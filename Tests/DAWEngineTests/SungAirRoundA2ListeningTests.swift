import CryptoKit
import Foundation
import Testing

@testable import AIServices
@testable import DAWCore
@testable import DAWEngine

// W9-AIR (p2-sing-x9-air): listening round A2, "breath, not static", SUNG BY THE REAL SINGING ENGINE and HEARD
// THROUGH THE ENGINE'S OFFLINE RENDER. Round A's phrase, voice, seed and render path, through W8-X9R's own rig
// (`X9RRig`, `X9RSource`, `X9RMath` in `SingListeningRoundsX9RTests.swift`), so nothing about the source can drift.
//
// ⛔ ENV-GATED: runs ONLY with `AIR_ROUND=1` (plus the rig's `X9R_*` variables), after the lane's driver has started
// a singing sidecar on a PRIVATE port from a scratch runtime. Every normal run skips it.
//
// The ONE axis: how tightly the air is tied to the voice (`SungAirLayer.Coupling`), at ONE matched level ("some").
// - "none": the anchor take (no style), rendered.
// - rung 0 "loudness": the PRODUCT's own landed take for `SingStyle(air: some)` (today's layer, the sing job's path).
// - rungs 1-2 "tone", "tonePulse": the SAME job's pre-air sum, captured bit-exact from the `detectPitch` seam (the
//   coordinator writes it as `<job>-preair.wav` and hands it to the detector), through `SungAirLayer.apply(…,
//   coupling:)`, then the product's own normaliser, written with the product's own writer.
// The first control: that path with `.loudness` must give the product's landed take BYTE FOR BYTE.

extension X9RRig {
    /// `job(_:style:parts:cache:)` with ONE change: the detector closure also copies the coordinator's pre-air sum
    /// (`*-preair.wav`) to `capture` before detecting on it.
    func airJob(_ label: String, style: SingStyle?, cache: SingPhraseCache, capture: URL?) async throws -> X9RLanded {
        guard Date() < deadline else { throw X9RError("the wall-clock budget was spent before job \(label)") }
        let root = work.appendingPathComponent("jobs/\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (store, clipID) = try await MainActor.run { try X9RSource.store(root: root, style: style) }
        let detect: @Sendable (URL) async throws -> [ClipPitchFrame] = { url in
            if let capture, url.lastPathComponent.hasSuffix("-preair.wav") {
                try? FileManager.default.removeItem(at: capture)
                try FileManager.default.copyItem(at: url, to: capture)
            }
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
        let id = try await coordinator.submit(SingJobRequest(clipID: clipID, parts: [], key: X9RSource.cMajor)).jobID
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
                           + "\(status.error?.message ?? "") \(status.error?.detail ?? "")")
        }
        let (tracks, tempo) = await MainActor.run { (store.tracks, store.transport.tempoMap) }
        let sung = tracks.filter { $0.kind == .audio }
        guard let lead = sung.first(where: { $0.id == result.trackID }) else {
            throw X9RError("job \(label): the lead track \(result.trackID) is not in the store")
        }
        note("job \(label): done in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, units "
             + "\(status.unitCount) (cached \(status.cachedUnits), rendered \(status.renderedUnits)), warnings "
             + "\(status.warnings)")
        return X9RLanded(label: label, status: status, tracks: sung, tempo: tempo, lead: lead, parts: [])
    }
}

@Suite("W9-AIR listening round A2 through the real singing engine (AIR_ROUND=1 only)")
struct SungAirRoundA2ListeningTests {

    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["AIR_ROUND"] == "1"
    /// Round A (W8-X9R, 2026-10-07), from its `out/swift-rounds.json` and its stems (READ by the driver).
    static let oldAnchorTakeSha = env["AIR_OLD_ANCHOR_TAKE_SHA"] ?? ""
    static let oldSomeTakeSha = env["AIR_OLD_SOME_TAKE_SHA"] ?? ""
    static let oldNoneRenderSha = env["AIR_OLD_NONE_RENDER_SHA"] ?? ""
    static let oldSomeRenderSha = env["AIR_OLD_SOME_RENDER_SHA"] ?? ""

    static func f(_ x: Double?) -> String { x.map { String(format: "%.4f", $0) } ?? "nil" }

    static func energyDb(_ a: [Float], minus b: [Float]) -> Double {
        var sum = 0.0
        for i in 0..<min(a.count, b.count) {
            let d = Double(a[i]) - Double(b[i])
            sum += d * d
        }
        return sum > 0 ? 10 * log10(sum) : -300
    }

    /// The lead clip of `tracks` pointing at `take` instead (nothing else changes).
    static func withLeadTake(_ tracks: [Track], lead: UUID, take: URL) -> [Track] {
        var out = tracks
        for t in out.indices where out[t].id == lead {
            for c in out[t].clips.indices { out[t].clips[c].audioFileURL = take }
        }
        return out
    }

    @Test("W9-AIR: round A2 (none, loudness, tone, tonePulse) sung by the real engine, heard through the offline render",
          .enabled(if: SungAirRoundA2ListeningTests.enabled))
    func roundA2() async throws {
        let rig = try await X9RRig.make()
        let fm = FileManager.default
        let takes = rig.out.appendingPathComponent("takes", isDirectory: true)
        let raw = rig.out.appendingPathComponent("raw", isDirectory: true)
        try fm.createDirectory(at: takes, withIntermediateDirectories: true)
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        var report: [String: Any] = ["health": rig.health, "startedAt": ISO8601DateFormatter().string(from: Date())]
        var gates: [[String: Any]] = []
        func gate(_ name: String, _ ok: Bool, _ detail: String) {
            gates.append(["gate": name, "pass": ok, "detail": detail])
            rig.note("GATE \(ok ? "PASS" : "FAIL") \(name): \(detail)")
        }
        func write() {
            report["gates"] = gates
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: rig.out.appendingPathComponent("swift-a2.json"))
            }
        }

        // ---- D0: determinism. Two REAL renders in two fresh caches, then round A's anchor.
        let a = try await rig.airJob("none-a", style: nil, cache: rig.cache("a2-det-a"), capture: nil)
        let shared = rig.cache("a2-shared")
        let anchor = try await rig.airJob("none-b", style: nil, cache: shared, capture: nil)
        let anchorSha = X9RMath.fileSha(anchor.leadTake)
        gate("D0 two real renders, same seed, byte-equal take",
             X9RMath.fileSha(a.leadTake) == anchorSha && anchorSha != "missing"
                 && a.status.cachedUnits == 0 && anchor.status.cachedUnits == 0
                 && a.status.renderedUnits >= 1 && anchor.status.renderedUnits >= 1,
             "\(X9RMath.fileSha(a.leadTake).prefix(16)) vs \(anchorSha.prefix(16)); cached \(a.status.cachedUnits)/"
                 + "\(anchor.status.cachedUnits), rendered \(a.status.renderedUnits)/\(anchor.status.renderedUnits)")
        let sameAsRoundA = anchorSha == Self.oldAnchorTakeSha
        gate("D0' the anchor take equals round A's (2026-10-07)", sameAsRoundA,
             "\(anchorSha.prefix(16)) vs \(Self.oldAnchorTakeSha.prefix(16))")
        report["anchor"] = ["takeSha": anchorSha, "seed": Int(anchor.status.seed),
                            "appliedGainDb": X9RMath.json(anchor.lead.sungVocalProvenance?.loudness?.appliedGainDb),
                            "takePath": anchor.leadTake?.path ?? "missing"]
        write()

        // ---- rung 0: the PRODUCT's landed take at "some", with the pre-air sum captured from the detector seam.
        let preURL = rig.work.appendingPathComponent("preair-some.wav")
        let some = SungAirLayer.airSome
        let product = try await rig.airJob("loudness-some", style: SingStyle(air: some), cache: shared, capture: preURL)
        let productSha = X9RMath.fileSha(product.leadTake)
        gate("rung 0 is the product's job: every unit from the cache, the style landed",
             product.status.cachedUnits == product.status.unitCount && product.status.renderedUnits == 0
                 && product.lead.sungVocalProvenance?.style?.air == some,
             "cached \(product.status.cachedUnits)/\(product.status.unitCount), style.air "
                 + "\(Self.f(product.lead.sungVocalProvenance?.style?.air))")
        if sameAsRoundA {
            gate("the product's 'some' take after the W9-AIR edit equals round A's 'some' take (default untouched)",
                 productSha == Self.oldSomeTakeSha, "\(productSha.prefix(16)) vs \(Self.oldSomeTakeSha.prefix(16))")
        }
        let preAudio = try SingWAV.read(preURL)
        let preair = preAudio.mono
        let rate = preAudio.sampleRate
        let seed = product.status.seed

        // The spans, by the expression pass's own steps (`SingJobCoordinator.expressionPass`), on the captured sum.
        let frames = try ClipPitchAnalyzer.detect(
            fileAt: preURL, fromSeconds: 0, durationSeconds: Double(preair.count) / Double(rate),
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs).frames
        let planRoot = rig.work.appendingPathComponent("jobs/plan", isDirectory: true)
        try fm.createDirectory(at: planRoot, withIntermediateDirectories: true)
        let (plan, clipNotes) = try await MainActor.run { () throws -> (SingPlan, [MIDINote]) in
            let (store, clipID) = try X9RSource.store(root: planRoot, style: SingStyle(air: some))
            let planning = try store.planSungVocal(clipId: clipID, octaveShift: 0)
            let clip = store.tracks.lazy.flatMap(\.clips).first { $0.id == clipID }
            return (planning.plan, clip?.notes ?? [])
        }
        let detected = PitchNoteTable.detected(from: SingJobCoordinator.detectionResult(
            frames, sampleRate: rate, durationSeconds: Double(preair.count) / Double(rate)))
        guard let notes = SungExpressionPlanner.notes(planned: plan.notes, windows: SingTakeAssembly.noteWindows(plan),
                                                      velocities: SingJobCoordinator.velocities(of: clipNotes)) else {
            throw X9RError("the planned notes do not match their windows")
        }
        let expression = try SungExpressionPlanner.plan(notes: notes, style: SingStyle(air: some), detected: detected,
                                                        clipID: plan.clipID)
        let spans = expression.airSpans
        report["spans"] = spans.map { ["start": $0.startSeconds, "end": $0.endSeconds, "levelDb": $0.levelDb] }
        report["preair"] = ["path": preURL.path, "sha": X9RMath.fileSha(preURL), "rate": rate, "frames": preair.count,
                            "seed": Int(seed)]

        // ---- The FIRST control: my path with `.loudness` == the product's landed take, byte for byte.
        func land(_ coupling: SungAirLayer.Coupling) async throws -> (url: URL, aired: [Float], gainDb: Double?) {
            let aired = SungAirLayer.apply(spans, to: preair, sampleRate: Double(rate), seed: seed, coupling: coupling)
            let normalized = try await ProjectStore.normalizeSungVocalTake(
                RenderedAudio(sampleRate: Double(rate), channelData: [aired]))
            let url = takes.appendingPathComponent("\(coupling.rawValue).wav")
            try? fm.removeItem(at: url)
            try SingWAV.writeFloat32Mono(normalized.audio.channelData.first ?? [], sampleRate: rate, to: url)
            let pre = takes.appendingPathComponent("\(coupling.rawValue)-pregain.wav")
            try? fm.removeItem(at: pre)
            try SingWAV.writeFloat32Mono(aired, sampleRate: rate, to: pre)
            return (url, aired, normalized.report.appliedGainDb)
        }
        let mine = try await land(.loudness)
        let mineSha = X9RMath.fileSha(mine.url)
        gate("my path with .loudness == the product's landed take, byte for byte (pre-air capture + spans + normaliser)",
             mineSha == productSha, "\(mineSha.prefix(16)) vs \(productSha.prefix(16))")
        write()
        guard mineSha == productSha else {
            rig.note("the first control failed: no candidate is rendered")
            #expect(Bool(false), "my path does not reproduce the product's take")
            return
        }
        try? fm.removeItem(at: takes.appendingPathComponent("preair.wav"))
        try fm.copyItem(at: preURL, to: takes.appendingPathComponent("preair.wav"))

        // ---- Renders: none, loudness (the product's take), tone, tonePulse.
        let todayEnergy = Self.energyDb(mine.aired, minus: preair)
        var options: [[String: Any]] = []
        func keep(_ slug: String, tracks: [Track], tempo: TempoMap, take: URL, pregain: URL?, gainDb: Double?,
                  airEnergyDb: Double?) async throws -> String {
            let render = try await rig.render(tracks, tempo: tempo, label: "a2-\(slug)")
            let url = raw.appendingPathComponent("\(slug).wav")
            try M23QComparisonPair.writeWAV([render.left, render.right], sampleRate: X9RSource.rate, to: url)
            let stem = takes.appendingPathComponent("\(slug)-lead.wav")
            if stem.path != take.path {
                try? fm.removeItem(at: stem)
                try fm.copyItem(at: take, to: stem)
            }
            options.append(["option": slug, "raw": url.path, "renderSha": render.sha, "take": stem.path,
                            "takeSha": X9RMath.fileSha(stem), "pregain": pregain?.path ?? NSNull(),
                            "appliedGainDb": X9RMath.json(gainDb), "airEnergyDb": X9RMath.json(airEnergyDb),
                            "airEnergyVsTodayDb": X9RMath.json(airEnergyDb.map { $0 - todayEnergy }),
                            "stretched": render.stretched, "shortfalls": render.shortfalls])
            report["options"] = options
            write()
            return render.sha
        }
        guard let anchorTake = anchor.leadTake, let productTake = product.leadTake else {
            throw X9RError("a landed take is missing")
        }
        let noneSha = try await keep("none", tracks: anchor.tracks, tempo: anchor.tempo, take: anchorTake, pregain: nil,
                                     gainDb: anchor.lead.sungVocalProvenance?.loudness?.appliedGainDb,
                                     airEnergyDb: nil)
        if sameAsRoundA {
            gate("No air renders byte-identical to round A's No air", noneSha == Self.oldNoneRenderSha,
                 "\(noneSha.prefix(16)) vs \(Self.oldNoneRenderSha.prefix(16))")
        }
        let todaySha = try await keep("loudness", tracks: product.tracks, tempo: product.tempo, take: productTake,
                                      pregain: takes.appendingPathComponent("loudness-pregain.wav"),
                                      gainDb: product.lead.sungVocalProvenance?.loudness?.appliedGainDb,
                                      airEnergyDb: todayEnergy)
        if sameAsRoundA {
            gate("today's air at 'some' renders byte-identical to round A's 'some'", todaySha == Self.oldSomeRenderSha,
                 "\(todaySha.prefix(16)) vs \(Self.oldSomeRenderSha.prefix(16))")
        }
        // The swap control: the product's tracks with the lead clip pointed at MY .loudness take (the same bytes)
        // must render byte-identical to the product's own, or swapping a take in the clip is not a faithful render.
        let swapped = try await rig.render(Self.withLeadTake(product.tracks, lead: product.lead.id, take: mine.url),
                                           tempo: product.tempo, label: "a2-swap-control")
        gate("a swapped-in take with the product's bytes renders byte-identical to the product's own",
             swapped.sha == todaySha, "\(swapped.sha.prefix(16)) vs \(todaySha.prefix(16))")
        for coupling in [SungAirLayer.Coupling.tone, .tonePulse] {
            let landed = try await land(coupling)
            let energy = Self.energyDb(landed.aired, minus: preair)
            gate("\(coupling.rawValue): added energy within 0.2 dB of today's", abs(energy - todayEnergy) <= 0.2,
                 "\(Self.f(energy - todayEnergy)) dB")
            let tracks = Self.withLeadTake(product.tracks, lead: product.lead.id, take: landed.url)
            _ = try await keep(coupling.rawValue, tracks: tracks, tempo: product.tempo, take: landed.url,
                               pregain: takes.appendingPathComponent("\(coupling.rawValue)-pregain.wav"),
                               gainDb: landed.gainDb, airEnergyDb: energy)
        }
        report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        write()
        let failed = gates.filter { ($0["pass"] as? Bool) != true }.map { "\($0["gate"] ?? "")" }
        rig.note("round A2 finished: \(options.count) renders, failed gates: \(failed)")
        #expect(failed.isEmpty, "failed gates: \(failed)")
    }
}
