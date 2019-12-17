#import "Service/Sources/EDORemoteException.h"

static NSString *const kEDORemoteExceptionCoderName = @"name";
static NSString *const kEDORemoteExceptionCoderReason = @"reason";
static NSString *const kEDORemoteExceptionCoderStacks = @"callStackSymbols";

@implementation EDORemoteException

+ (BOOL)supportsSecureCoding {
  return YES;
}

- (instancetype)initWithName:(NSExceptionName)name
                      reason:(NSString *)reason
            callStackSymbols:(NSArray<NSString *> *)callStackSymbols {
  self = [super init];
  if (self) {
    _name = [name copy];
    _reason = [reason copy];
    _callStackSymbols = [callStackSymbols copy];
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super init];
  if (self) {
    _name = [aDecoder decodeObjectOfClass:[NSString class] forKey:kEDORemoteExceptionCoderName];
    _reason = [aDecoder decodeObjectOfClass:[NSString class] forKey:kEDORemoteExceptionCoderReason];
    _callStackSymbols =
        [aDecoder decodeObjectOfClasses:[NSSet setWithArray:@[ [NSArray class], [NSString class] ]]
                                 forKey:kEDORemoteExceptionCoderStacks];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [aCoder encodeObject:self.name forKey:kEDORemoteExceptionCoderName];
  [aCoder encodeObject:self.reason forKey:kEDORemoteExceptionCoderReason];
  [aCoder encodeObject:self.callStackSymbols forKey:kEDORemoteExceptionCoderStacks];
}

@end
