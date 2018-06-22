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
#import "Service/Sources/EDOMessage.h"
#import "Service/Sources/EDOMessageQueue.h"
#import "Service/Sources/EDOObjectReleaseMessage.h"

// The context key for the executor for the dispatch queue.
static const char *_executorKey = "com.google.executorkey";

// Timeout for ping health check.
static const int64_t kPingTimeoutSeconds = 10 * NSEC_PER_SEC;

@interface EDOExecutor ()
// The message queue to process the requests and responses.
@property EDOMessageQueue *messageQueue;
// The isolation queue for synchronization.
@property(readonly) dispatch_queue_t isolationQueue;
// The data of ping message for channel health check.
@property(class, readonly) NSData *pingMessageData;
@end

@implementation EDOExecutor

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
    _trackedQueue = queue;
    _requestHandlers = handlers;

    if (queue) {
      dispatch_queue_set_specific(queue, _executorKey, (void *)CFBridgingRetain(self),
                                  (dispatch_function_t)CFBridgingRelease);
    }
  }
  return self;
}

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
  return (__bridge EDOExecutor *)(dispatch_get_specific(_executorKey))
             ?: [[EDOExecutor alloc] initWithHandlers:@{} queue:nil];
}

+ (instancetype)associateExecutorWithHandlers:(EDORequestHandlers *)handlers
                                        queue:(dispatch_queue_t)queue {
  return [[self alloc] initWithHandlers:handlers queue:queue];
}

- (EDOServiceResponse *)sendRequest:(EDOServiceRequest *)request
                        withChannel:(id<EDOChannel>)channel
                              error:(NSError **)errorOrNil {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSAssert(!self.trackedQueue || dispatch_get_current_queue() == self.trackedQueue,
           @"Only execute the request from the tracked queue.");
#pragma clang diagnostic pop

  __block NSData *responseData = nil;
  __block BOOL responseReceived = NO;
  __block NSException *exception = nil;

  // 1. Create the waited queue so it can also process the requests while waiting for the response
  // when the incoming request is dispatched to this same queue.
  EDOMessageQueue *messageQueue = [[EDOMessageQueue alloc] init];

  // 2. Do send.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  // TODO(b/112517451): Support eDO with iOS 12.
  NSData *requestData = [NSKeyedArchiver archivedDataWithRootObject:request];
#pragma clang diagnostic pop
  [channel sendData:requestData
      withCompletionHandler:^(id<EDOChannel> channel, NSError *error) {
        // TODO(haowoo): Handle errors.
        __block BOOL serviceClosed = NO;
        dispatch_semaphore_t waitLock = dispatch_semaphore_create(0);
        // 2.5 Check ping response to make sure channel is healthy.
        [channel receiveDataWithHandler:^(id<EDOChannel> _Nonnull channel, NSData *_Nullable data,
                                          NSError *_Nullable error) {
          // TODO(ynzhang): the data could be error response with more details.
          // We should log the details when we have better error handling.
          if (![data isEqualToData:EDOExecutor.pingMessageData]) {
            // If the handler is triggered but data is nil or does not match ping message data, it
            // indicates that the channel is closed from the other side.
            serviceClosed = YES;
          }
          dispatch_semaphore_signal(waitLock);
        }];
        // The channel is broken if ping message data does not match or it is not received in
        // kPingTimeOutSeconds seconds. When the service is killed, the channel connected to the
        // service may or may not get properly closed. We need to handle both cases:
        // (1) request timeout or (2) receiving empty data.
        long result = dispatch_semaphore_wait(
            waitLock, dispatch_time(DISPATCH_TIME_NOW, kPingTimeoutSeconds));
        if (result != 0 || serviceClosed) {
          NSLog(@"The edo channel %@ is broken.", channel);
          // Reset the message queue after receiving the response in the handler (the handler is not
          // reentrant to assure the data integrity).
          dispatch_sync(self.isolationQueue, ^{
            responseReceived = YES;
            self.messageQueue = nil;
          });
          [messageQueue enqueueMessage:@[]];
          return;
        }

        // 3. Ready to receive the response.
        [channel receiveDataWithHandler:^(id<EDOChannel> channel, NSData *data, NSError *error) {
          // TODO(haowoo): Handle errors.
          NSAssert(error == nil, @"Data sent errors.");

          // Reset the message queue after receiving the response in the handler (the handler is not
          // reentrant to assure the data integrity.)
          dispatch_sync(self.isolationQueue, ^{
            responseReceived = YES;
            self.messageQueue = nil;
          });

          responseData = data;

          // Enqueue the placeholder of empty array for the expected response, so the message queue
          // can be awakened.
          [messageQueue enqueueMessage:@[]];
        }];
      }];

  // 4. Drain the message queue until the empty message is received - when it errors or the response
  //    data is received.
  EDOServiceResponse *response = nil;
  NSArray *messages = nil;
  while (true) {
    // Before suspending the dispatch queue, set the message queue so when the request is received
    // and dispatched to this queue, it can be woken up.
    // Note: this message queue can be reset in a nested handling loop, and we only need to make
    // sure we have a message queue to process the requests before the dispatch queue gets blocked.
    dispatch_sync(self.isolationQueue, ^{
      // Only set the message queue when the response hasn't been received for this loop. It may be
      // already reset right after handling the inner loop and before this line is executed.
      if (!responseReceived) {
        self.messageQueue = messageQueue;
      }
    });

    // Block the current queue and wait for the new message. It will unset the
    // messageQueue if it receives a response so there is no race condition where it has some
    // messages left in the queue to be processed after the queue is unset.
    messages = [messageQueue dequeueMessage];
    if (messages.count > 0) {
      NSAssert([messages[0] isKindOfClass:[EDOServiceRequest class]],
               @"The message can only be EDOServiceRequest.");
      // The exception needs to be raised here (in case there's any) to make sure it runs in the
      // same queue that runs the method. Previously it was being thrown on the channel callback
      // which was unable to be caught from the test.
      [exception raise];
      NSAssert(messages.count == 3 || messages.count == 4,
               @"The message can be either two elements or three elements with a context.");

      // [0]: the request; [1]: the channel; [2]: the context [3]: the wait lock of receiving data.
      [self edo_handleRequest:(EDOServiceRequest *)messages[0]
                  withChannel:messages[1]
                      context:(messages.count > 3 ? messages[3] : nil)];
      dispatch_semaphore_signal(messages[2]);
    } else {
      // Dequeued the placeholder of empty array, exit the loop and return.
      NSAssert(messageQueue.empty, @"The message queue contains stale requests.");
      NSAssert(messageQueue != self.messageQueue, @"The message queue should be untracked.");
      NSAssert(responseReceived, @"The response should be received.");

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      // TODO(b/112517451): Support eDO with iOS 12.
      response = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];
#pragma clang diagnostic pop
      break;
    }
  }

  if (!response) {
    if (errorOrNil) {
      // TODO(ynzhang): Add better error code define.
      *errorOrNil = [NSError errorWithDomain:NSPOSIXErrorDomain code:0 userInfo:nil];
    }
  } else {
    NSAssert([request.messageId isEqualToString:response.messageId],
             @"The response (%@) Id is mismatched with the request (%@)", response, request);
  }

  return response;
}

- (void)receiveRequest:(EDOServiceRequest *)request
           withChannel:(id<EDOChannel>)channel
               context:(id)context {
  // TODO(haowoo): throw an NSInternalInconsistencyException
  NSAssert(self.trackedQueue != nil, @"The tracked queue is already released.");

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSAssert(dispatch_get_current_queue() != self.trackedQueue,
           @"Only enqueue a request from a non-tracked queue.");
#pragma clang diagnostic pop
  dispatch_semaphore_t waitLock = dispatch_semaphore_create(0);
  dispatch_sync(self.isolationQueue, ^{
    EDOMessageQueue *messageQueue = self.messageQueue;
    if (messageQueue) {
      NSArray *message =
          context ? @[ request, channel, waitLock, context ] : @[ request, channel, waitLock ];
      [messageQueue enqueueMessage:message];
    } else {
      dispatch_async(self.trackedQueue, ^{
        [self edo_handleRequest:request withChannel:channel context:context];
        dispatch_semaphore_signal(waitLock);
      });
    }
  });
  // the semaphore will be signaled in edo_handleRequest either directly or after dequeue.
  dispatch_semaphore_wait(waitLock, DISPATCH_TIME_FOREVER);
}

#pragma mark - Private

/** Handle the request and send the response back to the @c channel. */
- (void)edo_handleRequest:(EDOServiceRequest *)request
              withChannel:(id<EDOChannel>)channel
                  context:(id)context {
  // Health check for the channel.
  [channel sendData:EDOExecutor.pingMessageData withCompletionHandler:nil];

  NSString *className = NSStringFromClass([request class]);
  EDORequestHandler handler = self.requestHandlers[className];
  EDOServiceResponse *response = nil;
  if (handler) {
    response = handler(request, context);
  }

  if (!response) {
    // TODO(haowoo): Define the proper NSError domain, code and error description.
    NSError *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:0 userInfo:nil];
    response = [EDOServiceResponse errorResponse:error forRequest:request];
  }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  // TODO(b/112517451): Support eDO with iOS 12.
  NSData *responseData = [NSKeyedArchiver archivedDataWithRootObject:response];
#pragma clang diagnostic pop
  // TODO(haowoo): Handle the response error (should just log and ignore safely).
  [channel sendData:responseData withCompletionHandler:nil];
}

@end
