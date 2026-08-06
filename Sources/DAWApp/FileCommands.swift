import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DAWCore
import DAWAppKit

/// File menu for getting a session in and out of the app: New / Open / Save /
/// Save As, the two imports (audio, MIDI) and the two exports (audio, MIDI),
/// wired to `ProjectStore` / `AppModel`. Standard macOS panels and alerts are used
/// deliberately — they're OS chrome, outside the glass-cockpit main window. Every
/// failure surfaces the store's message verbatim so the user reads the same
/// actionable text an agent would.
///
/// This target has NO test target, so nothing here may DECIDE anything: the one
/// item whose title or enabled state varies (Export Audio…, m23-dd) takes both
/// from `DAWAppKit.ExportMenuPolicy`, which is testable headless. Everything else
/// here is a fixed title over a store call.
struct FileCommands: Commands {
    let store: ProjectStore
    /// The app model — owns the shared audio-import execution path (beta m10-k), so
    /// the menu import runs the SAME `AudioImportPlan` pipeline as the drag-drop.
    let model: AppModel

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
            // Import your own audio / stems / vocals (beta m10-k). Multi-select →
            // one new audio track per file at the playhead (the stems fan-out).
            Button("Import Audio…") { importAudio() }
                .keyboardShortcut("i", modifiers: .command)
            // Standard MIDI Files (m23-k4b) — the first way to reach m23-k3/k4a
            // without an agent on the control port.
            Button("Import MIDI…") { importMIDI() }
            // Bouncing the song to disk (m23-dd). A user reported this missing
            // and it was: audio export was reachable ONLY from the transport
            // bar's EXPORT chip and the onboarding tour's export step — no menu
            // anywhere — while the MIDI export below has had one since m23-k4b.
            //
            // ⚠️⚠️ NO `.keyboardShortcut`, DELIBERATELY, and this is not an
            // oversight to be tidied up later. m23-g1: an unbundled staging
            // binary does not route real key events, so a key equivalent cannot
            // be verified by any gate here — only by `dist/DAWPro.app` and the
            // user's hands. And m23-cf is still OPEN on an undiagnosed DELETE
            // key that never reaches its handlers; adding a second key path
            // before the first is understood makes both harder to diagnose. The
            // full argument, including why the ITEM carries none of the
            // SHORTCUT's hazard, is on `ExportMenuPolicy`.
            //
            // BEFORE "Export MIDI…" so the menu reads as a 2×2 — Import Audio /
            // Import MIDI over Export Audio / Export MIDI — and because audio is
            // the export a song is finished by. Neither export has a key
            // equivalent, so nothing's muscle memory moves.
            //
            // ⚠️ THE ACTION IS `model.exportSong()` AND NOTHING ELSE. That is
            // the same entry point the transport chip uses; it opens the Export
            // dialog, and the save panel comes later from the dialog's own
            // button (`runExportFromDialog`), which is what lets the panel offer
            // the chosen container. A menu that ran its own `NSSavePanel` — the
            // idiom every other item in this file uses — would silently re-ship
            // the pre-m23-m3 hardcoded-`.wav` export beside the real one.
            //
            // Title and enabled state both come from `ExportMenuPolicy`
            // (`DAWAppKit`): this target has no test target, so a `FileCommands`
            // that DECIDED anything would be untestable by construction. Reading
            // `store.tracks` here is what keeps the item live — it is
            // `@Observable`, so the menu re-evaluates when the first track
            // arrives.
            let exportAudio = ExportMenuPolicy.fileMenuItem(trackCount: store.tracks.count)
            Button(exportAudio.title) { model.exportSong() }
                .disabled(!exportAudio.isEnabled)
            Button("Export MIDI…") { exportMIDI() }
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

    /// ⌘I: import one or more audio files at the playhead. NSOpenPanel is restricted
    /// to audio types and allows multi-select; the URLs run through the shared plan →
    /// execution path (one undo step for the whole set). Any per-file failure surfaces
    /// verbatim, the store-error idiom. A menu import has no drop target, so a single
    /// file makes a new audio track and multiple files fan out to one track each.
    ///
    /// m23-k4b NARROWED the panel: it used to say `[.audio]`, and because
    /// `public.midi-audio` conforms to `public.audio` a `.mid` was SELECTABLE
    /// here and then died in the plan with "isn't a supported audio file". The
    /// derived list names the concrete types this app actually reads, so the
    /// refusal happens at the panel — where "this file is greyed out" is the
    /// whole message — and MIDI has its own menu item below.
    @MainActor
    private func importAudio() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.allowedContentTypes = AudioImportPlan.audioContentTypes
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        runImport(urls: panel.urls)
    }

    /// File→Import MIDI… (m23-k4b): import one or more Standard MIDI Files as new
    /// instrument tracks, landing at the playhead — resolved through
    /// `resolvedImportBeat`, the SAME one home ⌘I uses, never a bare
    /// `positionBeats` (a menu import snaps to the arrange grid like a drop does).
    ///
    /// Two things worth knowing, both inherited from `project.importMIDI` (m23-k3)
    /// rather than decided here: the default tempo policy is `.auto`, so a file
    /// dropped into a project that has NO clips yet brings its own tempo and meter
    /// map with it; and each file is its own undo step.
    @MainActor
    private func importMIDI() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.allowedContentTypes = AudioImportPlan.midiContentTypes
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        runImport(urls: panel.urls)
    }

    /// File→Export MIDI… (m23-k4b): write the WHOLE project out as a Standard
    /// MIDI File. The single-track verb (`track.exportMIDI`) got its own surface
    /// at m23-m3b, and deliberately NOT here: this menu still has no track
    /// selection to read (the app has no track-selection domain at all —
    /// selecting a track selects its clips), so the per-track item lives in the
    /// track-header context menu, which has the track identity in hand.
    ///
    /// Export mutates nothing, so there is no undo step and no success alert;
    /// only a refusal (a project with no instrument content, an unwritable
    /// destination) surfaces, verbatim.
    @MainActor
    private func exportMIDI() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = store.projectName
        panel.prompt = "Export"
        panel.allowedContentTypes = AudioImportPlan.midiContentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportMIDIFile(path: url.path) } catch { present(error) }
    }

    /// The shared tail of both import menu items: run the URLs through the ONE
    /// execution path (`AudioImportPlan` → store) and report per-file failures.
    /// Both items call it, so neither can drift from the drag-drop's behaviour.
    @MainActor
    private func runImport(urls: [URL]) {
        let results = model.importFiles(
            urls: urls, targetTrackID: nil,
            startBeat: model.resolvedImportBeat(rawBeat: store.transport.positionBeats))
        let failures = results.filter { $0.error != nil }
        if !failures.isEmpty { presentImportFailures(failures) }
    }

    /// Lists any files that couldn't be imported (unreadable / unsupported), each
    /// with the store's verbatim reason — the `present(_:)` alert idiom.
    @MainActor
    private func presentImportFailures(_ failures: [AudioImportFileResult]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1
            ? "One file couldn't be imported"
            : "\(failures.count) files couldn't be imported"
        alert.informativeText = failures.map { result in
            "\((result.path as NSString).lastPathComponent): \(result.error ?? "unknown error")"
        }.joined(separator: "\n")
        alert.runModal()
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
