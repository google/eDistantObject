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

/**
 *  The information for a port that the host service is listening on.
 *  This interface can represent either a host port on local machine or host port on a real device.
 */
@interface EDOHostPort : NSObject <NSCopying>

/** The listen port number of the host. */
@property(readonly, nonatomic) UInt16 port;

/** The device serial number string. @c nil if the connection is not to a physical device. */
@property(readonly, nullable, nonatomic) NSString *deviceSerialNumber;

/** Creates a host port instance with local port number. This helper method is for a local host. */
+ (instancetype)hostPortWithLocalPort:(UInt16)port;

/**
 *  Create a host port instance with local port number and device serial number. This helper method
 *  is for a host running on devices.
 */
+ (instancetype)hostPortWithLocalPort:(UInt16)port
                   deviceSerialNumber:(NSString *)deviceSerialNumber;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
