//
// Copyright 2020 Google Inc.
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

#import "Service/Sources/EDOBlockObject.h"

#include <objc/message.h>
#include <objc/runtime.h>

#import "Service/Sources/EDOObject+Private.h"

@class EDOServicePort;

static NSString *const kEDOBlockObjectCoderSignatureKey = @"signature";
static NSString *const kEDOBlockObjectCoderHasStretKey = @"hasStret";

/**
 *  The block structure defined in ABI here:
 *  https://clang.llvm.org/docs/Block-ABI-Apple.html#id2
 */

struct EDOBlockHeader;

typedef void (*EDOBlockCopyHelperFunc)(struct EDOBlockHeader *dst, struct EDOBlockHeader *src);
typedef void (*EDOBlockDisposeHelperFunc)(struct EDOBlockHeader *src);

typedef struct EDOBlockDescriptor {
  unsigned long int reserved;
  unsigned long int size;
  union {
    struct {
      // Optional helper functions
      EDOBlockCopyHelperFunc copy_helper;        // IFF (flag & 1<<25)
      EDOBlockDisposeHelperFunc dispose_helper;  // IFF (flag & 1<<25)
      const char *signature;
    } helper;
    // Required ABI.2010.3.16
    const char *signature;  // IFF (flag & 1<<30)
  };
} EDOBlockDescriptor;

/** The enums for the block flag. */
typedef NS_ENUM(int, EDOBlockFlags) {
  EDOBlockFlagsHasCopyDispose = (1 << 25),  // If the block has copy and dispose function pointer.
  EDOBlockFlagsIsGlobal = (1 << 28),        // If the block is a global block.
  EDOBlockFlagsHasStret = (1 << 29),        // If we should use _stret calling convention.
  EDOBlockFlagsHasSignature = (1 << 30)     // If the signature is filled.
};

typedef struct {
  id __unsafe_unretained object;
  EDOBlockFlags original_flags;
  EDOBlockDescriptor *original_descriptor;
} EDOBlockCapturedVariables;

typedef struct EDOBlockHeader {
  void *isa;
  EDOBlockFlags flags;
  int reserved;
  void (*invoke)(void);  // The block implementation, which is either _objc_msgForward or
                         // _objc_msgForward_stret to trigger message forwarding.
  EDOBlockDescriptor *descriptor;
  EDOBlockCapturedVariables captured_variables;
} EDOBlockHeader;

typedef NS_ENUM(int, EDOBlockFieldDescriptors) {
  EDOBlockFieldIsObject = 3,  // id, NSObject, __attribute__((NSObject)), block, ...
};

/* Get @c NSBlock class. */
static Class GetBlockBaseClass() {
  static Class blockClass;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    blockClass = NSClassFromString(@"NSBlock");
    NSCAssert(blockClass, @"Couldn't load NSBlock class.");
  });
  return blockClass;
}

/** Check if the @c block has struct returns. */
static BOOL HasStructReturnForBlock(id block) {
  EDOBlockHeader *blockHeader = (__bridge EDOBlockHeader *)block;
  return (blockHeader->flags & EDOBlockFlagsHasStret) != 0;
}

@implementation EDOBlockObject

+ (BOOL)supportsSecureCoding {
  return YES;
}

+ (BOOL)isBlock:(id)object {
  if ([object isProxy]) {
    return NO;
  }

  // We use runtime primitive APIs to go through the class hierarchy in case any subclass to
  // override -[isKindOfClass:] and cause unintended behaviours, i.e. OCMock.
  Class blockClass = GetBlockBaseClass();
  Class objClass = object_getClass(object);
  while (objClass) {
    if (objClass == blockClass) {
      return YES;
    }
    objClass = class_getSuperclass(objClass);
  }
  return NO;
}

+ (EDOBlockObject *)EDOBlockObjectFromBlock:(id)block {
  EDOBlockHeader *header = (__bridge EDOBlockHeader *)block;
#if !defined(__arm64__)
  if (header->invoke == (void (*)(void))_objc_msgForward ||
      header->invoke == (void (*)(void))_objc_msgForward_stret) {
    return header->captured_variables.object;
  }
#else
  if (header->invoke == (void (*)(void))_objc_msgForward) {
    return header->captured_variables.object;
  }
#endif
  return nil;
}

+ (char const *)signatureFromBlock:(id)block {
  EDOBlockHeader *blockHeader = (__bridge EDOBlockHeader *)block;
  NSAssert(blockHeader->flags & EDOBlockFlagsHasSignature, @"The block doesn't have a signature.");
  if (blockHeader->flags & EDOBlockFlagsHasCopyDispose) {
    return blockHeader->descriptor->helper.signature;
  } else {
    return blockHeader->descriptor->signature;
  }
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super initWithCoder:aDecoder];
  if (self) {
    _signature = [aDecoder decodeObjectOfClass:[NSString class]
                                        forKey:kEDOBlockObjectCoderSignatureKey];
    _returnsStruct = [aDecoder decodeBoolForKey:kEDOBlockObjectCoderHasStretKey];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [super encodeWithCoder:aCoder];
  [aCoder encodeObject:self.signature forKey:kEDOBlockObjectCoderSignatureKey];
  [aCoder encodeBool:self.returnsStruct forKey:kEDOBlockObjectCoderHasStretKey];
}

// Dispose the returned descriptor using DisposeDescriptor.
static EDOBlockDescriptor *CreateDescriptorWithSignature(NSString *signature) {
  EDOBlockDescriptor *newDescriptor = (EDOBlockDescriptor *)calloc(1, sizeof(EDOBlockDescriptor));
  // Note that we only do dispose because our block should never have a copy handler.
  newDescriptor->helper.dispose_helper = EDOBlockDisposeHelper;
  newDescriptor->helper.signature = strdup([signature UTF8String]);
  return newDescriptor;
}

static void DisposeDescriptor(EDOBlockDescriptor *desc) {
  // Free up the memory that we allocated for the signature and our descriptor.
  free((void *)desc->helper.signature);
  free((void *)desc);
}

static void EDOBlockDisposeHelper(EDOBlockHeader *src) {
  // Dispose is only called once when the block is being released.
  // Dispose/Release our captured object.
  _Block_object_dispose((__bridge void *)src->captured_variables.object, EDOBlockFieldIsObject);

  // Free up the memory that we allocated for the descriptor.
  DisposeDescriptor(src->descriptor);

  // Reset the header back the way it was.
  src->descriptor = src->captured_variables.original_descriptor;
  src->flags = src->captured_variables.original_flags;

  // We don't need to call the previous dispose helper because we asserted that there wasn't one
  // when we created the block.
}

// When we decode it, we swap with the actual block object so the receiver can invoke on it.
- (id)awakeAfterUsingCoder:(NSCoder *)aDecoder {
  EDOBlockCapturedVariables vars = {nil, 0, NULL};
  void (^dummy)(void) = ^{
    // The printf is never called, it solely exists to capture vars to associate it with the block
    // so we get the proper amount of "variable" space in our block header.
    printf("%p", vars.original_descriptor);
  };

  // Move the block from the stack to the heap.
  id dummyOnHeap = [dummy copy];
  EDOBlockHeader *header = (__bridge EDOBlockHeader *)dummyOnHeap;

  // Verify that Apple hasn't added some fun optimizations that are copying our block in a
  // weird way.
  NSAssert(header->descriptor->size == sizeof(EDOBlockHeader), @"block wrong size");

  // Check to make sure that Apple hasn't added copy/dispose handlers to our blocks for some reason.
  // If they do, we will have to be careful to chain them in dispose.
  NSAssert((header->flags & EDOBlockFlagsHasCopyDispose) == 0, @"block has copy/dispose handlers");

  // Add a reference to "self" into the block.
  _Block_object_assign(&header->captured_variables.object, (__bridge void *)self,
                       EDOBlockFieldIsObject);

  // Record the original values from the header so we can restore them when we dispose the block.
  header->captured_variables.original_descriptor = header->descriptor;
  header->captured_variables.original_flags = header->flags;

  // Create up a new descriptor with our dispose and signature.
  // Note that we need to make a new descriptor because multiple blocks may be using the same
  // descriptor that the compiler generates for us, and modifying it directly can mess up other
  // blocks. We create our own, and then clean up all the memory in EDOBlockDisposeHelper.
  EDOBlockDescriptor *newDescriptor = CreateDescriptorWithSignature(self.signature);
  header->descriptor = newDescriptor;

  // Add the copy/dispose/signatures flags so that the OS calls us appropriately.
  header->flags |= (EDOBlockFlagsHasCopyDispose | EDOBlockFlagsHasSignature);

  header->invoke = (void (*)(void))_objc_msgForward;
#if !defined(__arm64__)
  if (self.returnsStruct) {
    header->invoke = (void (*)(void))_objc_msgForward_stret;
  }
#endif

  // Swap the ownership: the unarchiver retains `self` and autoreleases the `dummyOnHeap` block.
  // Here we capture self within the `dummyOnHeap` block, and replace `self` with the `dummyOnHeap`
  // block. This effectively transfers the ownership of dummyOnHeap to the caller of the unarchiver.
  CFBridgingRelease((__bridge void *)self);
  return (__bridge id)CFBridgingRetain(dummyOnHeap);
}

- (instancetype)edo_initWithLocalObject:(id)target port:(EDOServicePort *)port {
  // object is self. This does the same as self = [super initWithLocalObject:target port:port], but
  // because we have the prefix to avoid the naming collisions, the compiler complains assigning
  // self in a non-init method.
  EDOBlockObject *object = [super edo_initWithLocalObject:target port:port];

  _returnsStruct = HasStructReturnForBlock(target);
  _signature = [NSString stringWithUTF8String:[EDOBlockObject signatureFromBlock:target]];
  return object;
}

@end
