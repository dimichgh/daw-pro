#!/usr/bin/env python3
"""Build publish.json for a roads film from its own DESCRIPTION.md.

⛔ THE ONE RULE THIS SCRIPT ENFORCES: **every m:ss in the published text must be
a timestamp derive.py computed.** The description body is written by hand — it
has to be, it is prose — so the guarantee cannot come from construction. It
comes from CHECKING: every `m:ss` token in the title, description and chapters
is looked up in the set derive.py printed for THIS directory, and an unknown one
aborts the write naming the offender. A typed timestamp cannot reach a
publish.json through this script.

⚠ ASCII ONLY in the emitted text, matching 03-moonlight-long/publish.json:
em-dashes, curly quotes and ♩ are transliterated. The YouTube API is fine with
UTF-8, but the three shipped blocks are ASCII and a mixed set is a diff nobody
can read.

usage: mkpublish.py <film-dir> [--check]      (--check writes nothing)
"""
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.abspath(sys.argv[1])
CHECK = "--check" in sys.argv
DERIVE = os.path.join(HERE, "06-bach-prelude", "derive.py")

out = subprocess.run([sys.executable, DERIVE, DIR], capture_output=True, text=True)
if out.returncode != 0:
    sys.exit(f"derive.py failed on {DIR}:\n{out.stderr}")
DERIVED = set(re.findall(r"\b\d+:\d\d\b", out.stdout))
if not DERIVED:
    sys.exit("derive.py printed no timestamps at all — refusing to certify anything")

desc_md = open(os.path.join(DIR, "DESCRIPTION.md")).read()

# The published block is what sits between the two bare `---` fences under
# "## Description (paste below the line)". Anything outside it is working notes.
m = re.search(r"## Description \(paste below the line\)\s*\n\s*\n---\n(.*?)\n---\n",
              desc_md, re.S)
if not m:
    sys.exit(f"{DIR}: could not find the fenced description block")
body = m.group(1).strip()

mt = re.search(r"## Title\s*\n\s*\n\s+(.+)", desc_md)
if not mt:
    sys.exit(f"{DIR}: could not find the title")
title = mt.group(1).strip()

TRANS = {"—": " - ", "–": "-", "’": "'", "‘": "'",
         "“": '"', "”": '"', "−": "-", "♠": "", "·": "-",
         "♯": "#", "♩": "quarter note", "…": "...", "♥": "",
         " ": " ", "→": "->", "–": "-"}
def ascii_ify(s):
    for k, v in TRANS.items():
        s = s.replace(k, v)
    s = re.sub(r" +", " ", s)
    bad = sorted({c for c in s if ord(c) > 127})
    if bad:
        sys.exit(f"{DIR}: non-ASCII left in the published text: {bad!r}")
    return s

title, body = ascii_ify(title), ascii_ify(body)

# The DESCRIPTION.md files use a lone em-dash as a section rule. Transliterated
# it becomes a bare " - " line, which reads as a typo on YouTube; 03's shipped
# block has no rule at all. Drop rule-only lines, and strip the trailing spaces
# transliteration leaves at a line end.
# ⚠ `l.strip(" -")` ALSO EMPTIES A BLANK LINE, and my first version of this
# line deleted every paragraph break in all three descriptions. Match the
# rule line explicitly.
body = "\n".join(l.rstrip() for l in body.split("\n") if l.strip() not in ("-", "--"))
body = re.sub(r"\n{3,}", "\n\n", body).strip()

# ⛔ THE GATE. Every m:ss in what we are about to publish must be derived.
found = sorted(set(re.findall(r"\b\d+:\d\d\b", title + "\n" + body)))
typed = [t for t in found if t not in DERIVED]
if typed:
    sys.exit(f"{DIR}: TYPED TIMESTAMPS in the published text, not printed by "
             f"derive.py: {typed}\n  derive.py printed: {sorted(DERIVED)}")

META = json.load(open(os.path.join(HERE, "publish-tags.json")))
TAGS, NOTES = META["tags"], META["licenceNotes"]
key = os.path.basename(DIR)
if key not in TAGS:
    sys.exit(f"no tag list for {key} in publish-tags.json")

# ⭐ THE SECOND LICENCE CAVEAT IS APPENDED HERE, NOT WRITTEN INTO DESCRIPTION.md.
# Both caveats have to ride the published block, but 06's DESCRIPTION.md is an
# APPROVED deliverable and editing it to satisfy a request made after approval is
# the trade I already declined once this round. So the stanza is generated.
if key in NOTES:
    body = body.rstrip() + "\n\n" + ascii_ify(NOTES[key])

# Three things that must be in every published block, asserted rather than hoped:
for must, what in (("Polyfjord", "the Polyfjord credit"),
                   ("public domain", "the public-domain statement"),
                   ("LICENCE NOTES", "the licence caveats")):
    if must.lower() not in body.lower():
        sys.exit(f"{DIR}: {what} is missing from the published text")

doc = {"title": title, "description": body, "tags": TAGS[key],
       "categoryId": "10", "privacyStatus": "private",
       "containsSyntheticMedia": True, "madeForKids": False}

print(f"[{key}] title {len(title)} chars, description {len(body)} chars, "
      f"{len(TAGS[key])} tags")
print(f"  timestamps in the published text: {found or '(none)'} — all derived")
if len(title) > 100:
    sys.exit(f"  title is {len(title)} chars; YouTube's limit is 100")
if len(body) > 5000:
    sys.exit(f"  description is {len(body)} chars; YouTube's limit is 5000")
if sum(len(t) + 1 for t in TAGS[key]) > 500:
    sys.exit("  tags exceed YouTube's 500-character total")
if CHECK:
    print("  --check: nothing written")
else:
    p = os.path.join(DIR, "publish.json")
    json.dump(doc, open(p, "w"), indent=2, ensure_ascii=True)
    open(p, "a").write("\n")
    print(f"  wrote {p}")
