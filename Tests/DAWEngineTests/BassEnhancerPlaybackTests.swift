import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m23-p2 — THE HIGH-PASSED-PLAYBACK A/B, the leg the roadmap's parent line
/// demands and the only one that tests the PSYCHOACOUSTIC claim rather than the
/// arithmetic one.
///
/// m23-p1 already pinned the harmonic series numerically (H2 −11.231, H3
/// −11.421, H4 −12.782 dB as literals, predicted from theory before they were
/// measured). Re-measuring that series here would prove nothing new. The claim
/// this file exists for is the product claim: **play the same bass part through
/// a speaker that cannot reproduce it, and the enhanced version still carries
/// the note while the dry one goes quiet.**
///
/// ## What is deliberately chosen, and why (state it, do not let it be an
/// accident of fixture convenience)
///
/// **The program is FUNDAMENTAL-DOMINANT by choice.** A plucked or DI bass
/// already carries strong 2nd/3rd harmonics of its own, so a small speaker
/// keeps plenty of it and the A/B delta collapses toward noise. That is not the
/// case this effect exists for. The case it exists for is sub-heavy synth bass
/// — a near-sine fundamental with almost nothing above it — played on a phone.
/// Three sustained near-sine notes, then, at 52 / 58 / 66 Hz: a real part (the
/// pitch changes, the level changes) with the spectral shape the effect is for.
///
/// **The speaker is modelled by an INDEPENDENT instrument.** The "small
/// speaker" here is a cascade of three plain RC one-pole high-passes
/// (18 dB/oct) whose coefficient is a pasted literal, NOT
/// `EQFilterResponse.cutSection` and not an RBJ biquad — the effect's own
/// filter math is the thing under test, and an instrument built from it would
/// let a coefficient error cancel itself out. Different formula, different
/// order, hardcoded coefficient.
///
/// **Every expectation is a pasted literal.** Nothing here derives an expected
/// level from `crossoverHz` or from `BassEnhancerParams.harmonicWeights` — that
/// would test this file's arithmetic against the DSP's arithmetic and call the
/// agreement a result. The Goertzel probe frequencies ARE derived from the
/// program's own note pitches, which is legitimate: those are properties of the
/// fixture, not of the effect.
///
/// ## The four legs, and what each one separates
///
///  · B1 the dry path is untouched → separates ADDING from BOOSTING. Without
///    it, "the enhanced version has more energy above the corner" is equally
///    satisfied by a wideband gain, which would be a strictly worse effect
///    sold with the same sentence.
///  · B2 through the speaker, dry loses / enhanced retains → the headline.
///  · B3 the retained partials TRACK the note → the residue-pitch claim. A
///    generator locked to a fixed frequency, or one following the crossover
///    instead of the content, would keep B2 green and redden only here.
///  · B4 the dry has nothing at those partial frequencies → anti-vacuity: the
///    retained energy is the effect's, not the program's own overtones.
///
/// ## What B4 does NOT catch, measured rather than assumed
///
/// Mutation M3 (`w4 = 0` — the 4th partial dropped from the series) left B4
/// **green**. Its floor is 50 dB over a dry reading that sits at −137 dB, and
/// the clamp plus the envelope's residual ripple still put ~−60 dB of leakage
/// in the 4f bin. That is the correct scope for an anti-vacuity leg and it is
/// worth stating so nobody over-credits it: **B4 proves the energy is
/// generated, B3's literal margins prove it has the right SHAPE**, and m23-p1's
/// H2/H3/H4 literals prove the series itself. Reading B4 as a series check
/// would be reading a floor as a fingerprint.
@MainActor
@Suite("Bass enhancer — high-passed playback A/B (m23-p2)")
struct BassEnhancerPlaybackTests {
    private static let sampleRate = 48_000.0

    // MARK: - The program

    /// One note: 0.75 s. The first 0.25 s ramps in (the enhancer's amplitude
    /// detector is a 50 ms one-pole, so a hard edge would fold its settle into
    /// the reading); the last 0.5 s is steady and is the ONLY part measured.
    private static let noteFrames = 36_000
    private static let attackFrames = 12_000
    /// 24 000 frames at 48 kHz = one bin every 2 Hz, so every pitch below and
    /// every partial of it lands EXACTLY on a Goertzel bin (all are even Hz).
    private static let measureFrames = 24_000

    /// The part. Even-Hz pitches so the bins are exact; pitches and levels both
    /// change so this is a part and not a tone. No two notes share a partial:
    /// 2f = 104/116/132, 3f = 156/174/198, 4f = 208/232/264 — nine distinct
    /// frequencies, which is what makes the B3 tracking leg meaningful.
    private static let notes: [(f0: Double, amplitude: Double)] = [
        (52, 0.50), (58, 0.35), (66, 0.45),
    ]

    /// The crossover the part is played through — the effect's corner AND the
    /// modelled speaker's. 100 Hz is a small-speaker figure (a laptop is nearer
    /// 150, a phone higher still); every note here is a fifth to an octave
    /// below it, which is the situation the effect addresses.
    private static let crossoverHz = 100.0

    /// The measurement window of note `index`, in frames of the whole program.
    private static func window(_ index: Int) -> Range<Int> {
        let start = index * noteFrames + (noteFrames - measureFrames)
        return start..<(start + measureFrames)
    }

    private func program() -> [Float] {
        var out = [Float]()
        out.reserveCapacity(Self.notes.count * Self.noteFrames)
        for note in Self.notes {
            for frame in 0..<Self.noteFrames {
                // Raised-cosine attack, then dead steady through the window.
                let ramp = frame < Self.attackFrames
                    ? 0.5 - 0.5 * cos(.pi * Double(frame) / Double(Self.attackFrames))
                    : 1.0
                let phase = 2.0 * Double.pi * note.f0 * Double(frame) / Self.sampleRate
                out.append(Float(note.amplitude * ramp * sin(phase)))
            }
        }
        return out
    }

    // MARK: - The independent speaker model

    /// A plain RC one-pole high-pass coefficient at 100 Hz / 48 kHz:
    /// `a = 1 / (1 + 2π·fc/fs)`. PASTED, not computed — see the suite note. The
    /// effect's own corner is a 2nd-order RBJ Butterworth section; this shares
    /// no formula, no order and no code with it.
    private static let speakerPoleCoefficient = 0.9870791639583207

    /// How many of those cascade — 6 poles ≈ 36 dB/oct.
    ///
    /// THIS NUMBER WAS CHOSEN ON EVIDENCE AND THE EVIDENCE IS RECORDED. The
    /// first draft used 3 poles (18 dB/oct) and measured a retention of only
    /// **2.8–4.0 dB**, which would have been a weak headline dressed up as a
    /// strong one. The reason is worth keeping: at 18 dB/oct a 52 Hz
    /// fundamental is still only 20 dB down at the far side of a 100 Hz
    /// corner, so the "speaker" is really still playing the note and the
    /// broadband reading is dominated by that leak rather than by anything the
    /// effect did. A shallow filter is not a small speaker.
    ///
    /// A real micro-transducer is far steeper than either figure: it is a
    /// resonant system with almost no output below its resonance, and the amp
    /// in front of it usually adds a protective high-pass on top. 36 dB/oct at
    /// 100 Hz is therefore still GENEROUS to the dry signal compared with an
    /// actual phone, and it is applied identically to both sides of the A/B.
    private static let speakerPoles = 6

    /// The modelled speaker, applied to BOTH sides of the A/B.
    /// `y = a·(y₋₁ + x − x₋₁)`, cascaded.
    private func throughSpeaker(_ samples: [Float]) -> [Float] {
        var signal = samples
        let a = Self.speakerPoleCoefficient
        for _ in 0..<Self.speakerPoles {
            var previousInput = 0.0
            var previousOutput = 0.0
            for index in signal.indices {
                let x = Double(signal[index])
                let y = a * (previousOutput + x - previousInput)
                previousInput = x
                previousOutput = y
                signal[index] = Float(y)
            }
        }
        return signal
    }

    // MARK: - Measurement

    private func goertzel(_ samples: [Float], frequency: Double, in range: Range<Int>) -> Double {
        let w = 2.0 * Double.pi * frequency / Self.sampleRate
        let coeff = 2.0 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for index in range {
            let s0 = Double(samples[index]) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return max(power, 0).squareRoot() * 2.0 / Double(range.count)
    }

    private func rms(_ samples: [Float], in range: Range<Int>) -> Double {
        var sum = 0.0
        for index in range { sum += Double(samples[index]) * Double(samples[index]) }
        return (sum / Double(range.count)).squareRoot()
    }

    private func dB(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-30)) }

    /// Renders the mono program through a fresh enhancer in 512-frame quanta
    /// (quantum-boundary state continuity is part of the proof) and returns
    /// channel 0. The DRY side of the A/B is the program itself: m23-p1's
    /// `bypassedBassEnhancerIsByteIdenticalToAbsence` already pins that a chain
    /// without this effect is byte-identical to one carrying it bypassed, so
    /// "dry = the program" is a pinned fact here, not an assumption.
    private func enhanced(_ params: BassEnhancerParams, program: [Float]) throws -> [Float] {
        let effect = BassEnhancerEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        var out = [Float]()
        out.reserveCapacity(program.count)
        var offset = 0
        while offset < program.count {
            let frames = min(512, program.count - offset)
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<frames {
                data[0][frame] = program[offset + frame]
                data[1][frame] = program[offset + frame]
            }
            effect.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: frames)
            out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            offset += frames
        }
        return out
    }

    /// The A/B pair, both sides through the same modelled speaker.
    private func renderAB() throws -> (dry: [Float], wet: [Float],
                                       drySpeaker: [Float], wetSpeaker: [Float]) {
        let dry = program()
        let wet = try enhanced(
            BassEnhancerParams(crossoverHz: Self.crossoverHz, amount: 0.7, mix: 1.0),
            program: dry)
        return (dry, wet, throughSpeaker(dry), throughSpeaker(wet))
    }

    // MARK: - B1: the dry path is untouched (ADDING, not BOOSTING)

    @Test("the part's own fundamentals come through the enhancer at their own level")
    func enhancerAddsWithoutTouchingTheLowEnd() throws {
        let ab = try renderAB()
        #expect(ab.wet.allSatisfy { $0.isFinite }, "NaN/Inf guard")

        for (index, note) in Self.notes.enumerated() {
            let range = Self.window(index)
            let dryF0 = goertzel(ab.dry, frequency: note.f0, in: range)
            let wetF0 = goertzel(ab.wet, frequency: note.f0, in: range)
            let delta = dB(wetF0) - dB(dryF0)
            print("[measured] B1 note \(index) f0 \(note.f0) Hz — "
                  + "dry \(dB(dryF0)) dB, wet \(dB(wetF0)) dB, delta \(delta) dB")
            // The generated series is high-passed at the same corner the notes
            // sit BELOW, so essentially none of it lands back on the
            // fundamental. A wideband "bass boost" masquerading as this effect
            // would move these by several dB.
            #expect(abs(delta) < 0.05,
                    "note \(index) f0 moved by \(delta) dB — the dry path must be untouched")
        }
    }

    // MARK: - B2: through the speaker, dry loses / enhanced retains

    /// MEASURED 2026-07-29 and pasted, per note, in dB. Nothing in this file
    /// derives them: they are the outcome of running the fixture, and they are
    /// pinned so that a change in the DSP has to explain itself rather than
    /// slide under an inequality. The ±1.0 dB band is for cross-machine libm
    /// drift (the m22-a null-pin precedent), not slack in the claim.
    ///
    /// How much of the dry part the modelled speaker throws away:
    private static let expectedLostDb = [40.388, 36.030, 31.180]
    /// How much MORE the enhanced part still delivers through that speaker.
    /// Note the honest shape of these numbers: the retention SHRINKS as the
    /// note rises (17.1 → 14.4 → 11.4 dB), because a higher note leaks more of
    /// its own fundamental past the corner and has less to gain. The effect is
    /// worth most exactly where the speaker is worst, which is the claim.
    private static let expectedRetainedDb = [17.140, 14.440, 11.370]

    @Test("through a speaker that cannot play the notes, the enhanced part keeps energy the dry part loses")
    func speakerKeepsTheEnhancedPart() throws {
        let ab = try renderAB()

        for (index, note) in Self.notes.enumerated() {
            let range = Self.window(index)
            let dryFull = dB(rms(ab.dry, in: range))
            let dryThin = dB(rms(ab.drySpeaker, in: range))
            let wetThin = dB(rms(ab.wetSpeaker, in: range))
            print("[measured] B2 note \(index) f0 \(note.f0) Hz — dry full \(dryFull) dB, "
                  + "dry through speaker \(dryThin) dB (lost \(dryFull - dryThin)), "
                  + "enhanced through speaker \(wetThin) dB "
                  + "(retained \(wetThin - dryThin) over dry)")

            // (a) THE LOSS. The speaker throws away nearly all of the dry part.
            //     Two pins, and they fail on different mistakes: the LITERAL
            //     catches drift in either direction (a loss that grew would
            //     mean the fixture stopped resembling a small speaker), the
            //     floor states the product claim in its own right so a future
            //     re-measure cannot quietly walk it down to nothing.
            let lost = dryFull - dryThin
            #expect(abs(lost - Self.expectedLostDb[index]) < 1.0,
                    "note \(index): dry loses \(lost) dB, pinned \(Self.expectedLostDb[index])")
            #expect(lost > 28,
                    "note \(index): the speaker must actually lose the dry part (lost only \(lost) dB)")

            // (b) THE RETENTION — the headline number, same two-pin shape.
            let retained = wetThin - dryThin
            #expect(abs(retained - Self.expectedRetainedDb[index]) < 1.0,
                    "note \(index): retained \(retained) dB, pinned \(Self.expectedRetainedDb[index])")
            #expect(retained > 10,
                    "note \(index): enhanced retains only \(retained) dB over dry")
        }
    }

    // MARK: - B3: the retained partials TRACK the note

    /// MEASURED 2026-07-29 and pasted: how far the weakest partial OF THE NOTE
    /// BEING PLAYED stands above the strongest reading at any partial frequency
    /// belonging to one of the other two notes, in dB. A generator locked to a
    /// fixed frequency, or one following the crossover rather than the content,
    /// collapses these toward zero while leaving B2 green.
    private static let expectedTrackingMarginDb = [22.238, 36.045, 36.884]

    @Test("what the speaker still plays follows the note being played, not a fixed frequency")
    func retainedPartialsTrackTheNote() throws {
        let ab = try renderAB()

        for (index, note) in Self.notes.enumerated() {
            let range = Self.window(index)
            let own = [2.0, 3.0, 4.0].map { multiple in
                dB(goertzel(ab.wetSpeaker, frequency: note.f0 * multiple, in: range))
            }
            // The same partial numbers for the notes NOT being played here.
            let foreign = Self.notes.enumerated()
                .filter { $0.offset != index }
                .flatMap { other in
                    [2.0, 3.0, 4.0].map { multiple in
                        dB(goertzel(ab.wetSpeaker, frequency: other.element.f0 * multiple,
                                    in: range))
                    }
                }
            print("[measured] B3 note \(index) f0 \(note.f0) Hz — own 2f/3f/4f \(own), "
                  + "foreign \(foreign)")

            let weakestOwn = own.min() ?? -.infinity
            let strongestForeign = foreign.max() ?? .infinity
            let margin = weakestOwn - strongestForeign
            #expect(abs(margin - Self.expectedTrackingMarginDb[index]) < 1.5,
                    "note \(index): margin \(margin) dB, pinned \(Self.expectedTrackingMarginDb[index])")
            #expect(margin > 20,
                    "note \(index): own partials \(own) must stand clear of the other notes' partial frequencies \(foreign)")
        }
    }

    // MARK: - B4: anti-vacuity — the dry part has nothing there to begin with

    @Test("the dry part carries nothing at those partial frequencies — the retained energy is generated")
    func dryPartHasNoPartialsToRetain() throws {
        let ab = try renderAB()

        for (index, note) in Self.notes.enumerated() {
            let range = Self.window(index)
            for multiple in [2.0, 3.0, 4.0] {
                let f = note.f0 * multiple
                let dryLevel = dB(goertzel(ab.drySpeaker, frequency: f, in: range))
                let wetLevel = dB(goertzel(ab.wetSpeaker, frequency: f, in: range))
                print("[measured] B4 note \(index) \(f) Hz — dry \(dryLevel) dB, "
                      + "enhanced \(wetLevel) dB, gained \(wetLevel - dryLevel)")
                #expect(dryLevel < -90,
                        "note \(index) at \(f) Hz: the dry part must be silent there (measured \(dryLevel) dB)")
                // Bounded on BOTH sides: a floor alone would stay green under a
                // generator that had run away, and "more energy" is not the
                // claim — "the right energy" is. Measured span 93.4…102.6 dB.
                #expect(wetLevel - dryLevel > 50,
                        "note \(index) at \(f) Hz: only \(wetLevel - dryLevel) dB generated")
                #expect(wetLevel - dryLevel < 110,
                        "note \(index) at \(f) Hz: \(wetLevel - dryLevel) dB generated — runaway")
            }
        }
    }

    // MARK: - B5: the same A/B, as something a human can put in their ears

    /// Where the four listenable files land. `/tmp`, deliberately: the suite
    /// must never write into the user's real Application Support directory
    /// (m23-aa filed exactly that bug against four other suites), and the gate
    /// already parks its captures under `/tmp/daw-gate-out/`.
    private static let artifactDirectory = URL(
        fileURLWithPath: "/tmp/daw-gate-out/m23p2", isDirectory: true)

    /// A psychoacoustic claim — "your ear supplies the bass note it never
    /// heard" — is ultimately settled by a listener, and every other leg in
    /// this file is a number. So write the A/B out: the same program with the
    /// enhancer in and out, each pair also passed through the modelled small
    /// speaker. Play `speaker-dry` against `speaker-enhanced` on anything and
    /// the assertions above stop being a matter of trust.
    ///
    /// The two speaker files share ONE make-up gain and the two full-range
    /// files share another, both printed and carried in the filename. Per-file
    /// normalization would be a dishonest demo: it would erase the level
    /// difference that IS the result. The make-up gain exists only because a
    /// 36 dB/oct filter leaves the dry side near the noise floor of most
    /// playback chains — it is applied EQUALLY to both sides of each pair, so
    /// it moves neither toward the other. Each factor is taken from the LOUDER
    /// side of its pair (the enhanced one), which is why the dry file of a pair
    /// lands below unity rather than at it: that is the level relationship the
    /// render produced, scaled, not a level chosen for it.
    ///
    /// Measured on the written files, and worth knowing before listening:
    /// full-range the pair is −4.1 vs −1.0 dBFS peak but only 0.3 dB apart in
    /// RMS — the effect is NOT a loudness trick on a full-range system. Through
    /// the modelled speaker the same pair is 12.8 dB apart in RMS. That gap
    /// between the two pairs is the whole claim, in a form a listener can check
    /// without reading a single assertion in this file.
    ///
    /// This leg asserts what it wrote. A helper that quietly fails to produce
    /// its artifact is worse than no helper.
    @Test("the A/B is written out where a human can listen to it")
    func writesTheListenableAB() throws {
        let ab = try renderAB()
        try FileManager.default.createDirectory(
            at: Self.artifactDirectory, withIntermediateDirectories: true)

        // One factor per PAIR, from the louder side of that pair, leaving 1 dB
        // of headroom. Peak (not RMS) so nothing clips.
        func sharedGain(_ a: [Float], _ b: [Float]) -> Float {
            let peak = max(a.map { abs($0) }.max() ?? 0, b.map { abs($0) }.max() ?? 0)
            return peak > 0 ? Float(0.891 / Double(peak)) : 1
        }
        let fullGain = sharedGain(ab.dry, ab.wet)
        let speakerGain = sharedGain(ab.drySpeaker, ab.wetSpeaker)
        print("[measured] B5 make-up gain — full-range ×\(fullGain), "
              + "through the speaker ×\(speakerGain) (shared within each pair)")

        let files: [(String, [Float], Float)] = [
            ("full-dry", ab.dry, fullGain),
            ("full-enhanced", ab.wet, fullGain),
            ("speaker-dry", ab.drySpeaker, speakerGain),
            ("speaker-enhanced", ab.wetSpeaker, speakerGain),
        ]
        let suffix = String(format: "x%.0f", Double(speakerGain))
        for (name, samples, gain) in files {
            let url = Self.artifactDirectory.appendingPathComponent(
                name.hasPrefix("speaker") ? "\(name)-\(suffix).wav" : "\(name).wav")
            try? FileManager.default.removeItem(at: url)
            try write(samples.map { $0 * gain }, to: url)
            let size = try #require(
                FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            // 108 000 frames × 2 bytes ≈ 216 KB; anything much smaller means a
            // truncated or empty write dressed up as a success.
            #expect(size > 200_000, "\(url.lastPathComponent) is \(size) bytes")
            print("[artifact] \(url.path) (\(size) bytes)")
        }
    }

    /// 48 kHz mono 16-bit WAV — the format every player on the machine opens.
    private func write(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let data = try #require(buffer.floatChannelData)
        for index in samples.indices { data[0][index] = samples[index] }
        try file.write(from: buffer)
    }
}
