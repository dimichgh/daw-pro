import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

/// Edit-menu Undo / Redo / Delete, wired to `ProjectStore`'s undo journal and the
/// app's three deletable surfaces. The item
/// titles fold in the next operation's label ("Undo Add Track 'Vox'") and the
/// items enable/disable live — `ProjectStore.journal` is observed, so reading
/// `canUndo`/`undoLabel` here re-evaluates the menu when history changes.
/// Failures surface the store's message verbatim via the same NSAlert pattern
/// as `FileCommands` (standard OS chrome, outside the glass-cockpit window).
struct EditCommands: Commands {
    let store: ProjectStore
    /// Read for the Delete item only (m23-cf) — its title, its enabled state and
    /// its action all come from `AppModel.deleteMenuItem` / `performMenuDelete`.
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
