import SwiftUI
import DAWAppKit

/// View-menu zoom commands (m17-b, m21-c): ⌘+/⌘− walk the pixels-per-beat
/// ladder, ⌘0 resets to the default scale, and a Track Height submenu sets the
/// stepped S/M/L row height. Every action routes through the AppModel zoom
/// ROUTER (`zoomIn`/`zoomOut`/`zoomReset`): while the piano-roll editor holds
/// key focus the keys zoom the ROLL, otherwise the arrange timeline through
/// the SAME entry points the toolbar cluster and `debug.arrangeZoom` use, so
/// the playhead-anchored no-jump rule applies identically from every driver.
/// (macOS convention note: ⌘+ is physically ⌘⇧=; the bare ⌘= alias is caught
/// by a hidden in-window shortcut in ContentView, since one menu item can
/// carry only one key equivalent.)
struct ViewCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Zoom to Default") { model.zoomReset() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Menu("Track Height") {
                ForEach(ArrangeZoom.RowStep.allCases, id: \.self) { step in
                    Button {
                        model.setArrangeRowStep(step)
                    } label: {
                        if model.arrangeRowStep == step {
                            Label(title(step), systemImage: "checkmark")
                        } else {
                            Text(title(step))
                        }
                    }
                }
            }
        }
    }

    private func title(_ step: ArrangeZoom.RowStep) -> String {
        switch step {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}
