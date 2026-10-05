import Foundation

// m39-tpl-2 (docs/design/2026-09-27-multi-instrument-templates.md §2.4, §5.2's
// fourth row): where a track may play into and send to, as PURE functions over
// `Track` values — THE ONE HOME for these rules.
//
// `ProjectStore.setTrackOutput` (`track.setOutput`) and `ProjectStore.addSend`
// (`track.addSend`) call these after their recording guard; the template
// builder calls them on a template's tracks before those tracks exist. There is
// no other copy: the store's inline guards were DELETED when it was re-pointed
// here (m39-tpl-2a.2), so a change here changes both paths at once, and a plant
// that breaks one rule here reddens a store test AND a builder test (the lane
// log records it). The refusals, their order and their sentences are the ones
// the store had always thrown, byte for byte (`ProjectError`'s cases, which
// the wire surfaces verbatim).

public enum RoutingRules {
    /// `track.setOutput`'s rules, in the store's order:
    ///
    /// 1. the track exists (`trackNotFound`);
    /// 2. it is not a bus — a bus always plays into the master
    ///    (`busRoutingFixed`);
    /// 3. with a destination only: it exists (`trackNotFound`) and it is a bus
    ///    (`notABus`). nil = back to the master, always allowed.
    public static func checkOutput(of trackID: UUID, to busID: UUID?,
                                   in tracks: [Track]) throws {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard tracks[index].kind != .bus else { throw ProjectError.busRoutingFixed }
        if let busID {
            guard let destIndex = tracks.firstIndex(where: { $0.id == busID }) else {
                throw ProjectError.trackNotFound(busID)
            }
            guard tracks[destIndex].kind == .bus else { throw ProjectError.notABus(busID) }
        }
    }

    /// `track.addSend`'s rules, in the store's order:
    ///
    /// 1. the track exists (`trackNotFound`);
    /// 2. it is not a bus — a bus has no sends (`busRoutingFixed`);
    /// 3. the destination exists (`trackNotFound`) and is a bus (`notABus`);
    /// 4. the track does not already send to it (`duplicateSend`, which also
    ///    bounds a track's sends by the number of buses).
    public static func checkSend(from trackID: UUID, to busID: UUID,
                                 in tracks: [Track]) throws {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard tracks[index].kind != .bus else { throw ProjectError.busRoutingFixed }
        guard let destIndex = tracks.firstIndex(where: { $0.id == busID }) else {
            throw ProjectError.trackNotFound(busID)
        }
        guard tracks[destIndex].kind == .bus else { throw ProjectError.notABus(busID) }
        guard !tracks[index].sends.contains(where: { $0.destinationBusID == busID }) else {
            throw ProjectError.duplicateSend(busID)
        }
    }
}
