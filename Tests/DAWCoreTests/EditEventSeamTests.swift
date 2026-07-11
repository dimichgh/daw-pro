import Foundation
import Testing
@testable import DAWCore

/// Coverage for the M8 ob-b DAWCore seam: `ProjectStore.lastEditEvent` (published
/// inside `performEdit` exactly when a journal entry records) and
/// `renderCompletedCount` (incremented on every successful bounce/mixdown). These
/// are the two facts the app-side onboarding signal adapter observes to translate
/// project mutations into tour signals — WITHOUT the tour model reading the store.
/// Reuses `FakeBufferEngine` (RenderPolicyTests) for the render paths.
@MainActor
@Suite("Edit-event + render seam (M8 ob-b)")
struct EditEventSeamTests {

    // MARK: - lastEditEvent

    @Test("a fresh store has no edit event and a zero render count")
    func freshDefaults() {
        let store = ProjectStore()
        #expect(store.lastEditEvent == nil)
        #expect(store.renderCompletedCount == 0)
    }

    @Test("a journaled edit publishes lastEditEvent with its label + key and seq 1")
    func firstEditPublishes() {
        let store = ProjectStore()
        store.setMasterVolume(0.5)   // journals "Set Master Volume", key "mixer.master"
        let event = store.lastEditEvent
        #expect(event?.seq == 1)
        #expect(event?.label == "Set Master Volume")
        #expect(event?.key == "mixer.master")
    }

    @Test("a nil-key edit publishes with key nil")
    func nilKeyEdit() {
        let store = ProjectStore()
        _ = store.addTrack(name: "Drums", kind: .audio)   // "Add Track 'Drums'", no key
        #expect(store.lastEditEvent?.label == "Add Track 'Drums'")
        #expect(store.lastEditEvent?.key == nil)
        #expect(store.lastEditEvent?.seq == 1)
    }

    @Test("seq strictly increases, and coalesced same-key edits still each tick")
    func seqStrictlyIncreasesEvenWhenCoalesced() {
        let store = ProjectStore()
        let track = store.addTrack(name: "Bass", kind: .audio)   // seq 1
        #expect(store.lastEditEvent?.seq == 1)

        // Two fader moves on the SAME track coalesce in the journal (same key,
        // adjacent) — but each still ticks lastEditEvent so a debounced observer
        // never misses the second move.
        store.setTrackVolume(id: track.id, volume: 0.8)   // seq 2
        #expect(store.lastEditEvent?.seq == 2)
        #expect(store.lastEditEvent?.key == "track.volume:\(track.id.uuidString)")
        store.setTrackVolume(id: track.id, volume: 0.6)   // seq 3
        #expect(store.lastEditEvent?.seq == 3)
        #expect(store.lastEditEvent?.key == "track.volume:\(track.id.uuidString)")
    }

    @Test("a no-op edit leaves lastEditEvent untouched (no journal, no tick)")
    func noOpEditStaysSilent() {
        let store = ProjectStore()
        store.setMasterVolume(0.5)                 // real change → seq 1
        let afterReal = store.lastEditEvent
        #expect(afterReal?.seq == 1)

        store.setMasterVolume(0.5)                 // same value → no state change → no journal
        #expect(store.lastEditEvent == afterReal)  // unchanged: same seq, no phantom event
        #expect(store.lastEditEvent?.seq == 1)
    }

    @Test("the mixer vs non-mixer distinction is carried on the event, not collapsed")
    func mixerAndNonMixerEditsCarryDistinctKeys() {
        let store = ProjectStore()
        let track = store.addTrack(name: "Keys", kind: .audio)

        // A fader move: a mixer key.
        store.setTrackVolume(id: track.id, volume: 0.7)
        #expect(store.lastEditEvent?.key == "track.volume:\(track.id.uuidString)")

        // A mute: a track-state edit with NO key (the shape-step surface).
        store.setTrackMute(id: track.id, muted: true)
        #expect(store.lastEditEvent?.key == nil)
        #expect(store.lastEditEvent?.label.contains("Mute") == true)
    }

    // MARK: - renderCompletedCount

    @Test("renderBounce increments the render count on success")
    func bounceIncrements() async throws {
        let store = ProjectStore()
        let engine = FakeBufferEngine()   // strong local — store.engine is weak
        store.engine = engine
        #expect(store.renderCompletedCount == 0)
        _ = try await store.renderBounce(durationSeconds: 1)
        #expect(store.renderCompletedCount == 1)
        _ = try await store.renderBounce(durationSeconds: 1)
        #expect(store.renderCompletedCount == 2)
    }

    @Test("renderMixdown increments the render count on success (the other path)")
    func mixdownIncrements() async throws {
        let store = ProjectStore()
        let engine = FakeBufferEngine()   // strong local — store.engine is weak
        store.engine = engine
        _ = try await store.renderMixdown(durationSeconds: 1)
        #expect(store.renderCompletedCount == 1)
    }

    @Test("a failed render does NOT increment the count")
    func failedRenderDoesNotIncrement() async {
        let store = ProjectStore()
        let engine = FakeBufferEngine()
        engine.renderError = ProjectError.nothingToRender
        store.engine = engine
        await #expect(throws: (any Error).self) {
            _ = try await store.renderBounce(durationSeconds: 1)
        }
        #expect(store.renderCompletedCount == 0)
    }

    @Test("a render never journals an edit — the two seams are independent")
    func renderDoesNotTouchEditEvent() async throws {
        let store = ProjectStore()
        let engine = FakeBufferEngine()   // strong local — store.engine is weak
        store.engine = engine
        _ = try await store.renderBounce(durationSeconds: 1)
        #expect(store.lastEditEvent == nil)          // bouncing is not an edit
        #expect(store.renderCompletedCount == 1)
    }
}
