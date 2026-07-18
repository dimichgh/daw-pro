# Free instruments for DAW Pro

DAW Pro hosts **Audio Units (AU)** — the macOS-native plugin format. It does not host VST/VST3
(see the appendix below). The good news: nearly every worthwhile free instrument on macOS ships
an AU build, so you're not missing much by skipping VST.

This guide covers where to get free AU instruments, what DAW Pro already ships without any
download, and how to check what's on your Mac right now.

## Where to get free AU instruments

All entries below were verified July 2026. "Account" means you must sign up somewhere to get the
download link; "admin password" means the installer writes into `/Library` and macOS will prompt
for it.

| Instrument | What it is | Get it | Install | Gotchas |
|---|---|---|---|---|
| **Splice INSTRUMENT** (formerly Spitfire LABS) | Free orchestral/cinematic sample player with rotating monthly "Free Drops" presets | [splice.com/instrument](https://splice.com/instrument) | Free Spitfire/Splice account, then a downloader app installs the plugin (AU/VST3/AAX) | LABS was discontinued and folded into this product in late 2025 — searching for "Spitfire LABS" now lands you here. The legacy LABS plugin still runs but gets no new free content. |
| **Vital** | Free wavetable synth, full feature set in the free tier (fewer presets than Pro) | [vital.audio](https://vital.audio/) | Free `account.vital.audio` signup required, then installer (VST/VST3/AU) | Account gate; otherwise no restrictions on the free "Basic" tier's synth engine. |
| **Surge XT** | Open-source hybrid subtractive/wavetable synth (successor to the commercial Vember Audio Surge) | [surge-synthesizer.github.io/downloads](https://surge-synthesizer.github.io/downloads/) | `.dmg` containing a signed `.pkg` installer (Standalone/AU/CLAP/VST3); needs your admin password for the system-wide install | No account. GPL-3 licensed, source on GitHub. |
| **Dexed** | Open-source Yamaha DX7 FM synth emulation, loads original DX7 SysEx patches | [asb2m10.github.io/dexed](https://asb2m10.github.io/dexed/) / [GitHub releases](https://github.com/asb2m10/dexed) | `.dmg` containing a `.pkg` installer (like Surge XT); needs your admin password for the system-wide install | No account. GPL-3 licensed. |
| **TAL-NoiseMaker** | Free 3-oscillator virtual analog synth from TAL Software | [tal-software.com/products/tal-noisemaker](https://tal-software.com/products/tal-noisemaker) | `.zip` (current) or `.pkg` (older versions) | No account. GPL-licensed and genuinely $0, not crippled donationware. |
| **Decent Sampler** | Free sample player for the open `.dspreset`/`.dslibrary` format, plus built-in oscillators | [decentsamples.com/product/decent-sampler-plugin](https://www.decentsamples.com/product/decent-sampler-plugin/) | Installer (VST/VST3/AU/AAX) | Gated behind an email address (not a full account/login) before the download link appears. |
| **sforzando** | Free SFZ 2.0 player from Plogue, the reference way to play SFZ-format sample libraries | [plogue.com/products/sforzando](https://www.plogue.com/products/sforzando.html) | Installer (Standalone/AU/VST3/CLAP; no AAX on macOS) | No account. Can also load raw `.sf2`/`.dls`/acidized `.wav` by drag-and-drop, auto-converting to SFZ. |
| **Komplete Start** | Native Instruments' free bundle: Kontakt 8 Player + sample libraries (Hypha, Ethereal Earth, Irish Harp, etc.), Massive X Player, effects | [native-instruments.com/.../komplete-start](https://www.native-instruments.com/en/products/komplete/bundles/komplete-start/) | Requires a free Native ID account **and** the Native Access 2 app, which then installs everything (AU/VST3/AAX) | Heaviest install on this list (content packs run into GBs) and the only one gated by a separate installer app rather than a direct download. |
| **Odin 2** | Free, open-source semi-modular synth (3 oscillators, 12 types incl. wavetable/FM, modular matrix) from TheWaveWarden | [thewavewarden.com/pages/odin-2](https://thewavewarden.com/pages/odin-2) | Installer (VST3/AU/CLAP/LV2) | No account. GPL-3; compiled binaries are free for commercial use with no attribution required. |
| **OB-Xd** | Free Oberheim OB-X/OB-Xa/OB-8-inspired analog synth emulation from discoDSP, actively maintained since 2014 | [discodsp.com/obxd](https://www.discodsp.com/obxd/) | Installer (AU/VST/VST3/Standalone) | No account, no restrictions. |
| **BBC Symphony Orchestra Discover** | Free, lightweight (~240 MB) orchestral library — 34 instruments recorded at Maida Vale by Spitfire Audio | [spitfireaudio.com/.../bbc-symphony-orchestra-discover](https://www.spitfireaudio.com/en-us/products/bbc-symphony-orchestra-discover) | Same Spitfire/Splice downloader as Splice INSTRUMENT above | Free Spitfire account. A genuinely different product from Splice INSTRUMENT/LABS — a scaled-down BBC SO, not a LABS pack. |

## "Can I get the instruments from Logic Pro / GarageBand?"

No — and this trips people up, so here's the honest answer. Logic Pro and GarageBand's signature
instruments (**Alchemy, Sculpture, ES2, EFM1, ES1, Drummer/Drum Machine Designer**, and friends)
are **built into the Logic app itself**. They are not packaged as standalone Audio Units and don't
appear in `/Library/Audio/Plug-Ins/Components` — no other host, including DAW Pro, can load them.
This has been true since Apple acquired Camel Audio (Alchemy's original maker) and folded it into
Logic exclusively — it never shipped again as a cross-DAW plugin.

What *is* shareable are Apple's **system-level** Audio Units, which live outside any single app and
get installed with macOS itself or Logic's content installer: **AUSampler** (a general-purpose
sample player) and **DLSMusicDevice** (plays General MIDI `.dls`/`.sf2` banks — the same General
MIDI system bank DAW Pro uses out of the box, see below). DAW Pro already hosts both. Everything
past that — the actual instrument *engines* in Logic — stays inside Logic.

## What DAW Pro ships built-in

No download required for any of this:

- **PolySynth** — a 16-voice subtractive synth (saw/square/triangle/sine oscillators, a
  state-variable low-pass filter, ADSR envelope).
- **Sampler** — DAW Pro's own key-zone sample player: map audio files across the keyboard with
  key-span, pitch offset, and gain per zone; one-shot or looped playback. Zone audio is bundled
  into the `.dawproj` file.
- **Sample-library import** — imports `.sfz` (documented subset) and `.dspreset` sample-library
  files straight onto the built-in Sampler: key/velocity zones, layering groups, round-robins,
  per-zone tuning/pan/envelope, all defined by the library author — no manual mapping. This
  unlocks the big free community libraries (Salamander Grand Piano, VSCO2 Community Edition,
  Virtual Playing Orchestra, Karoryfer, and similar) natively, with no plugin in the chain.
  Import via the Instrument Picker's "Import Sample Library…" button or the
  `instrument.importSampleLibrary` command; every import returns an honest report of anything
  skipped or ignored. The exact supported/reported/ignored boundary for both formats is
  documented in [SFZ-SUPPORT.md](SFZ-SUPPORT.md). (`.dslibrary` is a zip — unzip it and import
  the `.dspreset` inside.)
- **Sound-bank import** — load any `.sf2` (SoundFont2) or `.dls` file as an instrument, played back
  through the system AUSampler. DAW Pro also ships a **zero-setup General MIDI bank** (macOS's own
  `gs_instruments.dls`) so every project has usable instruments with no download at all. Import a
  bank via the instrument picker or the `instrument.importSoundBank` command; DAW Pro also scans
  the two standard macOS bank folders (`/Library/Audio/Sounds/Banks` and
  `~/Library/Audio/Sounds/Banks`) automatically.
- **Audio Unit hosting** — any third-party AU instrument you install (everything in the table
  above) shows up automatically and hosts like a first-class citizen, with full plugin-UI windows
  and state saved in your project file.

## Worked example: checking what you have

Two folders hold AU components on any Mac: the **system** one, shared by every user account, and
the **user** one, just for you.

```
/Library/Audio/Plug-Ins/Components        ← system-wide (needs admin to install into)
~/Library/Audio/Plug-Ins/Components       ← just your user account
```

On this development machine, a check of both folders found:

- `/Library/Audio/Plug-Ins/Components/` — `Kontakt 8.component`, `Reaktor 6.component`,
  `Splice INSTRUMENT.component` (three system-wide installs; note it's genuinely named "Splice
  INSTRUMENT" now, not "Spitfire LABS" — see the table above)
- `~/Library/Audio/Plug-Ins/Components/` — `Surge XT.component`, `Dexed.component` (installed
  user-level while verifying this guide: a `.pkg` can be expanded with `pkgutil --expand-full`
  and its `.component` payload copied here — no admin password needed; Surge XT also wants its
  resources copied to `~/Library/Application Support/Surge XT`)

All five were verified against DAW Pro's actual host chain (July 2026): **Surge XT and Dexed
load and make sound immediately** — their default patches rendered at −19 and −23 LUFS through
`track.setInstrument` → MIDI clip → offline render. **Kontakt 8, Reaktor 6, and Splice
INSTRUMENT load and validate cleanly but render silence out of the box** — they're shell
instruments that stay quiet until you load a library, ensemble, or preset (and Splice INSTRUMENT
needs its account login first). That's expected behavior, not a hosting bug.

DAW Pro discovers everything in both folders the same way: over the control protocol via
`instrument.listAudioUnits` (the `instrument_list_audio_units` MCP tool for AI agents), or in-app
through the **Instrument Picker**'s "Audio Units" section (click a track's instrument slot). You
don't need to know which folder something lives in — DAW Pro asks macOS for the full list and
shows it either way. If you just installed something and don't see it, quit and relaunch DAW Pro
(AU discovery happens at launch).

## Appendix: VST3 hosting — not now

VST3 hosting is not on the roadmap. It would mean building and maintaining a second plugin-hosting
stack alongside AudioUnit, plus taking on the Steinberg VST3 SDK's licensing terms — for very
little practical gain, since every marquee free instrument checked for this guide (LABS/Splice
INSTRUMENT, Vital, Surge XT, Dexed, TAL-NoiseMaker, Decent Sampler, sforzando, Komplete Start, Odin
2, OB-Xd) ships an AU build on macOS. We'd revisit this only if a genuinely must-have plugin turned
out to be VST3-only on macOS with no AU equivalent.

## Appendix: SFZ / `.dspreset` import — SHIPPED (was: filed follow-up spike)

This appendix originally filed native sample-library import as a spike candidate. The spike ran,
the design said GO, and the importer now ships: DAW Pro's built-in Sampler **imports `.sfz`
(documented subset) and `.dspreset` sample-library files natively** — zones, velocity layers,
layering groups, round-robins, and per-zone playback scalars, with every degradation reported
honestly (see the "Sample-library import" bullet above and [SFZ-SUPPORT.md](SFZ-SUPPORT.md) for
the exact boundary). Sustain loops are the one deferred playback feature (imported without
looping, noted in the report). sforzando / Decent Sampler above remain the full-format AU route
for content outside the documented subset.
