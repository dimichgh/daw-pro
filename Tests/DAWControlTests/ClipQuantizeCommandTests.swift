import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M5 (iii-d) `clip.quantize`: the round-trip over
/// ProjectStore.quantizeClipNotes, MPC swing on the wire, field-named param
/// validation (gridBeats/strength/swing ranges — the parseFadeCurve style), and
/// store rejections (audio clip / unknown id) surfacing verbatim. Reuses
/// `FakeMedia` from ControlTests.swift (same target).
@MainActor
@Suite("Clip quantize — control protocol")
struct ClipQuantizeCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    /// Adds an instrument track + one 8-beat MIDI clip carrying `notes`,
    /// returning the clip id as a wire string.
    private func addMIDIClip(_ router: CommandRouter, notes: [JSONValue]) async throws -> String {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "lengthBeats": .number(8), "notes": .array(notes)]))
        return try #require(addClip.result?["id"]?.stringValue)
    }

    // 1.
    @Test("clip.quantize snaps onsets at strength 1, preserves lengths, store reflects")
    func happyPath() async throws {
        let (router, store) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: [
            .object(["pitch": .number(60), "startBeat": .number(0.2), "lengthBeats": .number(1)]),
            .object(["pitch": .number(64), "startBeat": .number(1.1), "lengthBeats": .number(0.5)]),
            .object(["pitch": .number(67), "startBeat": .number(1.9), "lengthBeats": .number(0.5)]),
        ])
        let resp = await router.handle(ControlRequest(
            id: "1", command: "clip.quantize",
            params: ["clipId": .string(clipID), "gridBeats": .number(1), "strength": .number(1)]))
        #expect(resp.ok)
        let notes = try #require(resp.result?["notes"]?.arrayValue)
        #expect(notes.compactMap { $0["startBeat"]?.doubleValue } == [0.0, 1.0, 2.0])
        #expect(notes.compactMap { $0["lengthBeats"]?.doubleValue } == [1.0, 0.5, 0.5])
        #expect(store.tracks[0].clips[0].notes!.map(\.startBeat) == [0.0, 1.0, 2.0])
    }

    // 2.
    @Test("swing 66 delays the offbeat slot by (2·0.66 − 1)·grid on the wire")
    func swing() async throws {
        let (router, _) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: [
            .object(["pitch": .number(60), "startBeat": .number(0.1), "lengthBeats": .number(1)]),  // slot 0 → 0
            .object(["pitch": .number(62), "startBeat": .number(0.9), "lengthBeats": .number(1)]),  // slot 1 → 1.32
        ])
        let resp = await router.handle(ControlRequest(
            id: "1", command: "clip.quantize",
            params: ["clipId": .string(clipID), "gridBeats": .number(1),
                     "strength": .number(1), "swing": .number(66)]))
        #expect(resp.ok)
        let starts = try #require(resp.result?["notes"]?.arrayValue).compactMap { $0["startBeat"]?.doubleValue }
        #expect(starts.count == 2)
        #expect(abs(starts[0] - 0.0) < 1e-9)
        #expect(abs(starts[1] - 1.32) < 1e-9)
    }

    // 3.
    @Test("param validation: gridBeats required + > 0, strength 0...1, swing 50...75, field-named")
    func paramValidation() async throws {
        let (router, _) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: [
            .object(["pitch": .number(60), "startBeat": .number(0.2)]),
        ])
        func quantize(_ extra: [String: JSONValue]) async -> ControlResponse {
            await router.handle(ControlRequest(id: "1", command: "clip.quantize",
                params: extra.merging(["clipId": .string(clipID)]) { a, _ in a }))
        }
        let missingGrid = await quantize([:])
        #expect(!missingGrid.ok)
        #expect(missingGrid.error?.contains("gridBeats") == true)

        let zeroGrid = await quantize(["gridBeats": .number(0)])
        #expect(!zeroGrid.ok)
        #expect(zeroGrid.error?.contains("greater than 0") == true)

        let badStrength = await quantize(["gridBeats": .number(1), "strength": .number(2)])
        #expect(!badStrength.ok)
        #expect(badStrength.error?.contains("strength") == true)

        let badSwing = await quantize(["gridBeats": .number(1), "swing": .number(90)])
        #expect(!badSwing.ok)
        #expect(badSwing.error?.contains("swing") == true)
    }

    // 4.
    @Test("store rejections surface verbatim: audio clip, unknown id")
    func storeRejections() async throws {
        let (router, _) = makeRouter()
        // Audio clip → quantizeRequiresMIDIClip verbatim.
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let audioTrackID = try #require(addTrack.result?["id"]?.stringValue)
        let addAudio = await router.handle(ControlRequest(
            id: "a", command: "clip.addAudio",
            params: ["trackId": .string(audioTrackID), "path": .string("/tmp/Loop.wav")]))
        let audioClipID = try #require(addAudio.result?["id"]?.stringValue)
        let onAudio = await router.handle(ControlRequest(
            id: "1", command: "clip.quantize",
            params: ["clipId": .string(audioClipID), "gridBeats": .number(1)]))
        #expect(!onAudio.ok)
        #expect(onAudio.error?.contains("clip.quantize applies only to MIDI clips") == true)

        // Unknown clip id → clipNotFound verbatim.
        let onMissing = await router.handle(ControlRequest(
            id: "2", command: "clip.quantize",
            params: ["clipId": .string(UUID().uuidString), "gridBeats": .number(1)]))
        #expect(!onMissing.ok)
        #expect(onMissing.error?.contains("no clip with id") == true)
    }

    // 5.
    @Test("allCommands advertises clip.quantize")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("clip.quantize"))
    }

    // MARK: m23-ap I5-F4 — the wire quantizes on the SONG's grid

    /// Adds an instrument track + one 8-beat MIDI clip at song beat `atBeat`,
    /// returning the clip id as a wire string.
    private func addMIDIClip(_ router: CommandRouter, atBeat: Double,
                             notes: [JSONValue]) async throws -> String {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "atBeat": .number(atBeat),
                     "lengthBeats": .number(8), "notes": .array(notes)]))
        return try #require(addClip.result?["id"]?.stringValue)
    }

    // 6.
    @Test("I5-F4 — clip.quantize on an OFF-GRID clip (at 2.1) lands its notes on the SONG's 1/16 lines (2.25, 2.5, 3.0), where the clip-counted grid put them 0.1 beat off every line")
    func offGridClipQuantizesOntoTheSongGrid() async throws {
        let (router, store) = makeRouter()
        let clipID = try await addMIDIClip(router, atBeat: 2.1, notes: [
            .object(["pitch": .number(60), "startBeat": .number(0.2), "lengthBeats": .number(0.5)]),
            .object(["pitch": .number(62), "startBeat": .number(0.37), "lengthBeats": .number(0.5)]),
            .object(["pitch": .number(64), "startBeat": .number(0.9), "lengthBeats": .number(0.5)]),
        ])
        // The fixture really is off the grid.
        #expect(store.tracks[0].clips[0].startBeat == 2.1)
        let resp = await router.handle(ControlRequest(
            id: "1", command: "clip.quantize",
            params: ["clipId": .string(clipID), "gridBeats": .number(0.25), "strength": .number(1)]))
        #expect(resp.ok)
        let local = try #require(resp.result?["notes"]?.arrayValue).compactMap { $0["startBeat"]?.doubleValue }
        let song = local.map { 2.1 + $0 }
        #expect(song.count == 3)
        #expect(zip(song, [2.25, 2.5, 3.0]).allSatisfy { abs($0 - $1) < 1e-9 }, "\(song)")
        // The store agrees with the response.
        #expect(store.tracks[0].clips[0].notes!.map { 2.1 + $0.startBeat }
            .allSatisfy { v in [2.25, 2.5, 3.0].contains { abs($0 - v) < 1e-9 } })
    }

    // 7.
    @Test("I5-F4 — clip.quantize on a clip that starts ON a grid line at an even song slot (beat 4: 1/4 slot 4, 1/8 slot 8) answers exactly what the same notes at beat 0 answer, straight and swung")
    func onGridClipQuantizesExactlyAsBefore() async throws {
        let notes: [JSONValue] = [
            .object(["pitch": .number(60), "startBeat": .number(0.2), "lengthBeats": .number(1)]),
            .object(["pitch": .number(64), "startBeat": .number(1.1), "lengthBeats": .number(0.5)]),
            .object(["pitch": .number(67), "startBeat": .number(1.9), "lengthBeats": .number(0.5)]),
        ]
        for extra in [["gridBeats": JSONValue.number(1)],
                      ["gridBeats": .number(0.5), "swing": .number(66)]] {
            var answers: [[Double]] = []
            for atBeat in [0.0, 4.0] {
                let (router, _) = makeRouter()
                let clipID = try await addMIDIClip(router, atBeat: atBeat, notes: notes)
                let resp = await router.handle(ControlRequest(
                    id: "1", command: "clip.quantize",
                    params: extra.merging(["clipId": .string(clipID)]) { a, _ in a }))
                #expect(resp.ok)
                answers.append(try #require(resp.result?["notes"]?.arrayValue)
                    .compactMap { $0["startBeat"]?.doubleValue })
            }
            #expect(answers[0].map(\.bitPattern) == answers[1].map(\.bitPattern), "\(extra): \(answers)")
        }
    }

    // 8.
    @Test("I5-F4 — clip.quantize swing counts from the SONG's beat 0 (ruled 2026-09-27): on a clip at 2.6 (an offbeat start) a swung 1/8 keeps the song's downbeats 3 and 4 straight and delays its offbeats 3.5 and 4.5, as clip.quantizeAudio does")
    func swingCountsFromTheSongsBeatZero() async throws {
        let (router, store) = makeRouter()
        let clipID = try await addMIDIClip(router, atBeat: 2.6, notes: [0.37, 0.93, 1.42, 1.87].enumerated().map {
            .object(["pitch": .number(Double(60 + $0.offset)), "startBeat": .number($0.element),
                     "lengthBeats": .number(0.25)])
        })
        #expect(store.tracks[0].clips[0].startBeat == 2.6)
        let resp = await router.handle(ControlRequest(
            id: "1", command: "clip.quantize",
            params: ["clipId": .string(clipID), "gridBeats": .number(0.5), "swing": .number(66)]))
        #expect(resp.ok)
        let song = try #require(resp.result?["notes"]?.arrayValue)
            .compactMap { $0["startBeat"]?.doubleValue }
            .map { 2.6 + $0 }
        #expect(song.count == 4)
        #expect(zip(song, [3.0, 3.66, 4.0, 4.66]).allSatisfy { abs($0 - $1) < 1e-9 }, "\(song)")
    }

    // 9.
    @Test("I5-F4 round 3 — clip.quantize refuses a grid finer than 1/1024 beat, or not finite, in words that name the finest grid allowed (0.0009765625); 1/1024 itself is accepted, 0 keeps its shipped wording, and a refused call leaves the notes alone")
    func refusesAbsurdGridsInWords() async throws {
        let (router, store) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: [
            .object(["pitch": .number(60), "startBeat": .number(1.3), "lengthBeats": .number(1)]),
        ])
        func quantize(_ grid: Double) async -> ControlResponse {
            await router.handle(ControlRequest(id: "1", command: "clip.quantize",
                params: ["clipId": .string(clipID), "gridBeats": .number(grid)]))
        }
        for grid in [1e-20, 1e-300, Double.leastNonzeroMagnitude, 0.0009, Double.infinity] {
            let resp = await quantize(grid)
            #expect(!resp.ok, "gridBeats \(grid) must be refused")
            #expect(resp.error?.contains("at least 1/1024 beat (0.0009765625)") == true,
                    "gridBeats \(grid): \(resp.error ?? "no error")")
        }
        #expect(store.tracks[0].clips[0].notes!.map(\.startBeat) == [1.3])
        let zero = await quantize(0)
        #expect(zero.error?.contains("greater than 0") == true)
        #expect(zero.error?.contains("1/1024") == false)
        // POSITIVE CONTROL: the floor itself passes and quantizes: 1.3 lands on
        // its nearest 1/1024 line, 1331/1024 = 1.2998046875.
        let finest = await quantize(1.0 / 1024)
        #expect(finest.ok, "\(finest.error ?? "")")
        let landed = try #require(store.tracks[0].clips[0].notes?.first?.startBeat)
        #expect(abs(landed - 1331.0 / 1024) < 1e-12, "\(landed)")
    }

    // MARK: - The timeline ceiling, end to end (m23-ap I5-F4 round 4)
    //
    // Hosted here, in an existing MainActor suite, because no new MainActor
    // suite may be added; the walker's own tests are TimelineCeilingTests.

    @Test("I5-F4 round 4 — the wire refuses a beat position or length past 2^20 beats before the command runs, at the top of the params or inside the notes, in words naming the param, its value and the limit; nothing is added; 2^20 itself is accepted")
    func timelineCeilingRefusesAFarClipOrNote() async throws {
        let (router, store) = makeRouter()
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        func addMIDI(_ extra: [String: JSONValue]) async -> ControlResponse {
            await router.handle(ControlRequest(id: "c", command: "clip.addMIDI", params: extra.merging(
                ["trackId": .string(trackID), "lengthBeats": .number(4)]) { mine, _ in mine }))
        }
        let far = await addMIDI(["atBeat": .number(1_048_577)])
        #expect(!far.ok)
        #expect(far.error == "'atBeat' is 1048577.0, past the timeline limit: a position, length or "
            + "offset in beats must be a finite number within 1048576 beats of beat 0 (2^20 beats, "
            + "about 145 hours at 120 BPM)", "\(far.error ?? "no error")")
        let farNote = await addMIDI(["notes": .array([
            .object(["pitch": .number(60), "startBeat": .number(0), "lengthBeats": .number(1)]),
            .object(["pitch": .number(62), "startBeat": .number(2e6), "lengthBeats": .number(1)]),
        ])])
        #expect(farNote.error?.hasPrefix("'notes[1].startBeat' is 2000000.0, past the timeline limit") == true,
                "\(farNote.error ?? "no error")")
        let long = await addMIDI(["lengthBeats": .number(5e6)])
        #expect(long.error?.hasPrefix("'lengthBeats' is 5000000.0, past the timeline limit") == true,
                "\(long.error ?? "no error")")
        #expect(store.tracks[0].clips.isEmpty)
        // CONTROL: the ceiling itself is a legal position.
        let edge = await addMIDI(["atBeat": .number(1_048_576)])
        #expect(edge.ok, "\(edge.error ?? "")")
        #expect(store.tracks[0].clips.count == 1)
    }

    @Test("I5-F4 round 4 — the same ceiling on every command, before its own checks: a far point inside automation.setPoints (decoded by the model's Codable), a far comp segment, a seek, a bar insert, a count-in, a move offset, a looper horizon; clip.repeatNotes' count (copies, not bars) is left to the command")
    func timelineCeilingCoversEveryCommand() async throws {
        let (router, _) = makeRouter()
        let someID = UUID().uuidString
        let cases: [(String, [String: JSONValue], String)] = [
            ("automation.setPoints", ["trackId": .string(someID), "laneId": .string(someID),
              "points": .array([.object(["beat": .number(2e6), "value": .number(0.5)])])], "'points[0].beat'"),
            ("take.setComp", ["trackId": .string(someID), "groupId": .string(someID), "segments": .array([.object([
              "laneId": .string(someID), "startBeat": .number(0), "endBeat": .number(3e6)])])],
             "'segments[0].endBeat'"),
            ("transport.seek", ["beats": .number(2e6)], "'beats'"),
            ("arrange.insertBars", ["atBar": .number(2e6), "count": .number(1)], "'atBar'"),
            ("arrange.deleteBars", ["fromBar": .number(1), "count": .number(2e6)], "'count'"),
            ("transport.setMetronome", ["countInBars": .number(2e6)], "'countInBars'"),
            ("clip.moveMany", ["ids": .array([.string(someID)]), "byBeats": .number(-2e6)], "'byBeats'"),
            ("looper.begin", ["bars": .number(4), "horizonCycles": .number(2e6)], "'horizonCycles'"),
        ]
        for (command, params, named) in cases {
            let resp = await router.handle(ControlRequest(id: "1", command: command, params: params))
            #expect(!resp.ok, "\(command)")
            #expect(resp.error?.hasPrefix("\(named) is ") == true && resp.error?.contains("past the timeline limit") == true,
                    "\(command): \(resp.error ?? "no error")")
        }
        let copies = await router.handle(ControlRequest(id: "1", command: "clip.repeatNotes", params: [
            "clipId": .string(someID), "periodBeats": .number(4), "count": .number(2e6)]))
        #expect(copies.error?.contains("timeline limit") == false, "\(copies.error ?? "no error")")
    }

    @Test("I5-F4 round 4 — a bar number of 1e20, which the wire converted with Int() before any check (a trap), is refused in words")
    func timelineCeilingStopsTheBarTrap() async {
        let (router, _) = makeRouter()
        for (command, params) in [("arrange.insertBars", ["atBar": JSONValue.number(1e20), "count": .number(1)]),
                                  ("arrange.deleteBars", ["fromBar": .number(1), "count": .number(1e20)]),
                                  ("transport.setMetronome", ["countInBars": .number(-1e20)])] {
            let resp = await router.handle(ControlRequest(id: "1", command: command, params: params))
            #expect(resp.error?.contains("past the timeline limit") == true, "\(command): \(resp.error ?? "no error")")
        }
    }

    @Test("I5-F4 round 4 — gridBeats keeps round 3's floor and gains the 2^20-beat ceiling in its own words, on clip.quantize and on clip.sliceToSampler's grid mode; clip.quantizeAudio's divisions refuses 1e20 in words (it trapped Int() before)")
    func gridCeilingAndSliceFloor() async throws {
        let (router, store) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: [
            .object(["pitch": .number(60), "startBeat": .number(1.3), "lengthBeats": .number(0.5)])])
        let long = await router.handle(ControlRequest(id: "1", command: "clip.quantize", params: [
            "clipId": .string(clipID), "gridBeats": .number(2e6)]))
        #expect(long.error == "'gridBeats' is 2000000.0, past the timeline limit: a grid may be at most "
            + "1048576 beats (2^20)", "\(long.error ?? "no error")")
        #expect(store.tracks[0].clips[0].notes?.first?.startBeat == 1.3)
        let edge = await router.handle(ControlRequest(id: "1", command: "clip.quantize", params: [
            "clipId": .string(clipID), "gridBeats": .number(1_048_576), "strength": .number(0)]))
        #expect(edge.ok, "\(edge.error ?? "")")
        for grid in [1e-20, 0.0009, 2e6] {
            let slice = await router.handle(ControlRequest(id: "1", command: "clip.sliceToSampler", params: [
                "clipId": .string(UUID().uuidString), "mode": .string("grid"), "gridBeats": .number(grid)]))
            #expect(!slice.ok)
            let words = grid < 1 ? "at least 1/1024 beat (0.0009765625)" : "a grid may be at most 1048576 beats"
            #expect(slice.error?.contains(words) == true, "gridBeats \(grid): \(slice.error ?? "no error")")
        }
        let divisions = await router.handle(ControlRequest(id: "1", command: "clip.quantizeAudio", params: [
            "trackId": .string(UUID().uuidString), "clipId": .string(UUID().uuidString),
            "divisions": .number(1e20), "strength": .number(0)]))
        #expect(divisions.error?.contains("'divisions' must be a whole number between") == true,
                "\(divisions.error ?? "no error")")
    }
}
