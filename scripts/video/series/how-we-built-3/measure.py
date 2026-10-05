#!/usr/bin/env python3
"""Every number "How We Built a DAW - Part 3" says out loud, with the command
that produced it, into MEASUREMENTS.json.

⚠ THE HONESTY CONSTRAINT. This part is about failures that LOOK like successes,
so every figure here is derived twice where two derivations exist, and where a
record and a live measurement disagree the disagreement is STORED rather than
resolved in my favour.

⚠ NOTHING HERE TOUCHES 17600. The only live reads are the meter geometry
(arithmetic), the two shipped demo wavs (files on disk), a grep of this repo's
own documents, and one deliberately broken shell command run on this machine.
"""
import json, os, re, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = "/Users/dsemenov/Views/daw-pro"
sys.path.insert(0, HERE)
import wav                                                    # noqa: E402

M, C = {}, {}


def sh(cmd, cwd=REPO):
    """Run through bash. ⚠ NEVER through the rtk hook: `git log --oneline | wc -l`
    returns 50 under it and 105 through `rtk proxy`, because the hook truncates.
    That is this film's own thesis biting the film's own measurements."""
    p = subprocess.run(["bash", "-c", cmd], cwd=cwd, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def grep1(pattern, path, what):
    """One grep, with a NEGATIVE CONTROL on every call, refusing to record a
    zero it cannot distinguish from a broken pattern.

    ⚠ THIS FILM IS ABOUT EXACTLY THIS. The first run of measure.py recorded
    FOUR silent zeroes — patterns that spanned a line break in a hard-wrapped
    markdown file, and one that forgot the backticks. Every one of them looked
    like "the record does not say that."
    """
    rc, out, _ = sh(f"grep -c {json.dumps(pattern)} {path}")
    hits = int(out.strip() or 0)
    rc2, out2, _ = sh(f"grep -c {json.dumps(pattern + 'ZZQQ')} {path}")
    neg = int(out2.strip() or 0)
    if neg != 0:
        sys.exit(f"MEASURE REFUSES — negative control matched for {what}")
    if hits == 0:
        sys.exit(f"MEASURE REFUSES — {what}: pattern {pattern!r} found NOTHING in "
                 f"{path}, and its negative control also found nothing, so this "
                 f"zero carries no information. Fix the pattern.")
    return hits


def rec(key, value, command):
    M[key] = value
    C[key] = command
    return value


# ══ 1. THE METER WITH DEAD BARS ═══════════════════════════════════════════════
# scripts/video/meter.py's own constants, and its own analysis geometry.
SR, FPS = 48000, 30
mp = open(f"{REPO}/scripts/video/meter.py").read()
F_LO = float(re.search(r"F_LO, F_HI = ([\d.]+), ([\d.]+)", mp).group(1))
F_HI = float(re.search(r"F_LO, F_HI = ([\d.]+), ([\d.]+)", mp).group(2))
N_NEW = int(re.search(r"N_BARS = (\d+)", mp).group(1))
N_OLD = 48                     # the previous density, named in the same file
win = int(SR / FPS * 2)        # `win = int(hop * 2)`, hop = sr / fps
fr = np.fft.rfftfreq(win, 1 / SR)
binHz = float(fr[1] - fr[0])
rec("meterFLo", F_LO, "grep 'F_LO, F_HI' scripts/video/meter.py")
rec("meterFHi", F_HI, "grep 'F_LO, F_HI' scripts/video/meter.py")
rec("meterBarsNew", N_NEW, "grep 'N_BARS =' scripts/video/meter.py")
rec("meterBarsOld", N_OLD, "the previous density, named in meter.py's own comment")
rec("meterBinHz", binHz, f"np.fft.rfftfreq(win={win}, 1/{SR})[1] — win = 2*sr/fps")


def bands(n):
    e = np.geomspace(F_LO, F_HI, n + 1)
    masks = [(fr >= e[k]) & (fr < e[k + 1]) for k in range(n)]
    centres = np.sqrt(e[:-1] * e[1:])
    dead = [k for k, m in enumerate(masks) if not m.any()]
    narrow = [k for k in range(n) if (e[k + 1] - e[k]) < binHz]
    return dead, narrow, centres


d48, n48, c48 = bands(N_OLD)
d72, n72, _ = bands(N_NEW)
rec("meterDeadOld", len(d48),
    "geomspace(30,12000,49) vs rfftfreq(3200,1/48000): bands containing NO bin")
rec("meterDeadOldHz", [round(float(c48[k]), 1) for k in d48],
    "geometric centres of those bands")
rec("meterNarrowOld", len(n48), "bands NARROWER than one 15 Hz bin — a DIFFERENT question")
rec("meterDeadNew", len(d72), "the same count at 72 bands, before the fix")
rec("meterNarrowNew", len(n72), "bands narrower than one bin at 72")
rec("meterDeadAfterFix", 0,
    "every empty band now reads the bin NEAREST its geometric centre "
    "(meter.py `nearest`), so no band can be empty")
# what the RECORD says, so the two can be compared on screen
rec("meterDocClaimFound",
    grep1("old 48 bands were dead, centred at 36, 41, 52, 67 and 98 Hz",
          "docs/research/design-lesson-rebuild.md", "the record's dead-band claim"),
    "grep -c (line 106; the sentence WRAPS, so a pattern starting at 'MEASURED: 5' "
    "finds nothing and looks like an absence)")
rec("meterCodeNarrowClaim",
    grep1("11 of the previous 48 bands were narrower", "scripts/video/meter.py",
          "the code comment's narrower-than-a-bin count"),
    "grep -c '11 of the previous 48 bands were narrower' scripts/video/meter.py")

# ══ 2. THE DEMONSTRATION THAT WAS CORRECT AND INAUDIBLE ═══════════════════════
A = f"{REPO}/scripts/video/comp/audio"
FAST, SLOW = f"{A}/d3-release-fast.wav", f"{A}/d3-release-slow.wav"
sr, f, _ = wav.read(FAST)
_, s, _ = wav.read(SLOW)
n = min(len(f), len(s))
f, s = f[:n], s[:n]
rec("pairSeconds", round(n / sr, 3), f"ffmpeg decode of {os.path.basename(FAST)}")
rec("pairRmsFast", round(wav.db(f), 2), "20*log10(rms) over the whole file")
rec("pairRmsSlow", round(wav.db(s), 2), "20*log10(rms) over the whole file")
ef, w = wav.env_db(f, sr, 20.0)
es, _ = wav.env_db(s, sr, 20.0)
d = ef - es
# The windows where the two settings actually DIFFER — derived, never chosen by
# eye. 3 dB is the gate; below that there is nothing to listen for.
sig = (d > 3.0) & (ef > -70.0)
rec("pairDiffWindows", int(sig.sum()), "20 ms windows where fast is >3 dB above slow AND above -70 dBFS")
rec("pairWindowMs", round(1000 * w / sr, 1), "the analysis window")
rec("pairDiffSeconds", round(float(sig.sum()) * w / sr, 3), "total time the difference is present")
rec("pairDiffFraction", round(100.0 * float(sig.sum()) * w / sr / (n / sr), 2),
    "as a percentage of the excerpt")
rec("pairDiffLevelFast", round(float(ef[sig].mean()), 2), "mean level of the FAST setting in those windows")
rec("pairDiffLevelSlow", round(float(es[sig].mean()), 2), "mean level of the SLOW setting in those windows")
rec("pairDiffDb", round(float(d[sig].mean()), 2), "mean difference in those windows")
rec("pairDiffDbMax", round(float(d[sig].max()), 2), "the largest single-window difference")
# how much of the file is DIGITAL SILENCE in both — the reason the tail carried it
both_silent = (ef < -120) & (es < -120)
rec("pairSilentFraction", round(100.0 * float(both_silent.sum()) / len(ef), 1),
    "percentage of 20 ms windows that are digital silence in BOTH files")
# the record's own figures
rec("pairRecordPhrase",
    grep1("differed by 11.5 dB", "docs/research/design-b3-recut.md",
          "the record's own figure for this pair"),
    "grep -c 'differed by 11.5 dB' docs/research/design-b3-recut.md")
rec("pairRecordDb", 11.5, "docs/research/design-b3-recut.md:27")
rec("pairRecordLevels", [-39.9, -51.5], "docs/research/design-b3-recut.md:27-28")
rec("filmLufs", -16.0, "this film's own integrated loudness target (spec)")
rec("pairBelowFilm", round(-16.0 - float(ef[sig].mean()), 1),
    "how far under the film's own level the LOUDER half of the difference sits")
LIFT = 14.0   # ⚠ THE ONE HOME for this number: audioprep.py reads it back out of
              # MEASUREMENTS.json. It was 30 here and 14 there for one build, and
              # spec.py's check() is what found the disagreement.
rec("pairLiftDb", LIFT, "ONE shared static gain applied to BOTH halves for the second listen")

# ══ 3. A TOOL THAT NEVER RAN AND A TOOL THAT FOUND NOTHING ════════════════════
TERM, WHERE = "masterChainHost", "Sources/"
rc_b, out_b, err_b = sh(f"timeout 60 grep -rln {TERM} {WHERE} 2>/dev/null")
rc_g, out_g, _ = sh(f"grep -rln {TERM} {WHERE}")
_, err_real, _ = sh(f"timeout 60 grep -rln {TERM} {WHERE} 2>&1 | head -1")
rec("grepTerm", TERM, "a symbol chosen because it has more than one home")
rec("grepBrokenExit", rc_b, f"bash -c 'timeout 60 grep -rln {TERM} {WHERE} 2>/dev/null'")
rec("grepBrokenBytes", len(out_b), "bytes this command printed to stdout")
rec("grepGoodExit", rc_g, f"bash -c 'grep -rln {TERM} {WHERE}'")
rec("grepGoodCount", len([x for x in out_g.split() if x]), "files the working command found")
rec("grepGoodFiles", [os.path.basename(x) for x in out_g.split() if x], "their names")
rec("grepRealError", err_real.strip(), "what 2>/dev/null was throwing away")

# ══ 4. A TEST THAT PASSED A DEMONSTRATION THAT NEVER HAPPENED ═════════════════
SK = "plugins/narrated-film/skills/narrated-film/SKILL.md"
rec("abSkillClaim", grep1("passed GREEN at `+0.00 LU`", SK,
                          "the same-file A/B that passed green"),
    f"grep -c 'passed GREEN at `+0.00 LU`' {SK}  (the BACKTICKS are part of it)")
rec("abCheckExists",
    grep1("def check_ab_separation", "plugins/narrated-film/scripts/verify.py",
          "the gate that now catches it"),
    "grep -c 'def check_ab_separation' plugins/narrated-film/scripts/verify.py")
rec("abFrameHashMentions",
    grep1("md5", "plugins/narrated-film/scripts/verify.py",
          "md5 in verify.py — now only in the comment explaining why NOT to hash"),
    "grep -c md5 verify.py")
rec("frameNoiseFloor",
    grep1("max 0.11; real film: max 5.04", "CHANGELOG.md",
          "the measured pixel floor that replaced the hash"),
    "grep -c 'max 0.11; real film: max 5.04' CHANGELOG.md")
rec("frameStillMax", 0.11, "CHANGELOG.md:696 — a still film's frame-to-frame pixel difference")
rec("frameRealMax", 5.04, "CHANGELOG.md:696 — a real film's")

# ══ 5. THE PUMPING RATE THAT WAS THE DRUMS ════════════════════════════════════
rec("pumpRetracted",
    grep1("comparison, after its 6.45 Hz", "CHANGELOG.md", "the 6.45 Hz retraction"),
    "grep -c 'comparison, after its 6.45 Hz' CHANGELOG.md")
rec("pumpHz", 6.45, "docs/research/design-b7-what-it-took.md:194, CHANGELOG.md:14")
rec("pumpLessonFound",
    grep1("named cause is only as strong as the test behind the name", "CHANGELOG.md",
          "the lesson the retraction left behind"),
    "grep -c (CHANGELOG.md:53 — the sentence WRAPS after 'with a')")
rec("pumpPredicted", [74.55, 248.49, 1987.93], "CHANGELOG.md:19-21 — what replaced it")
rec("pumpMeasured", [74.57, 248.49, 1987.92], "CHANGELOG.md:19-21")
rec("pumpReleases", [30, 100, 800], "CHANGELOG.md:19-20, milliseconds")

# ══ 6. SCALE, and the project on screen ═══════════════════════════════════════
_, o, _ = sh("ls scripts/gates/*.mjs | wc -l")
rec("gateScripts", int(o.strip()), "ls scripts/gates/*.mjs | wc -l")
_, o, _ = sh("rtk proxy git log --oneline | wc -l")
rec("commits", int(o.strip()), "rtk proxy git log --oneline | wc -l  (NOT bare git log — see sh())")
_, o, _ = sh("find Sources -name '*.swift' -exec cat {} + | wc -l")
rec("swiftLines", int(o.strip()), "find Sources -name '*.swift' -exec cat {} + | wc -l")
_, o, _ = sh("find Tests -name '*.swift' -exec cat {} + | wc -l")
rec("testLines", int(o.strip()), "find Tests -name '*.swift' -exec cat {} + | wc -l")

if os.path.exists(f"{HERE}/ids.json"):
    demo = json.load(open(f"{HERE}/ids.json"))
    M["demo"], C["demo"] = demo["demo"], "project.overview on staging (17695)"

M["_commands"] = C
json.dump(M, open(f"{HERE}/MEASUREMENTS.json", "w"), indent=1)
for k, v in M.items():
    if k != "_commands":
        print(f"  {k:24s} {v}")
