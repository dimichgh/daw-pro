import Foundation
import Testing
@testable import AIServices
@testable import DAWControl
@testable import DAWCore

/// p2-sing-e part 2: `project.transpose` (design §6 row 17, §3.6) through the router, with a SPY in front of
/// `ProjectStore.transposeProject` (W7-PK's store door, THE only way the song's key changes).
@Suite("SingWire — project.transpose reaches ProjectStore.transposeProject (p2-sing-e)")
struct SingWireTransposeTests {

    struct Rig {
        let router: CommandRouter
        let store: ProjectStore
        let clipID: UUID
        let spy: SingWireTransposeSpy
    }

    private func rig() async throws -> Rig {
        let root = try SingWireFixture.tempDir("transpose")
        return try await MainActor.run {
            let (store, clipID) = try SingWireFixture.store(root: root)
            let spy = SingWireTransposeSpy(store: store)
            return Rig(router: CommandRouter(store: store, singTranspose: spy), store: store, clipID: clipID, spy: spy)
        }
    }

    private func pitches(_ rig: Rig) async -> [Int] {
        await MainActor.run {
            (rig.store.tracks.flatMap(\.clips).first { $0.id == rig.clipID }?.notes ?? []).map(\.pitch)
        }
    }

    @Test("SPY: the wire reaches transposeProject with the parsed params; the song moves as ONE undo step")
    func transposeReachesTransposeProject() async throws {
        let rig = try await rig()
        let before = await pitches(rig)
        let response = await rig.router.handle(SingWireFixture.request("project.transpose", ["semitones": .number(2)]))
        #expect(response.ok, "\(response.error ?? "")")
        #expect(await MainActor.run { rig.spy.calls } == [.init(semitones: 2, excludeTrackIds: [], dryRun: false)])
        #expect(response.result?["semitones"]?.doubleValue == 2)
        #expect(response.result?["applied"]?.boolValue == true)
        #expect(response.result?["notesMoved"]?.doubleValue == 8)
        #expect(await pitches(rig) == before.map { $0 + 2 })
        _ = try await MainActor.run { try rig.store.undo() }
        #expect(await pitches(rig) == before)
    }

    @Test("dryRun and excludeTrackIds reach the store as given; a dry run changes nothing")
    func dryRunAndExclusionsPassThrough() async throws {
        let rig = try await rig()
        let before = await pitches(rig)
        let trackID = await MainActor.run { rig.store.tracks.first { $0.clips.contains { $0.id == rig.clipID } }!.id }
        let response = await rig.router.handle(SingWireFixture.request("project.transpose", [
            "semitones": .number(-3), "excludeTrackIds": .array([.string(trackID.uuidString)]), "dryRun": .bool(true)]))
        #expect(response.ok, "\(response.error ?? "")")
        #expect(await MainActor.run { rig.spy.calls } == [.init(semitones: -3, excludeTrackIds: [trackID], dryRun: true)])
        #expect(response.result?["dryRun"]?.boolValue == true)
        #expect(await pitches(rig) == before)
    }

    @Test("refusals read \"<code>: <message>\" with the store's own words, and nothing moves")
    func refusalsAreExact() async throws {
        let rig = try await rig()
        let before = await pitches(rig)
        let unknownTrack = UUID()
        let cases: [([String: JSONValue], String)] = [
            (["semitones": .number(13)],
             "transposeOutOfRange: A key change moves the song by a whole number of semitones, from 12 down to 12 "
                 + "up (one octave either way); 13 is not one of those. Nothing was changed."),
            (["semitones": .number(2.5)],
             "transposeOutOfRange: A key change moves the song by a whole number of semitones, from 12 down to 12 "
                 + "up (one octave either way); 2.5 is not one of those. Nothing was changed."),
            (["semitones": .number(1), "excludeTrackIds": .array([.string(unknownTrack.uuidString)])],
             "trackNotFound: No track with id \(unknownTrack.uuidString)."),
            ([:], "missing or invalid required param 'semitones' (a whole number from -12 to 12)"),
            (["semitones": .number(1), "key": .string("C")],
             "project.transpose: unknown parameter 'key' — valid keys are 'dryRun', 'excludeTrackIds', 'semitones'"),
        ]
        for (params, expected) in cases {
            let response = await rig.router.handle(SingWireFixture.request("project.transpose", params))
            #expect(response.error == expected)
        }
        #expect(await pitches(rig) == before)
    }

    @Test("a note pushed past MIDI 127 is refused by the store's own check (transposeNoteOutOfRange)")
    func noteOutOfRangeIsTheStoresRefusal() async throws {
        let root = try SingWireFixture.tempDir("transpose-high")
        let (router, store) = try await MainActor.run { () -> (CommandRouter, ProjectStore) in
            let (store, _) = try SingWireFixture.store(root: root, pitches: [125])
            return (CommandRouter(store: store), store)
        }
        let response = await router.handle(SingWireFixture.request("project.transpose", ["semitones": .number(5)]))
        #expect(response.error?.hasPrefix("transposeNoteOutOfRange: ") == true, "\(response.error ?? "")")
        let expected = await MainActor.run { () -> String? in
            do {
                _ = try store.transposeProject(semitones: 5, dryRun: true)
                return nil
            } catch let refusal as TransposeRefusal {
                return refusal.message
            } catch {
                return nil
            }
        }
        #expect(response.error == "transposeNoteOutOfRange: \(expected ?? "?")")
    }
}
