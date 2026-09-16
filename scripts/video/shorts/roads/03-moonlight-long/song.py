#!/usr/bin/env python3
r"""MOONLIGHT — Beethoven, Op. 27 No. 2, 1st movement (Adagio sostenuto).

The first real piece on the roads. User: "can we get some famous composition
like moonlight sonata, not the whole length, but the famous part and play it."

⛔ NOT ONE PITCH HERE WAS TYPED FROM MEMORY. `ly2notes.py` parses the Mutopia
edition in `source/` (see source/PROVENANCE.md) and asserts a ground truth
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
from ly2notes import parse_voice, ground_truth, invariants, LET

# ⭐⭐ THE SPAN, CHOSEN FROM THE STRUCTURE AND DEFENDED IN NOTES.md. 42 bars:
# the opening through the LONG DOMINANT PEDAL (bars 28-41 sit on G# without a
# single change of bass) and out the other side onto the bar-42 downbeat, where
# the bass returns to C# and the arpeggio returns to the exact figure of bar 1.
# That is the movement's own arch closing, not a duration: at quarter = 56 it
# happens to land on 3:00, and if it had landed on 2:40 or 3:20 the boundary
# would still be the reason.
# ⛔ THE START IS NOT A CHOICE — the user asked for "moonlight from start but
# longer", so bar 1 is fixed and only the end was ever open.
BARS = int(os.environ.get("MOON_BARS", "42"))
BPM  = 56          # quarter = 56. Adagio sostenuto; 2/2, so a bar is 4 beats.
LEN  = BARS * 4

SRC = open(os.path.join(HERE, "source", "moonlight1-a4.ly")).read()
# ⭐ ROUND 30: parse_voice() DETECTS the octave mode (\relative vs absolute) and
# any \transpose instead of the parser assuming relative, and splits `<< A \\ B >>`
# polyphony into streams. invariants() then runs the piece-independent checks —
# MIDI in 21..108, no None pitches, positive durations, onsets that do not go
# backwards — which no assert in this pipeline did before.
ARP, ARP_BARS = parse_voice(SRC, "topsecondary", 4, 2.0 / 3.0)
MEL, MEL_BARS = parse_voice(SRC, "topmain", 4)
BAS, BAS_BARS = parse_voice(SRC, "bottom", 3)
for _nm, _ev, _bb in (("arp", ARP, ARP_BARS), ("mel", MEL, MEL_BARS), ("bass", BAS, BAS_BARS)):
    invariants(_nm, _ev, _bb, verbose=False)


def dstep(letter, octave):
    """Absolute DIATONIC step: the staff line a notehead sits on, by letter."""
    return 7 * octave + LET.index(letter)


# ⭐⭐⭐ THE ENDING, AND THE ONE NOTE THAT DECIDED IT.
# Bar 42 is the arrival: fourteen bars of G# pedal (28-41) resolve, the bass
# returns to a C# octave and the arpeggio returns to the exact figure of bar 1.
# ⛔ BUT THE MELODY DOES NOT REST THERE. It has its own pickup at bar 42 beat 4
# (whole-note 41.75, two short G#s) whose LANDING is bar 43's downbeat — and bar
# 43's bass is B#, not C#. So including that pickup ends the film on a gesture
# pointing at a chord the film does not contain, and including bar 43 to resolve
# it ends on the DIMINISHED harmony instead of the tonic. Both are worse endings
# than the arrival itself.
# ⭐ SO THE MELODY'S SPAN ENDS AT 41.75 AND EVERYTHING ELSE ENDS AT 42.0. That is
# not trimming to taste: the melody's own phrase already ENDED at bar 40 beat 3
# (measured — the next melodic rest is 9 beats long), so the part is complete and
# what is dropped is the beginning of the NEXT phrase. Nothing is cut mid-note,
# the bass whole-note of bar 42 sounds in full, and the film ends on a bar line
# with the tonic ringing. 168 beats, 180.0 s of music exactly.
MEL_END = min(float(os.environ.get("MOON_MEL_END", "41.75")), BARS)


def take(ev, vel, minlen=0.0, end=None):
    """LilyPond whole-notes -> [start_beat, midi, length_beats, vel, staffStep]."""
    end = BARS if end is None else end
    out = []
    for pos, ns, dur, rest in ev:
        if rest or pos >= end - 1e-9:
            continue
        for midi, letter, octave in ns:
            out.append([round(pos * 4, 6), int(midi),
                        round(max(minlen, min(dur, end - pos) * 4), 6),
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
mel  = take(MEL, 82, end=MEL_END)
bass = take(BAS, 54)

# ⭐ THE GROUND TRUTH, NOW ACTUALLY RUN. The docstring above has always said
# ly2notes "asserts a ground truth before returning"; it did not — the asserts
# lived under `if __name__ == "__main__"` and the build path never touched them.
# This calls them, over the SPAN BEING RENDERED, so lengthening the film
# lengthens the verification instead of leaving new bars behind an old sentence.
GT = ground_truth(ARP, MEL, BAS, BARS)


def band(ns):
    ds = [n[4] for n in ns]
    return min(ds), max(ds), (min(ds) + max(ds)) // 2


# ⭐ EACH ROAD'S BOTTOM LINE IS DERIVED FROM ITS OWN RANGE, not inherited from a
# clef. The staff is five lines = eight steps, so centring the part puts its
# bottom line four steps under the middle of what it actually plays. A clef
# origin copied from the tuning sample would have put the bass eight ledger
# lines off its own staff -- the failure prep.mjs's own comment records.
# ⭐⭐ AND THE LANES ARE NOW DERIVED TOO, NOT THREE HAND-PLACED NUMBERS.
# The 20-bar cut used roadX0 -1.30 / -0.05 / 1.55, solved by hand against
# half-widths of 0.32 / 0.52 / 0.72. Over 42 bars every part covers far more of
# its staff — the melody spans 18 diatonic steps where it spanned 8, because of
# the descent to B2 in bars 37-40 that leads into the recapitulation (CHECKED
# against the source, and against the arpeggio: inside the span the melody is
# never below the arpeggio's top note). Half-widths become 1.02 / 1.32 / 0.92,
# the old spacing puts all three lanes ON TOP OF EACH OTHER, and marks.mjs says
# so: "roads OVERLAP — containment would prove nothing".
# ⚠ SO THE LANES MUST FOLLOW THE MUSIC, AND HAND-PLACING THEM AGAIN WOULD JUST
# MOVE THE SAME FAILURE TO THE NEXT SPAN. Laid out edge to edge with one gap,
# centred on 0; the gap is the 20-bar cut's own measured gap (0.41 / 0.36 -> 0.40).
LANE_GAP = float(os.environ.get("MOON_LANE_GAP", "0.40"))

ROADW = {}
for nm, ns in (("mel", mel), ("arp", arp), ("bass", bass)):
    lo, hi, mid = band(ns)
    bot = mid - 4
    # widest excursion from the bottom line, in world units, + a notehead
    halfw = round(max(abs(-0.40 + (lo - bot) * 0.10),
                      abs(-0.40 + (hi - bot) * 0.10)) + 0.12, 2)
    ROADW[nm] = (bot, halfw, lo, hi)

ROADX = {}
_tot = sum(ROADW[k][1] for k in ("mel", "arp", "bass")) * 2 + 2 * LANE_GAP
_cur = -_tot / 2
for nm in ("mel", "arp", "bass"):
    hw = ROADW[nm][1]
    ROADX[nm] = round(_cur + hw, 3)
    _cur += 2 * hw + LANE_GAP

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
        print(f"  road {nm:5s} steps {lo}..{hi}  bottom line {bot}  halfW {hw}  "
              f"x0 {ROADX[nm]}  band [{ROADX[nm]-hw:.2f}, {ROADX[nm]+hw:.2f}]")
    sys.exit(0)

# ⭐ THE LOOK IS INHERITED, NOT RE-TYPED. Round 12 closed with the user's "all
# four looks great!" on the tuning sample's look block; copying those numbers by
# hand is how a settled look drifts. This reads them.
SAMPLE = json.load(open(os.path.join(HERE, "..", "00-sample", "song.json")))
look = dict(SAMPLE["look"])
look["roadLabels"] = 1
# ⭐ THE FALLOFF-DERIVED VISIBILITY CULL, ON FOR THE LONG FILM ONLY.
# Default OFF in road.html so the approved 8-bar film keeps reproducing md5
# 8574075dfd3d92ed39c396fcd57af261 byte for byte; the long film turns it on
# because it is the film that has something to cull (299 drawn meshes falling to
# 154, and 0 differing pixels — see lib/cull.mjs and its two controls).
look["cull"] = True
# ⭐ see road.html: the positional label-flip proxies split a frame in two on a
# camera that crosses the road AND goes in front. This one is a dot product.
look["labelFlip"] = "auto"

# ═════════════════════════════════════════════════════════════════════════════
# ⭐⭐⭐ THE FROZEN LOOK (ROUND 28). Approved by the user on three stills of
# `_variants/r27-disk/H1-G1-steady` — "these are good: H1-G1-steady-t59.13.png /
# H1-G1-steady-t63.28.png / H1-G1-steady-t110.00.png". Rounds 23-27's ladders are
# CLOSED; do not re-tune any number in this block.
#
# ⛔ IT IS WRITTEN HERE AND NOT IN 00-sample/song.json, DELIBERATELY. That file is
# the regression anchor whose payload must keep rendering to md5
# e373fc5d30c6b5505a3756185fda538b (22 consecutive runs as of r43). Editing the
# SAMPLE to change the FILM would break the one check that proves road.html is
# stable, so the film overrides the inherited block instead.
#
# WHAT EACH NUMBER IS, so nobody has to go digging:
#  · lightPower 12 / lightDist 22 / ambient 0 / overhead 0 / coolFill 0 — the
#    lamps ARE the lighting now. The old 0.16/6 with 0.45 ambient lit the paper
#    from nowhere; at ambient 0 an unlit road is genuinely dark.
#  · lampLift 1.55 / liftReach 6.25 — U2.50 geometry, approved round 24 ("all
#    three images are perfect"), the 2x-wider cast light the user asked for.
#  · groundExtent 200 — the K3fix infinite floor ("we need infinite surface, not
#    narrow road").
#  · lampWhite 0.38 / coreGain 0.30 — G1, the DARKER of the two colour rungs the
#    user was offered, picked by name.
#  · coreSteady 1.0 — ROUND 27's fix: the playhead disk stops dimming when its
#    voice rests. Default 0 is a byte-identical identity; 1.0 is the whole fix.
look["lightPower"]  = 12.0
look["lightDist"]   = 22
look["ambient"]     = 0
look["overhead"]    = 0
look["coolFill"]    = 0
look["lampLift"]    = 1.55
look["liftReach"]   = 6.25
look["groundExtent"] = 200
look["lampWhite"]   = 0.38
look["coreGain"]    = 0.30
look["coreSteady"]  = 1.0

# ═════════════════════════════════════════════════════════════════════════════
# ⭐ THE END CARD — a DELIVERABLE, not a detail. Two jobs at once:
#  (1) It is the frame a scroller stops on. Without it the film's last frame is a
#      dark grey slab with the paper's end edge cutting across it (opened at
#      t=179.5) — the "dead grey pucks" problem returning.
#  (2) It carries the LICENCE OBLIGATION where a viewer can see it. The user ruled
#      "let's keep it as is for now" on the rights question, so the Mutopia
#      LilyPond edition stays the note source and its CC BY-SA 2.5 attribution
#      travels with the film. That is a DECISION, not an open item.
# ⚠ The film is rendered LONGER than the music so the card has somewhere to live:
# the picture runs to END_CARD_END while music.wav is MUSIC_SECONDS, and the mux
# pads the audio rather than cutting the picture with -shortest.
MUSIC_SECONDS = round(LEN * 60 / BPM + 2.4, 2)
# ⚠ DERIVED FROM THE SPAN, not typed. A second, shorter cut through this same
# file (the vertical Short) has a different music length, and a hardcoded 181.4
# would put its card 140 s past the end of the film.
CARD_AT   = float(os.environ.get("MOON_CARD_AT", str(round(MUSIC_SECONDS - 1.0, 2))))
CARD_FADE = 2.6
CARD_HOLD = 5.2
PICTURE_SECONDS = round(CARD_AT + CARD_FADE + CARD_HOLD, 2)
look["endCard"] = {
    "at": CARD_AT, "fade": CARD_FADE,
    "title": "Beethoven — Moonlight Sonata",
    # ⛔ DERIVED FROM THE SPAN. Hardcoded "bars 1–42" it was a FALSE STATEMENT on
    # the Short's end card, which is bars 1–9 — found by opening the frame, not by
    # any gate, and it is the house failure mode printed 62 px high on the frame a
    # viewer stops on.
    "subtitle": f"Op. 27 No. 2 · Adagio sostenuto · bars 1–{BARS}",
    "credit": [
        "Score: Mutopia-2007/02/11-276 — engraved by Stewart Holmes",
        "from Berners, 1908, ed. A. Winterberger",
        "Licence: Creative Commons Attribution-ShareAlike 2.5",
        "",
        "Performed and visualised in DAW Pro",
    ],
}

# ═════════════════════════════════════════════════════════════════════════════
# ⭐⭐⭐ THE CHOREOGRAPHED CAMERA. The user, verbatim: "fly over and in front and
# then return back to the right side, be dynamic."
#
# ⛔ IT IS NOT A LOOK PREFERENCE — IT IS THE ONLY THING THAT FRAMES THIS SPAN.
# Measured on this payload with framing.mjs at FRAMING_ALLOW=0: a STATIC fit wide
# enough to hold the widest bars (cameraFitExtra >= 2.10) photographs as a small
# grey wedge on black (frame opened), and the approved close fit (1.40) leaves
# 452 of 24,369 playhead-frames out of frame, worst overshoot 13.5 %. The band
# the camera must hold is 6.98 units wide in bars 38-40 and 3.74 in bars 1-4 —
# so no single distance can be right, and a moving camera is the fix.
#
# ⚠⚠ THE PHRASE-GAP METHOD, AS STATED, DOES NOT APPLY HERE — MEASURED, NOT
# ASSUMED. The largest inter-onset gap across all 42 bars is 0.357 s: the
# accompaniment triplets never stop, so "put the move in the biggest gap" would
# put it anywhere at all.
# ⭐ THE VOICE THAT HAS PHRASES IS THE MELODY. Its rests, measured off the built
# payload: 23.57 s (bars 32-36), 6.43 s (bars 9-10), 2.14 s (bar 15), 2.14 s
# (bar 23), and four of 1.07 s (bars 28-31). Every transition below BEGINS AND
# ENDS inside one of those rests and COMPLETES on a named musical event.
#
# ⭐ AND THE SHOT LIST IS DRIVEN BY THE LAYOUT, NOT CHOSEN. Per-bar live-x
# extents, computed below from the same note tuples the roads are built from:
#   bars  1-4   x[-0.60, 3.14]  no melody           narrow, right of centre
#   bars  5-31  x[-3.04, 3.54]  all three roads     the full texture
#   bar  32     melody OUT      x[-0.80, 2.84]      the G# pedal
#   bar  36     bass OUT        x[-0.10, 1.10]      arpeggio ALONE — the thinnest
#   bar  37     melody RETURNS  x[-3.34, 0.10]      far left, no bass
#   bars 38-40  x[-3.44, 2.94]  the descent         THE WIDEST — needs the wide shot
#   bar  41     melody OUT      x[-0.80, 3.14]      the close
# So the widest shot lands on bars 37-40, which is the most dramatic moment in
# the span: the wide framing is MOTIVATED rather than a framing tax.
BOT_X, STEP_X = -0.40, 0.10          # prep.mjs:25 — the same constants, not new ones
SECS = lambda beat: beat * 60.0 / BPM + 0.0175      # song's own lag, below


def _xy(ns, nm):
    bot = ROADW[nm][0]
    return [(SECS(n[0]), SECS(n[0]) + SECS(n[2]) - 0.0175,
             ROADX[nm] + BOT_X + (n[4] - bot) * STEP_X) for n in ns]


_ALL = _xy(mel, "mel") + _xy(arp, "arp") + _xy(bass, "bass")


def live_band(t0, t1):
    """min/max x of every note SOUNDING anywhere in [t0, t1] — the lateral band
    the camera has to hold across that window."""
    xs = [x for (a, b, x) in _ALL if b > t0 and a < t1]
    if not xs:
        # ⚠ THE LAST SEGMENT HAS NO SUBJECT BY DEFINITION — it begins where the
        # music ends. Widening backwards is the honest answer (the shot has to
        # hold what is still DECAYING, which is the material of the bars just
        # gone); silently returning zero would centre the closing move on nothing.
        xs = [x for (a, b, x) in _ALL if b > t0 - 8.0 and a < t1]
    if not xs:
        sys.exit(f"camera: no note sounds in [{t0 - 8.0}, {t1}] — a segment with no subject")
    return min(xs), max(xs)


# ⚠ THE DISTANCE IS SOLVED, NOT PLACED. A camera at distance D with vertical fov
# F on a 16:9 frame covers +/- D*tan(F/2)*aspect laterally at the aim point, and
# every live playhead sits at the SAME z (the road IS the timeline) so the
# subject at any instant is exactly that lateral band. SAFETY covers the
# perspective spread of a band that is not perpendicular to the view axis, and
# framing.mjs at ALLOW=0 is what says whether it was enough.
import math
ASPECT = 1920.0 / 1080.0
SAFETY = float(os.environ.get("MOON_CAM_SAFETY", "1.30"))


def fit_dist(half, fov):
    return round(half * SAFETY / (math.tan(math.radians(fov) / 2) * ASPECT), 2)


# The six transitions. Each is (name, ENDS_AT, dur) and each end is a named
# musical event; `at` is derived so the move COMPLETES there.
_T = [
    ("melody enters (first melody onset)",              20.375, 2.4),
    ("melody re-enters after the 6.43 s rest",          41.803, 2.4),
    ("melody re-enters after the 2.14 s rest, bar 23",  97.517, 2.0),
    ("melody EXITS — bar 32, start of the 23.57 s rest", 136.075, 3.2),
    ("melody RETURNS — bar 37 area, end of that rest",  156.446, 3.2),
    ("bar 42, the tonic return",                        175.732, 3.2),
    # ⭐ AND ONE MORE, WHICH IS THE ENDING ITSELF. It starts exactly where the
    # music stops (the last note-off, 180.0175) and lifts the camera away while
    # the end card fades up through it — so the film ENDS rather than stopping on
    # a dark grey slab. The card is at 181.4, mid-move, deliberately.
    ("the music ends — the camera lifts away",          182.617, 2.6),
]
_AT = [0.0] + [round(e - d, 3) for (_, e, d) in _T]
_HOLD = _AT[1:] + [PICTURE_SECONDS]                        # each segment's window end

# ⚠ The clearance a SIDE camera keeps outside the paper is not invented: the
# approved side take sat 4.20 out from a paper of half-width 1.86 — 2.34 units of
# air. This layout is wider, so the camera moves out with it.
SIDE_CLEAR = 2.34
XHI = max(ROADX[k] + ROADW[k][1] for k in ROADW)
XLO = min(ROADX[k] - ROADW[k][1] for k in ROADW)

_SHOTS = [
    # (type, fov, extra kwargs) — one entry per segment, in journey order
    ("quarter", 52, {"lift": 0.0,  "hk": 0.34, "sidex": -1.0}),   # OPEN: behind, left
    ("side",    62, {"lift": 2.6}),                               # FLY OVER to the right
    ("side",    62, {"lift": 0.0}),                               # ride the right side
    ("front",   58, {"lift": 2.2, "bow": 0.55}),                               # IN FRONT, facing back
    ("quarter", 56, {"lift": 2.2, "bow": 0.55, "hk": 0.40, "sidex": 0.9}),    # back over the top
    ("quarter", 60, {"lift": 1.4,  "hk": 0.46, "sidex": 1.1, "trail": 2.4, "ahead": 0.0}),  # THE WIDEST — bars 37-40
    # ⭐ THE CLOSE IS A WIDE THREE-QUARTER FROM THE RIGHT, NOT A STRICT SIDE, and
    # that is a MEASURED choice: a strict side shot at the tail put the bass
    # voices BEHIND THE CAMERA for 89 frames (framing clusters, t 177.3-180.3).
    # A voice whose part is finished decays to black where it is — the user CLOSED
    # that question as-is — so the camera must be behind ENOUGH to still hold it,
    # which `trail` is: extra distance bought purely to keep the finished voices
    # in the last shot. It is also the frame the film ends on, so it has to be
    # worth looking at.
    ("quarter", 62, {"lift": 1.8,  "hk": 0.20, "sidex": 2.6, "trail": 5.5, "ahead": 0.0}),  # RETURN to the right side
    # THE CLOSE: lifted and pulled far back over the finished road, under the card.
    ("quarter", 58, {"lift": 0.0,  "hk": 0.62, "sidex": 1.8, "trail": 9.0, "ahead": 0.0}),
]

# ⭐ MOON_CAM=side — THE SIDE-VIEW CUT, asked for by the user by name ("would be
# nice to have side view one for moonlight"). It is the SAME film, the same eight
# windows and the same seven measured transitions; only the shot TYPES change, to
# side throughout. The road is watched from off the edge of the paper the whole
# way, crossing over the top to the left for the middle of the piece and back for
# the return, so it is a side view rather than a static tripod.
# ⚠ `sgn` is which side: +1 is the right edge (XHI + clearance), -1 the left
# (XLO - clearance). `out` buys extra clearance, `lead` sits the camera further
# BACK behind the playheads — which is what keeps a finished voice in frame at
# the tail, the failure a strict side shot produced on the journey cut.
if os.environ.get("MOON_CAM") == "side":
    _SHOTS = [
        ("side", 60, {"sgn":  1, "hk": 0.62, "lead": 1.6, "ahead": 1.2}),
        ("side", 60, {"sgn":  1, "hk": 0.66, "lead": 1.2, "ahead": 1.2, "lift": 1.6}),
        ("side", 58, {"sgn":  1, "hk": 0.72, "lead": 0.6, "ahead": 1.4, "out": 0.6}),
        # ⚠ `bow` IS WHAT MAKES A CROSSING SIDE SHOT SURVIVE. Lerping the camera
        # from +5.9 to -5.9 takes it THROUGH x=0, right over the playheads, and
        # the subject falls out of the bottom of the frame for ~10 frames at the
        # midpoint. Measured: lift alone does not fix it (raising the camera
        # while it is directly overhead points it straight down), and REDUCING
        # the lift made it worse — 13 offenders became 17. `bow` pushes the
        # camera radially AWAY from its aim point at the midpoint, which is the
        # move that keeps the band in frame.
        ("side", 58, {"sgn": -1, "hk": 0.72, "lead": 1.4, "ahead": 1.4, "out": 1.0,
                      "lift": 3.2, "bow": 0.55}),                     # OVER THE TOP to the left
        ("side", 56, {"sgn": -1, "hk": 0.78, "lead": 1.0, "ahead": 1.2, "out": 1.0}),
        ("side", 58, {"sgn":  1, "hk": 0.74, "lead": 1.4, "ahead": 1.0, "out": 1.0,
                      "lift": 3.2, "bow": 0.55}),                     # back over for the descent
        ("side", 60, {"sgn":  1, "hk": 0.70, "lead": 4.0, "ahead": 0.6, "out": 1.6}),
        ("side", 60, {"sgn":  1, "hk": 0.66, "lead": 8.0, "ahead": 0.0, "out": 3.0,
                      "lift": 1.4}),                                  # the close, pulled back
    ]

# ⛔ THE JOURNEY IS FOR THE LONG CUT ONLY, AND THE FILE MUST SAY SO IN CODE.
# Every transition time above is an ABSOLUTE second in the 42-bar span. Run this
# same file at MOON_BARS=9 for the vertical Short and all seven of them land past
# the end of the film — `live_band` would exit on "a segment with no subject",
# which is the right failure but the wrong question. The Short uses the PORTRAIT
# camera the user picked by ladder (`short-right1`), not a journey.
# ⛔⛔ THIS COMPARED AGAINST MUSIC_SECONDS AND THAT SHIPPED THE WRONG CAMERA.
# The last transition ENDS at 182.617 s, deliberately — it is the lift-away under
# the end card, which lives in the PICTURE's tail, past the music. MUSIC_SECONDS
# is 182.4, so 182.617 <= 182.4 was FALSE and the 42-bar film silently fell back
# to the Short's portrait camera (`take: default`, camXAdd 0.50). Every gate went
# green on it: framing passes on the fallback, labels pass, framegate passes,
# sync passes — because they all measure THE CAMERA THE PAYLOAD ASKED FOR, and
# nothing compared that against the camera the film was supposed to have.
# MEASURED, not reasoned: out/payload.json of the delivered film read
# `take: default, camXAdd 0.5` while the whole round was gated on a journey.
# ⭐ The FILM's length is the right bound, and the Short is still refused by it
# (its picture is ~46 s, and 182.617 > 46).
JOURNEY_OK = _T[-1][1] <= PICTURE_SECONDS
SEGMENTS = []
_camlog = []
if not JOURNEY_OK:
    _SHOTS = []
for i, (typ, fov, kw) in enumerate(_SHOTS):
    t0, t1 = _AT[i], _HOLD[i]
    lo, hi = live_band(t0, t1)
    mid, half = round((lo + hi) / 2, 3), (hi - lo) / 2
    sg = {"at": _AT[i], "dur": (2.4 if i == 0 else _T[i - 1][2]),
          "type": typ, "fov": fov, "aimX": mid, "aimY": 0.06}
    if kw.get("lift"):
        sg["lift"] = kw["lift"]
    if kw.get("bow"):
        sg["bow"] = kw["bow"]
    if typ == "side":
        # the band lies along the view axis for a side shot, so it is DEPTH, not
        # width: the distance is set by clearance from the paper edge, and the
        # far playhead being far is the shot's whole character.
        _out = SIDE_CLEAR + kw.get("out", 0.0)
        sg["side"] = round((XHI + _out) if kw.get("sgn", 1) > 0 else (XLO - _out), 2)
        # ⚠ THE HEIGHT SCALES WITH THE PAPER, TOO. Inherited flat at 1.30 the shot
        # is almost edge-on across a paper twice the sample's width — read off a
        # frame at t=60, where the three roads collapse into one bright band. The
        # approved side take sat at h 1.23 over a paper of half-width 1.86; that
        # ratio (0.66) applied to THIS half-width is what gives the same look-down
        # angle on a wider sheet.
        sg["h"] = round(kw.get("hk", 0.66) * (XHI - XLO) / 2, 2)
        sg["lead"] = kw.get("lead", 0.35)
        sg["aimAhead"] = kw.get("ahead", 1.2)
        d = abs(sg["side"] - mid)
    else:
        d = fit_dist(half, fov)
        if typ == "front":
            sg["gap"] = d
            sg["x"] = mid
            sg["h"] = 1.55
            sg["aimBehind"] = 0.0
        else:
            sg["back"] = round(d + kw.get("trail", 0.0), 2)
            d = sg["back"]
            sg["x"] = round(mid + kw["sidex"], 3)
            sg["h"] = round(d * kw["hk"], 2)
            sg["aimAhead"] = kw.get("ahead", 0.6)
    SEGMENTS.append(sg)
    _camlog.append(f"  seg {i} {typ:8s} t {t0:7.2f}-{t1:7.2f}  band[{lo:6.2f},{hi:6.2f}] "
                   f"half {half:4.2f}  aimX {mid:6.2f}  fov {fov}  dist {d:5.2f}"
                   + (f"  lift {kw['lift']}" if kw.get("lift") else ""))

import copy
FORMATS = copy.deepcopy(SAMPLE["formats"])
if JOURNEY_OK:
    FORMATS["landscape"]["takes"]["journey"] = {
        "kind": "journey", "cullNear": 0.22, "segments": SEGMENTS,
    }
    look["take"] = os.environ.get("MOON_TAKE", "journey")
else:
    # ⭐ `short-right1` RECONSTRUCTED FROM THE ARTIFACT, NOT FROM THE NOTES.
    # NOTES.md records it as "(+0.50 / −6°)" and nothing else; the two numbers are
    # `camXAdd` and `camYawAdd`, read back off
    # 00-sample/out/r19/short-right1/payload.json — the payload of the cut the user
    # actually approved (md5 536847bad5d0e01722b3ffa2d80ace61) — by diffing its
    # look against its own base.json. A prose parenthesis is not a specification.
    # ⚠ camYawAdd is not decoration: sliding right without re-aiming points the
    # camera off the road, which is the failure roadpix caught on the first short
    # camera (8 of 21 road bands entirely off screen).
    look["camXAdd"] = 0.50
    look["camYawAdd"] = -6.0
    look["take"] = os.environ.get("MOON_TAKE", "default")

if "--camera" in sys.argv:
    print("JOURNEY CAMERA")
    print("\n".join(_camlog))
    print(json.dumps(SEGMENTS, indent=1))
    sys.exit(0)

song = {
    "id": os.environ.get("MOON_ID", "moonlight-long"),
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
    # ⚠ THE AUDIO LENGTH. The PICTURE is longer (see PICTURE_SECONDS) so the end
    # card has somewhere to live; build.sh shoots to picture_seconds and pads the
    # audio. Keeping these two separate is what stops -shortest from cutting the
    # card off the end of the film.
    "renderSeconds": MUSIC_SECONDS,
    "pictureSeconds": PICTURE_SECONDS,
    "look": look,
    "formats": FORMATS,
    # ⭐ THE CAMERA'S FIT REFERENCE TRAVELS WITH THE CAMERA. `formats` carries
    # the approved keyframes; `cameraFitLayout` records the lateral layout those
    # keyframes were FRAMED AGAINST. Inheriting one without the other is exactly
    # how the Bass road ended up off the right edge of this piece: the camera was
    # right for the sample's layout and this piece's layout is 0.20 further right
    # and 0.09 wider. prep.mjs slides and widens from the difference.
    "cameraFitLayout": SAMPLE["cameraFitLayout"],
    # ⚠⚠ RE-SOLVED FOR THIS SPAN, NOT INHERITED. `cameraFitExtra` scales the
    # DOLLY (back and h together) past what the sheet's own half-width asks for,
    # to cover the near-field crop a lateral half-width cannot see.
    # ⚠ IT IS LAYOUT-DEPENDENT, and this layout is not the 20-bar cut's: three
    # wider lanes make the paper 8.28 units across where it was 5.50, so the
    # 20-bar cut's approved 1.40 is simply wrong here. Laddered against
    # framing.mjs at FRAMING_ALLOW=0 on THIS payload:
    #   1.00 -> 1183 offenders   1.20 -> 666   1.40 -> 452   1.60 -> 398
    #   1.80 -> 63               2.00 -> 18    2.10 -> 0     2.20 -> 0   2.50 -> 0
    # So the threshold is between 2.00 and 2.10, and 2.20 sits clear of it with
    # the same ~+0.10 margin the 20-bar cut kept over its own 1.28-1.30.
    # ⚠ DEAD CONFIG FOR THE SHIPPING FILM since look["take"]="journey": only the
    # `default` keyframe camera reads the fit. Kept because the ladder above is the
    # evidence that a STATIC fit cannot serve this span, and MOON_FIT_EXTRA +
    # MOON_TAKE make that head-to-head re-runnable on ONE payload vintage.
    "cameraFitExtra": float(os.environ.get("MOON_FIT_EXTRA", "2.20")),
    "buses": SAMPLE["buses"],
    "master": SAMPLE["master"],
    "tracks": [
        # ⚠ ONE INSTRUMENT, THREE ROADS. All three are the same piano program;
        # they are three STRANDS of one pair of hands, not three players, so
        # nothing is panned apart.
        {"name": "Melody", "label": "Melody", "program": 0, "road": True,
         "roadX0": ROADX["mel"], "roadHalfW": ROADW["mel"][1], "roadBottomStep": ROADW["mel"][0],
         # ⭐ ROUND 28: the S=40 hue fan, approved as G1. Melody / Arpeggio / Bass
         # sit 23.76 deg apart on a circular hue arc against a 1.36 deg positional
         # floor -- "slightly different color for each note track", measured.
         "color": "#FF707C", "volume": 0.92, "pan": 0.0,
         "send": {"bus": "Air", "level": 0.26}, "notes": mel},
        {"name": "Arpeggio", "label": "Arpeggio", "program": 0, "road": True,
         "roadX0": ROADX["arp"], "roadHalfW": ROADW["arp"][1], "roadBottomStep": ROADW["arp"][0],
         "color": "#FFC370", "volume": 0.72, "pan": 0.0, "audioHoldBeats": 1.3333,
         "send": {"bus": "Air", "level": 0.20}, "notes": arp},
        {"name": "Bass", "label": "Bass", "program": 0, "road": True,
         "roadX0": ROADX["bass"], "roadHalfW": ROADW["bass"][1], "roadBottomStep": ROADW["bass"][0],
         "color": "#DBFF70", "volume": 0.80, "pan": 0.0,
         "send": {"bus": "Air", "level": 0.14}, "notes": bass},
    ],
}

sys.path.insert(0, os.path.join(HERE, "..", "..", "tunes", "lib"))
from theory import write
write(song, os.path.join(os.environ.get("MOON_OUTDIR", HERE), "song.json"))
print(f"moonlight: {BARS} bars, {LEN} beats, {song['renderSeconds']}s  "
      f"mel {len(mel)} arp {len(arp)} bass {len(bass)} notes; "
      f"ground truth ok, {GT['sounding']} triplets, rest-bars {GT['restBars'] or 'none'}")
