import SwiftUI
import AIServices
import DAWAppKit

/// The sung take's results card (p2-sing-f, design §5.6): once the take is in the song it shows the checks as they
/// finish ("Checking the notes…", "Checking the words…"), then the result line, green or amber, and [▶ Play from
/// here] [Try another take] [Choose a different voice], with the first-take tip. A floating status card (not a
/// modal): progress before landing is the unified progress card's (§5.5).
struct SingTakeCardView: View {
    var model: SingTakeModel

    private var accent: Color {
        switch model.row?.tone {
        case .green?: return DAWTheme.signal
        case .amber?, .failed?: return DAWTheme.record
        default: return DAWTheme.ai
        }
    }

    var body: some View {
        if let row = model.row {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(DAWTheme.ai).frame(width: 7, height: 7)
                        .glow(DAWTheme.ai, radius: 5, intensity: 0.8)
                    Text(SingCopy.takeTitle)
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(2)
                        .foregroundStyle(DAWTheme.textPrimary)
                    Spacer(minLength: 0)
                    Button { model.dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DAWTheme.textDim)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
                if let line = row.resultLine {
                    Text(line)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                        .glow(accent, radius: 4, intensity: row.tone == .green ? 0.45 : 0.2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(row.stage)
                        .font(.system(size: 11))
                        .foregroundStyle(DAWTheme.textSecondary)
                }
                ForEach(Array(row.notices.enumerated()), id: \.offset) { _, notice in
                    SingSentence(text: notice, color: DAWTheme.textDim, size: 10)
                }
                if let failure = row.failure { PanelRefusalLine(message: failure) }
                if row.showsResultButtons {
                    HStack(spacing: 6) {
                        SingButton(title: SingCopy.playFromHere, systemImage: "play.fill") { model.playFromHere() }
                        SingButton(title: SingCopy.tryAnotherTake, systemImage: "arrow.clockwise", role: .ai) {
                            Task { await model.tryAnotherTake() }
                        }
                    }
                    SingButton(title: SingCopy.chooseDifferentVoice, systemImage: "person.wave.2") {
                        model.chooseDifferentVoice()
                    }
                }
                if model.showsTip {
                    SingSentence(text: SingCopy.firstTakeTip, color: DAWTheme.textDim, size: 10)
                }
                if let refusal = model.refusal { PanelRefusalLine(message: refusal) }
            }
            .padding(12)
            .frame(width: 340, alignment: .leading)
            .background(DAWTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.4), lineWidth: 1))
        }
    }
}
