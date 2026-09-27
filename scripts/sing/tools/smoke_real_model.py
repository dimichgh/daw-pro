"""One real-model smoke of the facade: T1 renders, and the prompt-f0 NULL TEST (design §7.6) passes.
Item p2-sing-b's gate; p2-sing-g can re-run it on staging. Standard library only (any python3 >= 3.9).

It talks to an ALREADY RUNNING facade that was launched through run.sh with SING_TEST_HOOKS=1. It never starts or
stops anything: whoever launched the sidecar stops it, pid-exact.

Checks (each an assertion on the WRITTEN BYTES or on the reply):
  0  while the model loads, a render is refused 503 "loading" ("ready" means ready) - when the load is caught;
  1  /health is ready: facadeVersion 1, device mps, the engine commit, the weights' size;
  2  T1 with the built-in voice at 24 kHz: 200; the reply's targetMeta dumps to --t1-json's bytes (the real g2p_en,
     end to end); the file is float32 mono 24000 Hz with 241920 frames; every sample finite; audible; the reply's
     outputSha256/pcmSha256 are the file's;
  3  T1 at 48 kHz (through soxr VHQ): 483840 frames, finite, audible;
  4  THE NULL TEST, own voice, one process, one seed, 24 kHz:
        a  no prompt f0             b  a full-length prompt f0 (the prompt's mel frames + 1)
        a2 a again                  c  a SHORT prompt f0 (it truncates the prompt)      e  seed + 1
     PASS iff sha(a) == sha(b)  (the null test)
          and sha(a) == sha(a2) (same-process determinism: without it the null test means nothing)
          and sha(c) != sha(a)  (the hook reaches DataProcessor: without it the null test is vacuous)
          and sha(e) != sha(a)  (the output depends on the seed at all);
  5  refusals from the real engine: emptyWord, pathNotAllowed, voiceNotFound, referenceChanged.
Optionally (--spike-render) the T1 24 kHz samples are compared with the spike's own render of the same inputs:
INFORMATIVE only (cross-process identity is unmeasured, design §4.3).

Usage:
  smoke_real_model.py --port 18004 --out <folder inside SING_ALLOWED_ROOTS> --t1-json <spike T1.json>
                      --own-reference <wav inside SING_ALLOWED_ROOTS> --own-labels <upstream metadata json>
                      [--outside <a .wav path outside the roots>] [--spike-render <wav>] [--seed 20260924]
Writes <out>/summary.json and prints it. Exit 0 iff every check passed.
"""
import argparse
import array
import hashlib
import json
import math
import os
import sys
import time
import urllib.error
import urllib.request

SING = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if SING not in sys.path:
    sys.path.insert(0, SING)
from singlib import score, wavio  # noqa: E402

SPB = 0.6
T1_NOTES = [(60, 0, 1), (60, 1, 1), (67, 2, 1), (67, 3, 1), (69, 4, 1), (69, 5, 1), (67, 6, 2),
            (65, 8, 1), (65, 9, 1), (64, 10, 1), (64, 11, 1), (62, 12, 1), (62, 13, 1), (60, 14, 2)]
T1_WORDS = [("Twinkle", [0, 1]), ("twinkle", [2, 3]), ("little", [4, 5]), ("star", [6]), ("how", [7]), ("I", [8]),
            ("wonder", [9, 10]), ("what", [11]), ("you", [12]), ("are", [13])]
AUDIBLE_PEAK, AUDIBLE_RMS = 0.02, 0.002


def call(port, method, path, body=None, timeout=600):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read()), time.time() - t0
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null"), time.time() - t0


def sha(b):
    return hashlib.sha256(b).hexdigest()


def t1_request(output_path, voice, seed, sr, **over):
    req = {"facadeVersion": 1, "voice": voice,
           "phrase": {"notes": [{"startS": sb * SPB, "endS": (sb + lb) * SPB, "midi": p} for p, sb, lb in T1_NOTES],
                      "words": [{"text": t, "noteIndices": list(i)} for t, i in T1_WORDS]},
           "leadS": 0.24, "trailS": 0.24, "seed": seed, "nSteps": 32, "cfg": 3.0,
           "outputPath": output_path, "outputSampleRate": sr}
    req.update(over)
    return req


def own_voice_from_labels(reference, labels_json, voice_id="smoke-own-voice"):
    """An own voice whose prompt labels are an upstream metadata file's notes (window = the whole reference)."""
    with open(labels_json, encoding="utf-8") as f:
        meta = json.load(f)
    meta = meta[0] if isinstance(meta, list) else meta
    durs = [float(x) for x in meta["duration"].split()]
    texts, pitches, types = meta["text"].split(), meta["note_pitch"].split(), meta["note_type"].split()
    t, notes = 0.0, []
    for d, w, p, ty in zip(durs, texts, pitches, types):
        if w != score.SP and int(p) > 0:
            notes.append({"startS": round(t, 6), "endS": round(t + d, 6), "midi": int(p), "word": w,
                          "continues": ty == "3"})
        t += d
    with open(reference, "rb") as f:
        ref_sha = sha(f.read())
    info, _ = wavio.read_wav(reference)
    return {"id": voice_id, "referencePath": reference, "referenceSha256": ref_sha,
            "prompt": {"windowStartS": 0.0, "windowEndS": round(min(t, info["frames"] / float(info["sample_rate"])), 6),
                       "notes": notes},
            "promptLabelOffset": 0}


def audio_facts(path, reply):
    info, blob = wavio.read_wav(path)
    y, sr = wavio.read_float32_mono(path)
    finite = all(math.isfinite(v) for v in y)
    peak = max(abs(v) for v in y) if finite and len(y) else float("nan")
    rms = math.sqrt(sum(v * v for v in y) / len(y)) if finite and len(y) else float("nan")
    data = blob[info["data_offset"]:info["data_offset"] + info["data_size"]]
    return {"format": info["format"], "channels": info["channels"], "sampleRate": sr, "frames": info["frames"],
            "finite": finite, "peak": peak, "rms": rms, "fileSha256": sha(blob), "pcmSha256": sha(data),
            "replyMatchesFile": reply.get("outputSha256") == sha(blob) and reply.get("pcmSha256") == sha(data),
            "audible": finite and peak >= AUDIBLE_PEAK and rms >= AUDIBLE_RMS}


class Smoke(object):
    def __init__(self, a):
        self.a = a
        self.checks = []
        self.summary = {"started": time.strftime("%Y-%m-%d %H:%M:%S"), "port": a.port, "renders": {}}

    def check(self, name, ok, detail=None):
        self.checks.append({"check": name, "pass": bool(ok), "detail": detail})
        sys.stderr.write("%s  %s%s\n" % ("PASS" if ok else "FAIL", name, "" if detail is None else "  " + str(detail)))
        return ok

    def render(self, tag, body, expect=200):
        st, reply, took = call(self.a.port, "POST", "/v1/sing/phrase", body)
        rec = {"status": st, "seconds": round(took, 3)}
        if st == 200:
            rec.update({k: reply.get(k) for k in ("frames", "sampleRate", "inferSeconds", "rtf", "totalSeconds",
                                                  "mpsDriverBytes", "entries", "targetFrames", "modelSamples24k",
                                                  "samples24k", "outputSha256", "pcmSha256", "voice", "seed")})
            rec["audio"] = audio_facts(reply["outputPath"], reply)
        else:
            rec["reply"] = reply
        self.summary["renders"][tag] = rec
        if expect is not None and st != expect:
            self.check("%s answered %d" % (tag, expect), False, {"status": st, "reply": reply})
        return st, reply, rec

    def run(self):
        a = self.a
        os.makedirs(a.out, exist_ok=True)
        builtin = {"id": "builtin-1"}
        # 0 + 1: health; a render while loading is refused
        t0 = time.time()
        first = None
        while time.time() - t0 < a.health_timeout:
            try:
                st, h, _ = call(a.port, "GET", "/health", timeout=5)
            except OSError:
                time.sleep(0.5)
                continue
            first = first or h.get("status")
            if h.get("status") == "loading" and "loading" not in self.summary["renders"]:
                st2, reply, _ = call(a.port, "POST", "/v1/sing/phrase",
                                     t1_request(os.path.join(a.out, "loading.wav"), builtin, a.seed, 24000))
                self.summary["renders"]["loading"] = {"status": st2, "reply": reply}
                self.check("0 a render while loading is refused 503 loading", st2 == 503 and reply.get("error") == "loading",
                           reply)
            if h.get("status") in ("ready", "error"):
                break
            time.sleep(0.5)
        self.summary["health"] = h
        self.summary["waitedForReadyS"] = round(time.time() - t0, 1)
        if not self.check("1 health ready", h.get("status") == "ready" and h.get("facadeVersion") == 1
                          and h.get("device") == "mps" and h.get("engine", {}).get("commit")
                          and h.get("engine", {}).get("weightsBytes"), h):
            return
        # 2 + 3: T1, built-in voice
        with open(a.t1_json, "rb") as f:
            t1_bytes = f.read()
        st, reply, rec = self.render("T1-builtin-24k", t1_request(os.path.join(a.out, "t1-builtin-24k.wav"), builtin,
                                                                  a.seed, 24000))
        if st == 200:
            got = score.dump_meta_list([reply["targetMeta"]])
            self.check("2 T1 targetMeta == spike T1.json bytes (real g2p_en)", got == t1_bytes,
                       {"got": sha(got), "want": sha(t1_bytes)})
            au = rec["audio"]
            self.check("2 T1 24 kHz: float32 mono 24000 Hz, 241920 frames",
                       (au["format"], au["channels"], au["sampleRate"], au["frames"]) == (3, 1, 24000, 241920), au)
            self.check("2 T1 24 kHz: every sample finite, audible", au["finite"] and au["audible"],
                       {"peak": au["peak"], "rms": au["rms"]})
            self.check("2 T1 24 kHz: the reply's hashes are the file's", au["replyMatchesFile"])
            if a.spike_render and os.path.isfile(a.spike_render):
                same = wavio.data_chunk(a.spike_render) == wavio.data_chunk(os.path.join(a.out, "t1-builtin-24k.wav"))
                self.summary["informativeSpikeRenderPcmIdentical"] = same
                sys.stderr.write("INFO  T1 24 kHz samples %s the spike's render of the same inputs (informative)\n"
                                 % ("EQUAL" if same else "DIFFER FROM"))
        st, reply, rec = self.render("T1-builtin-48k", t1_request(os.path.join(a.out, "t1-builtin-48k.wav"), builtin,
                                                                  a.seed, 48000))
        if st == 200:
            au = rec["audio"]
            self.check("3 T1 48 kHz: 483840 frames, finite, audible",
                       au["frames"] == 483840 and au["sampleRate"] == 48000 and au["finite"] and au["audible"], au)
        # 4: the null test
        voice = own_voice_from_labels(a.own_reference, a.own_labels)
        self.summary["ownVoice"] = voice
        hz = 220.0
        plan = [("a", {}, a.seed), ("b", {"testPromptF0": {"hz": hz, "frames": "full"}}, a.seed), ("a2", {}, a.seed),
                ("c", {"testPromptF0": {"hz": hz, "frames": a.short_f0_frames}}, a.seed), ("e", {}, a.seed + 1)]
        shas = {}
        for tag, extra, seed in plan:
            st, reply, rec = self.render("null-" + tag, t1_request(os.path.join(a.out, "null-%s.wav" % tag), voice,
                                                                   seed, 24000, **extra))
            if st != 200:
                return
            shas[tag] = rec["audio"]["fileSha256"]
            self.check("4 null-%s: finite and audible" % tag, rec["audio"]["finite"] and rec["audio"]["audible"],
                       {"peak": rec["audio"]["peak"], "rms": rec["audio"]["rms"]})
        v = {k: self.summary["renders"]["null-" + k]["voice"] for k in shas}
        self.summary["nullTest"] = {"sha256": shas, "voice": {k: {kk: v[k].get(kk) for kk in (
            "promptFrames", "promptMelFrames", "promptF0Frames", "promptCached", "promptPaddedSamples")} for k in v}}
        self.check("4 the hook took: b carried a full-length prompt f0 (mel frames + 1), a none",
                   v["b"]["promptF0Frames"] == v["b"]["promptMelFrames"] + 1 and v["a"]["promptF0Frames"] == 0
                   and v["b"]["promptFrames"] == v["a"]["promptFrames"], self.summary["nullTest"]["voice"])
        self.check("4 c's short f0 truncated the prompt", v["c"]["promptFrames"] == a.short_f0_frames
                   < v["a"]["promptFrames"], (v["c"]["promptFrames"], v["a"]["promptFrames"]))
        self.check("4 CONTROL same-process determinism: sha(a) == sha(a2)", shas["a"] == shas["a2"], shas)
        self.check("4 NULL TEST: sha(a) == sha(b), prompt f0 omitted vs full-length", shas["a"] == shas["b"], shas)
        self.check("4 CONTROL the comparison can fail: sha(c) != sha(a)", shas["c"] != shas["a"], shas)
        self.check("4 CONTROL seed + 1 differs: sha(e) != sha(a)", shas["e"] != shas["a"], shas)
        # 5: refusals from the real engine
        bad = t1_request(os.path.join(a.out, "x.wav"), builtin, a.seed, 24000)
        bad["phrase"]["words"][3]["text"] = "!!!"
        refusals = [("emptyWord", 400, bad),
                    ("voiceNotFound", 404, t1_request(os.path.join(a.out, "x.wav"), {"id": "builtin-9"}, a.seed, 24000)),
                    ("referenceChanged", 409, t1_request(os.path.join(a.out, "x.wav"), dict(voice, referenceSha256="0" * 64),
                                                         a.seed, 24000))]
        if a.outside:
            refusals.append(("pathNotAllowed", 403, t1_request(a.outside, builtin, a.seed, 24000)))
        for code, status, body in refusals:
            st, reply, _ = call(a.port, "POST", "/v1/sing/phrase", body)
            self.summary["renders"]["refuse-" + code] = {"status": st, "reply": reply}
            self.check("5 %s -> %d" % (code, status), st == status and reply.get("error") == code, reply)
        st, h, _ = call(a.port, "GET", "/health")
        self.summary["healthAfter"] = h

    def finish(self):
        self.summary["checks"] = self.checks
        self.summary["passed"] = bool(self.checks) and all(c["pass"] for c in self.checks)
        self.summary["finished"] = time.strftime("%Y-%m-%d %H:%M:%S")
        with open(os.path.join(self.a.out, "summary.json"), "w") as f:
            json.dump(self.summary, f, indent=1, sort_keys=True, default=str)
        print(json.dumps(self.summary, indent=1, sort_keys=True, default=str))
        return 0 if self.summary["passed"] else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, default=18004)
    ap.add_argument("--out", required=True)
    ap.add_argument("--t1-json", required=True)
    ap.add_argument("--own-reference", required=True)
    ap.add_argument("--own-labels", required=True)
    ap.add_argument("--outside")
    ap.add_argument("--spike-render")
    ap.add_argument("--seed", type=int, default=20260924)
    ap.add_argument("--short-f0-frames", type=int, default=50)
    ap.add_argument("--health-timeout", type=float, default=300.0)
    a = ap.parse_args(argv)
    if a.port == 8004:
        sys.stderr.write("smoke: refusing port 8004 (the product's port); use a test port such as 18004.\n")
        return 2
    s = Smoke(a)
    try:
        s.run()
    except Exception as e:           # a crash is a FAIL with its reason, never a silent pass
        s.check("smoke ran to the end", False, "%s: %s" % (type(e).__name__, e))
    return s.finish()


if __name__ == "__main__":
    sys.exit(main())
