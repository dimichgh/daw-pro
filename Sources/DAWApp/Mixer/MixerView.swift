import SwiftUI
import DAWCore
import DAWAppKit

/// The full mixing console: a horizontal rack of channel strips (audio +
/// instrument tracks in project order), then the visually-grouped bus strips,
/// with the master strip pinned at the right. Overflows horizontally; the
/// master stays in view. A thin surface over `ProjectStore` + `MixerLayout` —
/// no local mixing state of its own.
struct MixerView: View {
    @Environment(ProjectStore.self) private var store
    /// The console's shared density store (docs/DESIGN-LANGUAGE.md "Panels").
    /// Threaded to every channel/bus strip; the master strip never reads it
    /// (its modes coincide). The SIMPLE/PRO chip in the Mix toolbar binds the
    /// same store under `panelID`.
    var densityStore: PanelDensityStore

    /// Stable density key for the whole mixer console — the console is ONE panel,
    /// so every strip and the toolbar chip share this one ID.
    static let panelID = "mixer"

    var body: some View {
        let channels = MixerLayout.channelTracks(store.tracks)
        let buses = MixerLayout.busTracks(store.tracks)

        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 10) {
                    if channels.isEmpty && buses.isEmpty {
                        emptyState
                    } else {
                        // Every strip is explainable (ex-b): per-instance frame
                        // anchoring (ExplainCoordinator) lands each shared ExplainID
                        // on whichever strip is hovered, so a full console tags cleanly.
                        ForEach(channels) { track in
                            MixerChannelStrip(track: track, densityStore: densityStore)
                        }
                        if !buses.isEmpty {
                            busDivider
                            ForEach(buses) { MixerChannelStrip(track: $0, densityStore: densityStore) }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Master is outside the scroller so it stays pinned at the right.
            MixerMasterStrip()
                .padding(.vertical, 12)
                .padding(.leading, 8)
                .padding(.trailing, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(cornerRadius: 12)
    }

    /// A slim separator + caption that marks where the bus group begins.
    private var busDivider: some View {
        VStack(spacing: 8) {
            Text("BUSES")
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DAWTheme.textDim)
            Rectangle()
                .fill(DAWTheme.hairline)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 26))
                .foregroundStyle(DAWTheme.textFaint)
            Text("No tracks to mix yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DAWTheme.textDim)
            Text("Add a track in Arrange, or let an agent do it over MCP")
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Arrange ⇄ Mix workspace switch — the themed segmented chip pair described in
/// DESIGN-LANGUAGE (active half cyan-lit), matching the Simple/Pro control idiom.
struct WorkspaceToggle: View {
    var mode: WorkspaceMode
    var onSelect: (WorkspaceMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment("Arrange", .arrange)
            segment("Mix", .mix)
        }
        .padding(2)
        .background(DAWTheme.panelRaised)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(DAWTheme.hairline, lineWidth: 1))
    }

    private func segment(_ label: String, _ value: WorkspaceMode) -> some View {
        let active = mode == value
        return Button { onSelect(value) } label: {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(active ? DAWTheme.playback : DAWTheme.textDim)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(active ? DAWTheme.playback.opacity(0.16) : Color.clear)
                .clipShape(Capsule())
                .glow(DAWTheme.playback, radius: 4, intensity: active ? 0.4 : 0)
        }
        .buttonStyle(.plain)
    }
}
