#!/usr/bin/env python3
"""Channel-level brand assets: avatar, banner, and a horizontal lockup.

These are CHANNEL assets and say "AGENTIC". The per-video intro/outro cards in
brand.py say "LESSONS" and are deliberately left alone -- Lessons is a series
inside the channel, not the channel.

⚠ The avatar is displayed as a CIRCLE at sizes down to about 88 px, so it is a
MARK, not a wordmark: at 88 px any lettering is mud. Every render here is
checked by masking to a circle and downscaling, because "looks fine at 800 px"
is not evidence about the size it is actually used at.

⚠ The banner is 2560x1440 but only a centred 1546x423 is shown on every device.
Everything that must be read lives inside that box; the rest is decoration that
some viewers will never see.

    python3 channel.py avatar --out avatar.png
    python3 channel.py banner --out banner.png
    python3 channel.py lockup --out lockup.png
"""
import argparse, math, os
from PIL import Image, ImageDraw, ImageFilter, ImageChops, ImageFont

BG     = (11, 13, 18)
CYAN   = (62, 230, 255)
VIOLET = (180, 140, 255)
WHITE  = (238, 242, 255)
DIM    = (150, 158, 175)
SF   = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"

# The mark: 13 bars whose heights trace a musical swell, symmetric so it reads
# as a considered shape rather than a random spectrum grab. Centre bars are
# VIOLET because the design language reserves violet for anything AI-touched,
# which is the whole premise of the channel.
# The mark is a symmetrical spectrum-bar motif -- a music-themed default. It is
# DATA, not a drawing: put your own `markBars` list in brand.json (any length,
# values 0..1, symmetrical reads best) and the mark becomes yours. There is no
# support for supplying a bitmap; the whole point is that it stays crisp at the
# 88 px circle YouTube actually shows.
BARS = [0.24, 0.38, 0.30, 0.55, 0.72, 0.88, 1.00, 0.88, 0.72, 0.55, 0.30, 0.38, 0.24]

# ---------------------------------------------------------------------- brand
# Same brand.json as brand.py, so a project's cards and its channel art cannot
# drift apart. Only the keys this script draws are read here.
BRAND = {"wordmark": "YOUR BRAND", "channelSub": "C H A N N E L", "tagline": ""}

def load_brand(path):
    global BG, CYAN, VIOLET, WHITE, DIM, SF, MONO, BRAND, BARS
    if not path or not os.path.exists(path):
        return None
    import json
    d = json.load(open(path))
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
    if d.get("markBars"):
        bars = d["markBars"]
        if not all(isinstance(v, (int, float)) and 0 <= v <= 1 for v in bars):
            raise SystemExit("brand.json markBars: every value must be a number in 0..1")
        BARS = list(bars)
    return path

def spaced(text):
    """Draw-ready letter list. brand.json may spell the sub either way."""
    return text if " " in text.strip() else " ".join(text)


def font(p, s):
    return ImageFont.truetype(p, s)


def centre(d, text, f, y, fill, track=0):
    if track:
        w = sum(d.textlength(c, font=f) + track for c in text) - track
        x = (d.im.size[0] - w) / 2
        for c in text:
            d.text((x, y), c, font=f, fill=fill)
            x += d.textlength(c, font=f) + track
    else:
        d.text(((d.im.size[0] - d.textlength(text, font=f)) / 2, y), text, font=f, fill=fill)


def lerp(a, b, t):
    return tuple(int(x + (y - x) * t) for x, y in zip(a, b))


def draw_mark(d, cx, cy, span, height, bw_frac=0.52, ring=None):
    """Bars centred on (cx, cy). `span` is total width, `height` the tallest bar."""
    n = len(BARS)
    pitch = span / n
    bw = pitch * bw_frac
    for i, h in enumerate(BARS):
        # violet in the middle, cyan at the edges
        t = 1.0 - abs(i - (n - 1) / 2) / ((n - 1) / 2)
        col = lerp(CYAN, VIOLET, t ** 1.4)
        bh = h * height
        x = cx - span / 2 + i * pitch + (pitch - bw) / 2
        r = min(bw / 2, 12)
        d.rounded_rectangle([x, cy - bh / 2, x + bw, cy + bh / 2], r, fill=col)
    if ring:
        rr, rw = ring
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=CYAN, width=rw)


def glowed(size, paint, radius=26, strength=0.9):
    """Draw once into a black layer, blur it, add it under a sharp second pass.

    ⚠ Blurring the FINISHED frame is the trap this exists to avoid: it turns
    white text grey. Glow is a separate layer, always.
    """
    base = Image.new("RGB", size, BG)
    gl = Image.new("RGB", size, (0, 0, 0))
    paint(ImageDraw.Draw(gl), True)
    gl = gl.filter(ImageFilter.GaussianBlur(radius))
    if strength != 1.0:
        gl = gl.point(lambda v: int(v * strength))
    base = ImageChops.add(base, gl)
    paint(ImageDraw.Draw(base), False)
    return base


def avatar(out, size=800):
    S = size

    def paint(d, is_glow):
        draw_mark(d, S / 2, S / 2, span=S * 0.56, height=S * 0.42,
                  ring=(S * 0.415, 10))
    im = glowed((S, S), paint, radius=int(S * 0.035))
    im.save(out)
    # circle-masked previews at the sizes YouTube actually renders
    stem = os.path.splitext(out)[0]
    for px in (800, 88):
        sm = im.resize((px, px), Image.LANCZOS).convert("RGBA")
        mask = Image.new("L", (px * 4, px * 4), 0)
        ImageDraw.Draw(mask).ellipse([0, 0, px * 4, px * 4], fill=255)
        sm.putalpha(mask.resize((px, px), Image.LANCZOS))
        flat = Image.new("RGB", (px, px), (255, 255, 255))
        flat.paste(sm, (0, 0), sm)
        flat.save(f"{stem}-circle-{px}.png")
    print(f"  wrote {out} (+ circle previews at 800 and 88 px)")


def to_alpha(im):
    """Turn near-black background into transparency.

    The art is glowing marks on #0B0D12, so how far a pixel sits ABOVE the
    background is exactly how opaque it should be. Done as a per-channel max so
    a saturated cyan bar stays fully opaque instead of going translucent.
    """
    import numpy as np
    a = np.asarray(im).astype(np.int16)
    d = np.clip(a - np.array(BG, dtype=np.int16), 0, 255).max(axis=2)
    alpha = np.clip(d.astype(np.float32) * 3.2, 0, 255).astype(np.uint8)
    out = Image.fromarray(np.dstack([np.asarray(im), alpha]), "RGBA")
    return out


def lockup(out, W=1100, H=420, alpha=False):
    # ⚠ Measure and CENTRE, do not hand-place. The first version drew the mark
    # at a fixed x=200 on a 1600-wide canvas and the artwork ended at x=822 --
    # a logo file that was half empty on the right.
    def paint(d, g):
        fw, fa = font(SF, 108), font(MONO, 40)
        wmW = d.textlength(BRAND["wordmark"], font=fw)
        markW, gap = 250, 110
        x0 = (W - (markW + gap + wmW)) / 2
        tx = x0 + markW + gap
        draw_mark(d, x0 + markW / 2, H / 2, span=markW, height=170)
        d.text((tx, H / 2 - 92), BRAND["wordmark"], font=fw, fill=WHITE)
        d.line([(tx + 2, H / 2 + 34), (tx + 2 + wmW, H / 2 + 34)], fill=CYAN, width=3)
        x = tx + 4
        for c in spaced(BRAND["channelSub"]):
            d.text((x, H / 2 + 52), c, font=fa, fill=VIOLET)
            x += d.textlength(c, font=fa) + 6
    im = glowed((W, H), paint, radius=20)
    if alpha:
        im = to_alpha(im)
    im.save(out)
    print(f"  wrote {out} ({'RGBA, transparent' if alpha else 'RGB, solid'})")


def banner(out, W=2560, H=1440, safe=(1546, 423), guides=False):
    sw, sh = safe
    sx, sy = (W - sw) / 2, (H - sh) / 2
    cy = H / 2

    def paint(d, g):
        # Decoration: a wide, low spectrum sweep that most viewers never see.
        # Nothing here is load-bearing.
        n = 96
        for i in range(n):
            t = i / (n - 1)
            h = (math.sin(t * math.pi) ** 1.6) * (0.10 + 0.06 * math.sin(t * 37))
            bh = h * H
            x = t * W
            col = lerp(CYAN, VIOLET, (math.sin(t * math.pi)) ** 2)
            col = tuple(int(v * 0.30) for v in col)
            d.rounded_rectangle([x - 7, H - 120 - bh, x + 7, H - 120], 6, fill=col)
        # --- everything below is INSIDE the safe area ---
        # ⚠ Measure and CENTRE the whole lockup in the safe box. Left-aligning
        # it inside the box looks balanced on a 2560px desktop banner and badly
        # lopsided on mobile, which crops to the box and nothing else.
        fw, fa, ft = font(SF, 104), font(MONO, 38), font(SF, 34)
        tag = BRAND["tagline"]
        wmW = d.textlength(BRAND["wordmark"], font=fw)
        tagW = d.textlength(tag, font=ft)
        textW = max(wmW, tagW)
        markW, gap = 196, 94
        x0 = sx + (sw - (markW + gap + textW)) / 2
        tx = x0 + markW + gap
        draw_mark(d, x0 + markW / 2, cy, span=markW, height=140)
        d.text((tx, cy - 86), BRAND["wordmark"], font=fw, fill=WHITE)
        d.line([(tx + 2, cy + 36), (tx + 2 + wmW, cy + 36)], fill=CYAN, width=3)
        x = tx + 4
        for c in spaced(BRAND["channelSub"]):
            d.text((x, cy + 54), c, font=fa, fill=VIOLET)
            x += d.textlength(c, font=fa) + 6
        if tag:
            d.text((tx, cy + 116), tag, font=ft, fill=DIM)
    im = glowed((W, H), paint, radius=28)
    if guides:
        g = ImageDraw.Draw(im)
        g.rectangle([sx, sy, sx + sw, sy + sh], outline=(255, 77, 94), width=4)
        g.text((sx + 8, sy + 8), f"SAFE {sw}x{sh}", font=font(MONO, 28), fill=(255, 77, 94))
    im.save(out)
    kb = os.path.getsize(out) / 1024
    print(f"  wrote {out}  ({kb:.0f} KB, limit 6144 KB)")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("what", choices=["avatar", "banner", "lockup"])
    ap.add_argument("--out", required=True)
    ap.add_argument("--guides", action="store_true",
                    help="banner only: draw the safe-area rectangle for checking")
    ap.add_argument("--alpha", action="store_true",
                    help="lockup only: write RGBA with the background knocked out")
    ap.add_argument("--brand", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                    os.pardir, "brand.json"),
                    help="brand.json to draw the identity from")
    a = ap.parse_args()
    used = load_brand(os.path.normpath(a.brand) if a.brand else None)
    print(f"  brand: {used or 'built-in defaults (no brand.json found)'}")
    if a.what == "avatar":
        avatar(a.out)
    elif a.what == "lockup":
        lockup(a.out, alpha=a.alpha)
    else:
        banner(a.out, guides=a.guides)
