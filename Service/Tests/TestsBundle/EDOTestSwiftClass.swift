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

  public func returnSwiftAnyObjectArray() -> [AnyObject] {
    return [NSObject(), NSObject()]
  }

  public func returnSwiftArray() -> [NSObject] {
    return [NSObject(), NSObject()]
  }

  public func sumFrom(structValue: EDOTestSwiftStruct) -> [Int] {
    return [structValue.intValues.reduce(0) { $0 + $1 }]
  }

  public func sumFrom(codedStruct: CodableVariable) throws -> CodableVariable {
    let structValue: EDOTestSwiftStruct = try codedStruct.unwrap()
    return self.sumFrom(structValue: structValue).eDOCodableVariable
  }

  public func propagateError(withCustomizedDescription isCustomized: Bool) throws {
    if isCustomized {
      throw EDOCustomizedTestError.intentionalError
    } else {
      throw EDOTestError.intentionalError
    }
  }
}

extension EDOTestDummy: EDOTestDummyExtension {
  open func returnProtocol() -> EDOTestSwiftProtocol {
    return EDOTestSwiftClass()
  }
}
