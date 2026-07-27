// m23-g1 gate helper: crop a capture to one or more CLIP BOXES, write each crop,
// and report per-box mean RGB + luminance + a sha of the cropped pixels.
//
// WHY MEAN LUMINANCE AND NOT A HASH ALONE: the m23-b law is that a distinctness
// check only proves the CAPTURE changed, never that the surface under test did.
// A hash says "different"; it cannot say "brighter, in the direction selection
// is supposed to move it". `ClipBlock` paints a selected block at fill opacity
// 0.34 vs 0.22 unselected, with a 1.5 pt 0.95-opacity stroke vs 1.0 pt 0.55 and
// a glow at intensity 0.5 vs 0 — all of which raise the box's mean luminance
// over the dark panel. So the gate asserts a SIGNED, ordered difference between
// two boxes in the SAME frame, plus a control pair of two UNSELECTED boxes that
// must read alike. Crops are written so a human can look.
//
// TWO MODES, because the gate must DERIVE its crop rects rather than inherit
// hardcoded ones (FIXTURE LAW):
//
//   boxes IN.png OUTDIR label:x,y,w,h [label:x,y,w,h …]
//     prints one line per box: "<label> dims=WxH mean=R,G,B luma=L sha=…"
//
//   rows IN.png x w y0 h0
//     prints "<y> <luma>" for every row in [y0, y0+h0) averaged across the x
//     window — the lane-band finder. The gate turns that profile into lane y's
//     and ASSERTS their count and spacing against the row geometry it set, so a
//     layout shift fails loudly instead of silently cropping empty panel.
//
// (all rects are in CAPTURE PIXELS, i.e. logical points × the capture scale)
import AppKit
import CryptoKit

func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(2) }

let args = CommandLine.arguments
guard args.count >= 3 else { die("usage: probe boxes|rows …") }
let mode = args[1]
let inPath = args[2]

guard let src = NSImage(contentsOfFile: inPath),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    die("cannot read \(inPath)")
}

/// Draws `rect` of the source into a straight RGBA buffer.
func pixels(_ rect: CGRect) -> (buf: [UInt8], w: Int, h: Int, crop: CGImage) {
    guard rect.minX >= 0, rect.minY >= 0,
          rect.maxX <= CGFloat(cg.width), rect.maxY <= CGFloat(cg.height),
          let crop = cg.cropping(to: rect) else {
        die("crop \(rect) out of bounds for \(cg.width)x\(cg.height)")
    }
    let cw = crop.width, ch = crop.height
    var buf = [UInt8](repeating: 0, count: cw * ch * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &buf, width: cw, height: ch, bitsPerComponent: 8,
                              bytesPerRow: cw * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        die("no ctx")
    }
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: cw, height: ch))
    return (buf, cw, ch, crop)
}

if mode == "rows" {
    guard args.count == 7, let x = Int(args[3]), let w = Int(args[4]),
          let y0 = Int(args[5]), let h0 = Int(args[6]) else {
        die("usage: probe rows IN.png x w y0 h0")
    }
    let (buf, cw, ch, _) = pixels(CGRect(x: x, y: y0, width: w, height: h0))
    for row in 0..<ch {
        var sr = 0.0, sg = 0.0, sb = 0.0
        for col in 0..<cw {
            let i = (row * cw + col) * 4
            sr += Double(buf[i]); sg += Double(buf[i + 1]); sb += Double(buf[i + 2])
        }
        let n = Double(cw)
        let luma = (0.299 * sr + 0.587 * sg + 0.114 * sb) / n
        print("\(y0 + row) \(String(format: "%.3f", luma))")
    }
    exit(0)
}

if mode == "cols" {
    guard args.count == 7, let x = Int(args[3]), let w = Int(args[4]),
          let y0 = Int(args[5]), let h0 = Int(args[6]) else {
        die("usage: probe cols IN.png x w y0 h0")
    }
    let (buf, cw, ch, _) = pixels(CGRect(x: x, y: y0, width: w, height: h0))
    for col in 0..<cw {
        var sr = 0.0, sg = 0.0, sb = 0.0
        for row in 0..<ch {
            let i = (row * cw + col) * 4
            sr += Double(buf[i]); sg += Double(buf[i + 1]); sb += Double(buf[i + 2])
        }
        let n = Double(ch)
        let luma = (0.299 * sr + 0.587 * sg + 0.114 * sb) / n
        print("\(x + col) \(String(format: "%.3f", luma))")
    }
    exit(0)
}

guard mode == "boxes", args.count >= 4 else { die("usage: probe boxes IN.png OUTDIR label:x,y,w,h …") }
let outDir = args[3]

for spec in args.dropFirst(4) {
    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { die("bad spec \(spec)") }
    let label = parts[0]
    let nums = parts[1].split(separator: ",").compactMap { Int($0) }
    guard nums.count == 4 else { die("bad rect in \(spec)") }
    let rect = CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
    let (buf, cw, ch, crop) = pixels(rect)

    let rep = NSBitmapImageRep(cgImage: crop)
    guard let png = rep.representation(using: .png, properties: [:]) else { die("no png") }
    let outPath = "\(outDir)/\(label).png"
    try! png.write(to: URL(fileURLWithPath: outPath))

    var sr = 0.0, sg = 0.0, sb = 0.0
    for i in stride(from: 0, to: cw * ch * 4, by: 4) {
        sr += Double(buf[i]); sg += Double(buf[i + 1]); sb += Double(buf[i + 2])
    }
    let n = Double(cw * ch)
    let (r, g, b) = (sr / n, sg / n, sb / n)
    // Rec. 601 luma — any monotone brightness metric works here; this one is
    // standard and needs no colour-space assumptions beyond device RGB.
    let luma = 0.299 * r + 0.587 * g + 0.114 * b
    let digest = SHA256.hash(data: png).compactMap { String(format: "%02x", $0) }.joined()
    print("\(label) dims=\(cw)x\(ch) mean=\(String(format: "%.2f,%.2f,%.2f", r, g, b)) "
          + "luma=\(String(format: "%.3f", luma)) sha=\(String(digest.prefix(12)))")
}
