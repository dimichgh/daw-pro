// m23-b offscreen gutter harness.
//
// Build (after `swift build`, from the repo root — it compiles the REAL
// Theme.swift + KeyboardSidebar.swift against the built module objects, so it
// can never drift from what the app draws):
//
//   swiftc -O -o /tmp/m23b-harness scripts/probes/m23b-gutter-fullrange.swift \
//     Sources/DAWApp/Theme.swift Sources/DAWApp/PianoRoll/KeyboardSidebar.swift \
//     -I .build/debug/Modules \
//     .build/debug/DAWAppKit.build/*.o .build/debug/DAWCore.build/*.o \
//     .build/debug/AIServices.build/*.o -framework SwiftUI -framework AppKit
//   /tmp/m23b-harness <ABSOLUTE outdir> <tag>
//
// Renders the REAL `KeyboardSidebar` (compiled from Sources/DAWApp, not a copy)
// over the FULL 128-row pitch range into a PNG, so the pitch extremes the app
// viewport can never show (1792 pt of content vs ~1117 pt of screen, and the
// roll's `.defaultScrollAnchor(.center)` pins the window to the middle) are
// still reviewable. Also samples pixels at every octave label so the contrast
// claim is measured, not eyeballed.
import SwiftUI
import AppKit
import DAWAppKit

/// A faithful sRGB pixel buffer: the CGImage is redrawn into an explicit sRGB
/// context and read as raw bytes. (Sampling via `NSBitmapImageRep.colorAt`
/// instead reports device-RGB values reinterpreted as sRGB — every hex comes
/// out several steps light, which would quietly inflate every ratio below.)
struct Pixels {
    let w: Int, h: Int
    let bytes: [UInt8]
    func at(_ x: Int, _ y: Int) -> (Double, Double, Double)? {
        guard x >= 0, y >= 0, x < w, y < h else { return nil }
        let i = (y * w + x) * 4
        return (Double(bytes[i]), Double(bytes[i + 1]), Double(bytes[i + 2]))
    }
}

/// Slices the (very tall, very narrow) full-range column into N vertical bands
/// laid out side by side, so the whole 128-row gutter is reviewable at 1:1 in
/// one frame instead of a 3584 px strip nothing can display.
func sheet(_ cg: CGImage, bands: Int, to path: String) {
    let bandH = Int((Double(cg.height) / Double(bands)).rounded(.up))
    let gap = 16
    let w = (cg.width + gap) * bands - gap
    guard let ctx = CGContext(
        data: nil, width: w, height: bandH, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(CGColor(srgbRed: 0.043, green: 0.051, blue: 0.071, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: bandH))
    for i in 0..<bands {
        // CGImage y is top-down; band 0 is the TOP of the column (highest pitch).
        let y = i * bandH
        let h = min(bandH, cg.height - y)
        guard h > 0, let slice = cg.cropping(to: CGRect(x: 0, y: y, width: cg.width, height: h)) else { continue }
        // CGContext y is bottom-up: draw each slice flush to the TOP of the sheet.
        ctx.draw(slice, in: CGRect(x: i * (cg.width + gap), y: bandH - h, width: cg.width, height: h))
    }
    guard let out = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: out)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

@MainActor
func render(to path: String, model: PianoRollModel, width: CGFloat) -> Pixels? {
    let view = KeyboardSidebar(model: model, width: width)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    renderer.isOpaque = true
    guard let cg = renderer.cgImage else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
    sheet(cg, bands: 4, to: path.replacingOccurrences(of: "gutter-full", with: "gutter-sheet"))
    // 3× zoom on pitches 50…76 (the middle-C neighbourhood) — the one place a
    // by-eye call is being made (bold vs medium as the middle-C landmark).
    let topPt = Double(PianoRollModel.pitchCount - 1 - 76) * 14.0
    let hPt = Double(76 - 50 + 1) * 14.0
    if let crop = cg.cropping(to: CGRect(x: 0, y: topPt * 2, width: Double(cg.width), height: hPt * 2)),
       let ctx = CGContext(data: nil, width: crop.width * 3, height: crop.height * 3,
                           bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        ctx.interpolationQuality = CGInterpolationQuality.none
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width * 3, height: crop.height * 3))
        if let out = ctx.makeImage(),
           let data = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath:
                path.replacingOccurrences(of: "gutter-full", with: "gutter-middleC")))
        }
    }
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(
        data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return Pixels(w: w, h: h, bytes: buf)
}

/// sRGB relative luminance + WCAG contrast, on 0...255 channels.
func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
    func lin(_ c: Double) -> Double {
        let v = c / 255
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}
func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
    let la = luminance(a.0, a.1, a.2), lb = luminance(b.0, b.1, b.2)
    let hi = max(la, lb), lo = min(la, lb)
    return (hi + 0.05) / (lo + 0.05)
}

@MainActor
func main() {
    let out = CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : FileManager.default.currentDirectoryPath
    let tag = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "state"
    let width: CGFloat = 54
    let model = PianoRollModel()
    let rowHeight = model.rowHeight

    guard let rep = render(to: "\(out)/gutter-full-\(tag).png", model: model, width: width) else {
        print("RENDER FAILED"); exit(1)
    }
    print("rendered \(rep.w)x\(rep.h) px (scale 2) -> gutter-full-\(tag).png")

    // ---- measured checks, per octave ----
    // Label row band for pitch p: y = (127 - p) * rowHeight ... + rowHeight,
    // baseline centered at y + rowHeight/2, drawn trailing at x = width - 4.
    func px(_ xPt: Double, _ yPt: Double) -> (Double, Double, Double)? {
        rep.at(Int(xPt * 2), Int(yPt * 2))
    }
    func hexOf(_ c: (Double, Double, Double)) -> String {
        String(format: "#%02X%02X%02X", Int(c.0.rounded()), Int(c.1.rounded()), Int(c.2.rounded()))
    }

    print("\n pitch  note   key-bg      darkest-ink  contrast   inkpixels(of label band)")
    for p in stride(from: 0, through: 120, by: 12) {
        let yTop = Double(PianoRollModel.pitchCount - 1 - p) * Double(rowHeight)
        // Key background sample: left third of the row, clear of the label and
        // clear of the 1 pt octave marker at the row top.
        guard let bg = px(6, yTop + Double(rowHeight) / 2) else { continue }
        // Scan the label band (right 34 pt, vertically the middle 9 pt) for the
        // ink pixel furthest from the background — that's the glyph core.
        var worst = bg
        var worstC = 1.0
        var inkPixels = 0
        var yy = yTop + 2.0
        while yy < yTop + Double(rowHeight) - 1.5 {
            var xx = Double(width) - 38
            while xx < Double(width) - 3 {
                if let c = px(xx, yy) {
                    let k = contrast(c, bg)
                    if k > 1.6 { inkPixels += 1 }
                    if k > worstC { worstC = k; worst = c }
                }
                xx += 0.5
            }
            yy += 0.5
        }
        let names = ["C-1", "C0", "C1", "C2", "C3", "C4", "C5", "C6", "C7", "C8", "C9"]
        let name = names[p / 12]
        print(String(format: "  %3d   %-4@  %@   %@    %6.2f:1   %d",
                     p, name as NSString, hexOf(bg), hexOf(worst), worstC, inkPixels))
    }

    // Row-separator visibility on both key colors, and the white|white key gap.
    print("\n--- structural lines (contrast vs the row they sit on) ---")
    func lineCheck(_ label: String, pitch: Int, dy: Double) {
        let yTop = Double(PianoRollModel.pitchCount - 1 - pitch) * Double(rowHeight)
        guard let line = px(6, yTop + dy), let body = px(6, yTop + Double(rowHeight) / 2) else { return }
        print(String(format: "  %-34@ line %@  row %@  %5.2f:1",
                     label as NSString, hexOf(line), hexOf(body), contrast(line, body)))
    }
    lineCheck("separator on WHITE (E|F gap, p=64)", pitch: 64, dy: 0.25)
    lineCheck("separator on WHITE (B|C gap, p=71)", pitch: 71, dy: 0.25)
    lineCheck("separator on BLACK (p=66 F#)", pitch: 66, dy: 0.25)
    lineCheck("octave marker on WHITE (p=72 C5)", pitch: 72, dy: 0.5)
    lineCheck("octave marker middle C (p=60)", pitch: 60, dy: 0.5)

    // Right-edge hairline, both colors.
    print("\n--- right edge (contrast vs its own row) ---")
    for (n, p) in [("white row C5", 72), ("black row F#4", 66)] {
        let yTop = Double(PianoRollModel.pitchCount - 1 - p) * Double(rowHeight)
        guard let edge = px(Double(width) - 0.25, yTop + Double(rowHeight) / 2),
              let body = px(6, yTop + Double(rowHeight) / 2) else { continue }
        print(String(format: "  %-14@ edge %@  row %@  %5.2f:1",
                     n as NSString, hexOf(edge), hexOf(body), contrast(edge, body)))
    }

    // Key alternation.
    if let w = px(6, Double(127 - 72) * Double(rowHeight) + 7),
       let b = px(6, Double(127 - 66) * Double(rowHeight) + 7) {
        print(String(format: "\n  white %@ vs black %@ alternation %5.2f:1", hexOf(w), hexOf(b), contrast(w, b)))
    }
    exit(0)
}

MainActor.assumeIsolated { main() }
