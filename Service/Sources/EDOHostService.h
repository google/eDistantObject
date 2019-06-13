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

@class EDOServicePort;

/**
 *  The EDOHostService is a service hosting remote objects for remote process.
 *
 *  The service manages the distant objects and its life cycles. The distant object is always
 *  associated with a service, and any inherited objects will share the same attributes (i.e.
 *  another distant object returned by the method). If a local object is passed as a parameter to
 *  a remote invocation, it is converted to a distant object from the service associate with the
 *  current execution queue; If none exists, an exception is raised.
 */
@interface EDOHostService : NSObject

/** The port to identify the service. */
@property(readonly, nonatomic) EDOServicePort *port;

/**
 *  Creates a service with the object and its associated execution queue.
 *
 *  @note Once the service is up and running, @c EDOClientService can be used to retrieve the root
 *        object or the remote class. A generated UUID will be used as the unique service name.
 *
 *  @param port   The port the service will listen on. If 0 is given, the port will be automatically
 *                assigned.
 *  @param object The root object.
 *  @param queue  The dispatch queue that the invocation will be executed on.
 *
 *  @return An instance of EDOHostService that starts listening on the given port.
 */
+ (instancetype)serviceWithPort:(UInt16)port
                     rootObject:(nullable id)object
                          queue:(nullable dispatch_queue_t)queue;

/**
 *  Creates a service with the service name, the root object and its associated execution queue.
 *
 *  @note Once the service is up and running, @c EDOClientService can be used to retrieve the root
 *        object or the remote class.
 *
 *  @param name   The service name of the @c EDOHostService. It is used to identify the service.
 *  @param object The root object.
 *  @param queue  The dispatch queue that the invocation will be executed on.
 *
 *  @return An instance of EDOHostService that starts listening on an auto-assigned port.
 */
+ (instancetype)serviceWithRegisteredName:(NSString *)name
                               rootObject:(nullable id)object
                                    queue:(nullable dispatch_queue_t)queue;

/**
 *  Gets the EDOHostService associated with the given dispatch queue if any.
 *
 *  @param queue The dispatch queue to retrieve the EDOHostService.
 *  @return The instance of EDOHostService if it has been set up, or @nil if not.
 */
+ (instancetype)serviceForQueue:(dispatch_queue_t)queue;

/**
 *  Gets the EDOHostService associated with the current running dispatch queue, if any.
 *
 *  @return The instance of EDOHostService if it has been set up, or @nil if not.
 */
+ (instancetype)serviceForCurrentQueue;

- (instancetype)init NS_UNAVAILABLE;

/** Invalidates the service and releases all the associated objects. */
- (void)invalidate;

@end

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
