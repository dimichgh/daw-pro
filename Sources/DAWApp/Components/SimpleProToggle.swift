import SwiftUI
import DAWAppKit

/// The shared SIMPLE / PRO density chip pair (docs/DESIGN-LANGUAGE.md "Panels").
/// Every panel's mode toggle is this one component, so the chip is pixel-identical
/// across the app: SF Mono 9 pt bold uppercase, tracking 0.6, the active half
/// cyan-lit (`DAWTheme.playback` on an 0.18 fill), the inactive half `textDim`, on
/// a raised chip with a hairline border. Extracted verbatim from the piano roll's
/// original inline `modeToggle`.
///
/// Store-bound (not a plain `Binding`) so the `debug.panelDensity` staging command
/// — which writes straight to the same `PanelDensityStore` — is reflected live in
/// the chip. Reusable: it takes a store + a stable panel ID as value inputs, so a
/// preview can drive it with an in-memory store just like the real app.
struct SimpleProToggle: View {
    /// The per-panel density store (owned by AppModel in the app, an in-memory
    /// store in previews/tests).
    var store: PanelDensityStore
    /// Stable panel identifier, e.g. `"pianoRoll"` — the key density is stored under.
    var panelID: String
    /// Tooltip describing what Simple hides and Pro reveals for this panel.
    var help: String = "Simple shows the essentials. Pro reveals every control."

    var body: some View {
        let current = store.density(forPanel: panelID)
        HStack(spacing: 0) {
            ForEach(PanelDensity.allCases, id: \.self) { candidate in
                let isOn = current == candidate
                Button {
                    store.setDensity(candidate, forPanel: panelID)
                } label: {
                    Text(candidate.label.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(isOn ? DAWTheme.playback : DAWTheme.textDim)
                        .frame(height: 20)
                        .padding(.horizontal, 9)
                        .background(isOn ? DAWTheme.playback.opacity(0.18) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        .help(help)
    }
}
