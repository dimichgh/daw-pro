"""Notes + words -> SoulX-Singer score metadata. A port of the spike's converter
(`~/DAWPro-spikes/sing-soulx/code/score_from_notes.py`, `build()` at :48-92), which produced every render the
user heard. The arithmetic below is the spike's, line for line; the tests reproduce the spike's T1, T2 and T1T2
JSON byte for byte (scripts/sing/tests/test_score.py).

Rules (design §2.4 "Conversion rules"):
  * a leading <SP> of `lead` seconds, an <SP> for every gap between notes, and a trailing <SP> of `trail`;
  * boundaries rounded to 10 ms CUMULATIVELY (each event's start, and the last event's end), then differenced;
    never per-duration rounding;
  * each word's phonemes are `en_` + its g2p_en ARPAbet tokens joined with `-`;
  * a word on k notes becomes k entries, each carrying the WHOLE word's phonemes, note_type 2 on the first and
    3 on the rest (`score_from_notes.py:53,64`). Upstream splits each phone into its own token
    (`data_processor.py:96-100`), so no syllable splitting of phonemes is done;
  * rests are `<SP>` / `<SP>` / pitch 0 / type 1; language "English"; time [0, total_ms]; no f0 key.
  * every phone must be in upstream's `phone_set.json`.

Two additions, both invisible on the spike's fixtures (the tests prove the three fixtures are unchanged):
  * an <SP> whose ROUNDED duration is 0.00 is dropped. The cumulative boundaries are untouched by the drop, so
    no other entry moves; the spike's converter would have emitted a zero-length rest (it never met one);
  * a NOTE whose rounded duration is 0.00 is refused (`badRequest`): it would reach the model as a word with no
    frames.

Seconds, not beats: the facade's request carries unit-relative seconds, so an event starts at `lead + start_s`.
The spike computed `LEAD + sb * spb`; a client that sends `start_s = sb * spb` (as a float, which JSON
round-trips exactly) therefore reproduces the spike's floats bit for bit. `build_from_beats()` is that bridge.

Standard library only; Python 3.9 compatible. The phonemizer is injected: `phonemize(word) -> [ARPAbet tokens]`
(already filtered the spike's way: `[t for t in g2p(word.lower()) if t.strip() and t[0].isalpha()]`).

facadeVersion 2 (design docs/design/2026-10-06-p2-sing-expansion.md §6.4): `langs` (one per word, default all "en")
and an injected `lexicon` (`syllables(lang, chars) -> [syllable or None per character]`, `tone_rank(lang, base) ->
tones, most common first`). English words take today's path, call for call, so an all-English phrase builds today's
bytes (tests P2/P5). A zh/yue word is ONE token, `zh_`/`yue_` + its tonal syllable:
  * a run of consecutive Chinese-character words of one language is phonemised in ONE call (a character with two
    readings needs its neighbours), and mapped back one syllable per character;
  * a typed syllable (ni3, lu:4 or lv4, nei5) passes through, lower-cased;
  * a syllable whose tone the phone set lacks becomes the same syllable's most common tone that IS in the set
    (the lexicon ranks; ties and unranked tones go lowest number first), and is reported in
    info["substitutions"] = [{word, asked, used}] (each distinct triple once);
  * no syllable at all (an unknown character, a two-syllable reading), or no tone of it in the set: `unknownPhone`,
    naming the character. The metadata's `language` becomes the first non-English word's language name.
"""
from __future__ import annotations

import json

from . import langs as L
from .refusals import Refusal

SP = "<SP>"
SAMPLE_RATE = 24000
HOP = 480
DEFAULT_LEAD = DEFAULT_TRAIL = 0.24   # the spike's LEAD/TRAIL


class _Phonemes:
    """Per-build memo around the injected phonemizer, with the design's two word refusals."""

    def __init__(self, phonemize, phoneset):
        self._phonemize = phonemize
        self._phoneset = phoneset
        self._memo = {}

    def token(self, word):
        if word in self._memo:
            return self._memo[word]
        toks = list(self._phonemize(word))
        if not toks:
            raise Refusal("emptyWord", "The word %r has no letters to sing." % (word,))
        if self._phoneset is not None:
            for ph in toks:
                if "en_" + ph not in self._phoneset:
                    raise Refusal("unknownPhone",
                                  "The word %r needs the sound %r, which the singing engine does not know."
                                  % (word, ph))
        tok = "en_" + "-".join(toks)
        self._memo[word] = tok
        return tok


def _syllable_token(lang, word, syl, phoneset, lexicon, subs):
    """One Chinese word's token (see the module docstring); appends to `subs` when the tone is substituted."""
    pre = L.PREFIX[lang]
    if not L.is_syllable(lang, syl):
        raise Refusal("unknownPhone", "I don't know how to sing %r in %s: there is no single sung syllable for it "
                      "(got %r). Try a different character, or type its %s."
                      % (word, L.NAME[lang], syl, L.EXAMPLE[lang]))
    tok = pre + syl
    if phoneset is None or tok in phoneset:
        return tok
    base, tone = L.split_tone(syl)
    present = [t for t in L.TONES[lang] if pre + base + t in phoneset]
    if not present:
        raise Refusal("unknownPhone", "The word %r is sung %r in %s, and the singing engine knows no tone of %r."
                      % (word, syl, L.NAME[lang], base))
    order = list(lexicon.tone_rank(lang, base)) if lexicon is not None else []
    ranked = [t for t in order if t in present] + [t for t in present if t not in order]
    used = base + ranked[0]
    entry = {"word": word, "asked": syl, "used": used}
    if entry not in subs:
        subs.append(entry)
    return pre + used


def chinese_tokens(words, langs, lexicon, phoneset=None):
    """-> ({word index: token} for every non-English word, substitutions). English words are left to _Phonemes."""
    toks, subs = {}, []
    j = 0
    while j < len(words):
        lang = langs[j]
        if lang == L.DEFAULT:
            j += 1
            continue
        if lang not in L.TONES:
            raise Refusal("languageNotSupported", "The word %r asks for language %r, which this singing engine does "
                          "not sing." % (words[j][0], lang))
        text = words[j][0]
        if L.is_cjk_char(text):
            if lexicon is None:
                raise Refusal("languageNotSupported", "This singing engine has no %s phonemiser." % L.NAME[lang])
            k = j + 1
            while k < len(words) and langs[k] == lang and L.is_cjk_char(words[k][0]):
                k += 1
            run = "".join(w for w, _ in words[j:k])
            syl = list(lexicon.syllables(lang, run))
            if len(syl) != k - j:
                raise Refusal("badRequest", "Internal: the %s phonemiser gave %d syllables for the %d characters %r."
                              % (L.NAME[lang], len(syl), k - j, run))
            for m in range(j, k):
                toks[m] = _syllable_token(lang, words[m][0], syl[m - j], phoneset, lexicon, subs)
            j = k
        else:
            syl = L.romanised(lang, text)
            if syl is None:
                raise Refusal("badRequest", "The word %r is marked %s, but it is not one Chinese character or one "
                              "syllable typed as %s." % (text, L.NAME[lang], L.EXAMPLE[lang]))
            toks[j] = _syllable_token(lang, text, syl, phoneset, lexicon, subs)
            j += 1
    return toks, subs


def build_meta(notes, words, lead=DEFAULT_LEAD, trail=DEFAULT_TRAIL, phonemize=None, phoneset=None,
               pitch_offset=0, f0_const=None, language="English", langs=None, lexicon=None):
    """notes: [(midi, start_s, end_s)] unit-relative seconds, sorted and non-overlapping (callers validate;
    the asserts here are the spike's own). words: [(text, [note indices])], covering every note exactly once.
    langs (v2): one language code per word (None = every word English); lexicon: see the module docstring.

    Returns (meta, info) exactly as the spike's build() did, except that `meta` is the dict itself (the spike
    returned [meta]). `dump_meta_list([meta])` gives the spike's file bytes. info["substitutions"] lists the tone
    substitutions (always [] for an all-English phrase).
    """
    ph = _Phonemes(phonemize, phoneset)
    word_of = {}
    for j, (w, idx) in enumerate(words):
        for k, i in enumerate(idx):
            word_of[i] = (w, 2 if k == 0 else 3, j)
    if sorted(word_of) != list(range(len(notes))):
        raise Refusal("wordsDoNotCoverNotes", "Every note needs exactly one word.")
    other, subs = {}, []
    if langs is not None and any(lang != L.DEFAULT for lang in langs):
        if len(langs) != len(words):
            raise Refusal("badRequest", "Internal: %d languages for %d words." % (len(langs), len(words)))
        other, subs = chinese_tokens(words, langs, lexicon, phoneset)
        language = L.NAME[next(lang for lang in langs if lang != L.DEFAULT)]
    # boundaries in seconds (spike: ev = [("<SP>", 0.0, LEAD, 0, 1, "<SP>")])
    ev = [(SP, 0.0, lead, 0, 1, SP)]
    t_prev_end = lead
    for i, (p, s, e) in enumerate(notes):
        st, en = lead + s, lead + e
        if not st >= t_prev_end - 1e-9:
            raise Refusal("notesOverlap", "Note %d starts before the previous note ends." % i)
        if st > t_prev_end + 1e-9:
            ev.append((SP, t_prev_end, st, 0, 1, SP))
        w, ty, j = word_of[i]
        ev.append((other[j] if j in other else ph.token(w), st, en, p + pitch_offset, ty, w))
        t_prev_end = en
    ev.append((SP, t_prev_end, t_prev_end + trail, 0, 1, SP))
    bounds = [round(x[1] * 100) / 100 for x in ev] + [round(ev[-1][2] * 100) / 100]
    durs = [round(b - a, 2) for a, b in zip(bounds[:-1], bounds[1:])]
    total_ms = int(round(bounds[-1] * 1000))
    # The two additions (see the module docstring).
    kept_ev, kept_durs = [], []
    note_no = 0
    for x, d in zip(ev, durs):
        is_rest = x[0] == SP
        if not is_rest:
            if d <= 0:
                raise Refusal("badRequest",
                              "Note %d (%r) is shorter than 10 ms after rounding to the model's grid."
                              % (note_no, x[5]))
            note_no += 1
        elif d == 0:
            continue
        kept_ev.append(x)
        kept_durs.append(d)
    ev, durs = kept_ev, kept_durs
    meta = {"index": "vocal_0_%d" % total_ms, "language": language, "time": [0, total_ms],
            "duration": " ".join("%.2f" % d for d in durs),
            "text": " ".join(x[5] for x in ev),
            "phoneme": " ".join(x[0] for x in ev),
            "note_pitch": " ".join(str(x[3]) for x in ev),
            "note_type": " ".join(str(x[4]) for x in ev)}
    n_frames = int(sum(durs) * SAMPLE_RATE / HOP)
    if f0_const is not None:
        meta["f0"] = " ".join(["%.1f" % f0_const] * (n_frames + 5))
    # the spike's asserts (plan §1.3 E.5)
    lengths = [len(meta[k].split()) for k in ("duration", "text", "phoneme", "note_pitch", "note_type")]
    if len(set(lengths)) != 1:
        raise Refusal("badRequest", "Internal: metadata list lengths differ %r (a word with spaces?)." % lengths)
    if abs(sum(durs) * 1000 - total_ms) > 10:
        raise Refusal("badRequest", "Internal: durations %r vs span %d ms." % (sum(durs), total_ms))
    info = {"entries": lengths[0], "notes": len(notes), "total_ms": total_ms, "mel_frames": n_frames,
            "score_notes_s": [(round(lead + s, 3), round(lead + e, 3), p + pitch_offset) for p, s, e in notes],
            "bounds_s": bounds_of(meta), "substitutions": subs}
    return meta, info


def bounds_of(meta):
    """Cumulative entry boundaries (seconds) as the model sees them: the running sum of `duration`."""
    out, t = [0.0], 0.0
    for d in meta["duration"].split():
        t += float(d)
        out.append(t)
    return out


def build_from_beats(notes_beats, words, bpm=100.0, lead=DEFAULT_LEAD, trail=DEFAULT_TRAIL, **kw):
    """The spike's own signature: notes as (pitch, startBeat, lengthBeats). Computes start_s = sb * spb and
    end_s = (sb + lb) * spb, so `lead + start_s` is the spike's `LEAD + sb * spb` bit for bit."""
    spb = 60.0 / bpm
    notes = [(p, sb * spb, (sb + lb) * spb) for p, sb, lb in notes_beats]
    return build_meta(notes, words, lead=lead, trail=trail, **kw)


def prompt_words(prompt_notes):
    """Own-voice prompt labels -> (notes, words, lead, trail_end).

    prompt_notes: [(midi, start_s, end_s, word, continues)] relative to the prompt window. A note with
    continues=True is another note of the previous note's word (note_type 3, the whole word's phonemes).
    Returns notes shifted so the first starts at 0, the words, and lead = the first note's start.
    """
    if not prompt_notes:
        raise Refusal("badRequest", "The voice prompt has no notes.")
    lead = prompt_notes[0][1]
    notes, words = [], []
    for i, (midi, s, e, word, cont) in enumerate(prompt_notes):
        notes.append((midi, s - lead, e - lead))
        if cont:
            if not words:
                raise Refusal("badRequest", "Prompt note 0 cannot continue a previous word.")
            if words[-1][0] != word:
                raise Refusal("badRequest",
                              "Prompt note %d continues %r but carries the word %r." % (i, words[-1][0], word))
            words[-1][1].append(i)
        else:
            words.append((word, [i]))
    return notes, words, lead


def build_prompt_meta(prompt_notes, window_s, phonemize=None, phoneset=None, label_offset=0):
    """The own-voice prompt metadata: the same converter, with lead = the first label's start and
    trail = window length - the last label's end. `label_offset` moves NON-REST labels only (rests stay 0),
    matching upstream's own `note_pitch > 0` mask (design §2.4, `promptLabelOffset`)."""
    notes, words, lead = prompt_words(prompt_notes)
    trail = window_s - prompt_notes[-1][2]
    if trail < -1e-9:
        raise Refusal("badRequest", "The last prompt note ends after the prompt window.")
    return build_meta(notes, words, lead=lead, trail=max(0.0, trail), phonemize=phonemize, phoneset=phoneset,
                      pitch_offset=label_offset)


def dump_meta_list(meta_list):
    """The spike's file bytes: json.dump(list, f, ensure_ascii=False, indent=1), no trailing newline."""
    return json.dumps(meta_list, ensure_ascii=False, indent=1).encode("utf-8")


def mel_frames(meta):
    """DataProcessor.preprocess's frame count: int(sum(duration) * 24000 / 480)."""
    return int(sum(float(x) for x in meta["duration"].split()) * SAMPLE_RATE / HOP)


def output_samples_24k(meta):
    """cli/inference.py process(): the merged buffer is int(time[1] / 1000 * 24000) samples."""
    return int(meta["time"][1] / 1000 * SAMPLE_RATE)
