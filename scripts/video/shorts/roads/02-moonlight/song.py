#!/usr/bin/env python3
r"""MOONLIGHT — Beethoven, Op. 27 No. 2, 1st movement (Adagio sostenuto).

The first real piece on the roads. User: "can we get some famous composition
like moonlight sonata, not the whole length, but the famous part and play it."

⛔ NOT ONE PITCH HERE WAS TYPED FROM MEMORY. `ly2notes.py` parses the Mutopia
edition in `source/` (see source/PROVENANCE.md). ⚠ IT DOES NOT assert a ground truth
on the build path — every assert in ly2notes.py sits under `__main__`; see the
header there. The claim that follows is about `python ly2notes.py`, not about this build.
The original wording said it asserts a ground truth
before returning. The harmonic skeleton printed by `--skeleton` is DERIVED from
those parsed notes, not asserted over them, so it is a readout of what will
actually sound rather than a claim about it.

⭐ THREE ROADS, NO PERCUSSION. There are no drums in this movement, so the perc
road is simply absent (prep.mjs already builds it only when a drum track
exists). The three roads are the three real strands of the texture:
    MELODY     the dotted repeated-note tune, silent until bar 5
    ARPEGGIO   the continuous triplets, twelve to the bar, unbroken
    BASS       the held left-hand octaves
Order across x is score order top-to-bottom, and the camera sits on the -x
side, so the melody is the nearest and largest road. It being EMPTY for the
first four bars is the piece, not a defect.

⚠ THE STAFF IS DRAWN BY LETTER NAME AND THIS KEY HAS FOUR SHARPS. The existing
mapping (`staffStep` in prep.mjs) is diatonic BY PITCH CLASS and THROWS on any
pitch outside the 7-note scale; bars 1-20 use every one of the twelve pitch
classes, so it cannot represent this music at all. Checked before writing a
note, exactly as instructed. The fix is that every note carries its own staff
step, parsed from the source's SPELLING — B# and C are one key and two lines.
⚠ ACCIDENTAL GLYPHS ARE STILL NOT DRAWN. A sharp is in the sound and in the
staff POSITION, but no ♯ is engraved beside the head. Stated, not hidden.
"""
import os, sys, json

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from ly2notes import block, parse, LET

BARS = int(os.environ.get("MOON_BARS", "20"))
BPM  = 56          # quarter = 56. Adagio sostenuto; 2/2, so a bar is 4 beats.
LEN  = BARS * 4

SRC = open(os.path.join(HERE, "source", "moonlight1-a4.ly")).read()
ARP, _ = parse(block(SRC, "topsecondary"), 4, 2.0 / 3.0)
MEL, _ = parse(block(SRC, "topmain"), 4)
BAS, _ = parse(block(SRC, "bottom"), 3)


def dstep(letter, octave):
    """Absolute DIATONIC step: the staff line a notehead sits on, by letter."""
    return 7 * octave + LET.index(letter)


def take(ev, vel, minlen=0.0):
    """LilyPond whole-notes -> [start_beat, midi, length_beats, vel, staffStep]."""
    out = []
    for pos, ns, dur, rest in ev:
        if rest or pos >= BARS - 1e-9:
            continue
        for midi, letter, octave in ns:
            out.append([round(pos * 4, 6), int(midi),
                        round(max(minlen, min(dur, BARS - pos) * 4), 6),
                        int(vel), dstep(letter, octave)])
    return out


# ⚠ VELOCITIES ARE THE DYNAMIC, NOT THE MIX. "sempre pianissimo"; the melody is
# the only thing that leans out. Absolute level is steered to -14 LUFS by
# gain.mjs afterwards, so these numbers only set the BALANCE.
# ⚠ THE PEDAL LIVES IN build.mjs, NOT HERE. Beethoven's direction is "senza
# sordini" — dampers off — and the wire path writes no CC 64, so the arpeggio
# track asks for `audioHoldBeats` below and the notes reach the DAW held four
# triplets long. THE LENGTHS IN THIS FILE STAY WRITTEN-LENGTH.
# ⛔ LENGTHENING THEM HERE WAS TRIED AND IT TRIPLED THE PLAYHEADS: prep.mjs
# deals overlapping notes to separate voices, so one arpeggio line rendered as
# three parallel lights running down the road. A change made for the SOUND
# reached the PICTURE through a shared array. Measured on a real render.
# THE BASS IS NOT HELD: its written octaves are already half- and whole-notes.
arp  = take(ARP, 46)
mel  = take(MEL, 82)
bass = take(BAS, 54)


def band(ns):
    ds = [n[4] for n in ns]
    return min(ds), max(ds), (min(ds) + max(ds)) // 2


# ⭐ EACH ROAD'S BOTTOM LINE IS DERIVED FROM ITS OWN RANGE, not inherited from a
# clef. The staff is five lines = eight steps, so centring the part puts its
# bottom line four steps under the middle of what it actually plays. A clef
# origin copied from the tuning sample would have put the bass eight ledger
# lines off its own staff -- the failure prep.mjs's own comment records.
ROADW = {}
for nm, ns in (("mel", mel), ("arp", arp), ("bass", bass)):
    lo, hi, mid = band(ns)
    bot = mid - 4
    # widest excursion from the bottom line, in world units, + a notehead
    halfw = round(max(abs(-0.40 + (lo - bot) * 0.10),
                      abs(-0.40 + (hi - bot) * 0.10)) + 0.12, 2)
    ROADW[nm] = (bot, halfw, lo, hi)

if "--skeleton" in sys.argv:
    # THE HARMONIC SKELETON, BAR BY BAR, DERIVED FROM THE PARSED NOTES.
    # An error at this level is visible to anyone who reads it; an error buried
    # in 240 triplet pitches is not.
    # ⚠ SPELLED, NOT PITCH-CLASSED. A first cut printed bar 6's bass as "C" and
    # bar 20's as "F"; they are B# and E#, and the whole point of this readout
    # is that a human can check it against a score. It reads the LETTER out of
    # the same tuple the staff position comes from.
    def spell(n):
        step, midi = n[4], n[1]
        letter = LET[step % 7]
        nat = 12 * (step // 7 + 1) + {"c": 0, "d": 2, "e": 4, "f": 5,
                                      "g": 7, "a": 9, "b": 11}[letter]
        alt = midi - nat
        return letter.upper() + ("#" * alt if alt > 0 else "b" * -alt)
    for b in range(BARS):
        lo = [n for n in bass if b * 4 <= n[0] < (b + 1) * 4]
        ap = sorted({spell(n) for n in arp if b * 4 <= n[0] < (b + 1) * 4})
        root = spell(min(lo, key=lambda n: n[0])) if lo else "-"
        print(f"  bar {b+1:2d}  bass {root:3s}  arpeggio {' '.join(ap)}")
    for nm in ("mel", "arp", "bass"):
        bot, hw, lo, hi = ROADW[nm]
        print(f"  road {nm:5s} steps {lo}..{hi}  bottom line {bot}  halfW {hw}")
    sys.exit(0)

# ⭐ THE LOOK IS INHERITED, NOT RE-TYPED. Round 12 closed with the user's "all
# four looks great!" on the tuning sample's look block; copying those numbers by
# hand is how a settled look drifts. This reads them.
SAMPLE = json.load(open(os.path.join(HERE, "..", "00-sample", "song.json")))
look = dict(SAMPLE["look"])
look["roadLabels"] = 1

song = {
    "id": "moonlight",
    "title": "Beethoven — Moonlight Sonata",
    "subtitle": "Op. 27 No. 2  ·  Adagio sostenuto  ·  C♯ minor",
    # ⚠ keyRoot/keyScale/bottomLinePitch are now only a FALLBACK. Every note
    # below carries its own staff step (element 4), so nothing in this piece is
    # routed through the pitch-class mapping that cannot represent it. These
    # three are kept legal so prep.mjs's unconditional reference call succeeds.
    "keyRoot": 1, "keyScale": "minor", "bottomLinePitch": 40,
    "vizLagMs": 17.5,
    # ⭐ RESTORED TO THE APPROVED 0.45. It was held at 0.30 for exactly one
    # reason: at 0.45 the 20-bar road is ~111 units long and ONE paper texture
    # wanted 50,445 rows against a measured 16,384 GPU limit. That wall is gone —
    # the map is now a bounded 12,288-row tile wrapped down the sheet (see the
    # long note in lib/prep.mjs and the (S) gate in lib/seam.mjs), so length no
    # longer buys texture height at all.
    # ⚠ THE SPACING WAS NEVER THE PROBLEM AND MUST NOT BE THE FIX: staying legal
    # on one texture at 20 bars needed zPerGap <= 0.145, which puts consecutive
    # noteheads 0.12 units apart against a 0.15-unit notehead — overlapping.
    "zPerGap": float(os.environ.get("MOON_ZPG", "0.45")),
    "tempoSegments": [{"startBeat": 0, "bpm": BPM}],
    "beatsPerBar": 4, "lengthBeats": LEN,
    "renderSeconds": round(LEN * 60 / BPM + 2.4, 2),
    "look": look,
    "formats": SAMPLE["formats"],
    # ⭐ THE CAMERA'S FIT REFERENCE TRAVELS WITH THE CAMERA. `formats` carries
    # the approved keyframes; `cameraFitLayout` records the lateral layout those
    # keyframes were FRAMED AGAINST. Inheriting one without the other is exactly
    # how the Bass road ended up off the right edge of this piece: the camera was
    # right for the sample's layout and this piece's layout is 0.20 further right
    # and 0.09 wider. prep.mjs slides and widens from the difference.
    "cameraFitLayout": SAMPLE["cameraFitLayout"],
    # ⚠⚠ SOLVED, NOT CHOSEN, AND RE-SOLVED ONCE THE SPACING WENT BACK TO 0.45.
    # `cameraFitExtra` scales the DOLLY (back and h together) past what the sheet's
    # own half-width asks for, to cover the near-field crop a lateral half-width
    # cannot see. Measured against framing.mjs at FRAMING_ALLOW=0 on this piece at
    # zPerGap 0.45:  1.19 -> 16 offenders,  1.28 -> 1,  1.30 -> 0,  1.45 -> 0.
    # So the threshold is between 1.28 and 1.30 and 1.40 sits clear of it.
    # ⚠ IT IS SPACING-DEPENDENT, which is the honest limit of a per-song constant:
    # at zPerGap 0.30 the same piece needed only 1.06. Re-solve whenever the
    # layout, the spacing or the camera keyframes move — the gate at ALLOW=0 is
    # what makes that a check rather than a hope.
    "cameraFitExtra": 1.40,
    "buses": SAMPLE["buses"],
    "master": SAMPLE["master"],
    "tracks": [
        # ⚠ ONE INSTRUMENT, THREE ROADS. All three are the same piano program;
        # they are three STRANDS of one pair of hands, not three players, so
        # nothing is panned apart.
        {"name": "Melody", "label": "Melody", "program": 0, "road": True,
         "roadX0": -1.30, "roadHalfW": ROADW["mel"][1], "roadBottomStep": ROADW["mel"][0],
         "color": "#FFD08A", "volume": 0.92, "pan": 0.0,
         "send": {"bus": "Air", "level": 0.26}, "notes": mel},
        {"name": "Arpeggio", "label": "Arpeggio", "program": 0, "road": True,
         "roadX0": -0.05, "roadHalfW": ROADW["arp"][1], "roadBottomStep": ROADW["arp"][0],
         "color": "#FFC46B", "volume": 0.72, "pan": 0.0, "audioHoldBeats": 1.3333,
         "send": {"bus": "Air", "level": 0.20}, "notes": arp},
        {"name": "Bass", "label": "Bass", "program": 0, "road": True,
         "roadX0": 1.55, "roadHalfW": ROADW["bass"][1], "roadBottomStep": ROADW["bass"][0],
         "color": "#FFB45A", "volume": 0.80, "pan": 0.0,
         "send": {"bus": "Air", "level": 0.14}, "notes": bass},
    ],
}

sys.path.insert(0, os.path.join(HERE, "..", "..", "tunes", "lib"))
from theory import write
write(song, os.path.join(HERE, "song.json"))
print(f"moonlight: {BARS} bars, {LEN} beats, {song['renderSeconds']}s  "
      f"mel {len(mel)} arp {len(arp)} bass {len(bass)} notes")
