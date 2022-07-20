//
// Copyright 2022 Google Inc.
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

@class EDOObject;

NS_ASSUME_NONNULL_BEGIN

/** The request to check if the underlying object is still alive in the service. */
@interface EDOObjectAliveRequest : EDOServiceRequest

/** Create a request with the @c EDOObject. */
+ (instancetype)requestWithObject:(EDOObject *)object;

- (instancetype)init NS_UNAVAILABLE;

@end

/** The object response for the object tick request. */
@interface EDOObjectAliveResponse : EDOServiceResponse

/** @c YES if the underlying object is alive in the service; @c NO otherwise. */
@property(nonatomic, getter=isAlive) BOOL alive;

/**
 * Initializes the class.
 *
 * @param isAlive The result for the @c request.
 * @param request The request that is processed by the service.
 *
 * @return The instance of EDOObjectAliveResponse.
 */
- (instancetype)initWithResult:(BOOL)isAlive
                    forRequest:(EDOServiceRequest *)request NS_DESIGNATED_INITIALIZER;

/** @see -[NSCoding initWithCoder:]. */
- (instancetype)initWithCoder:(NSCoder *)aDecoder NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithMessageID:(NSString *)messageID NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END