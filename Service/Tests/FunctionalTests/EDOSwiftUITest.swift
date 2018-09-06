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

import Foundation
import XCTest

class EDOSwiftUITest: XCTestCase {
  @discardableResult
  func launchAppWithPort(port : Int, value : Int) -> XCUIApplication {
    let application = XCUIApplication()
    application.launchArguments = [
      "-servicePort", String(format:"%d", port), String("-dummyInitValue"),
      String(format:"%d", value)]
    application.launch()
    return application
  }

  func testRemoteInvocation() {
    launchAppWithPort(port:1234, value:10)
    let service = EDOHostService(port:2234, rootObject:self, queue:DispatchQueue.main)

    let dummyClass = EDOTestClassDummy(value:20)
    let testDummy = unsafeBitCast(dummyClass, to: EDOTestSwiftProtocol.self)
    XCTAssertEqual(testDummy.returnString(), "Swift String")

    XCTAssertEqual(testDummy.returnWithBlock { (str : NSString) in
      XCTAssertEqual(str, "Block")
      return testDummy
    }, "Swift StringBlock")

    service.invalidate()
  }
}
