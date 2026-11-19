import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

// m39-panlaw-new (W9-PANLAW) — what the song's pan rule does to the SOUND.
//
// The user's pick (2026-10-07, "One rule for new songs only"): in a NEW song the pan knob uses the automation rule
// (constant loudness as it moves, √2·cos θ / √2·sin θ, θ = (p + 1)·π/4), so the knob at p and a constant pan lane at p
// must render IDENTICALLY — on a one-channel source, a true stereo source, an instrument strip and a bus strip. Songs
// already made keep the original rule (the knob is a linear balance), pinned by
// `MixerRenderTests.staticVersusAutomatedPanLaw`, which renders with the offline renderer's default (the original
// rule) and is left as it was.
//
// Nonisolated suites over `@MainActor` helpers (the CR0 harness pattern): no new `@MainActor` suite.

private enum PanLawRigError: Error {
    case setup(String)
}

@MainActor
enum PanLawRig {
    nonisolated static let sampleRate = 48_000.0
    static let tempoMap = TempoMap(constantBPM: 120)
    nonisolated static let seconds = 1.0
    /// A steady window well inside the 1 s render (clip from beat 0, 2.5 beats = 1.25 s long).
    nonisolated static let window = 12_000..<36_000
    nonisolated static let pans: [Double] = [-1.0, -0.4, 0.4, 0.5, 1.0]

    static func sources() throws -> (mono: URL, stereo: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawpro-panlaw-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mono = dir.appendingPathComponent("mono-1k.wav")
        let stereo = dir.appendingPathComponent("stereo-440-660.wav")
        if !FileManager.default.fileExists(atPath: mono.path) { try PanLawGate.writeSource(mono, channels: 1) }
        if !FileManager.default.fileExists(atPath: stereo.path) { try PanLawGate.writeSource(stereo, channels: 2) }
        return (mono, stereo)
    }

    static func constLane(_ key: String, _ p: Double) -> AutomationLane {
        AutomationLane(id: PanLawGate.id("\(key).lane"), target: .pan,
                       points: [AutomationPoint(beat: 0, value: p), AutomationPoint(beat: 2.5, value: p)])
    }

    /// One strip of `kind` ("mono" / "stereo" audio, "synth", "bus" — a bus fed by a centred mono strip), panned by
    /// the KNOB at `knob` and, when `lane` is non-nil, by a constant pan LANE on the panned strip.
    static func strip(_ kind: String, knob: Double, lane: Double?) throws -> [Track] {
        let (mono, stereo) = try sources()
        let key = "rig.\(kind)"
        let lanes = lane.map { [constLane(key, $0)] } ?? []
        switch kind {
        case "mono", "stereo":
            return [Track(id: PanLawGate.id("\(key).track"), name: kind, kind: .audio, pan: knob,
                          clips: [PanLawGate.clip(key, kind == "mono" ? mono : stereo)], automation: lanes)]
        case "synth":
            return [Track(id: PanLawGate.id("\(key).track"), name: kind, kind: .instrument, pan: knob,
                          clips: [Clip(id: PanLawGate.id("\(key).clip"), name: "notes", startBeat: 0,
                                       lengthBeats: 2.5, notes: PanLawGate.notes(key))],
                          instrument: InstrumentDescriptor(kind: .polySynth), automation: lanes)]
        case "bus":
            let busID = PanLawGate.id("\(key).bus")
            return [Track(id: PanLawGate.id("\(key).feed"), name: "feed", kind: .audio,
                          clips: [PanLawGate.clip(key, mono)], outputBusID: busID),
                    Track(id: busID, name: "bus", kind: .bus, pan: knob, automation: lanes)]
        default:
            throw PanLawRigError.setup("unknown strip kind \(kind)")
        }
    }

    static func render(_ tracks: [Track], law: PanLaw, frames: Int? = nil) throws -> RenderedAudio {
        let renderer = frames.map { OfflineRenderer(sampleRate: sampleRate, maximumFrameCount: $0) }
            ?? OfflineRenderer(sampleRate: sampleRate)
        renderer.panLaw = law
        return try renderer.render(tracks: tracks, tempoMap: tempoMap, durationSeconds: seconds)
    }

    /// Samples that differ (exact float compare) across both channels; a length mismatch counts every extra frame.
    static func differing(_ a: [[Float]], _ b: [[Float]]) -> Int {
        var count = abs(a.count - b.count)
        for (x, y) in zip(a, b) {
            count += abs(x.count - y.count)
            for i in 0..<min(x.count, y.count) where x[i] != y[i] { count += 1 }
        }
        return count
    }

    static func dB(_ x: Float) -> Double { 20 * log10(max(Double(x), 1e-12)) }

    static func levels(_ audio: RenderedAudio) -> (l: Double, r: Double) {
        (dB(TestSignals.rms(audio.channelData[0], in: window)), dB(TestSignals.rms(audio.channelData[1], in: window)))
    }

    /// The automation rule's gains in dB at pan p (left, right).
    static func expected(_ p: Double) -> (l: Double, r: Double) {
        let theta = (p + 1) * Double.pi / 4
        return (20 * log10(max(2.0.squareRoot() * cos(theta), 1e-12)),
                20 * log10(max(2.0.squareRoot() * sin(theta), 1e-12)))
    }

    /// Renders `tracks` through a STORE and a real `AudioEngine` (`renderBounce`): the store hands its rule to the
    /// engine's pan-carrying render (W9-PLRT R1), which hands it to the offline renderer; the engine's cached rule
    /// (reported as `engineLaw`) is the LIVE graph's. `newSong` runs `newProject()` first.
    static func renderThroughStore(_ tracks: [Track], newSong: Bool, label: String) async throws
        -> (channels: [[Float]], storeLaw: PanLaw, engineLaw: PanLaw, liveGraphLaw: PanLaw) {
        let engine = AudioEngine()
        let store = ProjectStore()
        store.engine = engine
        if newSong { try store.newProject(discardChanges: true) }
        store.tracks = tracks
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawpro-panlaw-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("\(label).wav")
        _ = try await store.renderBounce(toPath: url.path, fromBeat: 0, durationSeconds: seconds)
        let channels = try TestSignals.readFile(url)
        let laws = (store.panLaw, engine.panLaw, engine.graph.panLaw)
        withExtendedLifetime(engine) {}
        return (channels, laws.0, laws.1, laws.2)
    }

    /// Opens a saved bundle in a store that held the NEW rule first (so a rule that is not replaced by the open
    /// shows), then renders it through the store and a real engine.
    static func openAndRender(bundle: URL, to wav: URL) async throws
        -> (storeLaw: PanLaw, engineLaw: PanLaw, channels: [[Float]]) {
        let engine = AudioEngine()
        let store = ProjectStore()
        store.engine = engine
        try store.newProject(discardChanges: true)
        _ = try store.openProject(at: bundle.path, discardChanges: true)
        let laws = (store.panLaw, engine.panLaw)
        _ = try await store.renderBounce(toPath: wav.path, fromBeat: 0, durationSeconds: seconds)
        let channels = try TestSignals.readFile(wav)
        withExtendedLifetime(engine) {}
        return (laws.0, laws.1, channels)
    }

    static func save(_ tracks: [Track], to bundle: URL) throws {
        let saver = ProjectStore()
        saver.tracks = tracks
        _ = try saver.saveProject(to: bundle.path)
    }
}

@Suite("m39-panlaw-new: a new song's pan knob uses the automation rule", .serialized)
struct PanLawRenderTests {

    @Test("New song: the knob at p renders sample-identical to a constant pan lane at p (mono, stereo, synth, bus)")
    func newSongKnobEqualsConstantLane() async throws {
        var failures: [String] = []
        var balanceSame: [String] = []
        var axisDead: [String] = []
        for kind in ["mono", "stereo", "synth", "bus"] {
            for p in PanLawRig.pans {
                let knob = try await PanLawRig.render(PanLawRig.strip(kind, knob: p, lane: nil), law: .equalPower)
                let lane = try await PanLawRig.render(PanLawRig.strip(kind, knob: 0, lane: p), law: .equalPower)
                let n = await PanLawRig.differing(knob.channelData, lane.channelData)
                print("[PANLAW] identity \(kind) p=\(p): knob vs lane differing samples = \(n)")
                if n != 0 { failures.append("\(kind)@\(p)=\(n)") }
                #expect(TestSignals.peak(knob.channelData[0] + knob.channelData[1], in: 0..<96_000) > 0.05,
                        "\(kind)@\(p): silent render")
                // CONTROL 1: the original rule (a saved song) keeps today's difference — the axis is real.
                let oldKnob = try await PanLawRig.render(PanLawRig.strip(kind, knob: p, lane: nil), law: .balance)
                if await PanLawRig.differing(oldKnob.channelData, lane.channelData) == 0 {
                    balanceSame.append("\(kind)@\(p)")
                }
                // CONTROL 2: the field moves the knob's sound (identical bytes would mean it did nothing).
                if await PanLawRig.differing(oldKnob.channelData, knob.channelData) == 0 {
                    axisDead.append("\(kind)@\(p)")
                }
            }
        }
        #expect(failures.isEmpty, "new song: knob != constant lane: \(failures)")
        #expect(balanceSame.isEmpty, "control: an OLD song's knob already equals the lane at \(balanceSame)")
        #expect(axisDead.isEmpty, "control: the pan rule changed nothing at \(axisDead)")
    }

    @Test("New song: measured levels at full pan and halfway match the automation rule (+3.01 dB / +2.32 / -5.33 dB)")
    func newSongLevelsMatchTheAutomationRule() async throws {
        let centre = try await PanLawRig.levels(PanLawRig.render(PanLawRig.strip("mono", knob: 0, lane: nil),
                                                                  law: .equalPower))
        let oldCentre = try await PanLawRig.levels(PanLawRig.render(PanLawRig.strip("mono", knob: 0, lane: nil),
                                                                     law: .balance))
        #expect(abs(centre.l - oldCentre.l) < 1e-9 && abs(centre.r - oldCentre.r) < 1e-9,
                "the centre is the same in both rules")
        #expect(centre.l > -20, "control: real signal (\(centre.l) dB)")
        for p in [1.0, 0.5, -0.4, -1.0] {
            let new = try await PanLawRig.levels(PanLawRig.render(PanLawRig.strip("mono", knob: p, lane: nil),
                                                                   law: .equalPower))
            let old = try await PanLawRig.levels(PanLawRig.render(PanLawRig.strip("mono", knob: p, lane: nil),
                                                                   law: .balance))
            let want = await PanLawRig.expected(p)
            let gotL = new.l - centre.l, gotR = new.r - centre.r
            print("[PANLAW] level p=\(p) NEW song: L \(gotL) dB, R \(gotR) dB (rule: L \(want.l), R \(want.r)); "
                  + "OLD song: L \(old.l - centre.l) dB, R \(old.r - centre.r) dB")
            for (got, rule, side) in [(gotL, want.l, "L"), (gotR, want.r, "R")] {
                if rule < -100 {
                    #expect(got < -100, "p=\(p) \(side): the far side must be gone (\(got) dB)")
                } else {
                    #expect(abs(got - rule) < 0.01, "p=\(p) \(side): \(got) dB vs the rule's \(rule) dB")
                }
            }
        }
        // The near side at full pan: +3.01 dB in a new song, unchanged (0 dB) in an old one.
        let full = try await PanLawRig.levels(PanLawRig.render(PanLawRig.strip("mono", knob: 1, lane: nil),
                                                                law: .equalPower))
        let oldFull = try await PanLawRig.levels(PanLawRig.render(PanLawRig.strip("mono", knob: 1, lane: nil),
                                                                   law: .balance))
        #expect(abs((full.r - centre.r) - 3.0103) < 0.01)
        #expect(abs(oldFull.r - centre.r) < 0.1, "an OLD song's near side stays at the centre level")
    }

    @Test("Both rules leave a centred knob bit-identical (the stage's centre short-circuit)")
    func centreIsIdenticalInBothRules() async throws {
        for kind in ["mono", "stereo", "synth", "bus"] {
            let new = try await PanLawRig.render(PanLawRig.strip(kind, knob: 0, lane: nil), law: .equalPower)
            let old = try await PanLawRig.render(PanLawRig.strip(kind, knob: 0, lane: nil), law: .balance)
            #expect(await PanLawRig.differing(new.channelData, old.channelData) == 0, "\(kind)")
        }
    }

    @Test("Through the store and a real engine: a NEW song's knob equals its lane; an OLD song's does not")
    func throughTheStoreAndEngine() async throws {
        let knob = try await PanLawRig.strip("mono", knob: 0.4, lane: nil)
        let lane = try await PanLawRig.strip("mono", knob: 0, lane: 0.4)
        let newKnob = try await PanLawRig.renderThroughStore(knob, newSong: true, label: "new-knob")
        let newLane = try await PanLawRig.renderThroughStore(lane, newSong: true, label: "new-lane")
        #expect(newKnob.storeLaw == .equalPower && newKnob.engineLaw == .equalPower
                && newKnob.liveGraphLaw == .equalPower, "New Project must reach the engine and its live graph")
        #expect(await PanLawRig.differing(newKnob.channels, newLane.channels) == 0,
                "a new song's knob at 0.4 must render like a lane at 0.4 through the store and engine")
        let oldKnob = try await PanLawRig.renderThroughStore(knob, newSong: false, label: "old-knob")
        #expect(oldKnob.storeLaw == .balance && oldKnob.engineLaw == .balance)
        #expect(await PanLawRig.differing(oldKnob.channels, newLane.channels) > 0,
                "control: an old song's knob keeps the original rule")
        #expect(await PanLawRig.differing(oldKnob.channels, newKnob.channels) > 0,
                "control: the store's rule reaches the bounce")
    }

    @Test("A song saved without the setting opens on the original rule and renders like a store on that rule")
    func savedSongOpensOnTheOriginalRule() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawpro-panlaw-saved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracks = try await PanLawRig.strip("stereo", knob: -0.4, lane: nil)
            + PanLawRig.strip("synth", knob: 1.0, lane: nil)
        let bundle = dir.appendingPathComponent("Saved Song.dawproj")
        try await PanLawRig.save(tracks, to: bundle)
        let text = try String(contentsOf: bundle.appendingPathComponent("project.json"), encoding: .utf8)
        #expect(!text.contains("panLaw"), "the fixture is a saved song: no pan-rule key")
        #expect(text.contains("\"pan\""), "control: the grep can see a key that IS there")
        let opened = try await PanLawRig.openAndRender(bundle: bundle, to: dir.appendingPathComponent("opened.wav"))
        #expect(opened.storeLaw == .balance, "decoded value: a saved song opens on the ORIGINAL rule")
        #expect(opened.engineLaw == .balance, "the engine must hear the original rule")
        let reopenedTracks = try ProjectBundle.read(from: bundle).runtimeState(bundleURL: bundle).tracks
        let original = try await PanLawRig.renderThroughStore(reopenedTracks, newSong: false, label: "original")
        let new = try await PanLawRig.renderThroughStore(reopenedTracks, newSong: true, label: "new")
        #expect(await PanLawRig.differing(opened.channels, original.channels) == 0,
                "a saved song must render exactly like the original rule")
        #expect(await PanLawRig.differing(opened.channels, new.channels) > 0,
                "control: the same tracks as a NEW song sound different")
    }

    @Test("Bounce twin: a new song's knob renders identically at offline blocks 64 / 441 / 2048 and the default")
    func newSongTwinAcrossBlockSizes() async throws {
        var failures: [String] = []
        for kind in ["stereo", "synth", "bus"] {
            let tracks = try await PanLawRig.strip(kind, knob: 0.4, lane: nil)
            let reference = try await PanLawRig.render(tracks, law: .equalPower)
            for n in [64, 441, 2_048] {
                let audio = try await PanLawRig.render(tracks, law: .equalPower, frames: n)
                let d = await PanLawRig.differing(audio.channelData, reference.channelData)
                print("[PANLAW] twin \(kind) N=\(n): differing samples = \(d)")
                if d != 0 { failures.append("\(kind)@N\(n)=\(d)") }
            }
        }
        #expect(failures.isEmpty, "the new rule depends on the block size: \(failures)")
    }

    @Test("The knob stage itself: 0 is a no-op, p is flat from the first quantum, a move glides, NaN is ignored")
    func knobStageUnit() async throws {
        try await MainActor.run {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256),
                  let data = buffer.floatChannelData else { throw PanLawRigError.setup("buffer") }
            buffer.frameLength = 256
            func fill() { for c in 0..<2 { for i in 0..<256 { data[c][i] = 0.5 } } }
            let renderer = AutomationRenderer()
            var stamp = AudioTimeStamp()
            func pass() { renderer.apply(bufferList: buffer.mutableAudioBufferList, frameCount: 256, timestamp: &stamp) }

            // The original rule only ever publishes 0: the audio is not touched (bit-exact).
            renderer.publishStaticPan(0)
            fill(); pass()
            #expect((0..<256).allSatisfy { data[0][$0] == 0.5 && data[1][$0] == 0.5 }, "0 must be a no-op")

            // NaN is ignored, and does not poison the next value.
            renderer.publishStaticPan(.nan)
            fill(); pass()
            #expect((0..<256).allSatisfy { data[0][$0] == 0.5 && data[1][$0] == 0.5 }, "NaN must leave audio alone")

            // A fresh stage: the first quantum at p is FLAT (exactly a constant lane's gains).
            let fresh = AutomationRenderer()
            func freshPass() { fresh.apply(bufferList: buffer.mutableAudioBufferList, frameCount: 256, timestamp: &stamp) }
            fresh.publishStaticPan(0.5)
            #expect(fresh.currentStaticPan == 0.5)
            fill(); freshPass()
            let theta = (0.5 + 1) * (Double.pi / 4)
            let gL = Float(2.0.squareRoot() * cos(theta)), gR = Float(2.0.squareRoot() * sin(theta))
            #expect((0..<256).allSatisfy { data[0][$0] == 0.5 * gL && data[1][$0] == 0.5 * gR },
                    "first quantum must be flat at the constant-lane gains")
            // A move to -0.5 glides across ONE quantum: starts at 0.5's gains, moves monotonically toward -0.5.
            fresh.publishStaticPan(-0.5)
            fill(); freshPass()
            #expect(data[0][0] == 0.5 * gL && data[1][0] == 0.5 * gR, "the glide starts where the knob was")
            #expect((1..<256).allSatisfy { data[0][$0] >= data[0][$0 - 1] && data[1][$0] <= data[1][$0 - 1] },
                    "the glide is monotonic")
            #expect(data[0][255] > data[0][0] && data[1][255] < data[1][0], "the glide moves")
            // Settled: the next quantum is flat at -0.5.
            fill(); freshPass()
            let theta2 = (-0.5 + 1) * (Double.pi / 4)
            #expect(data[0][0] == 0.5 * Float(2.0.squareRoot() * cos(theta2)) && data[0][0] == data[0][255])
            #expect((0..<256).allSatisfy { data[0][$0].isFinite && data[1][$0].isFinite })
        }
    }
}

// MARK: - Bounce == live (PANLAW_LIVE=1): the live graph, `.realtime` manual rendering, the CR12 G2 MAIN shape.

@MainActor
private enum PanLawLive {
    static let maximumFrames = 2_048

    /// The CR12 live roll (`ControlGridInvarianceTests`' `CR12Live.render`), with the song's pan rule set on the
    /// graph before its first parameter pass. Sleeps `paceMs` after every 100 ms of audio (a file player starves when
    /// the pull loop outruns its disk reader).
    static func render(_ tracks: [Track], law: PanLaw, pull: Int, frames total: Int,
                       paceMs: Int) async throws -> [[Float]] {
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        graph.panLaw = law
        guard let format = AVAudioFormat(standardFormatWithSampleRate: PanLawRig.sampleRate, channels: 2) else {
            throw PanLawRigError.setup("format")
        }
        try engine.enableManualRenderingMode(.realtime, format: format,
                                             maximumFrameCount: AVAudioFrameCount(maximumFrames))
        _ = engine.mainMixerNode
        _ = graph.reconcile(tracks: tracks)
        graph.applyParameters(tracks: tracks, playheadBeat: 0)
        try engine.start()
        graph.applyParameters(tracks: tracks, playheadBeat: 0)
        graph.scheduleAll(fromBeat: 0, tempoMap: PanLawRig.tempoMap)
        graph.startAllPlayers(at: nil)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maximumFrames)),
              let data = buffer.floatChannelData else { throw PanLawRigError.setup("pull buffer") }
        let render = engine.manualRenderingBlock
        var left: [Float] = []
        var right: [Float] = []
        var retries = 0
        var sincePace = 0
        while left.count < total {
            let frames = min(pull, total - left.count)
            buffer.frameLength = AVAudioFrameCount(frames)
            var error: OSStatus = noErr
            let status = render(AVAudioFrameCount(frames), buffer.mutableAudioBufferList, &error)
            if status == .cannotDoInCurrentContext, retries < 1_000 {
                retries += 1
                await Task.yield()
                continue
            }
            guard status == .success else {
                throw PanLawRigError.setup("manual render status \(status.rawValue) error \(error)")
            }
            left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: frames))
            sincePace += frames
            if paceMs > 0, sincePace >= Int(0.1 * PanLawRig.sampleRate) {
                sincePace = 0
                try await Task.sleep(for: .milliseconds(paceMs))
            }
        }
        graph.stopAllPlayers()
        engine.stop()
        return [left, right]
    }
}

@Suite("m39-panlaw-new: bounce == live for the new rule (PANLAW_LIVE=1)", .serialized)
struct PanLawLiveTests {
    /// Live samples that are exactly 0 where the bounce is not: the file-player starvation signature (CR12).
    static func starved(_ live: [[Float]], _ reference: [[Float]]) -> Int {
        var count = 0
        for (x, y) in zip(live, reference) {
            for i in 0..<min(x.count, y.count) where x[i] == 0 && y[i] != 0 { count += 1 }
        }
        return count
    }

    @Test("Live graph (.realtime, at: nil) at pulls 64/441/1024 equals the 512 bounce for a new song's knob",
          .enabled(if: ProcessInfo.processInfo.environment["PANLAW_LIVE"] == "1"))
    func liveEqualsBounce() async throws {
        let total = Int(PanLawRig.seconds * PanLawRig.sampleRate)
        let whole = (total / 512) * 512
        var failures: [String] = []
        for (kind, pace) in [("synth", 0), ("bus", 25), ("stereo", 25)] {
            let tracks = try await PanLawRig.strip(kind, knob: 0.4, lane: nil)
            let bounce = try await PanLawRig.render(tracks, law: .equalPower).channelData.map { Array($0.prefix(whole)) }
            for pull in [64, 441, 1_024] {
                let live = try await PanLawLive.render(tracks, law: .equalPower, pull: pull, frames: total, paceMs: pace)
                var d = await PanLawRig.differing(live.map { Array($0.prefix(whole)) }, bounce)
                var note = ""
                if d != 0, pace > 0 {
                    // The CR12 rule: a file player STARVES when the pull loop outruns its disk reader (exact zeros
                    // where the bounce is not). Report the signature, then re-render once at real time; only a
                    // difference that survives a fully paced render counts.
                    let starved = Self.starved(live.map { Array($0.prefix(whole)) }, bounce)
                    let again = try await PanLawLive.render(tracks, law: .equalPower, pull: pull, frames: total,
                                                            paceMs: 100)
                    let d2 = await PanLawRig.differing(again.map { Array($0.prefix(whole)) }, bounce)
                    note = " (first render: \(d) differing, \(starved) starved zeros; real-time re-render: \(d2))"
                    d = d2
                }
                print("[PANLAW] live \(kind) pull=\(pull): differing samples vs bounce = \(d)\(note)")
                if d != 0 { failures.append("\(kind)@\(pull)=\(d)") }
            }
            // CONTROL: the live graph on the ORIGINAL rule differs from the new-rule bounce (it reads the field).
            let old = try await PanLawLive.render(tracks, law: .balance, pull: 512, frames: total, paceMs: pace)
            let dOld = await PanLawRig.differing(old.map { Array($0.prefix(whole)) }, bounce)
            print("[PANLAW] live \(kind) ORIGINAL rule vs new-rule bounce: differing samples = \(dOld)")
            #expect(dOld > 0, "control: \(kind) — the live graph ignored the pan rule")
        }
        #expect(failures.isEmpty, "live != bounce: \(failures)")
    }
}
