import AVFAudio
import SwiftUI
import DAWAppKit
import DAWCore

/// Coarse peak data for one audio file: max-magnitude buckets at a fixed rate,
/// so a clip can draw the WINDOW of its source it actually sounds
/// (`startOffsetSeconds` .. + its length) without re-reading the file. v0 is an
/// outline, not a zoom-accurate editor — one magnitude per bucket, mirrored.
struct WaveformPeaks: Sendable, Equatable {
    /// Peak magnitude 0…1 per time bucket, from the file's head. **RAW** — never
    /// pre-scaled. Auto-fit (m25-e) is applied at DRAW time from `peakMax`, not
    /// baked in here: baking it would make raw mode unreachable and would mean a
    /// mode flip had to re-read the file.
    var magnitudes: [Float]
    /// How many buckets cover one second of source audio.
    var bucketsPerSecond: Double
    /// The loudest bucket in the WHOLE file (m25-e) — the auto-fit divisor.
    ///
    /// ⚠️ **FILE scope, not clip scope**, and deliberately so: this cache is keyed
    /// by URL and shared by every clip that windows the same source (splits share
    /// a file). A per-window peak would make the two halves of a split draw at
    /// different scales — the same relative-level lie that fit mode already has
    /// to justify, but now WITHIN one performance. So a split covering a quiet
    /// passage of a loud file gets the loud file's factor, and reads quiet. That
    /// is the intended behaviour.
    ///
    /// Defaulted to 1 (= no boost) so previews and every existing call site keep
    /// compiling and keep drawing exactly what they drew before.
    var peakMax: Float = 1

    /// Peak magnitude at a source time (seconds), clamped to the file's extent.
    /// Out-of-range times read as silence so a clip windowed past the file end
    /// draws flat rather than crashing.
    func magnitude(atSeconds seconds: Double) -> Float {
        guard !magnitudes.isEmpty, seconds >= 0 else { return 0 }
        let index = Int(seconds * bucketsPerSecond)
        guard index >= 0, index < magnitudes.count else { return 0 }
        return magnitudes[index]
    }
}

/// Main-actor peak cache keyed by file URL. A clip asks for its file's peaks; a
/// miss returns nil and kicks off ONE off-main read (`Task.detached`) that
/// publishes the result back, redrawing the observing clip. Peaks are computed
/// once per URL and reused across every clip that windows the same source
/// (splits share a file), so the arrange view never reads audio on the main
/// thread and never per frame.
@MainActor
@Observable
final class WaveformStore {
    private var cache: [URL: WaveformPeaks] = [:]
    @ObservationIgnored private var loading: Set<URL> = []

    /// Buckets per second of source — coarse (a 60 s file is ~9 k floats), plenty
    /// for a 16 pt/beat outline. Fixed so every clip on a file shares one grid.
    static let bucketsPerSecond: Double = 150

    /// Cached peaks for `url`, or nil while the first read is in flight (which
    /// this call starts). Observing the result in a Canvas redraws it when it lands.
    func peaks(for url: URL) -> WaveformPeaks? {
        if let cached = cache[url] { return cached }
        guard !loading.contains(url) else { return nil }
        loading.insert(url)
        let rate = Self.bucketsPerSecond
        Task.detached(priority: .utility) {
            let peaks = Self.computePeaks(url: url, bucketsPerSecond: rate)
            await MainActor.run { self.store(peaks, for: url) }
        }
        return nil
    }

    private func store(_ peaks: WaveformPeaks?, for url: URL) {
        loading.remove(url)
        if let peaks { cache[url] = peaks }
    }

    /// Reads `url` off the main actor and downsamples to fixed-rate max-magnitude
    /// buckets. Pure one-shot file I/O (the `AudioFileImporter` idiom) — opens,
    /// scans, closes; never touches the render path, so it needs no isolation.
    /// Returns nil for an unreadable file (the clip keeps its icon fallback).
    nonisolated static func computePeaks(url: URL, bucketsPerSecond: Double) -> WaveformPeaks? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, file.length > 0 else { return nil }
        let framesPerBucket = max(1, Int(sampleRate / bucketsPerSecond))
        let readBlock: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readBlock) else { return nil }

        var magnitudes: [Float] = []
        magnitudes.reserveCapacity(Int(Double(file.length) / Double(framesPerBucket)) + 1)
        var bucketPeak: Float = 0
        var framesInBucket = 0
        let channelCount = Int(format.channelCount)

        while true {
            do { try file.read(into: buffer) } catch { break }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            for frame in 0..<frames {
                var sample: Float = 0
                for ch in 0..<channelCount {
                    sample = max(sample, abs(channels[ch][frame]))
                }
                bucketPeak = max(bucketPeak, sample)
                framesInBucket += 1
                if framesInBucket >= framesPerBucket {
                    magnitudes.append(min(1, bucketPeak))
                    bucketPeak = 0
                    framesInBucket = 0
                }
            }
        }
        if framesInBucket > 0 { magnitudes.append(min(1, bucketPeak)) }
        guard !magnitudes.isEmpty else { return nil }
        // m25-e: the file's loudest bucket, carried alongside the RAW magnitudes
        // so the drawing layer can fit without re-reading and without losing the
        // true amplitudes. Derived from the buckets we already have — one pass
        // over an array that is ~150 floats per second, off-main like the read.
        let peakMax = magnitudes.max() ?? 0
        return WaveformPeaks(magnitudes: magnitudes, bucketsPerSecond: bucketsPerSecond,
                             peakMax: peakMax)
    }
}

/// Canvas peak outline for one audio clip, drawn as a mirrored dual-tone shape
/// (body + brighter core) tinted by the clip's accent — violet when AI-touched
/// (docs/DESIGN-LANGUAGE.md: waveforms). Respects `startOffsetSeconds`: a split
/// or leading-trim windows into the source, so the visible outline starts that
/// far into the file. Value-in only (peaks + geometry) so it previews without
/// the store; redraws only when peaks/clip change (no TimelineView).
struct ClipWaveform: View {
    var peaks: WaveformPeaks
    var startOffsetSeconds: Double
    var secondsPerBeat: Double
    var pixelsPerBeat: CGFloat
    var tint: Color
    /// Auto-fit the outline to the block's height, capped (m25-e). Threaded from
    /// `PanelLayoutStore.waveformNormalize`; the default is the app default so a
    /// preview draws what the app draws.
    var normalize: Bool = WaveformScale.defaultNormalize
    /// Extra vertical magnification on top of the fit (m25-e), from
    /// `PanelLayoutStore.waveformVerticalZoom`. 1 = none.
    var verticalZoom: CGFloat = WaveformScale.defaultVerticalZoom

    var body: some View {
        // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
        // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
        let peaks = peaks
        let startOffsetSeconds = startOffsetSeconds
        let secondsPerBeat = secondsPerBeat
        let pixelsPerBeat = pixelsPerBeat
        let tint = tint
        // m25-e: ONE scalar, resolved from the headless rules BEFORE the closure —
        // per-view, never per column and never per frame (the no-allocation-in-
        // drawing rule). The Canvas below multiplies by it and does no other math.
        let scale = WaveformScale.drawScale(peakMax: peaks.peakMax, normalize: normalize,
                                            verticalZoom: verticalZoom)
        return Canvas { @Sendable context, size in
            let midY = size.height / 2
            let halfH = size.height / 2 - 2
            // m25-e: zoomed past full height the drawing is TRIMMED at the block
            // edge rather than squashed back in — the standard DAW behaviour, and
            // the only honest one (rescaling to fit would silently undo the zoom
            // the user just asked for). Clamping each bar's half-length to
            // `size.height / 2` reproduces a rect clip exactly, because every bar
            // is a vertical line centred on `midY` — and it keeps Path
            // coordinates bounded, so a big magnification cannot hand the
            // renderer runaway geometry. At scale 1 nothing here can trigger:
            // `halfH < maxH`, so the drawing is byte-identical to the pre-m25-e one.
            let maxH = size.height / 2
            // Step across the width in ~1.5 pt columns — coarse and cheap; the
            // Path is rebuilt per redraw (on data change), never per frame.
            let step: CGFloat = 1.5
            var body = Path()
            var core = Path()
            var x: CGFloat = 0
            while x <= size.width {
                let seconds = startOffsetSeconds + Double(x / pixelsPerBeat) * secondsPerBeat
                let mag = CGFloat(peaks.magnitude(atSeconds: seconds))
                let drawn = max(0.5, mag * scale * halfH)
                let bodyH = min(maxH, drawn)
                body.move(to: CGPoint(x: x, y: midY - bodyH))
                body.addLine(to: CGPoint(x: x, y: midY + bodyH))
                // The core is trimmed against the SAME edge, off the UNCLAMPED
                // length — computing it from the clamped body would flatten the
                // bright core early and make a trimmed peak read as a plateau.
                let coreH = min(maxH, drawn * 0.55)
                core.move(to: CGPoint(x: x, y: midY - coreH))
                core.addLine(to: CGPoint(x: x, y: midY + coreH))
                x += step
            }
            context.stroke(body, with: .color(tint.opacity(0.5)), lineWidth: 1)
            context.stroke(core, with: .color(tint.opacity(0.85)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
