#!/usr/bin/env bash
#
# RVC voice-conversion sidecar launcher — starts the FastAPI facade
# (server.py) installed by install.sh, bound to 127.0.0.1 ONLY (loopback —
# hard security rule; the host is hardcoded in server.py too, never
# configurable).
#
# Mirrors scripts/ace-step/run.sh, with one deliberate difference: this
# script OWNS the pidfile (.rvc.pid). The ACE launcher leaves pidfile
# management to SidecarManager.swift; the RVC client actor arrives only at
# m10-p-3, so until then the pidfile must exist for plain shell lifecycle
# management (kill $(cat scripts/rvc/.rvc.pid)). Because this script `exec`s
# into the server, the PID it writes IS the server's PID — no wrapper
# process to babysit, and a SIGTERM to that PID reaches uvicorn directly.
#
# Logs go to <runtime>/logs/rvc-facade.log (append). Check there first when
# the facade won't boot or a conversion fails.
#
# Env overrides (all optional):
#   RVC_RUNTIME_DIR   default: <this dir>/runtime
#   RVC_API_PORT      default: 8002   (port only — the host is always loopback)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${RVC_RUNTIME_DIR:-$SCRIPT_DIR/runtime}"
SRC_DIR="$RUNTIME_DIR/src"
VENV_PY="$SRC_DIR/.venv/bin/python"
PIDFILE="$SCRIPT_DIR/.rvc.pid"
LOG_DIR="$RUNTIME_DIR/logs"
LOG_FILE="$LOG_DIR/rvc-facade.log"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "RVC engine is not installed (no source at $SRC_DIR)." >&2
  echo "Run scripts/rvc/install.sh first." >&2
  exit 1
fi
if [[ ! -x "$VENV_PY" ]]; then
  echo "RVC venv is missing/incomplete (no interpreter at $VENV_PY)." >&2
  echo "Run scripts/rvc/install.sh (it resumes an interrupted install)." >&2
  exit 1
fi

# Refuse to double-start; clear a stale pidfile from a dead process.
if [[ -f "$PIDFILE" ]]; then
  OLD_PID="$(cat "$PIDFILE")"
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "RVC facade already running (pid $OLD_PID, pidfile $PIDFILE)." >&2
    echo "Stop it first: kill \$(cat $PIDFILE)" >&2
    exit 1
  fi
  echo "Clearing stale pidfile (pid $OLD_PID is gone)."
  rm -f "$PIDFILE"
fi

# faiss segfault guard — MANDATORY (spike delta #4, per the fork's own
# benchmark README). Must be set before the process imports faiss.
export OMP_NUM_THREADS=1
export TOKENIZERS_PARALLELISM="${TOKENIZERS_PARALLELISM:-false}"
export PYTHONUNBUFFERED=1
export RVC_RUNTIME_DIR="$RUNTIME_DIR"
export RVC_API_PORT="${RVC_API_PORT:-8002}"

mkdir -p "$LOG_DIR"
# $$ becomes the server's PID after the exec below.
echo $$ > "$PIDFILE"
echo "RVC facade starting on 127.0.0.1:$RVC_API_PORT (pid $$, pidfile $PIDFILE)"
echo "Logging to $LOG_FILE"
cd "$SRC_DIR"
exec >> "$LOG_FILE" 2>&1
exec "$VENV_PY" "$SCRIPT_DIR/server.py"
