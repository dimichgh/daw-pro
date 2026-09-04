#!/usr/bin/env python3
"""Build a branded vertical Short from one JSON spec.

Eleven Shorts hand-coded is eleven chances to get the brand slightly wrong.
This takes a spec — card templates plus narration — and does the whole run:
render cards, narrate through the content gate, render themed intro/outro,
assemble, verify, and check the product name as a literal substring.

    python3 shortsmith.py spec.json --out-dir WORKDIR [--skip-narrate]

Needs the omlx speech server on :8000 (see the narrated-film plugin) unless
--skip-narrate is given.

⚠ Two rules learned the hard way and enforced here:
  * An aggregate transcript score CANNOT gate a product name. 4 of 5 takes
    said "DW Pro"/"DAO Pro" at 0.78-0.88 similarity. Every stage whose script
    contains a `brandCheck` string is re-generated until the transcript
    literally contains it.
  * verify.py's content gate is INVALID below 3 stages / 45 s and reports
    BROKEN rather than ok. For a Short that is expected; the content evidence
    is the per-line gate plus the substring check, and both are printed.
"""
import argparse
import base64
import difflib
import json
import os
import re
import subprocess
import sys
import urllib.request
import uuid

from PIL import Image, ImageDraw, ImageFont

W, H = 1080, 1920          # portrait by default; set_size() switches to landscape


def set_size(w, h):
    """Lessons are 16:9, Shorts are 9:16, and every template centres on W."""
    global W, H
    W, H = int(w), int(h)
BG = (11, 13, 18)
DIM = (150, 158, 175)
WHITE = (238, 242, 255)
SF = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"

REPO = "/Users/dsemenov/Views/daw-pro"
PLUGIN = f"{REPO}/plugins/narrated-film"
VENV = f"{PLUGIN}/.venv/bin/python"
BRANDJSON = f"{REPO}/claude-plugin/skills/demo-film/brand.json"
STING = os.path.expanduser("~/Movies/sting-norm.wav")
BASE = os.environ.get("OMLX_BASE", "http://127.0.0.1:8000")
TTS = "mlx-community--VoxCPM2-bf16"
STT = "mlx-community--whisper-large-v3-turbo-asr-fp16"

REF_WAV = f"{PLUGIN}/assets/reference-voice.wav"
REF_TEXT = ("Every user facing action in DAW Pro is exposed twice. Once as a command "
            "over a WebSocket, and again as a tool on an MCP server. So an AI can drive "
            "this workstation directly, note by note and knob by knob.")

# Theme accents, mirroring brand.json's themes so cards match their own intro.
ACCENT = {
    "theory":    ((130, 205, 255), (180, 140, 255)),
    "classical": ((255, 198, 122), (226, 170, 112)),
    "mastering": ((255, 146, 92),  (255, 96, 124)),
    "history":   ((214, 192, 150), (178, 156, 206)),
    "quicktip":  ((118, 255, 196), (92, 222, 255)),
    "remix":     ((124, 240, 255), (255, 120, 220)),
}


def fnt(p, s):
    return ImageFont.truetype(p, s)


def centre(d, text, font, y, fill, track=0):
    if track:
        ws = [d.textlength(c, font=font) for c in text]
        x = (W - (sum(ws) + track * (len(text) - 1))) / 2
        for c, cw in zip(text, ws):
            d.text((x, y), c, font=font, fill=fill)
            x += cw + track
    else:
        d.text(((W - d.textlength(text, font=font)) / 2, y), text, font=font, fill=fill)


def fit(d, text, path, size, maxw=None):
    """Shrink until it fits. Text that runs off a 1080px frame is a bug, and
    nothing downstream can see it -- the first list title built here overflowed
    and rendered as "AT ACTUALLY HAPPEN", which is a valid PNG and a valid
    video and completely wrong."""
    maxw = maxw or int(W * 0.87)
    while size > 16 and d.textlength(text, font=fnt(path, size)) > maxw:
        size -= 2
    return fnt(path, size)


def fit_tracked(d, text, path, size, track, maxw=None):
    """Same, but letter-spacing adds (n-1)*track that textlength does not know
    about. Fitting without it is how a tracked title still overflows."""
    maxw = maxw or int(W * 0.87)
    while size > 12:
        f = fnt(path, size)
        w = sum(d.textlength(c, font=f) for c in text) + track * (len(text) - 1)
        if w <= maxw:
            return f
        size -= 2
    return fnt(path, size)


# ------------------------------------------------------------------ templates
def card_statement(d, c, A, B):
    y = c.get("y") or (520 if H > W else 300)
    for i, line in enumerate(c["lines"]):
        f = fit(d, line, SF, c.get("size", 88))
        centre(d, line, f, y, WHITE, track=2)
        y += c.get("size", 88) + 18
    if c.get("rule", True):
        y += 20
        d.line([(W * 0.22, y), (W * 0.78, y)], fill=A, width=3)
        y += 60
    for line in c.get("sub", []):
        f = fit(d, line, SF, 46)
        centre(d, line, f, y, DIM)
        y += 62
    if c.get("punch"):
        y += 40
        f = fit(d, c["punch"], SF, c.get("punchSize", 76))
        centre(d, c["punch"], f, y, A, track=3)


def card_bignumber(d, c, A, B):
    y = c.get("y") or (470 if H > W else 210)
    centre(d, c["label"], fnt(MONO, 40), y, B, track=8)
    f = fit(d, c["value"], SF, c.get("size", 220), maxw=980)
    centre(d, c["value"], f, y + 100, A)
    y2 = y + 100 + c.get("size", 220) * 1.14
    if c.get("unit"):
        centre(d, c["unit"], fnt(MONO, 46), y2, WHITE, track=10)
        y2 += 90
    d.line([(W * 0.20, y2 + 30), (W * 0.80, y2 + 30)], fill=A, width=3)
    y2 += 90
    for line in c.get("notes", []):
        f = fit(d, line, SF, 40)
        centre(d, line, f, y2, DIM)
        y2 += 58


def card_list(d, c, A, B):
    step = c.get("step", 96)
    rows = c["items"]
    # Centre the block instead of hanging it off a magic top margin.
    block = 130 + step * len(rows)
    top = c.get("y") or int((H - block) / 2)
    centre(d, c["title"], fit_tracked(d, c["title"], MONO, 40, 6), top, B, track=6)

    # ONE size for every right-hand cell: fitting each row independently made
    # a single long row render smaller than its neighbours, which reads as a
    # mistake rather than as emphasis.
    rsize = 42
    for it in rows:
        if isinstance(it, list) and len(it) > 1 and it[1]:
            while rsize > 20 and d.textlength(str(it[1]), font=fnt(SF, rsize)) > W * 0.52:
                rsize -= 2
    y = top + 130
    for item in rows:
        left, right = (item + ["", ""])[:2] if isinstance(item, list) else (item, "")
        hot = isinstance(item, list) and len(item) > 2 and item[2] == "hot"
        d.text((W * 0.16, y), str(left), font=fnt(MONO, 46), fill=A if hot else WHITE)
        if right:
            d.text((W * 0.39, y + 6), str(right), font=fnt(SF, rsize), fill=A if hot else DIM)
        y += step


def card_closing(d, c, A, B):
    y = c.get("y") or (620 if H > W else 340)
    for line in c["lines"]:
        f = fit(d, line, SF, c.get("size", 60))
        centre(d, line, f, y, WHITE)
        y += c.get("size", 60) + 26
    if c.get("kicker"):
        y += 40
        f = fit(d, c["kicker"], SF, 46)
        centre(d, c["kicker"], f, y, A)


TEMPLATES = {"statement": card_statement, "bignumber": card_bignumber,
             "list": card_list, "closing": card_closing}


def render_cards(spec, outdir):
    A, B = ACCENT[spec["theme"]]
    paths = []
    for i, c in enumerate(spec["cards"]):
        if c["type"] not in TEMPLATES:
            sys.exit(f"unknown card type {c['type']!r}; known: {sorted(TEMPLATES)}")
        im = Image.new("RGB", (W, H), BG)
        TEMPLATES[c["type"]](ImageDraw.Draw(im), c, A, B)
        p = os.path.join(outdir, f"card{i:02d}.png")
        im.save(p)
        paths.append(os.path.basename(p))
    print(f"  cards  : {len(paths)} rendered")
    return paths


# ------------------------------------------------------------------ narration
def _ref():
    return base64.b64encode(open(REF_WAV, "rb").read()).decode()


def synth(text, out, temperature=0.35):
    body = {"model": TTS, "input": text, "ref_audio": _ref(), "ref_text": REF_TEXT,
            "response_format": "wav", "stream": False, "temperature": temperature,
            "top_p": 0.85, "top_k": 40, "repetition_penalty": 1.1}
    r = urllib.request.Request(f"{BASE}/v1/audio/speech", data=json.dumps(body).encode(),
                               headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=1200) as x:
        open(out, "wb").write(x.read())


def transcribe(path):
    b = uuid.uuid4().hex
    parts = []
    for n, v in (("model", STT), ("response_format", "json"), ("language", "en")):
        parts.append(f"--{b}\r\nContent-Disposition: form-data; name=\"{n}\"\r\n\r\n{v}\r\n".encode())
    parts.append((f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; "
                  "filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n").encode()
                 + open(path, "rb").read() + b"\r\n")
    parts.append(f"--{b}--\r\n".encode())
    r = urllib.request.Request(f"{BASE}/v1/audio/transcriptions", data=b"".join(parts),
                               headers={"Content-Type": f"multipart/form-data; boundary={b}"})
    with urllib.request.urlopen(r, timeout=900) as x:
        return json.loads(x.read()).get("text", "").strip()


# Number words the SCRIPT uses versus the digits WHISPER writes back. Comparing
# them naively is a trap: "four hundred and forty in eighteen thirty four" comes
# back as "440 in 1834", and a PERFECT take scored 0.65 -- below the floor,
# which would have thrown away good audio and burned eight generations doing it.
# The channel's own rule (spell numbers out, so the TTS reads them properly)
# is what creates the mismatch, so the metric has to absorb it.
NUMWORDS = set("""zero one two three four five six seven eight nine ten eleven
twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty
thirty forty fifty sixty seventy eighty ninety hundred thousand million point
first second third fourth fifth sixth seventh eighth ninth tenth twelfth
nineties eighties seventies sixties and""".split())

_num = re.compile(r"[\d][\d,.:]*")
_punct = re.compile(r"[^\w\s]")


def _words(t):
    """Words with numbers and number-words removed, for the PROSE comparison."""
    t = _num.sub(" ", _punct.sub(" ", t.lower()))
    return [w for w in t.split() if w not in NUMWORDS]


def sim(a, b):
    """Similarity over prose only. Numbers are checked separately and exactly,
    via `factCheck` -- an aggregate cannot gate a short critical substring, and
    on this channel the numbers ARE the critical substrings."""
    return difflib.SequenceMatcher(None, _words(a), _words(b), autojunk=False).ratio()


def fact_missing(facts, got):
    """Which required substrings are absent -- accepting SPELLING VARIANTS.

    ⚠ The first version compared one literal string, and rejected eight
    consecutive PERFECT takes of "seventy two beats per minute" because the
    transcriber writes "72". The number was right, the delivery was right, and
    the gate was wrong. A factCheck entry may therefore be a LIST: any one
    spelling satisfies it. The entry is still a hard requirement -- this
    loosens WHICH FORM counts, never WHETHER the number has to be there."""
    g = got.lower()
    out = []
    for f in facts:
        alts = f if isinstance(f, (list, tuple)) else [f]
        if not any(str(a).lower() in g for a in alts):
            out.append(alts[0])
    return out


def narrate(spec, vodir, tries=8, floor=0.80):
    os.makedirs(vodir, exist_ok=True)
    report = []
    for st in spec["stages"]:
        text = st["narration"]
        need = st.get("brandCheck")
        facts = st.get("factCheck", [])
        out = os.path.join(vodir, f"{st['id']}.wav")
        best = None
        for i in range(1, tries + 1):
            tmp = os.path.join(vodir, f"_try{i}.wav")
            synth(text, tmp, 0.35 if i < 4 else 0.30)
            got = transcribe(tmp)
            s = sim(text, got)
            ok_brand = (need.lower() in got.lower()) if need else True
            missing = fact_missing(facts, got)
            if s >= floor and ok_brand and not missing:
                os.replace(tmp, out)
                best = (i, s, got)
                break
            if best is None or s > best[1]:
                best = (i, s, got, missing)
                if not need and not facts:
                    os.replace(tmp, out)
        else:
            if need or facts:
                sys.exit(f"✘ {st['id']}: {tries} takes, none satisfied "
                         f"brand={need!r} facts={facts}. Best missed {best[3]}, "
                         f"transcript: {best[2]!r}")
        i, s, got = best[0], best[1], best[2]
        bits = []
        if need:
            bits.append(f"brand OK")
        if facts:
            bits.append(f"facts OK ({len(facts)})")
        # ⚠ Never accept a sub-floor take in silence. The whole point of the gate
        # is that bad audio measures healthy.
        if s < floor:
            bits.append(f"⚠ BELOW FLOOR {floor}")
        print(f"  vo     : {st['id']} take {i} sim {s:.2f}"
              + ("  " + ", ".join(bits) if bits else ""))
        report.append({"stage": st["id"], "take": i, "sim": round(s, 3),
                       "brandCheck": need, "factCheck": facts,
                       "belowFloor": s < floor, "transcript": got})
    return report


# ------------------------------------------------------------------- assembly
def run(cmd, quiet=True):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"FAILED: {' '.join(cmd[:6])}\n{p.stdout[-800:]}\n{p.stderr[-1500:]}")
    return p.stdout


def ab_shots(ab, shots):
    """Translate an A/B block's beforeShots/afterShots from CARD INDICES (how
    every other stage refers to a card) into the basenames assemble.py
    resolves. Without distinct stills both halves show the identical card and
    only the small badge separates them -- which reads as a frozen video."""
    ab = dict(ab)
    for k in ("beforeShots", "afterShots"):
        if ab.get(k):
            ab[k] = [shots[i] for i in ab[k]]
    return ab


def build(spec, outdir, skip_narrate=False):
    os.makedirs(outdir, exist_ok=True)
    print(f"\n=== {spec['id']}  {spec['title']}  [{spec['theme']}] ===")
    shots = render_cards(spec, outdir)

    man = {"video": {"width": W, "height": H, "fps": 30,
                     "cut": spec.get("cut", 4.2), "bed": 0.16,
                     "playMax": spec.get("playMax", 14.0)},
           "stages": [{"id": s["id"], "narration": s["narration"],
                       "shots": [shots[i] for i in s["shots"]],
                       "cut": s.get("cut", spec.get("cut", 4.2)),
                       # a stage may carry its own audio example, played clean
                       **({"loop": s["loop"]} if s.get("loop") else {}),
                       # A loop that is a MEASUREMENT (test tones, a beat rate,
                       # an isolated artefact) must not linger as a bed under
                       # the next narration. Default stays true: real music
                       # under a voice is normal and good.
                       **({"bedEligible": False}
                          if s.get("bedEligible", True) is False else {}),
                       # An A/B stage alternates BEFORE/AFTER on the same
                       # passage with badges -- assemble.py already implements
                       # it; shortsmith just never passed it through, so a
                       # spec's `ab` block was silently dropped and the stage
                       # played only the AFTER file. Nothing errored.
                       **({"ab": ab_shots(s["ab"], shots)} if s.get("ab") else {}),
                       **({"holdLast": True} if s.get("holdLast", True) else {})}
                      for s in spec["stages"]]}
    manp = os.path.join(outdir, "manifest.json")
    json.dump(man, open(manp, "w"), ensure_ascii=False, indent=2)

    vodir = os.path.join(outdir, "vo")
    report = [] if skip_narrate else narrate(spec, vodir)

    intro = os.path.join(outdir, "intro.mp4")
    outro = os.path.join(outdir, "outro.mp4")
    run([VENV, f"{PLUGIN}/scripts/brand.py", "intro", "--brand", BRANDJSON,
         "--theme", spec["theme"], "--size", f"{W}x{H}", "--audio", STING,
         "--seconds", str(spec.get("introSeconds", 4)), "--out", intro])
    run([VENV, f"{PLUGIN}/scripts/brand.py", "outro", "--brand", BRANDJSON,
         "--theme", spec["theme"], "--size", f"{W}x{H}",
         "--seconds", str(spec.get("outroSeconds", 3)), "--out", outro])
    print("  cards  : intro + outro rendered")

    film = os.path.join(outdir, f"{spec['id']}.mp4")
    # ⚠ --work IS NOT OPTIONAL HERE. assemble.py defaults it to a RELATIVE
    # "segments", so the intermediates land in whatever directory the builder
    # was standing in -- which put 325 MB at this repo's root and 276 MB under
    # scripts/video before anyone noticed. Keep them beside the film they
    # belong to, where they are obviously disposable.
    run([VENV, f"{PLUGIN}/scripts/assemble.py", "--manifest", manp, "--vo", vodir,
         "--shots", outdir, "--loops", outdir, "--work", os.path.join(outdir, "segments"),
         "--intro", intro, "--outro", outro, "--out", film])

    dur = float(run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                     "-of", "default=nw=1:nk=1", film]).strip())
    print(f"  film   : {film}  {dur:.1f}s")
    if dur > 60:
        print(f"  ⚠ {dur:.1f}s is OVER the 60 s Shorts limit — trim a stage")

    # ⚠ verify.py's --base is the SPEECH SERVER URL, not a directory. Passing
    # the work dir made the content gate report "speech server unreachable" --
    # a BROKEN probe that looks like a film problem and is not one.
    v = subprocess.run([VENV, f"{PLUGIN}/scripts/verify.py", "--film", film,
                        "--manifest", manp], capture_output=True, text=True)
    fails = []
    for line in v.stdout.splitlines():
        if line.startswith("[") or "FAIL" in line:
            print("  " + line)
        if line.lstrip().startswith("[ FAIL ]"):
            fails.append(line.strip())
    json.dump({"spec": spec["id"], "duration": dur, "narration": report,
               "verifyFails": fails},
              open(os.path.join(outdir, "build-report.json"), "w"), indent=2)
    # ⚠ A [ FAIL ] USED TO BE PRINTED AND THEN IGNORED. The Amen lesson failed
    # its true-peak check and was copied to ~/Movies anyway, one line below the
    # word FAIL. A gate nobody obeys is decoration -- shipping now stops here.
    # (verify.py's [BROKEN] is different: it means the probe could not judge,
    # which is the documented state for a Short, and does not block.)
    if fails:
        raise SystemExit("REFUSING TO SHIP — verify.py failed:\n  "
                         + "\n  ".join(fails))
    return film, dur


MOVIES = os.path.expanduser("~/Movies")


def finalize(spec, film):
    """Copy to ~/Movies under its shipping name and write the publish sidecar."""
    name = spec["filename"]
    dest = os.path.join(MOVIES, name + ".mp4")
    subprocess.run(["cp", film, dest], check=True)
    meta = {
        "title": spec["title"],
        "description": spec["description"],
        "tags": spec.get("tags", []),
        "categoryId": spec.get("categoryId", "27"),
        "defaultLanguage": "en",
        "privacyStatus": "private",
        # ⚠ TRUE, and it stays true for anything this pipeline makes: every
        # film here is narrated by a synthetic voice. It shipped as False and
        # 25 sidecars had to be corrected by hand. If a future film has NO
        # synthetic narration, turn it off in that one spec -- do not flip the
        # default back.
        "containsSyntheticMedia": True,
        "madeForKids": False,
        "playlist": spec.get("playlist", "Shorts"),
    }
    mp = os.path.join(MOVIES, name + ".publish.json")
    json.dump(meta, open(mp, "w"), ensure_ascii=False, indent=2)
    v = subprocess.run([VENV, f"{PLUGIN}/scripts/publish.py", "validate",
                        "--film", dest, "--meta", mp], capture_output=True, text=True)
    print(f"  ship   : {dest}")
    print("  meta   : " + v.stdout.strip().splitlines()[-1].strip())
    return dest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("spec")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--skip-narrate", action="store_true")
    ap.add_argument("--size", default="1080x1920", help="WxH; 1920x1080 for a lesson")
    ap.add_argument("--finalize", action="store_true",
                    help="copy to ~/Movies and write the publish.json sidecar")
    a = ap.parse_args()
    spec = json.load(open(a.spec))
    w, h = (int(x) for x in (spec.get("size") or a.size).lower().split("x"))
    set_size(w, h)
    if spec["theme"] not in ACCENT:
        sys.exit(f"unknown theme {spec['theme']!r}; known: {sorted(ACCENT)}")
    film, dur = build(spec, a.out_dir, a.skip_narrate)
    if a.finalize:
        finalize(spec, film)


if __name__ == "__main__":
    main()
