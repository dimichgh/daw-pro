import Foundation

/// Pure sidechain-routing domain math (m12-f, S-1) — the single source of
/// truth every consumer reads so the engine edge, the PDC planner, and the
/// stem-pass transform can never disagree about which strips key which
/// (design docs/research/design-m11f-sidechain.md §4-A/§6.3: "passTracks
/// derives key sources from the SAME model field the engine reads").
///
/// v1 scope (design §10 condition 2, narrowed by implementation — see the
/// store's teaching errors): key SOURCES are source tracks (audio/instrument;
/// buses are deferred because a bus's output is hardwired to master, so a
/// stem pass could not carry a bus key source without leaking it into the
/// stem's audio). Key DESTINATIONS are strips that physically own a
/// `ChainHostAU` insert point: audio tracks and buses (instrument strips walk
/// their chain inside the instrument source node, which has no input bus to
/// receive a key edge).
public enum SidechainGraph {

    /// Every track id currently tapped as a sidechain key source, derived
    /// from `Effect.sidechainSourceTrackID` across all strips. Dangling ids
    /// (source not in `tracks`) and bus sources are EXCLUDED — no engine edge
    /// forms for them, so no PDC/stem consequence may attach either.
    public static func keySourceTrackIDs(tracks: [Track]) -> Set<UUID> {
        let validSources = Set(tracks.filter { $0.kind != .bus }.map(\.id))
        var sources: Set<UUID> = []
        for track in tracks {
            for effect in track.effects {
                if let source = effect.sidechainSourceTrackID,
                   validSources.contains(source) {
                    sources.insert(source)
                }
            }
        }
        return sources
    }

    /// Signal-flow adjacency over {track→outputBus, track→sendBus,
    /// keySource→keyedStrip} edges: `edges[x]` = every strip whose input (or
    /// key input) x's output feeds, in deterministic model order.
    static func flowEdges(tracks: [Track]) -> [UUID: [UUID]] {
        let ids = Set(tracks.map(\.id))
        var edges: [UUID: [UUID]] = [:]
        func add(_ from: UUID, _ to: UUID) {
            guard ids.contains(from), ids.contains(to) else { return }
            if edges[from]?.contains(to) != true {
                edges[from, default: []].append(to)
            }
        }
        for track in tracks {
            if track.kind != .bus {
                if let out = track.outputBusID { add(track.id, out) }
                for send in track.sends { add(track.id, send.destinationBusID) }
            }
            for effect in track.effects {
                if let source = effect.sidechainSourceTrackID {
                    add(source, track.id)
                }
            }
        }
        return edges
    }

    /// Would keying `destination` from `source` close a feedback loop?
    /// Returns the SHORTEST existing signal path `destination → … → source`
    /// (track ids, inclusive both ends; `[destination]` when destination ==
    /// source) that the new key edge `source → destination` would turn into a
    /// cycle — or nil when the edge is safe. BFS over `flowEdges` with
    /// deterministic (model-order) expansion, so the named path is stable.
    public static func cyclePath(ifKeying destination: UUID, from source: UUID,
                                 tracks: [Track]) -> [UUID]? {
        if destination == source { return [destination] }
        let edges = flowEdges(tracks: tracks)
        var cameFrom: [UUID: UUID] = [:]
        var queue: [UUID] = [destination]
        var visited: Set<UUID> = [destination]
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            for next in edges[current] ?? [] where !visited.contains(next) {
                visited.insert(next)
                cameFrom[next] = current
                if next == source {
                    var path = [source]
                    var walk = source
                    while let previous = cameFrom[walk] {
                        path.append(previous)
                        walk = previous
                    }
                    return path.reversed()
                }
                queue.append(next)
            }
        }
        return nil
    }
}
