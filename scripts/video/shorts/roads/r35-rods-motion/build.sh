#!/bin/bash
# ROUND 35 — the rods IN MOTION. Short clips of one identical window of
# 06-bach-prelude, one per variant, so they can be compared like for like.
#
# ⚠ WINDOW CHOSEN ON EVIDENCE, not convenience: t 96 -> 114 sits inside the G
# pedal (bass onsets every 2.0 s at t=96.017, 98.017, ... 112.017 — NINE rods
# born and dying) and is longer than the 2.7-4.0 s it takes a rod anchored at
# its onset to pass the LENS (round 34 §3), so every clip contains several
# complete rod lifetimes including the pass.
# ⛔ Writes only into r35-rods-motion/. No film directory is touched.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; R="$(cd "$D/.." && pwd)"
SRC="$R/06-bach-prelude/out"
PY=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python
START=${START:-96}; SECS=${SECS:-18}
VARIANTS=${VARIANTS:-"V0-no-rods-control V1-bass-thin-tall-lit-not-emitting V4-bass-height-from-duration V8-standing-ahead-at-V5-colour V9-horizontal-duration-bar"}
OUT=${OUT:-$D/out}
mkdir -p "$OUT"
for V in $VARIANTS; do
  echo "=== $V"
  "$PY" - "$V" "$OUT" <<'PYEOF'
import json, sys, os
R = os.path.dirname(os.path.dirname(os.path.abspath(sys.argv[0]))) if False else None
V, OUT = sys.argv[1], sys.argv[2]
root = "/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads"
P = json.load(open(f"{root}/06-bach-prelude/out/payload.json"))
rods = json.load(open(f"{root}/lib/_rods.variants.json"))[V]
if rods: P["look"]["rods"] = rods
else: P["look"].pop("rods", None)
json.dump(P, open(f"{OUT}/{V}.payload.json", "w"))
PYEOF
  rm -rf "$OUT/frames"
  START=$START node "$R/lib/shoot.mjs" "$OUT/$V.payload.json" "$OUT/frames" "$SECS"
  WANT=$("$PY" -c "print(int(round($SECS*30)))")
  GOT=$(ls "$OUT/frames" | grep -c '^f[0-9]*\.png$')
  [ "$GOT" -ge "$WANT" ] || { echo "[FAIL] $V frames $GOT / $WANT" >&2; exit 2; }
  echo "  [pin] frames $GOT / $WANT"
  ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$OUT/frames/f%06d.png" \
    -vf setsar=1 -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -r 30 "$OUT/$V.picture.mp4"
  ffmpeg -hide_banner -loglevel error -y -ss "$START" -t "$SECS" -i "$SRC/music.wav" \
    -i "$OUT/$V.picture.mp4" -map 1:v -map 0:a -c:v copy \
    -af "aresample=48000,aformat=channel_layouts=stereo,apad" -c:a aac -b:a 192k \
    -shortest "$OUT/$V.mp4"
  rm -f "$OUT/$V.picture.mp4"
  ffprobe -v error -show_entries format=duration:stream=codec_type -of csv=p=0 "$OUT/$V.mp4"
done
rm -rf "$OUT/frames"
