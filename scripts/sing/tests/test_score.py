"""The converter (singlib/score.py) against the spike's own fixtures, byte for byte, plus its rules.

THE GATE (design §9, p2-sing-b): the converter reproduces the spike's T1, T2 and T1T2 JSON byte for byte.
The spike's files are vendored in tests/fixtures/spike/ (byte copies of ~/DAWPro-spikes/sing-soulx/fixtures/*.json;
test_vendored_copies_are_the_spikes proves the copies exact whenever the spike is on this Mac). Phonemes come from a
table (the tokens the spike's own files carry), so this runs under the system python; test_venv_g2p.py repeats the
gate with the real g2p_en and upstream's phone_set.json.
"""
import json
import os
import unittest

from _util import (FIXTURES, SPIKE, T2_NOTES, T2_WORDS, all_spike_cases, evidence, fixture_bytes, need_machine,
                   phrase_request, sha256_bytes, spike_cases, table_phonemize)

from singlib import schema, score
from singlib.refusals import Refusal

GATE = ("T1", "T2", "T1T2")
ALL = ("T1", "T2", "T1T2", "T2-sep", "T1-f0-110", "T1-plus2", "T3-30", "T3-60")
SPIKE_FIXTURES = os.path.join(SPIKE, "fixtures")


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
        need_machine(os.path.isdir(SPIKE_FIXTURES), "the spike's fixtures folder %s" % SPIKE_FIXTURES)
        for name in ALL:
            with open(os.path.join(SPIKE_FIXTURES, name + ".json"), "rb") as f:
                self.assertEqual(f.read(), fixture_bytes(name), name)

    def test_info_matches_the_spikes_manifest(self):
        man = os.path.join(SPIKE_FIXTURES, "fixtures-manifest.json")
        need_machine(os.path.isfile(man), "the spike's %s" % man)
        with open(man) as f:
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
