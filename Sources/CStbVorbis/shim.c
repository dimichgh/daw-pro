// The ONLY translation unit in this target. The vendored decoder is #included
// (not compiled separately) and is `exclude`d in Package.swift, so stb_vorbis'
// symbols exist exactly once and none of them are exported beyond this file.

#include "include/cstb_vorbis.h"

#include <stdlib.h>

// stb_vorbis pulls in its own <stdio.h> paths for the file API we never use.
#define STB_VORBIS_NO_PUSHDATA_API
#define STB_VORBIS_NO_STDIO
#include "vendor/stb_vorbis.c"

int32_t cstb_vorbis_decode(const uint8_t *data, int32_t length,
                           int32_t *out_channels, int32_t *out_sample_rate,
                           int16_t **out_samples)
{
    if (out_samples) { *out_samples = NULL; }
    if (!data || length <= 0 || !out_channels || !out_sample_rate || !out_samples) {
        return -1;
    }
    int channels = 0;
    int rate = 0;
    short *decoded = NULL;
    int frames = stb_vorbis_decode_memory((const unsigned char *)data, (int)length,
                                          &channels, &rate, &decoded);
    if (frames < 0) {
        if (decoded) { free(decoded); }
        return -2;
    }
    // A stream that yields no frames is a FAILURE for our purposes, not an
    // empty sample: writing it into a converted bank would be a silent hole.
    if (frames == 0 || decoded == NULL || channels <= 0 || rate <= 0) {
        if (decoded) { free(decoded); }
        return -3;
    }
    *out_channels = (int32_t)channels;
    *out_sample_rate = (int32_t)rate;
    *out_samples = (int16_t *)decoded;
    return (int32_t)frames;
}

void cstb_vorbis_free(int16_t *samples)
{
    if (samples) { free((void *)samples); }
}
