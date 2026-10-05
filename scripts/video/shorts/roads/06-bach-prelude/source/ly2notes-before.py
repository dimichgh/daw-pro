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
"""
import re, sys, json

LET  = "cdefgab"
SEMI = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}


def block(src, name):
    i = src.index(name + " =")
    j = src.index("{", i)
    d, k = 0, j
    while True:
        if src[k] == "{": d += 1
        elif src[k] == "}": d -= 1
        if d == 0: return src[j + 1:k]
        k += 1


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
    s = re.sub(r'-?"[^"]*"', " ", s)
    # ⚠ NAMED BEFORE THE GENERIC STRIP, because the generic strip removes the
    # COMMAND and leaves its ARGUMENT: `\\key e \\major` left a bare `e`, which
    # parsed as a real E3 and became the first note of the bass line.
    s = re.sub(r"\\key\s+[a-g](?:is|es)*\s*\\(major|minor)", " ", s)
    s = re.sub(r"\\time\s+\d+/\d+", " ", s)
    s = re.sub(r"\\clef\s+\"?[a-zA-Z]+\"?", " ", s)
    s = re.sub(r"\\(override|revert|set|tweak|once)\b", " ", s)
    s = re.sub(r"\\[a-zA-Z]+", " ", s)
    s = re.sub(r"[A-Z][A-Za-z]*", " ", s)      # grob names only live in overrides
    s = re.sub(r"-\d+", " ", s)                # fingerings
    s = re.sub(r"[=\^_()\\]", " ", s)
    return s.replace("{", " ").replace("}", " ")


# ⚠ THE TRAILING `(?![a-z])` IS LOAD-BEARING. Without it the token `f` matched
# inside the surviving identifier "fingeringOrientations" and planted a phantom
# F4 as the first note of the piece — which the ground-truth assert caught.
TOK = re.compile(r"(<|>|\||~)|\b([a-g](?:is|es)*)(?![a-z])([',]*)((?:\d+\.*)?)((?:\*\d+(?:/\d+)?)?)"
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


def parse(body, start_octave, scale=1.0):
    """-> ([(pos, [(midi,letter,octave)...], dur, is_rest)], [barline positions])
    positions and durations are in WHOLE NOTES, already scaled by `scale`
    (2/3 for a block written entirely inside \\times 2/3)."""
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
            emit(out, pos, chord, dur * scale, False, tie); tie = False
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
        di = LET.index(letter) - LET.index(pl)
        octv = po + (-1 if di > 3 else 1 if di < -3 else 0) + oc.count("'") - oc.count(",")
        midi = 12 * (octv + 1) + SEMI[letter] + alt
        prev = (letter, octv)
        if chord is not None:
            if not chord: chord_ref = prev
            chord.append((midi, letter, octv))
            continue
        if d: dur = durval(d, mu)
        emit(out, pos, [(midi, letter, octv)], dur * scale, False, tie); tie = False
        pos += dur * scale
    return out, bars


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
    arp, abars = parse(block(src, "topsecondary"), 4, 2.0 / 3.0)
    mel, mbars = parse(block(src, "topmain"), 4)
    bas, bbars = parse(block(src, "bottom"), 3)
    nb = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    gt = ground_truth(arp, mel, bas, nb)
    print(f"ground truth ok: {nb} bars x 12 triplet slots at k/12, "
          f"{gt['sounding']} sounding, bass on the beat; "
          f"written rests inside the triplets in bars {gt['restBars'] or 'none'}")
    print("  bars(arp)", len(abars), "events", len(arp), len(mel), len(bas))
    for nm, ev in (("arp", arp), ("mel", mel), ("bass", bas)):
        print(f"  {nm}: {sum(1 for e in ev if not e[3])} sounding, "
              f"through whole-note {ev[-1][0] + ev[-1][2]:.2f}")
