#!/usr/bin/env bash
# Install the voice + video kit: a local speech server, the three models, and
# the ffmpeg the assembler needs. Apple Silicon macOS — the models are MLX.
#
#   ./install.sh              # venv + omlx + prefetch all three models
#   ./install.sh --no-models  # skip the ~8 GB download
#   ./install.sh --publish    # ALSO install the YouTube upload dependencies
#
# Flags combine: ./install.sh --no-models --publish
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$HERE/.venv"
SKIP_MODELS=0
WANT_PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --no-models) SKIP_MODELS=1 ;;
    --publish)   WANT_PUBLISH=1 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

say() { printf "\n\033[1m==> %s\033[0m\n" "$*"; }
die() { printf "\033[31mERROR: %s\033[0m\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- prequisites
say "checking prerequisites"
[[ "$(uname -s)" == "Darwin" ]] || die "macOS only — the models are MLX builds."
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon required (MLX has no Intel build)."
command -v python3 >/dev/null || die "python3 not found."
command -v ffmpeg  >/dev/null || die "ffmpeg not found — 'brew install ffmpeg'."
command -v ffprobe >/dev/null || die "ffprobe not found — 'brew install ffmpeg'."
# ⚠ node is deliberately NOT required. It was, while this kit shipped the DAW
# Pro capture scripts; those are app-specific and no longer live here, so the
# pipeline is python + ffmpeg only. Do not re-add the check without re-adding a
# script that needs it.
echo "  python3 $(python3 -V 2>&1 | cut -d' ' -f2), ffmpeg present"

FREE_GB=$(df -g "$HOME" | awk 'NR==2 {print $4}')
if [[ $SKIP_MODELS -eq 0 && ${FREE_GB:-0} -lt 20 ]]; then
  die "only ${FREE_GB}GB free; the models need about 8GB plus working room."
fi

# ---------------------------------------------------------------------- venv
# ⚠ MEASURED: `omlx` is NOT on PyPI. `pip install omlx` fails with "No matching
# distribution found" — it installs only from its git repository. That one line
# is why this script exists at all.
say "creating the virtualenv"
# omlx declares requires-python >=3.11. Prefer a 3.11-3.13 interpreter when one
# is present: some published revisions also cap it at <3.14, and a plain
# `python3` here can easily be newer than that.
PYBIN=""
# omlx's published bound is >=3.11,<3.14. Prefer an interpreter inside it;
# `python3` last, because on a current macOS it is very likely 3.14+.
for c in python3.13 python3.12 python3.11 python3; do
  command -v "$c" >/dev/null || continue
  "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' || continue
  PYBIN="$c"; break
done
[[ -n "$PYBIN" ]] || die "need python 3.11 or newer (found $(python3 -V 2>&1))."
echo "  building the venv with $PYBIN ($("$PYBIN" -V 2>&1))"
[[ -d "$VENV" ]] || "$PYBIN" -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip

say "installing omlx (local OpenAI-compatible speech server)"
OMLX_GIT="git+https://github.com/jundot/omlx"
# ⚠ THIS SCRIPT IS RE-RUN, most often to add --publish to a working install.
# It used to attempt the omlx install every time and dead-end on a
# requires-python bound that had ALREADY been worked around on the first run --
# so a user with a perfectly good venv was told their Python was wrong and
# never reached the flag they actually asked for. Measured 2026-09-04 on
# python 3.14.6 with omlx 0.6.4 already installed.
if [[ -x "$VENV/bin/omlx" ]]; then
  echo "  already installed: $("$VENV/bin/omlx" --version 2>/dev/null || echo omlx)"
elif ! "$VENV/bin/pip" install --quiet "omlx@${OMLX_GIT}"; then
  # A revision with an upper Python bound refuses a newer interpreter. Running
  # past it is measured-good on 3.14 on the machine this kit came from, so try
  # it rather than dead-ending -- but say so out loud.
  printf "\033[33m  requires-python refused this interpreter; retrying past the bound\033[0m\n"
  "$VENV/bin/pip" install --quiet --ignore-requires-python "omlx@${OMLX_GIT}" \
    || die "pip install omlx failed. Clone https://github.com/jundot/omlx and 'pip install -e' it."
fi
"$VENV/bin/omlx" --version 2>/dev/null || echo "  omlx installed"

# ⚠ numpy and Pillow are dependencies of THIS KIT, not of omlx. They arrive
# today only because omlx happens to pull them in transitively -- MEASURED: a
# fresh venv here had both, and neither was ever asked for. brand.py,
# channel.py and verify.py all break without them, so ask explicitly rather
# than inheriting them by luck from someone else's dependency tree.
say "installing the kit's own dependencies"
# ⚠ soundfile belongs here too, and its absence was found the hard way:
# `brand.py intro --audio` reads the sting to drive the bar animation, so on a
# venv with only numpy+Pillow the OUTRO renders fine and the INTRO dies with
# ModuleNotFoundError. A partial success is the failure mode this installer
# exists to prevent.
"$VENV/bin/pip" install --quiet numpy Pillow soundfile \
  || die "pip install numpy Pillow soundfile failed."

# The YouTube publisher is OPTIONAL and deliberately not part of the default
# install: uploading is a different job from making the film, and most users of
# this kit never upload from it. publish.py's `validate` and `--dry-run` work
# without these; only the network path needs them.
if [[ $WANT_PUBLISH -eq 1 ]]; then
  say "installing YouTube upload dependencies (--publish)"
  "$VENV/bin/pip" install --quiet google-api-python-client google-auth-oauthlib \
    || die "pip install google-api-python-client google-auth-oauthlib failed."
  "$VENV/bin/python" -c 'import googleapiclient, google_auth_oauthlib' \
    || die "the Google client libraries did not import after installing."
fi

# Smoke-check the imports the scripts actually make. An installer that reports
# success and leaves a venv that cannot render a title card is worse than one
# that fails.
"$VENV/bin/python" - <<'PYCHECK' || die "the venv is missing a module the scripts need."
import sys
missing = []
for m in ("numpy", "PIL", "soundfile"):
    try:
        __import__(m)
    except ImportError:
        missing.append(m)
if missing:
    print("  MISSING:", ", ".join(missing)); sys.exit(1)
print("  numpy, Pillow and soundfile import cleanly")
PYCHECK

# --------------------------------------------------------------------- models
# ⚠ These are NOT vendored. Together they are about 8 GB, which does not belong
# in a git repository. They are pulled from Hugging Face on first use; this step
# just does it up front so the first render is not a surprise download.
TTS=mlx-community/VoxCPM2-bf16                      # speaks every line (clone)
VOICE=mlx-community/OmniVoice-bf16                  # designs a voice from text
STT=mlx-community/whisper-large-v3-turbo-asr-fp16   # gates every take

if [[ $SKIP_MODELS -eq 0 ]]; then
  say "downloading models (~8 GB: 4.6 + 2.0 + 1.5)"
  "$VENV/bin/pip" install --quiet "huggingface_hub[cli]"
  for m in "$TTS" "$VOICE" "$STT"; do
    echo "  $m"
    # `hf` is the current CLI; huggingface_hub < 0.34 only ships `huggingface-cli`.
    if [[ -x "$VENV/bin/hf" ]]; then HF="$VENV/bin/hf"; else HF="$VENV/bin/huggingface-cli"; fi
    "$HF" download "$m" >/dev/null || die "download failed: $m"
  done
else
  say "skipping model download (--no-models)"
fi

cat <<EOF

$(printf "\033[1mInstalled.\033[0m")

Start the server (leave it running):
    $VENV/bin/omlx serve --port 8000

Then, from this directory:
    # 1. optional — design a new narrator instead of the bundled one
    $VENV/bin/python scripts/design-voice.py --out voices/

    # 2. narration: one wav per stage id in your manifest
    OUT_DIR=./vo MANIFEST=./example/manifest.json \\
      $VENV/bin/python scripts/narrate.py

    # 3. assemble
    $VENV/bin/python scripts/assemble.py --manifest ./example/manifest.json \\
      --vo ./vo --out ~/Movies/film.mp4 --shots ./shots --loops ./loops

⚠ The server holds tens of GB of memory while reporting about 1 GB resident.
  Stop it when you are done, by PORT rather than by name:
      lsof -nP -iTCP:8000 -sTCP:LISTEN     # find the pid
      kill <pid>
EOF
