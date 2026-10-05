// screenrec — record ONE window to an mp4 with ScreenCaptureKit.
//
// WHY THIS EXISTS. `debug.captureUI` is the default capture method for this
// project and stays that way: it is headless, needs no permission, and does not
// put the app on the user's screen. But it runs at about 3.5 fps (MEASURED;
// `scale` does not change it), so it cannot film MOTION — a control actually
// being dragged, a terminal scrolling, a playhead sweeping. This tool is for
// exactly that and nothing else.
//
// ⚠️ IT NEEDS THE SCREEN RECORDING PERMISSION, granted to the app that RUNS it
// (Terminal, not this binary): System Settings -> Privacy & Security -> Screen &
// System Audio Recording. The grant takes effect when Terminal is relaunched.
// Without it, ScreenCaptureKit does not error in an obvious way — it reports a
// shareable-content list with NO windows, which reads exactly like "that window
// is not open". `--list` therefore says so explicitly rather than printing an
// empty list, because an empty list and a missing permission are the same
// output, and this project has been burned by that shape repeatedly.
//
// Build:  swiftc -O -swift-version 5 -framework ScreenCaptureKit \
//                -framework AVFoundation -o screenrec screenrec.swift
import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// ── args ────────────────────────────────────────────────────────────────────
func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name),
          i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
let wantsList = CommandLine.arguments.contains("--list")
let titleQuery = arg("--window-title")
let appQuery = arg("--app")
let outPath = arg("--out") ?? "screenrec.mp4"
let seconds = Double(arg("--seconds") ?? "10") ?? 10
let fps = Int(arg("--fps") ?? "30") ?? 30
let scale = Double(arg("--scale") ?? "1.0") ?? 1.0

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("screenrec: " + msg + "\n").data(using: .utf8)!)
    exit(2)
}

// ── content ─────────────────────────────────────────────────────────────────
func shareable() async throws -> SCShareableContent {
    try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
}

/// ⚠️ An empty window list is AMBIGUOUS: no permission, or nothing on screen.
/// Never let the caller read one as the other.
func windows(_ content: SCShareableContent) -> [SCWindow] {
    content.windows.filter { ($0.title?.isEmpty == false) && $0.frame.width > 60 }
}

func permissionHint() -> String {
    """
    no capturable windows were returned.

    That means ONE of two things and they look identical from here:
      1. the Screen Recording permission has not been granted, or
      2. there genuinely is no matching on-screen window.

    Grant it to the app running this (Terminal, not this binary):
      System Settings -> Privacy & Security -> Screen & System Audio Recording
    then RELAUNCH Terminal -- the grant does not apply to an already-running
    process. `claude --continue` picks the session back up afterwards.
    """
}

// ── writer ──────────────────────────────────────────────────────────────────
final class Sink: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    private var started = false
    private var frames = 0
    private let lock = NSLock()

    init(url: URL, width: Int, height: Int, fps: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * fps / 12),
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw NSError(domain: "screenrec", code: 1) }
        writer.add(input)
        super.init()
    }

    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return frames }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, CMSampleBufferGetImageBuffer(sb) != nil else { return }
        // ⚠️ SCStream delivers a buffer every frame interval whether or not the
        // window CHANGED, and the unchanged ones carry no new pixels. Writing
        // them produces a file whose frame count looks right and whose motion
        // is wrong. Only `.complete` frames carry an image.
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = arr.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else { return }

        lock.lock(); defer { lock.unlock() }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sb))
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sb)
            frames += 1
        }
    }

    // ⚠️ Taking an NSLock directly inside an async function is a warning today
    // and an ERROR in the Swift 6 language mode this project builds under
    // everywhere else. Read the flag through a synchronous helper instead.
    private func didStart() -> Bool { lock.lock(); defer { lock.unlock() }; return started }

    func finish() async {
        guard didStart() else { return }
        input.markAsFinished()
        await writer.finishWriting()
    }
}

// ── main ────────────────────────────────────────────────────────────────────
// ⚠️ SCStream CAPTURE REQUIRES A WINDOW-SERVER CONNECTION, and a bare CLI does
// not have one: `startCapture` aborts with
//   Assertion failed: (did_initialize), function CGS_REQUIRE_INIT
// Note that LISTING content works fine without it, so `--list` succeeding
// proves nothing about whether capture will. Initialising NSApplication as an
// `.accessory` gives us the connection without putting an icon in the Dock or
// stealing focus from the window we are trying to film.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task {
    do {
        let content = try await shareable()
        let wins = windows(content)
        if wantsList {
            if wins.isEmpty { die(permissionHint()) }
            print("\(wins.count) capturable windows:")
            for w in wins {
                let app = w.owningApplication?.applicationName ?? "?"
                print(String(format: "  [%d] %-28s %@  (%.0fx%.0f)",
                             w.windowID, (app as NSString).utf8String!,
                             w.title ?? "", w.frame.width, w.frame.height))
            }
            exit(0)
        }
        if wins.isEmpty { die(permissionHint()) }

        var picked = wins
        if let q = appQuery {
            picked = picked.filter {
                ($0.owningApplication?.applicationName ?? "").localizedCaseInsensitiveContains(q)
            }
        }
        if let q = titleQuery {
            picked = picked.filter { ($0.title ?? "").localizedCaseInsensitiveContains(q) }
        }
        guard let win = picked.sorted(by: { $0.frame.width * $0.frame.height >
                                            $1.frame.width * $1.frame.height }).first else {
            die("no window matched"
                + (appQuery.map { " --app \($0)" } ?? "")
                + (titleQuery.map { " --window-title \($0)" } ?? "")
                + ". Run with --list to see what is capturable.")
        }

        // Even dimensions: h264 refuses odd ones, and the failure is late and cryptic.
        let w = Int((win.frame.width * scale).rounded()) & ~1
        let h = Int((win.frame.height * scale).rounded()) & ~1
        let cfg = SCStreamConfiguration()
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.queueDepth = 6
        cfg.showsCursor = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA

        let sink = try Sink(url: URL(fileURLWithPath: outPath), width: w, height: h, fps: fps)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: win),
                              configuration: cfg, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "screenrec.frames"))
        FileHandle.standardError.write(
            "recording \"\(win.title ?? "")\" (\(w)x\(h)) for \(seconds)s at \(fps) fps\n"
                .data(using: .utf8)!)
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        // A stream that already ended makes stopCapture throw. Finishing the
        // writer still has to happen, or a real partial recording is discarded.
        try? await stream.stopCapture()
        await sink.finish()

        // ⭐ REPORT THE FRAME COUNT. A recorder that produced a valid but EMPTY
        // mp4 is the failure this project keeps meeting in other forms, and the
        // count is the one number that separates it from a real recording.
        let n = sink.frameCount
        FileHandle.standardError.write("wrote \(outPath) — \(n) frames\n".data(using: .utf8)!)
        if n == 0 { die("ZERO frames captured; the file is not a recording.") }
        exit(0)
    } catch {
        // ⚠️ DO NOT append the permission hint here. An earlier version did, and
        // a plain stream failure at an unsupported capture size printed a
        // confident "you have not granted Screen Recording" — a wrong diagnosis
        // that looked authoritative. The hint belongs ONLY where the symptom is
        // actually ambiguous: an empty window list.
        die("capture failed: \(error.localizedDescription)")
    }
}
app.run()
