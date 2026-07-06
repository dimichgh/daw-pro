import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DAWCore

/// File menu for session persistence: New / Open / Save / Save As, wired to
/// `ProjectStore`. Standard macOS panels and alerts are used deliberately —
/// they're OS chrome, outside the glass-cockpit main window. Every failure
/// surfaces the store's message verbatim so the user reads the same actionable
/// text an agent would.
struct FileCommands: Commands {
    let store: ProjectStore

    /// The `.dawproj` package type, if the OS can resolve it from the extension.
    private var dawprojType: UTType? { UTType(filenameExtension: ProjectBundle.fileExtension) }

    var body: some Commands {
        // Replace the default New Item group so ⌘N maps to a new session.
        CommandGroup(replacing: .newItem) {
            Button("New Project") { newProject() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open…") { openProject() }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Save As…") { saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }

    @MainActor
    private func newProject() {
        do { try store.newProject() } catch { present(error) }
    }

    @MainActor
    private func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true  // a .dawproj bundle is a directory
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if let dawprojType { panel.allowedContentTypes = [dawprojType] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.openProject(at: url.path) } catch { present(error) }
    }

    /// ⌘S: save in place, or fall through to the Save As flow when the session
    /// is still untitled (no bundle to save into yet).
    @MainActor
    private func save() {
        guard store.projectPath != nil else { saveAs(); return }
        do { try store.saveProject(to: nil) } catch { present(error) }
    }

    @MainActor
    private func saveAs() {
        let panel = NSSavePanel()
        panel.directoryURL = Self.defaultProjectsDirectory
        panel.nameFieldStringValue = store.projectName
        panel.prompt = "Save"
        if let dawprojType { panel.allowedContentTypes = [dawprojType] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.saveProject(to: url.path) } catch { present(error) }
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

    /// Default Save As location: `~/Documents/DAW Pro/`.
    private static var defaultProjectsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent("DAW Pro", isDirectory: true)
    }
}
