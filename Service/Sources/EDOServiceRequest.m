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

@implementation EDOServiceRequest

+ (EDORequestHandler)requestHandler {
  // Default handler that only bounces the request.
  return ^(EDOServiceRequest *request, EDOHostService *service) {
    return [EDOServiceResponse errorResponse:nil forRequest:request];
  };
}

- (BOOL)canMatchService:(EDOServicePort *)unused {
  return YES;
}

@end

@implementation EDOServiceResponse

- (instancetype)initWithMessageId:(NSString *)messageId error:(NSError *)error {
  self = [super initWithMessageId:messageId];
  if (self) {
    _error = error;
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super initWithCoder:aDecoder];
  if (self) {
    _error = [aDecoder decodeObjectForKey:@"error"];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [super encodeWithCoder:aCoder];
  [aCoder encodeObject:self.error forKey:@"error"];
}

+ (EDOServiceResponse *)errorResponse:(NSError *)error forRequest:(EDOServiceRequest *)request {
  return [[self alloc] initWithMessageId:request.messageId error:error];
}

@end
