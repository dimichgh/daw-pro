import Foundation
import Testing
@testable import AIServices
@testable import DAWCore

// Shared fixtures for the SingJob* suites (p2-sing-e part 1). The file holds no tests: it is named
// `…Tests.swift` only because this lane's files are `Tests/AIServicesTests/SingJob*Tests.swift`.
// Everything here is nonisolated except the store builders, which are `@MainActor` functions (no
// `@Suite` is MainActor-isolated: the tree is at its `@MainActor` suite cap).

enum SingFixture {

    /// A fresh temp folder for one test.
    static func tempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sing-job-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The two-unit melody: two breath phrases of four contiguous one-beat notes, at beats 4 and 36
    /// (120 BPM: 2 s and 18 s). The whole span is more than the 15 s unit target, so the planner cuts
    /// between the phrases: unit 1 is "one two three four" (bar 2), unit 2 "five six seven eight"
    /// (bar 10).
    static let twoUnitOnsets: [Double] = [4, 5, 6, 7, 36, 37, 38, 39]
    static let twoUnitLyrics = "one two three four\nfive six seven eight"
    static let twoUnitPitches = [60, 62, 64, 65, 67, 65, 64, 62]

    /// A store with a WAV-reading media fake, a temp Generations folder under `root`, and one melody
    /// clip on an instrument track. Returns the store and the clip id.
    @MainActor
    static func store(root: URL, onsets: [Double] = twoUnitOnsets, pitches: [Int]? = nil,
                      lyrics: String? = twoUnitLyrics) throws -> (ProjectStore, UUID) {
        let store = ProjectStore()
        store.media = SingWAVMedia()
        store.generationImportsDirectory = root.appendingPathComponent("generations", isDirectory: true)
        let track = store.addTrack(kind: .instrument)
        let pitchList = pitches ?? twoUnitPitches
        let notes = onsets.enumerated().map { i, onset in
            MIDINote(pitch: pitchList[i % pitchList.count], startBeat: onset, lengthBeats: 1)
        }
        let length = (onsets.max() ?? 0) + 2
        let clip = try store.addMIDIClip(toTrack: track.id, name: "Melody", atBeat: 0, lengthBeats: length,
                                         notes: notes)
        if let lyrics { try setLyrics(store, clipID: clip.id, text: lyrics) }
        return (store, clip.id)
    }

    /// Writes `text` onto a clip directly, outside any undo step (no lyrics setter exists yet).
    @MainActor
    static func setLyrics(_ store: ProjectStore, clipID: UUID, text: String) throws {
        for t in store.tracks.indices {
            if let c = store.tracks[t].clips.firstIndex(where: { $0.id == clipID }) {
                store.tracks[t].clips[c].lyrics = ClipLyrics(text: text)
                return
            }
        }
        throw ProjectError.clipNotFound(clipID)
    }

    // MARK: Audio a facade would write

    enum Voice: Sendable, Equatable {
        /// A sine at every note's pitch, amplitude 0.1 (the stub's own render).
        case sine
        /// The same, `cents` off every note.
        case detuned(cents: Double)
        /// Uniform noise at the sine's level: audible, unpitched.
        case noise
        /// The sine, plus ONE full-scale sample in the middle (a click).
        case click
        /// A sine at amplitude 0.0005 (−66 dBFS) plus one full-scale sample: the ceiling holds the gain
        /// far below the target.
        case quietWithClick
        /// Every sample NaN.
        case nan
        /// All zeros.
        case silent
    }

    /// What a facade renders for `request`: `leadS`, the notes, `trailS`, on the 10 ms grid the
    /// facade's own converter rounds to (`scripts/sing/singlib/score.py`), plus `extraSeconds`.
    static func render(_ request: SingingPhraseRequest, voice: Voice = .sine, extraSeconds: Double = 0) -> [Float] {
        let rate = Double(request.outputSampleRate)
        let lastEnd = request.notes.map(\.endS).max() ?? 0
        let seconds = ((request.leadS + lastEnd + request.trailS) * 100).rounded() / 100 + extraSeconds
        let count = Int((seconds * rate).rounded())
        switch voice {
        case .nan: return [Float](repeating: .nan, count: count)
        case .silent: return [Float](repeating: 0, count: count)
        case .noise:
            var generator = SplitMix(seed: 0x5EED)
            return (0..<count).map { _ in Float(generator.unit() * 0.2 - 0.1) }
        default: break
        }
        var cents = 0.0
        var amplitude: Float = 0.1
        if case .detuned(let c) = voice { cents = c }
        if voice == .quietWithClick { amplitude = 0.0005 }
        var y = [Float](repeating: 0, count: count)
        for note in request.notes {
            let a = Int(((request.leadS + note.startS) * rate).rounded())
            let b = min(count, Int(((request.leadS + note.endS) * rate).rounded()))
            guard b > a else { continue }
            let f = 440 * pow(2, (Double(note.midi) - 69 + cents / 100) / 12)
            let w = 2 * Double.pi * f / rate
            let fade = max(1, min(Int(0.01 * rate), (b - a) / 2))
            for k in 0..<(b - a) {
                var g = 1.0
                if k < fade {
                    g = 0.5 - 0.5 * cos(Double.pi * Double(k) / Double(fade))
                } else if k >= (b - a) - fade {
                    g = 0.5 - 0.5 * cos(Double.pi * Double((b - a) - 1 - k) / Double(fade))
                }
                y[a + k] = amplitude * Float(g * sin(w * Double(k)))
            }
        }
        if voice == .click || voice == .quietWithClick, !y.isEmpty { y[y.count / 2] = 1.0 }
        return y
    }

    /// The facade's JSON answer for a WAV it wrote, through the client's own parser.
    static func result(for request: SingingPhraseRequest, samples: [Float], nonFinite: Bool = false)
        -> SingingRenderResult {
        let peak = samples.reduce(Float(0)) { $1.isFinite ? max($0, abs($1)) : $0 }
        let json: [String: Any] = [
            "outputPath": request.outputPath, "sampleRate": request.outputSampleRate, "channels": 1,
            "frames": samples.count, "durationS": Double(samples.count) / Double(request.outputSampleRate),
            "peak": Double(peak), "rms": 0.07, "nonFinite": nonFinite, "seed": request.seed,
            "nSteps": request.nSteps, "cfg": request.cfg,
        ]
        return SingingRenderResult(json: json)!
    }

    // MARK: A pitch tracker for sines (the tests' stand-in for SwiftF0)

    /// Frames every 10 ms over a 40 ms window: the frequency from the mean spacing of interpolated
    /// rising zero crossings, the confidence from how regular that spacing is (1 for a sine, ~0 for
    /// noise). Under −80 dBFS RMS, or fewer than 3 crossings: unvoiced. Accurate to well under a
    /// cent on the fixtures' sines, so the note check and gate L2 read real audio, not a script.
    static func frames(samples: [Float], sampleRate: Int) -> [ClipPitchFrame] {
        let rate = Double(sampleRate)
        let hop = max(1, Int(0.01 * rate))
        let window = max(2, Int(0.04 * rate))
        var frames: [ClipPitchFrame] = []
        var start = 0
        while start + window <= samples.count {
            let time = Double(start + window / 2) / rate
            var energy = 0.0
            for i in start..<(start + window) { energy += Double(samples[i]) * Double(samples[i]) }
            let rms = (energy / Double(window)).squareRoot()
            var crossings: [Double] = []
            if rms.isFinite, rms >= 1e-4 {
                for i in (start + 1)..<(start + window) {
                    let a = Double(samples[i - 1]), b = Double(samples[i])
                    if a < 0, b >= 0 { crossings.append(Double(i - 1) + (-a) / (b - a)) }
                }
            }
            if crossings.count >= 3 {
                let gaps = zip(crossings.dropFirst(), crossings).map { $0 - $1 }
                let mean = gaps.reduce(0, +) / Double(gaps.count)
                let spread = (gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)).squareRoot()
                let confidence = max(0, min(1, 1 - 5 * spread / mean))
                let hz = rate / mean
                if confidence >= 0.9, hz > 40, hz < 2_000 {
                    frames.append(ClipPitchFrame(timeSeconds: time, frequencyHz: hz, confidence: confidence,
                                                 levelDbfs: 20 * log10(rms), absence: nil))
                } else {
                    frames.append(ClipPitchFrame(timeSeconds: time, frequencyHz: nil, confidence: confidence,
                                                 levelDbfs: 20 * log10(rms), absence: .belowConfidence))
                }
            } else {
                frames.append(ClipPitchFrame(timeSeconds: time, frequencyHz: nil, confidence: 0,
                                             levelDbfs: nil, absence: .belowLevel))
            }
            start += hop
        }
        return frames
    }

    static func frames(at url: URL) throws -> [ClipPitchFrame] {
        let audio = try SingWAV.read(url)
        return frames(samples: audio.mono, sampleRate: audio.sampleRate)
    }

    /// Polls `condition` every 5 ms until it holds or `seconds` pass (a contention allowance, not a
    /// weakened assertion: every wait here is on work the test itself releases).
    static func waitUntil(_ seconds: Double = 20, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return try await condition()
    }
}

/// A deterministic generator for the noise fixture.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// `ProjectStore.media` for these tests: the duration is read from the WAV itself.
struct SingWAVMedia: MediaImporting {
    func audioFileInfo(at url: URL) throws -> AudioFileInfo {
        let audio = try SingWAV.read(url)
        return AudioFileInfo(durationSeconds: Double(audio.frameCount) / Double(audio.sampleRate),
                             sampleRate: Double(audio.sampleRate), channelCount: audio.channels.count)
    }
}

/// A one-shot latch a fake waits on until the test opens it.
actor SingLatch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
