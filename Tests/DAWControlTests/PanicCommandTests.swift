import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Wire-level gate for `transport.panic` (m23-af) through `CommandRouter.handle`.
///
/// The verb exists because there was NO way out of a stuck note — not for the
/// user (`ProjectStore.stop()` early-returns unless the transport is playing or
/// recording, so the Stop button cannot clear one) and not for an agent (no
/// `panic`/`allNotesOff` command existed at all). Every leg here pins one of the
/// two ways a "fix" for that could quietly stop fixing it: routing panic through
/// stop, or flushing the engine while the audition ledger still believes notes
/// are held.
@MainActor
@Suite("transport.panic wire command (m23-af)")
struct PanicCommandTests {
    /// Engine spy that records the ORDER of the two engine-facing calls a panic
    /// makes, and — the part that matters — lets a test observe the store's
    /// audition ledger AT THE MOMENT the flush lands.
    @MainActor
    private final class PanicSpyEngine: AudioEngineControlling {
        var isRunning = true
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?

        /// Every engine call a panic makes, in order.
        private(set) var calls: [String] = []
        private(set) var auditionCalls: [(trackID: UUID, pitches: [UInt8], velocity: UInt8)] = []
        /// What `allNotesOff()` reports back — the wire echoes this.
        var flushCountStub = 3
        /// Ran INSIDE `allNotesOff()`, so a test can assert what was already true
        /// when the flush happened rather than only what is true afterwards.
        var onAllNotesOff: (() -> Void)?

        func allNotesOff() -> Int {
            calls.append("allNotesOff")
            onAllNotesOff?()
            return flushCountStub
        }

        func stopAllAudition() {
            calls.append("stopAllAudition")
        }

        func setAuditionPitches(trackID: UUID, pitches: [UInt8],
                                velocity: UInt8) -> AuditionOutcome {
            auditionCalls.append((trackID, pitches, velocity))
            return .sounded
        }

        func prepare() throws { isRunning = true }
        func shutdown() { isRunning = false }
        func tracksDidChange(_ tracks: [Track]) {}
        func startPlayback(_ transport: TransportState) {}
        func stopPlayback() { calls.append("stopPlayback") }
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
        func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                       completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {}
        func stopRecording() { calls.append("stopRecording") }
    }

    private func makeRouter() -> (CommandRouter, ProjectStore, PanicSpyEngine, UUID) {
        let store = ProjectStore()
        let engine = PanicSpyEngine()
        store.engine = engine
        let instrument = store.addTrack(name: "Keys", kind: .instrument).id
        return (CommandRouter(store: store), store, engine, instrument)
    }

    private func panic(_ router: CommandRouter,
                       _ params: [String: JSONValue] = [:]) async -> ControlResponse {
        await router.handle(ControlRequest(id: "1", command: "transport.panic", params: params))
    }

    // MARK: - The bug itself

    /// T1 — THE REGRESSION THAT MATTERS. Panic must flush while the transport is
    /// STOPPED. This is the exact case `transport.stop` cannot serve: `stop()`
    /// guards on `isPlaying || isRecording`, so a stuck note on an idle transport
    /// was unreachable from the wire before m23-af.
    @Test("panics while STOPPED — the case Stop structurally cannot reach")
    func panicsWhileStopped() async {
        let (router, store, engine, _) = makeRouter()
        #expect(store.transport.isPlaying == false)
        #expect(store.transport.isRecording == false)

        let response = await panic(router)

        #expect(response.ok)
        #expect(engine.calls.contains("allNotesOff"))
        #expect(response.result?["tracksFlushed"]?.doubleValue == 3)
    }

    /// T2 — panic must NOT stop the transport. Pins the verb against a future
    /// "simplification" into `store.stop()`, which would re-introduce the guard
    /// T1 exists to route around AND lose the take.
    @Test("does NOT stop playback — safe to hit mid-take")
    func doesNotStopTransport() async {
        let (router, store, engine, _) = makeRouter()
        store.play()
        #expect(store.transport.isPlaying)

        let response = await panic(router)

        #expect(response.ok)
        #expect(store.transport.isPlaying, "panic must not stop the transport")
        #expect(engine.calls.contains("allNotesOff"))
        #expect(!engine.calls.contains("stopPlayback"), "panic routed through stop()")
        #expect(!engine.calls.contains("stopRecording"))
    }

    // MARK: - The ledger-ordering hazard

    /// T3 — the audition ledger must be CLEAR by the time the flush lands.
    ///
    /// `AuditionController` keeps its own view of what is sounding and runs a
    /// 500 ms heartbeat that RE-ASSERTS it (`Audition.swift:184`, so a held note
    /// survives the renderer's 3 s watchdog). Flush the engine while that ledger
    /// still believes pitches are down and the next heartbeat re-pushes them into
    /// a ring the panic just emptied — a panic that undoes itself half a second
    /// later, for auditioned notes only. Observing `isHolding` from INSIDE
    /// `allNotesOff()` is what makes this an ordering assertion rather than an
    /// after-the-fact one: asserting it only on return would pass even if the
    /// clear happened second.
    @Test("clears the audition ledger BEFORE flushing the engine")
    func clearsLedgerBeforeFlush() async throws {
        let (router, store, engine, instrument) = makeRouter()
        _ = try store.auditionPitches(trackID: instrument, pitches: [60, 64], velocity: 90)
        #expect(store.audition.isHolding, "precondition: something is held")

        var holdingAtFlush: Bool?
        engine.onAllNotesOff = { holdingAtFlush = store.audition.isHolding }

        let response = await panic(router)

        #expect(response.ok)
        #expect(holdingAtFlush == false, "ledger still held when the flush landed")
        #expect(store.audition.isHolding == false)
        #expect(engine.calls == ["stopAllAudition", "allNotesOff"])
    }

    /// T4 — idempotent. A user mashing the panic button, or an agent retrying,
    /// must not error or wedge.
    @Test("is idempotent — repeated panics all succeed")
    func isIdempotent() async {
        let (router, _, engine, _) = makeRouter()

        for _ in 0..<3 {
            #expect(await panic(router).ok)
        }
        #expect(engine.calls.filter { $0 == "allNotesOff" }.count == 3)
    }

    // MARK: - Wire hygiene

    /// T5 — no params, and an unknown key is a teaching error rather than a
    /// silent no-op (the house `rejectUnknownKeys` contract).
    @Test("rejects unknown params")
    func rejectsUnknownParams() async {
        let (router, _, engine, _) = makeRouter()

        let response = await panic(router, ["trackId": .string(UUID().uuidString)])

        #expect(!response.ok)
        #expect(engine.calls.isEmpty, "a rejected panic must flush nothing")
    }

    /// T6 — declared in `allCommands`, so the MCP/catalog parity check sees it.
    @Test("is declared in allCommands")
    func isDeclared() {
        #expect(CommandRouter.allCommands.contains("transport.panic"))
    }

    /// T7 — an engine-less store still answers. The protocol default reports 0
    /// renderers, which is honest: there was nothing to flush.
    @Test("headless store answers 0 rather than failing")
    func headlessAnswersZero() async {
        let store = ProjectStore()
        _ = store.addTrack(name: "Keys", kind: .instrument)
        let router = CommandRouter(store: store)

        let response = await router.handle(
            ControlRequest(id: "1", command: "transport.panic", params: [:]))

        #expect(response.ok)
        #expect(response.result?["tracksFlushed"]?.doubleValue == 0)
    }
}
