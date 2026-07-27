import Foundation
import Testing
@testable import DAWCore

/// m23-m1 — the pure `[Track]` transform behind `excludeTrackIds`. Headless,
/// engine-free: the ONE home for "silence these tracks for this render", so no
/// second, divergent computation of the same thing can exist (`resolve` is the
/// only producer of `ResolvedRenderExclusion` — its `init` is fileprivate).
@Suite("Render exclusion transform (m23-m1)")
struct RenderExclusionTests {

    private func session() -> [Track] {
        [Track(name: "Drums", kind: .audio),
         Track(name: "Vocal", kind: .audio, isSoloed: true),
         Track(name: "Reverb", kind: .bus)]
    }

    @Test("nil ids → the session verbatim, and NO honesty field (pre-m23-m1 byte-identity)")
    func nilIsIdentity() throws {
        let tracks = session()
        let resolved = try RenderExclusion.resolve(session: tracks, excluding: nil)
        #expect(resolved.tracks == tracks)
        #expect(resolved.excludedNames == nil)
    }

    @Test("named tracks are muted AND un-soloed; every other track is untouched")
    func excludedTracksAreGatedAndDeSoloed() throws {
        let tracks = session()
        let resolved = try RenderExclusion.resolve(
            session: tracks, excluding: [tracks[1].id])
        #expect(resolved.excludedNames == ["Vocal"])
        #expect(resolved.tracks.count == tracks.count)
        #expect(resolved.tracks.map(\.id) == tracks.map(\.id))   // size + ORDER
        #expect(resolved.tracks[1].isMuted)
        // Solo leaves with the track: `soloActive` is mute-blind, so a soloed
        // excluded track would otherwise gate the whole rest of the session.
        #expect(!resolved.tracks[1].isSoloed)
        #expect(!resolved.tracks[0].isMuted)
        #expect(!resolved.tracks[2].isMuted)
        // The caller's array is a value type — it did not move.
        #expect(tracks[1].isSoloed)
        #expect(!tracks[1].isMuted)
    }

    @Test("an empty array excludes nothing but still echoes (a present, empty list)")
    func emptyArrayIsAnEcho() throws {
        let tracks = session()
        let resolved = try RenderExclusion.resolve(session: tracks, excluding: [])
        #expect(resolved.tracks == tracks)
        #expect(resolved.excludedNames == [])
    }

    @Test("names come back in SESSION order and duplicates collapse")
    func namesAreSessionOrderedAndDeduplicated() throws {
        let tracks = session()
        let resolved = try RenderExclusion.resolve(
            session: tracks,
            excluding: [tracks[2].id, tracks[0].id, tracks[0].id])
        #expect(resolved.excludedNames == ["Drums", "Reverb"])
        #expect(resolved.tracks[0].isMuted)
        #expect(resolved.tracks[2].isMuted)
        #expect(!resolved.tracks[1].isMuted)
    }

    @Test("a bus can be excluded — it is a track like any other here")
    func busesAreExcludable() throws {
        let tracks = session()
        let resolved = try RenderExclusion.resolve(
            session: tracks, excluding: [tracks[2].id])
        #expect(resolved.excludedNames == ["Reverb"])
        #expect(resolved.tracks[2].isMuted)
    }

    @Test("an unknown id throws trackNotFound and nothing is resolved")
    func unknownIDRejects() throws {
        let tracks = session()
        let stray = UUID()
        do {
            _ = try RenderExclusion.resolve(
                session: tracks, excluding: [tracks[0].id, stray])
            Issue.record("expected trackNotFound")
        } catch let ProjectError.trackNotFound(id) {
            #expect(id == stray)
        }
    }

    @Test("excluding EVERY track is allowed — it renders silence, honestly reported")
    func excludingEverythingIsAllowed() throws {
        let tracks = session()
        let resolved = try RenderExclusion.resolve(
            session: tracks, excluding: tracks.map(\.id))
        #expect(resolved.tracks.allSatisfy { $0.isMuted })
        #expect(resolved.excludedNames == ["Drums", "Vocal", "Reverb"])
    }
}
