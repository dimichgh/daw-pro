// m17-b diagnostic: bar-line coincidence between the pinned ruler band and the
// lanes band. Finds thin vertical "line" columns (local luminance maxima vs
// horizontal neighbors) in each band and prints their x positions so the
// static ruler-vs-lanes skew can be measured directly against drawn gridlines,
// independent of playhead-line width/centering semantics.
import Foundation
import CoreGraphics
import ImageIO

let args = CommandLine.arguments
guard args.count >= 2 else { fatalError("usage: barlines.swift <png> [rulerY] [lanesY]") }
let path = args[1]
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("read \(path)") }
let w = img.width, h = img.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
func lum(_ x: Int, _ y: Int) -> Double {
    let o = (y * w + x) * 4
    return (Double(data[o]) + Double(data[o + 1]) + Double(data[o + 2])) / 3
}

// Average a few rows in each band so single-row noise (labels, clip text)
// doesn't dominate. Ruler tick zone: bottom of the ruler band. Lanes grid
// zone: rows chosen inside lane backgrounds between clips where gridlines show.
func lineColumns(rows: [Int], from x0: Int, to x1: Int) -> [Int] {
    var cols: [Int] = []
    var x = x0
    while x < x1 {
        var v = 0.0, l = 0.0, r = 0.0
        for y in rows { v += lum(x, y); l += lum(x - 3, y); r += lum(x + 3, y) }
        v /= Double(rows.count); l /= Double(rows.count); r /= Double(rows.count)
        // A gridline is brighter than BOTH neighbors by a visible margin.
        if v - l > 4, v - r > 4 {
            // collapse adjacent columns of the same line: take local peak
            var best = x, bestV = v
            var xx = x + 1
            while xx < x1 {
                var vv = 0.0, ll = 0.0, rr = 0.0
                for y in rows { vv += lum(xx, y); ll += lum(xx - 3, y); rr += lum(xx + 3, y) }
                vv /= Double(rows.count); ll /= Double(rows.count); rr /= Double(rows.count)
                if vv - ll > 4, vv - rr > 4 { if vv > bestV { bestV = vv; best = xx }; xx += 1 } else { break }
            }
            cols.append(best)
            x = xx + 4
        } else { x += 1 }
    }
    return cols
}

let rulerRows = [372, 376, 380]
let lanesRows = [410, 420, 430]
let x0 = args.count > 2 ? Int(args[2])! : 1600
let rc = lineColumns(rows: rulerRows, from: x0, to: w - 20)
let lc = lineColumns(rows: lanesRows, from: x0, to: w - 20)
print("ruler lines (rows \(rulerRows)): \(rc)")
print("lanes lines (rows \(lanesRows)): \(lc)")
// pair each ruler line with the nearest lanes line and print deltas
var deltas: [Int] = []
for r in rc {
    if let n = lc.min(by: { abs($0 - r) < abs($1 - r) }), abs(n - r) < 40 {
        deltas.append(n - r)
    }
}
print("nearest-line deltas (lanes - ruler, px): \(deltas)")
