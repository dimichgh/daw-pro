#!/usr/bin/env python3
"""Generates the committed bundled sampler content (m30-a).

The DAW ships with NO sample audio, so a fresh project cannot make the built-in
Sampler produce a single sound — which means the sampler's own features (bend
range, voice mode, zone mapping) cannot be smoke-tested, by a human or by an
agent, without first sourcing audio from somewhere else. This script writes the
one small one-shot that closes that gap.

Nothing here is sampled from a recording: every byte is a closed-form
expression of the constants below, so the file is bit-reproducible on any
machine with a stdlib Python. Re-running this script over an existing file must
produce a byte-identical result; if it does not, the recipe changed and the
tests pinned to the tone's pitch are measuring something new.

    python3 scripts/make-bundled-samples.py

Recipe (test-tone-a4.wav):
  * 44,100 Hz, mono, 16-bit signed PCM, 15,434 frames — MEASURED, not derived:
    `int(44100 * 0.35)` is 15,434, not 15,435, because the float product is
    15,434.999…, so the file is 0.34998 s rather than a round 0.35.
  * Pitch A4 = 440.0 Hz exactly, i.e. MIDI note 69 — the sampler zone that
    mounts this file uses rootPitch 69 and plays it unshifted there.
  * Harmonics 1.00 / 0.30 / 0.15 at 440 / 880 / 1320 Hz, all sine, zero phase.
    Harmonic content is deliberate: a pure sine is hard to hear as a *note*,
    and a smoke test a human runs has to be audibly obvious. It also means a
    pitch measurement over this file must be autocorrelation-style — naive
    zero-crossing counting sees the harmonics.
  * Amplitude envelope: 5 ms linear attack, then exp(-t / 0.25 s) decay, then a
    20 ms linear fade to true zero at the tail. The gentle decay is on purpose:
    the note must still be sounding (~ -12 dB) at the end of the file so a
    mono-voice-mode takeover test has energy left to see collapse. The final
    fade is on purpose too: a truncated exponential steps to zero at the file
    boundary and clicks.
  * Gain 0.8 / 1.45 (= PEAK / the sum of the harmonic coefficients), applied
    to the harmonic sum before the envelope. That is a worst-case budget: the
    three partials never crest together, so the MEASURED peak sample is 0.626
    of full scale, comfortably clear of clipping.
  * Rounding: round-half-away-from-zero to int16, clamped to [-32768, 32767].
"""

import math
import struct
import wave
from pathlib import Path

SAMPLE_RATE = 44_100
DURATION_SECONDS = 0.35
FUNDAMENTAL_HZ = 440.0
ROOT_MIDI_NOTE = 69
HARMONICS = ((1, 1.00), (2, 0.30), (3, 0.15))
PEAK = 0.8
ATTACK_SECONDS = 0.005
DECAY_TAU_SECONDS = 0.25
FADE_OUT_SECONDS = 0.020

OUTPUT = (
    Path(__file__).resolve().parent.parent
    / "Sources"
    / "DAWCore"
    / "Resources"
    / "BundledSamples"
    / "test-tone-a4.wav"
)


def envelope(t: float, total: float) -> float:
    if t < ATTACK_SECONDS:
        level = t / ATTACK_SECONDS
    else:
        level = math.exp(-(t - ATTACK_SECONDS) / DECAY_TAU_SECONDS)
    fade_start = total - FADE_OUT_SECONDS
    if t > fade_start:
        level *= max(0.0, (total - t) / FADE_OUT_SECONDS)
    return level


def render() -> bytes:
    frames = int(SAMPLE_RATE * DURATION_SECONDS)
    total = frames / SAMPLE_RATE
    gain = PEAK / sum(amplitude for _, amplitude in HARMONICS)
    out = bytearray()
    for frame in range(frames):
        t = frame / SAMPLE_RATE
        value = 0.0
        for partial, amplitude in HARMONICS:
            value += amplitude * math.sin(
                2.0 * math.pi * FUNDAMENTAL_HZ * partial * t
            )
        value *= gain * envelope(t, total)
        scaled = value * 32767.0
        # Round half AWAY FROM ZERO: Python's round() is banker's rounding,
        # which would make the bytes depend on tie-breaking rather than on the
        # formula.
        quantized = int(math.floor(scaled + 0.5)) if scaled >= 0 else int(math.ceil(scaled - 0.5))
        quantized = max(-32768, min(32767, quantized))
        out += struct.pack("<h", quantized)
    return bytes(out)


def main() -> None:
    data = render()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUTPUT), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(data)
    print(f"wrote {OUTPUT} ({OUTPUT.stat().st_size} bytes, "
          f"{len(data) // 2} frames, root MIDI {ROOT_MIDI_NOTE} = {FUNDAMENTAL_HZ} Hz)")


if __name__ == "__main__":
    main()
