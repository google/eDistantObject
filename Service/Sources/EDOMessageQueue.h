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

/**
 *  The message queue to enqueue and dequeue messages from different dispatch queues.
 *
 *  This is a thread-safe blocking queue used to process messages for the suspended dispatch queue.
 *  This also tracks the dispatch queue in a way where you can only enqueue the message in the queue
 *  where you've initialized instance of this class, so it is a one-to-one relationship between the
 *  message queue and the dispatch queue.
 */
@interface EDOMessageQueue : NSObject

@property(getter=isEmpty) BOOL empty;

/**
 *  Enqueue the message for the service queue to process.
 *
 *  @param message The message to enqueue.
 */
- (void)enqueueMessage:(id)message;

/**
 *  Dequeue the message.
 *
 *  This will block the current thread until the new message is available, a.k.a the consumer.
 *
 *  @return The message enqueued in the FIFO order.
 */
- (id)dequeueMessage;

@end

NS_ASSUME_NONNULL_END
