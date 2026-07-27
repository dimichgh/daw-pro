import CoreGraphics
import Testing
@testable import DAWAppKit

/// m23-d — the note-audition DEFEAT SWITCH and the gutter's y→pitch mapping
/// (§13 C17). The switch is a `PanelLayoutStore` slot: view chrome, staged for
/// gates through `debug.panelLayout {auditionEnabled}` and carrying ZERO wire
/// surface. `note.audition` deliberately ignores it — that half is pinned in
/// `AuditionCommandTests`.
@MainActor
@Suite("Note audition preference + gutter geometry (m23-d)")
struct AuditionPreferenceTests {

    @Test("C17 audition starts ON — the feature must not be invisible by default")
    func defaultsOn() {
        #expect(PanelLayoutStore.defaultAuditionEnabled)
        #expect(PanelLayoutStore().auditionEnabled)
    }

    @Test("C17 the switch round-trips and PERSISTS like every other layout slot")
    func persistsAcrossStores() {
        let backing = InMemoryPanelLayoutBacking()
        let store = PanelLayoutStore(backing: backing)
        store.setAuditionEnabled(false)
        #expect(!store.auditionEnabled)

        // A second store over the SAME backing is the relaunch simulation.
        let reopened = PanelLayoutStore(backing: backing)
        #expect(!reopened.auditionEnabled)

        reopened.setAuditionEnabled(true)
        #expect(PanelLayoutStore(backing: backing).auditionEnabled)
    }

    @Test("C17 reset() restores audition to ON")
    func resetRestoresIt() {
        let store = PanelLayoutStore()
        store.setAuditionEnabled(false)
        store.reset()
        #expect(store.auditionEnabled == PanelLayoutStore.defaultAuditionEnabled)
    }

    @Test("the audition slot is INDEPENDENT of the follow slot (one switch, one meaning)")
    func independentOfFollow() {
        let store = PanelLayoutStore()
        store.setFollowPlayhead(true)
        store.setAuditionEnabled(false)
        #expect(store.followPlayhead)
        #expect(!store.auditionEnabled)
        store.setFollowPlayhead(false)
        #expect(!store.auditionEnabled)
    }

    // MARK: - The gutter's y → pitch mapping

    @Test("the keyboard gutter's y→pitch inverse round-trips against the drawn affine")
    func gutterMappingRoundTrips() {
        // The sidebar sounds `model.pitch(forY:)` — the SAME affine the Canvas
        // draws each key's rect with. A second copy of the mapping in the view
        // would be a divergence waiting to happen, so this pins the round trip
        // at the row's top edge, its middle, and its bottom edge.
        let model = PianoRollModel(notes: [], clipLengthBeats: 4)
        for pitch in [0, 21, 60, 72, 127] {
            let top = model.y(forPitch: pitch)
            #expect(model.pitch(forY: top) == pitch)
            #expect(model.pitch(forY: top + model.rowHeight / 2) == pitch)
            #expect(model.pitch(forY: top + model.rowHeight - 0.01) == pitch)
        }
    }

    @Test("sliding past the top or bottom key HOLDS that key rather than going silent")
    func gutterMappingClamps() {
        let model = PianoRollModel(notes: [], clipLengthBeats: 4)
        #expect(model.pitch(forY: -500) == 127)                       // above C9
        #expect(model.pitch(forY: model.contentHeight + 500) == 0)    // below C-1
    }
}
