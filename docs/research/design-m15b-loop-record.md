# Design note (m15-b): Loop-cycle take recording + record×loop honesty

**Status: DESIGN ONLY — no production code. Gates the m15-b implementation.**
**Author: daw-architect, 2026-07-13.**
**Scope:** ROADMAP m15-b (docs/ROADMAP.md:241) — M5 iii-b loop-cycle take recording, unparked by M14 (design-m13f-gapless-loop.md §6.1), plus the audit-m15 F2/B2 record×loop dishonesty. Every claim about current behavior cites file:line read for this note. Citation drift note: audit-m15 cites the suppression sites at AudioEngine.swift:1302/1533/1720; the file has grown — they now sit at :1317, :1552, :1731 (verified verbatim).

---

## 1. Decision (summary up front)

**GO-WITH-CONDITIONS (§8).** The shape:

1. **Record seeks to loop start.** `record()` with loop enabled sets `positionBeats = loopStartBeat` before freezing the take (§3). Count-in then pre-rolls from the loop start exactly as today's delayed-anchor machinery already does.
2. **The engine plays the loop for real; the capture stays ONE linear take.** Lift both m13-f §6.1 suppression sites: `startTake` schedules WITH the loop window and the playhead wraps modularly on the never-moving M14 anchor. Zero writer/capture-path changes (§5).
3. **Lane-per-cycle is pure store-side slicing at stop.** `finishTake` slices the linear capture at the absolute integrals `k·cycleSeconds` and fans each slice through the EXISTING `autoGroupRecordedTake` path in cycle order — the desired N-lane group with newest-wins comp falls out of machinery that already ships (§4). Mid-cycle stop lands an honest partial last lane.
4. **Wire: zero growth, no flag.** Loop state alone decides; `transport.record` keeps its exact shape. Three new teaching errors (loop×punch, loop-too-short, setLoop-mid-record) and MCP description updates only (§6).
5. **Punch × loop is REFUSED in v1** with a teaching error — the writer's accept window is single-window machinery and per-cycle punch would be new capture machinery for a rare combination (§7).

Two real bugs-in-waiting were found while reading and are folded in as conditions: the MIDI open-note stop clamp would use a MODULAR beat against LINEAR note beats once the wrap is live (§5.3), and the metronome loop top-up under count-in under-feeds by the count-in delay (§5.4).

---

## 2. Ground truth today (evidence)

- **The dishonesty (audit-m15 B2, live-proven):** record with loop [0,4) enabled starts at the playhead and rolls LINEAR while the snapshot reports `isLoopEnabled: true` (audit-m15.md §2-B2). Mechanism: the record path passes `scheduleLoop: false` (AudioEngine.swift:1317), the loop-eligibility guard requires `scheduleLoop, activeTake == nil` (AudioEngine.swift:1552), and the playhead task's legacy-wrap branch requires `activeTake == nil` (AudioEngine.swift:1731). `LoopContext` is "deliberately nil while recording" (AudioEngine.swift:201-208).
- **The M14 enabler:** under a live loop the anchor NEVER moves across wraps — `beat(forElapsedSeconds:)` derives cycle position modularly from one anchor, and the map is only evaluated inside the loop window (AudioEngine.swift:1683-1701). design-m13f §6.1: "Lane-per-cycle is then pure store-side slicing of the linear capture at k·loopSeconds. Zero capture-path changes required."
- **The capture is anchor-aligned and graph-independent:** the writer's accept window is host-time based, set ONCE at `startTake` against `currentAnchor.anchorHostTime` (AudioEngine.swift:1331-1350; RecordingWriter.swift:132-159 — `startOffsetSeconds` measured from the reference). MIDI capture rides the SAME anchor and converts host time → beat LINEARLY through the frozen map (AudioEngine.swift:1352-1367; MIDICaptureSession.swift:83-88); pre-anchor ons are dropped, which is how count-in trims (MIDICaptureSession.swift:47-49).
- **Count-in:** `countInBars` (0–4, Model.swift:1079-1082, :1120) delays the record anchor while the metronome fills the gap (AudioEngine.swift:1311-1315, :1517-1524; `Metronome.countInPlan`, Metronome.swift:131-136). Count-in has NO UI — wire-only via `transport.setMetronome` (TransportBar.swift:219-222; the m10-q §1.3 stepper rider lands with this item).
- **Landing today:** `finishTake` computes the clip start/length via the frozen map's inverse integrals from `startOffsetSeconds`/`durationSeconds` (ProjectStore.swift:634-641), inside ONE `performEdit("Record Take N")` (ProjectStore.swift:659-694), fanning each audio clip through `autoGroupRecordedTake` (ProjectStore.swift:677; ProjectStore+Takes.swift:245-288 — overlap → append lane / form group, comp := newest lane). MIDI clips append plain (ProjectStore.swift:682-691); auto-grouping is AUDIO-ONLY v0 and "Loop-cycle recording is out of scope" (ProjectStore+Takes.swift:229-231). Take groups are per-track model state (Model.swift:639, encoded omit-when-empty, Model.swift:736) with lane payload = a full `Clip` in absolute beats (Takes.swift:14-48).
- **Guards today:** `record()` requires a STOPPED transport (ProjectStore.swift:542-546). Mid-record refusals exist for seek/tempo/tempoMap/punch/metronome/input-device/undo/redo and the announce-capability routing set (ProjectStore.swift:357-359, :778-782, :806-813, :1125-1130) — but **`setLoop` has NO recording guard** (ProjectStore.swift:758-770); it is silently cache-only mid-take today (`loopChanged` returns early with no scheduled loop, AudioEngine.swift:1173).

---

## 3. Q1 — Record-seeks-to-loop-start: YES

**Decision:** when `record()` runs with `isLoopEnabled` (and passes the new guards, §6), the store seeks to `loopStartBeat` first: `transport.positionBeats = loopStartBeat`, then the take freezes `recordStartBeats = loopStartBeat` plus the loop bounds into `PendingTake`.

**UX argument:** the user framed a loop specifically to record over it — Logic and Live both jump to cycle start on record. Recording "from wherever the playhead last sat" is exactly the B2 confusion, and a partial first cycle would land a lane that is not comparable to the others (the whole point of takes is per-cycle comparison). Count-in supplies the pickup bar; a musician who wants lead-in sets `countInBars`, not a mid-loop start.

**Implementation argument:** with `beats == loopStartBeat`, `headSeconds == cycleSeconds` (AudioEngine.swift:1554-1560), so every cycle boundary is the uniform absolute integral `k·cycleSeconds` — the slicer needs no irregular-head case, and store-side eligibility trivially matches engine-side eligibility (after the seek, `beats < loopEndBeat` always holds and `cycleSeconds > 0` is guaranteed by `minLoopLengthBeats`, Model.swift:1123).

**Count-in composes for free:** the anchor is DELAYED by the count-in while the playhead clamps at the record beat (AudioEngine.swift:1517-1524, :1703-1709), the writer trims pre-anchor capture (RecordingWriter accept window) and the MIDI session drops pre-anchor ons (MIDICaptureSession.swift:47-49). So cycle 1 begins exactly at the anchor == loop start, and **count-in produces no lane content** — no special case. The alternative (record from playhead, first cycle partial) loses on both axes and is rejected.

The `transport.record` response already returns the transport encoding (Commands.swift:404-411) — the seek is visible to agents in the response (`positionBeats == loopStartBeat`), for free.

## 4. Q2 — Cycle boundaries → lanes: one linear capture, store-side slicing at stop

**Decision:** the engine keeps ONE linear capture per take (writer + MIDI session untouched); `finishTake` slices per cycle. Evaluated first per the roadmap, and it wins outright: per-cycle writer rotation would put file-close/reopen on the cycle cadence (allocation + I/O against a rolling take, new failure modes per wrap) and buys nothing — the M14 anchor already makes the cycle math exact from one file. **No new writer machinery.**

**Slicing math (audio).** Freeze at record(): `L = tempoMap.seconds(from: loopStartBeat, to: loopEndBeat)` — the same integral as the engine's `cycleSeconds` (AudioEngine.swift:1554). At finalize, `lag = startOffsetSeconds` (capture-start latency vs the anchor) and `D = durationSeconds`. The file covers elapsed `[lag, lag + D)`; cycle k (1-based) covers elapsed `[(k−1)·L, k·L)`. Lane k clip (all map evaluations restricted to the loop window — the timeline law):
- k = 1: `startBeat = tempoMap.beat(from: loopStartBeat, elapsedSeconds: lag)` (exactly today's landing formula, ProjectStore.swift:634-637), `startOffsetSeconds = 0`, length = inverse integral to the cycle end.
- k ≥ 2: `startBeat = loopStartBeat`, `startOffsetSeconds = (k−1)·L − lag` (absolute integral, never accumulated — the m12-c/C3 discipline), full cycle length.
- Last lane: if `lag + D` ends mid-cycle, length = the inverse integral of the partial seconds — **the honest partial lane**; it lands whenever its `lengthBeats > 0` (the existing empty-take guard, ProjectStore.swift:642-651, is the only floor). All lanes share the ONE take file at different offsets — the lane payload supports that natively (Takes.swift:19-21).

**Landing (audio): reuse `autoGroupRecordedTake` verbatim.** Fan the slices through it IN CYCLE ORDER inside the one `performEdit("Record Take N")`: slice 1 joins pre-existing overlapping material or lands plain (today's cases, ProjectStore+Takes.swift:249-287); slice 2 then overlaps slice 1 → forms the group; slices 3..N append lanes; final comp = newest lane full-range (newest-wins, Takes.swift:80-91). N == 1 degrades to EXACTLY today's single-take behavior. Re-recording over a previous loop take appends N more lanes to the same group (case 1) — the Logic comping workflow. Zero new grouping machinery; lane names `"<track> Take <n>.<k>"`.

**MIDI.** Notes were beat-stamped LINEARLY through the frozen map (MIDICaptureSession.swift:83-88) — they run past `loopEndBeat` in later cycles, and slicing in beat space would leak map segments beyond the loop end into cycle timing. Slice in the SECONDS domain by exact inversion: for each note, `e = tempoMap.seconds(from: recordStart, to: recordStart + noteStart)` (the mathematical inverse of the session's conversion), cycle `k = ⌊e/L⌋`, within-cycle beat = `tempoMap.beat(from: loopStartBeat, elapsedSeconds: e − k·L)`. A note belongs to its ONSET cycle and clamps at that cycle's end (the `windowNotes`/stop-clamp precedent, Takes.swift:291-306, MIDICaptureSession.swift:68-72) — v1 policy, documented; matches the audio slice exactly at the boundary. Loop-cycle MIDI lands as a MIDI take group via a small explicit lander in ProjectStore+Takes.swift (all-MIDI groups are already legal — `groupTakes` rejects only MIXED, ProjectStore+Takes.swift:71-74); the non-loop v0 stacking policy is untouched. A cycle with no notes still lands an empty lane (lane index == cycle index); a take with zero notes overall is discarded exactly as today (ProjectStore.swift:648-650).

## 5. Q3 — The two suppression sites, lifted together

1. **`startPlayers(scheduleLoop: false)` (AudioEngine.swift:1317, enforced :1539-1543/:1552):** DELETE the `scheduleLoop` parameter (the record call is its only non-default user) and the `activeTake == nil` term at :1552. `startTake` then builds `LoopContext` exactly like playback — the M14 unroll (audio/MIDI/automation/click top-ups, `serviceLoop`, prune containment) runs during recording with no new code.
2. **Playhead legacy-wrap guard (AudioEngine.swift:1731):** after (1), a loop-enabled record always starts INSIDE the window (the §3 seek), so `loopContext != nil` and the legacy branch is unreachable while recording — delete its `activeTake == nil` term as dead. What KEEPS it dead is a new store guard: **`setLoop` refuses mid-record** ("cannot change the loop while recording — stop first", the m13-c phrasing family, ProjectStore.swift:1125-1130 precedent) — without it, a mid-take bounds edit would reach `loopChanged`'s restart (AudioEngine.swift:1173-1178), killing the writer's anchor mid-capture. This closes the honesty hole rather than re-suppressing it. `metronomeChanged`'s `activeTake == nil` (AudioEngine.swift:1196) is NOT a §6.1 site — it stays as defense-in-depth behind the existing store refusal (ProjectStore.swift:806-813).

**3. Writer non-interaction, confirmed with one found bug.** The capture writer hangs off the input tap, not the playback graph; its accept window references host times computed ONCE from the never-moving anchor (AudioEngine.swift:1331-1350; AudioEngine.swift:201-208). Loop unrolling only queues MORE segments on rolling players — it never touches `currentAnchor` or the flush family (design-m13f §5). **The bug:** `stopRecording` clamps open MIDI notes at `derivedBeats()` (AudioEngine.swift:1437) — MODULAR once the wrap is live, against the session's LINEAR note beats: an open note in cycle 3 would clamp to a cycle-1 beat and collapse to the 0.001-beat floor (MIDICaptureSession.swift:91-93). Fix: a linear variant (the `beat(forElapsedSeconds:)` non-loop branch, AudioEngine.swift:1699-1700) for the capture clamp only; the playhead keeps the modular read.

**4. Metronome under count-in + loop (new interaction).** The comment "loop-context starts never carry a count-in (the record path schedules linear)" (AudioEngine.swift:1644-1645, also :222-227) dies with the lift. Two riders: (a) `serviceLoop` feeds `elapsed − metronomeElapsedOffset` (AudioEngine.swift:1773-1775) but the click player's timeline begins `countIn.delaySeconds` BEFORE the transport anchor — set `metronomeElapsedOffset = −countIn.delaySeconds` on a count-in loop start or the click unroll under-feeds by the count-in (up to 4 slow bars vs the 0.2 s horizon, AudioEngine.swift:230-235 — a real starvation window). (b) the loop plan's `headSeconds` derives from `playerStartBeat` by map INTEGRAL (Metronome.swift:195) while count-in spacing is a record-beat LOOKUP by policy (Metronome.swift:122-136) — pass the count-in delay explicitly so cycle click anchors are `delaySeconds + integral(recordBeat → loopEnd) + k·L`, not an integral across the pre-roll span.

## 6. Q4 — Wire semantics: zero growth, loop state decides

- **No flag.** `transport.record` params unchanged; with loop enabled it seeks, loops, and lands takes — there is no honest use for a `loopTakes: false` opt-out (that is B2 by request; an agent that wants linear recording disables the loop first, one existing call). Command/tool counts stay 120/123.
- **Honesty is structural, not a new field:** while rolling, `isLoopEnabled: true` + a modularly-wrapping `positionBeats` is now TRUE; the record response shows the seek (§3). The audit's proposed `loopSuppressed` field is unnecessary once nothing is suppressed — the contradiction dies by making the claim real.
- **Landed-lane surface (existing):** `project.snapshot` encodes `tracks[].takeGroups` (omit-when-empty) through the Track Codable pass-through (Commands.swift:3802-3806; Model.swift:684, :736) — `{id, name, lanes:[{id, name, clip}], comp:[{laneId, startBeat, endBeat}], crossfadeSeconds}` (Takes.swift:14-131) plus flattened members in `clips` tagged `takeGroupID`. Agents comp with the existing `take.*` verbs. Nothing new.
- **Teaching errors (3):** (i) `record` with loop AND punch both enabled → "recording with both a loop and a punch window is not supported — disable one: loop-cycle takes (transport.setLoop) or punch (transport.setPunch)"; (ii) `record` with `cycleSeconds < TakeGroup.minLoopRecordCycleSeconds` (new constant, **1.0 s** — bounds lane creation at ≤ 60/min; one 4/4 bar at 240 BPM) → "loop is too short for take recording — use a loop of at least 1 second per cycle"; (iii) `transport.setLoop` mid-record → the §5.2 refusal. All via existing error mapping; documented in the `transport.record`/`transport.setLoop` doc comments (Commands.swift:404-431) and the matching MCP tool descriptions (description text only).
- **Undo:** the whole loop take (group + N lanes + comp) stays ONE `performEdit("Record Take N")` entry (§4); undo mid-record remains refused (ProjectStore.swift:3153-3154).

## 7. Q5 — Punch: refuse the combination (defer per-cycle punch)

Punch is one host-time accept window per take (RecordingWriter.swift:139-159, set once at AudioEngine.swift:1333-1346). Loop-cycle punch means a REPEATING accept window — new writer machinery, per-cycle boundary cases, for a workflow neither Logic-normal nor requested. v1 refuses `record` when both are enabled (§6 error i); punch-only recording is byte-identical to today (the era gate). Revisit only on beta demand; the writer's window would generalize to a window LIST if it ever lands.

## 8. Alternatives considered

- **Per-cycle writer rotation** (new file per cycle): loses — file open/close on the cycle cadence, allocation and I/O failure modes per wrap, breaks the single-anchor discipline the writer is built on (RecordingWriter.swift:68-73), and the store must then MERGE metadata across files. The linear capture needs none of it.
- **Refuse record while loop enabled** (honesty-only fix): loses — satisfies the B2 gate letter but discards the milestone's headline; M14 was built precisely to enable this feature (design-m13f §6/§6.1). Kept only as the documented fallback if condition G1 fails.
- **Engine-side lane splitting or a loop-aware MIDI session**: loses — moves pure arithmetic into the engine, violates "zero capture-path changes", and the store already holds every input (frozen map, loop bounds, offsets) to slice exactly (§4).

## 9. Failure modes

1. **Store/engine eligibility divergence** (store slices as looped, engine scheduled linear or vice versa): contained by the §3 seek (post-seek the engine guard at AudioEngine.swift:1552-1561 always passes when the store engages) + condition G7's unit pin.
2. **Cycle-boundary rounding drift**: every window from absolute integrals `(k−1)·L − lag`, never accumulated — pinned with == (G1, the m12-c discipline).
3. **MIDI modular clamp collapse**: §5.3 — pinned by G4's held-note-across-stop fixture.
4. **Click starvation / misalignment under count-in + loop**: §5.4 — pinned by G6.
5. **Mid-take loop edit killing the anchor**: closed by the `setLoop` recording guard (G5).
6. **Pathological lane counts** (0.25-beat loop at 400 BPM = 37.5 ms cycles): closed by the 1.0 s cycle floor (G5).
7. **Config-change abort / no-input watchdog mid-loop-take**: unchanged paths (AudioEngine.swift:1376-1428) — the take dies cleanly before slicing; nothing loop-specific runs on failure.

## 10. Implementation plan

**Route (per ROADMAP): audio-dsp-engineer (engine lift) → swift-app-engineer (store slicing + wire + UI rider). No full Xcode needed — everything runs offline from bare SPM.**

**Phase 1 — engine lift** (`Sources/DAWEngine/AudioEngine.swift`, control-thread only): delete the `scheduleLoop` parameter and the two `activeTake == nil` suppression terms (:1317, :1552, :1731); linear stop-beat for the MIDI clamp in `stopRecording` (:1437); `metronomeElapsedOffset = −countIn.delaySeconds` + explicit count-in offset into the metronome loop plan (`Sources/DAWEngine/Metronome.swift` :184-199); rewrite the dead comments (:201-208, :222-227, :1539-1543, :1644-1645). Tests in `Tests/DAWEngineTests/`: offline loop-record schedule A/B (non-loop era byte-identity), count-in+loop click placement unit, held-note clamp fixture.
**Phase 2 — store** (`Sources/DAWCore/ProjectStore.swift`, `ProjectStore+Takes.swift`): `record()` gains punch×loop refusal, cycle floor (`TakeGroup.minLoopRecordCycleSeconds` in `Sources/DAWCore/Takes.swift`), seek-to-loop-start, `PendingTake` loop-bounds freeze; `setLoop` recording guard; `finishTake` loop branch = §4 slicing + per-slice `autoGroupRecordedTake` fan-out + the MIDI lane lander; retire the "Loop-cycle recording is out of scope" comment (ProjectStore+Takes.swift:231). Headless tests: ≥3-cycle slicing == integrals under a multi-segment map, partial-lane stop, one-undo, N==1 degradation, MIDI modular slicing round-trip.
**Phase 3 — wire/MCP/UI riders**: doc-comment updates in `Sources/DAWControl/Commands.swift` (:404-431); MCP description text in `mcp-server/src/` (transport_record, transport_set_loop, transport_set_punch — no schema/count change); count-in stepper in the record cluster (`Sources/DAWApp/TransportBar.swift` :219-222 note dies; wire `transport.setMetronome countInBars` already exists); Explain copy if the transport section mentions record+loop. `docs/ARCHITECTURE.md` recording/loop contract + FEATURES.md row ride the landing (with the m15-g pass).
**Phase 4 — live gate**: virtual-CoreMIDI loop take over the wire (the m13-c idiom), 3+ cycles → lanes visible in `project.snapshot`, comp plays the newest, refusal errors verbatim, `.ips` listings byte-equal.

## 11. Verdict

**GO-WITH-CONDITIONS.** Numbered, falsifiable:

1. **G1 — cycle-exact lanes:** an offline-driven loop-record of ≥ 3 full cycles under a multi-segment tempo map (segments inside AND beyond the loop window) lands exactly N lanes on ONE group; every lane's `startBeat`/`startOffsetSeconds`/`lengthBeats` == the absolute integrals of §4, pinned with == (audio) and the seconds-domain round-trip (MIDI, tolerance ≤ 1e-9 beats). Any `previous + L` accumulation found in review is a defect.
2. **G2 — honest partial lane:** a mid-cycle stop lands the partial last lane with length == the inverse integral of the remaining seconds; comp = that newest lane; no phantom full cycle.
3. **G3 — non-loop era:** loop-disabled recording (including count-in and punch takes) is byte-identical before/after — landed clip JSON equal and the engine schedule checksums unchanged (the suppression-lift A/B).
4. **G4 — capture path untouched:** zero diff in `RecordingWriter.swift`, `InputCapture`, `MIDICaptureSession.swift` (grep-proven); the held-note-across-stop fixture proves the linear clamp (a note held across ≥ 1 wrap ends at its true linear beat, never the 0.001 floor).
5. **G5 — B2 dead, refusals teach:** live record+loop wraps modularly and lands lanes (no silent linear roll — re-run the audit's probe3 shape); loop×punch, short-cycle, and setLoop-mid-record refuse with the §6 errors verbatim; no other verb gains a guard (the m13-c overreach rule).
6. **G6 — count-in composes:** count-in + loop record starts cycle 1 at the anchor == loop start with NO count-in lane content; click cycle anchors == `delaySeconds + integral + k·L` with a tempo boundary at the record beat; no click starvation at the 1.0 s cycle floor with a 4-bar count-in.
7. **G7 — eligibility unity:** a unit pin that store-side loop-record engagement and engine-side `LoopContext` construction agree for every guard edge (min loop length, position past loop end pre-seek, cycle floor).
8. **G8 — zero new RT surface:** all changes are main-actor/control-thread (the M14 C4 inheritance); no new allocation, locks, or ObjC on the render path.
9. **G9 — M14 stays green:** `GaplessLoopSpikeTests` and the M14 C1–C8 gates all pass; the wrap still never flushes; wire/MCP counts pinned unchanged (120/123).
10. **G10 — one undo:** the entire loop take is ONE history entry; undo restores the pre-record track exactly (members, groups, comp); redo relands; the take file survives undo (the m11-e discipline).

Failure of G1 in implementation converts the feature to the documented fallback (record+loop REFUSES with a teaching error — the roadmap's alternate honesty arm) and returns here; the suppression lift itself only ships together with the slicing, never alone.
