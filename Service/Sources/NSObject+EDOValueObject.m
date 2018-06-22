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
#import "Service/Sources/NSObject+EDOValueObject.h"

#import "Service/Sources/EDOValueObject.h"

@implementation NSObject (EDOValueObject)

- (instancetype)returnByValue {
  NSString *reason =
      @"Not a remote object. returnByValue call isn't supported on non-remote objects.";
  NSException *exception =
      [NSException exceptionWithName:NSObjectNotAvailableException reason:reason userInfo:nil];
  @throw exception;  // NOLINT
  return nil;
}

- (instancetype)passByValue {
  NSAssert([self conformsToProtocol:@protocol(NSCoding)],
           @"passByValue is called on object that does not conforms to NSCoding.");
  return (id)[[EDOValueObject alloc] initWithLocalObject:(id<NSCoding>)self];
}

@end
