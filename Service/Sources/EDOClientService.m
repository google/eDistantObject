
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

#import "Service/Sources/EDOClientService.h"

#include <objc/runtime.h>

#import "Channel/Sources/EDOChannelPool.h"
#import "Channel/Sources/EDOHostPort.h"
#import "Channel/Sources/EDOSocketChannel.h"
#import "Service/Sources/EDOBlockObject.h"
#import "Service/Sources/EDOClassMessage.h"
#import "Service/Sources/EDOClientServiceStatsCollector.h"
#import "Service/Sources/EDOExecutor.h"
#import "Service/Sources/EDOHostNamingService.h"
#import "Service/Sources/EDOHostService+Private.h"
#import "Service/Sources/EDOObject+Private.h"
#import "Service/Sources/EDOObjectAliveMessage.h"
#import "Service/Sources/EDOObjectMessage.h"
#import "Service/Sources/EDOObjectReleaseMessage.h"
#import "Service/Sources/EDOTimingFunctions.h"
#import "Service/Sources/NSKeyedArchiver+EDOAdditions.h"
#import "Service/Sources/NSKeyedUnarchiver+EDOAdditions.h"

/** Timeout for ping health check. */
static const int64_t kPingTimeoutSeconds = 10 * NSEC_PER_SEC;

@implementation EDOClientService

+ (id)rootObjectWithPort:(UInt16)port {
  EDOHostPort *hostPort = [EDOHostPort hostPortWithLocalPort:port];
  EDOObjectRequest *objectRequest = [EDOObjectRequest requestWithHostPort:hostPort];
  return [self responseObjectWithRequest:objectRequest onPort:hostPort];
}

+ (id)rootObjectWithPort:(UInt16)port serviceName:(NSString *)serviceName {
  EDOHostPort *hostPort = [EDOHostPort hostPortWithLocalPort:port serviceName:serviceName];
  EDOObjectRequest *objectRequest = [EDOObjectRequest requestWithHostPort:hostPort];
  return [self responseObjectWithRequest:objectRequest onPort:hostPort];
}

+ (Class)classObjectWithName:(NSString *)className port:(UInt16)port {
  EDOHostPort *hostPort = [EDOHostPort hostPortWithLocalPort:port];
  EDOServiceRequest *classRequest = [EDOClassRequest requestWithClassName:className
                                                                 hostPort:hostPort];
  return (Class)[self responseObjectWithRequest:classRequest onPort:hostPort];
}

+ (Class)classObjectWithName:(NSString *)className
                        port:(UInt16)port
                 serviceName:(NSString *)serviceName {
  EDOHostPort *hostPort = [EDOHostPort hostPortWithLocalPort:port serviceName:serviceName];
  EDOServiceRequest *classRequest = [EDOClassRequest requestWithClassName:className
                                                                 hostPort:hostPort];
  return (Class)[self responseObjectWithRequest:classRequest onPort:hostPort];
}

+ (id)unwrappedObjectFromObject:(id)object {
  EDOObject *edoObject =
      [EDOBlockObject isBlock:object] ? [EDOBlockObject EDOBlockObjectFromBlock:object] : object;
  Class objClass = object_getClass(edoObject);
  if (objClass == [EDOObject class] || objClass == [EDOBlockObject class]) {
    EDOHostService *service = [EDOHostService serviceForCurrentQueue];
    // If there is a service for the current queue, we check if the object belongs to this queue.
    // Otherwise, we send EDOObjectAlive message to another service running in the same process.
    if ([service.port match:edoObject.servicePort]) {
      return (__bridge id)(void *)edoObject.remoteAddress;
    } else if (edoObject.isLocalEdo) {
      // If the underlying object is not a local object (but in the same process) then this could
      // return nil. For example, the service becomes invalide, or the remote object is already
      // released.
      id resolvedInstance = [self resolveInstanceFromEDOObject:edoObject];
      if (resolvedInstance) {
        return resolvedInstance;
      }
    }
  }

  return object;
}

+ (EDOHostNamingService *)namingServiceWithDeivceSerial:(NSString *)serial error:(NSError **)error {
  __block NSError *connectError;
  EDOHostPort *hostPort = [EDOHostPort hostPortWithPort:EDOHostNamingService.namingServerPort
                                                   name:nil
                                     deviceSerialNumber:serial];
  id<EDOChannel> channel =
      [EDOChannelPool.sharedChannelPool fetchConnectedChannelWithPort:hostPort error:&connectError];
  if (connectError) {
    if (error) {
      *error = connectError;
    }
    return nil;
  }

  EDOObjectRequest *objectRequest = [EDOObjectRequest requestWithHostPort:hostPort];
  NSData *requestData = [NSKeyedArchiver edo_archivedDataWithObject:objectRequest];
  dispatch_semaphore_t lock = dispatch_semaphore_create(0);
  [channel sendData:requestData
      withCompletionHandler:^(id<EDOChannel> channel, NSError *error) {
        if (error) {
          connectError = error;
        }
        dispatch_semaphore_signal(lock);
      }];
  dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
  __block EDOObjectResponse *response = nil;
  if (!connectError) {
    [channel receiveDataWithHandler:^(id<EDOChannel> channel, NSData *data, NSError *error) {
      if (error) {
        connectError = error;
      } else {
        // Continue to receive the response if the ping is received.
        if ([data isEqualToData:EDOClientService.pingMessageData]) {
          [channel receiveDataWithHandler:^(id<EDOChannel> channel, NSData *responseData,
                                            NSError *error) {
            if (error) {
              connectError = error;
            } else {
              response = [NSKeyedUnarchiver edo_unarchiveObjectWithData:responseData];
            }
            dispatch_semaphore_signal(lock);
          }];
        } else {
          // TODO(ynzhang): add better error handling with proper error info.
          connectError = [NSError errorWithDomain:NSPOSIXErrorDomain code:0 userInfo:nil];
          dispatch_semaphore_signal(lock);
        }
        [EDOChannelPool.sharedChannelPool addChannel:channel];
      }
    }];
    dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
  }
  if (error) {
    *error = connectError;
  }
  return response.object;
}

#pragma mark - Private Category

+ (NSMapTable *)localDistantObjects {
  static NSMapTable<NSNumber *, EDOObject *> *localDistantObjects;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    localDistantObjects = [NSMapTable strongToWeakObjectsMapTable];
  });
  return localDistantObjects;
}

+ (dispatch_queue_t)edoSyncQueue {
  static dispatch_queue_t edoSyncQueue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    edoSyncQueue = dispatch_queue_create("com.google.edo.service.edoSync", DISPATCH_QUEUE_SERIAL);
  });
  return edoSyncQueue;
}

+ (NSData *)pingMessageData {
  static NSData *_pingMessageData;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    _pingMessageData = [@"ping" dataUsingEncoding:NSUTF8StringEncoding];
  });
  return _pingMessageData;
}

+ (EDOObject *)distantObjectReferenceForRemoteAddress:(EDOPointerType)remoteAddress {
  NSNumber *edoKey = [NSNumber numberWithLongLong:remoteAddress];
  __block EDOObject *result;
  dispatch_sync(self.edoSyncQueue, ^{
    result = [self.localDistantObjects objectForKey:edoKey];
  });
  return result;
}

+ (void)addDistantObjectReference:(id)object {
  EDOObject *edoObject =
      [EDOBlockObject isBlock:object] ? [EDOBlockObject EDOBlockObjectFromBlock:object] : object;
  NSNumber *edoKey = [NSNumber numberWithLongLong:edoObject.remoteAddress];
  dispatch_sync(self.edoSyncQueue, ^{
    [self.localDistantObjects setObject:object forKey:edoKey];
  });
}

+ (void)removeDistantObjectReference:(EDOPointerType)remoteAddress {
  NSNumber *edoKey = [NSNumber numberWithLongLong:remoteAddress];
  dispatch_sync(self.edoSyncQueue, ^{
    [self.localDistantObjects removeObjectForKey:edoKey];
  });
}

+ (id)cachedEDOFromObjectUpdateIfNeeded:(id)object {
  EDOObject *edoObject =
      [EDOBlockObject isBlock:object] ? [EDOBlockObject EDOBlockObjectFromBlock:object] : object;
  Class objClass = object_getClass(edoObject);
  if (objClass == [EDOObject class] || objClass == [EDOBlockObject class]) {
    id localObject = [self distantObjectReferenceForRemoteAddress:edoObject.remoteAddress];
    EDOObject *localEDO = localObject;
    if ([EDOBlockObject isBlock:localObject]) {
      localEDO = [EDOBlockObject EDOBlockObjectFromBlock:localEDO];
    }
    // Verify the service in case the old address is overwritten by a new service.
    if ([edoObject.servicePort match:localEDO.servicePort]) {
      // Since we already have the EDOObject in the cache, the new decoded EDOObject is
      // taken as a temporary local object, which does not send release message.
      edoObject.local = YES;
      return localObject;
    } else {
      // Track the new remote object.
      [self addDistantObjectReference:object];
    }
  }
  return object;
}

+ (EDOServiceResponse *)sendSynchronousRequest:(EDOServiceRequest *)request
                                        onPort:(EDOHostPort *)port {
  // TODO(b/119416282): We still run the executor even for the other requests before the deadlock
  //                    issue is fixed.
  EDOHostService *service = [EDOHostService serviceForCurrentQueue];
  return [self sendSynchronousRequest:request onPort:port withExecutor:service.executor];
}

+ (EDOServiceResponse *)sendSynchronousRequest:(EDOServiceRequest *)request
                                        onPort:(EDOHostPort *)port
                                  withExecutor:(EDOExecutor *)executor {
  EDOClientServiceStatsCollector *stats = EDOClientServiceStatsCollector.sharedServiceStats;

  int maxAttempts = 2;
  int currentAttempt = 0;
  while (currentAttempt < maxAttempts) {
    NSError *error;
    uint64_t connectionStartTime = mach_absolute_time();
    id<EDOChannel> channel =
        [EDOChannelPool.sharedChannelPool fetchConnectedChannelWithPort:port error:&error];
    [stats reportConnectionDuration:EDOGetMillisecondsSinceMachTime(connectionStartTime)];

    // Raise an exception if the connection fails.
    if (error) {
      [stats reportError];
      NSString *reason =
          [NSString stringWithFormat:@"Failed to connect the service %@ for %@.", port, request];
      [[self exceptionWithReason:reason port:port error:error] raise];
    }

    // If the request is of type ObjectReleaseRequest then don't perform any of the
    // protocol (check if channel is alive, send ping message, report errors, etc.). If the message
    // wasn't able to sent then it's most likely that the host side is dead and there's no need
    // to retry or try to handle it.
    if ([request class] == [EDOObjectReleaseRequest class]) {
      [stats reportReleaseObject];
      NSData *requestData = [NSKeyedArchiver edo_archivedDataWithObject:request];
      [channel sendData:requestData withCompletionHandler:nil];
      [EDOChannelPool.sharedChannelPool addChannel:channel];
      return nil;
    } else {
      uint64_t requestStartTime = mach_absolute_time();
      __block NSData *responseData = nil;
      NSData *requestData = [NSKeyedArchiver edo_archivedDataWithObject:request];

      if (executor) {
        [executor runUsingMessageQueueCloseHandler:^(EDOMessageQueue *messageQueue) {
          responseData = [self sendRequestData:requestData withChannel:channel];
          [messageQueue closeQueue];
        }];
      } else {
        responseData = [self sendRequestData:requestData withChannel:channel];
      }

      EDOServiceResponse *response;
      if (responseData) {
        response = [NSKeyedUnarchiver edo_unarchiveObjectWithData:responseData];
        NSAssert([request.messageId isEqualToString:response.messageId],
                 @"The response (%@) Id is mismatched with the request (%@)", response, request);
      }

      [stats reportRequestType:[request class]
               requestDuration:EDOGetMillisecondsSinceMachTime(requestStartTime)
              responseDuration:response.duration];
      if (response) {
        [EDOChannelPool.sharedChannelPool addChannel:channel];
        // TODO(haowoo): Now there are only errors from the host service when the requests don't
        //               match the service UDID. We need to add a better error domain and code to
        //               give a better explanation of what went wrong for the request.
        if (response.error) {
          [[self exceptionWithReason:@"The host service couldn't handle the request"
                                port:port
                               error:response.error] raise];
        }
        return response;
      } else {
        // Cleanup broken channels before retry.
        [EDOChannelPool.sharedChannelPool removeChannelsWithPort:port];
        currentAttempt += 1;
      }
    }
  }
  NSAssert(NO,
           @"Failed to send request (%@) on port (%@) after %d attempts. The remote service may be "
           @"unresponsive due to a crash or hang. Check full logs for more information.",
           request, port, maxAttempts);
  return nil;
}

#pragma mark - Private

/**
 *  Sends EDOObjectAliveRequest to the service that the given object belongs to in the current
 *  process and check it is still alive.
 *
 *  @param object The remote object to check if it is alive.
 *  @return The underlying object if it is still alive, otherwise @c nil.
 */
+ (id)resolveInstanceFromEDOObject:(EDOObject *)object {
  @try {
    EDOObjectAliveRequest *request = [EDOObjectAliveRequest requestWithObject:object];
    EDOObjectAliveResponse *response = (EDOObjectAliveResponse *)[EDOClientService
        sendSynchronousRequest:request
                        onPort:object.servicePort.hostPort];

    EDOObject *responseObject;
    if ([EDOBlockObject isBlock:response.object]) {
      responseObject = [EDOBlockObject EDOBlockObjectFromBlock:response.object];
    } else {
      responseObject = response.object;
    }
    return (__bridge id)(void *)responseObject.remoteAddress;
  } @catch (NSException *e) {
    // In case of the service is dead or error, ignore the exception and reset to nil.
    return nil;
  }
}

+ (NSException *)exceptionWithReason:(NSString *)reason
                                port:(EDOHostPort *)port
                               error:(NSError *)error {
  NSDictionary *userInfo = @{@"port" : port, @"error" : error ?: NSNull.null};
  return [NSException exceptionWithName:NSDestinationInvalidException
                                 reason:reason
                               userInfo:userInfo];
}

/** Connects to the host service on the given @c port. */
+ (id<EDOChannel>)connectPort:(UInt16)port error:(NSError **)error {
  return [EDOChannelPool.sharedChannelPool
      fetchConnectedChannelWithPort:[EDOHostPort hostPortWithLocalPort:port]
                              error:error];
}

/** Sends the request data through the given @c channel and waits for the response synchronously. */
+ (NSData *)sendRequestData:(NSData *)requestData withChannel:(id<EDOChannel>)channel {
  __block NSData *responseData;
  // The channel is asynchronous and not I/O re-entrant so we chain the sending and receiving,
  // and capture the response in the callback blocks.
  [channel sendData:requestData withCompletionHandler:nil];

  __block BOOL serviceClosed = NO;
  dispatch_semaphore_t waitLock = dispatch_semaphore_create(0);
  EDOChannelReceiveHandler receiveHandler =
      ^(id<EDOChannel> channel, NSData *data, NSError *error) {
        responseData = data;
        serviceClosed = data == nil;
        dispatch_semaphore_signal(waitLock);
      };

  // Check ping response to make sure channel is healthy.
  [channel receiveDataWithHandler:receiveHandler];

  dispatch_time_t timeoutInSeconds = dispatch_time(DISPATCH_TIME_NOW, kPingTimeoutSeconds);
  long result = dispatch_semaphore_wait(waitLock, timeoutInSeconds);

  // Continue to receive the response if the ping is received.
  if ([responseData isEqualToData:EDOClientService.pingMessageData]) {
    [channel receiveDataWithHandler:receiveHandler];
    dispatch_semaphore_wait(waitLock, DISPATCH_TIME_FOREVER);
  }

  if (result != 0 || serviceClosed) {
    NSLog(@"The edo channel %@ is broken.", channel);
  }

  return responseData;
}

+ (EDOObject *)responseObjectWithRequest:(EDOServiceRequest *)request onPort:(EDOHostPort *)port {
  EDOServiceResponse *response = [self sendSynchronousRequest:request onPort:port];
  EDOObject *remoteObject = ((EDOObjectResponse *)response).object;
  remoteObject = [self unwrappedObjectFromObject:remoteObject];
  remoteObject = [self cachedEDOFromObjectUpdateIfNeeded:remoteObject];
  return remoteObject;
}

@end
