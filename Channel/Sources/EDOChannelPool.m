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
#import "Device/Sources/EDODeviceConnector.h"

/** Timeout for channel fetch. */
static const int64_t kChannelPoolTimeout = 10 * NSEC_PER_SEC;

/**
 *  A data object to store channels with the same host port along with a semaphore to control
 *  available channel resource.
 */
@interface EDOChannelSet : NSObject
@property(nonatomic) NSMutableSet<id<EDOChannel>> *channels;
// Each channel set has a semaphore to guarantee available channel when make connection.
@property(nonatomic) dispatch_semaphore_t channelSemaphore;
@end

@implementation EDOChannelSet

- (instancetype)init {
  self = [super init];
  if (self) {
    _channels = [[NSMutableSet alloc] init];
    _channelSemaphore = dispatch_semaphore_create(0);
  }
  return self;
}

@end

@implementation EDOChannelPool {
  dispatch_queue_t _channelPoolQueue;
  NSMutableDictionary<EDOHostPort *, EDOChannelSet *> *_channelMap;
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

- (id<EDOChannel>)fetchConnectedChannelWithPort:(EDOHostPort *)port error:(NSError **)error {
  __block id<EDOChannel> channel = [self edo_popChannelFromChannelMapWithPort:port
                                                             waitUntilTimeout:NO];
  __block NSError *resultError;

  if (channel) {
    return channel;
  } else if (port.port == 0) {
    // TODO(ynzhang): Should request connection channel from the service side and add it to channel
    // pool. Now it is done in the unit test.
  } else {
    id<EDOChannel> createdChannel = [self edo_createChannelWithPort:port error:&resultError];
    if (createdChannel) {
      [self addChannel:createdChannel];
    }
  }
  channel = [self edo_popChannelFromChannelMapWithPort:port waitUntilTimeout:YES];
  if (error) {
    *error = resultError;
  } else {
    NSLog(@"Error fetching channel: %@", resultError);
  }
  return channel;
}

- (void)addChannel:(id<EDOChannel>)channel {
  // reuse the channel only when it is valid
  if (channel.isValid) {
    dispatch_sync(_channelPoolQueue, ^{
      EDOChannelSet *channelSet = self->_channelMap[channel.hostPort];
      if (!channelSet) {
        channelSet = [[EDOChannelSet alloc] init];
        [self->_channelMap setObject:channelSet forKey:channel.hostPort];
      }
      [channelSet.channels addObject:channel];
      dispatch_semaphore_signal(channelSet.channelSemaphore);
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
    NSMutableSet *channelSet = self->_channelMap[port].channels;
    if (channelSet) {
      channelCount = channelSet.count;
    }
  });
  return channelCount;
}

- (UInt16)serviceConnectionPort {
  dispatch_once(&_serviceConnectionOnceToken, ^{
    [self edo_startHostRegistrationPortIfNeeded];
  });
  return _serviceRegistrationSocket.socketPort.port;
}

#pragma mark - private

- (id<EDOChannel>)edo_createChannelWithPort:(EDOHostPort *)port error:(NSError **)error {
  __block id<EDOChannel> channel = nil;
  __block NSError *connectionError;
  if (port.deviceSerialNumber) {
    dispatch_io_t dispatchChannel =
        [EDODeviceConnector.sharedConnector connectToDevice:port.deviceSerialNumber
                                                     onPort:port.port
                                                      error:&connectionError];
    if (!connectionError) {
      channel = [EDOSocketChannel channelWithDispatchChannel:dispatchChannel hostPort:port];
    }
  } else {
    dispatch_semaphore_t lock = dispatch_semaphore_create(0);
    [EDOSocket connectWithTCPPort:port.port
                            queue:nil
                   connectedBlock:^(EDOSocket *socket, UInt16 listenPort, NSError *socketError) {
                     if (socket) {
                       channel = [EDOSocketChannel
                           channelWithSocket:socket
                                    hostPort:[EDOHostPort hostPortWithLocalPort:listenPort
                                                                    serviceName:port.name]];
                     }
                     connectionError = socketError;
                     dispatch_semaphore_signal(lock);
                   }];
    dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
  }
  if (error) {
    *error = connectionError;
  }
  return channel;
}

/**
 *  Pops channel from the channel set. If @c forcedToWait is @c NO, it will return @c nil if the
 *  channel set is empty.
 */
- (id<EDOChannel>)edo_popChannelFromChannelMapWithPort:(EDOHostPort *)port
                                      waitUntilTimeout:(BOOL)waitUntilTimeout {
  __block EDOChannelSet *channelSet;
  dispatch_sync(_channelPoolQueue, ^{
    channelSet = self->_channelMap[port];
    if (!channelSet) {
      channelSet = [[EDOChannelSet alloc] init];
      [self->_channelMap setObject:channelSet forKey:port];
    }
  });

  __block id<EDOChannel> socketChannel = nil;
  long success = dispatch_semaphore_wait(
      _channelMap[port].channelSemaphore,
      waitUntilTimeout ? dispatch_time(DISPATCH_TIME_NOW, kChannelPoolTimeout) : DISPATCH_TIME_NOW);
  if (success == 0) {
    dispatch_sync(_channelPoolQueue, ^{
      socketChannel = channelSet.channels.anyObject;
      [channelSet.channels removeObject:socketChannel];
    });
  }
  return socketChannel;
}

- (void)edo_startHostRegistrationPortIfNeeded {
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
