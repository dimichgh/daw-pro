#!/usr/bin/env python3
"""Re-derive every number Part 2 states, and record the COMMAND beside it.

⭐ Nothing downstream may hard-code a figure: spec.py reads MEASUREMENTS.json
and asserts every SPOKEN number against the measured one.

⚠ THE DEADLINE IS READ OFF THE LIVE ENGINE, not quoted from a design document.
`engine.performanceStats` on the STAGING app (17695) reports the block size and
sample rate the audio graph is actually running at, and a reset-windowed read
taken WHILE THE TRANSPORT PLAYS reports how many of those deadlines the app met
on this very project.

⚠ THE 45 % IS CITED, NOT RE-RUN. It was measured once, in-process, by the agent
that fixed the defect: the fix was temporarily reverted and the contention test
caught the old code losing 45 % of its increments. Two independent places in the
repository record it, and both are grepped here. The 57 % in the test's own
comment is a DIFFERENT number (the live 16-track debug figure, later
re-attributed to real dropped device cycles) and is deliberately not used.
"""
import json, os, re, subprocess, sys, time

REPO = "/Users/dsemenov/Views/daw-pro"
HERE = os.path.dirname(os.path.abspath(__file__))
DAWCTL = f"{REPO}/claude-plugin/skills/ui-capture/scripts/dawctl.mjs"
PORT = "17695"
M, CMDS = {}, {}


def sh(key, cmd):
    p = subprocess.run(["bash", "-c", cmd], cwd=REPO, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"MEASURE FAILED [{key}]: {cmd}\n{p.stderr[-1200:]}")
    CMDS[key] = cmd
    return p.stdout.strip()


def num(key, cmd):
    v = int(sh(key, cmd).split()[0])
    print(f"  {key:24s} {v:>10,}   {cmd[:64]}")
    return v


def wire(key, method, params=None):
    """⛔ STAGING ONLY. 17600 is the user's live app and is never addressed."""
    if PORT != "17695":
        sys.exit("REFUSING: staging port must be 17695")
    cmd = (f"DAW_CONTROL_PORT={PORT} node {DAWCTL} {method} "
           f"'{json.dumps(params or {})}'")
    return json.loads(sh(key, cmd))


# ── the deadline, from the running engine ──────────────────────────────────
wire("perf:reset", "engine.performanceStats", {"reset": True})
wire("perf:play", "transport.play")
time.sleep(6.0)
st = wire("perf:read", "engine.performanceStats", {"reset": False})
wire("perf:stop", "transport.stop")
wire("perf:seek", "transport.seek", {"beats": 0})

M["blockFrames"] = int(st["quantumFrames"])
M["sampleRate"] = int(st["sampleRate"])
M["blockMilliseconds"] = 1000.0 * M["blockFrames"] / M["sampleRate"]
M["windowSeconds"] = float(st["sinceResetSeconds"])
M["windowCallbacks"] = int(st["callbackCount"])
M["windowOverruns"] = int(st["overrunCount"])
M["peakCallbackMs"] = st["peakCallbackNs"] / 1e6
M["peakShareOfBudget"] = 100.0 * M["peakCallbackMs"] / M["blockMilliseconds"]
M["averageLoadPercent"] = 100.0 * float(st["averageLoad"])
# ⭐ HOW MANY SEPARATE RENDER BLOCKS THE GRAPH RUNS, DERIVED rather than
# assumed: one block is due every sampleRate/blockFrames times a second, so
# the measured call rate divided by that is the number of blocks in flight.
# perf-c's method; it lands on 6.00 here (five instrument tracks + master).
M["blocksPerSecond"] = M["sampleRate"] / M["blockFrames"]
M["callbacksPerSecond"] = M["windowCallbacks"] / M["windowSeconds"]
M["renderBlocks"] = M["callbacksPerSecond"] / M["blocksPerSecond"]
print(f"  LIVE  block {M['blockFrames']} @ {M['sampleRate']} Hz = "
      f"{M['blockMilliseconds']:.3f} ms; {M['windowCallbacks']} calls in "
      f"{M['windowSeconds']:.2f}s, {M['windowOverruns']} late, peak "
      f"{M['peakCallbackMs']:.3f} ms ({M['peakShareOfBudget']:.1f}% of budget); "
      f"{M['callbacksPerSecond']:.1f} calls/s = {M['renderBlocks']:.2f} blocks")

# ── the RT-safety audit, from the audit document itself ────────────────────
AUD = "docs/research/audit-rt-safety.md"
M["auditDate"] = sh("auditDate", f"grep -o 'Date: [0-9-]*' {AUD} | head -1").split()[-1]
M["auditViolations"] = int(re.search(r"Violations: (\d+)", sh(
    "auditViolations", f"grep -o 'Violations: [0-9]*' {AUD} | head -1")).group(1))
M["auditWatch"] = int(re.search(r"Watch list \((\d+)\)", sh(
    "auditWatch", f"grep -o 'Watch list ([0-9]*)' {AUD} | head -1")).group(1))
M["auditSites"] = int(re.search(r"Sites audited: (\d+)", sh(
    "auditSites", f"grep -o 'Sites audited: [0-9]*' {AUD}")).group(1))
M["auditFamilies"] = int(re.search(r"across (\d+) families", sh(
    "auditFamilies", f"grep -o 'across [0-9]* families' {AUD}")).group(1))
# ⚠ COUNT THE LIST, NOT THE TABLE CELLS. Only five table rows read WATCH (four
# distinct sites); the numbered watch LIST has six entries, because two of them
# are notes attached to rows whose verdict is SAFE. Counting cells returns 5 and
# would have "corrected" a figure that is right.
M["auditWatchListed"] = num(
    "auditWatchListed",
    f"awk '/^- \\*\\*Watch list/,/^## Teardown/' {AUD} | grep -c '^  [0-9]\\.'")
M["auditWatchCells"] = num("auditWatchCells", f"grep -c '| \\*\\*WATCH\\*\\* |' {AUD}")
if M["auditWatchListed"] != M["auditWatch"]:
    sys.exit(f"MEASURE REFUSES: header says {M['auditWatch']} watch items, "
             f"the list has {M['auditWatchListed']}")
print(f"  AUDIT {M['auditDate']}  {M['auditSites']} sites / "
      f"{M['auditFamilies']} families  violations {M['auditViolations']}  "
      f"watch {M['auditWatch']} (list) vs {M['auditWatchCells']} (table cells)")

# ── the forbidden list, from the normative section ─────────────────────────
M["forbidden"] = sh("forbidden",
                    "grep -o 'Forbidden: [^.]*' docs/ARCHITECTURE.md | head -1")

# ── the counter that lost its counts ───────────────────────────────────────
# Two independent records of the same in-process falsification.
a = sh("counterArch", "grep -o '8-thread falsification measured [0-9]* % loss' "
                      "docs/ARCHITECTURE.md")
b = sh("counterRoad", "grep -o 'test caught [0-9]* % lost increments' docs/ROADMAP.md")
pa = int(re.search(r"(\d+) %", a).group(1))
pb = int(re.search(r"(\d+) %", b).group(1))
if pa != pb:
    sys.exit(f"MEASURE REFUSES: the two records disagree, {pa} vs {pb}")
M["counterLossPercent"] = pa
M["counterThreads"] = int(re.search(r"let threads = (\d+)", sh(
    "counterThreads", "grep -o 'let threads = [0-9]*' "
                      "Tests/DAWEngineTests/EnginePerformanceTests.swift")).group(1))
M["counterPerThread"] = int(re.search(r"let perThread = ([0-9_]+)", sh(
    "counterPerThread", "grep -o 'let perThread = [0-9_]*' "
                        "Tests/DAWEngineTests/EnginePerformanceTests.swift")
    ).group(1).replace("_", ""))
M["counterTotal"] = M["counterThreads"] * M["counterPerThread"]
print(f"  COUNTER {M['counterLossPercent']} % lost, recorded twice; test is "
      f"{M['counterThreads']} threads x {M['counterPerThread']:,}")

# ── the load profile (perf-c, release build) ───────────────────────────────
P = "docs/research/perf-c-load-profile.md"
M["loadTracks"] = int(re.search(r"a (\d+)-track session", sh(
    "loadTracks", f"grep -o 'a [0-9]*-track session' {P} | head -1")).group(1))
M["loadCorePercent"] = int(re.search(r"(\d+) %", sh(
    "loadCore", f"grep -o '[0-9]* % of one core' {P} | head -1")).group(1))
M["loadOfflineRealtime"] = float(re.search(r"([\d.]+)", sh(
    "loadOffline", f"grep -o '[0-9.]*× realtime' {P} | head -1")).group(1))
# ⚠ THE BOLD SPANS THE WHOLE PHRASE in perf-c -- it is "**1 % of the real-time
# budget**", NOT "**1 %**", so a pattern ending in `%\*\*` matches NOTHING and
# exits 1. The narration says "the worst single block took under one percent",
# so this figure is spoken and has to be on the record with its command.
M["loadPeakPercent"] = int(re.search(r"(\d+) %", sh(
    "loadPeak",
    f"grep -o 'per-callback peaks under \\*\\*[0-9]* %' {P}")).group(1))
# ⭐ THE RE-ATTRIBUTION (perf-d). After the counter was fixed, the reading that
# started the investigation DID NOT MOVE — so the missing calls were never lost
# counts; the machine was genuinely skipping cycles on an unoptimised build.
M["perfDebug16"] = int(re.search(r"~(\d+)/s", sh(
    "perfDebug16", f"grep -o 'N=16 still measures ~[0-9]*/s' {P}")).group(1))
M["perfRelease16"] = int(re.search(r"(\d+)/s", sh(
    "perfRelease16", f"grep -o '[0-9]*/s (100 %)' {P} | tail -1")).group(1))
M["debugSlowdown"] = int(re.search(r"(\d+)-30x", sh(
    "debugSlowdown", f"grep -o '[0-9]*-30. slower per block' {P}")).group(1)) \
    if False else None
print(f"  REATTRIB debug@16 {M['perfDebug16']}/s vs release {M['perfRelease16']}/s")

print(f"  LOAD {M['loadTracks']} tracks at {M['loadCorePercent']} % of a core; "
      f"offline {M['loadOfflineRealtime']}x realtime; "
      f"per-callback peak under {M['loadPeakPercent']} %")

# ── the corpus (context only; Part 1 owns the hook) ────────────────────────
M["engineLines"] = num("engineLines",
                       "find Sources/DAWEngine -name '*.swift' -exec cat {} + | wc -l")
M["swiftLines"] = num("swiftLines", "find Sources -name '*.swift' -exec cat {} + | wc -l")
M["commits"] = num("commits", "git log --oneline | wc -l")

# ── the demonstration ──────────────────────────────────────────────────────
dj = f"{HERE}/dropout.json"
if os.path.exists(dj):
    d = json.load(open(dj))
    if d["blockFrames"] != M["blockFrames"] or d["sampleRate"] != M["sampleRate"]:
        sys.exit("MEASURE REFUSES: the dropout was built at a different block "
                 f"size ({d['blockFrames']}@{d['sampleRate']}) than the engine "
                 f"reports ({M['blockFrames']}@{M['sampleRate']}) — re-run "
                 "dropout.py with the live figure")
    M["dropout"] = d

ids = json.load(open(f"{HERE}/ids.json"))
M["demo"] = {"tempoBPM": ids["tempo"], "tracks": len(ids["noteCounts"]),
             "notes": sum(ids["noteCounts"].values()),
             "noteCounts": ids["noteCounts"]}

M["_commands"] = CMDS
json.dump(M, open(f"{HERE}/MEASUREMENTS.json", "w"), indent=1)
print(f"\n  wrote MEASUREMENTS.json  ({len(CMDS)} recorded commands)")
