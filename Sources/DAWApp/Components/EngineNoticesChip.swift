import SwiftUI
import DAWCore
import DAWAppKit

/// The transport-bar ENGINE-NOTICES chip (m15-e, audit F6): a compact amber
/// warning that appears ONLY when the store's coalesced notices ring is
/// non-empty. Semantic AMBER (`DAWTheme.record` — the accent system's
/// warning/clipping-adjacent hue), the LOOP/PUNCH-chip construction (mono
/// readout, rounded glass, glow recipe). It earns its accent by state (Rule 3):
/// the glow means a real schedule-time degradation happened. Click toggles the
/// popover list.
struct EngineNoticesChip: View {
    let model: EngineNoticesModel
    /// Whether the popover is open (drives the pressed-in fill).
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                // Compact count = DISTINCT problems (see EngineNoticesModel.badgeCount).
                Text("\(model.badgeCount)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(DAWTheme.record)
            .frame(height: 26)
            .padding(.horizontal, 9)
            .background(DAWTheme.record.opacity(isOpen ? 0.22 : 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(DAWTheme.record.opacity(0.6), lineWidth: 1)
            )
            .glow(DAWTheme.record, radius: 5, intensity: 0.5)
        }
        .buttonStyle(.plain)
        .help(model.chipHelp)
    }
}

/// The engine-notices popover list (m15-e): a dark-glass card with a faint amber
/// hairline + subtle amber bloom (the glow recipe), listing each coalesced
/// notice newest-first. Rendered as an IN-WINDOW overlay (not a stock NSPopover
/// — the ContentView "a popover can't be captured" precedent, so `debug.captureUI`
/// snapshots it). Beginner-readable copy throughout (Rule 6). NO VIOLET.
struct EngineNoticesPopover: View {
    let model: EngineNoticesModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DAWTheme.hairline)

            // What these notices ARE, in plain language — the panel is honest
            // that nothing in the project changed (Rule 6 beginner test).
            Text("These sounds played on time, but not exactly as set. Nothing in your project was changed.")
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 2)

            ForEach(model.rows, id: \.code) { notice in
                noticeRow(notice)
            }
        }
        .frame(width: 320)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DAWTheme.record.opacity(0.28), lineWidth: 1)
        )
        .glow(DAWTheme.record, radius: 10, intensity: 0.12)
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.record)
            Text("PLAYBACK NOTICES")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(DAWTheme.textSecondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DAWTheme.textDim)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func noticeRow(_ notice: EngineNotice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(DAWTheme.record)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                    .glow(DAWTheme.record, radius: 4, intensity: 0.6)
                Text(notice.message)
                    .font(.system(size: 12))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let badge = EngineNoticesModel.repeatBadge(for: notice) {
                    // Per-entry repeat total — the fidelity the chip's
                    // distinct-count intentionally omits (see badgeCount).
                    Text(badge)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(DAWTheme.record)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DAWTheme.record.opacity(0.16))
                        .clipShape(Capsule())
                }
            }
            if let beat = EngineNoticesModel.beatLabel(for: notice) {
                Text(beat)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
                    .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
