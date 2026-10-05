import Foundation
import Testing
@testable import DAWCore

/// p2-sing-d2: `Track.sungVocalProvenance` (design §3.9), a FACT stored on the
/// track a sing job made. Additive and optional: an old file has none, a track
/// without one writes no key, and every field decodes leniently. Pure values,
/// so NOT `@MainActor`.
@Suite("Sung-vocal provenance: a fact on the track, saved and reopened, never required (p2-sing-d2)")
struct SungVocalProvenanceTests {

    static let record = SungVocalProvenance(
        engineId: "soulx-singer", engineCommit: "abc1234", weightsRevision: "rev-1", facadeVersion: 1,
        voiceId: "builtin-1", voiceName: "Built-in singer", voiceKind: SungVocalProvenance.VoiceKind.builtIn,
        lyricsText: "twin-kle +\nlit-tle star",
        sourceClipId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        octaveShift: -1, songTransposeSemitones: 2, seed: 7, nSteps: 32, cfg: 1.5,
        renderedAt: Date(timeIntervalSince1970: 1_790_000_000),
        loudness: BounceLoudnessReport(input: LoudnessMeasurement(integratedLufs: -20, truePeakDbtp: -3),
                                       output: LoudnessMeasurement(integratedLufs: -16, truePeakDbtp: -1),
                                       appliedGainDb: 4, lufsTarget: -16),
        noteAccuracy: SungNoteAccuracy(hitRate: 0.9, meanAbsErrorCents: 12, voicedCoverage: 0.95, inTune: true),
        wordCheck: SungWordCheck(state: SungWordCheck.State.checked, wer: 0.1, heard: "twinkle little star",
                                 verdict: "clear"))

    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test("a track without a record writes no key, and a payload without the key decodes to nil")
    func absentMeansNone() throws {
        let plain = Track(name: "Vox", kind: .audio)
        let plainJSON = try Self.json(plain)
        #expect(!plainJSON.contains("sungVocalProvenance"))
        let back = try JSONDecoder().decode(Track.self, from: Data(plainJSON.utf8))
        #expect(back.sungVocalProvenance == nil)
        #expect(back == plain)
        // Control: a track that has one writes the key.
        var sung = plain
        sung.sungVocalProvenance = Self.record
        #expect(try Self.json(sung).contains(#""sungVocalProvenance":{"#))
        #expect(Track(name: "Vox", kind: .audio, sungVocalProvenance: Self.record).sungVocalProvenance == Self.record)
    }

    @Test("the record round-trips through Track's Codable and through the project file")
    func roundTrips() throws {
        let track = Track(name: "Vocals — Built-in singer", kind: .audio, isAIGenerated: true,
                          sungVocalProvenance: Self.record)
        let back = try JSONDecoder().decode(Track.self, from: try JSONEncoder().encode(track))
        #expect(back == track)

        // The project file, with the ISO-8601 dates `ProjectBundle` writes.
        let document = ProjectDocument(name: "Sung", transport: TransportState(), tracks: [track], masterVolume: 1,
                                       mediaRefs: [:])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(document)
        #expect(String(decoding: data, as: UTF8.self).contains(#""sungVocalProvenance":{"#), "TrackDocument writes it")
        let reopened = try decoder.decode(ProjectDocument.self, from: data)
        #expect(reopened.tracks.first?.sungVocalProvenance == Self.record, "TrackDocument reads it")
        let runtime = reopened.runtimeState(bundleURL: URL(fileURLWithPath: "/tmp/sd2-sung.dawproj")).tracks
        #expect(runtime.first?.sungVocalProvenance == Self.record, "runtimeState carries it onto the track")
    }

    @Test("every field decodes leniently: an empty record opens, and values a later build writes survive")
    func lenientDecode() throws {
        let empty = try JSONDecoder().decode(SungVocalProvenance.self, from: Data("{}".utf8))
        #expect(empty == SungVocalProvenance(
            engineId: "", engineCommit: "", weightsRevision: "", facadeVersion: 0, voiceId: "", voiceName: "",
            voiceKind: "", lyricsText: "", sourceClipId: nil, octaveShift: 0, songTransposeSemitones: 0,
            seed: 0, nSteps: 0, cfg: 0, renderedAt: Date(timeIntervalSinceReferenceDate: 0)))
        let later = try JSONDecoder().decode(
            SungVocalProvenance.self,
            from: Data(#"{"voiceKind":"cloned","wordCheck":{"state":"asleep"},"noteAccuracy":{},"futureField":1}"#.utf8))
        #expect(later.voiceKind == "cloned")
        #expect(later.wordCheck == SungWordCheck(state: "asleep"))
        #expect(later.noteAccuracy == SungNoteAccuracy(hitRate: 0, meanAbsErrorCents: nil, voicedCoverage: 0,
                                                       inTune: false))
        // A track whose record lost its fields still opens, record and all. (Leniency is about MISSING
        // keys only: a field of the wrong type still throws, as `VoiceProvenance`'s synthesized decode does.)
        let plain = try Self.json(Track(name: "Vox", kind: .audio))
        let damaged = #"{"sungVocalProvenance":{},"# + plain.dropFirst()
        let track = try JSONDecoder().decode(Track.self, from: Data(damaged.utf8))
        #expect(track.sungVocalProvenance?.engineId == "")
        #expect(track.sungVocalProvenance?.renderedAt == Date(timeIntervalSinceReferenceDate: 0))
    }
}
