import Foundation

// m39-tpl-1 (docs/design/2026-09-27-multi-instrument-templates.md §5.2): the
// rules a sidechain key must obey, as ONE pure check over `Track` values.
//
// ⭐ MOVED HERE VERBATIM from `ProjectStore.setSidechain`, where they ran inline
// against the live store. The template builder has to check a template's keys
// BEFORE its tracks exist, so the rules had to become a function over values
// that `fx.setSidechain` also calls. The store keeps only what needs the live
// project: the recording guard, the edit and the reply. The refusals, their
// order and their sentences are unchanged — a golden table captured from the
// pre-move code proves it (`SidechainRulesTests`).
//
// Beside `SidechainGraph` (Sidechain.swift), whose `cyclePath` the loop rule
// reads: the graph math and the rules that use it stay one hop apart.

public enum SidechainRules {
    /// Checks keying the effect `effectID` on the track `trackID` from
    /// `sourceTrackID` (nil = clearing the key) against `tracks`, and throws
    /// the first rule it breaks, in this order:
    ///
    /// 1. the track exists (`trackNotFound`), and so does the effect on it
    ///    (`effectNotFound`);
    /// 2. the effect is a compressor or a gate (`sidechainUnsupportedEffect`) —
    ///    checked when CLEARING too;
    /// 3. with a source only: the keyed strip is an audio track or a bus
    ///    (`sidechainUnsupportedTrack`: an instrument strip has no input bus for
    ///    a key edge); the source exists (`trackNotFound`) and is not a bus
    ///    (`sidechainUnsupportedSource`); no OTHER effect on the strip is already
    ///    keyed (`sidechainOneSourcePerStrip`); and the new edge closes no
    ///    feedback loop, a strip keying itself included
    ///    (`sidechainWouldCreateCycle`, naming the loop).
    ///
    /// ⚠️ The ORDER is part of the contract: an agent reads the first refusal,
    /// and `fx.setSidechain` has always refused in exactly this order.
    public static func check(keying trackID: UUID, effect effectID: UUID,
                             from sourceTrackID: UUID?, in tracks: [Track]) throws {
        guard let ti = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard let ei = tracks[ti].effects.firstIndex(where: { $0.id == effectID }) else {
            throw ProjectError.effectNotFound(effectID)
        }
        let kind = tracks[ti].effects[ei].kind
        guard kind == .compressor || kind == .gate else {
            throw ProjectError.sidechainUnsupportedEffect(kind)
        }
        if let sourceTrackID {
            // Destination strip must physically own a ChainHostAU insert
            // point (audio/bus sandwich) — instrument strips walk their chain
            // inside the source node, which has no input bus for a key edge.
            guard tracks[ti].kind == .audio || tracks[ti].kind == .bus else {
                throw ProjectError.sidechainUnsupportedTrack(tracks[ti].kind)
            }
            guard let si = tracks.firstIndex(where: { $0.id == sourceTrackID }) else {
                throw ProjectError.trackNotFound(sourceTrackID)
            }
            guard tracks[si].kind != .bus else {
                throw ProjectError.sidechainUnsupportedSource(
                    "'\(tracks[si].name)' is a bus — bus key sources are deferred in v1; key from a source track feeding it instead")
            }
            // One key input per strip (v1): a DIFFERENT effect already keyed
            // on this strip rejects; re-keying the same effect is fine.
            if let taken = tracks[ti].effects.first(where: {
                $0.id != effectID && $0.sidechainSourceTrackID != nil
            }) {
                throw ProjectError.sidechainOneSourcePerStrip(
                    "strip '\(tracks[ti].name)' already has a keyed \(taken.kind.rawValue) (effect \(taken.id.uuidString)) — one sidechain key per strip in v1; clear it first")
            }
            // Cycle validation BEFORE the edit commits: the new key edge
            // source → destination must not close an existing signal path
            // destination → … → source (AVAudioEngine graph cycles are
            // undefined behavior; rejected here, never discovered there).
            if let cycle = SidechainGraph.cyclePath(
                ifKeying: trackID, from: sourceTrackID, tracks: tracks) {
                let names = cycle.map { id in
                    tracks.first(where: { $0.id == id })?.name ?? id.uuidString
                }
                let sourceName = tracks[si].name
                // `names` runs destination → … → source; the new key edge
                // source → destination closes it — show the full loop.
                let path = (names + [tracks[ti].name]).joined(separator: " → ")
                throw ProjectError.sidechainWouldCreateCycle(
                    trackID == sourceTrackID
                        ? "a strip cannot key itself — '\(sourceName)' is the keyed strip"
                        : "sidechain would create a feedback cycle: '\(tracks[ti].name)' already feeds '\(sourceName)' (\(path)) — keying it from '\(sourceName)' closes the loop")
            }
        }
    }
}
