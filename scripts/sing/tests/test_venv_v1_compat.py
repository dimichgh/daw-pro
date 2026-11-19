"""The no-impact gate for facadeVersion 2, venv half (design docs/design/2026-10-06-p2-sing-expansion.md §9.1, item
p2-sing-x2). Runs in tests/run_all.sh pass 2 (the installed runtime's venv, READ-ONLY): it needs numpy (the real
SoulXBackend.render) and g2pM / ToJyutping (the lazy-import test). No model is loaded: a SPY model and a spy
DataProcessor record what the real render code hands them.

  P3  test_v1_infer_kwargs_spy                 a v1 body: model.infer's kwargs, the target metadata and the written
                                               WAV equal the goldens recorded BEFORE x2 (pin-before, W8-X2 2026-10-06)
  P5b test_v2_defaults_infer_kwargs_equal_v1   a v2 body using only defaults: the same, plus "control" in the reply
  P8  test_lazy_imports                        an English request imports neither g2pM nor ToJyutping; a Mandarin
                                               one imports g2pM, a Cantonese one ToJyutping; parselmouth never
"""
import hashlib
import json
import os
import subprocess
import sys
import unittest

from _util import (RUNTIME, SING, UPSTREAM, T1_NOTES, T1_WORDS, T2_NOTES, T2_WORDS, child_env, evidence, have_modules,
                   need, phrase_request, table_phonemize, temp_dir)

from singlib import score

GOLDEN_KWARGS = {"auto_shift": False, "pitch_shift": 0, "n_steps": 32, "cfg": 3.0, "control": "score",
                 "use_fp16": False}
GOLDEN = {   # pin-before (the tree before x2): $S/w8/X2/pin/spy-before.json
    "T1": {"kwargs": GOLDEN_KWARGS,
           "targetMetaSha256": "f6a064ef0fa9b1c140dbbf889cf70f2b70351ccfff3a9567a51502620cd8c274",
           "targetMetaListBytesSha256": "83e5baf016dd2d5556e8bf28a28d6dac19fbed67ae862ca5887541b7a5c08796",
           "outputSha256": "d62cd78ad472f48f3fa74392045b4f736b8bd288227ef4ca5ab63b3733621c49"},
    "T2": {"kwargs": GOLDEN_KWARGS,
           "targetMetaSha256": "46aadbc81ceced6cec85bf99d344003fee3611d1e14935c75e45de14ac2ffd86",
           "targetMetaListBytesSha256": "d70dc04e8527ad111845dd2da248fd3a8de81c1e07a856c5137db49af5ee5eae",
           "outputSha256": "6bacff7333a1044d1dba272041f7d1150479601a702c650dfeb6694581881bce"},
    "T1-24k-seed7-cfg2": {"kwargs": dict(GOLDEN_KWARGS, cfg=2, n_steps=16),
                          "targetMetaSha256": "f6a064ef0fa9b1c140dbbf889cf70f2b70351ccfff3a9567a51502620cd8c274",
                          "targetMetaListBytesSha256":
                              "83e5baf016dd2d5556e8bf28a28d6dac19fbed67ae862ca5887541b7a5c08796",
                          "outputSha256": "e1ef3181c98c0b95c9de334954a8bd0ab88561397e8fb9daef76171823485858"},
}
PROMPT_META_SHA256 = "a2112ae2374f58a1798a3932a253244d821bb1686437bf70f14e6ef6bff3d088"   # builtin-1's prompt.json
REPLY_KEYS = ["cfg", "channels", "durationS", "entries", "frames", "inferSeconds", "modelSamples24k", "mpsDriverBytes",
              "nSteps", "nonFinite", "outputPath", "outputSha256", "pcmSha256", "peak", "rms", "rtf", "sampleRate",
              "samples24k", "seed", "targetFrames", "targetMeta", "totalSeconds", "voice"]
CASES = {"T1": (T1_NOTES, T1_WORDS, {}), "T2": (T2_NOTES, T2_WORDS, {}),
         "T1-24k-seed7-cfg2": (T1_NOTES, T1_WORDS, {"outputSampleRate": 24000, "seed": 7, "cfg": 2, "nSteps": 16})}

# The spy harness, shared by the in-process tests and the clean-interpreter subprocess of P8.
HARNESS = r'''
import copy, json, os, sys, types
import numpy as np
from singlib import schema, score
from singlib import pins as spins
from singlib.engine import SoulXBackend


class Shape(object):
    def __init__(self, n):
        self.shape = (1, n)


class FakeOut(object):
    def __init__(self, n):
        self.n = n

    def detach(self):
        return self
    float = cpu = detach

    def reshape(self, *a):
        return self

    def numpy(self):
        return np.zeros(self.n, dtype=np.float32)


class SpyDP(object):
    def __init__(self):
        self.calls = []

    def process(self, meta, wav):
        self.calls.append((copy.deepcopy(meta), wav))
        return {"mel2note": Shape(score.mel_frames(meta)), "meta": copy.deepcopy(meta)}


class SpyModel(object):
    def __init__(self):
        self.calls = []

    def infer(self, items, **kw):
        self.calls.append((sorted(items), dict(kw)))
        return FakeOut(score.output_samples_24k(items["target"]["meta"]))


class NoGrad(object):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def spy_backend(runtime, phonemize, phoneset=None, lexicon=None):
    be = SoulXBackend(runtime, spins.load(), device="cpu")
    be.torch = types.SimpleNamespace(manual_seed=lambda s: None, no_grad=NoGrad)
    be.model, be.dp = SpyModel(), SpyDP()
    be.phonemize, be.phoneset, be.lexicon = phonemize, phoneset, lexicon
    be._state = "ready"
    return be


def spy_runtime(tmp, builtin_meta_src):
    rt = os.path.join(tmp, "runtime")
    vd = os.path.join(rt, "voices", "builtin-1")
    os.makedirs(vd, exist_ok=True)
    with open(builtin_meta_src, "rb") as f, open(os.path.join(vd, "prompt.json"), "wb") as g:
        g.write(f.read())
    open(os.path.join(vd, "prompt.wav"), "wb").close()
    cache = os.path.join(tmp, "cache")
    os.makedirs(cache, exist_ok=True)
    return rt, cache, schema.normalize_roots([cache, os.path.join(rt, "voices")])


def spy_render(be, body, rt, roots):
    req = schema.validate(json.loads(json.dumps(body)))
    schema.resolve(req, roots, os.path.join(rt, "voices"))
    n_model, n_dp = len(be.model.calls), len(be.dp.calls)
    reply = be.render(req)
    (items, kw), = be.model.calls[n_model:]
    target_meta = be.dp.calls[-1][0]
    prompt_meta = be.dp.calls[n_dp][0] if len(be.dp.calls) - n_dp == 2 else None
    return req, reply, items, kw, target_meta, prompt_meta
'''

_NS = {}


def harness():
    need(have_modules("numpy"), "numpy (the singing runtime's venv)")
    if not _NS:
        exec(compile(HARNESS, "<spy harness>", "exec"), _NS)
    return _NS


def builtin_meta():
    p = os.path.join(RUNTIME, "voices", "builtin-1", "prompt.json")
    need(os.path.isfile(p), "the installed runtime's builtin-1 prompt.json at %s (SING_TEST_RUNTIME)" % p)
    return p


def sha(b):
    return hashlib.sha256(b).hexdigest()


def meta_facts(meta):
    return {"targetMetaSha256": sha(json.dumps(meta, sort_keys=True, ensure_ascii=False).encode("utf-8")),
            "targetMetaListBytesSha256": sha(score.dump_meta_list([meta]))}


class SpyRender(unittest.TestCase):
    def setUp(self):
        self.h = harness()
        self.tmp = os.path.realpath(temp_dir("v1compat spy"))
        self.rt, self.cache, self.roots = self.h["spy_runtime"](self.tmp, builtin_meta())

    def render(self, name, body):
        be = self.h["spy_backend"](self.rt, table_phonemize)
        return self.h["spy_render"](be, body, self.rt, self.roots)

    def body(self, name, version=1, spelled=False):
        notes, words, over = CASES[name]
        b = phrase_request(notes, words, os.path.join(self.cache, "%s-v%d%s.wav" % (name, version, "s" if spelled
                                                                                      else "")), **over)
        if version == 2:
            b["facadeVersion"] = 2
            if spelled:
                b["control"] = "score"
                for w in b["phrase"]["words"]:
                    w["lang"] = "en"
        return b

    def test_v1_infer_kwargs_spy(self):
        """P3."""
        for name, want in GOLDEN.items():
            req, reply, items, kw, meta, prompt_meta = self.render(name, self.body(name))
            self.assertEqual(items, ["prompt", "target"], name)
            self.assertEqual(kw, want["kwargs"], name)
            self.assertIs(type(kw["control"]), str)
            self.assertNotIn("f0", meta, name)
            self.assertEqual(meta_facts(meta), {k: want[k] for k in ("targetMetaSha256", "targetMetaListBytesSha256")},
                             name)
            self.assertEqual(reply["outputSha256"], want["outputSha256"], name)
            self.assertEqual(sorted(reply), REPLY_KEYS, name)
            self.assertEqual(sha(json.dumps(prompt_meta, sort_keys=True).encode()), PROMPT_META_SHA256)
        evidence("P3: v1 T1/T2/T1-24k infer kwargs, target meta and WAV bytes == pin-before goldens")

    def test_v2_defaults_infer_kwargs_equal_v1(self):
        """P5b: a v2 body with only defaults (bare, and with control/lang spelled out) renders exactly as v1."""
        for name, want in GOLDEN.items():
            for spelled in (False, True):
                req, reply, items, kw, meta, _ = self.render(name, self.body(name, 2, spelled))
                self.assertEqual(kw, want["kwargs"], (name, spelled))
                self.assertEqual(meta_facts(meta), {k: want[k] for k in ("targetMetaSha256",
                                                                         "targetMetaListBytesSha256")}, name)
                self.assertEqual(reply["outputSha256"], want["outputSha256"], name)
                self.assertEqual(sorted(reply), sorted(REPLY_KEYS + ["control"]), name)   # no "substitutions"
                self.assertEqual(reply["control"], "score")


P8_SCRIPT = HARNESS + r'''
from singlib import phonemes
mods = lambda: {m: m in sys.modules for m in ("g2pM", "ToJyutping", "parselmouth", "g2p_en")}
out = {"atStart": mods()}
tmp, meta_src, nltk, phoneset_path, sing_tests = sys.argv[1:6]
sys.path.insert(0, sing_tests)
from _util import T2_NOTES, T2_WORDS, phrase_request
rt, cache, roots = spy_runtime(tmp, meta_src)
with open(phoneset_path, encoding="utf-8") as f:
    ps = frozenset(json.load(f))
be = spy_backend(rt, phonemes.G2PPhonemizer(nltk), ps, phonemes.Lexicon())
out["capabilities"] = be.health()["capabilities"]
out["afterHealth"] = mods()
_, reply, _, kw, meta, _ = spy_render(be, phrase_request(T2_NOTES, T2_WORDS, os.path.join(cache, "en.wav")), rt, roots)
out["afterEnglish"] = mods()
out["englishTokens"] = meta["phoneme"]
zh = phrase_request(T2_NOTES, T2_WORDS, os.path.join(cache, "zh.wav"), facadeVersion=2)
zh["phrase"]["words"] = [{"text": c, "noteIndices": i, "lang": "zh"} for c, i in (("我", [0]), ("爱", [1, 2, 3]),
                                                                                    ("你", [4]))]
_, reply, _, kw, meta, _ = spy_render(be, zh, rt, roots)
out["afterMandarin"] = mods()
out["mandarinTokens"] = meta["phoneme"]
out["mandarinLanguage"] = meta["language"]
yue = json.loads(json.dumps(zh))
yue["outputPath"] = os.path.join(cache, "yue.wav")
for w in yue["phrase"]["words"]:
    w["lang"] = "yue"
_, reply, _, kw, meta, _ = spy_render(be, yue, rt, roots)
out["afterCantonese"] = mods()
out["cantoneseTokens"] = meta["phoneme"]
out["loaded"] = be.lexicon.loaded()
print("@@P8 " + json.dumps(out, ensure_ascii=False))
'''


class LazyImports(unittest.TestCase):
    def test_lazy_imports(self):
        """P8, in a clean interpreter (this process may already hold the libraries)."""
        need(have_modules("numpy", "g2p_en", "g2pM", "ToJyutping"), "numpy, g2p_en, g2pM, ToJyutping (the venv)")
        need(os.environ.get("NLTK_DATA"), "NLTK_DATA (the runtime's nltk_data)")
        phoneset = os.path.join(UPSTREAM, "soulxsinger", "utils", "phoneme", "phone_set.json")
        need(os.path.isfile(phoneset), "upstream's phone_set.json at %s" % phoneset)
        tmp = os.path.realpath(temp_dir("lazy imports"))
        script = os.path.join(tmp, "p8.py")
        with open(script, "w", encoding="utf-8") as f:
            f.write(P8_SCRIPT)
        env = child_env(PYTHONPATH=SING, MPLCONFIGDIR=os.path.join(tmp, "mpl"))
        r = subprocess.run([sys.executable, "-B", script, os.path.join(tmp, "spy"), builtin_meta(),
                            os.environ["NLTK_DATA"], phoneset, os.path.join(SING, "tests")], env=env,
                           capture_output=True, text=True, timeout=300)
        self.assertEqual(r.returncode, 0, r.stderr[-3000:])
        out = json.loads([x for x in r.stdout.splitlines() if x.startswith("@@P8 ")][0][5:])
        none = {"g2pM": False, "ToJyutping": False, "parselmouth": False}
        for stage in ("atStart", "afterHealth", "afterEnglish"):
            self.assertEqual({k: out[stage][k] for k in none}, none, stage)
        self.assertTrue(out["afterEnglish"]["g2p_en"])                         # control: the probe sees an import
        self.assertEqual(out["capabilities"]["languages"], ["en", "zh", "yue"])  # found, not imported
        self.assertEqual({k: out["afterMandarin"][k] for k in none}, dict(none, g2pM=True))
        self.assertEqual({k: out["afterCantonese"][k] for k in none}, dict(none, g2pM=True, ToJyutping=True))
        self.assertEqual(out["loaded"], ["yue", "zh"])
        self.assertEqual(out["mandarinTokens"].split()[1:-1], ["zh_wo3", "zh_ai4", "zh_ai4", "zh_ai4", "<SP>", "zh_ni3"])
        self.assertEqual(out["mandarinLanguage"], "Mandarin")
        self.assertEqual(out["cantoneseTokens"].split()[1:-1],
                         ["yue_ngo5", "yue_oi3", "yue_oi3", "yue_oi3", "<SP>", "yue_nei5"])
        self.assertIn("en_HH-OW1-L-D", out["englishTokens"])
        evidence("P8: %s" % json.dumps({k: out[k] for k in ("afterEnglish", "afterMandarin", "afterCantonese")}))


if __name__ == "__main__":
    unittest.main()
