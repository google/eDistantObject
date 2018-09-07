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

#import "Channel/Sources/EDOSocketChannelPool.h"
#import "Service/Sources/EDOClientService.h"
#import "Service/Sources/EDOHostService.h"
#import "Service/Sources/NSObject+EDOValueObject.h"
#import "Service/Tests/FunctionalTests/EDOTestDummyInTest.h"
#import "Service/Tests/TestsBundle/EDOTestClassDummy.h"
#import "Service/Tests/TestsBundle/EDOTestDummy.h"
#import "Service/Tests/TestsBundle/EDOTestProtocol.h"
#import "Service/Tests/TestsBundle/EDOTestProtocolInApp.h"
#import "Service/Tests/TestsBundle/EDOTestProtocolInTest.h"

#import <objc/runtime.h>

@interface EDOUITestAppUITests : XCTestCase
@property(nonatomic) int numRemoteInvokes;
@end

@implementation EDOUITestAppUITests

- (void)setUp {
  [super setUp];

  self.continueAfterFailure = YES;
}

- (void)tearDown {
  [EDOSocketChannelPool.sharedChannelPool removeChannelsWithPort:EDOTEST_APP_SERVICE_PORT];

  [super tearDown];
}

- (XCUIApplication *)launchAppWithPort:(int)port initValue:(int)value {
  XCUIApplication *app = [[XCUIApplication alloc] init];
  app.launchArguments = @[
    @"-servicePort", [NSString stringWithFormat:@"%d", port], @"-dummyInitValue",
    [NSString stringWithFormat:@"%d", value]
  ];
  [app launch];
  return app;
}

- (void)testSimpleBlock {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:10];
  EDOHostService *service = [EDOHostService serviceWithPort:2234
                                                 rootObject:self
                                                      queue:dispatch_get_main_queue()];

  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  __block BOOL blockAssignment = NO;
  [remoteDummy voidWithBlock:^{
    blockAssignment = YES;
  }];
  XCTAssertTrue(blockAssignment);
  XCTAssertEqual([remoteDummy returnWithBlockDouble:^double {
                   return 100.0;
                 }],
                 100.0);

  self.numRemoteInvokes = 0;
  [self assignStackBlock:remoteDummy];
  XCTAssertNoThrow([remoteDummy invokeBlock]);
  XCTAssertNoThrow(remoteDummy.block());
  XCTAssertNoThrow([remoteDummy returnBlock]());
  XCTAssertNoThrow([remoteDummy voidWithBlockAssigned:^{
    ++self.numRemoteInvokes;
  }]);
  XCTAssertNoThrow([remoteDummy invokeBlock]);
  XCTAssertEqual(self.numRemoteInvokes, 3);

  [service invalidate];
}

- (void)testBlockWithStruct {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:10];
  EDOHostService *service = [EDOHostService serviceWithPort:2234
                                                 rootObject:self
                                                      queue:dispatch_get_main_queue()];

  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  EDOTestDummyStruct dummyStruct = [remoteDummy returnStructWithBlockStret:^EDOTestDummyStruct {
    return (EDOTestDummyStruct){.value = 100, .a = 30.0, .x = 50, .z = 200};
  }];
  XCTAssertEqual(dummyStruct.value, 100);
  XCTAssertEqual(dummyStruct.a, 30);
  XCTAssertEqual(dummyStruct.x, 50);
  XCTAssertEqual(dummyStruct.z, 200);

  EDOTestDummy *dummyReturn = [remoteDummy
      returnWithInt:5
        dummyStruct:(EDOTestDummyStruct){.value = 150, .a = 30.0, .x = 50, .z = 200}
       blockComplex:^EDOTestDummy *(EDOTestDummyStruct dummy, int i, EDOTestDummy *test) {
         XCTAssertEqual(dummyStruct.a, 30);
         XCTAssertEqual(dummyStruct.x, 50);
         XCTAssertEqual(dummyStruct.z, 200);
         XCTAssertEqual(i, 5);
         XCTAssertEqual(dummy.value, 150);
         test.value = i + dummy.value + 4;
         return test;
       }];
  XCTAssertEqual(dummyReturn.value, 159);
  [service invalidate];
}

- (void)testBlockIsEqual {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:10];
  EDOHostService *service = [EDOHostService serviceWithPort:2234
                                                 rootObject:self
                                                      queue:dispatch_get_main_queue()];

  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];

  void (^localBlock)(void) = ^{
    [self class];  // To make this a non global block.
  };
  id returnedBlock = [remoteDummy returnWithBlockObject:^id(EDOTestDummy *_) {
    return localBlock;
  }];
  XCTAssertEqual((id)localBlock, returnedBlock);

  XCTAssertEqual([remoteDummy returnBlock], [remoteDummy returnBlock]);
  [service invalidate];
}

/*
 Test that makes sure local block is resolved to its address, when it is decoded from the service
 which is different from the service it is encoded.
 */
- (void)testBlockResolveToLocalAddress {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:10];
  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  EDOHostService *service = [EDOHostService serviceWithPort:2234
                                                 rootObject:self
                                                      queue:dispatch_get_main_queue()];
  dispatch_queue_t backgroundQueue =
      dispatch_queue_create("com.google.edo.testbackground", DISPATCH_QUEUE_SERIAL);
  EDOHostService *backgroundService = [EDOHostService serviceWithPort:2235
                                                           rootObject:self
                                                                queue:backgroundQueue];

  void (^localBlock)(void) = ^{
    [self class];  // To make this a non global block.
  };

  // Sending block to remote process through background eDO host.
  dispatch_sync(backgroundQueue, ^{
    remoteDummy.block = localBlock;
  });

  // Resolve the block from main thread eDO host.
  id returnedBlock = remoteDummy.block;
  XCTAssertEqual((id)localBlock, returnedBlock);

  [service invalidate];
  [backgroundService invalidate];
}

- (void)testBlockByValueAndOutArgument {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:10];
  EDOHostService *service = [EDOHostService serviceWithPort:2234
                                                 rootObject:self
                                                      queue:dispatch_get_main_queue()];

  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];

  NSArray *arrayReturn = [remoteDummy returnWithBlockObject:^id(EDOTestDummy *dummy) {
    XCTAssertEqual([dummy class], NSClassFromString(@"EDOObject"));
    XCTAssertEqual(dummy.value, 10);
    dummy.value += 10;
    return [@[ @(dummy.value), @20 ] passByValue];
  }];
  // The returned array from the block, if not passByValue, should be resolved to the local array
  // here.
  XCTAssertEqual([arrayReturn class], NSClassFromString(@"EDOObject"));
  XCTAssertEqualObjects(arrayReturn[0], @20);
  XCTAssertEqualObjects(arrayReturn[1], @20);

  EDOTestDummy *outDummy;
  XCTAssertNoThrow(outDummy = [remoteDummy returnWithBlockOutObject:^(EDOTestDummy **dummy) {
                     *dummy = [EDO_REMOTE_CLASS(EDOTestDummy, EDOTEST_APP_SERVICE_PORT)
                         classMethodWithNumber:@10];
                   }]);
  XCTAssertEqual(outDummy.value, 10);

  [service invalidate];
}

- (void)assignStackBlock:(EDOTestDummy *)dummy {
  void (^block)(void) = ^{
    ++self.numRemoteInvokes;
  };
  dummy.block = block;
}

- (void)testEDOResolveToLocalAddress {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:10];

  XCTAssertNil(NSClassFromString(@"EDOTestDummy"));
  EDOTestDummyInTest *rootObject = [[EDOTestDummyInTest alloc] initWithValue:5];
  EDOHostService *service = [EDOHostService serviceWithPort:2234
                                                 rootObject:rootObject
                                                      queue:dispatch_get_main_queue()];

  EDOTestDummyInTest *dummyInTest = [[EDOTestDummyInTest alloc] initWithValue:5];
  EDOTestDummyInTest *dummyAssigned = [[EDOTestDummyInTest alloc] initWithValue:6];

  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  XCTAssertEqualObjects([remoteDummy class], NSClassFromString(@"EDOObject"));

  EDOTestDummy *returnDummy = [remoteDummy returnIdWithInt:5];
  XCTAssertEqualObjects([returnDummy class], NSClassFromString(@"EDOObject"));
  XCTAssertEqual(returnDummy.value, 15);

  Class testDummyClass = EDO_REMOTE_CLASS(EDOTestDummy, EDOTEST_APP_SERVICE_PORT);
  XCTAssertEqualObjects([testDummyClass class], NSClassFromString(@"EDOObject"));
  XCTAssertEqualObjects([remoteDummy class], NSClassFromString(@"EDOObject"));

  [remoteDummy setDummInTest:dummyInTest withDummy:dummyAssigned];

  XCTAssertEqual(dummyInTest.dummyInTest, dummyAssigned);
  XCTAssertEqual([remoteDummy getRootObject:2234], rootObject);

  EDOTestDummyInTest *returnedDummy = [remoteDummy createEDOWithPort:2234];
  XCTAssertEqualObjects([returnedDummy class], [EDOTestDummyInTest class]);
  XCTAssertEqual(returnedDummy.value.intValue, 17);

  [service invalidate];
}

- (void)testValueAndIdOutParameter {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:7];
  EDOHostService *service =
      [EDOHostService serviceWithPort:2234
                           rootObject:[[EDOTestDummyInTest alloc] initWithValue:9]
                                queue:dispatch_get_main_queue()];

  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  XCTAssertEqualObjects([remoteDummy class], NSClassFromString(@"EDOObject"));

  NSError *errorOut;
  XCTAssertFalse([remoteDummy returnBoolWithError:nil]);
  XCTAssertTrue([remoteDummy returnBoolWithError:&errorOut]);
  XCTAssertEqual(errorOut.code, 7);

  EDOTestDummy *dummyOut;
  XCTAssertThrows([remoteDummy voidWithOutObject:nil]);

  [remoteDummy voidWithOutObject:&dummyOut];
  XCTAssertEqualObjects([dummyOut class], NSClassFromString(@"EDOObject"));
  XCTAssertEqual(dummyOut.value, 12);

  EDOTestDummyInTest *dummyInTestOut;
  // 11 + 7 + 12
  XCTAssertEqual(
      [dummyOut selWithOutEDO:&dummyInTestOut dummy:[[EDOTestDummyInTest alloc] initWithValue:11]],
      30);
  // dummyInTestOut is created in this process and need to be unwrapped to the local address
  // as an out parameter.
  XCTAssertEqualObjects([dummyInTestOut class], [EDOTestDummyInTest class]);
  XCTAssertEqual(dummyInTestOut.value.intValue, 30);

  EDOTestDummyInTest *dummyInTestOutRet = [dummyOut selWithInOutEDO:&dummyInTestOut];
  XCTAssertEqual(dummyInTestOut.value.intValue, 30);
  XCTAssertEqual(dummyInTestOutRet.value.intValue, 49);  // 12 + 7 + 30

  EDOTestDummyInTest *dummyInNil;
  XCTAssertNil([dummyOut selWithInOutEDO:&dummyInNil]);
  XCTAssertThrows([dummyOut selWithInOutEDO:nil]);

  [service invalidate];
}

- (void)testProtocolParameter {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:10];

  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];

  // The protocol is loaded in the both sides so it shouldn't throw an exception.
  XCTAssertNoThrow([remoteDummy voidWithProtocol:@protocol(EDOTestProtocol)]);
  // This protocol isn't loaded on the app-side.
  XCTAssertThrowsSpecificNamed([remoteDummy voidWithProtocol:@protocol(EDOTestProtocolInTest)],
                               NSException, NSInternalInconsistencyException);
  // Calling a method from the protocol
  XCTAssertTrue([[remoteDummy protocolName] isEqualToString:@"EDOTestProtocolInApp"]);
  // Getting a protocol that wasn't loaded on the test side
  XCTAssertThrowsSpecificNamed([remoteDummy returnWithProtocolInApp], NSException,
                               NSInternalInconsistencyException);
}

- (void)testTwoWayAndMultiplexInvocation {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:5];
  EDOHostService *service =
      [EDOHostService serviceWithPort:2234
                           rootObject:[[EDOTestDummyInTest alloc] initWithValue:9]
                                queue:dispatch_get_main_queue()];

  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  XCTAssertEqualObjects([remoteDummy class], NSClassFromString(@"EDOObject"));

  EDOTestDummyInTest *dummy = [[EDOTestDummyInTest alloc] initWithValue:8];

  // Test: [A callBackToTest:B withValue:7]
  //   App:    A-> [B callTestDummy:A]
  //     Test:      B-> [A selWithIdReturn:10]
  //        App:         -> A.value = A.value(5) + value(10) * 2 = 25
  //        App:         -> new A(A.value(5) + 10).value
  //        App:         = 15
  //     Test:      B-> (15) + B.value(8) + 3
  //     Test:           = 26
  //   App:    (26) + value(7) + A.value(25)
  // Test:  = 58
  XCTAssertEqual([remoteDummy callBackToTest:dummy withValue:7], 58);

  [service invalidate];
}

- (void)testDispatchAsyncEarlyReturn {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:5];
  EDOHostService *service =
      [EDOHostService serviceWithPort:2234
                           rootObject:[[EDOTestDummyInTest alloc] initWithValue:9]
                                queue:dispatch_get_main_queue()];

  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  EDOTestDummyInTest *dummy = [[EDOTestDummyInTest alloc] initWithValue:7];

  dispatch_semaphore_t waitLock = dispatch_semaphore_create(0L);
  XCTestExpectation *expectsInvoke = [self expectationWithDescription:@"Invoked the block."];
  dummy.block = ^{
    dispatch_semaphore_wait(waitLock, DISPATCH_TIME_FOREVER);
    [expectsInvoke fulfill];
  };

  // Test: [A returnPlus10AndAsyncExecuteBlock:B]
  //   App:   dispatch_async: [B invokeBlock]
  //                   Test:     acquire waitLock
  //          -> 5 + 10
  // Test: = 15
  //       release waitLock
  //   App:   dispatch_async: finish
  XCTAssertEqual([remoteDummy returnPlus10AndAsyncExecuteBlock:dummy], 5 + 10);

  dispatch_semaphore_signal(waitLock);
  [self waitForExpectationsWithTimeout:1 handler:nil];

  [service invalidate];
}

- (void)testDispatchAsyncManyTimes {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:8];
  NS_VALID_UNTIL_END_OF_SCOPE dispatch_queue_t backgroundQueue =
      dispatch_queue_create("com.google.edo.uitest", DISPATCH_QUEUE_SERIAL);
  EDOTestDummyInTest *rootDummy = [[EDOTestDummyInTest alloc] initWithValue:9];
  EDOHostService *service = [EDOHostService serviceWithPort:2234
                                                 rootObject:rootDummy
                                                      queue:backgroundQueue];

  __block int numOfInvokes = 0;
  const int totalOfInvokes = 10;
  XCTestExpectation *expectsTen = [self expectationWithDescription:@"Invoked many times."];
  rootDummy.block = ^{
    // This block is dispatched to a background queue.
    XCTAssertFalse([NSThread isMainThread]);
    if (++numOfInvokes == totalOfInvokes) {
      [expectsTen fulfill];
    }
  };

  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  EDOTestDummyInTest *dummy = [EDOClientService rootObjectWithPort:2234];
  // Dispatch to execute the block @c totalOfInvokes of times asynchronously in the background
  // queue.
  for (int i = 0; i < totalOfInvokes; ++i) {
    XCTAssertEqual([remoteDummy returnPlus10AndAsyncExecuteBlock:dummy], 8 + 10);
  }

  [self waitForExpectationsWithTimeout:5 handler:nil];

  XCTAssertEqual(numOfInvokes, totalOfInvokes);
  [service invalidate];
}

- (void)testServiceInvalidOrTerminatedInMiddle {
  // Terminate the app if other tests launched it.
  [[[XCUIApplication alloc] init] terminate];

  XCTAssertThrowsSpecificNamed([EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT],
                               NSException, NSDestinationInvalidException);

  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:8];

  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  [remoteDummy invalidateService];
  XCTAssertThrowsSpecificNamed([remoteDummy voidWithValuePlusOne], NSException,
                               NSDestinationInvalidException);

  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:8];

  XCTAssertThrowsSpecificNamed([remoteDummy voidWithValuePlusOne], NSException,
                               NSInternalInconsistencyException);
}

- (void)testAllocAndClassMethod {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:5];

  // Create a local service so it can wrap and deref the any returned EDOObjects.
  EDOHostService *service = [EDOHostService serviceWithPort:2234
                                                 rootObject:[[EDOTestDummyInTest alloc] init]
                                                      queue:dispatch_get_main_queue()];

  EDOTestClassDummy *testDummyEqual = [EDOTestClassDummy alloc];
  XCTAssertEqual(testDummyEqual, [testDummyEqual initWithValue:10]);

  // @see EDOTestClassDummyStub.m
  XCTAssertEqual([EDOTestClassDummy classMethodWithInt:7], 16);
  XCTAssertEqual([EDOTestClassDummy classMethodWithIdReturn:8].value, 8);

  // Stub class forwarding alloc will alloc an instance of EDOObject.
  XCTAssertEqualObjects([[EDOTestClassDummy alloc] class], NSClassFromString(@"EDOObject"));
  XCTAssertEqualObjects([[EDOTestClassDummy allocWithZone:nil] class],
                        NSClassFromString(@"EDOObject"));

  // XCTAssertTrue(testDummyEqual == [testDummyEqual initWithValue:10]);

  EDOTestClassDummy *dummy = [EDOTestClassDummy classMethodWithIdReturn:8];
  XCTAssertEqualObjects([dummy class], NSClassFromString(@"EDOObject"));
  [service invalidate];

  // Validate the class methods don't exist locally.
  unsigned int methodCount = 0;
  Class dummyMeta = object_getClass([EDOTestClassDummy class]);
  Method *methods = class_copyMethodList(dummyMeta, &methodCount);
  for (unsigned int i = 0; i < methodCount; i++) {
    Method method = methods[i];
    char const *selectorName = sel_getName(method_getName(method));

    // Make sure those class methods are not defined locally.
    XCTAssertTrue(strcmp(selectorName, sel_getName(@selector(classMethodWithInt:))) != 0);
    XCTAssertTrue(strcmp(selectorName, sel_getName(@selector(classMethodWithIdReturn:))) != 0);
  }

  free(methods);
}

- (void)testRemoteObjectCopy {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:5];
  EDOTestDummy *dummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  NSArray *remoteArray = [dummy returnArray];
  NSArray *remoteArrayCopy;
  XCTAssertNoThrow(remoteArrayCopy = [remoteArray copy]);
  XCTAssertEqual(remoteArray, remoteArrayCopy);
}

- (void)testRemoteObjectMutableCopy {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:5];
  EDOTestDummy *dummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  NSArray *remoteArray = [dummy returnArray];
  NSMutableArray *remoteArrayCopy = [remoteArray mutableCopy];
  XCTAssertNotEqual(remoteArray, remoteArrayCopy);
  XCTAssertEqualObjects(remoteArray, remoteArrayCopy);
  [remoteArrayCopy addObject:@"test"];
  XCTAssertEqualObjects([remoteArrayCopy lastObject], @"test");
}

- (void)testInsertRemoteObjectToDictionary {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:5];
  EDOTestDummy *dummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
  XCTAssertNoThrow([dict setObject:dummy forKey:@"key"]);
}

- (void)testBrokenChannelAfterServiceClosed {
  XCUIApplication *app = [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:5];
  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  XCTAssertEqualObjects([remoteDummy class], NSClassFromString(@"EDOObject"));
  [app terminate];
  app = [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:5];

  EDOTestDummy *newRemoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  XCTAssertNotEqualObjects(remoteDummy, newRemoteDummy);
  __block Class clazz;
  XCTestExpectation *expectsReturn = [self expectationWithDescription:@"Returned in time."];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    clazz = [newRemoteDummy class];
    [expectsReturn fulfill];
  });
  [self waitForExpectationsWithTimeout:15 handler:nil];
  XCTAssertEqualObjects(clazz, NSClassFromString(@"EDOObject"));
  XCTAssertThrowsSpecificNamed([remoteDummy returnInt], NSException,
                               NSInternalInconsistencyException);
}

- (void)testEDOObjectReleaseInHost {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:6];
  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  @autoreleasepool {
    // Allocate a weak variable inside the autoreleasepool.
    NS_VALID_UNTIL_END_OF_SCOPE EDOTestDummy *dummyInTest =
        [remoteDummy weaklyHeldDummyForMemoryTest];
    // Assert that the remoteDummy holds a reference to the weak variable.
    XCTAssertNotNil(dummyInTest);
    XCTAssertNotNil(remoteDummy.weakDummyInTest);
  }
  // The strong variable that held a strong reference is gone. Since the remoteDummy holds a weak
  // reference to itself, then it should be nil.
  XCTAssertNil(remoteDummy.weakDummyInTest);
}

- (void)testEDOObjectReleasedMultipleReferences {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:6];
  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  EDOTestDummy *strongReference;
  __weak EDOTestDummy *weakReference;
  @autoreleasepool {
    // Get a weak variable.
    NS_VALID_UNTIL_END_OF_SCOPE EDOTestDummy *dummy = [remoteDummy weaklyHeldDummyForMemoryTest];
    // Assign it to a weak and a strong variable.
    weakReference = dummy;
    strongReference = dummy;
    XCTAssertNotNil(weakReference);
    XCTAssertNotNil(strongReference);
  }
  // Since there is still a strong reference to the weak variable then references are not nil.
  XCTAssertNotNil(weakReference);
  XCTAssertNotNil(strongReference);
  XCTAssertNotNil(remoteDummy.weakDummyInTest);
}

- (void)testEDOObjectNotReleasedMultipleReferences {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:6];
  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  __weak EDOTestDummy *weakReference;
  __weak EDOTestDummy *weakReferenceTwo;
  @autoreleasepool {
    // Get a weak variable.
    NS_VALID_UNTIL_END_OF_SCOPE EDOTestDummy *dummy = [remoteDummy weaklyHeldDummyForMemoryTest];
    weakReference = dummy;
    weakReferenceTwo = dummy;
    XCTAssertNotNil(weakReference);
    XCTAssertNotNil(weakReferenceTwo);
  }
  // Both variables are weak. When one of them is released both of them get released.
  XCTAssertNil(weakReference);
  XCTAssertNil(weakReferenceTwo);
  XCTAssertNil(remoteDummy.weakDummyInTest);
}

- (void)testEDOObjectNotReleasedStronglyHeldAppSide {
  [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:6];
  __weak EDOTestDummy *remoteWeakDummy;
  @autoreleasepool {
    // Initialize a weak reference to the rootObject.
    NS_VALID_UNTIL_END_OF_SCOPE EDOTestDummy *dummy =
        [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
    remoteWeakDummy = dummy;
    XCTAssertNotNil(remoteWeakDummy);
  }
  // The weak reference to the root object is gone on the test side. But since the app side
  // holds a strong reference to root object it is not deallocated.
  XCTAssertNil(remoteWeakDummy);
  XCTAssertNotNil([EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT]);
}

- (void)testEDOObjectReleasedAfterAppKiled {
  XCUIApplication *app = [self launchAppWithPort:EDOTEST_APP_SERVICE_PORT initValue:6];
  EDOTestDummy *remoteDummy = [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
  __weak EDOTestDummy *weakReference;
  @autoreleasepool {
    NS_VALID_UNTIL_END_OF_SCOPE EDOTestDummy *dummy = [remoteDummy weaklyHeldDummyForMemoryTest];
    weakReference = dummy;
    [app terminate];
  }
  // The test shouldn't crash if the app is gone.
  XCTAssertNil(weakReference);
}

@end
