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

#import <objc/runtime.h>

#import "Service/Sources/EDOClassMessage.h"
#import "Service/Sources/EDOClientService+Private.h"
#import "Service/Sources/EDOHostService+Private.h"
#import "Service/Sources/EDOInvocationMessage.h"
#import "Service/Sources/EDOMethodSignatureMessage.h"
#import "Service/Sources/EDOObject+Private.h"
#import "Service/Sources/EDOObjectMessage.h"
#import "Service/Sources/EDOParameter.h"

#import "Service/Tests/TestsBundle/EDOTestDummy.h"

@interface EDOMessageTest : XCTestCase

@end

@implementation EDOMessageTest

// To make the compiler be aware of this selector's exsitence.
- (void)nonExistMethod {
}

- (void)testObjectRequestHandler {
  XCTestExpectation *blockExecuted = [self expectationWithDescription:@"Executed the test block."];
  id dummyLocal = [[EDOTestDummy alloc] init];
  [self
      edo_createQueueAndServiceWithRootObject:dummyLocal
                                        block:^(EDOHostService *service) {
                                          EDOObjectResponse *response =
                                              (EDOObjectResponse *)EDOObjectRequest.requestHandler(
                                                  [EDOObjectRequest request], service);
                                          XCTAssertEqualObjects([response class],
                                                                [EDOObjectResponse class]);
                                          EDOObject *object = response.object;
                                          XCTAssertEqual(object.remoteAddress,
                                                         (EDOPointerType)dummyLocal);
                                          XCTAssertEqual(object.remoteClass,
                                                         (EDOPointerType)[dummyLocal class]);
                                          [blockExecuted fulfill];
                                        }];
  [self waitForExpectationsWithTimeout:1 handler:nil];
}

- (void)testClassRequestHandler {
  XCTestExpectation *blockExecuted = [self expectationWithDescription:@"Executed the test block."];
  id dummyLocal = [[EDOTestDummy alloc] init];
  Class dummyMeta = object_getClass([dummyLocal class]);
  [self
      edo_createQueueAndServiceWithRootObject:dummyLocal
                                        block:^(EDOHostService *service) {
                                          {
                                            EDOServiceRequest *request = [EDOClassRequest
                                                requestWithClassName:@"EDOTestDummy"];
                                            EDOClassResponse *response =
                                                (EDOClassResponse *)EDOClassRequest.requestHandler(
                                                    request, service);
                                            XCTAssertEqualObjects([response class],
                                                                  [EDOClassResponse class]);
                                            EDOObject *object = response.object;
                                            XCTAssertTrue(object.remoteAddress ==
                                                          (EDOPointerType)[dummyLocal class]);
                                            XCTAssertTrue(object.remoteClass ==
                                                          (EDOPointerType)dummyMeta);
                                          }

                                          {
                                            EDOServiceRequest *request = [EDOClassRequest
                                                requestWithClassName:@"NonExistTestClass"];
                                            EDOClassResponse *response =
                                                (EDOClassResponse *)EDOClassRequest.requestHandler(
                                                    request, service);
                                            XCTAssertNotNil(response);
                                            XCTAssertNil(response.object);
                                          }

                                          [blockExecuted fulfill];
                                        }];
  [self waitForExpectationsWithTimeout:1 handler:nil];
}

- (void)testNoArgsInvocationHandler {
  XCTestExpectation *blockExecuted = [self expectationWithDescription:@"Executed the test block."];
  EDOTestDummy *dummyLocal = [[EDOTestDummy alloc] init];
  [self edo_createQueueAndServiceWithRootObject:dummyLocal
                                          block:^(EDOHostService *service) {
                                            EDOInvocationResponse *response =
                                                [self edo_runInvocationWithService:service
                                                                            target:dummyLocal
                                                                          selector:@selector
                                                                          (voidWithValuePlusOne)
                                                                         arguments:@[]];
                                            XCTAssertNil(response.exception);
                                            XCTAssertNil(response.returnValue);
                                            XCTAssertNil(response.outValues);

                                            [blockExecuted fulfill];
                                          }];
  [self waitForExpectationsWithTimeout:1 handler:nil];
}

- (void)testInvocationWithArgsHandler {
  XCTestExpectation *blockExecuted = [self expectationWithDescription:@"Executed the test block."];
  EDOTestDummy *dummyLocal = [[EDOTestDummy alloc] initWithValue:5];

  [self
      edo_createQueueAndServiceWithRootObject:dummyLocal
                                        block:^(EDOHostService *service) {
                                          {
                                            EDOInvocationResponse *response = [self
                                                edo_runInvocationWithService:service
                                                                      target:dummyLocal
                                                                    selector:@selector(voidWithInt:)
                                                                   arguments:@[ [self
                                                                                 edo_intValue:8] ]];
                                            XCTAssertNil(response.exception);
                                            XCTAssertNil(response.returnValue);
                                            XCTAssertNil(response.outValues);
                                          }

                                          {
                                            EDOInvocationResponse *response =
                                                [self edo_runInvocationWithService:service
                                                                            target:dummyLocal
                                                                          selector:@selector
                                                                          (voidWithNumber:)
                                                                         arguments:@[
                                                                           [self edo_numberValue:@9]
                                                                         ]];
                                            XCTAssertNil(response.exception);
                                            XCTAssertNil(response.returnValue);
                                            XCTAssertNil(response.outValues);
                                          }

                                          [blockExecuted fulfill];
                                        }];
  [self waitForExpectationsWithTimeout:1 handler:nil];
}

- (void)testInvocationWithReturnHandler {
  XCTestExpectation *blockExecuted = [self expectationWithDescription:@"Executed the test block."];
  EDOTestDummy *dummyLocal = [[EDOTestDummy alloc] initWithValue:100];

  [self
      edo_createQueueAndServiceWithRootObject:dummyLocal
                                        block:^(EDOHostService *service) {
                                          {
                                            EDOInvocationResponse *response = [self
                                                edo_runInvocationWithService:service
                                                                      target:dummyLocal
                                                                    selector:@selector(returnInt)
                                                                   arguments:@[]];
                                            int returnValue = 0;
                                            XCTAssert(strcmp(response.returnValue.objCType,
                                                             @encode(int)) == 0);
                                            [response.returnValue getValue:&returnValue];
                                            XCTAssertEqual(returnValue, 100);
                                            XCTAssertNil(response.exception);
                                            XCTAssertNil(response.outValues);
                                          }

                                          {
                                            EDOInvocationResponse *response = [self
                                                edo_runInvocationWithService:service
                                                                      target:dummyLocal
                                                                    selector:@selector(returnNumber)
                                                                   arguments:@[]];
                                            NSNumber __unsafe_unretained *returnValue;
                                            XCTAssert(strcmp(response.returnValue.objCType,
                                                             @encode(NSNumber *)) == 0);
                                            [response.returnValue getValue:&returnValue];
                                            XCTAssertEqualObjects(returnValue,
                                                                  [NSNumber numberWithInteger:100]);
                                            XCTAssertNil(response.exception);
                                            XCTAssertNil(response.outValues);
                                          }

                                          {
                                            EDOInvocationResponse *response = [self
                                                edo_runInvocationWithService:service
                                                                      target:dummyLocal
                                                                    selector:@selector(returnIdNil)
                                                                   arguments:@[]];
                                            id __unsafe_unretained returnValue;
                                            XCTAssert(strcmp(response.returnValue.objCType,
                                                             @encode(id)) == 0);
                                            [response.returnValue getValue:&returnValue];
                                            XCTAssert(returnValue == nil);
                                            XCTAssertNil(response.exception);
                                            XCTAssertNil(response.outValues);
                                          }

                                          [blockExecuted fulfill];
                                        }];
  [self waitForExpectationsWithTimeout:1 handler:nil];
}

- (void)testInvocationWithArgsAndReturnHandler {
  XCTestExpectation *blockExecuted = [self expectationWithDescription:@"Executed the test block."];
  EDOTestDummy *dummyLocal = [[EDOTestDummy alloc] initWithValue:50];

  [self
      edo_createQueueAndServiceWithRootObject:dummyLocal
                                        block:^(EDOHostService *service) {
                                          {
                                            EDOInvocationResponse *response =
                                                [self edo_runInvocationWithService:service
                                                                            target:dummyLocal
                                                                          selector:@selector
                                                                          (returnIdWithInt:)
                                                                         arguments:@[
                                                                           [self edo_intValue:10]
                                                                         ]];
                                            EDOTestDummy __unsafe_unretained *returnValue;
                                            XCTAssert(strcmp(response.returnValue.objCType,
                                                             @encode(id)) == 0);
                                            [response.returnValue getValue:&returnValue];
                                            XCTAssertEqual(
                                                [returnValue class], [EDOObject class],
                                                @"Non-value-type should be wrapped as a EDOObject");
                                            XCTAssertNil(response.exception);
                                            XCTAssertNil(response.outValues);
                                          }

                                          {
                                            EDOInvocationResponse *response = [self
                                                edo_runInvocationWithService:service
                                                                      target:dummyLocal
                                                                    selector:@selector
                                                                    (returnNumberWithInt:value:)
                                                                   arguments:@[
                                                                     [self edo_intValue:8],
                                                                     [self edo_numberValue:@9]
                                                                   ]];
                                            NSNumber __unsafe_unretained *returnValue;
                                            XCTAssert(strcmp(response.returnValue.objCType,
                                                             @encode(NSNumber *)) == 0);
                                            [response.returnValue getValue:&returnValue];

                                            // 50(dummyInitValue) + 10(selWithIdReturn:) * 2 + (8 +
                                            // 9)(selWithReturnAndArg:value:)
                                            XCTAssertEqualObjects(returnValue,
                                                                  [NSNumber numberWithInteger:87]);
                                            XCTAssertNil(response.exception);
                                            XCTAssertNil(response.outValues);
                                          }

                                          [blockExecuted fulfill];
                                        }];
  [self waitForExpectationsWithTimeout:1 handler:nil];
}

- (void)testInvocationWitOutParameters {
  XCTestExpectation *blockExecuted = [self expectationWithDescription:@"Executed the test block."];
  EDOTestDummy *dummyLocal = [[EDOTestDummy alloc] initWithValue:8];
  [self edo_createQueueAndServiceWithRootObject:dummyLocal
                                          block:^(EDOHostService *service) {
                                            {
                                              EDOBoxedValueType *nullValue = [EDOBoxedValueType
                                                  parameterForDoublePointerNullValue];
                                              EDOInvocationResponse *response = [self
                                                  edo_runInvocationWithService:service
                                                                        target:dummyLocal
                                                                      selector:@selector
                                                                      (returnBoolWithError:)
                                                                     arguments:@[ nullValue ]];
                                              XCTAssertNil(response.exception);
                                              XCTAssertEqual(response.outValues.count, 1U);

                                              BOOL retValue = YES;
                                              [response.returnValue getValue:&retValue];
                                              XCTAssertFalse(retValue);
                                            }

                                            {
                                              // nil as a pointer pointing to nil
                                              EDOBoxedValueType *nilValue =
                                                  [EDOBoxedValueType parameterForNilValue];
                                              EDOInvocationResponse *response =
                                                  [self edo_runInvocationWithService:service
                                                                              target:dummyLocal
                                                                            selector:@selector
                                                                            (returnBoolWithError:)
                                                                           arguments:@[ nilValue ]];
                                              BOOL retValue = NO;
                                              XCTAssertNil(response.exception);
                                              [response.returnValue getValue:&retValue];
                                              XCTAssertTrue(retValue);

                                              XCTAssertEqual(response.outValues.count, 1U);

                                              // Only copy the pointer address out of the
                                              // EDOBoxedValueType w/o retain/release.
                                              NSError __unsafe_unretained *errorOut;
                                              [response.outValues[0] getValue:&errorOut];

                                              // NSError is not a value type.
                                              XCTAssertEqualObjects([errorOut class],
                                                                    [EDOObject class]);
                                              XCTAssertEqual(errorOut.code, 8);
                                            }

                                            [blockExecuted fulfill];
                                          }];
  [self waitForExpectationsWithTimeout:1 handler:nil];
}

- (void)testInvocationWithThrowHandler {
  XCTestExpectation *blockExecuted = [self expectationWithDescription:@"Executed the test block."];
  EDOTestDummy *dummyLocal = [[EDOTestDummy alloc] initWithValue:50];
  [self
      edo_createQueueAndServiceWithRootObject:dummyLocal
                                        block:^(EDOHostService *service) {
                                          XCTAssertNotNil(
                                              [self edo_runInvocationWithService:service
                                                                          target:dummyLocal
                                                                        selector:@selector
                                                                        (selWithThrow)
                                                                       arguments:@[]]
                                                  .exception);
                                          {
                                            EDOBoxedValueType *nilValue =
                                                [EDOBoxedValueType parameterForNilValue];
                                            EDOInvocationResponse *response = [self
                                                edo_runInvocationWithService:service
                                                                      target:dummyLocal
                                                                    selector:@selector(voidWithId:)
                                                                   arguments:@[ nilValue ]];
                                            XCTAssertEqualObjects(
                                                response.exception,
                                                [dummyLocal exceptionWithReason:@"NilArg"]);
                                          }
                                          {
                                            id nonNilArg = @"NonNil";
                                            EDOBoxedValueType *nonNilValue =
                                                [EDOBoxedValueType parameterWithBytes:&nonNilArg
                                                                             objCType:@encode(id)];
                                            EDOInvocationResponse *response = [self
                                                edo_runInvocationWithService:service
                                                                      target:dummyLocal
                                                                    selector:@selector(voidWithId:)
                                                                   arguments:@[ nonNilValue ]];
                                            XCTAssertEqualObjects(
                                                response.exception,
                                                [dummyLocal exceptionWithReason:@"NonNilArg"]);
                                          }

                                          [blockExecuted fulfill];
                                        }];
  [self waitForExpectationsWithTimeout:1 handler:nil];
}

- (void)testClassMethodInvocationHandler {
  XCTestExpectation *blockExecuted = [self expectationWithDescription:@"Executed the test block."];
  EDOTestDummy *dummyLocal = [[EDOTestDummy alloc] init];
  [self edo_createQueueAndServiceWithRootObject:dummyLocal
                                          block:^(EDOHostService *service) {
                                            EDOInvocationResponse *response = [self
                                                edo_runInvocationWithService:service
                                                                      target:[dummyLocal class]
                                                                    selector:@selector
                                                                    (classMethodWithNumber:)
                                                                   arguments:@[
                                                                     [self edo_numberValue:@(10)]
                                                                   ]];
                                            id __unsafe_unretained returnValue;
                                            XCTAssert(strcmp(response.returnValue.objCType,
                                                             @encode(id)) == 0);
                                            [response.returnValue getValue:&returnValue];
                                            XCTAssertEqualObjects([returnValue class],
                                                                  [EDOObject class]);
                                            XCTAssertNil(response.exception);
                                            XCTAssertNil(response.outValues);

                                            [blockExecuted fulfill];
                                          }];
  [self waitForExpectationsWithTimeout:1 handler:nil];
}

- (void)testArgsMismatchedInvocationHandler {
  XCTestExpectation *blockExecuted = [self expectationWithDescription:@"Executed the test block."];
  EDOTestDummy *dummyLocal = [[EDOTestDummy alloc] initWithValue:50];

  [self
      edo_createQueueAndServiceWithRootObject:dummyLocal
                                        block:^(EDOHostService *service) {
                                          XCTAssertNotNil(
                                              [self edo_runInvocationWithService:service
                                                                          target:dummyLocal
                                                                        selector:@selector
                                                                        (returnIdWithInt:)
                                                                       arguments:@[]]
                                                  .exception);
                                          XCTAssertNotNil(
                                              [self edo_runInvocationWithService:service
                                                                          target:dummyLocal
                                                                        selector:@selector
                                                                        (nonExistMethod)
                                                                       arguments:@[]]
                                                  .exception);
                                          XCTAssertNotNil(
                                              [self edo_runInvocationWithService:service
                                                                          target:dummyLocal
                                                                        selector:@selector
                                                                        (voidWithValuePlusOne)
                                                                       arguments:@[
                                                                         [self edo_intValue:10]
                                                                       ]]
                                                  .exception);
                                          XCTAssertNotNil(
                                              [self edo_runInvocationWithService:service
                                                                          target:dummyLocal
                                                                        selector:@selector
                                                                        (voidWithInt:)
                                                                       arguments:@[
                                                                         [self edo_numberValue:@10]
                                                                       ]]
                                                  .exception);

                                          [blockExecuted fulfill];
                                        }];
  [self waitForExpectationsWithTimeout:1 handler:nil];
}

- (void)testMethodSignatureRequestHandler {
  NS_VALID_UNTIL_END_OF_SCOPE EDOTestDummy *dummyLocal = [[EDOTestDummy alloc] initWithValue:50];
  void *remoteAddress = (__bridge void *)dummyLocal;

  EDOHostService *service = [EDOHostService serviceWithPort:0
                                                 rootObject:self
                                                      queue:dispatch_get_main_queue()];

  [EDOTestDummy enumerateSelector:^(SEL selector) {
    EDOMethodSignatureRequest *request =
        [EDOMethodSignatureRequest requestWithObject:(EDOPointerType)remoteAddress
                                                port:service.port
                                            selector:selector];
    EDOMethodSignatureResponse *response =
        (EDOMethodSignatureResponse *)EDOMethodSignatureRequest.requestHandler(request, service);
    XCTAssertEqualObjects(response.signature, [self selectorSignature:selector],
                          @"the signature for %@ is not matched.", NSStringFromSelector(selector));
  }];
  EDOMethodSignatureRequest *request =
      [EDOMethodSignatureRequest requestWithObject:(EDOPointerType)remoteAddress
                                              port:service.port
                                          selector:@selector(nonExistMethod)];
  EDOMethodSignatureResponse *response =
      (EDOMethodSignatureResponse *)EDOMethodSignatureRequest.requestHandler(request, service);
  XCTAssertNil(response.signature, @"the non-exist signature should be nil.");
}

- (void)testMethodSignatureForward {
  id dummyLocal = [[EDOTestDummy alloc] init];
  NS_VALID_UNTIL_END_OF_SCOPE dispatch_queue_t queue =
      dispatch_queue_create("com.google.edo.service.test", DISPATCH_QUEUE_SERIAL);
  EDOHostService *service = [EDOHostService serviceWithPort:0 rootObject:dummyLocal queue:queue];

  [EDOTestDummy enumerateSelector:^(SEL sel) {
    EDOTestDummy *object = [EDOClientService rootObjectWithPort:service.port.port];
    NSMethodSignature *sig1 = [object methodSignatureForSelector:sel];
    NSMethodSignature *sig2 = [dummyLocal methodSignatureForSelector:sel];
    XCTAssertEqualObjects(sig1, sig2, @"The remote signature is not matched %@.",
                          NSStringFromSelector(sel));
  }];

  {
    EDOTestDummy *object = [EDOClientService rootObjectWithPort:service.port.port];
    NSMethodSignature *sig1 = [object methodSignatureForSelector:@selector(nonExistMethod)];
    NSMethodSignature *sig2 = [dummyLocal methodSignatureForSelector:@selector(nonExistMethod)];
    XCTAssertEqual(sig1, sig2);
    XCTAssertNil(sig1, @"The non-exist signature should be nil.");
  }

  {
    id dummyClazz = [service distantObjectForLocalObject:[dummyLocal class]];
    NSMethodSignature *sig1 =
        [dummyClazz methodSignatureForSelector:@selector(classMethodWithNumber:)];
    NSMethodSignature *sig2 =
        [EDOTestDummy methodSignatureForSelector:@selector(classMethodWithNumber:)];
    XCTAssertEqualObjects(sig1, sig2, @"The class method signature is not matched.");
  }
  [service invalidate];
}

- (dispatch_queue_t)edo_createQueueAndServiceWithRootObject:(id)obj
                                                      block:(void (^)(EDOHostService *))block {
  NSString *queueName = [NSString stringWithFormat:@"com.google.edo.service.%@", self.name];
  dispatch_queue_t queue = dispatch_queue_create(queueName.UTF8String, DISPATCH_QUEUE_SERIAL);
  EDOHostService *service = [EDOHostService serviceWithPort:0 rootObject:obj queue:queue];
  block(service);
  XCTAssertNotNil(queue);
  [service invalidate];
  return queue;
}

- (EDOInvocationResponse *)edo_runInvocationWithService:(EDOHostService *)service
                                                 target:(id)target
                                               selector:(SEL)selector
                                              arguments:(NSArray *)arguments {
  EDOPointerType targetPointer = (EDOPointerType)(__bridge void *)target;
  EDOInvocationRequest *request = [EDOInvocationRequest requestWithTarget:targetPointer
                                                                 selector:selector
                                                                arguments:arguments
                                                            returnByValue:NO];
  return (EDOInvocationResponse *)EDOInvocationRequest.requestHandler(request, service);
}

- (NSString *)selectorSignature:(SEL)selector {
  Method method = class_getInstanceMethod([EDOTestDummy class], selector);
  return [NSString stringWithFormat:@"%s", method_getTypeEncoding(method)];
}

- (EDOBoxedValueType *)edo_intValue:(int)value {
  return [EDOBoxedValueType parameterWithBytes:&value objCType:@encode(int)];
}

- (EDOBoxedValueType *)edo_numberValue:(NSNumber *)value {
  return [EDOBoxedValueType parameterWithBytes:&value objCType:@encode(NSNumber *)];
}

@end
