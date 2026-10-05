import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// m32-b1 — CHOP-TO-TIMELINE on `clip.quantizeAudio`: the additive `divisions`
/// param, the `gridBeats`-optional-at-`strength: 0` relaxation, and the
/// mode-scoped rejection of `sensitivity`.
///
/// ⭐ THE LOAD-BEARING GATE IN HERE IS THE DETECTOR SPY, not the offsets.
/// The stub markers are planted at positions that are NOT division boundaries
/// (0.13 / 0.61 / 1.42 s), so a `divisions` request that silently fell through
/// to the detector would produce a plausible-looking chop at the WRONG cuts.
/// `engine.detectCalls == 0` plus the exact offsets catch that; either alone
/// would not. Each assertion carries a positive control that produces a
/// DIFFERENT array, because a comparison that can only return "equal" proves
/// nothing.
///
/// Reuses `FakeTransientEngine` (ClipTransientCommandTests.swift) and
/// `FakeMedia` (ControlTests.swift, 2 s file → 4 beats @ 120, spb 0.5), so the
/// clip's source window is [0, 2) s and a boundary at source second `s` sits at
/// timeline beat `2·s`.
@MainActor
@Suite("Clip audio quantize — chop to timeline (m32-b1)")
struct ClipQuantizeAudioGridTests {

    /// Onsets that are NOT equal-division boundaries of the [0, 2) s window —
    /// so detector output and divisions output can never be confused.
    private static let plantedMarkers = [
        TransientMarker(timeSeconds: 0.13, strength: 1.0),
        TransientMarker(timeSeconds: 0.61, strength: 0.8),
        TransientMarker(timeSeconds: 1.42, strength: 0.6),
    ]

    private func makeRouter(engine: FakeTransientEngine?) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        return (CommandRouter(store: store), store)
    }

    private func stubbedEngine() -> FakeTransientEngine {
        let engine = FakeTransientEngine()
        engine.stubMarkers = Self.plantedMarkers
        return engine
    }

    private func addAudioClip(_ router: CommandRouter) async throws
        -> (trackID: String, clipID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav"),
                     "atBeat": .number(0)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    /// One `clip.quantizeAudio` against a FRESH project (the verb replaces the
    /// clip, so every case needs its own).
    private func chop(_ extra: [String: JSONValue],
                      engine: FakeTransientEngine?) async throws
        -> (response: ControlResponse, store: ProjectStore, engine: FakeTransientEngine?) {
        let (router, store) = makeRouter(engine: engine)
        let (trackID, clipID) = try await addAudioClip(router)
        var params: [String: JSONValue] = ["trackId": .string(trackID),
                                           "clipId": .string(clipID)]
        params.merge(extra) { _, new in new }
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.quantizeAudio", params: params))
        return (response, store, engine)
    }

    /// ⚠️ `Clip.encode` OMITS `startOffsetSeconds` at its 0 default
    /// (`Model.swift:950`, the omit-when-default rule), so an ABSENT key means
    /// exactly 0 here — the head slice of every chop reads that way.
    private func sourceOffsets(_ response: ControlResponse) throws -> [Double] {
        let clips = try #require(response.result?["clips"]?.arrayValue)
        return clips.map { $0["startOffsetSeconds"]?.doubleValue ?? 0 }
    }

    private func startBeats(_ response: ControlResponse) throws -> [Double] {
        let clips = try #require(response.result?["clips"]?.arrayValue)
        return try clips.map { try #require($0["startBeat"]?.doubleValue) }
    }

    // MARK: - (a) divisions cuts into N equal parts, and the detector never runs

    @Test("divisions 8 at strength 0 → 8 clips on the quarter-second grid, detector NOT called")
    func divisionsChopsIntoEightAndSkipsTheDetector() async throws {
        let engine = stubbedEngine()
        let (response, store, _) = try await chop(
            ["divisions": .number(8), "strength": .number(0)], engine: engine)
        #expect(response.ok, "\(response.error ?? "?")")

        let offsets = try sourceOffsets(response)
        let beats = try startBeats(response)
        #expect(offsets.count == 8)
        for i in 0..<8 {
            #expect(abs(offsets[i] - Double(i) * 0.25) < 1e-9, "offset \(i)")
            #expect(abs(beats[i] - Double(i) * 0.5) < 1e-9, "beat \(i)")
        }
        #expect(store.tracks[0].clips.count == 8)
        // ⭐ THE SPY. No detection ran, so the planted markers cannot have
        // contributed a single boundary.
        #expect(engine.detectCalls == 0)
    }

    /// POSITIVE CONTROL for the test above: the SAME project and the SAME
    /// planted markers, without `divisions`, chop at the MARKERS instead and
    /// DO call the detector. If the spy or the offsets could not distinguish
    /// the two paths, this test and the previous one would agree.
    @Test("without divisions the same clip chops at the planted markers (positive control)")
    func detectorPathUsesTheMarkers() async throws {
        let engine = stubbedEngine()
        let (response, _, _) = try await chop(
            ["gridBeats": .number(1), "strength": .number(0)], engine: engine)
        #expect(response.ok, "\(response.error ?? "?")")

        let offsets = try sourceOffsets(response)
        #expect(offsets.count == 4)                    // head + 3 markers
        #expect(abs(offsets[0] - 0.0) < 1e-9)
        #expect(abs(offsets[1] - 0.13) < 1e-9)
        #expect(abs(offsets[2] - 0.61) < 1e-9)
        #expect(abs(offsets[3] - 1.42) < 1e-9)
        #expect(engine.detectCalls == 1)
        // And it is genuinely a DIFFERENT array from the divisions chop.
        let divisionsOffsets = try sourceOffsets(
            try await chop(["divisions": .number(8), "strength": .number(0)],
                           engine: stubbedEngine()).response)
        #expect(offsets != divisionsOffsets)
    }

    @Test("chop-to-timeline is ONE undo step and the slices tile the window")
    func chopIsOneUndoStep() async throws {
        let engine = stubbedEngine()
        let (router, store) = makeRouter(engine: engine)
        let (trackID, clipID) = try await addAudioClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.quantizeAudio",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "divisions": .number(4), "strength": .number(0)]))
        #expect(response.ok, "\(response.error ?? "?")")
        #expect(store.tracks[0].clips.count == 4)
        // Seams: slice i ends in SOURCE exactly where slice i+1 begins, so the
        // concatenation IS the original waveform (click-free by construction).
        let clips = store.tracks[0].clips
        for i in 0..<3 {
            #expect(abs((clips[i].startOffsetSeconds + clips[i].lengthBeats * 0.5)
                        - clips[i + 1].startOffsetSeconds) < 1e-9, "source seam \(i)")
            #expect(abs((clips[i].startBeat + clips[i].lengthBeats)
                        - clips[i + 1].startBeat) < 1e-9, "timeline seam \(i)")
            #expect(clips[i].fadeOutBeats == 0, "clean cut \(i)")
        }
        let undo = await router.handle(ControlRequest(id: "u", command: "edit.undo", params: [:]))
        #expect(undo.ok)
        #expect(store.tracks[0].clips.count == 1)      // ONE step restored the original
        #expect(store.tracks[0].clips[0].id.uuidString == clipID)
    }

    // MARK: - (b) mode-scoped params are rejected BY NAME, not ignored

    @Test("divisions + sensitivity is a named error and nothing is chopped")
    func sensitivityWithDivisionsIsRejected() async throws {
        let engine = stubbedEngine()
        let (response, store, _) = try await chop(
            ["divisions": .number(8), "strength": .number(0), "sensitivity": .number(0.7)],
            engine: engine)
        #expect(!response.ok)
        let error = response.error ?? ""
        #expect(error.contains("'sensitivity' only applies to transient slicing"))
        #expect(error.contains("'divisions'"))
        // A SINGLE problem keeps the plain message (no verb prefix) — the
        // shipped `combinedFieldProblems` rule, pinned by WireHardeningM16ETests.
        #expect(!error.contains("clip.quantizeAudio"))
        #expect(engine.detectCalls == 0)
        #expect(store.tracks[0].clips.count == 1)      // untouched

        // POSITIVE CONTROL: the same 'sensitivity' WITHOUT 'divisions' is
        // accepted, so the rejection is scoped and did not simply break the knob.
        let ok = try await chop(
            ["gridBeats": .number(1), "sensitivity": .number(0.7)], engine: stubbedEngine())
        #expect(ok.response.ok, "\(ok.response.error ?? "?")")
        #expect(ok.engine?.lastSensitivity == 0.7)
    }

    @Test("out-of-range and non-integer divisions are named errors")
    func divisionsRangeValidation() async throws {
        for bad in [JSONValue.number(1), .number(0), .number(129), .number(4.5)] {
            let engine = stubbedEngine()
            let (response, _, _) = try await chop(
                ["divisions": bad, "strength": .number(0)], engine: engine)
            #expect(!response.ok, "divisions \(bad) should be refused")
            #expect(response.error?.contains(
                "'divisions' must be a whole number between 2 and 128") == true)
            #expect(engine.detectCalls == 0)
        }
        // POSITIVE CONTROL: the boundary values of the same range are ACCEPTED.
        for good in [JSONValue.number(2), .number(128)] {
            let (response, _, _) = try await chop(
                ["divisions": good, "strength": .number(0)], engine: stubbedEngine())
            #expect(response.ok, "divisions \(good): \(response.error ?? "")")
        }
    }

    @Test("divisions too fine for the clip surfaces audioQuantizeDivisionsTooFine")
    func divisionsTooFineSurfacesVerbatim() async throws {
        // A 0.16-beat clip = 0.08 s window; halving it puts each boundary 0.04 s
        // from an edge, under the 0.05 s floor.
        let store = ProjectStore()
        store.media = FakeMedia()
        let tiny = Clip(name: "tiny", startBeat: 0, lengthBeats: 0.16,
                        audioFileURL: URL(fileURLWithPath: "/tmp/Loop.wav"),
                        startOffsetSeconds: 0)
        let track = Track(name: "Aud", kind: .audio, clips: [tiny])
        let store2 = ProjectStore(tracks: [track])
        store2.media = store.media
        let router = CommandRouter(store: store2)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.quantizeAudio",
            params: ["trackId": .string(track.id.uuidString),
                     "clipId": .string(tiny.id.uuidString),
                     "divisions": .number(2), "strength": .number(0)]))
        #expect(!response.ok)
        let error = response.error ?? ""
        #expect(error.contains("cannot be cut into 2 equal parts"))
        #expect(error.contains("0.080 s"))
        #expect(error.contains("minimum slice width"))
        // NOT detector advice — no detector ran.
        #expect(!error.contains("sensitivity"))
    }

    // MARK: - (c) gridBeats is optional at strength 0, and truly irrelevant there

    @Test("strength 0 without gridBeats chops identically to strength 0 WITH gridBeats")
    func gridBeatsIsIrrelevantAtStrengthZero() async throws {
        let omitted = try await chop(
            ["divisions": .number(8), "strength": .number(0)], engine: stubbedEngine())
        #expect(omitted.response.ok, "\(omitted.response.error ?? "?")")

        let withGrid = try await chop(
            ["divisions": .number(8), "strength": .number(0), "gridBeats": .number(1)],
            engine: stubbedEngine())
        #expect(withGrid.response.ok, "\(withGrid.response.error ?? "?")")

        let withOtherGrid = try await chop(
            ["divisions": .number(8), "strength": .number(0), "gridBeats": .number(0.25)],
            engine: stubbedEngine())
        #expect(withOtherGrid.response.ok, "\(withOtherGrid.response.error ?? "?")")

        let a = try sourceOffsets(omitted.response)
        #expect(try sourceOffsets(withGrid.response) == a)
        #expect(try sourceOffsets(withOtherGrid.response) == a)
        #expect(try startBeats(withGrid.response) == (try startBeats(omitted.response)))

        // ⭐ POSITIVE CONTROL — an equality that can only ever return "equal"
        // proves nothing. At strength 0.5 the SAME grid DOES move the slices.
        let nudged = try await chop(
            ["divisions": .number(8), "strength": .number(0.5), "gridBeats": .number(1)],
            engine: stubbedEngine())
        #expect(nudged.response.ok, "\(nudged.response.error ?? "?")")
        #expect(try startBeats(nudged.response) != (try startBeats(omitted.response)))
    }

    @Test("gridBeats stays REQUIRED above strength 0 — no shipped caller changes")
    func gridBeatsStillRequiredWhenNudging() async throws {
        // Omitted strength defaults to 1 → still required.
        var response = try await chop([:], engine: stubbedEngine()).response
        #expect(!response.ok)
        #expect(response.error?.contains("required param 'gridBeats'") == true)
        // Explicit non-zero strength → still required.
        response = try await chop(["strength": .number(0.5)], engine: stubbedEngine()).response
        #expect(!response.ok)
        #expect(response.error?.contains("required param 'gridBeats'") == true)
        // Divisions does NOT relax it either — only strength 0 does.
        response = try await chop(["divisions": .number(4)], engine: stubbedEngine()).response
        #expect(!response.ok)
        #expect(response.error?.contains("required param 'gridBeats'") == true)
        // POSITIVE CONTROL: strength 0 with the grid omitted is accepted.
        response = try await chop(["strength": .number(0)], engine: stubbedEngine()).response
        #expect(response.ok, "\(response.error ?? "?")")
    }

    // MARK: - Headless: divisions needs no engine, the detector path still does

    @Test("headless + divisions succeeds; headless without divisions still says engineUnavailable")
    func headlessDivisionsWorks() async throws {
        let (response, store, _) = try await chop(
            ["divisions": .number(4), "strength": .number(0)], engine: nil)
        #expect(response.ok, "\(response.error ?? "?")")
        #expect(store.tracks[0].clips.count == 4)

        // POSITIVE CONTROL: the shipped headless behaviour is unchanged for the
        // detector path.
        let detector = try await chop(["gridBeats": .number(1)], engine: nil)
        #expect(!detector.response.ok)
        #expect(detector.response.error == "audio engine not available")
    }

    @Test("headless + divisions + a MIDI clip still surfaces engineUnavailable first (order pin)")
    func headlessMidiOrderUnchanged() async throws {
        // The shipped ordering: with no engine, a MIDI clip reports the ENGINE
        // problem, not the clip-kind problem. Moving the guard below validation
        // would silently flip this for existing callers.
        let store = ProjectStore()
        store.media = FakeMedia()
        let router = CommandRouter(store: store)
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "lengthBeats": .number(4)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.quantizeAudio",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "gridBeats": .number(1)]))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    // MARK: - Wire surface

    @Test("divisions is an accepted key; a typo is still rejected")
    func divisionsIsAKnownKey() async throws {
        let accepted = try await chop(
            ["divisions": .number(4), "strength": .number(0)], engine: stubbedEngine())
        #expect(accepted.response.ok, "\(accepted.response.error ?? "?")")
        // POSITIVE CONTROL: the unknown-key guard is still live on this verb.
        let typo = try await chop(
            ["division": .number(4), "strength": .number(0)], engine: stubbedEngine())
        #expect(!typo.response.ok)
        #expect(typo.response.error?.contains("division") == true)
    }

    @Test("divisions composes with the grid: cut into 4, snap to the 1/4 grid")
    func divisionsComposesWithTheGrid() async throws {
        let chopOnly = try await chop(
            ["divisions": .number(4), "strength": .number(0)], engine: stubbedEngine())
        let snapped = try await chop(
            ["divisions": .number(4), "strength": .number(1), "gridBeats": .number(1)],
            engine: stubbedEngine())
        #expect(chopOnly.response.ok, "\(chopOnly.response.error ?? "?")")
        #expect(snapped.response.ok, "\(snapped.response.error ?? "?")")
        // The clip sits on the grid already, so 4 equal parts land on beats
        // 0/1/2/3 either way — what must hold is that BOTH paths ran the
        // divisions boundary source, with the detector untouched in each.
        #expect(chopOnly.engine?.detectCalls == 0)
        #expect(snapped.engine?.detectCalls == 0)
        #expect(try startBeats(snapped.response).count == 4)
    }
}
