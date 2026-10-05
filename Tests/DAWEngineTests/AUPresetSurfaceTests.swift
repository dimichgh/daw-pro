import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// Hosted-AU PRESET surface (m23-cw): list/load against REAL system AUs.
///
/// Two fixtures, chosen because they are the two SHAPES this surface has to
/// answer for, both MEASURED on this machine before the code was written:
///   • AUMatrixReverb ('aufx mrev appl') — 13 factory presets, the populated
///     case, and the one whose presets are audibly different from each other;
///   • AUDelay ('aufx dely appl') — `factoryPresets` is nil, the EMPTY case,
///     which is the MAJORITY of Apple's built-ins (15 of 23).
/// No third-party AUv2 appears here by policy (`track_set_instrument` with one
/// wedges the main actor for minutes).
///
/// Preset COUNTS and NAMES are read at test time, never hard-coded — the
/// parameter suite's stance. What is pinned is behaviour: that a load takes,
/// that a refusal changes nothing, that the sound actually moves, and that the
/// result survives the save-time state capture. All control-plane: no hardware
/// start, no render thread.
@MainActor
@Suite("Hosted-AU preset surface", .serialized)
struct AUPresetSurfaceTests {
    private static let matrixReverb = AudioUnitComponentID(
        type: "aufx", subType: "mrev", manufacturer: "appl")
    private static let delay = AudioUnitComponentID(
        type: "aufx", subType: "dely", manufacturer: "appl")

    /// An AudioEngine whose registry hosts one ready insert of `component`.
    private func preparedEffect(_ component: AudioUnitComponentID,
                                stateData: Data? = nil)
        async throws -> (engine: AudioEngine, effectID: UUID) {
        let engine = AudioEngine()
        let effectID = UUID()
        await engine.auRegistry.prepareEffect(
            effectID: effectID,
            config: AudioUnitConfig(component: component, stateData: stateData),
            sampleRate: 48_000)
        #expect(engine.auRegistry.effectStatus[effectID] == .ready)
        return (engine, effectID)
    }

    // MARK: - Listing

    @Test("AUMatrixReverb lists real factory presets with distinct non-negative numbers")
    func listPopulatedUnit() async throws {
        let (engine, effectID) = try await preparedEffect(Self.matrixReverb)
        let list = try #require(try engine.listHostedAUPresets(.effect(effectID: effectID)))
        print("[measured] AUMatrixReverb: hasFactoryPresets \(list.hasFactoryPresets), "
              + "factory \(list.factoryPresets.count), user \(list.userPresets.count), "
              + "supportsUserPresets \(list.supportsUserPresets), "
              + "current \(list.currentPreset.map { "\($0.number) '\($0.name)' \($0.source.rawValue)" } ?? "nil")")
        print("[measured] names: "
              + list.factoryPresets.map { "\($0.number):\($0.name)" }.joined(separator: ", "))

        #expect(list.hasFactoryPresets)
        #expect(!list.factoryPresets.isEmpty)
        // Apple's contract: factory preset numbers are >= 0, and they identify
        // a preset, so they must not repeat.
        for preset in list.factoryPresets {
            #expect(preset.number >= 0, "factory preset \(preset.number) is negative")
            #expect(!preset.name.isEmpty)
        }
        let numbers = list.factoryPresets.map(\.number)
        #expect(Set(numbers).count == numbers.count, "factory preset numbers repeat")
        // User presets, whatever the unit reports, must obey the sign rule.
        for preset in list.userPresets {
            #expect(preset.number < 0, "user preset \(preset.number) is not negative")
        }
        // Whatever it reports as current must be CLASSIFIED consistently with
        // the lists we just received — the source field is derived, and this
        // is the assertion that it is derived from the right thing.
        if let current = list.currentPreset {
            switch current.source {
            case .factory:
                #expect(numbers.contains(current.number))
            case .user:
                #expect(list.userPresets.map(\.number).contains(current.number))
            case .unlisted:
                #expect(!numbers.contains(current.number))
                #expect(!list.userPresets.map(\.number).contains(current.number))
            }
        }
    }

    @Test("an AU with NO presets answers cleanly — empty lists, hasFactoryPresets:false, never an error")
    func listEmptyUnitIsSuccess() async throws {
        let (engine, effectID) = try await preparedEffect(Self.delay)
        let list = try #require(try engine.listHostedAUPresets(.effect(effectID: effectID)))
        print("[measured] AUDelay: hasFactoryPresets \(list.hasFactoryPresets), "
              + "factory \(list.factoryPresets.count), user \(list.userPresets.count), "
              + "current \(list.currentPreset.map { "\($0.number) '\($0.name)' \($0.source.rawValue)" } ?? "nil")")
        // The whole point: SUCCESS with empty lists, the
        // `hasParameterTree: false` precedent.
        #expect(!list.hasFactoryPresets)
        #expect(list.factoryPresets.isEmpty)
        #expect(list.userPresets.isEmpty)
        // A unit nobody has chosen a preset on reports -1 "Untitled". That is a
        // NEGATIVE number, which Apple's sign rule would call a user preset —
        // it is not, and `.unlisted` is the answer that says so.
        if let current = list.currentPreset {
            #expect(current.source == .unlisted,
                    "a unit with no lists at all can only report an unlisted current preset")
        }
    }

    @Test("no hosted instance: list answers nil, load throws .noHostedAU")
    func unknownTargetTaxonomy() async throws {
        let (engine, _) = try await preparedEffect(Self.delay)
        let ghost = HostedAUTarget.effect(effectID: UUID())
        #expect(try engine.listHostedAUPresets(ghost) == nil)
        #expect(throws: HostedAUPresetError.noHostedAU) {
            try engine.loadHostedAUPreset(ghost, selector: .number(0))
        }
    }

    // MARK: - Loading

    @Test("load by number: the read-back reports the requested preset, classified factory")
    func loadByNumber() async throws {
        let (engine, effectID) = try await preparedEffect(Self.matrixReverb)
        let target = HostedAUTarget.effect(effectID: effectID)
        let list = try #require(try engine.listHostedAUPresets(target))
        // A preset that is NOT the one the unit already sits on, so a no-op
        // could not masquerade as a pass.
        let wanted = try #require(list.factoryPresets.first {
            $0.number != list.currentPreset?.number
        })
        let loaded = try engine.loadHostedAUPreset(target, selector: .number(wanted.number))
        print("[measured] loaded #\(wanted.number) '\(wanted.name)' → "
              + "\(loaded.number) '\(loaded.name)' (\(loaded.source.rawValue))")
        #expect(loaded.number == wanted.number)
        #expect(loaded.source == .factory)
        // And a FRESH list agrees — the load is state on the unit, not a value
        // the call happened to return.
        let after = try #require(try engine.listHostedAUPresets(target))
        #expect(after.currentPreset?.number == wanted.number)
        #expect(after.currentPreset?.source == .factory)
    }

    @Test("load by exact name resolves to that preset's own number")
    func loadByName() async throws {
        let (engine, effectID) = try await preparedEffect(Self.matrixReverb)
        let target = HostedAUTarget.effect(effectID: effectID)
        let list = try #require(try engine.listHostedAUPresets(target))
        let wanted = try #require(list.factoryPresets.first {
            $0.number != list.currentPreset?.number
        })
        let loaded = try engine.loadHostedAUPreset(target, selector: .name(wanted.name))
        print("[measured] loaded by name '\(wanted.name)' → #\(loaded.number)")
        #expect(loaded.number == wanted.number)
        #expect(loaded.name == wanted.name)
    }

    @Test("the unit's own name wins: a load echoes the READ-BACK, not the request")
    func readBackIsTheUnitsAnswer() async throws {
        let (engine, effectID) = try await preparedEffect(Self.matrixReverb)
        let target = HostedAUTarget.effect(effectID: effectID)
        let list = try #require(try engine.listHostedAUPresets(target))
        let wanted = try #require(list.factoryPresets.first)
        let loaded = try engine.loadHostedAUPreset(target, selector: .number(wanted.number))
        // MEASURED before this surface existed: assigning a preset NUMBER with
        // a wrong name read back with the unit's own name. So the name in the
        // result is the unit's, and it must match its own list entry.
        #expect(loaded.name == wanted.name)
    }

    // MARK: - Refusals (each one must change NOTHING)

    @Test("an unknown preset number is refused BEFORE the unit is touched — current preset unmoved")
    func unknownNumberChangesNothing() async throws {
        let (engine, effectID) = try await preparedEffect(Self.matrixReverb)
        let target = HostedAUTarget.effect(effectID: effectID)
        let list = try #require(try engine.listHostedAUPresets(target))
        // Land on a known preset first, so "unchanged" is a specific claim.
        let anchor = try #require(list.factoryPresets.last)
        _ = try engine.loadHostedAUPreset(target, selector: .number(anchor.number))
        let paramsBefore = try Self.parameterValues(engine, target)

        // 999_999 is absent by construction — asserted, not assumed.
        let absent = 999_999
        #expect(!list.factoryPresets.map(\.number).contains(absent))
        var refused = false
        do {
            _ = try engine.loadHostedAUPreset(target, selector: .number(absent))
        } catch let error as HostedAUPresetError {
            refused = true
            guard case .unknownPresetNumber(let number, let available) = error else {
                Issue.record("wrong refusal: \(error)")
                return
            }
            #expect(number == absent)
            #expect(available == list.factoryPresets.map(\.number) + list.userPresets.map(\.number))
            print("[measured] refusal text: \(error.localizedDescription)")
        }
        #expect(refused, "an absent preset number must refuse, never silently no-op")

        // THE POINT OF THIS TEST. Assigning an unrecognised preset to a live
        // AU is a SILENT NO-OP (measured) — so the only way to know our guard
        // ran BEFORE the assignment, rather than after a harmless one, is that
        // the unit is provably untouched.
        let after = try #require(try engine.listHostedAUPresets(target))
        #expect(after.currentPreset?.number == anchor.number,
                "the refused load moved the current preset")
        #expect(try Self.parameterValues(engine, target) == paramsBefore,
                "the refused load moved parameter values")
    }

    @Test("an unknown preset name is refused and lists the names the unit does have")
    func unknownNameRefuses() async throws {
        let (engine, effectID) = try await preparedEffect(Self.matrixReverb)
        let target = HostedAUTarget.effect(effectID: effectID)
        let list = try #require(try engine.listHostedAUPresets(target))
        let absent = "no preset is called this — m23-cw"
        #expect(!list.factoryPresets.map(\.name).contains(absent))
        do {
            _ = try engine.loadHostedAUPreset(target, selector: .name(absent))
            Issue.record("an absent preset name must refuse")
        } catch let error as HostedAUPresetError {
            guard case .unknownPresetName(let name, _) = error else {
                Issue.record("wrong refusal: \(error)")
                return
            }
            #expect(name == absent)
            let text = try #require(error.errorDescription)
            // The refusal has to be actionable: it names the verb to call.
            #expect(text.contains("au.listPresets"))
        }
    }

    @Test("case-insensitive fallback: a differently-cased name still resolves")
    func caseInsensitiveFallback() async throws {
        let (engine, effectID) = try await preparedEffect(Self.matrixReverb)
        let target = HostedAUTarget.effect(effectID: effectID)
        let list = try #require(try engine.listHostedAUPresets(target))
        let wanted = try #require(list.factoryPresets.first { $0.name != $0.name.uppercased() })
        // Only meaningful if the upper-cased form is NOT itself a real preset
        // name (otherwise this would be testing the exact path).
        let shouted = wanted.name.uppercased()
        #expect(!list.factoryPresets.map(\.name).contains(shouted))
        let loaded = try engine.loadHostedAUPreset(target, selector: .name(shouted))
        print("[measured] '\(shouted)' resolved case-insensitively to #\(loaded.number) '\(loaded.name)'")
        #expect(loaded.number == wanted.number)
    }

    @Test("a unit with no presets refuses a load with .noPresets and stays put")
    func loadOnPresetlessUnit() async throws {
        let (engine, effectID) = try await preparedEffect(Self.delay)
        let target = HostedAUTarget.effect(effectID: effectID)
        let before = try Self.parameterValues(engine, target)
        #expect(throws: HostedAUPresetError.noPresets) {
            try engine.loadHostedAUPreset(target, selector: .number(0))
        }
        #expect(throws: HostedAUPresetError.noPresets) {
            try engine.loadHostedAUPreset(target, selector: .name("anything"))
        }
        #expect(try Self.parameterValues(engine, target) == before)
        // The refusal must point somewhere useful rather than dead-ending.
        let text = try #require(HostedAUPresetError.noPresets.errorDescription)
        #expect(text.contains("au.setParam"))
        #expect(text.contains("plugin.openUI"))
    }

    // MARK: - The load is REAL: parameters move, and the sound moves

    @Test("loading a preset moves the unit's actual parameter values")
    func loadMovesParameters() async throws {
        let (engine, effectID) = try await preparedEffect(Self.matrixReverb)
        let target = HostedAUTarget.effect(effectID: effectID)
        let list = try #require(try engine.listHostedAUPresets(target))
        let first = try #require(list.factoryPresets.first)
        let last = try #require(list.factoryPresets.last)
        #expect(first.number != last.number)

        _ = try engine.loadHostedAUPreset(target, selector: .number(first.number))
        let a = try Self.parameterValues(engine, target)
        _ = try engine.loadHostedAUPreset(target, selector: .number(last.number))
        let b = try Self.parameterValues(engine, target)
        print("[measured] '\(first.name)' vs '\(last.name)': "
              + "\(zip(a, b).filter { $0 != $1 }.count) of \(a.count) parameters differ")
        #expect(a != b, "two different presets produced identical parameter values")
    }

    @Test("audible truth: two reverb presets render measurably different tails")
    func presetsRenderDifferently() async throws {
        let engine = AudioEngine()
        let effectID = UUID()
        let config = AudioUnitConfig(component: Self.matrixReverb)
        await engine.auRegistry.prepareEffect(effectID: effectID, config: config,
                                              sampleRate: 48_000)
        #expect(engine.auRegistry.effectStatus[effectID] == .ready)
        let target = HostedAUTarget.effect(effectID: effectID)

        let list = try #require(try engine.listHostedAUPresets(target))
        // The smallest and largest spaces the unit ships, by name — and if the
        // names are not there, the first and last presets still differ.
        let small = try #require(list.factoryPresets.first { $0.name.contains("Small") }
                                 ?? list.factoryPresets.first)
        let large = try #require(list.factoryPresets.first { $0.name.contains("Cathedral") }
                                 ?? list.factoryPresets.last)
        #expect(small.number != large.number)

        let descriptor = EffectDescriptor(id: effectID, kind: .audioUnit, audioUnit: config)
        let processor = EffectChainProcessor()
        let chainState = EffectChainState(processor: processor)
        let registry = engine.auRegistry
        chainState.hostedEffectProvider = { registry.preparedEffect(forEffect: $0) }
        chainState.sync(descriptors: [descriptor], sampleRate: 48_000)
        let hosted = try #require(registry.preparedEffect(forEffect: effectID))

        func tailEnergy(preset: HostedAUPresetInfo) throws -> Double {
            _ = try engine.loadHostedAUPreset(target, selector: .number(preset.number))
            hosted.auAudioUnit.reset()            // a clean tail, not the last one's
            let quantum = 4_096
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000,
                                                    channels: 2))
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
            buffer.frameLength = AVAudioFrameCount(quantum)
            let left = buffer.floatChannelData![0]
            let right = buffer.floatChannelData![1]
            var energy = 0.0
            // ~1.7 s of tail after a single impulse: long enough that a small
            // room has decayed and a cathedral has not.
            for index in 0..<20 {
                memset(left, 0, quantum * MemoryLayout<Float>.stride)
                memset(right, 0, quantum * MemoryLayout<Float>.stride)
                if index == 0 { left[0] = 1; right[0] = 1 }
                processor.process(bufferList: buffer.mutableAudioBufferList,
                                  frameCount: quantum)
                // Skip the first two quanta (direct sound + early reflections);
                // the LATE tail is where the rooms differ.
                if index >= 2 {
                    for frame in 0..<quantum {
                        let sample = Double(left[frame])
                        #expect(sample.isFinite, "non-finite sample in the reverb tail")
                        energy += sample * sample
                    }
                }
            }
            #expect(hosted.lastRenderError == nil)
            return energy
        }

        let smallEnergy = try tailEnergy(preset: small)
        let largeEnergy = try tailEnergy(preset: large)
        print("[measured] late-tail energy — '\(small.name)' \(smallEnergy) vs "
              + "'\(large.name)' \(largeEnergy)")
        // Both must actually produce a tail (a silent render would make any
        // ratio claim meaningless).
        #expect(smallEnergy > 0)
        #expect(largeEnergy > 0)
        // And the two presets must be audibly different: the bigger space
        // holds clearly more late energy. 2x is far inside the measured gap
        // and leaves room for AU revisions.
        #expect(largeEnergy > smallEnergy * 2,
                "'\(large.name)' should hold much more late energy than '\(small.name)'")
    }

    // MARK: - Composition with the save-time state capture (the m23-bx-1 law)

    @Test("a loaded preset reaches fullStateForDocument and survives a save/restore round trip")
    func loadedPresetSurvivesStateCapture() async throws {
        let (engine, effectID) = try await preparedEffect(Self.matrixReverb)
        let target = HostedAUTarget.effect(effectID: effectID)
        let list = try #require(try engine.listHostedAUPresets(target))
        let first = try #require(list.factoryPresets.first)
        let wanted = try #require(list.factoryPresets.last)
        #expect(first.number != wanted.number)

        // Anchor, capture, load, capture again.
        _ = try engine.loadHostedAUPreset(target, selector: .number(first.number))
        let stateBefore = try #require(engine.effectState(forEffect: effectID))
        _ = try engine.loadHostedAUPreset(target, selector: .number(wanted.number))
        let stateAfter = try #require(engine.effectState(forEffect: effectID))
        let expected = try Self.parameterValues(engine, target)

        print("[measured] effectState before \(stateBefore.count) B, after \(stateAfter.count) B, "
              + "changed \(stateBefore != stateAfter)")
        // LEG 1 — the preset load is VISIBLE to the save path. This is the
        // whole reason `au.loadPreset` may write nothing to the model: the
        // existing `tracksWithLiveAudioUnitState()` capture reads exactly
        // these bytes, so if they did not move, the preset would not persist.
        #expect(stateBefore != stateAfter,
                "the preset load never reached fullStateForDocument — save would lose it")

        // LEG 2 — restore those captured bytes into a FRESH instance, the way
        // opening a saved project does, and the sound comes back.
        let (engine2, effectID2) = try await preparedEffect(Self.matrixReverb,
                                                            stateData: stateAfter)
        let target2 = HostedAUTarget.effect(effectID: effectID2)
        let restored = try Self.parameterValues(engine2, target2)
        print("[measured] restored \(restored.count) params; match \(restored == expected)")
        #expect(restored == expected,
                "restoring the captured state did not reproduce the loaded preset's values")

        // LEG 3 — DOCUMENTING A MEASURED SURPRISE, not asserting a wish.
        // After a fullStateForDocument round trip the unit keeps the preset's
        // NAME but reports number -1: the values are exact, yet it no longer
        // claims to sit on a numbered preset. `source` is therefore
        // `.unlisted`, and that is the honest answer — anything else would be
        // us inferring a preset identity the unit declined to assert. If a
        // future macOS starts preserving the number, this expectation is where
        // that shows up.
        let restoredList = try #require(try engine2.listHostedAUPresets(target2))
        let current = try #require(restoredList.currentPreset)
        print("[measured] after round trip the unit reports "
              + "#\(current.number) '\(current.name)' (\(current.source.rawValue)) "
              + "— loaded was #\(wanted.number) '\(wanted.name)'")
        #expect(current.name == wanted.name, "the preset NAME should survive the round trip")
        if current.number == wanted.number {
            #expect(current.source == .factory)
        } else {
            #expect(current.source == .unlisted,
                    "a number that is in no list must classify as unlisted")
        }
    }

    /// Every parameter value of the target, in tree order — the cheapest
    /// honest "did the unit change" probe, and it reuses the shipped
    /// parameter surface rather than a second reader.
    private static func parameterValues(_ engine: AudioEngine,
                                        _ target: HostedAUTarget) throws -> [Double] {
        let page = try engine.describeHostedAUParameters(
            target, offset: 0, maxParams: 4_096, addresses: nil)
        return page?.parameters.map(\.value) ?? []
    }
}
