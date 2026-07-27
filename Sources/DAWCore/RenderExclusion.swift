import Foundation

/// The resolved render-local track list for an `excludeTrackIds` render
/// (m23-m1). `init` is fileprivate, so `RenderExclusion.resolve` is the ONLY
/// producer — a second, divergent "silence these tracks" computation is
/// unrepresentable rather than merely absent (the `ResolvedDropBeat` law).
public struct ResolvedRenderExclusion: Sendable, Equatable {
    /// The track array to hand the engine: the FULL session, same size, same
    /// order, same latency profile — only the excluded tracks' gate flags
    /// differ. Never the persisted `ProjectStore.tracks`.
    public let tracks: [Track]
    /// Names of the tracks silenced, in session order — the response's honesty
    /// field. nil exactly when no `excludeTrackIds` was requested (so a render
    /// that excluded nothing stays byte-identical on the wire); a present,
    /// empty array means "you asked to exclude nothing".
    public let excludedNames: [String]?

    fileprivate init(tracks: [Track], excludedNames: [String]?) {
        self.tracks = tracks
        self.excludedNames = excludedNames
    }
}

/// `excludeTrackIds` — render the FULL session with named tracks silenced, for
/// THIS render only (m23-m1, research `m23-l-export-set-research.md` §4.4).
///
/// **Why a mute-copy and not a subset render.** `render.stems` had to invent
/// `forcedCompensationTargets` because each stem pass hands `renderOffline` a
/// REDUCED track array, whose automatic PDC plan aligns a lone strip to target
/// 0 where the full mix delays it to the session's highest-latency strip — a
/// subset "instrumental" would inherit that combing hazard silently. The
/// compensation survey (`PlaybackGraph.recomputeCompensation`) is mute-BLIND
/// across its whole extent: it never reads `isMuted`/`isSoloed`, so a
/// full-array mute-copy leaves the array size, order and latency profile
/// untouched and the automatic plan is provably the correct full-session plan.
/// No forced-targets plumbing is needed here, by construction.
///
/// **What silencing a track takes with it — say this in teaching text, don't
/// leave it to a bug report.** The strip fans out from the node that carries
/// fader/pan/MUTE (`PlaybackGraph` `:133-141`, connected at `:1067`), and that
/// fan-out array holds every send's gain node, the main destination, AND every
/// sidechain key edge. So an excluded track takes with it:
///   · its direct signal,
///   · everything it feeds a send — **its reverb/delay tail leaves too**, which
///     is what makes this a genuinely clean instrumental, and equally means
///     this parameter CANNOT express "instrumental but keep the vocal's
///     reverb" (that would be a pre-fader send tap — a different feature),
///   · its sidechain key contribution — a ducker keyed off an excluded vocal
///     stops ducking, so the music renders un-pumped.
///
/// **Solo is cleared alongside mute, deliberately.** `soloActive` is
/// `tracks.contains(where: \.isSoloed)` — mute-blind like the PDC survey — so
/// leaving `isSoloed` set on an excluded track would let a track that is NOT in
/// the render decide what everyone else hears: excluding the only soloed track
/// would render silence. Excluding a track means "as if it were not in this
/// session, audibly", so its solo flag leaves with it. Other tracks' solo
/// state is untouched and still governs the render exactly as today.
public enum RenderExclusion {

    /// Builds the render-local track list. `ids` nil → the session verbatim
    /// (`excludedNames` nil, byte-identical to a pre-m23-m1 render); otherwise
    /// every named track is returned with `isMuted` forced true and `isSoloed`
    /// forced false. An unknown id throws `ProjectError.trackNotFound`,
    /// consistent with `trackIds` everywhere else, and it throws BEFORE any
    /// rendering starts. Duplicate ids collapse. NOTHING here mutates the
    /// store: no `tracks` write, no dirty flag, no undo entry — which is the
    /// entire reason this parameter exists instead of telling a caller to mute
    /// by hand and remember to un-mute even when the render throws.
    public static func resolve(session: [Track],
                               excluding ids: [UUID]?) throws -> ResolvedRenderExclusion {
        guard let ids else {
            return ResolvedRenderExclusion(tracks: session, excludedNames: nil)
        }
        // Validate BEFORE building, so an unknown id rejects readably instead
        // of silently rendering the full mix (the `StemPlan.descriptors`
        // precedent).
        let known = Set(session.map(\.id))
        for id in ids where !known.contains(id) {
            throw ProjectError.trackNotFound(id)
        }
        let excluded = Set(ids)
        var names: [String] = []
        var tracks = session
        for index in tracks.indices where excluded.contains(tracks[index].id) {
            names.append(tracks[index].name)
            tracks[index].isMuted = true
            tracks[index].isSoloed = false
        }
        return ResolvedRenderExclusion(tracks: tracks, excludedNames: names)
    }
}
