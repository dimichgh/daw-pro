import AVFAudio
import AudioToolbox
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// m23-m2 output format at the WRITER: every offered depth × container
/// combination written by the real `OfflineRenderer`, then re-opened and
/// inspected BY A READER THAT DID NOT WRITE IT (`AVAudioFile(forReading:)` for
/// the stream format, `AudioFileGetProperty` for the container) — never "the
/// write succeeded", because the failure this item exists to prevent is a file
/// that opens fine and is the wrong format.
///
/// Two traps are pinned here because both fail SILENTLY:
///   · `AVLinearPCMBitDepthKey` alone is IGNORED — the base settings carry
///     `AVLinearPCMIsFloatKey = 1`, and with it left in place a 24-bit request
///     writes 32-bit float on WAV and 32-bit big-endian float (AIFF-C) on AIFF,
///     with no error raised.
///   · Endianness is dictated by the CONTAINER, which comes from the URL's path
///     extension. `AVLinearPCMIsBigEndianKey` is inert in both directions
///     (measured), so these tests assert the ON-DISK byte order and never the
///     settings key — a key-pinning test passes on a build that deletes it.
@MainActor
@Suite("Delivery format — the writer (m23-m2)", .serialized)
struct DeliveryFormatWriteTests {

    // MARK: - On-disk inspection (a reader that did not write the file)

    struct OnDisk {
        /// Four-char container type read from the file itself, e.g. "WAVE",
        /// "AIFC", "caff" — NOT inferred from the extension.
        let container: String
        let bitsPerChannel: UInt32
        let isFloat: Bool
        let isBigEndian: Bool
        let isSignedInteger: Bool
        let sampleRate: Double
        let channelCount: UInt32
    }

    private func inspect(_ url: URL) throws -> OnDisk {
        // Bound to locals and lifetime-extended on purpose:
        // `streamDescription` points into the AVAudioFormat, so reading
        // `.pointee` off a temporary is a use-after-free that quietly returns
        // an ALL-ZERO ASBD — assertions that then pass or fail by accident.
        let file = try AVAudioFile(forReading: url)
        let fileFormat = file.fileFormat
        let asbd = fileFormat.streamDescription.pointee
        withExtendedLifetime((file, fileFormat)) {}
        var container = "????"
        var audioFile: AudioFileID?
        if AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr,
           let audioFile {
            var typeID: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioFileGetProperty(audioFile, kAudioFilePropertyFileFormat,
                                    &size, &typeID) == noErr {
                var bigEndian = typeID.bigEndian
                container = withUnsafeBytes(of: &bigEndian) {
                    String(bytes: $0, encoding: .ascii) ?? "????"
                }
            }
            AudioFileClose(audioFile)
        }
        return OnDisk(
            container: container,
            bitsPerChannel: asbd.mBitsPerChannel,
            isFloat: asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            isBigEndian: asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0,
            isSignedInteger: asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
            sampleRate: asbd.mSampleRate,
            channelCount: asbd.mChannelsPerFrame)
    }

    private func makeDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-delivery-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An OFF-GRID stereo signal: 997 Hz at 0.9 amplitude, deliberately not a
    /// dyadic ramp. A signal that lands exactly on the 16-bit grid quantizes
    /// with ZERO error and CANNOT discriminate one depth from another
    /// (measured: an i/N ramp gives maxErr 0.0 at both 16 and 24 bit).
    private func offGridSignal(frames: Int = 8_192) -> RenderedAudio {
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            samples[i] = 0.9 * Float(sin(2.0 * Double.pi * 997.0 * Double(i) / 48_000.0))
        }
        return RenderedAudio(sampleRate: 48_000, channelData: [samples, samples])
    }

    // MARK: - Leg 1: every combination, asserted on disk

    @Test("every depth × container combination lands as the format it claims")
    func everyCombinationOnDisk() throws {
        let dir = try makeDir("matrix")
        let audio = offGridSignal(frames: 1_024)

        for containerCase in DeliveryContainer.allCases {
            for depth: Int? in [16, 24, 32, nil] {
                let format = try DeliveryFormat.resolve(
                    bitDepth: depth, container: containerCase.rawValue)
                let url = URL(fileURLWithPath: format.applyingExtension(
                    to: dir.appendingPathComponent("d\(depth.map(String.init) ?? "f32")-"
                                                   + containerCase.rawValue).path))
                let info = try OfflineRenderer.writeAudioFile(audio, to: url, format: format)
                let disk = try inspect(url)

                // The container, read from the file's own header. `.aiff`
                // always lands as the AIFF-C form (FORM/AIFC) — measured for
                // integer depths too, not just float.
                #expect(disk.container == (containerCase == .wav ? "WAVE" : "AIFC"),
                        "\(format.label): container \(disk.container)")
                // The endianness the CONTAINER dictates — asserted on disk,
                // never via the (inert) settings key.
                #expect(disk.isBigEndian == (containerCase == .aiff),
                        "\(format.label): bigEndian \(disk.isBigEndian)")
                if let depth {
                    #expect(disk.bitsPerChannel == UInt32(depth),
                            "\(format.label): \(disk.bitsPerChannel) bits on disk")
                    #expect(!disk.isFloat, "\(format.label) must not be float on disk")
                    #expect(disk.isSignedInteger, "\(format.label) must be signed integer")
                } else {
                    #expect(disk.bitsPerChannel == 32)
                    #expect(disk.isFloat, "the default must stay 32-bit FLOAT")
                }
                #expect(disk.sampleRate == 48_000)
                #expect(disk.channelCount == 2)
                #expect(info.channelCount == 2)
                #expect(abs(info.durationSeconds - 1_024.0 / 48_000.0) < 1e-9)
                print("[measured] \(format.label): container=\(disk.container) "
                      + "bits=\(disk.bitsPerChannel) float=\(disk.isFloat) "
                      + "bigEndian=\(disk.isBigEndian)")
            }
        }
    }

    // MARK: - Leg 2: the IsFloat trap, on BOTH containers

    @Test("the float flag is cleared for integer depths — on WAV and on AIFF")
    func floatFlagClearedOnBothContainers() throws {
        // The mapper's own contract, directly: the BASE settings carry
        // IsFloat = 1, and an integer depth MUST clear it. Leaving it set is
        // the silent trap — no error, wrong file.
        guard let baseFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000,
                                             channels: 2) else {
            Issue.record("could not build the base format")
            return
        }
        let base = baseFormat.settings
        #expect((base[AVLinearPCMIsFloatKey] as? NSNumber)?.boolValue == true,
                "premise: the base settings really do carry IsFloat = true")

        for depth in [16, 24, 32] {
            let format = try DeliveryFormat.resolve(bitDepth: depth, container: nil)
            let settings = OfflineRenderer.fileSettings(base: base, format: format)
            #expect((settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue == depth)
            #expect((settings[AVLinearPCMIsFloatKey] as? NSNumber)?.boolValue == false,
                    "\(depth)-bit must clear IsFloat — the depth key ALONE is ignored")
        }
        let defaultSettings = OfflineRenderer.fileSettings(base: base, format: .default)
        #expect((defaultSettings[AVLinearPCMIsFloatKey] as? NSNumber)?.boolValue == true,
                "the Float32 default must leave the base settings' float flag alone")

        // And end to end, where the trap actually bites differently per
        // container: WAV would stay 32-bit float, AIFF would become 32-bit
        // BIG-ENDIAN float (AIFF-C). Both are caught by the same assertion.
        let dir = try makeDir("floatflag")
        let audio = offGridSignal(frames: 512)
        for containerCase in DeliveryContainer.allCases {
            let format = try DeliveryFormat.resolve(bitDepth: 24,
                                                    container: containerCase.rawValue)
            let url = dir.appendingPathComponent(format.fileName("trap-\(containerCase.rawValue)"))
            _ = try OfflineRenderer.writeAudioFile(audio, to: url, format: format)
            let disk = try inspect(url)
            #expect(disk.bitsPerChannel == 24,
                    "\(containerCase.rawValue): \(disk.bitsPerChannel) bits — the float flag leaked")
            #expect(!disk.isFloat,
                    "\(containerCase.rawValue): still FLOAT on disk — the float flag leaked")
        }
    }

    // MARK: - Leg 4: the samples, not the header

    @Test("16- and 24-bit really quantize the AUDIO — error bounded, and 256× apart")
    func sampleFidelity() throws {
        let dir = try makeDir("fidelity")
        let audio = offGridSignal()
        var errors: [Int: Float] = [:]

        for containerCase in DeliveryContainer.allCases {
            for depth in [16, 24] {
                let format = try DeliveryFormat.resolve(bitDepth: depth,
                                                        container: containerCase.rawValue)
                let url = dir.appendingPathComponent(
                    format.fileName("ramp-\(depth)-\(containerCase.rawValue)"))
                _ = try OfflineRenderer.writeAudioFile(audio, to: url, format: format)
                let back = try TestSignals.readFile(url)
                #expect(back[0].count == audio.frameCount)
                var maxError: Float = 0
                for i in 0..<audio.frameCount {
                    maxError = max(maxError, abs(back[0][i] - audio.channelData[0][i]))
                }
                let step = Float(pow(2.0, Double(1 - depth)))  // full-scale is ±1
                print("[measured] \(format.label) maxError=\(maxError) step=\(step)")
                // Bounded by ONE quantization step (the quantizer rounds, so
                // this is generous by 2×; the bound is the contract).
                #expect(maxError <= step,
                        "\(format.label): error \(maxError) exceeds one step \(step)")
                // ... and NOT zero: a build that ignores `bitDepth` writes
                // Float32 and lands exactly 0 here, which the upper bound alone
                // would happily accept.
                #expect(maxError > step / 4,
                        "\(format.label): error \(maxError) is too small to be \(depth)-bit quantization — is the file still Float32?")
                if containerCase == .wav { errors[depth] = maxError }
            }
        }

        // THE discriminator: 8 bits of extra depth is 256× less error. A
        // header-only implementation gives the same error at both depths.
        let ratio = errors[16]! / errors[24]!
        print("[measured] 16-bit / 24-bit error ratio: \(ratio)")
        #expect(abs(ratio - 256) < 8, "expected ~256×, measured \(ratio)")
    }

    // MARK: - Leg 5: the default path is byte-identical

    @Test("nil/nil is byte-identical to the pre-m23-m2 writer")
    func defaultPathByteIdentical() throws {
        let dir = try makeDir("identity")
        let audio = offGridSignal(frames: 4_096)

        // Three entry points that must all produce the same bytes: the
        // format-less writer, the writer at `.default`, and the engine's own
        // protocol method.
        let legacy = dir.appendingPathComponent("legacy.wav")
        let explicit = dir.appendingPathComponent("explicit.wav")
        let engineWritten = dir.appendingPathComponent("engine.wav")
        _ = try OfflineRenderer.writeAudioFile(audio, to: legacy)
        _ = try OfflineRenderer.writeAudioFile(audio, to: explicit, format: .default)
        _ = try AudioEngine().writeAudioFile(audio, to: engineWritten)

        let a = try Data(contentsOf: legacy)
        let b = try Data(contentsOf: explicit)
        let c = try Data(contentsOf: engineWritten)
        #expect(a == b, "explicit .default must produce the legacy writer's bytes")
        #expect(a == c, "the engine's writeAudioFile must produce them too")
        #expect(a.count > 4_096 * 2 * 4, "sanity: real audio was written")

        // And it IS the Float32 WAV the rest of the codebase depends on.
        let disk = try inspect(legacy)
        #expect(disk.container == "WAVE")
        #expect(disk.bitsPerChannel == 32)
        #expect(disk.isFloat)
    }

    // MARK: - What an integer depth costs

    @Test("integer depths CLAMP > 0 dBFS content; Float32 preserves it")
    func integerDepthsClamp() throws {
        let dir = try makeDir("clamp")
        let over = RenderedAudio(sampleRate: 48_000,
                                 channelData: [[1.5, -1.5, 0.5, 2.0, 0, -1.0],
                                               [1.5, -1.5, 0.5, 2.0, 0, -1.0]])
        let format24 = try DeliveryFormat.resolve(bitDepth: 24, container: nil)
        let clamped = dir.appendingPathComponent("clamped.wav")
        _ = try OfflineRenderer.writeAudioFile(over, to: clamped, format: format24)
        let clampedBack = try TestSignals.readFile(clamped)
        #expect(clampedBack[0][0] < 1.0001 && clampedBack[0][0] > 0.99,
                "1.5 must clamp to full scale, measured \(clampedBack[0][0])")
        #expect(clampedBack[0][3] < 1.0001, "2.0 must clamp too")
        #expect(clampedBack[0][1] >= -1.0001 && clampedBack[0][1] <= -0.99)

        // The ii-e no-baked-headroom stance survives on the DEFAULT path.
        let intact = dir.appendingPathComponent("intact.wav")
        _ = try OfflineRenderer.writeAudioFile(over, to: intact)
        let intactBack = try TestSignals.readFile(intact)
        #expect(intactBack[0][0] == 1.5, "Float32 must keep > 0 dBFS content")
        #expect(intactBack[0][3] == 2.0)
    }
}
