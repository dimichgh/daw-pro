import Foundation
import Testing
@testable import AIServices
@testable import DAWCore

/// p2-sing-e part 1, the pure halves of a sing job: the WAV codec, the per-unit check, assembly, the
/// static gain (the bounce's own policy), the four landing gates WITH a control each, the note and
/// word checks, and the phrase cache.
@Suite("SingJob audio — codec, assembly, gain, landing gates, checks, cache (p2-sing-e)")
struct SingJobGatesTests {

    static let rate = 24_000

    /// The two-unit melody's plan.
    static func plan() async throws -> SingPlan {
        let root = try SingFixture.tempDir("plan")
        defer { try? FileManager.default.removeItem(at: root) }
        return try await MainActor.run {
            let (store, clipID) = try SingFixture.store(root: root)
            return try store.planSungVocal(clipId: clipID, octaveShift: 0).plan
        }
    }

    struct Take {
        var written: [Float]
        var report: BounceLoudnessReport?
        var measured: LoudnessMeasurement
        var frames: [ClipPitchFrame]
        var gates: SingGateReport
    }

    /// Renders every unit as a facade would (`voice`), assembles, gains, writes, reads back, measures and
    /// gates: the coordinator's finishing steps, in order, on the same functions.
    static func take(_ plan: SingPlan, voice: SingFixture.Voice = .sine, longUnit: Int? = nil) async throws -> Take {
        let placed = plan.units.enumerated().map { index, unit in
            let request = SingJobRequestBuilder.phraseRequest(unit: unit, voice: .builtin(id: "builtin-1"),
                                                              seed: 1, outputPath: "", outputSampleRate: rate)
            return SingTakeAssembly.Placed(
                offsetSeconds: unit.offsetSeconds,
                samples: SingFixture.render(request, voice: voice, extraSeconds: index == longUnit ? 0.1 : 0))
        }
        let assembled = SingTakeAssembly.assemble(placed, sampleRate: rate)
        var gained = assembled
        var report: BounceLoudnessReport?
        if let normalized = try? await ProjectStore.normalizeSungVocalTake(
            RenderedAudio(sampleRate: Double(rate), channelData: [assembled])) {
            gained = normalized.audio.channelData[0]
            report = normalized.report
        }
        let dir = try SingFixture.tempDir("take")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("take.wav")
        try SingWAV.writeFloat32Mono(gained, sampleRate: rate, to: url)
        let written = try SingWAV.read(url).mono
        let measured = await Loudness.measureDetached(RenderedAudio(sampleRate: Double(rate), channelData: [written]))
        let frames = SingFixture.frames(samples: written, sampleRate: rate)
        let gates = SingLandingGates.evaluate(samples: written, sampleRate: rate, plan: plan, frames: frames,
                                              written: measured, report: report)
        return Take(written: written, report: report, measured: measured, frames: frames, gates: gates)
    }

    // MARK: - WAV

    @Test("WAV: the writer writes wavio's layout; the reader reads it back bit for bit")
    func wavRoundTrip() throws {
        let samples: [Float] = [0, 0.5, -0.25, 1, -1, .leastNonzeroMagnitude]
        let data = SingWAV.float32MonoBytes(samples, sampleRate: 48_000)
        #expect(data.count == 12 + 26 + 12 + 8 + samples.count * 4)
        #expect(Array(data[0..<4]) == Array("RIFF".utf8))
        #expect(Array(data[12..<16]) == Array("fmt ".utf8))
        #expect(data[16] == 18, "the 18-byte fmt chunk (cbSize 0) wavio writes")
        #expect(data[20] == 3, "WAVE_FORMAT_IEEE_FLOAT")
        #expect(Array(data[38..<42]) == Array("fact".utf8))
        let audio = try SingWAV.parse(data)
        #expect(audio.sampleRate == 48_000)
        #expect(audio.channels.count == 1)
        #expect(audio.mono.map { $0.bitPattern } == samples.map { $0.bitPattern })
    }

    @Test("WAV: 16-bit PCM stereo, an odd-sized chunk skipped with its pad byte; truncation refused")
    func wavReaderFormats() throws {
        var data = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le32(0); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("junk".utf8)); le32(3); data.append(contentsOf: [1, 2, 3, 0])
        data.append(contentsOf: Array("fmt ".utf8)); le32(16)
        le16(1); le16(2); le32(8_000); le32(32_000); le16(4); le16(16)
        data.append(contentsOf: Array("data".utf8)); le32(8)
        le16(UInt16(bitPattern: 16_384)); le16(UInt16(bitPattern: -16_384)); le16(0); le16(UInt16(bitPattern: 32_767))
        let audio = try SingWAV.parse(data)
        #expect(audio.sampleRate == 8_000)
        #expect(audio.channels == [[0.5, 0], [-0.5, Float(32_767) / 32_768]])
        #expect(audio.mono == [0, Float(32_767) / 65_536], "mono is the channels' mean")
        #expect(throws: SingWAV.ReadError.truncated) { try SingWAV.parse(data.dropLast(2)) }
        #expect(throws: SingWAV.ReadError.notWAV) { try SingWAV.parse(Data("hello world!".utf8)) }
    }

    // MARK: - One unit

    @Test("unit check: NaN and digital silence are caught; a sung unit and a quiet one are not")
    func unitCheck() {
        #expect(SingUnitCheck.check([0.1, .nan, 0.1]) == .nonFinite)
        #expect(SingUnitCheck.check([0.1, .infinity]) == .nonFinite)
        #expect(SingUnitCheck.check([Float](repeating: 0, count: 100)) == .silent)
        #expect(SingUnitCheck.check([Float](repeating: 0.00005, count: 100)) == .silent)
        #expect(SingUnitCheck.check([0, 0.001, -0.001]) == .ok, "control: −60 dBFS is not silence")
        #expect(SingUnitCheck.check([0, 0.1, -0.1]) == .ok)
    }

    // MARK: - Assembly

    @Test("assembly: units sum at their offsets; length comes from the units' own audio")
    func assemblyPlacesUnits() {
        let a = SingTakeAssembly.Placed(offsetSeconds: 0, samples: [1, 1, 1, 1])
        let b = SingTakeAssembly.Placed(offsetSeconds: 0.006, samples: [2, 2, 2])
        let out = SingTakeAssembly.assemble([a, b], sampleRate: 1_000)
        #expect(out == [1, 1, 1, 1, 0, 0, 2, 2, 2], "no overlap: exact placement, a gap of silence")
        let cut = SingTakeAssembly.assemble([SingTakeAssembly.Placed(offsetSeconds: -0.002, samples: [1, 2, 3, 4])],
                                            sampleRate: 1_000)
        #expect(cut == [3, 4], "a negative offset cuts that much of the unit's start")
    }

    @Test("assembly: where units overlap, a 20 ms equal-power crossfade centred on the overlap")
    func assemblyCrossfades() {
        let rate = 1_000
        let a = SingTakeAssembly.Placed(offsetSeconds: 0, samples: [Float](repeating: 1, count: 100))
        let b = SingTakeAssembly.Placed(offsetSeconds: 0.060, samples: [Float](repeating: 1, count: 100))
        let out = SingTakeAssembly.assemble([a, b], sampleRate: rate)
        #expect(out.count == 160)
        // Overlap 60..<100 (40 samples); the 20-sample window is centred: 70..<90.
        #expect(out[0..<70].allSatisfy { $0 == 1 }, "before the window: unit A alone")
        #expect(out[90..<160].allSatisfy { $0 == 1 }, "after it: unit B alone")
        for t in 70..<90 {
            let x = Double.pi / 2 * Double(t - 70) / 20
            let expected = Float(cos(x)) + Float(sin(x))
            #expect(abs(out[t] - expected) < 1e-6, "sample \(t): cos fade-out + sin fade-in")
        }
    }

    // MARK: - Gain and the landing gates (design §7.1), each with its control

    @Test("a clean take: gained toward −18 LUFS, every gate passes, no quiet notice")
    func cleanTakePassesEveryGate() async throws {
        let plan = try await Self.plan()
        #expect(plan.units.count == 2, "control: the fixture is two units")
        let take = try await Self.take(plan)
        #expect(take.gates.failed.isEmpty, "\(take.gates)")
        let report = try #require(take.report)
        #expect(!report.limitedByCeiling)
        #expect(abs((report.output.integratedLufs ?? .nan) - ProjectStore.sungVocalLufsTarget) < 0.1)
        #expect(abs((take.measured.integratedLufs ?? .nan) - ProjectStore.sungVocalLufsTarget) < 0.1,
                "the WRITTEN bytes measure the same")
        #expect(take.gates.voicedCoverage > 0.8)
        #expect(abs(take.gates.lengthSeconds - take.gates.plannedSeconds) <= 0.02)
        #expect(!take.gates.quieterThanUsual)
    }

    @Test("L1: a unit 100 ms longer than planned fails physics; the clean take is the control")
    func gateL1Length() async throws {
        let plan = try await Self.plan()
        let take = try await Self.take(plan, voice: .sine, longUnit: 1)
        #expect(take.gates.failed == [.physics], "\(take.gates)")
        #expect(take.gates.lengthSeconds - take.gates.plannedSeconds > 0.09)
    }

    @Test("L2: audible noise is not singing (voiced coverage under 50%); the sine is the control")
    func gateL2Noise() async throws {
        let plan = try await Self.plan()
        let take = try await Self.take(plan, voice: .noise)
        #expect(take.gates.failed.contains(.singingPresent), "\(take.gates)")
        #expect(take.gates.voicedCoverage < 0.1)
        #expect((take.measured.integratedLufs ?? -.infinity) > -30, "control: the noise IS audible (L4 passes)")
        #expect(!take.gates.failed.contains(.audible))
    }

    @Test("L3 + quiet notice: a click holds the gain at the ceiling; it lands under −1 dBTP, quieter than usual")
    func gateL3ClickIsCeilingLimited() async throws {
        let plan = try await Self.plan()
        let take = try await Self.take(plan, voice: .click)
        let report = try #require(take.report)
        #expect(report.limitedByCeiling, "the click, not the loudness, set the gain")
        #expect((take.measured.truePeakDbtp ?? .infinity) <= -1.0 + SingLandingGates.truePeakToleranceDb)
        #expect(take.gates.failed.isEmpty, "\(take.gates)")
        #expect(take.gates.quieterThanUsual)
        #expect((take.measured.integratedLufs ?? 0) < -18.5)
    }

    @Test("L3 evaluates the written bytes: a true peak over −1 dBTP fails, one at it passes")
    func gateL3Threshold() async throws {
        let plan = try await Self.plan()
        let take = try await Self.take(plan)
        var hot = take.measured
        hot.truePeakDbtp = -0.5
        let failed = SingLandingGates.evaluate(samples: take.written, sampleRate: Self.rate, plan: plan,
                                               frames: take.frames, written: hot, report: take.report)
        #expect(failed.failed == [.truePeak])
        var atCeiling = take.measured
        atCeiling.truePeakDbtp = -1.0
        let passed = SingLandingGates.evaluate(samples: take.written, sampleRate: Self.rate, plan: plan,
                                               frames: take.frames, written: atCeiling, report: take.report)
        #expect(passed.failed.isEmpty)
    }

    @Test("L4: a very quiet take with a click cannot be gained up past the ceiling and fails audibility")
    func gateL4QuietWithClick() async throws {
        let plan = try await Self.plan()
        let take = try await Self.take(plan, voice: .quietWithClick)
        #expect(take.report?.limitedByCeiling == true)
        #expect(take.gates.failed.contains(.audible), "\(take.gates)")
        #expect((take.measured.integratedLufs ?? -.infinity) < -30)
        #expect(!take.gates.quieterThanUsual, "a take that does not land gets no quiet notice")
    }

    @Test("digital silence: nothing to gain (bounceSilent), L2 and L4 fail")
    func silentTakeFails() async throws {
        let plan = try await Self.plan()
        let take = try await Self.take(plan, voice: .silent)
        #expect(take.report == nil)
        #expect(take.gates.failed == [.singingPresent, .audible], "\(take.gates)")
    }

    @Test("gate sentences are beginner words that say what happened and what to do")
    func gateSentences() {
        for gate in SingLandingGate.allCases {
            #expect(gate.sentence.hasSuffix("Try another take."))
            #expect(!gate.sentence.contains("LUFS") && !gate.sentence.contains("dB"))
        }
    }

    // MARK: - The note check (design §4.6, the §1.7 metric)

    @Test("notes: the planned sine is in tune; a semitone off misses every note and names its bars")
    func noteCheck() async throws {
        let plan = try await Self.plan()
        let bars = [2, 2, 2, 2, 10, 10, 10, 10]
        let clean = try await Self.take(plan)
        let inTune = SingNoteCheck.score(frames: clean.frames, plan: plan, noteBars: bars)
        #expect(inTune.hitRate == 1)
        #expect((inTune.meanAbsErrorCents ?? 99) < 5)
        #expect(inTune.inTune)
        #expect(inTune.offBars.isEmpty)

        let off = try await Self.take(plan, voice: .detuned(cents: 100))
        let missed = SingNoteCheck.score(frames: off.frames, plan: plan, noteBars: bars)
        #expect(missed.hitRate == 0)
        #expect(!missed.inTune)
        #expect(missed.offBars == [2, 10])

        let near = try await Self.take(plan, voice: .detuned(cents: 30))
        let close = SingNoteCheck.score(frames: near.frames, plan: plan, noteBars: bars)
        #expect(close.hitRate == 1, "30 c is a hit (±50 c)")
        #expect(!close.inTune, "but a 30 c mean error is over the 25 c bar")
    }

    // MARK: - The word check (design §4.6, §7.3)

    @Test("words: clear, some unclear, hard to understand; skipped without a speech model; hard to judge")
    func wordCheck() async throws {
        let plan = try await Self.plan()
        let clear = SingWordCheck.check(assignment: plan.assignment, heard: "one two three four five six seven eight",
                                        voiceIsReliable: true)
        #expect(clear.state == SungWordCheck.State.checked)
        #expect(clear.wer == 0)
        #expect(clear.verdict == SingWordCheck.Verdict.clear)
        #expect(SingWordCheck.sentence(clear) == "Words clear")
        let some = SingWordCheck.check(assignment: plan.assignment, heard: "one two tree four five sex seven ate",
                                       voiceIsReliable: true)
        #expect(some.verdict == SingWordCheck.Verdict.someUnclear)
        let hard = SingWordCheck.check(assignment: plan.assignment, heard: "la la la", voiceIsReliable: true)
        #expect(hard.verdict == SingWordCheck.Verdict.unclear)
        #expect(SingWordCheck.sentence(hard).hasPrefix("The words are hard to understand in this take"))
        let skipped = SingWordCheck.check(assignment: plan.assignment, heard: nil, voiceIsReliable: true)
        #expect(skipped.state == SungWordCheck.State.skipped)
        #expect(SingWordCheck.sentence(skipped) == "Word check skipped: no speech model is installed.")
        let unsure = SingWordCheck.check(assignment: plan.assignment, heard: "la la la", voiceIsReliable: false)
        #expect(unsure.state == SungWordCheck.State.hardToJudge)
        #expect(SingWordCheck.sentence(unsure) == "Word check: hard to judge for this voice.")
    }

    // MARK: - The phrase cache (design §4.3)

    @Test("cache: a stored unit is a hit; a truncated one is deleted and reads as a miss")
    func cacheHitAndBrokenEntry() throws {
        let dir = try SingFixture.tempDir("cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SingPhraseCache(directory: dir)
        try cache.prepare()
        let excluded = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true, "the cache folder is kept out of backups")
        let samples: [Float] = (0..<480).map { Float(sin(Double($0) / 10)) * 0.1 }
        try SingWAV.writeFloat32Mono(samples, sampleRate: 48_000, to: cache.wavURL("k1"))
        try cache.store(SingPhraseCache.Entry(key: "k1", frames: samples.count, sampleRate: 48_000, seed: 7))
        let hit = try #require(cache.lookup("k1", sampleRate: 48_000))
        #expect(hit.samples == samples)
        #expect(hit.entry.seed == 7)
        #expect(cache.lookup("k1", sampleRate: 24_000) == nil, "another rate is a miss (and drops the entry)")
        #expect(!FileManager.default.fileExists(atPath: cache.wavURL("k1").path))

        try SingWAV.writeFloat32Mono(samples, sampleRate: 48_000, to: cache.wavURL("k2"))
        try cache.store(SingPhraseCache.Entry(key: "k2", frames: samples.count, sampleRate: 48_000, seed: 7))
        let bytes = try Data(contentsOf: cache.wavURL("k2"))
        try bytes.dropLast(100).write(to: cache.wavURL("k2"))
        #expect(cache.lookup("k2", sampleRate: 48_000) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.factsURL("k2").path), "the broken entry is gone")
        #expect(cache.lookup("never", sampleRate: 48_000) == nil)
    }

    @Test("cache: over its cap, the least recently used entries go first, never a protected one")
    func cacheEvictsLeastRecentlyUsed() throws {
        let dir = try SingFixture.tempDir("cache-lru")
        defer { try? FileManager.default.removeItem(at: dir) }
        let unit: [Float] = [Float](repeating: 0.1, count: 1_000)
        let entryBytes = UInt64(SingWAV.float32MonoBytes(unit, sampleRate: 8_000).count)
        let cache = SingPhraseCache(directory: dir, capBytes: entryBytes * 2 + 400)
        try cache.prepare()
        for (i, key) in ["old", "mid", "new"].enumerated() {
            try SingWAV.writeFloat32Mono(unit, sampleRate: 8_000, to: cache.wavURL(key))
            try cache.store(SingPhraseCache.Entry(key: key, frames: unit.count, sampleRate: 8_000, seed: 1))
            let when = Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60)
            for url in [cache.wavURL(key), cache.factsURL(key)] {
                try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
            }
        }
        #expect(cache.evict(protecting: ["old"]) == ["mid"], "the oldest unprotected entry goes")
        #expect(cache.lookup("old", sampleRate: 8_000) != nil)
        #expect(cache.lookup("new", sampleRate: 8_000) != nil)
        #expect(cache.evict(protecting: []) == [], "control: under the cap nothing goes")
    }
}
