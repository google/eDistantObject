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

#import "Channel/Sources/EDOSocketPort.h"

#include <arpa/inet.h>
#include <sys/un.h>

@implementation EDOSocketPort {
  /** The raw socker address storage. */
  struct sockaddr_storage _socketAddress;
}

- (instancetype)initWithSocket:(dispatch_fd_t)socketFD {
  self = [super init];
  if (self) {
    socklen_t addrLen = sizeof(_socketAddress);
    if (getsockname(socketFD, (struct sockaddr *)&_socketAddress, &addrLen) == -1) {
      // We ignore the failure and reset to zero, for example, the invalid socket.
      memset(&_socketAddress, 0, addrLen);
    }
  }
  return self;
}

- (UInt16)port {
  if (_socketAddress.ss_family == AF_INET) {
    return ntohs(((const struct sockaddr_in *)&_socketAddress)->sin_port);
  } else if (_socketAddress.ss_family == AF_INET6) {
    return ntohs(((const struct sockaddr_in6 *)&_socketAddress)->sin6_port);
  } else {
    return 0;
  }
}

- (NSString *)IPAddress {
  static char addressBuf[INET6_ADDRSTRLEN];
  if (_socketAddress.ss_family == AF_INET) {
    const struct sockaddr_in *addrIPv4 = (const struct sockaddr_in *)&_socketAddress;
    inet_ntop(AF_INET, &addrIPv4->sin_addr, addressBuf, sizeof(addressBuf));
  } else if (_socketAddress.ss_family == AF_INET6) {
    const struct sockaddr_in6 *addrIPv6 = (const struct sockaddr_in6 *)&_socketAddress;
    inet_ntop(AF_INET6, &addrIPv6->sin6_addr, addressBuf, sizeof(addressBuf));
  } else {
    return nil;
  }
  return [NSString stringWithUTF8String:addressBuf];
}

- (NSString *)description {
  return [NSString stringWithFormat:@"The socket on %d at %@", self.port, self.IPAddress];
}

@end
