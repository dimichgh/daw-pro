#!/usr/bin/env bash
# ONE SCREEN TAKE PER MOTION BEAT, from takes.json (the table the audio was cut
# from). Each take lands as bursts/<burst>/raw.mp4; sync-takes.py then trims its
# head to the excerpt's first sample using the transport clock read in the take's
# FIRST FRAME, and writes bursts/<burst>/clip.mp4 (what assemble.py plays).
#
#   bash record-all.sh            every take with record != false
#   bash record-all.sh sour drums only those
#
# Copied in SHAPE from features/record-all.sh, with three differences, each for
# a reason:
#  * no LEAD_IN constant. Features measured 1.825 s for ITS driver; this one
#    opens states and waits for the note editor first (prep), so the handshake
#    differs. The head is trimmed per take from the on-screen clock instead.
#  * the slow part (opening a state, the editor reading the take) runs BEFORE
#    the camera, in `record-motion.mjs prep`, so no take opens on a half-drawn view.
#  * every take is checked to MOVE (peak frame difference 2 s vs 8 s in, with a
#    frozen control that must read static) — features' ymax probe.
set -euo pipefail
HOME_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$HOME_DIR"
REC=../screenrec/screenrec
BURSTS=$HOME_DIR/bursts
mkdir -p "$BURSTS" logs

# ⛔ ScreenCaptureKit returns ZERO frames while the display sleeps, and still
# writes a valid-looking mp4. Hold the display awake for this script's life.
caffeinate -d -i -u -w $$ &
sleep 1

TAKES=$(/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python -c '
import json, sys
only = set(sys.argv[1:])
for t in json.load(open("takes.json"))["takes"]:
    if t.get("record", True) and (not only or t["burst"] in only):
        print(t["burst"])' "$@")
[ -n "$TAKES" ] || { echo "⛔ no takes selected"; exit 1; }

for b in $TAKES; do
  mkdir -p "$BURSTS/$b"
  echo "--- $b"
  # ⚠ LOGGED, never discarded: a failed prep must say why.
  node record-motion.mjs prep "$b" > "$BURSTS/$b/prep.log" 2>&1 \
    || { echo "⛔ prep FAILED for $b:"; cat "$BURSTS/$b/prep.log"; exit 1; }
  SECS=$(/usr/bin/grep -o '"recordSeconds":[0-9.]*' "$BURSTS/$b/prep.log" | cut -d: -f2)
  [ -n "$SECS" ] || { echo "⛔ prep for $b printed no recordSeconds"; cat "$BURSTS/$b/prep.log"; exit 1; }
  HOLD=$(echo "$SECS + 2" | bc)
  node record-motion.mjs play "$HOLD" > "$BURSTS/$b/drive.log" 2>&1 &
  DRIVER=$!
  sleep 0.5
  rm -f "$BURSTS/$b/raw.mp4"
  $REC --app "DAWProStaging" --out "$BURSTS/$b/raw.mp4" --seconds "$SECS" --fps 30 --scale 2.0 \
    > "$BURSTS/$b/rec.log" 2>&1 \
    || { echo "⛔ recorder FAILED for $b:"; cat "$BURSTS/$b/rec.log"; kill "$DRIVER" 2>/dev/null || true; exit 1; }
  tail -1 "$BURSTS/$b/rec.log"
  wait $DRIVER || { echo "⛔ transport driver FAILED for $b:"; cat "$BURSTS/$b/drive.log"; exit 1; }
done

echo "=== every take must be a DIFFERENT file"
md5 -q "$BURSTS"/*/raw.mp4 | sort | uniq -c | sort -rn | head -3

echo "=== and every take must MOVE (changed pixels, frame 2 s vs frame 8 s), with self + frozen controls"
# ⛔ The blend=difference probe that stood here paired its inputs BY TIMESTAMP
# and did not compare 2 s with 8 s (see tools/take-motion.py). Numpy instead.
/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python "$HOME_DIR/tools/take-motion.py" $TAKES \
  || { echo "⛔ a take is static, or a control failed"; exit 1; }
echo "✓ recorded: $(echo $TAKES | wc -w | tr -d ' ') takes"
