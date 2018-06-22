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

#import "Channel/Sources/EDOSocketChannelPool.h"

#import "Channel/Sources/EDOSocket.h"
#import "Channel/Sources/EDOSocketChannel.h"
#import "Channel/Sources/EDOSocketPort.h"

@implementation EDOSocketChannelPool {
  dispatch_queue_t _channelPoolQueue;
  NSMutableDictionary<NSNumber *, NSMutableSet<EDOSocketChannel *> *> *_channelMap;
}

+ (instancetype)sharedChannelPool {
  static EDOSocketChannelPool *instance = nil;
  static dispatch_once_t token = 0;
  dispatch_once(&token, ^{
    instance = [[EDOSocketChannelPool alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _channelPoolQueue = dispatch_queue_create("com.google.edo.executor", DISPATCH_QUEUE_SERIAL);
    _channelMap = [[NSMutableDictionary alloc] init];
  }
  return self;
}

- (void)fetchConnectedChannelWithPort:(UInt16)port
                withCompletionHandler:(EDOFetchChannelHandler)handler {
  NSNumber *channelSetKey = [NSNumber numberWithUnsignedShort:port];
  __block EDOSocketChannel *socketChannel = nil;
  dispatch_sync(_channelPoolQueue, ^{
    NSMutableSet *channelSet = self->_channelMap[channelSetKey];
    if (!channelSet) {
      channelSet = [[NSMutableSet alloc] init];
      [self->_channelMap setObject:channelSet forKey:channelSetKey];
    }
    if (channelSet.count > 0) {
      EDOSocketChannel *channel = [channelSet anyObject];
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

- (void)addChannel:(EDOSocketChannel *)channel {
  // reuse the channel only when it is valid
  if (channel.isValid) {
    NSNumber *channelSetKey = [NSNumber numberWithUnsignedShort:channel.listenPort];
    dispatch_sync(_channelPoolQueue, ^{
      NSMutableSet<EDOSocketChannel *> *channelSet = self->_channelMap[channelSetKey];
      [channelSet addObject:channel];
    });
  }
}

- (void)removeChannelsWithPort:(UInt16)port {
  NSNumber *channelSetKey = [NSNumber numberWithUnsignedShort:port];
  dispatch_sync(_channelPoolQueue, ^{
    [self->_channelMap removeObjectForKey:channelSetKey];
  });
}

- (NSUInteger)countChannelsWithPort:(UInt16)port {
  __block NSUInteger channelCount = 0;
  NSNumber *channelSetKey = [NSNumber numberWithUnsignedShort:port];
  dispatch_sync(_channelPoolQueue, ^{
    NSMutableSet *channelSet = self->_channelMap[channelSetKey];
    if (channelSet) {
      channelCount = channelSet.count;
    }
  });
  return channelCount;
}

#pragma mark - private

- (void)EDO_createChannelWithPort:(UInt16)port
            withCompletionHandler:(EDOFetchChannelHandler)handler {
  __block EDOSocketChannel *channel = nil;
  [EDOSocket
      connectWithTCPPort:port
                   queue:nil
          connectedBlock:^(EDOSocket *_Nullable socket, UInt16 listenPort,
                           NSError *_Nullable error) {
            if (error) {
              handler(nil, error);
            } else {
              channel = [EDOSocketChannel channelWithSocket:socket listenPort:listenPort];
              handler(channel, nil);
            }
          }];
}

@end
