//
// Copyright 2019 Google LLC.
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

#import "Service/Sources/NSObject+EDOWeakObject.h"

#include <objc/runtime.h>

#import "Service/Sources/EDOWeakObject.h"

@implementation NSObject (EDOWeakObject)

// When an object is passed from the client to the host, it is wrapped in an @c EDOObject that acts
// as a proxy to the original object. As long as the host holds a reference to the @c EDOObject, the
// original object is retained.
//
// This breaks when the host is only holding a weak reference to the @c EDOObject as it may be
// deallocated immediately
//
// == Client ==               | == Host ==
//                            |
//     ┌────────┐             | ┌──────────────┐
// ┌──▶│ object │             | │ RemoteObject │─┐
// │   └────────┘             | └──────────────┘ │ weak
// │ ┌────────────────────┐   |  ┌───────────┐   │
// └─│ localObjects (eDO) │◀--|--│ EDOObject │◀──┘
//   └────────────────────┘   |  └───────────┘
//
// Through the use of @c remoteWeak:
// 1. The client wraps the object in an @c EDOWeakObject, which triggers additional handling on the
//    host side when the object is passed to a remote process.
// 2. The host tracks the @c EDOObject in @c localWeakObjects to prevent premature deallocation.
// 3. The client associates a deallocation tracker to the object. When the object is deallocated,
//    the tracker's @c dealloc triggers an object release request to remove the @c EDOObject from
//    the host's @c localWeakObjects. Once the @c EDOObject is deallocated on the host, the usual
//    cleanup flow ensues, removing the @c EDOWeakObject from the client's @c localObjects.
// 4. When an message is sent to the @c EDOObject, it is forwarded to the @c EDOWeakObject, which is
//    itself an @c NSProxy and forwards the invocation to the original object.
//
// == Client ==                | == Host ==
//                             |
//    ┌─────────────────────┐  |   ┌────────────────────────┐
// ┌─▶│ DeallocationTracker │--|--▶│ localWeakObjects (eDO) │─┐
// │  └─────────────────────┘  |   └────────────────────────┘ │
// └───────┌────────┐          |                              │
//      ┌─▶│ object │────────┐ |                              │
// weak │  └────────┘        │ |                              │
//      └─┌───────────────┐  │ | ┌──────────────┐             │
//  ┌────▶│ EDOWeakObject │◀─┘ | │ RemoteObject │─┐           │
//  │     └───────────────┘    | └──────────────┘ │ weak      │
//  │ ┌────────────────────┐   |  ┌───────────┐   │           │
//  └─│ localObjects (eDO) │◀--|--│ EDOObject │◀──┴───────────┘
//    └────────────────────┘   |  └───────────┘
- (instancetype)remoteWeak {
  static dispatch_queue_t syncQueue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    syncQueue = dispatch_queue_create("com.google.edo.weakobj", DISPATCH_QUEUE_SERIAL);
  });
  __block id weakObject;
  dispatch_sync(syncQueue, ^{
    weakObject = objc_getAssociatedObject(self, &_cmd);
    if (!weakObject) {
      weakObject = [[EDOWeakObject alloc] initWithWeakObject:self];
      objc_setAssociatedObject(self, &_cmd, weakObject, OBJC_ASSOCIATION_RETAIN);
    }
  });
  return weakObject;
}

@end
