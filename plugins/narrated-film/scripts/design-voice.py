#!/usr/bin/env python3
"""Design a narrator voice with OmniVoice, then audition the candidates.

THIS IS THE ONLY JOB OMNIVOICE DOES HERE. It can invent a voice from a written
description, which is how the shipped narrator was created. It is NOT used to
speak the film — see the warning below and narrate.py, which clones the chosen
clip with VoxCPM2.

    python3 design-voice.py --out voices/
    # listen to voices/*.mp3, pick one, then:
    cp voices/V6-teacher.wav ../assets/reference-voice.wav
    # and set REF_TEXT (in narrate.py) to the words spoken in AUDITION below

⚠️ DO NOT NARRATE A WHOLE FILM WITH OMNIVOICE. Measured, twice:
  * `voice` is routed to the model's *instruct* channel and this build SPEAKS
    THE DESCRIPTION ALOUD mid-sentence ("gentle, encouraging and clear").
  * Sampling knobs are only applied if SENT. Without them one sentence comes
    back at -14, -24 and -40 dB on consecutive tries, and lines collapse into
    babble that Whisper transcribes as nothing but "Thank you."
Both failures pass every level, pace and spectrum check. Use it to design the
voice once; clone that clip for everything else.
"""
import argparse, json, os, subprocess, urllib.request

BASE = os.environ.get("OMLX_BASE", "http://127.0.0.1:8000")
MODEL = os.environ.get("VOICE_MODEL", "mlx-community--OmniVoice-bf16")
GEN = {"temperature": 0.35, "top_p": 0.85, "top_k": 40, "repetition_penalty": 1.1}

# Keep this text as the reference sentence: it is what REF_TEXT must say, and
# it is long enough to carry a voice's character.
AUDITION = ("This is a test of the narration voice. It should sound calm, "
            "unhurried and clear, like a patient teacher explaining something "
            "for the first time. Listen to a few candidates and keep the one "
            "you would happily hear for ten minutes.")

VARIANTS = {
    "V1-engineer": "A warm, articulate male studio engineer in his thirties. Calm, "
                   "confident and unhurried, explaining his craft to a colleague. "
                   "Clear diction, natural conversational rhythm.",
    "V2-narrator": "A deep, resonant male documentary narrator. Low pitch, measured "
                   "and deliberate, cinematic warmth, unhurried authority.",
    "V3-producer": "An upbeat young male music producer. Bright, quick and energetic, "
                   "genuinely enthusiastic, modern and casual.",
    "V4-presenter": "A crisp, friendly female technology presenter in her early thirties. "
                    "Precise diction, warm and approachable, steady mid pace.",
    "V5-broadcast": "A polished female broadcast journalist. Even, professional and "
                    "articulate, neutral accent, calm authority without warmth or drama.",
    "V6-teacher": "A patient male teacher in his forties. Gentle, encouraging and clear, "
                  "slightly slower than conversational, as if explaining to a beginner.",
}


def synth(text, desc, out, timeout=900):
    body = {"model": MODEL, "input": text, "voice": desc,
            "response_format": "wav", "stream": False, **GEN}
    req = urllib.request.Request(f"{BASE}/v1/audio/speech", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        open(out, "wb").write(r.read())


def measure(path):
    d = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                              "-of", "csv=p=0", path], capture_output=True, text=True).stdout.strip())
    p = subprocess.run(["ffmpeg", "-hide_banner", "-i", path, "-af", "astats=metadata=1",
                        "-f", "null", "-"], capture_output=True, text=True)
    rms = next((float(l.split("RMS level dB", 1)[1].lstrip(":= ").split()[0])
                for l in p.stderr.splitlines() if "RMS level dB" in l), -99.0)
    return d, rms


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="voices")
    ap.add_argument("--only", help="comma-separated variant names")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    json.dump(VARIANTS, open(f"{a.out}/variants.json", "w"), indent=2)

    names = a.only.split(",") if a.only else list(VARIANTS)
    for k in names:
        desc = VARIANTS[k]
        wav = f"{a.out}/{k}.wav"
        synth(AUDITION, desc, wav)
        d, rms = measure(wav)
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", wav,
                        "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "44100",
                        f"{a.out}/{k}.mp3"], check=True)
        print(f"{k:14s} {d:6.2f}s  RMS {rms:7.2f}   {a.out}/{k}.mp3")

    print(f"\nListen to the mp3s, then copy the WAV you want over "
          f"assets/reference-voice.wav.\nKeep REF_TEXT in narrate.py equal to the "
          f"audition sentence, or the clone degrades.")


if __name__ == "__main__":
    main()
