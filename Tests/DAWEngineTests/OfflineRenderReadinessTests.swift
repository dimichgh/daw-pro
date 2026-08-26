import AVFAudio
import AudioToolbox
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// LEG R-1 — THE SILENT HEAD OF A BOUNCE.
// docs/research/design-m29-oop-au-hosting.md §15.
//
// THE DEFECT (measured by a tester 2026-08-20, not hypothesised): an offline
// render of a track whose instrument is a hosted Audio Unit starts SILENT for
// the first 8–25 seconds, and the lost span scales with how many distinct
// sample zones the part touches. A 296 s bounce of a sax on a 46-zone SFZ came
// back silent until 25.25 s. In the tester's words: *"The worst kind: the
// render succeeds, the loudness report looks plausible, and the file is quietly
// missing its opening."*
//
// THE MECHANISM IS APPLE'S OWN, and it is documented in `AUAudioUnit.h`
// (:1024-1035): `renderingOffline` exists so a host can tell a unit there are
// no realtime deadlines, at which point the unit *"may respond by … allowing
// itself to block at render time if data being generated on secondary work
// threads is not ready in time. (Normally, in a realtime thread, this data
// would have to be dropped.)"* Our offline graph pulls faster than realtime
// while the plugin's loader runs in wall time; the plugin drops, correctly, for
// what it believes is a realtime context. This host had never set the property.
//
// ⚠️ AN EXTENSION OF `AUHostingTests`, NOT A NEW `@Suite`.
// `MainActorOccupancySiteTests` Leg C caps `@MainActor`-isolated suites at 330
// and the tree sits exactly on it (m23-aw-4), so a new suite here would have to
// be free — and every assertion below touches `AUHostRegistry`, which is
// main-actor-isolated. Extending the existing main-actor suite adds ZERO suites
// and zero isolation, which is the same reason `FirstClipDropProbeTests`
// extends `SoundBankHostingTests`. It is also the right conceptual home.
//
// ⭐ WHY A STUB AU IS THE GATE AND A REAL PLUGIN IS NOT (§15.5, verbatim
// rationale). The obvious gate — "bounce a real lazy-loading plugin, cold,
// assert non-silence" — is REJECTED: "cold" is not reproducible inside a test
// process, and per §15.1 the sax case may not be cache-sensitive at all, so
// that gate can pass VACUOUSLY. The stub below is deterministic and headless
// and it tests THE HOST'S BEHAVIOUR rather than a plugin's cache state. Real
// plugins appear here only as MEASUREMENTS, labelled as such.

// MARK: - The instrumented stub AU

/// Cross-thread observation store for one stub AU instance.
///
/// `allocateRenderResources` may run OFF the main actor: `AUHostRegistry`
/// routes DLS-family components (AUSampler 'samp'/'appl', which is the
/// component identity these tests use for the registry's component LOOKUP)
/// onto `dlsBankQueue` (m18-d/m19-j). The render block runs on the render
/// thread. Neither overlaps the other or the reads below — the registry's
/// prepare completes before any pull, and the test reads only after the render
/// loop has finished — so this is the `SidechainSpikeAU.Tape` discipline: an
/// `@unchecked Sendable` box with a documented write window, no locks.
private final class OfflineFlagObservations: @unchecked Sendable {
    /// Quanta the stub withholds output for when it was NOT told it is
    /// rendering offline — the model of a sampler whose zones are still loading
    /// on a secondary thread and which, in what it believes is a realtime
    /// context, must output silence rather than miss a deadline.
    let withheldQuanta: Int

    /// ⭐ THE LOAD-BEARING OBSERVATION: the value of `isRenderingOffline` READ
    /// INSIDE `allocateRenderResources`. A flag set AFTER allocate is a silent
    /// no-op that would still read back `true` from the property afterwards, so
    /// "is it set?" cannot distinguish the fix from the bug. "Was it set when
    /// the unit allocated?" can.
    var flagAtAllocate = false
    var allocateCalls = 0
    /// Render-thread counter; read only after the render loop has finished.
    var renderedQuanta = 0

    init(withheldQuanta: Int) { self.withheldQuanta = withheldQuanta }
}

/// A music device that models the measured defect exactly: it emits a steady
/// 440 Hz tone, EXCEPT that when it was not told it is rendering offline it
/// withholds output (exact zeros) for its first `withheldQuanta` render calls.
///
/// It ignores MIDI entirely and sounds from frame 0 — deliberately. The
/// question under test is whether the HEAD of the bounce survives, and a stub
/// whose output depended on note scheduling would let a scheduling regression
/// masquerade as this defect (and vice versa).
private final class OfflineFlagStubInstrumentAU: AUAudioUnit {
    let observations: OfflineFlagObservations
    private var busArray: AUAudioUnitBusArray!

    init(componentDescription: AudioComponentDescription,
         observations: OfflineFlagObservations) throws {
        self.observations = observations
        try super.init(componentDescription: componentDescription, options: [])
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        busArray = AUAudioUnitBusArray(audioUnit: self, busType: .output,
                                       busses: [try AUAudioUnitBus(format: format)])
    }

    override var outputBusses: AUAudioUnitBusArray { busArray }

    override func allocateRenderResources() throws {
        // Read the flag BEFORE `super`, so the recorded value is what the unit
        // was holding at the moment the host asked it to allocate.
        observations.flagAtAllocate = isRenderingOffline
        observations.allocateCalls += 1
        try super.allocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let observations = self.observations
        return { _, _, frameCount, _, outputData, _, _ in
            let quantum = observations.renderedQuanta
            observations.renderedQuanta += 1
            let sounding = observations.flagAtAllocate || quantum >= observations.withheldQuanta
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            for buffer in buffers {
                guard let raw = buffer.mData else { continue }
                let samples = raw.assumingMemoryBound(to: Float.self)
                for frame in 0..<Int(frameCount) {
                    samples[frame] = sounding ? 0.5 : 0
                }
            }
            return noErr
        }
    }
}

/// The insert-effect mirror: two bus arrays (`prepareEffect` sets formats on
/// BOTH and enables input bus 0), passthrough render, same allocate-time
/// observation.
private final class OfflineFlagStubEffectAU: AUAudioUnit {
    let observations: OfflineFlagObservations
    private var inputArray: AUAudioUnitBusArray!
    private var outputArray: AUAudioUnitBusArray!

    init(componentDescription: AudioComponentDescription,
         observations: OfflineFlagObservations) throws {
        self.observations = observations
        try super.init(componentDescription: componentDescription, options: [])
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inputArray = AUAudioUnitBusArray(audioUnit: self, busType: .input,
                                         busses: [try AUAudioUnitBus(format: format)])
        outputArray = AUAudioUnitBusArray(audioUnit: self, busType: .output,
                                          busses: [try AUAudioUnitBus(format: format)])
    }

    override var inputBusses: AUAudioUnitBusArray { inputArray }
    override var outputBusses: AUAudioUnitBusArray { outputArray }

    override func allocateRenderResources() throws {
        observations.flagAtAllocate = isRenderingOffline
        observations.allocateCalls += 1
        try super.allocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let observations = self.observations
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            observations.renderedQuanta += 1
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            var flags = AudioUnitRenderActionFlags()
            return pullInputBlock(&flags, timestamp, frameCount, 0, outputData)
        }
    }
}

extension AUHostingTests {
    /// The registry only reaches its `instantiator` seam after
    /// `AVAudioUnitComponentManager` MATCHES the component, so the stub has to
    /// wear the identity of something really installed. AUSampler is the
    /// obvious choice and is DLS-family, which routes the stub's allocate onto
    /// `dlsBankQueue` — deliberately accepted (it is the production path for
    /// this identity) and the reason `OfflineFlagObservations` is written to be
    /// safe off the main actor.
    private static var orrSampler: AudioUnitComponentID {
        AudioUnitComponentID(subType: "samp", manufacturer: "appl")
    }

    /// AUDelay — a real, installed, v2 Apple effect, used for the byte
    /// containment measurement below.
    private static var orrDelay: AudioUnitComponentID {
        AudioUnitComponentID(type: "aufx", subType: "dely", manufacturer: "appl")
    }

    private func orrStubTrack() -> Track {
        Track(name: "OfflineFlagStub", kind: .instrument,
              clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 4,
                           notes: [MIDINote(pitch: 60, velocity: 100,
                                            startBeat: 0, lengthBeats: 3)])],
              instrument: InstrumentDescriptor(
                  kind: .audioUnit,
                  audioUnit: AudioUnitConfig(component: Self.orrSampler)))
    }

    /// One offline render of the stub-instrument track, through the REAL
    /// production path (`OfflineRenderer.prepareAudioUnits` → `render`), with
    /// the renderer's registry built either as production builds it
    /// (`rendersOffline: true`) or as the tree built it BEFORE Leg R-1
    /// (`rendersOffline: false` — the negative control).
    private func orrRenderStub(rendersOffline: Bool, withheldQuanta: Int,
                               seconds: Double) async throws
        -> (left: [Float], observations: OfflineFlagObservations) {
        let observations = OfflineFlagObservations(withheldQuanta: withheldQuanta)
        let renderer = OfflineRenderer(sampleRate: 48_000, channelCount: 2,
                                       maximumFrameCount: RenderBlockSize.offlineFrames,
                                       rendersOffline: rendersOffline)
        renderer.auRegistry.instantiator = { description, _ in
            try OfflineFlagStubInstrumentAU(componentDescription: description,
                                            observations: observations)
        }
        let track = orrStubTrack()
        await renderer.prepareAudioUnits(tracks: [track])
        let status = renderer.auRegistry.status[track.id]
        try #require(status == .ready, """
            the stub AU did not reach .ready (\(String(describing: status))) — every window \
            measured below would be silent BY CONSTRUCTION, which reads exactly like the defect \
            under test. Fix the stub, do not reinterpret the silence.
            """)
        let audio = try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                        fromBeat: 0, durationSeconds: seconds)
        return (audio.channelData[0], observations)
    }

    // MARK: - Site + order

    /// STRUCTURAL GATE 1 — the offline registry flags its instrument, the live
    /// registry does not, and BOTH arms are checked at the moment that matters:
    /// inside `allocateRenderResources`.
    ///
    /// The live arm is not decoration. `renderingOffline` invites a plugin to
    /// BLOCK AT RENDER TIME; on the live engine's registry that is an
    /// invitation to stall the render thread, which is the exact inverse of
    /// every real-time law this project holds. This pins that the flag can
    /// never leak there.
    @Test("Leg R-1 site: the OFFLINE registry flags its AUs before allocate; the LIVE one never does")
    func offlineRegistryFlagsInstrumentsAndLiveRegistryDoesNot() async throws {
        for rendersOffline in [true, false] {
            let observations = OfflineFlagObservations(withheldQuanta: 0)
            let registry = AUHostRegistry(rendersOffline: rendersOffline)
            registry.instantiator = { description, _ in
                try OfflineFlagStubInstrumentAU(componentDescription: description,
                                                observations: observations)
            }
            let track = Track(name: "AU", kind: .instrument, clips: [],
                              instrument: InstrumentDescriptor(
                                  kind: .audioUnit,
                                  audioUnit: AudioUnitConfig(component: Self.orrSampler)))
            await registry.prepare(track: track, sampleRate: 48_000)
            try #require(registry.status[track.id] == .ready)
            print("[measured] Leg R-1 instrument rendersOffline=\(rendersOffline): "
                  + "allocateCalls \(observations.allocateCalls), "
                  + "flagAtAllocate \(observations.flagAtAllocate)")
            // Without this the test would pass vacuously against a build in
            // which allocate never ran at all.
            #expect(observations.allocateCalls == 1)
            #expect(observations.flagAtAllocate == rendersOffline, """
                an AU prepared by a registry with rendersOffline=\(rendersOffline) observed \
                isRenderingOffline=\(observations.flagAtAllocate) at allocate time. For the \
                offline arm that means the fix is absent or lands too late; for the LIVE arm it \
                means a plugin has been invited to block the render thread.
                """)
            #expect(registry.rendersOffline == rendersOffline)
        }
    }

    /// STRUCTURAL GATE 2 — the effect path carries the same contract.
    ///
    /// A hosted reverb whose tail data is generated on a secondary thread has
    /// the same failure shape as a lazy sampler, so the flag is set for both.
    /// ⚠️ Apple's sentence offers the unit a SECOND response — *"using a more
    /// expensive signal processing algorithm"* — which on an effect would
    /// change rendered bytes on bounces that were already correct. That is the
    /// containment measured by `offlineFlagLeavesBuiltInEffectBytesUnchanged`
    /// below; it is machine-checked, not argued.
    @Test("Leg R-1 site: hosted EFFECTS are flagged before allocate on the offline registry only")
    func offlineRegistryFlagsEffectsAndLiveRegistryDoesNot() async throws {
        for rendersOffline in [true, false] {
            let observations = OfflineFlagObservations(withheldQuanta: 0)
            let registry = AUHostRegistry(rendersOffline: rendersOffline)
            registry.instantiator = { description, _ in
                try OfflineFlagStubEffectAU(componentDescription: description,
                                            observations: observations)
            }
            let effectID = UUID()
            await registry.prepareEffect(effectID: effectID,
                                         config: AudioUnitConfig(component: Self.orrDelay),
                                         sampleRate: 48_000)
            try #require(registry.effectStatus[effectID] == .ready)
            print("[measured] Leg R-1 effect rendersOffline=\(rendersOffline): "
                  + "allocateCalls \(observations.allocateCalls), "
                  + "flagAtAllocate \(observations.flagAtAllocate)")
            #expect(observations.allocateCalls == 1)
            #expect(observations.flagAtAllocate == rendersOffline)
        }
    }

    /// STRUCTURAL GATE 3 — production wires it. `OfflineRenderer` owns its own
    /// registry precisely so this is settable without touching live playback
    /// (§15.5: *"it is safe only because the offline renderer already owns a
    /// separate registry"*), and `AudioEngine`'s registry must stay unflagged.
    ///
    /// The `AUHostRegistry(rendersOffline:)` parameter is a `let`, so "the live
    /// registry never sets it" is structural rather than conventional — there
    /// is no setter to reach. This pins the two production values anyway,
    /// because a future refactor could pass the wrong one.
    @Test("Leg R-1 wiring: OfflineRenderer's registry renders offline, AudioEngine's does not")
    func productionRegistriesCarryTheRightFlag() async throws {
        #expect(OfflineRenderer().auRegistry.rendersOffline)
        #expect(AUHostRegistry().rendersOffline == false)
    }

    // MARK: - ⭐ THE LOAD-BEARING GATE

    /// ⭐⭐ **A LAZY-LOADING INSTRUMENT'S FIRST SECONDS MUST REACH THE BOUNCE.**
    ///
    /// The stub withholds output for its first 40 render calls unless it was
    /// told at allocate time that this is an offline render — 40 × 512 frames =
    /// 20 480 frames = 0.427 s of dead head, the same SHAPE as the tester's
    /// 25.25 s, scaled to a test's patience.
    ///
    /// ⭐ THE NEGATIVE-CONTROL ARM IS THE HALF THAT MAKES THIS A GATE. It
    /// re-renders through a registry built the way the tree built it BEFORE Leg
    /// R-1 and REQUIRES the head to be dead. Without it, a build that fixed
    /// nothing — or one where the stub simply sounds unconditionally — would
    /// pass the first arm and prove nothing. The control also asserts its own
    /// TAIL is sounding, so "silent everywhere" cannot masquerade as "silent at
    /// the head".
    ///
    /// Figures measured on this rig 2026-08-20 at 48 kHz: head RMS 0.5 flagged
    /// vs exactly 0.0 unflagged; tail RMS 0.5 in both arms.
    @Test("GATE: a lazy-loading hosted instrument's HEAD survives an offline bounce")
    func lazyLoadingInstrumentHeadSurvivesTheBounce() async throws {
        let withheld = 40
        let headWindow = 0..<12_000        // 0.25 s — well inside the dead span
        let tailWindow = 30_000..<60_000   // past it in both arms

        let fixed = try await orrRenderStub(rendersOffline: true,
                                            withheldQuanta: withheld, seconds: 1.5)
        let fixedHead = TestSignals.rms(fixed.left, in: headWindow)
        let fixedTail = TestSignals.rms(fixed.left, in: tailWindow)
        print("[measured] Leg R-1 GATE flagged: head RMS \(fixedHead), tail RMS \(fixedTail), "
              + "quanta \(fixed.observations.renderedQuanta)")
        #expect(fixed.observations.flagAtAllocate)
        #expect(fixedHead > 0.1, """
            the first 0.25 s of a hosted-instrument bounce is silent (RMS \(fixedHead)) — this is \
            the 2026-08-20 field report: the render succeeds and the file is quietly missing its \
            opening.
            """)
        #expect(fixedTail > 0.1)

        // ⭐ NEGATIVE CONTROL — the pre-Leg-R-1 host, same stub, same render.
        let broken = try await orrRenderStub(rendersOffline: false,
                                             withheldQuanta: withheld, seconds: 1.5)
        let brokenHead = TestSignals.rms(broken.left, in: headWindow)
        let brokenTail = TestSignals.rms(broken.left, in: tailWindow)
        print("[measured] Leg R-1 GATE unflagged (control): head RMS \(brokenHead), "
              + "tail RMS \(brokenTail)")
        #expect(broken.observations.flagAtAllocate == false)
        #expect(brokenHead < 1e-4, """
            the control cannot see a dead bounce head (RMS \(brokenHead)) — the assertions above \
            are vacuous and this is not a gate.
            """)
        #expect(brokenTail > 0.1, """
            the control's TAIL is silent too, so it is measuring "silent everywhere" rather than \
            "silent at the head" — it discriminates nothing.
            """)
    }

    // MARK: - Byte containment (the m23-bv shape: measured, argued, machine-checked)

    /// This change makes hosted-AU bounces differ from the pre-Leg-R-1 tree —
    /// that is the entire point for a lazy INSTRUMENT. For hosted EFFECTS there
    /// is no such intent, and Apple's own sentence offers the unit a way to
    /// change bytes anyway (*"a more expensive signal processing algorithm"*).
    /// So the containment is measured rather than assumed.
    ///
    /// MEASURED 2026-08-20 through the raw v2 API on this machine: AUDelay
    /// answers `AudioUnitGetPropertyInfo(kAudioUnitProperty_OfflineRender)` with
    /// **-10879 `kAudioUnitErr_InvalidProperty`** and rejects the set with the
    /// same status — Apple's built-in effects do not implement the property at
    /// all, so they cannot change behaviour under it. This test checks the
    /// consequence end-to-end rather than trusting that reasoning: the same
    /// bounce, through a real AUDelay insert, flag off vs flag on, byte-for-byte.
    @Test("Leg R-1 containment: the offline flag leaves a built-in AU effect's bounce byte-identical")
    func offlineFlagLeavesBuiltInEffectBytesUnchanged() async throws {
        func render(rendersOffline: Bool) async throws -> [Float] {
            var track = Track(
                name: "PolyWithDelay", kind: .instrument,
                clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 4,
                             notes: [MIDINote(pitch: 60, velocity: 100,
                                              startBeat: 0, lengthBeats: 2)])],
                instrument: InstrumentDescriptor(kind: .polySynth))
            track.effects = [EffectDescriptor(kind: .audioUnit,
                                              audioUnit: AudioUnitConfig(component: Self.orrDelay))]
            let renderer = OfflineRenderer(sampleRate: 48_000, channelCount: 2,
                                           maximumFrameCount: RenderBlockSize.offlineFrames,
                                           rendersOffline: rendersOffline)
            await renderer.prepareAudioUnits(tracks: [track])
            let effectID = try #require(track.effects.first?.id)
            try #require(renderer.auRegistry.effectStatus[effectID] == .ready)
            let audio = try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                            fromBeat: 0, durationSeconds: 2.0)
            return audio.channelData[0]
        }

        let off = try await render(rendersOffline: false)
        let on = try await render(rendersOffline: true)
        let differing = zip(off, on).reduce(into: 0) { count, pair in
            if pair.0 != pair.1 { count += 1 }
        }
        print("[measured] Leg R-1 AUDelay containment: \(off.count) frames, "
              + "\(differing) differing, off RMS \(TestSignals.rms(off, in: 0..<off.count)), "
              + "on RMS \(TestSignals.rms(on, in: 0..<on.count))")
        // The bounce has to be AUDIBLE, or "identical" would be two silences.
        #expect(TestSignals.rms(off, in: 0..<off.count) > 1e-3)
        #expect(off.count == on.count)
        #expect(differing == 0, """
            setting renderingOffline changed \(differing) samples of a built-in AU effect's bounce. \
            That is Apple's OTHER documented response to the flag ("a more expensive signal \
            processing algorithm") and it is a finding, not a failure — record the numbers before \
            deciding whether effects should keep the flag.
            """)
    }

    // MARK: - Measurements about the world (observations, deliberately narrow)

    /// ⚠️ **A SETTER'S RETURN IS NOT PROOF IT TOOK — and here is the proof of
    /// that, machine-checked.** `AUAudioUnitV2Bridge` reports
    /// `isRenderingOffline == true` after a set even for units whose underlying
    /// v2 implementation REJECTED `kAudioUnitProperty_OfflineRender`: the bridge
    /// caches the value and swallows the error. So the Objective-C read-back is
    /// worthless as evidence, which is why every gate above observes the flag
    /// from INSIDE the unit's own `allocateRenderResources` instead.
    ///
    /// Measured here through the raw v2 API, the only surface that answers
    /// honestly. Apple's word in the header is *"may"*, and this is what "may"
    /// looks like in the installed population: music devices implement it,
    /// built-in effects do not.
    @Test("Leg R-1 measurement: which Apple components really accept kAudioUnitProperty_OfflineRender")
    func appleComponentAcceptanceOfTheOfflineRenderProperty() async throws {
        func acceptance(type: OSType, subType: OSType,
                        manufacturer: OSType) -> (set: OSStatus, value: UInt32) {
            var description = AudioComponentDescription(
                componentType: type, componentSubType: subType,
                componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description) else {
                return (-1, 0)
            }
            var instance: AudioUnit?
            guard AudioComponentInstanceNew(component, &instance) == noErr,
                  let unit = instance else { return (-2, 0) }
            defer { AudioComponentInstanceDispose(unit) }
            var flag: UInt32 = 1
            let setStatus = AudioUnitSetProperty(
                unit, kAudioUnitProperty_OfflineRender, kAudioUnitScope_Global, 0,
                &flag, UInt32(MemoryLayout<UInt32>.size))
            var readBack: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioUnitGetProperty(unit, kAudioUnitProperty_OfflineRender,
                                     kAudioUnitScope_Global, 0, &readBack, &size)
            return (setStatus, readBack)
        }

        let sampler = acceptance(type: kAudioUnitType_MusicDevice,
                                 subType: 0x7361_6D70, manufacturer: 0x6170_706C)  // 'samp'/'appl'
        let dls = acceptance(type: kAudioUnitType_MusicDevice,
                             subType: 0x646C_7320, manufacturer: 0x6170_706C)      // 'dls '/'appl'
        let delay = acceptance(type: kAudioUnitType_Effect,
                               subType: 0x6465_6C79, manufacturer: 0x6170_706C)    // 'dely'/'appl'
        print("[measured] Leg R-1 v2 OfflineRender acceptance — "
              + "AUSampler set=\(sampler.set) value=\(sampler.value), "
              + "DLSMusicDevice set=\(dls.set) value=\(dls.value), "
              + "AUDelay set=\(delay.set) value=\(delay.value) "
              + "(-10879 = kAudioUnitErr_InvalidProperty)")
        // If Apple's own samplers ever stopped accepting the property, the
        // cheap half of this leg would have quietly stopped doing anything.
        #expect(sampler.set == noErr)
        #expect(sampler.value == 1)

        // PERSISTENCE, measured on the same instance: the property survives
        // uninitialize/initialize. This is what makes the re-assertion on the
        // rate-renegotiation path redundant today, and it is recorded here so
        // the claim has a number behind it rather than a memory.
        var samplerDescription = AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice, componentSubType: 0x7361_6D70,
            componentManufacturer: 0x6170_706C, componentFlags: 0, componentFlagsMask: 0)
        if let component = AudioComponentFindNext(nil, &samplerDescription) {
            var instance: AudioUnit?
            if AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance {
                defer { AudioComponentInstanceDispose(unit) }
                var flag: UInt32 = 1
                _ = AudioUnitSetProperty(unit, kAudioUnitProperty_OfflineRender,
                                         kAudioUnitScope_Global, 0, &flag,
                                         UInt32(MemoryLayout<UInt32>.size))
                let initStatus = AudioUnitInitialize(unit)
                let uninitStatus = AudioUnitUninitialize(unit)
                var survived: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                _ = AudioUnitGetProperty(unit, kAudioUnitProperty_OfflineRender,
                                         kAudioUnitScope_Global, 0, &survived, &size)
                print("[measured] Leg R-1 OfflineRender persistence — AUSampler "
                      + "init=\(initStatus) uninit=\(uninitStatus) valueAfter=\(survived)")
                #expect(survived == 1)
            }
        }
    }

    /// OBSERVATION, EXPLICITLY NON-GATING (§15.5 point 5): what the flag does
    /// to a bounce of the built-in GM sound bank — the closest real
    /// lazy-loading instrument this test process can drive.
    ///
    /// ⚠️ THIS IS NOT EXPECTED TO REPRODUCE THE DEFECT, and the mechanism is in
    /// our own code rather than a guess: `AUHostRegistry.performPrepare` AWAITS
    /// `loadSoundBank` inside the prepare body, and `prepareAudioUnits` is
    /// awaited before the first pull, so the bank is fully resident before the
    /// render clock starts. There is no secondary-thread load left in flight to
    /// drop. The tester's shape is different — a third-party plugin restoring
    /// `fullStateForDocument`, which returns immediately while the plugin loads
    /// on its own threads.
    ///
    /// It IS asserted rather than merely printed, and the reason is that the
    /// `.soundBank` path is the one where the flag lands on a unit that
    /// genuinely accepts it (AUSampler, per the acceptance test above) AND
    /// where the registry does more work after allocate — `loadSoundBank` runs
    /// post-allocate inside the same prepare, and T6 already measured that
    /// AUSampler's loaded bank is fragile across resource-lifecycle
    /// transitions. It is also the DEFAULT hosted bounce path, far more
    /// travelled than a third-party AU. An unasserted zero on that path is
    /// exactly the shape of a regression nobody sees.
    @Test("Leg R-1 containment: the offline flag leaves a real GM sound-bank bounce byte-identical")
    func offlineFlagEffectOnAGMSoundBankBounce() async throws {
        func render(rendersOffline: Bool) async throws -> [Float] {
            let track = Track(
                name: "GM", kind: .instrument,
                clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 4,
                             notes: [MIDINote(pitch: 62, velocity: 100,
                                              startBeat: 0, lengthBeats: 2)])],
                instrument: InstrumentDescriptor(
                    kind: .soundBank,
                    soundBank: SoundBankConfig(source: .generalMIDI, program: 66, bankMSB: 121)))
            let renderer = OfflineRenderer(sampleRate: 48_000, channelCount: 2,
                                           maximumFrameCount: RenderBlockSize.offlineFrames,
                                           rendersOffline: rendersOffline)
            await renderer.prepareAudioUnits(tracks: [track])
            let status = renderer.auRegistry.status[track.id]
            try #require(status == .ready, """
                the GM bank did not reach .ready (\(String(describing: status))) — an honest-silence \
                prepare failure reads exactly like the defect under observation (the T1 rule).
                """)
            let audio = try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                            fromBeat: 0, durationSeconds: 2.0)
            return audio.channelData[0]
        }

        let off = try await render(rendersOffline: false)
        let on = try await render(rendersOffline: true)
        let differing = zip(off, on).reduce(into: 0) { count, pair in
            if pair.0 != pair.1 { count += 1 }
        }
        let headOff = TestSignals.rms(off, in: 0..<12_000)
        let headOn = TestSignals.rms(on, in: 0..<12_000)
        print("[measured] Leg R-1 GM sax bounce — head RMS off \(headOff), on \(headOn); "
              + "\(differing)/\(off.count) samples differ")
        // Audible in both arms first, or "identical" would be two silences.
        #expect(headOff > 1e-3)
        #expect(headOn > 1e-3)
        #expect(off.count == on.count)
        #expect(differing == 0, """
            setting renderingOffline changed \(differing) samples of a GM sound-bank bounce. \
            AUSampler DOES accept the property, so this is a legitimate plugin response and a \
            FINDING rather than a failure — record the numbers, then decide, because every \
            `.soundBank` bounce in the app goes through this path.
            """)
    }

    // MARK: - The second allocate site

    /// The registry is not the only place an offline AU allocates:
    /// `HostedAUInstrument.prepare(sampleRate:…)` deallocates and REallocates
    /// when the graph connects at a rate the registry did not prepare for.
    /// Production offline renders do not reach it (the renderer prepares at its
    /// own `sampleRate` and the graph connects at that same rate, so the guard
    /// at `HostedAUInstrument.swift:126` returns early), so this drives the
    /// branch directly. `allocateCalls == 2` proves the renegotiation really
    /// ran; `flagAtAllocate` then reports the SECOND allocate's observation,
    /// overwriting the first.
    ///
    /// ⚠️⚠️ WHAT THIS TEST DOES **NOT** DO, said out loud because the name
    /// would otherwise imply it: it does not discriminate the re-assertion line
    /// in `HostedAUInstrument.prepare`. That line was PLANTED AWAY and this
    /// test stayed GREEN. The reason is a measurement, not an oversight —
    /// `renderingOffline` SURVIVES a deallocate/allocate cycle on every
    /// component available here (a plain `AUAudioUnit` subclass, AUSampler
    /// through `AUAudioUnitV2Bridge`, DecentSampler, and the raw v2 layer
    /// across uninitialize/initialize), so the registry's single set already
    /// holds at the second allocate.
    ///
    /// What it therefore pins is the INVARIANT — "an offline render's AU is
    /// flagged at EVERY allocate, and a live one at none" — which is the thing
    /// that matters, by whichever mechanism holds it. Making it discriminate
    /// the line would require a stub that CLEARS the flag on deallocate, i.e.
    /// inventing a behaviour no measured component exhibits, and bending a
    /// fixture until it goes red proves nothing about the world.
    @Test("Leg R-1: an offline AU is still flagged at its SECOND allocate (rate renegotiation)")
    func rateRenegotiationReassertsTheOfflineFlag() async throws {
        for rendersOffline in [true, false] {
            let observations = OfflineFlagObservations(withheldQuanta: 0)
            let description = AudioComponentDescription(
                componentType: kAudioUnitType_MusicDevice,
                componentSubType: 0x646F_6666,       // 'doff' — stub-only identity
                componentManufacturer: 0x4441_5750,  // 'DAWP'
                componentFlags: 0, componentFlagsMask: 0)
            let au = try OfflineFlagStubInstrumentAU(componentDescription: description,
                                                     observations: observations)
            au.maximumFramesToRender = 512
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000,
                                                    channels: 2))
            try au.outputBusses[0].setFormat(format)
            AUHostRegistry.applyOfflineRenderFlag(to: au, rendersOffline: rendersOffline)
            try au.allocateRenderResources()
            let instrument = try HostedAUInstrument(au: au, sampleRate: 48_000,
                                                    rendersOffline: rendersOffline)
            try #require(observations.allocateCalls == 1)

            // A DIFFERENT rate is what opens the renegotiation branch.
            instrument.prepare(sampleRate: 44_100, maxFramesPerQuantum: 512, channelCount: 2)
            print("[measured] Leg R-1 renegotiation rendersOffline=\(rendersOffline): "
                  + "allocateCalls \(observations.allocateCalls), "
                  + "flagAtAllocate(2nd) \(observations.flagAtAllocate)")
            #expect(observations.allocateCalls == 2, """
                the renegotiation branch did not reallocate, so this test asserts nothing about \
                the second allocate site.
                """)
            #expect(observations.flagAtAllocate == rendersOffline)
        }
    }
}
