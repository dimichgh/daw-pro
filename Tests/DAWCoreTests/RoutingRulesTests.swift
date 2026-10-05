import Foundation
import Testing
@testable import DAWCore

// m39-tpl-2 — `RoutingRules` (Sources/DAWCore/RoutingRules.swift), THE ONE HOME
// for the output and send rules: `track.setOutput` / `track.addSend` (the store's
// `setTrackOutput` / `addSend`) and the template builder all call it.
//
// One TABLE, two paths judged against it — never against each other (with one
// home, comparing the store with the rule would compare a thing with itself):
//   - `RoutingRulesTests` calls the rule directly;
//   - `BusRoutingStoreTests.tpl2StoreRefusesEveryRoutingCase` calls the store
//     verbs the wire calls, and checks the refusal's case, its EXACT sentence
//     (the wording the wire surfaces verbatim, written out here as literals),
//     that a refusal changes nothing, and that an allowed call applies.

/// The table: a fixed set of tracks and every call shape.
enum TPL2Routing {
    static let audio = TPL2SequentialIDs.id(101)
    static let instrument = TPL2SequentialIDs.id(102)
    static let bus1 = TPL2SequentialIDs.id(103)
    static let bus2 = TPL2SequentialIDs.id(104)
    static let missing = TPL2SequentialIDs.id(199)

    /// Audio "A" already sends to "B1".
    static func tracks() -> [Track] {
        [
            Track(id: audio, name: "A", kind: .audio,
                  sends: [Send(id: TPL2SequentialIDs.id(150), destinationBusID: bus1, level: 0.5)]),
            Track(id: instrument, name: "I", kind: .instrument),
            Track(id: bus1, name: "B1", kind: .bus),
            Track(id: bus2, name: "B2", kind: .bus),
        ]
    }

    enum Call: Sendable {
        case output(UUID, UUID?)
        case send(UUID, UUID)
    }

    // The refusal sentences, as LITERALS: `ProjectError`'s wording is wire
    // contract ("Exact wording is contract" in MediaImporting.swift), so a
    // re-point that changed a byte of it must fail here.
    static let busFixed = "bus tracks always output to master in v0 — cannot set output or sends on a bus"
    static func notABus(_ id: UUID) -> String {
        "track \(id.uuidString) is not a bus — output and send destinations must be bus tracks"
    }
    static func duplicate(_ id: UUID) -> String {
        "track already has a send to bus \(id.uuidString) — use track.setSend to change its level"
    }
    static func notFound(_ id: UUID) -> String { "No track with id \(id.uuidString)." }

    /// (label, call, the refusal case or "OK", its exact sentence or nil).
    static let cases: [(String, Call, String, String?)] = [
        ("output audio → bus", .output(audio, bus1), "OK", nil),
        ("output audio → master", .output(audio, nil), "OK", nil),
        ("output instrument → bus", .output(instrument, bus2), "OK", nil),
        ("output audio → instrument", .output(audio, instrument), "notABus", notABus(instrument)),
        ("output audio → missing", .output(audio, missing), "trackNotFound", notFound(missing)),
        ("output missing → bus", .output(missing, bus1), "trackNotFound", notFound(missing)),
        ("output bus → bus", .output(bus1, bus2), "busRoutingFixed", busFixed),
        ("output bus → master (the bus check comes first)", .output(bus1, nil), "busRoutingFixed",
         busFixed),
        ("output missing → missing (the source check comes first)", .output(missing, missing),
         "trackNotFound", notFound(missing)),
        ("send audio → new bus", .send(audio, bus2), "OK", nil),
        ("send instrument → bus", .send(instrument, bus1), "OK", nil),
        ("send audio → the bus it already sends to", .send(audio, bus1), "duplicateSend",
         duplicate(bus1)),
        ("send audio → instrument", .send(audio, instrument), "notABus", notABus(instrument)),
        ("send audio → missing", .send(audio, missing), "trackNotFound", notFound(missing)),
        ("send missing → bus", .send(missing, bus1), "trackNotFound", notFound(missing)),
        ("send bus → bus", .send(bus1, bus2), "busRoutingFixed", busFixed),
        ("send bus → missing (the bus check comes before the destination)", .send(bus1, missing),
         "busRoutingFixed", busFixed),
        ("send audio → itself (not a bus)", .send(audio, audio), "notABus", notABus(audio)),
    ]

    /// "OK", or "<case>|<sentence>" for a refusal.
    static func describe(_ body: () throws -> Void) -> String {
        do {
            try body()
            return "OK"
        } catch {
            let name = String(describing: error).prefix { $0 != "(" }
            return "\(name)|\(error.localizedDescription)"
        }
    }

    static func expected(_ refusal: String, _ sentence: String?) -> String {
        sentence.map { "\(refusal)|\($0)" } ?? refusal
    }

    static func viaRule(_ call: Call) -> String {
        let tracks = tracks()
        switch call {
        case .output(let track, let bus):
            return describe { try RoutingRules.checkOutput(of: track, to: bus, in: tracks) }
        case .send(let track, let bus):
            return describe { try RoutingRules.checkSend(from: track, to: bus, in: tracks) }
        }
    }
}

@Suite("m39-tpl-2: RoutingRules")
struct RoutingRulesTests {
    @Test("the output and send rules refuse in the store's order, with the wire's exact sentences")
    func outputAndSendRulesInTheStoresOrder() {
        for (label, call, refusal, sentence) in TPL2Routing.cases {
            let outcome = TPL2Routing.viaRule(call)
            let expected = TPL2Routing.expected(refusal, sentence)
            #expect(outcome == expected, "\(label): \(outcome), expected \(expected)")
        }
    }
}

// ⚠️ An EXTENSION of the existing `@MainActor` suite `BusRoutingStoreTests`, not a
// new suite: the `MainActorOccupancySiteTests` cap on `@MainActor` suites.
extension BusRoutingStoreTests {
    @Test("m39-tpl-2: the store verbs the wire calls refuse every routing case exactly; a refusal changes nothing, an allowed call applies")
    func tpl2StoreRefusesEveryRoutingCase() {
        var wrong: [String] = []
        for (label, call, refusal, sentence) in TPL2Routing.cases {
            let store = ProjectStore(tracks: TPL2Routing.tracks())
            let before = store.tracks
            let depth = store.journal.undoStack.count
            let outcome: String
            switch call {
            case .output(let track, let bus):
                outcome = TPL2Routing.describe { try store.setTrackOutput(id: track, busID: bus) }
                if outcome == "OK", store.tracks.first(where: { $0.id == track })?.outputBusID != bus {
                    wrong.append("\(label): answered OK but the output did not change")
                }
            case .send(let track, let bus):
                outcome = TPL2Routing.describe { _ = try store.addSend(toTrack: track, busID: bus) }
                if outcome == "OK",
                   store.tracks.first(where: { $0.id == track })?.sends.last?.destinationBusID != bus {
                    wrong.append("\(label): answered OK but no send was added")
                }
            }
            let expected = TPL2Routing.expected(refusal, sentence)
            if outcome != expected { wrong.append("\(label): store \(outcome), expected \(expected)") }
            if outcome == "OK" {
                // One undo step when the song changed; none for a no-op (an
                // audio track already on the master, sent to the master again).
                let steps = store.tracks == before ? 0 : 1
                if store.journal.undoStack.count != depth + steps {
                    wrong.append("\(label): applied with \(store.journal.undoStack.count - depth) "
                        + "undo steps, expected \(steps)")
                }
            } else if store.tracks != before || store.journal.undoStack.count != depth {
                wrong.append("\(label): a refusal changed the song or the undo history")
            }
        }
        // A Bool, not the array: a failing `#expect` prints what it captured.
        let exact = wrong.isEmpty
        #expect(exact, "\(wrong.count) wrong: \(wrong)")
        // Control: the table is not vacuous — it holds allowed calls and every refusal case.
        let refusals = Set(TPL2Routing.cases.map { $0.2 })
        #expect(refusals == ["OK", "notABus", "trackNotFound", "busRoutingFixed", "duplicateSend"])
    }
}
