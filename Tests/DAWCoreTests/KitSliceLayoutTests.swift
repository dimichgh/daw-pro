import Foundation
import Testing
@testable import DAWCore

// m39-w4-6 — the pure half of kit-aware slicing: `DrumHitClassifier`, `KitSliceLayout`, the settings, and the
// sampler branch of `DrumLaneMap`. Design `docs/design/2026-10-07-loop-drum-depth.md` §5.2–§5.4, §9.2, §10.3.
// NOT `@MainActor`: all pure.
@Suite("Kit slicing — classifier, layout and lane map (m39-w4-6)")
struct KitSliceLayoutTests {

    static let clipID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C5")!
    static let url = URL(fileURLWithPath: "/tmp/w46-layout/loop.wav")

    /// A timbre with every feature chosen by hand: `role` picks a textbook example of that role.
    static func timbre(_ role: KitSliceRole, peak: Double = 0.5) -> SliceTimbre {
        switch role {
        case .kick:
            return SliceTimbre(lowEnergyShare: 0.95, highEnergyShare: 0, attackCentroidHz: 70, decaySeconds: 0.2,
                               decayReachedFloor: true, spectralFlatness: 1e-6, peak: peak, durationSeconds: 0.5)
        case .snare:
            return SliceTimbre(lowEnergyShare: 0.05, highEnergyShare: 0.1, attackCentroidHz: 1_500,
                               decaySeconds: 0.06, decayReachedFloor: true, spectralFlatness: 0.01, peak: peak,
                               durationSeconds: 0.5)
        case .closedHat:
            return SliceTimbre(lowEnergyShare: 0, highEnergyShare: 0.97, attackCentroidHz: 10_000,
                               decaySeconds: 0.02, decayReachedFloor: true, spectralFlatness: 0.03, peak: peak,
                               durationSeconds: 0.5)
        case .openHat:
            return SliceTimbre(lowEnergyShare: 0, highEnergyShare: 0.97, attackCentroidHz: 10_000,
                               decaySeconds: 0.15, decayReachedFloor: true, spectralFlatness: 0.01, peak: peak,
                               durationSeconds: 0.5)
        case .other:
            return SliceTimbre(lowEnergyShare: 0, highEnergyShare: 0, attackCentroidHz: 1_000, decaySeconds: 0.1,
                               decayReachedFloor: true, spectralFlatness: 1e-9, peak: peak, durationSeconds: 0.5)
        }
    }

    /// A chromatic plan of `count` slices at 48 kHz (pads 0, 1, 2…, the kit path's plan settings).
    static func chromaticPlan(_ count: Int) throws -> SliceToSamplerPlan.Result {
        let frames = (1..<count).map { $0 * 24_000 }
        let geometry = SliceBoundaryGeometry(sampleRate: 48_000, frameCount: count * 24_000,
                                             boundaryFrames: frames,
                                             snapOffsetFrames: Array(repeating: 0, count: frames.count),
                                             residualAmplitude: Array(repeating: 0, count: frames.count))
        let settings = SliceToSamplerSettings(mode: .divisions, divisions: max(2, count), maxSlices: 96,
                                              mapping: .kit)
        return try SliceToSamplerPlan.compute(
            clip: Clip(name: "Loop", startBeat: 0, lengthBeats: Double(count), audioFileURL: url),
            geometry: geometry, strengths: [], settings: settings.planSettings,
            tempoMap: TempoMap(constantBPM: 120))
    }

    // MARK: - The classifier on hand-made timbres

    @Test("the classifier names each textbook timbre, and 'other' stays other")
    func classifierOnTextbookTimbres() {
        #expect(DrumHitClassifier.classify(Self.timbre(.kick)).role == .kick)
        #expect(DrumHitClassifier.classify(Self.timbre(.snare)).role == .snare)
        #expect(DrumHitClassifier.classify(Self.timbre(.closedHat)).role == .closedHat)
        #expect(DrumHitClassifier.classify(Self.timbre(.openHat)).role == .openHat)
        let other = DrumHitClassifier.classify(Self.timbre(.other))
        #expect(other.role == nil)
        for role in KitSliceRole.allCases {
            let confidence = DrumHitClassifier.classify(Self.timbre(role)).confidence
            #expect((0.5...1).contains(confidence), "\(role): confidence \(confidence) outside 0.5…1")
        }
        // A hat still ringing when the slice ended is OPEN, whatever its measured decay.
        var cut = Self.timbre(.closedHat)
        cut.decayReachedFloor = false
        #expect(DrumHitClassifier.classify(cut).role == .openHat)
    }

    @Test("a voice a kit does not sort into is 'other', never the nearest of the four")
    func unsortedVoicesAreOther() {
        #expect(KitSliceRole(.clap) == .other)
        #expect(KitSliceRole(.tom) == .other)
        #expect(KitSliceRole(.rim) == .other)
        #expect(KitSliceRole(.cymbal) == .other)
        #expect(KitSliceRole(nil) == .other)
        #expect(KitSliceRole(.closedHat) == .closedHat, "control: a sorted voice maps to itself")
        #expect(KitSliceRole.allCases.map(\.drumVoice) == [.kick, .snare, .closedHat, .openHat, nil])
    }

    // MARK: - Layout: notes

    @Test("General MIDI notes, the loudest of a role first, overflow and other from 84 in time order")
    func notesFollowTheDesign() throws {
        let roles: [KitSliceRole] = [.kick, .closedHat, .snare, .closedHat, .kick, .closedHat, .kick, .other,
                                     .openHat, .snare, .snare]
        let loud: [Double] = [0.5, 0.3, 0.9, 0.4, 0.8, 0.2, 0.6, 0.7, 0.5, 0.4, 0.95]
        let notes = try KitSliceLayout.notes(roles: roles, loudness: loud, clipId: Self.clipID)
        // kicks: 0.8 (slice 4) → 36, 0.6 (slice 6) → 35, 0.5 (slice 0) → extra
        // snares: 0.95 (10) → 38, 0.9 (2) → 40, 0.4 (9) → extra
        // closed hats: 0.4 (3) → 42, 0.3 (1) → 44, 0.2 (5) → extra; open hat (8) → 46; other (7) → extra
        // extras in time order: 0, 5, 7, 9 → 84, 85, 86, 87
        #expect(notes == [84, 44, 40, 42, 36, 85, 35, 86, 46, 87, 38])
    }

    @Test("equal loudness goes to the earlier slice")
    func tiesGoToTheEarlierSlice() throws {
        let notes = try KitSliceLayout.notes(roles: [.kick, .kick, .kick], loudness: [0.5, 0.5, 0.5],
                                             clipId: Self.clipID)
        #expect(notes == [36, 35, 84])
    }

    @Test("extras past note 127 are REFUSED with a sentence, never truncated")
    func extrasPastMIDIAreRefused() throws {
        let fits = [KitSliceRole](repeating: .other, count: 44)        // 84…127
        #expect(try KitSliceLayout.notes(roles: fits, loudness: Array(repeating: 1, count: 44),
                                         clipId: Self.clipID).last == 127)
        let over = [KitSliceRole](repeating: .other, count: 45)
        #expect(throws: ProjectError.self) {
            try KitSliceLayout.notes(roles: over, loudness: Array(repeating: 1, count: 45), clipId: Self.clipID)
        }
        do {
            _ = try KitSliceLayout.notes(roles: over, loudness: Array(repeating: 1, count: 45), clipId: Self.clipID)
        } catch {
            #expect("\(error)".contains("MIDI stops at 127"), "\(error)")
        }
    }

    // MARK: - Layout: the plan

    @Test("apply: only the note, the role and the hats' choke move; timing, length, velocity and frames stay")
    func applyMovesOnlyTheNote() throws {
        let plan = try Self.chromaticPlan(5)
        let timbres: [SliceTimbre] = [.kick, .snare, .closedHat, .openHat, .other].map { Self.timbre($0) }
        let outcome = try KitSliceLayout.apply(to: plan, timbres: timbres, overrides: [:], clipId: Self.clipID)
        let kit = outcome.plan
        #expect(kit.zones.map(\.rootPitch) == [36, 38, 42, 46, 84])
        #expect(kit.zones.map(\.minPitch) == [36, 38, 42, 46, 84])
        #expect(kit.zones.map(\.maxPitch) == [36, 38, 42, 46, 84])
        #expect(kit.zones.map(\.drumRole) == [.kick, .snare, .closedHat, .openHat, nil])
        #expect(kit.zones.map(\.chokeGroup) == [nil, nil, 0, 0, nil])
        #expect(kit.slices.map(\.role) == [.kick, .snare, .closedHat, .openHat, .other])
        #expect(kit.slices.allSatisfy { ($0.confidence ?? 0) >= 0.5 })
        #expect(kit.notes.map(\.pitch) == [36, 38, 42, 46, 84])
        // Everything else is the chromatic plan's, field for field.
        #expect(kit.zones.map(\.startFrame) == plan.zones.map(\.startFrame))
        #expect(kit.zones.map(\.endFrame) == plan.zones.map(\.endFrame))
        #expect(kit.zones.map(\.id) == plan.zones.map(\.id))
        #expect(kit.zones.map(\.attack) == plan.zones.map(\.attack))
        #expect(kit.zones.map(\.release) == plan.zones.map(\.release))
        #expect(kit.zones.map(\.gain) == plan.zones.map(\.gain))
        #expect(kit.notes.map(\.startBeat) == plan.notes.map(\.startBeat))
        #expect(kit.notes.map(\.lengthBeats) == plan.notes.map(\.lengthBeats))
        #expect(kit.notes.map(\.velocity) == plan.notes.map(\.velocity))
        #expect(kit.slices.map(\.startFrame) == plan.slices.map(\.startFrame))
        #expect(kit.slices.map(\.beat) == plan.slices.map(\.beat))
        #expect(kit.warnings == plan.warnings && kit.headSeconds == plan.headSeconds)
        #expect(outcome.summary == "Sorted into 1 kick, 1 snare, 1 closed hat, 1 open hat and 1 other hit.")
    }

    @Test("C5 at the layout: the unrecognised hit is on 84 with role other, never folded into a hat")
    func otherIsNeverFolded() throws {
        let plan = try Self.chromaticPlan(2)
        let outcome = try KitSliceLayout.apply(to: plan, timbres: [Self.timbre(.closedHat), Self.timbre(.other)],
                                               overrides: [:], clipId: Self.clipID)
        #expect(outcome.plan.zones[1].rootPitch == 84)
        #expect(outcome.plan.zones[1].drumRole == nil)
        #expect(outcome.plan.zones[1].chokeGroup == nil, "an 'other' hit never joins the hats' choke")
        #expect(outcome.plan.slices[1].role == .other)
    }

    @Test("roles override the classifier with confidence 1; an index past the chop is refused")
    func overridesWin() throws {
        let plan = try Self.chromaticPlan(3)
        let timbres = [Self.timbre(.kick), Self.timbre(.kick), Self.timbre(.other)]
        let outcome = try KitSliceLayout.apply(to: plan, timbres: timbres,
                                               overrides: [1: .snare, 2: .openHat], clipId: Self.clipID)
        #expect(outcome.roles == [.kick, .snare, .openHat])
        #expect(outcome.plan.slices.map(\.confidence)[1] == 1 && outcome.plan.slices.map(\.confidence)[2] == 1)
        #expect(outcome.plan.zones.map(\.rootPitch) == [36, 38, 46])
        #expect(throws: ProjectError.self) {
            try KitSliceLayout.apply(to: plan, timbres: timbres, overrides: [3: .kick], clipId: Self.clipID)
        }
        // An engine that measured nothing cannot sort: refused, never sorted by unmeasured numbers.
        #expect(throws: ProjectError.self) {
            try KitSliceLayout.apply(to: plan, timbres: [], overrides: [:], clipId: Self.clipID)
        }
    }

    @Test("the summary sentence, including the design's own example")
    func summarySentence() {
        let example: [KitSliceRole] = Array(repeating: .kick, count: 4) + Array(repeating: .snare, count: 3)
            + Array(repeating: .closedHat, count: 8) + [.openHat] + [.other, .other]
        #expect(KitSliceLayout.summary(example)
                == "Sorted into 4 kicks, 3 snares, 8 closed hats, 1 open hat and 2 other hits.")
        #expect(KitSliceLayout.summary([.kick]) == "Sorted into 1 kick.")
        #expect(KitSliceLayout.summary([.other, .kick, .other]) == "Sorted into 1 kick and 2 other hits.")
        #expect(KitSliceLayout.summary([]) == "There were no hits to sort.")
    }

    // MARK: - Settings

    @Test("planSettings: chromatic is unchanged; kit numbers pads from 0 so the 127 ceiling cannot refuse it")
    func planSettings() throws {
        let chromatic = SliceToSamplerSettings(baseNote: 60)
        #expect(chromatic.mapping == .chromatic, "the default mapping is chromatic")
        #expect(chromatic.planSettings == chromatic)
        let kit = SliceToSamplerSettings(maxSlices: 96, mapping: .kit, roleOverrides: [0: .kick])
        #expect(kit.planSettings.baseNote == 0)
        #expect(kit.planSettings.roleOverrides == [0: .kick] && kit.planSettings.mapping == .kit)
        // 96 slices: chromatic from 36 would need note 131 and is refused; the kit plan is not.
        #expect(throws: ProjectError.self) {
            try SliceToSamplerPlan.validateSliceCount(boundaryCount: 95,
                                                      settings: SliceToSamplerSettings(maxSlices: 96,
                                                                                       includeHead: true),
                                                      clipId: Self.clipID)
        }
        try SliceToSamplerPlan.validateSliceCount(
            boundaryCount: 95,
            settings: SliceToSamplerSettings(maxSlices: 96, includeHead: true, mapping: .kit).planSettings,
            clipId: Self.clipID)
    }

    // MARK: - DrumLaneMap's sampler branch

    static func sampler(_ zones: [SamplerZone]) -> InstrumentDescriptor {
        InstrumentDescriptor(kind: .sampler, sampler: SamplerParams(zones: zones, gain: 1))
    }

    @Test("a sorted kit's rows: one per role note, the loudest of a role first, then the other hits")
    func samplerLanesFromRoles() throws {
        let plan = try Self.chromaticPlan(6)
        let timbres = [Self.timbre(.kick, peak: 0.4), Self.timbre(.snare), Self.timbre(.closedHat),
                       Self.timbre(.kick, peak: 0.9), Self.timbre(.other), Self.timbre(.openHat)]
        let kit = try KitSliceLayout.apply(to: plan, timbres: timbres, overrides: [:], clipId: Self.clipID)
        let lanes = try #require(DrumLaneMap.lanes(for: Self.sampler(kit.plan.zones)))
        #expect(lanes.map(\.note) == [36, 35, 38, 42, 46, 84])
        #expect(lanes.map(\.label) == ["Kick", "Kick 2", "Snare", "Closed Hat", "Open Hat", "Other"])
        #expect(lanes.map(\.voice) == [.kick, .kick, .snare, .closedHat, .openHat, nil])
    }

    @Test("a sampler whose zones name no drum keeps the melodic window (no rows)")
    func melodicSamplerHasNoRows() {
        let zone = SamplerZone(audioFileURL: Self.url, rootPitch: 60)
        #expect(DrumLaneMap.lanes(for: Self.sampler([zone])) == nil)
        #expect(DrumLaneMap.lanes(for: Self.sampler([])) == nil)
        var labelled = zone
        labelled.drumRole = .clap
        let lanes = DrumLaneMap.lanes(for: Self.sampler([labelled]))
        #expect(lanes?.map(\.label) == ["Clap"], "control: one role is enough to make it a drum instrument")
        #expect(lanes?.map(\.note) == [60])
    }
}
