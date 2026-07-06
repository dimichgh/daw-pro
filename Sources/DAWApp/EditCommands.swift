import AppKit
import SwiftUI
import DAWCore

/// Edit-menu Undo / Redo, wired to `ProjectStore`'s undo journal. The item
/// titles fold in the next operation's label ("Undo Add Track 'Vox'") and the
/// items enable/disable live — `ProjectStore.journal` is observed, so reading
/// `canUndo`/`undoLabel` here re-evaluates the menu when history changes.
/// Failures surface the store's message verbatim via the same NSAlert pattern
/// as `FileCommands` (standard OS chrome, outside the glass-cockpit window).
struct EditCommands: Commands {
    let store: ProjectStore

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(undoTitle) { undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndo)
            Button(redoTitle) { redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!store.canRedo)
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
