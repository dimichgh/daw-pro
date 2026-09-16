#!/bin/bash
# Windowed RMS of every stem in a directory. `-ss/-t` matter: a part that plays
# for one room of five reads ~7 dB low over the whole file, and a stem measured
# that way looks buried when it is merely brief.
D="$1"; SS="${2:-0}"; T="${3:-999}"
for f in "$D"/*.wav; do
  v=$(ffmpeg -hide_banner -ss "$SS" -t "$T" -i "$f" -af astats=metadata=1 -f null - 2>&1 \
      | grep -m1 Overall -A 12 | grep "RMS level" | sed "s/.*RMS level dB: //")
  printf "%-32s %s\n" "$(basename "$f")" "$v"
done
