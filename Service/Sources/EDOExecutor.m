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
static const char *_executorKey = "com.google.executorkey";

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

  // 1. Create the waited queue so it can also process the requests while waiting for the response
  // when the incoming request is dispatched to the same queue.
  EDOMessageQueue<EDOExecutorMessage *> *messageQueue = [[EDOMessageQueue alloc] init];

  // Set the message queue to process the request that will be received and dispatched to this
  // queue while waiting for the response to come back.
  dispatch_sync(self.isolationQueue, ^{
    self.messageQueue = messageQueue;
  });

  // 2. Do send.
  NSData *requestData = [NSKeyedArchiver edo_archivedDataWithObject:request];
  [channel sendData:requestData
      withCompletionHandler:^(id<EDOChannel> channel, NSError *error) {
        // TODO(haowoo): Handle errors.
        __block BOOL serviceClosed = NO;
        dispatch_semaphore_t waitLock = dispatch_semaphore_create(0);
        // 3. Check ping response to make sure channel is healthy.
        [channel receiveDataWithHandler:^(id<EDOChannel> _Nonnull channel, NSData *_Nullable data,
                                          NSError *_Nullable error) {
          responseData = data;
          serviceClosed = data == nil;
          dispatch_semaphore_signal(waitLock);
        }];
        // The request is failed if ping message data does not match or it is not received in
        // kPingTimeOutSeconds seconds. When the service is killed, the channel connected to the
        // service may or may not get properly closed. We need to handle 3 cases:
        // (1) request timeout (2) receiving empty data or (3) receiving error response
        long result = dispatch_semaphore_wait(
            waitLock, dispatch_time(DISPATCH_TIME_NOW, kPingTimeoutSeconds));

        // 3.5 Continue to receive the response if the ping is received.
        if ([responseData isEqualToData:EDOExecutor.pingMessageData]) {
          [channel receiveDataWithHandler:^(id<EDOChannel> channel, NSData *data, NSError *error) {
            // TODO(haowoo): Handle errors.
            NSAssert(error == nil, @"Data sent error: %@.", error);
            responseData = data;
            dispatch_semaphore_signal(waitLock);
          }];
          dispatch_semaphore_wait(waitLock, DISPATCH_TIME_FOREVER);
        }

        if (result != 0 || serviceClosed) {
          NSLog(@"The edo channel %@ is broken.", channel);
        }

        // Close the queue because the response is received, the current message queue won't
        // process any new messages.
        [messageQueue closeQueue];
      }];

  // 4. Drain the message queue until the empty message is received - when it errors or the response
  //    data is received.
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
  // TODO(haowoo): Throw an NSInternalInconsistencyException.
  NSAssert(self.trackedQueue != nil, @"The tracked queue is already released.");

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  // TODO(haowoo): Replace with dispatch_assert_queue once the minimum support is iOS 10+.
  NSAssert(dispatch_get_current_queue() != self.trackedQueue,
           @"Only enqueue a request from a non-tracked queue.");
#pragma clang diagnostic pop

  // Health check for the channel.
  [channel sendData:EDOExecutor.pingMessageData withCompletionHandler:nil];

  EDOExecutorMessage *message = [EDOExecutorMessage messageWithRequest:request service:context];
  dispatch_sync(self.isolationQueue, ^{
    EDOMessageQueue<EDOExecutorMessage *> *messageQueue = self.messageQueue;
    if (![messageQueue enqueueMessage:message]) {
      dispatch_async(self.trackedQueue, ^{
        [self edo_handleMessage:message];
      });
    }
  });

  EDOServiceResponse *response = [message waitForResponse];
  NSData *responseData = [NSKeyedArchiver edo_archivedDataWithObject:response];
  [channel sendData:responseData withCompletionHandler:nil];
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

@end
