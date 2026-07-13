import SwiftUI
import DAWCore
import DAWAppKit

/// The mixer AU-effect picker (m13-g, audit F6): a searchable browser of the
/// installed Audio Unit EFFECT plugins, opened from a Pro channel/bus strip's
/// insert add-menu ("Audio Units…"). It presents as a centered dark-glass modal
/// over a dimmed scrim (the instrument-picker idiom) — chosen over a menu/popover
/// so it renders INSIDE the main window content and `debug.captureUI` can snapshot
/// it headlessly (a menu lives in its own window, invisible to the cacheDisplay
/// path). A selection produces one `AudioUnitConfig` handed to `onChoose`, which
/// drives the SAME `store.addEffect(kind:.audioUnit, audioUnit:)` the wire's
/// `fx.add kind:"audioUnit"` uses (UI == wire).
///
/// PRO / TRACK-only by construction: reachable only from the Pro inserts section,
/// and never offered on the MASTER strip (built-ins only, v1). NO VIOLET —
/// standard signal-flow chrome, not AI content (docs/DESIGN-LANGUAGE.md Rule 3).
struct EffectPickerOverlay: View {
    @Bindable var model: EffectPickerModel
    /// The target track's name, for the header ("add an effect to ‹Bass›").
    var trackName: String
    /// Applies the chosen AU effect (wired to `store.addEffect`), then closes.
    var onChoose: (AudioUnitConfig) -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            card
                .frame(width: 480)
                .frame(maxHeight: 560)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchField
            Divider().overlay(DAWTheme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    let units = model.filteredAudioUnits
                    if units.isEmpty {
                        Text(model.audioUnits.isEmpty
                             ? "No Audio Unit effects are installed on this Mac."
                             : "No plugins match your search.")
                            .font(.system(size: 11))
                            .foregroundStyle(DAWTheme.textDim)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(units, id: \.component) { au in
                            row(au)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.textDim)
            Text("AUDIO UNIT EFFECT")
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(DAWTheme.textPrimary)
            Text("add to \(trackName)")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Close the effect picker")
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.textDim)
            TextField("Search effects…", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(DAWTheme.textPrimary)
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DAWTheme.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(DAWTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    private func row(_ au: AudioUnitComponentInfo) -> some View {
        Button { onChoose(model.config(for: au)) } label: {
            HStack(spacing: 9) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DAWTheme.textDim)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(au.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DAWTheme.textPrimary)
                            .lineLimit(1)
                        if au.isV3 { tag("AUv3") }
                    }
                    if !au.manufacturerName.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(au.manufacturerName)
                            .font(.system(size: 9.5))
                            .foregroundStyle(DAWTheme.textDim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DAWTheme.textPrimary)   // neutral create-chrome (Rule 3)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(DAWTheme.panelRaised.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(DAWTheme.textDim)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(DAWTheme.panelRaised)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(DAWTheme.hairline, lineWidth: 1))
    }
}
