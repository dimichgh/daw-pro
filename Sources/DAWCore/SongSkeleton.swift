import Foundation

// MARK: - Song-skeleton catalog (M7 macro-c)

/// One track slot in a genre skeleton: a beginner-readable name, its track
/// `kind` (instrument or audio in v1 — never a bus), and an OPTIONAL mixer
/// preset (a `MixerPresetCatalog.v1` kebab name) pre-applied to the strip when
/// the skeleton is scaffolded. `nil` leaves the strip's chain empty. The
/// `MixerPresetCatalog`/`CopilotToolCatalog` precedent: static, versioned,
/// code-defined data, not user state.
public struct SongSkeletonTrack: Sendable, Equatable {
    /// Beginner-readable track name ("Bass", "Rhythm Guitar").
    public let name: String
    /// Track kind — v1 skeletons use only `.instrument` and `.audio`.
    public let kind: TrackKind
    /// A `MixerPresetCatalog.v1` name whose fresh chain lands on this strip, or
    /// `nil` for no preset. A catalog-integrity test proves every reference here
    /// resolves against `MixerPresetCatalog.v1`.
    public let mixerPreset: String?

    public init(name: String, kind: TrackKind, mixerPreset: String? = nil) {
        self.name = name
        self.kind = kind
        self.mixerPreset = mixerPreset
    }
}

/// One arrangement section: a named span measured in BARS. 4/4 is assumed in v1,
/// so a section's timeline length in beats is `bars × 4`. Shared by the catalog
/// (a genre's `defaultSections`) and the store method's optional `sections`
/// override param.
public struct SkeletonSection: Sendable, Equatable {
    /// Section label ("Verse", "Chorus", "Drop") — also the guide clip's name.
    public let name: String
    /// Section length in bars (4/4: beats = bars × 4). Validated 1...64.
    public let bars: Int

    public init(name: String, bars: Int) {
        self.name = name
        self.bars = bars
    }
}

/// One genre skeleton: a default tempo, a roster of named tracks (some carrying
/// a mixer preset), and a default section layout. `applySongSkeleton` scaffolds
/// exactly these onto the current project as ONE undoable edit.
public struct SongSkeletonGenre: Sendable, Equatable {
    /// Stable kebab-case identifier — the wire/enum value ("hip-hop").
    public let name: String
    /// Beginner-readable display name — also the undo-label body:
    /// "Song Skeleton '<displayName>'".
    public let displayName: String
    /// Genre's default tempo in BPM (used when the caller passes no tempo).
    /// Every catalog value sits inside `TransportState.tempoRange` (20...400).
    public let defaultTempoBPM: Double
    /// The track roster, in strip order (the "Arrangement" guide track is added
    /// separately, LAST — it is not part of any genre roster).
    public let tracks: [SongSkeletonTrack]
    /// The default section layout, in timeline order.
    public let defaultSections: [SkeletonSection]

    public init(name: String, displayName: String, defaultTempoBPM: Double,
                tracks: [SongSkeletonTrack], defaultSections: [SkeletonSection]) {
        self.name = name
        self.displayName = displayName
        self.defaultTempoBPM = defaultTempoBPM
        self.tracks = tracks
        self.defaultSections = defaultSections
    }
}

/// The v1 curated genre catalog — five genres, each a working starting point.
/// 4/4 assumed throughout (bars → beats ×4). Mixer-preset references point only
/// at `MixerPresetCatalog.v1` names; a catalog-integrity test enforces that.
public enum SongSkeletonCatalog {
    /// Every v1 genre, in catalog order (matches the MCP enum ordering).
    public static let v1: [SongSkeletonGenre] = [
        pop,
        house,
        hipHop,
        rock,
        ballad,
    ]

    /// Lookup by kebab-case name; `nil` when unknown.
    public static func genre(named name: String) -> SongSkeletonGenre? {
        v1.first { $0.name == name }
    }

    /// Every valid genre name, in catalog order (for the enum + error listing).
    public static var names: [String] { v1.map(\.name) }

    // MARK: Genres

    /// Radio pop at 120 BPM: a full band plus a preset-shaped bass, keys, and
    /// vocal, with a verse/chorus form and a bridge.
    static let pop = SongSkeletonGenre(
        name: "pop",
        displayName: "Pop",
        defaultTempoBPM: 120,
        tracks: [
            SongSkeletonTrack(name: "Drums", kind: .instrument),
            SongSkeletonTrack(name: "Bass", kind: .instrument, mixerPreset: "bass-tight"),
            SongSkeletonTrack(name: "Keys", kind: .instrument, mixerPreset: "warm-keys"),
            SongSkeletonTrack(name: "Lead", kind: .instrument),
            SongSkeletonTrack(name: "Vocals", kind: .audio, mixerPreset: "vocal-presence"),
        ],
        defaultSections: [
            SkeletonSection(name: "Intro", bars: 4),
            SkeletonSection(name: "Verse", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Verse", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Bridge", bars: 4),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Outro", bars: 4),
        ])

    /// Four-on-the-floor house at 124 BPM: drums, a tight bass, a synth, warm
    /// pads, and an FX return, in a build/drop/break form.
    static let house = SongSkeletonGenre(
        name: "house",
        displayName: "House",
        defaultTempoBPM: 124,
        tracks: [
            SongSkeletonTrack(name: "Drums", kind: .instrument),
            SongSkeletonTrack(name: "Bass", kind: .instrument, mixerPreset: "bass-tight"),
            SongSkeletonTrack(name: "Synth", kind: .instrument),
            SongSkeletonTrack(name: "Pads", kind: .instrument, mixerPreset: "warm-keys"),
            SongSkeletonTrack(name: "FX", kind: .audio),
        ],
        defaultSections: [
            SkeletonSection(name: "Intro", bars: 8),
            SkeletonSection(name: "Build", bars: 8),
            SkeletonSection(name: "Drop", bars: 16),
            SkeletonSection(name: "Break", bars: 8),
            SkeletonSection(name: "Drop", bars: 16),
            SkeletonSection(name: "Outro", bars: 8),
        ])

    /// Hip-hop at 90 BPM: drums, an 808 bass, a sample lane, a lead, and a
    /// vocal, in a verse/hook form.
    static let hipHop = SongSkeletonGenre(
        name: "hip-hop",
        displayName: "Hip-Hop",
        defaultTempoBPM: 90,
        tracks: [
            SongSkeletonTrack(name: "Drums", kind: .instrument),
            SongSkeletonTrack(name: "808 Bass", kind: .instrument, mixerPreset: "bass-tight"),
            SongSkeletonTrack(name: "Samples", kind: .audio),
            SongSkeletonTrack(name: "Lead", kind: .instrument),
            SongSkeletonTrack(name: "Vocals", kind: .audio, mixerPreset: "vocal-presence"),
        ],
        defaultSections: [
            SkeletonSection(name: "Intro", bars: 4),
            SkeletonSection(name: "Verse", bars: 16),
            SkeletonSection(name: "Hook", bars: 8),
            SkeletonSection(name: "Verse", bars: 16),
            SkeletonSection(name: "Hook", bars: 8),
            SkeletonSection(name: "Outro", bars: 4),
        ])

    /// Rock at 140 BPM: drums, a tight bass, rhythm and lead guitars, and a
    /// vocal, with a guitar solo section.
    static let rock = SongSkeletonGenre(
        name: "rock",
        displayName: "Rock",
        defaultTempoBPM: 140,
        tracks: [
            SongSkeletonTrack(name: "Drums", kind: .instrument),
            SongSkeletonTrack(name: "Bass", kind: .instrument, mixerPreset: "bass-tight"),
            SongSkeletonTrack(name: "Rhythm Guitar", kind: .audio),
            SongSkeletonTrack(name: "Lead Guitar", kind: .audio),
            SongSkeletonTrack(name: "Vocals", kind: .audio, mixerPreset: "vocal-presence"),
        ],
        defaultSections: [
            SkeletonSection(name: "Intro", bars: 4),
            SkeletonSection(name: "Verse", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Verse", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Solo", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Outro", bars: 4),
        ])

    /// Ballad at 72 BPM: a warm piano, strings, a tight bass, and a vocal, in a
    /// gentle verse/chorus form.
    static let ballad = SongSkeletonGenre(
        name: "ballad",
        displayName: "Ballad",
        defaultTempoBPM: 72,
        tracks: [
            SongSkeletonTrack(name: "Piano", kind: .instrument, mixerPreset: "warm-keys"),
            SongSkeletonTrack(name: "Strings", kind: .instrument),
            SongSkeletonTrack(name: "Bass", kind: .instrument, mixerPreset: "bass-tight"),
            SongSkeletonTrack(name: "Vocals", kind: .audio, mixerPreset: "vocal-presence"),
        ],
        defaultSections: [
            SkeletonSection(name: "Intro", bars: 4),
            SkeletonSection(name: "Verse", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Verse", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Outro", bars: 4),
        ])
}

// MARK: - Result

/// What `applySongSkeleton` scaffolded, so the control layer / an agent can
/// re-orient in one round trip with real, actionable ids. `tracks` lists EVERY
/// track created, in creation order — the genre roster first, then the
/// "Arrangement" guide track LAST (whose id is also surfaced separately as
/// `arrangementTrackID` for convenience).
public struct SongSkeletonResult: Sendable, Equatable {
    /// One created track's id + name.
    public struct TrackRef: Sendable, Equatable {
        public let id: UUID
        public let name: String
        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// One guide clip laid onto the Arrangement track.
    public struct SectionClipRef: Sendable, Equatable {
        public let name: String
        public let startBeat: Double
        public let lengthBeats: Double
        public init(name: String, startBeat: Double, lengthBeats: Double) {
            self.name = name
            self.startBeat = startBeat
            self.lengthBeats = lengthBeats
        }
    }

    /// The genre's kebab id that was scaffolded.
    public let genre: String
    /// The effective tempo applied (the caller's, else the genre default).
    public let tempoBPM: Double
    /// Every created track (roster + the Arrangement guide track, in order).
    public let tracks: [TrackRef]
    /// The contiguous guide clips on the Arrangement track, in timeline order.
    public let sectionClips: [SectionClipRef]
    /// Loop region applied (always enabled): start and end in beats.
    public let loopStart: Double
    public let loopEnd: Double
    /// The Arrangement guide track's id.
    public let arrangementTrackID: UUID

    public init(genre: String, tempoBPM: Double, tracks: [TrackRef],
                sectionClips: [SectionClipRef], loopStart: Double, loopEnd: Double,
                arrangementTrackID: UUID) {
        self.genre = genre
        self.tempoBPM = tempoBPM
        self.tracks = tracks
        self.sectionClips = sectionClips
        self.loopStart = loopStart
        self.loopEnd = loopEnd
        self.arrangementTrackID = arrangementTrackID
    }
}

// MARK: - Apply (store method)

extension ProjectStore {
    /// Bars per section in v1 (4/4 assumed everywhere): a section's timeline
    /// length in beats is `bars × beatsPerSkeletonBar`.
    /// m12-b (design row 35): skeletons stay DELIBERATELY meter-map-free —
    /// the catalog's section shapes are authored against 4/4 regardless of
    /// the project's time signature (today's behavior, preserved exactly);
    /// routing this constant through `MeterMap.beatsPerBar(atBeat:)` would
    /// silently reshape skeletons on non-4/4 projects. Revisit in Phase D if
    /// meter-aware skeletons are ever wanted.
    private static let beatsPerSkeletonBar = 4.0
    /// Section-count bounds for a custom `sections` override.
    static let songSkeletonSectionCountRange: ClosedRange<Int> = 1...16
    /// Per-section bar bounds for a custom `sections` override.
    static let songSkeletonSectionBarsRange: ClosedRange<Int> = 1...64
    /// Max section-name length (a guide-clip label, not prose).
    static let songSkeletonSectionNameMaxLength = 40

    /// Scaffolds a working session for `genre` in ONE undoable edit
    /// ("Song Skeleton '<GenreDisplayName>'"): sets the tempo, appends the
    /// genre's named tracks (with their mixer presets pre-applied as fresh
    /// chains), appends an INSTRUMENT "Arrangement" guide track carrying one
    /// contiguous empty MIDI clip per section (named per section, `startBeat` =
    /// running sum, `lengthBeats` = bars × 4), and enables the loop over the
    /// whole arrangement. ADDITIVE — it never wipes the project; existing tracks
    /// and clips are untouched (a duplicate "Arrangement" name is fine — names
    /// are not ids). Undo reverts the ENTIRE scaffold at once.
    ///
    /// Guards run OUTSIDE the edit body (the `applyMixerPreset` precedent):
    ///  - unknown `genre` → `songSkeletonGenreNotFound` whose message lists every
    ///    valid genre name;
    ///  - out-of-range `tempoBPM` (20...400) → `invalidSongSkeleton`;
    ///  - a bad `sections` override (count, name length, bar count) →
    ///    field-named `invalidSongSkeleton`.
    /// The whole scaffold publishes through a SINGLE `performEdit` snapshot — the
    /// tempo and loop mutations fold in via `applyTempoChange` / `applyLoopRegion`
    /// (which do NOT open their own edits) rather than the public `setTempo` /
    /// `setLoop` (which would each journal a separate undo step). `tempoBPM` nil
    /// means the genre default; `sections` nil means the genre's default layout.
    @discardableResult
    public func applySongSkeleton(genre genreID: String,
                                  tempoBPM: Double? = nil,
                                  sections: [SkeletonSection]? = nil) throws -> SongSkeletonResult {
        // Genre guard — message lists every valid name (the mixerPresetNotFound
        // precedent).
        guard let genre = SongSkeletonCatalog.genre(named: genreID) else {
            let valid = SongSkeletonCatalog.names.joined(separator: ", ")
            throw ProjectError.songSkeletonGenreNotFound(
                "unknown genre '\(genreID)' — valid: \(valid)")
        }

        // Tempo: caller's value else the genre default; validated (never silently
        // clamped — an out-of-range request is a field-named error).
        let tempo = tempoBPM ?? genre.defaultTempoBPM
        guard TransportState.tempoRange.contains(tempo) else {
            throw ProjectError.invalidSongSkeleton(
                "tempoBPM must be between \(Int(TransportState.tempoRange.lowerBound)) and "
                + "\(Int(TransportState.tempoRange.upperBound)) — got \(tempo)")
        }

        // Sections: caller's override else the genre default; each field validated.
        let effectiveSections = sections ?? genre.defaultSections
        guard Self.songSkeletonSectionCountRange.contains(effectiveSections.count) else {
            throw ProjectError.invalidSongSkeleton(
                "sections must have between \(Self.songSkeletonSectionCountRange.lowerBound) and "
                + "\(Self.songSkeletonSectionCountRange.upperBound) entries — got \(effectiveSections.count)")
        }
        for (i, section) in effectiveSections.enumerated() {
            let trimmed = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, section.name.count <= Self.songSkeletonSectionNameMaxLength else {
                throw ProjectError.invalidSongSkeleton(
                    "sections[\(i)].name must be a non-empty string of at most "
                    + "\(Self.songSkeletonSectionNameMaxLength) characters")
            }
            guard Self.songSkeletonSectionBarsRange.contains(section.bars) else {
                throw ProjectError.invalidSongSkeleton(
                    "sections[\(i)].bars must be an integer between "
                    + "\(Self.songSkeletonSectionBarsRange.lowerBound) and "
                    + "\(Self.songSkeletonSectionBarsRange.upperBound) — got \(section.bars)")
            }
        }

        // Build the roster tracks with fresh preset chains — NO model mutation
        // yet (everything is staged, then published in one edit below).
        var rosterTracks: [Track] = []
        var trackRefs: [SongSkeletonResult.TrackRef] = []
        for spec in genre.tracks {
            var effects: [EffectDescriptor] = []
            if let presetName = spec.mixerPreset {
                // Reuse the mixer-preset chain machinery directly (macro-b): a
                // catalog-integrity test guarantees this never fails, but we throw
                // the same listing error rather than crash if the catalogs drift.
                guard let preset = MixerPresetCatalog.preset(named: presetName) else {
                    let valid = MixerPresetCatalog.names.joined(separator: ", ")
                    throw ProjectError.mixerPresetNotFound(
                        "unknown mixer preset '\(presetName)' — valid: \(valid)")
                }
                effects = preset.freshChain()
            }
            let track = Track(name: spec.name, kind: spec.kind, effects: effects)
            rosterTracks.append(track)
            trackRefs.append(.init(id: track.id, name: track.name))
        }

        // Build the Arrangement guide track: one contiguous empty MIDI clip per
        // section (notes: [] makes it a MIDI clip with no notes). startBeat is the
        // running sum; lengthBeats is bars × 4.
        var guideClips: [Clip] = []
        var sectionRefs: [SongSkeletonResult.SectionClipRef] = []
        var cursorBeats = 0.0
        for section in effectiveSections {
            let lengthBeats = Double(section.bars) * Self.beatsPerSkeletonBar
            guideClips.append(Clip(name: section.name, startBeat: cursorBeats,
                                   lengthBeats: lengthBeats, notes: []))
            sectionRefs.append(.init(name: section.name, startBeat: cursorBeats,
                                     lengthBeats: lengthBeats))
            cursorBeats += lengthBeats
        }
        let totalBeats = cursorBeats  // >= 4 (min 1 section × 1 bar) — a valid loop region.
        let arrangementTrack = Track(name: "Arrangement", kind: .instrument, clips: guideClips)
        trackRefs.append(.init(id: arrangementTrack.id, name: arrangementTrack.name))

        let loopStart = 0.0
        let loopEnd = totalBeats

        // ONE undoable edit. Nested performEdit calls would EACH journal an undo
        // entry (the journal only coalesces adjacent same-key edits inside an
        // 800 ms window — a scaffold's tempo/track/loop mutations carry different
        // keys), so we mutate directly here instead of calling addTrack/setTempo/
        // setLoop. `tracks` is internal(set) (mutable from this extension); the
        // transport (private setter) is folded in through the primary-file
        // `applyTempoChange` / `applyLoopRegion` helpers, mirroring how
        // `importGeneration` folds a tempo change into its single edit.
        performEdit("Song Skeleton '\(genre.displayName)'") {
            tracks.append(contentsOf: rosterTracks)
            tracks.append(arrangementTrack)
            applyTempoChange(tempo)
            applyLoopRegion(enabled: true, startBeat: loopStart, endBeat: loopEnd)
            engine?.tracksDidChange(tracks)
        }

        return SongSkeletonResult(
            genre: genre.name,
            tempoBPM: tempo,
            tracks: trackRefs,
            sectionClips: sectionRefs,
            loopStart: loopStart,
            loopEnd: loopEnd,
            arrangementTrackID: arrangementTrack.id)
    }
}
