#!/bin/bash
# _orphans.sh — list staging DAWApp processes that are still alive.
#
# WHY THIS IS IN THE REPO (m23-ac-2c). A gate-run leak check is a verification
# instrument, and this one has now been wrong in BOTH directions inside two
# cycles:
#
#  1. m23-ac-2a shipped a PORT-based check (`lsof -iTCP:17695`). It reported
#     "clean" while three orphans sat on the user's machine for half an hour —
#     each had lost the race to bind 17695 and kept running WITHOUT a port, so
#     the very population the leak produces was invisible to it. The USER found
#     them, not the check.
#  2. The process-based replacement then matched its OWN pipeline: `ps | grep
#     ".build/debug/DAWApp"` matches the grep, and (through rtk, which maps grep
#     to ugrep) the ugrep, and the /bin/zsh -c that carries the whole command
#     line as an argument. It reported LEAKED for all eight gates in an
#     otherwise-clean regression run, including gates whose teardown had not
#     been touched.
#
# The fix for (2) is to compare the COMMAND FIELD EXACTLY rather than searching
# the whole line: a shell whose argv merely CONTAINS the binary path has "-c" in
# field 2, so it cannot match. Field-exact beats substring whenever the haystack
# includes your own process.
#
# ⚠️ Prints pids ONLY. Killing is the caller's job, and must stay pidfile- or
#    pid-exact — never pkill/pgrep, which match on a name and would take the
#    user's live app on 17600 down with the staging one.
# ⚠️ Must go through `rtk proxy`: the rtk hook filters plain `ps` so completely
#    that it returned EMPTY with three orphans alive (m23-ac-2a).
BIN="${1:-.build/debug/DAWApp}"
rtk proxy ps -Ao pid=,command= 2>/dev/null | awk -v b="$BIN" '
  $2 == b { print $1; next }              # launched as a relative path
  $2 ~ "/" b "$" { print $1 }             # launched as an absolute path
'
