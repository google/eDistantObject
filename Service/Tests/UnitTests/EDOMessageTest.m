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
#import "Service/Sources/EDOParameter.h"  // IWYU pragma: keep
#import "Service/Sources/EDORemoteException.h"
#import "Service/Sources/EDOServicePort.h"
#import "Service/Sources/NSKeyedArchiver+EDOAdditions.h"
#import "Service/Sources/NSKeyedUnarchiver+EDOAdditions.h"

#import "Service/Tests/TestsBundle/EDOTestDummy.h"

static const char kDeallocSentinelKey = '\0';
static const char kIsProxyHookKey = '\0';

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
    EDOObject *vended = [service distantObjectForLocalObject:transient
                                                    hostPort:service.port.hostPort];
    address = vended.remoteAddress;
    archive = [self edo_archiveProxy:vended withProcessUUID:@"com.google.edotest.remote"];
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

      // Same-port duplicate hit must unwrap localEDO and mark duplicate local.
      XCTAssertEqual([EDOClientService cachedEDOFromObjectUpdateIfNeeded:proxyA2], proxyA1);
      XCTAssertTrue(edoA2.isLocal);

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
    NSData *archiveA = nil;
    EDOPointerType sharedAddress = [self edo_createArchivesForBlock:isBlock
                                                           archiveA:&archiveA
                                                           archiveB:NULL];
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
      }
      XCTAssertNil([EDOClientService distantObjectReferenceForRemoteAddress:sharedAddress]);
    }
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
