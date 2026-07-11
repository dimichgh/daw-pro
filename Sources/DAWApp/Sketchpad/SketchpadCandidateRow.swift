import SwiftUI
import DAWCore
import DAWAppKit

/// One candidate row in the Sketchpad list (M6 iii-b). A violet-accented glass
/// card whose body reflects the candidate's `state`: a shimmer + progress bar
/// while generating, an SF Mono metadata readout + preview/import controls when
/// succeeded, a red-bordered message when failed, and a violet IMPORTED badge
/// with the created track's name once landed. `isStale` (a transient poll/import
/// blip) dims the card and shows a quiet "reconnecting" hint — the take survives.
struct SketchpadCandidateRow: View {
    var candidate: SketchpadCandidate
    var isPlaying: Bool
    var onPlayToggle: (String) -> Void      // passed the audio path
    var onImport: () -> Void
    var onDismiss: () -> Void

    private var accent: Color {
        switch candidate.state {
        case .failed: return DAWTheme.clip
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
        // While generating, the "working" cue — a slow violet shimmer sweep
        // (the ClipShimmer recipe), clipped to the card.
        .overlay {
            if isGenerating {
                SketchpadShimmer(tint: DAWTheme.ai)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }
        .opacity(candidate.isStale ? 0.6 : 1)
    }

    private var isActive: Bool { candidate.state.isActive }
    private var isGenerating: Bool {
        switch candidate.state {
        case .queued, .running: return true
        default: return false
        }
    }

    private var headerLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 10))
                .foregroundStyle(accent)
            Text(candidate.promptSnippet)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DAWTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if candidate.isStale {
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
                .help("Dismiss this candidate")
            }
        }
    }

    private var isTerminalDismissable: Bool {
        switch candidate.state {
        case .failed, .imported: return true
        default: return false
        }
    }

    @ViewBuilder
    private var stateBody: some View {
        switch candidate.state {
        case .queued:
            statusLine(text: "QUEUED", color: DAWTheme.textDim)
            progressBar(nil)
        case .running(let progress, let statusText):
            HStack {
                statusLine(text: statusText?.uppercased() ?? "GENERATING", color: DAWTheme.ai)
                Spacer()
                Text(progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DAWTheme.ai)
            }
            progressBar(progress)
        case .succeeded(let audioPath, let bpm, let duration):
            succeededBody(audioPath: audioPath, bpm: bpm, duration: duration)
        case .failed(let message):
            Text(message)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DAWTheme.clip)
                .fixedSize(horizontal: false, vertical: true)
        case .imported(_, let trackName):
            importedBody(trackName: trackName)
        }
    }

    private func statusLine(text: String, color: Color) -> some View {
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

    private func succeededBody(audioPath: String, bpm: Double?, duration: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // SF Mono metadata readout.
            HStack(spacing: 10) {
                if let bpm { readout("\(Int(bpm.rounded()))", "BPM") }
                if let duration { readout("\(Int(duration.rounded()))s", "LEN") }
                Spacer()
            }
            HStack(spacing: 8) {
                Button { onPlayToggle(audioPath) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        Text(isPlaying ? "STOP" : "PREVIEW")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(DAWTheme.playback)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.playback.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)

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
                .help("Add this take to the project as a new violet AI track")
                Spacer(minLength: 0)
            }
        }
    }

    private func readout(_ value: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.textPrimary)
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(DAWTheme.textDim)
        }
    }

    private func importedBody(trackName: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.ai)
                .glow(DAWTheme.ai, radius: 4, intensity: 0.6)
            Text("IMPORTED")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(DAWTheme.ai)
            Text("→ \(trackName)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// The generating "working" cue — a slow violet diagonal highlight sweep,
/// mirroring the timeline's `ClipShimmer` recipe (docs/DESIGN-LANGUAGE.md: a
/// subtle animated sweep, never a spinner). Self-animating; the parent removes
/// it the instant the candidate leaves a generating state.
struct SketchpadShimmer: View {
    var tint: Color
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let band = max(28, w * 0.4)
            LinearGradient(
                colors: [.clear, tint.opacity(0.28), Color.white.opacity(0.18),
                         tint.opacity(0.28), .clear],
                startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: -band + phase * (w + band))
                .blendMode(.screen)
                .onAppear {
                    withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        }
        .allowsHitTesting(false)
    }
}
