#!/usr/bin/env bash
#
# ACE-Step-1.5 sidecar launcher — starts the FastAPI server installed by
# install.sh, bound to 127.0.0.1 ONLY (loopback — see docs/AI-INTEGRATIONS.md
# security posture). Intended to be spawned as a child process by
# Sources/AIServices/SidecarManager.swift (which owns the pidfile/log
# capture itself); this script stays in the foreground and `exec`s into the
# real server process so a SIGTERM sent to this script's PID reaches the
# server directly (no extra wrapper process to babysit).
#
# Env overrides (all optional):
#   ACESTEP_RUNTIME_DIR    default: <this dir>/runtime
#   ACESTEP_CHECKPOINTS_DIR default: <runtime dir>/checkpoints
#   ACESTEP_CONFIG_PATH     default: acestep-v15-xl-turbo (fast default; use
#                           acestep-v15-xl-sft for a "polish" pass)
#   ACESTEP_CONFIG_PATH2    default: acestep-v15-xl-sft (slot 2 — constructs a
#                           second handler so ACEStepClient can load the
#                           BASE/SFT model on demand for extract/lego jobs,
#                           which turbo does not officially support)
#   ACESTEP_LM_MODEL_PATH   default: acestep-5Hz-lm-4B (top quality tier)
#   ACESTEP_API_PORT        default: 8001
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${ACESTEP_RUNTIME_DIR:-$SCRIPT_DIR/runtime}"
SRC_DIR="$RUNTIME_DIR/src"

if ! command -v uv &>/dev/null; then
  if [[ -x "$HOME/.local/bin/uv" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
  elif [[ -x "$HOME/.cargo/bin/uv" ]]; then
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
fi

if [[ ! -d "$SRC_DIR" ]]; then
  echo "ACE-Step-1.5 is not installed (no source at $SRC_DIR)." >&2
  echo "Run scripts/ace-step/install.sh first." >&2
  exit 1
fi

if ! command -v uv &>/dev/null; then
  echo "uv (Astral's Python package manager) is not on PATH — required to run the sidecar." >&2
  echo "Install it: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  exit 1
fi

# Model tier: XL DiT + 4B LM planner, the top official quality tier (this
# machine has 128 GB unified memory — see docs/research/2026-07-05-ace-step-local-song-generation.md
# section 8a). Override to acestep-v15-xl-sft for a slower/higher-fidelity pass.
export ACESTEP_CHECKPOINTS_DIR="${ACESTEP_CHECKPOINTS_DIR:-$RUNTIME_DIR/checkpoints}"
export ACESTEP_CONFIG_PATH="${ACESTEP_CONFIG_PATH:-acestep-v15-xl-turbo}"
# Slot 2: the BASE/SFT tier, so extract/lego jobs (which turbo's
# TASK_TYPES_TURBO excludes) have a real handler to load into on demand via
# POST /v1/init rather than upstream silently substituting the primary/turbo
# handler (M6 iii-c-real — see ACEStepClient.swift). Setting this env var only
# constructs the slot 2 handler at startup; the SFT weights themselves (already
# downloaded by install.sh) still load lazily on the first /v1/init call.
export ACESTEP_CONFIG_PATH2="${ACESTEP_CONFIG_PATH2:-acestep-v15-xl-sft}"
export ACESTEP_LM_MODEL_PATH="${ACESTEP_LM_MODEL_PATH:-acestep-5Hz-lm-4B}"
# Upstream inconsistency (verified in acestep_v15_pipeline.py): the serve-time
# generation path builds `os.path.join(project_root, "checkpoints")` and passes
# it EXPLICITLY, which bypasses ACESTEP_CHECKPOINTS_DIR (custom_dir wins in
# get_checkpoints_dir). project_root honors ACESTEP_PROJECT_ROOT, else cwd
# (= src/ after the cd below) — without this the first generation request
# re-downloads the entire main bundle into src/checkpoints.
export ACESTEP_PROJECT_ROOT="${ACESTEP_PROJECT_ROOT:-$RUNTIME_DIR}"

# Apple Silicon: mirrors ACE-Step's own start_api_server_macos.sh (MLX
# backend for the LM planner; the DiT/VAE MLX path auto-enables on
# Apple Silicon independently) plus the community-documented MPS fallback
# env var (research doc section 3) as a safety net for ops MLX doesn't cover.
export ACESTEP_LM_BACKEND="${ACESTEP_LM_BACKEND:-mlx}"
export TOKENIZERS_PARALLELISM="${TOKENIZERS_PARALLELISM:-false}"
export PYTORCH_ENABLE_MPS_FALLBACK="${PYTORCH_ENABLE_MPS_FALLBACK:-1}"

# Loopback ONLY — never bind 0.0.0.0 here.
export ACESTEP_API_HOST="127.0.0.1"
export ACESTEP_API_PORT="${ACESTEP_API_PORT:-8001}"

cd "$SRC_DIR"
# Start must never re-resolve dependencies: a bare `uv run` re-syncs the
# environment, which needs the network (observed failure: metadata fetch for
# a direct-URL flash-attn wheel died on an intercepting proxy's TLS cert and
# the sidecar never booted). The env was fully built by install.sh — when its
# .venv exists, run against it as-is; a missing .venv falls back to a full
# sync so a fresh checkout still self-heals.
if [[ -d "$SRC_DIR/.venv" ]]; then
  exec uv run --no-sync acestep-api
else
  exec uv run acestep-api
fi
