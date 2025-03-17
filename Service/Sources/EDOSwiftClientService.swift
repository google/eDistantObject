/// Fetches a remote class object from the app process.
///
/// The caller of this method should pass the local class object in its process as @c theClass.
/// eDO will map @c theClass to the appropriate class object in the remote process and return that.
///
/// - Parameters:
///   - aClass: The class object to fetch from the remote process.
///   - hostPort: The server port of the remote process.
///
/// - Returns: A class object, which is the same type as @c theClass in the remote process.
///            Invocations made to the returned Class object will be executed in the remote process.
///            If the remote process doesn't have such class, `nil` will be returned.
///
/// - Attention: Only methods that are marked `@objc dynamic` can be called. Swift compiler won't
///              prevent from calling other types of methods, but it will crash the current process.
public func remoteClassObject<T: NSObject>(of aClass: T.Type, on port: EDOHostPort) -> T.Type? {
  let className = NSStringFromClass(aClass)
  let classRequest = EDOClassRequest(className: className, hostPort: port)

  // The return type is intentionally `Any` instead of `AnyClass`. ARC and Swift treat `Class`
  // objects as immortal, which means there is no need for retain/release. However, the actual
  // object returned by this method is a proxy object that is not immortal. Therefore, use `Any` as
  // the return type to ensure the compiler retains/releases the object as usual. See this thread
  // for more details:
  // https://forums.swift.org/t/why-does-casting-type-metadata-to-anyobject-later-result-in-destroy-value-being-called-on-the-anyobject/66371/4
  let remoteClass = EDOClientService<AnyObject>.responseObject(with: classRequest, on: port)
  guard let remoteClass else {
    return nil
  }

  if !IsNativeObjCClass(T.self) {
    print(
      """
      EDO WARNING: '\(T.self)' is a Swift class from the remote process. Invoking methods not \
      marked `@objc dynamic` is unsupported and will lead to failures.
      """
    )
  }

  // The following cast is safe because `remoteClass` is `AnyObject`, which will be treated the same
  // as `T.Type` when the compiler generates code to call a class method.
  //
  // `T` is an Objective-C-compatible class, either defined in Swift or in Objective-C:
  //
  // * For an `@objc` Swift class, `T.Type` is a “class metadata record”. Class metadata records are
  // compatible with the Objective-C `Class` type, so the compiler passes a class metadata record
  // directly to `objc_msgSend`.
  // * For an Objective-C class, `T.Type` is an “Objective-C class wrapper metadata record”. The
  // compiler calls `swift_getObjCClassFromMetadata` to get the underlying Objective-C `Class`
  // object from the metadata record in order to pass it to `objc_msgSend`.
  //
  // One thing note is that `AnyObject` is compatible with `T.Type` in terms of calling class
  // methods, regardless of how `T` was defined:
  //
  // * If `T` is an `@objc` Swift class, the compiler passes the `AnyObject` value directly to
  //   `objc_msgSend`, which is the desired outcome.
  // * If `T` is an Objective-C class, the compiler passes the `AnyObject` value to
  //   `swift_getObjCClassFromMetadata`.
  //
  // Fortunately, `swift_getObjCClassFromMetadata` can handle all cases: Objective-C class wrapper
  // metadata records, class metadata records, and Objective-C `Class` objects. For the latter two,
  // the function returns the value as-is. Thus, the `AnyObject` value will be returned and then
  // passed to `objc_msgSend` as desired.
  return unsafeBitCast(remoteClass as AnyObject, to: T.Type.self)
}

// Whether the object is a class implemented in Objective-C (as opposed to a Swift class inheriting
// `NSObject`).
func IsNativeObjCClass(_ aClass: AnyClass) -> Bool {
  let metadataPointer = unsafeBitCast(aClass, to: UnsafePointer<TypeMetadata>.self)
  return metadataPointer.pointee.kind == MetadataKind.objCClassWrapper.rawValue
}

private enum MetadataKind: UInt {
  // Value taken from ABI.
  //
  // See: https://github.com/swiftlang/swift/blob/a184782a38406d2a04e717d0725f42d46258b422/include/swift/ABI/MetadataKind.def#L74
  case objCClassWrapper = 0x305
}

private struct TypeMetadata {
  // According to the ABI doc about TypeMetadata, the first pointer-sized
  // integer described the kind of the type.
  //
  // See: https://github.com/swiftlang/swift/blob/main/docs/ABI/TypeMetadata.rst#common-metadata-layout
  let kind: UInt
}
