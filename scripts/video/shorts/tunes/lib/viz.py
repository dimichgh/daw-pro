#!/usr/bin/env python3
"""Render a vertical falling-note piano roll from the SAME song.json the DAW
project was built from, straight to stdout as rawvideo for ffmpeg.

WHY NOT THE APP ITSELF. `debug.windowFrame` was asked for a 540x960 portrait
window and answered 1208x960; the enforced floor is minWidth 1208, and the
tallest this display allows is 1208x1013 -- 1.19:1, landscape. A 9:16 frame
cannot be the app window, and cropping a column out of a landscape one is the
measured-ugly option this project already rejected. So the roll is rebuilt, in
the app's own idiom (dark glass, key strip, beat grid, neon notes, a bar the
notes cross), at native 1080x1920.

    python3 viz.py song.json --seconds 44.2 | ffmpeg -f rawvideo ...

⚠ TIME IS DERIVED FROM THE TEMPO MAP, not from a single bpm: the accelerando
short is a real tempo map and the grid has to compress with it. `secs()` is a
piecewise-constant integration of the same {startBeat,bpm} segments the wire
took, which is what DAWCore's TempoMap.seconds(fromBeatZeroTo:) does.
"""
import argparse, json, math, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 1080, 1920
FPS = 30
HIT_Y = 1500                 # the bar the notes cross
LOOKAHEAD = 2.35             # seconds of music visible above the bar
SF = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"
BG_TOP = np.array([9, 11, 17], np.float32)
BG_BOT = np.array([16, 20, 31], np.float32)
BLACK_KEYS = {1, 3, 6, 8, 10}


def fnt(p, s):
    return ImageFont.truetype(p, s)


class Timing:
    """Beats <-> seconds under a piecewise-CONSTANT tempo map (each segment
    holds its bpm until the next segment's startBeat)."""

    def __init__(self, segs):
        self.segs = sorted(segs, key=lambda s: s["startBeat"])
        assert self.segs and self.segs[0]["startBeat"] == 0, "segment 0 must be at beat 0"
        self.t0 = [0.0]
        for a, b in zip(self.segs, self.segs[1:]):
            self.t0.append(self.t0[-1] + (b["startBeat"] - a["startBeat"]) * 60.0 / a["bpm"])

    def secs(self, beat):
        i = 0
        for k, s in enumerate(self.segs):
            if s["startBeat"] <= beat:
                i = k
        return self.t0[i] + (beat - self.segs[i]["startBeat"]) * 60.0 / self.segs[i]["bpm"]

    def beat_at(self, t):
        i = 0
        for k, s in enumerate(self.segs):
            if self.t0[k] <= t:
                i = k
        return self.segs[i]["startBeat"] + (t - self.t0[i]) * self.segs[i]["bpm"] / 60.0


def hexrgb(s):
    s = s.lstrip("#")
    return np.array([int(s[i:i + 2], 16) for i in (0, 2, 4)], np.float32)


def text_sprite(text, font, colour, pad=0):
    """An (alpha, rgb) pair for one run of text, rendered once and blitted many
    times. PIL for glyphs, numpy for compositing -- 1,300 frames of PIL text
    drawing is minutes; blitting a cached mask is milliseconds."""
    im = Image.new("L", (8, 8))
    box = ImageDraw.Draw(im).textbbox((0, 0), text, font=font)
    w, h = max(1, box[2] - box[0] + 2 * pad + 2), max(1, box[3] - box[1] + 2 * pad + 2)
    im = Image.new("L", (w, h), 0)
    ImageDraw.Draw(im).text((pad - box[0] + 1, pad - box[1] + 1), text, font=font, fill=255)
    return np.asarray(im, np.float32) / 255.0, np.array(colour, np.float32)


def blit(buf, sprite, x, y, gain=1.0):
    a, rgb = sprite
    h, w = a.shape
    x, y = int(x), int(y)
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0:
        return
    sa = a[y0 - y:y1 - y, x0 - x:x1 - x, None] * gain
    buf[y0:y1, x0:x1] = buf[y0:y1, x0:x1] * (1 - sa) + rgb * sa


def rect(buf, x0, y0, x1, y1, rgb, alpha=1.0):
    x0, x1 = int(max(0, min(W, x0))), int(max(0, min(W, x1)))
    y0, y1 = int(max(0, min(H, y0))), int(max(0, min(H, y1)))
    if x1 <= x0 or y1 <= y0:
        return
    if alpha >= 1.0:
        buf[y0:y1, x0:x1] = rgb
    else:
        buf[y0:y1, x0:x1] += (rgb - buf[y0:y1, x0:x1]) * alpha


def add(buf, x0, y0, x1, y1, rgb, k=1.0):
    """ADDITIVE, for glow: overlapping halos brighten instead of flattening."""
    x0, x1 = int(max(0, min(W, x0))), int(max(0, min(W, x1)))
    y0, y1 = int(max(0, min(H, y0))), int(max(0, min(H, y1)))
    if x1 > x0 and y1 > y0:
        buf[y0:y1, x0:x1] += rgb * k


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("song")
    ap.add_argument("--seconds", type=float, required=True)
    ap.add_argument("--out", default="-")
    ap.add_argument("--probe-frame", type=float, default=None,
                    help="write ONE frame at this second as a PNG to --out and stop")
    a = ap.parse_args()
    song = json.load(open(a.song))
    T = Timing(song["tempoSegments"])

    tracks = [t for t in song["tracks"] if t.get("notes")]
    # ⚠ POINT THE ROLL AT THE NOTES. The pitch window is derived from the
    # material, never assumed -- a bass part under a fixed window photographs an
    # empty grid, which is this project's classic wrong-but-ok capture.
    lo = min(n[1] for t in tracks for n in t["notes"])
    hi = max(n[1] for t in tracks for n in t["notes"])
    lo, hi = lo - 1, hi + 1
    ML, MR = 26, 26
    slot = (W - ML - MR) / (hi - lo + 1)

    def px(pitch):
        return ML + (pitch - lo) * slot

    # ---- static chrome, drawn once -----------------------------------------
    base = np.zeros((H, W, 3), np.float32)
    ramp = np.linspace(0, 1, H, dtype=np.float32)[:, None, None]
    base += BG_TOP * (1 - ramp) + BG_BOT * ramp
    # key strip: the black-key columns run the WHOLE height, faintly, so the
    # frame reads as a pitch grid rather than as a game lane.
    for p in range(lo, hi + 1):
        if p % 12 in BLACK_KEYS:
            rect(base, px(p), 0, px(p) + slot, H, np.array([0, 0, 0], np.float32), 0.35)
        if p % 12 == 0:                                   # every C, a hairline
            rect(base, px(p), 0, px(p) + 1, H, np.array([70, 84, 110], np.float32), 0.55)
    # the bar
    rect(base, 0, HIT_Y - 2, W, HIT_Y + 3, np.array([120, 150, 190], np.float32), 0.9)
    add(base, 0, HIT_Y - 26, W, HIT_Y + 26, np.array([30, 60, 95], np.float32), 0.5)

    # ⚠ A SCRIM UNDER THE TEXT. Without it the title sits on top of whatever
    # note happens to be falling there and the frame at 26 s had "Bowed glass
    # pad" written across a vibraphone note. Measured by looking at it.
    scrim = np.linspace(1.0, 0.0, 420, dtype=np.float32)[:, None, None] ** 1.6
    base[:420] *= (1 - 0.72 * scrim)

    title = song.get("title", "")
    sub = song.get("subtitle", "")
    sp_title = text_sprite(title, fnt(SF, 46), (232, 238, 255))
    # ⚠ FIT THE SUBTITLE. "one note, one instrument · twenty-four of them · D
    # pentatonic · 132" ran off the right edge of the cascade and the last words
    # were simply not in the frame -- a valid PNG with the sentence cut in half.
    ssz = 26
    while ssz > 15 and ImageDraw.Draw(Image.new("L", (8, 8))).textlength(
            sub, font=fnt(MONO, ssz)) > W - 96:
        ssz -= 1
    sp_sub = text_sprite(sub, fnt(MONO, ssz), (128, 142, 168))

    # ---- the legend, in one of three modes ---------------------------------
    # `list`    one row per track            -- the default; up to ~8 parts
    # `groups`  one row per `group` field    -- Five Rooms has 15 parts in 5 rooms
    # `current` one big name, whoever played -- Twelve Colours and the Cascade,
    #           where the point IS which instrument is speaking right now and a
    #           list of 24 would be a wall of text
    mode = song.get("legendMode", "list")
    leg_y0, leg_step = 190, 44
    rows = []
    if mode == "groups":
        seen = []
        for t in tracks:
            g = t.get("group", t["name"])
            if g not in seen:
                seen.append(g)
                rows.append((g, hexrgb(t["color"]), [t["name"]]))
            else:
                rows[seen.index(g)][2].append(t["name"])
    elif mode == "list":
        rows = [(t["name"], hexrgb(t["color"]), [t["name"]]) for t in tracks]
    # ⚠ TWO COLUMNS PAST SEVEN ROWS. The Stack has twelve parts; one column ran
    # to y=674, far below the header scrim, and the bottom six names sat
    # unreadable on top of the falling notes -- found by looking at a frame of
    # the finished film, not by any gate.
    ncol = 2 if len(rows) > 7 else 1
    percol = (len(rows) + ncol - 1) // ncol
    legend = []
    for i, (label, c, members) in enumerate(rows):
        legend.append({
            "x": 84 + 500 * (i // percol),
            "y": leg_y0 + (i % percol) * leg_step, "c": c, "members": set(members),
            "dim": text_sprite(label, fnt(SF, 27), tuple((c * 0.42).tolist())),
            "lit": text_sprite(label, fnt(SF, 27), tuple(np.minimum(255, c * 1.15).tolist())),
        })
    # `current` needs one sprite per track, and a HOLD: at sixteenth notes the
    # name would otherwise change nine times a second and read as a flicker.
    cur_sprites = {t["name"]: text_sprite(t.get("label", t["name"]), fnt(SF, 44),
                                          tuple(np.minimum(255, hexrgb(t["color"]) * 1.2).tolist()))
                   for t in tracks} if mode == "current" else {}
    CUR_HOLD = float(song.get("legendHold", 0.45))


    # ---- note geometry, in SECONDS ------------------------------------------
    notes = []
    for t in tracks:
        c = hexrgb(t["color"])
        # A pad's 8-beat note is longer than the whole lookahead, so it draws as
        # a full-height column and swamps the moving parts. `vizAlpha` lets a
        # bed sit BEHIND the music instead of in front of it.
        va = float(t.get("vizAlpha", 1.0))
        for s, p, l, v in t["notes"]:
            t0 = T.secs(s)
            notes.append((t0, T.secs(s + l) - t0, p, c, v / 127.0, t["name"], va))
    notes.sort(key=lambda n: n[0])
    onsets = np.array([n[0] for n in notes], np.float32)

    bars = song.get("beatsPerBar", 4)
    last_beat = song["lengthBeats"]
    grid = [(T.secs(b), b % bars == 0) for b in range(0, int(last_beat) + 1)]

    # The header band is as tall as the legend it has to cover: five rows of
    # names needs 470 px, one big current-instrument label needs 300.
    # The header band is exactly as tall as what it has to cover.
    HDR = 300 if mode == "current" else leg_y0 + percol * leg_step + 34
    FLAT = HDR - 70
    SCRIM = np.ones((HDR, 1, 1), np.float32)
    SCRIM[:FLAT] = 0.22
    SCRIM[FLAT:] = np.linspace(0.22, 1.0, HDR - FLAT, dtype=np.float32)[:, None, None]

    nframes = int(round(a.seconds * FPS))
    out = sys.stdout.buffer if a.out == "-" else None
    frames = [int(round(a.probe_frame * FPS))] if a.probe_frame is not None else range(nframes)

    ignore = {t["name"] for t in tracks if t.get("legendIgnore")}
    cur_name, cur_since = None, -9.0
    for f in frames:
        t = f / FPS
        if mode == "current":
            # the LAST onset at or before now, recomputed from scratch so a
            # single-frame probe is identical to the same frame in a full run
            # ⚠ SKIP THE BACKING PARTS. In `current` mode the label names
            # whoever played last, and on Twelve Colours the hi-hat plays last
            # roughly always -- the frame at 31 s read "Kit" while a vibraphone
            # was playing the line the whole short exists to show. A track with
            # `legendIgnore` can never be named.
            back = [n for n in notes if n[0] <= t + 1e-6 and n[5] not in ignore]
            if back:
                cand = back[-1][5]
                if cand != cur_name and t - cur_since >= CUR_HOLD:
                    cur_name, cur_since = cand, t
                elif cur_name is None:
                    cur_name, cur_since = cand, t
        buf = base.copy()
        # beat grid, moving: this is what makes a tempo change VISIBLE
        for gt, isbar in grid:
            y = HIT_Y - (gt - t) / LOOKAHEAD * HIT_Y
            if -4 <= y <= H:
                rect(buf, 0, y, W, y + (2 if isbar else 1),
                     np.array([126, 150, 190] if isbar else [52, 62, 80], np.float32),
                     0.75 if isbar else 0.4)
        # notes
        i0 = np.searchsorted(onsets, t - LOOKAHEAD * (H - HIT_Y) / HIT_Y - 4.0)
        i1 = np.searchsorted(onsets, t + LOOKAHEAD + 0.5)
        active = set()
        for t0, dur, p, c, vel, nm, va in notes[i0:i1]:
            yb = HIT_Y - (t0 - t) / LOOKAHEAD * HIT_Y
            yt = yb - max(dur, 0.05) / LOOKAHEAD * HIT_Y
            if yt > H or yb < -8:
                continue
            x0, x1 = px(p) + slot * 0.10, px(p) + slot * 0.90
            if x1 - x0 < 5:
                x0, x1 = px(p) + slot * 0.5 - 2.5, px(p) + slot * 0.5 + 2.5
            playing = t0 <= t < t0 + dur
            if playing:
                active.add(nm)
            # past the bar the note dims out -- it has been heard
            faded = min(1.0, max(0.0, (yt - HIT_Y) / 380.0))
            k = va * (1.0 - faded) * (0.45 + 0.55 * vel)
            if k <= 0.01:
                continue
            add(buf, x0 - 7, yt - 5, x1 + 7, yb + 5, c * 0.30, k)      # halo
            rect(buf, x0, yt, x1, yb, np.minimum(255.0, c * (1.35 if playing else 0.95)),
                 min(1.0, k * (1.0 if playing else 0.92)))
            if playing:                                                # struck
                add(buf, x0 - 16, HIT_Y - 20, x1 + 16, HIT_Y + 20, c, 0.55)
                add(buf, x0 - 40, HIT_Y - 6, x1 + 40, HIT_Y + 6, c, 0.25)
        # ⚠ THE HEADER IS DRAWN PER FRAME, LAST. Baked into the static layer it
        # sat UNDER the falling notes, and a bar line drew straight through
        # "Bowed glass pad" -- visible only by looking at a frame of the
        # FINISHED file, which is where this was found.
        # ⚠ THE SCRIM MUST OUTLAST THE TEXT. The first version faded to nothing
        # at y=400 and the LAST legend row sits at 366-400, so a beat line ran
        # straight through "Bowed glass pad" at ~3% scrim. Hold it flat over the
        # whole header block, then fade.
        buf[:HDR] *= SCRIM
        blit(buf, sp_title, 46, 62)
        blit(buf, sp_sub, 48, 124)
        for L in legend:
            on = bool(L["members"] & active)
            blit(buf, L["lit"] if on else L["dim"], L["x"], L["y"])
            add(buf, L["x"] - 38, L["y"] + 6, L["x"] - 18, L["y"] + 26, L["c"],
                0.9 if on else 0.20)
        if mode == "current" and cur_name:
            blit(buf, cur_sprites[cur_name], 48, 186)
        # a hairline progress bar along the very top edge: on a muted scroller
        # it is the only thing that says how much is left.
        rect(buf, 0, 0, W * min(1.0, t / a.seconds), 5,
             np.array([120, 200, 255], np.float32), 0.85)
        frame = np.clip(buf, 0, 255).astype(np.uint8)
        if a.probe_frame is not None:
            Image.fromarray(frame).save(a.out)
            print(f"probe frame {f} at {t:.2f}s -> {a.out}", file=sys.stderr)
            return
        out.write(frame.tobytes())
    print(f"viz: {nframes} frames, {len(notes)} notes, pitch {lo}-{hi}, "
          f"slot {slot:.1f}px", file=sys.stderr)


if __name__ == "__main__":
    main()
