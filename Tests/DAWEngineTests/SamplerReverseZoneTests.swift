import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m32-d — REVERSE ZONES. `SamplerZone.reverse` plays a zone's span backwards
// by READ-BACKWARDS INDEX MATH: a per-voice direction scalar, `readBase +
// readDir × local`. No reversed buffer is ever materialised — that would cost a
// second full-file allocation per reversed zone and undo m32-a on exactly the
// workflow (chopping one long record into many zones) that needs it most.
//
// ⚠️⚠️ ITS OWN SUITE, AND DELIBERATELY **NOT** `@MainActor` — MEASURED, not
// stylistic. These tests first shipped as an `extension SamplerTests` (which is
// `@MainActor .serialized`), and in that shape they reddened a test in a
// DIFFERENT suite: `AUPrepareRenegotiationStressTests`'s m23-as-2
// discriminator, whose control leg measures a clean `AUHostRegistry.prepare`
// against a 1.0 s budget. Three configurations, one full suite run each:
//
//   these tests absent   → AU control min 0.0438 s, suite GREEN
//   as `SamplerTests`    → AU control min 3.2067 s, suite RED (2 of 2 runs)
//   this file --filter'd → AU control min 0.0024 s, GREEN
//
// The channel is the MAIN ACTOR, which is one serialization point for the whole
// test process: `prepare` is `@MainActor`, so its wall time includes the queue
// wait behind every `@MainActor` test body doing CPU work. Hosting 18 offline
// renders inside a `@MainActor` suite extended `Sampler instrument` from 257 s
// to 319 s and pushed the AU suite's tail from a quiet window into a loaded
// one. Nothing here needs the main actor (no test in this file calls
// `SamplerInstrument.apply(params:)`, its only `@MainActor` member), so the
// fix is to stop asking for it — which is also `m23-aw-1`, the resting place
// that file's own fence comment names.
//
// ⛔ DO NOT "TIDY" THIS BACK INTO `SamplerTests`, and do not add `@MainActor`.
// Either one re-creates a cross-suite failure that looks like an AU-hosting
// regression and is not one.
//
// `.serialized` because the file-local fixture cache and the shared
// `SamplerM32Identity` render are process-wide; a non-`@MainActor` suite still
// runs in PARALLEL with every other suite, which is the whole point — the main
// actor stays free. Leg C's `@MainActor` census is unmoved at 344/349.
//
// Helpers are file-local free functions (a different file cannot see another's
// `private` ones); the cross-item reference render lives in
// `SamplerM32Identity`.
//
// ⭐ EVERY GATE HERE MEASURES RENDERED AUDIO. Nothing asserts on a zone flag or
// on a voice field: a test that reads the direction scalar back cannot tell you
// the direction reached the sound.

// MARK: - File-local harness

/// 4096 = 4 × 1024 frames of a strictly ASYMMETRIC ramp, written at the GRAPH
/// rate so a note at `rootPitch` advances exactly 1.0 source frame per output
/// frame and the mirror below is sample-EXACT rather than approximately
/// mirrored.
///
/// ⭐ STEREO, and the two channels carry DIFFERENT ramps (rising left, falling
/// right). Two reasons, both load-bearing: a channel mix-up cannot hide, and
/// m32-h — a single `AVAudioFile.read(into:)` short-reads every MONO file whose
/// frame count is not a multiple of 1024 (measured 22 050 → 21 504), while
/// stereo reads fully at every length. The frame count is 1024-aligned too, so
/// this fixture measures reversal and nothing else.
private let rampFrames = 4_096

private func writeRampFixture(to url: URL, rate: Double) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                     channels: 2, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(rampFrames)),
          let data = buffer.floatChannelData else {
        throw SamplerM32FixtureError.bufferAllocationFailed
    }
    for frame in 0..<rampFrames {
        // Left: 0 → +0.8 linearly. Right: +0.6 → −0.6 linearly. Both are exact
        // affine functions of the frame index, which is what lets the
        // half-rate test below assert INTERPOLATED values analytically.
        data[0][frame] = Float(0.8 * Double(frame) / Double(rampFrames - 1))
        data[1][frame] = Float(0.6 - 1.2 * Double(frame) / Double(rampFrames - 1))
    }
    buffer.frameLength = AVAudioFrameCount(rampFrames)
    try file.write(from: buffer)
}

/// The ramp fixture, written ONCE per process.
///
/// A `let` with a lazy initialiser, not a `nonisolated(unsafe) var` checked and
/// filled on first use: Swift initialises a global `let` under `swift_once`, so
/// this is correct even though the suite is no longer `@MainActor` and could in
/// principle be entered from two threads. The old check-then-fill shape was
/// safe only because `SamplerTests` serialised everything on the main actor —
/// exactly the property this file gave up. `Result` rather than a `try!` so a
/// fixture-write failure surfaces as a test failure with its real error
/// instead of a crash that takes the whole run with it.
private let cachedRampFixture: Result<URL, any Error> = {
    do {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m32d-reverse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ramp_48k_stereo_4096.wav")
        try writeRampFixture(to: url, rate: SamplerM32Identity.graphRate)
        return .success(url)
    } catch {
        return .failure(error)
    }
}()

private func rampFixture() throws -> URL {
    try cachedRampFixture.get()
}

/// One zone, one note held from frame 0, rendered at unity everywhere: params
/// gain 1, zone gain 1, velocity 127, no pan (nil = exact 1.0/1.0), zone
/// `attack: 0` (a one-frame rise, so `level` is exactly 1 from the first
/// rendered frame) and `oneShot` so no note-off ever starts a release ramp.
/// Under those settings the rendered sample IS the source sample, which is what
/// makes the assertions below exact rather than approximate.
private func renderOneZone(_ zone: SamplerZone, pitch: UInt8 = 60,
                           frames: Int = 6_144)
    throws -> (left: [Float], right: [Float], notes: [String]) {
    let params = SamplerParams(zones: [zone], oneShot: true,
                               attack: 0.001, release: 0.05, gain: 1.0)
    let instrument = SamplerInstrument(params: params,
                                       sampleRate: SamplerM32Identity.graphRate,
                                       randomSeed: 0x6D33_3264)
    instrument.prepare(sampleRate: SamplerM32Identity.graphRate,
                       maxFramesPerQuantum: 512, channelCount: 2)
    let events = SamplerM32Identity.note(on: 0, off: Int64(frames) + 1_000,
                                         pitch: pitch, id: 1)
    let rendered = try SamplerM32Identity.renderQuanta(instrument, events: events, frames: frames)
    return (rendered.left, rendered.right, instrument.zoneLoadNotes)
}

/// The fixture's left channel as the engine will see it: Float32, exactly the
/// values `writeRampFixture` wrote.
private func rampLeft(_ frame: Int) -> Float {
    Float(0.8 * Double(frame) / Double(rampFrames - 1))
}

private func rampRight(_ frame: Int) -> Float {
    Float(0.6 - 1.2 * Double(frame) / Double(rampFrames - 1))
}

@Suite("Sampler reverse zones (m32-d)", .serialized)
struct SamplerReverseZoneTests {
    // MARK: - Gate (a): the sample-EXACT mirror

    /// ⭐⭐ THE GATE m32-d EXISTS FOR. An asymmetric ramp rendered through a
    /// reversed zone at `rootPitch` must equal the forward render REVERSED,
    /// sample for sample — not "sounds backwards", not "roughly mirrored".
    /// A "sounds backwards" test passes with an off-by-one read, with a
    /// dropped first or last frame, and with several inverted-index bugs; this
    /// one does not.
    ///
    /// Fixture rate == graph rate and the note is at `rootPitch`, so the
    /// increment is exactly 1.0 and every read lands on an integer frame.
    ///
    /// Two controls: the FORWARD render is independently checked against the
    /// source ramp (so "mirror of the forward render" cannot be satisfied by
    /// two equally-broken renders), and forward ≠ reversed (so a `reverse` flag
    /// that did nothing at all cannot pass).
    @Test("m32-d GATE: a reversed zone is the sample-EXACT mirror of the forward render")
    func reversedZoneMirrorsForwardSampleExactly() throws {
        let url = try rampFixture()
        let forward = try renderOneZone(
            SamplerZone(audioFileURL: url, rootPitch: 60, minPitch: 60, maxPitch: 60,
                        gain: 1, attack: 0))
        let reversed = try renderOneZone(
            SamplerZone(audioFileURL: url, rootPitch: 60, minPitch: 60, maxPitch: 60,
                        gain: 1, attack: 0, reverse: true))

        // Control 1: the forward render IS the source, frame for frame.
        var forwardMatches = 0
        for frame in 0..<rampFrames where forward.left[frame] == rampLeft(frame)
            && forward.right[frame] == rampRight(frame) {
            forwardMatches += 1
        }
        #expect(forwardMatches == rampFrames,
                """
                forward render is not the source ramp (\(forwardMatches)/\(rampFrames) frames \
                matched) — the mirror comparison below would be two wrongs agreeing
                """)

        // The gate itself.
        var mirrored = 0
        for frame in 0..<rampFrames
        where reversed.left[frame] == forward.left[rampFrames - 1 - frame]
            && reversed.right[frame] == forward.right[rampFrames - 1 - frame] {
            mirrored += 1
        }
        #expect(mirrored == rampFrames,
                """
                reversed render is not the sample-exact mirror: only \(mirrored)/\(rampFrames) \
                frames matched
                """)

        // Control 2: it really is a different signal.
        #expect(Array(reversed.left[0..<rampFrames]) != Array(forward.left[0..<rampFrames]),
                "reversed and forward renders are identical — `reverse` did nothing")
        // And both voices end where the span ends: exact zeros after 4096.
        #expect(reversed.left[rampFrames..<forward.left.count].allSatisfy { $0 == 0 })
        #expect(forward.left[rampFrames..<forward.left.count].allSatisfy { $0 == 0 })
    }

    /// ⭐ THE FRACTIONAL GATE, and it is the one the required mirror test above
    /// structurally CANNOT be: at `rootPitch` the increment is exactly 1.0, so
    /// `frac` is identically zero and no interpolation bug can show. Here the
    /// note is five semitones DOWN (increment ≈ 0.749, never a symmetric 0.5),
    /// so nearly every read lands between two frames.
    ///
    /// The ramp is affine, so linear interpolation at a fractional position `p`
    /// has a CLOSED FORM — `0.8·p/4095` — and the expected output can be
    /// asserted analytically instead of against another render. An implementation
    /// that mirrored the integer index but not the fraction (reading `x[idx] +
    /// (x[idx+1] − x[idx])·frac` when it owed `1 − frac`) lands up to one full
    /// inter-sample step away, ~20× this tolerance.
    @Test("m32-d: a reversed zone at a FRACTIONAL rate interpolates at the mirrored position")
    func reversedZoneInterpolatesAtTheMirroredFractionalPosition() throws {
        let url = try rampFixture()
        // minPitch/maxPitch span the keyboard: the note below is NOT at
        // rootPitch, which is the entire point, so a one-note zone would
        // simply never fire and every assertion here would pass on silence.
        let rendered = try renderOneZone(
            SamplerZone(audioFileURL: url, rootPitch: 60, minPitch: 0, maxPitch: 127,
                        gain: 1, attack: 0, reverse: true),
            pitch: 55)
        // The engine's own increment expression, character for character
        // (`trigger`: exp2((pitch − rootPitch)/12) × tuneFactor × fileRate /
        // sampleRate), so the predicted positions cannot drift from the real
        // ones through a different association order.
        let increment = exp2((Double(55) - Double(60)) / 12.0)
            * 1.0 * SamplerM32Identity.graphRate / SamplerM32Identity.graphRate
        var local = 0.0
        var checked = 0
        var worst = 0.0
        for frame in 0..<rendered.left.count {
            let readPosition = Double(rampFrames - 1) - local
            if readPosition < 1 { break }
            let expected = 0.8 * readPosition / Double(rampFrames - 1)
            worst = max(worst, abs(Double(rendered.left[frame]) - expected))
            checked += 1
            local += increment
        }
        #expect(checked > 5_000, """
            only \(checked) frames were checked — the reversed voice ended far too early to \
            have covered the span
            """)
        #expect(worst < 1e-5, """
            worst deviation from the analytic mirrored-interpolation value is \(worst); \
            an inverted fraction would be ~2e-4
            """)

        // ⭐ THE LOW-SIDE SPAN CHECK, pinned by the SOURCE'S OWN RANGE rather
        // than by a flag. This zone starts at frame 0 (nil `startFrame` — every
        // whole-file reversed zone), and the increment is fractional, so the
        // reversed playhead's LAST step lands between −1 and 0. `Int` truncates
        // toward zero, so an integer bound check (`idx < startFrame`) reads
        // idx 0 with a NEGATIVE fraction and EXTRAPOLATES past the ramp's ends:
        // below 0 on the rising left channel, above 0.6 on the falling right
        // one. The shipped check compares the Double, so neither can happen.
        let belowFloor = rendered.left.filter { $0 < 0 }
        let aboveCeiling = rendered.right.filter { $0 > 0.6 }
        #expect(belowFloor.isEmpty, """
            \(belowFloor.count) left-channel samples fell below the ramp's own minimum \
            (most negative \(belowFloor.min() ?? 0)) — the reversed voice read past startFrame
            """)
        #expect(aboveCeiling.isEmpty, """
            \(aboveCeiling.count) right-channel samples rose above the ramp's own maximum \
            (largest \(aboveCeiling.max() ?? 0)) — the reversed voice read past startFrame
            """)
    }

    /// A reversed SUB-SPAN must stay inside itself — the case that would read
    /// `left[startFrame − 1]` (or, at `startFrame == 0`, a negative fraction)
    /// if the low-side span check were wrong.
    @Test("m32-d: a reversed zone with startFrame/endFrame mirrors exactly that span and reads nothing outside it")
    func reversedSubSpanStaysInsideItself() throws {
        let url = try rampFixture()
        let start = 1_000
        let end = 3_000
        let rendered = try renderOneZone(
            SamplerZone(audioFileURL: url, rootPitch: 60, minPitch: 60, maxPitch: 60,
                        gain: 1, startFrame: start, endFrame: end, attack: 0, reverse: true))
        var matched = 0
        for frame in 0..<(end - start) where rendered.left[frame] == rampLeft(end - 1 - frame) {
            matched += 1
        }
        #expect(matched == end - start,
                """
                reversed sub-span is not the mirror of [\(start), \(end)): \
                \(matched)/\(end - start) frames matched
                """)
        // Nothing plays after the span is exhausted — in particular the voice
        // does not walk on into frames BELOW startFrame.
        #expect(rendered.left[(end - start)...].allSatisfy { $0 == 0 },
                "the reversed voice kept sounding past startFrame — it read outside its span")
    }

    /// Denormal/NaN guard: a reversed whole-file zone (`startFrame` nil = 0,
    /// the common case) driven fast, where a mis-signed position would run
    /// negative. Every sample must be finite and inside the source's own range.
    @Test("m32-d: a fast reversed whole-file zone produces only finite, in-range samples")
    func reversedZoneProducesNoNaNOrRunaway() throws {
        let url = try rampFixture()
        let rendered = try renderOneZone(
            SamplerZone(audioFileURL: url, rootPitch: 60, minPitch: 0, maxPitch: 127,
                        gain: 1, attack: 0, reverse: true),
            pitch: 96)  // +3 octaves: 8 source frames per output frame
        #expect(rendered.left.allSatisfy { $0.isFinite && abs($0) <= 0.81 })
        #expect(rendered.right.allSatisfy { $0.isFinite && abs($0) <= 0.61 })
        #expect((rendered.left.map { abs($0) }.max() ?? 0) > 0.5,
                "the fast reversed voice never sounded — the range assertions above proved nothing")
    }

    // MARK: - v1 reversed zones IGNORE loops, and say so

    /// The stated v1 cut, measured in both directions: a reversed zone that
    /// ALSO carries a loop plays its span once and stops, and the loader says
    /// why. The positive control is the same zone WITHOUT `reverse` — it must
    /// still be sounding long after the span, or "did not loop" would be
    /// unfalsifiable.
    @Test("m32-d: a reversed LOOPING zone plays its span once, does not loop, and reports why")
    func reversedZoneIgnoresItsLoopAndSaysSo() throws {
        let url = try rampFixture()
        let looped = SamplerZone(audioFileURL: url, rootPitch: 60, minPitch: 60, maxPitch: 60,
                                 gain: 1, attack: 0,
                                 loopMode: .continuous, loopStart: 0, loopEnd: 1_024,
                                 reverse: true)
        let rendered = try renderOneZone(looped)
        #expect((rendered.left[0..<rampFrames].map { abs($0) }.max() ?? 0) > 0.5,
                "the reversed looping zone never sounded at all")
        #expect(rendered.left[rampFrames...].allSatisfy { $0 == 0 },
                "the reversed zone LOOPED — v1 reversed zones play their span once")
        #expect(rendered.notes.contains { $0.contains("reverse") && $0.contains("loop") },
                "no zone-load note explained the dropped loop; notes were \(rendered.notes)")

        // Positive control: identical zone, forward. It MUST still be sounding.
        let forwardLooping = SamplerZone(audioFileURL: url, rootPitch: 60, minPitch: 60,
                                         maxPitch: 60, gain: 1, attack: 0,
                                         loopMode: .continuous, loopStart: 0, loopEnd: 1_024)
        let control = try renderOneZone(forwardLooping)
        #expect((control.left[rampFrames...].map { abs($0) }.max() ?? 0) > 0.1,
                "the forward looping control did not loop either — the assertion above is blind")
        #expect(control.notes.isEmpty, "the forward looping zone should not be noted: \(control.notes)")
    }

    /// The note fires only when a loop was actually AUTHORED. A plain reversed
    /// zone must not report a loop it never had — noise in `zoneLoadNotes` is
    /// how the warning that mattered gets ignored.
    @Test("m32-d: a plain reversed zone reports NO zone-load note")
    func plainReversedZoneIsNotNoted() throws {
        let url = try rampFixture()
        let rendered = try renderOneZone(
            SamplerZone(audioFileURL: url, rootPitch: 60, minPitch: 60, maxPitch: 60,
                        gain: 1, attack: 0, reverse: true))
        #expect(rendered.notes.isEmpty, "unexpected zone-load notes: \(rendered.notes)")
    }

    // MARK: - Gate (b): forward byte-identity, INCLUDING a looping and a bent voice

    /// ⭐⭐ THE BYTE-IDENTITY GATE, and it is pinned to a digest harvested from
    /// the engine BEFORE m32-d was written. `base + dir × local` is an IEEE
    /// identity forward (`0 + 1.0 × x == x` exactly), so a project that sets no
    /// `reverse` anywhere must render bit-for-bit as it always did — including
    /// the two places the position math is hairiest, a CONTINUOUS-LOOP voice
    /// and a BENT voice, both of which this render contains.
    ///
    /// Three controls, because a digest test can be green for stupid reasons:
    ///  1. rendered TWICE and the two digests compared — a pin nobody has shown
    ///     to be stable pins nothing;
    ///  2. a non-floor assertion on the peak — a render of pure silence would
    ///     hash stably forever and mean nothing;
    ///  3. the two channels must DIFFER, so a mono-collapse cannot pass.
    @Test("m32-d: a project with no reversed zone renders byte-identically — looping voice and bent voice included")
    func forwardRenderStaysByteIdentical() throws {
        let first = try SamplerM32Identity.render()
        let second = try SamplerM32Identity.render()
        let digestA = SamplerM32Identity.digest(first.left, first.right)
        let digestB = SamplerM32Identity.digest(second.left, second.right)
        #expect(digestA == digestB,
                "the reference render is not deterministic; a digest pin on it would be noise")

        let peak = max(first.left.map { abs($0) }.max() ?? 0,
                       first.right.map { abs($0) }.max() ?? 0)
        #expect(peak > 0.05, "reference render is at the floor (peak \(peak)) — it proves nothing")
        #expect(first.left != first.right, "channels are identical; a mono collapse would pass blind")

        print("[measured] m32 forward identity digest: \(digestA)")
        #expect(digestA == SamplerM32Identity.goldenDigest, """
            The forward reference render changed. A project using NEITHER m32-d's `reverse` NOR \
            m32-f's `chokeGroup` must render bit-for-bit as it did before both items. \
            got \(digestA), pinned \(SamplerM32Identity.goldenDigest).
            """)
    }
}
