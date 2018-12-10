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

#import "Service/Sources/EDOExecutor.h"
#import "Service/Sources/EDOServiceRequest.h"

@interface EDOExecutorTest : XCTestCase
@end

@implementation EDOExecutorTest

- (void)testExecutorHandleMessageAndContext {
  NSObject *context = [[NSObject alloc] init];
  dispatch_queue_t queue = [self testQueue];
  EDOExecutor *executor = [self executorWithQueue:queue context:context];

  [self verifyResponse:[executor handleRequest:[[EDOServiceRequest alloc] init] context:context]];
}

- (void)testExecutorNotRunningToHandleMessageWithoutQueue {
  EDOExecutor *executor = [self executorWithQueue:nil context:nil];

  XCTAssertThrowsSpecificNamed([executor handleRequest:[[EDOServiceRequest alloc] init]
                                               context:nil],
                               NSException, NSInternalInconsistencyException);
}

- (void)testExecutorNotRunningToHandleMessageWithQueue {
  dispatch_queue_t queue = [self testQueue];
  EDOExecutor *executor = [self executorWithQueue:queue context:nil];

  [self verifyResponse:[executor handleRequest:[[EDOServiceRequest alloc] init] context:nil]];
}

- (void)testExecutorRecordProcessTime {
  dispatch_queue_t queue = [self testQueue];
  EDOExecutor *executor = [self executorWithQueue:queue context:nil delay:1];

  EDOServiceResponse *response = [executor handleRequest:[[EDOServiceRequest alloc] init]
                                                 context:nil];
  [self verifyResponse:response];
  // Assert the duration is within the reasonable range [1000ms, 1500ms].
  XCTAssertTrue(response.duration >= 1000 && response.duration <= 1500);
}

- (void)testExecutorFinishRunningAfterClosingMessageQueue {
  dispatch_queue_t queue = [self testQueue];
  EDOExecutor *executor = [self executorWithQueue:queue context:nil];

  XCTestExpectation *expectFinish = [self expectationWithDescription:@"The executor is finished."];
  dispatch_async(queue, ^{
    [executor
        runUsingMessageQueueCloseHandler:^(EDOMessageQueue<EDOExecutorMessage *> *messageQueue) {
          [messageQueue closeQueue];
        }];
    // Only fulfills the exepectation after the executor finishes the run.
    [expectFinish fulfill];
  });

  [self waitForExpectationsWithTimeout:1 handler:nil];
}

- (void)testExecutorIsRunningToHandleMessage {
  dispatch_queue_t queue = [self testQueue];
  EDOExecutor *executor = [self executorWithQueue:queue context:nil];

  XCTestExpectation *expectRun = [self expectationWithDescription:@"The executor is running."];
  dispatch_async(queue, ^{
    [executor
        runUsingMessageQueueCloseHandler:^(EDOMessageQueue<EDOExecutorMessage *> *messageQueue) {
          [expectRun fulfill];
        }];
  });

  [self waitForExpectationsWithTimeout:1 handler:nil];
  [self verifyResponse:[executor handleRequest:[[EDOServiceRequest alloc] init] context:nil]];
}

- (void)testExecutorHandleMessageAfterClosingQueue {
  dispatch_queue_t queue = [self testQueue];
  EDOExecutor *executor = [self executorWithQueue:queue context:nil];

  XCTestExpectation *expectClose = [self expectationWithDescription:@"The queue is closed."];
  dispatch_async(queue, ^{
    [executor
        runUsingMessageQueueCloseHandler:^(EDOMessageQueue<EDOExecutorMessage *> *messageQueue) {
          [messageQueue closeQueue];
          [expectClose fulfill];
        }];
  });

  [self waitForExpectationsWithTimeout:1 handler:nil];
  [self verifyResponse:[executor handleRequest:[[EDOServiceRequest alloc] init] context:nil]];
}

- (void)testSendRequestWithExecutorProcessingStressfully {
  NS_VALID_UNTIL_END_OF_SCOPE dispatch_queue_t queue = [self testQueue];
  EDOExecutor *executor = [self executorWithQueue:queue context:nil];

  XCTestExpectation *expectFinish = [self expectationWithDescription:@"The executor is finished."];
  expectFinish.expectedFulfillmentCount = 3;
  NSInteger numRuns = 1000;
  dispatch_async(queue, ^{
    for (NSInteger i = 0; i < numRuns; ++i) {
      [executor
          runUsingMessageQueueCloseHandler:^(EDOMessageQueue<EDOExecutorMessage *> *messageQueue) {
            [messageQueue closeQueue];
          }];
    }
    [expectFinish fulfill];
  });

  // Generate requests from differnt QoS queues so it can cover cases:
  // 1. the request is received before the executor starts
  // 2. the request is received after the executor starts but before the while-loop starts
  // 3. the request is received after the while-loop tarts.
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
    for (NSInteger i = 0; i < numRuns; ++i) {
      [self verifyResponse:[executor handleRequest:[[EDOServiceRequest alloc] init] context:nil]];
    }
    [expectFinish fulfill];
  });
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
    for (NSInteger i = 0; i < numRuns; ++i) {
      [self verifyResponse:[executor handleRequest:[[EDOServiceRequest alloc] init] context:nil]];
    }
    [expectFinish fulfill];
  });
  [self waitForExpectationsWithTimeout:0.1 * numRuns handler:nil];
}

#pragma mark - Test helper methods

/** Create an executor to handle an EDOServiceResponse. */
- (EDOExecutor *)executorWithQueue:(dispatch_queue_t)queue context:(id)context {
  return [self executorWithQueue:queue context:context delay:0];
}

/** Create an executor to delay @c seconds to handle an EDOServiceResponse. */
- (EDOExecutor *)executorWithQueue:(dispatch_queue_t)queue context:(id)context delay:(int)seconds {
  NSError *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:100 userInfo:nil];
  EDORequestHandler requestHandler = ^(EDOServiceRequest *request, id handlerContext) {
    XCTAssertEqual(context, handlerContext);
    sleep(seconds);
    return [EDOServiceResponse errorResponse:error forRequest:request];
  };
  return [EDOExecutor executorWithHandlers:@{@"EDOServiceRequest" : requestHandler} queue:queue];
}

- (void)verifyResponse:(EDOServiceResponse *)response {
  XCTAssertEqual(response.error.code, 100);
  XCTAssertEqualObjects(response.error.domain, NSPOSIXErrorDomain);
}

/** Create a dispatch queue with the current testname. */
- (dispatch_queue_t)testQueue {
  NSString *queueName = [NSString stringWithFormat:@"com.google.edo.Executor[%@]", self.name];
  return dispatch_queue_create(queueName.UTF8String, DISPATCH_QUEUE_SERIAL);
}

@end
