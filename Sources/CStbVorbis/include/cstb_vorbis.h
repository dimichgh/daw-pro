// Flat-C shim over the vendored stb_vorbis Ogg Vorbis decoder (m31-h).
//
// WHY THIS EXISTS: `.sf3` SoundFonts — the format MuseScore ships EXCLUSIVELY,
// and therefore the one a consumer most likely already has — are structurally
// `.sf2` with every sample replaced by an independent Ogg Vorbis stream. macOS
// has no PUBLIC Vorbis decoder (measured: no `Ogg`/`Vorbis` constant exists in
// any AudioToolbox or AVFAudio header, while `kAudioFileFLACType` does), so
// converting one at import time needs a decoder we carry ourselves.
//
// OFFLINE ONLY — this runs at IMPORT time, never on the render thread: it
// allocates, and a whole-file decode is unbounded work.

#ifndef CSTB_VORBIS_H
#define CSTB_VORBIS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Decodes one COMPLETE in-memory Ogg Vorbis stream to interleaved 16-bit PCM.
///
/// Returns the number of frames (samples PER CHANNEL) on success and writes
/// `*out_samples` — a malloc'd interleaved buffer the caller MUST release with
/// `cstb_vorbis_free`. Returns a NEGATIVE value on any failure, in which case
/// `*out_samples` is set to NULL and the out-params are untouched.
///
/// ⛔ It never returns 0-with-a-buffer for a stream it could not read: a
/// failure is always negative, so a caller cannot mistake "undecodable" for
/// "legitimately empty" and write silence into a converted bank.
int32_t cstb_vorbis_decode(const uint8_t *data, int32_t length,
                           int32_t *out_channels, int32_t *out_sample_rate,
                           int16_t **out_samples);

/// Releases a buffer handed back by `cstb_vorbis_decode`. NULL-safe.
void cstb_vorbis_free(int16_t *samples);

#ifdef __cplusplus
}
#endif

#endif /* CSTB_VORBIS_H */
