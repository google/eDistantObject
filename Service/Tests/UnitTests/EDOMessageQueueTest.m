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

#import <XCTest/XCTest.h>

#import "Service/Sources/EDOMessage.h"
#import "Service/Sources/EDOMessageQueue.h"

@interface EDOMessageQueueTest : XCTestCase
@end

@implementation EDOMessageQueueTest

- (void)testCloseQueueWithMessages {
  XCTestExpectation *expectClose = [self expectationWithDescription:@"The queue is closed."];
  EDOMessageQueue<EDOMessage *> *messageQueue = [[EDOMessageQueue alloc] init];
  dispatch_async([self testQueue], ^{
    XCTAssertTrue([messageQueue enqueueMessage:[[EDOMessage alloc] init]]);
    XCTAssertTrue([messageQueue closeQueue]);
    XCTAssertFalse([messageQueue closeQueue], @"The queue should only be closed once.");
    [expectClose fulfill];
  });

  [self waitForExpectationsWithTimeout:1 handler:nil];
  XCTAssertNotNil([messageQueue dequeueMessage]);
  XCTAssertNil([messageQueue dequeueMessage]);
  XCTAssertFalse([messageQueue enqueueMessage:[[EDOMessage alloc] init]],
                 @"No new messages should be enqueued after it is closed");
}

- (void)testCloseQueueWithoutMessages {
  XCTestExpectation *expectClose = [self expectationWithDescription:@"The queue is closed."];
  EDOMessageQueue<EDOMessage *> *messageQueue = [[EDOMessageQueue alloc] init];
  dispatch_queue_t testQueue = [self testQueue];
  dispatch_async(testQueue, ^{
    XCTAssertTrue([messageQueue closeQueue]);
    XCTAssertFalse([messageQueue closeQueue]);
    [expectClose fulfill];
  });
  [self waitForExpectationsWithTimeout:1 handler:nil];
  XCTAssertNil([messageQueue dequeueMessage]);
}

- (void)testEnqueueDequeueMessage {
  EDOMessageQueue<EDOMessage *> *messageQueue = [[EDOMessageQueue alloc] init];
  NSArray<EDOMessage *> *messages = [self messages];

  XCTAssertTrue([messageQueue enqueueMessage:messages[0]]);
  XCTAssertEqual([messageQueue dequeueMessage], messages[0], @"Message should be equal.");

  [self edo_enqueueMessages:messages forQueue:messageQueue];
  XCTAssertFalse(messageQueue.empty, @"The queue shouldn't be empty.");

  [self edo_assertMessages:messages inOrderForQueue:messageQueue];
  XCTAssertTrue(messageQueue.empty, @"The queue should be empty.");

  XCTestExpectation *waitForThread = [self expectationWithDescription:@"Wait for thread."];
  [NSThread
      detachNewThreadSelector:@selector(edo_executeBlock:)
                     toTarget:self
                   withObject:^{
                     XCTAssertThrows(
                         [messageQueue dequeueMessage],
                         @"It should error when message is dequeued from a different thread.");
                     [waitForThread fulfill];
                   }];
  [messageQueue enqueueMessage:messages[0]];
  [self waitForExpectationsWithTimeout:1 handler:nil];
  XCTAssertFalse(messageQueue.empty, @"The message shouldn't be dequeued from a different thread.");
}

- (void)testEnqueueDequeueInDifferentThread {
  __block EDOMessageQueue<EDOMessage *> *messageQueue = nil;
  NSArray<EDOMessage *> *messages = [self messages];

  dispatch_semaphore_t creationLock = dispatch_semaphore_create(0L);
  XCTestExpectation *waitForThread = [self expectationWithDescription:@"Wait for thread."];
  [NSThread detachNewThreadSelector:@selector(edo_executeBlock:)
                           toTarget:self
                         withObject:^{
                           messageQueue = [[EDOMessageQueue alloc] init];
                           dispatch_semaphore_signal(creationLock);

                           [self edo_assertMessages:messages inOrderForQueue:messageQueue];
                           [waitForThread fulfill];
                         }];
  dispatch_semaphore_wait(creationLock, DISPATCH_TIME_FOREVER);
  [self edo_enqueueMessages:messages forQueue:messageQueue];

  XCTAssertThrows([messageQueue dequeueMessage],
                  @"It should error when message is dequeued from a different thread.");

  [self waitForExpectationsWithTimeout:1 handler:nil];
  XCTAssertTrue(messageQueue.empty, @"The queue should be empty.");
}

- (void)testEnqueueDequeueInDifferentQueue {
  __block EDOMessageQueue<EDOMessage *> *messageQueue = nil;
  NSArray<EDOMessage *> *messages = [self messages];

  dispatch_queue_t queue = dispatch_queue_create("com.google.servicequeue.test", NULL);
  dispatch_semaphore_t creationLock = dispatch_semaphore_create(0L);
  XCTestExpectation *waitForQueue = [self expectationWithDescription:@"Wait for queue."];

  dispatch_async(queue, ^{
    messageQueue = [[EDOMessageQueue alloc] init];
    dispatch_semaphore_signal(creationLock);

    [self edo_assertMessages:messages inOrderForQueue:messageQueue];
    [waitForQueue fulfill];
  });
  dispatch_semaphore_wait(creationLock, DISPATCH_TIME_FOREVER);
  [self edo_enqueueMessages:messages forQueue:messageQueue];

  XCTestExpectation *waitForThread = [self expectationWithDescription:@"Wait for thread."];
  [NSThread detachNewThreadSelector:@selector(edo_executeBlock:)
                           toTarget:self
                         withObject:^{
                           dispatch_sync(queue, ^{
                             [self edo_assertMessages:messages inOrderForQueue:messageQueue];
                           });
                           [waitForThread fulfill];
                         }];

  [self edo_enqueueMessages:messages forQueue:messageQueue];

  XCTAssertThrows([messageQueue dequeueMessage],
                  @"It should error when message is dequeued from a different thread.");

  [self waitForExpectationsWithTimeout:1 handler:nil];
  XCTAssertTrue(messageQueue.empty, @"The queue should be empty.");
}

#pragma mark - Private

- (NSArray<EDOMessage *> *)messages {
  NSMutableArray<EDOMessage *> *messages = [[NSMutableArray alloc] init];
  for (int i = 10; i >= 0; --i) {
    [messages addObject:[[EDOMessage alloc] init]];
  }
  return messages;
}

/** Create a dispatch queue with the current testname. */
- (dispatch_queue_t)testQueue {
  NSString *queueName = [NSString stringWithFormat:@"com.google.edo.MessageQueue[%@]", self.name];
  return dispatch_queue_create(queueName.UTF8String, DISPATCH_QUEUE_SERIAL);
}

- (void)edo_assertMessages:(NSArray<EDOMessage *> *)messages
           inOrderForQueue:(EDOMessageQueue<EDOMessage *> *)messageQueue {
  for (EDOMessage *message in messages) {
    XCTAssertEqual(message, [messageQueue dequeueMessage], @"Message should be dequeued in FIFO.");
  }
}

- (void)edo_enqueueMessages:(NSArray<EDOMessage *> *)messages
                   forQueue:(EDOMessageQueue<EDOMessage *> *)messageQueue {
  for (EDOMessage *message in messages) {
    XCTAssertTrue([messageQueue enqueueMessage:message]);
  }
}

/** Wrap a selector to execute a block. */
- (void)edo_executeBlock:(void (^)(void))block {
  block();
}

@end
