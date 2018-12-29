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

#import "Channel/Sources/EDOHostPort.h"

@implementation EDOHostPort

+ (instancetype)hostPortWithLocalPort:(UInt16)port {
  return [[EDOHostPort alloc] initWithPort:port name:nil deviceSerialNumber:nil];
}

+ (instancetype)hostPortWithLocalPort:(UInt16)port
                   deviceSerialNumber:(NSString *)deviceSerialNumber {
  return [[EDOHostPort alloc] initWithPort:port name:nil deviceSerialNumber:deviceSerialNumber];
}

+ (instancetype)hostPortWithName:(NSString *)name {
  return [[EDOHostPort alloc] initWithPort:0 name:name deviceSerialNumber:nil];
}

- (instancetype)initWithPort:(UInt16)port
                        name:(NSString *)name
          deviceSerialNumber:(NSString *)deviceSerialNumber {
  self = [super init];
  if (self) {
    _port = port;
    _name = name;
    _deviceSerialNumber = [deviceSerialNumber copy];
  }
  return self;
}

#pragma mark - Object Equality

- (BOOL)isEqual:(id)other {
  if (other == self) {
    return YES;
  } else if ([other isKindOfClass:[self class]]) {
    EDOHostPort *otherPort = (EDOHostPort *)other;
    BOOL isPortEqual = _port == otherPort.port;
    BOOL isSerialEqual = _deviceSerialNumber == otherPort.deviceSerialNumber ||
                         [_deviceSerialNumber isEqualToString:otherPort.deviceSerialNumber];
    BOOL isNameEqual = _name == otherPort.name || [_name isEqualToString:otherPort.name];
    return isPortEqual && isSerialEqual && isNameEqual;
  }
  return NO;
}

- (NSUInteger)hash {
  return [_deviceSerialNumber hash] ^ [_name hash] ^ _port;
}

#pragma mark - NSCopying

- (id)copyWithZone:(nullable NSZone *)zone {
  return [[EDOHostPort alloc] initWithPort:_port name:_name deviceSerialNumber:_deviceSerialNumber];
}

@end
