/// Deinterleaved rendered audio: plain `[[Float]]` + sample rate, nothing
/// else. Lives in DAWCore (moved from DAWEngine, M5 iv-a) so pure analysis
/// (`Loudness.measure`) and the render/normalization policy layer can consume
/// buffers without any engine import — AVFoundation types stay inside
/// DAWEngine, which converts its render taps/files into this shape at the
/// module boundary.
public struct RenderedAudio: Sendable {
    public let sampleRate: Double
    /// `[channel][frame]`. Mutable only through `applyGain(linear:)` so the
    /// channel-count/frame-count shape stays whatever the renderer produced.
    public private(set) var channelData: [[Float]]

    public var frameCount: Int { channelData.first?.count ?? 0 }

    public init(sampleRate: Double, channelData: [[Float]]) {
        self.sampleRate = sampleRate
        self.channelData = channelData
    }

    /// In-place linear gain over every channel — no copy of what may be a
    /// multi-hundred-MB buffer (a 10-min stereo 48 k render is ~230 MB). Used
    /// by the loudness-normalized bounce (spec §4.1): gain in Float32, applied
    /// once, output re-measured afterwards.
    public mutating func applyGain(linear gain: Float) {
        for channel in channelData.indices {
            for frame in channelData[channel].indices {
                channelData[channel][frame] *= gain
            }
        }
    }
}
