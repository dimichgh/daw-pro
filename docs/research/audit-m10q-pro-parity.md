# Pro-parity audit vs Logic Pro / Ableton Live (m10-q)

Date: 2026-07-11
Author: research-analyst (agent)
Scope: the ten seeded candidates from `docs/ROADMAP.md` (m10-q), audited against DAW Pro's actual code/wire state (not assumptions), plus current-2026 Logic Pro and Ableton Live behavior verified via web search. Docs-only — no code changes. Output = a prioritized M11 candidate list.

Ground-truth sources read directly for this audit: `docs/FEATURES.md`, `docs/ROADMAP.md` (M0–M10 full text), `docs/ARCHITECTURE.md` (command table + engine invariants), `Sources/DAWControl/Commands.swift` (`allCommands`, counted at **108**, not the stale "102" printed in `FEATURES.md`'s count section — `Commands.swift` is the wire-truth per the task brief), `Sources/DAWCore/Model.swift` (`TransportState`, `Clip`, `TimeSignature`), `Sources/DAWCore/UndoJournal.swift`, `Sources/DAWCore/ProjectStore.swift` (`moveClip`, `setClipGain`), `Sources/DAWCore/Automation.swift` (`AutomationTarget`), `Sources/DAWAppKit/AutomationLaneModel.swift`, `Sources/DAWApp/TransportBar.swift`, `mcp-server/src/server.ts` (111 tools confirmed by count). Two FEATURES.md entries are now **stale documentation**, not real gaps — loop-region UI shipped in m10-g and track-rename UI shipped in m10-i, but the Limitations table still marks both "wire-only." Flagging for `docs-scribe`, not treating as gaps here.

---

## 1. Per-feature audit

### 1.1 Session markers (arrangement markers/locators)

**DAW Pro today:** absent entirely. Grepped `marker`/`Marker` across all of `Sources/` — the only hit in `DAWCore` is an unrelated comment about take-group membership ("group marker"). No `Marker` type, no command, no ruler affordance. `TransportState` (`Model.swift:842`) carries loop/punch regions but nothing named or positioned for arrangement navigation.

**Logic Pro:** a first-class Marker global track (alongside Tempo/Time-Signature/Key-Signature/Chord tracks) — named, colored tags on the timeline, used for navigation and export reference points ([Apple Support: markers, time/key signatures, tempo](https://support.apple.com/guide/logicpro-ipad/intro-to-markers-signatures-and-tempo-lpipe08cc0a2/ipados)).

**Ableton Live 12:** "Locators" in Arrangement View — set live during playback/recording, named (Intro/Verse/Chorus/Bridge/Solo convention), Previous/Next-locator navigation, "Loop to Next Locator" ([Ableton Arrangement View manual](https://www.ableton.com/en/manual/arrangement-view/)).

**Gap size:** total (model + wire + UI all missing).

**Why a pro cares:** the single most common "am I looking at the right part of the song" affordance; also needed for structured export/reference and for an agent to reason about song sections in AI-native language ("regenerate the chorus" needs the DAW to know where the chorus is).

**Effort:** S–M. Pattern-matches the loop-ruler UI already shipped (m10-g, 19 headless tests + ruler gesture glue): a `[{beat, name, color?}]` list on the project (or `TransportState`), `markers.add/remove/rename/list` wire commands, ruler-row UI reusing the `LoopRulerModel` zone-hit-test idiom. No engine/render-thread involvement (pure metadata, like loop points).

**Recommended M11 priority: HIGH.**

---

### 1.2 Tempo track + time-signature changes

**DAW Pro today:** `TransportState` (`Model.swift:842-901`) carries exactly **one** `tempoBPM: Double` (range 20–400 per `tempoRange`, though `FEATURES.md` line 30 says "20–300 BPM" — a second stale-doc nit) and exactly **one** `timeSignature: TimeSignature` for the whole project. There is no tempo map, no list of tempo/meter changes at beat positions. `transport.setTempo` mutates the single global value. This is a genuinely pervasive assumption — beat↔seconds conversion (`positionSeconds`, `sourceWindowSeconds(tempoBPM:)`, the MIDI scheduler, PDC, the automation renderer, loudness/render offline math) all treat tempo as one constant, confirmed by ~20 files referencing `tempoBPM` project-wide.

**Logic Pro:** dedicated Tempo track + Time-Signature track/list — tempo automation curves, per-bar time-signature changes, Smart Tempo can even derive a tempo map from a free recording ([Apple Support: time/key signature overview](https://support.apple.com/guide/logicpro/time-and-key-signature-overview-lgcp6409cfb7/mac); [create time signature changes](https://logicpro.skydocu.com/en/make-global-changes-to-a-project/work-with-time-and-key-signatures/create-time-signature-changes/)).

**Ableton Live 12:** tempo automation via envelopes on the master track, plus time-signature markers droppable anywhere in the Arrangement ("Insert Time Signature Change" via the Create menu) ([Ableton Arrangement View manual](https://www.ableton.com/en/manual/arrangement-view/)).

**Gap size:** total, and architecturally the deepest of the ten — this is not additive metadata like markers, it changes what "a beat" means at every point in the timeline.

**Why a pro cares:** essential for film/game scoring, prog/hybrid genres, live-tempo-matched arrangements, and any song with a tempo ramp or meter change (extremely common even in pop — a 2/4 pickup bar, a half-time breakdown).

**Effort:** L. Requires a real tempo-map data structure, a beat↔seconds evaluator that replaces every single-constant call site (scheduler, PDC, automation, loudness/render, UI ruler math), persistence versioning, and UI for editing the map. Comparable in blast radius to the M4 automation epic (vii-a through vii-e, five sub-items) or larger, since automation touched fewer render-path call sites than tempo would.

**Recommended M11 priority: LOW for M11** (real, but the single biggest lift on this list, and the least AI-native-differentiated — an agent can already ask for "tempo 140" once per song; multi-tempo scoring is a minority pro workflow relative to markers/freeze/undo-history). Worth a dedicated design doc before scoping, not a drive-by M11 item.

---

### 1.3 Count-in / pre-roll

**DAW Pro today:** already shipped, more completely than the roadmap seed implies. `TransportState.countInBars` (`Model.swift:867-874`, clamped 0–4) exists; `transport.setMetronome {enabled, countInBars}` is a real wire command (`Commands.swift:342-351`); M2 shipped it (`ROADMAP.md` M2: "Metronome/click with count-in"). The metronome ON/OFF toggle has a real UI control (`TransportBar.swift:219-246`, signal-green toggle, disabled while recording). The **only** actual gap: `countInBars` itself has no UI affordance — `TransportBar.swift:221` comment says outright "set via the control protocol / MCP (transport.setMetronome countInBars)". A human without an agent cannot change count-in length from 0–4 bars without going through Copilot/MCP.

**Logic / Live:** both expose count-in bar count as a plain UI stepper/preference.

**Gap size:** small — one numeric control missing, everything else (data model, engine behavior, wire) shipped.

**Why a pro cares:** low-stakes; most pros set it once and forget it. It's the kind of thing a beta user notices but wouldn't file as a blocker.

**Effort:** S (a stepper next to the existing metronome toggle, or a context-menu entry — no new wire surface needed since `transport.setMetronome` already accepts `countInBars`).

**Recommended M11 priority: LOW** — cheap, but purely a UI-completeness nit, not a capability gap. Good filler item, not a headline.

---

### 1.4 Track freeze / bounce-in-place

**DAW Pro today:** absent entirely. Grepped `freeze`/`Freeze`/`bounceInPlace`/`sidechain` across all of `Sources/` — every "freeze" hit is unrelated (engine-telemetry "freezes the counters," UI "freeze at the last level," playhead-freeze comments). No track-freeze state, no per-track render-to-file-and-mute mechanism. The closest existing primitive is `render.stems` (per-track WAV export, M5 iv-d) — but that's an export operation, not an in-place CPU-saving swap that keeps the track editable-on-thaw.

**Logic Pro:** two distinct, real features — **Freeze** (bounces to a 32-bit-float freeze file, deactivates the track+plugins, easily reversible/thawable, preserves automation) vs. **Bounce in Place** (renders to a new 24-bit audio track, mutes/replaces the original, more permanent) ([Apple Support: bounce in place overview](https://support.apple.com/guide/logicpro/bounce-in-place-overview-lgcpe2a9f868/mac); [freeze vs. bounce comparison](https://www.theblindlogic.pro/p/the-difference-between-bounce-in-place-and-freezing-tracks-plus-how-why-to-disable-and-enable-a-track)).

**Ableton Live:** has an equivalent Freeze/Flatten pair.

**Gap size:** total.

**Why a pro cares:** CPU-heavy AU-instrument or effect-chain tracks (orchestral libraries, heavy synths) need this to keep a session playable on real hardware; it's a daily-driver feature in any AU/VST-hosting DAW, and DAW Pro already hosts arbitrary AU instruments/effects (`instrument.listAudioUnits`, `fx.listAudioUnits`) — the CPU-pressure scenario this solves is fully reachable today.

**Effort:** M. Bounce-in-place is the cheaper half — it's structurally close to `render.stems` scoped to one track, landing a new audio clip and muting/hiding the source (state machine similar to `ai.importGeneration`'s "render → land a new track/clip in one undo step" pattern). True Freeze (reversible, keeps the original + automation live for later unfreeze) is the harder half — needs a track-level frozen/thawed flag, cached render invalidation on edit, and UI. Recommend shipping **bounce-in-place only** for M11 (reuses `render.stems`-adjacent machinery, single undo step) and deferring true reversible Freeze.

**Recommended M11 priority: MEDIUM-HIGH** — real capability gap with a concrete, moderate-size path (bounce-in-place), directly useful the moment a user hosts a CPU-heavy AU.

---

### 1.5 Sidechain routing

**DAW Pro today:** absent entirely, at every layer. Grepped `sidechain`/`Sidechain`/`externalKey`/`keyInput` across `Sources/DAWEngine/Effects/` and all of `Sources/` — zero hits beyond this audit's own search. The per-strip effects architecture (`EffectRendering` seam, `ChainHostAU`, M4-ii) is built around **one audio input per strip** — each strip's chain processes only that strip's own signal. There is no mechanism today for a second track's signal to reach another strip's compressor/gate as a key input.

**Logic Pro:** sidechain input selectable on any dynamics processor (Compressor, Noise Gate, Multipressor, etc.) via a routing menu.

**Ableton Live 12:** sidechain on the stock Compressor (and any dynamics device that supports it) via a routing dropdown revealed by the sidechain toggle; Live 12 specifically improved sidechain routing onto Group tracks/buses ([Sidechaining in Ableton 12](https://magneticmag.com/2025/12/sidechaining-in-ableton-12/); [Ableton Routing and I/O manual](https://www.ableton.com/en/manual/routing-and-i-o/)).

**Gap size:** total, and architecturally invasive — unlike every other candidate on this list, this is not additive metadata or a UI layer on an existing engine capability. It requires piping a second signal into an effect node inline in the per-strip chain, which breaks the current "each insert chain only ever sees its own strip's audio" invariant that `ChainHostAU`/`EffectRendering` was built around.

**Why a pro cares:** the single most common EDM/pop mixing technique (kick-ducking-bass, kick-ducking-pads) — arguably the most-requested "missing knob" for any producer doing club/dance genres.

**Effort:** L. Needs a design pass before implementation (how does a second audio stream reach a Tier-1 render-thread effect node without violating the RT-safety invariants in `ARCHITECTURE.md`'s audited section — no allocation/locks on the render path — likely a preallocated aux-tap per key-source, wired at graph-build time like the existing bus/send topology). Real, but this is the kind of item that needs its own `docs/research/design-*.md` spike (the `vi-b` AU-window precedent) before it's roadmapped, not a same-cycle build.

**Recommended M11 priority: MEDIUM** — high pro demand, but do not underestimate the engine-architecture cost; recommend a design spike as the M11 unit of work, not the full feature.

---

### 1.6 MIDI CC lanes

**DAW Pro today:** absent more completely than the roadmap phrasing ("MIDI CC lanes... gap is UI") suggests — this is **not** a UI-only gap. `MIDINote` (referenced throughout `Model.swift`/`Clip.notes`) stores only pitch/velocity/startBeat/lengthBeats; there is no CC/pitch-bend/aftertouch storage anywhere in the `Clip` model. Separately, `AutomationTarget` (`Automation.swift:18-27`) has four cases (`volume`, `pan`, `sendLevel`, `effectParam`) — no `.midiCC` case — and the UI-layer `AutomationLaneModel` (`AutomationLaneModel.swift`) hard-codes only `.volume`/`.pan` in its own picker enum, so even the two targets the wire already supports (`sendLevel`, `effectParam`) have no UI path to create a lane, a detail `FEATURES.md` undersells by marking effect-param automation "Shipped (partial)." `FEATURES.md`'s own Limitations table already lists "MIDI CC / learn — Not yet," confirming this is a known, not new, gap — but the audit found it's a **model** gap, not just a UI gap.

**Logic Pro:** full MIDI CC editing (Piano Roll CC lanes, Event List, hardware MIDI-learn to any parameter).

**Ableton Live 12:** MIDI CC as clip envelopes (draw/edit any CC number directly on a MIDI clip, same envelope-editor idiom as track automation) plus a new "CC Control" utility device in Live 12 for outbound CC ([Ableton MIDI CC in Live](https://help.ableton.com/hc/en-us/articles/360010389480-Using-MIDI-CC-in-Live); [Clip Envelopes manual](https://www.ableton.com/en/live-manual/12/clip-envelopes/)).

**Gap size:** total (model + wire + UI). Bigger than the roadmap seed implied.

**Why a pro cares:** expression pedals, mod wheel, filter sweeps recorded from a controller, hardware synth parameter automation — table stakes for anyone using a real MIDI keyboard/controller (which DAW Pro already supports at the transport level — `midi.listInputs`, M3-vii hardware input).

**Effort:** L, correcting the roadmap's implicit sizing. Needs: (a) a `MIDINote`-adjacent CC-event storage shape on `Clip` (new Codable field, persistence-version bump), (b) a CC-lane editor in the Piano Roll (new Canvas view, distinct from the existing velocity lane which is note-attached not time-continuous), (c) `clip.setCC`-shaped wire command + MCP tool, (d) recording-path capture of incoming CC from `midi.listInputs` sources into the new storage. MIDI-learn/hardware-to-parameter mapping is a separate, even larger feature (would need a mapping-mode UI across every knob in the app) — recommend scoping M11 to CC **lane display/edit only**, not learn.

**Recommended M11 priority: MEDIUM** — genuinely wanted by anyone with a controller, but is the second-largest lift on this list after tempo-map; needs its own design pass, similar sizing to the M4 automation epic.

---

### 1.7 Groove-template UI

**DAW Pro today:** the engine is fully shipped and wire-complete — `Sources/DAWCore/Groove.swift` (`GrooveTemplate.extract`), `ProjectStore.grooveTemplates` (persisted, undo-covered), `groove.extract`/`groove.list`/`groove.remove` wire commands + 3 MCP tools, built-in MPC swing presets (`swing8`/`swing16`, 8 canonical values), and the `groove` param already wired into both `clip.quantize` and `clip.quantizeAudio` (`ARCHITECTURE.md`'s `groove.*` deep-dive, M5 iii-g). Grepped `groove`/`Groove` across `Sources/DAWApp` and `Sources/DAWAppKit` — the only hits are false positives (a fader's visual "groove" channel graphic, and one Explain-copy use of the word colloquially). **There is zero UI surface for grooves** — not even a menu entry inside the quantize flow to pick a groove by name.

**Logic Pro:** groove templates extractable from any region, applied via the region inspector.

**Ableton Live 12:** the Groove Pool — a persistent, always-visible panel; drag any clip in to extract, drag any groove from the browser onto a clip to apply, **non-destructive and live-adjustable** (timing/random/velocity knobs continue to affect playback, Hot-Swap to preview alternatives while a clip plays, a separate "Commit" step bakes it in only when wanted) ([Ableton Using Grooves manual](https://www.ableton.com/en/manual/using-grooves/)).

**Design nuance worth flagging (not in scope per the roadmap's framing, but material to sizing):** DAW Pro's groove application is **destructive-on-apply** — it rides `clip.quantize`/`clip.quantizeAudio`, which bakes the groove into notes/audio slices immediately. Live's model is non-destructive and continuously adjustable until committed. Matching Live's live-adjustable model would be a bigger, different feature than "add a picker UI on top of what exists." A UI that exposes the *existing* bake-on-apply model (pick a groove name → apply to selection) is the honest, in-scope M11 unit.

**Gap size:** UI-only, exactly as the roadmap framed it (engine is real and wire-complete) — but note the destructive-vs-live design gap above for anyone scoping beyond "add a picker."

**Why a pro cares:** groove/swing feel is a daily beat-programming tool; right now this entire, already-built capability is invisible to anyone not using Copilot/MCP — an unusually large "hidden feature" for this product.

**Effort:** S. All backing logic exists; this is a groove-name picker (list from `groove.list`) wired into the existing quantize UI surface (wherever quantize strength/swing/grid are already exposed) — no new domain model, no new wire command.

**Recommended M11 priority: HIGH** — best effort-to-payoff ratio on this entire list: real, tested, wire-complete engine work sitting completely unused by anyone without an agent.

---

### 1.8 Undo-history panel

**DAW Pro today:** the underlying data is already fully modeled and just not exposed. `UndoJournal` (`Sources/DAWCore/UndoJournal.swift`) keeps a real labeled stack — `undoStack`/`redoStack: [UndoEntry]` (`label`, coalescing `key`, `before` snapshot), capped at 100 entries (`defaultCap`), with correct coalescing-window and barrier semantics. But `ProjectStore` only exposes the **single top label** via `undoLabel`/`redoLabel` (used for Edit-menu item titles), and the wire only has `edit.undo`/`edit.redo` (`Commands.swift:234-235, 2193-2203`) — one step at a time, no way to see or jump to an arbitrary point in history.

**Logic Pro:** a real Undo History window (`Edit > Undo History`, ⌥⌘Z) — a time-ordered, clickable list of every undoable action; selecting a past entry undoes/redoes everything between there and now in one action; step cap configurable up to 200 ([Apple Support: undo and redo](https://support.apple.com/guide/logicpro/undo-and-redo-edits-lgcp1dbd67ab/mac)).

**Ableton Live:** linear undo/redo only, no visual history list — so DAW Pro is already at *Live* parity here; the gap is specifically against *Logic*.

**Gap size:** small at the data layer (everything needed already exists in `UndoJournal`), real at the wire+UI layer (nothing reads/exposes it).

**Why a pro cares:** recovering from "I made six more changes after the one I actually wanted to undo" without hammering ⌘Z six times and manually replaying the good changes — a real quality-of-life feature, not cosmetic.

**Effort:** S. This is the cheapest real capability gap on the entire list: add a read command (`edit.history` → `{undoStack: [{label}], redoStack: [{label}]}`, or similar), and either (a) a jump-to-index primitive in `ProjectStore`/`UndoJournal` (pop N times, or add a direct-index restore), or (b) ship the read-only list first and let the UI drive N sequential `edit.undo`/`edit.redo` calls — genuinely a small addition given the data model is complete. Comparable to the `engine.watchdogStatus`-class "expose existing internal state" commands already shipped in M9.

**Recommended M11 priority: HIGH** — cheapest real win on the list, directly maps to something the underlying journal already tracks correctly.

---

### 1.9 Per-clip gain envelopes UI

**DAW Pro today:** this is a bigger gap than "missing UI" — there is no per-clip envelope **model** at all, only a single scalar. `Clip.gainDb` (`Model.swift:209-211`) is one `Double` (−72…+24 dB) applied uniformly across the whole clip, plus separate `fadeInBeats`/`fadeOutBeats` with curve types (linear/equal-power) at the head/tail only (`Model.swift:212-221`). There is no multi-point breakpoint gain curve *within* a clip. Separately, DAW Pro *does* have real breakpoint automation — but it's **track**-scoped, not clip-scoped: `automation.addLane` requires a `trackId` (`Commands.swift:802-811`), and the Arrange breakpoint editor (M4 vii-e) draws volume/pan lanes per track, spanning the whole timeline, not per individual clip. So "per-clip gain envelope" is architecturally a third thing DAW Pro doesn't have, distinct from both existing mechanisms.

**Logic Pro / Ableton Live:** both let you draw a multi-point gain curve directly on an individual clip/region (Live: the clip's own Volume "Clip Envelope," drawn in the same breakpoint idiom as track automation but scoped to that one clip; Logic: region gain/volume automation similarly clip-scoped).

**Gap size:** total at the model layer, not just UI. `FEATURES.md`'s "Clip gain ✅ Shipped" entry describes the scalar-only reality accurately; this candidate is asking for something categorically new.

**Why a pro cares:** riding a vocal's level through a phrase, taming one loud syllable, ducking under a transient — this is finer-grained and far more common in daily editing than track-wide automation; a scalar + two fades can't express "quieter in the middle, louder at the end."

**Effort:** M. Needs: a new `[GainPoint]`-shaped field on `Clip` (persistence-additive, the `gainDb`-omitted-when-0 precedent), a pure evaluator (`value(atLocalBeat:)`, mirroring `AutomationLane.value(atBeat:)`'s existing pattern almost exactly — same interpolation code shape, different scope), an engine render-path hookup (extending the existing per-sample gain-ramp machinery from M4 vii-b to read from the clip's envelope when present, falling back to the scalar `gainDb` otherwise), a `clip.setGainEnvelope`-shaped wire command + MCP tool, and a Canvas breakpoint editor reusing the Arrange automation lane's drawing idiom scoped to one clip's width. Real work, but every piece has a close precedent already shipped (M4's automation epic, `ClipWaveform`'s per-clip Canvas overlay pattern from M5).

**Recommended M11 priority: MEDIUM-HIGH** — a real, frequently-felt daily-editing gap with strong precedent to build from.

---

### 1.10 Crossfade tool (arrange-level)

**DAW Pro today:** confirmed the roadmap's framing precisely — `take.setCrossfade` (`ARCHITECTURE.md`'s `take.*` deep-dive) only operates at comp-segment boundaries *inside* a take group. For ordinary clips, the audit found something worth flagging beyond "no tool exists": `ProjectStore.moveClip` (`ProjectStore.swift:1962-1972`) performs **no overlap check at all** — two ordinary (non-take-group) clips on the same track can be freely dragged into overlap via `clip.move`, and nothing in the engine auto-crossfades them; they simply sum (both play back simultaneously, no fade, in the overlap zone). The only place DAW Pro auto-groups overlapping clips into a take group is the **recording** path (`ProjectStore.swift:517`, `finishTake`) — a clip placed by hand via `clip.move`/`clip.addAudio` never gets that treatment. So this isn't just "missing a drag-a-crossfade-handle tool" — ordinary overlap today produces a genuinely rough, unintended-sounding result (silent volume doubling), not a graceful degradation.

**Logic Pro:** a dedicated Crossfade tool for overlapping regions on the same track — drag one region over another, apply the Crossfade tool, get an equal-power (or other curve) blend.

**Ableton Live 12:** overlap two clips on the same Arrangement track, drag a fade handle over the adjacent clip's edge (or use the "Create Crossfade" command over a selected boundary range) — same equal-power blending idiom, curve-adjustable via a slope handle ([Ableton crossfades in Arrangement View, Sound on Sound](https://www.soundonsound.com/techniques/creative-crossfades-ableton-live); [Ableton forum: crossfade between clips](https://forum.ableton.com/viewtopic.php?t=134576)).

**Gap size:** total for ordinary clips; comp-lane crossfades (the take-group case) are genuinely shipped and out of scope, exactly as the roadmap noted.

**Why a pro cares:** basic comping/editing hygiene — joining two audio takes or looping a region without a click/pop at the seam is one of the most frequent micro-edits in any DAW session.

**Effort:** S-M. DAW Pro already has the DSP primitive — `AudioQuantize.swift`'s "CompFlattener mechanism" produces equal-power crossfades at compressed slice joins, and `take.setCrossfade`'s comp-boundary crossfade is the same shape at the take layer. The M11 unit of work is: (a) detect/allow ordinary-clip overlap without doubling volume by default (either auto-crossfade the overlap region using the existing equal-power math, or reject the overlap with an actionable error until a crossfade is requested — a design decision, not new DSP), (b) a `clip.setCrossfadeAt`-shaped wire command (or extend `clip.setFades`) for the explicit case, (c) drag-to-crossfade UI reusing the existing fade-handle idiom already shipped for clip fades. Smaller than it looks because the DSP is a two-time precedent already (audio quantize splices, take comp).

**Recommended M11 priority: MEDIUM-HIGH** — real editing-hygiene gap, DSP precedent already exists twice over, and the silent-overlap-doubling behavior is arguably a latent correctness bug worth fixing regardless of the "tool" framing.

---

## 2. Prioritized M11 candidate list

Ranked, filtered through DAW Pro's actual thesis — radically simpler than Logic + AI-native + full MCP control. Every item states its wire/MCP implication since every capability here ships app + wire + MCP + test together (per `CLAUDE.md` conventions).

1. **Groove-template UI** — HIGHEST. Best payoff-to-effort ratio on the list: `groove.extract/list/remove` + the `groove` param on `clip.quantize`/`clip.quantizeAudio` are already fully wire/MCP-complete and tested; this is UI-only (a picker over `groove.list`, no new command). Ships a real, already-built feature to non-agent users for the first time. *Wire/MCP: none new — pure UI wiring onto existing commands.*

2. **Undo-history panel** — HIGH. Cheapest real capability gap: `UndoJournal` already tracks a correct, labeled 100-entry stack; needs one new read command (e.g. `edit.history`) plus a UI list, and possibly a jump-to-index primitive. Directly closes a Logic-parity gap (Live doesn't even have this, so it's differentiation, not just catch-up) with minimal risk. *Wire/MCP: one new command (`edit.history`) + one new MCP tool; possibly a second command if jump-to-index ships beyond read-only.*

3. **Session markers** — HIGH. Total gap today, but small/medium effort with a direct precedent (m10-g's loop-ruler UI shipped the exact same "ruler-row hit-testing + metadata list" shape). High pro-visibility item that also serves the AI-native thesis directly — an agent reasoning about "the chorus" or "bar 32" needs named markers to point at, which today it structurally cannot create or read. *Wire/MCP: new namespace, e.g. `marker.add/remove/rename/list` (4 commands + 4 MCP tools) — pure metadata, no engine/render-thread change.*

4. **Crossfade tool (arrange-level) — and fix the silent overlap-doubling** — MEDIUM-HIGH. Real editing-hygiene gap with DSP precedent already shipped twice (audio-quantize slice crossfades, take-comp crossfades); the audit surfaced that today's ordinary-clip overlap is a rough, unintended-sounding bug (silent volume doubling on `clip.move`-created overlap), which raises this above a "nice to have" — it's closer to a correctness fix wearing a feature's clothes. *Wire/MCP: one new/extended command (e.g. `clip.setCrossfadeAt` or an extension to `clip.setFades`) + matching MCP tool.*

5. **Track bounce-in-place** (not full reversible Freeze) — MEDIUM-HIGH. Directly useful the moment a pro hosts a CPU-heavy AU instrument (already fully supported — `instrument.listAudioUnits`), moderate effort by reusing `render.stems`-adjacent single-track render + one-undo-step land pattern (the `ai.importGeneration` precedent). Recommend scoping OUT true reversible Freeze (state machine + cache invalidation) for a later milestone. *Wire/MCP: one new command (e.g. `track.bounceInPlace`) + one new MCP tool.*

6. **Per-clip gain envelope** — MEDIUM-HIGH, ranked below bounce-in-place/crossfade only because it's a larger build (new model field + render-path hookup) even though every piece has a close precedent (M4's automation evaluator, M5's per-clip Canvas overlay pattern). A frequently-felt daily-editing gap once a beta user starts fine-editing vocals. *Wire/MCP: one new command (e.g. `clip.setGainEnvelope`) + one new MCP tool; additive `Clip` persistence field.*

7. **MIDI CC lanes** — MEDIUM, downgraded from the roadmap's implicit "UI gap" framing because the audit found it's actually a **model** gap (no CC storage on `Clip` at all) plus a UI gap plus a recording-capture gap — closer in size to the M4 automation epic than a single UI item. Real value for anyone using a hardware controller (which the app already supports at the transport level), but recommend an explicit design/sizing pass before committing to an M11 slot; scope to CC lane display/edit only, defer MIDI-learn. *Wire/MCP: new model field on `Clip` (persistence-version bump) + `clip.setCC`-shaped command + MCP tool + capture-on-record wiring.*

8. **Sidechain routing** — MEDIUM, high pro-demand (arguably the most-requested single "missing knob" for dance/pop genres) but the most architecturally invasive item that isn't the tempo map — it violates the current one-audio-input-per-strip invariant `ChainHostAU`/`EffectRendering` was built around. Recommend an M11 **design spike** (`docs/research/design-*.md`, the `vi-b` AU-window precedent) rather than committing to full implementation in the same cycle. *Wire/MCP: TBD pending design — likely a `fx.setParam`-shaped extension (key-source track id) once the render-thread routing question is settled.*

9. **Tempo track + time-signature changes** — LOW for M11 specifically because it is the single largest lift on this list (touches beat↔seconds conversion at every render-path call site: scheduler, PDC, automation renderer, offline render/loudness math) and is the least AI-native-differentiated of the ten (an agent already sets tempo once per song trivially via `transport.setTempo`; multi-tempo scoring is a real but minority pro workflow versus markers/freeze/undo-history/groove, which land broad daily value for cheaper). Recommend a dedicated design doc before this ever gets an M-number, not a same-cycle build. *Wire/MCP: likely replaces `transport.setTempo`'s semantics with a tempo-map read/write surface — a breaking-ish wire change needing careful versioning.*

10. **Count-in/pre-roll UI stepper** — LOW priority as a headline item (it's real but tiny — the feature is already fully shipped at the model/engine/wire layer; only a UI stepper for `countInBars` is missing), but essentially free to bundle into whichever transport-bar work happens next. *Wire/MCP: none — `transport.setMetronome {countInBars}` already exists.*

---

## 3. Already triaged — do not re-audit

Three FOLD-IN polish items were banked from earlier M10 items specifically for m10-q and are complete audit scope already (small, separately handled, listed here only so this audit is complete):

- **`installedNotRunning` banner copy** — says "call ai.sidecarStart," which is wire-speak leaking into a user-facing surface (m10-b residual, `Sources/AIServices/SidecarStatus.swift`-adjacent UI copy).
- **Arrange ruler + TRACKS header scroll pinning** — both currently ride the shared vertical scroll introduced in m10-j and scroll away with deep content; proper fix needs a fragile synced separate h-offset for the ruler, deliberately deferred (m10-j residual).
- **`plugin.openUI` soundBank rejection copy** — the rejection string at `Commands.swift:2388` predates sound-bank instruments (m10-n-3) and should be reworded to point at the program browser instead of its stale pre-sound-bank phrasing.

---

## 4. New discovery (beta directive: things nobody asked for)

**Ordinary-clip overlap silently sums instead of failing or fading (found auditing candidate 1.10).** `ProjectStore.moveClip` performs no overlap detection at all for plain (non-take-group) clips — an agent or a user can drag/move two audio clips into an overlapping position on the same track via `clip.move`, and the engine will play both simultaneously with **no crossfade and no warning**, producing an audible volume-doubling artifact in the overlap zone. This is distinct from the "missing crossfade tool" framing in the roadmap seed (candidate 1.10) — it means the *current* behavior of an already-shipped command (`clip.move`) is quietly wrong in an edge case a pro (or an AI agent asked to "tighten up the arrangement") could trigger today without any error surfacing. Recommend folding the fix into the crossfade-tool M11 item (candidate 4 above) rather than treating it as separate roadmap work — same DSP, same command surface — but calling it out explicitly here since it's a correctness issue, not a missing-feature request.

## Actionable takeaways

- Highest-value, lowest-risk M11 opening move: ship **groove-template UI** and the **undo-history panel** together — both are UI work over already-complete, already-tested backends, no new render-thread risk, and both directly demonstrate "AI already had this, humans didn't" which is a good beta-facing narrative.
- **Session markers** should follow immediately after — same shape of work as the just-shipped m10-g loop ruler, and it's the one candidate that most directly serves the AI-native thesis (agents need named song-section anchors to reason about arrangement requests).
- Bundle the **crossfade tool** and the **overlap-doubling correctness fix** into one M11 item — they share DSP and the fix is arguably higher priority than the tool framing suggests.
- **Sidechain** and **tempo-map** both deserve a `docs/research/design-*.md` spike before roadmapping — they are the two items on this list that touch RT-safety invariants (`ARCHITECTURE.md`'s audited section) or pervasive beat-math call sites, and should not be scoped in the same breath as the UI-shaped items above.
- Fold the three FOLD-IN copy fixes (Section 3) into whatever docs-scribe/polish pass follows M11 scoping — they're real but trivial and shouldn't consume a dedicated roadmap slot.
- Flag for `docs-scribe`: `FEATURES.md`'s Limitations table still lists "Track rename UI" and "Loop region UI" as wire-only; both shipped in m10-i/m10-g. Also its Command & Tool Counts section says "Wire commands: 102" — the current `Commands.swift` count is 108 (111 MCP tools, matching `mcp-server/src/server.ts`'s 111 `registerTool` calls). Not part of this audit's scope to fix, but should not survive into M11 planning docs uncorrected.
