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

#import "Service/Sources/EDOMessageQueue.h"

@interface EDOMessageQueue ()
// The dispatch queue used for the resource isolation/fast lock
@property(readonly) dispatch_queue_t messageIsolationQueue;
// The messages in the queue.
@property(readonly) NSMutableArray *messages;
// The message semaphore to signal.
@property(readonly) dispatch_semaphore_t numberOfMessages;
// Debug purpose to track the execution queue.
@property(readonly) __weak dispatch_queue_t queue; // NOLINT
@end

@implementation EDOMessageQueue {
  /** Whether the queue is closed and will reject any new messages. */
  BOOL _closed;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _messages = [[NSMutableArray alloc] init];
    _closed = NO;

    NSString *queueName = [NSString stringWithFormat:@"com.google.edo.message[%p]", self];
    _messageIsolationQueue = dispatch_queue_create(queueName.UTF8String, DISPATCH_QUEUE_SERIAL);

    _numberOfMessages = dispatch_semaphore_create(0L);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _queue = dispatch_get_current_queue();
#pragma clang diagnostic pop
  }
  return self;
}

- (BOOL)enqueueMessage:(id)message {
  __block BOOL enqueued = NO;
  dispatch_sync(self.messageIsolationQueue, ^{
    if (!self->_closed) {
      [self.messages addObject:message];
      enqueued = YES;
    }
  });
  dispatch_semaphore_signal(self.numberOfMessages);
  return enqueued;
}

- (id)dequeueMessage {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSAssert(dispatch_get_current_queue() == self.queue,
           @"Only dequeue the message from the assigned queue");
#pragma clang diagnostic pop

  __block BOOL shouldWaitMessage = YES;
  dispatch_sync(self.messageIsolationQueue, ^{
    if (self->_closed && self.messages.count == 0) {
      shouldWaitMessage = NO;
    }
  });
  if (!shouldWaitMessage) {
    return nil;
  }

  dispatch_semaphore_wait(self.numberOfMessages, DISPATCH_TIME_FOREVER);

  __block id message = nil;
  dispatch_sync(self.messageIsolationQueue, ^{
    if (!self->_closed || self.messages.count > 0) {
      message = self.messages.firstObject;
      [self.messages removeObjectAtIndex:0];
    }
  });
  return message;
}

- (BOOL)closeQueue {
  __block BOOL success = NO;
  dispatch_sync(self.messageIsolationQueue, ^{
    if (!self->_closed) {
      self->_closed = YES;
      success = YES;
    }
  });
  if (success) {
    dispatch_semaphore_signal(self.numberOfMessages);
  }
  return success;
}

- (BOOL)isEmpty {
  __block BOOL empty = NO;
  dispatch_sync(self.messageIsolationQueue, ^{
    empty = self.messages.count == 0;
  });
  return empty;
}

@end
