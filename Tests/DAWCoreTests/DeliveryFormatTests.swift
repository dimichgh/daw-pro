import Foundation
import Testing
@testable import DAWCore

/// m23-m2 `DeliveryFormat` — the ONE home for bit depth, container AND the file
/// extension, headless. Nothing here touches AVFoundation: what the settings
/// dictionary does with these values is asserted against the real writer in
/// `DeliveryFormatWriteTests`; what lands on disk, in
/// `DeliveryFormatRenderTests`.
@Suite("Delivery format — the value type (m23-m2)")
struct DeliveryFormatTests {

    // MARK: - resolve is the only producer

    @Test("valid combinations resolve; the default is Float32 WAV")
    func validCombinations() throws {
        let fallback = try DeliveryFormat.resolve(bitDepth: nil, container: nil)
        #expect(fallback == .default)
        #expect(fallback.isDefault)
        #expect(fallback.bitDepth == nil)
        #expect(fallback.container == .wav)
        #expect(fallback.fileExtension == "wav")

        for depth in [16, 24, 32] {
            for container in ["wav", "aiff"] {
                let format = try DeliveryFormat.resolve(bitDepth: depth, container: container)
                #expect(format.bitDepth == depth)
                #expect(format.container.rawValue == container)
                #expect(format.fileExtension == container)
                #expect(!format.isDefault)
            }
        }
        let aiffFloat = try DeliveryFormat.resolve(bitDepth: nil, container: "aiff")
        #expect(aiffFloat.bitDepth == nil)
        #expect(aiffFloat.fileExtension == "aiff")
        #expect(!aiffFloat.isDefault, "a non-WAV container is not the default path")
    }

    @Test("an off-list depth or container is refused, by name")
    func invalidInputsRefused() {
        for bad in [8, 12, 20, 48, 64, 0, -1] {
            #expect(throws: ProjectError.self) {
                _ = try DeliveryFormat.resolve(bitDepth: bad, container: nil)
            }
        }
        for bad in ["mp3", "flac", "caf", "aif", "WAV", "AIFF", "wave", ""] {
            #expect(throws: ProjectError.self) {
                _ = try DeliveryFormat.resolve(bitDepth: nil, container: bad)
            }
        }
        // The message names the offending value and lists the alternatives —
        // it is what the control protocol and MCP surface verbatim.
        do {
            _ = try DeliveryFormat.resolve(bitDepth: 20, container: nil)
            Issue.record("expected a throw")
        } catch let error as ProjectError {
            let text = error.errorDescription ?? ""
            #expect(text.contains("bitDepth"))
            #expect(text.contains("20"))
            #expect(text.contains("16"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
        do {
            _ = try DeliveryFormat.resolve(bitDepth: nil, container: "mp3")
            Issue.record("expected a throw")
        } catch let error as ProjectError {
            let text = error.errorDescription ?? ""
            #expect(text.contains("container"))
            #expect(text.contains("mp3"))
            #expect(text.contains("aiff"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    // MARK: - The load-bearing extension

    @Test("the DEFAULT format's extension policy is byte-identical to pre-m23-m2 — except the CAF bug")
    func defaultExtensionPolicyPreserved() {
        let wav = DeliveryFormat.default
        // Pre-m23-m2 rule, verbatim: append ".wav" unless it already ends in
        // ".wav" (case-insensitively). Every one of these was MEASURED against
        // the pre-change tree.
        #expect(wav.applyingExtension(to: "/t/p1") == "/t/p1.wav")
        #expect(wav.applyingExtension(to: "/t/p2.wav") == "/t/p2.wav")
        #expect(wav.applyingExtension(to: "/t/p4.aiff") == "/t/p4.aiff.wav")
        #expect(wav.applyingExtension(to: "/t/p5.aif") == "/t/p5.aif.wav")
        #expect(wav.applyingExtension(to: "/t/p6.xyz") == "/t/p6.xyz.wav")
        // The ONE deliberate deviation, and it is a bug fix: the old rule
        // accepted ".WAV" case-insensitively and left it alone, but
        // AVAudioFile's extension matching is case-SENSITIVE, so the file
        // landed as a **CAF** named ".WAV" (measured). Canonicalized now.
        #expect(wav.applyingExtension(to: "/t/p3.WAV") == "/t/p3.wav")
        #expect(wav.applyingExtension(to: "/t/p3.Wav") == "/t/p3.wav")
    }

    @Test("the container's extension is applied without ever clobbering the caller's name")
    func aiffExtensionPolicy() throws {
        let aiff = try DeliveryFormat.resolve(bitDepth: nil, container: "aiff")
        #expect(aiff.applyingExtension(to: "/t/mix") == "/t/mix.aiff")
        #expect(aiff.applyingExtension(to: "/t/mix.aiff") == "/t/mix.aiff")
        // Appended, NOT replaced: an appended extension is ugly, a clobbered
        // one is unrecoverable — and appending is what keeps the default
        // format's behaviour byte-identical in the mirror-image case above.
        #expect(aiff.applyingExtension(to: "/t/mix.wav") == "/t/mix.wav.aiff")
        // `.aif` / `.aifc` ALREADY denote this container to the writer
        // (measured: both produce FORM/AIFC), so they are kept rather than
        // doubled up.
        #expect(aiff.applyingExtension(to: "/t/mix.aif") == "/t/mix.aif")
        #expect(aiff.applyingExtension(to: "/t/mix.aifc") == "/t/mix.aifc")
        #expect(aiff.applyingExtension(to: "/t/mix.AIFF") == "/t/mix.aiff")
        #expect(aiff.applyingExtension(to: "/t/mix.AIF") == "/t/mix.aif")
        // ".wave" is NOT a container the writer knows (it falls through to
        // CAF), so it is treated as an ordinary name fragment.
        #expect(aiff.applyingExtension(to: "/t/mix.wave") == "/t/mix.wave.aiff")
    }

    @Test("generated names carry the format's extension")
    func generatedFileNames() throws {
        #expect(DeliveryFormat.default.fileName("00 Mixdown") == "00 Mixdown.wav")
        let aiff = try DeliveryFormat.resolve(bitDepth: 24, container: "aiff")
        #expect(aiff.fileName("00 Mixdown") == "00 Mixdown.aiff")
        #expect(aiff.fileName("00 Mastered Mix") == "00 Mastered Mix.aiff")

        // The stem plan reads the same home — no second ".wav" literal.
        var taken = Set<String>()
        #expect(StemPlan.fileName(index: 1, name: "Drums", kind: .track,
                                  taken: &taken) == "01 Drums.wav")
        var takenAiff = Set<String>()
        #expect(StemPlan.fileName(index: 2, name: "Bass", kind: .track,
                                  taken: &takenAiff, format: aiff) == "02 Bass.aiff")
        let ids = [Track(name: "A", kind: .audio), Track(name: "B", kind: .audio)]
        let descriptors = try StemPlan.descriptors(tracks: ids, including: nil, format: aiff)
        #expect(descriptors.map(\.fileName) == ["01 A.aiff", "02 B.aiff"])
        let defaults = try StemPlan.descriptors(tracks: ids, including: nil)
        #expect(defaults.map(\.fileName) == ["01 A.wav", "02 B.wav"])
    }

    // MARK: - The wire echo (omitted-when-default, the m23-m1 convention)

    @Test("echo fields are omitted for the default and present otherwise")
    func wireEcho() throws {
        let fallback = DeliveryFormat.default
        #expect(fallback.reportedBitDepth == nil)
        #expect(fallback.reportedContainer == nil)
        #expect(fallback.reportedDitherApplied == nil)

        let deep = try DeliveryFormat.resolve(bitDepth: 24, container: nil)
        #expect(deep.reportedBitDepth == 24)
        #expect(deep.reportedContainer == nil, "WAV stays omitted — absence means the default")
        #expect(deep.reportedDitherApplied == false, "v0 does not dither and says so")

        let aiff = try DeliveryFormat.resolve(bitDepth: nil, container: "aiff")
        #expect(aiff.reportedBitDepth == nil)
        #expect(aiff.reportedContainer == "aiff")
        #expect(aiff.reportedDitherApplied == nil,
                "no integer depth → dithering could not apply either way")
    }

    @Test("label reads for humans")
    func labels() throws {
        #expect(DeliveryFormat.default.label == "32-bit float WAV")
        #expect(try DeliveryFormat.resolve(bitDepth: 24, container: "aiff").label
                == "24-bit integer AIFF")
    }
}
