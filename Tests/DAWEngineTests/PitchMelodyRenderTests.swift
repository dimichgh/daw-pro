import DAWCore
import Foundation
import Testing

@testable import DAWEngine

// Tune to Melody, M2 (W7-TTM2): THE FIRST RENDERED PHYSICS CHECK (design
// `2026-09-24-unpitched-notes-presets-midi-targets.md` §3.6 "Physics"). M1 proved the plan's
// cents by arithmetic; this proves the SOUND, through the real path a user's click takes:
//
//     a WAV on disk -> ProjectStore.autoCorrectClipPitchReport(…, melody:)   (the store)
//       -> detectClipPitch -> ClipPitchAnalyzer.detect                       (the PRODUCT detector)
//       -> PitchAutoCorrect.build(…, melody:) -> one performEdit             (the stored table)
//       -> StretchRenderCache.renderAudio(Params(clip:))                     (the offline render)
//       -> M23QToneTracker                                                   (an INDEPENDENT tracker)
//
// The "voice" is a 12-partial harmonic tone, not a sine: SwiftF0 leaves a pure sine
// unvoiced at 147 and 220 Hz (W7-LAG's census), and this fixture sits at 215-330 Hz.
// Every pitch is inside `M23QToneTracker`'s 150-400 Hz band, and no second harmonic is.
//
// ⛔ Distinct bytes prove nothing: every assertion is a tracked pitch against a MIDI note, and
// each test carries a control that must come out the other way.
//
// An EXTENSION of the existing `@MainActor` suite `StretchEngineTests` (the @MainActor census
// has one slot left): the store is main-actor, and so is this suite. Names start with
// `tuneToMelodyRender`.

/// The store's engine for these tests: detection is the PRODUCT detector on the real file,
/// exactly what `AudioEngine.detectPitch` runs (`Task.detached` + `ClipPitchAnalyzer.detect`);
/// everything else is inert. No audio device is opened.
@MainActor
private final class MelodyDetectEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted
    var lastDetection: PitchDetectionResult?

    func detectPitch(inFileAt url: URL, fromSeconds: Double, durationSeconds: Double,
                     confidenceThreshold: Double,
                     silenceFloorDbfs: Double) async throws -> PitchDetectionResult {
        let result = try await Task.detached(priority: .userInitiated) {
            try ClipPitchAnalyzer.detect(
                fileAt: url, fromSeconds: fromSeconds, durationSeconds: durationSeconds,
                confidenceThreshold: confidenceThreshold, silenceFloorDbfs: silenceFloorDbfs)
        }.value
        lastDetection = result
        return result
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

/// The fixture, one home. 120 bpm, so a timeline beat b is source second b/2 (the vocal starts
/// at beat 0 and plays its file from 0, ratio 1).
private enum MelodyRenderFixture {
    static let sampleRate = 48_000.0
    static let seconds = 3.2
    /// The three sung spans, source seconds; the melody sounds over exactly these.
    static let spans: [(start: Double, end: Double)] = [(0.2, 1.0), (1.2, 2.0), (2.2, 3.0)]
    /// The melody: A3, C4, E4.
    static let melody = [57, 60, 64]
    /// A rendered note is ON its melody note within this many cents (the brief's bound).
    static let toleranceCents = 10.0

    static func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }
    static func midi(_ hz: Double) -> Double { 69 + 12 * log2(hz / 440) }

    /// The sung take: a harmonic tone per span at `sung[i]` (MIDI), 10 ms raised-cosine edges,
    /// digital silence between the notes.
    static func voice(_ sung: [Double]) -> [Float] {
        var out = [Float](repeating: 0, count: Int(seconds * sampleRate))
        let ramp = Int(0.01 * sampleRate)
        for (span, pitch) in zip(spans, sung) {
            let note = PitchTrackerAccuracyTests.Fixture.tone(
                seconds: span.end - span.start, amplitude: 0.5, partials: 12,
                sampleRate: sampleRate) { _ in hz(pitch) }
            let first = Int(span.start * sampleRate)
            for (i, sample) in note.enumerated() where first + i < out.count {
                let edge = min(i, note.count - 1 - i)
                let gain = edge < ramp ? 0.5 - 0.5 * cos(.pi * Double(edge) / Double(ramp)) : 1
                out[first + i] = sample * Float(gain)
            }
        }
        return out
    }

    /// The pitch each note SOUNDS at, MIDI: the median tracked pitch over the middle half of
    /// its span, clear of the retune ramps and the edges.
    static func trackedMidi(_ samples: [Float]) -> [Double] {
        let estimates = M23QToneTracker.track(samples, sampleRate: sampleRate, band: 150...400)
        return spans.map { span in
            let quarter = (span.end - span.start) / 4
            let frames = ((span.start + quarter) * sampleRate)..<((span.end - quarter) * sampleRate)
            guard let hz = M23QToneTracker.medianHz(estimates, centreIn: frames) else { return .nan }
            return midi(hz)
        }
    }

    static func log(_ message: String) { print("tune-to-melody-render| \(message)") }
}

extension StretchEngineTests {

    /// A store at 120 bpm holding the take as a real WAV (a vocal clip) and the melody (a MIDI
    /// clip on a lead track), with the product detector behind it.
    private func melodyRenderStore(sung: [Double]) throws
        -> (store: ProjectStore, engine: MelodyDetectEngine, vocalID: UUID, leadID: UUID,
            source: [Float], dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-ttm2-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("take.wav")
        let source = MelodyRenderFixture.voice(sung)
        try M23QComparisonPair.writeWAV([source], sampleRate: MelodyRenderFixture.sampleRate, to: url)
        let vocal = Clip(name: "Take", startBeat: 0, lengthBeats: MelodyRenderFixture.seconds * 2,
                         audioFileURL: url)
        let notes = zip(MelodyRenderFixture.spans, MelodyRenderFixture.melody).map { span, pitch in
            MIDINote(pitch: pitch, startBeat: span.start * 2, lengthBeats: (span.end - span.start) * 2)
        }
        let lead = Clip(name: "Lead", startBeat: 0, lengthBeats: 8, notes: notes)
        var transport = TransportState()
        transport.tempoBPM = 120
        let store = ProjectStore(
            tracks: [Track(name: "Vocal", kind: .audio, clips: [vocal]),
                     Track(name: "Lead", kind: .instrument, clips: [lead])],
            transport: transport)
        let engine = MelodyDetectEngine()
        store.engine = engine
        return (store, engine, vocal.id, lead.id, source, dir)
    }

    /// THE PRODUCT RENDER of the vocal clip as the store holds it now.
    private func renderVocal(_ store: ProjectStore, _ source: [Float]) throws -> [Float] {
        var whole = [source]
        let out = try StretchRenderCache.renderAudio(
            whole: &whole, window: nil, sampleRate: MelodyRenderFixture.sampleRate,
            params: StretchRenderCache.Params(clip: store.tracks[0].clips[0]),
            curveContour: nil, isCancelled: { false })
        return out.output.planar[0]
    }

    /// What the product detector read for each sung span, MIDI (its median over the span).
    private func detectedMidi(_ engine: MelodyDetectEngine) -> [Double] {
        let frames = engine.lastDetection?.frames ?? []
        return MelodyRenderFixture.spans.map { span in
            let hz = frames.filter { $0.timeSeconds >= span.start && $0.timeSeconds < span.end }
                .compactMap(\.frequencyHz).sorted()
            return hz.isEmpty ? .nan : MelodyRenderFixture.midi(hz[hz.count / 2])
        }
    }

    @Test("tuneToMelodyRender X1: a voice 40 c flat of a three-note melody RENDERS on each melody note within 10 c; the untuned render does not")
    func tuneToMelodyRenderLandsOnEachNote() async throws {
        let sung = [56.6, 59.6, 63.6]
        let f = try melodyRenderStore(sung: sung)
        defer { try? FileManager.default.removeItem(at: f.dir) }

        // INSTRUMENT CONTROL first: the same render with no tuning reads each note 40 c flat,
        // so this tracker CAN see a 40 c miss, and "on the melody" below is not its default.
        let untuned = MelodyRenderFixture.trackedMidi(try renderVocal(f.store, f.source))
        for (played, target) in zip(untuned, MelodyRenderFixture.melody) {
            let cents = (played - Double(target)) * 100
            MelodyRenderFixture.log("X1 untuned target \(target) reads \(String(format: "%+.2f", cents)) c")
            #expect(abs(cents + 40) < MelodyRenderFixture.toleranceCents, "untuned \(target): \(cents) c")
        }

        let report = try await f.store.autoCorrectClipPitchReport(
            clipId: f.vocalID, options: PitchCorrectionPreset.natural.options(scale: .chromatic),
            melody: MelodyTuning(source: .clip(f.leadID)))
        let melody = try #require(report.melody)
        #expect(melody.matchedParts == 3, "the product detector found three held notes under the melody")
        #expect(report.appliedOptions.strength == 1)
        let detected = detectedMidi(f.engine)
        let tuned = MelodyRenderFixture.trackedMidi(try renderVocal(f.store, f.source))
        for i in 0..<3 {
            let cents = (tuned[i] - Double(MelodyRenderFixture.melody[i])) * 100
            MelodyRenderFixture.log("X1 note \(i) sung \(sung[i]) detected \(String(format: "%.3f", detected[i])) "
                + "rendered \(String(format: "%.3f", tuned[i])) -> \(String(format: "%+.2f", cents)) c from \(MelodyRenderFixture.melody[i])")
            #expect(abs(cents) < MelodyRenderFixture.toleranceCents,
                    "note \(i): \(cents) c from MIDI \(MelodyRenderFixture.melody[i])")
        }
    }

    @Test("tuneToMelodyRender X2: the MELODY decides the note, not the scale: a note sung 140 c under E4 renders on E4; the same pass without the melody lands a semitone off")
    func tuneToMelodyRenderMelodyNotScaleDecides() async throws {
        // The third note is sung at 62.6: its nearest chromatic note is 63 (E-flat), the
        // melody's is 64 (E). Only a pass that reads the melody puts it on 64; Natural's own
        // 0.85 would also stop 0.15 · 140 = 21 c short of it.
        let sung = [56.6, 59.6, 62.6]
        let f = try melodyRenderStore(sung: sung)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let natural = PitchCorrectionPreset.natural.options(scale: .chromatic)

        // DESIGN CONTROL: the same take, the same preset, NO melody.
        _ = try await f.store.autoCorrectClipPitchReport(clipId: f.vocalID, options: natural)
        let plain = MelodyRenderFixture.trackedMidi(try renderVocal(f.store, f.source))
        let plainCents = (plain[2] - 64) * 100
        MelodyRenderFixture.log("X2 control (no melody) third note \(String(format: "%.3f", plain[2])) -> \(String(format: "%+.2f", plainCents)) c from 64")
        #expect(abs(plainCents) > 50, "without the melody the third note must NOT land on E4: \(plainCents) c")

        let report = try await f.store.autoCorrectClipPitchReport(
            clipId: f.vocalID, options: natural, melody: MelodyTuning(source: .clip(f.leadID)))
        #expect(report.melody?.matchedParts == 3)
        let detected = detectedMidi(f.engine)
        let tuned = MelodyRenderFixture.trackedMidi(try renderVocal(f.store, f.source))
        for i in 0..<3 {
            let cents = (tuned[i] - Double(MelodyRenderFixture.melody[i])) * 100
            MelodyRenderFixture.log("X2 note \(i) sung \(sung[i]) detected \(String(format: "%.3f", detected[i])) "
                + "rendered \(String(format: "%.3f", tuned[i])) -> \(String(format: "%+.2f", cents)) c from \(MelodyRenderFixture.melody[i])")
            #expect(abs(cents) < MelodyRenderFixture.toleranceCents,
                    "note \(i): \(cents) c from MIDI \(MelodyRenderFixture.melody[i])")
        }
    }
}
