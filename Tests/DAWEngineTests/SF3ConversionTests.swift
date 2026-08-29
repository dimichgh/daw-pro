import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m31-h — SF3→SF2 decode on import.
///
/// m31-g made `.sf3` VISIBLE and honest; it did not make it PLAYABLE. `.sf3` is
/// the format a consumer most likely already HAS (MuseScore ships it
/// EXCLUSIVELY), so these tests are about the difference between "import works"
/// and "import works for the file you actually downloaded".
///
/// ⭐ THE FIXTURE IS REAL. `Fixtures/sf3-conversion-fixture.sf3` carries Ogg
/// Vorbis streams copied byte for byte out of MuseScore's `FluidR3Mono_GM.sf3`
/// (see `scripts/make-sf3-fixture.py`). Two of its four samples — `square-8`
/// and `Sine Wave E4` — are among the SEVENTEEN that macOS's own undocumented
/// Vorbis decoder cannot read at all, which is a large part of why we carry
/// `stb_vorbis` instead of leaning on the OS.
///
/// ⛔ THE ASSERTION THAT MATTERS IS THE AUDITION. A converted bank that loads,
/// reports a sensible size and then makes no sound is the failure mode this
/// feature is graded against, and no byte count can see it — so the suite
/// renders notes through the real AUSampler path and asserts on the audio,
/// against a no-note silence control in the same graph.
@MainActor
@Suite("SF3 → SF2 conversion on import (m31-h)", .serialized)
struct SF3ConversionTests {

    // MARK: - Fixtures

    static var fixtureURL: URL {
        Bundle.module.url(forResource: "Fixtures/sf3-conversion-fixture", withExtension: "sf3")!
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m31h-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A library wired the way the shipping app wires it (`DAWProApp` sets the
    /// same decoder next to `store.media`).
    private func convertingLibrary(_ dir: URL) -> SoundBankLibrary {
        SoundBankLibrary(libraryDirectory: dir, scanDirectories: [dir],
                         vorbisDecoder: StbVorbisDecoder())
    }

    private func peak(_ x: [Float]) -> Float { x.reduce(0) { max($0, abs($1)) } }

    private func renderLeft(track: Track, seconds: Double = 2.0) async throws -> [Float] {
        let renderer = OfflineRenderer(maximumFrameCount: RenderBlockSize.offlineFrames)
        await renderer.prepareAudioUnits(tracks: [track])
        #expect(renderer.auRegistry.status[track.id] == .ready)
        let audio = try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                        fromBeat: 0, durationSeconds: seconds)
        return audio.channelData[0]
    }

    private func bankTrack(_ source: SoundBankSource, program: Int, pitch: Int?) -> Track {
        let notes = pitch.map { [MIDINote(pitch: $0, velocity: 127, startBeat: 1, lengthBeats: 2)] } ?? []
        return Track(
            name: "Bank", kind: .instrument,
            clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 8, notes: notes)],
            instrument: InstrumentDescriptor(
                kind: .soundBank,
                soundBank: SoundBankConfig(source: source, program: program,
                                           bankMSB: 121, bankLSB: 0)))
    }

    // MARK: - 1. The capability

    @Test("importing a .sf3 lands a REAL .sf2 in the library")
    func importProducesRealSF2() throws {
        let dir = tempDir()
        let info = try convertingLibrary(dir).importBank(from: Self.fixtureURL)

        #expect(info.format == "sf2")
        #expect(info.supported == true)
        #expect(info.unsupportedReason == nil)
        #expect(URL(fileURLWithPath: info.path).pathExtension == "sf2")

        // On disk, not merely in the returned struct — a setter's return is not
        // proof it took.
        #expect(FileManager.default.fileExists(atPath: info.path))
        let landed = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(landed == ["sf3-conversion-fixture.sf2"], "got \(landed)")

        // And it really is an SF2 now: version 2.x, no Vorbis anywhere.
        let converted = try Data(contentsOf: URL(fileURLWithPath: info.path))
        #expect(SoundFontCompression.isCompressedSoundFont(converted) == false)
        #expect(converted.count > 0)
    }

    @Test("the converted bank's samples are decompressed PCM with rebased offsets")
    func convertedSampleHeadersAreCorrect() throws {
        let dir = tempDir()
        let info = try convertingLibrary(dir).importBank(from: Self.fixtureURL)
        let data = try Data(contentsOf: URL(fileURLWithPath: info.path))
        let headers = try Self.sampleHeaders(of: data)

        #expect(headers.count == 5, "4 samples + the terminal EOS record")
        let real = headers.dropLast()
        #expect(real.map(\.name) == ["square-8", "Sticks(R)", "Sticks(L)", "Sine Wave E4"])

        // ⛔ The 0x10 Vorbis bit must be GONE — an .sf2 that still advertises it
        // describes data the file no longer contains — while the left/right
        // bits (18/20) and the stereo link survive untouched.
        #expect(real.map(\.sampleType) == [1, 2, 4, 1])
        #expect(real[1].sampleLink == 2)
        #expect(real[2].sampleLink == 1)

        // Frame counts, measured through the decoder. `square-8` is 64 frames —
        // this is one of the samples the OS decoder returns NOTHING for.
        #expect(real[0].end - real[0].start == 64)
        #expect(real[3].end - real[3].start == 104)

        for (index, header) in real.enumerated() {
            // dwStart/dwEnd are FRAME offsets now, not byte offsets, and each
            // sample is separated from the next by the spec's 46 zero frames.
            #expect(header.end > header.start, "sample \(index) is empty")
            // ⭐ Loops are RELATIVE in SF3 and ABSOLUTE in SF2. Getting this
            // wrong loops into a NEIGHBOURING sample — audible only on a
            // sustained note, so it is asserted rather than eyeballed.
            #expect(header.startLoop >= header.start, "sample \(index) loop starts before it")
            #expect(header.endLoop <= header.end, "sample \(index) loops past its own audio")
            #expect(header.sampleRate == (index == 0 ? 48000 : 44100))
        }
        // Sample 1 begins after sample 0 plus the 46-frame guard gap.
        #expect(real[1].start == real[0].end + 46)
    }

    // MARK: - 2. THE AUDITION — the assertion a byte count cannot make

    @Test("a converted bank SOUNDS: notes render audio, silence renders silence")
    func convertedBankAuditions() async throws {
        let dir = tempDir()
        let info = try convertingLibrary(dir).importBank(from: Self.fixtureURL)

        // Key 100 is inside `square-8`'s zone (96–127) — the sample macOS
        // CANNOT decode. If conversion silently dropped it, this is silent.
        let wavetable = try await renderLeft(track: bankTrack(info.source, program: 0, pitch: 100))
        let wavetablePeak = peak(wavetable)

        // Key 40 is inside `Sine Wave E4`'s zone (24–59) — also one of the 17.
        let sine = try await renderLeft(track: bankTrack(info.source, program: 0, pitch: 40))
        let sinePeak = peak(sine)

        // Key 65 plays `Sticks(R)`, an ordinary stereo-flagged sample.
        let sticks = try await renderLeft(track: bankTrack(info.source, program: 0, pitch: 65))
        let sticksPeak = peak(sticks)

        // ⭐ The control that makes the three assertions above mean something:
        // the SAME graph and the SAME bank with NO note must be silent, so a
        // stuck buffer or a noise floor cannot pass as a rendered note.
        let silent = try await renderLeft(track: bankTrack(info.source, program: 0, pitch: nil))
        let silentPeak = peak(silent)

        #expect(silentPeak < 0.0001, "[measured] no-note control peak=\(silentPeak)")
        #expect(wavetablePeak > 0.01,
                "[measured] square-8 (key 100) peak=\(wavetablePeak) — converted bank is SILENT")
        #expect(sinePeak > 0.01,
                "[measured] Sine Wave E4 (key 40) peak=\(sinePeak) — converted bank is SILENT")
        #expect(sticksPeak > 0.01,
                "[measured] Sticks(R) (key 65) peak=\(sticksPeak) — converted bank is SILENT")
    }

    // MARK: - 3. The honest-refusal path (m31-g), still intact

    @Test("with NO decoder wired, .sf3 import keeps m31-g's refusal and copies nothing")
    func refusalSurvivesWithoutDecoder() throws {
        let dir = tempDir()
        let library = SoundBankLibrary(libraryDirectory: dir, scanDirectories: [dir])

        let error = { () -> ProjectError? in
            do { _ = try library.importBank(from: Self.fixtureURL); return nil }
            catch let error as ProjectError { return error }
            catch { return nil }
        }()
        guard case .importFailed(let reason)? = error else {
            Issue.record("expected importFailed, got \(String(describing: error))")
            return
        }
        #expect(reason == "sound bank must be a .sf2 or .dls file — got sf3-conversion-fixture.sf3")
        let landed = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(landed.isEmpty, "nothing may be copied on refusal; got \(landed)")
    }

    @Test("a CORRUPT .sf3 fails loudly and leaves no partial bank behind")
    func corruptStreamFailsLoudly() throws {
        let dir = tempDir()
        let sourceDir = tempDir()
        // Real SF3 structure, but the Vorbis payload is overwritten with
        // garbage — the shape of a truncated or damaged download.
        var bytes = try Data(contentsOf: Self.fixtureURL)
        let smplStart = try Self.smplOffset(of: bytes)
        for index in smplStart..<min(smplStart + 4096, bytes.count) {
            bytes[index] = 0x7f
        }
        let corrupt = sourceDir.appendingPathComponent("Damaged.sf3")
        try bytes.write(to: corrupt)

        let error = { () -> ProjectError? in
            do { _ = try convertingLibrary(dir).importBank(from: corrupt); return nil }
            catch let error as ProjectError { return error }
            catch { return nil }
        }()
        guard case .importFailed(let reason)? = error else {
            Issue.record("a corrupt .sf3 must FAIL, not import silently — got \(String(describing: error))")
            return
        }
        // Actionable, in the m31-g tone: it names the file and says what to do.
        #expect(reason.contains("Damaged.sf3"))
        #expect(reason.contains("could not be decoded") || reason.contains("damaged"))

        // ⛔ Nothing half-written may survive: a truncated .sf2 would pass every
        // extension gate and then fail at PLAY time — the silent failure this
        // whole design exists to prevent.
        let landed = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(landed.isEmpty, "a failed conversion must leave the library clean; got \(landed)")
    }

    @Test("a file that is not a SoundFont at all is refused, not half-converted")
    func nonSoundFontIsRefused() throws {
        let dir = tempDir()
        let sourceDir = tempDir()
        let bogus = sourceDir.appendingPathComponent("NotABank.sf3")
        try Data("this is not a RIFF file".utf8).write(to: bogus)

        #expect(throws: ProjectError.self) {
            try convertingLibrary(dir).importBank(from: bogus)
        }
        let landed = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(landed.isEmpty, "got \(landed)")
    }

    // MARK: - 4. ⛔ The m31-g safety property: labelling never becomes loading

    @Test("a .sf3 is STILL not selectable as an instrument, decoder or no decoder")
    func sf3StaysUnselectable() throws {
        let dir = tempDir()
        let sf3 = dir.appendingPathComponent("Planted.sf3")
        try Data(contentsOf: Self.fixtureURL).write(to: sf3)
        let sf2 = dir.appendingPathComponent("Fine.sf2")
        try Data("not-a-real-bank-just-bytes".utf8).write(to: sf2)

        let store = ProjectStore()
        store.soundBankLibrary = convertingLibrary(dir)

        // It IS listed — the premise.
        let listed = store.availableSoundBanks().first { $0.format == "sf3" }
        #expect(listed != nil)
        // …and now the remedy names conversion rather than another application.
        #expect(listed?.unsupportedReason?.contains(".sf2") == true)

        let track = store.addTrack(name: "Lead", kind: .instrument)
        let before = store.tracks.first { $0.id == track.id }?.instrument
        #expect(throws: ProjectError.self) {
            try store.setInstrument(id: track.id, soundBank: SoundBankConfig(
                source: .file(path: sf3.path), program: 80, displayName: "Square Lead"))
        }
        #expect(store.tracks.first { $0.id == track.id }?.instrument == before)

        // Positive control: the same call with a .sf2 is accepted, so the throw
        // above is the format gate and not a broken fixture.
        #expect(throws: Never.self) {
            try store.setInstrument(id: track.id, soundBank: SoundBankConfig(
                source: .file(path: sf2.path), program: 80, displayName: "Square Lead"))
        }
    }

    @Test("the extension predicates are UNCHANGED — .sf3 is still not 'supported'")
    func predicatesUnchanged() {
        // ⭐ Conversion deliberately did NOT loosen these. The converted file
        // passes the load gates because it is genuinely `.sf2` on disk, never
        // because a gate learned about `.sf3`.
        #expect(!SoundBankLibrary.isSupportedExtension("sf3"))
        #expect(SoundBankLibrary.isSupportedExtension("sf2"))
        #expect(SoundBankLibrary.isSupportedExtension("DLS"))
        #expect(SoundBankLibrary.isDiscoverableExtension("sf3"))
    }

    // MARK: - 5. The decoder itself

    @Test("StbVorbisDecoder decodes a real MuseScore stream and throws on rubbish")
    func decoderContract() throws {
        let decoder = StbVorbisDecoder()
        let data = try Data(contentsOf: Self.fixtureURL)
        let smplStart = try Self.smplOffset(of: data)
        // The first sample in the fixture is `square-8`: 3461 bytes → 64 frames.
        let stream = data[(data.startIndex + smplStart)..<(data.startIndex + smplStart + 3461)]
        let pcm = try decoder.decodeVorbis(Data(stream))
        #expect(pcm.channels == 1)
        #expect(pcm.sampleRate == 48000)
        #expect(pcm.frames == 64)
        #expect(pcm.samples.contains { $0 != 0 }, "decoded to digital silence")

        // ⛔ It must THROW rather than return empty PCM: a decoder that answers
        // "nothing" for a stream it could not read is how a converted bank
        // grows a silent hole.
        #expect(throws: (any Error).self) { try decoder.decodeVorbis(Data()) }
        #expect(throws: (any Error).self) {
            try decoder.decodeVorbis(Data(repeating: 0x7f, count: 2048))
        }
    }

    // MARK: - Helpers: a minimal SF2 reader, independent of the writer

    struct ReadHeader {
        var name: String
        var start: UInt32, end: UInt32, startLoop: UInt32, endLoop: UInt32, sampleRate: UInt32
        var sampleLink: UInt16, sampleType: UInt16
    }

    /// Walks the RIFF tree by hand rather than reusing the converter's own
    /// parser — a reader that shares code with the writer can agree with it
    /// about a shape that is wrong.
    static func chunks(of data: Data) -> [(String, Int, Int)] {
        var found: [(String, Int, Int)] = []
        func walk(_ from: Int, _ to: Int) {
            var off = from
            while off + 8 <= to {
                let id = String(decoding: data[(data.startIndex + off)..<(data.startIndex + off + 4)],
                                as: UTF8.self)
                let size = data.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self).littleEndian
                }
                let body = off + 8
                let count = Int(size)
                guard body + count <= to else { return }
                if id == "LIST" { walk(body + 4, body + count) } else { found.append((id, body, count)) }
                off = body + count + (count & 1)
            }
        }
        walk(12, data.count)
        return found
    }

    static func smplOffset(of data: Data) throws -> Int {
        guard let smpl = chunks(of: data).first(where: { $0.0 == "smpl" }) else {
            throw ProjectError.importFailed("no smpl chunk")
        }
        return smpl.1
    }

    static func sampleHeaders(of data: Data) throws -> [ReadHeader] {
        guard let shdr = chunks(of: data).first(where: { $0.0 == "shdr" }) else {
            throw ProjectError.importFailed("no shdr chunk")
        }
        return (0..<(shdr.2 / 46)).map { index in
            let at = shdr.1 + index * 46
            func u32(_ offset: Int) -> UInt32 {
                data.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: at + offset, as: UInt32.self).littleEndian
                }
            }
            func u16(_ offset: Int) -> UInt16 {
                data.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: at + offset, as: UInt16.self).littleEndian
                }
            }
            let raw = data[(data.startIndex + at)..<(data.startIndex + at + 20)]
            return ReadHeader(
                name: String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self),
                start: u32(20), end: u32(24), startLoop: u32(28), endLoop: u32(32),
                sampleRate: u32(36), sampleLink: u16(42), sampleType: u16(44))
        }
    }
}
