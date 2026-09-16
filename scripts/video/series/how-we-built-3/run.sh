#!/bin/bash
# ⛔⛔ PORT DISCIPLINE. Two film builds killed each other's speech server on the
# default 8000 in one night, in both directions, each convinced it was
# reclaiming its own leftover. Identifying a process by port proves WHAT it is,
# never WHOSE it is. This derives its own port, records the pid IT started, and
# kills nothing else.
set -u
HERE=/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-3
V=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin
export OMLX_PORT=$((8000 + ($$ % 900) + 1))
export OMLX_BASE=http://127.0.0.1:$OMLX_PORT
if lsof -nP -iTCP:$OMLX_PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "PORT $OMLX_PORT ALREADY IN USE BY SOMEBODY ELSE — refusing to touch it"; exit 3
fi
$V/omlx serve --port $OMLX_PORT > $HERE/omlx.log 2>&1 &
OMLX_PID=$!
echo "OMLX_PORT=$OMLX_PORT OMLX_PID=$OMLX_PID"
echo $OMLX_PID > $HERE/omlx.pid
echo $OMLX_PORT > $HERE/omlx.port
for i in $(seq 1 90); do
  if lsof -nP -iTCP:$OMLX_PORT -sTCP:LISTEN -t 2>/dev/null | grep -qx "$OMLX_PID"; then
    echo "listening, and the pid on the port IS the one I started"; break; fi
  sleep 2
done
