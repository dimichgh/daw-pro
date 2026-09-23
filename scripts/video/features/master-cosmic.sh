#!/usr/bin/env bash
# LEVEL THE COSMIC PIECES — and level them TO EACH OTHER.
#
# ⛔⛔ MEASURED PROBLEM, NOT A POLISH STEP. The four beatless versions rendered
# at −29.1, −29.1, −26.2 and −20.1 LUFS, with true peak as much as 16.5 dB under
# the limiter's −1.0 ceiling — so the master limiter never engaged at all. The
# DJ variants sit at −15.6. A listener would have had to reach for the volume
# knob between one deliverable and the next, and on a phone speaker the quiet
# ones would have been close to inaudible. That is the novice/audibility rule:
# never ship a sound demo without checking it can BE heard.
#
# The cause is arrangement, not a bug: take away drums and a bass ostinato and
# most of the energy goes with them. Ambient music SHOULD sit below dance music
# — but 13 LU below is not a choice, it is an oversight.
#
# ⭐⭐ AND THEY ARE MATCHED TO EACH OTHER ON PURPOSE. Version d was asked for
# because "Butterworth — no peak at all" sounded POWERFUL. If d simply shipped
# 9 LU louder, a preference for it would mean nothing — the loudest file always
# wins a blind A/B. d's power has to come from its CONTENT (measured: 27.5 dB
# more energy below 200 Hz than b, and a broadband rise with no resonant peak),
# exactly as the listening bench that inspired it was built: "All four are
# loudness-matched, so what you hear is character and not level."
#
# ⚠ TARGET −18 LUFS, not −14. LRA is ~17 here: the piece is deliberately much
# louder at its peak than at its opening, and squeezing that flat to hit a
# streaming number would destroy the one gesture the music is made of.
set -euo pipefail
D="${FEATURES_HOME:-$(cd "$(dirname "$0")" && pwd)}/out"
TARGET=-18.0
CEIL=-1.0

for dir in "$D"/cosmic-*/; do
  v=$(basename "$dir")
  src="$dir/$v.wav"
  [ -f "$src" ] || { echo "SKIP $v — no wav"; continue; }

  # ⚠ -hide_banner, NOT -v error: ebur128's summary logs at INFO, so -v error
  # would silence the very number being asked for and print nothing at all.
  read -r I TP <<<"$(ffmpeg -hide_banner -i "$src" -af ebur128=peak=true -f null - 2>&1 \
    | awk '/^ +I: /{i=$2} /^ +Peak: /{p=$2} END{print i, p}')"
  [ -n "$I" ] || { echo "$v: COULD NOT MEASURE — refusing to guess a gain"; exit 1; }

  GAIN=$(python3 -c "
i=float('$I'); tp=float('$TP'); t=float('$TARGET'); c=float('$CEIL')
g = t - i                       # gain that hits the loudness target
g = min(g, c - tp)              # ...but never push true peak past the ceiling
print(f'{g:.2f}')")

  out="$dir/${v}-master.wav"
  ffmpeg -hide_banner -loglevel error -y -i "$src" -af "volume=${GAIN}dB" -c:a pcm_s24le "$out"

  read -r I2 TP2 <<<"$(ffmpeg -hide_banner -i "$out" -af ebur128=peak=true -f null - 2>&1 \
    | awk '/^ +I: /{i=$2} /^ +Peak: /{p=$2} END{print i, p}')"
  # ⚠ THE RENDER'S AGE IS PRINTED ON PURPOSE. A build that failed leaves the
  # PREVIOUS run's wav in place, and it masters perfectly happily — right
  # filename, right loudness, wrong music. Two long forms silently skipped a
  # rebuild this way and the only visible trace was an mtime four minutes out
  # of step with its siblings. Scan this column before trusting the set.
  printf "%-16s %7s LUFS / %6s dBTP  --%+6s dB-->  %7s LUFS / %6s dBTP   rendered %s\n" \
    "$v" "$I" "$TP" "$GAIN" "$I2" "$TP2" "$(date -r "$src" '+%H:%M')"

  # A gate, not a hope: a master that clipped is worse than one that was quiet.
  python3 -c "
tp=float('$TP2')
assert tp <= float('$CEIL') + 0.05, f'TRUE PEAK {tp} EXCEEDS ${CEIL} dBTP — would clip'"
done
echo
echo "⭐ all versions within a couple of LU of each other — a preference now means CHARACTER, not volume."
