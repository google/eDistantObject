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

#import "Channel/Sources/EDOHostPort.h"

@interface EDOHostPortTest : XCTestCase

@end

@implementation EDOHostPortTest

- (void)testHostPortEquality {
  EDOHostPort *port1 = [EDOHostPort hostPortWithLocalPort:1];
  XCTAssertEqualObjects(port1, port1);
  EDOHostPort *port2 = [EDOHostPort hostPortWithLocalPort:1];
  XCTAssertEqualObjects(port1, port2);

  EDOHostPort *port3 = [EDOHostPort hostPortWithLocalPort:2];
  XCTAssertNotEqualObjects(port1, port3);
  EDOHostPort *port4 = [EDOHostPort hostPortWithDevicePort:1 deviceSerialNumber:@"test_serial"];
  XCTAssertNotEqualObjects(port1, port4);

  EDOHostPort *port5 = [EDOHostPort hostPortWithName:@"test_name"];
  EDOHostPort *port6 = [EDOHostPort hostPortWithLocalPort:1];
  XCTAssertNotEqualObjects(port5, port6);

  NSObject *object = [[NSObject alloc] init];
  XCTAssertNotEqualObjects(port1, object);
}

- (void)testHostPortHash {
  EDOHostPort *port1 = [EDOHostPort hostPortWithLocalPort:1];
  EDOHostPort *port2 = [EDOHostPort hostPortWithLocalPort:1];
  XCTAssertEqual([port1 hash], [port2 hash]);

  EDOHostPort *port3 = [EDOHostPort hostPortWithName:@"test_name"];
  EDOHostPort *port4 = [EDOHostPort hostPortWithName:@"test_name"];
  XCTAssertEqual([port3 hash], [port4 hash]);
}

- (void)testHostPortCopy {
  EDOHostPort *port1 = [EDOHostPort hostPortWithDevicePort:1 deviceSerialNumber:@"test_serial"];
  EDOHostPort *port2 = [port1 copy];
  XCTAssertEqual(port1.port, port2.port);
  XCTAssertEqualObjects(port1.deviceSerialNumber, port2.deviceSerialNumber);
}

- (void)testHostPortAsDictionaryKey {
  EDOHostPort *port1 = [EDOHostPort hostPortWithLocalPort:1];
  EDOHostPort *port2 = [EDOHostPort hostPortWithName:@"test_name"];
  EDOHostPort *port3 = [EDOHostPort hostPortWithDevicePort:1 deviceSerialNumber:@"test_serial"];
  NSMutableDictionary *dict = [[NSMutableDictionary alloc]
      initWithObjectsAndKeys:@"1", port1, @"2", port2, @"3", port3, nil];
  XCTAssertEqual(dict.count, (NSUInteger)3);
  EDOHostPort *port4 = [EDOHostPort hostPortWithLocalPort:1];
  [dict setObject:@"4" forKey:port4];
  XCTAssertEqualObjects([dict objectForKey:port1], @"4");
}

@end
