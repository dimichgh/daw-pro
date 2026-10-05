import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// Natural tuning §2 (m23-nt, lane NT-E2): **THE CONSONANT MIX, BYTE BY BYTE.**
/// Design `docs/design/2026-09-25-natural-tuning.md` §2b.3-2b.5 and §2g's
/// gates G-C1, G-C2, G-C4, G-C5, G-C6, G-C9 and G-C10, as amended by R1 (the
/// power-matched law, ρ per fade; G-C6 on the I1-F1 split), plus the order
/// with the level mask and the engine half of the render key.
///
/// ONE fixture, a sung phrase built from the source-filter voice: sibilant
/// noise and a low breath BETWEEN the notes, so the gaps are consonants and the
/// notes are vowels, as on a real take:
///
///     0.00-0.30 's'   head region (dry)
///     0.30-1.00 A     110 Hz, unmoved
///     1.00-1.20 's'   region between A and B (clean history: nothing moved yet)
///     1.20-1.90 B     147 Hz, MOVED +300 c
///     1.90-1.932      a 32 ms detector blink inside the vowel: a SOFT join, stays wet
///     1.932-2.60 C    147 Hz, unmoved
///     2.60-2.75 breath region AFTER a moved note (the phase wake)
///     2.75-3.50 D     110 Hz, MOVED −200 c
///     3.50-4.00 's'   tail region
///
/// Retune 30 ms (the editor seed), formant nil. Deliberately NOT `@MainActor`
/// (the cap): pure renders of in-memory audio.
@Suite("Natural tuning §2 — the consonant mix, byte gates (NT-E2)")
struct NaturalTuningConsonantRenderTests {
    typealias Params = StretchRenderCache.Params
    static let sampleRate = 48_000.0
    static func frame(_ seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }

    // MARK: - The fixture

    /// A low, smooth breath: white noise through a one-pole low-pass (about
    /// 500 Hz). Its waveform moves slowly, so a hard switch between it and a
    /// phase-rotated copy is a visible step (G-C4's plant needs that; a
    /// sibilant's own first difference is already as large as any switch).
    static func breath(seconds: Double, seed: UInt64) -> [Float] {
        let n = frame(seconds)
        var generator = SplitMix64(seed: seed)
        var out = [Float](repeating: 0, count: n)
        var state: Float = 0
        let a: Float = 0.064  // 1 − exp(−2π·500/48000)
        for i in 0..<n {
            state += a * ((generator.nextUnit() * 2 - 1) - state)
            out[i] = state * 1.6
        }
        return out
    }

    static func vowel(_ hz: Double, seconds: Double) -> [Float] {
        SourceFilterVoice.voice(f0Hz: hz, frames: frame(seconds), sampleRate: sampleRate,
                                amplitude: 0.5)
    }

    static func hiss(seconds: Double, seed: UInt64) -> [Float] {
        SourceFilterVoice.fricativeBurst(durationSeconds: seconds, sampleRate: sampleRate,
                                         amplitude: 0.3, seed: seed)
    }

    /// The phrase above, 4.0 s, mono.
    static let phrase: [Float] = {
        var x: [Float] = []
        x += hiss(seconds: 0.30, seed: 1)
        x += vowel(110, seconds: 0.70)
        x += hiss(seconds: 0.20, seed: 2)
        x += vowel(146.83, seconds: 1.40)  // B, the blink and C: one sustained vowel
        x += breath(seconds: 0.15, seed: 3)
        x += vowel(110, seconds: 0.75)
        x += hiss(seconds: 0.50, seed: 4)
        return x
    }()

    static let a = NoteSegment(startSeconds: 0.30, endSeconds: 1.00, detectedHz: 110, detectedConfidence: 0.95)
    static let b = NoteSegment(startSeconds: 1.20, endSeconds: 1.90, detectedHz: 146.83, detectedConfidence: 0.95)
    static let c = NoteSegment(startSeconds: 1.932, endSeconds: 2.60, detectedHz: 146.83, detectedConfidence: 0.95)
    static let d = NoteSegment(startSeconds: 2.75, endSeconds: 3.50, detectedHz: 110, detectedConfidence: 0.95)

    /// The phrase's table with B +300 c and D −200 c. `edit` may change more.
    static func set(consonants: Bool, _ edit: (inout [NoteSegment]) -> Void = { _ in }) -> PitchEditSet {
        var notes = [a, b, c, d]
        notes[1].pitchOffsetCents = 300
        notes[3].pitchOffsetCents = -200
        edit(&notes)
        return PitchEditSet(segments: notes, retuneMs: 30, keepsConsonantsUntuned: consonants)
    }

    static func params(_ set: PitchEditSet, ratio: Double = 1, semitones: Double = 0) -> Params {
        Params(ratio: ratio, semitones: semitones, formantPreserve: false, pitchEdits: set)
    }

    /// The product render body, whole-file entry.
    static func render(_ params: Params, _ input: [Float] = phrase) throws -> [Float] {
        var whole = [input]
        return try StretchRenderCache.renderAudio(
            whole: &whole, window: nil, sampleRate: sampleRate, params: params,
            curveContour: nil, isCancelled: { false }).output.planar[0]
    }

    /// The product render body, window entry (I1-F1's `renderOutputFrames`),
    /// reading the phrase from memory.
    static func window(_ frames: Range<Int>, _ params: Params, preRoll: Int? = nil,
                       input: [Float] = phrase) throws -> [Float] {
        let source = StretchRenderCache.SpanSource(
            url: URL(fileURLWithPath: "/nonexistent/nt-e2-phrase.wav"), channels: 1,
            sampleRate: sampleRate, frames: input.count,
            read: { range, _ in [Array(input[range])] })
        return try StretchRenderCache.renderOutputFrames(
            frames, of: source, params: params, preRollFrames: preRoll,
            renderCacheDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("nt-e2-unused", isDirectory: true),
            detector: .product, isCancelled: { false }).planar[0]
    }

    /// The mix's weight at every frame, from DAWCore (`tunedWeight`, the set
    /// level, with its own search), independently of the render.
    static func weights(_ set: PitchEditSet, count: Int) -> [Double] {
        (0..<count).map { set.tunedWeight(atSourceSecond: Double($0) / sampleRate) }
    }

    /// Maximal runs of frames where `predicate` holds.
    static func runs(_ count: Int, _ predicate: (Int) -> Bool) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start: Int?
        for i in 0..<count {
            if predicate(i) { if start == nil { start = i } } else if let s = start {
                out.append(s..<i)
                start = nil
            }
        }
        if let s = start { out.append(s..<count) }
        return out
    }

    static func mismatches(_ x: [Float], _ y: [Float], in frames: [Range<Int>]) -> Int {
        frames.reduce(0) { total, range in
            total + range.filter { x[$0].bitPattern != y[$0].bitPattern }.count
        }
    }

    static func rms(_ x: [Float], _ range: Range<Int>) -> Double {
        guard !range.isEmpty else { return 0 }
        let sum = range.reduce(0.0) { $0 + Double(x[$1]) * Double(x[$1]) }
        return (sum / Double(range.count)).squareRoot()
    }

    static func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }

    /// `10·log10(Σ(a−b)² / Σb²)` over `range`; −infinity when bit-identical.
    static func residualDb(_ a: [Float], _ b: [Float], _ range: Range<Int>) -> Double {
        var diff = 0.0, ref = 0.0
        for i in range {
            let d = Double(a[i]) - Double(b[i])
            diff += d * d
            ref += Double(b[i]) * Double(b[i])
        }
        guard diff > 0 else { return -.infinity }
        return 10 * log10(diff / max(ref, 1e-30))
    }

    // MARK: - The fixture's own premises

    @Test("fixture: the regions are the head, the 's' before B, the breath after C and the tail; the 32 ms blink is a soft join; the mix is active at ratio 1, 0 st")
    func fixturePremises() {
        let on = Self.set(consonants: true)
        let regions = on.consonantRegions()
        #expect(regions.map(\.startSeconds) == [0, 1.00, 2.60, 3.50], "\(regions)")
        #expect(Array(regions.map(\.endSeconds).prefix(3)) == [0.30, 1.20, 2.75])
        #expect(on.joinKind(between: 1, and: 2) == .soft)
        #expect(StretchCurvePlan.consonantMixActive(Self.params(on)))
        #expect(!StretchCurvePlan.consonantMixActive(Self.params(Self.set(consonants: false))))
        #expect(Self.phrase.count == Self.frame(4.0))
    }

    // MARK: - G-C1: the dry gaps ARE the source

    @Test("G-C1: flag on, every frame inside a region beyond its fades is the SOURCE's bytes; flag off, those frames are not (the stretcher resynthesises them); a moved note is not the source")
    func dryGapsAreTheSource() throws {
        let on = Self.set(consonants: true)
        let rendered = try Self.render(Self.params(on))
        let flagOff = try Self.render(Self.params(Self.set(consonants: false)))
        let w = Self.weights(on, count: rendered.count)
        let dryFrames = Self.runs(rendered.count) { w[$0] == 0 }
        let dryCount = dryFrames.reduce(0) { $0 + $1.count }
        let onMismatch = Self.mismatches(rendered, Self.phrase, in: dryFrames)
        let offMismatch = Self.mismatches(flagOff, Self.phrase, in: dryFrames)
        let bFrames = [Self.frame(1.30)..<Self.frame(1.80)]
        let noteMismatch = Self.mismatches(rendered, Self.phrase, in: bFrames)
        print("[measured] G-C1: \(dryCount) dry frames in \(dryFrames.count) runs; flag on \(onMismatch) differ from the source, flag off \(offMismatch); moved B \(noteMismatch) of \(bFrames[0].count)")
        #expect(dryCount > Self.frame(1.0), "premise: the fixture has over a second of dry frames")
        #expect(onMismatch == 0, "G-C1: \(onMismatch) dry frames are not the source's bytes")
        #expect(offMismatch > dryCount / 2, "positive control: flag off resynthesises the gaps")
        #expect(noteMismatch > bFrames[0].count / 2, "negative control: the moved note is not the source")
    }

    // MARK: - G-C2: note frames untouched

    @Test("G-C2: flag on vs flag off, every frame with weight 1 (every note, the soft blink, a levelled and a cleared note) is byte-identical; frames inside the regions differ (the mix ran)")
    func noteFramesAreUntouched() throws {
        for levelled in [false, true] {
            let edit: (inout [NoteSegment]) -> Void = { notes in
                guard levelled else { return }
                notes[0].amplitudeDb = -6
                notes[2].isCleared = true
            }
            let on = Self.set(consonants: true, edit)
            let rendered = try Self.render(Self.params(on))
            let flagOff = try Self.render(Self.params(Self.set(consonants: false, edit)))
            let w = Self.weights(on, count: rendered.count)
            let tuned = Self.runs(rendered.count) { w[$0] == 1 }
            let mixed = Self.runs(rendered.count) { w[$0] < 1 }
            let tunedMismatch = Self.mismatches(rendered, flagOff, in: tuned)
            let mixedMismatch = Self.mismatches(rendered, flagOff, in: mixed)
            print("[measured] G-C2 (levels \(levelled)): \(tunedMismatch) of \(tuned.reduce(0) { $0 + $1.count }) weight-1 frames differ; \(mixedMismatch) of \(mixed.reduce(0) { $0 + $1.count }) region frames differ")
            #expect(tunedMismatch == 0, "G-C2 (levels \(levelled)): a note frame changed")
            #expect(mixedMismatch > 1_000, "negative control (levels \(levelled)): the mix changed nothing")
        }
    }

    // MARK: - G-C4 / G-C5: the joins

    /// Every fade of `set`'s mix: the runs of frames with 0 < w < 1.
    static func fades(_ set: PitchEditSet, count: Int) -> [Range<Int>] {
        let w = weights(set, count: count)
        return runs(count) { w[$0] > 0 && w[$0] < 1 }
    }

    /// G-C4's reading at one fade: max |Δy| over the fade ± 2 ms, against
    /// 1.1 × the larger of the two sides' own max |Δ| there (p2-ren G3).
    static func click(_ y: [Float], dry: [Float], wet: [Float], fade: Range<Int>) -> (step: Float, bound: Float) {
        let pad = frame(0.002)
        let lo = max(1, fade.lowerBound - pad), hi = min(y.count, fade.upperBound + pad)
        var step: Float = 0, dryStep: Float = 0, wetStep: Float = 0
        for i in lo..<hi {
            step = max(step, abs(y[i] - y[i - 1]))
            dryStep = max(dryStep, abs(dry[i] - dry[i - 1]))
            wetStep = max(wetStep, abs(wet[i] - wet[i - 1]))
        }
        return (step, 1.1 * max(dryStep, wetStep))
    }

    /// G-C5's reading at one fade: the output's RMS over the fade's central
    /// half (where the crossfade is deepest) against the mean of the two
    /// sides' RMS over the same frames, dB.
    static func envelope(_ y: [Float], dry: [Float], wet: [Float], fade: Range<Int>) -> Double {
        let quarter = fade.count / 4
        let centre = (fade.lowerBound + quarter)..<(fade.upperBound - quarter)
        let sides = (rms(dry, centre) + rms(wet, centre)) / 2
        return db(rms(y, centre)) - db(sides)
    }

    @Test("G-C4 no click at any join (first difference within p2-ren G3's bound) and G-C5 no dip or bump (fade-centre RMS within [−6, +1.5] dB of the two sides'); every fade's ρ reported; flag off has no join")
    func joinsAreClean() throws {
        let on = Self.set(consonants: true)
        let rendered = try Self.render(Self.params(on))
        // The wet side the mix blended: the flag-off render, frame for frame.
        let wet = try Self.render(Self.params(Self.set(consonants: false)))
        var wetAudio = [wet]
        let fadesRead = try StretchCurvePlan.applyConsonantMix(
            on.consonantRegions(), wet: &wetAudio, dry: [Self.phrase], sampleRate: Self.sampleRate,
            ratio: 1)
        #expect(wetAudio[0] == rendered, "the pass on the flag-off render IS the product render")
        let fades = Self.fades(on, count: rendered.count)
        #expect(fades.count == 6, "head 1, 's' 2, breath 2, tail 1: \(fades)")
        #expect(fadesRead.map(\.frames) == fades, "the pass reports the fades the weight defines")
        for (fade, read) in zip(fades, fadesRead) {
            let (step, bound) = Self.click(rendered, dry: Self.phrase, wet: wet, fade: fade)
            let env = Self.envelope(rendered, dry: Self.phrase, wet: wet, fade: fade)
            print("[measured] join at \(String(format: "%.4f", Double(fade.lowerBound) / Self.sampleRate)) s (\(read.afterNote ? "after a note" : "before a note")): ρ \(String(format: "%.3f", read.correlation)) (law \(String(format: "%.3f", read.rho))), step \(step) vs bound \(bound), envelope \(String(format: "%+.2f", env)) dB")
            #expect(step <= bound, "G-C4: a click at \(fade)")
            #expect(env >= -6 && env <= 1.5, "G-C5: the envelope at \(fade) reads \(env) dB")
        }
        // Negative control (G-C5): flag off has no join to check.
        #expect(Self.fades(Self.set(consonants: false), count: rendered.count).isEmpty)
    }

    /// Max |x[i] − 2x[i−1] + x[i−2]| over `range`: a step in a smooth
    /// waveform is a spike here, a slow gain ramp is not.
    static func maxSecondDifference(_ x: [Float], _ range: Range<Int>) -> Double {
        var peak = 0.0
        for i in max(2, range.lowerBound)..<min(x.count, range.upperBound) {
            peak = max(peak, abs(Double(x[i]) - 2 * Double(x[i - 1]) + Double(x[i - 2])))
        }
        return peak
    }

    /// ⛔ **THE PHRASE'S G-C4 CANNOT SEE A HARD SWITCH, MEASURED.** Under the
    /// fade = 0 plant (the weight snapped to 0 or 1) `joinsAreClean` stayed
    /// green: every join there sits on a fixture segment boundary, and the
    /// source's own step at that boundary (a glottal pulse, a hiss onset) sets
    /// the bound (0.169 against 0.175 at 2.60 s, 0.165 against 0.413 at
    /// 2.74 s). Between two SMOOTH sides a hard switch is a step the second
    /// difference sees at once, while a 10 ms raised-cosine handover only
    /// sums the sides' own curvature plus a slow gain slope (about 2× here,
    /// worked in the report). Two pairs: two different sines (ρ near 0) and
    /// one sine on both sides (a clean history, ρ 1, where equal power would
    /// read +3 dB).
    @Test("G-C4/G-C5 on smooth sides: across each fade between two sines the output's second difference stays within 4× the sides' own and its RMS within [−6, +1.5] dB; the hard switch fade = 0 would write, built here, reads over 50× (the instrument can fail)")
    func smoothJoinsAreClean() throws {
        let n = Self.frame(0.4)
        func sine(_ hz: Double, phase: Double) -> [Float] {
            (0..<n).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / Self.sampleRate + phase)) }
        }
        let region = PitchConsonantRegion(startSeconds: 0.1, endSeconds: 0.3, followsNote: true,
                                          precedesNote: true)
        let pairs: [(String, wet: [Float], dry: [Float])] = [
            ("different sines (300 Hz tuned, 220 Hz dry)", sine(300, phase: 0), sine(220, phase: 1.0)),
            ("one sine both sides (clean history)", sine(220, phase: 1.0), sine(220, phase: 1.0)),
        ]
        for (label, wet, dry) in pairs {
            var out = [wet]
            let fades = try StretchCurvePlan.applyConsonantMix([region], wet: &out, dry: [dry],
                                                               sampleRate: Self.sampleRate, ratio: 1)
            #expect(fades.count == 2, "\(label): one fade per note-facing end")
            for fade in fades {
                let pad = Self.frame(0.002)
                let span = (fade.frames.lowerBound - pad)..<(fade.frames.upperBound + pad)
                let sides = max(Self.maxSecondDifference(wet, span), Self.maxSecondDifference(dry, span))
                let curvature = Self.maxSecondDifference(out[0], span)
                // Negative control: the hard switch at the fade's middle, the
                // output the fade = 0 plant writes (tuned on the note's side).
                let middle = (fade.frames.lowerBound + fade.frames.upperBound) / 2
                let hard = (0..<n).map { i -> Float in
                    let tunedSide = fade.afterNote ? i < middle : i >= middle
                    return tunedSide ? wet[i] : dry[i]
                }
                let hardCurvature = Self.maxSecondDifference(hard, span)
                let env = Self.envelope(out[0], dry: dry, wet: wet, fade: fade.frames)
                print("[measured] smooth join, \(label), \(fade.afterNote ? "after" : "before") a note: ρ \(String(format: "%.3f", fade.correlation)) (law \(String(format: "%.3f", fade.rho))), curvature \(String(format: "%.2f", curvature / sides))× the sides', a hard switch \(String(format: "%.1f", hardCurvature / sides))×, envelope \(String(format: "%+.2f", env)) dB")
                #expect(curvature <= 4 * sides, "G-C4: a click at \(fade.frames) (\(label))")
                #expect(env >= -6 && env <= 1.5, "G-C5: the envelope at \(fade.frames) reads \(env) dB (\(label))")
                if label.hasPrefix("different") {
                    #expect(hardCurvature > 50 * sides, "control: a hard switch between different sines must read as a click")
                }
            }
        }
    }

    // MARK: - G-C6: window == whole (the I1-F1 split, R1)

    @Test("G-C6 (a): windows with an untransposed history equal the whole-file render below −90 dB: one straddling the 's' fade after A, one whose END cuts the fade before moved B (the widening), one away from any join; G-C6 (b): a window over the breath after moved B keeps the whole file's level")
    func windowEqualsWhole() throws {
        let params = Self.params(Self.set(consonants: true))
        let whole = try Self.render(params)
        let cases: [(String, Range<Int>)] = [
            ("straddles the fade after A", Self.frame(0.90)..<Self.frame(1.15)),
            ("its end cuts the fade before B", Self.frame(1.10)..<(Self.frame(1.195) + 1)),
            ("away from any join", Self.frame(0.45)..<Self.frame(0.85)),
        ]
        for (label, frames) in cases {
            let span = try Self.window(frames, params)
            let reference = Array(whole[frames])
            let residual = Self.residualDb(span, reference, 0..<frames.count)
            print("[measured] G-C6 (a) \(label): \(String(format: "%.1f", residual)) dB")
            #expect(residual < -90, "G-C6 (a) \(label): \(residual) dB")
        }
        // (b) Transposed history: the level over the breath region matches.
        let breath = Self.frame(2.55)..<Self.frame(2.80)
        let span = try Self.window(breath, params)
        let level = Self.db(Self.rms(span, 0..<breath.count)) - Self.db(Self.rms(whole, breath))
        let interior = (Self.frame(2.62) - breath.lowerBound)..<(Self.frame(2.73) - breath.lowerBound)
        let dryInterior = Self.residualDb(span, Array(whole[breath]), interior)
        print("[measured] G-C6 (b) breath after moved B: level \(String(format: "%+.2f", level)) dB; the dry interior \(dryInterior) dB")
        #expect(abs(level) < 1.5, "G-C6 (b): the window's level differs by \(level) dB")
        #expect(dryInterior == -.infinity, "G-C6 (b): the dry interior is the source in both")
    }

    @Test("G-C6 widening: a window whose edge cuts a fade renders wide enough to hold it and trims back to the original span; a window cutting none is run as asked")
    func consonantMixWindowWidens() throws {
        let on = Self.set(consonants: true)
        let regions = on.consonantRegions()
        func win(_ lo: Int, _ hi: Int) -> StretchWindow {
            StretchWindow(channels: 1, sourceFrames: Self.phrase.count, startOutputFrame: lo,
                          endOutputFrame: hi, readSource: { _ in [] })
        }
        let schedule = try OfflineStretcher.curveSchedule(sourceFrames: Self.phrase.count, channels: 1,
                                                          sampleRate: Self.sampleRate, ratio: 1)
        // The end cuts the fade before B (1.19-1.20 s).
        let cut = win(Self.frame(1.10), Self.frame(1.195))
        let (wide, trim) = try StretchRenderCache.consonantMixWindow(
            cut, regions: regions, sampleRate: Self.sampleRate, ratio: 1)
        let original = schedule.span(startOutputFrame: cut.startOutputFrame, endOutputFrame: cut.endOutputFrame)
        #expect(trim == original.startOutputFrame..<original.endOutputFrame)
        #expect(wide.endOutputFrame >= Self.frame(1.20) - 1, "the end moved to the fade's end: \(wide.endOutputFrame)")
        // A window inside A cuts nothing.
        let (same, none) = try StretchRenderCache.consonantMixWindow(
            win(Self.frame(0.5), Self.frame(0.8)), regions: regions, sampleRate: Self.sampleRate, ratio: 1)
        #expect(none == nil && same.endOutputFrame == Self.frame(0.8))
        // A START cut: the loop starts on the block grid, and a fade that
        // grid line splits moves the start back to the fade's start (the span
        // then snaps to the block before it).
        let block = schedule.blockFrames
        let cutStart = PitchConsonantRegion(
            startSeconds: Double(10 * block - 100) / Self.sampleRate, endSeconds: 1.5,
            followsNote: true, precedesNote: true)
        let (startWide, startTrim) = try StretchRenderCache.consonantMixWindow(
            win(10 * block + 50, 12 * block), regions: [cutStart], sampleRate: Self.sampleRate, ratio: 1)
        #expect(startTrim == (10 * block)..<(12 * block), "the trim is the original span: \(String(describing: startTrim))")
        #expect(startWide.startOutputFrame <= 10 * block - 100, "the start moved to the fade's start: \(startWide.startOutputFrame)")
        // No regions: never widened.
        #expect(try StretchRenderCache.consonantMixWindow(cut, regions: [], sampleRate: Self.sampleRate,
                                                           ratio: 1).trim == nil)
    }

    // MARK: - G-C9: inactive = today's bytes

    @Test("G-C9: on a stretched (1.5) or transposed (+1 st) clip, flag-on bytes equal flag-off bytes and a reason is given; at ratio 1, 0 st the reason is nil; the render still reads no time warp")
    func inactiveIsToday() throws {
        for (ratio, semitones) in [(1.5, 0.0), (1.0, 1.0)] {
            let on = Self.params(Self.set(consonants: true), ratio: ratio, semitones: semitones)
            let off = Self.params(Self.set(consonants: false), ratio: ratio, semitones: semitones)
            #expect(StretchCurvePlan.consonantMixInactiveReason(on) != nil)
            #expect(!StretchCurvePlan.consonantMixActive(on))
            let a = try Self.render(on), b = try Self.render(off)
            let differing = zip(a, b).filter { $0.bitPattern != $1.bitPattern }.count
            print("[measured] G-C9 ratio \(ratio) semitones \(semitones): \(differing) of \(a.count) frames differ, reason \(String(describing: StretchCurvePlan.consonantMixInactiveReason(on)))")
            #expect(a.count == b.count && differing == 0, "G-C9: an inactive flag changed \(differing) frames")
        }
        #expect(StretchCurvePlan.consonantMixInactiveReason(Self.params(Self.set(consonants: true))) == nil)
        #expect(StretchCurvePlan.readsTimeWarp == false,
                "TRIPWIRE: the render reads the time warp now; re-decide §2b.5's 'time edits' rule")
    }

    // MARK: - G-C10: blinks stay wet

    @Test("G-C10: the 32 ms blink between B and C renders exactly as flag off (tuned); the 200 ms 's' gap does go dry")
    func blinksStayWet() throws {
        let rendered = try Self.render(Self.params(Self.set(consonants: true)))
        let flagOff = try Self.render(Self.params(Self.set(consonants: false)))
        let blink = [Self.frame(1.90)..<Self.frame(1.932)]
        let gap = [Self.frame(1.02)..<Self.frame(1.18)]
        let blinkMismatch = Self.mismatches(rendered, flagOff, in: blink)
        let gapMismatch = Self.mismatches(rendered, flagOff, in: gap)
        print("[measured] G-C10: blink \(blinkMismatch) of \(blink[0].count) frames differ from flag off; the 's' gap \(gapMismatch) of \(gap[0].count)")
        #expect(blinkMismatch == 0, "G-C10: the blink became a dry island")
        #expect(gapMismatch > gap[0].count / 2, "negative control: a real gap goes dry")
    }

    // MARK: - The order with the level mask

    @Test("ORDER: a CLEARED, untouched breath inside a region renders as silence (the mix runs before the level mask); uncleared, the same frames are the source")
    func clearedBreathStaysSilent() throws {
        func withBreath(cleared: Bool) -> PitchEditSet {
            Self.set(consonants: true) { notes in
                notes.append(NoteSegment(startSeconds: 2.60, endSeconds: 2.75, detectedHz: 110,
                                         detectedConfidence: 0.2, isCleared: cleared, origin: .unpitched))
            }
        }
        let cleared = withBreath(cleared: true)
        let sound = try #require(cleared.segments.first { $0.origin == .unpitched })
        #expect(!sound.entersPitchCurve, "premise: an untouched sound is inside the region")
        let rendered = try Self.render(Self.params(cleared))
        let plateau = Self.runs(rendered.count) {
            cleared.gain(atSourceSecond: Double($0) / Self.sampleRate) == 0
        }
        let loud = plateau.reduce(0) { total, range in total + range.filter { rendered[$0] != 0 }.count }
        let plateauCount = plateau.reduce(0) { $0 + $1.count }
        let open = try Self.render(Self.params(withBreath(cleared: false)))
        let w = Self.weights(cleared, count: rendered.count)
        let dryPlateau = plateau.map { range in range.filter { w[$0] == 0 } }
            .flatMap { $0 }.map { $0..<($0 + 1) }
        let openMismatch = Self.mismatches(open, Self.phrase, in: dryPlateau)
        print("[measured] ORDER: \(plateauCount) cleared frames, \(loud) not silent; uncleared, \(openMismatch) differ from the source")
        #expect(plateauCount > Self.frame(0.1), "premise: the cleared plateau is over 100 ms")
        #expect(loud == 0, "ORDER: \(loud) frames of a cleared breath play (the mix ran after the mask)")
        #expect(openMismatch == 0, "control: uncleared, the breath is the dry source")
    }

    // MARK: - Denormals and NaN

    @Test("GUARDS: a fade whose blend is denormal is flushed to +0, a NaN on the tuned side plays the source, and a region's interior copies the source's own bytes (a denormal there stays: it IS the source)")
    func denormalAndNaNGuards() throws {
        let region = PitchConsonantRegion(startSeconds: 0.001, endSeconds: 0.1, followsNote: true,
                                          precedesNote: true)
        let n = Self.frame(0.1) + 10
        let tiny = Float.leastNormalMagnitude / 4
        let nanFrame = Self.frame(0.004)
        var wet = [[Float](repeating: tiny, count: n)]
        var dry = [[Float](repeating: tiny, count: n)]
        wet[0][nanFrame] = .nan
        dry[0][nanFrame] = 0.25
        try StretchCurvePlan.applyConsonantMix([region], wet: &wet, dry: dry,
                                               sampleRate: Self.sampleRate, ratio: 1)
        let fade = (Self.frame(0.001) + 1)..<Self.frame(0.011)
        #expect(fade.allSatisfy { wet[0][$0].isFinite }, "a NaN survived the fade")
        #expect(wet[0][nanFrame] == 0.25, "a NaN on the tuned side did not play the source")
        #expect(fade.allSatisfy { $0 == nanFrame || wet[0][$0].bitPattern == 0 },
                "a denormal blend survived the fade (it must flush to +0)")
        #expect(wet[0][Self.frame(0.05)].bitPattern == tiny.bitPattern, "the interior is the source's bytes")
    }

    // MARK: - The engine half of the key

    /// `renderKeys`' fields up to `legacy`, WITHOUT the consonant field: the
    /// key every render had before NT-E2.
    static func keyWithoutMix(_ url: URL, _ params: Params) throws -> String {
        var fields = try StretchRenderCache.sourceIdentityFields(source: url)
        fields += [String(params.ratio.bitPattern), String(params.semitones.bitPattern),
                   params.formantPreserve ? "1" : "0", String(StretchRenderCache.stretchEngineVersion)]
        if !params.pitchEditSetHash.isEmpty { fields.append("pitch:" + params.pitchEditSetHash) }
        if params.semitones != 0 || !params.pitchEditSetHash.isEmpty
            || StretchRenderCache.phaseVocoderNearUnity(params.ratio) {
            fields.append("pv:\(StretchRenderCache.transposeEngineVersion)")
        }
        return StretchRenderCache.keyDigest(fields)
    }

    @Test("KEY: a render that runs the mix gains `consonantMix:1` (the pre-mix key under slot 8 is never served as the mix); flag off, and flag on while transposed or stretched, keep their keys byte for byte")
    func renderKeyNamesTheMix() throws {
        let dir = try I1Signals.tempDir("nt-e2-key")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("phrase.wav")
        try I1Signals.write([Self.phrase], sampleRate: Self.sampleRate, to: url)
        func key(_ p: Params) throws -> String {
            try StretchRenderCache.renderKeys(source: url, params: p, detector: .product).legacy
        }
        let active = Self.params(Self.set(consonants: true))
        // Positive control: the reconstruction IS the key of a render without the mix.
        let flagOff = Self.params(Self.set(consonants: false))
        #expect(try key(flagOff) == Self.keyWithoutMix(url, flagOff), "the reconstruction is wrong")
        #expect(try key(active) != Self.keyWithoutMix(url, active), "the mix did not re-key its render")
        var fields = try StretchRenderCache.sourceIdentityFields(source: url)
        fields += [String(active.ratio.bitPattern), String(active.semitones.bitPattern), "0",
                   String(StretchRenderCache.stretchEngineVersion), "pitch:" + active.pitchEditSetHash,
                   "pv:\(StretchRenderCache.transposeEngineVersion)",
                   "consonantMix:\(StretchRenderCache.consonantMixVersion)"]
        #expect(try key(active) == StretchRenderCache.keyDigest(fields))
        for (ratio, semitones) in [(1.5, 0.0), (1.0, 2.0)] {
            let inactive = Self.params(Self.set(consonants: true), ratio: ratio, semitones: semitones)
            #expect(try key(inactive) == Self.keyWithoutMix(url, inactive),
                    "an inactive flag-on render (ratio \(ratio), \(semitones) st) was re-keyed")
        }
    }
}
