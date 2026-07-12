import Foundation
import Testing
@testable import DAWAppKit

/// Unit tests for the headless track-rename commit resolver (beta m10-i). The
/// double-click rename field in the track header is thin over this: it seeds a
/// draft, and on Return / focus-loss asks `committedName` whether to call
/// `ProjectStore.renameTrack`. Exercising trim / empty-cancel / unchanged-no-op
/// here pins the commit contract without a display (the `PianoRollPlayhead`
/// test-suite style).
@Suite("TrackRename")
struct TrackRenameModelTests {

    // 1. A real rename: distinct non-blank text commits verbatim (after trim).
    @Test("a distinct non-blank draft commits the trimmed name")
    func distinctNameCommits() {
        #expect(TrackRename.committedName(draft: "Lead Vocal", current: "Audio 1") == "Lead Vocal")
        // Surrounding whitespace is trimmed off the committed value.
        #expect(TrackRename.committedName(draft: "  Bass  ", current: "Audio 1") == "Bass")
        // Interior spaces are preserved — only the ends are trimmed.
        #expect(TrackRename.committedName(draft: "Rhythm Guitar 2", current: "Audio 1") == "Rhythm Guitar 2")
    }

    // 2. Empty / whitespace-only input cancels (nil) — an accidental clear must
    // never wipe a track's name (the store also rejects empty, this is the UI floor).
    @Test("empty or whitespace-only input cancels (nil)")
    func emptyInputCancels() {
        #expect(TrackRename.committedName(draft: "", current: "Audio 1") == nil)
        #expect(TrackRename.committedName(draft: "   ", current: "Audio 1") == nil)
        #expect(TrackRename.committedName(draft: "\n\t ", current: "Audio 1") == nil)
    }

    // 3. Unchanged input is a no-op (nil) so it never pushes a pointless undo step.
    @Test("re-typing the same name is a no-op (nil), trim-insensitive")
    func unchangedIsNoOp() {
        #expect(TrackRename.committedName(draft: "Audio 1", current: "Audio 1") == nil)
        // Padding the same name still reads as unchanged (both sides trimmed).
        #expect(TrackRename.committedName(draft: "  Audio 1 ", current: "Audio 1") == nil)
        #expect(TrackRename.committedName(draft: "Drums", current: "  Drums  ") == nil)
    }

    // 4. A whitespace-only DIFFERENCE (padding a name) is not a rename, but a real
    // character change — even one — is.
    @Test("only a real character change commits, not a padding change")
    func realChangeVsPadding() {
        // Case change IS a real change (names are case-sensitive to the user).
        #expect(TrackRename.committedName(draft: "audio 1", current: "Audio 1") == "audio 1")
        // A trailing character added is a real change.
        #expect(TrackRename.committedName(draft: "Audio 10", current: "Audio 1") == "Audio 10")
        // Pure re-padding is not.
        #expect(TrackRename.committedName(draft: " Audio 1", current: "Audio 1 ") == nil)
    }

    // 5. `trimmed` is the shared normalizer the field and validator agree on.
    @Test("trimmed strips only leading/trailing whitespace and newlines")
    func trimmedNormalizer() {
        #expect(TrackRename.trimmed("  Bass  ") == "Bass")
        #expect(TrackRename.trimmed("\n Lead \t") == "Lead")
        #expect(TrackRename.trimmed("Rhythm Guitar") == "Rhythm Guitar")   // interior kept
        #expect(TrackRename.trimmed("   ") == "")
    }
}
