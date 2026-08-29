# Vendored third-party code

Single-file public-domain Ogg Vorbis decoder, vendored verbatim (the decoder
plus its license, nothing else) for SF3→SF2 conversion at import time (m31-h).
`shim.c` is the only translation unit; it `#include`s the vendored `.c`, which
is therefore `exclude`d in Package.swift so its symbols exist exactly once.

| Library | Upstream | Commit | Fetched | License |
|---|---|---|---|---|
| stb_vorbis (v1.22) | https://github.com/nothings/stb | `1ee679ca2ef753a528db5ba6801e1067b40481b8` | 2026-08-28 | MIT / public domain, dual (`vendor/LICENSE.txt`) |

`vendor/stb_vorbis.c` SHA256:
`4c7cb2ff1f7011e9d67950446b7eb9ca044f2e464d76bfbb0b84dd2e23e65636`

## Why a vendored decoder rather than the OS

Measured on macOS 26.4 before choosing this, because "check, do not assume" cut
both ways here — the OS turned out to decode Vorbis, and it still was not
usable:

1. **No public API.** No `Ogg` or `Vorbis` constant exists in any AudioToolbox
   or AVFAudio header. The grep was positive-controlled: `kAudioFileFLACType`
   *is* there, in the same headers, so the absence is real. What works on 26.4
   is undocumented behaviour with no availability annotation.
2. **The deployment floor is macOS 14**, which cannot be tested here — and
   m26-d makes bank installation an UNATTENDED FIRST-RUN path, the worst place
   to depend on an OS version's undocumented decoder.
3. **It is measurably incomplete.** Across the 1186 samples of the real
   `FluidR3Mono_GM.sf3`, `AVAudioFile` decoded 1169 and failed 17 — every one
   of them a short single-cycle wavetable (sines, saws, squares, pulses).
   `stb_vorbis` decodes all 1186.
4. **Determinism.** The OS trims sample 0 to its granule position (48 frames);
   ffmpeg emits 128. One vendored decoder means one reproducible artifact on
   every machine and OS version, which is what lets a converted bank be
   hash-pinned at all.

Correctness was checked against ffmpeg's independent libvorbis-lineage decoder
on the largest sample in the bank (632,869 frames): identical frame count,
identical peak (16249), max absolute difference 1 LSB, Pearson r = 0.9999999999.

To update: re-copy `stb_vorbis.c` from upstream, update the commit + SHA256
above, and re-run `SF3ConversionTests` — the fixture asserts decoded frame
counts, so a decoder behaviour change fails loudly rather than silently
altering converted banks.
