import Foundation
import Testing
import DAWAppKit
@testable import DAWCore
@testable import DAWEngine

/// The Export dialog (m23-m3) driven through the REAL store and the REAL engine,
/// asserted on **the file on disk**.
///
/// Why this suite exists and why it is not in `DAWAppKitTests`: the load-bearing
/// question is not "does the picker offer AIFF" — that passes on an
/// implementation that renders the control and never plumbs it, which is exactly
/// how m23-m2's protocol-default hazard failed. It is "does the dialog's chosen
/// state reach the bytes". So every leg here calls
/// `ExportDialogModel.export(store:toPath:)` — **the same method the sheet's
/// EXPORT button and `debug.exportDialog {exportToPath}` call** — and reads the
/// result back with a hand-rolled RIFF/FORM parser that did not write the file
/// (no AVFoundation, no AudioToolbox: the writer must not be its own witness).
@MainActor
@Suite("Export dialog → file on disk (m23-m3)", .serialized)
struct ExportDialogRenderTests {

    // MARK: - Session

    /// The engine is returned and MUST be held by the caller: `ProjectStore.engine`
    /// is `weak`, so a temporary `AudioEngine()` is deallocated before the render
    /// and every call throws `engineUnavailable` (the m23-m2 suite's lesson).
    private func makeSession() throws -> (ProjectStore, URL, AudioEngine, [Track]) {
        let fixtures = try TestSignals.fixtures()
        let drums = Track(name: "Drums", kind: .audio, pan: -0.3,
                          clips: [Clip(name: "d", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)])
        let bass = Track(name: "Bass", kind: .audio, volume: 0.7, pan: 0.4,
                         clips: [Clip(name: "b", startBeat: 0, lengthBeats: 4,
                                      audioFileURL: fixtures.cos1k48Quarter)])
        let engine = AudioEngine()
        let store = ProjectStore()
        store.engine = engine
        store.tracks = [drums, bass]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-export-dialog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (store, dir, engine, [drums, bass])
    }

    private func dialog(for store: ProjectStore) -> ExportDialogModel {
        let model = ExportDialogModel()
        model.prepare(tracks: store.tracks)
        return model
    }

    // MARK: - A reader that did not write the file

    /// What a container says about itself, read straight out of the bytes.
    struct Probe: Equatable {
        /// "RIFF/WAVE", "FORM/AIFC", "FORM/AIFF", or the raw pair for anything
        /// else (a CAF written under a .wav name reads "caff/…" — the m23-m2 bug).
        let form: String
        let bitsPerSample: Int
        /// WAV: format tag 3 (IEEE float) or the extensible sub-format.
        /// AIFF: the AIFC compression type is `fl32`/`fl64`.
        let isFloat: Bool
        let channels: Int
    }

    private func probe(_ path: String) throws -> Probe {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.count > 16, "file is too small to be an audio container: \(data.count) bytes")
        let magic = ascii(data, 0, 4)
        let type = ascii(data, 8, 4)
        switch magic {
        case "RIFF": return try probeRIFF(data, form: "RIFF/" + type)
        case "FORM": return try probeAIFF(data, form: "FORM/" + type)
        default: return Probe(form: magic + "/" + type, bitsPerSample: 0,
                              isFloat: false, channels: 0)
        }
    }

    private func probeRIFF(_ data: Data, form: String) throws -> Probe {
        // Chunks start at 12; each is a 4-byte id + a LITTLE-endian UInt32 size,
        // payload padded to an even length.
        var offset = 12
        while offset + 8 <= data.count {
            let id = ascii(data, offset, 4)
            let size = Int(u32le(data, offset + 4))
            let body = offset + 8
            if id == "fmt " && body + 16 <= data.count {
                var tag = Int(u16le(data, body))
                let channels = Int(u16le(data, body + 2))
                let bits = Int(u16le(data, body + 14))
                // WAVE_FORMAT_EXTENSIBLE keeps the real tag in the sub-format
                // GUID's first two bytes (at +24 of the fmt body).
                if tag == 0xFFFE, body + 26 <= data.count { tag = Int(u16le(data, body + 24)) }
                return Probe(form: form, bitsPerSample: bits, isFloat: tag == 3,
                             channels: channels)
            }
            offset = body + size + (size % 2)
        }
        return Probe(form: form, bitsPerSample: 0, isFloat: false, channels: 0)
    }

    private func probeAIFF(_ data: Data, form: String) throws -> Probe {
        // Same walk, BIG-endian sizes — AIFF is a big-endian IFF container.
        var offset = 12
        while offset + 8 <= data.count {
            let id = ascii(data, offset, 4)
            let size = Int(u32be(data, offset + 4))
            let body = offset + 8
            if id == "COMM" && body + 18 <= data.count {
                let channels = Int(u16be(data, body))
                let bits = Int(u16be(data, body + 6))
                // AIFF-C names its encoding in a 4CC after the 10-byte extended
                // sample rate: 'NONE' = big-endian PCM, 'fl32' = 32-bit float.
                let compression = size >= 22 ? ascii(data, body + 18, 4) : "NONE"
                return Probe(form: form, bitsPerSample: bits,
                             isFloat: compression == "fl32" || compression == "fl64",
                             channels: channels)
            }
            offset = body + size + (size % 2)
        }
        return Probe(form: form, bitsPerSample: 0, isFloat: false, channels: 0)
    }

    /// Peak |sample| of a 16-bit RIFF file, read straight out of the `data`
    /// chunk — the honest measurement of what LANDED, as opposed to the
    /// pre-quantization number in the render report.
    private func peakInt16(_ path: String) throws -> Int {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(ascii(data, 0, 4) == "RIFF")
        // Refuse to read a file that is not what the caller thinks it is: on the
        // "never plumbs the depth" mutant this parser cheerfully read a Float32
        // buffer as pairs of integers and returned 32766, which is a number that
        // MEANS nothing. A reader must say so rather than answer anyway.
        let shape = try probe(path)
        #expect(shape.bitsPerSample == 16 && !shape.isFloat,
                "peakInt16 was handed a \(shape.bitsPerSample)-bit \(shape.isFloat ? "float" : "integer") file")
        var offset = 12
        while offset + 8 <= data.count {
            let id = ascii(data, offset, 4)
            let size = Int(u32le(data, offset + 4))
            let body = offset + 8
            if id == "data" {
                var peak = 0
                var index = body
                let end = min(body + size, data.count) - 1
                while index < end {
                    let raw = Int(Int16(bitPattern: u16le(data, index)))
                    peak = max(peak, raw == Int(Int16.min) ? 32768 : abs(raw))
                    index += 2
                }
                return peak
            }
            offset = body + size + (size % 2)
        }
        return 0
    }

    private func ascii(_ data: Data, _ offset: Int, _ count: Int) -> String {
        guard offset + count <= data.count else { return "" }
        return String(bytes: data[data.startIndex + offset ..< data.startIndex + offset + count],
                      encoding: .ascii) ?? ""
    }

    private func u16le(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[d.startIndex + o]) | (UInt16(d[d.startIndex + o + 1]) << 8)
    }
    private func u32le(_ d: Data, _ o: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(d[d.startIndex + o + $1]) << (8 * UInt32($1))) }
    }
    private func u16be(_ d: Data, _ o: Int) -> UInt16 {
        (UInt16(d[d.startIndex + o]) << 8) | UInt16(d[d.startIndex + o + 1])
    }
    private func u32be(_ d: Data, _ o: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(d[d.startIndex + o + $1]) }
    }

    // MARK: - Leg 0: the parser is not blind (a positive control)

    @Test("the hand-rolled parser distinguishes the containers it is asked to judge")
    func parserIsNotBlind() async throws {
        let (store, dir, engine, _) = try makeSession()
        defer { _ = engine }
        let wav = try await store.renderBounce(
            toPath: dir.appendingPathComponent("control").path, durationSeconds: 0.5)
        let aiff = try await store.renderBounce(
            toPath: dir.appendingPathComponent("control-aiff").path,
            durationSeconds: 0.5, bitDepth: 16, container: "aiff")
        // If these two read the same, every assertion below is vacuous.
        #expect(try probe(wav.path).form == "RIFF/WAVE")
        #expect(try probe(aiff.path).form == "FORM/AIFC")
        #expect(try probe(wav.path) != probe(aiff.path))
    }

    // MARK: - Leg 1: the untouched dialog is BYTE-IDENTICAL to today's bounce

    @Test("open the dialog, change nothing, export → byte-identical to renderBounce(toPath:)")
    func defaultPathIsByteIdentical() async throws {
        let (store, dir, engine, _) = try makeSession()
        defer { _ = engine }
        let model = dialog(for: store)

        let viaDialog = dir.appendingPathComponent("via-dialog.wav").path
        #expect(await model.export(store: store, toPath: viaDialog))
        let viaStore = try await store.renderBounce(toPath: dir.appendingPathComponent("via-store").path)

        let a = try Data(contentsOf: URL(fileURLWithPath: viaDialog))
        let b = try Data(contentsOf: URL(fileURLWithPath: viaStore.path))
        #expect(a.count == b.count, "sizes differ: \(a.count) vs \(b.count)")
        #expect(a == b, "the dialog's default path is NOT today's bounce")
        // …and it is the shipped format, not merely a matching pair.
        let disk = try probe(viaDialog)
        #expect(disk.form == "RIFF/WAVE")
        #expect(disk.bitsPerSample == 32)
        #expect(disk.isFloat)
    }

    @Test("a dialled PEAK LIMIT with normalization OFF still lands byte-identical")
    func inertCeilingDoesNotReachTheBytes() async throws {
        let (store, dir, engine, _) = try makeSession()
        defer { _ = engine }
        let model = dialog(for: store)
        // The ceiling control is nested under the toggle in the sheet; this is
        // the leg proving the nesting is not merely cosmetic — a request that
        // leaked the value would put it in the report of a render that never
        // read it.
        model.truePeakCeilingDb = -6
        model.lufsTarget = -9
        let path = dir.appendingPathComponent("inert.wav").path
        #expect(await model.export(store: store, toPath: path))
        let reference = try await store.renderBounce(
            toPath: dir.appendingPathComponent("reference").path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path))
                == (try Data(contentsOf: URL(fileURLWithPath: reference.path))))
    }

    // MARK: - Leg 2: the chosen format reaches the bytes

    @Test("16-bit AIFF picked in the dialog lands as FORM/AIFC, sample size 16")
    func sixteenBitAIFFReachesTheBytes() async throws {
        let (store, dir, engine, _) = try makeSession()
        defer { _ = engine }
        let model = dialog(for: store)
        model.setBitDepth(16)
        model.setContainer(.aiff)

        // The name the save panel would offer — the extension comes from the
        // model's DeliveryFormat, and it is what actually selects the container.
        let name = model.suggestedFileName(projectName: "Night Drive")
        #expect(name == "Night Drive.aiff")
        let path = dir.appendingPathComponent(name).path
        #expect(await model.export(store: store, toPath: path))

        let outcome = try #require(model.lastExport)
        #expect(outcome.path.hasSuffix("Night Drive.aiff"))
        let disk = try probe(outcome.path)
        #expect(disk.form == "FORM/AIFC")
        #expect(disk.bitsPerSample == 16)
        #expect(!disk.isFloat)
        #expect(disk.channels == 2)
        #expect(outcome.formatLabel == "16-bit integer AIFF")
    }

    @Test("24-bit WAV picked in the dialog lands as RIFF/WAVE, 24-bit integer PCM")
    func twentyFourBitWAVReachesTheBytes() async throws {
        let (store, dir, engine, _) = try makeSession()
        defer { _ = engine }
        let model = dialog(for: store)
        model.setBitDepth(24)
        let path = dir.appendingPathComponent(model.suggestedFileName(projectName: "Mix")).path
        #expect(await model.export(store: store, toPath: path))
        let disk = try probe(try #require(model.lastExport).path)
        #expect(disk.form == "RIFF/WAVE")
        #expect(disk.bitsPerSample == 24)
        #expect(!disk.isFloat)
    }

    /// The named legs above cover three of the EIGHT combinations the sheet
    /// offers. `DeliveryFormatWriteTests.everyCombinationOnDisk` pins all eight
    /// at the WRITER (m23-m2) — but that suite calls `writeAudioFile` directly,
    /// so it cannot see a dialog that offers a control and never plumbs it. This
    /// leg walks the picker's OWN vocabulary end to end: 32-bit integer and
    /// float-AIFF are both clickable and were, until this leg, never inspected
    /// on disk through the dialog's path. It is also what first EXECUTES the
    /// `fl32` branch of `probeAIFF` — a dead branch in a reader is itself a
    /// blind spot.
    @Test("every depth × container the picker OFFERS lands as that format")
    func everyOfferedCombinationReachesTheBytes() async throws {
        let (store, dir, engine, _) = try makeSession()
        defer { _ = engine }
        let model = dialog(for: store)

        for container in DeliveryContainer.allCases {
            for depth in DeliveryFormat.selectableBitDepths {
                model.setBitDepth(depth)
                model.setContainer(container)
                // Through the model's own naming path, so the EXTENSION under
                // test is the one the save panel would have offered.
                let stem = "Matrix \(DeliveryFormat.depthLabel(depth)) \(container.label)"
                let name = model.suggestedFileName(projectName: stem)
                #expect(name == stem + "." + container.rawValue, "offered name \(name)")
                #expect(await model.export(store: store,
                                           toPath: dir.appendingPathComponent(name).path))
                let outcome = try #require(model.lastExport, "no export for \(name)")
                #expect(outcome.path.hasSuffix(name), "landed at \(outcome.path)")

                let disk = try probe(outcome.path)
                #expect(disk.form == (container == .wav ? "RIFF/WAVE" : "FORM/AIFC"),
                        "\(name): container reads \(disk.form)")
                #expect(disk.channels == 2, "\(name): \(disk.channels) channels")
                if let depth {
                    #expect(disk.bitsPerSample == depth, "\(name): \(disk.bitsPerSample) bits")
                    #expect(!disk.isFloat, "\(name) must not be float on disk")
                } else {
                    #expect(disk.bitsPerSample == 32, "\(name): \(disk.bitsPerSample) bits")
                    #expect(disk.isFloat, "\(name) must stay 32-bit FLOAT")
                }
                print("[measured] \(name): \(disk.form) bits=\(disk.bitsPerSample) "
                      + "float=\(disk.isFloat)")
            }
        }
    }

    @Test("a REFUSED depth never reaches the bytes — the file is still the default")
    func refusedDepthNeverReachesTheBytes() async throws {
        let (store, dir, engine, _) = try makeSession()
        defer { _ = engine }
        let model = dialog(for: store)
        // The picker cannot produce this; the debug seam could try. The model
        // refuses (keeping the standing format) rather than coercing — and this
        // is the leg that proves the refusal is not merely a model nicety.
        model.setBitDepth(48)
        let path = dir.appendingPathComponent("refused.wav").path
        #expect(await model.export(store: store, toPath: path))
        #expect(model.lastError == nil, "a refused pick must not fail the export")
        let disk = try probe(path)
        #expect(disk.bitsPerSample == 32)
        #expect(disk.isFloat)
    }

    // MARK: - Leg 3: leaving a track out really silences it

    @Test("excluding a track through the dialog changes the AUDIO, not the project")
    func exclusionIsPerformedNotJustReported() async throws {
        let (store, dir, engine, tracks) = try makeSession()
        defer { _ = engine }
        let model = dialog(for: store)

        let full = dir.appendingPathComponent("full.wav").path
        #expect(await model.export(store: store, toPath: full))

        model.toggleExcluded(tracks[1].id)          // Bass
        let instrumental = dir.appendingPathComponent("instrumental.wav").path
        #expect(await model.export(store: store, toPath: instrumental))

        // The echo…
        let outcome = try #require(model.lastExport)
        #expect(outcome.excludedTracks == ["Bass"])
        // …and the audio, which is the half an echo cannot fake (m23-m1: an
        // implementation that REPORTS an exclusion without performing it passes
        // every echo leg).
        let a = try Data(contentsOf: URL(fileURLWithPath: full))
        let b = try Data(contentsOf: URL(fileURLWithPath: instrumental))
        #expect(a != b, "the instrumental is byte-identical to the full mix — nothing was silenced")

        // The project itself is untouched: this is the entire reason the
        // parameter exists rather than telling people to mute by hand.
        #expect(store.tracks.allSatisfy { !$0.isMuted })
        #expect(store.tracks.map(\.name) == ["Drums", "Bass"])
    }

    // MARK: - Leg 4: normalization moves the samples that land

    @Test("a loudness target picked in the dialog changes the samples on disk")
    func normalizationReachesTheBytes() async throws {
        let (store, dir, engine, _) = try makeSession()
        defer { _ = engine }
        let model = dialog(for: store)
        model.setBitDepth(16)   // so the peak can be read as plain integers

        let plain = dir.appendingPathComponent("plain.wav").path
        #expect(await model.export(store: store, toPath: plain))

        // Well below the fixture program, so the gain is a genuine REDUCTION and
        // the true-peak ceiling cannot be what moved it.
        model.normalize = true
        model.lufsTarget = -40
        let quiet = dir.appendingPathComponent("quiet.wav").path
        #expect(await model.export(store: store, toPath: quiet))

        let plainPeak = try peakInt16(plain)
        let quietPeak = try peakInt16(quiet)
        #expect(plainPeak > 0, "the fixture program is silent — every leg here would be vacuous")
        #expect(quietPeak < plainPeak / 2,
                "normalization did not reach the samples: \(quietPeak) vs \(plainPeak)")
        #expect(try #require(model.lastExport).limitedByCeiling == false,
                "a reduction toward -40 must not be ceiling-limited")
    }
}
