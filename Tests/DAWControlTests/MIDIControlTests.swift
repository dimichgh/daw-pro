import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// M3 (vii) control surface: midi.listInputs, instrument-track arming through
/// track.setArm, and the snapshot's midiInputs/midiEventCount fields.
@MainActor
final class FakeMIDIEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    var midiInputs: [MIDIInputDevice] = []
    var eventCount = 0

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

    /// How many times the MIDI client's bring-up path was asked for. The
    /// discriminator for "learn actually woke CoreMIDI up" (m28-knob) — an
    /// armed learn against a client that never existed hears nothing, and
    /// "turn the knob, nothing happens" is indistinguishable from a bug.
    var midiInputsRequestCount = 0
    func availableMIDIInputs() -> [MIDIInputDevice] {
        midiInputsRequestCount += 1
        return midiInputs
    }
    func midiEventCount() -> Int { eventCount }

    /// The installed m28-knob controller sink. Holding it lets a test drive the
    /// WHOLE chain from the engine seam inwards, with no CoreMIDI and no knob.
    var controlObserver: (@MainActor ([MIDIControlChangeEvent]) -> Void)?
    func setControlChangeObserver(
        _ observer: (@MainActor ([MIDIControlChangeEvent]) -> Void)?) {
        controlObserver = observer
    }
}

@MainActor
@Suite("MIDI control surface")
struct MIDIControlTests {
    private func makeRouter(engine: FakeMIDIEngine) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.engine = engine
        return (CommandRouter(store: store), store)
    }

    @Test("midi.listInputs returns the engine's devices (and is a known command)")
    func midiListInputsReturnsEngineDevices() async {
        let engine = FakeMIDIEngine()
        engine.midiInputs = [
            MIDIInputDevice(uniqueID: 42, name: "Test Keys", isVirtual: false, isOnline: true),
            MIDIInputDevice(uniqueID: -7, name: "Virtual Src", isVirtual: true, isOnline: false),
        ]
        let (router, _) = makeRouter(engine: engine)

        #expect(CommandRouter.allCommands.contains("midi.listInputs"))
        let response = await router.handle(ControlRequest(id: "1", command: "midi.listInputs"))
        #expect(response.ok)
        let inputs = response.result?["inputs"]?.arrayValue
        #expect(inputs?.count == 2)
        #expect(inputs?[0]["uniqueID"]?.doubleValue == 42)
        #expect(inputs?[0]["name"]?.stringValue == "Test Keys")
        #expect(inputs?[0]["isVirtual"]?.boolValue == false)
        #expect(inputs?[0]["isOnline"]?.boolValue == true)
        #expect(inputs?[1]["uniqueID"]?.doubleValue == -7)
        #expect(inputs?[1]["isVirtual"]?.boolValue == true)
    }

    @Test("track.setArm accepts instrument tracks; bus still errors readably")
    func trackSetArmAcceptsInstrumentTracks() async {
        let engine = FakeMIDIEngine()
        let (router, store) = makeRouter(engine: engine)
        let inst = store.addTrack(kind: .instrument)
        let bus = store.addTrack(kind: .bus)

        let armed = await router.handle(ControlRequest(
            id: "1", command: "track.setArm",
            params: ["trackId": .string(inst.id.uuidString), "armed": .bool(true)]))
        #expect(armed.ok)
        #expect(store.tracks[0].isArmed)

        let refused = await router.handle(ControlRequest(
            id: "2", command: "track.setArm",
            params: ["trackId": .string(bus.id.uuidString), "armed": .bool(true)]))
        #expect(!refused.ok)
        #expect(refused.error?.contains("bus") == true)
    }

    @Test("project.snapshot carries midiInputs and midiEventCount")
    func snapshotCarriesMIDIInputsAndEventCount() async {
        let engine = FakeMIDIEngine()
        engine.midiInputs = [
            MIDIInputDevice(uniqueID: 7, name: "Pad", isVirtual: true, isOnline: true),
        ]
        engine.eventCount = 123
        let (router, _) = makeRouter(engine: engine)

        let response = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        #expect(response.ok)
        #expect(response.result?["midiEventCount"]?.doubleValue == 123)
        let inputs = response.result?["midiInputs"]?.arrayValue
        #expect(inputs?.count == 1)
        #expect(inputs?[0]["name"]?.stringValue == "Pad")
        #expect(inputs?[0]["uniqueID"]?.doubleValue == 7)
    }

    // MARK: - The CC→target mapping trio (m28-knob)

    /// ⛔ **PLACEMENT IS PINNED HERE, IN ONE FILE, ON PURPOSE** (the
    /// `PadPreviewCommandTests.verbIsRegistered` precedent). The trio sits
    /// immediately after `midi.listInputs` — its only sibling on this surface —
    /// and therefore BEFORE `transport.record`, which is load-bearing and not
    /// cosmetic: `ControlTests`' route-coverage loop walks `allCommands` IN
    /// ORDER and is mid-take from `transport.record` onwards.
    ///
    /// Without this pin, a later tidy-up that appends the verbs to the tail
    /// reddens ~22 unrelated files with count and offset failures and nothing
    /// says why. With it, the reason fails in one place.
    @Test("the trio is registered next to midi.listInputs, before transport.record, NOT at the tail")
    func theTrioIsRegisteredBesideItsSibling() {
        let all = CommandRouter.allCommands
        guard let anchor = all.firstIndex(of: "midi.listInputs") else {
            Issue.record("midi.listInputs vanished — the anchor this placement rests on")
            return
        }
        #expect(Array(all[anchor...(anchor + 3)]) == [
            "midi.listInputs", "midi.getControlMap", "midi.setControlMap", "midi.learnControl",
        ])
        guard let record = all.firstIndex(of: "transport.record") else {
            Issue.record("transport.record vanished")
            return
        }
        #expect(anchor + 3 < record, "the trio must sit BEFORE the mid-take verbs")
        for verb in ["midi.getControlMap", "midi.setControlMap", "midi.learnControl"] {
            #expect(all.firstIndex(of: verb) != all.count - 1, "\(verb) must NOT be at the tail")
        }
    }

    private func binding(_ target: String, controller: Int,
                         extra: [String: JSONValue] = [:]) -> JSONValue {
        var out: [String: JSONValue] = [
            "target": .string(target),
            "controller": .number(Double(controller)),
        ]
        for (key, value) in extra { out[key] = value }
        return .object(out)
    }

    /// The catalogue is what makes the table self-describing: an agent that can
    /// only read `bindings` cannot discover what it is allowed to bind TO.
    ///
    /// ⚠️ And `midi.getControlMap` is PASSIVE — reading a table must not open
    /// the user's MIDI devices. `midi.learnControl` is the verb that does, and
    /// the request count is how the two are told apart.
    @Test("midi.getControlMap publishes the catalogue and does NOT wake CoreMIDI")
    func getControlMapIsPassiveAndSelfDescribing() async {
        let engine = FakeMIDIEngine()
        let (router, _) = makeRouter(engine: engine)

        let response = await router.handle(ControlRequest(id: "1", command: "midi.getControlMap"))
        #expect(response.ok)
        #expect(response.result?["bindings"]?.arrayValue?.isEmpty == true)
        #expect(response.result?["subscribed"]?.boolValue == false)
        #expect(response.result?["learningTarget"] == nil, "omitted, not null, while disarmed")
        #expect(response.result?["lastControlChange"] == nil)

        let targets = response.result?["targets"]?.arrayValue
        #expect(targets?.count == MIDIControlTarget.allCases.count)
        #expect(targets?.contains { $0["id"]?.stringValue == "breathPadAngle" } == true)
        #expect(targets?.allSatisfy { ($0["summary"]?.stringValue?.count ?? 0) >= 40 } == true)

        #expect(engine.midiInputsRequestCount == 0,
                "reading the map must not bring the CoreMIDI client up")
        #expect(engine.controlObserver == nil, "nothing to route yet, so no subscription")
    }

    /// A full SET, so an agent reads the map and writes it back idempotently.
    @Test("midi.setControlMap replaces the whole table, subscribes, and [] clears")
    func setControlMapReplacesTheWholeTable() async {
        let engine = FakeMIDIEngine()
        let (router, store) = makeRouter(engine: engine)

        let set = await router.handle(ControlRequest(
            id: "1", command: "midi.setControlMap",
            params: ["bindings": .array([
                binding("breathPadAngle", controller: 74,
                        extra: ["sourceId": .number(42), "inverted": .bool(true)]),
                binding("breathPadRadius", controller: 71, extra: ["channel": .number(3)]),
            ])]))
        #expect(set.ok)
        let bindings = set.result?["bindings"]?.arrayValue
        #expect(bindings?.count == 2)
        #expect(set.result?["subscribed"]?.boolValue == true)
        #expect(engine.controlObserver != nil, "a live table must be subscribed to the engine")
        #expect(store.midiControlMap.binding(for: .breathPadAngle)?.inverted == true)
        #expect(store.midiControlMap.binding(for: .breathPadRadius)?.channel == 3)

        // The catalogue reports which control drives each target.
        let angleEntry = set.result?["targets"]?.arrayValue?
            .first { $0["id"]?.stringValue == "breathPadAngle" }
        #expect(angleEntry?["controller"]?.doubleValue == 74)
        #expect(angleEntry?["sourceId"]?.doubleValue == 42)

        // Read-back is the same table.
        let read = await router.handle(ControlRequest(id: "2", command: "midi.getControlMap"))
        #expect(read.result?["bindings"]?.arrayValue?.count == 2)

        // `[]` clears it AND unsubscribes — no table, no reason to hold the
        // CoreMIDI feed open.
        let cleared = await router.handle(ControlRequest(
            id: "3", command: "midi.setControlMap", params: ["bindings": .array([])]))
        #expect(cleared.ok)
        #expect(cleared.result?["bindings"]?.arrayValue?.isEmpty == true)
        #expect(cleared.result?["subscribed"]?.boolValue == false)
        #expect(engine.controlObserver == nil)
    }

    @Test("midi.setControlMap refuses malformed bindings readably")
    func setControlMapRefusesMalformedBindings() async {
        let engine = FakeMIDIEngine()
        let (router, store) = makeRouter(engine: engine)

        let noBindings = await router.handle(ControlRequest(
            id: "1", command: "midi.setControlMap"))
        #expect(!noBindings.ok)
        #expect(noBindings.error?.contains("bindings") == true)

        let badTarget = await router.handle(ControlRequest(
            id: "2", command: "midi.setControlMap",
            params: ["bindings": .array([binding("padAngle", controller: 74)])]))
        #expect(!badTarget.ok)
        #expect(badTarget.error?.contains("breathPadAngle") == true,
                "the refusal must NAME the legal targets")

        let badController = await router.handle(ControlRequest(
            id: "3", command: "midi.setControlMap",
            params: ["bindings": .array([binding("breathPadAngle", controller: 200)])]))
        #expect(!badController.ok)
        #expect(badController.error?.contains("0…127") == true)

        let badChannel = await router.handle(ControlRequest(
            id: "4", command: "midi.setControlMap",
            params: ["bindings": .array([
                binding("breathPadAngle", controller: 74,
                        extra: ["channel": .number(99)])])]))
        #expect(!badChannel.ok)

        let strayKey = await router.handle(ControlRequest(
            id: "5", command: "midi.setControlMap",
            params: ["bindings": .array([]), "mode": .string("absolute")]))
        #expect(!strayKey.ok, "rejectUnknownKeys must reject a key the schema does not have")

        // Not one refusal left a partial table behind.
        #expect(store.midiControlMap.bindings.isEmpty)
    }

    /// ⭐ **ARMING BRINGS THE MIDI CLIENT UP** — the whole reason learn is its
    /// own verb. And when there is nothing online it SAYS SO, instead of leaving
    /// a learn armed against silence.
    @Test("midi.learnControl wakes CoreMIDI, arms, and reports what it can see")
    func learnControlWakesTheClientAndReportsInputs() async {
        let engine = FakeMIDIEngine()
        let (router, _) = makeRouter(engine: engine)

        // Nothing connected: armed, but the response says why nothing will come.
        let empty = await router.handle(ControlRequest(
            id: "1", command: "midi.learnControl",
            params: ["target": .string("breathPadAngle")]))
        #expect(empty.ok)
        #expect(engine.midiInputsRequestCount >= 1, "learn must bring the client UP")
        #expect(empty.result?["learningTarget"]?.stringValue == "breathPadAngle")
        #expect(empty.result?["inputs"]?.arrayValue?.isEmpty == true)
        #expect(empty.result?["hint"]?.stringValue?.contains("no ONLINE MIDI input") == true)
        #expect(engine.controlObserver != nil, "an armed learn subscribes to the feed")

        // With a controller connected the hint tells the user what to do.
        engine.midiInputs = [
            MIDIInputDevice(uniqueID: 42, name: "Keys", isVirtual: false, isOnline: true),
        ]
        let armed = await router.handle(ControlRequest(
            id: "2", command: "midi.learnControl",
            params: ["target": .string("breathPadRadius")]))
        #expect(armed.ok)
        #expect(armed.result?["inputs"]?.arrayValue?.count == 1)
        #expect(armed.result?["hint"]?.stringValue?.contains("Turn the knob") == true)

        // Cancel disarms and, with nothing bound, unsubscribes.
        let cancelled = await router.handle(ControlRequest(
            id: "3", command: "midi.learnControl", params: ["cancel": .bool(true)]))
        #expect(cancelled.ok)
        #expect(cancelled.result?["learningTarget"] == nil)
        #expect(cancelled.result?["subscribed"]?.boolValue == false)
        #expect(engine.controlObserver == nil)

        let badTarget = await router.handle(ControlRequest(
            id: "4", command: "midi.learnControl", params: ["target": .string("nope")]))
        #expect(!badTarget.ok)
        #expect(badTarget.error?.contains("cancel") == true)
    }

    /// ⛔ **THE WHOLE CHAIN, DRIVEN FROM THE ENGINE SEAM, WITH NO HARDWARE.**
    /// The observer the store installed IS the one `MIDIInputManager` calls from
    /// its 30 Hz drain, so feeding it here exercises everything downstream of
    /// the ring: learn, resolve, and delivery to the subscriber.
    @Test("a synthesised knob turn learns, then steers, all the way through")
    func aSynthesisedKnobTurnDrivesTheWholeChain() async {
        let engine = FakeMIDIEngine()
        engine.midiInputs = [
            MIDIInputDevice(uniqueID: 42, name: "Keys", isVirtual: false, isOnline: true),
        ]
        let (router, store) = makeRouter(engine: engine)
        var passes: [MIDIControlPump] = []
        store.midiControl.pumpHandler = { passes.append($0) }

        _ = await router.handle(ControlRequest(
            id: "1", command: "midi.learnControl",
            params: ["target": .string("breathPadAngle")]))
        let observer = try? #require(engine.controlObserver)

        // Turn the knob. It BINDS and moves the target on the very same event —
        // a knob that binds and then visibly does nothing until you turn it
        // again is indistinguishable from a learn that failed.
        observer?([MIDIControlChangeEvent(sourceID: 42, channel: 5,
                                          controller: 74, value: 127)])
        #expect(store.midiControlMap.binding(for: .breathPadAngle)?.controller == 74)
        #expect(passes.count == 1)
        #expect(passes.first?.updates.map(\.target) == [.breathPadAngle])
        #expect(passes.first?.updates.first?.value == 1.0)

        // A second turn just steers — and an unmapped CC steers nothing while
        // still being SEEN, which is the "is my knob even sending?" diagnostic.
        observer?([MIDIControlChangeEvent(sourceID: 42, channel: 5,
                                          controller: 74, value: 0)])
        observer?([MIDIControlChangeEvent(sourceID: 42, channel: 5,
                                          controller: 11, value: 60)])
        #expect(passes.count == 3)
        #expect(passes[1].updates.first?.value == 0)
        #expect(passes[2].updates.isEmpty)

        let read = await router.handle(ControlRequest(id: "2", command: "midi.getControlMap"))
        #expect(read.result?["lastControlChange"]?["controller"]?.doubleValue == 11)
        #expect(read.result?["lastControlChange"]?["value"]?.doubleValue == 60)

        // ⭐ The IDLE TICK survives the whole chain: an empty pass from the
        // engine reaches the subscriber, because that is the only "release" a
        // knob has.
        observer?([])
        #expect(passes.count == 4)
        #expect(passes[3].updates.isEmpty)
        #expect(passes[3].feedEnded == false)
    }

    /// The feed dying mid-turn is announced, not silently stopped — otherwise a
    /// subscriber waits forever for an idle tick that is never coming, holding a
    /// live controller preview on the instrument.
    @Test("removing the last binding announces the feed's end")
    func removingTheLastBindingAnnouncesTheFeedEnd() async {
        let engine = FakeMIDIEngine()
        let (router, store) = makeRouter(engine: engine)
        var passes: [MIDIControlPump] = []
        store.midiControl.pumpHandler = { passes.append($0) }

        _ = await router.handle(ControlRequest(
            id: "1", command: "midi.setControlMap",
            params: ["bindings": .array([binding("breathPadAngle", controller: 74)])]))
        #expect(passes.isEmpty)

        _ = await router.handle(ControlRequest(
            id: "2", command: "midi.setControlMap", params: ["bindings": .array([])]))
        #expect(passes.count == 1)
        #expect(passes.first?.feedEnded == true)
    }

    // MARK: - The engine swap

    /// ⚠️ **"THE SETTER RETURNED, SO IT TOOK" — the shape `reattach` exists for.**
    /// `refreshSubscription` is LATCHED on `isSubscribed`, so across an engine
    /// swap the latch says *subscribed* while the NEW engine has never heard of
    /// us. Every state variable insists the feed is live; the knob is dead.
    /// Nothing else in this suite exercises the swap — `makeRouter` assigns the
    /// engine BEFORE any binding exists, so `reattach`'s guard short-circuits in
    /// every other test here and the path was untested.
    @Test("a new engine picks the subscription up — the latch does not strand it")
    func swappingTheEngineReattachesTheLiveSubscription() async {
        let first = FakeMIDIEngine()
        let (router, store) = makeRouter(engine: first)
        _ = await router.handle(ControlRequest(
            id: "1", command: "midi.setControlMap",
            params: ["bindings": .array([binding("breathPadAngle", controller: 74)])]))
        #expect(first.controlObserver != nil, "precondition: the first engine is subscribed")

        let second = FakeMIDIEngine()
        store.engine = second

        #expect(second.controlObserver != nil, """
            the new engine was never subscribed. The `isSubscribed` latch still reads true, \
            `midi.getControlMap` still reports subscribed:true, and the mapped knob is silent.
            """)
        #expect(store.midiControl.isSubscribed)

        // And it is the LIVE path, not merely a non-nil closure: drive the new
        // engine's observer and watch the dot's feed move.
        var passes: [MIDIControlPump] = []
        store.midiControl.pumpHandler = { passes.append($0) }
        second.controlObserver?([MIDIControlChangeEvent(
            sourceID: 7, channel: 0, controller: 74, value: 127, hostTime: 0)])
        #expect(passes.first?.updates.first?.target == .breathPadAngle)
        #expect(passes.first?.updates.first?.value == 1.0)
    }

    /// ⛔ **A LATCH THAT LIES IS WORSE THAN NO LATCH.** With no engine attached
    /// there is nothing to subscribe to, so `subscribed` must read FALSE — an
    /// agent that sets a map headless and is told `subscribed: true` has been
    /// handed a working-looking answer for a feed that does not exist (this
    /// tree's characteristic failure mode). And when an engine later arrives,
    /// the wanted subscription must go live on it, or "bind before the engine
    /// exists" would be a permanently dead knob.
    @Test("a table set with NO engine reads unsubscribed, then goes live when one arrives")
    func aTableSetBeforeTheEngineExistsGoesLiveWhenItArrives() async {
        let store = ProjectStore()          // deliberately NO engine
        let router = CommandRouter(store: store)
        var passes: [MIDIControlPump] = []
        store.midiControl.pumpHandler = { passes.append($0) }

        _ = await router.handle(ControlRequest(
            id: "1", command: "midi.setControlMap",
            params: ["bindings": .array([binding("breathPadRadius", controller: 11)])]))

        let read = await router.handle(ControlRequest(
            id: "2", command: "midi.getControlMap", params: [:]))
        #expect(read.result?["bindings"]?.arrayValue?.count == 1,
                "POSITIVE CONTROL: the table itself must survive with no engine — only the SUBSCRIPTION is absent")
        #expect(read.result?["subscribed"]?.boolValue == false, """
            reported subscribed:true with no engine attached. Nothing is listening; that is a \
            working-looking answer for a feed that does not exist.
            """)
        #expect(passes.isEmpty, "nothing was ever live, so there is no feed end to announce")

        let engine = FakeMIDIEngine()
        store.engine = engine
        #expect(engine.controlObserver != nil, """
            the engine arrived and the already-wanted subscription did not follow it — a map \
            bound before the engine exists would be dead forever.
            """)
        #expect(store.midiControl.isSubscribed)
    }

    /// The other side of the swap: an engine that goes AWAY mid-ride must
    /// announce the feed's end, exactly as un-binding does. Otherwise a
    /// subscriber holds an external gesture open waiting for an idle tick from a
    /// feed that no longer exists.
    @Test("losing the engine mid-ride announces the feed's end")
    func losingTheEngineAnnouncesTheFeedEnd() async {
        let engine = FakeMIDIEngine()
        let (router, store) = makeRouter(engine: engine)
        _ = await router.handle(ControlRequest(
            id: "1", command: "midi.setControlMap",
            params: ["bindings": .array([binding("breathPadAngle", controller: 74)])]))
        var passes: [MIDIControlPump] = []
        store.midiControl.pumpHandler = { passes.append($0) }

        store.engine = nil

        #expect(passes.count == 1, "the feed died and said nothing")
        #expect(passes.first?.feedEnded == true)
        #expect(store.midiControl.isSubscribed == false,
                "the latch outlived the engine it describes")
    }
}
