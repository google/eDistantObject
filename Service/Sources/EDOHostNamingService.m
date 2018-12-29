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

#import "Service/Sources/EDOHostNamingService.h"

#import "Channel/Sources/EDOChannelPool.h"
#import "Channel/Sources/EDOHostPort.h"
#import "Channel/Sources/EDOSocket.h"
#import "Channel/Sources/EDOSocketChannel.h"
#import "Channel/Sources/EDOSocketPort.h"
#import "Service/Sources/EDOHostNamingService+Private.h"
#import "Service/Sources/EDOHostService.h"
#import "Service/Sources/EDOServicePort.h"

@implementation EDOHostNamingService {
  // The mapping from service name to host service port.
  NSMutableDictionary<NSString *, EDOServicePort *> *_servicePortsInfo;
  // The dispatch queue to execute atomic operations of starting/stopping service and
  // tracking/untracking service port info.
  dispatch_queue_t _namingServicePortQueue;
  // The dispatch queue to execute service start/stop events and request handler of the naming
  // service.
  dispatch_queue_t _namingServiceEventQueue;
  // The dispatch queue to register service by name.
  dispatch_queue_t _serviceRegistrationQueue;
  // The host service serving the naming service object.
  EDOHostService *_service;
  // The socket of service registration.
  EDOSocket *_serviceRegistrationSocket;
}

+ (UInt16)namingServerPort {
  return 11237;
}

+ (NSString *)serviceRegistrationPortName {
  return @"EDOServiceReigstration";
}

+ (instancetype)sharedService {
  static EDOHostNamingService *instance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[EDOHostNamingService alloc] initInternal];
  });
  return instance;
}

- (instancetype)initInternal {
  self = [super init];
  if (self) {
    _servicePortsInfo = [[NSMutableDictionary alloc] init];
    _service = nil;
    _namingServicePortQueue =
        dispatch_queue_create("com.google.edo.namingService.port", DISPATCH_QUEUE_SERIAL);
    _namingServiceEventQueue =
        dispatch_queue_create("com.google.edo.namingService.event", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)dealloc {
  [_service invalidate];
}

- (EDOServicePort *)portForServiceWithName:(NSString *)name {
  __block EDOServicePort *portInfo;
  dispatch_sync(_namingServicePortQueue, ^{
    portInfo = self->_servicePortsInfo[name];
  });
  return portInfo;
}

- (BOOL)start {
  // Use a local variable to guarantee thread-safety.
  __block BOOL result;
  dispatch_sync(_namingServiceEventQueue, ^{
    if (self->_service) {
      return;
    }
    self->_service = [EDOHostService serviceWithPort:EDOHostNamingService.namingServerPort
                                          rootObject:self
                                               queue:self->_namingServiceEventQueue];
    result = self->_service.port.port != 0;
    self->_serviceRegistrationSocket = [self startHostRegistrationPortIfNeeded];

    if (self->_serviceRegistrationSocket) {
      UInt16 port = self->_serviceRegistrationSocket.socketPort.port;
      [self
          addServicePort:[EDOServicePort
                             servicePortWithPort:port
                                     serviceName:EDOHostNamingService.serviceRegistrationPortName]];
    }
  });
  return result;
}

- (void)stop {
  [self removeServicePortWithName:EDOHostNamingService.serviceRegistrationPortName];
  dispatch_sync(_namingServiceEventQueue, ^{
    [self->_service invalidate];
    self->_service = nil;
    [self->_serviceRegistrationSocket invalidate];
    self->_serviceRegistrationSocket = nil;
  });
}

#pragma mark - Private category

- (BOOL)addServicePort:(EDOServicePort *)servicePort {
  __block BOOL result;
  dispatch_sync(_namingServicePortQueue, ^{
    if ([self->_servicePortsInfo objectForKey:servicePort.serviceName]) {
      result = NO;
    } else {
      [self->_servicePortsInfo setObject:servicePort forKey:servicePort.serviceName];
      result = YES;
    }
  });
  return result;
}

- (void)removeServicePortWithName:(NSString *)name {
  dispatch_sync(_namingServicePortQueue, ^{
    [self->_servicePortsInfo removeObjectForKey:name];
  });
}

#pragma mark - Private

/**
 *  Starts a port for clients to connect, and receive host name to register as service. Returns the
 *  listen port number.
 *
 *  Does nothing if the host registration port is already listening and returns the current listen
 *  port.
 */
- (EDOSocket *)startHostRegistrationPortIfNeeded {
  if (_serviceRegistrationSocket) {
    return _serviceRegistrationSocket;
  }
  __block UInt16 port = 0;
  return [EDOSocket
      listenWithTCPPort:0
                  queue:_serviceRegistrationQueue
         connectedBlock:^(EDOSocket *socket, UInt16 listenPort, NSError *serviceError) {
           if (!serviceError) {
             EDOSocketChannel *socketChannel = [EDOSocketChannel channelWithSocket:socket];
             [socketChannel
                 receiveDataWithHandler:^(id<EDOChannel> channel, NSData *data, NSError *error) {
                   if (!error) {
                     NSString *name = [[NSString alloc] initWithData:data
                                                            encoding:NSUTF8StringEncoding];
                     [socketChannel updateHostPort:[EDOHostPort hostPortWithName:name]];
                     [EDOChannelPool.sharedChannelPool addChannel:socketChannel];
                     port = listenPort;
                   } else {
                     // Log the error instead of exception in order not to terminate the process,
                     // since eDO may still work without getting the host port name.
                     NSLog(@"Unable to receive host port name: %@", error);
                   }
                 }];
           }
         }];
}

@end
