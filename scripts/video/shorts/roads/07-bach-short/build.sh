#!/bin/bash
# ⭐ 07 — THE VERTICAL SHORT of BWV 846: bars 1-11, portrait, on `short-right1`.
#
# ⛔⛔ `D` IS THIS DIRECTORY AND NOTHING ELSE. This file was copied from
# 06-bach-prelude/build.sh, whose own header records that ITS ancestor still
# pointed at 02-moonlight and would have overwritten an approved film. The FIRST
# edit made here was `D`. Verified before any invocation: nothing below resolves
# into 06-bach-prelude except READS of the shared song.py/derive.py/source.
#
# ⭐ IT SHARES 06's song.py, bach_gt.py, derive.py, ly2notes.py AND source/ RATHER
# THAN COPYING THEM — the cut is ENVIRONMENT (BACH_CAM/BACH_BARS/BACH_OUTDIR/
# BACH_ID), exactly as 04 and 05 share 03's. A second copy of the parser is a
# second thing to keep in sync and the first thing to rot; round 31's bar-33
# error was a typed number in a file that now has one home for that reason.
# ⛔ THE APPROVED 35-BAR FILM IS PINNED BY md5 AGAINST EVERY EDIT TO song.py:
#   BACH_OUTDIR=<scratch> song.py  ->  9cbfee9128e6f7bba525c558f0b1b0da
#
# ⭐⭐ WHY BARS 1-11 — a Short is not the first N seconds, and this piece gives no
# rest to end on: the figure runs unbroken sixteenths from bar 1 to bar 33, so
# the phrase boundary has to come from the HARMONY, and it is DERIVED rather than
# asserted (derive.py's SPAN block, run on this directory):
#  · the bass moves by fifths across bars 9-11 — A3(57) -> D3(50) -> G3(55) — a
#    three-bar chain that TERMINATES at bar 11 (bar 12 in the full score stays on
#    G, so the chain does not continue: bar 11 is its arrival).
#    ⚠ THE LAST STEP RISES A FOURTH, it does not fall a fifth. Same root motion;
#    requiring a FALL is exactly the bug that first measured this chain as one
#    bar long;
#  · bar 11 over that bass spells a plain G MAJOR triad in root position — the
#    half-cadence on the dominant, the first structural arrival in the piece;
#  · it opens at bar 1, so the whole opening tonic span is there to set it up.
# It is therefore self-contained: departure, sequence, arrival.
# ⚠ WHAT THIS SPAN COSTS, STATED RATHER THAN BURIED: the excerpt STOPS the
# sixteenths at the bar line instead of letting them finish. See NOTES ROUND 32
# for the measured ending and the options — nothing is faded silently.
set -euo pipefail
D=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads/07-bach-short
R=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads
PY=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python
S=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads/06-bach-prelude
export BACH_CAM=short BACH_BARS=${BACH_BARS:-11} BACH_ID=bach-short
export BACH_OUTDIR="$D"
# ⛔ THE DOLLY IS RE-SOLVED FOR THIS SPAN AND THIS FRAME, NOT INHERITED.
# 04's header records what inheriting the landscape figure did to the
# Moonlight Short: the action occupied the bottom sixth of a 1080x1920 frame
# and framing.mjs passed it, because "in frame" and "worth looking at" are
# different questions. Laddered against framing.mjs at FRAMING_ALLOW=0 on
# THIS payload — see NOTES ROUND 32 for the table.
#   0.80 -> FAIL 1.3% of playhead-frames   1.00 -> FAIL 0.2%
#   1.05 -> ok   1.10 -> ok   1.15 -> ok   1.20 -> ok   1.30/1.40/1.50/2.20 -> ok
# The threshold is between 1.00 and 1.05, so 1.15 keeps the same ~+0.10 margin
# over the first passing rung that 04 keeps over its own.
# ⭐ AND IT WAS PICKED BY LOOKING, not only by the gate — stills at t=8 and t=24
# on 1.15 / 1.30 / 1.50 / 2.20: every one PASSES framing, and the action shrinks
# monotonically with the number. At 1.50 the three lamps sit in the lower third
# and the staves are thin; at 1.15 they fill the middle of a 1080x1920 frame.
# "In frame" and "worth looking at" are different questions — 04's own words.
export BACH_FIT_EXTRA=${BACH_FIT_EXTRA:-1.15}
export DAW_CONTROL_PORT=17695          # ⛔ NEVER 17600 — that is the user's live app
# ⚠ 30 s IS dawctl.mjs's DEFAULT AND A 182 s OFFLINE RENDER IS NOT A 30 s CALL.
# The first attempt at this film's audio died with
# "render.measureLoudness: no reply in 30000ms" — the render was fine, the client
# gave up. Exported here so the next long span does not rediscover it.
export DAW_TIMEOUT_MS=${DAW_TIMEOUT_MS:-900000}
FMT=${FMT:-short}
# ⭐ PICTURE_ONLY=1 re-renders the FILM from the audio that is already on disk.
# The re-entry fix and the camera fit are picture-side changes; re-cutting a take
# through the DAW to change nothing about the music would be churn on staging,
# and would re-mint every track/clip id in build-facts.json for no reason.
# ⚠ It is only correct while song.py's NOTES are unchanged — the pin below is
# what makes that a check rather than a hope.
if [ "${PICTURE_ONLY:-0}" != 1 ]; then
  $PY "$S/song.py"
  node "$R/../tunes/lib/build.mjs" "$D/song.json" "$D/out"
  node "$R/../tunes/lib/gain.mjs"  "$D/song.json" "$D/out" -14
else
  # ⛔⛔ PICTURE_ONLY USED TO SKIP song.py ENTIRELY, AND THAT SHIPPED A STALE
  # song.json. Measured, on this very Short: a re-derived end-card caption and a
  # re-laddered cameraFitExtra were both edited, the build was re-run with
  # PICTURE_ONLY=1, it printed every pin green — and the film still carried the
  # OLD caption ("bars 1-42" on a nine-bar cut) and the OLD dolly. The note-count
  # pin cannot see it: a caption and a camera change no note counts.
  # ⭐ PICTURE_ONLY MEANS "DO NOT TOUCH THE DAW", NOT "DO NOT RE-DERIVE THE SONG".
  # So song.py runs, and the pin below then compares the FRESH song.json against
  # the audio that is already on disk — which is a strictly stronger check than
  # before, because it now also catches a picture-only edit that accidentally
  # moved a note.
  $PY "$S/song.py"
  $PY - "$D/song.json" "$D/out/build-facts.json" <<'PIN'
import json, sys
song = json.load(open(sys.argv[1])); facts = json.load(open(sys.argv[2]))
have = {t["name"]: t["notes"] for t in facts["tracks"]}
want = {t["name"]: len(t["notes"]) for t in song["tracks"] if t.get("road") or t.get("roadDrum")}
if have != want:
    sys.exit(f"PICTURE_ONLY refused: song.json {want} does not match the rendered audio {have} — "
             "the music changed, so re-run without PICTURE_ONLY")
print(f"  [pin] PICTURE_ONLY: song.json notes match the rendered audio {have}")
PIN
fi
node "$R/lib/prep.mjs" "$D/song.json" --format "$FMT" --out "$D/out/payload.json"
# ⛔⛔ THE ONE REGRESSION NO GATE IN THIS PIPELINE CAN SEE. `coreSteady` defaults
# to 0 in road.html and 0 is a BYTE-IDENTICAL IDENTITY, so a payload that loses it
# renders a perfectly valid film with round 27's disk defect back in it and every
# other gate green. song.py asserts it in the SONG; this asserts it in the
# PAYLOAD, which is the object road.html actually reads — prep.mjs is a merge, and
# a merge is where a key goes missing.
$PY - "$D/out/payload.json" <<'CORE'
import json, sys
lk = json.load(open(sys.argv[1]))["look"]
want = {"coreSteady": 1, "coreGain": 0.30, "lampWhite": 0.38, "lightPower": 12.0,
        "lightDist": 22, "ambient": 0, "overhead": 0, "coolFill": 0,
        "lampLift": 1.55, "liftReach": 6.25, "groundExtent": 200}
bad = {k: (lk.get(k), v) for k, v in want.items() if lk.get(k) != v}
if bad: sys.exit(f"[FAIL] the frozen look did not survive prep.mjs: {bad}")
print(f"  [pin] frozen look intact in the payload (coreSteady {lk['coreSteady']}, "
      f"coreGain {lk['coreGain']}, lampWhite {lk['lampWhite']})")
CORE
SECS=$($PY -c "import json;print(json.load(open('$D/song.json'))['renderSeconds'])")
# ⭐ THE PICTURE IS LONGER THAN THE MUSIC, so the end card has somewhere to live.
# Keeping the two lengths separate is what stops -shortest from cutting the card
# off the end of the film; the AUDIO is padded to meet the picture instead.
PSECS=$($PY -c "import json;print(json.load(open('$D/song.json'))['pictureSeconds'])")
node "$R/lib/marks.mjs" "$D/out/payload.json"
# ⭐ THE GATES THAT CARRY THIS ROUND'S TWO FIXES, IN THE PIPELINE RATHER THAN RUN
# BY HAND. framing at ALLOW=0 is the acceptance test cameraFitExtra was SOLVED
# against — at the default 4 % tolerance it passed the broken framing too.
# ⚠ FRAMING_SECONDS, or the gate walks `total + coast` (182.02 s) and leaves the
# last ELEVEN frames of a 182.4 s film unexamined — the same shape as the round-7
# bug framing.mjs's own header records.
FRAMING_ALLOW=0 FRAMING_SECONDS="$PSECS" node "$R/lib/framing.mjs" "$D/out/payload.json"
# ⚠⚠ (R) reentry REPORTS BROKEN ON THIS PIECE AND EXITS 2, AND THAT IS THE
# HONEST ANSWER, NOT A PASS. Its question is "does a voice returning from a long
# rest fade in rather than switching on in place", and BWV 846 has no long rest
# in any voice: the figure's largest onset-to-onset gap is 0.750 s, the bass
# never stops, and the tenor's only hole is the written `r16` — 0.25 s, against
# the 1.84 s the OLD fade needed to put a light out. MEASURED both ways: with
# BACH_TENOR_HOLD=0 the premise still fails, so this is the PIECE, not the hold.
# ⛔ ITS EXIT 2 IS TOLERATED BY NAME, exactly as seam's and cull's are — and the
# first run of this script DIED HERE under `set -e` because that clause was
# missing. It printed BROKEN and stopped; an earlier by-hand check had reported
# "exit 0" because it was piped into `tail`, which is the failure this file's own
# header warns about, walked into once more.
node "$R/lib/reentry.mjs" "$D/out/payload.json" || [ $? = 2 ]
# ⭐ (L) THE LABELS MUST READ. Six orientation errors in this project, every one
# found by cropping a frame and looking; this is the first one that is asserted.
node "$R/lib/labels.mjs"  "$D/out/payload.json"
node "$R/lib/entry.mjs"   "$D/out/payload.json"
# ⚠ (S) seam: (S1)/(S2) are real verdicts here; (S3) reports BROKEN because on
# THIS film's camera 0.5 world units is only 13-18 px along the road, so it gets
# 0 usable pixel samples and refuses to give a verdict. A BROKEN probe must not
# redden a build — same contract as cull below, tolerated BY NAME and by exit
# code 2 only, so a real (S1) failure (exit 1) still stops the build.
# ⛔ WITHOUT THIS LINE THIS SCRIPT CANNOT COMPLETE. Measured 2026-09-07: a
# PICTURE_ONLY re-run died silently at seam under `set -e`, and because the run
# was piped into `tail -40` the wrapper reported the TAIL's exit 0. The film on
# disk was untouched and every visible sign said the build had succeeded. Do not
# pipe this script into tail.
node "$R/lib/seam.mjs"    "$D/out/payload.json" || [ $? = 2 ]
node "$R/lib/ribbon.mjs"  "$D/out/payload.json"
# ⚠ (C) cull: (C1) is a real verdict here (0 differing px, control fires); (C2)
# reports BROKEN because its comparator road is shorter than the cull radius. A
# BROKEN probe must not redden a build, so its exit 2 is tolerated BY NAME.
node "$R/lib/cull.mjs"    "$D/out/payload.json" || [ $? = 2 ]
rm -rf "$D/out/frames"
node "$R/lib/shoot.mjs" "$D/out/payload.json" "$D/out/frames" "$PSECS"
# ⭐ THE FRAME PIN, same contract as lib/r4.sh: a truncated picture must not ship
# green. Derived from renderSeconds x 30, never from what happens to be there.
WANT=$($PY -c "import sys;print(int(round(float(sys.argv[1])*30)))" "$PSECS")
GOT=$(ls "$D/out/frames" | grep -c '^f[0-9]*\.png$')
if [ "$GOT" -lt "$WANT" ]; then echo "[FAIL] frames $GOT / $WANT expected" >&2; exit 2; fi
echo "  [pin] frames $GOT / $WANT expected (pictureSeconds $PSECS x 30)"
# ⭐ STILLS == SEQUENCE. r4.sh has always run this; build.sh had not, and the
# repeating paper tile is a NEW init-time path that no determinism check had seen.
$PY "$R/lib/framegate.py" "$D/out/frames" "$D/out/payload.json"
# ⚠ CRF 15 HERE, NOT 12, AND THE NUMBER IS MEASURED ON THIS FILM'S OWN FRAMES.
# The master is uploaded to a platform that RE-ENCODES it, so its job is to give
# that encoder headroom, not to be small — which is why the landscape cuts use 12.
# But portrait 1080x1920 costs far more at the same CRF here. Measured on THIS
# directory's frames, a 300-frame (10 s) excerpt:
#   crf 12 -> 46,385,891 B · crf 15 -> 30,374,776 B · crf 19 -> 15,423,583 B.
# Linear extrapolation is an UPPER BOUND, not a prediction (it says 162 MB for
# crf 15 against an actual 136,497,067 B — the last 8 s is a static end card), so
# crf 12 would land this 53.2 s Short somewhere under 247 MB. ⭐ The check that
# JUSTIFIES it is BITRATE DENSITY, not CRF: at 15 this master is 136,497,067 B /
# 53.200 s = 2.57 MB/s, ABOVE the 08 landscape master's crf-12 density of
# 356,510,713 B / 149.200 s = 2.39 MB/s, at the identical pixels per frame. So
# crf 15 hands YouTube MORE data per frame here than crf 12 does there.
# ⭐ The under-30-MiB copy the user can actually send is a SEPARATE, clearly named
# file (out/bach-short-preview.mp4), never this one.
ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$D/out/frames/f%06d.png" \
  -vf setsar=1 -c:v libx264 -preset medium -crf 15 -pix_fmt yuv420p -r 30 "$D/out/picture.mp4"
# ⚠ apad, THEN -shortest. Without apad the audio (182.4 s) is the shorter stream
# and -shortest would cut the picture — taking the END CARD with it. With apad the
# audio runs forever and -shortest lands on the PICTURE's length, which is what we
# want. A bare -shortest here silently ships a film with no credit on it and
# nothing downstream would say so.
ffmpeg -hide_banner -loglevel error -y -i "$D/out/picture.mp4" -i "$D/out/music.wav" \
  -c:v copy -af "aresample=48000,aformat=channel_layouts=stereo,apad" -c:a aac -b:a 192k \
  -shortest "$D/out/bach-short.mp4"
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$D/out/bach-short.mp4")
$PY -c "
import sys; d=float(sys.argv[1]); w=float(sys.argv[2])
sys.exit(f'[FAIL] film {d}s is short of the {w}s asked for' if d < w - 0.5 else 0)" "$DUR" "$PSECS"
echo "  [pin] film duration ${DUR}s / ${PSECS}s asked for (music ${SECS}s + end card)"
# ⭐ A/V DRIFT. Every other gate here measures the PICTURE; this one decodes the
# film's own AUDIO and scores its onsets against the score. It is the only check
# whose failure mode GROWS WITH LENGTH, and it was missing from all three film
# builds while r4.sh ran it on a 14-second sample. Measured on the finished mux:
# long 94.1% matched / 2.4 ms drift, short 96.4% / 4.4 ms. Its own wrong-phase
# and random controls must fire or it reports BROKEN (exit 2).
# ⚠ THE LEAD IS DERIVED, NOT TYPED. `vizLagMs` is a standing open question in
# NOTES.md; a literal 0.0175 here would silently diverge from song.json the day
# it changes, and the gate would then measure the wrong thing while staying green.
LEAD=$($PY -c "import json,sys;print(json.load(open(sys.argv[1]))['vizLagMs']/1000.0)" "$D/song.json")
$PY "$R/../tunes/lib/sync.py" "$D/out/bach-short.mp4" "$D/song.json" --roads --lead "$LEAD"
# ⭐ THE PREVIEW — a SECOND file, never a replacement for the master.
# The master is ~65 MB and cannot be sent over a 30 MiB transfer limit, so the
# user cannot watch their own film away from this machine. This is a same-length,
# same-resolution, same-audio copy squeezed under that limit. It is NOT the
# upload: the master above is.
# ⚠ TWO-PASS with a hard -bufsize, not a CRF guess — CRF targets quality and its
# SIZE is whatever it turns out to be, which is exactly the thing that must be
# bounded here. The pin below then refuses to let a preview that missed the
# budget be reported as one.
PVBIT=980k
ffmpeg -hide_banner -loglevel error -y -i "$D/out/picture.mp4" \
  -c:v libx264 -preset medium -b:v $PVBIT -maxrate 1200k -bufsize 2400k \
  -pix_fmt yuv420p -pass 1 -passlogfile "$D/out/_pv" -an -f null /dev/null
ffmpeg -hide_banner -loglevel error -y -i "$D/out/picture.mp4" -i "$D/out/music.wav" \
  -c:v libx264 -preset medium -b:v $PVBIT -maxrate 1200k -bufsize 2400k \
  -pix_fmt yuv420p -pass 2 -passlogfile "$D/out/_pv" \
  -af "aresample=48000,aformat=channel_layouts=stereo,apad" -c:a aac -b:a 192k \
  -shortest "$D/out/bach-short-preview.mp4"
rm -f "$D/out/_pv"*.log "$D/out/_pv"*.log.mbtree
PVB=$(stat -f%z "$D/out/bach-short-preview.mp4")
PVD=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$D/out/bach-short-preview.mp4")
$PY -c "
import sys
b=int(sys.argv[1]); d=float(sys.argv[2]); w=float(sys.argv[3]); L=31457280
if b >= L: sys.exit(f'[FAIL] preview {b} B is NOT under the {L} B (30 MiB) limit')
if d < w - 0.5: sys.exit(f'[FAIL] preview {d}s is short of the {w}s master')
print(f'  [pin] preview {b} B ({b/1048576:.1f} MiB) < 30 MiB, {d}s')" "$PVB" "$PVD" "$PSECS"
echo "-> $D/out/bach-short-preview.mp4   (PREVIEW — for sending; do NOT upload)"
echo "-> $D/out/bach-short.mp4"
