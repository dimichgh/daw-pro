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
                wordCheck: SungWordCheck? = nil) {
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
    }

    private enum CodingKeys: String, CodingKey {
        case engineId, engineCommit, weightsRevision, facadeVersion
        case voiceId, voiceName, voiceKind
        case lyricsText, sourceClipId, octaveShift, songTransposeSemitones
        case seed, nSteps, cfg, renderedAt, loudness, noteAccuracy, wordCheck
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
            wordCheck: try c.decodeIfPresent(SungWordCheck.self, forKey: .wordCheck))
    }
}

/// The note check's summary (design §4.6 "Notes"; §1.7's metric).
public struct SungNoteAccuracy: Codable, Sendable, Equatable {
    /// The share of voiced frames within ±50 cents of the planned note, 0...1.
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
