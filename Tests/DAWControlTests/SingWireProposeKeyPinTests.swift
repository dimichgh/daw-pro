import CryptoKit
import Foundation
import Testing
@testable import AIServices
@testable import DAWControl
@testable import DAWCore

/// p2-sing-x9-f3 (W8-X9F3B): `sing.proposeKey` replies byte for byte as it did before a harmony part got its own fit
/// rule. The key proposal keeps `KeyFitWeights.octaveOnlyAcceptOutOfBand`; only `HarmonyPlanner`'s fit reads the new
/// harmony fields. Captured on the tree BEFORE the edit (`$S/w8/X9F3B/before.log`), canonicalised by `X7APin.canonical`
/// (sorted keys, ids replaced by placeholders) with the saved voice's id replaced by `<voice>`.
///
/// Fixtures: seven melodies (the SE1 two-unit line, shifted by −12, −5, +3, +7 and +12, and a wide arpeggio), each
/// against the built-in singer and a voice saved through `sing.addVoice` (the scripted clean take). The existing
/// `SingWireVoiceTests.proposeKey` compares the wire to a RECOMPUTED proposal, so both sides would move together; this
/// one compares to literals. Nonisolated (the tree is at its `@MainActor` suite cap).
///
/// RE-PINNED KNOWINGLY by W8-X9F5 (p2-sing-x9-f5): every reply gained `recommendation.fits` (additive), and a reply
/// whose recommendation does not fit reads a true sentence (`fitsByLabel`). With `fits` taken out, every reply that
/// fits is still byte for byte what HEAD replied (`beforeFittingDigest`, hashed from W8-X9F5's BEFORE run,
/// `$S/w8/X9F5/before.log`).
@Suite("SingWire: sing.proposeKey replies byte for byte as before the harmony fit rule (p2-sing-x9-f3)")
struct SingWireProposeKeyPinTests {

    static let base = SingWireFixture.twoUnitPitches
    static let melodies: [(name: String, pitches: [Int])] = [
        ("base", base), ("down12", base.map { $0 - 12 }), ("down5", base.map { $0 - 5 }),
        ("up3", base.map { $0 + 3 }), ("up7", base.map { $0 + 7 }), ("up12", base.map { $0 + 12 }),
        ("wide", [48, 55, 60, 64, 67, 72, 76, 79]),
    ]

    /// Every reply, canonical, in order: (melody, voice) → text.
    static func replies() async throws -> [(label: String, text: String)] {
        let root = try SingWireFixture.tempDir("f3b-propose-pin")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = URL(string: "http://127.0.0.1:\(try SingWireFixture.unusedLoopbackPort())")!
        let lifecycle = await SingWireFixture.lifecycle(root, baseURL: base)
        let engine = SingWireFakeEngine(config: SingWireFixture.config(root: root, baseURL: base, lifecycle: lifecycle),
                                        state: .installedNotRunning)
        let jobs = SingWireFakeJobs()
        let probe = SingWireInstallProbe()
        let trash = SingWireFixture.trash(into: root)
        let (router, clips) = try await MainActor.run { () throws -> (CommandRouter, [(String, UUID)]) in
            let (store, first) = try SingWireFixture.store(root: root, lyrics: SingWireFixture.twoUnitLyrics)
            var clips: [(String, UUID)] = [("base", first)]
            for (name, pitches) in Self.melodies.dropFirst() {
                let track = store.addTrack(kind: .instrument)
                let notes = SingWireFixture.twoUnitOnsets.enumerated().map { i, onset in
                    MIDINote(pitch: pitches[i % pitches.count], startBeat: onset, lengthBeats: 1)
                }
                let clip = try store.addMIDIClip(toTrack: track.id, name: name, atBeat: 0,
                                                 lengthBeats: (SingWireFixture.twoUnitOnsets.max() ?? 0) + 2,
                                                 notes: notes)
                clips.append((name, clip.id))
            }
            let services = SingWireFixture.services(root: root, engine: engine, jobs: jobs,
                                                    installFunction: probe.function, trash: trash)
            return (CommandRouter(store: store, singServices: services), clips)
        }
        let take = root.appendingPathComponent("take-f3b.wav")
        try SingWireFixture.writeTake(take)
        let added = await router.handle(SingWireFixture.request("sing.addVoice", ["path": .string(take.path)]))
        let voiceID = try #require(added.result?["id"]?.stringValue, "\(added.error ?? "")")
        var out: [(String, String)] = []
        for (name, clipID) in clips {
            for (voiceName, voice) in [("builtIn", nil as String?), ("saved", voiceID)] {
                var params: [String: JSONValue] = ["clipId": .string(clipID.uuidString)]
                if let voice { params["voiceId"] = .string(voice) }
                let reply = await router.handle(SingWireFixture.request("sing.proposeKey", params))
                #expect(reply.error == nil, "\(name) \(voiceName): \(reply.error ?? "")")
                let text = try X7APin.canonical(reply.result).replacingOccurrences(of: voiceID, with: "<voice>")
                out.append(("\(name)|\(voiceName)", text))
            }
        }
        return out
    }

    /// First captured BEFORE the harmony rule: `$S/w8/X9F3B/before.log` (2026-10-07 09:26, the unedited
    /// `VoiceRangeFit.swift` sha256 4e86fe5f…), 14 replies, digest 6e75c318…; the four song-key replies (down5, up7)
    /// are where a looser threshold could change one. Re-pinned by W8-X9F5 after `fits` (`$S/w8/X9F5/after1.log`,
    /// 2026-10-07 10:06): with `fits` removed, 12 replies are HEAD's bytes and `wide|builtIn` / `wide|saved` differ in
    /// `sentence` only.
    static let pinnedDigest: String? = "bbc1dd71d51116687ae616e35d64a9a35dda0b6df1372e6e5d89da5c8e21ac86"
    static let pinnedBaseBuiltIn: String? = #"{"alternativeSentence":null,"alternatives":[],"bestOctaveOnly":{"cost":0.5625000000000018,"octaveShift":0},"clipId":"<id1>","melody":{"highMidi":67,"highNote":"G4","lowMidi":60,"lowNote":"C4","medianMidi":64},"recommendation":{"calibrated":false,"fits":true,"kind":"octave","octaveShift":0,"songTranspose":0,"vocalOffset":0},"sentence":"Fits your voice.","voice":{"id":"builtin-1","name":"Built-in singer","range":{"lowNote":"D4","medianNote":"F♯4","p10Midi":61.7,"p50Midi":65.9,"p90Midi":68.7}}}"#

    /// p2-sing-x9-f5: which replies' recommendations fit (the wide arpeggio fits neither voice).
    static let fitsByLabel: [String: Bool] = [
        "base|builtIn": true, "base|saved": true, "down12|builtIn": true, "down12|saved": true,
        "down5|builtIn": true, "down5|saved": true, "up3|builtIn": true, "up3|saved": true, "up7|builtIn": true,
        "up7|saved": true, "up12|builtIn": true, "up12|saved": true, "wide|builtIn": false, "wide|saved": false,
    ]
    /// The fitting replies, `"fits":true,` taken out, hashed as above from W8-X9F5's BEFORE run (HEAD's code).
    static let beforeFittingDigest = "2f93137f98459a152a9add01d6f27ed45479bfb1a2b6fd63f1fe741934432702"
    /// The wide arpeggio on the built-in singer: 4.6 semitones out of band; HEAD replied "Fits your voice.".
    static let wideBuiltInSentence = "This tune doesn't fully fit your voice: some notes will be above and some below "
        + "where you usually sing."

    @Test("sing.proposeKey: built-in and saved voice, seven melodies, byte for byte as before (pinned before the edit)")
    func proposeKeyRepliesArePinned() async throws {
        let replies = try await Self.replies()
        var hasher = SHA256()
        var fittingHasher = SHA256()
        for (label, text) in replies {
            print("F3B-WIRE|\(label)|\(text)")
            hasher.update(data: Data("\(label)\n\(text)\n".utf8))
            // Exactly one `fits` key per reply, and it is the expected one.
            let fitsTrue = text.components(separatedBy: #""fits":true,"#).count - 1
            let fitsFalse = text.components(separatedBy: #""fits":false,"#).count - 1
            #expect(fitsTrue + fitsFalse == 1, "\(label): \(fitsTrue) true, \(fitsFalse) false")
            #expect(Self.fitsByLabel[label] == (fitsTrue == 1), "\(label)")
            if fitsTrue == 1 {
                let legacy = text.replacingOccurrences(of: #""fits":true,"#, with: "")
                fittingHasher.update(data: Data("\(label)\n\(legacy)\n".utf8))
            } else {
                #expect(!text.contains("Fits your voice.") && !text.contains("right where you sing"), "\(label)")
            }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let fittingDigest = fittingHasher.finalize().map { String(format: "%02x", $0) }.joined()
        print("F3B-WIRE-DIGEST|\(digest)|\(replies.count)")
        print("X9F5-WIRE-FITTING-DIGEST|\(fittingDigest)")
        #expect(replies.count == Self.melodies.count * 2)
        #expect(fittingDigest == Self.beforeFittingDigest)
        let wide = try #require(replies.first { $0.label == "wide|builtIn" })
        #expect(wide.text.contains(#""sentence":"\#(Self.wideBuiltInSentence)""#), "\(wide.text)")
        guard let pinned = Self.pinnedDigest, let baseBuiltIn = Self.pinnedBaseBuiltIn else { return }
        #expect(replies.first?.text == baseBuiltIn)
        #expect(digest == pinned)
    }
}
