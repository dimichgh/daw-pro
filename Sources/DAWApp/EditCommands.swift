import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

/// Edit-menu Undo / Redo / Cut / Copy / Paste / Delete, wired to `ProjectStore`'s
/// undo journal, the app's `EditClipboard` and its deletable surfaces. The item
/// titles fold in the next operation's label ("Undo Add Track 'Vox'") and the
/// items enable/disable live — `ProjectStore.journal` is observed, so reading
/// `canUndo`/`undoLabel` here re-evaluates the menu when history changes.
/// Failures surface the store's message verbatim via the same NSAlert pattern
/// as `FileCommands` (standard OS chrome, outside the glass-cockpit window).
struct EditCommands: Commands {
    let store: ProjectStore
    /// Read for the Delete item (m23-cf) — every title, enabled state and action
    /// comes from an `AppModel` property backed by a DAWAppKit policy, never
    /// decided here. ⭐ Cut / Copy / Paste no longer render here at all: since
    /// m25-f-1 they ARE macOS's own pasteboard items, driven by the same policy
    /// through `ClipboardResponder` on the responder chain.
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(undoTitle) { undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndo)
            Button(redoTitle) { redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!store.canRedo)
        }
        // DELETE (m23-cf) — the SECOND, non-keyboard route to removing a clip, a
        // note or an automation point. Before this the bare DELETE key was the
        // only one, and a user reported it dead on both notes and clips: with no
        // menu route, the operation was simply unreachable.
        //
        // ⚠️⚠️ THIS ITEM MUST NEVER GET `.keyboardShortcut(.delete)`. Menu key
        // equivalents are checked BEFORE text insertion, so that one modifier
        // would steal Backspace from every rename field in the app — the m17-d
        // trap, written up at length on `ContentView`'s `ArrangeDeleteKey`. ⭐ THE
        // DISTINCTION THIS ITEM EXISTS TO EXPLOIT: the hazard belongs to the
        // SHORTCUT, not to the MENU ITEM. With no key equivalent this carries none
        // of it, and the existing `.onKeyPress(.delete)` handlers keep the
        // keyboard path exactly as it was.
        //
        // AFTER `.pasteboard` — where Delete sits in a standard macOS Edit menu
        // (Cut / Copy / Paste / Delete), so it is where a user already looks.
        //
        // `role: .destructive` matches the `Button("Remove Track", role:
        // .destructive)` precedent (docs/DESIGN-LANGUAGE.md). macOS does not tint
        // menu-bar items by role; it is kept for the convention, and because the
        // TITLE is what actually carries the warning here ("Delete 3 Clips").
        CommandGroup(after: .pasteboard) {
            // ═══ WHERE CUT / COPY / PASTE WENT (m23-ek-3 → m25-f-1) ═══
            //
            // ⚠️⚠️ **THREE `Button`s USED TO SIT HERE AND WERE DELETED ON PURPOSE
            // 2026-08-12. DO NOT PUT THEM BACK** — they would be a second,
            // shortcut-less row for verbs macOS's own Cut / Copy / Paste items
            // now perform, which is precisely the duplication the user ruled
            // against ("if the most versatile can handle our use-cases, then we
            // can drop the inferrior ones").
            //
            // ⭐⭐ THE USER REVERSED THE MENU-ONLY RULING 2026-08-12: "copy/paste
            // keybord shortcuts should also work based on track area for clips
            // supporting group copy and pasting at playhead. In note editor we
            // need the same". THE KEYSTROKES ARE WANTED — and they arrive on the
            // RESPONDER CHAIN (`ClipboardResponder.swift`), never as a
            // `.keyboardShortcut` here:
            //
            //   ⚠️ A `CommandGroup` key equivalent is checked BEFORE the
            //   responder chain, so `.keyboardShortcut("c", modifiers: .command)`
            //   on one of these buttons would fire CLIP-COPY for a ⌘C typed into
            //   a rename field — the m17-d trap, transposed. The user asked for
            //   the OUTCOME, not for that mechanism.
            //
            // ⭐⭐ AND THE COUNTED TITLES WENT WITH THEM, ON THE USER'S WORD the
            // same day: "we do not need to use copy 3 clips, it should just copy
            // anything selected to the copy buffer and when pasted, it should use
            // paste behavior of what is being copied. use common logic and
            // commonly adopted partice for such behavior". The Edit menu now
            // reads plain "Cut" / "Copy" / "Paste", greyed when unavailable —
            // and the teaching titles ("Copy Selection" and its two siblings)
            // were deleted from `ClipboardMenuPolicy` in the same ruling.
            //
            // ⭐ THE INERT-TITLE COLLISION THIS BLOCK USED TO WARN ABOUT IS GONE
            // AT THE ROOT. `after: .pasteboard` put our greyed "Cut" / "Copy" /
            // "Paste" under macOS's own, which measurably rendered as six
            // near-identical rows; there is now exactly one row per verb, which
            // is why plain words are legible again.
            //
            // ⚠️ DELETE IS DELIBERATELY NOT ALIGNED WITH THIS. It still reads
            // "Delete 3 Clips" / "Delete Selection" (`DeleteMenuPolicy`) — the
            // user named COPY and said nothing about Delete, and that counted
            // title was its own earlier decision. Left standing for them to rule
            // on; do not "make it consistent" in either direction.
            //
            // ⚠️ ROLLBACK, IF A HUMAN FINDS THE NATIVE ITEMS DEAD: restore the
            // three `Button`s (git history for this file, m25-f-1) — they route
            // through the same `model.performMenuCut/Copy/Paste` and need no
            // other change. The keystrokes would go with them.
            //
            // ⚠️ DELETE STAYS A BUTTON, and that is not an inconsistency: this
            // app does NOT claim `delete:` on the responder chain (see
            // `ClipboardResponderRouting.claimedSelectorNames`), because the ⌫
            // key already routes through `DeleteKeyMonitorRouting` →
            // `DeleteMenuPolicy` — a fix the user confirmed by hand on
            // 2026-08-12 and which nothing here may put a second route into.
            let item = model.deleteMenuItem
            Button(item.title, role: .destructive) { model.performMenuDelete() }
                .disabled(!item.isEnabled)

            // CONVERT VOICE… (m24-m leg B) — the SECOND, non-pointer route to
            // the selection-driven voice-conversion action the user ratified
            // 2026-08-13. The context menu is the first; both call
            // `openVoiceConvert(clipIDs:)` with ids resolved by the SAME
            // `VoiceConvertMenuPolicy`, so the label and the blast radius come
            // out of one producer.
            //
            // ⚠️ NO `.keyboardShortcut`, deliberately. It is not a destructive
            // item, so `role:` is omitted — conversion only ever APPENDS a track
            // and one undo removes it — but the m17-d hazard is about the
            // SHORTCUT, not the role: a menu key equivalent is checked before
            // text insertion, and this leg has no keystroke to offer anyway.
            //
            // ⚠️ AND IT IS SHOWN WHEN INERT (the m23-cf rule): greyed it reads
            // "Convert Clips to Voice…" with no count, teaching that the
            // operation exists and wants a selection of audio clips.
            Divider()
            let convert = model.voiceConvertMenuItem
            Button(convert.title) { model.performMenuVoiceConvert() }
                .disabled(!convert.isEnabled)
        }
    }

    private var undoTitle: String {
        store.undoLabel.map { "Undo \($0)" } ?? "Undo"
    }

    private var redoTitle: String {
        store.redoLabel.map { "Redo \($0)" } ?? "Redo"
    }

    @MainActor
    private func undo() {
        do { try store.undo() } catch { present(error) }
    }

    @MainActor
    private func redo() {
        do { try store.redo() } catch { present(error) }
    }

    /// Surfaces the store's error message verbatim in a standard alert.
    @MainActor
    private func present(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't complete that"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.runModal()
    }
}
