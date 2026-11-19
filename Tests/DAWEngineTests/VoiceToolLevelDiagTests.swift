import AVFoundation
import CryptoKit
import Foundation
import Testing

@testable import DAWCore
@testable import DAWEngine

// W9-VDIAG (diagnosis of vf-10 / vf-15 / vf-16 / vf-17, the Voice tool's level and top end): renders only, no
// assertions on the product's sound. ⛔ ENV-GATED: every test here is skipped unless `VDIAG=1`.
//  - `grid`: a sung take's saved tracks (W9-MF's `<source>-tracks.json` + `<source>-take.wav`), edited with the pitch
//    editor's own writers (`setClipNotePitchOffsets`, `setClipFormantCorrection`, `setClipNoteFormant`) over
//    move {−12, −5, 0, +5, +12} st × Keep voice size {ON, OFF} × Voice {−6, −2, 0, +2, +6}, each cell rendered by the
//    app's offline render (`StretchRenderCache` + `OfflineRenderer`, the body of `AudioEngine.renderOffline`, the
//    shape of `MaleToFemaleSingTests`' `MFSong.render`). Plus `raw`: the same clip with NO pitch-edit table.
//  - `probe`: synthetic inputs (written by the lane's python, read here) through the product's stretcher entry
//    `OfflineStretcher.stretchTransposeCurve` with the shipping latency compensation and an ENGAGED formant curve
//    (explicit base = the tone's f0, i.e. the envelope-through-harmonic-peaks branch), at fixed (transpose, formant).
// Deliberately NOT `@MainActor` (the suite cap): the store and the render hop to it.

enum VDiag {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["VDIAG"] == "1"
    static let tempo = 100.0
    static let renderSeconds = 27.0

    static func sha(_ channels: [[Float]]) -> String {
        var hasher = SHA256()
        for channel in channels {
            channel.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Float32 WAV (WAVE_FORMAT_IEEE_FLOAT), interleaved.
    static func writeWAV(_ channels: [[Float]], sampleRate: Double, to url: URL) throws {
        let count = channels.map(\.count).min() ?? 0
        let numChannels = channels.count
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let dataBytes = UInt32(count * numChannels * 4)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(UInt16(numChannels))
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * UInt32(numChannels) * 4); u16(UInt16(numChannels * 4)); u16(32)
        data.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        var interleaved = [Float](repeating: 0, count: count * numChannels)
        for c in 0..<numChannels {
            let channel = channels[c]
            for i in 0..<count { interleaved[i * numChannels + c] = channel[i] }
        }
        interleaved.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }

    static func readWAV(_ url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ProjectError.invalidClipEdit("no buffer for \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        var channels: [[Float]] = []
        for c in 0..<Int(buffer.format.channelCount) {
            guard let pointer = buffer.floatChannelData?[c] else { continue }
            channels.append(Array(UnsafeBufferPointer(start: pointer, count: frames)))
        }
        return (channels, file.processingFormat.sampleRate)
    }

    static func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    /// The body of `AudioEngine.renderOffline` (as `MFSong.render`), for `seconds`.
    @MainActor
    static func render(_ tracks: [Track], tempo: TempoMap, seconds: Double, work: URL,
                       label: String) async throws -> (channels: [[Float]], stretched: Int) {
        let dir = work.appendingPathComponent("stretch/\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = StretchRenderCache(directory: dir, contourDetector: .product)
        cache.debounceMillisecondsForInstance = 0
        var stretched = 0
        for track in tracks where track.kind == .audio {
            for clip in track.clips where StretchRenderCache.needsRender(clip) {
                guard let source = clip.audioFileURL else { continue }
                let params = StretchRenderCache.Params(clip: clip)
                _ = try await cache.renderIfNeeded(clipID: clip.id, source: source, params: params)
                stretched += 1
            }
        }
        let renderer = OfflineRenderer()
        renderer.stretchedFileProvider = { clip in
            guard let source = clip.audioFileURL else { return nil }
            return cache.cachedURL(source: source, params: StretchRenderCache.Params(clip: clip))
        }
        let audio = try renderer.render(tracks: tracks, tempoMap: tempo, fromBeat: 0, durationSeconds: seconds)
        return (audio.channelData, stretched)
    }
}

struct VDiagCell: Sendable {
    let label: String
    let cents: Double
    let keep: Double?
    let voice: Double
    let raw: Bool
}

struct VDiagEcho: Sendable {
    let offsets: [Int]
    let formants: [Double]
    let correction: Double?
    let voiced: Int
    let hasTable: Bool
}

@Suite("W9-VDIAG: the Voice tool's level and top end, rendered (VDIAG=1 only)")
struct VoiceToolLevelDiagTests {

    static func cells() -> [VDiagCell] {
        var out = [VDiagCell(label: "raw", cents: 0, keep: nil, voice: 0, raw: true)]
        let moves: [Int] = (VDiag.env["VDIAG_MOVES"] ?? "-12,-5,0,5,12").split(separator: ",").compactMap { Int($0) }
        let voices: [Double] = (VDiag.env["VDIAG_VOICES"] ?? "-6,-2,0,2,6").split(separator: ",")
            .compactMap { Double($0) }
        for move in moves {
            for keep in [1.0, 0.0] {
                for voice in voices {
                    let label = String(format: "m%+d_k%d_v%+.0f", move, Int(keep), voice)
                    out.append(VDiagCell(label: label, cents: Double(move * 100), keep: keep, voice: voice, raw: false))
                }
            }
        }
        return out
    }

    /// The pitch editor's own writers, as `MaleToFemaleSingTests.phase2` drives them, for one cell.
    @MainActor
    static func apply(_ cell: VDiagCell, to prepared: [Track], track t: Int, table: PitchEditSet,
                      clipID: UUID) throws -> ([Track], TempoMap, VDiagEcho) {
        let store = ProjectStore()
        try store.setTempo(VDiag.tempo)
        var base = prepared
        if cell.raw { base[t].clips[0].pitchEdits = nil }
        store.tracks = base
        if !cell.raw {
            if cell.cents != 0 {
                // Select-all + drag (W9-MF phase 2's move): every note, its own offset + the move.
                let offsets = table.segments.map {
                    NotePitchOffset(segmentId: $0.id, offsetCents: $0.pitchOffsetCents + cell.cents)
                }
                try store.setClipNotePitchOffsets(clipId: clipID, offsets: offsets,
                                                  undoKey: PitchCorrectionUndoKey.structuralKey)
            }
            try store.setClipFormantCorrection(clipId: clipID, amount: cell.keep)
            if cell.voice != 0 {
                // The Voice tool refuses a sound (`.unpitched`): the sung notes only.
                let sung = table.segments.filter { $0.origin != .unpitched }.map(\.id)
                try store.setClipNoteFormant(clipId: clipID, segmentIds: sung, semitones: cell.voice)
            }
        }
        let after = store.tracks.lazy.flatMap(\.clips).first { $0.id == clipID }?.pitchEdits
        let echo = VDiagEcho(
            offsets: Set((after?.segments ?? []).map { Int($0.pitchOffsetCents.rounded()) }).sorted(),
            formants: Set((after?.segments ?? []).map(\.formantOffsetSemitones)).sorted(),
            correction: after?.formantCorrection,
            voiced: (after?.segments ?? []).filter { $0.formantOffsetSemitones != 0 }.count,
            hasTable: after != nil)
        return (store.tracks.filter { $0.kind == .audio }, store.transport.tempoMap, echo)
    }

    /// The render's own curve for each cell, sampled every hop: the transpose, the formant shift and the formant
    /// base the stretcher is handed (`StretchRenderCache.resolveRenderContour` + `StretchCurvePlan.make`, as
    /// `renderAudio` builds them; sampled at the hop's output frame, no latency offset).
    @Test("W9-VDIAG curves: the transpose / formant / base each grid cell hands the stretcher, per hop",
          .enabled(if: VDiag.enabled && VDiag.env["VDIAG_CURVES"] == "1"))
    func curves() async throws {
        guard let outPath = VDiag.env["VDIAG_OUT"], let srcPath = VDiag.env["VDIAG_SRC"],
              outPath.hasPrefix("/private/tmp/claude-501/") else {
            Issue.record("VDIAG_OUT (scratch) and VDIAG_SRC must be set")
            return
        }
        let sources = (VDiag.env["VDIAG_SOURCES"] ?? "male-2,female-ref").split(separator: ",").map(String.init)
        let srcDir = URL(fileURLWithPath: srcPath, isDirectory: true)
        let outRoot = URL(fileURLWithPath: outPath, isDirectory: true)
        let hop = 1_440
        for source in sources {
            let out = outRoot.appendingPathComponent(source, isDirectory: true)
            let contourDir = outRoot.appendingPathComponent("contour-\(source)", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: contourDir, withIntermediateDirectories: true)
            let take = srcDir.appendingPathComponent("\(source)-take.wav")
            let sourceFrames = Int(try AVAudioFile(forReading: take).length)
            let tracksData = try Data(contentsOf: srcDir.appendingPathComponent("\(source)-tracks.json"))
            var tracks = try JSONDecoder().decode([Track].self, from: tracksData)
            guard let t = tracks.firstIndex(where: { $0.clips.first?.pitchEdits != nil }),
                  let table = tracks[t].clips.first?.pitchEdits else {
                Issue.record("\(source): no pitch-edit table")
                continue
            }
            tracks[t].clips[0].audioFileURL = take
            let clipID = tracks[t].clips[0].id
            let prepared = tracks
            var result: [String: Any] = ["hop": hop, "sourceFrames": sourceFrames]
            for cell in Self.cells() where !cell.raw {
                let (edited, _, _) = try await MainActor.run {
                    try Self.apply(cell, to: prepared, track: t, table: table, clipID: clipID)
                }
                guard let clip = edited.lazy.flatMap(\.clips).first(where: { $0.id == clipID }) else { continue }
                let params = StretchRenderCache.Params(clip: clip)
                let contour = try StretchRenderCache.resolveRenderContour(
                    params: params, source: take, renderCacheDirectory: contourDir, detector: .product,
                    isCancelled: { false })
                guard let plan = StretchCurvePlan.make(
                    editSet: params.pitchEdits, clipPitchShiftSemitones: params.semitones, sampleRate: 48_000,
                    ratio: params.ratio, contour: contour.curveContour) else {
                    result[cell.label] = ["plan": false]
                    continue
                }
                var k: [Double] = [], f: [Double] = [], b: [Double] = []
                var frame = 0
                while frame < sourceFrames {
                    k.append((plan.semitones(atOutputFrame: frame) * 1e6).rounded() / 1e6)
                    f.append((plan.formantSemitones(atOutputFrame: frame, formantPreserve: params.formantPreserve)
                              * 1e6).rounded() / 1e6)
                    b.append((plan.formantBaseHz(atOutputFrame: frame) * 1e3).rounded() / 1e3)
                    frame += hop
                }
                result[cell.label] = ["plan": true, "engages": plan.engagesFormantCurve,
                                      "formantPreserve": params.formantPreserve,
                                      "fallback": contour.fallbackReason.map { $0 as Any } ?? NSNull(), "k": k, "F": f, "base": b] as [String: Any]
            }
            try VDiag.writeJSON(result, to: out.appendingPathComponent("curves.json"))
            print("vdiag-curves| \(source): \(result.count - 2) cells")
        }
    }

    @Test("W9-VDIAG grid: move × Keep voice size × Voice through the app's offline render",
          .enabled(if: VDiag.enabled && VDiag.env["VDIAG_GRID"] == "1"))
    func grid() async throws {
        guard let outPath = VDiag.env["VDIAG_OUT"], let srcPath = VDiag.env["VDIAG_SRC"],
              outPath.hasPrefix("/private/tmp/claude-501/") else {
            Issue.record("VDIAG_OUT (scratch) and VDIAG_SRC must be set")
            return
        }
        let sources = (VDiag.env["VDIAG_SOURCES"] ?? "male-2,female-ref").split(separator: ",").map(String.init)
        let srcDir = URL(fileURLWithPath: srcPath, isDirectory: true)
        let outRoot = URL(fileURLWithPath: outPath, isDirectory: true)
        var failures: [String] = []
        for source in sources {
            let out = outRoot.appendingPathComponent(source, isDirectory: true)
            let work = outRoot.appendingPathComponent("work-\(source)", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let take = srcDir.appendingPathComponent("\(source)-take.wav")
            let tracksData = try Data(contentsOf: srcDir.appendingPathComponent("\(source)-tracks.json"))
            var tracks = try JSONDecoder().decode([Track].self, from: tracksData)
            guard let t = tracks.firstIndex(where: { $0.clips.first?.pitchEdits != nil }),
                  let table = tracks[t].clips.first?.pitchEdits else {
                Issue.record("\(source): no pitch-edit table")
                continue
            }
            // The brief's READ-ONLY copy of the take (cmp-identical to the path the tracks JSON names).
            tracks[t].clips[0].audioFileURL = take
            let clipID = tracks[t].clips[0].id
            let clipStartBeat = tracks[t].clips[0].startBeat
            let prepared = tracks
            var report: [String: Any] = [
                "source": source, "take": take.path, "segments": table.segments.count,
                "origins": Dictionary(grouping: table.segments, by: { $0.origin.rawValue }).mapValues(\.count),
                "sourceFormantCorrection": table.formantCorrection.map { $0 as Any } ?? NSNull(),
                "keepsConsonantsUntuned": table.keepsConsonantsUntuned,
                "clipStartBeat": clipStartBeat, "tempo": VDiag.tempo,
                "segmentTable": table.segments.map { seg -> [String: Any] in
                    ["id": seg.id.uuidString, "origin": seg.origin.rawValue, "start": seg.startSeconds,
                     "end": seg.endSeconds, "detectedHz": seg.detectedHz]
                },
            ]
            let reportURL = out.appendingPathComponent("grid-report.json")
            var rows: [[String: Any]] = []
            for cell in Self.cells() {
                var row: [String: Any] = ["label": cell.label, "cents": cell.cents, "voice": cell.voice,
                                          "keep": cell.keep.map { $0 as Any } ?? NSNull(), "raw": cell.raw]
                do {
                    let (edited, tempo, echo) = try await MainActor.run {
                        try Self.apply(cell, to: prepared, track: t, table: table, clipID: clipID)
                    }
                    row["echo"] = ["offsetsAfter": echo.offsets, "formantOffsetsAfter": echo.formants,
                                   "formantCorrectionAfter": echo.correction.map { $0 as Any } ?? NSNull(),
                                   "segmentsWithVoice": echo.voiced, "hasTable": echo.hasTable] as [String: Any]
                    let render = try await VDiag.render(edited, tempo: tempo, seconds: VDiag.renderSeconds,
                                                        work: work, label: cell.label)
                    let wav = out.appendingPathComponent("\(cell.label).wav")
                    try? FileManager.default.removeItem(at: wav)
                    try VDiag.writeWAV(render.channels, sampleRate: 48_000, to: wav)
                    row["render"] = wav.path
                    row["sha"] = VDiag.sha(render.channels)
                    row["stretched"] = render.stretched
                    row["frames"] = render.channels.first?.count ?? 0
                } catch {
                    row["error"] = "\(error)"
                    failures.append("\(source)/\(cell.label): \(error)")
                }
                print("vdiag| \(source) \(cell.label) sha \(String(describing: row["sha"] ?? "-").prefix(12)) "
                      + "stretched \(row["stretched"] ?? "-") \(row["error"] ?? "")")
                rows.append(row)
                report["cells"] = rows
                try VDiag.writeJSON(report, to: reportURL)
            }
            // Clean the stretch cache (the WAVs stay).
            try? FileManager.default.removeItem(at: work)
        }
        #expect(failures.isEmpty, "cells that failed: \(failures)")
    }

    /// One probe run: transpose `k` semitones, ENGAGED formant curve at `formant` semitones with base `baseHz`.
    struct ProbeConfig: Sendable {
        let k: Double
        let formant: Double
        var label: String { String(format: "k%+.0f_F%+.0f", k, formant) }
    }

    @Test("W9-VDIAG probe: synthetic tones through OfflineStretcher.stretchTransposeCurve (engaged formant curve)",
          .enabled(if: VDiag.enabled && VDiag.env["VDIAG_PROBE"] == "1"))
    func probe() async throws {
        guard let dirPath = VDiag.env["VDIAG_PROBE_DIR"], dirPath.hasPrefix("/private/tmp/claude-501/") else {
            Issue.record("VDIAG_PROBE_DIR (scratch) must be set")
            return
        }
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        let manifestData = try Data(contentsOf: dir.appendingPathComponent("in/manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let inputs = manifest["inputs"] as? [[String: Any]],
              let configList = manifest["configs"] as? [[Double]] else {
            Issue.record("bad manifest")
            return
        }
        let configs = configList.map { ProbeConfig(k: $0[0], formant: $0[1]) }
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: 48_000)
        var rows: [[String: Any]] = []
        var failures: [String] = []
        for input in inputs {
            guard let name = input["name"] as? String, let baseHz = input["baseHz"] as? Double else { continue }
            let (channels, rate) = try VDiag.readWAV(dir.appendingPathComponent("in/\(name).wav"))
            for config in configs {
                var row: [String: Any] = ["input": name, "k": config.k, "F": config.formant, "baseHz": baseHz]
                do {
                    let formant = OfflineStretcher.FormantCurve(
                        semitonesAtOutputFrame: { _ in config.formant }, baseHzAtOutputFrame: { _ in baseHz })
                    let output = try OfflineStretcher.stretchTransposeCurve(
                        input: channels, sampleRate: rate, ratio: 1,
                        semitonesAtOutputFrame: { _ in config.k }, formantPreserve: false,
                        formant: formant, compensation: compensation)
                    let wav = outDir.appendingPathComponent("\(name)__\(config.label).wav")
                    try? FileManager.default.removeItem(at: wav)
                    try VDiag.writeWAV(output, sampleRate: rate, to: wav)
                    row["out"] = wav.path
                    row["sha"] = VDiag.sha(output)
                } catch {
                    row["error"] = "\(error)"
                    failures.append("\(name) \(config.label): \(error)")
                }
                rows.append(row)
            }
            try VDiag.writeJSON(["rows": rows], to: dir.appendingPathComponent("probe-report.json"))
            print("vdiag-probe| \(name): \(configs.count) configs")
        }
        #expect(failures.isEmpty, "probe runs that failed: \(failures)")
    }
}
