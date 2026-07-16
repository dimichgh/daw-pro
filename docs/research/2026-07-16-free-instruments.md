# Research — Free-instrument content story (m17-e)

**Date:** 2026-07-16
**Roadmap item:** `docs/ROADMAP.md` — m17-e, "Free-instrument content story (user #2)".
**Deliverable:** `docs/FREE-INSTRUMENTS.md` (user-facing guide) + this verification matrix.
**Scope of this pass:** desk research (web verification + codebase grep). No AU instruments were
downloaded/installed/loaded on this machine as part of this task — that's the roadmap item's
separate GATE ("swift-app-engineer only if load bugs surface"), out of scope for a research-only
pass. The three instruments confirmed present on this machine (Kontakt 8, Reaktor 6, Splice
INSTRUMENT) were discovered read-only via `Glob`, not installed by this task.

## Verification matrix

| # | Claim | Source | Verdict |
|---|---|---|---|
| 1 | Spitfire LABS was a free instrument plugin requiring the Spitfire Audio app | [KVR product page](https://www.kvraudio.com/product/labs-by-spitfire-audio); [Spitfire install-LABS help article](https://support.spitfireaudio.com/en/articles/12034689-how-to-install-labs) | TRUE historically, but **superseded** — see #2. |
| 2 | LABS has been discontinued/folded into "Splice INSTRUMENT" as of late 2025; new free content only ships there | [Spitfire support: "What is Splice INSTRUMENT and what is happening to LABS?"](https://support.spitfireaudio.com/en/articles/12247087-what-is-splice-instrument-and-what-is-happening-to-labs); [Bedroom Producers Blog, 2025-10-03](https://bedroomproducersblog.com/2025/10/03/splice-instrument/); `labs.spitfireaudio.com` now 301-redirects to `splice.com/instrument` (observed directly via WebFetch) | **CONFIRMED, and corroborated locally**: this machine's `/Library/Audio/Plug-Ins/Components/` literally contains `Splice INSTRUMENT.component`, not a LABS-branded component (confirmed via `Glob`, not just orchestrator say-so). |
| 3 | Splice INSTRUMENT is free to download, AU/VST3/AAX, requires a (free) account/login | [splice.com/instrument](https://splice.com/instrument) (WebFetch) | Plugin + hundreds of presets free; premium preset packs need a paid Splice subscription ($12.99/mo+). Account requirement not 100% explicit on the page but a "Log in" gate is present and matches the LABS-era account requirement. **Mostly confirmed**, account requirement inferred not textually explicit. |
| 4 | Vital: free "Basic" tier, full synth engine, AU on macOS, requires free account to download | [vital.audio](https://vital.audio/) (WebFetch — pricing tiers); [account.vital.audio/signup](https://account.vital.audio/signup) (search-confirmed signup flow); KVR product page confirms AU/VST/VST3/CLAP/LV2 | CONFIRMED. |
| 5 | Surge XT: open-source, macOS install = `.dmg` containing a `.pkg` installer, needs admin password, AU/VST3/CLAP/Standalone, no account | [surge-synthesizer.github.io/downloads](https://surge-synthesizer.github.io/downloads/) (WebFetch); [make_installer.sh source](https://github.com/surge-synthesizer/surge/blob/main/scripts/installer_mac/make_installer.sh) (WebFetch — confirms `productbuild` .pkg wrapped in .dmg, installs to `/Library/Audio/Plug-Ins/...`, `rootVolumeOnly=true`) | CONFIRMED. Roadmap text said "pkg installer" loosely — more precisely it's a DMG *containing* a pkg. Noted in the guide as `.dmg` with the pkg inside. |
| 6 | Dexed: open-source DX7 emulation, GPL-3, macOS `.dmg`, AU/VST/VST3/LV2/CLAP, no account | [asb2m10.github.io/dexed](https://asb2m10.github.io/dexed/) (WebFetch — GPLv3, DMG download link); [GitHub releases](https://github.com/asb2m10/dexed) | CONFIRMED. |
| 7 | TAL-NoiseMaker: free ($0), GPL-licensed, AU/VST3/AAX/CLAP on macOS, no account, current download is a `.zip` (older versions had `.pkg`) | [tal-software.com/products/tal-noisemaker](https://tal-software.com/products/tal-noisemaker) (WebFetch — confirmed zip for current version, pkg for v4.7.0); web search cross-checks (KVR, plugins4free) confirming free/GPL | CONFIRMED. |
| 8 | Decent Sampler: free, VST/VST3/AU/AAX/Standalone on macOS, email address required (not account/login) to reach the download link | [decentsamples.com/product/decent-sampler-plugin](https://www.decentsamples.com/product/decent-sampler-plugin/) (WebFetch — "FREE / $0", "just enter your email address!") | CONFIRMED. |
| 9 | sforzando (Plogue): free SFZ 2.0 player, AU/VST3/CLAP on macOS (no AAX on Mac), no account required, can auto-convert `.sf2`/`.dls`/acidized-wav to SFZ | [plogue.com/products/sforzando.html](https://www.plogue.com/products/sforzando.html) (WebFetch) | CONFIRMED. |
| 10 | Native Instruments Komplete Start: free bundle, requires free Native ID account + the Native Access 2 app to install, ships AU/VST3/AAX, includes Kontakt 8 Player + named content packs | [native-instruments.com Komplete Start](https://www.native-instruments.com/en/products/komplete/bundles/komplete-start/); [Get Komplete Start](https://www.native-instruments.com/en/products/komplete/bundles/komplete-start/get-komplete-start/) | CONFIRMED. Content list (Hypha, Ethereal Earth, Irish Harp, Yangqin, Massive X Player, etc.) cross-checked across two NI pages, consistent. |
| 11 | Odin 2: free, open-source (GPL-3), AU/VST3/CLAP/LV2 on macOS, commercial use of compiled binary needs no royalty/attribution, no account | [thewavewarden.com/pages/odin-2](https://thewavewarden.com/pages/odin-2) (search-quoted license text); [GitHub](https://github.com/TheWaveWarden/odin2); KVR product page | CONFIRMED. |
| 12 | OB-Xd: free, actively maintained (Dec 2025 release cited), AU/VST/VST3/AAX/LV2/Standalone on macOS, no account, no restrictions incl. commercial use | [discodsp.com/obxd](https://www.discodsp.com/obxd/); [GitHub — reales/OB-Xd](https://github.com/reales/OB-Xd) | CONFIRMED via search snippets; **not independently WebFetched** — flagged as slightly lower-confidence than the WebFetch-verified rows. Recommend a direct WebFetch of discodsp.com/obxd before treating exact "no restrictions" wording as verbatim. |
| 13 | BBC Symphony Orchestra Discover: free (was previously paid-tier-gated), 34 instruments, ~240 MB, AU/VST/AAX on macOS, same Spitfire/Splice account gate as #2/#3 | [spitfireaudio.com/.../bbc-symphony-orchestra-discover](https://www.spitfireaudio.com/en-us/products/bbc-symphony-orchestra-discover); [MusicRadar](https://www.musicradar.com/news/spitfire-audio-free-bbc-symphony-orchestra); [Bedroom Producers Blog](https://bedroomproducersblog.com/2022/07/22/bbc-symphony-orchestra-free/) | CONFIRMED (search-snippet corroborated across 3 independent outlets); page itself not directly WebFetched. |
| 14 | Logic Pro / GarageBand's built-in instruments (Alchemy, Sculpture, ES2, etc.) are app-internal, not distributed as standalone AUs, cannot be hosted by other DAWs | Search-corroborated: Apple's acquisition of Camel Audio (Alchemy's maker) ended Alchemy's life as a cross-DAW plugin (multiple outlets, incl. [CDM](https://cdm.link/2015/08/deep-alchemy-synth-now-part-logic-pro-x-heres-whats-new/) coverage of the Logic-exclusive integration) | **CONFIRMED BY INFERENCE, NOT BY AN APPLE PRIMARY SOURCE.** Apple does not publish a document stating "Alchemy/Sculpture/ES2 are not AUs." The claim is standard, uncontested community knowledge (no discovered source disputes it; nobody has ever reported hosting Alchemy/Sculpture/ES2 in a third-party AU host), and is trivially checkable by any reader — searching `/Library/Audio/Plug-Ins/Components` and `~/Library/Audio/Plug-Ins/Components` after installing Logic never turns up Alchemy/Sculpture/ES2 components. Treat as high-confidence but explicitly not Apple-primary-sourced. |
| 15 | Apple's *system-level* AUs (AUSampler, DLSMusicDevice) are hostable by any AU host, unlike Logic-internal instruments | [Apple Support: "Where are third-party Audio Units plug-ins installed on Mac?"](https://support.apple.com/en-us/102239); DAW Pro's own codebase already hosts both (see code citations below) | CONFIRMED — and DAW Pro is itself living proof: `Sources/DAWCore/SoundBanks.swift:140` references `/System/Library/Components/CoreAudio.component/.../gs_instruments.dls`, played back through AUSampler, and DAW Pro's `instrument.listAudioUnits` command (`Sources/DAWControl/Commands.swift:744`) enumerates all installed `'aumu'` components including `DLSMusicDevice`/`AUSampler` per `docs/FEATURES.md:62`. |
| 16 | AU components live in `/Library/Audio/Plug-Ins/Components` (system) and `~/Library/Audio/Plug-Ins/Components` (user) | [Apple Support 102239](https://support.apple.com/en-us/102239) | CONFIRMED, and directly verified on this machine via `Glob` (not just web search): system folder has `Kontakt 8.component`, `Reaktor 6.component`, `Splice INSTRUMENT.component`; user folder is empty. |
| 17 | DAW Pro discovers AUs via `AVAudioUnitComponentManager.shared()` (standard Apple API, scans both component folders + AUv3 extensions) | Code: `Sources/DAWEngine/AudioUnits/AUHostRegistry.swift:88,112,291,436` (grep-confirmed `AVAudioUnitComponentManager.shared()` call sites) | CONFIRMED by direct code read, not web search — this is an internal architecture fact, not an external claim. |
| 18 | DAW Pro ships PolySynth (16-voice subtractive), a built-in key-zone Sampler, AU instrument hosting, and SF2/DLS sound-bank import (incl. a zero-setup system GM bank) | `docs/FEATURES.md:60-63`; `Sources/DAWCore/Model.swift:1226-1241` (`InstrumentDescriptor.Kind`: `polySynth`, `sampler`, `audioUnit`, `soundBank`); `Sources/DAWCore/SoundBanks.swift` (whole file — `SoundBankSource`, `SoundBankConfig`, `SoundBankLibrary`); `Sources/DAWControl/Commands.swift:171-174,744,761,769,783` (`instrument.listAudioUnits`/`listSoundBanks`/`listSoundBankPrograms`/`importSoundBank`) | CONFIRMED by direct code grep, cross-checked against `docs/FEATURES.md`. Note: `docs/FEATURES.md:64` still says "MIDI CC ... not yet shipped," which per the orchestrator's own memory is now STALE (MIDI CC shipped m16-b1–b4) — flagged for whoever next touches FEATURES.md (m17-g docs fold-in), not corrected here since this task's scope excludes editing other docs. |
| 19 | DAW Pro's sound-bank library: import copies to `~/Library/Application Support/DAWPro/SoundBanks/`; reference-in-place scan of `/Library/Audio/Sounds/Banks` and `~/Library/Audio/Sounds/Banks`; system GM bank is the `gs_instruments.dls` sentinel | `Sources/DAWCore/SoundBanks.swift:139-169` (direct read) | CONFIRMED by direct code read — this is the *implementation*, not just the m10-n design doc (`docs/research/design-m10n-instrument-library.md`), which was cross-checked and matches exactly. |
| 20 | VST3 hosting is NOT NOW because every marquee free AU instrument checked here ships an AU build on macOS | Rows 1–13 above, all AU-confirmed | CONFIRMED — every single instrument verified for this guide ships an AU build on macOS; no VST3-only free instrument was found in this pass. |

## Claims NOT independently verified (flagged explicitly)

- **Row 12 (OB-Xd)** and **row 13 (BBC SO Discover)**: corroborated only via WebSearch snippets
  from multiple independent outlets, not a direct WebFetch of the primary vendor page. High
  confidence (multiple independent sources agree, no contradictions found) but lower rigor than
  the WebFetch-verified rows. Recommend a follow-up WebFetch pass if these become load-bearing for
  anything beyond a documentation link.
- **Row 3 (Splice INSTRUMENT account requirement)**: the fetched page text implies but does not
  explicitly state that an account is mandatory before download (a "Log in" link is present, and
  the predecessor LABS product definitively required a Spitfire Audio account). Treated as
  effectively-confirmed by product-family precedent, not page-text-verbatim.
- **Apple's Logic-instruments-are-app-internal claim (row 14)** has no Apple primary source — Apple
  does not publish plugin-architecture internals for its own apps. This is standard, uncontested
  community/practitioner knowledge (verified across multiple independent discussion threads and
  press coverage of the Camel Audio acquisition), and is independently falsifiable by any reader
  (check the AU component folders after installing Logic — Alchemy/Sculpture/ES2 never appear).
  Flagged here so the caller can decide whether that confidence level is sufficient for a
  user-facing doc; the guide phrases the claim in a way that doesn't overclaim an Apple citation.
- No AU instrument was actually downloaded, installed, or loaded into DAW Pro's host during this
  research pass — the roadmap item's "≥2 real third-party free AU instruments verified sounding"
  GATE is explicitly a separate, later step (swift-app-engineer / qa-test-engineer territory per
  the roadmap's own routing), not something a research-only pass should attempt.

## Surprising findings

1. **Spitfire LABS, as named in the roadmap item and in common usage, is functionally
   discontinued.** It was folded into "Splice INSTRUMENT" in late 2025 — new free content only
   ships through the new product. This is not a hypothetical future risk; it's already reflected on
   *this development machine*, whose `/Library/Audio/Plug-Ins/Components/` holds a component
   literally named `Splice INSTRUMENT.component`, not anything LABS-branded. `docs/FREE-INSTRUMENTS.md`
   leads with "Splice INSTRUMENT (formerly Spitfire LABS)" rather than "Spitfire LABS" for this
   reason — a guide written under the old name would send a reader to a dead URL
   (`labs.spitfireaudio.com` now 301-redirects to `splice.com/instrument`).
2. Surge XT's macOS distribution is a `.dmg` *containing* a `.pkg` installer that writes to
   `/Library/Audio/Plug-Ins/...` with `rootVolumeOnly=true` (confirmed by reading the project's own
   `make_installer.sh`) — i.e. it does need the admin password, contrary to a casual assumption that
   open-source plugins are always drag-and-drop.
3. DAW Pro's own instrument stack is a strong illustration of the "Logic instruments are
   app-internal, Apple system AUs are shareable" distinction it needs to explain to users: DAW Pro's
   built-in sound-bank feature *is* built on the same system-level `DLSMusicDevice`/AUSampler +
   `gs_instruments.dls` GM bank that ships with every Mac — the exact kind of AU Logic's own
   internal instruments are not.

## Actionable takeaways

- **Ship `docs/FREE-INSTRUMENTS.md` as-is** (this pass's deliverable) — it reflects the
  Splice-INSTRUMENT rename, the verified install/account/gotcha matrix, and accurate DAW-Pro-side
  facts pulled from code, not just `docs/FEATURES.md` prose.
- **Roadmap/FEATURES.md housekeeping (route to docs-scribe at m17-g, not this task):**
  `docs/FEATURES.md:64` still reads "MIDI CC ... Not yet" — stale since m16-b1–b4 shipped MIDI CC.
  Not touched here (out of scope for a research-only pass; docs-scribe already owns m17-g doc
  fold-ins) but flagged so it isn't missed.
- **Roadmap m17-e wording nit:** the item text says Surge XT ships a "pkg installer" — more
  precisely it's a `.dmg` containing a `.pkg`. Cosmetic; doesn't change the gate.
- **No code/architecture changes indicated.** DAW Pro's existing AU-hosting + SF2/DLS sound-bank
  pipeline already covers everything this research turned up; nothing here suggests a gap in
  `instrument.listAudioUnits`/`instrument.listSoundBanks`/`track.setInstrument`. The one forward
  candidate is the already-filed SFZ/DecentSampler-format import spike (appendix of the guide) —
  intentionally left as a filed spike, not scoped work, per the roadmap item's own instruction to
  "file (don't build)."
- **Next step per the roadmap gate** ("≥2 real third-party free AU instruments verified sounding
  via `instrument.listAudioUnits` → `track.setInstrument` → offline render RMS above silence") is
  an install-and-load verification pass, which needs a hands-on agent (swift-app-engineer per the
  roadmap's own routing) — not attempted here by design.
