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
    ///
    /// `blockFrames` (m28-bug) exists so a test can pin a measurement to the
    /// block it was TAKEN at. Most callers want the shipping default; T5 must
    /// name 4096 explicitly, because what it documents is a property of that
    /// block and re-pointing it at whatever ships would leave it asserting
    /// nothing while still looking like a measurement.
    private func renderLeft(track: Track, durationSeconds: Double = 2.0,
                            blockFrames: Int = RenderBlockSize.offlineFrames) async throws -> [Float] {
        let renderer = OfflineRenderer(maximumFrameCount: blockFrames)
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

    // MARK: - T5 (breath-pad P5): does CC 11 share bend's block quantisation?

    /// `measure-gm-sax-cc.md` §2.3a measured the block sample-and-hold **for
    /// pitch bend only**, and §2.4 states the mechanism as "AUSampler computes
    /// pitch per sample and merely reads its MIDI *inputs* per block". Whether
    /// that covers CC 11 was DERIVED, never measured — and breath-pad P5 was
    /// about to lean on it (deliver tremor amplitude-side, on the theory that
    /// the CC lane is finer than the bend lane). This measures it.
    ///
    /// Method: one sustained sax note carrying a CC 11 lane that is a SINE at
    /// `rateHz`, authored at 200 points/second so our own lane is nowhere near
    /// the limit. Render offline, take a short-time RMS envelope, mean-subtract
    /// it, and Goertzel the envelope at the commanded rate and at the
    /// sample-and-hold image `|11.719 − rateHz|`. The built-in `.sampler` is
    /// the negative control on the same lane, same clip, same analysis.
    private func expressionSine(rateHz: Double, bpm: Double = 120,
                                startBeat: Double, lengthBeats: Double,
                                pointsPerSecond: Double = 200,
                                centre: Int = 84, amplitude: Double = 43)
        -> MIDIControllerLane {
        let secondsPerBeat = 60.0 / bpm
        let durationSeconds = lengthBeats * secondsPerBeat
        let count = Int((durationSeconds * pointsPerSecond).rounded())
        let points = (0...count).map { i -> MIDIControllerPoint in
            let t = Double(i) / pointsPerSecond
            let value = Double(centre) + amplitude * sin(2 * .pi * rateHz * t)
            return MIDIControllerPoint(beat: startBeat + t / secondsPerBeat,
                                       value: Int(value.rounded()))
        }
        return MIDIControllerLane(type: .cc(controller: 11), points: points)
    }

    /// Short-time RMS envelope of `samples` over `range`, one value per `hop`
    /// frames. The envelope's own sample rate is `sampleRate / hop`.
    private func rmsEnvelope(_ samples: [Float], in range: Range<Int>,
                             hop: Int = 256) -> [Float] {
        var out: [Float] = []
        var i = range.lowerBound
        while i + hop <= range.upperBound {
            var sum = 0.0
            for j in i..<(i + hop) { sum += Double(samples[j]) * Double(samples[j]) }
            out.append(Float((sum / Double(hop)).squareRoot()))
            i += hop
        }
        return out
    }

    /// Goertzel magnitude of a mean-subtracted envelope — the DC term of an
    /// amplitude envelope is enormous and would leak into every bin.
    private func envelopeMagnitude(_ envelope: [Float], frequency: Double,
                                   sampleRate: Double) -> Double {
        guard !envelope.isEmpty else { return 0 }
        let mean = envelope.reduce(0.0) { $0 + Double($1) } / Double(envelope.count)
        let centred = envelope.map { Float(Double($0) - mean) }
        return goertzelMagnitude(centred, frequency: frequency,
                                 sampleRate: sampleRate, in: 0..<centred.count)
    }

    /// A 4 s, 440 Hz mono sine written once per run — the built-in `.sampler`
    /// needs a zone to sound at all, and the negative control has to sound.
    private static var cachedSineFixture: URL?
    private func sineFixture() throws -> URL {
        if let cached = Self.cachedSineFixture { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-p5-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sine440_4s_mono.wav")
        let fileRate = 48_000.0
        let frames = Int(fileRate * 4)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fileRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: fileRate, channels: 1,
                                                interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(frames)))
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<frames {
            data[0][frame] = Float(0.5 * sin(2.0 * .pi * 440.0 * Double(frame) / fileRate))
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
        Self.cachedSineFixture = url
        return url
    }

    private func clip(withLane lane: MIDIControllerLane?) -> Clip {
        Clip(name: "midi", startBeat: 0, lengthBeats: 8,
             notes: [MIDINote(pitch: 69, velocity: 100, startBeat: 1, lengthBeats: 5)],
             controllerLanes: lane.map { [$0] } ?? [])
    }

    @Test("T5 (P5/m28-bug): CC 11 is block-sampled at 4096, and clean at the shipping block")
    func expressionSharesTheBlockRateOnHostedAUs() async throws {
        let sampleRate = 48_000.0
        let hop = 256
        let envelopeRate = sampleRate / Double(hop)          // 187.5 Hz
        let blockRate = 48_000.0 / 4_096.0                   // 11.71875 Hz
        // Analysis window: 0.4 s after onset (past the attack) to 2.4 s.
        let window = 24_000 + Int(0.4 * sampleRate)..<24_000 + Int(2.4 * sampleRate)

        func bins(_ audio: [Float], rate: Double) -> (rate: Double, image: Double) {
            let envelope = rmsEnvelope(audio, in: window, hop: hop)
            return (envelopeMagnitude(envelope, frequency: rate, sampleRate: envelopeRate),
                    envelopeMagnitude(envelope, frequency: abs(blockRate - rate),
                                      sampleRate: envelopeRate))
        }

        // --- The discriminator: 8 Hz on the hosted AU ------------------------
        // 8 Hz is above the 5.86 Hz Nyquist, so a sample-and-hold puts its
        // image at 3.719 Hz — BELOW the commanded rate. A lowpass, a smoother
        // or a slew limiter CANNOT manufacture energy down there; only
        // re-sampling can.
        let hostedAt8 = bins(
            try await renderLeft(track: soundBankTrack(
                program: 65, clips: [clip(withLane: expressionSine(rateHz: 8, startBeat: 1,
                                                                   lengthBeats: 5))]),
                                 durationSeconds: 4.0, blockFrames: 4_096),
            rate: 8)
        // Same path, a rate BELOW Nyquist: the commanded rate must dominate.
        let hostedAt2 = bins(
            try await renderLeft(track: soundBankTrack(
                program: 65, clips: [clip(withLane: expressionSine(rateHz: 2, startBeat: 1,
                                                                   lengthBeats: 5))]),
                                 durationSeconds: 4.0, blockFrames: 4_096),
            rate: 2)
        // The BOTTOM of §10.1's 4–8 Hz physiological band, measured rather
        // than derived: P5 has to say whether ANY of that band survives here.
        let hostedAt4 = bins(
            try await renderLeft(track: soundBankTrack(
                program: 65, clips: [clip(withLane: expressionSine(rateHz: 4, startBeat: 1,
                                                                   lengthBeats: 5))]),
                                 durationSeconds: 4.0, blockFrames: 4_096),
            rate: 4)
        // §10.1's own default rate, recorded because P5 has to choose it.
        let hostedAt55 = bins(
            try await renderLeft(track: soundBankTrack(
                program: 65, clips: [clip(withLane: expressionSine(rateHz: 5.5, startBeat: 1,
                                                                   lengthBeats: 5))]),
                                 durationSeconds: 4.0, blockFrames: 4_096),
            rate: 5.5)
        // NO lane at all — the analysis control. Whatever this reads is the
        // floor every figure above has to beat.
        let hostedFlat = bins(
            try await renderLeft(track: soundBankTrack(program: 65,
                                                       clips: [clip(withLane: nil)]),
                                 durationSeconds: 4.0, blockFrames: 4_096),
            rate: 8)

        // --- The engine control: same lane, same clip, built-in sampler ------
        let zone = SamplerZone(audioFileURL: try sineFixture(), rootPitch: 69)
        let builtIn = Track(
            name: "Sampler", kind: .instrument,
            clips: [clip(withLane: expressionSine(rateHz: 8, startBeat: 1, lengthBeats: 5))],
            instrument: InstrumentDescriptor(
                kind: .sampler,
                sampler: SamplerParams(zones: [zone], attack: 0.001, release: 0.05)))
        let builtInAt8 = bins(try await renderLeft(track: builtIn, durationSeconds: 4.0, blockFrames: 4_096), rate: 8)

        func line(_ label: String, _ b: (rate: Double, image: Double)) -> String {
            "[measured] P5/T5 \(label): at-rate \(b.rate), at-image \(b.image), "
                + "image/rate = \(b.image / max(b.rate, 1e-12))"
        }
        print(line("hosted AUSampler, CC11 @ 8.0 Hz (image 3.71875)", hostedAt8))
        print(line("hosted AUSampler, CC11 @ 2.0 Hz (image 9.71875)", hostedAt2))
        print(line("hosted AUSampler, CC11 @ 4.0 Hz (image 7.71875)", hostedAt4))
        print(line("hosted AUSampler, CC11 @ 5.5 Hz (image 6.21875)", hostedAt55))
        // ⭐ THE CLOSED FORM, and it is what makes the ceiling statable for
        // ANY rate instead of only the four measured here. A zero-order hold
        // at f_s weights the fundamental by sinc(f/f_s) and the first image by
        // sinc((f_s−f)/f_s); those two sines are supplementary, so the ratio
        // reduces to exactly `f / (f_s − f)`. Printed beside each measurement
        // so a reader can see the model predict, not just describe.
        for (label, rate, measured) in [("2.0", 2.0, hostedAt2), ("4.0", 4.0, hostedAt4),
                                        ("5.5", 5.5, hostedAt55), ("8.0", 8.0, hostedAt8)] {
            let predicted = rate / (blockRate - rate)
            print("[measured] P5/T5 ZOH model @ \(label) Hz: predicted image/rate \(predicted), "
                  + "measured \(measured.image / max(measured.rate, 1e-12))")
            #expect(abs(measured.image / measured.rate - predicted) < 0.1 * predicted + 0.02)
        }
        print(line("hosted AUSampler, NO CC11 lane  (floor)         ", hostedFlat))
        print(line("built-in sampler, CC11 @ 8.0 Hz (image 3.71875)", builtInAt8))

        // The control sounds and tracks the commanded rate cleanly: without
        // this the hosted image below could be an artefact of the analysis.
        #expect(builtInAt8.rate > 0)
        #expect(builtInAt8.image < builtInAt8.rate * 0.5)
        // The floor: a note with no lane has essentially nothing at either bin.
        #expect(hostedFlat.image < hostedAt8.image * 0.25)
        // ⛔ THE FINDING: on the hosted AU an 8 Hz expression modulation comes
        // back with MORE energy at 3.719 Hz than at 8 Hz. CC 11 is re-sampled
        // at the block rate, exactly as bend is.
        #expect(hostedAt8.image > hostedAt8.rate)
        // …and below Nyquist the commanded rate wins, so the effect is a
        // sampling limit and not a fixed resonance.
        #expect(hostedAt2.rate > hostedAt2.image)

        // ── m28-bug: THE SAME RENDER AT THE SHIPPING BLOCK ────────────────────
        //
        // Everything above is a fact about a 4096-frame block, and it stays
        // pinned because it is the evidence the ceiling was argued from. But
        // that block is no longer what ships, and a test that measured only the
        // retired configuration would let the fix rot silently.
        //
        // Same lane, same note, same analysis — only the block differs. The
        // image bin has to move to |93.75 − 8| = 85.75 Hz, which is above this
        // envelope trace's own Nyquist, so the 3.719 Hz bin simply empties.
        func shippingBins(_ audio: [Float], rate: Double) -> (rate: Double, image: Double) {
            let envelope = rmsEnvelope(audio, in: window, hop: hop)
            return (envelopeMagnitude(envelope, frequency: rate, sampleRate: envelopeRate),
                    envelopeMagnitude(envelope, frequency: abs(48_000.0 / 4_096.0 - rate),
                                      sampleRate: envelopeRate))
        }
        let shippingAt8 = shippingBins(
            try await renderLeft(track: soundBankTrack(
                program: 65, clips: [clip(withLane: expressionSine(rateHz: 8, startBeat: 1,
                                                                   lengthBeats: 5))]),
                                 durationSeconds: 4.0),
            rate: 8)
        print(line("SHIPPING BLOCK (\(RenderBlockSize.offlineFrames)), CC11 @ 8.0 Hz  ",
                   shippingAt8))
        // ⭐ THE INEQUALITY THAT DEFINED THE BUG, INVERTED. At 4096 the alias
        // was 2.14× the commanded modulation; at 512 it must be a small
        // fraction of it. Measured on this rig: 0.032.
        let shippingRatio = shippingAt8.image / max(shippingAt8.rate, 1e-12)
        #expect(shippingAt8.image < 0.25 * shippingAt8.rate,
                "image/commanded = \(shippingRatio) at the shipping block — the sample-and-hold is back in band")
        // CONJUNCTIVE, because "no image" is also what a render with no
        // modulation at all scores: the commanded 8 Hz must be STRONGER than
        // the 4096 arm delivered, not merely present.
        #expect(shippingAt8.rate > hostedAt8.rate,
                "shipping delivers \(shippingAt8.rate) at 8 Hz vs \(hostedAt8.rate) at 4096 — no depth gain")
    }

    // MARK: - T6 (breath-pad P5): how deep must a CC 11 tremor be to be heard?

    /// §10.1 specifies `tremorDepth` as "0.03 of effort travel". At leg D's
    /// defaults `travel = peakValue × depth = 127 × 0.25 = 31.75 CC`, so that
    /// reading is **±0.95 CC — one integer step**. The competing reading (0.03
    /// of `peakValue`) is ±3.8 CC. Same knob name, 4× different feature. This
    /// measures what each one is worth in dB on the path that can actually
    /// carry a tremor (the built-in `.sampler`), because if ±1 CC moves nothing
    /// then P5 would be shipping a generator hook, five wire keys and a
    /// suppression warning for a feature that is inaudible everywhere.
    @Test("T6 (P5): CC 11 tremor depth in CC steps → measured dB on the built-in sampler")
    func expressionTremorDepthInDecibels() async throws {
        let sampleRate = 48_000.0
        let hop = 256
        let envelopeRate = sampleRate / Double(hop)
        let window = 24_000 + Int(0.4 * sampleRate)..<24_000 + Int(2.4 * sampleRate)
        let zone = SamplerZone(audioFileURL: try sineFixture(), rootPitch: 69)

        /// Peak-to-trough dB of a `rateHz` modulation, measured two ways so a
        /// disagreement is visible: (a) from the Goertzel component amplitude
        /// (2 × magnitude) against the envelope mean, and (b) from the raw
        /// envelope's own min and max.
        func depthDb(_ audio: [Float], rateHz: Double) -> (goertzel: Double, raw: Double) {
            let envelope = rmsEnvelope(audio, in: window, hop: hop)
            let mean = envelope.reduce(0.0) { $0 + Double($1) } / Double(envelope.count)
            guard mean > 0 else { return (0, 0) }
            let amplitude = 2 * envelopeMagnitude(envelope, frequency: rateHz,
                                                  sampleRate: envelopeRate)
            let m = min(0.999, amplitude / mean)
            let lo = Double(envelope.min() ?? 0), hi = Double(envelope.max() ?? 0)
            return (20 * log10((1 + m) / (1 - m)),
                    lo > 0 ? 20 * log10(hi / lo) : .infinity)
        }

        for filterDepth in [0.0, 0.6] as [Double] {
            var params = SamplerParams(zones: [zone], attack: 0.001, release: 0.05)
            params.expressionFilterDepth = filterDepth
            for amplitude in [1.0, 2.0, 4.0, 8.0] as [Double] {
                let lane = expressionSine(rateHz: 4, startBeat: 1, lengthBeats: 5,
                                          centre: 111, amplitude: amplitude)
                let track = Track(name: "Sampler", kind: .instrument,
                                  clips: [clip(withLane: lane)],
                                  instrument: InstrumentDescriptor(kind: .sampler,
                                                                   sampler: params))
                let measured = depthDb(try await renderLeft(track: track, durationSeconds: 4.0),
                                       rateHz: 4)
                print("[measured] P5/T6 built-in sampler, expressionFilterDepth "
                      + "\(filterDepth), CC11 111 ± \(Int(amplitude)): "
                      + "peak-to-trough \(measured.goertzel) dB (Goertzel), "
                      + "\(measured.raw) dB (raw envelope min/max)")
            }
        }

        // A ±1 CC step must still MOVE something, or the null test below it
        // would be measuring nothing. Recorded as a floor, not a target.
        let oneStep = Track(
            name: "Sampler", kind: .instrument,
            clips: [clip(withLane: expressionSine(rateHz: 4, startBeat: 1, lengthBeats: 5,
                                                  centre: 111, amplitude: 1))],
            instrument: InstrumentDescriptor(
                kind: .sampler,
                sampler: SamplerParams(zones: [zone], attack: 0.001, release: 0.05)))
        let flat = Track(
            name: "Sampler", kind: .instrument,
            clips: [clip(withLane: expressionSine(rateHz: 4, startBeat: 1, lengthBeats: 5,
                                                  centre: 111, amplitude: 0))],
            instrument: InstrumentDescriptor(
                kind: .sampler,
                sampler: SamplerParams(zones: [zone], attack: 0.001, release: 0.05)))
        let oneStepAudio = try await renderLeft(track: oneStep, durationSeconds: 4.0)
        let flatAudio = try await renderLeft(track: flat, durationSeconds: 4.0)
        let oneStepBin = envelopeMagnitude(rmsEnvelope(oneStepAudio, in: window, hop: hop),
                                           frequency: 4, sampleRate: envelopeRate)
        let flatBin = envelopeMagnitude(rmsEnvelope(flatAudio, in: window, hop: hop),
                                        frequency: 4, sampleRate: envelopeRate)
        print("[measured] P5/T6 4 Hz envelope bin: ±1 CC \(oneStepBin), flat lane \(flatBin), "
              + "ratio \(oneStepBin / max(flatBin, 1e-15))")
        #expect(oneStepBin > flatBin * 4)
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
