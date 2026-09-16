#!/bin/bash
# Upload films given as explicit "<mp4>|<publish.json>" pairs.
# Two lessons baked in:
#   - never pipe the uploader (a pipe discards its exit status)
#   - never DERIVE the mp4 name; out/ also holds picture.mp4 (silent) and
#     *-preview.mp4 (low bitrate). Uploading the wrong one is invisible.
set -uo pipefail
PY=/Users/dsemenov/Views/daw-pro/scripts/video/publish/.venv/bin/python
UP=/Users/dsemenov/Views/daw-pro/scripts/video/publish/yt_upload.py
ok=0; fail=0
for pair in "$@"; do
  mp4="${pair%%|*}"; meta="${pair##*|}"
  echo "=== $(basename "$mp4")"
  [ -f "$mp4" ]  || { echo "  MISSING mp4: $mp4";  fail=$((fail+1)); continue; }
  [ -f "$meta" ] || { echo "  MISSING meta: $meta"; fail=$((fail+1)); continue; }
  log="/tmp/up-$(basename "$mp4" .mp4).log"
  if "$PY" "$UP" "$mp4" "$meta" > "$log" 2>&1; then
    ok=$((ok+1)); grep "PRIVATE draft" "$log" || echo "  uploaded but NO LINK LINE — inspect $log"
  else
    rc=$?; fail=$((fail+1)); echo "  FAILED rc=$rc"; tail -3 "$log" | sed 's/^/  /'
  fi
done
echo "--- uploaded $ok, failed $fail ---"
[ "$fail" -eq 0 ]
