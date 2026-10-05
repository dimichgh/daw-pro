import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Wire-level gate for `chord.voice` (m23-cv).
///
/// ⛔⛔ **THIS VERB IS THE SMALL HALF OF THE FEATURE AND THE SUITE SAYS SO.** The
/// deliverable of m23-cv is the on-screen, one-key chord button — the user ruled
/// explicitly against "an agent can already do it over the wire" as a substitute
/// for a manual surface in this exact cluster (`docs/ROADMAP.md:1049`). So the
/// first assertion here is not that the verb works: it is that the verb is
/// **PURE** — that it mutates nothing, sounds nothing, and reaches no engine.
/// That is what keeps it from growing into a second, competing feature.
@MainActor
@Suite("chord.voice wire command (m23-cv)")
struct ChordVoiceCommandTests {

    // ⚠️ **NO ENGINE SPY, AND THAT IS THE STRONGER PROOF, NOT THE LAZIER ONE.**
    // An engine-call counter can only ever say "this code path did not call the
    // engine on this input". With no engine attached at all, a verb that tried to
    // sound anything would have nowhere to send it — and the store-side ledgers
    // asserted below (`livePlay.heldPitches`, `audition.heldPitches`) are the
    // ones `note.play` actually moves, which `soundingIsMeasurable` proves with a
    // positive control before any of them is read as evidence of silence.

    private func makeRouter() -> (CommandRouter, ProjectStore, UUID) {
        let store = ProjectStore()
        let instrument = store.addTrack(name: "Keys", kind: .instrument).id
        return (CommandRouter(store: store), store, instrument)
    }

    private func voice(_ router: CommandRouter, _ params: [String: JSONValue]) async
        -> ControlResponse {
        await router.handle(ControlRequest(id: "1", command: "chord.voice", params: params))
    }

    private func chords(_ response: ControlResponse) -> [JSONValue] {
        guard case .object(let payload)? = response.result,
              case .array(let list)? = payload["chords"] else { return [] }
        return list
    }

    private func pitches(_ chord: JSONValue) -> [Int] {
        guard case .object(let payload) = chord,
              case .array(let list)? = payload["pitches"] else { return [] }
        return list.compactMap { $0.doubleValue.map(Int.init) }
    }

    // MARK: - Registration

    @Test("chord.voice is registered next to note.play and NOT at the tail")
    func verbIsRegistered() {
        #expect(CommandRouter.allCommands.contains("chord.voice"))
        // ⚠️ THE NEIGHBOURHOOD IS PINNED IN BOTH DIRECTIONS. `note.play` is
        // itself pinned to `pad.previewEffort + 1` by `LivePlayCommandTests`, so
        // this verb had to go AFTER it rather than before — and a tail append
        // reddened 19 end-relative assertions across 7 files at m23-ct. Both
        // constraints are recorded here so a later tidy-up is caught in this file
        // rather than in eight unrelated ones.
        let index = CommandRouter.allCommands.firstIndex(of: "chord.voice")
        let sibling = CommandRouter.allCommands.firstIndex(of: "note.play")
        #expect(index != nil && sibling != nil)
        #expect(index == sibling.map { $0 + 1 })
        #expect(index != CommandRouter.allCommands.count - 1, "must NOT be at the tail")
    }

    // MARK: - Purity — the load-bearing property

    /// ⭐⭐ **THE ASSERTION THAT KEEPS THIS VERB SMALL.** It is read-only by
    /// construction, and this measures it: no track appears, no clip appears, and
    /// neither sounding ledger moves.
    ///
    /// ⚠️ **THE SILENCE ASSERTIONS BELOW ARE ONLY EVIDENCE BECAUSE
    /// `soundingIsMeasurable` SHOWS THE SAME LEDGERS CAN MOVE.** An empty
    /// `livePlay.heldPitches` proves nothing on its own — a field nothing ever
    /// writes reads exactly the same as a field this verb correctly left alone.
    @Test("chord.voice sounds nothing, edits nothing, and touches no track")
    func isPure() async {
        let (router, store, _) = makeRouter()
        let clipsBefore = store.tracks.map(\.clips.count)
        let tracksBefore = store.tracks.count
        let response = await voice(router, [
            "key": .string("C"),
            "degrees": .array([.number(1), .number(5), .number(6), .number(4)]),
        ])
        #expect(response.error == nil)
        #expect(!chords(response).isEmpty)
        #expect(store.tracks.count == tracksBefore)
        #expect(store.tracks.map(\.clips.count) == clipsBefore)
        #expect(store.audition.heldPitches.isEmpty)
        #expect(store.livePlay.heldPitches.isEmpty)
    }

    /// ⭐ **THE POSITIVE CONTROL FOR `isPure`.** `note.play` on the same router and
    /// the same store DOES move `livePlay.heldPitches`, which is what makes that
    /// field's emptiness after `chord.voice` a measurement rather than a fact
    /// about a field nobody writes.
    @Test("positive control — the ledger chord.voice leaves empty is one note.play fills")
    func soundingIsMeasurable() async {
        let (router, store, instrument) = makeRouter()
        _ = await router.handle(ControlRequest(id: "1", command: "note.play", params: [
            "trackId": .string(instrument.uuidString),
            "pitches": .array([.number(60), .number(64), .number(67)]),
        ]))
        #expect(!store.livePlay.heldPitches.isEmpty,
                "the control did not fire — this suite cannot tell silence from a dead field")
        _ = await voice(router, ["degrees": .array([.number(1)])])
        // And chord.voice does not disturb what is already held, either.
        #expect(store.livePlay.heldPitches.count == 3)
    }

    @Test("chord.voice needs no track and no project state at all")
    func needsNoTrack() async {
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let response = await voice(router, ["degrees": .array([.number(1)])])
        #expect(response.error == nil)
        #expect(pitches(chords(response)[0]) == [48, 60, 64, 67])
    }

    // MARK: - The computation

    /// The four chords of pop in C, voiced for piano. Stated as pitch numbers
    /// because nobody on this side of the screen can hear anything: what is
    /// claimed is the arithmetic — a separated bass note, a close triad, and
    /// small motion between consecutive chords — never that it sounds good.
    @Test("degrees are voiced with real voice leading, chord to chord")
    func degreesAreVoiceLed() async {
        let (router, _, _) = makeRouter()
        let response = await voice(router, [
            "key": .string("C"),
            "degrees": .array([.number(1), .number(5), .number(6), .number(4)]),
        ])
        let list = chords(response)
        #expect(list.count == 4)
        #expect(pitches(list[0]) == [48, 60, 64, 67])          // C3 + C4 E4 G4
        // Each body moves a short distance from the one before it. The measured
        // cost is asserted against the same engine the app uses, so this cannot
        // drift away from what the button does.
        for index in 1..<list.count {
            let previous = Array(pitches(list[index - 1]).dropFirst())
            let current = Array(pitches(list[index]).dropFirst())
            let cost = ChordVoicing.voiceLeadingCost(current, previous)
            #expect(cost <= 6, "chord \(index) moved \(cost) semitones to \(current)")
        }
    }

    @Test("the reply names the chords and the numerals a human can read")
    func replyIsReadable() async {
        let (router, _, _) = makeRouter()
        let response = await voice(router, [
            "key": .string("C"),
            "degrees": .array([.number(1), .number(5), .number(6), .number(4)]),
        ])
        let names = chords(response).compactMap { value -> String? in
            guard case .object(let payload) = value else { return nil }
            return payload["symbol"]?.stringValue
        }
        #expect(names == ["C", "G", "Am", "F"])
        let numerals = chords(response).compactMap { value -> String? in
            guard case .object(let payload) = value else { return nil }
            return payload["numeral"]?.stringValue
        }
        #expect(numerals == ["I", "V", "vi", "IV"])
        guard case .object(let payload)? = response.result else {
            Issue.record("no payload"); return
        }
        #expect(payload["key"]?.stringValue == "C")
        #expect(payload["mode"]?.stringValue == "major")
        #expect(payload["preset"]?.stringValue == "piano")
        // Note names beside the numbers, from the repo's ONE naming home.
        guard case .object(let first) = chords(response)[0],
              case .array(let noteNames)? = first["noteNames"] else {
            Issue.record("no noteNames"); return
        }
        #expect(noteNames.compactMap { $0.stringValue } == ["C3", "C4", "E4", "G4"])
    }

    @Test("explicit chord symbols work, including sharps, flats and sevenths")
    func explicitSymbols() async {
        let (router, _, _) = makeRouter()
        let response = await voice(router, [
            "chords": .array([.string("Am7"), .string("F#m"), .string("Bb"),
                              .string("G7"), .string("Csus4"), .string("Bdim")]),
        ])
        let names = chords(response).compactMap { value -> String? in
            guard case .object(let payload) = value else { return nil }
            return payload["symbol"]?.stringValue
        }
        // ⚠️ `Bb` comes back as `A#`. Flats are ACCEPTED on input and never
        // PRODUCED on output, because this repo has exactly one pitch-class-name
        // array and it is the sharp one. Pinned so the asymmetry is a recorded
        // decision rather than a surprise in a reply.
        #expect(names == ["Am7", "F#m", "A#", "G7", "Csus4", "Bdim"])
    }

    @Test("the minor mode gives the minor diatonic set")
    func minorMode() async {
        let (router, _, _) = makeRouter()
        let response = await voice(router, [
            "key": .string("A"), "mode": .string("minor"),
            "degrees": .array([.number(1), .number(6), .number(3), .number(7)]),
        ])
        let names = chords(response).compactMap { value -> String? in
            guard case .object(let payload) = value else { return nil }
            return payload["symbol"]?.stringValue
        }
        #expect(names == ["Am", "F", "C", "G"])
    }

    /// The user's own question, answered on the wire: a bass instrument plays the
    /// root and nothing else.
    @Test("the bass preset returns one note per chord — the root")
    func bassPresetIsRootOnly() async {
        let (router, _, _) = makeRouter()
        let response = await voice(router, [
            "key": .string("C"), "preset": .string("bass"),
            "degrees": .array([.number(1), .number(5), .number(6), .number(4)]),
        ])
        let list = chords(response)
        #expect(list.count == 4)
        #expect(list.allSatisfy { pitches($0).count == 1 })
        #expect(pitches(list[0])[0] % 12 == 0)   // C
        #expect(pitches(list[1])[0] % 12 == 7)   // G
        #expect(pitches(list[2])[0] % 12 == 9)   // A
        #expect(pitches(list[3])[0] % 12 == 5)   // F
    }

    @Test("previousVoicing leads the FIRST chord too, so a caller can continue a phrase")
    func previousVoicingIsHonoured() async {
        let (router, _, _) = makeRouter()
        let cold = await voice(router, [
            "key": .string("C"), "degrees": .array([.number(4)]),
        ])
        let warm = await voice(router, [
            "key": .string("C"), "degrees": .array([.number(4)]),
            "previousVoicing": .array([48, 60, 64, 67].map { .number(Double($0)) }),
        ])
        #expect(pitches(chords(cold)[0]) != pitches(chords(warm)[0]))
        #expect(Array(pitches(chords(warm)[0]).dropFirst()) == [60, 65, 69])
    }

    @Test("octaveShift moves the whole voicing")
    func octaveShift() async {
        let (router, _, _) = makeRouter()
        let low = await voice(router, ["degrees": .array([.number(1)])])
        let high = await voice(router, ["degrees": .array([.number(1)]),
                                        "octaveShift": .number(1)])
        #expect((pitches(chords(high)[0]).max() ?? 0)
            > (pitches(chords(low)[0]).max() ?? 0))
    }

    @Test("density overrides the preset's own, for the lo-fi seventh-chord move")
    func densityOverride() async {
        let (router, _, _) = makeRouter()
        let response = await voice(router, [
            "key": .string("C"), "density": .string("seventh"),
            "degrees": .array([.number(1), .number(5)]),
        ])
        let names = chords(response).compactMap { value -> String? in
            guard case .object(let payload) = value else { return nil }
            return payload["symbol"]?.stringValue
        }
        #expect(names == ["Cmaj7", "G7"])
    }

    // MARK: - Refusals, each naming the fix

    @Test("unknown keys are rejected with a hint that shows the shape")
    func rejectsUnknownKeys() async {
        let (router, _, _) = makeRouter()
        let response = await voice(router, [
            "degrees": .array([.number(1)]), "tempo": .number(120),
        ])
        #expect(response.error != nil)
        #expect(response.error?.contains("tempo") == true)
    }

    @Test("giving both degrees and chords, or neither, is refused")
    func exactlyOneInput() async {
        let (router, _, _) = makeRouter()
        let both = await voice(router, [
            "degrees": .array([.number(1)]), "chords": .array([.string("C")]),
        ])
        #expect(both.error != nil)
        let neither = await voice(router, ["key": .string("C")])
        #expect(neither.error != nil)
        #expect(neither.error?.contains("degrees") == true)
    }

    /// ⭐ **NIL, NEVER A SILENT DEFAULT.** A parser that answered "C major" for an
    /// unreadable string would hand an agent a wrong chord that looks exactly like
    /// a right one — this tree's characteristic failure mode.
    @Test("an unreadable chord symbol is named, never silently defaulted")
    func unreadableChordIsNamed() async {
        let (router, _, _) = makeRouter()
        let response = await voice(router, ["chords": .array([.string("H7b9#11")])])
        #expect(response.error != nil)
        #expect(response.error?.contains("H7b9#11") == true)
    }

    @Test("out-of-range degrees, presets, modes and shifts are all refused by name")
    func rangeRefusals() async {
        let (router, _, _) = makeRouter()
        let cases: [(params: [String: JSONValue], needle: String)] = [
            (["degrees": .array([.number(9)])], "degrees"),
            (["degrees": .array([.number(1)]), "preset": .string("theremin")], "preset"),
            (["degrees": .array([.number(1)]), "mode": .string("lydian")], "mode"),
            (["degrees": .array([.number(1)]), "octaveShift": .number(99)], "octaveShift"),
            (["degrees": .array([.number(1)]), "key": .number(99)], "key"),
        ]
        for (dict, needle) in cases {
            let response = await voice(router, dict)
            #expect(response.error != nil, "\(needle) was accepted")
            #expect(response.error?.contains(needle) == true,
                    "the refusal did not name \(needle) — it said: \(response.error ?? "nil")")
        }
    }

    @Test("an empty degree list is refused rather than answered with nothing")
    func emptyIsRefused() async {
        let (router, _, _) = makeRouter()
        #expect(await voice(router, ["degrees": .array([])]).error != nil)
        #expect(await voice(router, ["chords": .array([])]).error != nil)
    }
}
