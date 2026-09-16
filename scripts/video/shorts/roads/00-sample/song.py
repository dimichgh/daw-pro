#!/usr/bin/env python3
"""THE TUNING SAMPLE — twelve seconds of nothing clever, so the LOOK can be judged.

C major, 120 BPM, six bars. Deliberately trivial music: four bars of a single
piano line (so the jumping light reads at its simplest) and then two bars of
three- and four-note CHORDS, which is the case the renderer has to handle with
one light per voice. A taiko and a woodblock give the fireball behaviour
something to be.

⚠ EVERY road pitch is diatonic in C major — the staff is drawn by letter name.
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "tunes", "lib"))
from theory import N, write

BPM, BARS = 120, 6
LEN = BARS * 4

# (beat, pitch(es), length, vel) — a list of pitches is a chord.
MEL = [
    (0.0, 60, 0.5), (0.5, 64, 0.5), (1.0, 67, 0.5), (1.5, 64, 0.5),
    (2.0, 69, 1.0), (3.0, 67, 1.0),
    (4.0, 65, 0.5), (4.5, 69, 0.5), (5.0, 72, 1.0),
    (6.0, 71, 0.5), (6.5, 69, 0.5), (7.0, 67, 1.0),
    (8.0, 64, 0.5), (8.5, 67, 0.5), (9.0, 72, 0.5), (9.5, 67, 0.5),
    (10.0, 74, 1.0), (11.0, 72, 1.0),
    (12.0, 71, 0.5), (12.5, 74, 0.5), (13.0, 77, 1.0), (14.0, 76, 1.0), (15.0, 72, 1.0),
    # the polyphony half: three and four lights at once
    (16.0, [60, 64, 67], 2.0), (18.0, [65, 69, 72], 2.0),
    (20.0, [62, 67, 71], 2.0), (22.0, [60, 64, 67, 72], 2.0),
]
mel = []
for b, p, l in MEL:
    for q in (p if isinstance(p, list) else [p]):
        mel.append(N(b, q, l, 104 if b % 1 == 0 else 92))

bass = [N(b, r, 1.8, 84) for b, r in
        [(0, 36), (2, 43), (4, 41), (6, 43), (8, 36), (10, 43),
         (12, 38), (14, 43), (16, 36), (18, 41), (20, 43), (22, 36)]]
taiko = [N(b, 45, 0.4, 112) for b in range(0, LEN, 2)]
wood = [N(b, 76, 0.2, 96) for b in range(1, LEN, 2)]

song = {
    "id": "sample", "title": "ROADS — tuning sample",
    "subtitle": "C major  ·  120  ·  one light per voice",
    "keyRoot": 0, "keyScale": "major", "bottomLinePitch": 62,   # D4 on the bottom line
    # ⭐ MEASURED, NOT INHERITED. The finished film's melody onsets sit +0.8 ms
    # from the score (sync.py --road-only, identical on the PCM wav and on the
    # muxed mp4), and this detector fires 16.7 ms EARLY on clicks of known time
    # (lib/clickbias.py, positive control: shifting the clicks +25 ms moves the
    # answer +24.4 ms). So the SOUND lands about +17.5 ms after the score and the
    # picture is delayed to meet it. ⚠ The 16.7 ms is calibrated on instant
    # attacks; on a soft-attack instrument it is not the same number, which is
    # why this is per-film and not a constant. A clarinet line measured +40.2 ms
    # on the same rig.
    "vizLagMs": 17.5, "zPerGap": 0.45,
    # ⭐ CAMERA KEYFRAMES. Parametrised as the shot is framed — height above the
    # paper, distance behind the light, pitch, yaw, field of view — so "pull back
    # and drift left" is four numbers and not two interpolated 3-vectors. Linear
    # in time, smoothstepped between keys. This exists to SHOW the move; a real
    # film would use it far more sparingly.
    # ROUND 2 NOTE 2: wider and farther back, so more of the road, more balls
    # and more noteheads are in frame at once -- and so the tall arcs the
    # constant-g physics now produces have somewhere to go.
    # The drift is deliberately SLOW and continuous (note 5): the camera never
    # holds and never snaps, and because it advances linearly in t it always
    # sits on the sounding position.
    # ⛔ ROUND 3: REBUILT FROM THE ACTUAL REFERENCE, not from thumbnails.
    # music-visualizer.mov is a LOW, RAKING, CLOSE view across a nearly-flat
    # sheet: the staff runs lower-left to upper-right, the camera sits about a
    # hand's height above the paper, and several staff systems are in shot.
    # It is NOT a highway receding to a vanishing point up the middle, which is
    # what rounds 1-2 built. yaw carries the road diagonally across the frame.
    # ⭐⭐ ROUND 4: THREE ROADS, LAID OUT AS BANDS ACROSS x.
    # A score page stacks staves; this page lies flat with z = time, so the
    # staves stack sideways and recede together as ONE sheet. Order is by
    # PROMINENCE, not by engraving convention: the camera sits on the -x side,
    # so the road nearest it renders largest, and that is where the melody
    # belongs. Bass next. Percussion farthest and thinnest -- a 1-line staff,
    # which is what a percussion staff actually is.
    # ⚠ THE BANDS MUST NOT OVERLAP and every note must fall inside its own
    # band; lib/marks.mjs asserts both, and a --cross-road control proves it
    # reddens. Bands, with halfW:
    #     Piano [-1.72, -0.48]   Bass [-0.22, +0.82]   Perc [+1.13, +1.97]
    # ⚠ THE SPREAD IS NOT FREE COMPOSITION: lit fraction is driven by HOW MUCH
    # PAPER IS IN FRAME (measured twice now — round 3's UMAX experiment and
    # round 4's narrowing, which dropped the median from .318 to .071). Roads
    # tight enough to read as one system, wide enough to fill a 16:9 frame.
    "percRoadName": "Perc", "percRoadX0": 1.55,
    "percRoadLines": 1, "percRoadHalfW": 0.42,
    # ⭐ THE FRAME IS AN ARGUMENT. Same song, same physics, same look; only the
    # size and the camera differ. Landscape is the primary deliverable -- three
    # roads spread ACROSS the frame, which is the axis 16:9 has to spare and
    # 9:16 does not.
    # ⚠ `fov` IS VERTICAL in three.js, so the same number frames very
    # differently per aspect: at fov 42 landscape sees 68 deg horizontally and
    # the Short sees only 24. The Short therefore needs a much larger fov AND a
    # steeper yaw, so the roads run diagonally and borrow the tall axis.
    "formats": {
        # ⭐ MEASURED, NOT PREFERRED. Same scene, same lights, same layout, one
        # still at t=6.60, lit fraction (>0.12 grey):
        #     landscape  63-65 %  (median .302-.318)   4 cameras swept
        #     short      54-56 %  (median .267-.286)   9 cameras swept
        # The Short is pinned at ~56 % however it is framed: 9:16 gives a third
        # of the horizontal angle for the same fov, so either the roads leave
        # frame or the paper does. The gap to the reference band (67-77 %) is
        # therefore mostly FRAMING, exactly as predicted -- and it is not a
        # lighting problem to be tuned away.
        "landscape": {
            "width": 1920, "height": 1080,
            "camera": [
                {"t": 0.0,  "h": 1.15, "back": 3.10, "pitch": -14.0, "yaw": 21.0, "x": -1.50, "fov": 40},
                {"t": 6.5,  "h": 1.22, "back": 3.26, "pitch": -14.6, "yaw": 21.8, "x": -1.56, "fov": 40.6},
                {"t": 13.8, "h": 1.32, "back": 3.48, "pitch": -15.4, "yaw": 22.8, "x": -1.63, "fov": 41.4},
            ],
            # ⭐⭐ THE REVERSE ANGLE, as a NAMED TAKE against the SAME
            # performance. User: "even go in front and show how the playing
            # disks approach as we move camera back." The camera gets ahead of
            # the playhead, faces back down the road, and retreats.
            # ⚠ `rate` IS THE SHOT. zps here is 1.80 u/s. At rate == 1.80 the
            # gap never changes and the frame is static and dead; below it the
            # disks close on the lens, grow, and eventually pass. Two variants
            # are rendered as ladder rungs because that difference is entirely
            # this one number and the pick is the user's.
            # ⚠ FACING BACK PUTS THE ROAD AHEAD BEHIND THE CAMERA, so `high`
            # trades a steeper pitch for keeping the upcoming road in shot.
            "takes": {
                "approach": {"kind": "approach", "gap0": 2.8, "rate": 1.30,
                             "gapMin": 0.55, "cullNear": 0.22, "h": 1.35, "pitch": -26.0,
                             "yaw": 0.0, "x": 0.05, "fov": 46, "followX": 0.35},
                "approach-high": {"kind": "approach", "gap0": 3.2, "rate": 1.30,
                                  "gapMin": 0.70, "cullNear": 0.22, "h": 2.35, "pitch": -30.0,
                                  "yaw": 0.0, "x": 0.05, "fov": 50, "followX": 0.30},
                # ⛔ THE REVERSE ANGLE FAILS THE BLOOM GATE AND THIS IS WHY.
                # Facing the playheads head-on puts their halos straight down
                # the lens instead of edge-on, and `gapMin` lets them pass
                # within half a unit of it: 20398 px of red-only clip at
                # t=11.50 against a 14500 ceiling, four blown blobs across the
                # bottom edge. Measured AFTER the cull fix -- before it there
                # were no playheads in this take at all, so every earlier bloom
                # number for an approach take was measured on a scene missing
                # its brightest objects and is void.
                # These two rungs move ONE thing each so the pick is the user's:
                # `approach-gap` holds the disks further off the lens, and
                # `approach-cool` leaves the framing alone and lowers the bloom.
                # ⭐⭐ TRACKING TAKES. User: "camera needs to move slower and track
                # position of playhead." The requirement inside that is that the
                # PLAYHEAD MUST NEVER LEAVE FRAME, and framing.mjs gates exactly
                # that. "Move slower" is ambiguous -- a slower constant recede
                # makes the escape WORSE -- so it is not guessed: three rungs
                # differ on ONE axis, how tightly the camera is glued to the
                # playhead, and the user's pick is the answer.
                # ⛔⛔ ROUND 7: THE TRACKING-MODE AXIS IS RETIRED. The three rungs
                # tight/loose/eased shipped in r9 and the user could not tell them
                # apart: "tight, loose, or eased - kind of the same, better in a
                # sense that camera holds the playheads in view."
                # ⭐ SO THE REQUIREMENT, NOT THE TUNING, WAS THE POINT -- and the
                # requirement is exactly what framing.mjs asserts and what its
                # --fixedrate control fails at 75.9 %. The GATE is the spec now;
                # the constants under it are free. `track-loose` and `track-eased`
                # are DELETED, not commented out, so nobody re-litigates an axis
                # the user has already said is invisible.
                # ⭐ GENERAL: before shipping rungs, ask whether the axis is one
                # the user could plausibly SEE. An indistinguishable ladder is
                # worse than wasted render time -- it asks for a choice with no
                # content in it.
                # `track` is the surviving mode (r9's `track-tight` verbatim).
                "track": {"kind": "approach", "track": 1, "gap": 1.55,
                          "cullNear": 0.22, "h": 1.30, "pitch": -25.0,
                          "yaw": 0.0, "x": 0.05, "fov": 46, "followX": 0.45},
                # ⭐⭐ ROUND 7 ITEM 2 -- CAMERA DISTANCE, THE ONE AXIS THAT MOVED.
                # User: "we need the camera a little more back to show more space
                # in front". These three differ in `gap` ALONE (and the height it
                # takes to keep the same pitch reading the road) -- tracking
                # behaviour, fov, followX and cullNear are identical to `track`,
                # so the ladder measures distance and nothing else.
                "back-1": {"kind": "approach", "track": 1, "gap": 2.60,
                           "cullNear": 0.22, "h": 1.30, "pitch": -25.0,
                           "yaw": 0.0, "x": 0.05, "fov": 46, "followX": 0.45},
                "back-2": {"kind": "approach", "track": 1, "gap": 3.70,
                           "cullNear": 0.22, "h": 1.30, "pitch": -25.0,
                           "yaw": 0.0, "x": 0.05, "fov": 46, "followX": 0.45},
                "back-3": {"kind": "approach", "track": 1, "gap": 5.00,
                           "cullNear": 0.22, "h": 1.30, "pitch": -25.0,
                           "yaw": 0.0, "x": 0.05, "fov": 46, "followX": 0.45},
                # ⭐⭐⭐ ROUND 7 ITEM 5 -- THE SIDE-CROSSING TAKE. User: "a variant
                # with camera view tracking playheads on the side, going with them
                # and then fly over to the other side and tracking from there".
                # crossT is MEASURED, not chosen: the largest inter-onset gap in
                # this piece is 1.000 s beginning at t=8.0175, which is also a
                # heavy bar line. The move starts there and lives entirely inside
                # the sparsest passage.
                # ⚠ side/fov/h/aimAhead ARE THE FRAMING GATE'S ANSWER, not a taste
                # call. The first cut (side 2.7, fov 44) FAILED framing at 8.4 %,
                # with the offenders at n=0-2: from x=-2.7 the far Perc road at
                # x=+1.55 projects off the right edge in the opening seconds.
                # MEASURED ladder against framing.mjs, 1002 playhead-frames:
                #     side 2.7 fov 44 -> 8.4 % out  FAIL
                #     side 3.6 fov 54 -> 4.6 % out  FAIL
                #     side 4.2 fov 58 -> 3.3 % out  ok   <- shipped
                # ⭐ ROUND 10: h 0.85 -> 1.23 (+45%). User: "we need to raise the camera at
                # 45% ... currently it is too close to the ground and hard to see all
                # playing heads." The REQUIREMENT inside that is legibility of every
                # playhead at once -- at the low angle the roads foreshorten into each
                # other and near heads occlude far ones -- so it is verified on that,
                # not on the number.
                # ⭐ ROUND 11: HIGHER AND FURTHER BACK on the START pose only. User: "make
                # camera starting higher and more back." The LAND pose is untouched --
                # they have not criticised it. "Higher and more back" is a direction
                # without a magnitude, so sideH/sideDist are laddered (side-a/b/c).
                # The standing reason still governs: all playheads legible at once.
                "side": {"kind": "side", "track": 1, "side": 4.2, "h": 1.23,
                         "crossT": 8.0175, "crossDur": 1.6, "crossLift": 2.10,
                         "lead": 0.35, "aimAhead": 1.4, "aimY": 0.06,
                # ⭐ ROUND 8: STARTS ON THE RIGHT and the fly-over goes 2x higher.
                # User: "better start from the right side, more natural to note
                # progression, and then camera should fly over the track at 2x
                # higher." startSide +1 puts the camera at x=+4.2 first, so the
                # crossing runs RIGHT TO LEFT; crossLift 1.05 -> 2.10 doubles the
                # apex so it reads as passing OVER the road, not sliding across.
                # ⚠ THE CROSSING MOMENT IS UNCHANGED (t=8.0175, the largest
                # inter-onset gap and a heavy bar line) -- that was measured and
                # is not to be disturbed.
                # ⚠ AND STARTING ON THE OTHER SIDE INVERTS THE LABEL CONDITION
                # that labelFlip:"x" was written for. Re-opened after the
                # crossing and READ, not reasoned about.
                         "cullNear": 0.18, "fov": 58, "followX": 1.0,
                         "startSide": 1},
                "approach-gap": {"kind": "approach", "gap0": 3.0, "rate": 1.30,
                                 "gapMin": 1.35, "cullNear": 0.9, "h": 1.35, "pitch": -26.0,
                                 "yaw": 0.0, "x": 0.05, "fov": 46, "followX": 0.35},
                "approach-slow": {"kind": "approach", "gap0": 2.8, "rate": 0.85,
                                  "gapMin": 0.45, "cullNear": 0.18, "h": 1.35, "pitch": -26.0,
                                  "yaw": 0.0, "x": 0.05, "fov": 46, "followX": 0.35},
            },
        },
        # ⚠ THE SHORT IS NOT THE LANDSCAPE CAMERA IN A TALL FRAME. It needs a
        # much steeper yaw (45 deg vs 21) so the roads run DIAGONALLY and borrow
        # the tall axis, plus a wider fov and more distance to fit three bands
        # into a third of the horizontal angle.
        "short": {
            "width": 1080, "height": 1920,
            # ⛔ THE FIRST SHORT CAMERA (yaw 45, fov 70, x -1.95, back 4.60) LOST
            # THE MELODY. It looked fine at 6.60 s and it is not: swept across the
            # piece, 8 of 21 (road, time) samples had a road's band projected
            # entirely OFF SCREEN, and at t=11.02 the piano band sat at
            # x=[-513,-108] with nothing of it in frame. A 45 deg yaw points the
            # camera away from the road nearest it. Found by lib/roadpix.mjs, and
            # only because that check reports BROKEN rather than guessing: argmax
            # had cheerfully returned an unrelated paper highlight at x=306 and
            # the first cut called it "the melody on the wrong staff".
            # This one is 0 of 21 off-screen with a +40 px worst-case margin, i.e.
            # every road fully inside the frame for the whole piece.
            "camera": [
            # ⭐⭐ ROUND 8: ITS OWN CAMERA, ON THE RIGHT, AND FURTHER BEHIND.
            # User: "short is also better to track from right side a little
            # behind." The camera was on the LEFT (x -1.15, yaw +16); it is now
            # mirrored to the right and pulled back, and the pitch/height follow
            # so the 9:16 shape is filled by the road rather than by black.
            # ⚠ MIRRORED, NOT NUDGED: x and yaw both change sign together. A
            # right-side camera with the old positive yaw would point AWAY from
            # the road, which is exactly the failure roadpix caught on the first
            # short camera (8 of 21 road bands entirely off screen).
            # ⭐ ROUND 10: FARTHER RIGHT, HEIGHT HELD. User: "short has a nice
            # height, but we need to move camera farther to the right but not as
            # far as it would become side view." So h/back/pitch/fov are FROZEN at
            # the values they approved and only x and yaw move -- and they move
            # TOGETHER, because a right-side camera with the wrong-sign yaw points
            # off the road (the failure roadpix caught on the first short camera).
            # "Not as far as side view" is an edge defined by negation, so it is
            # laddered: right-1/-2/-3 below, and the user's pick is the answer.
                {"t": 0.0,  "h": 1.72, "back": 4.35, "pitch": -19.5, "yaw": -16.0, "x": 1.15, "fov": 80},
                {"t": 6.5,  "h": 1.80, "back": 4.55, "pitch": -20.1, "yaw": -16.6, "x": 1.20, "fov": 80.6},
                {"t": 13.8, "h": 1.90, "back": 4.80, "pitch": -20.9, "yaw": -17.4, "x": 1.26, "fov": 81.4},
            ],
            "takes": {
                "approach": {"kind": "approach", "gap0": 2.4, "rate": 1.30,
                             "gapMin": 0.50, "cullNear": 0.22, "h": 1.75, "pitch": -20.0,
                             "yaw": 0.0, "x": -0.75, "fov": 78, "followX": 0.35},
            },
        },
    },
    "defaultFormat": "landscape",
    "look": {
        # ⭐ ROUND 7 ITEM 4 -- GLOW DOWN 30 %. User: "I think we need to reduce
        # glow 30%". "Glow" spans three knobs (bloomStrength, strikeEmissive, the
        # playhead core), so the reduction is applied to ONE named axis --
        # bloomStrength, which is what reads as global glow -- and the parameter
        # is named in the report rather than left to inference.
        # 0.45 -> 0.315 is exactly 0.70x. Judged on the NEW light-grey ground,
        # not the old cream one: a darker world makes the same bloom read
        # brighter, so the 30 % was re-looked-at after the ground landed.
        # ⚠ strikeEmissive stays 2.8. The bloom gate is still superseded and is
        # NOT being re-introduced to justify this; this is the user tuning a look
        # they can now see.
        # ⭐⭐⭐ ROUND 7 -- THE WHOLE IMAGE COMES DOWN. User: "the videos were
        # too bright, we need to dim them down with grey and dark surfaces."
        # So the grey road and dark world are the MECHANISM for a dimmer image,
        # not a palette change, and dimmer is the target rather than a risk.
        # ⭐ AIMED AT THE REFERENCE LUMINANCE BAND, not at taste. The observer
        # measured the r8/r9 cuts OUTSIDE it on the bright side (median .310 vs
        # a .275 ceiling). MEASURED SWEEP on track t=6.60, exposure/overhead/
        # ambient moved together:
        #     0.85 / 0.95 / 0.55  -> median .357   (r9 look on the new ground)
        #     0.70 / 0.75 / 0.45  -> median .278   (still over the ceiling)
        #     0.60 / 0.62 / 0.38  -> median .227   ⭐ INSIDE .216-.275
        #     0.52 / 0.55 / 0.32  -> median .188   (under the floor)
        # r9 landscape for reference measured median .435 on the same frame.
        # ⛔ CORRECTED AFTER THE FIRST FULL BATCH: the sweep above was measured
        # on ONE FRAME (t=6.60) and it OVERSTATED the film. Whole-film medians at
        # 0.60/0.62/0.38, sampled 2 fps over each delivered mp4, came out UNDER
        # the .216-.275 band on every cut -- landscape .165, track .212 -- because
        # a film contains far more near-black frames than the frame I tuned on.
        # ⭐ A SINGLE-FRAME CALIBRATION IS NOT A FILM CALIBRATION. Re-aimed at
        # 0.70/0.75/0.45, which measured .278 on that same frame.
        "exposure": 0.70, "ambient": 0.45,
        "camFollowX": 0, "overhead": 0.75, "bloomStrength": 0.315,
        "bloomThreshold": 0.88, "lightPower": 0.16, "halo": 0.13, "halo2": 0.26,
        # TERM 1 — ILLUMINATION: the moving ball as a real light. Falls off with
        # distance, sums across balls, gone when the ball is gone.
        "decay": 2.0, "lightDist": 6, "coreR": 0.014, "drumCoreR": 0.022,
        # TERM 2 — RESIDUAL EMISSION: the struck note's OWN glow, on its own
        # clock, owing nothing to where the ball went. A flare on contact, then
        # a slow decay. ⚠ NEVER raise `lightDist` to fake this — that lights the
        # whole sheet and undoes the lit-fraction work.
        "afterFlash": 1.8, "afterFlashTau": 0.10,
        # ⭐ ROUND 6. The user: "the note disks are black, but they stay lighted
        # not fully decaying and decay should happen faster". 1.6 measured a 26 %
        # RESIDUAL at the note's last visible frame (afterglow.mjs); the disk was
        # still a quarter lit when it left the shot, and forty of those stack up
        # down the road. 0.65 brings it under the gate. Laddered -- the SPEED is
        # the user's pick; reaching zero is not optional in any of them.
        # ⭐ MEASURED, not chosen. afterglow.mjs samples the disk at its LAST
        # VISIBLE FRAME (0.80 s after the strike -- the road carries it out of
        # shot by then) against THE SAME DISK in the same pixels with the glow
        # switched off, and reports the residual as a fraction of that baseline:
        #     afterDecay 0.65 -> 49.2 %      0.45 -> 22.3 %
        #                0.30 ->  7.6 %      0.20 ->  1.8 %
        # A clean monotone curve, so the 14 % limit lands between 0.45 and 0.30.
        # 0.32 is the fastest value that still reads as a FADE rather than a
        # blink. The SPEED is laddered; reaching zero is not optional in any rung.
        "afterDecay": 0.32,
        "afterGain": 1.0, "afterSize": 0.30, "afterPool": 128,
        # ⭐ ROUND 5: the struck note's glow is now the note DISK's own
        # emissive, through the bloom pass -- not a sprite hovering over it.
        # ⭐ RESTORED. 2.8 -> 1.5 was a trade I made against the bloom gate, which is
        # now superseded (see framegate.py). The user asked for the flare by name.
        "strikeEmissive": 2.8,
        # ⭐ ROUND 5, BUCKET A: the sheet as geometry. noteH is the disk's
        # THICKNESS -- the "volume" the user asked for; sheetLineH/W are the
        # staff and bar lines, which are extruded boxes now, not painted.
        # ⭐ THINNER, on the user's ask. 0.026 -> 0.016.
        "noteH": 0.016, "sheetLineH": 0.007, "sheetLineW": 0.009,
        # the paper and the staff lines run PAST the music at both ends, so no
        # frame ever contains the sheet's own cut edge -- see road.html.
        "sheetPad": 7.0,
        "percR": 0.62, "percEmissive": 0.16, "labelW": 0.95, "roadLabels": 1,
        # ⭐ ROUND 5, BUCKET D: the playhead is a flat disk of the same family.
        "playR": 0.060,
        # ⛔ ROUND 5, BUCKET B2: the spawn contract. A ball is on screen for
        # spawnLead seconds (0.75 s = 1.5 beats at 120) before its first note,
        # flying in from behind and above and DECELERATING into it, arriving
        # dim. See road.html for why this is a Hermite and not an ease.
        # ⛔⛔⛔ ROUND 7b: THE BALLS WERE VISIBLE PARKED IN THE VOID BESIDE THE
        # ROAD. Suppressing the comet ribbon on the spawn removed the tubes the
        # user complained about and left the UNDERLYING defect visible: two
        # glowing pucks hovering in black space, which is the user's original
        # "balls appear out of nowhere", exactly.
        # ⭐ THE SPAWN START WAS A FIXED WORLD OFFSET THAT HAPPENED TO SIT OFF
        # THE ROAD: p0 = p1 + (0.22 dx, 1.45 up, +3.1 back). +z is BEHIND, so on
        # the reverse tracking take that put the start in the far distance, in
        # frame, in the dark.
        # ⭐ NOW IT STARTS BEYOND THE FAR END OF THE ROAD AND FLIES IN ALONG IT:
        # dx 0 (in the lane), up 0.10 (just clear of the surface, never in the
        # sky), back -9.0 (nine units DOWN the road, out past the fog). The first
        # thing the viewer sees is motion toward the note, and on the reverse
        # take the start is behind the camera entirely.
        # ⚠ IT MUST STAY CAMERA-INDEPENDENT. Aiming p0 at the frustum would have
        # been easier and would have broken perfcam's invariant -- the
        # performance is identical in every take, and a camera-dependent spawn
        # path is a performance that differs per take.
        # MEASURED, reviewer's own void box (x>1305, y<302), track t=7.60:
        #     old spawn -> 234 px >= 200, max 205
        #     new spawn ->   0 px >= 200, max  58
        # ⛔⛔⛔⛔ FOURTH DISTINCT FORM OF THE SAME DEFECT. Round 7b's -9.0 put the
        # start NINE UNITS ALONG THE DIRECTION OF TRAVEL, so the ball flew back
        # UP the road against everything else. User: "the new light flew in from
        # the opposite side of the movement". z = -t*zps, so flow is toward -z;
        # a start at p1.z - 9 must travel +z to reach its note, i.e. INTO the
        # oncoming traffic.
        # ⭐ THE SIGN IS THE WHOLE FIX: +12.0 starts it far BEHIND and it travels
        # WITH the flow, arriving at the note from up-road exactly as the music
        # does. On the reverse/tracking cameras that is far away and small and
        # fogged, growing as it comes -- "appear far away ... join the movement".
        # ⭐ AND IT NEEDS TIME TO TRAVEL: spawnLead 0.75 -> 2.20 s, so the ball is
        # visibly moving for ~66 frames before its note instead of fading up next
        # to it. The user asked for exactly this: "they should appear long before
        # the actual target note is reached so they have time to reach".
        # ⚠ THE FOUR FORMS, so nobody re-solves this piecemeal a fifth time:
        #   (1) a one-frame brightness pop        (2) a full-width ribbon drawn
        #   up the spawn arc into the sky         (3) a light hovering stationary
        #   in the void                           (4) a ball flying against the
        #   flow. Each fix removed its own symptom and exposed the next. The
        #   entry now has ASSERTIONS (entry.mjs (D)/(E)), not just a value.
        "spawnLead": 2.20, "spawnUp": 0.10, "spawnBack": 12.0,
        "spawnDx": 0.0, "spawnV0": 1.0, "spawnEnv": 0.42,
        # THE TRAIL: must still be attached to note N-1 when the ball reaches
        # note N. Needs all four — a lit tail, a shallow falloff, a tail that
        # keeps its width, and a lifetime longer than the gap it spans.
        # ⛔ ROUND 5, BUCKET B1 -- THE TAIL DID NOT FADE, AND IT WAS MY DOING.
        # Round 4 took the brightness from `along^2` (exactly zero at the tail)
        # to arcTailGain 0.55 + falloff 1.2, which is very nearly a ribbon of
        # EVEN brightness end to end. The user: "the tail glow now does not
        # fade, probably because you re-draw pictures or something like that."
        # ⭐ THE ACCUMULATION HALF OF THAT HYPOTHESIS IS SETTLED NEGATIVE: the
        # arcs are disposed and rebuilt every frame (road.html empties arcGroup
        # with geometry.dispose()/material.dispose() before rebuilding), so
        # nothing is piling up. It was the gradient, flattened by me.
        # The tail now has a FLOOR, not a zero and not a one: bright at the
        # head, ~0.30 at the previous notehead, so it still REACHES the note it
        # is supposed to touch while visibly falling off along its length --
        # and it tapers in THICKNESS on the same curve, which is the user's
        # round-5 note: "fade in light and thickness as it fades".
        # ⛔ THE ARC PARAMETERS BELOW ARE DEAD. The trail is no longer built from
        # per-note arcs at all -- see cometFor() in road.html. They are kept for one
        # release only so an old payload does not error, and read by nothing.
        "arcTailGain": 0.30, "arcFalloff": 1.6, "arcTaper": 0.72,
        "arcDecay": 1.6, "arcJoinMax": 1.25, "arcHistory": 8, "arcGain": 1.5,
        # ⭐⭐ THE COMET. User: "like comets out with thick tails coming out of
        # disk (disk size) and narrowing to the end of the tail and there is no
        # end of the tail". cometHeadK 1.0 = the head is EXACTLY the playhead
        # disk's radius; width and alpha both reach exactly 0 at cometAge, so the
        # strip ends where it is already invisible.
        "cometAge": 1.15, "cometSegs": 44, "cometHeadK": 1.0,
        "cometWidthPow": 1.30, "cometAlphaPow": 1.70, "cometGain": 1.05,
        # ⭐ MATERIALS. Metal disks need something to reflect: see the
        # RoomEnvironment note in road.html -- without it they render dead black.
        "inkColor": 0x060606, "inkRough": 0.28, "inkMetal": 0.85, "inkEnv": 1.15,
        "lineRough": 0.42, "lineMetal": 0.55, "noteBevel": 0.26, "lineBevel": 0.30,
        "paperNormK": 0.55, "paperRough": 0.99, "paperRepU": 6, "paperRepV": 90,
        # ⭐ DRUM HOLES, replacing the falling balls (a REVERSAL -- see NOTES).
        "drumHoles": 1, "holeR": 0.78, "holeDepth": 0.42, "holeSegs": 22,
        "holeWallColor": 0x6b5a44, "holeWallMetal": 0.35, "holeWallEnv": 0.6,
        # ⛔⛔ AND A SECOND LIGHT IN THE VOID, WHICH WAS NOT A SPAWN AT ALL.
        # After the spawn fix the LANDSCAPE take still had an oval hanging in the
        # black at upper right. Removing the spawn did not remove it; removing
        # the drums did not remove it either (drumPower 0 kills the light, not
        # the emissive disk). Identified by querying the frame's own state rather
        # than by guessing: `{"kind":"drum","i":14,"y":1.1799,"sx":1681,"sy":178}`
        # -- a drum disk that had leapt 1.18 units into the SKY.
        # ⭐ Apex is drumLeap^2 * G * (...)^2 / 2, so 0.72 -> 0.40 cuts it by
        # ~0.31x. The disk still visibly comes OUT of its hole with the opening
        # under it (opened at t=4.12); it no longer flies off the road.
        # After: void box max 13, 0 px >= 200, and the state query returns EMPTY.
        # ⛔⛔⛔ REVERTED TO 0.72 IN ROUND 8, AND THE REVERT IS THE POINT.
        # In round 7b I lowered this 0.72 -> 0.40 because a drum disk at y=1.18
        # was the "light hanging in the void" on the landscape take. THE
        # IDENTIFICATION WAS RIGHT AND THE FIX WAS WRONG: the user then said of
        # the r13 cuts, which shipped 0.72, "on other videos drums are very
        # good." A disk clearly airborne above the road IS the leap they asked
        # for -- "light disks should jump out of them on beat" -- and dropping
        # the apex to keep it off the sky would have quietly removed the feature
        # from every cut they just praised.
        # ⚠ THIS IS THE SECOND TIME THIS PROJECT HAS NEARLY RE-TUNED WORKING
        # PERCUSSION. Round 5 recorded "drums/kick are pefect!" and round 6
        # reversed it on a direct instruction; nothing here is a licence to
        # adjust the leap on my own reading of a frame.
        # THE REAL DEFECT WAS FRAMING: the user's "no drums jumping out of the
        # holes, they appear somewhere high and not visible" is about `track`
        # ALONE -- the CLOSE camera -- and the apex simply leaves the top of the
        # shot at that distance. It is fixed by retiring the close framing, not
        # by lowering the leap.
        "drumCoreR": 0.030, "drumLeap": 0.72, "drumRestK": 0.55,
        "drumRestGlow": 0.22, "drumFade": 0.34,
        "trackSmooth": 0.55,
        "roadLabels": 1,
    },
    "tempoSegments": [{"startBeat": 0, "bpm": BPM}],
    "beatsPerBar": 4, "lengthBeats": LEN,
    "renderSeconds": round(LEN * 60 / BPM + 1.8, 2),
    "buses": [{"name": "Air", "volume": 0.95,
               "fx": [{"kind": "reverb", "params": {"roomSize": 0.78, "damping": 0.32,
                                                    "mix": 1.0, "preDelayMs": 26, "width": 1.0}}]}],
    "master": {"volume": 1.0, "fx": [
        {"kind": "gain", "index": 0, "params": {"gainLinear": 1.5}},
        {"kind": "limiter", "params": {"ceilingDb": -1.2, "releaseMs": 90, "truePeak": 1}}]},
    "tracks": [
        {"name": "Piano", "label": "Piano", "program": 0, "road": True,
         "roadX0": -1.10, "roadHalfW": 0.62, "roadBottomPitch": 62,
         "color": "#FFC46B", "volume": 0.88, "pan": 0.0,
         "send": {"bus": "Air", "level": 0.24}, "notes": mel},
        # ⚠ BASS WAS NOT A ROAD UNTIL NOW, so its pitches had never been through
        # the diatonic staff mapping (which THROWS on a non-scale pitch).
        # Checked first: 36/38/41/43 are C, D, F, G — all in C major.
        # ⚠ AND ITS COLOUR WAS #3E4C63, a blue-grey. The reference is warm for
        # its whole length and "no blue" is an explicit constraint, so a road
        # painted with it would have broken the rule on the first frame.
        # ⭐ ITS OWN CLEF ORIGIN: bottom line A1 (33) puts 36..43 on steps 2..6,
        # centred on its five lines. Through the piano road's origin (62) the
        # same notes land fifteen steps below the staff — a real notehead in a
        # real place on the wrong road, which is the failure the gate catches.
        {"name": "Bass", "label": "Bass", "program": 33, "road": True,
         "roadX0": 0.30, "roadHalfW": 0.52, "roadBottomPitch": 33,
         "color": "#FFB45A", "volume": 0.62, "pan": 0.0,
         "send": {"bus": "Air", "level": 0.12}, "notes": bass},
        {"name": "Taiko", "label": "Taiko", "program": 116, "roadDrum": True,
         "drumLanes": {"45": -0.20}, "color": "#FFA24B", "volume": 0.60, "pan": -0.12,
         "send": {"bus": "Air", "level": 0.20}, "notes": taiko},
        {"name": "Woodblock", "label": "Woodblock", "program": 115, "roadDrum": True,
         "drumLanes": {"76": 0.20}, "color": "#FFD08A", "volume": 0.42, "pan": 0.16,
         "send": {"bus": "Air", "level": 0.18}, "notes": wood},
    ],
}
write(song, os.path.join(os.path.dirname(os.path.abspath(__file__)), "song.json"))
