# m25-e — How other DAWs scale the waveform inside a clip

Survey run 2026-08-12, on the user's explicit instruction (*"Look how other do it, allow some
zooming to be able to recognize patterns while navigating sound on the track"*). The m25-e
implementation shipped **before** this survey — the agent that built it had no browsing tool and
said so — so this doc exists to check the shipped design against the field, not to inform it.

## The field

| DAW | Mechanism | Default | Scope |
|---|---|---|---|
| **Logic Pro** | **Waveform Zoom** button in the Tracks area menu bar — click-hold, then drag a slider vertically. Also `⌘−` / `⌘+` for preset levels **×1 / ×2 / ×4 / ×8**. Mirrored in the Audio Track Editor with its own Waveform Zoom button. | ×1 (raw) | Global |
| **Pro Tools** | A **zoom cluster** whose LEFT square is vertical zoom for **audio waveforms** and RIGHT square is vertical zoom for **MIDI** — two independent controls. `⌘⌥]` in / `⌘⌥[` out; `R`/`T` with Edit Keyboard Focus; `⇧⌥`+scroll. | raw | Global, all audio tracks |
| **REAPER** | View ▸ **Peaks Display Settings**; actions *"Peaks: Increase/Decrease peaks view gain"*. Also Normal / Rectified / Spectral / Spectrogram display modes. | raw | **Global ONLY — explicitly cannot be done per track.** The documented workaround for relative sizing is to change actual Take/Item/PreFX **volume**. |
| **Ableton Live** | **None.** No vertical waveform zoom exists. The only ways to make a waveform look bigger are to raise clip gain (and compensate with a Utility) or to enlarge the Clip View pane. | — | — |

## The finding that matters

⭐⭐ **NOT ONE of the four auto-normalises. All four draw RAW peaks and offer a MANUAL, GLOBAL
display gain on top.** REAPER goes furthest and makes the position explicit: per-item scaling is
*deliberately impossible*, and if you want one item to look bigger than another you must change its
**actual gain**. That is a considered stance, not an omission — it keeps "that clip looks hotter
than this one" a true statement about the audio.

Live is the counter-example that proves the demand: it has none of this, and its community has
asked for years. Our user's complaint is, almost word for word, the complaint on those threads.

## What this says about what we shipped

**Validated — leave alone:**

- **`⌥⌘±` / `⌥⌘0`.** Matches Pro Tools' `⌘⌥[`/`⌘⌥]` modifier set. Logic's bare `⌘±` is not
  available to us: `⌘+`/`⌘−`/`⌘0` are already the editor zoom (m21-c), and stealing them would be
  a regression. `⌥⌘` is the right disambiguation and it is what a Pro Tools user will try first.
- **The ladder 1 / 1.5 / 2 / 3 / 4 / 6 / 8.** A superset of Logic's ×1/×2/×4/×8 — same endpoints,
  finer middle. No DAW offers less than ×8 at the top, so the ceiling is right.
- **Global scope.** All three DAWs that have the feature are global. We match.
- **Putting the control in the toolbar.** Logic and Pro Tools both put it in the top chrome, not in
  a preferences pane. We match.

**The one real divergence — and it should be a deliberate product decision, not an accident:**

⚠️ **We default to FIT (normalise). No other DAW does.** The defence is genuine and worth stating
plainly rather than discovering later:

- The user's actual complaint *is* the raw-peaks default. Every DAW ships it, and it is exactly
  what produced *"it is too small and a lot of empty space"*. Matching the field here would mean
  reproducing the defect.
- This project's constitution is "the feature depth of Logic Pro with a radically simpler, more
  intuitive experience". A beginner will not go hunting for *"Peaks: Increase peaks view gain"* in
  an actions list. Defaulting to a readable waveform is that thesis applied.
- We keep the pro escape hatch the others rely on: **TRUE LEVEL (RAW)** is persisted and one click
  away, and the FIT boost is **capped at 4× / +12 dB**, so material below a quarter of full scale
  still reads visibly quieter. The cap is what stops FIT from erasing relative level entirely —
  REAPER's objection applies fully only to an uncapped normalise.

**Worth considering later, not shipped:**

- **Logic's click-hold-drag slider** is a better interaction than stepped `−`/`+` for a continuous
  quantity — one gesture to any level, no repeated clicking. Our `−`/readout/`+` cluster is the
  app's own idiom (it mirrors the horizontal zoom cluster), so consistency argues for what shipped;
  revisit only if users report the stepping is tedious.
- **Pro Tools separates audio and MIDI vertical zoom** into two controls. We have no MIDI-lane
  vertical zoom at all, and m25-b already records the related gap (the piano roll's `rowHeight` is
  a fixed 14 with no vertical zoom). If that lands, Pro Tools' two-control layout is the precedent.
- **REAPER's Rectified / Spectral display modes** are a genuinely different axis from zoom, and
  Rectified in particular is documented as helping spot quiet passages — which is close to what the
  user asked for (*"recognize patterns while navigating sound"*). Not filed; noted.

## Sources

- [Scroll and zoom in the Tracks area — Apple Support](https://support.apple.com/guide/logicpro/scroll-and-zoom-in-the-tracks-area-lgcpf7c0b924/mac)
- [The Audio Track Editor in Logic Pro — Apple Support](https://support.apple.com/en-lb/guide/logicpro/lgcp650a7dcc/mac)
- [Waveform Vertical Zoom Out ⌘− — Logic Pro X keyboard command of the day](https://www.studio-interns.com/2019/11/16/waveform-vertical-zoom-out-%E2%8C%98-logic-pro-x-keyboard-command-of-the-day/)
- [Zooming in Pro Tools — Avid user guide](https://www.avid.com/pro-tools/user-guide/zoom)
- [Pro Tools Zooming Shortcuts — Production Expert](https://www.production-expert.com/production-expert-1/pro-tools-zooming-shortcuts)
- [5 Ways to Display Audio in REAPER](https://www.reapertips.com/post/5-ways-to-display-audio-in-reaper)
- [Adjusting peak height in only one track in REAPER 6 — HomeRecording.com](https://homerecording.com/bbs/threads/adjusting-peak-height-in-only-one-track-in-reaper-6.406605/)
- [How to enlarge the wave display in Clip view? — Ableton Forum](https://forum.ableton.com/viewtopic.php?t=185219)
- [Waveform Vertical Zoom "all or nothing" — Ableton Forum](https://forum.ableton.com/viewtopic.php?t=250619)
