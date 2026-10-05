import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

// m34-o — THE SAMPLER'S GLOBAL DECAY/SUSTAIN, the half of the envelope that
// had no instrument-level control until now.
//
// ══ THE DEFECT, AS THE USER FOUND IT ════════════════════════════════════════
// "when activating sustain, the note should still eventually fade (fade time
// configurable), currently it keeps playing. Am I wrong?"
//
// They are not wrong, for a piano. A damper pedal stops the damper falling; it
// does not feed the string energy. The correct model is that THE PEDAL DEFERS
// THE RELEASE AND THE INSTRUMENT'S OWN DECAY DOES THE FADING — so a fading
// note needs an envelope that decays, and the pedal must never invent a fade
// of its own.
//
// ⛔⛔ AND HOLDING FOREVER IS CORRECT FOR SOME INSTRUMENTS. An organ, a bowed
// pad and a synth pad genuinely sustain under the pedal. THE INSTRUMENT
// DECIDES, NOT THE PEDAL. A change that made everything decay would be a worse
// defect than the one it replaces, because it would be silently wrong on every
// sound where the current behaviour is right. That is why HALF the gates below
// are FLAT CONTROLS: they assert a note does NOT fade, and they are as
// load-bearing as the ones that assert it does.
//
// ⭐ EVERY GATE MEASURES RENDERED AUDIO — peak amplitude in a window, sampled
// at several points so the CURVE is asserted rather than "it eventually
// stopped". None reads a coefficient back off the instrument. A test that
// asserts `decayStep != 0` cannot tell you the note got quieter.
//
// ⚠️ An extension on `SamplerTests`, not a new `@Suite`, for the reason
// `SamplerBendRangeVoiceModeTests` records: the `MainActorOccupancySiteTests`
// cap on @MainActor-isolated suites is 330 and the tree sits on it (m23-aw-4).

// MARK: - File-local harness

/// A Float32 WAV at 44.1 kHz, amp 0.5, mono, written from a closed-form
/// expression so the fixture is bit-reproducible run to run.
private func writeEnvSineFixture(to url: URL, frequency: Double, seconds: Double) throws {
    let fileRate = 44_100.0
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: fileRate,
        AVNumberOfChannelsKey: UInt32(1),
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = Int(fileRate * seconds)
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fileRate,
                                     channels: 1, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(frames)),
          let data = buffer.floatChannelData else {
        throw NSError(domain: "SamplerGlobalEnvelopeTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
    }
    for frame in 0..<frames {
        data[0][frame] = Float(0.5 * sin(2.0 * .pi * frequency * Double(frame) / fileRate))
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    try file.write(from: buffer)
}

private enum EnvFixture {
    nonisolated(unsafe) private static var cached: URL?

    /// 6 seconds — long enough that a note held across every measurement
    /// window below is still reading SAMPLE material, never the end of the
    /// file. A short fixture would fall silent on its own and every "it faded"
    /// gate would pass for the wrong reason.
    static func url() throws -> URL {
        if let cached { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m34o-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sine440_44k1_mono_6s.wav")
        try writeEnvSineFixture(to: url, frequency: 440, seconds: 6)
        cached = url
        return url
    }
}

private func envNoteEvents(on: Int64, off: Int64, pitch: UInt8 = 69,
                          velocity: UInt8 = 127, id: UInt64 = 1) -> [ScheduledMIDIEvent] {
    [ScheduledMIDIEvent(sampleTime: on, noteID: id,
                        kind: ScheduledMIDIEvent.noteOn, pitch: pitch, velocity: velocity),
     ScheduledMIDIEvent(sampleTime: off, noteID: id,
                        kind: ScheduledMIDIEvent.noteOff, pitch: pitch, velocity: 0)]
}

/// Renders in 512-frame quanta, replicating `InstrumentRenderer`'s slicing.
private func renderEnvQuanta(_ instrument: SamplerInstrument,
                             events unsorted: [ScheduledMIDIEvent],
                             frames totalFrames: Int,
                             sampleRate: Double = 48_000,
                             quantum: Int = 512) throws -> [Float] {
    let events = unsorted.sorted { a, b in
        if a.sampleTime != b.sampleTime { return a.sampleTime < b.sampleTime }
        let rankA = a.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
        let rankB = b.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
        if rankA != rankB { return rankA < rankB }
        return a.noteID < b.noteID
    }
    let format = try #require(AVAudioFormat(
        standardFormatWithSampleRate: sampleRate, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
    let channels = try #require(buffer.floatChannelData)

    var left: [Float] = []
    left.reserveCapacity(totalFrames)
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
        rendered += frames
    }
    return left
}

/// Peak absolute amplitude in a 0.25 s window centred on `seconds`.
private func envPeak(_ samples: [Float], atSeconds seconds: Double,
                     sampleRate: Double = 48_000) -> Float {
    let half = Int(0.125 * sampleRate)
    let centre = Int(seconds * sampleRate)
    let lo = max(0, centre - half)
    let hi = min(samples.count, centre + half)
    guard lo < hi else { return 0 }
    var peak: Float = 0
    for i in lo..<hi { peak = max(peak, abs(samples[i])) }
    return peak
}

/// The whole measurement, in one place: the note is held across all four
/// windows, so every number describes the SUSTAIN portion of the envelope and
/// nothing else. Returns peaks at 0.5 / 1.5 / 3.0 / 5.0 s.
private func heldNoteCurve(zone: SamplerZone,
                           globalDecay: Double? = nil,
                           globalSustain: Double? = nil,
                           label: String) throws -> [Float] {
    try heldNoteCurve(params: SamplerParams(zones: [zone], attack: 0.005, release: 0.05,
                                            gain: 0.8, decay: globalDecay,
                                            sustain: globalSustain),
                      label: label)
}

/// m34-s split the measurement out so params that have been through the SAVE
/// FORMAT are measured by exactly the same rig as params that have not — one
/// home for the numbers, so a reopened patch and a fresh one are comparable.
private func heldNoteCurve(params: SamplerParams, label: String) throws -> [Float] {
    let sampler = SamplerInstrument(params: params, randomSeed: 0xD1CE_5EED)
    sampler.prepare(sampleRate: 48_000, maxFramesPerQuantum: 512, channelCount: 2)
    let frames = Int(48_000 * 5.5)
    // NOTE-OFF LANDS AFTER THE LAST WINDOW: nothing here measures a release
    // ramp. The question is what the level does WHILE THE KEY IS DOWN, which
    // is exactly the question the sustain pedal asks.
    let left = try renderEnvQuanta(sampler,
                                   events: envNoteEvents(on: 0, off: Int64(frames)),
                                   frames: frames)
    let curve = [0.5, 1.5, 3.0, 5.0].map { envPeak(left, atSeconds: $0) }
    print("[measured] \(label): "
          + curve.enumerated()
              .map { "t\([0.5, 1.5, 3.0, 5.0][$0.offset])=\(String(format: "%.5f", $0.element))" }
              .joined(separator: "  "))
    return curve
}

/// A full-span zone on the 6 s fixture, with every envelope field nil unless
/// named — so a nil field is genuinely inheriting rather than quietly set.
private func envZone(fixture: URL, decay: Double? = nil,
                     sustain: Double? = nil) -> SamplerZone {
    SamplerZone(audioFileURL: fixture, rootPitch: 69, decay: decay, sustain: sustain)
}

/// m34-s — THE REAL SAVE/OPEN PATH: params → `InstrumentDocument` → JSON →
/// `InstrumentDocument` → `instrumentDescriptor`. Not `SamplerParams`' own
/// `Codable`, which round-trips all fifteen fields and therefore cannot fail
/// the way a project does.
///
/// ⚠️ Zone media rides as an ABSOLUTE path — `ProjectDocument.resolveMedia`'s
/// documented recovery-bundle form — because a zone whose media does not
/// resolve is DROPPED on open, and then every "it faded" assertion below would
/// pass on silence. The zone-count check inside is what makes that loud.
private func reopenThroughTheSaveFormat(_ params: SamplerParams) throws -> SamplerParams {
    let mediaRefs: [UUID: String?] = Dictionary(
        uniqueKeysWithValues: params.zones.map { ($0.id, $0.audioFileURL.path as String?) })
    let document = InstrumentDocument(
        from: InstrumentDescriptor(kind: .sampler, sampler: params), mediaRefs: mediaRefs)
    let data = try JSONEncoder().encode(document)
    let reopened = try JSONDecoder().decode(InstrumentDocument.self, from: data)
    var warnings: [String] = []
    let restored = try #require(
        reopened.instrumentDescriptor(bundleURL: URL(fileURLWithPath: "/tmp"),
                                      warn: { warnings.append($0) }).sampler)
    #expect(warnings.isEmpty, "the round trip must not warn: \(warnings)")
    #expect(restored.zones.count == params.zones.count,
            "a dropped zone would make every measurement here pass on silence")
    return restored
}

extension SamplerTests {

    // MARK: - 1. THE LEGACY LAW (the byte-compat gate)

    /// ⛔ THE GATE THE WHOLE CHANGE TURNS ON. `decay`/`sustain` moved from
    /// hardcoded `?? 0` / `?? 1` literals inside the engine's zone loader to a
    /// `-1` inherit sentinel resolved against a new instrument global. If that
    /// move changed what a nil-everything patch does, EVERY sampler project
    /// already on disk — every one of which has both globals nil and most of
    /// whose zones leave both fields nil — would render differently on load.
    ///
    /// The claim is specific: nil zone + nil globals must HOLD AT FULL LEVEL,
    /// flat, exactly as before. Asserted as a curve, not as a hash, because
    /// the interesting failure (a slow droop) is one a hash would report as
    /// "different" without saying how.
    @Test("m34-o legacy: nil zone + nil globals still holds FLAT at full level")
    func nilEverythingStillHoldsFlat() throws {
        let fixture = try EnvFixture.url()
        let curve = try heldNoteCurve(zone: envZone(fixture: fixture),
                                      label: "legacy nil-everything")
        let first = try #require(curve.first)
        #expect(first > 0.1, "the note must actually sound")
        for (i, value) in curve.enumerated() {
            #expect(abs(value - first) < 0.02 * first,
                    "legacy hold drifted at window \(i): \(value) vs \(first)")
        }
    }

    // MARK: - 2. THE FIX — a global fade, with no zone envelope at all

    /// The defect's direct answer: an instrument-level decay/sustain makes a
    /// held note fade, on a zone that authors NO envelope fields. Before m34-o
    /// this was unreachable — there was no global to set.
    ///
    /// Asserted as MONOTONIC over four windows, not merely "quieter at the
    /// end": a note that dipped and recovered would satisfy the weaker claim
    /// and is not a decay.
    @Test("m34-o global decay/sustain fades a held note MONOTONICALLY to near silence")
    func globalDecayFadesHeldNote() throws {
        let fixture = try EnvFixture.url()
        let curve = try heldNoteCurve(zone: envZone(fixture: fixture),
                                      globalDecay: 4.0, globalSustain: 0.0,
                                      label: "global decay 4 / sustain 0")
        for i in 1..<curve.count {
            #expect(curve[i] < curve[i - 1],
                    "not monotonic at window \(i): \(curve[i]) >= \(curve[i - 1])")
        }
        let first = try #require(curve.first)
        let last = try #require(curve.last)
        #expect(first > 0.1, "the note must start audible")
        // 4 s decay to sustain 0, measured at 5.0 s: past the end of the ramp,
        // so the level is at the floor rather than merely low.
        #expect(last < 0.01 * first,
                "a decay to sustain 0 must reach the floor: \(last) vs \(first)")
    }

    /// A PARTIAL fade — the piano-ish middle ground and the more common
    /// setting: the note falls, then SETTLES, and does not go silent. Pins
    /// that `sustain` is a level and not a flag.
    @Test("m34-o global sustain 0.3 falls to a FLOOR and holds there, not to silence")
    func globalPartialSustainSettles() throws {
        let fixture = try EnvFixture.url()
        let curve = try heldNoteCurve(zone: envZone(fixture: fixture),
                                      globalDecay: 1.0, globalSustain: 0.3,
                                      label: "global decay 1 / sustain 0.3")
        let first = try #require(curve.first)
        // Window 0 (0.5 s) sits mid-ramp; windows 2 and 3 are long past the
        // 1 s decay, so both must sit at the sustain floor together.
        #expect(curve[2] < 0.6 * first, "it must actually have fallen")
        #expect(curve[3] > 0.2 * first, "it must NOT have fallen to silence")
        #expect(abs(curve[3] - curve[2]) < 0.05 * first,
                "past the decay the level must be FLAT at the sustain floor: \(curve[2]) vs \(curve[3])")
    }

    // MARK: - 3. FLAT CONTROLS — the instrument decides, and some hold

    /// ⭐⭐ THE CONTROL THAT PROVES THE FIX IS NOT "MAKE EVERYTHING FADE".
    /// A zone that explicitly holds (sustain 1) keeps holding even while the
    /// INSTRUMENT global says fade — SFZ region-over-global precedence, and
    /// the reason an organ patch inside a sampler survives this change.
    @Test("m34-o FLAT CONTROL: a zone with sustain 1 holds THROUGH a global fade")
    func zoneSustainOverridesGlobalFade() throws {
        let fixture = try EnvFixture.url()
        let curve = try heldNoteCurve(zone: envZone(fixture: fixture, decay: 0, sustain: 1),
                                      globalDecay: 4.0, globalSustain: 0.0,
                                      label: "zone sustain 1 vs global fade")
        let first = try #require(curve.first)
        for (i, value) in curve.enumerated() {
            #expect(abs(value - first) < 0.02 * first,
                    "a holding zone must not be faded by the global (window \(i)): \(value) vs \(first)")
        }
    }

    /// The other half of the same rule: a zone that authors its OWN fade must
    /// fade even when the instrument global says hold. Together with the test
    /// above this pins precedence in both directions, so a future change that
    /// inverted it cannot pass by satisfying only one.
    @Test("m34-o a zone's own decay/sustain fades even when the globals say hold")
    func zoneEnvelopeFadesWithoutGlobals() throws {
        let fixture = try EnvFixture.url()
        let curve = try heldNoteCurve(zone: envZone(fixture: fixture, decay: 2.0, sustain: 0.0),
                                      label: "zone decay 2 / sustain 0, globals nil")
        let first = try #require(curve.first)
        let last = try #require(curve.last)
        #expect(last < 0.01 * first, "the zone's own envelope must fade it: \(last)")
    }

    // MARK: - 4. THE HALVES INHERIT INDEPENDENTLY

    /// ⛔ THE SUBTLETY THE IMPLEMENTATION TURNS ON. The decay STEP is a
    /// function of the PAIR (decay, sustain), while each half inherits
    /// separately. A zone that sets `sustain` and leaves `decay` nil must take
    /// the ZONE's sustain and the GLOBAL's decay.
    ///
    /// This is the gate a precomputed global decay-step could not pass: such a
    /// step necessarily carries the GLOBAL's sustain, so it would fade this
    /// note toward 0.9 instead of the zone's 0.0 and land ~9× too high.
    @Test("m34-o mixed halves: zone sustain 0 + global decay reaches the ZONE's floor")
    func zoneSustainWithGlobalDecay() throws {
        let fixture = try EnvFixture.url()
        // Global sustain is 0.9 — deliberately far from the zone's 0.0, so a
        // resolution that took the global's sustain would be unmistakable.
        let curve = try heldNoteCurve(zone: envZone(fixture: fixture, sustain: 0.0),
                                      globalDecay: 2.0, globalSustain: 0.9,
                                      label: "zone sustain 0 + global decay 2")
        let first = try #require(curve.first)
        let last = try #require(curve.last)
        #expect(last < 0.01 * first,
                "must reach the ZONE's sustain 0, not the global's 0.9: \(last) vs \(first)")
    }

    /// The mirror: the zone owns DECAY, the global owns SUSTAIN. A fast zone
    /// decay (0.4 s) against a global sustain of 0.25 must have SETTLED at
    /// 0.25 of peak by the second window — where a resolution that wrongly
    /// used the GLOBAL's 4 s decay would still be ramping, at ~0.72 of peak.
    ///
    /// ⚠️ MEASURED AGAINST A REFERENCE PEAK, NOT AGAINST THIS CURVE'S OWN
    /// FIRST WINDOW. The first draft of this test compared to `curve[0]` as a
    /// stand-in for peak and failed — correctly — because a 0.4 s decay is
    /// ALREADY FINISHED by the 0.5 s window, so `curve[0]` is the floor, not
    /// the peak. The engine was right and the assertion was wrong. A held
    /// nil-everything render supplies the true peak.
    @Test("m34-o mixed halves: zone decay + global sustain uses the ZONE's timing")
    func zoneDecayWithGlobalSustain() throws {
        let fixture = try EnvFixture.url()
        let reference = try heldNoteCurve(zone: envZone(fixture: fixture),
                                          label: "reference peak (nil everything)")
        let peak = try #require(reference.first)
        let curve = try heldNoteCurve(zone: envZone(fixture: fixture, decay: 0.4),
                                      globalDecay: 4.0, globalSustain: 0.25,
                                      label: "zone decay 0.4 + global sustain 0.25")
        // THE DISCRIMINATING NUMBER. Zone decay (0.4 s, finished) + global
        // sustain (0.25) => 0.25 x peak. The global's 4 s decay would leave
        // window 1 at ~0.72 x peak, which this tolerance excludes by a mile.
        #expect(abs(curve[1] - 0.25 * peak) < 0.03 * peak,
                "expected the GLOBAL sustain 0.25 of peak \(peak) via the ZONE's fast decay; got \(curve[1])")
        #expect(abs(curve[3] - curve[1]) < 0.05 * curve[1],
                "past the zone's decay the level must be flat: \(curve[1]) vs \(curve[3])")
    }

    // MARK: - 5. DENORMAL / NaN AND VOICE-LIFETIME GUARDS

    /// A decayed-to-zero voice must produce EXACT zeros, not denormal grit,
    /// and must not go non-finite. The render path's guard flushes sub-denormal
    /// filter state; this asserts the audible consequence.
    ///
    /// ⚠️ NAMED HONESTLY: a voice at sustain 0 stays ACTIVE (it is still held —
    /// only a note-off starts the release that frees it), so it continues to
    /// occupy a voice slot until the key or pedal comes up. That is the same
    /// voice-stealing budget as before m34-o and is not a leak; it is simply
    /// what "the note is still down, at zero level" means.
    @Test("m34-o a voice decayed to sustain 0 renders EXACT zeros, finite throughout")
    func decayedVoiceIsExactlySilentAndFinite() throws {
        let fixture = try EnvFixture.url()
        let params = SamplerParams(zones: [envZone(fixture: fixture)],
                                   attack: 0.005, release: 0.05, gain: 0.8,
                                   decay: 0.5, sustain: 0.0)
        let sampler = SamplerInstrument(params: params, randomSeed: 0xD1CE_5EED)
        sampler.prepare(sampleRate: 48_000, maxFramesPerQuantum: 512, channelCount: 2)
        let frames = Int(48_000 * 3.0)
        let left = try renderEnvQuanta(sampler,
                                       events: envNoteEvents(on: 0, off: Int64(frames)),
                                       frames: frames)
        #expect(left.allSatisfy { $0.isFinite }, "a decayed voice must never go non-finite")
        // Well past the 0.5 s decay: every sample must be EXACTLY zero, which
        // is a stronger claim than "quiet" and the one that rules out denormals.
        let tail = left[Int(48_000 * 2.0)...]
        #expect(tail.allSatisfy { $0 == 0 },
                "expected exact zeros past the decay; max was \(tail.map { abs($0) }.max() ?? 0)")
    }

    // MARK: - 6. THE MODEL LAYER'S ONE HOME FOR THE NIL LAW

    /// `effectiveDecay`/`effectiveSustain` are what the engine, the wire and
    /// `SamplerGlobalUse` all read. Pinned so a future edit cannot change what
    /// nil means in one place and not the others — which is precisely how a
    /// silent render change would get in.
    @Test("m34-o nil globals resolve to the legacy pair (decay 0, sustain 1)")
    func effectiveGlobalsResolveToLegacyPair() {
        let bare = SamplerParams()
        #expect(bare.decay == nil)
        #expect(bare.sustain == nil)
        #expect(bare.effectiveDecay == 0)
        #expect(bare.effectiveSustain == 1)
        let set = SamplerParams(decay: 3.5, sustain: 0.25)
        #expect(set.effectiveDecay == 3.5)
        #expect(set.effectiveSustain == 0.25)
        // Clamped to the ZONE's domains so a global and an override are
        // expressible over the same range.
        #expect(SamplerParams(decay: 999, sustain: 9).effectiveDecay
                == SamplerZone.decayRange.upperBound)
        #expect(SamplerParams(decay: -5, sustain: -5).effectiveSustain
                == SamplerZone.sustainRange.lowerBound)
    }

    /// `SamplerGlobalUse` must now answer "is this global heard?" for decay and
    /// sustain too. The inert case is the one that matters: an imported library
    /// that authors both fields on every zone makes the instrument knob do
    /// nothing, and a describe verb that did not say so would hand back a
    /// number that looks exactly like a valid answer.
    @Test("m34-o SamplerGlobalUse reports decay/sustain reach, including inert")
    func globalUseReportsDecayAndSustain() throws {
        let fixture = try EnvFixture.url()
        let inheriting = SamplerParams(zones: [envZone(fixture: fixture)], decay: 2, sustain: 0.5)
        let decayUse = SamplerGlobalUse.decay(of: inheriting)
        #expect(decayUse.zonesInheriting == 1)
        #expect(decayUse.zonesOverriding == 0)
        #expect(decayUse.globalIsInert == false)
        #expect(decayUse.effectiveValues == [2])

        let overridden = SamplerParams(
            zones: [envZone(fixture: fixture, decay: 0.25, sustain: 0.75)],
            decay: 2, sustain: 0.5)
        #expect(SamplerGlobalUse.decay(of: overridden).globalIsInert)
        #expect(SamplerGlobalUse.sustain(of: overridden).globalIsInert)
        #expect(SamplerGlobalUse.sustain(of: overridden).effectiveValues == [0.75])

        // With the globals UNSET the fold still has a reach to report — the
        // legacy pair — rather than nothing.
        let bare = SamplerParams(zones: [envZone(fixture: fixture)])
        #expect(SamplerGlobalUse.decay(of: bare).effectiveValues == [0])
        #expect(SamplerGlobalUse.sustain(of: bare).effectiveValues == [1])
    }

    // MARK: - 6. m34-s — THE SAME LAWS, AFTER A SAVE AND A REOPEN

    /// ⛔⛔ THE POINT OF m34-s AT THE LAYER THAT DECIDES IT. Until 2026-08-31
    /// `decay` and `sustain` were absent from `SamplerDocument`'s CodingKeys,
    /// so a patch that faded before a save HELD AT PEAK FOREVER after it: nil
    /// resolves to the legacy pair (0, 1). That is the user's ORIGINAL m34-o
    /// report — "the note keeps playing" — coming back on every reopen.
    ///
    /// ⭐ A restored FIELD is not the claim being made here; a restored SOUND
    /// is. This renders the reopened params and measures the curve, exactly as
    /// `globalDecayFadesHeldNote` does for the un-saved ones.
    @Test("m34-s: a SAVED AND REOPENED global decay still fades the held note")
    func reopenedGlobalDecayStillFadesTheHeldNote() throws {
        let fixture = try EnvFixture.url()
        let saved = SamplerParams(zones: [envZone(fixture: fixture)], attack: 0.005,
                                  release: 0.05, gain: 0.8, decay: 4.0, sustain: 0.0)
        let restored = try reopenThroughTheSaveFormat(saved)
        #expect(restored.decay == 4.0, "the save format dropped the global decay — ROADMAP m34-s")
        #expect(restored.sustain == 0.0, "the save format dropped the global sustain")

        let curve = try heldNoteCurve(params: restored,
                                      label: "REOPENED global decay 4 / sustain 0")
        let first = try #require(curve.first)
        #expect(first > 0.1, "the reopened patch must still SOUND — a dropped zone reddens here")
        for i in 1..<curve.count {
            #expect(curve[i] < curve[i - 1],
                    "not monotonic at window \(i) after a reopen: \(curve[i]) >= \(curve[i - 1])")
        }
        let last = try #require(curve.last)
        #expect(last < 0.01 * first,
                "a REOPENED decay to sustain 0 must still reach the floor: \(last) vs \(first)")
    }

    /// THE COMPAT CONTROL AT THE RENDER LAYER, and as load-bearing as the gate
    /// above: a patch that sets NEITHER global — which is every sampler project
    /// on disk — must still hold FLAT after the round trip. If m34-s had
    /// started writing a value where nil belongs, or resolved an absent key to
    /// anything but (0, 1), this is what catches it, by ear rather than by
    /// reading the field back.
    @Test("m34-s: a SAVED AND REOPENED patch with no globals still holds FLAT")
    func reopenedNilGlobalsStillHoldFlat() throws {
        let fixture = try EnvFixture.url()
        let saved = SamplerParams(zones: [envZone(fixture: fixture)], attack: 0.005,
                                  release: 0.05, gain: 0.8)
        let restored = try reopenThroughTheSaveFormat(saved)
        #expect(restored.decay == nil, "an unset global must reopen unset, not as a stored 0")
        #expect(restored.sustain == nil)
        #expect(restored.effectiveDecay == 0)
        #expect(restored.effectiveSustain == 1)

        let curve = try heldNoteCurve(params: restored, label: "REOPENED nil-everything")
        let first = try #require(curve.first)
        #expect(first > 0.1, "the note must actually sound")
        for (i, value) in curve.enumerated() {
            #expect(abs(value - first) < 0.02 * first,
                    "a reopened legacy patch drooped at window \(i): \(value) vs \(first)")
        }
    }
}
