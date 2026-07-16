import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Headless coverage for the space-bar transport toggle's decision funnel
/// (m17-d, user #6). The predicate is THE focus guard: a space typed while any
/// text editing is active must insert a space and never touch the transport,
/// so every branch of `TransportKeyRouting.decide` is pinned here — the app's
/// NSEvent monitor adds no policy of its own. The `toggleIntent` leg pins the
/// play/pause button's exact ternary (recording forces `isPlaying` true in
/// `ProjectStore.record()`, so mid-record space = the same `stop()` funnel).
@Suite("Transport key routing (m17-d)")
struct TransportKeyModelTests {

    private let space = TransportKeyRouting.spaceKeyCode

    /// Shorthand: the happy-path arguments, overridable per case.
    private func decide(
        keyCode: UInt16? = nil,
        modifiers: TransportKeyModifiers = [],
        isRepeat: Bool = false,
        responder: TransportKeyResponder = .none,
        window: TransportKeyWindow = .main
    ) -> TransportKeyDecision {
        TransportKeyRouting.decide(
            keyCode: keyCode ?? space, modifiers: modifiers, isRepeat: isRepeat,
            responder: responder, window: window)
    }

    // MARK: - The one granting combination

    @Test("bare, fresh space at the main window with no text editing toggles")
    func bareSpaceToggles() {
        #expect(decide() == .toggleTransport)
    }

    @Test("the decision is transport-state independent — the intent leg differentiates")
    func decisionIgnoresTransportState() {
        // decide() takes no transport state at all (by design: toggle handles
        // both directions), so the SAME verdict grants from stopped, playing,
        // and recording. The matrix here is decide × toggleIntent.
        #expect(decide() == .toggleTransport)
        #expect(TransportKeyRouting.toggleIntent(isPlaying: false) == .play)
        #expect(TransportKeyRouting.toggleIntent(isPlaying: true) == .stop)
    }

    // MARK: - Focus guard (the hard requirement)

    @Test("space while text editing passes through — rename fields keep their spaces")
    func spaceInFieldEditorPassesThrough() {
        #expect(decide(responder: .textEditing) == .passThrough)
        // Even from a playing or recording transport the verdict is the same —
        // the predicate never consults transport state, so a focused field can
        // never lose a space to a running transport either.
        #expect(decide(responder: .textEditing, window: .main) == .passThrough)
    }

    @Test("text editing beats every other grant — modifiers/repeat don't re-admit")
    func textEditingIsUnconditional() {
        #expect(decide(modifiers: [], isRepeat: false, responder: .textEditing) == .passThrough)
        #expect(decide(modifiers: [.shift], responder: .textEditing) == .passThrough)
        #expect(decide(isRepeat: true, responder: .textEditing) == .passThrough)
    }

    // MARK: - Key repeat

    @Test("a held space (key repeat) passes through — one press, one toggle")
    func repeatPassesThrough() {
        #expect(decide(isRepeat: true) == .passThrough)
    }

    // MARK: - Modifier chords

    @Test("any chord modifier passes through (⌘Space is Spotlight's, ⇧/⌥/⌃ stay free)")
    func modifierChordsPassThrough() {
        #expect(decide(modifiers: [.command]) == .passThrough)
        #expect(decide(modifiers: [.option]) == .passThrough)
        #expect(decide(modifiers: [.control]) == .passThrough)
        #expect(decide(modifiers: [.shift]) == .passThrough)
        #expect(decide(modifiers: [.command, .option]) == .passThrough)
        #expect(decide(modifiers: [.command, .option, .control, .shift]) == .passThrough)
    }

    // MARK: - Window scope

    @Test("space aimed at a secondary window passes through (main-window-only)")
    func secondaryWindowPassesThrough() {
        #expect(decide(window: .secondary) == .passThrough)
        // Secondary + text editing (an AU search box) — still pass through.
        #expect(decide(responder: .textEditing, window: .secondary) == .passThrough)
    }

    // MARK: - Other keys

    @Test("non-space keys never toggle, whatever the context")
    func otherKeysPassThrough() {
        for keyCode: UInt16 in [15 /* R */, 36 /* return */, 53 /* esc */, 0 /* A */] {
            #expect(decide(keyCode: keyCode) == .passThrough)
            #expect(decide(keyCode: keyCode, responder: .textEditing) == .passThrough)
        }
    }

    @Test("the space key code is kVK_Space (layout-independent)")
    func spaceKeyCodePinned() {
        #expect(TransportKeyRouting.spaceKeyCode == 49)
    }

    // MARK: - Toggle intent against a real store (the funnel equivalence)

    @Test("toggleIntent mirrors the play/pause button's ternary on a real store")
    @MainActor
    func toggleIntentAgainstRealStore() throws {
        let store = ProjectStore()
        // Stopped → play (from wherever the playhead sits — play() never seeks).
        #expect(TransportKeyRouting.toggleIntent(isPlaying: store.transport.isPlaying) == .play)
        store.play()
        #expect(store.transport.isPlaying)
        // Playing → stop, the SAME store.stop() the transport buttons call.
        #expect(TransportKeyRouting.toggleIntent(isPlaying: store.transport.isPlaying) == .stop)
        store.stop()
        #expect(!store.transport.isPlaying)
        #expect(TransportKeyRouting.toggleIntent(isPlaying: store.transport.isPlaying) == .play)
    }

    @Test("play from a seeked playhead starts there — space never rewinds")
    @MainActor
    func playHonorsPlayheadPosition() throws {
        let store = ProjectStore()
        try store.seek(toBeats: 8)
        #expect(store.transport.positionBeats == 8)
        // The space toggle calls the same play() — position untouched by starting.
        #expect(TransportKeyRouting.toggleIntent(isPlaying: false) == .play)
        store.play()
        #expect(store.transport.positionBeats == 8)
        store.stop()
    }
}
