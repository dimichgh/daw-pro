import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m23-bx-1 (defect 2) — **SILENCE MUST NEVER BE THE ONLY SYMPTOM.**
///
/// `PlaybackGraph` resolves a hosted instrument as
/// `audioUnitProvider(track) ?? SilentPlaceholderInstrument()`. Before this
/// fix, a track whose plug-in was missing, failed or timed out was wired to
/// exact zeros and that was the ENTIRE user-visible story: no log, no warning,
/// no retry. `SilentPlaceholderInstrument` had exactly three references in all
/// of `Sources/` — the type and those two call sites — so the loudest track in
/// a song could vanish with nothing anywhere to say why.
///
/// That is not a hypothetical: it is what made m23-bx-1's family of bugs cost
/// six investigation cycles. The engine now posts an `instrument-unavailable`
/// notice at the exact instant the track becomes audibly dead, into the same
/// ring `project.snapshot` publishes.
///
/// AU-FREE by construction: a component id no machine has (`zzzz/zzzz`) walks
/// the whole prepare body and lands `.missing` without instantiating anything,
/// so this suite needs no plug-in and no audio device.
@MainActor
@Suite("m23-bx-1 — an un-hostable instrument surfaces a notice", .serialized)
struct UnhostableInstrumentNoticeTests {

    private static let absent = AudioUnitComponentID(subType: "zzzz", manufacturer: "zzzz")

    private func auTrack(name: String, component: AudioUnitComponentID) -> Track {
        Track(name: name, kind: .instrument,
              instrument: InstrumentDescriptor(
                  kind: .audioUnit,
                  audioUnit: AudioUnitConfig(component: component)))
    }

    /// Drains the async prepare Task `syncAudioUnitInstruments` spawns.
    private func settle(_ engine: AudioEngine, trackID: UUID) async {
        for _ in 0..<200 {
            if engine.auRegistry.status[trackID] != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        // One more turn so the notice posts after the status lands.
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test("a track whose plug-in is not installed posts instrument-unavailable")
    func missingPluginPostsNotice() async {
        let engine = AudioEngine()
        var notices: [EngineNoticeEvent] = []
        engine.engineNoticeHandler = { notices.append($0) }

        let track = auTrack(name: "Bass", component: Self.absent)
        engine.tracksDidChange([track])
        await settle(engine, trackID: track.id)

        #expect(engine.auRegistry.status[track.id] == .missing,
                "precondition: the prepare must really have failed, or this proves nothing")
        #expect(engine.auRegistry.preparedInstrument(forTrack: track.id) == nil)

        let found = notices.first { $0.code == "instrument-unavailable" }
        #expect(found != nil, "a silent track must surface a notice")
        // Names the track (design-language: the listener must know WHICH one)
        // and says what to do — not wire-speak.
        #expect(found?.message.contains("Bass") == true)
        #expect(found?.message.contains("isn't installed") == true)
    }

    /// The complement, and the one that keeps the notice meaningful: a track
    /// that hosts fine must post NOTHING. A notice that fires on the happy path
    /// is noise, and noise is what people learn to ignore.
    @Test("a healthy built-in instrument track posts no notice")
    func healthyTrackIsSilentDiagnostically() async {
        let engine = AudioEngine()
        var notices: [EngineNoticeEvent] = []
        engine.engineNoticeHandler = { notices.append($0) }

        engine.tracksDidChange([Track(name: "Keys", kind: .instrument,
                                      instrument: InstrumentDescriptor(kind: .polySynth))])
        try? await Task.sleep(for: .milliseconds(120))

        #expect(!notices.contains { $0.code == "instrument-unavailable" })
    }

    /// Several dead tracks must each report — the store's ring coalesces them
    /// by `code` into one notice carrying `count`, the `clip-file-missing`
    /// contract. If the engine posted only once, a user fixing one plug-in
    /// would think they were done.
    @Test("every un-hostable track reports, so the ring's count is honest")
    func everyDeadTrackReports() async {
        let engine = AudioEngine()
        var notices: [EngineNoticeEvent] = []
        engine.engineNoticeHandler = { notices.append($0) }

        let tracks = [auTrack(name: "Bass", component: Self.absent),
                      auTrack(name: "Lead", component: Self.absent),
                      auTrack(name: "Pad", component: Self.absent)]
        engine.tracksDidChange(tracks)
        for track in tracks { await settle(engine, trackID: track.id) }

        let unavailable = notices.filter { $0.code == "instrument-unavailable" }
        #expect(unavailable.count == 3)
        for name in ["Bass", "Lead", "Pad"] {
            #expect(unavailable.contains { $0.message.contains(name) },
                    "\(name) went silent without saying so")
        }
    }
}
