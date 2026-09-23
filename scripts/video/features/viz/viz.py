#!/usr/bin/env python3
"""viz.py — turn a rendered stereo WAV into a music-visualisation video.

Two output formats:
    long   16:9  1920x1080, the whole track
    short  9:16  1080x1920, a --start/--duration window

The visualisation is led by ffmpeg's `showcqt` (constant-Q transform), which is
note-aligned: a semitone is a fixed number of pixels, so pitches land on musical
note positions instead of being crushed into the bottom of a linear-Hz display.
A `showwaves` strip carries rhythm and dynamics, and a progress bar tracks
position.

TEXT: ffmpeg on this machine is built WITHOUT freetype, so the `drawtext`
filter does not exist (verify: `ffmpeg -hide_banner -filters | grep drawtext`).
All text — title, subtitle, note names — is rendered to transparent PNGs with
Pillow and composited with `overlay`.

Pillow is NOT present on any system python here, so this script keeps its own
virtualenv next to itself (`.venv/`) and re-execs into it. First run needs
network; after that it is offline.

Examples
--------
    python3 viz.py --input mix.wav --output out_long.mp4 --format long \
        --title "Night Drive" --subtitle "DAW Pro · Original Mix"

    python3 viz.py --input mix.wav --output out_short.mp4 --format short \
        --start 12 --duration 15 \
        --title "Night Drive" --subtitle "chorus"
"""
from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
VENV_DIR = SCRIPT_DIR / ".venv"
_REEXEC_FLAG = "VIZ_PY_REEXEC"


# ---------------------------------------------------------------------------
# Pillow bootstrap
# ---------------------------------------------------------------------------
def ensure_pillow() -> None:
    """Make `PIL` importable, re-execing into a local venv if necessary."""
    try:
        import PIL  # noqa: F401
        return
    except ImportError:
        pass

    if os.environ.get(_REEXEC_FLAG):
        sys.exit(
            "viz.py: Pillow still missing after re-exec into %s.\n"
            "Install it manually:  %s -m pip install Pillow" % (VENV_DIR, sys.executable)
        )

    venv_python = VENV_DIR / "bin" / "python"
    if not venv_python.exists():
        print("viz.py: creating %s and installing Pillow (needs network once)" % VENV_DIR,
              file=sys.stderr)
        subprocess.run([sys.executable, "-m", "venv", str(VENV_DIR)], check=True)
        subprocess.run([str(venv_python), "-m", "pip", "install", "--disable-pip-version-check",
                        "-q", "Pillow"], check=True)

    os.environ[_REEXEC_FLAG] = "1"
    os.execv(str(venv_python), [str(venv_python), str(Path(__file__).resolve()), *sys.argv[1:]])


ensure_pillow()
from PIL import Image, ImageDraw, ImageFont  # noqa: E402


# ---------------------------------------------------------------------------
# Palette — dark, high contrast, readable on a phone and on a monitor
# ---------------------------------------------------------------------------
BG_TOP = (10, 14, 22)
BG_BOTTOM = (4, 6, 10)
INK = (240, 245, 252)
INK_DIM = (150, 166, 186)
ACCENT = (47, 217, 232)      # cyan  — matches showcqt's right channel
ACCENT_2 = (255, 201, 64)    # amber — matches showcqt's left channel
GRID = (120, 150, 180)

FONT_CANDIDATES = {
    "bold": [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Black.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ],
    "regular": [
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/SFNS.ttf",
    ],
    "mono": [
        "/System/Library/Fonts/SFNSMono.ttf",
        "/System/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/Supplemental/Courier New Bold.ttf",
    ],
}


def load_font(kind: str, size: int) -> ImageFont.FreeTypeFont:
    last = None
    for path in FONT_CANDIDATES[kind]:
        try:
            return ImageFont.truetype(path, size)
        except Exception as exc:  # noqa: BLE001
            last = exc
    raise SystemExit("viz.py: no usable %s font found (last error: %r)" % (kind, last))


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
class Layout:
    """Pixel geometry for one output format.

    showcqt's own height constraint: bar_h + axis_h + sono_h == height. We run
    with axis=0 (its built-in note axis uses a tiny fixed bitmap font that is
    illegible on a phone) and draw a larger note ruler ourselves, so
    bar_h + sono_h must equal cqt_h exactly. ffmpeg does NOT error when they
    do not sum — it silently leaves a dead band — so this is asserted below.
    """

    def __init__(self, fmt: str):
        if fmt == "long":
            self.w, self.h = 1920, 1080
            self.margin = 56
            self.title_y, self.title_size = 36, 66
            self.sub_y, self.sub_size = 112, 30
            self.rule_y = 156
            self.cqt_y, self.cqt_h = 180, 724
            self.bar_h = 316
            self.label_y, self.label_size = 914, 26
            self.wav_y, self.wav_h = 958, 96
            self.prog_y, self.prog_h = 1064, 8
        elif fmt == "short":
            self.w, self.h = 1080, 1920
            self.margin = 38
            self.title_y, self.title_size = 214, 74
            self.sub_y, self.sub_size = 318, 34
            self.rule_y = 378
            self.cqt_y, self.cqt_h = 410, 990
            self.bar_h = 430
            self.label_y, self.label_size = 1412, 30
            self.wav_y, self.wav_h = 1476, 170
            self.prog_y, self.prog_h = 1684, 10
        else:
            raise ValueError(fmt)

        self.sono_h = self.cqt_h - self.bar_h
        assert self.bar_h + self.sono_h == self.cqt_h, "showcqt height constraint"

        self.cqt_x = self.margin
        self.cqt_w = self.w - 2 * self.margin
        assert self.cqt_w % 2 == 0, "even width keeps yuv420p happy"


# ---------------------------------------------------------------------------
# Note geometry — the whole point of using a constant-Q transform
# ---------------------------------------------------------------------------
NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def midi_to_hz(m: float) -> float:
    return 440.0 * (2.0 ** ((m - 69.0) / 12.0))


class NoteAxis:
    """Maps MIDI note numbers to x pixels across the CQT band.

    showcqt spreads log2(f) linearly across the width. Putting the left edge a
    half-semitone below the lowest note makes every note sit in the CENTRE of
    its column, which is what makes the display readable as pitch.
    """

    def __init__(self, base_midi: int, octaves: int, x: int, w: int):
        self.base_midi = base_midi
        self.octaves = octaves
        self.semitones = 12 * octaves
        self.left_midi = base_midi - 0.5
        self.right_midi = self.left_midi + self.semitones
        self.x, self.w = x, w

    @property
    def basefreq(self) -> float:
        return midi_to_hz(self.left_midi)

    @property
    def endfreq(self) -> float:
        return midi_to_hz(self.right_midi)

    def x_of(self, midi: float) -> float:
        return self.x + self.w * (midi - self.left_midi) / self.semitones

    def octave_marks(self):
        """(x, label) for every C inside the range."""
        out = []
        m = self.base_midi
        while m <= self.right_midi:
            if m >= self.left_midi:
                out.append((self.x_of(m), "C%d" % (m // 12 - 1)))
            m += 12
        return out


# ---------------------------------------------------------------------------
# Text/graphic layers (drawtext does not exist here — this is the workaround)
# ---------------------------------------------------------------------------
def draw_tracked(draw: ImageDraw.ImageDraw, xy, text: str, font, fill, tracking: float = 0.0):
    """Draw text with letter spacing; returns total advance width."""
    x, y = xy
    total = 0.0
    for ch in text:
        draw.text((x + total, y), ch, font=font, fill=fill)
        total += draw.textlength(ch, font=font) + tracking
    return max(0.0, total - tracking)


def tracked_width(draw: ImageDraw.ImageDraw, text: str, font, tracking: float) -> float:
    if not text:
        return 0.0
    return sum(draw.textlength(c, font=font) for c in text) + tracking * (len(text) - 1)


def fit_font(draw, text: str, kind: str, start_size: int, max_w: float, tracking: float = 0.0):
    """Shrink until the string fits the available width."""
    size = start_size
    while size > 10:
        font = load_font(kind, size)
        if tracked_width(draw, text, font, tracking * size / start_size) <= max_w:
            return font, tracking * size / start_size
        size -= 2
    return load_font(kind, 10), 0.0


def make_background(lay: Layout, path: Path) -> None:
    img = Image.new("RGB", (lay.w, lay.h), BG_BOTTOM)
    px = img.load()
    # vertical gradient
    for y in range(lay.h):
        t = y / max(1, lay.h - 1)
        c = tuple(int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3))
        for x in range(lay.w):
            px[x, y] = c
    # soft glow behind the CQT band so the picture sits on something
    glow = Image.new("RGBA", (lay.w, lay.h), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    cy = lay.cqt_y + lay.cqt_h // 2
    for i in range(26):
        k = i / 25.0
        gd.ellipse(
            [lay.w * 0.5 - lay.w * (0.62 - 0.18 * k), cy - lay.cqt_h * (0.70 - 0.26 * k),
             lay.w * 0.5 + lay.w * (0.62 - 0.18 * k), cy + lay.cqt_h * (0.70 - 0.26 * k)],
            fill=(14, 40, 58, 5),
        )
    img = Image.alpha_composite(img.convert("RGBA"), glow).convert("RGB")
    img.save(path)


def make_foreground(lay: Layout, axis: NoteAxis, title: str, subtitle: str, path: Path) -> None:
    img = Image.new("RGBA", (lay.w, lay.h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    avail = lay.w - 2 * lay.margin

    # --- note grid: a faint vertical line at every C, brighter at middle C ---
    for x, label in axis.octave_marks():
        is_mid = label == "C4"
        d.line([(x, lay.cqt_y), (x, lay.cqt_y + lay.cqt_h)],
               fill=GRID + ((54 if is_mid else 26),), width=2 if is_mid else 1)

    # --- note ruler under the CQT -------------------------------------------
    mono = load_font("mono", lay.label_size)
    d.line([(lay.cqt_x, lay.label_y - 10), (lay.cqt_x + lay.cqt_w, lay.label_y - 10)],
           fill=(60, 78, 96, 170), width=1)
    for x, label in axis.octave_marks():
        tw = d.textlength(label, font=mono)
        tx = min(max(x - tw / 2, lay.cqt_x), lay.cqt_x + lay.cqt_w - tw)
        d.text((tx, lay.label_y), label, font=mono,
               fill=(ACCENT if label == "C4" else INK_DIM) + (235,))
        d.line([(x, lay.label_y - 10), (x, lay.label_y - 3)], fill=GRID + (150,), width=1)

    # --- title / subtitle ----------------------------------------------------
    if title:
        f, _ = fit_font(d, title, "bold", lay.title_size, avail)
        w = d.textlength(title, font=f)
        d.text(((lay.w - w) / 2, lay.title_y), title, font=f, fill=INK + (255,))
    if subtitle:
        up = subtitle.upper()
        trk = lay.sub_size * 0.22
        f, trk = fit_font(d, up, "regular", lay.sub_size, avail, tracking=trk)
        w = tracked_width(d, up, f, trk)
        draw_tracked(d, ((lay.w - w) / 2, lay.sub_y), up, f, INK_DIM + (255,), trk)

    # --- accent rule under the header ---------------------------------------
    rw = min(avail, int(lay.w * 0.30))
    x0 = (lay.w - rw) / 2
    for i in range(rw):
        k = abs(i / rw - 0.5) * 2          # 0 centre, 1 ends
        a = int(232 * (1 - k ** 1.6))
        col = ACCENT if i < rw / 2 else ACCENT_2
        d.line([(x0 + i, lay.rule_y), (x0 + i, lay.rule_y + 2)], fill=col + (a,))

    img.save(path)


def make_playhead(lay: Layout, path: Path) -> None:
    """Thin glowing line that sweeps across the waveform strip."""
    pad, core = 14, 3
    w, h = pad * 2 + core, lay.wav_h + 16
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for i in range(pad):
        a = int(70 * (1 - i / pad) ** 2.2)
        d.rectangle([pad - i - 1, 0, pad + core + i, h], fill=ACCENT + (a,))
    d.rectangle([pad, 0, pad + core - 1, h], fill=(255, 255, 255, 240))
    img.save(path)


def make_progress_bar(lay: Layout, path: Path) -> None:
    """Full-frame-width bar; overlay slides it in from x=-w so it grows from 0."""
    img = Image.new("RGBA", (lay.w, lay.prog_h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for i in range(lay.w):
        k = i / max(1, lay.w - 1)
        col = tuple(int(ACCENT[j] + (ACCENT_2[j] - ACCENT[j]) * k) for j in range(3))
        d.line([(i, 0), (i, lay.prog_h)], fill=col + (255,))
    img.save(path)


# ---------------------------------------------------------------------------
# ffmpeg
# ---------------------------------------------------------------------------
def probe_duration(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "json", str(path)],
        capture_output=True, text=True, check=True).stdout
    return float(json.loads(out)["format"]["duration"])


def hexcol(c) -> str:
    return "0x%02X%02X%02X" % c


def render_wave_picture(src: Path, start: float, dur: float, lay: Layout, path: Path) -> None:
    """Static waveform of the SAME window the video covers.

    A per-frame `showwaves` oscilloscope is useless here: at 30 fps one frame
    holds ~1600 samples spread over ~1800 px, which draws as disconnected
    blobs. A single showwavespic of the whole window shows the track's shape,
    and the playhead says where we are in it. scale=sqrt gives the envelope
    body without flattening dynamics the way cbrt does.
    """
    cmd = ["ffmpeg", "-y", "-hide_banner", "-v", "warning"]
    if start > 0:
        cmd += ["-ss", "%.6f" % start]
    cmd += ["-t", "%.6f" % dur, "-i", str(src),
            "-filter_complex",
            "showwavespic=s=%dx%d:colors=%s|%s:split_channels=1:scale=sqrt"
            % (lay.cqt_w, lay.wav_h, hexcol(ACCENT_2), hexcol(ACCENT)),
            "-frames:v", "1", "-update", "1", str(path)]
    subprocess.run(cmd, check=True)


def build_filtergraph(lay: Layout, axis: NoteAxis, args, dur: float) -> str:
    fps = args.fps
    # Frequency-dependent gain: without it the bass saturates to white and the
    # top third of the note axis reads as empty. Measured on the test signal.
    vol = "%g*sqrt(f/200)" % args.gain
    d = max(dur, 0.001)
    chains = [
        "color=c=0x%02x%02x%02x:s=%dx%d:r=%d[base]" % (*BG_BOTTOM, lay.w, lay.h, fps),
        "[0:a]showcqt=s={w}x{h}:fps={fps}:axis=0:bar_h={bh}:sono_h={sh}:count=6"
        ":basefreq={bf:.6f}:endfreq={ef:.6f}:sono_v='{v}':bar_v='{v}'[cqt]".format(
            w=lay.cqt_w, h=lay.cqt_h, fps=fps, bh=lay.bar_h, sh=lay.sono_h,
            bf=axis.basefreq, ef=axis.endfreq, v=vol),
        "[base][1:v]overlay=0:0[bg]",
        # shortest=1 here: [base] is an infinite color source, [cqt] is driven
        # by the audio, so this is what gives the graph its length.
        "[bg][cqt]overlay=%d:%d:shortest=1[v1]" % (lay.cqt_x, lay.cqt_y),
        "[v1][4:v]overlay=%d:%d[v2]" % (lay.cqt_x, lay.wav_y),
        "[v2][2:v]overlay=0:0[v3]",
        "[v3][5:v]overlay=x='%d+%d*min(t/%.6f\\,1)-(w-1)/2':y=%d[v4]"
        % (lay.cqt_x, lay.cqt_w, d, lay.wav_y - 8),
        "[v4][3:v]overlay=x='-w+w*min(t/%.6f\\,1)':y=%d[v5]" % (d, lay.prog_y),
        "[v5]format=yuv420p[vout]",
    ]
    return ";".join(chains)


def main() -> int:
    p = argparse.ArgumentParser(description="Render a music-visualisation video from a WAV.")
    p.add_argument("--input", required=True, help="input stereo WAV")
    p.add_argument("--output", required=True, help="output MP4")
    p.add_argument("--format", choices=["long", "short"], default="long",
                   help="long = 16:9 1920x1080 whole track; short = 9:16 1080x1920 window")
    p.add_argument("--title", default="", help="title burned into the frame")
    p.add_argument("--subtitle", default="", help="subtitle burned into the frame")
    p.add_argument("--start", type=float, default=0.0, help="window start seconds (short)")
    p.add_argument("--duration", type=float, default=None,
                   help="window length seconds (short; default 15)")
    p.add_argument("--fps", type=int, default=30)
    p.add_argument("--base-note", default="C1", help="lowest note shown, e.g. C1")
    p.add_argument("--octaves", type=int, default=7, help="octaves spanned by the CQT")
    p.add_argument("--gain", type=float, default=12.0, help="CQT brightness")
    p.add_argument("--crf", type=int, default=18)
    p.add_argument("--keep-assets", action="store_true", help="keep the generated PNG layers")
    args = p.parse_args()

    src = Path(args.input).expanduser().resolve()
    if not src.exists():
        sys.exit("viz.py: input not found: %s" % src)
    out = Path(args.output).expanduser().resolve()
    out.parent.mkdir(parents=True, exist_ok=True)

    total = probe_duration(src)
    if args.format == "short":
        start = max(0.0, args.start)
        dur = args.duration if args.duration is not None else 15.0
        dur = min(dur, max(0.1, total - start))
    else:
        start, dur = 0.0, total

    lay = Layout(args.format)

    # base note -> MIDI
    name = args.base_note.strip().upper()
    for i, nn in enumerate(NOTE_NAMES):
        if name.startswith(nn) and (len(nn) == 2 or not name[len(nn):len(nn) + 1] == "#"):
            pitch, octv = i, int(name[len(nn):])
            break
    else:
        sys.exit("viz.py: cannot parse --base-note %r" % args.base_note)
    base_midi = (octv + 1) * 12 + pitch

    axis = NoteAxis(base_midi, args.octaves, lay.cqt_x, lay.cqt_w)

    assets = out.parent / (out.stem + "_assets")
    assets.mkdir(exist_ok=True)
    bg, fg, pb = assets / "bg.png", assets / "fg.png", assets / "prog.png"
    wave, head = assets / "wave.png", assets / "playhead.png"
    make_background(lay, bg)
    make_foreground(lay, axis, args.title, args.subtitle, fg)
    make_progress_bar(lay, pb)
    make_playhead(lay, head)
    render_wave_picture(src, start, dur, lay, wave)

    cmd = ["ffmpeg", "-y", "-hide_banner"]
    if start > 0:
        cmd += ["-ss", "%.6f" % start]          # BEFORE -i: sample accurate,
    cmd += ["-t", "%.6f" % dur, "-i", str(src)]  # and picture/sound share it
    cmd += ["-i", str(bg), "-i", str(fg), "-i", str(pb), "-i", str(wave), "-i", str(head)]
    cmd += [
        "-filter_complex", build_filtergraph(lay, axis, args, dur),
        "-map", "[vout]", "-map", "0:a",
        "-c:v", "libx264", "-preset", "medium", "-crf", str(args.crf),
        "-r", str(args.fps), "-movflags", "+faststart",
        "-c:a", "aac", "-b:a", "192k",
        # Output -t clamps the VIDEO. Measured: without it showcqt flushes its
        # lookahead at EOF and emits ~4 extra frames (904 vs 900 for 30 s at
        # 30 fps), so the video stream ran 0.133 s past the audio.
        "-t", "%.6f" % dur,
        str(out),
    ]

    print("viz.py: %s  %dx%d  %.2fs @ %dfps  (%s .. %s)"
          % (args.format, lay.w, lay.h, dur, args.fps,
             "%.2f" % start, "%.2f" % (start + dur)))
    r = subprocess.run(cmd)
    if r.returncode != 0:
        return r.returncode

    # --- verify what we actually produced ---------------------------------
    info = json.loads(subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries",
         "stream=codec_type,codec_name,width,height,sample_aspect_ratio:format=duration",
         "-of", "json", str(out)], capture_output=True, text=True, check=True).stdout)
    got = float(info["format"]["duration"])
    vs = [s for s in info["streams"] if s["codec_type"] == "video"]
    as_ = [s for s in info["streams"] if s["codec_type"] == "audio"]
    print("viz.py: wrote %s" % out)
    print("        video=%d audio=%d  %dx%d SAR=%s  duration=%.3fs (expected %.3fs)"
          % (len(vs), len(as_), vs[0]["width"], vs[0]["height"],
             vs[0].get("sample_aspect_ratio", "?"), got, dur))
    ok = True
    if (vs[0]["width"], vs[0]["height"]) != (lay.w, lay.h):
        print("        !! wrong frame size"); ok = False
    if abs(got - dur) > 0.15:
        print("        !! duration drift > 0.15s"); ok = False
    if len(vs) != 1 or len(as_) != 1:
        print("        !! expected exactly one video and one audio stream"); ok = False

    if not args.keep_assets:
        for f in (bg, fg, pb, wave, head):
            f.unlink(missing_ok=True)
        try:
            assets.rmdir()
        except OSError:
            pass
    return 0 if ok else 2


if __name__ == "__main__":
    raise SystemExit(main())
