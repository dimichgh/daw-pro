import SwiftUI
import DAWCore
import DAWAppKit

/// One AI-fix job card in the panel's jobs strip (M6 v-b-2). A violet-accented
/// glass card whose body follows the card's `state`: a shimmer + progress bar
/// while running, a violet IMPORT button once the fix is ready, a violet IMPORTED
/// badge with the created lane's name, a red-bordered message on a hard failure,
/// and an amber message when the target drifted (`stale`). A transient poll/import
/// blip (`isStale`) dims the card to 60 % and shows a quiet RECONNECTING tag while
/// it keeps polling — the take survives (the Sketchpad stale-tolerance rule).
struct ClipFixJobCard: View {
    var card: ClipFixCard
    var onImport: () -> Void
    var onDismiss: () -> Void

    private var accent: Color {
        switch card.state {
        case .failed: return DAWTheme.clip
        case .stale: return DAWTheme.record
        default: return DAWTheme.ai
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            headerLine
            stateBody
        }
        .padding(10)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(accent.opacity(isActive ? 0.5 : 0.32), lineWidth: 1)
        )
        // While running, the "working" cue — a slow violet shimmer sweep (the
        // shared ClipShimmer recipe), clipped to the card.
        .overlay {
            if isRunning {
                SketchpadShimmer(tint: DAWTheme.ai)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }
        .opacity(card.isStale ? 0.6 : 1)
    }

    private var isActive: Bool { card.state.isActive }
    private var isRunning: Bool {
        switch card.state {
        case .pending, .running: return true
        default: return false
        }
    }

    private var headerLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 10))
                .foregroundStyle(accent)
            Text(regionLabel)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if card.isStale {
                Text("RECONNECTING")
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(DAWTheme.record)
            }
            if isTerminalDismissable {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DAWTheme.textDim)
                }
                .buttonStyle(.plain)
                .help("Dismiss this fix")
            }
        }
    }

    /// "beats 33–41" — the region this fix targets, in SF Mono.
    private var regionLabel: String {
        "beats \(Self.beats(card.regionStartBeat))–\(Self.beats(card.regionEndBeat))"
    }
    private static func beats(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private var isTerminalDismissable: Bool {
        switch card.state {
        case .failed, .stale, .imported: return true
        default: return false
        }
    }

    @ViewBuilder
    private var stateBody: some View {
        switch card.state {
        case .pending:
            statusLine("QUEUED", DAWTheme.textDim)
            progressBar(nil)
        case .running(let progress, let statusText):
            HStack {
                statusLine(statusText?.uppercased() ?? "GENERATING", DAWTheme.ai)
                Spacer()
                Text(progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DAWTheme.ai)
            }
            progressBar(progress)
        case .succeededAwaitingImport:
            succeededBody
        case .imported(let laneName):
            importedBody(laneName: laneName)
        case .failed(let message):
            Text(message)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DAWTheme.clip)
                .fixedSize(horizontal: false, vertical: true)
        case .stale(let message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.record)
                Text(message)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DAWTheme.record)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusLine(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(color)
    }

    private func progressBar(_ progress: Double?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DAWTheme.background)
                Capsule()
                    .fill(DAWTheme.ai)
                    .glow(DAWTheme.ai, radius: 4, intensity: 0.5)
                    .frame(width: max(4, geo.size.width * CGFloat(progress ?? 0.06)))
            }
        }
        .frame(height: 4)
    }

    private var succeededBody: some View {
        HStack(spacing: 8) {
            Text("READY")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(DAWTheme.signal)
            Spacer(minLength: 0)
            Button(action: onImport) {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text("IMPORT")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(DAWTheme.ai)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .glow(DAWTheme.ai, radius: 6, intensity: 0.55)
            }
            .buttonStyle(.plain)
            .help("Comp this AI fix in over the region as a new violet take lane")
        }
    }

    private func importedBody(laneName: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.ai)
                .glow(DAWTheme.ai, radius: 4, intensity: 0.6)
            Text("IMPORTED")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(DAWTheme.ai)
            Text("→ \(laneName)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}
