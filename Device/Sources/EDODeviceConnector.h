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

/** The notification when an iOS device is attached to MacOS. */
extern NSString *const EDODeviceDidAttachNotification;
/** The notification when an iOS device is dettached to MacOS. */
extern NSString *const EDODeviceDidDetachNotification;

/**
 *  The class to connect listen port on physical iOS device from Mac. All connected devices are
 *  stored in the singleton instance and identified by device serial number.
 */
@interface EDODeviceConnector : NSObject

/** The serial number strings of connected device IDs. */
@property(readonly) NSArray<NSString *> *devicesSerials;

/** Shared device connector. */
+ (EDODeviceConnector *)sharedConnector;

/**
 *  Starts listening to devices attachment/detachment events and invoke @c completion after it is
 *  started. When device is connected/disconnected,
 *  EDODeviceDidAttachNotification/EDODeviceDidDetachNotification will be sent out accordingly after
 *  the event is detected.
 */
- (void)startListeningWithCompletion:(nullable void (^)(NSError *))completion;

/** Stops listening to the broadcast of device events. */
- (void)stopListening;

/**
 *  Synchronously connects to a given @c deviceSerial and @c port listening on the connected device
 *  of that device serial.
 */
- (dispatch_io_t)connectToDevice:(NSString *)deviceSerial
                          onPort:(UInt16)port
                           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
