#!/usr/bin/env python3
"""Burn a small live spectrum meter into a corner of a finished film.

    python3 meter.py in.mp4 out.mp4 [--work DIR] [--corner br|bl|tr|tl]

WHY: a narrated film is mostly static frames, and a viewer has no way to tell
"this is playing" from "this is paused" except by listening. The intro already
solves that -- `brand.py`'s bars are driven by the real per-frame loudness of
the sting -- so the film gets the same instrument, shrunk into a corner, driven
by the FILM'S OWN audio track. It moves under the narration and it moves under
every demo.

⚠ IT IS A REAL ANALYSIS, NOT A DECORATION. The bars are a log-spaced band split
of the actual audio, so the 49 Hz heartbeat lights the left of the meter and
nothing else, and a saw wave lights the whole of it. A meter that merely
wiggled would be a lie about the one thing this film is for.

Palette and shape follow `brand.py` deliberately: same cyan, same violet on
every fourth bar, same glow-then-sharp compositing, same baseline the bars
stand on.
"""
import argparse, math, os, subprocess, sys, tempfile

CYAN = (90, 209, 255)
VIOLET = (167, 139, 250)
BASE = (26, 42, 58)
WARM = (125, 249, 214)       # the top end, so the ramp ends somewhere distinct


def bar_colour(k, n):
    """Colour by FREQUENCY, violet -> cyan -> warm, low to high.

    The old rule painted every fourth bar violet, which is a rhythm, not
    information: at 48 bars it would have read as stripes. A ramp means the
    colour of the lit region TELLS YOU WHERE THE ENERGY IS -- the 49 Hz
    heartbeat lights the violet end and nothing else, and a saw wave lights the
    whole ramp. Same palette as the intro sting, spent on meaning instead of
    decoration.
    """
    t = k / max(1, n - 1)
    a, b, u = (VIOLET, CYAN, t / 0.5) if t < 0.5 else (CYAN, WARM, (t - 0.5) / 0.5)
    return tuple(int(a[i] + (b[i] - a[i]) * u) for i in range(3))

# ⭐ THIS IS THE NARRATOR'S FACE. The user named it that, and it changes what
# the thing is for: it is not a readout in a corner, it is the only moving
# evidence that anybody is home while a still frame sits on screen. So it is
# MANY THIN LINES rather than a few fat blocks -- a dense display reads as
# "voice" and "sound" the way a chunky one reads as "widget" -- and it is HALF
# the height it used to be, because a face does not need to be a billboard.
# ⚠ SIZE AND DENSITY ARE THE USER'S CALL, TWICE OVER. First "make bar lines thin
# and more, scale it 50% smaller by height"; then "very narrow lines, one per
# frequency, compress the whole thing and make it a little bit smaller".
# 404x122 -> 404x61 -> 340x48, and 16 -> 48 -> 72 bands.
W_M, H_M = 340, 48           # the meter's own canvas
N_BARS = 72                  # one thin line per frequency, density over bulk
BAR_FILL = 0.34              # fraction of each slot the line occupies:
                             # ~1.5 px lines at full size, which is the "thin
                             # lines" the user asked for rather than bars
F_LO, F_HI = 30.0, 12000.0   # log-spaced band edges; F_LO must reach the 808
MARGIN = 36

# ⚠ SHORTS GET A SMALLER ONE. A 9:16 frame has ~44% of the width to spend, so
# the same panel eclipses content that a landscape frame has room for.
SHORT_SCALE = 0.62

# Peak-hold caps: a thin line that jumps to each new peak and falls slowly.
# It costs almost nothing and it is what makes a spectrum display read as ALIVE
# rather than as a bar chart being redrawn -- the bars show now, the caps show
# a moment ago, and the eye reads the gap between them as motion.
CAP_FALL = 1.9               # units per second, on the 0..1 level scale.
# ⚠ CAP_FALL WAS TUNED BY LOOKING, NOT BY TASTE. At 0.9/s the caps hung so
# far above their own lines during a quiet passage that they read as a
# separate, broken layer rather than as the peak of the line beneath them.
CAP_H = 2                    # cap thickness in px


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"FAILED: {' '.join(cmd[:8])}\n{p.stderr[-1500:]}")
    return p.stdout


def duration(path):
    return float(run(["ffprobe", "-v", "error", "-show_entries",
                      "format=duration", "-of", "csv=p=0", path]).strip())


def video_frames(path):
    """How many frames the film's VIDEO stream has.

    The meter is generated from the AUDIO, and in a film assembled from segments
    the audio runs slightly LONGER than the video -- 0.89 s on the first one this
    ran against. Overlaying more meter frames than there are video frames
    EXTENDS the video by the difference and the a/v drift gate fails at 872 ms.
    So the meter is cut to the video's own length.
    """
    out = run(["ffprobe", "-v", "error", "-select_streams", "v:0",
               "-count_packets", "-show_entries", "stream=nb_read_packets",
               "-of", "csv=p=0", path]).strip()
    return int(out) if out.isdigit() else 0


def bands(path, fps):
    """Per-frame, per-band level of the film's own audio.

    Returns a list of frames, each a list of N_BARS values in 0..1. Levels are
    normalised against the WHOLE FILM's loudest band-frame, so a quiet chapter
    reads as quiet -- normalising per frame would make silence look like a
    drum solo, which is the classic version of this bug.
    """
    import numpy as np
    # STEREO, NOT `-ac 1`. A mono downmix ADDS the channels, so anything
    # anti-phase cancels and the meter would draw silence over audio that is
    # playing. Each channel is analysed on its own and each band takes the LOUDER
    # of the two, which no phase relationship can talk out of a reading.
    #
    # ⚠ HOW MUCH THIS ACTUALLY BUYS, MEASURED rather than assumed: on this film
    # the two agree within ~8 dB at the widest point sampled, so it is insurance,
    # not a fix for a defect that was there. The apparent defect that sent me
    # looking -- "the meter is flat while astats says -16 dB" -- was neither:
    # `ffmpeg -ss` before `-i` is a FAST seek and does not land on the second you
    # asked for, so the two instruments were reading different moments. The audio
    # at that instant really is a -37 dB gap between words, and a flat meter is
    # the honest picture of it. ⭐ WHEN TWO INSTRUMENTS DISAGREE, CHECK THEY ARE
    # POINTED AT THE SAME SAMPLE BEFORE BELIEVING EITHER.
    wav = os.path.join(tempfile.mkdtemp(), "a.wav")
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", path,
         "-vn", "-ac", "2", "-ar", "48000", "-c:a", "pcm_s16le", wav])
    import wave
    w = wave.open(wav)
    sr = w.getframerate()
    raw = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)
    raw /= 32768.0
    chans = [raw[0::2], raw[1::2]] if w.getnchannels() == 2 else [raw]
    hop = sr / fps
    n = int(len(chans[0]) / hop)
    win = int(hop * 2)                      # overlap, so bars do not flicker
    edges = np.geomspace(F_LO, F_HI, N_BARS + 1)
    frames = []
    window = np.hanning(win)
    fr = np.fft.rfftfreq(win, 1 / sr)
    masks = [(fr >= edges[k]) & (fr < edges[k + 1]) for k in range(N_BARS)]
    # ⚠⚠ A BAND NARROWER THAN ONE FFT BIN CAN CONTAIN NO BIN AT ALL, and the old
    # code drew those as a permanent 0.0 -- DEAD BARS that look like a design
    # choice. MEASURED: at 15 Hz bins, 11 of the previous 48 bands were narrower
    # than one bin, and 22 of the current 72 are. Log spacing guarantees this at
    # the low end no matter how many bands there are, so it is not fixed by
    # choosing a nicer number. Every empty band falls back to the bin NEAREST its
    # geometric centre, so every line on screen is reading real audio.
    centres = np.sqrt(edges[:-1] * edges[1:])
    nearest = [int(np.argmin(np.abs(fr - c))) for c in centres]
    empties = sum(1 for m in masks if not m.any())
    for i in range(n):
        a = int(i * hop)
        best = None
        for x in chans:
            seg = x[a:a + win]
            if len(seg) < win:
                seg = np.pad(seg, (0, win - len(seg)))
            sp = np.abs(np.fft.rfft(seg * window))
            row = np.array([float(sp[m].mean()) if m.any() else float(sp[nearest[k]])
                            for k, m in enumerate(masks)])
            best = row if best is None else np.maximum(best, row)
        frames.append(best)
    arr = np.array(frames)
    db = 20 * np.log10(arr + 1e-9)

    # ⚠ ONE GLOBAL SCALE KILLS THE TOP HALF OF THE METER. MEASURED on a real
    # frame of narration: bands under 600 Hz sat at -3..+35 dB and everything
    # above at -17..-65, because a magnitude spectrum falls steeply with
    # frequency. Scaled together, every bar above 600 Hz pinned to zero for the
    # whole film -- eight dead bars that looked like a design choice.
    #
    # So each band is scaled against ITS OWN loud end, the way a real analyser
    # is tilted...
    ref = np.percentile(db, 98.0, axis=0)
    shape = np.clip((db - (ref - 42.0)) / 42.0, 0.0, 1.0) ** 0.7

    # ...and then the whole meter is gated by how loud the frame ACTUALLY is,
    # so silence is still silence. Without this, per-band scaling turns a quiet
    # passage into a full-height display of its own noise floor -- the classic
    # version of this bug, and a lie in a film about measurement.
    frame_db = 20 * np.log10(arr.sum(axis=1) + 1e-9)
    gate = np.clip((frame_db - (np.percentile(frame_db, 98.0) - 40.0)) / 40.0, 0.0, 1.0)
    out = shape * gate[:, None]
    return out.tolist()


def draw(levels, outdir, fps=30.0, scale=1.0):
    """One small RGBA PNG per frame: glow pass, then the same lines sharp."""
    from PIL import Image, ImageDraw, ImageFilter, ImageChops
    os.makedirs(outdir, exist_ok=True)
    W = max(1, int(round(W_M * scale)))
    H = max(1, int(round(H_M * scale)))
    pad = max(6, int(round(12 * scale)))
    span = W - pad * 2
    slot = span / N_BARS
    line_w = max(1.0, slot * BAR_FILL)
    base_y = H - max(6, int(round(10 * scale)))
    top_room = base_y - max(5, int(round(8 * scale)))
    cols = [bar_colour(k, N_BARS) for k in range(N_BARS)]
    caps = [0.0] * N_BARS
    fall = CAP_FALL / max(1e-6, fps)
    cap_h = max(1, int(round(CAP_H * scale)))
    for i, row in enumerate(levels):
        glow = Image.new("RGB", (W, H), (0, 0, 0))
        gd = ImageDraw.Draw(glow)
        sharp = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(sharp)
        # ⚠ A PANEL, NOT BARE LINES. Every corner of an app screenshot already
        # has controls in it; without a ground of its own the meter reads as
        # part of the DAW's chrome rather than as an overlay on top of it.
        d.rounded_rectangle([0, 0, W - 1, H - 1], radius=max(5, int(9 * scale)),
                            fill=(10, 14, 20, 196), outline=BASE + (220,),
                            width=max(1, int(round(1.5 * scale))))
        for k, v in enumerate(row):
            caps[k] = v if v >= caps[k] else max(v, caps[k] - fall)
            x = pad + k * slot + (slot - line_w) / 2.0
            h = max(1.0, v * top_room)
            col = cols[k]
            box = [x, base_y - h, x + line_w, base_y]
            gd.rectangle(box, fill=col)
            d.rectangle(box, fill=col + (255,))
            # the peak-hold cap, floating above the line it came from
            cy = base_y - max(1.0, caps[k] * top_room)
            if caps[k] > v + 0.02:
                cap = [x, cy - cap_h, x + line_w, cy]
                gd.rectangle(cap, fill=col)
                d.rectangle(cap, fill=col + (215,))
        gd.line([(pad - 2, base_y + 2), (W - pad + 2, base_y + 2)], fill=CYAN, width=2)
        d.line([(pad - 2, base_y + 2), (W - pad + 2, base_y + 2)], fill=BASE + (200,))
        glow = glow.filter(ImageFilter.GaussianBlur(max(2, int(round(5 * scale)))))
        img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        img = Image.alpha_composite(img, glow.convert("RGBA"))
        # the glow's own black background must not become a black box
        r, g, b, _ = img.split()
        img.putalpha(ImageChops.lighter(ImageChops.lighter(r, g), b).point(
            lambda v: min(255, int(v * 1.6))))
        img = Image.alpha_composite(img, sharp)
        img.save(os.path.join(outdir, f"m{i:06d}.png"))
    return len(levels)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--work", default=None)
    ap.add_argument("--corner", default="br", choices=["br", "bl", "tr", "tl"])
    ap.add_argument("--fps", type=float, default=30.0)
    # ⛔ NOT OVER THE INTRO. The intro sting ALREADY carries this instrument at
    # full size -- burning the corner copy on top of it is the same face twice,
    # which reads as a mistake rather than as a motif. The user asked for it
    # explicitly and it is a one-line `enable=` on the overlay.
    ap.add_argument("--start", type=float, default=0.0,
                    help="seconds before which the meter is not drawn (skip the intro)")
    ap.add_argument("--end", type=float, default=0.0,
                    help="seconds after which the meter is not drawn (0 = to the end)")
    ap.add_argument("--short", action="store_true",
                    help="the smaller build for a 9:16 frame")
    a = ap.parse_args()

    work = a.work or tempfile.mkdtemp()
    frames = os.path.join(work, "meter")
    lv = bands(a.src, a.fps)
    nv = video_frames(a.src)
    if nv and len(lv) > nv:
        lv = lv[:nv]
    elif nv and len(lv) < nv:
        # Shorter than the video: hold the last reading rather than let the
        # overlay end early. ⚠️ THE REASON CHANGED WHEN THE ENCODE DID, and the
        # old one is left here as a warning: this used to guard against
        # `shortest=1` TRUNCATING the film, and that flag is gone. Under the
        # current `shortest=0` + `-t <audio duration>` the film can no longer be
        # cut short, so what this branch now prevents is milder — the meter
        # simply VANISHING for the last few frames, which reads as a bug in the
        # meter rather than as the end of the film.
        lv = lv + [lv[-1]] * (nv - len(lv))
    scale = SHORT_SCALE if a.short else 1.0
    n = draw(lv, frames, fps=a.fps, scale=scale)
    print(f"  meter  : {n} frames, {N_BARS} bands {F_LO:.0f}-{F_HI:.0f} Hz"
          f"{' (short build)' if a.short else ''}"
          f"{f', from {a.start:.1f}s' if a.start else ''}", flush=True)

    pos = {"br": f"W-w-{MARGIN}:H-h-{MARGIN}", "bl": f"{MARGIN}:H-h-{MARGIN}",
           "tr": f"W-w-{MARGIN}:{MARGIN}", "tl": f"{MARGIN}:{MARGIN}"}[a.corner]
    # ⚠ THE OUTPUT IS PINNED TO THE AUDIO'S OWN DURATION, and that is the whole
    # a/v-drift story in one line. This step RE-ENCODES the video at a constant
    # -r fps, but its input is a concat of segments whose last frames are HELD --
    # so the container reports a longer duration than frames/fps, and a constant-
    # rate re-encode silently throws that difference away. MEASURED on the
    # compressor lesson: the concat probed 338.520 s of video against 10129
    # packets (337.63 s of frames), the re-encode came out at 337.667 s, the
    # audio stayed 338.541 s, and verify.py refused the film at 874.7 ms of
    # drift. An earlier `shortest=1` guard here fixed the OPPOSITE case (a meter
    # outrunning the video) and could not see this one.
    #
    # So: pad the video by cloning its last frame, let the overlay hold its own
    # last frame with shortest=0, and cut the result to the AUDIO length. The
    # film then ends exactly where its sound does, whichever stream was longer.
    # The window the meter is allowed to draw in. `enable` gates the OVERLAY,
    # not the frame generation, so frame N still lines up with second N/fps and
    # the alignment argument above is untouched.
    if a.start or a.end:
        hi = f",{a.end}" if a.end else ",1e9"
        gate = f":enable='between(t,{a.start}{hi})'"
    else:
        gate = ""
    adur = run(["ffprobe", "-v", "error", "-select_streams", "a:0",
                "-show_entries", "stream=duration", "-of",
                "default=nw=1:nk=1", a.src]).strip()
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-i", a.src, "-framerate", f"{a.fps}", "-i", os.path.join(frames, "m%06d.png"),
         "-filter_complex",
         f"[0:v]tpad=stop_mode=clone:stop_duration=3[vp];"
         f"[vp][1:v]overlay={pos}:shortest=0{gate}[v]",
         *(["-t", adur] if adur else []),
         "-map", "[v]", "-map", "0:a", "-c:v", "libx264", "-preset", "medium",
         "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "copy", a.dst])
    print(f"  meter  : burned into {a.dst}", flush=True)


if __name__ == "__main__":
    main()
