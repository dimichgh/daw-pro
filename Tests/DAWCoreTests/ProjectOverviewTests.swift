import Foundation
import Testing
@testable import DAWCore

/// Headless coverage for M7's agent-facing `ProjectOverview` projection:
/// field mapping onto `ProjectStore.overview()`, the counts-not-lists rule,
/// and the token-efficiency contract (a size bound the regression guard for
/// someone later "helpfully" inlining notes/points back into the wire shape).
@MainActor
@Suite("Project overview — agent-facing projection")
struct ProjectOverviewTests {
    // MARK: - Field mapping

    @Test("overview mirrors transport, master, and per-track summary fields")
    func fieldMapping() throws {
        let store = ProjectStore(projectName: "Demo")
        store.media = FakeMedia()
        try store.setTempo(128)
        try store.setLoop(enabled: true, startBeat: 4, endBeat: 20)
        try store.setMetronome(enabled: true, countInBars: 2)
        try store.setPunch(enabled: true, inBeat: 8, outBeat: 12)
        store.setMasterVolume(0.75)

        let bus = store.addTrack(name: "Reverb Bus", kind: .bus)
        let audio = store.addTrack(name: "Gtr", kind: .audio)
        try store.setTrackOutput(id: audio.id, busID: bus.id)
        try store.addSend(toTrack: audio.id, busID: bus.id, level: 0.6)
        _ = try store.addEffect(toTrack: audio.id, kind: .eq)
        store.setTrackMute(id: audio.id, muted: true)
        store.setTrackSolo(id: audio.id, soloed: true)
        try store.setTrackArm(id: audio.id, armed: true)
        store.setTrackVolume(id: audio.id, volume: 1.5)
        store.setTrackPan(id: audio.id, pan: -0.5)

        let clip = try store.importAudio(url: URL(fileURLWithPath: "/Users/someone/Secret Sessions/kick.wav"),
                                          toTrack: audio.id)
        _ = try store.setClipGain(trackId: audio.id, clipId: clip.id, gainDb: 6)
        _ = try store.setClipFades(trackId: audio.id, clipId: clip.id,
                                   fadeInBeats: 0.5, fadeOutBeats: 0.5,
                                   fadeInCurve: .linear, fadeOutCurve: .linear)
        _ = try store.setClipStretch(trackId: audio.id, clipId: clip.id, ratio: 1.5)

        let inst = store.addTrack(name: "Synth", kind: .instrument)
        let notes = (0..<10).map { i in
            MIDINote(pitch: 60 + i % 12, velocity: 100, startBeat: Double(i) * 0.5, lengthBeats: 0.25)
        }
        _ = try store.addMIDIClip(toTrack: inst.id, name: "Lead", notes: notes)

        let lane = try store.addAutomationLane(trackID: audio.id, target: .volume)
        let points = (0..<12).map { AutomationPoint(beat: Double($0), value: 1.0) }
        _ = try store.setAutomationPoints(trackID: audio.id, laneID: lane.id, points: points)

        let overview = store.overview()

        // Transport
        #expect(overview.transport.tempoBPM == 128)
        #expect(overview.transport.loop.enabled)
        #expect(overview.transport.loop.startBeat == 4)
        #expect(overview.transport.loop.endBeat == 20)
        #expect(overview.transport.metronome.enabled)
        #expect(overview.transport.metronome.countInBars == 2)
        #expect(overview.transport.punch.enabled)
        #expect(overview.transport.punch.inBeat == 8)
        #expect(overview.transport.punch.outBeat == 12)
        #expect(!overview.transport.isPlaying)
        #expect(!overview.transport.isRecording)

        // Master
        #expect(overview.master.volume == 0.75)

        // Tracks
        #expect(overview.tracks.count == 3)
        guard let audioOut = overview.tracks.first(where: { $0.id == audio.id }) else {
            Issue.record("audio track missing from overview"); return
        }
        #expect(audioOut.name == "Gtr")
        #expect(audioOut.kind == "audio")
        #expect(audioOut.muted)
        #expect(audioOut.soloed)
        #expect(audioOut.armed)
        #expect(audioOut.volume == 1.5)
        #expect(audioOut.pan == -0.5)
        #expect(audioOut.output == bus.id)
        #expect(audioOut.sends.count == 1)
        #expect(audioOut.sends[0].destinationBusID == bus.id)
        #expect(audioOut.sends[0].level == 0.6)
        #expect(audioOut.sends[0].preFader == false)
        #expect(audioOut.fx.count == 1)
        #expect(audioOut.fx[0].name == "eq")
        #expect(audioOut.fx[0].bypassed == false)

        #expect(audioOut.clips.count == 1)
        let clipOut = audioOut.clips[0]
        #expect(clipOut.id == clip.id)
        #expect(clipOut.kind == "audio")
        #expect(clipOut.noteCount == nil)
        #expect(clipOut.hasStretch == true)          // ratio 1.5 != identity
        #expect(clipOut.hasFades == true)
        #expect(clipOut.gainDb == 6)

        #expect(audioOut.automation.count == 1)
        #expect(audioOut.automation[0].target == "volume")
        #expect(audioOut.automation[0].enabled)
        #expect(audioOut.automation[0].pointCount == 12)

        guard let instOut = overview.tracks.first(where: { $0.id == inst.id }) else {
            Issue.record("instrument track missing from overview"); return
        }
        #expect(instOut.kind == "instrument")
        #expect(instOut.instrument == "polySynth")    // InstrumentDescriptor.default kind
        #expect(instOut.clips.count == 1)
        let midiClipOut = instOut.clips[0]
        #expect(midiClipOut.kind == "midi")
        #expect(midiClipOut.noteCount == 10)
        #expect(midiClipOut.hasStretch == nil)
        #expect(midiClipOut.hasFades == nil)
        #expect(midiClipOut.gainDb == nil)

        guard let busOut = overview.tracks.first(where: { $0.id == bus.id }) else {
            Issue.record("bus track missing from overview"); return
        }
        #expect(busOut.kind == "bus")
        #expect(busOut.clips.isEmpty)
    }

    @Test("audio clip gainDb is omitted (nil) when zero, present when non-zero")
    func gainOmittedAtZero() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let audio = store.addTrack(kind: .audio)
        let clip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/loop.wav"), toTrack: audio.id)
        let overview = store.overview()
        #expect(overview.tracks[0].clips[0].gainDb == nil)  // unity, omitted

        _ = try store.setClipGain(trackId: audio.id, clipId: clip.id, gainDb: -3)
        #expect(store.overview().tracks[0].clips[0].gainDb == -3)
    }

    // MARK: - No file paths, no unbounded lists

    @Test("overview JSON never carries a file path, raw notes, or raw automation points")
    func noPathsNoRawLists() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let audio = store.addTrack(kind: .audio)
        _ = try store.importAudio(
            url: URL(fileURLWithPath: "/Users/someone/Music/DAW Pro Sessions/lead vocal take 3.wav"),
            toTrack: audio.id)

        let inst = store.addTrack(kind: .instrument)
        _ = try store.addMIDIClip(toTrack: inst.id, notes: [
            MIDINote(pitch: 64, startBeat: 0, lengthBeats: 1),
        ])

        let lane = try store.addAutomationLane(trackID: audio.id, target: .volume)
        _ = try store.setAutomationPoints(trackID: audio.id, laneID: lane.id,
                                          points: [AutomationPoint(beat: 0, value: 1)])

        let data = try JSONEncoder().encode(store.overview())
        let json = String(decoding: data, as: UTF8.self)

        // The clip's own display `name` (basename-derived, like "Kick Loop"
        // in the plain import tests) IS expected on the wire — only the
        // directory layout and the raw URL/extension must never appear.
        #expect(!json.contains("Users"))
        #expect(!json.contains("DAW Pro Sessions"))
        #expect(!json.contains(".wav"))
        #expect(!json.contains("audioFileURL"))
        #expect(!json.contains("\"notes\""))
        #expect(!json.contains("\"points\""))
        #expect(!json.contains("startOffsetSeconds"))
    }

    // MARK: - Token-efficiency contract (the regression guard)

    /// Builds a synthetic dense project: 8 tracks (2 buses, 3 audio, 3
    /// instrument), 24 clips total (9 MIDI clips with 64 notes each, 15 audio
    /// clips), a 60-point volume automation lane on every non-bus track, one
    /// send per audio track, and one effect per audio track.
    private func denseProject() throws -> ProjectStore {
        let store = ProjectStore(projectName: "Dense Session")
        store.media = FakeMedia()
        try store.setTempo(140)

        let busA = store.addTrack(name: "Reverb Bus", kind: .bus)
        let busB = store.addTrack(name: "Delay Bus", kind: .bus)

        var nonBusTracks: [Track] = []
        for i in 0..<3 {
            let audio = store.addTrack(name: "Audio \(i + 1)", kind: .audio)
            try store.addSend(toTrack: audio.id, busID: busA.id, level: 0.5)
            _ = try store.addEffect(toTrack: audio.id, kind: .compressor)
            for j in 0..<5 {
                let clip = try store.importAudio(
                    url: URL(fileURLWithPath: "/tmp/audio-\(i)-\(j).wav"),
                    toTrack: audio.id)
                _ = try store.setClipFades(trackId: audio.id, clipId: clip.id,
                                           fadeInBeats: 0.1, fadeOutBeats: 0.1,
                                           fadeInCurve: .equalPower, fadeOutCurve: .equalPower)
            }
            nonBusTracks.append(store.tracks.first(where: { $0.id == audio.id })!)
        }

        for i in 0..<3 {
            let inst = store.addTrack(name: "Inst \(i + 1)", kind: .instrument)
            try store.addSend(toTrack: inst.id, busID: busB.id, level: 0.4)
            _ = try store.addEffect(toTrack: inst.id, kind: .eq)
            for j in 0..<3 {
                let notes = (0..<64).map { n in
                    MIDINote(pitch: 48 + n % 24, velocity: 90,
                             startBeat: Double(n) * 0.25, lengthBeats: 0.2)
                }
                _ = try store.addMIDIClip(toTrack: inst.id, name: "Take \(j)", notes: notes)
            }
            nonBusTracks.append(store.tracks.first(where: { $0.id == inst.id })!)
        }

        for track in nonBusTracks {
            let lane = try store.addAutomationLane(trackID: track.id, target: .volume)
            let points = (0..<60).map { AutomationPoint(beat: Double($0) * 0.5, value: 1.0) }
            _ = try store.setAutomationPoints(trackID: track.id, laneID: lane.id, points: points)
        }

        #expect(store.tracks.count == 8)
        #expect(store.tracks.reduce(0) { $0 + $1.clips.count } == 24)
        return store
    }

    @Test("overview stays under 8 KB and at least 5x smaller than the full snapshot")
    func tokenEfficiencyContract() throws {
        let store = try denseProject()

        let overviewData = try JSONEncoder().encode(store.overview())
        let snapshotData = try JSONEncoder().encode(store.snapshot())

        let overviewBytes = overviewData.count
        let snapshotBytes = snapshotData.count
        let ratio = Double(snapshotBytes) / Double(overviewBytes)

        #expect(overviewBytes < 8192,
                "overview grew to \(overviewBytes) bytes — investigate before raising the bound")
        #expect(ratio >= 5,
                "overview is only \(ratio)x smaller than the full snapshot (\(overviewBytes) vs \(snapshotBytes) bytes) — investigate before lowering the bound")
    }
}
