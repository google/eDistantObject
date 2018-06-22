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

#import "Service/Sources/EDOServicePort.h"

NS_ASSUME_NONNULL_BEGIN

/**
 *  The EDOClientService manages the communication to the remote objects in remote process.
 *
 *  The service manages the distant objects fetched from remote process. It provides API to make
 *  remote invocation to a @c EDOHostService running in the remote process.
 */
@interface EDOClientService : NSObject

- (instancetype)init NS_UNAVAILABLE;

/** Retrieve the root object from the given port that's listened by a service. */
+ (id)rootObjectWithPort:(UInt16)port;

/** Retrieve the class object from the given port that's listened by a service. */
+ (id)classObjectWithName:(NSString *)className port:(UInt16)port;

@end

NS_ASSUME_NONNULL_END

/**
 *  Stub the class implementation so it can resolve symbol lookup errors for the class methods.
 *
 *  The linker can't resolve class symbols when it compiles the class method statically. This macro
 *  helps to generate the stub implementation where it forwards the class method to the remote
 *  class object.
 *
 *  @note   This is not encouraged because this can resolve many remote invocations and has
 *          different memory implications, but it can provide a workaround to translate your code to
 *          a remote invocation without any modifications. If only the class method is needed, try
 *          to not enable the alloc. Because the local NSZone is passing to +[allocWithZone:], and
 *          NSZone is deprecating (also it's a struct and not supported), +[alloc] is used.
 *
 *  @param  clz The class literal.
 *  @param  p   The port that the service listens on.
 */
// TODO(haowoo): Cache the class object when we can know when the service is invalid.
// Refer to https://clang.llvm.org/docs/DiagnosticsReference.html for information about the
// ignored flags.
// TODO(ynzhang): Remove clang-format switch when b/78026272 is resolved.
// clang-format off
#define EDO_STUB_CLASS(__class, __port)                                                        \
_Pragma("clang diagnostic push")                                                             \
_Pragma("clang diagnostic ignored \"-Wincomplete-implementation\"")                          \
_Pragma("clang diagnostic ignored \"-Wprotocol\"")                                           \
_Pragma("clang diagnostic ignored \"-Wobjc-property-implementation\"")                       \
_Pragma("clang diagnostic ignored \"-Wobjc-protocol-property-synthesis\"")                   \
\
@implementation __class                                                                      \
\
+ (id) forwardingTargetForSelector : (SEL)sel {                                              \
  return [EDOClientService classObjectWithName:@""#__class port:(__port)];                   \
}                                                                                            \
\
+ (instancetype)alloc {                                                                      \
  id instance = [self forwardingTargetForSelector:_cmd];                                     \
  return (__bridge id)CFBridgingRetain([instance alloc]); /* NOLINT */                       \
}                                                                                            \
\
+ (instancetype)allocWithZone : (NSZone *)zone {                                             \
  return [self alloc];                                                                       \
}                                                                                            \
\
@end                                                                                         \
_Pragma("clang diagnostic pop")
// clang-format on

/**
 *  Fetch the remote class type.
 *
 *  When the stub is not used and the reference to the remote class is needed, this method can do
 *  the type checking and bypass the symbol lookup.
 *
 *  @note   The explicit conversion is used to have the compiler check the spelling because it
 *          converts the class literal into a NSString.
 *
 *  @param  clz The class literal
 *  @param  p   The port that the service listens on.
 */
#define EDO_REMOTE_CLASS(__class, __port) \
  ((Class)(__class *)[EDOClientService classObjectWithName:@"" #__class port:(__port)])
