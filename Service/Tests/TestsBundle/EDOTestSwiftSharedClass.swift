import Foundation
import SwiftUtil
@objcMembers
public class EDOTestSwiftSharedClass: NSObject {
  let value: Int

  public dynamic required init(initialValue: Int) {
    value = initialValue
    super.init()
  }

  public dynamic func returnInt() -> Int {
    return value
  }

  public dynamic func returnString() -> String {
    return "String from dynamic function"
  }

  public dynamic func returnInstance() -> EDOTestSwiftSharedClass {
    return EDOTestSwiftSharedClass(initialValue: value + 1)
  }

  public dynamic func sum(from codableValue: CodableVariable) throws -> CodableVariable {
    let structValue: EDOTestSwiftStruct = try! codableValue.unwrap()
    return self.sum(from: structValue).eDOCodableVariable
  }

  public func sum(from structValue: EDOTestSwiftStruct) -> Int {
    return structValue.intValues.reduce(0) { $0 + $1 }
  }
}
