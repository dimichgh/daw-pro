import Foundation
import Testing
@testable import DAWCore

/// Pure-value coverage for the M4 (vii-a) automation domain model: point
/// clamping + canonical ordering, equal-beat dedupe, the `value(atBeat:)`
/// evaluator (linear/hold/edges/empty), `AutomationTarget.valueRange` resolution,
/// and the flat `{type, …}` Codable round trip.
@Suite("Automation — core model")
struct AutomationCoreTests {
    @Test("a point clamps its beat to >= 0 and a lane orders points canonically")
    func pointInitClampsBeatAndOrdersCanonically() {
        let clamped = AutomationPoint(beat: -5, value: 0.3)
        #expect(clamped.beat == 0)

        let lane = AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 8, value: 1.0),
            AutomationPoint(beat: 2, value: 0.5),
            AutomationPoint(beat: 4, value: 0.7),
        ])
        #expect(lane.points.map(\.beat) == [2, 4, 8])
    }

    @Test("equal-beat points dedupe, last one wins")
    func equalBeatPointsDedupeLastWins() {
        let lane = AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 4, value: 0.2),
            AutomationPoint(beat: 4, value: 0.9),   // same beat, later → wins
            AutomationPoint(beat: 1, value: 0.1),
        ])
        #expect(lane.points.map(\.beat) == [1, 4])
        #expect(lane.points.first(where: { $0.beat == 4 })?.value == 0.9)
    }

    @Test("value(atBeat:) interpolates linear segments")
    func valueAtBeatInterpolatesLinearSegments() {
        let lane = AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 0, value: 0, curve: .linear),
            AutomationPoint(beat: 4, value: 1, curve: .linear),
        ])
        #expect(lane.value(atBeat: 0) == 0)
        #expect(lane.value(atBeat: 1) == 0.25)
        #expect(lane.value(atBeat: 2) == 0.5)
        #expect(lane.value(atBeat: 3) == 0.75)
        #expect(lane.value(atBeat: 4) == 1)
    }

    @Test("value(atBeat:) holds the edge values before the first and after the last point")
    func valueAtBeatHoldsBeforeFirstAndAfterLast() {
        let lane = AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 2, value: 0.3, curve: .linear),
            AutomationPoint(beat: 6, value: 0.8, curve: .linear),
        ])
        #expect(lane.value(atBeat: 0) == 0.3)      // before first → first value
        #expect(lane.value(atBeat: 1.5) == 0.3)
        #expect(lane.value(atBeat: 10) == 0.8)     // after last → last value
    }

    @Test("a hold segment holds until the next point, then steps")
    func holdCurveStepsAtNextPoint() {
        let lane = AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 0, value: 0.2, curve: .hold),
            AutomationPoint(beat: 4, value: 0.9, curve: .linear),
        ])
        #expect(lane.value(atBeat: 0) == 0.2)
        #expect(lane.value(atBeat: 2) == 0.2)      // held flat across the segment
        #expect(lane.value(atBeat: 3.999) == 0.2)  // still held just before the step
        #expect(lane.value(atBeat: 4) == 0.9)      // steps at the next point
    }

    @Test("an empty lane is inert — value(atBeat:) is nil")
    func emptyLaneIsInert() {
        let lane = AutomationLane(target: .volume, points: [])
        #expect(lane.value(atBeat: 0) == nil)
        #expect(lane.value(atBeat: 5) == nil)
    }

    @Test("valueRange resolves volume, pan, send level, and effect param")
    func targetValueRangeResolvesVolumePanSendAndEffectParam() {
        var track = Track(name: "Vox", kind: .audio)
        #expect(AutomationTarget.volume.valueRange(in: track) == Track.volumeRange)
        #expect(AutomationTarget.pan.valueRange(in: track) == Track.panRange)

        let send = Send(destinationBusID: UUID(), level: 0.5)
        track.sends = [send]
        #expect(AutomationTarget.sendLevel(sendID: send.id).valueRange(in: track) == Send.levelRange)
        #expect(AutomationTarget.sendLevel(sendID: UUID()).valueRange(in: track) == nil)  // unknown send

        let eq = EffectDescriptor(kind: .eq)
        track.effects = [eq]
        #expect(AutomationTarget.effectParam(effectID: eq.id, paramName: "peak1GainDb")
            .valueRange(in: track) == EQParams.gainDbRange)
        #expect(AutomationTarget.effectParam(effectID: eq.id, paramName: "lowShelfFreq")
            .valueRange(in: track) == EQParams.lowShelfFreqRange)
    }

    @Test("an unknown/empty/AU effect-param name resolves nil")
    func unknownEffectParamNameResolvesNil() {
        var track = Track(name: "Vox")
        let gain = EffectDescriptor(kind: .gain)
        track.effects = [gain]
        #expect(AutomationTarget.effectParam(effectID: gain.id, paramName: "bogus")
            .valueRange(in: track) == nil)                 // unknown name
        #expect(AutomationTarget.effectParam(effectID: gain.id, paramName: "")
            .valueRange(in: track) == nil)                 // empty name
        #expect(AutomationTarget.effectParam(effectID: UUID(), paramName: "gainLinear")
            .valueRange(in: track) == nil)                 // unknown effect id

        // An AU effect exposes no generic param surface in v0 → always nil.
        let au = EffectDescriptor(
            kind: .audioUnit,
            audioUnit: AudioUnitConfig(component: AudioUnitComponentID(
                type: "aufx", subType: "dcmp", manufacturer: "acme")))
        track.effects = [au]
        #expect(AutomationTarget.effectParam(effectID: au.id, paramName: "anything")
            .valueRange(in: track) == nil)
    }

    @Test("every AutomationTarget case round-trips through the flat {type, …} Codable shape")
    func targetCodableRoundTripsAllCases() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let sendID = UUID()
        let effectID = UUID()
        let targets: [AutomationTarget] = [
            .volume,
            .pan,
            .sendLevel(sendID: sendID),
            .effectParam(effectID: effectID, paramName: "peak1GainDb"),
        ]
        for target in targets {
            let data = try encoder.encode(target)
            let back = try decoder.decode(AutomationTarget.self, from: data)
            #expect(back == target)
        }

        // Wire-shape contract: the flat object with a `type` discriminator plus
        // the case-specific keys (sendId / effectId + param), nothing else.
        func object(_ target: AutomationTarget) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: encoder.encode(target)) as! [String: Any]
        }
        #expect(try object(.volume)["type"] as? String == "volume")
        #expect(try object(.pan)["type"] as? String == "pan")

        let sendObject = try object(.sendLevel(sendID: sendID))
        #expect(sendObject["type"] as? String == "sendLevel")
        #expect(sendObject["sendId"] as? String == sendID.uuidString)

        let fxObject = try object(.effectParam(effectID: effectID, paramName: "peak1GainDb"))
        #expect(fxObject["type"] as? String == "effectParam")
        #expect(fxObject["effectId"] as? String == effectID.uuidString)
        #expect(fxObject["param"] as? String == "peak1GainDb")
    }
}
