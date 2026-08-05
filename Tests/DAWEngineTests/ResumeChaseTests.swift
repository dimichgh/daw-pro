import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m23-cd — PAUSE → RESUME MUST SOUND A HELD NOTE.
//
// THE USER'S REPORT (2026-08-04, verbatim): "if I pause and then resume the
// sound stops coming for the current quarter and only comes back as it moves to
// another quarter... it only loses sound on track 'Atmospheric Pad' which has
// very long bars." THE RULING (same day, verbatim): "for 1st one lets do what
// other DAWs do" — chase held notes on resume, matching Logic/Ableton/Cubase.
//
// WHY THE PAD LOOKED SPECIAL AND WAS NOT: the no-chase contract is GLOBAL. A pad
// holding whole-bar notes has minutes between onsets; drums re-trigger every
// beat and hide the gap entirely. Nothing here is track- or instrument-scoped.
//
// WHAT THIS FILE PROVES THAT THE OTHER THREE m23-bp/cd SUITES DO NOT:
//
//  · `NoteChaseScheduleTests` pins the BUILD MATH frame-exact (no engine).
//  · `NoteChaseGraphTests` G-L1 proves a `.continuation` build is AUDIBLE — but
//    it schedules ONCE, into a fresh graph. It never stops a rolling graph.
//  · `NoteChaseSiteTests` pins the WIRING as source text — no audio at all.
//  · THIS FILE renders the user's actual gesture: play → render → STOP the
//    rolling players (which queues `instrument.reset()` for the top of the next
//    render quantum, killing every sounding voice — design-m23bp §1.2, the other
//    half of the mechanism) → render the silent pause → reschedule from the stop
//    beat → start again → render. Silence vs sound is MEASURED across that seam.
//
// THE ARM UNDER TEST READS ITS CAUSE FROM PRODUCTION SOURCE. It does not
// hard-code `.transportStart`: it parses what `AudioEngine.startPlayback`
// actually passes and renders with THAT. Reverting the site to `.relocation`
// therefore reddens this file with an AUDIBLE measurement, not only the source
// pin — the chain "site → cause → audible" is machine-checked end to end
// instead of resting on three separately-green suites and a paragraph.
//
// THREE CONTROLS, because "the chase arm is silent" and "the rig is broken" are
// otherwise the same observation:
//   · PRE-PAUSE window — audible in BOTH arms (the graph really was playing).
//   · PAUSE window — silent in BOTH arms (the stop really did cut the voice, so
//     the post-resume sound cannot be a leftover ring).
//   · POST-MARKER window — audible in BOTH arms (a note whose onset is AFTER the
//     resume beat is unaffected by chase policy; the v0 arm's silence is
//     confined to the held note, which is the defect and nothing else).
//
// 48 kHz, 120 BPM ⇒ 1 beat = 24 000 frames = 0.5 s.

private let rcRate = 48_000.0
private let rcQuantum = 512
private let rcBeatFrames = 24_000

// MARK: - Offline pause/resume rig (the NoteChaseRig idiom, extended)

@MainActor
private struct ResumeRig {
    let engine: AVAudioEngine
    let graph: PlaybackGraph
    let tempoMap: TempoMap
    private let tracks: [Track]

    /// Starts playback from `fromBeat` exactly as `AudioEngine.startPlayers`
    /// does: schedule → prepare → start.
    init(tracks: [Track], tempoMap: TempoMap, fromBeat: Double,
         cause: RescheduleCause) throws {
        self.tracks = tracks
        self.tempoMap = tempoMap
        engine = AVAudioEngine()
        graph = PlaybackGraph(engine: engine)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: rcRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        #expect(graph.reconcile(tracks: tracks))
        graph.applyParameters(tracks: tracks)
        try engine.start()
        graph.applyParameters(tracks: tracks)
        graph.scheduleAll(fromBeat: fromBeat, tempoMap: tempoMap, cause: cause)
        graph.prepareAllPlayers(withFrameCount: 8_192)
        graph.startAllPlayers(at: nil)
    }

    /// THE PAUSE. `ProjectStore.stop()` → `AudioEngine.stopPlayback()` →
    /// `graph.stopAllPlayers()`; the transport keeps its position
    /// (`stopPlayback` pushes one final `playheadHandler?(beats)`), which is why
    /// the resume below re-enters at the SAME beat.
    func pause() {
        graph.stopAllPlayers()
    }

    /// THE RESUME. `ProjectStore.play()` → `AudioEngine.startPlayback()` →
    /// `startPlayers(fromBeat: transport.positionBeats, cause: <under test>)`.
    func resume(atBeat beat: Double, cause: RescheduleCause) {
        graph.applyParameters(tracks: tracks)
        graph.scheduleAll(fromBeat: beat, tempoMap: tempoMap, cause: cause)
        graph.prepareAllPlayers(withFrameCount: 8_192)
        graph.startAllPlayers(at: nil)
    }

    func render(frames: Int, into channelData: inout [[Float]]) throws {
        let format = engine.manualRenderingFormat
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        var rendered = 0
        while rendered < frames {
            let request = AVAudioFrameCount(min(frames - rendered, rcQuantum))
            let status = try engine.renderOffline(request, to: buffer)
            try #require(status == .success)
            let source = try #require(buffer.floatChannelData)
            let count = Int(buffer.frameLength)
            for channel in 0..<2 {
                channelData[channel].append(contentsOf:
                    UnsafeBufferPointer(start: source[channel], count: count))
            }
            rendered += count
        }
    }
}

private func rcRMS(_ channelData: [[Float]], _ range: Range<Int>) -> Double {
    guard !range.isEmpty, channelData[0].count >= range.upperBound else { return .nan }
    var sum = 0.0
    for frame in range { sum += Double(channelData[0][frame]) * Double(channelData[0][frame]) }
    return (sum / Double(range.count)).squareRoot()
}

private func rcNaNCount(_ channelData: [[Float]]) -> Int {
    channelData.reduce(0) { $0 + $1.lazy.filter { $0.isNaN || $0.isInfinite }.count }
}

/// Writes the rendered segment to a real .wav and reads it BACK — the render is
/// asserted from decoded file samples, not only from the in-memory array.
private func rcWriteAndReadBackWAV(_ channelData: [[Float]], to url: URL) throws -> [[Float]] {
    let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: rcRate, channels: 2))
    let frames = channelData[0].count
    let writeBuffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    writeBuffer.frameLength = AVAudioFrameCount(frames)
    let target = try #require(writeBuffer.floatChannelData)
    for channel in 0..<2 {
        channelData[channel].withUnsafeBufferPointer { source in
            target[channel].update(from: source.baseAddress!, count: frames)
        }
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: rcRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
    ]
    // ⚠️ THE WRITER MUST GO OUT OF SCOPE BEFORE THE READ. An `AVAudioFile` open
    // for writing finalizes its header on deinit; reading while it is still
    // alive yields `length == 0` and a -50 (frameCapacity != 0) throw from the
    // read buffer — measured, not theorized.
    func writeFile() throws {
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: writeBuffer)
    }
    try writeFile()

    let reader = try AVAudioFile(forReading: url)
    let readBuffer = try #require(
        AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                         frameCapacity: AVAudioFrameCount(reader.length)))
    try reader.read(into: readBuffer)
    let source = try #require(readBuffer.floatChannelData)
    let count = Int(readBuffer.frameLength)
    var out: [[Float]] = [[], []]
    for channel in 0..<2 {
        out[channel] = Array(UnsafeBufferPointer(start: source[channel], count: count))
    }
    return out
}

// MARK: - The production wiring, read as source

/// THE CAUSE `AudioEngine.startPlayback` ACTUALLY PASSES.
///
/// Parsed, never assumed: this file's whole claim is that the USER'S PLAY BUTTON
/// now sounds a held note, and a hard-coded `.transportStart` would prove only
/// that the enum works. `NoteChaseSiteTests` pins the same fact as an ordered
/// sequence; this reads it back as behaviour.
@MainActor
private func causePassedByStartPlayback() -> RescheduleCause? {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let fm = FileManager.default
    var engineDir: URL?
    for _ in 0..<12 {
        let candidate = dir.appendingPathComponent("Sources/DAWEngine", isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
            engineDir = candidate
            break
        }
        dir = dir.deletingLastPathComponent()
    }
    guard let engineDir,
          let content = try? String(contentsOf: engineDir.appendingPathComponent("AudioEngine.swift"),
                                    encoding: .utf8) else {
        Issue.record("could not read Sources/DAWEngine/AudioEngine.swift from \(#filePath)")
        return nil
    }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let start = lines.firstIndex(where: {
        $0.contains("public func startPlayback(")
    }) else {
        Issue.record("`public func startPlayback(` not found — this parser is stale, not the code")
        return nil
    }
    for index in (start + 1)..<lines.count {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Stop at the next top-level member: the cause must come from INSIDE
        // startPlayback, never from whatever follows it.
        if index > start, line.hasPrefix("    "), !line.hasPrefix("     "),
           trimmed.contains("func "), !trimmed.hasPrefix("//") {
            break
        }
        guard !trimmed.hasPrefix("//") else { continue }
        for (token, cause): (String, RescheduleCause) in [
            ("relocation", .relocation),
            ("continuation", .continuation),
            ("transportStart", .transportStart),
        ] where trimmed.contains("cause: .\(token)") {
            print("[measured] startPlayback passes cause: .\(token) (AudioEngine.swift:\(index + 1))")
            return cause
        }
    }
    Issue.record("`startPlayback` states no `cause:` — the parameter must have regained a default")
    return nil
}

// MARK: - The gesture

@MainActor
@Suite("Resume chase — the pause/resume seam, offline (m23-cd)", .serialized)
struct ResumeChaseTests {

    /// A pad holding one very long note (the user's "very long bars"), plus a
    /// MARKER note whose onset is AFTER the resume beat. The marker is the
    /// anti-vacuity control: chase policy cannot touch it, so it must sound in
    /// both arms or the rig — not the fix — is what is being measured.
    private func padWithLaterMarker() -> Track {
        Track(name: "Atmospheric Pad", kind: .instrument, clips: [
            Clip(name: "held", startBeat: 0, lengthBeats: 64, notes: [
                MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 64),
                MIDINote(pitch: 72, velocity: 100, startBeat: 3, lengthBeats: 1),
            ]),
        ])
    }

    /// Renders play(0) → 1 beat → PAUSE → 0.5 beat of silence → RESUME(beat 2)
    /// → 2 beats, and returns the three measured windows.
    private func measureGesture(resumeCause: RescheduleCause)
        throws -> (prePause: Double, pause: Double, held: Double, marker: Double,
                   resumeSegment: [[Float]], nonFinite: Int) {
        let resumeBeat = 2.0
        let playFrames = 2 * rcBeatFrames        // beats 0…2
        let pauseFrames = rcBeatFrames / 2       // wall time only; the beat does not move
        let resumeFrames = 2 * rcBeatFrames      // beats 2…4

        let rig = try ResumeRig(tracks: [padWithLaterMarker()],
                                tempoMap: TempoMap(constantBPM: 120),
                                fromBeat: 0, cause: .transportStart)
        var playing: [[Float]] = [[], []]
        try rig.render(frames: playFrames, into: &playing)

        rig.pause()
        var paused: [[Float]] = [[], []]
        try rig.render(frames: pauseFrames, into: &paused)

        rig.resume(atBeat: resumeBeat, cause: resumeCause)
        var resumed: [[Float]] = [[], []]
        try rig.render(frames: resumeFrames, into: &resumed)
        rig.engine.stop()

        // Windows, in RESUME-segment frames. The marker's onset is beat 3 =
        // 1 beat = 24 000 frames after the resume, so:
        //   held   [2 400, 22 000)  — 50 ms of attack skipped, ends before the
        //                             marker: ONLY the chased pad can sound here
        //   marker [26 400, 46 000) — inside the marker note [beat 3, beat 4)
        let heldWindow = 2_400..<22_000
        let markerWindow = 26_400..<46_000
        return (prePause: rcRMS(playing, 2_400..<playFrames),
                pause: rcRMS(paused, 1_200..<pauseFrames),
                held: rcRMS(resumed, heldWindow),
                marker: rcRMS(resumed, markerWindow),
                resumeSegment: resumed,
                nonFinite: rcNaNCount(playing) + rcNaNCount(paused) + rcNaNCount(resumed))
    }

    /// THE TEST. Both arms in ONE run so a broken rig cannot pass as a finding.
    @Test("m23-cd: resuming inside a held note SOUNDS it; the v0 no-chase arm is silent")
    func resumeSoundsTheHeldNote() throws {
        let production = try #require(causePassedByStartPlayback(),
                                      "could not read startPlayback's cause from source")

        let fixed = try measureGesture(resumeCause: production)
        let v0 = try measureGesture(resumeCause: .relocation)

        print("""
              [measured] m23-cd pause/resume RMS —
                production(\(production)) prePause \(fixed.prePause) pause \(fixed.pause) \
              held \(fixed.held) marker \(fixed.marker)
                v0(.relocation)          prePause \(v0.prePause) pause \(v0.pause) \
              held \(v0.held) marker \(v0.marker)
                nonFinite \(fixed.nonFinite + v0.nonFinite)
              """)

        // CONTROL 1 — the graph really was playing before the pause.
        #expect(fixed.prePause > 1e-3)
        #expect(v0.prePause > 1e-3)

        // CONTROL 2 — the pause really cut the voice, so anything measured after
        // the resume is NEW sound, never a leftover ring.
        #expect(fixed.pause < 1e-4)
        #expect(v0.pause < 1e-4)

        // CONTROL 3 — a note whose onset is AFTER the resume beat is untouched
        // by chase policy: audible in BOTH arms.
        #expect(fixed.marker > 1e-3)
        #expect(v0.marker > 1e-3)

        // THE DEFECT, AND THE FIX. Same gesture, same rig, same run.
        let whyControl = "the v0 control stopped being silent — this arm IS the user's bug and "
            + "it must still reproduce, or the comparison above proves nothing"
        #expect(v0.held < 1e-6, "\(whyControl)")
        let whyFix = "resuming inside a held note is still SILENT. `AudioEngine.startPlayback` "
            + "passes cause: .\(production), whose chasesHeldNotes is "
            + "\(production.chasesHeldNotes) — m23-cd requires the play button to chase "
            + "(user ruling 2026-08-04)."
        #expect(fixed.held > 1e-3, "\(whyFix)")

        // Denormal / NaN guard across the whole gesture, both arms.
        #expect(fixed.nonFinite == 0)
        #expect(v0.nonFinite == 0)
    }

    /// The same fixed arm, ROUND-TRIPPED THROUGH A REAL .WAV. An in-memory float
    /// array is one assertion away from the code that produced it; decoded file
    /// samples are the artefact a human could open and listen to.
    @Test("m23-cd: the resumed segment survives a wav round-trip and still sounds")
    func resumedSegmentIsAudibleFromDisk() throws {
        let production = try #require(causePassedByStartPlayback())
        let fixed = try measureGesture(resumeCause: production)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m23cd-resume-\(UUID().uuidString.prefix(8)).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let decoded = try rcWriteAndReadBackWAV(fixed.resumeSegment, to: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? Int) ?? 0
        let heldFromDisk = rcRMS(decoded, 2_400..<22_000)
        let markerFromDisk = rcRMS(decoded, 26_400..<46_000)
        print("[measured] m23-cd wav \(url.lastPathComponent): \(bytes) bytes, "
              + "\(decoded[0].count) frames, held RMS \(heldFromDisk), marker RMS \(markerFromDisk)")

        #expect(decoded[0].count == fixed.resumeSegment[0].count)
        #expect(bytes > 0)
        #expect(heldFromDisk > 1e-3)     // the held note, read back off disk
        #expect(markerFromDisk > 1e-3)   // and the anti-vacuity marker with it
        #expect(rcNaNCount(decoded) == 0)
    }
}
