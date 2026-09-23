#!/usr/bin/env python3
"""Keep the narration's MEASURED CLAIMS true to the current render.

⛔⛔ WHY THIS EXISTS. The `the-drop` line asserts a number out loud:

    "the drop is six decibels louder and thirty three decibels brighter"

Those two figures came from measure.py against one particular render. Change
the lead instrument — as this cut does, swapping the toy synth for the
supersaw — and both numbers move. Nothing in the pipeline notices: narrate.py
SKIPS any take that already exists, so the old words are re-used verbatim over
the new music, and every gate downstream passes. The film then states a
measurement that is simply false, in a confident voice, over a picture of the
thing it is wrong about.

An independent observer verified those exact numbers last cut. They will again.

So: measure the render, compare against what the script SAYS, and when they
disagree, rewrite the sentence and throw away the stale voice take so narrate.py
is forced to speak the new one.

    python3 sync-claims.py <build.json> <manifest.json> <vo-dir>

EXITS: 0 nothing to do or claims updated - 1 measure.py failed - 3 refused.
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXIT_OK, EXIT_FAIL, EXIT_CONTROL = 0, 1, 3

ONES = ("zero one two three four five six seven eight nine ten eleven twelve "
        "thirteen fourteen fifteen sixteen seventeen eighteen nineteen").split()
TENS = ("_ _ twenty thirty forty fifty sixty seventy eighty ninety").split()


def words(n):
    """Integer to the spoken form the TTS reads best. 0-99 only."""
    n = int(n)
    if not 0 <= n <= 99:
        die_control(f"cannot speak {n}: outside 0-99")
    if n < 20:
        return ONES[n]
    t, o = divmod(n, 10)
    return TENS[t] + (f" {ONES[o]}" if o else "")


def die_control(msg):
    print(f"sync-claims: CONTROL FAILED -- {msg}", file=sys.stderr)
    sys.exit(EXIT_CONTROL)


def main():
    if len(sys.argv) < 4:
        die_control("usage: sync-claims.py <build.json> <manifest.json> <vo-dir>")
    build, manifest, vodir = sys.argv[1:4]
    for p in (build, manifest):
        if not os.path.exists(p):
            die_control(f"missing {p}")

    # measure.py is the ONE instrument that produces these numbers. Running it
    # here also re-asserts true peak and section structure on the new render,
    # which the supersaw's seven detuned saws could plausibly have broken.
    p = subprocess.run([sys.executable, f"{HERE}/measure.py", build],
                       capture_output=True, text=True)
    sys.stdout.write(p.stdout)
    if p.returncode != 0:
        sys.stderr.write(p.stderr)
        print(f"\n⛔ measure.py exited {p.returncode} — the render itself is the "
              "problem, not the narration. Fix the render first.", file=sys.stderr)
        return EXIT_FAIL

    m = re.search(r"drop is ([+-]?[\d.]+) dB louder and ([+-]?[\d.]+) dB brighter",
                  p.stdout)
    if not m:
        # ⚠ NOT a silent pass. If measure.py stops printing this line, the
        # claim becomes uncheckable and that must be loud, not invisible.
        die_control("measure.py printed no drop-vs-intro line to check against")
    loud, bright = round(float(m.group(1))), round(float(m.group(2)))

    man = json.load(open(manifest))
    stage = next((s for s in man["stages"] if s["id"] == "the-drop"), None)
    if stage is None:
        die_control("no the-drop stage in the manifest")

    pat = re.compile(r"the drop is (\w+(?: \w+)?) decibels louder and "
                     r"(\w+(?: \w+)?) decibels brighter", re.I)
    old = pat.search(stage["narration"])
    if not old:
        die_control("the-drop narration no longer contains the measured claim; "
                    "either restore the sentence or delete this gate")

    want = f"the drop is {words(loud)} decibels louder and {words(bright)} decibels brighter"
    if old.group(0).lower() == want.lower():
        print(f"\nclaims still true: {loud} dB louder, {bright} dB brighter — narration kept")
        return EXIT_OK

    stage["narration"] = pat.sub(want, stage["narration"])
    json.dump(man, open(manifest, "w"), indent=2, ensure_ascii=False)
    open(manifest, "a").write("\n")
    print(f"\n⚠ CLAIM MOVED — the render changed under the script.")
    print(f"    was: {old.group(0)}")
    print(f"    now: {want}")

    # The stale take must GO, not just be superseded: narrate.py keeps any wav
    # over 20 KB and would happily re-use the old sentence forever.
    stale = os.path.join(vodir, "the-drop.wav")
    if os.path.exists(stale):
        rej = os.path.join(vodir, "rejected")
        os.makedirs(rej, exist_ok=True)
        dest = os.path.join(rej, "the-drop-stale-claim.wav")
        os.replace(stale, dest)
        print(f"    quarantined the stale voice take -> {dest}")
    else:
        print("    (no existing voice take to quarantine)")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
