//
// Copyright 2025 Google Inc.
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

#include <objc/runtime.h>

#import "Service/Sources/EDOHostService+Private.h"
#import "Service/Sources/EDOHostService.h"
#import "Service/Sources/EDOParameter.h"

@interface EDOSwiftObject : NSObject
@end

@implementation EDOSwiftObject

+ (void)load {
  // @c SwiftObject is the base Objective-C class of all pure Swift class types and was renamed to
  // @c Swift._SwiftObject in Swift stable ABI.
  // https://github.com/swiftlang/swift/commit/9637b4a6e11ddca72f5f6dbe528efc7c92f14d01
  Class swiftObjectClass =
      (NSClassFromString(@"Swift._SwiftObject") ?: NSClassFromString(@"SwiftObject"));
  if (swiftObjectClass) {
    [self swizzleSelector:@selector(edo_parameterForTarget:service:hostPort:)
                  toClass:swiftObjectClass];
  }
}

+ (void)swizzleSelector:(SEL)sel toClass:(Class)klass {
  Method method = class_getInstanceMethod(self, sel);
  BOOL selectorAdded =
      class_addMethod(klass, sel, method_getImplementation(method), method_getTypeEncoding(method));
  if (!selectorAdded) {
    NSLog(@"Failed to add %@ to %@", NSStringFromSelector(sel), klass);
    abort();
  }
}

- (EDOParameter *)edo_parameterForTarget:(EDOObject *)target
                                 service:(EDOHostService *)service
                                hostPort:(EDOHostPort *)hostPort {
  NSAssert(service, @"The service isn't set up to create the remote object.");

  id boxedObject = [service distantObjectForLocalObject:self hostPort:hostPort];
  return [EDOParameter parameterWithObject:boxedObject];
}

@end
