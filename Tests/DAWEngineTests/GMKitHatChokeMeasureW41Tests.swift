import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m39-w4-1 (W8-W41, 2026-10-07): DOES APPLE'S GENERAL MIDI KIT CHOKE ITS HATS?
//
// A MEASUREMENT, not a product test. It decides whether m39-w4-9 (a control-plane synthetic hat choke for GM kit
// tracks) gets built. Design: docs/design/2026-10-07-loop-drum-depth.md §6 and §9.2. Findings and the verdict:
// docs/research/2026-10-07-gm-kit-hat-choke.md. Bars pre-registered in the lane's PREDICTIONS.md before the first
// render.
//
// Subject: the Standard Drum Kit (gs_instruments.dls through AUSampler, `GMProgramCatalog.standardDrumKit`, bank MSB
// 120 program 0), rendered offline through the SAME `OfflineRenderer` path every hosted instrument uses.
// Control instrument: our drum machine with the General MIDI note layout, whose hats are KNOWN to choke (choke group 0,
// `DrumKit.swift`), so the same notes 46 / 42 / 44 / 36 drive both through the identical MIDI path.
//
// Method (the `DrumSynthTests` "Choke: a closed hat cuts a sounding open hat" isolation): render open hat + second
// hit, subtract the second-hit-only render, and compare what remains (the open hat as it sounds when the second hit
// lands) against the open hat alone, as an RMS ratio over [130 ms, 200 ms) after the open hat's onset. Measuring the
// mix directly is WRONG: the second hit itself still sounds in that window.
//
// Validity (asserted; a red means "cannot tell", never "does not choke"): superposition on the DLS path, a non-silent
// control, an unchanged before-window, the kick-slot negative control, the drum-machine positive control, the piano
// note-off control. Determinism is measured first, not asserted: a non-deterministic render switches to 5 repeats and
// reports the spread. The verdict itself is printed and written to `$W41_OUT/measure.json`, never asserted.
//
// MEASURED 2026-10-07: the GM kit CHOKES (46 -> 42 and 46 -> 44 leave exactly zero from ~10 ms after the closed hat;
// the bank puts 42/44/46 in DLS key group 1), and a note-off changes its open hat by only -102 dB.
//
// Env-gated (`W41_MEASURE=1`). Nonisolated suite (the `@MainActor` suite cap in `MainActorOccupancySiteTests`); the
// renderer is reached through `@MainActor static` helpers.

@Suite("W8-W41 GM kit hat choke measurement (W41_MEASURE=1 only)")
struct GMKitHatChokeMeasureW41Tests {

    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["W41_MEASURE"] == "1"

    // MARK: - Fixed harness constants (pre-registered)

    static let bpm = 120.0
    static let sampleRate = 48_000.0
    /// The open hat lands at beat 1 (frame 24 000, the `SoundBankHostingTests` T1 idiom), never in the first block.
    static let onsetBeat = 1.0
    static let onsetFrame = 24_000
    /// The second hit, 100 ms later (0.2 beat at 120 BPM): frame 28 800.
    static let secondHitBeat = 1.2
    static let renderSeconds = 4.0
    static let velocity = 100
    /// A 2 s open hat in (a), so a note-off can never confound the choke.
    static let longBeats = 4.0
    /// 50 ms, the short note of (b).
    static let shortBeats = 0.1
    /// A sixteenth at 120 BPM (125 ms): the choker's and the kick's own length.
    static let hitBeats = 0.25

    static let openHat = 46, closedHat = 42, pedalHat = 44, kick = 36, pianoC4 = 60

    enum Instrument: String, Sendable {
        case gmKit, gmPiano, drumMachine, drumMachineChokeFree
    }

    struct Hit: Sendable {
        let pitch: Int
        let beat: Double
        let lengthBeats: Double
    }

    static func descriptor(_ instrument: Instrument) -> InstrumentDescriptor {
        switch instrument {
        case .gmKit:
            let kit = GMProgramCatalog.standardDrumKit
            return InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
                source: .generalMIDI, program: kit.program, bankMSB: kit.bankMSB))
        case .gmPiano:
            return InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
                source: .generalMIDI, program: 0, bankMSB: GMProgramCatalog.melodicBankMSB))
        case .drumMachine:
            return InstrumentDescriptor(kind: .drumSynth, drumKit: DrumKitParams(noteLayout: .gm))
        case .drumMachineChokeFree:
            var kit = DrumKitParams(noteLayout: .gm)
            kit.openHat.chokeGroup = nil
            kit.closedHat.chokeGroup = nil
            return InstrumentDescriptor(kind: .drumSynth, drumKit: kit)
        }
    }

    /// One track, one clip at beat 0, a FRESH renderer per call: no AU voice state can carry from one render into
    /// the next. Sound-bank tracks must reach `.ready`, or the render is honest silence and nothing was measured.
    @MainActor
    static func render(_ instrument: Instrument, _ hits: [Hit]) async throws -> RenderedAudio {
        let notes = hits.map {
            MIDINote(pitch: $0.pitch, velocity: velocity, startBeat: $0.beat, lengthBeats: $0.lengthBeats)
        }
        let track = Track(name: "W41 \(instrument.rawValue)", kind: .instrument,
                          clips: [Clip(name: "w41", startBeat: 0, lengthBeats: 8, notes: notes)],
                          instrument: descriptor(instrument))
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: [track])
        if descriptor(instrument).kind == .soundBank {
            let status = renderer.auRegistry.status[track.id]
            try #require(status == .ready,
                         "W41: \(instrument.rawValue) did not reach .ready (\(String(describing: status))): CANNOT TELL")
        }
        return try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: bpm),
                                   fromBeat: 0, durationSeconds: renderSeconds)
    }

    // MARK: - Signal helpers (nonisolated)

    static func frame(ms: Double) -> Int { onsetFrame + Int((ms * sampleRate / 1000).rounded()) }
    static func window(_ fromMs: Double, _ toMs: Double) -> Range<Int> { frame(ms: fromMs)..<frame(ms: toMs) }
    static let measureWindow = window(130, 200)
    static let beforeWindow = window(80, 98)

    static func rms(_ x: [Float], _ range: Range<Int>) -> Double {
        var sum = 0.0
        for index in range { let v = Double(x[index]); sum += v * v }
        return (sum / Double(max(1, range.count))).squareRoot()
    }

    static func dB(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-30)) }
    static func minus(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { $0 - $1 } }

    /// Bit-for-bit equality, and (when not equal) how many samples differ and by how much.
    static func compare(_ a: [Float], _ b: [Float], in range: Range<Int>? = nil) -> (equal: Bool, differing: Int, worst: Double) {
        let r = range ?? 0..<min(a.count, b.count)
        var differing = 0, worst = 0.0
        for index in r where a[index].bitPattern != b[index].bitPattern {
            differing += 1
            worst = max(worst, abs(Double(a[index]) - Double(b[index])))
        }
        return (differing == 0 && a.count == b.count, differing, worst)
    }

    static func firstFrame(_ x: [Float], above threshold: Float = 1e-4) -> Int? {
        x.firstIndex { abs($0) > threshold }
    }

    /// The first frame where two renders differ in their bits, or nil if they never do.
    static func firstDifference(_ a: [Float], _ b: [Float]) -> Int? {
        zip(a.indices, zip(a, b)).first { $0.1.0.bitPattern != $0.1.1.bitPattern }?.0
    }

    /// The first frame of the offline render block that holds `frame` (`OfflineRenderer`'s default block).
    static func blockStart(_ frame: Int) -> Int {
        (frame / RenderBlockSize.offlineFrames) * RenderBlockSize.offlineFrames
    }

    /// `hop` ms windows from `fromMs` to `toMs`: dB of numerator over denominator in each hop.
    static func hopEnvelope(_ num: [Float], _ den: [Float], fromMs: Double, toMs: Double,
                            hop: Double = 10) -> [(ms: Double, db: Double)] {
        stride(from: fromMs, to: toMs, by: hop).map { ms in
            let w = window(ms, ms + hop)
            let n = rms(num, w), d = rms(den, w)
            // Both exactly silent is "no difference" (0 dB), not -600 dB: the first run read the drum machine's
            // two decayed-to-zero hats as a -600 dB hop at 1010 ms.
            if n == 0 && d == 0 { return (ms, 0) }
            return (ms, dB(n / max(d, 1e-30)))
        }
    }

    static func firstHop(_ env: [(ms: Double, db: Double)], atOrBelow db: Double) -> Double? {
        env.first { $0.db <= db }?.ms
    }

    static func f(_ x: Double) -> String { String(format: "%.2f", x) }
    static func f(_ x: Double?) -> String { x.map { String(format: "%.0f", $0) } ?? "none" }

    // MARK: - The isolation (a)

    struct Isolation {
        let label: String
        let mix: RenderedAudio
        let secondOnly: RenderedAudio
        let control: RenderedAudio
        let isolatedLeft: [Float]
        let isolatedRight: [Float]
        /// RMS(isolated) / RMS(control), [130, 200) ms, LEFT (the asserted channel).
        let ratioDb: Double
        let ratioDbRight: Double
        /// Same, [80, 98) ms: the second hit has not landed yet.
        let beforeDb: Double
        let controlRMS: Double
        /// RMS(isolated - control) / RMS(control) in the measure window: the superposition residual.
        let residualDb: Double
        let worstResidual: Double
        let envelope: [(ms: Double, db: Double)]
        /// The first frame where the isolated open hat stops matching the open hat alone: where the choke begins.
        let firstDifferenceFrame: Int?
        /// The last frame where the isolated open hat is not exactly zero.
        let lastNonZeroFrame: Int?
        /// 1 ms hops from 90 to 130 ms: how fast the choke fades.
        let fineEnvelope: [(ms: Double, db: Double)]
    }

    static func isolate(_ instrument: Instrument, second pitch: Int) async throws -> Isolation {
        let open = Hit(pitch: openHat, beat: onsetBeat, lengthBeats: longBeats)
        let second = Hit(pitch: pitch, beat: secondHitBeat, lengthBeats: hitBeats)
        let mix = try await render(instrument, [open, second])
        let secondOnly = try await render(instrument, [second])
        let control = try await render(instrument, [open])
        let isoL = minus(mix.channelData[0], secondOnly.channelData[0])
        let isoR = minus(mix.channelData[1], secondOnly.channelData[1])
        let ctlL = control.channelData[0], ctlR = control.channelData[1]
        let controlRMS = rms(ctlL, measureWindow)
        let residual = minus(isoL, ctlL)
        return Isolation(
            label: "\(instrument.rawValue) 46->\(pitch)", mix: mix, secondOnly: secondOnly, control: control,
            isolatedLeft: isoL, isolatedRight: isoR,
            ratioDb: dB(rms(isoL, measureWindow) / controlRMS),
            ratioDbRight: dB(rms(isoR, measureWindow) / rms(ctlR, measureWindow)),
            beforeDb: dB(rms(isoL, beforeWindow) / rms(ctlL, beforeWindow)),
            controlRMS: controlRMS,
            residualDb: dB(rms(residual, measureWindow) / controlRMS),
            worstResidual: residual.reduce(0) { max($0, abs(Double($1))) },
            envelope: hopEnvelope(isoL, ctlL, fromMs: 100, toMs: 1500),
            firstDifferenceFrame: firstDifference(isoL, ctlL),
            lastNonZeroFrame: isoL.lastIndex { $0 != 0 },
            fineEnvelope: hopEnvelope(isoL, ctlL, fromMs: 90, toMs: 130, hop: 1))
    }

    static func verdictA(_ ratioDb: Double) -> String {
        if ratioDb <= -40 { return "CHOKES (as hard as our drum machine)" }
        if ratioDb <= -6 { return "CHOKES PARTIALLY OR SLOWLY" }
        if abs(ratioDb) <= 0.5 { return "DOES NOT CHOKE" }
        return "CANNOT TELL (ambiguous)"
    }

    // MARK: - The note-off (b)

    /// The note-off of the short note lands here (t0 + 50 ms = frame 26 400).
    static let noteOffFrame = frame(ms: 50)

    /// A short note against a long one with the same onset, both rendered alone.
    struct NoteOff {
        /// RMS(short) / RMS(long), [130, 200) ms.
        let ratioDb: Double
        /// RMS(short - long) / RMS(long), [130, 200) ms: how big the note-off's effect is at all.
        let differenceDb: Double
        let firstDifferenceFrame: Int?
        /// The ORIGINAL pre-registered bar: identical for every frame before the note-off frame. MEASURED FALSE on the
        /// GM bank (2026-10-07): the AU acts from the start of the render block that holds the event.
        let identicalBeforeNoteOff: Bool
        /// The re-registered bar: identical before the start of the 512-frame block that holds the note-off.
        let identicalBeforeBlock: Bool
        let identicalAfter: Bool
        /// The largest |dB| of any 10 ms hop from 50 to 1500 ms.
        let maxAbsHopDb: Double
        let envelope: [(ms: Double, db: Double)]
    }

    static func noteOff(short: RenderedAudio, long: RenderedAudio) -> NoteOff {
        let s = short.channelData[0], l = long.channelData[0]
        let end = min(s.count, l.count)
        let envelope = hopEnvelope(s, l, fromMs: 50, toMs: 1500)
        return NoteOff(
            ratioDb: dB(rms(s, measureWindow) / rms(l, measureWindow)),
            differenceDb: dB(rms(minus(s, l), measureWindow) / rms(l, measureWindow)),
            firstDifferenceFrame: firstDifference(s, l),
            identicalBeforeNoteOff: compare(s, l, in: 0..<noteOffFrame).equal,
            identicalBeforeBlock: compare(s, l, in: 0..<blockStart(noteOffFrame)).equal,
            identicalAfter: compare(s, l, in: noteOffFrame..<end).differing == 0,
            maxAbsHopDb: envelope.map { abs($0.db) }.max() ?? 0,
            envelope: envelope)
    }

    /// The (b) rule. The "no audible effect" row was ADDED after the first run (2026-10-07) showed a case the
    /// pre-registered rule had no row for: bytes differ, level does not. Flagged as post hoc in the research doc.
    static func verdictB(_ b: NoteOff) -> String {
        if b.identicalAfter { return "NOTE-OFF IGNORED (renders byte-identical)" }
        if b.differenceDb <= -60 && b.maxAbsHopDb <= 0.5 {
            return "NOTE-OFF HAS NO AUDIBLE EFFECT (bytes differ; difference \(f(b.differenceDb)) dB below the note)"
        }
        if b.ratioDb <= -40 { return "NOTE-OFF CUTS" }
        return "NOTE-OFF RELEASES"
    }

    // MARK: - Output (float WAV + JSON)

    static func outputDirectory() throws -> URL {
        let url = env["W41_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("W41-gm-hat-choke", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Mono 32-bit float WAV (the `TestSignals.write` settings, one channel).
    static func writeWAV(_ samples: [Float], _ name: String, in dir: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: dir.appendingPathComponent("\(name).wav"), settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(samples.count)))
        let channel = try #require(buffer.floatChannelData)[0]
        for index in samples.indices { channel[index] = samples[index] }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    // MARK: - The measurement

    @Test("W41: the GM kit's hat choke, measured against our drum machine's known choke",
          .enabled(if: GMKitHatChokeMeasureW41Tests.enabled))
    func measureGMKitHatChoke() async throws {
        let out = try Self.outputDirectory()
        var json: [String: Any] = ["item": "m39-w4-1", "lane": "W8-W41",
                                   "bank": SoundBankLibrary.systemGMBankPath,
                                   "measureWindowMs": [130, 200], "beforeWindowMs": [80, 98],
                                   "onsetFrame": Self.onsetFrame, "velocity": Self.velocity]
        guard FileManager.default.fileExists(atPath: SoundBankLibrary.systemGMBankPath) else {
            Issue.record("W41: the system GM bank is absent: CANNOT TELL")
            return
        }

        // V1: determinism first. Two fresh renderers, the same (a) mix.
        let open = Hit(pitch: Self.openHat, beat: Self.onsetBeat, lengthBeats: Self.longBeats)
        let closed = Hit(pitch: Self.closedHat, beat: Self.secondHitBeat, lengthBeats: Self.hitBeats)
        let firstMix = try await Self.render(.gmKit, [open, closed])
        let secondMix = try await Self.render(.gmKit, [open, closed])
        #expect(firstMix.sampleRate == Self.sampleRate, "V0: render rate \(firstMix.sampleRate)")
        let det = Self.compare(firstMix.channelData[0], secondMix.channelData[0])
        let detR = Self.compare(firstMix.channelData[1], secondMix.channelData[1])
        let deterministic = det.equal && detR.equal
        print("[measured] W41 V1 determinism (GM 46+42 rendered twice): byte-equal L \(det.equal) R \(detR.equal), "
              + "differing samples \(det.differing), worst \(det.worst)")
        json["deterministic"] = deterministic

        // (a) on the subject, repeated if (and only if) the DLS render is not deterministic.
        let repeats = deterministic ? 1 : 5
        var gm42: [Isolation] = []
        for _ in 0..<repeats { gm42.append(try await Self.isolate(.gmKit, second: Self.closedHat)) }
        let gm44 = try await Self.isolate(.gmKit, second: Self.pedalHat)
        let gmNeg = try await Self.isolate(.gmKit, second: Self.kick)
        let a = gm42[0]
        let spread = gm42.map(\.ratioDb)

        // The control instrument (known choke) through the identical harness.
        let dm42 = try await Self.isolate(.drumMachine, second: Self.closedHat)
        let dm44 = try await Self.isolate(.drumMachine, second: Self.pedalHat)
        let dmNeg = try await Self.isolate(.drumMachine, second: Self.kick)
        let dmFree = try await Self.isolate(.drumMachineChokeFree, second: Self.closedHat)

        for entry in [a, gm44, gmNeg, dm42, dm44, dmNeg, dmFree] {
            let level = String(format: "%.5f", entry.controlRMS)
            let head = "[measured] W41 (a) \(entry.label): tail \(Self.f(entry.ratioDb)) dB "
            let mid = "(R \(Self.f(entry.ratioDbRight))), before \(Self.f(entry.beforeDb)) dB, control RMS \(level), "
            let tail = "superposition residual \(Self.f(entry.residualDb)) dB (worst sample \(entry.worstResidual))"
            print(head + mid + tail)
        }
        if repeats > 1 {
            print("[measured] W41 (a) GM 46->42 over \(repeats) runs: min \(Self.f(spread.min() ?? 0)) "
                  + "max \(Self.f(spread.max() ?? 0)) dB")
        }

        // V6: where each hit actually landed (the in-quantum offset claim, as a number).
        let onsets: [String: Int] = [
            "gm46": Self.firstFrame(a.control.channelData[0]) ?? -1,
            "gm42": Self.firstFrame(a.secondOnly.channelData[0]) ?? -1,
            "gm44": Self.firstFrame(gm44.secondOnly.channelData[0]) ?? -1,
            "gm36": Self.firstFrame(gmNeg.secondOnly.channelData[0]) ?? -1,
            "dm46": Self.firstFrame(dm42.control.channelData[0]) ?? -1,
            "dm42": Self.firstFrame(dm42.secondOnly.channelData[0]) ?? -1,
            "dm36": Self.firstFrame(dmNeg.secondOnly.channelData[0]) ?? -1,
        ]
        let onsetText = onsets.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("[measured] W41 V6 onset frames (first |x| > 1e-4): \(onsetText)")

        // Where and how fast each choke happens (D2, D3, D5 in the lane's PREDICTIONS addendum).
        let chokerBlock = Self.blockStart(Self.frame(ms: 100))
        for entry in [a, gm44, dm42, dm44] {
            let fine = entry.fineEnvelope
            let first = entry.firstDifferenceFrame.map { "\($0)" } ?? "none"
            let last = entry.lastNonZeroFrame.map { "\($0)" } ?? "none"
            let hops = "\(Self.f(Self.firstHop(fine, atOrBelow: -20)))/\(Self.f(Self.firstHop(fine, atOrBelow: -40)))/"
                + "\(Self.f(Self.firstHop(fine, atOrBelow: -60)))"
            print("[measured] W41 (a) \(entry.label) timing: first difference from the open hat alone at frame "
                  + "\(first) (choker block starts \(chokerBlock)), last non-zero frame \(last), first 1 ms hop "
                  + "<= -20/-40/-60 dB at \(hops) ms")
        }

        // (b): a 50 ms open hat against a 2 s one. The long one IS the (a) control (same note, same velocity).
        let shortHat = Hit(pitch: Self.openHat, beat: Self.onsetBeat, lengthBeats: Self.shortBeats)
        let gmShort = try await Self.render(.gmKit, [shortHat])
        let gmB = Self.noteOff(short: gmShort, long: a.control)
        let dmShort = try await Self.render(.drumMachine, [shortHat])
        let dmB = Self.noteOff(short: dmShort, long: dm42.control)
        let pianoShort = try await Self.render(.gmPiano, [Hit(pitch: Self.pianoC4, beat: Self.onsetBeat,
                                                              lengthBeats: Self.shortBeats)])
        let pianoLong = try await Self.render(.gmPiano, [Hit(pitch: Self.pianoC4, beat: Self.onsetBeat,
                                                             lengthBeats: Self.longBeats)])
        let pianoB = Self.noteOff(short: pianoShort, long: pianoLong)
        for (name, entry) in [("gmKit 46", gmB), ("drumMachine 46", dmB), ("gmPiano 60", pianoB)] {
            let hop20 = Self.f(Self.firstHop(entry.envelope, atOrBelow: -20))
            let hop40 = Self.f(Self.firstHop(entry.envelope, atOrBelow: -40))
            let hop60 = Self.f(Self.firstHop(entry.envelope, atOrBelow: -60))
            let first = entry.firstDifferenceFrame.map { "\($0)" } ?? "none"
            let head = "[measured] W41 (b) \(name) 50 ms vs 2 s: \(Self.f(entry.ratioDb)) dB in [130,200) ms, "
                + "difference signal \(Self.f(entry.differenceDb)) dB, max |hop| \(Self.f(entry.maxAbsHopDb)) dB; "
            let mid = "first difference at frame \(first) (note-off \(Self.noteOffFrame), its block starts "
                + "\(Self.blockStart(Self.noteOffFrame))); identical before note-off \(entry.identicalBeforeNoteOff), "
                + "before its block \(entry.identicalBeforeBlock), after \(entry.identicalAfter); "
            let tail = "first hop <= -20/-40/-60 dB at \(hop20)/\(hop40)/\(hop60) ms"
            print(head + mid + tail)
        }

        // The control's own decay, so the window can be read: absolute dBFS per 100 ms of the GM open hat alone.
        let controlDecay = stride(from: 0.0, to: 1500, by: 100).map { ms in
            Self.dB(Self.rms(a.control.channelData[0], Self.window(ms, ms + 100)))
        }
        print("[measured] W41 GM open hat alone, dBFS per 100 ms from onset: "
              + controlDecay.map { Self.f($0) }.joined(separator: " "))
        let dmDecay = stride(from: 0.0, to: 500, by: 50).map { ms in
            Self.dB(Self.rms(dm42.control.channelData[0], Self.window(ms, ms + 50)))
        }
        print("[measured] W41 drum machine open hat alone, dBFS per 50 ms from onset: "
              + dmDecay.map { Self.f($0) }.joined(separator: " "))

        // ── Validity (a red here is CANNOT TELL, never "does not choke") ──
        #expect(a.controlRMS >= 0.005, "V3: the GM control open hat is too quiet in the window: \(a.controlRMS)")
        #expect(abs(a.beforeDb) <= 0.5, "V4: GM isolated before-window \(a.beforeDb) dB")
        #expect(gmNeg.residualDb <= -60, "V2: GM superposition residual \(gmNeg.residualDb) dB")
        #expect(abs(gmNeg.ratioDb) <= 0.5, "V5: GM negative control (kick slot) \(gmNeg.ratioDb) dB")
        #expect(dm42.ratioDb <= -40, "P+: drum machine 46->42 tail only \(dm42.ratioDb) dB")
        #expect(dm44.ratioDb <= -40, "P+: drum machine 46->44 tail only \(dm44.ratioDb) dB")
        #expect(abs(dm42.beforeDb) <= 0.5, "P+b: drum machine before-window \(dm42.beforeDb) dB")
        #expect(abs(dmNeg.ratioDb) <= 0.5, "N-: drum machine negative control \(dmNeg.ratioDb) dB")
        #expect(abs(dmFree.ratioDb) <= 0.5, "NF: choke-free drum machine 46->42 \(dmFree.ratioDb) dB")
        #expect(dmB.identicalBeforeNoteOff && dmB.identicalAfter, "B0: drum machine short and long hats differ")
        // B+/BI were pre-registered as "identical before the note-off FRAME"; the first run measured that FALSE on
        // the GM bank (the AU acts from the start of the block holding the event). Re-registered at the block start;
        // the original reading is still printed above and recorded in measure.json.
        #expect(pianoB.identicalBeforeBlock, "B+: GM piano renders differ BEFORE the note-off's block")
        #expect(pianoB.ratioDb <= -3, "B+: GM piano note-off moved the tail only \(pianoB.ratioDb) dB")
        #expect(gmB.identicalBeforeBlock, "BI: GM kit renders differ BEFORE the note-off's block")

        // ── The verdict (printed, recorded, never asserted) ──
        let valid = a.controlRMS >= 0.005 && abs(a.beforeDb) <= 0.5 && gmNeg.residualDb <= -60
            && abs(gmNeg.ratioDb) <= 0.5 && dm42.ratioDb <= -40 && abs(dmNeg.ratioDb) <= 0.5
        let verdictA = valid ? Self.verdictA(a.ratioDb) : "CANNOT TELL (a validity check failed)"
        let verdictA44 = valid ? Self.verdictA(gm44.ratioDb) : "CANNOT TELL (a validity check failed)"
        let verdictB = pianoB.identicalBeforeBlock && pianoB.ratioDb <= -3 && gmB.identicalBeforeBlock
            ? Self.verdictB(gmB)
            : "CANNOT TELL (a note-off control failed)"
        print("[measured] W41 VERDICT (a) 46->42: \(verdictA) | 46->44: \(verdictA44) | (b): \(verdictB)")

        func row(_ i: Isolation) -> [String: Any] {
            ["tailDb": i.ratioDb, "tailDbRight": i.ratioDbRight, "beforeDb": i.beforeDb, "controlRMS": i.controlRMS,
             "residualDb": i.residualDb, "worstResidual": i.worstResidual,
             "firstDifferenceFrame": i.firstDifferenceFrame ?? -1, "lastNonZeroFrame": i.lastNonZeroFrame ?? -1,
             "envelope1ms90to130": i.fineEnvelope.map { [$0.ms, $0.db] },
             "envelope10ms": i.envelope.map { [$0.ms, $0.db] }]
        }
        func rowB(_ b: NoteOff) -> [String: Any] {
            ["tailDb": b.ratioDb, "differenceDb": b.differenceDb, "maxAbsHopDb": b.maxAbsHopDb,
             "firstDifferenceFrame": b.firstDifferenceFrame ?? -1,
             "identicalBeforeNoteOffFrame": b.identicalBeforeNoteOff, "identicalBeforeNoteOffBlock": b.identicalBeforeBlock,
             "identicalAfterNoteOff": b.identicalAfter,
             "firstHopMs": ["-20": Self.firstHop(b.envelope, atOrBelow: -20) ?? -1,
                            "-40": Self.firstHop(b.envelope, atOrBelow: -40) ?? -1,
                            "-60": Self.firstHop(b.envelope, atOrBelow: -60) ?? -1],
             "envelope10ms": b.envelope.map { [$0.ms, $0.db] }]
        }
        let aRows: [String: Any] = [
            "gm46to42": row(a), "gm46to44": row(gm44), "gmKickSlot": row(gmNeg),
            "dm46to42": row(dm42), "dm46to44": row(dm44), "dmKickSlot": row(dmNeg),
            "dmChokeFree46to42": row(dmFree), "gm46to42RunsDb": spread]
        let bRows: [String: Any] = ["gmKit46": rowB(gmB), "drumMachine46": rowB(dmB), "gmPiano60": rowB(pianoB)]
        let determinism: [String: Any] = ["byteEqual": deterministic, "differingSamplesL": det.differing,
                                          "worstL": det.worst]
        let verdict: [String: Any] = ["a46to42": verdictA, "a46to44": verdictA44, "b": verdictB, "valid": valid]
        json["a"] = aRows
        json["b"] = bRows
        json["onsetFrames"] = onsets
        json["gmControlDbfsPer100ms"] = controlDecay
        json["dmControlDbfsPer50ms"] = dmDecay
        json["blocks"] = ["offlineFrames": RenderBlockSize.offlineFrames, "noteOffFrame": Self.noteOffFrame,
                          "noteOffBlockStart": Self.blockStart(Self.noteOffFrame), "chokerFrame": Self.frame(ms: 100),
                          "chokerBlockStart": chokerBlock]
        json["determinism"] = determinism
        json["verdict"] = verdict
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("measure.json"))

        // The renders behind the headline numbers, for a second instrument (ffmpeg) and for ears.
        try Self.writeWAV(a.mix.channelData[0], "gm-46-42-mix-L", in: out)
        try Self.writeWAV(a.secondOnly.channelData[0], "gm-42-only-L", in: out)
        try Self.writeWAV(a.control.channelData[0], "gm-46-only-L", in: out)
        try Self.writeWAV(a.isolatedLeft, "gm-46-42-isolated-L", in: out)
        try Self.writeWAV(gmShort.channelData[0], "gm-46-short-L", in: out)
        try Self.writeWAV(dm42.isolatedLeft, "dm-46-42-isolated-L", in: out)
        try Self.writeWAV(dm42.control.channelData[0], "dm-46-only-L", in: out)
        print("[measured] W41 wrote measure.json and 7 float WAVs to \(out.path)")
    }
}
