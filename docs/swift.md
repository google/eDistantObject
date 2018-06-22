# Swift Support

eDistantObject supports Swift as Swift is fundamentally interoperable with
Objective-C. More details in [Apple doc around
MixAndMatch](https://developer.apple.com/library/content/documentation/Swift/Conceptual/BuildingCocoaApps/MixandMatch.html).
However, pure Swift calls are statically linked, therefore, invocations are not
through the Objective-C runtime. There are three different scenarios when
working with Swift.

## 1. Swift calling methods in Objective-C

This works naturally when importing Objective-C headers as Swift will invoke
those methods already in an Objective-C manner and trigger the runtime to
forward invocations. As is usual with Swift, these method definitions must be exposed in a bridging header.

## 2. Objective-C calling methods in Swift

The methods need to be annotated with `@objc` so that it can be exported to
Objective-C and is visible. Once the invocation is fired in Objective-C, it will
properly be forwarded to the remote site.

The above two scenarios should work as long as the methods are tagged with
@objc.

## 3. Swift calling methods in Swift

In the Objective-C case, the compiler needs to see the header in order to know how
to run your code. However, there is no header in Swift. The workaround is to
define a protocol, to serve as a header, and then expose the object to work
with as a protocol.

For example:

```swift
//  In Swift
@objc
public protocol RemoteInterface {
  func remoteFoo() -> Bar
}

@objc
public protocol StubbedClassExtension {
  func remoteInterface() -> RemoteInterface
}

class ActualImplementation : RemoteInterface {
  func remoteFoo() -> Bar {
    // Your actual implementation.
  }
}

@objc
extension AlreadyStubbedClass : StubbedClassExtension {
  // The client calling this method to require the remote object.
  func remoteInterface() -> RemoteInterface {
    // return the actual implementation of RemoteInterface
  }
}
```

```objectivec
// In Objective-C

// Define a Objective-C bridge so Swift can extend.
@interface AlreadyStubbedClass
@end
```

In the code above, `AlreadyStubbedClass` is defined in Objective-C and will be
imported as a regular eDistantObject in both Swift files. This will then be used
as an entry point to return the protocol `RemoteInterface`. The remote
invocation will be:

```swift
RemoteInterface remote = unsafeCast(AlreadyStubbedClass.sharedClass, to:StubbedClassExtension.self).remoteInstance
remote.remoteFoo()
```

Here the `unsafeCast` lets the compiler know the `AlreadyStubbedClass` has the
extension.
