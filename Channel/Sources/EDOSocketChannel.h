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

#import "Channel/Sources/EDOChannel.h"

NS_ASSUME_NONNULL_BEGIN

@class EDOSocket;

/**
 *  The channel implemented using POSIX socket.
 *
 *  It uses dispatch_source and dispatch_io to process the non-blocking I/O. The users' completion
 *  block is dispatched to the queue of user's choice and they are scheduled in the order of data
 *  received; so if the user has a serial queue, the handler block will be scheduled in the order of
 *  data received. It is fine to block the handler block; the handler block will be continuousely to
 *  be scheduled to the user's queue.
 */
@interface EDOSocketChannel : NSObject <EDOChannel>

/**
 * The listen port number that the channel socket is connected to.
 */
@property(readonly, nonatomic) UInt16 listenPort;

/**
 *  Create a channel with the established socket.
 *
 *  @param socket     The established socket from the @c EDOSocketConnectedBlock callback.
 *  @param listenPort The listen port number that the channel socket is connected to.
 *
 *  @return An instance of EDOSocketChannel.
 */
+ (instancetype)channelWithSocket:(EDOSocket *)socket listenPort:(UInt16)listenPort;

- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
