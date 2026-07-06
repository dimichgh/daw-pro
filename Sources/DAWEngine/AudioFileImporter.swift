import AVFAudio
import DAWCore
import Foundation

/// Reads audio-file facts via AVAudioFile so DAWCore can turn a dropped file
/// into a tempo-mapped clip. This is pure, one-shot file I/O — it opens the
/// file, reads its header, and closes it; it never touches the render path,
/// so it needs no actor isolation and is safe to call off the main thread.
///
/// Sendable via being a struct with no stored state (required by MediaImporting).
public struct AudioFileImporter: MediaImporting {
    public init() {}

    public func audioFileInfo(at url: URL) throws -> AudioFileInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectError.importFailed("no file at \(url.path)")
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ProjectError.importFailed(error.localizedDescription)
        }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let durationSeconds = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        return AudioFileInfo(
            durationSeconds: durationSeconds,
            sampleRate: sampleRate,
            channelCount: Int(format.channelCount)
        )
    }
}
