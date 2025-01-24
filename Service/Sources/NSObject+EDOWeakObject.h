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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** NSObject extension to help with weak referenced objects. */
@interface NSObject (EDOWeakObject)

/**
 * Wraps an @c NSObject into a @c EDOWeakObject, which can be held weakly by a remote process.
 *
 * When an object is wrapped in an @c EDOObject and passed to a remote process, and the remote
 * process only holds a weak reference to the @c EDOObject, the @c EDOObject may be deallocated
 * prematurely without other strong references.
 *
 * With @c remoteWeak, the object is wrapped in an @c EDOWeakObject, which triggers additional logic
 * on the remote process to retain the @c EDOObject until the underlying object has been released.
 *
 * Passing weak objects that point to the same underlying object to multiple EDO client services is
 * *not* supported and doing so will lead to objects not being cleaned up properly on the client.
 *
 * Usage for assigning a local object to a weak reference of a remote object:
 * @code
 *   remoteObject.weakReference = [localObject remoteWeak];
 * @endcode
 */
- (instancetype)remoteWeak;

@end

NS_ASSUME_NONNULL_END
