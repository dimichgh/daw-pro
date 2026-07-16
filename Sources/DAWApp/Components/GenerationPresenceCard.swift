import SwiftUI
import DAWAppKit

/// The unified generation-progress card (m17-h) — the app's CANONICAL violet
/// surface: EVERY AI song job (Sketchpad, wire `ai.generateSong` / MCP
/// `generate_song`, stems / repaint / import paths) reports here, so a user
/// always sees ONE in-app presence for "the AI is working", whatever started
/// it. Status-chrome doctrine: an in-window card floated above the transport
/// bar's right status cluster (the engine-notices slot), NEVER a popover —
/// `debug.captureUI` must be able to snapshot it.
///
/// Per row: an origin chip (SKETCHPAD / AGENT / IMPORT), the job's label, the
/// stage line + percent + elapsed (SF Mono — numeric readouts are mono), and a
/// violet glowing progress bar under a slow shimmer (the ClipShimmer "working"
/// cue, never a spinner). FAILED flips the row's accent red and shows the
/// reason VERBATIM with a dismiss ✕; DONE reads green and clears itself after
/// a short linger. There is NO cancel button — ACE-Step's upstream job API has
/// no abort route, and offering a lie is worse than offering nothing.
///
/// All state + transitions live in the headless `GenerationPresenceModel`
/// (DAWAppKit); this view owns only the 1 s poll cadence (a `.task` loop — the
/// SketchpadView split) and dies with the card when the registry empties.
struct GenerationPresenceCard: View {
    var presence: GenerationPresenceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(presence.rows) { job in
                GenerationPresenceRow(
                    job: job,
                    stage: GenerationPresenceModel.stageLabel(for: job.phase),
                    percent: GenerationPresenceModel.percentText(for: job.phase),
                    fraction: GenerationPresenceModel.progressFraction(for: job.phase),
                    elapsed: presence.elapsedText(for: job),
                    onDismiss: { presence.dismiss(job.id) })
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DAWTheme.ai.opacity(0.35), lineWidth: 1)   // the AI surface's violet edge
        )
        .explainable(.generationCard)
        // The poll cadence: the model owns every transition, the view owns the
        // timer (the SketchpadView rule). The card only exists while jobs are
        // present, so the loop lives and dies with it; a pass with nothing
        // active is a cheap linger sweep.
        .task {
            while !Task.isCancelled {
                await presence.poll()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(DAWTheme.ai)
                .frame(width: 7, height: 7)
                .glow(DAWTheme.ai, radius: 5, intensity: 0.8)
            Text("AI GENERATION")
                .font(.system(size: 10, weight: .heavy))
                .tracking(2)
                .foregroundStyle(DAWTheme.textPrimary)
            Spacer(minLength: 0)
        }
    }
}

/// One job row — the SketchpadCandidateRow lifecycle body, generalized to the
/// origin-tagged presence registry.
private struct GenerationPresenceRow: View {
    var job: GenerationPresenceJob
    var stage: String
    var percent: String?
    var fraction: Double?
    var elapsed: String
    var onDismiss: () -> Void

    private var accent: Color {
        switch job.phase {
        case .failed: return DAWTheme.clip
        case .succeeded: return DAWTheme.signal
        default: return DAWTheme.ai
        }
    }

    private var isWorking: Bool { job.phase.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            identityLine
            statusLine
            if isWorking { progressBar }
            if case .failed(let reason) = job.phase { failureReason(reason) }
        }
        .padding(9)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(isWorking ? 0.5 : 0.38), lineWidth: 1)
        )
        // The "working" cue — a slow violet shimmer sweep, never a spinner.
        .overlay {
            if isWorking {
                SketchpadShimmer(tint: DAWTheme.ai)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .opacity(job.isStale ? 0.6 : 1)
    }

    private var identityLine: some View {
        HStack(spacing: 6) {
            Text(job.origin.displayLabel)
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(accent)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(accent.opacity(0.5), lineWidth: 1))
            Text(job.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DAWTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if job.isStale {
                Text("RECONNECTING")
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(DAWTheme.record)
            }
            if !job.phase.isActive {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DAWTheme.textDim)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if case .succeeded = job.phase {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(accent)
                    .glow(accent, radius: 4, intensity: 0.6)
            }
            Text(stage)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(accent)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(percent ?? (isWorking ? "—" : ""))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
            Text(elapsed)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.textSecondary)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DAWTheme.background)
                Capsule()
                    .fill(DAWTheme.ai)
                    .glow(DAWTheme.ai, radius: 4, intensity: 0.5)
                    .frame(width: max(4, geo.size.width * CGFloat(fraction ?? 0.06)))
            }
        }
        .frame(height: 4)
    }

    private func failureReason(_ reason: String) -> some View {
        Text(reason)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(DAWTheme.clip)
            .fixedSize(horizontal: false, vertical: true)
    }
}
