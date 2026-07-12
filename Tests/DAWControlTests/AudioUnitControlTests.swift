import DAWCore
import DAWEngine
import Foundation
import Testing
@testable import DAWControl

/// M3 (vi-a) Audio Unit control surface. The engine stand-in forwards
/// `availableAudioUnits` to the REAL enumeration (`AUHostRegistry`), so these
/// tests exercise the exact resolution path agents hit — everything else is a
/// no-op (no audio I/O, no instantiation).
@MainActor
private final class AUListingEngine: AudioEngineControlling {
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
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        completion(true)
    }
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }

    /// The real component enumeration — what makes strict selection testable.
    func availableAudioUnits() -> [AudioUnitComponentInfo] {
        AUHostRegistry.listMusicDevices()
    }

    /// The insert-effect mirror ('aufx'): fx.listAudioUnits and fx.add
    /// (kind audioUnit) resolve against exactly this list.
    func availableAudioUnitEffects() -> [AudioUnitComponentInfo] {
        AUHostRegistry.listEffectComponents()
    }
}

@MainActor
@Suite("CommandRouter — Audio Units")
struct AudioUnitControlTests {
    private func makeRouter() -> (CommandRouter, ProjectStore, AUListingEngine) {
        let store = ProjectStore()
        let engine = AUListingEngine()
        store.engine = engine
        return (CommandRouter(store: store), store, engine)
    }

    @Test("instrument.listAudioUnits returns Apple's stock devices")
    func listAudioUnitsCommandReturnsAppleDevices() async throws {
        let (router, _, engine) = makeRouter()
        _ = engine  // strong hold: store.engine is weak
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.listAudioUnits"))
        #expect(response.ok)
        guard case .array(let units)? = response.result?["audioUnits"] else {
            Issue.record("result has no audioUnits array"); return
        }
        #expect(!units.isEmpty)
        let dls = units.first {
            $0["subType"]?.stringValue == "dls " && $0["manufacturer"]?.stringValue == "appl"
        }
        let found = try #require(dls)
        #expect(found["type"]?.stringValue == "aumu")
        #expect(found["name"]?.stringValue?.isEmpty == false)
        #expect(found["manufacturerName"]?.stringValue?.isEmpty == false)
        #expect(found["isV3"]?.boolValue == false)  // DLS is a v2 component
        #expect(found["version"]?.stringValue != nil)
    }

    @Test("track.setInstrument audioUnit selection echoes the resolved descriptor")
    func setInstrumentAudioUnitSelectionEchoesResolvedDescriptor() async throws {
        let (router, store, engine) = makeRouter()
        _ = engine
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        // type omitted → defaults "aumu".
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID),
                     "audioUnit": .object(["subType": .string("dls "),
                                           "manufacturer": .string("appl")])]))
        #expect(response.ok)
        #expect(response.result?["kind"]?.stringValue == "audioUnit")
        let au = try #require(response.result?["audioUnit"])
        #expect(au["subType"]?.stringValue == "dls ")
        #expect(au["manufacturer"]?.stringValue == "appl")
        #expect(au["name"]?.stringValue?.isEmpty == false)         // resolved display name
        #expect(au["status"]?.stringValue?.isEmpty == false)       // status always present
        // The model landed the wholesale config with the resolved names.
        let descriptor = try #require(store.tracks[0].instrument)
        #expect(descriptor.kind == .audioUnit)
        #expect(descriptor.audioUnit?.name.isEmpty == false)
        #expect(descriptor.audioUnit?.stateData == nil)  // fresh selection: no state yet
    }

    @Test("fx.listAudioUnits returns Apple's stock 'aufx' effects")
    func fxListAudioUnitsReturnsAppleEffects() async throws {
        let (router, _, engine) = makeRouter()
        _ = engine  // strong hold: store.engine is weak
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.listAudioUnits"))
        #expect(response.ok)
        guard case .array(let units)? = response.result?["audioUnits"] else {
            Issue.record("result has no audioUnits array"); return
        }
        #expect(!units.isEmpty)
        let delay = units.first {
            $0["subType"]?.stringValue == "dely" && $0["manufacturer"]?.stringValue == "appl"
        }
        let found = try #require(delay)
        #expect(found["type"]?.stringValue == "aufx")
        #expect(found["name"]?.stringValue?.isEmpty == false)
        #expect(found["manufacturerName"]?.stringValue?.isEmpty == false)
    }

    @Test("fx.add kind audioUnit round-trips the resolved component on the wire and in the model")
    func fxAddAudioUnitRoundTripsComponent() async throws {
        let (router, store, engine) = makeRouter()
        _ = engine
        let trackID = store.addTrack(kind: .audio).id
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString),
                     "kind": .string("audioUnit"),
                     // type omitted → defaults "aufx".
                     "audioUnit": .object(["subType": .string("dely"),
                                           "manufacturer": .string("appl")])]))
        #expect(response.ok)
        let effect = try #require(response.result?["effects"]?.arrayValue?.first)
        #expect(effect["kind"]?.stringValue == "audioUnit")
        #expect(effect["params"]?["type"]?.stringValue == "aufx")
        #expect(effect["params"]?["subType"]?.stringValue == "dely")
        #expect(effect["params"]?["manufacturer"]?.stringValue == "appl")
        #expect(effect["params"]?["name"]?.stringValue?.isEmpty == false)
        // The model landed the wholesale config with the resolved names.
        let descriptor = try #require(store.tracks[0].effects.first)
        #expect(descriptor.kind == .audioUnit)
        #expect(descriptor.audioUnit?.component.subType == "dely")
        #expect(descriptor.audioUnit?.name.isEmpty == false)
        #expect(descriptor.audioUnit?.stateData == nil)  // fresh selection: no state yet
    }

    @Test("fx.add audioUnit with an unknown component fails readably, nothing added")
    func fxAddUnknownAudioUnitFailsReadably() async throws {
        let (router, store, engine) = makeRouter()
        _ = engine
        let trackID = store.addTrack(kind: .audio).id
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString),
                     "kind": .string("audioUnit"),
                     "audioUnit": .object(["subType": .string("zzzz"),
                                           "manufacturer": .string("zzzz")])]))
        #expect(!response.ok)
        #expect(response.error == "no installed Audio Unit matches aufx/zzzz/zzzz — see fx.listAudioUnits")
        #expect(store.tracks[0].effects.isEmpty)  // strict selection: nothing landed
    }

    @Test("fx.add kind audioUnit without a component errors at the store boundary")
    func fxAddAudioUnitWithoutComponentErrors() async throws {
        let (router, store, engine) = makeRouter()
        _ = engine
        let trackID = store.addTrack(kind: .audio).id
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString),
                     "kind": .string("audioUnit")]))
        #expect(!response.ok)
        #expect(response.error == "an audioUnit effect requires a component selection — pass audioUnit {type?, subType, manufacturer} (see fx.listAudioUnits)")
        #expect(store.tracks[0].effects.isEmpty)
    }

    @Test("track.setInstrument with an unknown component fails readably")
    func setInstrumentUnknownAudioUnitFailsReadably() async throws {
        let (router, store, engine) = makeRouter()
        _ = engine
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID),
                     "audioUnit": .object(["subType": .string("zzzz"),
                                           "manufacturer": .string("zzzz")])]))
        #expect(!response.ok)
        #expect(response.error == "no installed Audio Unit matches aumu/zzzz/zzzz — see instrument.listAudioUnits")
        // Strict selection: nothing landed on the track.
        #expect(store.tracks[0].instrument == nil)
    }
}
