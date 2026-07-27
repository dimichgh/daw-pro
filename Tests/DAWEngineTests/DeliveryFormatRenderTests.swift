import AVFAudio
import AudioToolbox
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// m23-m2 output format through the REAL store and the REAL engine — one
/// on-disk assertion per verb.
///
/// Why this suite exists separately from `DeliveryFormatWriteTests`: the format
/// crosses TWO engine seams. `render.bounce` and `render.stems` hand the engine
/// a buffer (`writeAudioFile`); `render.mixdown` has the ENGINE render AND
/// write (`renderMixdown(… to:format:)`). An implementation that plumbs only
/// the first passes every writer-level test while `render.mixdown` silently
/// keeps writing Float32 WAV.
///
/// And why it uses `AudioEngine` rather than a double: the format-aware
/// protocol methods carry an extension default, so the 4+ test doubles inherit
/// it. A store-level on-disk assertion made through a double would pass on an
/// implementation that never plumbs the parameter at all.
@MainActor
@Suite("Delivery format — through the store and engine (m23-m2)", .serialized)
struct DeliveryFormatRenderTests {

    private func makeStore(tracks: [Track], engine: AudioEngine) -> ProjectStore {
        let store = ProjectStore()
        store.engine = engine
        store.tracks = tracks
        return store
    }

    /// The engine is returned and MUST be held by the caller:
    /// `ProjectStore.engine` is `weak`, so a temporary `AudioEngine()` is
    /// deallocated before the render and every call throws `engineUnavailable`.
    private func makeSession() throws -> (ProjectStore, URL, AudioEngine) {
        let fixtures = try TestSignals.fixtures()
        let drums = Track(name: "Drums", kind: .audio, pan: -0.3,
                          clips: [Clip(name: "d", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)])
        let bass = Track(name: "Bass", kind: .audio, volume: 0.7, pan: 0.4,
                         clips: [Clip(name: "b", startBeat: 0, lengthBeats: 4,
                                      audioFileURL: fixtures.cos1k48Quarter)])
        let engine = AudioEngine()
        let store = makeStore(tracks: [drums, bass], engine: engine)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-delivery-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (store, dir, engine)
    }

    struct OnDisk {
        let container: String
        let bits: UInt32
        let isFloat: Bool
        let isBigEndian: Bool
    }

    /// Re-opened by a reader that did not write the file.
    private func inspect(_ path: String) throws -> OnDisk {
        let url = URL(fileURLWithPath: path)
        // The file MUST be bound to a local: `streamDescription` points into
        // the AVAudioFormat the AVAudioFile owns, so reading `.pointee` off a
        // temporary is a use-after-free that quietly yields an all-zero ASBD
        // (measured: bits 0, float false — assertions that would have passed
        // by accident on the wrong side).
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
        return OnDisk(container: container, bits: asbd.mBitsPerChannel,
                      isFloat: asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      isBigEndian: asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0)
    }

    // MARK: - Seam 1: render.bounce (the store hands over a buffer)

    @Test("render.bounce writes the requested depth AND container to disk")
    func bounceHonoursFormat() async throws {
        let (store, dir, engine) = try makeSession()
        defer { _ = engine }

        let deep = try await store.renderBounce(
            toPath: dir.appendingPathComponent("deep").path,
            durationSeconds: 0.5, bitDepth: 24)
        #expect(deep.path.hasSuffix("deep.wav"))
        let deepDisk = try inspect(deep.path)
        #expect(deepDisk.container == "WAVE")
        #expect(deepDisk.bits == 24)
        #expect(!deepDisk.isFloat)
        #expect(deep.bitDepth == 24)
        #expect(deep.container == nil, "the WAV default stays omitted")
        #expect(deep.ditherApplied == false, "v0 truncates and says so")

        let apple = try await store.renderBounce(
            toPath: dir.appendingPathComponent("apple").path,
            durationSeconds: 0.5, bitDepth: 16, container: "aiff")
        #expect(apple.path.hasSuffix("apple.aiff"))
        let appleDisk = try inspect(apple.path)
        #expect(appleDisk.container == "AIFC")
        #expect(appleDisk.bits == 16)
        #expect(appleDisk.isBigEndian, "AIFF is big-endian on disk")
        #expect(apple.bitDepth == 16)
        #expect(apple.container == "aiff")
    }

    // MARK: - Seam 2: render.mixdown (the ENGINE renders AND writes)

    @Test("render.mixdown writes the requested depth AND container to disk")
    func mixdownHonoursFormat() async throws {
        let (store, dir, engine) = try makeSession()
        defer { _ = engine }

        let deep = try await store.renderMixdown(
            toPath: dir.appendingPathComponent("deep").path,
            durationSeconds: 0.5, bitDepth: 24)
        #expect(deep.path.hasSuffix("deep.wav"))
        let deepDisk = try inspect(deep.path)
        #expect(deepDisk.bits == 24, "\(deepDisk.bits) bits — did the format reach renderMixdown?")
        #expect(!deepDisk.isFloat)
        #expect(deep.bitDepth == 24)
        #expect(deep.ditherApplied == false)

        let apple = try await store.renderMixdown(
            toPath: dir.appendingPathComponent("apple").path,
            durationSeconds: 0.5, container: "aiff")
        #expect(apple.path.hasSuffix("apple.aiff"))
        let appleDisk = try inspect(apple.path)
        #expect(appleDisk.container == "AIFC")
        #expect(appleDisk.isFloat, "no depth requested → Float32, in AIFF-C")
        #expect(appleDisk.isBigEndian)
        #expect(apple.container == "aiff")
        #expect(apple.bitDepth == nil)
        #expect(apple.ditherApplied == nil, "no integer depth → no dither claim either way")
    }

    // MARK: - Seam 3: render.stems (N files + the two siblings)

    @Test("render.stems writes EVERY file of the set in the requested format")
    func stemsHonourFormat() async throws {
        let (store, dir, engine) = try makeSession()
        defer { _ = engine }
        let result = try await store.renderStems(
            toDirectory: dir.appendingPathComponent("set").path,
            durationSeconds: 0.5, includeMixdown: true, includeMasteredMixdown: true,
            bitDepth: 24, container: "aiff")

        #expect(result.stems.map(\.path.lastPathComponentOfString)
                == ["01 Drums.aiff", "02 Bass.aiff"])
        let mixdownPath = try #require(result.mixdown).path
        #expect(mixdownPath.hasSuffix("00 Mixdown.aiff"))
        let masteredPath = try #require(result.masteredMixdown).path
        #expect(masteredPath.hasSuffix("00 Mastered Mix.aiff"))

        for path in result.stems.map(\.path) + [mixdownPath, masteredPath] {
            let disk = try inspect(path)
            #expect(disk.container == "AIFC", "\(path): container \(disk.container)")
            #expect(disk.bits == 24, "\(path): \(disk.bits) bits")
            #expect(!disk.isFloat, "\(path): still float")
            #expect(disk.isBigEndian, "\(path): not big-endian")
        }
        #expect(result.bitDepth == 24)
        #expect(result.container == "aiff")
        #expect(result.ditherApplied == false)
    }

    // MARK: - Leg 3: the container/extension agreement (the bounceDestination defect)

    @Test("asking for AIFF with a .wav path lands an AIFF file under an AIFF extension")
    func containerBeatsTheSuppliedExtension() async throws {
        let (store, dir, engine) = try makeSession()
        defer { _ = engine }

        // THE defect: `bounceDestination` used to force-append `.wav`, and the
        // extension is what selects the container — so this call used to return
        // "mix.wav", write a WAV, and report `container: "aiff"`.
        let bounce = try await store.renderBounce(
            toPath: dir.appendingPathComponent("mix.wav").path,
            durationSeconds: 0.25, container: "aiff")
        #expect(bounce.path.hasSuffix(".aiff"), "landed at \(bounce.path)")
        #expect(try inspect(bounce.path).container == "AIFC")
        #expect(bounce.container == "aiff")
        // The file the response NAMES is the file that exists.
        #expect(FileManager.default.fileExists(atPath: bounce.path))

        let mixdown = try await store.renderMixdown(
            toPath: dir.appendingPathComponent("raw.wav").path,
            durationSeconds: 0.25, container: "aiff")
        #expect(mixdown.path.hasSuffix(".aiff"), "landed at \(mixdown.path)")
        #expect(try inspect(mixdown.path).container == "AIFC")

        // And the reverse: an .aiff-suffixed path with the WAV default keeps
        // landing a WAV, exactly as it did before m23-m2.
        let legacy = try await store.renderBounce(
            toPath: dir.appendingPathComponent("old.aiff").path, durationSeconds: 0.25)
        #expect(legacy.path.hasSuffix("old.aiff.wav"))
        #expect(try inspect(legacy.path).container == "WAVE")
    }

    /// An UPPERCASE `.WAV` used to satisfy the destination policy's
    /// case-insensitive check and then miss `AVAudioFile`'s case-SENSITIVE
    /// extension matching — landing a **CAF** file under a `.WAV` name, with no
    /// error. Measured on the pre-m23-m2 tree; this is the leg that keeps it
    /// fixed.
    @Test("an uppercase .WAV path lands a real WAV, not a CAF")
    func uppercaseExtensionIsCanonicalized() async throws {
        let (store, dir, engine) = try makeSession()
        defer { _ = engine }
        let result = try await store.renderMixdown(
            toPath: dir.appendingPathComponent("SHOUT.WAV").path, durationSeconds: 0.25)
        #expect(result.path.hasSuffix("SHOUT.wav"), "landed at \(result.path)")
        let disk = try inspect(result.path)
        #expect(disk.container == "WAVE", "container \(disk.container) — a CAF in WAV's clothing")
        #expect(disk.isFloat)
    }

    // MARK: - Leg 5: the default path

    @Test("nil/nil renders the pre-m23-m2 Float32 WAV with NO new response keys")
    func defaultPathUnchanged() async throws {
        let (store, dir, engine) = try makeSession()
        defer { _ = engine }

        let bounce = try await store.renderBounce(
            toPath: dir.appendingPathComponent("plain").path, durationSeconds: 0.25)
        #expect(bounce.path.hasSuffix("plain.wav"))
        #expect(bounce.bitDepth == nil)
        #expect(bounce.container == nil)
        #expect(bounce.ditherApplied == nil)
        let disk = try inspect(bounce.path)
        #expect(disk.container == "WAVE")
        #expect(disk.bits == 32)
        #expect(disk.isFloat)

        // The JSON an agent receives must carry no new keys at all.
        let encoded = try JSONEncoder().encode(bounce)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["bitDepth"] == nil)
        #expect(json["container"] == nil)
        #expect(json["ditherApplied"] == nil)

        let mixdown = try await store.renderMixdown(
            toPath: dir.appendingPathComponent("plainmix").path, durationSeconds: 0.25)
        #expect(mixdown.path.hasSuffix("plainmix.wav"))
        #expect(mixdown.bitDepth == nil && mixdown.container == nil)
        #expect(try inspect(mixdown.path).isFloat)

        let stems = try await store.renderStems(
            toDirectory: dir.appendingPathComponent("plainstems").path,
            durationSeconds: 0.25, includeMixdown: true)
        #expect(stems.stems.map(\.path.lastPathComponentOfString)
                == ["01 Drums.wav", "02 Bass.wav"])
        #expect(try #require(stems.mixdown).path.hasSuffix("00 Mixdown.wav"))
        #expect(stems.bitDepth == nil && stems.container == nil && stems.ditherApplied == nil)
    }

    // MARK: - Validate-first

    @Test("an invalid format rejects BEFORE any file lands")
    func invalidFormatRejectsFirst() async throws {
        let (store, dir, engine) = try makeSession()
        defer { _ = engine }
        let target = dir.appendingPathComponent("never")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        await #expect(throws: ProjectError.self) {
            _ = try await store.renderStems(toDirectory: target.path,
                                            durationSeconds: 0.25, bitDepth: 20)
        }
        await #expect(throws: ProjectError.self) {
            _ = try await store.renderStems(toDirectory: target.path,
                                            durationSeconds: 0.25, container: "mp3")
        }
        let landed = try FileManager.default.contentsOfDirectory(atPath: target.path)
        #expect(landed.isEmpty, "a rejected format left files behind: \(landed)")

        await #expect(throws: ProjectError.self) {
            _ = try await store.renderBounce(toPath: dir.appendingPathComponent("no").path,
                                             durationSeconds: 0.25, bitDepth: 8)
        }
        await #expect(throws: ProjectError.self) {
            _ = try await store.renderMixdown(toPath: dir.appendingPathComponent("no").path,
                                              durationSeconds: 0.25, container: "flac")
        }
        #expect(!FileManager.default.fileExists(atPath:
            dir.appendingPathComponent("no.wav").path))
    }
}

private extension String {
    /// Last path component of a plain string path — reads better than a URL
    /// round trip inside a `map`.
    var lastPathComponentOfString: String { (self as NSString).lastPathComponent }
}
