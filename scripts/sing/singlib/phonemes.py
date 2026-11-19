"""g2p_en phonemizer for the facade (runtime venv only), and (facadeVersion 2) the Mandarin and Cantonese lexicon.

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


# ------------------------------------------------------------------------- facadeVersion 2: Chinese (design §6.4)
# Both libraries are already in requirements.lock and the installed venv (g2pm 0.1.2.5, tojyutping 3.2.0); NEITHER is
# imported until the first request that has a Mandarin or Cantonese word, so an English-only process imports exactly
# what it did before (test P8). Licences: g2pM is Apache 2.0, but its digest_cedict.pkl is CC-CEDICT content (CC BY-SA
# 4.0); ToJyutping is BSD 2-Clause, its trie.txt's source is unstated. DAW Pro does not distribute either (the user's
# Mac installs them from PyPI); see the x2 licence note before ever bundling them.

def _rank(counts):
    """{tone: count} -> tones, most common first; ties go to the lower tone number."""
    return sorted(counts, key=lambda t: (-counts[t], t))


class MandarinPhonemizer:
    """g2pM over a run of Chinese characters, ONE syllable per character. char_split=True: with char_split=False
    g2pM merges neighbouring digits and unknown characters into one item (measured 2026-10-06: 我20你 -> 3 items for
    4 characters), which would shift every later syllable onto the wrong note; on all-Chinese runs the two agree.
    An unknown character comes back as itself (喆 -> 喆) and a few have a two-syllable reading (shi2 ke4); the
    converter refuses both as unknownPhone."""

    def __init__(self):
        from g2pM import G2pM
        self._g = G2pM()
        self._ranks = None

    def syllables(self, chars):
        return list(self._g(chars, tone=True, char_split=True))

    def tone_rank(self, base):
        """The tones of `base`, most common first, counted over g2pM's own dictionary (every reading of every
        character), in memory, once per process [A: design §6.4; x9's character word check decides]."""
        if self._ranks is None:
            from . import langs
            counts = {}
            for prons in self._g.cedict.values():
                for p in prons:
                    if langs.is_syllable("zh", p):
                        b, t = langs.split_tone(p)
                        counts.setdefault(b, {}).setdefault(t, 0)
                        counts[b][t] += 1
            self._ranks = {b: _rank(c) for b, c in counts.items()}
        return self._ranks.get(base, [])


class CantonesePhonemizer:
    """ToJyutping over a run of Chinese characters: get_jyutping_list gives one (character, jyutping or None) per
    character, also inside a multi-character dictionary word (measured: 銀行 -> ngan4, hong4)."""

    def __init__(self):
        import ToJyutping
        self._tj = ToJyutping
        self._ranks = None

    def syllables(self, chars):
        return [j for _, j in self._tj.get_jyutping_list(chars)]

    def tone_rank(self, base):
        """The tones of `base`, most common first, counted over ToJyutping's own reading of every character in
        U+4E00-U+9FFF taken alone (its public API; 0.14 s, measured), in memory, once per process [A]."""
        if self._ranks is None:
            from . import langs
            counts = {}
            for cp in range(0x4E00, 0xA000):
                j = self._tj.get_jyutping_list(chr(cp))[0][1]
                if langs.is_syllable("yue", j):
                    b, t = langs.split_tone(j)
                    counts.setdefault(b, {}).setdefault(t, 0)
                    counts[b][t] += 1
            self._ranks = {b: _rank(c) for b, c in counts.items()}
        return self._ranks.get(base, [])


class Lexicon:
    """lang -> its phonemiser, built on first use (the converter's `lexicon`: syllables(lang, chars) and
    tone_rank(lang, base)). Renders are serialized by the facade's one inference lock."""
    FACTORIES = {"zh": MandarinPhonemizer, "yue": CantonesePhonemizer}

    def __init__(self, factories=None):
        self._factories = dict(self.FACTORIES if factories is None else factories)
        self._made = {}

    def _get(self, lang):
        if lang not in self._made:
            self._made[lang] = self._factories[lang]()
        return self._made[lang]

    def syllables(self, lang, chars):
        return self._get(lang).syllables(chars)

    def tone_rank(self, lang, base):
        return self._get(lang).tone_rank(base)

    def loaded(self):
        return sorted(self._made)
