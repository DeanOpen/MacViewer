#include "MacViewerG722.h"
#include "modules/third_party/g722/g722_enc_dec.h"
#include <stdlib.h>
#include <string.h>

MacViewerG722Decoder *MacViewerG722Create(void) {
    /* The pinned upstream initializer memsets its allocation without checking
       malloc. Supply checked storage while leaving upstream code unchanged. */
    G722DecoderState *state = calloc(1, sizeof(*state));
    if (state == NULL) return NULL;
    WebRtc_g722_decode_init(state, 64000, 0);
    return (MacViewerG722Decoder *)state;
}

void MacViewerG722Destroy(MacViewerG722Decoder *decoder) {
    if (decoder != NULL) WebRtc_g722_decode_release((G722DecoderState *)decoder);
}

size_t MacViewerG722Decode(MacViewerG722Decoder *decoder, const uint8_t *encoded,
                          size_t encoded_length, int16_t *pcm, size_t pcm_capacity) {
    if (decoder == NULL || encoded == NULL || pcm == NULL || encoded_length > pcm_capacity / 2) return 0;
    G722DecoderState *state = (G722DecoderState *)decoder;
    /* NAudio's original SpanDSP port casts the final QMF output to Int16;
       WebRTC clamps it. This affects output only, never the predictor state.
       Keep upstream unchanged and recover wrapped samples from its QMF history
       immediately after each byte. Ordinary, unclipped samples need no work.
       Source: NAudio v1.8.4 G722Codec.cs Decode lines 294-308; independently
       checked against the installed NAudio1.8.5 Windows codec fixture. */
    static const int coefficients[12] = {
        3, -11, 12, 32, -210, 951, 3876, -805, 362, -156, 53, -11
    };
    for (size_t index = 0; index < encoded_length; ++index) {
        int16_t *output = pcm + index * 2;
        if (WebRtc_g722_decode(state, output, encoded + index, 1) != 2) return 0;
        if (output[0] == INT16_MIN || output[0] == INT16_MAX ||
            output[1] == INT16_MIN || output[1] == INT16_MAX) {
            int64_t first = 0, second = 0;
            for (int tap = 0; tap < 12; ++tap) {
                first += (int64_t)state->x[2 * tap + 1] * coefficients[11 - tap];
                second += (int64_t)state->x[2 * tap] * coefficients[tap];
            }
            /* Unsigned conversion is defined modulo 2^16. Copy the bit pattern
               rather than relying on an out-of-range signed C conversion. */
            uint16_t bits[2] = { (uint16_t)(first >> 11), (uint16_t)(second >> 11) };
            memcpy(output, bits, sizeof(bits));
        }
    }
    return encoded_length * 2;
}
