#import "Service/Sources/EDORemoteException.h"

@implementation EDORemoteException

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

@end
