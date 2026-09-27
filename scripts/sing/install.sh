#!/bin/bash
#
# DAW Pro singing engine installer (design docs/design/2026-09-27-p2-sing-integration.md §2.5; item p2-sing-b).
#
# It installs SoulX-Singer at the pins in pins.env into $SING_RUNTIME_DIR (the app passes the profile-aware
# <Application Support>/DAWPro/SingingEngine; this script never guesses it). Consent is the app's business: this
# script is only ever started after the user clicked Install.
#
# Guarantees:
#   * IDEMPOTENT: every step checks its own output first and prints "@@skip <step>" when it still verifies.
#   * STAGED: downloads land in $SING_RUNTIME_DIR/.staging-<uuid>/ and move into place only after verification.
#     (One exception, by necessity: uv installs CPython straight into <runtime>/python, with its own temp+rename,
#     because the venv records the interpreter's absolute path. Python alone never makes the runtime "installed".)
#   * THE MARKER IS LAST: install.json is deleted before the first change and written only after every step
#     verified, so a cancelled or failed run leaves nothing that looks installed.
#   * CANCELLABLE: SIGTERM/SIGINT stops the running step's whole process group, deletes staging, prints
#     "@@cancelled <step>" and exits 143. Staging is gone BEFORE that line is printed.
#   * QUOTED: "Application Support" has a space. Every path is quoted, and nothing runs through a console-script
#     shebang: python runs as `"$PY" -m ...` / `"$PY" script.py`, never `pip` or `hf`.
#
# Machine-readable lines on stdout (SingingEngineInstaller parses them; human text goes to stderr):
#   @@step <name> <i>/<n>     a step started          @@skip <name>            it already verified
#   @@bytes <done> <total>    download progress        @@free <kb>              free space (preflight)
#   @@error <name> <message>  failed (exit 1)          @@cancelled <name>       cancelled (exit 143)
#   @@done <installedBytes>   finished (exit 0)
# Steps: preflight uv python venv upstream weights nltk voice finish.
#
# Usage: SING_RUNTIME_DIR=<dir> install.sh [--adopt-weights <path to model.pt>]
#   --adopt-weights  a local model.pt with the pinned size and sha256 is APFS-cloned (cp -c) instead of downloaded.
#                    A one-time convenience for this Mac and the spike's copy; never exposed on the wire.
# Tests only: SING_INSTALL_SOURCE=<local mirror> together with SING_PINS_FILE=<fixture pins>. Every download then
# comes from the mirror (file://, uv offline), and install.json records "source": "fixture".
#
# Exit codes: 0 done, 1 a step failed, 2 bad usage/config, 75 another install is running, 143 cancelled.
set -uo pipefail
set -m   # job control: each long step runs in its OWN process group, so a cancel can stop its whole tree

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
STEPS=(preflight uv python venv upstream weights nltk voice finish)
N_STEPS=${#STEPS[@]}
STEP_I=0
STEP_NAME=start
CHILD=""
STAGING=""
LOCKED=0
MARKER_INVALIDATED=0
CHANGED=0

emit() { printf '%s\n' "$*"; }
say() { printf 'install.sh: %s\n' "$*" >&2; }
fail() { emit "@@error $STEP_NAME $*"; say "step '$STEP_NAME' failed: $*"; exit 1; }
usage_fail() { say "$*"; exit 2; }

ADOPT_WEIGHTS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --adopt-weights) [[ $# -ge 2 ]] || usage_fail "--adopt-weights needs a path"; ADOPT_WEIGHTS="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) usage_fail "unknown argument '$1'" ;;
  esac
done

# ------------------------------------------------------------------------------------------------ pins (never sourced)
PINS_FILE="${SING_PINS_FILE:-$SCRIPT_DIR/pins.env}"
# ANSI-C quoting so the pattern can name the single quote: no quote of either kind, $, backquote or backslash in a value.
PIN_RE=$'^([A-Z][A-Za-z0-9_]*)=("([^"$`\\\']*)"|([^[:space:]"$`\\\'#]*))$'
load_pins() {
  local line n=0
  [[ -f "$PINS_FILE" ]] || usage_fail "no pins file at '$PINS_FILE'"
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" =~ $PIN_RE ]]; then
      printf -v "PIN_${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
    else
      usage_fail "pins file '$PINS_FILE' line $n is not KEY=value"
    fi
  done < "$PINS_FILE"
}
pin() { local v="PIN_$1"; printf '%s' "${!v:-}"; }
need_pins() { local k; for k in "$@"; do [[ -n "$(pin "$k")" ]] || usage_fail "pin $k is missing or empty in '$PINS_FILE'"; done; }

load_pins
need_pins SCRIPTS_VERSION UV_VERSION UV_ASSET UV_URL UV_SHA256 PYTHON_VERSION LOCK_FILE UPSTREAM_URL UPSTREAM_COMMIT \
  WEIGHTS_REPO WEIGHTS_REVISION MODEL_FILE MODEL_BYTES MODEL_SHA256 CONFIG_FILE CONFIG_BYTES CONFIG_SHA256 \
  NLTK_PACKAGES BUILTIN_VOICE_ID BUILTIN_SOURCE_AUDIO BUILTIN_SOURCE_META BUILTIN_CUT_START BUILTIN_CUT_END \
  BUILTIN_WAV_SHA256 BUILTIN_META_SHA256 BUILTIN_PCM_SHA256 MIN_MACOS MIN_FREE_KB FFMPEG_LIB_DIR

# ------------------------------------------------------------------------------------------------ test mode
SRC="${SING_INSTALL_SOURCE:-}"
SOURCE_KIND=network
if [[ -n "$SRC" || -n "${SING_PINS_FILE:-}" ]]; then
  [[ -n "$SRC" && -n "${SING_PINS_FILE:-}" ]] || usage_fail "SING_INSTALL_SOURCE and SING_PINS_FILE are for tests and go together"
  [[ -d "$SRC" ]] || usage_fail "SING_INSTALL_SOURCE '$SRC' is not a folder"
  SRC="$(cd "$SRC" && pwd -P)"
  SOURCE_KIND=fixture
  say "TEST MODE: every download comes from the local mirror '$SRC' (pins '$PINS_FILE')"
fi

LOCK_PATH="$(pin LOCK_FILE)"
[[ "$LOCK_PATH" == /* ]] || LOCK_PATH="$SCRIPT_DIR/$LOCK_PATH"
[[ -f "$LOCK_PATH" ]] || usage_fail "the lock file '$LOCK_PATH' is missing"

# ------------------------------------------------------------------------------------------------ runtime + lock
[[ -n "${SING_RUNTIME_DIR:-}" && "${SING_RUNTIME_DIR}" == /* ]] || usage_fail "SING_RUNTIME_DIR must be an absolute path"
mkdir -p "$SING_RUNTIME_DIR" || usage_fail "cannot create '$SING_RUNTIME_DIR'"
RUNTIME="$(cd "$SING_RUNTIME_DIR" && pwd -P)"
LOCKDIR="$RUNTIME/.install.lock"
MARKER="$RUNTIME/install.json"
STAMPS="$RUNTIME/.stamps"

cleanup() {
  if [[ -n "$STAGING" && -d "$STAGING" ]]; then rm -rf "$STAGING"; fi
  if [[ "$LOCKED" == 1 && -f "$LOCKDIR/pid" && "$(cat "$LOCKDIR/pid")" == "$$" ]]; then rm -rf "$LOCKDIR"; fi
}
kill_child() {
  [[ -n "$CHILD" ]] || return 0
  kill -TERM -- "-$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 -- "-$CHILD" 2>/dev/null || break
    sleep 0.5
  done
  kill -KILL -- "-$CHILD" 2>/dev/null
  wait "$CHILD" 2>/dev/null
  CHILD=""
}
on_cancel() {
  trap '' TERM INT
  say "cancelled during step '$STEP_NAME'"
  kill_child
  if [[ -n "$STAGING" && -d "$STAGING" ]]; then rm -rf "$STAGING"; fi
  emit "@@cancelled $STEP_NAME"
  exit 143
}
trap cleanup EXIT
trap on_cancel TERM INT

if mkdir "$LOCKDIR" 2>/dev/null; then
  echo "$$" > "$LOCKDIR/pid"; LOCKED=1
else
  OTHER="$(tr -cd '0-9' < "$LOCKDIR/pid" 2>/dev/null)"
  if [[ -n "$OTHER" ]] && kill -0 "$OTHER" 2>/dev/null && ps -p "$OTHER" -o command= | grep -q 'install\.sh'; then
    emit "@@error preflight another install is running (pid $OTHER)"
    say "another install is running (pid $OTHER)"
    exit 75
  fi
  say "clearing a stale install lock (pid '${OTHER}')"
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" || { say "cannot take the install lock"; exit 75; }
  echo "$$" > "$LOCKDIR/pid"; LOCKED=1
fi
for d in "$RUNTIME"/.staging-*; do [[ -d "$d" ]] && { say "removing leftover staging '$d'"; rm -rf "$d"; }; done
STAGING="$RUNTIME/.staging-$(/usr/bin/uuidgen)"
mkdir "$STAGING" || fail "cannot create the staging folder"

# ------------------------------------------------------------------------------------------------ helpers
begin_step() { STEP_I=$((STEP_I + 1)); STEP_NAME="$1"; emit "@@step $STEP_NAME $STEP_I/$N_STEPS"; }
skip_step() { emit "@@skip $STEP_NAME"; }
# Before the FIRST change to the runtime, the old marker goes: nothing half-changed may look installed.
changing() {
  CHANGED=1
  if [[ "$MARKER_INVALIDATED" == 0 ]]; then rm -f "$MARKER"; MARKER_INVALIDATED=1; fi
}
# Run "$@" as its own process group and wait (interruptibly: a cancel lands between the wait and the next line).
run() {
  "$@" < /dev/null &
  CHILD=$!
  local rc=0
  wait "$CHILD" || rc=$?
  CHILD=""
  return $rc
}
# hash_file <file> sets HASH. It is called directly, never inside $(...): a command substitution is a subshell, and
# a cancel would then wait out a whole 2.8 GB hash. Here the hash is a cancellable job like any other step.
HASH=""
hash_file() {
  local out="$STAGING/.sha.$$"
  HASH=""
  run /usr/bin/shasum -a 256 "$1" > "$out" || { rm -f "$out"; return 1; }
  HASH="$(cut -d ' ' -f 1 < "$out")"
  rm -f "$out"
}
hash_is() { hash_file "$1" && [[ "$HASH" == "$2" ]]; }   # hash_is <file> <pinned sha256>
file_id() { stat -f '%z %m %i' "$1"; }
stamp_ok() { [[ -f "$STAMPS/$1" && "$(cat "$STAMPS/$1")" == "$2" ]]; }
stamp_put() { mkdir -p "$STAMPS" && printf '%s' "$2" > "$STAMPS/$1"; }
url_path() {   # percent-encode a filesystem path for a file:// URL, byte by byte (bash 3.2: mask the sign)
  local LC_ALL=C
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9/._~-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' $(( $(printf '%d' "'$c") & 255 )))" ;;
    esac
  done
  printf '%s' "$out"
}
fetch() {   # fetch <mirror name> <url> <dest> <sha256> [<bytes>]: curl, https only (file:// in test mode)
  local name="$1" url="$2" dest="$3" sha="$4" bytes="${5:-0}" proto='=https'
  if [[ -n "$SRC" ]]; then url="file://$(url_path "$SRC/$name")"; proto='=file'; fi
  /usr/bin/curl --fail --location --silent --show-error --proto "$proto" --proto-redir "$proto" --retry 3 \
    --output "$dest" "$url" < /dev/null &
  CHILD=$!
  while kill -0 "$CHILD" 2>/dev/null; do
    if [[ "$bytes" -gt 0 && -f "$dest" ]]; then emit "@@bytes $(stat -f %z "$dest") $bytes"; fi
    sleep 0.5
  done
  local rc=0
  wait "$CHILD" || rc=$?
  CHILD=""
  [[ $rc -eq 0 ]] || { say "download of $name failed (curl exit $rc)"; return 1; }
  hash_is "$dest" "$sha" || { say "$name sha256 '$HASH', pinned $sha"; return 1; }
}

UV_VER="$(pin UV_VERSION)"
PY_VER="$(pin PYTHON_VERSION)"
PY_MM="${PY_VER%.*}"
UV="$RUNTIME/bin/uv"
PY_BASE="$RUNTIME/python/cpython-$PY_VER-macos-aarch64-none/bin/python$PY_MM"
VENV_PY="$RUNTIME/venv/bin/python"
LOCK_SHA="$(/usr/bin/shasum -a 256 "$LOCK_PATH" | cut -d ' ' -f 1)"
PINS_SHA="$(/usr/bin/shasum -a 256 "$PINS_FILE" | cut -d ' ' -f 1)"

# uv, git and huggingface_hub see only what this script sets: the caller's config never leaks in.
export UV_CACHE_DIR="$RUNTIME/cache/uv" UV_PYTHON_INSTALL_DIR="$RUNTIME/python" UV_PYTHON_BIN_DIR="$RUNTIME/python/bin"
export UV_NO_CONFIG=1 UV_NO_PROGRESS=1
unset UV_INDEX_URL UV_EXTRA_INDEX_URL UV_DEFAULT_INDEX UV_INDEX UV_FIND_LINKS UV_PYTHON UV_CONFIG_FILE PYTHONPATH PYTHONHOME
export HF_HOME="$RUNTIME/cache/hf" HF_HUB_DISABLE_TELEMETRY=1
export MPLCONFIGDIR="$RUNTIME/cache/mpl" NUMBA_CACHE_DIR="$RUNTIME/cache/numba" XDG_CACHE_HOME="$RUNTIME/cache/xdg"
export TORCH_HOME="$RUNTIME/cache/torch" MODELSCOPE_CACHE="$RUNTIME/cache/modelscope" PYTHONNOUSERSITE=1
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PYTORCH_ENABLE_MPS_FALLBACK
if [[ -n "$SRC" ]]; then export UV_OFFLINE=1; fi

# ================================================================================================ 1 preflight
begin_step preflight
[[ "$(uname -m)" == "arm64" ]] || fail "this Mac is not Apple silicon (arm64)"
MACOS_MAJOR="$(sw_vers -productVersion | cut -d . -f 1)"
[[ "$MACOS_MAJOR" =~ ^[0-9]+$ && "$MACOS_MAJOR" -ge "$(pin MIN_MACOS)" ]] || fail "macOS $(sw_vers -productVersion) is older than $(pin MIN_MACOS)"
FREE_KB="$(df -Pk "$RUNTIME" | awk 'NR == 2 { print $4 }')"
emit "@@free $FREE_KB"
[[ "$FREE_KB" =~ ^[0-9]+$ && "$FREE_KB" -ge "$(pin MIN_FREE_KB)" ]] || fail "only ${FREE_KB} KB free on the runtime's disk; the install needs $(pin MIN_FREE_KB) KB"
touch "$RUNTIME/.write-test" && rm -f "$RUNTIME/.write-test" || fail "cannot write to '$RUNTIME'"
for tool in /usr/bin/curl /usr/bin/git /usr/bin/shasum /usr/bin/tar /usr/bin/uuidgen; do
  [[ -x "$tool" ]] || fail "missing $tool"
done
FFMPEG="${SING_FFMPEG:-}"
if [[ -z "$FFMPEG" ]]; then
  for c in "$(command -v ffmpeg || true)" /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
    if [[ -n "$c" && -x "$c" ]]; then FFMPEG="$c"; break; fi
  done
fi
[[ -n "$FFMPEG" && -x "$FFMPEG" ]] || fail "FFmpeg is required (the built-in voice is cut with it, and the engine reads audio through FFmpeg's libraries): install it with Homebrew (brew install ffmpeg)"
FFMPEG_VERSION="$("$FFMPEG" -hide_banner -version | head -n 1)"
ls "$(pin FFMPEG_LIB_DIR)"/libavutil.*.dylib > /dev/null 2>&1 || fail "FFmpeg's libraries are not in $(pin FFMPEG_LIB_DIR), where the engine's audio reader (torchcodec) looks for them"
say "preflight ok: macOS $(sw_vers -productVersion), ${FREE_KB} KB free, $FFMPEG_VERSION"

# ================================================================================================ 2 uv
begin_step uv
uv_ok() { [[ -x "$UV" ]] && [[ "$("$UV" --version 2>/dev/null | cut -d ' ' -f 1-2)" == "uv $UV_VER" ]]; }
if uv_ok; then
  skip_step
else
  changing
  mkdir -p "$STAGING/uv"
  fetch "$(pin UV_ASSET)" "$(pin UV_URL)" "$STAGING/uv/$(pin UV_ASSET)" "$(pin UV_SHA256)" || fail "could not download uv $UV_VER"
  run /usr/bin/tar -xzf "$STAGING/uv/$(pin UV_ASSET)" -C "$STAGING/uv" || fail "could not unpack uv"
  UV_NEW="$(/usr/bin/find "$STAGING/uv" -type f -name uv -perm -u+x | head -n 1)"
  [[ -n "$UV_NEW" ]] || fail "the uv archive has no uv binary"
  mkdir -p "$RUNTIME/bin" && mv -f "$UV_NEW" "$UV" || fail "could not move uv into place"
  uv_ok || fail "uv at '$UV' does not report version $UV_VER"
fi

# ================================================================================================ 3 python
begin_step python
python_ok() { [[ -x "$PY_BASE" ]] && [[ "$("$PY_BASE" -c 'import sys; print(sys.version.split()[0])' 2>/dev/null)" == "$PY_VER" ]]; }
if python_ok; then
  skip_step
else
  changing
  PY_ARGS=(python install "$PY_VER" --no-bin)
  [[ -n "$SRC" ]] && PY_ARGS+=(--python-downloads-json-url "file://$(url_path "$SRC/python/downloads.json")")
  run "$UV" "${PY_ARGS[@]}" || fail "uv could not install CPython $PY_VER"
  python_ok || fail "CPython $PY_VER is not at '$PY_BASE' after the install"
fi

# ================================================================================================ 4 venv
begin_step venv
IMPORTS="$(pin VERIFY_IMPORTS)"
venv_verify() {   # venv_verify <python> <prefix>
  run "$1" "$SCRIPT_DIR/tools/verify_venv.py" --lock "$LOCK_PATH" --python-version "$PY_VER" --prefix "$2" --imports "$IMPORTS"
}
VENV_STAMP="lock=$LOCK_SHA python=$PY_VER prefix=$RUNTIME/venv"
if [[ -x "$VENV_PY" ]] && stamp_ok venv "$VENV_STAMP" && venv_verify "$VENV_PY" "$RUNTIME/venv"; then
  skip_step
else
  changing
  run "$UV" venv --relocatable --python "$PY_BASE" "$STAGING/venv" || fail "uv could not create the venv"
  PIP_ARGS=(pip install --python "$STAGING/venv/bin/python" --no-deps -r "$LOCK_PATH")
  [[ -n "$SRC" ]] && PIP_ARGS+=(--offline --no-index --find-links "$SRC/wheels")
  run "$UV" "${PIP_ARGS[@]}" || fail "the pinned packages did not install"
  run "$UV" pip check --python "$STAGING/venv/bin/python" || fail "the installed packages are not compatible (uv pip check)"
  venv_verify "$STAGING/venv/bin/python" "$STAGING/venv" || fail "the new venv does not match the lock"
  if [[ -e "$RUNTIME/venv" ]]; then mv "$RUNTIME/venv" "$STAGING/venv-old" || fail "could not move the old venv aside"; fi
  mv "$STAGING/venv" "$RUNTIME/venv" || fail "could not move the venv into place"
  venv_verify "$VENV_PY" "$RUNTIME/venv" || fail "the venv does not work after the move"
  stamp_put venv "$VENV_STAMP"
fi

# ================================================================================================ 5 upstream
begin_step upstream
COMMIT="$(pin UPSTREAM_COMMIT)"
upstream_ok() {
  [[ -d "$RUNTIME/upstream/.git" ]] \
    && [[ "$(/usr/bin/git -C "$RUNTIME/upstream" rev-parse HEAD 2>/dev/null)" == "$COMMIT" ]] \
    && [[ -z "$(/usr/bin/git -C "$RUNTIME/upstream" status --porcelain --untracked-files=no 2>&1)" ]]
}
if upstream_ok; then
  skip_step
else
  changing
  UP_URL="$(pin UPSTREAM_URL)"
  [[ -n "$SRC" ]] && UP_URL="file://$(url_path "$SRC/upstream.git")"
  run /usr/bin/git init -q "$STAGING/upstream" || fail "git init failed"
  run /usr/bin/git -C "$STAGING/upstream" fetch -q --depth 1 "$UP_URL" "$COMMIT" || fail "could not fetch $COMMIT from $UP_URL"
  run /usr/bin/git -C "$STAGING/upstream" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD || fail "checkout failed"
  [[ "$(/usr/bin/git -C "$STAGING/upstream" rev-parse HEAD)" == "$COMMIT" ]] || fail "the checkout is not $COMMIT"
  if [[ -e "$RUNTIME/upstream" ]]; then mv "$RUNTIME/upstream" "$STAGING/upstream-old" || fail "could not move the old checkout aside"; fi
  mv "$STAGING/upstream" "$RUNTIME/upstream" || fail "could not move the checkout into place"
  upstream_ok || fail "the checkout does not verify after the move"
fi

# ================================================================================================ 6 weights
begin_step weights
MODEL="$(pin MODEL_FILE)"
CONFIG="$(pin CONFIG_FILE)"
W="$RUNTIME/weights"
weights_stamp() { printf 'model=%s %s config=%s %s' "$(file_id "$W/$MODEL")" "$(pin MODEL_SHA256)" "$(file_id "$W/$CONFIG")" "$(pin CONFIG_SHA256)"; }
weights_hash_ok() {   # weights_hash_ok <dir>: sizes, then the full sha256 of both files
  [[ -f "$1/$MODEL" && -f "$1/$CONFIG" ]] || return 1
  [[ "$(stat -f %z "$1/$MODEL")" == "$(pin MODEL_BYTES)" && "$(stat -f %z "$1/$CONFIG")" == "$(pin CONFIG_BYTES)" ]] || return 1
  hash_is "$1/$MODEL" "$(pin MODEL_SHA256)" && hash_is "$1/$CONFIG" "$(pin CONFIG_SHA256)"
}
if [[ -f "$W/$MODEL" && -f "$W/$CONFIG" ]] && stamp_ok weights "$(weights_stamp)"; then
  skip_step
elif weights_hash_ok "$W"; then
  stamp_put weights "$(weights_stamp)"
  skip_step
else
  changing
  mkdir -p "$STAGING/weights"
  ADOPTED=0
  if [[ -n "$ADOPT_WEIGHTS" ]]; then
    if [[ -f "$ADOPT_WEIGHTS" && "$(stat -f %z "$ADOPT_WEIGHTS")" == "$(pin MODEL_BYTES)" ]] \
      && hash_is "$ADOPT_WEIGHTS" "$(pin MODEL_SHA256)"; then
      if run /bin/cp -c "$ADOPT_WEIGHTS" "$STAGING/weights/$MODEL"; then
        say "adopted $ADOPT_WEIGHTS (APFS clone)"
      else
        run /bin/cp "$ADOPT_WEIGHTS" "$STAGING/weights/$MODEL" || fail "could not copy the adopted weights"
        say "adopted $ADOPT_WEIGHTS (plain copy: not the same APFS volume)"
      fi
      ADOPT_CONFIG="$(dirname "$ADOPT_WEIGHTS")/$CONFIG"
      if [[ -f "$ADOPT_CONFIG" ]] && hash_is "$ADOPT_CONFIG" "$(pin CONFIG_SHA256)"; then
        run /bin/cp "$ADOPT_CONFIG" "$STAGING/weights/$CONFIG" || fail "could not copy the adopted config"
      fi
      ADOPTED=1
    else
      say "--adopt-weights '$ADOPT_WEIGHTS' does not match the pinned size and sha256; downloading instead"
    fi
  fi
  NEED=()
  [[ -f "$STAGING/weights/$MODEL" ]] || NEED+=(--file "$MODEL:$(pin MODEL_BYTES)")
  [[ -f "$STAGING/weights/$CONFIG" ]] || NEED+=(--file "$CONFIG:$(pin CONFIG_BYTES)")
  if [[ ${#NEED[@]} -gt 0 ]]; then
    run "$VENV_PY" "$SCRIPT_DIR/tools/hf_fetch.py" --repo "$(pin WEIGHTS_REPO)" --revision "$(pin WEIGHTS_REVISION)" \
      --dest "$STAGING/weights" "${NEED[@]}" || fail "could not download the model weights"
  fi
  rm -rf "$STAGING/weights/.cache"
  weights_hash_ok "$STAGING/weights" || fail "the weights do not match their pinned size and sha256"
  if [[ -e "$W" ]]; then mv "$W" "$STAGING/weights-old" || fail "could not move the old weights aside"; fi
  mv "$STAGING/weights" "$W" || fail "could not move the weights into place"
  stamp_put weights "$(weights_stamp)"
fi

# ================================================================================================ 7 nltk
begin_step nltk
read -r -a NLTK_PKGS <<< "$(pin NLTK_PACKAGES)"
nltk_ok() {   # nltk_ok <dir>
  local p z s
  for p in "${NLTK_PKGS[@]}"; do
    z="$(pin "NLTK_ZIP_$p")"; s="$(pin "NLTK_SHA256_$p")"
    [[ -n "$z" && -n "$s" && -f "$1/$z" && -d "$1/${z%.zip}" ]] || return 1
    hash_is "$1/$z" "$s" || return 1
  done
}
if nltk_ok "$RUNTIME/nltk_data"; then
  skip_step
else
  changing
  run "$VENV_PY" "$SCRIPT_DIR/tools/nltk_fetch.py" --dest "$STAGING/nltk_data" "${NLTK_PKGS[@]}" || fail "could not download the NLTK data"
  nltk_ok "$STAGING/nltk_data" || fail "the NLTK data does not match its pinned sha256"
  if [[ -e "$RUNTIME/nltk_data" ]]; then mv "$RUNTIME/nltk_data" "$STAGING/nltk-old" || fail "could not move the old NLTK data aside"; fi
  mv "$STAGING/nltk_data" "$RUNTIME/nltk_data" || fail "could not move the NLTK data into place"
fi

# ================================================================================================ 8 voice (builtin-1)
begin_step voice
VOICE_ID="$(pin BUILTIN_VOICE_ID)"
VOICE_DIR="$RUNTIME/voices/$VOICE_ID"
voice_ok() {
  [[ -f "$1/prompt.wav" && -f "$1/prompt.json" ]] \
    && hash_is "$1/prompt.wav" "$(pin BUILTIN_WAV_SHA256)" \
    && hash_is "$1/prompt.json" "$(pin BUILTIN_META_SHA256)"
}
if voice_ok "$VOICE_DIR"; then
  skip_step
else
  changing
  mkdir -p "$STAGING/voice"
  SRC_AUDIO="$RUNTIME/upstream/$(pin BUILTIN_SOURCE_AUDIO)"
  SRC_META="$RUNTIME/upstream/$(pin BUILTIN_SOURCE_META)"
  [[ -f "$SRC_AUDIO" && -f "$SRC_META" ]] || fail "the upstream checkout has no $(pin BUILTIN_SOURCE_AUDIO)"
  # INPUT seeking (-ss/-to before -i), as the spike cut it; output seeking gives different bytes (measured).
  run "$FFMPEG" -hide_banner -nostdin -loglevel error -y -ss "$(pin BUILTIN_CUT_START)" -to "$(pin BUILTIN_CUT_END)" \
    -i "$SRC_AUDIO" -c:a pcm_f32le "$STAGING/voice/prompt.wav" || fail "ffmpeg could not cut the built-in voice"
  /bin/cp "$SRC_META" "$STAGING/voice/prompt.json" || fail "could not copy the built-in voice's labels"
  hash_file "$STAGING/voice/prompt.wav" || fail "could not hash the built-in voice"
  GOT_WAV="$HASH"
  if [[ "$GOT_WAV" != "$(pin BUILTIN_WAV_SHA256)" ]]; then
    GOT_PCM="$("$VENV_PY" -c 'import hashlib, sys; sys.path.insert(0, sys.argv[1]); from singlib import wavio; print(hashlib.sha256(wavio.data_chunk(sys.argv[2])).hexdigest())' "$SCRIPT_DIR" "$STAGING/voice/prompt.wav" 2>&1)"
    if [[ "$GOT_PCM" == "$(pin BUILTIN_PCM_SHA256)" ]]; then
      WHAT="the audio samples ARE the ones you picked; only the file header differs ($FFMPEG_VERSION wrote it; the pinned bytes came from ffmpeg 8.1.1, Lavf62.12.101)"
    else
      WHAT="the audio samples differ too (pcm sha256 $GOT_PCM), so this decoder would give you a different voice"
    fi
    fail "the built-in voice did not rebuild to the bytes you picked (sha256 $GOT_WAV, pinned $(pin BUILTIN_WAV_SHA256)): $WHAT"
  fi
  hash_is "$STAGING/voice/prompt.json" "$(pin BUILTIN_META_SHA256)" || fail "the built-in voice's labels are not the pinned zh_prompt.json"
  mkdir -p "$RUNTIME/voices"
  if [[ -e "$VOICE_DIR" ]]; then mv "$VOICE_DIR" "$STAGING/voice-old" || fail "could not move the old voice aside"; fi
  mv "$STAGING/voice" "$VOICE_DIR" || fail "could not move the built-in voice into place"
fi

# ================================================================================================ 9 finish
begin_step finish
marker_json() {   # the marker, from the MEASURED state (never from a record)
  "$VENV_PY" -c '
import json, os, sys
runtime, lock_sha, pins_sha, source, scripts, py, uv, installed = sys.argv[1:9]
model, config, commit, rev, wsha, csha, bsha, vid = sys.argv[9:17]
st = os.stat(os.path.join(runtime, "weights", model))
print(json.dumps({"facadeVersion": 1, "scriptsVersion": int(scripts), "lockSha256": lock_sha, "pinsSha256": pins_sha,
                  "commit": commit, "weightsRevision": rev, "weightsSha256": wsha, "configSha256": csha,
                  "weightsBytes": st.st_size, "weightsMtime": int(st.st_mtime), "weightsInode": st.st_ino,
                  "builtinVoiceId": vid, "builtinSha256": bsha, "pythonVersion": py, "uvVersion": uv,
                  "installedBytes": int(installed), "source": source,
                  "date": __import__("datetime").datetime.now().astimezone().isoformat(timespec="seconds")},
                 indent=1, sort_keys=True))' \
    "$RUNTIME" "$LOCK_SHA" "$PINS_SHA" "$SOURCE_KIND" "$(pin SCRIPTS_VERSION)" "$PY_VER" "$UV_VER" "$1" \
    "$MODEL" "$CONFIG" "$COMMIT" "$(pin WEIGHTS_REVISION)" "$(pin MODEL_SHA256)" "$(pin CONFIG_SHA256)" \
    "$(pin BUILTIN_WAV_SHA256)" "$VOICE_ID"
}
marker_current() {   # the existing marker names exactly this install
  [[ -f "$MARKER" ]] && "$VENV_PY" -c '
import json, sys
m = json.load(open(sys.argv[1]))
want = dict(zip(["lockSha256", "pinsSha256", "commit", "weightsSha256", "builtinSha256", "scriptsVersion", "source"],
                sys.argv[2:9]))
want["scriptsVersion"] = int(want["scriptsVersion"])
sys.exit(0 if all(m.get(k) == v for k, v in want.items()) else 1)' \
    "$MARKER" "$LOCK_SHA" "$PINS_SHA" "$COMMIT" "$(pin MODEL_SHA256)" "$(pin BUILTIN_WAV_SHA256)" \
    "$(pin SCRIPTS_VERSION)" "$SOURCE_KIND" 2>/dev/null
}
if [[ "$CHANGED" == 0 ]] && marker_current; then
  skip_step
  INSTALLED_BYTES="$("$VENV_PY" -c 'import json, sys; print(json.load(open(sys.argv[1]))["installedBytes"])' "$MARKER")"
else
  changing
  if [[ -x "$UV" ]]; then run "$UV" cache clean > /dev/null || say "uv cache clean failed (not fatal)"; fi
  rm -rf "$STAGING"
  INSTALLED_BYTES=$(( $(du -sk "$RUNTIME" | cut -f 1) * 1024 ))
  mkdir -p "$STAGING"
  marker_json "$INSTALLED_BYTES" > "$STAGING/install.json" || fail "could not write install.json"
  mv -f "$STAGING/install.json" "$MARKER" || fail "could not move install.json into place"
fi
emit "@@done $INSTALLED_BYTES"
say "installed: $RUNTIME ($INSTALLED_BYTES bytes, source $SOURCE_KIND)"
exit 0
