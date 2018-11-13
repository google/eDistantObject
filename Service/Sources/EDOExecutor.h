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

#import <Foundation/Foundation.h>

#import "Service/Sources/EDOMessageQueue.h"
#import "Service/Sources/EDOServiceRequest.h"

NS_ASSUME_NONNULL_BEGIN

@class EDOExecutorMessage;
@protocol EDOChannel;

/** The request handlers from the class name to the handler block. */
typedef NSDictionary<NSString *, EDORequestHandler> EDORequestHandlers;

/**
 *  The handler to close the message queue and exit the while-loop of the executor.
 *
 *  Before the executor starts the while-loop, it schedules the handler in the background queue
 *  with the message queue. This message queue can be closed and the while-loop exits.
 *  @param messageQueue The message queue used to process the messages of the executor.
 */
typedef void (^EDOExecutorCloseHandler)(EDOMessageQueue<EDOExecutorMessage *> *messageQueue);

/**
 *  The executor to handle the requests.
 *
 *  The executor is running a while-loop and handling the requests using the message queue. The
 *  closeHandler is used to close the message queue and thus stops the executor to run. When the
 *  request is to be handled by the executor, it will enqueue the request to the message queue,
 *  which will be picked up by the executor when it is running a while-loop; if it is not running
 *  a while-loop, it will be dispatch to the execution queue to process it.
 */
@interface EDOExecutor : NSObject

/** The dispatch queue to handle the request if it is not running. */
@property(readonly, nonatomic, weak) dispatch_queue_t executionQueue;

/** The request handlers. */
@property(readonly, nonatomic) EDORequestHandlers *requestHandlers;

- (instancetype)init NS_UNAVAILABLE;

/**
 *  Creates the executor with the given dispatch queue.
 *
 *  The executor will keep track of the dispatch queue weakly, and assigned itself to its context
 *  under the key "com.google.executorkey"; the dispatch queue holds its reference so it shares the
 *  same lifecycle as the queue (you can safely discard the returned value).
 *
 *  @remark If the dispatch queue is already assigned one executor, it will be replaced.
 *  @param handlers The request handler map.
 *  @param queue    The dispatch queue to associate with the executor.
 *
 *  @return The @c EDOExecutor associated with the dispatch queue.
 */
+ (instancetype)executorWithHandlers:(EDORequestHandlers *)handlers
                               queue:(nullable dispatch_queue_t)queue;

/**
 *  Runs the while-loop to handle requests from the message queue synchronously.
 *
 *  @note The executor will continue to wait on the messages until the close handler closes the
 *        message queue given in the handler.
 *  @param closeHandler The handler to close the message queue. The handler will be scheduled on
 *                      the background queue before the while-loop starts.
 */
- (void)runUsingMessageQueueCloseHandler:(EDOExecutorCloseHandler)closeHandler;

/**
 *  Handles the request at once with the given context.
 *
 *  @note If the executor is running the while-loop, the request will be enqueued to process,
 *        or it will dispatch to the @c executionQueue to process.
 *  @param request The request to handle.
 *  @param context The context that will be passed to the handler along with the request.
 *
 *  @return The response for the given request.
 */
- (EDOServiceResponse *)handleRequest:(EDOServiceRequest *)request context:(nullable id)context;

@end

NS_ASSUME_NONNULL_END
