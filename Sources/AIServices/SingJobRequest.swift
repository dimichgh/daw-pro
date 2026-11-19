import CryptoKit
import DAWCore
import Foundation

// MARK: - Render options

/// The render settings a sing job sends with every unit (design §2.4's request), as ONE value so a later
/// expansion (harmony parts, per-note expression, other languages: W8-SX's design) adds OPTIONAL fields here
/// and nowhere else.
///
/// ⚠️ **`SingRenderOptions.v1` must keep producing today's exact request bytes.** The facade refuses every
/// key it does not know (`badRequest`, `schema.py`'s `TOP_KEYS`), so a field added here must stay OUT of the
/// request while it holds its default, and the facade must learn the key before any non-default value is
/// sent. `SingJobRequestTests.v1RequestBytesArePinned` pins the bytes.
public struct SingRenderOptions: Sendable, Equatable, Codable {
    /// Diffusion steps (`nSteps`, 1...200 at the facade). 32 is the spike's value, behind every render the
    /// user picked (`scripts/sing/singlib/schema.py:17`).
    public var nSteps: Int
    /// Classifier-free guidance (`cfg`, 0...20 at the facade). 3.0, the spike's value.
    public var cfg: Double

    public init(nSteps: Int = 32, cfg: Double = 3.0) {
        self.nSteps = nSteps
        self.cfg = cfg
    }

    /// Today's request, exactly.
    public static let v1 = SingRenderOptions()
}

// MARK: - Voices

/// A voice a job sings with (design §0.3): the built-in singer, or an own voice whose reference and Route N
/// labels were made by `sing.addVoice` (p2-sing-d3 / part 2).
public enum SingJobVoice: Sendable, Equatable {
    /// Upstream's prompt voice, `builtin-1` (the user's `sing-pick = v1`).
    case builtIn
    case own(SingOwnVoice)

    /// The built-in voice's facade id.
    public static let builtInID = "builtin-1"
    /// §5.7 "Built-in voice name".
    public static let builtInName = "Built-in singer"

    public var id: String {
        switch self {
        case .builtIn: return Self.builtInID
        case .own(let voice): return voice.id
        }
    }

    public var name: String {
        switch self {
        case .builtIn: return Self.builtInName
        case .own(let voice): return voice.name
        }
    }

    /// `SungVocalProvenance.VoiceKind`'s raw string.
    public var kind: String {
        switch self {
        case .builtIn: return SungVocalProvenance.VoiceKind.builtIn
        case .own: return SungVocalProvenance.VoiceKind.own
        }
    }

    /// Whether the word check can judge this voice (design §7.3 "the instrument check, per own voice"): an own
    /// voice whose own reference transcribed with a WER over 0.20 reads "hard to judge" instead of amber.
    public var wordCheckIsReliable: Bool {
        switch self {
        case .builtIn: return true
        case .own(let voice): return voice.wordCheckIsReliable
        }
    }

    /// The voice's measured range, for a part's whole-octave fit (design `2026-10-06-p2-sing-expansion.md` §4.5): the
    /// built-in singer's measured range, an own voice's when its caller passed one, else nil (the part then sits at
    /// the lead's octave, `HarmonyPlanner.range`'s rule without a voice).
    public var range: VoiceRange? {
        switch self {
        case .builtIn: return SingVoiceLibrary.builtInRange
        case .own(let voice): return voice.range
        }
    }

    /// The facade's `voice` object (design §2.4).
    public var reference: SingingVoiceReference {
        switch self {
        case .builtIn:
            return .builtin(id: Self.builtInID)
        case .own(let v):
            return .own(id: v.id, referencePath: v.referencePath, referenceSha256: v.referenceSha256,
                        windowStartS: v.windowStartS, windowEndS: v.windowEndS, notes: v.promptNotes,
                        promptLabelOffset: v.promptLabelOffset)
        }
    }
}

/// An own voice, as the job needs it: what the facade reads plus the name and the word-check reliability.
public struct SingOwnVoice: Sendable, Equatable {
    public var id: String
    public var name: String
    public var referencePath: String
    public var referenceSha256: String
    public var windowStartS: Double
    public var windowEndS: Double
    public var promptNotes: [SingingPromptNote]
    /// Design §2.4: whole semitones added to the prompt's non-rest labels; 0 unless §7.5's Round L changes it.
    public var promptLabelOffset: Int
    public var wordCheckIsReliable: Bool
    /// The voice's measured range (`SingVoiceRecord.range`), for a harmony part's octave fit (p2-sing-x6); nil = not
    /// known here, and a part sung in this voice sits at the lead's octave.
    public var range: VoiceRange?

    public init(id: String, name: String, referencePath: String, referenceSha256: String,
                windowStartS: Double, windowEndS: Double, promptNotes: [SingingPromptNote],
                promptLabelOffset: Int = 0, wordCheckIsReliable: Bool = true, range: VoiceRange? = nil) {
        self.id = id
        self.name = name
        self.referencePath = referencePath
        self.referenceSha256 = referenceSha256
        self.windowStartS = windowStartS
        self.windowEndS = windowEndS
        self.promptNotes = promptNotes
        self.promptLabelOffset = promptLabelOffset
        self.wordCheckIsReliable = wordCheckIsReliable
        self.range = range
    }
}

// MARK: - Parts (p2-sing-x6)

/// One more line a sing job sings after the lead (design `docs/design/2026-10-06-p2-sing-expansion.md` §4.4-§4.6,
/// §8.4): a harmony worked out from the melody, the melody clip's own chord notes, another MIDI clip, or a double.
/// Every part is its own monophonic render with the lead's words (a clip part: its own words, or the lead's when it
/// has none), lands on its OWN new track, and every landed line goes in ONE undo step.
///
/// Every default below was [A] until listening rounds H1-H3 and D (§4.6, §8.4, §10.1); the user's picks
/// (p2-sing-x9-picks, 2026-10-07) kept the level (H2, −4 dB) and the double's width (D, 0.4) and moved a part's
/// seed off the lead's (H3, `harmonySeedOffset`).
public struct SingJobPart: Sendable, Equatable {

    /// Where the part's notes come from (§4.2).
    public enum Kind: Sendable, Equatable {
        /// A part worked out from the melody (`HarmonyPlanner.derivedPart`): "a third above", "a sixth below"…
        /// Counted in `SingJobRequest.key`, else the song's estimated key (`singHarmonyNeedsKey` when it has none).
        case harmony(HarmonySpec)
        /// "Sing the chord's other notes" (`HarmonyPlanner.chordTonePart`): the melody clip's chord note `rank` from
        /// the top; where the clip has no such note, "`fillInterval` below" fills in, snapping by `fillChordSource`.
        case chordTones(rank: ChordToneRank, fillInterval: HarmonySpec.Interval,
                        fillChordSource: HarmonySpec.ChordSource)
        /// "Sing my other melody…": another MIDI clip, planned on its own; its own words, else the lead's.
        case clip(UUID)
        /// "Double the vocal" (§8.4): the lead's notes and words on another seed, to the side.
        case double
    }

    public var kind: Kind
    /// nil = the lead's voice (§2.4).
    public var voice: SingJobVoice?
    /// nil = the default: the lead's seed + `harmonySeedOffset` for a harmony, chord-notes or clip part (the
    /// user's Round H3 pick: its own performance, not the lead's); the lead's + `doubleSeedOffset` for a double
    /// [A: §8.4]. A double on the lead's own seed is refused (it is a copy). A seed given here is sung as given.
    public var seed: UInt64?
    /// Whole octaves, −2...2; nil = the part's own fit (§4.5: `HarmonyPlanner.range`, the song transposition fixed
    /// at the lead's, ties to the lead's octave). A double always sings at the lead's octave.
    public var octaveShift: Int?
    /// nil = "Harmony — third above · {voice}", "Vocals — double · {voice}" (§4.6, §8.4).
    public var trackName: String?
    /// −1...1; nil = the side default (§4.6).
    public var pan: Double?
    /// dB, −60...+6; nil = the default level (§4.6).
    public var volumeDb: Double?

    public init(_ kind: Kind, voice: SingJobVoice? = nil, seed: UInt64? = nil, octaveShift: Int? = nil,
                trackName: String? = nil, pan: Double? = nil, volumeDb: Double? = nil) {
        self.kind = kind
        self.voice = voice
        self.seed = seed
        self.octaveShift = octaveShift
        self.trackName = trackName
        self.pan = pan
        self.volumeDb = volumeDb
    }

    // MARK: The defaults ([A], §4.6 and §8.4; listening rounds decide)

    /// "Up to 3 harmony parts plus the lead" (§4.1 [A]); a double counts as a part.
    public static let maximumCount = 3
    /// §8.4: a double sings on the lead's seed + 7919 [A] (the same seed on the same notes is a bit-identical copy).
    public static let doubleSeedOffset: UInt64 = 7_919
    /// A harmony, chord-notes or clip part sings on the lead's seed + 2: a DIFFERENT performance from the lead's.
    /// The user's pick on the Sung Vocal Picks page, round H3 (take `seed-3`, 2026-10-07; p2-sing-x9-picks): the
    /// X9R harness sang that take on `SingJobRequestBuilder.firstTakeSeed + 2`, so a default job on that melody
    /// reproduces it. Before the pick a part sang on the lead's own seed. Distinct from every other seed a job
    /// uses: the lead's retry (+1, `retrySeed`), this part's retry (+3) and the double's (+7919).
    public static let harmonySeedOffset: UInt64 = 2
    /// §4.6: the first part on a side.
    public static let firstOnASidePan = 0.3
    public static let firstOnASideDb = -4.0
    /// §4.6: a second (or third) part on the same side.
    public static let moreOnASidePan = 0.5
    public static let moreOnASideDb = -6.0
    /// §8.4: the double.
    public static let doublePan = 0.4
    public static let doubleDb = -4.0
    /// The level range a caller may ask for, dB.
    public static let volumeDbRange: ClosedRange<Double> = -60...6

    /// Linear gain for a level in dB (`Track.volume`, 1 = unity): −4 dB is 0.631.
    public static func volume(db: Double) -> Double { pow(10, db / 20) }

    /// The track name a part lands under (§4.6, §8.4 [A]): "Harmony — third above · Built-in singer", with " · 2"
    /// for a second part on the same side; "Vocals — double · Built-in singer".
    public static func trackName(partName: String, voiceName: String, isDouble: Bool, sideRank: Int) -> String {
        if isDouble { return "Vocals — double · \(voiceName)" }
        return "Harmony — \(partName) · \(voiceName)" + (sideRank > 1 ? " · \(sideRank)" : "")
    }
}

// MARK: - The request builder

/// THE ONE place a planned unit becomes a facade request (design §2.4, §4.4). A harmony part (another job of
/// the same shape onto its own track) and the expression/language options all come through here, so the
/// bytes a v1 job sends can be pinned in one test.
public enum SingJobRequestBuilder {

    /// The seed behind every render the user picked (design §4.4): the first take of every job uses it.
    public static let firstTakeSeed: UInt64 = 20_260_924
    /// The sample rate a take is rendered at when the caller names none [A: the project's rate is part 2's to
    /// pass; 48 kHz is the facade's own example].
    public static let defaultOutputSampleRate = 48_000

    /// A fresh seed for "Try another take" (design §4.4, §7.4): one axis, the seed.
    public static func anotherTakeSeed() -> UInt64 {
        UInt64.random(in: 1...UInt64(UInt32.max))
    }

    /// The seed a unit's ONE retry uses after a non-finite or silent render (design §4.4): the take's + 1.
    public static func retrySeed(after seed: UInt64) -> UInt64 {
        seed &+ 1
    }

    /// The request for one planned unit.
    ///
    /// - `unit.notes` go as `startS`/`endS` (unit-relative seconds) and `midi` (the TARGET pitch, already
    ///   moved by whole octaves; nothing else moves a sung note, design §3.4);
    /// - `unit.words` go as `text` = the SUNG form (`SingWord.text`, never `typed`: W7-SD1 measured that the
    ///   facade re-splits a hyphen) and their `noteIndices`;
    /// - a word's language (`SingWord.language`, p2-sing-x3) goes as its `lang` (facadeVersion 2, design §7.2):
    ///   `"zh"`/`"yue"` on a Chinese word, nothing on an English one (`LyricLanguage.stored`, so even a literal
    ///   `"en"` is English), so an English unit is today's v1 request byte for byte;
    /// - lead and trail are `SingPlanner.leadSeconds` / `trailSeconds`.
    public static func phraseRequest(unit: SingUnit, voice: SingingVoiceReference, seed: UInt64,
                                     outputPath: String, outputSampleRate: Int = defaultOutputSampleRate,
                                     options: SingRenderOptions = .v1) -> SingingPhraseRequest {
        SingingPhraseRequest(
            voice: voice,
            notes: unit.notes.map { SingingPhraseNote(startS: $0.startSeconds, endS: $0.endSeconds, midi: $0.midi) },
            words: unit.words.map {
                SingingPhraseWord(text: $0.text, noteIndices: $0.noteIndices, lang: LyricLanguage.stored($0.language))
            },
            leadS: SingPlanner.leadSeconds, trailS: SingPlanner.trailSeconds,
            seed: seed, nSteps: options.nSteps, cfg: options.cfg,
            outputPath: outputPath, outputSampleRate: outputSampleRate)
    }

    /// The request body with its keys sorted: the request's CONTENT, byte for byte. (The client itself sends
    /// the same object unsorted; the facade parses JSON, so order never matters to it. Sorting is what makes
    /// the bytes a fixed function of the request, which a test can pin.)
    public static func canonicalBody(_ request: SingingPhraseRequest) throws -> Data {
        try JSONSerialization.data(withJSONObject: request.jsonObject(), options: [.sortedKeys])
    }

    /// The phrase cache key (design §4.3): sha256 of a canonical JSON of everything the render depends on —
    /// the facade version, the engine's commit and weights, the voice (id, reference sha256, prompt labels,
    /// label offset), the unit's notes and words (each word's `lang` too, with the body's facadeVersion 2, so a
    /// Chinese phrase never shares an English one's key), lead and trail, seed, nSteps, cfg and the output rate.
    /// NOT the output path (the cache names its file after this key) and NOT the reference's path (its
    /// sha256 is the content).
    public static func cacheKey(for request: SingingPhraseRequest, engine: SingEngineIdentity) throws -> String {
        var object = request.jsonObject()
        object["outputPath"] = nil
        if var voice = object["voice"] as? [String: Any] {
            voice["referencePath"] = nil
            object["voice"] = voice
        }
        object["engine"] = ["commit": engine.commit, "weightsRevision": engine.weightsRevision,
                            "weightsBytes": engine.weightsBytes]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the running engine says it is (`GET /health`'s `engine` object), for the cache key and the
/// provenance.
public struct SingEngineIdentity: Sendable, Equatable, Codable {
    public var commit: String
    public var weightsRevision: String
    public var weightsBytes: UInt64
    public var facadeVersion: Int

    public init(commit: String, weightsRevision: String, weightsBytes: UInt64, facadeVersion: Int) {
        self.commit = commit
        self.weightsRevision = weightsRevision
        self.weightsBytes = weightsBytes
        self.facadeVersion = facadeVersion
    }

    /// From a healthy `sing.sidecarStatus`. A field the facade did not report reads "" / 0, so two engines that
    /// both failed to report are NOT told apart by the key: the cache then trusts the facade version alone.
    public init(status: SingingSidecarStatus) {
        self.init(commit: status.commit ?? "", weightsRevision: status.weightsRevision ?? "",
                  weightsBytes: status.weightsBytes ?? 0,
                  facadeVersion: status.facadeVersion ?? SingingPhraseRequest.facadeVersion)
    }
}
