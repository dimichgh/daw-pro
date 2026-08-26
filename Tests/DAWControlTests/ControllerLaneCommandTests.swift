import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m16-b2: `clip.setControllerLane` /
/// `clip.removeControllerLane` — the round-trip, the verbatim teaching errors
/// (bad type, cc-without-controller, empty points, per-type value domains,
/// non-MIDI, caps, lane-not-found listing, rejectUnknownKeys), and the
/// `project.snapshot` carry (present when non-empty, omitted when empty). The
/// wire strings here ARE the contract (MCP surfaces them verbatim in phase 3).
@MainActor
@Suite("Controller lanes — control protocol (m16-b2)")
struct ControllerLaneCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    /// An instrument track with an empty MIDI clip; returns the clip id.
    private func midiClip(_ router: CommandRouter) async throws -> String {
        let track = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(track.result?["id"]?.stringValue)
        let add = await router.handle(ControlRequest(
            id: "m", command: "clip.addMIDI", params: ["trackId": .string(trackID)]))
        return try #require(add.result?["id"]?.stringValue)
    }

    // MARK: - round-trip

    @Test("clip.setControllerLane echoes the stored lane; removeControllerLane clears it")
    func roundTrip() async throws {
        let (router, _) = makeRouter()
        let clipID = try await midiClip(router)
        let set = await router.handle(ControlRequest(
            id: "s", command: "clip.setControllerLane", params: [
                "clipId": .string(clipID),
                "type": .string("cc"),
                "controller": .number(1),
                "points": .array([
                    .object(["beat": .number(0), "value": .number(0)]),
                    .object(["beat": .number(4), "value": .number(127)]),
                ]),
            ]))
        #expect(set.ok)
        let lanes = try #require(set.result?["controllerLanes"]?.arrayValue)
        #expect(lanes.count == 1)
        #expect(lanes[0]["type"]?["type"]?.stringValue == "cc")
        #expect(lanes[0]["type"]?["controller"]?.doubleValue == 1)
        #expect(lanes[0]["points"]?.arrayValue?.count == 2)

        let remove = await router.handle(ControlRequest(
            id: "r", command: "clip.removeControllerLane", params: [
                "clipId": .string(clipID), "type": .string("cc"), "controller": .number(1),
            ]))
        #expect(remove.ok)
        // The lane is gone → omit-when-empty means no controllerLanes key.
        #expect(remove.result?["controllerLanes"] == nil)
    }

    @Test("clip.setControllerLane pitchBend needs no controller and accepts the 0-16383 domain")
    func pitchBendRoundTrip() async throws {
        let (router, _) = makeRouter()
        let clipID = try await midiClip(router)
        let set = await router.handle(ControlRequest(
            id: "s", command: "clip.setControllerLane", params: [
                "clipId": .string(clipID),
                "type": .string("pitchBend"),
                "points": .array([.object(["beat": .number(0), "value": .number(8192)]),
                                  .object(["beat": .number(1), "value": .number(16383)])]),
            ]))
        #expect(set.ok)
        let lanes = try #require(set.result?["controllerLanes"]?.arrayValue)
        #expect(lanes[0]["type"]?["type"]?.stringValue == "pitchBend")
        #expect(lanes[0]["points"]?.arrayValue?.last?["value"]?.doubleValue == 16383)
    }

    // MARK: - m27 inert-lane warnings

    /// An instrument track + empty MIDI clip; returns (trackId, clipId).
    private func midiClipOnTrack(_ router: CommandRouter) async throws -> (String, String) {
        let track = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(track.result?["id"]?.stringValue)
        let add = await router.handle(ControlRequest(
            id: "m", command: "clip.addMIDI", params: ["trackId": .string(trackID)]))
        return (trackID, try #require(add.result?["id"]?.stringValue))
    }

    private func setLane(_ router: CommandRouter, clip: String,
                         controller: Int) async -> ControlResponse {
        await router.handle(ControlRequest(
            id: "s", command: "clip.setControllerLane", params: [
                "clipId": .string(clip),
                "type": .string("cc"),
                "controller": .number(Double(controller)),
                "points": .array([.object(["beat": .number(0), "value": .number(100)])]),
            ]))
    }

    /// The defect this round exists to end: a lane the instrument will never
    /// consume used to be accepted with a plain success. It is still accepted
    /// (lanes outlive instrument switches) but it now SAYS SO.
    @Test("a controller lane the instrument cannot consume comes back with a warning")
    func inertLaneWarns() async throws {
        let (router, _) = makeRouter()
        let (trackID, clip) = try await midiClipOnTrack(router)

        // A fresh instrument track carries NO instrument at all — worth its
        // own sentence, since a lane there reaches nothing whatsoever.
        let orphan = await setLane(router, clip: clip, controller: 74)
        #expect(orphan.ok)
        #expect(try #require(orphan.result?["warnings"]?.arrayValue?.first?.stringValue)
            .contains("no instrument"))

        #expect(await router.handle(ControlRequest(
            id: "i", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("polySynth")])).ok)

        // On the poly synth CC74 is inert: it consumes CC64 and bend only.
        let inert = await setLane(router, clip: clip, controller: 74)
        #expect(inert.ok)                                    // still accepted
        let warnings = try #require(inert.result?["warnings"]?.arrayValue)
        let text = try #require(warnings.first?.stringValue)
        print("[measured] inert CC74 on poly synth → \(text)")
        #expect(text.contains("CC74"))                       // names the controller
        #expect(text.contains("poly synth"))                 // names why
        #expect(text.contains("CC64"))                       // and what DOES work

        // CC64 is routed on the poly synth → no warning at all.
        let routed = await setLane(router, clip: clip, controller: 64)
        #expect(routed.ok)
        #expect(routed.result?["warnings"] == nil)
    }

    @Test("on a sampler CC11 is silent-free; CC1 warns until expressionModDepth opts in")
    func samplerExpressionWarnings() async throws {
        let (router, _) = makeRouter()
        let (trackID, clip) = try await midiClipOnTrack(router)
        let toSampler = await router.handle(ControlRequest(
            id: "i", command: "track.setInstrument", params: [
                "trackId": .string(trackID), "kind": .string("sampler"),
                "sampler": .object(["zones": .array([])]),
            ]))
        #expect(toSampler.ok)

        // CC11 is unconditional on the sampler — no warning.
        #expect(await setLane(router, clip: clip, controller: 11).result?["warnings"] == nil)

        // CC1 is wired but gated by a depth that defaults to 0.
        let gated = await setLane(router, clip: clip, controller: 1)
        let gatedText = try #require(gated.result?["warnings"]?.arrayValue?.first?.stringValue)
        print("[measured] CC1 on sampler at depth 0 → \(gatedText)")
        #expect(gatedText.contains("expressionModDepth"))    // names the exact fix
        #expect(gatedText.contains("CC1"))

        // Opt in, and the same lane stops warning.
        let opt = await router.handle(ControlRequest(
            id: "d", command: "track.setInstrument", params: [
                "trackId": .string(trackID), "kind": .string("sampler"),
                "sampler": .object(["expressionModDepth": .number(0.8)]),
            ]))
        #expect(opt.ok)
        #expect(opt.result?["sampler"]?["expressionModDepth"]?.doubleValue == 0.8)  // echoes back
        #expect(await setLane(router, clip: clip, controller: 1).result?["warnings"] == nil)

        // Channel pressure is consumed by nothing built-in.
        let pressure = await router.handle(ControlRequest(
            id: "p", command: "clip.setControllerLane", params: [
                "clipId": .string(clip), "type": .string("channelPressure"),
                "points": .array([.object(["beat": .number(0), "value": .number(64)])]),
            ]))
        let pressureText = try #require(
            pressure.result?["warnings"]?.arrayValue?.first?.stringValue)
        #expect(pressureText.contains("aftertouch"))
    }

    // MARK: - teaching errors (verbatim)

    private func setError(_ router: CommandRouter, _ params: [String: JSONValue]) async -> String {
        let response = await router.handle(ControlRequest(
            id: "e", command: "clip.setControllerLane", params: params))
        return response.error ?? ""
    }

    @Test("teaching errors are verbatim: bad type, cc-without-controller, empty, value domains")
    func teachingErrors() async throws {
        let (router, _) = makeRouter()
        let clipID = try await midiClip(router)
        let pts: JSONValue = .array([.object(["beat": .number(0), "value": .number(0)])])

        // Bad type string names the valid types.
        #expect(await setError(router, ["clipId": .string(clipID), "type": .string("mod"), "points": pts])
            .contains(#"'type' must be one of "cc", "pitchBend", "channelPressure""#))

        // cc without controller.
        #expect(await setError(router, ["clipId": .string(clipID), "type": .string("cc"), "points": pts])
            == #"'controller' is required when type is "cc" — an integer 0-127 (1 = mod wheel, 64 = sustain)"#)

        // Empty points steer to the remove verb.
        #expect(await setError(router, ["clipId": .string(clipID), "type": .string("pitchBend"),
                                        "points": .array([])])
            == "'points' must be non-empty — use clip.removeControllerLane to delete a lane")

        // pitchBend value out of the 0-16383 domain.
        #expect(await setError(router, ["clipId": .string(clipID), "type": .string("pitchBend"),
                                        "points": .array([.object(["beat": .number(0), "value": .number(20000)])])])
            == "points[0].value must be 0-16383 for pitchBend (8192 = center)")

        // cc value out of the 0-127 domain.
        #expect(await setError(router, ["clipId": .string(clipID), "type": .string("cc"), "controller": .number(1),
                                        "points": .array([.object(["beat": .number(0), "value": .number(200)])])])
            == "points[0].value must be 0-127")
    }

    @Test("an audio clip is rejected (notAMIDIClip surfaces)")
    func audioRejected() async throws {
        let (router, _) = makeRouter()
        let track = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(track.result?["id"]?.stringValue)
        let add = await router.handle(ControlRequest(
            id: "a", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav")]))
        let clipID = try #require(add.result?["id"]?.stringValue)
        let err = await setError(router, ["clipId": .string(clipID), "type": .string("pitchBend"),
                                          "points": .array([.object(["beat": .number(0), "value": .number(8192)])])])
        #expect(err.contains("audio clip"))
    }

    @Test("the 16-lanes cap surfaces its teaching error")
    func laneCapError() async throws {
        let (router, _) = makeRouter()
        let clipID = try await midiClip(router)
        for n in 0..<16 {
            let r = await router.handle(ControlRequest(
                id: "l\(n)", command: "clip.setControllerLane", params: [
                    "clipId": .string(clipID), "type": .string("cc"), "controller": .number(Double(n)),
                    "points": .array([.object(["beat": .number(0), "value": .number(1)])])]))
            #expect(r.ok)
        }
        let err = await setError(router, ["clipId": .string(clipID), "type": .string("pitchBend"),
                                          "points": .array([.object(["beat": .number(0), "value": .number(8192)])])])
        #expect(err.contains("already has 16 controller lanes — remove one first"))
    }

    @Test("removeControllerLane on an unknown lane lists the existing lanes")
    func removeUnknownLists() async throws {
        let (router, _) = makeRouter()
        let clipID = try await midiClip(router)
        _ = await router.handle(ControlRequest(
            id: "s", command: "clip.setControllerLane", params: [
                "clipId": .string(clipID), "type": .string("cc"), "controller": .number(64),
                "points": .array([.object(["beat": .number(0), "value": .number(127)])])]))
        let remove = await router.handle(ControlRequest(
            id: "r", command: "clip.removeControllerLane", params: [
                "clipId": .string(clipID), "type": .string("channelPressure")]))
        #expect(!remove.ok)
        #expect(remove.error?.contains("cc64") == true)   // the existing lane is listed
    }

    @Test("rejectUnknownKeys fires on both verbs")
    func rejectUnknownKeys() async throws {
        let (router, _) = makeRouter()
        let clipID = try await midiClip(router)
        let set = await router.handle(ControlRequest(
            id: "s", command: "clip.setControllerLane", params: [
                "clipId": .string(clipID), "type": .string("pitchBend"),
                "points": .array([.object(["beat": .number(0), "value": .number(8192)])]),
                "curve": .string("linear")]))   // unknown key
        #expect(!set.ok)
        #expect(set.error?.contains("unknown parameter") == true)
        #expect(set.error?.contains("'curve'") == true)

        let remove = await router.handle(ControlRequest(
            id: "r", command: "clip.removeControllerLane", params: [
                "clipId": .string(clipID), "type": .string("pitchBend"), "bogus": .bool(true)]))
        #expect(!remove.ok)
        #expect(remove.error?.contains("unknown parameter") == true)
    }

    // MARK: - snapshot carry

    @Test("project.snapshot carries controllerLanes when present and omits them when empty")
    func snapshotCarry() async throws {
        let (router, _) = makeRouter()
        let clipID = try await midiClip(router)

        // Before any lane: the snapshot clip has no controllerLanes key.
        var snap = await router.handle(ControlRequest(id: "q1", command: "project.snapshot", params: nil))
        var clip = try #require(snap.result?["tracks"]?.arrayValue?.first?["clips"]?.arrayValue?.first)
        #expect(clip["controllerLanes"] == nil)

        _ = await router.handle(ControlRequest(
            id: "s", command: "clip.setControllerLane", params: [
                "clipId": .string(clipID), "type": .string("cc"), "controller": .number(11),
                "points": .array([.object(["beat": .number(0), "value": .number(64)]),
                                  .object(["beat": .number(2), "value": .number(127)])])]))

        // After: the lane rides the snapshot verbatim.
        snap = await router.handle(ControlRequest(id: "q2", command: "project.snapshot", params: nil))
        clip = try #require(snap.result?["tracks"]?.arrayValue?.first?["clips"]?.arrayValue?.first)
        let lanes = try #require(clip["controllerLanes"]?.arrayValue)
        #expect(lanes.count == 1)
        #expect(lanes[0]["type"]?["controller"]?.doubleValue == 11)
        #expect(lanes[0]["points"]?.arrayValue?.count == 2)
    }

    // MARK: - m27 leg D: clip.applyBreathContour
    //
    // Folded into THIS suite (the tree is at its 330-@MainActor-suite ceiling),
    // and it belongs here anyway: this verb writes the same two controller
    // lanes clip.setControllerLane does.

    /// A sampler track with one 4-beat (2 s at the default 120 BPM) note —
    /// long enough to earn vibrato.
    private func breathClip(_ router: CommandRouter, lengthBeats: Double = 4)
    async throws -> (clipID: String, noteID: String) {
        let track = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(track.result?["id"]?.stringValue)
        _ = await router.handle(ControlRequest(
            id: "i", command: "track.setInstrument", params: [
                "trackId": .string(trackID), "kind": .string("sampler")]))
        let add = await router.handle(ControlRequest(
            id: "m", command: "clip.addMIDI", params: [
                "trackId": .string(trackID), "lengthBeats": .number(lengthBeats + 1)]))
        let clipID = try #require(add.result?["id"]?.stringValue)
        let notes = await router.handle(ControlRequest(
            id: "n", command: "clip.setNotes", params: [
                "clipId": .string(clipID),
                "notes": .array([.object(["pitch": .number(69), "velocity": .number(100),
                                          "startBeat": .number(0),
                                          "lengthBeats": .number(lengthBeats)])])]))
        let noteID = try #require(notes.result?["notes"]?.arrayValue?.first?["id"]?.stringValue)
        return (clipID, noteID)
    }

    /// Fires the verb and returns the response, so every round-trip case below
    /// reads as "call, then read the stored lane back".
    private func applyBreath(_ router: CommandRouter, clipID: String,
                             _ extra: [String: JSONValue] = [:]) async -> ControlResponse {
        var params: [String: JSONValue] = ["clipId": .string(clipID)]
        for (key, value) in extra { params[key] = value }
        return await router.handle(ControlRequest(
            id: "b", command: "clip.applyBreathContour", params: params))
    }

    /// The stored points of one lane, straight off the response.
    private func lanePoints(_ response: ControlResponse,
                            type: String, controller: Double? = nil) -> [JSONValue] {
        let lanes = response.result?["controllerLanes"]?.arrayValue ?? []
        return lanes.first {
            $0["type"]?["type"]?.stringValue == type
            && (controller == nil || $0["type"]?["controller"]?.doubleValue == controller)
        }?["points"]?.arrayValue ?? []
    }

    @Test("clip.applyBreathContour writes both lanes and reports what it did")
    func breathContourRoundTrip() async throws {
        let (router, _) = makeRouter()
        let (clipID, _) = try await breathClip(router)
        let response = await applyBreath(router, clipID: clipID)
        #expect(response.ok)
        let expression = lanePoints(response, type: "cc", controller: 11)
        let bend = lanePoints(response, type: "pitchBend")
        print("[measured] wire: \(expression.count) CC11 + \(bend.count) bend points; "
              + "notesTouched \(response.result?["notesTouched"]?.doubleValue ?? -1), "
              + "notesWithVibrato \(response.result?["notesWithVibrato"]?.doubleValue ?? -1), "
              + "budget \(response.result?["perNotePointBudget"]?.doubleValue ?? -1)")
        #expect(expression.count > 20)
        #expect(bend.count > 50)
        #expect(response.result?["notesTouched"]?.doubleValue == 1)
        #expect(response.result?["notesWithVibrato"]?.doubleValue == 1)
        #expect(response.result?["expressionPointCount"]?.doubleValue == Double(expression.count))
        #expect(response.result?["pitchBendPointCount"]?.doubleValue == Double(bend.count))
        #expect(response.result?["perNotePointBudget"]?.doubleValue == 16384)
        // The half-success warning rides the response (this sampler has no
        // expressionFilterDepth), the media-import idiom.
        let warnings = try #require(response.result?["warnings"]?.arrayValue)
        #expect(warnings.contains { $0.stringValue?.contains("LOUDNESS but not BRIGHTNESS") == true })
    }

    /// ⭐⭐ THE ROUND-TRIP PROOF, ONE CASE PER PARAMETER.
    ///
    /// A parameter that is described but never reaches the model produces
    /// output IDENTICAL TO THE DEFAULT — it cannot be caught by checking that
    /// the call succeeded, and earlier in this very round three such params
    /// shipped. So each field is set to a value whose effect on the STORED
    /// LANES is unmistakable, and the stored lanes are read back and compared
    /// against the default run. Fifteen fields, fifteen comparisons, no
    /// sampling.
    @Test("EVERY contour parameter reaches the model: each one changes the stored lanes")
    func everyParameterRoundTrips() async throws {
        let (router, _) = makeRouter()

        /// Applies the contour with one override on a FRESH clip and returns a
        /// fingerprint of the stored lanes.
        ///
        /// ⚠️ It carries BEATS as well as values, and that is not decoration:
        /// the first version compared values only, and `peakPosition` came back
        /// "IDENTICAL TO DEFAULT" — because moving the peak changes WHEN the
        /// contour passes through each value, not WHICH values it passes
        /// through (the knots and the travel are unchanged, and stepwise
        /// thinning collapses each run to its distinct values either way). A
        /// value-only fingerprint would have reported a live parameter as dead.
        typealias Print = (cc: Int, expression: [Double], expressionBeats: [Double],
                           bend: [Double], bendBeats: [Double])
        func fingerprint(_ override: [String: JSONValue]) async throws -> Print {
            let (clipID, _) = try await breathClip(router, lengthBeats: 8)
            let response = await applyBreath(router, clipID: clipID, override)
            #expect(response.ok, "\(override.keys) was rejected: \(String(describing: response.error))")
            let lanes = response.result?["controllerLanes"]?.arrayValue ?? []
            let ccPoints = lanes.first { $0["type"]?["type"]?.stringValue == "cc" }?["points"]?
                .arrayValue ?? []
            let bendPoints = lanePoints(response, type: "pitchBend")
            return (cc: Int(lanes.first { $0["type"]?["type"]?.stringValue == "cc" }?["type"]?["controller"]?
                        .doubleValue ?? -1),
                    expression: ccPoints.compactMap { $0["value"]?.doubleValue },
                    expressionBeats: ccPoints.compactMap { $0["beat"]?.doubleValue },
                    bend: bendPoints.compactMap { $0["value"]?.doubleValue },
                    bendBeats: bendPoints.compactMap { $0["beat"]?.doubleValue })
        }

        let base = try await fingerprint([:])
        #expect(base.cc == 11)
        #expect(!base.expression.isEmpty && !base.bend.isEmpty)

        // Each entry: the override, and what must differ from the default run.
        var report: [String] = []
        func check(_ key: String, _ value: JSONValue,
                   _ differs: (Print) -> Bool,
                   _ how: String) async throws {
            let out = try await fingerprint([key: value])
            let ok = differs(out)
            let verdict = ok ? "CHANGED" : "*** IDENTICAL TO DEFAULT ***"
            let shown = value.doubleValue.map { "\($0)" } ?? "?"
            report.append("\(key)=\(shown) → \(how): \(verdict)")
            // A param dropped between the schema and the handler produces
            // output IDENTICAL to the default — that is what this catches.
            #expect(ok, "'\(key)' did not reach the model: the stored lanes match the default run")
        }

        try await check("depth", .number(0.8), { $0.expression.min() != base.expression.min() },
                        "expression trough moves")
        try await check("peakValue", .number(100), { $0.expression.max() != base.expression.max() },
                        "expression peak moves")
        try await check("peakPosition", .number(0.3), { $0.expressionBeats != base.expressionBeats },
                        "the swell's peak moves earlier in the note")
        try await check("attackSettleSeconds", .number(0.4),
                        { $0.expressionBeats != base.expressionBeats },
                        "the dip moves later")
        try await check("expressionCC", .number(2), { $0.cc != base.cc },
                        "the lane's controller number changes")
        try await check("expressionSpacingSeconds", .number(0.5),
                        { $0.expression.count != base.expression.count },
                        "far fewer expression points")
        try await check("vibratoOnsetSeconds", .number(2.5), { $0.bend != base.bend },
                        "vibrato starts later")
        try await check("vibratoRateHz", .number(9), { $0.bend != base.bend },
                        "the oscillation's period changes")
        try await check("vibratoDepthCents", .number(60),
                        { ($0.bend.max() ?? 0) > (base.bend.max() ?? 0) + 100 },
                        "the bend swings much wider")
        try await check("vibratoBloomSeconds", .number(0.05), { $0.bend != base.bend },
                        "the widening ramp changes")
        try await check("vibratoReleaseSeconds", .number(1.5), { $0.bend != base.bend },
                        "the relax back to centre lengthens")
        try await check("sharpenCents", .number(80),
                        { ($0.bend.max() ?? 0) > (base.bend.max() ?? 0) + 100 },
                        "the whole bend biases sharp")
        try await check("bendSpacingSeconds", .number(0.05),
                        { $0.bend.count < base.bend.count / 2 },
                        "far fewer bend points")
        try await check("bendRangeSemitones", .number(12),
                        { ($0.bend.max() ?? 0) < (base.bend.max() ?? 0) - 100 },
                        "the same cents need fewer units")

        // noteIds is the fifteenth settable input and the one that is NOT an
        // Options field — proven by shaping ONE of two notes.
        let (twoNoteClip, _) = try await breathClip(router, lengthBeats: 4)
        _ = await router.handle(ControlRequest(
            id: "n2", command: "clip.setNotes", params: [
                "clipId": .string(twoNoteClip),
                "notes": .array([
                    .object(["pitch": .number(69), "startBeat": .number(0),
                             "lengthBeats": .number(4)]),
                    .object(["pitch": .number(71), "startBeat": .number(4),
                             "lengthBeats": .number(4)])])]))
        let listed = await router.handle(ControlRequest(
            id: "g", command: "clip.getNotes", params: ["clipId": .string(twoNoteClip)]))
        let firstID = try #require(listed.result?["notes"]?.arrayValue?.first?["id"]?.stringValue)
        let oneNote = await applyBreath(router, clipID: twoNoteClip,
                                        ["noteIds": .array([.string(firstID)])])
        report.append("noteIds=[first] → notesTouched "
                      + "\(oneNote.result?["notesTouched"]?.doubleValue ?? -1) of 2")
        #expect(oneNote.result?["notesTouched"]?.doubleValue == 1)

        print("[measured] per-parameter round-trip:\n  " + report.joined(separator: "\n  "))
    }

    @Test("out-of-range options are REFUSED with a teaching sentence, never silently clamped")
    func breathContourRefusesBadOptions() async throws {
        let (router, _) = makeRouter()
        let (clipID, _) = try await breathClip(router)
        let tooFast = await applyBreath(router, clipID: clipID, ["vibratoRateHz": .number(40)])
        #expect(!tooFast.ok)
        #expect(tooFast.error?.contains("vibratoRateHz") == true)
        #expect(tooFast.error?.contains("0.2") == true && tooFast.error?.contains("20.0") == true)
        // A fractional integer param is refused, not truncated (m23-aj-2).
        let fractional = await applyBreath(router, clipID: clipID, ["peakValue": .number(100.5)])
        #expect(!fractional.ok)
        #expect(fractional.error?.contains("whole number") == true)
        print("[measured] refusals: \(tooFast.error ?? "-") | \(fractional.error ?? "-")")
    }

    @Test("clip.applyBreathContour rejects unknown keys, naming the bad one")
    func breathContourRejectsUnknownKeys() async throws {
        let (router, _) = makeRouter()
        let (clipID, _) = try await breathClip(router)
        let bad = await applyBreath(router, clipID: clipID, ["vibratoRate": .number(5)])
        #expect(!bad.ok)
        #expect(bad.error?.contains("vibratoRate") == true)
        #expect(bad.error?.contains("vibratoRateHz") == true)   // lists the valid keys
    }

    @Test("an audio clip is refused verbatim, naming this verb")
    func breathContourRefusesAudioClips() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(kind: .audio)
        let clip = try store.importAudio(
            url: URL(fileURLWithPath: "/tmp/leg-d-fake.wav"), toTrack: track.id, atBeat: 0)
        let response = await applyBreath(router, clipID: clip.id.uuidString)
        #expect(!response.ok)
        #expect(response.error?.contains("clip.applyBreathContour") == true)
    }

    // MARK: - Breath pad P1: clip.applyEffortShape
    //
    // Folded into THIS suite, same reason as leg D's block above: the tree is at
    // its 330-@MainActor-suite ceiling and this is the controller-lane wire.

    /// Four abutting held notes on a sampler track — one phrase, long enough
    /// that a phrase-scoped pattern has somewhere to travel.
    private func effortClip(_ router: CommandRouter) async throws -> String {
        let track = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(track.result?["id"]?.stringValue)
        _ = await router.handle(ControlRequest(
            id: "i", command: "track.setInstrument", params: [
                "trackId": .string(trackID), "kind": .string("sampler")]))
        let add = await router.handle(ControlRequest(
            id: "m", command: "clip.addMIDI", params: [
                "trackId": .string(trackID), "lengthBeats": .number(17)]))
        let clipID = try #require(add.result?["id"]?.stringValue)
        let notes = (0..<4).map { i in
            JSONValue.object(["pitch": .number(69), "velocity": .number(100),
                              "startBeat": .number(Double(i) * 4), "lengthBeats": .number(4)])
        }
        _ = await router.handle(ControlRequest(
            id: "n", command: "clip.setNotes",
            params: ["clipId": .string(clipID), "notes": .array(notes)]))
        return clipID
    }

    private func applyEffort(_ router: CommandRouter, clipID: String, pattern: String,
                             _ extra: [String: JSONValue] = [:]) async -> ControlResponse {
        var params: [String: JSONValue] = ["clipId": .string(clipID), "pattern": .string(pattern)]
        for (key, value) in extra { params[key] = value }
        return await router.handle(ControlRequest(
            id: "e", command: "clip.applyEffortShape", params: params))
    }

    @Test("clip.applyEffortShape round-trips a phrase-scoped hairpin and reports the effort range")
    func effortShapeRoundTrip() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)
        let response = await applyEffort(router, clipID: clipID, pattern: "hairpinCrescendo")
        #expect(response.ok)
        let expression = lanePoints(response, type: "cc", controller: 11)
        let minEffort = try #require(response.result?["minEffort"]?.doubleValue)
        let maxEffort = try #require(response.result?["maxEffort"]?.doubleValue)
        print("[measured] wire effort shape: \(expression.count) CC11 points; scope "
              + "\(response.result?["scope"]?.stringValue ?? "-"), phrases "
              + "\(response.result?["phraseCount"]?.doubleValue ?? -1), effort "
              + "\(minEffort)…\(maxEffort)")
        #expect(response.result?["patternId"]?.stringValue == "hairpinCrescendo")
        #expect(response.result?["patternName"]?.stringValue == "Hairpin crescendo")
        #expect(response.result?["scope"]?.stringValue == "phrase")
        #expect(response.result?["notesTouched"]?.doubleValue == 4)
        #expect(response.result?["phraseCount"]?.doubleValue == 1)
        // ⭐ The field that distinguishes "ran and shaped" from "ran and did
        // nothing". Equal values would mean the latter.
        #expect(maxEffort > minEffort)
        #expect(expression.count > 20)
    }

    /// Case-insensitive resolution, and an UNKNOWN pattern refused with the
    /// valid list — never a silent fall back to a default gesture.
    @Test("clip.applyEffortShape resolves a pattern case-insensitively and refuses an unknown one")
    func effortShapePatternResolution() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)
        let loose = await applyEffort(router, clipID: clipID, pattern: "MESSADIVOCE")
        #expect(loose.ok)
        #expect(loose.result?["patternId"]?.stringValue == "messaDiVoce",
                "the canonical id is echoed back")

        let unknown = await applyEffort(router, clipID: clipID, pattern: "airRunsOut")
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("airRunsOut") == true)
        #expect(unknown.error?.contains("messaDiVoce") == true, "the refusal must list the valid ids")
        print("[measured] unknown-pattern refusal: \(unknown.error ?? "-")")

        let missing = await router.handle(ControlRequest(
            id: "e", command: "clip.applyEffortShape", params: ["clipId": .string(clipID)]))
        #expect(!missing.ok)
        #expect(missing.error?.contains("pattern") == true)
    }

    /// ⭐⭐ THE ROUND-TRIP PROOF for the parameters this verb ADDS. Each is set
    /// to a value whose effect on the STORED lane is unmistakable, and compared
    /// against the default run — a param that never reaches the model produces
    /// output identical to the default and cannot be caught by checking `ok`.
    @Test("EVERY new parameter reaches the model: each one changes the stored lanes")
    func effortShapeParametersAllReachTheModel() async throws {
        func points(_ extra: [String: JSONValue],
                    pattern: String = "hairpinCrescendo") async throws -> [(beat: Double, value: Int)] {
            let (router, _) = makeRouter()
            let clipID = try await effortClip(router)
            let response = await applyEffort(router, clipID: clipID, pattern: pattern, extra)
            #expect(response.ok, "\(extra) was refused: \(response.error ?? "-")")
            return lanePoints(response, type: "cc", controller: 11).compactMap {
                guard let beat = $0["beat"]?.doubleValue,
                      let value = $0["value"]?.doubleValue else { return nil }
                return (beat, Int(value))
            }
        }
        func run(_ extra: [String: JSONValue],
                 pattern: String = "hairpinCrescendo") async throws -> [Int] {
            try await points(extra, pattern: pattern).map(\.value)
        }
        let baseline = try await run([:])
        #expect(!baseline.isEmpty)

        // ⚠️ MEASURED, and it corrected this test's first draft: `amount: 0` on a
        // PHRASE-scoped pattern does NOT flatten the lane. It removes the ARC
        // ACROSS the phrase while every note keeps its ordinary contour, so the
        // right assertion is that all four notes now peak at the SAME value —
        // which is also a much sharper assertion than "something changed".
        let flatArc = try await points(["amount": .number(0)])
        func perNotePeaks(_ points: [(beat: Double, value: Int)]) -> [Int] {
            (0..<4).map { i in
                let lo = Double(i) * 4, hi = lo + 4
                return points.filter { $0.beat >= lo - 1e-9 && $0.beat <= hi + 1e-9 }
                    .map(\.value).max() ?? -1
            }
        }
        let flatPeaks = perNotePeaks(flatArc)
        let arcPeaks = perNotePeaks(try await points([:]))
        print("[measured] per-note peaks — amount 1 \(arcPeaks), amount 0 \(flatPeaks)")
        #expect(Set(flatPeaks).count == 1, "amount 0 must remove the phrase arc")
        #expect(Set(arcPeaks).count == 4, "amount 1 must give every note its own level")
        #expect(Set(flatArc.map(\.value)).count > 1,
                "…but each note still breathes: amount 0 is not a flat lane on a phrase pattern")
        // The note-scoped half of the same parameter: there the pattern owns the
        // intra-note shape, so amount 0 IS a flat lane.
        #expect(Set(try await run(["amount": .number(0)], pattern: "messaDiVoce")).count == 1,
                "on a NOTE-scoped pattern, amount 0 writes a flat lane")
        // loudnessDepth 0 removes the hairpin's level travel between notes.
        let noLoudness = try await run(["loudnessDepth": .number(0)])
        #expect(noLoudness != baseline)
        #expect((noLoudness.max() ?? 0) - (noLoudness.min() ?? 0)
                < (baseline.max() ?? 0) - (baseline.min() ?? 0))
        // swellDepth changes the per-note swell without changing the peaks.
        #expect(try await run(["swellDepth": .number(0)]) != baseline)
        // peakValue caps the whole lane.
        let quieter = try await run(["peakValue": .number(80)])
        #expect((quieter.max() ?? 999) <= 80)
        // maxGapBeats only matters where there IS a gap — but these notes abut,
        // so a HUGE ceiling must be a no-op, which is itself the assertion that
        // it is wired to phrase splitting and not to something else.
        #expect(try await run(["maxGapBeats": .number(16)]) == baseline)
        // The leg-D passthrough that shapes the lane this verb writes.
        #expect(try await run(["expressionSpacingSeconds": .number(0.2)]) != baseline)
        #expect(try await run(["attackSettleSeconds": .number(0.5)],
                              pattern: "sforzandoPiano") != baseline)
        print("[measured] baseline CC span \((baseline.max() ?? 0) - (baseline.min() ?? 0)); "
              + "loudnessDepth 0 span \((noLoudness.max() ?? 0) - (noLoudness.min() ?? 0))")
    }

    @Test("clip.applyEffortShape rejects unknown keys and refuses the pattern-owned ones")
    func effortShapeRejectsUnknownKeys() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)
        let typo = await applyEffort(router, clipID: clipID, pattern: "flat",
                                     ["ammount": .number(0.5)])
        #expect(!typo.ok)
        #expect(typo.error?.contains("ammount") == true)
        #expect(typo.error?.contains("amount") == true, "the refusal lists the valid keys")

        // ⭐ depth / peakPosition are DELIBERATELY not accepted here — they ARE
        // the pattern. A caller sending them is refused rather than having them
        // silently ignored, which is the whole point of rejectUnknownKeys.
        for owned in ["depth", "peakPosition", "onsetLevel", "releaseLevel"] {
            let response = await applyEffort(router, clipID: clipID, pattern: "flat",
                                             [owned: .number(0.5)])
            #expect(!response.ok, "'\(owned)' should be refused, not silently dropped")
            #expect(response.error?.contains(owned) == true)
        }
    }

    @Test("an out-of-range value is REFUSED with a teaching sentence, never clamped")
    func effortShapeRefusesOutOfRange() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)
        let tooStrong = await applyEffort(router, clipID: clipID, pattern: "flat",
                                          ["amount": .number(1.5)])
        #expect(!tooStrong.ok)
        #expect(tooStrong.error?.contains("amount") == true)
        let tooDeep = await applyEffort(router, clipID: clipID, pattern: "flat",
                                        ["loudnessDepth": .number(2)])
        #expect(!tooDeep.ok)
        print("[measured] refusals: \(tooStrong.error ?? "-") | \(tooDeep.error ?? "-")")
    }

    /// The wire half of the inert-parameter gate: PRESENCE is what earns the
    /// warning, and `boundedOption` cannot see presence — it returns the
    /// default for an absent key. So a caller who sends `loudnessDepth` on a
    /// note-scoped pattern is told it did nothing, and an ordinary call that
    /// sends neither key is not nagged about a default it never chose.
    @Test("sending loudnessDepth on a NOTE-scoped pattern is warned about, not silently ignored")
    func effortShapeWarnsAboutAnInertResponseOverTheWire() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)

        let asked = await applyEffort(router, clipID: clipID, pattern: "messaDiVoce",
                                      ["loudnessDepth": .number(0.9)])
        let askedWarnings = (asked.result?["warnings"]?.arrayValue ?? []).compactMap(\.stringValue)
        #expect(asked.ok)
        #expect(askedWarnings.contains { $0.contains("did NOTHING") })

        // Neither key sent → no nag. This is the assertion that would fail if
        // the handler compared the response to `.identity` instead of asking
        // whether the caller supplied one.
        let plain = await applyEffort(router, clipID: clipID, pattern: "messaDiVoce")
        let plainWarnings = (plain.result?["warnings"]?.arrayValue ?? []).compactMap(\.stringValue)
        #expect(plain.ok)
        #expect(!plainWarnings.contains { $0.contains("did NOTHING") })

        // POSITIVE CONTROL — the same key on a phrase-scoped pattern is live.
        let live = await applyEffort(router, clipID: clipID, pattern: "hairpinCrescendo",
                                     ["loudnessDepth": .number(0.9)])
        let liveWarnings = (live.result?["warnings"]?.arrayValue ?? []).compactMap(\.stringValue)
        print("[measured] wire inert-response: asked \(askedWarnings) | plain \(plainWarnings) "
              + "| phrase \(liveWarnings)")
        #expect(live.ok)
        #expect(!liveWarnings.contains { $0.contains("did NOTHING") })
    }

    @Test("an audio clip is refused verbatim, naming clip.applyEffortShape")
    func effortShapeRefusesAudioClips() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(kind: .audio)
        let clip = try store.importAudio(
            url: URL(fileURLWithPath: "/tmp/pad-p1-fake.wav"), toTrack: track.id, atBeat: 0)
        let response = await applyEffort(router, clipID: clip.id.uuidString, pattern: "flat")
        #expect(!response.ok)
        #expect(response.error?.contains("clip.applyEffortShape") == true)
    }

    // MARK: - Breath pad P2 — the ring on the wire

    /// The ring form: no `pattern`, a dot at `degrees`.
    private func applyRing(_ router: CommandRouter, clipID: String, degrees: Double,
                           _ extra: [String: JSONValue] = [:]) async -> ControlResponse {
        var params: [String: JSONValue] = ["clipId": .string(clipID),
                                           "ringAngle": .number(degrees)]
        for (key, value) in extra { params[key] = value }
        return await router.handle(ControlRequest(
            id: "r", command: "clip.applyEffortShape", params: params))
    }

    @Test("P2 wire: a dot on the ring shapes the clip and reports where it landed")
    func ringFormRoundTrips() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)
        // 157.5° — the seam between the two hairpins, whose 0.5/0.5 blend is
        // analytically constant at 0.625 ⇒ every note's peak CC is 101.
        let response = await applyRing(router, clipID: clipID, degrees: 157.5)
        let ring = try #require(response.result?["ring"]?.objectValue)
        let weights = (ring["weights"]?.arrayValue ?? []).compactMap(\.doubleValue)
        let peaks = lanePoints(response, type: "cc", controller: 11)
            .compactMap { $0["value"]?.doubleValue }
        print("[measured] P2 wire ring: angle \(ring["angleDegrees"] ?? .null), "
              + "weights \(weights), noteWeight \(ring["noteWeight"] ?? .null), "
              + "distinct CC \(Set(peaks).count), max \(peaks.max() ?? -1)")

        #expect(response.ok)
        #expect(ring["angleDegrees"]?.doubleValue == 157.5)
        #expect(ring["radius"]?.doubleValue == 1)
        #expect((ring["patternIds"]?.arrayValue ?? []).count == 8)
        #expect(abs(weights.reduce(0, +) - 1) < 1e-12)
        #expect(abs(weights[3] - 0.5) < 1e-12)      // hairpinCrescendo
        #expect(abs(weights[4] - 0.5) < 1e-12)      // hairpinDiminuendo
        #expect(ring["phraseWeight"]?.doubleValue == 1)
        #expect(ring["noteWeight"]?.doubleValue == 0)
        #expect(response.result?["minEffort"]?.doubleValue == 0.625)
        #expect(peaks.max() == 101, "an equal-power blend would peak at 119")

        // The SINGLE-PATTERN form carries no `ring` key at all.
        let plain = await applyEffort(router, clipID: clipID, pattern: "messaDiVoce")
        #expect(plain.ok)
        #expect(plain.result?["ring"] == nil,
                "a caller who named one pattern must not be answered about a ring")
    }

    @Test("P2 wire: every wrong way to choose a gesture is refused by a sentence")
    func ringFormFork() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)

        // BOTH forms at once — honouring one would silently ignore the other.
        let both = await applyEffort(router, clipID: clipID, pattern: "flat",
                                     ["ringAngle": .number(45)])
        #expect(!both.ok)
        #expect(both.error?.contains("EITHER") == true)

        // The ring's DECORATIONS without the dot itself.
        for orphan in ["ringRadius": JSONValue.number(0.5), "ring": .array([.string("flat")])] {
            let response = await router.handle(ControlRequest(
                id: "o", command: "clip.applyEffortShape",
                params: ["clipId": .string(clipID), orphan.key: orphan.value]))
            #expect(!response.ok, "\(orphan.key) alone must be refused")
            #expect(response.error?.contains("ringAngle") == true)
        }

        // NEITHER — this used to be caught by the MCP schema, and is now the
        // app's job because `pattern` had to become optional for the ring to
        // exist. The sentence must name BOTH forms.
        let neither = await router.handle(ControlRequest(
            id: "n", command: "clip.applyEffortShape",
            params: ["clipId": .string(clipID)]))
        #expect(!neither.ok)
        #expect(neither.error?.contains("pattern") == true)
        #expect(neither.error?.contains("ringAngle") == true)
        print("[measured] P2 wire fork: both=\(both.error ?? "") | neither=\(neither.error ?? "")")

        // POSITIVE CONTROL: exactly one form, and it goes through.
        #expect(await applyRing(router, clipID: clipID, degrees: 45).ok)
        #expect(await applyEffort(router, clipID: clipID, pattern: "flat").ok)
    }

    @Test("P2 wire: out-of-range and unknown ring values are refused, never clamped")
    func ringFormBoundsAndUnknownIDs() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)

        let tooFar = await applyRing(router, clipID: clipID, degrees: 4500)
        #expect(!tooFar.ok, "DAWCore wraps any angle; the WIRE bounds it so a typo is a sentence")
        #expect(tooFar.error?.contains("ringAngle") == true)

        let tooWide = await applyRing(router, clipID: clipID, degrees: 0,
                                      ["ringRadius": .number(1.5)])
        #expect(!tooWide.ok)

        let unknown = await applyRing(router, clipID: clipID, degrees: 0,
                                      ["ring": .array([.string("flat"), .string("airRunsOut")])])
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("airRunsOut") == true)
        #expect(unknown.error?.contains("subToneEntry") == true, "it must name the valid ones")

        let empty = await applyRing(router, clipID: clipID, degrees: 0, ["ring": .array([])])
        #expect(!empty.ok)

        let notStrings = await applyRing(router, clipID: clipID, degrees: 0,
                                         ["ring": .array([.number(3)])])
        #expect(!notStrings.ok)

        // POSITIVE CONTROLS: the exact boundaries are LEGAL, and a custom ring
        // with duplicates is legal too (that is how a self-blend is stated).
        #expect(await applyRing(router, clipID: clipID, degrees: 360,
                                ["ringRadius": .number(0)]).ok)
        let dupes = await applyRing(router, clipID: clipID, degrees: 90,
                                    ["ring": .array([.string("lateBloom"),
                                                     .string("lateBloom")])])
        #expect(dupes.ok)
        #expect((dupes.result?["ring"]?["patternIds"]?.arrayValue ?? []).count == 2)
    }

    @Test("P2 wire: the ring keys are on the unknown-key list, so a typo is caught")
    func ringKeysAreOnTheAcceptedList() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)
        // A near-miss on each new key must be refused rather than ignored — the
        // silent-default failure this round exists to end.
        for typo in ["ringangle", "ringRadious", "rings"] {
            let response = await router.handle(ControlRequest(
                id: "t", command: "clip.applyEffortShape",
                params: ["clipId": .string(clipID), "ringAngle": .number(45),
                         typo: .number(1)]))
            #expect(!response.ok, "'\(typo)' must be refused")
            #expect(response.error?.contains(typo) == true)
        }
    }

    // MARK: - Breath pad P3 — the dot's PATH on the wire

    @Test("P3 wire: a drifting dot shapes the clip and reports where it travelled")
    func pathFormRoundTrips() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)
        // ⚠️ scaleBeats 16, not 4: this fixture is 4 notes across 12 beats, so
        // the dot is sampled 0.25×/beat and a faster path would (correctly) come
        // back flagged `outrunsNotes`. The fixture is chosen so the round trip
        // is what is under test, not the aliasing warning — which has its own.
        let response = await applyRing(router, clipID: clipID, degrees: 157.5,
                                       ["path": .string("drift"),
                                        "pathSeed": .number(2_024),
                                        "scaleBeats": .number(16),
                                        "angleSwing": .number(45)])
        #expect(response.ok)
        let path = try #require(response.result?["path"]?.objectValue,
                                "a moving dot must be answered with a path report")
        let peaks = lanePoints(response, type: "cc", controller: 11)
            .compactMap { $0["value"]?.doubleValue }
        print("[measured] P3 wire drift: \(path); distinct CC \(Set(peaks).count)")

        #expect(path["pathId"]?.stringValue == "drift")
        #expect(path["seed"]?.doubleValue == 2_024)
        #expect(path["moved"]?.boolValue == true)
        #expect(path["outrunsNotes"]?.boolValue == false)
        #expect((path["angleSweepDegrees"]?.doubleValue ?? 0) > 1)
        #expect((path["patternIds"]?.arrayValue ?? []).count >= 2)
        // ⭐ THE ONE THAT CATCHES AN INERT PATH. P2's dot at this angle writes a
        // FLAT arc (the hairpins cancel to a constant 0.625 ⇒ every note peaks
        // at CC 101). If the drift never reached the lane, this would still be
        // one distinct value.
        #expect(Set(peaks).count > 1,
                "the drift wrote the same flat lane a parked dot writes — it never reached the lane")

        // The ORIGIN is what `ring` reports, not wherever the dot wandered to.
        let ring = try #require(response.result?["ring"]?.objectValue)
        #expect(ring["angleDegrees"]?.doubleValue == 157.5)

        // A FIXED path carries NO path report: a caller whose dot did not move
        // must not be answered about travel.
        let still = await applyRing(router, clipID: clipID, degrees: 157.5,
                                    ["path": .string("fixed")])
        #expect(still.ok)
        #expect(still.result?["path"] == nil)
    }

    @Test("P3 wire: the same seed reproduces its lane; a different seed does not")
    func pathSeedIsReadOnTheWire() async throws {
        let (router, _) = makeRouter()
        func lane(seed: Double) async throws -> [Double] {
            let clipID = try await effortClip(router)
            let response = await applyRing(router, clipID: clipID, degrees: 157.5,
                                           ["path": .string("drift"),
                                            "pathSeed": .number(seed),
                                            "scaleBeats": .number(4),
                                            "angleSwing": .number(22)])
            #expect(response.ok)
            return lanePoints(response, type: "cc", controller: 11)
                .compactMap { $0["value"]?.doubleValue }
        }
        let a = try await lane(seed: 7)
        #expect(try await lane(seed: 7) == a, "one seed did not reproduce its own lane")
        #expect(try await lane(seed: 8) != a, "the seed is threaded but never read")
        // The 32-bit cap is a REAL bound with a stated reason (a JSON number is
        // a double), so both sides of it are pinned.
        let clipID = try await effortClip(router)
        #expect(await applyRing(router, clipID: clipID, degrees: 0,
                                ["path": .string("drift"),
                                 "pathSeed": .number(4_294_967_295)]).ok)
        let tooBig = await applyRing(router, clipID: clipID, degrees: 0,
                                     ["path": .string("drift"),
                                      "pathSeed": .number(4_294_967_296)])
        #expect(!tooBig.ok)
        #expect(tooBig.error?.contains("pathSeed") == true)
    }

    @Test("P3 wire: a parameter belonging to another path is REFUSED, never ignored")
    func pathParametersAreScoped() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)

        // Orbit keys on a drift, and drift keys on an orbit. Accepting and
        // dropping either would be a call that succeeded and did something else.
        let orbitOnDrift = await applyRing(router, clipID: clipID, degrees: 0,
                                           ["path": .string("drift"),
                                            "revolutionBeats": .number(8)])
        #expect(!orbitOnDrift.ok)
        #expect(orbitOnDrift.error?.contains("revolutionBeats") == true)
        #expect(orbitOnDrift.error?.contains("orbit") == true, "it must name where the key belongs")

        let driftOnOrbit = await applyRing(router, clipID: clipID, degrees: 0,
                                           ["path": .string("orbit"),
                                            "momentum": .number(0.5)])
        #expect(!driftOnOrbit.ok)
        #expect(driftOnOrbit.error?.contains("momentum") == true)

        // Any moving-path key on a FIXED dot.
        let onFixed = await applyRing(router, clipID: clipID, degrees: 0,
                                      ["path": .string("fixed"), "pathSeed": .number(3)])
        #expect(!onFixed.ok)
        #expect(onFixed.error?.contains("pathSeed") == true)

        // A path parameter with no `path` at all.
        let noPath = await applyRing(router, clipID: clipID, degrees: 0,
                                     ["scaleBeats": .number(4)])
        #expect(!noPath.ok)
        #expect(noPath.error?.contains("path") == true)

        // A path on the single-pattern form — there is no dot to move.
        let onPattern = await applyEffort(router, clipID: clipID, pattern: "flat",
                                          ["path": .string("drift")])
        #expect(!onPattern.ok)
        #expect(onPattern.error?.contains("ringAngle") == true)

        // An unknown path name names the three valid ones.
        let unknown = await applyRing(router, clipID: clipID, degrees: 0,
                                      ["path": .string("wander")])
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("drift") == true)

        // POSITIVE CONTROLS: each key IS accepted on its own path, or the six
        // refusals above would prove only that the verb rejects everything.
        #expect(await applyRing(router, clipID: clipID, degrees: 0,
                                ["path": .string("orbit"),
                                 "revolutionBeats": .number(8),
                                 "pathDirection": .string("counterclockwise")]).ok)
        #expect(await applyRing(router, clipID: clipID, degrees: 0,
                                ["path": .string("drift"),
                                 "momentum": .number(0.5),
                                 "octaves": .number(3),
                                 "radiusSwing": .number(0.2)]).ok)
    }

    @Test("P3 wire: out-of-range path values are refused, never clamped")
    func pathBoundsAreRefusals() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)
        let bad: [(String, [String: JSONValue])] = [
            ("revolutionBeats", ["path": .string("orbit"), "revolutionBeats": .number(0.1)]),
            ("pathDirection", ["path": .string("orbit"),
                               "pathDirection": .string("widdershins")]),
            ("scaleBeats", ["path": .string("drift"), "scaleBeats": .number(0)]),
            ("octaves", ["path": .string("drift"), "octaves": .number(9)]),
            ("momentum", ["path": .string("drift"), "momentum": .number(1.5)]),
            ("angleSwing", ["path": .string("drift"), "angleSwing": .number(361)]),
            ("radiusSwing", ["path": .string("drift"), "radiusSwing": .number(-0.1)]),
        ]
        for (name, params) in bad {
            let response = await applyRing(router, clipID: clipID, degrees: 0, params)
            #expect(!response.ok, "'\(name)' out of range must be refused, not clamped")
            #expect(response.error?.contains(name) == true,
                    "the refusal must name '\(name)'; got \(response.error ?? "nil")")
        }
        // POSITIVE CONTROL on the boundaries themselves.
        #expect(await applyRing(router, clipID: clipID, degrees: 0,
                                ["path": .string("drift"), "scaleBeats": .number(0.25),
                                 "octaves": .number(8), "momentum": .number(0),
                                 "angleSwing": .number(0), "radiusSwing": .number(1)]).ok)
    }

    @Test("P3 wire: the path keys are on the unknown-key list, so a typo is caught")
    func pathKeysAreOnTheAcceptedList() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)
        for typo in ["pathseed", "revolutionbeats", "scaleBeat", "octave", "momentom",
                     "angleSwings", "radiusswing", "pathdirection"] {
            let response = await router.handle(ControlRequest(
                id: "t", command: "clip.applyEffortShape",
                params: ["clipId": .string(clipID), "ringAngle": .number(45),
                         typo: .number(1)]))
            #expect(!response.ok, "'\(typo)' must be refused")
            #expect(response.error?.contains(typo) == true)
        }
    }

    /// ⭐ THE PARITY GATE the design asks for (§12 item 3), widened to all THREE
    /// places a param name is written: the verb's accepted key list, the MCP
    /// tool's zod schema, and the Copilot catalog's JSON Schema.
    ///
    /// This is the only mechanical defence against them drifting apart, and the
    /// drift is SILENT in the direction that matters — a key the app accepts but
    /// a schema omits never reaches the app at all. The design only asks for the
    /// first two; the catalog was added because it is hand-written and its own
    /// suite pins only the ENTRY COUNT and the command set, so a mistyped PARAM
    /// there costs the in-app copilot a capability with nothing turning red.
    ///
    /// ⚠️ It reads the TypeScript source rather than the built bundle, because
    /// the bundle is generated and a stale one would make this pass on yesterday
    /// 's schema. If the file cannot be found the test FAILS rather than skips:
    /// a parity gate that quietly does nothing is the defect it exists to catch.
    @Test("P3+P4 wire: every pad key the verb accepts is in the MCP schema AND the Copilot catalog")
    func wireAndSchemaKeySetsAgree() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DAWControlTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let serverTS = root.appendingPathComponent("mcp-server/src/server.ts")
        let source = try String(contentsOf: serverTS, encoding: .utf8)
        // Narrow to the tool's own registration so a same-named key on another
        // tool cannot satisfy this.
        let start = try #require(source.range(of: "\"clip_apply_effort_shape\""))
        let end = try #require(source.range(of: "async ({", range: start.upperBound..<source.endIndex))
        let schema = String(source[start.upperBound..<end.lowerBound])

        // ⚠️ The probe is `key: z`, NOT `key: z.` — the schema is formatted with
        // the first chained call on the NEXT line (`path: z\n  .enum(...)`), so
        // the stricter pattern matched nothing and reported every key missing.
        // A pattern that cannot match is not an absence.
        // ⚠️ P4's six are on the SAME list rather than in a second gate. A
        // parallel gate is a gate somebody forgets to extend, and the failure it
        // guards is the same one either way.
        let p3Keys = ["path", "pathSeed", "revolutionBeats", "pathDirection",
                      "scaleBeats", "octaves", "momentum", "angleSwing", "radiusSwing",
                      "airEnforced", "airCapacitySeconds", "airConsumptionExponent",
                      "airRefillSecondsPerSecond", "airMinBreathSeconds", "airReserveFraction"]
        for key in p3Keys {
            #expect(schema.contains("\(key): z"),
                    Comment(rawValue: "'\(key)' is accepted by the Swift verb but missing from the zod "
                    + "schema — the MCP tool would never be able to send it"))
        }
        // POSITIVE CONTROL: a key that is deliberately NOT in the schema must be
        // reported as absent, or `contains` is matching something else and every
        // line above passes vacuously.
        #expect(!schema.contains("airBudget: z"),
                "the probe matched a key that does not exist — it is not reading the schema")

        // --- THE THIRD SURFACE: the Copilot catalog --------------------------
        //
        // `CopilotToolCatalog` is the one place these params are written by hand
        // with NO mechanical pin: `CopilotCatalogTests` checks the entry COUNT
        // and the command set, so a mistyped or forgotten PARAM name is silent —
        // the in-app copilot simply never learns the key exists, which is
        // exactly the shape of failure this round was opened to end. Read it
        // structurally (not by grep): a missing key here cannot hide behind a
        // pattern that does not match.
        let entry = try #require(CopilotToolCatalog.v1.first { $0.command == "clip.applyEffortShape" },
                                 "the effort verb is not in the Copilot catalog at all")
        guard case let .object(root) = entry.schema,
              case let .object(properties)? = root["properties"] else {
            Issue.record("the catalog entry's schema is not an object with properties")
            return
        }
        for key in p3Keys {
            #expect(properties[key] != nil,
                    Comment(rawValue: "'\(key)' reaches the verb and the MCP schema but is missing "
                    + "from the Copilot catalog — the in-app copilot can never use it: "
                    + "\(properties.keys.sorted())"))
        }
        // POSITIVE CONTROL, again: the lookup must be able to come back empty.
        // ⚠️ `airBudget` is the sentinel BECAUSE it is not a key: P4 named its
        // six `airEnforced`/`airCapacitySeconds`/… deliberately so this control
        // keeps working. Do not "fix" the naming to match.
        #expect(properties["airBudget"] == nil,
                "the catalog probe found a key that does not exist — it is not reading properties")
    }

    // MARK: - Breath pad P4 — the air budget, over the wire

    /// The response's `air` block is the layer-1 legibility surface, and it must
    /// be there on EVERY call — a caller asking "why did this get quiet?" cannot
    /// be told to re-run with a flag first.
    @Test("P4 wire: the response ALWAYS carries an air report, enforced or not")
    func airReportIsAlwaysPresent() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)
        let plain = await applyEffort(router, clipID: clipID, pattern: "messaDiVoce")
        let air = try #require(plain.result?["air"]?.objectValue,
                               "an ordinary call came back with no air report at all")
        #expect(air["applied"]?.boolValue == false, "the DEFAULT is not enforced (user ruling)")
        #expect(air["enforced"]?.boolValue == false)
        #expect(air["notesConsidered"]?.doubleValue == 4)
        #expect(air["settings"]?["capacitySeconds"]?.doubleValue == 6)
        #expect(air["lowestAir"] != nil)
        // The per-phrase detail rides along only when something was constrained,
        // so an ordinary call is not buried in empty structure.
        print("[measured] P4 wire plain: constrained "
              + "\(air["constrainedNoteCount"]?.doubleValue ?? -1), lowestAir "
              + "\(air["lowestAir"]?.doubleValue ?? -1), phrases key "
              + "\(air["phrases"] == nil ? "absent" : "present")")
    }

    @Test("P4 wire: airEnforced changes the lane, and the response names every note it changed")
    func airEnforcedChangesTheLaneOverTheWire() async throws {
        let (router, _) = makeRouter()
        func peaks(_ response: ControlResponse) -> [Int] {
            let points = lanePoints(response, type: "cc", controller: 11)
            return (0..<4).map { k in
                let lo = Double(k) * 4, hi = lo + 4
                return points.filter {
                    ($0["beat"]?.doubleValue ?? -1) >= lo && ($0["beat"]?.doubleValue ?? -1) < hi
                }.compactMap { $0["value"]?.doubleValue }.map(Int.init).max() ?? -1
            }
        }
        let offClip = try await effortClip(router)
        let off = await applyEffort(router, clipID: offClip, pattern: "messaDiVoce",
                                    ["airEnforced": .bool(false)])
        let onClip = try await effortClip(router)
        let on = await applyEffort(router, clipID: onClip, pattern: "messaDiVoce",
                                   ["airEnforced": .bool(true)])
        #expect(off.ok && on.ok)
        let offPeaks = peaks(off), onPeaks = peaks(on)
        let air = try #require(on.result?["air"]?.objectValue)
        print("[measured] P4 wire: off \(offPeaks) → on \(onPeaks); constrained "
              + "\(air["constrainedNoteCount"]?.doubleValue ?? -1); maxAttenuationDb "
              + "\(air["maxAttenuationDb"]?.doubleValue ?? -1)")
        #expect(onPeaks != offPeaks, "airEnforced=true wrote the same lane as false")
        #expect((air["constrainedNoteCount"]?.doubleValue ?? 0) > 0)

        // ⭐ THE NAMING. Every constrained note carries the two efforts side by
        // side — the field pair that makes the change legible — plus the exact
        // CC integers, which involve no assumption about how CC 11 is read.
        let phrases = try #require(air["phrases"]?.arrayValue,
                                   "the budget constrained notes and shipped no per-phrase detail")
        let notes = phrases.flatMap { $0["constrainedNotes"]?.arrayValue ?? [] }
        #expect(!notes.isEmpty)
        // ⚠️ THE PER-NOTE CONTRACT IS `<=` ON THE CC PAIR, NOT `<`. The report
        // filters on the MODEL's `effortAllowed < effortRequested`; the lane is
        // CC integers, so a note constrained by less than one CC step ships with
        // both integers equal and 0.0 dB. That is reachable — DAWCore's
        // `aNoteConstrainedByLessThanOneCCStepIsStillNamed` constructs it — and
        // an earlier version of this loop asserted `<` for every note, which was
        // green only because this fixture exhausts hard. The strict claim
        // belongs to the WHOLE LIST, below, not to each element.
        for note in notes {
            #expect(note["noteId"]?.stringValue != nil)
            let asked = try #require(note["effortRequested"]?.doubleValue)
            let got = try #require(note["effortAllowed"]?.doubleValue)
            #expect(got < asked, "a note is listed as constrained and lost nothing")
            #expect(try #require(note["peakCCAllowed"]?.doubleValue)
                    <= #require(note["peakCCRequested"]?.doubleValue))
            #expect(try #require(note["peakCCAllowed"]?.doubleValue) >= 1,
                    "the wire reported a silenced note — §9.6 forbids it")
            #expect(try #require(note["attenuationDb"]?.doubleValue) <= 0)
            #expect(note["shaped"]?.boolValue == true)
        }
        // And this fixture DOES exhaust, so at least one note must be audibly
        // down on the wire — without this the loop above would pass on a list of
        // no-ops.
        #expect(notes.contains {
            ($0["peakCCAllowed"]?.doubleValue ?? 0) < ($0["peakCCRequested"]?.doubleValue ?? 0)
                && ($0["attenuationDb"]?.doubleValue ?? 0) < -1
        }, "every constrained note on the wire lost less than one CC step")
        // And the breath classification is on the wire as a NAMED kind, not as a
        // nullable beat that conflates "first phrase" with "no time to breathe".
        #expect(phrases.first?["breath"]?["kind"]?.stringValue == "none")
        #expect(on.result?["warnings"]?.arrayValue?.contains {
            $0.stringValue?.contains("air enforcement changed") == true
        } == true)
    }

    @Test("P4 wire: an out-of-range air value is REFUSED, and airEnforced must be a bool")
    func airBoundsAreRefusals() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)
        let bad: [(String, JSONValue)] = [
            ("airCapacitySeconds", .number(0)),
            ("airCapacitySeconds", .number(100_000)),
            ("airConsumptionExponent", .number(-1)),
            ("airRefillSecondsPerSecond", .number(-0.5)),
            ("airMinBreathSeconds", .number(120)),
            ("airReserveFraction", .number(1.5)),
        ]
        for (key, value) in bad {
            let response = await applyEffort(router, clipID: clipID, pattern: "flat", [key: value])
            #expect(!response.ok, "'\(key)' out of range must be refused, not clamped")
            #expect(response.error?.contains(key) == true,
                    Comment(rawValue: "the refusal must name '\(key)': \(response.error ?? "nil")"))
        }
        let notABool = await applyEffort(router, clipID: clipID, pattern: "flat",
                                         ["airEnforced": .string("yes")])
        #expect(!notABool.ok)
        #expect(notABool.error?.contains("airEnforced") == true)
        // POSITIVE CONTROL on the boundaries themselves — every refusal above
        // must be about the VALUE, not about the key being unwelcome.
        #expect(await applyEffort(router, clipID: clipID, pattern: "flat", [
            "airEnforced": .bool(true), "airCapacitySeconds": .number(0.25),
            "airConsumptionExponent": .number(0), "airRefillSecondsPerSecond": .number(0),
            "airMinBreathSeconds": .number(0), "airReserveFraction": .number(1)]).ok)
    }

    @Test("P4 wire: the air keys are on the accepted-key list, so a typo is caught not ignored")
    func airKeysAreOnTheAcceptedList() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)
        for typo in ["airenforced", "airCapacity", "capacitySeconds", "enforced",
                     "airReserve", "airRefill", "referenceEffort"] {
            let response = await applyEffort(router, clipID: clipID, pattern: "flat",
                                             [typo: .number(1)])
            #expect(!response.ok, "'\(typo)' must be refused")
            #expect(response.error?.contains(typo) == true)
        }
        // ⚠️ `referenceEffort` above is in the list on purpose: design §9.1 names
        // it and P4 deliberately does NOT ship it (it is algebraically the same
        // axis as airCapacitySeconds). A caller who reads the design and tries it
        // gets a refusal listing the real keys, not a silently ignored parameter.
    }

    // MARK: - Breath pad P5: the parse -> forward segment

    /// ⛔⛔ **THE SEGMENT NO OTHER P5 GATE COULD SEE.** P5's Swift coverage was
    /// store tests (which call `ProjectStore.applyEffortShape` directly and so
    /// never enter `Commands.swift`), MCP tests (mocked bridge, never reach
    /// Swift at all), a catalog gate (key SPELLING, not use) and
    /// `rejectUnknownKeys` (proves a key is not REFUSED — which is not that it
    /// is APPLIED). Nothing drove a humanisation key through `CommandRouter`
    /// and looked at the resulting lane.
    ///
    /// MEASURED, twice, not supposed. With the `humanisation:` forward DELETED
    /// from the ring-form `store.applyEffortShape` call — which compiles,
    /// because the parameter defaults to `.none` — the whole `DAWControlTests`
    /// target stayed green: **1036 tests, 92 suites, 0 failures**. With the
    /// PARSE key misspelled (`"tremorRateHZ"`), so a caller's `tremorRateHz` is
    /// accepted by `rejectUnknownKeys` and then never read, the same 1036/92
    /// stayed green. Accepted-but-ignored: the call succeeds, the response
    /// looks right, the default is silently used. That is this tree's
    /// characteristic failure mode and the standing law that a setter's return
    /// is not proof it took.
    ///
    /// Both forms are driven because two forwards are two ways to be half-wired
    /// — and the ring form is the one a pattern-only test never reaches.
    @Test("P5 wire: the humanisation keys reach the store and change the lane — driven through CommandRouter, once per form, because a forward that is silently missing looks exactly like a knob at its default")
    func humanisationKeysReachTheStoreOnBothForms() async throws {
        let (router, _) = makeRouter()

        // The track is a built-in `sampler` (see `effortClip`), so the tremor is
        // NOT suppressed here. On a `.soundBank` track it would be — deliberately
        // — and this test would then be asserting the suppression, not the wiring.
        for form in ["pattern", "ring"] {
            let clipID = try await effortClip(router)

            func apply(_ extra: [String: JSONValue]) async -> ControlResponse {
                form == "pattern"
                    ? await applyEffort(router, clipID: clipID, pattern: "hairpinCrescendo", extra)
                    : await applyRing(router, clipID: clipID, degrees: 40, extra)
            }

            let plain = await apply([:])
            #expect(plain.ok, "\(form): the baseline call must succeed")
            let plainCC = lanePoints(plain, type: "cc", controller: 11)
                .compactMap { $0["value"]?.doubleValue }
            #expect(!plainCC.isEmpty, "\(form): no CC11 points — the fixture, not the feature, is broken")

            // TREMOR: rides the contour, so it must move the CC 11 values.
            let tremored = await apply(["tremorDepth": .number(0.25),
                                        "tremorRateHz": .number(5)])
            #expect(tremored.ok, "\(form): \(tremored.error ?? "-")")
            let tremorCC = lanePoints(tremored, type: "cc", controller: 11)
                .compactMap { $0["value"]?.doubleValue }
            #expect(differingPoints(tremorCC, plainCC) > 0,
                    "\(form): tremorDepth changed NOTHING on the wire — the forward or the parse is missing")
            // The grid refines when the tremor is on, so there are strictly more
            // points too: a second, independent witness that the value took.
            #expect(tremorCC.count > plainCC.count,
                    "\(form): the expression grid did not refine, so tremorRateHz never reached the generator")

            // ⭐ The RATE must be read too, not just the depth. Two different
            // rates through the same call must not produce the same lane — this
            // is what a misspelled `"tremorRateHZ"` parse key breaks while
            // `tremorDepth` alone still looks perfectly wired.
            let slow = await apply(["tremorDepth": .number(0.25), "tremorRateHz": .number(1)])
            let slowCC = lanePoints(slow, type: "cc", controller: 11)
                .compactMap { $0["value"]?.doubleValue }
            #expect(differingPoints(slowCC, tremorCC) > 0,
                    "\(form): 1 Hz and 5 Hz produced identical lanes — tremorRateHz is not being read")

            // DRIFT: a separate knob on a separate path (it moves effort before
            // the air sweep), so it needs its own witness.
            let drifted = await apply(["driftDepth": .number(0.5),
                                       "driftScaleBeats": .number(2)])
            #expect(drifted.ok, "\(form): \(drifted.error ?? "-")")
            let driftedCC = lanePoints(drifted, type: "cc", controller: 11)
                .compactMap { $0["value"]?.doubleValue }
            #expect(differingPoints(driftedCC, plainCC) > 0,
                    "\(form): driftDepth changed NOTHING on the wire")

            print("[measured] \(form) form: plain \(plainCC.count) CC11 points, "
                  + "tremored \(tremorCC.count) (\(differingPoints(tremorCC, plainCC)) differ), "
                  + "1 Hz vs 5 Hz \(differingPoints(slowCC, tremorCC)) differ, "
                  + "drifted \(driftedCC.count) (\(differingPoints(driftedCC, plainCC)) differ)")
        }
    }

    /// How many CC points differ between two lanes, counting a length change as a
    /// difference. Returned as a NUMBER on purpose: this tree's readable-failure
    /// law (see `ZeroParamVerbRejectionTests`) is to assert on a derived quantity
    /// rather than on raw equality of long arrays, which prints both in full and
    /// leaves the reader to diff ~200 values by eye. Measured while planting:
    /// the raw form emitted four ~200-element dumps in one failure.
    private func differingPoints(_ a: [Double], _ b: [Double]) -> Int {
        if a.count != b.count { return max(a.count, b.count) }
        return zip(a, b).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }

    /// The null, at the wire boundary rather than in the store: mentioning the
    /// humanisation keys at their documented defaults must reproduce the lane of
    /// a call that never mentioned them. §13.5's property, proven on the surface
    /// an agent actually touches.
    @Test("P5 wire: the humanisation keys at their defaults reproduce the untouched lane exactly")
    func humanisationDefaultsAreInertOnTheWire() async throws {
        let (router, _) = makeRouter()
        let clipID = try await effortClip(router)

        let untouched = await applyEffort(router, clipID: clipID, pattern: "hairpinCrescendo")
        let defaults = await applyEffort(
            router, clipID: clipID, pattern: "hairpinCrescendo",
            ["driftDepth": .number(0), "tremorDepth": .number(0),
             "driftScaleBeats": .number(8), "driftOctaves": .number(4),
             "tremorRateHz": .number(4.565), "tremorEffortExponent": .number(1)])
        #expect(defaults.ok, "\(defaults.error ?? "-")")
        let defaultCC = lanePoints(defaults, type: "cc", controller: 11)
            .compactMap { $0["value"]?.doubleValue }
        let untouchedCC = lanePoints(untouched, type: "cc", controller: 11)
            .compactMap { $0["value"]?.doubleValue }
        #expect(!untouchedCC.isEmpty, "no CC11 points — the fixture, not the feature, is broken")
        #expect(differingPoints(defaultCC, untouchedCC) == 0,
                "the documented defaults moved the CC11 lane, so they are not the null")
        let defaultBend = lanePoints(defaults, type: "pitchBend")
            .compactMap { $0["value"]?.doubleValue }
        let untouchedBend = lanePoints(untouched, type: "pitchBend")
            .compactMap { $0["value"]?.doubleValue }
        #expect(differingPoints(defaultBend, untouchedBend) == 0,
                "the documented defaults moved the bend lane")
    }
}
