import Accelerate
import CryptoKit
import Foundation
import Testing

@testable import AIServices
@testable import DAWCore
@testable import DAWEngine

// W8-X9R (p2-sing-x9, the rounds half; design `docs/design/2026-10-06-p2-sing-expansion.md` §10.1): listening rounds
// V, A, H1, H2, H3 and D, SUNG BY THE REAL SINGING ENGINE and HEARD THROUGH THE ENGINE'S OFFLINE RENDER.
//
// ⛔ ENV-GATED: runs ONLY with `X9R_ROUNDS=1`, after a driver script has started ONE singing sidecar on a TEST port
// (never 8004) from a scratch runtime. Every normal run skips it. It writes nothing outside `X9R_OUT`/`X9R_WORK`/
// `X9R_CACHE_ROOT` (the cache root must be one of the sidecar's allowed roots).
//
// Every option is ONE sing job through `SingJobCoordinator` (a fresh store per option, one shared phrase cache, a real
// `SingingSynthesisClient`), landed, then rendered by the body of `AudioEngine.renderOffline`: a `StretchRenderCache`
// renders every pitch-edited clip, and an `OfflineRenderer` with `stretchedFileProvider` wired to it mixes the sung
// tracks. A vibrato option is HEARD only through that render (the style lands a `pitchEdits` table, not new audio).
//
// Pre-registered in the lane's PREDICTIONS.md before the first render. Deliberately NOT `@MainActor` (the tree is at its
// suite cap): the store, the render cache and the renderer hop to the main actor.

struct X9RError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - The engine seam: the sidecar the driver started

/// The singing sidecar a driver script launched (pid-exact, on a test port), seen through the job's engine seam.
/// `start()` never launches anything: it waits for `/health` to say ready, then takes the lifecycle's admission the way
/// `SingingSidecarManager` does on a real boot.
actor X9RExternalSidecar: SingJobEngine {
    let baseURL: URL
    let pid: Int32?
    let lifecycle: ModelLifecycleCoordinator
    private var state: SingingSidecarState = .installedNotRunning
    private var facadeVersion: Int?
    private var commit: String?
    private var weightsRevision: String?
    private var weightsBytes: UInt64?
    private(set) var startCount = 0

    init(baseURL: URL, pid: Int32?, lifecycle: ModelLifecycleCoordinator) {
        self.baseURL = baseURL
        self.pid = pid
        self.lifecycle = lifecycle
    }

    func status() -> SingingSidecarStatus {
        let healthy = state == .healthy
        return SingingSidecarStatus(
            state: state, message: healthy ? "ready (X9R external sidecar)" : "X9R: not admitted yet",
            pid: healthy ? pid : nil, facadeVersion: facadeVersion, commit: commit,
            weightsRevision: weightsRevision, weightsBytes: weightsBytes)
    }

    func start() async throws -> SingingSidecarStatus {
        startCount += 1
        if state == .healthy { return status() }
        _ = try await readHealth()
        let plan = await lifecycle.resolveAdmission(.soulxSinger)
        if let ticket = try await lifecycle.commitAdmission(plan, for: .soulxSinger) {
            await lifecycle.admitted(ticket, healthy: true)
        }
        state = .healthy
        return status()
    }

    func lastStopClassification() -> SingingStopReason? { nil }

    /// Polls `/health` until it says ready (180 s at most); returns its body.
    func readHealth() async throws -> String {
        let deadline = Date().addingTimeInterval(180)
        while true {
            var request = URLRequest(url: baseURL.appendingPathComponent("health"))
            request.timeoutInterval = 5
            if let reply = try? await URLSession.shared.data(for: request),
               (reply.1 as? HTTPURLResponse)?.statusCode == 200,
               let object = (try? JSONSerialization.jsonObject(with: reply.0)) as? [String: Any],
               object["status"] as? String == "ready" {
                facadeVersion = object["facadeVersion"] as? Int
                if let engine = object["engine"] as? [String: Any] {
                    commit = engine["commit"] as? String
                    weightsRevision = engine["weightsRevision"] as? String
                    weightsBytes = (engine["weightsBytes"] as? NSNumber)?.uint64Value
                }
                return String(decoding: reply.0, as: UTF8.self)
            }
            if Date() > deadline { throw X9RError("the sidecar at \(baseURL) never reported ready") }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}

// MARK: - The constant source: the SING-6 line T1T2

enum X9RSource {
    // `scripts/sing/tests/fixtures/spike/T1T2.json` (= `Tests/DAWCoreTests/Fixtures/Sing/T1T2.json`), verbatim.
    static let durations = "0.24 0.60 0.60 0.60 0.60 0.60 0.60 1.20 0.60 0.60 0.60 0.60 0.60 0.60 1.20 1.00 0.60 0.30 0.30 0.60 0.60 1.20 0.24"
    static let text = "<SP> Twinkle Twinkle twinkle twinkle little little star how I wonder wonder what you are <SP> hold me me me <SP> now <SP>"
    static let pitches = "0 60 60 67 67 69 69 67 65 65 64 64 62 62 60 0 64 65 67 69 0 67 0"
    static let types = "1 2 3 2 3 2 3 2 2 2 2 3 2 2 2 1 2 2 3 3 1 2 1"

    static let cMajor = SongKey(tonicPitchClass: 0, mode: .major)
    static let rate = 48_000.0
    static let renderSeconds = 15.5

    struct Note: Sendable {
        let midi: Int
        let start: Double
        let end: Double
        var hz: Double { 440 * pow(2, Double(midi - 69) / 12) }
    }

    static func fixedID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    /// `SingPlannerTests.t1t2Clip()`'s recipe: 120 BPM (seconds × 2 = beats), a word on each type 2, `+` on each 3,
    /// a line break at each rest. 19 notes, 3 lines.
    static func line() -> (notes: [MIDINote], lyrics: String, timeline: [Note]) {
        let d = durations.split(separator: " ").compactMap { Double($0) }
        let p = pitches.split(separator: " ").compactMap { Int($0) }
        let k = types.split(separator: " ").compactMap { Int($0) }
        let w = text.split(separator: " ").map(String.init)
        var notes: [MIDINote] = []
        var timeline: [Note] = []
        var lyrics = ""
        var newLine = false
        var seconds = 0.0
        for i in d.indices {
            let start = seconds
            seconds += d[i]
            guard p[i] > 0 else {
                if !lyrics.isEmpty { newLine = true }
                continue
            }
            notes.append(MIDINote(id: fixedID(1_000 + i), pitch: p[i], velocity: 100,
                                  startBeat: start * 2, lengthBeats: d[i] * 2))
            timeline.append(Note(midi: p[i], start: start, end: seconds))
            if k[i] == 3 {
                lyrics += " +"
                continue
            }
            if !lyrics.isEmpty { lyrics += newLine ? "\n" : " " }
            lyrics += w[i]
            newLine = false
        }
        return (notes, lyrics, timeline)
    }

    /// The three 1.2 s notes, the only ones where a wobble has room to be measured.
    static var longNotes: [(name: String, note: Note)] {
        let t = line().timeline
        return t.enumerated().filter { $0.element.end - $0.element.start > 1.0 }.map { i, n in
            ("\(n.midi == 60 ? "C4" : "G4")@\(String(format: "%.2f", n.start))", n)
        }
    }

    /// W9-PICKS: every take of these rounds was sung while an unnamed vibrato meant "as sung". Since the user's
    /// picks (p2-sing-x9-picks) it means `SingStyle.defaultVibrato` (Normal), so the rounds name "as sung" wherever
    /// they name no vibrato, and a re-run sings what the user heard.
    static func asHeard(_ style: SingStyle?) -> SingStyle {
        var out = style ?? SingStyle()
        if out.vibrato == nil { out.vibrato = .asSung }
        return out
    }

    @MainActor
    static func store(root: URL, style: SingStyle?) throws -> (ProjectStore, UUID) {
        let store = ProjectStore()
        store.media = AudioFileImporter()
        store.generationImportsDirectory = root.appendingPathComponent("generations", isDirectory: true)
        let track = store.addTrack(kind: .instrument)
        let (notes, lyrics, _) = line()
        let clip = try store.addMIDIClip(toTrack: track.id, name: "Twinkle", atBeat: 0,
                                         lengthBeats: notes.map { $0.endBeat }.max() ?? 4, notes: notes)
        for t in store.tracks.indices {
            if let c = store.tracks[t].clips.firstIndex(where: { $0.id == clip.id }) {
                store.tracks[t].clips[c].lyrics = ClipLyrics(text: lyrics)
                store.tracks[t].clips[c].singStyle = asHeard(style)
                return (store, clip.id)
            }
        }
        throw ProjectError.clipNotFound(clip.id)
    }
}

// MARK: - One landed job, one render

struct X9RLanded: Sendable {
    let label: String
    let status: SingJobStatus
    let tracks: [Track]
    let tempo: TempoMap
    let lead: Track
    let parts: [Track]

    var leadTake: URL? { lead.clips.first?.audioFileURL }
    func partTake(_ i: Int = 0) -> URL? { parts.indices.contains(i) ? parts[i].clips.first?.audioFileURL : nil }

    var facts: [String: Any] {
        var out: [String: Any] = [
            "jobID": status.jobID, "phase": status.phase.rawValue, "seed": Int(status.seed),
            "unitCount": status.unitCount, "cachedUnits": status.cachedUnits, "renderedUnits": status.renderedUnits,
            "retriedUnits": status.retriedUnits, "engineRestarts": status.engineRestarts,
            "warnings": status.warnings, "notices": status.notices,
            "leadHitRate": X9RMath.json(status.result?.noteAccuracy?.hitRate),
            "leadAppliedGainDb": X9RMath.json(lead.sungVocalProvenance?.loudness?.appliedGainDb),
        ]
        out["parts"] = (status.parts ?? []).map { p -> [String: Any] in
            let track = tracks.first { $0.id == p.trackID }
            return ["role": p.role, "name": p.name, "state": p.state.rawValue, "octaveShift": p.octaveShift,
                    "fits": p.fits, "seed": Int(p.seed), "trackName": p.trackName,
                    "pan": X9RMath.json(track?.pan), "volume": X9RMath.json(track?.volume),
                    "hitRate": X9RMath.json(track?.sungVocalProvenance?.noteAccuracy?.hitRate),
                    "error": p.error?.code ?? "-"]
        }
        return out
    }
}

struct X9RRender: Sendable {
    let channels: [[Float]]
    let stretched: Int
    let shortfalls: [String]

    var left: [Float] { channels.first ?? [] }
    var right: [Float] { channels.count > 1 ? channels[1] : left }
    var mono: [Float] { zip(left, right).map { ($0 + $1) / 2 } }
    var sha: String { X9RMath.sha(channels) }
}

struct X9RRig {
    let engine: X9RExternalSidecar
    let lifecycle: ModelLifecycleCoordinator
    let synth: SingingSynthesisClient
    let work: URL
    let out: URL
    let cacheRoot: URL
    let deadline: Date
    let statusFile: URL?
    let health: String

    static func make() async throws -> X9RRig {
        let env = ProcessInfo.processInfo.environment
        let port = Int(env["X9R_PORT"] ?? "") ?? 18_004
        guard port != 8_004, port != 17_600, port != 17_695 else { throw X9RError("refusing port \(port)") }
        guard let outPath = env["X9R_OUT"], let workPath = env["X9R_WORK"], let cachePath = env["X9R_CACHE_ROOT"] else {
            throw X9RError("X9R_OUT, X9R_WORK and X9R_CACHE_ROOT must be set")
        }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let work = URL(fileURLWithPath: workPath, isDirectory: true)
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let lifecycle = ModelLifecycleCoordinator(
            storageDirectory: work.appendingPathComponent("lifecycle", isDirectory: true), settleSeconds: 0)
        var soulx = ModelRegistry.soulxSinger(baseURL: base)
        soulx.idleUnloadSeconds = nil
        var ace = ModelRegistry.aceStep(baseURL: URL(string: "http://127.0.0.1:9")!)
        ace.idleUnloadSeconds = nil
        await lifecycle.register(soulx, evictor: nil)
        await lifecycle.register(ace, evictor: nil)
        let engine = X9RExternalSidecar(baseURL: base, pid: Int32(env["X9R_PID"] ?? ""), lifecycle: lifecycle)
        let health = try await engine.readHealth()
        let budget = Double(env["X9R_BUDGET_S"] ?? "") ?? 2_400
        return X9RRig(engine: engine, lifecycle: lifecycle,
                      synth: SingingSynthesisClient(baseURL: base, timeoutSeconds: 120),
                      work: work, out: out, cacheRoot: URL(fileURLWithPath: cachePath, isDirectory: true),
                      deadline: Date().addingTimeInterval(budget),
                      statusFile: env["X9R_STATUS"].map { URL(fileURLWithPath: $0) }, health: health)
    }

    func cache(_ name: String) -> SingPhraseCache {
        SingPhraseCache(directory: cacheRoot.appendingPathComponent(name, isDirectory: true))
    }

    func note(_ line: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withFullTime, .withSpaceBetweenDateAndTime])
        let text = "\(stamp) W8-X9R \(line)\n"
        print("x9r| \(line)")
        guard let statusFile, let handle = try? FileHandle(forWritingTo: statusFile) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    /// ONE sing job, run to `done`, on a fresh store whose melody clip carries `style`.
    func job(_ label: String, style: SingStyle? = nil, parts: [SingJobPart] = [],
             cache: SingPhraseCache) async throws -> X9RLanded {
        guard Date() < deadline else { throw X9RError("the wall-clock budget was spent before job \(label)") }
        let root = work.appendingPathComponent("jobs/\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (store, clipID) = try await MainActor.run { try X9RSource.store(root: root, style: style) }
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
            detectPitch: detect, transcribe: { _ in nil }, configuration: configuration)
        let started = Date()
        let id = try await coordinator.submit(
            SingJobRequest(clipID: clipID, parts: parts, key: X9RSource.cMajor)).jobID
        let jobDeadline = min(deadline, Date().addingTimeInterval(600))
        var status = try await coordinator.status(jobID: id)
        while !status.phase.isTerminal {
            if Date() > jobDeadline {
                throw X9RError("job \(label) did not end in time: \(status.phase.rawValue) \(status.stageText)")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            status = try await coordinator.status(jobID: id)
        }
        let checks = Date().addingTimeInterval(120)
        while await coordinator.isBusy(), Date() < checks { try await Task.sleep(nanoseconds: 100_000_000) }
        status = try await coordinator.status(jobID: id)
        guard status.phase == .done, let result = status.result else {
            throw X9RError("job \(label) ended \(status.phase.rawValue): \(status.error?.code ?? "-") "
                           + "\(status.error?.message ?? "") \(status.error?.detail ?? "") parts "
                           + "\((status.parts ?? []).map { "\($0.role) \($0.state.rawValue) \($0.error?.code ?? "-")" })")
        }
        let (tracks, tempo) = await MainActor.run { (store.tracks, store.transport.tempoMap) }
        let sung = tracks.filter { $0.kind == .audio }
        guard let lead = sung.first(where: { $0.id == result.trackID }) else {
            throw X9RError("job \(label): the lead track \(result.trackID) is not in the store")
        }
        let partIDs = (status.parts ?? []).filter { $0.role != SingJobPartStatusRoles.lead }.compactMap(\.trackID)
        let partTracks = partIDs.compactMap { pid in sung.first { $0.id == pid } }
        guard partTracks.count == parts.count else {
            throw X9RError("job \(label): \(partTracks.count) part tracks landed for \(parts.count) parts")
        }
        note("job \(label): done in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, units "
             + "\(status.unitCount) (cached \(status.cachedUnits), rendered \(status.renderedUnits)), "
             + "\(sung.count) sung track(s)")
        return X9RLanded(label: label, status: status, tracks: sung, tempo: tempo, lead: lead, parts: partTracks)
    }

    /// The body of `AudioEngine.renderOffline`: every pitch-edited clip through a `StretchRenderCache` (the product
    /// detector), then a fresh `OfflineRenderer` whose `stretchedFileProvider` is a pure cache lookup.
    @MainActor
    func render(_ tracks: [Track], tempo: TempoMap, label: String) async throws -> X9RRender {
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
        let audio = try renderer.render(tracks: tracks, tempoMap: tempo, fromBeat: 0,
                                        durationSeconds: X9RSource.renderSeconds)
        return X9RRender(channels: audio.channelData, stretched: stretched, shortfalls: shortfalls)
    }

    func renderJob(_ j: X9RLanded, _ tracks: [Track]? = nil, label: String) async throws -> X9RRender {
        try await render(tracks ?? j.tracks, tempo: j.tempo, label: label)
    }

    /// Writes the engine render (float32, 48 kHz, stereo) and copies every landed take beside it.
    func keep(_ render: X9RRender, _ j: X9RLanded, round: String, option: String) throws -> [String: Any] {
        let raw = out.appendingPathComponent("\(round)/raw", isDirectory: true)
        let stems = out.appendingPathComponent("\(round)/stems", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stems, withIntermediateDirectories: true)
        let rawURL = raw.appendingPathComponent("\(option).wav")
        try M23QComparisonPair.writeWAV([render.left, render.right], sampleRate: X9RSource.rate, to: rawURL)
        var copied: [String: String] = [:]
        func copy(_ url: URL?, _ role: String) throws {
            guard let url else { return }
            let target = stems.appendingPathComponent("\(option)-\(role).wav")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: url, to: target)
            copied[role] = target.path
        }
        try copy(j.leadTake, "lead")
        for i in j.parts.indices { try copy(j.partTake(i), j.parts.count == 1 ? "part" : "part\(i + 1)") }
        return ["raw": rawURL.path, "stems": copied, "renderSha": render.sha]
    }
}

/// The role string the coordinator gives the lead's status row (`SingJobPartStatus.role`).
enum SingJobPartStatusRoles { static let lead = "lead" }

// MARK: - Instruments and arithmetic

enum X9RMath {
    static func json(_ x: Double?) -> Any {
        guard let x, x.isFinite else { return NSNull() }
        return (x * 10_000).rounded() / 10_000
    }

    static func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    static func sha(_ channels: [[Float]]) -> String {
        var hasher = SHA256()
        for channel in channels { channel.withUnsafeBytes { hasher.update(bufferPointer: $0) } }
        return hex(hasher.finalize())
    }

    static func fileSha(_ url: URL?) -> String {
        guard let url, let data = try? Data(contentsOf: url) else { return "missing" }
        return hex(SHA256.hash(data: data))
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func lufs(_ channels: [[Float]]) -> Double? {
        Loudness.measure(RenderedAudio(sampleRate: X9RSource.rate, channelData: channels)).integratedLufs
    }

    static func rmsDb(_ x: [Float]) -> Double {
        guard !x.isEmpty else { return -.infinity }
        var ms: Float = 0
        vDSP_measqv(x, 1, &ms, vDSP_Length(x.count))
        return 10 * log10(Double(ms) + 1e-30)
    }

    static func correlation(_ a: [Float], _ b: [Float]) -> Double {
        var sab = 0.0, saa = 0.0, sbb = 0.0, ma = 0.0, mb = 0.0
        let n = Double(min(a.count, b.count))
        for i in 0..<min(a.count, b.count) { ma += Double(a[i]); mb += Double(b[i]) }
        ma /= n; mb /= n
        for i in 0..<min(a.count, b.count) {
            let x = Double(a[i]) - ma, y = Double(b[i]) - mb
            sab += x * y; saa += x * x; sbb += y * y
        }
        return sab / max(1e-30, (saa * sbb).squareRoot())
    }

    /// Band powers (linear sums) of `x`: below 1 kHz, below 2 kHz, at/above 2 kHz. Hann 4096, hop 2048.
    static func bands(_ x: [Float]) -> (below1k: Double, below2k: Double, above2k: Double) {
        let n = 4_096
        let log2n = vDSP_Length(12)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return (.nan, .nan, .nan) }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var b1 = 0.0, b2 = 0.0, a2 = 0.0
        var start = 0
        while start + n <= x.count {
            for i in 0..<n { frame[i] = x[start + i] * window[i] }
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            for k in 1..<(n / 2) {
                let power = Double(real[k] * real[k] + imag[k] * imag[k])
                let hz = Double(k) * X9RSource.rate / Double(n)
                if hz < 1_000 { b1 += power }
                if hz < 2_000 { b2 += power } else { a2 += power }
            }
            start += n / 2
        }
        return (b1, b2, a2)
    }

    static func db(_ x: Double, over y: Double) -> Double { 10 * log10(x / y) }

    // MARK: SwiftF0 (the product detector) and the tone tracker

    static func detect(_ samples: [Float], name: String, dir: URL) throws -> PitchDetectionResult {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try M23QComparisonPair.writeWAV([samples], sampleRate: X9RSource.rate, to: url)
        return try PitchContourCache.detectWholeFile(url, .product)
    }

    /// The median voiced Hz of frame centres inside `[a, b]`, and the voiced share there.
    static func noteHz(_ d: PitchDetectionResult, from a: Double, to b: Double) -> (hz: Double?, voiced: Double) {
        let half = 0.5 / d.frameRateHz
        var hz: [Double] = []
        var total = 0
        for frame in d.frames {
            let t = frame.timeSeconds + half
            guard t >= a, t <= b else { continue }
            total += 1
            if let f = frame.frequencyHz { hz.append(f) }
        }
        return (median(hz), total > 0 ? Double(hz.count) / Double(total) : 0)
    }

    /// The first and last voiced frame centre inside `window`, and the voiced share of the window's frames.
    static func voicedSpan(_ d: PitchDetectionResult, within window: ClosedRange<Double>)
    -> (span: ClosedRange<Double>?, coverage: Double) {
        let half = 0.5 / d.frameRateHz
        var first: Double?, last: Double?
        var voiced = 0, total = 0
        for frame in d.frames {
            let t = frame.timeSeconds + half
            guard window.contains(t) else { continue }
            total += 1
            if frame.frequencyHz != nil {
                voiced += 1
                if first == nil { first = t }
                last = t
            }
        }
        guard let first, let last, last > first else { return (nil, 0) }
        return (first...last, total > 0 ? Double(voiced) / Double(total) : 0)
    }

    /// Mean |Δ cents| between two detections of the same length over frames voiced in both.
    static func meanAbsCents(_ a: PitchDetectionResult, _ b: PitchDetectionResult) -> (cents: Double?, frames: Int) {
        var sum = 0.0
        var n = 0
        for (x, y) in zip(a.frames, b.frames) {
            guard let fx = x.frequencyHz, let fy = y.frequencyHz else { continue }
            sum += abs(1200 * log2(fx / fy))
            n += 1
        }
        return (n > 0 ? sum / Double(n) : nil, n)
    }

    typealias Series = WobbleOnsetListeningTests.Reader.Series

    /// The tracker's 5.5 Hz sine amplitude over `window` relative to `hz`, its scan peak and the median offset.
    static func wobble(_ samples: [Float], hz: Double, window: ClosedRange<Double>)
    -> (amplitude: Double?, scan: (hz: Double, depth: Double)?, centre: Double?, points: Int) {
        let series = WobbleOnsetListeningTests.Reader.tracked(samples, sampleRate: X9RSource.rate, hz: hz, within: window)
        return (SungExpressionRenderPhysicsTests.sineAmplitude(series, hz: 5.5),
                SungExpressionRenderPhysicsTests.scanRate(series), median(series.v), series.t.count)
    }

    struct Calibration {
        let hz: Double
        let readings: [(truth: Double, read: Double?)]
        let flat: Double?
        var ratios: [Double] { readings.compactMap { r in r.read.map { $0 / r.truth } } }
        var scale: Double? {
            let r = ratios
            guard r.count == readings.count, !r.isEmpty else { return nil }
            return 1 / (r.reduce(0, +) / Double(r.count))
        }
        var valid: Bool {
            ratios.count == readings.count && ratios.allSatisfy { (0.6...1.15).contains($0) } && (flat ?? 99) < 5
        }
        var summary: [String: Any] {
            ["hz": X9RMath.json(hz), "readings": readings.map { ["truth": $0.truth, "read": X9RMath.json($0.read)] },
             "flat": X9RMath.json(flat), "scale": X9RMath.json(scale), "valid": valid]
        }
    }

    /// The tracker on a synthetic 1.2 s harmonic note at `hz` (0.3 s pads), a 5.5 Hz wobble of 25/45/70 c, read over
    /// the SAME window shape the long notes use ([on + 0.40, off − 0.15]) with the same fit.
    static func calibrate(hz: Double) -> Calibration {
        let pad = [Float](repeating: 0, count: Int(0.3 * X9RSource.rate))
        let window = (0.3 + 0.40)...(0.3 + 1.2 - 0.15)
        func read(_ depth: Double) -> Double? {
            let note = ContourToRenderTests.tone(seconds: 1.2) { u in hz * pow(2, depth * sin(2 * .pi * 5.5 * u) / 1200) }
            return wobble(pad + note + pad, hz: hz, window: window).amplitude
        }
        return Calibration(hz: hz, readings: [25.0, 45, 70].map { ($0, read($0)) }, flat: read(0))
    }
}

// MARK: - The rounds

final class X9RReport {
    var rows: [[String: Any]] = []
    var rounds: [String: Any] = [:]
    var meta: [String: Any] = [:]
    let url: URL

    init(url: URL) { self.url = url }

    func write() {
        let object: [String: Any] = ["meta": meta, "rounds": rounds, "options": rows]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}

struct X9RGates {
    var list: [[String: Any]] = []
    var pass: Bool { list.allSatisfy { ($0["pass"] as? Bool) == true } }
    mutating func add(_ name: String, _ ok: Bool, _ detail: String) {
        list.append(["name": name, "pass": ok, "detail": detail])
    }
}

@Suite("W8-X9R listening rounds through the real singing engine (X9R_ROUNDS=1 only)")
struct SingListeningRoundsX9RTests {

    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["X9R_ROUNDS"] == "1"
    static func wants(_ round: String) -> Bool {
        guard let only = env["X9R_ONLY"], !only.isEmpty else { return true }
        return only.split(separator: ",").map(String.init).contains(round)
    }

    static let thirdAbove = HarmonySpec(interval: .third, direction: .above, chordSource: .none)
    static func f(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "nil" }

    @Test("X9R: rounds V, A, H1, H2, H3, D sung by the real engine, heard through the offline render",
          .enabled(if: SingListeningRoundsX9RTests.enabled))
    func rounds() async throws {
        let rig = try await X9RRig.make()
        let report = X9RReport(url: rig.out.appendingPathComponent("swift-rounds.json"))
        report.meta = ["health": rig.health, "startedAt": ISO8601DateFormatter().string(from: Date()),
                       "seed": Int(SingJobRequestBuilder.firstTakeSeed), "key": "C major, chordSource none",
                       "renderSeconds": X9RSource.renderSeconds, "rate": X9RSource.rate]
        let calDir = rig.work.appendingPathComponent("detect", isDirectory: true)

        // ---- D0: determinism, two REAL renders in two fresh caches. Nothing else means anything until it holds.
        let a = try await rig.job("D0-a", cache: rig.cache("det-a"))
        let shared = rig.cache("shared")
        let anchor = try await rig.job("D0-b", cache: shared)
        let anchorSha = X9RMath.fileSha(anchor.leadTake)
        var d0 = X9RGates()
        d0.add("anchor twice, same seed, byte-equal take (two real renders)",
               X9RMath.fileSha(a.leadTake) == anchorSha && anchorSha != "missing",
               "\(X9RMath.fileSha(a.leadTake).prefix(16)) vs \(anchorSha.prefix(16))")
        d0.add("both were REAL renders (no cache)",
               a.status.cachedUnits == 0 && anchor.status.cachedUnits == 0
                   && a.status.renderedUnits >= 1 && anchor.status.renderedUnits >= 1,
               "a cached \(a.status.cachedUnits) rendered \(a.status.renderedUnits); "
                   + "b cached \(anchor.status.cachedUnits) rendered \(anchor.status.renderedUnits)")
        report.rounds["D0"] = ["gates": d0.list, "pass": d0.pass, "a": a.facts, "b": anchor.facts, "takeSha": anchorSha]
        report.write()
        rig.note("D0 determinism: \(d0.pass ? "PASS" : "FAIL") \(d0.list.map { "\($0["detail"] ?? "")" })")
        #expect(d0.pass, "the determinism control failed: \(d0.list)")
        guard d0.pass else { return }

        let anchorRender = try await rig.renderJob(anchor, label: "anchor")
        let anchorLeadHz = try X9RMath.detect(anchorRender.mono, name: "anchor-mono.wav", dir: calDir)

        if Self.wants("V") {
            try await roundV(rig, report, anchor: anchor, anchorSha: anchorSha, cache: shared, dir: calDir)
        }
        if Self.wants("A") {
            try await roundA(rig, report, anchor: anchor, anchorSha: anchorSha, anchorRender: anchorRender, cache: shared)
        }
        var thirdAbovePartSha: String?
        var thirdAbovePartDetect: PitchDetectionResult?
        if Self.wants("H1") {
            (thirdAbovePartSha, thirdAbovePartDetect) = try await roundH1(
                rig, report, anchorSha: anchorSha, leadDetect: anchorLeadHz, cache: shared, dir: calDir)
        }
        if Self.wants("H2") {
            try await roundH2(rig, report, anchorSha: anchorSha, thirdAboveSha: thirdAbovePartSha, cache: shared)
        }
        if Self.wants("H3") {
            try await roundH3(rig, report, anchorSha: anchorSha, leadDetect: anchorLeadHz,
                              thirdAboveSha: thirdAbovePartSha, thirdAboveDetect: thirdAbovePartDetect,
                              cache: shared, dir: calDir)
        }
        if Self.wants("D") {
            try await roundD(rig, report, anchorSha: anchorSha, cache: shared)
        }
        report.meta["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        report.write()
        let failed = report.rows.filter { ($0["pass"] as? Bool) != true }.map { "\($0["round"] ?? "")/\($0["option"] ?? "")" }
        rig.note("rounds finished: \(report.rows.count) options, physics/invariance failures: \(failed)")
        #expect(failed.isEmpty, "options failing a physics or invariance gate: \(failed)")
    }

    // MARK: V: vibrato depth

    func roundV(_ rig: X9RRig, _ report: X9RReport, anchor: X9RLanded, anchorSha: String,
                cache: SingPhraseCache, dir: URL) async throws {
        let asSung = try await rig.job("V-as-sung", style: SingStyle(vibrato: .asSung), cache: cache)
        let asSungRender = try await rig.renderJob(asSung, label: "V-as-sung")
        var control = X9RGates()
        control.add("As sung lands NO table", asSung.lead.clips.first?.pitchEdits == nil,
                    "pitchEdits \(asSung.lead.clips.first?.pitchEdits == nil ? "nil" : "SET")")
        control.add("As sung take bytes == the anchor's", X9RMath.fileSha(asSung.leadTake) == anchorSha,
                    "\(X9RMath.fileSha(asSung.leadTake).prefix(16))")
        var calibrations: [Int: X9RMath.Calibration] = [:]
        for (_, note) in X9RSource.longNotes where calibrations[note.midi] == nil {
            calibrations[note.midi] = X9RMath.calibrate(hz: note.hz)
        }
        let asSungDetect = try X9RMath.detect(asSungRender.left, name: "V-as-sung-left.wav", dir: dir)
        func readings(_ render: X9RRender, detect: PitchDetectionResult) -> [[String: Any]] {
            X9RSource.longNotes.map { name, note in
                let window = (note.start + 0.40)...(note.end - 0.15)
                let voiced = X9RMath.voicedSpan(detect, within: window)
                let span = voiced.span.map { max($0.lowerBound, window.lowerBound)...min($0.upperBound, window.upperBound) }
                let cal = calibrations[note.midi]
                let w = span.map { X9RMath.wobble(render.left, hz: note.hz, window: $0) }
                let readable = voiced.coverage >= 0.5 && (w?.points ?? 0) >= 12 && (cal?.valid ?? false)
                let real = (w?.amplitude).flatMap { amp in cal?.scale.map { amp * $0 } }
                let swift = WobbleOnsetListeningTests.Reader.relative(detect, toHz: note.hz, within: window)
                return ["note": name, "hz": X9RMath.json(note.hz), "coverage": X9RMath.json(voiced.coverage),
                        "points": w?.points ?? 0, "readable": readable,
                        "trackerRaw": X9RMath.json(w?.amplitude), "trackerReal": X9RMath.json(real),
                        "scanHz": X9RMath.json(w?.scan?.hz), "scanDepthRaw": X9RMath.json(w?.scan?.depth),
                        "centreCents": X9RMath.json(w?.centre),
                        "swiftF0Raw55": X9RMath.json(SungExpressionRenderPhysicsTests.sineAmplitude(swift, hz: 5.5))]
            }
        }
        let asSungReadings = readings(asSungRender, detect: asSungDetect)
        report.rounds["V"] = ["control": ["gates": control.list, "pass": control.pass, "job": asSung.facts,
                                          "readings": asSungReadings, "renderSha": asSungRender.sha],
                              "calibration": calibrations.values.sorted { $0.hz < $1.hz }.map(\.summary)]
        report.write()
        rig.note("V control (As sung): \(control.pass ? "PASS" : "FAIL")")

        let options: [(slug: String, label: String, vibrato: SingStyle.Vibrato, depth: Double)] = [
            ("straight", "Straight", .straight, 0), ("gentle-25c", "25 c", .gentle, 25),
            ("normal-45c", "45 c", .normal, 45), ("wide-70c", "70 c", .wide, 70)]
        var means: [Double?] = []
        var rowIndex: [Int] = []
        for option in options {
            let j = try await rig.job("V-\(option.slug)", style: SingStyle(vibrato: option.vibrato), cache: cache)
            let render = try await rig.renderJob(j, label: "V-\(option.slug)")
            let kept = try rig.keep(render, j, round: "V", option: option.slug)
            let detect = try X9RMath.detect(render.left, name: "V-\(option.slug)-left.wav", dir: dir)
            let r = readings(render, detect: detect)
            var g = X9RGates()
            g.add("take bytes == the anchor's (vibrato never changes the take)",
                  X9RMath.fileSha(j.leadTake) == anchorSha, "\(X9RMath.fileSha(j.leadTake).prefix(16))")
            g.add("a pitch-edit table landed", j.lead.clips.first?.pitchEdits != nil, "")
            g.add("provenance.style.vibrato == \(option.vibrato.rawValue) (a failed style lands plain)",
                  j.lead.sungVocalProvenance?.style?.vibrato == option.vibrato,
                  "\(j.lead.sungVocalProvenance?.style?.vibrato?.rawValue ?? "nil")")
            g.add("the stretch cache rendered it with no contour shortfall",
                  render.stretched == 1 && render.shortfalls.isEmpty,
                  "stretched \(render.stretched), shortfalls \(render.shortfalls)")
            g.add("render bytes differ from As sung", render.sha != asSungRender.sha, "")
            let readable = r.filter { ($0["readable"] as? Bool) == true }
            let reals = readable.compactMap { $0["trackerReal"] as? Double }
            let mean = reals.isEmpty ? nil : reals.reduce(0, +) / Double(reals.count)
            means.append(mean)
            let shifts: [Double] = zip(r, asSungReadings).compactMap { x, y in
                guard let c = x["centreCents"] as? Double, let d = y["centreCents"] as? Double else { return nil }
                return c - d
            }
            report.rows.append([
                "round": "V", "option": option.slug, "label": option.label, "axis": option.depth,
                "files": kept, "job": j.facts, "pass": g.pass, "gates": g.list,
                "physics": ["instrument": "tone tracker (WobbleOnsetListeningTests.Reader.tracked), calibrated per pitch; "
                                + "SwiftF0 5.5 Hz reported raw", "meanRealDepthCents": X9RMath.json(mean),
                            "readableNotes": readable.count, "notes": r,
                            "centreShiftVsAsSungCents": shifts.map { X9RMath.json($0) }]])
            rowIndex.append(report.rows.count - 1)
            report.write()
            rig.note("V \(option.slug): gates \(g.pass ? "PASS" : "FAIL"), mean real depth \(Self.f(mean)) c over "
                     + "\(readable.count) readable long notes, shifts \(shifts.map { Self.f($0) })")
        }
        var round = X9RGates()
        let m = means.map { $0 ?? .nan }
        round.add("depth strictly increasing Straight < 25 < 45 < 70",
                  m.allSatisfy(\.isFinite) && zip(m, m.dropFirst()).allSatisfy { $0 < $1 }, "\(m.map { Self.f($0) })")
        round.add("Wide − Straight ≥ 30 c", (m.last ?? .nan) - (m.first ?? .nan) >= 30,
                  Self.f((m.last ?? .nan) - (m.first ?? .nan)))
        round.add("the As-sung control", control.pass, "")
        finishRound("V", round, rowIndex, report)
    }

    // MARK: A: air

    func roundA(_ rig: X9RRig, _ report: X9RReport, anchor: X9RLanded, anchorSha: String, anchorRender: X9RRender,
                cache: SingPhraseCache) async throws {
        let none = X9RMath.bands(anchorRender.left)
        let noneGain = anchor.lead.sungVocalProvenance?.loudness?.appliedGainDb
        let options: [(slug: String, label: String, air: Double?)] = [
            ("none", "None", nil), ("a-little", "A little", SungAirLayer.airLittle),
            ("some", "Some", SungAirLayer.airSome), ("lots", "Lots", SungAirLayer.airLots)]
        var highs: [Double] = []
        var rowIndex: [Int] = []
        for option in options {
            let j: X9RLanded
            let render: X9RRender
            if option.air == nil {
                j = anchor
                render = anchorRender
            } else {
                j = try await rig.job("A-\(option.slug)", style: SingStyle(air: option.air), cache: cache)
                render = try await rig.renderJob(j, label: "A-\(option.slug)")
            }
            let kept = try rig.keep(render, j, round: "A", option: option.slug)
            let b = X9RMath.bands(render.left)
            let hi = X9RMath.db(b.above2k, over: none.above2k)
            let lo1 = X9RMath.db(b.below1k, over: none.below1k)
            let lo2 = X9RMath.db(b.below2k, over: none.below2k)
            let gain = j.lead.sungVocalProvenance?.loudness?.appliedGainDb
            let gainDelta = (gain ?? .nan) - (noneGain ?? .nan)
            highs.append(hi)
            var g = X9RGates()
            if let air = option.air {
                let band: ClosedRange<Double> = air < 0.5 ? 1.0...2.0 : air < 0.9 ? 3.0...5.0 : 6.5...9.5
                g.add("above-2 kHz delta in \(band)", band.contains(hi), Self.f(hi))
                g.add("below-1 kHz delta == Δ appliedGainDb ± 0.15 dB", abs(lo1 - gainDelta) <= 0.15,
                      "below1k \(Self.f(lo1)) vs Δgain \(Self.f(gainDelta))")
                g.add("below-1 kHz delta in [−1.0, +0.05] dB", (-1.0...0.05).contains(lo1), Self.f(lo1))
                g.add("provenance.style.air == \(Self.f(air))", j.lead.sungVocalProvenance?.style?.air == air,
                      Self.f(j.lead.sungVocalProvenance?.style?.air))
                g.add("the same take before air: every unit from the cache",
                      j.status.cachedUnits == j.status.unitCount && j.status.renderedUnits == 0,
                      "cached \(j.status.cachedUnits)/\(j.status.unitCount)")
                g.add("air baked into the take: bytes differ from none", X9RMath.fileSha(j.leadTake) != anchorSha, "")
            } else {
                g.add("none is the anchor take", X9RMath.fileSha(j.leadTake) == anchorSha, "")
            }
            report.rows.append([
                "round": "A", "option": option.slug, "label": option.label, "axis": X9RMath.json(option.air ?? 0),
                "airLevelDb": X9RMath.json(option.air.flatMap { SungAirLayer.levelDb(forAir: $0) }),
                "files": kept, "job": j.facts, "pass": g.pass, "gates": g.list,
                "physics": ["instrument": "Hann-4096 power spectrum of the engine render (left), dB vs none",
                            "above2kDb": X9RMath.json(hi), "below2kDb": X9RMath.json(lo2),
                            "below1kDb": X9RMath.json(lo1), "appliedGainDb": X9RMath.json(gain),
                            "appliedGainDeltaDb": X9RMath.json(gainDelta),
                            "tableLanded": j.lead.clips.first?.pitchEdits != nil]])
            rowIndex.append(report.rows.count - 1)
            report.write()
            rig.note("A \(option.slug): gates \(g.pass ? "PASS" : "FAIL"), >2k \(Self.f(hi)) dB, <1k \(Self.f(lo1)) dB, "
                     + "<2k \(Self.f(lo2)) dB, Δgain \(Self.f(gainDelta)) dB")
        }
        var round = X9RGates()
        round.add("above-2 kHz strictly increasing", zip(highs, highs.dropFirst()).allSatisfy { $0 < $1 },
                  "\(highs.map { Self.f($0) })")
        finishRound("A", round, rowIndex, report)
    }

    // MARK: H1: the interval

    static func expected(_ midi: Int, _ spec: HarmonySpec) -> Int {
        HarmonyPlanner.diatonicStep(midi, interval: spec.interval, direction: spec.direction,
                                    key: X9RSource.cMajor).pitch - midi
    }

    /// Per note: the detected interval (rounded semitones) between lead and part, against the diatonic step.
    static func intervals(lead: PitchDetectionResult, part: PitchDetectionResult, spec: HarmonySpec)
    -> (rows: [[String: Any]], matched: Int, compared: Int) {
        var rows: [[String: Any]] = []
        var matched = 0, compared = 0
        for note in X9RSource.line().timeline {
            let a = note.start + 0.1, b = note.end - 0.1
            let l = X9RMath.noteHz(lead, from: a, to: b), p = X9RMath.noteHz(part, from: a, to: b)
            let want = expected(note.midi, spec)
            var row: [String: Any] = ["midi": note.midi, "start": note.start, "expected": want,
                                      "leadHz": X9RMath.json(l.hz), "partHz": X9RMath.json(p.hz)]
            if let lh = l.hz, let ph = p.hz {
                let cents = 1200 * log2(ph / lh)
                let semis = Int((cents / 100).rounded())
                let match = ((semis - want) % 12 + 12) % 12 == 0
                compared += 1
                if match { matched += 1 }
                row["cents"] = X9RMath.json(cents)
                row["semitones"] = semis
                row["match"] = match
                if match { row["octaveOffset"] = (semis - want) / 12 }
            }
            rows.append(row)
        }
        return (rows, matched, compared)
    }

    func roundH1(_ rig: X9RRig, _ report: X9RReport, anchorSha: String, leadDetect: PitchDetectionResult,
                 cache: SingPhraseCache, dir: URL) async throws -> (String?, PitchDetectionResult?) {
        let options: [(slug: String, label: String, spec: HarmonySpec)] = [
            ("third-above", "Third above", Self.thirdAbove),
            ("sixth-below", "Sixth below", HarmonySpec(interval: .sixth, direction: .below, chordSource: .none)),
            ("third-below", "Third below", HarmonySpec(interval: .third, direction: .below, chordSource: .none)),
            ("fifth-above", "Fifth above", HarmonySpec(interval: .fifth, direction: .above, chordSource: .none))]
        var thirdSha: String?
        var thirdDetect: PitchDetectionResult?
        var rowIndex: [Int] = []
        for option in options {
            let j = try await rig.job("H1-\(option.slug)", parts: [SingJobPart(.harmony(option.spec))], cache: cache)
            let mix = try await rig.renderJob(j, label: "H1-\(option.slug)")
            let partSolo = try await rig.renderJob(j, [j.parts[0]], label: "H1-\(option.slug)-part")
            let kept = try rig.keep(mix, j, round: "H1", option: option.slug)
            let partDetect = try X9RMath.detect(partSolo.mono, name: "H1-\(option.slug)-part.wav", dir: dir)
            let iv = Self.intervals(lead: leadDetect, part: partDetect, spec: option.spec)
            let share = iv.compared > 0 ? Double(iv.matched) / Double(iv.compared) : 0
            let status = (j.status.parts ?? []).first { $0.role != SingJobPartStatusRoles.lead }
            if option.slug == "third-above" {
                thirdSha = X9RMath.fileSha(j.partTake())
                thirdDetect = partDetect
            }
            var g = X9RGates()
            g.add("detected interval (mod 12) matches on ≥ 80 % of notes", share >= 0.8,
                  "\(iv.matched)/\(iv.compared)")
            g.add("the lead's take == the anchor's", X9RMath.fileSha(j.leadTake) == anchorSha, "")
            g.add("pre-registered: part octaveShift 0 and fits", status?.octaveShift == 0 && status?.fits == true,
                  "octaveShift \(status?.octaveShift ?? 99) fits \(status?.fits ?? false)")
            report.rows.append([
                "round": "H1", "option": option.slug, "label": option.label,
                "axis": "\(option.spec.interval.rawValue) \(option.spec.direction.rawValue)",
                "files": kept, "job": j.facts, "pass": g.pass, "gates": g.list,
                "physics": ["instrument": "SwiftF0 (product) per-note median, lead-only vs part-only engine renders",
                            "matched": iv.matched, "compared": iv.compared, "share": X9RMath.json(share),
                            "notes": iv.rows, "partSha": X9RMath.fileSha(j.partTake())]])
            rowIndex.append(report.rows.count - 1)
            report.write()
            rig.note("H1 \(option.slug): gates \(g.pass ? "PASS" : "FAIL"), interval matched \(iv.matched)/\(iv.compared), "
                     + "part octaveShift \(status?.octaveShift ?? 99)")
        }
        finishRound("H1", X9RGates(), rowIndex, report)
        return (thirdSha, thirdDetect)
    }

    // MARK: H2: the level

    func roundH2(_ rig: X9RRig, _ report: X9RReport, anchorSha: String, thirdAboveSha: String?,
                 cache: SingPhraseCache) async throws {
        let levels: [Double] = [-2, -4, -6, -9]
        var partLufs: [Double] = []
        var partShas: [String] = []
        var rowIndex: [Int] = []
        for db in levels {
            let slug = "minus-\(Int(-db))db"
            let j = try await rig.job("H2-\(slug)", parts: [SingJobPart(.harmony(Self.thirdAbove), volumeDb: db)],
                                      cache: cache)
            let mix = try await rig.renderJob(j, label: "H2-\(slug)")
            let leadSolo = try await rig.renderJob(j, [j.lead], label: "H2-\(slug)-lead")
            let kept = try rig.keep(mix, j, round: "H2", option: slug)
            let residual = zip(mix.channels, leadSolo.channels).map { m, l in zip(m, l).map { $0 - $1 } }
            let level = X9RMath.lufs(residual) ?? .nan
            partLufs.append(level)
            let partSha = X9RMath.fileSha(j.partTake())
            partShas.append(partSha)
            var g = X9RGates()
            g.add("the lead's take == the anchor's", X9RMath.fileSha(j.leadTake) == anchorSha, "")
            if let thirdAboveSha {
                g.add("the part take == H1 third-above's (the SAME part render)", partSha == thirdAboveSha, "")
            }
            g.add("the part track's volume == \(Int(db)) dB",
                  abs((j.parts.first?.volume ?? 0) - SingJobPart.volume(db: db)) < 1e-9,
                  Self.f(j.parts.first?.volume))
            report.rows.append([
                "round": "H2", "option": slug, "label": "\(Int(db)) dB", "axis": db,
                "files": kept, "job": j.facts, "pass": g.pass, "gates": g.list,
                "physics": ["instrument": "DAWCore Loudness (BS.1770) of (mix − lead-only render)",
                            "partInMixLufs": X9RMath.json(level), "partSha": partSha]])
            rowIndex.append(report.rows.count - 1)
            report.write()
            rig.note("H2 \(slug): gates \(g.pass ? "PASS" : "FAIL"), the part in the mix \(Self.f(level)) LUFS")
        }
        var round = X9RGates()
        let steps = zip(partLufs, partLufs.dropFirst()).map { $1 - $0 }
        let want: [Double] = [-2, -2, -3]
        round.add("level steps −2/−2/−3 dB ± 0.1", steps.count == 3 && zip(steps, want).allSatisfy { abs($0 - $1) <= 0.1 },
                  "\(steps.map { Self.f($0) })")
        round.add("one part render across the round", Set(partShas).count == 1, "\(Set(partShas).count) distinct")
        finishRound("H2", round, rowIndex, report)
    }

    // MARK: H3: the part's seed

    func roundH3(_ rig: X9RRig, _ report: X9RReport, anchorSha: String, leadDetect: PitchDetectionResult,
                 thirdAboveSha: String?, thirdAboveDetect: PitchDetectionResult?,
                 cache: SingPhraseCache, dir: URL) async throws {
        let lead = SingJobRequestBuilder.firstTakeSeed
        // W9-PICKS: "seed-lead" names the lead's seed (an unnamed part seed is the lead's + 2 since the H3 pick).
        let seeds: [(slug: String, label: String, seed: UInt64?)] = [
            ("seed-lead", "The lead's seed", lead), ("seed-2", "Seed \(lead + 1)", lead + 1),
            ("seed-3", "Seed \(lead + 2)", lead + 2), ("seed-4", "Seed \(lead + 3)", lead + 3)]
        var shas: [String] = []
        var reference = thirdAboveDetect
        var rowIndex: [Int] = []
        for option in seeds {
            let j = try await rig.job("H3-\(option.slug)", parts: [SingJobPart(.harmony(Self.thirdAbove), seed: option.seed)],
                                      cache: cache)
            let mix = try await rig.renderJob(j, label: "H3-\(option.slug)")
            let partSolo = try await rig.renderJob(j, [j.parts[0]], label: "H3-\(option.slug)-part")
            let kept = try rig.keep(mix, j, round: "H3", option: option.slug)
            let partDetect = try X9RMath.detect(partSolo.mono, name: "H3-\(option.slug)-part.wav", dir: dir)
            if option.seed == lead, reference == nil { reference = partDetect }
            let sha = X9RMath.fileSha(j.partTake())
            shas.append(sha)
            let iv = Self.intervals(lead: leadDetect, part: partDetect, spec: Self.thirdAbove)
            let share = iv.compared > 0 ? Double(iv.matched) / Double(iv.compared) : 0
            let diff = reference.map { X9RMath.meanAbsCents(partDetect, $0) }
            var g = X9RGates()
            g.add("the lead's take == the anchor's", X9RMath.fileSha(j.leadTake) == anchorSha, "")
            g.add("interval still matches on ≥ 80 % of notes", share >= 0.8, "\(iv.matched)/\(iv.compared)")
            if option.seed == lead {
                if let thirdAboveSha { g.add("== H1 third-above's part bytes", sha == thirdAboveSha, "") }
                g.add("the part sang on the lead's seed", (j.status.parts ?? []).allSatisfy { $0.seed == lead }, "")
            } else {
                g.add("pitch track differs from the lead-seed part: mean |Δ| > 5 c", (diff?.cents ?? 0) > 5,
                      "\(Self.f(diff?.cents)) c over \(diff?.frames ?? 0) co-voiced frames")
            }
            report.rows.append([
                "round": "H3", "option": option.slug, "label": option.label,
                "axis": Int(option.seed ?? lead), "files": kept, "job": j.facts, "pass": g.pass, "gates": g.list,
                "physics": ["instrument": "SwiftF0 (product) on the part-only engine render",
                            "partSha": sha, "meanAbsCentsVsLeadSeedPart": X9RMath.json(diff?.cents),
                            "coVoicedFrames": diff?.frames ?? 0, "intervalShare": X9RMath.json(share)]])
            rowIndex.append(report.rows.count - 1)
            report.write()
            rig.note("H3 \(option.slug): gates \(g.pass ? "PASS" : "FAIL"), |Δ| \(Self.f(diff?.cents)) c, "
                     + "interval \(iv.matched)/\(iv.compared)")
        }
        var round = X9RGates()
        round.add("four distinct part takes", Set(shas).count == 4, "\(Set(shas).count) distinct")
        finishRound("H3", round, rowIndex, report)
    }

    // MARK: D: double width

    func roundD(_ rig: X9RRig, _ report: X9RReport, anchorSha: String, cache: SingPhraseCache) async throws {
        let pans: [Double] = [0.2, 0.4, 0.7, 1.0]
        var correlations: [Double] = []
        var shas: [String] = []
        var rowIndex: [Int] = []
        for pan in pans {
            let slug = "pan-\(String(format: "%.1f", pan))"
            let j = try await rig.job("D-\(slug)", parts: [SingJobPart(.double, pan: pan)], cache: cache)
            let mix = try await rig.renderJob(j, label: "D-\(slug)")
            let doubleSolo = try await rig.renderJob(j, [j.parts[0]], label: "D-\(slug)-double")
            let kept = try rig.keep(mix, j, round: "D", option: slug)
            let corr = X9RMath.correlation(mix.left, mix.right)
            correlations.append(corr)
            let stereo = X9RMath.lufs(mix.channels) ?? .nan
            let mono = X9RMath.lufs([mix.mono]) ?? .nan
            let take = j.partTake().flatMap { try? SingWAV.read($0).mono } ?? []
            let gainL = X9RMath.rmsDb(doubleSolo.left) - X9RMath.rmsDb(take)
            let gainR = X9RMath.rmsDb(doubleSolo.right) - X9RMath.rmsDb(take)
            let sha = X9RMath.fileSha(j.partTake())
            shas.append(sha)
            let status = (j.status.parts ?? []).first { $0.role != SingJobPartStatusRoles.lead }
            var g = X9RGates()
            g.add("the lead's take == the anchor's", X9RMath.fileSha(j.leadTake) == anchorSha, "")
            g.add("the double differs from the lead", sha != anchorSha, "")
            g.add("the double's seed is the lead's + 7919",
                  status?.seed == SingJobRequestBuilder.firstTakeSeed + SingJobPart.doubleSeedOffset,
                  "\(status?.seed ?? 0)")
            g.add("the double track sits at pan \(pan)", abs((j.parts.first?.pan ?? 9) - pan) < 1e-9,
                  Self.f(j.parts.first?.pan))
            g.add("mono sum audible (> −40 LUFS)", mono > -40, Self.f(mono))
            g.add("mono − stereo ≥ −4.5 dB (amendment D-1)", mono - stereo >= -4.5, Self.f(mono - stereo))
            report.rows.append([
                "round": "D", "option": slug, "label": "±\(String(format: "%.1f", pan))", "axis": pan,
                "files": kept, "job": j.facts, "pass": g.pass, "gates": g.list,
                "physics": ["instrument": "Pearson L/R over the engine render; DAWCore Loudness on (L+R)/2 vs stereo",
                            "correlation": X9RMath.json(corr), "stereoLufs": X9RMath.json(stereo),
                            "monoLufs": X9RMath.json(mono), "monoMinusStereoDb": X9RMath.json(mono - stereo),
                            "doubleGainLdB": X9RMath.json(gainL), "doubleGainRdB": X9RMath.json(gainR),
                            "doubleSha": sha]])
            rowIndex.append(report.rows.count - 1)
            report.write()
            rig.note("D \(slug): gates \(g.pass ? "PASS" : "FAIL"), corr \(Self.f(corr)), mono−stereo "
                     + "\(Self.f(mono - stereo)) dB, double L/R gain \(Self.f(gainL))/\(Self.f(gainR)) dB")
        }
        var round = X9RGates()
        round.add("L/R correlation strictly decreasing with pan",
                  zip(correlations, correlations.dropFirst()).allSatisfy { $0 > $1 }, "\(correlations.map { Self.f($0) })")
        round.add("one double render across the round", Set(shas).count == 1, "\(Set(shas).count) distinct")
        finishRound("D", round, rowIndex, report)
    }

    /// Writes the round-level gates and folds them into every option's pass/fail.
    func finishRound(_ name: String, _ gates: X9RGates, _ rowIndex: [Int], _ report: X9RReport) {
        var existing = report.rounds[name] as? [String: Any] ?? [:]
        existing["gates"] = gates.list
        existing["pass"] = gates.pass
        report.rounds[name] = existing
        for i in rowIndex {
            report.rows[i]["roundPass"] = gates.pass
            report.rows[i]["pass"] = ((report.rows[i]["pass"] as? Bool) ?? false) && gates.pass
        }
        report.write()
    }
}
