#!/usr/bin/env python3
"""Emit a YouTube metadata file for EVERY finished video, from its build.json.

    python3 publish-meta.py            # writes publish/*.json, prints the manifest

⛔ TITLES AND DESCRIPTIONS ARE GENERATED, NOT TYPED TWENTY-NINE TIMES. Each one
is built from the piece's own `build.json` — the same title and subtitle that are
burned into the video's own cards — so a video cannot be captioned on YouTube as
a different piece than the one on screen. Four Starlight versions once shipped
with identical captions; that is the mistake this removes.

⚠ SYNTHETIC-MEDIA FLAG IS PER-VIDEO AND DELIBERATE.
  demo-film   -> TRUE. Its narration is a cloned synthetic voice, which is
                 exactly what the disclosure exists for.
  visualisers -> FALSE. These are instrumental pieces played by software
                 synthesizers. YouTube's disclosure is for synthetic content that
                 realistically depicts people, places or events; a synthesizer is
                 not that, and over-flagging would attach an "altered content"
                 label that misdescribes the video. Say so rather than guess —
                 flip it in the JSON if you disagree.

⚠ SHORTS. A vertical video under 3 minutes is detected automatically, but
"#Shorts" in the title makes it unambiguous. Long visualisers must NOT carry it.
"""
import json
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "out"
PUB = HERE / "publish"
PUB.mkdir(exist_ok=True)

ABOUT = (
    "DAW Pro is a macOS digital audio workstation built so an AI agent can drive "
    "it as well as a person can — every instrument, effect and mix move here was "
    "made inside it."
)

# ⛔ THIS PARAGRAPH DESCRIBED THE WRONG AXIS FOR 44 OF 45 PUBLISHED VIDEOS.
# It read "the horizontal rulers are musical octaves ... a note sits at the same
# HEIGHT". In this visualiser pitch runs LEFT TO RIGHT (the C1-C7 labels sit
# along the bottom, the octave rules are vertical lines) and time runs downward.
# Nobody caught it because no gate reads the description against the picture, and
# the sentence is fluent — it just describes a different visualiser. Caught by an
# independent observer pass on 2026-09-22. ⭐ FLUENT PROSE ABOUT A PICTURE IS NOT
# A LOOK AT THE PICTURE.
VIZ = (
    "The picture is a constant-Q spectrogram: the octave rulers run left to right "
    "from C1 to C7, so a note sits at the same place across the frame every time "
    "it is played, which a normal spectrogram does not give you. Stereo waveform "
    "below, playhead and progress across the bottom."
)

# ⛔ USER RULE 2026-09-22: DO NOT NAME THE USER IN PUBLISHED COPY. This paragraph
# used to open "the reference Dmitry named". The reference itself stays — it is
# the honest attribution for what the piece borrows — but the person does not.
COSMIC = (
    "This is an original piece, not a cover. It was written after a reference "
    "track — А. Рыбников, «Свет звёзд», from the 1981 film «Через тернии к "
    "звёздам» — and what it borrows is an approach, not any of his material: "
    "sustained strings, a wordless voice on top, harmony that barely moves, and "
    "all of the motion in tone colour rather than in rhythm. There are no drums "
    "and no bass ostinato anywhere in it."
)

CLASSICAL = {
    "mountain-king": (
        "The melody is Edvard Grieg's, from Peer Gynt (1875), long in the public "
        "domain. Its pitches were traced from the LilyPond source text Mutopia "
        "publishes beside its engravings, rather than read off an image."
    ),
    "fate": (
        "The four-note motif is Beethoven's, from the Fifth Symphony (1808), long "
        "in the public domain. Its pitches were traced from the LilyPond source "
        "text Mutopia publishes beside its engravings. Everything after that "
        "motif is ours, not his — worth saying plainly rather than leaving you to "
        "assume."
    ),
}

LOOP_LEDE = (
    "A seamless loop. Let it repeat — it is cut to an exact whole number of "
    "the chord cycle, so it never lands on a join."
)

HANDOVER_LEDE = (
    "One minute centred on the moment one energy gives way to the next. It fades "
    "up and fades away, so it can repeat without a jump."
)

DJ_SHARED = (
    "Three variants were made one axis apart: same drum machine, same kit, same "
    "drum patterns, same effect chain, same 64-bar structure, same tempo. Only "
    "the melody changes — so a preference between them means something."
)

# ⭐ WHAT IS ALREADY ON THE CHANNEL, SO THE LIST CANNOT INVITE A DOUBLE UPLOAD.
# Recorded here rather than in prose: this file generates the list, so the list
# and the record of what was sent cannot drift apart.
# ✅ REPAIRED IN PLACE ON 2026-09-21 — these ten are now correct ON THE CHANNEL,
# verified by reading them back from the API (a second pass reported "already
# correct" for all ten, and a census of all 94 channel titles found zero Shorts
# still calling themselves "long"). Kept as a record of what was wrong and for
# how long, not as an outstanding task.
#
# ⛔⛔ THE PART THAT MATTERS IS HOW NEARLY I DIDN'T FIX THEM. I had written, in
# three separate files including one the user reads, that the uploader could only
# INSERT and that `videos.update` needed a broader OAuth scope — so repairing
# them would force a fresh consent screen, and the user should paste ten fields
# by hand. Every word of that was recalled, not measured. `publish.py` requests
# `https://www.googleapis.com/auth/youtube`, the FULL scope; the stored token
# carries it; update was available the entire time. (The script is also called
# `publish.py`, not `yt_upload.py`, which I had been writing down for days.)
# ⭐⭐ A CAPABILITY YOU ASSUME YOU LACK COSTS EXACTLY WHAT ONE YOU REALLY LACK
# COSTS — except that this one also spends the USER'S time. `grep -n SCOPES`
# IS FIVE SECONDS AND I WROTE THREE PARAGRAPHS OF WORKAROUND INSTEAD.
# The repair tool is `claude-plugin/skills/demo-film/scripts/repair-meta.py`.
# ⚠ THESE LIST ONLY THE VIDEOS THAT ARE STILL ON THE CHANNEL. Seven of the ten
# originally repaired were the five-minute pieces' Shorts, and those were DELETED
# later the same day once their looping replacements were verified live — so they
# are not listed here, because a name in this list is used to look up a live URL.
# The repair still happened; it is the record that shrank, not the history.
STALE_DESC = [                       # blurb claimed bars no section has
    "cosmic-ascent-5m-long", "cosmic-aurora-5m-long", "cosmic-signal-5m-long",
]
STALE_TITLE = [                      # Short titled "· long"
    "cosmic-b-long-short", "cosmic-d-long-short",
]

UPLOADED = {
    # ⭐ THE LOOPING SHORTS, 2026-09-21 — user asked for Shorts that repeat with no
    # audible break. Exact 8-bar cuts, no outro card (the old one was 2.4 s of
    # digital silence), brand in-frame. These REPLACE the `-short` cuts below.
    "cosmic-ascent-5m-loopshort":    "https://studio.youtube.com/video/e3koLxetBNc/edit",
    "cosmic-heartbeat-5m-loopshort": "https://studio.youtube.com/video/pX7ZTtjAGmA/edit",
    "cosmic-aurora-5m-loopshort":    "https://studio.youtube.com/video/X5YmQL8teJw/edit",
    "cosmic-signal-5m-loopshort":    "https://studio.youtube.com/video/VhbYM4XZwyg/edit",
    "cosmic-collapse-5m-loopshort":  "https://studio.youtube.com/video/xgkhrsNFuJE/edit",
    "demo-film": "https://studio.youtube.com/video/biNM1-bWcYQ/edit",
    # The three energies, uploaded 2026-09-22 (private drafts). Each piece ships
    # THREE videos: the full visualiser, a seamless 16-bar loop Short, and a
    # Short cut around the handover that fades instead of wrapping (the two
    # solve the replay join in opposite ways — see make-loop-short.sh KIND).
    "cosmic-forces-loopshort": "https://studio.youtube.com/video/8bEH7kbcZY0/edit",
    "cosmic-forces-handovershort": "https://studio.youtube.com/video/cLDMrtsaQck/edit",
    "cosmic-forces-apart-loopshort": "https://studio.youtube.com/video/U2RxGX4c3Io/edit",
    "cosmic-forces-apart-handovershort": "https://studio.youtube.com/video/NjgpxfGqjcs/edit",
    "cosmic-forces-crossing-loopshort": "https://studio.youtube.com/video/ecZdgQcn728/edit",
    "cosmic-forces-crossing-handovershort": "https://studio.youtube.com/video/riUuXYyDjoI/edit",
    "cosmic-forces-long": "https://studio.youtube.com/video/1aWnDgu_OeY/edit",
    "cosmic-forces-apart-long": "https://studio.youtube.com/video/U9P7lOTAwK0/edit",
    "cosmic-forces-crossing-long": "https://studio.youtube.com/video/k_E9O3D-STE/edit",
    "cosmic-a-long": "https://studio.youtube.com/video/RJJgnFF15dY/edit",
    "cosmic-b-long": "https://studio.youtube.com/video/BLvVjl6nfBU/edit",
    "cosmic-c-long": "https://studio.youtube.com/video/pqK4vSo6hkM/edit",
    "cosmic-d-long": "https://studio.youtube.com/video/bkfuEgSypvg/edit",
    "machine-room-long": "https://studio.youtube.com/video/gFOXmJGlt4s/edit",
    # ⭐ 2026-09-21, second batch — the user asked for "5 mins versions" uploaded.
    # These four ARE the five-minute long forms (5:05 each), long and short.
    "cosmic-d-long-long":  "https://studio.youtube.com/video/I-34z1DN7FY/edit",
    "cosmic-b-long-long":  "https://studio.youtube.com/video/ISlWKpj9DW0/edit",
    "cosmic-d-long-short": "https://studio.youtube.com/video/lm3jHC_KJ64/edit",
    "cosmic-b-long-short": "https://studio.youtube.com/video/glavfVExuLM/edit",
    # ⭐ THE FIVE NEW FIVE-MINUTE PIECES, long + Short each, 2026-09-21.
    "cosmic-ascent-5m-long":     "https://studio.youtube.com/video/bCP2W_Q00hU/edit",
    "cosmic-heartbeat-5m-long":  "https://studio.youtube.com/video/pK3BlsYSE_8/edit",
    "cosmic-aurora-5m-long":     "https://studio.youtube.com/video/h25gfffa06s/edit",
    "cosmic-signal-5m-long":     "https://studio.youtube.com/video/EicNiaQ7WRM/edit",
    "cosmic-collapse-5m-long":   "https://studio.youtube.com/video/3mfrOHImpSg/edit",
    # ⭐ THE REMAINING NINETEEN, 2026-09-21 — the 3½-minute developed pieces,
    # the a/b/c/d Shorts, and the DJ/classical cuts. Every video now on the channel.
    "cosmic-a-short": "https://studio.youtube.com/video/c-cX6zv_9z8/edit",
    "cosmic-ascent-long": "https://studio.youtube.com/video/E9Y9vjU3L6g/edit",
    "cosmic-ascent-short": "https://studio.youtube.com/video/GnbDVmTKowY/edit",
    "cosmic-aurora-long": "https://studio.youtube.com/video/8N_Gwc_Q7l4/edit",
    "cosmic-aurora-short": "https://studio.youtube.com/video/q97aEOTMVVs/edit",
    "cosmic-b-short": "https://studio.youtube.com/video/DFhBghWQxmA/edit",
    "cosmic-c-short": "https://studio.youtube.com/video/FmyR5klHFQM/edit",
    "cosmic-collapse-long": "https://studio.youtube.com/video/pYIWbOjZMUI/edit",
    "cosmic-collapse-short": "https://studio.youtube.com/video/F0TxTbt5y60/edit",
    "cosmic-d-short": "https://studio.youtube.com/video/LeEXC_InkTE/edit",
    "cosmic-heartbeat-long": "https://studio.youtube.com/video/KY11Nz4duRA/edit",
    "cosmic-heartbeat-short": "https://studio.youtube.com/video/gKt7NoafAlo/edit",
    "cosmic-signal-long": "https://studio.youtube.com/video/zP2RqVKwX4A/edit",
    "cosmic-signal-short": "https://studio.youtube.com/video/Qez_AtX-yNY/edit",
    "fate-long": "https://studio.youtube.com/video/WiE84rzQmJg/edit",
    "fate-short": "https://studio.youtube.com/video/NaEeL1kIzhI/edit",
    "machine-room-short": "https://studio.youtube.com/video/EGnqdvWFRw4/edit",
    "mountain-king-long": "https://studio.youtube.com/video/G259BsuV78U/edit",
    "mountain-king-short": "https://studio.youtube.com/video/lPz_Z9KPoeM/edit",
}
# ⛔⛔ THE "~6 UPLOADS A DAY" FIGURE IN THIS FILE WAS WRONG AND IT COST REAL WORK.
# It came from dividing a 10,000 unit daily quota by a widely-quoted ~1600 units
# per `videos.insert`. On 2026-09-21 **THIRTY-THREE** uploads went through in a
# single day with no quota error at all — every remaining video on the channel in
# one sitting. The estimate had already shaped a plan ("two slots left today, the
# user drags the other 23 in by hand") that was never true, and it was only
# discovered because ONE upload was attempted as a probe instead of predicted.
# ⭐ SO: PROBE THE LIMIT, DO NOT DERIVE IT. One real insert answers the question
# that arithmetic only guesses at, and a `quotaExceeded` costs nothing but the
# attempt. Stop on the error; never forecast it.
#
# ⛔ SEPARATELY: THE UPLOAD LOOP ONCE SKIPPED ITS LAST ITEM IN SILENCE. The queue
# was written with `"\n".join(...)` — no trailing newline — and `while read` drops
# a final partial line, so 19 queued became 18 attempted, exit 0, every attempted
# upload printing "ok". Caught only by comparing the loop's tally against the
# input count (`wc -l` said 18, `grep -c .` said 19 — wc counts NEWLINES).
# ⭐ ALWAYS ASSERT HOW MANY ITEMS A LOOP ACTUALLY PROCESSED.
# ⚠ `cosmic-b-long` is the long VISUALISER of the 2:32 `cosmic-b`; `cosmic-b-long-long`
# is the long visualiser of the 5:05 LONG FORM. Both are now uploaded and they are
# DIFFERENT CUTS — the names differ by one suffix, so check which row you are reading
# before re-sending either. Same for the `d` pair.

BASE_TAGS = ["DAW Pro", "music production", "audio software", "macOS",
             "music visualizer", "spectrogram"]
TAGS = {
    "dj": BASE_TAGS + ["drum machine", "electronic music", "techno", "synthesizer"],
    "cosmic": BASE_TAGS + ["ambient", "ambient music", "space music", "beatless",
                           "synthesizer", "Rybnikov"],
}


def clip(s, n):
    """Trim to n chars on a word boundary — never mid-word, never over the cap."""
    return s if len(s) <= n else s[:n].rsplit(" ", 1)[0].rstrip(" ,·—-")


def deshout(s):
    """Lower an ALL-CAPS emphasis clause to sentence case.

    ⚠ THE SUBTITLES ARE WRITTEN FOR THE REVIEW PAGE, WHERE CAPS ARE EMPHASIS.
    Pasted straight into a YouTube title they read as shouting — "Starlight ·
    Ascent — THE POWER ONE, DEVELOPED". Only fully-capitalised clauses are
    lowered, so "DAW Pro" and real initialisms in a mixed-case clause survive.
    """
    out = []
    for part in s.split("—"):
        p = part.strip()
        letters = [c for c in p if c.isalpha()]
        if letters and all(c.isupper() for c in letters):
            p = p[0].upper() + p[1:].lower()
        out.append(p)
    return " — ".join(x for x in out if x)


def build(piece, kind):
    """kind is 'long', 'short', or 'loopshort'.

    ⭐ `loopshort` IS a Short — it takes the #Shorts suffix and the vertical
    treatment — but it is an exact 8-bar cut that wraps seamlessly, so its
    description says so and its title drops the piece's "· long".
    """
    is_short = kind in ("short", "loopshort", "handovershort")
    b = json.loads((OUT / piece / "build.json").read_text())
    title, sub, blurb = b["title"], b["subtitle"], b["blurb"]
    fam = "cosmic" if piece.startswith("cosmic") else "dj"

    # ⛔ THE SHORT OF A LONG-FORM PIECE IS NOT "LONG". Seven Shorts went up titled
    # "Starlight · Ascent · long — … #Shorts", which contradicts itself in the space
    # of one line. Cause: "· long" is part of the PIECE'S OWN NAME for the long-form
    # cuts (`cosmic-b-long`, every `*-5m`), and the Short inherits the piece title
    # verbatim. Nothing was wrong with the Short — only with what it called itself.
    # ⭐ Found by CENSUSING all 39 titles for the contradiction, not by reading them:
    # every one of the seven looked plausible in isolation, and the two I happened
    # to open by hand were both fine.
    if is_short and title.endswith(" · long"):
        title = title[: -len(" · long")]

    # subtitle's first clause is the descriptive half; the rest is key/tempo
    head = deshout(sub.split("·")[0].strip())
    suffix = " #Shorts" if is_short else " | DAW Pro"
    budget = 100 - len(suffix) - len(title) - 3          # 3 = the " — " joiner

    # ⛔ CLIP THE HEAD, NEVER THE WHOLE TITLE. Clipping the assembled string cut
    # Aurora's suffix to "| DAW" — the one part that must always survive.
    # ⭐ AND DROP WHOLE CLAUSES BEFORE CUTTING WORDS. A word-boundary trim still
    # left "…moves twice as | DAW Pro", which is a sentence stopped mid-thought.
    # Shedding the last clause gives "The original, opened out — new harmony,
    # brighter", which is shorter AND still a complete phrase.
    # ⛔ A LOOP MUST NOT INHERIT THE PIECE'S SUBTITLE. "five minutes, two climbs"
    # on a 30-second loop is a promise the video does not keep — and the whole
    # point of generating titles from build.json was that a video cannot be
    # captioned as something it is not. The loop describes ITSELF: how long it
    # is in bars, and which section it was cut from.
    if kind == "loopshort":
        lj = OUT / piece / f"{piece}-loop.json"
        if lj.exists():
            lm = json.loads(lj.read_text())
            sb, acc, sect = lm["start_bar"], 0, None
            for s in b["sections"]:
                if acc <= sb < acc + s["bars"]:
                    sect = s["name"]
                    break
                acc += s["bars"]
            words = {8: "eight", 16: "sixteen", 24: "twenty-four"}
            n = words.get(lm["bars"], str(lm["bars"]))
            head = (f"{n} bars from {sect}, looping" if sect
                    else f"{n} bars, looping")

    # ⛔ SAME RULE FOR THE HANDOVER CUT, AND IT MATTERS MORE HERE: each piece now
    # ships TWO one-minute Shorts, so if the handover one inherits the piece's
    # subtitle the pair read as near-duplicates and the distinguishing fact — that
    # this is the changeover itself — never appears. Name what it is.
    if kind == "handovershort":
        head = "the handover, one minute"

    clauses = [c.strip() for c in head.split("—") if c.strip()]
    while len(clauses) > 1 and len(" — ".join(clauses)) > budget:
        clauses.pop()
    head = " — ".join(clauses)
    t = f"{title} — {clip(head, budget)}{suffix}"

    parts = [blurb, "", sub, ""]
    if kind == "loopshort":
        parts = [LOOP_LEDE, "", blurb, "", sub, ""]
    if kind == "handovershort":
        parts = [HANDOVER_LEDE, "", blurb, "", sub, ""]
    if fam == "cosmic":
        parts += [COSMIC, ""]
    else:
        parts += [DJ_SHARED, ""]
        if piece in CLASSICAL:
            parts += [CLASSICAL[piece], ""]
    # ⛔ THE LENGTH IS MEASURED FROM THE FILE, NOT TYPED. This line used to say
    # "a 36-second cut" as a literal, which was true of the Shorts it was written
    # for and silently wrong for every Short cut to a different length since.
    mp4 = OUT / piece / "video" / f"{piece}-{kind}.mp4"
    secs = None
    if mp4.exists():
        r = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                            "format=duration", "-of", "csv=p=0", str(mp4)],
                           capture_output=True, text=True)
        try:
            secs = float(r.stdout.strip())
        except ValueError:
            secs = None
    if kind == "short" and secs:
        parts += [f"This is a {secs:.0f}-second cut chosen to contain the piece's "
                  f"climax rather than to start at a round number. The full "
                  f"version is on the channel.", ""]
    elif kind == "loopshort":
        lj = OUT / piece / f"{piece}-loop.json"
        bars = json.loads(lj.read_text())["bars"] if lj.exists() else 8
        cycles = bars // 8
        parts += [f"This one loops. It is an exact {bars}-bar cut — "
                  f"{cycles} complete turn{'s' if cycles != 1 else ''} of the "
                  f"8-bar chord cycle in this music — so the chord that "
                  f"follows the last bar is the chord the first bar starts on — "
                  f"it can repeat indefinitely without a seam. The reverb tail is "
                  f"carried across the join rather than cut off. "
                  f"{secs:.0f} seconds; the full five-minute version is on the "
                  f"channel.", ""]
    elif kind == "handovershort":
        parts += [f"This is {secs:.0f} seconds cut around the handover itself, "
                  f"found by measuring where the incoming energy overtakes the "
                  f"outgoing one in their separately bounced tracks rather than "
                  f"by trusting the written form. It fades in and out, so a "
                  f"replay meets silence instead of a step. The full five-minute "
                  f"version is on the channel.", ""]
    parts += [VIZ, "", ABOUT, "", "Made with DAW Pro."]
    desc = "\n".join(parts).strip()

    meta = {
        "title": t,
        "description": desc,
        "tags": TAGS[fam],
        "categoryId": "10",
        "privacyStatus": "private",
        # see the module docstring — instrumental synth music is not what this
        # disclosure is for; the narrated film is, and carries it.
        "containsSyntheticMedia": False,
        "madeForKids": False,
    }
    assert len(meta["title"]) <= 100, f"{piece} {kind}: title {len(meta['title'])}"
    assert len(meta["description"]) <= 5000
    return meta


if __name__ == "__main__":
    rows = []
    for d in sorted(OUT.iterdir()):
        if not (d / "build.json").exists():
            continue
        # ⭐ `short` IS STILL GENERATED FOR THE PIECES THAT SHIP ONE. The five
        # five-minute pieces ship a `loopshort` INSTEAD — their old 36-second
        # cuts were deleted from the channel on 2026-09-21 once the looping
        # replacements were verified live, so generating metadata for them would
        # invite a re-upload of something deliberately removed.
        kinds = ("long", "loopshort") if (d / "video" / f"{d.name}-loopshort.mp4").exists() \
            else ("long", "short")
        if (d / "video" / f"{d.name}-handovershort.mp4").exists():
            kinds = kinds + ("handovershort",)
        for kind in kinds:
            mp4 = d / "video" / f"{d.name}-{kind}.mp4"
            if not mp4.exists():
                continue
            meta = build(d.name, kind)
            dest = PUB / f"{d.name}-{kind}.json"
            dest.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
            rows.append((mp4, dest, meta["title"]))

    print(f"{len(rows)} videos\n")
    for mp4, dest, title in rows:
        mb = mp4.stat().st_size / 1048576
        print(f"{mb:7.1f}M  {mp4.relative_to(HERE)}")
        print(f"          {dest.relative_to(HERE)}")
        print(f"          “{title}”\n")

    # ⭐ A LIST A PERSON CAN ACTUALLY WORK FROM. The API caps at ~6 uploads a day
    # (1600 quota units each against 10,000), so most of these get dragged into
    # Studio by hand — which means the title and description have to be somewhere
    # copy-pasteable, not only inside a JSON file the uploader reads.
    md = ["# Upload list",
          "",
          "Every finished video, with the title and description to paste into "
          "YouTube Studio. Drag the `.mp4` in, then copy the two fields below it.",
          "",
          "**All 39 are already on the channel as private drafts — do not "
          "upload any of them again.** Making them visible is yours to do; the "
          "uploader only ever creates private drafts.",
          "",
          "> An earlier version of this page said the API caps at about six "
          "uploads a day. That was my arithmetic, and it was wrong — 33 went "
          "through in one day. I had planned around the wrong number and told "
          "you so; probing the limit was what corrected it.",
          "",
          "## ✅ Ten had wrong metadata — already repaired on the channel",
          "",
          "These went up before two mistakes were caught. Both are now fixed "
          "**on YouTube**, not just here, and verified by reading them back. "
          "Nothing for you to do; listed so you know what changed under you.",
          "",
          "**Wrong bar count in the description** — the form tables changed and "
          "the prose did not follow, so these claimed bar counts no section has "
          "(14/18/20 against the real 16/24/24):",
          ""]
    for stem in STALE_DESC:
        md.append(f"- `{stem}` — {UPLOADED[stem]}")
    md += ["",
          "**Title said “· long” on a Short** — “· long” is part of the piece's "
          "own name for the long-form cuts, and the Short inherited it, so the "
          "title contradicted itself. The video itself was always fine:",
          ""]
    for stem in STALE_TITLE:
        md.append(f"- `{stem}` — {UPLOADED[stem]}")
    md += ["",
          "### Everything on the channel",
          ""]
    for stem, url in sorted(UPLOADED.items()):
        md.append(f"- `{stem}` — {url}")
    md += ["",
          "Set **Category: Music**, **Not made for kids**, and leave "
          "*Altered content* **No** — these are instrumental pieces played by "
          "software synthesizers, not synthetic depictions of anyone. "
          "(The narrated demo film is the exception and is flagged Yes.)",
          ""]
    for mp4, dest, title in rows:
        meta = json.loads(dest.read_text())
        mb = mp4.stat().st_size / 1048576
        done = " ✅ ALREADY UPLOADED" if dest.stem in UPLOADED else ""
        md += [f"## {title}{done}", "",
               f"`{mp4.relative_to(HERE)}` — {mb:.1f} MB", "",
               "<details><summary>Description</summary>", "",
               "```text", meta["description"], "```", "",
               f"Tags: `{', '.join(meta['tags'])}`", "", "</details>", ""]
    (PUB / "UPLOAD-LIST.md").write_text("\n".join(md))
    print(f"wrote {(PUB / 'UPLOAD-LIST.md').relative_to(HERE)}")
