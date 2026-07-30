import Foundation

// m23-o1 Step 1 — the resolution ladder (design §3 / D2 / D6). Pure Foundation.
//
// THE ONE HOME for "which instrument family is this track", separate from the
// one home for the VALUES (`InstrumentFrequencyTable`). It lives in DAWCore and
// not inline in `Commands.swift` because m23-o2's EQ card must resolve
// IDENTICALLY — one resolution, two callers, no second computation that happens
// to agree.
//
// ⚠️ NO TRACK-NAME HEURISTIC EXISTS HERE, AND THE SIGNATURE IS THE PROOF.
// `resolve` takes `trackKind`, `instrument` and `percussionNote` — it does not
// take a `Track`, and there is no parameter capable of accepting a name. That
// is the recorded law "a function that cannot accept the varying input makes
// the property structural": WIDENING this signature with a `trackName:`
// parameter — even a defaulted one — breaks the typed binding in
// `InstrumentFamilyResolutionTests` at COMPILE time, which is where drift
// actually happens (someone "just threads the name through").
//
// THE LIMIT OF THAT PIN, stated so nobody over-trusts it: an ADDED OVERLOAD
// `resolve(trackKind:instrument:percussionNote:trackName:)` sitting BESIDE this
// one leaves the explicitly-annotated binding unambiguous, so it would compile
// green. No second pin is added for that case on purpose — a source scrape for
// the token `trackName` finds the token, not the behaviour — and an overload is
// deliberate circumvention rather than the drift a pin is for. The real guard
// there is review plus the argument below.
//
// The argument for refusing the heuristic (design §3): the caller ALREADY has
// the track name — `project.snapshot` hands every agent the string "Bass DI 01"
// — so a Swift substring table adds no information the caller lacks, while
// adding an AUTHORITY GRADIENT. A `family` field coming back from the DAW reads
// as "the DAW knows", and an LLM will act on it. Meanwhile "Bass" in a track
// name is as likely to mean a bass DRUM as a bass GUITAR, and those two
// families' recommended corners differ by roughly an octave. What ships instead
// is TEACHING: the unresolved payload names the reason, states the remedy, and
// carries the full family vocabulary in the same response.

/// The result of the ladder. The failure is a first-class case WITH A PAYLOAD —
/// never an empty struct, never `{}`, never a row of zeros.
public enum InstrumentFamilyResolution: Sendable, Equatable {
    case resolved(InstrumentFamily, source: Source)
    /// A GM percussion-bank track queried without a note: the payload NAMES
    /// what is covered, so "not covered yet" can never read as "no data".
    case drumKit(coveredNotes: [Int])
    case unresolved(Reason)

    /// WHICH RUNG decided it — the `ResolvedDropBeat.Source` discipline applied
    /// to a different question: carry WHY, always.
    public enum Source: String, Sendable, Codable, CaseIterable {
        /// The caller passed `family` outright. Handled ABOVE this resolver, in
        /// the command handler (design §3 rung 1), so `resolve` itself never
        /// returns it — it exists here so the wire has ONE vocabulary for the
        /// rungs rather than the handler minting a second string.
        case argument
        case gmProgram
        case gmPercussionNote
    }

    /// Why the ladder produced nothing. Raw values go on the wire at Step 3 and
    /// the protocol is additive-only, so these names are permanent.
    public enum Reason: String, Sendable, Codable, CaseIterable {
        case audioTrackHasNoInstrument
        /// ADDED AT STEP 1 — not in design §3's list. `Track.instrument` is
        /// `InstrumentDescriptor?` (`Model.swift:1013`), so an instrument track
        /// with no descriptor is representable, and NEITHER
        /// `audioTrackHasNoInstrument` (it is not an audio track) nor
        /// `instrumentKindCarriesNoFamily` (there is no kind) would be honest
        /// about it. Adding the case costs nothing today and cannot be renamed
        /// later; reusing a lying one would be permanent too.
        case instrumentTrackHasNoInstrument
        /// testTone / polySynth / sampler — see design §2: a synth patch's range
        /// is a property of the PATCH, and `fx.spectrum` MEASURES that.
        case instrumentKindCarriesNoFamily
        case hostedAudioUnitIsOpaque
        /// `kind == .soundBank` with `soundBank == nil` (a legal state — the
        /// silent-placeholder rule).
        case soundBankSelectionMissing
        /// ADDED AT STEP 1 — not in design §3's list. A bank loaded from an
        /// IMPORTED SF2/DLS file (`SoundBankSource.file`), or one addressed at a
        /// bank-select MSB that is neither GM melodic (121) nor GM percussion
        /// (120), carries no General MIDI semantics: its program number is that
        /// file's own preset index. Applying the GM program→family map to it
        /// would be the confident-wrong-answer failure this item exists to
        /// prevent, and `gmProgramNotCoveredInV1` would be a lie (the program is
        /// not a GM program at all).
        case soundBankIsNotGeneralMIDI
        case gmProgramNotCoveredInV1
        case percussionNoteNotCoveredInV1
        /// bus / master — no instrument identity to resolve.
        case trackIsNotAnInstrumentOrAudioTrack

        /// The agent-facing sentence. Lives beside the wire string (the
        /// `InsertSpectrumTapPoint` shape) so the raw value, this text and any
        /// future UI label are ONE value and cannot drift apart.
        ///
        /// Every one of these says *not covered yet* or *cannot tell*, NEVER
        /// *no data* (design FM8).
        public var explanation: String {
            switch self {
            case .audioTrackHasNoInstrument:
                return "This is a recorded audio track, so the project carries no "
                    + "instrument identity for it — the DAW cannot tell a bass DI "
                    + "from a vocal."
            case .instrumentTrackHasNoInstrument:
                return "This instrument track has no instrument selected yet, so "
                    + "there is nothing to identify it by."
            case .instrumentKindCarriesNoFamily:
                return "This track plays a synth or sampler patch. A patch's "
                    + "frequency range is a property of the patch, not of any "
                    + "instrument, so no reference table can describe it honestly "
                    + "— measure it instead with fx.spectrum."
            case .hostedAudioUnitIsOpaque:
                return "This track plays a hosted Audio Unit. The plugin's name "
                    + "says nothing reliable about what it sounds like, so the DAW "
                    + "will not guess a family from it."
            case .soundBankSelectionMissing:
                return "This track is set to a sound bank but no program has been "
                    + "chosen yet, so there is nothing to identify it by."
            case .soundBankIsNotGeneralMIDI:
                return "This track plays an imported sound-bank file rather than "
                    + "the system General MIDI bank, so its program number is that "
                    + "file's own preset index and carries no General MIDI meaning."
            case .gmProgramNotCoveredInV1:
                return "This General MIDI program is not covered by the v1 "
                    + "frequency reference yet. That is a gap in the table, not a "
                    + "statement that the instrument has no range."
            case .percussionNoteNotCoveredInV1:
                return "This drum-kit note is not covered by the v1 frequency "
                    + "reference yet — see coveredNotes for the pieces that are."
            case .trackIsNotAnInstrumentOrAudioTrack:
                return "This is a bus, not a source track. A bus carries whatever "
                    + "is routed into it, so it has no instrument identity."
            }
        }

        /// What the caller should do next. Every reason is self-remedying in one
        /// round trip because the response also carries the full family index.
        public var remedy: String {
            switch self {
            case .audioTrackHasNoInstrument, .instrumentTrackHasNoInstrument,
                 .instrumentKindCarriesNoFamily, .hostedAudioUnitIsOpaque,
                 .soundBankSelectionMissing, .soundBankIsNotGeneralMIDI,
                 .gmProgramNotCoveredInV1, .trackIsNotAnInstrumentOrAudioTrack:
                return "Call frequency.reference again with `family` set to one of "
                    + "the ids in `families` below."
            case .percussionNoteNotCoveredInV1:
                return "Call frequency.reference again with a note from "
                    + "`coveredNotes`, or with `family` set to one of the ids in "
                    + "`families` below."
            }
        }
    }
}

/// One covered GM percussion note: the note number, its GM Level 1 spec name,
/// and the family it belongs to.
///
/// UNCOVERED notes deliberately ship NO name (design D3): GM's own names for
/// them are spec data this table simply did not author, and inventing them
/// would be the same class of error one level down.
public struct GMPercussionNote: Sendable, Equatable {
    /// MIDI note number on the GM percussion key map (bank MSB 120).
    public let note: Int
    /// The General MIDI Level 1 percussion key-map name.
    public let gmName: String
    public let family: InstrumentFamily

    fileprivate init(note: Int, gmName: String, family: InstrumentFamily) {
        self.note = note
        self.gmName = gmName
        self.family = family
    }
}

/// THE ONLY resolution home (design D6). m23-o2's EQ card calls THIS, not a copy.
public enum InstrumentFamilyResolver {
    // MARK: - Rung 2: GM melodic program → family

    /// Index == 0-based GM melodic program, exactly like
    /// `GMProgramCatalog.programNames`. `nil` is AUTHORED at every uncovered
    /// program — never a default, never a fallthrough, so a program that has no
    /// family says so rather than falling into a neighbour.
    ///
    /// The exclusions are principled, not laziness (design §2): every synth
    /// program (38–39 Synth Bass, 80–103 Synth Lead/Pad/FX) is out because a
    /// patch's range is a property of the patch; organ (16–23) is out because
    /// registration moves the sounding octave; ensembles and choirs (48–55) are
    /// out because one program spans several families at once.
    public static let melodicProgramFamilies: [InstrumentFamily?] = [
        // 0–7 Piano. 2 "Electric Grand Piano" IS `.piano`: a CP-70 and its GM
        // descendants are strung, hammered pianos with a pickup, so the row's
        // bands and high-pass reasoning transfer. 4–5 "Electric Piano 1/2" are
        // NOT: a Rhodes has struck tines and a Wurlitzer struck reeds, with no
        // strings at all — mechanism decides membership, not the marketing name.
        // (The honest cost: an electric grand is typically 73 keys, so `.piano`'s
        // A0–C8 compass overstates its bottom end. Bounded — V2a still passes
        // comfortably against a real CP-70's low E1.)
        .piano, .piano, .piano, .piano,
        nil, nil, nil, nil,                     // 4–5 electricPiano DELETED
        // 8–15 Chromatic Percussion — none.
        nil, nil, nil, nil, nil, nil, nil, nil,
        // 16–23 Organ — registration moves the sounding octave.
        nil, nil, nil, nil, nil, nil, nil, nil,
        // 24–31 Guitar
        .acousticGuitar, .acousticGuitar,
        .electricGuitar, .electricGuitar, .electricGuitar, .electricGuitar,
        .electricGuitar,
        nil,                                    // 31 Guitar Harmonics
        // 32–39 Bass
        .uprightBass,                           // 32 Acoustic Bass
        .electricBass, .electricBass, .electricBass, .electricBass, .electricBass,
        nil, nil,                               // 38–39 Synth Bass
        // 40–47 Strings. 40/41/42 were violin/viola/cello, all DELETED by the
        // research pass: every actionable field would have come from
        // ensemble-level "Orchestral Strings" guidance that never names the
        // instrument, and the cello's section-level 100 Hz corner fails V2a
        // against its own open C2 (bound 82.41 Hz).
        nil, nil, nil,                          // 40–42 violin/viola/cello DELETED
        .uprightBass,                           // 43 Contrabass — same instrument
        nil, nil, nil, nil,                     // 44–47 Tremolo/Pizz/Harp/Timpani
        // 48–55 Ensemble — a section spans several families at once.
        nil, nil, nil, nil, nil, nil, nil, nil,
        // 56–63 Brass. 56/59 were trumpet and 57 trombone, all DELETED: the
        // trumpet's source states a WRITTEN F♯, which sounds E3 on a B♭
        // instrument, so the MIDI field would have disagreed with the pitch in
        // its own quote; the trombone's only guidance is section-level 150 Hz,
        // which fails V2a against its low E2 (bound 103.83 Hz).
        nil, nil,                               // 56–57 trumpet/trombone DELETED
        nil,                                    // 58 Tuba — deferred
        nil,                                    // 59 Muted Trumpet — DELETED with trumpet
        nil, nil, nil, nil,                     // 60–63 Horn/Section/Synth Brass
        // 64–71 Reed — saxes/oboe/bassoon/clarinet all deferred.
        nil, nil, nil, nil, nil, nil, nil, nil,
        // 72–79 Pipe. 73 was flute, DELETED: no fetchable source states a
        // flute-specific high-pass corner or flute-specific bands, and the
        // high-pass is REQUIRED, so the row could not ship at all.
        nil,                                    // 72 Piccolo — deferred
        nil,                                    // 73 Flute — DELETED
        nil, nil, nil, nil, nil, nil,
        // 80–87 Synth Lead — out on principle.
        nil, nil, nil, nil, nil, nil, nil, nil,
        // 88–95 Synth Pad — out on principle.
        nil, nil, nil, nil, nil, nil, nil, nil,
        // 96–103 Synth Effects — out on principle.
        nil, nil, nil, nil, nil, nil, nil, nil,
        // 104–111 Ethnic
        nil, nil, nil, nil, nil, nil, nil, nil,
        // 112–119 Percussive
        nil, nil, nil, nil, nil, nil, nil, nil,
        // 120–127 Sound Effects
        nil, nil, nil, nil, nil, nil, nil, nil,
    ]

    /// The GM categories each family is allowed to appear in — the other half of
    /// the category-consistency sweep. A cross-category mis-assignment (GM 60
    /// French Horn mapped to `flute`, say) breaks this MECHANICALLY instead of
    /// needing review.
    public static func allowedGMCategories(for family: InstrumentFamily) -> Set<String> {
        switch family {
        case .piano: return ["Piano"]
        case .acousticGuitar, .electricGuitar: return ["Guitar"]
        // "Strings" is allowed for uprightBass because GM 43 Contrabass lives in
        // the Strings bucket while GM 32 Acoustic Bass lives in Bass.
        case .uprightBass: return ["Bass", "Strings"]
        case .electricBass: return ["Bass"]
        // Percussion is reached by NOTE, never by program (design D3), and
        // vocals have no GM melodic program at all — reaching either through
        // `melodicProgramFamilies` is a bug, so the allowed set is EMPTY.
        // EIGHT of the thirteen families are in this arm: an empty set means
        // exactly "no program maps here", and the C9 sweep pins that
        // equivalence in BOTH directions.
        case .kick, .snare, .hiHat, .tom, .rideCymbal, .crashCymbal,
             .maleVocal, .femaleVocal:
            return []
        }
    }

    // MARK: - Rung 3: GM percussion note → family

    /// The 17 covered GM Level 1 percussion notes, authored in note order.
    /// Everything else is `.percussionNoteNotCoveredInV1` — including 37 side
    /// stick, 39 hand clap, 52 china, 53 ride bell, 54 tambourine, 55 splash and
    /// 56 cowbell, each of which has a genuinely different spectrum. Folding
    /// them into a neighbour would be exactly the confident-wrong-answer failure
    /// this item exists to prevent.
    public static let percussionNotes: [GMPercussionNote] = [
        GMPercussionNote(note: 35, gmName: "Acoustic Bass Drum", family: .kick),
        GMPercussionNote(note: 36, gmName: "Bass Drum 1", family: .kick),
        GMPercussionNote(note: 38, gmName: "Acoustic Snare", family: .snare),
        GMPercussionNote(note: 40, gmName: "Electric Snare", family: .snare),
        GMPercussionNote(note: 41, gmName: "Low Floor Tom", family: .tom),
        GMPercussionNote(note: 42, gmName: "Closed Hi Hat", family: .hiHat),
        GMPercussionNote(note: 43, gmName: "High Floor Tom", family: .tom),
        GMPercussionNote(note: 44, gmName: "Pedal Hi-Hat", family: .hiHat),
        GMPercussionNote(note: 45, gmName: "Low Tom", family: .tom),
        GMPercussionNote(note: 46, gmName: "Open Hi-Hat", family: .hiHat),
        GMPercussionNote(note: 47, gmName: "Low-Mid Tom", family: .tom),
        GMPercussionNote(note: 48, gmName: "Hi-Mid Tom", family: .tom),
        GMPercussionNote(note: 49, gmName: "Crash Cymbal 1", family: .crashCymbal),
        GMPercussionNote(note: 50, gmName: "High Tom", family: .tom),
        GMPercussionNote(note: 51, gmName: "Ride Cymbal 1", family: .rideCymbal),
        GMPercussionNote(note: 57, gmName: "Crash Cymbal 2", family: .crashCymbal),
        GMPercussionNote(note: 59, gmName: "Ride Cymbal 2", family: .rideCymbal),
    ]

    /// The covered note numbers, ascending — the `coveredNotes` payload.
    public static let coveredPercussionNotes: [Int] =
        percussionNotes.map(\.note).sorted()

    /// The covered entry for a note, or `nil` when v1 does not cover it.
    public static func percussionNote(_ note: Int) -> GMPercussionNote? {
        percussionNotes.first { $0.note == note }
    }

    /// The covered notes that belong to a family, ascending — the `notes` field
    /// of the family index (design §6). Empty for every non-percussion family.
    public static func percussionNotes(for family: InstrumentFamily) -> [Int] {
        percussionNotes.filter { $0.family == family }.map(\.note).sorted()
    }

    // MARK: - The ladder

    /// Run the ladder against a track's instrument state.
    ///
    /// ⚠️ THE ABSENT PARAMETER IS THE FEATURE. There is no `trackName`, and
    /// there is deliberately no `Track` parameter that could carry one in
    /// sideways. Rung 1 (a caller-supplied `family`) is handled ABOVE this
    /// function, in the command handler, so that the override is visible in the
    /// response as `resolvedFrom: "argument"` rather than being laundered
    /// through the resolver.
    ///
    /// - Parameters:
    ///   - trackKind: the track's kind. A bus resolves
    ///     `.trackIsNotAnInstrumentOrAudioTrack`.
    ///   - instrument: the track's instrument descriptor, if any.
    ///   - percussionNote: a GM percussion note, meaningful only when the track
    ///     addresses the GM percussion bank. `nil` there yields `.drumKit`.
    public static func resolve(trackKind: TrackKind,
                               instrument: InstrumentDescriptor?,
                               percussionNote: Int?) -> InstrumentFamilyResolution {
        switch trackKind {
        case .bus:
            return .unresolved(.trackIsNotAnInstrumentOrAudioTrack)
        case .audio:
            // The COMMON case, not an edge: "clean up this bass" usually lives
            // on a recorded audio track.
            return .unresolved(.audioTrackHasNoInstrument)
        case .instrument:
            break
        }

        guard let instrument else { return .unresolved(.instrumentTrackHasNoInstrument) }

        switch instrument.kind {
        case .testTone, .polySynth, .sampler:
            return .unresolved(.instrumentKindCarriesNoFamily)
        case .audioUnit:
            return .unresolved(.hostedAudioUnitIsOpaque)
        case .soundBank:
            break
        }

        guard let bank = instrument.soundBank else {
            return .unresolved(.soundBankSelectionMissing)
        }
        // An imported SF2/DLS file's program number is that file's own preset
        // index, not a GM program — see `Reason.soundBankIsNotGeneralMIDI`.
        guard bank.source == .generalMIDI else {
            return .unresolved(.soundBankIsNotGeneralMIDI)
        }

        switch bank.bankMSB {
        case GMProgramCatalog.percussionBankMSB:
            guard let note = percussionNote else {
                return .drumKit(coveredNotes: coveredPercussionNotes)
            }
            guard let covered = self.percussionNote(note) else {
                return .unresolved(.percussionNoteNotCoveredInV1)
            }
            return .resolved(covered.family, source: .gmPercussionNote)

        case GMProgramCatalog.melodicBankMSB:
            guard melodicProgramFamilies.indices.contains(bank.program),
                  let family = melodicProgramFamilies[bank.program] else {
                return .unresolved(.gmProgramNotCoveredInV1)
            }
            return .resolved(family, source: .gmProgram)

        default:
            // A bank-select MSB that is neither 121 nor 120 addresses something
            // outside the GM layout even on the system bank.
            return .unresolved(.soundBankIsNotGeneralMIDI)
        }
    }
}
