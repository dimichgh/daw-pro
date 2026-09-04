---
name: ui-capture
description: Drive DAW Pro's user interface over the control port and photograph it — open the piano roll, mixer, effect/synth/sampler cards, quantize, breath pad, musical typing, pickers; select notes with a rubber band; and shoot before/after pairs of a control while you change its value. Use for "take a screenshot of the app", "show me that panel", "capture the compressor with these settings", "make a demo/tutorial video of DAW Pro", or any task where the PIXELS are the deliverable.
---

# /ui-capture — driving and photographing DAW Pro's interface

Every other skill in this suite talks to the **model**. This one talks to the
**window**: which panel is open, what a knob reads, what is selected, what a
screenshot contains.

⭐ **The whole surface is `debug.*`, and it is unreachable from MCP.** These
verbs are app-tier — off `CommandRouter.allCommands`, off the MCP server, off
the Copilot catalog. No MCP tool opens a panel or takes a screenshot. You must
speak the control-protocol WebSocket directly (`ws://127.0.0.1:17600`, override
with `DAW_CONTROL_PORT`). `scripts/dawctl.mjs` is that client; it needs no npm
install, because Node 18+ ships a global `WebSocket`.

```bash
node scripts/dawctl.mjs debug.panelLayout '{"editorMaximized":true}'
node scripts/panels.mjs ids                      # tracks, first clips, inserts
node scripts/panels.mjs shoot ./shots            # every panel, safely targeted
```

⚠️ **Port 17600 is the user's LIVE app and their real project.** Several verbs
here WRITE: a knob value, a note length, a selection, a created track. Nothing
in this skill is read-only unless it says so. Restore what you change, and
prove the restore by re-reading — see *Before/after pairs* below.

---

## The one-paragraph mental model

`debug.*` verbs are mostly **state read/write**: called bare they REPORT the
panel's state, called with parameters they SET it. So the loop is always
*read → set → capture → restore → re-read*. `debug.captureUI` writes a PNG of
the whole main window; there is no region or view selector (only
`target:"plugin"` for a floating plugin window, and `selectClip`, which changes
what the window is showing).

---

## Traps that produced a WRONG SCREENSHOT before they were understood

Every one of these **returned success**. That is the point: on this surface a
bad shot and a good shot are both `{"ok":true}` plus a valid PNG. Verify the
pixels, not the return code.

### 1. A modal you forgot photographs over everything

Open panels stack, and the newest wins. A capture meant for the mixer that
still has the breath pad open is a picture of the breath pad. **Always
`clearModals()` first.**

### 2. Four panels ignore `open` and open on ANY call

`breathPad`, `quantizePanel`, `instrumentPicker`, `effectPicker` document an
`open` parameter that the code never reads: **anything that is not
`{close:true}` opens them.** A "read the state" probe opens the panel.
(`effectEditor`, `synthEditor`, `samplerEditor`, `voicePanel` do obey
`open:true`.)

### 3. The pickers CREATE A TRACK when they cannot find one

`instrumentPicker` and `effectPicker` with no usable `trackId` will *add a
track to the user's project* rather than fail. Always pass a real id.
`panels.mjs shoot` fills targets from the live project and skips a panel it
cannot aim, rather than letting it invent one.

### 4. `debug.musicalTyping` returns early — one verb per call

The handler acts on the first key it recognises and returns. So
`{enable:true, playMode:"chords"}` silently applies **only `enable`**, and the
state it echoes back looks completely valid. Send `{enable:true}`, then
`{playMode:"chords"}`. Valid modes are `notes` and `chords`; an invalid one
errors loudly, which is how you can tell the parameter was read at all.

### 5. `pattern` on the breath pad sets the angle BY ITSELF

`{pattern:"hairpinCrescendo", angleDegrees:0}` applies the pattern and then
overwrites it with the angle, so every shape photographs identically. Send
`pattern` alone. Measured: `flat`→0°, `messaDiVoce`→45°, `lateBloom`→90°,
`hairpinCrescendo`→135°.

### 6. The piano roll has two independent framing traps

- **Pitch.** The roll shows a fixed band (roughly MIDI 48–79 at row height 11).
  A part below it — a bassline at 27–41, a kick at 36 — photographs as an
  **empty grid**. Read the clip's pitch range with `clip.getNotes` first.
- **Scroll.** The roll does **not** follow the playhead horizontally. Seeking
  to the notes does not bring them on screen; only zoom does. The grid is about
  1660 pt wide, so at `pianoRollPPB` 12 beat 56 lands at x=672 (visible) and at
  ppb 38 it lands at x=2128 (not).

### 7. Marquee coordinates are CONTENT points, and gestures must balance

`x = beat * ppb`, `y = (127 - pitch) * rowHeight`, both read from a bare
`debug.pianoRollMarquee` call. A band over beats 0–16 selects nothing on a clip
whose notes start at beat 56 — and reports `count: 0`, cheerfully.
**Check the count.** Every gesture must run `begin → changed* → end`; an
unbalanced one makes the next `begin` throw.

### 8. `project.overview` omits the master chain

Master insert ids are only readable from `debug.insertLabels`, whose ledger
**accumulates across rebuilds** — deleted effects are still listed. The effect
editor rejects a stale id, so opening it is the test for which one is live.

### 9. Identical byte sizes mean identical pictures

The cheapest defect check on a batch of shots:

```bash
md5 -q shots/*.png | sort | uniq -d      # any output = duplicate content
for f in shots/*.png; do echo "$(stat -f%z "$f") $f"; done | sort -n
```

Two shots that should differ and have the same hash means the parameter you
changed never took. This is how trap 5 was found.

---

## Before/after pairs — showing a control being changed

The strongest thing this skill does: photograph a card at one set of values and
again at another, so a viewer sees the knobs move and the numbers change.

```js
import { pair } from "./scripts/panels.mjs";
const r = await pair("./shots", "compressor", {
  driver: "insert",              // or "synth" for the Poly Synth card
  trackId, effectId,
  before: { thresholdDb: -18, ratio: 4, attackMs: 10, releaseMs: 100 },
});
if (!r.restored) throw new Error(`NOT RESTORED: ${JSON.stringify(r.drift)}`);
```

`pair` reads the project's CURRENT values first and treats them as the "after",
so the tuned state is whatever the project genuinely holds — never a number you
typed twice. It then writes `before`, shoots, writes the tuned values back, and
**re-reads to prove the restore landed**. A setter's return is not proof.

Get the honest "before" from the effect's own defaults, not from invention:

```bash
node scripts/dawctl.mjs fx.describe '{"kind":"compressor"}'   # min/max/default
```

---

## Recipes that are known to frame well

| want | do |
|---|---|
| whole song | `ui.showMixer {show:false}` + `panelLayout {editorFraction:0.30}` |
| notes as notes | pick a clip in pitch 48–79; `stepSequencer {mode:"notes"}`; `panelLayout {pianoRollPPB:12, pianoRollRowHeight:11, pianoRollMinimap:true}`; `captureUI {selectClip}` |
| drum grid | `captureUI {selectClip}` on a kit clip, then `stepSequencer {mode:"steps"}` |
| a selection | bare marquee call for `ppb`/`rowHeight`, then `begin`/`changed` at real note beats, capture, then `end` |
| extending notes | marquee `end` returns `selectedIds`; `clip.patchNotes` them; capture; `edit.undo` |
| chord pads | `musicalTyping {enable:true}` then `{playMode:"chords"}` then `{progression:"four-chords"}` |
| a knob card | `effectEditor {open:true, trackId, effectId}` — `trackId` may be the literal `"master"` |
| the EQ curve | same, on an `eq`; the card returns `editorMode:"curve"` in Pro density |

Full parameter schemas for every `debug.*` verb are in
`Sources/DAWApp/DAWProApp.swift`'s dispatch table (~line 5150) and the
`*Staging.swift` files. When a parameter does not seem to take, **read the
handler** — the early-return pattern in trap 4 is common.

---

## Leave the app as you found it

```js
await clearModals();
await send("debug.panelLayout", { pianoRollPPB: 55, pianoRollRowHeight: 14,
                                  editorFraction: 0.43, editorMaximized: false });
await send("transport.seek", { beats: 0 });
await send("ui.showMixer", { show: false });
```

Then re-read `project.overview` and confirm the track / insert / send /
automation counts are what you started with.

---

## Making a film out of these shots

See the **`demo-film`** skill, which takes a manifest of narration lines plus
these captures and renders a narrated video.
