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

#import <XCTest/XCTest.h>

#import "Channel/Sources/EDOChannelPool.h"
#import "Channel/Sources/EDOHostPort.h"
#import "Service/Sources/EDOClientService+Private.h"
#import "Service/Sources/EDOHostNamingService+Private.h"
#import "Service/Sources/EDOHostService.h"

static NSString *const kDummyServiceName = @"com.google.testService";
static const UInt16 kDummyServicePort = 1234;

@interface EDOHostNamingServiceTest : XCTestCase
@end

@implementation EDOHostNamingServiceTest

- (void)setUp {
  [super setUp];
  EDOHostNamingService *serviceObject = EDOHostNamingService.sharedObject;
  EDOServicePort *dummyServicePort = [EDOServicePort servicePortWithPort:kDummyServicePort
                                                             serviceName:kDummyServiceName];
  [serviceObject addServicePort:dummyServicePort];
}

- (void)tearDown {
  EDOHostNamingService *serviceObject = EDOHostNamingService.sharedObject;
  [serviceObject removeServicePortWithName:kDummyServiceName];
  [super tearDown];
}

/** Tests getting correct service name by sending ports message to @c EDOHostNamingService. */
- (void)testStartEDONamingServiceObject {
  [EDOHostNamingService.sharedObject start];
  EDOHostNamingService *serviceObject =
      [EDOClientService rootObjectWithPort:EDOHostNamingService.namingServerPort];
  XCTAssertEqual([serviceObject portForServiceWithName:kDummyServiceName].port, kDummyServicePort);
}

/**
 *  Tests sending object request to the naming service after stopping it, and verifies that
 *  exception happens.
 */
- (void)testStopEDONamingServiceObject {
  EDOHostNamingService *namingServiceObject = EDOHostNamingService.sharedObject;
  [namingServiceObject start];
  [namingServiceObject stop];
  // Clean up connected channels.
  [EDOChannelPool.sharedChannelPool
      removeChannelsWithPort:[EDOHostPort
                                 hostPortWithLocalPort:EDOHostNamingService.namingServerPort]];
  XCTAssertThrows([EDOClientService rootObjectWithPort:EDOHostNamingService.namingServerPort]);
}

/** Tests starting/stoping the naming service multiple times to verify idempotency. */
- (void)testStartAndStopMultipleTimes {
  EDOHostNamingService *namingServiceObject = EDOHostNamingService.sharedObject;
  [namingServiceObject start];
  [namingServiceObject start];
  XCTAssertNoThrow([EDOClientService rootObjectWithPort:EDOHostNamingService.namingServerPort]);
  [namingServiceObject stop];
  [namingServiceObject stop];
  // Clean up connected channels.
  [EDOChannelPool.sharedChannelPool
      removeChannelsWithPort:[EDOHostPort
                                 hostPortWithLocalPort:EDOHostNamingService.namingServerPort]];
  XCTAssertThrows([EDOClientService rootObjectWithPort:EDOHostNamingService.namingServerPort]);
}

/** Verifies no side effect when adding the same service multiple times. */
- (void)testAddingServiceMultipleTimes {
  EDOHostNamingService *namingServiceObject = EDOHostNamingService.sharedObject;
  NSString *serviceName = @"com.google.testService.adding";
  EDOServicePort *dummyPort = [EDOServicePort servicePortWithPort:12345 serviceName:serviceName];
  [namingServiceObject addServicePort:dummyPort];
  XCTAssertFalse([namingServiceObject addServicePort:dummyPort]);
  // Clean up.
  [namingServiceObject removeServicePortWithName:serviceName];
}

/** Verifies no side effect when removing the same service multiple times. */
- (void)testRemoveServiceMultipleTimes {
  EDOHostNamingService *namingServiceObject = EDOHostNamingService.sharedObject;
  NSString *serviceName = @"com.google.testService.removing";
  EDOServicePort *dummyPort = [EDOServicePort servicePortWithPort:12346 serviceName:serviceName];
  [namingServiceObject addServicePort:dummyPort];

  [namingServiceObject removeServicePortWithName:serviceName];
  [namingServiceObject removeServicePortWithName:serviceName];

  XCTAssertNil([namingServiceObject portForServiceWithName:serviceName]);
}

/** Verifies service are added even when naming service has stopped serving. */
- (void)testAddingServiceAfterStop {
  EDOHostNamingService *namingServiceObject = EDOHostNamingService.sharedObject;
  [namingServiceObject stop];
  NSString *serviceName = @"com.google.testService.stop";
  UInt16 port = 12347;
  EDOServicePort *dummyPort = [EDOServicePort servicePortWithPort:port serviceName:serviceName];
  [namingServiceObject addServicePort:dummyPort];
  XCTAssertEqual([namingServiceObject portForServiceWithName:serviceName].port, port);
  // Clean up.
  [namingServiceObject removeServicePortWithName:serviceName];
}

/**
 *  Tests thread safety of adding/removing services.
 *  This test adds two service ports concurrently to the naming service, and then removes them
 *  concurrently. And it verifies the state of the naming service after each step.
 */
- (void)testUpdateServicesConcurrently {
  EDOHostNamingService *namingServiceObject = EDOHostNamingService.sharedObject;
  NSString *serviceName1 = @"com.google.testService.concurrent1";
  UInt16 port1 = 12348;
  NSString *serviceName2 = @"com.google.testService.concurrent2";
  UInt16 port2 = 12349;
  EDOServicePort *dummyPort1 = [EDOServicePort servicePortWithPort:port1 serviceName:serviceName1];
  EDOServicePort *dummyPort2 = [EDOServicePort servicePortWithPort:port2 serviceName:serviceName2];
  dispatch_queue_t concurrentQueue = dispatch_queue_create(NULL, DISPATCH_QUEUE_CONCURRENT);
  dispatch_async(concurrentQueue, ^{
    [namingServiceObject addServicePort:dummyPort1];
  });
  dispatch_async(concurrentQueue, ^{
    [namingServiceObject addServicePort:dummyPort2];
  });
  dispatch_barrier_sync(concurrentQueue, ^{
    XCTAssertEqual([namingServiceObject portForServiceWithName:serviceName1].port, port1);
    XCTAssertEqual([namingServiceObject portForServiceWithName:serviceName2].port, port2);
  });
  dispatch_async(concurrentQueue, ^{
    [namingServiceObject removeServicePortWithName:serviceName1];
  });
  dispatch_async(concurrentQueue, ^{
    [namingServiceObject removeServicePortWithName:serviceName2];
  });
  dispatch_barrier_sync(concurrentQueue, ^{
    XCTAssertNil([namingServiceObject portForServiceWithName:serviceName1]);
    XCTAssertNil([namingServiceObject portForServiceWithName:serviceName2]);
  });
}

@end
