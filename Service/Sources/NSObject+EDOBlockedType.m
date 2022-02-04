//
// Copyright 2019 Google Inc.
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
#import "Service/Sources/NSObject+EDOBlockedType.h"

#include <objc/runtime.h>

#import "Service/Sources/EDOParameter.h"
#import "Service/Sources/EDOServiceException.h"
#import "Service/Sources/NSObject+EDOParameter.h"
#import "Service/Sources/NSObject+EDOValue.h"

@implementation NSObject (EDOBlockedType)

+ (void)edo_disallowRemoteInvocation {
  @synchronized(self.class) {
    if (self.edo_remoteInvocationDisallowed) {
      return;
    }
    SEL originalSelector = @selector(edo_parameterForTarget:service:hostPort:);
    Method originalMethod = class_getInstanceMethod(self, originalSelector);
    EDOParameter * (^impBlock)(id obj, EDOObject *target, EDOHostService *service,
                               EDOHostPort *port) =
        ^EDOParameter *(id obj, EDOObject *target, EDOHostService *service, EDOHostPort *port) {
      // If the object is always passed by value, the encoded EDOParameter is returned instead of
      // throwing an error. This helps the case that a subclass responds to edo_isEDOValueType
      // however the super class is disallowed.
      if ([obj respondsToSelector:@selector(edo_isEDOValueType)] && [obj edo_isEDOValueType]) {
        return [EDOParameter parameterWithObject:obj];
      }
      NSString *reason =
          [NSString stringWithFormat:@"%@ instance is not allowed to be part of remote invocation",
                                     NSStringFromClass([self class])];
      [[NSException exceptionWithName:EDOParameterTypeException reason:reason userInfo:nil] raise];
      return nil;
    };
    IMP newImp = imp_implementationWithBlock(impBlock);
    if (!class_addMethod(self, originalSelector, newImp, method_getTypeEncoding(originalMethod))) {
      method_setImplementation(originalMethod, newImp);
    }
    objc_setAssociatedObject(self, @selector(edo_remoteInvocationDisallowed), @(YES),
                             OBJC_ASSOCIATION_RETAIN);
  }
}

+ (BOOL)edo_remoteInvocationDisallowed {
  return objc_getAssociatedObject(self, @selector(edo_remoteInvocationDisallowed)) != nil;
}

@end
