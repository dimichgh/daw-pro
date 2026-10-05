import AVFAudio
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// m23-ap Phase 2 — **THE PRESET DOOR'S AUDIBILITY GATE (design §6.4).**
///
/// The clip context menu's *Tune Vocal ▸ Gentle / Natural / Tight* (and, since
/// contour-to-render put the detected contour into the render, *Hard Tune*) now exists as
/// pixels. This suite is the reason anyone should believe it does anything.
///
/// ⛔ **AUDIBILITY IS NOT CORRECTNESS.** Five planted defects in this tree have
/// passed an `audible=true` check, and one loudness gate passed a render
/// clipping at +1.5 dBTP. ⛔ **IDENTICAL BYTES PROVE THE AXIS DID NOTHING;
/// DISTINCT BYTES PROVE NOTHING AT ALL.** So nothing here asserts "the renders
/// differ". Every assertion is on the PHYSICS: a tone planted a known distance
/// sharp of a chromatic degree, put through the SAME call chain the menu button
/// makes —
///
///     PitchAutoCorrect.editSet(contour:frameRateHz:options: preset.options())
///       → StretchCurvePlan.make(editSet:…)
///       → OfflineStretcher.stretchTransposeCurve(…, compensation: shipping)
///
/// — and the rendered f0 measured back out with the phase-difference tracker in
/// `M23QCurveHarness`, which phase 0 positive-controlled against signals with
/// known answers. The correction has to arrive in the predicted DIRECTION, at
/// roughly the predicted CENTS, and the three presets have to order themselves
/// the way their strengths say they must.
///
/// ⭐ And the boring invariance control is the one that catches bugs: an edit
/// set that bends nothing must take the constant path, produce the empty cache
/// digest, and render byte-for-byte as if pitch correction had never been
/// written. `clearedSetRendersAsNeverTuned` in `StretchEngineTests` is its
/// end-to-end twin, through the real render cache.
///
/// Deliberately NOT `@MainActor` — DSP has no business there, and Leg C of
/// `MainActorOccupancySiteTests` is at its cadence cap.
@Suite("m23-ap Phase 2 — preset render gate (design §6.4)", .serialized)
struct PitchPresetRenderGateTests {

    // MARK: - The fixture

    static let sampleRate = 48_000.0
    /// A3. The tone is planted sharp of THIS, and chromatic correction must pull
    /// it back here — "the nearest allowed note" with no key to argue about.
    static let degreeHz = 220.0
    /// How far sharp the fixture sings, in cents.
    ///
    /// ⚠️ **35, AND THE NUMBER IS CHOSEN AGAINST THE DETECTOR, NOT FOR TIDINESS.**
    /// SwiftF0's argmax is over 256 log-spaced bins — 25.79 cents per bin — and
    /// it reads a 440 Hz sine 9.7 cents FLAT. Plant the tone at 45+ and a
    /// detector reading sharp crosses the 50-cent watershed, `nearestAllowedMidi`
    /// picks A♯3 instead of A3, and the correction reverses sign: a real failure
    /// of the FIXTURE that would read as a failure of the feature. 35 leaves
    /// ~15 cents of headroom on both sides of that watershed, and the test
    /// asserts the headroom held before it asserts anything else.
    static let detuneCents = 35.0
    static let fixtureHz = degreeHz * pow(2, detuneCents / 1200)
    static let seconds = 2.5
    static let amplitude = 0.5

    /// The plateau the f0 is read over: late enough that even `gentle`'s 200 ms
    /// retune ramp has fully arrived (and the stretcher's own latency
    /// compensation with it), early enough to stay well inside the note.
    static let plateau = 1.0..<2.0

    /// A voice-like harmonic tone, not a sine — the harmonic-not-sine lesson
    /// `PitchTrackerAccuracyTests` paid for: SwiftF0 is trained on voices and a
    /// pure sine is not one.
    static func fixtureSamples() -> [Float] {
        PitchTrackerAccuracyTests.Fixture.tone(
            seconds: seconds, amplitude: amplitude, partials: 12,
            sampleRate: sampleRate) { _ in fixtureHz }
    }

    static func writeWAV(_ samples: [Float], to url: URL) throws {
        try M23QComparisonPair.writeWAV([samples], sampleRate: sampleRate, to: url)
    }

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-preset-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - The instruments

    /// Median f0 over the plateau, measured with the phase-difference tracker.
    /// `nil` when the tracker found nothing there, which is a finding and not a
    /// zero.
    static func plateauHz(_ signal: [Float]) -> Double? {
        let estimates = M23QToneTracker.track(
            signal, sampleRate: sampleRate, band: 150...400)
        return M23QToneTracker.medianHz(
            estimates,
            centreIn: (plateau.lowerBound * sampleRate)..<(plateau.upperBound * sampleRate))
    }

    /// The NEVER-TUNED render: the exact `else` branch `StretchRenderCache`
    /// takes when `StretchCurvePlan.make` returns nil — ratio 1, the clip's own
    /// constant shift of 0, no curve anywhere. Every "did the correction move
    /// it" number below is measured against THIS, not against the raw file, so
    /// the stretcher's own transposer bias cancels out of the comparison
    /// instead of being attributed to the preset.
    static func untunedRender(_ input: [Float]) throws -> [Float] {
        try OfflineStretcher.stretch(
            input: [input], sampleRate: sampleRate, ratio: 1, semitones: 0,
            formantPreserve: false)[0]
    }

    /// The TUNED render: the exact `if let plan` branch of the same dispatch.
    static func tunedRender(_ input: [Float], plan: StretchCurvePlan) throws -> [Float] {
        try OfflineStretcher.stretchTransposeCurve(
            input: [input], sampleRate: sampleRate, ratio: 1,
            semitonesAtOutputFrame: { plan.semitones(atOutputFrame: $0) },
            formantPreserve: false,
            compensation: OfflineStretcher.curveLatencyCompensation(
                sampleRate: sampleRate))[0]
    }

    /// The CONSTANT-shift render of the same request: `OfflineStretcher.stretch`
    /// asked for the same number of cents in one go, with no curve anywhere.
    ///
    /// ⭐ **THIS IS THE SECOND INSTRUMENT, AND IT IS WHAT MAKES THE MAGNITUDE
    /// NUMBER MEAN ANYTHING.** The transposer used to miss where it was asked
    /// — design §5.5.3 measured +5.45 cents at +2 st, +3.95 at −2 st — until
    /// p2-acc and p2-acc-3 (2026-09-25) fixed three defects in the vendored
    /// stretcher (`Sources/CSignalsmithStretch/VENDORED.md`, patches 0001-0003);
    /// it now lands within 0.01 c for steady partials across ±24 st and for
    /// harmonic tones to ±12 st and +24 st, but a shared residual can still
    /// remain on real material (breath, noise, a moving voice).
    /// Rendering the same request BOTH ways separates a shallow curve from
    /// that: if the curve path and the constant path land together, the curve
    /// is delivering full depth and any remaining offset belongs to the
    /// transposer everything already shares.
    static func constantRender(_ input: [Float], cents: Double) throws -> [Float] {
        try OfflineStretcher.stretch(
            input: [input], sampleRate: sampleRate, ratio: 1,
            semitones: cents / 100, formantPreserve: false)[0]
    }

    /// RMS over the plateau — the LEVEL instrument.
    ///
    /// ⚠️ **PEAK IS NOT LEVEL HERE, AND THE MEASUREMENT SAYS SO.** A phase
    /// vocoder does not preserve the relative phases of a tone's partials, so
    /// the CREST FACTOR of a 12-partial fixture changes on resynthesis even at
    /// zero transposition: measured, a 0.500-peak fixture comes back at 0.746 /
    /// 0.721 / 0.844 through gentle / natural / tight — up to +4.6 dB of PEAK
    /// with no gain change anywhere. Judging "did this add level" on that
    /// number would fail a correct render (it did, on the first run of this
    /// suite). Energy is what a vocoder preserves, so energy is what the level
    /// assertion is made of; peak is still checked, against FULL SCALE, because
    /// clipping is a different question and a meter does not look up.
    static func plateauRMS(_ x: [Float]) -> Double {
        let low = Int(plateau.lowerBound * sampleRate)
        let high = min(x.count, Int(plateau.upperBound * sampleRate))
        guard low < high else { return 0 }
        var sum = 0.0
        for n in low..<high { sum += Double(x[n]) * Double(x[n]) }
        return (sum / Double(high - low)).squareRoot()
    }

    /// 4× cubic-interpolated peak — an approximation of TRUE peak, because a
    /// sample-peak meter does not look up and this tree has already shipped a
    /// loudness gate that passed a render clipping at +1.5 dBTP. Catmull-Rom
    /// under-reads a real inter-sample peak slightly, which is the safe
    /// direction for a ceiling check: it can only ever let a marginal render
    /// through, never fail a clean one.
    static func truePeak(_ x: [Float]) -> Double {
        guard x.count >= 4 else { return M23QWaveform.peakMagnitude(x) }
        var peak = M23QWaveform.peakMagnitude(x)
        for n in 1..<(x.count - 2) {
            let p0 = Double(x[n - 1]), p1 = Double(x[n])
            let p2 = Double(x[n + 1]), p3 = Double(x[n + 2])
            for step in 1...3 {
                let t = Double(step) / 4
                let a = 2 * p1
                let b = -p0 + p2
                let c = 2 * p0 - 5 * p1 + 4 * p2 - p3
                let d = -p0 + 3 * p1 - 3 * p2 + p3
                let v = 0.5 * (a + b * t + c * t * t + d * t * t * t)
                peak = max(peak, abs(v))
            }
        }
        return peak
    }

    // MARK: - (1) the physics

    @Test("⛔ every offered preset pulls the rendered pitch TOWARD the scale degree, by roughly what it asked for, in strength order")
    func offeredPresetsMoveTheRenderedPitch() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sharp-a3.wav")
        let input = Self.fixtureSamples()
        try Self.writeWAV(input, to: url)

        // ---- detect ONCE, with the SAME settings `ProjectStore.detectClipPitch`
        //      uses, so this is the contour the menu button's own call produces.
        let detected = try ClipPitchAnalyzer.detect(
            fileAt: url, fromSeconds: 0, durationSeconds: Self.seconds,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs)
        #expect(detected.voicedFrameCount > 0,
                "the fixture produced no voiced frames — every preset is then a no-op and the whole gate would pass for a reason that has nothing to do with the presets")

        // ---- ⭐ THE FIXTURE PRECONDITION, ASSERTED BEFORE ANYTHING DEPENDS ON IT.
        // If the detector reads the tone past the 50-cent watershed, chromatic
        // correction legitimately picks the NEXT semitone and the sign flips.
        // That is a broken fixture, and it must say so rather than looking like
        // a broken feature.
        let voiced = detected.frames.compactMap(\.frequencyHz)
        #expect(!voiced.isEmpty)
        let detectedHz = voiced.sorted()[voiced.count / 2]
        let detectedCents = M23QToneTracker.cents(detectedHz, above: Self.degreeHz)
        print(String(format:
            "fixture %.2f Hz (+%.1f c asked)  detector median %.2f Hz (%+.1f c)  %d/%d voiced",
            Self.fixtureHz, Self.detuneCents, detectedHz, detectedCents,
            detected.voicedFrameCount, detected.frameCount))
        #expect(detectedCents > 5 && detectedCents < 45,
                "the detector read the fixture \(String(format: "%+.1f", detectedCents)) cents from A3 — outside the safe band, so `nearestAllowedMidi` may pick a different degree and the whole sign convention below is void")

        // ---- the untuned reference render.
        let untuned = try Self.untunedRender(input)
        let untunedHz = try #require(Self.plateauHz(untuned),
                                     "the tracker found no tone in the untuned render's plateau")
        let untunedResidual = M23QToneTracker.cents(untunedHz, above: Self.degreeHz)
        let inputPeak = M23QWaveform.peakMagnitude(input)
        print(String(format: "input peak %.3f  untuned render peak %.3f  untuned residual %+.1f c",
                     inputPeak, Self.truePeak(untuned), untunedResidual))

        var asked: [PitchCorrectionPreset: Double] = [:]
        var measured: [PitchCorrectionPreset: Double] = [:]
        var residual: [PitchCorrectionPreset: Double] = [:]

        // The contour the RENDER shapes against: the whole-file detection
        // `PitchContourCache.renderContour` returns. For this untrimmed fixture
        // it is the same call as `detected` above (whole file, product
        // settings), which is exactly why the door's segments and the render's
        // contour agree here.
        let renderContour = PitchRenderContour.detected(
            try PitchContourCache.detectWholeFile(url, .product))

        for preset in PitchCorrectionPreset.offeredInUI {
            // ⭐ THE DOOR'S OWN CALL. `preset.options()` is character-for-character
            // what `AppModel.tuneVocalFromContextMenu` passes and what
            // `clip.autoCorrectPitch` builds for a preset with no key named.
            let set = PitchAutoCorrect.editSet(
                contour: detected.frames, frameRateHz: detected.frameRateHz,
                options: preset.options())
            #expect(!set.segments.isEmpty,
                    "\(preset.rawValue) produced no segments on a fully voiced fixture")
            #expect(!set.isIdentity,
                    "\(preset.rawValue) produced an IDENTITY set — it would take the constant path and render as if it had never been asked for")

            // The render's own plan: the render contour goes in exactly when
            // the edits need it (`StretchRenderCache.performRender`'s rule).
            let plan = try #require(
                StretchCurvePlan.make(
                    editSet: set, clipPitchShiftSemitones: 0,
                    sampleRate: Self.sampleRate, ratio: 1,
                    contour: set.needsDetectedContour ? renderContour : nil),
                "\(preset.rawValue) produced no render plan — the curve branch is not reachable for it")

            // ⭐ EVERY OFFERED PRESET RESOLVES. The ladder keeps
            // `preserveVibrato: true` and needs no contour; Hard Tune needs one
            // and now gets it. `withoutTheContourHardTuneDegradesAndSaysSo` is
            // the positive control that this list CAN be non-empty.
            #expect(plan.curve.unresolvedShapingSegmentIDs.isEmpty,
                    "\(preset.rawValue) has \(plan.curve.unresolvedShapingSegmentIDs.count) segment(s) the render path cannot resolve — it is being offered in the UI and cannot be honoured")

            let rendered = try Self.tunedRender(input, plan: plan)
            #expect(M23QWaveform.isAllFinite(rendered),
                    "\(preset.rawValue) rendered a non-finite sample")

            let hz = try #require(Self.plateauHz(rendered),
                                  "the tracker found no tone in \(preset.rawValue)'s plateau")
            let askedCents = set.segments.map(\.pitchOffsetCents).reduce(0, +)
                / Double(set.segments.count)
            let movedCents = M23QToneTracker.cents(hz, above: untunedHz)
            asked[preset] = askedCents
            measured[preset] = movedCents
            residual[preset] = M23QToneTracker.cents(hz, above: Self.degreeHz)

            // The same request through the CONSTANT path, as the second
            // instrument (see `constantRender`).
            let constant = try Self.constantRender(input, cents: askedCents)
            let constantHz = try #require(Self.plateauHz(constant),
                                          "the tracker found no tone in \(preset.rawValue)'s constant-path reference")
            let constantMoved = M23QToneTracker.cents(constantHz, above: untunedHz)

            let levelDb = 20 * log10(Self.plateauRMS(rendered) / Self.plateauRMS(untuned))
            print(String(format:
                "%-8@  %2d seg  asked %+6.1f c  curve %+6.1f c  constant %+6.1f c  residual %+6.1f c  peak %.3f  level %+.2f dB",
                preset.rawValue as NSString, set.segments.count,
                askedCents, movedCents, constantMoved, residual[preset]!,
                Self.truePeak(rendered), levelDb))

            // (a) DIRECTION. The fixture is sharp; a correction that is not a
            //     pull DOWN is not a correction, whatever its magnitude.
            #expect(askedCents < 0,
                    "\(preset.rawValue) asked for \(String(format: "%+.1f", askedCents)) cents on a SHARP note — the policy is pushing it further out of tune")
            #expect(movedCents < 0,
                    "\(preset.rawValue) moved the rendered pitch \(String(format: "%+.1f", movedCents)) cents — the wrong way")

            // (b) DEPTH, against the second instrument. The curve must deliver
            //     the SAME correction the constant path delivers for the same
            //     request — that is the assertion that a shallow, half-applied
            //     or ramp-never-arriving curve fails, and it is independent of
            //     how accurate the shared transposer is.
            #expect(abs(movedCents - constantMoved) < 4,
                    "\(preset.rawValue): the curve path moved \(String(format: "%+.1f", movedCents)) cents where the CONSTANT path moved \(String(format: "%+.1f", constantMoved)) for the same request — the curve is not arriving at full depth")

            // (c) MAGNITUDE against the request, to the ±12.90 cent floor §5.5.3
            //     writes the product claim against ("pulls a note's centre onto
            //     the scale, TO ROUGHLY THE DETECTOR'S OWN RESOLUTION"). Measured
            //     here after p2-acc (2026-09-25): the render lands within 0.1 c
            //     of the request (asked −16.8 / −28.5 / −33.5 c; curve −16.9 /
            //     −28.5 / −33.5; constant the same). Before the vendored
            //     fractional-read fix it landed 10.4 / 9.5 / 7.4 c shy.
            #expect(abs(movedCents - askedCents) < 12.90,
                    "\(preset.rawValue) asked for \(String(format: "%+.1f", askedCents)) cents and the render delivered \(String(format: "%+.1f", movedCents)) — further off the request than the detector's own resolution, so the product claim no longer holds")

            // (d) TRUE PEAK — a meter does not look up, and this tree has passed
            //     a loudness gate over a render clipping at +1.5 dBTP.
            #expect(Self.truePeak(rendered) < 1.0,
                    "\(preset.rawValue) rendered above full scale (true peak \(String(format: "%.3f", Self.truePeak(rendered)))) — it would crunch in any lossy export")
            // (e) LEVEL, on energy rather than peak (see `plateauRMS`). A tuning
            //     is not a gain stage.
            #expect(abs(levelDb) < 1.5,
                    "\(preset.rawValue) changed the level by \(String(format: "%+.2f", levelDb)) dB — a tuning is not a gain stage")
        }

        // (d) THE LADDER, MEASURED ON THE AUDIO. strengths 0.5 / 0.85 / 1.0
        //     against the same detected error, so a stronger preset must move
        //     the RENDER further. This is what catches two presets wired to one
        //     options blob — four identical files are a perfectly pleasant
        //     listening experience and a completely broken feature.
        let g = try #require(measured[.gentle])
        let n = try #require(measured[.natural])
        let t = try #require(measured[.tight])
        #expect(g > n && n > t,
                "the rendered corrections are not in strength order: gentle \(String(format: "%+.1f", g)) c, natural \(String(format: "%+.1f", n)) c, tight \(String(format: "%+.1f", t)) c — a stronger preset must move the audio further")
        #expect(abs(t) > abs(g) * 1.5,
                "tight moved \(String(format: "%.1f", abs(t))) cents against gentle's \(String(format: "%.1f", abs(g))) — strength 1.0 vs 0.5 should be close to twice, and this is not a ladder a listener could hear apart")

        // (e) IN-TUNENESS, the product claim itself: "pulls a note's centre onto
        //     the scale, to roughly the detector's own resolution."
        let tightResidual = try #require(residual[.tight])
        #expect(abs(tightResidual) < abs(untunedResidual),
                "Tight left the note \(String(format: "%.1f", abs(tightResidual))) cents out against the untuned \(String(format: "%.1f", abs(untunedResidual))) — it did not improve the tuning at all")
        #expect(abs(tightResidual) < 13,
                "Tight left the note \(String(format: "%.1f", abs(tightResidual))) cents from A3 — outside the ±12.90 cent detector floor the product claim is written against")
    }

    // MARK: - (2) the invariance controls — the boring ones that catch bugs

    @Test("⭐ an edit set that bends nothing takes the constant path, digests to nothing, and cannot be told from never-tuned")
    func nothingToBendIsByteIdenticalToNeverTuned() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sharp-a3.wav")
        let input = Self.fixtureSamples()
        try Self.writeWAV(input, to: url)
        let detected = try ClipPitchAnalyzer.detect(
            fileAt: url, fromSeconds: 0, durationSeconds: Self.seconds,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs)

        func plan(_ set: PitchEditSet?) -> StretchCurvePlan? {
            StretchCurvePlan.make(editSet: set, clipPitchShiftSemitones: 0,
                                  sampleRate: Self.sampleRate, ratio: 1)
        }

        // The three states that must be indistinguishable: never tuned (nil),
        // cleared (`clearClipPitchEdits` writes nil, never `.empty`), and a
        // strength-0 pass (`PitchAutoCorrect.editSet`'s short-circuit).
        let zeroStrength = PitchAutoCorrect.editSet(
            contour: detected.frames, frameRateHz: detected.frameRateHz,
            options: PitchAutoCorrectOptions(strength: 0))
        #expect(zeroStrength.segments.isEmpty,
                "strength 0 produced segments — the identity short-circuit is gone")
        #expect(zeroStrength.isIdentity)

        #expect(plan(nil) == nil, "a never-tuned clip must not reach the curve path")
        #expect(plan(zeroStrength) == nil,
                "a strength-0 pass reached the curve path — it would re-render a clip that asked for nothing")
        #expect(PitchEditSetDigest.hex(nil) == "",
                "a never-tuned clip must digest to the empty key")
        #expect(PitchEditSetDigest.hex(zeroStrength) == PitchEditSetDigest.hex(nil),
                "a clip that asked for no correction got a DIFFERENT cache key from one that was never tuned — it would re-render for nothing and re-key the playback schedule with it")

        // ⭐ THE POSITIVE CONTROL. Every assertion above is an equality or a
        // nil-check, and every one of them would also pass against a
        // `StretchCurvePlan.make` that returned nil unconditionally and a digest
        // that returned "" for everything. A real correction must break both.
        let real = PitchAutoCorrect.editSet(
            contour: detected.frames, frameRateHz: detected.frameRateHz,
            options: PitchCorrectionPreset.tight.options())
        #expect(plan(real) != nil,
                "POSITIVE CONTROL FAILED: a real Tight correction did not reach the curve path either, so the nil-checks above prove nothing")
        #expect(PitchEditSetDigest.hex(real) != "",
                "POSITIVE CONTROL FAILED: a real correction digests to the empty key, so the equality above proves nothing")

        // And the bytes, through the branch the dispatch actually takes: with no
        // plan there IS no second render, so "byte-identical" is the claim that
        // the constant call is the only thing that ran. Rendering it twice and
        // comparing is the cheapest way to say that out loud — and it is the
        // same call `StretchRenderCache` makes on the `else` branch.
        let a = try Self.untunedRender(input)
        let b = try Self.untunedRender(input)
        #expect(a.count == b.count)
        var differing = 0
        for (x, y) in zip(a, b) where x != y { differing += 1 }
        #expect(differing == 0,
                "\(differing) samples moved between two identical constant-path renders — the reference this suite measures everything against is not deterministic")
    }

    /// Formerly `hardTuneIsTheOnlyPresetTheRenderPathCannotHonour` — the reason
    /// `offeredInUI` withheld Hard Tune while the render built every curve with
    /// `contour: []`. That reason is gone (contour-to-render); what remains
    /// true, and is pinned here, is the FALLBACK: when the render cannot get
    /// the contour it builds exactly this no-contour plan, Hard Tune degrades
    /// to constant offsets, and the curve SAYS so through
    /// `unresolvedShapingSegmentIDs` — while the ladder, which never needed a
    /// contour, is unaffected either way.
    @Test("⛔ without the render contour Hard Tune degrades and says so; with it, every offered preset resolves")
    func withoutTheContourHardTuneDegradesAndSaysSo() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sharp-a3.wav")
        try Self.writeWAV(Self.fixtureSamples(), to: url)
        let detected = try ClipPitchAnalyzer.detect(
            fileAt: url, fromSeconds: 0, durationSeconds: Self.seconds,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs)
        let renderContour = PitchRenderContour.detected(
            try PitchContourCache.detectWholeFile(url, .product))

        func unresolved(_ preset: PitchCorrectionPreset,
                        _ contour: PitchRenderContour?) throws -> Int {
            let set = PitchAutoCorrect.editSet(
                contour: detected.frames, frameRateHz: detected.frameRateHz,
                options: preset.options())
            let plan = try #require(
                StretchCurvePlan.make(editSet: set, clipPitchShiftSemitones: 0,
                                      sampleRate: Self.sampleRate, ratio: 1,
                                      contour: contour))
            return plan.curve.unresolvedShapingSegmentIDs.count
        }

        // The fallback: no contour — the render's plan when detection is
        // unavailable. A segment asking for SHAPING has nothing to resolve
        // against, degrades to a constant offset, and is NAMED.
        #expect(try unresolved(.hardTune, nil) > 0,
                "hardTune resolved cleanly against NO contour — the fallback no longer reports what it could not do")
        #expect(try unresolved(.hardTune, .unavailable(reason: "planted")) > 0)
        // The product: the render contour — every offered preset resolves.
        for preset in PitchCorrectionPreset.offeredInUI {
            #expect(try unresolved(preset, renderContour) == 0,
                    "\(preset.rawValue) is offered in the UI and has segments the render cannot resolve even WITH the contour")
        }
        // And the ladder never depended on it.
        for preset in PitchCorrectionPreset.ladder {
            #expect(try unresolved(preset, nil) == 0)
        }
    }
}
