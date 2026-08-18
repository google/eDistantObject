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

@class EDOServicePort;
@class EDOWeakObject;

/**
 * The deallocation tracker to track the remote object lifecycle.
 *
 * It is associated with the underlying object of a weak object. When the underlying object is
 * released, the tracker is deallocated and it will send a release message to remove the weak object
 * entry from the dictionary in the host service.
 */
@interface EDODeallocationTracker : NSObject

/**
 * Creates an instance of the tracker that is associated with the underlying object.
 *
 * @param trackedObject The remote object that is stored in the weak object dictionary.
 * @param servicePort   The service port where weak object dictionary holds the remote object.
 */
+ (void)enableTrackingForObject:(EDOWeakObject *)trackedObject
                    servicePort:(EDOServicePort *)servicePort;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
