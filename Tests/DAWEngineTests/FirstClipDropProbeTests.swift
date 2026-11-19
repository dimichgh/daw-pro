import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// FIRST-CLIP-DROP TRIAGE PROBE — not a gate, not product code.
//
// User report (sax team, 2026-08-20): "the first clip in a render of an AU
// instrument track is silently dropped. Clip A was silent until I put a warm-up
// note in front of it, then it played fine."
//
// This probe RECORDS and asserts almost nothing. Its job is to separate three
// hypotheses that predict different LOSS DURATIONS:
//
//   H1 first-quantum event loss — only what lands in quantum 0 is lost
//                                 (10.7 ms at the shipping 512-frame block).
//   H2 lazy sample load          — a whole note, maybe more.
//   H3 clip enumeration          — the whole clip, and it would not be
//                                 AU-specific.
//
// The ladder (onset at frame 0 / 100 / 600 / 24000) is what distinguishes
// them, and the `.polySynth` arm at frame 0 is the cheap discriminator for
// whether the cause is in the hosted-AU path at all.
//
// ⚠️ AN EXTENSION, NOT A NEW `@Suite` — `MainActorOccupancySiteTests` caps
// `@MainActor` suites at 330 and the tree sits exactly on it (m23-aw-4), the
// same reason `BlockRateBounceProbeTests` is an extension. Every test below is
// env-guarded rather than suite-trait-gated for that reason.
//
//   DAWPRO_FIRSTCLIP_PROBE=1 ./scripts/test.sh --filter FirstClipDrop
extension SoundBankHostingTests {
    // 120 BPM at 48 kHz: one beat is exactly 24 000 frames, so a frame index
    // and a beat are the same statement written two ways.
    private static var fcdFramesPerBeat: Double { 24_000 }

    /// The standing gate's render window. The last assertion window closes at
    /// frame 326_400 (6.8 s); this is that plus a short release tail and
    /// nothing more. See the note at the `renderToWAV` call for why the slack
    /// is kept small.
    private static var fcdGateSeconds: Double { 7.2 }

    private func fcdBankTrack(program: Int = 0, clips: [Clip]) -> Track {
        Track(name: "FCD", kind: .instrument, clips: clips,
              instrument: InstrumentDescriptor(
                  kind: .soundBank,
                  soundBank: SoundBankConfig(source: .generalMIDI, program: program,
                                             bankMSB: 121)))
    }

    private func fcdSynthTrack(clips: [Clip]) -> Track {
        Track(name: "FCD-poly", kind: .instrument, clips: clips,
              instrument: InstrumentDescriptor(kind: .polySynth))
    }

    /// One clip starting at `clipStartFrames`, carrying one note whose onset is
    /// `onsetFrames` from the RENDER origin (not from the clip origin — the
    /// render origin is what the ladder is about).
    private func fcdClip(clipStartFrames: Int = 0, onsetFrames: Int,
                         lengthFrames: Int = 24_000, pitch: Int = 60) -> Clip {
        let perBeat = Self.fcdFramesPerBeat
        return Clip(name: "midi", startBeat: Double(clipStartFrames) / perBeat,
                    lengthBeats: 8,
                    notes: [MIDINote(pitch: pitch, velocity: 127,
                                     startBeat: Double(onsetFrames - clipStartFrames) / perBeat,
                                     lengthBeats: Double(lengthFrames) / perBeat)])
    }

    /// Full offline render of one track's LEFT channel. `cooperative` selects
    /// the driver a REAL bounce uses (`AudioEngine.renderOffline` →
    /// `renderCooperatively`), which yields the main actor between quanta —
    /// a seam `render()` does not exercise.
    private func fcdRenderLeft(track: Track, seconds: Double = 2.0,
                               block: Int = RenderBlockSize.offlineFrames,
                               cooperative: Bool = false) async throws -> [Float] {
        let renderer = OfflineRenderer(maximumFrameCount: block)
        await renderer.prepareAudioUnits(tracks: [track])
        let kind = (track.instrument ?? .default).kind
        if kind == .soundBank || kind == .audioUnit {
            let status = renderer.auRegistry.status[track.id]
            // T1's rule: a timed-out prepare renders HONEST SILENCE, which is
            // indistinguishable from the bug in every RMS assertion below.
            // Stop here with one diagnostic rather than mis-report a flake as a
            // reproduction.
            try #require(status == .ready, """
                AU prepare did not reach .ready (\(String(describing: status))) — the render \
                below is silent by construction, NOT by the bug under investigation.
                """)
        }
        let map = TempoMap(constantBPM: 120)
        let audio = cooperative
            ? try await renderer.renderCooperatively(
                tracks: [track], tempoMap: map, fromBeat: 0, durationSeconds: seconds,
                meterMap: MeterMap(constant: TimeSignature()))
            : try renderer.render(
                tracks: [track], tempoMap: map, fromBeat: 0, durationSeconds: seconds)
        return audio.channelData[0]
    }

    /// RMS over the note body, and the peak anywhere in the render — the second
    /// number is what tells "silent note" apart from "silent everything".
    @discardableResult
    private func fcdReport(_ label: String, _ left: [Float], onsetFrames: Int,
                           bodyFrames: Int = 24_000) -> Float {
        let end = min(left.count, onsetFrames + bodyFrames)
        let body: Float = onsetFrames < end
            ? TestSignals.rms(left, in: onsetFrames..<end)
            : 0
        let whole = TestSignals.peak(left, in: 0..<left.count)
        print("[measured] FCD \(label): body RMS[\(onsetFrames),\(end)) = \(body), "
              + "whole-render peak = \(whole)")
        return body
    }

    // MARK: - THE STANDING GATE (not env-guarded — this one runs every time)

    /// ⛔ **THE FIRST CLIP OF A HOSTED-AU TRACK MUST REACH THE BOUNCE FILE.**
    ///
    /// Filed against the 2026-08-20 field report ("the first clip in a render of
    /// an AU instrument track is silently dropped; clip A was silent until I put
    /// a warm-up note in front of it"). The triage below could NOT reproduce it
    /// across 17 conditions, so this is not the fix for a measured defect.
    ///
    /// ⚠️ WHAT WAS ACTUALLY MISSING, stated narrowly so the next reader is not
    /// misled: it is NOT that hosted-AU onset energy was unpinned — `T1` in this
    /// same suite has asserted that since m10-n-1, and the ladder below shows the
    /// class covered at four separate onsets. What no test asserted is
    /// **per-clip presence across a MULTI-CLIP hosted-AU arrangement, measured on
    /// the written file**. That is the gap this closes, and it is the shape the
    /// field report describes.
    ///
    /// Three sax clips in a row, the first starting at beat 2 so there is room
    /// in front of it for the "warm-up note" the reporter added; rendered
    /// through the SHIPPING block size and WRITTEN TO A FILE, because a render
    /// that never reached disk is not the thing the report is about.
    ///
    /// ⭐ THE NEGATIVE CONTROL IS THE LOAD-BEARING HALF. Every arm of the triage
    /// came back sounding, and an all-green measurement is exactly the result
    /// that has to be shown capable of going red: the control renders the SAME
    /// arrangement with the first clip's notes removed and requires that window
    /// to read ~0 while its neighbour still sounds. Without it, a build that
    /// silenced the whole track would still pass the assertions above by
    /// measuring nothing.
    ///
    /// Figures measured on this rig 2026-08-20, at 48 kHz / 120 BPM:
    /// clip0 0.0431, clip1 0.0431, clip2 0.0507; control clip0 exactly 0.0.
    /// The 5e-3 floor is an order of magnitude below the smallest of those and
    /// an order of magnitude above the control's zero.
    @Test("GATE: the FIRST clip of a hosted-AU instrument track reaches the bounce file")
    func firstClipOfAHostedTrackReachesTheFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-firstclip-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let clips = fcdClipRow(count: 3, firstStartBeat: 2, lengthBeats: 4)
        let track = fcdBankTrack(program: 66, clips: clips)
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: [track])
        // A timed-out prepare renders honest silence, which reads identically to
        // the reported bug — stop with one diagnostic rather than three failures
        // blaming the wrong thing (the T1 rule).
        let status = renderer.auRegistry.status[track.id]
        try #require(status == .ready, """
            the GM sax bank did not reach .ready (\(String(describing: status))) — this render \
            is silent by construction, so the assertions below would misreport a prepare \
            timeout as a first-clip drop.
            """)
        let url = dir.appendingPathComponent("first-clip-gate.wav")
        // ⚠️ 7.2 s, NOT the 9.0 s the triage probes use, and the tightness is
        // deliberate: the last window asserted below ends at frame 326_400 =
        // 6.8 s, so every frame past ~7 s is render work that no assertion
        // reads. This gate runs on every suite execution and shares a main
        // actor with the GM prepare path, so unmeasured render seconds are a
        // real cost here in a way they are not in an env-guarded probe.
        _ = try renderer.renderToWAV(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                     masterVolume: 1.0, fromBeat: 0, durationSeconds: Self.fcdGateSeconds,
                                     to: url)
        let left = try fcdFileLeftChannel(url)

        for (index, clip) in clips.enumerated() {
            let onset = Int(clip.startBeat * Self.fcdFramesPerBeat)
            let end = min(left.count, onset + Int(clip.lengthBeats * 0.9 * Self.fcdFramesPerBeat))
            let rms = TestSignals.rms(left, in: onset..<end)
            print("[measured] FCD GATE clip\(index) [\(onset),\(end)) file RMS = \(rms)")
            #expect(rms > 5e-3, """
                clip\(index) is missing from the bounce FILE (RMS \(rms)) — this is the shape \
                of the 2026-08-20 field report.
                """)
        }

        // ⭐ NEGATIVE CONTROL — same arrangement, first clip emptied.
        //
        // ⚠️ SAME RENDERER, SAME TRACK ID, DELIBERATELY. A second
        // `OfflineRenderer` would load the GM bank a SECOND time, and that is
        // not free: measured under full-suite parallel load this gate cost
        // 28.7 s with two loads against 0.12 s isolated, on the very main actor
        // whose contention already makes `AUPrepareRenegotiationStressTests`
        // flaky. `AUHostRegistry.prepareKey` keys `.soundBank` on component +
        // rate + bank ADDRESS — clips are not in it — so re-preparing the same
        // track id with different clips short-circuits on the idempotency guard
        // and the loaded AU is reused. The AU carrying voice state across the
        // two renders is harmless here: every note in arm 1 releases by beat
        // 13.6, inside the 14.4-beat window.
        var controlTrack = track
        controlTrack.clips[0].notes = []
        await renderer.prepareAudioUnits(tracks: [controlTrack])   // no-op by identity
        let controlURL = dir.appendingPathComponent("first-clip-control.wav")
        _ = try renderer.renderToWAV(
            tracks: [controlTrack], tempoMap: TempoMap(constantBPM: 120),
            masterVolume: 1.0, fromBeat: 0, durationSeconds: Self.fcdGateSeconds, to: controlURL)
        let controlLeft = try fcdFileLeftChannel(controlURL)
        let silentWindow = TestSignals.rms(controlLeft, in: 48_000..<134_400)
        let soundingWindow = TestSignals.rms(controlLeft, in: 144_000..<230_400)
        print("[measured] FCD GATE control: emptied clip0 \(silentWindow), clip1 \(soundingWindow)")
        #expect(silentWindow < 1e-4,
                "the control cannot see a silent first clip — the assertions above are vacuous")
        #expect(soundingWindow > 5e-3)
    }

    /// Reads a rendered WAV's left channel back off disk. The gate asserts on
    /// the FILE, not on the in-memory buffer: the report is about what a bounce
    /// contains.
    private func fcdFileLeftChannel(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let data = try #require(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    // MARK: - The ladder

    @Test("TRIAGE ladder: hosted-AU note onset at frame 0 / 100 / 600 / 24000")
    func firstClipOnsetLadder() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        for onset in [0, 100, 600, 24_000] {
            let track = fcdBankTrack(clips: [fcdClip(onsetFrames: onset)])
            _ = fcdReport("soundBank gm0, onset \(onset), block 512",
                          try await fcdRenderLeft(track: track), onsetFrames: onset)
        }
    }

    @Test("TRIAGE discriminator: built-in polySynth at the same onsets")
    func firstClipOnsetLadderPolySynth() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        for onset in [0, 100, 600, 24_000] {
            let track = fcdSynthTrack(clips: [fcdClip(onsetFrames: onset)])
            _ = fcdReport("polySynth, onset \(onset), block 512",
                          try await fcdRenderLeft(track: track), onsetFrames: onset)
        }
    }

    @Test("TRIAGE: block size 4096 vs 512 at onset 0 (does m28-bug matter?)")
    func firstClipBlockComparison() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        for block in [4_096, 512] {
            let track = fcdBankTrack(clips: [fcdClip(onsetFrames: 0)])
            _ = fcdReport("soundBank gm0, onset 0, block \(block)",
                          try await fcdRenderLeft(track: track, block: block), onsetFrames: 0)
        }
    }

    @Test("TRIAGE: four notes in ONE clip — is it the note or the clip that dies?")
    func firstClipFourNoteBreakdown() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        let clip = Clip(name: "midi", startBeat: 0, lengthBeats: 8,
                        notes: (0..<4).map { beat in
                            MIDINote(pitch: 60 + beat * 3, velocity: 127,
                                     startBeat: Double(beat), lengthBeats: 0.9)
                        })
        let left = try await fcdRenderLeft(track: fcdBankTrack(clips: [clip]), seconds: 3.0)
        for beat in 0..<4 {
            _ = fcdReport("soundBank gm0, 4-note clip, note \(beat) (beat \(beat))",
                          left, onsetFrames: beat * 24_000, bodyFrames: 21_600)
        }
    }

    @Test("TRIAGE: the REAL bounce driver (renderCooperatively) at onset 0")
    func firstClipCooperativeDriver() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        for onset in [0, 24_000] {
            let track = fcdBankTrack(clips: [fcdClip(onsetFrames: onset)])
            _ = fcdReport("soundBank gm0, COOPERATIVE, onset \(onset)",
                          try await fcdRenderLeft(track: track, cooperative: true),
                          onsetFrames: onset)
        }
    }

    // MARK: - Sweep 2: the conditions the ladder did NOT have

    /// N clips in a row on ONE track, each carrying one note at its own start.
    /// `firstStartBeat` leaves room in front so a "warm-up note" has somewhere
    /// to go — the tester's arrangement cannot have had clip A at beat 0.
    private func fcdClipRow(count: Int, firstStartBeat: Double, lengthBeats: Double,
                            lane: Bool = false) -> [Clip] {
        (0..<count).map { index in
            let start = firstStartBeat + Double(index) * lengthBeats
            let lanes: [MIDIControllerLane] = lane
                ? [MIDIControllerLane(type: .cc(controller: 11), points: (0...8).map {
                    MIDIControllerPoint(beat: Double($0) * lengthBeats / 8,
                                        value: 60 + $0 * 8)
                })]
                : []
            return Clip(name: "clip\(index)", startBeat: start, lengthBeats: lengthBeats,
                        notes: [MIDINote(pitch: 62 + index * 2, velocity: 100,
                                         startBeat: 0, lengthBeats: lengthBeats * 0.9)],
                        controllerLanes: lanes)
        }
    }

    private func fcdReportRow(_ label: String, _ left: [Float], clips: [Clip]) {
        for clip in clips {
            let onset = Int(clip.startBeat * Self.fcdFramesPerBeat)
            let body = Int(clip.lengthBeats * 0.9 * Self.fcdFramesPerBeat)
            fcdReport("\(label) — \(clip.name)", left, onsetFrames: onset, bodyFrames: body)
        }
    }

    @Test("TRIAGE sweep: three clips in a row, first at beat 0 and first at beat 2")
    func firstClipMultiClipRow() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        for firstStart in [0.0, 2.0] as [Double] {
            let clips = fcdClipRow(count: 3, firstStartBeat: firstStart, lengthBeats: 4)
            let left = try await fcdRenderLeft(track: fcdBankTrack(program: 66, clips: clips),
                                               seconds: 9.0)
            fcdReportRow("sax gm66, 3 clips from beat \(firstStart)", left, clips: clips)
        }
    }

    @Test("TRIAGE sweep: three clips WITH CC11 breath lanes (the chase prefix is live)")
    func firstClipMultiClipWithLanes() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        let clips = fcdClipRow(count: 3, firstStartBeat: 2, lengthBeats: 4, lane: true)
        let left = try await fcdRenderLeft(track: fcdBankTrack(program: 66, clips: clips),
                                           seconds: 9.0)
        fcdReportRow("sax gm66, 3 clips + CC11 lanes", left, clips: clips)
    }

    @Test("TRIAGE sweep: region render from beat 2 (fromBeat > 0, the chase path)")
    func firstClipRegionRender() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        let clips = fcdClipRow(count: 3, firstStartBeat: 2, lengthBeats: 4)
        let track = fcdBankTrack(program: 66, clips: clips)
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: [track])
        try #require(renderer.auRegistry.status[track.id] == .ready)
        let audio = try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                        fromBeat: 2, durationSeconds: 8.0)
        let left = audio.channelData[0]
        // Frames are now relative to beat 2.
        for (index, clip) in clips.enumerated() {
            let onset = Int((clip.startBeat - 2) * Self.fcdFramesPerBeat)
            fcdReport("sax gm66, fromBeat 2, clip\(index)", left,
                      onsetFrames: onset, bodyFrames: Int(3.6 * Self.fcdFramesPerBeat))
        }
    }

    @Test("TRIAGE sweep: two hosted tracks in one render")
    func firstClipTwoHostedTracks() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        let clips = fcdClipRow(count: 2, firstStartBeat: 2, lengthBeats: 4)
        let a = fcdBankTrack(program: 66, clips: clips)
        let b = fcdBankTrack(program: 0, clips: clips)
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: [a, b])
        try #require(renderer.auRegistry.status[a.id] == .ready)
        try #require(renderer.auRegistry.status[b.id] == .ready)
        let audio = try renderer.render(tracks: [a, b], tempoMap: TempoMap(constantBPM: 120),
                                        fromBeat: 0, durationSeconds: 7.0)
        fcdReportRow("two hosted tracks", audio.channelData[0], clips: clips)
    }

    @Test("TRIAGE sweep: hosted instrument behind an insert effect (PDC live)")
    func firstClipWithInsertEffect() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        let clips = fcdClipRow(count: 3, firstStartBeat: 2, lengthBeats: 4)
        var track = fcdBankTrack(program: 66, clips: clips)
        track.effects = [EffectDescriptor(kind: .reverb)]
        let left = try await fcdRenderLeft(track: track, seconds: 9.0)
        fcdReportRow("sax gm66 + reverb insert", left, clips: clips)
    }

    @Test("TRIAGE sweep: `.audioUnit` kind (raw AUSampler, no bank load)")
    func firstClipRawAudioUnitKind() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        let clips = fcdClipRow(count: 3, firstStartBeat: 2, lengthBeats: 4)
        let track = Track(
            name: "RawAU", kind: .instrument, clips: clips,
            instrument: InstrumentDescriptor(
                kind: .audioUnit,
                audioUnit: AudioUnitConfig(component: AudioUnitComponentID(
                    subType: "samp", manufacturer: "appl"))))
        let left = try await fcdRenderLeft(track: track, seconds: 9.0)
        fcdReportRow("raw AUSampler `.audioUnit`", left, clips: clips)
    }

    /// ⭐ NEGATIVE CONTROL. Every arm above reported energy, and an absence
    /// that confirms "no bug here" is exactly the result that has to be
    /// positive-controlled: `fcdReport` must be able to READ A SILENT CLIP.
    /// Clip 0 carries no notes at all; clips 1 and 2 are unchanged.
    @Test("TRIAGE control: an empty first clip MUST read ~0 (can the probe see silence?)")
    func firstClipProbeCanSeeSilence() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        var clips = fcdClipRow(count: 3, firstStartBeat: 2, lengthBeats: 4)
        clips[0].notes = []
        let left = try await fcdRenderLeft(track: fcdBankTrack(program: 66, clips: clips),
                                           seconds: 9.0)
        fcdReportRow("CONTROL, clip0 has NO notes", left, clips: clips)
        let silent = TestSignals.rms(left, in: 48_000..<134_400)
        let sounding = TestSignals.rms(left, in: 144_000..<230_400)
        #expect(silent < 1e-4, "the probe cannot distinguish a silent clip — every arm above is void")
        #expect(sounding > 1e-3)
    }

    /// The literal "AU instrument track": `.audioUnit` kind hosting AUSampler
    /// with a `stateData` blob, which is what `tracksWithLiveAudioUnitState`
    /// injects into every bounce of such a track (m23-bx-1). The state is
    /// captured from a REAL bank-loaded sampler so the restore has actual
    /// sample references to chase — an empty state would restore instantly and
    /// prove nothing.
    @Test("TRIAGE: `.audioUnit` AUSampler with RESTORED live state — onset ladder")
    func firstClipRestoredAudioUnitState() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        // 1. A bank-loaded sampler, exactly as a `.soundBank` track owns one.
        let sourceRegistry = AUHostRegistry()
        let sourceTrack = fcdBankTrack(program: 66, clips: [])
        await sourceRegistry.prepare(track: sourceTrack, sampleRate: 48_000)
        try #require(sourceRegistry.status[sourceTrack.id] == .ready)
        let state = sourceRegistry.instrumentState(forTrack: sourceTrack.id)
        print("[measured] FCD captured AUSampler fullStateForDocument: "
              + "\(state.map { "\($0.count) bytes" } ?? "nil")")
        let stateData = try #require(state)

        // 2. Render that state on a fresh `.audioUnit` track, notes at four
        // onsets so a warm-up window shows up as a boundary rather than a
        // single silent arm.
        for onset in [0, 24_000, 48_000, 96_000] {
            let track = Track(
                name: "RestoredAU", kind: .instrument,
                clips: [fcdClip(onsetFrames: onset, lengthFrames: 24_000, pitch: 62)],
                instrument: InstrumentDescriptor(
                    kind: .audioUnit,
                    audioUnit: AudioUnitConfig(
                        component: AudioUnitComponentID(subType: "samp", manufacturer: "appl"),
                        stateData: stateData)))
            _ = fcdReport("restored-state `.audioUnit`, onset \(onset)",
                          try await fcdRenderLeft(track: track, seconds: 4.0),
                          onsetFrames: onset)
        }
    }

    @Test("TRIAGE: the tester's shape — sax program 66, first clip vs warm-up note")
    func firstClipSaxWarmup() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        // Clip A alone: a sax entry at the very top of the render.
        let bare = fcdBankTrack(program: 66, clips: [fcdClip(onsetFrames: 0, lengthFrames: 48_000)])
        _ = fcdReport("sax gm66, bare first clip at frame 0",
                      try await fcdRenderLeft(track: bare, seconds: 3.0), onsetFrames: 0,
                      bodyFrames: 48_000)

        // Same clip with a throwaway note in front of it, inside the same clip.
        let warm = Clip(name: "midi", startBeat: 0, lengthBeats: 8, notes: [
            MIDINote(pitch: 48, velocity: 1, startBeat: 0, lengthBeats: 0.05),
            MIDINote(pitch: 60, velocity: 127, startBeat: 0.25, lengthBeats: 2),
        ])
        let warmLeft = try await fcdRenderLeft(track: fcdBankTrack(program: 66, clips: [warm]),
                                               seconds: 3.0)
        _ = fcdReport("sax gm66, warm-up note then the entry at frame 6000",
                      warmLeft, onsetFrames: 6_000, bodyFrames: 48_000)
    }
}
