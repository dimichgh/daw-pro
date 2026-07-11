import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// The `seedForCapture` hook (M6 rail-d): the debug-tier `debug.copilotSeed`
/// command drives a scripted transcript straight into the engine — no provider
/// call — for deterministic rail captures / E2E. These pin what the seed lands
/// (transcript, status, currentTurnId) and that it round-trips through the same
/// `stateJSON` wire shape `debug.copilotState` echoes.
@MainActor
@Suite("Copilot seed hook (rail-d capture support)")
struct CopilotSeedTests {
    /// A key-less, provider-less engine — seeding never touches the turn loop.
    private func makeEngine() -> CopilotEngine {
        CopilotEngine(store: ProjectStore(), dispatch: { _ in .success("0") })
    }

    @Test("seeds a running conversation: transcript, status, currentTurnId")
    func seedsRunningConversation() {
        let engine = makeEngine()
        engine.seedForCapture(turnID: "seed-turn", status: .running, entries: [
            .user("set the tempo to 120"),
            .assistant("On it."),
            .toolCall(command: "transport.setTempo", argsSummary: #"{"bpm": 120}"#),
            .toolResult(command: "transport.setTempo", ok: true, summary: #"{"tempoBPM": 120}"#),
        ])
        #expect(engine.status == .running)
        #expect(engine.currentTurnID == "seed-turn")
        #expect(engine.transcript.count == 4)
        // Every entry carries the seeded turnId (so a turn-filtered state query
        // returns them all).
        #expect(engine.transcript.allSatisfy { $0.turnID == "seed-turn" })
        if case .user(let text) = engine.transcript[0].kind {
            #expect(text == "set the tempo to 120")
        } else {
            Issue.record("first entry should be a user message")
        }
    }

    @Test("an idle seed clears the current turn id")
    func idleSeedClearsTurn() {
        let engine = makeEngine()
        engine.seedForCapture(turnID: "unused", status: .idle, entries: [])
        #expect(engine.status == .idle)
        #expect(engine.currentTurnID == nil)
        #expect(engine.transcript.isEmpty)
    }

    @Test("a failed seed lands a failure entry with the message")
    func failedSeedLandsFailure() {
        let engine = makeEngine()
        engine.seedForCapture(turnID: "t", status: .failed, entries: [
            .user("add a track"),
            .failure("the AI provider returned an error: rate limit exceeded"),
        ])
        #expect(engine.status == .failed)
        guard case .failure(let message) = engine.transcript.last?.kind else {
            Issue.record("last entry should be a failure")
            return
        }
        #expect(message.contains("rate limit"))
    }

    @Test("seeded transcript round-trips through stateJSON (the debug.copilotState shape)")
    func seedRoundTripsThroughStateJSON() throws {
        let engine = makeEngine()
        engine.seedForCapture(turnID: "seed-turn", status: .running, entries: [
            .user("hi"),
            .toolCall(command: "track.add", argsSummary: #"{"name":"Bass"}"#),
            .toolResult(command: "track.add", ok: false, summary: "unknown kind"),
        ])
        let json = engine.stateJSON(turnID: nil)
        guard case .object(let obj) = json else {
            Issue.record("stateJSON should be an object"); return
        }
        #expect(obj["status"]?.stringValue == "running")
        #expect(obj["currentTurnId"]?.stringValue == "seed-turn")
        guard case .array(let entries)? = obj["transcript"] else {
            Issue.record("transcript should be an array"); return
        }
        #expect(entries.count == 3)
        // The error toolResult carries ok=false + its summary (the red-chip data).
        guard case .object(let result) = entries[2] else {
            Issue.record("third entry should be an object"); return
        }
        #expect(result["kind"]?.stringValue == "toolResult")
        #expect(result["command"]?.stringValue == "track.add")
        #expect(result["ok"]?.boolValue == false)
        #expect(result["summary"]?.stringValue == "unknown kind")
    }

    @Test("reset clears a seeded transcript back to idle")
    func resetClearsSeed() {
        let engine = makeEngine()
        engine.seedForCapture(turnID: "t", status: .running, entries: [.user("hi")])
        engine.reset()
        #expect(engine.status == .idle)
        #expect(engine.transcript.isEmpty)
        #expect(engine.currentTurnID == nil)
    }
}
