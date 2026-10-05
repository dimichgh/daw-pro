#!/usr/bin/env python3
"""Does the FILM's audio actually line up with the notes the picture is drawing?

This is the gate that replaces the narration content check on a wordless short.
A level meter, a duration check and a distinct-frames check all pass happily on
a film whose audio is a different piece of music, or is offset by half a second
from the falling notes — which on THIS pipeline is the whole ballgame, because
the picture is generated from song.json and the sound is rendered by the DAW,
two entirely independent paths that agree only by construction.

    python3 sync.py film.mp4 song.json [--offset-tol 0.05]

Method: spectral-flux onset detection on the film's own audio track, versus the
note onsets computed from song.json's tempo map. For each detected onset, the
distance to the nearest expected onset. A film in sync has a tight distribution
centred on zero.

⭐ THE CONTROL, and it is the point: the same statistic is recomputed against
the expectation shifted by ±0.5 s and against the expectation TIME-REVERSED. If
those score as well as the real one, the statistic cannot tell sync from
nonsense and the result is BROKEN rather than ok.
"""
import argparse, json, subprocess, sys, tempfile, os
import numpy as np

SR = 22050


def audio(path):
    with tempfile.TemporaryDirectory() as d:
        w = os.path.join(d, "a.wav")
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", path,
                        "-ac", "1", "-ar", str(SR), "-f", "wav", w], check=True)
        import wave
        wf = wave.open(w, "rb")
        x = np.frombuffer(wf.readframes(wf.getnframes()), np.int16).astype(np.float32) / 32768.0
        wf.close()
    return x


def onsets(x, hop=256, win=1024, thresh=1.7):
    n = 1 + (len(x) - win) // hop
    frames = np.lib.stride_tricks.as_strided(
        x, (n, win), (x.strides[0] * hop, x.strides[0])) * np.hanning(win)
    S = np.abs(np.fft.rfft(frames, axis=1))
    flux = np.maximum(0.0, S[1:] - S[:-1]).sum(1)
    flux /= (flux.max() + 1e-9)
    # local-mean adaptive threshold, then keep the local maximum of each burst
    k = 20
    pad = np.pad(flux, (k, k), mode="edge")
    loc = np.array([pad[i:i + 2 * k + 1].mean() for i in range(len(flux))])
    peak = (flux[1:-1] > flux[:-2]) & (flux[1:-1] >= flux[2:]) & \
           (flux[1:-1] > thresh * loc[1:-1] + 0.004)
    idx = np.nonzero(peak)[0] + 1
    return (idx * hop + win / 2) / SR


class Timing:
    def __init__(self, segs):
        self.segs = sorted(segs, key=lambda s: s["startBeat"])
        self.t0 = [0.0]
        for a, b in zip(self.segs, self.segs[1:]):
            self.t0.append(self.t0[-1] + (b["startBeat"] - a["startBeat"]) * 60.0 / a["bpm"])

    def secs(self, beat):
        i = max(k for k, s in enumerate(self.segs) if s["startBeat"] <= beat)
        return self.t0[i] + (beat - self.segs[i]["startBeat"]) * 60.0 / self.segs[i]["bpm"]


def score(det, exp, tol):
    """(matched fraction, median signed offset) of detected onsets vs expected."""
    if len(det) == 0 or len(exp) == 0:
        return 0.0, 0.0
    j = np.searchsorted(exp, det)
    j = np.clip(j, 1, len(exp) - 1)
    lo, hi = exp[j - 1], exp[j]
    near = np.where(np.abs(det - lo) < np.abs(det - hi), lo, hi)
    d = det - near
    return float((np.abs(d) <= tol).mean()), float(np.median(d))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("film")
    ap.add_argument("song")
    ap.add_argument("--lead", type=float, default=0.0,
                    help="seconds of film BEFORE beat 0 (an intro card)")
    ap.add_argument("--tol", type=float, default=0.035)
    # ⭐ THE ROADS SERIES SCORES THE MELODY ALONE AS WELL AS THE WHOLE MIX.
    # "The light lands on the onset" is a claim about ONE line; a pad and a bass
    # under it add onsets the light was never supposed to mark, which moves the
    # matched fraction for reasons that have nothing to do with the gate.
    ap.add_argument("--road-only", action="store_true",
                    help="score only the track carrying \"road\": true")
    # ⭐ ROUND 4 (roads/00-sample): a SIBLING, not a relaxation. --road-only
    # deliberately refuses more than one road track, because "the light lands on
    # the onset" is a claim about ONE line and other films depend on that
    # refusal. With a road PER INSTRUMENT TRACK the claim generalises -- every
    # road onset is marked by its own road's light -- so the union is the right
    # expectation set. Kept as a separate flag so no existing gate loosens.
    ap.add_argument("--roads", action="store_true",
                    help="score the UNION of every track carrying \"road\": true "
                         "(the multi-road generalisation of --road-only)")
    a = ap.parse_args()
    song = json.load(open(a.song))
    T = Timing(song["tempoSegments"])
    road_mode = a.road_only or a.roads
    trks = [t for t in song["tracks"] if t.get("road")] if road_mode else song["tracks"]
    if a.road_only and len(trks) != 1:
        print(f"[BROKEN] sync: --road-only found {len(trks)} road tracks, need 1 "
              f"(use --roads for the multi-road generalisation)")
        return 2
    if a.roads and len(trks) < 1:
        print("[BROKEN] sync: --roads found no track carrying \"road\": true")
        return 2
    if a.roads:
        print(f"  sync: scoring the UNION of {len(trks)} road tracks "
              f"({', '.join(t.get('label', t['name']) for t in trks)})")
    exp = np.array(sorted({round(T.secs(n[0]) + a.lead, 4)
                           for t in trks for n in t["notes"]}))
    x = audio(a.film)
    det = onsets(x)
    # only judge inside the music, not the outro card
    det = det[(det >= exp[0] - 0.3) & (det <= exp[-1] + 1.0)]
    # ⚠⚠ --road-only SCORES THE OTHER WAY ROUND, and it has to. The detector
    # hears the WHOLE mix; the expectation is one line out of four. Asking "what
    # fraction of DETECTED onsets sit near a MELODY onset" counts every harp and
    # bass note as a miss and reports a perfectly synchronised film at ~40 %.
    # The question the light actually poses is the converse -- "does every
    # melody onset have a sound at it" -- so in this mode the two sets swap, and
    # the median offset swaps sign with them.
    flip = -1.0 if road_mode else 1.0
    if road_mode:
        det, exp = exp, det
    m, off = score(det, exp, a.tol)
    off *= flip
    # ⚠⚠ THE CONTROL SHIFT MUST NOT BE COMMENSURATE WITH THE GRID. A first cut
    # shifted by a fixed 0.5 s; this music is eighth notes at 116 BPM, so 0.5 s
    # is 1.93 eighths and the shifted expectation landed back ON the grid --
    # every control scored 91% against a 93% real match and the gate reported a
    # failure the film had not earned. Half the MEDIAN inter-onset gap is the
    # maximally wrong place for a grid to be, whatever the tempo.
    gap = float(np.median(np.diff(exp))) if len(exp) > 2 else 0.5
    ctrl = {}
    ctrl[f"shift +{gap/2*1000:.0f}ms"] = score(det, exp + gap / 2, a.tol)[0]
    ctrl[f"shift -{gap/2*1000:.0f}ms"] = score(det, exp - gap / 2, a.tol)[0]
    # ⚠⚠ TIME-REVERSAL IS NOT A CONTROL FOR METRICAL MUSIC, and this is measured,
    # not reasoned: on the canon it scored 84.1% against an 85.7% real match.
    # Reversing a set of onsets that sit on a regular grid gives back the SAME
    # grid. The control that does work is a random set of the same density over
    # the same span -- it has the right chance of a coincidental hit and none of
    # the right structure.
    rng = np.random.default_rng(20260906)
    ctrl["random, same density"] = score(
        det, np.sort(rng.uniform(exp[0], exp[-1], len(exp))), a.tol)[0]
    # ⚠⚠ WHICH CONTROL THE VERDICT USES, and why it is NOT the random one.
    # A random time has probability ~1-exp(-2*tol*density) of landing within tol
    # of SOME onset purely by chance. On the cascade -- sixteenths at 132 BPM,
    # one onset every 114 ms -- that expectation is 46%, and it was MEASURED at
    # 46.0%. So on dense material the random control is not measuring sync at
    # all, it is measuring the density, and using it as the adversary would fail
    # a perfectly synchronised film for being fast. The adversary that has the
    # SAME density and the WRONG phase is the half-gap shift, and that is the one
    # the verdict reads. The random figure is still printed, next to its own
    # analytic expectation, so a reader can see it saturating rather than take
    # this on trust.
    dens = len(exp) / max(1e-6, exp[-1] - exp[0])
    print(f"  (random control's chance expectation at this density: "
          f"{100*(1-np.exp(-2*a.tol*dens)):.0f}%)")
    worst = max(v for k, v in ctrl.items() if k.startswith("shift"))
    if road_mode:
        print(f"  melody onsets {len(det)}  audio onsets detected {len(exp)}  "
              f"(sets are SWAPPED in --road-only: see the note above)")
    else:
        print(f"  onsets detected {len(det)}  expected {len(exp)}")
    print(f"  matched within {a.tol*1000:.0f} ms: {m*100:.1f}%   median offset {off*1000:+.1f} ms")
    # ⭐ DRIFT BY THIRDS. A single median hides a picture that starts in sync and
    # ends half a bar out -- which is exactly what a tempo-map disagreement would
    # look like, and this series has an accelerando in it.
    edges = np.linspace(exp[0], exp[-1], 4)
    for k in range(3):
        seg = det[(det >= edges[k]) & (det < edges[k + 1])]
        if len(seg) > 4:
            mk, ok_ = score(seg, exp, a.tol)
            ok_ *= flip
            print(f"  third {k+1}: {len(seg):3d} onsets  matched {mk*100:5.1f}%  "
                  f"median offset {ok_*1000:+6.1f} ms")
    for k, v in ctrl.items():
        print(f"  control {k:12s} {v*100:.1f}%")
    # DRIFT is the second criterion and the one an accelerando needs: a constant
    # offset is the detector's own latency, a GROWING one is a tempo-map
    # disagreement between the picture and the sound.
    offs = []
    for k in range(3):
        seg = det[(det >= edges[k]) & (det < edges[k + 1])]
        if len(seg) > 4:
            offs.append(score(seg, exp, a.tol)[1])
    drift = (max(offs) - min(offs)) if len(offs) == 3 else 0.0
    print(f"  drift across the piece: {drift*1000:.1f} ms "
          f"(one frame at 30 fps is 33.3 ms)")
    if m < 2.0 * worst or m < 0.55:
        print(f"[ FAIL ] sync: {m*100:.1f}% matched against a {worst*100:.1f}% "
              "wrong-phase control")
        return 1
    if drift > 0.0333:
        print(f"[ FAIL ] sync: {drift*1000:.1f} ms of drift across the piece — over one frame")
        return 1
    if worst > 0.45:
        print(f"[BROKEN] sync: a wrong-phase control matched {worst*100:.1f}% — the "
              "statistic cannot tell sync from nonsense here")
        return 2
    print(f"[  ok  ] sync: {m*100:.1f}% matched vs {worst*100:.1f}% wrong-phase control, "
          f"offset {off*1000:+.1f} ms, drift {drift*1000:.1f} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
