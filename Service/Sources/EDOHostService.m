//
// Copyright 2018 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "Service/Sources/EDOHostService.h"

#include <objc/runtime.h>

#import "Channel/Sources/EDOHostPort.h"
#import "Channel/Sources/EDOSocket.h"
#import "Channel/Sources/EDOSocketChannel.h"
#import "Channel/Sources/EDOSocketPort.h"
#import "Device/Sources/EDODeviceConnector.h"
#import "Service/Sources/EDOBlockObject.h"
#import "Service/Sources/EDOClientService+Device.h"
#import "Service/Sources/EDOClientService+Private.h"
#import "Service/Sources/EDOExecutor.h"
#import "Service/Sources/EDOHostNamingService+Private.h"
#import "Service/Sources/EDOHostService+Handlers.h"
#import "Service/Sources/EDOObject+Private.h"
#import "Service/Sources/EDOObjectReleaseMessage.h"
#import "Service/Sources/NSKeyedArchiver+EDOAdditions.h"
#import "Service/Sources/NSKeyedUnarchiver+EDOAdditions.h"

// The context key for the executor for the dispatch queue.
static const char *gServiceKey = "com.google.edo.servicekey";

@interface EDOHostService ()
/** The execution queue for the root object. */
@property(readonly, weak) dispatch_queue_t executionQueue;
/** The executor to handle the request. */
@property(readonly) EDOExecutor *executor;
/** The set to save channel handlers in order to keep channels ready to accept request. */
@property(readonly) NSMutableSet<EDOChannelReceiveHandler> *handlerSet;
/** The queue to update handlerSet atomically. */
@property(readonly) dispatch_queue_t handlerSyncQueue;
/** The listen socket. */
@property(readonly) EDOSocket *listenSocket;
/** The tracked objects in the service. The key is the address of a tracked object and the value is
 * the object. */
@property(readonly) NSMutableDictionary<NSNumber *, id> *localObjects;
/** The queue to update local objects atomically. */
@property(readonly) dispatch_queue_t localObjectsSyncQueue;
/** The underlying root object. */
@property(readonly) id rootLocalObject;
@end

@implementation EDOHostService

@synthesize port = _port;

+ (instancetype)serviceForCurrentQueue {
  return (__bridge EDOHostService *)(dispatch_get_specific(gServiceKey));
}

+ (instancetype)serviceForQueue:(dispatch_queue_t)queue {
  return (__bridge EDOHostService *)(dispatch_queue_get_specific(queue, gServiceKey));
}

+ (instancetype)serviceWithPort:(UInt16)port rootObject:(id)object queue:(dispatch_queue_t)queue {
  return [[self alloc] initWithPort:port
                         rootObject:object
                        serviceName:nil
                              queue:queue
                         isToDevice:NO];
}

+ (instancetype)serviceWithRegisteredName:(NSString *)name
                               rootObject:(id)object
                                    queue:(dispatch_queue_t)queue {
  return [[self alloc] initWithPort:0 rootObject:object serviceName:name queue:queue isToDevice:NO];
}

+ (instancetype)serviceWithName:(NSString *)name
               registerToDevice:(NSString *)deviceSerial
                     rootObject:(id)object
                          queue:(dispatch_queue_t)queue {
  EDOHostService *service = [[self alloc] initWithPort:0
                                            rootObject:object
                                           serviceName:name
                                                 queue:queue
                                            isToDevice:YES];
  NSError *error;
  [service edo_registerServiceOnDevice:deviceSerial withName:name error:&error];
  if (error) {
    return nil;
  }
  service->_port = [EDOServicePort servicePortWithPort:0 serviceName:name];
  NSLog(@"The EDOHostService (%p) is registered to device %@", self, deviceSerial);
  return service;
}

- (instancetype)initWithPort:(UInt16)port
                  rootObject:(id)object
                 serviceName:(NSString *)serviceName
                       queue:(dispatch_queue_t)queue
                  isToDevice:(BOOL)isToDevice {
  self = [super init];
  if (self) {
    _localObjects = [[NSMutableDictionary alloc] init];
    _localObjectsSyncQueue =
        dispatch_queue_create("com.google.edo.service.localObjects", DISPATCH_QUEUE_SERIAL);
    _handlerSet = [[NSMutableSet alloc] init];
    _handlerSyncQueue =
        dispatch_queue_create("com.google.edo.service.handlers", DISPATCH_QUEUE_SERIAL);

    _executionQueue = queue;
    _executor = [EDOExecutor executorWithHandlers:[self class].handlers queue:queue];

    // Only creates the listen socket when the port is given or the root object is given so we need
    // to serve them at launch.
    if (!isToDevice && (port != 0 || object)) {
      _listenSocket = [self edo_createListenSocket:port];
      _port = [EDOServicePort servicePortWithPort:_listenSocket.socketPort.port
                                      serviceName:serviceName];
      [EDOHostNamingService.sharedService addServicePort:_port];
      NSLog(@"The EDOHostService (%p) is created and listening on %d", self, _port.hostPort.port);
    }

    if (object) {
      _rootLocalObject = object;
    }

    // Save itself to the queue.
    if (queue) {
      dispatch_queue_set_specific(queue, gServiceKey, (void *)CFBridgingRetain(self),
                                  (dispatch_function_t)CFBridgingRelease);
    }
  }
  return self;
}

- (void)dealloc {
  [self invalidate];
}

- (void)invalidate {
  if (!self.listenSocket.valid) {
    return;
  }
  [EDOHostNamingService.sharedService removeServicePort:_port];
  [self.listenSocket invalidate];
  // Retain the strong reference first to make sure atomicity.
  dispatch_queue_t executionQueue = self.executionQueue;
  if (executionQueue) {
    dispatch_queue_set_specific(executionQueue, gServiceKey, NULL, NULL);
  }
  NSLog(@"The EDOHostService (%p) is invalidated on port %d", self, _port.hostPort.port);
}

- (EDOServicePort *)port {
  // If the listen socket is not created at launch, we create it only when it's being used for the
  // first time and the auto-assigned zero port is used. This is useful for the temporary services.
  if (!_port) {
    _listenSocket = [self edo_createListenSocket:0];
    _port = [EDOServicePort servicePortWithPort:_listenSocket.socketPort.port serviceName:nil];
    NSLog(@"The EDOHostService (%p) is created lazily and listening on %d", self,
          _port.hostPort.port);
  }
  return _port;
}

#pragma mark - Private

- (EDOObject *)distantObjectForLocalObject:(id)object hostPort:(EDOHostPort *)hostPort {
  // TODO(haowoo): The edoObject shouldn't be shared across different services, currently there is
  //               only one edoObject associated with the underlying object. We need to have a
  //               edoObject for each service per object.

  BOOL isObjectBlock = [EDOBlockObject isBlock:object];
  // We need to make a copy for the block object. This will move the stack block to the heap so
  // we can still access it. For other types of blocks, i.e. global and malloc, it may only increase
  // the retain count.
  // Here we let ARC copy the block properly and we can then safely retain the resulting block.
  if (isObjectBlock) {
    object = [object copy];
  }

  NSNumber *objectKey = [NSNumber numberWithLongLong:(EDOPointerType)object];
  if (object != self.rootLocalObject) {
    dispatch_sync(_localObjectsSyncQueue, ^{
      if (![self.localObjects objectForKey:objectKey]) {
        [self.localObjects setObject:object forKey:objectKey];
      }
    });
  }

  hostPort = hostPort ?: self.port.hostPort;
  EDOServicePort *port = [EDOServicePort servicePortWithPort:self.port hostPort:hostPort];

  if (isObjectBlock) {
    return [EDOBlockObject edo_remoteProxyFromUnderlyingObject:object withPort:port];
  } else {
    return [EDOObject edo_remoteProxyFromUnderlyingObject:object withPort:port];
  }
}

- (BOOL)isObjectAlive:(EDOObject *)object {
  // TODO(haowoo): There can be different strategies to evict the object from the local cache,
  //               we should check if the object is still in the cache (self.localObjects).
  return [self.port match:object.servicePort];
}

- (BOOL)removeObjectWithAddress:(EDOPointerType)remoteAddress {
  NSNumber *edoKey = [NSNumber numberWithLongLong:remoteAddress];
  dispatch_sync(_localObjectsSyncQueue, ^{
    [self.localObjects removeObjectForKey:edoKey];
  });
  return YES;
}

- (void)startReceivingRequestsForChannel:(id<EDOChannel>)channel {
  __block __weak EDOChannelReceiveHandler weakHandlerBlock;
  __weak EDOHostService *weakSelf = self;

  // This handler block will be executed recursively by calling itself at the end of the
  // block in order to accept new request after last one is executed.
  // It is the strong reference of @c weakHandlerBlock above.
  EDOChannelReceiveHandler receiveHandler = ^(id<EDOChannel> targetChannel, NSData *data,
                                              NSError *error) {
    EDOChannelReceiveHandler strongHandlerBlock = weakHandlerBlock;
    EDOHostService *strongSelf = weakSelf;
    NSException *exception;
    // TODO(haowoo): Add the proper error handler.
    NSAssert(error == nil, @"Failed to receive the data (%d) for %@.",
             strongSelf.port.hostPort.port, error);
    if (data == nil) {
      // the client socket is closed.
      NSLog(@"The channel (%p) with port %d is closed", targetChannel,
            strongSelf.port.hostPort.port);
      dispatch_sync(strongSelf.handlerSyncQueue, ^{
        [strongSelf.handlerSet removeObject:strongHandlerBlock];
      });
      return;
    }
    EDOServiceRequest *request;

    @try {
      request = [NSKeyedUnarchiver edo_unarchiveObjectWithData:data];
    } @catch (NSException *e) {
      // TODO(haowoo): Handle exceptions in a better way.
      exception = e;
    }
    if (![request matchesService:strongSelf.port]) {
      // TODO(ynzhang): With better error handling, we may not throw exception in this
      // case but return an error response.
      NSError *error;

      if (!request) {
        // Error caused by the unarchiving process.
        error = [NSError errorWithDomain:exception.reason code:0 userInfo:nil];
      } else {
        error = [NSError errorWithDomain:NSPOSIXErrorDomain code:0 userInfo:nil];
      }
      EDOServiceResponse *errorResponse = [EDOServiceResponse errorResponse:error
                                                                 forRequest:request];
      NSData *errorData = [NSKeyedArchiver edo_archivedDataWithObject:errorResponse];
      [targetChannel sendData:errorData
          withCompletionHandler:^(id<EDOChannel> _Nonnull _channel, NSError *_Nullable error) {
            dispatch_sync(strongSelf.handlerSyncQueue, ^{
              [strongSelf.handlerSet removeObject:strongHandlerBlock];
            });
          }];
    } else {
      // For release request, we don't handle it in executor since response is not
      // needed for this request. The request handler will process this request
      // properly in its own queue.
      if ([request class] == [EDOObjectReleaseRequest class]) {
        [EDOObjectReleaseRequest requestHandler](request, strongSelf);
      } else {
        // Health check for the channel.
        [targetChannel sendData:EDOClientService.pingMessageData withCompletionHandler:nil];
        EDOServiceResponse *response = [strongSelf.executor handleRequest:request context:self];

        NSData *responseData = [NSKeyedArchiver edo_archivedDataWithObject:response];
        [targetChannel sendData:responseData withCompletionHandler:nil];
      }
      if ([strongSelf edo_shouldReceiveData:channel]) {
        [targetChannel receiveDataWithHandler:strongHandlerBlock];
      }
    }
    // Channel will be released and invalidated if service becomes invalid. So the
    // recursive block will eventually finish after service is invalid.
  };
  weakHandlerBlock = receiveHandler;

  // The channel is strongly referenced in receiveHandler until the channel or the host service is
  // invalidated.
  [channel receiveDataWithHandler:receiveHandler];

  dispatch_sync(self.handlerSyncQueue, ^{
    [self.handlerSet addObject:receiveHandler];
  });
}

- (EDOSocket *)edo_createListenSocket:(UInt16)port {
  __weak EDOHostService *weakSelf = self;
  return [EDOSocket
      listenWithTCPPort:port
                  queue:nil
         connectedBlock:^(EDOSocket *socket, UInt16 listenPort, NSError *error) {
           EDOHostService *strongSelf = weakSelf;
           if (!strongSelf) {
             // TODO(haowoo): Add more info to the response when the service becomes invalid.
             [socket invalidate];
             return;
           }

           id<EDOChannel> clientChannel =
               [EDOSocketChannel channelWithSocket:socket
                                          hostPort:[EDOHostPort hostPortWithLocalPort:listenPort]];
           [strongSelf startReceivingRequestsForChannel:clientChannel];
         }];
}

- (void)edo_registerServiceOnDevice:(NSString *)deviceSerial
                           withName:(NSString *)name
                              error:(NSError **)error {
  __block NSError *connectionError;
  EDOHostNamingService *namingService =
      [EDOClientService namingServiceWithDeivceSerial:deviceSerial error:&connectionError];
  if (!connectionError) {
    UInt16 port = namingService.serviceConnectionPort;
    EDOHostPort *devicePort = [EDOHostPort hostPortWithPort:port
                                                       name:name
                                         deviceSerialNumber:deviceSerial];
    dispatch_io_t dispatchChannel =
        [EDODeviceConnector.sharedConnector connectToDevice:devicePort.deviceSerialNumber
                                                     onPort:devicePort.port
                                                      error:&connectionError];
    if (!connectionError) {
      id<EDOChannel> channel = [EDOSocketChannel channelWithDispatchChannel:dispatchChannel
                                                                   hostPort:devicePort];
      NSData *data = [name dataUsingEncoding:kCFStringEncodingUTF8];
      dispatch_semaphore_t lock = dispatch_semaphore_create(0);
      [channel sendData:data
          withCompletionHandler:^(id<EDOChannel> channel, NSError *channelError) {
            if (channelError) {
              connectionError = channelError;
            } else {
              [self startReceivingRequestsForChannel:channel];
            }
            dispatch_semaphore_signal(lock);
          }];
      dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
    }
  }
  if (error) {
    *error = connectionError;
  }
}

- (BOOL)edo_shouldReceiveData:(id<EDOChannel>)channel {
  // If listenSocket is nil and port number is 0, it indicates a service on Mac for iOS device.
  if (!_listenSocket && _port.port == 0) {
    return channel.isValid;
  }
  return channel.isValid && _listenSocket.valid;
}

@end
