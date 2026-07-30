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

    /// Every word from every segment, in order. `segments` is the storage;
    /// this is the flat view n2b's wire payload will want.
    public var words: [TranscribedWord] { segments.flatMap(\.words) }

    fileprivate init(
        text: String,
        language: String,
        segments: [TranscribedSegment],
        modelVariantDirectoryName: String,
        rangeStartSeconds: Double,
        anchorBeat: Double
    ) {
        self.text = text
        self.language = language
        self.segments = segments
        self.modelVariantDirectoryName = modelVariantDirectoryName
        self.rangeStartSeconds = rangeStartSeconds
        self.anchorBeat = anchorBeat
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
    public static func map(
        results: [TranscriptionResult],
        rangeStartSeconds: Double,
        anchorBeat: Double,
        tempoMap: TempoMap,
        modelVariantDirectoryName: String
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
            anchorBeat: anchorBeat
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
