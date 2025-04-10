import XCTest
import SwiftUtil

struct EDOTestingStruct: Codable {
  var intValue: Int
  var stringValue: String
  var floatValue: Float
}

final class CodableVariableTests: XCTestCase {

  /// Verifies CodableVariable can wrap/unwrap structs that conforms Codable.
  func testSerializeStruct() throws {
    let structValue = EDOTestingStruct(intValue: 0, stringValue: "foo", floatValue: -1.0)
    let serialized = structValue.eDOCodableVariable
    let deserialized: EDOTestingStruct = try serialized.unwrap()
    XCTAssertEqual(deserialized.intValue, structValue.intValue)
    XCTAssertEqual(deserialized.stringValue, structValue.stringValue)
    XCTAssertEqual(deserialized.floatValue, structValue.floatValue)
  }

  /// Verifies CodableVariable will return nil when deserializing with optional try.
  func testOptionallyDeserializingStructReturnsNil() {
    let structValue = EDOTestingStruct(intValue: 0, stringValue: "foo", floatValue: -1.0)
    let serialized = structValue.eDOCodableVariable
    let deserialized: EDOTestingStruct? = try? serialized.unwrap()
    XCTAssertNil(deserialized)
  }

  /// Verifies CodableVariable can wrap/unwrap optional primitive types.
  func testSerializeOptionalPrimitive() throws {
    guard #available(iOS 13.0, *) else {
      throw XCTSkip("Optional is available for encoding after iOS 13")
    }
    let optionalValue: Int? = nil
    let serialized = optionalValue.eDOCodableVariable
    let deserialized: Int? = try serialized.unwrap()
    XCTAssertNil(deserialized)
  }

  /// Verifies CodableVariable throws exceptions when decoding expects a wrong type.
  func testThrowErrorWhenTypeMismatch() {
    let structValue = EDOTestingStruct(intValue: 0, stringValue: "foo", floatValue: -1.0)
    let serialized = structValue.eDOCodableVariable
    var thrownError: Error?
    XCTAssertThrowsError(try serialized.unwrap() as Int?) {
      thrownError = $0
    }
    let expectedError =
      CodableVariable.DecodingError.typeUnmatched(
        expectedType: "EDOTestingStruct",
        actualType: "Optional<Int>")
    XCTAssertEqual(thrownError?.localizedDescription, expectedError.localizedDescription)
  }

}
