#!/usr/bin/env python3
r"""BWV 846 — PRELUDE IN C, THE WHOLE PIECE (35 bars), as a roads payload.

⛔ NOT ONE PITCH HERE WAS TYPED FROM MEMORY, and this time that claim has an
ORACLE behind it rather than a hand-written expectation. `ly2notes.py` parses
the Mutopia LilyPond edition; `bach_gt.py` then scores every parsed note —
pitch, onset AND duration — against `source/wtk1-prelude1.mid`, which LILYPOND
produced from the same `.ly`. 549/549 or the build stops.

⭐ THREE ROADS, AS THE SCORE IS WRITTEN — the user's decision, taken with the
lockstep problem in front of them: roads 1 and 2 have IDENTICAL rhythm, one note
per half bar, 66 times, a sixteenth apart. They chose it anyway because it is
the source's own structure, and because the G2 PEDAL AT BARS 24-31 then becomes
a real event: for 32 seconds one light stops moving sideways while everything
else keeps flowing. The camera is built around that.

⚠ THE LOOK IS READ FROM 03-moonlight-long/song.json AND ASSERTED, NOT RETYPED.
Round 28 froze it on three stills the user approved by name; a second film that
copies eleven numbers by hand is how a frozen look drifts.
"""
import os, sys, json, math, copy

HERE = os.path.dirname(os.path.abspath(__file__))
MOON = os.path.join(HERE, "..", "03-moonlight-long")
sys.path.insert(0, MOON)
sys.path.insert(0, HERE)
from ly2notes import parse_voice, invariants, LET
from bach_gt import check as bach_check

# ⭐ 35 bars, ♩=60, 4/4 — every one of those is READ, not assumed. The `.ly`
# carries `\tempo 4=60` and the MIDI carries the same tempo event; the bar count
# is what the oracle counts.
BARS = int(os.environ.get("BACH_BARS", "35"))
BPM  = 60
LEN  = BARS * 4

SRC = open(os.path.join(HERE, "source", "wtk1-prelude1.ly")).read()
# ⭐ `right` is ABSOLUTE and carries `\transpose c c'`; `left` is `<< tenor \\ bass >>`.
# parse_voice detects both. Round 30's six fixes are what make these three lines
# possible at all — before them `right` returned zero events and `left` collapsed.
FIG, FIG_BARS = parse_voice(SRC, "right", 3)
TEN, TEN_BARS = parse_voice(SRC, "left", 3, voice=0)
BAS, BAS_BARS = parse_voice(SRC, "left", 3, voice=1)
for _nm, _ev, _bb in (("figure", FIG, FIG_BARS), ("tenor", TEN, TEN_BARS), ("bass", BAS, BAS_BARS)):
    invariants(_nm, _ev, _bb, verbose=False)


def dstep(letter, octave):
    """Absolute DIATONIC step: the staff line a notehead sits on, by letter."""
    return 7 * octave + LET.index(letter)


def take(ev, vel, end=None):
    """LilyPond whole-notes -> [start_beat, midi, length_beats, vel, staffStep]."""
    end = BARS if end is None else end
    out = []
    for pos, ns, dur, rest in ev:
        if rest or pos >= end - 1e-9:
            continue
        for midi, letter, octave in ns:
            out.append([round(pos * 4, 6), int(midi),
                        round(min(dur, end - pos) * 4, 6), int(vel),
                        dstep(letter, octave)])
    return out


# ⚠ VELOCITIES ARE THE BALANCE, NOT THE MIX — gain.mjs steers absolute level to
# -14 LUFS afterwards. The figure never stops and the other two speak twice a
# bar, so the sustained voices sit ABOVE it or they are not there at all.
# ⛔ NO `audioHoldBeats` ANYWHERE. Beethoven wrote *senza sordini* and the
# Moonlight payload holds its arpeggio for that reason; Bach wrote no pedal mark
# and this edition has none. Written lengths, with the one deliberate exception
# below, which is named.
figure = take(FIG, 62)
tenor  = take(TEN, 74)
bass   = take(BAS, 80)

# ⭐⭐ THE ORACLE, ON THE BUILD PATH, BEFORE ANY EDIT.
GT = bach_check(figure, tenor, bass, BPM, bars=BARS)

# ═════════════════════════════════════════════════════════════════════════════
# ⭐⭐ THE TENOR HOLD — the one deliberate departure from the written lengths.
# MEASURED, round 29: the tenor is written `r16 e'8. ~ e'4`, so it sounds 1.75
# of every 2.0 beats and leaves a 0.25 s hole before the next onset. road.html
# :1804 fires its idle fade in exactly that hole on 65 of the tenor's 66 gaps
# (the figure fires 0 of 414, the bass 0 of 66), and :1848 takes the lamp from
# 0.60 to 0.60*exp(-0.25/0.45) = 0.3443 — a 43 % dip, 65 times, over 140 s.
# ⚠ IT IS THE LAMP, NOT THE DISK: `coreSteady` 1.0 holds the playhead disk. So
# this is a flicker in the pool of light, not the round-27 defect returning.
# ⭐ THE FIX IS PAYLOAD-LEVEL AND REVERSIBLE: hold each tenor note to the NEXT
# ONSET, which is what a keyboard player's finger does anyway. `gapNext` then
# equals the duration, `t > noteEnd` is never true, and the fade cannot fire.
# ⚠⚠ IT REACHES THE AUDIO TOO, AND THERE IS NO PICTURE-ONLY PATH: build.mjs and
# road.html read the SAME array. The tenor sounds 2.0 beats instead of 1.75, 66
# times. Stated rather than buried — BACH_TENOR_HOLD=0 renders the comparison.
# ⚠ EXACTLY ABUTTING, NEVER OVERLAPPING. prep.mjs:67 reuses a voice when
# `v.free <= onset + 1e-6`, so `start + len == next.start` stays ONE voice; a
# longer hold would deal the tenor into two parallel lights, which is the
# failure the Moonlight payload's own comment records.
TENOR_HOLD = os.environ.get("BACH_TENOR_HOLD", "1") == "1"
_held = 0
if TENOR_HOLD:
    for i in range(len(tenor) - 1):
        want = round(tenor[i + 1][0] - tenor[i][0], 6)
        if want > tenor[i][2] + 1e-9:
            tenor[i][2] = want
            _held += 1

# ═════════════════════════════════════════════════════════════════════════════
def band(ns):
    ds = [n[4] for n in ns]
    return min(ds), max(ds), (min(ds) + max(ds)) // 2


# ⭐ EACH ROAD'S BOTTOM LINE AND LANE ARE DERIVED FROM ITS OWN RANGE, exactly as
# the Moonlight payload derives them — five staff lines is eight steps, so the
# bottom line sits four steps under the middle of what the part actually plays,
# and the lanes are laid edge to edge with one gap, centred on 0.
# ⚠ LANE ORDER IS HIGHEST-VOICE-LEFT, the same convention as the Moonlight cut
# (Melody, Arpeggio, Bass). Here that is figure, tenor, bass.
LANE_GAP = float(os.environ.get("BACH_LANE_GAP", "0.40"))
ROADW = {}
for nm, ns in (("fig", figure), ("ten", tenor), ("bass", bass)):
    lo, hi, mid = band(ns)
    bot = mid - 4
    halfw = round(max(abs(-0.40 + (lo - bot) * 0.10),
                      abs(-0.40 + (hi - bot) * 0.10)) + 0.12, 2)
    ROADW[nm] = (bot, halfw, lo, hi)

ROADX = {}
_tot = sum(ROADW[k][1] for k in ("fig", "ten", "bass")) * 2 + 2 * LANE_GAP
_cur = -_tot / 2
for nm in ("fig", "ten", "bass"):
    hw = ROADW[nm][1]
    ROADX[nm] = round(_cur + hw, 3)
    _cur += 2 * hw + LANE_GAP

if "--skeleton" in sys.argv:
    def spell(n):
        step, midi = n[4], n[1]
        letter = LET[step % 7]
        nat = 12 * (step // 7 + 1) + {"c": 0, "d": 2, "e": 4, "f": 5,
                                      "g": 7, "a": 9, "b": 11}[letter]
        alt = midi - nat
        return letter.upper() + ("#" * alt if alt > 0 else "b" * -alt)
    for b in range(BARS):
        lo = [n for n in bass if b * 4 <= n[0] < (b + 1) * 4]
        te = [n for n in tenor if b * 4 <= n[0] < (b + 1) * 4]
        fg = sorted({spell(n) for n in figure if b * 4 <= n[0] < (b + 1) * 4})
        root = spell(min(lo, key=lambda n: n[0])) if lo else "-"
        ten = spell(min(te, key=lambda n: n[0])) if te else "-"
        print(f"  bar {b+1:2d}  t {b*4:6.1f}s  bass {root:3s} tenor {ten:3s}  "
              f"figure {' '.join(fg)}")
    for nm in ("fig", "ten", "bass"):
        bot, hw, lo, hi = ROADW[nm]
        print(f"  road {nm:4s} steps {lo}..{hi}  bottom line {bot}  halfW {hw}  "
              f"x0 {ROADX[nm]}  band [{ROADX[nm]-hw:.2f}, {ROADX[nm]+hw:.2f}]")
    sys.exit(0)

# ═════════════════════════════════════════════════════════════════════════════
# ⭐⭐⭐ THE FROZEN LOOK, READ FROM THE FILM THE USER APPROVED — not retyped.
SAMPLE = json.load(open(os.path.join(HERE, "..", "00-sample", "song.json")))
MOONSONG = json.load(open(os.path.join(MOON, "song.json")))
look = dict(MOONSONG["look"])
look.pop("endCard", None)
FROZEN = {"lightPower": 12.0, "lightDist": 22, "ambient": 0, "overhead": 0,
          "coolFill": 0, "lampLift": 1.55, "liftReach": 6.25,
          "groundExtent": 200, "lampWhite": 0.38, "coreGain": 0.30,
          "coreSteady": 1.0}
# ⛔ ASSERTED, NOT ASSUMED. `coreSteady` DEFAULTS TO 0 in road.html and 0 is a
# byte-identical identity — a payload that loses it regresses the round-27 disk
# defect and NO GATE IN THIS PIPELINE CAN SEE IT. The other ten are asserted for
# the same reason: silence is what a lost look key sounds like.
_drift = {k: (look.get(k), v) for k, v in FROZEN.items() if look.get(k) != v}
assert not _drift, f"the frozen look has drifted in 03-moonlight-long/song.json: {_drift}"
assert look["coreSteady"] == 1.0, "coreSteady is not 1.0"

# ═════════════════════════════════════════════════════════════════════════════
MUSIC_SECONDS = round(LEN * 60 / BPM + 2.4, 2)
CARD_AT   = float(os.environ.get("BACH_CARD_AT", str(round(MUSIC_SECONDS - 1.0, 2))))
CARD_FADE = 2.6
CARD_HOLD = 5.2
PICTURE_SECONDS = round(CARD_AT + CARD_FADE + CARD_HOLD, 2)
# ⚠ THE LICENCE LINE IS THIS SOURCE'S, NOT THE MOONLIGHT'S. That edition is
# CC BY-SA 2.5; THIS one carries `copyright = "Public Domain"` — a typesetter's
# dedication, with no share-alike obligation. Two caveats travel with it and are
# recorded in DESCRIPTION.md: the header's own `source = "Unknown"`, and that a
# dedication written in a file is not a licence document.
look["endCard"] = {
    "at": CARD_AT, "fade": CARD_FADE,
    "title": "J. S. Bach — Prelude in C",
    "subtitle": f"BWV 846 · The Well-Tempered Clavier, Book I · bars 1–{BARS}",
    "credit": [
        "Score: Mutopia-2011/09/12-5 — typeset by Shay Rojansky,",
        "edited by Han-Wen Nienhuys and Tobias Erbsland",
        "Licence: Public Domain (dedication in the source file)",
        "",
        "Performed and visualised in DAW Pro",
    ],
}

# ═════════════════════════════════════════════════════════════════════════════
# ⭐⭐⭐ THE CAMERA — SIX WINDOWS, DERIVED FROM THE HARMONY, NOT PLACED BY EYE.
# Every transition lands on a BAR LINE WHERE THE BASS CHANGES, measured from the
# parsed notes (round 29): bars 11, 19, 24, 32, 35.
#   bars  1-10  the opening sequence; both left-hand voices sound at tick 0
#   bars 11-18  the second span
#   bars 19-23  the approach, and the most chromatic bars in the piece (22: D#/F#)
#   bars 24-31  ⭐ THE G2 PEDAL — 32 seconds in which the bass does not move
#               sideways at all while the figure keeps running
#   bar  32     the bass LANDS ON C. ⚠ NOT the figure's pattern break — round 31
#               typed that and it was wrong: derive.py computes the first bar
#               whose figure half-bars differ and it is bar 33 (2:08), not 32.
#               The camera move is justified by the BASS change; it ends at 32
#               and puts the camera on the FIGURE road in time for 33.
#   bar  35     the final chord, <e g c'>1 with a fermata
# ⭐ THE MOVE ACROSS THE PEDAL IS THE 30-SECOND TRANSITION, not a separate move.
# ⚠ MEASURED, and it is a PULL-BACK, not a push: seg 3 dist 3.21 / lift 1.2 /
# aimX -0.30 -> seg 4 dist 5.16 / lift 2.0 / aimX -1.84. That is forced by the
# framing solve — aiming at the FIGURE road while the bass road must stay in
# frame makes `half` 2.14 -> 3.58, and fit_dist grows with half. A push-IN aimed
# at the figure is geometrically incompatible with framing.mjs at ALLOW=0 on a
# three-road layout. The camera rises, retreats and pans left over 30 s.
# road.html:2387 blends adjacent journey poses with a smoothstep, so a `dur` of
# 30.0 on the move that COMPLETES at bar 32 means the camera creeps for the whole
# pedal and arrives exactly on the break. It is motivated by the music: a slow
# push is the one camera move that reads when nothing else is changing.
BOT_X, STEP_X = -0.40, 0.10
LAG = 0.0175
SECS = lambda beat: beat * 60.0 / BPM + LAG
BAR_T = lambda bar: round(SECS((bar - 1) * 4), 4)


def _xy(ns, nm):
    bot = ROADW[nm][0]
    return [(SECS(n[0]), SECS(n[0]) + SECS(n[2]) - LAG,
             ROADX[nm] + BOT_X + (n[4] - bot) * STEP_X) for n in ns]


_ALL = _xy(figure, "fig") + _xy(tenor, "ten") + _xy(bass, "bass")


def live_band(t0, t1):
    xs = [x for (a, b, x) in _ALL if b > t0 and a < t1]
    if not xs:
        xs = [x for (a, b, x) in _ALL if b > t0 - 8.0 and a < t1]
    if not xs:
        sys.exit(f"camera: no note sounds in [{t0 - 8.0}, {t1}] — a segment with no subject")
    return min(xs), max(xs)


ASPECT = 1920.0 / 1080.0
# ⚠ RE-LADDERED FOR THIS PAYLOAD, NOT INHERITED. The Moonlight cut's 1.30 leaves
# ONE playhead-frame outside the frame here (frame 1, t=0.033, overshoot 0.5 %),
# and a gate at ALLOW=0 means zero. Laddered against framing.mjs on THIS payload:
#   1.30 -> 1 offender (0.5 % overshoot)   1.36 -> 0   1.42 -> 0   1.50 -> 0
# The threshold is between 1.30 and 1.36; 1.42 keeps a margin the way the
# Moonlight cut keeps one over its own.
# ⚠ WIDENING THE FOV MADE IT WORSE, MEASURED (52 -> 1, 54 -> 1, 56 -> 2, 58 -> 2):
# fit_dist SHRINKS with fov, so a wider lens brings the camera in and the fixed
# `sidex` offset then counts for more. Moving `sidex` did not fix it either
# (-0.7/-0.4/-0.1 all -> 2). The distance was the variable.
SAFETY = float(os.environ.get("BACH_CAM_SAFETY", "1.42"))

# ⭐ ROUND 32: THREE CAMERAS OUT OF ONE FILE, exactly the way 03 serves 04 and 05.
# A second copy of the parser, the oracle and the score is a second thing to keep
# in sync and the first thing to rot, so the CUT is environment, not a fork.
#   journey (default) — 06's approved landscape film. UNCHANGED, and pinned by
#                       md5 against 9cbfee9128e6f7bba525c558f0b1b0da after every
#                       edit to this file.
#   side              — 08's landscape cut, watched from off the paper's edge.
#   short             — 07's portrait Short, on 00-sample's `short` format and
#                       the `short-right1` camera the user picked by ladder.
CAM = os.environ.get("BACH_CAM", "journey")
assert CAM in ("journey", "side", "short"), f"BACH_CAM={CAM!r} is not journey|side|short"


def fit_dist(half, fov):
    return round(half * SAFETY / (math.tan(math.radians(fov) / 2) * ASPECT), 2)


MUSIC_END = SECS(LEN)
_T = [
    ("bar 11 — the bass moves off the opening",        BAR_T(11), 2.4),
    ("bar 19 — the approach begins",                   BAR_T(19), 2.4),
    ("bar 24 — the G2 PEDAL begins",                   BAR_T(24), 2.4),
    # ⛔ THE 30 s MOVE IS THE JOURNEY CUT'S, AND ONLY THE JOURNEY CUT'S. On the
    # side cut it would drift the camera across the whole of the G2 pedal — the
    # one passage in this piece whose subject is a bass that does not move. A
    # travelling camera over a still bass is the opposite of the point, so the
    # side cut takes the ordinary 2.6 s and holds.
    ("bar 32 — the bass lands on C" + (" (a 30 s move across the pedal)" if CAM == "journey" else ""),
     BAR_T(32), 30.0 if CAM == "journey" else 2.6),
    ("bar 35 — the final chord",                       BAR_T(35), 2.6),
    ("the music ends — the camera lifts away",         round(MUSIC_END + 4.6, 3), 2.6),
]
_AT = [0.0] + [round(e - d, 3) for (_, e, d) in _T]
_HOLD = _AT[1:] + [PICTURE_SECONDS]

SIDE_CLEAR = 2.34
XHI = max(ROADX[k] + ROADW[k][1] for k in ROADW)
XLO = min(ROADX[k] - ROADW[k][1] for k in ROADW)
FIG_X = ROADX["fig"]

_SHOTS = [
    ("quarter", 52, {"lift": 0.0, "hk": 0.34, "sidex": -1.0}),                # bars 1-10
    ("side",    62, {"lift": 2.4}),                                           # bars 11-18
    ("side",    62, {"lift": 0.0}),                                           # bars 19-23
    ("quarter", 56, {"lift": 1.2, "hk": 0.42, "sidex": 1.0, "ahead": 0.8}),   # bars 24-31 pedal
    # ⭐ THE BREAK IS SHOT ON THE FIGURE ROAD. `aimx` overrides the live band's
    # midpoint: for three bars the camera stops looking at the whole texture and
    # looks at the voice that is actually doing something new.
    ("quarter", 58, {"lift": 2.0, "hk": 0.34, "sidex": 0.7, "ahead": 0.4,
                     "aimx": FIG_X, "bow": 0.45}),                            # bars 32-34
    ("quarter", 60, {"lift": 1.6, "hk": 0.26, "sidex": 2.0, "trail": 4.0, "ahead": 0.0}),  # bar 35
    ("quarter", 58, {"lift": 0.0, "hk": 0.62, "sidex": 1.8, "trail": 9.0, "ahead": 0.0}),  # the lift
]

# ⭐⭐ THE SIDE CUT — 08. Watched from off the edge of the paper the whole way,
# crossing over the top to the left for the middle and back for the pedal, so it
# is a side VIEW rather than a static tripod. Same seven windows as the journey.
# ⚠ THE CROSSING TIMES ARE THIS PIECE'S BAR LINES, NOT the Moonlight's — 03's
# side branch has eight shots against seven windows because ITS `_T` has seven
# transitions. Copying its list here would silently mis-index every window.
# ⭐ `sgn:+1` IS THE RIGHT EDGE, AND THE BASS ROAD IS THE RIGHTMOST LANE, so a
# +1 shot puts the pedal's own road NEAREST the camera. That is the whole reason
# this cut exists, and it is why windows 3 and 4 (bars 24-31, the pedal, and
# 32-34) are both on +1.
# ⚠ `bow` IS WHAT MAKES A CROSSING SIDE SHOT SURVIVE — lerping through x=0 takes
# the camera over the playheads and drops the band out of the bottom of frame.
_SIDE_SHOTS = [
    ("side", 60, {"sgn":  1, "hk": 0.62, "lead": 1.6, "ahead": 1.2}),                 # bars 1-10
    ("side", 60, {"sgn":  1, "hk": 0.66, "lead": 1.2, "ahead": 1.2, "lift": 1.6}),    # bars 11-18
    ("side", 58, {"sgn": -1, "hk": 0.72, "lead": 1.4, "ahead": 1.4, "out": 1.0,
                  "lift": 3.2, "bow": 0.55}),                                         # 19-23, over the top
    ("side", 58, {"sgn":  1, "hk": 0.72, "lead": 0.8, "ahead": 1.0, "out": 0.8,
                  "lift": 3.2, "bow": 0.55}),                                         # 24-31 THE PEDAL, bass nearest
    ("side", 56, {"sgn":  1, "hk": 0.74, "lead": 1.2, "ahead": 1.0, "out": 0.6}),     # 32-34
    ("side", 60, {"sgn":  1, "hk": 0.70, "lead": 4.0, "ahead": 0.6, "out": 1.6}),     # bar 35
    ("side", 60, {"sgn":  1, "hk": 0.66, "lead": 8.0, "ahead": 0.0, "out": 3.0,
                  "lift": 1.4}),                                                      # the lift-away
]
if CAM == "side":
    assert len(_SIDE_SHOTS) == len(_SHOTS) == len(_T) + 1, (
        f"the side cut has {len(_SIDE_SHOTS)} shots for {len(_T)} transitions")
    _SHOTS = _SIDE_SHOTS

# ⛔ THE MAX, NOT THE LAST. `_T` is ordered by bar, and at BACH_BARS=11 the last
# entry (the lift-away, MUSIC_END + 4.6 = 48.6 s) FITS inside a 53.2 s picture
# while bar 19's, 24's, 32's and 35's transitions all land past the end of the
# film. `_T[-1][1] <= PICTURE_SECONDS` therefore said the journey was fine for a
# span that has no bar 19 in it — the same "silently fell back" shape 03's header
# records, arrived at from the other direction. MEASURED: it returned True at
# BARS=11 (48.617 <= 53.2) with BAR_T(35) = 136.018 s in the same table.
JOURNEY_OK = max(e for _, e, _ in _T) <= PICTURE_SECONDS
# ⛔ THE PORTRAIT SHORT IS NOT A JOURNEY, AND MUST SAY SO RATHER THAN FALL BACK.
# Every transition above is an ABSOLUTE second in a 35-bar span; run at
# BACH_BARS=11 they all land past the end of the film. 03's own header records
# what a silent fallback costs — a 42-bar film shipped on the Short's camera with
# every gate green, because they all measure the camera the payload ASKED for.
if CAM == "short":
    assert not JOURNEY_OK, (f"BACH_CAM=short at BARS={BARS}: the journey would still "
                            f"fit ({_T[-1][1]} <= {PICTURE_SECONDS}), so the Short is "
                            f"not a Short — pick a shorter span or the journey cut")
    _SHOTS = []
else:
    assert JOURNEY_OK, (f"the last transition ends at {_T[-1][1]} but the picture is "
                        f"{PICTURE_SECONDS}s — the journey would silently fall back")
SEGMENTS, _camlog = [], []
for i, (typ, fov, kw) in enumerate(_SHOTS):
    t0, t1 = _AT[i], _HOLD[i]
    lo, hi = live_band(t0, t1)
    mid = round((lo + hi) / 2, 3)
    aim = round(kw.get("aimx", mid), 3)
    # ⛔ THE HALF-WIDTH IS MEASURED FROM THE AIM POINT, NOT FROM THE BAND'S
    # MIDPOINT. Those are the same number only when the camera aims at the
    # middle, which is true for every Moonlight segment and FALSE for the one
    # segment here that deliberately looks at one road (bars 32-34, aimed at the
    # figure). MEASURED: with `half` taken from the midpoint, framing.mjs at
    # ALLOW=0 reported 502 playhead-frames out of frame across t 117.3-134.0 —
    # the BASS voice, 3.58 units from the aim against a 2.24-unit fit.
    half = max(hi - aim, aim - lo)
    sg = {"at": _AT[i], "dur": (2.4 if i == 0 else _T[i - 1][2]),
          "type": typ, "fov": fov, "aimX": aim, "aimY": 0.06}
    if kw.get("lift"):
        sg["lift"] = kw["lift"]
    if kw.get("bow"):
        sg["bow"] = kw["bow"]
    if typ == "side":
        _out = SIDE_CLEAR + kw.get("out", 0.0)
        sg["side"] = round((XHI + _out) if kw.get("sgn", 1) > 0 else (XLO - _out), 2)
        sg["h"] = round(kw.get("hk", 0.66) * (XHI - XLO) / 2, 2)
        sg["lead"] = kw.get("lead", 0.35)
        sg["aimAhead"] = kw.get("ahead", 1.2)
        d = abs(sg["side"] - aim)
    else:
        d = fit_dist(half, fov)
        sg["back"] = round(d + kw.get("trail", 0.0), 2)
        d = sg["back"]
        sg["x"] = round(aim + kw["sidex"], 3)
        sg["h"] = round(d * kw["hk"], 2)
        sg["aimAhead"] = kw.get("ahead", 0.6)
    SEGMENTS.append(sg)
    _camlog.append(f"  seg {i} {typ:8s} t {t0:7.2f}-{t1:7.2f}  band[{lo:6.2f},{hi:6.2f}] "
                   f"half {half:4.2f}  aimX {aim:6.2f}  fov {fov}  dist {d:5.2f}"
                   + (f"  lift {kw['lift']}" if kw.get("lift") else ""))

FORMATS = copy.deepcopy(SAMPLE["formats"])
if CAM == "short":
    # ⭐ `short-right1` — the portrait camera the user picked by ladder, read back
    # off 00-sample/out/r19/short-right1/payload.json rather than off a prose
    # parenthesis. 04's header records why: camYawAdd is not decoration, and
    # sliding right without re-aiming points the camera off the road.
    look["camXAdd"] = 0.50
    look["camYawAdd"] = -6.0
    look["take"] = os.environ.get("BACH_TAKE", "default")
else:
    FORMATS["landscape"]["takes"]["journey"] = {
        "kind": "journey", "cullNear": 0.22, "segments": SEGMENTS,
    }
    look["take"] = os.environ.get("BACH_TAKE", "journey")
    look.pop("camXAdd", None)
    look.pop("camYawAdd", None)

if "--camera" in sys.argv:
    print(f"CAMERA {CAM!r} — transitions on bar lines where the bass changes")
    for nm, e, d in _T:
        print(f"  ends {e:8.3f}s  dur {d:5.1f}s   {nm}")
    print("\n".join(_camlog))
    sys.exit(0)

song = {
    "id": os.environ.get("BACH_ID", "bach-prelude"),
    "title": "J. S. Bach — Prelude in C",
    "subtitle": "BWV 846  ·  The Well-Tempered Clavier, Book I",
    "keyRoot": 0, "keyScale": "major", "bottomLinePitch": 40,
    "vizLagMs": round(LAG * 1000, 1),
    "zPerGap": float(os.environ.get("BACH_ZPG", "0.45")),
    "tempoSegments": [{"startBeat": 0, "bpm": BPM}],
    "beatsPerBar": 4, "lengthBeats": LEN,
    "renderSeconds": MUSIC_SECONDS,
    "pictureSeconds": PICTURE_SECONDS,
    "look": look,
    "formats": FORMATS,
    "cameraFitLayout": SAMPLE["cameraFitLayout"],
    "cameraFitExtra": float(os.environ.get("BACH_FIT_EXTRA", "2.20")),
    "buses": SAMPLE["buses"],
    "master": SAMPLE["master"],
    "tracks": [
        # ⚠ ONE INSTRUMENT, THREE ROADS — three strands of one pair of hands, so
        # nothing is panned apart. Colours are the SAME three the user approved
        # on the Moonlight cut (round 28's S=40 hue fan, G1).
        {"name": "Figure", "label": "Figure", "program": 0, "road": True,
         "roadX0": ROADX["fig"], "roadHalfW": ROADW["fig"][1], "roadBottomStep": ROADW["fig"][0],
         "color": "#FF707C", "volume": 0.80, "pan": 0.0,
         "send": {"bus": "Air", "level": 0.20}, "notes": figure},
        {"name": "Tenor", "label": "Tenor", "program": 0, "road": True,
         "roadX0": ROADX["ten"], "roadHalfW": ROADW["ten"][1], "roadBottomStep": ROADW["ten"][0],
         "color": "#FFC370", "volume": 0.88, "pan": 0.0,
         "send": {"bus": "Air", "level": 0.22}, "notes": tenor},
        {"name": "Bass", "label": "Bass", "program": 0, "road": True,
         "roadX0": ROADX["bass"], "roadHalfW": ROADW["bass"][1], "roadBottomStep": ROADW["bass"][0],
         "color": "#DBFF70", "volume": 0.92, "pan": 0.0,
         "send": {"bus": "Air", "level": 0.16}, "notes": bass},
    ],
}

sys.path.insert(0, os.path.join(HERE, "..", "..", "tunes", "lib"))
from theory import write
write(song, os.path.join(os.environ.get("BACH_OUTDIR", HERE), "song.json"))
print(f"bach: {BARS} bars, {LEN} beats, {song['renderSeconds']}s  "
      f"figure {len(figure)} tenor {len(tenor)} bass {len(bass)} notes; {GT}; "
      f"tenor hold {'ON' if TENOR_HOLD else 'OFF'} ({_held} durations extended)")
