#!/usr/bin/env python3
"""Where in a stage's narration is a phrase actually SPOKEN?

⚠ THE STILL TIMER IS NOT "EVENLY SPREAD" and guessing at it has put a drum grid
under the words "this is the lead melody" before now. It is
n = round(total/cut); each = total/n, with holdLast CLAMPING the list. The only
honest way to check a card is on screen when its number is read is to find the
instant the number is read. This transcribes 8-second windows until the phrase
appears.

    python3 locate.py 07-meter "thirty-six"
"""
import json, os, re, subprocess, sys, tempfile, urllib.request, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.environ["OMLX_BASE"]
STT = "mlx-community--whisper-large-v3-turbo-asr-fp16"


def transcribe(path):
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
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.loads(r.read()).get("text", "").strip()


def dur(p):
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                                 "format=duration", "-of", "default=nw=1:nk=1", p],
                                capture_output=True, text=True).stdout.strip())


def find(stage, phrase, win=8.0, hop=4.0):
    wav = f"{HERE}/out/vo/{stage}.wav"
    n = dur(wav)
    t = 0.0
    hits = []
    tmp = tempfile.mktemp(suffix=".wav")
    while t < n:
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                        "-ss", str(t), "-t", str(win), "-i", wav, tmp], check=True)
        got = transcribe(tmp).lower()
        if phrase.lower() in got:
            hits.append((round(t, 1), round(min(t + win, n), 1), got))
        t += hop
    return hits, n


if __name__ == "__main__":
    stage, phrase = sys.argv[1], sys.argv[2]
    hits, n = find(stage, phrase)
    print(f"{stage} ({n:.1f}s): {phrase!r}")
    for a, b, g in hits:
        print(f"  {a:6.1f}-{b:6.1f}  …{g[:150]}")
    if not hits:
        print("  NOT FOUND in any window")
