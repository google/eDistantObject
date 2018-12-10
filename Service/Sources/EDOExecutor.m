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

#import "Service/Sources/EDOExecutor.h"

#import "Channel/Sources/EDOChannel.h"
#import "Service/Sources/EDOExecutorMessage.h"
#import "Service/Sources/EDOMessage.h"
#import "Service/Sources/EDOMessageQueue.h"
#import "Service/Sources/EDOTimingFunctions.h"

@interface EDOExecutor ()
// The message queue to process the requests and responses.
@property EDOMessageQueue<EDOExecutorMessage *> *messageQueue;
// The isolation queue for synchronization.
@property(readonly) dispatch_queue_t isolationQueue;
@end

@implementation EDOExecutor

+ (instancetype)executorWithHandlers:(EDORequestHandlers *)handlers queue:(dispatch_queue_t)queue {
  return [[self alloc] initWithHandlers:handlers queue:queue];
}

/**
 *  Initialize with the request @c handlers for the dispatch @c queue.
 *
 *  The executor is associated with the dispatch queue and saved to its context. It shares the same
 *  life cycle as the dispatch queue and it only holds the weak reference of the designated queue.
 *
 *  @param handlers The request handlers.
 *  @param queue The dispatch queue to associate with the executor.
 */
- (instancetype)initWithHandlers:(EDORequestHandlers *)handlers queue:(dispatch_queue_t)queue {
  self = [super init];
  if (self) {
    NSString *queueName = [NSString stringWithFormat:@"com.google.edo.executor[%p]", self];
    _isolationQueue = dispatch_queue_create(queueName.UTF8String, DISPATCH_QUEUE_SERIAL);
    _executionQueue = queue;
    _requestHandlers = handlers;
  }
  return self;
}

- (void)runUsingMessageQueueCloseHandler:(EDOExecutorCloseHandler)closeHandler {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSAssert(!self.executionQueue || dispatch_get_current_queue() == self.executionQueue,
           @"Only run the executor from the tracked queue.");
#pragma clang diagnostic pop

  // Create the waited queue so it can also process the requests while waiting for the response
  // when the incoming request is dispatched to the same queue.
  EDOMessageQueue<EDOExecutorMessage *> *messageQueue = [[EDOMessageQueue alloc] init];

  // Set the message queue to process the request that will be received and dispatched to this
  // queue while waiting for the response to come back.
  dispatch_sync(self.isolationQueue, ^{
    self.messageQueue = messageQueue;
  });

  // Schedule the handler in the background queue so it won't block the current thread. After the
  // handler closes the messageQueue, before or after the while loop starts, it will trigger the
  // while loop to exit.
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    closeHandler(messageQueue);
  });

  while (true) {
    // Block the current queue and wait for the new message. It will unset the
    // messageQueue if it receives a response so there is no race condition where it has some
    // messages left in the queue to be processed after the queue is unset.
    EDOExecutorMessage *message = [messageQueue dequeueMessage];
    if (!message) {
      break;
    }

    [self edo_handleMessage:message];

    // Reset the message queue in case that the nested invocation in -[edo_handleMessage:] clears
    // it after its handling.
    // Note: We only need to make sure the message queue can process any nested request, which shall
    //       come before the response is received. If any request comes after the response is
    //       received, this request will be dispatched async'ly.
    dispatch_sync(self.isolationQueue, ^{
      self.messageQueue = messageQueue;
    });
  }

  NSAssert(messageQueue.empty, @"The message queue contains stale requests.");
}

- (EDOServiceResponse *)handleRequest:(EDOServiceRequest *)request context:(id)context {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  // TODO(haowoo): Replace with dispatch_assert_queue once the minimum support is iOS 10+.
  NSAssert(dispatch_get_current_queue() != self.executionQueue,
           @"Only enqueue a request from a non-tracked queue.");
#pragma clang diagnostic pop

  __block BOOL messageHandled = YES;
  EDOExecutorMessage *message = [EDOExecutorMessage messageWithRequest:request service:context];
  dispatch_sync(self.isolationQueue, ^{
    EDOMessageQueue<EDOExecutorMessage *> *messageQueue = self.messageQueue;
    if (![messageQueue enqueueMessage:message]) {
      dispatch_queue_t executionQueue = self.executionQueue;
      if (executionQueue) {
        dispatch_async(self.executionQueue, ^{
          [self edo_handleMessage:message];
        });
      } else {
        messageHandled = NO;
      }
    }
  });

  // Assertion outside the dispatch queue in order to populate the exceptions.
  NSAssert(messageHandled,
           @"The message is not handled because the execution queue is already released.");
  return [message waitForResponse];
}

#pragma mark - Private

/** Handle the request and set the response for the @c message. */
- (void)edo_handleMessage:(EDOExecutorMessage *)message {
  // The handler mapping from the request class name to the handler block.
  NSString *className = NSStringFromClass([message.request class]);
  EDORequestHandler handler = self.requestHandlers[className];
  EDOServiceResponse *response = nil;
  if (handler) {
    uint64_t currentTime = mach_absolute_time();
    response = handler(message.request, message.service);
    response.duration = EDOGetMillisecondsSinceMachTime(currentTime);
  }

  if (!response) {
    // TODO(haowoo): Define the proper NSError domain, code and error description.
    NSError *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:0 userInfo:nil];
    response = [EDOServiceResponse errorResponse:error forRequest:message.request];
  }

  [message assignResponse:response];
}

@end
