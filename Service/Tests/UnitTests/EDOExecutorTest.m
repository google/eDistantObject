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

#import <OCMock/OCMock.h>
#import <XCTest/XCTest.h>

#import "Channel/Sources/EDOSocket.h"
#import "Channel/Sources/EDOSocketChannel.h"
#import "Service/Sources/EDOExecutor.h"
#import "Service/Sources/EDOServiceRequest.h"

@interface EDOExecutorTest : XCTestCase
@property(weak) id weakHolder;
@end

@implementation EDOExecutorTest

- (void)testWeakTrackQueue {
  __weak EDOExecutor *weakExecutor = nil;
  @autoreleasepool {
    dispatch_queue_t queue =
        dispatch_queue_create("com.google.edo.released", DISPATCH_QUEUE_SERIAL);
    @autoreleasepool {
      EDOExecutor *executor = [EDOExecutor associateExecutorWithHandlers:@{} queue:queue];
      dispatch_sync(queue, ^{
        XCTAssertEqual(executor, [EDOExecutor currentExecutor], @"The executor is not set.");
      });
      weakExecutor = executor;
    }

    XCTAssertNotNil(weakExecutor, @"The executor should not be released.");

    __block EDOExecutor *executor = nil;
    dispatch_sync(queue, ^{
      executor = [EDOExecutor currentExecutor];
      XCTAssertNotNil(executor, @"The executor should exist.");
      XCTAssertEqual(executor, weakExecutor,
                     @"The executor should be the same as initial associated.");
    });

    queue = nil;
    // Internal trackedQueue should become nil once the queue is set to nil.
    [self expectationForPredicate:[NSPredicate predicateWithFormat:@"trackedQueue == nil"]
              evaluatedWithObject:executor
                          handler:nil];
    [self waitForExpectationsWithTimeout:2 handler:nil];

    id<EDOChannel> channel = nil;
    XCTAssertThrows([executor receiveRequest:[[EDOServiceRequest alloc] init]
                                 withChannel:channel
                                     context:nil]);

    weakExecutor = executor;
  }
  self.weakHolder = weakExecutor;
  [self expectationForPredicate:[NSPredicate predicateWithFormat:@"weakHolder == nil"]
            evaluatedWithObject:self
                        handler:nil];
  [self waitForExpectationsWithTimeout:2 handler:nil];
  XCTAssertNil(weakExecutor, @"The executor should be released after the dispatch queue is gone.");
}

- (void)testNilAndNonNilContext {
  // TODO(haowoo): Fill this test.
}

- (void)testSendAndReceiveResponse {
  NSError *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:100 userInfo:nil];
  EDORequestHandler requestHandler = ^(EDOServiceRequest *request, EDOHostService *service) {
    return [EDOServiceResponse errorResponse:error forRequest:request];
  };
  NSDictionary *handlers = @{@"EDOServiceRequest" : requestHandler};

  NS_VALID_UNTIL_END_OF_SCOPE dispatch_queue_t queue =
      [self edo_setupDispatchQueueWithPort:1234 handlers:handlers];

  XCTestExpectation *expectExecuted = [self expectationWithDescription:@"Executed the block."];
  [self edo_testClientExecutorWithPort:1234
                              handlers:handlers
                                 block:^(EDOExecutor *executor, id<EDOChannel> channel) {
                                   EDOServiceResponse *response =
                                       [executor sendRequest:[[EDOServiceRequest alloc] init]
                                                 withChannel:channel
                                                       error:nil];
                                   XCTAssertEqual(executor, [EDOExecutor currentExecutor],
                                                  @"The executor is not matched.");
                                   XCTAssertEqual(response.error.code, 100,
                                                  @"The response error code is not matched.");
                                   XCTAssertNotEqual(response.error, error,
                                                     @"The response should be serialized.");
                                   [expectExecuted fulfill];
                                 }];
  [self waitForExpectationsWithTimeout:1 handler:nil];
}

- (void)testMultiplexSendAndReceiveResponse {
  EDOServiceRequest *oneRequest = [[EDOServiceRequest alloc] init];
  NS_VALID_UNTIL_END_OF_SCOPE __block dispatch_queue_t queue1 = nil;
  NS_VALID_UNTIL_END_OF_SCOPE __block dispatch_queue_t queue2 = nil;

  NSError *error1 = [NSError errorWithDomain:NSPOSIXErrorDomain code:100 userInfo:nil];
  NSError *error2 = [NSError errorWithDomain:NSPOSIXErrorDomain code:200 userInfo:nil];

  EDORequestHandler requestHandler1 = ^(EDOServiceRequest *request, EDOHostService *service) {
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_10_0
    dispatch_assert_queue(queue1);
#endif

    __block EDOSocketChannel *channel = nil;
    dispatch_semaphore_t waitLock = dispatch_semaphore_create(0L);
    [EDOSocket connectWithTCPPort:1235
                            queue:nil
                   connectedBlock:^(EDOSocket *socket, UInt16 listenPort, NSError *error) {
                     channel = [EDOSocketChannel channelWithSocket:socket listenPort:1235];
                     dispatch_semaphore_signal(waitLock);
                   }];
    dispatch_semaphore_wait(waitLock, dispatch_time(DISPATCH_TIME_NOW, 1e9L));

    EDOExecutor *executor = [EDOExecutor currentExecutor];
    XCTAssertNotNil(executor, @"The executor is not set up.");

    // Execute the request on queue1 synchronously while on queue2, it is waiting for this
    // response to complete.
    EDOServiceResponse *response = [executor sendRequest:request withChannel:channel error:nil];
    XCTAssertEqual(response.error.code, 200, @"The response error code is not matched.");
    return [EDOServiceResponse errorResponse:error1 forRequest:request];
  };

  EDORequestHandler requestHandler2 = ^(EDOServiceRequest *request, EDOHostService *service) {
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_10_0
    dispatch_assert_queue(queue2);
#endif
    return [EDOServiceResponse errorResponse:error2 forRequest:request];
  };

  NSDictionary *handlers1 = @{@"EDOServiceRequest" : requestHandler1};
  NSDictionary *handlers2 = @{@"EDOServiceRequest" : requestHandler2};

  queue1 = [self edo_setupDispatchQueueWithPort:1234 handlers:handlers1];
  queue2 = [self edo_setupDispatchQueueWithPort:1235 handlers:handlers2];

  XCTestExpectation *expectExecuted = [self expectationWithDescription:@"Executed the block."];
  [EDOSocket
      connectWithTCPPort:1234
                   queue:nil
          connectedBlock:^(EDOSocket *socket, UInt16 listenPort, NSError *error) {
            EDOSocketChannel *channel = [EDOSocketChannel channelWithSocket:socket listenPort:1234];
            dispatch_sync(queue2, ^{
              EDOExecutor *executor = [EDOExecutor currentExecutor];
              XCTAssertNotNil(executor, @"The executor is not set up.");

              EDOServiceResponse *response = [executor sendRequest:oneRequest
                                                       withChannel:channel
                                                             error:nil];
              XCTAssertEqual(response.error.code, 100, @"The response error code is not matched.");
            });
            [expectExecuted fulfill];
          }];

  [self waitForExpectationsWithTimeout:1 handler:nil];
}

- (void)testSendAndReceiveNestedLoop {
  // TODO(haowoo): Test the nested executor loop.
}

- (void)testSendRequestToInvalidChannel {
  EDORequestHandler requestHandler = ^(EDOServiceRequest *request, EDOHostService *service) {
    return [EDOServiceResponse errorResponse:nil forRequest:request];
  };
  NSDictionary *handlers = @{@"EDOServiceRequest" : requestHandler};

  NS_VALID_UNTIL_END_OF_SCOPE dispatch_queue_t queue =
      [self edo_setupDispatchQueueWithPort:1234 handlers:handlers];

  XCTestExpectation *expectExecuted = [self expectationWithDescription:@"Executed the block."];
  [self edo_testClientExecutorWithPort:1234
                              handlers:handlers
                                 block:^(EDOExecutor *executor, id<EDOChannel> channel) {
                                   EDOSocketChannel *mockChannel = OCMPartialMock(channel);
                                   OCMStub([mockChannel receiveDataWithHandler:OCMOCK_ANY]);
                                   NSError *channelError = nil;
                                   [executor sendRequest:[[EDOServiceRequest alloc] init]
                                             withChannel:mockChannel
                                                   error:&channelError];
                                   XCTAssertNotNil(channelError);
                                   [expectExecuted fulfill];
                                 }];
  [self waitForExpectationsWithTimeout:15 handler:nil];
}

#pragma mark - Private

- (dispatch_queue_t)edo_setupDispatchQueueWithPort:(UInt16)port handlers:(NSDictionary *)handlers {
  NSString *queueName = [NSString stringWithFormat:@"com.google.edo.test.executor.host.%d", port];
  __block dispatch_queue_t queue =
      dispatch_queue_create(queueName.UTF8String, DISPATCH_QUEUE_SERIAL);
  EDOExecutor *hostExecutor = [EDOExecutor associateExecutorWithHandlers:handlers queue:queue];
  dispatch_sync(queue, ^{
    XCTAssertEqual(hostExecutor, [EDOExecutor currentExecutor], @"The executor is not set.");
  });

  __block EDOSocket *listenSocket = nil;
  listenSocket = [EDOSocket
      listenWithTCPPort:port
                  queue:nil
         connectedBlock:^(EDOSocket *socket, UInt16 listenPort, NSError *error) {
           EDOSocketChannel *channel = [EDOSocketChannel channelWithSocket:socket listenPort:port];

           [channel receiveDataWithHandler:^(id<EDOChannel> channel, NSData *data, NSError *error) {
             if (data != nil) {
               EDOServiceRequest *request = [NSKeyedUnarchiver unarchiveObjectWithData:data];
               [hostExecutor receiveRequest:request withChannel:channel context:nil];
             }
           }];

           // Keep track of this to retain it.
           listenSocket = nil;
         }];
  return queue;
}

- (void)edo_testClientExecutorWithPort:(UInt16)port
                              handlers:(NSDictionary *)handlers
                                 block:(void (^)(EDOExecutor *, id<EDOChannel>))block {
  dispatch_queue_t clientQueue =
      dispatch_queue_create("com.google.edo.test.executor.client", DISPATCH_QUEUE_SERIAL);
  EDOExecutor *clientExecutor = [EDOExecutor associateExecutorWithHandlers:handlers
                                                                     queue:clientQueue];
  dispatch_sync(clientQueue, ^{
    XCTAssertEqual(clientExecutor, [EDOExecutor currentExecutor], @"The executor is not set.");
  });

  [EDOSocket connectWithTCPPort:port
                          queue:nil
                 connectedBlock:^(EDOSocket *socket, UInt16 listenPort, NSError *error) {
                   EDOSocketChannel *channel = [EDOSocketChannel channelWithSocket:socket
                                                                        listenPort:port];
                   dispatch_sync(clientQueue, ^{
                     block(clientExecutor, channel);
                   });
                 }];
}

@end
