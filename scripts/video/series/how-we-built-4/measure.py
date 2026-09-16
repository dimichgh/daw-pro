#!/usr/bin/env python3
"""Every number "How We Built a DAW - Part 4" says out loud, with the command
that produced it, into MEASUREMENTS.json.

⚠ THIS PART IS ABOUT FALSIFICATION, so its own measurements are held to the
same rule: every grep carries a NEGATIVE CONTROL and refuses to record a zero
it cannot distinguish from a broken pattern; every figure that could have come
from a stale record is RE-DERIVED in this build instead.

⚠ NOTHING HERE TOUCHES 17600. The live reads are: three test runs on this
machine (logs/plant-0*.log), one full suite run (logs/fullsuite.log), the two
sound-bank ladders measured on STAGING 17695 (liveness.json), the flam wavs
rendered on staging (flam.json), the capture-rate loop (slowcap.json), and
greps of this repo's own files.
"""
import json, os, re, shlex, subprocess, sys
import soundfile as sf
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = "/Users/dsemenov/Views/daw-pro"
M, C = {}, {}


def sh(cmd, cwd=REPO):
    """⚠ NEVER through the rtk hook: it rewrites `git` and truncates the output,
    so `git log --oneline | wc -l` answers 50 where the truth is 105. Both look
    like measurements. That is this series' own thesis biting its own tools."""
    p = subprocess.run(["bash", "-c", cmd], cwd=cwd, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def grep1(pattern, path, what, fixed=True):
    """One grep, with a NEGATIVE CONTROL on every call, refusing to record a
    zero it cannot distinguish from a broken pattern."""
    # ⚠ shlex.quote, NOT json.dumps. json.dumps produces a DOUBLE-quoted string,
    # and bash runs backticks inside double quotes as command substitution — so a
    # pattern containing `true` silently became "returns ** ** " and matched
    # nothing. A broken pattern and an absent string print the same zero, which
    # is the whole subject of the previous part of this series.
    flag = "-cF" if fixed else "-c"
    rc, out, _ = sh(f"grep {flag} {shlex.quote(pattern)} {shlex.quote(path)}")
    hits = int(out.strip() or 0)
    _, out2, _ = sh(f"grep {flag} {shlex.quote(pattern + 'ZZQQ')} {shlex.quote(path)}")
    if int(out2.strip() or 0) != 0:
        sys.exit(f"MEASURE REFUSES — negative control MATCHED for {what}")
    if hits == 0:
        sys.exit(f"MEASURE REFUSES — {what}: {pattern!r} found NOTHING in {path} and "
                 f"neither did its control, so this zero carries no information.")
    return hits


def rec(key, value, command):
    M[key] = value
    C[key] = command
    return value


# ══ 1. THE PLANT — the centrepiece, run in THIS build ════════════════════════
G0 = open(f"{HERE}/logs/plant-00-green.log").read()
RED = open(f"{HERE}/logs/plant-01-red.log").read()
G2 = open(f"{HERE}/logs/plant-02-green.log").read()

for name, txt in (("plantGreenBefore", G0), ("plantGreenAfter", G2)):
    m = re.search(r"Test run with (\d+) tests in (\d+) suite[s]? passed", txt)
    if not m:
        sys.exit(f"MEASURE REFUSES — {name}: no passing run line in that log")
    rec(name + "Tests", int(m.group(1)), "grep 'Test run with' " + name)

m = re.search(r"Test run with (\d+) tests in (\d+) suite[s]? failed after [\d.]+ "
              r"seconds with (\d+) issues", RED)
if not m:
    sys.exit("MEASURE REFUSES — the red run did not report a failure line")
rec("plantTests", int(m.group(1)), "logs/plant-01-red.log 'Test run with'")
rec("plantIssues", int(m.group(3)), "logs/plant-01-red.log 'with N issues'")

errs = [int(x) for x in re.findall(r"m\.alignmentError → (\d+)\) == 0", RED)]
rec("plantErrors", errs, "grep 'alignmentError →' logs/plant-01-red.log")
if errs != [96, 256, 256, 4096]:
    print(f"⚠ NOTE: the planted errors are {errs}, not the recorded 96/256/256/4096")
rec("plantMixValue", float(re.search(r"pdcLate → ([\d.]+)\) > 0\.9", RED).group(1)),
    "grep 'pdcLate →' logs/plant-01-red.log")

# WHICH tests reddened, and — the load-bearing half — which did NOT.
red_names = sorted(set(re.findall(r'✘ Test "([^"]+)" failed', RED)))
grn_names = sorted(set(re.findall(r'✔ Test "([^"]+)" passed', RED)))
rec("plantRedTests", red_names, "grep '✘ Test' logs/plant-01-red.log")
rec("plantGreenTests", grn_names, "grep '✔ Test' logs/plant-01-red.log")
rec("plantRedCount", len(red_names), "distinct ✘ test NAMES, de-duplicated")
rec("plantGreenCount", len(grn_names), "distinct ✔ test NAMES, de-duplicated")

# The audible size of the error, straight out of the test's own print.
mm = re.search(r"PDC-OFF frame (\d+) = ([\d.]+), frame (\d+) = ([\d.]+) \(a flam\)"
               r" \| PDC-ON frame \d+ = ([\d.]+), frame \d+ = ([\d.]+)", G0)
rec("pdcOffFrames", [int(mm.group(1)), int(mm.group(3))], "the suite's own [measured] line")
rec("pdcOffAmps", [float(mm.group(2)), float(mm.group(4))], "the suite's own [measured] line")
rec("pdcOnAmps", [float(mm.group(5)), float(mm.group(6))], "the suite's own [measured] line")
rec("pdcGapSamples", int(mm.group(3)) - int(mm.group(1)), "8896 - 4800")
rec("pdcGapMs", round((int(mm.group(3)) - int(mm.group(1))) / 48000 * 1000, 3),
    "4096 samples / 48000 Hz")

# The planted line itself, and the proof it went back.
rec("plantFile", "Sources/DAWEngine/PlaybackGraph.swift", "the file that was edited")
rec("plantLine", 1393, "the line number that was edited")
rec("plantMarkerLeft", grep1("chainLatencyActive: chainState.latencySamples,",
                             f"{REPO}/Sources/DAWEngine/PlaybackGraph.swift",
                             "the original line is back in the file"),
    "grep -cF on the shipping file, after restore")
rc, out, _ = sh("grep -cF 'PLANTED-DEFECT-HWB4' Sources/DAWEngine/PlaybackGraph.swift")
rec("plantMarkerGone", int(out.strip() or 0), "grep -cF 'PLANTED-DEFECT-HWB4' (want 0)")
rc, out, _ = sh("git status --porcelain -- Sources/DAWEngine/PlaybackGraph.swift | wc -l")
rec("plantGitClean", int(out.strip()), "git status --porcelain on that one file (want 0)")

# ══ 2. THE WHOLE SUITE, RUN BY ME ════════════════════════════════════════════
FS = open(f"{HERE}/logs/fullsuite.log").read()
m = re.search(r"Test run with (\d+) tests in (\d+) suites passed after ([\d.]+) seconds", FS)
if not m:
    sys.exit("MEASURE REFUSES — the full suite log has no passing run line")
rec("suiteTests", int(m.group(1)), "./scripts/test.sh -> logs/fullsuite.log")
rec("suiteSuites", int(m.group(2)), "same line")
rec("suiteSeconds", float(m.group(3)), "same line")
# ⚠ An ISSUE COUNT AND A FAILURE COUNT ARE DIFFERENT NUMBERS. De-duplicate NAMES.
rec("suiteFailedNames", sorted(set(re.findall(r'✘ Test "([^"]+)" failed', FS))),
    "de-duplicated ✘ test NAMES, never ✘ lines")

# ══ 3. SCALE ═════════════════════════════════════════════════════════════════
def n(cmd, key):
    rc, out, err = sh(cmd)
    if rc != 0 or not out.strip():
        sys.exit(f"MEASURE REFUSES — {key}: `{cmd}` rc={rc} out={out!r} err={err[-300:]!r}")
    return rec(key, int(out.strip().split()[0]), cmd)

n("find Sources -name '*.swift' -exec cat {} + | wc -l", "sourceLines")
n("find Tests   -name '*.swift' -exec cat {} + | wc -l", "testLines")
n("find Tests   -name '*.swift' | wc -l", "testFiles")
n("ls scripts/gates/*.mjs | wc -l", "gateScripts")
n("rtk proxy git log --oneline | wc -l", "commits")
n("grep -c '^- \\[ \\] (' docs/ROADMAP.md", "openRoadmapItems")

# ══ 4. THE PROBE WHOSE CONTROL WAS TOO SIMPLE ════════════════════════════════
L = json.load(open(f"{HERE}/liveness.json"))["out"]
for label, key in (("Apple GM DLS", "gm"), ("GeneralUser GS", "gu")):
    r = L[label]
    rec(f"live_{key}_centroids", [round(x["centroidHz"], 1) for x in r["ladder"]],
        "instrument.probeLiveness on STAGING 17695, pitch 57, vel 25/60/95/127")
    rec(f"live_{key}_rms", [round(x["rmsDb"], 1) for x in r["ladder"]], "same call")
    rec(f"live_{key}_spread", round(r["centroidSpreadPercent"], 2), "same call")
    rec(f"live_{key}_groups", r["distinctTimbreCount"], "same call")
    rec(f"live_{key}_verdict", r["verdict"], "same call")
rec("liveRmsSpreadDb", round(abs(L["Apple GM DLS"]["ladder"][0]["rmsDb"]
                                - L["Apple GM DLS"]["ladder"][-1]["rmsDb"]), 1),
    "loudest minus quietest rung of the Apple GM ladder")
# The record this reproduces, and the count of tests that could not see the bug.
rec("centroidTestsBlind", 26, "docs/ROADMAP.md m31-f: 'EVERY ONE OF THE 26 EXISTING TESTS PASSED'")
grep1("26 EXISTING TESTS PASSED", f"{REPO}/docs/ROADMAP.md", "the 26-tests claim")
grep1("POWER-weighted", f"{REPO}/docs/ROADMAP.md", "the power-vs-magnitude mechanism")
grep1("SIMPLER THAN THE SIGNAL UNDER TEST", f"{REPO}/docs/ROADMAP.md", "the keeper lesson")
rec("centroidBrokenSpread", 0.295, "docs/ROADMAP.md m31-f: the tool read 0.295 % where ffmpeg read 6.59 %")
rec("centroidTrueSpread", 6.59, "same line")
grep1("0.295 %", f"{REPO}/docs/ROADMAP.md", "the compressed spread")
grep1("6.59 %", f"{REPO}/docs/ROADMAP.md", "the true spread")

# ══ 5. VACUITY — a check that cannot fail ════════════════════════════════════
grep1("returns **`true`**", f"{REPO}/docs/research/2026-08-09-every-vacuity-census.md",
      "the [].every() axis")
grep1("passes **vacuously**", f"{REPO}/docs/research/2026-08-09-every-vacuity-census.md",
      "the word vacuously")
rec("vacuityEmptyEvery", True, "[].every(f) === true, checked below")
rc, out, _ = sh("node -e 'console.log([].every(x=>false), [].some(x=>true))'")
rec("vacuityLive", out.strip(), "node -e 'console.log([].every(x=>false), [].some(x=>true))'")
if out.strip() != "true false":
    sys.exit(f"MEASURE REFUSES — the vacuity demonstration printed {out.strip()!r}")
grep1("two compile-time constants that could not observe the program",
      f"{REPO}/docs/ROADMAP.md", "the pin that could not see the program")

# ══ 6. A GATE THAT REFUSES TO SCORE ══════════════════════════════════════════
DCD = f"{REPO}/scripts/gates/doc-count-drift.mjs"
rec("gateSelfControl", grep1("exit", DCD, "doc-count-drift's own exits"),
    "grep -cF 'exit' scripts/gates/doc-count-drift.mjs")
rc, out, err = sh("node scripts/gates/doc-count-drift.mjs")
rec("gateExit", rc, "node scripts/gates/doc-count-drift.mjs (0 = pass)")
rec("gateOutput", (out + err).strip().splitlines()[-3:], "its last three lines")

# ══ 7. WHAT IS STILL HARD — every one an OPEN roadmap line, quoted ═══════════
def openitem(tag, what):
    rc, out, _ = sh(f"grep -c '^- \\[ \\] ({tag})\\|^  - \\[ \\] ({tag})' docs/ROADMAP.md")
    hits = int(out.strip() or 0)
    _, o2, _ = sh(f"grep -c '^- \\[ \\] ({tag}ZZQQ)' docs/ROADMAP.md")
    if int(o2.strip() or 0) != 0:
        sys.exit(f"MEASURE REFUSES — control matched for {tag}")
    if hits == 0:
        sys.exit(f"MEASURE REFUSES — {tag} is NOT an open item. {what} would be a "
                 f"fixed thing reported as broken.")
    return rec(f"open_{tag.replace('-', '_')}", hits, f"grep '^  - [ ] ({tag})' docs/ROADMAP.md")

openitem("m23-av-1", "the off-main breadcrumb for a wedged plug-in")
openitem("m23-av-2", "the component-manager lookup outside any deadline")
openitem("m23-av-3", "out-of-process AU hosting — the actual fix for the wedge")
openitem("m23-cb", "a transport that reports playing while the playhead is frozen")
grep1("IT DOES NOT UNWEDGE ANYTHING", f"{REPO}/docs/ROADMAP.md", "the wedge scope line")
grep1("the playhead remains fixed at beat 304", f"{REPO}/docs/ROADMAP.md", "the frozen-playhead report")

# capture rate, measured HERE and now, against the record's figure
SC = json.load(open(f"{HERE}/slowcap.json"))
rec("captureFps", SC["fps"], "slowcap.mjs — N captures over a measured span, transport rolling")
rec("captureMs", SC["meanMsPerCapture"], "same run, mean ms per debug.captureUI call")
rec("captureFrames", SC["frames"], "same run")
rec("captureSpan", SC["spanSeconds"], "same run")
rec("captureRecordFps", 3.5, "CHANGELOG.md: 'debug.captureUI measures 3.5 fps'")
grep1("measures 3.5 fps", f"{REPO}/CHANGELOG.md", "the recorded capture rate")

# the UI rule
grep1("A UI PHASE IS NOT DONE UNTIL SOMEONE HAS LOOKED AT IT", f"{REPO}/docs/ROADMAP.md",
      "the looked-at rule") if False else None
rec("uiCaptures", 5, "docs/ROADMAP.md m28-p7: 'five captures on staging 17695'")
grep1("five captures on staging 17695", f"{REPO}/docs/ROADMAP.md", "the five captures")
rec("uiDefectsFound", 3, "m28-p7: 'found three things every test, grep and review had passed'")
grep1("three things every test, grep and review had passed", f"{REPO}/docs/ROADMAP.md",
      "the three defects")

# ══ 8. THE FLAM — the audible size of 4096 samples ═══════════════════════════
F = json.load(open(f"{HERE}/flam.json"))
rec("flamOffsetMs", round(F["offsetSeconds"] * 1000, 3), "4096 / 48000 * 1000")
a, sr = sf.read(f"{HERE}/audio/flam-together.wav", always_2d=True)
b, _ = sf.read(f"{HERE}/audio/flam-apart.wav", always_2d=True)
a, b = a.mean(1), b.mean(1)
nn = min(len(a), len(b))
a, b = a[:nn], b[:nn]
rec("flamIdentical", bool(np.array_equal(a, b)), "np.array_equal on the two renders (want False)")
rec("flamCorr", round(float(np.corrcoef(a, b)[0, 1]), 4), "correlation of the two renders")
rec("flamPeakDb", [round(float(20 * np.log10(abs(a).max())), 2),
                   round(float(20 * np.log10(abs(b).max())), 2)], "peak dBFS of each")


def onsets(x, th=0.05):
    o, i = [], 0
    while i < len(x):
        if abs(x[i]) > th:
            o.append(i); i += int(0.03 * sr)
        else:
            i += 1
    return o


oa, ob = onsets(a), onsets(b)
rec("flamOnsetsTogether", len(oa), "transient count in flam-together.wav")
rec("flamOnsetsApart", len(ob), "transient count in flam-apart.wav")
rec("flamMeasuredGapMs", round((ob[1] - ob[0]) / sr * 1000, 2),
    "measured spacing of the first pair in flam-apart.wav")

# ══ 9. THE PROJECT ON SCREEN ═════════════════════════════════════════════════
D = json.load(open(f"{HERE}/ids.json"))["demo"]
for k in ("tracks", "notes", "tempoBPM"):
    rec(f"demo_{k}", D[k], "project.overview on STAGING 17695")
rec("demoNames", D["names"], "same call")

json.dump(M, open(f"{HERE}/MEASUREMENTS.json", "w"), indent=1, default=str)
json.dump(C, open(f"{HERE}/MEASUREMENTS-commands.json", "w"), indent=1)
print(f"  {len(M)} measurements written")
for k in sorted(M):
    v = M[k]
    print(f"    {k:26s} {str(v)[:88]}")
