//
// Copyright 2019 Google Inc.
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

#import <Foundation/Foundation.h>

#ifndef EDOCHANNEL_UTIL_H_
#define EDOCHANNEL_UTIL_H_

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

#if defined(__cplusplus)
extern "C" {
#endif

/** Get the size of the payload from the frame header. */
size_t EDOGetPayloadSizeFromFrameData(dispatch_data_t data);

/** Util to create dispatch_data with frame header from NSData. */
dispatch_data_t EDOBuildFrameFromDataWithQueue(NSData *data, dispatch_queue_t queue);

#if defined(__cplusplus)
}  //   extern "C"
#endif

#endif
