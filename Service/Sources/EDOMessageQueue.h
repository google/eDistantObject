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
@interface EDOMessageQueue<ObjectType> : NSObject

/** Whether the queue has any messages. */
@property(readonly, nonatomic, getter=isEmpty) BOOL empty;

/**
 *  Enqueues the message for the service queue to process.
 *
 *  @param message The message to enqueue.
 *  @return YES if the message is enqueued; NO, if the queue is closed already and the message
 *          will not be enqueued.
 */
- (BOOL)enqueueMessage:(ObjectType)message;

/**
 *  Closes the queue so no more messages can be enqueued.
 *
 *  @return YES if the queue is just closed; NO if the queue is already closed.
 */
- (BOOL)closeQueue;

/**
 *  Dequeues the message.
 *
 *  This will block the current thread unless the queue is closed or there are new messages in the
 *  queue.
 *
 *  @return The message enqueued in the FIFO order. @c nil if the message queue doesn't have any
 *          pending messages and is already closed.
 */
- (nullable ObjectType)dequeueMessage;

@end

NS_ASSUME_NONNULL_END
