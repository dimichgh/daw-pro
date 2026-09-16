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
import hashlib
import json
import math
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
    # ⚠ fit_tracked, NOT fnt: a tracked label wider than the frame renders as a
    # valid PNG with its first and last letters sliced off. "THE SIREN, MEASURED"
    # shipped once as "E SIREN, MEASUR" -- the list title had this fix and the
    # big-number label did not.
    centre(d, c["label"], fit_tracked(d, c["label"], MONO, 40, 8), y, B, track=8)
    f = fit(d, c["value"], SF, c.get("size", 220), maxw=980)
    centre(d, c["value"], f, y + 100, A)
    y2 = y + 100 + c.get("size", 220) * 1.14
    if c.get("unit"):
        centre(d, c["unit"], fit_tracked(d, c["unit"], MONO, 46, 10), y2, WHITE, track=10)
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
    # The left column is a COLUMN: it stops at 0.39 where the right one starts.
    # Without this, a long key silently draws THROUGH its own value -- "the
    # fundamental never moved" shipped once overlapping "44 Hz in all three".
    # One size for every key, same reasoning as the right column above.
    lsize, lmax = 46, W * 0.21
    for it in rows:
        left = str(it[0] if isinstance(it, list) else it)
        while lsize > 22 and d.textlength(left, font=fnt(MONO, lsize)) > lmax:
            lsize -= 2
    y = top + 130
    for item in rows:
        left, right = (item + ["", ""])[:2] if isinstance(item, list) else (item, "")
        hot = isinstance(item, list) and len(item) > 2 and item[2] == "hot"
        d.text((W * 0.16, y), str(left), font=fnt(MONO, lsize), fill=A if hot else WHITE)
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


def _synth_one(text, out, temperature=0.35):
    body = {"model": TTS, "input": text, "ref_audio": _ref(), "ref_text": REF_TEXT,
            "response_format": "wav", "stream": False, "temperature": temperature,
            "top_p": 0.85, "top_k": 40, "repetition_penalty": 1.1}
    r = urllib.request.Request(f"{BASE}/v1/audio/speech", data=json.dumps(body).encode(),
                               headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=1200) as x:
        open(out, "wb").write(x.read())


# ----------------------------------------------------- chunked synthesis + echo
# ⭐ WHY THIS EXISTS, AND IT IS MEASURED, NOT INFERRED.
# A listener reported "a background self-feeding echo when narration goes too
# long". It is real, and it is a property of TAKE LENGTH, not of the words. The
# controlled pair -- the SAME 1,432 characters, once as one take and once as two
# -- measured, as the 10th-percentile "gap floor" inside each fifth of the take:
#   1,432 ch, ONE take   58.1 s  20 ms-RMS peak -7.1 dB  -50.3 -42.2 -33.1 -28.8 -28.3
#     715 ch, take A     31.7 s        (sample peak is -0.4 to -1.6 dBFS on
#     716 ch, take B     31.5 s         every take; the two are not the same
#                                    number and echo_floor() reports the SAMPLE one)
#     715 / 716 ch floors:  -45.4 -50.3 -49.3 -43.2 -41.8  /  -42.1 -68.6 -46.9 -47.1 -40.3
# The pauses in the long take end up only ~21 dB under the voice; in the split
# takes they stay 34-41 dB under. Nothing here explains WHY the floor climbs --
# "self-feeding" is the listener's name for the sound, not a mechanism I have
# shown. What is established is the correlation with length and that splitting
# removes it.
#
# ⚠ IT IS NOT DETERMINISTIC, so a chunk budget alone is not a fix. Measured
# across one film's 16 stages, 12-film is 1,093 characters and clean (ends
# -42.8 dB) while 07-converge is 848 and affected (ends -27.8). That is why
# echo_floor() below is also wired into narrate() as a take-PREFERENCE:
# chunking lowers the odds, the measurement catches the residual.
#
# ⭐ THE BUDGET IS MEASURED, not chosen. The worst stage of one film (1,134
# characters, gap floor ending -26.9 dB) was re-synthesised at three budgets:
#   600 -> 2 chunks  -49.4 -45.4 -48.9 -51.6 -37.4   (better, still marginal)
#   400 -> 4 chunks  -47.6 -49.6 -54.1 -53.2 -49.3   (clean)
#   300 -> 5 chunks  -68.6 -63.1 -51.1 -59.4 -60.9   (clean by a wide margin)
# Transcribe-back similarity was 0.951 / 0.934 / 0.951 -- unchanged -- and the
# synthesis took 32/34/33 s against 38 s for the single take, so splitting is
# not slower. 300 is the value this pipeline uses.
#
# ⚠ OFF BY DEFAULT, deliberately. Enabling it changes vo_key, which re-records
# every cached take of every film on its next build. Set VO_CHUNK_CHARS (600 is
# the measured value) to opt a film in; flip CHUNK_DEFAULT to make it universal,
# but not while another film's build is in flight.
CHUNK_DEFAULT = 0                      # characters; 0 = one take per stage (300 = on)
CHUNK_METHOD = "chunk-v1"              # bump to force a re-record of chunked vo
CHUNK_GAP_S = 0.30                     # measured inter-sentence pause: 0.25-0.40 s
ECHO_FLOOR_DB = -38.0                  # final-fifth gap floor must be AT OR BELOW


def chunk_chars():
    try:
        return int(os.environ.get("VO_CHUNK_CHARS", CHUNK_DEFAULT))
    except ValueError:
        return CHUNK_DEFAULT


def split_for_synth(text, budget):
    """Greedily pack whole SENTENCES up to `budget` characters. Never splits a
    sentence -- a half sentence is synthesised with the wrong prosody, and the
    join is then audible as a stumble rather than a breath."""
    if budget <= 0 or len(text) <= budget:
        return [text]
    sents = re.split(r"(?<=[.!?])\s+", text.strip())
    # ⚠ EVEN packing, not greedy. Greedy at 400 chars produced chunks of
    # 372/344/353/62 -- a 62-character runt synthesised on its own, which is a
    # different prosody problem from the one being fixed. Aim at len/n instead.
    n = max(1, math.ceil(len(text) / budget))
    target = len(text) / n
    out, cur = [], ""
    for sent in sents:
        if cur and len(cur) + 1 + len(sent) > target:
            out.append(cur)
            cur = sent
        else:
            cur = f"{cur} {sent}".strip()
    if cur:
        out.append(cur)
    # ⚠ MERGE RUNTS. A sentence boundary is the only legal cut, so a short
    # sentence followed by a long one can still leave a 69-character chunk, and
    # a two-word chunk synthesised alone comes back with the wrong cadence.
    # Anything under RUNT joins its smaller neighbour, target be damned.
    RUNT = 110
    while len(out) > 1:
        i = min(range(len(out)), key=lambda j: len(out[j]))
        if len(out[i]) >= RUNT:
            break
        j = i - 1 if i == len(out) - 1 else (
            i + 1 if i == 0 else (i - 1 if len(out[i - 1]) <= len(out[i + 1]) else i + 1))
        a, b = min(i, j), max(i, j)
        out[a:b + 1] = [out[a] + " " + out[b]]
    return out


def _rd(path):
    import wave, array
    w = wave.open(path, "rb")
    assert w.getsampwidth() == 2 and w.getnchannels() == 1, f"{path}: expected mono 16-bit"
    a = array.array("h")
    a.frombytes(w.readframes(w.getnframes()))
    sr = w.getframerate()
    w.close()
    return a, sr


def _wr(path, samples, sr):
    import wave, array
    w = wave.open(path, "wb")
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(array.array("h", samples).tobytes())
    w.close()


def _frame_db(a, sr, ms=20):
    """RMS of consecutive `ms` windows, in dBFS. Pure python on purpose: numpy
    is not installed for this interpreter and a 60 s take is only ~3,000 frames."""
    import math
    n = max(1, int(sr * ms / 1000))
    out = []
    for i in range(0, len(a) - n + 1, n):
        acc = 0
        for v in a[i:i + n]:
            acc += v * v
        r = math.sqrt(acc / n) / 32768.0
        out.append(20 * math.log10(r) if r > 1e-9 else -180.0)
    return out


def echo_floor(path, fifths=5):
    """Return (peak_dbfs, [gap floor per fifth]). The floor is the 10th
    percentile of the frame energies inside that fifth -- i.e. how quiet the
    QUIET parts are. A clean take holds its floor; an affected one climbs.

    ⚠ CONFOUND, stated because it bit the first version of this metric: in a
    dense passage with few pauses the 10th percentile lands on speech, so a
    single fifth can read high innocently, and a very quiet lead-in makes the
    FIRST fifth read absurdly low and inflates any 'rise' figure. That is why
    the gate below reads the LAST fifth's absolute value and not the rise."""
    import math
    a, sr = _rd(path)
    db = _frame_db(a, sr)
    peak = max((abs(v) for v in a), default=1) / 32768.0
    peak_db = 20 * math.log10(peak) if peak > 0 else -180.0
    k = max(1, len(db) // fifths)
    floors = []
    for i in range(fifths):
        seg = db[i * k: (i + 1) * k] if i < fifths - 1 else db[i * k:]
        # ⚠ DROP THE DIGITAL SILENCE THIS PIPELINE PUTS THERE ITSELF. synth()
        # joins chunks with 0.30 s of exact zeros, which score -180 and would
        # drag the percentile down -- the measurement would then be flattered by
        # the very thing it is supposed to be judging. No neural vocoder output
        # reaches -100 dBFS in 16-bit; only a run of exact zeros does, so that
        # is a safe discriminator. 15 frames per join against 300-550 per fifth
        # usually would not reach rank 10 % anyway, but "usually" is not a
        # measurement.
        seg = sorted(v for v in seg if v > -100.0)
        floors.append(seg[max(0, int(0.10 * len(seg)))] if seg else -180.0)
    return peak_db, floors


def synth(text, out, temperature=0.35):
    """Synthesise `text`. Long text is split into sentence chunks and joined,
    because a single long take grows an audible wash in its pauses (see above)."""
    budget = chunk_chars()
    chunks = split_for_synth(text, budget)
    if len(chunks) == 1:
        return _synth_one(text, out, temperature)
    parts, sr = [], None
    for i, c in enumerate(chunks):
        tmp = f"{out}.part{i}.wav"
        _synth_one(c, tmp, temperature)
        a, sr = _rd(tmp)
        # Trim each chunk's own lead-in/tail silence at -45 dBFS, keeping 60 ms
        # of pad, so the join gap is the gap we ask for and not that plus two
        # arbitrary tails.
        db = _frame_db(a, sr)
        n = max(1, int(sr * 0.020))
        live = [j for j, v in enumerate(db) if v > -45.0]
        if live:
            pad = int(sr * 0.060)
            a = a[max(0, live[0] * n - pad): min(len(a), (live[-1] + 1) * n + pad)]
        parts.append(a)
        os.remove(tmp)
    gap = [0] * int(sr * CHUNK_GAP_S)
    joined = []
    for i, a in enumerate(parts):
        if i:
            joined.extend(gap)
        joined.extend(a)
    _wr(out, joined, sr)


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
    """Synthesise one take per stage, keeping the best of up to `tries`.

    ⚠ A CACHE, because a whole film's narration is ~30 minutes of wall clock and
    ONE typo in ONE stage's factCheck used to cost all of it. A stage is
    re-narrated only when its TEXT changes; the hash covers the narration and
    both gates, so tightening a gate re-records and a re-run after an unrelated
    edit does not. `--skip-narrate` remains the blunt instrument that reuses
    everything regardless.
    """
    # ⚠ PRE-FLIGHT: a gate that asks for words the SCRIPT does not contain can
    # never pass, and the failure arrives after eight takes and several minutes
    # of synthesis, disguised as a speech problem. It is not a speech problem;
    # it is a typo in the spec. Two real ones cost a build each: a brandCheck
    # for "DAW Pro" against a script that only said "a DAW", and a factCheck for
    # "four bars" against a script that said "four-bar".
    bad = []
    for st in spec["stages"]:
        low = st["narration"].lower()
        need = st.get("brandCheck")
        if need and need.lower() not in low:
            bad.append(f'{st["id"]}: brandCheck {need!r} is not in the narration')
        for f in st.get("factCheck", []):
            alts = f if isinstance(f, (list, tuple)) else [f]
            if not any(str(a).lower() in low for a in alts):
                bad.append(f'{st["id"]}: factCheck {alts[0]!r} is not in the narration')
    if bad:
        raise SystemExit("REFUSING TO NARRATE — a gate cannot pass as written:\n  "
                         + "\n  ".join(bad))

    os.makedirs(vodir, exist_ok=True)
    cachep = os.path.join(vodir, "_cache.json")
    cache = {}
    if os.path.exists(cachep):
        try:
            cache = json.load(open(cachep))
        except Exception:
            cache = {}                       # a corrupt cache re-records, never crashes
    report = []
    for st in spec["stages"]:
        text = st["narration"]
        need = st.get("brandCheck")
        facts = st.get("factCheck", [])
        out = os.path.join(vodir, f"{st['id']}.wav")
        key = vo_key(st)      # ONE definition, shared with verify_cached()
        if cache.get(st["id"]) == key and os.path.exists(out):
            print(f"  vo     : {st['id']} unchanged, kept", flush=True)
            report.append((st["id"], "cached", 1.0))
            continue
        best = None
        # ⚠ THE ECHO CHECK IS A PREFERENCE, NOT A VETO. Armed only when chunking
        # is on. It cannot be a hard gate: a take that is clean on words and
        # merely marginal on the floor is still the best audio available, and
        # failing the build on it would report the miss as a factCheck failure,
        # which is a lie about what went wrong. So: accept immediately on a take
        # that passes everything, otherwise keep the QUIETEST-pauses take among
        # those that passed the word gates, and say what it measured.
        clean = []          # (floor_db, i, sim, transcript, path) -- word gates passed
        for i in range(1, tries + 1):
            tmp = os.path.join(vodir, f"_try{i}.wav")
            synth(text, tmp, 0.35 if i < 4 else 0.30)
            got = transcribe(tmp)
            s = sim(text, got)
            ok_brand = (need.lower() in got.lower()) if need else True
            missing = fact_missing(facts, got)
            words_ok = s >= floor and ok_brand and not missing
            echo_db = None
            if chunk_chars() > 0 and words_ok:
                try:
                    echo_db = echo_floor(tmp)[1][-1]
                except Exception as e:
                    print(f"  vo     : ⚠ echo check unavailable ({e})")
            if words_ok and (echo_db is None or echo_db <= ECHO_FLOOR_DB):
                os.replace(tmp, out)
                best = (i, s, got)
                break
            if words_ok and echo_db is not None:
                keep = os.path.join(vodir, f"_echo{i}.wav")
                os.replace(tmp, keep)
                clean.append((echo_db, i, s, got, keep))
                print(f"  vo     : {st['id']} take {i} words OK but gap floor "
                      f"{echo_db:.1f} dB > {ECHO_FLOOR_DB} — trying again")
                continue
            if best is None or s > best[1]:
                best = (i, s, got, missing)
                if not need and not facts:
                    os.replace(tmp, out)
        if best is None or len(best) == 4:
            if clean:
                clean.sort()
                echo_db, i, s, got, keep = clean[0]
                os.replace(keep, out)
                best = (i, s, got)
                print(f"  vo     : {st['id']} kept take {i} — quietest of "
                      f"{len(clean)}, gap floor {echo_db:.1f} dB (over "
                      f"{ECHO_FLOOR_DB}; words all pass)")
        for _, _, _, _, keep in clean:
            if os.path.exists(keep):
                os.remove(keep)
        # ⚠ THIS WAS A for/else. It stopped meaning what it said the moment a
        # second for loop was written above it -- `else` binds to the NEAREST
        # for, so it would have fired on every stage that has a factCheck,
        # regardless of whether a take had been accepted. Written out.
        if best is not None and len(best) == 4 and (need or facts):
            sys.exit(f"✘ {st['id']}: {tries} takes, none satisfied "
                     f"brand={need!r} facts={facts}. Best missed {best[3]}, "
                     f"transcript: {best[2]!r}")
        i, s, got = best[0], best[1], best[2]
        cache[st["id"]] = key                 # only reached once a take is kept
        json.dump(cache, open(cachep, "w"))
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


def vo_key(st):
    """The cache key for one stage -- text plus both gates, exactly as narrate()
    computes it. Split out so --skip-narrate can check what narrate() wrote."""
    # ⚠ THE SYNTHESIS METHOD IS PART OF THE KEY. Without this, turning chunking
    # on kept every echo-era take in the cache and the fix shipped to nothing.
    # It also means opting a film in re-records all of it -- that is the intent.
    return hashlib.sha256(json.dumps(
        [st["narration"], st.get("brandCheck"), st.get("factCheck", []),
         (CHUNK_METHOD, chunk_chars()) if chunk_chars() else None],
        sort_keys=True).encode()).hexdigest()


def verify_cached(spec, vodir):
    """Refuse to assemble a film out of takes that do not match its script.

    ⚠ THIS EXISTS BECAUSE IT HAPPENED. A vo file is named for its STAGE ID, so
    two specs built into ONE --out-dir share the directory: this film and its
    six Shorts both have a stage called `01-hook`, and the Shorts were built
    second. A later `--skip-narrate` rebuild of the film then assembled the
    SHORT's opening line into the film -- 51 words of script playing 14 words of
    audio -- and every one of the eight gates passed it, because each of them
    measures the file that exists rather than the script it was supposed to say.
    The film came out 11 seconds shorter and nothing said why.

    `--skip-narrate` skips SYNTHESIS. It was never meant to skip knowing whether
    the take on disk belongs to this spec.
    """
    cachep = os.path.join(vodir, "_cache.json")
    cache = {}
    if os.path.exists(cachep):
        try:
            cache = json.load(open(cachep))
        except Exception:
            cache = {}
    bad = []
    for st in spec["stages"]:
        out = os.path.join(vodir, f"{st['id']}.wav")
        if not os.path.exists(out):
            bad.append(f"{st['id']}: no take on disk at {out}")
        elif cache.get(st["id"]) != vo_key(st):
            bad.append(f"{st['id']}: the take on disk was recorded from "
                       f"DIFFERENT text or gates")
    if bad:
        raise SystemExit(
            "REFUSING TO ASSEMBLE — --skip-narrate would use takes that do not\n"
            "match this spec. Drop --skip-narrate to re-record just these:\n  "
            + "\n  ".join(bad))


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
            ab[k] = [shots[i] if isinstance(i, int) else i for i in ab[k]]
    return ab


def build(spec, outdir, skip_narrate=False):
    os.makedirs(outdir, exist_ok=True)
    print(f"\n=== {spec['id']}  {spec['title']}  [{spec['theme']}] ===")
    shots = render_cards(spec, outdir)

    man = {"video": {"width": W, "height": H, "fps": 30,
                     "cut": spec.get("cut", 4.2), "bed": 0.16,
                     "playMax": spec.get("playMax", 14.0)},
           "stages": [{"id": s["id"], "narration": s["narration"],
                       # A stage shot is EITHER an int (an index into the
                       # rendered cards) OR a captured image -- a path, or
                       # {"path":…, "zoom":[x,y,w,h], "to":[…]} to cut into a
                       # region of it. Cards-only was the original design and it
                       # made it impossible to put the APP on screen, which is
                       # the whole point of a session film.
                       "shots": [shots[i] if isinstance(i, int) else i
                                 for i in s["shots"]],
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
                       # a directory of frames photographed WHILE THE TRANSPORT
                       # RAN: the play segment becomes the playhead actually
                       # crossing the notes instead of a frozen picture.
                       **({"burst": s["burst"]} if s.get("burst") else {}),
                       # ⚠ OPT OUT OF loudnorm ON A LOUDNESS LESSON. assemble's
                       # play segments run a single-pass loudnorm, which is
                       # dynamic -- MEASURED, it INVERTED a real 2.1 LU
                       # difference between a compressor A/B's two halves. A
                       # stage that is demonstrating LEVEL sets this false and
                       # pre-gains its own wavs statically.
                       **({"normalize": False}
                          if s.get("normalize", True) is False else {}),
                       # A play segment that IS a rendered chart has a fixed
                       # length; the film-wide playMax would cut it mid-sweep.
                       **({"playMax": s["playMax"]} if s.get("playMax") else {}),
                       **({"holdLast": True} if s.get("holdLast", True) else {})}
                      for s in spec["stages"]]}
    manp = os.path.join(outdir, "manifest.json")
    json.dump(man, open(manp, "w"), ensure_ascii=False, indent=2)

    # A `burst` that resolves to nothing degrades to a frozen still — visible
    # only by watching the film. Say it at build time instead.
    bdir = spec.get("bursts") or os.path.join(outdir, "bursts")
    for st in spec["stages"]:
        b = st.get("burst")
        if b and not os.path.exists(os.path.join(bdir, b, "meta.json")):
            print(f"  ⚠ burst  : {st['id']} names '{b}' but {bdir}/{b}/meta.json "
                  f"is missing — that stage will show a STILL, not motion")

    vodir = os.path.join(outdir, "vo")
    if skip_narrate:
        verify_cached(spec, vodir)
        # ⚠⚠ AN EMPTY LIST IS NOT A RECORD OF A SKIP -- it reads as "no stages
        # were narrated", which is the same shape as a real failure. Three
        # --skip-narrate rebuilds of HWB3 overwrote a good narration record with
        # [], and the per-take scores survived only in build.log. Carry the last
        # real record forward and SAY that is what happened.
        prev = os.path.join(outdir, "build-report.json")
        report = []
        if os.path.exists(prev):
            try:
                report = json.load(open(prev)).get("narration") or []
            except (ValueError, OSError):
                report = []
        narration_note = ("carried forward from the previous build — this run "
                          "passed --skip-narrate and synthesised nothing"
                          if report else
                          "NOT RECORDED — --skip-narrate, and no earlier "
                          "build-report.json to carry forward")
    else:
        report = narrate(spec, vodir)
        narration_note = None

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
    # ⚠ --bursts DEFAULTS TO A RELATIVE "bursts", i.e. whatever directory the
    # builder happened to be standing in — the same defect --work had. A spec
    # may name its own with "bursts"; otherwise look beside the spec file, then
    # in the out-dir, so a stage's `burst` cannot silently resolve to nothing
    # and fall back to a frozen still.
    bursts = spec.get("bursts") or os.path.join(outdir, "bursts")
    run([VENV, f"{PLUGIN}/scripts/assemble.py", "--manifest", manp, "--vo", vodir,
         "--shots", outdir, "--loops", outdir, "--work", os.path.join(outdir, "segments"),
         "--bursts", bursts,
         "--intro", intro, "--outro", outro, "--out", film])

    # ⭐ THE CORNER METER, and it runs HERE -- before the duration read and
    # before verify.py -- so every gate downstream judges the film that actually
    # ships. A post-processing step bolted on AFTER the gates is a step the gates
    # cannot see, which is how this rig shipped an 11-second-short film with all
    # eight of them green.
    #
    # Opt-in per spec (`"meter": true`, or a corner: "br"/"bl"/"tr"/"tl"), because
    # a 40-second Short has no long stretch of static frame to explain and does
    # not need one. Audio is stream-copied, so the loudness gate reads the same
    # numbers it did before this existed.
    if spec.get("meter"):
        m = spec["meter"]
        metered = os.path.join(outdir, f"{spec['id']}-meter.mp4")
        # ⛔ START AFTER THE INTRO. The sting already IS this instrument at full
        # size; a corner copy on top of it is the same face twice. The intro's
        # own length is the number to skip, and it is right here in the spec —
        # `brand.py` was handed exactly this value a few lines above.
        intro_s = float(spec.get("introSeconds", 4))
        # A 9:16 frame has ~44% of the width to spend, so the Shorts build is
        # smaller. Read the size the spec actually asked for rather than
        # guessing from the id.
        W_spec, H_spec = (spec.get("size", "1920x1080").split("x") + ["1080"])[:2]
        portrait = int(H_spec) > int(W_spec)
        run([VENV, os.path.join(os.path.dirname(os.path.abspath(__file__)), "meter.py"),
             film, metered, "--work", os.path.join(outdir, "segments"),
             "--corner", m if isinstance(m, str) else "br",
             "--start", f"{intro_s:.3f}"] + (["--short"] if portrait else []))
        # ⭐ KEEP THE PRE-METER MASTER. The meter is BURNED IN, so once this
        # replace has happened the only way to change the meter's look is to
        # re-assemble the whole film -- burning a second meter over the first
        # draws two. Keeping the clean master makes a restyle a one-command
        # re-burn instead of a rebuild. It costs one extra copy of the film.
        nometer = os.path.join(outdir, f"{spec['id']}-nometer.mp4")
        try:
            os.replace(film, nometer)
        except OSError:
            nometer = None
        os.replace(metered, film)
        if nometer:
            print(f"  master : {nometer}  (pre-meter, for restyling)")

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
    fails, broken = [], []
    for line in v.stdout.splitlines():
        if line.startswith("[") or "FAIL" in line:
            print("  " + line)
        if line.lstrip().startswith("[ FAIL ]"):
            fails.append(line.strip())
        # ⚠⚠ A BROKEN CHECK IS NOT A PASSING CHECK. verify.py tags the one
        # case a film may legitimately ship through -- a Short too small for
        # the cross-stage control -- as "not applicable". Every other BROKEN
        # means the probe could not judge: a dead speech server, a failed
        # import, a control that collapsed. Those used to print and be
        # ignored, so a run silently dropped from "8 ok" to "7 ok + 1 BROKEN"
        # and still reported success. MEASURED: two film builds killed each
        # other's speech server on port 8000 in one night.
        elif line.lstrip().startswith("[BROKEN]") and "not applicable" not in line:
            broken.append(line.strip())
    rep = {"spec": spec["id"], "duration": dur, "narration": report,
           "verifyFails": fails, "verifyBroken": broken}
    if narration_note:
        rep["narrationNote"] = narration_note
    json.dump(rep, open(os.path.join(outdir, "build-report.json"), "w"), indent=2)
    # ⚠ A [ FAIL ] USED TO BE PRINTED AND THEN IGNORED. The Amen lesson failed
    # its true-peak check and was copied to ~/Movies anyway, one line below the
    # word FAIL. A gate nobody obeys is decoration -- shipping now stops here.
    # (verify.py's [BROKEN] is different: it means the probe could not judge,
    # which is the documented state for a Short, and does not block.)
    if fails:
        raise SystemExit("REFUSING TO SHIP — verify.py failed:\n  "
                         + "\n  ".join(fails))
    if broken:
        raise SystemExit("REFUSING TO SHIP — a gate could not judge this film, "
                         "which is not the same as passing:\n  "
                         + "\n  ".join(broken)
                         + "\n  Fix the probe (is the speech server up on $OMLX_BASE?) "
                           "and re-run verify. Do NOT re-run the build to make it go away.")
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
