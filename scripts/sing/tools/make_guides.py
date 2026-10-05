"""The two sing-along guide tunes for Fixture P1 ("Row, row, row your boat, gently down the stream"): the tunes the
"Add your voice" recorder plays (design §3.7, §3.8, §5.4). Ported unchanged in its arithmetic from SING-6's
make_guides.py (scratchpad w6/SING6), whose outputs are the files the user recorded against:
  row-guide-high.wav sha256 2b16520a3e7617789a8852e03ae45ba6fe15b53d00372d686f2a0c6c129535cb (C4)
  row-guide-low.wav  sha256 05608e40c4a7e2344485f7dd31823ae70b4714761e75e96a9f2966f67953264c (C3)
tests/test_make_guides.py rebuilds both and compares those bytes.

Deterministic (no RNG): the same bytes on every run. numpy + stdlib `wave`; pyloudnorm and scipy only set the level.
Needs the runtime venv (numpy, scipy, pyloudnorm are all in requirements.lock).

Layout (48 kHz, mono, 16-bit):
  0.25 s silence (so a browser player does not swallow the first click)
  4 count-in clicks, one bar of 4 at 100 BPM (0.6 s apart; the first is accented)
  the melody, 8 beats = 4.8 s, in a soft mallet-into-flute tone (additive harmonics, no vibrato)
  1.0 s of digital silence at the end
Each note sounds for its length minus a 45 ms articulation gap, so repeated notes ("Row, row, row") re-attack.
Every tail ends inside its own note window (no overlap between notes).

Level: scaled so integrated loudness (BS.1770, pyloudnorm) = -18.0 LUFS; REFUSES to write if the 4x-oversampled
true peak would exceed -1.5 dBTP (no limiter, no silent clipping).

Usage: python make_guides.py OUTDIR [--detune-cents C --only high|low --name NAME]   (the detune form is a gate CONTROL)
"""
import argparse
import json
import os
import wave

import numpy as np

SR = 48000
BPM = 100.0
BEAT = 60.0 / BPM
LEAD_SILENCE = 0.25
COUNT_IN_BEATS = 4
TAIL_SILENCE = 1.0
ARTIC_GAP = 0.045
TARGET_LUFS = -18.0
TP_REFUSE = -1.5

# Fixture P1 as written in the brief, relative to the starting C: (syllable, semitones above the start, beats)
P1 = [("Row", 0, 1.0), ("row", 0, 1.0), ("row", 0, 0.75), ("your", 2, 0.25), ("boat", 4, 1.0),
      ("gent-", 4, 0.75), ("-ly", 2, 0.25), ("down", 4, 0.75), ("the", 5, 0.25), ("stream", 7, 2.0)]
START_MIDI = {"high": 60, "low": 48}          # C4 / C3

# tone: harmonic n has amplitude 1/n^1.3; it decays from its attack level towards a sustain of 0.5/n with
# time constant 0.35/sqrt(n) s (a soft mallet onset that settles into a flute-like held tone)
N_HARM = 8


def midi_hz(m, cents=0.0):
    return 440.0 * 2.0 ** ((m - 69) / 12.0 + cents / 1200.0)


def raised_cos(n):
    return 0.5 - 0.5 * np.cos(np.pi * np.arange(n) / max(n, 1))


def note(f0, dur_s):
    sound = dur_s - ARTIC_GAP
    n = int(round(sound * SR))
    t = np.arange(n) / SR
    y = np.zeros(n)
    for h in range(1, N_HARM + 1):
        fh = f0 * h
        if fh > 0.45 * SR:
            break
        amp = 1.0 / h ** 1.3
        sus = 0.5 / h
        tau = 0.35 / np.sqrt(h)
        env = sus + (1.0 - sus) * np.exp(-t / tau)
        y += amp * env * np.sin(2 * np.pi * fh * t)
    a = int(0.006 * SR)
    r = min(int(0.050 * SR), n // 2)
    y[:a] *= raised_cos(a)
    y[n - r:] *= raised_cos(r)[::-1]
    return y


def click(accent):
    n = int(0.060 * SR)
    t = np.arange(n) / SR
    f = 2000.0 if accent else 1500.0
    y = np.sin(2 * np.pi * f * t) * np.exp(-t / 0.012)
    a = int(0.001 * SR)
    y[:a] *= raised_cos(a)
    return y


def build(start_midi, detune_cents=0.0):
    mel_start = LEAD_SILENCE + COUNT_IN_BEATS * BEAT
    mel_beats = sum(b for _, _, b in P1)
    total = mel_start + mel_beats * BEAT + TAIL_SILENCE
    y = np.zeros(int(round(total * SR)))
    for k in range(COUNT_IN_BEATS):
        c = 0.55 * click(k == 0)
        i = int(round((LEAD_SILENCE + k * BEAT) * SR))
        y[i:i + len(c)] += c
    t_beat = 0.0
    layout = []
    for syl, semis, beats in P1:
        m = start_midi + semis
        s = mel_start + t_beat * BEAT
        x = note(midi_hz(m, detune_cents), beats * BEAT)
        i = int(round(s * SR))
        y[i:i + len(x)] += x
        layout.append({"syllable": syl, "midi": m, "start_s": round(s, 4), "end_s": round(s + beats * BEAT, 4)})
        t_beat += beats
    return y, layout, total


def loud_scale(y):
    import pyloudnorm as pyln
    from scipy.signal import resample_poly
    I = pyln.Meter(SR).integrated_loudness(y)
    z = y * 10 ** ((TARGET_LUFS - I) / 20)
    tp = 20 * np.log10(np.max(np.abs(resample_poly(z, 4, 1))) + 1e-12)
    return z, I, tp


def write16(path, z):
    q = np.clip(np.round(z * 32767.0), -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(q.tobytes())


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir")
    ap.add_argument("--detune-cents", type=float, default=0.0)
    ap.add_argument("--only", choices=["high", "low"])
    ap.add_argument("--name")
    a = ap.parse_args(argv)
    os.makedirs(a.outdir, exist_ok=True)
    rec = {}
    for key in (["high", "low"] if not a.only else [a.only]):
        y, layout, total = build(START_MIDI[key], a.detune_cents)
        z, I_raw, tp = loud_scale(y)
        if tp > TP_REFUSE:
            raise SystemExit(f"{key}: true peak {tp:.2f} dBTP after loudness match would exceed {TP_REFUSE}; refusing to write")
        name = a.name or f"row-guide-{key}.wav"
        p = os.path.join(a.outdir, name)
        write16(p, z)
        rec[key] = {"path": p, "start_midi": START_MIDI[key], "detune_cents": a.detune_cents, "duration_s": round(len(z) / SR, 4),
                    "pre_scale_lufs": round(float(I_raw), 2), "predicted_tp_dbtp": round(float(tp), 2), "layout": layout}
        print(f"{key}: wrote {p} ({len(z) / SR:.3f} s), predicted TP {tp:.2f} dBTP")
    print(json.dumps(rec)[:400])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
