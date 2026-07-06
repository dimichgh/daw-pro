#!/usr/bin/env bash
#
# ACE-Step-1.5 sidecar installer — M6 (i), see
# docs/research/2026-07-05-ace-step-local-song-generation.md for the full
# rationale (model tier, sizing, license).
#
# WHAT THIS DOWNLOADS (largest official tier — this machine has 128 GB
# unified memory and 1.2 TB free disk, so we take the top quality tier
# rather than a leaner one):
#   - the ACE-Step-1.5 "main" bundle (VAE + Qwen3-Embedding-0.6B text
#     encoder + default 2B turbo DiT + default 1.7B LM) — required, the
#     shared components (VAE/text encoder) ship only inside this bundle
#   - acestep-v15-xl-turbo   (XL ~5B DiT, 8-step distilled — fast default)
#   - acestep-v15-xl-sft     (XL ~5B DiT, full step count — "polish" pass)
#   - acestep-5Hz-lm-4B      (Qwen3-4B LM planner — top quality tier)
#   Total download is roughly 55-70 GB (see DEVIATION note below on why
#   this is larger than the research doc's ~25-35 GB estimate). Trivial
#   against 1.2 TB free; the bottleneck is bandwidth/time, not space.
#
# NEEDS THE USER IF THIS HAPPENS: ACE-Step-1.5's code and weights are all
# MIT-licensed and NOT gated on Hugging Face as of the research date — no
# login/token should be required. If a download nonetheless fails with a
# 401/403 ("gated"/"authentication required"), STOP — do not work around
# it — and have the user either:
#   1. run `huggingface-cli login` (or set HF_TOKEN) with an account that
#      has accepted whatever gate appeared, then re-run this script
#      (it is idempotent/resumable — already-downloaded models are skipped), or
#   2. confirm the intended checkpoint name in case the upstream registry
#      changed (this script deviates from the research doc already; see
#      the DEVIATION note below).
#
# DEVIATION from docs/research/2026-07-05-ace-step-local-song-generation.md:
#   The doc recommends downloading the "-diffusers" bf16 repos (e.g.
#   acestep-v15-xl-turbo-diffusers) to save disk. As of this writing, the
#   upstream `acestep-download` CLI's SUBMODEL_REGISTRY (acestep/model_downloader.py)
#   does not list any "-diffusers" checkpoint names — only the raw (FP32 on
#   disk) xl-base/xl-sft/xl-turbo repos. Since disk is not a constraint on
#   this machine, this script downloads the raw repos via the officially
#   documented `acestep-download` CLI (verified against the live
#   pyproject.toml entry point `acestep-download = "acestep.model_downloader:main"`)
#   rather than hand-rolling a snapshot_download against a repo id that may
#   not exist. Revisit if/when upstream ships bf16 "-diffusers" XL repos.
#
# Idempotent: safe to re-run. Each step skips work already done (repo
# already cloned, venv already synced, a model already fully present) —
# both upstream's own tooling (huggingface_hub resumes partial downloads)
# and this script's own pre-checks make an interrupted run resumable.
#
# Env overrides:
#   ACESTEP_RUNTIME_DIR   default: <this dir>/runtime
#   ACESTEP_PYTHON_VERSION default: 3.12
#   FORCE=1               re-run every step even if already done
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${ACESTEP_RUNTIME_DIR:-$SCRIPT_DIR/runtime}"
SRC_DIR="$RUNTIME_DIR/src"
CHECKPOINTS_DIR="$RUNTIME_DIR/checkpoints"
MARKER="$SCRIPT_DIR/.install-state.json"
PYTHON_VERSION="${ACESTEP_PYTHON_VERSION:-3.12}"
FORCE="${FORCE:-0}"
REPO_URL="https://github.com/ace-step/ACE-Step-1.5.git"

DIT_MODELS=("acestep-v15-xl-turbo" "acestep-v15-xl-sft")
LM_MODEL="acestep-5Hz-lm-4B"

log() { printf '==> %s\n' "$1"; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

log "ACE-Step-1.5 sidecar install starting ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
log "Runtime dir: $RUNTIME_DIR"

if [[ "$FORCE" != "1" && -f "$MARKER" ]]; then
  log "Already installed (marker found at $MARKER) — nothing to do."
  log "Set FORCE=1 to re-verify/re-download anyway."
  cat "$MARKER"
  exit 0
fi

# --- Step 1: disk space sanity -----------------------------------------
log "Step 1/7: disk space check"
AVAIL_KB=$(df -Pk "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
log "Free space at $SCRIPT_DIR: ${AVAIL_GB} GB"
if (( AVAIL_GB < 80 )); then
  die "Need at least ~80 GB free for the XL+4B tier (main bundle + xl-turbo + xl-sft + 4B LM); only ${AVAIL_GB} GB available. Free up space and re-run."
fi

# --- Step 2: package manager (uv) ---------------------------------------
log "Step 2/7: locating uv (Astral's Python package/venv manager)"
if ! command -v uv &>/dev/null; then
  if [[ -x "$HOME/.local/bin/uv" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
  elif [[ -x "$HOME/.cargo/bin/uv" ]]; then
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
fi

if command -v uv &>/dev/null; then
  log "uv found: $(uv --version)"
  USE_UV=1
else
  log "uv not found — falling back to system python3 with a version floor check."
  USE_UV=0
  PY3_VERSION="$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || echo "0.0.0")"
  PY3_MAJOR="${PY3_VERSION%%.*}"
  PY3_MINOR="$(echo "$PY3_VERSION" | cut -d. -f2)"
  # ACE-Step-1.5 pins requires-python = ">=3.11,<3.13" (verified against the
  # live pyproject.toml). Without uv to fetch an isolated interpreter, the
  # system python3 must itself fall in that window.
  if [[ "$PY3_MAJOR" != "3" || "$PY3_MINOR" -lt 11 || "$PY3_MINOR" -ge 13 ]]; then
    die "system python3 is $PY3_VERSION, outside ACE-Step-1.5's required >=3.11,<3.13 window (this machine's python3 is 3.14.x by default). Install uv instead: curl -LsSf https://astral.sh/uv/install.sh | sh — uv manages an isolated 3.12 interpreter for us and sidesteps this entirely."
  fi
  log "system python3 $PY3_VERSION is within the required window — proceeding without uv (slower, no isolated env)."
fi

# --- Step 3: clone (or reuse) the ACE-Step-1.5 repo ----------------------
log "Step 3/7: ACE-Step-1.5 source"
mkdir -p "$RUNTIME_DIR"
if [[ -d "$SRC_DIR/.git" ]]; then
  log "Source already present at $SRC_DIR — skipping clone (resumable behavior)."
else
  log "Cloning $REPO_URL (shallow) into $SRC_DIR ..."
  git clone --depth 1 "$REPO_URL" "$SRC_DIR"
fi
ACE_COMMIT="$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
log "ACE-Step-1.5 commit: $ACE_COMMIT"

# --- Step 4: venv + dependencies -----------------------------------------
log "Step 4/7: Python environment (pinned to $PYTHON_VERSION)"
cd "$SRC_DIR"
if [[ "$USE_UV" == "1" ]]; then
  if [[ -d ".venv" && "$FORCE" != "1" ]]; then
    log "venv already present at $SRC_DIR/.venv — skipping creation, running uv sync to reconcile (fast if already up to date)."
  else
    log "Creating venv pinned to Python $PYTHON_VERSION via uv (downloads an isolated interpreter if needed — sidesteps this machine's system Python 3.14, which is outside ACE-Step-1.5's <3.13 ceiling)..."
    # --clear is safe here unconditionally: this branch only runs when either
    # .venv doesn't exist yet (nothing to clear) or FORCE=1 (clearing is the point).
    uv venv --python "$PYTHON_VERSION" .venv --clear
  fi
  log "Running uv sync (installs torch/mlx/mlx-lm/transformers/diffusers/fastapi/... — several GB, one-time)..."
  uv sync
else
  if [[ ! -d ".venv" || "$FORCE" == "1" ]]; then
    python3 -m venv .venv
  fi
  # shellcheck disable=SC1091
  source .venv/bin/activate
  log "Installing dependencies via pip (uv unavailable — slower path)..."
  pip install --upgrade pip
  pip install -e .
fi
RESOLVED_PY_VERSION="$(cd "$SRC_DIR" && { [[ "$USE_UV" == "1" ]] && uv run python -c 'import platform; print(platform.python_version())' || .venv/bin/python -c 'import platform; print(platform.python_version())'; })"
log "Resolved interpreter: Python $RESOLVED_PY_VERSION"

run_python() {
  if [[ "$USE_UV" == "1" ]]; then
    (cd "$SRC_DIR" && uv run python "$@")
  else
    (cd "$SRC_DIR" && .venv/bin/python "$@")
  fi
}

run_download() {
  if [[ "$USE_UV" == "1" ]]; then
    (cd "$SRC_DIR" && uv run acestep-download "$@")
  else
    (cd "$SRC_DIR" && .venv/bin/acestep-download "$@")
  fi
}

# --- Step 5: model weights ------------------------------------------------
log "Step 5/7: model weights -> $CHECKPOINTS_DIR"
mkdir -p "$CHECKPOINTS_DIR"
export ACESTEP_CHECKPOINTS_DIR="$CHECKPOINTS_DIR"

download_check() {
  local model_name="$1" arg_skip_main="$2"
  log "Ensuring '$model_name' is present (huggingface, auto-fallback to modelscope)..."
  local extra=()
  [[ "$arg_skip_main" == "1" ]] && extra+=(--skip-main)
  # Stream stdout/stderr live (clear progress on a multi-GB download) while
  # ALSO teeing to a temp file so we can grep it afterward for a gated/auth
  # failure signature. `set -o pipefail` (part of `set -euo pipefail` above)
  # is required for `if ! cmd | tee ...; then` to reflect cmd's own exit
  # status rather than tee's.
  local tmp_output
  tmp_output="$(mktemp)"
  # ${extra[@]+"${extra[@]}"} (not the bare "${extra[@]}") is required because
  # this machine's default /bin/bash is 3.2 (Apple froze it pre-GPLv3), which
  # treats expanding an EMPTY array under `set -u` as an unbound-variable
  # error — the "+"-guarded form is the standard portable workaround.
  if ! run_download --model "$model_name" --dir "$CHECKPOINTS_DIR" ${extra[@]+"${extra[@]}"} 2>&1 \
      | tee "$tmp_output"; then
    if grep -qiE "gated|401|403|authentication" "$tmp_output"; then
      rm -f "$tmp_output"
      die "Download of '$model_name' looks gated/unauthenticated. See the NOTE at the top of this script — run 'huggingface-cli login' or set HF_TOKEN, then re-run install.sh (it will resume)."
    fi
    rm -f "$tmp_output"
    die "Download of '$model_name' failed. Re-run install.sh to resume (huggingface_hub resumes partial downloads); check network connectivity."
  fi
  rm -f "$tmp_output"
  # Size/checksum sanity: a real weights file must exist and be non-trivial
  # in size (upstream ships no published checksums for these repos, so we
  # check presence + a >1 MB floor rather than a bit-exact hash).
  local dir="$CHECKPOINTS_DIR/$model_name"
  # Accept both single-file weights (model.safetensors, pytorch_model.bin, …)
  # and SHARDED repos (model-0000N-of-0000M.safetensors + a small index json —
  # the index alone is never >1 MB, so the check must look at the shards).
  local found=0
  local weights_file
  weights_file=$(find "$dir" -maxdepth 1 -type f \( -name "*.safetensors" -o -name "pytorch_model*.bin" \) -size +1M 2>/dev/null | head -1)
  if [[ -n "$weights_file" ]]; then
    local size
    size=$(stat -f%z "$weights_file" 2>/dev/null || stat -c%s "$weights_file" 2>/dev/null || echo 0)
    found=1
    log "  sanity OK: $(basename "$weights_file") ($((size / 1024 / 1024)) MB)"
  fi
  if [[ "$found" != "1" ]]; then
    die "'$model_name' downloaded but no weights file over 1 MB was found under $dir — looks corrupt/incomplete. Re-run install.sh to retry."
  fi
}

# First call downloads the shared "main" bundle too (VAE, text encoder,
# default 2B turbo, default 1.7B LM) unless already present.
download_check "${DIT_MODELS[0]}" 0
download_check "${DIT_MODELS[1]}" 1
download_check "$LM_MODEL" 1

# --- Step 6: self-check ---------------------------------------------------
log "Step 6/7: self-check — import the installed runtime, resolve model paths"
if ! SELF_CHECK_JSON="$(run_python -c "
from acestep.model_downloader import get_checkpoints_dir, check_model_exists, check_main_model_exists
import json, sys
d = get_checkpoints_dir('$CHECKPOINTS_DIR')
info = {
    'checkpointsDir': str(d),
    'mainModelPresent': check_main_model_exists(d),
    'ditModels': {
        'acestep-v15-xl-turbo': {'present': check_model_exists('acestep-v15-xl-turbo', d), 'path': str(d / 'acestep-v15-xl-turbo')},
        'acestep-v15-xl-sft': {'present': check_model_exists('acestep-v15-xl-sft', d), 'path': str(d / 'acestep-v15-xl-sft')},
    },
    'lmModel': {'name': '$LM_MODEL', 'present': check_model_exists('$LM_MODEL', d), 'path': str(d / '$LM_MODEL')},
    'vaePath': str(d / 'vae'),
    'textEncoderPath': str(d / 'Qwen3-Embedding-0.6B'),
}
all_present = (
    info['mainModelPresent']
    and all(m['present'] for m in info['ditModels'].values())
    and info['lmModel']['present']
)
print(json.dumps(info, indent=2))
sys.exit(0 if all_present else 1)
")"; then
  echo "$SELF_CHECK_JSON"
  die "self-check reports a missing model after download — see JSON above. Re-run install.sh to retry the missing piece."
fi
echo "$SELF_CHECK_JSON"

# --- Step 7: write the install marker -------------------------------------
log "Step 7/7: writing install marker -> $MARKER"
cat > "$MARKER" <<EOF
{
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "aceStepCommit": "$ACE_COMMIT",
  "pythonVersion": "$RESOLVED_PY_VERSION",
  "checkpointsDir": "$CHECKPOINTS_DIR",
  "ditModels": ["acestep-v15-xl-turbo", "acestep-v15-xl-sft"],
  "lmModel": "$LM_MODEL",
  "defaultDitModel": "acestep-v15-xl-turbo",
  "apiPort": 8001
}
EOF

log "Install complete. Start the sidecar with: $SCRIPT_DIR/run.sh"
log "Or from the app/MCP: the ai.sidecarStart control command / ai_sidecar_start MCP tool."
