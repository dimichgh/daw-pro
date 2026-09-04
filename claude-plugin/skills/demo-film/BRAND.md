# The DAW Pro Lessons brand

One 5-second opening and one closing card, used unchanged on every video. Both
are produced by `scripts/brand.py`, and both are encoded with the *same* flags
as the film body so the final concat can stay `-c copy`.

```bash
# the sting: hand-written in DAW Pro, then gain-matched (see below)
python3 scripts/brand.py intro --audio sting-norm.wav --out intro.mp4
python3 scripts/brand.py outro --out outro.mp4 --holder "Your Name Here"

python3 scripts/assemble.py --manifest m.json --vo vo/ --out film.mp4 \
    --intro intro.mp4 --outro outro.mp4
```

## Palette and type — from `docs/DESIGN-LANGUAGE.md`, not invented here

| role | value |
|---|---|
| background | `#0B0D12` |
| panel | `#12151D` |
| cyan — playback, active | `#3EE6FF` |
| violet — **anything AI-touched** | `#B48CFF` |
| primary text | `#EEF2FF` |
| dim text | `#969EAF` |

Violet is not a decorative choice: the design language reserves it for
AI-generated and AI-touched content, which is what these lessons are.
Words are SF Pro; every number is SF Mono.

## Two things that cost real time

**This ffmpeg has no `drawtext`** — it is built without libfreetype, so the
filter is simply absent and text silently never appears. Every frame here is
rendered with Pillow instead.

**Do not blur the finished frame to make things glow.** The first version did,
and it turned the white wordmark grey. Glow is a *separate layer*: draw the
glowing marks, blur that, `ImageChops.add` it onto the background, then draw the
sharp copy and the text on top.

## The sting

Written by hand in DAW Pro at 120 BPM, so 5.0 s is exactly 10 beats: a rising
glockenspiel figure over a swelling pad, landing on beat 7 — which is 3.5 s,
which is where the wordmark resolves. Then it rings out.

⚠️ **Gain-match it with a measured static gain, not `loudnorm`.** Single-pass
`loudnorm` on a 5-second clip with a big swell landed 3.7 dB hot. Measure with
`ebur128`, compute `min(-16 - I, -1.5 - TP)`, and apply that as a flat
`volume=` — the dynamics are the whole point of a sting.

## Replacing the background with generated footage

`brand.py intro --background <clip>` screen-blends the title over supplied
video. Screen is the right operator: the card is glowing marks on black, so
black leaves the footage untouched and only the glow adds — no alpha channel
needed, which generated video usually lacks. The clip is looped/trimmed to
exactly 5 s first, so a slightly short clip does not shorten the intro.

### What to ask for

Deliver: **1920×1080, 16:9, exactly 5 seconds, 30 fps, no audio, and no text of
any kind** — the wordmark is composited on top and baked-in text will collide
with it. It must stay **dark**: the title is white and cyan on near-black, and a
bright background destroys it. Keep the centre and the lower third quiet, since
that is where the wordmark and the spectrum bars sit.

**Prompt A — abstract, safest, matches the palette:**

> A slow, elegant abstract motion background for a music-technology title card.
> Near-black background, hex #0B0D12. Thin horizontal filaments of light drift
> slowly from left to right, glowing electric cyan (#3EE6FF) and soft violet
> (#B48CFF). Shallow depth of field, fine grain, subtle volumetric haze. The
> composition is darkest in the centre and along the lower third. Very slow,
> calm, continuous motion, no cuts, no camera shake. Cinematic, high-end
> studio-hardware mood, night-flight avionics. No text, no logos, no people.
> 16:9, 5 seconds.

**Prompt B — literal, if you want it to read as audio:**

> Macro cinematic shot of glowing audio waveforms and thin frequency lines
> rippling across a dark glass surface, viewed almost edge-on. Electric cyan and
> violet light, near-black background #0B0D12, deep shadows, soft bloom, tiny
> dust motes. Slow lateral drift and gentle pulsing in time with unheard music.
> No cuts, no camera shake. The centre of frame stays dark and uncluttered. No
> text, no logos, no people, no instruments. 16:9, 5 seconds.

**Prompt C — for a still (GPT Image) instead of video**, which `brand.py` will
hold under the animated title:

> A 16:9 abstract background for a dark music-software title card. Near-black
> (#0B0D12) with a faint radial glow low in the frame. Thin streaks of electric
> cyan (#3EE6FF) and violet (#B48CFF) light, soft bloom, subtle film grain,
> generous empty space in the centre and lower third. Moody, premium, calm. No
> text, no logos, no people, no user interface. 1920×1080.

Then:

```bash
python3 scripts/brand.py intro --background their-clip.mp4 \
    --audio sting-norm.wav --out intro.mp4
```

## The closing card

⚠️ **The copyright holder is not something this tool can know.** It comes from
**`brand.json`** beside this file — wordmark, sub-label, byline, holder,
disclaimer, palette and fonts all live there, and `--holder`/`--line2`/`--sub`
are per-run overrides of it, not the source of truth. The script always prints
what it used.
`--year` defaults to the current year. `--line2` is a free line and deliberately
contains **no URL** — a domain guessed at by a script is a fabricated claim on a
copyright notice.

The card also carries the synthetic-voice disclosure, which is why it belongs on
every video rather than only in the description.

## One thing the intro does to your chapters

A 5-second opening card makes a 5-second first chapter, and **YouTube requires
every chapter to be at least 10 seconds** — it silently disables chapters for the
whole video if any one is shorter. Do not give the card its own chapter: fold it
into the first real one, which starts at `0:00` anyway. Every later timestamp
shifts by the length of the intro, so derive them from the assembled segment
list rather than editing the old ones by hand.

## Before/after playback (`ab`)

A fix you only hear once is an assertion. Alternating the *same passage*
unfixed and fixed lets a listener actually judge it, and doing it twice is what
makes the difference land.

```json
{"id": "fix-register", "narration": "...", "shots": ["spec-b.png"],
 "loop": "b-register.wav", "burst": "b-register",
 "ab": {"before": "a-muddy.wav", "beforeBurst": "a-muddy",
        "cycles": 2, "seconds": 5.5}}
```

`loop` is the AFTER; `ab.before` is the same passage without the fix. The
assembler emits before/after/before/after and burns a **BEFORE** (amber) or
**AFTER** (green) badge into each half.

⚠️ **The badge is not decoration.** The two clips look nearly identical and only
the sound differs, so with no label the viewer is guessing which one they are
hearing. It is placed centred at 46% height because the top-left corner is the
app's own title bar.

⚠️ **Verify the halves actually alternate, by measurement.** A swapped or
duplicated pair looks perfect and teaches the lesson backwards. Extract each
half's audio from the finished film and compare spectral centroids: every BEFORE
should measure identically, and each AFTER should differ in the direction the
fix predicts.

⚠️ **Say it in the narration.** Without a line announcing the comparison the
alternation reads as a glitch. And watch for the TTS echoing a nearby word —
"then the same passage" came out as "*Listen* the same passage" twice in a row
because the previous sentence ended in "Listen"; rewording the earlier sentence
fixed it where re-rolling did not.
