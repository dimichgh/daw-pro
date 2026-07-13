import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Disk-free media stub so `previewMatchesStore` can seed a real audio clip
/// (2.0 s → 4 beats at the default 120 BPM, the DAWCore FakeMedia convention).
private struct StubMedia: MediaImporting {
    func audioFileInfo(at url: URL) throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: 2.0, sampleRate: 48_000, channelCount: 2)
    }
}

/// Unit tests for the headless stretch-handle logic (M5 ii-e): alt-drag
/// classification, ratio-from-length preview (mirroring `ProjectStore.stretchClip`
/// including the ratio-clamp → length re-derivation), 0.75–1.5× band checks,
/// badge/readout formatting, and render-state mapping. The arrange stretch
/// gesture layer is thin over these, so exercising them here covers the handle's
/// logic without a display (the `ClipEditModel` precedent).
@Suite("ClipStretchModel")
struct ClipStretchModelTests {

    /// Trivial single-meter map (m13-h) — the byte-equivalence anchor.
    private func meter(_ bpb: Int = 4) -> MeterMap {
        MeterMap(constant: TimeSignature(beatsPerBar: bpb))
    }

    /// 4/4 → 6/8 @ beat 16 (bpb 6): barlines …12,16,22,28…
    private func crossMeter() -> MeterMap {
        try! MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            .init(startBeat: 16, beatsPerBar: 6, beatUnit: 8),
        ])
    }

    // MARK: - Alt-drag classification

    @Test("only a trailing-edge option-drag on an audio clip is a stretch")
    func stretchClassification() {
        #expect(ClipStretch.isStretchDrag(zone: .trimEnd, optionHeld: true, isAudio: true))
        // MIDI right-edge alt-drag stays a plain trim (audio-only in v0).
        #expect(!ClipStretch.isStretchDrag(zone: .trimEnd, optionHeld: true, isAudio: false))
        // Without the modifier it is a plain trim.
        #expect(!ClipStretch.isStretchDrag(zone: .trimEnd, optionHeld: false, isAudio: true))
        // Any other zone is never a stretch, even with option held.
        for zone in [ClipZone.trimStart, .body, .fadeInHandle, .fadeOutHandle] {
            #expect(!ClipStretch.isStretchDrag(zone: zone, optionHeld: true, isAudio: true))
        }
    }

    // MARK: - Target length from a right-edge drag (snapped like a trim)

    @Test("target length snaps the new end and floors at the min clip length")
    func targetLengthSnapAndFloor() {
        // 4-beat clip at 0, dragged +1.6 beats, bar snap (4) → end snaps to 4? no:
        // rawEnd 5.6 → nearest bar (4) = 4? nearest of {4,8} to 5.6 is 4 -> len 4.
        let l1 = ClipStretch.targetLength(
            originalStart: 0, originalLength: 4, dragDeltaBeats: 1.6,
            snap: .bar, meterMap: meter())
        #expect(l1 == 4)
        // Beat snap, +2.4 → rawEnd 6.4 → snaps to 6 → length 6.
        let l2 = ClipStretch.targetLength(
            originalStart: 0, originalLength: 4, dragDeltaBeats: 2.4,
            snap: .beat, meterMap: meter())
        #expect(l2 == 6)
        // Dragging far left is floored to the min clip length (start pinned).
        let l3 = ClipStretch.targetLength(
            originalStart: 2, originalLength: 4, dragDeltaBeats: -100,
            snap: .off, meterMap: meter())
        #expect(l3 == ClipEdit.minClipLengthBeats)
    }

    @Test("target length .bar snap follows the region's meter across a change (m13-h)")
    func targetLengthCrossBoundary() {
        let m = crossMeter()   // barlines …12,16,22,28…
        // A clip starting at 16 (6/8), dragged so the new end lands ~21 → 6/8 bar 22.
        // originalLength 4 → rawEnd 20 + delta 1 = 21 → snaps to 22 → length 6.
        let l = ClipStretch.targetLength(
            originalStart: 16, originalLength: 4, dragDeltaBeats: 1,
            snap: .bar, meterMap: m)
        #expect(l == 6)   // 22 - 16, one 6/8 bar
        // Trivial-map regression: same call on a plain 4/4 map snaps end 21 → 20.
        let l4 = ClipStretch.targetLength(
            originalStart: 16, originalLength: 4, dragDeltaBeats: 1,
            snap: .bar, meterMap: meter())
        #expect(l4 == 4)   // 20 - 16, one 4/4 bar
    }

    // MARK: - Ratio-from-length preview (mirrors the store)

    @Test("stretch preview scales ratio with length, holding the source window")
    func previewWindowInvariant() {
        // 4 beats @ ratio 1 → 6 beats ⇒ ratio 1.5, length 6.
        let a = ClipStretch.stretchPreview(oldLength: 4, oldRatio: 1, targetLength: 6)
        #expect(abs(a.ratio - 1.5) < 1e-12)
        #expect(a.length == 6)
        // 4 → 2 beats ⇒ ratio 0.5.
        let b = ClipStretch.stretchPreview(oldLength: 4, oldRatio: 1, targetLength: 2)
        #expect(abs(b.ratio - 0.5) < 1e-12)
        #expect(b.length == 2)
        // Already stretched (6 beats @ 1.5, window 4): retarget to 3 ⇒ 0.75.
        let c = ClipStretch.stretchPreview(oldLength: 6, oldRatio: 1.5, targetLength: 3)
        #expect(abs(c.ratio - 0.75) < 1e-12)
        #expect(c.length == 3)
    }

    @Test("preview clamps ratio to 0.25–4 and RE-DERIVES length on clamp")
    func previewRatioClampReDerivesLength() {
        // 4 beats @ ratio 1 (window 4). Target 20 beats ⇒ desired ratio 5 → clamps
        // to 4, and length re-derives to window·ratio = 4·4 = 16 (NOT 20), so the
        // source window stays invariant — exactly the store's behavior.
        let up = ClipStretch.stretchPreview(oldLength: 4, oldRatio: 1, targetLength: 20)
        #expect(up.ratio == 4)
        #expect(up.length == 16)
        // Target 0.2 beats ⇒ desired 0.05 → clamps to 0.25, length re-derives to
        // 4·0.25 = 1.
        let down = ClipStretch.stretchPreview(oldLength: 4, oldRatio: 1, targetLength: 0.2)
        #expect(down.ratio == 0.25)
        #expect(down.length == 1)
    }

    @Test("preview matches ProjectStore.stretchClip on the same clip")
    @MainActor
    func previewMatchesStore() throws {
        let store = ProjectStore()
        store.media = StubMedia()
        let track = store.addTrack(name: "Aud", kind: .audio)
        let clip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/x.wav"), toTrack: track.id)
        #expect(clip.lengthBeats == 4)
        // A representative set of targets incl. a clamp.
        for target in [6.0, 2.0, 3.0, 20.0, 0.2, 8.0] {
            let preview = ClipStretch.stretchPreview(oldLength: 4, oldRatio: 1, targetLength: target)
            let result = try store.stretchClip(trackId: track.id, clipId: clip.id, toLengthBeats: target)
            #expect(abs(result.lengthBeats - preview.length) < 1e-9,
                    "length mismatch at target \(target): store \(result.lengthBeats) vs preview \(preview.length)")
            #expect(abs(result.stretchRatio - preview.ratio) < 1e-9,
                    "ratio mismatch at target \(target): store \(result.stretchRatio) vs preview \(preview.ratio)")
            // Reset for the next independent comparison.
            _ = try store.stretchClip(trackId: track.id, clipId: clip.id, toLengthBeats: 4)
        }
    }

    @Test("preview guards a degenerate zero-length / zero-ratio clip")
    func previewDegenerateGuard() {
        let z = ClipStretch.stretchPreview(oldLength: 0, oldRatio: 1, targetLength: 6)
        #expect(z.length == 6)
        #expect(z.ratio == 1)
    }

    // MARK: - Quality band

    @Test("quality band classifies against the 0.75–1.5 sweet spot")
    func qualityBands() {
        #expect(ClipStretch.qualityBand(ratio: 1.0) == .transparent)
        #expect(ClipStretch.qualityBand(ratio: 0.75) == .transparent)   // inclusive edge
        #expect(ClipStretch.qualityBand(ratio: 1.5) == .transparent)    // inclusive edge
        #expect(ClipStretch.qualityBand(ratio: 0.7499) == .degraded)
        #expect(ClipStretch.qualityBand(ratio: 1.5001) == .degraded)
        #expect(ClipStretch.qualityBand(ratio: 0.5) == .degraded)
        #expect(ClipStretch.qualityBand(ratio: 4.0) == .degraded)
    }

    @Test("out-of-band flags only actually-stretched clips outside the band")
    func outOfBand() {
        #expect(!ClipStretch.isOutOfBand(ratio: 1.0))       // identity is never flagged
        #expect(!ClipStretch.isOutOfBand(ratio: 1.25))      // stretched but in band
        #expect(!ClipStretch.isOutOfBand(ratio: 0.75))
        #expect(ClipStretch.isOutOfBand(ratio: 1.75))
        #expect(ClipStretch.isOutOfBand(ratio: 0.5))
        #expect(ClipStretch.isOutOfBand(ratio: 4.0))
    }

    // MARK: - Formatting

    @Test("ratio string is two decimals + multiplication sign")
    func ratioFormatting() {
        #expect(ClipStretch.ratioString(1.5) == "1.50×")
        #expect(ClipStretch.ratioString(0.75) == "0.75×")
        #expect(ClipStretch.ratioString(1) == "1.00×")
        #expect(ClipStretch.ratioString(1.25) == "1.25×")
    }

    @Test("semitone string carries an explicit sign, drops whole decimals")
    func semitoneFormatting() {
        #expect(ClipStretch.semitoneString(3) == "+3st")
        #expect(ClipStretch.semitoneString(-5) == "-5st")
        #expect(ClipStretch.semitoneString(7) == "+7st")
        #expect(ClipStretch.semitoneString(3.5) == "+3.5st")
    }

    @Test("badge shows ratio and/or pitch, nil for identity")
    func badgeFormatting() {
        #expect(ClipStretch.badge(ratio: 1, semitones: 0) == nil)
        #expect(ClipStretch.badge(ratio: 1.5, semitones: 0) == "1.50×")
        #expect(ClipStretch.badge(ratio: 1, semitones: 3) == "+3st")
        #expect(ClipStretch.badge(ratio: 1.5, semitones: -5) == "1.50× -5st")
    }

    @Test("stretch readout is length beats + resulting ratio")
    func readoutFormatting() {
        #expect(ClipStretch.stretchReadout(length: 6, ratio: 1.5) == "6.0 beats · 1.50×")
        #expect(ClipStretch.stretchReadout(length: 2, ratio: 0.5) == "2.0 beats · 0.50×")
    }

    @Test("out-of-band help names the ratio and the transparent range")
    func outOfBandHelp() {
        let help = ClipStretch.outOfBandHelp(ratio: 1.75)
        #expect(help.contains("1.75×"))
        #expect(help.contains("0.75–1.5×"))
    }

    // MARK: - Render state

    @Test("render visual maps engine status to shimmer / error / none")
    func renderVisualMapping() {
        #expect(ClipStretch.renderVisual(for: nil) == .none)
        #expect(ClipStretch.renderVisual(for: .idle) == .none)
        #expect(ClipStretch.renderVisual(for: .rendering) == .shimmer)
        #expect(ClipStretch.renderVisual(for: .failed("boom")) == .error)
    }
}
