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
@interface EDOHostPort : NSObject <NSCopying, NSSecureCoding>

/** The listen port number of the host. 0 if the host port is identified by name. */
@property(readonly, nonatomic) UInt16 port;

/** The optional name of the host port. @c nil if the host port is identified by port. */
@property(readonly, nonatomic, nullable) NSString *name;

/** The device serial number string. @c nil if the connection is not to a physical iOS device. */
@property(readonly, nonatomic, nullable) NSString *deviceSerialNumber;

/**
 *  Creates a host port instance with local port number. This is used for host ports on a local
 *  machine.
 */
+ (instancetype)hostPortWithLocalPort:(UInt16)port;

/**
 *  Creates a host port instance with a unique name which is to identify the host port when
 *  communicate with a service on Mac from an iOS physical device.
 *  In this case the @c port is always 0 and @c deviceSerialNumber is always @c nil.
 */
+ (instancetype)hostPortWithName:(NSString *)name;

/**
 *  Creates a host port instance with local port number and optional service name. This is used for
 *  host ports on a local machine.
 */
+ (instancetype)hostPortWithLocalPort:(UInt16)port serviceName:(NSString *_Nullable)name;

/* Creates a host port instance with port number and optional name and device serial number. */
+ (instancetype)hostPortWithPort:(UInt16)port
                            name:(NSString *_Nullable)name
              deviceSerialNumber:(NSString *_Nullable)deviceSerialNumber;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
