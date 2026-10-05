#!/bin/bash
# MOONLIGHT, THE SIDE VIEW (bars 1-42) — a second camera on the same film.
# ⛔⛔ `D` IS THIS DIRECTORY AND NOTHING ELSE. Two files in this tree were copied
# from a sibling with `D` still pointing at the approved 02-moonlight; if you copy
# this one, the FIRST edit is D.
# ⭐ IT REUSES 03's AUDIO. The notes are identical, so music.wav and
# build-facts.json are copied in once and PICTURE_ONLY=1 is the only supported
# mode here — this script never contacts the DAW at all.
set -euo pipefail
D=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads/05-moonlight-side
S=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads/03-moonlight-long
R=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads
PY=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python
export DAW_CONTROL_PORT=17695          # ⛔ NEVER 17600 — that is the user's live app
# ⚠ 30 s IS dawctl.mjs's DEFAULT AND A 182 s OFFLINE RENDER IS NOT A 30 s CALL.
# The first attempt at this film's audio died with
# "render.measureLoudness: no reply in 30000ms" — the render was fine, the client
# gave up. Exported here so the next long span does not rediscover it.
export DAW_TIMEOUT_MS=${DAW_TIMEOUT_MS:-900000}
# ⭐ THE SIDE CUT. Same 42 bars, same audio, same eight windows and the same
# seven measured transitions — only the shot TYPES differ, side all the way,
# crossing over the top to the LEFT for the middle of the piece and back for the
# descent. Asked for by the user by name. song.py, ly2notes.py and source/ are
# SHARED with 03; only the camera, the output directory and the id are here.
export MOON_CAM=side MOON_OUTDIR="$D" MOON_ID=moonlight-side
FMT=${FMT:-landscape}
# ⭐ PICTURE_ONLY=1 re-renders the FILM from the audio that is already on disk.
# The re-entry fix and the camera fit are picture-side changes; re-cutting a take
# through the DAW to change nothing about the music would be churn on staging,
# and would re-mint every track/clip id in build-facts.json for no reason.
# ⚠ It is only correct while song.py's NOTES are unchanged — the pin below is
# what makes that a check rather than a hope.
# ⛔ THIS CUT HAS NO DAW PATH. Its notes are 03's notes and its audio is 03's
# audio; re-cutting the take would only re-mint ids and risk a second, subtly
# different master of the same music. Refused loudly rather than left as a note.
if [ "${PICTURE_ONLY:-0}" != 1 ]; then
  echo "[FAIL] 05-moonlight-side is PICTURE_ONLY=1 only — its audio is 03's." >&2
  exit 2
fi
if false; then
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
node "$R/lib/reentry.mjs" "$D/out/payload.json"
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
# ⚠ CRF 12, NOT 19, AND THE REASON IS MEASURED. This film's master is uploaded to
# a platform that RE-ENCODES it, so the master's job is to give that encoder
# headroom, not to be small. The shipped 71,582,680 B master was produced by a
# hand-run encode in this CRF class; the scripted line said 19, which lands the
# same picture at 26,432,423 B (924 kbps). Measured on the SAME frames, 30 s
# excerpts extrapolated: crf 19 -> 24.7 MB, 16 -> 37.5 MB, 14 -> 47.6 MB,
# 12 -> 64.6 MB. So the script and the artifact disagreed by 2.7x and nothing
# said so. ⭐ The picture is IDENTICAL either way — crf 19 measures PSNR 46.5 dB
# average / 44.8 dB min against its own source PNGs — this is purely about what
# YouTube's transcoder is handed.
# ⭐ The under-30-MiB copy the user can actually send is a SEPARATE, clearly named
# file (out/moonlight-side-preview.mp4), never this one.
ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$D/out/frames/f%06d.png" \
  -vf setsar=1 -c:v libx264 -preset medium -crf 12 -pix_fmt yuv420p -r 30 "$D/out/picture.mp4"
# ⚠ apad, THEN -shortest. Without apad the audio (182.4 s) is the shorter stream
# and -shortest would cut the picture — taking the END CARD with it. With apad the
# audio runs forever and -shortest lands on the PICTURE's length, which is what we
# want. A bare -shortest here silently ships a film with no credit on it and
# nothing downstream would say so.
ffmpeg -hide_banner -loglevel error -y -i "$D/out/picture.mp4" -i "$D/out/music.wav" \
  -c:v copy -af "aresample=48000,aformat=channel_layouts=stereo,apad" -c:a aac -b:a 192k \
  -shortest "$D/out/moonlight-side.mp4"
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$D/out/moonlight-side.mp4")
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
$PY "$R/../tunes/lib/sync.py" "$D/out/moonlight-side.mp4" "$D/song.json" --roads --lead "$LEAD"
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
  -shortest "$D/out/moonlight-side-preview.mp4"
rm -f "$D/out/_pv"*.log "$D/out/_pv"*.log.mbtree
PVB=$(stat -f%z "$D/out/moonlight-side-preview.mp4")
PVD=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$D/out/moonlight-side-preview.mp4")
$PY -c "
import sys
b=int(sys.argv[1]); d=float(sys.argv[2]); w=float(sys.argv[3]); L=31457280
if b >= L: sys.exit(f'[FAIL] preview {b} B is NOT under the {L} B (30 MiB) limit')
if d < w - 0.5: sys.exit(f'[FAIL] preview {d}s is short of the {w}s master')
print(f'  [pin] preview {b} B ({b/1048576:.1f} MiB) < 30 MiB, {d}s')" "$PVB" "$PVD" "$PSECS"
echo "-> $D/out/moonlight-side-preview.mp4   (PREVIEW — for sending; do NOT upload)"
echo "-> $D/out/moonlight-side.mp4"
