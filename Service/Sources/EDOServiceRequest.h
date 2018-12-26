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

#import <Foundation/Foundation.h>

#import "Service/Sources/EDOMessage.h"

NS_ASSUME_NONNULL_BEGIN

@class EDOHostService;
@class EDOServicePort;
@class EDOServiceRequest;
@class EDOServiceResponse;

/**
 *  The request handler.
 *
 *  @param request The incoming request.
 *  @param context The context of the response handler. It is usually the host service instance.
 *
 *  @return The response.
 */
typedef EDOServiceResponse *_Nonnull (^EDORequestHandler)(EDOServiceRequest *request,
                                                          id _Nullable context);

/** The base request class for the request to send. */
@interface EDOServiceRequest : EDOMessage

/**
 *  The request handler.
 *
 *  The sub classes should override this and provide its own handler. The default implementation
 *  returns nil.
 */
@property(readonly, class) EDORequestHandler requestHandler;

- (instancetype)initWithMessageId:(NSString *)messageId NS_UNAVAILABLE;

/**
 *  Checks if the request matches the @c port.
 *
 *  @note The default implementation will always return YES. Subclasses should override this
 *        if it contains the service-sensitive information such as the object address.
 *
 *  @param port The service identity from which this request will send to.
 *
 *  @return YES if both the service port and UUID matches, that is, for the same service.
 */
- (BOOL)matchesService:(EDOServicePort *)port;

@end

/** The base response class for the response to receive. */
@interface EDOServiceResponse : EDOMessage

/** The error object if there is any. */
@property(readonly, nonatomic, nullable) NSError *error;
/** Time spent in seconds to generate the response. */
@property(nonatomic) double duration;

- (instancetype)init NS_UNAVAILABLE;

/** Create an error response with the given error object from a request. */
+ (EDOServiceResponse *)errorResponse:(NSError *_Nullable)error
                           forRequest:(EDOServiceRequest *)request;
@end

NS_ASSUME_NONNULL_END
