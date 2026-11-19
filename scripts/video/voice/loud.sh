#!/bin/bash
# loud.sh <wav>... — integrated LUFS, true peak, and loudness range per file.
# ⚠ -hide_banner, NEVER -v error: ebur128's summary logs at INFO, so -v error
# prints nothing and exits 0 — an empty answer that reads like silence.
for f in "$@"; do
  out="$(ffmpeg -hide_banner -nostats -i "$f" -af ebur128=peak=true -f null - 2>&1)"
  I="$(printf '%s\n' "$out" | grep -E '^\s+I:' | tail -1 | awk '{print $2}')"
  P="$(printf '%s\n' "$out" | grep -E '^\s+Peak:' | tail -1 | awk '{print $2}')"
  L="$(printf '%s\n' "$out" | grep -E '^\s+LRA:' | tail -1 | awk '{print $2}')"
  [ -n "$I" ] || { echo "⛔ $f: no ebur128 summary parsed — the probe saw nothing"; continue; }
  printf "%-40s I %7s LUFS   TP %6s dBTP   LRA %5s LU\n" "$(basename "$f")" "$I" "$P" "$L"
done
