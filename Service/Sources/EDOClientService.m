
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

#import "Service/Sources/EDOClientService.h"

#include <objc/runtime.h>

#import "Channel/Sources/EDOSocketChannel.h"
#import "Channel/Sources/EDOSocketChannelPool.h"
#import "Service/Sources/EDOBlockObject.h"
#import "Service/Sources/EDOExecutor.h"
#import "Service/Sources/EDOHostService+Private.h"
#import "Service/Sources/EDOObject+Private.h"
#import "Service/Sources/EDOClassMessage.h"
#import "Service/Sources/EDOObjectMessage.h"
#import "Service/Sources/EDOObjectReleaseMessage.h"

@implementation EDOClientService

+ (id)rootObjectWithPort:(UInt16)port {
  EDOServiceResponse *response = [self sendRequest:[EDOObjectRequest request] port:port];
  EDOObject *rootObject = ((EDOObjectResponse *)response).object;
  rootObject = [EDOHostService.currentService unwrappedObjectFromObject:rootObject] ?: rootObject;
  rootObject = [self cachedEDOFromObjectUpdateIfNeeded:rootObject];
  return rootObject;
}

+ (id)classObjectWithName:(NSString *)className port:(UInt16)port {
  EDOServiceRequest *classRequest = [EDOClassRequest requestWithClassName:className];
  EDOServiceResponse *response = [self sendRequest:classRequest port:port];
  EDOObject *classObject = ((EDOObjectResponse *)response).object;
  classObject =
      [EDOHostService.currentService unwrappedObjectFromObject:classObject] ?: classObject;
  classObject = [self cachedEDOFromObjectUpdateIfNeeded:classObject];
  return classObject;
}

+ (NSMapTable *)localDistantObjects {
  static NSMapTable<NSNumber *, EDOObject *> *localDistantObjects;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    localDistantObjects = [NSMapTable strongToWeakObjectsMapTable];
  });
  return localDistantObjects;
}

+ (dispatch_queue_t)edoSyncQueue {
  static dispatch_queue_t edoSyncQueue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    edoSyncQueue = dispatch_queue_create("com.google.edo.service.edoSync", DISPATCH_QUEUE_SERIAL);
  });
  return edoSyncQueue;
}

+ (EDOObject *)distantObjectReferenceForRemoteAddress:(EDOPointerType)remoteAddress {
  NSNumber *edoKey = [NSNumber numberWithLongLong:remoteAddress];
  __block EDOObject *result;
  dispatch_sync(self.edoSyncQueue, ^{
    result = [self.localDistantObjects objectForKey:edoKey];
  });
  return result;
}

+ (void)addDistantObjectReference:(id)object {
  EDOObject *edoObject =
      [EDOBlockObject isBlock:object] ? [EDOBlockObject EDOBlockObjectFromBlock:object] : object;
  NSNumber *edoKey = [NSNumber numberWithLongLong:edoObject.remoteAddress];
  dispatch_sync(self.edoSyncQueue, ^{
    [self.localDistantObjects setObject:object forKey:edoKey];
  });
}

+ (void)removeDistantObjectReference:(EDOPointerType)remoteAddress {
  NSNumber *edoKey = [NSNumber numberWithLongLong:remoteAddress];
  dispatch_sync(self.edoSyncQueue, ^{
    [self.localDistantObjects removeObjectForKey:edoKey];
  });
}

#pragma mark - Private

+ (EDOServiceResponse *)sendRequest:(EDOServiceRequest *)request port:(UInt16)port {
  __block NSException *exception = nil;
  __block id<EDOChannel> channel = nil;
  __block NSError *retryError = nil;
  int attempts = 2;

  while (attempts > 0) {
    dispatch_semaphore_t waitLock = dispatch_semaphore_create(0L);
    void (^fetchChannelCompletionHandler)(EDOSocketChannel *, NSError *) =
        ^(EDOSocketChannel *socketChannel, NSError *error) {
          if (error) {
            NSString *reason = [NSString
                stringWithFormat:@"Failed to connect the service %d for %@.", port, request];
            exception = [self exceptionWithReason:reason port:port error:error];
          } else {
            channel = socketChannel;
          }
          dispatch_semaphore_signal(waitLock);
        };
    [EDOSocketChannelPool.sharedChannelPool
        fetchConnectedChannelWithPort:port
                withCompletionHandler:fetchChannelCompletionHandler];

    // Either the response comes back in time, or connection times out.
    dispatch_semaphore_wait(waitLock, DISPATCH_TIME_FOREVER);

    // Populate the connection errors so the stack is properly unwound.
    // For nil exception, this is safely ignored.
    [exception raise];

    NSError *error = nil;

    // If the request is of type ObjectReleaseRequest then don't perform any of the
    // protocol (check if channel is alive, send ping message, report errors, etc.). If the message
    // wasn't able to sent then it's most likely that the host side is dead and there's no need
    // to retry or try to handle it.
    if ([request class] == [EDOObjectReleaseRequest class]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      // TODO(b/112517451): Support eDO with iOS 12.
      NSData *requestData = [NSKeyedArchiver archivedDataWithRootObject:request];
#pragma clang diagnostic pop
      [channel sendData:requestData withCompletionHandler:nil];
      [EDOSocketChannelPool.sharedChannelPool addChannel:channel];
      return nil;
    } else {
      EDOServiceResponse *response = [[EDOExecutor currentExecutor] sendRequest:request
                                                                    withChannel:channel
                                                                          error:&error];
      // TODO(ynzhang): better to check error type when we have better error handling. In some cases
      // we won't need to retry and could give better error information.
      if (!error && !response.error) {
        [EDOSocketChannelPool.sharedChannelPool addChannel:channel];
        return response;
      } else {
        // Cleanup broken channels before retry.
        [EDOSocketChannelPool.sharedChannelPool removeChannelsWithPort:port];
        attempts -= 1;
        retryError = error;
      }
    }
  }
  NSAssert(NO, @"Retry creating channel failed. This failure should happen at connection time "
               @"instead of reaching here.");
  return nil;
}

+ (NSException *)exceptionWithReason:(NSString *)reason port:(UInt16)port error:(NSError *)error {
  NSDictionary *userInfo = @{@"port" : @(port), @"error" : error ?: NSNull.null};
  return [NSException exceptionWithName:NSDestinationInvalidException
                                 reason:reason
                               userInfo:userInfo];
}

+ (id)cachedEDOFromObjectUpdateIfNeeded:(id)object {
  EDOObject *edoObject =
      [EDOBlockObject isBlock:object] ? [EDOBlockObject EDOBlockObjectFromBlock:object] : object;
  Class objClass = object_getClass(edoObject);
  if (objClass == [EDOObject class] || objClass == [EDOBlockObject class]) {
    id localObject = [self distantObjectReferenceForRemoteAddress:edoObject.remoteAddress];
    EDOObject *localEDO = localObject;
    if ([EDOBlockObject isBlock:localObject]) {
      localEDO = [EDOBlockObject EDOBlockObjectFromBlock:localEDO];
    }
    // Verify the service in case the old address is overwritten by a new service.
    if ([edoObject.servicePort match:localEDO.servicePort]) {
      // Since we already have the EDOObject in the cache, the new decoded EDOObject is
      // taken as a temporary local object, which does not send release message.
      edoObject.local = YES;
      return localObject;
    } else {
      // Track the new remote object.
      [self addDistantObjectReference:object];
    }
  }
  return object;
}

@end
