import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m10-n-1 sound-bank instrument path (AUSampler hosting SF2/DLS programs),
/// headless: GM programs from the system bank rendered through the SAME
/// offline graph as every other instrument (the AUHostingTests pattern —
/// zero new render-thread code, the render path IS `HostedAUInstrument`).
/// AU output is NEVER bit-exact/null-tested — assertions are windowed
/// peak/RMS plus normalized 24-band Goertzel SHAPE distances (LAW L10:
/// every number printed `[measured]`). 48 kHz stereo, 120 BPM → beat 1 =
/// frame 24 000.
@MainActor
@Suite("Sound-bank instrument hosting (m10-n-1)", .serialized)
struct SoundBankHostingTests {
    // MARK: - Fixtures

    private func soundBankTrack(program: Int, bankMSB: Int = 121,
                                source: SoundBankSource = .generalMIDI,
                                clips: [Clip] = []) -> Track {
        Track(name: "Bank", kind: .instrument, clips: clips,
              instrument: InstrumentDescriptor(
                  kind: .soundBank,
                  soundBank: SoundBankConfig(source: source, program: program,
                                             bankMSB: bankMSB)))
    }

    /// One clip at beat 0: the given pitch, v127, onset at clip-beat 1
    /// (frame 24 000), the given length. Default: sustained C4, beats 1–3.
    private func noteClip(pitch: Int = 60, lengthBeats: Double = 2) -> Clip {
        Clip(name: "midi", startBeat: 0, lengthBeats: 8, notes: [
            MIDINote(pitch: pitch, velocity: 127, startBeat: 1, lengthBeats: lengthBeats),
        ])
    }

    /// Full offline render of one track: prepare (bank load included) + 2 s
    /// pass at 48 kHz, returning the left channel. Hosted tracks must reach
    /// `.ready`; built-ins never touch the registry.
    private func renderLeft(track: Track, durationSeconds: Double = 2.0) async throws -> [Float] {
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: [track])
        if (track.instrument ?? .default).kind == .soundBank {
            #expect(renderer.auRegistry.status[track.id] == .ready)
        }
        let audio = try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                        fromBeat: 0, durationSeconds: durationSeconds)
        return audio.channelData[0]
    }

    // MARK: - Duration → seconds (m23-aw)

    /// `Duration` → `Double` seconds. Local copy of the
    /// `AUPrepareRenegotiationStressTests.secondsOf` shape — that file's own
    /// comment says test-timing scaffolding stays local to whichever file
    /// needs it rather than migrating into `DAWCore`.
    private static func secondsOf(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) * 1e-18
    }

    // MARK: - Spectral helpers (T2)

    /// Goertzel single-bin magnitude over `range` (the FXPack1 estimator,
    /// window-normalized — comparable across bands of one window).
    private func goertzelMagnitude(_ samples: [Float], frequency: Double,
                                   sampleRate: Double, in range: Range<Int>) -> Double {
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let coefficient = 2.0 * cos(omega)
        var s1 = 0.0, s2 = 0.0
        for index in range {
            let s0 = Double(samples[index]) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
        return max(0, power).squareRoot() / Double(range.count)
    }

    /// 24 log-spaced Goertzel band magnitudes (60 Hz – 8 kHz) over `range`,
    /// normalized to a unit-L2 vector (silence ⇒ the zero vector) — a
    /// level-independent spectral SHAPE.
    private func bandShape(_ samples: [Float], sampleRate: Double,
                           in range: Range<Int>) -> [Double] {
        let magnitudes = (0..<24).map { band in
            goertzelMagnitude(
                samples,
                frequency: 60.0 * pow(8_000.0 / 60.0, Double(band) / 23.0),
                sampleRate: sampleRate, in: range)
        }
        let norm = magnitudes.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return magnitudes }
        return magnitudes.map { $0 / norm }
    }

    /// Euclidean distance between two unit-normalized band vectors
    /// (0 = identical shape, 2 = maximally different).
    private func spectralDistance(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
    }

    // MARK: - T1: onset energy + prepare wall time

    @Test("T1: GM program 0 renders energy exactly at the scheduled onset")
    func gmProgramRendersEnergyAtScheduledOnset() async throws {
        let track = soundBankTrack(program: 0, clips: [noteClip()])
        let renderer = OfflineRenderer()
        let clock = ContinuousClock()
        let prepareTime = await clock.measure {
            await renderer.prepareAudioUnits(tracks: [track])
        }
        // §5.7: the GM selection-to-ready target is < ~300 ms — RECORD it.
        //
        // m23-aw: ADDITIVE ONLY — the prefix and the first value
        // (`prepareTime`) keep their exact spelling and position; m23-ab-3,
        // m23-at, m23-aw and scripts/gates/m23aw-prepare-headroom.mjs all
        // read past measurements off this prefix, and a reformat blinds the
        // gate silently. `horizon` mirrors what m23-as-2 appended to the
        // m19-e line: the record states the timeout that ACTUALLY applied
        // (`AUHostRegistry.defaultPrepareTimeout` — 60 s in a detected test
        // process, 10 s in production), so the void-clause staleness class
        // that hid this item's own finding becomes self-correcting. `margin`
        // is `horizon / prepareTime` to three decimals, printed and NEVER
        // asserted — the number a human should be able to grep out of any
        // log without doing arithmetic. The 36 s worst-of-campaign threshold
        // that DOES get asserted lives only in
        // `scripts/gates/m23aw-prepare-headroom.mjs` (§5.5 of the design —
        // one home, not one in Swift and a duplicate in JS).
        let horizon = AUHostRegistry.defaultPrepareTimeout
        let marginString = String(
            format: "%.3f", Self.secondsOf(horizon) / Self.secondsOf(prepareTime))
        print("[measured] GM bank prepare-to-ready wall time: \(prepareTime), "
              + "horizon \(horizon), margin \(marginString)")
        // m23-ab-3: a timed-out/failed prepare renders honest silence, so the
        // three onset assertions below would ALL fail as if three things
        // broke when really there is one root cause. `#require` stops here
        // with ONE diagnostic instead of three, and — unlike loosening a
        // threshold or adding a retry — still demands exactly the same
        // `.ready` outcome the old `#expect` did.
        //
        // MEASURED (10 consecutive full-suite runs, 2026-07-29; full
        // characterization in m23-ab-3): isolated (N=30) and even under
        // heavy synthetic CPU load (N=15, 20 saturating background
        // processes) this call completes in ~45–70 ms every time, zero
        // failures. Under a full ~446-suite parallel run (N=10, 2 failed)
        // the measured wall time was 20.4–23.0 s on ALL TEN runs — pass and
        // fail alike — not a threshold gradually being approached: the
        // entire distribution sits ABOVE the 10 s timeout, and elapsed time
        // does NOT predict the outcome (the FASTEST of the ten, 20.42 s,
        // failed; the SLOWEST, 22.96 s, passed). So the discriminator is not
        // "did this call get slow enough to cross 10 s" — the THEN-current
        // `raceAgainstTimeout` was two unstructured `Task { @MainActor in … }`
        // closures (the real work and a `Task.sleep(for: 10s)` backstop), and
        // which one's continuation actually got scheduled and resumed FIRST
        // was what decided ready-vs-timed-out; under full-suite load both were
        // held up by the same ~20 s of something (consistent with, but not
        // directly measured as, main-actor executor contention from the ~78%
        // of this suite's siblings that are also `@MainActor`-isolated), so
        // which one won was decided by scheduling order, not by which
        // finished "faster" in absolute time.
        //
        // ⚠️ EVERYTHING ABOVE DESCRIBES THE PRE-m23-at REGIME. It is kept
        // because the characterization of WHY this test was flaky is still
        // true — but the coin flip is GONE, and `raceAgainstTimeout` no longer
        // exists. m23-at replaced it with `DAWCore.DeadlineRace`, whose
        // deadline runs on the cooperative pool and so fires on wall time
        // instead of needing to re-acquire a contended main actor.
        //
        // Two consequences, both counter-intuitive enough to state outright:
        // (1) the prepare is no longer ABANDONED at 10 s, so it runs to
        // completion and the measured wall time ROSE — 17–22 s before the
        // policy, 24–27 s after it. (2) "raising the timeout would be the
        // wrong fix", which was correct while the deadline was a coin flip,
        // does NOT describe this code any more: the shipped wall is still
        // 10 s, but a detected test process deliberately gets the higher
        // `AUHostRegistry.testPrepareTimeout` (m23-at Phase B, pinned by
        // `AUPrepareTimeoutPolicyTests` so the SHIPPED value cannot drift).
        // What needs watching now is the MARGIN between the measured prepare
        // and that test-time wall — see m23-aw.
        let status = renderer.auRegistry.status[track.id]
        try #require(status == .ready, """
            AU prepare did not reach .ready (status: \(String(describing: status))) \
            after \(prepareTime) (target ~300 ms, effective wall \
            \(AUHostRegistry.defaultPrepareTimeout)) — the render below \
            is silent by construction, so the onset assertions would read as three \
            failures instead of one. See m23-ab-3: main-actor scheduling contention \
            under full-suite parallel load, not an AU/driver stall.
            """)

        let audio = try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                        fromBeat: 0, durationSeconds: 3.0)
        let left = audio.channelData[0]
        let prePeak = TestSignals.peak(left, in: 0..<24_000)
        let bodyRMS = TestSignals.rms(left, in: 24_000..<28_800)
        let preOnsetRMS = TestSignals.rms(left, in: 23_488..<24_000)
        let postOnsetRMS = TestSignals.rms(left, in: 24_000..<24_512)
        print("[measured] gm p0 pre-peak \(prePeak), body RMS[24000,28800] \(bodyRMS), "
              + "onset edge RMS \(preOnsetRMS) → \(postOnsetRMS)")
        #expect(prePeak < 1e-4)          // silent before the scheduled onset
        #expect(bodyRMS > 0.005)         // audible note body
        #expect(preOnsetRMS < 1e-4)      // onset lands AT frame 24000 …
        #expect(postOnsetRMS > 1e-3)     // … not before, not much after
    }

    // MARK: - T2: the SPECTRAL GATE (roadmap-facing proof)

    @Test("T2 SPECTRAL GATE: built-in polySynth vs GM piano vs GM trumpet — distinct timbres, one bank")
    func spectralProofAcrossInstruments() async throws {
        // The same 2-bar MIDI (sustained C4, beats 1–3) through three
        // instruments; program addressing is what separates gm0 from gm56.
        let polyTrack = Track(name: "Poly", kind: .instrument, clips: [noteClip()],
                              instrument: InstrumentDescriptor(kind: .polySynth))
        let poly = try await renderLeft(track: polyTrack)
        let gm0 = try await renderLeft(track: soundBankTrack(program: 0, clips: [noteClip()]))
        let gm56 = try await renderLeft(track: soundBankTrack(program: 56, clips: [noteClip()]))

        // Body energy: every render is audibly non-silent.
        let rmsWindow = 24_000..<48_000
        for (name, samples) in [("polySynth", poly), ("gm0 piano", gm0), ("gm56 trumpet", gm56)] {
            let bodyRMS = TestSignals.rms(samples, in: rmsWindow)
            print("[measured] \(name) body RMS[24000,48000] \(bodyRMS)")
            #expect(bodyRMS > 0.005)
        }

        // Spectral shape: 24 log-spaced Goertzel bands over the note body,
        // unit-L2 normalized, pairwise Euclidean distance.
        let shapeWindow = 26_400..<69_600
        let polyShape = bandShape(poly, sampleRate: 48_000, in: shapeWindow)
        let gm0Shape = bandShape(gm0, sampleRate: 48_000, in: shapeWindow)
        let gm56Shape = bandShape(gm56, sampleRate: 48_000, in: shapeWindow)
        let dPolyGm0 = spectralDistance(polyShape, gm0Shape)
        let dGm0Gm56 = spectralDistance(gm0Shape, gm56Shape)
        print("[measured] 24-band spectral distance d(polySynth, gm0) = \(dPolyGm0)")
        print("[measured] 24-band spectral distance d(gm0, gm56) = \(dGm0Gm56)")
        #expect(dPolyGm0 > 0.25)  // non-built-in timbre
        #expect(dGm0Gm56 > 0.25)  // program addressing works
    }

    // MARK: - T3: percussion addressing (bankMSB 0x78)

    @Test("T3: the drum kit (bankMSB 120) renders a snare onset")
    func percussionBankRendersSnareOnset() async throws {
        let track = soundBankTrack(program: 0, bankMSB: 120,
                                   clips: [noteClip(pitch: 38, lengthBeats: 1)])
        let left = try await renderLeft(track: track)
        let prePeak = TestSignals.peak(left, in: 0..<24_000)
        let bodyRMS = TestSignals.rms(left, in: 24_000..<28_800)
        print("[measured] drum kit (120/0, pitch 38) pre-peak \(prePeak), "
              + "onset RMS[24000,28800] \(bodyRMS)")
        #expect(prePeak < 1e-4)
        #expect(bodyRMS > 0.005)
    }

    // MARK: - T4: idempotency + program swap

    @Test("T4: same-address re-prepare is a no-op; a program change swaps the instance")
    func idempotencyAndProgramSwap() async throws {
        let registry = AUHostRegistry()
        var track = soundBankTrack(program: 0)
        await registry.prepare(track: track, sampleRate: 48_000)
        #expect(registry.status[track.id] == .ready)
        let first = try #require(registry.preparedInstrument(forTrack: track.id))

        // Same address — even under a cosmetic rename (LAW L8) — needs no
        // prepare and keeps the SAME live instance.
        track.instrument?.soundBank?.displayName = "Renamed Piano"
        #expect(!registry.needsPrepare(track: track, sampleRate: 48_000))
        await registry.prepare(track: track, sampleRate: 48_000)
        let second = try #require(registry.preparedInstrument(forTrack: track.id))
        #expect(first === second)

        // A program change IS structural: re-prepare lands a fresh, ready
        // instance (the release→prepare→reconcile swap machinery's registry
        // half; the graph half is keyed by the same Address — §5.4/§5.7).
        track.instrument?.soundBank?.program = 56
        #expect(registry.needsPrepare(track: track, sampleRate: 48_000))
        await registry.prepare(track: track, sampleRate: 48_000)
        #expect(registry.status[track.id] == .ready)
        let third = try #require(registry.preparedInstrument(forTrack: track.id))
        #expect(third !== first)
    }

    // MARK: - T5: missing-file honesty (LAW L5)

    @Test("T5: a missing bank file fails honestly and renders exact silence — never a fallback timbre")
    func missingBankFailsHonestlyAndRendersSilence() async throws {
        let track = soundBankTrack(program: 0,
                                   source: .file(path: "/nonexistent/missing-bank.sf2"),
                                   clips: [noteClip()])
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: [track])
        guard case .failed(let reason)? = renderer.auRegistry.status[track.id] else {
            Issue.record("expected .failed, got \(String(describing: renderer.auRegistry.status[track.id]))")
            return
        }
        print("[measured] missing-bank failure reason: \(reason)")
        #expect(reason.contains("no sound bank file at /nonexistent/missing-bank.sf2"))
        #expect(renderer.auRegistry.preparedInstrument(forTrack: track.id) == nil)

        // The render must not throw — and must be EXACT silence (zeros).
        let audio = try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                        fromBeat: 0, durationSeconds: 1.0)
        for channel in audio.channelData {
            #expect(TestSignals.peak(channel, in: 0..<channel.count) == 0)
        }
    }

    // MARK: - T6: rate-renegotiation survival (§5.8 / R7)

    @Test("T6: a loaded bank survives rate renegotiation 48 kHz → 44.1 kHz (not the default preset)")
    func loadedBankSurvivesRateRenegotiation() async throws {
        // Bank-loaded sampler, prepared at 48 kHz then renegotiated to 44.1.
        let registry = AUHostRegistry()
        let track = soundBankTrack(program: 0)
        await registry.prepare(track: track, sampleRate: 48_000)
        #expect(registry.status[track.id] == .ready)
        let instrument = try #require(registry.preparedInstrument(forTrack: track.id))
        instrument.prepare(sampleRate: 44_100, maxFramesPerQuantum: 4_096, channelCount: 2)

        // Reference discriminator: a FRESH AUSampler with NO bank loaded at
        // 44.1 kHz — its factory-default preset (a plain sine) is exactly
        // what a lost bank would degrade to, so "energy alone" cannot
        // false-pass this gate.
        let defaultRegistry = AUHostRegistry()
        let defaultTrack = Track(
            name: "Default", kind: .instrument,
            instrument: InstrumentDescriptor(
                kind: .audioUnit,
                audioUnit: AudioUnitConfig(component: AudioUnitComponentID(
                    subType: "samp", manufacturer: "appl"))))
        await defaultRegistry.prepare(track: defaultTrack, sampleRate: 44_100)
        #expect(defaultRegistry.status[defaultTrack.id] == .ready)
        let defaultSampler = try #require(
            defaultRegistry.preparedInstrument(forTrack: defaultTrack.id))

        // Render ~0.56 s (6 × 4096 quanta) from each: noteOn C4 v127 at frame 0.
        func renderQuanta(_ subject: HostedAUInstrument) throws -> [Float] {
            let quantum = 4_096
            let format = try #require(AVAudioFormat(
                standardFormatWithSampleRate: 44_100, channels: 2))
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
            buffer.frameLength = AVAudioFrameCount(quantum)
            let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            var samples: [Float] = []
            for index in 0..<6 {
                let events = index == 0 ? [ScheduledMIDIEvent(
                    sampleTime: 0, noteID: 0, kind: ScheduledMIDIEvent.noteOn,
                    pitch: 60, velocity: 127)] : []
                events.withUnsafeBufferPointer { slice in
                    subject.render(events: slice, renderStart: Int64(index * quantum),
                                   frameCount: quantum, output: output)
                }
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: buffer.floatChannelData![0], count: quantum))
            }
            return samples
        }

        let renegotiated = try renderQuanta(instrument)
        let factoryDefault = try renderQuanta(defaultSampler)

        // Discriminator: 2nd-harmonic / fundamental energy ratio at C4. A
        // pure sine (the factory default preset — what a LOST bank degrades
        // to, measured before the R7 hook landed) has essentially none; the
        // GM piano has plenty. Sharper than a whole-band shape distance,
        // whose fundamental-heavy window measured only 0.09 here (L10:
        // thresholds tuned against printed reality).
        let energyWindow = 2_000..<24_000
        func harmonicRatio(_ samples: [Float]) -> Double {
            let fundamental = goertzelMagnitude(samples, frequency: 261.626,
                                                sampleRate: 44_100, in: energyWindow)
            let second = goertzelMagnitude(samples, frequency: 523.251,
                                           sampleRate: 44_100, in: energyWindow)
            return fundamental > 0 ? second / fundamental : 0
        }
        let renegotiatedRMS = TestSignals.rms(renegotiated, in: energyWindow)
        let defaultRMS = TestSignals.rms(factoryDefault, in: energyWindow)
        let renegotiatedRatio = harmonicRatio(renegotiated)
        let defaultRatio = harmonicRatio(factoryDefault)
        let distance = spectralDistance(
            bandShape(renegotiated, sampleRate: 44_100, in: energyWindow),
            bandShape(factoryDefault, sampleRate: 44_100, in: energyWindow))
        print("[measured] post-renegotiation RMS \(renegotiatedRMS), "
              + "factory-default-preset RMS \(defaultRMS), "
              + "24-band distance piano-vs-default \(distance)")
        print("[measured] h2/h1 harmonic ratio: renegotiated \(renegotiatedRatio), "
              + "factory-default \(defaultRatio)")
        #expect(renegotiatedRMS > 1e-3)             // still renders energy at 44.1 kHz
        #expect(renegotiatedRatio > 0.1)            // harmonically rich — the PIANO …
        #expect(defaultRatio < 0.02)                // … while the default preset is a bare sine
    }

    // MARK: - T-extra (R3): record, don't assert

    @Test("T-extra: out-of-bank address (bankMSB 5) behavior is measured and recorded")
    func outOfBankAddressBehaviorRecorded() async throws {
        let track = soundBankTrack(program: 0, bankMSB: 5, clips: [noteClip()])
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: [track])
        let status = renderer.auRegistry.status[track.id]
        print("[measured] bankMSB 5 (absent from the GM bank): prepare status = "
              + String(describing: status))
        // Whatever the load did, the surface stays honest: either .failed +
        // silence, or .ready and the render is the truth. Record which.
        if renderer.auRegistry.preparedInstrument(forTrack: track.id) != nil {
            let audio = try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                            fromBeat: 0, durationSeconds: 2.0)
            let bodyRMS = TestSignals.rms(audio.channelData[0], in: 24_000..<72_000)
            print("[measured] bankMSB 5 render body RMS = \(bodyRMS) "
                  + "(ready-but-silent vs failed — recorded for R3)")
        }
    }
}
