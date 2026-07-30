#!/usr/bin/env python3
"""Classify scripts/gates/*.mjs by whether they BUILD the tree and whether they
LAUNCH the app themselves — the measurement behind roadmap item m23-ac.

  CLASS 1  builds + launches            → tests a binary of KNOWN provenance
  CLASS 2  launches, never builds       → tests whatever was compiled last
  CLASS 3  never launches               → drives whatever is already on the port

WHY THIS LIVES IN THE REPO AND NOT IN A SCRATCHPAD. It is the verification
instrument for m23-ac-1/2/3, and m23-ac-2 opened with it reporting `CLASS 1 = 0`
on a corpus that genuinely had seven class-1 gates. It has to outlive the
session that wrote it, next to the harness it measures.

FOUR TRAPS THIS MUST AVOID. The first three were each sprung on this item by a
real measurement that produced a confident wrong answer:

  1. Matching tokens inside COMMENTS. The original m23-ac filing scored three
     gates as "builds first" on the strength of a `// swift build && node …`
     usage note. A comment is not a build.
  2. Matching only same-line `spawn(… "DAWApp")` and missing the dominant
     idiom `const BINARY = …; spawn(BINARY, …)`, which nine gates use.
  3. ⚠️ DEFINING SAFETY SYNTACTICALLY WHEN THE FIX IS STRUCTURAL. Until this
     rewrite, "builds" meant a literal `spawnSync("swift", ["build"])` in the
     file — but m23-ac-1's entire achievement was replacing that literal with an
     import of `_staging.mjs`. So the moment the fix landed, the instrument that
     measured the problem could no longer see the solution, and reported all
     seven converted gates as class 3. A detector keyed to a spelling loses its
     subject when the spelling becomes an abstraction. Hence: an import of the
     shared harness counts, and `launchStaging()` counts as BOTH legs because it
     builds internally, while `startStaging()` counts only as a launch and needs
     its own `buildOrAbort()`.
  4. Counting `_staging.mjs` itself as a gate. It is the harness.
  5. ⚠️ TREATING "DOES IT LAUNCH?" AS A PROPERTY OF THE FILE. What decides the
     stale-binary hazard is whether the gate launches BEFORE its first
     connection — and `m23c2-follow-playhead` does not. Its only `spawn` is
     Leg 6, a deliberate mid-test RELAUNCH that proves a preference survives a
     restart; at startup it just connects to whatever is on the port. It scored
     class 2 here for three cycles while behaving like class 3, and it is the
     one gate in the corpus that CANNOT run standalone: on an empty port it dies
     `no connect` after 30 s of retries. So `order` below compares the first
     launch CALL against the first connect CALL and flags `hybrid` when the
     launch comes second. This is a source-order heuristic — top-level scripts
     execute in source order, but a function defined early and called late can
     fool it — so it is a cheap SCREEN, not proof. The ground truth is empirical:
     run the gate on a verified-empty port and see whether it connects.

SELF-CHECK: run with --expect-class1 to assert a known-good set is still
detected, so a future rewrite of this file cannot quietly go blind the way the
last one did.
"""
import os, re, sys, glob, json

GATES = os.path.dirname(os.path.abspath(__file__))
HARNESS = "_staging.mjs"
CALL = r"(?:spawn|spawnSync|exec|execSync|execFile|execFileSync)"


def strip_comments(src):
    """Remove /* */ blocks and // line comments WITHOUT eating `ws://`."""
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    out = []
    for line in src.split("\n"):
        guard = line.replace("://", "\x00")   # protect URL double-slashes
        idx = guard.find("//")
        if idx != -1:
            guard = guard[:idx]
        out.append(guard.replace("\x00", "://"))
    return "\n".join(out)


def classify(path):
    name = os.path.basename(path)
    body = strip_comments(open(path, encoding="utf-8").read())

    # Does it import the shared staging harness, and what does it call?
    imports_harness = bool(re.search(r"""from\s+["'][^"']*_staging\.mjs["']""", body))
    calls_launch = bool(re.search(r"\blaunchStaging\s*\(", body))
    calls_start = bool(re.search(r"\bstartStaging\s*\(", body))
    calls_build = bool(re.search(r"\bbuildOrAbort\s*\(", body))

    # --- LAUNCHES: via the harness, or by spawning the binary itself.
    binvars = set(re.findall(
        r"(?:const|let|var)\s+(\w+)\s*=[^;\n]*\.build/debug/DAWApp", body))
    literal_launch = bool(re.search(
        CALL + r"""\s*\(\s*["'`][^"'`]*\.build/debug/DAWApp""", body))
    var_launch = any(re.search(CALL + r"\s*\(\s*%s\b" % v, body) for v in binvars)
    harness_launch = imports_harness and (calls_launch or calls_start)
    launches = literal_launch or var_launch or harness_launch

    # --- BUILDS: `launchStaging` builds internally; `startStaging` does NOT.
    literal_build = bool(re.search(
        CALL + r"""\s*\(\s*["'`]swift["'`]\s*,\s*\[\s*["'`]build["'`]""", body))
    harness_build = imports_harness and (calls_launch or calls_build)
    builds = literal_build or harness_build

    # --- does it drive a socket at all (i.e. genuinely needs an instance)?
    wires = bool(re.search(r"WebSocket|ws://|17695|STAGING_PORT|\bconnect\s*\(", body))

    # --- ORDER (trap 5): does the launch happen BEFORE the first connection?
    # Line numbers of the first launch CALL and the first connect CALL. Import
    # lines are excluded, and a `connect` DEFINITION is not a call.
    def first_line(pattern, skip_imports=True):
        for n, line in enumerate(body.split("\n"), 1):
            if skip_imports and re.match(r"\s*import\b", line):
                continue
            if re.search(pattern, line):
                return n
        return None

    launch_at = min([n for n in (
        first_line(CALL + r"\s*\(\s*(?:%s)" % "|".join(
            [r"""["'`][^"'`]*\.build/debug/DAWApp"""] + [re.escape(v) + r"\b" for v in binvars])
            if binvars or literal_launch else r"(?!x)x"),
        first_line(r"\b(?:startStaging|launchStaging)\s*\("),
    ) if n] or [None])
    # ⚠️ Count only an INVOCATION of connect(). An earlier version also matched
    # `new WebSocket(` and flagged nine gates as hybrids when only one is: every
    # gate here defines `async function connect()` near the top, so the
    # WebSocket inside that DEFINITION was being read as a connection attempt
    # occurring before the spawn. A definition is not a call — the same
    # comment-vs-behaviour confusion this whole item was filed about, in a new
    # costume. The corrected screen agrees with the empirical run: only m23c2.
    connect_at = first_line(r"(?:await|=)\s*connect\s*\(")
    order = ("hybrid" if (launch_at and connect_at and launch_at > connect_at)
             else "launch-first" if launch_at else "-")

    cls = 1 if (launches and builds) else 2 if launches else 3
    return dict(name=name, cls=cls, launches=launches, builds=builds, wires=wires,
                via="harness" if harness_launch else "inline" if launches else "-",
                order=order, launch_at=launch_at, connect_at=connect_at,
                binvars=sorted(binvars))


def main():
    # m23-ac-3b-1: exclude EVERY leading-underscore file, not just _staging.mjs by
    # name. When _class3-baseline.mjs shipped in ac-3a it was counted as a gate — it
    # builds and launches, so it silently inflated CLASS 1 by one and made the class
    # totals stop reconciling against the previous cycle. The directory already uses
    # `_` to mean "harness, not gate" (_staging, _class3-baseline, _classify,
    # _orphans); encoding that convention here means the next harness is excluded the
    # day it lands instead of the cycle someone notices the arithmetic drifted.
    rows = [classify(p) for p in sorted(glob.glob(os.path.join(GATES, "*.mjs")))
            if not os.path.basename(p).startswith("_")]

    by = {1: [], 2: [], 3: []}
    for r in rows:
        by[r["cls"]].append(r)

    print("TOTAL GATES: %d   (excludes every _-prefixed harness)" % len(rows))
    for c, label in ((1, "builds + launches — KNOWN binary"),
                     (2, "launches, NEVER builds — stale binary"),
                     (3, "never launches — drives whatever is on the port")):
        print("\n=== CLASS %d — %s: %d ===" % (c, label, len(by[c])))
        for r in by[c]:
            flag = "  ⚠️ HYBRID: launches only AFTER connecting" if r["order"] == "hybrid" else ""
            print("   %-38s via=%-8s wire=%-5s binvar=%-8s%s"
                  % (r["name"], r["via"], r["wires"], ",".join(r["binvars"]) or "-", flag))

    print("\nwire-driving gates that never launch: %d"
          % sum(1 for r in rows if r["cls"] == 3 and r["wires"]))
    hybrids = [r["name"] for r in rows if r["order"] == "hybrid"]
    print("HYBRIDS (scored as launchers but connect FIRST — really class 3 at startup): %s"
          % (", ".join(hybrids) or "none"))
    json.dump(rows, open("/tmp/gate-classes.json", "w"), indent=1)

    # --- self-check: `--expect-class1 a.mjs,b.mjs` asserts these are detected.
    for arg in sys.argv[1:]:
        if arg.startswith("--expect-class1="):
            want = {s.strip() for s in arg.split("=", 1)[1].split(",") if s.strip()}
            got = {r["name"] for r in by[1]}
            missing = sorted(want - got)
            if missing:
                print("\nSELF-CHECK FAILED — expected class 1 but not detected: %s"
                      % ", ".join(missing))
                print("The classifier has gone blind to a form it must recognise (trap 3).")
                return 1
            print("\nSELF-CHECK OK — all %d expected gates detected as class 1." % len(want))
    return 0


if __name__ == "__main__":
    sys.exit(main())
