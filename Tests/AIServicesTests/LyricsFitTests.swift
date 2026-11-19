import Foundation
import Testing
@testable import AIServices
@testable import DAWCore

/// p2-sing-x7b (design `2026-10-06-p2-sing-expansion.md` §8.3): `LyricsFit`, lyrics written to fit a melody and CHECKED
/// against it, and the fit prompts. Nonisolated; the store is built on the main actor. No writer here touches a network.
@Suite("LyricsFit — words that fit a melody, checked not trusted (p2-sing-x7b)")
struct LyricsFitTests {

    /// Two breath phrases of four one-beat notes (beats 4-7 and 36-39) at the default 120 BPM.
    private func melody() async throws -> (Clip, TempoMap) {
        try await MainActor.run {
            let store = ProjectStore()
            let track = store.addTrack(kind: .instrument)
            let notes = [4.0, 5, 6, 7, 36, 37, 38, 39].map { MIDINote(pitch: 60, startBeat: $0, lengthBeats: 1) }
            let clip = try store.addMIDIClip(toTrack: track.id, name: "Melody", atBeat: 0, lengthBeats: 41, notes: notes)
            return (clip, store.transport.tempoMap)
        }
    }

    @Test("cleaned: every [tag] goes, wherever it is; lines are trimmed; blank lines dropped")
    func cleaned() {
        #expect(LyricsFit.cleaned("[verse]\n  one two  \n\n[Chorus 2] three\n[outro]\n") == "one two\nthree")
        #expect(LyricsFit.cleaned("Siobhan{shi-vawn} sings\n") == "Siobhan{shi-vawn} sings", "braces are markup, kept")
    }

    @Test("phrases: the assigner's breath phrases, each with its note count and length in seconds")
    func phrases() async throws {
        let (clip, tempo) = try await melody()
        #expect(LyricsFit.phrases(of: clip, tempoMap: tempo)
            == [.init(notes: 4, seconds: 2), .init(notes: 4, seconds: 2)])
    }

    @Test("check: a line that fits, a line with too many syllables, the wrong number of lines, and an assigner refusal")
    func check() async throws {
        let (clip, tempo) = try await melody()
        let fits = LyricsFit.check("one two three four\nfive six one", clip: clip, language: nil, tempoMap: tempo)
        #expect(fits.allFit && fits.problems.isEmpty)
        #expect(fits.lines == [LyricsFitLine(phrase: 1, notes: 4, syllables: 4, fits: true),
                               LyricsFitLine(phrase: 2, notes: 4, syllables: 3, fits: true)])

        let long = LyricsFit.check("wonderfully beautiful\nfive six one", clip: clip, language: nil, tempoMap: tempo)
        let count = EnglishSyllables.estimate("wonderfully") + EnglishSyllables.estimate("beautiful")
        #expect(count > 4)
        #expect(!long.allFit)
        #expect(long.lines.map(\.fits) == [false, true])
        #expect(long.problems == ["Line 1 has \(count) syllables, but phrase 1 has only 4 notes."])

        let one = LyricsFit.check("one two three four five six", clip: clip, language: nil, tempoMap: tempo)
        #expect(!one.allFit, "two phrases sung from one line flow; they are not line for line")
        #expect(one.problems.first == "You wrote 1 line, but the tune has 2 phrases. Write exactly 2 lines, one for each phrase.")

        let crowded = LyricsFit.check("a b c d e\nf g", clip: clip, language: nil, tempoMap: tempo)
        #expect(!crowded.allFit)
        #expect(crowded.problems.contains { $0.hasPrefix("The words couldn't be placed on the notes: ") })
    }

    @Test("write: asks once when the reply fits; once more, naming the lines, when it does not; never more")
    func writeRetriesOnce() async throws {
        let (clip, tempo) = try await melody()
        let fitting = LyricsFitTestWriter(["[verse]\none two three four\nfive six one two"])
        let first = try await LyricsFit.write(LyricsWriteRequest(prompt: "home"), clip: clip, language: nil,
                                              tempoMap: tempo, writer: fitting)
        #expect(first.attempts == 1 && first.report.allFit)
        #expect(first.result == LyricsWriteResult(lyrics: "one two three four\nfive six one two", provider: "fake"))

        let stubborn = LyricsFitTestWriter(["wonderfully beautiful\nfive"])
        let second = try await LyricsFit.write(LyricsWriteRequest(prompt: "home"), clip: clip, language: nil,
                                               tempoMap: tempo, writer: stubborn)
        #expect(second.attempts == 2 && !second.report.allFit)
        let asked = await stubborn.requests
        try #require(asked.count == 2)
        #expect(asked[0].fit?.problems == [])
        #expect(asked[1].fit?.problems == second.report.problems)
        let retry = LyricsPromptBuilder.userPrompt(asked[1])
        #expect(retry.contains("Your last lines didn't fit the tune:\n- Line 1 has "))
        #expect(retry.hasSuffix("Write all 2 lines again, fixing those."))
        #expect(LyricsPromptBuilder.systemPrompt(asked[0]).contains("FORMAT: write exactly 2 lines, one for each phrase"))
        #expect(LyricsFit.Copy.notFit(lines: [1, 3, 4]) == "Some lines didn't fit the tune: 1, 3 and 4. Edit them, or try again.")
    }
}

/// Answers its script in order (the last reply repeats), recording every request. No network.
actor LyricsFitTestWriter: LyricsGenerating {
    private var replies: [String]
    private(set) var requests: [LyricsWriteRequest] = []

    init(_ replies: [String]) { self.replies = replies }

    func generateLyrics(theme: String, style: String?) async throws -> String { "legacy" }

    func writeLyrics(_ request: LyricsWriteRequest) async throws -> LyricsWriteResult {
        requests.append(request)
        let reply = replies.count > 1 ? replies.removeFirst() : (replies.first ?? "")
        return LyricsWriteResult(lyrics: reply, provider: "fake")
    }
}
