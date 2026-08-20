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

    // MARK: - Breath pad P1: applyEffortShape
    //
    // Folded into THIS suite for the reason leg D's tests were: the tree is at
    // its 330-`@MainActor`-suite ceiling, and this IS the controller-lane store
    // boundary. The PURE half (patterns, phrases, the effort hook) lives in the
    // non-`@MainActor` `EffortPatternTests`, which costs no slot.

    /// A sound-bank track — Apple's AUSampler hosting the stock GM bank, which
    /// is where the user's sax lives and the ONLY path the 2026-08-19
    /// measurements were taken on.
    private func soundBankStore(noteCount: Int = 3, noteLengthBeats: Double = 4)
    throws -> (store: ProjectStore, clip: Clip) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        _ = try store.setInstrument(id: track.id, kind: .soundBank,
                                    soundBank: SoundBankConfig(source: .generalMIDI, program: 66))
        let notes = (0..<noteCount).map {
            MIDINote(pitch: 69, startBeat: Double($0) * noteLengthBeats,
                     lengthBeats: noteLengthBeats)
        }
        let clip = try store.addMIDIClip(toTrack: track.id,
                                         lengthBeats: noteLengthBeats * Double(noteCount) + 1,
                                         notes: notes)
        return (store, clip)
    }

    private func expressionLane(_ store: ProjectStore) throws -> [MIDIControllerPoint] {
        try #require(store.tracks[0].clips[0].controllerLanes
            .first { $0.type == .cc(controller: 11) }).points
    }

    /// ⭐⭐ THE DISCRIMINATING TEST FOR THE WHOLE PHASE. A phrase-scoped hairpin
    /// must make notes at different points of the phrase come out at DIFFERENT
    /// levels — and this reads that off the STORED LANE POINTS, never off the
    /// options that were passed in. An effort model that computed a beautiful
    /// curve and then handed every note the same options would return success,
    /// write hundreds of points, and fail here.
    @Test("a phrase-scoped hairpin writes a DIFFERENT peak level per note, read off the lane")
    func effortShapeVariesAcrossThePhrase() throws {
        let (store, clip) = try breathStore(noteCount: 4)
        let pattern = try #require(EffortPattern.named("hairpinCrescendo"))
        let result = try store.applyEffortShape(clipID: clip.id, pattern: pattern)
        let lane = try expressionLane(store)

        // Peak CC inside each note's own 4-beat span.
        let peaks = (0..<4).map { i -> Int in
            let lo = Double(i) * 4, hi = lo + 4
            return lane.filter { $0.beat >= lo - 1e-9 && $0.beat <= hi + 1e-9 }
                .map(\.value).max() ?? -1
        }
        print("[measured] hairpinCrescendo per-note peak CC: \(peaks); effort "
              + "\(String(format: "%.3f", result.minEffort))…\(String(format: "%.3f", result.maxEffort)); "
              + "phrases \(result.phraseCount); warnings \(result.warnings.count)")
        #expect(peaks == peaks.sorted(), "a crescendo must not go down")
        #expect(Set(peaks).count == 4, "every note should sit at its own level")
        #expect(peaks[3] - peaks[0] > 20, "the hairpin barely moved: \(peaks)")
        #expect(result.scope == .phrase)
        #expect(result.phraseCount == 1, "four abutting notes are ONE phrase")
        #expect(result.maxEffort > result.minEffort)

        // THE MIRROR, as a positive control on the direction: the diminuendo
        // must produce the reversed ordering from the same notes.
        let (store2, clip2) = try breathStore(noteCount: 4)
        _ = try store2.applyEffortShape(
            clipID: clip2.id, pattern: try #require(EffortPattern.named("hairpinDiminuendo")))
        let lane2 = try expressionLane(store2)
        let peaks2 = (0..<4).map { i -> Int in
            let lo = Double(i) * 4, hi = lo + 4
            return lane2.filter { $0.beat >= lo - 1e-9 && $0.beat <= hi + 1e-9 }
                .map(\.value).max() ?? -1
        }
        print("[measured] hairpinDiminuendo per-note peak CC: \(peaks2)")
        #expect(peaks2 == peaks2.sorted().reversed())
    }

    /// A BREATH splits the phrase, so the hairpin restarts — the point of
    /// factoring the classifier out of humanize in the first place.
    @Test("a rest splits the phrase and the hairpin starts over")
    func effortShapeRestartsAtABreath() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        _ = try store.setInstrument(id: track.id, kind: .sampler, sampler: SamplerParams(zones: []))
        // Two two-note phrases separated by a 2-beat rest.
        let notes = [MIDINote(pitch: 69, startBeat: 0, lengthBeats: 4),
                     MIDINote(pitch: 69, startBeat: 4, lengthBeats: 4),
                     MIDINote(pitch: 69, startBeat: 10, lengthBeats: 4),
                     MIDINote(pitch: 69, startBeat: 14, lengthBeats: 4)]
        let clip = try store.addMIDIClip(toTrack: track.id, lengthBeats: 20, notes: notes)
        let result = try store.applyEffortShape(
            clipID: clip.id, pattern: try #require(EffortPattern.named("hairpinCrescendo")))
        let lane = try expressionLane(store)
        let peaks = [(0.0, 4.0), (4, 8), (10, 14), (14, 18)].map { span -> Int in
            lane.filter { $0.beat >= span.0 - 1e-9 && $0.beat <= span.1 + 1e-9 }
                .map(\.value).max() ?? -1
        }
        print("[measured] two phrases: peaks \(peaks); phraseCount \(result.phraseCount)")
        #expect(result.phraseCount == 2)
        #expect(peaks[0] < peaks[1], "phrase 1 grows")
        #expect(peaks[2] < peaks[3], "phrase 2 grows")
        #expect(peaks[2] < peaks[1], "the crescendo RESTARTS after the breath")
    }

    /// ⛔ THE MEASURED SOUND-BANK GATE. On a hosted AU, bend vibrato aliases in
    /// bounces, so it must not be authored — and the result must SAY so rather
    /// than reporting notes "with vibrato" that have none.
    @Test("on a sound-bank track vibrato is suppressed, reported as 0, and CC1 is named")
    func effortShapeSuppressesBendVibratoOnHostedAU() throws {
        let (store, clip) = try soundBankStore()
        let result = try store.applyEffortShape(
            clipID: clip.id, pattern: try #require(EffortPattern.named("messaDiVoce")))
        let bend = store.tracks[0].clips[0].controllerLanes.first { $0.type == .pitchBend }
        let deviations = (bend?.points ?? []).map { abs($0.value - 8192) }
        print("[measured] sound-bank: notesWithVibrato \(result.notesWithVibrato), "
              + "bend points \(bend?.points.count ?? 0), max |Δ| from centre "
              + "\(deviations.max() ?? 0) units; warnings:\n  - "
              + result.warnings.joined(separator: "\n  - "))
        #expect(result.notesWithVibrato == 0, "vibrato was suppressed — reporting it would be a lie")
        // The micro-sharpening still rides the bend lane: it is a seconds-scale
        // curve, far under the measured 5.86 Hz Nyquist, so it is safe.
        #expect((deviations.max() ?? 0) > 0, "micro-sharpening should survive the suppression")
        // 4 cents at ±2 semitones = 164 units; a real vibrato at ±12 cents would
        // reach ~490. This bound is what distinguishes the two.
        #expect((deviations.max() ?? 0) < 300, "that deviation is vibrato-sized, not sharpening-sized")
        #expect(result.warnings.contains { $0.contains("CC1") },
                "the warning must name the route that DOES work")
        #expect(result.warnings.contains { $0.contains("5.4 Hz") })
        // And no warning may promise brightness on this path.
        #expect(!result.warnings.contains { $0.lowercased().contains("expressionfilterdepth") },
                "a sound-bank track has no such switch — sending a user to look for it is worse than silence")
        #expect(result.warnings.contains { $0.contains("LOUDNESS only") })

        // POSITIVE CONTROL: the SAME call on a built-in sampler must keep its
        // vibrato, or the assertions above would pass on a build that had
        // simply broken vibrato everywhere.
        let (samplerStore, samplerClip) = try breathStore()
        let onSampler = try samplerStore.applyEffortShape(
            clipID: samplerClip.id, pattern: try #require(EffortPattern.named("messaDiVoce")))
        let samplerBend = samplerStore.tracks[0].clips[0].controllerLanes
            .first { $0.type == .pitchBend }
        let samplerDeviation = (samplerBend?.points ?? []).map { abs($0.value - 8192) }.max() ?? 0
        print("[measured] built-in sampler control: notesWithVibrato "
              + "\(onSampler.notesWithVibrato), max |Δ| \(samplerDeviation) units")
        #expect(onSampler.notesWithVibrato == 3)
        #expect(samplerDeviation > 300)
    }

    @Test("a note-scoped pattern reshapes the note; flat writes a flat lane; amount 0 warns")
    func effortShapeNoteScope() throws {
        // messaDiVoce peaks mid-note; leg D's own default peaks at 0.65.
        let (store, clip) = try breathStore(noteCount: 1, noteLengthBeats: 8)
        let messa = try #require(EffortPattern.named("messaDiVoce"))
        _ = try store.applyEffortShape(clipID: clip.id, pattern: messa)
        let lane = try expressionLane(store)
        let peakBeat = try #require(lane.max { $0.value < $1.value }).beat
        print("[measured] messaDiVoce peak lands at beat \(peakBeat) of 8 (leg D default = 5.2)")
        #expect(abs(peakBeat - 4) < 0.6, "a messa di voce peaks in the MIDDLE")

        // The identity pattern: a flat lane, and no swell at all.
        let (flatStore, flatClip) = try breathStore(noteCount: 1, noteLengthBeats: 8)
        _ = try flatStore.applyEffortShape(
            clipID: flatClip.id, pattern: try #require(EffortPattern.named("flat")))
        let flatLane = try expressionLane(flatStore)
        print("[measured] flat: \(flatLane.count) points, values \(Set(flatLane.map(\.value)).sorted())")
        #expect(Set(flatLane.map(\.value)).count == 1, "the identity pattern must not swell")

        // amount 0 is a valid no-op on the shaping axis AND says so.
        let (zeroStore, zeroClip) = try breathStore(noteCount: 1, noteLengthBeats: 8)
        let zero = try zeroStore.applyEffortShape(clipID: zeroClip.id, pattern: messa, amount: 0)
        print("[measured] amount 0 warnings: \(zero.warnings)")
        #expect(Set(try expressionLane(zeroStore).map(\.value)).count == 1)
        #expect(zero.warnings.contains { $0.contains("amount is 0") })
    }

    /// ⭐ THE INERT-PARAMETER GATE. `loudnessDepth`/`swellDepth` are PROVABLY
    /// dead on a note-scoped pattern — every note is at effort 1, so
    /// `BreathContour.scaled` returns its input untouched — and a caller who
    /// sets them there would otherwise get success, a written lane, and no
    /// effect: this tree's characteristic failure ("returns something that
    /// looks like a valid answer"). The parameter descriptions saying "a
    /// phrase-scoped shape" is mitigation, not a runtime signal.
    @Test("an EXPLICIT effort response on a note-scoped pattern warns that it did nothing")
    func effortShapeWarnsWhenTheResponseIsInert() throws {
        let messa = try #require(EffortPattern.named("messaDiVoce"))
        let strong = BreathContour.EffortResponse(loudnessDepth: 0.9, swellDepth: 0.9)

        // (a) Explicit response, note scope → warned AND provably inert.
        let (asked, askedClip) = try breathStore(noteCount: 1, noteLengthBeats: 8)
        let askedResult = try asked.applyEffortShape(clipID: askedClip.id, pattern: messa,
                                                     response: strong)
        // (b) The SAME call with no response at all — the lane must be
        //     IDENTICAL, which is what makes "it did nothing" a measurement
        //     rather than a claim about the code.
        let (plain, plainClip) = try breathStore(noteCount: 1, noteLengthBeats: 8)
        let plainResult = try plain.applyEffortShape(clipID: plainClip.id, pattern: messa)

        let askedLane = try expressionLane(asked)
        let plainLane = try expressionLane(plain)
        print("[measured] inert response: \(askedLane.count) vs \(plainLane.count) points, "
              + "identical = \(askedLane == plainLane); warnings \(askedResult.warnings)")
        #expect(askedLane == plainLane, "the response must be provably inert here")
        #expect(askedResult.warnings.contains { $0.contains("did NOTHING") })
        #expect(askedResult.warnings.contains { $0.contains("hairpinCrescendo") },
                "the warning must name the patterns that DO respond")

        // (c) NO warning when nothing was asked for — the default response is
        //     non-identity, so warning unconditionally would fire on EVERY
        //     ordinary note-scoped call and bury the real case.
        #expect(!plainResult.warnings.contains { $0.contains("did NOTHING") })

        // (d) POSITIVE CONTROL: the same explicit response on a PHRASE-scoped
        //     pattern is not inert, gets no warning, and visibly moves the lane.
        let (phrase, phraseClip) = try breathStore(noteCount: 4, noteLengthBeats: 4)
        let phraseResult = try phrase.applyEffortShape(
            clipID: phraseClip.id, pattern: try #require(EffortPattern.named("hairpinCrescendo")),
            response: strong)
        let (phrasePlain, phrasePlainClip) = try breathStore(noteCount: 4, noteLengthBeats: 4)
        _ = try phrasePlain.applyEffortShape(
            clipID: phrasePlainClip.id,
            pattern: try #require(EffortPattern.named("hairpinCrescendo")))
        print("[measured] phrase-scope control: identical = "
              + "\(try expressionLane(phrase) == (try expressionLane(phrasePlain))); "
              + "warnings \(phraseResult.warnings)")
        #expect(try expressionLane(phrase) != (try expressionLane(phrasePlain)),
                "on a phrase-scoped pattern the response REACHES the lane")
        #expect(!phraseResult.warnings.contains { $0.contains("did NOTHING") })
    }

    @Test("applyEffortShape is ONE undo step named for itself, and merges like leg D")
    func effortShapeUndoAndMerge() throws {
        let (store, clip) = try breathStore(noteCount: 2)
        // A hand-authored point OUTSIDE both notes must survive the write.
        _ = try store.setControllerLane(clipID: clip.id, type: .cc(controller: 11), points: [
            MIDIControllerPoint(beat: 8.5, value: 33),
        ])
        let firstNoteID = try #require(store.tracks[0].clips[0].notes?.first?.id)
        let result = try store.applyEffortShape(
            clipID: clip.id, noteIDs: [firstNoteID],
            pattern: try #require(EffortPattern.named("lateBloom")))
        let lane = try expressionLane(store)
        print("[measured] merge under effort shape: \(lane.count) points, "
              + "survivors at 8.5 \(lane.filter { $0.beat == 8.5 }.map(\.value)); "
              + "notesTouched \(result.notesTouched)")
        #expect(result.notesTouched == 1)
        #expect(lane.contains { $0.beat == 8.5 && $0.value == 33 },
                "a hand-authored point outside the touched note must survive")
        #expect(try store.undo() == "Effort Shape")
        #expect(try expressionLane(store).map(\.value) == [33])
    }

    /// Leg D's own honesty gap, closed by P1 and pinned here: a caller who turns
    /// vibrato off must not be told notes "got vibrato".
    @Test("applyBreathContour with vibratoDepthCents 0 reports 0 notes with vibrato")
    func breathContourZeroDepthReportsHonestly() throws {
        let (store, clip) = try breathStore()
        let result = try store.applyBreathContour(clipID: clip.id,
                                                  options: .init(vibratoDepthCents: 0))
        print("[measured] vibratoDepthCents 0: notesWithVibrato \(result.notesWithVibrato)/"
              + "\(result.notesTouched), bend points \(result.pitchBendPointCount), "
              + "warnings \(result.warnings)")
        #expect(result.notesWithVibrato == 0)
        // …and it must NOT claim the notes were too short. They are 2 s long.
        #expect(!result.warnings.contains { $0.contains("shorter than") })
        // POSITIVE CONTROL: with vibrato ON, the same notes report 3.
        let (control, controlClip) = try breathStore()
        #expect(try control.applyBreathContour(clipID: controlClip.id).notesWithVibrato == 3)
    }

    // MARK: - Breath pad P2: the ring, at the STORE boundary
    //
    // The pure weight/blend maths lives in the non-`@MainActor`
    // `EffortRingTests` (no suite slot). What can only be checked here is
    // whether the blend survives the projection onto leg D's parameterised
    // generator and comes out as the LANE the gesture describes.

    /// Applies a ring dot and returns the resulting expression lane.
    private func ringLane(noteCount: Int = 4,
                          noteLengthBeats: Double = 4,
                          ring: EffortRing = .standard,
                          degrees: Double,
                          radius: Double = 1,
                          amount: Double = 1)
    throws -> (points: [MIDIControllerPoint], result: EffortShapeApplication) {
        let (store, clip) = try breathStore(noteCount: noteCount,
                                            noteLengthBeats: noteLengthBeats)
        let result = try store.applyEffortShape(
            clipID: clip.id, ring: ring,
            angleRadians: EffortRing.radians(fromDegrees: degrees),
            radius: radius, amount: amount)
        return (try expressionLane(store), result)
    }

    /// The per-note peak CC on a 4-note, 4-beat-each clip — the number the
    /// phrase arc is actually made of.
    private func perNotePeaks(_ points: [MIDIControllerPoint],
                              noteCount: Int = 4,
                              noteLengthBeats: Double = 4) -> [Int] {
        (0..<noteCount).map { k in
            let lo = Double(k) * noteLengthBeats
            let hi = lo + noteLengthBeats
            return points.filter { $0.beat >= lo && $0.beat < hi }.map(\.value).max() ?? -1
        }
    }

    /// ⭐ THE STORE-LEVEL EXACT-REPRODUCTION GATE, and the reason P2 refactored
    /// P1's path instead of forking it: parking the dot on a pattern's own angle
    /// must write the SAME LANE, point for point, as naming that pattern. This
    /// is what makes "the single-pattern form is still valid" a fact rather
    /// than a promise.
    @Test("P2: the dot parked ON a pattern writes the identical lane to naming it")
    func ringAtAPatternAngleReproducesTheSinglePatternCall() throws {
        for (i, pattern) in EffortPattern.library.enumerated() {
            let (store, clip) = try breathStore(noteCount: 4)
            _ = try store.applyEffortShape(clipID: clip.id, pattern: pattern)
            let named = try expressionLane(store)

            let (dot, result) = try ringLane(degrees: Double(i) * 45)
            #expect(dot == named,
                    "\(pattern.id) at \(Double(i) * 45)° must be identical to naming it")
            #expect(result.patternID == pattern.id)
            #expect(result.scope == pattern.scope)
            // …and the ring report says so, with all the weight on that one.
            let report = try #require(result.ring)
            #expect(report.weights[i] == 1)
            #expect(report.weights.reduce(0, +) == 1)
            #expect(abs(report.angleDegrees - Double(i) * 45) < 1e-9)
        }
        // NEGATIVE CONTROL: the same comparison HALFWAY between two patterns
        // must FAIL to match either neighbour, or the equality above would hold
        // for a function that ignores the angle entirely.
        let (store, clip) = try breathStore(noteCount: 4)
        _ = try store.applyEffortShape(
            clipID: clip.id, pattern: try #require(EffortPattern.named("messaDiVoce")))
        let messa = try expressionLane(store)
        let (between, _) = try ringLane(degrees: 67.5)
        #expect(between != messa, "67.5° is not messaDiVoce and must not write its lane")
    }

    /// ⛔ THE EQUAL-POWER CATCHER, END TO END. A ring of eight copies of ONE
    /// pattern must write that pattern's lane at EVERY angle — including the
    /// midpoints, where `√0.5 + √0.5 ≈ 1.414` would inflate every level.
    /// `√w + √(1−w)` is exactly 1 at the pattern angles, so an angle sweep that
    /// skipped the midpoints would ship an equal-power blend green.
    @Test("P2: a ring of one pattern repeated writes that pattern's lane at EVERY angle")
    func selfBlendWritesTheIdenticalLaneEverywhere() throws {
        let source = try #require(EffortPattern.named("subToneEntry"))
        let (store, clip) = try breathStore(noteCount: 4)
        _ = try store.applyEffortShape(clipID: clip.id, pattern: source)
        let reference = try expressionLane(store)
        #expect(reference.count > 20, "fixture check: there IS a lane to compare")

        let uniform = EffortRing.uniform(source, count: 8)
        for degrees in stride(from: 0.0, to: 360.0, by: 22.5) {   // 22.5 = the midpoints
            let (lane, _) = try ringLane(ring: uniform, degrees: degrees)
            #expect(lane == reference, "self-blend at \(degrees)° drifted from the pattern")
        }
    }

    /// The measured discriminator P2 exists for: the two hairpins are ring
    /// NEIGHBOURS and exact mirrors, so their 0.5/0.5 blend is analytically
    /// CONSTANT at 0.625 — a phrase arc that cancels to a level.
    @Test("P2: the hairpin midpoint writes a FLAT phrase arc at CC 101, not the 119 sqrt gives")
    func hairpinMidpointIsFlatAtTheEqualGainLevel() throws {
        // 135° = hairpinCrescendo, 180° = hairpinDiminuendo ⇒ 157.5 is the seam.
        let (blend, blendResult) = try ringLane(degrees: 157.5)
        let peaks = perNotePeaks(blend)
        print("[measured] P2 hairpin midpoint: per-note peak CC \(peaks); "
              + "effort \(blendResult.minEffort)…\(blendResult.maxEffort); "
              + "warnings \(blendResult.warnings)")

        // ⛔ THE NUMBER, DERIVED not remembered. effort = 0.625 everywhere, and
        // `EffortResponse.loudnessDepth` is 0.55, so
        //     peak = round(127 × (1 − 0.55 × (1 − 0.625))) = round(100.8) = 101.
        // An equal-power blend would sit at 0.8839 ⇒ round(118.9) = 119, which
        // is 2.8 dB louder under CC 11's square law. Both are FLAT, so
        // flatness alone proves nothing — the level is the discriminator.
        #expect(peaks == [101, 101, 101, 101])
        #expect(abs(blendResult.minEffort - 0.625) < 1e-9)
        #expect(abs(blendResult.maxEffort - 0.625) < 1e-9)

        // TWO NEGATIVE CONTROLS: the parents themselves must still rise and fall.
        //
        // ⚠️ THE DIMINUENDO IS NOT THE CRESCENDO REVERSED, and I guessed that it
        // was. Four uniformly spaced notes sit at u = 0, ¼, ½, ¾ — there is no
        // sample at u = 1 — and `dim(u) == cresc(1 − u)`, so the diminuendo's
        // four samples are the crescendo evaluated at 1, ¾, ½, ¼, which is a
        // set the crescendo's own four never contain. Derived, then MEASURED to
        // agree: round(127 × (1 − 0.55 × (1 − dim(u)))) = 127, 119, 101, 82.
        // The two DO cross at u = ½ (both 101), which is the same 0.625 the
        // midpoint blend sits at, and that agreement is the cross-check.
        let (up, _) = try ringLane(degrees: 135)
        let (down, _) = try ringLane(degrees: 180)
        #expect(perNotePeaks(up) == [75, 82, 101, 119])
        #expect(perNotePeaks(down) == [127, 119, 101, 82])

        // P1's "produced almost no variation" warning is CORRECT here and must
        // fire: a flat blend really did vary nothing across the phrase.
        #expect(blendResult.warnings.contains { $0.contains("almost no variation") })
    }

    @Test("P2: ringRadius 0 is a true no-op, and its warning names the dot, not amount")
    func radiusZeroIsANoOpAndSaysWhichLeverIsDown() throws {
        // On a PHRASE-scoped dot, radius 0 leaves every note at effort 1 — which
        // is exactly what `amount: 0` does, and P1 documents that as "each note
        // still breathes; what is missing is the shape across the phrase".
        let (atCentre, centreResult) = try ringLane(degrees: 135, radius: 0)
        let (store, clip) = try breathStore(noteCount: 4)
        _ = try store.applyEffortShape(
            clipID: clip.id,
            pattern: try #require(EffortPattern.named("hairpinCrescendo")), amount: 0)
        #expect(atCentre == (try expressionLane(store)),
                "radius 0 and amount 0 are the same point on the same axis")
        #expect(centreResult.minEffort == 1 && centreResult.maxEffort == 1)

        // ⭐ AND THE SENTENCE NAMES THE RIGHT LEVER. Telling someone who dragged
        // the dot to the middle to "raise amount" sends them to a control they
        // never touched.
        print("[measured] P2 radius-0 warnings: \(centreResult.warnings)")
        #expect(centreResult.warnings.contains { $0.contains("ringRadius is 0") })
        #expect(!centreResult.warnings.contains { $0.contains("amount is 0") })
        // …and the single-pattern form still says "amount is 0", unchanged.
        let (_, plainZero) = try ringLane(degrees: 135, amount: 0)
        #expect(plainZero.warnings.contains { $0.contains("amount is 0") })
    }

    @Test("P2: radius and amount are one axis — only the product reaches the lane")
    func radiusAndAmountCompose() throws {
        let (half, _) = try ringLane(degrees: 135, radius: 0.5, amount: 1)
        let (other, _) = try ringLane(degrees: 135, radius: 1, amount: 0.5)
        #expect(half == other, "radius 0.5 × amount 1 must equal radius 1 × amount 0.5")
        // NEGATIVE CONTROL: a different product must land somewhere else.
        let (full, _) = try ringLane(degrees: 135, radius: 1, amount: 1)
        #expect(half != full)
        print("[measured] P2 r×s composition: half \(perNotePeaks(half)), full \(perNotePeaks(full))")
    }

    /// A dot between a NOTE gesture and a PHRASE gesture has to drive both
    /// axes at once — the thing a single pattern structurally cannot do.
    @Test("P2: a mixed-scope dot shapes the note AND the phrase, and reports the split")
    func mixedScopeDotDrivesBothAxes() throws {
        // 90° = lateBloom (note), 135° = hairpinCrescendo (phrase) ⇒ 112.5 is
        // an even mix of the two.
        let (mixed, result) = try ringLane(degrees: 112.5)
        let report = try #require(result.ring)
        print("[measured] P2 mixed dot: noteWeight \(report.noteWeight), "
              + "phraseWeight \(report.phraseWeight), effort "
              + "\(result.minEffort)…\(result.maxEffort), peaks \(perNotePeaks(mixed))")

        #expect(abs(report.noteWeight - 0.5) < 1e-12)
        #expect(abs(report.phraseWeight - 0.5) < 1e-12)
        // The PHRASE axis moved: the notes are not all at one effort.
        #expect(result.maxEffort - result.minEffort > 0.05)
        // …and the NOTE axis moved too — the lane differs from the pure phrase
        // gesture applied at the same phrase strength, which is what proves the
        // intra-note shape was blended rather than left alone.
        let (phraseOnly, _) = try ringLane(degrees: 135, radius: 0.5)
        #expect(mixed != phraseOnly)
        // Neither warning about a WHOLLY inert axis may fire on a mixed dot.
        #expect(!result.warnings.contains { $0.contains("amount is 0") })
    }

    @Test("P2: a custom ring is honoured, refused readably, and reported back")
    func customRingIsHonouredAndReported() throws {
        // Three patterns ⇒ 120° apart, so 120° must be the SECOND one exactly.
        let ring = try EffortRing.resolve(ids: ["flat", "sforzandoPiano", "terraced"])
        let (lane, result) = try ringLane(ring: ring, degrees: 120)
        let (store, clip) = try breathStore(noteCount: 4)
        _ = try store.applyEffortShape(
            clipID: clip.id, pattern: try #require(EffortPattern.named("sforzandoPiano")))
        #expect(lane == (try expressionLane(store)),
                "on a 3-ring, 120° IS the second pattern")
        let report = try #require(result.ring)
        #expect(report.patternIDs == ["flat", "sforzandoPiano", "terraced"])
        #expect(report.weights == [0, 1, 0])

        // The single-pattern form carries NO ring report — a caller who never
        // mentioned a ring must not be answered about one.
        let (plainStore, plainClip) = try breathStore(noteCount: 4)
        let plain = try plainStore.applyEffortShape(
            clipID: plainClip.id, pattern: try #require(EffortPattern.named("flat")))
        #expect(plain.ring == nil)
    }

    // MARK: - Breath pad P3: the dot PATH, at the STORE boundary
    //
    // The pure field maths (THE PAD LAW, the fBm, the hash) lives in the
    // non-`@MainActor` `BreathPadDeterminismTests` and costs no suite slot. What
    // can only be checked here is whether a MOVING dot reaches the LANE, and
    // whether a still one still writes exactly what P1 and P2 wrote.

    /// A drift wide enough to cross pattern boundaries on the default ring.
    private func driftPath(scaleBeats: Double = 8,
                           momentum: Double = 0.5,
                           angleSwingDegrees: Double = 90,
                           radiusSwing: Double = 0) -> DotPath {
        .drift(scaleBeats: scaleBeats, octaves: 4, momentum: momentum,
               angleSwingRadians: EffortRing.radians(fromDegrees: angleSwingDegrees),
               radiusSwing: radiusSwing)
    }

    /// ⭐ THE STRUCTURAL-IDENTITY GATE. A `.fixed` path must write the SAME
    /// LANE, point for point, as P2's pathless call — because it is the same
    /// code with a zero offset, not a parallel implementation that agrees.
    @Test("P3: a fixed path writes the identical lane to P2's pathless call")
    func fixedPathIsBitIdenticalToP2() throws {
        for degrees in [0.0, 45.0, 67.5, 157.5, 300.0] {
            let (reference, _) = try ringLane(degrees: degrees)
            let (store, clip) = try breathStore(noteCount: 4)
            let result = try store.applyEffortShape(
                clipID: clip.id, ring: .standard,
                angleRadians: EffortRing.radians(fromDegrees: degrees),
                radius: 1, path: .fixed, seed: 999)
            #expect(try expressionLane(store) == reference,
                    "a fixed path changed the lane at \(degrees)°")
            // …and it must not invent a path report for a dot that did not move.
            #expect(result.path == nil, "a fixed dot must not be reported as a path")
        }
    }

    /// ⭐⭐ THE DISCRIMINATING TEST FOR P3, read off the STORED LANE. A wandering
    /// dot must give notes at different beats DIFFERENT gestures. A path that
    /// computed a beautiful trajectory and then handed every note the same blend
    /// would return success, a full report, and an identical lane.
    @Test("P3: a drifting dot writes a DIFFERENT lane than a still one, and says where it went")
    func driftReachesTheLane() throws {
        let (still, _) = try ringLane(noteCount: 8, noteLengthBeats: 2, degrees: 45)
        let (store, clip) = try breathStore(noteCount: 8, noteLengthBeats: 2)
        let result = try store.applyEffortShape(
            clipID: clip.id, ring: .standard,
            angleRadians: EffortRing.radians(fromDegrees: 45),
            radius: 1, path: driftPath(), seed: 2_024)
        let moved = try expressionLane(store)
        #expect(moved != still, "the drift wrote the same lane as a parked dot — it is inert")

        let report = try #require(result.path, "a moving dot must report its path")
        #expect(report.pathID == "drift")
        #expect(report.seed == 2_024)
        #expect(report.moved)
        #expect(report.patternIDs.count >= 2,
                "a ±90° swing must touch more than one gesture on a 45°-spaced ring")
        #expect(!report.outrunsNotes)
        print("[measured] P3 store drift: sweep \(report.angleSweepDegrees)°, "
              + "patterns \(report.patternIDs), \(moved.count) points, "
              + "effort \(result.minEffort)…\(result.maxEffort)")
    }

    /// ⭐⭐⭐ CLIP-POSITION INVARIANCE — the test that catches a field fed a
    /// TIMELINE beat instead of a clip-relative one.
    ///
    /// This is the store half of the loop-invariance argument. Its other half is
    /// `BreathPadDeterminismTests.fieldIsPositionSensitive`, which proves the
    /// field's answer really does change with the beat — without that, this test
    /// would pass on a field that returned a constant, and the pair would prove
    /// nothing. The loop unroller rebuilds each cycle from clip data
    /// (`PlaybackGraph.swift:2923-2930`), so "the same clip beat gives the same
    /// dot" is exactly what makes cycle 5 sound like cycle 1.
    ///
    /// ⚠️ **It asserts on the VALUES, and on the beats only to 1e-9, and that is
    /// not a weakened assertion — it is the boundary of what P3 owns.** MEASURED
    /// while writing this: a lane written at clip start 128 has point beats
    /// differing in the last ulps (`0.08` vs `0.0800000000000125`) because leg
    /// D's generator converts beats→seconds→beats through the tempo map at
    /// ABSOLUTE positions. It is pre-existing and has nothing to do with the
    /// dot: a `.fixed` path shows the identical drift, and the control below
    /// asserts that so this tolerance can never quietly cover a real one.
    @Test("P3: moving the clip down the timeline does not change one lane VALUE")
    func clipPositionDoesNotChangeThePath() throws {
        func lane(clipStartBeat: Double, path: DotPath) throws -> [MIDIControllerPoint] {
            let (store, clip) = try breathStore(noteCount: 8, noteLengthBeats: 2)
            if clipStartBeat != 0 {
                _ = try store.moveClip(trackId: store.tracks[0].id, clipId: clip.id,
                                       toStartBeat: clipStartBeat)
            }
            #expect(store.tracks[0].clips[0].startBeat == clipStartBeat, "fixture check")
            _ = try store.applyEffortShape(
                clipID: clip.id, ring: .standard,
                angleRadians: EffortRing.radians(fromDegrees: 45),
                radius: 1, path: path, seed: 77)
            return try expressionLane(store)
        }
        // The tempo map is constant here, so nothing may legitimately move
        // except that round-trip: under a tempo RAMP a relocated clip would
        // differ for a reason that is not the field is.
        let atZero = try lane(clipStartBeat: 0, path: driftPath())
        #expect(atZero.count > 20, "fixture check: there IS a lane to compare")
        var worstBeatDrift = 0.0
        for start in [128.0, 512.5, 4_096.0] {
            let moved = try lane(clipStartBeat: start, path: driftPath())
            #expect(moved.count == atZero.count,
                    "the point COUNT changed when the clip moved to beat \(start)")
            for (i, point) in moved.enumerated() where i < atZero.count {
                #expect(point.value == atZero[i].value,
                        Comment(rawValue: "point \(i) changed VALUE (\(atZero[i].value) → \(point.value)) "
                        + "when the clip moved to beat \(start) — the field is being fed a "
                        + "TIMELINE beat, so a bounce from bar 33 would not match playing "
                        + "through to it"))
                worstBeatDrift = max(worstBeatDrift, abs(point.beat - atZero[i].beat))
            }
        }
        #expect(worstBeatDrift < 1e-9,
                "the point BEATS moved by \(worstBeatDrift) — far past a float round-trip")

        // CONTROL A: the beat drift is leg D's, not the dot's. A FIXED path —
        // P2's exact behaviour, no field involved — must show the same residual,
        // or the tolerance above is hiding something P3 introduced.
        let fixedZero = try lane(clipStartBeat: 0, path: .fixed)
        let fixedMoved = try lane(clipStartBeat: 128, path: .fixed)
        var fixedDrift = 0.0
        for (i, point) in fixedMoved.enumerated() where i < fixedZero.count {
            #expect(point.value == fixedZero[i].value)
            fixedDrift = max(fixedDrift, abs(point.beat - fixedZero[i].beat))
        }
        #expect(fixedDrift > 0,
                Comment(rawValue: "a FIXED path showed NO beat drift (\(fixedDrift)) — then the drift the "
                + "drifting path shows is NOT the pre-existing round-trip this test tolerates, "
                + "and the tolerance is covering a real defect"))
        print("[measured] P3 clip-position: worst beat drift \(worstBeatDrift) with a drift path, "
              + "\(fixedDrift) with a FIXED one (leg D\'s beats→seconds→beats round-trip); "
              + "0 values changed")

        // CONTROL B: the VALUES are position-sensitive, so their invariance
        // above is a fact about the coordinate and not about a flat field.
        // Same clip, same seed — notes moved 128 beats later INSIDE the clip.
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        _ = try store.setInstrument(id: track.id, kind: .sampler, sampler: SamplerParams(zones: []))
        let late = (0..<8).map {
            MIDINote(pitch: 69, startBeat: 128 + Double($0) * 2, lengthBeats: 2)
        }
        let lateClip = try store.addMIDIClip(toTrack: track.id, lengthBeats: 160, notes: late)
        _ = try store.applyEffortShape(
            clipID: lateClip.id, ring: .standard,
            angleRadians: EffortRing.radians(fromDegrees: 45),
            radius: 1, path: driftPath(), seed: 77)
        let lateLane = try expressionLane(store)
        #expect(lateLane.map(\.value) != atZero.map(\.value),
                Comment(rawValue: "notes 128 beats later in the SAME clip got the identical values — the "
                + "field is not reading the beat at all, so the invariance above is vacuous"))
    }

    /// The other half of "did it actually do something": the same call with a
    /// different seed must be a different performance, all the way to the lane.
    @Test("P3: the seed reaches the lane, and re-running one seed reproduces it exactly")
    func seedReachesTheLane() throws {
        func lane(seed: UInt64) throws -> [MIDIControllerPoint] {
            let (store, clip) = try breathStore(noteCount: 8, noteLengthBeats: 2)
            _ = try store.applyEffortShape(
                clipID: clip.id, ring: .standard,
                angleRadians: EffortRing.radians(fromDegrees: 45),
                radius: 1, path: driftPath(), seed: seed)
            return try expressionLane(store)
        }
        let a = try lane(seed: 1)
        #expect(try lane(seed: 1) == a, "the same seed did not reproduce its own lane")
        #expect(try lane(seed: 2) != a, "the seed is threaded but never read")
    }

    /// P3's two silent failures, said out loud. A wander that goes nowhere and a
    /// wander that moves faster than the notes can sample it both look exactly
    /// like success from the outside.
    @Test("P3: an inert path and an aliasing path each earn their own sentence")
    func pathWarningsAreLegible() throws {
        // (a) A swing far smaller than the 45° gap between gestures: it moves,
        // and it never leaves the pattern it started on.
        let (store, clip) = try breathStore(noteCount: 8, noteLengthBeats: 2)
        let tiny = try store.applyEffortShape(
            clipID: clip.id, ring: .standard, angleRadians: 0, radius: 1,
            path: driftPath(angleSwingDegrees: 2), seed: 5)
        #expect(tiny.warnings.contains { $0.contains("never left") },
                Comment(rawValue: "a 2° wander on a 45°-spaced ring blended nothing and said nothing: "
                + "\(tiny.warnings)"))

        // (b) An orbit far faster than the note grid. Notes arrive every 2 beats
        // here, so the dot is sampled 0.5×/beat and anything above 0.25 cycles
        // per beat is an alias.
        let (fastStore, fastClip) = try breathStore(noteCount: 8, noteLengthBeats: 2)
        let fast = try fastStore.applyEffortShape(
            clipID: fastClip.id, ring: .standard, angleRadians: 0, radius: 1,
            path: .orbit(revolutionBeats: 0.5, direction: .clockwise))
        #expect(fast.warnings.contains { $0.contains("ALIAS") },
                Comment(rawValue: "a 0.5-beat orbit sampled once per 2 beats aliased silently: \(fast.warnings)"))

        // (c) ⭐ THE WARNING MUST NAME THE GESTURE THE CALLER IS ACTUALLY ON.
        // Case (a) sits at 0°, where "lowest ring index touched" and "dominant"
        // are the same pattern — so it is green against a wrong implementation.
        // Park the dot on ring index 2 (Late bloom, 90°) instead: a 2° wander
        // there straddles the boundary and TOUCHES index 1, so a message built
        // from `patternIDs.first` says "never left Messa di voce" about a dot
        // that never left Late bloom, and sends the caller to edit the wrong
        // gesture. This case fails against that implementation and passes
        // against the weight-summed dominant.
        let onLateBloom = EffortRing.radians(fromDegrees: 90)
        let (nameStore, nameClip) = try breathStore(noteCount: 8, noteLengthBeats: 2)
        let named = try nameStore.applyEffortShape(
            clipID: nameClip.id, ring: .standard, angleRadians: onLateBloom, radius: 1,
            path: driftPath(angleSwingDegrees: 2), seed: 5)
        let inertness = try #require(named.warnings.first { $0.contains("never left") },
                                     Comment(rawValue: "no inertness warning at 90°: \(named.warnings)"))
        #expect(inertness.contains("Late bloom"),
                Comment(rawValue: "the warning did not name the gesture the dot is parked on: \(inertness)"))
        #expect(!inertness.contains("Messa di voce"),
                Comment(rawValue: "the warning named the lower-index NEIGHBOUR, not the dominant "
                + "gesture — patternIDs.first is sorted by ring index, not by weight: \(inertness)"))
        // And the report itself must agree with the sentence.
        #expect(named.patternName == "Late bloom",
                Comment(rawValue: "the report's own dominant disagrees with the warning: "
                + "\(named.patternName)"))

        // NEGATIVE CONTROL: a sane path earns NEITHER sentence, or the warnings
        // are decoration that always fires.
        let (sane, saneClip) = try breathStore(noteCount: 8, noteLengthBeats: 2)
        let ok = try sane.applyEffortShape(
            clipID: saneClip.id, ring: .standard, angleRadians: 0, radius: 1,
            path: driftPath(), seed: 5)
        #expect(!ok.warnings.contains { $0.contains("never left") || $0.contains("ALIAS") },
                Comment(rawValue: "a well-behaved drift was warned about anyway: \(ok.warnings)"))
    }

    // MARK: - Breath pad P4: the AIR BUDGET, at the STORE boundary
    //
    // The sweep's own maths lives in the non-`@MainActor` `AirBudgetTests` and
    // costs no suite slot. What can only be checked HERE is whether the budget
    // reaches the LANE when it is enforced, leaves it untouched when it is not,
    // and says so out loud either way.

    /// A part long enough to run a 6-second lungful out: 8 notes of 4 beats at
    /// 120 bpm is 16 seconds of continuous blowing.
    private func airStore() throws -> (store: ProjectStore, clip: Clip) {
        try breathStore(noteCount: 8, noteLengthBeats: 4)
    }

    /// ⭐⭐ THE DISCRIMINATING TEST FOR THE WHOLE PHASE (design §13.3). The same
    /// phrase with `enforced` true and false must produce DIFFERENT CC values
    /// **and** a report that names the notes that changed. A budget that
    /// attenuates correctly but reports nothing fails here; so does one that
    /// reports beautifully and never reaches the lane.
    @Test("P4: enforcement CHANGES the lane and the report NAMES every note it changed")
    func airEnforcementChangesTheLaneAndSaysSo() throws {
        let pattern = try #require(EffortPattern.named("messaDiVoce"))
        func apply(_ enforced: Bool) throws -> (points: [MIDIControllerPoint],
                                                result: EffortShapeApplication) {
            let (store, clip) = try airStore()
            let result = try store.applyEffortShape(
                clipID: clip.id, pattern: pattern,
                air: AirBudget.Settings(enforced: enforced))
            return (try expressionLane(store), result)
        }
        let (offPoints, off) = try apply(false)
        let (onPoints, on) = try apply(true)
        let offPeaks = perNotePeaks(offPoints, noteCount: 8)
        let onPeaks = perNotePeaks(onPoints, noteCount: 8)
        print("[measured] P4 store: enforced=false per-note peak CC \(offPeaks); "
              + "enforced=true \(onPeaks); constrained \(on.air.constrainedNoteCount) of "
              + "\(on.air.notesConsidered); lowestAir \(on.air.lowestAir); "
              + "maxAttenuation \(on.air.maxAttenuationDb) dB")

        // 1. THE LANE MOVED.
        #expect(onPeaks != offPeaks, "enforcement wrote the same lane — it never reached the write")
        #expect(offPeaks.allSatisfy { $0 == offPeaks[0] },
                "fixture check: unenforced, a note-scoped pattern gives every note the same peak")
        // 2. AND THE REPORT NAMES EXACTLY THE NOTES THAT MOVED. This is the
        //    assertion a silent implementation fails.
        let namedBeats = Set(on.air.constrainedNotes.map(\.beat))
        let movedIndices = (0..<8).filter { onPeaks[$0] != offPeaks[$0] }
        let namedIndices = namedBeats.map { Int($0 / 4) }.sorted()
        #expect(!movedIndices.isEmpty, "fixture check: something must have moved")
        #expect(namedIndices == movedIndices,
                Comment(rawValue: "the report names notes \(namedIndices) but the LANE changed on "
                + "\(movedIndices) — one of the two is lying"))
        // 3. And the report is the same PREDICTION either way; only `applied`
        //    differs. So "what would this do?" is answerable without mutating.
        #expect(off.air.applied == false)
        #expect(on.air.applied == true)
        // ⚠️ Compared WITHOUT the note ids: each `airStore()` builds a fresh
        // store, so the two runs describe the same music with different UUIDs.
        // Comparing whole `ConstrainedNote`s fails on identity alone and says
        // nothing about the model, which is what it did on the first run.
        func shape(_ report: AirBudget.Report) -> [[Double]] {
            report.constrainedNotes.map {
                [$0.beat, $0.effortRequested, $0.effortAllowed, $0.airAtNote,
                 Double($0.peakCCRequested), Double($0.peakCCAllowed), $0.attenuationDb]
            }
        }
        #expect(shape(off.air) == shape(on.air))
        #expect(!shape(on.air).isEmpty, "fixture check: there is something to compare")
        // 4. THE WARNING. The existence of the effect is never silent.
        #expect(on.warnings.contains { $0.contains("air enforcement changed") },
                Comment(rawValue: "enforcement changed the lane and said nothing: \(on.warnings)"))
        #expect(on.warnings.contains { $0.contains("airCapacitySeconds") },
                "the warning must name the key that fixes it")
    }

    /// ⛔ THE USER RULING (2026-08-19), pinned where a well-meaning default
    /// change cannot slip past: a call that never mentions air must write
    /// exactly what it wrote before P4 existed.
    @Test("P4: `enforced` DEFAULTS TO FALSE — an ordinary call is byte-identical to enforced:false")
    func enforcementDefaultsToOff() throws {
        let pattern = try #require(EffortPattern.named("messaDiVoce"))
        let (plainStore, plainClip) = try airStore()
        let plain = try plainStore.applyEffortShape(clipID: plainClip.id, pattern: pattern)
        let (offStore, offClip) = try airStore()
        _ = try offStore.applyEffortShape(
            clipID: offClip.id, pattern: pattern, air: AirBudget.Settings(enforced: false))
        let (onStore, onClip) = try airStore()
        _ = try onStore.applyEffortShape(
            clipID: onClip.id, pattern: pattern, air: AirBudget.Settings(enforced: true))

        let plainPoints = try expressionLane(plainStore)
        let offPoints = try expressionLane(offStore)
        let onPoints = try expressionLane(onStore)
        #expect(plainPoints == offPoints, "the default is not `enforced: false`")
        // POSITIVE CONTROL: the comparison above CAN come out unequal, so its
        // equality is evidence rather than a tautology about the fixture.
        #expect(plainPoints != onPoints,
                Comment(rawValue: "enforced:true wrote the same lane as the default — the control "
                + "is dead and the equality above proves nothing"))
        // ⭐ AND AN ORDINARY CALL IS NOT NAGGED ABOUT A MODEL IT NEVER ASKED
        // FOR — **not one sentence, not the "would have" advisory**. This was
        // originally written as `!contains("air enforcement is OFF")`, which
        // passed while FOUR other air sentences leaked into a plain call on any
        // part longer than a lungful: a behaviour change to a live verb. The
        // assertion has to be "no warning mentions air AT ALL".
        //
        // ⚠️ Tokenised, not `contains("air")` — this file already learned that
        // the hard way: `contains("air")` matches h-AIR-pinCrescendo.
        func mentionsAir(_ warning: String) -> Bool {
            Set(warning.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
                .contains("air")
        }
        #expect(!plain.warnings.contains(where: mentionsAir),
                Comment(rawValue: "a caller who never mentioned air was nagged: \(plain.warnings)"))
        // ...but one who DID ask, with it off, is told what it would have done.
        // POSITIVE CONTROL for `mentionsAir`: it must be capable of firing.
        let (askStore, askClip) = try airStore()
        let asked = try askStore.applyEffortShape(
            clipID: askClip.id, pattern: pattern, air: AirBudget.Settings(enforced: false))
        #expect(asked.warnings.contains(where: mentionsAir),
                Comment(rawValue: "the air-detector never fires, so the silence above proves "
                + "nothing: \(asked.warnings)"))
        #expect(asked.warnings.contains { $0.contains("air enforcement is OFF") },
                Comment(rawValue: "a caller who asked about air got no advisory: \(asked.warnings)"))
        // And the same for enforcement ON: the gate is `applied || airAsked`, so
        // turning it on without any other air key must still speak.
        let onResult = try airStore()
        let spoke = try onResult.store.applyEffortShape(
            clipID: onResult.clip.id, pattern: pattern, air: AirBudget.Settings(enforced: true))
        #expect(spoke.warnings.contains(where: mentionsAir),
                Comment(rawValue: "enforcement changed the lane in silence: \(spoke.warnings)"))
    }

    /// ⛔ §9.6, BOTH HALVES. The budget must never make a note silent, and must
    /// never change a note's length or existence.
    @Test("P4: enforcement never silences a note and never touches note count or length")
    func theBudgetNeverSilencesOrDeletes() throws {
        let (before, beforeClip) = try airStore()
        let originalNotes = try #require(before.tracks[0].clips[0].notes)
        // loudnessDepth 1 is the reachable worst case: `peak × (1 − 1 × (1 − e))`
        // is exactly 0 at effort 0, so without the floor this WOULD write CC 0.
        let result = try before.applyEffortShape(
            clipID: beforeClip.id,
            pattern: try #require(EffortPattern.named("messaDiVoce")),
            response: BreathContour.EffortResponse(loudnessDepth: 1, swellDepth: 1),
            air: AirBudget.Settings(enforced: true))
        let after = try #require(before.tracks[0].clips[0].notes)
        let points = try expressionLane(before)
        print("[measured] P4 §9.6: notes \(originalNotes.count) → \(after.count); "
              + "lowest CC written \(points.map(\.value).min() ?? -1); "
              + "constrained \(result.air.constrainedNoteCount)")

        #expect(result.air.constrainedNoteCount > 0, "fixture check: the budget must have bitten")
        #expect(after.count == originalNotes.count, "the budget changed the NOTE COUNT")
        #expect(zip(originalNotes, after).allSatisfy { $0.lengthBeats == $1.lengthBeats },
                "the budget changed a note's LENGTH")
        #expect(zip(originalNotes, after).allSatisfy { $0.startBeat == $1.startBeat })
        #expect((points.map(\.value).min() ?? 0) > 0,
                "a CC 0 reached the lane — the budget silenced a note, which §9.6 forbids")
        #expect(result.air.constrainedNotes.allSatisfy { $0.peakCCAllowed >= 1 })
    }

    /// ⚠️ The P1 inert-response warning REVERSES under enforcement: with air
    /// pulling effort below 1, `loudnessDepth`/`swellDepth` are exactly what
    /// makes the sag audible, so telling the caller they "did NOTHING" would
    /// send them to delete the parameters carrying the effect.
    @Test("P4: the `did NOTHING` warning is suppressed when air is what makes the response live")
    func theInertResponseWarningFlipsUnderEnforcement() throws {
        let pattern = try #require(EffortPattern.named("messaDiVoce"))
        let asked = BreathContour.EffortResponse(loudnessDepth: 0.9, swellDepth: 0.5)
        func warnings(enforced: Bool) throws -> [String] {
            let (store, clip) = try airStore()
            return try store.applyEffortShape(
                clipID: clip.id, pattern: pattern, response: asked,
                air: AirBudget.Settings(enforced: enforced)).warnings
        }
        let off = try warnings(enforced: false)
        let on = try warnings(enforced: true)
        print("[measured] P4 inert flip: off \(off.filter { $0.contains("did NOTHING") }.count) "
              + "| on \(on.filter { $0.contains("did NOTHING") }.count)")
        // POSITIVE CONTROL FIRST: with enforcement off, effort really is pinned
        // at 1 on a note-scoped pattern and the sentence is TRUE, so it must
        // still fire. Without this half the suppression could be unconditional.
        #expect(off.contains { $0.contains("did NOTHING") },
                Comment(rawValue: "the P1 warning stopped firing where it is still true: \(off)"))
        #expect(!on.contains { $0.contains("did NOTHING") },
                Comment(rawValue: "the caller was told loudnessDepth did nothing while it was "
                + "carrying the entire air sag: \(on)"))
    }

    /// ⛔ THE AMBIGUITY §9 FORBIDS, guarded at the only place it could reappear.
    /// "Air runs out" must never be selectable as a ring pattern: a user who
    /// could PICK the symptom the budget separately PRODUCES would have two
    /// indistinguishable causes for one sound.
    @Test("P4: `air runs out` is not, and cannot become, a selectable pattern")
    func airIsNotAPattern() {
        // The predicate: does any library entry offer running out of air as a
        // gesture the user chooses?
        //
        // ⚠️ TOKENS, NOT SUBSTRINGS, and that is not fastidiousness: the obvious
        // `text.contains("air")` matches **h-air-pinCrescendo** and fired on the
        // shipped library the first time this ran. A guard that reports the
        // thing it guards against is worse than none — it teaches the next
        // reader to delete it.
        func tokens(_ pattern: EffortPattern) -> Set<String> {
            var spaced = ""
            for character in "\(pattern.id) \(pattern.displayName)" {
                if character.isUppercase { spaced.append(" ") }
                spaced.append(character)
            }
            return Set(spaced.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init))
        }
        func offersAirAsAGesture(_ patterns: [EffortPattern]) -> Bool {
            patterns.contains { pattern in
                let words = tokens(pattern)
                return words.contains("air") || words.contains("breathless")
                    || words.contains("winded") || words.contains("exhausted")
            }
        }
        // The token split itself, pinned — otherwise the guard could be passing
        // because it never sees a word at all.
        #expect(tokens(EffortPattern.library[3]).contains("hairpin"))
        #expect(!tokens(EffortPattern.library[3]).contains("air"))
        #expect(!offersAirAsAGesture(EffortPattern.library))
        // ⭐ POSITIVE CONTROL — the predicate must be able to FIRE. A guard built
        // from a pattern that cannot match is the weakest evidence there is, and
        // this tree has shipped one.
        let planted = EffortPattern.library + [EffortPattern(
            id: "airRunsOut", displayName: "Air runs out", scope: .phrase,
            summary: "the symptom the budget produces",
            knots: [.init(u: 0, level: 1), .init(u: 1, level: 0.2)])]
        #expect(offersAirAsAGesture(planted),
                "the guard cannot detect the thing it guards against")
        // And the wire cannot resolve it by name either.
        #expect(EffortPattern.named("airRunsOut") == nil)
        #expect((try? EffortRing.resolve(ids: ["airRunsOut"])) == nil)
    }

    /// The whole clip consumes air, but only the SELECTION can be rewritten —
    /// and the difference is reported rather than passing as a change that
    /// happened.
    @Test("P4: unselected notes still consume air, are reported shaped=false, and are not rewritten")
    func unselectedNotesConsumeButAreNotRewritten() throws {
        let (store, clip) = try airStore()
        let notes = try #require(store.tracks[0].clips[0].notes)
        // Shape only the LAST two notes — the ones that would be short of air.
        let tail = Array(notes.suffix(2).map(\.id))
        let result = try store.applyEffortShape(
            clipID: clip.id, noteIDs: tail,
            pattern: try #require(EffortPattern.named("messaDiVoce")),
            air: AirBudget.Settings(enforced: true))
        print("[measured] P4 selection: considered \(result.air.notesConsidered), shaped "
              + "\(result.air.notesShaped), constrained \(result.air.constrainedNoteCount) "
              + "(\(result.air.constrainedShapedCount) of them shaped)")

        #expect(result.air.notesConsidered == 8, "the sweep must see the WHOLE clip")
        #expect(result.air.notesShaped == 2)
        #expect(result.air.constrainedShapedCount > 0)
        // ⭐ The discriminating half: unselected notes were ALSO short of air,
        // and the report says so instead of quietly leaving them out.
        #expect(result.air.constrainedNoteCount > result.air.constrainedShapedCount,
                Comment(rawValue: "the sweep only looked at the selection — a player who has been "
                + "blowing since bar 1 does not arrive fresh because the caller selected bar 9"))
        #expect(result.air.constrainedNotes.contains { !$0.shaped })
        #expect(result.warnings.contains { $0.contains("NOT in the noteIds you selected") },
                Comment(rawValue: "notes were left short of air with no sentence: \(result.warnings)"))
    }

    /// ⛔⛔ **THE BUDGET MUST NOT MOVE P1's "IT RAN AND DID NOTHING" SIGNAL.**
    ///
    /// `minEffort`/`maxEffort` are the gesture's range, and the wire, the MCP
    /// tool description and the Copilot catalog all promise the same sentence:
    /// *equal values mean the shape ran and varied nothing*. A note-scoped
    /// pattern asks every note for effort 1, so the P1 invariant is
    /// `min == max == 1`.
    ///
    /// Building the pair from the WRITTEN effort instead broke that, and I
    /// measured it before believing it: enforcement turned `1.0 … 1.0` into
    /// `4.4e-16 … 1.0`, which every one of those descriptions reads as "the
    /// shape varied something". It did not — the budget did. Two causes, one
    /// symptom, in the one field that exists to be unambiguous.
    @Test("P4: enforcement does NOT move minEffort/maxEffort — they stay the GESTURE's range")
    func enforcementDoesNotDisturbTheEffortRange() throws {
        let pattern = try #require(EffortPattern.named("messaDiVoce"))
        #expect(pattern.scope == .note, "fixture: the invariant is a NOTE-scoped one")
        let (plainStore, plainClip) = try airStore()
        let plain = try plainStore.applyEffortShape(clipID: plainClip.id, pattern: pattern)
        let (onStore, onClip) = try airStore()
        let on = try onStore.applyEffortShape(clipID: onClip.id, pattern: pattern,
                                              air: AirBudget.Settings(enforced: true))

        // FIXTURE CHECK: enforcement really did change this lane, so the
        // equality below is a property of the FIELD and not of a no-op call.
        #expect(on.air.applied && on.air.constrainedShapedCount > 0,
                Comment(rawValue: "fixture: enforcement changed nothing, so this test proves "
                + "nothing: \(on.air.constrainedShapedCount) shaped constraints"))
        #expect(try expressionLane(plainStore) != expressionLane(onStore),
                "fixture: the two lanes must differ, or there is no budget effect to leak")

        // THE INVARIANT, both halves.
        #expect(plain.minEffort == 1 && plain.maxEffort == 1,
                Comment(rawValue: "P1: a note-scoped pattern asks every note for 1, got "
                + "\(plain.minEffort)…\(plain.maxEffort)"))
        #expect(on.minEffort == plain.minEffort && on.maxEffort == plain.maxEffort,
                Comment(rawValue: "the budget leaked into the gesture's range: "
                + "\(on.minEffort)…\(on.maxEffort) vs \(plain.minEffort)…\(plain.maxEffort)"))
        // And the effect is not LOST — it is on the surface built for it.
        #expect(on.air.constrainedNotes.contains { $0.effortAllowed < 1 },
                "the budget's effect must still be legible in air.constrainedNotes")
    }

    /// ⛔⛔ **THE WARNING THAT CLAIMED AN ATTENUATION THAT NEVER HAPPENED.**
    ///
    /// Enforcement ON + `noteIDs` naming only well-supplied notes: the budget
    /// constrains five notes, every one of them outside the selection, and the
    /// lane this call wrote is byte-identical to `airEnforced: false`. The
    /// summary sentence was gated on `applied` alone, so it read
    ///
    ///   "air enforcement changed 0 of 2 shaped notes … pulled down by up to
    ///    13.9 dB"
    ///
    /// — a dB figure quoted about notes this call did not touch, and a past
    /// tense ("were attenuated") about a lane that does not exist. That is the
    /// exact defect class P4 exists to remove, committed by the warning written
    /// to prevent it. `wrote = applied && constrainedShapedCount > 0` now gates
    /// every claim of a change, and every quoted figure is measured over the
    /// notes its sentence is about.
    @Test("P4: enforcement that reaches NOTHING SELECTED never claims a change or a dB figure")
    func enforcementThatWritesNothingClaimsNothing() throws {
        let pattern = try #require(EffortPattern.named("messaDiVoce"))
        let (store, clip) = try airStore()
        let all = try #require(store.tracks[0].clips[0].notes)
        // The first two notes are on a full lungful; the shortfall is in the tail.
        let head = Array(all.prefix(2).map(\.id))
        let result = try store.applyEffortShape(
            clipID: clip.id, noteIDs: head, pattern: pattern,
            air: AirBudget.Settings(enforced: true))

        // FIXTURE CHECK — the situation actually exists, or this test is vacuous.
        #expect(result.air.applied)
        #expect(result.air.constrainedNoteCount > 0,
                "fixture: the budget must constrain something somewhere")
        #expect(result.air.constrainedShapedCount == 0,
                Comment(rawValue: "fixture: the selection must contain NO constrained note, got "
                + "\(result.air.constrainedShapedCount)"))
        #expect(result.air.maxAttenuationDb > 1,
                "fixture: there must be a big dB figure available to be misquoted")

        // 1. NO sentence claims a change to this call's lane.
        #expect(!result.warnings.contains { $0.contains("air enforcement changed") },
                Comment(rawValue: "claimed a change that never reached a lane: \(result.warnings)"))
        #expect(!result.warnings.contains { $0.contains("were attenuated") },
                Comment(rawValue: "past tense about a lane that does not exist: \(result.warnings)"))
        // 2. The dB figure belonging to the untouched notes may still be quoted
        //    — a caller who turned enforcement ON deserves to hear that five
        //    notes elsewhere WOULD sag — but only ever in the counterfactual
        //    voice. Any sentence carrying the number must also carry "would be".
        let db = String(format: "%.1f", result.air.maxAttenuationDb)
        for warning in result.warnings where warning.contains("\(db) dB") {
            #expect(warning.contains("would be"),
                    Comment(rawValue: "quoted \(db) dB as something that HAPPENED: \(warning)"))
        }
        #expect(result.warnings.contains { $0.contains("\(db) dB") },
                Comment(rawValue: "fixture/control: the dB figure must appear SOMEWHERE, or the "
                + "loop above is vacuous: \(result.warnings)"))
        // 3. But it is not SILENT either — it says enforcement changed nothing,
        //    and names the notes that are short of air.
        #expect(result.warnings.contains { $0.contains("air enforcement is ON but changed NOTHING") },
                Comment(rawValue: "enforcement ran and said nothing about it: \(result.warnings)"))
        #expect(result.warnings.contains { $0.contains("NOT in the noteIds you selected") },
                Comment(rawValue: "the constrained notes were never named: \(result.warnings)"))
        // 4. THE GROUND TRUTH the sentence is asserting: the lane really is what
        //    `airEnforced: false` would have written.
        let (offStore, offClip) = try airStore()
        _ = try offStore.applyEffortShape(clipID: offClip.id, noteIDs:
                                            Array(try #require(offStore.tracks[0].clips[0].notes)
                                                .prefix(2).map(\.id)),
                                          pattern: pattern,
                                          air: AirBudget.Settings(enforced: false))
        #expect(try expressionLane(store) == expressionLane(offStore),
                "the sentence says nothing was written; the lane disagrees")
    }

    /// Layer 2 in full: the sentences a composer actually reads.
    @Test("P4: the warnings name the phrase, the seconds, the dB and the key that fixes it")
    func airWarningsAreLegible() throws {
        let (store, clip) = try airStore()
        let result = try store.applyEffortShape(
            clipID: clip.id, pattern: try #require(EffortPattern.named("messaDiVoce")),
            air: AirBudget.Settings(enforced: true))
        let air = result.warnings.filter { $0.contains("air") }
        print("[measured] P4 warnings:\n  - " + air.joined(separator: "\n  - "))
        #expect(air.contains { $0.contains("effortRequested") && $0.contains("effortAllowed") },
                "the summary must point at the two fields that make the change legible")
        #expect(air.contains { $0.contains("dB") }, "the audible size must be stated")
        #expect(air.contains { $0.contains("airEnforced=false") },
                "every sentence about an override must say how to turn it off")
        // A phrase-and-seconds sentence, §9.4's first example.
        #expect(result.warnings.contains {
            $0.contains("ran out of air") && $0.contains("phrase")
        }, Comment(rawValue: "no phrase-level detail sentence: \(result.warnings)"))
    }

    /// ⛔ The inert-ENFORCEMENT trap, reachable from the wire: with
    /// `loudnessDepth: 0, swellDepth: 0` the budget constrains notes and writes
    /// exactly the same lane. Success, a written lane, no effect — the defect
    /// class this round exists to end.
    @Test("P4: enforcement with an IDENTITY response is called out rather than shipped silently")
    func inertEnforcementIsCalledOut() throws {
        let (store, clip) = try airStore()
        let result = try store.applyEffortShape(
            clipID: clip.id, pattern: try #require(EffortPattern.named("messaDiVoce")),
            response: .identity, air: AirBudget.Settings(enforced: true))
        #expect(result.air.constrainedNoteCount > 0)
        #expect(result.warnings.contains { $0.contains("NONE of it will be audible") },
                Comment(rawValue: "an inert enforcement passed silently: \(result.warnings)"))
        // POSITIVE CONTROL: a live response does NOT earn the sentence.
        let (liveStore, liveClip) = try airStore()
        let live = try liveStore.applyEffortShape(
            clipID: liveClip.id, pattern: try #require(EffortPattern.named("messaDiVoce")),
            air: AirBudget.Settings(enforced: true))
        #expect(!live.warnings.contains { $0.contains("NONE of it will be audible") })
    }

    // MARK: - Breath pad P5: physiological humanisation (§10)
    //
    // Folded into THIS suite for the reason P1–P4's store halves were: the tree
    // is at its 330-`@MainActor`-suite ceiling and this IS the controller-lane
    // store boundary. The PURE half is in `BreathPadDeterminismTests`.

    /// ⭐⭐ **§13.5's NULL, AT THE STORE.** With humanisation at its defaults the
    /// written lane must be byte-identical to a call that never mentions it —
    /// which is what makes each knob individually declinable after the fact.
    @Test("P5: default humanisation writes the byte-identical lane; a non-default one does not")
    func humanisationDefaultsAreANull() throws {
        let pattern = try #require(EffortPattern.named("hairpinCrescendo"))

        let (plain, plainClip) = try breathStore(noteCount: 4)
        _ = try plain.applyEffortShape(clipID: plainClip.id, pattern: pattern)
        let plainLane = try expressionLane(plain)

        let (defaulted, defaultedClip) = try breathStore(noteCount: 4)
        _ = try defaulted.applyEffortShape(clipID: defaultedClip.id, pattern: pattern,
                                           humanisation: .none)
        #expect(try expressionLane(defaulted) == plainLane,
                "passing .none changed the lane")

        // ⚠️ The rate and scale carry no depth, so they too must change nothing.
        // A generator that refined its grid on the RATE rather than on the
        // DEPTH would pass the assertion above and fail this one.
        let (rated, ratedClip) = try breathStore(noteCount: 4)
        _ = try rated.applyEffortShape(
            clipID: ratedClip.id, pattern: pattern,
            humanisation: EffortField.Humanisation(driftScaleBeats: 2, tremorRateHz: 12))
        #expect(try expressionLane(rated) == plainLane,
                "a rate with no depth behind it changed the lane")

        // ⭐ AND THE DISCRIMINATING HALF: a real depth MUST change it, or every
        // assertion above is satisfied by a feature wired to nothing.
        let (drifted, driftedClip) = try breathStore(noteCount: 4)
        _ = try drifted.applyEffortShape(
            clipID: driftedClip.id, pattern: pattern,
            humanisation: EffortField.Humanisation(driftDepth: 0.3))
        let driftedLane = try expressionLane(drifted)
        #expect(driftedLane != plainLane, "driftDepth 0.3 wrote the identical lane")

        let (tremored, tremoredClip) = try breathStore(noteCount: 4)
        _ = try tremored.applyEffortShape(
            clipID: tremoredClip.id, pattern: pattern,
            humanisation: EffortField.Humanisation(tremorDepth: 0.08))
        let tremoredLane = try expressionLane(tremored)
        #expect(tremoredLane != plainLane, "tremorDepth 0.08 wrote the identical lane")
        print("[measured] P5 store null: plain \(plainLane.count) points, "
              + "drift \(driftedLane.count), tremor \(tremoredLane.count)")
        // The tremor forces a finer grid, so it must emit MORE points — a
        // cheap, independent witness that the refinement really ran.
        #expect(tremoredLane.count > plainLane.count)
    }

    /// The drift IS gesture variation, unlike P4's air budget, so it belongs in
    /// the `minEffort`/`maxEffort` pair that the wire, the MCP tool and the
    /// Copilot catalog all describe as "the shape ran and varied nothing".
    @Test("P5: the drift moves the REQUESTED effort range; the note-scoped invariant holds without it")
    func driftMovesTheReportedEffortRange() throws {
        let messa = try #require(EffortPattern.named("messaDiVoce"))

        // P1's invariant: on a note-scoped pattern every note is at effort 1.
        let (plain, plainClip) = try breathStore(noteCount: 6)
        let plainResult = try plain.applyEffortShape(clipID: plainClip.id, pattern: messa)
        #expect(plainResult.minEffort == 1 && plainResult.maxEffort == 1)

        // …and with a drift on, they must NOT be equal, because the shape really
        // did vary something. Reporting 1.00…1.00 here would tell the caller the
        // opposite of what the lane says.
        let (drifted, driftedClip) = try breathStore(noteCount: 6)
        let driftedResult = try drifted.applyEffortShape(
            clipID: driftedClip.id, pattern: messa,
            humanisation: EffortField.Humanisation(driftDepth: 0.25))
        print("[measured] P5 drifted effort range: \(driftedResult.minEffort)…\(driftedResult.maxEffort)")
        #expect(driftedResult.maxEffort < 1.0000001)
        #expect(driftedResult.minEffort < driftedResult.maxEffort,
                "the drift did not vary the requested effort")
        #expect(driftedResult.minEffort >= 0.75 - 1e-9, "the drift exceeded its own depth")
    }

    /// ⚠️ THE WARNING REVERSAL, the same shape P4 found for the air budget: with
    /// a drift on, `loudnessDepth`/`swellDepth` are exactly what makes it
    /// audible on a note-scoped pattern, so the "they did NOTHING" sentence
    /// becomes false and must not fire.
    @Test("P5: the inert-response warning does NOT fire once a drift is moving effort")
    func driftReversesTheInertResponseWarning() throws {
        let messa = try #require(EffortPattern.named("messaDiVoce"))
        let response = BreathContour.EffortResponse(loudnessDepth: 0.9, swellDepth: 0.2)

        // POSITIVE CONTROL: without the drift the warning fires, so its absence
        // below is a consequence of the drift and not of a broken predicate.
        let (still, stillClip) = try breathStore(noteCount: 4)
        let stillResult = try still.applyEffortShape(clipID: stillClip.id, pattern: messa,
                                                     response: response)
        #expect(stillResult.warnings.contains { $0.contains("did NOTHING here") },
                "the control did not fire: \(stillResult.warnings)")

        let (drifted, driftedClip) = try breathStore(noteCount: 4)
        let driftedResult = try drifted.applyEffortShape(
            clipID: driftedClip.id, pattern: messa, response: response,
            humanisation: EffortField.Humanisation(driftDepth: 0.25))
        #expect(!driftedResult.warnings.contains { $0.contains("did NOTHING here") },
                "the warning claimed the response was inert while the drift was using it")
    }

    /// The drift's own inert case, which is NOT the one above: effort reaches
    /// the lane only through the response, so with both depths at 0 a drifted
    /// note writes the identical contour.
    @Test("P5: a drift under an IDENTITY response is named as inaudible, and really is")
    func driftUnderAnIdentityResponseIsNamed() throws {
        let messa = try #require(EffortPattern.named("messaDiVoce"))
        let (store, clip) = try breathStore(noteCount: 4)
        let result = try store.applyEffortShape(
            clipID: clip.id, pattern: messa, response: .identity,
            humanisation: EffortField.Humanisation(driftDepth: 0.3))
        #expect(result.warnings.contains { $0.contains("NOTHING will be heard") },
                "no sentence named the inaudible drift: \(result.warnings)")

        // …and the claim is TRUE: the lane really is identical to no drift.
        let (control, controlClip) = try breathStore(noteCount: 4)
        _ = try control.applyEffortShape(clipID: controlClip.id, pattern: messa,
                                         response: .identity)
        #expect(try expressionLane(store) == expressionLane(control),
                "the warning said nothing would be heard, and something changed")

        // POSITIVE CONTROL: with a live response the sentence must NOT appear,
        // or it is unconditional advice rather than a diagnosis.
        let (live, liveClip) = try breathStore(noteCount: 4)
        let liveResult = try live.applyEffortShape(
            clipID: liveClip.id, pattern: messa,
            response: BreathContour.EffortResponse(loudnessDepth: 0.6, swellDepth: 0.2),
            humanisation: EffortField.Humanisation(driftDepth: 0.3))
        #expect(!liveResult.warnings.contains { $0.contains("NOTHING will be heard") })
    }

    /// ⛔⛔ **THE MEASURED CEILING, ENFORCED AT THE STORE.** On a hosted-AU track
    /// the tremor is SUPPRESSED — the lane must be byte-identical to one written
    /// with no tremor at all — and the caller must be told, with the cause named
    /// as OUR 4096-frame offline block rather than as the plugin.
    @Test("P5: the tremor is suppressed on a hosted-AU track, byte-for-byte, and says why")
    func tremorIsSuppressedOnHostedAUs() throws {
        let messa = try #require(EffortPattern.named("messaDiVoce"))
        let tremor = EffortField.Humanisation(tremorDepth: 0.08, tremorRateHz: 5.5)

        let (bank, bankClip) = try soundBankStore(noteCount: 3)
        let bankResult = try bank.applyEffortShape(clipID: bankClip.id, pattern: messa,
                                                   humanisation: tremor)
        let (bankControl, bankControlClip) = try soundBankStore(noteCount: 3)
        _ = try bankControl.applyEffortShape(clipID: bankControlClip.id, pattern: messa)
        #expect(try expressionLane(bank) == expressionLane(bankControl),
                "the tremor reached a hosted-AU lane it was supposed to be suppressed on")

        let sentence = try #require(bankResult.warnings.first { $0.contains("micro-tremor") },
                                    "nothing told the caller the tremor was dropped")
        // The sentence has to carry the CAUSE and the MEASUREMENT, not just a
        // refusal — a warning that only says "no" is how a user concludes the
        // feature is broken.
        #expect(sentence.contains("4096"), "must name OUR block size as the cause: \(sentence)")
        #expect(sentence.contains("11.719"), "must carry the measured sampling rate")
        #expect(sentence.contains("2.14"), "must carry the measured 8 Hz image ratio")
        #expect(sentence.contains("built-in Sampler"), "must name the path that DOES work")

        // ⭐ AND THE OTHER HALF: on a built-in sampler the same call writes the
        // tremor and says nothing. Without this, "suppressed" could be "never
        // implemented".
        let (sampler, samplerClip) = try breathStore(noteCount: 3)
        let samplerResult = try sampler.applyEffortShape(clipID: samplerClip.id, pattern: messa,
                                                         humanisation: tremor)
        let (samplerControl, samplerControlClip) = try breathStore(noteCount: 3)
        _ = try samplerControl.applyEffortShape(clipID: samplerControlClip.id, pattern: messa)
        #expect(try expressionLane(sampler) != expressionLane(samplerControl),
                "the tremor did nothing on the path that CAN carry it")
        #expect(!samplerResult.warnings.contains { $0.contains("micro-tremor was NOT written") })

        // ⛔ The DRIFT is unaffected on the hosted path — it is three orders of
        // magnitude slower than the ceiling, and suppressing it too would be a
        // limit applied by association.
        let (bankDrift, bankDriftClip) = try soundBankStore(noteCount: 3)
        _ = try bankDrift.applyEffortShape(
            clipID: bankDriftClip.id,
            pattern: try #require(EffortPattern.named("hairpinCrescendo")),
            humanisation: EffortField.Humanisation(driftDepth: 0.3))
        let (bankDriftControl, bankDriftControlClip) = try soundBankStore(noteCount: 3)
        _ = try bankDriftControl.applyEffortShape(
            clipID: bankDriftControlClip.id,
            pattern: try #require(EffortPattern.named("hairpinCrescendo")))
        #expect(try expressionLane(bankDrift) != expressionLane(bankDriftControl),
                "the drift was suppressed on the hosted path along with the tremor")
    }

    /// The tremor must be an OSCILLATION in the written lane, not a level
    /// offset: the lane has to reverse direction several times inside one note.
    /// A "tremor" that only lowered the contour would pass every
    /// lane-changed test above.
    @Test("P5: the written tremor reverses direction many times inside ONE note")
    func tremorIsAnOscillationNotAnOffset() throws {
        let messa = try #require(EffortPattern.named("messaDiVoce"))
        let (store, clip) = try breathStore(noteCount: 1, noteLengthBeats: 8)  // 4 s at 120 BPM
        _ = try store.applyEffortShape(
            clipID: clip.id, pattern: messa,
            humanisation: EffortField.Humanisation(tremorDepth: 0.12, tremorRateHz: 5))
        let lane = try expressionLane(store)

        func reversals(_ points: [MIDIControllerPoint]) -> Int {
            var count = 0
            var lastSign = 0
            for i in 1..<points.count {
                let delta = points[i].value - points[i - 1].value
                guard delta != 0 else { continue }
                let sign = delta > 0 ? 1 : -1
                if lastSign != 0, sign != lastSign { count += 1 }
                lastSign = sign
            }
            return count
        }
        let tremored = reversals(lane)

        let (control, controlClip) = try breathStore(noteCount: 1, noteLengthBeats: 8)
        _ = try control.applyEffortShape(clipID: controlClip.id, pattern: messa)
        let plain = reversals(try expressionLane(control))

        print("[measured] P5 direction reversals in a 4 s note: tremor \(tremored), plain \(plain)")
        // A 4 s note at 5 Hz is 20 cycles = 40 reversals if every one survives
        // integer rounding; the contour's own single peak accounts for the 1–2
        // the control shows.
        #expect(tremored > 20, "the tremor wrote \(tremored) reversals — that is an offset, not an oscillation")
        #expect(plain <= 2, "positive control: the un-tremored contour is nearly monotone")
    }

}
