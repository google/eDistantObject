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
#include <stdatomic.h>

@implementation EDOExecutorMessage {
  /** The execution block to be processed by the executor. */
  void (^_executeBlock)(void);
  /** The boolean to indicate if execution has started. */
  atomic_flag _started;
  /** The lock to signal after the request is processed and response is sent. */
  dispatch_group_t _executedGroup;
}

- (instancetype)initWithBlock:(void (^)(void))executeBlock {
  self = [super init];
  if (self) {
    _executeBlock = executeBlock;
    atomic_flag_clear(&_started);
    _executedGroup = dispatch_group_create();
    dispatch_group_enter(_executedGroup);
  }
  return self;
}

- (void)waitForCompletion {
  dispatch_group_wait(_executedGroup, DISPATCH_TIME_FOREVER);
}

- (BOOL)executeBlock {
  if (!atomic_flag_test_and_set(&_started)) {
    _executeBlock();
    dispatch_group_leave(_executedGroup);
    return YES;
  };
  return NO;
}

@end
