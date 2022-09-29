#import <Foundation/Foundation.h>

#import <objc/runtime.h>

#import "Service/Sources/EDOClientService.h"
#import "Service/Sources/EDOServiceError.h"

NS_ASSUME_NONNULL_BEGIN

@implementation NSArray (EDOArchiverDelegate)

/**
 * Checks the NSCoding conformance of the array's elements.
 *
 * @param[out] error A passed error for populating if any element of the array cannot be encoded.
 *
 * @return @c YES if all of the elements conform to NSCoding; @c NO otherwise.
 */
- (BOOL)EDOCheckEncodingConformance:(NSError **)error {
  for (id element in self) {
    if (!EDOIsRemoteObject(element) && ![element respondsToSelector:@selector(encodeWithCoder:)]) {
      if (error) {
        NSString *reason = [NSString
            stringWithFormat:
                @"The array %@ does not fully conform to NSCoding because it contains %@.",
                [self description], [element description]];
        *error = [NSError errorWithDomain:EDOServiceErrorDomain
                                     code:EDOServiceErrorRequestNotHandled
                                 userInfo:@{EDOErrorEncodingFailureReasonKey : reason}];
      }
      return NO;
    }
  }
  return YES;
}

@end

NS_ASSUME_NONNULL_END