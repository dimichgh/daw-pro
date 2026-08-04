// m23-ah GLYPH MATCHER — reads the WORDS, which every m23-v leg is blind to.
//
//   m23ah-hint-glyph-probe CAPTURE.png xA xB y0 w h scale "cand0" "cand1" …
//   (xA/xB/y0/w/h in PIXELS; cand0 is the PINNED copy, the rest are near-misses)
//
// WHY THIS EXISTS. `m23v-empty-lane-hint.mjs` proves the empty-lane hint is DRAWN,
// DIM, on exactly the right lanes, and that it VANISHES. It does not prove it
// SPELLS the hint: its E-legs read the echo (`hint.text` — the MODEL's value, not
// glyphs) and its P-legs bound ink HEIGHT/PEAK/LANE/disappearance, all of which a
// different string at the same font size satisfies. MEASURED: replacing
// `Text(hint.text)` with the literal `"Double-click to odd a clip"` scored 27/27
// GREEN on that gate. A WIDTH pin does not close it either — in SF Pro `a` and `o`
// carry near-identical advances (134.191 pt vs 134.621 pt for those two strings, a
// 0.43 pt difference), so the exact mutant that motivated the item survives one.
//
// TWO IDEAS make glyph-level comparison robust without needing a pixel-exact
// reference render:
//
//  1. THE GRID IS CANCELLED THE SAME WAY m23-v CANCELS IT, BUT IN 2D. The label
//     window and a control window in the SAME lane, both starting at x ≡ 4 (mod
//     64), span the identical bar/beat lines. `ink = max(0, A - B)` per pixel
//     leaves glyph ink only. That is the m23-p2 law in two dimensions: a
//     comparison control must be structurally identical, or you measure the
//     structure. MEASURED on a real capture: on a lane with NO hint the two
//     windows are byte-identical (sha c16ce2bfe607 both), so the ink is exactly
//     0.0 — the cancellation is not approximate.
//
//  2. THE VERDICT IS A RANKING, NOT A THRESHOLD. Absolute agreement between
//     SwiftUI's rasterizer and a CoreText reference is not something anyone should
//     be tuning; but WHICH candidate the frame looks most like is stable. NCC is
//     amplitude- and offset-invariant, so it does not care that reference ink is
//     255 while actual ink peaks near 106 over the lane background.
//
// HOW WELL IT AGREES, measured on the clean tree at lane 0: the pinned copy scores
// NCC 0.9893 and the single-glyph near-miss 0.9323 (margin +0.0570); with the
// mutant compiled in, the two scores swap almost exactly (0.9331 vs 0.9895, margin
// −0.0564). `NSFont.systemFont(ofSize: 11)` reproduces SwiftUI's
// `.font(.system(size: 11))` essentially exactly — that was the design's main risk
// and it is retired.
//
// ⚠️ THE FONT SIZE IS HARDCODED AT 11 pt to match
// `TimelineLanesView.emptyLaneHintFontSize` (`TimelineLanesView.swift:410`). It is
// echoed on the `INK` line so the gate can assert the two agree; a change to that
// constant must fail the GATE loudly rather than quietly detune this reference.
//
// ⚠️ WHAT THIS PROBE DOES NOT DO. It does not locate anything. The caller supplies
// the crop, and a crop that misses the text entirely would make every candidate
// score badly *together* — a ranking cannot tell "wrong words" from "wrong place".
// That is why the ink floor below is a REFUSAL and not a warning, why the crop
// rect is echoed back on the `INK` line, and why the gate pins an ABSOLUTE NCC
// alongside the ranking.
//
// OUTPUT — one labelled key=value line per fact, the m23-g1 probe convention, so
// the gate parses rather than scrapes:
//   INK sum=… max=… xA=… xB=… y0=… w=… h=… scale=… font=…
//   NCC <idx> <score> <dx> <dy> <candidate…>      (candidate last: it has spaces)
//   BEST <idx> <score>
//   MARGIN <pinned − best-near-miss>
//   VERDICT PASS|FAIL
// or, when the window carries no ink:
//   INK …
//   REFUSED ink-below-floor floor=…
//
// EXIT CODES: 0 the pinned copy wins, 1 a near-miss ties or wins, 2 refused/usage.
// The gate must therefore capture stdout even on a NONZERO exit — the red baseline
// exits 1 by design and the refusal path exits 2 with its numbers already printed.
import AppKit
import CoreGraphics

func die(_ m: String) -> Never { FileHandle.standardError.write(m.data(using: .utf8)!); exit(2) }

let INK_FLOOR = 100.0
let FONT_PT = 11.0   // TimelineLanesView.emptyLaneHintFontSize — echoed, and pinned by the gate
/// Where the reference line is drawn inside its buffer, in POINTS. Arbitrary on
/// its own — the shift search sweeps it away — but ECHOED because the caller can
/// subtract it out of the winning shift and recover the label's true horizontal
/// position: contentX = (xA / scale) + REF_X + dx / scale. That turns a byproduct
/// of the search into a position pin, which is the only thing in this measurement
/// that can catch a scrolled viewport (the crop's x would still read correct).
let REF_X = 6.0

let a = CommandLine.arguments
guard a.count >= 9, let xA = Int(a[2]), let xB = Int(a[3]), let y0 = Int(a[4]),
      let w = Int(a[5]), let h = Int(a[6]), let scale = Double(a[7]) else {
    die("usage: m23ah-hint-glyph-probe CAPTURE.png xA xB y0 w h scale \"cand0\" …\n")
}
let candidates = Array(a[8...])

guard let src = CGDataProvider(url: URL(fileURLWithPath: a[1]) as CFURL),
      let img = CGImage(pngDataProviderSource: src, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent) else {
    die("cannot read \(a[1])\n")
}

/// One window of the capture as Rec.601 luma, row-major, `w * h` samples.
func crop(_ x: Int) -> [Double] {
    guard let c = img.cropping(to: CGRect(x: x, y: y0, width: w, height: h)) else { die("crop failed\n") }
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { die("no ctx\n") }
    ctx.draw(c, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let d = ctx.data else { die("no data\n") }
    let buf = d.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var out = [Double](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
        out[i] = 0.299 * Double(buf[i * 4]) + 0.587 * Double(buf[i * 4 + 1]) + 0.114 * Double(buf[i * 4 + 2])
    }
    return out
}

// THE INK. `max(0, label − control)`, so anything the two windows share — the beat
// and bar lines, the lane's own background tone, the panel gradient — subtracts
// out, and only what the label adds survives.
let A = crop(xA), B = crop(xB)
var ink = [Double](repeating: 0, count: w * h)
for i in 0..<(w * h) { ink[i] = max(0, A[i] - B[i]) }
let inkSum = ink.reduce(0, +)
print(String(format: "INK sum=%.1f max=%.1f xA=%d xB=%d y0=%d w=%d h=%d scale=%.1f font=%.1f refx=%.1f",
             inkSum, ink.max() ?? 0, xA, xB, y0, w, h, scale, FONT_PT, REF_X))
// A wrong crop must fail LOUDLY. Scoring an empty window would rank four
// candidates against noise and report whichever won as a verdict about the words.
if inkSum < INK_FLOOR {
    print(String(format: "REFUSED ink-below-floor floor=%.1f", INK_FLOOR))
    die("REFUSING: the label window carries no ink — the crop is wrong, not the copy\n")
}

/// Render one candidate into the SAME buffer geometry as the ink. The draw
/// position is deliberately approximate — the alignment search below sweeps it —
/// so only the FONT has to match the app's.
func renderRef(_ s: String) -> [Double] {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { die("no ctx\n") }
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldSmoothFonts(true)
    let font = NSFont.systemFont(ofSize: CGFloat(FONT_PT))
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.white]))
    // Near the buffer's left edge and vertical centre; the search does the rest.
    ctx.textPosition = CGPoint(x: REF_X, y: Double(h) / scale / 2 - 4)
    CTLineDraw(line, ctx)
    guard let d = ctx.data else { die("no data\n") }
    let buf = d.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var out = [Double](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
        out[i] = 0.299 * Double(buf[i * 4]) + 0.587 * Double(buf[i * 4 + 1]) + 0.114 * Double(buf[i * 4 + 2])
    }
    return out
}

/// Normalized cross-correlation, maximized over integer shifts of ±8 pt.
///
/// Amplitude-invariant by construction (the denominator is the product of the two
/// norms), which is what lets a 255-valued reference be compared against actual
/// ink peaking near 106 without a single tuned scale factor. The shift sweep
/// absorbs the reference's arbitrary draw position and the label's own inset, so
/// the score reflects GLYPH SHAPE and nothing else.
func bestNCC(_ ref: [Double], _ act: [Double]) -> (Double, Int, Int) {
    let R = Int(8 * scale)
    var best = -2.0, bx = 0, by = 0
    for dy in -R...R {
        for dx in -R...R {
            var sar = 0.0, saa = 0.0, srr = 0.0
            for y in 0..<h {
                let ry = y + dy
                if ry < 0 || ry >= h { continue }
                for x in 0..<w {
                    let rx = x + dx
                    if rx < 0 || rx >= w { continue }
                    let av = act[y * w + x], rv = ref[ry * w + rx]
                    sar += av * rv; saa += av * av; srr += rv * rv
                }
            }
            if saa <= 0 || srr <= 0 { continue }
            let ncc = sar / (saa.squareRoot() * srr.squareRoot())
            if ncc > best { best = ncc; bx = dx; by = dy }
        }
    }
    return (best, bx, by)
}

var scores: [(String, Double, Int, Int)] = []
for c in candidates {
    let (n, dx, dy) = bestNCC(renderRef(c), ink)
    scores.append((c, n, dx, dy))
}
for (i, s) in scores.enumerated() {
    print(String(format: "NCC %d %.5f %d %d %@", i, s.1, s.2, s.3, s.0 as NSString))
}
let bestIdx = scores.indices.max(by: { scores[$0].1 < scores[$1].1 })!
print(String(format: "BEST %d %.5f", bestIdx, scores[bestIdx].1))
let pinned = scores[0]
let bestOther = scores.dropFirst().max(by: { $0.1 < $1.1 })!
let margin = pinned.1 - bestOther.1
print(String(format: "MARGIN %+.5f", margin))
print(margin > 0 ? "VERDICT PASS" : "VERDICT FAIL")
exit(margin > 0 ? 0 : 1)
