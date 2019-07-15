//
// Copyright 2019 Google LLC.
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
 *  Convenience creation method. See -initWithSocket:.
 *
 *  @param socket The established socket from the @c EDOSocketConnectedBlock callback.
 *  @return An instance of EDOSocketChannel.
 */
+ (instancetype)channelWithSocket:(EDOSocket *)socket;

/**
 *  Initializes a channel with the established socket.
 *
 *  @param socket The established socket from the @c EDOSocketConnectedBlock callback.
 */
- (instancetype)initWithSocket:(EDOSocket *)socket;

/**
 *  Releases the ownership of the underlying socket and returns it.
 *
 *  It is not guaranteed to return a valid socket; it returns what the underlying socket is and
 *  the channel becomes invalid.
 */
- (dispatch_fd_t)releaseSocket;

@end

NS_ASSUME_NONNULL_END
