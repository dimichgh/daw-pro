import SwiftUI
import AIServices
import DAWCore
import DAWAppKit

/// "Add your voice" (p2-sing-f, design §5.4): pick a tune, the headphones question, record with a count-in and a
/// live meter, the check, then a name and [Save]. Thin over `SingVoiceRecorderModel`. Record and Stop wear the
/// record amber; nothing here is violet (recording a voice is the person's act, not the AI's).
struct SingVoiceRecorderView: View {
    @Bindable var model: SingVoiceRecorderModel
    var onChooseFile: () -> Void
    var onClose: () -> Void

    var body: some View {
        SingModalCard(width: 460, onScrimTap: nil) {
            VStack(alignment: .leading, spacing: 12) {
                SingCardHeader(systemImage: "mic", title: SingCopy.recorderTitle, tint: DAWTheme.record,
                               closeHelp: "Close the voice recorder", onClose: onClose)
                Divider().overlay(DAWTheme.hairline)
                content
                if let notice = model.notice { PanelRefusalLine(message: notice) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .closed:
            EmptyView()
        case .choose:
            choose
        case .askingPermission:
            SingSentence(text: SingCopy.micPermission, color: DAWTheme.textPrimary, size: 12)
        case .permissionDenied:
            SingSentence(text: SingCopy.micDenied, color: DAWTheme.record, size: 12)
            HStack {
                Spacer()
                SingButton(title: SingCopy.tryAgain, systemImage: "arrow.clockwise") {
                    model.answerHeadphones(model.wearsHeadphones ?? true)
                }
            }
        case .listening:
            SingSentence(text: SingCopy.listenFirst, color: DAWTheme.textPrimary, size: 12)
        case .ready:
            SingSentence(text: SingCopy.singNaturally, color: DAWTheme.textSecondary)
            HStack {
                Spacer()
                SingButton(title: SingCopy.record, systemImage: "record.circle", role: .record) { model.record() }
            }
        case .recording, .finishing:
            recording
        case .checking:
            SingSentence(text: SingCopy.checking, color: DAWTheme.textSecondary, size: 12)
        case .passed:
            passed
        case .failed(let sentence):
            SingSentence(text: sentence, color: DAWTheme.record, size: 12)
            HStack {
                Spacer()
                SingButton(title: SingCopy.recordAgain, systemImage: "record.circle", role: .record) {
                    model.record()
                }
            }
        case .saving:
            SingSentence(text: SingCopy.saving, color: DAWTheme.textSecondary, size: 12)
        case .saved(let sentence):
            SingSentence(text: sentence, color: DAWTheme.signal, size: 12)
            HStack {
                Spacer()
                SingButton(title: SingCopy.done, action: onClose)
            }
        }
    }

    // MARK: Steps 1 and 2

    private var choose: some View {
        VStack(alignment: .leading, spacing: 10) {
            SingSentence(text: SingCopy.pickTune, color: DAWTheme.textPrimary, size: 12)
            HStack(spacing: 8) {
                tuneButton(.high, title: SingCopy.higher)
                tuneButton(.low, title: SingCopy.lower)
            }
            SingSentence(text: SingCopy.headphonesQuestion, color: DAWTheme.textPrimary, size: 12)
            HStack(spacing: 8) {
                SingButton(title: SingCopy.headphonesYes, systemImage: "headphones") { model.answerHeadphones(true) }
                SingButton(title: SingCopy.headphonesNo, systemImage: "speaker.wave.2") {
                    model.answerHeadphones(false)
                }
            }
            Divider().overlay(DAWTheme.hairline)
            HStack(spacing: 8) {
                SingSentence(text: SingCopy.useExisting, color: DAWTheme.textDim, size: 10.5)
                Spacer()
                SingButton(title: SingCopy.chooseFile, systemImage: "folder", action: onChooseFile)
            }
        }
    }

    private func tuneButton(_ guide: SingGuideLine.Guide, title: String) -> some View {
        let picked = model.guide == guide
        return Button {
            model.pickAndPlay(guide)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(DAWTheme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(picked ? DAWTheme.panelRaised : DAWTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(picked ? DAWTheme.textSecondary.opacity(0.7) : DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: Step 3

    private var recording: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                phaseLabel
                Spacer()
                Text(String(format: "%4.1f s", model.elapsed))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DAWTheme.textSecondary)
            }
            countInDots
            SingLevelMeter(dbfs: model.levelDbfs)
                .frame(height: 10)
            SingSentence(text: SingCopy.singNaturally, color: DAWTheme.textDim, size: 10.5)
            HStack {
                Spacer()
                SingButton(title: SingCopy.stop, systemImage: "stop.fill", role: .record,
                           isEnabled: model.step == .recording) { model.stop() }
            }
        }
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch model.recordingPhase {
        case .getReady?, nil:
            Text(SingCopy.getReady).font(.system(size: 13, weight: .semibold)).foregroundStyle(DAWTheme.textPrimary)
        case .countIn(let beat)?:
            Text("\(beat)")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(DAWTheme.record)
                .glow(DAWTheme.record, radius: 6, intensity: 0.6)
        case .singing?:
            Text(SingCopy.singNow).font(.system(size: 13, weight: .semibold)).foregroundStyle(DAWTheme.record)
        }
    }

    private var countInDots: some View {
        let lit: Int = {
            switch model.recordingPhase {
            case .countIn(let beat)?: return beat
            case .singing?: return SingRecorderTiming.countInBeats
            default: return 0
            }
        }()
        return HStack(spacing: 6) {
            ForEach(1...SingRecorderTiming.countInBeats, id: \.self) { beat in
                Circle()
                    .fill(beat <= lit ? DAWTheme.record : DAWTheme.panelRaised)
                    .frame(width: 8, height: 8)
                    .glow(beat <= lit ? DAWTheme.record : .clear, radius: 4, intensity: beat <= lit ? 0.6 : 0)
            }
        }
    }

    // MARK: Step 4

    private var passed: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SingSentence(text: SingCopy.gotIt, color: DAWTheme.signal, size: 13)
                SingButton(title: SingCopy.listen, systemImage: model.playing == nil ? "play.fill" : "stop.fill") {
                    model.listen()
                }
            }
            HStack(spacing: 8) {
                Text(SingCopy.nameLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(DAWTheme.textSecondary)
                TextField(SingVoicePreparation.defaultName, text: $model.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(DAWTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
                SingButton(title: SingCopy.save, systemImage: "checkmark") { Task { await model.save() } }
                    .keyboardShortcut(.defaultAction)
            }
            HStack {
                Spacer()
                SingButton(title: SingCopy.recordAgain, systemImage: "record.circle", role: .record) {
                    model.record()
                }
            }
        }
    }
}

/// The live input level: a segmented bar, green → amber → red, its brightness following the level (the meter
/// recipe), and the dBFS readout in SF Mono.
struct SingLevelMeter: View {
    var dbfs: Double?

    private var fraction: Double {
        guard let dbfs else { return 0 }
        return min(1, max(0, (dbfs + 60) / 60))
    }

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                let segments = 24
                let lit = Int((fraction * Double(segments)).rounded())
                HStack(spacing: 2) {
                    ForEach(0..<segments, id: \.self) { i in
                        let zone = Double(i) / Double(segments)
                        let color = zone > 0.92 ? DAWTheme.clip : zone > 0.72 ? DAWTheme.record : DAWTheme.signal
                        RoundedRectangle(cornerRadius: 1)
                            .fill(i < lit ? color : DAWTheme.panelRaised)
                            .frame(width: max(1, (geo.size.width - CGFloat(segments - 1) * 2) / CGFloat(segments)))
                    }
                }
                .glow(DAWTheme.signal, radius: 4, intensity: 0.15 + 0.45 * fraction)
            }
            Text(dbfs.map { String(format: "%5.1f dB", $0) } ?? "  —  dB")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DAWTheme.textSecondary)
                .frame(width: 64, alignment: .trailing)
        }
    }
}
