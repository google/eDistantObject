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
static NSString *const EDOServicePortCoderUUIDKey = @"uuid";

@implementation EDOServicePort {
  uuid_t _serviceKey;
}

+ (instancetype)servicePortWithPort:(UInt16)port {
  return [[self alloc] initWithPort:port];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _port = 0;
    uuid_generate(_serviceKey);
  }
  return self;
}

- (instancetype)initWithPort:(UInt16)port {
  self = [self init];
  if (self) {
    _port = port;
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super init];
  if (self) {
    _port = (UInt16)[aDecoder decodeIntForKey:EDOServicePortCoderPortKey];
    uuid_copy(_serviceKey, [aDecoder decodeBytesForKey:EDOServicePortCoderUUIDKey
                                        returnedLength:NULL]);
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [aCoder encodeInteger:self.port forKey:EDOServicePortCoderPortKey];
  [aCoder encodeBytes:_serviceKey length:sizeof(_serviceKey) forKey:EDOServicePortCoderUUIDKey];
}

- (BOOL)match:(EDOServicePort *)otherPort {
  return self.port == otherPort.port && uuid_compare(_serviceKey, otherPort->_serviceKey) == 0;
}

@end
