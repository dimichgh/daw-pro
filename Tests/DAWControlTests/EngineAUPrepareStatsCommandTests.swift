import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m23-br-1 `engine.auPrepareStats`: the
/// read-only AU-registry prepare ledger. The counting RULES (count at the
/// idempotency guard, real removals only, digest stability) are pinned in
/// DAWEngine's `AUPrepareStatsTests`; here we pin the wire shape, the
/// headless all-zero contract, the omission of absent optional fields, and
/// the no-params guard's ORDERING against the engine read.
@MainActor
@Suite("AU prepare stats — control protocol (m23-br-1)")
struct EngineAUPrepareStatsCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    @Test("allCommands advertises engine.auPrepareStats")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("engine.auPrepareStats"))
    }

    /// Headless must be an honest zero rather than a refusal: a gate reads
    /// this verb as a BASELINE before doing anything, and an engineUnavailable
    /// there would force every caller to special-case its own first read.
    @Test("headless: the wire shape is all-zero counters and empty arrays, never a refusal")
    func headlessZeroShape() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "engine.auPrepareStats"))
        #expect(response.ok)
        #expect(response.result?["instrumentPrepares"]?.doubleValue == 0)
        #expect(response.result?["instrumentReleases"]?.doubleValue == 0)
        #expect(response.result?["effectPrepares"]?.doubleValue == 0)
        #expect(response.result?["effectReleases"]?.doubleValue == 0)
        #expect(response.result?["tracks"]?.arrayValue?.isEmpty == true)
        #expect(response.result?["effects"]?.arrayValue?.isEmpty == true)
    }

    @Test("an engine's prepare ledger threads through the store onto the wire, entries and all")
    func statsThreadThrough() async throws {
        let (router, store) = makeRouter()
        let engine = FakeAUPrepareStatsEngine()
        let trackID = UUID()
        let effectID = UUID()
        engine.stats = EngineAUPrepareStats(
            instrumentPrepares: 7, instrumentReleases: 3,
            effectPrepares: 2, effectReleases: 1,
            tracks: [.init(trackId: trackID.uuidString,
                           keyDigest: "0123456789abcdef", status: "ready")],
            effects: [.init(effectId: effectID.uuidString,
                            keyDigest: "fedcba9876543210", status: "failed: boom")])
        store.engine = engine

        let response = await router.handle(ControlRequest(
            id: "1", command: "engine.auPrepareStats"))
        #expect(response.ok)
        #expect(response.result?["instrumentPrepares"]?.doubleValue == 7)
        #expect(response.result?["instrumentReleases"]?.doubleValue == 3)
        #expect(response.result?["effectPrepares"]?.doubleValue == 2)
        #expect(response.result?["effectReleases"]?.doubleValue == 1)

        let track = try #require(response.result?["tracks"]?.arrayValue?.first)
        #expect(track["trackId"]?.stringValue == trackID.uuidString)
        #expect(track["keyDigest"]?.stringValue == "0123456789abcdef")
        #expect(track["status"]?.stringValue == "ready")

        let effect = try #require(response.result?["effects"]?.arrayValue?.first)
        #expect(effect["effectId"]?.stringValue == effectID.uuidString)
        #expect(effect["keyDigest"]?.stringValue == "fedcba9876543210")
        // The "failed: <reason>" spelling comes from
        // `AudioUnitTrackStatus.wireLabel`, shared with project.snapshot's
        // instrument objects — one spelling, one home.
        #expect(effect["status"]?.stringValue == "failed: boom")
        #expect(engine.reads == 1)
    }

    /// A slot the registry has no key/status for must not fabricate one.
    /// Asserting the ENCODER's actual behaviour (synthesized `Codable` uses
    /// `encodeIfPresent`, so nil fields are OMITTED rather than emitted as
    /// JSON null) rather than an assumption about it — a reader checking
    /// `keyDigest === undefined` needs this to be true, not believed.
    @Test("absent keyDigest/status are OMITTED from the JSON, not emitted as null")
    func absentOptionalFieldsAreOmitted() async throws {
        let (router, store) = makeRouter()
        let engine = FakeAUPrepareStatsEngine()
        let trackID = UUID()
        engine.stats = EngineAUPrepareStats(
            instrumentPrepares: 0, instrumentReleases: 0,
            effectPrepares: 0, effectReleases: 0,
            tracks: [.init(trackId: trackID.uuidString, keyDigest: nil, status: nil)],
            effects: [])
        store.engine = engine

        let response = await router.handle(ControlRequest(
            id: "1", command: "engine.auPrepareStats"))
        #expect(response.ok)
        let track = try #require(response.result?["tracks"]?.arrayValue?.first)
        #expect(track["trackId"]?.stringValue == trackID.uuidString)
        #expect(track["keyDigest"] == nil)
        #expect(track["status"] == nil)
        #expect(track.objectValue?.keys.sorted() == ["trackId"])

        // ANTI-BLINDNESS CONTROL. `JSONValue`'s subscript returns nil for an
        // ABSENT key and `.null` for a present JSON null, so the two
        // expectations above really do discriminate — this leg proves the
        // instrument can see the difference it is being used to rule out.
        let explicitNull = JSONValue.object(["keyDigest": .null])
        #expect(explicitNull["keyDigest"] == .null)
        #expect(explicitNull["absent"] == nil)
    }

    /// The ORDERING witness (the m23-n2h house requirement): the fake counts
    /// every real `auPrepareStats()` call, so `reads == 0` proves the unknown-key
    /// guard ran BEFORE the engine was touched — not merely that a
    /// `rejectUnknownKeys` call site exists somewhere in the case body.
    @Test("no params accepted; unknown extras are rejected before the engine is touched")
    func noParamsTolerance() async throws {
        let (router, store) = makeRouter()
        let engine = FakeAUPrepareStatsEngine()
        engine.stats = EngineAUPrepareStats(
            instrumentPrepares: 5, instrumentReleases: 0,
            effectPrepares: 0, effectReleases: 0, tracks: [], effects: [])
        store.engine = engine

        let sloppy = await router.handle(ControlRequest(
            id: "1", command: "engine.auPrepareStats", params: ["reset": .bool(true)]))
        #expect(!sloppy.ok)
        // `reset` specifically: engine.performanceStats HAS one, so an agent
        // pattern-matching across the two verbs will try it here. The refusal
        // has to teach that this ledger is monotone by design.
        #expect(sloppy.error == "engine.auPrepareStats: unknown parameter 'reset' — engine.auPrepareStats takes no parameters")
        #expect(engine.reads == 0, "the guard must run before auPrepareStats() is ever called")
    }

    /// Two reads of an unchanged ledger must be byte-identical — the whole
    /// point of the sorted arrays. A caller diffs them.
    @Test("repeated reads of an unchanged ledger are identical")
    func repeatedReadsAreIdentical() async throws {
        let (router, store) = makeRouter()
        let engine = FakeAUPrepareStatsEngine()
        engine.stats = EngineAUPrepareStats(
            instrumentPrepares: 1, instrumentReleases: 0,
            effectPrepares: 0, effectReleases: 0,
            tracks: [.init(trackId: UUID().uuidString, keyDigest: "aaaaaaaaaaaaaaaa",
                           status: "pending")],
            effects: [])
        store.engine = engine

        let first = await router.handle(ControlRequest(id: "1", command: "engine.auPrepareStats"))
        let second = await router.handle(ControlRequest(id: "2", command: "engine.auPrepareStats"))
        #expect(first.result == second.result)
        #expect(engine.reads == 2)
    }
}

/// Minimal engine fake: only the AU-prepare-stats surface matters; everything
/// else rides the protocol's optional-capability defaults (the perf-b /
/// watchdog fake shape).
@MainActor
private final class FakeAUPrepareStatsEngine: AudioEngineControlling {
    var stats: EngineAUPrepareStats = .idle
    private(set) var reads = 0

    func auPrepareStats() -> EngineAUPrepareStats {
        reads += 1
        return stats
    }

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
}
