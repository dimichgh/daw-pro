import AVFoundation
import Accelerate
import Foundation
import Testing

@testable import AIServices
@testable import DAWCore
@testable import DAWEngine

// W8-X9F3 (p2-sing-x9-f3): how far outside the built-in voice's band can the REAL singing engine sing a harmony part
// before it measurably degrades? A MEASUREMENT harness; it changes nothing in the product and decides nothing: the
// orchestrator reads the curve.
//
// ⛔ ENV-GATED. `X9F3_CAL=1` runs the instrument calibration (no engine). `X9F3_SWEEP=1` runs the sweep against ONE
// singing sidecar a driver script started on a TEST port (never 8004), reached through W8-X9R's rig (`X9RRig.make()`
// reads `X9R_PORT`/`X9R_OUT`/`X9R_WORK`/`X9R_CACHE_ROOT`). Every normal run skips both.
//
// The sweep: "a third above" on the X9R fixture (T1T2, 19 notes), the LEAD transposed by k semitones with the KEY moved
// with it (so the part's interval shape is constant), the part's octave PINNED (the question is what the engine can
// sing, not what the planner would choose), one sing job per point through the coordinator's parts path. The x value is
// `HarmonyPlanner.range(of:)` (which wraps `fit(of:)`): its candidate at the RENDERED octave. Each landed take is read
// directly (the take file starts at beat 0 for this fixture: `SingPlan.t0Seconds` = max(0, 0.24 s − lead)).
//
// Pre-registered in the lane's PREDICTIONS.md before the first render. NOT `@MainActor` (the tree is at its suite cap):
// the store hops to the main actor.

// MARK: - The source: the X9R line, transposed

enum X9F3Source {
    static let thirdAbove = HarmonySpec(interval: .third, direction: .above, chordSource: .none)
    static let leadSeed = SingJobRequestBuilder.firstTakeSeed
    static let altSeed = SingJobRequestBuilder.firstTakeSeed + 1

    static func key(_ k: Int) -> SongKey { SongKey(tonicPitchClass: ((k % 12) + 12) % 12, mode: .major) }

    /// `X9RSource.store` with every note moved k semitones.
    @MainActor
    static func store(root: URL, k: Int) throws -> (ProjectStore, UUID) {
        let store = ProjectStore()
        store.media = AudioFileImporter()
        store.generationImportsDirectory = root.appendingPathComponent("generations", isDirectory: true)
        let track = store.addTrack(kind: .instrument)
        let (base, lyrics, _) = X9RSource.line()
        let notes = base.map { n -> MIDINote in
            var m = n
            m.pitch += k
            return m
        }
        let clip = try store.addMIDIClip(toTrack: track.id, name: "Twinkle", atBeat: 0,
                                         lengthBeats: notes.map { $0.endBeat }.max() ?? 4, notes: notes)
        for t in store.tracks.indices {
            if let c = store.tracks[t].clips.firstIndex(where: { $0.id == clip.id }) {
                store.tracks[t].clips[c].lyrics = ClipLyrics(text: lyrics)
                return (store, clip.id)
            }
        }
        throw ProjectError.clipNotFound(clip.id)
    }
}

/// What the planner says about one point, read from the SAME calls the coordinator makes.
struct X9F3PlanInfo: Sendable {
    struct Note: Sendable {
        let leadMidi: Int
        let partMidi: Int
        let start: Double
        let end: Double
    }
    let k: Int
    let notes: [Note]
    let range: HarmonyRange

    static let band = (low: SingVoiceLibrary.builtInRange.p10Midi - VoiceRangeFit.defaultWeights.bandMarginSemitones,
                       high: SingVoiceLibrary.builtInRange.p90Midi + VoiceRangeFit.defaultWeights.bandMarginSemitones)

    func candidate(octave: Int) -> KeyFitCandidate? { range.candidates.first { $0.octaveShift == octave } }

    /// The largest single-note excursion beyond the band at `octave`: (below, above), semitones, 0 when inside.
    func excursion(octave: Int) -> (below: Double, above: Double) {
        let xs = notes.map { Double($0.partMidi + 12 * octave) }
        return (max(0, Self.band.low - (xs.min() ?? Self.band.low)), max(0, (xs.max() ?? Self.band.high) - Self.band.high))
    }

    func facts(octave: Int) -> [String: Any] {
        let c = candidate(octave: octave)
        let e = excursion(octave: octave)
        return [
            "k": k, "renderedOctave": octave,
            "oob": X9RMath.json(c?.outOfBandSemitones), "fractionBelow": X9RMath.json(c?.fractionBelowBand),
            "fractionAbove": X9RMath.json(c?.fractionAboveBand), "maxBelow": X9RMath.json(e.below),
            "maxAbove": X9RMath.json(e.above),
            "winnerOctave": range.fit?.octaveShift ?? 99, "winnerOob": X9RMath.json(range.fit?.outOfBandSemitones),
            "winnerFits": range.fits, "sentence": range.sentence ?? "-",
            "candidates": range.candidates.map { ["o": $0.octaveShift, "oob": X9RMath.json($0.outOfBandSemitones),
                                                  "cost": X9RMath.json($0.cost)] },
            "partMidi": notes.map(\.partMidi), "leadMidi": notes.map(\.leadMidi),
            "shape": notes.map { $0.partMidi - $0.leadMidi },
        ]
    }
}

// MARK: - The instruments

enum X9F3Read {
    static let confident = SingLandingGates.confidentFrame
    static let hnrFrame = 1_920            // 40 ms at 48 kHz
    static let hnrHop = 480                // 10 ms

    static func mono(_ url: URL) throws -> (samples: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw X9RError("cannot allocate a buffer for \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        guard let data = buffer.floatChannelData, channels > 0 else { throw X9RError("no float data in \(url.path)") }
        var out = [Float](repeating: 0, count: n)
        for c in 0..<channels {
            let p = data[c]
            for i in 0..<n { out[i] += p[i] / Float(channels) }
        }
        return (out, format.sampleRate)
    }

    /// The normalised cross-correlation of `n` samples at `start` with themselves `lag` later.
    static func nccf(_ x: UnsafeBufferPointer<Float>, start: Int, n: Int, lag: Int) -> Double {
        guard let base = x.baseAddress else { return 0 }
        var dot: Float = 0, e0: Float = 0, e1: Float = 0
        vDSP_dotpr(base + start, 1, base + start + lag, 1, &dot, vDSP_Length(n))
        vDSP_svesq(base + start, 1, &e0, vDSP_Length(n))
        vDSP_svesq(base + start + lag, 1, &e1, vDSP_Length(n))
        let d = (Double(e0) * Double(e1)).squareRoot()
        return d > 1e-20 ? Double(dot) / d : 0
    }

    /// The NCCF peak within ±10 % of the period `rate / f0`, refined by a parabola through the best lag and its
    /// neighbours. Nil when the frame and its longest lag do not fit inside `limit` samples.
    static func periodicity(_ x: UnsafeBufferPointer<Float>, start: Int, f0: Double, rate: Double, limit: Int) -> Double? {
        guard f0.isFinite, f0 > 0, rate / f0 < 1e6 else { return nil }
        let tau = rate / f0
        let lo = max(2, Int((0.9 * tau).rounded(.down)))
        let hi = Int((1.1 * tau).rounded(.up))
        guard hi > lo, start >= 0, start + hnrFrame + hi + 1 <= min(limit, x.count) else { return nil }
        var rs: [Double] = []
        for lag in (lo - 1)...(hi + 1) { rs.append(nccf(x, start: start, n: hnrFrame, lag: lag)) }
        var best = 1
        for i in 1..<(rs.count - 1) where rs[i] > rs[best] { best = i }
        let a = rs[best - 1], b = rs[best], c = rs[best + 1]
        let curve = a - 2 * b + c
        var peak = b
        if curve < 0 { peak = b - (c - a) * (c - a) / (8 * curve) }
        return min(max(peak, b), 0.999_999)
    }

    static func hnrDb(_ r: Double) -> Double {
        let r = min(max(r, 1e-6), 0.999_999)
        return 10 * log10(r / (1 - r))
    }

    /// An INDEPENDENT f0 per frame (not SwiftF0): the NCCF over lags for 60...2200 Hz; the SMALLEST-lag local peak within
    /// 90 % of the best (so a period's multiples never win), parabola-refined. (hz, r) or nil when the frame and its
    /// longest lag do not fit inside `limit` samples.
    static let acfMinHz = 60.0, acfMaxHz = 2_200.0, acfVoicedR = 0.5
    static func acf(_ x: UnsafeBufferPointer<Float>, start: Int, rate: Double, limit: Int) -> (hz: Double, r: Double)? {
        let lo = max(2, Int((rate / acfMaxHz).rounded(.down))), hi = Int((rate / acfMinHz).rounded(.up))
        guard start >= 0, start + hnrFrame + hi + 1 <= min(limit, x.count) else { return nil }
        var rs = [Double](repeating: 0, count: hi + 2)
        for lag in (lo - 1)...(hi + 1) { rs[lag] = nccf(x, start: start, n: hnrFrame, lag: lag) }
        var best = lo
        for lag in lo...hi where rs[lag] > rs[best] { best = lag }
        guard rs[best] > 0 else { return nil }
        var pick = best
        for lag in lo...hi where rs[lag] >= 0.9 * rs[best] && rs[lag] >= rs[lag - 1] && rs[lag] >= rs[lag + 1] {
            pick = lag
            break
        }
        let a = rs[pick - 1], b = rs[pick], c = rs[pick + 1]
        let curve = a - 2 * b + c
        // A parabola through a true local peak moves it at most half a lag; the fallback (`best` at an edge) may not be
        // one, so the step is clamped (an unclamped step once produced a negative period and a crashing range).
        let delta = curve < 0 ? min(0.5, max(-0.5, 0.5 * (a - c) / curve)) : 0
        let hz = rate / (Double(pick) + delta)
        guard hz.isFinite, hz > 0 else { return nil }
        return (hz, b)
    }

    /// The independent instrument over `[a, b]` seconds: (median Hz of voiced frames, voiced share, frames, and the
    /// median HNR of the voiced frames at the ACF's own period, with how many frames gave one).
    static func acfNote(_ x: UnsafeBufferPointer<Float>, rate: Double, from a: Double, to b: Double)
    -> (hz: Double?, voiced: Double, frames: Int, hnr: Double?, hnrFrames: Int) {
        let first = Int((a * rate).rounded(.up)), limit = Int((b * rate).rounded(.down))
        var hz: [Double] = []
        var hnrs: [Double] = []
        var total = 0
        var start = first
        while start + hnrFrame < limit {
            if let reading = acf(x, start: start, rate: rate, limit: limit) {
                total += 1
                if reading.r >= acfVoicedR {
                    hz.append(reading.hz)
                    if let r = periodicity(x, start: start, f0: reading.hz, rate: rate, limit: limit) {
                        hnrs.append(hnrDb(r))
                    }
                }
            }
            start += hnrHop
        }
        return (X9RMath.median(hz), total > 0 ? Double(hz.count) / Double(total) : 0, total, X9RMath.median(hnrs),
                hnrs.count)
    }

    /// Median HNR (dB) over the frames that fit inside `[a, b]` seconds, each guided by `f0At(centre seconds)`.
    static func hnr(_ x: UnsafeBufferPointer<Float>, rate: Double, from a: Double, to b: Double,
                    f0At: (Double) -> Double?) -> (median: Double?, frames: Int) {
        let first = Int((a * rate).rounded(.up)), limit = Int((b * rate).rounded(.down))
        var values: [Double] = []
        var start = first
        while start + hnrFrame < limit {
            let centre = (Double(start) + Double(hnrFrame) / 2) / rate
            if let f0 = f0At(centre), f0 > 20,
               let r = periodicity(x, start: start, f0: f0, rate: rate, limit: limit) {
                values.append(hnrDb(r))
            }
            start += hnrHop
        }
        return (X9RMath.median(values), values.count)
    }

    /// The voiced, confident SwiftF0 frame whose centre is nearest `t` (within one hop), as a guide for the HNR.
    static func guide(_ d: PitchDetectionResult) -> (Double) -> Double? {
        let half = 0.5 / d.frameRateHz
        let hop = 1 / d.frameRateHz
        let frames = d.frames
        return { t in
            let i = Int(((t - half) * d.frameRateHz).rounded())
            let lo = max(0, i - 1), hi = min(frames.count - 1, i + 1)
            guard lo <= hi else { return nil }
            var best: ClipPitchFrame?
            for j in lo...hi {
                let f = frames[j]
                guard f.frequencyHz != nil, f.confidence >= confident, abs(f.timeSeconds + half - t) <= hop else { continue }
                if best == nil || abs(f.timeSeconds + half - t) < abs(best!.timeSeconds + half - t) { best = f }
            }
            return best?.frequencyHz
        }
    }

    struct Target: Sendable {
        let midi: Int
        let start: Double
        let end: Double
        var hz: Double { 440 * pow(2, Double(midi - 69) / 12) }
    }

    /// Everything one take says, against `targets` (take-relative seconds; MIDDLE 50 % of each note, the product's
    /// `SingNoteCheck` window, frame START times like the product).
    static func take(_ url: URL, targets: [Target]) throws -> [String: Any] {
        let (samples, rate) = try mono(url)
        let detection = try PitchContourCache.detectWholeFile(url, .product)
        let f0At = guide(detection)
        var rows: [[String: Any]] = []
        var hits = 0, pcMatches = 0, pitched = 0
        var absCents: [Double] = []
        var voiced = 0, total = 0
        var hnrs: [Double] = []
        var jitters: [Double] = []
        var acfHits = 0, acfPc = 0, acfPitched = 0, acfCounted = 0
        var acfAbs: [Double] = []
        var acfVoicedSum = 0.0
        var acfHnrs: [Double] = []
        samples.withUnsafeBufferPointer { x in
            for target in targets {
                let quarter = (target.end - target.start) / 4
                let a = target.start + quarter, b = target.end - quarter
                let window = detection.frames.filter { $0.timeSeconds >= a && $0.timeSeconds < b }
                let good = window.filter { $0.frequencyHz != nil && $0.confidence >= confident }
                voiced += good.count
                total += window.count
                var row: [String: Any] = ["midi": target.midi, "start": target.start, "end": target.end,
                                          "frames": window.count, "voiced": good.count]
                if let median = X9RMath.median(good.compactMap(\.frequencyHz)) {
                    let cents = 1200 * log2(median / target.hz)
                    let semis = Int((cents / 100).rounded())
                    pitched += 1
                    absCents.append(abs(cents))
                    if abs(cents) <= SingNoteCheck.hitCents { hits += 1 }
                    if ((semis % 12) + 12) % 12 == 0 { pcMatches += 1 }
                    row["hz"] = X9RMath.json(median)
                    row["cents"] = X9RMath.json(cents)
                    row["hit"] = abs(cents) <= SingNoteCheck.hitCents
                    row["octaveOff"] = ((semis % 12) + 12) % 12 == 0 ? semis / 12 : NSNull()
                }
                let track = good.compactMap(\.frequencyHz)
                if track.count >= 3 {
                    var d2 = 0.0
                    for i in 1..<track.count { d2 += pow(1200 * log2(track[i] / track[i - 1]), 2) }
                    let jitter = (d2 / Double(track.count - 1)).squareRoot()
                    jitters.append(jitter)
                    row["jitterCents"] = X9RMath.json(jitter)
                }
                let acfReading = acfNote(x, rate: rate, from: a, to: b)
                row["acfFrames"] = acfReading.frames
                row["acfVoiced"] = X9RMath.json(acfReading.voiced)
                row["acfHnrDb"] = X9RMath.json(acfReading.hnr)
                if let m = acfReading.hnr, acfReading.hnrFrames >= 3 { acfHnrs.append(m) }
                if acfReading.frames > 0 {
                    acfVoicedSum += acfReading.voiced
                    acfCounted += 1
                }
                if let hz = acfReading.hz {
                    let cents = 1200 * log2(hz / target.hz)
                    let semis = Int((cents / 100).rounded())
                    acfPitched += 1
                    acfAbs.append(abs(cents))
                    if abs(cents) <= SingNoteCheck.hitCents { acfHits += 1 }
                    if ((semis % 12) + 12) % 12 == 0 { acfPc += 1 }
                    row["acfHz"] = X9RMath.json(hz)
                    row["acfCents"] = X9RMath.json(cents)
                }
                let h = hnr(x, rate: rate, from: a, to: b, f0At: f0At)
                row["hnrDb"] = X9RMath.json(h.median)
                row["hnrFrames"] = h.frames
                if let m = h.median, h.frames >= 3 { hnrs.append(m) }
                rows.append(row)
            }
        }
        let loud = Loudness.measure(RenderedAudio(sampleRate: rate, channelData: [samples]))
        let n = Double(targets.count)
        return [
            "notes": rows, "rate": rate, "seconds": Double(samples.count) / rate,
            "hitRate": X9RMath.json(Double(hits) / n), "hits": hits, "pitched": pitched,
            "pcMatchRate": X9RMath.json(Double(pcMatches) / n),
            "meanAbsCentsAll": X9RMath.json(absCents.isEmpty ? nil : absCents.reduce(0, +) / Double(absCents.count)),
            "coverage": X9RMath.json(total > 0 ? Double(voiced) / Double(total) : nil),
            "hnrDb": X9RMath.json(X9RMath.median(hnrs)), "hnrNotes": hnrs.count,
            "jitterCents": X9RMath.json(X9RMath.median(jitters)),
            "lufs": X9RMath.json(loud.integratedLufs), "truePeakDbtp": X9RMath.json(loud.truePeakDbtp),
            "voicedFractionWholeFile": X9RMath.json(detection.voicedFraction),
            "acfHitRate": X9RMath.json(Double(acfHits) / n), "acfPitched": acfPitched,
            "acfPcMatchRate": X9RMath.json(Double(acfPc) / n),
            "acfMeanAbsCentsAll": X9RMath.json(acfAbs.isEmpty ? nil : acfAbs.reduce(0, +) / Double(acfAbs.count)),
            "acfCoverage": X9RMath.json(acfCounted > 0 ? acfVoicedSum / Double(acfCounted) : nil),
            "acfHnrDb": X9RMath.json(X9RMath.median(acfHnrs)), "acfHnrNotes": acfHnrs.count,
        ]
    }

    /// A harmonic tone (1/n partials below 0.45·rate), fixed phases, peak-normalised to 0.5.
    static func tone(hz: Double, seconds: Double, rate: Double) -> [Float] {
        let count = Int(seconds * rate)
        var out = [Float](repeating: 0, count: count)
        let partials = (1...12).filter { Double($0) * hz < 0.45 * rate }
        for i in 0..<count {
            let t = Double(i) / rate
            var v = 0.0
            for p in partials { v += sin(2 * .pi * Double(p) * hz * t + 0.7 * Double(p)) / Double(p) }
            out[i] = Float(v)
        }
        var peak: Float = 0
        vDSP_maxmgv(out, 1, &peak, vDSP_Length(count))
        guard peak > 0 else { return out }
        let gain = 0.5 / peak
        return out.map { $0 * gain }
    }

    /// A sung-vowel-like tone: harmonics shaped by three /a/-like formants (800, 1150, 2900 Hz) over a 1/n tilt, zero
    /// phases, every partial below 0.45·rate (at most 60), peak-normalised to 0.5.
    static func vowel(hz: Double, seconds: Double, rate: Double) -> [Float] {
        let count = Int(seconds * rate)
        let formants: [(f: Double, bw: Double)] = [(800, 80), (1_150, 90), (2_900, 120)]
        let partials = (1...60).filter { Double($0) * hz < 0.45 * rate }
        let gains = partials.map { p -> Double in
            let f = Double(p) * hz
            return (0.2 + formants.reduce(0.0) { $0 + 1 / (1 + pow((f - $1.f) / $1.bw, 2)) }) / Double(p)
        }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / rate
            var v = 0.0
            for (p, gain) in zip(partials, gains) { v += gain * sin(2 * .pi * Double(p) * hz * t) }
            out[i] = Float(v)
        }
        var peak: Float = 0
        vDSP_maxmgv(out, 1, &peak, vDSP_Length(count))
        guard peak > 0 else { return out }
        let scale = 0.5 / peak
        return out.map { $0 * scale }
    }

    /// Seeded white Gaussian noise at `snrDb` below `signal`'s mean power (SplitMix64 + Box-Muller).
    static func withNoise(_ signal: [Float], snrDb: Double, seed: UInt64) -> [Float] {
        var state = seed
        func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return (Double(z >> 11) + 0.5) / Double(1 << 53)
        }
        var power: Float = 0
        vDSP_measqv(signal, 1, &power, vDSP_Length(signal.count))
        let sigma = (Double(power) / pow(10, snrDb / 10)).squareRoot()
        return signal.map { s in
            let g = (-2 * log(next())).squareRoot() * cos(2 * .pi * next())
            return s + Float(sigma * g)
        }
    }
}

// MARK: - One job, one point

extension X9RRig {
    /// ONE sing job on a fresh store holding the line moved `k` semitones, with ONE third-above part; returns the landed
    /// job and the planner's own reading of the part (the coordinator's `derive` and `range(of:)` calls).
    func x9f3Job(_ label: String, k: Int, seed: UInt64?, octave: Int?, cache: SingPhraseCache,
                 note: (String) -> Void) async throws -> (X9RLanded, X9F3PlanInfo) {
        guard Date() < deadline else { throw X9RError("the wall-clock budget was spent before job \(label)") }
        let root = work.appendingPathComponent("jobs/\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let spec = X9F3Source.thirdAbove
        let key = X9F3Source.key(k)
        let (store, clipID, info) = try await MainActor.run { () throws -> (ProjectStore, UUID, X9F3PlanInfo) in
            let (store, clipID) = try X9F3Source.store(root: root, k: k)
            guard let track = store.tracks.first(where: { $0.clips.contains { $0.id == clipID } }),
                  let clip = track.clips.first(where: { $0.id == clipID }) else { throw ProjectError.clipNotFound(clipID) }
            let tempo = store.transport.tempoMap
            let plan = try SungVocalDerivedPart.derive(.harmony(spec), givenKey: key, partIndex: 1, clip: clip,
                                                       on: track, tracks: store.tracks, tempoMap: tempo)
            let range = HarmonyPlanner.range(of: plan, clipStartBeat: clip.startBeat, tempoMap: tempo,
                                             voice: SingJobVoice.builtIn.range, leadOctaveShift: 0)
            let notes = plan.notes.sorted { $0.startBeat < $1.startBeat }.map {
                X9F3PlanInfo.Note(leadMidi: $0.leadPitch, partMidi: $0.pitch,
                                  start: tempo.seconds(from: 0, to: clip.startBeat + $0.startBeat),
                                  end: tempo.seconds(from: 0, to: clip.startBeat + $0.startBeat + $0.lengthBeats))
            }
            return (store, clipID, X9F3PlanInfo(k: k, notes: notes, range: range))
        }
        let detect: @Sendable (URL) async throws -> [ClipPitchFrame] = { url in
            let seconds = try SingVoiceAudioDecoder.durationSeconds(of: url)
            return try await Task.detached(priority: .userInitiated) {
                try ClipPitchAnalyzer.detect(
                    fileAt: url, fromSeconds: 0, durationSeconds: seconds,
                    confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
                    silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs).frames
            }.value
        }
        let configuration = SingJobCoordinator.Configuration(
            modelPollSeconds: 0.05, enginePollSeconds: 0.05, songGeneratorRunsOutside: { false })
        let coordinator = SingJobCoordinator(
            store: store, engine: engine, synthesizer: synth, lifecycle: lifecycle, cache: cache,
            detectPitch: detect, transcribe: { _ in nil }, configuration: configuration)
        let started = Date()
        let parts = [SingJobPart(.harmony(spec), seed: seed, octaveShift: octave)]
        let id = try await coordinator.submit(SingJobRequest(clipID: clipID, parts: parts, key: key)).jobID
        let jobDeadline = min(deadline, Date().addingTimeInterval(600))
        var status = try await coordinator.status(jobID: id)
        while !status.phase.isTerminal {
            if Date() > jobDeadline {
                throw X9RError("job \(label) did not end in time: \(status.phase.rawValue) \(status.stageText)")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            status = try await coordinator.status(jobID: id)
        }
        let checks = Date().addingTimeInterval(120)
        while await coordinator.isBusy(), Date() < checks { try await Task.sleep(nanoseconds: 100_000_000) }
        status = try await coordinator.status(jobID: id)
        guard status.phase == .done, let result = status.result else {
            throw X9RError("job \(label) ended \(status.phase.rawValue): \(status.error?.code ?? "-") "
                           + "\(status.error?.message ?? "") \(status.error?.detail ?? "") parts "
                           + "\((status.parts ?? []).map { "\($0.role) \($0.state.rawValue) \($0.error?.code ?? "-")" })")
        }
        let (tracks, tempo) = await MainActor.run { (store.tracks, store.transport.tempoMap) }
        let sung = tracks.filter { $0.kind == .audio }
        guard let lead = sung.first(where: { $0.id == result.trackID }) else {
            throw X9RError("job \(label): the lead track \(result.trackID) is not in the store")
        }
        let partIDs = (status.parts ?? []).filter { $0.role != SingJobPartStatusRoles.lead }.compactMap(\.trackID)
        let partTracks = partIDs.compactMap { pid in sung.first { $0.id == pid } }
        guard partTracks.count == 1 else {
            let rows = (status.parts ?? []).map {
                "\($0.role) \($0.state.rawValue) o\($0.octaveShift) \($0.error?.code ?? "-") \($0.error?.message ?? "") "
                    + "\($0.error?.detail ?? "") warnings \($0.warnings)"
            }
            throw X9RError("job \(label): \(partTracks.count) part tracks landed for 1; job warnings \(status.warnings); "
                           + "notices \(status.notices); parts \(rows)")
        }
        note("job \(label): done in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, cached "
             + "\(status.cachedUnits), rendered \(status.renderedUnits)")
        return (X9RLanded(label: label, status: status, tracks: sung, tempo: tempo, lead: lead, parts: partTracks), info)
    }
}

// MARK: - The report

final class X9F3Report {
    var meta: [String: Any] = [:]
    var controls: [String: Any] = [:]
    var rows: [[String: Any]] = []
    let url: URL
    init(url: URL) { self.url = url }
    func write() {
        let object: [String: Any] = ["meta": meta, "controls": controls, "points": rows]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}

@Suite("W8-X9F3 harmony fit tolerance on the real singing engine (X9F3_CAL=1 / X9F3_SWEEP=1 only)")
struct SingHarmonyToleranceSweepX9F3Tests {

    static let env = ProcessInfo.processInfo.environment
    static let sweepEnabled = env["X9F3_SWEEP"] == "1"
    static let calibrationEnabled = env["X9F3_CAL"] == "1"
    static func f(_ x: Any?) -> String { (x as? Double).map { String(format: "%.2f", $0) } ?? "nil" }

    static func note(_ line: String) {
        print("x9f3| \(line)")
        guard let path = env["X9F3_STATUS"], let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withFullTime, .withSpaceBetweenDateAndTime])
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(stamp) W8-X9F3 \(line)\n".utf8))
    }

    // MARK: The instruments, on known signals (no engine)

    @Test("X9F3: SwiftF0 range and the HNR estimator on synthetic tones",
          .enabled(if: SingHarmonyToleranceSweepX9F3Tests.calibrationEnabled))
    func instrumentCalibration() throws {
        guard let outPath = Self.env["X9F3_OUT"] else { throw X9RError("X9F3_OUT must be set") }
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        let dir = out.appendingPathComponent("calibration", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rate = 48_000.0
        let pad = [Float](repeating: 0, count: Int(0.3 * rate))
        let interior = (0.3 + 0.1)...(0.3 + 1.2 - 0.1)
        var rows: [[String: Any]] = []
        for midi in [40, 48, 52, 57, 64, 72, 76, 78, 84, 88, 96] {
            let hz = 440 * pow(2, Double(midi - 69) / 12)
            let clean = pad + X9F3Read.tone(hz: hz, seconds: 1.2, rate: rate) + pad
            var row: [String: Any] = ["midi": midi, "hz": hz]
            var guided: [String: Any] = [:], detected: [String: Any] = [:], acfGuided: [String: Any] = [:]
            let variants: [(name: String, snr: Double?)] = [("clean", nil), ("snr10", 10), ("snr0", 0)]
            for (name, snr) in variants {
                let signal = snr.map { X9F3Read.withNoise(clean, snrDb: $0, seed: UInt64(midi) &* 7_919) } ?? clean
                let url = dir.appendingPathComponent("tone-\(midi)-\(name).wav")
                try M23QComparisonPair.writeWAV([signal], sampleRate: rate, to: url)
                let d = try PitchContourCache.detectWholeFile(url, .product)
                let span = X9RMath.voicedSpan(d, within: interior)
                let median = X9RMath.noteHz(d, from: interior.lowerBound, to: interior.upperBound).hz
                if name == "clean" {
                    row["swiftF0Voiced"] = X9RMath.json(span.coverage)
                    row["swiftF0ErrorCents"] = X9RMath.json(median.map { 1200 * log2($0 / hz) })
                }
                signal.withUnsafeBufferPointer { x in
                    guided[name] = X9RMath.json(X9F3Read.hnr(x, rate: rate, from: interior.lowerBound,
                                                             to: interior.upperBound, f0At: { _ in hz }).median)
                    detected[name] = X9RMath.json(X9F3Read.hnr(x, rate: rate, from: interior.lowerBound,
                                                               to: interior.upperBound, f0At: X9F3Read.guide(d)).median)
                    acfGuided[name] = X9RMath.json(X9F3Read.acfNote(x, rate: rate, from: interior.lowerBound,
                                                                    to: interior.upperBound).hnr)
                }
            }
            let voicedOK = ((row["swiftF0Voiced"] as? Double) ?? 0) >= 0.90
            let errOK = abs((row["swiftF0ErrorCents"] as? Double) ?? 999) <= 10
            let c = guided["clean"] as? Double ?? -99, n10 = guided["snr10"] as? Double ?? -99
            let n0 = guided["snr0"] as? Double ?? -99
            let hnrOK = c >= 25 && abs(n10 - 10) <= 2 && abs(n0 - 0) <= 2
            var agree = true
            for name in ["clean", "snr10", "snr0"] {
                if let a = guided[name] as? Double, let b = detected[name] as? Double, abs(a - b) > 1,
                   !(name == "clean" && a >= 25 && b >= 25) { agree = false }
            }
            row["hnrTrueF0"] = guided
            row["hnrSwiftF0"] = detected
            row["hnrAcf"] = acfGuided
            row["detectorPass"] = voicedOK && errOK
            row["hnrPass"] = hnrOK
            row["guidesAgree"] = agree
            rows.append(row)
            Self.note("calibration MIDI \(midi): SwiftF0 voiced \(Self.f(row["swiftF0Voiced"])) err "
                      + "\(Self.f(row["swiftF0ErrorCents"])) c; HNR true-f0 clean/10/0 \(Self.f(c))/\(Self.f(n10))/"
                      + "\(Self.f(n0)) dB; SwiftF0-guided \(Self.f(detected["clean"]))/\(Self.f(detected["snr10"]))/"
                      + "\(Self.f(detected["snr0"])); ACF-guided \(Self.f(acfGuided["clean"]))/"
                      + "\(Self.f(acfGuided["snr10"]))/\(Self.f(acfGuided["snr0"])); detector \(voicedOK && errOK ? "PASS" : "FAIL"), "
                      + "HNR \(hnrOK ? "PASS" : "FAIL"), guides \(agree ? "agree" : "DISAGREE")")
        }
        // ---- B: the two pitch instruments (SwiftF0 = the product's; ACF = independent) over the whole pitch span, on
        // three waveforms. Recorded; the ACF's pass is pre-registered (PREDICTIONS.md amendment A1).
        var scan: [[String: Any]] = []
        let midis = Array(stride(from: 40, through: 96, by: 2)) + [65, 67, 69, 71, 73, 75, 77, 79]
        for midi in midis.sorted() {
            let hz = 440 * pow(2, Double(midi - 69) / 12)
            let shapes: [(String, [Float])] = [
                ("sine-phases", X9F3Read.tone(hz: hz, seconds: 1.2, rate: rate)),
                ("saw-fixture", PitchTrackerAccuracyTests.Fixture.tone(seconds: 1.2, sampleRate: rate, f0: { _ in hz })),
                ("vowel-a", X9F3Read.vowel(hz: hz, seconds: 1.2, rate: rate)),
            ]
            for (shape, body) in shapes {
                let signal = pad + body + pad
                let url = dir.appendingPathComponent("scan-\(midi)-\(shape).wav")
                try M23QComparisonPair.writeWAV([signal], sampleRate: rate, to: url)
                let d = try PitchContourCache.detectWholeFile(url, .product)
                let frames = d.frames.filter { interior.contains($0.timeSeconds) }
                let confident = frames.filter { $0.frequencyHz != nil && $0.confidence >= X9F3Read.confident }
                let swiftHz = X9RMath.median(confident.compactMap(\.frequencyHz))
                let acf = signal.withUnsafeBufferPointer {
                    X9F3Read.acfNote($0, rate: rate, from: interior.lowerBound, to: interior.upperBound)
                }
                let swiftErr = swiftHz.map { 1200 * log2($0 / hz) }
                let acfErr = acf.hz.map { 1200 * log2($0 / hz) }
                let swiftVoiced = frames.isEmpty ? 0 : Double(confident.count) / Double(frames.count)
                scan.append(["midi": midi, "shape": shape,
                             "swiftF0Voiced": X9RMath.json(swiftVoiced), "swiftF0ErrorCents": X9RMath.json(swiftErr),
                             "swiftF0MeanConfidence": X9RMath.json(frames.isEmpty ? nil
                                 : frames.map(\.confidence).reduce(0, +) / Double(frames.count)),
                             "acfVoiced": X9RMath.json(acf.voiced), "acfErrorCents": X9RMath.json(acfErr),
                             "acfPass": acf.voiced >= 0.9 && abs(acfErr ?? 999) <= 5,
                             "swiftF0Pass": swiftVoiced >= 0.9 && abs(swiftErr ?? 999) <= 20])
            }
            let mine = scan.suffix(3)
            Self.note("scan MIDI \(midi): SwiftF0 (voiced/err c) " + mine.map {
                "\($0["shape"]!) \(Self.f($0["swiftF0Voiced"]))/\(Self.f($0["swiftF0ErrorCents"]))" }.joined(separator: ", ")
                + " | ACF " + mine.map { "\(Self.f($0["acfVoiced"]))/\(Self.f($0["acfErrorCents"]))" }.joined(separator: ", "))
        }
        // ---- C: replay real takes through `X9F3Read.take` (X9F3_REPLAY = "path@octave,…"): the k = 0 third-above
        // targets moved by whole octaves. Proves the reader survives the take that crashed run 1 (pc-oct-2).
        var replay: [[String: Any]] = []
        if let list = Self.env["X9F3_REPLAY"], !list.isEmpty {
            let line = X9RSource.line()
            let plan = HarmonyPlanner.notes(lead: line.notes, spec: X9F3Source.thirdAbove, key: X9F3Source.key(0),
                                            partIndex: 1, chordAt: { _ in nil })
            let pitches = plan.notes.sorted { $0.startBeat < $1.startBeat }.map(\.pitch)
            for item in list.split(separator: ",") {
                let bits = item.split(separator: "@")
                guard bits.count == 2, let octave = Int(bits[1]) else { continue }
                let targets = zip(pitches, line.timeline).map {
                    X9F3Read.Target(midi: $0.0 + 12 * octave, start: $0.1.start, end: $0.1.end)
                }
                let reading = try X9F3Read.take(URL(fileURLWithPath: String(bits[0])), targets: targets)
                replay.append(["path": String(bits[0]), "octave": octave, "reading": reading])
                Self.note("replay \(URL(fileURLWithPath: String(bits[0])).lastPathComponent) @\(octave): ACF hit "
                          + "\(Self.f(reading["acfHitRate"])), cov \(Self.f(reading["acfCoverage"])), HNR "
                          + "\(Self.f(reading["acfHnrDb"])) dB; SwiftF0 hit \(Self.f(reading["hitRate"])), cov "
                          + "\(Self.f(reading["coverage"]))")
            }
        }
        let object: [String: Any] = ["rows": rows, "scan": scan, "replay": replay, "rate": rate,
                                     "frame": X9F3Read.hnrFrame, "hop": X9F3Read.hnrHop]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("calibration.json"))
        // Pre-registered: the HNR estimator passes over the sweep's own range (part notes 52...78). Amendment A1 (made
        // after SwiftF0 failed its own range check, BEFORE any engine render): the INDEPENDENT pitch instrument must
        // pass on every waveform over 40...96 (the sweep and both positive controls); SwiftF0 is recorded, not asserted.
        for row in rows {
            let midi = row["midi"] as? Int ?? 0
            guard (52...78).contains(midi) else { continue }
            #expect(row["hnrPass"] as? Bool == true, "HNR calibration failed at MIDI \(midi): \(row)")
        }
        for row in scan {
            #expect(row["acfPass"] as? Bool == true, "the independent pitch instrument failed: \(row)")
        }
    }

    // MARK: The sweep

    @Test("X9F3: a third above, k semitones off, octave pinned, sung by the real engine",
          .enabled(if: SingHarmonyToleranceSweepX9F3Tests.sweepEnabled))
    func sweep() async throws {
        let rig = try await X9RRig.make()
        let report = X9F3Report(url: rig.out.appendingPathComponent("sweep.json"))
        let stems = rig.out.appendingPathComponent("stems", isDirectory: true)
        try FileManager.default.createDirectory(at: stems, withIntermediateDirectories: true)
        report.meta = ["health": rig.health, "startedAt": ISO8601DateFormatter().string(from: Date()),
                       "leadSeed": Int(X9F3Source.leadSeed), "altSeed": Int(X9F3Source.altSeed),
                       "band": [X9F3PlanInfo.band.low, X9F3PlanInfo.band.high],
                       "voice": ["p10": SingVoiceLibrary.builtInRange.p10Midi,
                                 "median": SingVoiceLibrary.builtInRange.medianMidi,
                                 "p90": SingVoiceLibrary.builtInRange.p90Midi],
                       "weights": ["margin": VoiceRangeFit.defaultWeights.bandMarginSemitones,
                                   "tolerance": VoiceRangeFit.defaultWeights.octaveOnlyAcceptOutOfBand]]
        report.write()

        // One point: the job, then both takes read. Never throws: an engine refusal at an extreme is a finding.
        func point(_ label: String, k: Int, seed: UInt64?, octave: Int?, cache: SingPhraseCache,
                   group: String) async -> [String: Any] {
            var row: [String: Any] = ["label": label, "group": group, "k": k, "seed": seed.map { Int($0) } ?? -1,
                                      "pinnedOctave": octave ?? 99]
            do {
                let (j, info) = try await rig.x9f3Job(label, k: k, seed: seed, octave: octave, cache: cache,
                                                      note: Self.note)
                let partStatus = (j.status.parts ?? []).first { $0.role != SingJobPartStatusRoles.lead }
                let rendered = partStatus?.octaveShift ?? octave ?? 0
                let part = j.parts[0]
                let partClipBeat = part.clips.first?.startBeat ?? -1
                let leadClipBeat = j.lead.clips.first?.startBeat ?? -1
                let shift = j.tempo.seconds(from: 0, to: max(0, partClipBeat))
                let targets = info.notes.map {
                    X9F3Read.Target(midi: $0.partMidi + 12 * rendered, start: $0.start - shift, end: $0.end - shift)
                }
                let leadShift = j.tempo.seconds(from: 0, to: max(0, leadClipBeat))
                let leadTargets = info.notes.map {
                    X9F3Read.Target(midi: $0.leadMidi, start: $0.start - leadShift, end: $0.end - leadShift)
                }
                guard let partURL = j.partTake(), let leadURL = j.leadTake else { throw X9RError("a take is missing") }
                let partStem = stems.appendingPathComponent("\(label)-part.wav")
                let leadStem = stems.appendingPathComponent("\(label)-lead.wav")
                for (from, to) in [(partURL, partStem), (leadURL, leadStem)] {
                    try? FileManager.default.removeItem(at: to)
                    try FileManager.default.copyItem(at: from, to: to)
                }
                row["plan"] = info.facts(octave: rendered)
                row["renderedOctave"] = rendered
                row["clipStartBeats"] = ["part": partClipBeat, "lead": leadClipBeat]
                row["job"] = j.facts
                row["partStatus"] = ["octaveShift": partStatus?.octaveShift ?? 99, "fits": partStatus?.fits ?? false]
                row["shas"] = ["part": X9RMath.fileSha(partURL), "lead": X9RMath.fileSha(leadURL)]
                row["stems"] = ["part": partStem.path, "lead": leadStem.path]
                let accuracy = part.sungVocalProvenance?.noteAccuracy
                row["productPart"] = ["hitRate": X9RMath.json(accuracy?.hitRate),
                                      "meanAbsErrorCents": X9RMath.json(accuracy?.meanAbsErrorCents),
                                      "voicedCoverage": X9RMath.json(accuracy?.voicedCoverage),
                                      "inTune": accuracy?.inTune ?? false,
                                      "appliedGainDb": X9RMath.json(part.sungVocalProvenance?.loudness?.appliedGainDb)]
                let leadAccuracy = j.lead.sungVocalProvenance?.noteAccuracy
                row["productLead"] = ["hitRate": X9RMath.json(leadAccuracy?.hitRate),
                                      "voicedCoverage": X9RMath.json(leadAccuracy?.voicedCoverage),
                                      "inTune": leadAccuracy?.inTune ?? false]
                let reading = try X9F3Read.take(partURL, targets: targets)
                row["part"] = reading
                if group == "control-k0" && seed == nil && octave == 0 {
                    // The hit-rate instrument's negative control: the same take against WRONG targets.
                    let wrong = targets.map { X9F3Read.Target(midi: $0.midi + 2, start: $0.start, end: $0.end) }
                    let w = try X9F3Read.take(partURL, targets: wrong)
                    report.controls["hitRateWrongTargets"] = [
                        "hitRate": w["hitRate"] ?? NSNull(), "acfHitRate": w["acfHitRate"] ?? NSNull(),
                        "pass": ((w["hitRate"] as? Double) ?? 1) <= 0.10 && ((w["acfHitRate"] as? Double) ?? 1) <= 0.10]
                }
                row["leadReading"] = try X9F3Read.take(leadURL, targets: leadTargets)
                let p = row["plan"] as? [String: Any] ?? [:]
                Self.note("\(label): oob \(Self.f(p["oob"])) (o \(rendered)), hit \(Self.f(reading["hitRate"])) "
                          + "(product \(Self.f(accuracy?.hitRate))), |c| \(Self.f(reading["meanAbsCentsAll"])), "
                          + "cov \(Self.f(reading["coverage"])), HNR \(Self.f(reading["hnrDb"])) dB | ACF hit "
                          + "\(Self.f(reading["acfHitRate"])), |c| \(Self.f(reading["acfMeanAbsCentsAll"])), cov "
                          + "\(Self.f(reading["acfCoverage"])), HNR \(Self.f(reading["acfHnrDb"])) dB | "
                          + "TP \(Self.f(reading["truePeakDbtp"])), LUFS \(Self.f(reading["lufs"]))")
            } catch {
                row["error"] = "\(error)"
                Self.note("\(label): ERROR \(error)")
            }
            return row
        }

        // ---- D0: k = −3 twice, two FRESH caches, both real renders. Nothing else means anything until it holds.
        let a = await point("D0-a", k: -3, seed: nil, octave: 0, cache: rig.cache("det-a"), group: "D0")
        let shared = rig.cache("shared")
        let b = await point("D0-b", k: -3, seed: nil, octave: 0, cache: shared, group: "reference")
        let shaA = a["shas"] as? [String: String], shaB = b["shas"] as? [String: String]
        let jobA = a["job"] as? [String: Any], jobB = b["job"] as? [String: Any]
        let real = [jobA, jobB].allSatisfy { ($0?["cachedUnits"] as? Int) == 0 && (($0?["renderedUnits"] as? Int) ?? 0) >= 2 }
        let d0 = shaA != nil && shaA == shaB && real
        report.controls["D0"] = ["pass": d0, "a": shaA ?? [:], "b": shaB ?? [:], "bothReal": real]
        report.rows.append(contentsOf: [a, b])
        report.write()
        Self.note("D0 determinism: \(d0 ? "PASS" : "FAIL") part \(shaA?["part"]?.prefix(16) ?? "-") vs "
                  + "\(shaB?["part"]?.prefix(16) ?? "-"), lead \(shaA?["lead"]?.prefix(16) ?? "-") vs "
                  + "\(shaB?["lead"]?.prefix(16) ?? "-"), both real \(real)")
        #expect(d0, "the determinism control failed: \(report.controls["D0"] ?? "")")
        guard d0 else { return }

        // ---- The in-band reference (oob ≤ 0.25): k = −3 (alt seed), −4 and −2 (both seeds).
        var plan: [(label: String, k: Int, seed: UInt64?, octave: Int?, group: String)] = [
            ("k-3-alt", -3, X9F3Source.altSeed, 0, "reference"),
            ("k-4", -4, nil, 0, "reference"), ("k-4-alt", -4, X9F3Source.altSeed, 0, "reference"),
            ("k-2", -2, nil, 0, "reference"), ("k-2-alt", -2, X9F3Source.altSeed, 0, "reference"),
            // ---- k = 0: the cross-lane shas (X9R H1 third above, H3 seed-2) and the live-path fit check (unpinned).
            ("k+0", 0, nil, 0, "control-k0"), ("k+0-alt", 0, X9F3Source.altSeed, 0, "control-k0"),
            ("k+0-unpinned", 0, nil, nil, "control-unpinned"),
            // ---- The proxy's POSITIVE control: the k = 0 part forced out by whole octaves.
            ("pc-oct+2", 0, nil, 2, "positive"), ("pc-oct-2", 0, nil, -2, "positive"),
            ("pc-oct+1", 0, nil, 1, "positive"), ("pc-oct-1", 0, nil, -1, "positive"),
        ]
        // ---- The sweep, both takes per point.
        for k in [-1, 1, 2, 3, 4, 5, 6, -5, -6, -7, -8, -9, -10, -11, -12] {
            let name = k >= 0 ? "k+\(k)" : "k\(k)"
            plan.append((name, k, nil, 0, "sweep"))
            plan.append(("\(name)-alt", k, X9F3Source.altSeed, 0, "sweep"))
        }
        for p in plan {
            let row = await point(p.label, k: p.k, seed: p.seed, octave: p.octave, cache: shared, group: p.group)
            report.rows.append(row)
            report.write()
        }
        report.meta["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        report.write()
        let errors = report.rows.filter { $0["error"] != nil }.map { "\($0["label"] ?? "")" }
        Self.note("sweep finished: \(report.rows.count) takes, errors \(errors)")
    }
}
