"""The converter (singlib/score.py) against the spike's own fixtures, byte for byte, plus its rules.

THE GATE (design §9, p2-sing-b): the converter reproduces the spike's T1, T2 and T1T2 JSON byte for byte.
The spike's files are vendored in tests/fixtures/spike/ (byte copies of ~/DAWPro-spikes/sing-soulx/fixtures/*.json and
its fixtures-manifest.json; test_vendored_copies_are_the_spikes checks them against sha256s measured from the spike
itself on 2026-10-06, before that folder was deleted). Phonemes come from a
table (the tokens the spike's own files carry), so this runs under the system python; test_venv_g2p.py repeats the
gate with the real g2p_en and upstream's phone_set.json.
"""
import json
import os
import unittest

from _util import (FIXTURES, T2_NOTES, T2_WORDS, all_spike_cases, evidence, fixture_bytes,
                   phrase_request, sha256_bytes, spike_cases, table_phonemize)

from singlib import schema, score
from singlib.refusals import Refusal

GATE = ("T1", "T2", "T1T2")
ALL = ("T1", "T2", "T1T2", "T2-sep", "T1-f0-110", "T1-plus2", "T3-30", "T3-60")
MANIFEST = os.path.join(FIXTURES, "spike", "fixtures-manifest.json")
# sha256 of the spike's own fixtures/<name>.json and fixtures-manifest.json, measured by W8-SFIX on 2026-10-06 from
# ~/DAWPro-spikes/sing-soulx/fixtures/ AND from the vendored copies (identical), before the spike folder was deleted.
SPIKE_SHA256 = {
    "T1": "83e5baf016dd2d5556e8bf28a28d6dac19fbed67ae862ca5887541b7a5c08796",
    "T2": "d70dc04e8527ad111845dd2da248fd3a8de81c1e07a856c5137db49af5ee5eae",
    "T1T2": "e44eaa9a0cc31d86525b34217b8392221c7eb91ea6d5e915f2239920c5fc0626",
    "T2-sep": "ff22a7680fd96eb50fb233e4d2afc815067a454fb6787819a5f905dd61d177b0",
    "T1-f0-110": "3ed34981d96d04a9d6417f6fcac00b5c36252886f7d8bee4e9f8fe7d009ed516",
    "T1-plus2": "39290d4f3769cc1297ca213a3003c6f96a7872023e7fe9e1bb3a67f967839d31",
    "T3-30": "40a77641643d0eab560241ede8b9d285649fdbc04bd0ab9a08eca72299cc7a12",
    "T3-60": "8db9c70725979d6bd21072cad52a2ac2d82311c7bf540c7657659a23dd194f24",
    "fixtures-manifest": "cd7ccf71252bbc4db0e36999520f7dcf9b087bfd9a8d604043770b9cf15ff420",
}


def build(name):
    notes, words, kw = all_spike_cases()[name]
    return score.build_from_beats(notes, words, phonemize=table_phonemize, **kw)


def entries(meta):
    keys = ("duration", "text", "phoneme", "note_pitch", "note_type")
    cols = [meta[k].split() for k in keys]
    return [dict(zip(keys, row)) for row in zip(*cols)]


class SpikeBytes(unittest.TestCase):
    def test_gate_T1_T2_T1T2_byte_for_byte(self):
        for name in GATE:
            meta, _ = build(name)
            got, want = score.dump_meta_list([meta]), fixture_bytes(name)
            self.assertEqual(got, want, name)
            evidence("%s converter bytes == spike fixture: %d B sha256 %s" % (name, len(got), sha256_bytes(got)))

    def test_gate_through_the_facade_request(self):
        """The same bytes when the notes arrive as the facade's JSON request (seconds, through parse + validate)."""
        for name in GATE:
            notes, words = spike_cases()[name]
            raw = json.dumps(phrase_request(notes, words, "/x/out.wav")).encode("utf-8")
            r = schema.validate(schema.parse_body(raw))
            meta, _ = score.build_meta(r.notes, r.words, lead=r.lead, trail=r.trail, phonemize=table_phonemize)
            self.assertEqual(score.dump_meta_list([meta]), fixture_bytes(name), name)

    def test_the_spikes_other_five_fixtures_byte_for_byte(self):
        for name in ALL[3:]:
            meta, _ = build(name)
            self.assertEqual(score.dump_meta_list([meta]), fixture_bytes(name), name)

    def test_the_comparison_can_fail(self):
        """Negative controls: one pitch, the lead, or one phoneme each change the bytes."""
        notes, words, _ = all_spike_cases()["T1"]
        moved = [(61, 0, 1)] + list(notes[1:])
        meta, _ = score.build_from_beats(moved, words, phonemize=table_phonemize)
        self.assertNotEqual(score.dump_meta_list([meta]), fixture_bytes("T1"))
        meta, _ = score.build_from_beats(notes, words, lead=0.25, phonemize=table_phonemize)
        self.assertNotEqual(score.dump_meta_list([meta]), fixture_bytes("T1"))
        other = lambda w: ["AH0"] if w.lower() == "star" else table_phonemize(w)   # noqa: E731
        meta, _ = score.build_from_beats(notes, words, phonemize=other)
        self.assertNotEqual(score.dump_meta_list([meta]), fixture_bytes("T1"))

    def test_vendored_copies_are_the_spikes(self):
        for name in ALL:
            self.assertEqual(sha256_bytes(fixture_bytes(name)), SPIKE_SHA256[name], name)
        with open(MANIFEST, "rb") as f:
            self.assertEqual(sha256_bytes(f.read()), SPIKE_SHA256["fixtures-manifest"])

    def test_info_matches_the_spikes_manifest(self):
        with open(MANIFEST) as f:
            manifest = json.load(f)
        for name in ALL:
            _, info = build(name)
            want = manifest[name]
            for k in ("entries", "notes", "total_ms", "mel_frames"):
                self.assertEqual(info[k], want[k], (name, k))
            self.assertEqual([list(x) for x in info["score_notes_s"]], want["score_notes_s"], name)


class Rules(unittest.TestCase):
    def test_rests_lead_gap_and_trail(self):
        meta, _ = build("T2")
        rows = entries(meta)
        rests = [i for i, r in enumerate(rows) if r["phoneme"] == score.SP]
        self.assertEqual(rests, [0, 5, 7])                     # lead, the 1-beat gap before "now", trail
        self.assertEqual([rows[i]["duration"] for i in rests], ["0.24", "0.60", "0.24"])
        for i in rests:
            self.assertEqual((rows[i]["text"], rows[i]["note_pitch"], rows[i]["note_type"]), (score.SP, "0", "1"))
        self.assertEqual(meta["language"], "English")
        self.assertNotIn("f0", meta)

    def test_a_word_on_k_notes_is_k_entries_with_the_whole_words_phonemes(self):
        meta, _ = build("T2")
        me = [r for r in entries(meta) if r["text"] == "me"]
        self.assertEqual([r["phoneme"] for r in me], ["en_M-IY1"] * 3)
        self.assertEqual([r["note_type"] for r in me], ["2", "3", "3"])
        self.assertEqual([r["note_pitch"] for r in me], ["65", "67", "69"])
        sep, _ = build("T2-sep")                              # the spike's positive control: three words "me"
        self.assertEqual([r["note_type"] for r in entries(sep) if r["text"] == "me"], ["2", "2", "2"])

    def test_boundaries_are_rounded_cumulatively_never_per_duration(self):
        third = 1.0 / 3.0
        notes = [(60, i * third, (i + 1) * third) for i in range(50)]
        words = [("hold", [i]) for i in range(50)]
        meta, info = score.build_meta(notes, words, phonemize=table_phonemize)
        durs = [float(d) for d in meta["duration"].split()]
        true_end = 0.24 + 50 * third + 0.24
        self.assertLess(abs(sum(durs) - true_end), 0.0051)
        self.assertEqual(info["total_ms"], int(round(round(true_end * 100) / 100 * 1000)))
        per_duration = 0.24 + sum(round(third, 2) for _ in range(50)) + 0.24   # the rule the spike refused
        self.assertGreater(abs(per_duration - true_end), 0.1)

    def test_a_rest_that_rounds_to_zero_is_dropped_and_nothing_moves(self):
        base = [(60, 0.0, 1.0), (62, 1.0, 2.0)]
        gap4ms = [(60, 0.0, 1.0), (62, 1.004, 2.0)]
        words = [("hold", [0]), ("now", [1])]
        a, _ = score.build_meta(base, words, phonemize=table_phonemize)
        b, _ = score.build_meta(gap4ms, words, phonemize=table_phonemize)
        self.assertEqual(score.dump_meta_list([a]), score.dump_meta_list([b]))
        self.assertNotIn("0.00", b["duration"].split())

    def test_a_note_shorter_than_the_grid_is_refused(self):
        with self.assertRaises(Refusal) as cm:
            score.build_meta([(60, 0.0, 1.0), (62, 1.0, 1.004)], [("hold", [0]), ("now", [1])],
                             phonemize=table_phonemize)
        self.assertEqual(cm.exception.code, "badRequest")
        self.assertIn("now", cm.exception.message)

    def test_overlap_and_coverage(self):
        with self.assertRaises(Refusal) as cm:
            score.build_meta([(60, 0.0, 1.0), (62, 0.5, 2.0)], [("hold", [0]), ("now", [1])],
                             phonemize=table_phonemize)
        self.assertEqual(cm.exception.code, "notesOverlap")
        with self.assertRaises(Refusal) as cm:
            score.build_meta([(60, 0.0, 1.0), (62, 1.0, 2.0)], [("hold", [0])], phonemize=table_phonemize)
        self.assertEqual(cm.exception.code, "wordsDoNotCoverNotes")

    def test_empty_word_and_unknown_phone_name_the_word(self):
        with self.assertRaises(Refusal) as cm:
            score.build_meta([(60, 0.0, 1.0)], [("!!", [0])], phonemize=lambda w: [])
        self.assertEqual(cm.exception.code, "emptyWord")
        self.assertIn("!!", cm.exception.message)
        phoneset = {"en_" + p for w in ("hold", "me") for p in table_phonemize(w)}
        with self.assertRaises(Refusal) as cm:
            score.build_meta([(60, 0.0, 1.0)], [("now", [0])], phonemize=table_phonemize, phoneset=phoneset)
        self.assertEqual(cm.exception.code, "unknownPhone")
        self.assertIn("now", cm.exception.message)
        meta, _ = score.build_meta([(60, 0.0, 1.0)], [("hold", [0])], phonemize=table_phonemize, phoneset=phoneset)
        self.assertIn("en_HH-OW1-L-D", meta["phoneme"])        # control: a known word passes the same phone set

    def test_frames_and_output_samples(self):
        for name, frames, samples in (("T1", 503, 241920), ("T2", 204, 97920), ("T1T2", 733, 352320)):
            meta, info = build(name)
            self.assertEqual(score.mel_frames(meta), frames, name)
            self.assertEqual(info["mel_frames"], frames, name)
            self.assertEqual(score.output_samples_24k(meta), samples, name)

    def test_bounds_are_the_running_sum(self):
        meta, _ = build("T2")
        b = score.bounds_of(meta)
        self.assertEqual(len(b), len(meta["duration"].split()) + 1)
        self.assertAlmostEqual(b[-1], meta["time"][1] / 1000.0, places=9)


class TableLexicon(object):
    """An injected lexicon (no venv): readings from a table, ranks from a table, and a log of every call."""

    def __init__(self, readings, ranks=None):
        self.readings, self.ranks, self.calls = readings, ranks or {}, []

    def syllables(self, lang, chars):
        self.calls.append((lang, chars))
        return [self.readings.get((lang, c)) for c in chars]

    def tone_rank(self, lang, base):
        return self.ranks.get((lang, base), [])


ZH = {("zh", c): r for c, r in zip("一闪亮晶我爱你行长银", ["yi1", "shan3", "liang4", "jing1", "wo3", "ai4", "ni3",
                                                        "xing2", "zhang3", "yin2"])}
ZH.update({("zh", "对"): "dui3", ("zh", "喆"): "喆", ("zh", "兛"): "shi2 ke4", ("zh", "嗯"): "m2", ("zh", "绿"): "lu:4"})
YUE = {("yue", c): r for c, r in zip("一閃亮晶我的心情", ["jat1", "sim2", "loeng6", "zing1", "ngo5", "dik1", "sam1", "cing4"])}
YUE.update({("yue", "兀"): "ngat6"})
READINGS = dict(ZH)
READINGS.update(YUE)
# a phone set with every token above EXCEPT zh_dui3 (as in the real set: dui1/dui4 only), zh_m2 (no zh_m* at all)
# and yue_ngat6 (ngat1 only)
PHONESET = frozenset({"zh_" + r for (lang, _), r in ZH.items() if lang == "zh" and r and " " not in r}
                     | {"yue_" + r for (lang, _), r in YUE.items() if r} | {"zh_dui1", "zh_dui4", "yue_ngat1",
                                                                              "zh_ni3", "zh_hao3", "zh_lu:4", "en_HH",
                                                                              "en_OW1", "en_L", "en_D"}) \
    - {"zh_dui3", "zh_m2", "yue_ngat6"}


def zh_meta(chars, langs=None, lexicon=None, phoneset=None, english=()):
    """One word per note, 0.5 s each; `english` = indices that are English words (sung through the table)."""
    words = [(c, [i]) for i, c in enumerate(chars)]
    notes = [(60 + i, 0.5 * i, 0.5 * (i + 1)) for i in range(len(chars))]
    langs = langs or ["en" if i in english else "zh" for i in range(len(chars))]
    return score.build_meta(notes, words, phonemize=table_phonemize, phoneset=phoneset, langs=langs,
                            lexicon=lexicon if lexicon is not None else TableLexicon(READINGS))


class Languages(unittest.TestCase):
    """facadeVersion 2's per-language tokens (design 2026-10-06 §6.4), with an injected lexicon (no venv)."""

    def phonemes(self, meta):
        return [r["phoneme"] for r in entries(meta) if r["phoneme"] != score.SP]

    def test_all_english_langs_build_todays_bytes_for_every_spike_case(self):
        for name in ALL:
            notes, words, kw = all_spike_cases()[name]
            want, _ = build(name)
            meta, info = score.build_from_beats(notes, words, phonemize=table_phonemize, langs=["en"] * len(words),
                                                lexicon=None, **kw)
            self.assertEqual(score.dump_meta_list([meta]), score.dump_meta_list([want]), name)
            self.assertEqual(score.dump_meta_list([meta]), fixture_bytes(name), name)
            self.assertEqual(info["substitutions"], [])

    def test_a_mandarin_run_is_one_call_and_one_token_per_character(self):
        lex = TableLexicon(ZH)
        meta, info = zh_meta("一闪一闪亮晶晶", lexicon=lex, phoneset=PHONESET)
        self.assertEqual(lex.calls, [("zh", "一闪一闪亮晶晶")])
        self.assertEqual(self.phonemes(meta), ["zh_yi1", "zh_shan3", "zh_yi1", "zh_shan3", "zh_liang4", "zh_jing1",
                                               "zh_jing1"])
        self.assertEqual(meta["language"], "Mandarin")
        self.assertEqual(meta["text"].split()[1:-1], list("一闪一闪亮晶晶"))
        self.assertEqual(info["substitutions"], [])

    def test_an_english_word_or_a_typed_syllable_splits_the_run(self):
        lex = TableLexicon(ZH)
        meta, _ = zh_meta(["我", "爱", "hold", "你"], lexicon=lex, phoneset=PHONESET, english=(2,))
        self.assertEqual(lex.calls, [("zh", "我爱"), ("zh", "你")])
        self.assertEqual(self.phonemes(meta), ["zh_wo3", "zh_ai4", "en_HH-OW1-L-D", "zh_ni3"])
        lex = TableLexicon(ZH)
        meta, _ = zh_meta(["我", "NI3", "你", "lv4"], lexicon=lex, phoneset=PHONESET)
        self.assertEqual(lex.calls, [("zh", "我"), ("zh", "你")])
        self.assertEqual(self.phonemes(meta), ["zh_wo3", "zh_ni3", "zh_ni3", "zh_lu:4"])

    def test_a_chinese_word_on_k_notes_is_k_entries_of_one_token(self):
        meta, _ = score.build_meta([(60, 0.0, 0.5), (62, 0.5, 1.0), (64, 1.0, 1.5)], [("我", [0, 1]), ("你", [2])],
                                   phonemize=table_phonemize, phoneset=PHONESET, langs=["zh", "zh"],
                                   lexicon=TableLexicon(ZH))
        rows = [r for r in entries(meta) if r["phoneme"] != score.SP]
        self.assertEqual([(r["phoneme"], r["note_type"]) for r in rows],
                         [("zh_wo3", "2"), ("zh_wo3", "3"), ("zh_ni3", "2")])

    def test_cantonese(self):
        meta, info = zh_meta("一閃亮晶我的心情", langs=["yue"] * 8, phoneset=PHONESET)
        self.assertEqual(self.phonemes(meta), ["yue_jat1", "yue_sim2", "yue_loeng6", "yue_zing1", "yue_ngo5",
                                               "yue_dik1", "yue_sam1", "yue_cing4"])
        self.assertEqual((meta["language"], info["substitutions"]), ("Cantonese", []))

    def test_tone_fallback_uses_the_rank_and_reports_each_substitution_once(self):
        lex = TableLexicon(ZH, ranks={("zh", "dui"): ["3", "4", "1"]})          # 3 is ranked first but missing
        meta, info = zh_meta("对我对", lexicon=lex, phoneset=PHONESET)
        self.assertEqual(self.phonemes(meta), ["zh_dui4", "zh_wo3", "zh_dui4"])
        self.assertEqual(info["substitutions"], [{"word": "对", "asked": "dui3", "used": "dui4"}])
        lex = TableLexicon(ZH, ranks={("zh", "dui"): ["1", "4"]})
        self.assertEqual(self.phonemes(zh_meta("对", lexicon=lex, phoneset=PHONESET)[0]), ["zh_dui1"])
        lex = TableLexicon(ZH)                                            # unranked: the lowest tone in the set
        self.assertEqual(self.phonemes(zh_meta("对", lexicon=lex, phoneset=PHONESET)[0]), ["zh_dui1"])
        meta, info = zh_meta("兀", langs=["yue"], phoneset=PHONESET)
        self.assertEqual((self.phonemes(meta), info["substitutions"]),
                         (["yue_ngat1"], [{"word": "兀", "asked": "ngat6", "used": "ngat1"}]))
        meta, info = zh_meta(["dui3"], lexicon=TableLexicon(ZH), phoneset=PHONESET)    # a typed syllable too
        self.assertEqual(info["substitutions"], [{"word": "dui3", "asked": "dui3", "used": "dui1"}])
        meta, info = zh_meta("对", lexicon=TableLexicon(ZH), phoneset=None)          # no phone set: no fallback
        self.assertEqual((self.phonemes(meta), info["substitutions"]), (["zh_dui3"], []))

    def test_no_sung_syllable_or_no_tone_in_the_set_is_unknown_phone_naming_the_character(self):
        for char, why in (("喆", "'喆'"), ("兛", "shi2 ke4"), ("嗯", "knows no tone of 'm'")):
            with self.assertRaises(Refusal) as cm:
                zh_meta(char, phoneset=PHONESET)
            self.assertEqual(cm.exception.code, "unknownPhone", char)
            self.assertIn(repr(char), cm.exception.message)
            self.assertIn(why, cm.exception.message)
        with self.assertRaises(Refusal) as cm:                       # Latin but not a syllable: never looked up
            zh_meta(["x"], langs=["yue"], phoneset=PHONESET)
        self.assertEqual(cm.exception.code, "badRequest")
        with self.assertRaises(Refusal) as cm:                       # a character the lexicon has no reading for
            zh_meta("心", langs=["zh"], phoneset=PHONESET)          # (心 has a Cantonese reading only, in the table)
        self.assertEqual(cm.exception.code, "unknownPhone")
        self.assertIn("None", cm.exception.message)

    def test_a_lexicon_that_miscounts_is_an_internal_error_not_a_shifted_line(self):
        class Short(TableLexicon):
            def syllables(self, lang, chars):
                return super(Short, self).syllables(lang, chars)[:-1]
        with self.assertRaises(Refusal) as cm:
            zh_meta("我爱你", lexicon=Short(ZH), phoneset=PHONESET)
        self.assertEqual(cm.exception.code, "badRequest")
        self.assertIn("Internal", cm.exception.message)

    def test_no_lexicon_is_language_not_supported(self):
        with self.assertRaises(Refusal) as cm:
            score.build_meta([(60, 0.0, 0.5)], [("我", [0])], phonemize=table_phonemize, langs=["zh"], lexicon=None)
        self.assertEqual(cm.exception.code, "languageNotSupported")


class PromptMeta(unittest.TestCase):
    NOTES = [(57, 0.24, 0.84, "hold", False), (59, 0.84, 1.14, "me", False), (60, 1.14, 1.44, "me", True),
             (62, 2.04, 3.24, "now", False)]

    def test_label_offset_moves_non_rest_labels_only(self):
        m0, _ = score.build_prompt_meta(self.NOTES, 5.0, phonemize=table_phonemize)
        m5, _ = score.build_prompt_meta(self.NOTES, 5.0, phonemize=table_phonemize, label_offset=5)
        p0 = [int(x) for x in m0["note_pitch"].split()]
        p5 = [int(x) for x in m5["note_pitch"].split()]
        self.assertEqual([b - a if a else b for a, b in zip(p0, p5)], [0 if a == 0 else 5 for a in p0])
        self.assertEqual(p5, [0, 62, 64, 65, 0, 67, 0])
        self.assertEqual(m0["duration"], m5["duration"])

    def test_lead_trail_and_continuations(self):
        meta, _ = score.build_prompt_meta(self.NOTES, 5.0, phonemize=table_phonemize)
        rows = entries(meta)
        self.assertEqual(rows[0]["duration"], "0.24")         # lead = the first label's start
        self.assertEqual(rows[-1]["duration"], "1.76")        # trail = window - the last label's end
        self.assertEqual(meta["time"], [0, 5000])
        self.assertEqual([r["note_type"] for r in rows if r["text"] == "me"], ["2", "3"])

    def test_bad_continuations_and_overlong_labels(self):
        with self.assertRaises(Refusal):
            score.prompt_words([(57, 0.2, 0.8, "hold", True)])
        with self.assertRaises(Refusal):
            score.prompt_words([(57, 0.2, 0.8, "hold", False), (59, 0.8, 1.0, "me", True)])
        with self.assertRaises(Refusal):
            score.build_prompt_meta(self.NOTES, 3.0, phonemize=table_phonemize)


if __name__ == "__main__":
    unittest.main()
