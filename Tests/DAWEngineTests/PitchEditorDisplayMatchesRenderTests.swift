import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine
import DAWAppKit

/// m23-ap C-0 — **THE PITCH EDITOR DRAWS THE CURVE THE RENDER PLAYS.**
/// Design `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md` §4.6.
///
/// ⭐⭐ **THE GATE IS AN IN-PROCESS EQUALITY, NOT A LOOK.** `PitchCorrectionCurve`
/// is `Equatable` over its spans, so the curve OBJECT the display builds is
/// compared with the one `StretchCurvePlan.make` builds for the render — for
/// every answer the seam can give. Both sides are built here, in one process,
/// from one fixture, with the render side mirroring `performRender`'s own
/// contour rule line for line (`renderCurve`).
///
/// ⛔ **DISTINCT BYTES PROVE NOTHING, SO THE PHYSICS IS ASSERTED TOO.**
/// `drawnPointsAreThePlayedPitch` checks what the points SAY against numbers
/// computed without the curve: a +100 c note plus a +2 transpose plays exactly
/// 3 semitones above the singer; a 6 Hz ±40 c generator plays exactly
/// `2 + 0.4·sin(2π·6·t)` above; a flattened vibrato plays with a fraction of
/// the sung swing.
///
/// Every test names the defect planted to prove it can fail; each was applied,
/// seen red, and reverted (the close record quotes the red runs).
///
/// ⚠️ NOT a `@MainActor` suite (`MainActorOccupancySiteTests` bounds those);
/// the one test that needs a `ProjectStore` is `@MainActor` on its own.
@Suite("C-0 — the pitch editor draws the curve the render plays")
struct PitchEditorDisplayMatchesRenderTests {

    // MARK: - The fixture (§4.6)

    static let frameRate = 62.5
    static let period = 1 / 62.5
    static let tempo = try! TempoMap(segments: [.init(startBeat: 0, bpm: 120)])

    /// Three voiced runs with a 5.5 Hz, ±40 c vibrato, separated by unvoiced
    /// holes — the one between runs 2 and 3 is the one `holesStayHoles` looks
    /// for — plus an unvoiced tail. Frame indices at 62.5 fps:
    ///   A 0..<50 (220 Hz) · hole 50..<56 · B 56..<116 (246.94 Hz)
    ///   · hole 116..<126 · C 126..<186 (196 Hz) · tail 186..<196.
    static func frames(gridOffset: Double = 0) -> [ClipPitchFrame] {
        var out: [ClipPitchFrame] = []
        func voiced(_ range: Range<Int>, hz: Double) {
            for i in range {
                let t = Double(i) * period + gridOffset
                let cents = 40 * sin(2 * .pi * 5.5 * t)
                out.append(ClipPitchFrame(timeSeconds: t, frequencyHz: hz * pow(2, cents / 1200),
                                          confidence: 0.97, levelDbfs: -16, absence: nil))
            }
        }
        func unvoiced(_ range: Range<Int>, _ absence: PitchDetectionAbsence) {
            for i in range {
                out.append(ClipPitchFrame(timeSeconds: Double(i) * period + gridOffset,
                                          frequencyHz: nil, confidence: 0.2,
                                          levelDbfs: absence == .belowLevel ? -90 : -40,
                                          absence: absence))
            }
        }
        voiced(0..<50, hz: 220)
        unvoiced(50..<56, .belowConfidence)
        voiced(56..<116, hz: 246.94)
        unvoiced(116..<126, .belowLevel)
        voiced(126..<186, hz: 196)
        unvoiced(186..<196, .belowLevel)
        return out
    }

    static func detection(_ frames: [ClipPitchFrame]) -> PitchDetectionResult {
        let voiced = frames.filter { $0.frequencyHz != nil }.count
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: voiced,
            voicedFraction: frames.isEmpty ? 0 : Double(voiced) / Double(frames.count),
            frameRateHz: frameRate, analysisSampleRateHz: 16_000, sourceSampleRateHz: 48_000,
            windowStartSeconds: frames.first?.timeSeconds ?? 0,
            windowDurationSeconds: Double(frames.count) * period,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs,
            minFrequencyHz: 46, maxFrequencyHz: 2_093)
    }

    /// The seam's whole-file answer.
    static let wholeFile = detection(frames())

    /// The editor's own window detection — a DIFFERENT analysis on purpose:
    /// its grid sits 2 ms off the whole-file grid (F18's measured offset), so
    /// a test can tell which of the two a point was drawn from.
    static let windowDetection = detection(frames(gridOffset: 0.002))

    struct Notes {
        let a: NoteSegment
        let b: NoteSegment
        let c: NoteSegment
        var set: PitchEditSet { PitchEditSet(segments: [a, b, c]) }
    }

    /// A: +100 cents. B: `vibratoScale: 0` — needs the contour. C: a 6 Hz,
    /// ±40 c generator. Segments are the detected table (`PitchNoteTable`),
    /// so their boundaries are exactly the runs'.
    static func notes() -> Notes {
        let table = PitchNoteTable.detected(from: wholeFile)
        precondition(table.segments.count == 3, "the fixture must segment into three notes")
        var a = table.segments[0]
        a.pitchOffsetCents = 100
        var b = table.segments[1]
        b.vibratoScale = 0
        var c = table.segments[2]
        c.vibratoRateHz = 6
        c.vibratoDepthCents = 40
        return Notes(a: a, b: b, c: c)
    }

    /// `pitchShiftSemitones: 2`, `stretchRatio: 1.25`, untrimmed: 8 beats at
    /// 120 BPM is 4 s of output, 3.2 s of source — the whole 3.136 s file.
    static func clip(_ notes: Notes, startOffsetSeconds: Double = 0,
                     lengthBeats: Double = 8) -> Clip {
        Clip(name: "vox", startBeat: 0, lengthBeats: lengthBeats,
             audioFileURL: URL(fileURLWithPath: "/tmp/c0-display-matches-render.wav"),
             startOffsetSeconds: startOffsetSeconds, stretchRatio: 1.25,
             pitchShiftSemitones: 2, pitchEdits: notes.set)
    }

    static let contours: [(name: String, contour: PitchRenderContour)] = [
        ("detected", .detected(wholeFile)),
        ("analysisVersionMismatch", .analysisVersionMismatch(editSet: 0, detector: 1)),
        ("unavailable", .unavailable(reason: "the pitch model is missing from this build")),
    ]

    // MARK: - The render side, mirroring `performRender` line for line

    /// The curve the RENDER builds for `clip` when THE seam answers
    /// `seamAnswer` — `StretchRenderCache.performRender`'s own three steps:
    ///  1. the seam is asked only when the edits `needsDetectedContour`;
    ///  2. `shortfallReason` decides whether that answer is usable;
    ///  3. `StretchCurvePlan.make` gets the contour only when it is, else `nil`.
    /// `nil` when the render takes the constant path (an identity set).
    static func renderCurve(for clip: Clip,
                            seamAnswer: PitchRenderContour) -> PitchCorrectionCurve? {
        let p = StretchRenderCache.Params(clip: clip)
        var contour: PitchRenderContour?
        if let set = p.pitchEdits, set.needsDetectedContour {
            contour = seamAnswer
        }
        let fallbackReason = StretchRenderCache.shortfallReason(contour)
        return StretchCurvePlan.make(
            editSet: p.pitchEdits,
            clipPitchShiftSemitones: p.semitones,
            sampleRate: 48_000,
            ratio: p.ratio,
            contour: fallbackReason == nil ? contour : nil)?.curve
    }

    /// What the DISPLAY builds for the same clip and the same seam answer.
    static func displayLine(for clip: Clip, contour: PitchRenderContour?,
                            fallback: PitchDetectionResult? = windowDetection) -> PitchPlayedLine {
        PitchPlayedLine.make(contour: contour, fallback: fallback, editSet: clip.pitchEdits,
                             clipPitchShiftSemitones: clip.pitchShiftSemitones,
                             sourceWindow: PitchPlayedLine.sourceWindow(of: clip, tempoMap: tempo))
    }

    // MARK: - 1. displayCurveIsTheRenderCurve

    /// ⭐⭐ THE GATE. Planted, each separately, and seen red:
    ///  (i)  the display builds with `PitchCorrectionCurve.make(editSet:
    ///       clipPitchShiftSemitones:)` and no contour → red on `.detected`
    ///       (B's flattening vanishes from the display only);
    ///  (ii) the display passes `clipPitchShiftSemitones: 0` → red on all three;
    ///  (iv) the display builds its curve from the WINDOW-CROPPED frames → red
    ///       on the trimmed clip, whose window starts inside B.
    /// ((iii), the C2-5 `timeWarp` plant, belongs to C2 and does not exist yet.)
    ///  (v)  for the offsets-only leg: `PitchCorrectionCurve.make` seeding every
    ///       span's `shapingStartSeconds` with the contour's value offset, even
    ///       for a note that never shapes → red on that leg alone. The gate
    ///       compares curve OBJECTS, so a contour the render never asked for
    ///       may not leave any trace in the display's curve.
    @Test("⭐ the display's curve IS the render's curve — detected, version mismatch, unavailable")
    func displayCurveIsTheRenderCurve() throws {
        let notes = Self.notes()
        let untrimmed = Self.clip(notes)
        // Trimmed so the window STARTS INSIDE B: a shaping note straddling the
        // window edge, which is exactly where a display that cropped before
        // building its curve would diverge from a render of the whole file.
        let trimmed = Self.clip(notes, startOffsetSeconds: 1.2, lengthBeats: 4)
        #expect(trimmed.startOffsetSeconds > notes.b.startSeconds
                && trimmed.startOffsetSeconds < notes.b.endSeconds,
                "the trimmed leg must cut B in half, or it proves nothing about cropping")

        for (name, contour) in Self.contours {
            for clip in [untrimmed, trimmed] {
                let render = try #require(Self.renderCurve(for: clip, seamAnswer: contour),
                                          "the fixture has edits, so the render builds a curve")
                let line = Self.displayLine(for: clip, contour: contour)
                #expect(line.curve == render,
                        "\(name), window from \(clip.startOffsetSeconds) s: the display's curve is not the render's")
            }
            let line = Self.displayLine(for: untrimmed, contour: contour)
            switch contour {
            case .detected:
                #expect(line.basis == .render)
                #expect(line.unresolvedSegmentIDs.isEmpty,
                        "B has 60 voiced frames — the render resolves its flattening")
            case .analysisVersionMismatch, .unavailable:
                #expect(line.basis.key == "estimate", "\(name) must draw as an estimate")
                #expect(line.unresolvedSegmentIDs == [notes.b.id],
                        "\(name): exactly the shaping note is unresolved, as the render reports")
                #expect(line.unresolvedSegmentIDsInWindow == [notes.b.id])
            }
        }

        // A set with NO shaping note: the render never asks the seam
        // (`needsDetectedContour` is false) and builds with no contour, while
        // the display still holds the `.detected` answer the pane fetched. The
        // contour must then change nothing — the same curve object.
        var plainB = notes.b
        plainB.vibratoScale = 1
        var plainC = notes.c
        plainC.vibratoRateHz = 0
        plainC.vibratoDepthCents = 0
        plainC.pitchOffsetCents = -50
        let offsetsOnly = Notes(a: notes.a, b: plainB, c: plainC)
        #expect(!offsetsOnly.set.needsDetectedContour, "this leg needs a set the render asks no contour for")
        let plain = Self.clip(offsetsOnly)
        let plainRender = try #require(Self.renderCurve(for: plain, seamAnswer: .detected(Self.wholeFile)))
        #expect(Self.displayLine(for: plain, contour: .detected(Self.wholeFile)).curve == plainRender,
                "offsets only: the display's curve changed with a contour the render never asked for")

        // POSITIVE CONTROLS — the equality above can only fail if the things it
        // compares actually depend on the contour and on the transpose.
        let detected = Self.displayLine(for: untrimmed, contour: Self.contours[0].contour)
        let unavailable = Self.displayLine(for: untrimmed, contour: Self.contours[2].contour)
        #expect(detected.curve != unavailable.curve,
                "the detected contour must change the curve (B's flattening), or the gate is blind to it")
        let noShift = PitchPlayedLine.make(
            contour: Self.contours[0].contour, fallback: nil, editSet: untrimmed.pitchEdits,
            clipPitchShiftSemitones: 0,
            sourceWindow: PitchPlayedLine.sourceWindow(of: untrimmed, tempoMap: Self.tempo))
        #expect(noShift.curve != detected.curve, "the transpose must be inside the curve")
    }

    /// ⭐ THE SAME GATE, ONE LAYER UP: the line the EDITOR MODEL holds — built
    /// by its own `rebuildPlayedLine` from the detection it applied, the table
    /// it synced and the seam answer it fetched — is the render's curve, and
    /// what it hands the surface is that curve's pitch at each frame centre,
    /// mapped through the geometry and nothing else. Both load orders: the
    /// detection and the seam run in parallel (§4.3 steps 1–2), so either can
    /// land first.
    @Test("⭐ the editor model's line is the render's curve, and its screen points are that curve's pitch")
    @MainActor
    func modelLineIsTheRenderCurve() async throws {
        let notes = Self.notes()
        let clip = Self.clip(notes)
        let detection = ClipPitchDetection(pitch: Self.windowDetection,
                                           clipWindowDurationSeconds: 3.2,
                                           stretchRatio: clip.stretchRatio,
                                           pitchShiftSemitones: clip.pitchShiftSemitones)
        for (name, contour) in Self.contours {
            let render = try #require(Self.renderCurve(for: clip, seamAnswer: contour))
            for seamFirst in [false, true] {
                let model = PitchEditorModel(
                    clipID: clip.id, geometry: PitchEditorGeometry(clip: clip, tempoMap: Self.tempo))
                let seam: PitchEditorRenderContourProvider = { _ in
                    PitchRenderInputs(contour: contour, sourceDurationSeconds: 3.136)
                }
                if seamFirst { await model.loadRenderContour(using: seam) }
                model.apply(detection)
                model.syncStoredNoteTable(clip.pitchEdits)
                if !seamFirst { await model.loadRenderContour(using: seam) }

                let order = seamFirst ? "seam first" : "detection first"
                #expect(model.playedLine.curve == render,
                        "\(name), \(order): the model's curve is not the render's")
                let geometry = model.geometry
                let drawn = Array(model.playedLineSegments().joined())
                let points = Array(model.playedLine.runs.joined())
                #expect(drawn.count == points.count && !points.isEmpty)
                for (xy, point) in zip(drawn, points) {
                    let played = point.sungMidi + render.semitones(atSourceSecond: point.sourceSeconds)
                    #expect(xy == CGPoint(x: geometry.x(forSourceSecond: point.editedSeconds),
                                          y: geometry.y(forMidi: played)),
                            "\(name): the point drawn for \(point.sourceSeconds) s is not the render's pitch there")
                }
            }
        }
    }

    /// An identity set renders on the CONSTANT path (`StretchCurvePlan.make`
    /// returns nil and the stretcher gets `semitones:`), so there is no render
    /// curve object to compare. The display's curve must then PLAY that
    /// constant — asserted at every drawn point, which is the only claim that
    /// case has. This is the first thing a novice does: open the editor on a
    /// transposed clip and touch nothing.
    ///
    /// Planted and seen red: the display skipping the transpose when the set
    /// is identity — every point then plays at +0 instead of +2.
    @Test("an untouched note table draws exactly the clip's constant transpose")
    func identitySetPlaysTheConstantPath() throws {
        let table = PitchNoteTable.detected(from: Self.wholeFile)
        #expect(table.isIdentity)
        var clip = Self.clip(Self.notes())
        clip.pitchEdits = table
        #expect(Self.renderCurve(for: clip, seamAnswer: .detected(Self.wholeFile)) == nil,
                "an identity set must take the render's constant path")
        let line = Self.displayLine(for: clip, contour: .detected(Self.wholeFile))
        let points = Array(line.runs.joined())
        #expect(!points.isEmpty)
        for point in points {
            #expect(point.playedMidi - point.sungMidi == 2,
                    "at \(point.sourceSeconds) s the untouched line is not the constant +2")
        }
    }

    // MARK: - 2. drawnPointsAreThePlayedPitch

    /// Every point, three ways exactly, plus the physics.
    ///
    /// Planted and seen red: the curve evaluated at the frame START instead of
    /// its centre → red at every point of B (its shaping is interpolated
    /// between two centre-placed samples there), every point of C (the
    /// generator is a function of time) and A's two ramp points — 122 of the
    /// 170 drawn points.
    @Test("⭐ every drawn point is the pitch the render plays at that frame's centre")
    func drawnPointsAreThePlayedPitch() throws {
        let notes = Self.notes()
        let clip = Self.clip(notes)
        let contour = PitchRenderContour.detected(Self.wholeFile)
        let render = try #require(Self.renderCurve(for: clip, seamAnswer: contour))
        let line = Self.displayLine(for: clip, contour: contour)

        let voiced = Self.wholeFile.frames.filter { $0.frequencyHz != nil }
        let points = Array(line.runs.joined())
        #expect(points.count == voiced.count, "an untrimmed clip draws every voiced frame")
        #expect(contour.frameValueOffsetSeconds == 0.5 / Self.frameRate)
        for (point, frame) in zip(points, voiced) {
            #expect(point.sourceSeconds == frame.timeSeconds + contour.frameValueOffsetSeconds)
            #expect(point.editedSeconds == point.sourceSeconds, "no retime before C2")
            #expect(point.sungMidi == PitchCorrectionMath.midi(fromHz: frame.frequencyHz ?? 0))
            #expect(point.playedMidi
                    == point.sungMidi + render.semitones(atSourceSecond: point.sourceSeconds),
                    "at \(point.sourceSeconds) s the drawn pitch is not what the render plays")
        }

        // THE PHYSICS, computed without the curve.
        let ramp = 0.030 / 2  // retuneMs 30 → a ±15 ms centred ramp at each edge
        func interior(_ n: NoteSegment) -> [PitchPlayedLine.Point] {
            points.filter { $0.sourceSeconds > n.startSeconds + ramp
                && $0.sourceSeconds < n.endSeconds - ramp }
        }
        let a = interior(notes.a), b = interior(notes.b), c = interior(notes.c)
        #expect(a.count > 30 && b.count > 40 && c.count > 40)
        for p in a {
            #expect(abs((p.playedMidi - p.sungMidi) - 3) < 1e-9,
                    "A: +100 c on a +2 transpose must play exactly 3 semitones above the singer")
        }
        for p in c {
            let expected = 2 + 0.4 * sin(2 * .pi * 6 * p.sourceSeconds)
            #expect(abs((p.playedMidi - p.sungMidi) - expected) < 1e-9,
                    "C: the 6 Hz ±40 c generator on +2 is 2 + 0.4·sin(2π·6·t)")
        }
        // B: the sung ±40 c wobble is flattened. A 250 ms separator passes ~121 %
        // of a 5.5 Hz wobble into "vibrato" (PitchRenderContour.shapingVersion's
        // doc), so what is left is a small fraction of the sung swing — never
        // the sung swing itself.
        let sungSwing = (b.map(\.sungMidi).max() ?? 0) - (b.map(\.sungMidi).min() ?? 0)
        let playedSwing = (b.map(\.playedMidi).max() ?? 0) - (b.map(\.playedMidi).min() ?? 0)
        #expect(sungSwing > 0.7, "the fixture's B must actually wobble (±40 c)")
        #expect(playedSwing < 0.4 * sungSwing,
                "B: vibratoScale 0 must flatten the drawn wobble (sung \(sungSwing) st, drawn \(playedSwing) st)")
        let bMedian = try #require(PitchCorrectionMath.median(b.map(\.playedMidi)))
        let bCentre = PitchCorrectionMath.midi(fromHz: notes.b.detectedHz)
        #expect(abs(bMedian - (bCentre + 2)) < 0.1,
                "B plays around its own centre, two semitones up")
    }

    /// The estimate basis draws the WINDOW detection's frames, at ITS centres —
    /// the same formula, from the fallback's own rate.
    @Test("an estimate is drawn from the editor's own detection, at its frame centres")
    func estimateDrawsTheFallbackFrames() throws {
        let clip = Self.clip(Self.notes())
        let line = Self.displayLine(for: clip, contour: .unavailable(reason: "no model"))
        let voiced = Self.windowDetection.frames.filter { $0.frequencyHz != nil }
        let points = Array(line.runs.joined())
        #expect(points.count == voiced.count)
        let render = try #require(Self.renderCurve(for: clip, seamAnswer: .unavailable(reason: "no model")))
        for (point, frame) in zip(points, voiced) {
            #expect(point.sourceSeconds == frame.timeSeconds + 0.5 / Self.frameRate)
            #expect(point.playedMidi
                    == point.sungMidi + render.semitones(atSourceSecond: point.sourceSeconds))
        }
        // No fallback either → nothing to draw, and still an estimate.
        let bare = Self.displayLine(for: clip, contour: .unavailable(reason: "no model"),
                                    fallback: nil)
        #expect(bare.runs.isEmpty)
        #expect(bare.basis.key == "estimate")
        // Not answered yet → the pending sentence, never a failure sentence.
        let pending = Self.displayLine(for: clip, contour: nil)
        #expect(pending.basis == .estimate(reason: PitchPlayedLine.pendingReason))
    }

    // MARK: - 3. seamIsCalledWithTheRenderArguments

    /// A spy engine: records every `renderPitchContour` call and answers
    /// `.unavailable`. Everything else is the minimal conformance.
    @MainActor
    final class ContourSpyEngine: AudioEngineControlling {
        struct Call: Equatable {
            let url: URL
            let analysisVersion: Int
        }
        private(set) var calls: [Call] = []

        func renderPitchContour(inFileAt url: URL, analysisVersion: Int) async -> PitchRenderContour {
            calls.append(Call(url: url, analysisVersion: analysisVersion))
            return .unavailable(reason: "spy")
        }

        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var isRunning = false
        func prepare() throws {}
        func shutdown() {}
        func tracksDidChange(_ tracks: [Track]) {}
        func startPlayback(_ transport: TransportState) {}
        func stopPlayback() {}
        func seek(_ transport: TransportState) {}
        func setTempo(_ transport: TransportState) {}
        func loopChanged(_ transport: TransportState) {}
        func masterVolumeChanged(_ volume: Double) {}
        func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor],
                           masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           to url: URL) async throws -> AudioFileInfo {
            throw ProjectError.engineUnavailable
        }
        var recordPermission: RecordPermission { .granted }
        func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
            completion(true)
        }
        func availableInputDevices() -> [AudioInputDevice] { [] }
        func setInputDevice(uid: String?) throws {}
        func startRecording(_ transport: TransportState, to url: URL,
                            completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
            throw ProjectError.engineUnavailable
        }
        func stopRecording() {}
    }

    struct FixedDurationMedia: MediaImporting {
        let seconds: Double
        func audioFileInfo(at url: URL) throws -> AudioFileInfo {
            AudioFileInfo(durationSeconds: seconds, sampleRate: 48_000, channelCount: 1)
        }
    }

    /// Planted and seen red: the door passes
    /// `PitchEditSet.currentAnalysisVersion` instead of the set's own version.
    @Test("⭐ the store asks the seam for the clip's SOURCE FILE at the SET's analysis version")
    @MainActor
    func seamIsCalledWithTheRenderArguments() async throws {
        let store = ProjectStore()
        _ = store.addTrack(kind: .audio)
        // A set made by ANOTHER detector generation: version 0, not current.
        let oldSet = PitchEditSet(analysisVersion: 0, segments: Self.notes().set.segments)
        #expect(oldSet.analysisVersion != PitchEditSet.currentAnalysisVersion,
                "the plant is only visible if the set's version differs from the current one")
        let url = URL(fileURLWithPath: "/tmp/c0-seam-spy.wav")
        let edited = Clip(name: "old", startBeat: 0, lengthBeats: 8, audioFileURL: url,
                          pitchShiftSemitones: 2, pitchEdits: oldSet)
        let untouched = Clip(name: "new", startBeat: 8, lengthBeats: 8,
                             audioFileURL: URL(fileURLWithPath: "/tmp/c0-seam-spy-2.wav"))
        store.tracks[0].clips = [edited, untouched]

        // No engine: an honest refusal, never a throw, never a fabrication.
        let headless = await store.renderPitchContour(clipId: edited.id)
        #expect(headless.contour == .unavailable(reason: "no audio engine is running"))
        #expect(headless.sourceDurationSeconds == nil, "no media → no duration, said as nil")

        let spy = ContourSpyEngine()   // held strongly: `store.engine` is weak
        store.engine = spy
        store.media = FixedDurationMedia(seconds: 3.136)

        let answer = await store.renderPitchContour(clipId: edited.id)
        #expect(spy.calls == [ContourSpyEngine.Call(url: url, analysisVersion: 0)],
                "the seam must be asked for the SOURCE file at the SET's own version — got \(spy.calls)")
        #expect(answer.contour == .unavailable(reason: "spy"), "the seam's answer is passed through verbatim")
        #expect(answer.sourceDurationSeconds == 3.136)

        // A clip with no edits asks at the CURRENT version (the seam's contract).
        _ = await store.renderPitchContour(clipId: untouched.id)
        #expect(spy.calls.last?.analysisVersion == PitchEditSet.currentAnalysisVersion)
        #expect(spy.calls.last?.url == untouched.audioFileURL)

        // No file, and no clip: refusals with their own reasons, no seam call.
        let before = spy.calls.count
        let midi = Clip(name: "keys", startBeat: 20, lengthBeats: 4, notes: [])
        store.tracks[0].clips.append(midi)
        let noFile = await store.renderPitchContour(clipId: midi.id)
        #expect(noFile.contour == .unavailable(reason: "this clip has no audio file"))
        let gone = await store.renderPitchContour(clipId: UUID())
        #expect(gone.contour == .unavailable(reason: "this clip is no longer in the project"))
        #expect(spy.calls.count == before, "a refusal must not reach the engine")
    }

    // MARK: - The cost (§4.2, F11)

    /// A fixed, deliberately UNRELATED CPU-bound loop (no code shared with the
    /// curve builder, so a regression there still moves the ratio) —
    /// `EQCurveEditorModelTests.calibrationWork`'s shape (m23-ab-2). Under
    /// load both sides slow by about the same factor, so their RATIO holds
    /// still where either absolute time does not.
    static func calibrationWork(_ iterations: Int) -> Double {
        var acc = 0.0
        var x = 0.137
        var i = 0
        while i < iterations {
            x = sin(x) + cos(x * 1.0000001)
            acc += (abs(x) + 1e-9).squareRoot() + log(abs(x) + 1e-9)
            i += 1
        }
        return acc
    }

    /// Calibration iterations per table shape, sized so each calibration
    /// lasts about as long as the build it is compared with at `-Onone`
    /// (≈ 23 ms per million iterations here).
    ///
    /// ⚠️ **EQUAL LENGTHS, MEASURED IN INTERLEAVED PAIRS — BECAUSE THE FIRST
    /// VERSION'S RATIO WAS NOT LOAD-INVARIANT.** It compared a ~415 ms build
    /// with ONE 23 ms calibration: best-of-N finds quiet windows for a short
    /// operation that a long one never gets, so under the full suite the
    /// Hard Tune ratio inflated from 18.0 (isolated) to 27.4. Two operations
    /// of the same length, run back to back, see the same load.
    static let calibrationIterations: [String: Int] = ["offsets": 1_000_000,
                                                       "hardTune": 18_000_000]

    /// Milliseconds one call of `body` takes.
    static func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    /// The build's cost against a same-length calibration, per table shape.
    ///
    /// ⚠️ **THE DESIGN'S "50 ms DEBUG BOUND" DOES NOT HOLD FOR EVERY TABLE, AND
    /// THE CODE WINS.** Measured at `-Onone` on this machine: plain offsets
    /// (the preset ladder's shape) ≈ 25 ms, but a table where every note asks
    /// for the contour (Hard Tune's shape) ≈ 415 ms — the O(segments × frames)
    /// per-segment filter in `PitchCorrectionCurve.make` (F11), which the
    /// debug build does not optimise. The RELEASE figures, measured separately
    /// against a `-c release` DAWCore, are ≈ 1.5 ms and ≈ 5 ms: under the
    /// design's 8 ms trigger for turning that filter into a binary-searched
    /// slice, so it is not turned (the design: "do not optimise before
    /// measuring"). An absolute debug bound would also flake under load —
    /// the m23-ab-2 lesson — so each shape is bounded as a RATIO to a
    /// same-process, same-length calibration. Healthy ratios are ≈ 1 (1.05 and
    /// 1.00 isolated, three runs each); K = 3 catches a build that got three
    /// times slower relative to the machine. Planted and seen red: building
    /// the curve four times inside `make` → Hard Tune ratio 3.81.
    static let budgetK = 3.0

    @Test("the played line for a 450-note, five-minute vocal builds within a calibrated budget")
    func buildCostOnAFiveMinuteVocal() {
        let fixture = Self.fiveMinuteFixture()
        let window = 0..<fixture.duration
        for (label, set, runs) in [("offsets", fixture.offsets, 5), ("hardTune", fixture.hardTune, 3)] {
            #expect(set.segments.count == 450)
            let iterations = Self.calibrationIterations[label] ?? 1_000_000
            _ = Self.calibrationWork(iterations / 10)   // warm
            var line: PitchPlayedLine?
            var bestBuild = Double.infinity
            var bestCalibration = Double.infinity
            for _ in 0..<runs {
                bestCalibration = min(bestCalibration, Self.milliseconds {
                    _ = Self.calibrationWork(iterations)
                })
                bestBuild = min(bestBuild, Self.milliseconds {
                    line = PitchPlayedLine.make(contour: .detected(fixture.detection), fallback: nil,
                                                editSet: set, clipPitchShiftSemitones: 0,
                                                sourceWindow: window)
                })
            }
            let points = line?.runs.reduce(0) { $0 + $1.count } ?? 0
            let ratio = bestBuild / bestCalibration
            print("[measured] C-0 PitchPlayedLine.make, 450 notes / \(fixture.detection.frames.count) frames / \(String(format: "%.1f", fixture.duration)) s, \(label): best of \(runs) \(String(format: "%.2f", bestBuild)) ms, same-length calibration \(String(format: "%.2f", bestCalibration)) ms, ratio \(String(format: "%.2f", ratio)), \(points) points")
            #expect(points > 15_000, "the fixture must actually draw ~five minutes of voiced frames")
            if label == "hardTune" {
                #expect(line?.curve.unresolvedShapingSegmentIDs.isEmpty == true,
                        "every Hard Tune note must resolve, or the expensive path did not run")
            }
            #expect(ratio < Self.budgetK,
                    "\(label): the build costs \(ratio)× a same-length calibration, over the \(Self.budgetK)× budget")
        }
    }

    struct FiveMinuteFixture {
        let detection: PitchDetectionResult
        let offsets: PitchEditSet
        let hardTune: PitchEditSet
        let duration: Double
    }

    /// 450 notes of 35 voiced frames (560 ms) each, a 7-frame hole after each:
    /// 18,900 frames, 302.4 s. Pitches walk a C-major scale; every note wobbles.
    static func fiveMinuteFixture() -> FiveMinuteFixture {
        var frames: [ClipPitchFrame] = []
        frames.reserveCapacity(450 * 42)
        let scale: [Double] = [0, 2, 4, 5, 7, 9, 11, 12]
        var index = 0
        for note in 0..<450 {
            let midi = 55 + scale[note % scale.count] + 0.3 * sin(Double(note))
            let hz = PitchCorrectionMath.hz(fromMidi: midi)
            for _ in 0..<35 {
                let t = Double(index) * period
                let cents = 35 * sin(2 * .pi * 5.5 * t)
                frames.append(ClipPitchFrame(timeSeconds: t, frequencyHz: hz * pow(2, cents / 1200),
                                             confidence: 0.95, levelDbfs: -18, absence: nil))
                index += 1
            }
            for _ in 0..<7 {
                frames.append(ClipPitchFrame(timeSeconds: Double(index) * period, frequencyHz: nil,
                                             confidence: 0.1, levelDbfs: -80, absence: .belowLevel))
                index += 1
            }
        }
        let detection = Self.detection(frames)
        let table = PitchNoteTable.detected(from: detection)
        let offsets = PitchEditSet(segments: table.segments.map {
            var s = $0
            s.pitchOffsetCents = 37
            return s
        })
        let hardTune = PitchEditSet(segments: table.segments.map {
            var s = $0
            s.pitchOffsetCents = 37
            s.driftScale = 0
            s.vibratoScale = 0
            return s
        })
        return FiveMinuteFixture(detection: detection, offsets: offsets, hardTune: hardTune,
                                 duration: Double(frames.count) * period)
    }
}
