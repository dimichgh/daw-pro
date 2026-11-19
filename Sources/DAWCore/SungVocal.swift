import Foundation

/// How a sung vocal track was made (p2-sing-d2, design
/// `docs/design/2026-09-27-p2-sing-integration.md` §3.9), stored as
/// `Track.sungVocalProvenance`.
///
/// ⭐ **A FACT, NOT A BINDING** — the `VoiceProvenance` doctrine
/// (`VoiceProvenance.swift`), for the same reasons:
///  - **Not a live binding.** Nothing re-sings, re-renders or re-links when the
///    melody, the lyrics or the voice change. The track's clip is an ordinary
///    audio clip that the user may edit, split or delete; this record keeps
///    describing where the audio came from.
///  - **Not a cache key.** No output is keyed on it and no comparison of it
///    invalidates anything. "Try another take" makes a NEW track with its own
///    record (the "conversions always create a new track" ruling).
///  - **Not `VoiceProvenance`.** That one drives save-time RVC voice embedding
///    and `embeddedVoicesReport()`, which would look a singing voice up in
///    the RVC store and report it missing (design §3.9).
///
/// ⛔ **A HISTORICAL RECORD THAT NO EDIT MOVES**, `project.transpose` included:
/// `octaveShift` and `songTransposeSemitones` say what was in force WHEN THE
/// TAKE WAS SUNG. Moving the song later moves the audio clip's
/// `pitchShiftSemitones` (a transpose edits audio clips); it must never
/// rewrite this record, or the record would stop describing the render.
///
/// Every field decodes leniently (a missing key reads as its default), so a
/// record with fields missing (an older build's, or one trimmed by hand)
/// still opens. Leniency covers MISSING keys only: a field of the wrong type
/// still throws, as `VoiceProvenance`'s synthesized decode does. Kinds and
/// states are raw strings, so a record written by a later build with a value
/// this build does not know still decodes (the `EffectDocument.kind`
/// precedent).
public struct SungVocalProvenance: Codable, Sendable, Equatable {

    // MARK: The engine

    /// The singing engine's id, e.g. "soulx-singer".
    public var engineId: String
    /// The upstream code commit the engine ran at.
    public var engineCommit: String
    /// The model weights' revision (or their sha256).
    public var weightsRevision: String
    /// The facade protocol version (`/health`'s `facadeVersion`).
    public var facadeVersion: Int

    // MARK: The voice

    /// The voice's id ("builtin-1", or an own voice's id).
    public var voiceId: String
    /// The voice's name AT RENDER TIME ("Built-in singer", "My voice"): a
    /// snapshot, so the record can still say what the voice was after the
    /// voice is removed.
    public var voiceName: String
    /// `VoiceKind.builtIn` or `VoiceKind.own`; a raw string for forward
    /// compatibility.
    public var voiceKind: String

    // MARK: What was sung

    /// The lyrics as they were when the take was planned (a snapshot).
    public var lyricsText: String
    /// The melody clip that was sung; nil only in a damaged record.
    public var sourceClipId: UUID?
    /// The whole octaves the vocal moved by on its own (−2...2).
    public var octaveShift: Int
    /// The semitones the song had been moved by (`project.transpose`) as
    /// part of this take's key choice, 0 when the key was kept. History, not
    /// state: see the type's ⛔ note.
    public var songTransposeSemitones: Int

    // MARK: The render

    public var seed: Int
    public var nSteps: Int
    public var cfg: Double
    /// When the take was rendered.
    public var renderedAt: Date
    /// The assembled take's loudness before and after its static gain
    /// (design §4.5 steps 2–4).
    public var loudness: BounceLoudnessReport?
    /// The note check (design §4.6 "Notes"); nil until it has run.
    public var noteAccuracy: SungNoteAccuracy?
    /// The word check (design §4.6 "Words"), filled in after landing; nil
    /// until it has run.
    public var wordCheck: SungWordCheck?
    /// The melody clip's singing style AS SUNG (p2-sing-x5, design
    /// `docs/design/2026-10-06-p2-sing-expansion.md` §5.4 "Provenance"): a
    /// snapshot of `Clip.singStyle` when the take was planned, so the record
    /// still says what was used after the clip's style changes. A clip with no
    /// style is recorded with the default vibrato it was sung with
    /// (`SingStyle.defaultVibrato`); nil only for takes sung before styles
    /// existed. Omitted from the file when nil.
    public var style: SingStyle?
    /// Which line of a multi-part sing job this track is (p2-sing-x6, design
    /// `docs/design/2026-10-06-p2-sing-expansion.md` §4.4 "Provenance"):
    /// `PartRole.lead`, `PartRole.harmony` or `PartRole.double`, a raw string
    /// for forward compatibility. nil = a take sung on its own (every take
    /// before x6, and every single-part job still); omitted from the file when
    /// nil.
    public var partRole: String?
    /// How a harmony part's notes were worked out (§4.4): the interval and
    /// the key it was counted in. nil for the lead, a double, a part sung from
    /// another clip, and every take before x6; omitted from the file when nil.
    public var harmony: SungVocalHarmony?

    /// The part roles this build writes.
    public enum PartRole {
        public static let lead = "lead"
        public static let harmony = "harmony"
        public static let double = "double"
    }

    /// The two voice kinds this build knows.
    public enum VoiceKind {
        public static let builtIn = "builtIn"
        public static let own = "own"
    }

    public init(engineId: String, engineCommit: String, weightsRevision: String, facadeVersion: Int,
                voiceId: String, voiceName: String, voiceKind: String,
                lyricsText: String, sourceClipId: UUID?, octaveShift: Int, songTransposeSemitones: Int = 0,
                seed: Int, nSteps: Int, cfg: Double, renderedAt: Date = Date(),
                loudness: BounceLoudnessReport? = nil, noteAccuracy: SungNoteAccuracy? = nil,
                wordCheck: SungWordCheck? = nil, style: SingStyle? = nil, partRole: String? = nil,
                harmony: SungVocalHarmony? = nil) {
        self.engineId = engineId
        self.engineCommit = engineCommit
        self.weightsRevision = weightsRevision
        self.facadeVersion = facadeVersion
        self.voiceId = voiceId
        self.voiceName = voiceName
        self.voiceKind = voiceKind
        self.lyricsText = lyricsText
        self.sourceClipId = sourceClipId
        self.octaveShift = octaveShift
        self.songTransposeSemitones = songTransposeSemitones
        self.seed = seed
        self.nSteps = nSteps
        self.cfg = cfg
        self.renderedAt = renderedAt
        self.loudness = loudness
        self.noteAccuracy = noteAccuracy
        self.wordCheck = wordCheck
        self.style = style
        self.partRole = partRole
        self.harmony = harmony
    }

    private enum CodingKeys: String, CodingKey {
        case engineId, engineCommit, weightsRevision, facadeVersion
        case voiceId, voiceName, voiceKind
        case lyricsText, sourceClipId, octaveShift, songTransposeSemitones
        case seed, nSteps, cfg, renderedAt, loudness, noteAccuracy, wordCheck
        case style
        case partRole, harmony
    }

    /// Lenient: every missing key reads as its default. The encoder is the
    /// synthesized one (an absent optional is omitted).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            engineId: try c.decodeIfPresent(String.self, forKey: .engineId) ?? "",
            engineCommit: try c.decodeIfPresent(String.self, forKey: .engineCommit) ?? "",
            weightsRevision: try c.decodeIfPresent(String.self, forKey: .weightsRevision) ?? "",
            facadeVersion: try c.decodeIfPresent(Int.self, forKey: .facadeVersion) ?? 0,
            voiceId: try c.decodeIfPresent(String.self, forKey: .voiceId) ?? "",
            voiceName: try c.decodeIfPresent(String.self, forKey: .voiceName) ?? "",
            voiceKind: try c.decodeIfPresent(String.self, forKey: .voiceKind) ?? "",
            lyricsText: try c.decodeIfPresent(String.self, forKey: .lyricsText) ?? "",
            sourceClipId: try c.decodeIfPresent(UUID.self, forKey: .sourceClipId),
            octaveShift: try c.decodeIfPresent(Int.self, forKey: .octaveShift) ?? 0,
            songTransposeSemitones: try c.decodeIfPresent(Int.self, forKey: .songTransposeSemitones) ?? 0,
            seed: try c.decodeIfPresent(Int.self, forKey: .seed) ?? 0,
            nSteps: try c.decodeIfPresent(Int.self, forKey: .nSteps) ?? 0,
            cfg: try c.decodeIfPresent(Double.self, forKey: .cfg) ?? 0,
            renderedAt: try c.decodeIfPresent(Date.self, forKey: .renderedAt) ?? Date(timeIntervalSinceReferenceDate: 0),
            loudness: try c.decodeIfPresent(BounceLoudnessReport.self, forKey: .loudness),
            noteAccuracy: try c.decodeIfPresent(SungNoteAccuracy.self, forKey: .noteAccuracy),
            wordCheck: try c.decodeIfPresent(SungWordCheck.self, forKey: .wordCheck),
            style: try c.decodeIfPresent(SingStyle.self, forKey: .style),
            partRole: try c.decodeIfPresent(String.self, forKey: .partRole),
            harmony: try c.decodeIfPresent(SungVocalHarmony.self, forKey: .harmony))
    }
}

/// How a harmony part was worked out (p2-sing-x6, design
/// `docs/design/2026-10-06-p2-sing-expansion.md` §4.4 "Provenance": "the
/// `HarmonySpec` and `SongKey` used"), stored as
/// `SungVocalProvenance.harmony`. A fact, like the rest of the record.
///
/// Stored as RAW values, not as the planner's enums, on purpose: the record's
/// own rule is that a value written by a later build still decodes (a new
/// interval or mode must not stop an older build opening the project, which a
/// synthesized enum decode would). Every field is optional, decoded
/// leniently, and omitted when nil. `spec` and `key` read the typed values
/// back (nil when a raw value is one this build does not know).
public struct SungVocalHarmony: Codable, Sendable, Equatable {
    /// `HarmonySpec.Interval`'s raw value ("third", "sixth", …); for a
    /// chord-tones part, the interval that filled the notes no chord gave.
    public var interval: String?
    /// `HarmonySpec.Direction`'s raw value ("above", "below").
    public var direction: String?
    /// `HarmonySpec.ChordSource`'s raw value ("auto", "none", …).
    public var chordSource: String?
    /// The key the steps were counted in: tonic pitch class 0 (C) … 11 (B).
    /// nil when no step needed a key.
    public var keyTonicPitchClass: Int?
    /// `KeyMode`'s raw value ("major", "minor").
    public var keyMode: String?
    /// `SongKey.Source`'s raw value ("given", "estimated").
    public var keySource: String?
    /// The key estimate's confidence (1 for a given key).
    public var keyConfidence: Double?
    /// A chord-tones part's rank from the top (`ChordToneRank`: 2 or 3).
    public var chordToneRank: Int?

    public init(spec: HarmonySpec?, key: SongKey?, chordToneRank: ChordToneRank? = nil) {
        interval = spec?.interval.rawValue
        direction = spec?.direction.rawValue
        chordSource = spec?.chordSource.rawValue
        keyTonicPitchClass = key?.tonicPitchClass
        keyMode = key?.mode.rawValue
        keySource = key?.source.rawValue
        keyConfidence = key?.confidence
        self.chordToneRank = chordToneRank?.rawValue
    }

    /// The interval spec, or nil when a field is missing or unknown here.
    public var spec: HarmonySpec? {
        guard let interval = interval.flatMap(HarmonySpec.Interval.init(rawValue:)),
              let direction = direction.flatMap(HarmonySpec.Direction.init(rawValue:)) else { return nil }
        return HarmonySpec(interval: interval, direction: direction,
                           chordSource: chordSource.flatMap(HarmonySpec.ChordSource.init(rawValue:)) ?? .auto)
    }

    /// The key, or nil when a field is missing or unknown here.
    public var key: SongKey? {
        guard let tonic = keyTonicPitchClass, let mode = keyMode.flatMap(KeyMode.init(rawValue:)) else { return nil }
        return SongKey(tonicPitchClass: tonic, mode: mode,
                       source: keySource.flatMap(SongKey.Source.init(rawValue:)) ?? .given,
                       confidence: keyConfidence ?? 1)
    }

    private enum CodingKeys: String, CodingKey {
        case interval, direction, chordSource, keyTonicPitchClass, keyMode, keySource, keyConfidence, chordToneRank
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interval = try c.decodeIfPresent(String.self, forKey: .interval)
        direction = try c.decodeIfPresent(String.self, forKey: .direction)
        chordSource = try c.decodeIfPresent(String.self, forKey: .chordSource)
        keyTonicPitchClass = try c.decodeIfPresent(Int.self, forKey: .keyTonicPitchClass)
        keyMode = try c.decodeIfPresent(String.self, forKey: .keyMode)
        keySource = try c.decodeIfPresent(String.self, forKey: .keySource)
        keyConfidence = try c.decodeIfPresent(Double.self, forKey: .keyConfidence)
        chordToneRank = try c.decodeIfPresent(Int.self, forKey: .chordToneRank)
    }
}

/// The note check's summary (design §4.6 "Notes"; §1.7's metric).
public struct SungNoteAccuracy: Codable, Sendable, Equatable {
    /// The share of planned NOTES that were hit, 0...1: a note is a hit when
    /// the median pitch over the middle half of its window is within ±50
    /// cents of the planned pitch (design §1.7, the spike's metric).
    public var hitRate: Double
    /// The mean absolute error over the hits, in cents; nil with no hits.
    public var meanAbsErrorCents: Double?
    /// The share of the planned note time that was voiced, 0...1.
    public var voicedCoverage: Double
    /// True when it reads "In tune" (hits ≥ 85%, error ≤ 25 c, coverage ≥ 80%).
    public var inTune: Bool
    /// The 1-based bars the amber notice names; empty when in tune.
    public var offBars: [Int]

    public init(hitRate: Double, meanAbsErrorCents: Double?, voicedCoverage: Double, inTune: Bool,
                offBars: [Int] = []) {
        self.hitRate = hitRate
        self.meanAbsErrorCents = meanAbsErrorCents
        self.voicedCoverage = voicedCoverage
        self.inTune = inTune
        self.offBars = offBars
    }

    private enum CodingKeys: String, CodingKey {
        case hitRate, meanAbsErrorCents, voicedCoverage, inTune, offBars
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(hitRate: try c.decodeIfPresent(Double.self, forKey: .hitRate) ?? 0,
                  meanAbsErrorCents: try c.decodeIfPresent(Double.self, forKey: .meanAbsErrorCents),
                  voicedCoverage: try c.decodeIfPresent(Double.self, forKey: .voicedCoverage) ?? 0,
                  inTune: try c.decodeIfPresent(Bool.self, forKey: .inTune) ?? false,
                  offBars: try c.decodeIfPresent([Int].self, forKey: .offBars) ?? [])
    }
}

/// The word check's result (design §4.6 "Words", §6 row 15's
/// `wordCheck {state, wer, heard, verdict}`).
public struct SungWordCheck: Codable, Sendable, Equatable {
    /// `State.checked`, `State.skipped` (no speech model) or
    /// `State.hardToJudge`; a raw string for forward compatibility.
    public var state: String
    /// `WordErrorRate.measure(...).wer`; nil when not checked.
    public var wer: Double?
    /// What the transcriber heard.
    public var heard: String?
    /// The results line's verdict, e.g. "clear"; a raw string.
    public var verdict: String?

    /// The states this build knows.
    public enum State {
        public static let checked = "checked"
        public static let skipped = "skipped"
        public static let hardToJudge = "hardToJudge"
    }

    public init(state: String, wer: Double? = nil, heard: String? = nil, verdict: String? = nil) {
        self.state = state
        self.wer = wer
        self.heard = heard
        self.verdict = verdict
    }

    private enum CodingKeys: String, CodingKey { case state, wer, heard, verdict }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(state: try c.decodeIfPresent(String.self, forKey: .state) ?? "",
                  wer: try c.decodeIfPresent(Double.self, forKey: .wer),
                  heard: try c.decodeIfPresent(String.self, forKey: .heard),
                  verdict: try c.decodeIfPresent(String.self, forKey: .verdict))
    }
}


// MARK: - The melody now, against the melody the take was planned from (p2-sing-e)

/// How the plan a sung take was rendered from compares with the plan the same
/// clip gives NOW, at landing (design `docs/design/2026-09-27-p2-sing-integration.md`
/// §4.5 "Project identity", amended 2026-09-27 10:10; owner p2-sing-e).
///
/// The plan signature alone cannot tell "the song was transposed" from "the
/// melody was edited": both change it. This compares the two plans field by
/// field instead. Pure: no store, no clock.
public enum SungVocalReplanComparison: Equatable, Sendable {
    /// The same plan: the take sings what the clip asks for now.
    case unchanged
    /// A PURE transposition by `semitones` (never 0): every planned note is
    /// still there, with the same id and the same timing, every pitch moved by
    /// the same amount, the words and the placement unchanged. The take lands
    /// moved by the same amount, as `project.transpose` would have moved it had
    /// it landed first.
    case transposed(semitones: Int)
    /// Anything else (a note added, removed, retimed or moved alone; the words;
    /// the tempo; the clip gone or no longer plannable): the take lands as it
    /// was sung, with the "melody changed" notice.
    case changed

    /// Compares `planned` with `current` (nil when the clip is gone or can no
    /// longer be planned).
    ///
    /// Equal signatures are `.unchanged` (the signature digests everything the
    /// render depends on, which is the rule `landSungVocal` already used). A
    /// shift whose size is outside `Clip.pitchShiftSemitonesRange` is
    /// `.changed`: `Clip.init` would clamp it silently, and a clamped shift
    /// would leave the take off-key against the song. (`project.transpose`
    /// refuses more than 12 per call, but two calls reach 24 and three reach 36.)
    public static func compare(planned: SingPlan, current: SingPlan?) -> SungVocalReplanComparison {
        guard let current else { return .changed }
        if planned.signature == current.signature { return .unchanged }
        guard planned.octaveShift == current.octaveShift,
              planned.t0Seconds.bitPattern == current.t0Seconds.bitPattern,
              planned.atBeat.bitPattern == current.atBeat.bitPattern,
              planned.units.count == current.units.count else { return .changed }
        var delta: Int?
        for (p, c) in zip(planned.units, current.units) {
            guard p.offsetSeconds.bitPattern == c.offsetSeconds.bitPattern,
                  p.onsetSeconds.bitPattern == c.onsetSeconds.bitPattern,
                  p.spanSeconds.bitPattern == c.spanSeconds.bitPattern,
                  p.words == c.words,
                  p.notes.count == c.notes.count else { return .changed }
            for (pn, cn) in zip(p.notes, c.notes) {
                guard pn.noteID == cn.noteID,
                      pn.startSeconds.bitPattern == cn.startSeconds.bitPattern,
                      pn.endSeconds.bitPattern == cn.endSeconds.bitPattern else { return .changed }
                let moved = cn.midi - pn.midi
                guard cn.sourcePitch - pn.sourcePitch == moved else { return .changed }
                if let delta, delta != moved { return .changed }
                delta = moved
            }
        }
        guard let delta, delta != 0,
              Clip.pitchShiftSemitonesRange.contains(Double(delta)) else { return .changed }
        return .transposed(semitones: delta)
    }
}
