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

/**
 *  The EDOWeakObject wraps the weak object as an NSProxy.
 */
@interface EDOWeakObject : NSProxy

@property(nonatomic, readonly, weak) id weakObject;

- (instancetype)init NS_UNAVAILABLE;

/**
 *  Associates the weak object with EDOWeakObject.
 */
- (instancetype)initWithWeakObject:(id)weakObject;

@end

NS_ASSUME_NONNULL_END
