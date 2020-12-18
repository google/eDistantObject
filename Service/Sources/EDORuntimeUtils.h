//
// Copyright 2020 Google LLC.
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

#ifdef __cplusplus
extern "C" {
#endif

/**
 *  Fetches the method signature of @c sel of @c target. If @c target doesn't
 *  have instance method for @c sel but forwards invocations through
 *  -forwardingTargetForSelector:, this function will also traverse along the
 *  forwarding chain.
 *
 *  @param target The object to fetch the method signature.
 *  @param sel   The selector of the method.
 *
 *  @return The NSMethodSignature instance that describes the method.
 */
NSMethodSignature *EDOGetMethodSignature(id target, SEL sel);

#ifdef __cplusplus
}  // extern "C"
#endif
