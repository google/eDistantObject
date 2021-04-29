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
import SwiftUtil
@objc
public class EDOTestSwiftClass: NSObject, EDOTestSwiftProtocol {
  public func returnString() -> NSString {
    return "Swift String"
  }

  public func returnWithBlock(block: @escaping (NSString) -> EDOTestSwiftProtocol) -> NSString {
    return block("Block").returnString().appending("Block") as NSString
  }

  public func returnWithDictionarySum(data: NSDictionary) -> Int {
    var sum = 0
    for key in data.allKeys {
      sum += (data.object(forKey: key) as! NSNumber).intValue
    }
    return sum
  }

  public func returnSwiftArray() -> [AnyObject] {
    return [NSObject.init(), NSObject.init()]
  }

  public func sumFrom(structValue: EDOTestSwiftStruct) -> [Int] {
    return [structValue.intValues.reduce(0) { $0 + $1 }]
  }

  public func sumFrom(codedStruct: CodableVariable) throws -> CodableVariable {
    let structValue = try codedStruct.unwrap(EDOTestSwiftStruct.self)
    return self.sumFrom(structValue: structValue).eDOCodableVariable
  }
}

extension EDOTestDummy: EDOTestDummyExtension {
  open func returnProtocol() -> EDOTestSwiftProtocol {
    return EDOTestSwiftClass()
  }
}
