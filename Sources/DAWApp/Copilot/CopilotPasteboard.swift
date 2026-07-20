import AppKit
import DAWAppKit

/// The real clipboard behind the copilot rail's copy affordances — the one
/// NSPasteboard touch point (general pasteboard: clearContents + setString,
/// the SettingsView copy-URL recipe). The seam (`CopilotPasteboarding`)
/// lives headless in DAWAppKit so `CopilotRailUIModel`'s copy logic is
/// tested against a fake and never touches the real clipboard.
struct GeneralPasteboard: CopilotPasteboarding {
    func write(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
