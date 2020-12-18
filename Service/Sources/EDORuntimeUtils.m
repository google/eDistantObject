#import "Service/Sources/EDORuntimeUtils.h"

#import <objc/runtime.h>

NSMethodSignature *EDOGetMethodSignature(id target, SEL sel) {
  // eDO uses the last object of the -forwardingTargetForSelector: chain to perform
  // -methodSignatureForSelector:.
  id forwardedObject = target;
  Class klass = object_getClass(forwardedObject);
  Method method = sel ? class_getInstanceMethod(klass, sel) : nil;
  id nextForwardedObject = [forwardedObject forwardingTargetForSelector:sel];
  while (method == nil && nextForwardedObject != nil) {
    forwardedObject = nextForwardedObject;
    klass = object_getClass(forwardedObject);
    method = sel ? class_getInstanceMethod(klass, sel) : nil;
    nextForwardedObject = [forwardedObject forwardingTargetForSelector:sel];
  }

  if (method) {
    return [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
  } else {
    return [forwardedObject methodSignatureForSelector:sel];
  }
}
