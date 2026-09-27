import Foundation
import Testing
@testable import DAWCore

// m39-tpl-1 — the Poly Synth's setting names moved to ONE home,
// `PolySynthParams.settingNames` (formerly DAWControl's
// `PolySynthDescription.order`), with the name → property table the template
// codec reads through (docs/design/2026-09-27-multi-instrument-templates.md §4.5,
// §5.2).
//
// The wire-side agreement (the names ARE `track.setInstrument`'s allow-list,
// and each range IS what `instrument.describeSynth` publishes) lives in
// `Tests/DAWControlTests/TrackSetTemplateWireParityTests.swift`, the one test
// target that sees both modules. This suite checks the table against the
// MODEL: every stored property is a listed name and the reverse, and every
// name round-trips through its setter and reader.

@Suite("m39-tpl-1: PolySynthParams.settingNames and its name table")
struct PolySynthSettingNamesRulesTests {
    @Test("the 24 names are exactly PolySynthParams' stored properties (a 25th field cannot arrive unlisted)")
    func namesAreTheStoredProperties() {
        let names = PolySynthParams.settingNames
        let stored = Mirror(reflecting: PolySynthParams()).children.compactMap { $0.label }
        // Positive control: Mirror sees the struct's fields.
        #expect(stored.contains("cutoffHz") && stored.count >= 24, "\(stored)")
        #expect(names.count == 24 && Set(names).count == names.count, "\(names)")
        #expect(Set(names) == Set(stored), """
            the names and the stored properties differ: unlisted \
            \(Set(stored).subtracting(names).sorted()), not stored \
            \(Set(names).subtracting(stored).sorted())
            """)
    }

    @Test("every name has a kind, and every range is the model's own")
    func everyNameHasAKind() {
        for name in PolySynthParams.settingNames {
            #expect(PolySynthParams.settingKind(named: name) != nil, "\(name)")
        }
        #expect(PolySynthParams.settingKind(named: "cutoffHz") == .number(PolySynthParams.cutoffRange))
        #expect(PolySynthParams.settingKind(named: "unisonVoices")
                == .integer(PolySynthParams.unisonVoicesRange))
        #expect(PolySynthParams.settingKind(named: "subWaveform") == .waveform)
        #expect(PolySynthParams.settingKind(named: "zzNotASetting") == nil)
        #expect(PolySynthParams.settingKind(named: "") == nil)
    }

    @Test("every number and whole-number setting round-trips through its setter and reader")
    func numbersRoundTrip() {
        var checked = 0
        for name in PolySynthParams.settingNames {
            var params = PolySynthParams()
            switch PolySynthParams.settingKind(named: name) {
            case .number(let range):
                let value = range.lowerBound + (range.upperBound - range.lowerBound) * 0.37
                let wrote = params.setSetting(name, number: value)
                #expect(wrote, "\(name)")
                #expect(params.settingNumber(name) == value, "\(name)")
                checked += 1
            case .integer(let range):
                let value = range.upperBound
                let wrote = params.setSetting(name, number: Double(value))
                #expect(wrote, "\(name)")
                #expect(params.settingNumber(name) == Double(value), "\(name)")
                // A fraction is refused and changes nothing.
                let before = params
                let wroteFraction = params.setSetting(name, number: Double(value) - 0.5)
                #expect(!wroteFraction, "\(name)")
                #expect(params == before, "\(name)")
                checked += 1
            case .waveform:
                let wroteNumber = params.setSetting(name, number: 1)
                #expect(!wroteNumber, "\(name) takes a waveform")
                let wroteWaveform = params.setSetting(name, waveform: .square)
                #expect(wroteWaveform, "\(name)")
                #expect(params.settingWaveform(name) == .square, "\(name)")
                checked += 1
            case nil:
                Issue.record("\(name) has no kind")
            }
        }
        #expect(checked == 24)
        var params = PolySynthParams()
        let before = params
        let wroteUnknown = params.setSetting("zzNotASetting", number: 1)
        let wroteWaveformOnANumber = params.setSetting("attack", waveform: .saw)
        #expect(!wroteUnknown)
        #expect(!wroteWaveformOnANumber, "attack is not a waveform")
        #expect(params == before)
    }
}
