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

#import "Service/Sources/EDOBlockObject.h"
#import "Service/Sources/EDOParameter.h"
#import "Service/Sources/EDOServiceException.h"
#import "Service/Sources/NSObject+EDOParameter.h"
#import "Service/Sources/NSObject+EDOValue.h"

/**
 *  Change the implementation of -edo_parameterForTarget:service:hostPort: for the target class.
 *
 *  @param targetClass    The class to apply.
 *  @param implementation The implementation to apply.
 */
static void UpdateEDOParameterForTarget(Class targetClass, IMP implementation) {
  static SEL selector;
  static const char *typeEncoding;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    selector = @selector(edo_parameterForTarget:service:hostPort:);
    typeEncoding = method_getTypeEncoding(class_getInstanceMethod([NSObject class], selector));
  });
  Method method = class_getInstanceMethod(targetClass, selector);
  if (!class_addMethod(targetClass, selector, implementation, typeEncoding)) {
    method_setImplementation(method, implementation);
  }
}

@implementation NSObject (EDOBlockedType)

+ (void)edo_disallowRemoteInvocation {
  [self edo_disallowRemoteInvocationWithExlcusion:@[]];
}

+ (void)edo_disallowRemoteInvocationWithExlcusion:(NSArray<Class> *)excludedSubclasses {
  // This method may swizzle the original [NSObject -edo_parameterForTarget:service:hostPort:] so
  // it caches the original method before it gets changed.
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    [NSObject EDOOriginalParameterForTarget];
  });
  @synchronized(self.class) {
    if (self.edo_remoteInvocationAlwaysAllowed) {
      NSString *reason =
          [NSString stringWithFormat:@"You can't add this class to blocklist because either this "
                                     @"class or its superclass has been excluded from the "
                                     @"blocklist, which is done at the following stacktrace:\n%@",
                                     objc_getAssociatedObject(
                                         self, @selector(edo_alwaysAllowRemoteInvocation))];
      [[NSException exceptionWithName:EDOParameterTypeException reason:reason userInfo:nil] raise];
    }
    for (Class subclass in excludedSubclasses) {
      if ([subclass isSubclassOfClass:self]) {
        [subclass edo_alwaysAllowRemoteInvocation];
      } else {
        NSString *reason =
            [NSString stringWithFormat:
                          @"%@ cannot be excluded from blocklist because it's not subclass of %@",
                          NSStringFromClass(subclass), NSStringFromClass([self class])];
        [[NSException exceptionWithName:EDOParameterTypeException reason:reason
                               userInfo:nil] raise];
      }
    }
    if (self.edo_remoteInvocationDisallowed) {
      return;
    }
    EDOParameter * (^impBlock)(id obj, EDOObject *target, EDOHostService *service,
                               EDOHostPort *port) =
        ^EDOParameter *(id obj, EDOObject *target, EDOHostService *service, EDOHostPort *port) {
      // If the object is always passed by value, the encoded EDOParameter is returned instead of
      // throwing an error. This helps the case that a subclass responds to edo_isEDOValueType
      // however the super class is disallowed.
      if ([obj respondsToSelector:@selector(edo_isEDOValueType)] && [obj edo_isEDOValueType]) {
        return [EDOParameter parameterWithObject:obj];
      }
      // Meta class type is always allowed being sent across the process.
      else if (class_isMetaClass(object_getClass(obj)) || [EDOBlockObject isBlock:obj]) {
        return ((EDOParameter * (*)(id, SEL, EDOObject *, EDOHostService *, EDOHostPort *))
                    NSObject.EDOOriginalParameterForTarget)(obj, nil, target, service, port);
      }
      NSString *reason = [NSString
          stringWithFormat:@"%@ instance is not allowed to be part of remote invocation\n",
                           NSStringFromClass([obj class])];
      [[NSException exceptionWithName:EDOParameterTypeException reason:reason userInfo:nil] raise];
      return nil;
    };
    IMP newImp = imp_implementationWithBlock(impBlock);
    UpdateEDOParameterForTarget(self, newImp);
    objc_setAssociatedObject(self, @selector(edo_remoteInvocationDisallowed), @(YES),
                             OBJC_ASSOCIATION_RETAIN);
  }
}

+ (void)edo_alwaysAllowRemoteInvocation {
  @synchronized(self.class) {
    if (self.edo_remoteInvocationAlwaysAllowed) {
      return;
    }
    if (self.edo_remoteInvocationDisallowed) {
      objc_setAssociatedObject(self, @selector(edo_remoteInvocationDisallowed), nil,
                               OBJC_ASSOCIATION_ASSIGN);
    }
    UpdateEDOParameterForTarget(self, self.EDOOriginalParameterForTarget);
    objc_setAssociatedObject(self, @selector(edo_alwaysAllowRemoteInvocation),
                             NSThread.callStackSymbols.description, OBJC_ASSOCIATION_RETAIN);
  }
}

+ (BOOL)edo_remoteInvocationDisallowed {
  return objc_getAssociatedObject(self, @selector(edo_remoteInvocationDisallowed)) != nil;
}

+ (BOOL)edo_remoteInvocationAlwaysAllowed {
  return objc_getAssociatedObject(self, @selector(edo_alwaysAllowRemoteInvocation)) != nil;
}

@end
