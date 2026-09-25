import Foundation
import DAWCore

/// What the timeline's render light watches (M5 ii-e; p2-render-indicator).
///
/// `ContentView` hands every new value to `.onChange`, which calls
/// `AppModel.noteStretchEdit()`: a bounded poll of the engine's per-clip render
/// status, and the ONLY thing that makes a clip shimmer while its offline render
/// is pending (or show red when it failed). A value that fails to change when a
/// render is re-keyed leaves that clip silent (it schedules as silence while
/// rendering) with nothing on screen saying why.
///
/// ⛔ **THE DEFECT THIS REPLACES: ONE FACT, TWO PREDICATES, A THIRD TIME.** The
/// view used to hash ratio, semitones and formant only, so a TUNING (a preset, a
/// note drag, a split, a clear) never started the poll, and a tuned clip's
/// render never shimmered. "Does this clip render?" has ONE home,
/// `Clip.rendersThroughStretchCache`; this type reads it and restates nothing.
///
/// ## What it holds: the render key's model-side inputs, per rendering clip
///
/// For each non-MIDI clip where `rendersThroughStretchCache` is true, keyed by
/// clip id (the engine's job and status slots are per clip, so a new rendering
/// clip is a new entry), the inputs of `StretchRenderCache.renderKeys`
/// (DAWEngine), which DAWAppKit cannot import:
///
/// | render key field | mirrored as |
/// |---|---|
/// | source path ‖ size ‖ mtime (`sourceIdentityFields`) | `audioFileURL`. `ProjectStore.save` rewrites it IN PLACE when media is copied into the bundle. Size and mtime are file-system facts: stat-ing files on every body evaluation is not an option, so a file rewritten at the same path is invisible here. |
/// | ratio and semitones BIT PATTERNS, formant flag | the same bit patterns and flag |
/// | `stretchEngineVersion`, `shaping:` version | nothing: per-build constants |
/// | `pitch:` + `PitchEditSetDigest.hex(pitchEdits)`, only when non-empty | `Tuning`, below |
/// | `contour:` key (contour-shaping sets only) | nothing extra: it depends on the source and the edits (both above) and on the per-process detector (a constant) |
///
/// ## How the tuning is compared without a second field list
///
/// The digest is `""` for a set that bends nothing (nil, or detected notes nobody
/// edited). Here, `Clip.hasPitchEdits` (the same rule, pinned against the digest
/// on the engine side) turns such a set into "no tuning", so running detection
/// alone starts no poll. When a set does bend the curve, the digest hashes the
/// raw BIT PATTERNS of the notes' stored fields (the vibrato generator's three
/// only while some depth is non-zero) plus the set's `analysisVersion` and
/// `retuneMs`, and deliberately never `autoCorrectStamp` (not render material:
/// see its declaration). `Tuning` compares:
///
/// * **the notes BYTE FOR BYTE**, not with `==`. `==` calls +0.0 and −0.0
///   equal, and so does `Hashable`. The digest does not, so a lone ±0 flip
///   re-keys the render (and silences the clip while it re-renders). Comparing
///   bytes also compares a field added to `NoteSegment` tomorrow with no list
///   here to update. That is sound because a note is plain data: a UUID,
///   Doubles, and (since I7a) ONE trailing Bool, `isCleared`. Its first `size`
///   bytes are exactly its fields and only its tail is padding, which the
///   comparison skips. A future field that added INTERIOR padding or a
///   reference could only make EQUAL notes compare unequal (one spare poll),
///   never the reverse, and `noteBytesAreExactlyItsFields` would say so first;
/// * **everything else through the type's own synthesized `==`**, on a copy with
///   the notes emptied and the stamp cleared, so a set-level field added
///   tomorrow is compared the day it lands.
///
/// ## Where it knowingly says "changed" when no render re-keys
///
/// Each costs one spare poll (≤ 12 s of 10 Hz status reads that find nothing),
/// never a missed one:
/// * a generator rate or onset edited while every vibrato depth is zero (the
///   digest only hashes that block when some depth is non-zero);
/// * a source URL re-spelled without moving (the key standardizes the path).
///
/// ## Cost
///
/// This runs on every `ContentView` body evaluation, which follows the playhead
/// (~30 Hz) during playback. Building it copies no notes (the note array is
/// shared, not duplicated). The one per-note walk is the model's own
/// `hasPitchEdits`, which stops at the first edited note; it reads the whole
/// table only when nothing, or only the last note, is edited. Comparing an
/// unchanged tuning is O(1), because the note arrays share storage. Only a
/// tuning that really changed (or was rebuilt) costs one `memcmp` over its notes.
public struct ClipRenderSignature: Equatable, Sendable {

    /// Clip id → the inputs its render is keyed on, for every clip that plays
    /// from a render. A clip that plays its source untouched has no entry, so
    /// adding, moving or reordering one changes nothing.
    let renders: [UUID: RenderInputs]

    public init(tracks: [Track]) {
        var renders: [UUID: RenderInputs] = [:]
        for track in tracks {
            // `!isMIDI`: the status poll reads non-MIDI clips only
            // (`AppModel.refreshStretchStatuses`), and the engine never renders
            // a clip without an audio file.
            for clip in track.clips where !clip.isMIDI && clip.rendersThroughStretchCache {
                renders[clip.id] = RenderInputs(clip)
            }
        }
        self.renders = renders
    }

    /// One clip's render-key inputs; see the table in the type's doc.
    struct RenderInputs: Equatable, Sendable {
        let source: URL?
        let stretchRatioBits: UInt64
        let pitchShiftSemitonesBits: UInt64
        let formantPreserve: Bool
        /// nil when the clip carries no edit that bends the curve.
        let tuning: Tuning?

        init(_ clip: Clip) {
            source = clip.audioFileURL
            stretchRatioBits = clip.stretchRatio.bitPattern
            pitchShiftSemitonesBits = clip.pitchShiftSemitones.bitPattern
            formantPreserve = clip.formantPreserve
            tuning = clip.hasPitchEdits ? clip.pitchEdits.map(Tuning.init) : nil
        }
    }

    /// A pitch-edit set compared the way the render key compares it; see
    /// "How the tuning is compared" in the type's doc.
    struct Tuning: Equatable, Sendable {
        /// The set with `segments` emptied and `autoCorrectStamp` cleared.
        let everythingButTheNotes: PitchEditSet
        let notes: [NoteSegment]

        init(_ set: PitchEditSet) {
            var rest = set
            rest.segments = []
            rest.autoCorrectStamp = nil
            everythingButTheNotes = rest
            notes = set.segments
        }

        static func == (lhs: Tuning, rhs: Tuning) -> Bool {
            lhs.everythingButTheNotes == rhs.everythingButTheNotes
                && bitIdentical(lhs.notes, rhs.notes)
        }

        /// True when both tables hold the same bytes. Shared storage (the common
        /// case: nothing touched the set) answers without reading a note.
        ///
        /// ⚠️ **Each note is compared over its `size` bytes, never its
        /// `stride`.** Since I7a added `isCleared` (a Bool, declared last), a
        /// note is 129 bytes stored at a 136-byte stride, and the 7 tail bytes
        /// are padding that nothing initialises. Comparing them would let two
        /// EQUAL tables read unequal depending on what the allocator left
        /// there. `noteBytesAreExactlyItsFields` pins that all padding is at the
        /// tail, so a note's first `size` bytes are exactly its fields.
        static func bitIdentical(_ lhs: [NoteSegment], _ rhs: [NoteSegment]) -> Bool {
            guard lhs.count == rhs.count else { return false }
            return lhs.withUnsafeBytes { left in
                rhs.withUnsafeBytes { right in
                    guard let l = left.baseAddress, let r = right.baseAddress else {
                        return left.count == right.count
                    }
                    if l == r { return true }
                    let size = MemoryLayout<NoteSegment>.size
                    let stride = MemoryLayout<NoteSegment>.stride
                    for index in 0..<lhs.count
                    where memcmp(l + index * stride, r + index * stride, size) != 0 {
                        return false
                    }
                    return true
                }
            }
        }
    }
}
