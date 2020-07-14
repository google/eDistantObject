#import <XCTest/XCTest.h>

#import "Service/Sources/EDOExecutorMessage.h"

@interface EDOExecutorMessageTest : XCTestCase
@end

@implementation EDOExecutorMessageTest

/** Tests EDOExecutorMessage executes initial block. */
- (void)testMessageExecuteBlock {
  __block BOOL executedBlock = NO;
  EDOExecutorMessage *message = [[EDOExecutorMessage alloc] initWithBlock:^{
    executedBlock = YES;
  }];
  [message executeBlock];
  XCTAssertTrue(executedBlock);
}

/** Tests EDOExecutorMessage executes initial block once when being invoked multiple times. */
- (void)testMessageExecuteBlockOnce {
  __block NSUInteger executedTimes = 0;
  EDOExecutorMessage *message = [[EDOExecutorMessage alloc] initWithBlock:^{
    executedTimes++;
  }];
  XCTAssertTrue([message executeBlock]);
  for (int i = 0; i < 100; ++i) {
    XCTAssertFalse([message executeBlock]);
  }
  XCTAssertEqual(executedTimes, 1U);
}

/** Tests EDOExecutorMessage waits the completion until initial block is executed completely. */
- (void)testMessageWaitUntilBlockExecuted {
  XCTestExpectation *beforeInvokeBlockExpectation =
      [self expectationWithDescription:@"wait should not complete before executing block."];
  beforeInvokeBlockExpectation.inverted = YES;
  XCTestExpectation *afterInvokeBlockExpectation =
      [self expectationWithDescription:@"wait should complete after executing block."];
  __block BOOL blockExecuted = NO;
  EDOExecutorMessage *message = [[EDOExecutorMessage alloc] initWithBlock:^{
    blockExecuted = YES;
  }];
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
    [message waitForCompletion];
    if (blockExecuted) {
      [afterInvokeBlockExpectation fulfill];
    } else {
      [beforeInvokeBlockExpectation fulfill];
    }
  });
  [self waitForExpectations:@[ beforeInvokeBlockExpectation ] timeout:1.f];
  [message executeBlock];
  [self waitForExpectations:@[ afterInvokeBlockExpectation ] timeout:1.f];
}

/** Tests EDOExecutorMessage can wait for completion multiple times before executing block. */
- (void)testMessageCanWaitMultipleTimesBeforeComplete {
  const NSUInteger waitTimes = 5;
  XCTestExpectation *startWaitExpectation = [self expectationWithDescription:@"wait start."];
  startWaitExpectation.expectedFulfillmentCount = waitTimes;
  XCTestExpectation *endWaitExpectation = [self expectationWithDescription:@"wait complete."];
  endWaitExpectation.expectedFulfillmentCount = waitTimes;

  EDOExecutorMessage *message = [[EDOExecutorMessage alloc] initWithBlock:^{
  }];
  for (NSUInteger i = 0; i < waitTimes; ++i) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
      [startWaitExpectation fulfill];
      [message waitForCompletion];
      [endWaitExpectation fulfill];
    });
  }
  [self waitForExpectations:@[ startWaitExpectation ] timeout:1.f];
  [message executeBlock];
  [self waitForExpectations:@[ endWaitExpectation ] timeout:1.f];
}

/** Tests EDOExecutorMessage can wait for completion multiple times after executing block. */
- (void)testMessageCanWaitMultipleTimesAfterComplete {
  EDOExecutorMessage *message = [[EDOExecutorMessage alloc] initWithBlock:^{
  }];
  [message executeBlock];

  const NSUInteger waitTimes = 5;
  XCTestExpectation *endWaitExpectation = [self expectationWithDescription:@"wait complete"];
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
    dispatch_apply(waitTimes, DISPATCH_APPLY_AUTO, ^(size_t iteration) {
      [message waitForCompletion];
    });
    [endWaitExpectation fulfill];
  });
  [self waitForExpectations:@[ endWaitExpectation ] timeout:1.f];
}

@end
