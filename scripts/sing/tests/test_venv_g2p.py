"""The converter with the REAL g2p_en and upstream's phone_set.json (runtime venv only).

  * the spike's eight fixtures, byte for byte, through singlib.phonemes.G2PPhonemizer (the facade's phonemizer);
  * the number/hyphen defect in the spike's rule (the CONTROL: it still exists) and the facade's fix;
  * every word the spike ever sang is phonemized exactly as the spike did (the fix is invisible on them);
  * missing NLTK data fails BEFORE g2p_en is imported (so its import-time download can never run).
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

from singlib import score

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


if __name__ == "__main__":
    unittest.main()
