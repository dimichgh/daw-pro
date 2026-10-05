#!/usr/bin/env python3
"""The PREDICTIONS, computed from the parameters alone and written down BEFORE
anything is rendered.

⭐ THIS FILE IS THE POINT OF THE EPISODE. A compressor's behaviour is arithmetic,
so every claim can be predicted and then checked against a real render. If a
measurement disagrees with its prediction, that is either a bug in our
compressor or an error in the lesson, and either one is worth more than the
video.

The gain computer is `Sources/DAWEngine/Effects/CompressorEffect.swift:280`,
a quadratic soft knee in the log domain:

    slope = 1/ratio - 1                        (negative: it REDUCES)
    over  = levelDb - thresholdDb
    2*over <= -knee  ->  0                     (below the knee: untouched)
    2*over >=  knee  ->  slope * over          (above it: the ratio line)
    otherwise        ->  slope * (over + knee/2)^2 / (2*knee)

⚠️ THE DETECTOR IS PEAK, not RMS (`level = max(peak, level*decay)`), so every
level below is a PEAK level and every measurement must be a peak too. Comparing
a peak prediction against an RMS measurement would disagree by ~3 dB on a sine
and look exactly like a broken compressor.
"""
import json


def reduction_db(level_db, threshold_db, ratio, knee_db):
    """Gain reduction in dB (positive = quieter), steady state."""
    slope = 1.0 / ratio - 1.0
    over = level_db - threshold_db
    if knee_db > 0 and -knee_db < 2 * over < knee_db:
        t = over + knee_db / 2.0
        target = slope * t * t / (2.0 * knee_db)
    elif 2 * over >= knee_db:
        target = slope * over
    else:
        target = 0.0
    return -target


# Demo 1 — threshold + ratio decide HOW MUCH. Hard knee, so the arithmetic is
# the plain ratio line and nothing else. The input level is MEASURED from the
# bypassed render rather than assumed, so this is a function, not a constant.
D1 = dict(thresholdDb=-18.0, ratio=4.0, kneeDb=0.0, attackMs=1.0, releaseMs=100.0)
D1_CONTROL = dict(D1, ratio=1.0)          # unity: MUST measure 0.0 dB

# Demo 4 — the knee demo nobody does: a tone JUST BELOW threshold.
# Hard knee does nothing at all; a soft knee is already working.
D4_HARD = dict(thresholdDb=-18.0, ratio=4.0, kneeDb=0.0)
D4_SOFT = dict(thresholdDb=-18.0, ratio=4.0, kneeDb=24.0)
D4_TONE_BELOW_DB = -20.0                  # 2 dB under the threshold

if __name__ == "__main__":
    out = {
        "_note": "written BEFORE the renders; measure.py checks against it",
        "d4_tone_db": D4_TONE_BELOW_DB,
        "d4_hard_predicted_gr_db": round(reduction_db(D4_TONE_BELOW_DB, D4_HARD["thresholdDb"], D4_HARD["ratio"], D4_HARD["kneeDb"]), 4),
        "d4_soft_predicted_gr_db": round(reduction_db(D4_TONE_BELOW_DB, D4_SOFT["thresholdDb"], D4_SOFT["ratio"], D4_SOFT["kneeDb"]), 4),
        # a worked example at a level we will not necessarily hit, to show the shape
        "d1_example_input_db": -6.0,
        "d1_example_predicted_gr_db": round(
            reduction_db(-6.0, D1["thresholdDb"], D1["ratio"], D1["kneeDb"]), 4),
        "d1_control_predicted_gr_db": round(
            reduction_db(-6.0, D1_CONTROL["thresholdDb"], D1_CONTROL["ratio"],
                         D1_CONTROL["kneeDb"]), 4),
    }
    print(json.dumps(out, indent=1))
