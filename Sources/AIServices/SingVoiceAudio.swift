import AVFoundation
import DAWCore
import Foundation

/// Reads a recording someone already has into Float32 samples at the file's own rate (p2-sing-e part 2,
/// `sing.addVoice {path}` / `{clipId}`, design §5.4 "Use a recording you already have").
///
/// That door accepts ANY audio file macOS can open (WAV, AIFF, M4A, MP3, CAF…), so this is AVFoundation, not
/// `SingWAV` (which reads only the facade's own Float32/PCM WAVs). It reads a window of the file, never the
/// whole of a long one: a clip's window of a song, or the first seconds of a file the clip check will refuse
/// as too long anyway.
public enum SingVoiceAudioDecoder {

    public enum DecodeError: Error, Equatable, LocalizedError {
        /// AVFoundation could not open or read the file; the detail is its own words.
        case unreadable(path: String, detail: String)
        /// The file (or the window asked for) holds no audio.
        case empty(path: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path, let detail): return "could not read \(path): \(detail)"
            case .empty(let path): return "\(path) holds no audio in the part asked for"
            }
        }
    }

    /// The file's length in seconds, from its header (nothing is decoded).
    public static func durationSeconds(of url: URL) throws -> Double {
        let file = try open(url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { throw DecodeError.empty(path: url.path) }
        return Double(file.length) / rate
    }

    /// Decodes `[startSeconds, startSeconds + durationSeconds)` of the file (clamped to its end; nil = to the
    /// end), every channel, at the file's own sample rate.
    public static func decode(_ url: URL, startSeconds: Double = 0,
                              durationSeconds: Double? = nil) throws -> RenderedAudio {
        let file = try open(url)
        let format = file.processingFormat   // deinterleaved Float32, AVFoundation's standard format
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        guard file.length > 0, rate > 0, channels > 0 else { throw DecodeError.empty(path: url.path) }
        let startFrame = AVAudioFramePosition((max(0, startSeconds) * rate).rounded())
        guard startFrame < file.length else { throw DecodeError.empty(path: url.path) }
        var remaining = file.length - startFrame
        if let durationSeconds {
            let requested = AVAudioFramePosition((max(0, min(durationSeconds, 86_400)) * rate).rounded())
            remaining = min(remaining, requested)
        }
        guard remaining > 0 else { throw DecodeError.empty(path: url.path) }
        file.framePosition = startFrame
        var out = [[Float]](repeating: [], count: channels)
        for c in 0..<channels { out[c].reserveCapacity(Int(remaining)) }
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw DecodeError.unreadable(path: url.path, detail: "no buffer for format \(format)")
        }
        while remaining > 0 {
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            do {
                try file.read(into: buffer, frameCount: want)
            } catch {
                throw DecodeError.unreadable(path: url.path, detail: error.localizedDescription)
            }
            let got = Int(buffer.frameLength)
            guard got > 0, let data = buffer.floatChannelData else { break }
            for c in 0..<channels {
                out[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: got))
            }
            remaining -= AVAudioFramePosition(got)
        }
        guard (out.first?.count ?? 0) > 0 else { throw DecodeError.empty(path: url.path) }
        return RenderedAudio(sampleRate: rate, channelData: out)
    }

    /// The channels averaged to one (the reference a voice is saved as: design §2.3, "Float32, mono, native
    /// rate").
    public static func mono(_ audio: RenderedAudio) -> [Float] {
        let channels = audio.channelData
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        let scale = 1 / Float(channels.count)
        var mixed = [Float](repeating: 0, count: first.count)
        for channel in channels {
            for i in 0..<min(channel.count, mixed.count) { mixed[i] += channel[i] * scale }
        }
        return mixed
    }

    private static func open(_ url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw DecodeError.unreadable(path: url.path, detail: error.localizedDescription)
        }
    }
}
