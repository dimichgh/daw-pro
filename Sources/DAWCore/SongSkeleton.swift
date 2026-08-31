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

    /// m34-o — the GM program this part SOUNDS LIKE, or nil to leave the track
    /// unconfigured (which plays `InstrumentDescriptor.default`, the built-in
    /// Poly Synth).
    ///
    /// ⭐ WHY THIS EXISTS, and it is the sustain-pedal report's real half. The
    /// user's rule: *"piano decays, organ sustains and so on depending on
    /// instrument."* THE INSTRUMENT DECIDES — a piano's note fades because a
    /// piano fades, an organ's does not because an organ does not. That rule
    /// was already TRUE on the hosted sound-bank path (measured: GM program 0
    /// "Acoustic Grand Piano" falls to silence under a held pedal within 15 s,
    /// while program 19 "Church Organ" holds dead flat), and it could not be
    /// true of a skeleton, because a skeleton assigned NO instrument at all:
    /// every generated part — the one named "Drums", the one named "Piano",
    /// the one named "Organ" — came out as the same saw poly synth. A part
    /// called Piano that neither sounds nor fades like a piano is the defect
    /// this field ends.
    ///
    /// ⛔ NOT EVERY PART GETS ONE, DELIBERATELY. "Synth", "Lead" and the two
    /// guitars in the electric genres stay nil where the built-in synth is a
    /// defensible voice for them: a synth part BEING a synth is
    /// instrument-appropriate, and blanket-assigning GM to everything would
    /// make this a "replace the built-in" change rather than a "make the
    /// default fit the part" one.
    ///
    /// ⚠️ ONLY `.instrument` PARTS. An audio track (Vocals, FX, Samples) hosts
    /// no instrument; a program on one is rejected at validation rather than
    /// silently dropped.
    ///
    /// ADDITIVE-OPTIONAL: nil is exactly today's behaviour, so a caller-supplied
    /// roster written before m34-o still compiles and still generates what it
    /// always did. And because the store writes the resolved descriptor into the
    /// new track EXPLICITLY, this changes only songs generated from now on —
    /// it cannot reach a project already on disk (see `ProjectDocument`: a track
    /// with no `instrument` key resolves the type-level default at LOAD, which
    /// is why the fix is here and not on `InstrumentDescriptor.default`).
    public let program: SoundBankProgram?

    public init(name: String, kind: TrackKind, mixerPreset: String? = nil,
                program: SoundBankProgram? = nil) {
        self.name = name
        self.kind = kind
        self.mixerPreset = mixerPreset
        self.program = program
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

/// The v1 curated genre catalog — fourteen genres, each a working starting
/// point. 4/4 assumed throughout (bars → beats ×4). Mixer-preset references
/// point only at `MixerPresetCatalog.v1` names; a catalog-integrity test
/// enforces that.
///
/// m26-p (route ⓑ) grew this from five to fourteen. `v1` GROWS IN PLACE and the
/// nine additions are appended AFTER the original five, so catalog order — which
/// the MCP enum mirrors — stays stable and no existing genre is retuned. Route ⓐ
/// (the free-form `tracks` roster override) already landed and covers ANY genre;
/// these curated defaults exist for DISCOVERABILITY, because the enum's
/// description is how an agent learns what a genre actually contains.
///
/// ⚠️ THE BAR FOR A SLOT: a genre must be distinct in ROSTER AND FORM. That is
/// why there is no `latin` (salsa, reggaetón, bachata and cumbia share almost no
/// roster or tempo — shipping them as one entry would recreate exactly the
/// rock-serving-blues failure this work exists to fix) and no catch-all `edm`
/// (house is here already; trance/DnB/techno differ by 40+ BPM). The roster
/// override reaches all of those with no release.
///
/// ⚠️ TRACK KIND IS A CONTRACT, NOT A LABEL (m26-o, N4): `.audio` is reserved
/// for RECORDED material (Vocals, Backing Vocals, FX, Samples, Vinyl FX); every
/// PLAYABLE part is `.instrument`, because an audio track cannot host an
/// instrument and an all-MIDI brief would have to remove and re-add it — staling
/// the very ids the macro just returned. A test pins this across every genre.
public enum SongSkeletonCatalog {
    /// Every v1 genre, in catalog order (matches the MCP enum ordering).
    public static let v1: [SongSkeletonGenre] = [
        pop,
        house,
        hipHop,
        rock,
        ballad,
        // m26-p additions — appended, never interleaved (order is wire-visible).
        blues,
        jazz,
        country,
        rAndB,
        funk,
        metal,
        folk,
        reggae,
        loFi,
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
            SongSkeletonTrack(name: "Drums", kind: .instrument,
                              program: GMProgramCatalog.standardDrumKit),
            SongSkeletonTrack(name: "Bass", kind: .instrument, mixerPreset: "bass-tight",
                              program: GMProgramCatalog.melodic(33)),   // Electric Bass (finger)
            // ⭐ THE REPORTED CASE. "Keys" was a saw synth that held forever
            // under the sustain pedal; an Acoustic Grand Piano fades, because
            // a piano fades. Measured to silence within 15 s.
            SongSkeletonTrack(name: "Keys", kind: .instrument, mixerPreset: "warm-keys",
                              program: GMProgramCatalog.melodic(0)),    // Acoustic Grand Piano
            // Lead stays nil: the built-in Poly Synth IS a defensible pop lead.
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
            SongSkeletonTrack(name: "Drums", kind: .instrument,
                              program: GMProgramCatalog.standardDrumKit),
            SongSkeletonTrack(name: "Bass", kind: .instrument, mixerPreset: "bass-tight",
                              program: GMProgramCatalog.melodic(38)),   // Synth Bass 1
            // Synth stays nil — a house synth part being the built-in synth is
            // instrument-appropriate, not a gap.
            SongSkeletonTrack(name: "Synth", kind: .instrument),
            // ⭐ A SUSTAINING PART, ON PURPOSE. A pad HOLDS under the pedal and
            // must keep holding: this is the shipped-surface control that the
            // m34-o envelope work did not simply make everything fade.
            SongSkeletonTrack(name: "Pads", kind: .instrument, mixerPreset: "warm-keys",
                              program: GMProgramCatalog.melodic(89)),   // Pad 2 (warm)
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
            SongSkeletonTrack(name: "Drums", kind: .instrument,
                              program: GMProgramCatalog.standardDrumKit),
            SongSkeletonTrack(name: "808 Bass", kind: .instrument, mixerPreset: "bass-tight",
                              program: GMProgramCatalog.melodic(38)),   // Synth Bass 1
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
            // m26-n: these two were the ONLY playable parts typed `.audio` in
            // this file — every other genre types every playable part
            // `.instrument` (Drums/Bass/Keys/Lead/Synth/Pads/Piano/Strings) and
            // reserves `.audio` for recorded material (Vocals, FX, Samples).
            // As audio they could not host an instrument, so an all-MIDI brief
            // had to REMOVE and RE-ADD them — which changes their ids and
            // silently staled every id the macro had just returned to the
            // caller (2026-08-17 field report, N4).
            SongSkeletonTrack(name: "Rhythm Guitar", kind: .instrument,
                              program: GMProgramCatalog.melodic(29)),   // Overdriven Guitar
            SongSkeletonTrack(name: "Lead Guitar", kind: .instrument,
                              program: GMProgramCatalog.melodic(30)),   // Distortion Guitar
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
            SongSkeletonTrack(name: "Piano", kind: .instrument, mixerPreset: "warm-keys",
                              program: GMProgramCatalog.melodic(0)),   // Acoustic Grand Piano
            SongSkeletonTrack(name: "Strings", kind: .instrument,
                              program: GMProgramCatalog.melodic(48)),   // String Ensemble 1 — SUSTAINS, correctly
            SongSkeletonTrack(name: "Bass", kind: .instrument, mixerPreset: "bass-tight",
                              program: GMProgramCatalog.melodic(32)),   // Acoustic Bass
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

    // MARK: Genres (m26-p additions)

    /// ⭐ Blues at 84 BPM — the genre whose ABSENCE caused the 2026-08-17 field
    /// report: a twelve-bar blues brief had to borrow `rock`, and inherited
    /// rock's 140 BPM, its `bass-tight` clamp, and (then) audio-typed guitars.
    /// The form is genuinely twelve-bar: every body section is 12 bars, not the
    /// 8 a pop layout would give, so the section markers land on the real chorus
    /// boundaries a blues player expects. `bass-round` over `bass-tight` and
    /// `drum-room` over a dry kit are the two choices that make it sound blues
    /// rather than rock-at-84.
    static let blues = SongSkeletonGenre(
        name: "blues",
        displayName: "Blues",
        defaultTempoBPM: 84,
        tracks: [
            SongSkeletonTrack(name: "Drums", kind: .instrument, mixerPreset: "drum-room",
                              program: GMProgramCatalog.standardDrumKit),
            SongSkeletonTrack(name: "Bass", kind: .instrument, mixerPreset: "bass-round",
                              program: GMProgramCatalog.melodic(33)),   // Electric Bass (finger)
            SongSkeletonTrack(name: "Rhythm Guitar", kind: .instrument,
                              program: GMProgramCatalog.melodic(27)),   // Electric Guitar (clean)
            SongSkeletonTrack(name: "Lead Guitar", kind: .instrument, mixerPreset: "guitar-crunch",
                              program: GMProgramCatalog.melodic(29)),   // Overdriven Guitar
            SongSkeletonTrack(name: "Organ", kind: .instrument, mixerPreset: "warm-keys",
                              program: GMProgramCatalog.melodic(16)),   // Drawbar Organ — HOLDS under the pedal, and MUST
            SongSkeletonTrack(name: "Vocals", kind: .audio, mixerPreset: "vocal-presence"),
        ],
        defaultSections: [
            SkeletonSection(name: "Intro", bars: 4),
            SkeletonSection(name: "Head", bars: 12),   // the twelve-bar form, stated once…
            SkeletonSection(name: "Verse", bars: 12),  // …and repeated, as it is played
            SkeletonSection(name: "Solo", bars: 12),
            SkeletonSection(name: "Verse", bars: 12),
            SkeletonSection(name: "Outro", bars: 4),
        ])

    /// Jazz at 132 BPM: a combo, not a band — no vocal track at all, and the
    /// form is head/solos/head with 32-bar choruses, so the markers map onto
    /// where a player actually trades. The ONLY genre here with no `.audio`
    /// strip; that is correct, not an oversight (a combo is played, not tracked).
    static let jazz = SongSkeletonGenre(
        name: "jazz",
        displayName: "Jazz",
        defaultTempoBPM: 132,
        tracks: [
            SongSkeletonTrack(name: "Drums", kind: .instrument, mixerPreset: "drum-room",
                              program: GMProgramCatalog.standardDrumKit),
            SongSkeletonTrack(name: "Upright Bass", kind: .instrument, mixerPreset: "bass-round",
                              program: GMProgramCatalog.melodic(32)),   // Acoustic Bass
            SongSkeletonTrack(name: "Piano", kind: .instrument, mixerPreset: "warm-keys",
                              program: GMProgramCatalog.melodic(0)),   // Acoustic Grand Piano
            SongSkeletonTrack(name: "Horn", kind: .instrument, mixerPreset: "horn-section",
                              program: GMProgramCatalog.melodic(56)),   // Trumpet
            SongSkeletonTrack(name: "Guitar", kind: .instrument,
                              program: GMProgramCatalog.melodic(26)),   // Electric Guitar (jazz)
        ],
        defaultSections: [
            SkeletonSection(name: "Intro", bars: 8),
            SkeletonSection(name: "Head", bars: 32),
            SkeletonSection(name: "Piano Solo", bars: 32),
            SkeletonSection(name: "Horn Solo", bars: 32),
            SkeletonSection(name: "Head", bars: 32),
            SkeletonSection(name: "Outro", bars: 8),
        ])

    /// Country at 100 BPM: the roster is the tell — an acoustic AND an electric
    /// guitar AND a pedal steel, which no other genre here carries. Standard
    /// verse/chorus form with a bridge.
    static let country = SongSkeletonGenre(
        name: "country",
        displayName: "Country",
        defaultTempoBPM: 100,
        tracks: [
            SongSkeletonTrack(name: "Drums", kind: .instrument, mixerPreset: "drum-bus-glue",
                              program: GMProgramCatalog.standardDrumKit),
            SongSkeletonTrack(name: "Bass", kind: .instrument, mixerPreset: "bass-round",
                              program: GMProgramCatalog.melodic(32)),   // Acoustic Bass
            SongSkeletonTrack(name: "Acoustic Guitar", kind: .instrument, mixerPreset: "acoustic-sparkle",
                              program: GMProgramCatalog.melodic(25)),   // Acoustic Guitar (steel)
            SongSkeletonTrack(name: "Electric Guitar", kind: .instrument,
                              program: GMProgramCatalog.melodic(27)),   // Electric Guitar (clean)
            SongSkeletonTrack(name: "Pedal Steel", kind: .instrument),
            SongSkeletonTrack(name: "Vocals", kind: .audio, mixerPreset: "vocal-presence"),
        ],
        defaultSections: [
            SkeletonSection(name: "Intro", bars: 4),
            SkeletonSection(name: "Verse", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Verse", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Bridge", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Outro", bars: 4),
        ])

    /// R&B at 88 BPM: the only genre with a SEPARATE backing-vocal lane (stacked
    /// harmonies are the genre's signature), and the only one whose form carries
    /// a Pre-Chorus — the 4-bar lift into the hook that defines modern R&B
    /// structure. Both vocal strips are `.audio`: they are sung, not played.
    static let rAndB = SongSkeletonGenre(
        name: "r-and-b",
        displayName: "R&B",
        defaultTempoBPM: 88,
        tracks: [
            SongSkeletonTrack(name: "Drums", kind: .instrument, mixerPreset: "drum-bus-glue",
                              program: GMProgramCatalog.standardDrumKit),
            SongSkeletonTrack(name: "Bass", kind: .instrument, mixerPreset: "bass-round",
                              program: GMProgramCatalog.melodic(33)),   // Electric Bass (finger)
            SongSkeletonTrack(name: "Keys", kind: .instrument, mixerPreset: "warm-keys",
                              program: GMProgramCatalog.melodic(4)),   // Electric Piano 1 — decays
            SongSkeletonTrack(name: "Pads", kind: .instrument,
                              program: GMProgramCatalog.melodic(89)),   // Pad 2 (warm) — SUSTAINS, correctly
            SongSkeletonTrack(name: "Lead Vocal", kind: .audio, mixerPreset: "vocal-presence"),
            SongSkeletonTrack(name: "Backing Vocals", kind: .audio),
        ],
        defaultSections: [
            SkeletonSection(name: "Intro", bars: 4),
            SkeletonSection(name: "Verse", bars: 8),
            SkeletonSection(name: "Pre-Chorus", bars: 4),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Verse", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Bridge", bars: 8),
            SkeletonSection(name: "Outro", bars: 4),
        ])

    /// Funk at 108 BPM: `bass-tight` DELIBERATELY (funk's bass is percussive and
    /// wants the clamp — it is the one new genre where the tight preset is the
    /// right answer, which is precisely why `bass-round` is a sibling and not a
    /// replacement). Long 16-bar verses to vamp over, and a Breakdown where the
    /// band drops to the rhythm section.
    static let funk = SongSkeletonGenre(
        name: "funk",
        displayName: "Funk",
        defaultTempoBPM: 108,
        tracks: [
            SongSkeletonTrack(name: "Drums", kind: .instrument, mixerPreset: "drum-bus-glue",
                              program: GMProgramCatalog.standardDrumKit),
            SongSkeletonTrack(name: "Bass", kind: .instrument, mixerPreset: "bass-tight",
                              program: GMProgramCatalog.melodic(33)),   // Electric Bass (finger)
            SongSkeletonTrack(name: "Rhythm Guitar", kind: .instrument,
                              program: GMProgramCatalog.melodic(27)),   // Electric Guitar (clean)
            SongSkeletonTrack(name: "Clavinet", kind: .instrument, mixerPreset: "warm-keys",
                              program: GMProgramCatalog.melodic(7)),   // Clavinet — the part is NAMED for the program
            SongSkeletonTrack(name: "Horns", kind: .instrument, mixerPreset: "horn-section",
                              program: GMProgramCatalog.melodic(61)),   // Brass Section
            SongSkeletonTrack(name: "Vocals", kind: .audio, mixerPreset: "vocal-presence"),
        ],
        defaultSections: [
            SkeletonSection(name: "Intro", bars: 8),
            SkeletonSection(name: "Verse", bars: 16),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Breakdown", bars: 8),
            SkeletonSection(name: "Verse", bars: 16),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Outro", bars: 8),
        ])

    /// Metal at 170 BPM: the fastest genre here, and the only one with a DOUBLE
    /// rhythm-guitar roster ("Rhythm Guitar L"/"R" — the hard-panned double-track
    /// that is the sound). All three guitars carry `guitar-crunch`. The form ends
    /// on a Chorus with no Outro, after a Breakdown and a 16-bar Solo.
    static let metal = SongSkeletonGenre(
        name: "metal",
        displayName: "Metal",
        defaultTempoBPM: 170,
        tracks: [
            SongSkeletonTrack(name: "Drums", kind: .instrument, mixerPreset: "drum-bus-glue",
                              program: GMProgramCatalog.standardDrumKit),
            SongSkeletonTrack(name: "Bass", kind: .instrument, mixerPreset: "bass-tight",
                              program: GMProgramCatalog.melodic(33)),   // Electric Bass (finger)
            SongSkeletonTrack(name: "Rhythm Guitar L", kind: .instrument, mixerPreset: "guitar-crunch",
                              program: GMProgramCatalog.melodic(30)),   // Distortion Guitar
            SongSkeletonTrack(name: "Rhythm Guitar R", kind: .instrument, mixerPreset: "guitar-crunch",
                              program: GMProgramCatalog.melodic(30)),   // Distortion Guitar
            SongSkeletonTrack(name: "Lead Guitar", kind: .instrument, mixerPreset: "guitar-crunch",
                              program: GMProgramCatalog.melodic(30)),   // Distortion Guitar
            SongSkeletonTrack(name: "Vocals", kind: .audio, mixerPreset: "vocal-presence"),
        ],
        defaultSections: [
            SkeletonSection(name: "Intro", bars: 8),
            SkeletonSection(name: "Verse", bars: 16),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Verse", bars: 16),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Breakdown", bars: 8),
            SkeletonSection(name: "Solo", bars: 16),
            SkeletonSection(name: "Chorus", bars: 8),
        ])

    /// Folk at 96 BPM: the ONLY genre whose roster leads with a guitar and a
    /// voice rather than drums — the order is the arrangement advice. Percussion
    /// rather than a kit, and a fiddle instead of a lead guitar.
    static let folk = SongSkeletonGenre(
        name: "folk",
        displayName: "Folk",
        defaultTempoBPM: 96,
        tracks: [
            SongSkeletonTrack(name: "Acoustic Guitar", kind: .instrument, mixerPreset: "acoustic-sparkle",
                              program: GMProgramCatalog.melodic(25)),   // Acoustic Guitar (steel)
            SongSkeletonTrack(name: "Vocals", kind: .audio, mixerPreset: "vocal-presence"),
            SongSkeletonTrack(name: "Bass", kind: .instrument, mixerPreset: "bass-round",
                              program: GMProgramCatalog.melodic(32)),   // Acoustic Bass
            SongSkeletonTrack(name: "Fiddle", kind: .instrument,
                              program: GMProgramCatalog.melodic(40)),   // Violin
            SongSkeletonTrack(name: "Percussion", kind: .instrument,
                              program: GMProgramCatalog.standardDrumKit),
        ],
        defaultSections: [
            SkeletonSection(name: "Intro", bars: 4),
            SkeletonSection(name: "Verse", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Verse", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Bridge", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Outro", bars: 4),
        ])

    /// Reggae at 76 BPM — the slowest genre here after the ballad. "Skank
    /// Guitar" is named for the off-beat chop it plays, so the roster tells the
    /// player what the part IS, and the form carries a Dub Break where the mix
    /// strips to drum and bass.
    static let reggae = SongSkeletonGenre(
        name: "reggae",
        displayName: "Reggae",
        defaultTempoBPM: 76,
        tracks: [
            SongSkeletonTrack(name: "Drums", kind: .instrument, mixerPreset: "drum-bus-glue",
                              program: GMProgramCatalog.standardDrumKit),
            SongSkeletonTrack(name: "Bass", kind: .instrument, mixerPreset: "bass-round",
                              program: GMProgramCatalog.melodic(33)),   // Electric Bass (finger)
            SongSkeletonTrack(name: "Skank Guitar", kind: .instrument,
                              program: GMProgramCatalog.melodic(27)),   // Electric Guitar (clean)
            SongSkeletonTrack(name: "Organ", kind: .instrument, mixerPreset: "warm-keys",
                              program: GMProgramCatalog.melodic(16)),   // Drawbar Organ — HOLDS, correctly
            SongSkeletonTrack(name: "Vocals", kind: .audio, mixerPreset: "vocal-presence"),
        ],
        defaultSections: [
            SkeletonSection(name: "Intro", bars: 4),
            SkeletonSection(name: "Verse", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Verse", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Dub Break", bars: 8),
            SkeletonSection(name: "Chorus", bars: 8),
            SkeletonSection(name: "Outro", bars: 4),
        ])

    /// Lo-fi at 78 BPM: the only LOOP-BASED form here — Loop A / Loop B / Loop A
    /// rather than verse/chorus, because that is how the music is actually built.
    /// Two strips carry `lofi-tape` (the kit and the sample lane), and the Vinyl
    /// FX lane is `.audio` because crackle is a recording, not a played part.
    static let loFi = SongSkeletonGenre(
        name: "lo-fi",
        displayName: "Lo-Fi",
        defaultTempoBPM: 78,
        tracks: [
            SongSkeletonTrack(name: "Drums", kind: .instrument, mixerPreset: "lofi-tape",
                              program: GMProgramCatalog.standardDrumKit),
            SongSkeletonTrack(name: "Bass", kind: .instrument, mixerPreset: "bass-round",
                              program: GMProgramCatalog.melodic(33)),   // Electric Bass (finger)
            SongSkeletonTrack(name: "Keys", kind: .instrument, mixerPreset: "warm-keys",
                              program: GMProgramCatalog.melodic(4)),   // Electric Piano 1 — decays
            SongSkeletonTrack(name: "Samples", kind: .audio, mixerPreset: "lofi-tape"),
            SongSkeletonTrack(name: "Vinyl FX", kind: .audio),
        ],
        defaultSections: [
            SkeletonSection(name: "Intro", bars: 8),
            SkeletonSection(name: "Loop A", bars: 16),
            SkeletonSection(name: "Loop B", bars: 16),
            SkeletonSection(name: "Loop A", bars: 16),
            SkeletonSection(name: "Outro", bars: 8),
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

    /// One SESSION MARKER dropped at a section's start. Mirrors the
    /// `SectionClipRef` for the same section — identical `name`, and `beat` ==
    /// that section's `startBeat` — but carries a real `id` because markers are
    /// individually addressable afterwards (`marker.rename` / `marker.move` /
    /// `marker.remove`) where a guide clip is addressed through its track.
    /// Resolvable against `ProjectStore.markers` (and `marker.list`) by id.
    public struct MarkerRef: Sendable, Equatable {
        /// The created marker's id — stable, and resolvable via `marker.list`.
        public let id: UUID
        /// The section's name, VERBATIM (never auto-numbered — see
        /// `applySongSkeleton`); disambiguate repeats by `beat`.
        public let name: String
        /// Absolute timeline position in beats: the section's start.
        public let beat: Double
        public init(id: UUID, name: String, beat: Double) {
            self.id = id
            self.name = name
            self.beat = beat
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
    /// The session markers this call created — one per section, at that
    /// section's START beat, in SECTION order (which is also beat-ascending,
    /// since section starts are a running sum). Mirrors `sectionClips` 1:1.
    /// NOTE: this is only what THIS call added; the project's `markers` array is
    /// the merged, beat-sorted whole (markers that existed before survive).
    public let markers: [MarkerRef]
    /// Loop region applied (always enabled): start and end in beats.
    public let loopStart: Double
    public let loopEnd: Double
    /// The Arrangement guide track's id.
    public let arrangementTrackID: UUID

    public init(genre: String, tempoBPM: Double, tracks: [TrackRef],
                sectionClips: [SectionClipRef], markers: [MarkerRef],
                loopStart: Double, loopEnd: Double,
                arrangementTrackID: UUID) {
        self.genre = genre
        self.tempoBPM = tempoBPM
        self.tracks = tracks
        self.sectionClips = sectionClips
        self.markers = markers
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
    /// Max section-name length (a guide-clip label, not prose). Also the bound
    /// for a custom roster's TRACK names — one home deliberately, so the two
    /// label bounds can never drift apart (the MCP schema pins 40 for both).
    static let songSkeletonSectionNameMaxLength = 40
    /// Track-count bounds for a custom `tracks` roster override. The ceiling is
    /// generous (a big session roster) but finite: the roster is created inside
    /// ONE undoable edit, so an unbounded array would be an unbounded edit.
    /// The "Arrangement" guide track is NOT counted here — it is appended on
    /// top of the roster, always, so the real ceiling is 24 + 1 tracks.
    static let songSkeletonTrackCountRange: ClosedRange<Int> = 1...24

    /// Scaffolds a working session for `genre` in ONE undoable edit
    /// ("Song Skeleton '<GenreDisplayName>'"): sets the tempo, appends the
    /// roster's named tracks (the genre's, or the caller's `tracks` override —
    /// with their mixer presets pre-applied as fresh
    /// chains), appends an INSTRUMENT "Arrangement" guide track carrying one
    /// contiguous empty MIDI clip per section (named per section, `startBeat` =
    /// running sum, `lengthBeats` = bars × 4), drops a real SESSION MARKER at
    /// every section start, and enables the loop over the whole arrangement.
    /// ADDITIVE — it never wipes the project; existing tracks and clips are
    /// untouched (a duplicate "Arrangement" name is fine — names are not ids)
    /// and markers already in the project SURVIVE, merged into the store's
    /// canonical beat order. Undo reverts the ENTIRE scaffold at once.
    ///
    /// MARKERS (the beat map, not decoration): every section start gets a
    /// `Marker` whose name is the section's name VERBATIM — the SAME string the
    /// guide clip gets, deliberately NOT auto-numbered even when a layout
    /// repeats a name (pop's default is Intro/Verse/Chorus/Verse/Chorus/Bridge/
    /// Chorus/Outro, so it lands two "Verse" and three "Chorus" markers, and
    /// calling the macro twice lands the whole set twice). One source of truth
    /// with the guide clips beats a prettier name that diverges from them;
    /// callers disambiguate by BEAT (the result's `markers` carries both, and
    /// each ref's id is directly addressable). Do not "fix" this into
    /// "Verse 1"/"Verse 2" — the clips would then disagree with the markers.
    /// A pre-existing marker sitting exactly ON a section start is KEPT
    /// alongside the new one (no dedupe) and sorts FIRST, since the merge is
    /// `markers + new` and the shared sort breaks ties by current index.
    ///
    /// ROSTER OVERRIDE (`tracks`): replaces THE GENRE ROSTER, and ONLY that.
    /// The "Arrangement" guide track is ALWAYS appended LAST regardless — an
    /// override can never suppress it, reorder it, or displace it from last
    /// position, because producing that beat map (a clip and a real session
    /// marker per section) is the macro's entire reason to exist. So
    /// `SongSkeletonResult.tracks`' documented order — roster first, the
    /// Arrangement track last — holds for every call, overridden or not. A
    /// caller roster may itself contain a track NAMED "Arrangement": names are
    /// not ids (this method already tolerates duplicates), so it is simply a
    /// roster track and the real guide track still lands after it. Not
    /// special-cased, not rejected. `genre` stays REQUIRED even under a full
    /// override — it still supplies everything the caller did not override
    /// (the default tempo today) and keeps the wire contract stable.
    ///
    /// Guards run OUTSIDE the edit body (the `applyMixerPreset` precedent):
    ///  - unknown `genre` → `songSkeletonGenreNotFound` whose message lists every
    ///    valid genre name;
    ///  - out-of-range `tempoBPM` (20...400) → `invalidSongSkeleton`;
    ///  - a bad `sections` override (count, name length, bar count) →
    ///    field-named `invalidSongSkeleton`;
    ///  - a bad `tracks` roster (count 1...24, name length, a `.bus` kind, an
    ///    unresolvable `mixerPreset` — whose message lists every valid preset)
    ///    → field-named `invalidSongSkeleton`.
    /// The whole scaffold publishes through a SINGLE `performEdit` snapshot — the
    /// tempo and loop mutations fold in via `applyTempoChange` / `applyLoopRegion`
    /// (which do NOT open their own edits) rather than the public `setTempo` /
    /// `setLoop` (which would each journal a separate undo step). `tempoBPM` nil
    /// means the genre default; `sections` nil means the genre's default layout;
    /// `tracks` nil means the genre's default roster.
    @discardableResult
    public func applySongSkeleton(genre genreID: String,
                                  tempoBPM: Double? = nil,
                                  sections: [SkeletonSection]? = nil,
                                  tracks: [SongSkeletonTrack]? = nil) throws -> SongSkeletonResult {
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

        // Roster: caller's override else the genre default, validated field by
        // field the same way `sections` is — and validated on the EFFECTIVE
        // roster, so the catalog is held to exactly the contract a caller is.
        // This override replaces the GENRE ROSTER ONLY; the Arrangement guide
        // track below is appended unconditionally and is not reachable from
        // here (that is the whole safety argument — see the doc comment).
        let effectiveRoster = tracks ?? genre.tracks
        guard Self.songSkeletonTrackCountRange.contains(effectiveRoster.count) else {
            throw ProjectError.invalidSongSkeleton(
                "tracks must have between \(Self.songSkeletonTrackCountRange.lowerBound) and "
                + "\(Self.songSkeletonTrackCountRange.upperBound) entries — got \(effectiveRoster.count)")
        }
        for (i, spec) in effectiveRoster.enumerated() {
            let trimmed = spec.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, spec.name.count <= Self.songSkeletonSectionNameMaxLength else {
                throw ProjectError.invalidSongSkeleton(
                    "tracks[\(i)].name must be a non-empty string of at most "
                    + "\(Self.songSkeletonSectionNameMaxLength) characters")
            }
            // v1 skeletons never make buses: a skeleton's job is playable parts
            // plus the guide track, and a bus with nothing routed into it is
            // dead weight the caller then has to clean up. Rejected by name
            // rather than silently coerced to `.audio`.
            guard spec.kind == .instrument || spec.kind == .audio else {
                throw ProjectError.invalidSongSkeleton(
                    "tracks[\(i)].kind must be 'instrument' or 'audio' — got "
                    + "'\(spec.kind.rawValue)'; v1 skeletons never create buses "
                    + "(add one afterwards with track.add if you need it)")
            }
            // m34-o: an audio track hosts no instrument, so a program on one
            // could only ever be silently dropped — the silent-discard defect
            // class this tree keeps paying for. Refused by name instead.
            if spec.program != nil, spec.kind != .instrument {
                throw ProjectError.invalidSongSkeleton(
                    "tracks[\(i)].program is set on a '\(spec.kind.rawValue)' track — only "
                    + "instrument tracks host an instrument. Drop the program or make the "
                    + "track kind 'instrument'.")
            }
            // The message LISTS every valid preset (the songSkeletonGenreNotFound
            // precedent) so one round trip teaches the whole vocabulary.
            if let presetName = spec.mixerPreset,
               MixerPresetCatalog.preset(named: presetName) == nil {
                let valid = MixerPresetCatalog.names.joined(separator: ", ")
                throw ProjectError.invalidSongSkeleton(
                    "tracks[\(i)].mixerPreset is unknown: '\(presetName)' — valid: \(valid)")
            }
        }

        // Build the roster tracks with fresh preset chains — NO model mutation
        // yet (everything is staged, then published in one edit below).
        var rosterTracks: [Track] = []
        var trackRefs: [SongSkeletonResult.TrackRef] = []
        for spec in effectiveRoster {
            var effects: [EffectDescriptor] = []
            if let presetName = spec.mixerPreset {
                // Reuse the mixer-preset chain machinery directly (macro-b). The
                // up-front roster guard above already rejected an unresolvable
                // preset with a field-named error, so this branch is unreachable
                // — it stays as the total-function fallback (the alternative is a
                // force-unwrap that would CRASH if the catalogs ever drift).
                guard let preset = MixerPresetCatalog.preset(named: presetName) else {
                    let valid = MixerPresetCatalog.names.joined(separator: ", ")
                    throw ProjectError.mixerPresetNotFound(
                        "unknown mixer preset '\(presetName)' — valid: \(valid)")
                }
                effects = preset.freshChain()
            }
            // m34-o: the part's GM program becomes an EXPLICIT instrument
            // descriptor on the new track. Explicit is the whole safety
            // argument — a track that carries its own instrument is immune to
            // any future change of `InstrumentDescriptor.default`, and equally
            // this assignment cannot reach a project already on disk. `nil`
            // leaves the track unconfigured exactly as before m34-o.
            let instrument = spec.program.map { program in
                InstrumentDescriptor(
                    kind: .soundBank,
                    soundBank: SoundBankConfig(
                        source: .generalMIDI, program: program.program,
                        bankMSB: program.bankMSB, bankLSB: program.bankLSB,
                        // Cosmetic, and DERIVED from the catalog rather than
                        // typed here, so a roster cannot label a program with
                        // a name that is not that program's.
                        displayName: program.name))
            }
            let track = Track(name: spec.name, kind: spec.kind,
                              instrument: instrument, effects: effects)
            rosterTracks.append(track)
            trackRefs.append(.init(id: track.id, name: track.name))
        }

        // Build the Arrangement guide track: one contiguous empty MIDI clip per
        // section (notes: [] makes it a MIDI clip with no notes). startBeat is the
        // running sum; lengthBeats is bars × 4. The SAME loop mints the section
        // marker off the SAME `cursorBeats` and the SAME name string, so the
        // guide clips and the beat map can never disagree.
        var guideClips: [Clip] = []
        var sectionRefs: [SongSkeletonResult.SectionClipRef] = []
        var sectionMarkers: [Marker] = []
        var markerRefs: [SongSkeletonResult.MarkerRef] = []
        var cursorBeats = 0.0
        for section in effectiveSections {
            let lengthBeats = Double(section.bars) * Self.beatsPerSkeletonBar
            guideClips.append(Clip(name: section.name, startBeat: cursorBeats,
                                   lengthBeats: lengthBeats, notes: []))
            sectionRefs.append(.init(name: section.name, startBeat: cursorBeats,
                                     lengthBeats: lengthBeats))
            let marker = Marker(name: section.name, beat: cursorBeats)
            sectionMarkers.append(marker)
            markerRefs.append(.init(id: marker.id, name: marker.name, beat: marker.beat))
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
        // setLoop — and, for the same reason, NOT the public `addMarker` (which
        // journals its own "Add Marker '<name>'" edit per marker: a pop skeleton
        // would cost eight extra undo steps). `tracks` and `markers` are
        // internal(set) (mutable from this extension — the documented `markers`
        // rule); the transport (private setter) is folded in through the
        // primary-file `applyTempoChange` / `applyLoopRegion` helpers, mirroring
        // how `importGeneration` folds a tempo change into its single edit.
        // `markers` rides `EditState`, so undo reverts the beat map with the rest
        // of the scaffold. The merge re-applies the SHARED `markersSortedByBeat`
        // funnel (no second sort here) so pre-existing markers survive in the
        // store's canonical order rather than being appended after them.
        //
        // `self.tracks` is spelled out here because the `tracks:` ROSTER OVERRIDE
        // parameter shadows the store's `tracks` property inside this body. The
        // two are different things and the compiler would reject the mistake, but
        // an explicit `self.` says WHICH one at a glance.
        performEdit("Song Skeleton '\(genre.displayName)'") {
            self.tracks.append(contentsOf: rosterTracks)
            self.tracks.append(arrangementTrack)
            markers = Self.markersSortedByBeat(markers + sectionMarkers)
            applyTempoChange(tempo)
            applyLoopRegion(enabled: true, startBeat: loopStart, endBeat: loopEnd)
            engine?.tracksDidChange(self.tracks)
        }

        return SongSkeletonResult(
            genre: genre.name,
            tempoBPM: tempo,
            tracks: trackRefs,
            sectionClips: sectionRefs,
            markers: markerRefs,
            loopStart: loopStart,
            loopEnd: loopEnd,
            arrangementTrackID: arrangementTrack.id)
    }
}
