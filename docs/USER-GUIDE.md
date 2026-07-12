# User Guide — DAW Pro

Welcome to DAW Pro, a professional digital audio workstation with a glass-cockpit interface and full AI control. This guide walks you through the app from launch to a finished, mixed song.

## Getting Started

### Install & launch

DAW Pro runs on macOS 14+. Choose one:

- **From a disk image** (beta): drag **DAW Pro** to **Applications** and double-click it. On first launch on another Mac, right-click it → **Open** to bypass Gatekeeper (a one-time gate; later launches are normal).
- **From source** (development): run `swift run DAWApp` in the repository.

### First-launch checklist

1. **Microphone permission.** When you record an audio track, macOS will ask for mic access. This is required for audio input; MIDI and instrument tracks do not need it.
2. **AI features** (optional). Song generation via ACE-Step sidecar requires the environment variable `DAWPRO_ACESTEP_DIR` (bundled app) or runs automatically if you're inside the source checkout. Text features (lyrics, naming) need an Anthropic or OpenAI API key in Settings.
3. **Onboarding tour** (optional). On first launch, the app offers a seven-step guided tour. You can replay it anytime from Settings.

## The Workspace

### Arrange, Mix, and density modes

The app has two main views, toggled by the **ARRANGE** ↔ **MIX** header chips:

- **Arrange**: the timeline. Clips line up in horizontal lanes, one per track. This is where you arrange song structure.
- **Mix**: the console. Vertical channel strips (faders, pan, meters, effects, sends) grouped by audio/instrument/bus strips and a pinned master.

Both views have **Simple** and **Pro** density modes — a pair of chips (SIMPLE / PRO) in the toolbar. Simple hides advanced controls and locks the snap grid to the bar for safer editing. Pro reveals everything. Your choice is sticky per panel and survives app restart. A beginner can finish a song in Simple mode; Pro is there when you're ready.

### Explain this (AI help)

Click the violet **EXPLAIN** chip in the header to turn on "Explain this" mode. While on, hover any control and a card pops up with a beginner-readable definition and an "Ask the Copilot →" button. It's an overlay — clicks pass through to the control underneath. Press **Esc** or click the chip again to close it. This mode is always available, even without an API key.

### Copilot rail (AI agent)

A violet **COPILOT** chip in the top-right opens the AI agent sidebar on the far right. Type what you want in plain language — *"add a drum track at 120 BPM"*, *"tighten the timing on the piano"* — and the Copilot uses the same control surface the UI uses to make it happen. Each step is undoable. Requires an API key (Anthropic preferred, OpenAI fallback).

The Copilot works in **rounds**: each round it reads your project, thinks, then makes a batch of changes. One reply is capped at a set number of rounds (8 by default) so a single request can't run away. Change the cap in **Settings → Copilot** ("Max rounds", 1–32); a new value applies to the Copilot's next reply, no restart needed. Raise it for big, multi-step jobs, or lower it to keep replies short and quick. Over the wire, `ai.copilotSend` accepts an optional `maxRounds` number to override the cap for a single turn (clamped to 1–32), and `ai.copilotState` reports the current policy under a `limits` object.

## Tracks & Clips

### Adding a track

Click the **+** in the Arrange track header area or use the menu. Choose a **kind**:

- **Audio**: for recorded vocals, guitars, samples. Plays audio files and records from your mic/input.
- **Instrument**: for MIDI — the built-in synth, sampler, or a hosted AU instrument. Stays armed to receive MIDI from your keyboard (live thru).
- **Bus**: a mix destination. No clips — just receives sends from audio/instrument tracks for group mixing.

A track is stereo by default.

### Importing your own audio

Bring in your own recordings, samples, loops, or stems two ways:

- **File → Import Audio…** (⌘I): pick one or more audio files. They land at the playhead. A single file makes a new audio track; **multiple files each get their own new audio track** (drop a folder of stems and they arrange side by side), named from the filenames.
- **Drag from Finder** onto the Arrange timeline: drop audio files straight onto the lanes. Dropping a single file onto an existing **audio** track adds it there at the drop position (a cyan highlight shows the target lane and a cyan line marks where it will start, snapped to the grid). Dropping on empty space — or dropping several files — creates a new audio track per file. (MIDI/instrument lanes aren't audio targets, so a drop there makes a new track instead.)

Non-audio files are ignored. The whole import is a single undo step.

### Naming a track

Currently, renaming must be done via the Copilot or the wire (`track.rename` command). The UI rename feature is coming.

### Arming & recording audio

Click the **Arm** button (amber glow) on an audio or instrument track. When armed, the track will capture during **transport.record**. A small amber dot glows steadily while armed.

- **Audio tracks** record microphone or input audio.
- **Instrument tracks** record MIDI from a connected keyboard (live thru while stopped or rolling).

### Moving, trimming, and splitting clips

In Arrange, clips are direct-manipulation:

- **Move**: drag the clip body to a new beat position (snap respects the grid — set it with the SNAP chip).
- **Trim**: drag the left or right edge inward to shorten the clip and advance/defer the end. (The edge of the clip, not the waveform.)
- **Split**: double-click inside a clip at the point where you want to cut it.
- **Time-stretch** (audio only): hold **Option** and drag the right edge to change the clip's timeline length. A badge shows the ratio (e.g., "1.50×").

Fades are the small triangular grips at the clip corners. Drag them in/out, double-click or delete to reset, and **Option+click** a grip to flip between linear (straight ramp) and equal-power (curved, for constant volume).

Gain (volume change) is set by clicking the small cyan dB chip that appears on hover/select.

All edits are undoable as a single step.

### Takes & comping

When you record over an existing clip, a take lane automatically forms. A stacked-layers glyph appears on the track header. Click it to open the takes section — you'll see a grid of all your takes (recorded versions) with the current comp lane highlighted. Drag horizontally to paint in the lane you want, or click a lane once to select it entirely. A **FLATTEN** chip lets you dissolve the group back to ordinary clips.

## MIDI & Instruments

### Piano roll editing

Double-click a MIDI clip in Arrange to open the piano-roll editor. The grid shows pitch (vertical) vs. time (horizontal).

- **Add**: click empty space to draw a note.
- **Move**: drag a note left/right or up/down (snap grid applies).
- **Resize**: drag the right edge of a note to change its length.
- **Delete**: double-click or select and press Delete.
- **Velocity**: in Pro mode, a lane below shows each note's loudness. Drag it up/down.

The **SNAP** chip (in Pro mode) sets the grid resolution — Off, Bar, Beat, 1/8, 1/16 (default Beat). In Simple mode, the grid is locked to Beat and you see only add/move/delete.

### Quantizing & groove

If a part was played a little loose, **quantize** nudges the notes onto a tidy timing grid. Open the **QUANTIZE** panel from the piano-roll header (the "QUANTIZE" chip), or right-click a clip in Arrange (in Pro) and choose **Quantize…**.

- **Grid** — the timing grid to snap to, in musical names: 1/4, 1/8, 1/16, 1/32, and triplets (1/8 triplet, …). Pick the smallest division your part actually uses.
- **Strength** — how far each note is pulled toward the grid. 100% tightens completely; part way keeps some of the human feel of the take while still cleaning it up.
- **Apply** — press **APPLY QUANTIZE** to commit. It's one undo step, so ⌘Z restores the original timing.

Flip the panel to **Pro** for more:

- **Swing** — adds a relaxed shuffle by nudging the in-between notes a touch late (50% is straight, up to 75% for a strong bounce).
- **Also snap note ends** — lines up where notes stop, not just where they start.
- **Groove** — instead of the plain grid, apply a **feel** borrowed from elsewhere. Pick a built-in swing preset, or one you've extracted. When a groove is chosen it sets the grid and swing for you (both controls dim to show the groove is in charge); the Strength slider still controls how strongly it's applied.

**Extract a groove.** In the Groove section, **+ Extract from clip** captures the timing feel of the current part as a reusable groove — name it, press **EXTRACT GROOVE**, and it joins the list to stamp onto other parts. You can also right-click any clip in Arrange (in Pro) and choose **Extract Groove…** (this works on audio clips too, using their detected hits).

### Choosing an instrument

Every instrument track carries an **instrument chip** — a small button in the track header (in Arrange) and a wider one in the mixer strip (in Mix) that shows the track's current sound. Click it (or use the wire command `track.setInstrument`) to open the **instrument picker**, a dark-glass panel with a search box and three sections:

- **Built-in** — **Poly Synth** (a warm, tunable synthesizer, the default), **Sampler** (plays your own audio files across the keys), and, in Pro, **Test Tone** (a reference note for checking your setup).
- **Sound Banks** — ready-to-play instruments with **no downloads**. **General MIDI** is built in and gives you **128 classic instruments** (piano, strings, brass, drums, and more) plus a Standard Drum Kit. Click a bank to browse its programs, grouped by family (Piano, Brass, …) with search-as-you-type; the drum kit lives in its own group.
- **Audio Units** — any AU instrument plugin installed on your Mac (Apple's DLSMusicDevice, third-party instruments). Search across the name and maker; a v3 badge marks newer plugins.

**Simple vs Pro.** Flip the SIMPLE / PRO chip in the picker header. **Simple** shows curated **Instrument Sets** — the 16 General MIDI families as one-click choices (Piano, Guitar, Brass, Drums, …), each picking a sensible default sound. **Pro** opens the full browser with program numbers and bank details.

**Zero setup.** General MIDI needs nothing installed — pick a family in Simple or an exact program in Pro and you're playing. When you pick a sound-bank instrument it may say **loading** for a moment (a small dot on the chip) while it prepares; if a bank can't be found the chip shows a warning and the reason, and the track stays silent rather than playing the wrong sound.

**Importing SoundFonts.** In the Sound Banks section, **Add SoundFont…** lets you import a `.sf2` or `.dls` bank file. It's copied into your library and added to the list, ready to select on any instrument track. (Projects reference banks by location, so a project moved to another Mac needs the same bank there — General MIDI, being built in, always works.)

### Opening a plugin window

Some AUs (virtual instruments or effect plugins) have custom UIs. If one is available, an **open UI** button (a window glyph) appears next to its name. Click it to open the vendor's editor in a floating glass-chrome window. Built-in and sound-bank instruments have no plugin window — the instrument picker (and the synth/sampler editors) is where you shape them.

## Mixing

### The console

In the Mix view, you'll see a horizontal rack of **channel strips** (audio/instrument tracks on the left, buses in the middle, and a wider cyan-bordered **Master** on the right).

Each strip has, top to bottom:

- **Name + kind badge** (signal-green for audio, cyan for instrument).
- **Inserts** (effect chain): a row of bypass dots and effect names. Click **+** to add a built-in effect or AU effect.
- **Sends** (side-chain sends to buses): click **+** to send this track to a bus.
- **Output** (routing): Master or a bus.
- **Pan knob** (left/right balance).
- **Long-throw fader** + live meter + dB readout (volume).
- **Mute** (red, silence the track), **Solo** (cyan, hear only this track), **Arm** (amber, ready to record).

### Faders, pan, mute, solo

- **Fader**: drag vertically or double-click to reset to unity (0 dB). Hold **Option** for fine control.
- **Pan**: drag the knob left/right or double-click to center.
- **Mute**: red button — click to silence the track. A muted track's fader dims.
- **Solo**: cyan button — click to hear only this track and its feeds (useful for checking a single instrument or vocal). Multiple tracks can be soloed; click again to unsolo.

### Buses and sends

A **bus** is a mix destination (like a folder in a file browser). To group tracks:

1. In Mix view, add a bus track (like any track).
2. On an audio or instrument track, click **+** in the Sends row and pick the bus.
3. The send level appears as a mini-fader. Set it where you want.
4. The bus itself has a fader, pan, and effects on the master console strip.
5. The bus's output routes to Master by default.

**Pre/post** (on the wire): sends are post-fader by default (level follows the track fader). Wire command `track.addSend` has a `preFader` option.

### Built-in effects

Every strip (audio, instrument, or bus) has an insert chain. Click **+** in Inserts to add one of these built-in effects:

| Effect | What it does |
|---|---|
| **Gain** | Simple level boost/cut in dB. |
| **EQ** | 4-band parametric EQ — adjust bass, mids, treble, and presence. |
| **Compressor** | Reduces volume when signal gets loud, evening out dynamics. Useful for vocals and bass. |
| **Limiter** | Hard ceiling — nothing gets louder than your threshold. Protects against clipping. |
| **Reverb** | Adds space (simulates room acoustics). |
| **Delay** | Echo effect — copies of the signal at set intervals. |
| **Saturator** | Adds harmonic warmth and crunch. |
| **Gate** | Silences the signal below a threshold (reduces noise). |
| **Chorus** | Doubles the signal slightly detuned for width and thickness. |

Each effect has a **bypass dot** (signal-green = passing, dim = bypassed) and a name. Click the name to open its editor. Double-click to reset to default.

You can also host **AudioUnit effects** — any AU plug-in on your Mac (e.g., AUDelay, AUPeakLimiter). Click **+** and choose "Audio Unit" to browse your installed effects.

### Automation

An **automation lane** lets you draw volume and pan changes over time (useful for risers, fades between sections, etc.).

In Arrange, click the small **axis chart** glyph on a track header to open the automation row. You'll see:

- A **VOL/PAN** chip (pick which parameter to automate).
- A **green ON/OFF** toggle (enable/disable the lane).
- A **Canvas breakpoint editor** below — a neon curve where you click to add points, drag to move them, and double-click or delete to remove them.

The **Volume lane glows cyan** (matching the fader color). **Pan lanes are neutral white**. Points snap to the grid (same as clips). Edits are live — play back to hear them.

When a lane is disabled, the fader/knob works manually (no automation).

### Master volume & analysis

The **Master** strip on the far right shows your stereo mix. The **long fader** is the master volume (0 dB = unity, no change). The **stereo meter** shows peak and RMS for left/right channels.

A **glowing cyan orb** just left of the master is the **Session Vibe Meter** — a live read of your mix's spectral balance and energy. Warm amber = bass-heavy, cyan = bright. The shape shows where the energy is (bass bulges the bottom, treble the top). It's a quick read of your mix feel.

## Playback & Loop

### Transport controls

The **Transport bar** (top) has a large cyan **PLAY** button and a **STOP** button. Click PLAY to start rolling; click STOP to stop.

Between them, the **position readout** shows bars.beats (musical time) and SMPTE time (hours:minutes:seconds). The **tempo** (BPM) is editable inline — click it to change, then press Enter.

To the right, a **count-in** and **metronome** toggle (the click track).

### Loop region

Currently, loop region is set via the control wire (`transport.setLoop` command). The UI is coming. You can loop a region over MCP or the Copilot.

### Punch in/out

In the Transport bar, a **Punch In/Out** affordance lets you set record boundaries. When armed and recording, the audio capture starts at punch-in and stops at punch-out, trimming the take to the window.

## AI Features

### Song generation (Sketchpad)

Click the violet **SKETCHPAD** chip to open the song generator panel on the right. Here's the flow:

1. **Start the ACE-Step sidecar** (if needed): on first use, it loads models (~1 min). A status banner at the top shows progress. Once healthy, the banner disappears.
2. **Write a prompt** in the **STYLE** field — describe the song (genre, mood, instrumentation).
3. (Optional) **Write lyrics** in the **LYRICS** editor. Use the section-tag buttons to mark [verse], [chorus], [bridge], [outro] — one per line. Parentheses mark backing vocals.
4. **Set length** with the cyan stepper (15–240 seconds, default 30 s).
5. Click the violet glowing **GENERATE** button.

The song queues and generates (2–10 minutes typical on M-series Mac, depending on duration). As it runs, a progress bar and step counter show the work. Once done, click the violet **IMPORT** button — the track lands in Arrange as a violet (AI-generated) clip, and the project tempo adopts the song's BPM automatically.

### Lyrics Workshop (AI lyrics)

Inside the Sketchpad, a nested **WRITE WITH AI** section writes lyrics for you. Expand it and:

1. **Enter a theme** (what the song is about) — required.
2. (Optional) Enter a **STYLE** (genre, feel).
3. Click **WRITE** to generate a draft. The section structure auto-populates ([verse]/[chorus]/etc.).
4. Tweak the structure or refine the draft with a follow-up instruction.
5. Click **APPLY TO LYRICS** to push the final lyric into the main LYRICS editor.

Requires an API key.

### Vocal fix (AI audio editing)

Select an audio clip in Arrange and look for the violet **FIX WITH AI** chip in the header. Click it to open the fixer panel. Set the **region to fix** (beat range), describe what to fix, pick a **strength** (Subtle/Balanced/Bold), and click **FIX THIS REGION**. The AI re-records that region's vocal in a new take lane — you keep the original and can paint over it in the comp or delete it later.

### Copilot conversation

Open the Copilot rail (violet **COPILOT** chip, far right). Type a request in natural language:

- *"Add a quiet ambient pad under the second verse"*
- *"Master this for 16 dB LUFS loudness"*
- *"Tighten the drums by 10%"*

The Copilot uses the same control surface the UI uses — each step is undoable. It's a real operator, not a suggestion engine.

Requires an API key.

## Exporting

### Bounce & mixdown

In the Transport bar, an **EXPORT** button opens the save dialog. Choose:

- **Bounce/mixdown**: the whole mix rendered to a stereo WAV file. Sample rate matches the project; you can choose bit depth (16-bit, 24-bit, 32-bit float).
- **Stems**: individual track bounces (one file per track) — useful for sending to a mastering engineer or remixing.
- **Loudness check**: measure the integrated loudness (LUFS) of the mix. Streaming services have targets (Spotify ≈ −14 LUFS, YouTube ≈ −13 LUFS).

All renders are offline — the engine processes the full project at once, then writes the file(s).

## Connecting AI Agents (MCP)

If you're using the DAW with an AI agent (Claude Code, Claude Desktop, etc.), here's the setup:

### Control protocol

The DAW runs a WebSocket command server on `ws://127.0.0.1:17600` (loopback-only, local network off by design).

You can see and copy the live address in the app: open **Settings** (the gear, top-right) and find the **Agent Connection** section. It shows the exact `ws://…` URL agents connect to, with a **Copy** button, and a **Port** field to change the port without a terminal — the new port takes effect the next time you launch DAW Pro. Agents can also read the current URL/port over the wire with the `app.connectionInfo` command.

To override the port for a single session (this always wins over the in-app setting), launch the app with the environment variable:

```bash
DAW_CONTROL_PORT=9999 swift run DAWApp
```

When that variable is set, the Settings section shows an "Overridden by DAW_CONTROL_PORT for this session" note so it's clear which port is actually in effect.

### MCP server

The MCP server bridges agents to the control protocol. Set it up:

1. **Build it**: 
   ```bash
   cd mcp-server
   npm install
   npm run build
   ```

2. **Register it** in your agent configuration (e.g., Claude Desktop's `claude_desktop_config.json`):
   ```json
   {
     "tools": [
       {
         "name": "daw-pro",
         "command": "node",
         "args": ["/absolute/path/to/dist/index.js"]
       }
     ]
   }
   ```

3. **Start the app first**, then connect your agent.

The server exposes 111 tools — one for every control-protocol command. The agent sees the entire DAW state and can compose, arrange, mix, and master like a human operator.

## Troubleshooting

### Sidecar logs (ACE-Step)

If song generation fails or stalls, check the sidecar logs:

```bash
cat ~/Library/Logs/DAWPro/ace-step.log
```

### Crash recovery

After an unexpected quit, DAW Pro offers to recover the project on the next launch. Accept to restore where you left off.

### File locations

- **Projects**: `~/Music/DAW Pro Projects/` (default, or wherever you save).
- **App support**: `~/Library/Application Support/DAWPro/` (caches, recovery bundles).
- **Sidecar**: `scripts/ace-step/` in the repo, or `$DAWPRO_ACESTEP_DIR` if set.

### Feedback bundle

If you hit a bug, save a feedback bundle to help us fix it. Open **Settings** (gear icon, top-right), scroll to **Beta Feedback**, and click **Save Feedback Bundle**. Include the folder in your bug report.

The bundle includes app version, engine health, session overview (counts only, no audio), and recent crash reports. It does NOT include your project content unless you opt in — and it never includes API keys.

## Keyboard shortcuts

- **Play/Stop**: Space
- **Record**: R (toggle)
- **Undo**: ⌘Z
- **Redo**: ⇧⌘Z
- **Settings**: ⌘,
- **Explain mode**: toggle with the EXPLAIN chip, or press Esc to exit

## Next steps

- Complete the onboarding tour (7 steps, ~5 min) to get oriented.
- Record a simple vocal and add a drum track to get a feel for multitrack editing.
- Try the Copilot: *"Add a reverb to the vocal and turn it up."*
- Check the Explain mode on any control you're unsure about.

Enjoy — welcome to DAW Pro.
