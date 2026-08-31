import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// m28-knob-ui — the breath pad's hardware-mapping section: every sentence it
/// draws, and **the one hard rule that opening it must not wake CoreMIDI**.
///
/// ⭐ **NOT `@MainActor`, deliberately.** `MainActorOccupancySiteTests`' Leg C
/// caps the tree's `@MainActor` `@Suite` count at 330 and the tree is AT it, so
/// a new suite must not buy a slot. The presentation type is a pure value and
/// needs no actor at all; the handful of assertions that touch the `@MainActor`
/// model reach it through `await MainActor.run`, which is an isolation hop and
/// not a suite annotation.
@Suite struct BreathPadHardwareModelTests {

    // MARK: - Fixtures

    /// The narrowest possible conformer. Every member below is REQUIRED by
    /// `AudioEngineControlling`; the two that matter here — `availableMIDIInputs`
    /// and `setControlChangeObserver` — COUNT their calls, because this suite's
    /// central claim is that both stay at zero.
    @MainActor
    final class SpyEngine: AudioEngineControlling {
        var isRunning = false
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var recordPermission: RecordPermission = .granted

        func prepare() throws { isRunning = true }
        func shutdown() { isRunning = false }
        func tracksDidChange(_ tracks: [Track]) {}
        func startPlayback(_ transport: TransportState) {}
        func stopPlayback() {}
        func seek(_ transport: TransportState) {}
        func setTempo(_ transport: TransportState) {}
        func loopChanged(_ transport: TransportState) {}
        func masterVolumeChanged(_ volume: Double) {}
        func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {}
        func availableInputDevices() -> [AudioInputDevice] { [] }
        func setInputDevice(uid: String?) throws {}
        func startRecording(_ transport: TransportState, to url: URL,
                            completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
        func stopRecording() {}
        func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor],
                           masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           to url: URL) async throws -> AudioFileInfo {
            AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
        }
        func midiEventCount() -> Int { 0 }

        /// ⛔ THE TWO CALLS THAT CREATE THE CoreMIDI CLIENT AND CONNECT TO EVERY
        /// ONLINE SOURCE ON THE USER'S DESK. Both are counted.
        var midiInputs: [MIDIInputDevice] = []
        var enumerateCount = 0
        func availableMIDIInputs() -> [MIDIInputDevice] {
            enumerateCount += 1
            return midiInputs
        }

        var observeCount = 0
        var controlObserver: (@MainActor ([MIDIControlChangeEvent]) -> Void)?
        func setControlChangeObserver(
            _ observer: (@MainActor ([MIDIControlChangeEvent]) -> Void)?) {
            observeCount += 1
            controlObserver = observer
        }

        /// "Did anything ask this engine about MIDI at all?" — the single number
        /// the quiet gate reads.
        var midiTouchCount: Int { enumerateCount + observeCount }
    }

    private static let keystation = MIDIInputDevice(
        uniqueID: 4242, name: "Keystation 49", isVirtual: false, isOnline: true)

    private static func state(_ bindings: [MIDIControlBinding],
                              devices: [MIDIInputDevice] = [],
                              learning: MIDIControlTarget? = nil,
                              lastEvent: MIDIControlChangeEvent? = nil,
                              subscribed: Bool = false) -> MIDIControlPanelState {
        var map = MIDIControlMap(bindings: bindings)
        if let learning { map.armLearn(target: learning) }
        if let lastEvent {
            // `ingest` is the only writer of `lastEvent`, which is the point:
            // the fixture cannot fabricate a state the real path cannot reach.
            // ⚠️ It also COMPLETES an armed learn, so re-arm afterwards when the
            // fixture asked for both.
            map.ingest(lastEvent)
            if let learning { map.armLearn(target: learning) }
        }
        return MIDIControlPanelState(map: map, knownDevices: devices, isSubscribed: subscribed)
    }

    // MARK: - The device-identity ladder

    @Test("a device seen during a learn is NAMED")
    func namedDevice() {
        let s = Self.state([MIDIControlBinding(target: .breathPadAngle, controller: 74,
                                               sourceID: 4242)],
                           devices: [Self.keystation])
        let row = s.rows.first { $0.target == .breathPadAngle }
        #expect(row?.deviceLabel == "Keystation 49")
        #expect(row?.statusLine == "CC 74 · Keystation 49")
    }

    /// ⭐ THE CASE THE CACHE-FROM-LEARN DESIGN CANNOT COVER, AND MUST NOT FAKE.
    /// An agent can create a binding through `midi.setControlMap` with a
    /// `sourceID` this session never enumerated. Resolving that name would mean
    /// calling `availableMIDIInputs()`, which creates the CoreMIDI client — so
    /// the row reports the NUMBER instead of inventing a name.
    @Test("a device this session never enumerated is reported as its NUMBER")
    func unknownDevice() {
        let s = Self.state([MIDIControlBinding(target: .breathPadAngle, controller: 74,
                                               sourceID: 9001)])
        let row = s.rows.first { $0.target == .breathPadAngle }
        #expect(row?.device == .unknown(9001))
        #expect(row?.deviceLabel == "device 9001")
    }

    /// `sourceID == nil` is a deliberate WILDCARD, not missing knowledge — a
    /// third state, and reading it as either of the other two would be wrong in
    /// opposite directions.
    @Test("sourceID nil reads as ANY DEVICE, not as unknown and not as unbound")
    func anyDevice() {
        let s = Self.state([MIDIControlBinding(target: .breathPadRadius, controller: 11,
                                               sourceID: nil)])
        let row = s.rows.first { $0.target == .breathPadRadius }
        #expect(row?.device == .anyDevice)
        #expect(row?.deviceLabel == "any device")
        #expect(row?.isBound == true)
    }

    @Test("an unbound row is unbound, and says so")
    func unbound() {
        let s = Self.state([])
        #expect(s.rows.count == MIDIControlTarget.allCases.count)
        #expect(s.rows.allSatisfy { $0.device == .unbound && !$0.isBound })
        #expect(s.rows.allSatisfy { $0.statusLine == "Not mapped" })
        #expect(s.boundCount == 0)
    }

    // MARK: - The sentences

    /// ⚠️ A row that is armed while already bound must NOT read as settled: the
    /// next controller change replaces what it says.
    @Test("LEARNING outranks BOUND in the row's status")
    func learningOutranksBound() {
        let s = Self.state([MIDIControlBinding(target: .breathPadAngle, controller: 74,
                                               sourceID: 4242)],
                           devices: [Self.keystation],
                           learning: .breathPadAngle)
        let row = s.rows.first { $0.target == .breathPadAngle }
        #expect(row?.isLearning == true)
        #expect(row?.statusLine == "Turn a knob…")
        #expect(s.summaryLine == "Waiting for a knob…")
    }

    @Test("the collapsed summary carries the count AND whether we are listening")
    func summaryLine() {
        #expect(Self.state([]).summaryLine == "No knobs mapped")
        let one = [MIDIControlBinding(target: .breathPadAngle, controller: 74)]
        #expect(Self.state(one, subscribed: false).summaryLine == "1 knob mapped")
        #expect(Self.state(one, subscribed: true).summaryLine == "1 knob mapped · listening")
        let two = one + [MIDIControlBinding(target: .breathPadRadius, controller: 75)]
        #expect(Self.state(two, subscribed: true).summaryLine == "2 knobs mapped · listening")
    }

    /// ⛔ The three feed states are genuinely different diagnoses and must not
    /// collapse into one sentence: listening; mapped but no engine; nothing
    /// mapped so we are deliberately leaving the hardware alone.
    @Test("the feed line distinguishes listening, no-engine, and nothing-mapped")
    func feedLine() {
        let mapped = [MIDIControlBinding(target: .breathPadAngle, controller: 74)]
        #expect(Self.state(mapped, subscribed: true).feedLine.contains("Listening"))
        #expect(Self.state(mapped, subscribed: false).feedLine.contains("no audio engine"))
        let idle = Self.state([], subscribed: false).feedLine
        #expect(idle.contains("leaves your MIDI gear alone"))
        #expect(idle.contains("LEARN"))
    }

    /// ⭐⭐ THE READOUT THAT MAKES A DEAD KNOB DIAGNOSABLE. Channel is reported
    /// 1-based, the way every hardware panel in the world prints it.
    @Test("LAST HEARD names the controller, its value, its channel and its device")
    func lastHeard() {
        #expect(Self.state([]).lastHeardLine == "Nothing heard yet.")
        let event = MIDIControlChangeEvent(sourceID: 4242, channel: 0, controller: 74, value: 96)
        let heard = Self.state([], devices: [Self.keystation], lastEvent: event)
        #expect(heard.lastHeardLine == "CC 74 = 96 · ch 1 · Keystation 49")
        // Unknown device: the number, never a guess.
        let anon = Self.state([], lastEvent: event)
        #expect(anon.lastHeardLine == "CC 74 = 96 · ch 1 · device 4242")
    }

    /// An event from a CC we are NOT mapped to still shows up — that is the
    /// whole point: it separates "your knob is not mapped" from "your knob is
    /// not sending".
    @Test("an UNMAPPED controller still appears in LAST HEARD")
    func unmappedControllerIsStillHeard() {
        let s = Self.state([MIDIControlBinding(target: .breathPadAngle, controller: 74)],
                           lastEvent: MIDIControlChangeEvent(sourceID: 7, channel: 3,
                                                             controller: 1, value: 12))
        #expect(s.lastHeardLine.contains("CC 1 = 12"))
        #expect(s.lastHeardLine.contains("ch 4"))
    }

    @Test("the panel says out loud that mappings are not saved with the song")
    func persistenceNote() {
        let note = MIDIControlPanelState.persistenceNote
        #expect(note.contains("not saved into the project"))
        #expect(note.contains("forgotten when DAW Pro quits"))
    }

    /// The row composes DAWCore's own copy rather than restating it — so a
    /// target added later cannot arrive with a name only the wire knows.
    @Test("row copy is DAWCore's, verbatim")
    func copyIsComposed() {
        let s = Self.state([])
        for row in s.rows {
            #expect(row.name == row.target.displayName)
            #expect(row.summary == row.target.summary)
        }
    }

    // MARK: - ⛔⛔ THE HARD RULE: the panel's model never wakes CoreMIDI

    /// **Constructing the model, reading every property it draws, and pushing a
    /// table into it must not ask the engine anything at all.**
    ///
    /// `armMIDIControlLearn` → `refreshSubscription` → `setControlChangeObserver`
    /// creates the MIDI client and connects to every online source; `armLearn`
    /// ALSO calls `availableMIDIInputs()`, which creates the same client by a
    /// second route. Both are counted here, and the positive control below shows
    /// the counter CAN move — a zero from an instrument that cannot register a
    /// one is worth nothing.
    @Test("opening the panel asks the engine NOTHING (with a positive control)")
    func openingThePanelIsQuiet() async {
        await MainActor.run {
            let engine = SpyEngine()
            let store = ProjectStore()
            store.engine = engine
            let model = BreathPadHardwareModel(
                arm: { store.armMIDIControlLearn(target: $0) },
                cancel: { store.cancelMIDIControlLearn() },
                setBindings: { store.setMIDIControlBindings($0) },
                readBack: { (store.midiControlMap, store.midiControl.isSubscribed) })

            // THE APPEAR PATH, exactly: the app syncs, and the view reads every
            // property it draws.
            model.sync()
            let s = model.state
            _ = s.rows.map(\.statusLine)
            _ = s.summaryLine
            _ = s.feedLine
            _ = s.lastHeardLine
            _ = model.isExpanded
            model.isExpanded = true          // the disclosure is a view flag
            _ = model.state.rows.map(\.summary)

            #expect(engine.midiTouchCount == 0, """
                opening the breath pad asked the engine about MIDI \
                \(engine.midiTouchCount) time(s) — observe=\(engine.observeCount) \
                enumerate=\(engine.enumerateCount)
                """)
            #expect(store.midiControl.isSubscribed == false)

            // POSITIVE CONTROL. The counter is not stuck at zero: pressing LEARN
            // moves BOTH halves of it, which is the designed behaviour and the
            // reason the zero above means something.
            model.toggleLearn(.breathPadAngle)
            #expect(engine.observeCount == 1)
            #expect(engine.enumerateCount == 1)
            #expect(store.midiControl.isSubscribed == true)
        }
    }

    /// Cancelling a learn that was never armed must not reach the engine either
    /// — `closeBreathPad` calls it on every dismissal.
    @Test("cancelling a learn that was never armed is a no-op, engine untouched")
    func cancelWithoutLearnIsQuiet() async {
        await MainActor.run {
            let engine = SpyEngine()
            let store = ProjectStore()
            store.engine = engine
            var cancels = 0
            let model = BreathPadHardwareModel(
                arm: { store.armMIDIControlLearn(target: $0) },
                cancel: { cancels += 1; store.cancelMIDIControlLearn() },
                setBindings: { store.setMIDIControlBindings($0) },
                readBack: { (store.midiControlMap, store.midiControl.isSubscribed) })
            model.cancelLearn()
            #expect(cancels == 0)
            #expect(engine.midiTouchCount == 0)
        }
    }

    // MARK: - The 30 Hz guard

    /// ⚠️ The pump pushes the table in ~30 times a second, EMPTY passes
    /// included. An unguarded write to an `@Observable` property would
    /// invalidate the whole card at that rate forever.
    @Test("refresh is equality-guarded, so an idle pump changes nothing")
    func refreshIsEqualityGuarded() async {
        await MainActor.run {
            let model = BreathPadHardwareModel(arm: { _ in [] }, cancel: {},
                                               setBindings: { _ in },
                                               readBack: { (MIDIControlMap(), false) })
            let map = MIDIControlMap(bindings: [MIDIControlBinding(target: .breathPadAngle,
                                                                   controller: 74)])
            #expect(model.refresh(map: map, isSubscribed: true) == true)
            // Thirty idle passes with the same table: not one of them is a change.
            for _ in 0..<30 {
                #expect(model.refresh(map: map, isSubscribed: true) == false)
            }
            // A real change still gets through — the guard is not a mute.
            #expect(model.refresh(map: map, isSubscribed: false) == true)
        }
    }

    // MARK: - Editing

    @Test("FLIP toggles inversion, FORGET removes one, and both are no-ops when unbound")
    func editing() async {
        await MainActor.run {
            var written: [[MIDIControlBinding]] = []
            var table = MIDIControlMap(bindings: [
                MIDIControlBinding(target: .breathPadAngle, controller: 74, sourceID: 4242),
                MIDIControlBinding(target: .breathPadRadius, controller: 75, sourceID: 4242),
            ])
            let model = BreathPadHardwareModel(
                arm: { _ in [] }, cancel: {},
                setBindings: { bindings in
                    written.append(bindings)
                    table = MIDIControlMap(bindings: bindings)
                },
                readBack: { (table, !table.bindings.isEmpty) })
            model.sync()
            #expect(model.state.boundCount == 2)

            model.toggleInverted(.breathPadAngle)
            #expect(model.state.rows.first { $0.target == .breathPadAngle }?.isInverted == true)
            #expect(model.state.rows.first { $0.target == .breathPadAngle }?.statusLine
                    == "CC 74 · device 4242 · flipped")

            model.unbind(.breathPadRadius)
            #expect(model.state.boundCount == 1)

            // ⛔ A stray press on an UNBOUND row must not spend a store write:
            // `setBindings` tears the subscription down and rebuilds it.
            let writesBefore = written.count
            model.toggleInverted(.breathPadRadius)
            model.unbind(.breathPadRadius)
            #expect(written.count == writesBefore)

            model.clearAll()
            #expect(model.state.boundCount == 0)
            let writesAfterClear = written.count
            model.clearAll()
            #expect(written.count == writesAfterClear, "clearing an empty table is a no-op")
        }
    }

    /// Re-arming the row that is already armed CANCELS — the button is its own
    /// escape, because a knob gesture has no release to abandon a learn with.
    @Test("pressing LEARN twice on the same row cancels instead of re-arming")
    func learnTogglesOff() async {
        await MainActor.run {
            let engine = SpyEngine()
            let store = ProjectStore()
            store.engine = engine
            let model = BreathPadHardwareModel(
                arm: { store.armMIDIControlLearn(target: $0) },
                cancel: { store.cancelMIDIControlLearn() },
                setBindings: { store.setMIDIControlBindings($0) },
                readBack: { (store.midiControlMap, store.midiControl.isSubscribed) })
            model.toggleLearn(.breathPadAngle)
            #expect(model.state.isLearning == true)
            model.toggleLearn(.breathPadAngle)
            #expect(model.state.isLearning == false)
            // Nothing was bound, so the feed is torn down again — the app must
            // not be left holding a MIDI client for a learn the user abandoned.
            #expect(store.midiControl.isSubscribed == false)
        }
    }

    /// A learn completed by a real controller turn names the device, because
    /// `arm` returned the list and the model cached it.
    @Test("a completed learn names the device it captured")
    func learnNamesTheDevice() async {
        await MainActor.run {
            let engine = SpyEngine()
            engine.midiInputs = [Self.keystation]
            let store = ProjectStore()
            store.engine = engine
            let model = BreathPadHardwareModel(
                arm: { store.armMIDIControlLearn(target: $0) },
                cancel: { store.cancelMIDIControlLearn() },
                setBindings: { store.setMIDIControlBindings($0) },
                readBack: { (store.midiControlMap, store.midiControl.isSubscribed) })
            model.toggleLearn(.breathPadRadius)
            // The knob turn, synthesised — no CoreMIDI, no hardware.
            store.pumpMIDIControl([MIDIControlChangeEvent(sourceID: 4242, channel: 0,
                                                          controller: 11, value: 127)])
            model.refresh(map: store.midiControlMap,
                          isSubscribed: store.midiControl.isSubscribed)
            let row = model.state.rows.first { $0.target == .breathPadRadius }
            #expect(row?.statusLine == "CC 11 · Keystation 49")
        }
    }

    // MARK: - The on-screen precision knobs

    /// A pad wired to a REAL `ProjectStore` — the `PadHarness` idiom from
    /// `HumanizeModelTests`: the panel's commit must be the same call the
    /// `clip.applyEffortShape` wire verb makes, and a fabricated
    /// `EffortShapeApplication` would prove nothing about the apply path.
    @MainActor final class KnobHarness {
        let store = ProjectStore()
        let clipID: UUID
        let trackID: UUID
        var applyCount = 0
        var previews: [PadPreviewPhase] = []

        init() throws {
            let track = store.addTrack(kind: .instrument)
            trackID = track.id
            let notes = (0..<4).map {
                MIDINote(pitch: 69, startBeat: Double($0) * 4, lengthBeats: 4)
            }
            clipID = try store.addMIDIClip(toTrack: track.id, lengthBeats: 17,
                                           notes: notes).id
        }

        func makeModel() -> BreathPadModel {
            let model = BreathPadModel(
                apply: { [self] clipID, ring, angle, radius, air in
                    applyCount += 1
                    return try store.applyEffortShape(clipID: clipID, ring: ring,
                                                      angleRadians: angle,
                                                      radius: radius, air: air)
                },
                // m34-f step ②: the seam now RETURNS the engine's capture verdict.
                // A recorder has no engine, so it has no answer — `nil` is the
                // documented third state and deliberately not `false`.
                preview: { [self] _, _, phase in previews.append(phase); return nil })
            model.prepare(clipID: clipID, trackID: trackID, clipName: "Sax", isMIDI: true)
            return model
        }
    }

    /// ⛔ THE LEAK THIS GUARD EXISTS TO PREVENT. `KnobControl`'s gesture is
    /// `DragGesture(minimumDistance: 0)`, so a plain CLICK fires `onChange` once
    /// with the value the knob already had and never fires `onCommit`. A model
    /// that opened a gesture on that tick would open one nothing ever closes —
    /// leaving a live controller preview parked on the instrument until
    /// `PadPreviewController`'s 30 s ceiling fired, which is exactly the state
    /// its rule 3 exists to prevent.
    @Test("a stray click on a precision knob opens no gesture, and streams nothing")
    func strayClickOpensNoGesture() async throws {
        try await MainActor.run {
            let h = try KnobHarness()
            let model = h.makeModel()
            // Exactly what the knob hands back on a zero-translation drag: the
            // fraction it was given.
            #expect(model.knobMoved(angleFraction: model.angleFraction) == false)
            #expect(model.knobMoved(radiusFraction: model.radiusFraction) == false)
            #expect(model.gesture == nil)
            #expect(h.previews.isEmpty, "a stray click streamed \(h.previews.count) preview(s)")
        }
    }

    @Test("a knob that actually moves opens a gesture and releases through the pad's own gate")
    func knobMoveOpensAndReleases() async throws {
        try await MainActor.run {
            let h = try KnobHarness()
            let model = h.makeModel()

            #expect(model.knobMoved(angleFraction: 0.25) == true)
            #expect(model.gesture == .pointer)      // NOT a third source
            #expect(abs(model.dot.angle - .pi / 2) < 1e-9)
            // The OTHER axis is untouched — one knob, one dimension.
            #expect(model.dot.radius == 1)
            #expect(h.previews.first == .begin)

            #expect(model.knobReleased() == true)
            #expect(model.gesture == nil)
            #expect(h.applyCount == 1)
            #expect(h.previews.last == .end)
        }
    }

    /// The round trip fraction → radians → fraction is what the guard compares,
    /// and it must be exact or a stray click leaks a gesture roughly whenever
    /// the last bit disagrees.
    @Test("the angle fraction round-trips exactly at every ring position")
    func angleFractionRoundTrips() async throws {
        try await MainActor.run {
            let h = try KnobHarness()
            let model = h.makeModel()
            for step in 0...64 {
                let f = Double(step) / 64
                model.setDot(angle: f * 2 * .pi, radius: 0.5)
                // Feeding back the fraction the knob would have been given must
                // read as "no movement" — every time, not just at nice angles.
                #expect(model.knobMoved(angleFraction: model.angleFraction) == false,
                        "opened a gesture at fraction \(f)")
                #expect(model.gesture == nil)
            }
        }
    }

    /// ⛔⛔ **ONE KNOB RESETS ONE AXIS — and this test is here because its first
    /// version asserted the opposite.**
    ///
    /// The original wired both `onReset` closures to a shared `resetKnobs()` that
    /// set angle 0 AND radius 1, so double-clicking DEPTH swung the ANGLE. The
    /// test passed, because it asserted exactly that coupling: a defect with a
    /// green gate certifying it. The lesson is not "write more tests" — it is
    /// that a test written from the implementation inherits the implementation's
    /// bugs as requirements. This one is written from the CONTRACT instead:
    /// `KnobControl.onReset` restores the value that knob displays, which is the
    /// behaviour every other knob in the app already has.
    @Test("each knob's double-click resets ONLY its own axis, and commits nothing")
    func resetIsPerAxis() async throws {
        try await MainActor.run {
            let h = try KnobHarness()
            let model = h.makeModel()

            model.setDot(angle: 2.0, radius: 0.3)
            model.resetAngle()
            #expect(model.dot.angle == 0)
            #expect(model.dot.radius == 0.3, "resetting ANGLE moved DEPTH")

            model.setDot(angle: 2.0, radius: 0.3)
            model.resetDepth()
            #expect(model.dot.radius == 1)
            #expect(model.dot.angle == 2.0, "resetting DEPTH swung ANGLE")

            // A reset is a re-aim, not an edit: nothing is written to the clip.
            #expect(h.applyCount == 0)
            #expect(model.gesture == nil)
            // ⛔ DEPTH resets to 1, NOT 0: radius 0 is the "exactly as written"
            // no-op, and a reset that silently disabled WRITE THE SHAPE would
            // read as broken.
            #expect(model.canApply == true)
        }
    }

    /// The hardware wins nothing while a hand is on a knob — the knob opens a
    /// `.pointer` gesture, so `pumpExternalControl`'s existing precedence rule
    /// covers it with no second rule to keep in step.
    @Test("a hardware turn is ignored while an on-screen knob holds the gesture")
    func pointerBeatsHardwareThroughTheKnob() async throws {
        try await MainActor.run {
            let h = try KnobHarness()
            let model = h.makeModel()
            #expect(model.knobMoved(angleFraction: 0.25) == true)
            let held = model.dot.angle
            model.pumpExternalControl(MIDIControlPump(updates: [
                MIDIControlUpdate(target: .breathPadAngle, value: 0.9,
                                  controller: 74, sourceID: 1),
            ]))
            #expect(model.dot.angle == held)
        }
    }

    /// ⭐ TWO-WAY, ASSERTED: a hardware turn moves the value the on-screen knob
    /// RENDERS. There is one dot and three ways to push it, not three copies of
    /// a position — and the knob reads `angleFraction`/`radiusFraction`, so this
    /// is the number the cap is drawn from.
    @Test("a hardware turn moves what the on-screen knobs render")
    func hardwareMovesTheOnScreenKnobs() async throws {
        try await MainActor.run {
            let h = try KnobHarness()
            let model = h.makeModel()
            model.pumpExternalControl(MIDIControlPump(updates: [
                MIDIControlUpdate(target: .breathPadAngle, value: 0.75,
                                  controller: 74, sourceID: 1),
                MIDIControlUpdate(target: .breathPadRadius, value: 0.4,
                                  controller: 75, sourceID: 1),
            ]))
            #expect(abs(model.angleFraction - 0.75) < 1e-9)
            #expect(abs(model.radiusFraction - 0.4) < 1e-9)
            #expect(model.gesture == .external)
        }
    }
}
