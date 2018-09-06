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

#import "Channel/Sources/EDOSocket.h"
#import "Channel/Sources/EDOSocketPort.h"

static char const *gSocketChannelQueueLabel = "com.google.edo.socket_channel";

#pragma mark - Socket Frame Header

/**
 *  The data header for each data package being sent.
 *
 *  The header data layout:
 *  |--- 32bit ---|--- 32bit ---|----- 32 bit -----|--- flexible ---|
 *  |-- type(1) --|- 0xc080c080-|- length of data -|--*-* data *-*--|
 */
typedef struct EDOSocketFrameHeader_s {
  // Type of frame, always 1.
  uint32_t type;

  // Tag.
  uint32_t tag;

  // If payloadSize is larger than zero, @c payloadSize of bytes are following.
  uint32_t payloadSize;
} EDOSocketFrameHeader_t;

#pragma mark - EDOSocketFrameHeader util functions

static const uint64_t kGEdoSocketFrameHeaderTag = 0xc080c080;

// Check if the frame header is valid
// TODO(haowoo): add more checksum checks.
static BOOL edo_isFrameHeaderValid(EDOSocketFrameHeader_t *header) {
  // Make sure it is not NULL and the tag matches the magic tag so we can make sure the data being
  // processed is in the expected format.
  return header != NULL && header->tag == kGEdoSocketFrameHeaderTag;
}

/** Get the size of the payload from the frame header. */
static size_t GetPayloadSizeFromFrameData(dispatch_data_t data) {
  if (data == NULL) {
    return 0;
  }

  EDOSocketFrameHeader_t *frame = NULL;
  dispatch_data_t contiguousData = dispatch_data_create_map(data, (const void **)&frame, NULL);

  if (!edo_isFrameHeaderValid(frame)) {
    return 0;
  }

  size_t payloadSize = ntohl(frame->payloadSize);
  contiguousData = NULL;
  return payloadSize;
}

/** Util to create dispatch_data from NSData */
static dispatch_data_t BuildFrameFromDataWithQueue(NSData *data, dispatch_queue_t queue) {
  dispatch_data_t frameData = dispatch_data_create(data.bytes, data.length, queue, ^{
    // The trick to have the block capture and retain the data.
    [data length];
  });

  dispatch_data_t headerData = ({
    EDOSocketFrameHeader_t frameHeader = {
        .type = 1,
        .tag = kGEdoSocketFrameHeaderTag,
        .payloadSize = htonl(data.length),
    };
    NSData *headerData = [NSData dataWithBytes:&frameHeader length:sizeof(frameHeader)];
    dispatch_data_create(headerData.bytes, headerData.length, queue, ^{
      [headerData length];
    });
  });
  return dispatch_data_create_concat(headerData, frameData);
}

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

+ (instancetype)channelWithSocket:(EDOSocket *)socket listenPort:(UInt16)listenPort {
  return [[self alloc] initWithSocket:socket listenPort:listenPort];
}

- (instancetype)initWithSocket:(EDOSocket *)socket listenPort:(UInt16)listenPort {
  self = [super init];
  if (self) {
    _socket = -1;
    _listenPort = 0;
    _handlerQueue =
        dispatch_queue_create("com.google.edo.socketChannel", DISPATCH_QUEUE_CONCURRENT);
    // For internal IO and event handlers, it is equivalent to creating it as a serial queue as they
    // are not reentrant and only one block will be scheduled by dispatch io and dispatch source.
    _eventQueue = dispatch_queue_create(gSocketChannelQueueLabel, DISPATCH_QUEUE_SERIAL);

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
        _listenPort = listenPort;
      }
    }
  }
  return self;
}

- (void)dealloc {
  [self invalidate];
}

- (void)sendData:(NSData *)data withCompletionHandler:(EDOChannelSentHandler)handler {
  if (!self.channel) {
    dispatch_async(_handlerQueue, ^{
      if (handler) {
        handler(self, [NSError errorWithDomain:NSPOSIXErrorDomain code:0 userInfo:nil]);
      }
    });
    return;
  }

  dispatch_data_t totalData = BuildFrameFromDataWithQueue(data, self.eventQueue);
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
    size_t payloadSize = GetPayloadSizeFromFrameData(data);
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
  _listenPort = 0;
}

@end
