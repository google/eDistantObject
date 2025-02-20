#import "Service/Sources/EDORuntimeUtils.h"

#import <objc/runtime.h>

NSMethodSignature *EDOGetMethodSignature(id target, SEL sel) {
  // eDO uses the last object of the -forwardingTargetForSelector: chain to perform
  // -methodSignatureForSelector:.
  id forwardedObject = target;
  id lastObjectInForwardingChain;
  do {
    Class klass = object_getClass(forwardedObject);
    Method method = sel ? class_getInstanceMethod(klass, sel) : nil;
    if (method) {
      return [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    }
    lastObjectInForwardingChain = forwardedObject;
  } while ((forwardedObject = [forwardedObject forwardingTargetForSelector:sel]));
  return [lastObjectInForwardingChain methodSignatureForSelector:sel];
}
