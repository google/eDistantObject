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

#import "Service/Sources/EDOObjectMessage.h"

#import "Service/Sources/EDOHostService+Private.h"

static NSString *const EDOObjectCoderObjectKey = @"object";

#pragma mark -

@implementation EDOObjectRequest

// Only the type placeholder, don't need to override the [initWithCoder:] and [encodeWithCoder:]

+ (EDORequestHandler)requestHandler {
  return ^(EDOServiceRequest *request, EDOHostService *service) {
    return [EDOObjectResponse responseWithObject:service.rootObject forRequest:request];
  };
}

+ (instancetype)request {
  return [[self alloc] init];
}

@end

#pragma mark -

@implementation EDOObjectResponse

- (instancetype)initWithObject:(EDOObject *)object forRequest:(EDOServiceRequest *)request {
  self = [self initWithMessageId:request.messageId];
  if (self) {
    _object = object;
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super initWithCoder:aDecoder];
  if (self) {
    _object = [aDecoder decodeObjectForKey:EDOObjectCoderObjectKey];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [super encodeWithCoder:aCoder];
  [aCoder encodeObject:self.object forKey:EDOObjectCoderObjectKey];
}

+ (EDOServiceResponse *)responseWithObject:(EDOObject *)object
                                forRequest:(EDOServiceRequest *)request {
  return [[self alloc] initWithObject:object forRequest:request];
}

@end
