#!/usr/bin/env python3
"""Build the film's central demonstration: a rendered mix with three single
BLOCKS of audio replaced by silence, plus the waveform pictures that show it.

⚠ HONESTY. Nothing here crashes or stalls the audio engine. The engine
rendered the clean file correctly; this script then edits the FILE, so what
you hear is a faithful reconstruction of what a missed deadline sounds like,
not a captured failure. The narration says exactly that, and every offset and
length used is written into dropout.json so the claim can be checked.

Block size and sample rate are READ FROM THE LIVE ENGINE (engine.performance
Stats: quantumFrames / sampleRate), not assumed -- see measure.py.
"""
import json, os, subprocess, sys
import numpy as np
import soundfile as sf
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
A, S = f"{HERE}/audio", f"{HERE}/shots"
SRC = f"{A}/mix-clean-full.wav"

BLOCK = int(sys.argv[1]) if len(sys.argv) > 1 else 512   # frames per block
EXC_START, EXC_LEN = 0.0, 12.0                            # excerpt seconds
# ⭐ THE EXCERPT STARTS AT THE TOP OF THE SONG ON PURPOSE: the moving
# shot of the app was filmed from bar one, so the clean half of this
# demonstration is the same twelve seconds the viewer is watching.
DROPS = [2.55, 5.55, 8.55]                                # sec into the excerpt

# ⚠ ONE STATIC GAIN, SHARED BY BOTH HALVES. The project's own render comes out
# at +0.4 dBTP / -8.1 LUFS, and these two files are the film's A/B so they ride
# with "normalize": false — assemble.py must not touch their relative levels.
# Un-gained they SET the master's true peak, and assemble's backstop then
# re-encodes AAC once per retry with zero margin and oscillates instead of
# converging (measured: +0.60 -> -0.80 -> -0.70 -> -0.90 -> -0.40, refused).
# The sanctioned fix, from assemble.play_audio's own docstring, is to pre-gain
# the PAIR by one shared amount. Applied to the excerpt before the blocks are
# zeroed, so clean and broken differ in exactly the same 1536 frames as before
# (g x 0 is still 0) and nothing in the demonstration moves relative to
# anything else. Nothing is compressed and nothing is made louder.
PLAY_GAIN_DB = -6.0

x, sr = sf.read(SRC, always_2d=True)
print(f"  source {x.shape[0]} frames @ {sr} Hz  ({x.shape[0]/sr:.2f}s)")
i0 = int(round(EXC_START * sr))
n = int(round(EXC_LEN * sr))
clean = x[i0:i0 + n].copy() * (10.0 ** (PLAY_GAIN_DB / 20.0))
broken = clean.copy()
print(f"  static gain {PLAY_GAIN_DB:+.1f} dB applied to BOTH halves equally")

marks = []
for d in DROPS:
    s = int(round(d * sr))
    s -= s % BLOCK                     # land on a block boundary, as the engine does
    broken[s:s + BLOCK, :] = 0.0
    marks.append({"startFrame": s, "startSeconds": s / sr,
                  "frames": BLOCK, "milliseconds": 1000.0 * BLOCK / sr})
    print(f"  zeroed block at frame {s} = {s/sr:.4f}s  ({1000*BLOCK/sr:.3f} ms)")

sf.write(f"{A}/mix-clean.wav", clean, sr, subtype="PCM_24")
sf.write(f"{A}/mix-broken.wav", broken, sr, subtype="PCM_24")

# ── prove the edit is exactly what was claimed, by re-reading the files ─────
a = sf.read(f"{A}/mix-clean.wav", always_2d=True)[0]
b = sf.read(f"{A}/mix-broken.wav", always_2d=True)[0]
diff = np.any(a != b, axis=1)
changed = int(diff.sum())
expect = BLOCK * len(DROPS)
runs = []
i = 0
while i < len(diff):
    if diff[i]:
        j = i
        while j < len(diff) and diff[j]:
            j += 1
        runs.append((i, j - i))
        i = j
    else:
        i += 1
print(f"  differing frames {changed} (expected {expect})  runs {runs}")
if changed != expect or len(runs) != len(DROPS) or any(r[1] != BLOCK for r in runs):
    sys.exit("DROPOUT REFUSES: the edit is not exactly three blocks")
if not np.all(b[runs[0][0]:runs[0][0] + BLOCK] == 0.0):
    sys.exit("DROPOUT REFUSES: the zeroed block is not zero")

# ── the pictures ───────────────────────────────────────────────────────────
BG, FG, HOT, DIM = "#0b0d10", "#e8ecf2", "#ff6b5d", "#7a8291"
plt.rcParams.update({"figure.facecolor": BG, "axes.facecolor": BG,
                     "savefig.facecolor": BG, "text.color": FG,
                     "axes.labelcolor": FG, "xtick.color": DIM,
                     "ytick.color": DIM, "font.size": 15})

def frame(ax):
    for sp in ("top", "right"):
        ax.spines[sp].set_visible(False)
    for sp in ("left", "bottom"):
        ax.spines[sp].set_color(DIM)

mono_c, mono_b = a.mean(1), b.mean(1)
t = np.arange(len(a)) / sr

# 1 -- the whole excerpt, clean over broken, with the three marks
fig, axes = plt.subplots(2, 1, figsize=(19.2, 10.8), dpi=100, sharex=True)
for ax, y, lab, col in ((axes[0], mono_c, "CLEAN RENDER", "#5dd0ff"),
                        (axes[1], mono_b, "THREE BLOCKS REPLACED WITH SILENCE", HOT)):
    ax.plot(t, y, lw=0.5, color=col)
    ax.set_ylim(-1.05, 1.05)
    ax.set_ylabel(lab, fontsize=17, labelpad=14)
    frame(ax)
for m in marks:
    axes[1].axvline(m["startSeconds"], color=HOT, lw=1.4, alpha=0.9)
    axes[1].annotate(f'{m["milliseconds"]:.2f} ms', (m["startSeconds"], 0.86),
                     color=HOT, fontsize=15, ha="center",
                     xytext=(0, 8), textcoords="offset points")
axes[1].set_xlabel("seconds", fontsize=16)
axes[0].set_title("Twelve seconds of the same mix", fontsize=26, color=FG, pad=18)
# ⚠ the corner avatar lives bottom-right: keep the caption LEFT of centre
fig.text(0.06, 0.028, "one block = 512 samples at 48 kHz = 10.67 ms",
         color=DIM, fontsize=17)
fig.tight_layout(rect=(0, 0.05, 1, 1))
fig.savefig(f"{S}/wave-full.png"); plt.close(fig)

# 2 -- 60 ms around the first gap, samples visible
m = marks[0]
w = int(0.030 * sr)
lo, hi = m["startFrame"] - w, m["startFrame"] + BLOCK + w
tt = (np.arange(lo, hi) - m["startFrame"]) * 1000.0 / sr
fig, ax = plt.subplots(figsize=(19.2, 10.8), dpi=100)
ax.plot(tt, mono_c[lo:hi], lw=1.6, color="#5dd0ff", label="clean")
ax.plot(tt, mono_b[lo:hi], lw=2.2, color=HOT, label="one block missing")
ax.axvspan(0, 1000.0 * BLOCK / sr, color=HOT, alpha=0.10)
ax.set_xlabel("milliseconds, around the gap", fontsize=18)
ax.set_ylabel("signal", fontsize=18)
ax.set_title("The gap, close up: 512 samples of nothing", fontsize=28, color=FG, pad=18)
ax.legend(frameon=False, fontsize=18, loc="upper left", labelcolor=FG)
frame(ax)
fig.text(0.06, 0.028, "the two vertical steps at the edges are the click you hear",
         color=DIM, fontsize=17)
fig.tight_layout(rect=(0, 0.05, 1, 1))
fig.savefig(f"{S}/wave-zoom.png"); plt.close(fig)

meta = {"sourceRender": SRC, "sampleRate": sr, "blockFrames": BLOCK,
        "blockMilliseconds": 1000.0 * BLOCK / sr,
        "excerptStartSeconds": EXC_START, "excerptSeconds": EXC_LEN,
        "dropouts": marks, "differingFrames": changed,
        "runs": [{"start": r[0], "length": r[1]} for r in runs],
        "playGainDb": PLAY_GAIN_DB,
        "differingFramesPerEar": changed, "channels": int(clean.shape[1]),
        "excerptFramesPerEar": int(clean.shape[0]),
        "method": ("rendered the project offline to a 24-bit WAV over the "
                   "control socket, then wrote zeros over three separate "
                   f"{BLOCK}-frame blocks of that file. The audio engine was "
                   "not stalled, starved or crashed. Both halves were then "
                   f"turned down by the same {PLAY_GAIN_DB:.1f} dB — one static "
                   "gain, no compression — so the film's master would not clip; "
                   "their relative levels are untouched.")}
json.dump(meta, open(f"{HERE}/dropout.json", "w"), indent=1)
print(f"  wrote mix-clean.wav / mix-broken.wav and two charts; "
      f"block {1000*BLOCK/sr:.3f} ms")
