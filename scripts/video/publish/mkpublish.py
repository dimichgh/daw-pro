#!/usr/bin/env python3
"""Build publish.json from a film's DESCRIPTION.md — mechanically, never typed.

Title  : the indented block under '## Title'.
Body   : the lines between the '---' fences under '## Description'.
Everything else is fixed policy (private, category 10, synthetic media).
"""
import json, re, sys, os

def extract(path):
    txt = open(path).read()

    m = re.search(r"^## Title\s*\n(.*?)(?=^## )", txt, re.M | re.S)
    if not m:
        sys.exit(f"{path}: no '## Title' section")
    title_lines = [l.strip() for l in m.group(1).splitlines() if l.strip()]
    if len(title_lines) != 1:
        sys.exit(f"{path}: expected exactly 1 title line, got {len(title_lines)}")
    title = title_lines[0]

    m = re.search(r"^## Description[^\n]*\n\s*\n---\n(.*?)\n---\s*$", txt, re.M | re.S)
    if not m:
        sys.exit(f"{path}: no fenced '## Description' block")
    body = m.group(1).strip("\n")

    # YouTube renders plain text; keep the em-dashes and accidentals as authored.
    if len(title) > 100:
        sys.exit(f"{path}: title is {len(title)} chars (limit 100)")
    if len(body) > 5000:
        sys.exit(f"{path}: description is {len(body)} chars (limit 5000)")
    if not body:
        sys.exit(f"{path}: empty description")
    return title, body

TAGS = ["Bach", "Prelude in C", "BWV 846", "Well-Tempered Clavier",
        "classical music", "music visualiser", "sheet music",
        "DAW Pro", "three.js"]

for d in sys.argv[1:]:
    src = os.path.join(d, "DESCRIPTION.md")
    title, body = extract(src)
    meta = {
        "title": title,
        "description": body,
        "tags": TAGS,
        "categoryId": "10",
        "privacyStatus": "private",
        "containsSyntheticMedia": True,
        "madeForKids": False,
    }
    out = os.path.join(d, "publish.json")
    with open(out, "w") as fh:
        json.dump(meta, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print(f"{out}\n   title ({len(title)}): {title}\n   desc  ({len(body)} chars)")
