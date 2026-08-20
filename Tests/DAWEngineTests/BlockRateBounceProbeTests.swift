import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m28-bug MEASUREMENT PROBE — not a gate, not product code.
//
// `measure-gm-sax-cc.md` §2.4 ends on an explicit, falsifiable PREDICTION:
// the 85.33 ms controller sample-and-hold on the hosted-AU path is OUR block
// size (`OfflineRenderer.maximumFrameCount` = 4096), so constructing
// `OfflineRenderer(maximumFrameCount: 512)` should move the null from
// 11.719 Hz to 93.75 Hz and take the alias images out of the vibrato band.
// That test was never run — the render block size is not reachable from the
// wire, which is why the JS harness could not do it.
//
// This probe RENDERS BOTH ARMS and writes WAVs the proven JS analysis library
// (`scripts/gates/_measure-dsp.mjs`) then re-analyses. It deliberately does
// NOT assert: the 4096 arm is a POSITIVE CONTROL that has to reproduce the
// doc's published figures (8 Hz → image at 3.719 Hz near 41.7 cents; 11.72 Hz
// → ~0 depth and a static ≈ −17.9 cent detune) before the 512 arm means
// anything at all. A hand-built probe's negative result is the weakest
// evidence there is.
//
// Disabled unless `DAWPRO_BLOCK_PROBE` is set: ~8 s of render per trial plus a
// GM bank load, far too slow for the standing suite.
//
//   DAWPRO_BLOCK_PROBE=1 DAWPRO_BLOCK_SIZES=4096,512 \
//     ./scripts/test.sh --filter BlockRateBounceProbe
// ⚠️ AN EXTENSION, NOT A NEW `@Suite` — `MainActorOccupancySiteTests` caps
// `@MainActor` suites at 330 and the tree sits exactly on it (m23-aw-4). The
// suite-level `.enabled(if:)` trait is therefore replaced by a per-test env
// guard, which is why every test below returns early without `DAWPRO_BLOCK_PROBE`.
extension SoundBankHostingTests {
    // Timing is COPIED from `_measure-gm-sax-cc.mjs` so the 4096 arm is
    // comparable to the published numbers rather than merely similar:
    // 120 BPM, note on at beat 2 (t = 1.0 s), 12 beats long (off at 7.0 s),
    // 8 s render, analysis window 2.0–5.5 s.
    private static let bpm = 120.0
    private static let beatSeconds = 60.0 / bpm
    private static let noteBeat = 2.0
    private static let noteLengthBeats = 12.0
    private static let renderSeconds = 8.0
    private static let noteOffSeconds = (noteBeat + noteLengthBeats) * beatSeconds

    /// ⚠️ NO SESSION-SPECIFIC DEFAULT. An earlier draft hardcoded the authoring
    /// session's scratchpad path, which is dead on arrival for every later run —
    /// the renders would land in a directory that no longer exists (or, worse,
    /// silently succeed into a stale one and be analysed as fresh).
    /// `SAXCC_SCRATCH` matches the name the JS harnesses already use.
    private static var scratch: String {
        ProcessInfo.processInfo.environment["SAXCC_SCRATCH"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("dawpro-blockprobe", isDirectory: true).path
    }

    private static var blockSizes: [Int] {
        (ProcessInfo.processInfo.environment["DAWPRO_BLOCK_SIZES"] ?? "4096,512")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static var rates: [Double] {
        (ProcessInfo.processInfo.environment["DAWPRO_BLOCK_RATES"] ?? "2.0,5.5,8.0,11.0,11.72")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// GM tenor sax. `findSaxProgram` in the JS harness picks the /tenor/i
    /// match out of the parsed bank listing, which is GM program 66
    /// (`GMProgramCatalog.swift:93`: 64 Soprano, 65 Alto, 66 Tenor). The doc's
    /// bend figures were taken on that program at pitch 62 (D4, 293.665 Hz).
    private static var saxProgram: Int {
        Int(ProcessInfo.processInfo.environment["DAWPRO_BLOCK_PROGRAM"] ?? "") ?? 66
    }

    private func probeSaxTrack(program: Int, clips: [Clip]) -> Track {
        Track(name: "Sax", kind: .instrument, clips: clips,
              instrument: InstrumentDescriptor(
                  kind: .soundBank,
                  soundBank: SoundBankConfig(source: .generalMIDI, program: program,
                                             bankMSB: 121)))
    }

    /// The JS bend lane, value-for-value: ±50 cents, one point every 8 ms,
    /// mapped cents → 14-bit bend as `8192 + (cents / 200) * 8192`. The ±200
    /// cent assumption is the harness's, and reproducing the published depth
    /// requires reproducing it rather than "fixing" it here.
    private func bendVibrato(rateHz: Double, depthCents: Double = 50) -> MIDIControllerLane {
        var points: [MIDIControllerPoint] = []
        var t = 0.0
        while t <= Self.noteOffSeconds {
            let cents = depthCents * sin(2 * .pi * rateHz * t)
            let raw = 8192.0 + (cents / 200.0) * 8192.0
            points.append(MIDIControllerPoint(beat: t / Self.beatSeconds,
                                              value: max(0, min(16383, Int(raw.rounded())))))
            t += 0.008
        }
        return MIDIControllerLane(type: .pitchBend, points: points)
    }

    /// CC 11 tremolo, the T5 shape (`SoundBankHostingTests`) — the P5 arm.
    private func probeExpressionSine(rateHz: Double, pointsPerSecond: Double = 200,
                                centre: Int = 84, amplitude: Double = 43)
        -> MIDIControllerLane {
        let count = Int((Self.noteOffSeconds * pointsPerSecond).rounded())
        let points = (0...count).map { i -> MIDIControllerPoint in
            let t = Double(i) / pointsPerSecond
            let value = Double(centre) + amplitude * sin(2 * .pi * rateHz * t)
            return MIDIControllerPoint(beat: t / Self.beatSeconds,
                                       value: Int(value.rounded()))
        }
        return MIDIControllerLane(type: .cc(controller: 11), points: points)
    }

    private func probeClip(lane: MIDIControllerLane, pitch: Int) -> Clip {
        Clip(name: "midi", startBeat: 0, lengthBeats: 16,
             notes: [MIDINote(pitch: pitch, velocity: 100,
                              startBeat: Self.noteBeat, lengthBeats: Self.noteLengthBeats)],
             controllerLanes: [lane])
    }

    /// One render at one block size, written to disk THE MOMENT it lands.
    private func renderTrial(tag: String, block: Int, track: Track) async throws {
        let dir = URL(fileURLWithPath: Self.scratch, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(tag).wav")
        let renderer = OfflineRenderer(maximumFrameCount: block)
        await renderer.prepareAudioUnits(tracks: [track])
        let status = renderer.auRegistry.status[track.id]
        let clock = ContinuousClock()
        var info: AudioFileInfo?
        let elapsed = try clock.measure {
            info = try renderer.renderToWAV(
                tracks: [track], tempoMap: TempoMap(constantBPM: Self.bpm),
                masterVolume: 1.0, fromBeat: 0,
                durationSeconds: Self.renderSeconds, to: url)
        }
        print("[probe] \(tag) block=\(block) status=\(String(describing: status)) "
            + "seconds=\(info?.durationSeconds ?? -1) render=\(elapsed)")
        #expect(status == .ready, "hosted sax must load, or the render is silence")
    }

    @Test("bend vibrato rendered at each block size (writes WAVs, asserts nothing)")
    func bendArm() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_BLOCK_PROBE"] != nil else { return }
        print("[probe] scratch=\(Self.scratch) program=\(Self.saxProgram)")
        for block in Self.blockSizes {
            for rate in Self.rates {
                let track = probeSaxTrack(program: Self.saxProgram,
                                     clips: [probeClip(lane: bendVibrato(rateHz: rate), pitch: 62)])
                try await renderTrial(tag: "blockfix-bend-\(block)-\(rate)Hz",
                                      block: block, track: track)
            }
        }
    }

    /// COST ARM. A real multi-track bounce, timed at each block size.
    ///
    /// ⚠️ `prepareAudioUnits` loads a GM bank per track and costs seconds; it
    /// would swamp an 8× block change completely. Only `render()` is inside the
    /// clock, and the AUs are prepared ONCE per block size outside it.
    @Test("bounce wall-clock at each block size (multi-track)")
    func costArm() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_BLOCK_COST"] != nil else { return }
        let seconds = Double(ProcessInfo.processInfo.environment["DAWPRO_COST_SECONDS"] ?? "")
            ?? 120.0
        let runs = Int(ProcessInfo.processInfo.environment["DAWPRO_COST_RUNS"] ?? "") ?? 3
        // Eight instrument strips across the GM map, each with a dense part and
        // a controller lane — bend lanes are the thing whose delivery cost the
        // block size changes, so a bounce without them would understate it.
        let programs = [0, 24, 33, 48, 56, 66, 73, 4]
        let beats = seconds / Self.beatSeconds
        let tracks: [Track] = programs.enumerated().map { index, program in
            var notes: [MIDINote] = []
            var beat = 0.0
            while beat < beats {
                notes.append(MIDINote(pitch: 48 + (index * 5 + Int(beat)) % 24,
                                      velocity: 100, startBeat: beat, lengthBeats: 0.45))
                beat += 0.5
            }
            var lane: [MIDIControllerPoint] = []
            var t = 0.0
            while t <= seconds {
                let cents = 50 * sin(2 * .pi * 5.5 * t)
                lane.append(MIDIControllerPoint(beat: t / Self.beatSeconds,
                                                value: Int((8192 + (cents / 200) * 8192).rounded())))
                t += 0.008
            }
            return Track(name: "T\(index)", kind: .instrument,
                         clips: [Clip(name: "c", startBeat: 0, lengthBeats: beats,
                                      notes: notes,
                                      controllerLanes: [MIDIControllerLane(type: .pitchBend,
                                                                           points: lane)])],
                         instrument: InstrumentDescriptor(
                            kind: .soundBank,
                            soundBank: SoundBankConfig(source: .generalMIDI, program: program,
                                                       bankMSB: 121)))
        }
        print("[cost] \(tracks.count) hosted tracks, \(seconds) s of audio, \(runs) runs per block")
        for block in Self.blockSizes {
            let renderer = OfflineRenderer(maximumFrameCount: block)
            await renderer.prepareAudioUnits(tracks: tracks)
            for track in tracks {
                #expect(renderer.auRegistry.status[track.id] == .ready)
            }
            var samples: [Double] = []
            for run in 0..<runs {
                let clock = ContinuousClock()
                let elapsed = try clock.measure {
                    _ = try renderer.render(tracks: tracks, tempoMap: TempoMap(constantBPM: Self.bpm),
                                            fromBeat: 0, durationSeconds: seconds)
                }
                let s = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) * 1e-18
                samples.append(s)
                print("[cost] block=\(block) run=\(run) render=\(String(format: "%.3f", s)) s "
                    + "(\(String(format: "%.1f", seconds / s))x realtime)")
            }
            let best = samples.min() ?? 0, worst = samples.max() ?? 0
            let mean = samples.reduce(0, +) / Double(samples.count)
            print("[cost] BLOCK \(block): mean \(String(format: "%.3f", mean)) s "
                + "[\(String(format: "%.3f", best)) … \(String(format: "%.3f", worst))]")
        }
    }

    @Test("CC 11 tremolo rendered at each block size (the P5 arm)")
    func expressionArm() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_BLOCK_CC"] != nil else { return }
        for block in Self.blockSizes {
            for rate in Self.rates {
                let track = probeSaxTrack(program: Self.saxProgram,
                                     clips: [probeClip(lane: probeExpressionSine(rateHz: rate), pitch: 69)])
                try await renderTrial(tag: "blockfix-cc11-\(block)-\(rate)Hz",
                                      block: block, track: track)
            }
        }
    }
}
