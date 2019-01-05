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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class EDOHostPort;
@protocol EDOChannel;

/**
 *  @typedef EDOFetchChannelHandler
 *  The type of handlers that are invoked when channel is successfully created or fetched from the
 *  socket channel pool.
 *
 *  @param socketChannel The channel fetched from the channel pool. Nil if the channel
 *                       failed to be created.
 *  @param error         The error object if the data is failed to send. Nil if
 *                       there wasn't an error in the channel.
 */
typedef void (^EDOFetchChannelHandler)(id<EDOChannel> _Nullable socketChannel,
                                       NSError *_Nullable error);

/**
 *  The @c EDOChannelPool manages channels that are used to send data to
 *  another process.
 *
 *  @c EDOSocketChannel objects that are available can be stored here for future reuse.
 *  It will help save time build socket connection again. Channels are clustered with the port
 *  they are connected to.
 */
@interface EDOChannelPool : NSObject

@property(class, readonly) EDOChannelPool *sharedChannelPool;

/**
 *  A port for clients to accept connection, and receive host name to register as service. This port
 *  will lazily create a listen socket when accessed.
 */
@property(readonly) UInt16 serviceConnectionPort;

/**
 *  Fetch an available channel from the pool given host port. If no available, it will connect the
 *  host port to create one.
 */
- (id<EDOChannel>)fetchConnectedChannelWithPort:(EDOHostPort *)port
                                          error:(NSError *_Nullable *_Nullable)error;
/**
 *  Release an available channel and add it to the pool.
 */
- (void)addChannel:(id<EDOChannel>)channel;

/**
 *  Clean up channels connected by the given host port.
 *  This should be called when the service the host port belongs to is closed.
 */
- (void)removeChannelsWithPort:(EDOHostPort *)port;

/**
 *  The count of channels in the pool given host port.
 */
- (NSUInteger)countChannelsWithPort:(EDOHostPort *)port;

@end

NS_ASSUME_NONNULL_END
