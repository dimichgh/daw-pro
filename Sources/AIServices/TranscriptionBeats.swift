import Foundation
import DAWCore
import WhisperKit

// MARK: - What a transcription looks like once it is on the project timeline

/// One recognised word, placed on the project timeline.
///
/// **Constructed only by `TranscriptionBeatMapper`.** The memberwise
/// initialiser is `fileprivate` and the type is `Encodable` — deliberately NOT
/// `Codable`, so there is no synthesised decode-side back door either. A second
/// producer of "what beat does this word land on" is therefore
/// *unrepresentable* rather than merely absent, the same shape as
/// `ArrangeDropSnap.ResolvedDropBeat`.
public struct TranscribedWord: Sendable, Equatable, Encodable {
    /// The word exactly as the recogniser emitted it, including the leading
    /// space and trailing punctuation it carries (`" The"`, `" dog."`).
    /// Not normalised here: display and matching policy belong to the caller.
    public let text: String
    /// Start in seconds **from the beginning of the source file** — not from
    /// the requested sub-range. See `Transcription.rangeStartSeconds`.
    public let startSeconds: Double
    /// End in seconds from the beginning of the source file.
    public let endSeconds: Double
    /// Start on the **project timeline**, in beats.
    public let startBeat: Double
    /// End on the project timeline, in beats.
    public let endBeat: Double
    /// Recogniser confidence for this word, 0…1.
    public let confidence: Double

    fileprivate init(
        text: String,
        startSeconds: Double,
        endSeconds: Double,
        startBeat: Double,
        endBeat: Double,
        confidence: Double
    ) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.startBeat = startBeat
        self.endBeat = endBeat
        self.confidence = confidence
    }
}

/// One recogniser segment (roughly a phrase or sentence), placed on the project
/// timeline. Same construction rule as `TranscribedWord`.
public struct TranscribedSegment: Sendable, Equatable, Encodable {
    /// Segment text as the recogniser emitted it (leading space kept).
    public let text: String
    /// Start in seconds from the beginning of the source file.
    public let startSeconds: Double
    /// End in seconds from the beginning of the source file.
    public let endSeconds: Double
    /// Start on the project timeline, in beats.
    public let startBeat: Double
    /// End on the project timeline, in beats.
    public let endBeat: Double
    /// The segment's words. Empty when the recogniser produced no word-level
    /// alignment for this segment (it is `nil` upstream, never an error).
    /// m23-n3f: when EVERY segment is wordless the cause may be the model
    /// rather than the audio — read `Transcription.supportsWordTimestamps` /
    /// `wordTimestampsUnavailable` before concluding the singer said nothing,
    /// and since m23-ef `Transcription.wordTimestampSupport` /
    /// `wordTimestampsUnverified` for the case where the model never said.
    public let words: [TranscribedWord]

    fileprivate init(
        text: String,
        startSeconds: Double,
        endSeconds: Double,
        startBeat: Double,
        endBeat: Double,
        words: [TranscribedWord]
    ) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.startBeat = startBeat
        self.endBeat = endBeat
        self.words = words
    }
}

/// A finished transcription: the text, and every segment and word placed on the
/// project's beat timeline.
public struct Transcription: Sendable, Equatable, Encodable {
    /// The full text, assembled from the segments and trimmed. Derived from
    /// exactly what `segments` exposes, so the two can never disagree.
    public let text: String
    /// BCP-47-ish language code the recogniser reported (`"en"`), or `""` when
    /// it reported none.
    public let language: String
    /// Every segment, in recogniser order.
    public let segments: [TranscribedSegment]
    /// Directory name of the model that produced this — the model's identity,
    /// per `WhisperModelDescriptor.variantDirectoryName`.
    public let modelVariantDirectoryName: String
    /// Where in the **source file** the transcribed audio began, in seconds.
    /// `0` when the whole file was read.
    public let rangeStartSeconds: Double
    /// Where that same instant sits on the **project timeline**, in beats.
    /// Every beat below is measured forward from here.
    public let anchorBeat: Double
    /// Whether the MODEL that produced this can emit word-level timings at all
    /// (m23-n3f). A property of the model, decided when it was resolved —
    /// **never inferred from `words.isEmpty`**, which is content-dependent (an
    /// instrumental clip legitimately has no words) and would make the answer
    /// depend on the audio instead of on the weights.
    ///
    /// m23-ef: **computed from `wordTimestampSupport`**, so the two cannot
    /// disagree. Same name, same type, same meaning, still on the wire (see
    /// `encode(to:)` — synthesis would have dropped it once it stopped being
    /// stored). `.unknown` still reads `true`, deliberately.
    public var supportsWordTimestamps: Bool { wordTimestampSupport != .unsupported }
    /// The three-state capability of the model that produced this (m23-ef):
    /// `.supported` (it said yes), `.unsupported` (it said no), `.unknown`
    /// (nothing on disk could be asked). THE stored source of truth here.
    ///
    /// This is the additive field m23-ef exists for: `supportsWordTimestamps`
    /// alone cannot tell a caller whether an empty word list was promised to be
    /// impossible, promised to be possible, or simply never spoken for.
    public let wordTimestampSupport: WordTimestampSupport
    /// The teaching message when `supportsWordTimestamps` is false, `nil`
    /// otherwise — `WhisperModelDescriptor.wordTimestampsUnavailableExplanation`
    /// verbatim, so the wording has one home. This is what a caller shows
    /// INSTEAD of silently rendering an empty word list.
    public let wordTimestampsUnavailable: String?

    /// The wording for the `.unknown` case, carried unconditionally and shown
    /// conditionally — see `wordTimestampsUnverified`, which is what callers
    /// read. Deliberately NOT public and NOT encoded: publishing it would put
    /// the caveat on every `.mlpackage` transcription regardless of outcome,
    /// which is the alarm fatigue m23-n3f refused and m23-ef must not
    /// re-introduce.
    private let wordTimestampsUnverifiedExplanation: String?

    /// Every word from every segment, in order. `segments` is the storage;
    /// this is the flat view n2b's wire payload will want.
    public var words: [TranscribedWord] { segments.flatMap(\.words) }

    /// The UNKNOWN-case caution (m23-ef): non-nil only when the model's
    /// capability could not be determined **and** this run came back with
    /// segments but not one word — the shape where an unreadable capability is
    /// genuinely the suspect.
    ///
    /// ⚠️ **`words.isEmpty` decides whether to SHOW a caution. It never decides
    /// the CAPABILITY** — that is `wordTimestampSupport`, read from the model
    /// on disk, and m23-n3f's core law (an instrumental clip has no words
    /// either, so inferring capability from emptiness would blame the weights
    /// for the audio). The two uses look similar and are not: one is a
    /// question about the model, the other about this run's output.
    ///
    /// `!segments.isEmpty` is load-bearing and not defensive noise. Both
    /// `words.isEmpty` and "every segment is wordless" are vacuously true when
    /// the recogniser returned NOTHING — silence, an instrumental, an empty
    /// range — and firing there would put the caution exactly where it has the
    /// least to do with word timings. Requiring at least one segment means the
    /// claim is "it heard something and still produced no words", which is the
    /// only shape worth a caution.
    public var wordTimestampsUnverified: String? {
        guard wordTimestampSupport == .unknown, !segments.isEmpty, words.isEmpty else { return nil }
        return wordTimestampsUnverifiedExplanation
    }

    fileprivate init(
        text: String,
        language: String,
        segments: [TranscribedSegment],
        modelVariantDirectoryName: String,
        rangeStartSeconds: Double,
        anchorBeat: Double,
        wordTimestampSupport: WordTimestampSupport,
        wordTimestampsUnavailable: String?,
        wordTimestampsUnverifiedExplanation: String?
    ) {
        self.text = text
        self.language = language
        self.segments = segments
        self.modelVariantDirectoryName = modelVariantDirectoryName
        self.rangeStartSeconds = rangeStartSeconds
        self.anchorBeat = anchorBeat
        self.wordTimestampSupport = wordTimestampSupport
        self.wordTimestampsUnavailable = wordTimestampsUnavailable
        self.wordTimestampsUnverifiedExplanation = wordTimestampsUnverifiedExplanation
    }

    // MARK: Encoding — hand-written, and the reason is specific (m23-ef)

    /// `clip.transcribe` returns this value VERBATIM, and m23-ef made
    /// `supportsWordTimestamps` computed. Swift synthesizes `Encodable` over
    /// stored properties only, so synthesis would have silently REMOVED a live
    /// wire field — the one thing the additive-only rule forbids. It is
    /// therefore encoded explicitly, as a derived mirror of
    /// `wordTimestampSupport`. `wordTimestampsUnverified` is likewise computed
    /// and likewise encoded.
    ///
    /// ⚠️ Hand-writing this means a new stored property will NOT reach the wire
    /// by itself. `TranscriptionEncodingTests` asserts the exact key SET so
    /// that omission fails loudly instead of shipping.
    private enum CodingKeys: String, CodingKey {
        case text
        case language
        case segments
        case modelVariantDirectoryName
        case rangeStartSeconds
        case anchorBeat
        case supportsWordTimestamps
        case wordTimestampSupport
        case wordTimestampsUnavailable
        case wordTimestampsUnverified
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(language, forKey: .language)
        try container.encode(segments, forKey: .segments)
        try container.encode(modelVariantDirectoryName, forKey: .modelVariantDirectoryName)
        try container.encode(rangeStartSeconds, forKey: .rangeStartSeconds)
        try container.encode(anchorBeat, forKey: .anchorBeat)
        // Derived. Present because it is LIVE — see the note above.
        try container.encode(supportsWordTimestamps, forKey: .supportsWordTimestamps)
        try container.encode(wordTimestampSupport, forKey: .wordTimestampSupport)
        // `encodeIfPresent` for both optionals, matching what synthesis did:
        // a nil message OMITS the key rather than writing `null`, which is what
        // the `wordTimestampsUnavailable?` in `clip.transcribe`'s documented
        // response shape means and what MCP callers already read.
        try container.encodeIfPresent(wordTimestampsUnavailable, forKey: .wordTimestampsUnavailable)
        try container.encodeIfPresent(wordTimestampsUnverified, forKey: .wordTimestampsUnverified)
    }
}

// MARK: - The one home for recogniser-seconds → project-beats

/// THE single place that turns WhisperKit's timings into project time.
///
/// **One home, and it is not this file's.** The seconds↔beats rule itself lives
/// in `DAWCore.TempoMap`; nothing here recomputes it. Every beat below comes out
/// of `TempoMap.beat(from:elapsedSeconds:)`, which is `S⁻¹(S(anchor) + Δt)` —
/// correct across tempo-map segment boundaries, not a per-position multiply.
/// (The npm `tempo-lint` suite mechanically forbids a second copy of that
/// arithmetic anywhere under `Sources/`; this file is clean by construction
/// because it contains no tempo arithmetic at all.)
///
/// **Two offsets, and they are not the same offset.** WhisperKit returns times
/// relative to the samples it was *given*. When a sub-range was read, that is
/// relative to `rangeStartSeconds`, not to the file. So:
///
/// * seconds are reported **file-absolute**: `rangeStartSeconds + Δt`
///   (a plain shift along one axis — no tempo involved);
/// * beats are reported **project-absolute**: `beat(from: anchorBeat,
///   elapsedSeconds: Δt)` — `Δt` is elapsed time *since the anchor*, so
///   `rangeStartSeconds` must NOT appear in it. Adding it there would
///   double-count the file offset into musical time, which is invisible whenever
///   the range starts at 0.
///
/// Nothing is clamped to the requested range: a recogniser timing that runs past
/// the range end is reported where it actually is. Clamping is presentation
/// policy and would hide exactly the offset mistakes above.
public enum TranscriptionBeatMapper {
    /// Map a WhisperKit result set onto the project timeline.
    ///
    /// - Parameters:
    ///   - results: The recogniser's output. **Flattened, never `.first`** —
    ///     chunked audio comes back as several results and taking the first
    ///     would silently drop the tail.
    ///   - rangeStartSeconds: Where in the source file the transcribed audio
    ///     began (what was passed as `startTime:`). `0` for a whole file.
    ///   - anchorBeat: The project beat that `rangeStartSeconds` sits on.
    ///   - tempoMap: The project tempo map.
    ///   - modelVariantDirectoryName: Identity of the model that produced this.
    ///   - wordTimestampSupport: Whether that model can emit word timings at
    ///     all (m23-n3f; three-state since m23-ef). Defaults to `.supported` —
    ///     the shape of every model this mapper had before the capability was
    ///     checkable, and the direction that never invents a warning.
    ///     `WhisperTranscriber.makeTranscription` is the production caller and
    ///     passes the resolved model's real value. **It replaced a
    ///     `supportsWordTimestamps: Bool` parameter rather than joining it:
    ///     two parameters that can disagree is exactly what m23-ef removes.**
    ///   - wordTimestampsUnavailable: The teaching message for the
    ///     `.unsupported` case, from
    ///     `WhisperModelDescriptor.wordTimestampsUnavailableExplanation`.
    ///   - wordTimestampsUnverifiedExplanation: The wording for the `.unknown`
    ///     case, from `WhisperModelDescriptor.wordTimestampsUnverifiedExplanation`.
    ///     Carried in unconditionally; `Transcription.wordTimestampsUnverified`
    ///     decides whether it is shown, because that decision needs the
    ///     mapped segments and this one does not.
    public static func map(
        results: [TranscriptionResult],
        rangeStartSeconds: Double,
        anchorBeat: Double,
        tempoMap: TempoMap,
        modelVariantDirectoryName: String,
        wordTimestampSupport: WordTimestampSupport = .supported,
        wordTimestampsUnavailable: String? = nil,
        wordTimestampsUnverifiedExplanation: String? = nil
    ) -> Transcription {
        var mapped: [TranscribedSegment] = []
        for result in results {
            for segment in result.segments {
                let words = (segment.words ?? []).map { word in
                    TranscribedWord(
                        text: word.word,
                        startSeconds: fileSeconds(word.start, rangeStartSeconds: rangeStartSeconds),
                        endSeconds: fileSeconds(word.end, rangeStartSeconds: rangeStartSeconds),
                        startBeat: projectBeat(word.start, anchorBeat: anchorBeat, tempoMap: tempoMap),
                        endBeat: projectBeat(word.end, anchorBeat: anchorBeat, tempoMap: tempoMap),
                        confidence: Double(word.probability)
                    )
                }
                mapped.append(
                    TranscribedSegment(
                        text: segment.text,
                        startSeconds: fileSeconds(segment.start, rangeStartSeconds: rangeStartSeconds),
                        endSeconds: fileSeconds(segment.end, rangeStartSeconds: rangeStartSeconds),
                        startBeat: projectBeat(segment.start, anchorBeat: anchorBeat, tempoMap: tempoMap),
                        endBeat: projectBeat(segment.end, anchorBeat: anchorBeat, tempoMap: tempoMap),
                        words: words
                    )
                )
            }
        }
        return Transcription(
            text: mapped.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
            language: results.first?.language ?? "",
            segments: mapped,
            modelVariantDirectoryName: modelVariantDirectoryName,
            rangeStartSeconds: rangeStartSeconds,
            anchorBeat: anchorBeat,
            wordTimestampSupport: wordTimestampSupport,
            wordTimestampsUnavailable: wordTimestampsUnavailable,
            wordTimestampsUnverifiedExplanation: wordTimestampsUnverifiedExplanation
        )
    }

    /// Recogniser time → seconds from the start of the **file**. A shift along
    /// the seconds axis only; the tempo map has no business here.
    private static func fileSeconds(_ elapsed: Float, rangeStartSeconds: Double) -> Double {
        rangeStartSeconds + Double(elapsed)
    }

    /// Recogniser time → the **project** beat, through `DAWCore`'s converter.
    /// `elapsed` is time since the anchor, so `rangeStartSeconds` is absent by
    /// design (see the type's note on the two offsets).
    private static func projectBeat(
        _ elapsed: Float,
        anchorBeat: Double,
        tempoMap: TempoMap
    ) -> Double {
        tempoMap.beat(from: anchorBeat, elapsedSeconds: Double(elapsed))
    }
}
