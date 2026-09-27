"""DAW Pro singing sidecar STUB (item p2-sing-b): the facade's exact HTTP API with sine tones instead of a model.
Standard library only; runs under the system /usr/bin/python3 (3.9). It is what the app's manager, job and E2E
tests (p2-sing-c, p2-sing-e, p2-sing-f) spawn instead of the 6 GB model.

It imports the SAME schema, refusal table, converter and HTTP layer as server.py (singlib/), so every 400/403/
404/409/503 it gives is the facade's own. Differences, by design:
  * a render is a sine at each note's target pitch (amplitude 0.1, 10 ms raised-cosine edges) placed on the SAME
    10 ms-rounded boundaries the converter hands the model, silence on rests; about -23 LUFS on a sung line;
  * words are checked with a stand-in for g2p: a word with no letter or digit is `emptyWord`; `unknownPhone`
    never happens (there is no phone set);
  * built-in voice `builtin-1` always exists (placeholder files under <runtime>/run/stub-voices/);
  * the output length is int(time[1]/1000*24000) samples at 24 kHz, scaled to outputSampleRate with round-half-up:
    identical to the facade's soxr length at 24/48/96 kHz, within one sample at other rates.

Faults, chosen at LAUNCH (never over the wire). SING_STUB_FAULT = one of:
  nan        writes a WAV with 64 NaN samples in the first note and still reports "nonFinite": false - a planted
             NaN that got past the facade's own check. The app's L1 gate must catch it from the bytes.
  nonfinite  answers what the real facade answers when the model makes NaN: 500 {"error": "nonFinite"}. (Not in
             the design's list of six; added so the job's one-retry path has a stub.)
  silence    an all-zero WAV of the right length (L2 must fail).
  click      the clean sine plus ONE full-scale sample (1.0) in the second note: lands ceiling-limited (L4 notice).
  crash      the process exits (code 70) mid-request after SING_STUB_CRASH_AFTER_S (0.2 s): no response.
  slow       sleeps SING_STUB_SLOW_S (30 s) before rendering normally (cancel, timeouts, a yield mid-unit).
  balloon    grows to SING_STUB_BALLOON_MB (600) in 64 MiB steps every 50 ms, touching every page, holds it for
             SING_STUB_BALLOON_HOLD_S (60 s), then renders normally (the watchdog's footprint kill).
SING_STUB_FAULT_AFTER (default 0) = the 0-based render index where faults start; SING_STUB_FAULT_COUNT (default:
every render from there) = how many renders get it. E.g. AFTER=0 COUNT=1: the first render is bad, its retry is
clean. SING_STUB_LOAD_S (default 0.5) = how long /health says "loading".

Environment otherwise as server.py (SING_RUNTIME_DIR, SING_PORT, SING_HOST, SING_ALLOWED_ROOTS, SING_TEST_HOOKS).
Launch through run.sh with SING_USE_STUB=1, so the pidfile and the exec are the product's own path.
"""
import argparse
import array
import math
import os
import re
import signal
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from singlib import http as shttp  # noqa: E402
from singlib import schema, score, wavio  # noqa: E402
from singlib.refusals import Refusal  # noqa: E402

FAULTS = ("nan", "nonfinite", "silence", "click", "crash", "slow", "balloon")
AMPLITUDE = 0.1
FADE_S = 0.010
NAN_SAMPLES = 64
MiB = 1 << 20
_LETTER_OR_DIGIT = re.compile(r"[A-Za-z0-9]")


def stub_phonemize(word):
    """g2p stand-in: one dummy phone per word that has a letter or digit; none otherwise (-> emptyWord)."""
    return ["AH0"] if _LETTER_OR_DIGIT.search(word) else []


def out_len(n24, out_sr):
    return n24 if out_sr == score.SAMPLE_RATE else (n24 * out_sr + score.SAMPLE_RATE // 2) // score.SAMPLE_RATE


def synthesize(meta, out_sr):
    """Sine per note entry on the converter's own rounded boundaries; -> (array('f'), [(start, end) samples])."""
    n = out_len(score.output_samples_24k(meta), out_sr)
    y = array.array("f", bytes(4 * n))
    bounds = score.bounds_of(meta)
    pitches = [int(p) for p in meta["note_pitch"].split()]
    spans = []
    for i, p in enumerate(pitches):
        if p <= 0:
            continue
        a, b = int(round(bounds[i] * out_sr)), min(n, int(round(bounds[i + 1] * out_sr)))
        if b <= a:
            continue
        f = 440.0 * 2.0 ** ((p - 69) / 12.0)
        w = 2.0 * math.pi * f / out_sr
        fade = max(1, min(int(FADE_S * out_sr), (b - a) // 2))
        for k in range(b - a):
            g = 1.0
            if k < fade:
                g = 0.5 - 0.5 * math.cos(math.pi * k / fade)
            elif k >= (b - a) - fade:
                g = 0.5 - 0.5 * math.cos(math.pi * ((b - a) - 1 - k) / fade)
            y[a + k] = AMPLITUDE * g * math.sin(w * k)
        spans.append((a, b))
    return y, spans


class StubBackend(object):
    def __init__(self, fault, after, count, load_s, slow_s, balloon_mb, balloon_hold_s, crash_after_s):
        self.fault, self.after, self.count = fault, after, count
        self.load_s, self.slow_s = load_s, slow_s
        self.balloon_mb, self.balloon_hold_s, self.crash_after_s = balloon_mb, balloon_hold_s, crash_after_s
        self.t0 = time.time()
        self.renders = 0
        self.applied = 0
        self.rendered = 0

    def state(self):
        return ("loading", None) if time.time() - self.t0 < self.load_s else ("ready", None)

    def health(self):
        st, _ = self.state()
        return {"status": st, "facadeVersion": 1,
                "engine": {"commit": "stub", "weightsRevision": "stub", "weightsBytes": 0},
                "device": "stub", "pid": os.getpid(), "loadSeconds": self.load_s if st == "ready" else None,
                "mpsDriverBytes": 0, "rendered": self.rendered,
                "stub": {"fault": self.fault, "after": self.after, "count": self.count, "applied": self.applied,
                         "renders": self.renders}}

    def _fault_for(self, idx):
        if not self.fault or idx < self.after:
            return None
        if self.count is not None and self.applied >= self.count:
            return None
        self.applied += 1
        return self.fault

    def _balloon(self):
        held, target = [], self.balloon_mb * MiB
        step = 64 * MiB
        while sum(len(b) for b in held) < target:
            held.append(b"\x5a" * min(step, target - sum(len(b) for b in held)))   # memset: every page touched
            time.sleep(0.05)
        shttp.log("stub balloon holding %d MiB for %.0f s" % (self.balloon_mb, self.balloon_hold_s))
        time.sleep(self.balloon_hold_s)
        del held

    def _check_own_voice(self, v):
        try:
            info, _ = wavio.read_wav(v.reference_real)
        except (OSError, wavio.WavError) as e:
            raise Refusal("badReference", "The voice recording can't be read: %s" % e)
        dur = info["frames"] / float(info["sample_rate"])
        if v.window_end > dur + 0.05:
            raise Refusal("badReference", "The voice window ends at %.2f s, but the recording is only %.2f s long."
                          % (v.window_end, dur))
        win = v.window_end - v.window_start
        if win < schema.MIN_WINDOW_S or win > schema.MAX_WINDOW_S:
            raise Refusal("badReference", "The voice window is %.2f s long; it must be %.0f-%.0f s."
                          % (win, schema.MIN_WINDOW_S, schema.MAX_WINDOW_S))
        score.build_prompt_meta(v.prompt_notes, win, phonemize=stub_phonemize, label_offset=v.label_offset)

    def render(self, req):
        idx = self.renders
        self.renders += 1
        meta, info = score.build_meta(req.notes, req.words, lead=req.lead, trail=req.trail, phonemize=stub_phonemize)
        if req.voice.kind == "own":
            self._check_own_voice(req.voice)
        fault = self._fault_for(idx)
        if fault:
            shttp.log("stub fault %s on render %d" % (fault, idx))
        if fault == "crash":
            time.sleep(self.crash_after_s)
            os._exit(70)
        if fault == "slow":
            time.sleep(self.slow_s)
        if fault == "balloon":
            self._balloon()
        if fault == "nonfinite":
            raise Refusal("nonFinite", "The model produced samples that are not numbers (stub fault); nothing was "
                          "written.")
        y, spans = synthesize(meta, req.out_sr)
        if fault == "silence":
            y = array.array("f", bytes(4 * len(y)))
        elif fault == "nan" and spans:
            a, b = spans[0]
            mid = (a + b) // 2
            for k in range(mid, min(b, mid + NAN_SAMPLES)):
                y[k] = float("nan")
        elif fault == "click" and spans:
            a, b = spans[1] if len(spans) > 1 else spans[0]
            y[(a + b) // 2] = 1.0
        os.makedirs(os.path.dirname(req.output_real), exist_ok=True)
        wavio.write_float32_wav(req.output_real, y, req.out_sr)
        self.rendered += 1
        finite = [abs(v) for v in y if v == v]
        return {"outputPath": req.output_path, "sampleRate": req.out_sr, "channels": 1, "frames": len(y),
                "durationS": round(len(y) / float(req.out_sr), 6),
                "peak": max(finite) if finite else 0.0,
                "rms": math.sqrt(sum(v * v for v in finite) / len(y)) if y else 0.0,
                "nonFinite": False, "seed": req.seed, "nSteps": req.n_steps, "cfg": req.cfg,
                "voice": {"id": req.voice.id, "kind": req.voice.kind}, "entries": info["entries"],
                "samples24k": score.output_samples_24k(meta), "targetMeta": meta,
                "stub": {"fault": fault, "renderIndex": idx}}


def _env_float(name, default):
    v = os.environ.get(name)
    return float(v) if v not in (None, "") else default


def _write_placeholder_voice(voices_dir):
    d = os.path.join(voices_dir, "builtin-1")
    os.makedirs(d, exist_ok=True)
    wav, meta = os.path.join(d, "prompt.wav"), os.path.join(d, "prompt.json")
    if not os.path.isfile(wav):
        wavio.write_float32_wav(wav, array.array("f", bytes(4 * 24000)), 24000)
    if not os.path.isfile(meta):
        wavio.write_atomic(meta, b'[{"note": "stub placeholder for builtin-1"}]')


def main(argv=None):
    ap = argparse.ArgumentParser(description="DAW Pro singing sidecar stub")
    ap.add_argument("--host", default=os.environ.get("SING_HOST", shttp.LOOPBACK))
    ap.add_argument("--port", type=int, default=int(os.environ.get("SING_PORT", "8004")))
    ap.add_argument("--runtime", default=os.environ.get("SING_RUNTIME_DIR"))
    a = ap.parse_args(argv)
    shttp.check_host(a.host)
    if not a.runtime or not os.path.isdir(a.runtime):
        sys.stderr.write("sing-stub: SING_RUNTIME_DIR must name an existing folder (got %r).\n" % a.runtime)
        return 2
    fault = os.environ.get("SING_STUB_FAULT", "") or None
    if fault is not None and fault not in FAULTS:
        sys.stderr.write("sing-stub: unknown SING_STUB_FAULT %r (one of %s).\n" % (fault, ", ".join(FAULTS)))
        return 2
    count = os.environ.get("SING_STUB_FAULT_COUNT", "")
    backend = StubBackend(
        fault=fault, after=int(os.environ.get("SING_STUB_FAULT_AFTER", "0") or 0),
        count=int(count) if count not in ("", "all") else None,
        load_s=_env_float("SING_STUB_LOAD_S", 0.5), slow_s=_env_float("SING_STUB_SLOW_S", 30.0),
        balloon_mb=int(_env_float("SING_STUB_BALLOON_MB", 600)),
        balloon_hold_s=_env_float("SING_STUB_BALLOON_HOLD_S", 60.0),
        crash_after_s=_env_float("SING_STUB_CRASH_AFTER_S", 0.2))
    runtime = os.path.realpath(a.runtime)
    voices_dir = os.path.join(runtime, "run", "stub-voices")
    _write_placeholder_voice(voices_dir)
    roots = schema.roots_from_env(os.environ.get("SING_ALLOWED_ROOTS"), always=[voices_dir])
    pidfile = os.path.join(runtime, "run", "sing.pid")

    def remove_own_pidfile():
        try:
            with open(pidfile) as f:
                if f.readline().strip() == str(os.getpid()):
                    os.remove(pidfile)
        except OSError:
            pass
    try:
        server = shttp.make_server(a.port, backend, roots, voices_dir, os.environ.get("SING_TEST_HOOKS") == "1")
    except OSError as e:
        sys.stderr.write("sing-stub: cannot listen on %s:%d: %s\n" % (shttp.LOOPBACK, a.port, e))
        remove_own_pidfile()
        return 3

    def on_signal(signum, frame):
        remove_own_pidfile()
        os._exit(0)
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, on_signal)
    shttp.log("STUB pid %d listening on %s:%d (fault %s after %d count %s; allowed roots %s)"
              % (os.getpid(), shttp.LOOPBACK, a.port, fault, backend.after, backend.count, roots))
    server.serve_forever(poll_interval=0.25)
    return 0


if __name__ == "__main__":
    sys.exit(main())
