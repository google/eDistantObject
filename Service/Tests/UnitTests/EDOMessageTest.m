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

#import "Channel/Sources/EDOChannel.h"
#import "Channel/Sources/EDOChannelPool.h"
#import "Channel/Sources/EDOHostPort.h"
#import "Service/Sources/EDOBlockObject.h"
#import "Service/Sources/EDOClassMessage.h"
#import "Service/Sources/EDOClientService+Private.h"
#import "Service/Sources/EDOClientService.h"
#import "Service/Sources/EDOHostService+Private.h"
#import "Service/Sources/EDOHostService.h"
#import "Service/Sources/EDOInvocationMessage.h"
#import "Service/Sources/EDOMethodSignatureMessage.h"
#import "Service/Sources/EDOObject+Private.h"
#import "Service/Sources/EDOObject.h"
#import "Service/Sources/EDOObjectMessage.h"
#import "Service/Sources/EDOObjectReleaseMessage.h"
#import "Service/Sources/EDOParameter.h"  // IWYU pragma: keep
#import "Service/Sources/EDORemoteException.h"
#import "Service/Sources/EDOServicePort.h"
#import "Service/Sources/NSKeyedArchiver+EDOAdditions.h"
#import "Service/Sources/NSKeyedUnarchiver+EDOAdditions.h"

#import "Service/Tests/TestsBundle/EDOTestDummy.h"
#import <OCMock/OCMock.h>  // IWYU pragma: no_include "OCMockObject.h"

static const char kDeallocSentinelKey = '\0';
static const char kIsProxyHookKey = '\0';

@interface EDOHostService (EDOTestRefCounting)
@property(nonatomic, readonly) NSMutableDictionary<NSNumber *, id> *localObjects;
@property(nonatomic, readonly) NSMutableDictionary<NSNumber *, NSNumber *> *localObjectsCounts;
@property(nonatomic, readonly) dispatch_queue_t localObjectsSyncQueue;
@property(nonatomic, readonly, nullable) dispatch_queue_t executionQueue;
@end

@interface EDOObjectReleaseRequest (EDOTestRefCounting)
@property(nonatomic, readonly, getter=isCountedRelease) BOOL countedRelease;
@end

/** Fake channel capturing @c sendData:withCompletionHandler: callbacks without socket I/O. */
@interface EDOTestFakeChannel : NSObject <EDOChannel>
@property(nonatomic, nullable, copy) EDOChannelSentHandler sentHandler;
@property(nonatomic, nullable) NSData *sentData;
@property(nonatomic, readwrite, getter=isValid) BOOL valid;
@end

@implementation EDOTestFakeChannel

- (instancetype)init {
  self = [super init];
  if (self) {
    _valid = YES;
  }
  return self;
}

- (void)sendData:(NSData *)data withCompletionHandler:(EDOChannelSentHandler _Nullable)handler {
  self.sentData = data;
  self.sentHandler = handler;
}

- (void)receiveDataWithHandler:(EDOChannelReceiveHandler _Nullable)handler {
}

- (void)receiveDataWithQueue:(dispatch_queue_t)queue
                     handler:(EDOChannelReceiveHandler _Nullable)handler {
}

- (void)invalidate {
  self.valid = NO;
}

@end

/** Helper that invokes a callback when its associated owner is deallocated. */
@interface EDODeallocSentinel : NSObject
- (instancetype)initWithBlock:(dispatch_block_t)block;
@end

@implementation EDODeallocSentinel {
  dispatch_block_t _block;
}

- (instancetype)initWithBlock:(dispatch_block_t)block {
  self = [super init];
  if (self) {
    _block = [block copy];
  }
  return self;
}

- (void)dealloc {
  if (_block) {
    _block();
  }
}

@end

/** Service port wrapper that runs a one-shot hook before delegating @c -match:. */
@interface EDOHookedServicePort : EDOServicePort
@property(nonatomic) EDOServicePort *backingPort;
@property(nonatomic, copy, nullable) dispatch_block_t onMatch;
@end

@implementation EDOHookedServicePort

// testAllEDOClassesSupportNSSecureCoding requires this on EDO-prefixed NSCoding classes.
+ (BOOL)supportsSecureCoding {
  return YES;
}

- (EDOHostPort *)hostPort {
  return self.backingPort.hostPort;
}

- (UInt16)port {
  return self.backingPort.port;
}

- (BOOL)match:(EDOServicePort *)otherPort {
  dispatch_block_t hook = self.onMatch;
  self.onMatch = nil;
  if (hook) {
    hook();
  }
  return [self.backingPort match:otherPort];
}

@end

/** @c EDOObject subclass without added ivars used via @c object_setClass to hook @c -isProxy. */
@interface EDOHookedObject : EDOObject
@end

@implementation EDOHookedObject

// testAllEDOClassesSupportNSSecureCoding requires this on EDO-prefixed NSCoding classes.
+ (BOOL)supportsSecureCoding {
  return YES;
}

- (BOOL)isProxy {
  dispatch_block_t hook = objc_getAssociatedObject(self, &kIsProxyHookKey);
  if (hook) {
    objc_setAssociatedObject(self, &kIsProxyHookKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    hook();
  }
  return [super isProxy];
}

@end

@interface EDOMessageTest : XCTestCase

@end

@implementation EDOMessageTest

// To make the compiler be aware of this selector's exsitence.
- (void)nonExistMethod {
}

/**
 * Check if the @c class implements +supportsSecureCoding on its own.
 *
 * @note @c NSSecureCoding requires the subclasses also implements +supportsSecureCoding, so it
 * needs to manually to look up the methods in the class itself.
 */
- (BOOL)implementsSecureCoding:(Class)class {
  unsigned int methodCount = 0;
  Class dummyMeta = object_getClass(class);
  // Only iterates over the class methods defined in this class only.
  Method *methods = class_copyMethodList(dummyMeta, &methodCount);
  const char *secureCodingSelectorName = sel_getName(@selector(supportsSecureCoding));
  BOOL found = NO;
  for (unsigned int i = 0; i < methodCount; i++) {
    Method method = methods[i];
    char const *selectorName = sel_getName(method_getName(method));

    if (strcmp(selectorName, secureCodingSelectorName) == 0) {
      found = YES;
      break;
    }
  }

  free(methods);
  return found;
}

/** Tests that all serializable EDO classes conform to NSSecureCoding. */
- (void)testAllEDOClassesSupportNSSecureCoding {
  int numClasses = objc_getClassList(NULL, 0);
  Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * numClasses);
  numClasses = objc_getClassList(classes, numClasses);

  for (int i = 0; i < numClasses; i++) {
    Class klass = classes[i];

    // Only check classes that start with EDO and conforms to NSCoding.
    // TODO(haowoo): We need to skip NSException as it's not securely coded.
    if (memcmp(class_getName(klass), "EDO", 3) != 0 ||
        ![klass conformsToProtocol:@protocol(NSCoding)] ||
        strcmp(class_getName(klass), "EDOTestDummyException") == 0) {
      continue;
    }

    XCTAssertTrue([klass conformsToProtocol:@protocol(NSSecureCoding)],
                  @"class %s doesn't conform to NSSecureCoding", class_getName(klass));
    XCTAssertTrue([self implementsSecureCoding:classes[i]],
                  @"class %s doesn't implement supportsSecureCoding", class_getName(klass));
    XCTAssertTrue([classes[i] supportsSecureCoding],
                  @"supportsSecureCoding returns NO for class %s", class_getName(klass));
  }

  free(classes);
}

- (void)testObjectRequestHandler {
  XCTestExpectation *blockExecuted = [self expectationWithDescription:@"Executed the test block."];
  id dummyLocal = [[EDOTestDummy alloc] init];
  [self
      edo_createQueueAndServiceWithRootObject:dummyLocal
                                        block:^(EDOHostService *service) {
                                          EDOObjectResponse *response =
                                              (EDOObjectResponse *)EDOObjectRequest.requestHandler(
                                                  [EDOObjectRequest
                                                      requestWithHostPort:service.port.hostPort],
                                                  service);
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
                                                requestWithClassName:@"EDOTestDummy"
                                                            hostPort:service.port.hostPort];
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
                                                requestWithClassName:@"NonExistTestClass"
                                                            hostPort:service.port.hostPort];
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
                                            XCTAssertEqualObjects(response.exception.reason,
                                                                  @"NilArg");
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
                                            XCTAssertEqualObjects(response.exception.reason,
                                                                  @"NonNilArg");
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

  [service invalidate];
}

- (void)testMethodSignatureForward {
  id dummyLocal = [[EDOTestDummy alloc] init];
  NS_VALID_UNTIL_END_OF_SCOPE dispatch_queue_t queue =
      dispatch_queue_create("com.google.edo.service.test", DISPATCH_QUEUE_SERIAL);
  EDOHostService *service = [EDOHostService serviceWithPort:0 rootObject:dummyLocal queue:queue];

  [EDOTestDummy enumerateSelector:^(SEL sel) {
    EDOTestDummy *object = [EDOClientService rootObjectWithPort:service.port.hostPort.port];
    NSMethodSignature *sig1 = [object methodSignatureForSelector:sel];
    NSMethodSignature *sig2 = [dummyLocal methodSignatureForSelector:sel];
    XCTAssertEqualObjects(sig1, sig2, @"The remote signature is not matched %@.",
                          NSStringFromSelector(sel));
  }];

  {
    EDOTestDummy *object = [EDOClientService rootObjectWithPort:service.port.hostPort.port];
    NSMethodSignature *sig1 = [object methodSignatureForSelector:@selector(nonExistMethod)];
    NSMethodSignature *sig2 = [dummyLocal methodSignatureForSelector:@selector(nonExistMethod)];
    XCTAssertEqual(sig1, sig2);
    XCTAssertNil(sig1, @"The non-exist signature should be nil.");
  }

  {
    id dummyClazz = [service distantObjectForLocalObject:[dummyLocal class]
                                                hostPort:service.port.hostPort];
    NSMethodSignature *sig1 =
        [dummyClazz methodSignatureForSelector:@selector(classMethodWithNumber:)];
    NSMethodSignature *sig2 =
        [EDOTestDummy methodSignatureForSelector:@selector(classMethodWithNumber:)];
    XCTAssertEqualObjects(sig1, sig2, @"The class method signature is not matched.");
  }
  [service invalidate];
}

/**
 * Verifies that deallocating an uncached duplicate non-local object or block proxy preserves the
 * cached proxy at the same address, and that deallocating the cached proxy evicts it.
 */
- (void)testOlderProxyDeallocPreservesNewerCachedProxy {
  for (NSNumber *isBlockValue in @[ @NO, @YES ]) {
    BOOL isBlock = isBlockValue.boolValue;
    NSData *archive = nil;
    EDOPointerType address = [self edo_createArchivesForBlock:isBlock
                                                     archiveA:&archive
                                                     archiveB:NULL];

    __block NSUInteger cachedCount = 0;
    @autoreleasepool {
      id cachedProxy = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archive];
      EDOObject *cachedEDO = [self edo_distantObjectFromProxy:cachedProxy isBlock:isBlock];
      XCTAssertFalse(cachedEDO.isLocalEdo);
      XCTAssertFalse(cachedEDO.isLocal);
      XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:cachedProxy], cachedProxy);
      XCTAssertEqual([EDOClientService distantObjectReferenceForRemoteAddress:address],
                     cachedProxy);

      @autoreleasepool {
        id duplicateProxy = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archive];
        EDOObject *duplicateEDO = [self edo_distantObjectFromProxy:duplicateProxy isBlock:isBlock];
        XCTAssertNotEqual(duplicateProxy, cachedProxy);
        XCTAssertNotEqual(duplicateEDO, cachedEDO);
        XCTAssertFalse(duplicateEDO.isLocalEdo);
        XCTAssertFalse(duplicateEDO.isLocal);
      }

      // Duplicate proxy's dealloc must leave the cached proxy intact.
      XCTAssertEqual([EDOClientService distantObjectReferenceForRemoteAddress:address],
                     cachedProxy);
      dispatch_sync(EDOClientService.edoSyncQueue, ^{
        cachedCount = EDOClientService.localDistantObjects.count;
      });
    }

    // Dealloc of the cached proxy must evict the entry and decrement the table count.
    XCTAssertNil([EDOClientService distantObjectReferenceForRemoteAddress:address]);
    __block NSUInteger evictedCount = 0;
    dispatch_sync(EDOClientService.edoSyncQueue, ^{
      evictedCount = EDOClientService.localDistantObjects.count;
    });
    XCTAssertEqual(evictedCount, cachedCount - 1);
  }
}

/**
 * Verifies that a cache hit in @c cachedEDOFromObjectUpdateIfNeeded: marks only distinct duplicate
 * proxies @c local so the host object stays alive until the cached proxy deallocates.
 */
- (void)testCachedEDOFromObjectUpdateIfNeededMarksDuplicateLocal {
  XCTestExpectation *transientDeallocated =
      [self expectationWithDescription:@"Host released transient object when cached proxy died."];
  EDOHostService *service = [self edo_hostServiceWithName:@"com.google.edo.service.cacheDuplicate"];

  NSData *archive = nil;
  EDOPointerType address = 0;
  @autoreleasepool {
    EDOTestDummy *transient = [[EDOTestDummy alloc] initWithValue:42];
    EDODeallocSentinel *sentinel = [[EDODeallocSentinel alloc] initWithBlock:^{
      [transientDeallocated fulfill];
    }];
    objc_setAssociatedObject(transient, &kDeallocSentinelKey, sentinel,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Register transient in service.localObjects, then archive an uncounted proxy to verify the
    // legacy duplicate-local suppression path.
    [service distantObjectForLocalObject:transient hostPort:service.port.hostPort];
    EDOServicePort *servicePort = [EDOServicePort servicePortWithPort:service.port
                                                             hostPort:service.port.hostPort];
    EDOObject *legacy = [EDOObject edo_remoteProxyFromUnderlyingObject:transient
                                                              withPort:servicePort];
    address = legacy.remoteAddress;
    archive = [self edo_archiveProxy:legacy withProcessUUID:@"com.google.edotest.remote"];
  }

  @autoreleasepool {
    EDOObject *firstProxy = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archive];
    XCTAssertFalse(firstProxy.isLocalEdo);
    XCTAssertFalse(firstProxy.isLocal);
    XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:firstProxy], firstProxy);
    XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:firstProxy], firstProxy);
    XCTAssertFalse(firstProxy.isLocal);

    @autoreleasepool {
      EDOObject *duplicateProxy = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archive];
      XCTAssertFalse(duplicateProxy.isLocal);
      id resolved = [EDOClientService cachedEDOFromObjectUpdateIfNeeded:duplicateProxy];
      XCTAssertEqual(resolved, firstProxy);
      XCTAssertTrue(duplicateProxy.isLocal);
    }

    XCTAssertEqual([EDOClientService distantObjectReferenceForRemoteAddress:address], firstProxy);
    @autoreleasepool {
      XCTAssertEqual([(EDOTestDummy *)firstProxy returnInt], 42);
    }
  }

  XCTAssertNil([EDOClientService distantObjectReferenceForRemoteAddress:address]);
  [self waitForExpectations:@[ transientDeallocated ] timeout:2.0];
}

/**
 * Verifies cache hit unwrapping, port-mismatch replacement, and live identity-checked removal for
 * both object and block proxies.
 */
- (void)testCachedProxyHitPortMismatchAndLiveRemoval {
  for (NSNumber *isBlockValue in @[ @NO, @YES ]) {
    BOOL isBlock = isBlockValue.boolValue;
    NSData *archiveA = nil;
    NSData *archiveB = nil;
    EDOPointerType sharedAddress = [self edo_createArchivesForBlock:isBlock
                                                           archiveA:&archiveA
                                                           archiveB:&archiveB];
    @autoreleasepool {
      id proxyA1 = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archiveA];
      id proxyA2 = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archiveA];
      id proxyB = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archiveB];
      EDOObject *edoA1 = [self edo_distantObjectFromProxy:proxyA1 isBlock:isBlock];
      EDOObject *edoA2 = [self edo_distantObjectFromProxy:proxyA2 isBlock:isBlock];
      EDOObject *edoB = [self edo_distantObjectFromProxy:proxyB isBlock:isBlock];

      XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:proxyA1], proxyA1);
      XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:proxyA1], proxyA1);
      XCTAssertFalse(edoA1.isLocal);

      // Same-port duplicate hit must unwrap localEDO and leave counted duplicate remote so dealloc
      // balances the host's counted vend.
      XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:proxyA2], proxyA1);
      XCTAssertTrue(edoA2.countedByHost);
      XCTAssertFalse(edoA2.isLocal);

      // Mismatched port must replace proxyA1 instead of keeping stale entry.
      XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:proxyB], proxyB);
      XCTAssertEqual([EDOClientService distantObjectReferenceForRemoteAddress:sharedAddress],
                     proxyB);
      XCTAssertFalse(edoB.isLocal);

      // Live identity-checked removal must unwrap cachedEDO and evict only proxyB.
      [EDOClientService removeDistantObjectReferenceForObject:edoA1];
      XCTAssertEqual([EDOClientService distantObjectReferenceForRemoteAddress:sharedAddress],
                     proxyB);
      [EDOClientService removeDistantObjectReferenceForObject:edoB];
      XCTAssertNil([EDOClientService distantObjectReferenceForRemoteAddress:sharedAddress]);

      // Suppress async teardown release writes after verifying cache state since this test isolates
      // client cache eviction rather than host release transport.
      edoA1.local = YES;
      edoA2.local = YES;
      edoB.local = YES;
    }
    XCTAssertNil([EDOClientService distantObjectReferenceForRemoteAddress:sharedAddress]);
  }
}

/**
 * Verifies that concurrent lookups in @c cachedEDOFromObjectUpdateIfNeeded: serialize to one
 * non-local cached proxy.
 */
- (void)testCachedEDOFromObjectUpdateIfNeededSerializesConcurrentLookups {
  for (NSNumber *isBlockValue in @[ @NO, @YES ]) {
    BOOL isBlock = isBlockValue.boolValue;
    EDOHostService *serviceA = [self
        edo_hostServiceWithName:[NSString
                                    stringWithFormat:@"com.google.edo.service.cacheConcurrent.%d",
                                                     isBlock]];
    id target = [self edo_testTargetForBlock:isBlock];
    NSData *archiveA = nil;
    EDOPointerType sharedAddress = 0;
    @autoreleasepool {
      // Register target once on serviceA, then archive an uncounted proxy to verify legacy
      // concurrent duplicate-local suppression without tripping per-vend refcounting.
      [serviceA distantObjectForLocalObject:target hostPort:serviceA.port.hostPort];
      id copiedTarget = isBlock ? [target copy] : target;
      EDOServicePort *servicePort = [EDOServicePort servicePortWithPort:serviceA.port
                                                               hostPort:serviceA.port.hostPort];
      EDOObject *legacyVended =
          isBlock
              ? [EDOBlockObject edo_remoteProxyFromUnderlyingObject:copiedTarget
                                                           withPort:servicePort]
              : [EDOObject edo_remoteProxyFromUnderlyingObject:copiedTarget withPort:servicePort];
      sharedAddress = legacyVended.remoteAddress;
      archiveA = [self edo_archiveProxy:legacyVended withProcessUUID:@"com.google.edotest.remoteA"];
    }
    dispatch_queue_t concurrentQueue = dispatch_queue_create(
        "com.google.edo.test.clientCacheConcurrent", DISPATCH_QUEUE_CONCURRENT);
    const size_t workerCount = 4;
    for (int round = 0; round < 25; ++round) {
      @autoreleasepool {
        NSMutableArray<id> *proxies = [NSMutableArray arrayWithCapacity:workerCount];
        NSMutableArray<id> *results = [NSMutableArray arrayWithCapacity:workerCount];
        for (size_t i = 0; i < workerCount; ++i) {
          [proxies addObject:[NSKeyedUnarchiver edo_unarchiveObjectWithData:archiveA]];
          [results addObject:[NSNull null]];
        }
        dispatch_apply(workerCount, concurrentQueue, ^(size_t idx) {
          @autoreleasepool {
            id resolved = [EDOClientService cachedEDOFromObjectUpdateIfNeeded:proxies[idx]];
            @synchronized(results) {
              results[idx] = resolved;
            }
          }
        });

        id winner = results[0];
        XCTAssertNotEqual(winner, (id)[NSNull null]);
        XCTAssertFalse([self edo_distantObjectFromProxy:winner isBlock:isBlock].isLocal);
        NSUInteger nonLocalCount = 0;
        for (size_t i = 0; i < workerCount; ++i) {
          XCTAssertEqual(results[i], winner);
          if (![self edo_distantObjectFromProxy:proxies[i] isBlock:isBlock].isLocal) {
            nonLocalCount += 1;
          }
        }
        XCTAssertEqual(nonLocalCount, 1U);
        // Suppress async release writes after asserting non-local winner selection.
        [self edo_distantObjectFromProxy:winner isBlock:isBlock].local = YES;
      }
      XCTAssertNil([EDOClientService distantObjectReferenceForRemoteAddress:sharedAddress]);
    }
    [EDOChannelPool.sharedChannelPool removeChannelsWithPort:serviceA.port.hostPort];
  }
}

/**
 * Verifies that @c cachedEDOFromObjectUpdateIfNeeded: checks port match on @c edoSyncQueue and
 * releases a displaced @c EDOObject or @c EDOBlockObject outside @c edoSyncQueue when its final
 * external strong reference drops mid-dispatch.
 */
- (void)testCachedEDOFromObjectUpdateIfNeededReleasesDisplacedEntryOutsideQueue {
  for (NSNumber *isBlockValue in @[ @NO, @YES ]) {
    BOOL isBlock = isBlockValue.boolValue;
    NSData *archiveA = nil;
    NSData *archiveB = nil;
    EDOPointerType sharedAddress = [self edo_createArchivesForBlock:isBlock
                                                           archiveA:&archiveA
                                                           archiveB:&archiveB];
    __block BOOL proxyADeallocated = NO;
    __block id externalProxyA = nil;
    @autoreleasepool {
      externalProxyA = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archiveA];
      EDOObject *edoA = [self edo_distantObjectFromProxy:externalProxyA isBlock:isBlock];
      EDODeallocSentinel *sentinel = [[EDODeallocSentinel alloc] initWithBlock:^{
        proxyADeallocated = YES;
      }];
      objc_setAssociatedObject(edoA, &kDeallocSentinelKey, sentinel,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:externalProxyA],
                     externalProxyA);
    }
    XCTAssertFalse(proxyADeallocated);

    dispatch_semaphore_t enteredMatch = dispatch_semaphore_create(0);
    dispatch_semaphore_t releasedExternalRef = dispatch_semaphore_create(0);
    dispatch_semaphore_t postMatchQueueProbe = dispatch_semaphore_create(0);
    dispatch_group_t releaseGroup = dispatch_group_create();
    dispatch_group_async(releaseGroup, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      XCTAssertEqual(
          dispatch_semaphore_wait(enteredMatch, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)),
          0);
      externalProxyA = nil;
      dispatch_semaphore_signal(releasedExternalRef);
    });

    @autoreleasepool {
      id proxyB = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archiveB];
      EDOObject *edoB = [self edo_distantObjectFromProxy:proxyB isBlock:isBlock];
      // Swap readonly _servicePort via ivar to intercept -match: without changing production
      // headers.
      Ivar portIvar = class_getInstanceVariable([EDOObject class], "_servicePort");
      XCTAssertTrue(portIvar != NULL);
      EDOHookedServicePort *hookedPort = [[EDOHookedServicePort alloc] init];
      hookedPort.backingPort = edoB.servicePort;
      __block id cachedAfterMatchDispatch = nil;
      hookedPort.onMatch = ^{
        dispatch_assert_queue(EDOClientService.edoSyncQueue);
        // Enqueue a FIFO probe while still holding edoSyncQueue so it runs immediately after the
        // current dispatch_sync finishes and before any hypothetical second dispatch_sync insert.
        dispatch_async(EDOClientService.edoSyncQueue, ^{
          @autoreleasepool {
            cachedAfterMatchDispatch =
                [EDOClientService.localDistantObjects objectForKey:@(sharedAddress)];
          }
          dispatch_semaphore_signal(postMatchQueueProbe);
        });
        dispatch_semaphore_signal(enteredMatch);
        XCTAssertEqual(dispatch_semaphore_wait(releasedExternalRef,
                                               dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)),
                       0);
      };
      object_setIvar(edoB, portIvar, hookedPort);

      id resolved = [EDOClientService cachedEDOFromObjectUpdateIfNeeded:proxyB];
      XCTAssertEqual(resolved, proxyB);
      XCTAssertEqual(dispatch_semaphore_wait(postMatchQueueProbe,
                                             dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)),
                     0);
      XCTAssertEqual(cachedAfterMatchDispatch, proxyB);
      cachedAfterMatchDispatch = nil;
      XCTAssertTrue(proxyADeallocated);
      XCTAssertEqual([EDOClientService distantObjectReferenceForRemoteAddress:sharedAddress],
                     proxyB);
    }

    XCTAssertEqual(
        dispatch_group_wait(releaseGroup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);
    XCTAssertNil([EDOClientService distantObjectReferenceForRemoteAddress:sharedAddress]);
  }
}

/**
 * Verifies legacy @c removeDistantObjectReference: eviction and that
 * @c removeDistantObjectReferenceForObject: releases a loaded cached proxy outside
 * @c edoSyncQueue when its external strong reference drops mid-dispatch.
 */
- (void)testRemoveDistantObjectReferenceSupportsLegacyRemovalAndOutsideQueueRelease {
  NSData *archiveA = nil;
  NSData *archiveB = nil;
  EDOPointerType sharedAddress = [self edo_createArchivesForBlock:NO
                                                         archiveA:&archiveA
                                                         archiveB:&archiveB];
  @autoreleasepool {
    EDOObject *legacyProxy = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archiveA];
    @try {
      XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:legacyProxy], legacyProxy);
      XCTAssertEqual([EDOClientService distantObjectReferenceForRemoteAddress:sharedAddress],
                     legacyProxy);
      [EDOClientService removeDistantObjectReference:sharedAddress];
      XCTAssertNil([EDOClientService distantObjectReferenceForRemoteAddress:sharedAddress]);
      [EDOClientService removeDistantObjectReference:sharedAddress];
    } @finally {
      // Mark manually evicted proxy local so -dealloc does not release host object for archiveB.
      legacyProxy.local = YES;
    }
  }
  __block BOOL proxyBDeallocated = NO;
  __block EDOObject *externalProxyB = nil;
  @autoreleasepool {
    externalProxyB = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archiveB];
    EDODeallocSentinel *sentinel = [[EDODeallocSentinel alloc] initWithBlock:^{
      proxyBDeallocated = YES;
    }];
    objc_setAssociatedObject(externalProxyB, &kDeallocSentinelKey, sentinel,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:externalProxyB],
                   externalProxyB);
  }
  XCTAssertFalse(proxyBDeallocated);

  dispatch_semaphore_t enteredIsProxy = dispatch_semaphore_create(0);
  dispatch_semaphore_t releasedExternalRef = dispatch_semaphore_create(0);
  dispatch_group_t releaseGroup = dispatch_group_create();
  objc_setAssociatedObject(
      externalProxyB, &kIsProxyHookKey,
      ^{
        dispatch_assert_queue(EDOClientService.edoSyncQueue);
        dispatch_semaphore_signal(enteredIsProxy);
        XCTAssertEqual(dispatch_semaphore_wait(releasedExternalRef,
                                               dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)),
                       0);
      },
      OBJC_ASSOCIATION_COPY_NONATOMIC);
  object_setClass(externalProxyB, [EDOHookedObject class]);

  dispatch_group_async(releaseGroup, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    XCTAssertEqual(
        dispatch_semaphore_wait(enteredIsProxy, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)),
        0);
    externalProxyB = nil;
    dispatch_semaphore_signal(releasedExternalRef);
  });

  @autoreleasepool {
    EDOObject *proxyA = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archiveA];
    [EDOClientService removeDistantObjectReferenceForObject:proxyA];
    XCTAssertTrue(proxyBDeallocated);
  }

  XCTAssertEqual(
      dispatch_group_wait(releaseGroup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);
  XCTAssertNil([EDOClientService distantObjectReferenceForRemoteAddress:sharedAddress]);
}

/**
 * Verifies pass-through for non-cached inputs (local block, non-eDO @c NSProxy, @c EDOObject
 * subclass) and replacement when either the incoming or cached @c servicePort is @c nil.
 */
- (void)testCachedEDOFromObjectUpdateIfNeededHandlesEdgePartitionsAndNilPort {
  XCTAssertNil([EDOClientService cachedEDOFromObjectUpdateIfNeeded:nil]);
  int (^localBlock)(void) = ^{
    return 1;
  };
  XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:localBlock], localBlock);

  EDOHostService *service = [self edo_hostServiceWithName:@"com.google.edo.service.edgePartitions"];
  id target = [self edo_testTargetForBlock:NO];
  EDOPointerType address = 0;
  @autoreleasepool {
    EDOObject *rawValid = [service distantObjectForLocalObject:target
                                                      hostPort:service.port.hostPort];
    address = rawValid.remoteAddress;
    NSData *validArchive = [self edo_archiveProxy:rawValid
                                  withProcessUUID:@"com.google.edotest.validPort"];
    EDOObject *rawNilPort = [service distantObjectForLocalObject:target
                                                        hostPort:service.port.hostPort];
    // Clear readonly _servicePort via ivar to test nil-port wire payloads without changing headers.
    Ivar portIvar = class_getInstanceVariable([EDOObject class], "_servicePort");
    XCTAssertTrue(portIvar != NULL);
    object_setIvar(rawNilPort, portIvar, nil);
    NSData *nilPortArchive = [self edo_archiveProxy:rawNilPort
                                    withProcessUUID:@"com.google.edotest.nilPort"];

    EDOObject *validProxy = [NSKeyedUnarchiver edo_unarchiveObjectWithData:validArchive];
    id nonEdoProxy = [validProxy returnByValue];
    XCTAssertTrue([EDOClientService cachedEDOFromObjectUpdateIfNeeded:nonEdoProxy] == nonEdoProxy);

    EDOObject *subclassProxy = [NSKeyedUnarchiver edo_unarchiveObjectWithData:validArchive];
    subclassProxy.local = YES;
    object_setClass(subclassProxy, [EDOHookedObject class]);
    XCTAssertTrue([EDOClientService cachedEDOFromObjectUpdateIfNeeded:subclassProxy] ==
                  subclassProxy);
    XCTAssertNil([EDOClientService distantObjectReferenceForRemoteAddress:address]);

    EDOObject *nilPortProxyA = [NSKeyedUnarchiver edo_unarchiveObjectWithData:nilPortArchive];
    EDOObject *nilPortProxyB = [NSKeyedUnarchiver edo_unarchiveObjectWithData:nilPortArchive];
    @try {
      XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:validProxy], validProxy);
      // Incoming nil servicePort must not match a valid cached port.
      XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:nilPortProxyA],
                     nilPortProxyA);
      XCTAssertFalse(nilPortProxyA.isLocal);
      // Cached nil servicePort must not match an incoming nil servicePort.
      XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:nilPortProxyB],
                     nilPortProxyB);
      XCTAssertFalse(nilPortProxyB.isLocal);
      // Incoming valid servicePort replaces cached nil servicePort.
      XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:validProxy], validProxy);
    } @finally {
      // Mark synthetic nil-port proxies local so -dealloc skips sending on nil hostPort.
      nilPortProxyA.local = YES;
      nilPortProxyB.local = YES;
    }
  }
  XCTAssertNil([EDOClientService distantObjectReferenceForRemoteAddress:address]);
}

/**
 * Verifies repeated vending increments per-vend counts and requires matching counted releases
 * before dropping the underlying object from the host cache.
 *
 */
- (void)testRepeatedVendingIncrementsAndRequiresMatchingCountedReleases {
  EDOHostService *service = [self edo_hostServiceWithName:@"com.google.edo.service.refcount1"];
  XCTestExpectation *deallocExpectation = [self expectationWithDescription:@"target deallocated"];
  __weak EDOTestDummy *weakTarget = nil;
  EDOPointerType address = 0;

  @autoreleasepool {
    EDOTestDummy *target = [[EDOTestDummy alloc] initWithValue:42];
    weakTarget = target;
    EDODeallocSentinel *sentinel = [[EDODeallocSentinel alloc] initWithBlock:^{
      [deallocExpectation fulfill];
    }];
    objc_setAssociatedObject(target, &kDeallocSentinelKey, sentinel,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    EDOObject *vended1 = [service distantObjectForLocalObject:target hostPort:nil];
    EDOObject *vended2 = [service distantObjectForLocalObject:target hostPort:nil];
    XCTAssertTrue(vended1.isLocal);
    XCTAssertTrue(vended2.isLocal);
    address = vended1.remoteAddress;
    XCTAssertEqual(address, vended2.remoteAddress);
  }

  XCTAssertNotNil(weakTarget);
  __block id trackedEntry = nil;
  __block NSNumber *trackedCount = nil;
  dispatch_sync(service.localObjectsSyncQueue, ^{
    trackedEntry = service.localObjects[@(address)];
    trackedCount = service.localObjectsCounts[@(address)];
  });
  XCTAssertNotNil(trackedEntry);
  XCTAssertEqualObjects(trackedCount, @2);
  trackedEntry = nil;

  XCTAssertTrue([service releaseObjectWithAddress:address]);
  XCTAssertNotNil(weakTarget);
  dispatch_sync(service.localObjectsSyncQueue, ^{
    trackedEntry = service.localObjects[@(address)];
    trackedCount = service.localObjectsCounts[@(address)];
  });
  XCTAssertNotNil(trackedEntry);
  XCTAssertEqualObjects(trackedCount, @1);
  trackedEntry = nil;

  XCTAssertTrue([service releaseObjectWithAddress:address]);
  [self waitForExpectations:@[ deallocExpectation ] timeout:5.0];
  XCTAssertNil(weakTarget);
  dispatch_sync(service.localObjectsSyncQueue, ^{
    trackedEntry = service.localObjects[@(address)];
    trackedCount = service.localObjectsCounts[@(address)];
  });
  XCTAssertNil(trackedEntry);
  XCTAssertNil(trackedCount);
  XCTAssertFalse([service releaseObjectWithAddress:address]);
}

/**
 * Verifies legacy @c removeObjectWithAddress: and uncounted @c EDOObjectReleaseRequest messages
 * force-clear all outstanding vends immediately.
 *
 */
- (void)testLegacyRemoveObjectForceClearsMultipleVendsAndLegacyReleaseRequest {
  EDOHostService *service = [self edo_hostServiceWithName:@"com.google.edo.service.refcount2"];

  // Direct removeObjectWithAddress: clears count = 2 immediately.
  XCTestExpectation *deallocA = [self expectationWithDescription:@"target A deallocated"];
  __weak EDOTestDummy *weakA = nil;
  EDOPointerType addressA = 0;
  @autoreleasepool {
    EDOTestDummy *targetA = [[EDOTestDummy alloc] initWithValue:1];
    weakA = targetA;
    EDODeallocSentinel *sentinel = [[EDODeallocSentinel alloc] initWithBlock:^{
      [deallocA fulfill];
    }];
    objc_setAssociatedObject(targetA, &kDeallocSentinelKey, sentinel,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    EDOObject *vended1 = [service distantObjectForLocalObject:targetA hostPort:nil];
    [service distantObjectForLocalObject:targetA hostPort:nil];
    addressA = vended1.remoteAddress;
  }
  XCTAssertTrue([service removeObjectWithAddress:addressA]);
  [self waitForExpectations:@[ deallocA ] timeout:5.0];
  XCTAssertNil(weakA);
  dispatch_sync(service.localObjectsSyncQueue, ^{
    XCTAssertNil(service.localObjects[@(addressA)]);
    XCTAssertNil(service.localObjectsCounts[@(addressA)]);
  });
  XCTAssertFalse([service removeObjectWithAddress:addressA]);

  // Legacy uncounted EDOObjectReleaseRequest force-removes despite count = 2.
  XCTestExpectation *deallocB = [self expectationWithDescription:@"target B deallocated"];
  __weak EDOTestDummy *weakB = nil;
  EDOPointerType addressB = 0;
  @autoreleasepool {
    EDOTestDummy *targetB = [[EDOTestDummy alloc] initWithValue:2];
    weakB = targetB;
    EDODeallocSentinel *sentinel = [[EDODeallocSentinel alloc] initWithBlock:^{
      [deallocB fulfill];
    }];
    objc_setAssociatedObject(targetB, &kDeallocSentinelKey, sentinel,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    EDOObject *vended1 = [service distantObjectForLocalObject:targetB hostPort:nil];
    [service distantObjectForLocalObject:targetB hostPort:nil];
    addressB = vended1.remoteAddress;
  }
  EDOObjectReleaseRequest *legacyRequest =
      [EDOObjectReleaseRequest requestWithRemoteAddress:addressB];
  NSData *archivedRequest = [NSKeyedArchiver edo_archivedDataWithObject:legacyRequest];
  EDOObjectReleaseRequest *decodedRequest =
      [NSKeyedUnarchiver edo_unarchiveObjectWithData:archivedRequest];
  EDOObjectReleaseRequest.requestHandler(decodedRequest, service);
  [self waitForExpectations:@[ deallocB ] timeout:5.0];
  XCTAssertNil(weakB);
  dispatch_sync(service.localObjectsSyncQueue, ^{
    XCTAssertNil(service.localObjects[@(addressB)]);
    XCTAssertNil(service.localObjectsCounts[@(addressB)]);
  });
}

/**
 * Verifies duplicate incoming counted proxies send counted releases on dealloc to balance the
 * host's per-vend increment while preserving the cached client proxy for both objects and blocks.
 *
 */
- (void)testDuplicateCountedProxyRetainsHostCountAndPreservesCachedProxy {
  for (NSNumber *isBlockValue in @[ @NO, @YES ]) {
    BOOL isBlock = isBlockValue.boolValue;
    NSString *serviceName =
        [NSString stringWithFormat:@"com.google.edo.service.dupCounted.%d", isBlock];
    EDOHostService *service = [self edo_hostServiceWithName:serviceName];
    XCTestExpectation *deallocExpectation = [self expectationWithDescription:@"target deallocated"];
    __weak id weakTarget = nil;
    EDOPointerType address = 0;

    @autoreleasepool {
      NSData *archive1 = nil;
      NSData *archive2 = nil;
      @autoreleasepool {
        id target;
        if (isBlock) {
          EDOTestDummy *capturedDummy = [[EDOTestDummy alloc] initWithValue:99];
          // Capture a heap object so -copy allocates a distinct __NSMallocBlock__ per call.
          target = (id)[^int {
            return capturedDummy.value;
          } copy];
        } else {
          target = [[EDOTestDummy alloc] initWithValue:99];
        }
        weakTarget = target;
        EDODeallocSentinel *sentinel = [[EDODeallocSentinel alloc] initWithBlock:^{
          [deallocExpectation fulfill];
        }];
        objc_setAssociatedObject(target, &kDeallocSentinelKey, sentinel,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        EDOObject *vended1 = [service distantObjectForLocalObject:target
                                                         hostPort:service.port.hostPort];
        EDOObject *vended2 = [service distantObjectForLocalObject:target
                                                         hostPort:service.port.hostPort];
        address = vended1.remoteAddress;
        archive1 = [self edo_archiveProxy:vended1 withProcessUUID:@"com.google.edotest.remote"];
        archive2 = [self edo_archiveProxy:vended2 withProcessUUID:@"com.google.edotest.remote"];
      }

      __block NSNumber *initialCount = nil;
      dispatch_sync(service.localObjectsSyncQueue, ^{
        initialCount = service.localObjectsCounts[@(address)];
      });
      XCTAssertEqualObjects(initialCount, @2);

      XCTestExpectation *dupReleaseExpectation =
          [self expectationWithDescription:@"duplicate counted release processed"];
      Method releaseMethod =
          class_getInstanceMethod([EDOHostService class], @selector(releaseObjectWithAddress:));
      typedef BOOL (*ReleaseIMP)(id, SEL, EDOPointerType);
      ReleaseIMP originalIMP = (ReleaseIMP)method_getImplementation(releaseMethod);
      IMP wrapperIMP = imp_implementationWithBlock(^BOOL(id instance, EDOPointerType addr) {
        BOOL result = originalIMP(instance, @selector(releaseObjectWithAddress:), addr);
        if (instance == service && addr == address) {
          [dupReleaseExpectation fulfill];
        }
        return result;
      });
      method_setImplementation(releaseMethod, wrapperIMP);

      @try {
        @autoreleasepool {
          id proxy1 = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archive1];
          XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:proxy1], proxy1);

          @autoreleasepool {
            id proxy2 = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archive2];
            EDOObject *distantObject2 = [self edo_distantObjectFromProxy:proxy2 isBlock:isBlock];
            XCTAssertTrue(distantObject2.countedByHost);
            id resolved = [EDOClientService cachedEDOFromObjectUpdateIfNeeded:proxy2];
            XCTAssertEqual(resolved, proxy1);
            // Counted duplicates stay remote so dealloc emits one counted release.
            XCTAssertFalse(distantObject2.isLocal);
          }

          // Duplicate counted release should decrement count from 2 to 1 while cached proxy stays
          // usable. Wait deterministically for the async release request on the host queue.
          [self waitForExpectations:@[ dupReleaseExpectation ] timeout:5.0];
          method_setImplementation(releaseMethod, (IMP)originalIMP);

          __block NSNumber *midCount = nil;
          __block id midTracked = nil;
          dispatch_sync(service.localObjectsSyncQueue, ^{
            midCount = service.localObjectsCounts[@(address)];
            midTracked = service.localObjects[@(address)];
          });
          XCTAssertEqualObjects(midCount, @1);
          XCTAssertNotNil(midTracked);
          XCTAssertNotNil(weakTarget);
          if (isBlock) {
            XCTAssertEqual(((int (^)(void))proxy1)(), 99);
          } else {
            XCTAssertEqual([(EDOTestDummy *)proxy1 returnInt], 99);
          }
          XCTAssertEqual([EDOClientService distantObjectReferenceForRemoteAddress:address], proxy1);
        }

        // First proxy's dealloc releases the remaining host vend count.
        [self waitForExpectations:@[ deallocExpectation ] timeout:5.0];
      } @finally {
        method_setImplementation(releaseMethod, (IMP)originalIMP);
        if (service.executionQueue) {
          // Drain the execution queue so pending async releases finish before imp_removeBlock.
          dispatch_sync(service.executionQueue, ^{
                        });
        }
        imp_removeBlock(wrapperIMP);
      }
      XCTAssertNil(weakTarget);
      __block NSNumber *finalCount = nil;
      __block id finalTracked = nil;
      dispatch_sync(service.localObjectsSyncQueue, ^{
        finalCount = service.localObjectsCounts[@(address)];
        finalTracked = service.localObjects[@(address)];
      });
      XCTAssertNil(finalCount);
      XCTAssertNil(finalTracked);
      XCTAssertNil([EDOClientService distantObjectReferenceForRemoteAddress:address]);
    }
    [EDOChannelPool.sharedChannelPool removeChannelsWithPort:service.port.hostPort];
  }
}

/**
 * Verifies legacy uncounted duplicate proxies are marked local to suppress release, and
 * re-encoding a decoded counted proxy drops @c edoCountedByHost so it falls back to legacy
 * release.
 *
 */
- (void)testLegacyProxyMarksDuplicateLocalAndReencodedCountedProxyFallsBackToLegacy {
  EDOHostService *service = [self edo_hostServiceWithName:@"com.google.edo.service.compat"];
  EDOServicePort *servicePort = [EDOServicePort servicePortWithPort:service.port
                                                           hostPort:service.port.hostPort];

  // Part A: legacy proxy without edoCountedByHost marks duplicate local.
  XCTestExpectation *deallocA = [self expectationWithDescription:@"target A deallocated"];
  __weak EDOTestDummy *weakA = nil;
  EDOPointerType addressA = 0;
  @autoreleasepool {
    NSData *legacyArchive1 = nil;
    NSData *legacyArchive2 = nil;
    @autoreleasepool {
      EDOTestDummy *targetA = [[EDOTestDummy alloc] initWithValue:10];
      weakA = targetA;
      EDODeallocSentinel *sentinel = [[EDODeallocSentinel alloc] initWithBlock:^{
        [deallocA fulfill];
      }];
      objc_setAssociatedObject(targetA, &kDeallocSentinelKey, sentinel,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      // Put 2 counted vends on the host, then create uncounted archives simulating an older host.
      [service distantObjectForLocalObject:targetA hostPort:nil];
      [service distantObjectForLocalObject:targetA hostPort:nil];
      EDOObject *legacy1 = [EDOObject edo_remoteProxyFromUnderlyingObject:targetA
                                                                 withPort:servicePort];
      EDOObject *legacy2 = [EDOObject edo_remoteProxyFromUnderlyingObject:targetA
                                                                 withPort:servicePort];
      addressA = legacy1.remoteAddress;
      legacyArchive1 = [self edo_archiveProxy:legacy1 withProcessUUID:@"com.google.edotest.remote"];
      legacyArchive2 = [self edo_archiveProxy:legacy2 withProcessUUID:@"com.google.edotest.remote"];
    }

    @autoreleasepool {
      EDOObject *decoded1 = [NSKeyedUnarchiver edo_unarchiveObjectWithData:legacyArchive1];
      XCTAssertFalse(decoded1.countedByHost);
      XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:decoded1], decoded1);

      @autoreleasepool {
        EDOObject *decoded2 = [NSKeyedUnarchiver edo_unarchiveObjectWithData:legacyArchive2];
        XCTAssertFalse(decoded2.countedByHost);
        XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:decoded2], decoded1);
        XCTAssertTrue(decoded2.isLocal);
      }

      // Duplicate legacy proxy was marked local, so host count remains 2.
      __block NSNumber *countAfterDup = nil;
      dispatch_sync(service.localObjectsSyncQueue, ^{
        countAfterDup = service.localObjectsCounts[@(addressA)];
      });
      XCTAssertEqualObjects(countAfterDup, @2);
    }

    // Primary legacy proxy sends uncounted release, force-clearing host entry.
    [self waitForExpectations:@[ deallocA ] timeout:5.0];
    XCTAssertNil(weakA);
  }

  // Part B: re-encoding a decoded counted proxy drops edoCountedByHost and falls back to legacy
  // release.
  XCTestExpectation *deallocB = [self expectationWithDescription:@"target B deallocated"];
  __weak EDOTestDummy *weakB = nil;
  EDOPointerType addressB = 0;
  @autoreleasepool {
    NSData *archive1 = nil;
    @autoreleasepool {
      EDOTestDummy *targetB = [[EDOTestDummy alloc] initWithValue:20];
      weakB = targetB;
      EDODeallocSentinel *sentinel = [[EDODeallocSentinel alloc] initWithBlock:^{
        [deallocB fulfill];
      }];
      objc_setAssociatedObject(targetB, &kDeallocSentinelKey, sentinel,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      EDOObject *vended1 = [service distantObjectForLocalObject:targetB
                                                       hostPort:service.port.hostPort];
      [service distantObjectForLocalObject:targetB hostPort:nil];
      addressB = vended1.remoteAddress;
      archive1 = [self edo_archiveProxy:vended1 withProcessUUID:@"com.google.edotest.remote1"];
    }

    EDOObject *decoded = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archive1];
    XCTAssertTrue(decoded.countedByHost);
    NSData *reencodedArchive = [self edo_archiveProxy:decoded
                                      withProcessUUID:@"com.google.edotest.remote2"];
    // Mark first decoded proxy local so only the re-encoded copy drives host release below.
    decoded.local = YES;

    @autoreleasepool {
      EDOObject *reencoded = [NSKeyedUnarchiver edo_unarchiveObjectWithData:reencodedArchive];
      XCTAssertFalse(reencoded.countedByHost);
    }

    // Re-encoded proxy sent a legacy release, force-removing despite host count = 2.
    [self waitForExpectations:@[ deallocB ] timeout:5.0];
    XCTAssertNil(weakB);
    dispatch_sync(service.localObjectsSyncQueue, ^{
      XCTAssertNil(service.localObjects[@(addressB)]);
      XCTAssertNil(service.localObjectsCounts[@(addressB)]);
    });
  }
  [EDOChannelPool.sharedChannelPool removeChannelsWithPort:service.port.hostPort];
}

/**
 * Verifies @c EDOObjectReleaseRequest counted factory preserves its flag across archive round
 * trips and decrements host vend count cleanly via @c requestHandler.
 *
 */
- (void)testCountedReleaseRequestArchiveRoundTripDecrementsCount {
  EDOHostService *service = [self edo_hostServiceWithName:@"com.google.edo.service.reqRoundTrip"];
  XCTestExpectation *deallocExpectation = [self expectationWithDescription:@"target deallocated"];
  __weak EDOTestDummy *weakTarget = nil;
  EDOPointerType address = 0;

  @autoreleasepool {
    EDOTestDummy *target = [[EDOTestDummy alloc] initWithValue:77];
    weakTarget = target;
    EDODeallocSentinel *sentinel = [[EDODeallocSentinel alloc] initWithBlock:^{
      [deallocExpectation fulfill];
    }];
    objc_setAssociatedObject(target, &kDeallocSentinelKey, sentinel,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    EDOObject *vended = [service distantObjectForLocalObject:target hostPort:nil];
    [service distantObjectForLocalObject:target hostPort:nil];
    address = vended.remoteAddress;
  }

  EDOObjectReleaseRequest *countedRequest =
      [EDOObjectReleaseRequest requestWithCountedRemoteAddress:address];
  NSData *archived1 = [NSKeyedArchiver edo_archivedDataWithObject:countedRequest];
  EDOObjectReleaseRequest *decoded1 = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archived1];
  XCTAssertTrue(decoded1.countedRelease);
  EDOObjectReleaseRequest.requestHandler(decoded1, service);

  XCTAssertNotNil(weakTarget);
  dispatch_sync(service.localObjectsSyncQueue, ^{
    XCTAssertNotNil(service.localObjects[@(address)]);
    XCTAssertEqualObjects(service.localObjectsCounts[@(address)], @1);
  });

  NSData *archived2 = [NSKeyedArchiver edo_archivedDataWithObject:countedRequest];
  EDOObjectReleaseRequest *decoded2 = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archived2];
  EDOObjectReleaseRequest.requestHandler(decoded2, service);

  [self waitForExpectations:@[ deallocExpectation ] timeout:5.0];
  XCTAssertNil(weakTarget);
  dispatch_sync(service.localObjectsSyncQueue, ^{
    XCTAssertNil(service.localObjects[@(address)]);
    XCTAssertNil(service.localObjectsCounts[@(address)]);
  });
}

/**
 * Verifies vending @c rootLocalObject stays uncounted, never encodes @c edoCountedByHost, and
 * survives release requests.
 *
 */
- (void)testRootObjectVendIsUncountedAndSurvivesRelease {
  EDOTestDummy *root = [[EDOTestDummy alloc] initWithValue:123];
  __weak EDOTestDummy *weakRoot = root;
  dispatch_queue_t queue =
      dispatch_queue_create("com.google.edo.service.rootTest", DISPATCH_QUEUE_SERIAL);
  EDOHostService *service = [EDOHostService serviceWithPort:0 rootObject:root queue:queue];
  [self addTeardownBlock:^{
    (void)queue;
    (void)root;
    [service invalidate];
  }];

  EDOObject *vendedRoot = [service distantObjectForLocalObject:root hostPort:service.port.hostPort];
  EDOPointerType rootAddress = vendedRoot.remoteAddress;
  dispatch_sync(service.localObjectsSyncQueue, ^{
    XCTAssertNil(service.localObjects[@(rootAddress)]);
    XCTAssertNil(service.localObjectsCounts[@(rootAddress)]);
  });

  NSData *rootArchive = [self edo_archiveProxy:vendedRoot
                               withProcessUUID:@"com.google.edotest.remoteRoot"];
  @autoreleasepool {
    EDOObject *decodedRoot = [NSKeyedUnarchiver edo_unarchiveObjectWithData:rootArchive];
    XCTAssertFalse(decodedRoot.countedByHost);
  }
  XCTAssertFalse([service releaseObjectWithAddress:rootAddress]);
  XCTAssertFalse([service removeObjectWithAddress:rootAddress]);
  XCTAssertNotNil(weakRoot);
  [EDOChannelPool.sharedChannelPool removeChannelsWithPort:service.port.hostPort];
}

/**
 * Concurrent stress test with two host services on separate queues vending objects and executing
 * counted releases in parallel.
 *
 * @note The lost-update race on host refcounts only manifests reliably under ThreadSanitizer
 *       (@c ServiceUnitTests_sim --features=tsan).
 *
 */
- (void)testConcurrentVendAndCountedReleaseMaintainsExactCount {
  EDOHostService *serviceA = [self edo_hostServiceWithName:@"com.google.edo.service.concurrentA"];
  EDOHostService *serviceB = [self edo_hostServiceWithName:@"com.google.edo.service.concurrentB"];
  NSArray<EDOHostService *> *services = @[ serviceA, serviceB ];
  const NSInteger kIterationsPerService = 40;

  XCTestExpectation *deallocA = [self expectationWithDescription:@"serviceA target deallocated"];
  XCTestExpectation *deallocB = [self expectationWithDescription:@"serviceB target deallocated"];
  dispatch_queue_t workerQueue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  dispatch_group_t group = dispatch_group_create();
  __block EDOPointerType addressA = 0;
  __block EDOPointerType addressB = 0;
  __weak EDOTestDummy *weakTargetA = nil;
  __weak EDOTestDummy *weakTargetB = nil;

  @autoreleasepool {
    EDOTestDummy *targetA = [[EDOTestDummy alloc] initWithValue:1];
    EDOTestDummy *targetB = [[EDOTestDummy alloc] initWithValue:2];
    weakTargetA = targetA;
    weakTargetB = targetB;
    EDODeallocSentinel *sentinelA = [[EDODeallocSentinel alloc] initWithBlock:^{
      [deallocA fulfill];
    }];
    EDODeallocSentinel *sentinelB = [[EDODeallocSentinel alloc] initWithBlock:^{
      [deallocB fulfill];
    }];
    objc_setAssociatedObject(targetA, &kDeallocSentinelKey, sentinelA,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(targetB, &kDeallocSentinelKey, sentinelB,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray<EDOTestDummy *> *targets = @[ targetA, targetB ];
    addressA = (EDOPointerType)(__bridge void *)targetA;
    addressB = (EDOPointerType)(__bridge void *)targetB;

    for (NSUInteger idx = 0; idx < services.count; idx++) {
      EDOHostService *service = services[idx];
      EDOTestDummy *target = targets[idx];
      for (NSInteger iter = 0; iter < kIterationsPerService; iter++) {
        dispatch_group_async(group, workerQueue, ^{
          @autoreleasepool {
            EDOObject *vended = [service distantObjectForLocalObject:target
                                                            hostPort:service.port.hostPort];
            NSString *uuid = [NSString stringWithFormat:@"com.google.edotest.worker.%lu.%ld",
                                                        (unsigned long)idx, (long)iter];
            NSData *archive = [self edo_archiveProxy:vended withProcessUUID:uuid];
            @autoreleasepool {
              EDOObject *remoteProxy = [NSKeyedUnarchiver edo_unarchiveObjectWithData:archive];
              XCTAssertTrue(remoteProxy.countedByHost);
              (void)remoteProxy;
            }
          }
        });
      }
    }
  }

  XCTAssertEqual(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)),
                 0);
  [self waitForExpectations:@[ deallocA, deallocB ] timeout:10.0];
  XCTAssertNil(weakTargetA);
  XCTAssertNil(weakTargetB);

  dispatch_sync(serviceA.localObjectsSyncQueue, ^{
    XCTAssertNil(serviceA.localObjects[@(addressA)]);
    XCTAssertNil(serviceA.localObjectsCounts[@(addressA)]);
  });
  dispatch_sync(serviceB.localObjectsSyncQueue, ^{
    XCTAssertNil(serviceB.localObjects[@(addressB)]);
    XCTAssertNil(serviceB.localObjectsCounts[@(addressB)]);
  });
  [EDOChannelPool.sharedChannelPool removeChannelsWithPort:serviceA.port.hostPort];
  [EDOChannelPool.sharedChannelPool removeChannelsWithPort:serviceB.port.hostPort];
}

/**
 * Verifies @c EDOObjectReleaseRequest returns its channel to @c EDOChannelPool only inside the
 * @c sendData:withCompletionHandler: completion block and drops channels that fail to write.
 */
- (void)testReleaseRequestPoolsChannelOnlyAfterWriteSuccess {
  EDOHostPort *successPort = [EDOHostPort hostPortWithLocalPort:65432
                                                    serviceName:@"com.google.edo.test.poolOk"];
  EDOHostPort *errorPort = [EDOHostPort hostPortWithLocalPort:65433
                                                  serviceName:@"com.google.edo.test.poolErr"];
  EDOChannelPool *pool = EDOChannelPool.sharedChannelPool;
  [pool removeChannelsWithPort:successPort];
  [pool removeChannelsWithPort:errorPort];

  EDOTestFakeChannel *successChannel = [[EDOTestFakeChannel alloc] init];
  EDOTestFakeChannel *errorChannel = [[EDOTestFakeChannel alloc] init];
  id poolMock = OCMPartialMock(pool);
  OCMStub([poolMock channelWithPort:successPort
                    connectionQueue:OCMOCK_ANY
                              error:[OCMArg anyObjectRef]])
      .andReturn(successChannel);
  OCMStub([poolMock channelWithPort:errorPort
                    connectionQueue:OCMOCK_ANY
                              error:[OCMArg anyObjectRef]])
      .andReturn(errorChannel);

  @try {
    EDOObjectReleaseRequest *successRequest =
        [EDOObjectReleaseRequest requestWithCountedRemoteAddress:1001];
    XCTAssertNil([EDOClientService sendSynchronousRequest:successRequest onPort:successPort]);
    XCTAssertNotNil(successChannel.sentData);
    XCTAssertNotNil(successChannel.sentHandler);
    // Must not return channel to the pool synchronously before sendData: completes.
    XCTAssertEqual([pool countChannelsWithPort:successPort], 0U);
    successChannel.sentHandler(successChannel, nil);
    XCTAssertEqual([pool countChannelsWithPort:successPort], 1U);

    EDOObjectReleaseRequest *errorRequest =
        [EDOObjectReleaseRequest requestWithCountedRemoteAddress:1002];
    XCTAssertNil([EDOClientService sendSynchronousRequest:errorRequest onPort:errorPort]);
    XCTAssertNotNil(errorChannel.sentData);
    XCTAssertNotNil(errorChannel.sentHandler);
    NSError *writeError = [NSError errorWithDomain:@"com.google.edo.test" code:1 userInfo:nil];
    errorChannel.sentHandler(errorChannel, writeError);
    XCTAssertEqual([pool countChannelsWithPort:errorPort], 0U);
  } @finally {
    OCMStopMocking(poolMock);
    [pool removeChannelsWithPort:successPort];
    [pool removeChannelsWithPort:errorPort];
  }
}

/**
 * Verifies concurrent @c cachedEDOFromObjectUpdateIfNeeded: lookups on counted proxies resolve to
 * one cached winner without marking duplicates local, balancing all host vends on release.
 */
- (void)testConcurrentCountedProxyCacheLookupPreservesCountUntilWinnerDealloc {
  for (NSNumber *isBlockValue in @[ @NO, @YES ]) {
    BOOL isBlock = isBlockValue.boolValue;
    EDOHostService *service =
        [self edo_hostServiceWithName:
                  [NSString stringWithFormat:@"com.google.edo.service.concurrentCountedCache.%d",
                                             isBlock]];
    XCTestExpectation *deallocExpectation = [self expectationWithDescription:@"target deallocated"];
    __weak id weakTarget = nil;
    __block EDOPointerType address = 0;
    const size_t kWorkerCount = 8;

    @autoreleasepool {
      NSMutableArray<NSData *> *archives = [NSMutableArray arrayWithCapacity:kWorkerCount];
      @autoreleasepool {
        id target;
        if (isBlock) {
          EDOTestDummy *capturedDummy = [[EDOTestDummy alloc] initWithValue:99];
          target = (id)[^int {
            return capturedDummy.value;
          } copy];
        } else {
          target = [[EDOTestDummy alloc] initWithValue:99];
        }
        weakTarget = target;
        EDODeallocSentinel *sentinel = [[EDODeallocSentinel alloc] initWithBlock:^{
          [deallocExpectation fulfill];
        }];
        objc_setAssociatedObject(target, &kDeallocSentinelKey, sentinel,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (size_t i = 0; i < kWorkerCount; ++i) {
          EDOObject *vended = [service distantObjectForLocalObject:target
                                                          hostPort:service.port.hostPort];
          address = vended.remoteAddress;
          NSString *uuid = [NSString stringWithFormat:@"com.google.edotest.cache.%zu", i];
          [archives addObject:[self edo_archiveProxy:vended withProcessUUID:uuid]];
        }
      }

      dispatch_queue_t concurrentQueue = dispatch_queue_create(
          "com.google.edo.test.countedCacheConcurrent", DISPATCH_QUEUE_CONCURRENT);
      NSMutableArray<id> *proxies = [NSMutableArray arrayWithCapacity:kWorkerCount];
      NSMutableArray<id> *results = [NSMutableArray arrayWithCapacity:kWorkerCount];
      for (size_t i = 0; i < kWorkerCount; ++i) {
        [proxies addObject:[NSKeyedUnarchiver edo_unarchiveObjectWithData:archives[i]]];
        [results addObject:[NSNull null]];
      }

      dispatch_apply(kWorkerCount, concurrentQueue, ^(size_t idx) {
        @autoreleasepool {
          id resolved = [EDOClientService cachedEDOFromObjectUpdateIfNeeded:proxies[idx]];
          @synchronized(results) {
            results[idx] = resolved;
          }
        }
      });

      id winner = results[0];
      XCTAssertNotEqual(winner, (id)[NSNull null]);
      for (size_t i = 0; i < kWorkerCount; ++i) {
        XCTAssertEqual(results[i], winner);
        EDOObject *distantObject = [self edo_distantObjectFromProxy:proxies[i] isBlock:isBlock];
        XCTAssertTrue(distantObject.countedByHost);
        XCTAssertFalse(distantObject.isLocal);
      }
      // Exercise cached winner while still retained before dropping all references together.
      if (isBlock) {
        XCTAssertEqual(((int (^)(void))winner)(), 99);
      } else {
        XCTAssertEqual([(EDOTestDummy *)winner returnInt], 99);
      }
    }

    [self waitForExpectations:@[ deallocExpectation ] timeout:10.0];
    XCTAssertNil(weakTarget);
    dispatch_sync(service.localObjectsSyncQueue, ^{
      XCTAssertNil(service.localObjects[@(address)]);
      XCTAssertNil(service.localObjectsCounts[@(address)]);
    });
    XCTAssertNil([EDOClientService distantObjectReferenceForRemoteAddress:address]);
    [EDOChannelPool.sharedChannelPool removeChannelsWithPort:service.port.hostPort];
  }
}

#pragma mark - Helper methods

- (id)edo_testTargetForBlock:(BOOL)isBlock {
  id target;
  if (isBlock) {
    EDOTestDummy *capturedDummy = [[EDOTestDummy alloc] initWithValue:99];
    // Capture a heap object so -copy allocates a distinct __NSMallocBlock__ per call instead of
    // reusing a singleton __NSGlobalBlock__.
    target = (id)[^int {
      return capturedDummy.value;
    } copy];
  } else {
    target = [[EDOTestDummy alloc] initWithValue:17];
  }
  [self addTeardownBlock:^{
    // Keep target alive until teardown so remoteAddress cannot be reused.
    (void)target;
  }];
  return target;
}

- (EDOHostService *)edo_hostServiceWithName:(NSString *)name {
  EDOTestDummy *root = [[EDOTestDummy alloc] init];
  dispatch_queue_t queue = dispatch_queue_create(name.UTF8String, DISPATCH_QUEUE_SERIAL);
  EDOHostService *service = [EDOHostService serviceWithPort:0 rootObject:root queue:queue];
  [self addTeardownBlock:^{
    // Keep root and weak _executionQueue alive until teardown.
    (void)queue;
    (void)root;
    [service invalidate];
  }];
  return service;
}

- (EDOPointerType)edo_createArchivesForBlock:(BOOL)isBlock
                                    archiveA:(NSData **)archiveA
                                    archiveB:(NSData *_Nullable *_Nullable)archiveB {
  EDOHostService *serviceA = [self edo_hostServiceWithName:@"com.google.edo.service.cacheTestA"];
  id target = [self edo_testTargetForBlock:isBlock];
  NSData *resultA = nil;
  NSData *resultB = nil;
  EDOPointerType sharedAddress = 0;
  @autoreleasepool {
    EDOObject *vendedA = [serviceA distantObjectForLocalObject:target
                                                      hostPort:serviceA.port.hostPort];
    sharedAddress = vendedA.remoteAddress;
    resultA = [self edo_archiveProxy:vendedA withProcessUUID:@"com.google.edotest.remoteA"];
    if (archiveB != NULL) {
      EDOHostService *serviceB =
          [self edo_hostServiceWithName:@"com.google.edo.service.cacheTestB"];
      EDOObject *vendedB = [serviceB distantObjectForLocalObject:target
                                                        hostPort:serviceB.port.hostPort];
      XCTAssertEqual(vendedA.remoteAddress, vendedB.remoteAddress);
      resultB = [self edo_archiveProxy:vendedB withProcessUUID:@"com.google.edotest.remoteB"];
    }
  }
  *archiveA = resultA;
  if (archiveB != NULL) {
    *archiveB = resultB;
  }
  return sharedAddress;
}

- (EDOObject *)edo_distantObjectFromProxy:(id)proxy isBlock:(BOOL)isBlock {
  if (isBlock) {
    EDOBlockObject *blockObject = [EDOBlockObject EDOBlockObjectFromBlock:proxy];
    XCTAssertNotNil(blockObject);
    return blockObject;
  }
  XCTAssertEqual(object_getClass(proxy), [EDOObject class]);
  return proxy;
}

// Patches _processUUID before archiving to simulate cross-process proxies without adding test-only
// mutators to production headers, then restores it so local vended objects stay local on dealloc.
- (NSData *)edo_archiveProxy:(EDOObject *)proxy withProcessUUID:(NSString *)processUUID {
  Ivar uuidIvar = class_getInstanceVariable([EDOObject class], "_processUUID");
  XCTAssertTrue(uuidIvar != NULL);
  id originalUUID = object_getIvar(proxy, uuidIvar);
  object_setIvar(proxy, uuidIvar, processUUID);
  NSData *archive = [NSKeyedArchiver edo_archivedDataWithObject:proxy];
  object_setIvar(proxy, uuidIvar, originalUUID);
  return archive;
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
                                                                 hostPort:service.port.hostPort
                                                            returnByValue:NO];
  return (EDOInvocationResponse *)EDOInvocationRequest.requestHandler(request, service);
}

- (NSString *)selectorSignature:(SEL)selector {
  Method method = class_getInstanceMethod([EDOTestDummy class], selector);
  NSMethodSignature *signature =
      [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
  NSMutableString *encoding = [NSMutableString stringWithUTF8String:signature.methodReturnType];
  for (NSUInteger i = 0; i < signature.numberOfArguments; ++i) {
    [encoding appendFormat:@"%s", [signature getArgumentTypeAtIndex:i]];
  }
  return encoding;
}

- (EDOBoxedValueType *)edo_intValue:(int)value {
  return [EDOBoxedValueType parameterWithBytes:&value objCType:@encode(int)];
}

- (EDOBoxedValueType *)edo_numberValue:(NSNumber *)value {
  return [EDOBoxedValueType parameterWithBytes:&value objCType:@encode(NSNumber *)];
}

@end
