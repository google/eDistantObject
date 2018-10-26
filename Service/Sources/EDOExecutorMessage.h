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

NS_ASSUME_NONNULL_BEGIN

@protocol EDOChannel;
@class EDOHostService;
@class EDOServiceRequest;
@class EDOServiceResponse;

/**
 *  The message being sent to the EDOExecutor to process.
 */
@interface EDOExecutorMessage : NSObject
/** The request to be processed by the executor. */
@property(readonly, nonatomic, nullable) EDOServiceRequest *request;
/** The service where the request is received from. */
@property(readonly, nonatomic, nullable) EDOHostService *service;
/** Whether the message has a request. */
@property(readonly, nonatomic, getter=isEmpty) BOOL empty;

/** Creates an instance of EDOExecutorMessage with the given request and service. */
+ (instancetype)messageWithRequest:(nullable EDOServiceRequest *)request
                           service:(nullable EDOHostService *)service;

/** Creates an empty message that doesn't contain a request. */
+ (instancetype)emptyMessage;

- (instancetype)init NS_UNAVAILABLE;

/** Initializes the message with the given request and service. */
- (instancetype)initWithRequest:(nullable EDOServiceRequest *)request
                        service:(nullable EDOHostService *)service NS_DESIGNATED_INITIALIZER;

/** Waits infinitely until the response is set. */
- (EDOServiceResponse *)waitForResponse;

/**
 *  Assigns the response and signals the wait thread if any thread is waiting.
 *
 *  @param response The response for the message.
 *  @return YES if the response is assigned for the first time; NO otherwise.
 *  @note The response can only be assigned once and no new value will be applied afterwards.
 */
- (BOOL)assignResponse:(EDOServiceResponse *)response;

@end

NS_ASSUME_NONNULL_END
