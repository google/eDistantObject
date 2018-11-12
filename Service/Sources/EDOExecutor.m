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
#import "Service/Sources/EDOObjectReleaseMessage.h"
#import "Service/Sources/NSKeyedArchiver+EDOAdditions.h"
#import "Service/Sources/NSKeyedUnarchiver+EDOAdditions.h"

// The context key for the executor for the dispatch queue.
static const char *const kExecutorKey = "com.google.executorkey";

// Timeout for ping health check.
static const int64_t kPingTimeoutSeconds = 10 * NSEC_PER_SEC;

@interface EDOExecutor ()
// The message queue to process the requests and responses.
@property EDOMessageQueue<EDOExecutorMessage *> *messageQueue;
// The isolation queue for synchronization.
@property(readonly) dispatch_queue_t isolationQueue;
// The data of ping message for channel health check.
@property(class, readonly) NSData *pingMessageData;
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

    if (queue) {
      dispatch_queue_set_specific(queue, kExecutorKey, (void *)CFBridgingRetain(self),
                                  (dispatch_function_t)CFBridgingRelease);
    }
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
  NSString *className = NSStringFromClass([message.request class]);
  EDORequestHandler handler = self.requestHandlers[className];
  EDOServiceResponse *response = nil;
  if (handler) {
    response = handler(message.request, message.service);
  }

  if (!response) {
    // TODO(haowoo): Define the proper NSError domain, code and error description.
    NSError *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:0 userInfo:nil];
    response = [EDOServiceResponse errorResponse:error forRequest:message.request];
  }

  [message assignResponse:response];
}

#pragma mark - Deprecated methods

// Data to use for health check.
+ (NSData *)pingMessageData {
  static NSData *_pingMessageData;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    _pingMessageData = [@"ping" dataUsingEncoding:NSUTF8StringEncoding];
  });
  return _pingMessageData;
}

+ (instancetype)currentExecutor {
  return (__bridge EDOExecutor *)(dispatch_get_specific(kExecutorKey))
             ?: [[EDOExecutor alloc] initWithHandlers:@{} queue:nil];
}

- (EDOServiceResponse *)sendRequest:(EDOServiceRequest *)request
                        withChannel:(id<EDOChannel>)channel
                              error:(NSError **)errorOrNil {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSAssert(!self.executionQueue || dispatch_get_current_queue() == self.executionQueue,
           @"Only execute the request from the tracked queue.");
#pragma clang diagnostic pop

  __block NSData *responseData = nil;
  NSData *requestData = [NSKeyedArchiver edo_archivedDataWithObject:request];

  [self runUsingMessageQueueCloseHandler:^(EDOMessageQueue<EDOExecutorMessage *> *messageQueue) {
    // The channel is asynchronous and not I/O re-entrant so we chain the sending and receiving,
    // and capture the response in the callback blocks.
    [channel sendData:requestData withCompletionHandler:nil];

    __block BOOL serviceClosed = NO;
    dispatch_semaphore_t waitLock = dispatch_semaphore_create(0);
    EDOChannelReceiveHandler receiveHandler =
        ^(id<EDOChannel> channel, NSData *data, NSError *error) {
          responseData = data;
          serviceClosed = data == nil;
          dispatch_semaphore_signal(waitLock);
        };

    // Check ping response to make sure channel is healthy.
    [channel receiveDataWithHandler:receiveHandler];
    long result =
        dispatch_semaphore_wait(waitLock, dispatch_time(DISPATCH_TIME_NOW, kPingTimeoutSeconds));

    // Continue to receive the response if the ping is received.
    if ([responseData isEqualToData:EDOExecutor.pingMessageData]) {
      [channel receiveDataWithHandler:receiveHandler];
      dispatch_semaphore_wait(waitLock, DISPATCH_TIME_FOREVER);
    }

    if (result != 0 || serviceClosed) {
      NSLog(@"The edo channel %@ is broken.", channel);
    }

    [messageQueue closeQueue];
  }];

  EDOServiceResponse *response;
  if (responseData) {
    response = [NSKeyedUnarchiver edo_unarchiveObjectWithData:responseData];
    NSAssert([request.messageId isEqualToString:response.messageId],
             @"The response (%@) Id is mismatched with the request (%@)", response, request);
  } else {
    if (errorOrNil) {
      // TODO(ynzhang): Add better error code define.
      *errorOrNil = [NSError errorWithDomain:NSPOSIXErrorDomain code:0 userInfo:nil];
    }
  }

  return response;
}

- (void)receiveRequest:(EDOServiceRequest *)request
           withChannel:(id<EDOChannel>)channel
               context:(id)context {
  // Health check for the channel.
  [channel sendData:EDOExecutor.pingMessageData withCompletionHandler:nil];

  EDOServiceResponse *response = [self handleRequest:request context:context];

  NSData *responseData = [NSKeyedArchiver edo_archivedDataWithObject:response];
  [channel sendData:responseData withCompletionHandler:nil];
}

@end
