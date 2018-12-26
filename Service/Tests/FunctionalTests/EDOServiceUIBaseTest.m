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

#import "Service/Tests/FunctionalTests/EDOServiceUIBaseTest.h"

#import "Channel/Sources/EDOChannelPool.h"
#import "Channel/Sources/EDOHostPort.h"
#import "Service/Sources/EDOClientService.h"
#import "Service/Sources/EDOClientServiceStatsCollector.h"
#import "Service/Tests/TestsBundle/EDOTestDummy.h"

@implementation EDOServiceUIBaseTest

+ (void)setUp {
  [EDOClientServiceStatsCollector.sharedServiceStats start];
}

+ (void)tearDown {
  [EDOClientServiceStatsCollector.sharedServiceStats complete];
  NSLog(@"%@", EDOClientServiceStatsCollector.sharedServiceStats);
}

- (void)tearDown {
  // Reset the channel pool generated internally by EDOClientService.
  [EDOChannelPool.sharedChannelPool
      removeChannelsWithPort:[EDOHostPort hostPortWithLocalPort:EDOTEST_APP_SERVICE_PORT]];

  [super tearDown];
}

- (XCUIApplication *)launchApplicationWithPort:(int)port initValue:(int)value {
  XCUIApplication *app = [[XCUIApplication alloc] init];
  app.launchArguments = @[
    @"-servicePort", [NSString stringWithFormat:@"%d", port], @"-dummyInitValue",
    [NSString stringWithFormat:@"%d", value]
  ];
  [app launch];
  return app;
}

- (XCUIApplication *)launchApplicationWithServiceName:(NSString *)serviceName initValue:(int)value {
  XCUIApplication *app = [[XCUIApplication alloc] init];
  app.launchArguments = @[
    @"-serviceName", serviceName, @"-dummyInitValue", [NSString stringWithFormat:@"%d", value]
  ];
  [app launch];
  return app;
}

- (EDOTestDummy *)remoteRootObject {
  return [EDOClientService rootObjectWithPort:EDOTEST_APP_SERVICE_PORT];
}

@end
