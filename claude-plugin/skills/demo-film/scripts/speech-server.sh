#!/usr/bin/env bash
# Start / stop / probe the local speech server that narrate.py talks to.
#
# ⛔⛔ WHY THIS EXISTS — TWO REAL FAILURES, NOT TIDINESS.
#
# ① "IT IS NOT INSTALLED." A session probed `which omlx` (nothing) and
#    `python3 -c "import mlx_omni_server"` (ModuleNotFoundError), concluded the
#    cloned brand voice needed gigabytes of downloads, and narrated an entire
#    finished film with the macOS `say` voice instead. Everything was installed.
#    ⚠ THE IMPORT PROBE WAS ALSO TESTING THE WRONG NAME: the package is `omlx`,
#    NOT `mlx_omni_server`. A wrong module name and a missing package raise the
#    IDENTICAL ModuleNotFoundError — which is this machine's signature failure:
#    a tool that never looked and one that looked and found nothing are
#    indistinguishable. The user's reply: "everything is inside repo, look at
#    your skills!"
#
# ② THE PORT. Port 8000 is the DEFAULT and therefore THE COLLISION. Two film
#    builds have already killed each other's speech server on it, in both
#    directions. This script derives a private port instead, and `start` PRINTS
#    the OMLX_BASE you must pass to narrate.py.
#
#   eval "$(./speech-server.sh start)"   # exports OMLX_BASE; blocks until ready
#   ./speech-server.sh status
#   ./speech-server.sh stop              # ALWAYS — it holds tens of GB
set -u

# The server ships INSIDE THIS REPO, in the narrated-film plugin's own venv.
# Resolution order; add new homes HERE, so the next session gets them by running
# the script rather than by remembering.
find_omlx() {
  [ -n "${OMLX_BIN:-}" ] && [ -x "$OMLX_BIN" ] && { echo "$OMLX_BIN"; return; }
  for c in \
      "${CLAUDE_PLUGIN_ROOT:-}/.venv/bin/omlx" \
      /Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/omlx \
      /Users/dsemenov/Views/llm/.venv/bin/omlx \
      "$(command -v omlx 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return; }
  done
  return 1
}

# A port nobody else will pick. NEVER default to 8000 — see ② above.
PORT="${OMLX_PORT:-$((8000 + ($$ % 900) + 1))}"
PORTFILE="${OMLX_PORTFILE:-/tmp/omlx-port.$USER}"
[ "${1:-status}" != "start" ] && [ -z "${OMLX_PORT:-}" ] && [ -f "$PORTFILE" ] && PORT="$(cat "$PORTFILE")"
LOG="${OMLX_LOG:-/tmp/omlx-$PORT.log}"

pid_on_port() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1; }
listening()   { nc -z -G 2 127.0.0.1 "$PORT" 2>/dev/null; }

case "${1:-status}" in
  start)
    if listening; then
      echo "export OMLX_BASE=http://127.0.0.1:$PORT"
      echo "# already listening on $PORT (pid $(pid_on_port))" >&2; exit 0; fi
    BIN="$(find_omlx)" || {
      echo "⛔ omlx not found." >&2
      echo "   It is NOT on \$PATH, and that alone is NOT absence." >&2
      echo "   It ships in-repo: plugins/narrated-film/.venv/bin/omlx" >&2
      echo "   ⚠ Do NOT probe 'import mlx_omni_server' — the package is 'omlx'." >&2
      echo "   Models are cached already: ls ~/.cache/huggingface/hub | grep -iE 'voxcpm|whisper'" >&2
      exit 1; }
    echo "# starting $BIN on port $PORT (log: $LOG)" >&2
    nohup "$BIN" serve --port "$PORT" > "$LOG" 2>&1 &
    # Wait for the PORT, never a fixed sleep: a cold model load outlasts any
    # guess, and the failure then looks like connection-refused from narrate.py.
    for _ in $(seq 1 180); do listening && break; sleep 1; done
    if ! listening; then echo "⛔ not up within 180 s; tail of $LOG:" >&2; tail -15 "$LOG" >&2; exit 1; fi
    echo "$PORT" > "$PORTFILE"
    echo "export OMLX_BASE=http://127.0.0.1:$PORT"
    echo "# up: pid $(pid_on_port) on $PORT" >&2
    ;;
  status)
    if listening; then echo "LISTENING on $PORT, pid $(pid_on_port)";
    else echo "no listener on $PORT (checked $PORTFILE and \$OMLX_PORT)"; fi
    ;;
  stop)
    P="$(pid_on_port)"
    # ⚠ GUARD THE EMPTY CASE. An empty pid once turned a targeted probe into a
    # machine-wide one here and read as a pass.
    if [ -z "$P" ]; then echo "nothing listening on $PORT; nothing to kill"; exit 0; fi
    echo "killing pid $P (owner of port $PORT)"; kill "$P"
    for _ in $(seq 1 30); do listening || break; sleep 1; done
    listening && { echo "⛔ still listening; NOT escalating automatically"; exit 1; }
    rm -f "$PORTFILE"; echo "stopped."
    ;;
  *) echo "usage: $0 {start|status|stop}"; exit 2;;
esac
