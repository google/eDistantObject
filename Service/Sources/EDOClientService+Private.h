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

#import "Service/Sources/EDOClientService.h"
#import "Service/Sources/EDOObject+Private.h"

NS_ASSUME_NONNULL_BEGIN

@class EDOObject;
@class EDOServiceRequest;
@class EDOServiceResponse;

/** The internal use for sending and receiving EDOObject. */
@interface EDOClientService (Private)

/** The EDOObjects created by all services that are mapped by the remote address. */
@property(class, readonly) NSMapTable<NSNumber *, EDOObject *> *localDistantObjects;
/** The synchronization queue for accessing remote object references. */
@property(class, readonly) dispatch_queue_t edoSyncQueue;

/** Get the reference of a distant object of the given @c remoteAddress. */
+ (EDOObject *)distantObjectReferenceForRemoteAddress:(EDOPointerType)remoteAddress;

/** Add reference of given distant object. It could be an EDOObject or dummy block object. */
+ (void)addDistantObjectReference:(id)object;

/** Remove the reference of a distant object of the given @c remoteAddress. */
+ (void)removeDistantObjectReference:(EDOPointerType)remoteAddress;

/** Try to get the object from local cache. Update the cache if @c object is not in it. */
+ (id)cachedEDOFromObjectUpdateIfNeeded:(id)object;

/**
 *  Synchronously send the request and wait for the response.
 *
 *  @param request The request to be sent.
 *  @param port    The service port number.
 *  @throw  NSInternalInconsistencyException if it fails to communicate with the service.
 *
 *  @return The response from the service.
 */
+ (EDOServiceResponse *)sendRequest:(EDOServiceRequest *)request port:(UInt16)port;

@end

NS_ASSUME_NONNULL_END
