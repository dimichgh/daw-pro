import Foundation
import Testing
@testable import DAWAppKit
@testable import DAWCore

/// Coverage for `OnboardingEditClassifier` (M8 ob-b): the pure split of journaled
/// edits into `mixerAdjusted` (the `mix` step) vs `editPerformed` (the `shape`
/// step). Two layers: unit cases over hand-built `EditEvent`s (fast, exhaustive on
/// the taxonomy) AND a drift guard that classifies events produced by a REAL
/// `ProjectStore`, so a change to the store's label/key conventions is caught here.
@Suite("Onboarding edit classifier (M8 ob-b)")
struct OnboardingEditClassifierTests {

    private func event(_ label: String, key: String? = nil) -> EditEvent {
        EditEvent(seq: 1, label: label, key: key)
    }

    // MARK: - Mixer family → mixerAdjusted

    @Test("master volume, fader, pan, and mixer preset all read as mixerAdjusted")
    func mixerFamily() {
        let uuid = UUID().uuidString
        let cases: [EditEvent] = [
            event("Set Master Volume", key: "mixer.master"),
            event("Set 'Bass' Volume", key: "track.volume:\(uuid)"),
            event("Set 'Bass' Pan", key: "track.pan:\(uuid)"),
            event("Apply Preset 'Clean Boost'", key: nil),   // the macro carries no key
        ]
        for e in cases {
            #expect(OnboardingEditClassifier.isMixerAdjustment(e), "\(e.label) should be a mixer edit")
            #expect(OnboardingEditClassifier.signal(for: e) == .mixerAdjusted)
        }
    }

    // MARK: - Everything else → editPerformed

    @Test("mutes, tempo, clip edits, sends, routing, add-track read as editPerformed")
    func nonMixerFamily() {
        let uuid = UUID().uuidString
        let cases: [EditEvent] = [
            event("Mute 'Bass'", key: nil),                                  // shape invites a mute
            event("Set Tempo", key: "transport.tempo"),
            event("Move Clip 'Loop'", key: "clip.move:\(uuid)"),
            event("Trim Clip 'Loop'", key: "clip.trim:\(uuid)"),
            event("Edit Notes", key: "clip.notes:\(uuid)"),
            event("Set Send Level", key: "track.send:\(uuid):\(UUID().uuidString)"),
            event("Set 'Bass' Output", key: nil),
            event("Add Track 'Drums'", key: nil),
            event("Humanize", key: nil),
        ]
        for e in cases {
            #expect(!OnboardingEditClassifier.isMixerAdjustment(e), "\(e.label) should NOT be a mixer edit")
            #expect(OnboardingEditClassifier.signal(for: e) == .editPerformed)
        }
    }

    @Test("a send-level key never collides with the fader/pan prefixes")
    func sendLevelIsNotAFader() {
        // track.send: shares the "track." stem but must not match "track.volume:"
        // or "track.pan:" — else a send move would jump the mix step early.
        let e = event("Set Send Level", key: "track.send:\(UUID().uuidString):\(UUID().uuidString)")
        #expect(!OnboardingEditClassifier.isMixerAdjustment(e))
    }

    @Test("the anti-collapse invariant: a fader move is NEVER editPerformed")
    func faderIsNeverShapeStep() {
        let e = event("Set 'Lead' Volume", key: "track.volume:\(UUID().uuidString)")
        #expect(OnboardingEditClassifier.signal(for: e) != .editPerformed)
        #expect(OnboardingEditClassifier.signal(for: e) == .mixerAdjusted)
    }

    // MARK: - Drift guard against the REAL store

    @MainActor
    @Test("real ProjectStore edits classify as designed (drift guard)")
    func realStoreEventsClassify() throws {
        let store = ProjectStore()
        let track = store.addTrack(name: "Bass", kind: .audio)

        func classifyLatest() -> OnboardingSignal? {
            store.lastEditEvent.map(OnboardingEditClassifier.signal(for:))
        }

        // Mixer family.
        store.setTrackVolume(id: track.id, volume: 0.7)
        #expect(classifyLatest() == .mixerAdjusted)
        store.setTrackPan(id: track.id, pan: -0.5)
        #expect(classifyLatest() == .mixerAdjusted)
        store.setMasterVolume(0.5)
        #expect(classifyLatest() == .mixerAdjusted)
        _ = try store.applyMixerPreset(trackID: track.id, presetName: "clean-boost")
        #expect(classifyLatest() == .mixerAdjusted)

        // Non-mixer family.
        store.setTrackMute(id: track.id, muted: true)   // a mute reaches the shape step
        #expect(classifyLatest() == .editPerformed)
        try store.setTempo(128)
        #expect(classifyLatest() == .editPerformed)
    }
}
