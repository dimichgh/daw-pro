import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m39-d (W8-M39D) — DOES LIVE BLOCK-RATE MODULATION DEPEND ON THE BLOCK SIZE? A MEASUREMENT, NOT A GATE.
//
// The question the roadmap left open: the live render block is the hardware buffer (device-dependent and
// user-changeable), the bounce is `RenderBlockSize.offlineFrames` (512), and 512 is the only size ever measured.
// Effect-parameter modulation is evaluated ONCE PER RENDER CALL at the quantum start
// (`AutomationRenderer.storeEffectParams`, called from `ChainHostAU`'s render block and from the instrument
// node), and held for that call's `frameCount`. The block length therefore comes from the render call, not from
// a device property — so the live case can be measured WITHOUT a device: the real `PlaybackGraph` on an
// `AVAudioEngine` in manual rendering `.realtime` mode, pulled at 64 / 128 / 512 / 1024 frames per call.
//
// Controls (each one able to fail, and each one shown failing by a plant in the lane's record):
//   C1 the `quantumFrames` probe reports every forced pull size (a probe that never reports a difference proves
//      nothing); C2 the realtime harness at N frames is bit-identical to `OfflineRenderer(maximumFrameCount: N)`,
//      so every difference reported is CADENCE alone; C3 the realtime file player did not starve; C4 the modulated
//      render differs from the unmodulated one (m39-e once shipped byte-identical to "no modulation"); C5 the
//      analysis can see an alias when one is there.
//
// Disabled unless `M39D_BLOCKS=1` (about a minute of renders and analysis). Results land in `M39D_OUT`
// (default: a temp directory), one TSV plus float WAVs for independent re-analysis.
//
//   M39D_BLOCKS=1 M39D_OUT=/some/dir ./scripts/test.sh --filter LiveBlockSizeModulation
//
// Nonisolated suite: the graph work runs in `@MainActor` helpers awaited from here, and nothing blocks the main
// thread (pacing, when enabled, is `Task.sleep`).

private enum M39D {
    static let sampleRate = 48_000.0
    static let seconds = 3.0
    static let totalFrames = Int(seconds * sampleRate)
    static let maximumFrames = 1_024
    static let pullSizes = [64, 128, 512, 1_024]
    static let lfoRates = [5.0, 12.0, 30.0]
    static let lfoDepth = 1.0 / 32.0          // gainLinear 0…16 linear: gain = 1 ± 0.5
    static let stepDepth = 1.0 / 16.0         // gain 1 ↔ 2
    static let stepRate = 8.0                 // steps per second: a 1/16 gate at 120 BPM
    static let dcLevel: Float = 0.25
    static let windowStart = Int(0.5 * sampleRate)
    static let windowEnd = Int(2.5 * sampleRate)
    static let tempoMap = TempoMap(constantBPM: 120)

    static var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["M39D_OUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("dawpro-m39d", isDirectory: true).path
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var paceMilliseconds: Int {
        Int(ProcessInfo.processInfo.environment["M39D_PACE_MS"] ?? "") ?? 0
    }

    static var prerollMilliseconds: Int {
        Int(ProcessInfo.processInfo.environment["M39D_PREROLL_MS"] ?? "") ?? 0
    }
}

private enum M39DError: Error {
    case setup(String)
}

/// What the model in the lane's `model.py` predicted (dB of the fundamental vs the ideal 0.5 depth, and lag in
/// samples) — C6, a check on the READING of the mechanism, not on the product.
private let m39dModel: [String: (depthDb: Double, lagSamples: Double)] = [
    "64@5.0": (-0.079, 237.8), "128@5.0": (-0.055, 238.3), "512@5.0": (-0.050, 375.0), "1024@5.0": (-0.172, 631.0),
    "64@12.0": (-0.438, 232.2), "128@12.0": (-0.307, 235.3), "512@12.0": (-0.287, 375.0), "1024@12.0": (-1.009, 631.0),
    "64@30.0": (-2.215, 206.1), "128@30.0": (-1.663, 219.6), "512@30.0": (-1.840, 375.0), "1024@30.0": (-7.259, 631.0),
]

/// Timestamp facts from a silent sibling `AVAudioSourceNode` (C7). Render-thread writes into preallocated cells.
private final class M39DStampBox: @unchecked Sendable {
    // 0 calls, 1 hostTimeValid calls, 2 sampleTimeValid calls, 3 first host, 4 last host,
    // 5 first sample (bits), 6 last sample (bits), 7 total frames
    let cells: UnsafeMutablePointer<UInt64>
    init() {
        cells = .allocate(capacity: 8)
        cells.initialize(repeating: 0, count: 8)
    }
    deinit { cells.deallocate() }
}

private struct M39DRealtimeRender: Sendable {
    var left: [Float]
    var probeReadings: [Int]
    var retries: Int
    var stamps: [UInt64]
    /// Samples after the first 0.1 s that are exactly 0.0 — a starved file player (C3's sharpest symptom; the
    /// DC input can never be 0 through a gain of 0.5…2).
    var starvedSamples: Int {
        left.dropFirst(Int(0.1 * M39D.sampleRate)).reduce(0) { $0 + ($1 == 0 ? 1 : 0) }
    }
}

private struct M39DSpectrum: Sendable {
    var dc: Double
    var rate: Double
    var amplitude: Double
    var lagSamples: Double
    var worstImageHz: Double
    var worstImageDbc: Double
    var dominantHz: Double
}

@MainActor
private enum M39DHarness {
    nonisolated static func dcFile() throws -> URL {
        let directory = M39D.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("dc-0.25-4s.wav")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: M39D.sampleRate,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(4 * M39D.sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: M39D.sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else { throw M39DError.setup("dc buffer") }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            for frame in 0..<frames { data[channel][frame] = M39D.dcLevel }
        }
        try file.write(from: buffer)
        return url
    }

    nonisolated static func track(dc: URL, source: ModulationSource, depth: Double) -> Track {
        let gain = EffectDescriptor(kind: .gain)   // knob 1.0: the modulation is the only motion
        var track = Track(name: "DC", kind: .audio,
                          clips: [Clip(name: "dc", startBeat: 0, lengthBeats: 8, audioFileURL: dc)],
                          effects: [gain])
        track.modulationSources = [source]
        track.modulationRoutes = [ModulationRoute(
            sourceID: source.id,
            target: .effectParam(effectID: gain.id, paramName: "gainLinear"),
            depth: depth)]
        return track
    }

    nonisolated static func lfo(_ rate: Double) -> ModulationSource {
        ModulationSource(kind: .lfo, params: .lfo(LFOSourceParams(waveform: .sine, rateHz: rate, bipolar: true)))
    }

    nonisolated static func stepGate() -> ModulationSource {
        ModulationSource(kind: .stepSequencer, params: .stepSequencer(
            StepSequencerSourceParams(steps: [0, 1], rateHz: M39D.stepRate, edgeMs: 2)))
    }

    /// The bounce, at any block size.
    static func offline(_ track: Track, frames: Int) throws -> [Float] {
        let audio = try OfflineRenderer(sampleRate: M39D.sampleRate, maximumFrameCount: frames)
            .render(tracks: [track], tempoMap: M39D.tempoMap, fromBeat: 0, durationSeconds: M39D.seconds)
        return audio.channelData[0]
    }

    /// The LIVE graph, device-free: `.realtime` manual rendering, `pull` frames per render call under a 1024
    /// maximum. Set-up order mirrors the live roll (reconcile → applyParameters → start → applyParameters →
    /// scheduleAll → startAllPlayers). `at: nil` rolls with sample-time positions (see DIAGNOSIS: the host-time
    /// position path is NOT exercised here).
    static func realtime(_ track: Track, pull: Int, stampProbe: Bool = false) async throws -> M39DRealtimeRender {
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: M39D.sampleRate, channels: 2) else {
            throw M39DError.setup("format")
        }
        try engine.enableManualRenderingMode(.realtime, format: format,
                                             maximumFrameCount: AVAudioFrameCount(M39D.maximumFrames))
        _ = engine.mainMixerNode
        let box = M39DStampBox()
        if stampProbe {
            let node = AVAudioSourceNode(format: format) { @Sendable isSilence, timestamp, frameCount, abl in
                let cells = box.cells
                let stamp = timestamp.pointee
                let calls = cells[0]
                cells[0] = calls &+ 1
                if stamp.mFlags.contains(.hostTimeValid) { cells[1] = cells[1] &+ 1 }
                if stamp.mFlags.contains(.sampleTimeValid) { cells[2] = cells[2] &+ 1 }
                if calls == 0 {
                    cells[3] = stamp.mHostTime
                    cells[5] = stamp.mSampleTime.bitPattern
                }
                cells[4] = stamp.mHostTime
                cells[6] = stamp.mSampleTime.bitPattern
                cells[7] = cells[7] &+ UInt64(frameCount)
                for buffer in UnsafeMutableAudioBufferListPointer(abl) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                isSilence.pointee = true
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        _ = graph.reconcile(tracks: [track])
        graph.applyParameters(tracks: [track], playheadBeat: 0)
        try engine.start()
        graph.applyParameters(tracks: [track], playheadBeat: 0)
        graph.scheduleAll(fromBeat: 0, tempoMap: M39D.tempoMap)
        graph.startAllPlayers(at: nil)
        if M39D.prerollMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(M39D.prerollMilliseconds))
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(M39D.maximumFrames)),
              let data = buffer.floatChannelData else { throw M39DError.setup("pull buffer") }
        let render = engine.manualRenderingBlock
        var left = [Float]()
        left.reserveCapacity(M39D.totalFrames)
        var probe: [Int] = []
        var retries = 0
        var sincePace = 0
        let paceFrames = Int(Double(M39D.paceMilliseconds) * M39D.sampleRate / 1000)
        while left.count < M39D.totalFrames {
            let frames = min(pull, M39D.totalFrames - left.count)
            buffer.frameLength = AVAudioFrameCount(frames)
            var error: OSStatus = noErr
            let status = render(AVAudioFrameCount(frames), buffer.mutableAudioBufferList, &error)
            if status == .cannotDoInCurrentContext, retries < 1_000 {
                retries += 1
                await Task.yield()
                continue
            }
            guard status == .success else {
                throw M39DError.setup("manual render status \(status.rawValue) error \(error) at frame \(left.count)")
            }
            left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            if frames == pull { probe.append(graph.performance.snapshot().quantumFrames) }
            sincePace += frames
            if paceFrames > 0, sincePace >= paceFrames {
                sincePace = 0
                try await Task.sleep(for: .milliseconds(M39D.paceMilliseconds))
            }
        }
        graph.stopAllPlayers()
        engine.stop()
        let stamps = (0..<8).map { box.cells[$0] }
        return M39DRealtimeRender(left: left, probeReadings: probe, retries: retries, stamps: stamps)
    }
}

private enum M39DAnalysis {
    /// Window-normalised complex amplitude of `f` in `x` (a pure tone of amplitude A reads |A|), by a rotation
    /// recurrence (renormalised) rather than a trig call per sample.
    static func tone(_ x: [Double], _ w: [Double], _ f: Double, sumW: Double) -> (re: Double, im: Double) {
        let d = 2 * Double.pi * f / M39D.sampleRate
        let cd = cos(d), sd = sin(d)
        var c = 1.0, s = 0.0
        var re = 0.0, im = 0.0
        for i in 0..<x.count {
            let v = x[i] * w[i]
            re += v * c
            im -= v * s
            let nc = c * cd - s * sd
            s = s * cd + c * sd
            c = nc
            if i & 1023 == 1023 {
                let r = (c * c + s * s).squareRoot()
                c /= r; s /= r
            }
        }
        return (2 * re / sumW, 2 * im / sumW)
    }

    static func hann(_ n: Int) -> [Double] {
        (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1)) }
    }

    static func spectrum(_ y: [Float], f: Double, pull: Int, dc: Double) -> M39DSpectrum {
        let segment = y[M39D.windowStart..<M39D.windowEnd].map(Double.init)
        let mean = segment.reduce(0, +) / Double(segment.count)
        let x = segment.map { $0 - mean }
        let w = hann(x.count)
        let sumW = w.reduce(0, +)
        func mag(_ freq: Double) -> Double {
            let t = tone(x, w, freq, sumW: sumW)
            return (t.re * t.re + t.im * t.im).squareRoot()
        }
        // Rate: golden-section peak search within f ± 0.3 Hz.
        var lo = f - 0.3, hi = f + 0.3
        let g = (5.0.squareRoot() - 1) / 2
        var a = hi - g * (hi - lo), b = lo + g * (hi - lo)
        var fa = mag(a), fb = mag(b)
        for _ in 0..<22 {
            if fa > fb {
                hi = b; b = a; fb = fa
                a = hi - g * (hi - lo); fa = mag(a)
            } else {
                lo = a; a = b; fa = fb
                b = lo + g * (hi - lo); fb = mag(b)
            }
        }
        let rate = (lo + hi) / 2
        let fundamental = tone(x, w, f, sumW: sumW)
        let amplitude = (fundamental.re * fundamental.re + fundamental.im * fundamental.im).squareRoot()
        let idealPhase = 2 * Double.pi * f * Double(M39D.windowStart) / M39D.sampleRate - Double.pi / 2
        var dphi = atan2(fundamental.im, fundamental.re) - idealPhase
        dphi = (dphi + Double.pi).truncatingRemainder(dividingBy: 2 * Double.pi)
        if dphi < 0 { dphi += 2 * Double.pi }
        dphi -= Double.pi
        let lag = -dphi / (2 * Double.pi * f) * M39D.sampleRate
        // Images of the block-rate staircase: k·sr/N ± f.
        var worst = (hz: 0.0, mag: 0.0)
        for k in 1...2 {
            for sign in [-1.0, 1.0] {
                let fi = Double(k) * M39D.sampleRate / Double(pull) + sign * f
                guard fi > 0 else { continue }
                let m = mag(fi)
                if m > worst.mag { worst = (fi, m) }
            }
        }
        // Dominant component 0.5…100 Hz on 48× box-decimated data.
        let m = 48
        var decimated: [Double] = []
        var i = 0
        while i + m <= x.count {
            var sum = 0.0
            for j in i..<(i + m) { sum += x[j] }
            decimated.append(sum / Double(m))
            i += m
        }
        let wd = hann(decimated.count)
        var best = (hz: 0.0, mag: -1.0)
        var fq = 0.5
        while fq <= 100 {
            let d = 2 * Double.pi * fq / (M39D.sampleRate / Double(m))
            var re = 0.0, im = 0.0
            for n in 0..<decimated.count {
                let v = decimated[n] * wd[n]
                re += v * cos(d * Double(n))
                im -= v * sin(d * Double(n))
            }
            let mm = (re * re + im * im).squareRoot()
            if mm > best.mag { best = (fq, mm) }
            fq += 0.25
        }
        return M39DSpectrum(dc: dc, rate: rate, amplitude: amplitude, lagSamples: lag,
                            worstImageHz: worst.hz,
                            worstImageDbc: 20 * log10(max(worst.mag, 1e-15) / max(amplitude, 1e-15)),
                            dominantHz: best.hz)
    }

    /// Midpoint-crossing lag (samples) of every gate edge after 0.25 s, vs the ideal edge k·sr/rate.
    static func edgeLags(_ y: [Float], dc: Double) -> [Double] {
        let samplesPerStep = M39D.sampleRate / M39D.stepRate
        let threshold = dc * 1.5
        var lags: [Double] = []
        var k = 1
        while Double(k + 1) * samplesPerStep < Double(y.count - 2_000) {
            let edge = Double(k) * samplesPerStep
            let rising = k % 2 == 1
            var i = Int(edge) - 200
            while i < Int(edge) + 3_000 {
                let a = Double(y[i]), b = Double(y[i + 1])
                if (rising && a < threshold && b >= threshold) || (!rising && a > threshold && b <= threshold) {
                    if edge > 0.25 * M39D.sampleRate { lags.append(Double(i) + (threshold - a) / (b - a) - edge) }
                    break
                }
                i += 1
            }
            k += 1
        }
        return lags
    }

    static func bitDiffs(_ a: [Float], _ b: [Float]) -> (count: Int, first: Int, maxAbs: Float) {
        var count = 0, first = -1
        var maxAbs: Float = 0
        for i in 0..<min(a.count, b.count) where a[i].bitPattern != b[i].bitPattern {
            count += 1
            if first < 0 { first = i }
            maxAbs = max(maxAbs, abs(a[i] - b[i]))
        }
        return (count + abs(a.count - b.count), first, maxAbs)
    }

    static func writeWAV(_ samples: [Float], name: String) throws {
        let url = M39D.outputDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: M39D.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: M39D.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData else { throw M39DError.setup("wav buffer") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in 0..<samples.count { data[0][i] = samples[i] }
        try file.write(from: buffer)
    }

    static func windowMean(_ y: [Float]) -> Double {
        y[M39D.windowStart..<M39D.windowEnd].reduce(0.0) { $0 + Double($1) }
            / Double(M39D.windowEnd - M39D.windowStart)
    }
}

@Suite("m39-d live block size: effect-param modulation at 64/128/512/1024 frames (M39D_BLOCKS=1)",
       .serialized, .enabled(if: ProcessInfo.processInfo.environment["M39D_BLOCKS"] == "1"))
struct LiveBlockSizeModulationTests {

    @Test("m39-d C1: the quantumFrames probe reports every forced pull size (64/128/512/1024)")
    func probeReportsEveryPullSize() async throws {
        let dc = try M39DHarness.dcFile()
        let track = M39DHarness.track(dc: dc, source: M39DHarness.lfo(5), depth: M39D.lfoDepth)
        var seen: [Int: Set<Int>] = [:]
        for pull in M39D.pullSizes {
            let render = try await M39DHarness.realtime(track, pull: pull)
            seen[pull] = Set(render.probeReadings)
            print("[measured] m39-d C1 probe: pull \(pull) → quantumFrames readings \(Set(render.probeReadings).sorted()) "
                  + "over \(render.probeReadings.count) full pulls (retries \(render.retries), starved samples "
                  + "\(render.starvedSamples), pace \(M39D.paceMilliseconds) ms)")
            #expect(Set(render.probeReadings) == [pull], "the probe must report the forced pull size \(pull)")
        }
        #expect(seen[64] != seen[1_024], "a probe that never reports a difference proves nothing")
    }

    @Test("m39-d: block-rate effect-param LFO, live (.realtime, 64/128/512/1024) vs the 512 bounce: rate, depth, lag, images, alias")
    func lfoModulationAcrossBlockSizes() async throws {
        let dc = try M39DHarness.dcFile()
        try FileManager.default.createDirectory(at: M39D.outputDirectory, withIntermediateDirectories: true)
        var tsv = "arm\tpull\tf\tdc\tdepth_ratio\tdepth_db_vs_ideal\trate\tlag_samples\tlag_ms\tworst_image_hz\t"
            + "worst_image_dbc\tdominant_hz\n"

        // Control arms (depth 0) per pull: C3 starvation, and the DC every depth ratio is read against.
        let controlTrack = M39DHarness.track(dc: dc, source: M39DHarness.lfo(5), depth: 0)
        var control: [Int: [Float]] = [:]
        for pull in M39D.pullSizes {
            let render = try await M39DHarness.realtime(controlTrack, pull: pull)
            let level = M39DAnalysis.windowMean(render.left)
            var worst: Float = 0
            for i in M39D.windowStart..<M39D.windowEnd { worst = max(worst, abs(render.left[i] - Float(level))) }
            let firstNonDC = render.left.firstIndex { abs($0 - Float(level)) > 1e-6 } ?? -1
            print("[measured] m39-d C3 control pull \(pull): DC \(level), max |x − DC| in window \(worst), "
                  + "first sample off DC \(firstNonDC), retries \(render.retries), starved samples \(render.starvedSamples)")
            #expect(level > 0.1, "the DC clip must be audible (starvation control)")
            #expect(worst <= 1e-6, "the unmodulated control must be flat in the window (no starvation)")
            control[pull] = render.left
        }

        var results: [String: M39DSpectrum] = [:]
        for f in M39D.lfoRates {
            let track = M39DHarness.track(dc: dc, source: M39DHarness.lfo(f), depth: M39D.lfoDepth)
            let bounce = try await M39DHarness.offline(track, frames: 512)
            let bounceControl = try await M39DHarness.offline(
                M39DHarness.track(dc: dc, source: M39DHarness.lfo(f), depth: 0), frames: 512)
            let dcBounce = M39DAnalysis.windowMean(bounceControl)
            let ref = M39DAnalysis.spectrum(bounce, f: f, pull: 512, dc: dcBounce)
            results["O512@\(f)"] = ref
            try M39DAnalysis.writeWAV(bounce, name: "O512-lfo\(Int(f)).wav")
            tsv += row("O512", 512, f, ref)
            for pull in M39D.pullSizes {
                let live = try await M39DHarness.realtime(track, pull: pull)
                let offlineSame = try await M39DHarness.offline(track, frames: pull)
                let dcLive = M39DAnalysis.windowMean(control[pull] ?? [])
                // C2: realtime harness == OfflineRenderer at the SAME block size (cadence is the only variable).
                let same = M39DAnalysis.bitDiffs(live.left, offlineSame)
                print("[measured] m39-d C2 R\(pull) vs O\(pull) @\(f) Hz: \(same.count) differing samples "
                      + "(first \(same.first), max |Δ| \(same.maxAbs)); starved samples \(live.starvedSamples)")
                #expect(same.count == 0, "the .realtime harness at \(pull) must equal the bounce engine at \(pull)")
                if pull == 512 {
                    let null = M39DAnalysis.bitDiffs(live.left, bounce)
                    #expect(null.count == 0, "C2 null: live at 512 must be bit-identical to the 512 bounce")
                }
                // C4: modulation is not inert.
                let inert = M39DAnalysis.bitDiffs(live.left, control[pull] ?? [])
                print("[measured] m39-d C4 R\(pull) @\(f) Hz vs its control: \(inert.count) differing samples")
                #expect(inert.count > 10_000, "the modulated render must differ from the unmodulated one")
                let s = M39DAnalysis.spectrum(live.left, f: f, pull: pull, dc: dcLive)
                results["R\(pull)@\(f)"] = s
                try M39DAnalysis.writeWAV(live.left, name: "R\(pull)-lfo\(Int(f)).wav")
                tsv += row("R", pull, f, s)
                let depthDb = 20 * log10((s.amplitude / s.dc) / (ref.amplitude / ref.dc))
                print("[measured] m39-d R\(pull) @\(f) Hz: rate \(fmt(s.rate, 4)) Hz, depth \(fmt(s.amplitude / s.dc, 5)) "
                      + "(\(fmt(depthDb, 3)) dB vs O512), lag \(fmt(s.lagSamples / 48, 2)) ms "
                      + "(Δ \(fmt((s.lagSamples - ref.lagSamples) / 48, 2)) ms vs O512 \(fmt(ref.lagSamples / 48, 2))), "
                      + "worst image \(fmt(s.worstImageHz, 3)) Hz at \(fmt(s.worstImageDbc, 2)) dBc "
                      + "(O512 \(fmt(ref.worstImageDbc, 2)) dBc), dominant \(fmt(s.dominantHz, 2)) Hz")
                // C6: does the engine match the model built from the source as read?
                if let model = m39dModel["\(pull)@\(f)"] {
                    let depthVsIdeal = 20 * log10((s.amplitude / s.dc) / 0.5)
                    print("[measured] m39-d C6 model R\(pull)@\(f): depth \(fmt(depthVsIdeal, 3)) dB vs model "
                          + "\(model.depthDb); lag \(fmt(s.lagSamples, 1)) vs model \(model.lagSamples) samples")
                    #expect(abs(depthVsIdeal - model.depthDb) <= 0.1, "C6 depth vs model at \(pull)@\(f)")
                    #expect(abs(s.lagSamples - model.lagSamples) <= 20, "C6 lag vs model at \(pull)@\(f)")
                }
            }
        }
        // C5: the analysis can see an alias — 30 Hz sampled at 46.875 Hz folds to 16.875 Hz.
        let aliased = try #require(results["R1024@30.0"])
        print("[measured] m39-d C5: R1024 @30 Hz dominant component \(aliased.dominantHz) Hz "
              + "(predicted ≈16.875 Hz); worst image \(aliased.worstImageHz) Hz at \(fmt(aliased.worstImageDbc, 2)) dBc")
        #expect(abs(aliased.dominantHz - 16.875) <= 0.5, "C5: an alias the analysis cannot see means the analysis is blind")

        // Verdicts against the pre-registered bars (PREDICTIONS.md). Printed, not asserted: this is the finding.
        for pull in M39D.pullSizes {
            var failed: [String] = []
            for f in M39D.lfoRates {
                guard let s = results["R\(pull)@\(f)"], let ref = results["O512@\(f)"] else { continue }
                let dDepth = 20 * log10((s.amplitude / s.dc) / (ref.amplitude / ref.dc))
                let dLagMs = (s.lagSamples - ref.lagSamples) / 48
                if abs(s.rate - f) > 0.01 { failed.append("rate@\(f)") }
                if abs(s.dominantHz - f) > 0.5 { failed.append("alias@\(f)→\(s.dominantHz)") }
                if abs(dDepth) > 0.5 { failed.append("depth@\(f)(\(fmt(dDepth, 2))dB)") }
                if abs(dLagMs) > 2 { failed.append("timing@\(f)(\(fmt(dLagMs, 2))ms)") }
                if s.worstImageDbc > max(ref.worstImageDbc + 3, -40) {
                    failed.append("zipper@\(f)(\(fmt(s.worstImageDbc, 1)) vs \(fmt(ref.worstImageDbc, 1))dBc)")
                }
            }
            print("[measured] m39-d VERDICT LFO pull \(pull): \(failed.isEmpty ? "AGREE" : "DIVERGE " + failed.joined(separator: ", "))")
        }
        let tsvURL = M39D.outputDirectory.appendingPathComponent("lfo-results.tsv")
        try tsv.write(to: tsvURL, atomically: true, encoding: .utf8)
        print("[measured] m39-d wrote \(tsvURL.path)")
    }

    @Test("m39-d SECONDARY: a step gate (8 steps/s) on an effect param — edge timing live vs the 512 bounce")
    func stepGateEdgesAcrossBlockSizes() async throws {
        let dc = try M39DHarness.dcFile()
        let track = M39DHarness.track(dc: dc, source: M39DHarness.stepGate(), depth: M39D.stepDepth)
        let controlTrack = M39DHarness.track(dc: dc, source: M39DHarness.stepGate(), depth: 0)
        let bounce = try await M39DHarness.offline(track, frames: 512)
        let bounceControl = try await M39DHarness.offline(controlTrack, frames: 512)
        let dcBounce = M39DAnalysis.windowMean(bounceControl)
        let reference = M39DAnalysis.edgeLags(bounce, dc: dcBounce)
        try M39DAnalysis.writeWAV(bounce, name: "O512-gate.wav")
        print("[measured] m39-d gate O512: \(reference.count) edges, lag \(fmt(reference.min() ?? .nan, 1))…"
              + "\(fmt(reference.max() ?? .nan, 1)) samples, mean \(fmt(reference.reduce(0, +) / Double(max(reference.count, 1)), 1))")
        #expect(reference.count >= 18, "the analysis must find the gate edges in the bounce")
        for pull in M39D.pullSizes {
            let live = try await M39DHarness.realtime(track, pull: pull)
            let offlineSame = try await M39DHarness.offline(track, frames: pull)
            let same = M39DAnalysis.bitDiffs(live.left, offlineSame)
            print("[measured] m39-d C2 gate R\(pull) vs O\(pull): \(same.count) differing samples (first \(same.first)); "
                  + "starved samples \(live.starvedSamples)")
            #expect(same.count == 0, "C2 gate: R\(pull) == O\(pull)")
            if pull == 512 { #expect(M39DAnalysis.bitDiffs(live.left, bounce).count == 0, "C2 gate null at 512") }
            let liveControl = try await M39DHarness.realtime(controlTrack, pull: pull)
            let dcLive = M39DAnalysis.windowMean(liveControl.left)
            let lags = M39DAnalysis.edgeLags(live.left, dc: dcLive)
            try M39DAnalysis.writeWAV(live.left, name: "R\(pull)-gate.wav")
            let deltas = zip(lags, reference).map { $0 - $1 }
            let worst = deltas.map(abs).max() ?? .nan
            print("[measured] m39-d gate R\(pull): \(lags.count) edges, lag \(fmt(lags.min() ?? .nan, 1))…"
                  + "\(fmt(lags.max() ?? .nan, 1)) samples (\(fmt((lags.min() ?? .nan) / 48, 2))…\(fmt((lags.max() ?? .nan) / 48, 2)) ms), "
                  + "mean \(fmt(lags.reduce(0, +) / Double(max(lags.count, 1)), 1)); vs O512 Δ \(fmt(deltas.min() ?? .nan, 1))…"
                  + "\(fmt(deltas.max() ?? .nan, 1)) samples, max |Δ| \(fmt(worst / 48, 2)) ms → "
                  + (worst / 48 <= 2 ? "AGREE" : "DIVERGE"))
            #expect(lags.count == reference.count, "same edge count live and bounced at \(pull)")
        }
    }

    @Test("m39-d C7: what timestamps does .realtime manual rendering hand the graph? (fact, no verdict)")
    func realtimeHarnessTimestamps() async throws {
        let dc = try M39DHarness.dcFile()
        let track = M39DHarness.track(dc: dc, source: M39DHarness.lfo(5), depth: M39D.lfoDepth)
        let render = try await M39DHarness.realtime(track, pull: 512, stampProbe: true)
        let s = render.stamps
        let firstSample = Double(bitPattern: s[5]), lastSample = Double(bitPattern: s[6])
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let hostSeconds = s[4] >= s[3]
            ? Double(s[4] - s[3]) * Double(info.numer) / Double(info.denom) / 1e9 : -1
        print("[measured] m39-d C7 .realtime stamps: \(s[0]) calls, hostTimeValid on \(s[1]), sampleTimeValid on \(s[2]); "
              + "host \(s[3])→\(s[4]) (\(fmt(hostSeconds, 4)) s), sample \(firstSample)→\(lastSample) "
              + "(\(fmt((lastSample - firstSample) / M39D.sampleRate, 4)) s), \(s[7]) frames")
        #expect(s[0] > 0, "the probe node must have been pulled")
    }
}

private func fmt(_ v: Double, _ places: Int) -> String {
    String(format: "%.\(places)f", v)
}

private func row(_ arm: String, _ pull: Int, _ f: Double, _ s: M39DSpectrum) -> String {
    let ratio = s.amplitude / s.dc
    return "\(arm)\t\(pull)\t\(f)\t\(s.dc)\t\(ratio)\t\(20 * log10(ratio / 0.5))\t\(s.rate)\t\(s.lagSamples)\t"
        + "\(s.lagSamples / 48)\t\(s.worstImageHz)\t\(s.worstImageDbc)\t\(s.dominantHz)\n"
}
