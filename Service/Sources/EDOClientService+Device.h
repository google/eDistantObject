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

#import "Service/Sources/EDOClientService.h"

NS_ASSUME_NONNULL_BEGIN

@class EDOHostNamingService;

/** The device support methods for @c EDOClientService. */
@interface EDOClientService (Device)

/**
 *  Sychrounously fetch the naming service remote instance running on the physical device with given
 *  device serial. It will be used to get available listening port in the host side by service name.
 */
+ (EDOHostNamingService *)namingServiceWithDeivceSerial:(NSString *)serial
                                                  error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
