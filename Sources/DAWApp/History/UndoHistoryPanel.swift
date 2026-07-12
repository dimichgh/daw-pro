import SwiftUI
import DAWCore
import DAWAppKit

/// The Undo-history panel (m11-b): a face for the undo/redo journal that already
/// tracks labeled 100-entry stacks. It presents as a centered dark-glass modal
/// card over a dimmed scrim (the Quantize / instrument-picker overlay idiom) —
/// rendered INSIDE the main window content so `debug.captureUI` can snapshot it
/// headlessly (a popover lives in its own window, invisible to the window
/// cacheDisplay path).
///
/// One chronological list with a clear "you are here" marker: REDO entries sit
/// ABOVE it (the dimmed "future" you can reapply), UNDO entries BELOW it (the past
/// you can reverse), each NEWEST-adjacent-to-the-marker. Clicking a row jumps
/// there via REPEATED `ProjectStore.undo()`/`redo()` calls only (the model's step
/// plan) — no new mutation surface; the coalescing barrier and mid-take guard
/// still apply. Hover reveals how many steps a row is from now.
///
/// NO VIOLET anywhere — undo history is standard editing chrome, not AI content
/// (docs/DESIGN-LANGUAGE.md Rule 3). Cyan marks only the earned active state: the
/// current-position marker.
///
/// **Density decision** (docs/research/simple-pro-inventory.md): COINCIDENT-EXEMPT
/// — a single list of labels has no advanced controls to hide, so Simple and Pro
/// would be identical. No do-nothing SIMPLE/PRO chip (the master-strip precedent).
struct UndoHistoryPanel: View {
    var model: UndoHistoryModel
    var onClose: () -> Void

    /// Which row is hovered (its `Row.id`) — drives the trailing step-count hint.
    @State private var hoveredRowID: String?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            card
                .frame(width: 340)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().overlay(DAWTheme.hairline)
            if model.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .padding(16)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
        .explainable(.editHistory)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.textDim)
            Text("HISTORY")
                .font(.system(size: 12, weight: .heavy))
                .tracking(2)
                .foregroundStyle(DAWTheme.textPrimary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Close the history panel")
        }
    }

    // MARK: - Empty state (honest)

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 12))
                .foregroundStyle(DAWTheme.textFaint)
            Text("No edits yet — your changes will appear here as you make them.")
                .font(.system(size: 10.5))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: - History list

    private var list: some View {
        // Bounded scroll so a deep (up-to-100) stack never blows the card past the
        // window; short histories still hug (the card sizes to content).
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                // Future (redo) — dimmed, above the marker; newest-redo lands last
                // so it sits directly above "you are here".
                ForEach(model.redoRows) { row in
                    historyRow(row)
                }
                marker
                // Past (undo) — below the marker; newest-undo first (adjacent).
                ForEach(model.undoRows) { row in
                    historyRow(row)
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxHeight: 360)
    }

    /// The "you are here" divider between redo (future) and undo (past). Cyan is
    /// the one earned active state on this panel — it marks the live position.
    private var marker: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(DAWTheme.playback)
                .frame(width: 7, height: 7)
                .glow(DAWTheme.playback, radius: 4, intensity: 0.7)
            Text("YOU ARE HERE")
                .font(.system(size: 9, weight: .heavy))
                .tracking(1.4)
                .foregroundStyle(DAWTheme.playback)
            Rectangle()
                .fill(DAWTheme.playback.opacity(0.35))
                .frame(height: 1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
    }

    private func historyRow(_ row: UndoHistoryModel.Row) -> some View {
        let isRedo = row.direction == .redo
        let hovered = hoveredRowID == row.id
        return Button {
            model.step(row)
        } label: {
            HStack(spacing: 8) {
                // Direction glyph: future points up-and-back-in (redo), past points
                // down-and-out (undo) — a quiet cue, not a semantic accent.
                Image(systemName: isRedo ? "arrow.uturn.forward" : "arrow.uturn.backward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DAWTheme.textFaint)
                    .frame(width: 12)
                Text(row.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isRedo ? DAWTheme.textDim : DAWTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // Hover reveals the step count — how far this row is from now.
                if hovered {
                    Text(stepHint(row))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(DAWTheme.textFaint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovered ? DAWTheme.panelRaised.opacity(0.7) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredRowID = $0 ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID) }
        .help(isRedo
              ? "Redo forward to here (\(row.stepCount) step\(row.stepCount == 1 ? "" : "s"))"
              : "Undo back to here (\(row.stepCount) step\(row.stepCount == 1 ? "" : "s"))")
    }

    /// The trailing hover hint: how many steps, in which direction.
    private func stepHint(_ row: UndoHistoryModel.Row) -> String {
        let n = row.stepCount
        let unit = n == 1 ? "step" : "steps"
        return row.direction == .redo ? "↷ \(n) \(unit)" : "↶ \(n) \(unit)"
    }
}
