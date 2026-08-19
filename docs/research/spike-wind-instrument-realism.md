# Spike: wind-instrument realism — why the GM tenor sax reads as keyboard-entered

**Date:** 2026-08-18
**Author:** research-analyst
**Trigger:** field report — a jazz-ballad instrumental generated through our MCP surface. Across 225 tenor-sax notes, every note either abutted the next exactly or left a gap; not one overlapped. The part "comes out discrete instead of continuous flow."
**Method:** web research on wind/bowed sequencing practice (cited below, dated) + direct reading of DAW Pro's own engine source (`Sources/DAWEngine`, `Sources/DAWCore`) to establish what our signal path actually does today, not what the task's framing assumed it does. The second half turned out to be the load-bearing one — see §0.

---

## 0. Executive summary — the premise needs a correction first

The task described the instrument as "a General MIDI sound bank... [that] exposes NO parameter surface at all — no amplitude envelope, no filter — so there is nothing on the patch side to soften an attack." **Half of that is right and half is wrong, and the wrong half changes the whole plan.**

Right: `SoundBankConfig` (`Sources/DAWCore/SoundBanks.swift:47-98`) carries only `source`/`program`/`bankMSB`/`bankLSB`/`displayName` — no ADSR, no filter cutoff, nothing a UI panel could expose. That part of the complaint is accurate and there is no fix for it short of a better instrument (§4).

Wrong: DAW Pro does **not** play GM sound-bank tracks through some minimal built-in synth with no performance-control surface. It plays them through Apple's real **AUSampler** Audio Unit, hosted exactly like a third-party plugin (`AUHostRegistry.swift:62-99`, `.soundBank` synthesizes an `AUSampler` component and loads the SF2/DLS program into it — verified by reading the code, not inferred). Hosted AUs on this engine receive **every** scheduled MIDI event — note on/off, any numbered CC, full 14-bit pitch bend, channel pressure — forwarded byte-for-byte via `scheduleMIDIEventBlock` (`HostedAUInstrument.swift:188-221`, "Unknown future kinds emit nothing" is the only exclusion, and CC/bend/pressure are not unknown kinds). This is not a proposal — it shipped: `docs/ROADMAP.md` m16-b1 through m16-b4 are all `[x]` (model + schedule playback + live thru/capture + piano-roll CC strip), and the MCP tool `clip_set_controller_lane` already exists, already documented with "expression" as a named example (`mcp-server/src/server.ts:3999-4066`).

**So the honest framing is:** DAW Pro already has a full performance-control wire — CC11, CC1, CC2, pitch bend, all clip-relative, all reachable today by both a human (piano-roll CC strip) and an agent (`clip_set_controller_lane`) — running all the way into a spec-conformant sampler engine. Nothing in this chain needs new engine code for the four items the task asked about (overlap, gate, expression, vibrato/bend). **The entire gap is that whatever generates the sax part never calls any of it.** That reframes this from "what can we fix on a paramater-less instrument" to "what should the generation layer actually author, given tools that already work."

One caveat carried through the rest of this doc: whether the *specific* stock macOS GM bank's tenor-sax patch (`gs_instruments.dls`) has its own modulator data that makes CC1 audibly produce vibrato is **unverified** — SoundFont/DLS-conformant engines are supposed to honor a spec-mandated default CC1→vibrato-depth connection even absent patch-authored modulators (§2.3), but I did not render-test this bank. That is one of two items in this report I could not confirm from source (the other being pitch-bend range on the AUSampler path, §2.4) and flag as needing an actual audio check before anyone hard-codes numbers into a generation prompt.

### Ranked root causes of "discrete, not played"

| # | Cause | Evidence | Fix tier |
|---|---|---|---|
| 1 | **Zero overlap, inconsistent gaps** — every note-on triggers a brand-new sampler voice with a fresh attack, on both our custom sampler and AUSampler (there is no "legato hold" mode anywhere in this engine, verified §3.1). Abutment = a fresh attack transient on every note (audible re-tonguing); a gap = audible silence. | Field report (225/225 notes) + `SamplerInstrument.swift:686-727` (`trigger()` fires unconditionally per note-on) | **Tier 0** — pure note-authoring, ships today |
| 2 | **No CC11/CC2 dynamic contour at all** — flat, un-shaped loudness on every note. If a future pass DOES author CC11 without knowing it defaults to 127, any lane that peaks below 127 is a *cut*, not a shape (confirmed in our own model: `Model.swift:294-305`, `case 11: return 127 // expression (full)`) | `clip_set_controller_lane` exists, unused for generated wind parts | **Tier 0** |
| 3 | **No CC1 vibrato, no pitch-bend gestures** (scoops/falls/doits) — the sax has zero of the pitch motion that signals a human embouchure | Same tool, unused; bend already wired end-to-end (fixed ±2 st on the custom sampler; range unverified but unconfigured on AUSampler — see §2.4) | **Tier 0**, with one headroom caveat (§2.4/§6) |
| 4 | **No tongued/slurred distinction, no breath rests** — a real player's phrase has texture (some attacks harder, some notes blend); this part has neither | Pure MIDI-authoring gap, nothing engine-side blocks it | **Tier 0** |
| 5 | **Instrument quality itself** — GM DLS bank sax is a decades-old, generically-authored patch (single/few samples per octave, pitch-shifted across range, no velocity crossfade, unverified modulator depth) | Forum consensus (§3), architecture confirms no per-patch shaping exists to add on top even if we wanted to | **Tier 2** — needs a better sample source, not just better MIDI |

Sections 1-2 are the practitioner research (what real playing looks like, numerically, where numbers exist). Section 3 is the DAW Pro-specific "what's actually broken and where" analysis. Section 4 surveys better instruments. Section 5 surveys how other tools automate this. Section 6 is the recommended parameter table. Section 7 is the actionable takeaways.

---

## 1. How wind and bowed instruments are actually sequenced

### 1.1 Note overlap — and why the "right" number depends on what's listening

Two entirely different mechanisms get called "overlap," and conflating them is the single biggest way to get bad advice here:

- **Scripted true-legato instruments** (Sample Modeling/SWAM, EastWest Play legato patches, Cinesax-class libraries) use overlap (or a short *gap*, both work) purely as a **trigger signal** to a script that then plays a *recorded interval transition sample* or a *portamento algorithm* — the overlap amount barely matters once past a minimum, because the actual glide is scripted, not rendered from the overlap itself. On the Sample Modeling forum a developer states overlap-duration effects are secondary to **overlapped-note velocity and CC26** (their legato-speed CC), with realized legato/portamento time ranging **30 ms to over 1 second** depending on that CC, not the overlap ms ([Samplemodeling forum, "Legato Settings"](https://vanilla.samplemodeling.com/discussion/39711/legato-settings)). Separately, VI-Control practitioners report **legato triggers on any gap under roughly 8-10 ms**, and that some scripting frameworks (SIPS) need only "a few ms" of overlap to fire ([VI-Control, "Duration of overlap to trigger Legato"](https://vi-control.net/community/threads/duration-of-overlap-to-trigger-legato.31460/)).
- **A plain multi-sampled patch with no legato script — which is exactly what both DAW Pro's custom sampler and AUSampler are for a GM/SFZ track** — has no such trigger. Overlap there does one thing only: **two voices sound simultaneously** (a literal transient dyad), because every note-on always spawns a fresh voice with a fresh envelope (confirmed by reading `SamplerInstrument.swift:686-727`: `trigger()` unconditionally starts a new voice on every matching note-on; AUSampler behaves identically per General MIDI/SF2 semantics — there is no "steal and glide" mode in either). **This is the exact case the task asked about, and the answer is derived from our own architecture, not a practitioner convention**: keep the overlap *short* — just long enough that the new note's attack transient is masked under the departing note's decaying tail, not so long that it reads as two saxophones. At the ballad-genre default tempo (72 BPM, per `mcp-server/src/server.ts:5269`), a beat is 833 ms; **~20-40 ms ≈ 0.024-0.048 beats** is a reasonable starting point — short enough to stay inaudible as a dyad, long enough to blur the retrigger. This figure is **derived from the engine's own voice-allocation behavior**, not sourced from a practitioner citation — flagged accordingly, and it is the single number in this report most worth confirming with an actual listen test (see the CC1 test note in §2.3 — the same render can carry both checks).

Sound on Sound's orchestral-sampling series confirms the overlap-for-legato-triggering pattern generally (deliberately overlapped notes to fire correct interval transitions) without giving a millisecond figure ([Sound on Sound, "The Sampled Orchestra: Part 3"](https://www.soundonsound.com/techniques/sampled-orchestra-part3)).

### 1.2 Note-length / gate conventions

There is no single music-theory standard here — these are **sequencer-tool defaults**, and I name the tool each time rather than presenting them as universal:

- A commonly cited calculator convention (CMUSE's "Note Length Percent Calculator"): **Staccato 25%, Half-gate 50%, Tight 80%, Full 100%, Legato 105-110%** — above 100% the note overlaps into the next ([CMUSE](https://www.cmuse.org/note-length-percent-calculator)).
- Ableton's own Live 12 manual documents the *behavior*, not a percentage: **Legato** extends every selected note to the start of the next; **Tenuto** preserves original length; **Staccato** derives a new (short) length from the smallest gap between successive note starts, halved ([Ableton Live 12 manual, MIDI Tools](https://www.ableton.com/en/live-manual/12/midi-tools/)) — deliberately qualitative, no fixed percentage.
- Logic Pro's "Force Legato" piano-roll command extends each note to the start of the next, matching the same idea ([Apple Support](https://support.apple.com/guide/logicpro-ipad/force-legato-lpip9af3c9f9/ipados)).

**Marcato/tenuto figures found (~75-95%) come from generic MIDI-articulation explainer pages, not a named authoritative source — treat as folklore, not convention.**

### 1.3 Tonguing vs. slurring — sources disagree, don't average

- One instructional source states the rule plainly: *"every jazz musician will tongue the upbeats while slurring the downbeats,"* with two hard exceptions — **always tongue the first note of a phrase, always tongue the last** ([The Woodshed, "Tonguing for Jazz Saxophone"](https://thewoodshedmusic.com/2014/04/tonguing-for-jazz-saxophone/)).
- A saxophone-forum thread pushes back hard on that same rule: it is *"only true about a quarter of the time... more often untrue than true"* in real playing ([Sax on the Web forum](https://www.saxontheweb.net/threads/question-about-proper-jazz-articulation.397048/), via search synthesis — thread content not independently re-fetched).

**These disagree on how prescriptive the rule is, not on its direction** — both agree upbeats-tongued/downbeats-slurred is *a* real tendency and both agree first/last notes of a phrase get tongued regardless of beat position. I did not find a numeric "X% of notes are tongued" statistic anywhere in the literature; any percentage in §6 is an **engineering default I am proposing**, not a measured practitioner statistic.

### 1.4 Breath — the sources explicitly refuse to give numbers, and that refusal is itself informative

Two independent sources on wind breathing **deliberately decline** to give duration figures:

- Orchestration Online's Thomas Goss explicitly argues against duration charts: *if "our chart says that oboe players can hold a note for 45 seconds," students abuse the number* — the guidance offered instead is relative capacity (oboe > bassoon/clarinet > flute) and "musical breaths" modeled on natural speech rhythm ([Orchestration Online](https://orchestrationonline.com/woodwinds-note-durations-and-breathing/)).
- Bret Pimentel (professional woodwind player/pedagogue) gives the same shape of advice: mark **musical breaths first** (phrase-driven, taken even when air remains), then **survival breaths** only where physically required; never breathe at a bar line just because it looks like a stopping point ([Bret Pimentel, "Planning breaths"](https://bretpimentel.com/planning-breaths/)).

Since no source will commit to a number, here is a **derived, unsourced estimate** for what this means in beats at our own ballad-genre tempo (72 BPM, 833 ms/beat): a musically normal 4-8 bar phrase in 4/4 is 16-32 beats = **13.3-26.7 seconds**, comfortably inside typical wind-playing breath capacity at a relaxed dynamic — meaning a breath rest belongs roughly **every 4-8 bars**, at a phrase boundary (cadence, end of a lyrical idea), not on a fixed clock. The **rest itself** should be short — a "catch breath" rather than a full stop; I estimate **150-400 ms** (≈0.18-0.48 beats at 72 BPM) as a reasonable placeholder, again **not sourced** — this is the second number in this report most worth confirming by ear rather than trusting on paper, and can ride along on the same render test proposed for §1.1/§2.3.

---

## 2. Continuous controllers — the expression layer

### 2.1 CC11 (expression) — the 127-default trap is real and confirmed in two places

- The convention is confirmed generically: CC11 defaults to 127 and any custom shape is a modification from that ceiling, not from zero ([search synthesis of MIDI CC reference pages](https://motifkit.com/midi-cc/), [nickfever.com](https://nickfever.com/music/midi-cc-list)).
- **DAW Pro's own model encodes this exact convention**: `MIDIControllerType.neutralDefault` returns **127 for CC11** as "expression (full)" (`Sources/DAWCore/Model.swift:294-305`) — this is the value the schedule chases back to when no point precedes a block. **Any authored CC11 lane that peaks below 127 is therefore a net cut relative to the instrument's resting state, not a shape** — exactly the risk flagged in the task. Correct authoring practice, per practitioner convention: shape CC11 within roughly **100-127** for a contoured-but-still-full-volume swell, and only dip lower when the musical intent is an actual dynamic drop (with the drop compensated by clip/track gain if the overall part reads too quiet against the mix).
- One nuance worth carrying into any implementation: several practitioners describe CC11 and CC7 (channel volume) as **multiplicative**, and describe a workflow where **CC11 sets the "dynamic marking" baseline (p/mf/f) and CC1 does the phrase-level shaping on top** — the inverse of the more common "CC1 = dynamic layer crossfade, CC11 = output trim" convention used by some orchestral libraries. Practice is genuinely split here (see the VI-Control "Dynamics vs Expression" thread cited below) — **do not treat either convention as universal.**
- Sources: [modwheel.net, "Understanding MIDI CCs for Orchestral Programming"](https://modwheel.net/guides/understanding-midi-ccs); [VI-Control, "The difference between Dynamics (CC1) and Expression (CC11)"](https://vi-control.net/community/threads/the-difference-between-dynamics-cc-1-and-expression-cc-11.58127/page-2); [SOS forum, "MIDI Expression CC11 - a lesson for instrument designers"](https://forum.soundonsound.com/phpbb/viewtopic.php?t=90324&embed=true).

### 2.2 CC2 (breath) and CC1 (mod wheel) as vibrato-depth control

CC1's *original* MIDI purpose is modulation-wheel vibrato depth, and that is still the live convention on most wind patches; CC2 is the default target for a hardware breath controller and is sometimes used interchangeably with CC1 for vibrato on wind-specific patches ([search synthesis, general MIDI-CC references](https://modwheel.net/guides/understanding-midi-ccs)). The idiomatic shape, confirmed across multiple sources: **start a note with no vibrato and bring it in over roughly the first fraction of a second to a few seconds** — "delayed vibrato onset" is repeatedly called out as one of the clearest tells that separates a played note from a triggered one. On sax specifically, one practitioner note states vibrato is more often applied **centered on or below the target pitch**, not symmetrically above and below.

### 2.3 CC1 depth and rate — the SF2 spec gives an actual number, and it matters here

This is the single most load-bearing citation in this section, because DAW Pro's GM sound-bank path plays through a real, spec-conformant sampler (AUSampler, §3.2):

The **SoundFont 2 specification mandates 10 "default modulator" connections** every conformant synth engine must implement even when a preset defines none of its own, including **MIDI CC1 → Vibrato LFO Pitch Depth** and **MIDI CC11 → Initial Attenuation** ([SoundFont 2.04 Technical Specification](https://musescore.org/sites/musescore.org/files/2023-01/sfspec24.pdf); corroborated by [synthfont.com, "SoundFont modulators"](http://www.synthfont.com/modulators.html)). The commonly cited default depth is **CC1 at full value adds up to 50 cents of vibrato at a roughly 4 Hz LFO rate** — i.e. a genuinely audible, moderate vibrato, available on *any* SF2-conformant patch, even one that never explicitly asks for vibrato. **What is unverified**: whether Apple's AUSampler fully implements these default connections, and whether the specific macOS system bank (`gs_instruments.dls`, a DLS not SF2 file — DLS's default-connection story differs from SF2's) actually responds. This is worth an actual render-and-listen test before relying on it — a two-note bounce (CC1=0 vs CC1=100 on an otherwise identical held note) would settle it in minutes and is a cheap first verification step for whoever picks this up. The same render can double-check the §1.1 overlap figure and the §1.4 breath-rest duration by ear at essentially no extra cost.

### 2.4 Pitch bend — scoops, falls, doits, and two DAW Pro-specific hazards

- Idiomatic sax gestures, terminology confirmed via multiple sources: **scoop** (rise up into the target note from below), **doit** (rise up and off the note at its end), **fall** (drop off the note at its end), **plop** (drop down into the note from above) ([Sax on the Web forum](https://www.saxontheweb.net/threads/different-falls-and-scoops.24645/); general terminology cross-checked against orchestration references).
- MIDI pitch bend is a **14-bit value, and DAW Pro's clip lanes store it raw (0-16383, center 8192)** with a documented **±2-semitone default range on the built-in custom sampler**, confirmed by reading code (`Sources/DAWEngine/Instruments/SamplerInstrument.swift:244`, `bendRangeSemitones = 2.0`, hardcoded, not configurable per-instrument today — this applies to `.sampler`-kind tracks, not the GM path). AUSampler (the actual GM-bank playback engine, `.soundBank`) supports a **configurable** bend range per Apple's own documentation, but DAW Pro does not set it anywhere in `AUHostRegistry.swift` — it is left at AUSampler's factory default. That factory default is conventionally **±2 semitones** (matching General MIDI convention), but **this specific figure is not independently confirmed for AUSampler** — flagged as the second open verification item alongside §2.3's CC1 test.
- **Headroom finding, not just a caveat**: idiomatic fall/doit depth in real playing can exceed a minor third (a few hundred cents) — bigger than a ±2-semitone (±200-cent) bend range can deliver without clipping at the rail. **If bigger gestures are wanted, the fix is a concrete engineering task, not just a MIDI-authoring choice**: set AUSampler's pitch-bend-range property explicitly (unset today) rather than relying on its factory default. Until that's done, author fall/doit depth **within ±200 cents** on the GM path, or accept that anything requested beyond that will simply clip at the ±2-semitone ceiling.
- **Channel-wide-bend hazard — confirmed by code read for one instrument kind, inferred for the other.** Pitch bend is a **channel-wide MIDI message** by the MIDI spec itself, not a per-note one. For DAW Pro's custom sampler (`.sampler` tracks) this is **confirmed by reading the code**: the bend handler iterates `where voices[index].active` with no per-note filter (`SamplerInstrument.swift:780-789`) — an incoming bend affects every currently-sounding voice on the instrument, including a departing note's release tail. For AUSampler (`.soundBank`, the path actually in play here) the same behavior is **not** independently code-read — it is **inferred** from standard MIDI channel-message semantics, which any conformant synth (including AUSampler) should follow, but this is reasoning by convention, not a verified fact about Apple's implementation. **Practical consequence either way**: if you author a "fall" on note N's release tail while note N+1 has already started (the overlap recommended in §1.1), the fall will also bend N+1's freshly-started attack — the two goals fight each other. Falls/doits/scoops are safest on **phrase-boundary notes with no following overlap** (the last note before a breath rest, or the first note after one); mid-phrase notes that use overlap should stay bend-free.

---

## 3. What specifically makes a GM soundfont sax sound fake, ranked by fixability on DAW Pro's actual architecture

This section is grounded in reading the engine source, not general soundfont folklore (though the folklore agrees on the qualitative causes: "MIDI simply doesn't have enough information," "wind and brass are hardest," per general forum consensus — [HomeRecording.com, "Sax Soundfonts: Realistic?"](https://homerecording.com/bbs/threads/sax-soundfonts-realistic.103321/)).

### 3.1 Confirmed: no legato-hold mode exists anywhere in this engine (fixable: no — needs a different instrument or new engine work; masking it is Tier 0)

Both playback paths — DAW Pro's own custom `SamplerInstrument` (used for imported SFZ/.dspreset libraries) and Apple's AUSampler (used for **every** `.soundBank`/GM track) — start a brand-new voice with a fresh attack envelope on every note-on, unconditionally. There is no "steal the previous voice and pitch-glide" behavior in this codebase for *any* instrument kind. This is the direct cause of "keyboard-entered": overlap does not (and architecturally cannot, without new engine work) eliminate the retrigger; it can only mask it under the previous note's decaying tail (§1.1). **This is the ceiling on what MIDI-side authoring alone can achieve** — true legato requires either a scripted-legato AU (§4) or new engine capability, both bigger lifts than anything else in this report.

### 3.2 Confirmed: `.soundBank` tracks ARE fully CC/bend-capable today — the generation layer just never uses it (fixable: yes, zero engine work)

Traced end-to-end: `AUHostRegistry.swift` synthesizes a real `AUSampler` (`kAudioUnitType_MusicDevice`, "samp") for every `.soundBank` instrument and loads the SF2/DLS program via `kAUSamplerProperty_LoadInstrument` (:948-966); `HostedAUInstrument.render` forwards every scheduled event kind — note on/off, CC (any number), 14-bit pitch bend, channel pressure — to that AU via `scheduleMIDIEventBlock`, with only genuinely-unknown future kinds silently dropped (`HostedAUInstrument.swift:188-221`). The clip-level lane model (`MIDIControllerLane`, `clip.setControllerLane`/`clip_set_controller_lane`) that feeds this is fully shipped (ROADMAP m16-b1-4, all `[x]`) and already has a piano-roll editing surface and an MCP tool. **Nothing stands between "the generation code decides to author a CC11 swell" and "it plays back correctly" — the wire is not the gap.**

(Contrast: DAW Pro's *other* built-in path — the custom `SamplerInstrument` used for imported SFZ libraries — is deliberately more limited: it honors only CC64 sustain and its fixed ±2-st pitch bend, and drops every other CC by design (`SamplerInstrument.swift:754-758`, comment: "every other CC is deliberately ignored here... hosted AUs receive them all"). **This limitation does not apply to the GM sound-bank track the field report is about** — it would matter only if the fix path in §4 leads to importing a plain SFZ library rather than hosting a scripted AU instrument. Worth being precise about which of DAW Pro's three instrument kinds (`.soundBank` / `.sampler` / `.audioUnit`) is in play before assuming what CC surface is available.)

### 3.3 Confirmed: no per-patch envelope/filter exists to expose, for either instrument kind (fixable: no, not from the MIDI/FX side)

`SoundBankConfig` has no envelope fields (§0). Even DAW Pro's own custom sampler's per-zone ADSR (`SamplerZone`, used for imported SFZ libraries, m19-b) is **not** exposed for `.soundBank` tracks, which read whatever attack/decay/sustain/release the DLS/SF2 file's own generator data specifies and nothing else. There is genuinely no UI or wire lever here today for a GM-bank instrument.

### 3.4 Available today but unused: FX-side softening (fixable: yes, zero engine work, cheapest possible lever)

Both `CompressorEffect` and `ReverbEffect` are shipped, working track-insert effects (`Sources/DAWEngine/Effects/`). Neither is GM-sax-specific, but both are real, general-purpose levers a generation/mixing pass could apply automatically to any melodic wind/brass track with zero new code:
- A gentle compressor (fast attack, moderate ratio) on the sax insert chain evens out the sharpest attack transients note-to-note — it doesn't remove the retrigger, but it reduces how *punchy* each one reads.
- A short reverb tail (small room/plate, modest wet mix) blurs the boundary between notes, which is exactly what helps most on notes that still have a small gap between them (breath rests, or any residual authoring imperfection) — the reverb tail fills what would otherwise be dead silence.

This is a genuinely low-effort, high-availability lever that the task's "MIDI/FX side" framing explicitly asked about and that the rest of this research (focused on MIDI/CC authoring) would otherwise have missed.

### 3.5 Likely true but unverified: the specific GM bank patch quality itself

Generic forum consensus (not DAW Pro-specific, not independently verified against `gs_instruments.dls` directly): cheap/generic GM banks commonly use few samples per octave with pitch-shifting across a wide range, no velocity-crossfaded dynamic layers, and minimal or no patch-authored modulation — all of which compound the "static, sampled-once" quality on top of the retrigger problem. I could not verify these specifics against the actual macOS system bank (would require inspecting `gs_instruments.dls`'s zone/generator data directly, out of scope for this research pass) — flagged as plausible-but-unconfirmed.

---

## 4. Better instrument options

DAW Pro can host **AUv2/AUv3** Audio Units (`AUHostRegistry`) and has its own **SFZ/.dspreset importer** shipped and working (ROADMAP M19, m19-a through m19-d: velocity layers, round-robin, groups, per-zone ADSR, all imported into the same custom `SamplerInstrument` zone model). That importer's mapper explicitly **reason-codes every opcode it skips** rather than silently dropping data (`instrument.importSampleLibrary`, dry-run supported) — the cheapest way to find out exactly what a candidate library loses on import is to actually run a dry-run import against it, not to guess from a spec sheet. I did not do this (out of scope: "do not touch code"/no live app interaction), but it is the natural next step and is flagged in §8.

**Important caveat that applies to every option below**: our SFZ mapper explicitly skips `trigger`≠`attack` regions (i.e. scripted `trigger=legato`/`trigger=release` opcodes are dropped, per the m19-c ROADMAP entry: "reason-coded skips incl. trigger≠attack/CC/keyswitch-reduction"). **A scripted-legato SFZ library imported through our own pipeline today will lose its legato scripting and degrade to a plain multi-sample instrument** — better round-robin/velocity variety than GM, but the same "every note-on is a fresh voice" ceiling as §3.1. This matters for evaluating the options below: none of the *free* libraries found actually carry scripted legato anyway (they are all plain layered sample sets), so this caveat mostly matters if someone later considers importing a scripted-legato commercial SFZ library and expects the legato to survive — it won't, with today's importer.

| Library | Format | License | Size / layers | Legato scripting | Notes |
|---|---|---|---|---|---|
| **Weresax** (Karoryfer Samples) | SFZ, 24-bit WAV | **CC0-1.0** (public domain) | 189 MB, 256 samples, **2 velocity layers × 2 round-robin** per note, D♭2-A♭4 chromatic | No — plain layered sample set | Alto sax per most listings (one source calls it tenor-range samples); free, open-source, importable via our own SFZ pipeline today. [Karoryfer via GitHub](https://github.com/sfzinstruments/karoryfer.weresax), [Bedroom Producers Blog writeup](https://bedroomproducersblog.com/2015/11/13/weresax-saxophone-sfz/) |
| **Bear Sax** (Karoryfer Samples) | SFZ | **CC0-1.0** | 1926 Conn baritone sax; staccato has **4 dynamic layers, 3-4 round-robin** | No | Baritone, not tenor — included for completeness/technique reference. [GitHub](https://github.com/sfzinstruments/karoryfer.bear-sax) |
| **VCSL tenor saxophone** (Versilian Community Sample Library) | SFZ (WAV/FLAC) + SF2 | **CC0-1.0** (explicit public-domain dedication) | Library-wide convention: **1 round-robin, 2-3 velocity layers** typical (not confirmed per-instrument for the sax specifically) | No | Genuinely tenor, genuinely free, genuinely CC0. Best license/instrument-match combination found. [Versilian Studios](https://versilian-studios.com/vcsl/), [GitHub](https://github.com/sgossner/VCSL) |
| **MTG Solo Sax** | — | **CC-BY-4.0** (attribution required) | 110 MB | Unverified | Attribution requirement is a real constraint if bundled into a shipped product — flag before use. |
| **FreePats tenor saxophone** | SFZ + SF2 | **CC0 1.0** | Unverified layer count | Unverified | [freepats.zenvoid.org](https://freepats.zenvoid.org/Reed/saxophone.html) |
| **Monster Sax** (MonsterDAW / Devian Zikri) | Standalone VST/VST3/**AU** plugin (not raw samples) | **Unverified** — described as "free" everywhere it's covered, but no license text was found in any source checked | ~50 MB+ | Yes — ships **8 key-switched articulations including "legato," "slurs," "bending," "growls"** as an engine feature, not raw overlap-triggered scripting | Would be hosted as a third-party `.audioUnit` instrument (not imported as samples), which per project history has had **reliability issues with some third-party AUv2 instruments** (main-actor stalls on load, documented separately in project operating notes — not a general claim about all third-party AUv2, but a reason to test before relying on it). License is the bigger open question — do not bundle without confirming terms directly from the publisher. [Bedroom Producers Blog](https://bedroomproducersblog.com/2023/05/09/monster-sax/) |
| **SWAM Saxophones** (Audio Modeling / ex-Sample Modeling) | Commercial plugin, AU/VST/VST3/AAX | Commercial, paid | N/A (physically modeled, not sampled) | **True real-time legato via physical modeling** — not sample-based at all, so the entire "voice retrigger" ceiling in §3.1 does not apply to it | Included as the *quality ceiling reference*, not a free option: independent reviews describe its legato as flowing in "an unbroken stream" with continuous breath/dynamics control ([Sound on Sound review](https://www.soundonsound.com/reviews/audio-modeling-swam-solo-instruments), [Audio Modeling product page](https://audiomodeling.com/swam-engine/solo-woodwinds/swam-saxophones/)). If DAW Pro ever wants a sax that doesn't have the retrigger ceiling at all, this is the class of product, and it would be hosted the same way Monster Sax would (`.audioUnit`), with full CC/bend forwarding already working per §3.2. |

**Usable without a commercial sampler?** Yes for Weresax/Bear Sax/VCSL/FreePats — all are raw SFZ (or SF2) files importable through DAW Pro's **own** SFZ pipeline (`instrument.importSampleLibrary`), no third-party player required. Monster Sax and SWAM are standalone AU plugins and would go through AU hosting instead.

---

## 5. What other tools offer to make this automatic

| Tool / feature | What it does | Relevant figures |
|---|---|---|
| **Ableton Live 12 — Span (Note Utilities)** | One-click transform: Legato / Tenuto / Staccato applied to a note selection | Qualitative only (extends to next note-on / preserves length / derives from smallest gap) — [Ableton manual](https://www.ableton.com/en/live-manual/12/midi-tools/) |
| **Ableton Live 12 — Note Length MIDI effect** | Real-time (not destructive) gate-percent control via a `Gate` parameter, 100% = full step, >100% = overlapping/legato | Same manual |
| **Ableton Live 12 — Humanize (Note Utilities panel)** | Timing/velocity randomization, similar scope to DAW Pro's own `HumanizeModel` | — |
| **Logic Pro — "Force Legato" (Piano Roll)** | Extends each selected note to the start of the next, one command | [Apple Support](https://support.apple.com/guide/logicpro-ipad/force-legato-lpip9af3c9f9/ipados) |
| **Logic Pro — MIDI Transform window** | Preset-based note-length/velocity/timing transforms, incl. a "Humanize" preset | [Sound on Sound](https://www.soundonsound.com/techniques/logic-pro-midi-transform-humanize) |
| **Cubase — Logical Editor presets** | Community-shared presets specifically tuned to fix legato-gap mismatches when quantizing against sample-library legato triggers | [VI-Control thread](https://vi-control.net/community/threads/cubase-logical-editor-presets-for-css-legato-delays.67706/) |
| **NotePerformer** (Sibelius/Dorico/Finale playback engine) | Automatically infers articulation/dynamics from notation context — a different approach (score-driven, not a manual transform) | [noteperformer.com](https://www.noteperformer.com/?page=support_dorico) |

**DAW Pro's own current surface, for comparison**: `HumanizeModel` (`Sources/DAWAppKit/HumanizeModel.swift`) is a two-dimension tool — timing jitter (±0-0.25 beats) and velocity spread (±0-64) — with no gate/legato dimension at all, and no CC-authoring affordance. No "articulation" or "phrase" tool exists anywhere in the app or the MCP surface today; `clip_set_controller_lane` is powerful but low-level (an agent/human must hand-author every point). **The minimal affordance that would raise the floor on every melodic wind part**: a third `HumanizeModel` dimension (or a sibling tool) for **gate percentage** — exactly the same shape as the existing timing/velocity sliders, defaulting to something like 105-115% (legato-leaning, since "abuts or gaps, never overlaps" is the reported failure mode) — would directly fix root cause #1 (§0) with the smallest possible surface-area addition, reusing the existing panel's undo/apply/no-seed-control design precedent verbatim.

---

## 6. Recommended parameter set

All beat figures assume the ballad-genre default tempo, **72 BPM (833 ms/beat)** — recompute for other tempos via `beats = ms / 1000 × BPM / 60`. Figures marked **(derived)** come from reading DAW Pro's own engine behavior, not a practitioner source; figures marked **(estimate)** are engineering proposals with no citation behind them — flagged per the task's request for honesty over false confidence.

| Parameter | Recommended value | Basis |
|---|---|---|
| Note overlap (legato passages, no scripted engine) | **20-40 ms ≈ 0.024-0.048 beats** | **(derived)** — masks the fresh-voice attack transient without reading as a dyad; see §1.1. Worth confirming by ear. |
| Note overlap (if hosting a scripted-legato AU, e.g. SWAM) | Overlap amount is secondary; drive legato speed via that plugin's own CC (e.g. SWAM's portamento-time CC) | §1.1, Samplemodeling forum |
| Gate % — legato phrase | **105-110%** (i.e. slight overlap into next note) | CMUSE calculator convention (tool default, not a standard) |
| Gate % — tenuto | **95-100%** | Same, cross-checked against Ableton Span's qualitative definition |
| Gate % — staccato | **25-50%** | Same |
| Gate % — never exactly 100% or a hard gap | Eliminate the abut/gap-only pattern the field report measured | Field report is the evidence here |
| Tongued-note proportion | **~30-40% of notes** in a legato jazz phrase, always including the first and last note of every phrase | **(estimate)** — sources disagree on the general rule's strength (§1.3); this is a pragmatic default, not a measured statistic |
| Breath rest placement | Every **4-8 bars** (16-32 beats ≈ 13.3-26.7 s at 72 BPM), at a phrase/cadence boundary | **(derived)** from typical breath capacity + genre tempo; sources explicitly decline to give numbers (§1.4) |
| Breath rest duration | **150-400 ms ≈ 0.18-0.48 beats** | **(estimate)**, unsourced. Worth confirming by ear. |
| CC11 (expression) range for a "shape, not cut" swell | **100-127**, never resting below ~90 for a still-audible passage | §2.1, our own `neutralDefault = 127` |
| CC1 (vibrato depth) onset | Hold at 0 for the first **~300-600 ms** of a note (or the whole note, for notes shorter than that), then ramp in over the remainder | §2.2, general delayed-onset convention |
| CC1 depth ceiling | Up to the SF2-spec default of **~50 cents at CC1=127** | §2.3 — **unverified against the actual macOS GM bank**, needs a render test |
| Pitch bend — scoop into a note | **-100 to -200 cents**, ramping to 0 over **~80-150 ms** at note onset | §2.4, within the ±2 st (±200 cent) range available on the GM path today |
| Pitch bend — fall/doit | **Cap at ±200 cents** on the GM path as configured today (idiomatic depth can run larger, but exceeds the unconfigured AUSampler bend range — see §2.4's headroom finding); author only on phrase-final notes with no following overlap | §2.4 — the channel-wide-bend hazard (confirmed for the custom sampler, inferred for AUSampler) means this must not coincide with an overlapping next note |
| FX — compressor on wind/brass tracks | Fast attack, moderate ratio, light gain reduction on note peaks | §3.4, shipped `CompressorEffect`, zero new code |
| FX — reverb tail | Short room/plate, modest wet mix, to blur any residual gap | §3.4, shipped `ReverbEffect`, zero new code |

---

## 7. Fixable today (MIDI/FX layer, zero engine work) vs. needs more

**Fixable today, purely by changing what the generation layer authors** (all tools already shipped and wired end-to-end for a `.soundBank`/GM track, confirmed in §3.2):
- Note overlap and gate-percent variety (`clip.setNotes` / `clip_set_notes` — pure beat/length placement, no new tool needed)
- Tongued/slurred texture via velocity variation on the existing notes
- Breath rests (just don't place a note there)
- CC11 expression contour, CC1 vibrato, CC2 breath, pitch-bend gestures within ±200 cents (`clip.setControllerLane` / `clip_set_controller_lane` — exists, documented, unused for generated wind parts)
- Compressor/reverb on the instrument's insert chain (`fx.add` — exists, unused for this purpose)

**Needs more than MIDI/FX authoring:**
- True legato (single sustained voice pitch-gliding between notes, no retrigger at all) — not possible on either DAW Pro instrument kind today; would need either a scripted-legato AU (SWAM-class, commercial, hostable today via `.audioUnit` with zero new engine work since CC/bend forwarding already exists) or new engine capability in DAW Pro's own sampler
- Wider pitch-bend gestures (beyond ±200 cents) on the GM path — needs an explicit `kAUSamplerProperty` bend-range configuration in `AUHostRegistry`, a small but real engine change (§2.4)
- Better base timbre (round-robin/velocity-layer variety, less "the same sample every time") — solvable today via the SFZ importer + a free library (Weresax/VCSL, §4), but does **not** by itself fix the discreteness — that is a MIDI-authoring problem first (§3.1), an instrument-quality problem second
- Confirming whether the stock GM DLS bank's sax patch honors CC1 vibrato at all, and confirming AUSampler's actual factory bend range — needs an actual render-and-listen test, not further reading

---

## 8. Actionable takeaways

1. **Highest-value, lowest-effort fix: change what the generation/arrangement code authors for melodic wind (and likely all monophonic melodic) instrument tracks.** Nothing here requires new engine or wire surface — route: whichever agent owns the arrangement-generation prompt/logic (likely `mcp-integration-engineer` for the MCP-side generation code, or the composition prompt itself if the note placement comes from an LLM call). Concretely: stop emitting exact-abut/gapped note sequences; author with the §6 overlap/gate table; call the existing `clip_set_controller_lane` tool to add CC11 (100-127 range) and CC1 (delayed-onset vibrato) lanes on generated wind/brass melodic tracks; use pitch bend (within ±200 cents until the bend-range item below lands) for phrase-final falls/doits only.

2. **Add a `gate` (legato/staccato) dimension to `HumanizeModel`, mirroring the existing timing/velocity sliders.** This is the single UI/API affordance that would raise the floor on every melodic part, not just AI-generated ones (§5). Route: `swift-app-engineer` (the model change) — reuses `HumanizeModel`'s existing apply/undo/no-seed-control precedent, likely small.

3. **Verify CC1 vibrato actually reaches the ear on the stock GM bank, and confirm AUSampler's actual pitch-bend range, before relying on either in generation prompts** — a two-note render-and-compare (CC1=0 vs CC1=100; and a max-value pitch bend vs a known interval) settles §2.3 and §2.4's open questions cheaply, and the same render can confirm the §1.1 overlap and §1.4 breath-rest figures by ear. Route: whoever picks up item 1, as a five-minute pre-check.

4. **If wider pitch-bend gestures (beyond ±200 cents) are wanted for sax/brass, set AUSampler's bend-range property explicitly in `AUHostRegistry`** instead of relying on its unconfigured factory default (§2.4/§7) — small, scoped engine change, `audio-dsp-engineer` or `daw-architect` territory depending on how it's exposed (a fixed engine-wide default vs. a per-instrument config field).

5. **If/when a better sax timbre is wanted, evaluate the SFZ importer against Weresax and VCSL tenor sax via a `dryRun` `instrument.importSampleLibrary` call** — the mapper reason-codes every skipped opcode, so this tells you exactly what's lost on import instead of guessing from a license page (§4). Both are CC0, no license risk. This is a smaller, independent follow-up from item 1 — it improves the *instrument*, not the *authoring*, and per §3.1/§7 does not by itself fix the discreteness complaint.

6. **Do not bundle Monster Sax or any other "free" plugin whose license text was not directly verified** — flagged unverified in §4; if it's wanted, get the actual license from the publisher first, not from secondary coverage.

7. **Longer-horizon, filed not scheduled**: true legato (no retrigger at all) is architecturally out of reach for both DAW Pro instrument kinds today (§3.1/§7). If wind-instrument realism keeps mattering, the two paths are (a) host a scripted-legato/physically-modeled commercial AU (SWAM-class — CC/bend forwarding already works, §3.2, so this is mostly a licensing/UX decision, not an engine one) or (b) a genuine engine feature (voice-steal-and-glide on note-on-during-sustain) — bigger, `daw-architect`-scoped, not proposed as a near-term item here.

---

## Unverified / flagged claims (collected)

- Whether `gs_instruments.dls`'s tenor sax patch honors CC1 vibrato or CC11 attenuation via its own or the DLS-spec-default modulator connections (§2.3, §6).
- AUSampler's actual factory-default pitch-bend range — documented as configurable, conventionally ±2 semitones, but DAW Pro does not set it explicitly anywhere found, so the effective default is Apple's factory value, not independently confirmed (§2.4).
- The channel-wide-bend hazard on the AUSampler (`.soundBank`) path specifically — confirmed by code read for DAW Pro's custom sampler, inferred from standard MIDI channel-message semantics (not code-read) for AUSampler (§2.4).
- Exact velocity-layer/round-robin counts for VCSL's tenor sax and the FreePats tenor sax specifically (library-wide conventions cited, not confirmed per-instrument) (§4).
- Whether Weresax is alto or tenor range — sources disagree (§4).
- Monster Sax's actual license terms — no license text found in any source checked, only "free" descriptions in secondary coverage (§4).
- Generic GM-soundfont quality claims (few samples/octave, no velocity crossfade) as applied specifically to `gs_instruments.dls` — plausible from general forum consensus, not confirmed against this specific file (§3.5).
- The "~30-40% tongued" and breath-rest-duration figures in §6 are explicitly engineering estimates, not sourced statistics (see inline flags).
