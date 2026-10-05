"""The facade's request schema and its path rules (singlib/schema.py): every 400 the schema gives, and the
allowed-roots checks on the REALPATH (403), plus voiceNotFound (404) and referenceChanged (409).

Design §2.4's refusal table; §8 F11 (path traversal through the facade). Standard library only.
"""
import copy
import json
import os
import unicodedata
import unittest

from _util import T2_NOTES, T2_WORDS, own_voice, phrase_request, sha256_path, temp_dir, write_reference_wav

from singlib import schema
from singlib.refusals import Refusal


def base(**over):
    return phrase_request(T2_NOTES, T2_WORDS, "/x/out.wav", **over)


def own(**over):
    v = own_voice("/x/voices/v1/reference.wav", "ab" * 32)
    v.update(over)
    return v


class Validate(unittest.TestCase):
    def refused(self, obj, code, hooks=False, contains=None):
        with self.assertRaises(Refusal) as cm:
            schema.validate(obj, test_hooks=hooks)
        self.assertEqual(cm.exception.code, code, cm.exception.message)
        if contains:
            self.assertIn(contains, cm.exception.message)
        return cm.exception

    def test_a_valid_request(self):
        r = schema.validate(base())
        self.assertEqual(r.voice.kind, "builtin")
        self.assertEqual(r.notes[0], (64, 0.0, 0.6))
        self.assertEqual(r.words[1], ("me", [1, 2, 3]))
        self.assertEqual((r.lead, r.trail, r.seed, r.n_steps, r.cfg, r.out_sr), (0.24, 0.24, 20260924, 32, 3.0, 48000))
        self.assertIsNone(r.test_prompt_f0)

    def test_a_valid_own_voice(self):
        r = schema.validate(base(voice=own(promptLabelOffset=-12)))
        v = r.voice
        self.assertEqual((v.kind, v.window_start, v.window_end, v.label_offset), ("own", 0.0, 5.0, -12))
        self.assertEqual(v.prompt_notes[2], (60, 1.14, 1.44, "me", True))
        self.assertEqual(v.sha256, "ab" * 32)

    def test_body_parsing(self):
        for raw in (b"{", b"[]", b'"x"', b"\xff\xfe", b'{"a": NaN}', b'{"a": Infinity}', b'{"a": -Infinity}'):
            with self.assertRaises(Refusal) as cm:
                schema.parse_body(raw)
            self.assertEqual(cm.exception.code, "badRequest", raw)
        self.assertEqual(schema.parse_body(b'{"a": 1}'), {"a": 1})

    def test_unknown_keys_are_refused_at_every_level(self):
        cases = [("the request", lambda o: o.update(extra=1)),
                 ("phrase", lambda o: o["phrase"].update(extra=1)),
                 ("phrase.notes[0]", lambda o: o["phrase"]["notes"][0].update(velocity=90)),
                 ("phrase.words[0]", lambda o: o["phrase"]["words"][0].update(extra=1)),
                 ("voice", lambda o: o["voice"].update(extra=1))]
        for where, mutate in cases:
            o = base()
            mutate(o)
            self.refused(o, "badRequest", contains=where)
        for where, mutate in (("voice", lambda v: v.update(extra=1)),
                              ("voice.prompt", lambda v: v["prompt"].update(extra=1)),
                              ("voice.prompt.notes[1]", lambda v: v["prompt"]["notes"][1].update(extra=1))):
            v = own()
            mutate(v)
            self.refused(base(voice=v), "badRequest", contains=where)

    def test_missing_keys(self):
        for k in schema.TOP_KEYS:
            o = base()
            del o[k]
            self.refused(o, "badRequest", contains=k)

    def test_facade_version(self):
        for fv in (2, 0, True, "1", 1.0):
            self.refused(base(facadeVersion=fv), "badRequest", contains="facadeVersion")

    def test_note_values(self):
        for field, value in (("midi", 0), ("midi", 128), ("midi", 60.5), ("midi", True), ("startS", -0.1),
                             ("startS", "0"), ("endS", 0.0)):
            o = base()
            o["phrase"]["notes"][0][field] = value
            self.refused(o, "badRequest")

    def test_unsorted_and_overlapping_notes(self):
        o = base()
        n = o["phrase"]["notes"]
        n[0], n[1] = n[1], n[0]
        self.refused(o, "notesUnsorted")
        o = base()
        o["phrase"]["notes"][1]["startS"] = 0.5            # starts before note 0 ends at 0.6
        self.refused(o, "notesOverlap")
        o = base()
        o["phrase"]["notes"][0]["endS"] = 0.6              # touching (end == next start) is legato, not overlap
        schema.validate(o)

    def test_word_coverage(self):
        def words(*ws):
            return base(phrase={"notes": base()["phrase"]["notes"],
                                "words": [{"text": t, "noteIndices": i} for t, i in ws]})
        self.refused(words(("hold", [0]), ("me", [1, 2, 3])), "wordsDoNotCoverNotes", contains="Note 4 has no word")
        self.refused(words(("hold", [0, 1]), ("me", [1, 2, 3]), ("now", [4])), "wordsDoNotCoverNotes",
                     contains="two words")
        self.refused(words(("hold", [0]), ("me", [1, 3]), ("x", [2]), ("now", [4])), "wordsDoNotCoverNotes",
                     contains="contiguous")
        self.refused(words(("hold", [0]), ("me", [1, 2, 3]), ("now", [5])), "wordsDoNotCoverNotes",
                     contains="points at note 5")
        self.refused(words(("now", [4]), ("hold", [0]), ("me", [1, 2, 3])), "wordsDoNotCoverNotes",
                     contains="note order")
        self.refused(words(("hold", [0]), ("me", []), ("now", [4])), "badRequest")
        self.refused(words(("hold", [0]), ("me", [1, 2, True]), ("now", [4])), "badRequest")

    def test_word_text(self):
        for text, code in (("", "emptyWord"), ("   ", "emptyWord"), ("two words", "badRequest"),
                           ("tab\tbed", "badRequest"), ("nul\x00", "badRequest"), ("zw​sp", "badRequest"),
                           ("x" * 65, "badRequest"), (7, "badRequest")):
            o = base()
            o["phrase"]["words"][0]["text"] = text
            self.refused(o, code)
        o = base()
        o["phrase"]["words"][0]["text"] = "don't"          # an apostrophe is part of a word
        schema.validate(o)

    def test_phrase_too_long(self):
        o = base(trailS=5.0)
        o["phrase"]["notes"][-1]["endS"] = 24.76            # 0.24 + 24.76 + 5.0 = 30.0: the limit itself is fine
        schema.validate(o)
        o["phrase"]["notes"][-1]["endS"] = 24.77
        self.refused(o, "phraseTooLong", contains="30")

    def test_numeric_ranges(self):
        for key, value in (("leadS", -0.01), ("leadS", 5.01), ("trailS", "0.24"), ("seed", -1), ("seed", 2 ** 63),
                           ("seed", 1.0), ("seed", True), ("nSteps", 0), ("nSteps", 201), ("cfg", -0.1), ("cfg", 20.5),
                           ("cfg", "3"), ("cfg", False), ("outputSampleRate", 7999), ("outputSampleRate", 192001),
                           ("outputSampleRate", 48000.0)):
            self.refused(base(**{key: value}), "badRequest", contains=key if key != "cfg" else "cfg")
        schema.validate(base(seed=2 ** 63 - 1, nSteps=200, cfg=0, outputSampleRate=8000))

    def test_output_path_shape(self):
        for p in ("relative.wav", "/x/out.mp3", "/x/", "/x/out.wav\x00.txt", "/" + "a" * 1030 + ".wav", 7):
            self.refused(base(outputPath=p), "badRequest", contains="outputPath")
        schema.validate(base(outputPath="/x/OUT.WAV"))

    def test_voice_ids(self):
        for vid in ("", "../x", "a/b", "-lead", "x" * 65, 7):
            self.refused(base(voice={"id": vid}), "badRequest")
        self.refused(base(voice=own(id="builtin-9")), "badRequest", contains="builtin-")

    def test_own_voice_fields(self):
        for mutate in (lambda v: v.update(referencePath="relative/ref.wav"),
                       lambda v: v.update(referenceSha256="ab" * 31),
                       lambda v: v.update(referenceSha256="zz" * 32),
                       lambda v: v["prompt"].update(windowEndS=0.0),
                       lambda v: v.update(promptLabelOffset=49),
                       lambda v: v.update(promptLabelOffset=1.5),
                       lambda v: v["prompt"]["notes"][0].update(continues=True),
                       lambda v: v["prompt"]["notes"][1].update(continues="yes"),
                       lambda v: v["prompt"]["notes"][3].update(endS=5.5),
                       lambda v: v["prompt"]["notes"].reverse(),
                       lambda v: v["prompt"]["notes"][1].update(startS=0.5),
                       lambda v: v["prompt"]["notes"][0].update(word=" "),
                       lambda v: v["prompt"].update(notes=[])):
            v = own()
            mutate(v)
            e = self.refused(base(voice=v), "emptyWord" if v["prompt"]["notes"] and
                             v["prompt"]["notes"][0].get("word") == " " else "badRequest")
            self.assertTrue(e.message)
        for label, offset in ((20, -20), (120, 8)):                         # 0 and 128: outside MIDI 1-127
            v = own(promptLabelOffset=offset)
            v["prompt"]["notes"][0]["midi"] = label
            self.refused(base(voice=v), "badRequest", contains="MIDI 1-127")
        for label, offset in ((21, -20), (119, 8)):                         # controls: 1 and 127 are fine
            v = own(promptLabelOffset=offset)
            v["prompt"]["notes"][0]["midi"] = label
            schema.validate(base(voice=v))

    def test_test_hook_exists_only_when_the_process_was_launched_with_it(self):
        hook = {"hz": 220.0, "frames": "full"}
        self.refused(base(voice=own(), testPromptF0=hook), "badRequest", contains="testPromptF0")
        r = schema.validate(base(voice=own(), testPromptF0=hook), test_hooks=True)
        self.assertEqual(r.test_prompt_f0, (220.0, "full"))
        r = schema.validate(base(voice=own(), testPromptF0={"hz": 110, "frames": 12}), test_hooks=True)
        self.assertEqual(r.test_prompt_f0, (110.0, 12))
        self.refused(base(testPromptF0=hook), "badRequest", hooks=True, contains="own voice")
        for bad in ({"hz": 0, "frames": "full"}, {"hz": 220.0, "frames": 0}, {"hz": 220.0, "frames": "half"},
                    {"hz": 220.0}, {"hz": 220.0, "frames": True}):
            self.refused(base(voice=own(), testPromptF0=bad), "badRequest", hooks=True)


class Resolve(unittest.TestCase):
    """The filesystem stage, against real folders (with a space in their path, like Application Support)."""

    def setUp(self):
        self.tmp = os.path.realpath(temp_dir("resolve"))
        self.cache = os.path.join(self.tmp, "Singing Cache")
        self.voices = os.path.join(self.tmp, "Singing Voices")
        self.runtime_voices = os.path.join(self.tmp, "SingingEngine", "voices")
        self.outside = os.path.join(self.tmp, "Elsewhere")
        for d in (self.cache, self.voices, self.runtime_voices, self.outside):
            os.makedirs(d)
        b = os.path.join(self.runtime_voices, "builtin-1")
        os.makedirs(b)
        for n in ("prompt.wav", "prompt.json"):
            with open(os.path.join(b, n), "wb") as f:
                f.write(b"x")
        self.ref = os.path.join(self.voices, "v1", "reference.wav")
        self.ref_sha = write_reference_wav(self.ref, seconds=1.5)
        self.roots = schema.normalize_roots([self.cache, self.voices, self.runtime_voices])

    def req(self, output=None, voice=None):
        return schema.validate(base(outputPath=output or os.path.join(self.cache, "k.wav"), voice=voice))

    def resolve(self, output=None, voice=None):
        r = self.req(output, voice)
        schema.resolve(r, self.roots, self.runtime_voices)
        return r

    def refused(self, code, output=None, voice=None):
        r = self.req(output, voice)
        with self.assertRaises(Refusal) as cm:
            schema.resolve(r, self.roots, self.runtime_voices)
        self.assertEqual(cm.exception.code, code, cm.exception.message)
        return cm.exception

    def test_inside_the_cache_is_allowed(self):
        r = self.resolve()
        self.assertEqual(r.output_real, os.path.join(self.cache, "k.wav"))
        self.assertEqual(r.voice.wav, os.path.join(self.runtime_voices, "builtin-1", "prompt.wav"))
        r = self.resolve(os.path.join(self.cache, "new sub folder", "k.wav"))   # a folder the backend will create
        self.assertTrue(r.output_real.startswith(self.cache + "/"))

    def test_outside_every_root_is_refused(self):
        self.refused("pathNotAllowed", os.path.join(self.outside, "k.wav"))
        self.refused("pathNotAllowed", "/private/tmp/k.wav")
        self.refused("pathNotAllowed", os.path.join(self.cache, "..", "Elsewhere", "k.wav"))
        self.refused("pathNotAllowed", os.path.join(self.cache + " evil", "k.wav"))    # a prefix is not a parent

    def test_a_symlinked_folder_that_escapes_is_refused(self):
        link = os.path.join(self.cache, "link")
        os.symlink(self.outside, link)
        self.refused("pathNotAllowed", os.path.join(link, "k.wav"))
        inner = os.path.join(self.cache, "inner-link")
        os.symlink(os.path.join(self.voices, "v1"), inner)          # a link that stays inside the roots is fine
        self.assertEqual(self.resolve(os.path.join(inner, "k.wav")).output_real,
                         os.path.join(self.voices, "v1", "k.wav"))

    def test_an_output_path_that_is_itself_a_symlink_out_is_refused(self):
        target = os.path.join(self.outside, "victim.wav")
        with open(target, "wb") as f:
            f.write(b"precious")
        os.symlink(target, os.path.join(self.cache, "k.wav"))
        self.refused("pathNotAllowed")
        os.symlink(os.path.join(self.outside, "dangling.wav"), os.path.join(self.cache, "d.wav"))
        self.refused("pathNotAllowed", os.path.join(self.cache, "d.wav"))
        with open(target, "rb") as f:
            self.assertEqual(f.read(), b"precious")

    def test_a_folder_at_the_output_path_is_refused(self):
        os.makedirs(os.path.join(self.cache, "d.wav"))
        self.refused("badRequest", os.path.join(self.cache, "d.wav"))

    def test_a_root_reached_through_a_symlink_and_unicode_forms(self):
        alias = os.path.join(self.tmp, "cache alias")
        os.symlink(self.cache, alias)
        roots = schema.normalize_roots([alias])
        r = self.req(os.path.join(self.cache, "k.wav"))
        schema.resolve(r, roots + [self.runtime_voices], self.runtime_voices)
        cafe_nfc = os.path.join(self.cache, unicodedata.normalize("NFC", "Café"))
        os.makedirs(cafe_nfc)
        nfd = os.path.join(self.cache, unicodedata.normalize("NFD", "Café"), "k.wav")
        self.assertNotEqual(nfd, os.path.join(cafe_nfc, "k.wav"))
        roots = schema.normalize_roots([cafe_nfc, self.runtime_voices])
        r = self.req(nfd)
        schema.resolve(r, roots, self.runtime_voices)                # NFD spelling of an NFC root: the same folder
        cafe = os.path.join(self.cache, "Cafe")
        os.makedirs(cafe)
        r = self.req(os.path.join(cafe, "k.wav"))
        with self.assertRaises(Refusal) as cm:                       # control: a different name is refused
            schema.resolve(r, roots, self.runtime_voices)
        self.assertEqual(cm.exception.code, "pathNotAllowed")

    def test_roots_from_the_environment(self):
        value = os.pathsep.join(["relative/dir", "", self.cache, self.cache + "/", self.voices])
        roots = schema.roots_from_env(value, always=[self.runtime_voices])
        self.assertEqual(roots, [self.runtime_voices, self.cache, self.voices])
        self.assertEqual(schema.roots_from_env(None, always=[self.runtime_voices]), [self.runtime_voices])

    def test_builtin_voices(self):
        self.refused("voiceNotFound", voice={"id": "builtin-2"})
        os.remove(os.path.join(self.runtime_voices, "builtin-1", "prompt.json"))
        self.refused("voiceNotFound")
        planted = os.path.join(self.outside, "prompt.json")
        with open(planted, "w") as f:
            json.dump([{}], f)
        os.symlink(planted, os.path.join(self.runtime_voices, "builtin-1", "prompt.json"))
        self.refused("pathNotAllowed")

    def test_own_voices(self):
        good = own_voice(self.ref, self.ref_sha)
        self.assertEqual(self.resolve(voice=good).voice.reference_real, self.ref)
        outside_ref = os.path.join(self.outside, "reference.wav")
        sha = write_reference_wav(outside_ref, seconds=1.5)
        self.refused("pathNotAllowed", voice=own_voice(outside_ref, sha))
        link = os.path.join(self.voices, "v2")
        os.makedirs(link)
        os.symlink(outside_ref, os.path.join(link, "reference.wav"))
        self.refused("pathNotAllowed", voice=own_voice(os.path.join(link, "reference.wav"), sha))
        self.refused("pathNotAllowed", voice=own_voice(os.path.join(self.voices, "..", "Elsewhere", "reference.wav"),
                                                       sha))
        self.refused("voiceNotFound", voice=own_voice(os.path.join(self.voices, "v9", "reference.wav"), sha))
        e = self.refused("referenceChanged", voice=own_voice(self.ref, "0" * 64))
        self.assertIn(self.ref_sha, e.message)
        upper = own_voice(self.ref, self.ref_sha.upper())          # the hex case never matters
        self.assertEqual(self.resolve(voice=upper).voice.sha256, self.ref_sha)
        with open(self.ref, "ab") as f:                             # the recording changed after it was checked
            f.write(b"\x00\x00\x00\x00")
        self.refused("referenceChanged", voice=good)
        self.assertNotEqual(sha256_path(self.ref), self.ref_sha)

    def test_the_output_is_checked_before_the_voice(self):
        self.refused("pathNotAllowed", os.path.join(self.outside, "k.wav"), voice={"id": "builtin-7"})


if __name__ == "__main__":
    unittest.main()
