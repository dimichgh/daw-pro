"""The no-impact gate for facadeVersion 2, standard-library half (design docs/design/2026-10-06-p2-sing-expansion.md
§9.1, item p2-sing-x2). "When none of the new things is used, every request, render and reply is byte-identical to
today's." Every golden below was recorded by W8-X2 on 2026-10-06 from the tree BEFORE x2 changed anything (pin-before:
`$S/w8/X2/pin/`, the facade files as of commit e7e4d24 plus W8-SFIX's test changes); a golden recorded after the
change would pin nothing.

  P1 test_v1_bodies_validate_unchanged     v1 bodies -> today's PhraseRequest, new fields at their defaults
  P2 (test_score.py SpikeBytes)            the T1/T2/T1T2 bytes and all eight spike cases, unchanged
  P4 test_v2_key_under_v1_refused          each v2 key under facadeVersion 1: today's message + the version sentence
  P5 test_v2_defaults_equal_v1             a v2 body using only defaults = the v1 body (fields, metadata bytes)
  P6 test_stub_v1_render_sha               the stub's v1 WAVs and replies, by sha256
  P7 test_health_superset                  /health: today's keys and values, plus `capabilities` and nothing else
  P9 test_no_gpl_import                    nothing under scripts/sing imports parselmouth (GPLv3)
  S7 (Python twin) test_every_v2_key_is_optional
P3 (the infer kwargs, through the real render) and P8 (lazy imports) need numpy / g2pM: test_venv_v1_compat.py.
"""
import hashlib
import json
import os
import re
import unittest

from _util import (SING, T1_NOTES, T1_WORDS, T2_NOTES, T2_WORDS, all_spike_cases, concat, fixture_bytes, free_port,
                   health_status, http, own_voice, phrase_request, sha256_path, stub_via_run_sh, table_phonemize,
                   temp_dir, write_reference_wav)

from singlib import schema, score
from singlib.engine import SoulXBackend
from singlib.refusals import Refusal
from singlib import pins as spins

# ---------------------------------------------------------------------------------------------- pin-before goldens
# canonical = sha256 of json.dumps(x, sort_keys=True, separators=(",", ":")) after a JSON round trip
PHRASE_REQUEST_SHA = {   # vars(PhraseRequest) with vars(voice), BEFORE x2 (so without any new field)
    "T1": "806c94ebf0b662bc5a1bea5b9b51347d09879ca46ebc9b7ba8435e557476dc61",
    "T2": "b4c076e61df92bb82063ceed06930344cee8c8b805758555a3d88f7834ce9221",
    "T2-own-hook": "354565385e5acc4d48fb2cd7a926ea6bd68a4cb7b0cd6219dd2d3cbe5a09045e",
    "T2-own-offset": "56e38e7725866ee21d0cf71d8207a812051f049a3b46437841d8961925ab848f",
}
NEW_FIELDS = ("facade_version", "control", "word_langs", "note_vibratos")
NEW_VOICE_FIELDS = ("prompt_f0",)
V1_MESSAGES = {          # today's refusal for each v2 key under facadeVersion 1, BEFORE x2
    "control": "Unknown key in the request: control. Allowed: facadeVersion, voice, phrase, leadS, trailS, seed, "
               "nSteps, cfg, outputPath, outputSampleRate.",
    "lang": "Unknown key in phrase.words[0]: lang. Allowed: text, noteIndices.",
    "vibrato": "Unknown key in phrase.notes[2]: vibrato. Allowed: startS, endS, midi.",
    "f0": "Unknown key in voice.prompt: f0. Allowed: windowStartS, windowEndS, notes.",
}
STUB_WAV_SHA = {         # the stub's v1 renders, in this order in ONE stub process, BEFORE x2
    "T1-48k": "bc878e648d2a3987905a7a3ce79997592057c2e1a9b96b8d5bafcb912161630e",
    "T2-48k": "520d73877f72300263beee792508402e36c9763f8b1bc2fe7d81c753016b0c7e",
    "T1T2-44k": "abf601be7803227c9156982b83e9aaa99c1f34d6750166efdaed07e3e9a1150d",
    "T2-own": "520d73877f72300263beee792508402e36c9763f8b1bc2fe7d81c753016b0c7e",
}
STUB_REPLY_SHA = {       # the same renders' replies without outputPath
    "T1-48k": "86e0fa02736dc6c8a3ce13456534b1eaf6892c28f3610f4dfac112bc22460347",
    "T2-48k": "ec4ebd5cc1a3edc8ae944a5dcfde603a45399a7fee8dfd6d7b9f6956a7f9546e",
    "T1T2-44k": "2537d289e2ed93c81f3901ab815d6732f35b1f15ff5535d6f5a897961f1c3dba",
    "T2-own": "37aaabe43376c3e697ffe2a6df894edbbc00b7e91cb449890898a2b6ee3715b4",
}
STUB_HEALTH = {"device": "stub", "engine": {"commit": "stub", "weightsBytes": 0, "weightsRevision": "stub"},
               "facadeVersion": 1, "loadSeconds": 0.2, "mpsDriverBytes": 0, "rendered": 0, "status": "ready",
               "stub": {"after": 0, "applied": 0, "count": None, "fault": None, "renders": 0}}   # minus pid
FACADE_HEALTH_KEYS = ["device", "engine", "facadeVersion", "ffmpegMajor", "loadSeconds", "mpsDriverBytes", "pid",
                      "rendered", "status"]
FACADE_ENGINE_KEYS = ["commit", "weightsBytes", "weightsRevision"]
CAPABILITY_KEYS = ["controls", "facadeVersions", "languages"]


def canon(x):
    return hashlib.sha256(json.dumps(json.loads(json.dumps(x, default=list)), sort_keys=True,
                                     separators=(",", ":")).encode("utf-8")).hexdigest()


def fields(r, drop_new=True):
    d = dict(vars(r))
    d["voice"] = dict(vars(r.voice))
    if drop_new:
        for k in NEW_FIELDS:
            d.pop(k)
        for k in NEW_VOICE_FIELDS:
            d["voice"].pop(k)
    return d


def v1_bodies():
    hook = phrase_request(T2_NOTES, T2_WORDS, "/x/out.wav", voice=own_voice("/x/v/r.wav", "ab" * 32),
                          testPromptF0={"hz": 220.0, "frames": "full"})
    return {"T2": (phrase_request(T2_NOTES, T2_WORDS, "/x/out.wav"), False),
            "T1": (phrase_request(T1_NOTES, T1_WORDS, "/x/out.wav"), False),
            "T2-own-offset": (phrase_request(T2_NOTES, T2_WORDS, "/x/out.wav",
                                             voice=own_voice("/x/v/r.wav", "ab" * 32, offset=-12)), False),
            "T2-own-hook": (hook, True)}


def request_cases():
    """The spike cases a request can carry: T3-30 and T3-60 are longer than the facade's 30 s (they still get the
    all-English byte check without a request, test_score.Languages)."""
    return {name: c for name, c in all_spike_cases().items()
            if 0.24 + max(sb + lb for _, sb, lb in c[0]) * 0.6 + 0.24 <= schema.MAX_PHRASE_S}


def assert_defaults(tc, r, version=1):
    tc.assertEqual(r.facade_version, version)
    tc.assertEqual(r.control, "score")
    tc.assertEqual(r.word_langs, ["en"] * len(r.words))
    tc.assertEqual(r.note_vibratos, [None] * len(r.notes))
    tc.assertIsNone(r.voice.prompt_f0)


class NoImpact(unittest.TestCase):
    def test_v1_bodies_validate_unchanged(self):
        """P1."""
        for name, (body, hooks) in v1_bodies().items():
            r = schema.validate(json.loads(json.dumps(body)), test_hooks=hooks)
            self.assertEqual(canon(fields(r)), PHRASE_REQUEST_SHA[name], name)
            assert_defaults(self, r)
        self.assertEqual(sorted(request_cases()), ["T1", "T1-f0-110", "T1-plus2", "T1T2", "T2", "T2-sep"])
        for name, (notes, words, _) in request_cases().items():             # and every spike case's body
            assert_defaults(self, schema.validate(phrase_request(notes, words, "/x/out.wav")))

    def test_v2_key_under_v1_refused(self):
        """P4."""
        def body(key):
            o = phrase_request(T2_NOTES, T2_WORDS, "/x/out.wav")
            if key == "control":
                o["control"] = "score"
            elif key == "lang":
                o["phrase"]["words"][0]["lang"] = "en"
            elif key == "vibrato":
                o["phrase"]["notes"][2]["vibrato"] = {"rateHz": 5.5, "depthCents": 40, "onsetS": 0.2}
            else:
                v = own_voice("/x/voices/v1/reference.wav", "ab" * 32)
                v["prompt"]["f0"] = {"fps": 50, "hz": [220.0] * 10}
                o["voice"] = v
            return o
        for key, today in V1_MESSAGES.items():
            with self.assertRaises(Refusal) as cm:
                schema.validate(body(key))
            self.assertEqual(cm.exception.code, "badRequest", key)
            self.assertEqual(cm.exception.message, today + " '%s' needs facadeVersion 2." % key)
        for key, outcome in (("control", None), ("lang", None), ("vibrato", "vibratoNeedsMelody"),
                             ("f0", "badRequest")):                       # control: under v2 each key is KNOWN
            b2 = body(key)
            b2["facadeVersion"] = 2
            if outcome is None:
                schema.validate(b2)
                continue
            with self.assertRaises(Refusal) as cm:
                schema.validate(b2)
            self.assertEqual(cm.exception.code, outcome, key)
            self.assertNotIn("Unknown key", cm.exception.message)       # known, and refused for melody mode only
            self.assertIn("melody", cm.exception.message)

    def test_v2_defaults_equal_v1(self):
        """P5: request fields and metadata bytes. (The infer kwargs half is test_venv_v1_compat.py.)"""
        for name, (notes, words, kw) in request_cases().items():
            v1 = phrase_request(notes, words, "/x/out.wav")
            bare = dict(v1, facadeVersion=2)
            spelled = json.loads(json.dumps(bare))
            spelled["control"] = "score"
            for w in spelled["phrase"]["words"]:
                w["lang"] = "en"
            r1 = schema.validate(json.loads(json.dumps(v1)))
            for b2 in (bare, spelled):
                r2 = schema.validate(json.loads(json.dumps(b2)))
                f1, f2 = fields(r1, drop_new=False), fields(r2, drop_new=False)
                self.assertEqual(f2.pop("facade_version"), 2)
                f1.pop("facade_version")
                self.assertEqual(f1, f2, name)
                m1, _ = score.build_meta(r1.notes, r1.words, lead=r1.lead, trail=r1.trail, phonemize=table_phonemize,
                                         langs=r1.word_langs, lexicon=None, **kw)
                m2, i2 = score.build_meta(r2.notes, r2.words, lead=r2.lead, trail=r2.trail, phonemize=table_phonemize,
                                          langs=r2.word_langs, lexicon=None, **kw)
                self.assertEqual(score.dump_meta_list([m2]), score.dump_meta_list([m1]), name)
                self.assertEqual(i2["substitutions"], [])
                if name in ("T1", "T2", "T1T2"):
                    self.assertEqual(score.dump_meta_list([m2]), fixture_bytes(name), name)

    def test_every_v2_key_is_optional(self):
        """S7's Python twin: a v2 body carrying every key x2 accepts still validates with any ONE of them removed.
        (vibrato and voice.prompt.f0 are melody-only: no valid x2 body carries them; test_schema refuses both.)"""
        full = phrase_request(T2_NOTES, T2_WORDS, "/x/out.wav", facadeVersion=2, control="score")
        for w in full["phrase"]["words"]:
            w["lang"] = "en"
        paths = [("control",)] + [("phrase", "words", j, "lang") for j in range(len(full["phrase"]["words"]))]
        schema.validate(json.loads(json.dumps(full)))
        for path in paths:
            o = json.loads(json.dumps(full))
            node = o
            for k in path[:-1]:
                node = node[k]
            del node[path[-1]]
            assert_defaults(self, schema.validate(o), version=2)


class StubNoImpact(unittest.TestCase):
    def test_stub_v1_render_sha(self):
        """P6: the stub is deterministic sines, so its v1 output is pinned by bytes."""
        tmp = os.path.realpath(temp_dir("v1compat stub"))
        rt, cache, voices = (os.path.join(tmp, "App Support", "DAWPro", d) for d in
                             ("SingingEngine", "SingingCache", "SingingVoices"))
        for d in (rt, cache, voices):
            os.makedirs(d)
        ref = os.path.join(voices, "v1", "reference.wav")
        sha = write_reference_wav(ref, seconds=5.0)
        t1t2 = concat([(T1_NOTES, T1_WORDS, 0), (T2_NOTES, T2_WORDS, 16 + 100.0 / 60.0)])
        cases = (("T1-48k", T1_NOTES, T1_WORDS, {}), ("T2-48k", T2_NOTES, T2_WORDS, {}),
                 ("T1T2-44k", t1t2[0], t1t2[1], {"outputSampleRate": 44100}),
                 ("T2-own", T2_NOTES, T2_WORDS, {"voice": own_voice(ref, sha)}))
        port = free_port()
        with stub_via_run_sh(rt, port, [cache, voices]):
            st, h = http("GET", port, "/health")
            for name, notes, words, over in cases:
                out = os.path.join(cache, name + ".wav")
                st, body = http("POST", port, "/v1/sing/phrase", phrase_request(notes, words, out, **over), timeout=120)
                self.assertEqual(st, 200, body)
                self.assertEqual(sha256_path(out), STUB_WAV_SHA[name], name)
                body.pop("outputPath")
                self.assertEqual(canon(body), STUB_REPLY_SHA[name], name)

    def test_health_superset(self):
        """P7: the stub's and the facade's /health keep every key and value, and add `capabilities` only."""
        tmp = os.path.realpath(temp_dir("v1compat health"))
        rt = os.path.join(tmp, "SingingEngine")
        os.makedirs(rt)
        port = free_port()
        with stub_via_run_sh(rt, port, [tmp]):
            h = health_status(port)
        h.pop("pid")
        caps = h.pop("capabilities")
        self.assertEqual(h, STUB_HEALTH)
        self.assertEqual(sorted(caps), CAPABILITY_KEYS)
        self.assertEqual(caps["facadeVersions"], [1, 2])
        self.assertEqual(caps["controls"], ["score"])
        f = SoulXBackend(rt, spins.load(), device="cpu").health()           # the facade's own, no model needed
        self.assertEqual(sorted(set(f) - {"capabilities"}), FACADE_HEALTH_KEYS)
        self.assertEqual(sorted(f["engine"]), FACADE_ENGINE_KEYS)
        self.assertEqual(f["facadeVersion"], 1)
        self.assertEqual(sorted(f["capabilities"]), CAPABILITY_KEYS)
        self.assertEqual(f["capabilities"]["languages"][0], "en")


# ------------------------------------------------------------------------------------------------ P9
IMPORT_RE = re.compile(r"^\s*(?:import\s+([\w.]+(?:\s*,\s*[\w.]+)*)|from\s+([\w.]+)\s+import\b)", re.M)
DYNAMIC_RE = re.compile(r"(?:__import__|import_module)\(\s*['\"]([\w.]+)['\"]")


def imported_modules(root):
    """{top-level module name: [files]} for every import statement and literal dynamic import in root's .py files."""
    found = {}
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x != "__pycache__"]
        for fn in files:
            if not fn.endswith(".py"):
                continue
            p = os.path.join(d, fn)
            with open(p, encoding="utf-8", errors="replace") as f:
                text = f.read()
            names = []
            for m in IMPORT_RE.finditer(text):
                names += [x.strip() for x in (m.group(1) or m.group(2)).split(",")]
            names += DYNAMIC_RE.findall(text)
            for n in names:
                found.setdefault(n.split(".")[0], []).append(os.path.relpath(p, root))
    return found


class NoGPL(unittest.TestCase):
    def test_no_gpl_import(self):
        """P9: praat-parselmouth (GPLv3) is in the venv only because the lock mirrors upstream; nothing of ours may
        import it. Positive controls: the same scan finds soxr in scripts/sing, and finds a planted parselmouth."""
        found = imported_modules(SING)
        self.assertIn("soxr", found)                                          # the scan can see a real import
        self.assertIn("g2p_en", found)
        self.assertNotIn("parselmouth", found, found.get("parselmouth"))
        with open(os.path.join(SING, "pins.env"), encoding="utf-8") as f:
            self.assertNotIn("parselmouth", f.read().split("VERIFY_IMPORTS=", 1)[1].splitlines()[0])
        plant = temp_dir("gpl plant")
        for i, line in enumerate(("im" + "port parselmouth", "from parsel" + "mouth import Sound",
                                  "x = __im" + "port__('parselmouth')", "    import os, parsel" + "mouth")):
            with open(os.path.join(plant, "p%d.py" % i), "w") as f:
                f.write("# plant\n" + line + "\n")
            self.assertEqual(sorted(imported_modules(plant).get("parselmouth")),
                             ["p%d.py" % k for k in range(i + 1)])


if __name__ == "__main__":
    unittest.main()
