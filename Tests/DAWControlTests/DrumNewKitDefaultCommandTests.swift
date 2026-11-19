import DAWCore
import Foundation
import Testing
@testable import DAWControl

// W9-DRUMDEF (m39-hat-default + m39-dm-gm-default) — the WIRE half: a drum machine
// born over `track.setInstrument`, a partial `drumKit` on a fresh track, a preset,
// and what `instrument.describeDrumKit` tells an agent about each.
//
// ⛔ AN EXTENSION OF `DrumKitCommandTests`, NOT A NEW SUITE (no new `@MainActor`
// suite). Its helpers are `private`, so this file carries its own two.
extension DrumKitCommandTests {

    fileprivate func w9Call(_ router: CommandRouter, _ verb: String,
                            _ params: [String: JSONValue]) async -> ControlResponse {
        await router.handle(ControlRequest(id: "1", command: verb, params: params))
    }

    fileprivate func w9Payload(_ response: ControlResponse) throws -> JSONValue {
        guard response.ok, let result = response.result else {
            Issue.record(Comment(rawValue: "expected success, got \(response.error ?? "nil")"))
            throw CancellationError()
        }
        return result
    }

    @Test("W9-DRUMDEF: kind drumSynth over the wire births the picks; describe says so, with the GM notes")
    func w9WireBirthIsTheNewKit() async throws {
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        let echo = try w9Payload(await w9Call(router, "track.setInstrument", [
            "trackId": .string(id.uuidString), "kind": .string("drumSynth"),
        ]))
        #expect(echo["drumKit"]?["noteLayout"]?.stringValue == "gm")
        #expect(echo["drumKit"]?["hatsLevelDb"]?.doubleValue == 23.4)
        #expect(echo["drumKit"]?["cymbalsLevelDb"]?.doubleValue == 5.7)
        #expect(store.tracks.first { $0.id == id }?.instrument?.drumKit == DrumKitParams.newDrumMachineKit)

        let described = try w9Payload(await w9Call(router, "instrument.describeDrumKit", [
            "trackId": .string(id.uuidString),
        ]))
        #expect(described["isConfigured"]?.boolValue == true)
        #expect(described["noteLayout"]?.stringValue == "gm")
        #expect(described["kit"]?["hatsLevelDb"]?["value"]?.doubleValue == 23.4)
        #expect(described["kit"]?["hatsLevelDb"]?["default"]?.doubleValue == 23.4)
        #expect(described["kit"]?["cymbalsLevelDb"]?["value"]?.doubleValue == 5.7)
        #expect(described["kit"]?["cymbalsLevelDb"]?["default"]?.doubleValue == 5.7)
        let snareNotes = described["voiceNotes"]?["snare"]?.arrayValue?.compactMap(\.doubleValue)
        #expect(snareNotes == [38, 40], "a new drum machine's snare is not on the General MIDI keys")
    }

    /// A partial `drumKit` sent WITH `kind: "drumSynth"` on a track that is not a
    /// drum machine yet overlays the NEW kit, not the old factory one.
    @Test("W9-DRUMDEF: a partial drumKit that births a drum machine overlays the new kit")
    func w9PartialKitOnABirth() async throws {
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        _ = try w9Payload(await w9Call(router, "track.setInstrument", [
            "trackId": .string(id.uuidString), "kind": .string("drumSynth"),
            "drumKit": .object(["kick": .object(["decay": .number(0.9)])]),
        ]))
        var expected = DrumKitParams.newDrumMachineKit
        expected.setValue(0.9, forParamName: "kick.decay")
        #expect(store.tracks.first { $0.id == id }?.instrument?.drumKit == expected)
    }

    /// A preset on a NEW drum machine keeps the General MIDI keys and the picked
    /// levels. On a saved never-edited one it keeps the pad keys and RAISES the
    /// hats to the new level — loading a preset is an edit.
    @Test("W9-DRUMDEF: a preset keeps the layout and brings the picked hat and cymbal levels")
    func w9PresetOnNewAndSavedDrumMachines() async throws {
        let nine = try #require(DrumKitParams.preset(named: "909"))
        // New.
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        _ = try w9Payload(await w9Call(router, "track.setInstrument", [
            "trackId": .string(id.uuidString), "kind": .string("drumSynth"),
        ]))
        let loaded = try w9Payload(await w9Call(router, "instrument.loadDrumPreset", [
            "trackId": .string(id.uuidString), "name": .string("909"),
        ]))
        #expect(loaded["replacedAllParameters"]?.boolValue == true)
        #expect(loaded["noteLayout"]?.stringValue == "gm")
        #expect(loaded["drumKit"]?["hatsLevelDb"]?.doubleValue == 23.4)
        #expect(store.tracks.first { $0.id == id }?.instrument?.drumKit
                    == DrumKitParams.newDrumMachineKit.applyingPreset(nine))
        // Saved, never edited.
        let saved = Track(name: "Old Drums", kind: .instrument, instrument: InstrumentDescriptor(kind: .drumSynth))
        let oldStore = ProjectStore(tracks: [saved])
        let oldRouter = CommandRouter(store: oldStore)
        let described = try w9Payload(await w9Call(oldRouter, "instrument.describeDrumKit", [
            "trackId": .string(saved.id.uuidString),
        ]))
        #expect(described["isConfigured"]?.boolValue == false)
        #expect(described["noteLayout"]?.stringValue == "pads")
        #expect(described["kit"]?["hatsLevelDb"]?["value"]?.doubleValue == 0)
        let oldLoaded = try w9Payload(await w9Call(oldRouter, "instrument.loadDrumPreset", [
            "trackId": .string(saved.id.uuidString), "name": .string("909"),
        ]))
        #expect(oldLoaded["noteLayout"]?.stringValue == "pads", "a preset moved a saved song's drums")
        #expect(oldLoaded["drumKit"]?["hatsLevelDb"]?.doubleValue == 23.4)
    }
}
