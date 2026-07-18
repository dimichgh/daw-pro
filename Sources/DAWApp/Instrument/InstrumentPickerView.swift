import SwiftUI
import DAWCore
import DAWAppKit

/// The instrument picker (m10-n-3): the ONE shared surface opened from both the
/// track-header instrument chip and the mixer instrument-strip chip. It presents
/// as a centered dark-glass modal card over a dimmed scrim (the Settings-overlay
/// idiom) — chosen over a popover so it renders INSIDE the main window content and
/// `debug.captureUI` can snapshot it headlessly (a popover lives in its own
/// window, invisible to the window cacheDisplay path).
///
/// Three sections — Built-in / Sound Banks / Audio Units — with a search field
/// spanning them all, a GM program browser (categories, collapse, drum-kit group),
/// an "Add SoundFont…" import affordance, and the Simple/Pro density split
/// (Simple = curated "Instrument Sets"; Pro = the full browser). Every selection
/// produces one `InstrumentChoice` handed straight to `onChoose`.
///
/// NO VIOLET — standard chrome (docs/DESIGN-LANGUAGE.md Rule 3). Cyan marks only
/// the CURRENT selection (an earned active state).
struct InstrumentPickerOverlay: View {
    @Bindable var model: InstrumentPickerModel
    /// The picker's own Simple/Pro density store (the fifth live-chip surface —
    /// its modes genuinely differ, so it earns a chip; see the density inventory).
    var densityStore: PanelDensityStore
    /// Applies the chosen instrument to the target track (wired to
    /// `ProjectStore.setInstrument`), then closes the picker.
    var onChoose: (InstrumentChoice) -> Void
    /// NSOpenPanel → `model.importBank` (not headless, so it lives in the app view).
    var onImport: () -> Void
    /// NSOpenPanel → `store.importSampleLibrary` (m19-c): imports an .sfz
    /// (documented subset) or .dspreset sample-library file onto this
    /// track's built-in Sampler. Sits beside the sound-bank import flow.
    var onImportSampleLibrary: () -> Void
    var onClose: () -> Void

    /// The picker's stable panel ID for the shared density store.
    static let panelID = "instrumentPicker"

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            card
                .frame(width: 560)
                .frame(maxHeight: 640)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
        .transition(.opacity)
        // Keep the model's density in sync with the shared store so its
        // section-building (Simple vs Pro) reflects the live chip.
        .onAppear { model.density = densityStore.density(forPanel: Self.panelID) }
        .onChange(of: densityStore.density(forPanel: Self.panelID)) { _, new in
            model.density = new
        }
    }

    private var isPro: Bool { densityStore.density(forPanel: Self.panelID) == .pro }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchField
            Divider().overlay(DAWTheme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.isDrilledIn {
                        programBrowser
                    } else {
                        builtInSection
                        soundBankSection
                        audioUnitSection
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "pianokeys")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.textDim)
            Text("INSTRUMENT")
                .font(.system(size: 12, weight: .heavy))
                .tracking(2)
                .foregroundStyle(DAWTheme.textPrimary)
            Text("choose this track's sound")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
            Spacer()
            SimpleProToggle(
                store: densityStore, panelID: Self.panelID,
                help: "Simple: ready-made instrument sets. Pro: the full bank and plugin browser."
            )
            .explainable(.panelDensity)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Close the instrument picker")
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.textDim)
            TextField("Search instruments…", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(DAWTheme.textPrimary)
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DAWTheme.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(DAWTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    // MARK: - Section header

    private func sectionLabel(_ text: String, trailing: AnyView? = nil) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DAWTheme.textDim)
            Spacer()
            if let trailing { trailing }
        }
    }

    // MARK: - Built-in section

    @ViewBuilder
    private var builtInSection: some View {
        let items = model.builtIns
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                // The sample-library import lands on the built-in Sampler, so
                // its affordance lives on THIS section (the sound-bank import
                // button precedent below).
                sectionLabel("BUILT-IN", trailing: AnyView(sampleLibraryImportButton))
                ForEach(items) { item in
                    row(title: item.name, subtitle: item.detail, glyph: "waveform.path",
                        isCurrent: model.isCurrent(item.choice)) {
                        onChoose(item.choice)
                    }
                }
                if let notice = model.importNotice {
                    inlineNotice(notice)
                }
            }
        }
    }

    /// COPY LAW (m19-c): "imports .sfz (documented subset) and .dspreset
    /// sample-library files" — never a product-compatibility claim.
    private var sampleLibraryImportButton: some View {
        Button(action: onImportSampleLibrary) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text("Import Sample Library…")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(DAWTheme.textPrimary)   // neutral create-chrome (Rule 3)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Import an .sfz (documented subset) or .dspreset sample-library file onto this track's Sampler")
    }

    /// The neutral inline notice (m19-c): import-report facts — zone counts
    /// and degradations — in informational chrome, deliberately NOT the red
    /// `inlineError` style (a degraded import is a fact, not a failure).
    private func inlineNotice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.clearImportNotice() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(DAWTheme.panelRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    // MARK: - Sound Banks section

    @ViewBuilder
    private var soundBankSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("SOUND BANKS", trailing: AnyView(importButton))
            if isPro {
                // Pro: the bank list → drill into a program browser.
                ForEach(model.filteredBanks, id: \.path) { bank in
                    bankRow(bank)
                }
            } else {
                // Simple: the curated Instrument Sets (16 GM categories + Drums).
                ForEach(model.instrumentSets) { set in
                    row(title: set.name, subtitle: setSubtitle(set), glyph: setGlyph(set),
                        isCurrent: model.isCurrent(set.choice)) {
                        onChoose(set.choice)
                    }
                }
            }
            if let error = model.importError {
                inlineError(error)
            }
        }
        .explainable(.instrumentPickerSoundBanks)
    }

    private var importButton: some View {
        Button(action: onImport) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text("Add SoundFont…")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(DAWTheme.textPrimary)   // neutral create-chrome (Rule 3)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Import a SoundFont (.sf2) or DLS bank file into your library")
    }

    private func bankRow(_ bank: SoundBankInfo) -> some View {
        Button { model.drillInto(bank) } label: {
            HStack(spacing: 9) {
                Image(systemName: "pianokeys")
                    .font(.system(size: 12))
                    .foregroundStyle(DAWTheme.textDim)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(bank.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DAWTheme.textPrimary)
                        if bank.builtin { tag("BUILT-IN") }
                    }
                    Text("\(bank.format.uppercased()) · \(byteLabel(bank.sizeBytes))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(DAWTheme.textDim)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DAWTheme.textFaint)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(DAWTheme.panelRaised.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Browse the programs in \(bank.name)")
    }

    // MARK: - Program browser (Pro, drilled into a bank)

    private var programBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { model.drillOut() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                        Text("BANKS")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(1)
                    }
                    .foregroundStyle(DAWTheme.textDim)
                }
                .buttonStyle(.plain)
                .help("Back to the bank list")
                Text(model.drilledBank?.name ?? "Programs")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                Spacer()
                if !model.drilledNamesParsed {
                    Text("names unavailable")
                        .font(.system(size: 9))
                        .foregroundStyle(DAWTheme.textFaint)
                        .help("This bank exposes no program names — pick by number.")
                }
            }
            ForEach(model.programGroups) { group in
                programGroupView(group, bank: model.drilledBank)
            }
        }
    }

    @ViewBuilder
    private func programGroupView(_ group: ProgramGroup, bank: SoundBankInfo?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { model.toggleCategory(group.category) } label: {
                HStack(spacing: 6) {
                    Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DAWTheme.textDim)
                    Text(group.category.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(DAWTheme.textDim)
                    Text("\(group.programs.count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(DAWTheme.textFaint)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if !group.isCollapsed, let bank {
                ForEach(group.programs, id: \.self) { program in
                    let choice = model.choice(for: program, in: bank)
                    programRow(program, isCurrent: model.isCurrent(choice)) { onChoose(choice) }
                }
            }
        }
    }

    private func programRow(_ program: SoundBankProgram, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(String(format: "%3d", program.program))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DAWTheme.textFaint)
                Text(program.name)
                    .font(.system(size: 12))
                    .foregroundStyle(isCurrent ? DAWTheme.playback : DAWTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("bank \(program.bankMSB)/\(program.bankLSB)")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(DAWTheme.textFaint)
                if isCurrent { currentTick }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .padding(.leading, 12)
            .background(isCurrent ? DAWTheme.playback.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Audio Units section

    @ViewBuilder
    private var audioUnitSection: some View {
        let units = model.filteredAudioUnits
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("AUDIO UNITS")
            if units.isEmpty {
                Text(model.audioUnits.isEmpty
                     ? "No Audio Unit instruments are installed on this Mac."
                     : "No plugins match your search.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .padding(.vertical, 2)
            } else {
                ForEach(units, id: \.component) { au in
                    let choice = model.choice(for: au)
                    row(title: au.name, subtitle: au.manufacturerName, glyph: "puzzlepiece.extension.fill",
                        isCurrent: model.isCurrent(choice), badge: au.isV3 ? "AUv3" : nil) {
                        onChoose(choice)
                    }
                }
            }
        }
        .explainable(.instrumentPickerAudioUnits)
    }

    // MARK: - Shared row

    private func row(title: String, subtitle: String, glyph: String,
                     isCurrent: Bool, badge: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: glyph)
                    .font(.system(size: 12))
                    .foregroundStyle(isCurrent ? DAWTheme.playback : DAWTheme.textDim)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isCurrent ? DAWTheme.playback : DAWTheme.textPrimary)
                            .lineLimit(1)
                        if let badge { tag(badge) }
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 9.5))
                            .foregroundStyle(DAWTheme.textDim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isCurrent { currentTick }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(isCurrent ? DAWTheme.playback.opacity(0.1) : DAWTheme.panelRaised.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(isCurrent ? DAWTheme.playback.opacity(0.4) : DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var currentTick: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(DAWTheme.playback)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(DAWTheme.textDim)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(DAWTheme.panelRaised)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(DAWTheme.hairline, lineWidth: 1))
    }

    private func inlineError(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.record)
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DAWTheme.record)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.clearImportError() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(DAWTheme.record.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Small helpers

    private func setSubtitle(_ set: InstrumentSet) -> String {
        set.name == "Drums" ? "Standard Drum Kit" : "e.g. \(set.program.name)"
    }
    private func setGlyph(_ set: InstrumentSet) -> String {
        set.name == "Drums" ? "circle.grid.cross" : "pianokeys"
    }

    private func byteLabel(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return "\(bytes / 1_000_000) MB" }
        if bytes >= 1_000 { return "\(bytes / 1_000) KB" }
        return "\(bytes) B"
    }
}
