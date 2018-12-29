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

#import "Channel/Sources/EDOChannelUtil.h"

static const uint64_t kGEdoSocketFrameHeaderTag = 0xc080c080;

// Check if the frame header is valid
// TODO(haowoo): add more checksum checks.
static BOOL edo_isFrameHeaderValid(EDOSocketFrameHeader_t *header) {
  // Make sure it is not NULL and the tag matches the magic tag so we can make sure the data being
  // processed is in the expected format.
  return header != NULL && header->tag == kGEdoSocketFrameHeaderTag;
}

size_t GetPayloadSizeFromFrameData(dispatch_data_t data) {
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

dispatch_data_t BuildFrameFromDataWithQueue(NSData *data, dispatch_queue_t queue) {
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
