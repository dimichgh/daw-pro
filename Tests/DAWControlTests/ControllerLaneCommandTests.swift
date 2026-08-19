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
        let clip = try await store.importAudio(
            url: URL(fileURLWithPath: "/tmp/leg-d-fake.wav"), toTrack: track.id, atBeat: 0)
        let response = await applyBreath(router, clipID: clip.id.uuidString)
        #expect(!response.ok)
        #expect(response.error?.contains("clip.applyBreathContour") == true)
    }
}
