# viz — music-visualisation pipeline

Turns a rendered stereo WAV into a music-visualisation video in two formats.
Pure ffmpeg + Pillow. It never touches the DAW app, the control port, or MCP.

## Invocations

Both commands are run from this directory.

**Long — 16:9, 1920x1080, whole track**

```sh
python3 viz.py \
  --input test_signal.wav \
  --output out/demo_long.mp4 \
  --format long \
  --title "Night Drive" \
  --subtitle "DAW Pro / Original Mix"
```

**Short — 9:16, 1080x1920, a time window**

```sh
python3 viz.py \
  --input test_signal.wav \
  --output out/demo_short.mp4 \
  --format short \
  --start 12 --duration 14 \
  --title "Night Drive" \
  --subtitle "chorus"
```

`--start` / `--duration` are seconds and only apply to `short`; `long` always
covers the whole file. Both are passed to ffmpeg **before** `-i`, so the
picture and the sound are cut from the same sample offset by construction.

### Other options

| Flag | Default | What |
|---|---|---|
| `--fps` | `30` | frame rate; also drives `showcqt`'s own rate so no frames are duped |
| `--base-note` | `C1` | lowest note on the display (`A0`, `F#2`, …) |
| `--octaves` | `7` | octaves spanned left-to-right |
| `--gain` | `12.0` | CQT brightness |
| `--crf` | `18` | x264 quality |
| `--keep-assets` | off | keep the generated PNG layers next to the output |

## Test material

`make_test_wav.py` synthesises the 30 s stereo test input with `aevalsrc`:

```sh
python3 make_test_wav.py test_signal.wav
```

It is built to *exercise* a constant-Q display rather than flatter it — an
8-note arpeggio stepping every 16th at 120 BPM, the chord alternating A major /
F major every 4 s, a plucked bass, a downbeat bell, a sustained pad, beat
clicks and 8th-note broadband hats. The right channel plays the arpeggio in
reverse order, so the two channels are never the same note. Measured: 30.00 s,
true peak −4.5 dBFS, −17.6 LUFS integrated.

A silent or single-tone file makes a broken visualiser look fine, which is why
the test signal has both a wide pitch range and rhythmic events.

## What is on screen

- **`showcqt`** is the hero. Constant-Q is note-aligned: a semitone is a fixed
  number of pixels, so pitch reads off the horizontal axis directly. The top
  band is the instantaneous spectrum, the band below is the scrolling
  sonogram, and they share an edge so "now" is continuous between them.
  Left channel draws amber, right draws cyan.
- **Note ruler** — `C1 … C7`, with middle C picked out in cyan, plus a faint
  gridline at every C across the CQT. Drawn by us, not by `showcqt` (see
  below).
- **Waveform strip** — a static `showwavespic` of the whole window, split per
  channel, with a sweeping playhead.
- **Progress bar** — full width at the bottom.

## Two measurements that shaped the design

**1. `drawtext` does not exist on this machine.** ffmpeg is built without
freetype, so all text is rendered to transparent PNGs with Pillow and
composited with `overlay`.

```
$ ffmpeg -hide_banner -filters | grep drawtext
(no output, grep exit 1)

$ ffmpeg -hide_banner -filters | grep -w overlay        # positive control
 TS overlay           VV->V      Overlay a video source on top of the input.
(grep exit 0)

$ ffmpeg -hide_banner -version | grep configuration | tr ' ' '\n' \
    | grep -iE 'freetype|fontconfig|harfbuzz|libass'
(no output, grep exit 1)

$ ... | grep -iE 'libx264'                              # positive control
--enable-libx264
```

ffmpeg version 8.1.1, Homebrew, `/opt/homebrew/bin/ffmpeg`.

`showcqt` *does* still draw its own note axis without freetype — it has a
built-in bitmap font — but the glyphs are a fixed tiny size and are illegible
at 9:16 on a phone. We run it with `axis=0` and draw a larger ruler ourselves.

**2. Pillow was not installed.** It is absent from `/usr/bin/python3`,
`/opt/homebrew/bin/python3` (3.14), and `python3.12`. `viz.py` therefore keeps
its own virtualenv at `.venv/` next to itself and re-execs into it; if the
venv is missing it creates it and `pip install`s Pillow, which needs network
**once**. After that the script is offline. There is no system-wide install to
depend on.

## Gotchas worth keeping

- `showcqt` requires `bar_h + axis_h + sono_h == height`. When they do not sum
  ffmpeg does **not** error — it silently leaves a dead band. `Layout`
  asserts it.
- A per-frame `showwaves` oscilloscope is the wrong tool for a wide strip: at
  30 fps one frame holds ~1600 samples spread over ~1800 px and draws as
  disconnected blobs. A single `showwavespic` of the window plus a playhead
  shows the same information and is readable.
- Without a frequency tilt on `sono_v`/`bar_v` the bass saturates to white and
  the top third of the note axis reads as empty. `--gain` feeds
  `gain*sqrt(f/200)`.
- ffmpeg's own expression syntax uses `lt()`/`between()`, not `<`, and commas
  inside `if()`/`min()` must be escaped or single-quoted or the filtergraph
  parser eats them. `viz.py` builds argv as a list and never uses a shell.
- `showcqt` flushes its lookahead at EOF. Measured on a 30 s render: the
  **video** stream came out 904 frames / 30.133 s against an audio stream of
  exactly 30.000 s. (It is not AAC padding — priming is 1024 samples, ~0.021 s,
  and the audio stream measured exact.) `viz.py` passes `-t <dur>` as an
  *output* option to clamp the video, and verifies the result afterwards.
