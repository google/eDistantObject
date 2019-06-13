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

#import "Channel/Sources/EDOHostPort.h"
#import "Service/Sources/EDOBlockObject.h"
#import "Service/Sources/EDOClientService+Private.h"
#import "Service/Sources/EDOHostService+Private.h"
#import "Service/Sources/EDOParameter.h"
#import "Service/Sources/EDOServicePort.h"
#import "Service/Sources/NSObject+EDOParameter.h"

// Box the value type directly into NSValue, the other types into a EDOObject, and the nil value.
#define BOX_VALUE(__value, __service, __hostPort)                        \
  ([(__value) edo_parameterForService:(__service) hostPort:(__hostPort)] \
       ?: [EDOBoxedValueType parameterForNilValue])

#define CHECK_PREFIX(__string, __prefix) (strncmp(__string, __prefix, sizeof(__prefix) - 1) == 0)

static NSString *const kEDOInvocationCoderTargetKey = @"target";
static NSString *const kEDOInvocationCoderSelectorNameKey = @"selName";
static NSString *const kEDOInvocationCoderArgumentsKey = @"arguments";
static NSString *const kEDOInvocationCoderHostPortKey = @"hostPort";
static NSString *const kEDOInvocationReturnByValueKey = @"returnByValue";

static NSString *const kEDOInvocationCoderReturnRetainedKey = @"returnRetained";
static NSString *const kEDOInvocationCoderReturnValueKey = @"returnValue";
static NSString *const kEDOInvocationCoderOutValuesKey = @"outValues";
static NSString *const kEDOInvocationCoderExceptionKey = @"exception";

/** A struct representing an Objective-C method family. */
typedef struct MethodFamily {
  /** The prefix identifying the method family. */
  const char *prefix;
  /** The length of the prefix of the method family. */
  size_t length;
} MethodFamily;

/** The helper macro to define a @c MethodFamily above. */
#define METHOD_FAMILY(__str) ((MethodFamily){.prefix = (__str), .length = sizeof(__str) - 1})

/** The methods family that should retain the returned object. */
const MethodFamily kRetainReturnsMethodsFamily[] = {
    METHOD_FAMILY("alloc"),
    METHOD_FAMILY("copy"),
    METHOD_FAMILY("new"),
    METHOD_FAMILY("mutableCopy"),
};

/**
 *  Check if the method belongs to the ns_returns_retained family.
 *
 *  More info here:
 *  https://clang.llvm.org/docs/AutomaticReferenceCounting.html#retained-return-values.
 */
static BOOL CheckIfMethodRetainsReturn(const char *methodName) {
  if (!methodName) {
    return NO;
  }

  /**
   *  To find out if a selector is in a certain method family:
   *
   *  A selector is in a certain selector family if, ignoring any leading underscores, the first
   *  component of the selector either consists entirely of the name of the method family or it
   *  begins with that name followed by a character other than a lowercase letter.
   *  http://clang.llvm.org/docs/AutomaticReferenceCounting.html#method-families
   */

  // Skip the leading underscore as it is considered to be the same method family.
  while (*methodName == '_') {
    ++methodName;
  }

  // Skip the first component if it begins with a method family that is implicitly annotated with
  // the ns_returns_retained attribute.
  BOOL matchesMethodFamily = NO;
  int familySize = sizeof(kRetainReturnsMethodsFamily) / sizeof(kRetainReturnsMethodsFamily);
  for (int i = 0; i < familySize; i++) {
    MethodFamily family = kRetainReturnsMethodsFamily[i];
    if (strncmp(methodName, family.prefix, family.length) == 0) {
      methodName += family.length;
      matchesMethodFamily = YES;
      break;
    }
  }

  if (!matchesMethodFamily) {
    return NO;
  }

  // It should end or be followed by a character other than a lowercase letter.
  return *methodName == '\0' || !islower(*methodName);
}

#pragma mark - EDOInvocationRequest extension

@interface EDOInvocationRequest ()
/** The remote target. */
@property(readonly) EDOPointerType target;
/** The selector name. */
@property(readonly) NSString *selectorName;
/** The boxed arguments. */
@property(readonly) NSArray<EDOBoxedValueType *> *arguments;
/** The flag indicationg return-by-value. */
@property(readonly, assign) BOOL returnByValue;
/** The host port. */
@property(readonly) EDOHostPort *hostPort;
@end

#pragma mark -

@implementation EDOInvocationResponse

+ (BOOL)supportsSecureCoding {
  return YES;
}

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
    _returnRetained = CheckIfMethodRetainsReturn(request.selectorName.UTF8String);
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super initWithCoder:aDecoder];
  if (self) {
    _returnRetained = [aDecoder decodeBoolForKey:kEDOInvocationCoderReturnRetainedKey];
    _returnValue = [aDecoder decodeObjectOfClass:[EDOParameter class]
                                          forKey:kEDOInvocationCoderReturnValueKey];
    // TODO(haowoo): The exception doesn't conform to NSSecureCoding, so when NSKeyedUnarchiver
    // deserializes this class with requiresSecureCoding = YES, this will throw an exception.
    // Because of this, we currently can't set requiresSecureCoding to be YES when deserializing the
    // EDOInvocationResponse; we should provide a serializable EDOException that will propagate
    // exception information. However here we still use the -[decodeObjectOfClass:forKey:] to keep
    // our code consistent with the Apple documentation.
    _exception = [aDecoder decodeObjectOfClass:[NSException class]
                                        forKey:kEDOInvocationCoderExceptionKey];
    NSSet *anyClasses =
        [NSSet setWithObjects:[EDOBlockObject class], [NSObject class], [EDOObject class], nil];
    _outValues = [aDecoder decodeObjectOfClasses:anyClasses forKey:kEDOInvocationCoderOutValuesKey];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [super encodeWithCoder:aCoder];

  [aCoder encodeBool:self.returnRetained forKey:kEDOInvocationCoderReturnRetainedKey];
  [aCoder encodeObject:self.returnValue forKey:kEDOInvocationCoderReturnValueKey];
  [aCoder encodeObject:self.exception forKey:kEDOInvocationCoderExceptionKey];
  [aCoder encodeObject:self.outValues forKey:kEDOInvocationCoderOutValuesKey];
}

- (NSString *)description {
  return [NSString stringWithFormat:@"Invocation response (%@)", self.messageId];
}

@end

#pragma mark -

@implementation EDOInvocationRequest

+ (BOOL)supportsSecureCoding {
  return YES;
}

+ (instancetype)requestWithTarget:(EDOPointerType)target
                         selector:(SEL)selector
                        arguments:(NSArray *)arguments
                         hostPort:(EDOHostPort *)hostPort
                    returnByValue:(BOOL)returnByValue {
  return [[self alloc] initWithTarget:target
                             selector:selector
                            arguments:arguments
                             hostPort:hostPort
                        returnByValue:returnByValue];
}

+ (instancetype)requestWithInvocation:(NSInvocation *)invocation
                               target:(EDOObject *)target
                             selector:(SEL _Nullable)selector
                        returnByValue:(BOOL)returnByValue
                              service:(EDOHostService *)service {
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
      value = BOX_VALUE(obj, service, nil);
    } else if (EDO_IS_OBJPOINTER(ctype)) {
      id __unsafe_unretained *objRef;
      [invocation getArgument:&objRef atIndex:i];

      // Convert and pass the value as an object and decode it on remote side.
      value = objRef ? BOX_VALUE(*objRef, service, nil)
                     : [EDOBoxedValueType parameterForDoublePointerNullValue];
    } else if (EDO_IS_POINTER(ctype)) {
      // TODO(haowoo): Add the proper error and/or exception handler.
      NSAssert(NO, @"Not supported type (%s) in the argument for selector (%@).", ctype,
               selector ? NSStringFromSelector(selector) : @"(block)");
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
                        hostPort:target.servicePort.hostPort
                   returnByValue:returnByValue];
}

+ (EDORequestHandler)requestHandler {
  return ^(EDOServiceRequest *originalRequest, EDOHostService *service) {
    EDOInvocationRequest *request = (EDOInvocationRequest *)originalRequest;
    NSAssert([request isKindOfClass:[EDOInvocationRequest class]],
             @"EDOInvocationRequest is expected.");
    EDOHostPort *hostPort = request.hostPort;
    id target = (__bridge id)(void *)request.target;
    SEL sel = NSSelectorFromString(request.selectorName);

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

          // The local buffer to save the pointer to the object. We need to inspect if the object
          // from the remote process can be unwrapped into a local object and then use the local
          // buffer for the outvar (i.e. NSError **) argument.
          id __unsafe_unretained *objRef = NULL;
          if (![argument isDoublePointerNullValue]) {
            [argument getValue:&outObjects[curArgIdx]];
            objRef = &outObjects[curArgIdx];
          }
          if (objRef && *objRef) {
            *objRef = [EDOClientService unwrappedObjectFromObject:*objRef];
            *objRef = [EDOClientService cachedEDOFromObjectUpdateIfNeeded:*objRef];
          }
          [invocation setArgument:&objRef atIndex:curArgIdx];
        } else if (EDO_IS_OBJECT_OR_CLASS(ctype)) {
          id __unsafe_unretained obj;
          [argument getValue:&obj];
          obj = [EDOClientService unwrappedObjectFromObject:obj];
          obj = [EDOClientService cachedEDOFromObjectUpdateIfNeeded:obj];
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
                                              : BOX_VALUE(obj, service, hostPort);
          if (CheckIfMethodRetainsReturn(request.selectorName.UTF8String)) {
            // We need to do an extra release here because the method return is not autoreleased,
            // and because the invocation is dynamically created, ARC won't insert an extra release
            // for us.
            CFBridgingRelease((__bridge void *)obj);
          }
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
        // TODO(ynzhang): add device serial info.
        [outValues addObject:BOX_VALUE(outObjects[curArgIdx], service, hostPort)];
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
                      hostPort:(EDOHostPort *)hostPort
                 returnByValue:(BOOL)returnByValue {
  self = [super init];
  if (self) {
    _target = target;
    _selectorName = selector ? NSStringFromSelector(selector) : nil;
    _arguments = [arguments copy];
    _hostPort = hostPort;
    _returnByValue = returnByValue;
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super initWithCoder:aDecoder];
  if (self) {
    NSSet *anyClasses =
        [NSSet setWithObjects:[EDOBlockObject class], [EDOObject class], [NSObject class], nil];
    _target = [aDecoder decodeInt64ForKey:kEDOInvocationCoderTargetKey];
    _selectorName = [aDecoder decodeObjectOfClass:[NSString class]
                                           forKey:kEDOInvocationCoderSelectorNameKey];
    _arguments = [aDecoder decodeObjectOfClasses:anyClasses forKey:kEDOInvocationCoderArgumentsKey];
    _hostPort = [aDecoder decodeObjectOfClass:[EDOHostPort class]
                                       forKey:kEDOInvocationCoderHostPortKey];
    _returnByValue = [aDecoder decodeBoolForKey:kEDOInvocationReturnByValueKey];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [super encodeWithCoder:aCoder];
  [aCoder encodeInt64:self.target forKey:kEDOInvocationCoderTargetKey];
  [aCoder encodeObject:self.selectorName forKey:kEDOInvocationCoderSelectorNameKey];
  [aCoder encodeObject:self.arguments forKey:kEDOInvocationCoderArgumentsKey];
  [aCoder encodeObject:self.hostPort forKey:kEDOInvocationCoderHostPortKey];
  [aCoder encodeBool:self.returnByValue forKey:kEDOInvocationReturnByValueKey];
}

- (NSString *)description {
  return [NSString stringWithFormat:@"Invocation request (%@) on target (%llx) with selector (%@)",
                                    self.messageId, self.target, self.selectorName];
}

@end
