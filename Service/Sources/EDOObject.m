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

#import "Service/Sources/EDOObject.h"
#import <Foundation/Foundation.h>

#include <objc/runtime.h>

#import "Service/Sources/EDOClientService+Private.h"
#import "Service/Sources/EDOClientService.h"
#import "Service/Sources/EDOObject+Private.h"
#import "Service/Sources/EDOObjectReleaseMessage.h"
#import "Service/Sources/EDOParameter.h"
#import "Service/Sources/EDOServiceError.h"
#import "Service/Sources/EDOServiceException.h"
#import "Service/Sources/EDOServicePort.h"
#import "Service/Sources/EDOValueObject.h"

static NSString *const kEDOObjectCoderPortKey = @"edoServicePort";
static NSString *const kEDOObjectCoderRemoteAddressKey = @"edoRemoteAddress";
static NSString *const kEDOObjectCoderRemoteClassKey = @"edoRemoteClass";
static NSString *const kEDOObjectCoderClassNameKey = @"edoClassName";
static NSString *const kEDOObjectCoderProcessUUIDKey = @"edoProcessUUID";

/** Returns the boolean idicating if the two objects are from the same process. */
static BOOL IsFromSameProcess(id object1, id object2);

@interface EDOObject ()
/** The port to connect to the local socket. */
@property(nonatomic, readonly) EDOServicePort *servicePort;
/** The proxied object's address in the remote. */
@property(nonatomic, readonly, assign) EDOPointerType remoteAddress;
/** The proxied object's class object in the remote. */
@property(nonatomic, readonly, assign) EDOPointerType remoteClass;
/** The proxied object's class name in the remote. */
@property(nonatomic, readonly) NSString *className;
/** The process unique identifier for the remote object. */
@property(nonatomic, readonly) NSString *processUUID;
@end

@implementation EDOObject

+ (BOOL)supportsSecureCoding {
  return YES;
}

// Initialize a remote object on the host side that is going to be sent back to the client side.
+ (instancetype)objectWithTarget:(id)target port:(EDOServicePort *)port {
  return [[self alloc] edo_initWithLocalObject:target port:port];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  NSAssert(sizeof(EDOPointerType) >= sizeof(void *), @"The pointer size is not big enough.");
  _servicePort = [aDecoder decodeObjectOfClass:[EDOServicePort class]
                                        forKey:kEDOObjectCoderPortKey];
  _remoteAddress = [aDecoder decodeInt64ForKey:kEDOObjectCoderRemoteAddressKey];
  _remoteClass = [aDecoder decodeInt64ForKey:kEDOObjectCoderRemoteClassKey];
  _className = [aDecoder decodeObjectOfClass:[NSString class] forKey:kEDOObjectCoderClassNameKey];
  _local = NO;
  _processUUID = [aDecoder decodeObjectOfClass:[NSString class]
                                        forKey:kEDOObjectCoderProcessUUIDKey];
  return self;
}

- (BOOL)isLocalEdo {
  return [self.processUUID isEqualToString:[EDOObject edo_processUUID]];
}

- (BOOL)weaklyReferenced {
  return [self.className isEqualToString:@"EDOWeakObject"];
}

- (id)returnByValue {
  return [[EDOValueObject alloc] initWithRemoteObject:self];
}

- (id)remoteWeak {
  [[NSException exceptionWithName:EDOWeakObjectRemoteWeakMisuseException
                           reason:@"Calling remoteWeak on a remote object."
                         userInfo:nil] raise];
  return self;
}

- (void)doesNotRecognizeSelector:(SEL)sel {
  [[NSException
      exceptionWithName:EDOObjectCalledUnrecognizedSelectorException
                 reason:[NSString
                            stringWithFormat:
                                @"eDO failed to proxy a method invocation because the proxied "
                                @"class %@ doesn't have the %s method",
                                [self className], sel_getName(sel)]
               userInfo:nil] raise];
}

// No-op when called on a remote object.
- (id)passByValue {
  return self;
}

- (instancetype)edo_initWithLocalObject:(id)target port:(EDOServicePort *)port {
  _servicePort = port;
  _remoteAddress = (EDOPointerType)target;
  _remoteClass = (EDOPointerType)(__bridge void *)object_getClass(target);
  _className = NSStringFromClass(object_getClass(target));
  _processUUID = [EDOObject edo_processUUID];
  _local = YES;
  return self;
}

#pragma mark - Class method proxy

- (instancetype)alloc {
  return [self edo_forwardInvocationForSelector:_cmd];
}

- (instancetype)allocWithZone:(NSZone *)zone {
  // +[allocWithZone:] is deprecated, forwarding to +[alloc]
  return [self alloc];
}

#pragma mark - Instance method proxy

// Forward the invocation to -[copy].
- (instancetype)copyWithZone:(NSZone *)zone {
  return [self copy];
}

// Forward the invocation to -[mutableCopy].
- (instancetype)mutableCopyWithZone:(NSZone *)zone {
  return [self mutableCopy];
}

- (instancetype)copy {
  return [self edo_forwardInvocationForSelector:_cmd];
}

- (instancetype)mutableCopy {
  return [self edo_forwardInvocationForSelector:_cmd];
}

- (void)dealloc {
  // Send a release message only when the object is not from the same process.
  if (![self isLocal] && ![self isLocalEdo]) {
    // Release the local edo manually to make sure the entry is removed from the cache.
    [EDOClientService removeDistantObjectReference:self.remoteAddress];
    @try {
      EDOObjectReleaseRequest *request =
          [EDOObjectReleaseRequest requestWithRemoteAddress:_remoteAddress];
      [EDOClientService sendSynchronousRequest:request onPort:_servicePort.hostPort];
    } @catch (NSException *e) {
      // There's an error with the service or most likely it's dead.
      // TODO(haowoo): Convert the exception to NSError and handle it accordingly.
    }
  }
}

- (id)forwardingTargetForSelector:(SEL)sel {
  // TODO(haowoo): Use this to forward to the local object.
  return nil;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  NSAssert(sizeof(int64_t) >= sizeof(void *), @"The pointer size is not big enough.");
  [aCoder encodeObject:self.servicePort forKey:kEDOObjectCoderPortKey];
  [aCoder encodeInt64:self.remoteAddress forKey:kEDOObjectCoderRemoteAddressKey];
  [aCoder encodeInt64:self.remoteClass forKey:kEDOObjectCoderRemoteClassKey];
  [aCoder encodeObject:self.className forKey:kEDOObjectCoderClassNameKey];
  [aCoder encodeObject:self.processUUID forKey:kEDOObjectCoderProcessUUIDKey];
}

- (BOOL)isEqual:(id)object {
  if (self == object) {
    return YES;
  }
  if (IsFromSameProcess(self, object)) {
    BOOL returnValue = NO;
    NSInvocation *invocation = [self edo_invocationForSelector:_cmd];
    [invocation setArgument:&object atIndex:2];
    [self forwardInvocation:invocation];
    [invocation getReturnValue:&returnValue];
    return returnValue;
  }
  return NO;
}

- (BOOL)isKindOfClass:(Class)aClass {
  if (!IsFromSameProcess(self, aClass)) {
    NSString *warningMessage = [NSString
        stringWithFormat:
            @"EDO WARNING: %@'s class is being compared via isKindOfClass: with a class that "
            @"doesn't belong to the process of the callee object. It will always return NO. To "
            @"expect isKindOfClass: to return YES, please use a class object that is fetched by "
            @"-[EDOClientService classObjectWithName:hostPort:].",
            self.className];
    // Starting with Xcode 16.3, errors thrown by Swift functions are captured by Swift testing and
    // go through a backtracing step, where the @c EDOObject is force cast to a @c Swift.Error,
    // resulting in a crash. To get around this, the check is forwarded to the actual object.
    // Note that only checks for @c NSError are forwarded to address this specific case. Attempts to
    // forward other checks, most notably for @c NSArray, have resulted in exceptions and require
    // further investigation.
    if (aClass != NSError.class) {
      NSLog(@"%@", warningMessage);
      return NO;
    }
    NSString *className = NSStringFromClass(aClass);
    aClass = [EDOClientService classObjectWithName:className hostPort:self.servicePort.hostPort];
    if (!aClass) {
      NSLog(@"%@", warningMessage);
      return NO;
    }
  }

  NSInvocation *invocation = [self edo_invocationForSelector:_cmd];
  [invocation setArgument:&aClass atIndex:2];
  [self forwardInvocation:invocation];
  BOOL returnValue = NO;
  [invocation getReturnValue:&returnValue];
  return returnValue;
}

- (id)arrayWithObjects:(id)object1, ... {
  NSLog(@"EDO WARNING: You are making remote invocation to variadic method [%@ arrayWithObjects:]. "
        @"Only the first argument will be passed to the remote execution, the rest of the "
        @"arguments will be dropped. Use +arrayWithArray: or NSMutableArray instead.",
        self.className);

  NSInvocation *invocation = [self edo_invocationForSelector:@selector(arrayWithObject:)];
  [invocation setArgument:&object1 atIndex:2];
  [self forwardInvocation:invocation];
  id __unsafe_unretained returnValue = nil;
  [invocation getReturnValue:&returnValue];
  return returnValue;
}

- (id)objectAtIndex:(NSUInteger)index {
  NSMethodSignature *methodSignature = [self methodSignatureForSelector:_cmd];
  if (EDO_IS_OBJPOINTER(methodSignature.methodReturnType)) {
    // Objective-C bridged Swift array returns Unmanaged<AnyObject>. Unmanaged<AnyObject> is
    // interpreted as pointer by method signature and fails the eDO type check. To bypass the
    // validation check, eDO redirects invocations to objectAtIndex: to objectsAtIndexes:.
    Class arrayClass = [EDOClientService classObjectWithName:@"NSArray"
                                                    hostPort:self.servicePort.hostPort];
    if ([self isKindOfClass:arrayClass]) {
      NSIndexSet *indexSet = [NSIndexSet indexSetWithIndex:index];
      return [((NSArray *)self) objectsAtIndexes:indexSet].firstObject;
    } else {
      // The redirection only works for array type and its subclasses. Users custom type which
      // has objectAtIndex: and returns Unmanaged<AnyObject> will eventually enter this branch. This
      // case is currently not supported, please file a bug to eDO if you see this message.
      NSAssert(NO,
               @"The non array remote class %@ declares objectAtIndex: to return object pointer, "
               @"which is not supported by eDO.",
               self.className);
      return nil;
    }
  } else {
    // If the return type is not object pointer, eDO simply forwards the invocation to the original
    // method.
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
    invocation.target = self;
    invocation.selector = _cmd;
    [invocation setArgument:&index atIndex:2];
    [self forwardInvocation:invocation];
    id __unsafe_unretained returnValue;
    [invocation getReturnValue:&returnValue];
    return returnValue;
  }
}

- (id)objectAtIndexedSubscript:(NSUInteger)index {
  return [self objectAtIndex:index];
}

/** Overrides NSDictionary enumeration to bypass the restriction of the C pointer. */
- (void)enumerateKeysAndObjectsUsingBlock:(void (^)(id key, id obj, BOOL *stop))block {
  NSMethodSignature *methodSignature = [self methodSignatureForSelector:_cmd];
  if (methodSignature) {
    __block BOOL stopped = NO;
    id modifiedBlock = ^(id key, id obj, NSUInteger unusedStop) {
      if (!stopped) {
        block(key, obj, &stopped);
      }
    };
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
    invocation.target = self;
    invocation.selector = _cmd;
    [invocation setArgument:&modifiedBlock atIndex:2];
    [self forwardInvocation:invocation];
  }
}

- (NSUInteger)hash {
  NSUInteger remoteHash = 0;
  NSInvocation *invocation = [self edo_invocationForSelector:_cmd];
  [self forwardInvocation:invocation];
  [invocation getReturnValue:&remoteHash];
  return remoteHash;
}

- (NSString *)description {
  return [self edo_forwardInvocationForSelector:_cmd];
}

/**
 * The override for __SwiftNativeNSError Swift-only method.
 *
 * This method is being called when a Swift error is propagated beyond the Swift XCTestCase. The
 * proxied error doesn't reveal useful information as the local Swift error, so eDO rethrows the
 * error message through its client error handler.
 */
- (BOOL)xct_shouldBeRecordedAsTestFailure {
  NSDictionary<NSErrorUserInfoKey, id> *userInfo = @{
    EDOErrorSwiftErrorDescription : [(id)self localizedDescription],
  };
  NSError *error = [NSError errorWithDomain:EDOServiceErrorDomain
                                       code:EDOServiceErrorSwiftErrorThrow
                                   userInfo:userInfo];
  EDOExportEDOClientError(error);
  return NO;
}

#pragma mark - NSFastEnumeration

/**
 * Implement the fast enumeration protocol that works for the remote container like NSArray, NSSet
 * and NSDictionary who implements "slow" enumeration's NSEnumerator. This doesn't provide the
 * performance gain usually given by the fast enumeration but a syntax benefit such that the
 * existing code will also work.
 *
 * @param state    Context information that is used in the enumeration to, in addition to other
 *                 possibilities, ensure that the collection has not been mutated.
 * @param buffer   A C array of objects over which the sender is to iterate.
 * @param len      The maximum number of objects to return in stackbuf.
 *
 * @return The number of objects returned in stackbuf, or 0 when the iteration is finished.
 */
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained _Nullable[_Nonnull])buffer
                                    count:(NSUInteger)len {
  // state 0: it is entering the enumeration, setting up the internal state.
  if (state->state == 0) {
    // Detecting concurrent mutations remotely isn't supported. We only make sure the remote address
    // doesn't change during the enumeration. The fast enumeration algorithm checks the value its
    // mutationsPtr points to.
    state->mutationsPtr = (unsigned long *)&_remoteAddress;

    // We use keyEnumerator or objectEnumerator to enumerate the remote container.
    // extra[0] to point to the enumerator and hold a strong reference of it.
    if ([self methodSignatureForSelector:@selector(keyEnumerator)]) {
      *((CFTypeRef *)(state->extra)) = CFBridgingRetain([(id)self keyEnumerator]);
    } else if ([self methodSignatureForSelector:@selector(objectEnumerator)]) {
      *((CFTypeRef *)(state->extra)) = CFBridgingRetain([(id)self objectEnumerator]);
    } else {
      BOOL implementsFastEnumeration =
          ![self methodSignatureForSelector:@selector(countByEnumeratingWithState:objects:count:)];
      NSString *reason = implementsFastEnumeration
                             ? @"Fast enumeration is not supported on custom types."
                             : @"Fast enumeration is not supported on the current object.";
      [[NSException exceptionWithName:NSInternalInconsistencyException reason:reason
                             userInfo:nil] raise];
      return 0;
    }

    // The enumeration has started.
    state->state = 1;
  }

  NSEnumerator *enumerator = (__bridge NSEnumerator *)(void *)state->extra[0];
  id nextObject = [enumerator nextObject];

  if (!nextObject) {
    objc_setAssociatedObject(enumerator, &_cmd, nil, OBJC_ASSOCIATION_RETAIN);
    CFRelease((void *)state->extra[0]);
    return 0;
  } else {
    objc_setAssociatedObject(enumerator, &_cmd, nextObject, OBJC_ASSOCIATION_RETAIN);
  }

  // We only return one object for each call.
  buffer[0] = nextObject;
  state->itemsPtr = &buffer[0];
  return 1;
}

#pragma mark - NSCoder overrides
// Overrides the NSCoder/NSKeyedArchiver so those won't get proxied.
// TODO(haowoo): Replace with other NSCoders.

- (id)replacementObjectForCoder:(NSCoder *)aCoder {
  return self;
}

- (id)replacementObjectForKeyedArchiver:(NSKeyedArchiver *)archiver {
  return self;
}

- (id)awakeAfterUsingCoder:(NSCoder *)aDecoder {
  return self;
}

- (Class)classForCoder {
  return nil;
}

- (Class)classForKeyedArchiver {
  return nil;
}

+ (Class)classForKeyedUnarchiver {
  return [self class];
}

+ (NSArray<NSString *> *)classFallbacksForKeyedArchiver {
  return nil;
}

#pragma mark - Private

+ (NSString *)edo_processUUID {
  static NSString *gProcessUUID;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    gProcessUUID = NSProcessInfo.processInfo.globallyUniqueString;
  });
  return gProcessUUID;
}

+ (EDOObject *)edo_remoteProxyFromUnderlyingObject:(id)underlyingObject
                                          withPort:(EDOServicePort *)port {
  return [[self alloc] edo_initWithLocalObject:underlyingObject port:port];
}

/**
 * Forwards the @c selector to the remote underlying object.
 *
 * @param selector      The selector to forward to the underlying remote object.
 * @return The object returned by the remote invocation.
 */
- (id)edo_forwardInvocationForSelector:(SEL)selector {
  NSInvocation *invocation = [self edo_invocationForSelector:selector];
  [self forwardInvocation:invocation];

  id __unsafe_unretained returnObject;
  [invocation getReturnValue:&returnObject];
  return returnObject;
}

/**
 * Creates NSInvocation with the @c selector by fetching the method signature from the underlying
 * remote object.
 *
 * @param  selector The selector to forward to the underlying remote object.
 * @return The NSInvocation instance that can be passed to [self -forwardInvocation:].
 */
- (NSInvocation *)edo_invocationForSelector:(SEL)selector {
  NSMethodSignature *methodSignature = [self methodSignatureForSelector:selector];
  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
  invocation.target = self;
  invocation.selector = selector;
  return invocation;
}

// This dummy method is to resolve an issue that this may be invoked during encoding, which
// leads to an unexpected message forwarding.
// TODO(ynzhang): this is a workaround and will be removed after root cause is fixed.
- (id)_accessibilityAttributedLocalizedString {
  return nil;
}

@end

static BOOL IsFromSameProcess(id object1, id object2) {
  Class edoClass = [EDOObject class];
  return ([object1 class] != edoClass && [object2 class] != edoClass) ||
         ([object1 class] == edoClass && [object2 class] == edoClass &&
          [((EDOObject *)object1).processUUID isEqual:((EDOObject *)object2).processUUID]);
}
