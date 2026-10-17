#ifndef MACVIEWER_G722_H
#define MACVIEWER_G722_H

#include <stddef.h>
#include <stdint.h>

typedef struct MacViewerG722Decoder MacViewerG722Decoder;

MacViewerG722Decoder *MacViewerG722Create(void);
void MacViewerG722Destroy(MacViewerG722Decoder *decoder);
size_t MacViewerG722Decode(MacViewerG722Decoder *decoder, const uint8_t *encoded,
                          size_t encoded_length, int16_t *pcm, size_t pcm_capacity);

#endif
