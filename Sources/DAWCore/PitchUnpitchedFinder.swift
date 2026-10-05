import Foundation

// UA-1 (the finder part) — SOUNDS WITH NO DETECTED NOTE: a breath, a consonant, or a
// piece of a sung note the detector did not commit to. Design
// `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md` §1.3 (U1, the
// audible threshold), §1.4 (U2, `NoteOrigin`), §1.5 (U3, which note a sound borrows),
// §1.10 (this function's shape and its tests); U3 confirmed by the user in §8.
//
// ⭐ **ONLY VOICED FRAMES MAKE NOTES, SO A BREATH HAS NOTHING TO GRAB** (§1.1). This
// finds the audible stretches BETWEEN notes, so the builders can add one `.unpitched`
// segment per stretch and the editor can draw it. It reads only fields every frame
// already carries (`frequencyHz`, `confidence`, `levelDbfs`): no detector change, no
// `analysisVersion` bump.
//
// ⭐ **RELATIVE TO THE CLIP'S OWN NOISE FLOOR, NEVER ABSOLUTE** (§1.2, §1.3). On the
// user's take an absolute −28.4 dBFS line found 38 sounds, and 0 on the SAME take
// 21.5 dB quieter; a line relative to the singing (V − 20) fell under the floor and
// cut the silence into 41 pieces. The floor-relative line (F + 9) kept Jaccard 0.969
// across that level change. `PitchUnpitchedFinderTests` holds the level-shift
// invariance as a gate (±N dB, the take's own −21.5 dB among them), and checks that
// each fixture is one an absolute line would get wrong.
//
// ⭐ **AN UNTOUCHED SOUND NEVER ENTERS THE PITCH CURVE; A MOVED ONE DOES** (U5 kept:
// natural-tuning design Revision 2, R21, which OVERRIDES that design's §2b.6 U-F2
// default this banner used to cite). That is enforced where the curve is built
// (`NoteSegment.entersPitchCurve`), not here: this file only finds sounds and says
// where to DRAW them. Its `anchorHz` is a drawing anchor, never a pitch estimate
// (§1.5), so a sound the user drags transposes whatever it is (a breath gets
// brighter or darker), which the editor says on screen (§1.7).
//
// Pure: no clock, no I/O, no store, no engine. It runs where the two note-table
// builders run, never on the render thread.

// MARK: - Where a segment came from

/// What made a note-table segment (design §1.4, U2). A DETECTION fact, like
/// `NoteSegment.detectedHz`: no edit changes it.
///
/// Declared beside the finder that makes `.unpitched`; stored as `NoteSegment.origin`
/// (UA-1 core), whose doc carries the contract (§1.4):
/// - declared LAST, after `isCleared` (`ClipRenderSignature` compares note BYTES and
///   `noteBytesAreExactlyItsFields` pins that the only padding is at the tail);
/// - encoded only when it is not `.detected`, so every stored table keeps its bytes
///   and its `contentStamp`;
/// - decoded through `init(storedValue:)`, so a missing OR unknown value reads as
///   `.detected` and a newer file still opens in an older build.
///
/// ⚠️ The digest's origin block (slot 6, `PitchEditSetDigest`) hashes each case by
/// an EXPLICIT byte, not by its position here: reordering these cases changes no key,
/// but a new case needs its own byte there.
///
/// The raw strings are WIRE values (the per-segment `origin` echo on
/// `clip.getPitchEdits`, UB-2) and are pinned by a test. Additive-only: never rename.
public enum NoteOrigin: String, Codable, Sendable, CaseIterable {
    /// A note `PitchNoteSplitter` found. Every segment written before UA-1 is one.
    case detected
    /// A `.transition` part: a slide into, between or out of held notes (UA-2
    /// stamps it; p2-seg §10 item 9).
    case transition
    /// A sound with no detected pitch (`PitchUnpitchedFinder`). Its `detectedHz` is
    /// the BORROWED drawing anchor (§1.5), and its `detectedConfidence` the median
    /// confidence of its own frames (§1.4).
    case unpitched

    /// The healing read (§1.4, the `NoteSegment.init` precedent): a missing value or
    /// one this build does not know is `.detected`, never a decode failure.
    public init(storedValue: String?) {
        self = storedValue.flatMap(NoteOrigin.init(rawValue:)) ?? .detected
    }
}

// MARK: - The finder

/// The finder (design §1.3, §1.5, §1.10): frames and notes in, sounds out.
///
/// **The rule.**
///  1. **F, the floor**: the 10th percentile of `levelDbfs` over the clip's UNVOICED
///     frames (`frequencyHz == nil`), nearest rank, with a `nil` level (digital
///     silence) ranking below every level.
///  2. **A no-note frame** is one outside every note (tested at the frame's
///     midpoint). It is **audible** when `levelDbfs − F ≥ marginDb` (9 dB).
///     ⚠️ Two populations: F is measured on UNVOICED frames; audibility is tested on
///     NO-NOTE frames, which also include the voiced frames of runs too short to be
///     a note.
///  3. **A sound** is a stretch of audible no-note frames. Dips of ≤ 2 frames are
///     bridged, but never across a note and never across a gap in the analysis (the
///     `voicedRuns` 1.5-period rule). It is kept when it lasts ≥
///     `PitchAutoCorrect.minimumNoteSeconds` (4 frames at 62.5 fps), and its span is
///     `[first.timeSeconds, last.timeSeconds + 1/frameRateHz)`, clamped to its
///     neighbouring notes' edges so it never overlaps one.
///  4. **Its anchor** is the `hz` of the NEARER lending note. A tie goes to the
///     FOLLOWING note (the user's rule): both gaps are ≤ 2 frames (it touches both),
///     or the gaps are equal at frame resolution. At a clip edge the only neighbour
///     lends.
///
/// **Guards**, in this order, each returning no sounds and a named reason (§1.3):
/// `notEnoughQuiet` (under 1 s of unvoiced frames with a level: F cannot be
/// measured), `tooNoisy` (V − F < 12 dB, V the median voiced level), `noNotes`
/// (nothing to borrow a pitch from).
///
/// ⭐ **THE FRAME RATE IS ALWAYS THE DETECTION'S OWN** (`frameRateHz`), never 62.5:
/// every frame count here derives from it.
public enum PitchUnpitchedFinder {

    // MARK: - The constants — each is the ONE home for its number

    /// **The margin above the floor, dB** (U1, §1.3): a no-note frame at `F + 9` or
    /// louder is audible. Where the floor's shoulder meets the flat run of real
    /// sounds in the take's histogram; F + 6 and F + 12 do worse on the level test
    /// (Jaccard 0.952 and 0.948 against 0.969). This code, on the product's own frames
    /// of that take (the env-gated port check in `PitchUnpitchedFinderTests`), reads
    /// F = −37.42 dBFS and 38 sounds over 6.19 s, 27 of them borrowing the following
    /// note: the design's replica numbers. ⚠️ TUNED ON ONE TAKE: it is the wire knob
    /// `marginDb` (§1.10) until a second take re-measures it.
    public static let defaultMarginDb: Double = 9

    /// **The floor's percentile** (U1): the 10th, over unvoiced frames.
    public static let floorPercentile: Double = 0.10

    /// **The most quiet frames a sound bridges** (§1.3): a dip of ≤ 2 frames (32 ms at
    /// 62.5 fps) stays inside the sound, so a consonant is not cut in pieces by a
    /// blink. It is also what "touches" means for the anchor tie (§1.5): a gap to a
    /// note that the finder would have bridged had the note been a sound.
    public static let maximumBridgedDipFrames: Int = 2

    /// **The least quiet the floor needs, seconds** (the `notEnoughQuiet` guard): under
    /// one second of unvoiced frames with a level, F is not a measurement.
    public static let minimumQuietSeconds: Double = 1

    /// **The least headroom between the singing and the floor, dB** (the `tooNoisy`
    /// guard): below 12 dB the floor and the singing overlap. The take measured 17.7.
    public static let minimumHeadroomDb: Double = 12

    // MARK: - Input

    /// One note the sounds sit between (design §1.10): a note part in the builders, a
    /// STORED segment in the merge verb, so the user's own splits count.
    public struct Note: Sendable, Equatable {
        /// Source-file seconds, the `ClipPitchFrame.timeSeconds` domain.
        public let startSeconds: Double
        public let endSeconds: Double
        /// The pitch a sound beside it borrows, Hz.
        public let hz: Double
        /// Whether a sound may borrow `hz`. Every note COVERS its time either way;
        /// the merge verb passes `false` for a stored `.unpitched` segment, which is
        /// covered time but never a pitch to borrow (UB-1). A non-finite or
        /// non-positive `hz` never lends, whatever this says: no 0 is ever stored.
        public let lendsPitch: Bool

        public init(startSeconds: Double, endSeconds: Double, hz: Double,
                    lendsPitch: Bool = true) {
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.hz = hz
            self.lendsPitch = lendsPitch
        }

        /// A note part, as the two builders see it: its span and its own median.
        public init(part: NotePart) {
            self.init(startSeconds: part.startSeconds, endSeconds: part.endSeconds,
                      hz: part.centreHz)
        }
    }

    // MARK: - Output

    /// Which neighbour a sound borrowed its anchor from.
    public enum Side: String, Sendable, Equatable, CaseIterable {
        case previous
        case following
    }

    /// One sound: an audible stretch with no note, and where to draw it.
    public struct Sound: Sendable, Equatable {
        /// Source-file seconds. `endSeconds` is exclusive, like a note's.
        public let startSeconds: Double
        public let endSeconds: Double
        /// The lending note's `hz`: where the sound is DRAWN, never what it sounds
        /// like (§1.5). Always a real positive frequency.
        public let anchorHz: Double
        public let borrowedFrom: Side
        /// The lending note's index in the `notes` the caller passed, so a caller can
        /// name it (the wire's `borrowedFrom` carries a segment id this type does not
        /// know).
        public let lenderIndex: Int
        /// Median `confidence` of the sound's own frames, bridged dips included —
        /// what `detectedConfidence` becomes for an `.unpitched` segment (§1.4).
        public let medianConfidence: Double
        /// Frames from its first audible frame to its last, bridged dips included.
        public let frameCount: Int
    }

    /// Why the finder returned no sounds on purpose. Raw strings are wire values
    /// (`skippedReason`, §1.10).
    public enum SkipReason: String, Sendable, Equatable, CaseIterable {
        /// Under `minimumQuietSeconds` of unvoiced frames with a level (or no usable
        /// frame rate): F cannot be measured.
        case notEnoughQuiet
        /// The singing is less than `minimumHeadroomDb` above the floor (F-hum).
        case tooNoisy
        /// No note lends a pitch, so nothing could anchor a sound (§1.5).
        case noNotes
    }

    /// What the floor measured.
    public enum Floor: Sendable, Equatable {
        /// A level, dBFS.
        case level(Double)
        /// At least a tenth of the unvoiced frames are exact digital silence (a
        /// hard-gated take), so the 10th percentile IS silence: every frame with any
        /// level clears it, and only the silence itself is never a sound.
        case digitalSilence
    }

    /// Everything the finder decided, for the builders, the merge verb and the wire
    /// echo (`floorDbfs`, `thresholdDbfs`, `skippedReason`).
    public struct Result: Sendable, Equatable {
        /// In time order. Empty whenever `skipped` is set.
        public let sounds: [Sound]
        /// `nil` exactly when F could not be measured (`notEnoughQuiet`).
        public let floor: Floor?
        /// The margin actually applied (a non-finite request heals to the default).
        public let marginDb: Double
        /// V, the median level of the voiced frames that have one; `nil` when none do
        /// (the `tooNoisy` guard is then not evaluated).
        public let singingDbfs: Double?
        public let skipped: SkipReason?

        /// F in dBFS, or `nil` when it is digital silence or was not measured.
        public var floorDbfs: Double? {
            if case .level(let dbfs) = floor { return dbfs }
            return nil
        }

        /// `F + marginDb`, or `nil` when F is not a level. With a `.digitalSilence`
        /// floor every levelled no-note frame is audible.
        public var thresholdDbfs: Double? { floorDbfs.map { $0 + marginDb } }
    }

    // MARK: - Finding sounds

    /// Find the sounds between `notes` (design §1.10).
    ///
    /// - Parameters:
    ///   - frames: a detection's frames, voiced and unvoiced, in any order. A frame
    ///     with a non-finite time is dropped; a non-finite level reads as no level.
    ///   - frameRateHz: the detection's own reported rate.
    ///   - notes: what already covers time, in any order; see `Note.lendsPitch`.
    ///   - marginDb: the wire knob; a non-finite value heals to `defaultMarginDb`.
    ///     Its range is the caller's to validate (UB-2), not this function's.
    public static func sounds(in frames: [ClipPitchFrame], frameRateHz: Double,
                              notes: [Note],
                              marginDb: Double = defaultMarginDb) -> Result {
        sounds(in: frames, frameRateHz: frameRateHz, notes: notes, marginDb: marginDb,
               rule: .product)
    }

    /// The same over a whole `clip.detectPitch` response, at the result's OWN rate.
    public static func sounds(in result: PitchDetectionResult, notes: [Note],
                              marginDb: Double = defaultMarginDb) -> Result {
        sounds(in: result.frames, frameRateHz: result.frameRateHz, notes: notes,
               marginDb: marginDb)
    }

    // MARK: - The rule, as one value

    /// The rule's numbers in one value (the `PitchNoteSplitter.Rule` precedent).
    /// `product` is built from the named constants above and from
    /// `PitchAutoCorrect.minimumNoteSeconds`, and from nothing else. A test builds a
    /// PLANTED rule (one constant moved) to prove a threshold pin can fail, without
    /// editing this file.
    struct Rule: Sendable, Equatable {
        var floorPercentile: Double
        var maximumBridgedDipFrames: Int
        var minimumSoundSeconds: Double
        var minimumQuietSeconds: Double
        var minimumHeadroomDb: Double

        static let product = Rule(
            floorPercentile: PitchUnpitchedFinder.floorPercentile,
            maximumBridgedDipFrames: PitchUnpitchedFinder.maximumBridgedDipFrames,
            minimumSoundSeconds: PitchAutoCorrect.minimumNoteSeconds,
            minimumQuietSeconds: PitchUnpitchedFinder.minimumQuietSeconds,
            minimumHeadroomDb: PitchUnpitchedFinder.minimumHeadroomDb)
    }

    /// A frame's level, or `nil` for digital silence or a non-finite reading.
    static func level(of frame: ClipPitchFrame) -> Double? {
        guard let dbfs = frame.levelDbfs, dbfs.isFinite else { return nil }
        return dbfs
    }

    /// F (U1): nearest rank `round(p·(n−1))` over the unvoiced frames, the
    /// `Loudness.loudnessRange` convention, so F is always one frame's own level and
    /// a level shift of N dB moves it by exactly N. A `nil` level ranks below every
    /// level. `nil` when under `minimumQuietSeconds` of those frames have a level.
    static func measureFloor(of ordered: [ClipPitchFrame], frameRateHz rate: Double,
                             rule: Rule) -> Floor? {
        let unvoiced = ordered.filter { $0.frequencyHz == nil }.map(level(of:))
        let levels = unvoiced.compactMap { $0 }.sorted()
        guard !levels.isEmpty,
              Double(levels.count) >= rule.minimumQuietSeconds * rate else { return nil }
        let silent = unvoiced.count - levels.count
        let raw = (rule.floorPercentile * Double(unvoiced.count - 1)).rounded()
        let rank = raw.isFinite ? min(max(Int(raw), 0), unvoiced.count - 1) : 0
        return rank < silent ? .digitalSilence : .level(levels[rank - silent])
    }

    /// The finder under an explicit rule. `Rule.product` is the ONLY rule the product
    /// uses.
    static func sounds(in frames: [ClipPitchFrame], frameRateHz: Double, notes: [Note],
                       marginDb: Double, rule: Rule) -> Result {
        let margin = PitchCorrectionMath.finite(marginDb, default: defaultMarginDb)
        let rate = PitchCorrectionMath.finite(frameRateHz, default: 0)
        let ordered = frames.filter { $0.timeSeconds.isFinite }
            .sorted { $0.timeSeconds < $1.timeSeconds }
        let singing = PitchCorrectionMath.median(
            ordered.compactMap { $0.frequencyHz == nil ? nil : level(of: $0) })
        func skipped(_ reason: SkipReason, floor: Floor?) -> Result {
            Result(sounds: [], floor: floor, marginDb: margin, singingDbfs: singing,
                   skipped: reason)
        }

        // The three guards, in the design's order (§1.3).
        guard rate > 0, let floor = measureFloor(of: ordered, frameRateHz: rate, rule: rule) else {
            return skipped(.notEnoughQuiet, floor: nil)
        }
        if case .level(let floorDbfs) = floor, let singing,
           singing - floorDbfs < rule.minimumHeadroomDb {
            return skipped(.tooNoisy, floor: floor)
        }
        // Every usable note covers its time; only a lending one anchors a sound.
        let usable = notes.indices.filter {
            notes[$0].startSeconds.isFinite && notes[$0].endSeconds.isFinite
                && notes[$0].endSeconds > notes[$0].startSeconds
        }
        let lenders = usable.filter {
            notes[$0].lendsPitch && notes[$0].hz.isFinite && notes[$0].hz > 0
        }
        guard !lenders.isEmpty else { return skipped(.noNotes, floor: floor) }

        let period = 1 / rate
        let covered = coveredSpans(usable.map {
            (start: notes[$0].startSeconds, end: notes[$0].endSeconds)
        })
        // Audible (U1): the DIFFERENCE form, so a level shift of N dB, which moves a
        // frame's level and F by the same N, cannot move a frame across the line.
        func isAudible(_ frame: ClipPitchFrame) -> Bool {
            guard let dbfs = level(of: frame) else { return false }
            switch floor {
            case .level(let floorDbfs): return dbfs - floorDbfs >= margin
            case .digitalSilence: return true
            }
        }

        // The scan: stretches of audible no-note frames, as frame-index ranges.
        var stretches: [(first: Int, last: Int)] = []
        var open: (first: Int, last: Int)?
        var dip = 0
        func close() {
            if let stretch = open { stretches.append(stretch) }
            open = nil
            dip = 0
        }
        var next = 0                 // the first covered span not yet passed
        var previousTime: Double?
        for index in ordered.indices {
            let time = ordered[index].timeSeconds
            let middle = time + period / 2
            // A jump of more than 1.5 periods is a gap in the analysis: nothing was
            // measured, so nothing is bridged (the `voicedRuns` rule).
            if let previousTime, time - previousTime > period * 1.5 { close() }
            previousTime = time
            // A note that starts at or before this frame's midpoint either holds this
            // frame or lies wholly between the previous frame and this one. Both end
            // the open stretch: bridging never crosses a note.
            var isCovered = false
            while next < covered.count, covered[next].start <= middle {
                if covered[next].end > middle { isCovered = true; break }
                close()
                next += 1
            }
            if isCovered { close(); continue }
            if isAudible(ordered[index]) {
                if let stretch = open { open = (stretch.first, index) } else { open = (index, index) }
                dip = 0
            } else if open != nil {
                dip += 1
                if dip > rule.maximumBridgedDipFrames { close() }
            }
        }
        close()

        var sounds: [Sound] = []
        for stretch in stretches {
            let firstTime = ordered[stretch.first].timeSeconds
            let lastTime = ordered[stretch.last].timeSeconds
            var start = firstTime
            var end = lastTime + period
            // Clamp to the neighbouring notes' edges. Frame-aligned parts abut exactly
            // after this; a stored segment split off the frame grid (the merge verb)
            // can overlap a frame's span by less than half a frame, and a sound that
            // overlapped it would be trimmed or gapped by `PitchEditSet.canonical`.
            for span in covered where span.start < end && span.end > start {
                if span.end <= firstTime + period / 2 { start = max(start, span.end) }
                if span.start >= lastTime + period / 2 { end = min(end, span.start) }
            }
            // The `voicedRuns` keep rule, on the span actually stored.
            guard end - start >= rule.minimumSoundSeconds else { continue }
            guard let anchor = anchor(start: start, end: end, notes: notes,
                                      lenders: lenders, period: period, rule: rule) else {
                continue
            }
            let confidences = ordered[stretch.first...stretch.last].map(\.confidence)
                .filter(\.isFinite)
            sounds.append(Sound(
                startSeconds: start,
                endSeconds: end,
                anchorHz: notes[anchor.index].hz,
                borrowedFrom: anchor.side,
                lenderIndex: anchor.index,
                medianConfidence: PitchCorrectionMath.median(confidences) ?? 0,
                frameCount: stretch.last - stretch.first + 1))
        }
        return Result(sounds: sounds, floor: floor, marginDb: margin, singingDbfs: singing,
                      skipped: nil)
    }

    /// U3 (§1.5): the NEARER lending neighbour; a tie goes to the FOLLOWING one. A
    /// tie is a sound that touches both (each gap ≤ `maximumBridgedDipFrames`
    /// periods) or two gaps equal at frame resolution (within half a period, never
    /// `==`: frame times are sums of periods and differ in the last bits). At a clip
    /// edge the only neighbour lends. `nil` only when no lender sits on either side,
    /// which the `noNotes` guard has already ruled out.
    static func anchor(start: Double, end: Double, notes: [Note], lenders: [Int],
                       period: Double, rule: Rule) -> (index: Int, side: Side)? {
        let middle = (start + end) / 2
        var previous: Int?
        var following: Int?
        for index in lenders {
            let note = notes[index]
            if note.endSeconds <= middle {
                if previous.map({ note.endSeconds > notes[$0].endSeconds }) ?? true {
                    previous = index
                }
            } else if note.startSeconds >= middle {
                if following.map({ note.startSeconds < notes[$0].startSeconds }) ?? true {
                    following = index
                }
            }
        }
        switch (previous, following) {
        case (nil, nil):
            return nil
        case (let previous?, nil):
            return (previous, .previous)
        case (nil, let following?):
            return (following, .following)
        case (let previous?, let following?):
            let before = max(0, start - notes[previous].endSeconds)
            let after = max(0, notes[following].startSeconds - end)
            let touching = (Double(rule.maximumBridgedDipFrames) + 0.5) * period
            let tie = (before <= touching && after <= touching)
                || abs(before - after) < period / 2
            return tie || after < before ? (following, .following) : (previous, .previous)
        }
    }

    /// The union of the notes' spans, sorted and disjoint. Abutting or overlapping
    /// notes become one covered span; the finder asks only "is this time a note?".
    static func coveredSpans(_ spans: [(start: Double, end: Double)])
    -> [(start: Double, end: Double)] {
        var union: [(start: Double, end: Double)] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = union.last, span.start <= last.end {
                union[union.count - 1].end = max(last.end, span.end)
            } else {
                union.append(span)
            }
        }
        return union
    }
}
