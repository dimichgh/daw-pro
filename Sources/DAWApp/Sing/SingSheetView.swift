import SwiftUI
import AppKit
import AIServices
import DAWCore
import DAWAppKit

/// The Sing sheet (p2-sing-f, design §5.2): Words, Voice, Height, [Sing it]; p2-sing-x8 adds the language picker,
/// the note field and the playback glow on the strip, the wordless buttons, "Write words for me", the Expression
/// card and the Harmony card (design 2026-10-06 §3.1, §4.1, §5.1, §6.1, §8.1-§8.3). Thin over `SingSheetModel`;
/// every press is a model method that makes the call the wire makes (see `SingSeams.swift`).
///
/// Height budget (docs/DESIGN-LANGUAGE.md, "WHICH region yields"): the ONE yielding region is still the notices
/// list under the words (warnings + refusals); every other region is fixed, and its height is computed from the
/// sheet's state (`SingCardLayout.sheetChrome`), never a constant ceiling.
struct SingSheetView: View {
    var model: SingSheetModel
    var windowHeight: Double
    var onClose: () -> Void

    var body: some View {
        SingModalCard(width: 560, onScrimTap: onClose) {
            VStack(alignment: .leading, spacing: 12) {
                SingCardHeader(systemImage: "music.mic", title: SingCopy.sheetTitle, subtitle: model.clipName,
                               tint: DAWTheme.ai, closeHelp: "Close without singing", onClose: onClose)
                Divider().overlay(DAWTheme.hairline)
                words
                voice
                height
                SingExpressionCardView(model: model.expression)
                SingHarmonyCardView(model: model)
                if let refusal = model.refusal { PanelRefusalLine(message: refusal) }
                singItRow
            }
        }
    }

    // MARK: Words

    private var words: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SingSectionLabel(text: SingCopy.wordsSection)
                Spacer(minLength: 4)
                if model.canWriteWords, !model.writeWords.isOpen {
                    SingButton(title: SingCopy.writeWordsForMe, systemImage: "sparkles", role: .ai) {
                        model.openWriteWords()
                    }
                }
                languagePicker
            }
            if model.writeWords.isOpen { writeWordsPanel }
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { model.text }, set: { model.setText($0) }))
                    .font(.system(size: 12))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                if model.text.isEmpty {
                    Text(SingCopy.wordsPlaceholder)
                        .font(.system(size: 12))
                        .foregroundStyle(DAWTheme.textFaint)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 64)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
            if model.wordlessOffered { wordlessRow }
            SingStripHost(model: model)
            notices
        }
    }

    /// "Language: English ▾" (§6.1): English and the two Chinese languages, from `LyricLanguage` (Spanish is out).
    private var languagePicker: some View {
        Menu {
            ForEach(SingCopy.languageCodes, id: \.self) { code in
                Button(SingCopy.languageName(code)) { model.setLanguage(code) }
            }
        } label: {
            HStack(spacing: 5) {
                Text("\(SingCopy.languageLabel): \(model.languageTitle)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DAWTheme.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// "No words? Sing: Ooh · Aah · Mm", with "One sound per line" / "One per note" (§8.1). Neutral chrome: it
    /// writes words, it is not AI.
    private var wordlessRow: some View {
        HStack(spacing: 6) {
            Text(SingCopy.wordlessLead)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
            ForEach(WordlessLyrics.Sound.allCases, id: \.self) { sound in
                SingChip(title: SingCopy.wordlessSound(sound), isLit: false) { model.singWordless(sound) }
            }
            Spacer(minLength: 6)
            SingChip(title: SingCopy.wordlessPerLine, isLit: !model.wordlessPerNote) { model.setWordlessPerNote(false) }
            SingChip(title: SingCopy.wordlessPerNote, isLit: model.wordlessPerNote) { model.setWordlessPerNote(true) }
        }
    }

    /// "Write words for me" (§8.3): a theme, [Write], then the words land in the box above (nothing is stored).
    private var writeWordsPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TextField(SingCopy.writeWordsThemePlaceholder,
                          text: Binding(get: { model.writeWords.theme }, set: { model.setWriteWordsTheme($0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(DAWTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.ai.opacity(0.4), lineWidth: 1))
                    .onSubmit { Task { await model.writeWordsForMe() } }
                SingButton(title: SingCopy.writeWordsGo, systemImage: "sparkles", role: .ai,
                           isEnabled: model.writeWordsDisabledReason == nil,
                           help: model.writeWordsDisabledReason ?? SingCopy.writeWordsForMe) {
                    Task { await model.writeWordsForMe() }
                }
                Button { model.closeWriteWords() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DAWTheme.textDim)
                }
                .buttonStyle(.plain)
                .help(SingCopy.writeWordsClose)
            }
            if model.writeWords.isWriting {
                SingSentence(text: SingCopy.writingWords, color: DAWTheme.ai, size: 10)
            } else if let notice = model.writeWords.notice {
                PanelRefusalLine(message: notice)
            }
        }
    }

    /// THE yielding region: hugs its content, scrolls inside its room when it cannot.
    private var notices: some View {
        let room = SingCardLayout.noticesRoom(windowHeight: windowHeight,
                                              expressionOpen: model.expression.isExpanded,
                                              partCount: model.harmonyParts.count,
                                              writeWordsOpen: model.writeWords.isOpen)
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let reason = model.preview.refusal { PanelRefusalLine(message: reason) }
                ForEach(Array(model.preview.warnings.enumerated()), id: \.offset) { _, warning in
                    SingSentence(text: warning, color: DAWTheme.textSecondary, size: 10)
                }
                ForEach(model.unreadableVoices, id: \.self) { problem in
                    SingSentence(text: problem, color: DAWTheme.textDim, size: 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: room)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Voice

    private var voice: some View {
        VStack(alignment: .leading, spacing: 6) {
            SingSectionLabel(text: SingCopy.voiceSection)
            Menu {
                ForEach(model.voices) { choice in
                    Button(choice.name) { model.selectVoice(choice.id) }
                }
                Divider()
                Button(SingCopy.addYourVoice) { model.onAddVoice?() }
            } label: {
                HStack(spacing: 6) {
                    Text(model.selectedVoice.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DAWTheme.textPrimary)
                    Text(VoiceRangeFit.noteName(midi: model.selectedVoice.range.medianMidi))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DAWTheme.textDim)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DAWTheme.textDim)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: Height

    @ViewBuilder
    private var height: some View {
        if let line = model.height {
            VStack(alignment: .leading, spacing: 6) {
                SingSectionLabel(text: SingCopy.heightSection)
                SingSentence(text: line.sentence, color: DAWTheme.textPrimary)
                if let suggestion = line.suggestion {
                    SingSentence(text: suggestion, color: DAWTheme.textDim, size: 10)
                }
                if let review = model.transposeReview {
                    transposeReview(review)
                } else if line.moveTitle != nil || line.keepTitle != nil {
                    HStack(spacing: 8) {
                        if let move = line.moveTitle {
                            SingButton(title: move, systemImage: "arrow.up.arrow.down") { model.chooseMove() }
                        }
                        if let keep = line.keepTitle {
                            SingButton(title: keep) { model.chooseKeepKey() }
                        }
                    }
                }
            }
        }
    }

    private func transposeReview(_ review: SingTransposeReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SingSentence(text: review.sentence, color: DAWTheme.textSecondary)
            ForEach(Array((review.audioWarnings + review.otherWarnings).enumerated()), id: \.offset) { _, line in
                PanelRefusalLine(message: line)
            }
            HStack(spacing: 8) {
                SingButton(title: SingCopy.confirmMove, systemImage: "checkmark") { model.confirmMove() }
                SingButton(title: SingCopy.cancel) { model.cancelMove() }
            }
        }
        .padding(10)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    // MARK: Sing it

    private var singItRow: some View {
        HStack(spacing: 10) {
            Spacer()
            if let reason = model.singItDisabledReason, model.preview.refusal == nil {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .lineLimit(2)
            }
            SingButton(title: SingCopy.singIt, systemImage: "waveform", role: .ai, isEnabled: model.canSing,
                       help: model.singItDisabledReason ?? SingCopy.singIt) {
                Task { await model.singIt() }
            }
            // ⚠️ Deliberately NO `.keyboardShortcut(.defaultAction)`: the words box above is multi-line (a Return
            // starts a new lyric line), and a default button can take Return before the text view does, which
            // would start a sing job on a newline. [Sing it] is a click.
        }
    }
}

/// The strip, its note field and its [Play the tune], in a view of their own: the playback glow reads the
/// transport, which changes at the playhead's rate, so ONLY this view redraws while the song plays (the rest of
/// the sheet, the words box included, does not). The glow is a lookup (`playingChipID`), never a derivation.
/// vf-2: the strip itself is mounted `.equatable()`, so a tick that does not move the glow to another word costs one
/// comparison, never a layout or a width measurement.
struct SingStripHost: View {
    var model: SingSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SingWordStrip(preview: model.preview, playingChipID: model.playingChipID,
                          selectedNoteIDs: model.expression.selectedNoteIDs,
                          styledNoteIDs: model.expression.notesWithOwnSetting,
                          field: model.noteWord,
                          onTapNote: { model.tapNote($0) }, onTapChip: { model.tapChip($0) },
                          onDraft: { model.setNoteWordDraft($0) },
                          onCommit: { model.commitNoteWord(advance: $0) })
                .equatable()
                .frame(height: SingWordStripLayout.height)
            HStack(alignment: .top, spacing: 8) {
                // The legend's line carries the note field's hint or refusal while the field is open.
                Group {
                    if let field = model.noteWord {
                        if let refusal = field.refusal {
                            Text(refusal).foregroundStyle(DAWTheme.record)
                        } else {
                            Text(SingCopy.noteWordHint).foregroundStyle(DAWTheme.textSecondary)
                        }
                    } else {
                        Text(SingCopy.holdLegend).foregroundStyle(DAWTheme.textDim)
                    }
                }
                .font(.system(size: 10))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .topLeading)
                if model.isTransportPlaying {
                    SingButton(title: SingCopy.stopTune, systemImage: "stop.fill") { model.stopTune() }
                } else {
                    SingButton(title: SingCopy.playTune, systemImage: "play.fill",
                               isEnabled: !model.preview.notes.isEmpty) { model.playTune() }
                }
            }
        }
    }
}

/// The melody's notes as a strip, with a glowing violet word chip over each word (§5.2). p2-sing-x8: the word under
/// the playhead glows brighter (§8.2), a note with its own singing style shows a dot (§5.1), notes picked for the
/// Expression card are ringed in cyan, and "Word on this note" opens over the clicked note (§3.1). Drawn from the
/// model: the words a chip shows are the words that are sung.
///
/// vf-2 (design 2026-10-12 §5): the words are placed by THE piano roll's Words-lane layout, through
/// `SingWordStripLayout` (→ `PianoRollWordLane.layout`): two rows; a word with no room becomes a dot (hover it for the
/// word); never truncated, never overlapping; a held word draws a line with a tick on each held note. Rather than
/// squeeze a long tune into the sheet, the strip scrolls sideways, never below `minPixelsPerBeat`, and scrolls the
/// open field and the playing word into view. This view computes no geometry of its own: every position, size and
/// click target comes from the layout, where the tests reach it.
struct SingWordStrip: View, Equatable {
    var preview: SingSheetPreview
    var playingChipID: Int? = nil
    var selectedNoteIDs: Set<UUID> = []
    var styledNoteIDs: Set<UUID> = []
    var field: SingNoteWordField? = nil
    var onTapNote: (UUID) -> Void = { _ in }
    var onTapChip: (Int) -> Void = { _ in }
    var onDraft: (String) -> Void = { _ in }
    var onCommit: (_ advance: Bool) -> Void = { _ in }

    @FocusState private var fieldFocused: Bool

    /// By value. The callbacks are left out: the host always hands in the same model's methods, so they never make
    /// two strips draw differently, and a closure can never compare equal (the strip would redraw on every tick).
    nonisolated static func == (lhs: SingWordStrip, rhs: SingWordStrip) -> Bool {
        lhs.preview == rhs.preview && lhs.playingChipID == rhs.playingChipID
            && lhs.selectedNoteIDs == rhs.selectedNoteIDs && lhs.styledNoteIDs == rhs.styledNoteIDs
            && lhs.field == rhs.field
    }

    var body: some View {
        GeometryReader { geo in
            let layout = SingWordStripLayout(
                preview: preview, visibleWidth: geo.size.width,
                textWidths: SingWordStripWidths.table(for: SingWordStripLayout.texts(of: preview)))
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    content(layout)
                }
                // A field opened (or moved by Tab) past the edge, or the playing word leaving the view: the least
                // scroll that shows it (`anchor: nil`), so a word already in view never moves the strip.
                .onChange(of: field?.noteID) { _, noteID in
                    guard let noteID else { return }
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(SingStripAnchor(noteID: noteID)) }
                }
                .onChange(of: playingChipID) { _, chipID in
                    guard let chipID, let first = preview.chips.first(where: { $0.id == chipID })?.noteIDs.first
                    else { return }
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(SingStripAnchor(noteID: first)) }
                }
            }
        }
        .background(DAWTheme.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    private func content(_ layout: SingWordStripLayout) -> some View {
        // CANVAS CONTRACT (m16-a): value captures only, computed before the closure.
        let bars = layout.noteFrames.map(\.rect)
        let picked = layout.noteFrames.filter { selectedNoteIDs.contains($0.id) || $0.id == field?.noteID }.map(\.rect)
        let dots = layout.noteFrames.filter { styledNoteIDs.contains($0.id) }.map(\.rect)
        let holds = layout.items.compactMap { item -> SingStripHold? in
            guard let from = item.holdFromX, let to = item.holdToX else { return nil }
            return SingStripHold(fromX: from, toX: to, tickXs: item.holdTickXs, playing: item.wordIndex == playingChipID)
        }
        let wordDots = layout.items.filter { $0.kind == .dot }.map {
            CGRect(x: $0.x, y: SingWordStripLayout.top(of: $0), width: $0.width, height: $0.width)
        }
        let chips = layout.items.filter { $0.kind != .dot }
        let dotItems = layout.items.filter { $0.kind == .dot }
        return ZStack(alignment: .topLeading) {
            Canvas { @Sendable context, _ in
                for bar in bars {
                    context.fill(Path(roundedRect: bar, cornerRadius: 1.5),
                                 with: .color(DAWTheme.textSecondary.opacity(0.85)))
                }
                for ring in picked {
                    context.stroke(Path(roundedRect: ring.insetBy(dx: -2, dy: -2), cornerRadius: 2.5),
                                   with: .color(DAWTheme.playback), lineWidth: 1.2)
                }
                for dot in dots {
                    let center = CGPoint(x: dot.minX + 2.5, y: dot.minY - 4)
                    context.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)),
                                 with: .color(DAWTheme.ai))
                }
                // A held word: a line from where it starts holding to its last note's end, a tick on each held note.
                for hold in holds {
                    let color = DAWTheme.ai.opacity(hold.playing ? 1 : 0.6)
                    let y = SingWordStripLayout.holdLineY
                    context.fill(Path(CGRect(x: hold.fromX, y: y, width: max(1, hold.toX - hold.fromX),
                                             height: PianoRollWordLane.holdLineWidth)), with: .color(color))
                    for x in hold.tickXs {
                        context.fill(Path(CGRect(x: x, y: y - PianoRollWordLane.holdTickHeight, width: 1,
                                                 height: PianoRollWordLane.holdTickHeight)), with: .color(color))
                    }
                }
                // A word with no room in either row: a neutral dot (the lane's), its word on hover.
                for dot in wordDots {
                    context.fill(Path(ellipseIn: dot), with: .color(DAWTheme.textSecondary))
                }
            }
            ForEach(chips, id: \.noteID) { item in
                let playing = item.wordIndex == playingChipID
                Text(item.text)
                    .font(.system(size: PianoRollWordLane.fontSize, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(playing ? DAWTheme.textPrimary : DAWTheme.ai)
                    .frame(width: item.width, height: PianoRollWordLane.rowHeight - 1)
                    .background(DAWTheme.ai.opacity(playing ? 0.45 : (item.holdFromX != nil ? 0.22 : 0.14)))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(DAWTheme.ai.opacity(playing ? 1 : 0.6), lineWidth: 1))
                    .glow(DAWTheme.ai, radius: playing ? 7 : 4, intensity: playing ? 0.9 : 0.35)
                    .help(layout.tooltip(for: item))
                    .offset(x: item.x, y: SingWordStripLayout.top(of: item) + 0.5)
            }
            // A dot is too small to hover: each gets a target `rowGap` wider each side (the lane's own slop).
            ForEach(dotItems, id: \.noteID) { item in
                Color.clear
                    .frame(width: item.width + 2 * PianoRollWordLane.rowGap, height: item.width + 4)
                    .contentShape(Rectangle())
                    .help(layout.tooltip(for: item))
                    .offset(x: item.x - PianoRollWordLane.rowGap, y: SingWordStripLayout.top(of: item) - 2)
            }
            // Where the strip scrolls to show a note's field (or the playing word): one invisible span per note.
            ForEach(layout.noteFrames) { note in
                let span = layout.fieldRect(for: note)
                Color.clear
                    .frame(width: span.width, height: 1)
                    .offset(x: span.minX, y: 0)
                    .allowsHitTesting(false)
                    .id(SingStripAnchor(noteID: note.id))
            }
            if let field, let rect = layout.fieldRect(noteID: field.noteID) {
                TextField(SingCopy.noteWordPlaceholder,
                          text: Binding(get: { field.draft }, set: { onDraft($0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .padding(.horizontal, 6)
                    .frame(width: rect.width, height: rect.height)
                    .background(DAWTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(DAWTheme.ai, lineWidth: 1))
                    .glow(DAWTheme.ai, radius: 4, intensity: 0.5)
                    .focused($fieldFocused)
                    .onSubmit { onCommit(false) }
                    .onKeyPress(.tab) {
                        onCommit(true)
                        return .handled
                    }
                    .offset(x: rect.minX, y: rect.minY)
                    .onAppear { fieldFocused = true }
                    .onChange(of: field.noteID) { fieldFocused = true }
                    .help(SingCopy.noteWordHint)
            }
        }
        .frame(width: layout.contentWidth, height: SingWordStripLayout.height, alignment: .topLeading)
        // ONE tap for the whole strip, resolved by the layout's arithmetic (`SingWordStripLayout.target`): a word, a
        // part or a dot picks its chip (its first note); under the words, a note's column picks that note.
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture(count: 1).onEnded { value in
            switch layout.target(at: value.location, fieldNoteID: field?.noteID) {
            case .word(let chipID): onTapChip(chipID)
            case .note(let noteID): onTapNote(noteID)
            case nil: break
            }
        })
    }
}

/// One held word's line, by value (the Canvas draws it).
private struct SingStripHold {
    var fromX: CGFloat
    var toX: CGFloat
    var tickXs: [CGFloat]
    var playing: Bool
}

/// The id the strip scrolls to for a note: its own type, so it can never match a word chip's `ForEach` id.
private struct SingStripAnchor: Hashable {
    var noteID: UUID
}

/// Chip widths for the strip's words: each text measured ONCE, in the font the chip draws (SF Pro semibold at the
/// lane's size), whole points plus the chip's padding (`SingWordStripLayout.chipWidth`). App-wide: a width depends
/// only on its text, and the table is read only when the strip's data changes, never per frame.
@MainActor
private enum SingWordStripWidths {
    private static var measured: [String: CGFloat] = [:]
    private static let font = NSFont.systemFont(ofSize: PianoRollWordLane.fontSize, weight: .semibold)

    static func table(for texts: Set<String>) -> [String: CGFloat] {
        var table: [String: CGFloat] = [:]
        table.reserveCapacity(texts.count)
        for text in texts {
            if let width = measured[text] {
                table[text] = width
                continue
            }
            let width = SingWordStripLayout.chipWidth(
                textWidth: (text as NSString).size(withAttributes: [.font: font]).width)
            measured[text] = width
            table[text] = width
        }
        return table
    }
}
