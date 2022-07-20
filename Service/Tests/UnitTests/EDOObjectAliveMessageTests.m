//
// Copyright 2022 Google Inc.
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

#import <XCTest/XCTest.h>

#import "Service/Sources/EDOHostService+Private.h"
#import "Service/Sources/EDOHostService.h"
#import "Service/Sources/EDOObject+Private.h"
#import "Service/Sources/EDOObject.h"
#import "Service/Sources/EDOObjectAliveMessage.h"
#import "Service/Sources/EDOServicePort.h"

@interface EDOObjectAliveMessageTests : XCTestCase
@end

@implementation EDOObjectAliveMessageTests {
  EDOHostService *_service;
}

- (void)setUp {
  [super setUp];
  NSObject *rootObject = [[NSObject alloc] init];
  _service = [EDOHostService serviceWithPort:0
                                  rootObject:rootObject
                                       queue:dispatch_get_main_queue()];
}

- (void)tearDown {
  [_service invalidate];
  [super tearDown];
}

/** Verifies EDOObjectAliveRequest results are @c YES when object is stored in the service. */
- (void)testPassObjectAliveQueryForCachedObject {
  EDOObject *proxy = [_service distantObjectForLocalObject:[[NSObject alloc] init] hostPort:nil];
  EDOObjectAliveRequest *request = [EDOObjectAliveRequest requestWithObject:proxy];
  EDOObjectAliveResponse *response =
      (EDOObjectAliveResponse *)EDOObjectAliveRequest.requestHandler(request, _service);
  XCTAssertTrue(response.alive);
}

/** Verifies EDOObjectAliveRequest results are @c YES when object is root object. */
- (void)testPassObjectAliveQueryForRootObject {
  EDOServicePort *port = [EDOServicePort servicePortWithPort:_service.port
                                                    hostPort:_service.port.hostPort];
  EDOObject *proxy = [EDOObject edo_remoteProxyFromUnderlyingObject:_service.rootLocalObject
                                                           withPort:port];
  EDOObjectAliveRequest *request = [EDOObjectAliveRequest requestWithObject:proxy];
  EDOObjectAliveResponse *response =
      (EDOObjectAliveResponse *)EDOObjectAliveRequest.requestHandler(request, _service);
  XCTAssertTrue(response.alive);
}

/** Verifies EDOObjectAliveRequest results are @c NO when object is not stored in the service. */
- (void)testFailObjectAliveQueryForUncachedObject {
  EDOServicePort *port = [EDOServicePort servicePortWithPort:_service.port
                                                    hostPort:_service.port.hostPort];
  EDOObject *proxy = [EDOObject edo_remoteProxyFromUnderlyingObject:[[NSObject alloc] init]
                                                           withPort:port];
  EDOObjectAliveRequest *request = [EDOObjectAliveRequest requestWithObject:proxy];
  EDOObjectAliveResponse *response =
      (EDOObjectAliveResponse *)EDOObjectAliveRequest.requestHandler(request, _service);
  XCTAssertFalse(response.alive);
}

/** Verifies EDOObjectAliveRequest results are @c NO when port is not match. */
- (void)testFailObjectAliveQueryForMismatchedPort {
  EDOServicePort *port = [EDOServicePort servicePortWithPort:0 serviceName:@"not exist"];
  EDOObject *proxy = [EDOObject edo_remoteProxyFromUnderlyingObject:_service.rootLocalObject
                                                           withPort:port];
  EDOObjectAliveRequest *request = [EDOObjectAliveRequest requestWithObject:proxy];
  EDOObjectAliveResponse *response =
      (EDOObjectAliveResponse *)EDOObjectAliveRequest.requestHandler(request, _service);
  XCTAssertFalse(response.alive);
}

/** Verifies EDOObjectAliveRequest results are @c NO when object is removed from the service. */
- (void)testFailObjectAliveQueryForRemovedObject {
  EDOObject *proxy = [_service distantObjectForLocalObject:[[NSObject alloc] init] hostPort:nil];
  [_service removeObjectWithAddress:proxy.remoteAddress];
  EDOObjectAliveRequest *request = [EDOObjectAliveRequest requestWithObject:proxy];
  EDOObjectAliveResponse *response =
      (EDOObjectAliveResponse *)EDOObjectAliveRequest.requestHandler(request, _service);
  XCTAssertFalse(response.alive);
}

@end
