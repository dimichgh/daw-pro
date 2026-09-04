#!/usr/bin/env bash
# Upload every finished film whose FILENAME contains a string, one after the
# other, taking each film's metadata from the sidecar that shortsmith wrote
# beside it.
#
#   ./scripts/upload-batch.sh "DAW Pro Short"
#   ./scripts/upload-batch.sh --dry-run "DAW Pro Lesson"
#
# Why this exists: publish.py deliberately takes ONE --film and ONE --meta, so
# a batch is a shell loop, and a shell loop over a directory of films is where
# the two expensive mistakes live -- uploading the same video twice, and
# sweeping up neighbouring files that were never part of this batch. Both are
# handled here rather than left to whoever types the loop.
#
# ⚠ AN UPLOAD IS NOT UNDOABLE FROM HERE. YouTube will cheerfully accept the
# same film ten times and give you ten videos. That is why every success is
# written to a ledger and a filename already in the ledger is SKIPPED, not
# re-sent. Delete the ledger line (or pass --redo) if you really mean it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$HERE/.venv/bin/python3"
PUBLISH="$HERE/scripts/publish.py"

DIR="$HOME/Movies"
LEDGER=""
DRY=0
ASSUME_YES=0
REDO=0
MATCH=""
PASSTHRU=()

die() { printf "\033[31mERROR: %s\033[0m\n" "$*" >&2; exit 1; }
say() { printf "\n\033[1m==> %s\033[0m\n" "$*"; }

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

  <match>            substring matched against the FILE NAME (not the path)

  --dir DIR          where the films are (default: ~/Movies)
  --ledger FILE      upload record (default: <dir>/.uploaded.tsv)
  --dry-run          hand --dry-run to publish.py; no network, nothing uploaded
  --redo             upload even if the ledger already lists the file
  --yes              do not ask for confirmation before starting
  --client-secret F  passed through to publish.py
  --token F          passed through to publish.py
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)      usage ;;
    --dir)          DIR="$2"; shift 2 ;;
    --ledger)       LEDGER="$2"; shift 2 ;;
    --dry-run)      DRY=1; shift ;;
    --redo)         REDO=1; shift ;;
    --yes|-y)       ASSUME_YES=1; shift ;;
    --client-secret|--token) PASSTHRU+=("$1" "$2"); shift 2 ;;
    -*)             die "unknown option $1 (try --help)" ;;
    *)              [[ -n "$MATCH" ]] && die "give exactly one match string"
                    MATCH="$1"; shift ;;
  esac
done

[[ -n "$MATCH" ]] || die "no match string. Example: $(basename "$0") \"DAW Pro Short\""
[[ -x "$PY"    ]] || die "interpreter not found: $PY — run ./install.sh --publish first."
[[ -f "$PUBLISH" ]] || die "publish.py not found next to this script."
[[ -d "$DIR"   ]] || die "no such directory: $DIR"
[[ -n "$LEDGER" ]] || LEDGER="$DIR/.uploaded.tsv"
touch "$LEDGER"

# ---------------------------------------------------------------- the batch
# ⚠ A PLAIN `for f in *.mp4` SORTS "Short 10" BEFORE "Short 2". That is only
# cosmetic here, but a batch you cannot read is a batch you cannot check, and
# checking the list is the whole point of the confirmation below. -V sorts the
# embedded numbers the way a person reads them.
# ⚠ macOS ships bash 3.2, which has no `mapfile` -- the first version of this
# script used it and died on line 1 of the search with "command not found".
# Stay 3.2-compatible: NUL-delimited find | sort -z -V | read loop.
# ⚠ THIS SEARCH IS A FUNCTION ON PURPOSE, and the reason is worth keeping.
# bash 3.2 (which is what macOS ships) scans a <( ... ) body for its closing
# paren LEXICALLY -- it does not respect a `)` that belongs to a case pattern,
# and it does not even respect one inside a COMMENT. Both spellings I tried
# inline died with a syntax error that pointed at the wrong line. A function
# body is parsed normally, so put the logic here and keep the substitution
# down to a bare call.
list_matching() {
  find "$DIR" -maxdepth 1 -type f -name '*.mp4' -print0 |
  while IFS= read -r -d '' g; do
    if [[ "$(basename "$g")" == *"$MATCH"* ]]; then printf '%s\0' "$g"; fi
  done | sort -z -V
}

FOUND=()
while IFS= read -r -d '' f; do FOUND+=("$f"); done < <(list_matching)
((${#FOUND[@]})) || die "nothing in $DIR matches \"$MATCH\"."

QUEUE=(); SKIP=(); NOMETA=()
for f in "${FOUND[@]}"; do
  b="$(basename "$f")"
  m="${f%.mp4}.publish.json"
  if [[ ! -f "$m" ]]; then NOMETA+=("$b"); continue; fi
  # A film is "done" when its exact basename appears in the ledger's 3rd column.
  if [[ $REDO -eq 0 ]] && awk -F'\t' -v n="$b" '$3==n{found=1} END{exit !found}' "$LEDGER"; then
    SKIP+=("$b"); continue
  fi
  QUEUE+=("$f")
done

say "matched \"$MATCH\" in $DIR"
((${#SKIP[@]}))   && { echo "  already uploaded (in the ledger), skipping:";
                       printf '    - %s\n' "${SKIP[@]}"; }
((${#NOMETA[@]})) && { printf "\033[33m  no .publish.json sidecar — NOT uploading:\033[0m\n";
                       printf '    - %s\n' "${NOMETA[@]}"; }
((${#QUEUE[@]}))  || { echo; echo "nothing left to upload."; exit 0; }

echo "  to upload, in this order:"
i=0; for f in "${QUEUE[@]}"; do i=$((i+1)); printf '    %2d. %s\n' "$i" "$(basename "$f")"; done

# ---------------------------------------------------- validate BEFORE any network
# Cheap, offline, and it is the difference between finding a bad sidecar now and
# finding it after eleven uploads have already gone out.
say "validating all ${#QUEUE[@]} sidecars offline first"
bad=0
for f in "${QUEUE[@]}"; do
  if ! out=$("$PY" "$PUBLISH" validate --film "$f" --meta "${f%.mp4}.publish.json" 2>&1); then
    printf "\033[31m  ✘ %s\033[0m\n%s\n" "$(basename "$f")" "$out"; bad=$((bad+1))
  fi
done
((bad == 0)) || die "$bad sidecar(s) failed validation. Nothing was uploaded."
echo "  all ${#QUEUE[@]} valid"

if [[ $DRY -eq 0 && $ASSUME_YES -eq 0 ]]; then
  echo
  read -r -p "Upload these ${#QUEUE[@]} videos now? [y/N] " ans
  [[ "$ans" == [yY] || "$ans" == [yY][eE][sS] ]] || { echo "aborted; nothing uploaded."; exit 1; }
fi

# ------------------------------------------------------------------- upload
n=0; ok=0
for f in "${QUEUE[@]}"; do
  n=$((n+1)); b="$(basename "$f")"
  say "[$n/${#QUEUE[@]}] $b"
  # ⚠ Under `set -u`, bash 3.2 treats an EMPTY array's "${a[@]}" as unbound and
  # aborts -- so the no-passthrough case, which is the common one, was the
  # broken one. The +"…" form expands to nothing when the array is empty.
  args=(upload --film "$f" --meta "${f%.mp4}.publish.json" ${PASSTHRU[@]+"${PASSTHRU[@]}"})
  ((DRY)) && args+=(--dry-run)
  # Both at once: the upload's progress must stream to the screen (it is a
  # multi-minute network call), AND the printed video id has to be captured for
  # the ledger. `tee /dev/tty` did both until it met a shell with no
  # controlling terminal, where it fails and -- with pipefail -- aborted the
  # whole batch before the first upload. Tee to a FILE: same live output, no
  # terminal required. pipefail still carries publish.py's exit status out.
  log="$(mktemp -t uploadbatch)"
  if ! "$PY" "$PUBLISH" "${args[@]}" 2>&1 | tee "$log"; then
    printf "\033[31m\nSTOPPED at %s. %d uploaded, %d not attempted.\033[0m\n" \
      "$b" "$ok" "$((${#QUEUE[@]} - n))" >&2
    rm -f "$log"; exit 1
  fi
  ok=$((ok+1))
  if ((DRY == 0)); then
    url=$(sed -n 's|.*\(https://youtu\.be/[A-Za-z0-9_-]*\).*|\1|p' "$log" | tail -1)
    printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${url:-unknown}" "$b" >> "$LEDGER"
  fi
  rm -f "$log"
done

say "done: $ok/${#QUEUE[@]} $( ((DRY)) && echo "dry-run" || echo "uploaded" )"
((DRY == 0)) && echo "  ledger: $LEDGER"
exit 0
