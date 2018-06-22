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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSObject (ValueObject)

/**
 *  Method to be called on invocation target to get a value object from remote invocation.
 *  This should not be called on a non-remote object.
 */
- (instancetype)returnByValue;

/**
 *  Method to be called on method parameter to pass a value object to remote invocation.
 */
- (instancetype)passByValue;

@end

NS_ASSUME_NONNULL_END
