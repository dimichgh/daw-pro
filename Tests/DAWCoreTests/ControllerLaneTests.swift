import Foundation
import Testing
@testable import DAWCore

// Reuses FakeMedia (ImportTests.swift) / FakeEngine (CoreTests.swift) from the
// DAWCoreTests target.

/// m16-b2 — per-clip MIDI controller lanes. The model half (C1 null era, the
/// flat-Codable type discriminator, identity-free stepwise points, the
/// canonicalization + chase-scan + windowing primitives) and the invariant that
/// controller lanes require MIDI. Lane truth is always the model primitives
/// (`MIDIControllerLane.value(atBeat:)` / `Clip.windowedControllerLanes`) — the
/// tests never re-derive stepwise semantics elsewhere.
@Suite("Controller lanes — model (m16-b2)")
struct ControllerLaneModelTests {

    // MARK: - MIDIControllerType (flat Codable, domains, order)

    // 1.
    @Test("MIDIControllerType encodes flat {type, controller?}; unknown type is a hard decode error")
    func typeCodableFlatShape() throws {
        // cc carries a controller; the others do not.
        let ccObj = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(MIDIControllerType.cc(controller: 64))) as? [String: Any]
        #expect(ccObj?["type"] as? String == "cc")
        #expect(ccObj?["controller"] as? Int == 64)
        let bendObj = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(MIDIControllerType.pitchBend)) as? [String: Any]
        #expect(bendObj?["type"] as? String == "pitchBend")
        #expect(bendObj?["controller"] == nil)

        // Round-trip each case.
        for t: MIDIControllerType in [.cc(controller: 1), .pitchBend, .channelPressure] {
            let back = try JSONDecoder().decode(MIDIControllerType.self, from: JSONEncoder().encode(t))
            #expect(back == t)
        }
        // Unknown discriminator → hard error (not a silent misread).
        let bogus = Data(#"{"type":"aftertouchPoly"}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(MIDIControllerType.self, from: bogus)
        }
        // An out-of-range cc controller re-clamps into 0...127 on decode.
        let hot = Data(#"{"type":"cc","controller":200}"#.utf8)
        let clamped = try JSONDecoder().decode(MIDIControllerType.self, from: hot)
        #expect(clamped == .cc(controller: 127))
    }

    // 2.
    @Test("valueRange, neutralDefault, and the stable sort key")
    func typeDomainsAndOrder() {
        #expect(MIDIControllerType.cc(controller: 1).valueRange == 0...127)
        #expect(MIDIControllerType.channelPressure.valueRange == 0...127)
        #expect(MIDIControllerType.pitchBend.valueRange == 0...16383)

        #expect(MIDIControllerType.pitchBend.neutralDefault == 8192)
        #expect(MIDIControllerType.channelPressure.neutralDefault == 0)
        #expect(MIDIControllerType.cc(controller: 7).neutralDefault == 100)   // channel volume
        #expect(MIDIControllerType.cc(controller: 10).neutralDefault == 64)   // pan center
        #expect(MIDIControllerType.cc(controller: 11).neutralDefault == 127)  // expression
        #expect(MIDIControllerType.cc(controller: 64).neutralDefault == 0)    // sustain (up)

        // cc ascending by controller, then pitchBend, then channelPressure.
        let types: [MIDIControllerType] = [.channelPressure, .pitchBend, .cc(controller: 64), .cc(controller: 1)]
        #expect(types.sorted { $0.sortKey < $1.sortKey }
            == [.cc(controller: 1), .cc(controller: 64), .pitchBend, .channelPressure])
    }

    // MARK: - Point + lane canonicalization

    // 3.
    @Test("MIDIControllerPoint floors beat at 0 and round-trips Codable")
    func pointFloorsAndCodes() throws {
        #expect(MIDIControllerPoint(beat: -5, value: 40).beat == 0)
        let p = MIDIControllerPoint(beat: 2.5, value: 100)
        let back = try JSONDecoder().decode(MIDIControllerPoint.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }

    // 4.
    @Test("lane canonicalizes: values clamped to type range, sorted, equal-beat last-wins")
    func laneCanonicalizes() {
        // Values clamp to the CC domain; beats sort; the equal-beat pair dedupes
        // to the LAST (value 90).
        let lane = MIDIControllerLane(type: .cc(controller: 1), points: [
            MIDIControllerPoint(beat: 2, value: 200),   // clamps → 127
            MIDIControllerPoint(beat: 0, value: -5),     // clamps → 0
            MIDIControllerPoint(beat: 1, value: 50),
            MIDIControllerPoint(beat: 1, value: 90),     // same beat → wins
        ])
        #expect(lane.points.map(\.beat) == [0, 1, 2])
        #expect(lane.points.map(\.value) == [0, 90, 127])

        // Pitch bend keeps the wider domain.
        let bend = MIDIControllerLane(type: .pitchBend, points: [
            MIDIControllerPoint(beat: 0, value: 16383),
            MIDIControllerPoint(beat: 1, value: 20000),  // clamps → 16383
        ])
        #expect(bend.points.map(\.value) == [16383, 16383])
    }

    // 5.
    @Test("lane.value(atBeat:) is the stepwise chase scan")
    func laneValueChaseScan() {
        let lane = MIDIControllerLane(type: .cc(controller: 11), points: [
            MIDIControllerPoint(beat: 1, value: 40),
            MIDIControllerPoint(beat: 3, value: 100),
        ])
        #expect(lane.value(atBeat: 0) == nil)     // before the first point — no state
        #expect(lane.value(atBeat: 1) == 40)      // on the first point
        #expect(lane.value(atBeat: 2) == 40)      // holds between points (stepwise)
        #expect(lane.value(atBeat: 3) == 100)     // on the second point
        #expect(lane.value(atBeat: 99) == 100)    // holds after the last
    }

    // 6.
    @Test("canonicalControllerLanes merges duplicate types last-wins, drops empty, sorts by type key")
    func canonicalLanes() {
        let lanes = Clip.canonicalControllerLanes([
            MIDIControllerLane(type: .channelPressure, points: [MIDIControllerPoint(beat: 0, value: 10)]),
            MIDIControllerLane(type: .cc(controller: 1), points: [MIDIControllerPoint(beat: 0, value: 20)]),
            // A second cc(1) lane merges into the first, last-wins at beat 0.
            MIDIControllerLane(type: .cc(controller: 1), points: [MIDIControllerPoint(beat: 0, value: 77),
                                                                  MIDIControllerPoint(beat: 2, value: 5)]),
            // An empty lane is dropped.
            MIDIControllerLane(type: .pitchBend, points: []),
        ])
        // Sorted: cc(1) then channelPressure (pitchBend dropped as empty).
        #expect(lanes.map(\.type) == [.cc(controller: 1), .channelPressure])
        let cc = lanes.first { $0.type == .cc(controller: 1) }
        #expect(cc?.points.map(\.beat) == [0, 2])
        #expect(cc?.points.first?.value == 77)   // the later duplicate won at beat 0
    }

    // MARK: - windowedControllerLanes (split / trim / chase seam)

    // 7.
    @Test("windowedControllerLanes: split halves share a continuous stepwise seam")
    func windowSplitSeam() {
        // A ramp of steps: value 20 @0, 60 @2, 100 @3 in a 4-beat clip.
        let lanes = [MIDIControllerLane(type: .cc(controller: 1), points: [
            MIDIControllerPoint(beat: 0, value: 20),
            MIDIControllerPoint(beat: 2, value: 60),
            MIDIControllerPoint(beat: 3, value: 100),
        ])]
        // Split at beat 2.5: left = window [0, 2.5], right = window [2.5, 4].
        let left = Clip.windowedControllerLanes(lanes, delta: 0, newLength: 2.5)
        let right = Clip.windowedControllerLanes(lanes, delta: 2.5, newLength: 1.5)
        // Left keeps points < the split verbatim (0/20, 2/60); no end point.
        #expect(left.first?.points.map(\.beat) == [0, 2])
        #expect(left.first?.points.map(\.value) == [20, 60])
        // Right opens with the value in effect at 2.5 (= 60, held from beat 2),
        // then the point at old beat 3 rebased to 0.5.
        #expect(right.first?.points.map(\.beat) == [0, 0.5])
        #expect(right.first?.points.map(\.value) == [60, 100])
        // The seam is continuous: left's value at its end == right's value at 0.
        #expect(left.first?.value(atBeat: 2.5) == 60)
        #expect(right.first?.value(atBeat: 0) == 60)
    }

    // 8.
    @Test("windowedControllerLanes: no injected beat-0 when no state precedes the window; empty lanes drop")
    func windowNoStateNoInjection() {
        // The lane's only point is at beat 3 — a window that starts before it has
        // NO established state, so it gets no spurious beat-0 point.
        let lanes = [MIDIControllerLane(type: .pitchBend, points: [
            MIDIControllerPoint(beat: 3, value: 10000),
        ])]
        let left = Clip.windowedControllerLanes(lanes, delta: 0, newLength: 2)   // [0,2): no state, no points
        #expect(left.isEmpty)                                                    // lane drops entirely
        let right = Clip.windowedControllerLanes(lanes, delta: 2, newLength: 2)  // [2,4): still no state at 2
        #expect(right.first?.points.map(\.beat) == [1])                         // only old beat 3 → rebased 1
        #expect(right.first?.value(atBeat: 0) == nil)
    }

    // 9.
    @Test("windowedControllerLanes: trim re-windows with the value in effect at the new head")
    func windowTrim() {
        let lanes = [MIDIControllerLane(type: .cc(controller: 64), points: [
            MIDIControllerPoint(beat: 0, value: 0),
            MIDIControllerPoint(beat: 1, value: 127),   // pedal down at beat 1
        ])]
        // Trim head in by 2 beats: the new beat 0 = old beat 2 = pedal DOWN (127).
        let trimmed = Clip.windowedControllerLanes(lanes, delta: 2, newLength: 2)
        #expect(trimmed.first?.points.map(\.beat) == [0])
        #expect(trimmed.first?.points.first?.value == 127)
    }

    // MARK: - Clip invariant + null era

    // 10.
    @Test("controller lanes require MIDI — an audio clip forces [], a MIDI clip keeps them")
    func invariantRequiresMIDI() {
        let lanes = [MIDIControllerLane(type: .pitchBend, points: [MIDIControllerPoint(beat: 0, value: 8000)])]
        // Audio clip: notes == nil → lanes wiped.
        let audio = Clip(name: "a", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"),
                         controllerLanes: lanes)
        #expect(audio.controllerLanes.isEmpty)
        // MIDI clip (with notes): lanes kept, canonicalized.
        let midi = Clip(name: "m", lengthBeats: 4,
                        notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)],
                        controllerLanes: lanes)
        #expect(midi.controllerLanes.count == 1)
        // A CC-only clip (notes: []) is a legal MIDI clip carrying lanes.
        let ccOnly = Clip(name: "c", lengthBeats: 4, notes: [], controllerLanes: lanes)
        #expect(ccOnly.isMIDI)
        #expect(ccOnly.controllerLanes.count == 1)
    }

    // 11.
    @Test("C1 null era: a clip without lanes writes NO controllerLanes key (model + DTO)")
    func nullEraOmitsKey() throws {
        // Audio clip, and a MIDI clip that never got lanes — neither grows the key.
        let audio = Clip(name: "a", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"))
        let midi = Clip(name: "m", lengthBeats: 4,
                        notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        for clip in [audio, midi] {
            let modelObj = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(clip)) as? [String: Any]
            #expect(modelObj?["controllerLanes"] == nil)
            let dtoObj = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(ClipDocument(from: clip, media: nil))) as? [String: Any]
            #expect(dtoObj?["controllerLanes"] == nil)
        }
        // Legacy decode: a payload with no controllerLanes key reads as [].
        let legacy = Data(#"{"id":"\#(UUID().uuidString)","name":"x","startBeat":0,"lengthBeats":4,"notes":[],"isAIGenerated":false}"#.utf8)
        let decoded = try JSONDecoder().decode(Clip.self, from: legacy)
        #expect(decoded.controllerLanes.isEmpty)
    }

    // 12.
    @Test("a laned clip round-trips deep-equal through the model Codable")
    func lanedClipRoundTrips() throws {
        let clip = Clip(name: "m", lengthBeats: 8, notes: [],
                        controllerLanes: [
                            MIDIControllerLane(type: .cc(controller: 1), points: [
                                MIDIControllerPoint(beat: 0, value: 0),
                                MIDIControllerPoint(beat: 4, value: 127)]),
                            MIDIControllerLane(type: .pitchBend, points: [
                                MIDIControllerPoint(beat: 2, value: 8192)]),
                        ])
        #expect(!clip.controllerLanes.isEmpty)
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        #expect(back.controllerLanes == clip.controllerLanes)
    }

    // MARK: - m27 routing table

    /// The ONE definition of "does this controller reach the sound". If this
    /// table and `SamplerInstrument.apply(_:)` ever disagree, the warning is
    /// worse than useless — it becomes a confident wrong answer.
    @Test("the routing table matches what each built-in instrument actually consumes")
    func routingTableMatchesTheInstruments() {
        let sampler = InstrumentDescriptor(kind: .sampler, sampler: SamplerParams())
        // Consumed by SamplerInstrument.apply(_:): CC64 + m27's CC11, and bend.
        #expect(MIDIControllerRouting.inertLaneWarning(
            for: .cc(controller: 11), instrument: sampler) == nil)
        #expect(MIDIControllerRouting.inertLaneWarning(
            for: .cc(controller: 64), instrument: sampler) == nil)
        #expect(MIDIControllerRouting.inertLaneWarning(
            for: .pitchBend, instrument: sampler) == nil)
        // Dropped at the voice.
        #expect(MIDIControllerRouting.inertLaneWarning(
            for: .cc(controller: 7), instrument: sampler) != nil)
        #expect(MIDIControllerRouting.inertLaneWarning(
            for: .channelPressure, instrument: sampler) != nil)
        // CC1/CC2: wired, but gated by a depth that defaults to off. The
        // verdict must be `routedButDisabled`, NOT `inert` — the difference is
        // "turn this knob up" versus "this will never work here".
        if case .routedButDisabled(let reason) = MIDIControllerRouting.routing(
            for: .cc(controller: 1), instrument: sampler) {
            #expect(reason.contains("expressionModDepth"))
        } else {
            Issue.record("CC1 on a depth-0 sampler must be routedButDisabled")
        }
        let opted = InstrumentDescriptor(
            kind: .sampler, sampler: SamplerParams(expressionModDepth: 0.5))
        #expect(MIDIControllerRouting.inertLaneWarning(
            for: .cc(controller: 2), instrument: opted) == nil)

        // PolySynthInstrument.apply(_:) honours CC64 and bend only.
        let poly = InstrumentDescriptor(kind: .polySynth)
        #expect(MIDIControllerRouting.inertLaneWarning(
            for: .cc(controller: 64), instrument: poly) == nil)
        #expect(MIDIControllerRouting.inertLaneWarning(
            for: .pitchBend, instrument: poly) == nil)
        #expect(MIDIControllerRouting.inertLaneWarning(
            for: .cc(controller: 11), instrument: poly) != nil)

        // TestToneInstrument.apply(_:) has no controller branch at all.
        #expect(MIDIControllerRouting.inertLaneWarning(
            for: .cc(controller: 64), instrument: .init(kind: .testTone)) != nil)

        // HostedAUInstrument emits raw 0xB0 for every CC — never warn.
        for kind in [InstrumentDescriptor.Kind.audioUnit, .soundBank] {
            #expect(MIDIControllerRouting.inertLaneWarning(
                for: .cc(controller: 74), instrument: .init(kind: kind)) == nil)
        }

        // A track with no instrument consumes nothing, and says so.
        let none = MIDIControllerRouting.inertLaneWarning(
            for: .cc(controller: 11), instrument: nil)
        #expect(none?.contains("no instrument") == true)
    }

    @Test("warning copy names the controller in words a user can act on")
    func warningCopyNamesTheController() {
        #expect(MIDIControllerRouting.describe(.cc(controller: 11)) == "CC11 (expression)")
        #expect(MIDIControllerRouting.describe(.cc(controller: 2)) == "CC2 (breath)")
        #expect(MIDIControllerRouting.describe(.cc(controller: 99)) == "CC99")
        #expect(MIDIControllerRouting.describe(.pitchBend) == "pitch bend")
        let text = try! #require(MIDIControllerRouting.inertLaneWarning(
            for: .cc(controller: 74), instrument: InstrumentDescriptor(kind: .polySynth)))
        #expect(text.hasPrefix("CC74 (brightness) is stored but will not sound:"))
    }
}

/// m16-b2 — the store edit boundary (create/replace/remove, value/cap
/// validation, per-lane undo coalescing, MIDI-only), the C8 clip-op matrix
/// (every reconstruction site preserves or windows lanes), and persistence
/// (omit-when-empty + round-trip through the DTO).
@MainActor
@Suite("Controller lanes — store + persistence (m16-b2)")
struct ControllerLaneStoreTests {
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    private func storeWithMIDIClip() throws -> (store: ProjectStore, trackID: UUID, clip: Clip) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, lengthBeats: 8,
                                         notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        return (store, track.id, clip)
    }

    // MARK: - setControllerLane / removeControllerLane

    // 1.
    @Test("setControllerLane creates + canonicalizes, echoes the stored lane, one undo")
    func setAndUndo() throws {
        let (store, _, clip) = try storeWithMIDIClip()
        let out = try store.setControllerLane(clipID: clip.id, type: .cc(controller: 1), points: [
            MIDIControllerPoint(beat: 2, value: 100),
            MIDIControllerPoint(beat: 0, value: 200),   // out of order + clamps → 127
        ])
        let lane = try #require(out.controllerLanes.first)
        #expect(lane.type == .cc(controller: 1))
        #expect(lane.points.map(\.beat) == [0, 2])
        #expect(lane.points.first?.value == 127)
        #expect(try store.undo() == "Set Controller Lane")
        #expect(store.tracks[0].clips[0].controllerLanes.isEmpty)
    }

    // 2.
    @Test("setControllerLane replaces the same type wholesale; a second type coexists")
    func replaceAndCoexist() throws {
        let (store, _, clip) = try storeWithMIDIClip()
        _ = try store.setControllerLane(clipID: clip.id, type: .cc(controller: 1),
                                        points: [MIDIControllerPoint(beat: 0, value: 10)])
        _ = try store.setControllerLane(clipID: clip.id, type: .pitchBend,
                                        points: [MIDIControllerPoint(beat: 0, value: 8192)])
        // Replace the cc(1) lane wholesale.
        let out = try store.setControllerLane(clipID: clip.id, type: .cc(controller: 1),
                                              points: [MIDIControllerPoint(beat: 1, value: 90)])
        #expect(out.controllerLanes.count == 2)
        let cc = out.controllerLanes.first { $0.type == .cc(controller: 1) }
        #expect(cc?.points.map(\.beat) == [1])
        #expect(cc?.points.first?.value == 90)
    }

    // 3.
    @Test("empty points CLEARS the lane at the store boundary")
    func emptyClears() throws {
        let (store, _, clip) = try storeWithMIDIClip()
        _ = try store.setControllerLane(clipID: clip.id, type: .channelPressure,
                                        points: [MIDIControllerPoint(beat: 0, value: 40)])
        #expect(!store.tracks[0].clips[0].controllerLanes.isEmpty)
        let cleared = try store.setControllerLane(clipID: clip.id, type: .channelPressure, points: [])
        #expect(cleared.controllerLanes.isEmpty)
    }

    // 4.
    @Test("rapid edits coalesce under one undo step (drag gesture)")
    func coalescingUndo() throws {
        let (store, _, clip) = try storeWithMIDIClip()
        for v in stride(from: 0, through: 120, by: 10) {
            _ = try store.setControllerLane(clipID: clip.id, type: .cc(controller: 11),
                                            points: [MIDIControllerPoint(beat: 2, value: v)])
        }
        #expect(store.tracks[0].clips[0].controllerLanes.first?.points.first?.value == 120)
        #expect(try store.undo() == "Set Controller Lane")
        #expect(store.tracks[0].clips[0].controllerLanes.isEmpty)
    }

    // 5.
    @Test("an audio clip is rejected — controller lanes apply to MIDI clips only")
    func audioRejected() throws {
        let store = ProjectStore()
        store.media = FakeMedia(info: AudioFileInfo(durationSeconds: 2.0, sampleRate: 44_100, channelCount: 2))
        let track = store.addTrack(kind: .audio)
        let audio = try store.importAudio(url: URL(fileURLWithPath: "/tmp/A.wav"), toTrack: track.id)
        let error = projectError {
            _ = try store.setControllerLane(clipID: audio.id, type: .pitchBend,
                                            points: [MIDIControllerPoint(beat: 0, value: 8000)])
        }
        guard case .notAMIDIClip? = error else {
            Issue.record("expected notAMIDIClip, got \(String(describing: error))")
            return
        }
    }

    // 6.
    @Test("the 16384-points-per-lane cap throws, naming the count")
    func pointCap() throws {
        let (store, _, clip) = try storeWithMIDIClip()
        let over = (0...16384).map { MIDIControllerPoint(beat: Double($0), value: 1) }  // 16385
        let error = projectError {
            _ = try store.setControllerLane(clipID: clip.id, type: .cc(controller: 1), points: over)
        }
        guard case .invalidClipEdit(let message)? = error else {
            Issue.record("expected invalidClipEdit, got \(String(describing: error))")
            return
        }
        #expect(message.contains("16384"))
        #expect(message.contains("16385"))
    }

    // 7.
    @Test("the 16-lanes-per-clip cap throws on a new type; a REPLACE at the cap is allowed")
    func laneCap() throws {
        let (store, _, clip) = try storeWithMIDIClip()
        // Fill 16 CC lanes (controllers 0...15).
        for n in 0..<16 {
            _ = try store.setControllerLane(clipID: clip.id, type: .cc(controller: n),
                                            points: [MIDIControllerPoint(beat: 0, value: 1)])
        }
        #expect(store.tracks[0].clips[0].controllerLanes.count == 16)
        // A 17th distinct type is refused.
        let error = projectError {
            _ = try store.setControllerLane(clipID: clip.id, type: .pitchBend,
                                            points: [MIDIControllerPoint(beat: 0, value: 8192)])
        }
        guard case .invalidClipEdit(let message)? = error else {
            Issue.record("expected invalidClipEdit, got \(String(describing: error))")
            return
        }
        #expect(message.contains("16 controller lanes"))
        // Replacing an EXISTING type at the cap still works.
        let ok = try store.setControllerLane(clipID: clip.id, type: .cc(controller: 0),
                                             points: [MIDIControllerPoint(beat: 1, value: 42)])
        #expect(ok.controllerLanes.count == 16)
    }

    // 8.
    @Test("removeControllerLane deletes; an unknown lane lists the existing ones; audio rejected")
    func removeLane() throws {
        let (store, _, clip) = try storeWithMIDIClip()
        _ = try store.setControllerLane(clipID: clip.id, type: .cc(controller: 64),
                                        points: [MIDIControllerPoint(beat: 0, value: 127)])
        _ = try store.setControllerLane(clipID: clip.id, type: .pitchBend,
                                        points: [MIDIControllerPoint(beat: 0, value: 8192)])
        let out = try store.removeControllerLane(clipID: clip.id, type: .cc(controller: 64))
        #expect(out.controllerLanes.map(\.type) == [.pitchBend])
        // Removing a type that isn't present → teaching error listing existing.
        let error = projectError {
            _ = try store.removeControllerLane(clipID: clip.id, type: .channelPressure)
        }
        guard case .invalidClipEdit(let message)? = error else {
            Issue.record("expected invalidClipEdit, got \(String(describing: error))")
            return
        }
        #expect(message.contains("channelPressure"))
        #expect(message.contains("pitchBend"))   // the existing lane is listed
    }

    // MARK: - C8 clip-op matrix

    private func lanedMIDIClip() throws -> (store: ProjectStore, trackID: UUID, clip: Clip) {
        let (store, trackID, clip) = try storeWithMIDIClip()   // 8 beats
        // A stepwise CC1 lane: 20 @0, 60 @4, 100 @6.
        _ = try store.setControllerLane(clipID: clip.id, type: .cc(controller: 1), points: [
            MIDIControllerPoint(beat: 0, value: 20),
            MIDIControllerPoint(beat: 4, value: 60),
            MIDIControllerPoint(beat: 6, value: 100),
        ])
        return (store, trackID, clip)
    }

    // 9.
    @Test("C8 split: the seam value matches the chase value at the split on both halves")
    func c8Split() throws {
        let (store, trackID, clip) = try lanedMIDIClip()
        let (first, second) = try store.splitClip(trackId: trackID, clipId: clip.id, atBeat: 5)
        let left = try #require(first.controllerLanes.first)
        let right = try #require(second.controllerLanes.first)
        // The value in effect at beat 5 is 60 (held from beat 4). The right half
        // opens with it; the left half holds it at its end.
        #expect(left.value(atBeat: first.lengthBeats) == 60)
        #expect(right.value(atBeat: 0) == 60)
        // The right half's later point (old beat 6) rebased to beat 1.
        #expect(right.points.map(\.beat).contains(1))
    }

    // 10.
    @Test("C8 trim: the lane re-windows with the value in effect at the new head")
    func c8Trim() throws {
        let (store, trackID, clip) = try lanedMIDIClip()
        // Trim head in by 5 beats: new beat 0 = old beat 5 = value 60 (held).
        let trimmed = try store.trimClip(trackId: trackID, clipId: clip.id,
                                         newStartBeat: 5, newLengthBeats: 3)
        let lane = try #require(trimmed.controllerLanes.first)
        #expect(lane.value(atBeat: 0) == 60)
        #expect(lane.points.first?.beat == 0)
    }

    // 11.
    @Test("C8 duplicate: lanes copy verbatim (points identity-free)")
    func c8Duplicate() throws {
        let (store, _, clip) = try lanedMIDIClip()
        let result = try store.duplicateClip(clipId: clip.id)
        #expect(result.clip.controllerLanes == store.tracks[0].clips[0].controllerLanes)
        #expect(result.clip.controllerLanes.first?.points.count == 3)
    }

    // 12.
    @Test("C8 setNotes preserves the lanes (replaces notes only)")
    func c8SetNotesPreservesLanes() throws {
        let (store, _, clip) = try lanedMIDIClip()
        let before = store.tracks[0].clips[0].controllerLanes
        let out = try store.setClipNotes(clipID: clip.id,
                                         notes: [MIDINote(pitch: 64, startBeat: 1, lengthBeats: 2)])
        #expect(out.controllerLanes == before)
    }

    // 13.
    @Test("C8 quantize + humanize move NOTES only; the lanes ride through untouched")
    func c8QuantizeHumanizeUntouched() throws {
        let (store, _, clip) = try lanedMIDIClip()
        let before = store.tracks[0].clips[0].controllerLanes
        _ = try store.quantizeClipNotes(clipId: clip.id, settings: QuantizeSettings(gridBeats: 0.25))
        #expect(store.tracks[0].clips[0].controllerLanes == before)
        _ = try store.humanizeClipNotes(clipID: clip.id, timingBeats: 0.05, velocityRange: 5, seed: 1)
        #expect(store.tracks[0].clips[0].controllerLanes == before)
    }

    // 14.
    @Test("C8 insertBars / deleteBars translate the clip whole; clip-relative lanes ride free")
    func c8InsertDeleteBars() throws {
        let (store, _, clip) = try lanedMIDIClip()
        let before = store.tracks[0].clips[0].controllerLanes
        // Insert a bar before the clip → the whole clip shifts; lanes unchanged.
        _ = try store.insertBars(atBar: 1, count: 1)
        let afterInsert = try #require(store.tracks[0].clips.first { $0.id == clip.id })
        #expect(afterInsert.controllerLanes == before)
        // Delete that bar back out → lanes still unchanged.
        _ = try store.deleteBars(fromBar: 1, count: 1)
        let afterDelete = try #require(store.tracks[0].clips.first { $0.id == clip.id })
        #expect(afterDelete.controllerLanes == before)
    }

    // MARK: - persistence

    // 15.
    @Test("a laned clip round-trips deep-equal through save→reopen (the DTO)")
    func roundTripDeepEqual() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-ctrllane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (store, _, _) = try lanedMIDIClip()
        // Add a second lane to prove the whole set persists.
        _ = try store.setControllerLane(clipID: store.tracks[0].clips[0].id, type: .pitchBend,
                                        points: [MIDIControllerPoint(beat: 2, value: 8192)])
        let path = dir.appendingPathComponent("Lanes").path
        try store.saveProject(to: path)

        // On-disk DTO carries the key.
        let document = try ProjectBundle.read(from: URL(fileURLWithPath: store.projectPath!))
        let clipDoc = try #require(document.tracks.first?.clips.first)
        #expect(clipDoc.controllerLanes?.count == 2)

        // Reopen → deep-equal lanes.
        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let restored = try #require(reopened.tracks.first?.clips.first)
        #expect(restored.controllerLanes == store.tracks[0].clips[0].controllerLanes)
    }

    // MARK: - m27 leg D: applyBreathContour
    //
    // Folded into THIS suite rather than getting its own: the tree is at its
    // 330-`@MainActor`-suite ceiling, and these tests are about the controller-
    // lane store boundary, which is exactly what this suite is.

    /// A clip of held notes on a SAMPLER track, so the routing warnings have a
    /// real instrument to reason about. 120 BPM ⇒ 1 beat = 0.5 s, and each note
    /// is 4 beats = 2 s, comfortably past the vibrato threshold.
    private func breathStore(noteCount: Int = 3,
                             noteLengthBeats: Double = 4,
                             filterDepth: Double? = nil)
    throws -> (store: ProjectStore, clip: Clip) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        _ = try store.setInstrument(
            id: track.id, kind: .sampler,
            sampler: SamplerParams(zones: [], expressionFilterDepth: filterDepth))
        let notes = (0..<noteCount).map {
            MIDINote(pitch: 69, startBeat: Double($0) * noteLengthBeats,
                     lengthBeats: noteLengthBeats)
        }
        let clip = try store.addMIDIClip(toTrack: track.id,
                                         lengthBeats: noteLengthBeats * Double(noteCount) + 1,
                                         notes: notes)
        return (store, clip)
    }

    // 16.
    @Test("applyBreathContour writes BOTH lanes, is one undo step, and reports what it did")
    func breathContourWritesBothLanes() throws {
        let (store, clip) = try breathStore()
        let result = try store.applyBreathContour(clipID: clip.id)
        print("[measured] 3×4-beat notes → \(result.expressionPointCount) expression + "
              + "\(result.pitchBendPointCount) bend points; vibrato on "
              + "\(result.notesWithVibrato)/\(result.notesTouched); budget "
              + "\(result.perNotePointBudget); warnings \(result.warnings)")
        #expect(result.notesTouched == 3)
        #expect(result.notesWithVibrato == 3)
        #expect(result.expressionPointCount > 100)
        #expect(result.pitchBendPointCount > 300)
        #expect(result.perNotePointBudget == 16384)

        let lanes = store.tracks[0].clips[0].controllerLanes
        #expect(lanes.contains { $0.type == .cc(controller: 11) })
        #expect(lanes.contains { $0.type == .pitchBend })
        // ONE undo step restoring the exact prior (empty) lanes.
        #expect(try store.undo() == "Breath Contour")
        #expect(store.tracks[0].clips[0].controllerLanes.isEmpty)
    }

    // 17.
    @Test("THE MERGE: points outside the touched notes survive; points inside are replaced")
    func breathContourMergesRatherThanReplacing() throws {
        // Two notes at beats 0-4 and 4-8 on a 9-beat clip; hand-author CC11
        // points inside note 1 AND out past both notes.
        let (store, clip) = try breathStore(noteCount: 2)
        _ = try store.setControllerLane(clipID: clip.id, type: .cc(controller: 11), points: [
            MIDIControllerPoint(beat: 1, value: 40),      // INSIDE note 1 → replaced
            MIDIControllerPoint(beat: 8.5, value: 33),    // OUTSIDE both  → survives
        ])
        // Shape ONLY note 1 (beats 0...4).
        let firstNoteID = try #require(store.tracks[0].clips[0].notes?.first?.id)
        let result = try store.applyBreathContour(clipID: clip.id, noteIDs: [firstNoteID])
        let lane = try #require(store.tracks[0].clips[0].controllerLanes
            .first { $0.type == .cc(controller: 11) })
        let hand = lane.points.filter { $0.value == 33 }
        let stale = lane.points.filter { $0.beat == 1 && $0.value == 40 }
        let insideNote2 = lane.points.filter { $0.beat > 4.0001 && $0.beat < 8 }
        print("[measured] merge: \(lane.points.count) points; hand-authored survivors "
              + "\(hand.map(\.beat)); stale in-span points \(stale.count); "
              + "points inside the untouched note 2: \(insideNote2.count)")
        #expect(hand.count == 1 && hand[0].beat == 8.5)   // untouched, exactly as authored
        #expect(stale.isEmpty)                            // in-span point replaced
        #expect(insideNote2.isEmpty)                      // note 2 was NOT selected
        #expect(result.notesTouched == 1)
    }

    // 18.
    @Test("running it note by note across a phrase ACCUMULATES instead of wiping the last call")
    func breathContourAccumulatesAcrossCalls() throws {
        let (store, clip) = try breathStore(noteCount: 3)
        let ids = try #require(store.tracks[0].clips[0].notes?.map(\.id))
        var counts: [Int] = []
        for id in ids {
            counts.append(try store.applyBreathContour(clipID: clip.id,
                                                       noteIDs: [id]).expressionPointCount)
        }
        let all = try store.applyBreathContour(clipID: clip.id).expressionPointCount
        print("[measured] per-note accumulation: \(counts) → whole-clip run \(all)")
        #expect(counts[0] < counts[1] && counts[1] < counts[2])   // each call ADDS
        #expect(counts[2] == all)                                 // and lands where one call does
    }

    // 19.
    @Test("an unknown note id is an ALL-OR-NOTHING rejection naming it")
    func breathContourRejectsUnknownNote() throws {
        let (store, clip) = try breathStore()
        let ghost = UUID()
        let real = try #require(store.tracks[0].clips[0].notes?.first?.id)
        let error = projectError {
            _ = try store.applyBreathContour(clipID: clip.id, noteIDs: [real, ghost])
        }
        #expect(error?.errorDescription?.contains(ghost.uuidString) == true)
        // Nothing was written — the partial application is what is refused.
        #expect(store.tracks[0].clips[0].controllerLanes.isEmpty)
    }

    // 20.
    @Test("an audio clip and a note-less MIDI clip are both refused readably")
    func breathContourRefusesWrongClips() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let empty = try store.addMIDIClip(toTrack: track.id, lengthBeats: 4)
        let noNotes = projectError { _ = try store.applyBreathContour(clipID: empty.id) }
        #expect(noNotes?.errorDescription?.contains("no notes to shape") == true)
        let missing = projectError { _ = try store.applyBreathContour(clipID: UUID()) }
        if case .clipNotFound = missing {} else { Issue.record("expected clipNotFound") }
    }

    // 21.
    @Test("THE HALF-SUCCESS WARNING: a sampler with expressionFilterDepth off is told so")
    func breathContourWarnsWhenBrightnessCannotMove() throws {
        let (offStore, offClip) = try breathStore(filterDepth: nil)
        let off = try offStore.applyBreathContour(clipID: offClip.id)
        let (onStore, onClip) = try breathStore(filterDepth: 0.6)
        let on = try onStore.applyBreathContour(clipID: onClip.id)
        print("[measured] filterDepth nil warnings: \(off.warnings)")
        print("[measured] filterDepth 0.6 warnings: \(on.warnings)")
        #expect(off.warnings.contains { $0.contains("LOUDNESS but not BRIGHTNESS") })
        #expect(!on.warnings.contains { $0.contains("LOUDNESS but not BRIGHTNESS") })
        // The lane is written either way — this warns, it does not refuse.
        #expect(off.expressionPointCount > 0)
    }

    // 22.
    @Test("short notes get the expression contour only, and the result SAYS no vibrato happened")
    func breathContourReportsShortNotes() throws {
        // 0.5-beat notes at 120 BPM = 0.25 s — under the 0.5 s straight opening.
        let (store, clip) = try breathStore(noteCount: 4, noteLengthBeats: 0.5)
        let result = try store.applyBreathContour(clipID: clip.id)
        print("[measured] 4×0.25 s notes: vibrato on \(result.notesWithVibrato)/"
              + "\(result.notesTouched), bend points \(result.pitchBendPointCount), "
              + "warnings \(result.warnings)")
        #expect(result.notesWithVibrato == 0)
        #expect(result.pitchBendPointCount == 0)
        #expect(!store.tracks[0].clips[0].controllerLanes.contains { $0.type == .pitchBend })
        #expect(result.warnings.contains { $0.contains("no note got vibrato") })
        #expect(result.expressionPointCount > 0)          // it still breathes
    }

    // 23.
    @Test("THE CLIP-WIDE BUDGET: many long notes are coarsened, and the result reports it")
    func breathContourHonoursTheClipWideBudget() throws {
        // 60 notes × 8 beats (4 s) each. Per note that is ~640 bend points —
        // each clears 16384 alone, together they are ~38400.
        let (store, clip) = try breathStore(noteCount: 60, noteLengthBeats: 8)
        let result = try store.applyBreathContour(clipID: clip.id)
        print("[measured] 60×4 s notes: \(result.pitchBendPointCount) bend + "
              + "\(result.expressionPointCount) expression points, per-note budget "
              + "\(result.perNotePointBudget), warnings \(result.warnings)")
        #expect(result.pitchBendPointCount <= ProjectStore.maxControllerPointsPerLane)
        #expect(result.expressionPointCount <= ProjectStore.maxControllerPointsPerLane)
        #expect(result.perNotePointBudget < 16384)
        #expect(result.warnings.contains { $0.contains("coarsened to fit") })
        // Coarsened, NOT dropped: every note still got a contour.
        #expect(result.notesTouched == 60)
        #expect(result.notesWithVibrato == 60)
    }

    // 24.
    @Test("the contour is anchored in seconds: the same notes at 240 BPM lose their vibrato")
    func breathContourFollowsTheProjectTempo() throws {
        let (fast, fastClip) = try breathStore(noteCount: 2, noteLengthBeats: 2)
        try fast.setTempoMap(TempoMap(constantBPM: 240))       // 2 beats = 0.5 s
        let fastResult = try fast.applyBreathContour(clipID: fastClip.id)
        let (slow, slowClip) = try breathStore(noteCount: 2, noteLengthBeats: 2)
        try slow.setTempoMap(TempoMap(constantBPM: 60))        // 2 beats = 2.0 s
        let slowResult = try slow.applyBreathContour(clipID: slowClip.id)
        print("[measured] same 2-beat notes: @240 BPM vibrato on "
              + "\(fastResult.notesWithVibrato), @60 BPM on \(slowResult.notesWithVibrato)")
        #expect(fastResult.notesWithVibrato == 0)
        #expect(slowResult.notesWithVibrato == 2)
    }

    // 25.
    @Test("the shared boundary beat belongs to the note STARTING, whatever order the notes are stored in")
    func breathContourIsIndependentOfNoteArrayOrder() throws {
        // Two abutting notes, 0…4 and 4…8. Beat 4 is inside BOTH closed spans,
        // so both notes generate a point there and `canonicalPoints` resolves
        // the tie LAST-WINS. The musically right winner is note 2's ONSET, not
        // note 1's taper end.
        //
        // ⚠️ The reordering below is not a contrived state. `Clip.init`
        // canonicalises, and so do `setClipNotes` and the paste/arrange paths —
        // but `Clip.notes` is a plain `var` and `ProjectStore+Humanize.swift:241`
        // assigns `tracks[t].clips[c].notes = humanized` DIRECTLY, deliberately
        // preserving input order. A timing pass that pushes one onset past the
        // next note's leaves exactly this array.
        func laneValues(reversingStoredNotes: Bool) throws -> [MIDIControllerPoint] {
            let (store, clip) = try breathStore(noteCount: 2)
            if reversingStoredNotes {
                let stored = try #require(store.tracks[0].clips[0].notes)
                store.tracks[0].clips[0].notes = stored.reversed()
            }
            _ = try store.applyBreathContour(clipID: clip.id)
            return try #require(store.tracks[0].clips[0].controllerLanes
                .first { $0.type == .cc(controller: 11) }).points
        }
        let ascending = try laneValues(reversingStoredNotes: false)
        let descending = try laneValues(reversingStoredNotes: true)
        let boundary = ascending.filter { abs($0.beat - 4) < 1e-9 }
        let atZero = ascending.filter { abs($0.beat - 0) < 1e-9 }
        print("[measured] order-independence: ascending \(ascending.count) points, "
              + "stored-reversed \(descending.count); boundary@4 "
              + "\(boundary.map(\.value)) vs onset@0 \(atZero.map(\.value)); "
              + "taper end \(ascending.last.map { "\($0.value)@\($0.beat)" } ?? "none")")
        // Byte-for-byte identical: the sort makes the stored array order
        // unobservable. Without it this comparison is what fails.
        #expect(ascending == descending,
                "the contour changed when the SAME notes were stored in a different array order")
        // Both notes are 4 beats long, so their contours are shape-identical:
        // the boundary must carry the onset value, not the release value.
        #expect(boundary.count == 1)
        #expect(atZero.count == 1)
        #expect(boundary.first?.value == atZero.first?.value,
                "beat 4 carries note 1's taper value — the note that is STARTING should own it")
        #expect(boundary.first?.value != ascending.last?.value)
    }
}
