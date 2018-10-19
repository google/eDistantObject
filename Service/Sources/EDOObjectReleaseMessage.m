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

#import "Service/Sources/EDOObjectReleaseMessage.h"
#import "Service/Sources/EDOServiceRequest.h"

#import "Service/Sources/EDOHostService+Private.h"

static NSString *const kEDOObjectReleaseCoderIsObjectReleasedKey = @"isObjectReleased";
static NSString *const kEDOObjectReleaseCoderRemoteAddressKey = @"remoteAddress";

@interface EDOObjectReleaseRequest ()
@property(readonly) EDOPointerType remoteAddress;
@end


@implementation EDOObjectReleaseRequest

+ (BOOL)supportsSecureCoding {
  return YES;
}

- (instancetype)initWithRemoteAddress:(EDOPointerType)remoteAddress {
  self = [super init];
  if (self) {
    _remoteAddress = remoteAddress;
  }
  return self;
}

+ (instancetype)requestWithRemoteAddress:(EDOPointerType)remoteAddress {
  return [[self alloc] initWithRemoteAddress:remoteAddress];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super initWithCoder:aDecoder];
  if (self) {
    _remoteAddress = [aDecoder decodeInt64ForKey:kEDOObjectReleaseCoderRemoteAddressKey];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [super encodeWithCoder:aCoder];
  [aCoder encodeInt64:self.remoteAddress forKey:kEDOObjectReleaseCoderRemoteAddressKey];
}

+ (EDORequestHandler)requestHandler {
  return ^(EDOServiceRequest *request, EDOHostService *service) {
    EDOObjectReleaseRequest *releaseRequest = (EDOObjectReleaseRequest *)request;
    EDOPointerType edoRemoteAddress = releaseRequest.remoteAddress;
    [service removeObjectWithAddress:edoRemoteAddress];
    // The return response from the call is not being needed. So we return a generic message.
    return [[EDOServiceResponse alloc] initWithMessageId:request.messageId];
  };
}

@end
