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

#import "Channel/Sources/EDOSocket.h"

#import "Channel/Sources/EDOListenSocket.h"
#import "Channel/Sources/EDOSocketPort.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <sys/un.h>

// The 'nil' completion block that does nothing.
static EDOSocketConnectedBlock gNoOpHandlerBlock =
    ^(EDOSocket *socket, UInt16 listenPort, NSError *error) {
    };

#pragma mark - Socket help functions
/**
 *  Create a non-block socket.
 *
 *  @param errNo the out parameter when it errors.
 *
 *  @return -1, if fails to create and @c errNo contains @c errno value;
 *          the socket file descriptor, otherwise.
 */
static dispatch_fd_t edo_CreateSocket(int *errNo) {
  NSCAssert(errNo, @"errNo cannot be nil");

  dispatch_fd_t fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd == -1) {
    *errNo = errno;
    return -1;
  }

  if (fcntl(fd, F_SETFL, O_NONBLOCK) == -1) {
    *errNo = errno;
    close(fd);
    return -1;
  }

  return fd;
}

/** Util function to run block on the error code. */
static void edo_RunHandlerWithErrorInQueueWithBlock(int code, dispatch_queue_t queue,
                                                    EDOSocketConnectedBlock block) {
  if (block) {
    dispatch_async(queue, ^{
      block(nil, 0, [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil]);
    });
  }
}

#pragma mark - EDOSocket implementation

@implementation EDOSocket {
  dispatch_fd_t _socket;
}

@dynamic valid;
@synthesize socket = _socket;

- (instancetype)initWithSocket:(dispatch_fd_t)socket {
  self = [super init];
  if (self) {
    _socket = socket;
    _socketPort = [[EDOSocketPort alloc] initWithSocket:socket];
  }
  return self;
}

- (void)dealloc {
  // Make sure the socket is released and closed.
  [self invalidate];
}

+ (instancetype)socketWithSocket:(dispatch_fd_t)socket {
  return [[self alloc] initWithSocket:socket];
}

- (dispatch_fd_t)releaseSocket {
  dispatch_fd_t socketFD = _socket;
  _socket = -1;
  return socketFD;
}

- (void)invalidate {
  dispatch_fd_t socketFD = [self releaseSocket];
  if (socketFD != -1) {
    close(socketFD);
  }
}

- (BOOL)valid {
  return _socket >= 0;
}

+ (void)connectWithTCPPort:(UInt16)port
                     queue:(dispatch_queue_t)queue
            connectedBlock:(EDOSocketConnectedBlock)block {
  block = block ?: gNoOpHandlerBlock;
  queue = queue ?: dispatch_queue_create("com.google.edo.connectSocket", DISPATCH_QUEUE_SERIAL);

  int socketErr = 0;
  dispatch_fd_t socketFD = edo_CreateSocket(&socketErr);
  if (socketFD == -1) {
    edo_RunHandlerWithErrorInQueueWithBlock(socketErr, queue, block);
    return;
  }

  // The dispatch source to wait on the connection.
  __block dispatch_source_t source =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)socketFD, 0, queue);

  dispatch_source_set_event_handler(source, ^{
    int connectError = 0;
    socklen_t errorlen = sizeof(connectError);

    // If there is an error, the connection fails.
    if (getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &connectError, &errorlen) != 0 ||
        connectError != 0) {
      edo_RunHandlerWithErrorInQueueWithBlock(connectError, queue, block);
    } else {
      // Prevent SIGPIPE, suggested by Apple.
      // https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/NetworkingOverview/CommonPitfalls/CommonPitfalls.html
      int on = 1;
      setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
      block([EDOSocket socketWithSocket:socketFD], port, nil);
    }

    // Once connected, we don't need this source any more; so we don't track this internally.
    dispatch_source_cancel(source);
  });

  dispatch_source_set_cancel_handler(source, ^{
    // hold and release the strong reference until the source is done or error.
    source = nil;
  });

  dispatch_resume(source);

  // Setup a sockaddr with the default local loopback address 127.0.0.1 to connect to.
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

  int ret = connect(socketFD, (struct sockaddr const *)&addr, sizeof(addr));
  socketErr = errno;
  if (ret != 0 && socketErr != EINPROGRESS) {
    edo_RunHandlerWithErrorInQueueWithBlock(socketErr, queue, block);
    close(socketFD);
  }
}

+ (EDOSocket *)listenWithTCPPort:(UInt16)port
                           queue:(dispatch_queue_t)queue
                  connectedBlock:(EDOSocketConnectedBlock)block {
  block = block ?: gNoOpHandlerBlock;
  queue = queue ?: dispatch_queue_create("com.google.edo.listenSocket", DISPATCH_QUEUE_CONCURRENT);

  int socketErr = 0;
  dispatch_fd_t socketFD = edo_CreateSocket(&socketErr);
  if (socketFD == -1) {
    edo_RunHandlerWithErrorInQueueWithBlock(socketErr, queue, block);
    return nil;
  }

  int on = 1;
  if (setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on)) == -1) {
    edo_RunHandlerWithErrorInQueueWithBlock(errno, queue, block);
    close(socketFD);
    return nil;
  }

  // Setup a sockaddr with the default local loopback address 127.0.0.1 and bind it to listen on.
  // Currently only listen on the default addresss.
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_len = sizeof(addr);
  addr.sin_port = htons(port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(socketFD, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    close(socketFD);
    return nil;
  }

  return [EDOListenSocket
      listenSocketWithSocket:socketFD
              connectedBlock:^(EDOSocket *socket, UInt16 listenPort, NSError *error) {
                // dispatch the block to the user's queue
                dispatch_async(queue, ^{
                  block(socket, listenPort, nil);
                });
              }];
}

@end
