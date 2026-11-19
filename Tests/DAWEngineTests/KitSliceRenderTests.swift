import AVFAudio
import CryptoKit
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

// m39-w4-6 — design `docs/design/2026-10-07-loop-drum-depth.md` §9.2: the render gates of kit-aware slicing.
//
// THE CORPUS (C3, "synthetic, truth known"): five one-shots, one per half-second slot, written at test time
// from a seeded generator so the truth is known exactly:
//   slot 0  60 Hz sine, 150 ms decay, plus a 2 ms click         → a kick
//   slot 1  200 Hz sine plus noise, 120 ms                      → a snare
//   slot 2  noise high-passed at 8 kHz, 40 ms                   → a closed hat
//   slot 3  the same noise, 400 ms                              → an open hat
//   slot 4  1 kHz sine, 300 ms                                  → nothing a kit knows ("other")
// "N ms" is the time the envelope takes to fall 60 dB. Stereo (left full, right at 0.8) and 48 kHz, the
// reconstruction suite's reasons: no mono short-read (m32-h), and a read increment of exactly 1.0.
//
// NOT `@MainActor`: the engine's offline render is reached through one main-actor helper, `render`.
enum KitSliceCorpus {
    static let rate = 48_000.0
    static let slotSeconds = 0.5
    static let slots = 5
    static var frames: Int { Int(Double(slots) * slotSeconds * rate) }
    static let bpm = 120.0
    /// The truth: slot index → the note a sorted kit must put it on (design C3).
    static let expectedNotes = [36, 38, 42, 46, 84]

    /// Seeded uniform noise in [-1, 1] (xorshift32), so every run writes the very same file.
    struct Noise {
        var state: UInt32
        mutating func next() -> Double {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return Double(state) / Double(UInt32.max) * 2 - 1
        }
    }

    /// RBJ high-pass biquad, direct form I.
    struct HighPass {
        let b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        init(cutoff: Double, rate: Double, q: Double) {
            let w = 2 * Double.pi * cutoff / rate
            let alpha = sin(w) / (2 * q)
            let a0 = 1 + alpha
            b0 = (1 + cos(w)) / 2 / a0
            b1 = -(1 + cos(w)) / a0
            b2 = (1 + cos(w)) / 2 / a0
            a1 = -2 * cos(w) / a0
            a2 = (1 - alpha) / a0
        }
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// −60 dB after `seconds`, silent from there on.
    static func envelope(_ t: Double, _ seconds: Double) -> Double {
        t < seconds ? exp(-t * log(1000) / seconds) : 0
    }

    /// The mono corpus, one hit per slot.
    static func monoSamples() -> [Double] {
        var out = [Double](repeating: 0, count: frames)
        let slot = Int(slotSeconds * rate)
        var noise = Noise(state: 0x5EED_0046)
        // slot 0: kick
        for i in 0..<slot {
            let t = Double(i) / rate
            var v = 0.8 * envelope(t, 0.150) * sin(2 * .pi * 60 * t)
            if t < 0.002 { v += 0.5 * noise.next() * (1 - t / 0.002) }
            out[i] = v
        }
        // slot 1: snare
        for i in 0..<slot {
            let t = Double(i) / rate
            out[slot + i] = envelope(t, 0.120) * (0.5 * sin(2 * .pi * 200 * t) + 0.35 * noise.next())
        }
        // slots 2 and 3: closed and open hat (4th-order high-pass at 8 kHz)
        for (index, length) in [(2, 0.040), (3, 0.400)] {
            var hp1 = HighPass(cutoff: 8_000, rate: rate, q: 0.7071)
            var hp2 = HighPass(cutoff: 8_000, rate: rate, q: 0.7071)
            for i in 0..<slot {
                let t = Double(i) / rate
                let filtered = hp2.process(hp1.process(noise.next()))
                out[index * slot + i] = 0.9 * envelope(t, length) * filtered
            }
        }
        // slot 4: a 1 kHz tone
        for i in 0..<slot {
            let t = Double(i) / rate
            out[4 * slot + i] = 0.6 * envelope(t, 0.300) * sin(2 * .pi * 1_000 * t)
        }
        return out
    }

    /// Writes the corpus to a fresh temp WAV (stereo float32, 48 kHz).
    static func write() throws -> URL {
        try write(monoSamples(), name: "corpus48.wav")
    }

    /// Writes `mono` (left full, right at 0.8) to a fresh temp WAV (stereo float32, 48 kHz).
    static func write(_ mono: [Double], name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("w46-kit-corpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = mono.count
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                                channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(count)))
        let data = try #require(buffer.floatChannelData)
        for i in 0..<count {
            data[0][i] = Float(mono[i])
            data[1][i] = Float(mono[i] * 0.8)
        }
        buffer.frameLength = AVAudioFrameCount(count)
        try file.write(from: buffer)
        return url
    }

    // MARK: - The C2 loop: hits cut while still ringing

    /// A one-second loop of eight hits, one every 125 ms (sixteenths at 120 BPM): kick, closed hat, snare,
    /// OPEN hat, closed hat, kick, OPEN hat, closed hat, then 0.5 s of tail. The open hats ring 400 ms, so
    /// each is CUT by the next hit while still sounding, and their tails bleed into the next slices: the
    /// case where a choke could change the reconstruction.
    static let loopRoles: [KitSliceRole] = [.kick, .closedHat, .snare, .openHat, .closedHat, .kick, .openHat,
                                            .closedHat]
    static let loopHitFrames = 6_000
    static var loopFrames: Int { loopHitFrames * loopRoles.count + Int(0.5 * rate) }

    static func loopSamples() -> [Double] {
        var out = [Double](repeating: 0, count: loopFrames)
        var noise = Noise(state: 0x100B_0046)
        for (index, role) in loopRoles.enumerated() {
            let start = index * loopHitFrames
            var hp1 = HighPass(cutoff: 8_000, rate: rate, q: 0.7071)
            var hp2 = HighPass(cutoff: 8_000, rate: rate, q: 0.7071)
            for i in 0..<Int(0.5 * rate) where start + i < out.count {
                let t = Double(i) / rate
                let v: Double
                switch role {
                case .kick: v = 0.7 * envelope(t, 0.150) * sin(2 * .pi * 60 * t)
                case .snare: v = envelope(t, 0.120) * (0.4 * sin(2 * .pi * 200 * t) + 0.3 * noise.next())
                case .closedHat: v = 0.6 * envelope(t, 0.040) * hp2.process(hp1.process(noise.next()))
                case .openHat: v = 0.6 * envelope(t, 0.400) * hp2.process(hp1.process(noise.next()))
                case .other: v = 0
                }
                out[start + i] += v
            }
        }
        return out
    }

    /// The loop's chromatic chop at its eight known onsets.
    static func loopPlan(_ url: URL, settings: SliceToSamplerSettings) throws -> SliceToSamplerPlan.Result {
        let geometry = try BoundarySnapper.resolve(
            fileAt: url, boundarySeconds: (1..<loopRoles.count).map { Double($0 * loopHitFrames) / rate },
            snapWindowSeconds: 0)
        return try SliceToSamplerPlan.compute(
            clip: Clip(name: "Loop", startBeat: 0, lengthBeats: Double(loopFrames) / rate * bpm / 60,
                       audioFileURL: url),
            geometry: geometry, strengths: [], settings: settings, tempoMap: TempoMap(constantBPM: bpm))
    }

    static func spans(_ plan: SliceToSamplerPlan.Result) -> [SliceFrameSpan] {
        plan.slices.map { SliceFrameSpan(start: $0.startFrame, end: $0.endFrame) }
    }

    /// The engine's own seam (`AudioEngine.analyzeSliceTimbres`), reached from the main actor.
    @MainActor
    static func engineTimbres(_ url: URL, _ spans: [SliceFrameSpan]) async throws -> [SliceTimbre] {
        try await AudioEngine().analyzeSliceTimbres(inFileAt: url, frameRanges: spans)
    }

    /// The source clip: the whole corpus, 5 beats at 120 BPM.
    static func clip(_ url: URL) -> Clip {
        Clip(name: "Corpus", startBeat: 0, lengthBeats: 5, audioFileURL: url)
    }

    /// The chromatic chop at the known slot boundaries (divisions mode: the head is pad 1).
    static func chromaticPlan(_ url: URL) throws -> SliceToSamplerPlan.Result {
        let geometry = try BoundarySnapper.resolve(
            fileAt: url, boundarySeconds: (1..<slots).map { Double($0) * slotSeconds },
            snapWindowSeconds: 0)
        return try SliceToSamplerPlan.compute(
            clip: clip(url), geometry: geometry, strengths: [],
            settings: SliceToSamplerSettings(mode: .divisions, divisions: slots),
            tempoMap: TempoMap(constantBPM: bpm))
    }

    static func samplerTrack(zones: [SamplerZone], notes: [MIDINote], lengthBeats: Double) -> Track {
        Track(name: "Pads", kind: .instrument,
              clips: [Clip(name: "pads", startBeat: 0, lengthBeats: lengthBeats, notes: notes)],
              instrument: InstrumentDescriptor(kind: .sampler,
                                               sampler: SamplerParams(zones: zones, gain: 1)))
    }

    /// The production offline render (`AudioEngine.renderOffline`), the reconstruction suite's path.
    @MainActor
    static func render(_ tracks: [Track], seconds: Double) async throws -> [[Float]] {
        let engine = AudioEngine()
        let buffer = try await engine.renderOffline(
            tracks: tracks, tempoMap: TempoMap(constantBPM: bpm), masterVolume: 1,
            fromBeat: 0, durationSeconds: seconds, forcedCompensationTargets: nil)
        return buffer.channelData
    }

    static func sha256(_ channels: [[Float]]) -> String {
        var hasher = SHA256()
        for channel in channels { channel.withUnsafeBytes { hasher.update(bufferPointer: $0) } }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func peak(_ channels: [[Float]]) -> Float {
        channels.flatMap { $0 }.reduce(0) { max($0, abs($1)) }
    }
}

@Suite("Kit slicing — render gates (m39-w4-6 C1)", .serialized)
struct KitSliceRenderTests {

    /// SHA-256 of the chromatic reconstruction render's float bits, captured by THIS test (`W46_RECORD_DIR`)
    /// from the tree before m39-w4-6 touched Sources (W8-W46, 2026-10-07).
    static let chromaticRenderGolden = "d88bf9a78a6e4d4e700b983e1b025b203b3906014779f5639db85884ffa7c699"

    @Test("C1 render: the chromatic chop's reconstruction renders byte-identically to before m39-w4-6")
    func chromaticReconstructionRenderIsPinned() async throws {
        let url = try KitSliceCorpus.write()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let plan = try KitSliceCorpus.chromaticPlan(url)
        #expect(plan.zones.count == KitSliceCorpus.slots, "control: one pad per slot")
        #expect(plan.zones.map(\.rootPitch) == [36, 37, 38, 39, 40], "control: chromatic from 36")
        let track = KitSliceCorpus.samplerTrack(zones: plan.zones, notes: plan.notes,
                                                lengthBeats: plan.midiClipLengthBeats)
        let channels = try await KitSliceCorpus.render([track], seconds: 2.5)
        #expect(KitSliceCorpus.peak(channels) > 0.3, "control: the render is not silent")
        let hash = KitSliceCorpus.sha256(channels)
        if let dir = ProcessInfo.processInfo.environment["W46_RECORD_DIR"] {
            try Data(hash.utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent("render-chromatic.txt"))
            return
        }
        #expect(hash == Self.chromaticRenderGolden, "C1 render: the chromatic reconstruction moved (\(hash))")
    }

    // MARK: - C3 / C5: the synthetic corpus, truth known

    /// The kit sort of the corpus, through the ENGINE's seam (so the wiring is measured too).
    static func sortedCorpus(_ url: URL) async throws -> KitSliceLayout.Outcome {
        let base = try SliceToSamplerPlan.compute(
            clip: KitSliceCorpus.clip(url),
            geometry: try BoundarySnapper.resolve(
                fileAt: url,
                boundarySeconds: (1..<KitSliceCorpus.slots).map { Double($0) * KitSliceCorpus.slotSeconds },
                snapWindowSeconds: 0),
            strengths: [],
            settings: SliceToSamplerSettings(mode: .divisions, divisions: KitSliceCorpus.slots,
                                             mapping: .kit).planSettings,
            tempoMap: TempoMap(constantBPM: KitSliceCorpus.bpm))
        let timbres = try await KitSliceCorpus.engineTimbres(url, KitSliceCorpus.spans(base))
        return try KitSliceLayout.apply(to: base, timbres: timbres, overrides: [:], clipId: UUID())
    }

    @Test("C3: the five synthetic one-shots land on 36, 38, 42, 46 and 84 — 5 of 5")
    func syntheticCorpusLandsOnItsNotes() async throws {
        let url = try KitSliceCorpus.write()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sorted = try await Self.sortedCorpus(url)
        let notes = sorted.plan.zones.map(\.rootPitch)
        print("W46 C3 notes \(notes) roles \(sorted.roles.map(\.rawValue)) "
              + "confidence \(sorted.plan.slices.map { String(format: "%.3f", $0.confidence ?? -1) })")
        #expect(notes == KitSliceCorpus.expectedNotes)
        #expect(sorted.roles == [.kick, .snare, .closedHat, .openHat, .other])
        #expect(sorted.summary == "Sorted into 1 kick, 1 snare, 1 closed hat, 1 open hat and 1 other hit.")
    }

    @Test("C5: 'other' is never folded — the 1 kHz tone is on 84 with role other and no choke")
    func otherToneIsNotFolded() async throws {
        let url = try KitSliceCorpus.write()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sorted = try await Self.sortedCorpus(url)
        let tone = try #require(sorted.plan.zones.last)
        #expect(tone.rootPitch == 84 && tone.minPitch == 84 && tone.maxPitch == 84)
        #expect(tone.drumRole == nil)
        #expect(tone.chokeGroup == nil)
        #expect(sorted.plan.slices.last?.role == .other)
    }

    @Test("the engine seam measures what the analyzer measures, index-aligned, once per slice")
    func engineSeamMatchesTheAnalyzer() async throws {
        let url = try KitSliceCorpus.write()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let slot = Int(KitSliceCorpus.slotSeconds * KitSliceCorpus.rate)
        let spans = (0..<KitSliceCorpus.slots).map {
            SliceFrameSpan(start: $0 * slot, end: $0 == KitSliceCorpus.slots - 1 ? nil : ($0 + 1) * slot)
        }
        let viaEngine = try await KitSliceCorpus.engineTimbres(url, spans)
        let direct = try SliceTimbreAnalyzer.analyze(fileAt: url, frameRanges: spans)
        #expect(viaEngine == direct)
        #expect(viaEngine.count == spans.count)
        #expect(viaEngine.allSatisfy { $0.peak > 0.3 && $0.peak <= 1 }, "every slot holds a hit")
        #expect(viaEngine.allSatisfy { $0.durationSeconds == KitSliceCorpus.slotSeconds })
        // No NaN or infinity leaks out of any feature.
        for t in viaEngine {
            for value in [t.lowEnergyShare, t.highEnergyShare, t.attackCentroidHz, t.decaySeconds,
                          t.spectralFlatness, t.peak] {
                #expect(value.isFinite)
            }
        }
        // Silence measures as silence, not as a drum.
        let silent = [Float](repeating: 0, count: 4_800)
        let quiet = silent.withUnsafeBufferPointer {
            SliceTimbreAnalyzer.timbre(of: $0, sampleRate: KitSliceCorpus.rate)
        }
        #expect(quiet.peak == 0 && quiet.lowEnergyShare == 0 && quiet.highEnergyShare == 0)
        #expect(DrumHitClassifier.classify(quiet).role == nil)
    }

    // MARK: - C2: the sort does not change the reconstruction

    @Test("C2: a kit-sorted reconstruction renders BIT-IDENTICALLY to the chromatic one (hats choking included)")
    func kitReconstructionIsBitIdenticalToChromatic() async throws {
        let url = try KitSliceCorpus.write(KitSliceCorpus.loopSamples(), name: "loop48.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let chromatic = try KitSliceCorpus.loopPlan(url, settings: SliceToSamplerSettings(
            mode: .divisions, divisions: KitSliceCorpus.loopRoles.count))
        let base = try KitSliceCorpus.loopPlan(url, settings: SliceToSamplerSettings(
            mode: .divisions, divisions: KitSliceCorpus.loopRoles.count, mapping: .kit).planSettings)
        let timbres = try SliceTimbreAnalyzer.analyze(fileAt: url, frameRanges: KitSliceCorpus.spans(base))
        // The truth is forced, so this gate measures the layout and the choke, not the classifier.
        var truth: [Int: KitSliceRole] = [:]
        for (index, role) in KitSliceCorpus.loopRoles.enumerated() { truth[index] = role }
        let kit = try KitSliceLayout.apply(to: base, timbres: timbres, overrides: truth, clipId: UUID())
        #expect(kit.plan.zones.map(\.rootPitch) != chromatic.zones.map(\.rootPitch),
                "control: the sort really moved the notes")
        #expect(kit.plan.zones.filter { $0.chokeGroup == 0 }.count == 5, "control: five hats choke")
        #expect(kit.plan.zones.map(\.startFrame) == chromatic.zones.map(\.startFrame))
        let seconds = Double(KitSliceCorpus.loopFrames) / KitSliceCorpus.rate
        let a = try await KitSliceCorpus.render(
            [KitSliceCorpus.samplerTrack(zones: chromatic.zones, notes: chromatic.notes,
                                         lengthBeats: chromatic.midiClipLengthBeats)], seconds: seconds)
        let b = try await KitSliceCorpus.render(
            [KitSliceCorpus.samplerTrack(zones: kit.plan.zones, notes: kit.plan.notes,
                                         lengthBeats: kit.plan.midiClipLengthBeats)], seconds: seconds)
        #expect(KitSliceCorpus.peak(a) > 0.2, "control: the reconstruction is not silent")
        var first: (channel: Int, frame: Int, a: Float, b: Float)?
        for channel in a.indices where first == nil {
            if let frame = zip(a[channel], b[channel]).enumerated()
                .first(where: { $0.element.0.bitPattern != $0.element.1.bitPattern })?.offset {
                first = (channel, frame, a[channel][frame], b[channel][frame])
            }
        }
        #expect(first == nil, "C2: first differing frame \(String(describing: first))")
        #expect(a.map { $0.count } == b.map { $0.count })
    }

    // MARK: - C6: a sorted kit's hats choke

    /// One render of `notes` (pitch, beat, length in beats) on `zones`.
    static func play(_ zones: [SamplerZone], _ notes: [(Int, Double, Double)]) async throws -> [Float] {
        let midi = notes.map { MIDINote(pitch: $0.0, velocity: 127, startBeat: $0.1, lengthBeats: $0.2) }
        let channels = try await KitSliceCorpus.render(
            [KitSliceCorpus.samplerTrack(zones: zones, notes: midi, lengthBeats: 4)], seconds: 1.0)
        return channels[0]
    }

    static func rms(_ x: [Float], _ range: Range<Int>) -> Double {
        var sum = 0.0
        for i in range { sum += Double(x[i]) * Double(x[i]) }
        return (sum / Double(max(1, range.count))).squareRoot()
    }

    @Test("C6: on a sorted kit, a closed hat 100 ms after an open hat leaves its tail ≤ −40 dB 30 ms later")
    func sortedKitHatsChoke() async throws {
        let url = try KitSliceCorpus.write()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let zones = try await Self.sortedCorpus(url).plan.zones
        #expect(zones.first { $0.rootPitch == 46 }?.chokeGroup == 0, "control: the open hat is in the hat group")
        // 46 at beat 0 for 2 beats (no note-off inside the window), 42 at +100 ms (0.2 beat at 120 BPM).
        let both = try await Self.play(zones, [(46, 0, 2), (42, 0.2, 0.25)])
        let closedAlone = try await Self.play(zones, [(42, 0.2, 0.25)])
        let openAlone = try await Self.play(zones, [(46, 0, 2)])
        let isolated = zip(both, closedAlone).map { $0 - $1 }
        let window = Int(0.130 * KitSliceCorpus.rate)..<Int(0.200 * KitSliceCorpus.rate)
        let free = Self.rms(openAlone, window)
        #expect(free > 1e-4, "control: unchoked, the open hat still rings in the window (\(free))")
        let tailDb = 20 * log10(max(Self.rms(isolated, window), 1e-30) / free)
        print("W46 C6 open-hat tail 130-200 ms: \(String(format: "%.1f", tailDb)) dB (bar -40)")
        #expect(tailDb <= -40)
        // Negative control: the same zones with no choke group leave the tail where it was.
        let unchoked = zones.map { zone -> SamplerZone in
            var copy = zone
            copy.chokeGroup = nil
            return copy
        }
        let bothFree = try await Self.play(unchoked, [(46, 0, 2), (42, 0.2, 0.25)])
        let closedFree = try await Self.play(unchoked, [(42, 0.2, 0.25)])
        let isolatedFree = zip(bothFree, closedFree).map { $0 - $1 }
        let freeDb = 20 * log10(max(Self.rms(isolatedFree, window), 1e-30) / free)
        #expect(abs(freeDb) < 1, "control: without the choke the tail is untouched (\(freeDb) dB)")
    }
}
