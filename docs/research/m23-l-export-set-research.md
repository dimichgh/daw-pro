# m23-l — Export research spike: what a complete export set looks like

**Date: 2026-07-27. Status: spike complete, GO recommendation issued. Route
after this doc: m23-m implements the delta (not a rewrite).**

Scope discipline for this document: it is research only. No file under
`Sources/`, `mcp-server/`, `Tests/`, or `scripts/` is touched by this spike.
Every command name below is a **proposal**, named to the letter of this
project's own wire conventions, for `m23-m` to build or reject.

---

## 0. What this replaces

The M23 seed HAVE block (`docs/ROADMAP.md` ~line 347) is **stale** on the MIDI
rung as of 2026-07-27 — it still lists "no SMF read/write path" as a gap. It is
not. `project.exportMIDI` / `track.exportMIDI` (m23-k4a) and the reciprocal
import path (m23-k3) both shipped. The roadmap's own m23-l line already carries
a corrected, line-level premise patch dated 2026-07-27 with measured file/line
citations; this document verifies that patch against the source (all citations
below were re-read, not assumed) and builds the comparison and proposal on top
of it.

**One framing correction to the roadmap line itself, surfaced rather than
smoothed over:** the line's own premise patch points at `includeMixdown`'s
full-session-vs-selection split as "the whole story for the instrumental/
minus-vocal rung." Having read the mute/solo gating code (§4.4), that turns
out to point at the wrong verb: `includeMixdown` is `render.stems`' own
chain-excluded null-check reference and has no normalization/mastering role at
all. The instrumental rung belongs on `render.bounce` (the mastered verb), not
on a stems-side flag, and it should be built via a mute-state copy, not via a
track subset. §4.4 has the full argument.

---

## 1. The measured HAVE — our own export surface today

This is the section the gate demands up front: which rungs already exist, so
`m23-m` is additive.

| # | Rung | Covered today? | By what |
|---|---|---|---|
| 1 | MIDI out | **YES — fully built** | `project.exportMIDI` / `track.exportMIDI` (wire), `project_export_midi` / `track_export_midi` (MCP), File → Export MIDI… (menu, project-scope only) |
| 2 | Raw stems | **YES — fully built** | `render.stems` / `render_stems` |
| 3 | Mastered stems | **NO — and see §4.3, this is deliberate, not an oversight** | — |
| 4 | Instrumental / minus-vocal | **Reachable today, but not as one call, and not without mutating the project.** Offline rendering already honors `Track.isMuted` (§4.4 — confirmed, not assumed, in the gating code), so `track.setMute` → `render.bounce` → `track.setMute` back produces a correct instrumental today. What's missing is atomicity and non-mutation, not rendering capability. | `track.setMute` (`Sources/DAWControl/Commands.swift:659-661`, params `trackId`/`muted`) + `render.bounce` |
| 5 | Full mastered mixdown | **YES — fully built** | `render.bounce` (LUFS + true-peak-ceiling normalization; "no limiter in v0") |
| 6a | Format / bit-depth / sample-rate options | **NO.** Every render path writes Float32 linear PCM WAV at the engine's own sample rate; no param anywhere chooses a container, depth, or rate | `OfflineRenderer.writeWAV`, `Sources/DAWEngine/OfflineRenderer.swift:508-554` (settings come straight from `AVAudioFormat.standardFormatWithSampleRate` + Float32, `AVLinearPCMIsNonInterleaved` overridden for WAV interleaving — nothing else is configurable) |
| 6b | Normalization | **YES for the mastered mixdown; deliberately NO for stems** | `render.bounce`'s `lufsTarget` / `truePeakCeilingDb`; stems are "NEVER normalized (spec §4.1)" per `ProjectStore+Render.swift:153-156` |
| 6c | Export presets | **NO** | — |

Two file-level facts worth restating because `m23-m` will lean on them
directly:

- **`render.stems`' `includeMixdown` renders the full session, not the
  selection.** `ProjectStore+Render.swift:222-233` passes the whole `tracks`
  array for the "00 Mixdown.wav" pass, while each stem pass at `:195-202` uses
  `StemPlan.passTracks(for: descriptor, session: tracks)` — a subset. This is
  why `trackIds` reaches the stems and not the mixdown, and it is the entire
  reason a naïve "instrumental" implementation (a subset render) is dangerous
  (§4.4). It is **not**, however, the mechanism the instrumental rung should
  build on — see the framing correction above.
- **Stems are master-chain-excluded on principle** (`ProjectStore+Render.swift:188-202`,
  `masterEffects: []` / `masterAutomation: []`), because a nonlinear master
  chain does not distribute over a partition — m13-d design §2 / **S-3′**. The
  master volume *lane* is excluded too (m15-c) because a programmed fade is
  master performance, not material. `render.stems`' own "00 Mixdown.wav" pass
  (`includeMixdown`) inherits the **same** exclusion — it is the stems' own
  null-check anchor, **not** a mastered deliverable. Anyone reading "we already
  ship a mixdown alongside stems" and concluding the mastered-stems rung is
  covered would be wrong; see §4.3.

---

## 2. Competitive comparison: Logic Pro, Ableton Live, REAPER, Studio One

Method: official vendor docs where they exist and answer the question;
long-standing trade press (Sound On Sound) and vendor knowledge-base articles
where the official manual doesn't cover the specific mechanism; community
sources flagged as such and used only for corroboration, never as the sole
citation for a load-bearing claim. Every claim below is attributed; nothing is
asserted from memory alone.

### 2.1 Logic Pro

- **Discrete operations.** `File > Bounce` (a single mastered file, options in
  the Bounce window) and `File > Export > Export All Tracks as Audio Files`
  (one file per track/aux, non-destructive "burn to audio"), plus a
  **Track-Stacks-as-stems** technique using nested stacks to group and export
  selectively [Sound On Sound, "Logic Pro: Exporting Stems With Track
  Stacks"](https://www.soundonsound.com/techniques/logic-pro-exporting-stems-track-stacks).
- **Stems and the master chain.** Confirmed directly from the Sound On Sound
  piece: exporting via a Track Stack **excludes** everything downstream of the
  stack, including the Stereo Out bus chain — "anything after the Track Stack
  you're exporting won't be included." The author's own workaround for
  monitoring-plugin contamination (SoundID Reference on the master) is to
  export stacks *instead of* bouncing, precisely because stack export never
  touches the master chain. Logic does **not** offer a checkbox to bake the
  master chain into a stem — the article makes no mention of one, and the
  mechanism (stack routing) structurally can't reach it.
- **Format / depth / rate options** — official Apple docs, current version:
  file format is AIFF, Broadcast Wave, or CAF; bit depth ("Resolution") is 8,
  16, or 24; sample rate ranges 11,025–192,000 Hz with 44,100/48,000/96,000
  called out as the common cases; dithering offers None, POWr #1/#2/#3, and
  UV22HR [Apple Support, "PCM bounce options in Logic
  Pro"](https://support.apple.com/guide/logicpro/lgcpb7e35135/mac) and ["About
  dithering algorithms in Logic
  Pro"](https://support.apple.com/guide/logicpro/lgcp44da971f/mac). Logic also
  bounces directly to MP3 and AAC via its own (licensed) encoders — a route not
  open to us (§4.5).
- **Instrumental / minus-vocal.** No named feature. Solo/mute the vocal, then
  bounce, or maintain a duplicate "instrumental" arrangement. [Sound On Sound,
  "Logic Pro Bouncing And Export
  Options"](https://www.soundonsound.com/techniques/logic-pro-bouncing-and-export-options)
  confirms no dedicated mechanism exists; users manage this through mute state
  and re-bouncing — exactly the pattern our own §4.4 makes atomic and
  non-mutating rather than inventing from scratch.
- **Presets.** None found in official docs or the two trade-press pieces
  above; the Bounce window's settings simply persist between uses. Treated as
  an unverified negative, not a confirmed absence.
- **MIDI export.** `File > Export > Export MIDI Regions` (or "Selection as MIDI
  File") lets you export selected regions with a format 0/1 choice [Apple
  Support, "Export MIDI regions as MIDI files in Logic Pro for
  Mac"](https://support.apple.com/guide/logicpro/lgcp77376cad/mac) (page
  confirmed live; specific dialog options not independently re-verifiable
  through the fetch, general shape corroborated by multiple secondary sources).

### 2.2 Ableton Live

- **Discrete operations.** One dialog, `File > Export Audio/Video`, with a
  "Rendered Track" selector: the master, one specific track, or **"All
  Individual Tracks."** Grouped tracks render at the group level with group
  effects, and (Live 10.1+) each grouped track *also* exports individually,
  without group effects [Ableton Help, "Importing and exporting
  stems"](https://help.ableton.com/hc/en-us/articles/360000843404-Importing-and-exporting-stems).
- **Stems and the master chain — the one real per-stem "bake it in" toggle
  found across all four DAWs.** The Export dialog carries an explicit
  **"Include return and master effects"** checkbox (Live 10.1+). Turning it on
  applies the shared master (and return) processing **independently to every
  exported track**. For any nonlinear chain (compression, limiting) this is
  mathematically incoherent as a *stems* feature: if `M` is the (nonlinear)
  master chain and `s₁…sₙ` are the per-track signals, `Σᵢ M(sᵢ) ≠ M(Σᵢ sᵢ)` in
  general — the sum of independently-processed stems does not equal the
  processed sum (the actual mastered mix). Ableton ships this trade-off
  explicitly rather than hiding it (the option is opt-in and off by default),
  but it is a real footgun: multiple independent producer-education sources
  (see below) exist specifically to warn users off it for mastering deliveries
  ("leave Normalize off," "the checkbox is for reference only," etc.), which is
  itself evidence of the class of complaint this creates. This is the
  concrete, named alternative to the S-3′ posture (§4.3) and it is the one we
  are **not** copying.
- **Format / depth / rate.** WAV or AIFF ("Encode PCM"); 8/16/24/32-bit;
  session or custom sample rate. Community guidance (not an Ableton manual
  page, flagged as secondary) consistently recommends 24-bit at session rate
  for mastering handoff, with 32-bit float suggested specifically to avoid a
  second dithering pass when further processing follows [Loop Community, "How
  to Export Stems in Ableton
  Live"](https://loopcommunity.com/blog/2018/06/exporting-stems-in-ableton-live/);
  the abundance of third-party "Ableton export settings" guides is itself a
  signal that the native defaults are not self-evidently correct to users.
- **Instrumental / minus-vocal.** No named feature; solo/mute + export, same
  as Logic.
- **Presets.** None found; the dialog remembers last-used settings per
  project, not named/saved presets.
- **MIDI export.** Per-clip only, via "Export MIDI Clip" from the clip context
  menu, and Live writes **SMF format 0 only** — a real, citable limitation
  relative to our own whole-project, format-0-or-1, tempo-map-and-meter-map
  export [Ableton Help, "Understanding MIDI
  files"](https://help.ableton.com/hc/en-us/articles/209068169); corroborated
  by community reporting that only a single clip can be exported at a time.

### 2.3 REAPER

- **Discrete operations, and the most flexible of the four.** One Render
  dialog with a **Source** popup offering (at minimum) "Master mix" (the
  standard post-master stereo file), **"Stems (selected tracks)"** (one file
  per selected track, "will include the result of any track effects that have
  been applied"), and **"Master mix + stems"** (both in one pass) [community
  confirmation via multiple sources; official REAPER manual/PDF text for this
  exact dialog was not independently retrievable during this spike — flagged
  below as the one comparison leg resting on secondary sources only]. There is
  also a separate **Region Render Matrix** for rendering multiple named
  song-sections/regions to files in one batch — a different axis (time
  selection, not track selection) not directly comparable to our six rungs.
- **Stems and the master chain.** "Stems (selected tracks)" carries per-track
  FX but not the master chain — structurally the same posture as Logic's
  Track-Stacks method and our own `render.stems`. "Master mix + stems" does
  **not** bake the master chain into the stems; it adds the **post-master
  reference file as a sibling output in the same render pass** — this is the
  precedent our §4.3 recommendation follows most closely.
- **Format / depth / rate.** The widest format list of the four — WAV, AIFF,
  FLAC, MP3, Ogg, and more — with standard depth/rate/dither/resample controls
  in the same dialog.
- **Presets — the one clear affirmative among the four, and it is
  primary-source-grade.** A REAPER update-summary PDF (hosted at
  `dlz.reaper.fm`, an official Cockos distribution path) lists the changelog
  line **"Render presets: fix incorrect duplication of presets after
  shift+clicking preset button and saving preset"** [REAPER Update Summary
  Guide, versions 6.68→6.72,
  `dlz.reaper.fm/userguide/REAPER main changes 668 to 672.pdf`] — this is a bug
  fix entry, which is only possible if a "render preset" save/recall mechanism
  already existed to have the bug. Community sources corroborate a `Presets`
  control on the Render dialog itself. This is the strongest evidence of a
  true render-preset feature found in this spike, for any of the four DAWs.
- **Instrumental / minus-vocal.** No named feature beyond solo/mute + render,
  same as the other three.

### 2.4 Studio One

- **Discrete operations.** `Song > Export Mixdown` (one mastered file) and
  `Song > Export Stems` (a dedicated dialog).
- **Stems and the master chain — the cleanest precedent of the four.**
  `Export Stems` has **two tabs**: **Tracks** (raw, pre-effects audio per
  arrange-view track) and **Channels** (each mixer channel with its *own*
  effects chain printed — including sends/returns and, notably, **the ability
  to select the Main/master bus itself as one of the exportable channel
  rows**) [PreSonus Knowledge Base, "Studio One - Is there an easy way to
  export stems in
  S1?"](https://support.presonus.com/hc/en-us/articles/210044093-Studio-One-Is-there-an-easy-way-to-export-stems-in-S1)].
  This is architecturally the same move as REAPER's "Master mix + stems": the
  mastered file is **its own selectable output row, standing alongside the
  stems, never baked into them.** No DAW in this survey other than Ableton
  bakes the shared chain into each stem independently — Ableton is the
  outlier, not the norm.
  - **Live user complaint confirming this is a real pain point, not a
    hypothetical.** A PreSonus community forum thread titled "Exported Stems
    sound different from Master Mixdown" existed at
    `forums.presonus.com/viewtopic.php?t=37257` — the forum was decommissioned
    November 2024 and the thread body could not be retrieved during this spike
    (redirects to a PreSonus closure notice), so only the **title** is
    verifiable here, not the diagnosis. It is cited as evidence the *class* of
    complaint (stems not matching the mastered reference) is a live,
    named-in-the-wild user issue — not evidence of Studio One's specific root
    cause, which is unconfirmed.
- **Format / depth / rate.** WAV, AIFF, FLAC, CAF, Ogg Vorbis, M4A, AAC/ALAC,
  MP3 (with constant/variable bitrate) — resolution and sample rate chosen
  per export; guidance is dither only on bit-depth reduction, Normalize
  defaulted and recommended **off** for mixdowns headed to mastering.
- **Instrumental / minus-vocal.** No named feature; same mute/solo + export
  pattern, though the Channels-tab "export the main bus as a channel" trick
  gets a user *closer* to a one-step "everything except X" export than the
  other three, since checking every channel *except* the vocal's produces the
  minus-vocal mix directly (still requires the Channels-tab summing to route
  correctly, which is a different mechanism from ours).
- **Presets.** Not confirmed either way — no export/render-preset mechanism
  surfaced in the KB articles read, but the manual's dedicated pages were
  unreachable during this spike (`s1manual.presonus.com` now redirects to a
  Fender-hosted login wall, evidently mid-migration as of this writing).
  Recorded as an unverified negative.

### 2.5 Summary table

| | Logic Pro | Ableton Live 12 | REAPER | Studio One |
|---|---|---|---|---|
| Stems mean | per-track / per-stack | per-track or per-group | per selected track | Tracks (dry) or Channels (w/ FX) |
| Master chain on stems | excluded (structural) | **optional, baked in** | excluded; mastered ref is a sibling file | excluded; master bus is a selectable sibling channel |
| Instrumental/minus-vocal | none native | none native | none native | none native (Channels trick helps) |
| Format options | AIFF/BWAV/CAF, 8/16/24-bit, 11k–192k Hz | WAV/AIFF, 8/16/24/32-bit | WAV/AIFF/FLAC/MP3/Ogg+ | WAV/AIFF/FLAC/CAF/Ogg/M4A/AAC/ALAC/MP3 |
| Dither | POWr #1-3, UV22HR | not specified | standard | dither-on-reduction only |
| Export presets | not found | not found | **confirmed** (render presets) | not confirmed |
| MIDI export | selection, format 0/1 | single clip, **format 0 only** | (not surveyed — out of scope, ours already exceeds Live's limitation) | (not surveyed) |

**Reading across the row that matters most for §4.3:** three of four DAWs
(Logic, REAPER, Studio One) keep the mastered file **structurally separate**
from the stem partition — as an excluded-by-construction stem set, or an
explicit sibling/reference output. Only Ableton offers to bake the chain into
every stem, and it is opt-in, off by default, and the subject of persistent
community "don't do this for mastering" guidance. The norm we should match is
the three-DAW norm, not Ableton's.

---

## 3. The rung-by-rung mapping (the spine)

Naming follows this project's settled convention (k4a, verbatim): `render.*`
verbs run the engine offline; `project.*`/`track.*` verbs serialize the model.
Every wire command below gets a snake_case MCP twin with no `daw_` prefix,
matching `project_export_midi` / `track_export_midi` / `render_stems` /
`render_bounce` / `render_mixdown`.

| # | Rung | Existing command | Proposed new command / param | Notes |
|---|---|---|---|---|
| 1 | MIDI out | `project.exportMIDI`, `track.exportMIDI` | — (none needed) | DONE. Residual, not blocking: program change is on the IR but not in the bytes yet (filed k2 follow-up, `programChangesNotWritten`); no File-menu path for a *selection* export, only the whole-project menu entry. Neither is a "complete export set" blocker — the notes/tempo/meter data reaches other DAWs today. |
| 2 | Raw stems | `render.stems` | — (none needed) | DONE. |
| 3 | Mastered stems | `render.stems` (chain-excluded, by design) | **`render.stems`: add `includeMasteredMixdown: Bool = false`, `masteredLufsTarget: Double?`, `masteredTruePeakCeilingDb: Double = -1.0`** | Additive params on the existing verb. When true, writes one extra sibling file (proposed name **"00 Mastered Mix.wav"**, distinct from the existing chain-excluded "00 Mixdown.wav") using the *same* pass `render.bounce` already runs (full `tracks`, real `masterEffects`/`masterAutomation`/`masterVolume`, optionally LUFS-normalized). Never bakes the chain into the per-stem files. §4.3. |
| 4 | Instrumental / minus-vocal | none as one call (composition-only today, §1) | **`render.bounce` (and `render.mixdown` for parity): add `excludeTrackIds: [UUID]? = nil`** | Renders the full session with the named tracks silenced **for this render only** — no project mutation, no dirty flag, no dependency on the caller's mute/render/unmute sequence. §4.4 has the mechanism, the confirming citation that the PDC survey is mute-blind, and the one open sub-question that should gate shipping. |
| 5 | Full mastered mixdown | `render.bounce` | — (none needed) | DONE. |
| 6a | Format / bit-depth / sample-rate | none | **`render.bounce`/`render.mixdown`/`render.stems`: add `bitDepth: Int? = nil` (16 \| 24 \| 32, default nil = today's Float32 unchanged) and `container: String? = nil` ("wav" \| "aiff", default nil = "wav")** | Phase 1 (cheap — a settings-dict change on the existing `AVAudioFile` write path). Compressed containers and sample-rate conversion are Phase 2 (§4.5 — genuine subsystems, not param additions). **ORCH CAVEAT 2026-07-27: "cheap" here is PROPOSED, not VERIFIED.** `OfflineRenderer.swift:540-541` constructs the file as `AVAudioFile(forWriting:settings:commonFormat: .pcmFormatFloat32, interleaved: false)` — the `commonFormat` argument sits *alongside* the settings dict, so whether raising `AVLinearPCMBitDepthKey` to 24 actually yields a 24-bit file while `commonFormat` still says Float32 is unconfirmed (that argument governs the *buffer* format for read/write, and the on-disk encoding comes from `settings` — but the interaction has not been exercised here). `m23-m` should settle this with a five-minute write-and-inspect (`afinfo` on the output) BEFORE costing the rung as a one-line change. This is exactly the class of "looks like a settings tweak and isn't" that the spike could not check, since a research pass runs no code. |
| 6b | Normalization | `render.bounce`'s `lufsTarget`/`truePeakCeilingDb` | (parametrically extended to the new `includeMasteredMixdown` sibling, row 3) | Stems stay never-normalized, unchanged, by design. |
| 6c | Export presets | none | **Named, not left unmapped, and deliberately deferred: `export.savePreset` / `export.listPresets` / `export.applyPreset`** (MCP: `export_save_preset` / `export_list_presets` / `export_apply_preset`) — see §4.5 for the param sketch and §5 Phase 3 for why this is a scheduling decision, not an unanswered rung | Deferred past `m23-m` on purpose (§4.5's MCP-native reasoning), named here so the deferral is dated and explicit. |

---

## 4. Deep dives

### 4.1 MIDI out — what "complete" still wants

Nothing new to build for the rung itself. Two loose ends worth naming so a
later reader doesn't rediscover them:

1. **Program change never reaches the bytes.** `SMFTrack.programChanges` is
   populated on the export IR (for General-MIDI sound-bank tracks) but
   `StandardMIDIFileWriter` — byte-frozen — never reads it. The report is
   honest about this (`programChangesNotWritten`); a receiving DAW opens the
   file on its own default patch. A fix is additive to the byte-frozen writer
   (a new `Rank` rung) but is **k2's file**, and this spike does not authorize
   touching it. If `m23-m` wants a truly turnkey "hand this to another DAW"
   deliverable, that fix belongs on its own line, not folded silently in.
2. **No File-menu path for exporting one track or a selection** — only the
   whole-project entry exists in the menu (`track.exportMIDI` is
   wire/MCP-reachable today, UI-absent). Cheap, UI-only, worth a line in
   `m23-m` if the menu surface matters to the user; it changes nothing in
   DAWCore.

### 4.2 Raw stems — nothing to add

`render.stems` already matches the strongest competitive precedent found
(Studio One's "Channels" tab: per-track/per-channel effects baked in, master
excluded). No proposal.

### 4.3 Mastered stems — the S-3′ collision, engaged head-on

**The math.** For a nonlinear master chain `M` (compression, limiting,
saturation — anything this app's `EQFilterResponse`/dynamics inserts already
allow on a master bus) and per-track/stem signals `s₁ … sₙ`:

```
Σᵢ M(sᵢ)  ≠  M(Σᵢ sᵢ)     in general, whenever M is nonlinear
```

The right-hand side is the actual mastered mix. The left-hand side is what you
get if you print the shared chain onto *each* stem independently — Ableton's
"Include return and master effects" checkbox does exactly this. It is a real,
shipped feature, not a hypothetical mistake, and it is also the one place in
this whole survey where independent producer-education content (multiple blog
posts, not one) exists specifically to warn users away from using it for
mastering handoffs. That pattern — a real feature, opt-in, generating a
cottage industry of "don't actually use this the obvious way" advice — is
itself the signal that "bake the chain into every stem" is the wrong shape for
this rung.

**What the other three DAWs do instead**, independently converging on the same
shape: keep the stem partition chain-excluded (Logic's Track Stacks, REAPER's
"Stems (selected tracks)", our own `render.stems`), and offer the **mastered
file as its own sibling output in the same operation** — REAPER's "Master mix
+ stems" render source, Studio One's Channels-tab main-bus-as-a-channel. Both
land a genuinely mastered file *next to* the stems, never *inside* them.

**The recommendation.** Copy the three-DAW shape, not Ableton's. Add
`includeMasteredMixdown` (plus its own optional LUFS/true-peak params) to the
existing `render.stems` call. It writes one additional file using exactly the
pass `render.bounce` already performs — the real master chain, the real master
volume lane, optionally loudness-normalized — landing alongside, never folded
into, the per-stem files. This is a parameter on an existing verb, not a
subsystem: `render.stems` already knows how to run a full-session pass
(`includeMixdown` does this today, just chain-excluded); this adds a second,
chain-*included* variant of the same pass.

**Naming discipline, because this is the likely bug class.** `includeMixdown`
is a **live** param and it means the chain-excluded null-check anchor
(`ProjectStore+Render.swift:216-233`). `includeMasteredMixdown` must be a
**distinct, additive** param, not a repurposing — an implementer who thinks
"we already have `includeMixdown`, I'll just also flip on the master chain
when both are requested" would be quietly building the Ableton footgun by
accident, on our own file. State this in the `m23-m` implementation notes
verbatim: **`includeMixdown` and `includeMasteredMixdown` are independent
booleans producing two independently-optional files with different, named,
non-overlapping semantics — never a shared flag with a "which chain" switch.**

**The honest characterization for docs/UI copy** (this sentence is the
deliverable the roadmap line asked for): *"A mastered stem" as commonly meant
— an individual instrument's audio with the whole song's shared master chain
printed onto it alone — is not offered, because it cannot be summed back to
the real mix once a nonlinear chain is involved, and the industry does not
actually ship it that way either (three of four surveyed DAWs keep the
mastered file structurally separate from the stem partition; the one that
does bake it in warns its own users off doing so for mastering). What we
offer instead: true stems (pre-master, summing to the null-anchor mixdown to
≤1e-4), plus, on request, the real mastered mix as an extra file in the same
export.*

### 4.4 Instrumental / minus-vocal — the mechanism, and why it must not copy `render.stems`' pattern verbatim

**The trap.** `render.stems` had to invent `forcedCompensationTargets` because
each stem pass calls `renderOffline` with a **reduced** `tracks` array
(`StemPlan.passTracks`) — a subset render's *automatic* PDC plan aligns a lone
track to target 0, while the full mix's plan delays it to the session's
highest-latency strip; without forcing, a stem lands early and combs the sum
(`ProjectStore+Render.swift:148-151`). Any "instrumental" implementation built
the same way — pass a subset of tracks that simply omits the vocal — inherits
the identical hazard, silently, unless it also plumbs the forced-targets
machinery through.

**The better mechanism, found by reading the gating code rather than assuming
the subset shape.** `PlaybackGraph.swift:1475-1487` (and `AudioEngine.swift:1207-1213`
identically) compute an ordinary track's audibility as:

```swift
gated = track.isMuted || (soloActive && !audibleUnderSolo)
...
var gain: Double = gated ? 0 : track.volume
```

**And, confirmed rather than assumed: the PDC survey itself is mute-blind.**
`recomputeCompensation(tracks:)` (`PlaybackGraph.swift:1271-1330`, the function
`offlineCompensationTargets` runs through `reconcile`/`applyParameters`) loops
`for track in tracks { guard let chainState = effectChainState(forTrack:
track.id) else { continue }; … }` — the **only** skip condition is whether a
graph node has been reconciled for that track yet; `isMuted`/`isSoloed` are
never read anywhere in this function. So muting a track changes nothing about
which strips enter `PDCStripInput`, `PDCPlan.compute`, or the resulting
`compensationSamples` map. Mute/solo gating (the `gated` computation above)
happens in a *different* function, entirely downstream of the compensation
plan, and only zeroes `mixer.outputVolume` after PDC has already been decided.

Putting the two findings together: **if "instrumental" is implemented by
passing the engine the *same, full* `tracks` array with a transient,
non-persisted copy of the excluded track(s) forced to `isMuted = true`, the
automatic PDC plan `renderOffline` computes is provably the correct
full-session plan — the compensation survey cannot see the mute flag, so it
cannot be affected by it.** There is no `forcedCompensationTargets` plumbing to
write; the hazard `render.stems` had to engineer around does not arise here,
by construction, because the array size/order/latency profile is untouched and
the one thing that changes (mute) is invisible to the exact function that
would need to see it to misbehave. This is cheaper to build **and** more
directly correct than a subset-render approach — it is literally "mute the
vocal, then bounce," minus the project-mutation, minus the two extra round
trips, minus the risk of forgetting to un-mute.

**The proposal.** `excludeTrackIds: [UUID]?` on `render.bounce` (mirror on
`render.mixdown` for parity with the raw/fast path). Mechanism: build a
render-local copy of `tracks` with `isMuted` forced true for the named ids
(never touches `Track.isMuted` in the persisted model, never dirties the
project, safe to call while the user has the same project open live). Response
adds an honesty field — `excludedTracks: [String]` on `BounceResult` /
`MixdownResult` — naming what was silenced, the same pattern this codebase
already uses everywhere else a render omits something (`masterChain:
"excluded"` on `StemExportResult`, `mutedTracksExported` on
`MIDIExportReport`). An unknown id in `excludeTrackIds` throws
`ProjectError.trackNotFound`, consistent with `trackIds` elsewhere.

**Why the model doesn't need a "vocal" role field, and why that's a defensible
choice, not a shortcut.** Grepped `Model.swift` (`:3-6`, `:997-1000`):
`TrackKind` is `audio | instrument | bus` — no role, tag, or category field
anywhere on `Track`. "Instrumental" therefore can only be expressed as
"mixdown minus these explicit track ids"; identifying which track(s) are the
vocal is the caller's job. This is the right call for now, and the reasoning
generalizes past this one rung: **building a heuristic (name-matching "vocal",
"lead vox", track color, etc.) would be more fragile than an explicit
id-based contract**, and this app's positioning is "AI agent tells the DAW
exactly what it means" — an MCP caller that just asked `project.list` or
`track.list` already has the track names and ids in hand and can pass the
right id without any heuristic at all.

**One open sub-question, named rather than glossed over, that should gate the
implementation (not the GO):** does muting a track also silence what it feeds
into a **send** (e.g. a shared reverb bus carrying the vocal's ambience tail)?
`PlaybackGraph.swift:1476-1480` states explicitly, for a **bus** track, that
"mute kills routed audio AND every send into it." The equivalent guarantee is
not spelled out in the same comment for an ordinary track — the snippet at
`:1481-1487` shows the gate value used for `mixer.outputVolume`, but whether
that node sits pre- or post-send-tap in the per-track chain was not settled by
this read (this spike is not an engine read and should not become one, and it
is a different question from the PDC one just settled above — PDC is about
*timing*, this is about *routing topology*). This matters because the entire
value of "instrumental" rests on the vocal's ambience genuinely leaving with
it — a minus-vocal mix with the vocal's reverb tail still audible is a
half-fix that will read as a bug, not a feature. **This one question needs an
`audio-dsp-engineer` confirmation (or a five-minute render-and-listen test)
before `excludeTrackIds` ships**, not a full second design spike — flagging it
now so `m23-m`'s implementer doesn't discover it mid-build.

> **ORCHESTRATOR ADDENDUM, 2026-07-27 — this sub-question is now SETTLED by
> measurement; `m23-m` must not re-open it.** Added by the verifying pass, not
> by the spike's author, who was right to decline an engine read.
>
> **Answer: muting an ordinary track DOES silence its sends, including the
> vocal's reverb tail into a shared bus.** The topology, read off
> `Sources/DAWEngine/PlaybackGraph.swift`:
>
> - The strip is `clip players → sumMixer → chainHost → mixer`, and the doc
>   comment at `:133-141` states that `mixer` carries **fader/pan/mute** and is
>   the **fan-out source**, with sends post-fader.
> - The fan-out is built at `:1030-1049` — every send's gain node plus the main
>   destination are collected into one `points` array — and connected at
>   **`:1067`: `engine.connect(mixer, to: points, fromBus: 0, format: format)`**.
> - So every send tap originates **downstream of the node that applies mute**.
>   The gate at `:1481-1487` sets that node's gain to `0`, which therefore zeroes
>   the sends along with the direct output. The bus-track guarantee at
>   `:1476-1480` is spelled out separately only because a bus's mute is its own
>   *output* gain, a different mechanism — not because ordinary tracks are
>   exempt.
>
> **Consequence for `excludeTrackIds`, and it is a DECISION, not a free win:** a
> transient-mute implementation gives a genuinely clean instrumental — the
> excluded track's ambience leaves with it, which is exactly what §4.4 argues
> the rung is worth. But it also means **there is no way to ask for "instrumental
> with the vocal's reverb retained"** through this parameter. That is very
> probably the right default and matches what the rung is for; it should be
> *stated* in the command's teaching text rather than discovered. If the other
> behaviour is ever wanted it is a separate, differently-shaped feature (a
> pre-fader send tap), not a flag on this one.


### 4.5 Format / bit-depth / sample-rate / normalization + presets

**Bit depth — cheap.** `OfflineRenderer.writeWAV` already builds a `settings`
dict for `AVAudioFile` from `AVAudioFormat.standardFormatWithSampleRate` (Float32)
and overrides one interleaving key (`OfflineRenderer.swift:528-541`). Adding
16/24-bit is a settings-dict change (`AVLinearPCMBitDepthKey`,
`AVLinearPCMIsFloatKey`), not a new subsystem. **Dither is the decision this
forces, and v0 should be honest about it rather than silent**: reducing 32-bit
float to 16-bit integer without dithering adds quantization distortion.
Logic's answer is POWr #1-3 / UV22HR — real psychoacoustic noise-shaping
algorithms, not worth building for a beta-stage v0. The precedent already set
by `render.bounce` ("no limiter in v0", honestly reported via
`limitedByCeiling`) is the model to copy here: **ship a straight
truncate-and-report v0** (a `ditherApplied: Bool` / equivalent field stating
`false`), and file real TPDF/noise-shaped dithering as a named follow-up rather
than pretending truncation is transparent.

**Sample rate — a genuine subsystem, not a param.** The engine renders at its
own working rate; delivering at a caller-chosen rate needs a real sample-rate-
conversion path (an `AVAudioConverter` pass, or reuse of whatever high-quality
resampler this project already vetted for time-stretch —
`docs/research/2026-07-05-time-stretch-library-evaluation.md` is the existing
research to check before reinventing one). This also interacts with the
engine's own device-rate work: `docs/research/2026-07-16-m19k-device-rate-design.md`
(m19-k) is the existing design doc for sample-rate handling elsewhere in the
engine and should be read before scoping this, not re-derived. Deserves its
own design pass, not a same-cycle param bolt-on.

**Container — split cheap from unverified.** WAV is free (today). AIFF is
close to free — same linear PCM payload, a different `AVAudioFile` file-type
constant, no new encode path. Compressed containers are **not** all equal, and
this spike explicitly verified rather than assumed the one claim likely to
bite hardest: **Apple's platform audio stack does not support MP3 *encoding*
on macOS — only decode.** This is a long-standing, licensing-rooted limitation
of CoreAudio/AudioToolbox (`kAudioFormatMPEGLayer3` fails on the write side;
corroborated by multiple Apple Developer Forum threads describing encode
failures and by AudioKit dropping MP3 write support in favor of AAC/CAF/AIFF/
WAV). **Recommendation: never offer MP3 as an export container — it cannot be
built on this platform without a third-party (and likely non-free) encoder,
and Logic's own MP3 bounce works only because Apple licenses that specific
encoder path inside its own app.** AAC (`.m4a`), ALAC, and FLAC (`kAudioFormatFLAC`)
all have documented *write* paths through `AVAudioFile`/CoreAudio (multiple
independent sources describe successful FLAC and AAC writes), but this spike
did **not** empirically test writing each on this codebase's exact
`AVAudioFile` call shape — flagged as "verify before shipping," not "assumed
to work." Sequencing: WAV + AIFF in phase 1 (verified free); AAC/ALAC/FLAC in
phase 2 after a short empirical spike (a few hours, not a design doc); MP3
never.

**Normalization — already covered for the mixdown, deliberately absent for
stems (no change).** The one addition: whatever LUFS/true-peak params
`includeMasteredMixdown` (§4.3) exposes should be **the same param names and
same contract ranges** `render.bounce` already uses (`lufsTarget` ∈ [−70, 0],
`truePeakCeilingDb` ∈ [−20, 0]) — not a parallel, differently-named pair.

**Export presets — the weakest evidence in this spike, said plainly, and
named rather than left unmapped.** Only REAPER is confirmed (primary-source-
adjacent: a changelog line that only makes sense if the feature exists).
Logic, Ableton, and Studio One are **unverified negatives** — no mechanism
surfaced in the docs read, but none of the official manual pages fully answer
the question either (Studio One's manual site was mid-migration and
unreachable during this spike). The case for building presets here does not
need to lean on the competitive claim at all: the actual argument is our
own — an agent asked to "deliver the standard set" benefits from naming that
set once. The proposed shape, named so the gate has a command to point at
even though it is scheduled for later:

```
export.savePreset   { name: string, spec: { stems?: {...render.stems params...},
                       masteredMixdown?: bool, instrumental?: { excludeTrackIds },
                       midi?: bool, bitDepth?, container? } }  -> { presetId }
export.listPresets  { }  -> { presets: [{ presetId, name, spec }] }
export.applyPreset  { presetId, directory }  -> runs the saved primitive calls,
                       returns the same per-rung reports each primitive would
```
(MCP twins: `export_save_preset`, `export_list_presets`, `export_apply_preset`.)

But **this app is MCP-native in a way none of the four surveyed DAWs are**: an
agent (Claude, via MCP) can already hold "the delivery preset" as a remembered
sequence of primitive calls (stems + mastered mixdown + instrumental + MIDI,
in whatever format/depth the user asked for) without any app-side persistence
at all. That lowers the urgency of the subsystem above relative to a
traditional DAW, where the user has no equivalent "memory" to lean on.
Recommendation: **name the three commands (done, above), but defer building
them past `m23-m`** — not because they're undesirable, but because the MCP
layer already covers the ergonomic need for now, and building persistence
(storage location, project-scoped vs user-scoped, versioning against future
rungs) is real subsystem work that competes with the concrete, cheap wins
above for the same cycle. This is a scheduling decision, not an unmapped rung.

### 4.6 A one-call "export the whole ladder" command

Not asked for explicitly by the roadmap line, but implied by "a complete
export set" and worth naming as a *phase 3* candidate rather than silently
omitting: a `project.exportDeliverySet` (or similar) that runs MIDI export +
stems + mastered-mixdown-alongside-stems + instrumental in one call, given a
directory and a small option set. This is explicitly **not** phase 1 — it's a
thin orchestration layer over everything else in this document, and it only
makes sense once the primitives above exist, and more so once `export.applyPreset`
(§4.5) exists to give it something to apply. Naming it now so `m23-m`'s scope
doesn't quietly grow to include it.

---

## 5. GO / NO-GO recommendation

**GO**, phased. No rung is left unmapped (§3 — including presets, which gets
named commands even though deferred), and no phase below is hedged — each is a
scope line, not a "maybe."

**Phase 1 — `m23-m` itself. All of it is a parameter on an existing verb; no
new subsystem.**
- `render.stems`: add `includeMasteredMixdown`, `masteredLufsTarget`,
  `masteredTruePeakCeilingDb` (§4.3).
- `render.bounce` (+ `render.mixdown` for parity): add `excludeTrackIds`
  (§4.4), gated on the audio-dsp-engineer send-path confirmation named there.
- `render.bounce` / `render.mixdown` / `render.stems`: add `bitDepth` (16/24/32,
  default unchanged) with a `ditherApplied: false`-and-truncate v0 policy, and
  `container` (wav/aiff, default wav) (§4.5).
- File-menu entry for `track.exportMIDI` (single-track / selection export),
  cheap and UI-only (§4.1).

**Phase 2 — a short empirical spike, not a design doc, then build.**
- Sample-rate conversion (own item; touches the time-stretch/resample
  literature already surveyed and the m19-k device-rate design; interacts with
  m19-k proper).
- AAC/ALAC/FLAC write-path verification on this exact `AVAudioFile` call
  shape, then wire the confirmed containers (never MP3).
- Real dithering (TPDF at minimum; POWr/UV22HR-class noise shaping is a
  stretch goal, not a requirement) to replace the phase-1 truncate-and-report.

**Phase 3 — explicitly out of `m23-m`'s scope, named so it isn't lost.**
- `export.savePreset` / `export.listPresets` / `export.applyPreset` (§4.5) —
  deferred per the MCP-native reasoning there, not abandoned.
- `project.exportDeliverySet` one-call orchestration (§4.6), which depends on
  the preset commands existing to be worth building as a distinct verb rather
  than an agent-side loop over the phase-1 primitives.

**Don't build, with reasons, stated so they aren't silently reopened later:**
- **Baking the shared master chain into individual stems** (Ableton's
  checkbox). Mathematically incompatible with the sum-to-mixdown invariant for
  any nonlinear chain; not the industry norm (3 of 4 surveyed DAWs keep it
  separate); actively the subject of "don't do this" guidance where it does
  exist. See §4.3.
- **MP3 export**, ever, on this stack — no macOS encode path exists outside a
  licensed/third-party encoder. See §4.5.
- **Heuristic vocal/role detection** ("guess which track is the vocal"). The
  model has no role field; an explicit `excludeTrackIds` contract is more
  honest and strictly more reliable for an MCP caller that already has track
  ids in hand. See §4.4.
- **A full psychoacoustic dither-algorithm suite** in v0. Truncate-and-report
  is honest and cheap; POWr-class noise shaping is real DSP work with no
  evidence beta users are blocked without it yet.

---

## 6. Actionable takeaways (for `m23-m`)

1. Implement `render.stems`' `includeMasteredMixdown` / `masteredLufsTarget` /
   `masteredTruePeakCeilingDb` exactly as scoped in §4.3 — and write the
   "never a shared flag with `includeMixdown`" naming-discipline note directly
   into the code comment, not just this doc, since that is the single most
   likely accidental-Ableton-footgun bug in the item.
2. Implement `excludeTrackIds` on `render.bounce`/`render.mixdown` per §4.4's
   mute-copy mechanism (not a subset-array approach — the PDC-survey-is-
   mute-blind citation there is why the mute-copy needs no forced-targets
   plumbing). Get the sends-survive-mute question answered by
   `audio-dsp-engineer` (or a direct render-and-listen check) before merging,
   not after.
3. Implement `bitDepth`/`container` (wav/aiff only) on all three render verbs
   with the truncate-and-report dither policy; file the real-dither and
   AAC/ALAC/FLAC verification as explicit phase-2 follow-up items, not silent
   scope creep into `m23-m`.
4. Add the File-menu entry for a single-track/selection MIDI export
   (`track.exportMIDI` UI path) — cheapest item in the whole ladder.
5. File `export.savePreset`/`export.listPresets`/`export.applyPreset` and the
   one-call delivery-set command as their own future roadmap line(s),
   explicitly out of `m23-m`, per §5 Phase 3.
6. Every new param above ships with its MCP twin and a test, per this
   project's standing convention — none of the six proposed params are
   exempt.

---

## Appendix: sources consulted

- Apple Support, "PCM bounce options in Logic Pro" —
  https://support.apple.com/guide/logicpro/lgcpb7e35135/mac
- Apple Support, "About dithering algorithms in Logic Pro" —
  https://support.apple.com/guide/logicpro/lgcp44da971f/mac
- Apple Support, "Export MIDI regions as MIDI files in Logic Pro for Mac" —
  https://support.apple.com/guide/logicpro/lgcp77376cad/mac
- Sound On Sound, "Logic Pro: Exporting Stems With Track Stacks" —
  https://www.soundonsound.com/techniques/logic-pro-exporting-stems-track-stacks
- Sound On Sound, "Logic Pro Bouncing And Export Options" —
  https://www.soundonsound.com/techniques/logic-pro-bouncing-and-export-options
- Ableton Help, "Importing and exporting stems" —
  https://help.ableton.com/hc/en-us/articles/360000843404-Importing-and-exporting-stems
- Ableton Help, "Understanding MIDI files" —
  https://help.ableton.com/hc/en-us/articles/209068169
- Loop Community, "How to Export Stems in Ableton Live" —
  https://loopcommunity.com/blog/2018/06/exporting-stems-in-ableton-live/
- REAPER Update Summary Guide, versions 6.68→6.72 (`dlz.reaper.fm`) —
  https://dlz.reaper.fm/userguide/REAPER%20main%20changes%20668%20to%20672.pdf
- REAPER Accessibility Wiki, "The render and Consolidate/Export Tracks
  Dialogs" —
  https://reaperaccessibility.com/wiki/The_render_and_Consolidate/Export_Tracks_Dialogs
- PreSonus Knowledge Base, "Studio One - Is there an easy way to export stems
  in S1?" —
  https://support.presonus.com/hc/en-us/articles/210044093-Studio-One-Is-there-an-easy-way-to-export-stems-in-S1
- PreSonus forum thread title (body unreachable, forum decommissioned
  Nov 2024), "Exported Stems sound different from Master Mixdown" —
  https://forums.presonus.com/viewtopic.php?t=37257
- Apple Developer Forums, MP3/AAC read-write limitation threads (encode not
  supported for MP3) —
  https://developer.apple.com/forums/thread/787004 ,
  https://developer.apple.com/forums/thread/676352
- `kAudioFormatFLAC` — Apple Developer Documentation —
  https://developer.apple.com/documentation/coreaudiotypes/kaudioformatflac

### In-tree sources re-read for this spike

- `Sources/DAWCore/ProjectStore+Render.swift` (full file, 300 lines)
- `Sources/DAWEngine/OfflineRenderer.swift:480-556` (`writeWAV`, `renderToWAV`)
- `Sources/DAWCore/Model.swift:3-6` (`TrackKind`), `:997-1003` (`Track`)
- `Sources/DAWEngine/PlaybackGraph.swift:1271-1342` (`recomputeCompensation` —
  confirmed mute-blind), `:1420-1500` (mute/solo gain gating, downstream of PDC)
- `Sources/DAWEngine/AudioEngine.swift:1200-1215` (parallel gating logic)
- `Sources/DAWCore/Loudness.swift:163-180` (`BounceResult`)
- `Sources/DAWCore/Model.swift:1898-1910` (`MixdownResult`)
- `Sources/DAWCore/ProjectStore.swift:4990-5000` (`renderMixdown`)
- `Sources/DAWControl/Commands.swift:659-661` (`track.setMute`),
  `:2675-2810` (`render.mixdown`, `render.measureLoudness`, `render.bounce`,
  `render.stems` wire handlers)
- `docs/research/m23-k4a-midi-export-design.md` (naming convention precedent,
  report-idiom precedent, D-MIX reasoning)
- `docs/ROADMAP.md` (m23-l's own premise patch, M23's ordering line)
