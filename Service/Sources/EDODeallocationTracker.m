//
// Copyright 2019 Google LLC.
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

#import "Service/Sources/EDODeallocationTracker.h"

#include <objc/runtime.h>

#import "Channel/Sources/EDOHostPort.h"
#import "Service/Sources/EDOClientService+Private.h"
#import "Service/Sources/EDOObject+Private.h"
#import "Service/Sources/EDOObjectReleaseMessage.h"

@interface EDODeallocationTracker ()

/** The remote object that is stored in the weak object dictionary. */
@property(weak) EDOObject *remoteObject;
/** The host port where weak object dictionary holds the remote object. */
@property EDOHostPort *hostPort;

@end

@implementation EDODeallocationTracker

- (instancetype)initWithRemoteObject:(EDOObject *)object hostPort:(EDOHostPort *)hostPort {
  _remoteObject = object;
  _hostPort = hostPort;
  return self;
}

- (void)dealloc {
  @try {
    EDOObjectReleaseRequest *request =
        [EDOObjectReleaseRequest requestWithWeakRemoteAddress:self.remoteObject.remoteAddress];
    [EDOClientService sendSynchronousRequest:request onPort:self.hostPort];
  } @catch (NSException *e) {
  }
}

@end
