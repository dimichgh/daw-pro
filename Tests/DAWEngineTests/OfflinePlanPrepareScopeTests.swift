import AVFAudio
import AudioToolbox
import CryptoKit
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

// AUR-1: THE COMPENSATION PLAN PREPARES HOSTED INSERTS ONLY.
// docs/design/2026-09-27-au-instance-reuse.md §3.1 (the change), §7.1 (T1, T2).
//
// `render.stems` and `track.bounceInPlace` both ask
// `AudioEngine.offlineCompensationTargets` for the full-session PDC plan before
// they render. Until AUR-1 that plan loaded EVERY hosted AU in the session into
// a throwaway renderer, hosted instruments included, and then read only
// insert-effect latency from it. For a 46-zone hosted sampler that is a whole
// sample-library load, dropped moments later mid-load, before the real render
// loads it again. It was the one code-path difference between the two verbs
// that lost the sax's opening and `render.mixdown`, which did not (sax defect
// ③). These gates pin the smaller plan; they say NOTHING about whether the
// throwaway caused ③. Only a same-plugin before/after render on the real
// plugin can say that.
//
// ⚠️ AN EXTENSION OF `AUHostingTests`, NOT A NEW `@Suite` (the
// `OfflineRenderReadinessTests` / `FirstClipDropProbeTests` precedent). Every
// assertion here drives `AudioEngine`, `OfflineRenderer`, `AUHostRegistry` or
// `ProjectStore`, all `@MainActor`, and the `@MainActor` suite census sits at
// its review cap. Extending the existing main-actor suite adds zero suites and
// inherits its `.serialized`, so no two of these instantiate AUs at once.
//
// Apple units only. No third-party plugin is loaded here, and none may be.

// MARK: - Instruments that count

/// Records what one registry's `instantiator` seam is asked for, split by
/// component type, then forwards to the real `AUAudioUnit.instantiate`. With
/// `stubInstruments`, a music device gets `AUR1StubInstrumentAU` instead, so a
/// control arm's instrument "load" costs nothing and loads no sampler.
///
/// This is one of the two counters every count below is read from; the other
/// is the registry's own m23-br-1 ledger (`instrumentPrepareCount`,
/// `status`, `effectPrepareCount`, `effectStatus`). The spy counts
/// INSTANTIATIONS; the ledger counts prepare bodies past the idempotency guard
/// (a failed prepare ticks it too, which is why `.ready` is asserted beside it).
@MainActor
private final class AUR1InstantiationSpy {
    let stubInstruments: Bool
    /// Subtype of every music device (`aumu`) asked for, in order.
    private(set) var instruments: [String] = []
    /// Subtype of every effect (`aufx`) asked for, in order.
    private(set) var effects: [String] = []
    /// Anything else (none expected).
    private(set) var others: [String] = []
    /// The planning renderer the engine seam handed over (T1, T2).
    var planner: OfflineRenderer?

    init(stubInstruments: Bool) {
        self.stubInstruments = stubInstruments
    }

    func install(on registry: AUHostRegistry) {
        registry.instantiator = { [self] description, options in
            let subType = AUHostRegistry.fourCCString(description.componentSubType)
            switch description.componentType {
            case kAudioUnitType_MusicDevice:
                instruments.append(subType)
                if stubInstruments {
                    return try AUR1StubInstrumentAU(stubbing: description)
                }
            case kAudioUnitType_Effect:
                effects.append(subType)
            default:
                others.append(subType)
            }
            return try await AUAudioUnit.instantiate(with: description, options: options)
        }
    }
}

/// A music device that only has to exist: one stereo output bus, renders
/// silence, loads nothing. It wears AUSampler's identity (`samp`/`appl`)
/// because the registry's component LOOKUP (`AVAudioUnitComponentManager`)
/// runs before its `instantiator` and must match something installed, the
/// R-1 stub's reason. That identity is DLS-family, so its allocate runs on
/// `dlsBankQueue`; this unit touches no state there, so that is harmless.
private final class AUR1StubInstrumentAU: AUAudioUnit {
    private var busArray: AUAudioUnitBusArray!

    init(stubbing componentDescription: AudioComponentDescription) throws {
        try super.init(componentDescription: componentDescription, options: [])
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        busArray = AUAudioUnitBusArray(audioUnit: self, busType: .output,
                                       busses: [try AUAudioUnitBus(format: format)])
    }

    override var outputBusses: AUAudioUnitBusArray { busArray }

    override var internalRenderBlock: AUInternalRenderBlock {
        return { _, _, _, _, outputData, _, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                guard let raw = buffer.mData else { continue }
                memset(raw, 0, Int(buffer.mDataByteSize))
            }
            return noErr
        }
    }
}

/// What the legacy-plan arm's seam did, recorded INSIDE the seam so the
/// throwaway renderer is never retained past the plan (it must die exactly
/// where the pre-AUR-1 code let it die: when the plan returns).
@MainActor
private final class AUR1PlanLog {
    var plans = 0
    var instrumentPrepares = 0
}

/// One row of the invariance table: the session, what to render from it, and
/// what the legacy-plan arm must have done (its anti-vacuity counts).
private struct AUR1InvarianceSession {
    let name: String
    let tracks: [Track]
    let stems: Bool
    let includeMixdown: Bool
    let bounce: [(label: String, id: UUID)]
    /// Plans the legacy arm must run: one for the stems, one per bounce.
    let plans: Int
    /// Hosted-instrument prepares the legacy arm's plans must make, in total.
    let planInstrumentPrepares: Int
}

/// One arm of the invariance A/B: every rendered file, in render order.
private struct AUR1Arm {
    struct File {
        let label: String
        let url: URL
        let bytes: Data
    }
    let files: [File]
    let planInstrumentPrepares: Int
    let plans: Int
    /// Everything this arm wrote lives under here; removed once compared.
    let root: URL
}

extension AUHostingTests {
    // MARK: - AUR-1 fixtures

    private static var aur1Sampler: AudioUnitComponentID {
        AudioUnitComponentID(subType: "samp", manufacturer: "appl")
    }
    /// AUMIDISynth: a hosted Apple instrument that is not DLS-bank-loaded.
    private static var aur1Synth: AudioUnitComponentID {
        AudioUnitComponentID(subType: "msyn", manufacturer: "appl")
    }
    private static var aur1Delay: AudioUnitComponentID {
        AudioUnitComponentID(type: "aufx", subType: "dely", manufacturer: "appl")
    }
    /// AUPeakLimiter: small, honest lookahead (`PDCHostedAURenderTests`).
    private static var aur1PeakLimiter: AudioUnitComponentID {
        AudioUnitComponentID(type: "aufx", subType: "lmtr", manufacturer: "appl")
    }
    /// AUDynamicsProcessor: a larger lookahead, used BYPASSED below.
    private static var aur1Dynamics: AudioUnitComponentID {
        AudioUnitComponentID(type: "aufx", subType: "dcmp", manufacturer: "appl")
    }

    /// Prints a `[measured]` line and, when `AUR1_MEASURE_DIR` is set, appends
    /// it to `aur1-measured.txt` there. The console test log drops records
    /// under load, and these numbers are evidence.
    private func aur1Record(_ line: String) {
        let text = "[measured] AUR-1 \(line)"
        print(text)
        guard let dir = ProcessInfo.processInfo.environment["AUR1_MEASURE_DIR"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("aur1-measured.txt")
        let data = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func aur1HostedInsert(_ component: AudioUnitComponentID,
                                  bypassed: Bool = false) -> EffectDescriptor {
        EffectDescriptor(kind: .audioUnit, isBypassed: bypassed,
                         audioUnit: AudioUnitConfig(component: component))
    }

    /// Two notes inside a 2 s render at 120 BPM.
    private func aur1NoteClip(pitch: Int = 60) -> Clip {
        Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: pitch, velocity: 110, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: pitch + 7, velocity: 100, startBeat: 1.5, lengthBeats: 1),
        ])
    }

    private func aur1GMTrack(name: String, program: Int = 0,
                             effects: [EffectDescriptor] = []) -> Track {
        Track(name: name, kind: .instrument, clips: [aur1NoteClip()],
              instrument: InstrumentDescriptor(
                  kind: .soundBank,
                  soundBank: SoundBankConfig(source: .generalMIDI, program: program,
                                             bankMSB: 121)),
              effects: effects)
    }

    private func aur1AudioTrack(_ name: String, url: URL, pan: Double = 0,
                                outputBusID: UUID? = nil, sends: [Send] = [],
                                effects: [EffectDescriptor] = []) -> Track {
        Track(name: name, kind: .audio, pan: pan,
              clips: [Clip(name: name, startBeat: 0, lengthBeats: 4, audioFileURL: url)],
              outputBusID: outputBusID, sends: sends, effects: effects)
    }

    // MARK: - T1: the plan instantiates no instrument

    /// T1's session. `hosted`: a hosted instrument (the stub, wearing
    /// AUSampler's identity) carrying its OWN hosted AUDelay. That row fails
    /// an implementation that skips hosted-instrument TRACKS instead of hosted
    /// INSTRUMENTS. `audio`: a second AUDelay, on a plain audio track. `poly`:
    /// a built-in instrument with nothing hosted.
    private func aur1T1Session() throws -> (tracks: [Track], hosted: Track, audio: Track) {
        let fixtures = try TestSignals.fixtures()
        let hosted = Track(name: "HostedStub", kind: .instrument, clips: [aur1NoteClip()],
                           instrument: InstrumentDescriptor(
                               kind: .audioUnit,
                               audioUnit: AudioUnitConfig(component: Self.aur1Sampler)),
                           effects: [aur1HostedInsert(Self.aur1Delay)])
        let audio = aur1AudioTrack("AudioDelay", url: fixtures.cos1k48Quarter,
                                   effects: [aur1HostedInsert(Self.aur1Delay)])
        let poly = Track(name: "Poly", kind: .instrument, clips: [aur1NoteClip()],
                         instrument: InstrumentDescriptor(kind: .polySynth))
        return ([hosted, audio, poly], hosted, audio)
    }

    /// ⭐ T1 (design §7.1). Through `AudioEngine.offlineCompensationTargets`
    /// itself: the planning renderer instantiates ZERO hosted instruments and
    /// every hosted insert. Counted twice, by two instruments that must agree:
    /// the `instantiator` spy (instantiations) and the planning registry's own
    /// ledger (prepare bodies, plus `.ready` per insert).
    ///
    /// ⭐ THE NEGATIVE CONTROL is the legacy plan path, run on the same session
    /// with the same spy: it must count ONE instrument. Without that arm, a
    /// spy that could not see instruments at all would pass the gate.
    ///
    /// A regression that bypasses the seam (a second `OfflineRenderer()` built
    /// behind its back) leaves the spy with zero EFFECTS, so the "every hosted
    /// insert" half is what catches it.
    @Test("AUR-1 T1: the compensation plan instantiates 0 hosted instruments and every hosted insert")
    func aur1PlanInstantiatesNoInstruments() async throws {
        let session = try aur1T1Session()
        let hostedDelay = try #require(session.hosted.effects.first?.id)
        let audioDelay = try #require(session.audio.effects.first?.id)
        let trackIDs = Set(session.tracks.map { $0.id })

        // THE GATE. The seam only installs the spy and keeps the renderer; it
        // prepares nothing itself.
        let engine = AudioEngine()
        let spy = AUR1InstantiationSpy(stubInstruments: true)
        engine.offlinePlanRendererForTesting = { renderer, _ in
            spy.install(on: renderer.auRegistry)
            spy.planner = renderer
        }
        let targets = await engine.offlineCompensationTargets(tracks: session.tracks)
        let registry = try #require(spy.planner?.auRegistry, """
            the seam never saw the planning renderer, so nothing below would be counted. \
            Is `offlinePlanRendererForTesting` still called by `offlineCompensationTargets`?
            """)
        aur1Record("T1 plan (inserts-only): instrument instantiations \(spy.instruments), "
                   + "effect instantiations \(spy.effects), ledger instrumentPrepares "
                   + "\(registry.instrumentPrepareCount), effectPrepares \(registry.effectPrepareCount), "
                   + "instrument status \(String(describing: registry.status[session.hosted.id]))")

        #expect(spy.instruments.isEmpty, """
            the compensation plan instantiated hosted instrument(s) \(spy.instruments). The plan reads \
            no instrument latency, so each one is a whole plugin load thrown away before the real \
            render loads it again (design §3.1).
            """)
        #expect(registry.instrumentPrepareCount == 0)
        #expect(registry.status[session.hosted.id] == nil)
        #expect(registry.preparedInstrument(forTrack: session.hosted.id) == nil)
        // "≥ 1 effect", made exact: both hosted inserts, each really ready.
        #expect(spy.effects == ["dely", "dely"])
        #expect(registry.effectPrepareCount == 2)
        #expect(registry.effectStatus[hostedDelay] == .ready, """
            the hosted insert ON the hosted-instrument track was not prepared: an implementation that \
            skips hosted-instrument TRACKS drops that strip's insert latency from the plan.
            """)
        #expect(registry.effectStatus[audioDelay] == .ready)
        #expect(spy.others.isEmpty)
        // Every strip is planned, the unprepared hosted-instrument strip included.
        #expect(Set(targets.keys) == trackIDs)

        // NEGATIVE CONTROL: the legacy plan path (both halves, the pre-AUR-1
        // body verbatim) with the same spy.
        let legacy = OfflineRenderer()
        let legacySpy = AUR1InstantiationSpy(stubInstruments: true)
        legacySpy.install(on: legacy.auRegistry)
        await legacy.prepareAudioUnits(tracks: session.tracks)
        let legacyTargets = legacy.compensationPlanTargets(tracks: session.tracks)
        aur1Record("T1 control (legacy plan): instrument instantiations \(legacySpy.instruments), "
                   + "effect instantiations \(legacySpy.effects), ledger instrumentPrepares "
                   + "\(legacy.auRegistry.instrumentPrepareCount), instrument status "
                   + "\(String(describing: legacy.auRegistry.status[session.hosted.id]))")
        #expect(legacySpy.instruments == ["samp"], """
            the control arm must count the one hosted instrument, or the gate above is blind.
            """)
        #expect(legacy.auRegistry.instrumentPrepareCount == 1)
        #expect(legacy.auRegistry.status[session.hosted.id] == .ready)
        #expect(legacySpy.effects == ["dely", "dely"])
        // And the smaller plan is the same plan (T2 pins this on a richer table).
        #expect(targets == legacyTargets)
    }

    // MARK: - T2: the smaller plan is the same plan

    /// T2's session table, one strip per row. Each row is a way the plan reads
    /// a hosted insert's latency, or a hosted instrument the plan must NOT need.
    private struct AUR1ParitySession {
        let tracks: [Track]
        /// GM sound bank (AUSampler + bank) carrying its OWN hosted
        /// AUPeakLimiter: THE LOAD-BEARING ROW. The plan no longer loads this
        /// strip's instrument, and must still read this strip's insert.
        let gm: Track
        /// `.audioUnit` AUMIDISynth routed into `bus`, carrying a BYPASSED
        /// hosted AUDynamicsProcessor (counted by `chainLatencyAll` only).
        let synth: Track
        /// A latent Apple insert on a plain audio track.
        let lim: Track
        /// A BYPASSED hosted AUDynamicsProcessor on a plain audio track.
        let byp: Track
        /// A sidechain KEY SOURCE (a `hasSends`-class strip to the planner).
        let key: Track
        /// A hosted AUPeakLimiter, then a compressor keyed off `key`.
        let duck: Track
        /// A bus with a hosted AUPeakLimiter.
        let bus: Track
    }

    private func aur1ParitySession() throws -> AUR1ParitySession {
        let fixtures = try TestSignals.fixtures()
        let bus = Track(name: "Bus", kind: .bus,
                        effects: [aur1HostedInsert(Self.aur1PeakLimiter)])
        let gm = aur1GMTrack(name: "GM+limiter",
                             effects: [aur1HostedInsert(Self.aur1PeakLimiter)])
        let synth = Track(name: "AUSynth->bus", kind: .instrument, clips: [aur1NoteClip()],
                          instrument: InstrumentDescriptor(
                              kind: .audioUnit,
                              audioUnit: AudioUnitConfig(component: Self.aur1Synth)),
                          outputBusID: bus.id,
                          effects: [aur1HostedInsert(Self.aur1Dynamics, bypassed: true)])
        let lim = aur1AudioTrack("Limited", url: fixtures.cos1k48Quarter,
                                 effects: [aur1HostedInsert(Self.aur1PeakLimiter)])
        let byp = aur1AudioTrack("BypassedDynamics", url: fixtures.cos1k48Quarter,
                                 effects: [aur1HostedInsert(Self.aur1Dynamics, bypassed: true)])
        let key = aur1AudioTrack("Key", url: fixtures.cos1k48Quarter)
        let duck = aur1AudioTrack("Ducked", url: fixtures.cos1k48Quarter, effects: [
            aur1HostedInsert(Self.aur1PeakLimiter),
            EffectDescriptor(kind: .compressor,
                             compressor: CompressorParams(thresholdDb: -20, ratio: 4,
                                                          attackMs: 0.1, releaseMs: 5,
                                                          kneeDb: 0, makeupDb: 0),
                             sidechainSourceTrackID: key.id),
        ])
        let routed = aur1AudioTrack("Routed->bus", url: fixtures.cos1k48Quarter,
                                    outputBusID: bus.id)
        let sender = aur1AudioTrack("Sender", url: fixtures.cos1k48Quarter,
                                    sends: [Send(destinationBusID: bus.id, level: 0.5)])
        return AUR1ParitySession(
            tracks: [gm, synth, lim, byp, key, duck, bus, routed, sender],
            gm: gm, synth: synth, lim: lim, byp: byp, key: key, duck: duck, bus: bus)
    }

    /// ⭐ T2 (design §7.1): PLAN PARITY. The production inserts-only plan equals
    /// the legacy both-halves plan, strip for strip, on the session table above.
    ///
    /// Anti-vacuity, before the comparison is read: the latent units really
    /// report latency (never assumed from a list); the legacy plan really loaded
    /// both hosted instruments; every strip is planned; not every target is 0.
    ///
    /// ⭐ TWO NEGATIVE CONTROLS. (1) A plan that prepares NO hosted insert
    /// differs, so the comparison can see hosted-insert latency at all. (2) A
    /// plan that prepares every insert EXCEPT those on instrument strips differs
    /// AT THE GM ROW, so the load-bearing row is really load-bearing.
    @Test("AUR-1 T2: plan parity — the inserts-only plan equals the legacy both-halves plan")
    func aur1PlanParityWithLegacyPlan() async throws {
        let s = try aur1ParitySession()
        func describe(_ targets: [UUID: Int]) -> String {
            s.tracks.map { track in "\(track.name)=\(targets[track.id].map { "\($0)" } ?? "-")" }
                .joined(separator: " ")
        }

        // The LEGACY plan: the pre-AUR-1 body verbatim.
        let legacy = OfflineRenderer()
        await legacy.prepareAudioUnits(tracks: s.tracks)
        let legacyTargets = legacy.compensationPlanTargets(tracks: s.tracks)

        // Anti-vacuity.
        let gmLimiterID = try #require(s.gm.effects.first?.id)
        let bypDynamicsID = try #require(s.byp.effects.first?.id)
        let limiterLatency = legacy.auRegistry.preparedEffect(forEffect: gmLimiterID)?.latencySamples ?? 0
        let dynamicsLatency = legacy.auRegistry.preparedEffect(forEffect: bypDynamicsID)?.latencySamples ?? 0
        aur1Record("T2 reported latency @48 kHz: AUPeakLimiter \(limiterLatency), "
                   + "AUDynamicsProcessor \(dynamicsLatency) samples")
        try #require(limiterLatency > 0, "AUPeakLimiter reports no latency: every row below is vacuous")
        try #require(dynamicsLatency > 0, "AUDynamicsProcessor reports no latency: the bypassed rows are vacuous")
        try #require(legacy.auRegistry.status[s.gm.id] == .ready, """
            the legacy plan did not load the GM instrument, so "parity" would compare two plans that \
            both skipped it
            """)
        try #require(legacy.auRegistry.status[s.synth.id] == .ready)
        let trackIDs = Set(s.tracks.map { $0.id })
        #expect(Set(legacyTargets.keys) == trackIDs)
        let legacyHasPositiveTarget = legacyTargets.values.contains { $0 > 0 }
        #expect(legacyHasPositiveTarget, "an all-zero plan cannot show parity")

        // THE GATE: the production plan, through the real entry point, with
        // the planning registry spied so parity is known to hold WITHOUT the
        // instruments (not because they happened to load).
        let engine = AudioEngine()
        let spy = AUR1InstantiationSpy(stubInstruments: false)
        engine.offlinePlanRendererForTesting = { renderer, _ in
            spy.install(on: renderer.auRegistry)
            spy.planner = renderer
        }
        let targets = await engine.offlineCompensationTargets(tracks: s.tracks)
        let registry = try #require(spy.planner?.auRegistry)
        aur1Record("T2 legacy plan:      \(describe(legacyTargets))")
        aur1Record("T2 inserts-only plan: \(describe(targets)) (instrument instantiations "
                   + "\(spy.instruments), effect instantiations \(spy.effects.count))")
        #expect(spy.instruments.isEmpty)
        #expect(registry.instrumentPrepareCount == 0)
        #expect(spy.effects.count == 6)
        let movedRows = s.tracks.filter { targets[$0.id] != legacyTargets[$0.id] }.map { $0.name }
        #expect(targets == legacyTargets,
                "the inserts-only plan moved a compensation target on: \(movedRows)")

        // NEGATIVE CONTROL 1: no hosted insert prepared at all.
        let bare = OfflineRenderer()
        let bareTargets = bare.compensationPlanTargets(tracks: s.tracks)
        aur1Record("T2 control, nothing prepared:        \(describe(bareTargets))")
        #expect(bareTargets != legacyTargets, "the gate cannot see hosted-insert latency at all")

        // NEGATIVE CONTROL 2: every insert EXCEPT those on instrument strips.
        let skip = OfflineRenderer()
        await skip.prepareHostedInsertEffects(tracks: s.tracks.filter { $0.kind != .instrument })
        let skipTargets = skip.compensationPlanTargets(tracks: s.tracks)
        aur1Record("T2 control, instrument-strip inserts skipped: \(describe(skipTargets))")
        #expect(skipTargets[s.gm.id] != legacyTargets[s.gm.id], """
            skipping the GM strip's own hosted limiter did not move its target, so the GM row \
            cannot catch a plan that drops instrument-strip inserts
            """)
    }

    // MARK: - Invariance: the rendered bytes do not move

    /// The tester's code-path shape with an Apple unit: `.audioUnit` AUSampler
    /// carrying `stateData` captured from a REAL bank-loaded sampler (the
    /// `FirstClipDropProbeTests` recipe), so the restore has real sample
    /// references to chase. `fullStateForDocument =` is the call that starts a
    /// lazy sampler's loading, and the old plan ran it in its throwaway.
    private func aur1CapturedSamplerState(program: Int) async throws -> Data {
        let registry = AUHostRegistry()
        let source = aur1GMTrack(name: "StateSource", program: program)
        await registry.prepare(track: source, sampleRate: 48_000)
        try #require(registry.status[source.id] == .ready)
        let state = try #require(registry.instrumentState(forTrack: source.id))
        registry.releaseInstrument(forTrack: source.id)
        return state
    }

    /// One arm of the invariance A/B, on a FRESH engine. `legacyPlan: false`
    /// is production exactly: the seam stays nil. `legacyPlan: true` rebuilds
    /// the pre-AUR-1 plan through the seam: it prepares the instrument half
    /// FIRST, then the plan prepares the inserts (the old `prepareAudioUnits`
    /// order), in the same throwaway, which dies where it always died because
    /// the seam keeps no reference to it. Renders `render.stems` when asked,
    /// then one `track.bounceInPlace` per entry in `bounce`, each from its OWN
    /// store so no bounce renders an earlier bounce's landed track.
    private func aur1RenderArm(_ session: AUR1InvarianceSession,
                               legacyPlan: Bool) async throws -> AUR1Arm {
        let tracks = session.tracks
        let seconds = 2.0
        let label = session.name.prefix(1)
        let engine = AudioEngine()
        let log = AUR1PlanLog()
        if legacyPlan {
            engine.offlinePlanRendererForTesting = { renderer, planned in
                await renderer.prepareHostedInstruments(tracks: planned)
                log.plans += 1
                log.instrumentPrepares += renderer.auRegistry.instrumentPrepareCount
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "daw-pro-aur1-\(label)-\(legacyPlan ? "legacy" : "inserts-only")-\(UUID().uuidString)")
        var files: [AUR1Arm.File] = []

        if session.stems {
            let store = ProjectStore()
            store.engine = engine
            store.tracks = tracks
            store.generationImportsDirectory = root.appendingPathComponent("imports-stems")
            let result = try await store.renderStems(
                toDirectory: root.appendingPathComponent("stems").path,
                durationSeconds: seconds, includeMixdown: session.includeMixdown)
            for stem in result.stems {
                let url = URL(fileURLWithPath: stem.path)
                files.append(AUR1Arm.File(label: "stem \(url.lastPathComponent)", url: url,
                                          bytes: try Data(contentsOf: url)))
            }
            if let mixdown = result.mixdown {
                let url = URL(fileURLWithPath: mixdown.path)
                files.append(AUR1Arm.File(label: "stems \(url.lastPathComponent)", url: url,
                                          bytes: try Data(contentsOf: url)))
            }
        }
        for target in session.bounce {
            let store = ProjectStore()
            store.engine = engine
            store.tracks = tracks
            store.generationImportsDirectory = root.appendingPathComponent("imports-\(target.label)")
            let result = try await store.bounceTrackInPlace(
                trackId: target.id, fromBeat: 0, durationSeconds: seconds, muteSource: false)
            let url = URL(fileURLWithPath: result.file)
            files.append(AUR1Arm.File(label: "bounce-in-place \(target.label)", url: url,
                                      bytes: try Data(contentsOf: url)))
        }
        // `ProjectStore.engine` is WEAK: the engine must outlive every render.
        withExtendedLifetime(engine) {}
        return AUR1Arm(files: files, planInstrumentPrepares: log.instrumentPrepares,
                       plans: log.plans, root: root)
    }

    private func aur1Digest(_ data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Both arms rendered the same files, byte for byte, and none is silent:
    /// two identical silences would prove nothing.
    private func aur1ExpectIdentical(_ legacy: AUR1Arm, _ insertsOnly: AUR1Arm,
                                     session: String) throws {
        let legacyLabels = legacy.files.map { $0.label }
        let insertsOnlyLabels = insertsOnly.files.map { $0.label }
        #expect(legacyLabels == insertsOnlyLabels)
        #expect(!insertsOnly.files.isEmpty)
        for (old, new) in zip(legacy.files, insertsOnly.files) {
            let channels = try TestSignals.readFile(new.url)
            var peak: Float = 0
            for channel in channels {
                peak = max(peak, TestSignals.peak(channel, in: 0..<channel.count))
            }
            let identical = old.bytes == new.bytes
            var differingSamples = 0
            if !identical {
                let oldChannels = try TestSignals.readFile(old.url)
                for (x, y) in zip(oldChannels, channels) {
                    for (u, v) in zip(x, y) where u != v { differingSamples += 1 }
                }
            }
            aur1Record("invariance \(session) | \(new.label): \(new.bytes.count) bytes, "
                       + "legacy sha \(aur1Digest(old.bytes)), inserts-only sha \(aur1Digest(new.bytes)), "
                       + "identical \(identical), differing samples \(differingSamples), peak \(peak)")
            #expect(identical, """
                \(session) \(new.label): the inserts-only plan changed the rendered file \
                (\(differingSamples) samples differ). Identical targets should force identical bytes.
                """)
            #expect(peak > 1e-3, "\(session) \(new.label) is silent: identical silences prove nothing")
        }
    }

    /// The invariance table, one session per row:
    ///   N: NO hosted AU (built-in instrument and effects, a latent built-in
    ///      limiter, a keyed compressor, a bus fed by sends), stems with the
    ///      mixdown, and two bounces;
    ///   A: Apple-unit instruments: a GM sound-bank track carrying its own
    ///      hosted AUPeakLimiter, beside an audio track with another; stems and
    ///      a bounce of the GM track;
    ///   R: the tester's code-path shape with an Apple unit, `.audioUnit`
    ///      AUSampler with RESTORED `stateData`, bounced in place (the verb that
    ///      separates M1 from M2 on the real plugin, design §5.1).
    private func aur1InvarianceSessions() async throws -> [AUR1InvarianceSession] {
        let fixtures = try TestSignals.fixtures()

        let echo = Track(name: "EchoBus", kind: .bus, effects: [
            EffectDescriptor(kind: .delay,
                             delay: DelayParams(timeMs: 250, feedback: 0.5, mix: 0.5,
                                                pingPong: 0, highCutHz: 12_000)),
        ])
        let kick = aur1AudioTrack("Kick", url: fixtures.cos1k48)
        let lead = aur1AudioTrack("Lead", url: fixtures.cos1k48Quarter, pan: -0.2,
                                  sends: [Send(destinationBusID: echo.id, level: 0.6)],
                                  effects: [
                                      EffectDescriptor(kind: .compressor,
                                                       compressor: CompressorParams(
                                                           thresholdDb: -20, ratio: 4,
                                                           attackMs: 0.1, releaseMs: 5,
                                                           kneeDb: 0, makeupDb: 0),
                                                       sidechainSourceTrackID: kick.id),
                                      EffectDescriptor(kind: .limiter),
                                  ])
        let poly = Track(name: "Poly", kind: .instrument, clips: [aur1NoteClip()],
                         instrument: InstrumentDescriptor(kind: .polySynth),
                         sends: [Send(destinationBusID: echo.id, level: 0.4)])
        let sessionN = AUR1InvarianceSession(
            name: "N (no hosted AU)", tracks: [echo, kick, lead, poly],
            stems: true, includeMixdown: true,
            bounce: [(label: "Poly", id: poly.id), (label: "Lead", id: lead.id)],
            plans: 3, planInstrumentPrepares: 0)

        let gm = aur1GMTrack(name: "GM", program: 0,
                             effects: [aur1HostedInsert(Self.aur1PeakLimiter)])
        let limited = aur1AudioTrack("LimitedAudio", url: fixtures.cos1k48Quarter,
                                     effects: [aur1HostedInsert(Self.aur1PeakLimiter)])
        let sessionA = AUR1InvarianceSession(
            name: "A (GM + hosted limiters)", tracks: [gm, limited],
            stems: true, includeMixdown: false,
            bounce: [(label: "GM", id: gm.id)],
            plans: 2, planInstrumentPrepares: 2)

        let state = try await aur1CapturedSamplerState(program: 66)
        aur1Record("invariance R: captured AUSampler state \(state.count) bytes, sha \(aur1Digest(state))")
        let restored = Track(name: "RestoredSampler", kind: .instrument,
                             clips: [aur1NoteClip(pitch: 62)],
                             instrument: InstrumentDescriptor(
                                 kind: .audioUnit,
                                 audioUnit: AudioUnitConfig(component: Self.aur1Sampler,
                                                            stateData: state)))
        let sessionR = AUR1InvarianceSession(
            name: "R (restored-state AUSampler)", tracks: [restored],
            stems: false, includeMixdown: false,
            bounce: [(label: "RestoredSampler", id: restored.id)],
            plans: 1, planInstrumentPrepares: 1)

        return [sessionN, sessionA, sessionR]
    }

    /// ⭐ INVARIANCE. `render.stems` and `track.bounceInPlace`, through the REAL
    /// store path, render the same bytes under the legacy plan and the
    /// inserts-only plan, on every row of `aur1InvarianceSessions`.
    ///
    /// Identical targets force identical rings, so for deterministic units this
    /// holds by construction (design §3.1); this measures it. Each arm renders
    /// on its own fresh engine, so the only difference between the arms is what
    /// the plan prepared, and `planInstrumentPrepares` proves the legacy arm
    /// really loaded the hosted instruments (A, R) that production did not.
    ///
    /// ⚠️ SCOPE, stated so it is not over-read: the legacy arm is rebuilt
    /// THROUGH `offlineCompensationTargets` (the seam adds the instrument half),
    /// so this isolates exactly the instrument-half difference. Any OTHER change
    /// to the plan moves both arms alike and is T2's to catch; the split of
    /// `prepareAudioUnits` on the real render is the digest probe's.
    @Test("AUR-1 invariance: stems and bounce-in-place bytes match the legacy plan's")
    func aur1RenderedBytesMatchLegacyPlan() async throws {
        for session in try await aur1InvarianceSessions() {
            let legacy = try await aur1RenderArm(session, legacyPlan: true)
            let insertsOnly = try await aur1RenderArm(session, legacyPlan: false)
            aur1Record("invariance \(session.name): legacy arm ran \(legacy.plans) plans, "
                       + "\(legacy.planInstrumentPrepares) plan instrument prepares")
            #expect(legacy.plans == session.plans, "\(session.name): stems and each bounce ask for one plan")
            #expect(legacy.planInstrumentPrepares == session.planInstrumentPrepares, """
                \(session.name): the legacy arm must load each hosted instrument in each plan, or the \
                two arms do not differ in the one thing under test
                """)
            try aur1ExpectIdentical(legacy, insertsOnly, session: session.name)
            // ~0.8 MB per file: never leave a full-suite run's renders in the temp dir.
            try? FileManager.default.removeItem(at: legacy.root)
            try? FileManager.default.removeItem(at: insertsOnly.root)
        }
    }

    /// PROBE, not a gate (the `FirstClipDropProbeTests` precedent): enabled
    /// only when `AUR1_DIGEST_OUT` names a file. Renders every invariance row
    /// through the PRODUCTION path alone and writes one SHA-256 per rendered
    /// file. Run once on the tree before AUR-1 and once after: identical files
    /// are the literal before/after, which the in-process A/B cannot give,
    /// because it also covers `prepareAudioUnits`' split on the REAL render.
    @Test("AUR-1 probe: production-path stems/bounce digests",
          .enabled(if: ProcessInfo.processInfo.environment["AUR1_DIGEST_OUT"] != nil))
    func aur1ProductionPathDigestProbe() async throws {
        let out = try #require(ProcessInfo.processInfo.environment["AUR1_DIGEST_OUT"])
        var lines: [String] = []
        for session in try await aur1InvarianceSessions() {
            let arm = try await aur1RenderArm(session, legacyPlan: false)
            for file in arm.files {
                let channels = try TestSignals.readFile(file.url)
                var peak: Float = 0
                for channel in channels {
                    peak = max(peak, TestSignals.peak(channel, in: 0..<channel.count))
                }
                let full = SHA256.hash(data: file.bytes).map { String(format: "%02x", $0) }.joined()
                lines.append("\(session.name) | \(file.label) | \(file.bytes.count) bytes | sha256 \(full) | peak \(peak)")
                #expect(peak > 1e-3, "\(session.name) \(file.label) is silent")
            }
            try? FileManager.default.removeItem(at: arm.root)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: out))
        aur1Record("digest probe wrote \(lines.count) lines to \(out)")
        #expect(lines.count == 11, "N: 4 stems + mixdown + 2 bounces; A: 2 stems + 1 bounce; R: 1 bounce")
    }
}
