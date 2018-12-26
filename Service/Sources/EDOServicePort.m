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

#import "Service/Sources/EDOServicePort.h"

static NSString *const EDOServicePortCoderPortKey = @"port";
static NSString *const EDOServicePortCoderNameKey = @"serviceName";
static NSString *const EDOServicePortCoderUUIDKey = @"uuid";

@implementation EDOServicePort {
  uuid_t _serviceKey;
}

+ (BOOL)supportsSecureCoding {
  return YES;
}

+ (instancetype)servicePortWithPort:(UInt16)port serviceName:(NSString *)serviceName {
  return [[self alloc] initWithPort:port serviceName:serviceName];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _port = 0;
    uuid_generate(_serviceKey);
  }
  return self;
}

- (instancetype)initWithPort:(UInt16)port serviceName:(NSString *)serviceName {
  self = [self init];
  if (self) {
    _port = port;
    _serviceName = serviceName;
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super init];
  if (self) {
    _port = (UInt16)[aDecoder decodeIntForKey:EDOServicePortCoderPortKey];
    _serviceName = [aDecoder decodeObjectOfClass:[NSString class]
                                          forKey:EDOServicePortCoderNameKey];
    uuid_copy(_serviceKey, [aDecoder decodeBytesForKey:EDOServicePortCoderUUIDKey
                                        returnedLength:NULL]);
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [aCoder encodeInteger:self.port forKey:EDOServicePortCoderPortKey];
  [aCoder encodeObject:self.serviceName forKey:EDOServicePortCoderNameKey];
  [aCoder encodeBytes:_serviceKey length:sizeof(_serviceKey) forKey:EDOServicePortCoderUUIDKey];
}

- (BOOL)match:(EDOServicePort *)otherPort {
  return self.port == otherPort.port && [self.serviceName isEqualToString:otherPort.serviceName] &&
         uuid_compare(_serviceKey, otherPort->_serviceKey) == 0;
}

@end
