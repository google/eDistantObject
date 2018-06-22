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

#import "Service/Sources/EDOServiceRequest.h"

NS_ASSUME_NONNULL_BEGIN

@protocol EDOChannel;

/** The request handlers from the class name to the handler block */
typedef NSDictionary<NSString *, EDORequestHandler> EDORequestHandlers;

/**
 *  The invocation executor associated with the dispatch queue.
 *
 *  The @c EDOExecutor is associated with the dispatch queue where the @c EDOObject will run.
 *  A remote request can be sent out synchronously through the executor in the tracked queue.
 *  The executor will keep looping and process incoming requests with attached handlers when it is
 *  sending a remote invocation and being suspended for the response.
 */
@interface EDOExecutor : NSObject

/** The associated dispatch queue. */
@property(readonly, weak, nullable) dispatch_queue_t trackedQueue;

/** The request handlers. */
@property(readonly) EDORequestHandlers *requestHandlers;

- (instancetype)init NS_UNAVAILABLE;

/**
 *  Synchronously send out the request to remote over the channel for execution.
 *
 *  @note This method blocks the current execution and is still able to process incoming requests.
 *
 *  @param request    The request to be processed remotely.
 *  @param channel    The channel to send the request and receive the response.
 *  @param errorOrNil The error when it fails to send request.
 *
 *  @return The response or nil in case of failure.
 */
- (EDOServiceResponse *_Nullable)sendRequest:(EDOServiceRequest *)request
                                 withChannel:(id<EDOChannel>)channel
                                       error:(NSError **)errorOrNil;

/**
 *  Receive request from remote to process and send the response to the @c channel.
 *
 *  This method should be invoked from a different queue in case the associated dispatch queue is
 *  suspended.
 *  And in most cases, @c EDOClientService will send the request to the executor. If the executor is
 *  already waiting for a response, this method will enqueue the message and wait for it to be
 *  processed; otherwise, it will dispatch sync to its tracked dispatch queue to process the
 *  request.
 *
 *  @param request The request to process.
 *  @param channel The channel to send the response.
 *  @param context The additional context for the request.
 */
- (void)receiveRequest:(EDOServiceRequest *)request
           withChannel:(id<EDOChannel>)channel
               context:(id _Nullable)context;

/**
 *  Create and associate the executor with the given dispatch queue.
 *
 *  The executor will keep track of the dispatch queue weakly, and assigned itself to its context
 *  under the key "com.google.executorkey"; the dispatch queue holds its reference so it shares the
 *  same lifecycle as the queue (you can safely discard the returned value).
 *
 *  @param handlers The request handler map.
 *  @param queue    The dispatch queue to associate with the executor.
 *
 *  @return The @c EDOExecutor associated with the dispatch queue.
 *  @remark If the dispatch queue is already assigned one executor, it will be replaced.
 */
+ (instancetype)associateExecutorWithHandlers:(EDORequestHandlers *)handlers
                                        queue:(dispatch_queue_t)queue;

/**
 *  Get the executor for the current running queue.
 *
 *  If the current dispatch queue is associated with an executor already, that executor will be
 *  returned; otherwise, a new executor will be returned.
 *
 *  @remark If no executor is associated with the current dispatch queue, every invocation will
 *          return a new executor so they will not process any requests but only waits for the
 *          response to come back. This is the intended behaviour because no requests will be
 *          dispatched without associating it with any distant object.
 */
+ (instancetype)currentExecutor;

@end

NS_ASSUME_NONNULL_END
