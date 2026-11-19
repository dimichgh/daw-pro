import CryptoKit
import Foundation
import Testing

@testable import AIServices
@testable import DAWCore
@testable import DAWEngine

// W9-MF (a male singing voice turned into a female one, with the app's OWN tools): the "Light On" lead from the voice
// film (`scripts/video/voice/material.mjs`, 100 BPM, 32 notes, the film's lyrics), SUNG BY THE REAL SINGING ENGINE and
// HEARD THROUGH THE ENGINE'S OFFLINE RENDER, through W8-X9R's rig (`X9RRig`, `X9RExternalSidecar`, `X9RMath`).
//
// ⛔ ENV-GATED, two runs:
//  - `MF_SING=1` (phase 1): a driver has started ONE singing sidecar on a PRIVATE port from a scratch runtime (the rig's
//    `X9R_*` variables). Sings each own voice in `MF_VOICE_IDS` (from the TEST library `MF_VOICES`) an octave DOWN,
//    `builtin-1` an octave down (the same notes) and `builtin-1` as written (the female reference), seed `MF_SEED`.
//  - `MF_PHASE2=1` (phase 2, no engine): the male take's saved tracks, edited the way the pitch editor edits them
//    (`setClipNotePitchOffsets`, `setClipFormantCorrection`, `setClipNoteFormant`), each option rendered.
//    W9-MF3: `MF_FIXED=1` (or `MF_MOVE=literal|legacy|fixed`) picks how the octave move is written (`MoveMode`; the
//    literal path, phase 2's writers, stays the default), `MF_P2_LABELS` limits the options rendered, and
//    `MF_SLIDES_MODES` reads the render's own curve for each mode (`slides()`).
// Every normal run skips both. Deliberately NOT `@MainActor` (the suite cap): the store and the render hop to it.

enum MFSong {
    static let tempo = 100.0
    static let rate = 48_000.0
    static let renderSeconds = 27.0
    /// material.mjs `LINES` (D4 62 … B4 71) and `RHYTHM` ([beat in the 2-bar line, length]); the last note holds 2.4.
    static let lines: [[Int]] = [[66, 66, 64, 66, 69, 66, 64, 62], [62, 66, 66, 69, 66, 64, 62, 64],
                                 [66, 69, 69, 71, 67, 69, 67, 66], [66, 69, 66, 64, 62, 64, 66, 62]]
    static let rhythm: [(Double, Double)] = [(0.5, 0.45), (1.0, 0.45), (1.5, 0.45), (2.0, 0.9),
                                             (3.0, 0.45), (3.5, 0.9), (4.5, 0.45), (5.0, 1.9)]
    static let lyrics = "I left the light on by the door,\nin case you wan-der home to-night.\n"
        + "The ci-ty hums a song for two,\nand ev-ery win-dow's burn-ing bright."

    static func notes() -> [MIDINote] {
        var out: [MIDINote] = []
        for (line, pitches) in lines.enumerated() {
            for (i, pitch) in pitches.enumerated() {
                let (at, len) = rhythm[i]
                let last = line == 3 && i == 7
                out.append(MIDINote(id: X9RSource.fixedID(5_000 + line * 8 + i), pitch: pitch, velocity: 96,
                                    startBeat: 8 + Double(line) * 8 + at, lengthBeats: last ? 2.4 : len))
            }
        }
        return out
    }

    @MainActor
    static func store(root: URL) throws -> (ProjectStore, UUID) {
        let store = ProjectStore()
        store.media = AudioFileImporter()
        store.generationImportsDirectory = root.appendingPathComponent("generations", isDirectory: true)
        try store.setTempo(tempo)
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, name: "Lead", atBeat: 0, lengthBeats: 44, notes: notes())
        for t in store.tracks.indices {
            if let c = store.tracks[t].clips.firstIndex(where: { $0.id == clip.id }) {
                store.tracks[t].clips[c].lyrics = ClipLyrics(text: lyrics)
                return (store, clip.id)
            }
        }
        throw ProjectError.clipNotFound(clip.id)
    }

    /// `X9RRig.render`'s body (the body of `AudioEngine.renderOffline`) for `seconds`.
    @MainActor
    static func render(_ tracks: [Track], tempo: TempoMap, seconds: Double, work: URL,
                       label: String) async throws -> X9RRender {
        let dir = work.appendingPathComponent("stretch/\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = StretchRenderCache(directory: dir, contourDetector: .product)
        cache.debounceMillisecondsForInstance = 0
        var stretched = 0
        var shortfalls: [String] = []
        for track in tracks where track.kind == .audio {
            for clip in track.clips where StretchRenderCache.needsRender(clip) {
                guard let source = clip.audioFileURL else { continue }
                let params = StretchRenderCache.Params(clip: clip)
                _ = try await cache.renderIfNeeded(clipID: clip.id, source: source, params: params)
                stretched += 1
                if let shortfall = cache.contourShortfall(source: source, params: params) { shortfalls.append(shortfall) }
            }
        }
        let renderer = OfflineRenderer()
        renderer.stretchedFileProvider = { clip in
            guard let source = clip.audioFileURL else { return nil }
            return cache.cachedURL(source: source, params: StretchRenderCache.Params(clip: clip))
        }
        let audio = try renderer.render(tracks: tracks, tempoMap: tempo, fromBeat: 0, durationSeconds: seconds)
        return X9RRender(channels: audio.channelData, stretched: stretched, shortfalls: shortfalls)
    }

    static func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}

struct MFPlanFact: Sendable {
    let shift: Int
    let notes: Int
    let units: Int
    let warnings: [String]
    let t0Seconds: Double
    let atBeat: Double
}

struct MFEcho: Sendable {
    let segments: Int
    let offsetsAfter: [Int]
    let formantsAfter: [Double]
    let formantCorrectionAfter: Double?
}

extension X9RRig {
    /// ONE sing job of "Light On" in `voice` at `octaveShift`, run to `done`, with the product's word check.
    func mfJob(_ label: String, voice: SingJobVoice, octaveShift: Int, seed: UInt64, cache: SingPhraseCache,
               transcribe: @escaping @Sendable (URL) async throws -> String?) async throws -> X9RLanded {
        guard Date() < deadline else { throw X9RError("the wall-clock budget was spent before job \(label)") }
        let root = work.appendingPathComponent("jobs/\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (store, clipID) = try await MainActor.run { try MFSong.store(root: root) }
        let detect: @Sendable (URL) async throws -> [ClipPitchFrame] = { url in
            let seconds = try SingVoiceAudioDecoder.durationSeconds(of: url)
            return try await Task.detached(priority: .userInitiated) {
                try ClipPitchAnalyzer.detect(
                    fileAt: url, fromSeconds: 0, durationSeconds: seconds,
                    confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
                    silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs).frames
            }.value
        }
        let configuration = SingJobCoordinator.Configuration(
            modelPollSeconds: 0.05, enginePollSeconds: 0.05, songGeneratorRunsOutside: { false })
        let coordinator = SingJobCoordinator(
            store: store, engine: engine, synthesizer: synth, lifecycle: lifecycle, cache: cache,
            detectPitch: detect, transcribe: transcribe, configuration: configuration)
        let started = Date()
        let id = try await coordinator.submit(
            SingJobRequest(clipID: clipID, octaveShift: octaveShift, voice: voice, seed: seed)).jobID
        let jobDeadline = min(deadline, Date().addingTimeInterval(900))
        var status = try await coordinator.status(jobID: id)
        while !status.phase.isTerminal {
            if Date() > jobDeadline {
                throw X9RError("job \(label) did not end in time: \(status.phase.rawValue) \(status.stageText)")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            status = try await coordinator.status(jobID: id)
        }
        let checks = Date().addingTimeInterval(300)
        while await coordinator.isBusy(), Date() < checks { try await Task.sleep(nanoseconds: 100_000_000) }
        status = try await coordinator.status(jobID: id)
        guard status.phase == .done, let result = status.result else {
            throw X9RError("job \(label) ended \(status.phase.rawValue): \(status.error?.code ?? "-") "
                           + "\(status.error?.message ?? "") \(status.error?.detail ?? "")")
        }
        let (tracks, tempo) = await MainActor.run { (store.tracks, store.transport.tempoMap) }
        let sung = tracks.filter { $0.kind == .audio }
        guard let lead = sung.first(where: { $0.id == result.trackID }) else {
            throw X9RError("job \(label): the lead track \(result.trackID) is not in the store")
        }
        note("MF job \(label): done in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, units "
             + "\(status.unitCount) (cached \(status.cachedUnits), rendered \(status.renderedUnits)), warnings "
             + "\(status.warnings)")
        return X9RLanded(label: label, status: status, tracks: sung, tempo: tempo, lead: lead, parts: [])
    }
}

@Suite("W9-MF: a male singer from the narrator, turned female with the app's own tools (MF_SING / MF_PHASE2 only)")
struct MaleToFemaleSingTests {

    static let env = ProcessInfo.processInfo.environment
    static let singEnabled = env["MF_SING"] == "1"
    static let phase2Enabled = env["MF_PHASE2"] == "1"
    static let optionCEnabled = env["MF_OPTC"] == "1"

    /// P1's words in order, and the note each one sings ("gently" sings two: gent- then -ly).
    static let p1Words = ["row", "row", "row", "your", "boat", "gently", "down", "the", "stream"]

    static func normalized(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) })
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var prev = row[0]
            row[0] = i
            for j in 1...y.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[y.count]
    }

    /// Option (c), W9-MF resume (orchestrator 2026-10-11): the narrator's SPOKEN guide line, tuned onto the guide tune
    /// with the app's own tools, then offered to the product's voice check. Per take:
    /// 1. the words and their times: the product's `WhisperTranscriber` on the raw take;
    /// 2. the notes: `PitchNoteTable.detected(from: ClipPitchAnalyzer.detect(…))`, the pitch editor's own seed;
    /// 3. a store: the take imported on an audio track at beat 1, stretched with the clip stretch HANDLE
    ///    (`stretchClip`, the only timing tool the render reads) so the words span P1's 4.8 s, every `.detected`
    ///    note set to the P1 note of the word under its middle (`setClipNotePitchOffsets`, the editor's writer),
    ///    Keep voice size ON (`setClipFormantCorrection(1.0)`); slides follow, sounds keep their own pitch;
    /// 4. rendered by the app's offline render, and the WAV given to `SingVoicePreparation.prepare`.
    @Test("W9-MF option (c): the narrator's spoken guide line, tuned onto the guide tune, through the voice check",
          .enabled(if: MaleToFemaleSingTests.optionCEnabled))
    func optionC() async throws {
        guard let outPath = Self.env["MF_OUT_C"], let rootPath = Self.env["MF_VOICES"],
              rootPath.hasPrefix("/private/tmp/claude-501/"), !rootPath.contains("Application Support") else {
            Issue.record("MF_OUT_C and a scratch MF_VOICES must be set")
            return
        }
        let takes = (Self.env["MF_OPTC_TAKES"] ?? "").split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        let startMidi = Int(Self.env["MF_OPTC_START"] ?? "") ?? 48
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let library = SingVoiceLibrary(root: URL(fileURLWithPath: rootPath, isDirectory: true))
        let whisper = WhisperTranscriber()
        let tempo = TempoMap(constantBPM: MFSong.tempo)
        let p1 = SingGuideLine.notes.map { startMidi + $0.semitonesAboveStart }
        let detect: @Sendable (URL, Double) async throws -> [ClipPitchFrame] = { url, seconds in
            try await Task.detached(priority: .userInitiated) {
                try ClipPitchAnalyzer.detect(
                    fileAt: url, fromSeconds: 0, durationSeconds: seconds,
                    confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
                    silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs).frames
            }.value
        }
        var rows: [[String: Any]] = []
        let reportURL = out.appendingPathComponent("optc-report.json")
        for take in takes {
            let name = take.deletingPathExtension().lastPathComponent
            var row: [String: Any] = ["take": take.path, "startMidi": startMidi]
            do {
                // 1. words
                let tr = try await whisper.transcribe(WhisperTranscriptionRequest(
                    audioURL: take, tempoMap: tempo, language: "en"))
                row["transcript"] = tr.text
                var cursor = 0
                var matched: [(start: Double, end: Double)] = []
                for target in Self.p1Words {
                    var found: Int?
                    var j = cursor
                    while j < tr.words.count, j < cursor + 3 {
                        let w = Self.normalized(tr.words[j].text)
                        if w == target || (!w.isEmpty && Self.editDistance(w, target) <= (target.count >= 4 ? 2 : 1)) {
                            found = j
                            break
                        }
                        j += 1
                    }
                    guard let hit = found else { break }
                    matched.append((tr.words[hit].startSeconds, tr.words[hit].endSeconds))
                    cursor = hit + 1
                }
                row["words"] = tr.words.map { ["text": $0.text, "start": $0.startSeconds, "end": $0.endSeconds] }
                guard matched.count == Self.p1Words.count, let first = matched.first, let last = matched.last else {
                    row["error"] = "only \(matched.count) of 9 guide words found in the transcript"
                    rows.append(row)
                    continue
                }
                // 2. the editor's seed table
                let seconds = try SingVoiceAudioDecoder.durationSeconds(of: take)
                let result = try await Task.detached(priority: .userInitiated) {
                    try ClipPitchAnalyzer.detect(
                        fileAt: take, fromSeconds: 0, durationSeconds: seconds,
                        confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
                        silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs)
                }.value
                let seed = PitchNoteTable.detected(from: result)
                // which P1 note each detected note sings
                var offsets: [NotePitchOffset] = []
                var mapping: [[String: Any]] = []
                for seg in seed.segments where seg.origin == .detected {
                    let mid = (seg.startSeconds + seg.endSeconds) / 2
                    var w = matched.firstIndex { $0.start <= mid && mid <= $0.end }
                    if w == nil {
                        w = matched.indices.min { abs((matched[$0].start + matched[$0].end) / 2 - mid)
                            < abs((matched[$1].start + matched[$1].end) / 2 - mid) }
                    }
                    guard let wi = w, seg.detectedHz > 0 else { continue }
                    var note = [0, 1, 2, 3, 4, 5, 7, 8, 9][wi]
                    if wi == 5, mid > matched[5].start + 0.75 * (matched[5].end - matched[5].start) { note = 6 }
                    let target = Double(p1[note])
                    let cents = (target - VoiceRangeFit.midi(fromHz: seg.detectedHz)) * 100
                    offsets.append(NotePitchOffset(segmentId: seg.id, offsetCents: cents))
                    mapping.append(["start": seg.startSeconds, "end": seg.endSeconds, "word": Self.p1Words[wi],
                                    "note": note, "targetMidi": target, "detectedHz": seg.detectedHz,
                                    "cents": (cents * 10).rounded() / 10])
                }
                row["segments"] = Dictionary(grouping: seed.segments, by: { $0.origin.rawValue }).mapValues(\.count)
                row["mapping"] = mapping
                let span = last.end - first.start
                let ratio = min(2, max(1, SingGuideLine.spanSeconds / span))
                row["wordSpanSeconds"] = span
                row["stretchRatio"] = ratio
                // 3. the store, the app's own writers
                let root = out.appendingPathComponent("work-\(name)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let (tracks, tempoMap, clipSeconds) = try await MainActor.run {
                    () throws -> ([Track], TempoMap, Double) in
                    let store = ProjectStore()
                    store.media = AudioFileImporter()
                    try store.setTempo(MFSong.tempo)
                    let track = store.addTrack(kind: .audio)
                    let clip = try store.importAudio(url: take, toTrack: track.id, atBeat: 1)
                    _ = try store.stretchClip(trackId: track.id, clipId: clip.id, toLengthBeats: clip.lengthBeats * ratio)
                    _ = try store.setClipNotePitchOffsets(clipId: clip.id, offsets: offsets, seedIfAbsent: seed,
                                                          undoKey: PitchCorrectionUndoKey.structuralKey)
                    _ = try store.setClipFormantCorrection(clipId: clip.id, amount: 1.0)
                    let landed = store.tracks.lazy.flatMap(\.clips).first { $0.id == clip.id }
                    let secs = (landed?.lengthBeats ?? 0) * 0.6
                    return (store.tracks.filter { $0.kind == .audio }, store.transport.tempoMap, secs)
                }
                // 4. the app's offline render, then the product's voice check
                let render = try await MFSong.render(tracks, tempo: tempoMap, seconds: 0.6 + clipSeconds + 1.0,
                                                     work: root, label: name)
                let wav = out.appendingPathComponent("\(name)-tuned-C\(startMidi).wav")
                try? FileManager.default.removeItem(at: wav)
                try M23QComparisonPair.writeWAV([render.left, render.right], sampleRate: MFSong.rate, to: wav)
                row["tuned"] = wav.path
                row["stretched"] = render.stretched
                row["shortfalls"] = render.shortfalls
                let wavSeconds = try SingVoiceAudioDecoder.durationSeconds(of: wav)
                let audio = try SingVoiceAudioDecoder.decode(wav, startSeconds: 0, durationSeconds: wavSeconds)
                let frames = try await detect(wav, wavSeconds)
                row["check"] = MaleToFemaleVoiceCheckTests.json(VoiceClipCheck.run(recording: audio, pitchFrames: frames))
                do {
                    let record = try await SingVoicePreparation.prepare(
                        source: wav, name: "W9-MF (c) \(name)", kind: .file, sourceName: wav.lastPathComponent,
                        library: library, detectPitch: detect)
                    row["prepare"] = "passed"
                    row["voiceId"] = record.id
                    row["range"] = MaleToFemaleVoiceCheckTests.json(record.range)
                    row["labelsVerdict"] = record.labels.verdict.rawValue
                } catch let refusal as SingVoiceAddRefusal {
                    row["prepare"] = "refused"
                    row["code"] = refusal.code
                    row["sentence"] = refusal.sentence
                }
            } catch {
                row["error"] = "\(error)"
            }
            print("mf-c| \(name): \(row["prepare"] ?? "-") \(row["code"] ?? "") \(row["labelsVerdict"] ?? "") \(row["error"] ?? "")")
            rows.append(row)
            try MFSong.writeJSON(["rows": rows], to: reportURL)
        }
        let errors = rows.filter { $0["error"] != nil }.count
        #expect(errors < rows.count, "every take errored")
    }

    static let vocalSetEnabled = env["MF_VS"] == "1"

    /// Phase 2b (W9-MF, user pick "vocalset-yes"): REAL male singers from VocalSet (CC BY 4.0) as voice PROMPTS. The
    /// rule was pre-registered in STATUS before this ran. Per "row" excerpt (`MF_VS_ROWS`): the product's Whisper finds
    /// P1's nine words; the first line is cut (R0/V0, no app processing); then the same cut is put through the app's
    /// clip stretch handle so its beat matches P1's (R1/V1), rendered by the app. Per other file (`MF_VS_RAW`): the
    /// first ≤ 10.5 s, untouched. Every WAV goes through `VoiceClipCheck.run` (numbers) and
    /// `SingVoicePreparation.prepare` (the product's own accept/refuse, labels, range) into the TEST library.
    @Test("W9-MF phase 2b: VocalSet male singers as voice prompts, through the voice check",
          .enabled(if: MaleToFemaleSingTests.vocalSetEnabled))
    func vocalSet() async throws {
        guard let outPath = Self.env["MF_VS_OUT"], let rootPath = Self.env["MF_VOICES"],
              rootPath.hasPrefix("/private/tmp/claude-501/"), !rootPath.contains("Application Support") else {
            Issue.record("MF_VS_OUT and a scratch MF_VOICES must be set")
            return
        }
        let list: (String) -> [URL] = { key in
            (Self.env[key] ?? "").split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        }
        let rowsIn = list("MF_VS_ROWS")
        let rawsIn = list("MF_VS_RAW")
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let library = SingVoiceLibrary(root: URL(fileURLWithPath: rootPath, isDirectory: true))
        let whisper = WhisperTranscriber()
        let tempo = TempoMap(constantBPM: MFSong.tempo)
        let detect: @Sendable (URL, Double) async throws -> [ClipPitchFrame] = { url, seconds in
            try await Task.detached(priority: .userInitiated) {
                try ClipPitchAnalyzer.detect(
                    fileAt: url, fromSeconds: 0, durationSeconds: seconds,
                    confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
                    silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs).frames
            }.value
        }
        // Cut [lo, hi) of a mono signal, 20 ms fades at both cut edges, `prePad`/`postPad` seconds of silence, then
        // gain DOWN only so the true peak is ≤ −3 dBTP. Returns the samples and the gain applied (dB).
        func cut(_ x: [Float], rate: Double, lo: Double, hi: Double, prePad: Double, postPad: Double)
            -> (samples: [Float], gainDb: Double) {
            let a = max(0, Int((lo * rate).rounded())), b = min(x.count, Int((hi * rate).rounded()))
            guard b > a else { return ([], 0) }
            var y = Array(x[a..<b])
            let fade = min(Int(0.020 * rate), y.count / 2)
            for i in 0..<fade {
                let g = Float(i) / Float(fade)
                y[i] *= g
                y[y.count - 1 - i] *= g
            }
            y = [Float](repeating: 0, count: Int((prePad * rate).rounded())) + y
                + [Float](repeating: 0, count: Int((postPad * rate).rounded()))
            var gainDb = 0.0
            if let tp = Loudness.measure(RenderedAudio(sampleRate: rate, channelData: [y])).truePeakDbtp,
               tp.isFinite, tp > -3 {
                gainDb = -3 - tp
                let g = Float(pow(10, gainDb / 20))
                for i in y.indices { y[i] *= g }
            }
            return (y, gainDb)
        }
        // The product's check + prepare on one WAV, into `row`.
        func checkAndPrepare(_ wav: URL, label: String, into row: inout [String: Any]) async throws {
            let seconds = try SingVoiceAudioDecoder.durationSeconds(of: wav)
            let audio = try SingVoiceAudioDecoder.decode(wav, startSeconds: 0, durationSeconds: seconds)
            let frames = try await detect(wav, seconds)
            row["durationSeconds"] = seconds
            row["check"] = MaleToFemaleVoiceCheckTests.json(VoiceClipCheck.run(recording: audio, pitchFrames: frames))
            do {
                let record = try await SingVoicePreparation.prepare(
                    source: wav, name: "W9-MF VocalSet \(label)", kind: .file, sourceName: wav.lastPathComponent,
                    library: library, detectPitch: detect)
                row["prepare"] = "passed"
                row["voiceId"] = record.id
                row["range"] = MaleToFemaleVoiceCheckTests.json(record.range)
                row["labelsVerdict"] = record.labels.verdict.rawValue
                row["labels"] = MaleToFemaleVoiceCheckTests.json(record.labels)
            } catch let refusal as SingVoiceAddRefusal {
                row["prepare"] = "refused"
                row["code"] = refusal.code
                row["sentence"] = refusal.sentence
            }
        }
        var rows: [[String: Any]] = []
        let reportURL = out.appendingPathComponent("vs-report.json")
        func log(_ row: [String: Any]) {
            print("mf-vs| \(row["label"] ?? "?"): \(row["prepare"] ?? "-") \(row["code"] ?? "") "
                  + "\(row["labelsVerdict"] ?? "") \(row["error"] ?? "")")
        }
        for file in rowsIn {
            let name = file.deletingPathExtension().lastPathComponent   // e.g. m4_row_straight
            let tag = name.contains("vibrato") ? "V" : "R"
            var base: [String: Any] = ["source": file.path]
            do {
                let seconds = try SingVoiceAudioDecoder.durationSeconds(of: file)
                let audio = try SingVoiceAudioDecoder.decode(file, startSeconds: 0, durationSeconds: seconds)
                let rate = audio.sampleRate
                let mono = audio.channelData[0]
                // 1. words (the product's Whisper), P1's nine in order
                let tr = try await whisper.transcribe(WhisperTranscriptionRequest(
                    audioURL: file, tempoMap: tempo, language: "en"))
                base["transcript"] = tr.text
                base["words"] = tr.words.map { ["text": $0.text, "start": $0.startSeconds, "end": $0.endSeconds] }
                var cursor = 0
                var hits: [Int] = []
                for target in Self.p1Words {
                    var found: Int?
                    var j = cursor
                    while j < tr.words.count, j < cursor + 3 {
                        let w = Self.normalized(tr.words[j].text)
                        if w == target || (!w.isEmpty && Self.editDistance(w, target) <= (target.count >= 4 ? 2 : 1)) {
                            found = j
                            break
                        }
                        j += 1
                    }
                    guard let hit = found else { break }
                    hits.append(hit)
                    cursor = hit + 1
                }
                let onset: Double
                let beat: Double
                var hi: Double
                if hits.count == Self.p1Words.count {
                    let row0 = tr.words[hits[0]], stream = tr.words[hits[8]]
                    onset = row0.startSeconds
                    beat = (stream.startSeconds - row0.startSeconds) / 6
                    hi = stream.startSeconds + 2 * beat + 0.3
                    if hits[8] + 1 < tr.words.count { hi = min(hi, tr.words[hits[8] + 1].startSeconds - 0.05) }
                    base["timing"] = "whisper"
                    base["whisperStreamEnd"] = stream.endSeconds
                } else {
                    // Pre-registered fallback: first voiced run ≥ 0.15 s of the product's detector; the written 8 s.
                    let frames = try await detect(file, seconds)
                    var first: Double?
                    var runStart: Double?
                    for f in frames {
                        let voiced = f.frequencyHz != nil
                            && f.confidence >= PitchDetectionDefaults.defaultConfidenceThreshold
                        if voiced {
                            if runStart == nil { runStart = f.timeSeconds }
                            if let r = runStart, f.timeSeconds - r >= 0.15 { first = r; break }
                        } else { runStart = nil }
                    }
                    guard let t0 = first else { throw MFVocalSetError.noOnset(name) }
                    onset = t0
                    beat = 1.0
                    hi = t0 + 8.0 + 0.3
                    base["timing"] = "fallback"
                    base["wordsFound"] = hits.count
                }
                base["onsetSeconds"] = onset
                base["beatSeconds"] = beat
                base["cutEndSeconds"] = hi
                // 2. R0/V0: the cut, nothing else
                let lo = onset - 0.6
                let c0 = cut(mono, rate: rate, lo: max(0, lo), hi: hi, prePad: max(0, -lo), postPad: 0.8)
                let wav0 = out.appendingPathComponent("\(name)-\(tag)0.wav")
                try? FileManager.default.removeItem(at: wav0)
                try M23QComparisonPair.writeWAV([c0.samples], sampleRate: rate, to: wav0)
                var row0 = base
                row0["label"] = "\(name)-\(tag)0"
                row0["wav"] = wav0.path
                row0["gainDb"] = c0.gainDb
                row0["appEdits"] = 0
                try await checkAndPrepare(wav0, label: "\(name)-\(tag)0", into: &row0)
                log(row0)
                rows.append(row0)
                try MFSong.writeJSON(["rows": rows], to: reportURL)
                // 3. R1/V1: the same cut through the app's clip stretch handle, rendered by the app
                let ratio = min(2, max(0.5, 0.6 / beat))
                let root = out.appendingPathComponent("work-\(name)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let (tracks, tempoMap, clipSeconds, landedRatio) = try await MainActor.run {
                    () throws -> ([Track], TempoMap, Double, Double) in
                    let store = ProjectStore()
                    store.media = AudioFileImporter()
                    try store.setTempo(MFSong.tempo)
                    let track = store.addTrack(kind: .audio)
                    let clip = try store.importAudio(url: wav0, toTrack: track.id, atBeat: 1)
                    _ = try store.stretchClip(trackId: track.id, clipId: clip.id,
                                              toLengthBeats: clip.lengthBeats * ratio)
                    let landed = store.tracks.lazy.flatMap(\.clips).first { $0.id == clip.id }
                    return (store.tracks.filter { $0.kind == .audio }, store.transport.tempoMap,
                            (landed?.lengthBeats ?? 0) * 0.6, landed?.stretchRatio ?? 0)
                }
                let render = try await MFSong.render(tracks, tempo: tempoMap, seconds: 0.6 + clipSeconds + 1.0,
                                                     work: root, label: name)
                let wav1 = out.appendingPathComponent("\(name)-\(tag)1.wav")
                try? FileManager.default.removeItem(at: wav1)
                try M23QComparisonPair.writeWAV([render.left, render.right], sampleRate: MFSong.rate, to: wav1)
                var row1 = base
                row1["label"] = "\(name)-\(tag)1"
                row1["wav"] = wav1.path
                row1["appEdits"] = 1
                row1["stretchRatio"] = ratio
                row1["landedStretchRatio"] = landedRatio
                row1["stretched"] = render.stretched
                row1["shortfalls"] = render.shortfalls
                try await checkAndPrepare(wav1, label: "\(name)-\(tag)1", into: &row1)
                log(row1)
                rows.append(row1)
            } catch {
                base["label"] = name
                base["error"] = "\(error)"
                log(base)
                rows.append(base)
            }
            try MFSong.writeJSON(["rows": rows], to: reportURL)
        }
        for file in rawsIn {
            let name = file.deletingPathExtension().lastPathComponent
            var row: [String: Any] = ["source": file.path, "label": "\(name)-0", "appEdits": 0]
            do {
                let seconds = try SingVoiceAudioDecoder.durationSeconds(of: file)
                let audio = try SingVoiceAudioDecoder.decode(file, startSeconds: 0, durationSeconds: seconds)
                let c = cut(audio.channelData[0], rate: audio.sampleRate, lo: 0, hi: min(seconds, 10.5),
                            prePad: 0, postPad: 0.8)
                let wav = out.appendingPathComponent("\(name)-0.wav")
                try? FileManager.default.removeItem(at: wav)
                try M23QComparisonPair.writeWAV([c.samples], sampleRate: audio.sampleRate, to: wav)
                row["wav"] = wav.path
                row["gainDb"] = c.gainDb
                try await checkAndPrepare(wav, label: "\(name)-0", into: &row)
            } catch {
                row["error"] = "\(error)"
            }
            log(row)
            rows.append(row)
            try MFSong.writeJSON(["rows": rows], to: reportURL)
        }
        let errors = rows.filter { $0["error"] != nil }.count
        #expect(errors < rows.count, "every file errored")
    }

    static let slidesEnabled = env["MF_SLIDES"] == "1"

    /// Orchestrator note (W9-VDIAG vf-18/vf-19, 2026-10-12): a select-all move of M bends every FOLLOWED slide
    /// (`glideFollow > 0`) by up to 2M, and moves the unpitched sounds too. For each source take
    /// (`MF_SLIDES_SOURCES` = `label=<dir>/<source>,…`, reading `<source>-tracks.json`), the render's OWN curve
    /// (`StretchRenderCache.resolveRenderContour` + `StretchCurvePlan.make`, as the render builds them; read with
    /// `plan.curve.semitones(atSourceSecond:)` every 5 ms) for the no-edit table and for opt-3 (+1200 c, Keep voice
    /// size ON, Voice +3.5 on the non-unpitched notes), the move written in each mode of `MF_SLIDES_MODES`
    /// (`literal` = phase 2's writers, the default; `legacy`; `fixed` = `moveClipNotePitches`, W9-MF3).
    /// Per segment and mode: dk = k(opt-3) − k(no edit), EXACT doubles on the 5 ms grid (a 1e-9 gate needs them
    /// unrounded), whether the segment enters the curve, and the curve joins' kinds, so the gate is computed outside.
    /// A clean move is dk = +12 on every moved note and 0 on every unmoved sound.
    @Test("W9-MF phase 2b: followed slides and sounds under the opt-3 move, read from the render's own curve",
          .enabled(if: MaleToFemaleSingTests.slidesEnabled))
    func slides() async throws {
        guard let outPath = Self.env["MF_SLIDES_OUT"], outPath.hasPrefix("/private/tmp/claude-501/") else {
            Issue.record("MF_SLIDES_OUT (scratch) must be set")
            return
        }
        guard let modes = Self.moveModes("MF_SLIDES_MODES", fallback: [.literal]) else {
            Issue.record("MF_SLIDES_MODES must name only \(MoveMode.allCases.map(\.rawValue))")
            return
        }
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let sources = (Self.env["MF_SLIDES_SOURCES"] ?? "").split(separator: ",").compactMap { item -> (String, String)? in
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        var report: [String: Any] = ["step": 0.005, "move": 12.0, "voice": 3.5, "modes": modes.map(\.rawValue)]
        var failed: [String] = []
        for (label, base) in sources {
            var entry: [String: Any] = ["source": base]
            do {
                let tracksData = try Data(contentsOf: URL(fileURLWithPath: base + "-tracks.json"))
                let tracks = try JSONDecoder().decode([Track].self, from: tracksData)
                guard let t = tracks.firstIndex(where: { $0.clips.first?.pitchEdits != nil }),
                      let clip = tracks[t].clips.first, let table = clip.pitchEdits else {
                    throw MFVocalSetError.noOnset("\(label): no pitch-edit table")
                }
                let clipID = clip.id
                var take = clip.audioFileURL ?? URL(fileURLWithPath: base + "-take.wav")
                if !FileManager.default.fileExists(atPath: take.path) { take = URL(fileURLWithPath: base + "-take.wav") }
                entry["take"] = take.path
                let takeURL = take
                entry["ratio"] = clip.stretchRatio
                entry["clipStartBeat"] = clip.startBeat
                let contourDir = out.appendingPathComponent("contour-\(label)", isDirectory: true)
                try FileManager.default.createDirectory(at: contourDir, withIntermediateDirectories: true)
                func plan(_ c: Clip) throws -> StretchCurvePlan? {
                    let params = StretchRenderCache.Params(clip: c)
                    let contour = try StretchRenderCache.resolveRenderContour(
                        params: params, source: takeURL, renderCacheDirectory: contourDir, detector: .product,
                        isCancelled: { false })
                    return StretchCurvePlan.make(editSet: params.pitchEdits, clipPitchShiftSemitones: params.semitones,
                                                 sampleRate: 48_000, ratio: params.ratio,
                                                 contour: contour.curveContour)
                }
                let p0 = try plan(clip)
                entry["identityHasPlan"] = p0 != nil
                for mode in modes {
                    let (edited, echo) = try await MainActor.run { () throws -> (Clip?, MoveEcho) in
                        let store = ProjectStore()
                        try store.setTempo(MFSong.tempo)
                        store.tracks = tracks
                        let echo = try Self.writeOption(mode, store: store, clipID: clipID, table: table,
                                                        cents: 1_200, keep: 1, voice: 3.5)
                        return (store.tracks.lazy.flatMap(\.clips).first { $0.id == clipID }, echo)
                    }
                    guard let editedClip = edited, let set = editedClip.pitchEdits,
                          let p3 = try plan(editedClip) else {
                        throw MFVocalSetError.noOnset("\(label) \(mode.rawValue): the edited clip has no plan")
                    }
                    var m: [String: Any] = ["echo": echo.json,
                                            "sameSegmentLayout": set.segments.map(\.id) == table.segments.map(\.id)]
                    var segs: [[String: Any]] = []
                    for (i, seg) in set.segments.enumerated() {
                        var ts: [Double] = []
                        var dks: [Double] = []
                        var t0 = seg.startSeconds
                        while t0 <= seg.endSeconds {
                            let k0 = p0?.curve.semitones(atSourceSecond: t0) ?? clip.pitchShiftSemitones
                            ts.append(t0)
                            dks.append(p3.curve.semitones(atSourceSecond: t0) - k0)
                            t0 += 0.005
                        }
                        segs.append(["index": i, "id": seg.id.uuidString, "origin": seg.origin.rawValue,
                                     "glideFollow": seg.glideFollow, "start": seg.startSeconds, "end": seg.endSeconds,
                                     "ownOffsetCents": seg.pitchOffsetCents,
                                     "formantOffsetSemitones": seg.formantOffsetSemitones,
                                     "entersCurve": seg.entersPitchCurve, "t": ts, "dk": dks])
                    }
                    m["segments"] = segs
                    // The joins between neighbouring CURVE notes of the edited set, as the render classifies them.
                    let curve = set.segments.indices.filter { set.segments[$0].entersPitchCurve }
                    var joins: [[String: Any]] = []
                    for (l, r) in zip(curve, curve.dropFirst()) {
                        let kind = PitchEditSet.joinKind(leftEndSeconds: set.segments[l].endSeconds,
                                                         rightStartSeconds: set.segments[r].startSeconds)
                        joins.append(["left": l, "right": r, "kind": kind.rawValue])
                    }
                    m["curveJoins"] = joins
                    let followed = set.segments.indices.filter { set.segments[$0].glideFollow > 0 }
                    let peak = followed.compactMap { (segs[$0]["dk"] as? [Double])?.max() }.max()
                    let peakText = peak.map { String($0) } ?? "-"
                    print("mf3-curve| \(label) \(mode.rawValue): rule \(echo.rule), carried \(echo.carried.count), "
                          + "followed \(followed.count), peak slide dk \(peakText)")
                    entry[mode.rawValue] = m
                }
            } catch {
                entry["error"] = "\(error)"
                failed.append("\(label): \(error)")
            }
            report[label] = entry
            try MFSong.writeJSON(report, to: out.appendingPathComponent("slides.json"))
        }
        #expect(failed.isEmpty, "sources that failed: \(failed)")
    }

    @Test("W9-MF phase 1: own voice(s) and builtin-1 an octave down, builtin-1 as written; rendered",
          .enabled(if: MaleToFemaleSingTests.singEnabled))
    func sing() async throws {
        let rig = try await X9RRig.make()
        guard let rootPath = Self.env["MF_VOICES"], rootPath.hasPrefix("/private/tmp/claude-501/"),
              !rootPath.contains("Application Support") else {
            Issue.record("MF_VOICES must be the lane's scratch test library")
            return
        }
        let library = SingVoiceLibrary(root: URL(fileURLWithPath: rootPath, isDirectory: true))
        let seed = UInt64(Self.env["MF_SEED"] ?? "") ?? 2_611
        let whisper = WhisperTranscriber()
        let transcribe: @Sendable (URL) async throws -> String? = { url in try await SingSpeech.transcribe(whisper, url) }
        var report: [String: Any] = ["health": rig.health, "seed": Int(seed),
                                     "startedAt": ISO8601DateFormatter().string(from: Date())]
        let reportURL = rig.out.appendingPathComponent("sing-report.json")

        // The plan, before anything is sung: 32 notes, the film's words, no warnings, at both octaves.
        let planRoot = rig.work.appendingPathComponent("jobs/plan", isDirectory: true)
        try FileManager.default.createDirectory(at: planRoot, withIntermediateDirectories: true)
        let planFacts = try await MainActor.run { () throws -> [MFPlanFact] in
            let (store, clipID) = try MFSong.store(root: planRoot)
            return try [-1, 0].map { shift in
                let plan = try store.planSungVocal(clipId: clipID, octaveShift: shift).plan
                return MFPlanFact(shift: shift, notes: plan.notes.count, units: plan.units.count,
                                  warnings: plan.warnings.map { "\($0)" }, t0Seconds: plan.t0Seconds,
                                  atBeat: plan.atBeat)
            }
        }
        report["plan"] = planFacts.map {
            ["octaveShift": $0.shift, "notes": $0.notes, "units": $0.units, "warnings": $0.warnings,
             "t0Seconds": $0.t0Seconds, "atBeat": $0.atBeat] as [String: Any]
        }
        try MFSong.writeJSON(report, to: reportURL)
        for fact in planFacts where fact.notes != 32 {
            Issue.record("the plan at octave \(fact.shift) has \(fact.notes) notes, not 32: refusing to sing")
            return
        }

        var jobs: [(label: String, voice: SingJobVoice, shift: Int)] = []
        let ids = (Self.env["MF_VOICE_IDS"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        for (n, id) in ids.enumerated() {
            let record = try library.record(id: id)
            jobs.append(("male-\(n + 1)", .own(library.ownVoice(record)), -1))
        }
        jobs.append(("builtin-down", .builtIn, -1))
        jobs.append(("female-ref", .builtIn, 0))

        let cache = rig.cache("mf-shared")
        var rows: [[String: Any]] = []
        for job in jobs {
            var row: [String: Any] = ["label": job.label, "voiceId": job.voice.id, "voiceName": job.voice.name,
                                      "octaveShift": job.shift]
            do {
                let landed = try await rig.mfJob(job.label, voice: job.voice, octaveShift: job.shift, seed: seed,
                                                 cache: cache, transcribe: transcribe)
                row["facts"] = landed.facts
                let result = landed.status.result
                row["noteAccuracy"] = MaleToFemaleVoiceCheckTests.json(result?.noteAccuracy)
                row["wordCheck"] = MaleToFemaleVoiceCheckTests.json(result?.wordCheck)
                row["warnings"] = landed.status.warnings
                let render = try await MFSong.render(landed.tracks, tempo: landed.tempo, seconds: MFSong.renderSeconds,
                                                     work: rig.work, label: job.label)
                let wav = rig.out.appendingPathComponent("\(job.label).wav")
                try? FileManager.default.removeItem(at: wav)
                try M23QComparisonPair.writeWAV([render.left, render.right], sampleRate: MFSong.rate, to: wav)
                row["render"] = wav.path
                row["renderSha"] = render.sha
                row["stretched"] = render.stretched
                row["shortfalls"] = render.shortfalls
                if let take = landed.leadTake {
                    let copy = rig.out.appendingPathComponent("\(job.label)-take.wav")
                    try? FileManager.default.removeItem(at: copy)
                    try FileManager.default.copyItem(at: take, to: copy)
                    row["take"] = copy.path
                    row["takeSha"] = X9RMath.fileSha(copy)
                    row["takeOriginal"] = take.path
                }
                let tracksURL = rig.out.appendingPathComponent("\(job.label)-tracks.json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(landed.tracks).write(to: tracksURL)
                row["tracks"] = tracksURL.path
                row["leadTrackID"] = landed.lead.id.uuidString
                row["leadClipID"] = landed.lead.clips.first?.id.uuidString ?? NSNull()
                row["pitchEditSegments"] = landed.lead.clips.first?.pitchEdits?.segments.count ?? 0
                row["formantCorrection"] = X9RMath.json(landed.lead.clips.first?.pitchEdits?.formantCorrection)
            } catch {
                row["error"] = "\(error)"
                rig.note("MF job \(job.label) FAILED: \(error)")
            }
            rows.append(row)
            report["jobs"] = rows
            try MFSong.writeJSON(report, to: reportURL)
        }
        report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        try MFSong.writeJSON(report, to: reportURL)
        let failed = rows.filter { $0["error"] != nil }.map { "\($0["label"] ?? "")" }
        #expect(failed.isEmpty, "jobs that failed: \(failed)")
    }

    struct Option: Sendable {
        let label: String
        let cents: Double
        let keep: Double
        let voice: Double
    }

    // MARK: W9-MF3 (vf-18 leg 1 is in the tree): the opt-3 octave move, written three ways

    /// How the octave move is written. `MF_FIXED=1` = `fixed`; else `MF_MOVE` (one name); unset = `literal`.
    enum MoveMode: String, Sendable, CaseIterable {
        /// Phase 2 as rendered for the picked file: EVERY segment (sounds included) its own offset + the move, through
        /// the literal writer `setClipNotePitchOffsets`. ⚠️ In today's tree that writer's home
        /// (`PitchEditSet.afterHandEdit(from:)`) ADOPTS the hold rule on a fresh table.
        case literal
        /// `literal`, then the set's slide rule put back to the legacy `.sungAtOpenSide` after the LAST write: the state
        /// phase 2 rendered before vf-18 leg 1 existed.
        case legacy
        /// The fix (SLRV REVIEW §3.8): `moveClipNotePitches(segmentIds: nil, byCents:)` = every SUNG note moved
        /// together, followed slides carried, sounds untouched; a fresh table adopts the hold rule.
        case fixed
    }

    /// The modes named in `key` (a comma list), `fallback` when unset; nil for an unknown name (never a silent default).
    static func moveModes(_ key: String, fallback: [MoveMode]) -> [MoveMode]? {
        guard let raw = env[key], !raw.isEmpty else { return fallback }
        var out: [MoveMode] = []
        for name in raw.split(separator: ",") {
            guard let mode = MoveMode(rawValue: String(name)) else { return nil }
            out.append(mode)
        }
        return out
    }

    struct MoveEcho: Sendable {
        let rule: String
        let carried: [UUID]
        /// Distinct STORED values per origin (detected / transition / unpitched), so "slides carried" and "sounds
        /// moved by mistake" cannot read the same.
        let offsetsByOrigin: [String: [Double]]
        let formantsByOrigin: [String: [Double]]
        let formantCorrection: Double?

        var json: [String: Any] {
            ["slideFollowRule": rule, "carriedSlides": carried.map(\.uuidString),
             "offsetsByOrigin": offsetsByOrigin, "formantOffsetsByOrigin": formantsByOrigin,
             "formantCorrection": X9RMath.json(formantCorrection)]
        }
    }

    /// One option's writes on `clipID` (`table` = the source take's stored table), in phase 2's order: the move
    /// (`cents`, written in `mode`), Keep voice size `keep`, then Voice `voice` on the SUNG notes. Echoes the stored set.
    @MainActor
    static func writeOption(_ mode: MoveMode, store: ProjectStore, clipID: UUID, table: PitchEditSet,
                            cents: Double, keep: Double, voice: Double) throws -> MoveEcho {
        var carried: [UUID] = []
        if cents != 0 {
            switch mode {
            case .literal, .legacy:
                // Select-all + drag as phase 2 wrote it: every note, its own offset + the move.
                let offsets = table.segments.map {
                    NotePitchOffset(segmentId: $0.id, offsetCents: $0.pitchOffsetCents + cents)
                }
                try store.setClipNotePitchOffsets(clipId: clipID, offsets: offsets,
                                                  undoKey: PitchCorrectionUndoKey.structuralKey)
            case .fixed:
                carried = try store.moveClipNotePitches(clipId: clipID, segmentIds: nil, byCents: cents,
                                                        undoKey: PitchCorrectionUndoKey.structuralKey).carriedSlideIDs
            }
        }
        try store.setClipFormantCorrection(clipId: clipID, amount: keep)
        if voice != 0 {
            // The Voice tool refuses a sound with no sung pitch (`.unpitched`): name the sung notes.
            let sung = table.segments.filter { $0.origin != .unpitched }.map(\.id)
            try store.setClipNoteFormant(clipId: clipID, segmentIds: sung, semitones: voice)
        }
        if mode == .legacy {
            for t in store.tracks.indices {
                for c in store.tracks[t].clips.indices where store.tracks[t].clips[c].id == clipID {
                    store.tracks[t].clips[c].pitchEdits?.slideFollowRule = .sungAtOpenSide
                }
            }
        }
        let after = store.tracks.lazy.flatMap(\.clips).first { $0.id == clipID }?.pitchEdits
        let segs = after?.segments ?? []
        let groups = Dictionary(grouping: segs, by: { $0.origin.rawValue })
        return MoveEcho(rule: after?.slideFollowRule.rawValue ?? "no table", carried: carried,
                        offsetsByOrigin: groups.mapValues { Array(Set($0.map(\.pitchOffsetCents))).sorted() },
                        formantsByOrigin: groups.mapValues { Array(Set($0.map(\.formantOffsetSemitones))).sorted() },
                        formantCorrection: after?.formantCorrection)
    }

    @Test("W9-MF phase 2: the male take, moved up and made lighter with the pitch editor's own writers; rendered",
          .enabled(if: MaleToFemaleSingTests.phase2Enabled))
    func phase2() async throws {
        guard let outPath = Self.env["MF_OUT"], let source = Self.env["MF_P2_SOURCE"] else {
            Issue.record("MF_OUT and MF_P2_SOURCE must be set")
            return
        }
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        let work = out.appendingPathComponent("p2-work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let tracksData = try Data(contentsOf: out.appendingPathComponent("\(source)-tracks.json"))
        let tracks = try JSONDecoder().decode([Track].self, from: tracksData)
        guard let leadIndex = tracks.firstIndex(where: { $0.clips.first?.pitchEdits != nil }),
              let clip = tracks[leadIndex].clips.first, let table = clip.pitchEdits else {
            Issue.record("the source take carries no pitch-edit table")
            return
        }
        let clipID = clip.id
        // W9-MF3: how the move is written (`MF_FIXED=1` / `MF_MOVE`), and which options to render (`MF_P2_LABELS`).
        let fallback: MoveMode = Self.env["MF_FIXED"] == "1" ? .fixed : .literal
        guard let modes = Self.moveModes("MF_MOVE", fallback: [fallback]), modes.count == 1,
              Self.env["MF_FIXED"] != "1" || Self.env["MF_MOVE"] == nil else {
            Issue.record("MF_MOVE must name ONE of \(MoveMode.allCases.map(\.rawValue)), and not together with MF_FIXED")
            return
        }
        let mode = modes[0]
        let only = Set((Self.env["MF_P2_LABELS"] ?? "").split(separator: ",").map(String.init))
        let voices = (Self.env["MF_P2_VOICES"] ?? "2,3.5,5").split(separator: ",").compactMap { Double($0) }
        var options: [Option] = [Option(label: "p2-identity", cents: 0, keep: table.formantCorrection ?? 1, voice: 0),
                                 Option(label: "opt-1", cents: 1_200, keep: 1, voice: 0)]
        for (i, v) in voices.enumerated() { options.append(Option(label: "opt-\(i + 2)", cents: 1_200, keep: 1, voice: v)) }
        options.append(Option(label: "ctl-keep-off", cents: 1_200, keep: 0, voice: 0))
        for v in voices { options.append(Option(label: "cal-same-pitch-voice-\(v)", cents: 0, keep: 1, voice: v)) }

        var report: [String: Any] = ["source": source, "segments": table.segments.count,
                                     "origins": Dictionary(grouping: table.segments, by: { $0.origin.rawValue })
                                         .mapValues(\.count),
                                     "sourceFormantCorrection": X9RMath.json(table.formantCorrection),
                                     "voices": voices, "moveMode": mode.rawValue, "labels": only.sorted()]
        let reportURL = out.appendingPathComponent("p2-report.json")
        var rows: [[String: Any]] = []
        for option in options where only.isEmpty || only.contains(option.label) {
            var row: [String: Any] = ["label": option.label, "cents": option.cents, "keep": option.keep,
                                      "voice": option.voice, "moveMode": mode.rawValue]
            do {
                let (edited, tempo, echo, moveEcho) = try await MainActor.run {
                    () throws -> ([Track], TempoMap, MFEcho, MoveEcho) in
                    let store = ProjectStore()
                    try store.setTempo(MFSong.tempo)
                    store.tracks = tracks
                    let ids = table.segments.map(\.id)
                    // The move (in `mode`), Keep voice size, Voice on the sung notes: phase 2's writes, in its order.
                    let moveEcho = try Self.writeOption(mode, store: store, clipID: clipID, table: table,
                                                        cents: option.cents, keep: option.keep, voice: option.voice)
                    let after = store.tracks.lazy.flatMap(\.clips).first { $0.id == clipID }?.pitchEdits
                    let moved = Set((after?.segments ?? []).map { Int(($0.pitchOffsetCents).rounded()) })
                    let formants = Set((after?.segments ?? []).map { $0.formantOffsetSemitones })
                    return (store.tracks.filter { $0.kind == .audio }, store.transport.tempoMap,
                            MFEcho(segments: ids.count, offsetsAfter: moved.sorted(), formantsAfter: formants.sorted(),
                                   formantCorrectionAfter: after?.formantCorrection), moveEcho)
                }
                row["echo"] = ["segments": echo.segments, "offsetsAfter": echo.offsetsAfter,
                               "formantOffsetsAfter": echo.formantsAfter,
                               "formantCorrectionAfter": X9RMath.json(echo.formantCorrectionAfter)] as [String: Any]
                row["moveEcho"] = moveEcho.json
                let editedURL = out.appendingPathComponent("\(option.label)-edited-tracks.json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(edited).write(to: editedURL)
                row["editedTracks"] = editedURL.path
                let render = try await MFSong.render(edited, tempo: tempo, seconds: MFSong.renderSeconds, work: work,
                                                     label: option.label)
                let wav = out.appendingPathComponent("\(option.label).wav")
                try? FileManager.default.removeItem(at: wav)
                try M23QComparisonPair.writeWAV([render.left, render.right], sampleRate: MFSong.rate, to: wav)
                row["render"] = wav.path
                row["renderSha"] = render.sha
                row["stretched"] = render.stretched
                row["shortfalls"] = render.shortfalls
            } catch {
                row["error"] = "\(error)"
            }
            rows.append(row)
            report["options"] = rows
            try MFSong.writeJSON(report, to: reportURL)
        }
        let failed = rows.filter { $0["error"] != nil }.map { "\($0["label"] ?? ""): \($0["error"] ?? "")" }
        #expect(failed.isEmpty, "options that failed: \(failed)")
    }
}

enum MFVocalSetError: Error { case noOnset(String) }
