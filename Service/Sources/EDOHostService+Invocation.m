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

#import "Service/Sources/EDOHostService+Invocation.h"

#import "Channel/Sources/EDOChannel.h"
#import "Channel/Sources/EDOSocket.h"
#import "Service/Sources/EDOClientService+Private.h"
#import "Service/Sources/EDOExecutor.h"
#import "Service/Sources/EDOObjectReleaseMessage.h"
#import "Service/Sources/NSKeyedArchiver+EDOAdditions.h"
#import "Service/Sources/NSKeyedUnarchiver+EDOAdditions.h"

// Some internal properties are exposed for the private category. For details please refer to
// EDOHostService.m
@interface EDOHostService ()
@property(readonly) EDOExecutor *executor;
@property(readonly) NSMutableSet<EDOChannelReceiveHandler> *handlerSet;
@property(readonly) dispatch_queue_t handlerSyncQueue;
@property(readonly) EDOSocket *listenSocket;
@end

@implementation EDOHostService (Invocation)

- (void)scheduleReceiveRequestsForChannel:(id<EDOChannel>)channel {
  // This handler block will be executed recursively by calling itself at the end of the
  // block. This is to accept new request after last one is executed.
  __block __weak EDOChannelReceiveHandler weakHandlerBlock;
  __weak EDOHostService *weakSelf = self;

  EDOChannelReceiveHandler receiveHandler = ^(id<EDOChannel> channel, NSData *data,
                                              NSError *error) {
    EDOChannelReceiveHandler strongHandlerBlock = weakHandlerBlock;
    EDOHostService *strongSelf = weakSelf;
    NSException *exception;
    // TODO(haowoo): Add the proper error handler.
    NSAssert(error == nil, @"Failed to receive the data (%d) for %@.", strongSelf.port.port, error);
    if (data == nil) {
      // the client socket is closed.
      NSLog(@"The channel (%p) with port %d is closed", channel, strongSelf.port.port);
      dispatch_sync(strongSelf.handlerSyncQueue, ^{
        [strongSelf.handlerSet removeObject:strongHandlerBlock];
      });
      return;
    }
    EDOServiceRequest *request;

    @try {
      request = [NSKeyedUnarchiver edo_unarchiveObjectWithData:data];
    } @catch (NSException *e) {
      // TODO(haowoo): Handle exceptions in a better way.
      exception = e;
    }
    if (![request matchesService:strongSelf.port]) {
      // TODO(ynzhang): With better error handling, we may not throw exception in this
      // case but return an error response.
      NSError *error;

      if (!request) {
        // Error caused by the unarchiving process.
        error = [NSError errorWithDomain:exception.reason code:0 userInfo:nil];
      } else {
        error = [NSError errorWithDomain:NSPOSIXErrorDomain code:0 userInfo:nil];
      }
      EDOServiceResponse *errorResponse = [EDOServiceResponse errorResponse:error
                                                                 forRequest:request];
      NSData *errorData = [NSKeyedArchiver edo_archivedDataWithObject:errorResponse];
      [channel sendData:errorData
          withCompletionHandler:^(id<EDOChannel> _Nonnull channel, NSError *_Nullable error) {
            dispatch_sync(strongSelf.handlerSyncQueue, ^{
              [strongSelf.handlerSet removeObject:strongHandlerBlock];
            });
          }];
    } else {
      // For release request, we don't handle it in executor since response is not
      // needed for this request. The request handler will process this request
      // properly in its own queue.
      if ([request class] == [EDOObjectReleaseRequest class]) {
        [EDOObjectReleaseRequest requestHandler](request, strongSelf);
      } else {
        // Health check for the channel.
        [channel sendData:EDOClientService.pingMessageData withCompletionHandler:nil];
        EDOServiceResponse *response = [strongSelf.executor handleRequest:request context:self];

        NSData *responseData = [NSKeyedArchiver edo_archivedDataWithObject:response];
        [channel sendData:responseData withCompletionHandler:nil];
      }
      if (channel.isValid && strongSelf.listenSocket.valid) {
        [channel receiveDataWithHandler:strongHandlerBlock];
      }
    }
    // Channel will be released and invalidated if service becomes invalid. So the
    // recursive block will eventually finish after service is invalid.
  };
  weakHandlerBlock = receiveHandler;

  [channel receiveDataWithHandler:receiveHandler];

  dispatch_sync(self.handlerSyncQueue, ^{
    [self.handlerSet addObject:receiveHandler];
  });
}

@end
