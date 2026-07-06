#pragma once
#include <stdbool.h>

// Flat-C facade over the vendored signalsmith-stretch C++ template (see
// vendor/ and VENDORED.md). One opaque handle per stretch job; NOT thread-safe
// per handle — the caller owns serialization (the OfflineStretcher facade uses
// one handle per render, on one thread). This shim exists so Swift never has
// to import C++ templates (the CAtomics precedent). Offline use only: the
// implementation allocates freely and must never run on the render thread.
//
// All audio is planar (non-interleaved) float32: `buffers[channel][frame]`.
// The offline recipe (mirrors upstream cmd/main.cpp + SignalsmithStretch::exact):
//   seekLength = inputLatency + outputLatency / stretchRatio   (truncated)
//   css_output_seek(first seekLength input frames)   // output now aligned to input start
//   css_process(...) in blocks, per-block out/in ≈ stretchRatio
//   css_flush(the last seekLength * stretchRatio output frames)

#ifdef __cplusplus
extern "C" {
#endif

typedef struct css_stretch css_stretch;

/// Creates a stretcher configured with signalsmith's default preset
/// (`presetDefault`: ~120 ms block, ~30 ms interval at `sampleRate`).
/// `seed` seeds the internal phase-randomisation RNG — pass a fixed value for
/// bit-reproducible offline renders (the default C++ ctor seeds from
/// std::random_device, which we deliberately avoid). Returns NULL on
/// allocation failure. Free with css_destroy.
css_stretch *_Nullable css_create(int channels, float sampleRate, long long seed);

void css_destroy(css_stretch *_Nonnull s);

/// Back to the just-created state (keeps configuration, clears audio state).
void css_reset(css_stretch *_Nonnull s);

/// Pitch shift in semitones (positive = up). `tonalityLimitHz` bounds the
/// frequency band that keeps harmonic alignment; 8000 Hz is upstream's
/// recommended default, 0 disables the limit.
void css_set_transpose_semitones(css_stretch *_Nonnull s, float semitones,
                                 float tonalityLimitHz);

/// true = keep formants at their source position while pitch-shifting
/// (signalsmith formant compensation with auto-detected fundamental — vocal
/// mode). false = formants follow the pitch shift (default).
void css_set_formant_preserve(css_stretch *_Nonnull s, bool preserve);

/// Analysis-side latency in input frames: input must be supplied this far
/// ahead of the processing position.
int css_input_latency(const css_stretch *_Nonnull s);

/// Synthesis-side latency in output frames: delivered output lags the
/// processing position by this much.
int css_output_latency(const css_stretch *_Nonnull s);

/// Signalsmith `outputSeek`: consumes the FIRST `inputFrames` frames of the
/// source and internally pre-computes the synthesis pre-roll, so the very
/// next frames from css_process are aligned to the start of the source
/// (no output trimming needed). Feed it
/// inputLatency + outputLatency * (inputFrames-per-outputFrame) frames —
/// derived from the two latency accessors above.
void css_output_seek(css_stretch *_Nonnull s,
                     const float *_Nonnull const *_Nonnull inputs,
                     int inputFrames);

/// Consumes exactly `inputFrames` and produces exactly `outputFrames`; the
/// effective stretch ratio is outputFrames/inputFrames, averaged across calls
/// (mirrors signalsmith's own process shape — there is no ratio setter).
void css_process(css_stretch *_Nonnull s,
                 const float *_Nonnull const *_Nonnull inputs, int inputFrames,
                 float *_Nonnull const *_Nonnull outputs, int outputFrames);

/// Drains the remaining output after the last css_process call (click-free
/// ending; no further input is consumed). `playbackRate` is the input/output
/// frame ratio (1/stretchRatio), used to keep the tail time-map consistent.
void css_flush(css_stretch *_Nonnull s,
               float *_Nonnull const *_Nonnull outputs, int outputFrames,
               double playbackRate);

#ifdef __cplusplus
}
#endif
