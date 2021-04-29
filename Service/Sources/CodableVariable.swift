import Foundation

/// CodableVariable wraps a `Codable` instance to make it compatible with @objc methods.
///
/// `Codable` documentation: https://developer.apple.com/documentation/swift/codable
///
/// The Swift compiler doesn't allow developers to declare an @objc method for eDO as below:
///
///   ```
///   @objc public FooClass : NSObject {
///     @objc public func callBar(value: Int?) // Compile Error!
///   }
///   ```
///
/// The same issue also applies to other auto-synthesized Codable types, including classes, structs
/// and enums (Swift 5.5+). This is because Optional<Int> is a pure Swift type that cannot be
/// represented in Objective-C land. As a workaround, developers can declare a new method in the
/// class extension as below:
///
///   ```
///   extension FooClass {
///     @objc public func callBar(codedValue: CodableVariable) throws {
///       self.callBar(value: try codedValue.unwrap(Int?.self))
///     }
///   }
///   ```
///
/// The new method is compatible with @objc and forwards the coded variables to the original method.
/// So developers can use the new method in the remote call:
///
///   ```
///   var value : Int?
///   // Do something...
///   try remoteFooInstance.callBar(codedValue: try CodableVariable.wrap(value))
///   ```
@objc(EDOCodableVariable)
public class CodableVariable: NSObject, NSSecureCoding, Codable {

  /// Error thrown by `CodableVariable` during the decoding.
  public enum DecodingError: Error, LocalizedError {
    /// The type of encoded data doesn't match the caller's expecting type.
    /// - expectedType: The type expected by the decoding method caller.
    /// - actualType: The type of the encoded data.
    case typeUnmatched(expectedType: String, actualType: String)

    public var errorDescription: String? {
      switch self {
      case let .typeUnmatched(expectedType, actualType):
        return "Expecting to decode \(expectedType) but the codable variable is \(actualType)."
      }
    }
  }

  internal static let typeKey = "EDOTypeKey"
  internal let data: Data
  internal let type: String

  /// Creates `CodableVariable` instance with a `Codable` instance.
  ///
  /// - Parameter parameter: The Codable instance to be wrapped.
  /// - Returns: A `CodableVariable` instance.
  /// - Throws: Errors propagated from JSONEncoder when encoding `parameter`.
  public static func wrap<T: Encodable>(_ parameter: T) throws -> CodableVariable {
    let encoder = JSONEncoder()
    return CodableVariable(data: try encoder.encode(parameter), type: String(describing: T.self))
  }

  internal init(data: Data, type: String) {
    self.data = data
    self.type = type
  }

  /// Decodes the Codable instance.
  ///
  /// - Parameter type: The expected type of the decoded instance.
  /// - Returns: The decoded instance of `type`.
  /// - Throws: `CodableVariable.DecodingError` if decoding fails.
  public func unwrap<T: Decodable>(_ type: T.Type) throws -> T {
    guard self.type == String(describing: type) else {
      throw DecodingError.typeUnmatched(
        expectedType: self.type,
        actualType: String(describing: type))
    }
    let decoder = JSONDecoder()
    return try decoder.decode(T.self, from: data)
  }

  // MARK - NSSecureCoding

  public required init?(coder: NSCoder) {
    guard let data = coder.decodeData(),
      let type = coder.decodeObject(forKey: CodableVariable.typeKey) as? String
    else {
      return nil
    }
    self.data = data
    self.type = type
  }

  public func encode(with coder: NSCoder) {
    coder.encode(data)
    coder.encode(type, forKey: CodableVariable.typeKey)
  }

  @objc public var edo_isEDOValueType: Bool { return true }

  @objc public static var supportsSecureCoding: Bool { return true }
}

/// Extends Encodable to easily produce `CodableVariable` from the instance.
extension Encodable {
  /// Produces a `CodableVariable` instance from `self`.
  public var eDOCodableVariable: CodableVariable {
    // try! is used here because`CodableVariable.wrap` only throws programmer errors when
    // JSONEncoder fails to encode a `Encodable` type.
    return try! CodableVariable.wrap(self)
  }
}
