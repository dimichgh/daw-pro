import Foundation
import Testing
@testable import DAWCore

/// W7-NTU ruling 1 (2026-10-04) — the preset card asks only when a preset
/// would replace something that changed: `autoCorrectReplaceableStamp`,
/// `replaceableContentStamp` and `hasHandEditsARerunWouldReplace(_:)`
/// (`PitchEditProvenance.swift`'s second banner).
///
/// Three things are proved, each against something real:
///  * AN OLD DOCUMENT (a preset's output saved before the field: W7-D2's
///    FROZEN `presetNatural` golden) decodes with no replaceable stamp,
///    re-saves byte for byte, and answers EXACTLY as today: a voice-size
///    change still asks;
///  * a NEW output folds only what a preset KEEPS: a voice size or a consonant
///    choice alone does not ask; a note, the slide smoothness, the retune
///    speed, a voice size set back to none, or an OFF nobody chose does;
///  * the fold is the REAL store's carry rule: after a change the predicate
///    calls "nothing to lose", the store's own preset keeps that change, and
///    the store's `replaceExisting:false` refusal (the wire's, deliberately
///    left on the whole-set rule) still refuses.
///
/// ⚠️ NOT a `@MainActor` suite: the store tests are `@MainActor` one by one,
/// so the review-cadence bound (`MainActorOccupancySiteTests`) is not spent.
@Suite("PitchEditSet — the replaceable stamp: what a preset would replace (W7-NTU ruling 1)")
struct PitchEditReplaceableStampTests {

    static let natural = PitchCorrectionPreset.natural.options()

    /// A (+150 c) and B abut, then C (-40 c): `ConsonantChoiceTests`' notes.
    static func output() -> PitchEditSet {
        PitchEditSet.seeded(analysisVersion: 1, segments: ConsonantChoiceTests.notes(), retuneMs: 110,
                            partKinds: [:], seedPolicy: .preset)
            .stampedAsAutoCorrectOutput()
    }

    // MARK: - An old document

    /// Planted and seen red (W7-NTU P-r1-absent, 2026-10-04 window R1W1; the line said "to be planted" until it has been): the predicate folding when
    /// the replaceable stamp is ABSENT (an old document stops asking).
    @Test("an OLD document (a preset's output saved before the field) decodes with no replaceable stamp, re-saves byte for byte, and answers exactly as today: a voice size or consonant change alone still ASKS")
    func oldDocumentKeepsTodaysRule() throws {
        let golden = try #require(ConsonantChoiceTests.goldens.first { $0.name == "presetNatural" })
        // Positive control on the literal: it IS a preset's output, with the
        // whole stamp and without the new key.
        #expect(golden.json.contains(#""autoCorrectStamp":"12da63bde6b83a8b""#))
        #expect(!golden.json.contains("autoCorrectReplaceableStamp"))
        let bytes = Data(golden.json.utf8)
        let old = try JSONDecoder().decode(PitchEditSet.self, from: bytes)
        #expect(old.autoCorrectReplaceableStamp == nil)
        #expect(try ConsonantChoiceTests.sortedEncoder().encode(old) == bytes,
                "an old document re-saved with different bytes")
        #expect(old.contentStamp == golden.stamp)
        #expect(old.hasHandEditsARerunWouldReplace(Self.natural) == false, "an untouched old output asks")
        #expect(old.hasHandEditsSinceAutoCorrect == false)

        var voice = old
        voice.formantCorrection = 0.6
        #expect(voice.hasHandEditsSinceAutoCorrect)
        #expect(voice.hasHandEditsARerunWouldReplace(Self.natural),
                "an old document stopped asking: ABSENT must be today's rule")
        var consonants = old
        consonants.consonantProtection = .offByChoice
        #expect(consonants.hasHandEditsARerunWouldReplace(Self.natural))
        // And once a preset writes it again, it carries both stamps.
        let restamped = voice.stampedAsAutoCorrectOutput()
        #expect(restamped.autoCorrectReplaceableStamp != nil)
        #expect(restamped.hasHandEditsARerunWouldReplace(Self.natural) == false)
    }

    // MARK: - A new output

    @Test("a new output carries BOTH stamps; the whole one is unchanged by the new field, and the replaceable one is the content with the kept settings folded")
    func newOutputCarriesBothStamps() throws {
        let out = Self.output()
        #expect(out.autoCorrectStamp == out.contentStamp)
        #expect(out.autoCorrectReplaceableStamp == out.replaceableContentStamp)
        // The whole stamp is what it was before the field existed: W7-D2's
        // frozen value for these notes.
        #expect(out.autoCorrectStamp == "12da63bde6b83a8b")
        // Neither stamp is its own input.
        var bare = out
        bare.autoCorrectStamp = nil
        bare.autoCorrectReplaceableStamp = nil
        #expect(bare.contentStamp == out.contentStamp)
        #expect(bare.replaceableContentStamp == out.replaceableContentStamp)
        // The key is written, and read back.
        let json = String(decoding: try ConsonantChoiceTests.sortedEncoder().encode(out), as: UTF8.self)
        #expect(json.contains(#""autoCorrectReplaceableStamp":""#))
        #expect(try JSONDecoder().decode(PitchEditSet.self, from: Data(json.utf8)) == out)
        // A FRESH output reads as un-edited under BOTH predicates: were
        // `contentStamp` to stop clearing the new stamp, every new preset
        // vocal would ask at once and the wire's replaceExisting:false would
        // refuse it.
        #expect(out.hasHandEditsSinceAutoCorrect == false)
        #expect(out.hasHandEditsARerunWouldReplace(Self.natural) == false)
    }

    /// Planted and seen red (W7-NTU P-r1-fold, 2026-10-04 window R1W3; the line said "to be planted" until it has been): `replaceableContentStamp`
    /// folding the slide smoothness too (a Slides pick would stop asking).
    @Test("only what a preset KEEPS is folded: a voice size or a consonant choice alone does not ask; a note, Slides, the retune speed, a voice size set back to none, or an OFF nobody chose does")
    func onlyKeptSettingsAreFolded() throws {
        let out = Self.output()
        func asks(_ change: (inout PitchEditSet) -> Void) -> Bool {
            var set = out
            change(&set)
            return set.hasHandEditsARerunWouldReplace(Self.natural)
        }
        // Kept by the next preset: nothing to lose.
        #expect(!asks { $0.formantCorrection = 0.6 })
        #expect(!asks { $0.formantCorrection = 0 })
        #expect(!asks { $0.consonantProtection = .offByChoice })
        #expect(!asks { $0.formantCorrection = 0.25; $0.consonantProtection = .offByChoice })
        // Replaced by the next preset: asks.
        #expect(asks { $0.segments[0].pitchOffsetCents += 10 })
        #expect(asks { $0.segments[1].formantOffsetSemitones = -2 })
        #expect(asks { $0.transitionSlopeCentsPerSecond = 9000 })
        #expect(asks { $0.retuneMs = 300 })
        #expect(asks { $0.formantCorrection = nil })
        #expect(asks { $0.consonantProtection = .offByDefault })
        // A kept change beside a replaced one: asks.
        #expect(asks { $0.formantCorrection = 0.6; $0.segments[0].pitchOffsetCents += 10 })
        // The whole-set rule still says "changed" for the kept ones (it is the
        // wire refusal's, deliberately unchanged).
        var voice = out
        voice.formantCorrection = 0.6
        #expect(voice.hasHandEditsSinceAutoCorrect)
    }

    @Test("options that NAME a voice size fold nothing: that preset replaces the voice size, so a hand-set one asks (only the wire can name one)")
    func namedVoiceSizeFoldsNothing() throws {
        var named = Self.natural
        named.formantCorrection = 0.3
        #expect(named.formantCorrectionOverride == 0.3, "the fixture does not name a voice size")
        let out = Self.output()
        #expect(out.hasHandEditsARerunWouldReplace(named) == false, "an untouched output asks")
        var voice = out
        voice.formantCorrection = 0.6
        #expect(voice.hasHandEditsARerunWouldReplace(named))
        var consonants = out
        consonants.consonantProtection = .offByChoice
        #expect(consonants.hasHandEditsARerunWouldReplace(named), "conservative on purpose: nothing is folded")
    }

    // MARK: - The REAL store's carry rule

    /// Planted and seen red (W7-NTU P-r1-store, 2026-10-04 window R1W4; the line said "to be planted" until it has been):
    /// `stampedAsAutoCorrectOutput()` writing the UNFOLDED content stamp as the
    /// replaceable one (a carried amount would ask again after the next preset).
    @Test("through the REAL store: a voice size and a consonant choice changed after a preset do not ask, the store's next preset KEEPS both, and its output, carrying a voice size that is not the seed's, still lets a later voice size pass; a Slides pick asks; the wire's replaceExisting:false still refuses a kept-only change")
    @MainActor
    func theStoreKeepsWhatTheFoldSkips() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w7ntu-r1-\(UUID().uuidString).wav")
        try Data([0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = Clip(name: "Lead", startBeat: 0, lengthBeats: 8, audioFileURL: url)
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [clip])])
        let engine = ReplaceableStampFakeEngine()
        store.engine = engine
        func stored() throws -> PitchEditSet { try #require(store.tracks[0].clips[0].pitchEdits) }

        _ = try await store.autoCorrectClipPitch(clipId: clip.id, options: Self.natural)
        let first = try stored()
        #expect(first.autoCorrectReplaceableStamp != nil, "the store's preset did not write the new stamp")
        #expect(first.hasHandEditsARerunWouldReplace(Self.natural) == false)

        _ = try store.setClipFormantCorrection(clipId: clip.id, amount: 0.6)
        _ = try store.setClipConsonantProtection(clipId: clip.id, enabled: false)
        let kept = try stored()
        #expect(kept.segments == first.segments, "a setting moved a note")
        #expect(kept.hasHandEditsARerunWouldReplace(Self.natural) == false, "a kept-only change asks")

        // The wire's refusal keeps the whole-set rule (deliberate, named in the
        // banner): it still refuses this state.
        await #expect(throws: (any Error).self) {
            try await store.autoCorrectClipPitch(clipId: clip.id, options: Self.natural,
                                                 replaceExisting: false)
        }

        // The store's own preset: the two settings stay, the notes are the
        // preset's, and nothing else is lost.
        _ = try await store.autoCorrectClipPitch(clipId: clip.id, options: Self.natural)
        let second = try stored()
        #expect(second.formantCorrection == 0.6, "the voice size the fold skipped was NOT kept")
        #expect(second.consonantProtection == .offByChoice, "the consonant choice the fold skipped was NOT kept")
        #expect(second.segments.map(\.pitchOffsetCents) == first.segments.map(\.pitchOffsetCents))
        #expect(second.transitionSlopeCentsPerSecond == first.transitionSlopeCentsPerSecond)
        #expect(second.retuneMs == first.retuneMs)

        // Its output carries 0.6, not the seed: a later voice size still passes.
        _ = try store.setClipFormantCorrection(clipId: clip.id, amount: 0.9)
        #expect(try stored().hasHandEditsARerunWouldReplace(Self.natural) == false)

        // A Slides pick is replaced by a preset: it asks.
        _ = try store.setClipPitchTransitionSmoothness(clipId: clip.id, centsPerSecond: 9000)
        #expect(try stored().hasHandEditsARerunWouldReplace(Self.natural))
        #expect(engine.detectCalls == 2)
    }
}

/// The store's detection, stubbed: two voiced runs at 225 Hz and 250 Hz
/// (`PitchCorrectionWriterTests`' fake and `melodicResult`, copied, because
/// test files cannot share a private type).
@MainActor
private final class ReplaceableStampFakeEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted
    var detectCalls = 0

    func detectPitch(inFileAt url: URL, fromSeconds: Double, durationSeconds: Double,
                     confidenceThreshold: Double,
                     silenceFloorDbfs: Double) async throws -> PitchDetectionResult {
        detectCalls += 1
        var frames: [ClipPitchFrame] = []
        for i in 0..<4 {
            frames.append(ClipPitchFrame(timeSeconds: Double(i) * 0.016, frequencyHz: 225.0,
                                         confidence: 0.95, levelDbfs: -12, absence: nil))
        }
        frames.append(ClipPitchFrame(timeSeconds: 0.064, frequencyHz: nil, confidence: 0.1,
                                     levelDbfs: -70, absence: .belowConfidence))
        for i in 0..<4 {
            frames.append(ClipPitchFrame(timeSeconds: 0.08 + Double(i) * 0.016, frequencyHz: 250.0,
                                         confidence: 0.95, levelDbfs: -12, absence: nil))
        }
        let voiced = frames.filter { $0.frequencyHz != nil }.count
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count,
            voicedFrameCount: voiced, voicedFraction: Double(voiced) / Double(frames.count),
            frameRateHz: 62.5, analysisSampleRateHz: 16_000, sourceSampleRateHz: 44_100,
            windowStartSeconds: 0, windowDurationSeconds: 0.15,
            confidenceThreshold: 0.9, silenceFloorDbfs: -75,
            minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
    }

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
}
