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

#import "Device/Sources/EDODeviceConnector.h"

#import "Device/Sources/EDODeviceChannel.h"
#import "Device/Sources/EDODeviceDetector.h"
#import "Device/Sources/EDOUSBMuxUtil.h"

NSString *const EDODeviceDidAttachNotification = @"EDODeviceDidAttachNotification";
NSString *const EDODeviceDidDetachNotification = @"EDODeviceDidDetachNotification";

/** Timeout for connecting to device. */
static const int64_t kDeviceConnectTimeout = 5 * NSEC_PER_SEC;

@implementation EDODeviceConnector {
  BOOL _startedListening;
  // Mappings from device serial strings to auto-assigned device IDs.
  NSMutableDictionary<NSString *, NSNumber *> *_deviceInfo;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _startedListening = NO;
    _deviceInfo = [[NSMutableDictionary alloc] init];
  }
  return self;
}

+ (EDODeviceConnector *)sharedConnector {
  static EDODeviceConnector *sharedConnector;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedConnector = [[EDODeviceConnector alloc] init];
  });
  return sharedConnector;
}

- (void)startListeningWithCompletion:(void (^)(NSError *))completion {
  // Already connected to usbmuxd.
  if (_startedListening) {
    if (completion) {
      completion(nil);
    }
    return;
  }
  EDODeviceDetector *detector = [EDODeviceDetector sharedInstance];
  [detector listenWithBroadcastHandler:^(NSDictionary *packet, NSError *error) {
    if (error) {
      [detector cancel];
      NSLog(@"Failed to listen to broadcast from usbmuxd: %@", error);
    }
    self->_startedListening = YES;
    [self handleBroadcastPacket:packet];
  }];
}

- (void)stopListening {
  [EDODeviceDetector.sharedInstance cancel];
  [_deviceInfo removeAllObjects];
  _startedListening = NO;
}

- (NSArray<NSString *> *)devicesSerials {
  return [_deviceInfo.allKeys copy];
}

- (dispatch_io_t)connectToDevice:(NSString *)deviceSerial
                          onPort:(UInt16)port
                           error:(NSError **)error {
  NSNumber *deviceID = _deviceInfo[deviceSerial];
  NSAssert(deviceID != nil, @"Device %@ is not detected.", deviceSerial);

  NSDictionary *packet = [EDOUSBMuxUtil connectPacketWithDeviceID:deviceID port:port];
  __block NSError *connectError;
  EDODeviceChannel *channel = [EDODeviceChannel channelWithError:&connectError];
  dispatch_semaphore_t lock = dispatch_semaphore_create(0);
  [channel sendPacket:packet
           completion:^(NSError *packetError) {
             if (packetError) {
               connectError = packetError;
             }
             dispatch_semaphore_signal(lock);
           }];
  dispatch_semaphore_wait(lock, dispatch_time(DISPATCH_TIME_NOW, kDeviceConnectTimeout));

  [channel
      receivePacketWithHandler:^(NSDictionary *_Nullable packet, NSError *_Nullable packetError) {
        if (packetError) {
          connectError = packetError;
        }
        dispatch_semaphore_signal(lock);
      }];
  dispatch_semaphore_wait(lock, dispatch_time(DISPATCH_TIME_NOW, kDeviceConnectTimeout));

  dispatch_io_t dispatchChannel = [channel releaseChannel];
  if (error) {
    *error = connectError;
  }
  return connectError ? nil : dispatchChannel;
}

#pragma mark - Private

- (void)handleBroadcastPacket:(NSDictionary *)packet {
  NSString *messageType = [packet objectForKey:kEDOMessageTypeKey];

  if ([messageType isEqualToString:kEDOMessageTypeAttachedKey]) {
    NSNumber *deviceID = packet[kEDOMessageDeviceIDKey];
    NSString *serialNumber = packet[kEDOMessagePropertiesKey][kEDOMessageSerialNumberKey];
    [_deviceInfo setObject:deviceID forKey:serialNumber];
    [[NSNotificationCenter defaultCenter] postNotificationName:EDODeviceDidAttachNotification
                                                        object:self
                                                      userInfo:packet];
  } else if ([messageType isEqualToString:kEDOMessageTypeDetachedKey]) {
    NSNumber *deviceID = packet[kEDOMessageDeviceIDKey];
    for (NSString *serialNumberString in _deviceInfo) {
      if ([_deviceInfo[serialNumberString] isEqualToNumber:deviceID]) {
        [_deviceInfo removeObjectForKey:serialNumberString];
      }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:EDODeviceDidDetachNotification
                                                        object:self
                                                      userInfo:packet];
  } else {
    NSLog(@"Warning: Unhandled broadcast message: %@", packet);
  }
}

@end
