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

#import "Service/Sources/EDOExecutorMessage.h"

@implementation EDOExecutorMessage {
  /** The response for the request. */
  EDOServiceResponse *_response;
  /** The lock to signal after the request is processed and response is sent. */
  dispatch_semaphore_t _waitLock;
  /** The dispatch_once token to assign the response. */
  dispatch_once_t _responseOnceToken;
}

+ (instancetype)messageWithRequest:(EDOServiceRequest *)request
                           service:(EDOHostService *)service {
  return [[self alloc] initWithRequest:request service:service];
}

+ (instancetype)emptyMessage {
  return [[self alloc] initWithRequest:nil service:nil];
}

- (instancetype)initWithRequest:(EDOServiceRequest *)request
                        service:(EDOHostService *)service {
  self = [super init];
  if (self) {
    _request = request;
    _service = service;
    _waitLock = dispatch_semaphore_create(0L);
  }
  return self;
}

- (BOOL)isEmpty {
  return self.request == nil;
}

- (EDOServiceResponse *)waitForResponse {
  if (!_response) {
    dispatch_semaphore_wait(_waitLock, DISPATCH_TIME_FOREVER);
  }
  return _response;
}

- (BOOL)assignResponse:(EDOServiceResponse *)response {
  __block BOOL assigned = NO;
  dispatch_once(&_responseOnceToken, ^{
    self->_response = response;
    assigned = YES;
    dispatch_semaphore_signal(self->_waitLock);
  });
  return assigned;
}

@end
