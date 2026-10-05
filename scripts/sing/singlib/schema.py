"""The facade's request schema (design §2.4) and its path rules. Standard library, Python 3.9 compatible.

Two stages, so each can be tested alone:
  validate(obj, test_hooks)       -> PhraseRequest   pure: no filesystem. Every 400 except the phoneme ones.
  resolve(req, roots, voices_dir) -> None            the filesystem: allowed roots on the REALPATH (403), the
                                                     voice exists (404), the reference's sha256 (409).
emptyWord / unknownPhone come from the converter (singlib.score), 422 badReference from reading the audio.

The request (DAW Pro's own schema; SoulX's metadata schema never crosses the wire):
  {"facadeVersion": 1,
   "voice": {"id": "builtin-1"}                                        a built-in voice, or an own voice:
            {"id": "<uuid>", "referencePath": "...", "referenceSha256": "<64 hex>",
             "prompt": {"windowStartS": s, "windowEndS": s,
                        "notes": [{"startS", "endS", "midi", "word", "continues"}]},   (window-relative)
             "promptLabelOffset": 0},                                   optional, whole semitones
   "phrase": {"notes": [{"startS", "endS", "midi"}], "words": [{"text", "noteIndices"}]},  unit-relative s
   "leadS": 0.24, "trailS": 0.24, "seed": 20260924, "nSteps": 32, "cfg": 3.0,
   "outputPath": "<an allowed root>/<name>.wav", "outputSampleRate": 48000}
Unknown keys are refused at every level (`badRequest`), like the app's rejectUnknownKeys.

Test hook (never reachable unless the process was LAUNCHED with SING_TEST_HOOKS=1; otherwise it is an unknown
key like any other): "testPromptF0": {"hz": 220.0, "frames": "full" | <int>} adds a constant f0 of that many
frames to an OWN voice's prompt metadata ("full" = the prompt's mel frames + 1, as the spike padded). It exists
for the §7.6 prompt-f0 null test only.
"""
import hashlib
import json
import math
import os
import re
import unicodedata

from .refusals import Refusal

FACADE_VERSION = 1
MAX_PHRASE_S = 30.0          # §2.4 phraseTooLong: "longer than 30 s with the guards" (the app sends <= 20 s)
MAX_GUARD_S = 5.0
MAX_NOTES = 1000
MAX_WORD_CHARS = 64
MIN_WINDOW_S = 1.0           # [A] shortest usable prompt window; the recorder asks for ~5 s (design §3.8)
MAX_WINDOW_S = 30.0
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SHA_RE = re.compile(r"^[0-9a-fA-F]{64}$")

TOP_KEYS = ("facadeVersion", "voice", "phrase", "leadS", "trailS", "seed", "nSteps", "cfg", "outputPath",
            "outputSampleRate")
TEST_KEYS = ("testPromptF0",)


class BuiltinVoice(object):
    kind = "builtin"

    def __init__(self, voice_id):
        self.id = voice_id
        self.dir = None
        self.wav = None
        self.meta = None

    def cache_key(self, extra=None):
        return "builtin:%s" % self.id


class OwnVoice(object):
    kind = "own"

    def __init__(self, voice_id, reference_path, sha256, window_start, window_end, prompt_notes, label_offset):
        self.id = voice_id
        self.reference_path = reference_path
        self.reference_real = None
        self.sha256 = sha256
        self.window_start = window_start
        self.window_end = window_end
        self.prompt_notes = prompt_notes      # [(midi, start_s, end_s, word, continues)] window-relative
        self.label_offset = label_offset

    def cache_key(self, extra=None):
        spec = {"id": self.id, "sha": self.sha256, "w": [self.window_start, self.window_end],
                "notes": self.prompt_notes, "offset": self.label_offset, "f0": extra}
        return "own:" + hashlib.sha256(json.dumps(spec, sort_keys=True).encode("utf-8")).hexdigest()


class PhraseRequest(object):
    def __init__(self):
        self.voice = None
        self.notes = []          # [(midi, start_s, end_s)] unit-relative seconds
        self.words = []          # [(text, [note indices])]
        self.lead = self.trail = None
        self.seed = self.n_steps = self.cfg = None
        self.output_path = None
        self.output_real = None
        self.out_sr = None
        self.test_prompt_f0 = None   # None | (hz, "full" | int)


def _bad(msg):
    return Refusal("badRequest", msg)


def _reject_constant(name):
    raise ValueError("%s is not allowed" % name)


def parse_body(raw):
    try:
        obj = json.loads(raw.decode("utf-8"), parse_constant=_reject_constant)
    except (UnicodeDecodeError, ValueError) as e:
        raise _bad("The request body is not valid JSON (%s)." % (str(e).splitlines()[0][:200],))
    if not isinstance(obj, dict):
        raise _bad("The request body must be a JSON object.")
    return obj


def _keys(obj, where, required, optional=()):
    if not isinstance(obj, dict):
        raise _bad("%s must be a JSON object." % where)
    unknown = sorted(k for k in obj if k not in required and k not in optional)
    if unknown:
        raise _bad("Unknown key%s in %s: %s. Allowed: %s." % (
            "s" if len(unknown) > 1 else "", where, ", ".join(unknown), ", ".join(tuple(required) + tuple(optional))))
    missing = [k for k in required if k not in obj]
    if missing:
        raise _bad("Missing key%s in %s: %s." % ("s" if len(missing) > 1 else "", where, ", ".join(missing)))


def _is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _num(obj, key, where, lo, hi, lo_open=False):
    v = obj[key]
    if not _is_num(v):
        raise _bad("%s.%s must be a finite number." % (where, key))
    if (v <= lo if lo_open else v < lo) or v > hi:
        raise _bad("%s.%s = %r is outside %s%r, %r]." % (where, key, v, "(" if lo_open else "[", lo, hi))
    return float(v)


def _int(obj, key, where, lo, hi):
    v = obj[key]
    if not isinstance(v, int) or isinstance(v, bool):
        raise _bad("%s.%s must be a whole number." % (where, key))
    if v < lo or v > hi:
        raise _bad("%s.%s = %r is outside [%r, %r]." % (where, key, v, lo, hi))
    return v


def _word_text(v, where):
    if not isinstance(v, str):
        raise _bad("%s must be a string." % where)
    if not v.strip():
        raise Refusal("emptyWord", "%s is empty: there is nothing to sing." % where)
    if len(v) > MAX_WORD_CHARS:
        raise _bad("%s is longer than %d characters." % (where, MAX_WORD_CHARS))
    if any(c.isspace() or unicodedata.category(c).startswith("C") for c in v):
        raise _bad("%s = %r contains a space or a control character. Send each word separately." % (where, v))
    return v


def _notes(arr, where, extra_keys=()):
    """-> [(midi, start, end, obj)] with the per-note checks done (not the ordering checks)."""
    if not isinstance(arr, list) or not arr:
        raise _bad("%s must be a non-empty list." % where)
    if len(arr) > MAX_NOTES:
        raise _bad("%s has %d notes; the most one request takes is %d." % (where, len(arr), MAX_NOTES))
    out = []
    for i, n in enumerate(arr):
        w = "%s[%d]" % (where, i)
        _keys(n, w, ("startS", "endS", "midi") + tuple(extra_keys))
        s = _num(n, "startS", w, 0.0, 3600.0)
        e = _num(n, "endS", w, 0.0, 3600.0)
        if e <= s:
            raise _bad("%s ends at %r, which is not after its start %r." % (w, e, s))
        m = _int(n, "midi", w, 1, 127)
        out.append((m, s, e, n))
    return out


def _order(notes, where, unsorted_code, overlap_code):
    for i in range(1, len(notes)):
        if notes[i][1] < notes[i - 1][1]:
            raise Refusal(unsorted_code, "%s[%d] starts at %r, before %s[%d] at %r: the notes must be sorted."
                          % (where, i, notes[i][1], where, i - 1, notes[i - 1][1]))
    for i in range(1, len(notes)):
        if notes[i][1] < notes[i - 1][2] - 1e-9:
            raise Refusal(overlap_code, "%s[%d] starts at %r, before %s[%d] ends at %r: notes may not overlap."
                          % (where, i, notes[i][1], where, i - 1, notes[i - 1][2]))


def _words(arr, n_notes):
    if not isinstance(arr, list) or not arr:
        raise _bad("phrase.words must be a non-empty list.")
    words, owner = [], [None] * n_notes
    for j, w in enumerate(arr):
        where = "phrase.words[%d]" % j
        _keys(w, where, ("text", "noteIndices"))
        text = _word_text(w["text"], where + ".text")
        idx = w["noteIndices"]
        if not isinstance(idx, list) or not idx or any(not isinstance(i, int) or isinstance(i, bool) for i in idx):
            raise _bad("%s.noteIndices must be a non-empty list of whole numbers." % where)
        for k, i in enumerate(idx):
            if i < 0 or i >= n_notes:
                raise Refusal("wordsDoNotCoverNotes", "The word %r points at note %d, but there are %d notes."
                              % (text, i, n_notes))
            if i != idx[0] + k:
                raise Refusal("wordsDoNotCoverNotes", "The word %r has note indices %r that are not contiguous and "
                              "ascending." % (text, idx))
            if owner[i] is not None:
                raise Refusal("wordsDoNotCoverNotes", "Note %d has two words: %r and %r." % (i, owner[i], text))
            owner[i] = text
        if words and idx[0] < words[-1][1][-1]:
            raise Refusal("wordsDoNotCoverNotes", "The words must be in note order: %r comes after %r."
                          % (text, words[-1][0]))
        words.append((text, list(idx)))
    for i, o in enumerate(owner):
        if o is None:
            raise Refusal("wordsDoNotCoverNotes", "Note %d has no word." % i)
    return words


def _voice(v, test_hooks):
    if not isinstance(v, dict):
        raise _bad("voice must be a JSON object.")
    if "referencePath" not in v:
        _keys(v, "voice", ("id",))
        vid = v["id"]
        if not isinstance(vid, str) or not ID_RE.match(vid):
            raise _bad("voice.id must match %s." % ID_RE.pattern)
        return BuiltinVoice(vid)
    _keys(v, "voice", ("id", "referencePath", "referenceSha256", "prompt"), ("promptLabelOffset",))
    vid = v["id"]
    if not isinstance(vid, str) or not ID_RE.match(vid):
        raise _bad("voice.id must match %s." % ID_RE.pattern)
    if vid.startswith("builtin-"):
        raise _bad("An own voice's id may not start with 'builtin-'.")
    ref = v["referencePath"]
    if not isinstance(ref, str) or not ref.startswith("/") or "\x00" in ref or len(ref) > 1024:
        raise _bad("voice.referencePath must be an absolute path.")
    sha = v["referenceSha256"]
    if not isinstance(sha, str) or not SHA_RE.match(sha):
        raise _bad("voice.referenceSha256 must be 64 hexadecimal characters.")
    p = v["prompt"]
    _keys(p, "voice.prompt", ("windowStartS", "windowEndS", "notes"))
    ws = _num(p, "windowStartS", "voice.prompt", 0.0, 3600.0)
    we = _num(p, "windowEndS", "voice.prompt", 0.0, 3600.0)
    if we <= ws:
        raise _bad("voice.prompt.windowEndS must be after windowStartS.")
    offset = 0
    if "promptLabelOffset" in v:
        offset = _int(v, "promptLabelOffset", "voice", -48, 48)
    raw = _notes(p["notes"], "voice.prompt.notes", ("word", "continues"))
    _order(raw, "voice.prompt.notes", "badRequest", "badRequest")
    notes = []
    for i, (m, s, e, n) in enumerate(raw):
        where = "voice.prompt.notes[%d]" % i
        if e > (we - ws) + 1e-6:
            raise _bad("%s ends at %r, after the prompt window (%r s long)." % (where, e, we - ws))
        word = _word_text(n["word"], where + ".word")
        cont = n["continues"]
        if not isinstance(cont, bool):
            raise _bad("%s.continues must be true or false." % where)
        if not 1 <= m + offset <= 127:
            raise _bad("%s: label %d + promptLabelOffset %d leaves MIDI 1-127." % (where, m, offset))
        notes.append((m, s, e, word, cont))
    if notes[0][4]:
        raise _bad("voice.prompt.notes[0] cannot continue a previous word.")
    return OwnVoice(vid, ref, sha.lower(), ws, we, notes, offset)


def validate(obj, test_hooks=False):
    """Pure schema validation. Raises Refusal; returns a PhraseRequest."""
    _keys(obj, "the request", TOP_KEYS, TEST_KEYS if test_hooks else ())
    r = PhraseRequest()
    fv = obj["facadeVersion"]
    if not isinstance(fv, int) or isinstance(fv, bool) or fv != FACADE_VERSION:
        raise _bad("facadeVersion must be %d." % FACADE_VERSION)
    ph = obj["phrase"]
    _keys(ph, "phrase", ("notes", "words"))
    raw = _notes(ph["notes"], "phrase.notes")
    _order(raw, "phrase.notes", "notesUnsorted", "notesOverlap")
    r.notes = [(m, s, e) for m, s, e, _ in raw]
    r.words = _words(ph["words"], len(r.notes))
    r.lead = _num(obj, "leadS", "the request", 0.0, MAX_GUARD_S)
    r.trail = _num(obj, "trailS", "the request", 0.0, MAX_GUARD_S)
    total = r.lead + r.notes[-1][2] + r.trail
    if total > MAX_PHRASE_S:
        raise Refusal("phraseTooLong", "This phrase is %.2f s long with its guards; the most one request takes "
                      "is %.0f s." % (total, MAX_PHRASE_S))
    r.seed = _int(obj, "seed", "the request", 0, 2 ** 63 - 1)
    r.n_steps = _int(obj, "nSteps", "the request", 1, 200)
    cfg = obj["cfg"]
    if not _is_num(cfg) or cfg < 0 or cfg > 20:
        raise _bad("cfg must be a number in [0, 20].")
    r.cfg = cfg                  # kept as sent (int or float): it only ever multiplies a float32 tensor
    r.out_sr = _int(obj, "outputSampleRate", "the request", 8000, 192000)
    op = obj["outputPath"]
    if not isinstance(op, str) or not op.startswith("/") or "\x00" in op or len(op) > 1024 \
            or not op.lower().endswith(".wav") or op.endswith("/"):
        raise _bad("outputPath must be an absolute path ending in .wav.")
    r.output_path = op
    r.voice = _voice(obj["voice"], test_hooks)
    if test_hooks and "testPromptF0" in obj:
        t = obj["testPromptF0"]
        _keys(t, "testPromptF0", ("hz", "frames"))
        hz = _num(t, "hz", "testPromptF0", 0.0, 2000.0, lo_open=True)
        fr = t["frames"]
        if fr != "full" and (not isinstance(fr, int) or isinstance(fr, bool) or fr < 1 or fr > 100000):
            raise _bad('testPromptF0.frames must be "full" or a whole number >= 1.')
        if r.voice.kind != "own":
            raise _bad("testPromptF0 applies to an own voice only.")
        r.test_prompt_f0 = (hz, fr)
    return r


# ---------------------------------------------------------------- the filesystem stage

def _nfc(p):
    return unicodedata.normalize("NFC", p)


def normalize_roots(paths):
    """Absolute roots -> realpath'd, NFC, de-duplicated. Relative entries are dropped (never trusted)."""
    out = []
    for p in paths:
        if p and os.path.isabs(p):
            r = _nfc(os.path.realpath(p))
            if r not in out:
                out.append(r)
    return out


def roots_from_env(value, always=()):
    return normalize_roots(list(always) + [p for p in (value or "").split(os.pathsep) if p])


def inside(path, roots):
    rp = _nfc(os.path.realpath(path))
    return any(rp == r or rp.startswith(r.rstrip("/") + "/") for r in roots)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def resolve(req, roots, voices_dir):
    """Allowed roots (checked on the REALPATH), existence and the reference hash. Mutates `req`."""
    op = req.output_path
    if not inside(os.path.dirname(op), roots) or not inside(op, roots):
        raise Refusal("pathNotAllowed", "outputPath %r is outside the folders the singing engine may write." % op)
    if os.path.isdir(op):
        raise _bad("outputPath %r is a folder." % op)
    req.output_real = os.path.join(os.path.realpath(os.path.dirname(op)), os.path.basename(op))
    v = req.voice
    if v.kind == "builtin":
        d = os.path.join(voices_dir, v.id)
        wav, meta = os.path.join(d, "prompt.wav"), os.path.join(d, "prompt.json")
        if not (os.path.isfile(wav) and os.path.isfile(meta)):
            raise Refusal("voiceNotFound", "There is no voice %r." % v.id)
        if not (inside(wav, roots) and inside(meta, roots)):
            raise Refusal("pathNotAllowed", "The voice %r resolves outside the allowed folders." % v.id)
        v.dir, v.wav, v.meta = d, wav, meta
        return
    if not inside(v.reference_path, roots):
        raise Refusal("pathNotAllowed", "The voice recording %r is outside the folders the singing engine may "
                      "read." % v.reference_path)
    real = os.path.realpath(v.reference_path)
    if not os.path.isfile(real):
        raise Refusal("voiceNotFound", "The recording for voice %r is missing: %s" % (v.id, v.reference_path))
    got = sha256_file(real)
    if got != v.sha256:
        raise Refusal("referenceChanged", "The recording for voice %r changed since it was checked (sha256 %s, "
                      "expected %s)." % (v.id, got, v.sha256))
    v.reference_real = real
