import AVFAudio
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// contour-to-render on a REAL VOICE — the four presets rendered through the
/// PRODUCT path (`StretchRenderCache.renderIfNeeded`, contour fetched or
/// detected inside the render job), so a person can pick, and so the numbers
/// the report quotes come from the audio the product actually makes.
///
/// Env-gated, because the recording is the user's and not in the tree:
///
///     CONTOUR_LISTEN_SOURCE=/path/dry.wav CONTOUR_LISTEN_OUT=/path/outdir \
///       ./scripts/test.sh --filter ContourRenderListeningTests
///
/// Writes `00-uncorrected.wav` (the same stretcher, nothing asked of it — every
/// tuned file differs from it by the tuning alone) and one WAV per preset.
///
/// ⭐ **SCORED PER HELD NOTE PART, ON TWO LEGS (p2-seg-F-metric, 2026-09-24).**
/// Every wander figure and every gate here reads the HELD parts of the note
/// table (`HeldPartWander`, in `PitchWanderMeter.swift`). A `.transition` plays
/// as sung by design, and a whole multi-note run is no longer one "note".
/// Hard Tune must pass two legs:
///  * leg W: its held notes are flat;
///  * leg N: each held note is on its OWN note.
///
/// Two plants prove the gate can fail:
///  * P1, the constant-offset fallback, is not flat;
///  * P2, `.runPin`, is flat but on the wrong note. That is the trap the
///    per-segment metric fell into: it scored a phrase pinned to one note as a
///    70 % flattening.
///
/// Both plants are written beside the presets (`90-`, `91-`). So is
/// `held-parts.json`, from which the second instrument, an independent YIN,
/// reads the same parts.
///
/// The pre-registration and the measurements are in
/// `~/Music/DAW Pro Dogfood/2026-09-24 p2-seg physics/F-metric/`.
///
/// Loudness, true peak and MP3 encoding happen outside, on the files written —
/// ONE rule for every file (2026-09-24 folder): a pure linear gain to a common
/// integrated-loudness target, no limiter, 256 kbps CBR mono 48 kHz:
///
///     ffmpeg -hide_banner -i X.wav -af volume=<target − measured LUFS>dB \
///            -ar 48000 -ac 1 -c:a libmp3lame -b:a 256k X.mp3
///     ffmpeg -hide_banner -nostats -i X.mp3 -af ebur128=peak=true -f null -
///
/// and if any written MP3's true peak exceeds −1 dBTP the COMMON target is
/// lowered 0.5 LU for every file and all are redone (−21 → −22 LUFS for the
/// dry vocal). Then `remeasureTheWrittenMP3s` reads the MP3s back.
@Suite("contour-to-render — real-vocal product renders", .serialized)
struct ContourRenderListeningTests {
    static func log(_ message: String) { print("contour-listen| \(message)") }

    static let enabled = ProcessInfo.processInfo.environment["CONTOUR_LISTEN_SOURCE"] != nil
        && ProcessInfo.processInfo.environment["CONTOUR_LISTEN_OUT"] != nil
    static let decodedEnabled = ProcessInfo.processInfo.environment["CONTOUR_LISTEN_SOURCE"] != nil
        && ProcessInfo.processInfo.environment["CONTOUR_LISTEN_DECODED"] != nil

    static let files: [(PitchCorrectionPreset, String)] = [
        (.gentle, "01-gentle"), (.natural, "02-natural"),
        (.tight, "03-tight"), (.hardTune, "04-hard-tune"),
    ]

    /// The note table the edit sets are written from, zipped onto `set`. The
    /// test fails if the zip does not hold bit for bit.
    static func table(_ set: PitchEditSet, _ parts: [NotePart]) throws -> [HeldPartWander.Entry] {
        let table = HeldPartWander.table(of: set, parts: parts)
        try #require(table.mismatch == nil, "the note table does not zip onto the set: \(table.mismatch ?? "")")
        return table.entries
    }

    /// One line per measurable held part: where it is, its wander before and
    /// after, and how far it sits from its own note.
    static func logParts(_ label: String, _ verdict: HeldPartWander.Verdict,
                         _ entries: [HeldPartWander.Entry]) {
        let indexByID = Dictionary(entries.map { ($0.segment.id, $0) }, uniquingKeysWith: { a, _ in a })
        for score in verdict.scores {
            let entry = indexByID[score.segment.id]
            log(String(format:
                "  %@ part %2ld (run %2ld) %6.3f-%6.3f s %6.1f Hz -> MIDI %.0f | spread %5.1f -> %5.1f c (cut %4.0f%%) | own-note miss %+7.1f c%@",
                label as NSString, entry?.index ?? -1, entry?.part.runIndex ?? -1,
                score.segment.startSeconds, score.segment.endSeconds, score.segment.detectedHz,
                HeldPartWander.targetMidi(ofHz: score.segment.detectedHz),
                score.before.spreadCents, score.after.spreadCents, score.cut * 100,
                score.missCents,
                (abs(score.missCents) > HeldPartWander.noteToleranceCents ? "  <- OFF ITS NOTE" : "") as NSString))
        }
    }

    /// The sensitivity lines every verdict carries: leave-one-part-out, and the
    /// verdict without the notes the instrument is known to over-read.
    static func logSensitivity(_ label: String, _ verdict: HeldPartWander.Verdict, gated: Bool = true) {
        let low = verdict.without(hzBelow: HeldPartWander.lowNoteHz)
        log(String(format: "  %@ sensitivity: leave-one-part-out moves the cut by at most %.1f points | without the %ld held parts under %.0f Hz: %@",
                   label as NSString, verdict.leaveOneOutSensitivity * 100,
                   verdict.scores.count - (low?.scores.count ?? 0), HeldPartWander.lowNoteHz,
                   ((gated ? low?.summary : low?.wanderSummary) ?? "n/a") as NSString))
    }

    /// Re-measures the MP3s ACTUALLY WRITTEN, decoded back to float WAV
    /// (`ffmpeg -hide_banner -i X.mp3 -c:a pcm_f32le -ar 48000 -ac 1 X.wav`
    /// into `CONTOUR_LISTEN_DECODED`), so the figures a README quotes belong to
    /// the files a person plays — not to the renders they were made from.
    @Test("the written MP3s carry what the renders measured", .enabled(if: decodedEnabled))
    @MainActor
    func remeasureTheWrittenMP3s() throws {
        let env = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(env["CONTOUR_LISTEN_SOURCE"]))
        let dir = URL(fileURLWithPath: try #require(env["CONTOUR_LISTEN_DECODED"]))
        let sampleRate = 48_000.0
        let detection = try PitchContourCache.detectWholeFile(source, .product)
        let parts = PitchNoteSplitter.parts(in: detection.frames, frameRateHz: detection.frameRateHz)
        let reference = try TestSignals.readFile(dir.appendingPathComponent("00-uncorrected.wav"))[0]
        var verdicts: [PitchCorrectionPreset: HeldPartWander.Verdict] = [:]
        for (preset, name) in Self.files {
            let set = PitchAutoCorrect.editSet(from: detection, options: preset.options())
            let held = HeldPartWander.held(try Self.table(set, parts))
            let decoded = try TestSignals.readFile(dir.appendingPathComponent(name + ".wav"))[0]
            let before = PitchWanderMeter.readNotes(reference, sampleRate: sampleRate, segments: held)
            let verdict = try #require(HeldPartWander.verdict(
                before: before,
                after: PitchWanderMeter.readNotes(decoded, sampleRate: sampleRate, segments: held),
                segments: held, threshold: HeldPartWander.hardCutThreshold))
            let measured = Set(verdict.scores.map(\.segment.id))
            let shifts = SpectralShiftMeter.noteShifts(
                reference: reference, shifted: decoded, sampleRate: sampleRate,
                segments: held.filter { measured.contains($0.id) })
            var moved: [Double] = [], missed: [Double] = []
            for segment in held {
                guard let cents = shifts[segment.id] else { continue }
                moved.append(abs(cents))
                missed.append(abs(cents - segment.pitchOffsetCents))
            }
            verdicts[preset] = verdict
            Self.log(String(format:
                "MP3 %@.mp3 | centre correction %.1f c (|delivered - asked| median %.1f c) | %@",
                name as NSString, PitchWanderMeter.median(moved) ?? -1,
                PitchWanderMeter.median(missed) ?? -1,
                (preset == .hardTune ? verdict.summary : verdict.wanderSummary) as NSString))
        }
        let hard = try #require(verdicts[.hardTune])
        let tight = try #require(verdicts[.tight])
        Self.logSensitivity("MP3 hardTune", hard)
        #expect(hard.passesW, "Hard Tune's MP3 cut its held notes' wander by only \(Int(hard.cut * 100))%")
        #expect(hard.passesN, "a held part of Hard Tune's MP3 plays \(Int(hard.maxAbsMiss)) c from its own note")
        #expect(tight.cut < HeldPartWander.noFlatteningCeiling,
                "Tight's MP3 flattened the held notes (\(Int(tight.cut * 100))%)")
    }

    @Test("the four presets through StretchRenderCache, measured on the rendered audio",
          .enabled(if: enabled))
    @MainActor
    func renderPresetsThroughTheProductPath() async throws {
        let env = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(env["CONTOUR_LISTEN_SOURCE"]))
        let outDir = URL(fileURLWithPath: try #require(env["CONTOUR_LISTEN_OUT"]))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let input = try TestSignals.readFile(source)
        let file = try AVAudioFile(forReading: source)
        let sampleRate = file.processingFormat.sampleRate
        let mono = input[0]

        // What `clip.autoCorrectPitch` stores for an untrimmed clip of this
        // file: the store detects over the clip's whole window at the product
        // settings, which for an untrimmed clip is the whole file.
        let clock = ContinuousClock()
        let detectStarted = clock.now
        let detection = try PitchContourCache.detectWholeFile(source, .product)
        let detectTook = clock.now - detectStarted
        Self.log("detection (first in this process): \(detectTook) — \(detection.frameCount) frames, \(detection.voicedFrameCount) voiced (\(String(format: "%.1f", detection.voicedFraction * 100))%) at confidence \(detection.confidenceThreshold) / floor \(detection.silenceFloorDbfs) dBFS, runtime \(SwiftF0PitchTracker.runtimeIdentity)")

        // A FRESH cache, so the first contour-shaped render really detects.
        let cacheDir = outDir.appendingPathComponent("render-cache", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        let cache = StretchRenderCache(directory: cacheDir)

        // The reference goes through the product's OWN curve loop with nothing
        // asked of it (a flat 0-semitone curve, the product's compensation),
        // so every tuned file differs from it by the tuning alone. Compared
        // against the constant-transpose entry point for the record.
        let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: sampleRate)
        let uncorrected = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: 1,
            semitonesAtOutputFrame: { _ in 0 }, formantPreserve: false,
            compensation: compensation)
        let constant = try OfflineStretcher.stretch(
            input: input, sampleRate: sampleRate, ratio: 1, semitones: 0,
            formantPreserve: false)
        var referenceDiffering = 0
        for (a, b) in zip(uncorrected[0], constant[0]) where a.bitPattern != b.bitPattern {
            referenceDiffering += 1
        }
        Self.log("reference: zero-curve product loop vs constant-transpose stretch differ in \(referenceDiffering) of \(uncorrected[0].count) samples")
        try M23QComparisonPair.writeWAV(uncorrected, sampleRate: sampleRate,
                                        to: outDir.appendingPathComponent("00-uncorrected.wav"))

        // ── THE POPULATION: the HELD parts of the note table (p2-seg-F-metric).
        //    The splitter's parts of THIS detection, zipped bit for bit onto
        //    every set this test scores; a transition never enters, whatever
        //    its edit values (under runPin they are not identity).
        let hardOptions = PitchCorrectionPreset.hardTune.options()
        try #require(hardOptions.scale == .chromatic, "leg N's target is the nearest CHROMATIC note")
        let parts = PitchNoteSplitter.parts(in: detection.frames, frameRateHz: detection.frameRateHz)
        let hard = PitchAutoCorrect.editSet(from: detection, options: hardOptions)
        let hardEntries = try Self.table(hard, parts)
        let segments = HeldPartWander.held(hardEntries)
        let before = PitchWanderMeter.readNotes(uncorrected[0], sampleRate: sampleRate,
                                                segments: segments)
        let durations = hard.segments.map(\.durationSeconds).sorted()
        Self.log("\(hard.segments.count) notes = \(segments.count) held parts (\(Set(hardEntries.map(\.part.runIndex)).count) runs) + \(hard.segments.count - segments.count) transitions, median length \(String(format: "%.3f", durations[durations.count / 2])) s; \(before.count) held parts long enough to measure (interior >= \(PitchWanderMeter.minimumInteriorSeconds) s after \(PitchWanderMeter.edgeMarginSeconds) s edges); the Hard Tune gate: leg W cut >= \(HeldPartWander.hardCutThreshold), leg N every held part within ±\(HeldPartWander.noteToleranceCents) c of its own note")

        // THE SPECTRAL METER'S POSITIVE CONTROL, on this voice: the same file
        // through the same loop transposed by a KNOWN constant must read back
        // that constant on every measured held part.
        let knownCents = 25.0
        let known = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: 1,
            semitonesAtOutputFrame: { _ in knownCents / 100 }, formantPreserve: false,
            compensation: compensation)
        let control = SpectralShiftMeter.noteShifts(
            reference: uncorrected[0], shifted: known[0], sampleRate: sampleRate,
            segments: segments.filter { s in before.contains { $0.segmentID == s.id } })
        let controlErrors = control.values.map { abs($0 - knownCents) }.sorted()
        Self.log(String(format: "spectral meter control: a known +%.0f c constant reads back on %d held parts with |error| median %.2f c, max %.2f c",
                        knownCents, control.count, PitchWanderMeter.median(controlErrors) ?? -1,
                        controlErrors.last ?? -1))
        #expect(control.count == before.count)
        #expect((controlErrors.last ?? .infinity) < 3,
                "the spectral meter misread a known constant transposition by \(controlErrors.last ?? -1) cents")

        // ── THE MANIFEST the second instrument reads: every part of the table,
        //    and each held part's reading on every render, keyed by PART INDEX
        //    (segment ids differ per set; the part table does not).
        var partRows: [[String: Any]] = hardEntries.map { entry -> [String: Any] in
            ["index": entry.index, "run": entry.part.runIndex, "kind": entry.part.kind.rawValue,
             "start": entry.part.startSeconds, "end": entry.part.endSeconds,
             "detectedHz": entry.part.centreHz,
             "detectedMidi": 69 + 12 * log2(entry.part.centreHz / 440),
             "targetMidi": HeldPartWander.targetMidi(ofHz: entry.part.centreHz),
             "asked": [String: Any](), "pwm": [String: Any]()]
        }
        var renderRows: [[String: Any]] = [["key": "00-uncorrected", "file": "00-uncorrected.wav"]]
        var verdictRows: [String: Any] = [:]
        func num(_ x: Double) -> Any { x.isFinite ? x : NSNull() }
        func legs(_ v: HeldPartWander.Verdict) -> [String: Any] {
            var row: [String: Any] = [:]
            row["heldPartsMeasured"] = v.scores.count
            row["cut"] = num(v.cut)
            row["beforeWanderCents"] = num(v.comparison.beforeWanderCents)
            row["afterWanderCents"] = num(v.comparison.afterWanderCents)
            row["maxAbsMissCents"] = num(v.maxAbsMiss)
            row["offNote"] = v.offNote.count
            row["passesW"] = v.passesW
            row["passesN"] = v.passesN
            row["passes"] = v.passes
            row["leaveOneOutSensitivity"] = num(v.leaveOneOutSensitivity)
            return row
        }
        func record(_ key: String, file: String?, entries: [HeldPartWander.Entry],
                    readings: [PitchWanderMeter.NoteReading], verdict: HeldPartWander.Verdict?,
                    askedAnything: Bool = true) {
            if let file { renderRows.append(["key": key, "file": file]) }
            let byID = Dictionary(readings.map { ($0.segmentID, $0) }, uniquingKeysWith: { a, _ in a })
            for entry in entries {
                if askedAnything {
                    var asked = partRows[entry.index]["asked"] as? [String: Any] ?? [:]
                    asked[key] = entry.segment.pitchOffsetCents
                    partRows[entry.index]["asked"] = asked
                }
                guard let r = byID[entry.segment.id] else { continue }
                var pwm = partRows[entry.index]["pwm"] as? [String: Any] ?? [:]
                var reading: [String: Any] = [:]
                reading["spreadCents"] = num(r.spreadCents)
                reading["iqrCents"] = num(r.iqrCents)
                reading["medianHz"] = num(r.medianHz)
                reading["estimates"] = r.estimateCount
                pwm[key] = reading
                partRows[entry.index]["pwm"] = pwm
            }
            guard let verdict else { return }
            var row = legs(verdict)
            row["withoutLowNotes"] = verdict.without(hzBelow: HeldPartWander.lowNoteHz)
                .map { legs($0) as Any } ?? NSNull()
            verdictRows[key] = row
        }
        record("00-uncorrected", file: nil, entries: hardEntries, readings: before, verdict: nil,
               askedAnything: false)

        var verdicts: [PitchCorrectionPreset: HeldPartWander.Verdict] = [:]
        var renders: [PitchCorrectionPreset: [Float]] = [:]
        var centreCorrection: [PitchCorrectionPreset: Double] = [:]
        var deliveryError: [PitchCorrectionPreset: Double] = [:]
        for (index, preset) in PitchCorrectionPreset.allCases.enumerated() {
            let set = PitchAutoCorrect.editSet(from: detection, options: preset.options())
            #expect(set.segments.map(\.id).count == hard.segments.count)
            let entries = try Self.table(set, parts)
            let held = HeldPartWander.held(entries)
            let clip = Clip(name: "vocal", audioFileURL: source, pitchEdits: set)
            let started = clock.now
            let url = try await cache.renderIfNeeded(clipID: clip.id, source: source,
                                                     params: .init(clip: clip))
            let took = clock.now - started
            let shortfall = cache.contourShortfall(source: source, params: .init(clip: clip))
            #expect(shortfall == nil, "\(preset.rawValue) fell back: \(shortfall ?? "")")
            let rendered = try TestSignals.readFile(url)
            renders[preset] = rendered[0]
            let name = String(format: "%02d-%@.wav", index + 1,
                              (preset == .hardTune ? "hard-tune" : preset.rawValue) as NSString)
            try M23QComparisonPair.writeWAV(rendered, sampleRate: sampleRate,
                                            to: outDir.appendingPathComponent(name))
            // Same part table across presets (same detection), so every preset
            // is read on the SAME held parts.
            let after = PitchWanderMeter.readNotes(rendered[0], sampleRate: sampleRate,
                                                   segments: held)
            let verdict = try #require(HeldPartWander.verdict(
                before: PitchWanderMeter.readNotes(uncorrected[0], sampleRate: sampleRate,
                                                   segments: held),
                after: after, segments: held, threshold: HeldPartWander.hardCutThreshold))
            verdicts[preset] = verdict
            record(name.replacingOccurrences(of: ".wav", with: ""), file: name,
                   entries: entries, readings: after, verdict: verdict)
            // Asked vs delivered, per MEASURED held part (the same parts the
            // wander is read on), by the SPECTRAL meter — the tracked median
            // is not shift-equivariant on this voice (see `SpectralShiftMeter`).
            let measured = Set(verdict.scores.map(\.segment.id))
            let delivered = SpectralShiftMeter.noteShifts(
                reference: uncorrected[0], shifted: rendered[0], sampleRate: sampleRate,
                segments: held.filter { measured.contains($0.id) })
            var asked: [Double] = [], moved: [Double] = [], missed: [Double] = []
            for segment in held {
                guard let cents = delivered[segment.id] else { continue }
                asked.append(abs(segment.pitchOffsetCents))
                moved.append(abs(cents))
                missed.append(abs(cents - segment.pitchOffsetCents))
            }
            centreCorrection[preset] = PitchWanderMeter.median(moved)
            deliveryError[preset] = PitchWanderMeter.median(missed)
            Self.log(String(format:
                "%-9@ render %@ | centre correction %.1f c (asked %.1f c; |delivered - asked| median %.1f c, max %.1f c) [tracked-median move %.1f c] | %@ | %@",
                preset.rawValue as NSString, "\(took)" as NSString,
                PitchWanderMeter.median(moved) ?? -1, PitchWanderMeter.median(asked) ?? -1,
                PitchWanderMeter.median(missed) ?? -1, missed.max() ?? -1,
                verdict.comparison.medianCentreMoveCents,
                (preset == .hardTune ? verdict.summary : verdict.wanderSummary) as NSString,
                name as NSString))
            if preset == .hardTune || preset == .tight {
                Self.logParts(preset.rawValue, verdict, entries)
                Self.logSensitivity(preset.rawValue, verdict, gated: preset == .hardTune)
            }
        }

        // ── PLANT P1, THE CONTROL, on the real voice: the same Hard Tune clip
        //    through a cache whose detector cannot run — the pre-contour
        //    render, which is what the app shipped before contour-to-render.
        //    Constant offsets, nothing flattened: it must FAIL leg W.
        let blindCache = StretchRenderCache(
            directory: outDir.appendingPathComponent("render-cache-blind", isDirectory: true),
            contourDetector: ContourToRenderTests.failing)
        let blindClip = Clip(name: "vocal", audioFileURL: source, pitchEdits: hard)
        let blindURL = try await blindCache.renderIfNeeded(
            clipID: blindClip.id, source: source, params: .init(clip: blindClip))
        let blind = try TestSignals.readFile(blindURL)[0]
        let p1Name = "90-plant-P1-constant-offset-fallback.wav"
        try M23QComparisonPair.writeWAV([blind], sampleRate: sampleRate,
                                        to: outDir.appendingPathComponent(p1Name))
        let p1After = PitchWanderMeter.readNotes(blind, sampleRate: sampleRate, segments: segments)
        let p1 = try #require(HeldPartWander.verdict(
            before: before, after: p1After, segments: segments,
            threshold: HeldPartWander.hardCutThreshold))
        record("90-plant-P1-constant-offset-fallback", file: p1Name, entries: hardEntries,
               readings: p1After, verdict: p1)
        Self.log("PLANT P1 hardTune WITHOUT the contour (the pre-contour render): \(p1.summary) -> \(p1.passes ? "NOT CAUGHT" : "CAUGHT")")
        Self.logSensitivity("P1", p1)
        #expect(p1.cut < HeldPartWander.noFlatteningCeiling,
                "the constant-offset fallback flattened the held notes (\(Int(p1.cut * 100))%)")
        #expect(!p1.passes, "PLANT P1 (the constant-offset fallback) passed the Hard Tune gate")

        // ── PLANT P2, THE TRAP: `.runPin` — every part of a run locked to the
        //    WHOLE run's note and flattened, the pre-split red behaviour on the
        //    split table. Its held parts ARE flat, so leg W may pass; a held
        //    part of a multi-note run lands on the run's note, so leg N must
        //    fail. The plant only tests leg N if some measurable held part is
        //    asked for a different note than the shipped shape asks for.
        let runPin = PitchAutoCorrect.editSet(from: detection, options: hardOptions,
                                              slideShape: .runPin)
        let pinEntries = try Self.table(runPin, parts)
        let pinHeld = HeldPartWander.held(pinEntries)
        let measuredParts = Set(before.compactMap { reading in
            hardEntries.first { $0.segment.id == reading.segmentID }?.index })
        let movedByThePin = pinEntries.filter { entry in
            entry.part.kind == .held && measuredParts.contains(entry.index)
                && abs(entry.segment.pitchOffsetCents
                       - hardEntries[entry.index].segment.pitchOffsetCents) > HeldPartWander.noteToleranceCents
        }
        Self.log("PLANT P2 runPin: \(movedByThePin.count) measurable held parts are asked for another note than the shipped shape asks (parts \(movedByThePin.map(\.index)))")
        #expect(!movedByThePin.isEmpty, "no measurable held part differs under runPin, so PLANT P2 cannot test leg N on this take")
        let pinClip = Clip(name: "vocal", audioFileURL: source, pitchEdits: runPin)
        let pinURL = try await cache.renderIfNeeded(clipID: pinClip.id, source: source,
                                                    params: .init(clip: pinClip))
        let pinShortfall = cache.contourShortfall(source: source, params: .init(clip: pinClip))
        #expect(pinShortfall == nil, "runPin fell back: \(pinShortfall ?? "")")
        let pinned = try TestSignals.readFile(pinURL)[0]
        let p2Name = "91-plant-P2-run-pin.wav"
        try M23QComparisonPair.writeWAV([pinned], sampleRate: sampleRate,
                                        to: outDir.appendingPathComponent(p2Name))
        let p2After = PitchWanderMeter.readNotes(pinned, sampleRate: sampleRate, segments: pinHeld)
        let p2 = try #require(HeldPartWander.verdict(
            before: PitchWanderMeter.readNotes(uncorrected[0], sampleRate: sampleRate, segments: pinHeld),
            after: p2After, segments: pinHeld, threshold: HeldPartWander.hardCutThreshold))
        record("91-plant-P2-run-pin", file: p2Name, entries: pinEntries, readings: p2After, verdict: p2)
        Self.log("PLANT P2 runPin: \(p2.summary) -> \(p2.passes ? "NOT CAUGHT" : "CAUGHT")")
        Self.logParts("P2", p2, pinEntries)
        Self.logSensitivity("P2", p2)
        #expect(!p2.passes, "PLANT P2 (runPin: a multi-note run pinned to one note) scored as a flattening win")

        // The claims the report makes, asserted on the audio just written.
        let hardVerdict = try #require(verdicts[.hardTune])
        let tightVerdict = try #require(verdicts[.tight])
        #expect(hardVerdict.passesW,
                "Hard Tune cut the held notes' wander by only \(Int(hardVerdict.cut * 100))% (leg W needs \(Int(HeldPartWander.hardCutThreshold * 100))%)")
        #expect(hardVerdict.passesN,
                "Hard Tune put \(hardVerdict.offNote.count) held part(s) off their own note, worst \(Int(hardVerdict.maxAbsMiss)) c")
        #expect(tightVerdict.cut < HeldPartWander.noFlatteningCeiling,
                "Tight flattened the held notes (\(Int(tightVerdict.cut * 100))%)")
        // The ladder moves each held note's centre by what it asked for (a
        // constant offset through the same transposer the control just verified).
        for preset in PitchCorrectionPreset.ladder {
            let miss = try #require(deliveryError[preset])
            #expect(miss < 3, "\(preset.rawValue) delivered its centre offsets \(miss) cents off (median)")
        }
        _ = centreCorrection

        let detectionRow: [String: Any] = [
            "frames": detection.frameCount, "frameRateHz": detection.frameRateHz,
            "confidenceThreshold": detection.confidenceThreshold,
            "silenceFloorDbfs": detection.silenceFloorDbfs]
        let gateRow: [String: Any] = [
            "hardCutThreshold": HeldPartWander.hardCutThreshold,
            "noteToleranceCents": HeldPartWander.noteToleranceCents,
            "noFlatteningCeiling": HeldPartWander.noFlatteningCeiling,
            "lowNoteHz": HeldPartWander.lowNoteHz]
        let instrumentRow: [String: Any] = [
            "windowSize": PitchWanderMeter.windowSize, "phaseHop": PitchWanderMeter.phaseHop,
            "estimateHop": PitchWanderMeter.estimateHop, "bandCents": PitchWanderMeter.bandCents,
            "edgeMarginSeconds": PitchWanderMeter.edgeMarginSeconds,
            "minimumInteriorSeconds": PitchWanderMeter.minimumInteriorSeconds,
            "minimumEstimates": PitchWanderMeter.minimumEstimates]
        let manifest: [String: Any] = [
            "what": "p2-seg-F-metric: ContourRenderListeningTests' per-part readings (PitchWanderMeter), for the second instrument",
            "source": source.path, "sampleRate": sampleRate, "detection": detectionRow,
            "gate": gateRow, "instrument": instrumentRow,
            "renders": renderRows, "parts": partRows, "verdicts": verdictRows,
        ]
        let json = try JSONSerialization.data(withJSONObject: manifest,
                                              options: [.prettyPrinted, .sortedKeys])
        try json.write(to: outDir.appendingPathComponent("held-parts.json"))

        // ── HARNESS ≡ PRODUCT, on the real voice. The harness the user heard
        //    (`M23QComparisonPair`) sample-and-holds the curve on a 1440-frame
        //    grid from frame 0 and builds it with no frame-centre offset.
        let productHard = try #require(renders[.hardTune])
        let hitStarted = clock.now
        let contour = PitchContourCache.renderContour(
            source: source, analysisVersion: hard.analysisVersion,
            renderCacheDirectory: cacheDir, detector: .product)
        Self.log("the seam after the render (a cache hit): \(clock.now - hitStarted); \(contour.frames.count) frames")
        // The render's contour IS the detection the segments came from (same
        // whole-file call, deterministic) — bit for bit.
        #expect(contour.frames == detection.frames)
        let plan = try #require(StretchCurvePlan.make(
            editSet: hard, clipPitchShiftSemitones: 0, sampleRate: sampleRate, ratio: 1,
            contour: contour))
        let interval = 1440
        var lookups: [(outputFrame: Int, semitones: Double)] = []
        var outFrame = 0
        while outFrame <= mono.count + interval {
            let lookup = OfflineStretcher.curveLookupFrame(
                outputFrame: outFrame, compensation: compensation, intervalSamples: interval)
            lookups.append((lookup, plan.semitones(atOutputFrame: lookup)))
            outFrame += interval
        }
        let exact = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: 1, curve: lookups,
            formantPreserve: false, compensation: compensation)[0]
        var exactDiffering = 0
        for (a, b) in zip(exact, productHard) where a.bitPattern != b.bitPattern {
            exactDiffering += 1
        }
        func grid(_ curve: PitchCorrectionCurve) -> [(outputFrame: Int, semitones: Double)] {
            stride(from: 0, to: mono.count, by: interval).map {
                ($0, curve.semitones(atSourceSecond: Double($0) / sampleRate))
            }
        }
        let gridProductCurve = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: 1, curve: grid(plan.curve),
            formantPreserve: false, compensation: compensation)[0]
        let asHeard = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: 1,
            curve: grid(PitchCorrectionCurve.make(editSet: hard, contour: contour.frames)),
            formantPreserve: false, compensation: compensation)[0]
        func cmp(_ x: [Float]) throws -> PitchWanderMeter.Comparison {
            try #require(PitchWanderMeter.compare(
                before: before,
                after: PitchWanderMeter.readNotes(x, sampleRate: sampleRate, segments: segments)))
        }
        let p = try cmp(productHard), b = try cmp(gridProductCurve), a = try cmp(asHeard)
        // Per-note centre agreement between the product and the render as
        // heard — by the spectral meter (the tracked median is not
        // shift-equivariant on this voice).
        let measuredIDs = Set(before.map(\.segmentID))
        let centreGaps = SpectralShiftMeter.noteShifts(
            reference: asHeard, shifted: productHard, sampleRate: sampleRate,
            segments: segments.filter { measuredIDs.contains($0.id) })
            .values.map { abs($0) }.sorted()
        Self.log(String(format:
            "harness≡product (held parts): (C) exact-lookup harness differs in %d of %d samples | wander %.1f c before -> product %.1f (%.0f%%), (B) harness grid + product curve %.1f (%.0f%%), (A) harness as heard %.1f (%.0f%%) | product vs as-heard note centres: median %.2f c, max %.2f c over %d held parts",
            exactDiffering, productHard.count, p.beforeWanderCents,
            p.afterWanderCents, p.medianReduction * 100,
            b.afterWanderCents, b.medianReduction * 100,
            a.afterWanderCents, a.medianReduction * 100,
            centreGaps.isEmpty ? -1 : centreGaps[centreGaps.count / 2],
            centreGaps.last ?? -1, centreGaps.count))
        #expect(exactDiffering == 0)
        try M23QComparisonPair.writeWAV([asHeard], sampleRate: sampleRate,
                                        to: outDir.appendingPathComponent("zz-harness-as-heard-hard-tune.wav"))
    }
}
