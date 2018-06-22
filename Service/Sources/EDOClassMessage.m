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

#import "Service/Sources/EDOClassMessage.h"

#import "Service/Sources/EDOHostService+Private.h"

static NSString *const kEDOObjectCoderClassNameKey = @"className";

#pragma mark -

@interface EDOClassRequest ()
/** The class name. */
@property(readonly) NSString *className;
@end

#pragma mark -

@implementation EDOClassRequest

+ (EDORequestHandler)requestHandler {
  return ^(EDOServiceRequest *request, EDOHostService *service) {
    EDOClassRequest *classRequest = (EDOClassRequest *)request;
    Class clz = NSClassFromString(classRequest.className);
    EDOObject *object = clz ? [service distantObjectForLocalObject:clz] : nil;
    return [EDOClassResponse responseWithObject:object forRequest:request];
  };
}

+ (instancetype)requestWithClassName:(NSString *)className {
  return [[self alloc] initWithClassName:className];
}

- (instancetype)initWithClassName:(NSString *)className {
  self = [super init];
  if (self) {
    _className = className;
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super initWithCoder:aDecoder];
  if (self) {
    _className = [aDecoder decodeObjectForKey:kEDOObjectCoderClassNameKey];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [super encodeWithCoder:aCoder];
  [aCoder encodeObject:self.className forKey:kEDOObjectCoderClassNameKey];
}

- (NSString *)description {
  return [NSString stringWithFormat:@"Class request (%@) name: %@", self.messageId, self.className];
}

@end

#pragma mark -

@implementation EDOClassResponse

- (NSString *)description {
  return [NSString stringWithFormat:@"Class response (%@)", self.messageId];
}

@end
