//
// Copyright 2019 Google Inc.
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

#import "Channel/Sources/EDODeviceConnector.h"

NS_ASSUME_NONNULL_BEGIN

@class EDOHostPort;
@protocol EDOChannel;

@interface EDODeviceConnector (Channel)

/**
 *  Synchronously connects to a given @c hostPort that contains the device serial and a port number
 *  listening on the connected device of that device serial.
 */
- (id<EDOChannel>)connectToDevicePort:(EDOHostPort *)hostPort error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
