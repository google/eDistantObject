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

#import "Service/Sources/NSKeyedArchiver+EDOAdditions.h"

#if __MAC_OS_X_VERSION_MAX_ALLOWED < 101400 || __TV_OS_VERSION_MAX_ALLOWED < 120000 || \
    __WATCH_OS_VERSION_MAX_ALLOWED < 50000 || __IPHONE_OS_VERSION_MAX_ALLOWED < 120000
// Expose APIs available only in the latest SDK.
@interface NSKeyedArchiver (Xcode9AndBelow)
// This API is available on iOS 11 runtime but it isn't exposed in its SDK coming with
// Xcode 9.x
- (instancetype)initRequiringSecureCoding:(BOOL)requiresSecureCoding;
@end
#endif

@implementation NSKeyedArchiver (EDOAdditions)

+ (NSData *)edo_archivedDataWithObject:(id)object {
  NSKeyedArchiver *archiver;
  // We need to make sure the minimum runtime SDK requirement is set above to make the compiler
  // happy.
  if (@available(iOS 11.0, macOS 10.13, tvOS 11.0, watchOS 4.0, *)) {
    if ([NSKeyedArchiver instancesRespondToSelector:@selector(initRequiringSecureCoding:)]) {
      archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    }
  }

  // This API is deprecated in iOS 12/macOS 10.14, so we suppress warning here in case it's building
  // with the lower SDKs.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (!archiver) {
    archiver = [[NSKeyedArchiver alloc] init];
  }
#pragma clang diagnostic pop

  [archiver encodeObject:object forKey:@"edo"];
  [archiver finishEncoding];
  return archiver.encodedData;
}

@end
