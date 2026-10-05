import CryptoKit
import DAWCore
import Foundation

/// **THE TIME BASE OF A FILE A CLIP PLAYS** (p2-ren Stage A;
/// `docs/design/2026-09-25-incremental-note-render.md` §3, §5, §11 step 1):
/// everything that decides WHICH source audio each frame of the file carries,
/// and so WHERE and HOW FAST the clip plays it. That is the source file's
/// identity, the stretch ratio, and, once the render reads it, the per-note
/// time warp W. Two files with equal time bases play the same source at the
/// same speed, in the same place, for the same number of frames. They can
/// differ only in pitch and level.
///
/// ⭐ **THE ONE HOME OF M5's RULE, KEPT BY ITS REASON.** M5 (spec §5) made a
/// pending clip silent so that it would "never play wrong-speed audio"; the
/// only alternative it had was the unrendered SOURCE, which plays at the wrong
/// speed and in the wrong place. The bridge (`AudioEngine.bridgeFile(for:
/// keys:)`) plays a clip's PREVIOUS file while its new render is pending ONLY
/// when this value is equal for the two, so the reason survives and only the
/// letter narrows.
///
/// Deliberately NOT here: the whole-clip transpose, the formant flag, and the
/// pitch and level of the notes. Those change what a file SOUNDS like, never
/// which source frame plays when.
struct RenderTimeBase: Equatable, Sendable {
    /// `StretchRenderCache.sourceIdentityFields(source:)`: the standardized
    /// path, the size and the mtime bit pattern. The render key starts with the
    /// same strings, so a source the key calls different is different here.
    let sourceIdentity: [String]

    /// `Clip.stretchRatio.bitPattern`. Bits, as the render key hashes them:
    /// `==` on Doubles would call +0.0 and −0.0 equal, and the key does not.
    let ratioBits: UInt64

    /// W, digested (`timeWarpDigest(_:)`), while the render READS W
    /// (`StretchCurvePlan.readsTimeWarp`); `nil` until then. While the render
    /// ignores W, a timing-only edit changes the render key but not one sample
    /// of the render (`docs/ARCHITECTURE.md`, C2), so it is not part of the
    /// time base, and the previous file is EXACT for it.
    let timeWarpDigest: String?

    /// The stretch ratio these bits hold.
    var ratio: Double { Double(bitPattern: ratioBits) }

    /// The time base of the file `clip` plays: its source itself (an identity
    /// clip) or the render the cache makes of that source for its parameters.
    /// Both have the source's identity and the clip's ratio, so ONE expression
    /// covers both. Throws when the source cannot be stat'ed.
    ///
    /// `readsTimeWarp` is `StretchCurvePlan.readsTimeWarp` everywhere but in
    /// the test that shows what the flip will do.
    static func of(source: URL, clip: Clip,
                   readsTimeWarp: Bool = StretchCurvePlan.readsTimeWarp) throws -> RenderTimeBase {
        RenderTimeBase(
            sourceIdentity: try StretchRenderCache.sourceIdentityFields(source: source),
            ratioBits: clip.stretchRatio.bitPattern,
            timeWarpDigest: readsTimeWarp ? timeWarpDigest(clip.pitchEdits) : nil)
    }

    /// How many frames EVERY file with this time base has when it is made from
    /// a source of `sourceFrames` frames: `OfflineStretcher`'s alignment
    /// contract, exactly `round(inputFrames × ratio)`. It covers the level-only
    /// path and a source file too, both at ratio 1. (It also holds under W once
    /// C2-3 lands: W(D) = D, so a warp never changes the length.)
    func expectedFrames(sourceFrames: Int) -> Int {
        Int((Double(sourceFrames) * ratio).rounded())
    }

    /// W's inputs, digested: every canonical note's source edges and timing
    /// deltas, and `PitchTimeWarp.scheduleVersion`. `""` for a set with no time
    /// edits, whose W is the identity. `PitchTimeWarp.make`'s only other input
    /// is D, the source's duration, which `sourceIdentity` already fixes, so
    /// equal digests beside equal identities mean equal warps.
    ///
    /// It errs toward silence, never toward wrong-time audio: a split that
    /// leaves W's values unchanged still changes the digest.
    static func timeWarpDigest(_ set: PitchEditSet?) -> String {
        guard let set, set.hasTimeEdits else { return "" }
        let segments = PitchEditSet.canonical(set.segments)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16 + segments.count * 32)
        func put(_ value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        put(UInt64(PitchTimeWarp.scheduleVersion))
        put(UInt64(segments.count))
        for segment in segments {
            put(segment.startSeconds.bitPattern)
            put(segment.endSeconds.bitPattern)
            put(segment.timeStartDeltaSeconds.bitPattern)
            put(segment.timeEndDeltaSeconds.bitPattern)
        }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}
