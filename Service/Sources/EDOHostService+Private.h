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

#import "Service/Sources/EDOHostService.h"
#import "Service/Sources/EDOObject+Private.h"

NS_ASSUME_NONNULL_BEGIN

@class EDOExecutor;
@class EDOObject;

/** The internal use for sending and receiving EDOObject. */
@interface EDOHostService (Private)
/** The root object. */
@property(readonly) EDOObject *rootObject;
/** The executor to handle the request. */
@property(readonly) EDOExecutor *executor;

/** Wrap a distant object for the given local object. */
- (EDOObject *)distantObjectForLocalObject:(id)object;

/**
 *  Checks if the underlying object for the given @c EDOObject is still alive.
 *
 *  @param object The @c EDOObject containing the underlying object address.
 *  @return @c YES if the underlying object is still in the cache; @c NO otherwise.
 */
- (BOOL)isObjectAlive:(EDOObject *)object;

/**
 *  Removes an EDOObject with the specified address in the host cache.
 *
 *  @param remoteAddress The @c EDOPointerType containing the object address.
 *  @return @c YES if an object was removed; @c NO otherwise.
 */
- (BOOL)removeObjectWithAddress:(EDOPointerType)remoteAddress;

@end

NS_ASSUME_NONNULL_END
