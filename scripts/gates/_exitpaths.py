#!/usr/bin/env python3
"""Does every gate that starts a staging app get guaranteed teardown? (m23-bd)

WHY THIS EXISTS. Twelve gates arm a watchdog shaped

    setTimeout(() => { console.error("TIMEOUT"); process.exit(2) }, 600_000)

and none of them tore down first. That is the one exit path that fires exactly
when a gate has HUNG, and it leaked the staging app it was driving. An orphan on
17695 is not a tidiness problem: at m23-ac-2a a single one produced FIVE false
greens and THREE false reds in one run, because the other gates connected to it
instead of to the instance they thought they had started.

The fix went into `_staging.mjs` (`armTeardown`), not into the twelve call
sites, so teardown is now structural — a gate author cannot forget what they
never have to write. THIS SCRIPT POLICES THE ONE ASSUMPTION THAT FIX RESTS ON:
that a gate acquires its staging app THROUGH the harness. A gate that spawns the
binary itself gets none of it back, and would reintroduce the leak silently.

So the question here is NOT "does this gate call stopStaging on every path" —
that is the harness's job now, and grepping for it per-gate reports 13 false
alarms. The question is "does anything spawn a staging app behind the harness's
back".

Usage:  python3 scripts/gates/_exitpaths.py [--strict]
        --strict exits 1 if any gate bypasses the harness (for CI).
"""
import glob
import os
import re
import sys

GATES = os.path.join(os.path.dirname(os.path.abspath(__file__)))

# A gate "owns a lifecycle" if it acquires staging through the one home.
VIA_HARNESS = re.compile(r"\b(startStaging|launchStaging)\s*\(")
# Spawning the app binary directly is the bypass we care about. `spawnSync` for
# swift build / swiftc / a probe is fine and deliberately not matched.
BYPASS = re.compile(r"\bspawn\s*\(\s*[^)]*(DAWApp|\.build/debug)", re.S)

# ⚠️ BYPASS ALONE WAS BLIND TO THE ONLY REAL SELF-SPAWNER IN THE CORPUS
# (measured m23-ac-3e-3). It matches a LITERAL at the spawn site, so a gate that
# writes `const BINARY = ".build/debug/DAWApp"` on one line and `spawn(BINARY)`
# on another is invisible to it. m23c2 has done exactly that since it was
# written — BEFORE and AFTER its conversion — so every "0 bypassers" this tool
# has ever printed was silent about it. The number was never wrong about the
# other 42 gates; it simply could not have been right about that one.
#
# Second, worse blind spot: the old test was `hand and not via`, so a gate that
# uses the harness AND ALSO spawns a binary itself was excluded by construction.
# That combination is precisely the risky one — a self-spawn the harness's
# teardown may or may not reach — and it is the one m23c2 is.
SELF_SPAWN_IDENT = re.compile(r"\bspawn\s*\(\s*([A-Za-z_$][\w$]*)")
# Any binding, so aliases can be chased: `const B2 = DEFAULT_BINARY` and then
# `spawn(B2)`. Resolved to a FIXPOINT below — a single pass would catch the first
# hop and be blind to the second, which is the same one-indirection-less-blind
# mistake this whole finding is about. (Verified against a synthetic alias gate.)
ANY_BINDING = re.compile(r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*([^;\n]+)")
SEED_BINARY = re.compile(r"DEFAULT_BINARY|DAWApp|\.build/debug")


def binary_idents(code):
    """Identifiers that (transitively) name the staging binary."""
    names = set()
    bindings = ANY_BINDING.findall(code)
    for _ in range(len(bindings) + 1):          # fixpoint, bounded by chain length
        grew = False
        for name, rhs in bindings:
            if name in names:
                continue
            if SEED_BINARY.search(rhs) or any(
                re.search(r"\b%s\b" % re.escape(n), rhs) for n in names
            ):
                names.add(name)
                grew = True
        if not grew:
            break
    return names

# Self-spawners that are KNOWN COVERED, each with the evidence that covers it.
# Being on this list is a claim that has been measured, not an exemption.
SELF_SPAWN_OK = {
    "m23c2-follow-playhead.mjs":
        "Leg 6 kills and respawns staging ON PURPOSE (it proves a preference "
        "survives a real restart) and writes the new pid to pidfilePath(GATE), so "
        "armTeardown/stopStaging re-read the pidfile and reach the RESPAWNED "
        "process. Measured m23-ac-3e-3: a throw injected right after the respawn "
        "left 0 orphans and released BOTH session locks (original + respawn).",
}


def strip_comments(src):
    """Blank comments but keep line numbers true — the first pass at this audit
    matched an explanatory comment and reported it as a live exit path."""
    out, in_block = [], False
    for line in src.split("\n"):
        if in_block:
            if "*/" in line:
                line, in_block = line.split("*/", 1)[1], False
            else:
                out.append("")
                continue
        while "/*" in line:
            pre, rest = line.split("/*", 1)
            if "*/" in rest:
                line = pre + rest.split("*/", 1)[1]
            else:
                line, in_block = pre, True
                break
        if "//" in line:
            line = line.split("//", 1)[0]
        out.append(line)
    return out


def main():
    strict = "--strict" in sys.argv
    owners, bypassers, selfspawn = [], [], []

    for path in sorted(glob.glob(os.path.join(GATES, "*.mjs"))):
        base = os.path.basename(path)
        if base.startswith("_"):          # harness, not a gate (see _classify.py)
            continue
        code = "\n".join(strip_comments(open(path, encoding="utf-8").read()))
        via = bool(VIA_HARNESS.search(code))
        hand = BYPASS.search(code)
        # Resolve `spawn(IDENT)` against a const binding naming the app binary —
        # the literal-at-the-spawn-site case BYPASS already covers, plus the
        # via-a-variable case it never could.
        if not hand:
            bins = binary_idents(code)
            for ident in set(SELF_SPAWN_IDENT.findall(code)):
                if ident in bins:
                    hand = re.search(r"\bspawn\s*\(\s*%s[^)]*" % re.escape(ident), code)
                    break
        if via:
            owners.append(base)
        if hand and not via:
            bypassers.append((base, hand.group(0)[:60].replace("\n", " ")))
        elif hand and via:
            selfspawn.append((base, hand.group(0)[:60].replace("\n", " ")))

    print("gates acquiring staging through _staging.mjs: %d" % len(owners))
    print("  -> teardown is guaranteed by armTeardown on exit, SIGINT, SIGTERM, SIGHUP")
    print("gates spawning a staging binary THEMSELVES: %d" % len(bypassers))
    for name, snippet in bypassers:
        print("  !! %-40s %s" % (name, snippet))

    # Reported SEPARATELY from bypassers: these gates do use the harness, but they
    # also spawn a binary themselves, so their teardown depends on the pidfile
    # staying accurate across that spawn. Silence here would be the old blind spot.
    print("gates that ALSO spawn a staging binary themselves: %d" % len(selfspawn))
    unjustified = []
    for name, snippet in selfspawn:
        why = SELF_SPAWN_OK.get(name)
        print("  %s %-38s %s" % ("~~" if why else "!!", name, snippet))
        if why:
            print("     covered: %s" % why)
        else:
            unjustified.append(name)

    if bypassers:
        print("\nA gate that spawns the app itself gets no teardown on the watchdog,")
        print("guard, or Ctrl-C paths. Route it through startStaging/launchStaging.")
        if strict:
            return 1
    elif unjustified:
        print("\nA gate that self-spawns INSIDE the harness must write the new pid to")
        print("pidfilePath(GATE) — teardown re-reads that file. Prove it, then add it")
        print("to SELF_SPAWN_OK with the evidence.")
        if strict:
            return 1
    else:
        print("\nOK — no gate bypasses the harness, and every self-spawn is covered.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
