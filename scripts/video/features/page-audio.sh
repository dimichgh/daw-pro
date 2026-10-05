#!/usr/bin/env bash
# LEVEL-MATCHED AUDIO FOR THE REVIEW PAGE.
#
#   bash page-audio.sh [piece ...]        # default: the five developed pieces
#
# ⛔ THIS LIVES IN THE REPO ON PURPOSE. Its predecessor was written into the
# session scratchpad, which is reaped — and the released film very nearly went
# with it (13 files hardcoded a /private/tmp path). A step that exists only in a
# temp directory is a step that exists until the next reboot.
#
# ⭐⭐ A STATIC GAIN, NOT A NORMALISER, AND THAT IS THE WHOLE POINT.
# gain = target − measured_I, the SAME arithmetic for every file, so the pieces
# keep their true relative dynamics and only their absolute level is equalised.
# If any file's true peak would pass the ceiling after its gain, the target drops
# for ALL of them TOGETHER — lowering one alone would re-introduce exactly the
# level difference this exists to remove.
#
# ⚠ WHY A SECOND PASS AT ALL, WHEN master-cosmic.sh ALREADY AIMED AT −18.
# It aims, then clamps: `g = min(g, c - tp)`, so any piece whose true peak would
# breach −1.0 dBTP stops short of the target. On the previous round that left A
# and B at −19.5/−19.6 against D's −18.0, and I shipped the claim "all four are
# level-matched" without measuring it. **The loudest file always wins a blind
# A/B** — 1.5 LU of D's apparent "power" was level, not content. This pass exists
# so a preference between the five means CHARACTER.
#
# ⚠ FULL LENGTH, NOT AN EXCERPT. These pieces are being judged on whether they
# DEVELOP over three and a half minutes; a 45-second window cannot show that and
# would make the question unanswerable.
set -euo pipefail
D="${FEATURES_HOME:-$(cd "$(dirname "$0")" && pwd)}"
OUT="$D/out/page-audio"
CEIL=-1.5
BITRATE=128k          # 3:40 stereo ≈ 3.4 MB — the artifact cap is 15 MB/file.

PIECES=("$@")
if [ ${#PIECES[@]} -eq 0 ]; then
  PIECES=(cosmic-ascent cosmic-collapse cosmic-heartbeat cosmic-aurora cosmic-signal)
fi

mkdir -p "$OUT"
MEAS="$OUT/_meas.txt"
: > "$MEAS"

# ⚠ -hide_banner, NOT -v error: ebur128's summary logs at INFO, so -v error
# silences the very number being asked for and prints nothing at all.
#
# ⛔⛔ -nostdin ON EVERY CALL, AND IT IS NOT COSMETIC. ffmpeg reads stdin for its
# interactive console. Pass 3 is a `while read ... done < "$MEAS"` loop, so
# ffmpeg ATE THE LOOP'S REMAINING LINES: the loop ran exactly ONCE, printed one
# row, and then announced "⭐ all matched" — a green result standing over four
# files that were never written. MEASURED 2026-09-21: 5 pieces in, 1 mp3 out,
# exit 0. The giveaway was ffmpeg's own "Enter command:" prompt in the output.
measure() {
  ffmpeg -nostdin -hide_banner -i "$1" -af ebur128=peak=true -f null - 2>&1 \
    | awk '/^ +I: /{i=$2} /^ +Peak: /{p=$2} END{print i, p}'
}

echo "=== pass 1: measure ==="
for v in "${PIECES[@]}"; do
  src="$D/out/$v/$v-master.wav"
  [ -f "$src" ] || src="$D/out/$v/$v.wav"
  [ -f "$src" ] || { echo "⛔ $v: no wav — refusing to skip silently"; exit 1; }
  read -r I TP <<<"$(measure "$src")"
  [ -n "$I" ] || { echo "⛔ $v: could not measure — refusing to guess a gain"; exit 1; }
  echo "$v $I $TP $src" >> "$MEAS"
  printf "  %-18s %7s LUFS  %6s dBTP   rendered %s\n" "$v" "$I" "$TP" "$(date -r "$src" '+%H:%M')"
done

echo
echo "=== pass 2: one target every file can reach under the ceiling ==="
TARGET=$(python3 -c "
rows=[l.split() for l in open('$MEAS') if l.strip()]
ceil=float('$CEIL')
print(f'{min([-18.0] + [ceil - float(tp) + float(i) for _,i,tp,_ in rows]):.2f}')")
echo "  common target: $TARGET LUFS (ceiling $CEIL dBTP)"

echo
echo "=== pass 3: apply, encode, verify ==="
printf "  %-18s %8s %9s %9s %7s %8s\n" file gain "I after" "TP after" size check
while read -r v I TP src; do
  [ -z "$v" ] && continue
  G=$(python3 -c "print(f'{float('$TARGET')-float('$I'):.2f}')")
  dst="$OUT/$v.mp3"
  ffmpeg -nostdin -hide_banner -loglevel error -y -i "$src" \
    -af "volume=${G}dB" -c:a libmp3lame -b:a "$BITRATE" "$dst"
  read -r I2 TP2 <<<"$(measure "$dst")"
  SZ=$(python3 -c "import os;print(f'{os.path.getsize(\"$dst\")/1048576:.1f}M')")
  ok=$(python3 -c "
i,tp,c=float('$I2'),float('$TP2'),float('$CEIL')
print('ok' if abs(i-float('$TARGET'))<0.6 and tp<=c+0.5 else 'REVIEW')")
  printf "  %-18s %+8s %9s %9s %7s %8s\n" "$v" "$G" "$I2" "$TP2" "$SZ" "$ok"
  [ "$ok" = "ok" ] || { echo "⛔ $v missed the target — not shipping a page that lies about level-matching"; exit 1; }
done < "$MEAS"

rm -f "$MEAS"
echo
echo "⭐ all matched to $TARGET LUFS — a preference now means CHARACTER, not volume."
ls -la "$OUT"/*.mp3 | awk '{printf "  %10s  %s\n",$5,$9}'
