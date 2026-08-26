import SwiftUI
import DAWAppKit

/// View-menu zoom commands (m17-b, m21-c, m25-b-4): ⌘+/⌘− walk the
/// pixels-per-beat ladder, ⌘0 resets to the default scale, a Track Height
/// submenu sets the arrange's stepped S/M/L lane height, and a **Note Row
/// Height** submenu (⌃⌘=/−/0) walks the PIANO ROLL's pitch-row height — a
/// different surface from Track Height despite both being "row heights", and the
/// warning on `PanelLayoutStore.pianoRollRowHeightKey` says why the two must
/// never be conflated. Every action routes through the AppModel zoom
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
            // Note-editor ROW HEIGHT (m25-b-4) — the piano roll's vertical zoom,
            // the ⌘± items' twin on the pitch axis.
            //
            // ⚠️ **⌃⌘, NOT ⌥⌘, AND NOT THE SURFACE ROUTER.** Both of the obvious
            // choices are already spoken for and both would make a STATIC label
            // lie. ⌥⌘=/−/0 is Waveform Height, kept off the router on purpose one
            // block up; routing the rows through `zoomIn`/`zoomOut` would put two
            // meanings behind "Zoom In" on an axis basis. A menu item's words are
            // readable while its focus context is not, so a label that is only
            // sometimes true is the m23-t dishonest-readout failure in another
            // costume. These items always address the piano roll's rows; when no
            // roll is open they simply move a persisted preference the next roll
            // reads, which is what the header ± cluster does too.
            //
            // ⚠️ `=` NOT `+`, for the measured reason spelled out on the waveform
            // items above: `+` is physically ⇧=, and ⌃⇧= does not emit `+`.
            Divider()
            Menu("Note Row Height") {
                Button("Taller Rows") { model.rowZoomIn() }
                    .keyboardShortcut("=", modifiers: [.command, .control])
                Button("Shorter Rows") { model.rowZoomOut() }
                    .keyboardShortcut("-", modifiers: [.command, .control])
                Button("Reset Row Height") { model.rowZoomReset() }
                    .keyboardShortcut("0", modifiers: [.command, .control])
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
