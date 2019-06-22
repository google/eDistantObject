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

#import "Service/Sources/EDOWeakObject.h"

#include <objc/runtime.h>

#import "Service/Sources/EDODeallocationTracker.h"
#import "Service/Sources/EDOHostService+Private.h"
#import "Service/Sources/EDOParameter.h"
#import "Service/Sources/EDOServicePort.h"

@implementation EDOWeakObject

- (instancetype)initWithWeakObject:(id)weakObject {
  _weakObject = weakObject;
  return self;
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
  return _weakObject;
}

// Keep the original behavior when nested pass-by-value is called.
- (id)passByValue {
  return self;
}

// Keep the original behavior when nested return-by-value is called.
- (id)returnByValue {
  return self;
}

#pragma mark - NSProxy

- (void)forwardInvocation:(NSInvocation *)invocation {
  [_weakObject edo_forwardInvocation:invocation selector:invocation.selector returnByValue:YES];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
  return [_weakObject methodSignatureForSelector:sel];
}

#pragma mark - EDOParameter

- (EDOParameter *)edo_parameterForTarget:(EDOObject *)target
                                 service:(EDOHostService *)service
                                hostPort:(EDOHostPort *)hostPort {
  NSAssert(service, @"The service isn't set up to create the remote object.");
  id boxedObject = [service distantObjectForLocalObject:self hostPort:hostPort];

  void *deallocationTrackerKey = (void *)'trac';
  EDODeallocationTracker *tracker =
      [[EDODeallocationTracker alloc] initWithRemoteObject:boxedObject
                                                  hostPort:target.servicePort.hostPort];
  objc_setAssociatedObject(self.weakObject, deallocationTrackerKey, tracker,
                           OBJC_ASSOCIATION_RETAIN);

  return [EDOParameter parameterWithObject:boxedObject];
}

@end
