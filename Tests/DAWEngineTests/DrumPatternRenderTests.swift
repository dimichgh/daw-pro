import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m39-w4-10 — the drum patterns' PHYSICS gates, by render.
// Design `docs/design/2026-10-07-loop-drum-depth.md` §9.2 (P1, P2) and §10.2 L2.
//
//  - P1 layout independence: the same pattern, written through the store onto a `pads` drum machine and a
//    `gm` drum machine (otherwise the same kit), renders BYTE-IDENTICALLY. The written notes must differ
//    (else equality is trivial), both renders must sound, and a pads kit fed the GM notes must NOT match
//    (the comparison can fail).
//  - P2: "four on the floor" — kick onsets, found on the kick-isolated render, sit on every beat within one
//    frame of the scheduled sample plus the kick's own lag at beat 0. The method checks its own premise
//    (silence before each onset) and is shown to catch a kick moved by three frames.
//  - True peak: every pattern on a NEW drum machine (kit gain 0.7) at fader 1.0, on a new song's pan law,
//    stays at or under -1 dBTP; the meter is shown able to read over it.
//  - L2: the first pattern IS the listening material the user picked from (`W4LBeats.l2`).
//
// nonisolated suite: the store and the offline renderer are `@MainActor`, so they run inside
// `DrumPatternRenderStage` (the `DrumDefStage` precedent). No new `@MainActor` suite.

@MainActor
enum DrumPatternRenderStage {
    /// A song with ONE drum-machine track on exactly `kit`, fader 1.0, `pattern` written through the store.
    /// ⚠️ `kind: .drumSynth` is set explicitly: a stored kit alone would leave the poly synth playing.
    static func song(kit: DrumKitParams, pattern: String, bars: Int?, bpm: Double) throws
        -> (store: ProjectStore, written: DrumPatternWriteResult) {
        let store = ProjectStore(projectName: "W9-PAT render \(pattern)")
        try store.setTempo(bpm)
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        _ = try store.setInstrument(id: id, kind: .drumSynth, drumKit: kit)
        _ = store.setTrackVolume(id: id, volume: 1.0)
        let track = try #require(store.tracks.first { $0.id == id })
        #expect(track.instrument?.kind == .drumSynth)
        #expect(track.instrument?.drumKit == kit, "the track must hold exactly the kit under test")
        #expect(track.volume == 1.0)
        return (store, try store.addDrumPattern(named: pattern, toTrack: id, bars: bars))
    }

    static func render(_ store: ProjectStore, tracks: [Track]? = nil, seconds: Double,
                       panLaw: PanLaw = .balance) throws -> RenderedAudio {
        let renderer = OfflineRenderer()
        renderer.panLaw = panLaw
        return try renderer.render(tracks: tracks ?? store.tracks, tempoMap: store.transport.tempoMap,
                                   fromBeat: 0, durationSeconds: seconds,
                                   masterVolume: store.masterVolume, masterEffects: store.masterEffects,
                                   meterMap: store.transport.meterMap)
    }

    /// The song's tracks with the one clip's notes replaced by `notes`.
    static func tracks(_ store: ProjectStore, notes: [MIDINote]) throws -> [Track] {
        var tracks = store.tracks
        #expect(tracks.count == 1 && tracks[0].clips.count == 1)
        tracks[0].clips[0].notes = notes
        return tracks
    }
}

@Suite("Drum patterns — render physics, P1/P2/true peak/L2 (m39-w4-10)", .serialized)
struct DrumPatternRenderTests {

    static func bits(_ audio: RenderedAudio) -> [UInt32] { audio.channelData.flatMap { $0.map(\.bitPattern) } }

    static func peak(_ audio: RenderedAudio) -> Float {
        audio.channelData.map { $0.map { abs($0) }.max() ?? 0 }.max() ?? 0
    }

    /// The loudest absolute sample over both channels at each frame.
    static func envelope(_ audio: RenderedAudio) -> [Float] {
        var out = [Float](repeating: 0, count: audio.frameCount)
        for channel in audio.channelData {
            for (i, x) in channel.enumerated() where abs(x) > out[i] { out[i] = abs(x) }
        }
        return out
    }

    /// The pads twin of a kit: identical but for which note plays which drum.
    static func padsTwin(of kit: DrumKitParams) -> DrumKitParams {
        var twin = kit
        twin.noteLayout = .pads
        return twin
    }

    // MARK: - P1

    @Test("P1: every pattern renders byte-identically on a pads drum machine and a General MIDI one",
          arguments: DrumPatternLibrary.patterns.map(\.id))
    func layoutIndependence(patternID: String) async throws {
        let gmKit = DrumKitParams.newDrumMachineKit
        let padsKit = Self.padsTwin(of: gmKit)
        #expect(gmKit.noteLayout == .gm && padsKit.noteLayout == .pads && gmKit != padsKit)
        let seconds = 5.0   // two bars at 120 BPM, plus a one-second tail

        let (gmAudio, padsAudio, crossAudio, gmPitches, padsPitches) = try await MainActor.run {
            let gm = try DrumPatternRenderStage.song(kit: gmKit, pattern: patternID, bars: 2, bpm: 120)
            let pads = try DrumPatternRenderStage.song(kit: padsKit, pattern: patternID, bars: 2, bpm: 120)
            let gmNotes = gm.written.clip.notes ?? []
            // The control: the pads kit fed the GENERAL MIDI notes (what a fixed GM table would write).
            let cross = try DrumPatternRenderStage.render(
                pads.store, tracks: try DrumPatternRenderStage.tracks(pads.store, notes: gmNotes), seconds: seconds)
            return (try DrumPatternRenderStage.render(gm.store, seconds: seconds),
                    try DrumPatternRenderStage.render(pads.store, seconds: seconds),
                    cross,
                    gmNotes.map(\.pitch), (pads.written.clip.notes ?? []).map(\.pitch))
        }
        #expect(gmPitches.count == padsPitches.count && !gmPitches.isEmpty)
        #expect(gmPitches != padsPitches, "\(patternID): the two kits got the same notes, so equality proves nothing")
        #expect(Self.peak(gmAudio) > 0.01, "\(patternID): the General MIDI render is silent")
        #expect(Self.peak(padsAudio) > 0.01, "\(patternID): the pads render is silent")
        // ⚠️ Arrays compared OUTSIDE `#expect` (a failing macro diffs whole buffers: 479 s, W8 measured).
        let identical = Self.bits(gmAudio) == Self.bits(padsAudio)
        #expect(identical, "\(patternID): pads and General MIDI drum machines render different bytes")
        let crossMatches = Self.bits(crossAudio) == Self.bits(padsAudio)
        #expect(!crossMatches, "\(patternID): a pads kit fed General MIDI notes matched; the gate cannot fail")
        print("[W9-PAT P1] \(patternID): identical=\(identical) crossDiffers=\(!crossMatches) "
              + "peak=\(Self.peak(gmAudio)) frames=\(gmAudio.frameCount)")
    }

    // MARK: - P2

    /// Kick onsets on a kick-only render: for each expected frame, the first frame within the window whose
    /// level passes `threshold`, with the premise (silence just before the onset) checked, not assumed.
    static func onsets(_ envelope: [Float], expected: [Int], threshold: Float,
                       quietFrames: Int, searchFrames: Int) -> [(onset: Int?, quietBefore: Bool)] {
        expected.map { frame in
            let quietStart = max(0, frame - quietFrames), quietEnd = max(0, frame - 2)
            let quiet = quietStart >= quietEnd || envelope[quietStart..<quietEnd].allSatisfy { $0 < threshold }
            let end = min(envelope.count, frame + searchFrames)
            let onset = (max(0, frame - quietFrames + 1)..<end).first { envelope[$0] > threshold }
            return (onset, quiet)
        }
    }

    @Test("P2: four on the floor — every kick lands on its beat within one frame, on the kick-isolated render")
    func fourOnTheFloorKicksOnTheBeat() async throws {
        let bpm = 30.0   // two seconds a beat: each kick dies away before the next (checked below)
        let kit = DrumKitParams.newDrumMachineKit
        let (kickOnly, shifted, single, sampleRate, kickNote) = try await MainActor.run {
            let song = try DrumPatternRenderStage.song(kit: kit, pattern: "fourOnTheFloor", bars: 2, bpm: bpm)
            let kickNote = try #require(song.written.written.first { $0.role == .kick }?.note)
            let kicks = (song.written.clip.notes ?? []).filter { $0.pitch == kickNote }
            let seconds = 8 * 60.0 / bpm + 1
            // The control: the third kick moved three frames late (at 48 kHz, 3 frames = 3/96000 beat).
            var moved = kicks
            let frameBeats = bpm / 60.0 / 48_000.0
            moved[2] = MIDINote(pitch: moved[2].pitch, velocity: moved[2].velocity,
                                startBeat: moved[2].startBeat + 3 * frameBeats, lengthBeats: moved[2].lengthBeats)
            let lone = [kicks[0]]
            let kickAudio = try DrumPatternRenderStage.render(
                song.store, tracks: try DrumPatternRenderStage.tracks(song.store, notes: kicks), seconds: seconds)
            return (kickAudio,
                    try DrumPatternRenderStage.render(
                        song.store, tracks: try DrumPatternRenderStage.tracks(song.store, notes: moved), seconds: seconds),
                    try DrumPatternRenderStage.render(
                        song.store, tracks: try DrumPatternRenderStage.tracks(song.store, notes: lone), seconds: 2),
                    kickAudio.sampleRate, kickNote)
        }
        #expect(sampleRate == 48_000, "the control's frame arithmetic assumes 48 kHz")
        #expect(kickNote == 36)

        // The kick's own lag: a lone kick at beat 0 through the same path.
        let singleEnvelope = Self.envelope(single)
        let singlePeak = singleEnvelope.max() ?? 0
        #expect(singlePeak > 0.01, "the lone kick is silent")
        let threshold = singlePeak * 0.001   // -60 dB under the kick's own peak
        let lag = try #require(singleEnvelope.firstIndex { $0 > threshold })
        #expect(lag <= 2, "a kick should start sounding within two frames of its note (lag \(lag))")

        let framesPerBeat = Int((60.0 / bpm * sampleRate).rounded())
        let expected = (0..<8).map { $0 * framesPerBeat }
        let found = Self.onsets(Self.envelope(kickOnly), expected: expected, threshold: threshold,
                                quietFrames: 64, searchFrames: framesPerBeat / 4)
        var deviations: [Int] = []
        for (beat, result) in found.enumerated() {
            #expect(result.quietBefore, "beat \(beat): the previous kick is still sounding, so the method is invalid")
            let onset = try #require(result.onset, "beat \(beat): no kick found")
            deviations.append(onset - (expected[beat] + lag))
        }
        #expect(deviations.allSatisfy { abs($0) <= 1 }, "kick onsets off their beats by \(deviations) frames")
        print("[W9-PAT P2] lag=\(lag) threshold=\(threshold) framesPerBeat=\(framesPerBeat) deviations=\(deviations)")

        // The gate can fail: the kick moved three frames late is found three frames late.
        let movedFound = Self.onsets(Self.envelope(shifted), expected: expected, threshold: threshold,
                                     quietFrames: 64, searchFrames: framesPerBeat / 4)
        let movedOnset = try #require(movedFound[2].onset)
        let movedDeviation = movedOnset - (expected[2] + lag)
        #expect(movedDeviation >= 2, "the control: a kick moved 3 frames read as \(movedDeviation)")
        print("[W9-PAT P2 control] moved kick deviation=\(movedDeviation)")
    }

    // MARK: - True peak

    @Test("every pattern on a NEW drum machine at fader 1.0 stays at or under -1 dBTP on a new song",
          arguments: DrumPatternLibrary.patterns.map(\.id))
    func truePeakOnANewDrumMachine(patternID: String) async throws {
        let (newSong, balance) = try await MainActor.run {
            let song = try DrumPatternRenderStage.song(kit: DrumKitParams.newDrumMachineKit,
                                                       pattern: patternID, bars: 4, bpm: 120)
            return (try DrumPatternRenderStage.render(song.store, seconds: 9, panLaw: PanLaw.newSong),
                    try DrumPatternRenderStage.render(song.store, seconds: 9, panLaw: .balance))
        }
        #expect(DrumKitParams.newDrumMachineKit.gain == 0.7)
        let newSongPeak = try #require(Loudness.measure(newSong).truePeakDbtp)
        let balancePeak = try #require(Loudness.measure(balance).truePeakDbtp)
        print("[W9-PAT TP] \(patternID): newSong(\(PanLaw.newSong.rawValue))=\(newSongPeak) dBTP "
              + "balance=\(balancePeak) dBTP")
        #expect(newSongPeak <= -1.0, "\(patternID) peaks at \(newSongPeak) dBTP on a new song")
        #expect(newSongPeak > -30, "\(patternID): the render is nearly silent (\(newSongPeak) dBTP)")
        // The meter can read over the bar: the same render 12 dB hotter.
        var hot = newSong
        hot.applyGain(linear: 3.981)
        let hotPeak = try #require(Loudness.measure(hot).truePeakDbtp)
        #expect(hotPeak > -1.0, "the control: a render 12 dB hotter read \(hotPeak) dBTP")
    }

    // MARK: - L2

    @Test("L2: the first pattern is the listening material the user picked (eighth-note hats), note for note")
    func firstPatternIsTheL2ListeningMaterial() throws {
        var pads = DrumKitParams()
        pads.noteLayout = .pads
        let roleNotes = try #require(DrumPatternLibrary.roleNotes(for: InstrumentDescriptor(kind: .drumSynth,
                                                                                           drumKit: pads)))
        // W4L's beat: two passes of a two-bar pattern = four bars.
        let ours = DrumPatternLibrary.notes(for: DrumPatternLibrary.firstPattern, bars: 4, roleNotes: roleNotes).notes
        let heard = W4LBeats.l2(hatStep: 0.5, lift: false)
        func key(_ pitch: Int, _ beat: Double, _ velocity: Int) -> String { "\(pitch)@\(beat)v\(velocity)" }
        let oursKeys = ours.map { key($0.pitch, $0.startBeat, $0.velocity) }.sorted()
        let heardKeys = heard.map { key(Int($0.voice.note), $0.beat, $0.velocity) }.sorted()
        #expect(oursKeys == heardKeys)
        #expect(ours.count == 48)
        // The lift variant (an open hat) is NOT what was picked: it must differ.
        let lift = W4LBeats.l2(hatStep: 0.5, lift: true).map { key(Int($0.voice.note), $0.beat, $0.velocity) }.sorted()
        #expect(oursKeys != lift)
    }
}
