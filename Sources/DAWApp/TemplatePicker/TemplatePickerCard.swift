import SwiftUI
import DAWCore
import DAWAppKit

/// The template picker card — "Start with a band" (m39-tpl-8, design §9.2).
///
/// A centered dark-glass card over a dimmed scrim, INSIDE the window (the
/// sampler card's pattern, so `debug.captureUI` can photograph it), mounted by
/// `TemplatePickerCardMount` in `ContentView.pickerOverlays`. Thin by design:
/// every tile, every button's state and reason, every sentence comes from
/// `TemplatePickerState` (DAWAppKit, tested headless), and every press goes to
/// `TemplatePickerModel`, which makes the ONE store call a wire verb makes.
///
/// - **Simple** (the default): the ten built-ins, Start a song / Add to my song.
/// - **Pro**: the Built-in / My Templates switch, a detail pane BESIDE the grid
///   (it adds width, not height), Import…, Export…, Remove, Save as Template….
///
/// The height budget is `TemplatePickerLayout`'s: the TEMPLATE GRID is the one
/// region that yields; everything else takes a fixed height, the message slot
/// included, so a warning appearing never moves the buttons.
///
/// NO VIOLET anywhere (§9.4): a band template is a scaffold, not AI-generated
/// audio. The buttons are NEUTRAL chrome (Rule 3: create/add earns no accent at
/// rest) — the primary is told apart by a light fill, not a colour. Cyan marks
/// only earned state: the selected tile and the density chip's active half.
///
/// ⭐ RETURN presses the primary button (`.defaultAction`) — on the Sketchpad's
/// Pop Band, one Return still starts a pop song (§9.1). ⚠️ Not verifiable on an
/// unbundled staging binary (key events do not reach it, m23-g1); the headless
/// stand-in is `TemplatePickerModel.pressPrimary()`. NO Escape binding: every
/// `.cancelAction` in the app is pinned by `EscapeKeyMonitorSiteTests`, and the
/// card closes with its ✕ or a click on the scrim.
struct TemplatePickerCard: View {
    let picker: TemplatePickerModel
    let state: TemplatePickerState
    var densityStore: PanelDensityStore
    var availableHeight: CGFloat
    var onImport: () -> Void
    var onExport: () -> Void
    var onSaveAsTemplate: () -> Void
    var onClose: () -> Void

    private typealias L = TemplatePickerLayout
    private typealias W = TemplatePickerCopy

    private var isPro: Bool { state.isPro }

    var body: some View {
        let gridHeight = L.gridHeight(tileCount: state.gridCellCount, isPro: isPro,
                                      availableHeight: availableHeight)
        VStack(alignment: .leading, spacing: 12) {
            header
            if state.showsTabs { tabs }
            HStack(alignment: .top, spacing: 14) {
                grid(height: gridHeight)
                    .frame(width: L.simpleCardWidth - 32)
                if state.showsDetail { detailPane(height: gridHeight) }
            }
            buttonRow
            messageSlot
            if state.showsLibraryRow { libraryRow }
        }
        .padding(16)
        .frame(width: isPro ? L.proCardWidth : L.simpleCardWidth, alignment: .leading)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DAWTheme.textDim)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(W.title)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(DAWTheme.textPrimary)
                Text(W.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            SimpleProToggle(
                store: densityStore, panelID: TemplatePickerModel.panelID,
                help: "Simple: the ten built-in bands. Pro: your own templates, details, import and export.")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    // MARK: - Pro: Built-in / My Templates

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(TemplatePickerTab.allCases, id: \.self) { tab in
                let isOn = state.visibleTab == tab
                Button { picker.setTab(tab) } label: {
                    Text(tab.title.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(isOn ? DAWTheme.playback : DAWTheme.textDim)
                        .frame(height: 22)
                        .padding(.horizontal, 12)
                        .background(isOn ? DAWTheme.playback.opacity(0.18) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        .frame(height: 24)
    }

    // MARK: - The grid (the ONE region that yields)

    private func grid(height: CGFloat) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: L.tileGap), count: L.columns)
        return ScrollView(.vertical) {
            if state.showsEmptySavedLine {
                Text(W.noSavedTemplates)
                    .font(.system(size: 11))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: L.tileHeight, alignment: .leading)
            } else {
                LazyVGrid(columns: columns, spacing: L.tileGap) {
                    ForEach(state.tiles) { tile in
                        tileView(tile)
                    }
                    ForEach(state.unreadableTiles) { tile in
                        unreadableTileView(tile)
                    }
                }
            }
        }
        .frame(height: height)
    }

    private func tileView(_ tile: TemplatePickerTile) -> some View {
        let isSelected = state.selectedID == tile.id
        let shown = Array(tile.glyphs.prefix(8))
        return Button { picker.select(tile.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(tile.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .lineLimit(1)
                Text(tile.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, glyph in
                        Image(systemName: glyph.systemImage)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isSelected ? DAWTheme.textPrimary : DAWTheme.textDim)
                    }
                    if tile.glyphs.count > shown.count {
                        Text("+\(tile.glyphs.count - shown.count)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(DAWTheme.textDim)
                    }
                    Spacer(minLength: 4)
                    Text(tile.trackCountLabel)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DAWTheme.textDim)
                        .fixedSize()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: L.tileHeight, maxHeight: L.tileHeight, alignment: .topLeading)
            .background(isSelected ? DAWTheme.playback.opacity(0.08) : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? DAWTheme.playback.opacity(0.75) : DAWTheme.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(tile.summary)
    }

    /// A saved file that could not be read: greyed, never clickable, with the
    /// library's reason (§9.3, §7.3).
    private func unreadableTileView(_ tile: TemplatePickerUnreadableTile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                Text(tile.file)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(DAWTheme.textDim)
            Text("\(W.unreadableTitle): \(tile.reason)")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: L.tileHeight, maxHeight: L.tileHeight, alignment: .topLeading)
        .background(DAWTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DAWTheme.hairline, lineWidth: 1))
        .opacity(0.7)
        .help(tile.reason)
    }

    // MARK: - Pro: the detail pane (beside the grid, the grid's height)

    private func detailPane(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(W.detailHeader)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DAWTheme.textDim)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(state.detailLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10))
                            .foregroundStyle(DAWTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: L.detailPaneWidth, height: height, alignment: .topLeading)
        .background(DAWTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    // MARK: - The buttons

    private var buttonRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Spacer(minLength: 0)
            ForEach(state.buttons) { button in
                buttonColumn(button)
            }
        }
    }

    private func buttonColumn(_ button: TemplatePickerButton) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                if button.action == .startSong, let menu = state.songStyleMenu {
                    songStyleMenu(menu)
                }
                actionButton(button)
            }
            Text(button.explanation)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 250, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func actionButton(_ button: TemplatePickerButton) -> some View {
        let label = Text(button.title)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(!button.isEnabled ? DAWTheme.textDim
                             : (button.isPrimary ? DAWTheme.background : DAWTheme.textPrimary))
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(button.isPrimary && button.isEnabled ? DAWTheme.textPrimary : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
        let base = Button { picker.press(button.action) } label: { label }
            .buttonStyle(.plain)
            .disabled(!button.isEnabled)
            .help(button.disabledReason ?? button.explanation)
        if button.isPrimary {
            base.keyboardShortcut(.defaultAction)
        } else {
            base
        }
    }

    private func songStyleMenu(_ menu: TemplatePickerSongStyleMenu) -> some View {
        Menu {
            ForEach(menu.options) { option in
                Button {
                    picker.setSongStyle(option.genre)
                } label: {
                    if option.genre == menu.selectedGenre {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text("\(W.songStyleLabel): \(menu.selectedTitle)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DAWTheme.textPrimary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The kind of song outline Start a song lays out: its tempo and sections")
    }

    // MARK: - The message slot (fixed height)

    private var messageSlot: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(state.messages) { message in
                    messageLine(message)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: L.messageSlotHeight)
    }

    @ViewBuilder
    private func messageLine(_ message: TemplatePickerMessage) -> some View {
        switch message.tone {
        case .caution:
            PanelRefusalLine(message: message.text)
        case .info:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                Text(message.text)
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Pro: the library row

    private var libraryRow: some View {
        HStack(spacing: 8) {
            if let pending = state.pendingRemovalID {
                let name = state.listing.entry(id: pending)?.name ?? pending
                Text(W.removeConfirm(name: name))
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.record)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                chip(W.removeKeepButton) { picker.cancelRemove() }
                Button(role: .destructive) { picker.confirmRemove() } label: {
                    Text(W.removeConfirmButton)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DAWTheme.clip)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(DAWTheme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.clip.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                chip(W.importButton, action: onImport)
                chip(W.exportButton, enabled: state.canExport, action: onExport)
                chip(W.removeButton, enabled: state.canRemove) { picker.requestRemoveSelected() }
                Spacer(minLength: 6)
                chip(W.saveAsTemplateButton, enabled: state.facts.songHasTracks, action: onSaveAsTemplate)
                    .help(state.facts.songHasTracks ? "Keep tracks from this song as a template of your own"
                          : W.saveNoTracksInSong)
            }
        }
        .frame(height: 26)
    }

    private func chip(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? DAWTheme.textPrimary : DAWTheme.textDim)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
