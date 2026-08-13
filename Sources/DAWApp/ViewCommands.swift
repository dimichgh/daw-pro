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
            // Waveform height (m25-e) — the ⌘± items' VERTICAL sibling, on ⌥⌘±
            // so the two axes read as one family. DELIBERATELY off the
            // `zoomIn`/`zoomOut` surface router: ⌘± means "more or less TIME" on
            // whichever editor has focus, and the piano roll has no waveform to
            // scale, so routing these would make one keystroke mean two unrelated
            // things. They always address the arrange waveforms.
            Divider()
            Menu("Waveform Height") {
                Button("Fit to Clip Height") { model.setWaveformNormalize(true) }
                Button("True Level") { model.setWaveformNormalize(false) }
                Divider()
                // ⚠️ `=`, NOT `+`, and the difference is load-bearing. A SwiftUI
                // key equivalent matches a CHARACTER: `+` is physically ⇧=, so
                // the zoom-in chord here would be ⌥⇧⌘=, which on a US layout
                // emits `±` rather than `+` — a dead menu item, and the one that
                // matters most (this is the fast path the feature exists for).
                // ⌥⌘= carries no Shift, so the character is unambiguously `=`.
                // The sibling ⌘+ item above gets away with `+` only because
                // ContentView:326 carries a hidden bare-⌘= alias for exactly this
                // reason; a submenu item cannot host a second equivalent, so this
                // one takes the unambiguous key directly. ⌥⌘− and ⌥⌘0 are
                // unaffected — Option does not remap those.
                Button("Taller Waveforms") { model.waveformZoomIn() }
                    .keyboardShortcut("=", modifiers: [.command, .option])
                Button("Shorter Waveforms") { model.waveformZoomOut() }
                    .keyboardShortcut("-", modifiers: [.command, .option])
                Button("Reset Waveform View") { model.waveformZoomReset() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
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
