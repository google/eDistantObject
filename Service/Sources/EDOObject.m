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

#import <objc/runtime.h>

#import "Channel/Sources/EDOSocket.h"
#import "Channel/Sources/EDOSocketChannel.h"
#import "Service/Sources/EDOClientService+Private.h"
#import "Service/Sources/EDOObject+Private.h"
#import "Service/Sources/EDOObjectReleaseMessage.h"
#import "Service/Sources/EDOServicePort.h"
#import "Service/Sources/EDOServiceRequest.h"
#import "Service/Sources/EDOValueObject.h"

static NSString *const kEDOObjectCoderPortKey = @"edoServicePort";
static NSString *const kEDOObjectCoderRemoteAddressKey = @"edoRemoteAddress";
static NSString *const kEDOObjectCoderRemoteClassKey = @"edoRemoteClass";
static NSString *const kEDOObjectCoderClassNameKey = @"edoClassName";
static NSString *const kEDOObjectCoderProcessUUIDKey = @"edoProcessUUID";

@interface EDOObject ()
/** The port to connect to the local socket. */
@property(readonly) EDOServicePort *servicePort;
/** The proxied object's address in the remote. */
@property(readonly, assign) EDOPointerType remoteAddress;
/** The proxied object's class object in the remote. */
@property(readonly, assign) EDOPointerType remoteClass;
/** The proxied object's class name in the remote. */
@property(readonly) NSString *className;
/** The process unique identifier for the remote object. */
@property(readonly) NSString *processUUID;
@end

@implementation EDOObject

// Initialize a remote object on the host side that is going to be sent back to the client side.
+ (instancetype)objectWithTarget:(id)target port:(EDOServicePort *)port {
  return [[self alloc] edo_initWithLocalObject:target port:port];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  NSAssert(sizeof(EDOPointerType) >= sizeof(void *), @"The pointer size is not big enough.");
  _servicePort = [aDecoder decodeObjectForKey:kEDOObjectCoderPortKey];
  _remoteAddress = [aDecoder decodeInt64ForKey:kEDOObjectCoderRemoteAddressKey];
  _remoteClass = [aDecoder decodeInt64ForKey:kEDOObjectCoderRemoteClassKey];
  _className = [aDecoder decodeObjectForKey:kEDOObjectCoderClassNameKey];
  _local = NO;
  _processUUID = [aDecoder decodeObjectForKey:kEDOObjectCoderProcessUUIDKey];
  return self;
}

- (BOOL)isLocalEdo {
  return [self.processUUID isEqualToString:[EDOObject edo_processUUID]];
}

- (id)returnByValue {
  return [[EDOValueObject alloc] initWithRemoteObject:self];
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

/**
 *  Forwards +[alloc] to the real class and adds an extra retain to the returned object.
 *
 *  When calling +[RemoteClass alloc], because RemoteClass is now a proxy and an instance of
 *  EDOObject, it will make an invocation of -[alloc] on the proxy EDOObject, forwarding the
 *  selector to the proxy instance; ARC will insert objc_release on the returned object, causing
 *  it to over-release. Therefore, we increasing the reference count manually to compensate for
 *  the over-release.
 *
 *  @note The stubbed class has already handled this in +[alloc] locally.
 */
- (instancetype)alloc {
  return [self edo_forwardInvocationAndRetainResultForSelector:_cmd];
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

/**
 *  -copy returns the object returned by -copyWithZone: but the EDOObject itself doesn't copy and
 *  should forward to its underlying -copy implementation. If the underlying object doesn't support
 *  or implement the proper method, exception will be propagated.
 *
 *  @note Increasing the reference count manually here to compensate the ARC release because -copy
 *        implies to own the object like -initWithXxx.
 */
- (instancetype)copy {
  return [self edo_forwardInvocationAndRetainResultForSelector:_cmd];
}

// Same as -[copy] but for the -[mutableCopy].
- (instancetype)mutableCopy {
  return [self edo_forwardInvocationAndRetainResultForSelector:_cmd];
}

- (void)dealloc {
  // Send a release message only when the object is not from the same process.
  if (![self isLocal] && ![self isLocalEdo]) {
    // Release the local edo manually to make sure the entry is removed from the cache.
    [EDOClientService removeDistantObjectReference:self.remoteAddress];
    @try {
      EDOObjectReleaseRequest *request =
          [EDOObjectReleaseRequest requestWithRemoteAddress:_remoteAddress];
      [EDOClientService sendRequest:request port:_servicePort.port];
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
  if ([object class] == [EDOObject class] &&
      [self.processUUID isEqual:((EDOObject *)object).processUUID]) {
    BOOL returnValue = NO;
    NSMethodSignature *methodSignature = [NSMethodSignature methodSignatureForSelector:_cmd];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
    invocation.target = self;
    invocation.selector = _cmd;
    [invocation setArgument:&object atIndex:2];
    [self forwardInvocation:invocation];
    [invocation getReturnValue:&returnValue];
    return returnValue;
  }
  return NO;
}

#pragma mark - NSFastEnumeration

/**
 *  Implement the fast enumeration protocol that works for the remote container like NSArray, NSSet
 *  and NSDictionary who implements "slow" enumeration's NSEnumerator. This doesn't provide the
 *  performance gain usually given by the fast enumeration but a syntax benefit such that the
 *  existing code will also work.
 *
 *  @param state    Context information that is used in the enumeration to, in addition to other
 *                  possibilities, ensure that the collection has not been mutated.
 *  @param buffer   A C array of objects over which the sender is to iterate.
 *  @param len      The maximum number of objects to return in stackbuf.
 *
 *  @return The number of objects returned in stackbuf, or 0 when the iteration is finished.
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
      state->extra[0] = (long)CFBridgingRetain([(id)self keyEnumerator]);
    } else if ([self methodSignatureForSelector:@selector(objectEnumerator)]) {
      state->extra[0] = (long)CFBridgingRetain([(id)self objectEnumerator]);
    } else {
      BOOL implementsFastEnumeration =
          ![self methodSignatureForSelector:@selector(countByEnumeratingWithState:objects:count:)];
      NSString *reason = implementsFastEnumeration
                             ? @"Fast enumeration is not supported on custom types."
                             : @"Fast enumeration is not supported on the current object.";
      [[NSException exceptionWithName:NSInternalInconsistencyException reason:reason userInfo:nil]
          raise];
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

- (instancetype)edo_forwardInvocationAndRetainResultForSelector:(SEL)selector {
  NSMethodSignature *methodSignature = [NSMethodSignature methodSignatureForSelector:selector];
  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
  invocation.target = self;
  invocation.selector = selector;
  [self forwardInvocation:invocation];

  EDOObject *returnObject;
  [invocation getReturnValue:&returnObject];
  return (__bridge id)CFBridgingRetain(returnObject);
}

@end
