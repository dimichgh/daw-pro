import Foundation
import Testing
@testable import DAWCore

/// Headless coverage for M7 (macro-b) mixer presets: catalog integrity
/// (unique kebab-case names, non-empty summaries, every referenced effect kind
/// + param resolvable — proven by APPLYING each preset), replace-semantics,
/// one-step undo restoring the exact prior chain, the unknown-preset error
/// listing every valid name, all three track kinds, and volume/pan left alone.
/// m26-p grew the catalog 6 → 12 and added the `bass-round` vs `bass-tight`
/// direction pin — the one test here that guards a MUSICAL claim rather than a
/// mechanical one.
@MainActor
@Suite("Mixer presets — ProjectStore")
struct MixerPresetTests {
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    private func track(_ store: ProjectStore, _ id: UUID) -> Track {
        store.tracks.first(where: { $0.id == id })!
    }

    // MARK: Catalog integrity

    @Test("catalog has the twelve v1 presets with unique kebab-case names")
    func catalogNamesUniqueKebabCase() {
        let names = MixerPresetCatalog.names
        // ORDER IS WIRE-VISIBLE (the MCP enum mirrors it), so this pins the
        // ORIGINAL six FIRST and the m26-p six APPENDED — an insertion in the
        // middle would fail here even though the set would still be right.
        #expect(names == ["drum-bus-glue", "vocal-presence", "bass-tight",
                          "master-glue", "warm-keys", "clean-boost",
                          "bass-round", "guitar-crunch", "acoustic-sparkle",
                          "horn-section", "drum-room", "lofi-tape"])
        // Unique.
        #expect(Set(names).count == names.count)
        // kebab-case: lowercase letters + digits, hyphen-separated, no edge/double hyphen.
        let pattern = try! Regex("^[a-z0-9]+(-[a-z0-9]+)*$")
        for name in names {
            #expect((try? pattern.firstMatch(in: name)) != nil, "not kebab-case: \(name)")
        }
    }

    @Test("every preset has a non-empty display name and summary, and a non-empty chain")
    func presetMetadataPresent() {
        for preset in MixerPresetCatalog.v1 {
            #expect(!preset.displayName.isEmpty)
            #expect(!preset.summary.isEmpty)
            #expect(!preset.chain.isEmpty, "\(preset.name) has an empty chain")
        }
    }

    /// The rule is "only the BUILT-IN FX pack" — never an `audioUnit`, whose
    /// availability depends on what is installed on the machine and would make a
    /// curated preset unresolvable on someone else's system.
    @Test("only built-in FX-pack kinds appear in preset chains")
    func presetsUseOnlyBuiltInFXPack() {
        // The WHOLE built-in pack, not just the kinds in use today — the rule
        // being tested is "built-in", and narrowing this set to the kinds that
        // happen to be referenced turns a rule into a snapshot (m26-p added
        // reverb + saturator and had to widen it by two).
        let allowed: Set<EffectDescriptor.Kind> = [
            .eq, .compressor, .limiter, .gain, .reverb, .delay,
            .saturator, .gate, .chorus, .bassEnhancer, .bitCrusher,
        ]
        var kindsSeen: Set<EffectDescriptor.Kind> = []
        for preset in MixerPresetCatalog.v1 {
            for effect in preset.chain {
                kindsSeen.insert(effect.kind)
                #expect(allowed.contains(effect.kind),
                        "\(preset.name) uses non-FX-pack kind \(effect.kind.rawValue)")
                // audioUnit inserts must carry a component — presets never do.
                #expect(effect.kind != .audioUnit)
            }
        }
        // ANTI-VACUITY: an empty catalog, or one whose chains were all emptied,
        // would satisfy the loop above without testing anything.
        #expect(MixerPresetCatalog.v1.count >= 12,
                "expected at least the 12 curated presets; saw \(MixerPresetCatalog.v1.count)")
        #expect(kindsSeen.count >= 5,
                "expected several distinct effect kinds across the catalog; saw \(kindsSeen)")
    }

    /// Applying EVERY preset proves the catalog→chain fidelity end to end: each
    /// referenced kind is real and its params round-trip through the store.
    @Test("applying each preset reproduces its catalog chain exactly (kind + params)")
    func applyingEachPresetMatchesCatalog() throws {
        for preset in MixerPresetCatalog.v1 {
            let store = ProjectStore()
            let t = store.addTrack(name: "Strip", kind: .audio)
            let result = try store.applyMixerPreset(trackID: t.id, presetName: preset.name)

            let applied = track(store, t.id).effects
            #expect(result.effects.map(\.id) == applied.map(\.id))
            #expect(applied.count == preset.chain.count)
            // Kinds in order.
            #expect(applied.map(\.kind) == preset.chain.map(\.kind))
            // Params identical to the catalog (resolved structs compare equal),
            // but ids are FRESH (minted per apply).
            // EVERY param surface is compared, not just the ones in use — a
            // preset using a kind this list omits would round-trip its params
            // UNVERIFIED while the loop still passed (m26-p's reverb and
            // saturator presets were exactly that gap).
            for (got, spec) in zip(applied, preset.chain) {
                #expect(got.id != spec.id, "\(preset.name) reused a template id")
                #expect(got.resolvedEQ == spec.resolvedEQ)
                #expect(got.resolvedCompressor == spec.resolvedCompressor)
                #expect(got.resolvedLimiter == spec.resolvedLimiter)
                #expect(got.resolvedGain == spec.resolvedGain)
                #expect(got.resolvedReverb == spec.resolvedReverb)
                #expect(got.resolvedDelay == spec.resolvedDelay)
                #expect(got.resolvedSaturator == spec.resolvedSaturator)
                #expect(got.resolvedGate == spec.resolvedGate)
                #expect(got.resolvedChorus == spec.resolvedChorus)
                #expect(got.resolvedBassEnhancer == spec.resolvedBassEnhancer)
                #expect(got.isBypassed == false)
            }
            // Undo label carries the display name.
            #expect(store.undoLabel == "Apply Preset '\(preset.displayName)'")
        }
    }

    @Test("clean-boost is a single gain effect at +3 dB")
    func cleanBoostIsPlusThreeDbGain() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Keys", kind: .audio)
        try store.applyMixerPreset(trackID: t.id, presetName: "clean-boost")
        let chain = track(store, t.id).effects
        #expect(chain.count == 1)
        #expect(chain.first?.kind == .gain)
        // +3 dB == 10^(3/20) linear.
        let expected = pow(10.0, 3.0 / 20.0)
        #expect(abs((chain.first?.resolvedGain.gainLinear ?? 0) - expected) < 1e-9)
    }

    /// ⭐ m26-p / field-report N6. `bass-round` exists ONLY as the audible
    /// OPPOSITE of `bass-tight`; if the two ever converge, the catalog has
    /// twelve names and eleven sounds and the whole fix is undone. This pins the
    /// DIRECTION of the difference rather than the literal numbers, so the
    /// presets can still be re-voiced — but not "tidied" into the same shape.
    ///
    /// ⚠️ SIGN CHECK, because it is the easy thing to get backwards: a SLOWER
    /// attack is a LARGER `attackMs`. Round's compressor must react LATER (so
    /// the note blooms) and LESS (so it is guided, not clamped).
    @Test("bass-round is the audible opposite of bass-tight: lower ratio, slower attack")
    func bassRoundIsTheOppositeOfBassTight() throws {
        let tight = try #require(MixerPresetCatalog.preset(named: "bass-tight"))
        let round = try #require(MixerPresetCatalog.preset(named: "bass-round"))

        let tightComp = try #require(tight.chain.first { $0.kind == .compressor }).resolvedCompressor
        let roundComp = try #require(round.chain.first { $0.kind == .compressor }).resolvedCompressor

        // THE TWO CLAIMS THE SUMMARY MAKES.
        #expect(roundComp.ratio < tightComp.ratio,
                """
                bass-round must compress at a LOWER ratio than bass-tight \
                (guide, not clamp)
                """)
        #expect(roundComp.attackMs > tightComp.attackMs,
                """
                bass-round must have a SLOWER (larger ms) attack than \
                bass-tight, so the note blooms before it is caught
                """)

        // The threshold is deliberately IDENTICAL: the pair differs in HOW it
        // compresses, not in how much signal it sees. That is what makes the
        // choice legible to a beginner (and to an agent reading the summaries).
        #expect(roundComp.thresholdDb == tightComp.thresholdDb)

        // And the tonal half of the inversion: tight TRIMS the low shelf,
        // round LIFTS it.
        let tightEQ = try #require(tight.chain.first { $0.kind == .eq }).resolvedEQ
        let roundEQ = try #require(round.chain.first { $0.kind == .eq }).resolvedEQ
        #expect(tightEQ.lowShelfGainDb < 0, "bass-tight trims the low shelf")
        #expect(roundEQ.lowShelfGainDb > 0, "bass-round lifts the low shelf")

        // ANTI-CLAMP: values silently clamped to a range edge would make the
        // comparison above true for the wrong reason. Both sit well inside.
        #expect(CompressorParams.ratioRange.contains(roundComp.ratio))
        #expect(CompressorParams.attackRange.contains(roundComp.attackMs))
        #expect(roundComp.ratio > CompressorParams.ratioRange.lowerBound)
        #expect(roundComp.attackMs < CompressorParams.attackRange.upperBound)

        // The summaries must tell a beginner WHICH to pick — the catalog is
        // also the agent's only guidance surface.
        #expect(round.summary.contains("bass-tight"),
                "bass-round's summary must name the preset it contrasts with")
    }

    // MARK: Replace semantics

    @Test("apply REPLACES the existing chain wholesale")
    func applyReplacesExistingChain() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Drums", kind: .audio)
        // Pre-existing chain of unrelated effects.
        _ = try store.addEffect(toTrack: t.id, kind: .reverb)
        _ = try store.addEffect(toTrack: t.id, kind: .delay)
        _ = try store.addEffect(toTrack: t.id, kind: .gate)
        #expect(track(store, t.id).effects.count == 3)

        try store.applyMixerPreset(trackID: t.id, presetName: "drum-bus-glue")
        let chain = track(store, t.id).effects
        // The reverb/delay/gate are gone; the preset's chain is all that remains.
        #expect(chain.map(\.kind) == MixerPresetCatalog.preset(named: "drum-bus-glue")!.chain.map(\.kind))
        #expect(!chain.contains { $0.kind == .reverb || $0.kind == .delay || $0.kind == .gate })
    }

    @Test("apply is ONE undo step that restores the exact prior chain")
    func undoRestoresExactPriorChain() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)
        let a = try store.addEffect(toTrack: t.id, kind: .eq)
        let b = try store.addEffect(toTrack: t.id, kind: .saturator)
        let priorIDs = [a.id, b.id]
        let priorKinds: [EffectDescriptor.Kind] = [.eq, .saturator]
        #expect(track(store, t.id).effects.map(\.id) == priorIDs)

        let depth = store.journal.undoStack.count
        try store.applyMixerPreset(trackID: t.id, presetName: "vocal-presence")
        // Exactly one new undo entry.
        #expect(store.journal.undoStack.count == depth + 1)
        #expect(track(store, t.id).effects.map(\.kind) != priorKinds)

        // A single undo restores the EXACT prior chain — same ids, same order.
        try store.undo()
        #expect(track(store, t.id).effects.map(\.id) == priorIDs)
        #expect(track(store, t.id).effects.map(\.kind) == priorKinds)
    }

    @Test("applying onto an empty chain still restores empty on undo")
    func undoFromEmptyChain() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Bass", kind: .audio)
        #expect(track(store, t.id).effects.isEmpty)
        try store.applyMixerPreset(trackID: t.id, presetName: "bass-tight")
        #expect(!track(store, t.id).effects.isEmpty)
        try store.undo()
        #expect(track(store, t.id).effects.isEmpty)
    }

    // MARK: Track kinds

    @Test("presets apply to audio, instrument, and bus tracks alike")
    func appliesToAllTrackKinds() throws {
        for kind in [TrackKind.audio, .instrument, .bus] {
            let store = ProjectStore()
            let t = store.addTrack(name: "Strip", kind: kind)
            try store.applyMixerPreset(trackID: t.id, presetName: "master-glue")
            let chain = track(store, t.id).effects
            #expect(chain.map(\.kind) == [.compressor, .limiter],
                    "master-glue failed on \(kind.rawValue)")
            #expect(track(store, t.id).kind == kind)  // track identity/kind unchanged
        }
    }

    // MARK: Balance untouched

    @Test("apply leaves volume and pan untouched")
    func volumeAndPanUntouched() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Keys", kind: .audio)
        _ = store.setTrackVolume(id: t.id, volume: 0.42)
        _ = store.setTrackPan(id: t.id, pan: -0.5)
        let volBefore = track(store, t.id).volume
        let panBefore = track(store, t.id).pan

        try store.applyMixerPreset(trackID: t.id, presetName: "warm-keys")
        #expect(track(store, t.id).volume == volBefore)
        #expect(track(store, t.id).pan == panBefore)
    }

    // MARK: Errors

    @Test("unknown track throws trackNotFound and changes nothing")
    func unknownTrackThrows() {
        let store = ProjectStore()
        let ghost = UUID()
        let depth = store.journal.undoStack.count
        let error = projectError { _ = try store.applyMixerPreset(trackID: ghost, presetName: "warm-keys") }
        guard case .trackNotFound(let id) = error else {
            Issue.record("expected trackNotFound, got \(String(describing: error))"); return
        }
        #expect(id == ghost)
        #expect(store.journal.undoStack.count == depth)
    }

    @Test("unknown preset error lists every valid preset name and changes nothing")
    func unknownPresetListsAllNames() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)
        _ = try store.addEffect(toTrack: t.id, kind: .eq)  // pre-existing chain must survive
        let depth = store.journal.undoStack.count

        let error = projectError { _ = try store.applyMixerPreset(trackID: t.id, presetName: "does-not-exist") }
        guard case .mixerPresetNotFound(let message) = error else {
            Issue.record("expected mixerPresetNotFound, got \(String(describing: error))"); return
        }
        for name in MixerPresetCatalog.names {
            #expect(message.contains(name), "error omits '\(name)': \(message)")
        }
        // Nothing changed: the pre-existing chain and undo depth are intact.
        #expect(track(store, t.id).effects.map(\.kind) == [.eq])
        #expect(store.journal.undoStack.count == depth)
    }
}
