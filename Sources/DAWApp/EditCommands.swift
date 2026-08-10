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
    /// Read for the Delete item (m23-cf) and the three clipboard items
    /// (m23-ek-3) — every title, enabled state and action comes from an
    /// `AppModel` property backed by a DAWAppKit policy, never decided here.
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
            // ═══ CUT / COPY / PASTE (m23-ek-3) ═══
            //
            // ⚠️⚠️ THESE MUST NEVER GET `.keyboardShortcut("c"/"x"/"v", modifiers:
            // .command)`, AND THAT IS THE USER'S OWN RULING, asked and answered.
            // They were shown both arguments and chose the verifiable option; do
            // not add one "for convenience" without re-asking them.
            //
            //  (a) THE m17-d TRAP, TRANSPOSED. A `CommandGroup` item's key
            //      equivalent is checked BEFORE the responder chain, so ⌘C typed
            //      in a rename field would fire CLIP-COPY instead of copying the
            //      text — the mirror image of the Delete banner below, where the
            //      hazard runs the other way. ⭐ The hazard belongs to the
            //      SHORTCUT, not to the ITEM; with no key equivalent these carry
            //      none of it, and macOS's own ⌘C/⌘X/⌘V keep working on text
            //      exactly as they do today, natively, with no code here.
            //  (b) THE DECISIVE ONE — A KEY EQUIVALENT IS INVISIBLE TO EVERY GATE
            //      IN THIS TREE (the m23-g1 law, on `ExportMenuPolicy.swift:17-33`
            //      and `FileCommands.swift:47-55`): an unbundled staging binary
            //      does not route real key events, so ⌘C could only ever be
            //      verified by a `dist/DAWPro.app` rebuild plus hands, every time,
            //      forever. A menu item with no key equivalent is fully testable.
            //
            // The macOS-correct way to add the keystrokes is `copy:`/`cut:`/
            // `paste:` on the RESPONDER CHAIN, which lights up the NATIVE items
            // per surface and creates no outranking key equivalent at all. That
            // is a separate item, and its precondition is m23-cf's undiagnosed
            // DELETE key being diagnosed first.
            //
            // ORDERED CUT / COPY / PASTE, BEFORE DELETE — where macOS puts them,
            // so the group reads as a standard Edit menu (Cut / Copy / Paste /
            // Delete) and a user's eye lands where it already expects to.
            //
            // ⚠️ SHOWN-BUT-DISABLED on an empty selection or an empty clipboard,
            // never hidden: a menu that does not appear teaches nothing, and
            // "the operation exists and it wants a selection" is exactly what
            // m23-cf's reported bug denied users.
            //
            // ⚠️ UNMEASURED, AND HANDED BACK DELIBERATELY — THE INERT-TITLE
            // COLLISION. `after: .pasteboard` inserts this whole group AFTER
            // macOS's native Cut/Copy/Paste block, so with nothing selected and
            // an empty clipboard the menu reads: native Cut, Copy, Paste, then
            // OUR greyed "Cut", "Copy", "Paste" — six near-identical titles in a
            // row. `DeleteMenuPolicy.swift:32-38` hit the two-item version of
            // this, MEASURED IT by enumerating the live menu on staging, and
            // fixed it by renaming the inert title ("Delete Selection"). ⭐ THAT
            // MEASUREMENT HAS NOT BEEN REPEATED HERE and cannot be: menu
            // enumeration is not reachable from this seam (see the gate's SKIP
            // for the same reason). Do NOT cite the Delete precedent as if it
            // covered this. THE ONE-LINE REMEDY IF A HUMAN LOOKS AND DISLIKES
            // IT: give `ClipboardVerb.inertTitle` "Cut Selection" / "Copy
            // Selection" — the field already exists and is already the only
            // producer of these titles.
            let cut = model.cutMenuItem
            Button(cut.title) { model.performMenuCut() }
                .disabled(!cut.isEnabled)
            let copy = model.copyMenuItem
            Button(copy.title) { model.performMenuCopy() }
                .disabled(!copy.isEnabled)
            let paste = model.pasteMenuItem
            Button(paste.title) { model.performMenuPaste() }
                .disabled(!paste.isEnabled)

            let item = model.deleteMenuItem
            Button(item.title, role: .destructive) { model.performMenuDelete() }
                .disabled(!item.isEnabled)
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
