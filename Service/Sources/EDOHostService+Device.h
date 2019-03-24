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

#import "Service/Sources/EDOHostService.h"

NS_ASSUME_NONNULL_BEGIN

/** The device support methods for @c EDOHostService. */
@interface EDOHostService (Device)

/** The flag indicating whether the host is successfully registered to the device. */
@property(readonly) BOOL registeredToDevice;

/**
 *  Creates an @c EDOHostService on host machine and registers the service @c name to the connected
 *  iOS device with the provided @c deviceSerial.
 *
 *  Only the process on the device with naming service started is reachable by this method. If the
 *  naming service is not started yet, this method will still return a service and keep trying to
 *  register the name until it times out. The naming registration process happens asynchronously in
 *  a background queue.
 *
 *  @param name         The name of the service.
 *  @param deviceSerial The device serial of the connected device. After registration, the channel
 *                      to communicate with the service will be available on the device.
 *  @param rootObject   The root object of the service. @c nil for temporary services.
 *  @param queue        The dispatch queue that the invocation will be executed on.
 *  @param seconds      The seconds to wait to successfully register the service name to the device.
 *
 *  @return An instance of EDOHostService that starts listening on the given port.
 *
 *  TODO(ynzhang): In the future we will move the EDOObject generation process from host side to
 *  client side. Then we will be able to register multiple devices for a single host service.
 */
+ (instancetype)serviceWithName:(NSString *)name
               registerToDevice:(NSString *)deviceSerial
                     rootObject:(nullable id)rootObject
                          queue:(dispatch_queue_t)queue
                        timeout:(NSTimeInterval)seconds;

@end

NS_ASSUME_NONNULL_END
