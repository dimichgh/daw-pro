#!/bin/bash
#
# DAW Pro singing sidecar launcher (design docs/design/2026-09-27-p2-sing-integration.md §2.6).
#
# It writes its own pid to <runtime>/run/sing.pid and then `exec`s the venv's python on server.py, so the pid in
# the pidfile IS the process listening on the port (the wrong-pid lesson). Nothing runs through a console-script
# shebang: "Application Support" has a space in it, and a shebang with a space in its path does not run.
#
# Environment:
#   SING_RUNTIME_DIR    required: the installed engine (<Application Support>/DAWPro/SingingEngine, profile-aware;
#                       the app passes it). The script never guesses it.
#   SING_PORT           default 8004 (staging and tests: 18004). The host is always 127.0.0.1 (server.py refuses
#                       anything else).
#   SING_ALLOWED_ROOTS  passed through to server.py (':'-separated folders it may read voices from and write to).
#   SING_LOG_FILE       optional: append stdout+stderr there (else they are inherited from the caller).
#   SING_USE_STUB=1     tests only: exec /usr/bin/python3 stub_server.py instead (no venv needed; same pidfile, same
#                       exec, same port rules). SING_STUB_* variables pick its fault (see stub_server.py).
#   SING_TEST_HOOKS=1   tests only: passed through (server.py accepts "testPromptF0").
#
# Exit codes before the exec: 2 = no/bad SING_RUNTIME_DIR, 3 = already running, 4 = not installed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SING_RUNTIME_DIR:-}" || ! -d "${SING_RUNTIME_DIR}" ]]; then
  echo "run.sh: SING_RUNTIME_DIR must name the singing engine's folder (got '${SING_RUNTIME_DIR:-}')." >&2
  exit 2
fi
RUNTIME_DIR="$(cd "$SING_RUNTIME_DIR" && pwd -P)"
RUN_DIR="$RUNTIME_DIR/run"
PIDFILE="$RUN_DIR/sing.pid"
export SING_RUNTIME_DIR="$RUNTIME_DIR"
export SING_PORT="${SING_PORT:-8004}"

if [[ "${SING_USE_STUB:-0}" == "1" ]]; then
  PY="/usr/bin/python3"
  SERVER="$SCRIPT_DIR/stub_server.py"
else
  PY="$RUNTIME_DIR/venv/bin/python"
  SERVER="$SCRIPT_DIR/server.py"
  if [[ ! -x "$PY" ]]; then
    echo "run.sh: the singing engine is not installed (no interpreter at '$PY'). Run install.sh." >&2
    exit 4
  fi
fi

mkdir -p "$RUN_DIR"

# Refuse a double start. A pid that is alive but is NOT our server (pid reuse) is a stale pidfile, not a
# running engine; the manager's own lsof check decides who owns the port.
if [[ -f "$PIDFILE" ]]; then
  OLD_PID="$(head -n 1 "$PIDFILE" | tr -cd '0-9')"
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    OLD_CMD="$(ps -p "$OLD_PID" -o command= || true)"
    if [[ "$OLD_CMD" == *"server.py"* ]]; then
      echo "run.sh: the singing engine is already running (pid $OLD_PID, pidfile '$PIDFILE')." >&2
      exit 3
    fi
  fi
  echo "run.sh: clearing a stale pidfile (pid '${OLD_PID}' is not a running singing engine)." >&2
  rm -f "$PIDFILE"
fi

# Caches live inside the runtime (design §2.5 step 8), and the running sidecar can never download.
export HF_HOME="$RUNTIME_DIR/cache/hf"
export TORCH_HOME="$RUNTIME_DIR/cache/torch"
export XDG_CACHE_HOME="$RUNTIME_DIR/cache/xdg"
export MODELSCOPE_CACHE="$RUNTIME_DIR/cache/modelscope"
export MPLCONFIGDIR="$RUNTIME_DIR/cache/mpl"
export NUMBA_CACHE_DIR="$RUNTIME_DIR/cache/numba"
export NLTK_DATA="$RUNTIME_DIR/nltk_data"
export HF_HUB_DISABLE_TELEMETRY=1
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export PYTHONUNBUFFERED=1
export PYTHONNOUSERSITE=1
# As measured in the spike (its F9): a missing MPS op must fail loudly, never run quietly on the CPU.
unset PYTORCH_ENABLE_MPS_FALLBACK
# Hermetic: nothing from the caller's shell may shadow the venv's packages.
unset PYTHONPATH PYTHONHOME

cd "$RUNTIME_DIR"
# $$ becomes the server's pid at the exec below.
echo "$$" > "$PIDFILE"
if [[ -n "${SING_LOG_FILE:-}" ]]; then
  mkdir -p "$(dirname "$SING_LOG_FILE")"
  exec >> "$SING_LOG_FILE" 2>&1
fi
echo "run.sh: starting $(basename "$SERVER") as pid $$ on 127.0.0.1:$SING_PORT (runtime '$RUNTIME_DIR')" >&2
exec "$PY" "$SERVER"
