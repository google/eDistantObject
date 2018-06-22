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

#import "Service/Sources/EDOServicePort.h"

NS_ASSUME_NONNULL_BEGIN

/**
 *  The EDOHostService is a service hosting remote objects for remote process.
 *
 *  The service manages the distant objects and its life cycles. The distant object is always
 *  associated with a service, and any inherited objects will share the same attributes (i.e.
 *  another distant object returned by the method). If a local object is passed as a parameter to
 *  a remote invocation, it is converted to a distant object from the service associate with the
 *  current execution queue; If none exists, an exception is raised.
 */
@interface EDOHostService : NSObject

/** The port to identify the service. */
@property(readonly) EDOServicePort *port;

/** Create a service with the object and its associated execution queue. */
+ (instancetype)serviceWithPort:(UInt16)port rootObject:(id)object queue:(dispatch_queue_t)queue;

/** Invalidate the service and release all the associated objects. */
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
