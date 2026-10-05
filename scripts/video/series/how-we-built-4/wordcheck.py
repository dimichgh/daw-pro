#!/usr/bin/env python3
"""Transcribe every stage take and read EVERY content word against the script.

⚠ THIS EXISTS BECAUSE A PASSING SIMILARITY SCORE IS NOT A STATEMENT THAT THE
WORDS ARE RIGHT. Part 2 shipped a stage scoring 1.00 that never said the word
"violations", and one scoring 0.95 that said "lowest" where the script said
"slowest" — a meaning inversion. One missing word in 250 rounds up.
"""
import base64, json, os, re, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.environ["OMLX_BASE"]
STT = "mlx-community--whisper-large-v3-turbo-asr-fp16"
MAN = json.load(open(f"{HERE}/out/manifest.json"))


def transcribe(path, timeout=1800):
    """Multipart, exactly as narrate.py posts it. A JSON body gets a broken
    pipe, which at least fails loudly."""
    import uuid
    b = uuid.uuid4().hex
    parts = []
    for n, v in (("model", STT), ("response_format", "json"), ("language", "en")):
        parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{n}"\r\n\r\n{v}\r\n'.encode())
    parts.append((f'--{b}\r\nContent-Disposition: form-data; name="file"; '
                  'filename="a.wav"\r\nContent-Type: audio/wav\r\n\r\n').encode()
                 + open(path, "rb").read() + b"\r\n")
    parts.append(f"--{b}--\r\n".encode())
    req = urllib.request.Request(f"{BASE}/v1/audio/transcriptions", data=b"".join(parts),
                                 headers={"Content-Type": f"multipart/form-data; boundary={b}"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read()).get("text", "").strip()


def words(t):
    return set(re.findall(r"[a-z']+", t.lower()))


out = {}
for st in MAN["stages"]:
    wav = f"{HERE}/out/vo/{st['id']}.wav"
    got = transcribe(wav)
    have = words(got)
    want = [w for w in re.findall(r"[A-Za-z']+", st["narration"]) if len(w) >= 6]
    missing = sorted({w for w in want if w.lower() not in have})
    out[st["id"]] = {"transcript": got, "missing": missing}
    print(f"\n=== {st['id']}  missing {len(missing)}")
    if missing:
        print("    ", missing)

json.dump(out, open(f"{HERE}/wordcheck.json", "w"), indent=1)
# negative control: a word that is in no script anywhere
ctrl = [k for k, v in out.items() if "banana" in words(v["transcript"])]
print(f"\nnegative control — stages whose transcript contains 'banana': {ctrl} (must be [])")
