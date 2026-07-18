#!/usr/bin/env bash
#
# RVC voice-conversion sidecar installer — M10 (m10-p-2), see
# docs/research/spike-m10p-vc.md (the "2026-07-17 continuation" +
# "Exact install shape for p-2" sections) for the full rationale: engine
# choice, measured RTFs, asset sizes/hashes, and the install-shape deltas
# this script bakes in.
#
# WHAT THIS INSTALLS:
#   - The MLX RVC fork (Acelogic/Retrieval-based-Voice-Conversion-MLX) at a
#     PINNED commit (see PINNED_COMMIT below), cloned at install time on the
#     user's machine — mirrors the ace-step precedent (we never vendor the
#     engine source into this repo).
#   - A Python 3.11 venv via uv (`uv venv` + `uv sync` against the fork's
#     uv.lock — 91 packages, plain PyPI, deterministic; proven recipe from
#     the spike), plus fastapi/uvicorn for the facade server (the fork does
#     not declare them).
#   - The 4 shared, speaker-agnostic neural assets from IAHispano/Applio
#     (MIT, ~775 MB total): RMVPE pitch extractor, ContentVec/HuBERT content
#     encoder (+config), and the generic RVC v2 base pretrains f0G40k/f0D40k
#     (training-initialization weights — NOT a usable voice). Reuses the
#     durable cache at ~/.cache/huggingface/daw-pro-rvc when present
#     (sha256-verified), downloads resumably when absent.
#   - Derived artifacts: contentvec model.safetensors (CVE-2025-32434
#     workaround — see Stage 6) and the MLX-native weight conversions
#     rmvpe_mlx.npz / hubert_mlx.npz / base_f0G40k.npz (the MLX runtime does
#     not consume raw .pt/.bin/.pth — spike delta #3).
#
# WHAT THIS NEVER INSTALLS:
#   - NO voice models of any kind. NO celebrity/third-party-person
#     checkpoints, EVER (hard project rule — the fork's own README
#     demo/benchmark voices are celebrity models and are off-limits).
#     Real target voices arrive ONLY via training on the user's own
#     recordings (m10-p-5/p-6); the voice store starts empty.
#   - fcpe.pt (alternate pitch extractor, ~41 MB): deliberately skipped —
#     RMVPE is the only pitch method the fork's MLX path supports
#     (`--f0_method {rmvpe}`), so fcpe would be dead weight (spike finding).
#
# LICENSE SHIPPING GATE (documented, unresolved as of 2026-07-17):
#   The pinned fork has NO LICENSE file anywhere in its tree; its
#   pyproject.toml self-declares MIT but GitHub's license detector reports
#   licenseInfo: null (re-verified 2026-07-17, spike doc "License re-check").
#   Before SHIPPING anything derived from the fork's code, either get a real
#   LICENSE grant added upstream or fall back to Applio's MIT-licensed code
#   paths. The model ASSETS are fine — they come from IAHispano/Applio,
#   which is MIT with a real LICENSE file.
#
# PINNED COMMIT rationale: eec7791a59eb09d0f56f1189df55e9852848e692 is BOTH
#   the fork's current main HEAD (latest as of 2026-07-17; the repo's
#   2026-03-05 push did not move main) AND the exact commit every m10-p-1
#   spike measurement validated (RMVPE 94.8x / HuBERT 574x / full pipeline
#   38x warm RTF on this hardware class). Pinning means upstream force-pushes
#   or future commits can never silently change what we install.
#
# NEEDS THE USER IF THIS HAPPENS: all 5 asset files are public on
# HuggingFace (no token, no gate). If a download fails, the historical cause
# on this machine was a corp TLS-interception proxy window that blocks HF's
# LFS/CDN payloads (see the spike doc's "Network workarounds" section) — the
# error message below names the exact URL/size/target so the file can be
# fetched manually from an unrestricted network and dropped into place, then
# this script re-run (it resumes; it never hangs or silently retry-loops).
#
# Idempotent: safe to re-run. A completed install fast-no-ops via the
# .install-state.json marker; an interrupted run resumes (every stage
# re-checks what already exists before doing work). Set FORCE=1 to redo.
#
# Env overrides:
#   RVC_RUNTIME_DIR       default: <this dir>/runtime
#   RVC_PYTHON_VERSION    default: 3.11
#   RVC_ASSET_CACHE       default: ~/.cache/huggingface/daw-pro-rvc/IAHispano-Applio/Resources
#   FORCE=1               re-run every stage even if already done
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${RVC_RUNTIME_DIR:-$SCRIPT_DIR/runtime}"
SRC_DIR="$RUNTIME_DIR/src"
VOICES_DIR="$RUNTIME_DIR/voices"
OUT_DIR="$RUNTIME_DIR/out"
LOGS_DIR="$RUNTIME_DIR/logs"
MARKER="$SCRIPT_DIR/.install-state.json"
PYTHON_VERSION="${RVC_PYTHON_VERSION:-3.11}"
FORCE="${FORCE:-0}"

REPO_URL="https://github.com/Acelogic/Retrieval-based-Voice-Conversion-MLX.git"
PINNED_COMMIT="eec7791a59eb09d0f56f1189df55e9852848e692"

ASSET_CACHE="${RVC_ASSET_CACHE:-$HOME/.cache/huggingface/daw-pro-rvc/IAHispano-Applio/Resources}"
HF_BASE="https://huggingface.co/IAHispano/Applio/resolve/main/Resources"

log() { printf '==> %s\n' "$1"; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

STAGE_T0=$SECONDS
stage_done() { log "    (stage wall: $((SECONDS - STAGE_T0))s)"; STAGE_T0=$SECONDS; }

log "RVC voice-conversion sidecar install starting ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
log "Runtime dir: $RUNTIME_DIR"
log "Asset cache: $ASSET_CACHE"

if [[ "$FORCE" != "1" && -f "$MARKER" ]]; then
  log "Already installed (marker found at $MARKER) — nothing to do."
  log "Set FORCE=1 to re-verify/re-convert anyway."
  cat "$MARKER"
  exit 0
fi

# --- Stage 1/8: disk space sanity ----------------------------------------
log "Stage 1/8: disk space check"
AVAIL_KB=$(df -Pk "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
log "Free space at $SCRIPT_DIR: ${AVAIL_GB} GB"
if (( AVAIL_GB < 6 )); then
  die "Need at least ~6 GB free (1 GB venv + ~1.2 GB assets incl. derived safetensors + ~0.6 GB MLX conversions + headroom); only ${AVAIL_GB} GB available. Free up space and re-run."
fi
stage_done

# --- Stage 2/8: package manager (uv) --------------------------------------
log "Stage 2/8: locating uv (Astral's Python package/venv manager)"
if ! command -v uv &>/dev/null; then
  if [[ -x "$HOME/.local/bin/uv" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
  elif [[ -x "$HOME/.cargo/bin/uv" ]]; then
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
fi
# Unlike the ace-step installer there is NO system-python fallback here:
# the only proven recipe for this stack is uv's isolated Python 3.11 +
# `uv sync` against the fork's uv.lock (spike delta #5 — reproduced exactly,
# zero drift). This machine's system python3 is 3.14.x, untested for this
# stack (torch 2.4.0 pin, numba 0.60, faiss-cpu 1.7.4), so a pip fallback
# would ship an unproven install path.
if ! command -v uv &>/dev/null; then
  die "uv is required (the proven install recipe is 'uv venv --python 3.11' + 'uv sync' against the fork's lockfile). Install it: curl -LsSf https://astral.sh/uv/install.sh | sh — then re-run this script."
fi
log "uv found: $(uv --version)"
stage_done

# --- Stage 3/8: pinned engine clone ---------------------------------------
log "Stage 3/8: engine source (pinned commit ${PINNED_COMMIT:0:12})"
mkdir -p "$RUNTIME_DIR"
if [[ -d "$SRC_DIR/.git" ]]; then
  HAVE_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [[ "$HAVE_COMMIT" == "$PINNED_COMMIT" ]]; then
    log "Source already present at $SRC_DIR at the pinned commit — skipping clone."
  else
    die "Source at $SRC_DIR is at commit $HAVE_COMMIT, not the pinned $PINNED_COMMIT. Move that directory aside (e.g. 'mv $SRC_DIR $SRC_DIR.bak') and re-run — this installer never rewrites an existing checkout's git state."
  fi
else
  # `git clone --revision=<sha>` (git >= 2.49) clones directly at the pinned
  # commit with no post-clone checkout/reset needed. Older gits fall back to
  # a plain clone, which is then VERIFIED against the pin (today the pin IS
  # main's HEAD, so the fallback works until upstream moves).
  log "Cloning $REPO_URL at $PINNED_COMMIT into $SRC_DIR ..."
  if ! git clone --depth 1 --revision="$PINNED_COMMIT" "$REPO_URL" "$SRC_DIR" 2>/dev/null; then
    log "git clone --revision unsupported by this git ($(git --version)) — falling back to plain clone + pin verification."
    rm -rf "$SRC_DIR"
    git clone --depth 1 "$REPO_URL" "$SRC_DIR"
    HAVE_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
    if [[ "$HAVE_COMMIT" != "$PINNED_COMMIT" ]]; then
      rm -rf "$SRC_DIR"
      die "Upstream main has moved to $HAVE_COMMIT but this installer pins $PINNED_COMMIT, and this git is too old for 'git clone --revision'. Update git to >= 2.49, or fetch the pinned snapshot manually: curl -L https://github.com/Acelogic/Retrieval-based-Voice-Conversion-MLX/archive/$PINNED_COMMIT.tar.gz | tar xz, and place the extracted tree at $SRC_DIR."
    fi
  fi
fi
RVC_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo "$PINNED_COMMIT")"
log "Engine commit: $RVC_COMMIT"
stage_done

# --- Stage 4/8: venv + dependencies ---------------------------------------
log "Stage 4/8: Python environment (pinned to $PYTHON_VERSION)"
cd "$SRC_DIR"
if [[ -d ".venv" && "$FORCE" != "1" ]]; then
  log "venv already present at $SRC_DIR/.venv — skipping creation, running uv sync to reconcile (fast if already up to date)."
else
  log "Creating venv pinned to Python $PYTHON_VERSION via uv (isolated interpreter — sidesteps system Python 3.14, untested for this stack)..."
  uv venv --python "$PYTHON_VERSION" .venv --clear
fi
log "Running uv sync (torch 2.4.0 / mlx / transformers / faiss-cpu / librosa / ... — 91 packages against the fork's uv.lock, one-time ~1 GB)..."
uv sync
VENV_PY="$SRC_DIR/.venv/bin/python"
RESOLVED_PY_VERSION="$("$VENV_PY" -c 'import platform; print(platform.python_version())')"
log "Resolved interpreter: Python $RESOLVED_PY_VERSION"

# Facade extras: the fork does not declare fastapi/uvicorn — install them
# into the venv AFTER uv sync (a later bare `uv run`/`uv sync` would strip
# them again, which is why run.sh and every python call below use the venv
# interpreter directly, never a re-syncing `uv run`).
if "$VENV_PY" -c 'import fastapi, uvicorn' &>/dev/null; then
  log "Facade extras (fastapi/uvicorn) already importable — skipping."
else
  log "Installing facade extras (fastapi, uvicorn) into the venv..."
  uv pip install --python "$VENV_PY" fastapi uvicorn
fi
stage_done

# --- Stage 5/8: shared neural assets --------------------------------------
log "Stage 5/8: shared neural assets (durable cache: $ASSET_CACHE)"
# The 4 required speaker-agnostic assets (5 files) from IAHispano/Applio.
# sha256 values are the spike doc's recorded ground truth (asset acquisition
# record, 2026-07-17). fcpe.pt is intentionally NOT here — see header.
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

ensure_asset() {
  local subpath="$1" expected_sha="$2" expected_bytes="$3"
  local target="$ASSET_CACHE/$subpath"
  local url="$HF_BASE/$subpath"
  if [[ -f "$target" ]]; then
    log "  $subpath: present in cache — verifying sha256..."
    local have_sha
    have_sha="$(sha256_of "$target")"
    if [[ "$have_sha" == "$expected_sha" ]]; then
      log "  $subpath: sha256 OK (reusing cached copy)"
      return 0
    fi
    log "  $subpath: sha256 MISMATCH (have $have_sha) — discarding cached copy and re-downloading."
    rm -f "$target"
  fi
  mkdir -p "$(dirname "$target")"
  log "  $subpath: downloading ($expected_bytes bytes) from $url ..."
  # -C - resumes a partial .part; --speed-limit/--speed-time abort a stalled
  # transfer (<1 KB/s for 60 s) rather than hanging; --retry covers blips.
  # NEVER a silent retry-loop: on failure we stop with the manual recipe.
  if ! curl -fL -C - --retry 3 --retry-delay 2 --connect-timeout 15 \
        --speed-limit 1024 --speed-time 60 -# \
        -o "$target.part" "$url"; then
    die "Could not download $subpath ($expected_bytes bytes) from $url. Historical cause on this machine: a corp TLS-interception proxy window that blocks HuggingFace LFS/CDN payloads (small API endpoints still work — see docs/research/spike-m10p-vc.md 'Network workarounds'). Fix: retry from an unrestricted network, or download the file manually (same URL, it is public — no token) and place it at $target, then re-run this script (it resumes; partial file kept at $target.part)."
  fi
  local got_sha
  got_sha="$(sha256_of "$target.part")"
  if [[ "$got_sha" != "$expected_sha" ]]; then
    rm -f "$target.part"
    die "Downloaded $subpath has sha256 $got_sha, expected $expected_sha (recorded in docs/research/spike-m10p-vc.md). The transfer may have been tampered with or truncated — re-run this script; if it persists, download manually from $url and verify before placing at $target."
  fi
  mv "$target.part" "$target"
  log "  $subpath: downloaded + sha256 OK"
}

ensure_asset "predictors/rmvpe.pt"                    "6d62215f4306e3ca278246188607209f09af3dc77ed4232efdd069798c4ec193" "181184272"
ensure_asset "embedders/contentvec/pytorch_model.bin" "d8dd400e054ddf4e6be75dab5a2549db748cc99e756a097c496c099f65a4854e" "378342945"
ensure_asset "embedders/contentvec/config.json"       "2ddde063b795d38d9051a7215a092fecf4cfe148b54251e38de51d88d356898b" "1388"
ensure_asset "pretrained_v2/f0G40k.pth"               "3b2c44035e782c4b14ddc0bede9e2f4a724d025cd073f736d4f43708453adfcb" "73106273"
ensure_asset "pretrained_v2/f0D40k.pth"               "6b6ab091e70801b28e3f41f335f2fc5f3f35c75b39ae2628d419644ec2b0fa09" "142875703"
# fcpe.pt (~41 MB) intentionally skipped: RMVPE is the fork's only supported
# MLX pitch method — fetching fcpe would be dead weight (spike finding).

# Symlink the cached assets into the paths the fork's loaders/tools resolve
# (all relative to the src root — verified against rvc/lib/utils.py
# load_embedding and tools/convert_rmvpe.py at the pinned commit).
log "Symlinking cached assets into the engine tree..."
mkdir -p "$SRC_DIR/rvc/models/predictors" "$SRC_DIR/rvc/models/embedders/contentvec" "$SRC_DIR/rvc/models/pretraineds/pretrained_v2"
ln -sfn "$ASSET_CACHE/predictors/rmvpe.pt"                    "$SRC_DIR/rvc/models/predictors/rmvpe.pt"
ln -sfn "$ASSET_CACHE/embedders/contentvec/pytorch_model.bin" "$SRC_DIR/rvc/models/embedders/contentvec/pytorch_model.bin"
ln -sfn "$ASSET_CACHE/embedders/contentvec/config.json"       "$SRC_DIR/rvc/models/embedders/contentvec/config.json"
ln -sfn "$ASSET_CACHE/pretrained_v2/f0G40k.pth"               "$SRC_DIR/rvc/models/pretraineds/pretrained_v2/f0G40k.pth"
ln -sfn "$ASSET_CACHE/pretrained_v2/f0D40k.pth"               "$SRC_DIR/rvc/models/pretraineds/pretrained_v2/f0D40k.pth"
stage_done

# --- Stage 6/8: CVE-2025-32434 safetensors derivation ---------------------
log "Stage 6/8: contentvec model.safetensors (CVE-2025-32434 workaround)"
# MANDATORY (spike delta #2): under the pinned torch 2.4.0, transformers
# 4.57.x REFUSES `torch.load` of a .bin (CVE-2025-32434 guard requires
# torch >= 2.6), so the first-run HuBERT conversion in Stage 7 would fail.
# Deriving model.safetensors next to the .bin makes from_pretrained take the
# safetensors (safe) path. Derived once into the durable cache, symlinked in.
SAFETENSORS_PATH="$ASSET_CACHE/embedders/contentvec/model.safetensors"
ST_SIZE=$(stat -f%z "$SAFETENSORS_PATH" 2>/dev/null || echo 0)
# Presence + size floor (the spike's derivation was 378,298,184 B; safetensors
# byte layout is not guaranteed identical across torch versions, so no sha pin).
if [[ -f "$SAFETENSORS_PATH" && "$ST_SIZE" -gt 350000000 ]]; then
  log "model.safetensors already derived in cache ($ST_SIZE bytes) — skipping."
else
  log "Deriving model.safetensors from pytorch_model.bin (torch.load weights_only=True -> safetensors.torch.save_file)..."
  OMP_NUM_THREADS=1 "$VENV_PY" - "$ASSET_CACHE/embedders/contentvec/pytorch_model.bin" "$SAFETENSORS_PATH" <<'PYEOF'
import sys
import torch
from safetensors.torch import save_file

bin_path, out_path = sys.argv[1], sys.argv[2]
sd = torch.load(bin_path, map_location="cpu", weights_only=True)
sd = {k: v.contiguous() for k, v in sd.items() if isinstance(v, torch.Tensor)}
save_file(sd, out_path)
print(f"wrote {out_path} ({len(sd)} tensors)")
PYEOF
fi
ln -sfn "$SAFETENSORS_PATH" "$SRC_DIR/rvc/models/embedders/contentvec/model.safetensors"
stage_done

# --- Stage 7/8: MLX weight conversions ------------------------------------
log "Stage 7/8: MLX-native weight conversions (spike delta #3)"
# The MLX runtime consumes .npz, not raw .pt/.bin/.pth. Output paths below
# are the loader paths verified at the pinned commit. OMP_NUM_THREADS=1 is
# the faiss segfault guard (spike delta #4) — set on every venv python run.
RMVPE_NPZ="$SRC_DIR/rvc_mlx/models/predictors/rmvpe_mlx.npz"
HUBERT_NPZ="$SRC_DIR/rvc/models/embedders/contentvec/hubert_mlx.npz"
BASE_NPZ="$SRC_DIR/rvc_mlx/models/checkpoints/base_f0G40k.npz"

npz_present() { # path, min-bytes
  local sz
  sz=$(stat -f%z "$1" 2>/dev/null || echo 0)
  [[ -f "$1" && "$sz" -gt "$2" ]]
}

if npz_present "$RMVPE_NPZ" 150000000; then
  log "rmvpe_mlx.npz already present — skipping."
else
  log "Converting RMVPE -> $RMVPE_NPZ ..."
  (cd "$SRC_DIR" && OMP_NUM_THREADS=1 "$VENV_PY" tools/convert_rmvpe.py)
  npz_present "$RMVPE_NPZ" 150000000 || die "convert_rmvpe.py ran but $RMVPE_NPZ is missing/undersized — inspect the tool output above and re-run."
fi

if npz_present "$HUBERT_NPZ" 300000000; then
  log "hubert_mlx.npz already present — skipping."
else
  log "Converting ContentVec/HuBERT -> $HUBERT_NPZ ..."
  (cd "$SRC_DIR" && OMP_NUM_THREADS=1 "$VENV_PY" tools/convert_hubert.py)
  npz_present "$HUBERT_NPZ" 300000000 || die "convert_hubert.py ran but $HUBERT_NPZ is missing/undersized — inspect the tool output above and re-run."
fi

# Base (untrained, generic 109-speaker) synthesizer: the facade's
# voiceId "base" smoke target — the spike's proven sid=0 end-to-end path.
# This is NOT a voice and NOT a training artifact; per-VOICE
# convert_pth_to_mlx.py runs belong to p-5/p-6 when trained voices exist.
if npz_present "$BASE_NPZ" 50000000; then
  log "base_f0G40k.npz already present — skipping."
else
  log "Converting base pretrain f0G40k.pth -> $BASE_NPZ ..."
  mkdir -p "$(dirname "$BASE_NPZ")"
  (cd "$SRC_DIR" && OMP_NUM_THREADS=1 "$VENV_PY" tools/convert_pth_to_mlx.py "$ASSET_CACHE/pretrained_v2/f0G40k.pth" "$BASE_NPZ")
  npz_present "$BASE_NPZ" 50000000 || die "convert_pth_to_mlx.py ran but $BASE_NPZ is missing/undersized — inspect the tool output above and re-run."
fi
stage_done

# --- Stage 8/8: self-check + voice store + marker -------------------------
log "Stage 8/8: self-check — import the runtime, verify every artifact"
mkdir -p "$VOICES_DIR" "$OUT_DIR" "$LOGS_DIR"
if ! SELF_CHECK_JSON="$(cd "$SRC_DIR" && OMP_NUM_THREADS=1 "$VENV_PY" - "$SRC_DIR" "$VOICES_DIR" <<'PYEOF'
import json, os, sys

src_dir, voices_dir = sys.argv[1], sys.argv[2]
os.chdir(src_dir)
sys.path.insert(0, src_dir)

def entry(path, floor):
    size = os.path.getsize(path) if os.path.exists(path) else 0
    return {"path": path, "bytes": size, "present": size > floor}

info = {
    "assets": {
        "rmvpe.pt": entry("rvc/models/predictors/rmvpe.pt", 150_000_000),
        "contentvec.bin": entry("rvc/models/embedders/contentvec/pytorch_model.bin", 300_000_000),
        "contentvec.config": entry("rvc/models/embedders/contentvec/config.json", 100),
        "contentvec.safetensors": entry("rvc/models/embedders/contentvec/model.safetensors", 300_000_000),
        "f0G40k.pth": entry("rvc/models/pretraineds/pretrained_v2/f0G40k.pth", 50_000_000),
        "f0D40k.pth": entry("rvc/models/pretraineds/pretrained_v2/f0D40k.pth", 100_000_000),
    },
    "mlxArtifacts": {
        "rmvpe_mlx.npz": entry("rvc_mlx/models/predictors/rmvpe_mlx.npz", 150_000_000),
        "hubert_mlx.npz": entry("rvc/models/embedders/contentvec/hubert_mlx.npz", 300_000_000),
        "base_f0G40k.npz": entry("rvc_mlx/models/checkpoints/base_f0G40k.npz", 50_000_000),
    },
    "voicesDir": voices_dir,
}

import mlx.core as mx
info["mlxDevice"] = str(mx.default_device())
import fastapi, uvicorn
info["fastapi"] = fastapi.__version__
info["uvicorn"] = uvicorn.__version__
# Import the inference entry point (pulls in soundfile/librosa/synthesizer
# graph code) — proves the venv can actually host the engine.
from rvc_mlx.infer.infer_mlx import RVC_MLX  # noqa: F401
info["engineImport"] = "ok"

ok = all(e["present"] for grp in ("assets", "mlxArtifacts") for e in info[grp].values())
print(json.dumps(info, indent=2))
sys.exit(0 if ok else 1)
PYEOF
)"; then
  echo "$SELF_CHECK_JSON"
  die "self-check reports a missing/undersized artifact — see JSON above. Re-run install.sh to retry the missing piece."
fi
echo "$SELF_CHECK_JSON"

log "Writing install marker -> $MARKER"
FASTAPI_VERSION="$("$VENV_PY" -c 'import fastapi; print(fastapi.__version__)')"
cat > "$MARKER" <<EOF
{
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "rvcMlxCommit": "$RVC_COMMIT",
  "pythonVersion": "$RESOLVED_PY_VERSION",
  "fastapiVersion": "$FASTAPI_VERSION",
  "srcDir": "$SRC_DIR",
  "assetCache": "$ASSET_CACHE",
  "voicesDir": "$VOICES_DIR",
  "baseModel": "$BASE_NPZ",
  "apiPort": 8002
}
EOF
stage_done

log "Install complete. Start the facade with: $SCRIPT_DIR/run.sh"
log "Total wall: ${SECONDS}s"
