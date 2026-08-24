import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m25-n — DOES PDC ACTUALLY WORK FOR A HOSTED AUDIO UNIT INSERT?
///
/// The engine reads `au.latency` at prepare (`HostedAUEffect.swift:63`) and
/// feeds it through `EffectChainState.latencySamples` →
/// `PlaybackGraph.recomputeCompensation` → per-strip compensation rings.
/// `HostedAUEffect` is the ONLY `EffectRendering` that ever reports non-zero
/// latency for an Apple built-in insert, so this is exactly the PDC path.
/// Nothing pinned it end to end; this suite does.
///
/// RIG (each render carries exactly ONE audible strip, so a plain argmax is
/// an unambiguous onset — no thresholding, no peak-pairing, no pan bleed):
///   • one impulse fixture, amplitude 0.5 at frame 4800;
///   • strip A = dry, strip B = the same impulse with a hosted AU insert;
///   • the strip we are NOT measuring is present in the project (so the PDC
///     planner sees its chain latency) but at `volume: 0` (so it contributes
///     nothing to the samples we argmax over).
///
/// Four numbers per unit, all measured, never assumed:
///   reported   = `HostedAUEffect.latencySamples`, what PDC is told;
///   actual     = B's onset − A's onset with the rings FORCED to zero
///                (`compensationTargets = [:]`), what the AU really does;
///   compA      = where A lands under plan-driven PDC, minus 4800;
///   alignment  = B's PDC onset − A's PDC onset. THE ANSWER. 0 = PDC works.
///
/// NOT `@MainActor` at the suite level (the tree is at its 330-suite cadence
/// cap); the per-test isolation is on the functions.
@Suite("PDC — hosted Audio Unit insert", .serialized)
struct PDCHostedAURenderTests {
    private static let sampleRate = 48_000.0
    private static let impulseFrame = 4_800
    private static let impulseAmplitude: Float = 0.5
    private static let renderSeconds = 0.6

    /// AULowpass — NEGATIVE CONTROL. Reports 0 samples, so a correct rig must
    /// already show alignment 0 with PDC on AND with PDC off.
    private static let lowpass = AudioUnitComponentID(
        type: "aufx", subType: "lpas", manufacturer: "appl")
    /// AUPeakLimiter — small, honest lookahead (~51 samples @ 48 k).
    private static let peakLimiter = AudioUnitComponentID(
        type: "aufx", subType: "lmtr", manufacturer: "appl")
    /// AUDynamicsProcessor — ~211 samples of lookahead.
    private static let dynamics = AudioUnitComponentID(
        type: "aufx", subType: "dcmp", manufacturer: "appl")
    /// AUMultibandCompressor — ~212 samples.
    private static let multiband = AudioUnitComponentID(
        type: "aufx", subType: "mcmp", manufacturer: "appl")
    /// AUNewTimePitch — the big one, ~4051 samples (~84 ms), grossly audible.
    private static let newTimePitch = AudioUnitComponentID(
        type: "aufx", subType: "nutp", manufacturer: "appl")

    /// Every unit the survey measures, in reported-latency order.
    private static let allCandidates: [(String, AudioUnitComponentID)] = [
        ("AULowpass", lowpass),
        ("AUPeakLimiter", peakLimiter),
        ("AUDynamicsProcessor", dynamics),
        ("AUMultibandCompressor", multiband),
        ("AUNewTimePitch", newTimePitch),
    ]

    /// The units that declare a NON-ZERO fixed latency — the ones PDC exists
    /// for. Membership is re-asserted at runtime (`reported > 0`), never
    /// assumed from this list.
    private static let latentCandidates: [(String, AudioUnitComponentID)] = [
        ("AUPeakLimiter", peakLimiter),
        ("AUDynamicsProcessor", dynamics),
        ("AUMultibandCompressor", multiband),
        ("AUNewTimePitch", newTimePitch),
    ]

    // MARK: - Fixture

    @MainActor private static var cachedImpulse: URL?

    @MainActor
    private func impulseFixture() throws -> URL {
        if let cached = Self.cachedImpulse { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m25n-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("impulse.wav")

        let frames = Int(Self.sampleRate)  // 1.0 s
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.sampleRate, channels: 2,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else {
            throw EngineError.renderFailed("fixture buffer allocation failed")
        }
        for frame in 0..<frames {
            channels[0][frame] = 0
            channels[1][frame] = 0
        }
        channels[0][Self.impulseFrame] = Self.impulseAmplitude
        channels[1][Self.impulseFrame] = Self.impulseAmplitude
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
        Self.cachedImpulse = url
        return url
    }

    // MARK: - Helpers

    private func track(id: UUID, clip url: URL, volume: Double,
                       effects: [EffectDescriptor]) -> Track {
        Track(id: id, name: "S", kind: .audio, volume: volume,
              clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4, audioFileURL: url)],
              effects: effects)
    }

    /// (frame of the largest |sample|, that magnitude) over channel 0.
    private func onset(_ audio: RenderedAudio) -> (frame: Int, peak: Float) {
        let channel = audio.channelData[0]
        var bestFrame = 0
        var bestValue: Float = 0
        for frame in channel.indices where abs(channel[frame]) > bestValue {
            bestValue = abs(channel[frame])
            bestFrame = frame
        }
        return (bestFrame, bestValue)
    }

    private func db(_ amplitude: Float) -> Double {
        amplitude <= 0 ? -.infinity : 20 * log10(Double(amplitude))
    }

    /// One measurement pass over a single component. `targets` nil = the
    /// always-on plan-driven PDC the live engine runs; `[:]` = every ring
    /// forced to zero, the uncompensated baseline.
    private struct Measurement {
        let reported: Int
        let dryOnset: Int
        let dryPeak: Float
        let wetOnsetNoPDC: Int
        let wetPeakNoPDC: Float
        let dryOnsetPDC: Int
        let dryPeakPDC: Float
        let wetOnsetPDC: Int
        let wetPeakPDC: Float
        /// What the AU really delays the transient by (rings off).
        var actualDelay: Int { wetOnsetNoPDC - dryOnset }
        /// How far PDC pushed the DRY strip back.
        var compensationApplied: Int { dryOnsetPDC - dryOnset }
        /// THE ANSWER: 0 = the two strips line up under PDC.
        var alignmentError: Int { wetOnsetPDC - dryOnsetPDC }
    }

    @MainActor
    private func measure(_ component: AudioUnitComponentID,
                         label: String) async throws -> Measurement {
        let clip = try impulseFixture()
        let dryID = UUID()
        let wetID = UUID()
        let effectID = UUID()
        let config = AudioUnitConfig(component: component)
        let insert = EffectDescriptor(id: effectID, kind: .audioUnit, audioUnit: config)

        // Two projects that differ ONLY in which strip is audible. Both carry
        // the same two strips, so both see the same PDC plan.
        func project(audible: UUID) -> [Track] {
            [track(id: dryID, clip: clip, volume: audible == dryID ? 1 : 0, effects: []),
             track(id: wetID, clip: clip, volume: audible == wetID ? 1 : 0, effects: [insert])]
        }

        func render(_ tracks: [Track], targets: [UUID: Int]?) async throws -> RenderedAudio {
            let renderer = OfflineRenderer()
            await renderer.prepareAudioUnits(tracks: tracks)
            let status = renderer.auRegistry.effectStatus[effectID]
            guard status == .ready else {
                throw EngineError.renderFailed("\(label) failed to prepare: \(String(describing: status))")
            }
            renderer.compensationTargets = targets
            return try renderer.render(tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
                                       fromBeat: 0, durationSeconds: Self.renderSeconds)
        }

        // The reported figure PDC is driven by, read off a real prepared unit.
        let probe = OfflineRenderer()
        await probe.prepareAudioUnits(tracks: project(audible: wetID))
        let hosted = try #require(probe.auRegistry.preparedEffect(forEffect: effectID),
                                  "\(label) did not prepare")
        let reported = hosted.latencySamples

        let dryRaw = onset(try await render(project(audible: dryID), targets: [:]))
        let wetRaw = onset(try await render(project(audible: wetID), targets: [:]))
        let dryPDC = onset(try await render(project(audible: dryID), targets: nil))
        let wetPDC = onset(try await render(project(audible: wetID), targets: nil))

        return Measurement(reported: reported,
                           dryOnset: dryRaw.frame, dryPeak: dryRaw.peak,
                           wetOnsetNoPDC: wetRaw.frame, wetPeakNoPDC: wetRaw.peak,
                           dryOnsetPDC: dryPDC.frame, dryPeakPDC: dryPDC.peak,
                           wetOnsetPDC: wetPDC.frame, wetPeakPDC: wetPDC.peak)
    }

    private func report(_ label: String, _ m: Measurement) {
        print("""
            [measured] m25-n \(label): reported latencySamples \(m.reported) \
            | dry onset \(m.dryOnset) (peak \(m.dryPeak), \(db(m.dryPeak)) dBFS) \
            | wet onset PDC-OFF \(m.wetOnsetNoPDC) (peak \(m.wetPeakNoPDC), \(db(m.wetPeakNoPDC)) dBFS) \
            → ACTUAL delay \(m.actualDelay) samples \
            | dry onset PDC-ON \(m.dryOnsetPDC) → compensation applied \(m.compensationApplied) \
            | wet onset PDC-ON \(m.wetOnsetPDC) (peak \(m.wetPeakPDC)) \
            → ALIGNMENT ERROR \(m.alignmentError) samples
            """)
    }

    // MARK: - Leg 1 — POSITIVE CONTROL + the survey

    /// ⭐ THE STEP WHOSE ABSENCE WASTED THE PREVIOUS ATTEMPT (which reported
    /// `leadVsMid = -Infinity dB`, `tailPeak = 0` — a SILENT render is not a
    /// PDC measurement, it is no measurement at all). Every render this suite
    /// interprets is proved non-silent here first, with real numbers.
    @MainActor
    @Test("POSITIVE CONTROL + SURVEY: every render makes signal; dry onset is exactly the impulse frame")
    func surveyCandidateUnits() async throws {
        for (label, component) in Self.allCandidates {
            let m = try await measure(component, label: label)
            report(label, m)
            // The probe made signal, at full scale, where the fixture put it.
            #expect(m.dryPeak > 0.4, "\(label): dry render was silent/quiet — the probe is broken")
            #expect(m.dryOnset == Self.impulseFrame,
                    "\(label): dry onset \(m.dryOnset) != fixture frame \(Self.impulseFrame) — rig error")
            #expect(m.dryPeakPDC > 0.4, "\(label): compensated dry render was silent — the probe is broken")
            // The AU passed audible signal too (AULowpass attenuates an
            // impulse hard — hence the looser floor).
            #expect(m.wetPeakNoPDC > 0.05, "\(label): AU render was silent — the probe is broken")
            #expect(m.wetPeakPDC > 0.05, "\(label): compensated AU render was silent — the probe is broken")
        }
    }

    // MARK: - Leg 2 — THE PIN

    /// For every Apple insert that declares a non-zero fixed latency:
    ///   • the AU really delays the transient by exactly what it reports
    ///     (`actual == reported`) — so a later mismatch is diagnosed as the
    ///     UNIT lying, never as PDC breaking;
    ///   • PDC pushes the dry strip back by exactly that amount;
    ///   • the two strips land on the SAME output frame;
    ///   • TEETH: with the rings forced to zero the same rig shows the FULL
    ///     misalignment. Without this leg the green above is unfalsifiable.
    @MainActor
    @Test("THE PIN: a latent hosted AU insert is compensated to sample-exact alignment")
    func latentHostedAUInsertsAreCompensatedExactly() async throws {
        for (label, component) in Self.latentCandidates {
            let m = try await measure(component, label: label)
            report(label, m)
            #expect(m.reported > 0, "\(label): expected a latent unit, got \(m.reported) samples")
            #expect(m.actualDelay == m.reported, """
                \(label): the AU DELAYS the transient by \(m.actualDelay) samples but REPORTS \
                \(m.reported). PDC compensates by the reported figure, so this is the unit \
                misreporting its own latency, not the compensation path failing.
                """)
            #expect(m.compensationApplied == m.reported, """
                \(label): plan-driven PDC moved the dry strip by \(m.compensationApplied) samples, \
                expected \(m.reported) (the insert's reported latency). The hosted-AU latency is not \
                reaching PlaybackGraph.recomputeCompensation.
                """)
            #expect(m.alignmentError == 0, """
                \(label): PDC left the strips \(m.alignmentError) samples apart (dry at \
                \(m.dryOnsetPDC), AU at \(m.wetOnsetPDC)). PDC IS BROKEN for hosted AU inserts.
                """)
            // TEETH: prove the rig can see a failure.
            #expect(m.wetOnsetNoPDC - m.dryOnset == m.reported, """
                \(label): with compensation forced OFF the strips should be \(m.reported) samples \
                apart, measured \(m.wetOnsetNoPDC - m.dryOnset). If this is 0 the rig cannot see \
                misalignment and the pass above proves nothing.
                """)
        }
    }

    // MARK: - Leg 3 — NEGATIVE CONTROL

    /// AULowpass declares 0 samples: PDC must do NOTHING, and the onsets must
    /// already agree without it. Measured caveat, deliberately tolerated: the
    /// filter's own minimum-phase GROUP DELAY moves the argmax of an impulse
    /// by ~2 samples (and drops its peak to ≈0.214). Group delay is not fixed
    /// algorithmic latency, no AU reports it, and no PDC scheme corrects it —
    /// so the tolerance here is 4 samples, and the load-bearing assertions are
    /// that the reported figure is 0 and that PDC-on and PDC-off are IDENTICAL.
    @MainActor
    @Test("NEGATIVE CONTROL: a 0-latency hosted AU (AULowpass) gets no compensation at all")
    func zeroLatencyHostedAUGetsNoCompensation() async throws {
        let m = try await measure(Self.lowpass, label: "AULowpass")
        report("AULowpass", m)
        #expect(m.reported == 0, "AULowpass reported \(m.reported) samples — expected 0")
        #expect(m.compensationApplied == 0,
                "PDC moved the dry strip \(m.compensationApplied) samples for a 0-latency insert")
        // PDC changed nothing anywhere: on and off are the same render position.
        #expect(m.dryOnsetPDC == m.dryOnset)
        #expect(m.wetOnsetPDC == m.wetOnsetNoPDC)
        #expect(abs(m.alignmentError) <= 4, """
            AULowpass onsets are \(m.alignmentError) samples apart, beyond the 4-sample \
            group-delay allowance. The MEASUREMENT RIG is wrong, not PDC.
            """)
    }

    // MARK: - Leg 4 — the audible consequence, in the mix

    /// The same fact at mix level, with BOTH strips audible: PDC turns two
    /// separated ~0.5 transients into ONE coherent ~1.0 transient. Uses
    /// AUNewTimePitch (4096 samples ≈ 85 ms — grossly audible flam), whose
    /// impulse response measured essentially non-smearing here (peak 0.49999997
    /// vs the 0.5 input), so onset detection is unambiguous.
    @MainActor
    @Test("IN THE MIX: PDC turns a ~85 ms flam into one coherent transient")
    func compensatedMixSumsCoherently() async throws {
        let clip = try impulseFixture()
        let dryID = UUID()
        let wetID = UUID()
        let effectID = UUID()
        let insert = EffectDescriptor(id: effectID, kind: .audioUnit,
                                      audioUnit: AudioUnitConfig(component: Self.newTimePitch))
        let tracks = [
            track(id: dryID, clip: clip, volume: 1, effects: []),
            track(id: wetID, clip: clip, volume: 1, effects: [insert]),
        ]

        let uncompensated = try await renderProject(tracks, effectID: effectID, targets: [:])
        let compensated = try await renderProject(tracks, effectID: effectID, targets: nil)

        let reported = try #require(uncompensated.reportedLatency)
        let late = Self.impulseFrame + reported

        let rawEarly = abs(uncompensated.audio.channelData[0][Self.impulseFrame])
        let rawLate = abs(uncompensated.audio.channelData[0][late])
        let pdcEarly = abs(compensated.audio.channelData[0][Self.impulseFrame])
        let pdcLate = abs(compensated.audio.channelData[0][late])
        print("""
            [measured] m25-n mix @ AUNewTimePitch (\(reported) samples): \
            PDC-OFF frame \(Self.impulseFrame) = \(rawEarly), frame \(late) = \(rawLate) (a flam) \
            | PDC-ON frame \(Self.impulseFrame) = \(pdcEarly), frame \(late) = \(pdcLate) (coherent sum)
            """)

        // PDC OFF: two separate half-scale transients, ~85 ms apart.
        #expect(rawEarly > 0.4 && rawEarly < 0.6)
        #expect(rawLate > 0.4 && rawLate < 0.6)
        // PDC ON: nothing at the early position, a doubled transient at the late one.
        #expect(pdcEarly < 0.05, "uncompensated dry transient still leads by \(reported) samples")
        #expect(pdcLate > 0.9, "the compensated strips did not sum coherently (\(pdcLate))")
    }

    // MARK: - Mix-level render helper

    private struct ProjectRender {
        let audio: RenderedAudio
        let reportedLatency: Int?
    }

    @MainActor
    private func renderProject(_ tracks: [Track], effectID: UUID,
                               targets: [UUID: Int]?) async throws -> ProjectRender {
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: tracks)
        guard renderer.auRegistry.effectStatus[effectID] == .ready else {
            throw EngineError.renderFailed(
                "insert not ready: \(String(describing: renderer.auRegistry.effectStatus[effectID]))")
        }
        let reported = renderer.auRegistry.preparedEffect(forEffect: effectID)?.latencySamples
        renderer.compensationTargets = targets
        let audio = try renderer.render(tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
                                        fromBeat: 0, durationSeconds: Self.renderSeconds)
        return ProjectRender(audio: audio, reportedLatency: reported)
    }
}
