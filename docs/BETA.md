# DAW Pro — Beta Guide

Welcome to the DAW Pro beta. This page tells you how to install the app, what to
expect on first launch, the rough edges we already know about, and how to send a
bug report that we can actually act on.

Everything here is **local**. DAW Pro does not phone home, and the feedback bundle
you send us contains only what you choose to share (details below).

## Install

The beta ships as a disk image built by `scripts/dmg.sh` (see
[PACKAGING.md](PACKAGING.md)):

1. Open `DAWPro-<version>.dmg`.
2. Drag **DAW Pro** onto the **Applications** shortcut in the same window.
3. Launch it from Applications (or Spotlight).

### First launch on another Mac (Gatekeeper)

The beta build is **ad-hoc signed** — Developer ID signing and notarization are
not available on the build machine yet (tracked as pkg-b / pkg-c). On the Mac that
built it, the app opens with no friction. On **any other Mac**, Gatekeeper will
refuse a plain double-click. To get past it the first time:

- **Right-click** (or Control-click) the app → **Open** → confirm **Open** in the
  dialog. macOS remembers the choice, so later launches are a normal double-click.
- Or, from a terminal: `xattr -dr com.apple.quarantine "/Applications/DAW Pro.app"`.

This prompt goes away once the build is notarized.

## First-launch notes

- **A fresh preferences domain.** The bundled app uses the bundle id
  `dev.dawpro.app` for its settings (window density, onboarding, recovery). If you
  previously ran a raw development build, those preferences do **not** carry over —
  a bundled first launch may show the onboarding tour (and, after an unclean
  shutdown, a recovery offer) that a long-time dev-build user would not.
- **Microphone permission.** The first time you record an audio track, macOS asks
  for microphone access — that is expected and required for input recording. MIDI
  and instrument tracks do not need it.
- **AI song generation (ACE-Step sidecar).** Full-song / sung-vocal generation
  runs a **local** ACE-Step sidecar. An installed copy of the app (dragged to
  `/Applications`) needs the environment variable `DAWPRO_ACESTEP_DIR` pointed at
  the sidecar directory (`scripts/ace-step`); without it, generation reports
  "not installed". A build run from inside the source checkout finds the sidecar
  automatically. See [PACKAGING.md](PACKAGING.md) for the details.

## Known gaps

These are deliberate, labeled gaps for this beta — please don't file them as bugs:

- **No app icon.** The UI-asset pipeline is credential-blocked, so the app ships
  without a custom icon (you'll see the generic bundle icon).
- **Some AI text features are key-gated.** Lyric writing, naming, and
  music-theory reasoning use Anthropic / OpenAI. Without a key configured
  (Settings → API Keys, or an environment variable), those specific features are
  unavailable; everything else — recording, editing, mixing, mastering, and local
  ACE-Step generation — works without any key.
- **No auto-update.** The beta does not self-update; we'll share new DMGs
  directly.

## How to report a bug

When something goes wrong — a crash, an audio dropout, wrong behavior, anything —
please **save a feedback bundle** and attach it to your report. It's a small local
folder with exactly the facts we need to reproduce and fix the problem.

**In the app:**

1. Open **Settings** (the gear in the top-right, or ⌘,).
2. Scroll to the **Beta Feedback** row at the bottom.
3. Click **Save Feedback Bundle**. Finder opens with the new
   `feedback-<timestamp>` folder selected.
4. Attach that **folder** to your bug report (zip it if your reporting tool
   needs a single file), and describe what you were doing when it happened.

**Over MCP (for AI agents):** call the `app_feedback_bundle` tool. It returns the
folder path to attach. Pass `includeProject: true` only with the user's consent
(see privacy below).

### What's in the bundle

- `manifest.json` — app version, build, macOS version, and Mac model. **No keys,
  no secrets.**
- `engine.json` — the audio engine's health: watchdog state (did it stall or
  self-heal?) and a render-load snapshot. This is what makes a "the audio glitched"
  report actionable.
- `overview.json` — a **counts-only** summary of your session: how many
  tracks / clips / effects and their ids. **No note content, no lyrics, no file
  paths.**
- `crashes/` — copies of your recent DAW Pro crash reports (last 14 days, newest
  10), if any.
- `project.dawproject/` — your **full project**, included **only** if you turned on
  the include-project toggle.

## Privacy

- Everything stays **on your Mac**. The feedback bundle is written to a local
  folder and is **never transmitted anywhere** by the app — you decide when and
  where to send it.
- By default the bundle is **privacy-lean**: it shares the counts-only overview,
  never your actual notes, lyrics, or audio-file paths.
- The **Include Project** toggle (off by default) opts into sharing your full
  project content — every track, clip, MIDI note, and the paths to your audio
  files. Only turn it on if you're comfortable sharing your work, and it helps us
  reproduce the problem.
- No API keys or other secrets are ever written into the bundle.
