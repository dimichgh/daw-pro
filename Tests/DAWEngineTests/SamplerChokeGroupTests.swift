import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m32-f — PER-ZONE CHOKE GROUPS. `SamplerZone.chokeGroup` (0…63): a new note on
// any zone in the group ends every voice ALREADY SOUNDING from that group. The
// open/closed hi-hat rule, and the reason a re-chopped break sounds tight
// instead of like the loose loop it came from.
//
// ⚠️⚠️ `chokeGroup` IS NOT `group`. `group` is a SELECTION rule at note-on (one
// zone per group fires per trigger — that is what round-robin and alternate
// layers are built on). Choke runs the other way: a new note ending an OLD one.
// Several tests below deliberately use BOTH on the same zones, because the
// combination is where a conflation of the two would show.
//
// ⚠️⚠️ ITS OWN SUITE, AND DELIBERATELY **NOT** `@MainActor`. These tests first
// shipped as an `extension SamplerTests` and in that shape reddened the
// m23-as-2 discriminator in `AUPrepareRenegotiationStressTests` — a main-actor
// contention effect, not a functional regression. The three measured
// configurations and the full reasoning are in SamplerReverseZoneTests.swift;
// read them before moving this suite or adding `@MainActor` to it.
//
// ⭐ EVERY CHOKE ASSERTION IS ON RENDERED AUDIO — the level of a sounding voice
// before and after the choking note. Nothing reads a stage enum or a mask back:
// the design says "assert via rendered envelope, not via a flag", and a flag
// test cannot tell you the choke reached the sound.

// MARK: - File-local harness

/// 8192 = 8 × 1024 frames of STEADY full-scale DC-free tone per channel, at the
/// graph rate. Steady on purpose: a choke is measured as a DROP in level, so
/// the source must not be dropping on its own. Stereo (and 1024-aligned) for
/// m32-h — a single `AVAudioFile.read(into:)` short-reads mono files whose
/// frame count is not a multiple of 1024.
private let chokeFrames = 8_192

private func writeSteadyFixture(to url: URL, leftHz: Double, rightHz: Double) throws {
    let rate = SamplerM32Identity.graphRate
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
                                        frameCapacity: AVAudioFrameCount(chokeFrames)),
          let data = buffer.floatChannelData else {
        throw SamplerM32FixtureError.bufferAllocationFailed
    }
    for frame in 0..<chokeFrames {
        let t = Double(frame) / rate
        data[0][frame] = Float(0.5 * sin(2.0 * .pi * leftHz * t))
        data[1][frame] = Float(0.5 * sin(2.0 * .pi * rightHz * t))
    }
    buffer.frameLength = AVAudioFrameCount(chokeFrames)
    try file.write(from: buffer)
}

/// Two DISTINCT files, so "which zone is sounding" is answerable from the audio
/// itself rather than from bookkeeping: zone A is heard on the LEFT channel
/// only, zone B on the RIGHT only (hard-panned below).
///
/// A `let` under `swift_once`, not a check-then-fill `var` — see the same
/// change in SamplerReverseZoneTests.swift: the old shape was thread-safe only
/// while this was a `@MainActor` suite, which it no longer is.
private let cachedChokeFixtures: Result<(a: URL, b: URL), any Error> = {
    do {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m32f-choke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("chokeA_48k_stereo.wav")
        let b = dir.appendingPathComponent("chokeB_48k_stereo.wav")
        // 375 Hz = 128 frames/cycle and 750 Hz = 64 frames/cycle at 48 kHz, and
        // BOTH divide the 8192-frame loop exactly. That matters: `loopXfade` is 0
        // for a loop starting at frame 0 (raw wrap), so a non-integer number of
        // cycles would put a real discontinuity at every wrap — one of which lands
        // within a few hundred frames of the choke the click assertion measures.
        try writeSteadyFixture(to: a, leftHz: 375, rightHz: 375)
        try writeSteadyFixture(to: b, leftHz: 750, rightHz: 750)
        return .success((a, b))
    } catch {
        return .failure(error)
    }
}()

private func chokeFixtures() throws -> (a: URL, b: URL) {
    try cachedChokeFixtures.get()
}

/// RMS over a window — the level measurement every choke assertion reads.
private func rms(_ samples: [Float], _ range: Range<Int>) -> Double {
    guard !range.isEmpty else { return 0 }
    var sum = 0.0
    for index in range { sum += Double(samples[index]) * Double(samples[index]) }
    return (sum / Double(range.count)).squareRoot()
}

private func renderChoke(zones: [SamplerZone], events: [ScheduledMIDIEvent],
                         frames: Int = 24_576, oneShot: Bool = true)
    throws -> (left: [Float], right: [Float]) {
    // `oneShot` so no note-off can start a release: the ONLY thing that can put
    // a voice into release in these renders is a choke.
    let params = SamplerParams(zones: zones, oneShot: oneShot,
                               attack: 0.001, release: 0.05, gain: 1.0)
    let instrument = SamplerInstrument(params: params,
                                       sampleRate: SamplerM32Identity.graphRate,
                                       randomSeed: 0x6D33_3266)
    instrument.prepare(sampleRate: SamplerM32Identity.graphRate,
                       maxFramesPerQuantum: 512, channelCount: 2)
    return try SamplerM32Identity.renderQuanta(instrument, events: events, frames: frames)
}

/// Hard-left zone on file A. `pan: -1` puts it entirely in the left channel, so
/// its level is readable independently of zone B.
private func zoneA(_ url: URL, chokeGroup: Int?, pitch: Int = 60,
                   group: Int? = nil, seqLength: Int? = nil, seqPosition: Int? = nil,
                   release: Double = 0.05) -> SamplerZone {
    SamplerZone(audioFileURL: url, rootPitch: pitch, minPitch: pitch, maxPitch: pitch,
                gain: 1, group: group, seqLength: seqLength, seqPosition: seqPosition,
                pan: -1, attack: 0, release: release,
                loopMode: .continuous, loopStart: 0, loopEnd: chokeFrames,
                chokeGroup: chokeGroup)
}

/// Hard-right zone on file B.
private func zoneB(_ url: URL, chokeGroup: Int?, pitch: Int = 64,
                   group: Int? = nil, release: Double = 0.05) -> SamplerZone {
    SamplerZone(audioFileURL: url, rootPitch: pitch, minPitch: pitch, maxPitch: pitch,
                gain: 1, group: group, pan: 1, attack: 0, release: release,
                loopMode: .continuous, loopStart: 0, loopEnd: chokeFrames,
                chokeGroup: chokeGroup)
}

@Suite("Sampler choke groups (m32-f)", .serialized)
struct SamplerChokeGroupTests {
    // MARK: - The gate: one zone's note ends another's sounding voice

    /// ⭐⭐ THE GATE. Two zones sharing choke group 3, on distinct hard-panned
    /// files, so each one's level is readable on its own channel. Zone A's note
    /// starts at 0 and would sustain for the whole render (continuous loop,
    /// one-shot, 4 s release — nothing else can end it). Zone B's note lands at
    /// 8000. A must be in RELEASE from there, and audibly decaying, while B
    /// sounds.
    ///
    /// The paired control is the SAME render with `chokeGroup: nil` on both: A
    /// must still be at full level after 8000. Without it, "A got quieter"
    /// could be any of a dozen unrelated things.
    @Test("m32-f GATE: a note in a choke group puts the group's sounding voice into release")
    func chokeGroupEndsTheSoundingVoice() throws {
        let (a, b) = try chokeFixtures()
        let events = SamplerM32Identity.note(on: 0, off: 30_000, pitch: 60, id: 1)
            + SamplerM32Identity.note(on: 8_000, off: 30_000, pitch: 64, id: 2)

        let choked = try renderChoke(zones: [zoneA(a, chokeGroup: 3),
                                             zoneB(b, chokeGroup: 3)],
                                     events: events)
        let control = try renderChoke(zones: [zoneA(a, chokeGroup: nil),
                                              zoneB(b, chokeGroup: nil)],
                                      events: events)

        // Before the choking note both renders agree — A is sounding, B is not.
        #expect(rms(choked.left, 4_000..<7_500) > 0.2)
        #expect(rms(choked.right, 4_000..<7_500) < 1e-6, "zone B sounded before its note")
        #expect(abs(rms(choked.left, 4_000..<7_500) - rms(control.left, 4_000..<7_500)) < 1e-9,
                "the two renders differ BEFORE the choke — they are not comparable")

        // After it: A has decayed in the choked render...
        let after = 10_000..<12_000
        let chokedA = rms(choked.left, after)
        let controlA = rms(control.left, after)
        #expect(chokedA < controlA * 0.7, """
            zone A was not choked: RMS after the choking note is \(chokedA) against a \
            no-chokeGroup control of \(controlA)
            """)
        // ...and the control did NOT decay, which is what makes the line above
        // a measurement of the choke rather than of the source running out.
        #expect(controlA > 0.2, """
            the control voice decayed on its own (RMS \(controlA)) — the choke assertion \
            above proves nothing
            """)
        // The choking note itself is unaffected: B sounds in both.
        #expect(rms(choked.right, after) > 0.2, "the choking note choked ITSELF")
        #expect(abs(rms(choked.right, after) - rms(control.right, after)) < 1e-9)
    }

    /// A choked voice is NOT hard-cut. `monoChoke`'s body — reused verbatim —
    /// moves it to its own release from its own level, so the decay is a RAMP.
    /// A hard cut would be a gain step, i.e. a click, on every choke.
    @Test("m32-f: a choked voice RAMPS down over its own release, it is not cut")
    func chokedVoiceRampsRatherThanCuts() throws {
        let (a, b) = try chokeFixtures()
        let events = SamplerM32Identity.note(on: 0, off: 30_000, pitch: 60, id: 1)
            + SamplerM32Identity.note(on: 8_000, off: 30_000, pitch: 64, id: 2)
        // 0.25 s release at 48 kHz = 12 000 frames to silence.
        let rendered = try renderChoke(zones: [zoneA(a, chokeGroup: 3, release: 0.25),
                                               zoneB(b, chokeGroup: 3, release: 0.25)],
                                       events: events)
        let early = rms(rendered.left, 8_100..<9_100)
        let late = rms(rendered.left, 17_000..<18_000)
        #expect(early > 0.15, "the choke was a hard cut — nothing survived the first 1000 frames")
        #expect(late < early * 0.4, "the choked voice never finished decaying (\(early) → \(late))")
        // And no click: no single-sample jump anywhere near the choke.
        var worstStep: Float = 0
        for index in 7_900..<8_600 {
            worstStep = max(worstStep, abs(rendered.left[index] - rendered.left[index - 1]))
        }
        #expect(worstStep < 0.15, "a \(worstStep) single-sample step at the choke — that is a click")
    }

    /// ⭐ THE LAYERING RULE, and the reason the fired-mask is a `UInt64` rather
    /// than a Bool. Two zones in DIFFERENT m19-a `group`s (so ONE note-on fires
    /// both) sharing ONE choke group must BOTH sound. Without per-group memory
    /// the second layer would choke the first and the user would hear half of
    /// what they authored.
    @Test("m32-f: two same-choke-group zones LAYERED by one note-on do not choke each other")
    func sameNoteOnLayersDoNotSelfChoke() throws {
        let (a, b) = try chokeFixtures()
        // Same pitch, different `group` → m19-a fires one voice per group.
        let zones = [zoneA(a, chokeGroup: 7, pitch: 60, group: 0),
                     zoneB(b, chokeGroup: 7, pitch: 60, group: 1)]
        let rendered = try renderChoke(
            zones: zones, events: SamplerM32Identity.note(on: 0, off: 30_000, pitch: 60, id: 1))
        // Zone A is hard left, zone B hard right: both channels must be loud.
        #expect(rms(rendered.left, 6_000..<10_000) > 0.2, "the left layer was choked by its own note-on")
        #expect(rms(rendered.right, 6_000..<10_000) > 0.2, "the right layer was choked by its own note-on")
    }

    /// ⭐ THE "ARM AT NOTE-ON, FIRE IN `trigger`" RULE, stated as a
    /// measurement. A note-on that selects NO zone must not silence what is
    /// sounding. Zone B here is gated OUT by round-robin on the second trigger
    /// (`seqLength: 2, seqPosition: 1` — it plays on match 1, not match 2), so
    /// the second note at pitch 64 selects nothing at all.
    ///
    /// An implementation that choked in the note-on SELECTION loop instead of
    /// inside `trigger` opens a hole exactly here: the sounding zone-A voice
    /// would be released by a note that never made a sound of its own.
    @Test("m32-f: a note-on that selects NO zone chokes nothing — no hole")
    func noteThatSelectsNoZoneOpensNoHole() throws {
        let (a, b) = try chokeFixtures()
        // Round-robin B so that its SECOND range match is gated out.
        let gatedB = SamplerZone(audioFileURL: b, rootPitch: 64, minPitch: 64, maxPitch: 64,
                                 gain: 1, seqLength: 2, seqPosition: 1, pan: 1, attack: 0,
                                 release: 0.05,
                                 loopMode: .continuous, loopStart: 0, loopEnd: chokeFrames,
                                 chokeGroup: 5)
        let events = SamplerM32Identity.note(on: 0, off: 40_000, pitch: 64, id: 1)   // B plays
            + SamplerM32Identity.note(on: 4_000, off: 40_000, pitch: 60, id: 2)      // A plays, chokes B
            + SamplerM32Identity.note(on: 12_000, off: 40_000, pitch: 64, id: 3)     // B is GATED OUT
        let rendered = try renderChoke(zones: [zoneA(a, chokeGroup: 5), gatedB], events: events)

        // Control that the gate really did gate: the right channel (zone B)
        // must be decaying from its 4000-frame choke and must NOT come back at
        // 12 000. Without this, "A survived" could be because B fired anyway.
        #expect(rms(rendered.right, 14_000..<16_000) < rms(rendered.right, 2_000..<3_500) * 0.7,
                """
                zone B sounded again at 12 000 — round-robin did not gate it, so the \
                assertion below is not testing a no-zone note-on
                """)
        // THE GATE: zone A, sounding since 4000, is untouched by the 12 000
        // note-on that selected nothing.
        let before = rms(rendered.left, 9_000..<11_500)
        let after = rms(rendered.left, 14_000..<16_500)
        #expect(before > 0.2)
        #expect(after > before * 0.95, """
            zone A lost \(1 - after / before) of its level after a note-on that sounded \
            NOTHING — the choke fired in the selection loop instead of in `trigger`
            """)
    }

    /// ⭐ THE SAME HOLE, ONE GATE FURTHER IN — and the case that shows why
    /// `group` and `chokeGroup` are different fields.
    ///
    /// Zones X and Y share m19-a `group` 0, so ONE note-on fires X and skips Y
    /// (one zone per selection group). Y carries choke group 2, and zone Z —
    /// sounding since frame 0 on the other channel — is in choke group 2 too.
    /// Y NEVER SOUNDS, so it must never choke: Z is still playing at the end.
    ///
    /// This is deliberately a second, narrower version of the no-hole test
    /// above. That one catches a choke fired on a bare RANGE MATCH; this one
    /// catches a choke fired after the round-robin/random gates but before the
    /// one-per-group rule — which the first test cannot see, because its gated
    /// zone never reaches that far. (Measured: an implementation choking at
    /// that later point passes the test above and fails this one.)
    @Test("m32-f: a zone that LOSES the one-per-group race never chokes — it did not sound")
    func zoneSkippedByItsSelectionGroupDoesNotChoke() throws {
        let (a, b) = try chokeFixtures()
        // Z: left channel, choke group 2, its own pitch.
        let z = SamplerZone(audioFileURL: a, rootPitch: 48, minPitch: 48, maxPitch: 48,
                            gain: 1, pan: -1, attack: 0, release: 0.05,
                            loopMode: .continuous, loopStart: 0, loopEnd: chokeFrames,
                            chokeGroup: 2)
        // X and Y: right channel, SAME m19-a group (nil = 0), so X wins and Y
        // is skipped. Y is the one carrying Z's choke group.
        let x = SamplerZone(audioFileURL: b, rootPitch: 60, minPitch: 60, maxPitch: 60,
                            gain: 1, pan: 1, attack: 0, release: 0.05,
                            loopMode: .continuous, loopStart: 0, loopEnd: chokeFrames,
                            chokeGroup: 1)
        let y = SamplerZone(audioFileURL: b, rootPitch: 60, minPitch: 60, maxPitch: 60,
                            gain: 1, pan: 1, attack: 0, release: 0.05,
                            loopMode: .continuous, loopStart: 0, loopEnd: chokeFrames,
                            chokeGroup: 2)
        let events = SamplerM32Identity.note(on: 0, off: 30_000, pitch: 48, id: 1)
            + SamplerM32Identity.note(on: 8_000, off: 30_000, pitch: 60, id: 2)
        let rendered = try renderChoke(zones: [z, x, y], events: events)

        #expect(rms(rendered.right, 10_000..<12_000) > 0.2,
                "X never sounded — the setup is wrong, not the engine")
        #expect(rms(rendered.left, 10_000..<12_000) > 0.2, """
            zone Z was choked by zone Y, which the one-per-group rule had already             SKIPPED — a zone that makes no sound must not end one that is
            """)
    }

    /// A zone with no choke group is not a member of anybody's group, so a
    /// choking neighbour leaves it alone.
    @Test("m32-f: a zone with no chokeGroup is untouched by a choking neighbour")
    func nilChokeGroupZoneIsUntouched() throws {
        let (a, b) = try chokeFixtures()
        let events = SamplerM32Identity.note(on: 0, off: 30_000, pitch: 60, id: 1)
            + SamplerM32Identity.note(on: 8_000, off: 30_000, pitch: 64, id: 2)
        let rendered = try renderChoke(zones: [zoneA(a, chokeGroup: nil),
                                               zoneB(b, chokeGroup: 3)],
                                       events: events)
        #expect(rms(rendered.left, 10_000..<12_000) > 0.2,
                "a nil-chokeGroup zone was choked by its neighbour")
        #expect(rms(rendered.right, 10_000..<12_000) > 0.2, "the choking zone did not sound")
    }

    /// Different groups are independent — group 3 does not touch group 4. The
    /// whole point of per-zone groups over mono voice mode is that hats can
    /// choke hats while kicks stay polyphonic in the same instrument.
    @Test("m32-f: choke groups are independent — a note in group 4 leaves group 3 sounding")
    func differentChokeGroupsAreIndependent() throws {
        let (a, b) = try chokeFixtures()
        let events = SamplerM32Identity.note(on: 0, off: 30_000, pitch: 60, id: 1)
            + SamplerM32Identity.note(on: 8_000, off: 30_000, pitch: 64, id: 2)
        let rendered = try renderChoke(zones: [zoneA(a, chokeGroup: 3),
                                               zoneB(b, chokeGroup: 4)],
                                       events: events)
        #expect(rms(rendered.left, 10_000..<12_000) > 0.2,
                "group 3 was choked by a note in group 4")
        #expect(rms(rendered.right, 10_000..<12_000) > 0.2)
    }

    /// The top of the range, because 63 is exactly where a `1 << group` shift
    /// stops being obviously safe. Group 63 must choke, and must not disturb
    /// group 0.
    @Test("m32-f: choke group 63 (the top of the range) works and is independent of group 0")
    func topOfRangeChokeGroupWorks() throws {
        let (a, b) = try chokeFixtures()
        let events = SamplerM32Identity.note(on: 0, off: 30_000, pitch: 60, id: 1)
            + SamplerM32Identity.note(on: 8_000, off: 30_000, pitch: 64, id: 2)
        let same = try renderChoke(zones: [zoneA(a, chokeGroup: 63),
                                           zoneB(b, chokeGroup: 63)],
                                   events: events)
        #expect(rms(same.left, 10_000..<12_000) < rms(same.left, 4_000..<7_500) * 0.7,
                "choke group 63 did not choke")
        let split = try renderChoke(zones: [zoneA(a, chokeGroup: 0),
                                            zoneB(b, chokeGroup: 63)],
                                    events: events)
        #expect(rms(split.left, 10_000..<12_000) > 0.2, "group 0 was choked by group 63")
    }

    // MARK: - Byte-identity for every project that does not use the field

    /// The same reference render, and the same pinned digest, m32-d's forward
    /// gate uses. A project with no `chokeGroup` anywhere must be bit-identical
    /// to the engine before this item.
    ///
    /// ⭐ ITS POSITIVE CONTROL IS THE NEXT TEST, and it is not optional: this
    /// render was built with OVERLAPPING notes across two zones precisely so
    /// that adding a `chokeGroup` MUST change it. A byte-identity test on
    /// material where no choke could ever fire is unfalsifiable.
    @Test("m32-f: a project with no chokeGroup renders byte-identically")
    func noChokeGroupRendersByteIdentically() throws {
        let rendered = try SamplerM32Identity.render()
        let digest = SamplerM32Identity.digest(rendered.left, rendered.right)
        #expect(digest == SamplerM32Identity.goldenDigest, """
            a project that sets no `chokeGroup` anywhere started rendering differently: \
            got \(digest), pinned \(SamplerM32Identity.goldenDigest)
            """)
    }

    @Test("m32-f POSITIVE CONTROL: giving those same zones a chokeGroup DOES change the render")
    func chokeGroupChangesTheSameRender() throws {
        let plain = try SamplerM32Identity.render()
        let choking = try SamplerM32Identity.render(chokeGroup: 9)
        let plainDigest = SamplerM32Identity.digest(plain.left, plain.right)
        let chokingDigest = SamplerM32Identity.digest(choking.left, choking.right)
        #expect(plainDigest == SamplerM32Identity.goldenDigest)
        #expect(chokingDigest != plainDigest, """
            adding a chokeGroup to both zones of the reference render changed NOTHING. \
            Either the field is inert, or the reference material has no overlap for a \
            choke to act on — in which case the byte-identity test above is blind.
            """)
        // …and the difference is a REDUCTION, i.e. actually a choke.
        let plainEnergy = rms(plain.left, 5_000..<13_000)
        let chokingEnergy = rms(choking.left, 5_000..<13_000)
        #expect(chokingEnergy < plainEnergy, """
            the chokeGroup render differs but is not quieter over the overlap \
            (\(plainEnergy) → \(chokingEnergy)) — that is not a choke
            """)
    }

    /// A project file written by hand (or by an older tool) can carry a
    /// `chokeGroup` outside 0…63 — a raw `Codable` decode bypasses the model's
    /// clamping init, which is why `startFrame`/`endFrame` are re-clamped in the
    /// loader too. `1 << 99` is undefined-to-trapping, ON THE RENDER THREAD.
    @Test("m32-f: an out-of-range chokeGroup from a raw decode is clamped, not shifted")
    func outOfRangeChokeGroupIsClamped() throws {
        let (a, b) = try chokeFixtures()
        // Bypass the clamping init exactly as a decode would.
        let raw = """
            {"id":"\(UUID().uuidString)","audioFileURL":"file://\(a.path)","rootPitch":60,
             "minPitch":60,"maxPitch":60,"gain":1,"pan":-1,"attack":0,"chokeGroup":9999}
            """
        let decoded = try JSONDecoder().decode(SamplerZone.self, from: Data(raw.utf8))
        #expect(decoded.chokeGroup == 9_999, "the raw decode was expected to BYPASS the clamp")
        let events = SamplerM32Identity.note(on: 0, off: 30_000, pitch: 60, id: 1)
            + SamplerM32Identity.note(on: 8_000, off: 30_000, pitch: 64, id: 2)
        // Must not trap, and must behave as the clamped group 63.
        let rendered = try renderChoke(zones: [decoded, zoneB(b, chokeGroup: 63)],
                                       events: events)
        #expect(rms(rendered.left, 4_000..<7_500) > 0.2, "the out-of-range zone never sounded")
        #expect(rms(rendered.left, 10_000..<12_000) < rms(rendered.left, 4_000..<7_500) * 0.7,
                "the clamped-to-63 zone was not choked by the real group 63")
    }
}
