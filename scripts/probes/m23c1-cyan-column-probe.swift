// m23-c1 gate helper: crop a capture to a band rect, WRITE the crop, and report
// (a) the crop's real pixel dimensions — asserted by the caller before any hash
// is trusted, because a silently-failed crop reproduces the whole-window false
// negative that already burned this surface once — (b) a sha256 of the cropped
// pixels, and (c) a cyan column profile so two bands can be proven to place the
// off-clip cue at the SAME x rather than merely both having one.
//
// Cyan metric: DAWTheme.playback is 0x3EE6FF (62,230,255); composited at any
// opacity over the dark grid it lifts G and B above R. score = (g+b)/2 - r,
// averaged down the column, then the crop's MEDIAN column is subtracted so the
// panel's own blue-ish background reads as zero and only cyan ink is counted.
import AppKit
import CryptoKit

func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(2) }

let a = CommandLine.arguments
guard a.count == 8 else { die("usage: pixelprobe IN.png OUT.png x y w h threshold") }
let inPath = a[1], outPath = a[2]
guard let x = Int(a[3]), let y = Int(a[4]), let w = Int(a[5]), let h = Int(a[6]),
      let threshold = Double(a[7]) else { die("bad numeric args") }

guard let src = NSImage(contentsOfFile: inPath),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    die("cannot read \(inPath)")
}
let rect = CGRect(x: x, y: y, width: w, height: h)
guard rect.maxX <= CGFloat(cg.width), rect.maxY <= CGFloat(cg.height),
      let crop = cg.cropping(to: rect) else {
    die("crop \(rect) out of bounds for \(cg.width)x\(cg.height)")
}

let rep = NSBitmapImageRep(cgImage: crop)
guard let png = rep.representation(using: .png, properties: [:]) else { die("no png") }
try! png.write(to: URL(fileURLWithPath: outPath))

let cw = crop.width, ch = crop.height
var buf = [UInt8](repeating: 0, count: cw * ch * 4)
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: &buf, width: cw, height: ch, bitsPerComponent: 8,
                          bytesPerRow: cw * 4, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    die("no ctx")
}
ctx.draw(crop, in: CGRect(x: 0, y: 0, width: cw, height: ch))

var columns = [Double](repeating: 0, count: cw)
for row in 0..<ch {
    for col in 0..<cw {
        let i = (row * cw + col) * 4
        let r = Double(buf[i]), g = Double(buf[i + 1]), b = Double(buf[i + 2])
        columns[col] += (g + b) / 2 - r
    }
}
for i in 0..<cw { columns[i] /= Double(ch) }
let baseline = columns.sorted()[cw / 2]          // median column = the background
let ink = columns.map { $0 - baseline }
let peak = ink.max() ?? 0
let hot = ink.enumerated().filter { $0.element >= threshold }.map(\.offset)

// Contiguous runs of hot columns, reported in the SOURCE image's x coordinates.
var runs: [(Int, Int)] = []
for c in hot {
    if let last = runs.last, c == last.1 + 1 { runs[runs.count - 1].1 = c } else { runs.append((c, c)) }
}
let runText = runs.map { "\($0.0 + x)-\($0.1 + x)" }.joined(separator: ",")

let digest = SHA256.hash(data: png).compactMap { String(format: "%02x", $0) }.joined()
print("dims=\(cw)x\(ch)")
print("sha=\(String(digest.prefix(12)))")
print("baseline=\(String(format: "%.2f", baseline))")
print("peak=\(String(format: "%.2f", peak))")
print("hotColumns=\(hot.count)")
print("runs=\(runs.isEmpty ? "-" : runText)")
