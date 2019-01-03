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

#import "Channel/Sources/EDOChannelPool.h"

#import "Channel/Sources/EDOHostPort.h"
#import "Channel/Sources/EDOSocket.h"
#import "Channel/Sources/EDOSocketChannel.h"
#import "Channel/Sources/EDOSocketPort.h"

@implementation EDOChannelPool {
  dispatch_queue_t _channelPoolQueue;
  NSMutableDictionary<EDOHostPort *, NSMutableSet<id<EDOChannel>> *> *_channelMap;
  // The socket of service registration.
  EDOSocket *_serviceRegistrationSocket;
  // The dispatch queue to accept service connection by name.
  dispatch_queue_t _serviceConnectionQueue;
  // The once token to guarantee thread-safety of service connection port setup.
  dispatch_once_t _serviceConnectionOnceToken;
}

+ (instancetype)sharedChannelPool {
  static EDOChannelPool *instance = nil;
  static dispatch_once_t token = 0;
  dispatch_once(&token, ^{
    instance = [[EDOChannelPool alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _channelPoolQueue = dispatch_queue_create("com.google.edo.channelPool", DISPATCH_QUEUE_SERIAL);
    _channelMap = [[NSMutableDictionary alloc] init];
    _serviceConnectionQueue =
        dispatch_queue_create("com.google.edo.serviceConnection", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)fetchConnectedChannelWithPort:(EDOHostPort *)port
                withCompletionHandler:(EDOFetchChannelHandler)handler {
  __block id<EDOChannel> socketChannel = nil;
  dispatch_sync(_channelPoolQueue, ^{
    NSMutableSet *channelSet = self->_channelMap[port];
    if (channelSet.count > 0) {
      id<EDOChannel> channel = [channelSet anyObject];
      [channelSet removeObject:channel];
      socketChannel = channel;
    }
  });
  if (socketChannel) {
    handler(socketChannel, nil);
  } else {
    [self EDO_createChannelWithPort:port withCompletionHandler:handler];
  }
}

- (void)addChannel:(id<EDOChannel>)channel {
  // reuse the channel only when it is valid
  if (channel.isValid) {
    dispatch_sync(_channelPoolQueue, ^{
      NSMutableSet<id<EDOChannel>> *channelSet = self->_channelMap[channel.hostPort];
      if (!channelSet) {
        channelSet = [[NSMutableSet alloc] init];
        [self->_channelMap setObject:channelSet forKey:channel.hostPort];
      }
      [channelSet addObject:channel];
    });
  }
}

- (void)removeChannelsWithPort:(EDOHostPort *)port {
  dispatch_sync(_channelPoolQueue, ^{
    [self->_channelMap removeObjectForKey:port];
  });
}

- (NSUInteger)countChannelsWithPort:(EDOHostPort *)port {
  __block NSUInteger channelCount = 0;
  dispatch_sync(_channelPoolQueue, ^{
    NSMutableSet *channelSet = self->_channelMap[port];
    if (channelSet) {
      channelCount = channelSet.count;
    }
  });
  return channelCount;
}

- (UInt16)serviceConnectionPort {
  dispatch_once(&_serviceConnectionOnceToken, ^{
    [self EDO_startHostRegistrationPortIfNeeded];
  });
  return _serviceRegistrationSocket.socketPort.port;
}

#pragma mark - private

- (void)EDO_createChannelWithPort:(EDOHostPort *)port
            withCompletionHandler:(EDOFetchChannelHandler)handler {
  __block EDOSocketChannel *channel = nil;
  [EDOSocket connectWithTCPPort:port.port
                          queue:nil
                 connectedBlock:^(EDOSocket *_Nullable socket, UInt16 listenPort,
                                  NSError *_Nullable error) {
                   if (error) {
                     handler(nil, error);
                   } else {
                     channel = [EDOSocketChannel
                         channelWithSocket:socket
                                  hostPort:[EDOHostPort hostPortWithLocalPort:listenPort]];
                     handler(channel, nil);
                   }
                 }];
}

- (void)EDO_startHostRegistrationPortIfNeeded {
  if (_serviceRegistrationSocket) {
    return;
  }
  _serviceRegistrationSocket = [EDOSocket
      listenWithTCPPort:0
                  queue:_serviceConnectionQueue
         connectedBlock:^(EDOSocket *socket, UInt16 listenPort, NSError *serviceError) {
           if (!serviceError) {
             EDOSocketChannel *socketChannel = [EDOSocketChannel channelWithSocket:socket];
             [socketChannel
                 receiveDataWithHandler:^(id<EDOChannel> channel, NSData *data, NSError *error) {
                   if (!error) {
                     NSString *name = [[NSString alloc] initWithData:data
                                                            encoding:NSUTF8StringEncoding];
                     [socketChannel updateHostPort:[EDOHostPort hostPortWithName:name]];
                     [self addChannel:socketChannel];
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
