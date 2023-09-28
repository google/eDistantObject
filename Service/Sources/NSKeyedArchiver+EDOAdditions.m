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

#import <objc/runtime.h>

#import "Service/Sources/EDOClientService.h"
#import "Service/Sources/EDOServiceError.h"
#import "Service/Sources/EDOServiceException.h"

NS_ASSUME_NONNULL_BEGIN

/** The delegate used for encoding eDO outgoing parameters. */
@interface EDOKeyedArchiverDelegate : NSObject <NSKeyedArchiverDelegate>

/** Initializes the object with the root object that is going to be encoded. */
- (instancetype)initWithRootObject:(id)rootObject NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

@implementation EDOKeyedArchiverDelegate {
  /** The object that is encoded by the attached NSKeyedArchiver of this delegate. */
  id _rootObject;
}

- (instancetype)initWithRootObject:(id)rootObject {
  self = [super init];
  if (self) {
    _rootObject = rootObject;
  }
  return self;
}

#pragma mark - NSKeyedArchiverDelegate

- (nullable id)archiver:(NSKeyedArchiver *)archiver willEncodeObject:(id)object {
  if (!EDOIsRemoteObject(object) &&
      [object respondsToSelector:@selector(EDOCheckEncodingConformance:)]) {
    NSError *error;
    if (![object EDOCheckEncodingConformance:&error]) {
      [self raiseEncodingConformanceError:error withEncodingObject:object];
    }
  }
  return object;
}

#pragma mark - Private

/**
 * Throws an exception for the failed NSCoding conformance check during the encoding procedure.
 *
 * @param error  The error that contains the underlying reason that encoding will fail. The error
 *               reason must be included in the `EDOErrorEncodingFailureReasonKey` of the
 *               `userInfo`.
 * @param object The object that will cause the encoding failure.
 */
- (void)raiseEncodingConformanceError:(NSError *)error withEncodingObject:(id)object {
  NSString *reason = [NSString
      stringWithFormat:
          @"eDO fails to encode a parameter which is sent for remote invocation. Please check if "
          @"the parameter fully conforming to NSCoding.\n\nThe parameter is: %@\nDetail: %@",
          [_rootObject description], error.userInfo[EDOErrorEncodingFailureReasonKey]];
  [[NSException exceptionWithName:EDOTypeEncodingException reason:reason userInfo:nil] raise];
}

/** @return Awalys @c NO because this class doesn't conform to NSCoding. */
- (BOOL)EDOCheckEncodingConformance:(NSError **)error {
  return NO;
}

@end

@implementation NSKeyedArchiver (EDOAdditions)

+ (NSData *)edo_archivedDataWithObject:(id)object {
  // In Xcode 10.0, we can use the newer APIs.
#if (defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 101400) || \
    (defined(__TV_OS_VERSION_MAX_ALLOWED) && __TV_OS_VERSION_MAX_ALLOWED >= 120000) ||       \
    (defined(__WATCH_OS_VERSION_MAX_ALLOWED) && __WATCH_OS_VERSION_MAX_ALLOWED >= 120000) || \
    (defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 120000)
  if (@available(iOS 11.0, macOS 10.13, tvOS 11.0, watchOS 4.0, *)) {
    // Use instancesRespondToSelector check because it's possible that something loads this on a
    // lower iOS version than what it was built with, in which case the availability macros alone
    // fail to protect it.
    if ([NSKeyedArchiver instancesRespondToSelector:@selector(initRequiringSecureCoding:)]) {
      NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
      EDOKeyedArchiverDelegate *delegate =
          [[EDOKeyedArchiverDelegate alloc] initWithRootObject:object];
      archiver.delegate = delegate;
      [archiver encodeObject:object forKey:NSKeyedArchiveRootObjectKey];
      [archiver finishEncoding];
      return archiver.encodedData;
    }
  }
#endif

  return [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:NO error:nil];
}

@end

NS_ASSUME_NONNULL_END