import DAWAppKit
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

// Tune to Melody, M3 (W7-TTM3): WHAT EACH PRESET CHIP STILL CHANGES IN MELODY MODE, MEASURED ON THE
// RENDER. A melody pass runs every preset at strength 1 (the store's rule 5), so a chip there sends
// only its retune speed (Gentle 200 ms, Natural 110, Tight 40, Hard Tune 30) and its vibrato rule
// (Hard Tune alone flattens). The orchestrator's ruling: "if a chip changes NOTHING audible in
// melody mode, it should not be offered: report which ones, with the measurement". This is that
// measurement, through the card's OWN request (`TuneToMelodyCard.options` + `.melodyTuning`, the
// store call the door makes):
//
//     a WAV on disk -> ProjectStore.autoCorrectClipPitchReport(…, melody:)   (the store)
//       -> ClipPitchAnalyzer.detect (the PRODUCT detector) -> the stored table
//       -> StretchRenderCache.renderAudio, with the PRODUCT's contour rule   (the offline render)
//       -> M23QToneTracker                                                   (an INDEPENDENT tracker)
//
// ⚠️ THE CONTOUR RULE IS THE PRODUCT'S (`StretchRenderCache.resolveRenderContour`): a set that
// wants contour shaping renders against the detected contour, anything else with nil. A first
// draft passed nil for every chip (TTM2's `PitchMelodyRenderTests` does): all four then read the
// same to 0.1 c, because only Hard Tune's set wants the contour (MEASURED 21:39-21:40).
//
// Two takes, each a 12-partial harmonic tone (TTM2's fixture: SwiftF0 leaves a pure sine unvoiced;
// every pitch inside the tracker's 150-400 Hz band):
//  * C1 ISOLATED NOTES: three 0.8 s notes, each 40 c flat of A3/C4/E4, ±35 c vibrato at 5.5 Hz.
//    Readings: ONSET (mean error over one vibrato period from 30 ms in) and WOBBLE (the 5.5 Hz
//    amplitude over the middle half).
//  * C2 A LEGATO JOIN: two notes with no gap, A 40 c flat of 57, B 30 c sharp of 60, no vibrato, so
//    the correction jumps from +40 to -30 c at the join. Reading: mean |error| over the 100 ms on
//    each side of the join (20 ms clear of it; the tracker's window is 21.3 ms), where a slower
//    retune is still crossing over.
//
// ⛔ Every assertion is a measured direction or a characterization pin, each beside an instrument
// control that must come out the other way (the untuned render reads the take's own error).
//
// An EXTENSION of the existing `@MainActor` suite `StretchEngineTests` (the census has one slot
// left). Names start with `tuneToMelodyChips`.

/// The product detector behind an inert engine (TTM2's `MelodyDetectEngine`, copied: test files
/// cannot share a private type). No audio device is opened.
@MainActor
private final class ChipDetectEngine: AudioEngineControlling {
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

/// One sung note of a take: its span (source seconds), its melody note, and how it was sung.
private struct ChipNote {
    let start: Double
    let end: Double
    let melody: Int
    let offCents: Double
    let vibratoCents: Double
}

/// A take on disk, the store over it (a vocal plus a "Lead" melody under it), and the product
/// render. Held strongly for the whole test: the store's `engine` does not keep the engine alive
/// (MEASURED: a temporary refused the first pass with `.engineUnavailable`).
@MainActor
private final class ChipRig {
    static let sampleRate = 48_000.0
    static let seconds = 3.2
    static let vibratoHz = 5.5

    let notes: [ChipNote]
    let source: [Float]
    let store: ProjectStore
    let engine = ChipDetectEngine()
    let vocalID: UUID
    let dir: URL

    static func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

    /// Each RUN of touching notes is ONE continuous tone (no phase break at a join), each note at
    /// `melody + offCents` (± its vibrato), with 10 ms raised-cosine edges at the run's ends and
    /// digital silence elsewhere.
    init(_ notes: [ChipNote]) throws {
        self.notes = notes
        var out = [Float](repeating: 0, count: Int(Self.seconds * Self.sampleRate))
        var runs: [[ChipNote]] = []
        for note in notes {
            if let last = runs.last?.last, abs(last.end - note.start) < 1e-9 {
                runs[runs.count - 1].append(note)
            } else {
                runs.append([note])
            }
        }
        let ramp = Int(0.01 * Self.sampleRate)
        for run in runs {
            let start = run[0].start
            let tone = PitchTrackerAccuracyTests.Fixture.tone(
                seconds: run[run.count - 1].end - start, amplitude: 0.5, partials: 12,
                sampleRate: Self.sampleRate) { t in
                    let at = start + t
                    let note = run.last { at >= $0.start } ?? run[0]
                    return Self.hz(Double(note.melody) + note.offCents / 100
                        + note.vibratoCents / 100 * sin(2 * .pi * Self.vibratoHz * (at - note.start)))
                }
            let first = Int(start * Self.sampleRate)
            for (i, sample) in tone.enumerated() where first + i < out.count {
                let edge = min(i, tone.count - 1 - i)
                let gain = edge < ramp ? 0.5 - 0.5 * cos(.pi * Double(edge) / Double(ramp)) : 1
                out[first + i] = sample * Float(gain)
            }
        }
        source = out
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-ttm3-chips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("take.wav")
        try M23QComparisonPair.writeWAV([out], sampleRate: Self.sampleRate, to: url)
        let vocal = Clip(name: "Take", startBeat: 0, lengthBeats: Self.seconds * 2, audioFileURL: url)
        vocalID = vocal.id
        let midi = notes.map {
            MIDINote(pitch: $0.melody, startBeat: $0.start * 2, lengthBeats: ($0.end - $0.start) * 2)
        }
        var transport = TransportState()
        transport.tempoBPM = 120
        store = ProjectStore(
            tracks: [Track(name: "Vocal", kind: .audio, clips: [vocal]),
                     Track(name: "Lead", kind: .instrument,
                           clips: [Clip(name: "Lead", startBeat: 0, lengthBeats: 8, notes: midi)])],
            transport: transport)
        store.engine = engine
    }

    func removeTake() { try? FileManager.default.removeItem(at: dir) }

    /// The card's request for `preset`, sent to the store the way the door sends it.
    func tuneWithCard(_ preset: PitchCorrectionPreset) async throws -> PitchAutoCorrectReport {
        var card = TuneToMelodyCard(vocal: store.tracks[0].clips[0], vocalTrackName: "Vocal",
                                    tracks: store.tracks, tempoMap: store.transport.tempoMap)
        card.choosePreset(preset)
        return try await store.autoCorrectClipPitchReport(
            clipId: vocalID, options: card.options, melody: card.melodyTuning)
    }

    /// THE PRODUCT RENDER of the vocal as stored, with the product's contour rule.
    func render() throws -> [Float] {
        var whole = [source]
        let clip = store.tracks[0].clips[0]
        let contour: PitchRenderContour? = clip.pitchEdits.flatMap { set in
            set.needsDetectedContour ? engine.lastDetection.map { .detected($0) } : nil
        }
        let out = try StretchRenderCache.renderAudio(
            whole: &whole, window: nil, sampleRate: Self.sampleRate,
            params: StretchRenderCache.Params(clip: clip),
            curveContour: contour, isCancelled: { false })
        return out.output.planar[0]
    }

    var wantsContour: Bool { store.tracks[0].clips[0].pitchEdits?.needsDetectedContour == true }

    func track(_ samples: [Float]) -> [M23QToneEstimate] {
        M23QToneTracker.track(samples, sampleRate: Self.sampleRate, band: 150...400)
    }

    /// Cents from `note`'s melody note, for every estimate centred in [from, to) seconds.
    func errors(_ estimates: [M23QToneEstimate], _ note: ChipNote, from: Double, to: Double)
        -> [(frame: Double, value: Double)] {
        let ref = Self.hz(Double(note.melody))
        return estimates
            .filter { $0.centreFrame >= from * Self.sampleRate && $0.centreFrame < to * Self.sampleRate }
            .map { (frame: $0.centreFrame, value: M23QToneTracker.cents($0.hz, above: ref)) }
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
    }

    static func log(_ message: String) { print("tune-to-melody-chips| \(message)") }
    static func fmt(_ value: Double) -> String { String(format: "%+.1f", value) }
}

extension StretchEngineTests {

    /// C1's two readings of a render, averaged over the take's notes.
    private func tuneToMelodyChipsReadIsolated(_ rig: ChipRig, _ samples: [Float])
        -> (onset: Double, wobble: Double) {
        let estimates = rig.track(samples)
        var onsets: [Double] = []
        var wobbles: [Double] = []
        for note in rig.notes {
            let lo = note.start + 0.030
            onsets.append(ChipRig.mean(
                rig.errors(estimates, note, from: lo, to: lo + 1 / ChipRig.vibratoHz).map(\.value)))
            let quarter = (note.end - note.start) / 4
            let mid = rig.errors(estimates, note, from: note.start + quarter, to: note.end - quarter)
            wobbles.append(M23QToneTracker.fitSinusoid(mid, rateHz: ChipRig.vibratoHz,
                                                       sampleRate: ChipRig.sampleRate)?.amplitude ?? .nan)
        }
        return (ChipRig.mean(onsets), ChipRig.mean(wobbles))
    }

    @Test("tuneToMelodyChips C1: on isolated notes with vibrato, Gentle, Natural and Tight render alike in melody mode; only Hard Tune differs (it thins the wobble, as it does without a melody)")
    func tuneToMelodyChipsOnIsolatedNotes() async throws {
        let rig = try ChipRig([
            ChipNote(start: 0.2, end: 1.0, melody: 57, offCents: -40, vibratoCents: 35),
            ChipNote(start: 1.2, end: 2.0, melody: 60, offCents: -40, vibratoCents: 35),
            ChipNote(start: 2.2, end: 3.0, melody: 64, offCents: -40, vibratoCents: 35),
        ])
        defer { rig.removeTake() }
        // INSTRUMENT CONTROL: untuned, the tracker reads the take's own -40 c and its own wobble.
        let untuned = tuneToMelodyChipsReadIsolated(rig, try rig.render())
        ChipRig.log("C1 untuned: onset \(ChipRig.fmt(untuned.onset)) c, wobble \(ChipRig.fmt(untuned.wobble)) c")
        #expect(abs(untuned.onset + 40) < 10, "untuned onset \(untuned.onset)")
        #expect(untuned.wobble > 20, "the tracker must see the take's wobble: \(untuned.wobble)")

        var read: [PitchCorrectionPreset: (onset: Double, wobble: Double)] = [:]
        for preset in TuneToMelodyCard.presets {
            let report = try await rig.tuneWithCard(preset)
            #expect(report.melody?.matchedParts == 3,
                    "\(preset): \(String(describing: report.melody?.matchedParts))")
            #expect(report.appliedOptions.strength == 1, "\(preset): a melody pass runs at strength 1")
            let r = tuneToMelodyChipsReadIsolated(rig, try rig.render())
            read[preset] = r
            ChipRig.log("C1 \(preset.rawValue) (retune \(Int(preset.options().retuneMs)) ms, vibrato "
                + "\(preset.options().preserveVibrato ? "kept" : "flattened"), detected contour "
                + "\(rig.wantsContour ? "yes" : "no")): onset \(ChipRig.fmt(r.onset)) c, "
                + "wobble \(ChipRig.fmt(r.wobble)) c")
        }
        // SCALE-MODE CONTROL: Hard Tune with NO melody (the preset door's own pass) on the same
        // take. Melody-mode Hard Tune flattening much less than this would mean the melody path
        // weakens it.
        _ = try await rig.store.autoCorrectClipPitchReport(
            clipId: rig.vocalID, options: PitchCorrectionPreset.hardTune.options())
        let scaleHard = tuneToMelodyChipsReadIsolated(rig, try rig.render())
        ChipRig.log("C1 hardTune WITHOUT a melody: onset \(ChipRig.fmt(scaleHard.onset)) c, "
            + "wobble \(ChipRig.fmt(scaleHard.wobble)) c")

        let gentle = try #require(read[.gentle])
        let natural = try #require(read[.natural])
        let tight = try #require(read[.tight])
        let hard = try #require(read[.hardTune])
        // Every chip pulled the onset most of the way from -40 c (the pass acted).
        for (preset, r) in read {
            #expect(abs(r.onset) < 15, "\(preset) onset \(r.onset)")
        }
        // Hard Tune is the one that differs: it thins the wobble the others keep (MEASURED in
        // scratch, chips3: 23.3 c vs 35.9 c), about as much as it does with no melody.
        #expect(hard.wobble < 0.8 * tight.wobble, "Hard Tune \(hard.wobble) vs Tight \(tight.wobble)")
        #expect(abs(hard.wobble - scaleHard.wobble) < 5,
                "melody-mode Hard Tune \(hard.wobble) vs no-melody Hard Tune \(scaleHard.wobble)")
        // CHARACTERIZATION PIN: on isolated notes the three vibrato-keeping chips render alike
        // (MEASURED chips3: onsets -7.3/-6.7/-6.7 c, wobbles 35.9 each). If retune speed starts
        // to show here, this goes red and the chips' lines must be re-read against the new sound.
        let onsets = [gentle.onset, natural.onset, tight.onset]
        let wobbles = [gentle.wobble, natural.wobble, tight.wobble]
        #expect((onsets.max() ?? 0) - (onsets.min() ?? 0) < 2, "onsets \(onsets)")
        #expect((wobbles.max() ?? 0) - (wobbles.min() ?? 0) < 1, "wobbles \(wobbles)")
    }

    /// The two joined notes `a` then `b` as a take: the untuned control (each side must read its
    /// own sung error, within 8 c), then every chip through the card, each read as the mean
    /// |error| over the 100 ms on either side of the join, 20 ms clear of it.
    private func tuneToMelodyChipsReadJoin(_ label: String, _ a: ChipNote, _ b: ChipNote,
                                           untunedBefore: Double, untunedAfter: Double)
        async throws -> (untuned: Double, read: [PitchCorrectionPreset: Double]) {
        let rig = try ChipRig([a, b])
        defer { rig.removeTake() }
        let join = b.start
        func readJoin(_ samples: [Float]) -> (before: Double, after: Double) {
            let estimates = rig.track(samples)
            let before = rig.errors(estimates, a, from: join - 0.12, to: join - 0.02).map { abs($0.value) }
            let after = rig.errors(estimates, b, from: join + 0.02, to: join + 0.12).map { abs($0.value) }
            return (ChipRig.mean(before), ChipRig.mean(after))
        }
        // INSTRUMENT CONTROL: untuned, each side reads the take's own error.
        let untuned = readJoin(try rig.render())
        ChipRig.log("\(label) untuned: |err| before \(ChipRig.fmt(untuned.before)) c, after \(ChipRig.fmt(untuned.after)) c")
        #expect(abs(untuned.before - untunedBefore) < 8 && abs(untuned.after - untunedAfter) < 8,
                "\(label) untuned \(untuned)")
        var read: [PitchCorrectionPreset: Double] = [:]
        for preset in TuneToMelodyCard.presets {
            let report = try await rig.tuneWithCard(preset)
            #expect(report.melody?.matchedParts == 2,
                    "\(label) \(preset): \(String(describing: report.melody?.matchedParts))")
            let r = readJoin(try rig.render())
            read[preset] = (r.before + r.after) / 2
            ChipRig.log("\(label) \(preset.rawValue) (retune \(Int(preset.options().retuneMs)) ms, detected contour "
                + "\(rig.wantsContour ? "yes" : "no")): |err| before \(ChipRig.fmt(r.before)) c, after "
                + "\(ChipRig.fmt(r.after)) c, mean \(ChipRig.fmt((r.before + r.after) / 2)) c")
        }
        return ((untuned.before + untuned.after) / 2, read)
    }

    @Test("tuneToMelodyChips C2: at a legato join where the correction jumps (+40 to -30 c), a slower chip crosses over more slowly in melody mode")
    func tuneToMelodyChipsAtALegatoJoin() async throws {
        let a = ChipNote(start: 0.4, end: 1.4, melody: 57, offCents: -40, vibratoCents: 0)
        let b = ChipNote(start: 1.4, end: 2.4, melody: 60, offCents: 30, vibratoCents: 0)
        let (untunedMean, read) = try await tuneToMelodyChipsReadJoin("C2", a, b, untunedBefore: 40, untunedAfter: 30)
        let gentle = try #require(read[.gentle])
        let natural = try #require(read[.natural])
        let tight = try #require(read[.tight])
        // Every chip did act at the join: far below the untuned error.
        for (preset, value) in read {
            #expect(value < 0.75 * untunedMean, "\(preset) \(value) vs untuned \(untunedMean)")
        }
        // THE QUESTION: does retune speed show at a join? Ordered slow -> fast.
        #expect(gentle > tight + 3, "Gentle \(gentle) vs Tight \(tight) at the join")
        #expect(gentle >= natural - 0.5 && natural >= tight - 0.5, "order \(gentle) \(natural) \(tight)")
    }

    /// C2's CONTROL: the same join, but both notes sung the SAME amount off, so the correction is
    /// +40 c on both sides and does not change at the join. If retune speed showed here too, the
    /// chips would differ at EVERY join; it is predicted (PREREG C3) to show nothing.
    @Test("tuneToMelodyChips C3: at a join where the correction does NOT change (both notes 40 c flat), the chips render alike")
    func tuneToMelodyChipsAtAnEqualOffsetJoin() async throws {
        let a = ChipNote(start: 0.4, end: 1.4, melody: 57, offCents: -40, vibratoCents: 0)
        let b = ChipNote(start: 1.4, end: 2.4, melody: 60, offCents: -40, vibratoCents: 0)
        let (untunedMean, read) = try await tuneToMelodyChipsReadJoin("C3", a, b, untunedBefore: 40, untunedAfter: 40)
        let gentle = try #require(read[.gentle])
        let natural = try #require(read[.natural])
        let tight = try #require(read[.tight])
        for (preset, value) in read {
            #expect(value < 0.75 * untunedMean, "\(preset) \(value) vs untuned \(untunedMean)")
        }
        let three = [gentle, natural, tight]
        #expect((three.max() ?? 0) - (three.min() ?? 0) < 2, "C3 gentle/natural/tight \(three)")
    }
}
