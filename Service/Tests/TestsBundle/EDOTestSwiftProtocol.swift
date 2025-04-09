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

public struct EDOTestSwiftStruct: Codable {
  public var intValues: [Int]

  public init(intValues: [Int]) {
    self.intValues = intValues
  }
}

public enum EDOTestError: Swift.Error {
  case intentionalError
}

public enum EDOCustomizedTestError: Swift.Error {
  case intentionalError
}

extension EDOCustomizedTestError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .intentionalError:
      return NSLocalizedString(
        "An override for EDOCustomizedTestError.intentionalError", comment: "EDOCustomizedTestError"
      )
    }
  }
}

@objc
public protocol EDOTestSwiftProtocol {
  func returnString() -> NSString
  func returnWithBlock(block: @escaping (NSString) -> EDOTestSwiftProtocol) -> NSString
  func returnWithDictionarySum(data: NSDictionary) -> Int
  func returnSwiftAnyObjectArray() -> [AnyObject]
  func returnSwiftArray() -> [NSObject]
  func sumFrom(codedStruct: CodableVariable) throws -> CodableVariable
  func propagateError(withCustomizedDescription isCustomized: Bool) throws
}

@objc
public protocol EDOTestDummyExtension {
  func returnProtocol() -> EDOTestSwiftProtocol
}
