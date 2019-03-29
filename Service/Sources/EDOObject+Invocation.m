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

#import "Service/Sources/EDOObject.h"

#import "Channel/Sources/EDOHostPort.h"
#import "Service/Sources/EDOClientService+Private.h"
#import "Service/Sources/EDOHostService+Private.h"
#import "Service/Sources/EDOInvocationMessage.h"
#import "Service/Sources/EDOMethodSignatureMessage.h"
#import "Service/Sources/EDOObject+Private.h"
#import "Service/Sources/EDOParameter.h"

/**
 *  The extension of EDOObject to handle the message forwarding.
 *
 *  When a method is not implemented, the objc runtime executes a sequence of events to recover
 *  before it sends doesNotRecognizeSelector: or raises an exception. It requests an
 *  NSMethodSignature using -/+methodSignatureForSelector:, which bundles with arguments types and
 *  return type information. And from there, it creates an NSInvocation object which captures the
 *  full message being sent, including the target, the selector and all the arguments. After this,
 *  the runtime invokes -/+forwardInvocation: method and here it serializes all the arguments and
 *  sends it across the wire; once it returns, it sets its return value back to the NSInvocation
 *  object. This allows us dynamically to turn a local invocation into a remote invocation.
 *
 */
@implementation EDOObject (Invocation)

/**
 *  Get an instance method signature for the @c EDOObject
 *
 *  This is called from the callee's thread and it is synchronous.
 *
 *  @param selector The selector.
 *
 *  @return         The instance method signature.
 */
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
  // TODO(haowoo): Cache the signature.
  EDOServiceRequest *request = [EDOMethodSignatureRequest requestWithObject:self.remoteAddress
                                                                       port:self.servicePort
                                                                   selector:selector];
  EDOMethodSignatureResponse *response = (EDOMethodSignatureResponse *)[EDOClientService
      sendSynchronousRequest:request
                      onPort:self.servicePort.hostPort];
  NSString *signature = response.signature;
  return signature ? [NSMethodSignature signatureWithObjCTypes:signature.UTF8String] : nil;
}

/** Forwards the invocation to the remote. */
- (void)forwardInvocation:(NSInvocation *)invocation {
  [self edo_forwardInvocation:invocation selector:invocation.selector returnByValue:NO];
}

- (void)edo_forwardInvocation:(NSInvocation *)invocation
                     selector:(SEL)selector
                returnByValue:(BOOL)returnByValue {
  // Keep the service until the end of the invocation scope so the nested remote call can be made
  // using this service.
  NS_VALID_UNTIL_END_OF_SCOPE EDOHostService *service = [EDOHostService serviceForCurrentQueue];

  // If there is no host service created for the current queue, a temporary queue is created only
  // within this invocation scope.
  if (!service) {
    service = [EDOHostService serviceWithPort:0 rootObject:nil queue:nil];
  }

  EDOInvocationRequest *request = [EDOInvocationRequest requestWithInvocation:invocation
                                                                       target:self
                                                                     selector:selector
                                                                returnByValue:returnByValue
                                                                      service:service];
  EDOInvocationResponse *response =
      (EDOInvocationResponse *)[EDOClientService sendSynchronousRequest:request
                                                                 onPort:self.servicePort.hostPort
                                                           withExecutor:service.executor];

  if (response.exception) {
    // Populate the exception.
    // Note: we throw here rather than -[raise] because we can't make an assumption of what user's
    //       code will throw.
    @throw response.exception;  // NOLINT
  }

  NSUInteger returnBufSize = invocation.methodSignature.methodReturnLength;
  char const *ctype = invocation.methodSignature.methodReturnType;
  if (EDO_IS_OBJECT_OR_CLASS(ctype)) {
    id __unsafe_unretained obj;
    [response.returnValue getValue:&obj];
    obj = [EDOClientService unwrappedObjectFromObject:obj];
    obj = [EDOClientService cachedEDOFromObjectUpdateIfNeeded:obj];
    [invocation setReturnValue:&obj];

    // ARC will insert a -release on the return if the method retains return, but because we build
    // the invocation dynamically, the return is not retained, we insert an extra retain here to
    // compensate ARC.
    if (response.returnRetained) {
      CFBridgingRetain(obj);
    }
  } else if (returnBufSize > 0) {
    char *const returnBuf = calloc(returnBufSize, sizeof(char));
    [response.returnValue getValue:returnBuf];
    [invocation setReturnValue:returnBuf];
    free(returnBuf);
  }

  NSArray<EDOBoxedValueType *> *outValues = response.outValues;
  if (outValues.count > 0) {
    NSMethodSignature *method = invocation.methodSignature;
    NSUInteger numOfArgs = method.numberOfArguments;
    for (NSUInteger curArgIdx = selector ? 2 : 1, curOutIdx = 0; curArgIdx < numOfArgs;
         ++curArgIdx) {
      char const *ctype = [method getArgumentTypeAtIndex:curArgIdx];
      if (!EDO_IS_OBJPOINTER(ctype)) {
        continue;
      }

      id __unsafe_unretained *obj;
      [invocation getArgument:&obj atIndex:curArgIdx];

      // Fill the out value back to its original buffer if provided.
      if (obj) {
        [outValues[curOutIdx] getValue:obj];
        *obj = [EDOClientService unwrappedObjectFromObject:*obj];
        // When there is no running service or the object is a true remote object, we will check
        // the local distant objects cache.
        *obj = [EDOClientService cachedEDOFromObjectUpdateIfNeeded:*obj];
      }

      ++curOutIdx;
    }
  }
}

@end
