#!/usr/bin/env python3
"""Every wav the film plays, from the renders staging produced.

⚠ ONE SHARED STATIC GAIN, NEVER A PER-HALF NORMALISE. The flam pair's whole
point is that the two files differ in TIMING and not in level; loudnorm on each
half separately would flatten or invert exactly the thing being demonstrated.
Both halves get MIX_TRIM_DB and nothing else, and the spec sets
`normalize: false` on the A/B.

⚠ MIX_TRIM_DB LIVES HERE AND NOWHERE ELSE. Part 3 learned this the expensive
way: the same number in two files drifted (30 vs 14) and only a spec-level
assertion caught it.
"""
import json, os, sys
import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
A = f"{HERE}/audio"
SR = 48000
MIX_TRIM_DB = 0.0      # the project render is already hot enough; see NOTES
FLAM_TRIM_DB = 0.0     # the woodblock pair peaks at -11.75 dBFS: a sparse transient
                       # demo is judged by PEAK, not RMS, and -11.75 is plainly
                       # audible on a laptop speaker. Its RMS is low only because
                       # most of the excerpt is silence between hits.


def rd(name):
    x, sr = sf.read(f"{A}/{name}", dtype="float32", always_2d=True)
    assert sr == SR, (name, sr)
    return x


def wr(name, x):
    sf.write(f"{A}/{name}", x, SR, subtype="FLOAT")
    m = float(np.abs(x).max())
    rms = float(np.sqrt((x.astype(np.float64) ** 2).mean()))
    print(f"  {name:26s} {len(x)/SR:6.2f}s  peak {20*np.log10(m):7.2f}  "
          f"rms {20*np.log10(rms):7.2f} dBFS")


g = lambda db: 10 ** (db / 20)

# 1. the project, for the "here it is working" segment and the beds
mix = rd("mix-full.wav") * g(MIX_TRIM_DB)
wr("mix-clean.wav", mix[: int(16.5 * SR)])
# ⚠ NEVER read and write the same name: the first draft did, so every re-run
# attenuated soft.wav AGAIN (it reached -23 dBFS peak on the second pass) and
# nothing errored. Source and product have different names now.
soft = rd("soft.wav") * g(MIX_TRIM_DB - 5.0)
wr("soft-bed.wav", soft)

# 2. the flam pair — ONE shared gain, so the A/B is a timing demonstration
tog, apt = rd("flam-together.wav"), rd("flam-apart.wav")
n = min(len(tog), len(apt))
tog, apt = tog[:n] * g(FLAM_TRIM_DB), apt[:n] * g(FLAM_TRIM_DB)
wr("flam-together-play.wav", tog)
wr("flam-apart-play.wav", apt)

# ⚠ ASSERT THE RELATIONSHIP SURVIVED. One shared gain must move both halves by
# exactly the same amount; anything else means the pair was normalised.
raw_t, raw_a = rd("flam-together.wav")[:n], rd("flam-apart.wav")[:n]
d0 = 20 * np.log10(np.sqrt((raw_a.astype(np.float64) ** 2).mean())
                   / np.sqrt((raw_t.astype(np.float64) ** 2).mean()))
d1 = 20 * np.log10(np.sqrt((apt.astype(np.float64) ** 2).mean())
                   / np.sqrt((tog.astype(np.float64) ** 2).mean()))
if abs(d0 - d1) > 1e-6:
    sys.exit(f"AUDIOPREP REFUSES — the pair's relationship moved: {d0:.9f} -> {d1:.9f} dB")
print(f"  A/B relationship preserved to {abs(d0-d1):.2e} dB (source delta {d0:+.3f} dB)")
json.dump({"mixTrimDb": MIX_TRIM_DB, "flamTrimDb": FLAM_TRIM_DB,
           "flamSourceDeltaDb": round(float(d0), 4)},
          open(f"{HERE}/audio.json", "w"), indent=1)
