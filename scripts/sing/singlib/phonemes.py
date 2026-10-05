"""g2p_en phonemizer for the facade (runtime venv only).

The spike's rule (`score_from_notes.py` g2p()): `[t for t in G2p()(word.lower()) if t.strip() and t[0].isalpha()]`,
with ONE measured correction for numbers and hyphens (design §3.2 "Numbers ... are sung through g2p_en's own
normalisation [A: item p2-sing-b's tests confirm this]" - they did NOT, as written):

  g2p_en expands "42" to "forty-two" and then tokenizes that as ONE word. It is not in cmudict, so the neural
  predictor spells it with the hyphen as <unk>: "42" -> F-AO0-R-T-UW1-T-W-AA2 (measured 2026-09-27, spike venv).
  "1999" and "2026" lose their last word the same way, and so does any hyphenated word ("well-known" ->
  W-EH1-L-K-AO1-N-ER0).

  So the facade expands numbers FIRST, with g2p_en's own `normalize_numbers`, and turns hyphens into spaces:
  "42" -> "forty two" -> F-AO1-R-T-IY0-T-UW1. A word with no digit, currency sign or hyphen is passed through
  unchanged, so every word the spike ever sang (and its T1/T2/T1T2 bytes) is unaffected; test_score.py pins both
  the defect (as the control) and the fix.

NEVER a download at run time: g2p_en calls `nltk.download()` at IMPORT when its data is missing, and nltk 3.9.2
also needs `averaged_perceptron_tagger_eng`, which g2p_en never fetches (spike deviations 14:31:57). So every
resource is looked up with `nltk.data.find` FIRST, and a missing one raises before g2p_en is imported.
"""

REQUIRED_NLTK = (
    "corpora/cmudict.zip",                    # g2p_en import-time check
    "taggers/averaged_perceptron_tagger.zip",  # g2p_en import-time check
    "taggers/averaged_perceptron_tagger_eng",  # nltk 3.9.2 pos_tag (nltk/tag/perceptron.py:277)
)


class NLTKDataMissing(RuntimeError):
    pass


def check_nltk_data(nltk_data_dir=None):
    import nltk
    if nltk_data_dir and nltk_data_dir not in nltk.data.path:
        nltk.data.path.insert(0, nltk_data_dir)
    missing = []
    for res in REQUIRED_NLTK:
        try:
            nltk.data.find(res)
        except LookupError:
            missing.append(res)
    if missing:
        raise NLTKDataMissing("NLTK data missing (the installer's nltk step puts it in <runtime>/nltk_data): "
                              + ", ".join(missing))


class G2PPhonemizer:
    def __init__(self, nltk_data_dir=None):
        check_nltk_data(nltk_data_dir)
        from g2p_en import G2p                        # only after the data check: its import-time download
        from g2p_en.expand import normalize_numbers   # is then a no-op
        self._g2p = G2p()
        self._normalize_numbers = normalize_numbers

    def spike_rule(self, word):
        """The spike's rule, unchanged (kept for the tests' control)."""
        return [t for t in self._g2p(word.lower()) if t.strip() and t[0].isalpha()]

    def __call__(self, word):
        pre = self._normalize_numbers(word.lower()).replace("-", " ")
        return [t for t in self._g2p(pre) if t.strip() and t[0].isalpha()]
