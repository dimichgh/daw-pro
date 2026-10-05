#!/usr/bin/env python3
r"""LILYPOND -> NOTES, WITH THE SPELLING KEPT.

⛔ THIS EXISTS BECAUSE TRANSCRIBING FROM MEMORY IS WHERE A CONFIDENT WRONG
ANSWER LIVES. Every pitch comes from the Mutopia Project's edition of Op. 27
No. 2 (Berners 1908, ed. A. Winterberger; Mutopia-2007/02/11-276, CC-BY-SA
2.5), PARSED here rather than typed by me.

⭐ AND IT KEEPS THE SPELLING. A staff is drawn by LETTER NAME: B# and C are the
same key and DIFFERENT LINES. MIDI throws that away, so every event carries
(letter, octave) beside its pitch and the road draws its notehead from that.

⚠ THE CLEANER IS THE DANGEROUS PART, not the note grammar. A first cut removed
`\moveText #'(0 . -2)` with `[^\n|]*` and ATE THE CHORD THAT FOLLOWED IT on the
same line — a silent transcription loss that renders perfectly. Every removal
rule below is therefore NARROW, and the parser asserts a known ground truth
(bar 1 = G#3 C#4 E4 x4) before anything downstream runs.

⭐⭐ ROUND 30 — FIVE SILENT FAILURES, AND THE GUARD THAT MATTERS MORE THAN ANY
OF THEM. Pointing this parser at a second piece (J.S. Bach, BWV 846, Mutopia
2011/09/12-5) found five ways it produced a WRONG ANSWER WITHOUT COMPLAINING:

  1. `block()` used `src.index(name + " =")`, a SUBSTRING search. On the Bach
     file `"right ="` matched inside `copyright = "Public Domain"` and the
     right hand parsed as ZERO EVENTS, with no error. ⚠ AND IT IS LATENT HERE:
     the Moonlight file contains `ragged-bottom =` and `ragged-last-bottom =`,
     which the search for `"bottom ="` also matches. It reads the right block
     TODAY only because the music (offset 11443) happens to sit before the
     \paper block (offset 14036) and `.index` returns the FIRST hit. Reorder
     the file — legal LilyPond — and the bass line becomes `##f`. Now anchored
     to a line start with a regex.
  2. `<< A \\ B >>` polyphony was concatenated into one line. `voices()` now
     splits it into independent streams.
  3. ⛔ THE PITCH MODEL WAS HARD-CODED RELATIVE. `parse()` picked the octave
     nearest the previous note, which is `\relative` semantics; the Bach file
     has no `\relative` anywhere and is entered ABSOLUTELY. Measured before the
     fix: bar 1 read G3 C4 E6 G6 C8 E9 and the octave ran away to MIDI 1392.
     The mode is now DETECTED from the source and there is no default.
  4. `\transpose c c'` was removed by the generic `\[a-zA-Z]+` strip, which
     leaves the ARGUMENTS: the literal `c c'` became two phantom notes at the
     head of the part. Same mechanism as the `\key e \major` bug below, and it
     was FORECAST from that bug and then OBSERVED. Now parsed and applied.
  5. `e!8.` — a forced natural. `!` was in no token class, so the duration
     `8.` detached and the note silently inherited the PREVIOUS duration, which
     then persisted into every following note. ⚠ THIS ONE IS LIVE IN THE
     MOONLIGHT FILE TOO (`b!2.` at line 137, `fis,!`/`a!` at 260, `b,!`/`e!` at
     289) and the fix MOVES 31 melody events — all of them at whole-note 55.0
     and later, i.e. BAR 56, and the film renders 42 bars, so the shipped
     song.json is byte-identical either way. That was measured, not hoped.

⭐⭐ THE GUARD IS THE REAL DELIVERABLE. Every assert in this file was a
MOONLIGHT ground truth living in `ground_truth()`, and NONE of them run on
another piece — which is why a parse containing MIDI 1385 came back clean.
`parse()` now asserts `21 <= midi <= 108` on every note it mints, and
`invariants()` carries the piece-independent structural checks. Fixing the
class, not the instance.
"""
import re, sys, json

LET  = "cdefgab"
SEMI = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}
PITCH = r"[a-g](?:is|es)*[',]*"
# ⚠ MIDI 21..108 is an 88-key piano, A0 to C8. It is deliberately WIDER than
# any piece this pipeline renders and NARROWER than the four-figure numbers a
# broken octave model produces, so it can only ever fire on a real defect.
MIDI_LO, MIDI_HI = 21, 108


def _span(src, name):
    """(i, j, k) — start of the assignment, its opening brace, its closing one.
    ⛔ ANCHORED TO A LINE START. `src.index(name + " =")` is a substring search
    and matched inside `copyright =` / `ragged-last-bottom =`; see §1 above."""
    m = re.search(r"(?m)^[ \t]*" + re.escape(name) + r"[ \t]*=", src)
    if m is None:
        raise ValueError(f"no top-level LilyPond assignment named {name!r}")
    i = m.start()
    j = src.index("{", i)
    d, k = 0, j
    while True:
        if src[k] == "{": d += 1
        elif src[k] == "}": d -= 1
        if d == 0: return i, j, k
        k += 1


def block(src, name):
    i, j, k = _span(src, name)
    return src[j + 1:k]


def pitch_of(tok):
    """absolute LilyPond pitch -> (midi, letter, octave). `c` is C3 = 48."""
    m = re.fullmatch(r"([a-g])((?:is|es)*)([',]*)", tok)
    if not m: raise ValueError(f"not a pitch: {tok!r}")
    letter, acc, oc = m.groups()
    alt = acc.count("is") - acc.count("es")
    octv = 3 + oc.count("'") - oc.count(",")
    return 12 * (octv + 1) + SEMI[letter] + alt, letter, octv


def voice_source(src, name):
    """-> (body, mode, transpose) for a named block.

    `mode` is DETECTED, never defaulted: `\\relative` anywhere in the header or
    the body means relative octaves, its absence means absolute ones. §3 above
    is what a hard-coded default costs.
    ⚠ KNOWN LIMIT: only the MODE is detected. `\\relative c\'`s ARGUMENT is not
    parsed — the caller still passes `start_octave` by hand (4/4/3 in song.py).
    It is ignored entirely in absolute mode, so it costs nothing on the Bach
    file, but it is the same shape of hard-coding as the bug above and it is
    named here rather than left to be rediscovered.
    `transpose` is (diatonic_steps, semitones) from a `\\transpose a b`, which
    is parsed and REMOVED here — before the generic command strip that used to
    leave its two arguments behind as notes (§4)."""
    i, j, k = _span(src, name)
    header, body = src[i:j], src[j + 1:k]
    mode = "relative" if "\\relative" in header + body else "absolute"
    tr = re.search(r"\\transpose\s+(" + PITCH + r")\s+(" + PITCH + r")", body)
    shift = (0, 0)
    if tr:
        (m1, l1, o1), (m2, l2, o2) = pitch_of(tr.group(1)), pitch_of(tr.group(2))
        shift = ((LET.index(l2) + 7 * o2) - (LET.index(l1) + 7 * o1), m2 - m1)
        body = body[:tr.start()] + " " + body[tr.end():]
    assert not re.search(r"\\transpose\b", body), \
        f"{name}: a second \\transpose — this parser applies one per block"
    return body, mode, shift


def transposed(ns, shift):
    """apply (diatonic_steps, semitones) to a pitch list, KEEPING THE SPELLING.
    The letter moves by diatonic steps and the accidental is whatever makes the
    semitone arithmetic come out — which is what LilyPond's \\transpose does."""
    ds, cs = shift
    if (ds, cs) == (0, 0): return ns
    out = []
    for midi, letter, octv in ns:
        idx = LET.index(letter) + 7 * octv + ds
        nl, no = LET[idx % 7], idx // 7
        nm = midi + cs
        alt = nm - 12 * (no + 1) - SEMI[nl]
        assert -2 <= alt <= 2, (
            f"\\transpose landed {nm} on {nl}{no} needing {alt} accidentals — "
            "this parser transposes by keeping the letter arithmetic honest, and "
            "a triple sharp means the interval was read wrong")
        out.append((nm, nl, no))
    return out


def voices(body):
    """-> [stream, ...] — one text stream per written voice.

    `<< A \\\\ B >>` is LilyPond's simultaneous-voices form and the old parser
    read `<<` as two chord-opens, concatenating the voices into one line (it
    produced a literal None-pitched event, which is how it was found). Music
    OUTSIDE the group belongs to every stream; music inside belongs to its own.
    A block with no group is one stream, byte-for-byte the old behaviour."""
    segs, i, n = [], 0, len(body)
    while True:
        a = body.find("<<", i)
        if a < 0:
            segs.append(("plain", body[i:])); break
        d, k = 0, a
        while k < n:
            if body.startswith("<<", k): d += 1; k += 2; continue
            if body.startswith(">>", k):
                d -= 1; k += 2
                if d == 0: break
                continue
            k += 1
        assert d == 0, "unclosed << >>"
        segs.append(("plain", body[i:a]))
        segs.append(("poly", body[a + 2:k - 2]))
        i = k
    parts = []
    for kind, txt in segs:
        parts.append([txt] if kind == "plain" else _split_top(txt))
    nv = max(len(p) for p in parts)
    # ⚠ A LIMIT, ASSERTED RATHER THAN LEFT AS AN IndexError. Two `<< >>` groups
    # in one block with DIFFERENT part counts (2 voices here, 3 there) has no
    # single obvious lane assignment, and neither piece in this pipeline does
    # it. Refused loudly instead of crashing four frames later.
    assert all(len(p) in (1, nv) for p in parts), (
        f"this block mixes {sorted({len(p) for p in parts})}-part << >> groups; "
        "ly2notes assigns one lane per voice and has no rule for that")
    return ["".join((p[v] if len(p) > 1 else p[0]) for p in parts) for v in range(nv)]


def _split_top(txt):
    """split a << >> body on its top-level `\\\\` separators."""
    out, d, last, i = [], 0, 0, 0
    while i < len(txt):
        c = txt[i]
        if c in "{<": d += 1
        elif c in "}>": d -= 1
        elif d == 0 and txt.startswith("\\\\", i):
            out.append(txt[last:i]); i += 2; last = i; continue
        i += 1
    out.append(txt[last:])
    return out


def clean(s):
    s = re.sub(r"%.*", " ", s)
    for _ in range(3):
        s = re.sub(r"\\markup\s*\{[^{}]*\}", " ", s)
        s = re.sub(r"\\markup\s*\{(?:[^{}]|\{[^{}]*\})*\}", " ", s)
    s = re.sub(r"#'\([^()]*\)", " ", s)
    s = re.sub(r"#\((?:[^()]|\([^()]*\))*\)", " ", s)
    s = re.sub(r"##?[a-zA-Z]+", " ", s)
    s = re.sub(r"#-?\d+(\.\d+)?", " ", s)
    s = re.sub(r"#'[a-zA-Z]+", " ", s)
    # ⛔⛔ A SIXTH SILENT FAILURE, FOUND BY THE MIDI ORACLE AND NOT BY READING.
    # `\clef "bass"` — the quoted-string strip below removed `"bass"` and left a
    # bare `\clef`, and the UNQUOTED clef rule further down then ate the next
    # word across the newline: in BWV 846 bar 33 that word was the `r` of `r8`.
    # The rest disappeared, the whole bar moved an eighth early, and nothing
    # complained. MEASURED against LilyPond's own MIDI: 21 of 415 figure notes
    # disagreed before this line, 0 after it. Same shape as `\key e \major` and
    # `\transpose c c'` — a rule that removes a command and keeps eating.
    s = re.sub(r'\\clef\s*"[^"]*"', " ", s)
    s = re.sub(r'-?"[^"]*"', " ", s)
    # ⚠ NAMED BEFORE THE GENERIC STRIP, because the generic strip removes the
    # COMMAND and leaves its ARGUMENT: `\\key e \\major` left a bare `e`, which
    # parsed as a real E3 and became the first note of the bass line.
    # ⚠⚠ `\\transpose c c'` IS THE SAME BUG AND IT WAS FOUND LATER, IN THE WILD.
    # It is handled in voice_source() rather than here, because unlike \\key it
    # has an EFFECT on the notes that follow and cannot simply be deleted.
    s = re.sub(r"\\key\s+[a-g](?:is|es)*\s*\\(major|minor)", " ", s)
    s = re.sub(r"\\time\s+\d+/\d+", " ", s)
    # ⚠ `[ \t]+`, NOT `\s+`: it must not cross a newline and swallow the first
    # token of the next bar. That is exactly what it did above.
    s = re.sub(r"\\clef[ \t]+[a-zA-Z]+", " ", s)
    s = re.sub(r"\\(override|revert|set|tweak|once)\b", " ", s)
    s = re.sub(r"\\[a-zA-Z]+", " ", s)
    s = re.sub(r"[A-Z][A-Za-z]*", " ", s)      # grob names only live in overrides
    s = re.sub(r"-\d+", " ", s)                # fingerings
    s = re.sub(r"[=\^_()\\]", " ", s)
    return s.replace("{", " ").replace("}", " ")


# ⚠ THE TRAILING `(?![a-z])` IS LOAD-BEARING. Without it the token `f` matched
# inside the surviving identifier "fingeringOrientations" and planted a phantom
# F4 as the first note of the piece — which the ground-truth assert caught.
# ⚠⚠ `(?:[!?]*)` AFTER THE OCTAVE MARKS IS THE ROUND-30 FIX. `!` (forced
# accidental) and `?` (cautionary) were in no class at all, so `b!2.` matched
# only `b`, the duration `2.` fell on the floor, and the note took the PREVIOUS
# duration — which then persisted forward. Non-capturing, so the group numbering
# below is unchanged.
TOK = re.compile(r"(<|>|\||~)|\b([a-g](?:is|es)*)(?![a-z])([',]*)(?:[!?]*)((?:\d+\.*)?)((?:\*\d+(?:/\d+)?)?)"
                 r"|\b([rs])(?![a-z])((?:\d+\.*)?)((?:\*\d+(?:/\d+)?)?)")


def durval(d, mult):
    dots = d.count(".")
    n = d.replace(".", "")
    v = 1.0 / int(n)
    v *= (2 - 0.5 ** dots)
    if mult:
        m = mult[1:]
        v *= eval(m) if "/" in m else float(m)
    return v


def parse(body, start_octave, scale=1.0, *, mode, shift=(0, 0), where=""):
    """-> ([(pos, [(midi,letter,octave)...], dur, is_rest)], [barline positions])
    positions and durations are in WHOLE NOTES, already scaled by `scale`
    (2/3 for a block written entirely inside \\times 2/3).

    ⛔ `mode` IS REQUIRED AND HAS NO DEFAULT. It is "relative" or "absolute",
    and a wrong one is not an error you can see — it is a plausible-looking part
    in the wrong octaves. Use voice_source()/parse_voice(), which detect it."""
    assert mode in ("relative", "absolute"), mode
    s = clean(body)
    prev = ("c", start_octave)
    dur = 0.25
    out, pos, bars = [], 0.0, [0.0]
    chord, chord_ref, tie = None, None, False
    for m in TOK.finditer(s):
        br, note, oc, d, mu, rest, rd, rmu = m.groups()
        if br == "|":
            bars.append(pos); continue
        if br == "~":
            tie = True; continue
        if br == "<":
            chord = []; continue
        if br == ">":
            tail = s[m.end():m.end() + 12]
            dm = re.match(r"\s*(\d+\.*)((?:\*\d+(?:/\d+)?)?)", tail)
            if dm: dur = durval(dm.group(1), dm.group(2))
            emit(out, pos, transposed(chord, shift), dur * scale, False, tie); tie = False
            prev, pos, chord = chord_ref, pos + dur * scale, None
            continue
        if rest:
            if rd: dur = durval(rd, rmu)
            elif rmu: dur = durval("4", rmu) if False else dur * (eval(rmu[1:]) if "/" in rmu[1:] else float(rmu[1:]))
            emit(out, pos, [], dur * scale, True, False)
            pos += dur * scale
            continue
        if note is None: continue
        letter, acc = note[0], note[1:]
        alt = acc.count("is") - acc.count("es")
        pl, po = prev
        if mode == "relative":
            di = LET.index(letter) - LET.index(pl)
            octv = po + (-1 if di > 3 else 1 if di < -3 else 0) + oc.count("'") - oc.count(",")
        else:
            octv = 3 + oc.count("'") - oc.count(",")
        midi = 12 * (octv + 1) + SEMI[letter] + alt
        # ⭐⭐ THE PIECE-INDEPENDENT GUARD. Before this line existed, an absolute
        # source parsed in relative mode produced MIDI 1385 and NOTHING SAID SO.
        assert MIDI_LO <= midi + shift[1] <= MIDI_HI, (
            f"{where or 'part'}: MIDI {midi + shift[1]} ({letter}{octv}) at whole-note "
            f"{pos:.4f} is outside {MIDI_LO}..{MIDI_HI} — an 88-key piano. The usual "
            f"cause is the wrong octave MODE (absolute source parsed as relative), "
            f"which runs the octave away without any other symptom.")
        prev = (letter, octv)
        if chord is not None:
            if not chord: chord_ref = prev
            chord.append((midi, letter, octv))
            continue
        if d: dur = durval(d, mu)
        emit(out, pos, transposed([(midi, letter, octv)], shift), dur * scale, False, tie); tie = False
        pos += dur * scale
    return out, bars


def parse_voice(src, name, start_octave, scale=1.0, voice=0):
    """block -> events, with the octave MODE and any \\transpose detected."""
    body, mode, shift = voice_source(src, name)
    streams = voices(body)
    assert voice < len(streams), \
        f"{name}: asked for voice {voice} but the block has {len(streams)}"
    return parse(streams[voice], start_octave, scale, mode=mode, shift=shift,
                 where=f"{name}[{voice}]")


def emit(out, pos, ns, dur, rest, tie):
    # ⚠ ROUNDED, BECAUSE A TRIPLET IS 1/12 AND FLOATS ARE NOT. Accumulating 800
    # of them drifts by ~1e-13, which is enough to put the first note of a bar
    # in the PREVIOUS bar under a `b <= pos < b+1` window — and the per-bar
    # continuity assert reported "13 events in bar 2" for exactly that reason.
    pos, dur = round(pos, 9), round(dur, 9)
    """A TIE EXTENDS, IT DOES NOT RE-STRIKE. The bass holds a whole-bar octave
    across a barline twice in bars 15-18; emitting two notes would put two
    landings where the player's hand never moved."""
    if tie and out and not rest and out[-1][1] and \
       sorted(x[0] for x in out[-1][1]) == sorted(x[0] for x in ns):
        p, n, dd, r = out[-1]
        out[-1] = (p, n, dd + dur, r)
        return
    out.append((pos, ns, dur, rest))


def invariants(name, ev, bars, verbose=True):
    """⭐⭐ THE CHECKS THAT RUN ON ANY PIECE. `ground_truth()` below is a
    MOONLIGHT ground truth — first12 == [56,61,64]*4, the bass 37/49, bar 59 —
    and round 29 found that NONE of it runs on another source, which is how a
    parse containing MIDI 1385 came back clean. These make no claim about which
    notes a piece contains, only that what came out is a well-formed part."""
    problems = []
    if not ev:
        problems.append("parsed ZERO events — check the block name and the "
                        "brace matching; a substring hit on the wrong assignment "
                        "returns an empty body without erroring")
    for i, e in enumerate(ev):
        pos, ns, dur, rest = e
        if dur <= 0: problems.append(f"event {i} at {pos}: duration {dur} is not positive")
        if not rest:
            if ns is None: problems.append(f"event {i} at {pos}: None pitch list (the parser fell over)")
            elif not ns: problems.append(f"event {i} at {pos}: a sounding event with no pitches")
            else:
                for midi, letter, octv in ns:
                    if not (MIDI_LO <= midi <= MIDI_HI):
                        problems.append(f"event {i} at {pos}: MIDI {midi} ({letter}{octv}) outside {MIDI_LO}..{MIDI_HI}")
        if i and pos < ev[i - 1][0] - 1e-9:
            problems.append(f"event {i}: onset {pos} goes BACKWARDS from {ev[i-1][0]}")
    if ev and abs(ev[0][0]) > 1e-9:
        problems.append(f"the part does not start at 0 (first onset {ev[0][0]})")
    assert not problems, f"{name}: " + "; ".join(problems[:8])
    # ⚠ NOT AN ASSERT: bar spacing. It is uneven in perfectly good sources — a
    # multi-bar rest, a `<< >>` group, a pickup — and MEASURED on the Moonlight
    # file the melody's barline intervals are {1.0: 58, 5.0: 1, 3.0: 1, 2.0: 1,
    # 0.75: 1}. An assert here would fire on the approved film. Reported instead.
    iv = {}
    for i in range(len(bars) - 1):
        iv[round(bars[i + 1] - bars[i], 6)] = iv.get(round(bars[i + 1] - bars[i], 6), 0) + 1
    if verbose and len(iv) > 1:
        print(f"  note {name}: barline intervals are not uniform: {iv}")
    return {"events": len(ev), "sounding": sum(1 for e in ev if not e[3]),
            "barIntervals": iv}

def ground_truth(arp, mel, bas, bars):
    """⭐ THE CHECKS THAT WERE ONLY EVER RUN BY HAND. They lived under
    `if __name__ == "__main__"`, while song.py's own docstring said this module
    "asserts a ground truth before returning" — it did not, on the build path.
    Now song.py CALLS this, so extending the film extends the verification with
    it rather than leaving 22 unchecked bars behind the same sentence.
    ⚠ `bars` IS PASSED IN, not assumed 20: the continuity claim is only made
    about the span actually being rendered."""
    # the opening bar is G#3 C#4 E4, four times
    first12 = [e[1][0][0] for e in arp[:12]]
    assert first12 == [56, 61, 64] * 4, first12
    # bar 1 of the bass is the C# octave; bar 2 is B
    assert sorted(x[0] for x in bas[0][1]) == [37, 49], bas[0]
    assert sorted(x[0] for x in bas[1][1]) == [35, 47], bas[1]
    # the melody is silent for four bars and enters in bar 5 on G#4
    assert abs(mel[3][0] - 4.75) < 1e-9 and mel[3][1][0][0] == 68, mel[:5]
    # ⛔⛔ THE GRAMMAR BOUNDARY, MEASURED. The bass block opens a `<< ... >>`
    # polyphony section in bar 60 and this parser has no rule for it: `<<` reads
    # as two chord-opens and the two voices are concatenated into one line. It
    # produced a literal None-pitched event, which is how it was found. NOTHING
    # PAST BAR 59 IS TRUSTWORTHY HERE, so the span is refused rather than
    # silently mis-transcribed.
    assert bars <= 59, (f"bar {bars}: the bass part uses << >> polyphony from bar 60 "
                        "and ly2notes cannot parse it — extend the parser first")
    # ⭐ THE CONTINUITY ASSERTION, over the WHOLE span being rendered. Durations
    # summing to a whole note per bar cannot tell 12 triplets from 11 and a rest.
    # ⚠ THE "NO RESTS" CLAUSE IS TRUE ONLY THROUGH BAR 20, AND THAT IS THE
    # MUSIC, NOT THE PARSER. From bar 29 the source really does write `r bis dis`
    # on the first triplet of the bar — the top voice is holding a note there, so
    # the accompaniment slot is a written rest. Extending the film to 42 bars
    # fired this assert on bar 29, and the score is what settled it. The
    # SLOT-COUNT claim (12 events at k/12, rests included) still holds
    # everywhere, and that is the claim worth keeping.
    RESTFREE = 20
    restbars = []
    for b in range(bars):
        ev = [e for e in arp if b <= e[0] < b + 1]
        assert len(ev) == 12, f"bar {b+1}: {len(ev)} arpeggio events, not 12"
        if any(e[3] for e in ev):
            restbars.append(b + 1)
            assert b >= RESTFREE, f"bar {b+1}: a rest inside the triplets"
        assert all(e[3] or len(e[1]) == 1 for e in ev), f"bar {b+1}: an arpeggio event is a chord"
        for k, e in enumerate(ev):
            assert abs(e[0] - (b + k / 12)) < 1e-6, \
                f"bar {b+1} note {k}: onset {e[0]} is not {b + k/12}"
    # the bass changes only where the harmony does
    for e in bas:
        if e[0] >= bars or e[3]:
            continue
        assert e[1] is not None, f"bass event at {e[0]} has no pitches (parser fell over)"
        assert abs(e[0] * 4 - round(e[0] * 4)) < 1e-6, f"bass onset off the beat: {e[0]}"
    # and no event of any part carries a None pitch list inside the span
    for nm, ev in (("arp", arp), ("mel", mel), ("bass", bas)):
        for e in ev:
            if e[0] < bars and not e[3]:
                assert e[1] is not None, f"{nm}: None pitches at whole-note {e[0]}"
    return {"sounding": len([e for e in arp if e[0] < bars and not e[3]]),
            "restBars": restbars}



if __name__ == "__main__":
    src = open(sys.argv[1]).read()
    arp, abars = parse_voice(src, "topsecondary", 4, 2.0 / 3.0)
    mel, mbars = parse_voice(src, "topmain", 4)
    bas, bbars = parse_voice(src, "bottom", 3)
    for nm, ev, bb in (("arp", arp, abars), ("mel", mel, mbars), ("bass", bas, bbars)):
        invariants(nm, ev, bb)
    nb = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    gt = ground_truth(arp, mel, bas, nb)
    print(f"ground truth ok: {nb} bars x 12 triplet slots at k/12, "
          f"{gt['sounding']} sounding, bass on the beat; "
          f"written rests inside the triplets in bars {gt['restBars'] or 'none'}")
    print("  bars(arp)", len(abars), "events", len(arp), len(mel), len(bas))
    for nm, ev in (("arp", arp), ("mel", mel), ("bass", bas)):
        print(f"  {nm}: {sum(1 for e in ev if not e[3])} sounding, "
              f"through whole-note {ev[-1][0] + ev[-1][2]:.2f}")
