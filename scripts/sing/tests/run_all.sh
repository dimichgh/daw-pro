#!/bin/bash
#
# The scripts/sing test suite, in its two passes (item p2-sing-b):
#   pass 1  stdlib: /usr/bin/python3 -m unittest discover -p 'test_*.py', with SING_TESTS_REQUIRE_MACHINE=1 (a missing
#           machine input - the installed runtime's uv, CPython and upstream files the fixture mirror is built from,
#           ffmpeg - FAILS instead of skipping). The test_venv_* modules skip here: they need the runtime's packages.
#   pass 2  venv: <runtime venv python> -m unittest discover -p 'test_venv_*.py', with SING_TESTS_REQUIRE_VENV=1 (a
#           missing package or data FAILS instead of skipping).
# So no gate can pass by skipping. Neither pass touches the network. Machine inputs come from the INSTALLED singing
# runtime (~/Library/Application Support/DAWPro/SingingEngine), which both passes only READ (no bytecode, every cache
# in the temp folder); never from the spike folder, which is being deleted (W8-SFIX, 2026-10-06).
#
# Environment (all optional):
#   SING_TEST_RUNTIME   the installed runtime to read inputs from (default: the one above)
#   SING_TEST_VENV_PY   the venv python for pass 2 (default: the runtime's venv/bin/python, used READ-ONLY)
#   SING_TEST_NLTK      NLTK data for pass 2 (default: the runtime's nltk_data)
#   SING_TEST_UPSTREAM  a SoulX-Singer checkout (default: the runtime's upstream), read only
#   SING_TEST_TMP       where temp folders go (default: a new folder under $TMPDIR)
#   SING_TEST_LOG_DIR   where stdlib.log and venv.log go (default: SING_TEST_TMP)
# Exit 0 iff both passes pass and no test process was left running.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
export SING_TEST_RUNTIME="${SING_TEST_RUNTIME:-$HOME/Library/Application Support/DAWPro/SingingEngine}"
VENV_PY="${SING_TEST_VENV_PY:-$SING_TEST_RUNTIME/venv/bin/python}"
NLTK="${SING_TEST_NLTK:-$SING_TEST_RUNTIME/nltk_data}"
export SING_TEST_UPSTREAM="${SING_TEST_UPSTREAM:-$SING_TEST_RUNTIME/upstream}"
export SING_TEST_TMP="${SING_TEST_TMP:-$(mktemp -d "${TMPDIR:-/tmp}/sing tests.XXXXXX")}"
LOGS="${SING_TEST_LOG_DIR:-$SING_TEST_TMP}"
mkdir -p "$SING_TEST_TMP" "$LOGS"
export PYTHONDONTWRITEBYTECODE=1          # never a __pycache__ in the repo or in a read-only venv
export MPLCONFIGDIR="$SING_TEST_TMP/cache/mpl" NUMBA_CACHE_DIR="$SING_TEST_TMP/cache/numba"
unset PYTHONPATH PYTHONHOME PYTORCH_ENABLE_MPS_FALLBACK SING_TESTS_REQUIRE_VENV SING_TESTS_REQUIRE_MACHINE

# Test processes this suite can leave behind if a test is broken; compared before and after (pid sets).
suspects() {
  /bin/ps -Ao pid=,command= | awk -v here="$HERE" '
    index($0, "stub_server.py") || index($0, "install.sh") || index($0, "hf_fetch.py") || index($0, "nltk_fetch.py") {
      if (!index($0, "awk -v here")) print $1 }' | sort -n
}
# Positive control for that probe: the same ps | awk shape must see this very script.
if [[ -z "$(/bin/ps -Ao pid=,command= | awk -v me="run_all.sh" 'index($0, me) && !index($0, "awk -v me") { print $1 }')" ]]; then
  echo "run_all.sh: the process probe cannot see this script; refusing to report on leftovers." >&2
  exit 3
fi
BEFORE="$(suspects | tr '\n' ' ')"

cd "$HERE"
echo "pass 1: stdlib, $(/usr/bin/python3 --version 2>&1) at /usr/bin/python3 -> $LOGS/stdlib.log"
SING_TESTS_REQUIRE_MACHINE=1 /usr/bin/python3 -m unittest discover -s "$HERE" -t "$HERE" -p 'test_*.py' -v \
  > "$LOGS/stdlib.log" 2>&1
RC1=$?
grep -E '^(Ran |OK|FAILED)' "$LOGS/stdlib.log"

echo "pass 2: venv, $("$VENV_PY" --version 2>&1) at $VENV_PY -> $LOGS/venv.log"
SING_TESTS_REQUIRE_VENV=1 NLTK_DATA="$NLTK" "$VENV_PY" -m unittest discover -s "$HERE" -t "$HERE" -p 'test_venv_*.py' -v \
  > "$LOGS/venv.log" 2>&1
RC2=$?
grep -E '^(Ran |OK|FAILED)' "$LOGS/venv.log"

AFTER="$(suspects | tr '\n' ' ')"
LEFT=""
for p in $AFTER; do
  case " $BEFORE " in *" $p "*) ;; *) LEFT="$LEFT $p" ;; esac
done
if [[ -n "$LEFT" ]]; then
  echo "LEFT RUNNING by this suite:" >&2
  /bin/ps -o pid,ppid,command -p "$(echo $LEFT | tr ' ' ',')" >&2
fi
# Positive control for the __pycache__ probe: the same find shape must see the venv's own (read-only) caches.
VENV_LIB="$(cd "$(dirname "$VENV_PY")/.." && pwd)/lib"
if [[ -z "$(/usr/bin/find "$VENV_LIB" -maxdepth 4 -name __pycache__ -print | head -n 1)" ]]; then
  echo "run_all.sh: the __pycache__ probe cannot see the venv's caches under $VENV_LIB; its 'none' would mean nothing." >&2
  RC3=1
elif [[ -n "$(/usr/bin/find "$HERE/.." -name __pycache__ -print)" ]]; then
  echo "a __pycache__ appeared under scripts/sing:" >&2
  /usr/bin/find "$HERE/.." -name __pycache__ -print >&2
  RC3=1
else
  RC3=0
fi
echo "stdlib exit $RC1, venv exit $RC2, leftovers '${LEFT# }', pycache exit $RC3"
[[ $RC1 -eq 0 && $RC2 -eq 0 && -z "$LEFT" && $RC3 -eq 0 ]]
