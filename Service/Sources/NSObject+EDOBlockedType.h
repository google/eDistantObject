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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 *  This category provides APIs to statically block a class to be used in remote invocation.
 *
 *  It provides a way to prevent certain types of instances being created in the wrong process
 *  and sent to system APIs as a remote object. For example, iOS app cannot add a remote UIView
 *  as the subview of another native UIView. If a type is blocked in remote invocation,
 *  its instance, which is created in this process by mistake, will throw an exception when it
 *  appears in a remote invocation.
 */
@interface NSObject (EDOBlockedType)

/**
 *  Blocks this type to be a parameter of remote invocation.
 *
 *  If a class is blocked, its instances are not allowed to be either parameters or return
 *  values in remote invocation.
 */
+ (void)edo_disallowRemoteInvocation;

/**
 *  Blocks this type, excluding @c excludedSubclasses, to be a parameter of remote invocation.
 *
 *  @param excludedSubclasses The classes to be excluded from the blocklist. They must be the
 *                            subclasses of the caller class.
 */
+ (void)edo_disallowRemoteInvocationWithExlcusion:(NSArray<Class> *)excludedSubclasses;

/**
 *  Allow this type to be a parameter of remote invocation, even if its super class is disallowed.
 *
 *  If as class is blocked, its subclasses are also blocked for remote invocation. This method will
 *  exclude a class and its subclasses from the blocklist.
 *
 *  @note The exclusion has higher priority than the blocklist, i.e., by excluding a class, all of
 *        its subclasses cannot be added to the blocklist, and doing so will result in an exception.
 *  @note This call can overwrite -edo_disallowRemoteInvocation, but not the reverse.
 */
+ (void)edo_alwaysAllowRemoteInvocation;

/** The boolean to indicate if @c self is blocked in remote invocation. */
@property(readonly, class) BOOL edo_remoteInvocationDisallowed;

/** The boolean to indicate if @c self is excluded from the blocklist of the remote invocation. */
@property(readonly, class) BOOL edo_remoteInvocationAlwaysAllowed;

@end

NS_ASSUME_NONNULL_END
