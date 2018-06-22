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

@implementation EDOMessageQueue

@dynamic empty;

- (instancetype)init {
  self = [super init];
  if (self) {
    _messages = [[NSMutableArray alloc] init];

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

- (void)enqueueMessage:(id)message {
  dispatch_sync(self.messageIsolationQueue, ^{
    [self.messages addObject:message];
  });
  dispatch_semaphore_signal(self.numberOfMessages);
}

- (id)dequeueMessage {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSAssert(dispatch_get_current_queue() == self.queue,
           @"Only dequeue the message from the assigned queue");
#pragma clang diagnostic pop

  // TODO(haowoo): Add finite timeout and errors.
  dispatch_semaphore_wait(self.numberOfMessages, DISPATCH_TIME_FOREVER);

  __block id message = nil;
  dispatch_sync(self.messageIsolationQueue, ^{
    message = self.messages.firstObject;
    [self.messages removeObjectAtIndex:0];
  });
  return message;
}

- (BOOL)isEmpty {
  return self.messages.count == 0;
}
@end
