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

@interface EDODeviceDetector ()
/**
 *  The channel to communicate with usbmuxd. It is lazily loaded when listenWithBroadcastHandler:
 *  is called.
 */
@property EDODeviceChannel *channel;

@end

@implementation EDODeviceDetector

- (BOOL)listenToBroadcastWithError:(NSError **)error
                    receiveHandler:(BroadcastHandler)receiveHandler {
  __block BOOL success = NO;
  __block NSError *resultError;
  @synchronized(self) {
    if (!self.channel) {
      NSError *channelError = nil;
      self.channel = [EDODeviceChannel channelWithError:&channelError];
      if (channelError) {
        resultError = channelError;
      } else {
        NSDictionary *packet = [EDOUSBMuxUtil listenPacket];
        // Synchronously send the listen packet and read response.
        dispatch_semaphore_t lock = dispatch_semaphore_create(0);
        [self.channel
            sendPacket:packet
            completion:^(NSError *packetSendError) {
              if (packetSendError) {
                resultError = packetSendError;
                dispatch_semaphore_signal(lock);
              } else {
                [self->_channel receivePacketWithHandler:^(NSDictionary *_Nonnull packet,
                                                           NSError *_Nonnull error) {
                  NSError *rootError = error ?: [EDOUSBMuxUtil errorFromPlistResponsePacket:packet];
                  if (rootError) {
                    resultError = rootError;
                  } else {
                    NSAssert([packet[kEDOMessageTypeKey] isEqualToString:kEDOPlistPacketTypeResult],
                             @"Invalid result packet type.");
                    success = YES;
                  }
                  dispatch_semaphore_signal(lock);
                }];
              }
            }];
        dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
        if (success) {
          // Schedule read recursively to constantly listen to broadcast event.
          [self scheduleReadBroadcastPacketWithHandler:receiveHandler];
        }
      }
    }
  }
  if (resultError) {
    NSLog(@"Failed to listen to broadcast: %@", resultError);
    if (error) {
      *error = resultError;
    }
  }
  return success;
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
