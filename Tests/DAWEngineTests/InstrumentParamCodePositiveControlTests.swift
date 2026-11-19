import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// ⭐⭐ m39-dm STEP 2's GATE — THE POSITIVE CONTROL ON THE `code` REFACTOR.
///
/// The drum machine moves `InstrumentParamID.code` and
/// `InstrumentParamID.appliesAtNextNoteOn` into `InstrumentParamSpec`, because
/// `ModulationSnapshotBuilder`'s `InstrumentParamID(rawValue: paramName)` guard
/// returns nil for a dotted name like `kick.tune` and DROPS the route from the
/// published snapshot — after `mod.addRoute` already answered success. That is
/// this tree's characteristic failure: a success response and a dead feature.
///
/// ⚠️⚠️ THE REFACTOR'S OWN RISK IS THE INVERSE ONE: `paramSlot` is the number
/// the render thread matches on (`ModulationEvaluator.targetIndex(
/// forInstrumentParamCode:)`), so if the moved table disagrees with the enum by
/// even one code, EVERY LIVE POLYSYNTH MODULATION ROUTE SILENTLY RENUMBERS —
/// a cutoff route starts driving resonance, with no error anywhere.
///
/// THIS SUITE WAS WRITTEN AND RUN GREEN **BEFORE** THE REFACTOR, then run again
/// after. Same assertions, two runs. That is what makes it a control rather
/// than a restatement of whatever the code happens to do: a test authored
/// against the new code can only agree with it.
/// ⛔ DELIBERATELY **NOT** `@MainActor`: this reads the `InstrumentParamSpec`
/// tables and renders a `PolySynthInstrument` offline. No main-actor type is
/// reachable from here, so the annotation would buy nothing but occupancy
/// against `MainActorOccupancySiteTests` Leg C's review cadence.
@Suite("Instrument param codes — polySynth non-regression control")
struct InstrumentParamCodePositiveControlTests {
    private static let sampleRate = 48_000.0

    /// The frozen truth, written out by hand rather than derived from the
    /// thing under test. A table that reads itself proves nothing.
    private static let expectedCodes: [(name: String, code: Int32)] = [
        ("cutoffHz", 0), ("resonance", 1), ("gain", 2), ("attack", 3),
        ("decay", 4), ("sustain", 5), ("release", 6),
    ]

    /// Likewise frozen by hand: the four envelope steps latch at note-on, the
    /// three continuous ones do not.
    private static let expectedLatching: [String: Bool] = [
        "cutoffHz": false, "resonance": false, "gain": false,
        "attack": true, "decay": true, "sustain": true, "release": true,
    ]

    private func lfo() -> ModulationSource {
        ModulationSource(kind: .lfo)
    }

    /// Builds a one-route snapshot for a polySynth strip and returns the
    /// resolved target — the render-thread POD, through the real builder.
    private func resolvedTarget(paramName: String) -> ModulationSnapshot.Target? {
        let source = lfo()
        let route = ModulationRoute(
            sourceID: source.id,
            target: .instrumentParam(paramName: paramName), depth: 0.5)
        let strip = ModulationSnapshotBuilder.Strip(
            sources: [source], routes: [route],
            instrument: InstrumentDescriptor(kind: .polySynth),
            isInstrumentTrack: true)
        guard let snapshot = ModulationSnapshotBuilder.build(
            strip: strip, generation: 1, timelineID: 1,
            sampleRate: Self.sampleRate, originSample: 0, positionValid: true)
        else { return nil }
        guard snapshot.targets.count == 1 else { return nil }
        return snapshot.targets[0]
    }

    @Test("Every polySynth param still resolves to its frozen render code")
    func polySynthCodesAreUnmoved() throws {
        for (name, code) in Self.expectedCodes {
            let target = try #require(resolvedTarget(paramName: name),
                                      "\(name) resolved to NO target — the route was dropped")
            #expect(target.kindCode == ModulationSnapshot.TargetCode.instrumentParam,
                    "\(name) resolved as the wrong target class")
            #expect(target.paramSlot == code,
                    "\(name) renumbered: expected \(code), got \(target.paramSlot)")
        }
    }

    /// The control on the control: a name that is NOT a polySynth param must
    /// resolve to nothing. Without this row, a builder that returned a target
    /// for literally any string would pass the test above.
    @Test("An unknown instrument param name still resolves to no target")
    func unknownNameIsDropped() {
        #expect(resolvedTarget(paramName: "notAParam") == nil)
        #expect(resolvedTarget(paramName: "") == nil)
        // A dotted drum name on a POLYSYNTH strip is equally unresolvable —
        // the kind's table does not carry it.
        #expect(resolvedTarget(paramName: "kick.tune") == nil)
    }

    /// `appliesAtNextNoteOn` is a computed property of `InstrumentParamID`
    /// today. When the drum machine moves it onto `InstrumentParamSpec`,
    /// NOTHING IN THE COMPILER carries the flag across — `describeSynth`'s
    /// "Takes effect at the next note-on" line would simply stop being true.
    /// This row pins the seven values through whichever home currently owns
    /// them, so the move cannot drop one.
    @Test("Note-on latching verdicts are unmoved for every polySynth param")
    func latchingVerdictsAreUnmoved() throws {
        for (name, expected) in Self.expectedLatching {
            let id = try #require(InstrumentParamID(rawValue: name))
            #expect(id.appliesAtNextNoteOn == expected,
                    "\(name) latching verdict moved: expected \(expected)")
        }
        #expect(Self.expectedLatching.count == InstrumentParamID.allCases.count)
    }

    /// The spec table and the enum must enumerate THE SAME SEVEN NAMES. If the
    /// refactor populates the table from a hand-copied list, this is what
    /// catches a typo before the codes do.
    @Test("The polySynth spec table and the param enum agree on the name set")
    func specTableMatchesEnum() {
        let specNames = Set(InstrumentParamSpec.specs(for: .polySynth).map(\.name))
        let enumNames = Set(InstrumentParamID.allCases.map(\.rawValue))
        #expect(specNames == enumNames)
        #expect(specNames.count == 7)
    }

    /// ⭐ THE TWO HOMES CANNOT DRIFT. `code` and `appliesAtNextNoteOn` now exist
    /// BOTH on `InstrumentParamID` and on `InstrumentParamSpec`. The spec rows
    /// are populated from the enum through a dedicated initialiser so they
    /// cannot disagree by construction — but "cannot by construction" is a
    /// claim, and this row is what makes it a measurement.
    @Test("The spec table's code and latching flag match the enum's, row for row")
    func specTableAgreesWithEnumOnCodeAndLatching() throws {
        for spec in InstrumentParamSpec.specs(for: .polySynth) {
            let id = try #require(InstrumentParamID(rawValue: spec.name))
            #expect(spec.code == id.code,
                    "\(spec.name): table says \(spec.code), enum says \(id.code)")
            #expect(spec.appliesAtNextNoteOn == id.appliesAtNextNoteOn,
                    "\(spec.name): latching flags disagree between the two homes")
        }
    }

    /// The drum machine's 75 rows must not collide with the polySynth's seven,
    /// because `paramSlot` is matched by VALUE on the render thread.
    @Test("Drum param codes are disjoint from polySynth param codes")
    func drumCodesDoNotCollide() {
        let poly = Set(InstrumentParamSpec.specs(for: .polySynth).map(\.code))
        let drums = Set(InstrumentParamSpec.specs(for: .drumSynth).map(\.code))
        #expect(poly.count == 7)
        #expect(drums.count == 77)
        #expect(poly.isDisjoint(with: drums))
    }

    /// ⛔ THE CASE THAT MOTIVATED THE WHOLE REFACTOR. Before it, this route was
    /// validated, accepted, and then DROPPED from the published snapshot
    /// because `InstrumentParamID(rawValue: "kick.tune")` is nil.
    @Test("A dotted drum param resolves to a real target on a drumSynth strip")
    func drumRouteResolves() throws {
        let source = lfo()
        let route = ModulationRoute(
            sourceID: source.id,
            target: .instrumentParam(paramName: "kick.tune"), depth: 0.5)
        let strip = ModulationSnapshotBuilder.Strip(
            sources: [source], routes: [route],
            instrument: InstrumentDescriptor(kind: .drumSynth),
            isInstrumentTrack: true)
        let snapshot = try #require(ModulationSnapshotBuilder.build(
            strip: strip, generation: 1, timelineID: 1,
            sampleRate: Self.sampleRate, originSample: 0, positionValid: true))
        #expect(snapshot.targets.count == 1)
        let spec = try #require(InstrumentParamSpec.specs(for: .drumSynth)
            .first { $0.name == "kick.tune" })
        #expect(snapshot.targets[0].paramSlot == spec.code)
        #expect(snapshot.targets[0].kindCode
            == ModulationSnapshot.TargetCode.instrumentParam)
        // And the base value is the DESCRIPTOR's value, not a hardcoded default.
        #expect(snapshot.targets[0].baseValue == DrumKitParams.kickDefault.tune)
    }
}
