#!/usr/bin/env python3
"""plantkit -- plant a defect, prove a gate reddens, revert sha-exact.

WHY THIS EXISTS
---------------
On 2026-09-20 a measurement script took a kind directory and a variant prefix
as argv... and ignored both. It had hardcoded clipper paths. Pointed at the
saturator, it re-measured the CLIPPER and printed a perfectly plausible report.
It was caught only because four figures matched a prior run to two decimals --
i.e. by luck, one step from being published.

The warning walked past: minutes earlier, a `grep argv` on that file had
returned nothing.

So this harness is built so that failure mode is STRUCTURALLY IMPOSSIBLE:

  * every path comes from argv -- there are NO literal repo paths below this
    docstring;
  * it ECHOES every resolved path before acting, so a wrong target is visible
    in the transcript rather than inferred from the numbers;
  * it refuses to run if a target does not exist, rather than proceeding and
    reporting on whatever it happens to find;
  * `--self-test` proves the reddening check can actually FAIL, because a plant
    harness whose gate always passes is worse than no harness at all.

THE SHAPE OF A REAL PLANT
-------------------------
1. sha256 the target BEFORE touching it.
2. Write the plant, tagged with a marker so residue is greppable.
3. Assert the file actually CHANGED (a no-op edit is the silent failure here --
   this is the `sub_once` count==1 discipline, applied to bytes).
4. Run the gate. It MUST exit non-zero. A gate that stays green on a planted
   defect is not measuring what its name claims.
5. Revert.
6. Assert the sha matches the ORIGINAL exactly, and that zero marker residue
   remains anywhere in the tree.

Step 4 is the experiment. Steps 1-3 and 5-6 are what make it trustworthy.

WHAT THIS FOUND, SO THE NEXT READER KNOWS IT IS NOT DECORATIVE
--------------------------------------------------------------
m39-ae: a byte gate over rendered demo variants MISSED a `Codable` decode
default (`?? 0` -> `?? 1`) while CATCHING the memberwise default (`= 0` -> `= 1`)
on the same field. The demo harness builds params through `fx.add`, so
`init(from:)` never runs and the render gate cannot see it. "Bit-exact for
existing projects" therefore needs TWO guards -- a decode test AND a byte gate --
and they are not interchangeable. That was argued for weeks; it took one plant
to settle.

PROMOTED FROM THE SESSION SCRATCHPAD 2026-09-20, with one bug fixed on the way
in -- see EXCLUDES below. It is deliberately untracked-but-in-repo: the next
cycle's verification uses it, and a scratchpad copy dies with its session.
"""
import argparse, hashlib, io, os, subprocess, sys

MARKER = "DSEMPLANT"

# ⚠️ THE BUG THAT WAS FIXED ON PROMOTION. The residue sweep ran
# `grep -rl DSEMPLANT Sources Tests scripts docs`. In THIS repo `scripts/`
# holds ~66 GB of rendered video plus ~56 GB of model weights and ~1.7 GB of
# RVC, and CLAUDE.md names that exact command as one that hangs. The sweep is
# the LAST step, after the revert has already printed a reassuring green line,
# so a hang there looks like a finished, successful run that merely got
# interrupted. Excluded here BY NAME, and the exclusions are PRINTED, because
# a sweep that quietly skips the tree is indistinguishable from a clean one.
EXCLUDES = ["--exclude-dir=video", "--exclude-dir=ace-step", "--exclude-dir=rvc",
            "--exclude-dir=node_modules", "--exclude-dir=.build",
            "--exclude-dir=out"]


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def run(cmd, cwd=None, merge=True):
    """Run a command; return (rc, output). Never reads rc through a pipe.

    `merge=False` keeps stderr OUT of the result. That distinction is not
    cosmetic: the residue sweep below once counted grep's own "No such file or
    directory" complaints as four matching files, because this helper had
    concatenated stderr into the output it then parsed as a file list. A tool
    that could not look reported hits -- the mirror image of the empty-result
    trap, and just as convincing.
    """
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    out = p.stdout or ""
    if merge:
        out += p.stderr or ""
    return p.returncode, out


def plant(target, old, new, gate_cmd, repo, label):
    print("=" * 66)
    print("PLANT: %s" % label)
    print("=" * 66)
    # -- echo every resolved path BEFORE acting. This is the whole point. ----
    print("  target file : %s" % target)
    print("  gate command: %s" % " ".join(gate_cmd))
    print("  repo root   : %s" % repo)
    if not os.path.isfile(target):
        sys.exit("ABORT: target does not exist: %s\n"
                 "       (refusing to 'measure' whatever else is lying around)"
                 % target)

    before_sha = sha256(target)
    before_size = os.path.getsize(target)
    print("  sha BEFORE  : %s  (%d bytes)" % (before_sha[:32], before_size))

    src = io.open(target, encoding="utf-8").read()
    n = src.count(old)
    if n != 1:
        sys.exit("ABORT: the string to replace occurs %d times, need exactly 1.\n"
                 "       Nothing written. Fix the OLD text -- a near-miss here\n"
                 "       writes nothing and then reports a green gate as proof."
                 % n)

    planted = src.replace(old, new + "  // %s: %s" % (MARKER, label), 1)
    if planted == src:
        sys.exit("ABORT: the plant produced an IDENTICAL file. A no-op plant\n"
                 "       makes every gate pass and proves nothing.")
    io.open(target, "w", encoding="utf-8").write(planted)

    after_sha = sha256(target)
    print("  sha PLANTED : %s  (%d bytes)" % (after_sha[:32], os.path.getsize(target)))
    if after_sha == before_sha:
        io.open(target, "w", encoding="utf-8").write(src)
        sys.exit("ABORT: sha unchanged after writing the plant -- reverted.")

    try:
        print("\n  running the gate (it MUST exit non-zero)...")
        rc, out = run(gate_cmd, cwd=repo)
        lines = out.strip().splitlines()
        # ⚠️ THE TAIL IS NOT THE VERDICT. `swift test` writes results to stdout
        # and build progress to stderr, and this helper concatenates stdout THEN
        # stderr -- so the last 14 lines are "Build complete!", and the failure
        # that actually reddened the gate scrolled past. A plant whose failing
        # test cannot be NAMED proves only that something went wrong, which is
        # the "an issue count is not a failure count" trap in the harness meant
        # to defend against it. So surface the failing lines FIRST.
        hits = [L for L in lines
                if ("✘" in L or "error:" in L
                    or "Test Case" in L and "failed" in L
                    or (" failed" in L and "Test" in L))]
        if hits:
            print("  WHAT REDDENED IT (%d line(s), first 10):" % len(hits))
            print("\n".join("    ✘ " + L.strip() for L in hits[:10]))
            print()
        print("  ...tail of the run:")
        print("\n".join("    | " + L for L in lines[-8:]))
        print("\n  gate exit code: %d" % rc)
        verdict = "CAUGHT" if rc != 0 else "MISSED"
        if rc == 0:
            print("  ⛔ THE GATE DID NOT CATCH THE PLANT.")
            print("     It is not measuring what its name claims. Do not trust")
            print("     a green run from it as evidence of anything.")
        else:
            print("  ✅ gate reddened on the plant, as it must.")
    finally:
        io.open(target, "w", encoding="utf-8").write(src)
        rev_sha = sha256(target)
        print("\n  sha REVERTED: %s  (%d bytes)" % (rev_sha[:32], os.path.getsize(target)))
        if rev_sha != before_sha:
            sys.exit("⛔⛔ REVERT FAILED -- the file does NOT match its original "
                     "sha. Fix this BY HAND before doing anything else.")
        print("  ✅ reverted bit-identical to the original sha.")

    # -- residue sweep: the marker must not survive anywhere -----------------
    # Only sweep directories that EXIST, and say which. A sweep of four missing
    # directories finds nothing and looks exactly like a clean tree.
    want = ["Sources", "Tests", "scripts", "docs"]
    dirs = [d for d in want if os.path.isdir(os.path.join(repo, d))]
    skipped = [d for d in want if d not in dirs]
    if not dirs:
        sys.exit("ABORT: none of %s exist under %s -- a residue sweep here would\n"
                 "       return a clean, meaningless zero." % (want, repo))
    print("  sweeping %s, excluding %s"
          % ("/".join(dirs), " ".join(e.split("=", 1)[1] for e in EXCLUDES)))
    # stderr stays OUT: its complaints are not file names.
    rc, out = run(["grep", "-rl"] + EXCLUDES + [MARKER] + dirs, cwd=repo, merge=False)
    hits = [L for L in out.splitlines() if L.strip()]
    # ⛔ THIS FILE MATCHES ITS OWN MARKER. Harmless in the scratchpad, a false
    # "residue left behind" the moment the harness moved INTO the tree it
    # sweeps -- which is exactly what happened on promotion, turning a clean
    # sha-exact revert into a red exit. Dropped BY PATH and PRINTED, never
    # silently: an exclusion you cannot see is how a sweep starts lying.
    try:
        mine = os.path.relpath(os.path.abspath(__file__), os.path.abspath(repo))
    except ValueError:
        mine = None
    if mine and mine in hits:
        hits.remove(mine)
        print("  (ignoring %s -- the harness defines the marker it greps for)" % mine)
    print("  %s residue: %d file(s)%s%s"
          % (MARKER, len(hits),
             (", SKIPPED (absent): " + "/".join(skipped)) if skipped else "",
             (" -> " + ", ".join(hits)) if hits else ""))
    if hits:
        sys.exit("⛔ residue left behind -- clean it before continuing.")
    return verdict


def self_test():
    """Prove the reddening check can FAIL -- otherwise 'gate reddened' is noise.

    Builds a throwaway file and a throwaway gate that ALWAYS exits 0, plants a
    real change, and asserts the harness reports MISSED. If this ever reports
    CAUGHT, the harness is lying and every result it has ever produced is void.
    """
    import tempfile
    d = tempfile.mkdtemp(prefix="plantkit-selftest-")
    # a real Sources/ so the residue sweep sweeps something that EXISTS --
    # otherwise it returns a clean zero for the wrong reason
    os.makedirs(os.path.join(d, "Sources"))
    target = os.path.join(d, "Sources", "subject.swift")
    io.open(target, "w", encoding="utf-8").write("let oversampling = 1\n")
    gate = os.path.join(d, "always-green.sh")
    io.open(gate, "w", encoding="utf-8").write("#!/bin/sh\nexit 0\n")
    os.chmod(gate, 0o755)

    print("SELF-TEST: a gate that always exits 0 MUST be reported as MISSED.\n")
    v = plant(target, "let oversampling = 1", "let oversampling = 2",
              [gate], d, "self-test-always-green")
    print("\n" + "=" * 66)
    if v != "MISSED":
        sys.exit("⛔⛔ SELF-TEST FAILED: harness reported %r for a gate that\n"
                 "   cannot fail. The harness is broken; discard its results." % v)
    print("✅ SELF-TEST PASSED: the harness correctly reports MISSED, so a")
    print("   'CAUGHT' from it is meaningful rather than automatic.")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--self-test", action="store_true",
                    help="prove the reddening check can fail, then exit")
    ap.add_argument("--repo", help="repo root the gate runs in")
    ap.add_argument("--target", help="file to plant the defect in")
    ap.add_argument("--old", help="exact text to replace (must occur ONCE)")
    ap.add_argument("--new", help="replacement text")
    ap.add_argument("--label", default="unlabelled", help="name for this plant")
    # ⚠️ PUT `--` BEFORE THE GATE COMMAND whenever the gate takes flags of its
    # own: `... --label x -- ./scripts/test.sh --filter FooTests`. Without it
    # argparse claims the gate's `--filter` as an unknown option and exits 2
    # BEFORE anything is planted. That is a safe failure (nothing written, no
    # revert owed) but it reads like the plant ran and found nothing.
    ap.add_argument("gate", nargs="*",
                    help="gate command, preceded by `--` if it takes flags; "
                         "e.g. -- ./scripts/test.sh --filter FooTests")
    a = ap.parse_args()

    if a.self_test:
        self_test()
        sys.exit(0)
    missing = [n for n in ("repo", "target", "old", "new") if not getattr(a, n)]
    if missing or not a.gate:
        sys.exit("need --%s and a gate command" % ", --".join(missing + (["gate"] if not a.gate else [])))
    v = plant(a.target, a.old, a.new, a.gate, a.repo, a.label)
    sys.exit(0 if v == "CAUGHT" else 1)
