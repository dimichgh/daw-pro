#!/usr/bin/env python3
"""The two MEASURED charts. Every value is read from MEASUREMENTS.json or from
git; nothing here is drawn by hand.

⚠ The film burns a corner meter into the BOTTOM RIGHT, so nothing that has to
be readable is placed there.
"""
import json, os, subprocess, datetime as dt
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager

# ⚠ matplotlib does not find "SF Pro Display" by NAME on this machine — it
# falls back to DejaVu and says so only on stderr, which is a chart that looks
# like a different project's chart. Register the file and use the name the
# file itself declares.
for _p in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/SFNSMono.ttf"):
    font_manager.fontManager.addfont(_p)
_SF = font_manager.FontProperties(fname="/System/Library/Fonts/SFNS.ttf").get_name()

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
BG, W, D, A, GOLD, GRN = "#0b0d12", "#eef2ff", "#969eaf", "#82cdff", "#ffc67a", "#76ffc4"
plt.rcParams.update({"font.family": _SF, "text.color": W,
                     "axes.labelcolor": W, "xtick.color": D, "ytick.color": W,
                     "figure.facecolor": BG, "axes.facecolor": BG,
                     "savefig.facecolor": BG})


def frame(w=19.2, h=10.8):
    f, ax = plt.subplots(figsize=(w, h), dpi=100)
    for s in ax.spines.values():
        s.set_visible(False)
    return f, ax


# ── 1. more test than program ──────────────────────────────────────────────
f, ax = frame()
rows = [("TESTS", M["testLines"], M["tsTestLines"]),
        ("PROGRAM", M["swiftLines"], M["tsLines"])]
for i, (lab, sw, ts) in enumerate(rows):
    ax.barh(i, sw, height=0.42, color=(GRN if lab == "TESTS" else A))
    ax.barh(i, ts, left=sw, height=0.42, color=(GRN if lab == "TESTS" else A),
            alpha=0.45)
    ax.text(sw / 2, i, f"Swift  {sw:,}", va="center", ha="center",
            fontsize=25, color="#0b0d12", weight="bold")
    # ⚠ "TypeScript" does not FIT the narrow segment and shipped clipped to
    # "TypeScrip" in the first render — a valid PNG and a wrong chart.
    ax.text(sw + ts / 2, i, f"TS\n{ts:,}", va="center", ha="center",
            fontsize=17, color="#0b0d12", weight="bold")
    ax.text(sw + ts + 4200, i, f"{sw+ts:,}", va="center", ha="left",
            fontsize=32, color=W, weight="bold")
ax.set_yticks([0, 1]); ax.set_yticklabels(["TESTS", "PROGRAM"], fontsize=30, weight="bold")
ax.set_xlim(0, 300000); ax.set_xticks([0, 50000, 100000, 150000, 200000, 250000])
ax.set_xticklabels(["0", "50k", "100k", "150k", "200k", "250k"], fontsize=20)
ax.set_ylim(-0.7, 1.75)
ax.grid(axis="x", color="#1c2230", lw=1)
ax.set_axisbelow(True)
ax.set_title("Lines of code that RUN the program, and lines of code that CHECK it",
             fontsize=34, weight="bold", pad=34, loc="left", x=-0.055)
ax.text(-0.055, -0.16,
        f"measured {dt.date.today().isoformat()} · find Sources -name '*.swift' -exec cat {{}} + | wc -l  "
        f"· and the same over Tests/ and mcp-server/",
        transform=ax.transAxes, fontsize=15, color=D, ha="left")
f.tight_layout(rect=[0.02, 0.06, 0.99, 0.99])
f.savefig(f"{HERE}/shots/chart-code.png"); plt.close(f)
print("  chart-code.png")

# ── 2. the whole history, week by week ─────────────────────────────────────
days = subprocess.run(["git", "log", "--format=%ad", "--date=short"],
                      cwd="/Users/dsemenov/Views/daw-pro",
                      capture_output=True, text=True).stdout.split()
ds = sorted(dt.date.fromisoformat(x) for x in days)
assert len(ds) == M["commits"], f"{len(ds)} != {M['commits']}"
start = ds[0]
weeks = {}
for d in ds:
    weeks[(d - start).days // 7] = weeks.get((d - start).days // 7, 0) + 1
ks = sorted(weeks)
f, ax = frame()
ax.bar([k + 1 for k in ks], [weeks[k] for k in ks], color=A, width=0.72)
for k in ks:
    ax.text(k + 1, weeks[k] + 0.7, str(weeks[k]), ha="center", fontsize=21, color=W)
ax.set_xticks([k + 1 for k in ks])
ax.set_xticklabels([f"wk {k+1}" for k in ks], fontsize=19)
ax.set_ylim(0, max(weeks.values()) * 1.22)
ax.set_yticks([])
ax.grid(axis="y", color="#1c2230", lw=1); ax.set_axisbelow(True)
ax.set_title(f"{M['commits']} saved steps of work, {M['firstCommit']} to {M['lastCommit']}",
             fontsize=34, weight="bold", pad=34, loc="left", x=-0.03)
ax.text(-0.03, -0.13, "git log --format=%ad --date=short", transform=ax.transAxes,
        fontsize=16, color=D, ha="left")
f.tight_layout(rect=[0.02, 0.06, 0.99, 0.99])
f.savefig(f"{HERE}/shots/chart-history.png"); plt.close(f)
print(f"  chart-history.png  {len(ks)} weeks, peak {max(weeks.values())}")
