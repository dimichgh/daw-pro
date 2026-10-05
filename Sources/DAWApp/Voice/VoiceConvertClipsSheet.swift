import SwiftUI
import DAWCore
import DAWAppKit
import AIServices

/// The **Convert Voice…** panel (m24-m leg B) — the user-facing half of per-clip
/// voice conversion, and the shape the user ratified 2026-08-13 (*"I agree on
/// this"*): SELECT clips → this action → pick a voice → ONE new track carrying a
/// converted counterpart of every selected clip, at the same beats.
///
/// It is another instance of the **centered dark-glass modal over a dimmed
/// scrim** — the NAMED in-window pattern (Settings / Instrument Picker /
/// Quantize / Undo History / Effect Editor / Export), never a popover or a child
/// window, so `debug.captureUI` photographs it.
///
/// ⛔ **THE INSERT/PLUGIN ROUTE IS WITHDRAWN** — the user sketched it themselves,
/// invited comment and chose this instead. There is no insert here and must not
/// be. ⛔ **Dragging a voice model onto a track is LEG C**, a second entry point
/// into this action; it will open this same panel.
///
/// **VIOLET is the through-line** (Rule 3): a voice model is AI identity and
/// conversion output is AI-generated audio, so the card takes the violet edge,
/// the picked voice row is violet-lit, and the primary button and progress bar
/// are violet. Numbers stay **cyan SF Mono** — the Sketchpad length-stepper rule
/// (a readout is a readout, not an AI signal).
///
/// ## The three states, and what each one promises
///
/// **Composer.** The engine banner (user copy, never wire-speak), the voice
/// picker — the SAME `VoiceChoiceRow` the Voice panel's list uses, so READY /
/// NEEDS PREP / INCOMPLETE reads identically in both places — the exact set of
/// clips that will convert, and the pitch stepper.
///
/// ⭐ **THE CLIP LIST IS HOW THE GOOD PATH IS MADE OBVIOUS.** Leg A refuses an
/// empty set, a duplicate id, an unknown id, a MIDI clip and two selected clips
/// that overlap in beats — all BEFORE doing any work. This panel does not
/// re-derive any of those rules (that would be a second home for them, and the
/// two would drift); it shows the set, named and with its beat spans, at the one
/// moment when noticing the wrong take is still cheap.
///
/// **Converting.** ⭐ **A SPINNER IS NOT PROGRESS.** A real conversion is
/// seconds-to-minutes per clip and leg A runs them serially, so the block names
/// which clip of how many (`CLIP 2/5`), what is happening to it in plain
/// language, a bar that steps on completed work only, and a **ticking elapsed
/// readout** so a live run is distinguishable from a hung one. The violet
/// shimmer is the house "working" cue (the ClipShimmer/Sketchpad recipe).
///
/// ⛔ **THERE IS NO CANCEL BUTTON, ON PURPOSE.** `convertClipsToVoice` has no
/// abort — the generation-progress-card law is explicit that this card offers no
/// affordance the engine cannot honor, and a Cancel that silently did nothing
/// would be worse than none. The close ✕ and the scrim are inert while a run is
/// in flight for the same reason: dismissing the panel would not stop the work.
///
/// **Result.** The new track's name, the count that landed, leg A's non-fatal
/// `warnings` as an amber notice list (**a warning is not a failure** — the
/// conversion happened and something is worth knowing), and, for the reserved
/// "base" target, the `realConversion:false` truth with the facade's note
/// verbatim.
///
/// **Refusals surface VERBATIM.** A `ProjectError` from leg A is written for a
/// human already and is the same string an agent gets from `vc.convertClips`;
/// the strip prints it word for word (the refusal-bubble one-vocabulary law).
struct VoiceConvertClipsSheet: View {
    @Bindable var model: VoicePanelModel
    /// The clips this run will convert, in list order (resolved by ContentView
    /// from the live store — plain value inputs, so a preview can drive it).
    var targets: [VoiceConvertTarget]
    var onClose: () -> Void

    /// ⚠️ The picked voice and the pitch live on the MODEL, not in `@State` —
    /// see `VoicePanelModel.selectedConvertVoiceID` for why (the armed primary
    /// button has to be photographable). These are thin aliases so the body
    /// reads the same as it would with local state.
    private var selectedVoiceID: String? { model.selectedConvertVoiceID }
    private var pitchSemitones: Int { model.convertPitchSemitones }

    /// The facade's own pitch bounds (`[-24, 24]` — see `VoiceConvertRequest`).
    private static let pitchRange = -24...24

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()
                // Inert while converting: dismissing would not stop the work,
                // and a modal that vanishes mid-run hides the only progress the
                // user has.
                .onTapGesture { if !model.isConvertingClips { onClose() } }
            // The card's scrolling body is bounded by the WINDOW (m23-m3c), so
            // its room is read from the geometry rather than guessed — three of
            // its regions can outgrow any card.
            GeometryReader { geo in
                card(bodyRoom: VoiceConvertSheetLayout.bodyRoom(availableHeight: geo.size.height))
                    .frame(width: VoiceConvertSheetLayout.cardWidth)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .transition(.opacity)
        .task {
            model.resetClipsConvertState()
            await model.refreshSidecar()
            if model.sidecarStatus?.state == .healthy {
                await model.refreshVoices()
            }
            // Pre-pick the only sensible default when exactly one voice exists.
            if selectedVoiceID == nil, model.voices.count == 1 {
                model.selectedConvertVoiceID = model.voices.first?.id
            }
        }
    }

    private func card(bodyRoom: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().overlay(DAWTheme.hairline)
            // ONE scroll region, inflexible at min(content, room) — the mixer
            // strip's mechanism verbatim, `fixedSize` load-bearing.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) { bodySections }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: bodyRoom)
            .fixedSize(horizontal: false, vertical: true)
            // PINNED below the scroller, and each for its own reason: progress
            // you have to scroll to find is not progress, a refusal you have to
            // scroll to find will not be read, and a modal whose primary action
            // is off-screen is worse than one that scrolls (m23-m3c).
            if let progress = model.clipsConvertProgress {
                progressBlock(progress)
            }
            // ⚠️ `!error.isEmpty` is load-bearing, not tidiness: a strip with a
            // warning triangle and no words claims something went wrong and
            // then refuses to say what. MEASURED on staging — an empty message
            // drew exactly that.
            if model.lastClipsConversion == nil,
               let error = model.clipsConvertError, !error.isEmpty {
                errorStrip(error)
            }
            footer
        }
        .padding(16)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DAWTheme.ai.opacity(0.22), lineWidth: 1)   // the AI surface's violet edge
        )
        .explainable(.voiceConvert)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(DAWTheme.ai)
                .frame(width: 7, height: 7)
                .glow(DAWTheme.ai, radius: 5, intensity: 0.8)
            Text("CONVERT VOICE")
                .font(.system(size: 11, weight: .heavy))
                .tracking(2)
                .foregroundStyle(DAWTheme.textPrimary)
                .fixedSize()
            // The blast radius, on the card itself — the same count the menu
            // item named, so the two can never disagree.
            Text(targets.count == 1 ? "1 clip" : "\(targets.count) clips")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize()
            Spacer(minLength: 4)
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .disabled(model.isConvertingClips)
            .help(model.isConvertingClips
                  ? "The conversion is still running — closing would not stop it"
                  : "Close without converting")
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var bodySections: some View {
        if let outcome = model.lastClipsConversion {
            resultView(outcome)
        } else {
            if let banner = model.banner { bannerStrip(banner) }
            voiceSection
            clipsSection
            pitchRow
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("VOICE")
            if model.voices.isEmpty {
                Text(model.sidecarStatus?.state == .healthy
                     ? "No voices available yet — build one in the Voice panel, then train it."
                     : "Start the voice engine to load the voice list.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Capped inside the body so a facade serving twenty voices
                // cannot push the clip list out of the room (m26-i: the
                // yielding region is a decision, not a leftover).
                ScrollView(.vertical) {
                    VStack(spacing: 5) {
                        ForEach(model.voices, id: \.id) { descriptor in
                            VoiceChoiceRow(
                                descriptor: descriptor,
                                isSelected: selectedVoiceID == descriptor.id,
                                isEnabled: !model.isConvertingClips,
                                onSelect: { model.selectedConvertVoiceID = descriptor.id })
                        }
                    }
                }
                .frame(maxHeight: VoiceConvertSheetLayout.voiceListMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The exact set that will convert — named, with its track and beat span.
    private var clipsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                fieldLabel("CLIPS TO CONVERT")
                Spacer()
                Text("\(targets.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DAWTheme.playback)
                    .fixedSize()
            }
            ScrollView(.vertical) {
                VStack(spacing: 4) {
                    ForEach(targets) { target in clipRow(target) }
                }
            }
            .frame(maxHeight: VoiceConvertSheetLayout.clipListMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            Text("Each clip converts on its own and lands on one new track at the same spot. "
                 + "Your originals are not touched.")
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func clipRow(_ target: VoiceConvertTarget) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.signal)
            Text(target.name.isEmpty ? "Audio Clip" : target.name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DAWTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(target.trackName)
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            // Beats are a numeric readout → cyan SF Mono, never violet.
            Text(target.beatSpanText)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(DAWTheme.playback)
                .fixedSize()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    /// Pitch shift in semitones — a numeric readout, so SF Mono cyan.
    private var pitchRow: some View {
        HStack(spacing: 10) {
            fieldLabel("PITCH")
            Text("optional — shifts the voice up or down")
                .font(.system(size: 8.5))
                .foregroundStyle(DAWTheme.textDim)
            Spacer(minLength: 4)
            stepButton("minus") {
                model.convertPitchSemitones =
                    max(Self.pitchRange.lowerBound, pitchSemitones - 1)
            }
            Text(pitchSemitones > 0 ? "+\(pitchSemitones) st" : "\(pitchSemitones) st")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.playback)
                .glow(DAWTheme.playback, radius: 4, intensity: 0.5)
                .frame(width: 52)
                .fixedSize()
            stepButton("plus") {
                model.convertPitchSemitones =
                    min(Self.pitchRange.upperBound, pitchSemitones + 1)
            }
        }
        .disabled(model.isConvertingClips)
    }

    private func stepButton(_ systemName: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DAWTheme.textPrimary)
                .frame(width: 22, height: 20)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Progress (never a bare spinner)

    private func progressBlock(_ progress: VoiceClipsConvertProgress) -> some View {
        // 1 Hz, UNPAUSED `.periodic` (the m22-e poll-discipline law — never
        // `.animation`, which stops when the window is not frontmost, and a
        // frozen elapsed count on a minutes-long job is precisely the dishonest
        // readout this project keeps closing).
        TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(progress.stepText)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(DAWTheme.playback)
                        .fixedSize()
                    Text("\(Int((progress.fraction * 100).rounded()))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DAWTheme.ai)
                        .fixedSize()
                    Spacer(minLength: 4)
                    Text("\(progress.elapsedSeconds(at: context.date))s")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DAWTheme.playback)
                        .fixedSize()
                }
                Text(progress.detailText)
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                progressBar(progress.fraction)
            }
            .padding(10)
            .background(DAWTheme.ai.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DAWTheme.ai.opacity(0.3), lineWidth: 1))
        }
    }

    /// The bar shows COMPLETED work only — a minimum sliver so a first clip in
    /// flight still reads as started, never an interpolated estimate.
    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DAWTheme.background)
                Capsule()
                    .fill(DAWTheme.ai)
                    .glow(DAWTheme.ai, radius: 4, intensity: 0.5)
                    .frame(width: max(4, geo.size.width * CGFloat(fraction)))
                // The house "working" cue — a slow violet sweep, never a spinner.
                SketchpadShimmer(tint: DAWTheme.ai)
                    .clipShape(Capsule())
            }
        }
        .frame(height: 5)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if model.lastClipsConversion != nil {
            Button { onClose() } label: {
                Text("DONE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(DAWTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(DAWTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                Text(VoicePanelModel.policyLine)   // the standing policy, here too
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                convertButton
            }
        }
    }

    private var canConvert: Bool {
        selectedVoiceID != nil
            && !targets.isEmpty
            && model.sidecarStatus?.state == .healthy
            && !model.isConvertingClips
    }

    private var convertButton: some View {
        Button {
            guard let voiceID = selectedVoiceID else { return }
            Task {
                // Success keeps the panel open on the honest result state; the
                // violet track already landed.
                _ = await model.convertClips(
                    clipIDs: targets.map(\.id), voiceID: voiceID,
                    pitchSemitones: pitchSemitones)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "person.wave.2.fill")
                Text(model.isConvertingClips ? "CONVERTING…" : convertTitle)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(1.5)
            }
            .foregroundStyle(canConvert ? Color.black : DAWTheme.textDim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(canConvert ? DAWTheme.ai : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .glow(canConvert ? DAWTheme.ai : .clear, radius: 8, intensity: 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!canConvert)
        .help("Re-sing these clips in the picked voice — one new track lands at the same spots")
    }

    /// The button names the blast radius too (the m23-cf rule): "CONVERT CLIP"
    /// for one, "CONVERT 3 CLIPS" for many.
    private var convertTitle: String {
        targets.count == 1 ? "CONVERT CLIP" : "CONVERT \(targets.count) CLIPS"
    }

    // MARK: - Result (the honest landing state)

    private func resultView(_ outcome: VoiceClipsConvertOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DAWTheme.ai)
                    .glow(DAWTheme.ai, radius: 5, intensity: 0.6)
                Text("Converted → \u{201C}\(outcome.result.trackName)\u{201D}")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 10) {
                readout("\(outcome.result.clips.count)", "CLIPS")
                readout(String(format: "%.1fs", outcome.totalInferSeconds), "ENGINE")
                Spacer(minLength: 0)
            }
            Text("The new track carries every clip at its own spot — one undo removes it.")
                .font(.system(size: 9.5))
                .foregroundStyle(DAWTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // NON-FATAL. A warning means the conversion HAPPENED and something
            // is worth knowing — amber notice, never a red failure and never an
            // alert that would make a successful run look broken.
            if !outcome.result.warnings.isEmpty { warningsBlock(outcome.result.warnings) }

            if !outcome.realConversion {
                notRealStrip(note: outcome.note)
            }
        }
    }

    private func warningsBlock(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.record)
                Text(warnings.count == 1 ? "WORTH KNOWING" : "WORTH KNOWING (\(warnings.count))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(DAWTheme.record)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning)   // leg A's own words, verbatim
                            .font(.system(size: 9.5))
                            .foregroundStyle(DAWTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: VoiceConvertSheetLayout.clipListMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(DAWTheme.record.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.record.opacity(0.35), lineWidth: 1))
    }

    /// The base smoke target's truth, never hidden.
    private func notRealStrip(note: String?) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.record)
            VStack(alignment: .leading, spacing: 3) {
                Text("Not a real voice conversion")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                if let note {
                    Text(note)   // the facade's own note, verbatim
                        .font(.system(size: 9))
                        .foregroundStyle(DAWTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.record.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.record.opacity(0.35), lineWidth: 1))
    }

    // MARK: - Shared bits

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
        .fixedSize()
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(DAWTheme.textDim)
            .fixedSize()
    }

    private func bannerStrip(_ banner: VoicePanelBanner) -> some View {
        let tint: Color = switch banner.tone {
        case .neutral: DAWTheme.textDim
        case .warning: DAWTheme.record
        case .error: DAWTheme.clip
        case .progress: DAWTheme.playback
        }
        return HStack(spacing: 8) {
            if banner.tone == .progress {
                ProgressView().controlSize(.small).tint(tint)
            } else {
                Image(systemName: banner.tone == .error
                      ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
            }
            Text(banner.message)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if banner.canStart, !model.isStartingSidecar {
                Button {
                    Task {
                        await model.startSidecar()
                        if selectedVoiceID == nil, model.voices.count == 1 {
                            model.selectedConvertVoiceID = model.voices.first?.id
                        }
                    }
                } label: {
                    Text("START")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(DAWTheme.record)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(DAWTheme.record.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else if banner.tone == .progress || model.isStartingSidecar {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini).tint(tint)
                    Text("STARTING…")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(tint)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(tint.opacity(0.5), lineWidth: 1))
            }
        }
        .padding(10)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.3), lineWidth: 1))
    }

    /// A refusal, in the store's own words (the refusal-bubble law).
    private func errorStrip(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.clip)
            Text(message)
                .font(.system(size: 9.5))
                .foregroundStyle(DAWTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.clip.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.clip.opacity(0.35), lineWidth: 1))
    }
}
