#!/usr/bin/env python3
"""Re-derive every number this film states, and record the COMMAND that
produced each one beside it.

⭐ Nothing in the spec may hard-code a figure: spec.py reads MEASUREMENTS.json
and asserts every SPOKEN number against the measured one, so the words on the
soundtrack and the numbers on the cards cannot part company.

⚠ The two surface counts are read from the TESTS THAT PIN THEM, not from a
grep of the source. `grep -c 'registerTool('` over-counts, and this file
measures that over-count deliberately, because the film tells that story.
"""
import json, os, re, subprocess, sys

REPO = "/Users/dsemenov/Views/daw-pro"
HERE = os.path.dirname(os.path.abspath(__file__))
M, CMDS = {}, {}


def sh(key, cmd):
    """Run a shell command, record it, return stdout stripped."""
    p = subprocess.run(["bash", "-c", cmd], cwd=REPO, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"MEASURE FAILED [{key}]: {cmd}\n{p.stderr[-1200:]}")
    CMDS[key] = cmd
    return p.stdout.strip()


def num(key, cmd):
    v = int(sh(key, cmd).split()[0])
    print(f"  {key:22s} {v:>9,}   {cmd[:70]}")
    return v


# ── the corpus ─────────────────────────────────────────────────────────────
M["swiftFiles"] = num("swiftFiles", "find Sources -name '*.swift' | wc -l")
M["swiftLines"] = num("swiftLines", "find Sources -name '*.swift' -exec cat {} + | wc -l")
M["testFiles"] = num("testFiles", "find Tests -name '*.swift' | wc -l")
M["testLines"] = num("testLines", "find Tests -name '*.swift' -exec cat {} + | wc -l")
M["tsLines"] = num("tsLines", "find mcp-server/src -name '*.ts' -exec cat {} + | wc -l")
M["tsTestLines"] = num("tsTestLines", "find mcp-server/test -name '*.ts' -exec cat {} + | wc -l")
M["gateScripts"] = num("gateScripts", "ls scripts/gates/*.mjs | wc -l")
M["designDocs"] = num("designDocs", "ls docs/research/*.md | wc -l")
M["commits"] = num("commits", "git log --oneline | wc -l")

# ⭐ THE HOOK, STATED HONESTLY. Swift tests vs Swift program is 224,005 vs
# 209,766 — true. Add the TypeScript on BOTH sides and the totals are much
# closer, so the film says the comparison it actually measured rather than the
# flattering one. Both are computed here and both are checked by spec.py.
M["programLinesAll"] = M["swiftLines"] + M["tsLines"]
M["testLinesAll"] = M["testLines"] + M["tsTestLines"]
M["testsExceedSwift"] = M["testLines"] > M["swiftLines"]
M["testsExceedAll"] = M["testLinesAll"] > M["programLinesAll"]

# ── the modules ────────────────────────────────────────────────────────────
MODULES = [
    ("DAWCore", "the model — tracks, clips, notes, tempo"),
    ("DAWEngine", "makes the sound, in real time"),
    ("DAWControl", "the socket — every action as a message"),
    ("DAWApp", "what you see and click"),
    ("DAWAppKit", "the controls the window is built from"),
    ("AIServices", "talks to the AI providers"),
]
M["modules"] = []
for name, blurb in MODULES:
    lines = num(f"mod:{name}:lines",
                f"find Sources/{name} -name '*.swift' -exec cat {{}} + | wc -l")
    files = num(f"mod:{name}:files", f"find Sources/{name} -name '*.swift' | wc -l")
    M["modules"].append({"name": name, "lines": lines, "files": files, "blurb": blurb})

# ── the two surface counts, from their pins ────────────────────────────────
M["commands"] = int(re.search(r"allCommands\.count == (\d+)", sh(
    "commands", "grep -o 'allCommands.count == [0-9]*' "
                "Tests/DAWControlTests/RenderCommandTests.swift | head -1")).group(1))
M["tools"] = int(re.search(r"tools\.length, (\d+)", sh(
    "tools", "grep -o 'tools.length, [0-9]*' mcp-server/test/integration.test.ts "
             "| head -1")).group(1))
M["toolsByGrep"] = num("toolsByGrep", "grep -c 'registerTool(' mcp-server/src/server.ts")
M["toolGrepOvercount"] = M["toolsByGrep"] - M["tools"]
print(f"  commands {M['commands']}  tools {M['tools']}  "
      f"grep says {M['toolsByGrep']} (+{M['toolGrepOvercount']})")

# ── the timeline ───────────────────────────────────────────────────────────
M["firstCommit"] = sh("firstCommit", "git log --reverse --format=%ad --date=short | head -1")
M["lastCommit"] = sh("lastCommit", "git log -1 --format=%ad --date=short")
import datetime as _dt
a = _dt.date.fromisoformat(M["firstCommit"]); b = _dt.date.fromisoformat(M["lastCommit"])
M["spanDays"] = (b - a).days
print(f"  span {M['firstCommit']} -> {M['lastCommit']}  {M['spanDays']} days")

# ── the convergence: the two call sites that meet in one function ──────────
# THE FILM'S CENTREPIECE IS THIS FACT, so it is measured rather than asserted.
def where(pattern, path):
    out = sh(f"where:{path}:{pattern}", f"grep -n {pattern!r} {path} | head -1")
    return {"file": path, "line": int(out.split(":")[0]), "text": out.split(":", 1)[1].strip()}

M["convergence"] = {
    "button": where(r"store.transport.isPlaying ? store.stop() : store.play()",
                    "Sources/DAWApp/TransportBar.swift"),
    "socket": where(r'case "transport.play":', "Sources/DAWControl/Commands.swift"),
    "shared": where(r"public func play() {", "Sources/DAWCore/ProjectStore.swift"),
    "engine": where(r"engine.startPlayback(transport)", "Sources/DAWCore/ProjectStore.swift"),
}
for k, v in M["convergence"].items():
    print(f"  {k:8s} {v['file']}:{v['line']}  {v['text'][:60]}")

# ── the demo project this film is shot on ──────────────────────────────────
ids = json.load(open(f"{HERE}/ids.json"))
M["demo"] = {"tempoBPM": ids["tempo"], "beats": ids["beats"],
             "tracks": len(ids["noteCounts"]),
             "noteCounts": ids["noteCounts"],
             "notes": sum(ids["noteCounts"].values())}
print(f"  demo {M['demo']['tracks']} tracks, {M['demo']['notes']} notes")

# ── how many commands the proof shot actually sent ─────────────────────────
dl = f"{HERE}/drive-log.json"
if os.path.exists(dl):
    M["driveCommands"] = len(json.load(open(dl)))

M["_commands"] = CMDS
json.dump(M, open(f"{HERE}/MEASUREMENTS.json", "w"), indent=1)
print(f"\nwrote {HERE}/MEASUREMENTS.json  ({len(M)} keys)")
