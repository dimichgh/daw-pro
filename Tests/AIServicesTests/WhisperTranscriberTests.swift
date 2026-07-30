import Foundation
import AVFoundation
import Testing
import DAWCore
import WhisperKit
@testable import AIServices

// =====================================================================
// m23-n2a — the transcription engine + beat mapping.
//
// Two halves, on purpose:
//
//   1. `TranscriptionBeatMappingTests` — the seconds→beats rule, driven with
//      hand-built WhisperKit results. No model, no audio, no I/O, so the
//      DISCRIMINATING legs run in milliseconds and can be numerous.
//   2. `WhisperTranscriberFixtureTests` — the real thing end to end against a
//      `say`-generated fixture. Slow (the first run on a machine pays a ~90 s
//      CoreML compile), hence `.serialized` + a five-minute limit and a single
//      shared transcriber.
//
// NOTE ON THE FIXTURE SUITE: it is deliberately NOT skipped when the weights
// are absent. A "skip if no model" guard would turn the headline gate into a
// no-op that reports green having proven nothing. A checkout without
// `~/Library/Application Support/DAWPro/Models` therefore REDS these tests,
// with `WhisperModelError`'s teaching text as the failure message — which is
// the honest outcome.
// =====================================================================

// MARK: - Building WhisperKit results by hand

/// One word as the recogniser would report it: text, start/end **relative to
/// the audio that was handed in**, and a probability.
private struct FakeWord {
    let text: String
    let start: Float
    let end: Float
    var probability: Float = 0.9
}

private func fakeSegment(
    text: String,
    start: Float,
    end: Float,
    words: [FakeWord]?
) -> TranscriptionSegment {
    TranscriptionSegment(
        start: start,
        end: end,
        text: text,
        words: words?.map {
            WordTiming(word: $0.text, tokens: [], start: $0.start, end: $0.end, probability: $0.probability)
        }
    )
}

private func fakeResult(
    language: String = "en",
    segments: [TranscriptionSegment]
) -> TranscriptionResult {
    TranscriptionResult(
        text: segments.map(\.text).joined(),
        segments: segments,
        language: language,
        timings: TranscriptionTimings()
    )
}

private func constantTempo(_ bpm: Double) -> TempoMap { TempoMap(constantBPM: bpm) }

/// 120 → 60 at beat 4. `S(4) = 2.0 s`, so beat 4 is two seconds in.
private func steppedTempo() throws -> TempoMap {
    try TempoMap(segments: [.init(startBeat: 0, bpm: 120), .init(startBeat: 4, bpm: 60)])
}

private let tolerance = 1e-9

// MARK: - The beat mapping

@Suite("Transcription beat mapping (m23-n2a)")
struct TranscriptionBeatMappingTests {

    /// Baseline: no range offset, no anchor, one constant tempo that is neither
    /// 60 (where beats and seconds coincide) nor 120 (where a "half seconds"
    /// bug looks like beats). At 90 BPM a second is 1.5 beats, so an
    /// implementation that returned seconds, or divided by a hardcoded 1.0,
    /// lands on 2.0/4.0 instead of 3.0/6.0.
    @Test("Beats are beats, not seconds — 90 BPM")
    func nonSixtyTempo() {
        let result = fakeResult(segments: [
            fakeSegment(text: " Hello there.", start: 2.0, end: 4.0, words: [
                FakeWord(text: " Hello", start: 2.0, end: 3.0),
                FakeWord(text: " there.", start: 3.0, end: 4.0),
            ])
        ])
        let mapped = TranscriptionBeatMapper.map(
            results: [result],
            rangeStartSeconds: 0,
            anchorBeat: 0,
            tempoMap: constantTempo(90),
            modelVariantDirectoryName: "test-variant")

        let words = mapped.words
        #expect(words.count == 2)
        #expect(abs(words[0].startBeat - 3.0) < tolerance)
        #expect(abs(words[0].endBeat - 4.5) < tolerance)
        #expect(abs(words[1].startBeat - 4.5) < tolerance)
        #expect(abs(words[1].endBeat - 6.0) < tolerance)
        // Seconds stay seconds; only beats are musical.
        #expect(abs(words[0].startSeconds - 2.0) < tolerance)
        #expect(abs(words[1].endSeconds - 4.0) < tolerance)
        // And the segment itself is placed, not just its words.
        #expect(abs(mapped.segments[0].startBeat - 3.0) < tolerance)
        #expect(abs(mapped.segments[0].endBeat - 6.0) < tolerance)
    }

    /// A second constant tempo, so "90" cannot be baked in either.
    @Test("Beats are beats — 140 BPM")
    func anotherConstantTempo() {
        let result = fakeResult(segments: [
            fakeSegment(text: " One.", start: 0.0, end: 3.0, words: [
                FakeWord(text: " One.", start: 0.0, end: 3.0)
            ])
        ])
        let mapped = TranscriptionBeatMapper.map(
            results: [result],
            rangeStartSeconds: 0,
            anchorBeat: 0,
            tempoMap: constantTempo(140),
            modelVariantDirectoryName: "test-variant")

        #expect(abs(mapped.words[0].startBeat - 0.0) < tolerance)
        #expect(abs(mapped.words[0].endBeat - 7.0) < tolerance)
    }

    /// **THE DISCRIMINATOR.** A non-zero anchor beat AND words whose elapsed
    /// time crosses a tempo-map boundary.
    ///
    /// Map: 120 BPM from beat 0, 60 BPM from beat 4 (so beat 4 is at 2.0 s).
    /// Anchor beat 2 (which sits at 1.0 s); the file range began at 7.5 s.
    ///
    /// Hand-computed, without calling `TempoMap` to produce the expectation:
    ///   * Δt = 0.50 s → still inside the 120 BPM segment → beat 2 + 1.00 = 3.00
    ///   * Δt = 0.75 s → beat 2 + 1.50 = 3.50
    ///   * Δt = 2.00 s → absolute 3.0 s; the map reaches beat 4 at 2.0 s and
    ///     then runs at one beat per second → beat 5.00
    ///   * Δt = 3.00 s → absolute 4.0 s → beat 6.00
    ///
    /// What this catches that nothing else does: writing
    /// `anchorBeat + tempoMap.beat(atSecondsFromZero: Δt)` instead of
    /// `tempoMap.beat(from: anchorBeat, elapsedSeconds: Δt)`. That version is
    /// numerically IDENTICAL at any constant tempo, and identical at a tempo
    /// change when the anchor is beat 0 — it only diverges when a non-zero
    /// anchor is combined with a crossed boundary. Here it yields 6.00 and 7.00
    /// for the last two, a whole beat and two beats out.
    @Test("Tempo change crossed from a non-zero anchor")
    func tempoChangeFromNonZeroAnchor() throws {
        let result = fakeResult(segments: [
            fakeSegment(text: " Near far.", start: 0.5, end: 3.0, words: [
                FakeWord(text: " Near", start: 0.5, end: 0.75),
                FakeWord(text: " far.", start: 2.0, end: 3.0),
            ])
        ])
        let mapped = TranscriptionBeatMapper.map(
            results: [result],
            rangeStartSeconds: 7.5,
            anchorBeat: 2,
            tempoMap: try steppedTempo(),
            modelVariantDirectoryName: "test-variant")

        let words = mapped.words
        #expect(words.count == 2)
        #expect(abs(words[0].startBeat - 3.00) < tolerance)
        #expect(abs(words[0].endBeat - 3.50) < tolerance)
        #expect(abs(words[1].startBeat - 5.00) < tolerance)
        #expect(abs(words[1].endBeat - 6.00) < tolerance)

        // The seconds axis is a plain shift by the range start and is
        // deliberately given different numbers than the beats, so a test that
        // confused the two axes could not pass by coincidence.
        #expect(abs(words[0].startSeconds - 8.00) < tolerance)
        #expect(abs(words[0].endSeconds - 8.25) < tolerance)
        #expect(abs(words[1].startSeconds - 9.50) < tolerance)
        #expect(abs(words[1].endSeconds - 10.50) < tolerance)

        // The segment spans the boundary too.
        #expect(abs(mapped.segments[0].startBeat - 3.00) < tolerance)
        #expect(abs(mapped.segments[0].endBeat - 6.00) < tolerance)
        #expect(abs(mapped.rangeStartSeconds - 7.5) < tolerance)
        #expect(abs(mapped.anchorBeat - 2.0) < tolerance)
    }

    /// The other offset bug: folding `rangeStartSeconds` into the MUSICAL
    /// conversion as well as the seconds one. WhisperKit's times are already
    /// relative to the slice it was given, so the file offset must not be added
    /// again on the beat axis.
    ///
    /// 120 BPM, anchor beat 2, range starting 5.0 s into the file, a word at
    /// Δt = 1.0…1.5 s. Correct: beats 4.0…5.0, seconds 6.0…6.5.
    /// Double-counting (`elapsedSeconds: rangeStart + Δt`) gives beat 14.0;
    /// applying the ANCHOR to the seconds axis gives 3.0 s.
    /// Both are invisible when the range starts at 0, which is why this test
    /// exists separately.
    @Test("Range start shifts seconds only, never beats")
    func rangeStartDoesNotLeakIntoBeats() {
        let result = fakeResult(segments: [
            fakeSegment(text: " Word.", start: 1.0, end: 1.5, words: [
                FakeWord(text: " Word.", start: 1.0, end: 1.5)
            ])
        ])
        let mapped = TranscriptionBeatMapper.map(
            results: [result],
            rangeStartSeconds: 5.0,
            anchorBeat: 2,
            tempoMap: constantTempo(120),
            modelVariantDirectoryName: "test-variant")

        let word = mapped.words[0]
        #expect(abs(word.startBeat - 4.0) < tolerance)
        #expect(abs(word.endBeat - 5.0) < tolerance)
        #expect(abs(word.startSeconds - 6.0) < tolerance)
        #expect(abs(word.endSeconds - 6.5) < tolerance)
    }

    /// Ordering survives the mapping across a tempo change: the map is
    /// monotonically increasing, so monotonic, non-overlapping input must come
    /// out monotonic and non-overlapping.
    @Test("Monotonic, non-overlapping input stays that way across a tempo change")
    func orderingSurvivesTempoChange() throws {
        let words = (0..<8).map { i in
            FakeWord(text: " w\(i)", start: Float(i) * 0.5, end: Float(i) * 0.5 + 0.5)
        }
        let result = fakeResult(segments: [
            fakeSegment(text: " eight words.", start: 0.0, end: 4.0, words: words)
        ])
        let mapped = TranscriptionBeatMapper.map(
            results: [result],
            rangeStartSeconds: 0,
            anchorBeat: 1.5,
            tempoMap: try steppedTempo(),
            modelVariantDirectoryName: "test-variant")

        let out = mapped.words
        #expect(out.count == 8)
        for word in out {
            #expect(word.startBeat < word.endBeat)
            #expect(word.startSeconds < word.endSeconds)
        }
        for (a, b) in zip(out, out.dropFirst()) {
            #expect(a.endBeat <= b.startBeat + tolerance)
            #expect(a.startBeat < b.startBeat)
            #expect(a.endSeconds <= b.startSeconds + tolerance)
        }
        // The tempo really did change inside the span: the same half-second
        // buys 1.0 beat early on and 0.5 beats after the boundary.
        let firstStep = out[1].startBeat - out[0].startBeat
        let lastStep = out[7].startBeat - out[6].startBeat
        #expect(abs(firstStep - 1.0) < tolerance)
        #expect(abs(lastStep - 0.5) < tolerance)
    }

    /// Chunked audio comes back as SEVERAL results. Taking `.first` would drop
    /// everything after the first chunk, silently.
    @Test("Every result is used, not just the first")
    func allResultsAreFlattened() {
        let a = fakeResult(segments: [
            fakeSegment(text: " First half.", start: 0.0, end: 1.0, words: [
                FakeWord(text: " First", start: 0.0, end: 0.5),
                FakeWord(text: " half.", start: 0.5, end: 1.0),
            ])
        ])
        let b = fakeResult(segments: [
            fakeSegment(text: " Second half.", start: 1.0, end: 2.0, words: [
                FakeWord(text: " Second", start: 1.0, end: 1.5),
                FakeWord(text: " half.", start: 1.5, end: 2.0),
            ])
        ])
        let mapped = TranscriptionBeatMapper.map(
            results: [a, b],
            rangeStartSeconds: 0,
            anchorBeat: 0,
            tempoMap: constantTempo(120),
            modelVariantDirectoryName: "test-variant")

        #expect(mapped.segments.count == 2)
        #expect(mapped.words.count == 4)
        #expect(mapped.text == "First half. Second half.")
        #expect(abs(mapped.words[3].endBeat - 4.0) < tolerance)
    }

    /// Word-level alignment is optional upstream (`words` is `[WordTiming]?`).
    /// Absent alignment is an empty list, never a crash and never an error —
    /// the segment is still placed.
    @Test("A segment without word alignment still lands on its beats")
    func segmentWithoutWords() {
        let result = fakeResult(segments: [
            fakeSegment(text: " No alignment.", start: 1.0, end: 2.0, words: nil)
        ])
        let mapped = TranscriptionBeatMapper.map(
            results: [result],
            rangeStartSeconds: 0,
            anchorBeat: 0,
            tempoMap: constantTempo(120),
            modelVariantDirectoryName: "test-variant")

        #expect(mapped.segments.count == 1)
        #expect(mapped.segments[0].words.isEmpty)
        #expect(mapped.words.isEmpty)
        #expect(abs(mapped.segments[0].startBeat - 2.0) < tolerance)
        #expect(abs(mapped.segments[0].endBeat - 4.0) < tolerance)
    }

    /// Metadata carried through, and `text` derived from the segments so the
    /// two can never disagree.
    @Test("Text, language and model identity are reported")
    func metadataIsCarried() {
        let result = fakeResult(language: "en", segments: [
            fakeSegment(text: " Some words here.", start: 0.0, end: 1.0, words: [
                FakeWord(text: " Some", start: 0.0, end: 0.3, probability: 0.5)
            ])
        ])
        let mapped = TranscriptionBeatMapper.map(
            results: [result],
            rangeStartSeconds: 0,
            anchorBeat: 0,
            tempoMap: constantTempo(120),
            modelVariantDirectoryName: "openai_whisper-test")

        #expect(mapped.text == "Some words here.")
        #expect(mapped.language == "en")
        #expect(mapped.modelVariantDirectoryName == "openai_whisper-test")
        #expect(abs(mapped.words[0].confidence - 0.5) < 1e-6)
    }

    /// An empty result set is an empty transcription, not a crash.
    @Test("Nothing recognised is an empty transcription")
    func emptyResults() {
        let mapped = TranscriptionBeatMapper.map(
            results: [],
            rangeStartSeconds: 3.0,
            anchorBeat: 8,
            tempoMap: constantTempo(120),
            modelVariantDirectoryName: "test-variant")

        #expect(mapped.text.isEmpty)
        #expect(mapped.segments.isEmpty)
        #expect(mapped.words.isEmpty)
        #expect(abs(mapped.anchorBeat - 8.0) < tolerance)
        #expect(abs(mapped.rangeStartSeconds - 3.0) < tolerance)
    }
}

// MARK: - Requests that never reach the model

@Suite("Whisper transcriber — request and model errors (m23-n2a)")
struct WhisperTranscriberErrorTests {

    private func emptyDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawpro-whisper-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The teaching error is the CATALOG's, reused verbatim — there is no
    /// parallel "model missing" case in `WhisperTranscriptionError`.
    ///
    /// The audio path deliberately does not exist: that makes this test also
    /// pin the ORDER of the two checks. If model resolution ever moved after
    /// the audio read, this would fail with a load error instead.
    @Test("No installed model → WhisperModelError.noModelInstalled")
    func noModelInstalled() async throws {
        let root = try emptyDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = WhisperModelCatalog(searchRoot: root)
        let transcriber = WhisperTranscriber(catalog: catalog)
        let request = WhisperTranscriptionRequest(
            audioURL: root.appendingPathComponent("not-a-real-file.wav"),
            tempoMap: TempoMap(constantBPM: 120))

        do {
            _ = try await transcriber.transcribe(request)
            Issue.record("expected the catalog's teaching error")
        } catch let error as WhisperModelError {
            #expect(error == .noModelInstalled(searchRoot: catalog.searchRoot.path, incomplete: []))
            #expect(error.errorDescription?.contains(catalog.searchRoot.path) == true)
        }
    }

    @Test("A named model that is not there → WhisperModelError.variantNotFound")
    func variantNotFound() async throws {
        let root = try emptyDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = WhisperModelCatalog(searchRoot: root)
        let transcriber = WhisperTranscriber(catalog: catalog, variantName: "openai_whisper-nope")
        let request = WhisperTranscriptionRequest(
            audioURL: root.appendingPathComponent("not-a-real-file.wav"),
            tempoMap: TempoMap(constantBPM: 120))

        do {
            _ = try await transcriber.transcribe(request)
            Issue.record("expected the catalog's teaching error")
        } catch let error as WhisperModelError {
            #expect(error == .variantNotFound(
                requested: "openai_whisper-nope",
                searchRoot: catalog.searchRoot.path,
                available: []))
        }
    }

    @Test("A search root that is not there → WhisperModelError.searchRootMissing")
    func searchRootMissing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawpro-whisper-absent-\(UUID().uuidString)", isDirectory: true)
        let catalog = WhisperModelCatalog(searchRoot: root)
        let transcriber = WhisperTranscriber(catalog: catalog)
        let request = WhisperTranscriptionRequest(
            audioURL: root.appendingPathComponent("not-a-real-file.wav"),
            tempoMap: TempoMap(constantBPM: 120))

        do {
            _ = try await transcriber.transcribe(request)
            Issue.record("expected the catalog's teaching error")
        } catch let error as WhisperModelError {
            #expect(error == .searchRootMissing(searchRoot: catalog.searchRoot.path))
        }
    }

    /// Range validation happens BEFORE the model is touched — so these run in
    /// microseconds even against a catalog with nothing in it, and a caller
    /// with a typo does not wait out a model load to be told.
    @Test("A backwards or negative range is refused before anything loads")
    func invalidRanges() async throws {
        let root = try emptyDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcriber = WhisperTranscriber(catalog: WhisperModelCatalog(searchRoot: root))
        let audio = root.appendingPathComponent("not-a-real-file.wav")
        let tempo = TempoMap(constantBPM: 120)

        do {
            _ = try await transcriber.transcribe(WhisperTranscriptionRequest(
                audioURL: audio, startSeconds: -1, tempoMap: tempo))
            Issue.record("expected invalidRange for a negative start")
        } catch let error as WhisperTranscriptionError {
            #expect(error == .invalidRange(startSeconds: -1, endSeconds: nil))
        }

        do {
            _ = try await transcriber.transcribe(WhisperTranscriptionRequest(
                audioURL: audio, startSeconds: 4, endSeconds: 4, tempoMap: tempo))
            Issue.record("expected invalidRange for an empty span")
        } catch let error as WhisperTranscriptionError {
            #expect(error == .invalidRange(startSeconds: 4, endSeconds: 4))
        }

        do {
            _ = try await transcriber.transcribe(WhisperTranscriptionRequest(
                audioURL: audio, startSeconds: 9, endSeconds: 2, tempoMap: tempo))
            Issue.record("expected invalidRange for a backwards span")
        } catch let error as WhisperTranscriptionError {
            #expect(error == .invalidRange(startSeconds: 9, endSeconds: 2))
        }
    }
}

// MARK: - End to end against a real fixture

/// ONE transcriber for the whole fixture suite: the model is loaded once and
/// every later case is warm (~1 s instead of ~90 s).
private let sharedTranscriber = WhisperTranscriber()

/// `say` with no voice argument writes 22050 Hz mono AIFF — deliberately NOT
/// 16 kHz, so every run through this fixture exercises WhisperKit's resample
/// path as well as its decoder.
private let fixturePhrase = "The quick brown fox jumps over the lazy dog"
private let fixtureWords = ["the", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog"]

private func makeSayFixture() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dawpro-whisper-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("fox.aiff")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-o", url.path, fixturePhrase]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
        throw NSError(domain: "WhisperTranscriberTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "`say -o \(url.path)` failed with status \(process.terminationStatus)"
        ])
    }
    return url
}

/// Lowercased alphanumeric tokens — strips the leading space and trailing
/// punctuation the recogniser attaches (`" dog."` → `["dog"]`).
private func normalizedTokens(_ text: String) -> [String] {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
}

@Suite("Whisper transcription — the say fixture (m23-n2a)", .serialized, .timeLimit(.minutes(5)))
struct WhisperTranscriberFixtureTests {

    /// The headline gate: exact words, monotonic non-overlapping timings, and
    /// beats that are genuinely musical.
    ///
    /// The beat check is at 120 BPM and hand-derived: with a constant map
    /// anchored at beat 0, a word at `t` seconds must land on `2·t` beats.
    /// At 60 BPM this leg would be vacuous (beats and seconds coincide); at
    /// 120 an implementation that reported seconds is out by exactly 2×.
    @Test("The say fixture transcribes to the right words on the right beats")
    func fixtureTranscribes() async throws {
        let audio = try makeSayFixture()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }

        // The fixture is not 16 kHz — this run therefore goes through
        // WhisperKit's resampler, which is the only resampler involved.
        let file = try AVAudioFile(forReading: audio)
        #expect(file.fileFormat.sampleRate != 16_000)
        #expect(file.fileFormat.sampleRate == 22_050)

        let transcription = try await sharedTranscriber.transcribe(
            WhisperTranscriptionRequest(
                audioURL: audio,
                anchorBeat: 0,
                tempoMap: TempoMap(constantBPM: 120),
                language: "en"))

        #expect(!transcription.modelVariantDirectoryName.isEmpty)
        #expect(normalizedTokens(transcription.text) == fixtureWords)
        // MEASURED 2026-07-27: with WhisperKit's default `skipSpecialTokens`
        // (false) this text came back as
        // `<|startoftranscript|><|en|><|transcribe|><|0.00|> The quick …`.
        // `normalizedTokens` strips punctuation, so it would happily eat the
        // `<|` `|>` syntax and only notice the WORDS the markers add — this
        // leg checks the marker syntax itself, so turning that option back off
        // reddens here instead of silently degrading the user-facing prose.
        #expect(!transcription.text.contains("<|"))

        let words = transcription.words
        #expect(words.map { normalizedTokens($0.text).joined() } == fixtureWords)

        for word in words {
            #expect(word.startSeconds <= word.endSeconds)
            #expect(word.startBeat <= word.endBeat)
            // 120 BPM from beat 0: two beats to the second, hand-derived.
            #expect(abs(word.startBeat - word.startSeconds * 2.0) < 1e-6)
            #expect(abs(word.endBeat - word.endSeconds * 2.0) < 1e-6)
        }
        for (a, b) in zip(words, words.dropFirst()) {
            #expect(a.endSeconds <= b.startSeconds + 1e-6)
            #expect(a.endBeat <= b.startBeat + 1e-6)
        }
        let fixtureDuration = Double(file.length) / file.fileFormat.sampleRate
        #expect(words.first.map { $0.startSeconds >= 0 } == true)
        #expect(words.last.map { $0.endSeconds <= fixtureDuration + 0.5 } == true)
    }

    /// The sub-range leg. The same fixture is read twice — once whole from beat
    /// 0, once from 1.0 s in with the anchor set to the beat that 1.0 s occupies
    /// (beat 2 at 120 BPM). Because `rangeStartSeconds` and `anchorBeat`
    /// describe the SAME instant on two axes, a word recognised in both runs
    /// must land on the same project beat.
    ///
    /// This is the composition check: reading the slice, offsetting seconds by
    /// the file position, and offsetting beats by the anchor all have to agree.
    /// Getting any one of them wrong moves the second run by at least a whole
    /// beat, far outside the tolerance below (which exists only because the
    /// recogniser sees less context in the shorter clip and its alignment can
    /// shift by tens of milliseconds).
    @Test("A sub-range lands on the same project beats as the whole file")
    func subRangeAgreesWithWholeFile() async throws {
        let audio = try makeSayFixture()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }

        let tempo = TempoMap(constantBPM: 120)
        let whole = try await sharedTranscriber.transcribe(
            WhisperTranscriptionRequest(
                audioURL: audio, anchorBeat: 0, tempoMap: tempo, language: "en"))

        let sliceStart = 1.0
        let sliced = try await sharedTranscriber.transcribe(
            WhisperTranscriptionRequest(
                audioURL: audio,
                startSeconds: sliceStart,
                anchorBeat: sliceStart * 2.0,   // beat 2: where 1.0 s sits at 120 BPM
                tempoMap: tempo,
                language: "en"))

        #expect(sliced.rangeStartSeconds == sliceStart)
        #expect(!sliced.words.isEmpty)

        // Nothing may be reported before the slice began, on either axis.
        for word in sliced.words {
            #expect(word.startSeconds >= sliceStart - 1e-6)
            #expect(word.startBeat >= sliceStart * 2.0 - 1e-6)
            #expect(abs(word.startBeat - word.startSeconds * 2.0) < 1e-6)
        }

        let wholeLast = try #require(whole.words.last)
        let slicedLast = try #require(sliced.words.last)
        #expect(normalizedTokens(slicedLast.text) == normalizedTokens(wholeLast.text))
        #expect(abs(slicedLast.startBeat - wholeLast.startBeat) < 0.4)
    }

    /// The **end** of the range, which the sub-range test above leaves open.
    /// `endSeconds` is what a clip's finish maps to, so "ignored end" is a live
    /// failure mode: the fixture runs to ~2.44 s and its last word (" dog.")
    /// starts at ~1.98 s, so an ignored bound shows up as a word ending well
    /// past 1.5 s and as "dog" appearing in text that should stop before it.
    @Test("The range end truncates the audio that is read")
    func rangeEndTruncates() async throws {
        let audio = try makeSayFixture()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }

        let truncated = try await sharedTranscriber.transcribe(
            WhisperTranscriptionRequest(
                audioURL: audio,
                startSeconds: 0,
                endSeconds: 1.5,
                anchorBeat: 0,
                tempoMap: TempoMap(constantBPM: 120),
                language: "en"))

        #expect(!truncated.words.isEmpty)
        for word in truncated.words {
            #expect(word.endSeconds <= 1.5 + 0.05)
        }
        let tokens = normalizedTokens(truncated.text)
        #expect(tokens.count < fixtureWords.count)
        #expect(!tokens.contains("dog"))
    }

    /// The one-job-at-a-time lock, contended for real.
    ///
    /// The `@unchecked Sendable` justification on `KitBox` rests on this: the
    /// same `WhisperKit` instance is never inside two jobs at once. Three
    /// concurrent calls against an already-loaded transcriber genuinely contend
    /// (a transcription suspends for well over a second while holding the lock),
    /// so this exercises both the wait and the release. All three must return —
    /// a lost wakeup or a lock leaked on some path would hang here, caught by the
    /// suite's five-minute limit.
    ///
    /// **The agreement legs alone are blind, and this was MEASURED, not
    /// assumed.** With `acquire()`'s wait loop disabled, three concurrent
    /// transcriptions of this fixture still returned identical, correct text
    /// (2026-07-27) — WhisperKit tolerated the overlap on an input this small.
    /// So the discriminating leg is `peakConcurrentJobs`, which reads 3 under
    /// the disabled lock and 1 with it. The other expectations stay because they
    /// pin what serialisation is FOR; they are just not what proves it.
    @Test("Concurrent jobs serialise on one instance")
    func concurrentJobsSerialise() async throws {
        let audio = try makeSayFixture()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let request = WhisperTranscriptionRequest(
            audioURL: audio, anchorBeat: 0, tempoMap: TempoMap(constantBPM: 120), language: "en")

        let texts = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try? await sharedTranscriber.transcribe(request).text
                }
            }
            var collected: [String?] = []
            for await text in group { collected.append(text) }
            return collected
        }

        #expect(texts.count == 3)
        #expect(texts.allSatisfy { $0 != nil })
        #expect(Set(texts.compactMap { $0 }).count == 1)
        #expect(normalizedTokens(texts.compactMap { $0 }.first ?? "") == fixtureWords)

        // THE discriminating leg (see the note above): never two jobs inside
        // the recogniser at once, across every case this serialized suite has
        // run so far.
        let peak = await sharedTranscriber.peakConcurrentJobs
        #expect(peak == 1)
    }

    /// The instance is held, not rebuilt: a second call reports the same model
    /// and does not reload. (`prewarm()` is the same load path the first
    /// transcription would take, so calling it here is free once the suite has
    /// already loaded.)
    @Test("The model is loaded once and kept")
    func modelIsHeld() async throws {
        try await sharedTranscriber.prewarm()
        let first = await sharedTranscriber.loadedModelVariantDirectoryName
        try await sharedTranscriber.prewarm()
        let second = await sharedTranscriber.loadedModelVariantDirectoryName
        #expect(first != nil)
        #expect(first == second)
    }
}
