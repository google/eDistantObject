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

#import "Service/Sources/EDOInvocationMessage.h"

#include <objc/runtime.h>

#import "Service/Sources/EDOHostService+Private.h"
#import "Service/Sources/EDOParameter.h"
#import "Service/Sources/NSObject+EDOParameter.h"

// Box the value type directly into NSValue, the other types into a EDOObject, and the nil value.
#define BOX_VALUE(value, service) \
  ([(value) edo_parameterForService:(service)] ?: [EDOBoxedValueType parameterForNilValue])

static NSString *const kEDOInvocationCoderTargetKey = @"target";
static NSString *const kEDOInvocationCoderSelNameKey = @"selName";
static NSString *const kEDOInvocationCoderArgumentsKey = @"arguments";
static NSString *const kEDOInvocationReturnByValueKey = @"returnByValue";

static NSString *const kEDOInvocationCoderReturnValueKey = @"returnValue";
static NSString *const kEDOInvocationCoderOutValuesKey = @"outValues";
static NSString *const kEDOInvocationCoderExceptionKey = @"exception";

#pragma mark -

@implementation EDOInvocationResponse

+ (instancetype)responseWithReturnValue:(EDOBoxedValueType *)value
                              exception:(NSException *)exception
                              outValues:(NSArray<EDOBoxedValueType *> *)outValues
                             forRequest:(EDOInvocationRequest *)request {
  return [[self alloc] initWithReturnValue:value
                                 exception:exception
                                 outValues:outValues
                                forRequest:request];
}

- (instancetype)initWithReturnValue:(EDOBoxedValueType *)value
                          exception:(NSException *)exception
                          outValues:(NSArray<EDOBoxedValueType *> *)outValues
                         forRequest:(EDOInvocationRequest *)request {
  self = [super initWithMessageId:request.messageId];
  if (self) {
    _returnValue = value;
    _exception = exception;
    _outValues = outValues;
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super initWithCoder:aDecoder];
  if (self) {
    _returnValue = [aDecoder decodeObjectForKey:kEDOInvocationCoderReturnValueKey];
    _exception = [aDecoder decodeObjectForKey:kEDOInvocationCoderExceptionKey];
    _outValues = [aDecoder decodeObjectForKey:kEDOInvocationCoderOutValuesKey];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [super encodeWithCoder:aCoder];

  [aCoder encodeObject:self.returnValue forKey:kEDOInvocationCoderReturnValueKey];
  [aCoder encodeObject:self.exception forKey:kEDOInvocationCoderExceptionKey];
  [aCoder encodeObject:self.outValues forKey:kEDOInvocationCoderOutValuesKey];
}

- (NSString *)description {
  return [NSString stringWithFormat:@"Invocation response (%@)", self.messageId];
}

@end

#pragma mark -

@interface EDOInvocationRequest ()
/** The remote target. */
@property(readonly) EDOPointerType target;
/** The selector name. */
@property(readonly) NSString *selName;
/** The boxed arguments. */
@property(readonly) NSArray<EDOBoxedValueType *> *arguments;
/** The flag indicationg return-by-value. */
@property(readonly, assign) BOOL returnByValue;
@end

@implementation EDOInvocationRequest

+ (instancetype)requestWithTarget:(EDOPointerType)target
                         selector:(SEL)selector
                        arguments:(NSArray *)arguments
                    returnByValue:(BOOL)returnByValue {
  return [[self alloc] initWithTarget:target
                             selector:selector
                            arguments:arguments
                        returnByValue:returnByValue];
}

+ (instancetype)requestWithTarget:(EDOObject *)target
                         selector:(SEL)selector
                       invocation:(NSInvocation *)invocation
                    returnByValue:(BOOL)returnByValue {
  NSMethodSignature *signature = invocation.methodSignature;
  NSUInteger numOfArgs = signature.numberOfArguments;
  // If the target is a block, the first argument starts at index 1, whereas for a regular object
  // invocation, the first argument starts at index 2, with the selector being the second argument.
  NSUInteger firstArgumentIndex = selector ? 2 : 1;
  NSMutableArray<id> *arguments =
      [[NSMutableArray alloc] initWithCapacity:(numOfArgs - firstArgumentIndex)];

  for (NSUInteger i = firstArgumentIndex; i < numOfArgs; ++i) {
    char const *ctype = [signature getArgumentTypeAtIndex:i];
    EDOBoxedValueType *value = nil;

    if (EDO_IS_OBJECT_OR_CLASS(ctype)) {
      id __unsafe_unretained obj;
      [invocation getArgument:&obj atIndex:i];
      value = BOX_VALUE(obj, EDOHostService.currentService);
    } else if (EDO_IS_OBJPOINTER(ctype)) {
      id __unsafe_unretained *objRef;
      [invocation getArgument:&objRef atIndex:i];

      // Convert and pass the value as an object and decode it on remote side.
      value = objRef ? BOX_VALUE(*objRef, EDOHostService.currentService)
                     : [EDOBoxedValueType parameterForDoublePointerNullValue];
    } else if (EDO_IS_POINTER(ctype)) {
      // TODO(haowoo): Add the proper error and/or exception handler.
      NSAssert(NO, @"Not supported.");
    } else {
      NSUInteger typeSize = 0L;
      NSGetSizeAndAlignment(ctype, &typeSize, NULL);
      void *argBuffer = alloca(typeSize);
      [invocation getArgument:argBuffer atIndex:i];

      // save struct or other POD to NSValue
      value = [EDOBoxedValueType parameterWithBytes:argBuffer objCType:ctype];
    }
    [arguments addObject:value];
  }

  return [self requestWithTarget:target.remoteAddress
                        selector:selector
                       arguments:arguments
                   returnByValue:returnByValue];
}

+ (EDORequestHandler)requestHandler {
  return ^(EDOServiceRequest *originalRequest, EDOHostService *service) {
    EDOInvocationRequest *request = (EDOInvocationRequest *)originalRequest;
    NSAssert([request isKindOfClass:[EDOInvocationRequest class]],
             @"EDOInvocationRequest is expected.");
    id target = (__bridge id)(void *)request.target;
    SEL sel = NSSelectorFromString(request.selName);

    EDOBoxedValueType *returnValue;
    NSException *invocationException;
    NSMutableArray<EDOBoxedValueType *> *outValues = [[NSMutableArray alloc] init];

    @try {
      // TODO(haowoo): Throw non-existing method exception.
      NSMethodSignature *methodSignature;
      Method method = sel ? class_getInstanceMethod(object_getClass(target), sel) : nil;
      if (method) {
        methodSignature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
      } else {
        // If the method doesn't exist, we use the same fallback mechanism to fetch its signature.
        methodSignature = [target methodSignatureForSelector:sel];
      }
      NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
      invocation.target = target;

      NSUInteger numOfArgs = methodSignature.numberOfArguments;
      NSUInteger firstArgumentIndex = sel ? 2 : 1;
      if (sel) {
        invocation.selector = sel;
      }

      NSArray<EDOBoxedValueType *> *arguments = request.arguments;

      // Allocate enough memory to save the out parameters if any.
      size_t outObjectsSize = sizeof(id) * numOfArgs;
      id __unsafe_unretained *outObjects = (id __unsafe_unretained *)alloca(outObjectsSize);
      memset(outObjects, 0, outObjectsSize);

      // TODO(haowoo): Throw a proper exception.
      NSAssert(arguments.count == numOfArgs - firstArgumentIndex,
               @"The expected number of arguments is not matched.");

      for (NSUInteger curArgIdx = firstArgumentIndex; curArgIdx < numOfArgs; ++curArgIdx) {
        EDOBoxedValueType *argument = arguments[curArgIdx - firstArgumentIndex];

        // TODO(haowoo): Handle errors if the primitive type isn't matched with the remote argument.
        char const *ctype = [methodSignature getArgumentTypeAtIndex:curArgIdx];
        NSAssert(EDO_IS_OBJPOINTER(ctype) ||
                     (EDO_IS_OBJECT(ctype) && EDO_IS_OBJECT(argument.objCType)) ||
                     (EDO_IS_CLASS(ctype) && EDO_IS_OBJECT(argument.objCType)) ||
                     strcmp(ctype, argument.objCType) == 0,
                 @"The argument type is not matched (%s : %s).", ctype, argument.objCType);

        if (EDO_IS_OBJPOINTER(ctype)) {
          NSAssert(EDO_IS_OBJECT(argument.objCType),
                   @"The argument should be id type for object pointer but (%s) instead.",
                   argument.objCType);

          void *objRef = NULL;
          if (![argument isDoublePointerNullValue]) {
            [argument getValue:&outObjects[curArgIdx]];
            objRef = &outObjects[curArgIdx];
          }
          [invocation setArgument:&objRef atIndex:curArgIdx];
        } else if (EDO_IS_OBJECT_OR_CLASS(ctype)) {
          id __unsafe_unretained obj;
          [argument getValue:&obj];
          obj = [service unwrappedObjectFromObject:obj] ?: obj;
          [invocation setArgument:&obj atIndex:curArgIdx];
        } else {
          NSUInteger valueSize = 0;
          NSGetSizeAndAlignment(argument.objCType, &valueSize, NULL);
          void *argBuffer = alloca(valueSize);
          [argument getValue:argBuffer];
          [invocation setArgument:argBuffer atIndex:curArgIdx];
        }
      }

      [invocation invoke];

      NSUInteger length = methodSignature.methodReturnLength;
      if (length > 0) {
        char const *returnType = methodSignature.methodReturnType;
        if (EDO_IS_OBJECT_OR_CLASS(returnType)) {
          id __unsafe_unretained obj;
          [invocation getReturnValue:&obj];
          returnValue = request.returnByValue ? [EDOParameter parameterWithObject:obj]
                                              : BOX_VALUE(obj, service);
        } else if (EDO_IS_POINTER(returnType)) {
          // TODO(haowoo): Handle this early and populate the exception.

          // We don't/can't support the plain memory access.
          NSAssert(NO, @"Doesn't support pointer returns.");
        } else {
          void *returnBuf = alloca(length);
          [invocation getReturnValue:returnBuf];

          // Save any c-struct/POD into the NSValue.
          returnValue = [EDOBoxedValueType parameterWithBytes:returnBuf
                                                     objCType:methodSignature.methodReturnType];
        }
      }

      for (NSUInteger curArgIdx = firstArgumentIndex; curArgIdx < numOfArgs; ++curArgIdx) {
        char const *ctype = [methodSignature getArgumentTypeAtIndex:curArgIdx];
        if (!EDO_IS_OBJPOINTER(ctype)) {
          continue;
        }

        [outValues addObject:BOX_VALUE(outObjects[curArgIdx], service)];
      }
    } @catch (NSException *e) {
      // TODO(haowoo): Add more error info for non-user exception errors.
      invocationException = e;
    }

    return [EDOInvocationResponse responseWithReturnValue:returnValue
                                                exception:invocationException
                                                outValues:(outValues.count > 0 ? outValues : nil)
                                               forRequest:request];
  };
}

- (instancetype)initWithTarget:(EDOPointerType)target
                      selector:(SEL)selector
                     arguments:(NSArray *)arguments
                 returnByValue:(BOOL)returnByValue {
  self = [super init];
  if (self) {
    _target = target;
    _selName = selector ? NSStringFromSelector(selector) : nil;
    _arguments = arguments;
    _returnByValue = returnByValue;
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super initWithCoder:aDecoder];
  if (self) {
    _target = [aDecoder decodeInt64ForKey:kEDOInvocationCoderTargetKey];
    _selName = [aDecoder decodeObjectForKey:kEDOInvocationCoderSelNameKey];
    _arguments = [aDecoder decodeObjectForKey:kEDOInvocationCoderArgumentsKey];
    _returnByValue = [aDecoder decodeBoolForKey:kEDOInvocationReturnByValueKey];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [super encodeWithCoder:aCoder];
  [aCoder encodeInt64:self.target forKey:kEDOInvocationCoderTargetKey];
  [aCoder encodeObject:self.selName forKey:kEDOInvocationCoderSelNameKey];
  [aCoder encodeObject:self.arguments forKey:kEDOInvocationCoderArgumentsKey];
  [aCoder encodeBool:self.returnByValue forKey:kEDOInvocationReturnByValueKey];
}

- (NSString *)description {
  return [NSString stringWithFormat:@"Invocation request (%@) on target (%llx) with selector (%@)",
                                    self.messageId, self.target, self.selName];
}

@end
