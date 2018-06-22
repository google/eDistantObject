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

#import "Service/Sources/EDOServiceRequest.h"

#import "Service/Sources/EDOObject+Private.h"

NS_ASSUME_NONNULL_BEGIN

@class EDOParameter;
typedef EDOParameter EDOBoxedValueType;

/** The invocation request to make a remote invocation. */
@interface EDOInvocationRequest : EDOServiceRequest

- (instancetype)init NS_UNAVAILABLE;

/**
 *  Create an invocation request.
 *
 *  @param target        The remote target's plain address. The caller needs to make sure the
 *                       address is valid.
 *  @param selector      The selector that is sent to the @c target. @c nil if the target is a
 *                       block.
 *  @param arguments     The array of arguments to send.
 *  @param returnByValue @c YES if the invocation should return the object by value instead of by
 *                       reference (for value-types that are already return-by-value by default,
 *                       this will be a no-op).
 */
+ (instancetype)requestWithTarget:(EDOPointerType)target
                         selector:(SEL _Nullable)selector
                        arguments:(NSArray *)arguments
                    returnByValue:(BOOL)returnByValue;

/**
 *  Create an invocation request from an @c invocation on a EDOObject.
 *
 *  @param target        The EDOObject.
 *  @param selector      The selector to be sent. When this is nil, the case for a block invocation,
 *                       the index of the actual arguments starts at 1; otherwise the case for an
 *                       object invocation, it starts at 2.
 *  @param invocation    The invocation.
 *  @param returnByValue @c YES if the invocation should return the object by value instead of by
 *                       reference.
 *
 *  @return An instance of EDOInvocationRequest.
 */
+ (instancetype)requestWithTarget:(EDOObject *)target
                         selector:(SEL _Nullable)selector
                       invocation:(NSInvocation *)invocation
                    returnByValue:(BOOL)returnByValue;

@end

/** The invocation response for the remote invocation. */
@interface EDOInvocationResponse : EDOServiceResponse

/** The exception if thrown remotely. */
@property(readonly, nullable) NSException *exception;
/** The boxed return value. */
@property(readonly, nullable) EDOBoxedValueType *returnValue;
/** The boxed values for out parameter. */
@property(readonly, nullable) NSArray<EDOBoxedValueType *> *outValues;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
