import Foundation
import CStbVorbis
import DAWCore

/// `VorbisDecoding` over the vendored stb_vorbis decoder (m31-h) — the concrete
/// half of the seam DAWCore declares, exactly as `AudioFileImporter` is the
/// concrete half of `MediaImporting`. It lands in DAWEngine because that is
/// where vendored C targets live and because DAWCore is dependency-free by law.
///
/// Used only at IMPORT time, to turn a `.sf3` SoundFont into a real `.sf2`.
/// ⛔ Never the render thread: it allocates and decodes whole streams.
///
/// Why we carry a decoder at all, when macOS 26.4 turns out to decode Vorbis:
/// there is no PUBLIC API for it (no `Ogg`/`Vorbis` constant in any
/// AudioToolbox or AVFAudio header — positive-controlled against
/// `kAudioFileFLACType`, which is present), the deployment floor is macOS 14,
/// and the OS decoder is measurably incomplete — it failed 17 of the 1186
/// samples in the real `FluidR3Mono_GM.sf3`, all of them short single-cycle
/// wavetables. See `Sources/CStbVorbis/VENDORED.md` for the full measurement.
public struct StbVorbisDecoder: VorbisDecoding {
    public init() {}

    public func decodeVorbis(_ data: Data) throws -> VorbisPCM {
        guard !data.isEmpty else {
            throw ProjectError.importFailed("the compressed audio stream is empty")
        }
        var channels: Int32 = 0
        var sampleRate: Int32 = 0
        var samples: UnsafeMutablePointer<Int16>?

        let frames: Int32 = data.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return cstb_vorbis_decode(base, Int32(buffer.count), &channels, &sampleRate, &samples)
        }

        // A negative return is the ONLY failure signal, by the shim's contract:
        // it never hands back an empty buffer for a stream it could not read,
        // so "undecodable" can never be mistaken here for "legitimately empty"
        // and written into a bank as silence.
        guard frames > 0, let samples, channels > 0, sampleRate > 0 else {
            if let samples { cstb_vorbis_free(samples) }
            throw ProjectError.importFailed(
                "the compressed audio stream could not be decoded (stb_vorbis error \(frames))")
        }
        defer { cstb_vorbis_free(samples) }

        let count = Int(frames) * Int(channels)
        let pcm = Array(UnsafeBufferPointer(start: samples, count: count))
        return VorbisPCM(samples: pcm, channels: Int(channels), sampleRate: Int(sampleRate))
    }
}
