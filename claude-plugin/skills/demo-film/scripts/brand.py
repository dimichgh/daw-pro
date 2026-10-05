#!/usr/bin/env python3
"""Brand furniture: a reusable 5-second opening title and a closing card.

Both are rendered frame by frame with Pillow rather than ffmpeg's drawtext,
because this ffmpeg has no libfreetype and drawtext is simply absent — a fact
that costs an hour if you discover it by watching text silently not appear.

Palette and type come from docs/DESIGN-LANGUAGE.md: near-black glass, cyan for
playback/active, violet for anything AI-touched. SF Pro for words, SF Mono for
numbers and small caps.

⚠ The output MUST be stream-compatible with assemble.py's concat, which joins
with `-c copy`. Mismatched fps, pixel format or SAR does not error — it glitches
on playback. Both cards go through the same VF chain and the same encoder flags.

    python3 brand.py intro --audio sting.wav --out intro.mp4
    python3 brand.py outro --holder "Your Name" --out outro.mp4
    python3 brand.py outro --no-disclaimer --out outro.mp4   # nothing narrated
"""
import argparse, math, os, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H, FPS = 1920, 1080, 30

# ---------------------------------------------------------------- geometry
# Shorts are portrait, and every offset below was hand-placed for 1920x1080.
# So the landscape numbers are kept as the 16:9 branch rather than re-derived
# from ratios. The portrait branch is its own composition, not a squeezed copy.
#
# ⚠ THE BYTE-IDENTICAL PIN ON THE FIVE SHIPPED CARDS IS GONE, DELIBERATELY.
# The outro group (O_*) is now multiplied by OUTRO_TYPE below, so a re-render
# of those cards will NOT match the old bytes. Nothing here is a regression to
# chase: it is the legibility fix, and this comment is the record of it. The
# intro group is untouched and its numbers are still verbatim.
LAYOUT = {}

# ---- OUTRO TYPE SCALE (measured, 2026-09-21) --------------------------------
# These films are watched small. At a 400 px playback width a 1920-wide frame
# is shown at 0.208x, and the outro card's own type measured, as CAP HEIGHTS at
# that size: wordmark 13.5 px, sub-label 4.17 px, © line 6.25 px, "All rights
# reserved." 4.17 px, line2 3.96 px, disclaimer 3.75 px. Everything under the
# wordmark was at or below ~4 px — the same order as the app-panel text the
# reviewer could not read.
#
# Sizes and offsets scale TOGETHER, which is what keeps this a type scale
# rather than a re-layout — the same card, drawn larger. Palette untouched.
#
# ⚠ 1.6, NOT THE 1.8 THAT MAXIMISES LEGIBILITY — AND THE REASON IS HIERARCHY.
# At 1.8 the outro wordmark reaches 166 pt against the INTRO wordmark's 150,
# so the closing card would out-shout the opening one. An end card is the last
# thing on screen, not the loudest: the title card opens the film and should
# stay the dominant mark. 1.6 gives 147 pt, just under the intro, and still
# carries the sub-label from an illegible 4.17 px cap height to ~6.7 px at a
# 400 px playback width. The trade is the disclaimer landing near 5.6 px —
# acceptable, because it is fine print AND because it is now omitted entirely
# from anything without narration (--no-disclaimer).
OUTRO_TYPE = 1.6


def set_size(w, h):
    """Set the card size and rebuild the layout and the ffmpeg scale chain."""
    global W, H, LAYOUT
    W, H = int(w), int(h)
    portrait = H > W
    if not portrait:
        # `o()` is the outro type scale. It multiplies the O_* sizes AND the
        # O_*_DY offsets, so the card grows as one composition instead of
        # colliding with itself. TRACK values scale too, or the letterspacing
        # reads tighter at the larger size than it did at the smaller one.
        o = lambda v: int(round(v * OUTRO_TYPE))
        LAYOUT = dict(
            TEXT_Y=240, F_WORD=150, TRACK_WORD=14, RULE_HALF=330, RULE_DY=190,
            SUB_DY=218, F_SUB=40, TRACK_SUB=8, BY_DY=308, F_BY=38,
            BASE_Y=int(H * 0.88), BAR_SPAN=0.80, BAR_H=0.24, SWEEP=0.40,
            GLOW_IN=26, N_BARS=72,
            O_GLOW=o(22), O_F_WORD=o(92), O_WORD_DY=o(-190), O_F_SUB=o(28),
            O_SUB_DY=o(-96), O_RULE_HALF=o(250), O_RULE_DY=o(-14),
            O_F_COPY=o(42), O_COPY_DY=o(10), O_F_ARR=o(28), O_ARR_DY=o(74),
            O_F_L2=o(26), O_L2_DY=o(152), O_F_DISC=o(24), O_DISC_DY=o(196),
            O_TRACK_WORD=o(9), O_TRACK_SUB=o(6),
        )
    else:
        # Type is scaled from the WIDTH, then boosted: a phone screen is held
        # close and Shorts are watched small, so the wordmark carries more of
        # the frame than it does in 16:9.
        k = (W / 1920.0) * 1.55
        r = lambda v: int(round(v * k))
        LAYOUT = dict(
            TEXT_Y=int(H * 0.30), F_WORD=r(150), TRACK_WORD=r(14),
            RULE_HALF=r(330), RULE_DY=r(190), SUB_DY=r(218), F_SUB=r(40),
            TRACK_SUB=r(8), BY_DY=r(308), F_BY=r(38),
            BASE_Y=int(H * 0.80), BAR_SPAN=0.86, BAR_H=0.16, SWEEP=0.43,
            GLOW_IN=r(26), N_BARS=48,
            O_GLOW=r(22), O_F_WORD=r(92), O_WORD_DY=r(-190), O_F_SUB=r(28),
            O_SUB_DY=r(-96), O_RULE_HALF=r(250), O_RULE_DY=r(-14),
            O_F_COPY=r(42), O_COPY_DY=r(10), O_F_ARR=r(28), O_ARR_DY=r(74),
            O_F_L2=r(26), O_L2_DY=r(152), O_F_DISC=r(24), O_DISC_DY=r(196),
            # Literals, not r(): these are the values outro_frame used to
            # hardcode, and a Short is already boosted 1.55x and watched at
            # phone width, where its wordmark measures ~21 px cap. Scaling the
            # tracking here too would change the shipped portrait cards for no
            # legibility gain.
            O_TRACK_WORD=9, O_TRACK_SUB=6,
        )
BG      = (11, 13, 18)
CYAN    = (62, 230, 255)
VIOLET  = (180, 140, 255)
DIM     = (150, 158, 175)
WHITE   = (238, 242, 255)
SF      = "/System/Library/Fonts/SFNS.ttf"
MONO    = "/System/Library/Fonts/SFNSMono.ttf"

# ---------------------------------------------------------------------- brand
# Every word drawn on these cards comes from brand.json, so the same code makes
# another project's cards without an edit. The values above stay as the DEFAULTS
# for anything the file omits — a brand.json with only a wordmark in it works.
#
# ⚠ These are module-level because the frame builders already read them as
# globals; loading a brand REBINDS them. That is why load_brand() is called once
# in main() before any frame is drawn, and never per-frame.
BRAND = {
    "wordmark": "YOUR BRAND", "sub": "S E R I E S", "byline": "",
    "holder": "Your Name", "line2": "", "disclaimer": "",
}

def load_brand(path, theme=None):
    """Read brand.json and rebind the palette/type globals it overrides.

    A THEME is a named overlay inside the same file:

        "themes": {"classical": {"sub": "C L A S S I C A L",
                                 "palette": {"cyan": [255, 196, 120]}}}

    It is applied on top of the base identity, so the mark, the wordmark and
    the fonts stay put and only the accent and the sub-label move. That is the
    point: a series of videos should look like one channel with different
    episodes, not like several channels.
    """
    global BG, CYAN, VIOLET, DIM, WHITE, SF, MONO, BRAND
    if not path or not os.path.exists(path):
        return None
    import json
    d = json.load(open(path))
    if theme:
        themes = d.get("themes", {})
        if theme not in themes:
            raise SystemExit(
                f"brand.json has no theme {theme!r}. Known themes: "
                + (", ".join(sorted(themes)) if themes else "(none defined)"))
        overlay = themes[theme]
        merged_pal = dict(d.get("palette", {}))
        merged_pal.update(overlay.get("palette", {}))
        d = {**d, **{k: v for k, v in overlay.items() if k != "palette"},
             "palette": merged_pal}
    for k in BRAND:
        if k in d:
            BRAND[k] = d[k]
    pal = d.get("palette", {})
    for name, key in (("BG","bg"), ("CYAN","cyan"), ("VIOLET","violet"),
                      ("DIM","dim"), ("WHITE","white")):
        if key in pal:
            globals()[name] = tuple(pal[key])
    f = d.get("fonts", {})
    if f.get("sans"): SF   = f["sans"]
    if f.get("mono"): MONO = f["mono"]
    for label, path_ in (("sans", SF), ("mono", MONO)):
        if not os.path.exists(path_):
            raise SystemExit(f"brand.json fonts.{label}: no such file {path_}")
    return path


def run(a):
    p = subprocess.run(a, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"FAILED {' '.join(a[:8])}\n{p.stderr[-1500:]}")


def font(path, size):
    return ImageFont.truetype(path, size)


def centre(d, text, f, y, fill, track=0):
    """Draw horizontally centred text, optionally letterspaced."""
    if not track:
        w = d.textlength(text, font=f)
        d.text(((W - w) / 2, y), text, font=f, fill=fill)
        return
    widths = [d.textlength(c, font=f) for c in text]
    total = sum(widths) + track * (len(text) - 1)
    x = (W - total) / 2
    for c, cw in zip(text, widths):
        d.text((x, y), c, font=f, fill=fill)
        x += cw + track


def glow(img, radius=28, strength=0.85):
    """Bloom: the design language's glow is a real blur, not a stroke."""
    b = img.filter(ImageFilter.GaussianBlur(radius))
    return Image.blend(img, Image.blend(img, b, 0.85), strength)


def ease(t):
    return t * t * (3 - 2 * t)


def envelope(audio, n):
    """Per-frame loudness of the sting, so the bars move with the actual music."""
    if not audio or not os.path.exists(audio):
        return [0.35 + 0.3 * math.sin(i / n * math.pi) for i in range(n)]
    import numpy as np, soundfile as sf
    x, sr = sf.read(audio, dtype="float32")
    if x.ndim > 1:
        x = x.mean(axis=1)
    out = []
    for i in range(n):
        a, b = int(i / n * len(x)), int((i + 1) / n * len(x))
        seg = x[a:max(b, a + 1)]
        out.append(float(np.sqrt((seg ** 2).mean() + 1e-12)))
    m = max(out) or 1.0
    return [min(1.0, v / m) for v in out]


def intro_frame(i, n, env, on_black=False, sub=None):
    sub = BRAND["sub"] if sub is None else sub
    """Two layers: a blurred GLOW pass, then the same shapes drawn sharp on top.

    Blurring the whole frame (the first attempt) greys the wordmark out — the
    text has to be composited crisp over the bloom, not inside it.
    """
    from PIL import ImageChops
    t = i / (n - 1)
    base = Image.new("RGB", (W, H), (0, 0, 0) if on_black else BG)
    glow_l = Image.new("RGB", (W, H), (0, 0, 0))
    gd = ImageDraw.Draw(glow_l)

    # ⚠ These two zones MUST NOT overlap: at full level the bars reach
    # BASE_Y - 0.24*H = 691 px, and the lowest text sits at 548. Raise the
    # bar height and the byline disappears behind the spectrum.
    L = LAYOUT
    BASE_Y = L["BASE_Y"]            # the bars stand on this line
    TEXT_Y = L["TEXT_Y"]            # top of the wordmark

    def bars(d, scale=1.0):
        grow = ease(max(0.0, min(1.0, (t - 0.10) / 0.30)))
        if grow <= 0:
            return
        n_bars, span = L["N_BARS"], W * L["BAR_SPAN"]
        bw = span / n_bars
        lvl = 0.25 + 0.75 * env[i]
        for k in range(n_bars):
            x = (W - span) / 2 + k * bw
            shape = math.sin((k + 0.5) / n_bars * math.pi) ** 0.9
            jit = 0.45 + 0.55 * abs(math.sin(k * 2.3 + t * 7.0))
            h = grow * lvl * shape * jit * (H * L["BAR_H"]) * scale
            if h < 3:
                continue
            col = VIOLET if k % 4 == 0 else CYAN
            d.rectangle([x + 2, BASE_Y - h, x + bw - 3, BASE_Y], fill=col)

    # the opening scan line, which the bars grow out of
    sweep = ease(min(1.0, t / 0.30))
    if sweep > 0.01:
        half = sweep * (W * L["SWEEP"])
        gd.line([(W/2 - half, BASE_Y), (W/2 + half, BASE_Y)], fill=CYAN, width=4)
    bars(gd)
    glow_l = glow_l.filter(ImageFilter.GaussianBlur(L["GLOW_IN"]))
    base = ImageChops.add(base, glow_l)

    d = ImageDraw.Draw(base)
    if sweep > 0.01:
        half = sweep * (W * L["SWEEP"])
        d.line([(W/2 - half, BASE_Y), (W/2 + half, BASE_Y)], fill=CYAN, width=3)
    bars(d)

    # the wordmark resolves as the sting lands (beat 7 of the sting = 3.5 s)
    show = ease(max(0.0, min(1.0, (t - 0.42) / 0.26)))
    if show > 0:
        lift = int((1 - show) * 30)
        fade = lambda c: tuple(int(v * show) for v in c)
        centre(d, BRAND["wordmark"], font(SF, L["F_WORD"]), TEXT_Y + lift, fade(WHITE),
               track=L["TRACK_WORD"])
        rh, rdy = L["RULE_HALF"] * show, TEXT_Y + L["RULE_DY"]
        d.line([(W/2 - rh, rdy), (W/2 + rh, rdy)], fill=fade(CYAN), width=3)
        centre(d, sub, font(MONO, L["F_SUB"]), TEXT_Y + L["SUB_DY"] + lift, fade(VIOLET),
               track=L["TRACK_SUB"])
    by = ease(max(0.0, min(1.0, (t - 0.66) / 0.24)))
    if by > 0 and BRAND["byline"]:
        centre(d, BRAND["byline"], font(SF, L["F_BY"]), TEXT_Y + L["BY_DY"],
               tuple(int(v * by) for v in DIM))
    return base


def outro_shift(line2, show_disclaimer=True):
    """How far to slide the outro block when the disclaimer is dropped.

    The card's lines sit at fixed offsets from the vertical centre, so simply
    not drawing the last one leaves the block hanging high with a hole under
    it. Re-centring means moving everything down by HALF the height that was
    removed, which puts the remaining lines back around the same optical
    centre — no gap where the disclaimer used to be.

    Returns 0 whenever nothing was actually removed, so the default card stays
    pixel-for-pixel what it has always been at a given type scale.
    """
    L = LAYOUT
    if show_disclaimer or not BRAND["disclaimer"]:
        return 0
    bottom = lambda text, f: (f.getbbox(text)[3] if text else 0)
    full = L["O_DISC_DY"] + bottom(BRAND["disclaimer"], font(SF, L["O_F_DISC"]))
    if line2:
        trimmed = L["O_L2_DY"] + bottom(line2, font(SF, L["O_F_L2"]))
    else:
        trimmed = L["O_ARR_DY"] + bottom("All rights reserved.",
                                         font(SF, L["O_F_ARR"]))
    return int(round(max(0, full - trimmed) / 2))


def outro_frame(i, n, holder, line2, year, sub=None, show_disclaimer=True):
    """Crisp text over a blurred glow pass — the same two-layer trick as the
    intro. Blurring the finished frame turns white text grey.

    ⚠ `show_disclaimer` is not cosmetic. brand.json's disclaimer says
    "Narration is a synthetic voice", and six visualiser videos containing no
    speech at all shipped carrying it — a card asserting something about the
    film that was not true of the film. A line about narration belongs only on
    something narrated, so the caller has to say which this is.
    """
    sub = BRAND["sub"] if sub is None else sub
    from PIL import ImageChops
    t = i / (n - 1)
    L = LAYOUT
    base = Image.new("RGB", (W, H), BG)
    gl = Image.new("RGB", (W, H), (0, 0, 0))
    gd = ImageDraw.Draw(gl)
    # ⚠ The shift has to reach BOTH passes, which is why it lives in `cy`.
    # Move only the sharp text and the bloom stays where it was, which reads
    # as a printing misregistration rather than as a design.
    cy = H // 2 + outro_shift(line2, show_disclaimer)
    a = ease(min(1.0, t / 0.20)) * (1.0 if t < 0.82 else 1 - ease((t - 0.82) / 0.18))
    fade = lambda c: tuple(int(v * a) for v in c)
    tw, ts = L["O_TRACK_WORD"], L["O_TRACK_SUB"]

    rh, ry = L["O_RULE_HALF"], cy + L["O_RULE_DY"]
    gd.line([(W/2 - rh, ry), (W/2 + rh, ry)], fill=fade(CYAN), width=4)
    centre(gd, sub, font(MONO, L["O_F_SUB"]), cy + L["O_SUB_DY"], fade(VIOLET), track=ts)
    base = ImageChops.add(base, gl.filter(ImageFilter.GaussianBlur(L["O_GLOW"])))

    d = ImageDraw.Draw(base)
    centre(d, BRAND["wordmark"], font(SF, L["O_F_WORD"]), cy + L["O_WORD_DY"],
           fade(WHITE), track=tw)
    centre(d, sub, font(MONO, L["O_F_SUB"]), cy + L["O_SUB_DY"], fade(VIOLET), track=ts)
    d.line([(W/2 - rh, ry), (W/2 + rh, ry)], fill=fade(CYAN), width=3)
    centre(d, f"© {year} {holder}", font(SF, L["O_F_COPY"]), cy + L["O_COPY_DY"], fade(WHITE))
    centre(d, "All rights reserved.", font(SF, L["O_F_ARR"]), cy + L["O_ARR_DY"], fade(DIM))
    if line2:
        centre(d, line2, font(SF, L["O_F_L2"]), cy + L["O_L2_DY"], fade(DIM))
    if show_disclaimer and BRAND["disclaimer"]:
        centre(d, BRAND["disclaimer"], font(SF, L["O_F_DISC"]), cy + L["O_DISC_DY"], fade(DIM))
    return base


def badge(text, colour, out, w=420, h=96):
    """A corner label burned over A/B footage.

    Without it a before/after comparison is a coin flip for the viewer: the two
    clips look nearly identical and only the sound differs, so nothing on screen
    says which one they are hearing.
    """
    from PIL import ImageChops
    im = Image.new("RGB", (w, h), (0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0, 0, w - 1, h - 1], 14, fill=(16, 19, 27), outline=colour, width=3)
    f = font(MONO, 40)
    tw = d.textlength(text, font=f)
    d.text(((w - tw) / 2, (h - 52) / 2), text, font=f, fill=colour)
    im.save(out)
    return out


def _vf():
    # ⚠ Built on demand. As a module-level constant it froze 1920x1080 at
    # import time and silently ignored --size, producing a letterboxed
    # landscape card inside a portrait file.
    return (f"scale={W}:{H}:force_original_aspect_ratio=decrease,"
            f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=0x0a0e14,"
            f"fps={FPS},format=yuv420p,setsar=1")


set_size(W, H)  # populate LAYOUT for importers


def encode(frames_dir, seconds, out, audio=None):
    """Same VF chain and encoder flags the assembler uses, so concat -c copy is safe."""
    silent = None
    if not audio:
        silent = os.path.join(frames_dir, "_silence.wav")
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
             "-i", f"anullsrc=r=48000:cl=stereo", "-t", f"{seconds:.3f}",
             "-c:a", "pcm_s16le", silent])
    a = audio or silent
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-framerate", str(FPS), "-i", os.path.join(frames_dir, "f%04d.png"),
         "-i", a,
         "-vf", _vf(), "-c:v", "libx264", "-preset", "medium", "-crf", "20",
         "-pix_fmt", "yuv420p", "-r", str(FPS),
         "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-ar", "48000",
         "-t", f"{seconds:.3f}", "-shortest", out])


def composite(frames_dir, background, seconds, out, audio):
    """Screen-blend the title over supplied footage.

    Screen is the right operator here because the card is glowing marks on
    black: black leaves the background untouched and only the glow adds. It
    needs no alpha channel, which most generated video does not carry anyway.
    The background is trimmed/looped to exactly `seconds` first, so a clip that
    is a little short does not shorten the intro.
    """
    tmp_bg = os.path.join(frames_dir, "_bg.mp4")
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-stream_loop", "-1",
         "-i", background, "-t", f"{seconds:.3f}", "-an",
         "-vf", _vf(), "-c:v", "libx264", "-preset", "medium", "-crf", "20",
         "-pix_fmt", "yuv420p", "-r", str(FPS), tmp_bg])
    silent = os.path.join(frames_dir, "_sil.wav")
    if not audio:
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
             "-i", "anullsrc=r=48000:cl=stereo", "-t", f"{seconds:.3f}",
             "-c:a", "pcm_s16le", silent])
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-i", tmp_bg, "-framerate", str(FPS), "-i", os.path.join(frames_dir, "f%04d.png"),
         "-i", audio or silent,
         "-filter_complex",
         f"[1:v]{_vf()}[fg];[0:v][fg]blend=all_mode=screen:shortest=1,format=yuv420p,setsar=1[v]",
         "-map", "[v]", "-map", "2:a",
         "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
         "-r", str(FPS), "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-ar", "48000",
         "-t", f"{seconds:.3f}", "-shortest", out])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("kind", choices=["intro", "outro"])
    ap.add_argument("--size", default="1920x1080",
                    help="WxH, e.g. 1080x1920 for a vertical Short")
    ap.add_argument("--theme", help="a named overlay from brand.json's \"themes\" map; "
                                    "shifts the accent and sub-label, never the wordmark")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--audio", help="intro: the sting; drives the bar animation")
    ap.add_argument("--background", help="intro: optional video to composite under the title")
    # Identity comes from brand.json. These flags stay as per-render overrides;
    # None means "whatever the brand file says", so a project sets its wordmark,
    # holder and disclaimer ONCE instead of on every invocation.
    ap.add_argument("--brand", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                    os.pardir, "brand.json"),
                    help="brand.json to draw the identity from")
    # ⚠ The copyright holder is NOT something this script can know. It comes
    # from the brand file and is always printed back.
    ap.add_argument("--holder", default=None)
    # No invented URL: a domain this script guessed at would be a fabricated
    # claim on a copyright card. Put a real one in brand.json or pass --line2.
    ap.add_argument("--line2", default=None)
    ap.add_argument("--year", default=str(__import__("datetime").date.today().year))
    # The per-video cards say one thing, channel-level cards another. Spaced
    # letters, because the mark is drawn letter-by-letter with tracking.
    ap.add_argument("--sub", default=None)
    # ⚠ outro: the brand disclaimer is a CLAIM ABOUT THE FILM, not decoration.
    # Six visualisers with no speech in them shipped saying "Narration is a
    # synthetic voice", because this line was stamped unconditionally. Pass
    # --no-disclaimer on anything that is not narrated; the remaining lines
    # re-centre so there is no gap where it was.
    ap.add_argument("--no-disclaimer", dest="disclaimer", action="store_false",
                    default=True,
                    help="outro: omit the brand.json disclaimer line. Use it on "
                         "any video with NO narration — the default line claims "
                         "there is a synthetic voice, which would be false.")
    a = ap.parse_args()

    try:
        w, h = (int(x) for x in a.size.lower().split("x"))
    except ValueError:
        sys.exit(f"--size must look like 1080x1920, got {a.size!r}")
    if min(w, h) < 64 or w % 2 or h % 2:
        sys.exit(f"--size {a.size}: dimensions must be even and at least 64 px "
                 "(h264 requires even dimensions)")
    set_size(w, h)
    print(f"  size : {W}x{H} ({'portrait' if H > W else 'landscape'})")

    used = load_brand(os.path.normpath(a.brand) if a.brand else None, a.theme)
    print(f"  brand: {used or 'built-in defaults (no brand.json found)'}"
          + (f"  theme: {a.theme}" if a.theme else ""))
    holder = a.holder if a.holder is not None else BRAND["holder"]
    line2  = a.line2  if a.line2  is not None else BRAND["line2"]
    sub    = a.sub    if a.sub    is not None else BRAND["sub"]

    n = int(round(a.seconds * FPS))
    with tempfile.TemporaryDirectory() as tmp:
        env = envelope(a.audio, n) if a.kind == "intro" else None
        for i in range(n):
            im = (intro_frame(i, n, env, on_black=bool(a.background), sub=sub)
                  if a.kind == "intro"
                  else outro_frame(i, n, holder, line2, a.year, sub=sub,
                                   show_disclaimer=a.disclaimer))
            im.save(os.path.join(tmp, f"f{i:04d}.png"))
        if a.kind == "intro" and a.background:
            composite(tmp, a.background, a.seconds, a.out, a.audio)
        else:
            encode(tmp, a.seconds, a.out, a.audio if a.kind == "intro" else None)
    print(f"WROTE {a.out}  ({a.seconds:.1f}s, {n} frames)")
    if a.kind == "outro":
        print(f"  copyright holder used: {holder!r} — set it in brand.json or --holder")
        # Printed either way: a claim about the film that is silently present
        # is exactly how six un-narrated videos came to carry one.
        print("  disclaimer  : "
              + (repr(BRAND["disclaimer"]) if a.disclaimer and BRAND["disclaimer"]
                 else "OMITTED (--no-disclaimer)" if not a.disclaimer
                 else "none set in brand.json"))


if __name__ == "__main__":
    sys.exit(main())
