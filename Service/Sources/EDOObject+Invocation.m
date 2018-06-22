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

#import "Service/Sources/EDOClientService+Private.h"
#import "Service/Sources/EDOHostService+Private.h"
#import "Service/Sources/EDOInvocationMessage.h"
#import "Service/Sources/EDOMethodSignatureMessage.h"
#import "Service/Sources/EDOObject+Private.h"
#import "Service/Sources/EDOParameter.h"
#import "Service/Sources/EDOServicePort.h"

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
  EDOMethodSignatureResponse *response =
      (EDOMethodSignatureResponse *)[EDOClientService sendRequest:request
                                                             port:self.servicePort.port];
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
  EDOInvocationRequest *request = [EDOInvocationRequest requestWithTarget:self
                                                                 selector:selector
                                                               invocation:invocation
                                                            returnByValue:returnByValue];
  EDOInvocationResponse *response =
      (EDOInvocationResponse *)[EDOClientService sendRequest:request port:self.servicePort.port];

  if (response.exception) {
    // Populate the exception.
    // Note: we throw here rather than -[raise] because we can't make an assumption of what user's
    //       code will throw.
    @throw response.exception;  // NOLINT
  }

  NSUInteger returnBufSize = invocation.methodSignature.methodReturnLength;
  EDOHostService *service = EDOHostService.currentService;

  char const *ctype = invocation.methodSignature.methodReturnType;
  if (EDO_IS_OBJECT_OR_CLASS(ctype)) {
    id __unsafe_unretained obj;
    [response.returnValue getValue:&obj];
    obj = [service unwrappedObjectFromObject:obj] ?: obj;
    obj = [EDOClientService cachedEDOFromObjectUpdateIfNeeded:obj];
    [invocation setReturnValue:&obj];
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
        *obj = [service unwrappedObjectFromObject:*obj] ?: *obj;
        // When there is no running service or the object is a true remote object, we will check
        // the local distant objects cache.
        *obj = [EDOClientService cachedEDOFromObjectUpdateIfNeeded:*obj];
      }

      ++curOutIdx;
    }
  }
}

@end
