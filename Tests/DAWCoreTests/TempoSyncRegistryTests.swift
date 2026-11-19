import Foundation
import Testing
@testable import DAWCore

/// m39-c — the ONE tempo-sync home (`Sources/DAWCore/TempoSync.swift`).
///
/// What these pin:
/// - the registry's shape (one entry per kind; every control-plane param is a
///   real spec param marked `.refused`);
/// - the CENSUS: every param the registry calls control-plane-only is refused
///   as an automation lane AND classified `controlPlaneOnly` by the modulation
///   rules, while the kind's other params stay automatable;
/// - the resolver keeps the m22-f contract (bit-exact delay math, idempotent,
///   no copy when nothing is synced) and `DelayTempoSync` forwards to it;
/// - the shared division → rate kernel a synced LFO would use;
/// - the delay's `controlPlaneOnly` refusal text, byte for byte;
/// - a SITE PIN, at ZERO, on hand-named `.delay` + `"sync"`/`"division"`
///   checks outside the home.
///
/// Nonisolated: everything here is pure value code (no store, no engine).
@Suite("m39-c tempo-sync registry — one home, census, resolver contract")
struct TempoSyncRegistryTests {

    private func track(with kind: EffectDescriptor.Kind) -> (Track, EffectDescriptor) {
        let effect = EffectDescriptor(kind: kind)
        return (Track(name: "Census", kind: .audio, effects: [effect]), effect)
    }

    // MARK: - The registry

    @Test("the registry: one entry per kind; the delay registers sync and division")
    func registryShape() {
        let kinds = TempoSync.effectRegistrations.map(\.kind)
        #expect(!kinds.isEmpty, "the registry is empty: nothing would ever be tempo-synced")
        #expect(Set(kinds).count == kinds.count, "a kind is registered twice: \(kinds)")
        let delay = TempoSync.registration(for: .delay)
        #expect(delay?.controlPlaneParams == ["sync", "division"])
        #expect(TempoSync.isControlPlaneOnly(kind: .delay, paramName: "sync"))
        #expect(TempoSync.isControlPlaneOnly(kind: .delay, paramName: "division"))
        // The delay's render params are NOT control-plane-only (the positive
        // control for the two above: the predicate can answer false).
        #expect(!TempoSync.isControlPlaneOnly(kind: .delay, paramName: "timeMs"))
        // A kind with no registration has no control-plane params at all.
        for kind in EffectDescriptor.Kind.allCases where TempoSync.registration(for: kind) == nil {
            for spec in EffectParamSpec.specs(for: kind) {
                #expect(!TempoSync.isControlPlaneOnly(kind: kind, paramName: spec.name),
                        "\(kind.rawValue).\(spec.name) is control-plane-only without a registration")
            }
        }
    }

    @Test("every control-plane param is a real spec param marked modulatable: .refused")
    func controlPlaneParamsAreRealRefusedSpecs() {
        var checked = 0
        for registration in TempoSync.effectRegistrations {
            let specs = EffectParamSpec.specs(for: registration.kind)
            for name in registration.controlPlaneParams {
                let spec = specs.first { $0.name == name }
                #expect(spec != nil, "\(registration.kind.rawValue).\(name) is not in the spec table")
                #expect(spec?.modulatable == .refused,
                        "\(registration.kind.rawValue).\(name) must be modulatable: .refused")
                checked += 1
            }
        }
        #expect(checked >= 2, "census checked \(checked) params")
    }

    // MARK: - The census (lane refusal + modulation reason)

    @Test("CENSUS: every control-plane param is refused as a lane; the kind's other params are not")
    func everyControlPlaneParamIsRefusedAsALane() {
        var refused = 0
        var accepted = 0
        for registration in TempoSync.effectRegistrations {
            let (strip, effect) = track(with: registration.kind)
            for spec in EffectParamSpec.specs(for: registration.kind) {
                let range = AutomationTarget.effectParam(effectID: effect.id, paramName: spec.name)
                    .valueRange(in: strip)
                if registration.controlPlaneParams.contains(spec.name) {
                    #expect(range == nil,
                            "\(registration.kind.rawValue).\(spec.name) is control-plane-only but a lane resolves")
                    refused += 1
                } else if range != nil {
                    accepted += 1
                }
            }
        }
        print("[measured] m39-c lane census: \(refused) refused, \(accepted) accepted")
        #expect(refused >= 2)
        // Positive control: the refusal is not "refuse everything".
        #expect(accepted >= 5, "only \(accepted) render params resolve as lanes")
    }

    @Test("CENSUS: the modulation rules refuse every control-plane param as controlPlaneOnly")
    func modulationRulesAgreeWithTheRegistry() {
        var checked = 0
        for registration in TempoSync.effectRegistrations {
            let (strip, effect) = track(with: registration.kind)
            for name in registration.controlPlaneParams {
                let target = AutomationTarget.effectParam(effectID: effect.id, paramName: name)
                do {
                    _ = try ModulationRules.validate(target: target, on: .track(strip))
                    Issue.record("\(registration.kind.rawValue).\(name) was accepted as a modulation target")
                } catch let ModulationError.modulationTargetUnsupported(_, reason, _) {
                    // `ModulationRules.validate` picks this reason through
                    // `TempoSync.isControlPlaneOnly`; a hand-named kind check
                    // there would give a second registered kind `discrete`.
                    #expect(reason == .controlPlaneOnly,
                            "\(registration.kind.rawValue).\(name) refused as \(reason.rawValue)")
                } catch {
                    Issue.record("\(registration.kind.rawValue).\(name): unexpected \(error)")
                }
                checked += 1
            }
        }
        #expect(checked >= 2)
    }

    /// The delay's refusal text as it has gone out on the wire since m39-e. An
    /// agent may match on it, so it is pinned BYTE FOR BYTE (the FXCommand
    /// test pins only the reason token).
    static let delayControlPlaneOnlyDetail =
        "this parameter is resolved off the render thread (the effective delay time derives "
        + "from the tempo on the main actor), so a modulator could not reach it. "
        + "Automation refuses it too."

    @Test("the delay's controlPlaneOnly refusal text is byte-identical on the wire (detail + message)")
    func delayControlPlaneOnlyTextIsPinned() {
        let (strip, effect) = track(with: .delay)
        var checked = 0
        for name in ["sync", "division"] {
            let target = AutomationTarget.effectParam(effectID: effect.id, paramName: name)
            do {
                _ = try ModulationRules.validate(target: target, on: .track(strip))
                Issue.record("delay.\(name) was accepted as a modulation target")
            } catch let error as ModulationError {
                guard case let .modulationTargetUnsupported(wireTarget, reason, detail) = error else {
                    Issue.record("delay.\(name): unexpected \(error)")
                    continue
                }
                #expect(wireTarget == "delay.\(name)")
                #expect(reason == .controlPlaneOnly)
                #expect(detail == Self.delayControlPlaneOnlyDetail, "delay.\(name) detail drifted: \(detail)")
                #expect(error.errorDescription
                        == "cannot modulate delay.\(name) (controlPlaneOnly): "
                           + Self.delayControlPlaneOnlyDetail)
                checked += 1
            } catch {
                Issue.record("delay.\(name): unexpected \(error)")
            }
        }
        #expect(checked == 2)
        // Positive control: a DISCRETE refusal on the same insert still gets
        // the other sentence (the pin can see a different string).
        let pingPong = AutomationTarget.effectParam(effectID: effect.id, paramName: "pingPong")
        let pingPongSpec = EffectParamSpec.specs(for: .delay).first { $0.name == "pingPong" }
        #expect(pingPongSpec?.modulatable == .refused, "the control needs a refused, non-tempo param")
        do {
            _ = try ModulationRules.validate(target: pingPong, on: .track(strip))
            Issue.record("delay.pingPong was accepted as a modulation target")
        } catch let ModulationError.modulationTargetUnsupported(_, reason, detail) {
            #expect(reason == .discrete)
            #expect(detail != Self.delayControlPlaneOnlyDetail)
        } catch {
            Issue.record("delay.pingPong: unexpected \(error)")
        }
    }

    // MARK: - The resolver contract

    @Test("the registry resolve is the m22-f delay math, bit-exact, at every division and tempo")
    func resolveMatchesDelayMath() {
        for division in NoteDivision.allCases {
            for bpm in [30.0, 60, 90, 97, 120, 174, 300] {
                let params = DelayParams(timeMs: 350, feedback: 0.4, mix: 0.5,
                                         sync: true, division: division)
                let effect = EffectDescriptor(kind: .delay, delay: params)
                let resolved = TempoSync.resolved(effect, tempoBPM: bpm)
                #expect(resolved.delay?.timeMs == params.effectiveTimeMs(atTempoBPM: bpm),
                        "\(division.rawValue) @ \(bpm)")
                // Everything but timeMs rides along unchanged.
                var expected = effect
                expected.delay?.timeMs = params.effectiveTimeMs(atTempoBPM: bpm)
                #expect(resolved == expected)
                // The m22-f name forwards to the same answer.
                #expect(DelayTempoSync.resolved(effect, tempoBPM: bpm) == resolved)
            }
        }
    }

    @Test("idempotent: re-resolving at a new tempo is exactly the recompute")
    func resolveIsIdempotent() {
        let effect = EffectDescriptor(kind: .delay,
                                      delay: DelayParams(timeMs: 350, sync: true, division: .eighthDotted))
        var strip = Track(name: "Echo", kind: .audio, effects: [effect, EffectDescriptor(kind: .eq)])
        strip.effects.append(EffectDescriptor(kind: .delay, delay: DelayParams(timeMs: 222)))
        let at120 = TempoSync.resolved(tracks: [strip], tempoBPM: 120)
        let at90 = TempoSync.resolved(tracks: at120, tempoBPM: 90)
        #expect(at90 == TempoSync.resolved(tracks: [strip], tempoBPM: 90))
        #expect(TempoSync.resolved(tracks: at90, tempoBPM: 120) == at120)
        // 1/8d: 375 ms @ 120, 500 ms @ 90; the free-running 222 ms never moves.
        #expect(at120[0].effects[0].delay?.timeMs == 375)
        #expect(at90[0].effects[0].delay?.timeMs == 500)
        #expect(at90[0].effects[2].delay?.timeMs == 222)
        #expect(at90[0].effects[1] == strip.effects[1])
        #expect(DelayTempoSync.resolved(tracks: [strip], tempoBPM: 90) == at90)
    }

    @Test("nothing synced: the INPUT comes back with the same storage (no copy)")
    func unsyncedInputIsReturnedWithoutACopy() {
        let effects = [EffectDescriptor(kind: .eq),
                       EffectDescriptor(kind: .delay, delay: DelayParams(timeMs: 350)),
                       EffectDescriptor(kind: .delay,
                                        delay: DelayParams(timeMs: 350, sync: false, division: .quarter))]
        #expect(!TempoSync.containsSynced(effects: effects))
        let out = TempoSync.resolved(effects: effects, tempoBPM: 90)
        let sameStorage = effects.withUnsafeBufferPointer { a in
            out.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
        }
        #expect(sameStorage, "an unsynced chain was copied")
        let tracks = [Track(name: "Dry", kind: .audio, effects: effects)]
        let outTracks = TempoSync.resolved(tracks: tracks, tempoBPM: 90)
        let sameTrackStorage = tracks.withUnsafeBufferPointer { a in
            outTracks.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
        }
        #expect(sameTrackStorage, "an unsynced track list was copied")
        // Positive control: a synced chain IS rebuilt (the probe can say no).
        var synced = effects
        synced.append(EffectDescriptor(kind: .delay,
                                       delay: DelayParams(timeMs: 350, sync: true, division: .quarter)))
        #expect(TempoSync.containsSynced(effects: synced))
        #expect(DelayTempoSync.containsSyncedDelay(effects: synced))
        let rebuilt = TempoSync.resolved(effects: synced, tempoBPM: 90)
        let rebuiltShares = synced.withUnsafeBufferPointer { a in
            rebuilt.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
        }
        #expect(!rebuiltShares)
    }

    // MARK: - The shared kernel

    @Test("rateHz: a division as cycles per second, the inverse of its duration")
    func rateKernel() {
        #expect(TempoSync.rateHz(of: .quarter, atTempoBPM: 120) == 2)
        #expect(abs(TempoSync.rateHz(of: .eighthDotted, atTempoBPM: 120) - 8.0 / 3) < 1e-12)
        #expect(TempoSync.rateHz(of: .whole, atTempoBPM: 60) == 0.25)
        for division in NoteDivision.allCases {
            for bpm in [30.0, 97, 120, 300] {
                let product = TempoSync.rateHz(of: division, atTempoBPM: bpm)
                    * division.milliseconds(atBPM: bpm) / 1_000
                #expect(abs(product - 1) < 1e-12, "\(division.rawValue) @ \(bpm)")
            }
        }
        for bad in [0.0, -120, .nan, .infinity] {
            #expect(TempoSync.rateHz(of: .quarter, atTempoBPM: bad).isNaN, "bpm \(bad)")
        }
    }

    // MARK: - The site pin

    /// The repo root, from this file's path (the `repoSource` idiom).
    static func repoRoot() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    @Test("SITE PIN: hand-named .delay sync/division checks outside the home can only shrink")
    func handNamedDelaySyncSitesArePinned() throws {
        let root = try #require(Self.repoRoot(), "could not locate the repo from \(#filePath)")
        let sources = root.appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources,
                                                                     includingPropertiesForKeys: nil))
        // One line naming the delay kind AND a quoted sync/division param: the
        // shape of a hand-written `kind == .delay, paramName == "sync"` check.
        let pattern = try Regex(#"\.delay\b.*"(sync|division)"|"(sync|division)".*\.delay\b"#)
        // Positive controls for the PATTERN: both pre-m39-c shapes match it.
        #expect(#"if effect.kind == .delay, paramName == "sync" || paramName == "division" {"#
                    .contains(pattern))
        #expect(#"(effect.kind == .delay && (paramName == "sync" || paramName == "division"))"#
                    .contains(pattern))
        var files = 0
        var sites: [String] = []
        var registryReaders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files += 1
            let parts = url.standardizedFileURL.pathComponents
            let from = (parts.lastIndex(of: "Sources") ?? 0) + 1
            let relative = parts[from...].joined(separator: "/")
            guard relative != "DAWCore/TempoSync.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, raw) in text.components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                if line.contains(pattern) { sites.append("\(relative):\(index + 1)") }
                if line.contains("TempoSync.isControlPlaneOnly(") { registryReaders.append(relative) }
            }
        }
        print("[measured] m39-c hand-named delay sync sites over \(files) files: \(sites); "
              + "registry readers: \(registryReaders)")
        #expect(files > 100, "scanned only \(files) Swift files")
        // Positive control for the SCAN: it read the two refusals and saw them
        // ask the registry (so an empty `sites` is a finding, not a blind scan).
        #expect(Set(registryReaders) == ["DAWCore/Automation.swift", "DAWCore/ModulationRules.swift"],
                "registry readers: \(registryReaders)")
        // PINNED AT ZERO (m39-c unit 2, 2026-10-07): the last hand-named site,
        // `ModulationRules.validate`'s `controlPlaneOnly` reason, now reads
        // `TempoSync.isControlPlaneOnly`. A site here means someone hand-wrote
        // a tempo-sync kind check outside the home: register the kind in
        // `TempoSync.effectRegistrations` and read it instead.
        #expect(sites.isEmpty,
                "hand-named .delay sync/division sites outside TempoSync.swift: \(sites)")
    }
}
