import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

/// The Export dialog (m23-m3, m23-m3c) — the face for `render.bounce`'s output
/// format, its instrumental switch and its loudness normalization, and for
/// `render.stems`' mixdown siblings, none of which had any surface before this.
/// The transport EXPORT chip used to run a bare `NSSavePanel` hardcoded to
/// `.wav`; it now opens this card, and the destination panel appears only after
/// the settings are chosen (which is also why it can offer the right file type —
/// or, in stems mode, a folder).
///
/// **ONE dialog with a "what to export" selector** (the Logic/Ableton idiom),
/// not two dialogs: the quality section is genuinely shared — `renderStems`
/// resolves depth and container through the same `DeliveryFormat` — so a second
/// card would mean a second copy of it. What is NOT shared is the track list.
/// The bounce EXCLUDES tracks; the stems call INCLUDES them, so one checkbox
/// column would mean opposite things in the two modes. **Stems mode therefore
/// hides the list entirely and shows the exact files that will be written**,
/// which teaches the eligibility rule (a bus IS a stem; a bus-routed track is
/// not) far better than a control whose meaning flips.
///
/// **The NAMED in-window pattern** — a centered dark-glass card over a dimmed
/// scrim (Settings / Instrument Picker / Quantize / Undo History / Effect
/// Editor / VoiceConvertSheet), never a popover or a child window, so
/// `debug.captureUI` snapshots the same instance a user sees. Its state lives
/// on `AppModel.exportDialog`, not in this view's `@State`, for the same
/// reason.
///
/// **NO VIOLET anywhere** (Rule 3): exporting your own mix is standard studio
/// chrome, not AI-touched content. Cyan marks only earned selection and the
/// numeric readouts; the card and its chrome stay neutral.
///
/// **NO LOUDNESS NUMBERS anywhere, before or after the render** — deliberate,
/// and the reason is a live open issue rather than taste: `BounceResult`'s
/// measurements describe the buffer BEFORE integer quantization (m23-m2, filed
/// in ARCHITECTURE.md), so beside a 16-bit choice a peak or a loudness figure
/// would name something the file on disk does not have. The result strip shows
/// the path, the length and the format, which are true of the delivered file.
///
/// **Density: COINCIDENT, so no SIMPLE/PRO chip** (docs/research/
/// simple-pro-inventory.md) — every control here is one a beginner exporting
/// their first song needs, and there is nothing a Pro would additionally want
/// that the dialog withholds. A toggle that changes nothing is worse than none.
struct ExportSheet: View {
    @Bindable var model: ExportDialogModel
    /// The project's name — the save panel's default file name comes from it
    /// (through the model, so the extension is the format's).
    var projectName: String
    /// Opens the save panel and runs the bounce. Wired to
    /// `AppModel.runExportFromDialog`, which calls the SAME
    /// `ExportDialogModel.export` the debug seam and the tests call.
    var onExport: () -> Void
    var onClose: () -> Void

    /// Bounded so a 40-track session cannot grow the card past the window; a
    /// short list still hugs (the Quantize groove-list idiom).
    private static let trackListMaxHeight: CGFloat = 132

    /// Same bound for the stems preview, and for the same reason — a 40-input
    /// session lists 40 files.
    private static let previewMaxHeight: CGFloat = 132

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture { if !model.isExporting { onClose() } }
            // The card's scrolling body is bounded by the WINDOW, so its room
            // is read from the geometry rather than guessed — see
            // `ExportSheetLayout` for why a fixed-height card was unusable at
            // the 640 pt window floor once stems mode arrived.
            GeometryReader { geo in
                card(bodyRoom: ExportSheetLayout.bodyRoom(availableHeight: geo.size.height))
                    .frame(width: 460)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .transition(.opacity)
    }

    private func card(bodyRoom: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(DAWTheme.hairline)
            // ONE scroll region, inflexible at min(content, room): at a
            // comfortable window it hugs and the card is pixel-identical to the
            // pre-m23-m3c one; at the floor it scrolls instead of pushing the
            // title and the EXPORT button off the window (the m23-a mechanism,
            // `fixedSize` load-bearing).
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) { sections }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: bodyRoom)
            .fixedSize(horizontal: false, vertical: true)
            // The error and the button stay OUT of the scroller: a reason the
            // export failed that a user has to scroll to find is a reason they
            // will not read, and a primary action must never be off-screen.
            if model.lastExport == nil && model.lastStemExport == nil {
                if let error = model.lastError { errorStrip(error) }
                footer
            }
        }
        .padding(16)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
        .explainable(.exportDialog)
    }

    /// Everything between the pinned header and the pinned footer.
    @ViewBuilder
    private var sections: some View {
        if let outcome = model.lastExport {
            resultView(outcome)
        } else if let outcome = model.lastStemExport {
            stemResultView(outcome)
        } else {
            modeSection
            Divider().overlay(DAWTheme.hairline)
            formatSection
            Divider().overlay(DAWTheme.hairline)
            // The two modes take different arguments, so they show different
            // controls — never the same control relabelled.
            switch model.mode {
            case .bounce:
                tracksSection
                Divider().overlay(DAWTheme.hairline)
                normalizeSection
            case .stems:
                stemsSection
                Divider().overlay(DAWTheme.hairline)
                previewSection
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.textDim)
            // The title follows the MODE (`ExportMode.title`, spelled once in
            // the model): a card headed "EXPORT SONG" while it writes a folder
            // of stems is a readout that disagrees with what it does.
            Text(model.mode.title)
                .font(.system(size: 12, weight: .heavy))
                .tracking(2)
                .foregroundStyle(DAWTheme.textPrimary)
                .fixedSize()
            Text(projectName)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .disabled(model.isExporting)
            .help("Close without exporting")
        }
    }

    // MARK: - What to export (m23-m3c)

    /// The mode selector: the house chip-pair idiom (active half cyan-lit, the
    /// SimpleProToggle / WAV|AIFF shape) plus the mode's own teaching line.
    /// Labels and copy come from `ExportMode` — this view spells neither.
    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("WHAT TO EXPORT")
                Spacer()
                modeChips
            }
            Text(model.mode.detail)
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeChips: some View {
        HStack(spacing: 0) {
            ForEach(ExportMode.allCases) { mode in
                let active = model.mode == mode
                Button { model.mode = mode } label: {
                    Text(mode.label)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(active ? DAWTheme.playback : DAWTheme.textDim)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(active ? DAWTheme.playback.opacity(0.18) : Color.clear)
                }
                .buttonStyle(.plain)
                .help(mode.detail)
            }
        }
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        .disabled(model.isExporting)
    }

    // MARK: - Format (depth + container)

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("QUALITY")
                Spacer()
                containerChips
            }
            VStack(spacing: 4) {
                // Enumerated from DeliveryFormat's OWN list, so the picker can
                // never offer a depth the render would reject.
                ForEach(Array(DeliveryFormat.selectableBitDepths.enumerated()), id: \.offset) { _, depth in
                    depthRow(depth)
                }
            }
        }
    }

    /// WAV | AIFF — the house chip-pair idiom (the active half cyan-lit, the
    /// SimpleProToggle / VOL-PAN shape). Labels come from `DeliveryContainer`,
    /// never spelled here.
    private var containerChips: some View {
        HStack(spacing: 0) {
            ForEach(DeliveryContainer.allCases, id: \.self) { container in
                let active = model.format.container == container
                Button { model.setContainer(container) } label: {
                    Text(container.label)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(active ? DAWTheme.playback : DAWTheme.textDim)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(active ? DAWTheme.playback.opacity(0.18) : Color.clear)
                }
                .buttonStyle(.plain)
                .help(container.detail)
            }
        }
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        .disabled(model.isExporting)
    }

    /// One depth choice — the Quantize groove-row shape (radio dot + name +
    /// dim gloss), cyan for the picked one. Labels and glosses come from
    /// `DeliveryFormat`; this view spells no depth of its own.
    private func depthRow(_ depth: Int?) -> some View {
        let selected = model.format.bitDepth == depth
        return Button { model.setBitDepth(depth) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? DAWTheme.playback : DAWTheme.textFaint)
                Text(DeliveryFormat.depthLabel(depth))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(selected ? DAWTheme.playback : DAWTheme.textPrimary)
                    .fixedSize()
                Text(DeliveryFormat.depthDetail(depth))
                    .font(.system(size: 9.5))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? DAWTheme.playback.opacity(0.1) : DAWTheme.panelRaised.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isExporting)
    }

    // MARK: - Leave tracks out (the instrumental)

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("LEAVE TRACKS OUT")
                Spacer()
                if !model.excludedTrackIDs.isEmpty {
                    Button { model.clearExclusions() } label: {
                        Text("INCLUDE ALL")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(DAWTheme.textDim)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help("Put every track back into the export")
                }
            }
            if model.tracks.isEmpty {
                Text("This project has no tracks yet.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(model.tracks) { track in
                            trackRow(track)
                        }
                    }
                }
                .frame(maxHeight: Self.trackListMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
            // The m23-m1 teaching text, in the place the choice is made: what
            // leaves with a silenced track is the thing people file bugs about.
            Text(model.excludedTrackIDs.isEmpty
                 ? "Silence a track to export an instrumental. Your project is not changed."
                 : "Left out: \(model.excludedNames.joined(separator: ", ")) — reverb and delay tails go with them, so the mix is genuinely clean. Your project is not changed.")
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trackRow(_ track: ExportTrackChoice) -> some View {
        let excluded = model.isExcluded(track.id)
        return Button { model.toggleExcluded(track.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: excluded ? "speaker.slash.fill" : "checkmark.square.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(excluded ? DAWTheme.textFaint : DAWTheme.playback)
                    .frame(width: 14)
                Text(track.name)
                    .font(.system(size: 11))
                    .foregroundStyle(excluded ? DAWTheme.textFaint : DAWTheme.textPrimary)
                    .strikethrough(excluded, color: DAWTheme.textFaint)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(track.kind.rawValue.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(DAWTheme.textFaint)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DAWTheme.panelRaised.opacity(excluded ? 0.25 : 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isExporting)
        .help(excluded ? "Put \"\(track.name)\" back into the export"
                       : "Leave \"\(track.name)\" out of this export")
    }

    // MARK: - Normalization

    private var normalizeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.normalize.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.normalize ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle(model.normalize ? DAWTheme.playback : DAWTheme.textDim)
                    Text("Match a loudness target")
                        .font(.system(size: 11))
                        .foregroundStyle(DAWTheme.textPrimary)
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isExporting)
            .help("Raise or lower the whole mix so it lands at a chosen loudness")

            // The ceiling is read ONLY when a target is set (it is inside
            // `if let lufsTarget` in the store's normalization policy), so it
            // appears only with the toggle on — a control that changes no
            // samples must not look live.
            if model.normalize {
                stepperRow(
                    label: "TARGET",
                    value: String(format: "%.1f LUFS", model.lufsTarget),
                    hint: "streaming services land near −14",
                    help: "The loudness the whole mix is moved to",
                    onDown: { model.lufsTarget -= 0.5 },
                    onUp: { model.lufsTarget += 0.5 })
                stepperRow(
                    label: "PEAK LIMIT",
                    value: String(format: "%.1f dBTP", model.truePeakCeilingDb),
                    hint: "the mix is never pushed past this",
                    help: "The loudest peak allowed — the move is held back to respect it",
                    onDown: { model.truePeakCeilingDb -= 0.5 },
                    onUp: { model.truePeakCeilingDb += 0.5 })
            }
        }
    }

    /// A label + SF Mono glowing readout + −/+ pair. The readout is pinned
    /// (`fixedSize`) and so is every label beside it: a control label never
    /// truncates and a number never shrinks (the m22-g law).
    private func stepperRow(label: String, value: String, hint: String, help: String,
                            onDown: @escaping () -> Void,
                            onUp: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize()
            Text(hint)
                .font(.system(size: 8.5))
                .foregroundStyle(DAWTheme.textFaint)
                .lineLimit(1)
            Spacer(minLength: 4)
            stepButton("minus", action: onDown)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.playback)
                .glow(DAWTheme.playback, radius: 4, intensity: 0.5)
                .fixedSize()
                .frame(width: 84, alignment: .trailing)
            stepButton("plus", action: onUp)
        }
        .disabled(model.isExporting)
        .help(help)
    }

    private func stepButton(_ systemName: String, action: @escaping () -> Void) -> some View {
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

    // MARK: - Stems (m23-m3c)

    /// The two mixdown SIBLINGS — the only stems parameters with a control here.
    /// There is no track list: see the type doc (the inclusion/exclusion flip),
    /// and the preview below carries what a list would have taught.
    private var stemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("ALSO WRITE")
            checkRow(
                title: "A reference mix",
                isOn: model.includeMixdown,
                help: "Writes one extra file: every stem summed, with no master effects") {
                    model.includeMixdown.toggle()
                }
            checkRow(
                title: "The finished master",
                isOn: model.includeMasteredMixdown,
                help: "Writes the same file the SONG export makes, beside the stems") {
                    model.includeMasteredMixdown.toggle()
                }
            // Nested exactly like the bounce's normalization steppers, and for
            // the same reason: this target is read ONLY while the mastered file
            // is being written, so it must not look live when it is not.
            if model.includeMasteredMixdown {
                checkRow(
                    title: "Match a loudness target",
                    isOn: model.masteredNormalize,
                    indented: true,
                    help: "Raise or lower the finished master so it lands at a chosen loudness") {
                        model.masteredNormalize.toggle()
                    }
                if model.masteredNormalize {
                    stepperRow(
                        label: "TARGET",
                        value: String(format: "%.1f LUFS", model.masteredLufsTarget),
                        hint: "streaming services land near −14",
                        help: "The loudness the finished master is moved to",
                        onDown: { model.masteredLufsTarget -= 0.5 },
                        onUp: { model.masteredLufsTarget += 0.5 })
                    stepperRow(
                        label: "PEAK LIMIT",
                        value: String(format: "%.1f dBTP", model.masteredTruePeakCeilingDb),
                        hint: "the mix is never pushed past this",
                        help: "The loudest peak allowed — the move is held back to respect it",
                        onDown: { model.masteredTruePeakCeilingDb -= 0.5 },
                        onUp: { model.masteredTruePeakCeilingDb += 0.5 })
                }
            }
            // What the two extra files are FOR, in the place they are chosen.
            // The stems themselves never carry master effects (S-3′), which is
            // the fact people file bugs about — so it is said here, not only in
            // the result strip.
            Text("The stems are your mix taken apart, without master effects. A reference mix proves they add back up; the finished master is what a listener hears.")
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A checkbox row in the normalization toggle's shape — one square glyph,
    /// one plain-language title, the whole row clickable.
    private func checkRow(title: String, isOn: Bool, indented: Bool = false,
                          help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? DAWTheme.playback : DAWTheme.textDim)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.leading, indented ? 20 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isExporting)
        .help(help)
    }

    /// The read-only preview: **the exact file names `renderStems` will write**,
    /// from `ExportDialogModel.plannedStemFiles` → `StemPlan.fileSet` — the same
    /// code that names the files on disk, never a second numbering.
    ///
    /// It is also this dialog's teaching surface for the eligibility rule: a
    /// user who routed a track into a bus does not find it here, and the line
    /// underneath says why. That is what stems mode shows INSTEAD of a track
    /// list, not in addition to one.
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("FILES")
                Spacer()
                Text("\(model.plannedStemFiles.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DAWTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            if model.plannedStemFiles.isEmpty {
                Text("Nothing reaches the main mix yet, so there are no stems to write.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.plannedStemFiles, id: \.self) { name in
                            HStack(spacing: 7) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 9))
                                    .foregroundStyle(DAWTheme.textFaint)
                                    .frame(width: 12)
                                Text(name)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(DAWTheme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DAWTheme.panelRaised.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
                .frame(maxHeight: Self.previewMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("A bus gets its own file. A track routed into a bus does not — its sound is already part of that bus's file.")
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            // Bounce: the exact name + format the save panel will open on, read
            // off the model's `DeliveryFormat`, never assembled here. Stems: the
            // count, because the names are listed above and the destination is a
            // folder the user has not chosen yet.
            Text(model.mode == .bounce
                 ? model.suggestedFileName(projectName: projectName)
                 : "\(model.plannedStemFiles.count) files")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Button(action: onExport) {
                HStack(spacing: 7) {
                    if model.isExporting {
                        ProgressView().controlSize(.small).tint(DAWTheme.background)
                        Text("EXPORTING…")
                            .font(.system(size: 12, weight: .heavy))
                            .tracking(1.2)
                            .fixedSize()
                    } else {
                        Text(model.mode == .bounce
                             ? "CHOOSE FILE & EXPORT"
                             : "CHOOSE FOLDER & EXPORT")
                            .font(.system(size: 12, weight: .heavy))
                            .tracking(1.2)
                            .fixedSize()
                    }
                }
                .foregroundStyle(DAWTheme.background)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(DAWTheme.playback)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .glow(DAWTheme.playback, radius: 6, intensity: 0.4)
            }
            .buttonStyle(.plain)
            // Stems with an empty plan would throw `nothingToRender` after the
            // folder chooser — the worst moment to find out, and the preview
            // above has already said why there is nothing to write.
            .disabled(model.isExporting
                      || (model.mode == .stems && model.plannedStemFiles.isEmpty))
            .help(model.mode == .bounce
                  ? "Pick where to save, then write the file"
                  : "Pick a folder, then write the files listed above")
        }
    }

    // MARK: - Result

    private func resultView(_ outcome: ExportDialogModel.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DAWTheme.signal)
                    .glow(DAWTheme.signal, radius: 5, intensity: 0.5)
                Text("Exported")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .fixedSize()
                Spacer(minLength: 4)
                Text(outcome.formatLabel)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize()
            }
            Text(outcome.path)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(DAWTheme.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Text(Self.lengthLabel(outcome.durationSeconds))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DAWTheme.playback)
                    .fixedSize()
                if !outcome.excludedTracks.isEmpty {
                    Text("without \(outcome.excludedTracks.joined(separator: ", "))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(DAWTheme.textDim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if outcome.limitedByCeiling {
                // A fact about the RENDER (the gain was held back), not a
                // measurement of the file — so it survives the quantization
                // hazard that keeps every loudness number off this card.
                noticeStrip("The mix was not raised all the way to your target — the peak limit held it back.")
            }
            HStack(spacing: 8) {
                Button { revealInFinder(outcome.path) } label: {
                    Text("SHOW IN FINDER")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(DAWTheme.textPrimary)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(DAWTheme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button(action: onClose) {
                    Text("DONE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(DAWTheme.background)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(DAWTheme.playback)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The stems run's result strip (m23-m3c). Same shape and same honesty rule
    /// as the bounce's — a path, a length, a format, and facts about the RENDER
    /// — but it names the FILES THAT LANDED (read off `StemExportResult`'s own
    /// paths), not the plan the card showed before the run.
    private func stemResultView(_ outcome: ExportDialogModel.StemOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DAWTheme.signal)
                    .glow(DAWTheme.signal, radius: 5, intensity: 0.5)
                Text(outcome.fileNames.count == 1
                     ? "Exported 1 file"
                     : "Exported \(outcome.fileNames.count) files")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .fixedSize()
                Spacer(minLength: 4)
                Text(outcome.formatLabel)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize()
            }
            Text(outcome.directory)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(DAWTheme.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(outcome.fileNames, id: \.self) { name in
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(DAWTheme.textDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: Self.previewMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            Text(Self.lengthLabel(outcome.durationSeconds))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.playback)
                .fixedSize()
            if outcome.masterChainExcluded {
                // The m13-d honesty field, said in words: stems are pre-master
                // material on purpose, and a person who does not know that will
                // think the export lost their master effects.
                noticeStrip("Your master effects are not on the stems — that is what makes them re-mixable. The finished master carries them.")
            }
            if outcome.limitedByCeiling {
                noticeStrip("The finished master was not raised all the way to your target — the peak limit held it back.")
            }
            HStack(spacing: 8) {
                Button { revealInFinder(outcome.directory) } label: {
                    Text("SHOW IN FINDER")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(DAWTheme.textPrimary)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(DAWTheme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button(action: onClose) {
                    Text("DONE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(DAWTheme.background)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(DAWTheme.playback)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// m:ss — the file's real length, one of the few numbers that survives
    /// integer conversion untouched.
    static func lengthLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Shared bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(DAWTheme.textDim)
            .fixedSize()
    }

    private func noticeStrip(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.record)
            Text(message)
                .font(.system(size: 9.5))
                .foregroundStyle(DAWTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(DAWTheme.record.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.record.opacity(0.35), lineWidth: 1))
    }

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
        .background(DAWTheme.clip.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.clip.opacity(0.35), lineWidth: 1))
    }
}
