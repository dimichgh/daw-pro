import AVFAudio
import CryptoKit
import DAWCore
import Foundation
@testable import DAWEngine

/// The ONE forward-playback reference render shared by M32's two new zone
/// fields — m32-d (`reverse`) and m32-f (`chokeGroup`).
///
/// ⭐⭐ WHY IT IS SHARED RATHER THAN DUPLICATED. Both items make the SAME
/// promise: *a project that does not use the new field renders byte-for-byte
/// as it did before the field existed.* One render, one digest, pinned in both
/// suites, means the two items cannot drift into disagreeing about what
/// "unchanged" means — and the digest below was harvested from the engine
/// BEFORE either item was written, so it is a genuine before/after pin rather
/// than a value read back out of the code it is supposed to constrain.
///
/// ⭐ WHAT THE RENDER DELIBERATELY CONTAINS, because a plain one-shot voice
/// would prove almost nothing:
///  · a CONTINUOUS-LOOP voice — the loop branch is where the position math is
///    hairiest (wrap, seam interpolation, crossfade), and m32-d rewrites how a
///    read position is derived;
///  · a BENT voice — `applyBendFactor` rewrites `increment` on every sounding
///    voice mid-note, so a direction scalar that folded the direction into the
///    increment instead of the position would break HERE and nowhere else;
///  · OVERLAPPING notes across two zones — without an overlap no choke could
///    ever fire, and m32-f's positive control (set `chokeGroup` → the digest
///    MUST change) would be unfalsifiable.
///
/// ⭐ Fixture is STEREO. m32-h: a single `AVAudioFile.read(into:)` short-reads
/// every MONO file whose frame count is not a multiple of 1024 (measured:
/// 22 050 → 21 504), and `SamplerInstrument.init` issues exactly one read. A
/// stereo fixture reads fully at every length, so this measures reverse/choke
/// and nothing else. The frame count is 1024-aligned as well, belt and braces.
///
/// No `@Suite` here on purpose — a fixture is not a suite. (The tree's
/// `@MainActor`-isolated suite census, `MainActorOccupancySiteTests` Leg C,
/// sits at 344 against a 349 cadence cap; the two m32 suites that use this
/// file are deliberately NOT `@MainActor`, so they cost that census nothing.)
enum SamplerM32Identity {
    // MARK: - Geometry

    /// Graph rate. The fixture is written at this rate too, so a zone played at
    /// its own `rootPitch` advances exactly 1.0 source frame per output frame —
    /// which is what makes m32-d's mirror gate sample-EXACT rather than
    /// approximately mirrored.
    static let graphRate = 48_000.0
    /// 8192 = 8 × 1024 (see the m32-h note above).
    static let fixtureFrames = 8_192
    /// 24 576 output frames = 0.512 s at 48 kHz.
    static let renderFrames = 24_576
    /// Fixed so zone selection (one xorshift draw per note-on) is deterministic.
    static let randomSeed: UInt64 = 0x4D33_3244_4D33_3246

    // MARK: - The pinned digest

    /// SHA256 over the raw IEEE bit patterns of the reference render, left
    /// channel then right.
    ///
    /// ⚠️ HARVESTED 2026-08-29 FROM THE ENGINE AS IT STOOD BEFORE m32-d, and
    /// re-asserted unchanged after m32-d and after m32-f. If this reddens, a
    /// project that uses NEITHER new field started rendering differently, which
    /// is the one thing both items promised not to do. Do not update it to make
    /// a run go green — find what moved.
    static let goldenDigest =
        "dbba562786fc6a5a5cacd633ac9426ac6e88a7157f86bae97822b1f93c6b8902"

    // MARK: - Fixture

    /// Stereo 48 kHz float WAV, L 440 Hz / R 660 Hz at different levels and a
    /// phase offset, so a channel mix-up cannot hide inside a digest.
    static func writeFixture(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: graphRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: graphRate,
                                         channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(fixtureFrames)),
              let data = buffer.floatChannelData else {
            throw SamplerM32FixtureError.bufferAllocationFailed
        }
        for frame in 0..<fixtureFrames {
            let t = Double(frame) / graphRate
            data[0][frame] = Float(0.50 * sin(2.0 * .pi * 440.0 * t))
            data[1][frame] = Float(0.35 * sin(2.0 * .pi * 660.0 * t + 0.7))
        }
        buffer.frameLength = AVAudioFrameCount(fixtureFrames)
        try file.write(from: buffer)
    }

    /// A temp directory holding the stereo fixture, created once per process.
    static func fixtureURL() throws -> URL {
        try cachedFixture.get()
    }

    /// ⚠️ THE ONE CACHE HERE THAT IS GENUINELY CROSS-SUITE. `SamplerReverseZoneTests`
    /// and `SamplerChokeGroupTests` are separate suites and each runs in
    /// parallel with the other, so a check-then-fill `var` would let both see
    /// nil and both write. A global `let` is initialised under `swift_once`, so
    /// the write happens exactly once no matter how many threads arrive. The
    /// earlier shape was safe only while both callers lived in one `@MainActor
    /// .serialized` suite — the property they gave up to stop starving the AU
    /// prepare timings (see SamplerReverseZoneTests.swift).
    private static let cachedFixture: Result<URL, any Error> = {
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("daw-pro-m32-identity-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("m32_identity_stereo_48k.wav")
            try writeFixture(to: url)
            return .success(url)
        } catch {
            return .failure(error)
        }
    }()

    // MARK: - The reference project

    /// Two zones on ONE file (so this also rides m32-a's dedup): zone 0 loops
    /// continuously, zone 1 is a plain panned voice.
    ///
    /// ⚠️ `chokeGroup` is the ONLY thing the m32-f positive control varies. It
    /// defaults to nil, which is the reference render — passing a value here
    /// MUST change the digest, and if it ever stops doing so the byte-identity
    /// test that shares this fixture has gone blind.
    static func zones(url: URL, chokeGroup: Int? = nil) -> [SamplerZone] {
        [
            SamplerZone(audioFileURL: url, rootPitch: 60, minPitch: 60, maxPitch: 60,
                        gain: 0.9, tuneCents: nil, pan: nil,
                        loopMode: .continuous, loopStart: 1_024, loopEnd: 5_120,
                        chokeGroup: chokeGroup),
            SamplerZone(audioFileURL: url, rootPitch: 64, minPitch: 64, maxPitch: 64,
                        gain: 0.7, group: 1, pan: 0.4,
                        attack: 0.002, release: 0.05,
                        chokeGroup: chokeGroup),
        ]
    }

    static func params(url: URL, chokeGroup: Int? = nil) -> SamplerParams {
        SamplerParams(zones: zones(url: url, chokeGroup: chokeGroup),
                      oneShot: false, attack: 0.004, release: 0.06, gain: 0.8)
    }

    /// Two overlapping voices, a bend up and back while both sound, then a
    /// second overlapping pair. Every note-on at 64 lands while a 60 is still
    /// sounding, which is what makes a choke observable.
    static func events() -> [ScheduledMIDIEvent] {
        var events: [ScheduledMIDIEvent] = []
        events += note(on: 0, off: 17_000, pitch: 60, id: 1)
        events += note(on: 5_000, off: 13_000, pitch: 64, id: 2)
        events.append(bend(at: 7_000, raw: 12_000))
        events.append(bend(at: 15_000, raw: 8_192))
        events += note(on: 18_000, off: 22_000, pitch: 64, id: 3)
        events += note(on: 20_000, off: 24_000, pitch: 60, id: 4)
        return events
    }

    static func note(on: Int64, off: Int64, pitch: UInt8,
                     velocity: UInt8 = 127, id: UInt64) -> [ScheduledMIDIEvent] {
        [ScheduledMIDIEvent(sampleTime: on, noteID: id,
                            kind: ScheduledMIDIEvent.noteOn, pitch: pitch, velocity: velocity),
         ScheduledMIDIEvent(sampleTime: off, noteID: id,
                            kind: ScheduledMIDIEvent.noteOff, pitch: pitch, velocity: 0)]
    }

    static func bend(at sampleTime: Int64, raw: Int) -> ScheduledMIDIEvent {
        ScheduledMIDIEvent(sampleTime: sampleTime, noteID: 0,
                           kind: ScheduledMIDIEvent.pitchBend,
                           pitch: UInt8(raw & 0x7F), velocity: UInt8((raw >> 7) & 0x7F))
    }

    // MARK: - Render + digest

    /// The reference render, start to finish. Deterministic by construction:
    /// fixed seed, fixed events, fixed 512-frame quanta.
    static func render(chokeGroup: Int? = nil) throws -> (left: [Float], right: [Float]) {
        let url = try fixtureURL()
        let instrument = SamplerInstrument(params: params(url: url, chokeGroup: chokeGroup),
                                           sampleRate: graphRate, randomSeed: randomSeed)
        instrument.prepare(sampleRate: graphRate, maxFramesPerQuantum: 512, channelCount: 2)
        return try renderQuanta(instrument, events: events(), frames: renderFrames)
    }

    /// Renders directly in 512-frame quanta, replicating `InstrumentRenderer`'s
    /// slicing (the `SamplerTests.renderDirect` contract, re-stated because
    /// that one is `private` to its own file).
    static func renderQuanta(_ instrument: SamplerInstrument,
                             events unsorted: [ScheduledMIDIEvent],
                             frames totalFrames: Int,
                             quantum: Int = 512) throws -> (left: [Float], right: [Float]) {
        let events = unsorted.sorted { a, b in
            if a.sampleTime != b.sampleTime { return a.sampleTime < b.sampleTime }
            let rankA = a.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            let rankB = b.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            if rankA != rankB { return rankA < rankB }
            return a.noteID < b.noteID
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: graphRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(quantum)),
              let channels = buffer.floatChannelData else {
            throw SamplerM32FixtureError.bufferAllocationFailed
        }
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(totalFrames)
        right.reserveCapacity(totalFrames)
        var cursor = 0
        var rendered = 0
        while rendered < totalFrames {
            let frames = min(quantum, totalFrames - rendered)
            buffer.frameLength = AVAudioFrameCount(frames)
            var end = cursor
            while end < events.count, events[end].sampleTime < Int64(rendered + frames) {
                end += 1
            }
            let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            events.withUnsafeBufferPointer { all in
                let slice = UnsafeBufferPointer(rebasing: all[cursor..<end])
                instrument.render(events: slice, renderStart: Int64(rendered),
                                  frameCount: frames, output: output)
            }
            cursor = end
            left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
            right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: frames))
            rendered += frames
        }
        return (left, right)
    }

    /// SHA256 over raw IEEE BIT PATTERNS, left then right. Bit patterns rather
    /// than values because `==` on Float calls 0.0 and −0.0 equal and says
    /// nothing at all about NaN, and BYTE identity is the claim being made.
    static func digest(_ left: [Float], _ right: [Float]) -> String {
        var hasher = SHA256()
        for channel in [left, right] {
            for sample in channel {
                var bits = sample.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { hasher.update(data: Data($0)) }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum SamplerM32FixtureError: Error {
    case bufferAllocationFailed
}
