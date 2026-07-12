import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Unit tests for the headless instrument-picker view-model (m10-n-3): section
/// building, search filtering across every section, category collapse, the
/// Simple-density "Instrument Sets" mapping, and `InstrumentChoice` construction
/// (GM program → correct `SoundBankConfig`; AU → correct component triple). The
/// SwiftUI picker is thin over this, so exercising it here covers the picker's
/// logic without a display OR a store (the injected-provider precedent).
@Suite("InstrumentPickerModel")
@MainActor
struct InstrumentPickerModelTests {

    // MARK: - Fixtures

    private static let gmBank = SoundBankInfo(
        source: .generalMIDI, name: "General MIDI",
        path: SoundBankLibrary.systemGMBankPath, format: "dls", builtin: true, sizeBytes: 1_969_024)

    private static let userBank = SoundBankInfo(
        source: .file(path: "/Banks/Vintage.sf2"), name: "Vintage",
        path: "/Banks/Vintage.sf2", format: "sf2", builtin: false, sizeBytes: 31_457_280)

    private static let dls = AudioUnitComponentInfo(
        component: AudioUnitComponentID(type: "aumu", subType: "dls ", manufacturer: "appl"),
        name: "DLSMusicDevice", manufacturerName: "Apple", versionString: "1.0", isV3: false)
    private static let sampler = AudioUnitComponentInfo(
        component: AudioUnitComponentID(type: "aumu", subType: "samp", manufacturer: "appl"),
        name: "AUSampler", manufacturerName: "Apple", versionString: "1.0", isV3: false)
    private static let third = AudioUnitComponentInfo(
        component: AudioUnitComponentID(type: "aumu", subType: "vsti", manufacturer: "Ace!"),
        name: "Massive", manufacturerName: "Native Instruments", versionString: "1.4", isV3: true)

    /// A model wired to fixed fixtures — GM + one user bank, three AUs, GM
    /// programs resolved from the real catalog, an importer that records + echoes.
    private static func makeModel(
        banks: [SoundBankInfo]? = nil,
        audioUnits: [AudioUnitComponentInfo]? = nil,
        onImport: ((URL) throws -> SoundBankInfo)? = nil
    ) -> InstrumentPickerModel {
        InstrumentPickerModel(
            soundBanks: { banks ?? [gmBank, userBank] },
            programs: { source in
                switch source {
                case .generalMIDI: return (GMProgramCatalog.programs, true)
                case .file:
                    // A generic un-named bank (the SF2-parse-failed fallback).
                    return ((0...127).map {
                        SoundBankProgram(program: $0, bankMSB: 121, bankLSB: 0,
                                         name: "Program \($0)", category: "")
                    }, false)
                }
            },
            audioUnits: { audioUnits ?? [dls, sampler, third] },
            importer: onImport ?? { url in
                SoundBankInfo(source: .file(path: url.path), name: url.deletingPathExtension().lastPathComponent,
                              path: url.path, format: url.pathExtension.lowercased(),
                              builtin: false, sizeBytes: 100) })
    }

    private static func prepared(density: PanelDensity = .pro,
                                 descriptor: InstrumentDescriptor? = nil) -> InstrumentPickerModel {
        let model = makeModel()
        model.prepare(trackID: UUID(), descriptor: descriptor, status: nil)
        model.density = density
        return model
    }

    // MARK: - Section building

    @Test("prepare loads the three sections from the providers")
    func sectionBuilding() {
        let model = Self.prepared()
        #expect(model.banks.map(\.name) == ["General MIDI", "Vintage"])   // GM first
        #expect(model.audioUnits.count == 3)
        // Pro built-ins: all three, Test Tone included.
        #expect(model.builtIns.map(\.kind) == [.polySynth, .sampler, .testTone])
    }

    @Test("Simple hides Test Tone; Pro shows it")
    func builtInDensitySplit() {
        let model = Self.prepared(density: .simple)
        #expect(model.builtIns.map(\.kind) == [.polySynth, .sampler])
        model.density = .pro
        #expect(model.builtIns.map(\.kind) == [.polySynth, .sampler, .testTone])
    }

    // MARK: - Search (spans all sections)

    @Test("search filters built-ins, banks, and audio units at once")
    func searchSpansSections() {
        let model = Self.prepared()
        model.searchText = "samp"
        // Built-in "Sampler", the AU "AUSampler" — both survive; "General MIDI"
        // bank does not.
        #expect(model.builtIns.map(\.name) == ["Sampler"])
        #expect(model.filteredAudioUnits.map(\.name) == ["AUSampler"])
        #expect(model.filteredBanks.isEmpty)
    }

    @Test("AU search matches manufacturer as well as name")
    func searchMatchesManufacturer() {
        let model = Self.prepared()
        model.searchText = "native"
        #expect(model.filteredAudioUnits.map(\.name) == ["Massive"])
    }

    @Test("empty / whitespace search matches everything")
    func emptySearchMatchesAll() {
        let model = Self.prepared()
        model.searchText = "   "
        #expect(model.filteredAudioUnits.count == 3)
        #expect(model.filteredBanks.count == 2)
    }

    // MARK: - Program browser + category collapse

    @Test("drilling GM builds category groups in program order incl. Drum Kits")
    func programBrowserGroups() {
        let model = Self.prepared()
        model.drillInto(Self.gmBank)
        #expect(model.isDrilledIn)
        #expect(model.drilledNamesParsed)
        let cats = model.programGroups.map(\.category)
        #expect(cats.first == "Piano")
        #expect(cats.contains("Brass"))
        #expect(cats.last == "Drum Kits")           // percussion group at the end
        // Each melodic category holds its 8 programs.
        #expect(model.programGroups.first { $0.category == "Brass" }?.programs.count == 8)
        // Trumpet (program 56) is the first Brass program.
        #expect(model.programGroups.first { $0.category == "Brass" }?.programs.first?.name == "Trumpet")
    }

    @Test("category collapse flips the group's flag without dropping its programs")
    func categoryCollapse() {
        let model = Self.prepared()
        model.drillInto(Self.gmBank)
        #expect(model.programGroups.first { $0.category == "Piano" }?.isCollapsed == false)
        model.toggleCategory("Piano")
        let group = model.programGroups.first { $0.category == "Piano" }
        #expect(group?.isCollapsed == true)
        #expect(group?.programs.count == 8)         // still there — the VIEW hides the rows
        model.toggleCategory("Piano")
        #expect(model.programGroups.first { $0.category == "Piano" }?.isCollapsed == false)
    }

    @Test("program-browser search filters programs across categories")
    func programSearch() {
        let model = Self.prepared()
        model.drillInto(Self.gmBank)
        model.searchText = "trumpet"
        let groups = model.programGroups
        #expect(groups.map(\.category) == ["Brass"])
        #expect(groups.first?.programs.map(\.name) == ["Trumpet", "Muted Trumpet"])
    }

    @Test("an un-named bank falls into a trailing Programs group, namesParsed false")
    func genericBankGrouping() {
        let model = Self.prepared()
        model.drillInto(Self.userBank)
        #expect(model.drilledNamesParsed == false)
        #expect(model.programGroups.map(\.category) == ["Programs"])
        #expect(model.programGroups.first?.programs.count == 128)
    }

    @Test("drillOut clears the browser and resets search")
    func drillOut() {
        let model = Self.prepared()
        model.drillInto(Self.gmBank)
        model.searchText = "trumpet"
        model.drillOut()
        #expect(!model.isDrilledIn)
        #expect(model.searchText.isEmpty)
        #expect(model.programGroups.isEmpty)
    }

    // MARK: - Simple mapping (Instrument Sets)

    @Test("Instrument Sets = 16 GM categories + Drums, each mapped to its first program")
    func instrumentSets() {
        let model = Self.prepared(density: .simple)
        let sets = model.instrumentSets
        #expect(sets.count == 17)                    // 16 categories + Drums
        #expect(sets.first?.name == "Piano")
        #expect(sets.first?.program.program == 0)    // Piano → program 0
        let brass = sets.first { $0.name == "Brass" }
        #expect(brass?.program.program == 56)        // Brass → Trumpet (56)
        let drums = sets.last
        #expect(drums?.name == "Drums")
        #expect(drums?.program.bankMSB == 120)       // percussion bank
        #expect(drums?.program.program == 0)
    }

    @Test("Instrument Set choice is a GM SoundBankConfig with a captured display name")
    func instrumentSetChoice() {
        let model = Self.prepared(density: .simple)
        let brass = model.instrumentSets.first { $0.name == "Brass" }!
        guard case .soundBank(let config) = brass.choice else {
            Issue.record("expected a soundBank choice"); return
        }
        #expect(config.source == .generalMIDI)
        #expect(config.program == 56)
        #expect(config.bankMSB == 121)
        #expect(config.displayName == "Trumpet — General MIDI")
    }

    @Test("Instrument Sets filter by search on the set name")
    func instrumentSetSearch() {
        let model = Self.prepared(density: .simple)
        model.searchText = "brass"
        #expect(model.instrumentSets.map(\.name) == ["Brass"])
    }

    // MARK: - Choice construction

    @Test("GM program choice builds the right SoundBankConfig with 'Name — Bank'")
    func gmProgramChoice() {
        let model = Self.prepared()
        model.drillInto(Self.gmBank)
        let trumpet = model.programGroups.first { $0.category == "Brass" }!.programs.first!
        guard case .soundBank(let config) = model.choice(for: trumpet, in: Self.gmBank) else {
            Issue.record("expected a soundBank choice"); return
        }
        #expect(config.source == .generalMIDI)
        #expect(config.program == 56)
        #expect(config.bankMSB == 121)
        #expect(config.bankLSB == 0)
        #expect(config.displayName == "Trumpet — General MIDI")
    }

    @Test("an un-named bank program choice uses the '· Pn' fallback name")
    func genericProgramChoiceName() {
        let model = Self.prepared()
        model.drillInto(Self.userBank)
        let program = model.programGroups.first!.programs[5]   // "Program 5"
        guard case .soundBank(let config) = model.choice(for: program, in: Self.userBank) else {
            Issue.record("expected a soundBank choice"); return
        }
        #expect(config.displayName == "Vintage · P5")
    }

    @Test("AU choice carries the component triple and captured display facts")
    func audioUnitChoice() {
        let model = Self.prepared()
        guard case .audioUnit(let config) = model.choice(for: Self.dls) else {
            Issue.record("expected an audioUnit choice"); return
        }
        #expect(config.component.type == "aumu")
        #expect(config.component.subType == "dls ")
        #expect(config.component.manufacturer == "appl")
        #expect(config.name == "DLSMusicDevice")
        #expect(config.manufacturerName == "Apple")
    }

    // MARK: - Current-selection highlighting + chip name

    @Test("isCurrent matches the descriptor by structural identity, not display name")
    func isCurrentMatching() {
        // A GM Trumpet is the current instrument.
        let current = InstrumentDescriptor(
            kind: .soundBank,
            soundBank: SoundBankConfig(source: .generalMIDI, program: 56, bankMSB: 121, bankLSB: 0,
                                       displayName: "a stale cached name"))
        let model = Self.prepared(descriptor: current)
        model.drillInto(Self.gmBank)
        let trumpet = model.programGroups.first { $0.category == "Brass" }!.programs.first!
        // Same address ⇒ current, even though the display names differ (LAW L8).
        #expect(model.isCurrent(model.choice(for: trumpet, in: Self.gmBank)))
        // A different program is NOT current.
        let trombone = model.programGroups.first { $0.category == "Brass" }!.programs[1]
        #expect(!model.isCurrent(model.choice(for: trombone, in: Self.gmBank)))
        // Built-ins / AUs of a soundBank track are not current.
        #expect(!model.isCurrent(.builtIn(.polySynth)))
        #expect(!model.isCurrent(model.choice(for: Self.dls)))
    }

    @Test("isCurrent matches a built-in by kind and an AU by component")
    func isCurrentBuiltInAndAU() {
        let builtIn = Self.prepared(descriptor: InstrumentDescriptor(kind: .polySynth))
        #expect(builtIn.isCurrent(.builtIn(.polySynth)))
        #expect(!builtIn.isCurrent(.builtIn(.sampler)))

        let au = InstrumentDescriptor(
            kind: .audioUnit,
            audioUnit: AudioUnitConfig(component: Self.dls.component, name: "DLSMusicDevice"))
        let auModel = Self.prepared(descriptor: au)
        #expect(auModel.isCurrent(auModel.choice(for: Self.dls)))
        #expect(!auModel.isCurrent(auModel.choice(for: Self.sampler)))
    }

    @Test("currentDisplayName reads the descriptor for each kind")
    func currentDisplayName() {
        #expect(InstrumentPickerModel.displayName(for: nil) == "Poly Synth")
        #expect(InstrumentPickerModel.displayName(for: InstrumentDescriptor(kind: .sampler)) == "Sampler")
        #expect(InstrumentPickerModel.displayName(for: InstrumentDescriptor(
            kind: .audioUnit, audioUnit: AudioUnitConfig(component: Self.dls.component, name: "DLSMusicDevice"))) == "DLSMusicDevice")
        #expect(InstrumentPickerModel.displayName(for: InstrumentDescriptor(
            kind: .soundBank, soundBank: SoundBankConfig(source: .generalMIDI, program: 56,
                displayName: "Trumpet — General MIDI"))) == "Trumpet — General MIDI")
    }

    // MARK: - Import

    @Test("importBank refreshes the list and returns the new bank")
    func importSuccess() {
        var imported: [URL] = []
        let model = Self.makeModel(onImport: { url in
            imported.append(url)
            return SoundBankInfo(source: .file(path: url.path), name: "Fresh",
                                 path: url.path, format: "sf2", builtin: false, sizeBytes: 10)
        })
        model.prepare(trackID: UUID(), descriptor: nil, status: nil)
        let result = model.importBank(from: URL(fileURLWithPath: "/tmp/Fresh.sf2"))
        #expect(result?.name == "Fresh")
        #expect(imported.count == 1)
        #expect(model.importError == nil)
    }

    @Test("a failed import surfaces the error and does not throw")
    func importFailure() {
        let model = Self.makeModel(onImport: { _ in
            throw ProjectError.importFailed("sound bank must be a .sf2 or .dls file — got song.mp3")
        })
        model.prepare(trackID: UUID(), descriptor: nil, status: nil)
        let result = model.importBank(from: URL(fileURLWithPath: "/tmp/song.mp3"))
        #expect(result == nil)
        #expect(model.importError?.contains(".sf2 or .dls") == true)
        model.clearImportError()
        #expect(model.importError == nil)
    }
}
