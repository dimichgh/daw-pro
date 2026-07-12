# Design — M10 (m10-n): Instrument library — picker, SoundFont/DLS banks, GM programs

**Status:** DESIGN SETTLED 2026-07-11 (this document is the implementation contract).
**Roadmap item:** docs/ROADMAP.md:171 — "(m10-n) Instrument library UX ('instrument sets') — a real
instrument picker listing installed AU instruments, plus SoundFont/DLS bank loading via AUSampler
so MIDI tracks aren't stuck on built-ins."
**Author:** daw-architect. **Implementing agents:** audio-dsp-engineer / swift-app-engineer (n-1
engine+domain), mcp-integration-engineer (n-2 library+wire+MCP), ui-design-engineer +
swift-app-engineer (n-3 picker), qa-test-engineer (gates).

Every code fact below was verified against the working tree on 2026-07-11 (paths:lines cited);
every Apple API fact against the local SDK headers at
`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`;
machine facts by read-only probes recorded in §2.3. No full-Xcode requirement anywhere in this
item (AUSampler is a system v2 component; no AUv3, no entitlements, no signing).

---

## 0. Decision summary

| # | Question | Decision |
|---|---|---|
| 1 | Sampler engine path | Host Apple **AUSampler** (`aumu`/`samp`/`appl`) through the EXISTING `AUHostRegistry` → `HostedAUInstrument` pipeline — **zero new render-thread code**. Bank/program loads via `kAUSamplerProperty_LoadInstrument` on the v2 handle (`AUAudioUnitV2Bridge.audioUnit`, public since macOS 11 — SDK-verified §2.2), executed on a **detached task, after `allocateRenderResources`, before the instance is ever handed to the graph** (§5.3). |
| 2 | Identity model | `InstrumentDescriptor.Kind` gains a fifth case `.soundBank`; new **additive optional** `soundBank: SoundBankConfig?` — source (`"gm"` sentinel or absolute path) + program + bankMSB/LSB + displayName. Same additive-optional migration shape as the `.sampler`/`.audioUnit` precedents (Model.swift:675–681). AUSampler is an implementation detail: never visible in the model, the wire, or the UI. |
| 3 | Bank files | Central library `~/Library/Application Support/DAWPro/SoundBanks/` (import copies there); the two standard macOS dirs (`/Library/Audio/Sounds/Banks`, `~/Library/Audio/Sounds/Banks`) scanned **reference-in-place**; the system GM bank (`gs_instruments.dls`, 1.9 MB, present on every macOS) is the zero-setup `"gm"` entry — persisted as sentinel, never as a path. No security-scoped bookmarks (app unsandboxed — tradeoff documented §4.3). Banks are NOT copied into `.dawproj` bundles. Missing at load ⇒ honest `.failed` status + silence — **never** a silent built-in fallback. |
| 4 | Wire surface | `track.setInstrument` grows optional `soundBank {source, program?, bankMSB?, bankLSB?}` (providing it implies the kind — the `audioUnit` rule mirror). Three new commands: `instrument.listSoundBanks`, `instrument.listSoundBankPrograms`, `instrument.importSoundBank` (`allCommands` 105→108). MCP: 3 new tools + `track_set_instrument` schema delta (108→111). Nothing renamed, nothing reshaped. |
| 5 | Program names | Static 128-entry **0-based** GM table + 16 categories lives in **DAWCore** (`GMProgramCatalog`) — the wire and the picker both need it and DAWCore is the shared dependency-free floor. User `.sf2` files get real names via a pure-Foundation RIFF `phdr` parser (§4.5); non-GM `.dls` files fall back to generic `Program 0…127` with `namesParsed:false` (DLS enumeration is out of scope). |
| 6 | Picker | ONE shared picker opened from the track-header instrument chip and the mixer instrument-strip slot. Three sections: Built-in / Sound Banks (bank list → program browser with GM categories, search, drum-kit group) / Audio Units (search at 64 entries). Simple density = curated "Instrument Sets" (the 16 GM categories); Pro = full MSB/LSB addressing. Headless `InstrumentPickerModel` in DAWAppKit. Contract in §7. |

**Split:** three cycles — **m10-n-1** (domain spec + engine sampler path, gated by an offline
spectral render proof), **m10-n-2** (bank library + wire + MCP), **m10-n-3** (picker UI + capture
gate). Dependency-ordered, each independently gateable — §9.

---

## 1. Scope and non-goals

In scope: the `.soundBank` instrument kind end to end (model, persistence, engine, wire, MCP,
picker); the system GM bank as a zero-download default; `.sf2`/`.dls` import + listing; program
addressing incl. percussion (bankMSB 0x78); an in-app instrument picker that also finally surfaces
the EXISTING built-in and AU selection (today there is **no instrument UI at all** — grep-verified,
no `setInstrument`/`InstrumentDescriptor` reference anywhere in `Sources/DAWApp` or
`Sources/DAWAppKit`).

Non-goals (explicitly out of v1 — do not gold-plate):
- EXS24 / `.aupreset` / `kAUSamplerProperty_LoadAudioFiles` loading paths (AUSampler supports
  them; additive later behind the same `SoundBankSource` seam).
- DLS program-name enumeration (GM table covers the builtin bank; other `.dls` show numbers).
- Live program change without node rebuild (v1 rebuilds per §5.7; flagged optimization §11-O2).
- Multi-timbral tracks / per-note program changes — one program per instrument track.
- Copying banks into project bundles (self-containment tradeoff, §4.3) and sandbox bookmarks.
- Exposing AUSampler's own UI (it has a custom Cocoa view per vi-b §12 — deliberately hidden; LAW L7).
- Editing built-in polySynth parameters in the picker (params remain wire-only, as today).
- A curated factory sample library beyond GM ("instrument sets" content is a separate roadmap
  conversation; the Simple-density category list deliberately creates the UX slot for it).

---

## 2. Ground truth (verified 2026-07-11)

### 2.1 Code facts

- `InstrumentDescriptor` — `Sources/DAWCore/Model.swift:659`: `Kind {testTone, polySynth, sampler,
  audioUnit}` (String-raw, CaseIterable, synthesized Codable); additive-optional precedent
  `sampler: SamplerParams?` (:675 "Optional so pre-sampler project files still decode") and
  `audioUnit: AudioUnitConfig?` (:678), both carried across kind switches. `AudioUnitConfig`
  (:643) = component triple + display names + `stateData` (fullStateForDocument plist).
- `Track` custom Codable — Model.swift:530 `decodeIfPresent(InstrumentDescriptor…)`, :555
  `encodeIfPresent`, :563 the byte-identical re-encode rule for omitted fields.
- `ProjectStore.setInstrument` — ProjectStore.swift:1264: partial overlay onto current descriptor;
  `audioUnit` param implies kind (:1291); wholesale-replace semantics for `sampler`/`audioUnit`;
  set-time file validation precedent `validateSamplerZones` (:1320, `importFailed` error style);
  undo coalesced per track under "Change Instrument" key `track.instrument:<id>` (:1310).
- `AUHostRegistry` — Sources/DAWEngine/AudioUnits/AUHostRegistry.swift: `PrepareKey`
  {component, sampleRate, stateData} (:41); `performPrepare` (:356) guards
  `descriptor.kind == .audioUnit` (:359), pipeline instantiate → maximumFramesToRender → setFormat
  → apply state → `allocateRenderResources` → post-allocate rate assertion → wrap
  `HostedAUInstrument`, all inside `raceAgainstTimeout` (10 s, unstructured — a stalled AU never
  blocks the main actor, :461); `releaseInstrument` fires `onRelease` (plugin-window invalidation)
  BEFORE `deallocateRenderResources` (:151); component lookup never instantiates — unknown →
  `.missing` (:373).
- `HostedAUInstrument` — HostedAUInstrument.swift: render thread touches ONLY the two captured
  blocks + preallocated memory (:14 contract); `reset()` = CC123+CC120, no ObjC (:180);
  main-actor rate renegotiation `prepare()` deallocs/reallocs render resources (:86).
- `PlaybackGraph` — PlaybackGraph.swift: `InstrumentTrackKey` structural-rebuild rules (:147–171 —
  kind structural, sampler ZONES structural, AU COMPONENT structural, stateData/params NOT);
  `instrumentFactory` (:280) maps `.audioUnit → audioUnitProvider(track) ??
  SilentPlaceholderInstrument()`; `willMutateRoutingTopology` stop-before-rewire law (:324);
  crash-a retire discipline is inside reconcile/retireNode and is untouched by this design.
- `AudioEngine.syncAudioUnitInstruments` — AudioEngine.swift:562: filter
  `kind == .audioUnit` (:568), `auDesired` keying duplicated inline from `instrument?.audioUnit`
  (:583), prepare Task → `invalidateInstrumentNode` → re-enter `tracksDidChange` (:594–601).
- `OfflineRenderer` — OfflineRenderer.swift:68 own `AUHostRegistry`; `prepareAudioUnits(tracks:)`
  (:88) filters `.audioUnit` tracks; providers wired at :154.
- Wire — Sources/DAWControl/Commands.swift: `track.setInstrument` (:466), `instrument.listAudioUnits`
  (:504), strict `parseAudioUnit` resolution (:3109), `instrumentJSON` + per-track AU status
  attachment (:3216/:3244), snapshot instrument replacement (:3153), `plugin.openUI` kind guard
  (:2334–2343). `allCommands` count = **105**; MCP `registerTool` count = **108**
  (`mcp-server/src/server.ts`; parity test-enforced by `audit-tools.test.ts`).
- App Support precedent in DAWCore: `~/Library/Application Support/DAWPro/{Autosave,Feedback}`
  (AutosaveManager.swift:114, DiagnosticsReporter.swift:172) — the SoundBanks dir joins this family.
- Existing real-AU offline test precedent: `Tests/DAWEngineTests/AUHostingTests.swift` renders
  DLSMusicDevice/AUMIDISynth/**AUSampler** headless through `OfflineRenderer` with windowed
  RMS asserts (`TestSignals.rms`) and `[measured]` prints — the n-1 gate extends this pattern.

### 2.2 SDK facts (MacOSX.sdk, cited by header line)

- `AudioToolbox/AudioUnitProperties.h:3785` — `kAUSamplerProperty_LoadInstrument = 4102`
  (Global scope, write, value `AUSamplerInstrumentData`).
- `:3819` — `struct AUSamplerInstrumentData { CFURLRef fileURL; UInt8 instrumentType;
  UInt8 bankMSB; UInt8 bankLSB; UInt8 presetID; }`.
- `:3851–3853` — `kInstrumentType_DLSPreset = 1`, **`kInstrumentType_SF2Preset =
  kInstrumentType_DLSPreset`** (same value — ONE load path for both formats, no sniffing).
- `:3860–3862` — `kAUSampler_DefaultPercussionBankMSB = 0x78` (120),
  `kAUSampler_DefaultMelodicBankMSB = 0x79` (121), `kAUSampler_DefaultBankLSB = 0x00`.
- `AudioToolbox/AUAudioUnitImplementation.h:445` — `AUAudioUnitV2Bridge.audioUnit` (the raw v2
  `AudioUnit` handle) is public, `API_AVAILABLE(macos(11.0))` — we target macOS 14+.

### 2.3 Machine probes (read-only, this runner, 2026-07-11)

- `auval -v aumu samp appl` → **AU VALIDATION SUCCEEDED** (render tests at 11 025–192 000 Hz,
  1-channel test, bad-max-frames test, MIDI test — all PASS).
- `auval -v aumu dls appl` → PASS (the losing GM alternative, recorded for completeness).
- `/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls` —
  present, 1.9 MB (the classic QuickTime GM set: 128 melodic programs + drum kits).
- `/Library/Audio/Sounds/Banks` and `~/Library/Audio/Sounds/Banks` — both exist, both EMPTY
  (no SF2 fixture on this machine ⇒ the phdr-parser test synthesizes its fixture in-test, §9 n-2).
- vi-b §12 inventory stands: 64 AU components, all v2, all Apple; AUSampler and DLSMusicDevice
  among the `aumu` set; AUSampler `hasCustomView == true` (irrelevant here by LAW L7).

---

## 3. Decision 1 — instrument identity (`InstrumentSpec`, in full)

The persistent identity is the EXISTING `InstrumentDescriptor`, grown additively. Today's shape
already covers built-ins (kind + params) and AU components (`AudioUnitConfig` triple + display
facts + stateData). What is missing is a bank-addressed sampler identity.

### 3.1 Exact model additions (Sources/DAWCore/Model.swift + new Sources/DAWCore/SoundBanks.swift)

```swift
// Model.swift — InstrumentDescriptor.Kind (additive case; String-raw so the wire
// value is "soundBank")
public enum Kind: String, Codable, Sendable, CaseIterable {
    case testTone, polySynth, sampler, audioUnit
    /// AUSampler-backed SoundFont2/DLS bank program (m10-n). The hosting AU is
    /// an implementation detail — identity lives entirely in `soundBank`.
    case soundBank
}

// Model.swift — InstrumentDescriptor (additive optional, carried across kind
// switches exactly like `sampler`/`audioUnit`; `kind == .soundBank &&
// soundBank == nil` is legal and renders the silent placeholder — the
// componentless-.audioUnit rule).
public var soundBank: SoundBankConfig?
```

```swift
// SoundBanks.swift (new, pure Foundation — LAW L9)

/// Where a bank file lives. Encodes as ONE string: "gm" for the system
/// General MIDI bank (path resolved at USE time, never persisted), or an
/// absolute filesystem path. Decode: "gm" → .generalMIDI; leading "/" →
/// .file; anything else → dataCorrupted (forward seam for future sentinels).
public enum SoundBankSource: Codable, Sendable, Equatable, Hashable {
    case generalMIDI
    case file(path: String)
}

/// Persistent, project-file-stable sound-bank instrument identity.
public struct SoundBankConfig: Codable, Sendable, Equatable {
    public var source: SoundBankSource
    public var program: Int        // MIDI program, 0-BASED 0…127 (R1)
    public var bankMSB: Int        // default 121 (0x79 melodic); 120 = percussion
    public var bankLSB: Int        // default 0
    public var displayName: String // captured at selection, e.g. "Trumpet — General MIDI"

    /// The STRUCTURAL identity (everything except cosmetic displayName) —
    /// PlaybackGraph rebuild key + AUHostRegistry PrepareKey both use this
    /// (LAW L8).
    public struct Address: Equatable, Hashable, Sendable {
        public let source: SoundBankSource
        public let program: Int
        public let bankMSB: Int
        public let bankLSB: Int
    }
    public var address: Address { … }

    // init clamps program/bankMSB/bankLSB into 0…127 (the model-clamping
    // convention, PolySynthParams precedent).
}
```

### 3.2 Migration story

- **Old file → new build:** `soundBank` is a synthesized-Codable optional ⇒ `decodeIfPresent` ⇒
  decodes nil. Zero migration, schemaVersion stays 1 (ProjectBundle.swift:73 comment: "additive
  fields ride decodeIfPresent defaults and need no migration").
- **New build re-saving an untouched old file:** synthesized encoding of a nil optional OMITS the
  key ⇒ the Track byte-identical rule (Model.swift:563) holds.
- **New file (uses `.soundBank`) → old build:** the String-raw `Kind` decode throws on the unknown
  case ⇒ the old build reports `malformedProject`. This is forward-INcompatibility, identical to
  what shipping `.sampler` and `.audioUnit` already did — accepted precedent, recorded honestly
  (R10). Do NOT bump schemaVersion for this (the version gates *newer-schema* files; an old build
  refusing an unknown instrument kind with a readable error is the correct failure).

### 3.3 `ProjectStore.setInstrument` delta (ProjectStore.swift:1264)

Additive parameter `soundBank: SoundBankConfig? = nil`:
- Providing it implies `kind: .soundBank` when `kind` is omitted (mirror of the `audioUnit` rule
  at :1291–1296).
- Providing BOTH `audioUnit` and `soundBank` in one call throws a new
  `ProjectError.ambiguousInstrumentSelection` — no silent precedence.
- Wholesale-replace semantics like `sampler`/`audioUnit`; the stored config survives kind switches.
- Set-time validation (the `validateSamplerZones` precedent :1282–1285, BEFORE the edit runs, no
  undo entry on failure): resolve source via `SoundBankLibrary.resolve` → file must exist
  (`importFailed("no sound bank file at …")`) and carry an `.sf2`/`.dls` extension
  (case-insensitive). No engine involvement — stays headless-testable.

### 3.4 Losing alternatives

- **Reuse `kind == .audioUnit` + samp component + a bank sidecar field** (forward-compatible with
  old builds): loses. Identity becomes a two-field riddle — every consumer (picker, wire encoder,
  reconcile keys, plugin-window guard) must distinguish "samp with our bank spec" from "raw
  AUSampler the user picked from the AU list"; `stateData` and the bank spec become dueling
  sources of truth; wire responses would leak `samp/appl` for "GM Trumpet". The forward-compat
  gain is small against the precedented enum-case cost.
- **Top-level `Track.soundBank` field outside the descriptor:** loses — abandons the descriptor's
  overlay/carry-across-kind-switch machinery and splits the single instrument wire object.

---

## 4. Decision 2 — bank files, library, GM data (in full)

### 4.1 `SoundBankLibrary` (new, Sources/DAWCore/SoundBanks.swift)

Pure Foundation, injectable directories for tests — the AutosaveManager default-dir precedent.

```swift
public struct SoundBankInfo: Codable, Sendable, Equatable {
    public var source: SoundBankSource  // "gm" or absolute path
    public var name: String             // "General MIDI" / filename stem
    public var path: String             // resolved absolute path (transparency)
    public var format: String           // "dls" | "sf2"
    public var builtin: Bool
    public var sizeBytes: Int
}

public struct SoundBankLibrary {
    /// The system GM bank — resolved from the "gm" sentinel at USE time only
    /// (LAW L4). Stable since QuickTime, but never persisted as a path.
    public static let systemGMBankPath =
        "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"

    /// Import destination + first scan root:
    /// ~/Library/Application Support/DAWPro/SoundBanks/ (created lazily).
    public var libraryDirectory: URL      // injectable (tests use temp dirs)
    public var scanDirectories: [URL]     // default: [libraryDirectory,
                                          //   /Library/Audio/Sounds/Banks,
                                          //   ~/Library/Audio/Sounds/Banks]

    /// GM entry FIRST, then each scan dir's *.sf2/*.dls (case-insensitive),
    /// deduped by standardized path, alphabetical within a dir. Read-only.
    public func scan() -> [SoundBankInfo]

    /// Copies into libraryDirectory (collision suffixes via
    /// ProjectBundle.uniqueName — reuse, do not re-implement). Validates
    /// extension + readability first; never moves or deletes the source.
    public func importBank(from url: URL) throws -> SoundBankInfo

    /// "gm" → systemGMBankPath; .file → its path. Throws importFailed-style
    /// when the resolved file is absent (shared by setInstrument validation
    /// and the engine's pre-instantiation check).
    public func resolve(_ source: SoundBankSource) throws -> URL

    /// §4.4/§4.5: GM table for .generalMIDI; phdr parse for .sf2; generic
    /// fallback for other .dls. Returns (programs, namesParsed).
    public func programs(for source: SoundBankSource) throws
        -> (programs: [SoundBankProgram], namesParsed: Bool)
}
```

### 4.2 Placement rules (decided)

- **Import copies to the central library**, projects reference by source string. Banks are
  GB-scale shared libraries, not per-project media — `ProjectBundle.planMedia` is deliberately
  NOT extended (clips/zones/takes stay the only bundle-copied media).
- **Scanned standard dirs are referenced in place** (no forced copy of files the user already
  organizes — Logic/GarageBand convention honors those folders).
- `track.setInstrument` accepts ANY absolute path that exists and has the right extension —
  agents are not restricted to scanned locations; `scan()` is discovery, not an allowlist.

### 4.3 Tradeoffs (documented, closed)

- **Not sandboxed today** ⇒ plain absolute paths, no security-scoped bookmarks. IF a sandboxed
  distribution ever lands, `SoundBankConfig` grows an additive `bookmark: Data?` and the resolve
  step prefers it — flagged, not built (§11-O6).
- **Projects are NOT self-contained w.r.t. banks.** A `.dawproj` moved to another machine needs
  the same bank at the same path (or "gm", which is universal). Honest cost of not duplicating
  gigabytes per project. v1 emits no save-time warning (missing banks surface at LOAD as status);
  a save-time courtesy warning is §11-O1.
- **Missing at load:** `AUHostRegistry` prepare fails → `AudioUnitTrackStatus.failed("no sound
  bank file at …")` → `SilentPlaceholderInstrument` renders → snapshot carries the verbatim
  reason. NEVER a silent fallback to a built-in timbre (LAW L5 — silence is honest, a wrong
  instrument is not).

### 4.4 `GMProgramCatalog` (new, DAWCore)

Static, 0-BASED table of the 128 GM melodic program names (program 0 = "Acoustic Grand Piano",
56 = "Trumpet") plus the 16 canonical categories of 8 (Piano, Chromatic Percussion, Organ,
Guitar, Bass, Strings, Ensemble, Brass, Reed, Pipe, Synth Lead, Synth Pad, Synth Effects,
Ethnic, Percussive, Sound Effects), plus ONE v1 percussion entry: "Standard Drum Kit"
(bankMSB 120, program 0). Lives in DAWCore because both the wire (`instrument.
listSoundBankPrograms`) and the picker need it, and DAWCore is the dependency-free floor —
NOT DAWAppKit (which DAWControl must never import).

### 4.5 `SoundFontPresetReader` (new, DAWCore — pure Foundation Data parsing)

Minimal RIFF walk for `.sf2`: `RIFF…sfbk` → `LIST…pdta` → `phdr` sub-chunk → fixed 38-byte
records `{achPresetName[20], wPreset u16, wBank u16, …}`, terminal EOP record dropped. Returns
`[(name, wBank, wPreset)]`. Mapping to AUSampler addressing (v1 heuristic, recorded as R11):
`wBank == 128` → (bankMSB 120, bankLSB 0, percussion); else → (bankMSB 121, bankLSB wBank).
Malformed/truncated file ⇒ the caller falls back to the generic 0…127 list with
`namesParsed:false` — listing NEVER errors for a file AUSampler might still load. File I/O is
main-actor/control-plane only (KB-scale reads — phdr sits near the end but `Data(contentsOf:)`
of the whole file is acceptable v1; an mmap/chunked refinement is not warranted).

---

## 5. Decision 3 — engine path (in full)

### 5.1 Why AUSampler-through-existing-hosting wins

The instrument render path in this engine is `InstrumentRenderer.renderQuantum` pulling an
`InstrumentRendering` — the schedule clock, live-thru ring, chain walk, PDC ring, and automation
stages all live INSIDE that quantum (InstrumentSourceNode.swift:191–389). `HostedAUInstrument`
already adapts any `aumu` AU into that seam via its two captured blocks. AUSampler is an `aumu`
v2 component that auval-PASSes on this machine (§2.3). Therefore: **instantiate `samp` through
the existing registry pipeline, add ONE bank-load step, wrap in the existing adapter.** The render
thread never learns this feature exists.

Losing alternatives:
- **`AVAudioUnitSampler` attached to the `AVAudioEngine` graph** — loses. It is an engine-attached
  node with its own event pump; it would bypass the schedule clock, thru ring, in-renderer chain
  walk, PDC and automation stages, violating the settled sequencer-clock decision
  (ARCHITECTURE.md "Key future decisions" first entry). Its ONLY unique asset —
  `loadSoundBankInstrument` — is a thin wrapper over the same `kAUSamplerProperty_LoadInstrument`
  we call directly.
- **Custom SF2/DLS engine extending the built-in `SamplerInstrument`** — loses. Weeks of DSP
  (generator model, envelopes, modulators, loop points, stereo layers) to re-implement an
  auval-validated OS component, with zero leverage from the existing adapter.
- **DLSMusicDevice ('dls ') + MIDI program changes** — loses. No SF2 support, GM-global preset
  state, and program-change plumbing through the schedule does not exist; AUSampler covers DLS
  AND SF2 with explicit per-instance addressing.

### 5.2 `AUHostRegistry` deltas (AUHostRegistry.swift)

- `PrepareKey` += `let soundBankAddress: SoundBankConfig.Address?` (nil for plain AU hosting) —
  idempotency now covers bank identity; displayName excluded by construction (LAW L8).
- New constant `static let auSamplerComponent = AudioUnitComponentID(type: "aumu",
  subType: "samp", manufacturer: "appl")`.
- `prepareKey(track:sampleRate:)` (:350) returns, for `.soundBank` with a config:
  `PrepareKey(component: auSamplerComponent, sampleRate:, stateData: nil, soundBankAddress:
  config.address)`. For `.soundBank` with `soundBank == nil`: nil → the existing
  "componentless → .missing placeholder" branch (:361–365) — reuse verbatim.
- `performPrepare` (:356): guard extends to `kind == .audioUnit || kind == .soundBank`. For
  `.soundBank` the `componentDescription` is SYNTHESIZED from `auSamplerComponent` (never read
  from `config.audioUnit`); `stateData` is ALWAYS nil (LAW L3). Pre-instantiation check: resolve
  the source via `SoundBankLibrary.resolve` — missing file → `.failed("no sound bank file at …")`
  WITHOUT instantiating (friendlier than an OSStatus, mirrors the lookup-never-instantiates rule).
- Inside the raced work closure, AFTER `allocateRenderResources` + the rate assertion and BEFORE
  wrapping: `try await Self.loadSoundBank(into: au, config: config, resolvedURL: url)` (§5.3).
  Failure throws `EngineError.renderFailed(…)` → the existing outcome switch lands `.failed`.

### 5.3 The bank load (exact shape — load-bearing)

```swift
// AUHostRegistry.swift (called from the timeout-raced prepare closure; the AU
// is exclusively owned here — allocated, never yet published to any graph).
private static func loadSoundBank(into au: AUAudioUnit, config: SoundBankConfig,
                                  resolvedURL: URL) async throws {
    guard let bridge = au as? AUAudioUnitV2Bridge else {
        // All-v2 machine today; if Apple ever ships samp as v3 this fails
        // readably instead of hosting a half-configured sampler.
        throw EngineError.renderFailed("AUSampler did not expose a v2 handle — cannot load bank")
    }
    struct UnitBox: @unchecked Sendable { let unit: AudioUnit }   // pre-publish exclusive (§5.3a)
    let box = UnitBox(unit: bridge.audioUnit)
    let path = resolvedURL.path
    let msb = UInt8(clamping: config.bankMSB), lsb = UInt8(clamping: config.bankLSB)
    let program = UInt8(clamping: config.program)

    let status: OSStatus = await Task.detached(priority: .userInitiated) {
        let url = URL(fileURLWithPath: path) as CFURL
        return withExtendedLifetime(url) {                        // R6: CFURL must outlive the call
            var data = AUSamplerInstrumentData(
                fileURL: Unmanaged.passUnretained(url),
                instrumentType: UInt8(kInstrumentType_SF2Preset), // == DLSPreset == 1: ONE path (R5)
                bankMSB: msb, bankLSB: lsb, presetID: program)
            return AudioUnitSetProperty(box.unit, kAUSamplerProperty_LoadInstrument,
                                        kAudioUnitScope_Global, 0, &data,
                                        UInt32(MemoryLayout<AUSamplerInstrumentData>.size))
        }
    }.value

    guard status == noErr else {
        throw EngineError.renderFailed(
            "sound bank load failed (OSStatus \(status)) — \(path), program \(program), bank \(msb)/\(lsb)")
    }
}
```

**(a) Threading argument.** `kAUSamplerProperty_LoadInstrument` on an INITIALIZED AU loads
synchronously on the calling thread (TN2283; and it is why the load sits AFTER
`allocateRenderResources`, not before — set earlier, the cost would hide inside the main-actor
`AudioUnitInitialize`). A GB-scale SF2 can block for seconds, and this beta round already burned
on main-thread stalls (m10-t) — so the call runs on a DETACHED task (LAW L2). Safety: the AU is
exclusively owned by this prepare (allocated but never published — no render pulls it, no other
code holds it); v2 CoreAudio property calls are safe from any single thread. The
`@unchecked Sendable` box is the sanctioned pre-publish-exclusive crossing (the
`HostedAUInstrument: @unchecked Sendable` precedent). This is control-plane work — Tier-1
render invariants are untouched (zero new render code in the whole item).

**(b) Timeout interaction.** The load runs inside the existing `raceAgainstTimeout` (10 s): a
pathological load times the prepare out READABLY (`.failed("…timed out…")`); the abandoned
detached task finishes harmlessly against an AU that was never published and dies by ARC.

**(c) Main-actor contract note.** AUHostRegistry's "all AU property access happens here, on the
main actor" comment (:18) gets one documented exception: the pre-publish bank load, per (a).
Update the class doc comment when implementing.

### 5.4 `PlaybackGraph` deltas (PlaybackGraph.swift)

- `InstrumentTrackKey` (:166) += `let soundBank: SoundBankConfig.Address?` — the ADDRESS is
  structural (source/program/MSB/LSB change ⇒ node rebuild, the sampler-zones precedent :155);
  `displayName` is cosmetic and must never rebuild (LAW L8). nil for all other kinds.
- `InstrumentNode` stores the same address for signature comparison (the `audioUnitComponent`
  pattern :183–185).
- `instrumentFactory` (:280) += `case .soundBank: return self.audioUnitProvider(track) ??
  SilentPlaceholderInstrument()` — the provider already consults the registry BY TRACK ID, so no
  new provider seam is needed.
- Teardown/retire: UNCHANGED. An address change flows: new key ≠ old key → reconcile tears the
  node down through the existing invalidate → `willMutateRoutingTopology` → retire path. The
  crash-a `retireNode` discipline and the 1 s schedule retire bin are not touched.

### 5.5 `AudioEngine` deltas (AudioEngine.swift:562)

- `syncAudioUnitInstruments` filter (:568): `kind == .audioUnit` → `kind == .audioUnit ||
  kind == .soundBank`.
- `auDesired` keying (:583): replace the inline `instrument?.audioUnit.map{…}` with
  `AUHostRegistry.prepareKey(track:sampleRate:)` for BOTH kinds — one keying authority, no
  drift between the engine's desired-map and the registry's idempotency check.
- Everything downstream (release-then-prepare on change :590–601, invalidate + re-enter) is
  reused verbatim.

### 5.6 `OfflineRenderer` deltas (OfflineRenderer.swift:88)

`prepareAudioUnits(tracks:)` filter includes `.soundBank`. The offline registry loads the bank
AGAIN (fresh AU instances per render — existing design) ⇒ a second transient RAM copy during a
bounce; trivial for GM (1.9 MB), documented for GB-scale SF2s (R9).

### 5.7 Swap / load-timing semantics (the §3 design questions, answered)

- **`setInstrument` during playback:** store edit → `tracksDidChange` → registry releases the old
  instance (plugin windows: none exist for soundBank) → node renders placeholder silence →
  prepare (instantiate + detached load, main actor free) → `invalidateInstrumentNode` →
  reconcile rebuild (`willMutateRoutingTopology` stop/restart only for non-trivial routing).
  Identical to today's AU component swap — no new interruption class.
- **Project load with a slow bank:** UI and transport are live immediately; the track is
  `.pending` (silent) until the load lands; the main actor is never blocked by the file load;
  status flows through the existing snapshot fields. A failed load is `.failed` + silence.
- **Program browsing in the picker:** each selection = full release→instantiate→load→rebuild
  cycle. Target for the GM bank: < ~300 ms selection-to-ready (n-1 gate RECORDS the measured
  number). Keeping a live AUSampler and hot-swapping programs is the flagged optimization
  (§11-O2) — NOT v1 (it would create the first mutate-while-rendering AU path and needs its own
  RT analysis).

### 5.8 Rate renegotiation (HostedAUInstrument.prepare :86)

The renegotiation path deallocs/reallocs render resources. v2 AU properties are EXPECTED to
survive an Uninitialize/Initialize cycle (the loaded instrument should persist), but this is not
documented for AUSampler's loaded-bank state. n-1 MUST pin it (gate test T6): prepare at 48 kHz,
renegotiate to 44.1 kHz, render, assert energy. Contingency if it fails: the registry re-runs
`loadSoundBank` after renegotiation via a small reload hook — design seam noted, only built if
T6 falsifies the expectation (R7).

---

## 6. Decision 4 — wire surface + MCP (exact shapes)

Additive only. Nothing renamed, nothing reshaped (LAW L6). `instrument.listAudioUnits`,
`fx.*`, and `plugin.*` are byte-stable.

### 6.1 `track.setInstrument` (grown)

New optional param:

```json
{ "trackId": "…",
  "soundBank": { "source": "gm", "program": 56, "bankMSB": 121, "bankLSB": 0 } }
```

- `source` (required): `"gm"` or an absolute path. STRICT like `parseAudioUnit` (:3109): a
  missing/wrong-extension file errors readably, naming `instrument.listSoundBanks`.
- `program` / `bankMSB` / `bankLSB` optional (defaults 0 / 121 / 0), clamped 0…127 through the
  model init (the `track.setVolume` silent-clamp convention).
- Providing `soundBank` implies `kind: "soundBank"` when `kind` is omitted (the `audioUnit` rule).
- `soundBank` + `audioUnit` in ONE request → error `"provide either audioUnit or soundBank, not
  both"` (maps `ambiguousInstrumentSelection`).
- `kind: "soundBank"` alone (no config provided, none stored) is legal → silent placeholder
  (the componentless-AU rule) — `parseInstrumentKind` picks the new case up automatically from
  `Kind.allCases`.
- `displayName` is SERVER-derived (GM table name / phdr name / "<file stem> · P<n>") — never a
  wire input.

Response — `instrumentJSON` (:3216/:3244) gains, when `kind == "soundBank"` and a config exists:

```json
"soundBank": { "source": "gm",
               "path": "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls",
               "program": 56, "bankMSB": 121, "bankLSB": 0,
               "name": "Trumpet — General MIDI",
               "status": "ready" }
```

`status` reads `store.audioUnitStatus(forTrack:)` — the registry status slot is SHARED with
plain AU hosting (same forwarder :1361, no new store surface; values `pending|ready|missing|
failed: …` exactly as the `audioUnit` object today :3221–3228). The same object rides
`snapshotJSON` (:3153 replacement path). `source` is the persistable sentinel/path; `path` is
the resolved transparency field (LAW L4: only `source` is ever persisted).

### 6.2 `instrument.listSoundBanks` (new; no params)

```json
{ "banks": [
    { "source": "gm", "name": "General MIDI", "path": "/System/…/gs_instruments.dls",
      "format": "dls", "builtin": true, "sizeBytes": 1969024 },
    { "source": "/Users/…/Library/Application Support/DAWPro/SoundBanks/Vintage.sf2",
      "name": "Vintage", "path": "…same…", "format": "sf2", "builtin": false, "sizeBytes": 31457280 }
] }
```

GM first, then scan order (§4.1). Never errors; an unreadable scan dir is skipped silently
(read-only discovery).

### 6.3 `instrument.listSoundBankPrograms` (new; params: `source`)

```json
{ "source": "gm", "namesParsed": true,
  "programs": [
    { "program": 0,  "bankMSB": 121, "bankLSB": 0, "name": "Acoustic Grand Piano", "category": "Piano" },
    …,
    { "program": 56, "bankMSB": 121, "bankLSB": 0, "name": "Trumpet", "category": "Brass" },
    …,
    { "program": 0,  "bankMSB": 120, "bankLSB": 0, "name": "Standard Drum Kit", "category": "Drum Kits" }
] }
```

- `"gm"` → the full 0-based GM table + categories + the v1 percussion entry (§4.4).
- `.sf2` → phdr parse (§4.5), `namesParsed: true`; on parse failure → generic
  `Program 0…127` with `namesParsed: false` (honest, never an error for a loadable bank).
- other `.dls` → generic fallback, `namesParsed: false`.
- Unknown source / missing file → error naming `instrument.listSoundBanks`.

### 6.4 `instrument.importSoundBank` (new; params: `path`)

Validates extension (`.sf2`/`.dls`) + existence + readability, copies into the central library
(collision suffixes via `ProjectBundle.uniqueName`), returns `{ "bank": { …SoundBankInfo shape
as §6.2… } }`. Errors in the MediaImporting taxonomy style ("Audio import failed: …" family —
same tone, bank-specific strings). Import never mutates the project — selection is a separate
`track.setInstrument` call (agents can import once, use many).

### 6.5 Counts + MCP deltas (mcp-server/src/server.ts)

- `allCommands` **105 → 108** (three `instrument.*` additions; the namespace already exists).
- Tools **108 → 111**: `instrument_list_sound_banks`, `instrument_list_sound_bank_programs`,
  `instrument_import_sound_bank` — mechanical name rule holds, NO Table A entries.
- `track_set_instrument` inputSchema grows the `soundBank` object (every property described —
  audit-enforced), its description teaching the zero-setup flow: *"list banks → list programs →
  set `{source:"gm", program}`; 128 General MIDI instruments with no downloads"*.
- `audit-tools.test.ts` parity + schema-richness enforcement is automatic; integration suite adds
  one GM round-trip (§9 n-2 gate).

### 6.6 Store forwarders (ProjectStore, engine-free)

`availableSoundBanks()`, `soundBankPrograms(source:)`, `importSoundBank(from:)` — thin wrappers
over an injected `SoundBankLibrary` (default real dirs; tests inject temp dirs). NO
`EngineProtocol` change anywhere in this item — bank discovery/parsing is pure file work and
playback rides the existing `tracksDidChange` path.

---

## 7. Decision 5 — picker UX contract (for the ui agent; sections/states/interactions — no pixels)

- **Entry points (both, one shared component):** (a) instrument tracks' TRACK HEADER gains an
  instrument CHIP showing the current display name ("Poly Synth", "Trumpet — General MIDI",
  "DLSMusicDevice"); (b) the MIXER instrument-strip gets the same chip in the slot where audio
  strips show inserts. Chip is status-aware: `pending` = subtle progress shimmer; `failed` =
  warning glyph + the verbatim status reason on hover/expand. Popover vs panel is the ui agent's
  call — one component, two anchors.
- **Section 1 — BUILT-IN:** Poly Synth, Sampler, Test Tone. Selection = `store.setInstrument(kind:)`
  (params untouched — they carry across switches by design). No parameter editing here (non-goal).
- **Section 2 — SOUND BANKS:** bank list (General MIDI first with a "built-in" tag; then imported
  + scanned banks; "Import Sound Bank…" affordance → NSOpenPanel → the import path → refresh).
  Selecting a bank drills into the PROGRAM BROWSER: GM categories as groups, search-as-you-type
  filter, "Drum Kits" group (bankMSB 120), current program highlighted. Selecting a program
  applies IMMEDIATELY (one coalesced undo per the `track.instrument:<id>` key; audition = the
  user's own MIDI/live-thru once status is ready — expect < ~0.3 s for GM, §5.7).
- **Section 3 — AUDIO UNITS:** `availableAudioUnits()` list (64 entries on this machine), search
  across `name` + `manufacturerName` (search is mandatory at this count, no pagination), v3 badge
  when `isV3` (future-proofing; all-v2 today). Selection applies immediately.
- **Simple density** (`PanelDensity` precedent, ClipEditModel.swift:57): a curated flat list —
  Poly Synth, Sampler, then the 16 GM categories presented as "Instrument Sets" (each maps to its
  category's first program: Piano→0, Brass→56, …) plus "Drums" (120/0). The AU section stays
  visible but flat (beginners own plugins too); raw program numbers and MSB/LSB detail are
  Pro-only.
- **Failure honesty:** a failed/missing bank shows the verbatim snapshot reason; recovery = pick
  again (a "Locate missing bank…" flow is §11-O4). No violet anywhere — the picker is standard
  chrome, violet stays AI-identity-only.
- **Plugin-window button take-over rules:** UNCHANGED for `.audioUnit` instruments. NOT shown for
  `.soundBank` (the picker IS the editor; the hosted AUSampler is invisible — LAW L7). The
  `plugin.openUI` guard already rejects non-`.audioUnit` kinds (:2338–2342); reword its message
  for the new case: *"track uses a sound-bank instrument — programs are picked in the instrument
  picker"* (the current wording would call it "the built-in soundBank instrument", which is wrong
  on both counts).
- **Explain entries (ExplainID + catalog + capture-staging focus):** `trackInstrumentChip`
  ("what an instrument is; where this track's sound comes from; click to change"),
  `instrumentPickerSoundBanks` ("what a sound bank / General MIDI is — 128 classic instruments,
  zero downloads"), `instrumentPickerAudioUnits` ("what an Audio Unit plugin is; where its window
  lives"). Naming follows the existing camelCase convention (ExplainModel.swift:22ff).
- **Headless model:** `InstrumentPickerModel` in DAWAppKit — sections built from
  `ProjectStore.availableAudioUnits()` + `SoundBankLibrary` + `GMProgramCatalog`, search
  filtering, density mapping, selection → `ProjectStore.setInstrument` (one command surface: the
  UI converges on the exact store methods the wire uses). Fully unit-testable without UI.

---

## 8. LAWS for implementers

- **L1 — Zero new render-thread code.** The render path for `.soundBank` IS `HostedAUInstrument`,
  byte-for-byte. Any diff touching `renderQuantum`, `HostedAUInstrument.render/reset`, or adding
  Tier-1 code for this item is wrong by construction.
- **L2 — The bank load runs on a DETACHED task**, after `allocateRenderResources`, only on an
  instance not yet handed to any graph. Never on the main actor (stall), never on a published
  instrument (mutate-while-rendering), never on the render thread (obviously).
- **L3 — `stateData` is ALWAYS nil for `.soundBank`.** `SoundBankConfig` is the single source of
  truth; AUSampler's `fullStateForDocument` embeds machine-local paths (the TN2283 trap) and must
  never be captured or restored for this kind.
- **L4 — `"gm"` is the only persisted form of the system bank.** The `/System/…` path is resolved
  at use time; it appears on the wire only as the transparency `path` field, never in
  project.json.
- **L5 — Missing bank ⇒ silence + verbatim `.failed` reason.** Never fall back to a built-in
  timbre; never downgrade the error to a log line.
- **L6 — Additive wire only.** Existing command/response shapes stay byte-stable; the three new
  commands and the `soundBank` param/response object are the complete wire delta; never rename.
- **L7 — Gate on descriptor kind, not registry presence.** `hostedInstrumentAudioUnit(forTrack:)`
  WILL return the live AUSampler for a soundBank track; `plugin.openUI`, window buttons, and any
  accessor consumer must check `descriptor.kind == .audioUnit` (the :2338 guard already does).
- **L8 — The structural rebuild/prepare key is `SoundBankConfig.Address`** (source, program,
  bankMSB, bankLSB). `displayName` is cosmetic: it must not rebuild the node, must not re-prepare
  the AU, must not appear in `PrepareKey` or `InstrumentTrackKey`.
- **L9 — DAWCore additions stay pure Foundation.** No AudioToolbox import in DAWCore; the MSB
  defaults are plain Ints (121/120/0) with the `kAUSampler_*` constant names in comments only.
- **L10 — Every gate number is printed `[measured]`** (AUHostingTests precedent) and thresholds
  are tuned against printed reality, never asserted blind.

---

## 9. Sub-item split, deliverables, gates (dependency-ordered)

### m10-n-1 — Engine sampler path + domain spec (audio-dsp-engineer or swift-app-engineer; the risky one, gated by audio proof)

**Deliverables**
- `Sources/DAWCore/Model.swift`: `Kind.soundBank`, `soundBank` field.
- `Sources/DAWCore/SoundBanks.swift` (partial): `SoundBankSource`, `SoundBankConfig` + `Address`,
  `SoundBankLibrary.resolve` + `systemGMBankPath` (scan/import/programs land in n-2).
- `Sources/DAWCore/ProjectStore.swift`: `setInstrument` param + validation +
  `ambiguousInstrumentSelection`.
- `Sources/DAWEngine/AudioUnits/AUHostRegistry.swift`: PrepareKey/prepareKey/performPrepare/
  `loadSoundBank` per §5.2–5.3 (+ class doc-comment exception note §5.3c).
- `Sources/DAWEngine/PlaybackGraph.swift`: key + factory per §5.4.
- `Sources/DAWEngine/AudioEngine.swift` (§5.5) + `OfflineRenderer.swift` (§5.6).
- Honest intermediate: `kind:"soundBank"` becomes wire-valid via `Kind.allCases` (silent
  placeholder, no bank param parsing yet) — acceptable; the full wire lands in n-2.

**Tests/gate**
- `Tests/DAWCoreTests/SoundBankConfigTests.swift`: Codable round-trip; `"gm"` sentinel encode
  shape; clamping; old-project fixture (no `soundBank` key) decodes; nil-field omission keeps
  Track encoding byte-identical; both-params ambiguity throws; kind-implication rule.
- `Tests/DAWEngineTests/SoundBankHostingTests.swift` (extends the AUHostingTests pattern):
  - **T1** GM program 0, single note at beat 1 → onset-windowed energy (the
    `assertRendersEnergyAtOnset` shape: body RMS > 0.005, pre-onset < 1e-4).
  - **T2 — SPECTRAL GATE (the roadmap-facing proof):** one 2-bar MIDI clip (sustained C4,
    beats 1–3) rendered offline 3×: built-in polySynth (default params), GM program 0 (piano),
    GM program 56 (trumpet). Compute 24 log-spaced Goertzel band magnitudes (60 Hz–8 kHz) over
    the note body, normalize each band vector to unit L2; assert every render body-RMS > 0.005
    AND pairwise vector distance d(poly, gm0) > 0.25 and d(gm0, gm56) > 0.25 (print `[measured]`
    and tune once — sine-ish poly vs piano vs brass should clear 0.5 comfortably). This proves
    non-built-in timbre AND program addressing in one cheap offline render.
  - **T3** percussion addressing: bankMSB 120, program 0, pitch 38 (snare) → onset energy.
  - **T4** idempotency + swap: same address → no re-prepare (attempted-key check); changed
    program → re-prepare + rebuild; render differs from T2's gm0 render.
  - **T5** missing file → `.failed("no sound bank file at …")`, renders silence, no throw-out of
    the project.
  - **T6** rate renegotiation survival (§5.8): prepare 48 kHz → `prepare(sampleRate: 44100…)` →
    still renders energy. If this falsifies, build the R7 reload hook BEFORE gating.
  - **T-extra (record, don't assert):** load a program address absent from the GM bank
    (e.g. bankMSB 5) and PRINT the observed behavior (OSStatus vs silent success) — feeds R3's
    documentation in the roadmap note.
- **Gate:** `./scripts/test.sh` green; `[measured]` spectral distances + GM prepare-to-ready wall
  time printed and recorded in the ROADMAP checkbox note.

### m10-n-2 — Bank library + wire + MCP (mcp-integration-engineer)

**Deliverables**
- `SoundBanks.swift` completed: `scan`, `importBank`, `programs(for:)`; `GMProgramCatalog`;
  `SoundFontPresetReader` (§4.4–4.5).
- `ProjectStore` forwarders (§6.6, injectable library).
- `Commands.swift`: `soundBank` param parsing on `track.setInstrument`, `instrumentJSON` delta,
  3 new commands (§6.1–6.4); `allCommands` 105→108.
- `mcp-server/src/server.ts`: 3 new tools + `track_set_instrument` schema delta (108→111).
- `docs/ARCHITECTURE.md`: control-protocol paragraph for the three commands + a "Key future
  decisions" entry — *"Instrument identity & sound banks: SETTLED (m10-n)"* citing this doc.
- `docs/AI-INTEGRATIONS.md` / tool docs touch-ups if the audit demands.

**Tests/gate**
- `Tests/DAWControlTests/SoundBankCommandTests.swift`: request/response shapes, strict source
  validation, ambiguity error, snapshot carry, list ordering (GM first) with injected temp dirs,
  import happy/collision/bad-extension/missing.
- `Tests/DAWCoreTests/SoundFontPresetReaderTests.swift`: SYNTHESIZED minimal sf2 bytes in-test
  (no binary fixtures; §2.3 — none exist on this machine): 2-preset file parses names + the
  wBank→MSB/LSB mapping incl. wBank 128 → percussion; truncated file → generic fallback path.
- npm: audit parity (108 commands ↔ 111 tools) + one integration GM round-trip.
- **Gate:** full Swift + npm suites green; live staging round-trip (STAGING LAUNCH LAW, dummy env
  keys): `instrument.listSoundBanks` (gm first) → `instrument.listSoundBankPrograms` spot-checks
  ("Acoustic Grand Piano"@0, "Trumpet"@56) → `track.setInstrument {source:"gm", program:56}` →
  snapshot `status:"ready"` within 2 s → `render.mixdown` of a small MIDI clip is non-silent.

### m10-n-3 — Picker UI (ui-design-engineer + swift-app-engineer)

**Deliverables**
- `Sources/DAWAppKit/InstrumentPickerModel.swift` (headless: sections, search, density,
  selection, status mapping).
- Picker view + track-header chip + mixer slot + import affordance (per §7), Explain entries (3
  new ExplainIDs + catalog copy), `plugin.openUI` soundBank message reword (:2341).
**Tests/gate**
- `Tests/DAWAppKitTests/InstrumentPickerModelTests.swift` (+ Explain catalog tests auto-cover
  the new ids).
- **Capture gate** (debug.captureUI + explainMode focus, orchestrator-eyeballed): (1) picker open
  with three sections; (2) program browser, GM categories + a search-filtered state; (3) header
  chip reading "Trumpet — General MIDI" after selection, cross-checked against the wire snapshot;
  (4) Simple-density curated "Instrument Sets" list; (5) Explain cards for the three new ids.

**Dependency order:** n-2 needs n-1's types; n-3 needs n-2's library/list surface. Each lands
green independently (n-1 is store+engine-complete with an honest silent wire intermediate; n-2 is
the full agent-facing capability; n-3 is the human-facing capability).

---

## 10. Risks & traps (pre-warnings for implementers)

- **R1 — GM off-by-one.** Human GM charts are 1-based ("#57 Trumpet"); the wire/model `program`
  is the 0-based MIDI byte. `GMProgramCatalog` is 0-based; n-2 pins `program 56 == "Trumpet"`.
- **R2 — bankMSB conventions.** 0x79/121 melodic, 0x78/120 percussion, LSB 0 — for
  GM-COMPATIBLE banks only (SDK doc §2.2). Custom banks use their real MSB/LSB — which is why
  the raw fields ride the wire and the Pro picker, never hard-coded.
- **R3 — Bad program address behavior is undocumented.** AUSampler may return an OSStatus error
  or accept-and-silence. n-1 T-extra measures and records it; either way the surface stays
  honest (failed status, or silence with ready status — the render is the truth).
- **R4 — The load is calling-thread-synchronous** once the AU is initialized → LAW L2's detached
  task. Never "just call it inline, GM is small" — user banks are not small.
- **R5 — `kInstrumentType_SF2Preset == kInstrumentType_DLSPreset == 1`** (SDK-verified). Do not
  branch on file format for loading; only listing cares (§4.5).
- **R6 — CFURL lifetime.** `AUSamplerInstrumentData.fileURL` is `Unmanaged` — the §5.3 shape
  (`passUnretained` + `withExtendedLifetime`) is load-bearing; a released CFURL is a
  use-after-free inside CoreAudio.
- **R7 — Renegotiation survival unpinned** until T6 runs; contingency reload hook per §5.8.
- **R8 — `fullStateForDocument` path-embedding trap** (LAW L3) — also the reason a user manually
  hosting AUSampler via the AU section keeps TODAY'S behavior (stateData capture, their problem
  and their power); our soundBank kind never mixes with it.
- **R9 — RAM.** AUSampler loads sample data into memory; live + offline registries during a
  bounce = two copies transiently. No size cap v1; `sizeBytes` in listSoundBanks lets agents/UI
  warn.
- **R10 — Forward-compat decode break** for pre-m10-n builds opening soundBank projects
  (§3.2) — accepted precedent, record in the roadmap note.
- **R11 — SF2 wBank mapping heuristic.** phdr's `wBank` is a raw u16: 128 conventionally means
  percussion (→ MSB 120), other non-zero values are genuinely ambiguous across real-world SF2s
  (some expect MSB=wBank, AUSampler's GM convention expects 121/LSB). v1 maps
  `128→(120,0)`, `else→(121, wBank)`, exposes raw MSB/LSB overrides in Pro, and revisits with a
  real corpus (§11-O3).
- **R12 — Component availability.** auval PASS recorded on this machine (§2.3); `samp` ships
  with macOS since 10.7 — effectively universal, and the `.missing` path covers the impossible.

---

## 11. Open questions (honest, deferred — none block implementation)

- **O1** Save-time courtesy warning when a project references a bank outside the central
  library / standard dirs (correctness is already covered by load-time status).
- **O2** Live program change without node rebuild (kept-instance reload or MIDI PC through the
  schedule) — only if the measured GM selection latency (n-1 gate) or beta feedback demands;
  needs its own RT analysis (first mutate-while-rendering AU path).
- **O3** SF2 wBank→MSB/LSB mapping against a real-world corpus (R11).
- **O4** "Locate missing bank…" recovery flow (re-pick is the v1 recovery).
- **O5** Curated factory "instrument sets" beyond GM — content/licensing conversation; the
  Simple-density category list is the deliberate UX slot for it.
- **O6** Sandboxed-dist bookmark field (`bookmark: Data?`, additive) — only if distribution ever
  sandboxes (§4.3).

---

*Probe log (read-only, 2026-07-11): `auval -v aumu samp appl` PASS · `auval -v aumu dls appl`
PASS · `gs_instruments.dls` present 1.9 MB · standard bank dirs empty · allCommands=105,
MCP registerTool=108 · SDK constants verified at the cited header lines.*
