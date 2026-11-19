"""The converter with the REAL g2p_en and upstream's phone_set.json (runtime venv only).

  * the spike's eight fixtures, byte for byte, through singlib.phonemes.G2PPhonemizer (the facade's phonemizer);
  * the number/hyphen defect in the spike's rule (the CONTROL: it still exists) and the facade's fix;
  * every word the spike ever sang is phonemized exactly as the spike did (the fix is invisible on them);
  * missing NLTK data fails BEFORE g2p_en is imported (so its import-time download can never run);
  * facadeVersion 2 (item p2-sing-x2, design 2026-10-06 §6.4): the Mandarin (g2pM) and Cantonese (ToJyutping) lexicon
    on the probe's lines, the tone fallback against the real phone set, and the coverage over g2pM's own 5,207-character
    vocabulary (every emitted token is in the phone set).
Needs: g2p_en + nltk (the venv), NLTK_DATA (cmudict, averaged_perceptron_tagger, averaged_perceptron_tagger_eng) and a
SoulX-Singer checkout for phone_set.json (SING_TEST_UPSTREAM). tests/run_all.sh runs this with
SING_TESTS_REQUIRE_VENV=1.
"""
import json
import os
import subprocess
import sys
import unittest

from _util import (SING, UPSTREAM, all_spike_cases, child_env, evidence, fixture_bytes, have_modules, need,
                   sha256_bytes, temp_dir)

from singlib import langs, score
from singlib.refusals import Refusal

PHONESET = os.path.join(UPSTREAM, "soulxsinger", "utils", "phoneme", "phone_set.json")
ALL = ("T1", "T2", "T1T2", "T2-sep", "T1-f0-110", "T1-plus2", "T3-30", "T3-60")
# Measured 2026-09-27 in the spike's venv-alt (g2p-en 2.1.0, nltk 3.9.2): the spike's rule vs the facade's.
NUMBERS = {
    "42": ("F-AO0-R-T-UW1-T-W-AA2", "F-AO1-R-T-IY0-T-UW1"),
    "1999": ("N-AY1-N-T-IY1-N-N-AY1-N-T-AY2-N-T-IY0", "N-AY1-N-T-IY1-N-N-AY1-N-T-IY0-N-AY1-N"),
    "2026": ("T-W-EH1-N-T-IY0-T-W-EH2-N-T-IY0-S-K-AY1-Z", "T-W-EH1-N-T-IY0-T-W-EH1-N-T-IY0-S-IH1-K-S"),
    "well-known": ("W-EH1-L-K-AO1-N-ER0", "W-EH1-L-N-OW1-N"),
}
SPOKEN = {"42": "forty two", "1999": "nineteen ninety nine", "2026": "twenty twenty six", "well-known": "well known"}

_G2P = None


def g2p():
    global _G2P
    need(have_modules("g2p_en", "nltk"), "g2p_en and nltk (the singing runtime's venv)")
    need(os.environ.get("NLTK_DATA"), "NLTK_DATA (the runtime's nltk_data)")
    if _G2P is None:
        from singlib.phonemes import G2PPhonemizer
        _G2P = G2PPhonemizer(os.environ["NLTK_DATA"])
    return _G2P


def phoneset():
    need(os.path.isfile(PHONESET), "upstream's phone_set.json at %s (SING_TEST_UPSTREAM)" % PHONESET)
    with open(PHONESET, encoding="utf-8") as f:
        return frozenset(json.load(f))


class RealG2P(unittest.TestCase):
    def test_all_eight_spike_fixtures_byte_for_byte_with_real_g2p(self):
        g, ps = g2p(), phoneset()
        for name in ALL:
            notes, words, kw = all_spike_cases()[name]
            meta, _ = score.build_from_beats(notes, words, phonemize=g, phoneset=ps, **kw)
            got = score.dump_meta_list([meta])
            self.assertEqual(got, fixture_bytes(name), name)
            if name in ("T1", "T2", "T1T2"):
                evidence("%s (real g2p_en + phone_set.json) == spike fixture: sha256 %s" % (name, sha256_bytes(got)))

    def test_the_spikes_words_are_unchanged_by_the_fix(self):
        g = g2p()
        words = {w for _, (_, ws, _) in all_spike_cases().items() for w, _ in ws}
        words |= {"Ooh", "wish", "nothing", "more", "the", "best", "don't", "O'Brien", "3rd", "$5"}
        for w in sorted(words):
            self.assertEqual(g(w), g.spike_rule(w), w)

    def test_numbers_and_hyphens_control_and_fix(self):
        g, ps = g2p(), phoneset()
        for word, (spike_tokens, facade_tokens) in NUMBERS.items():
            self.assertEqual("-".join(g.spike_rule(word)), spike_tokens, "CONTROL: the spike's rule on %r" % word)
            self.assertEqual("-".join(g(word)), facade_tokens, word)
            spoken = [t for part in SPOKEN[word].split() for t in g(part)]
            self.assertEqual(g(word), spoken, "%r must sing as %r" % (word, SPOKEN[word]))
            self.assertNotEqual(g(word), g.spike_rule(word), word)
            for ph in g(word):
                self.assertIn("en_" + ph, ps, (word, ph))

    def test_missing_nltk_data_fails_before_g2p_en_is_imported(self):
        need(have_modules("nltk"), "nltk (the singing runtime's venv)")
        home = temp_dir("nltk-missing")
        empty = os.path.join(home, "nltk_data")
        os.makedirs(empty)
        code = ("import sys; sys.path.insert(0, %r)\n"
                "from singlib.phonemes import G2PPhonemizer, NLTKDataMissing\n"
                "try:\n    G2PPhonemizer(%r)\n    print('NO-RAISE')\n"
                "except NLTKDataMissing as e:\n    print('RAISED', e)\n"
                "print('g2p_en imported:', 'g2p_en' in sys.modules)\n" % (SING, empty))
        env = child_env(HOME=home, NLTK_DATA=None)
        env.pop("NLTK_DATA", None)
        r = subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("RAISED", r.stdout)
        self.assertIn("averaged_perceptron_tagger_eng", r.stdout)
        self.assertIn("g2p_en imported: False", r.stdout)
        # positive control: the same probe with the real data does not raise
        env["NLTK_DATA"] = os.environ.get("NLTK_DATA", "")
        need(env["NLTK_DATA"], "NLTK_DATA")
        r = subprocess.run([sys.executable, "-c", code.replace(repr(empty), repr(env["NLTK_DATA"]))], env=env,
                           capture_output=True, text=True, timeout=300)
        self.assertIn("NO-RAISE", r.stdout, r.stderr)


_LEX = None


def lexicon():
    global _LEX
    need(have_modules("g2pM", "ToJyutping"), "g2pM and ToJyutping (the singing runtime's venv)")
    if _LEX is None:
        from singlib.phonemes import Lexicon
        _LEX = Lexicon()
    return _LEX


def tokens(chars, lang, ps):
    """Every character its own word on its own note, through the converter: -> (tokens, substitutions)."""
    words = [(c, [i]) for i, c in enumerate(chars)]
    notes = [(60, 0.5 * i, 0.5 * (i + 1)) for i in range(len(chars))]
    meta, info = score.build_meta(notes, words, phonemize=lambda w: ["AH0"], phoneset=ps, langs=[lang] * len(words),
                                  lexicon=lexicon())
    return [t for t in meta["phoneme"].split() if t != score.SP], info["substitutions"]


class RealChinese(unittest.TestCase):
    ZH_LINES = {"一闪一闪亮晶晶": "yi1 shan3 yi1 shan3 liang4 jing1 jing1",       # W8-SX probe P-B, the same g2pM
                "满天都是小星星": "man3 tian1 dou1 shi4 xiao3 xing1 xing1",
                "我爱你": "wo3 ai4 ni3", "你好世界": "ni3 hao3 shi4 jie4",
                "银行行长": "yin2 hang2 xing2 zhang3"}                           # a polyphone read by its neighbours
    YUE_LINES = {"一閃一閃亮晶晶": "jat1 sim2 jat1 sim2 loeng6 zing1 zing1", "我的心情": "ngo5 dik1 sam1 cing4"}

    def test_mandarin_lines(self):
        ps, _ = phoneset(), lexicon()                                         # lexicon() skips (or fails) first
        from g2pM import G2pM
        g = G2pM()
        for line, want in self.ZH_LINES.items():
            toks, subs = tokens(line, "zh", ps)
            self.assertEqual(toks, ["zh_" + x for x in want.split()], line)
            self.assertEqual(subs, [], line)
            # the facade's one-call-per-run, char_split=True mapping == upstream's own call on an all-Chinese line
            self.assertEqual(toks, ["zh_" + x for x in g(line, tone=True, char_split=False)], line)

    def test_cantonese_lines(self):
        ps = phoneset()
        for line, want in self.YUE_LINES.items():
            toks, subs = tokens(line, "yue", ps)
            self.assertEqual(toks, ["yue_" + x for x in want.split()], line)
            self.assertEqual(subs, [], line)

    def test_tone_fallback_against_the_real_phone_set(self):
        ps = phoneset()
        self.assertNotIn("zh_dui3", ps)                                       # W8-SX: a g2pM class the set lacks
        present = [t for t in langs.TONES["zh"] if "zh_dui" + t in ps]
        rank = lexicon().tone_rank("zh", "dui")
        self.assertTrue(rank and present, (rank, present))
        best = [t for t in rank if t in present][0]
        toks, subs = tokens(["dui3"], "zh", ps)
        self.assertEqual((toks, subs), (["zh_dui" + best], [{"word": "dui3", "asked": "dui3", "used": "dui" + best}]))
        self.assertNotIn("yue_gan3", ps)                                      # W8-SX's Cantonese misses: gan3
        present = [t for t in langs.TONES["yue"] if "yue_gan" + t in ps]
        best = [t for t in lexicon().tone_rank("yue", "gan") if t in present][0]
        toks, subs = tokens(["gan3"], "yue", ps)
        self.assertEqual((toks, subs), (["yue_gan" + best], [{"word": "gan3", "asked": "gan3", "used": "gan" + best}]))
        for word, lang, why in (("喆", "zh", "no single sung syllable"),      # g2pM echoes a character it can't read
                                ("ngat6", "yue", "knows no tone of 'ngat'")):  # no tone of the base in the set at all
            with self.assertRaises(Refusal) as cm:
                tokens([word], lang, ps)
            self.assertEqual(cm.exception.code, "unknownPhone")
            self.assertIn(repr(word), cm.exception.message)
            self.assertIn(why, cm.exception.message)

    def test_coverage_over_g2pms_own_vocabulary(self):
        """Measured, one character at a time (as W8-SX's probe P-B): singable directly, after the tone fallback, or
        refused (with why). Invariants: every emitted token is in the phone set, a substitution only ever changes the
        tone, and the fallback never makes a character unsingable."""
        import pickle
        import re
        ps, _ = phoneset(), lexicon()
        import g2pM as pkg
        with open(os.path.join(os.path.dirname(pkg.__file__), "char2idx.pkl"), "rb") as f:
            vocab = [c for c in pickle.load(f) if isinstance(c, str) and len(c) == 1 and re.match(r"[一-鿿]", c)]
        self.assertEqual(len(vocab), 5207)
        report = {}
        for lang in ("zh", "yue"):
            n = {"direct": 0, "fallback": 0, "refusedNoSyllable": 0, "refusedNoTone": 0}
            refused = []
            for c in vocab:
                try:
                    toks, subs = tokens(c, lang, ps)
                except Refusal as e:
                    self.assertEqual(e.code, "unknownPhone", (c, e.message))
                    kind = "refusedNoTone" if "knows no tone" in e.message else "refusedNoSyllable"
                    self.assertTrue(kind == "refusedNoTone" or "no single sung syllable" in e.message, e.message)
                    n[kind] += 1
                    refused.append(c)
                    continue
                self.assertIn(toks[0], ps, c)
                if subs:
                    self.assertEqual(langs.split_tone(subs[0]["asked"])[0], langs.split_tone(subs[0]["used"])[0], c)
                    n["fallback"] += 1
                else:
                    n["direct"] += 1
            report[lang] = dict(n, singable="%.2f%%" % (100.0 * (n["direct"] + n["fallback"]) / len(vocab)),
                                refusedSample="".join(refused[:12]))
            self.assertEqual(sum(v for k, v in n.items()), len(vocab))
        evidence("coverage over g2pM's %d vocabulary characters: %s" % (len(vocab),
                                                                         json.dumps(report, ensure_ascii=False)))
        self.assertGreaterEqual(report["zh"]["direct"] + report["zh"]["fallback"], 5137)    # W8-SX's direct count
        self.assertGreaterEqual(report["yue"]["direct"] + report["yue"]["fallback"], 5085)


if __name__ == "__main__":
    unittest.main()
