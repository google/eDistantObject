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

#import "Service/Sources/EDOObjectAliveMessage.h"

#import "Service/Sources/EDOHostService+Private.h"
#import "Service/Sources/EDOHostService.h"
#import "Service/Sources/EDOMessage.h"
#import "Service/Sources/EDOObject+Private.h"
#import "Service/Sources/EDOObject.h"
#import "Service/Sources/EDOServicePort.h"
#import "Service/Sources/EDOServiceRequest.h"

static NSString *const kEDOObjectAliveCoderRemoteAddressKey = @"remoteAddress";
static NSString *const kEDOObjectAliveCoderServicePortKey = @"servicePort";
static NSString *const kEDOObjectAliveCoderIsAliveKey = @"isAlive";

#pragma mark -

@interface EDOObjectAliveRequest ()
/** The proxied object's address in the remote. */
@property(nonatomic, readonly) EDOPointerType remoteAddress;
/** The port to connect to the local socket. */
@property(nonatomic, readonly) EDOServicePort *servicePort;
@end

#pragma mark -

@implementation EDOObjectAliveRequest

+ (BOOL)supportsSecureCoding {
  return YES;
}

- (instancetype)initWithObject:(EDOObject *)object {
  self = [super init];
  if (self) {
    _servicePort = object.servicePort;
    _remoteAddress = object.remoteAddress;
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super initWithCoder:aDecoder];
  if (self) {
    _servicePort = [aDecoder decodeObjectOfClass:[EDOServicePort class]
                                          forKey:kEDOObjectAliveCoderServicePortKey];
    _remoteAddress = [aDecoder decodeInt64ForKey:kEDOObjectAliveCoderRemoteAddressKey];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [super encodeWithCoder:aCoder];
  [aCoder encodeObject:self.servicePort forKey:kEDOObjectAliveCoderServicePortKey];
  [aCoder encodeInt64:self.remoteAddress forKey:kEDOObjectAliveCoderRemoteAddressKey];
}

+ (EDORequestHandler)requestHandler {
  return ^(EDOServiceRequest *request, EDOHostService *service) {
    EDOObjectAliveRequest *retainRequest = (EDOObjectAliveRequest *)request;
    BOOL isAlive = [service isObjectAliveWithPort:retainRequest.servicePort
                                    remoteAddress:retainRequest.remoteAddress];
    return [[EDOObjectAliveResponse alloc] initWithResult:isAlive forRequest:request];
  };
}

+ (instancetype)requestWithObject:(EDOObject *)object {
  return [[self alloc] initWithObject:object];
}

@end

#pragma mark -

@implementation EDOObjectAliveResponse

+ (BOOL)supportsSecureCoding {
  return YES;
}

- (instancetype)initWithResult:(BOOL)isAlive forRequest:(EDOServiceRequest *)request {
  self = [super initWithMessageID:request.messageID];
  if (self) {
    _alive = isAlive;
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super initWithCoder:aDecoder];
  if (self) {
    _alive = [aDecoder decodeBoolForKey:kEDOObjectAliveCoderIsAliveKey];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [super encodeWithCoder:aCoder];
  [aCoder encodeBool:self.isAlive forKey:kEDOObjectAliveCoderIsAliveKey];
}

@end
