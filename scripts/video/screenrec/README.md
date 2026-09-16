# screenrec — record ONE window to mp4 (ScreenCaptureKit)

Built 2026-09-05, for the "I can dance now" film and anything else where the
point is **motion**.

## What it is for, and what it is NOT for

⭐ **`debug.captureUI` / `view.capture` remains the DEFAULT capture method for
this project.** It is headless, needs no permission, does not put the app on the
user's screen, and the user named it as a feature they like. Do not migrate away
from it for convenience.

**This tool is the exception, for motion only** — a control actually being
dragged, a terminal scrolling, a playhead sweeping, the dance film. Measured:
`debug.captureUI` runs at about **3.5 fps** (and `scale` does not change it), so
it cannot film movement at all. This records at a real frame rate: **measured
150 frames in 5.0 s at `--fps 30`.**

## Build

```sh
swiftc -O -swift-version 5 -framework ScreenCaptureKit -framework AVFoundation \
       -framework AppKit -o screenrec screenrec.swift
```

Compiles with **zero warnings**. The binary is not committed; rebuild it here.

## Use

```sh
./screenrec --list                                    # what is capturable
./screenrec --app "DAW Pro" --out out.mp4 --seconds 20 --fps 30
./screenrec --window-title "Piano Roll" --out roll.mp4 --seconds 8 --scale 0.5
```

`--app` and `--window-title` are case-insensitive substring matches and may be
combined; when several windows match, the largest wins. `--scale` multiplies the
window's own size (dimensions are forced even — h264 refuses odd ones, and the
failure is late and cryptic).

## Permission

Needs **Screen Recording**, granted to the app that RUNS it (Terminal, not this
binary): System Settings → Privacy & Security → Screen & System Audio Recording.
The grant applies on Terminal relaunch.

⚠️ **VERIFIED GRANTED on this machine 2026-09-05** — `--list` returned real
window titles, which is impossible without it.

## ⚠️ Three traps that cost real time building this

1. **`--list` succeeding proves NOTHING about whether capture will work.**
   Listing shareable content needs no window-server connection; `startCapture`
   does, and a bare CLI has none — it aborts with
   `Assertion failed: (did_initialize), function CGS_REQUIRE_INIT`. Fixed by
   initialising `NSApplication` as `.accessory`, which gets the connection
   without a Dock icon and without stealing focus from the window being filmed.
2. **An empty window list is AMBIGUOUS** — no permission, or nothing on screen.
   The two produce identical output. `--list` refuses to print an empty list and
   explains both possibilities instead.
3. **SCStream delivers a buffer every frame interval whether the window changed
   or not**, and the unchanged ones carry no image. Appending them yields a file
   whose frame count looks right and whose motion is wrong. Only `.complete`
   frames are written, and the tool **prints the frame count and fails loudly at
   zero** — a valid-but-empty mp4 is this project's characteristic failure shape.

## Proven, not assumed

Recorded a moving window and checked the frames actually move:
`freezedetect` reported **0 freeze events** on the recording while firing on a
deliberately static control. A recording of 150 identical frames probes the same
as a real one, so the control is the only thing that separates them.

## ⭐⭐ Two questions that sound the same: "limit to the app" and "maximize it"

### Limiting to the app is STRUCTURAL, not a matter of aiming

`SCContentFilter(desktopIndependentWindow:)` captures the window's **own pixels
at the compositor**, not a region of the screen. **VERIFIED 2026-09-05:** the
staging DAW window was recorded while it was neither frontmost nor unobstructed
— terminals and editors overlapped it on screen — and **none of them appear in
the recording.** Nothing else can leak into the file even if it is sitting on
top of the target.

⚠️ That makes the capture safe once the RIGHT window is matched. It does not
make matching safe: `--app`/`--window-title` take the LARGEST match silently, so
still look at the first frame.

### For quality, DO NOT maximize — capture at `--scale 2.0`

The display is Retina. A "1500x950" window already has **~3000x1900 real pixels**
behind it, and capturing at `--scale 1.0` throws half of them away, then the film
upscales the result to 1920x1080 — soft text, twice degraded.

**MEASURED 2026-09-05:** the same region captured at 1x (upscaled to match) vs 2x
(native) — the 2x crop resolves letterforms the 1x crop smears. **Use
`--scale 2.0` for anything going into a film**; 3000x1900 downsamples to
1920x1080 cleanly.

⭐ **The two are different tools for different problems.** `--scale` gives the
SAME interface more sharply. Maximizing shows MORE interface at the same
sharpness — a framing decision, not a quality one.

### If you do want to resize the window: `debug.windowFrame`

`debug.windowFrame {width, height}` (content-rect points, floors enforced by
`WindowFloor`) resizes the app's main window over the wire — no Accessibility
permission, no AppleScript.

⭐ **A 16:9 window is worth setting for film work.** The default 1500x950 is
1.579:1 against a 1.778:1 film, so every shot is cropped or pillarboxed.
`{width: 1600, height: 900}` matches the film exactly and, at `--scale 2.0`,
captures 3200x1800 — a clean 1.667x downsample to 1920x1080.

⛔ **NEVER resize mid-build.** `debug.captureUI` stills taken before and after a
resize have different dimensions, and a film assembled from both will have its
frame size change partway through. Set the window BEFORE a film's shooting
starts, not during.
