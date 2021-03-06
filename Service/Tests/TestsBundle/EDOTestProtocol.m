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

#import "Service/Tests/TestsBundle/EDOTestProtocol.h"

#import <OCMock/OCMock.h>

// IWYU pragma: no_include "OCMArg.h"
// IWYU pragma: no_include "OCMFunctions.h"
// IWYU pragma: no_include "OCMLocation.h"
// IWYU pragma: no_include "OCMMacroState.h"
// IWYU pragma: no_include "OCMRecorder.h"
// IWYU pragma: no_include "OCMStubRecorder.h"
// IWYU pragma: no_include "OCMockObject.h"

@implementation EDOProtocolMockTestHelper

+ (id<EDOTestProtocol>)createTestProtocol {
  return OCMProtocolMock(@protocol(EDOTestProtocol));
}

+ (void)invokeMethodsWithProtocol:(id<EDOTestProtocol>)protocol {
  [protocol methodWithNothing];
  [protocol methodWithObject:nil];
  [protocol returnWithNothing];
  [protocol returnWithObject:self];
}

@end
