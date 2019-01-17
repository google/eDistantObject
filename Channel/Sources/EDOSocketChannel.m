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

#import "Channel/Sources/EDOSocketChannel.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <sys/un.h>

#import "Channel/Sources/EDOChannelUtil.h"
#import "Channel/Sources/EDOHostPort.h"
#import "Channel/Sources/EDOSocket.h"
#import "Channel/Sources/EDOSocketPort.h"

#pragma mark - Socket Connection Extension

@interface EDOSocketChannel ()
// The underlying socket file descriptor.
@property dispatch_fd_t socket;
// The dispatch io channel to send and receive I/O data from the underlying socket.
@property(readonly) dispatch_io_t channel;
// The dispatch queue to run the dispatch source handler and IO handler.
@property(readonly) dispatch_queue_t eventQueue;
// The dispatch queue where the receive handler block will be dispatched to.
@property(readonly) dispatch_queue_t handlerQueue;
// The data to be received.
@property dispatch_data_t dataReceived;
// The remaining size of data to be received.
@property size_t remainingDataSize;
@end

#pragma mark - Socket Connection

@implementation EDOSocketChannel
@dynamic valid;
@synthesize hostPort = _hostPort;

+ (instancetype)channelWithSocket:(EDOSocket *)socket {
  return [[self alloc] initWithSocket:socket hostPort:nil];
}

+ (instancetype)channelWithSocket:(EDOSocket *)socket hostPort:(EDOHostPort *)hostPort {
  return [[self alloc] initWithSocket:socket hostPort:hostPort];
}

+ (instancetype)channelWithDispatchChannel:(dispatch_io_t)dispatchChannel
                                  hostPort:(EDOHostPort *)hostPort {
  return [[self alloc] initWithDispatchChannel:dispatchChannel hostPort:hostPort];
}

- (instancetype)initWithSocket:(EDOSocket *)socket hostPort:(EDOHostPort *)hostPort {
  self = [self initInternal];
  if (self) {
    if (socket.valid) {
      // The channel takes over the socket.
      dispatch_fd_t socketFD = [socket releaseSocket];
      _socket = socketFD;
      __weak EDOSocketChannel *weakSelf = self;
      _channel = dispatch_io_create(DISPATCH_IO_STREAM, socketFD, _eventQueue, ^(int error) {
        weakSelf.socket = -1;

        // TODO(haowoo): check error and report.
        if (error == 0) {
          close(socketFD);
        }
      });

      // Clean up the socket if it fails to create the channel here.
      if (_channel == NULL && socketFD != -1) {
        close(socketFD);
      } else {
        _hostPort = hostPort;
      }
    }
  }
  return self;
}

- (instancetype)initWithDispatchChannel:(dispatch_io_t)dispatchChannel
                               hostPort:(EDOHostPort *)hostPort {
  self = [self initInternal];
  if (self) {
    _socket = dispatch_io_get_descriptor(dispatchChannel);
    _channel = dispatchChannel;
    _hostPort = hostPort;
  }
  return self;
}

- (instancetype)initInternal {
  self = [super init];
  if (self) {
    _socket = -1;
    _handlerQueue =
        dispatch_queue_create("com.google.edo.socketChannel.handler", DISPATCH_QUEUE_CONCURRENT);
    // For internal IO and event handlers, it is equivalent to creating it as a serial queue as they
    // are not reentrant and only one block will be scheduled by dispatch io and dispatch source.
    _eventQueue =
        dispatch_queue_create("com.google.edo.socketChannel.event", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)dealloc {
  [self invalidate];
}

- (void)updateHostPort:(EDOHostPort *)hostPort {
  _hostPort = hostPort;
}

#pragma mark - EDOChannel

- (void)sendData:(NSData *)data withCompletionHandler:(EDOChannelSentHandler)handler {
  if (!self.channel) {
    dispatch_async(_handlerQueue, ^{
      if (handler) {
        handler(self, [NSError errorWithDomain:NSPOSIXErrorDomain code:0 userInfo:nil]);
      }
    });
    return;
  }

  dispatch_data_t totalData = EDOBuildFrameFromDataWithQueue(data, self.eventQueue);
  dispatch_io_write(
      self.channel, 0, totalData, self.eventQueue, ^(bool done, dispatch_data_t _, int errCode) {
        if (!done) {
          return;
        }

        if (handler) {
          dispatch_async(self->_handlerQueue, ^{
            NSError *error;
            if (errCode != 0) {
              error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errCode userInfo:nil];
            }
            handler(self, error);
          });
        }
      });
}

- (void)receiveDataWithHandler:(EDOChannelReceiveHandler)handler {
  if (!self.channel) {
    dispatch_async(_handlerQueue, ^{
      // TODO(haowoo): Add better error code define.
      handler(self, nil,
              [NSError errorWithDomain:NSInternalInconsistencyException code:0 userInfo:nil]);
    });
    return;
  }

  dispatch_io_handler_t dataHandler = ^(bool done, dispatch_data_t data, int error) {
    // TODO(haowoo): Propagate this error to the handler.
    NSAssert(error == 0, @"Error on receiving data.");
    self.remainingDataSize -= dispatch_data_get_size(data);
    self.dataReceived =
        self.dataReceived ? dispatch_data_create_concat(self.dataReceived, data) : data;

    if (self.remainingDataSize > 0) {
      return;
    }

    NSMutableData *receivedData =
        [NSMutableData dataWithCapacity:dispatch_data_get_size(self.dataReceived)];
    dispatch_data_apply(self.dataReceived, ^bool(dispatch_data_t region, size_t offset,
                                                 const void *buffer, size_t size) {
      [receivedData appendBytes:buffer length:size];
      return YES;
    });
    self.dataReceived = nil;

    if (handler) {
      dispatch_async(self->_handlerQueue, ^{
        handler(self, receivedData, nil);
      });
    }
  };

  dispatch_io_handler_t frameHandler = ^(bool done, dispatch_data_t data, int error) {
    dispatch_io_t channel = self.channel;
    size_t payloadSize = EDOGetPayloadSizeFromFrameData(data);
    if (payloadSize > 0) {
      self.remainingDataSize = payloadSize;
      dispatch_io_read(channel, 0, payloadSize, self.eventQueue, dataHandler);
    } else {
      // Close the channel on errors and closed sockets.
      if (error != 0 || payloadSize == 0) {
        [self invalidate];
      }

      // Execute the block on closing the channel.
      if (payloadSize == 0 && error == 0 && handler) {
        dispatch_async(self->_handlerQueue, ^{
          handler(self, nil, nil);
        });
      }
    }
  };

  NSAssert(!self.dataReceived, @"There is an ongoing data transfer.");
  dispatch_io_read(_channel, 0, sizeof(EDOSocketFrameHeader_t), _eventQueue, frameHandler);
}

/** @see -[EDOChannel isValid] */
- (BOOL)isValid {
  return _socket != -1 && _channel != NULL;
}

/** @see -[EDOChannel invalidate] */
- (void)invalidate {
  if (_channel) {
    dispatch_io_close(_channel, 0);
    _channel = NULL;
  }
  _hostPort = nil;
}

@end
