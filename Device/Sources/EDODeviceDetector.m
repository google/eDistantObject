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

#import "Device/Sources/EDODeviceDetector.h"

#import "Device/Sources/EDODeviceChannel.h"
#import "Device/Sources/EDOUSBMuxUtil.h"

@implementation EDODeviceDetector {
  EDODeviceChannel *_channel;
}

+ (instancetype)sharedInstance {
  static EDODeviceDetector *sharedDetector;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedDetector = [[EDODeviceDetector alloc] init];
  });
  return sharedDetector;
}

- (BOOL)listenWithBroadcastHandler:(void (^)(NSDictionary *packet,
                                             NSError *error))broadcastHandler {
  if (_channel) {
    return NO;
  }
  __block NSError *channelError;
  _channel = [EDODeviceChannel channelWithError:&channelError];
  if (channelError) {
    return NO;
  }

  NSDictionary *packet = [EDOUSBMuxUtil listenPacket];
  // Synchronously send the listen packet and read response.
  dispatch_semaphore_t lock = dispatch_semaphore_create(0);
  [_channel sendPacket:packet
            completion:^(NSError *error) {
              if (error) {
                NSLog(@"Error sending packet to usbmuxd: %@", error);
              }
              [self->_channel receivePacketWithHandler:^(NSDictionary *_Nonnull packet,
                                                         NSError *_Nonnull error) {
                NSError *rootError = error ?: [EDOUSBMuxUtil errorFromPlistResponsePacket:packet];
                if (rootError) {
                  NSLog(@"Error when receiving packet from usbmuxd: %@", rootError);
                } else {
                  NSAssert([packet[kEDOMessageTypeKey] isEqualToString:kEDOPlistPacketTypeResult],
                           @"Invalid result packet type.");
                }
                dispatch_semaphore_signal(lock);
              }];
            }];
  dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);

  // Schedule read recursively to constantly listen to broadcast event.
  [self scheduleReadBroadcastPacketWithHandler:broadcastHandler];
  return YES;
}

- (void)cancel {
  _channel = nil;
}

#pragma mark - Private

- (void)scheduleReadBroadcastPacketWithHandler:(void (^)(NSDictionary *packet,
                                                         NSError *error))handler {
  [_channel receivePacketWithHandler:^(NSDictionary *packet, NSError *error) {
    // Interpret the broadcast packet we just received
    if (handler) {
      handler(packet, error);
    }

    // Re-schedule reading another incoming broadcast packet
    if (!error) {
      [self scheduleReadBroadcastPacketWithHandler:handler];
    }
  }];
}

@end
