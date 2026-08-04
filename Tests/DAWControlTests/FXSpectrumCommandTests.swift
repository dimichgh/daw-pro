import AVFAudio
import Foundation
import Testing
import DAWCore
@testable import DAWControl
@testable import DAWEngine

/// Control-protocol gate for m23-r4 `fx.spectrum`
/// (design-m23r4-fx-spectrum-lease.md §8) — the twelve legs the design
/// specifies, each with the mutation named in the design's table. Modelled
/// on `LiveLoudnessCommandTests` (a fake `AudioEngineControlling`), but per
/// the design's explicit instruction the fake here hosts a REAL
/// `InsertSpectrumTap` + `MasterMixAnalyzer` (`@testable import DAWEngine`
/// — `DAWControlTests` already depends on `DAWEngine`, `Package.swift:129`):
/// arming allocates a real tap, the tests write real injected tones through
/// `tap.write(buffers:frameCount:)`, and `insertAnalysis` returns
/// `tap.drainAndSnapshot()`. What is faked is ONLY the graph topology (which
/// track/effect exist is `ProjectStore`'s own model, mutated for real
/// through `store.addTrack`/`store.addEffect`/`store.addMasterEffect`); the
/// band oracle stays `MasterMixAnalyzer.bandIndex(containing:)`, never a
/// hardcoded index.
///
/// L9 (the tapPoint/curveHelp label agreement) lives in
/// `InsertSpectrumCoverageTests` (extending the two existing r2b fader legs,
/// `DAWEngineTests`) and `EQCurveEditorModelTests`
/// (`DAWAppKitTests`) — `DAWControlTests` cannot reach `DAWAppKit`. L10
/// (mute honesty) is skipped per the design's §4.5 gate: the MCP
/// description does not claim mute behaviour, so the leg is not required.
@MainActor
@Suite("fx.spectrum — control protocol (m23-r4)", .serialized)
struct FXSpectrumCommandTests {

    // MARK: - The real-tap fake engine

    /// Hosts a REAL `InsertSpectrumTap` per armed target (never a stub bands
    /// array) behind a settable cap, so L3/L4b can drive the cap-refusal and
    /// cap-freed paths with a real tap-allocation cost. Model validation
    /// (`trackNotFound`/`effectNotFound`) never reaches this type — that
    /// happens entirely inside `ProjectStore.setInsertAnalysisArmed` against
    /// the store's own track/effect lists, which is exactly what `armCallCount`
    /// (L7) proves: an unresolved id must never increment it.
    @MainActor
    private final class FakeSpectrumEngine: AudioEngineControlling {
        let sampleRate: Double
        var cap: Int
        private(set) var taps: [InsertAnalysisTarget: InsertSpectrumTap] = [:]
        private(set) var armCallCount = 0

        init(sampleRate: Double = 48_000, cap: Int = 8) {
            self.sampleRate = sampleRate
            self.cap = cap
        }

        var maxArmedInsertAnalysis: Int { cap }

        @discardableResult
        func setInsertAnalysisArmed(trackID: UUID?, effectID: UUID, armed: Bool) -> Bool {
            armCallCount += 1
            let target = InsertAnalysisTarget(trackID: trackID, effectID: effectID)
            guard armed else {
                taps.removeValue(forKey: target)
                return true
            }
            if taps[target] != nil { return true }
            guard taps.count < cap else { return false }
            taps[target] = InsertSpectrumTap(sampleRate: sampleRate)
            return true
        }

        func insertAnalysis(trackID: UUID?, effectID: UUID) -> MasterAnalysisSnapshot? {
            taps[InsertAnalysisTarget(trackID: trackID, effectID: effectID)]?.drainAndSnapshot()
        }

        // ---- Rest of AudioEngineControlling — the FakeLiveLoudnessEngine
        // boilerplate precedent (LiveLoudnessCommandTests.swift); every
        // other requirement takes the protocol's own no-capability default.
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var isRunning = false
        func prepare() throws {}
        func shutdown() {}
        func tracksDidChange(_ tracks: [Track]) {}
        func startPlayback(_ transport: TransportState) {}
        func stopPlayback() {}
        func seek(_ transport: TransportState) {}
        func setTempo(_ transport: TransportState) {}
        func loopChanged(_ transport: TransportState) {}
        func masterVolumeChanged(_ volume: Double) {}
        func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor],
                           masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           to url: URL) async throws -> AudioFileInfo {
            throw ProjectError.engineUnavailable
        }
        var recordPermission: RecordPermission { .granted }
        func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
            completion(true)
        }
        func availableInputDevices() -> [AudioInputDevice] { [] }
        func setInputDevice(uid: String?) throws {}
        func startRecording(_ transport: TransportState, to url: URL,
                            completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
            throw ProjectError.engineUnavailable
        }
        func stopRecording() {}

        /// Test-only: writes real samples into an armed target's REAL tap,
        /// via a tiny (~15-line) scratch buffer list — `DAWEngineTests`'
        /// own `Scratch` helper lives in that test target and is not
        /// reachable from here (the design's noted scaffolding budget).
        func feed(_ target: InsertAnalysisTarget, hz: Double, quanta: Int, quantum: Int = 512) {
            guard let tap = taps[target] else { return }
            let frames = quanta * quantum
            let samples = (0..<frames).map { index in
                Float(0.5) * Float(sin(2 * .pi * hz * Double(index) / sampleRate))
            }
            let storage = UnsafeMutablePointer<Float>.allocate(capacity: quantum * 2)
            defer { storage.deallocate() }
            let list = AudioBufferList.allocate(maximumBuffers: 2)
            defer { free(list.unsafeMutablePointer) }
            for channel in 0..<2 {
                list[channel] = AudioBuffer(mNumberChannels: 1,
                                            mDataByteSize: UInt32(quantum * MemoryLayout<Float>.stride),
                                            mData: UnsafeMutableRawPointer(storage + channel * quantum))
            }
            samples.withUnsafeBufferPointer { input in
                var offset = 0
                while offset < frames {
                    for channel in 0..<2 {
                        (storage + channel * quantum).update(from: input.baseAddress! + offset,
                                                              count: quantum)
                    }
                    tap.write(buffers: list, frameCount: quantum)
                    offset += quantum
                }
            }
        }
    }

    // MARK: - Setup

    @discardableResult
    private func makeRouter(cap: Int = 8, sampleRate: Double = 48_000,
                            now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now })
        -> (router: CommandRouter, store: ProjectStore, engine: FakeSpectrumEngine) {
        let store = ProjectStore()
        store.media = FakeMedia()
        let engine = FakeSpectrumEngine(sampleRate: sampleRate, cap: cap)
        store.engine = engine
        let router = CommandRouter(store: store,
                                   insertSpectrumLeases: InsertSpectrumLeases(now: now))
        return (router, store, engine)
    }

    private func spectrumRequest(_ id: String, trackId: String, effectId: String,
                                 arm: Bool? = nil) -> ControlRequest {
        var params: [String: JSONValue] = [
            "trackId": .string(trackId), "effectId": .string(effectId),
        ]
        if let arm { params["arm"] = .bool(arm) }
        return ControlRequest(id: id, command: "fx.spectrum", params: params)
    }

    // MARK: - L1: arm -> feed a tone -> non-floor bands on the tone's band

    @Test("L1: arm -> feed >=200ms of a 1kHz tone -> non-floor bands, peak on the tone's band")
    func armedTapReadsTheInjectedTone() async throws {
        let (router, store, engine) = makeRouter()
        let track = store.addTrack(name: "T")
        let effect = try store.addEffect(toTrack: track.id, kind: .gain)
        let target = InsertAnalysisTarget(trackID: track.id, effectID: effect.id)

        let arm = await router.handle(spectrumRequest("1", trackId: track.id.uuidString,
                                                       effectId: effect.id.uuidString))
        #expect(arm.ok, "fx.spectrum arm failed: \(arm.error ?? "?")")
        #expect(arm.result?["armed"]?.boolValue == true)

        engine.feed(target, hz: 1_000, quanta: 40)   // 40*512 = 20_480 frames ≈ 427 ms @ 48k

        let read = await router.handle(spectrumRequest("2", trackId: track.id.uuidString,
                                                        effectId: effect.id.uuidString))
        #expect(read.ok)
        let bands = (read.result?["bands"]?.arrayValue ?? []).compactMap(\.doubleValue)
        #expect(bands.count == 24)
        let peak = try #require(bands.max())
        #expect(peak > Double(MasterAnalysisSnapshot.floorDB) + 20,
                "the drained bands sat on the floor — nothing reached the analyzer")
        #expect(bands.firstIndex(of: peak) == MasterMixAnalyzer.bandIndex(containing: 1_000),
                "the tapped peak is not on the injected tone's band")
    }

    // MARK: - L2: a silent armed tap reads exactly the floor

    @Test("L2: a silent (no frames written) armed tap reads EXACTLY the floor, armed:true")
    func silentArmedTapReadsTheFloor() async throws {
        // `store.engine` is WEAK (the LiveLoudnessCommandTests precedent) —
        // the fake MUST stay bound here, not `_`, or ARC drops it the
        // instant `makeRouter` returns and every call below reads headless.
        let (router, store, engine) = makeRouter()
        let track = store.addTrack(name: "T")
        let effect = try store.addEffect(toTrack: track.id, kind: .gain)

        let response = await router.handle(spectrumRequest("1", trackId: track.id.uuidString,
                                                            effectId: effect.id.uuidString))
        #expect(response.ok, "fx.spectrum failed: \(response.error ?? "?")")
        #expect(response.result?["armed"]?.boolValue == true)
        let bands = (response.result?["bands"]?.arrayValue ?? []).compactMap(\.doubleValue)
        #expect(bands.count == 24)
        #expect(engine.taps.count == 1)
        #expect(bands.allSatisfy { $0 == Double(MasterAnalysisSnapshot.floorDB) },
                "a silent armed tap must read EXACTLY the floor, never a fabricated reading")
    }

    // MARK: - L3: the 9th arm is refused, naming the cap

    @Test("L3: arm 8 real live inserts, then a 9th is refused naming the cap and the release verb")
    func ninthArmIsRefused() async throws {
        let (router, store, engine) = makeRouter(cap: 8)
        let track = store.addTrack(name: "T")
        var effects: [EffectDescriptor] = []
        for _ in 0..<9 {
            effects.append(try store.addEffect(toTrack: track.id, kind: .gain))
        }
        for effect in effects.prefix(8) {
            let response = await router.handle(spectrumRequest(
                "arm", trackId: track.id.uuidString, effectId: effect.id.uuidString))
            #expect(response.ok, "an in-cap arm was refused: \(response.error ?? "?")")
        }
        #expect(engine.taps.count == 8)

        let ninth = effects[8]
        let refusal = await router.handle(spectrumRequest(
            "9th", trackId: track.id.uuidString, effectId: ninth.id.uuidString))
        #expect(!refusal.ok)
        #expect(refusal.error?.contains("8") == true, "the refusal must name the cap")
        #expect(refusal.error?.contains("release") == true,
                "the refusal must teach how to free a slot")
        #expect(engine.taps.count == 8, "the refused arm must not have recorded a 9th tap")
        #expect(CommandRouter.allCommands.count == 171, "a cap-full refusal must not have touched allCommands")
    }

    // MARK: - L4a/L4b: lease expiry — reporting vs cap-slot, deliberately split
    //
    // The two legs are disjoint by LEVEL, not just by which effect they
    // assert on: L4a drives `InsertSpectrumLeases` directly (unit-level —
    // never touches `CommandRouter`/`Commands.swift` at all), L4b drives it
    // through the wire (`fx.spectrum`, cap-slot eviction). This was found
    // empirically, not assumed: an earlier wire-level L4a and this L4b both
    // only ever advanced the clock PAST the TTL, so "the deadline comparison
    // is deleted (sweep unconditionally expires everything)" and "the
    // deadline is correctly enforced" produced IDENTICAL observations at
    // both legs — the mutation reddened neither leg's dedicated assertion
    // (it reddened L1/L3 instead, incidentally, because those happen to
    // re-invoke `fx.spectrum` on an unexpired target). A leg that only ever
    // advances past the boundary cannot distinguish "expires on time" from
    // "expires unconditionally"; the fix is a WITHIN-TTL survival assertion
    // at each level, added below.

    @Test("L4a: InsertSpectrumLeases.sweep — the deadline comparison distinguishes an expired lease from an unexpired one (unit-level, never touches the wire)")
    func sweepDistinguishesExpiredFromUnexpired() {
        nonisolated(unsafe) var fakeNow = ContinuousClock.now
        let leases = InsertSpectrumLeases(now: { fakeNow })
        let stale = InsertAnalysisTarget(trackID: UUID(), effectID: UUID())
        let fresh = InsertAnalysisTarget(trackID: UUID(), effectID: UUID())

        leases.renew(stale)
        fakeNow = fakeNow + InsertSpectrumLeases.defaultTTL - .seconds(1)   // 2s of a 3s TTL
        leases.renew(fresh)                                                // fresh's clock starts NOW
        fakeNow = fakeNow + .seconds(2)                                    // stale: 3s old (expired); fresh: 2s old (alive)

        #expect(leases.isHeld(stale) == false, "a lease held past its TTL must read as not-held")
        #expect(leases.isHeld(fresh) == true, "a lease still within its TTL must read as held")

        var released: [InsertAnalysisTarget] = []
        let expired = leases.sweep { released.append($0) }

        #expect(expired == [stale], "sweep must report ONLY the expired target")
        #expect(released == [stale], "sweep must release ONLY the expired target — an unexpired lease reaped early is exactly the bug this leg exists to catch")
        #expect(leases.isHeld(fresh) == true, "sweeping must never touch a lease that has not yet expired")
    }

    @Test("L4b: fx.spectrum lease expiry, at the wire — survives within its TTL, frees the cap slot once past it")
    func leaseExpiryFreesACapSlotOnlyOncePastTTL() async throws {
        nonisolated(unsafe) var fakeNow = ContinuousClock.now
        let (router, store, engine) = makeRouter(cap: 1, now: { fakeNow })
        let track = store.addTrack(name: "T")
        let effectA = try store.addEffect(toTrack: track.id, kind: .gain)
        let effectB = try store.addEffect(toTrack: track.id, kind: .gain)
        let targetA = InsertAnalysisTarget(trackID: track.id, effectID: effectA.id)
        let targetB = InsertAnalysisTarget(trackID: track.id, effectID: effectB.id)

        let armA = await router.handle(spectrumRequest("1", trackId: track.id.uuidString,
                                                        effectId: effectA.id.uuidString))
        #expect(armA.ok)
        #expect(engine.taps.count == 1)
        let armCallsAfterArmA = engine.armCallCount

        // WITHIN the 3s TTL: a sweep on an unrelated target (cap-1, so a
        // direct re-arm of A is not available to prove non-eviction) must
        // never reap A. A mutation that deletes the deadline comparison
        // (sweep unconditionally expires everything) reddens HERE, before
        // the boundary is even reached.
        fakeNow = fakeNow + .seconds(1)
        let bogus = await router.handle(spectrumRequest(
            "sweep-trigger", trackId: UUID().uuidString, effectId: UUID().uuidString, arm: false))
        #expect(!bogus.ok, "the bogus target must fail its own validation, not silently arm")
        #expect(engine.taps.count == 1, "A's tap must survive a sweep triggered 1s into its 3s TTL")
        #expect(engine.taps[targetA] != nil)
        #expect(engine.armCallCount == armCallsAfterArmA,
                "A must not have been re-armed — surviving a sweep is not the same as re-arming")
        #expect(store.insertAnalysis(trackID: track.id, effectID: effectA.id) != nil,
                "A's model-level reading must still be live 1s into its 3s TTL")

        // PAST the TTL (measuring from the original arm, which is the only
        // renewal — the survival check above deliberately swept via a
        // BOGUS target, never re-polling A itself, so A's clock was never
        // touched after the initial arm): the cap slot frees.
        fakeNow = fakeNow + InsertSpectrumLeases.defaultTTL
        let armB = await router.handle(spectrumRequest("3", trackId: track.id.uuidString,
                                                        effectId: effectB.id.uuidString))
        #expect(armB.ok, "arming a NEW target after the cap-1 lease expired should succeed: \(armB.error ?? "?")")
        #expect(armB.result?["armed"]?.boolValue == true)
        #expect(engine.taps.count == 1, "the cap-1 engine should hold exactly the NEW target's tap")
        #expect(engine.taps[targetA] == nil)
        #expect(engine.taps[targetB] != nil)
    }

    // MARK: - L5a/L5b: the symmetric stomp — wire<->UI ownership must never cross

    @Test("L5a: stomp wire -> UI — .ui arms, .control arms the SAME target, the lease expires, .ui's read survives")
    func stompWireIntoUI() async throws {
        nonisolated(unsafe) var fakeNow = ContinuousClock.now
        let (router, store, engine) = makeRouter(now: { fakeNow })
        let track = store.addTrack(name: "T")
        let effect = try store.addEffect(toTrack: track.id, kind: .gain)
        let target = InsertAnalysisTarget(trackID: track.id, effectID: effect.id)

        #expect(store.setInsertAnalysisArmed(trackID: track.id, effectID: effect.id,
                                             armed: true, owner: .ui) == .armed)
        let wireArm = await router.handle(spectrumRequest("1", trackId: track.id.uuidString,
                                                           effectId: effect.id.uuidString))
        #expect(wireArm.ok)

        fakeNow = fakeNow + InsertSpectrumLeases.defaultTTL + .seconds(1)
        // ANY fx.spectrum call sweeps first (even a bogus one that then
        // fails its own validation) — deliberately not touching the target
        // under test directly, so the release is attributable to the sweep.
        _ = await router.handle(spectrumRequest("sweep-trigger",
                                                trackId: UUID().uuidString,
                                                effectId: UUID().uuidString, arm: false))

        #expect(store.insertAnalysis(trackID: track.id, effectID: effect.id) != nil,
                "the UI's own arm must survive the wire lease's expiry")
        #expect(engine.taps[target] != nil)
    }

    @Test("L5b: stomp UI -> wire — .control arms via the wire, .ui arms then releases, .control's read survives")
    func stompUIIntoWire() async throws {
        let (router, store, engine) = makeRouter()
        let track = store.addTrack(name: "T")
        let effect = try store.addEffect(toTrack: track.id, kind: .gain)
        let target = InsertAnalysisTarget(trackID: track.id, effectID: effect.id)

        let wireArm = await router.handle(spectrumRequest("1", trackId: track.id.uuidString,
                                                           effectId: effect.id.uuidString))
        #expect(wireArm.ok)

        #expect(store.setInsertAnalysisArmed(trackID: track.id, effectID: effect.id,
                                             armed: true, owner: .ui) == .armed)
        #expect(store.setInsertAnalysisArmed(trackID: track.id, effectID: effect.id,
                                             armed: false, owner: .ui) == .released)

        #expect(store.insertAnalysis(trackID: track.id, effectID: effect.id) != nil,
                "the wire's control lease must survive the UI arming then releasing the SAME target")
        #expect(engine.taps[target] != nil)
    }

    // MARK: - L6: the TTL literal, pinned separately from every behavioural leg

    @Test("L6: the lease TTL is pinned against a literal (3s) — a mutation to it passes every clock-driven leg above")
    func ttlIsPinnedAgainstALiteral() {
        #expect(InsertSpectrumLeases.defaultTTL == .seconds(3))
    }

    // MARK: - L7: unknown ids refuse before ever reaching the engine's own arm

    @Test("L7: unknown trackId -> trackNotFound, unknown effectId -> effectNotFound, and the engine's own arm is never reached")
    func unknownIdsRefuseBeforeTouchingTheEngine() async throws {
        let (router, store, engine) = makeRouter()
        let track = store.addTrack(name: "T")
        let effect = try store.addEffect(toTrack: track.id, kind: .gain)

        let badTrack = await router.handle(spectrumRequest(
            "1", trackId: UUID().uuidString, effectId: effect.id.uuidString))
        #expect(!badTrack.ok)
        #expect(badTrack.error?.contains("No track with id") == true)

        let badEffect = await router.handle(spectrumRequest(
            "2", trackId: track.id.uuidString, effectId: UUID().uuidString))
        #expect(!badEffect.ok)
        #expect(badEffect.error?.contains("no effect with id") == true)

        #expect(engine.armCallCount == 0,
                "the engine's own arm must never be reached for an unresolved track/effect")
        #expect(engine.taps.isEmpty)
    }

    // MARK: - L8: an unknown param key is rejected, naming the key and the verb

    @Test("L8: an unknown param key is rejected, naming the key and the verb")
    func unknownParamKeyRejected() async throws {
        let (router, store, _) = makeRouter()
        let track = store.addTrack(name: "T")
        let effect = try store.addEffect(toTrack: track.id, kind: .gain)
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.spectrum",
            params: ["trackId": .string(track.id.uuidString),
                     "effectId": .string(effect.id.uuidString),
                     "bogus": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'bogus'") == true)
        #expect(response.error?.contains("fx.spectrum") == true)
    }

    // MARK: - L11: wire registration (additive-at-end law)

    @Test("L11: fx.spectrum is registered at the END of allCommands (additive-at-end law); count 161 -> 162 -> 163 -> 165 -> 166 -> 171 (m23-o1 appended frequency.reference, then m23-w appended clip.removeMany/clip.moveMany, m23-af appended transport.panic, then m23-aj-2 appended clip.moveManyByTracks/clip.moveManyToTrack, all after it)")
    func registeredAtEndOfAllCommands() {
        // fx.spectrum was the tail at m23-r4; m23-o1's frequency.reference,
        // m23-w's clip.removeMany/clip.moveMany, m23-af's transport.panic and
        // m23-aj-2's clip.moveManyByTracks/clip.moveManyToTrack are each
        // additive-at-end AFTER it, so fx.spectrum is now sixth-from-last —
        // still contiguous, still unmoved, per the same law it was gated by.
        #expect(CommandRouter.allCommands.dropLast(6).last == "fx.spectrum")
        #expect(CommandRouter.allCommands.dropLast(5).last == "frequency.reference")
        #expect(CommandRouter.allCommands.dropLast(4).last == "clip.removeMany")
        #expect(CommandRouter.allCommands.dropLast(3).last == "clip.moveMany")
        // m23-af appended `transport.panic` after the m23-w pair.
        #expect(CommandRouter.allCommands.dropLast(2).last == "transport.panic")
        // m23-aj-2 appended clip.moveManyByTracks/clip.moveManyToTrack after that.
        #expect(CommandRouter.allCommands.dropLast().last == "clip.moveManyByTracks")
        #expect(CommandRouter.allCommands.last == "clip.moveManyToTrack")
        #expect(CommandRouter.allCommands.count == 171)   // 166 at m23-af -> 168 at m20-j -> 169 at m23-br-1 -> 171 at m23-aj-2
    }

    // MARK: - L12: headless / no-capability both refuse honestly, never with a cap number

    @Test("L12: headless (no engine) and a present-but-incapable (cap 0) engine both refuse with engineUnavailable — never a cap number")
    func headlessAndIncapableEngineRefuse() async throws {
        let headlessStore = ProjectStore()
        headlessStore.media = FakeMedia()
        let headlessTrack = headlessStore.addTrack(name: "T")
        let headlessEffect = try headlessStore.addEffect(toTrack: headlessTrack.id, kind: .gain)
        let headlessRouter = CommandRouter(store: headlessStore)
        let headlessResponse = await headlessRouter.handle(spectrumRequest(
            "1", trackId: headlessTrack.id.uuidString, effectId: headlessEffect.id.uuidString))
        #expect(!headlessResponse.ok)
        #expect(headlessResponse.error == "audio engine not available")

        // `store.engine` is weak — keep the fake bound, see the L2 note
        // above. Discarding it here would deallocate the cap-0 fake
        // immediately, and the request would then hit `.unavailableHeadless`
        // (nil engine) instead of `.unsupported` (cap 0) — a DIFFERENT
        // code path that happens to produce the same wire message, which
        // would make this half of the leg pass for the wrong reason and
        // never actually exercise the `maxArmedInsertAnalysis > 0` guard.
        let (router, store, engine) = makeRouter(cap: 0)
        let track = store.addTrack(name: "T")
        let effect = try store.addEffect(toTrack: track.id, kind: .gain)
        let response = await router.handle(spectrumRequest(
            "2", trackId: track.id.uuidString, effectId: effect.id.uuidString))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
        #expect(response.error?.contains("0") != true, "a cap-0 engine must never say 'at most 0'")
        #expect(engine.armCallCount == 0,
                "a cap-0 engine's own arm must never be reached — .unsupported is a ProjectStore-level refusal")
    }

    // MARK: - Response shape (not its own numbered leg — supporting coverage)

    @Test("happy path: arm returns the mixer.masterAnalysis-shaped snapshot plus tapPoint + leaseSeconds; master differs from strip")
    func responseShapeCarriesTapPointAndLeaseSeconds() async throws {
        // `store.engine` is weak — keep the fake bound, see the L2 note above.
        let (router, store, engine) = makeRouter()
        _ = engine
        let track = store.addTrack(name: "T")
        let effect = try store.addEffect(toTrack: track.id, kind: .gain)

        let strip = await router.handle(spectrumRequest("1", trackId: track.id.uuidString,
                                                         effectId: effect.id.uuidString))
        #expect(strip.ok)
        #expect(strip.result?["tapPoint"]?.stringValue == "postInsertPreFader")
        #expect(strip.result?["leaseSeconds"]?.doubleValue == 3)
        #expect(strip.result?["bands"]?.arrayValue?.count == 24)
        #expect(strip.result?["levelDB"] != nil)
        #expect(strip.result?["peakDB"] != nil)

        let masterEffect = try store.addMasterEffect(kind: .gain)
        let master = await router.handle(spectrumRequest("2", trackId: "master",
                                                          effectId: masterEffect.id.uuidString))
        #expect(master.ok)
        #expect(master.result?["tapPoint"]?.stringValue == "postInsertPostFader")
    }

    @Test("arm:false on a target that was never armed is a benign success — armed:false, no analysis fields")
    func releaseOfNeverArmedTargetIsBenign() async throws {
        // `store.engine` is weak — keep the fake bound, see the L2 note above.
        let (router, store, engine) = makeRouter()
        _ = engine
        let track = store.addTrack(name: "T")
        let effect = try store.addEffect(toTrack: track.id, kind: .gain)
        let response = await router.handle(spectrumRequest(
            "1", trackId: track.id.uuidString, effectId: effect.id.uuidString, arm: false))
        #expect(response.ok)
        #expect(response.result?["armed"]?.boolValue == false)
        #expect(response.result?["bands"] == nil)
        #expect(response.result?["tapPoint"] != nil)
        #expect(response.result?["leaseSeconds"]?.doubleValue == 3)
    }
}
