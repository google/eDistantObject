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

#import "Service/Sources/NSObject+EDOWeakObject.h"

#include <objc/runtime.h>

#import "Service/Sources/EDOWeakObject.h"

@implementation NSObject (EDOWeakObject)

- (instancetype)remoteWeak {
  static dispatch_queue_t syncQueue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    syncQueue = dispatch_queue_create("com.google.edo.weakobj", DISPATCH_QUEUE_SERIAL);
  });
  __block id weakObject;
  dispatch_sync(syncQueue, ^{
    weakObject = objc_getAssociatedObject(self, &_cmd);
    if (!weakObject) {
      weakObject = [[EDOWeakObject alloc] initWithWeakObject:self];
      objc_setAssociatedObject(self, &_cmd, weakObject, OBJC_ASSOCIATION_RETAIN);
    }
  });
  return weakObject;
}

@end
