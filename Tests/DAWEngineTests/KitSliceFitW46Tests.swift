import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

// m39-w4-6 — THE FIT, kept as the record of where `DrumHitClassifier.Thresholds` came from.
// Design `docs/design/2026-10-07-loop-drum-depth.md` §9.2 + §10.3: "fitted once on the C3 and C4 corpora,
// then frozen". Env-gated (`W46_FIT=1`): it prints every feature `SliceTimbreAnalyzer` measures on
//   C3  the synthetic corpus (`KitSliceCorpus`, truth known), and
//   C4  our drum machine, all five factory kits, every voice, one hit per fresh render, at velocity 100,
//       each hit's slice cut at 0.25 s AND at 0.5 s (a loop's eighth and quarter at 120 BPM), and
//   GM  the Mac's General MIDI drum kit (bank 120) at the same eight notes, REPORTED ONLY.
// With `W46_FIT_OUT=<file>` every row is also written there (the console drops lines).
// Nonisolated suite; the renderer is reached through `@MainActor static` helpers (the W41 idiom).
@Suite("W8-W46 classifier fit (W46_FIT=1 only)")
struct KitSliceFitW46Tests {

    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["W46_FIT"] == "1"
    static let rate = 48_000.0
    static let bpm = 120.0
    /// Each hit lands at beat 0.5 (frame 12 000), never in the first block.
    static let onsetFrame = 12_000
    static let sliceSeconds = [0.25, 0.5]
    static let velocity = 100

    /// Each voice and the General MIDI note it answers in the `gm` layout (`DrumVoice.primaryNote(in: .gm)`
    /// is the source; hand-typed here so the fit does not lean on the code under test).
    static let gmNote: [(DrumVoice, Int)] = [(.kick, 36), (.snare, 38), (.closedHat, 42), (.openHat, 46),
                                             (.clap, 39), (.tom, 45), (.rim, 37), (.cymbal, 49)]

    static func record(_ line: String) {
        print("W46-FIT \(line)")
        guard let path = env["W46_FIT_OUT"] else { return }
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    static func row(_ corpus: String, _ name: String, _ seconds: Double, _ t: SliceTimbre) -> String {
        [corpus, name, String(format: "%.2f", seconds),
         String(format: "%.4f", t.lowEnergyShare), String(format: "%.4f", t.highEnergyShare),
         String(format: "%.0f", t.attackCentroidHz), String(format: "%.4f", t.decaySeconds),
         t.decayReachedFloor ? "reached" : "ringing", String(format: "%.3e", t.spectralFlatness),
         String(format: "%.3f", t.peak)].joined(separator: "\t")
    }

    @MainActor
    static func render(_ instrument: InstrumentDescriptor, note: Int) async throws -> [Float] {
        let track = Track(name: "W46 fit", kind: .instrument,
                          clips: [Clip(name: "fit", startBeat: 0, lengthBeats: 4, notes: [
                              MIDINote(pitch: note, velocity: velocity, startBeat: 0.5, lengthBeats: 0.25),
                          ])],
                          instrument: instrument)
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: [track])
        if instrument.kind == .soundBank {
            let status = renderer.auRegistry.status[track.id]
            try #require(status == .ready, "W46: the GM kit did not reach .ready: CANNOT TELL")
        }
        let audio = try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: bpm),
                                        fromBeat: 0, durationSeconds: 1.0)
        let left = audio.channelData[0]
        let right = audio.channelData.count > 1 ? audio.channelData[1] : left
        return zip(left, right).map { ($0 + $1) / 2 }
    }

    static func measure(_ mono: [Float], seconds: Double) -> SliceTimbre {
        let end = min(mono.count, onsetFrame + Int(seconds * rate))
        return mono.withUnsafeBufferPointer {
            SliceTimbreAnalyzer.timbre(of: UnsafeBufferPointer(rebasing: $0[onsetFrame..<end]), sampleRate: rate)
        }
    }

    @Test("W46 fit: print every feature on C3, C4 (five kits) and the GM kit", .enabled(if: enabled))
    func printTheFit() async throws {
        Self.record("corpus\tname\tslice\tlow\thigh\tcentroid\tdecay\tfloor\tflatness\tpeak")
        // C3
        let url = try KitSliceCorpus.write()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let slot = Int(KitSliceCorpus.slotSeconds * KitSliceCorpus.rate)
        let spans = (0..<KitSliceCorpus.slots).map { SliceFrameSpan(start: $0 * slot, end: ($0 + 1) * slot) }
        let c3 = try SliceTimbreAnalyzer.analyze(fileAt: url, frameRanges: spans)
        for (index, timbre) in c3.enumerated() {
            Self.record(Self.row("C3", ["kick", "snare", "closedHat", "openHat", "tone1k"][index],
                                 KitSliceCorpus.slotSeconds, timbre))
        }
        // C4
        for preset in DrumKitParams.presets {
            var kit = preset.params
            kit.noteLayout = .gm
            for (voice, note) in Self.gmNote {
                let mono = try await Self.render(InstrumentDescriptor(kind: .drumSynth, drumKit: kit), note: note)
                for seconds in Self.sliceSeconds {
                    Self.record(Self.row("C4-\(preset.name)", voice.rawValue, seconds,
                                         Self.measure(mono, seconds: seconds)))
                }
            }
        }
        // GM (reported only)
        let gm = GMProgramCatalog.standardDrumKit
        let bank = InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
            source: .generalMIDI, program: gm.program, bankMSB: gm.bankMSB))
        for (voice, note) in Self.gmNote {
            let mono = try await Self.render(bank, note: note)
            for seconds in Self.sliceSeconds {
                Self.record(Self.row("GM", voice.rawValue, seconds, Self.measure(mono, seconds: seconds)))
            }
        }
    }
}
