#!/usr/bin/env python3
"""Generate narration audio from a manifest, with a CONTENT gate.

THE POINT OF THIS FILE. A level/pace/spectrum gate passes audio that says the
WRONG WORDS, and local TTS says the wrong words often: it collapses into babble,
it speaks the voice DESCRIPTION out loud mid-sentence, it reads the cloning
reference text before the line, it truncates. All of those measure fine. One
delivered film had three of five sampled lines transcribe as nothing but
"Thank you." and every meter said it was healthy.

So every take is transcribed back with Whisper and compared to the script.

    OMLX_BASE=http://127.0.0.1:8000 \
    MANIFEST=manifest.json OUT_DIR=vo LANG_CODE=en \
    python3 narrate.py

Needs an OpenAI-compatible local speech server exposing /v1/audio/speech and
/v1/audio/transcriptions. See SKILL.md for the one this was built against.
"""
import base64, difflib, json, os, re, subprocess, sys, urllib.request, uuid

BASE = os.environ.get("OMLX_BASE", "http://127.0.0.1:8000")
HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.environ.get("TTS_MODEL", "mlx-community--VoxCPM2-bf16")
STT = os.environ.get("STT_MODEL", "mlx-community--whisper-large-v3-turbo-asr-fp16")
LANG = os.environ.get("LANG_CODE", "en")
OUTDIR = os.environ.get("OUT_DIR", "vo")
MANIFEST = os.environ.get("MANIFEST", "manifest.json")
ATTEMPTS = int(os.environ.get("ATTEMPTS", "4"))

# The voice is CLONED from a reference clip, so all lines match. Ship the clip
# and the exact words spoken in it; a wrong ref_text degrades the clone badly.
#
# ⚠ REF_TEXT NAMES A PRODUCT, AND THAT IS CORRECT. It is the literal transcript
# of assets/reference-voice.wav -- the words that clip actually speaks. It is
# not a template and not an example. "Generalising" this string while leaving
# the audio alone silently degrades every line the model speaks, in a way that
# still passes the content gate. If you replace the voice, replace BOTH.
REF_WAV = os.environ.get("REF_WAV", f"{HERE}/../assets/reference-voice.wav")
REF_TEXT = os.environ.get("REF_TEXT", (
    "Every user facing action in DAW Pro is exposed twice. Once as a command "
    "over a WebSocket, and again as a tool on an MCP server. So an AI can drive "
    "this workstation directly, note by note and knob by knob."))

# ⚠ Sampling knobs are only applied if SENT. Omitting them samples the model
# unconstrained, which is what makes one sentence come back at -14, -24 and
# -40 dB on three consecutive tries.
GEN = {"temperature": 0.35, "top_p": 0.85, "top_k": 40, "repetition_penalty": 1.1}

LEAK_PHRASES = [p.strip().lower() for p in os.environ.get("LEAK_PHRASES", "").split("|") if p.strip()]
LEAK_PHRASES += ["every user facing action", "note by note and knob by knob"]
GIBBERISH = re.compile(r"^(thank you\.?\s*)+$|^(you\.?\s*)+$|^\s*$", re.I)

RMS_MIN, RMS_MAX = -30.0, -8.0
SPW_MIN, SPW_MAX = 0.19, 0.85     # seconds per word
WORD_RATIO_MIN = 0.72
SIM_MIN = float(os.environ.get("SIM_MIN", "0.60"))
GOOD_ENOUGH = 0.95                # stop retrying once a take scores under this

_PUNCT = re.compile(r"[^\w\s]", re.U)
_ref = None


def similarity(a, b):
    """Word-level ratio with autojunk OFF.

    ⚠⚠ difflib.SequenceMatcher's `autojunk` heuristic fires on any sequence
    longer than 200 elements and discards every element occurring in more than
    1% of it. Narration lines are 600-1000 CHARACTERS, so character-level
    matching throws away the spaces and the common letters and scores a
    VERBATIM take at 0.17. The same take scores 0.91 as word lists with the
    heuristic off. Never call SequenceMatcher on long prose without this.
    """
    wa = _PUNCT.sub(" ", a.lower()).split()
    wb = _PUNCT.sub(" ", b.lower()).split()
    return difflib.SequenceMatcher(None, wa, wb, autojunk=False).ratio()


def _refb64():
    global _ref
    if _ref is None:
        _ref = base64.b64encode(open(REF_WAV, "rb").read()).decode()
    return _ref


def synth(text, out, timeout=1200):
    body = {"model": MODEL, "input": text, "ref_audio": _refb64(), "ref_text": REF_TEXT,
            "response_format": "wav", "stream": False, **GEN}
    if LANG != "en":
        body["language"] = LANG
    req = urllib.request.Request(f"{BASE}/v1/audio/speech", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        open(out, "wb").write(r.read())


def transcribe(path, timeout=900):
    b = uuid.uuid4().hex
    parts = []
    for n, v in (("model", STT), ("response_format", "json"), ("language", LANG)):
        parts.append(f"--{b}\r\nContent-Disposition: form-data; name=\"{n}\"\r\n\r\n{v}\r\n".encode())
    parts.append((f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; "
                  "filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n").encode()
                 + open(path, "rb").read() + b"\r\n")
    parts.append(f"--{b}--\r\n".encode())
    req = urllib.request.Request(f"{BASE}/v1/audio/transcriptions", data=b"".join(parts),
                                 headers={"Content-Type": f"multipart/form-data; boundary={b}"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read()).get("text", "").strip()


def _ff(path, filt, key):
    # ⚠ never `-v error` here: astats/ebur128 summaries log at INFO and the
    # numbers vanish, leaving an empty parse that looks like silence.
    p = subprocess.run(["ffmpeg", "-hide_banner", "-i", path, "-af", filt, "-f", "null", "-"],
                       capture_output=True, text=True)
    out = []
    for l in p.stderr.splitlines():
        if key in l:
            try:
                out.append(float(l.split(key, 1)[1].lstrip(":= ").split()[0]))
            except (ValueError, IndexError):
                pass
    return out


def measure(path):
    d = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                              "-of", "csv=p=0", path], capture_output=True, text=True).stdout.strip())
    r = _ff(path, "astats=metadata=1", "RMS level dB")
    return d, (r[0] if r else -99.0)


def evaluate(src, path):
    """(score, note). An infinite score means REJECTED."""
    d, rms = measure(path)
    words = max(1, len(src.split()))
    spw = d / words
    if not (RMS_MIN <= rms <= RMS_MAX):
        return float("inf"), f"level {rms:.1f}"
    if not (SPW_MIN <= spw <= SPW_MAX):
        return float("inf"), f"pace {spw:.2f}s/word"
    txt = transcribe(path)
    low, src_low = txt.lower(), src.lower()
    if GIBBERISH.match(txt):
        return float("inf"), "gibberish"
    hit = next((p for p in LEAK_PHRASES if p in low and p not in src_low), None)
    if hit:                                  # exempt if the SCRIPT really says it
        return float("inf"), f"leak '{hit[:28]}'"
    ratio = len(txt.split()) / words
    if ratio < WORD_RATIO_MIN:
        return float("inf"), f"truncated {ratio:.2f}"
    sim = similarity(src, txt)
    if sim < SIM_MIN:
        return float("inf"), f"content mismatch sim {sim:.2f}"
    return (abs(rms + 17.0) / 6.0 + abs(spw - 0.31) / 0.25 + (1.0 - min(sim, 1.0)),
            f"sim {sim:.2f} words {ratio:.2f} {rms:.1f}dB")


def say(src, out):
    best, note, have, tmp = float("inf"), "", False, out + ".try.wav"
    for i in range(ATTEMPTS):
        synth(src, tmp)
        s, n = evaluate(src, tmp)
        # Keep the first take unconditionally: `inf < inf` is False, so without
        # this a fully-rejected stage writes NO FILE AT ALL and the assembler
        # silently drops the line.
        if s < best or not have:
            best, note, have = min(s, best), f"try {i+1} {n}", True
            os.replace(tmp, out)
        elif os.path.exists(tmp):
            os.remove(tmp)
        if best < GOOD_ENOUGH:
            break
    ok = best != float("inf")
    print(f"    {'OK    ' if ok else 'REJECT'} {note}", flush=True)
    return ok


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    man = json.load(open(MANIFEST))
    print(f"model={MODEL} lang={LANG} out={OUTDIR} sim>={SIM_MIN}\n", flush=True)
    fails = []
    for st in man["stages"]:
        if not st.get("narration"):
            continue
        out = f"{OUTDIR}/{st['id']}.wav"
        if os.path.exists(out) and os.path.getsize(out) > 20000:
            print(f"{st['id']} (kept)", flush=True)
            continue
        print(st["id"], flush=True)
        if not say(st["narration"], out):
            fails.append(st["id"])
    print("\nREJECTED:", fails if fails else "none", flush=True)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
