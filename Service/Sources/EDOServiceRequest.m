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

#import "Service/Sources/EDOServiceRequest.h"

static NSString *const kEDOServiceRequestErrorKey = @"error";
static NSString *const kEDOServiceRequestDurationKey = @"duration";

@implementation EDOServiceRequest

+ (BOOL)supportsSecureCoding {
  return YES;
}

+ (EDORequestHandler)requestHandler {
  // Default handler that only bounces the request.
  return ^(EDOServiceRequest *request, EDOHostService *service) {
    return [EDOServiceResponse errorResponse:nil forRequest:request];
  };
}

- (BOOL)matchesService:(EDOServicePort *)unused {
  return YES;
}

@end

@implementation EDOServiceResponse

+ (BOOL)supportsSecureCoding {
  return YES;
}

- (instancetype)initWithMessageId:(NSString *)messageId error:(NSError *)error {
  self = [super initWithMessageId:messageId];
  if (self) {
    _error = error;
    _duration = 0.0;
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super initWithCoder:aDecoder];
  if (self) {
    _error = [aDecoder decodeObjectOfClass:[NSError class] forKey:kEDOServiceRequestErrorKey];
    _duration = [aDecoder decodeDoubleForKey:kEDOServiceRequestDurationKey];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [super encodeWithCoder:aCoder];
  [aCoder encodeObject:self.error forKey:kEDOServiceRequestErrorKey];
  [aCoder encodeDouble:self.duration forKey:kEDOServiceRequestDurationKey];
}

+ (EDOServiceResponse *)errorResponse:(NSError *)error forRequest:(EDOServiceRequest *)request {
  return [[self alloc] initWithMessageId:request.messageId error:error];
}

@end
