import Foundation
import Testing

/// Source pin for the **m22-e poll-discipline law** (stated verbatim at
/// `Sources/DAWApp/Mixer/ReferencePanelView.swift:26`, again at
/// `Components/GainReductionMeter.swift:38`): every live layer ticks in its own
/// UNPAUSED `TimelineView`, and NEVER
/// `.animation(paused: controlActiveState == .inactive)`.
///
/// **Why a test and not just a gate.** The behavioural proof lives in
/// `scripts/gates/m23r3b-live-layers.mjs`, which steals focus and measures that
/// each meter is still drawing — but that gate needs a staging app and a
/// display, so nobody runs it on the way past. This pin runs on every
/// `./scripts/test.sh`. It is the cheap half of a two-part defence, and it is
/// only the cheap half: **a token search finds the token, not the behaviour.**
/// If this fails, do not "fix" it by rewording; the idiom itself is the defect.
///
/// **The history it guards.** Apple's own guidance is to pause a timeline when
/// the window is inactive, and that guidance is wrong FOR THIS APP: agents drive
/// DAW Pro over a control socket, so its window is routinely not frontmost, and
/// a paused meter then freezes at a stale value while its data is live — a
/// readout that looks authoritative and has stopped. m22-b shipped the idiom on
/// the EQ spectrum (found and fixed at m23-r3, MEASURED as a frozen fill over an
/// armed tap); the same sweep then found three more live sites — the transport
/// vibe orb and both stereo-scope layers — fixed at m23-r3b. Twice now the fix
/// was one site and the family was four.
///
/// Anchored to the repo via `#filePath` (the `CanvasContractPinTests` idiom), so
/// it runs headless with no bundle resources.
@Suite("Poll-discipline pin — no paused-on-inactive live layers (m22-e law)")
struct PollDisciplinePinTests {

    /// Locate `<repo>/Sources` by walking up from this test file.
    private static func sourcesDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Sources from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    private static func swiftFiles() -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sourcesDir(), includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "swift" { out.append(url) }
        return out
    }

    /// One scan result: the non-comment hits (the violations) and the
    /// comment-only hits (the law's own prose). BOTH matter — a scan that finds
    /// nothing anywhere has a broken pattern, and its clean "zero violations" is
    /// then worth nothing at all.
    private struct Scan {
        var violations: [String] = []
        /// Comment mentions **per needle**, never summed. A single total is
        /// satisfiable by ONE contributor — see `noPausedOnInactiveTimelines`.
        var inComments: [String: Int] = [:]
        var timelineSites = 0
    }

    /// Scans every Swift file, skipping comment-only lines and trailing
    /// comments. This codebase writes the law down in doc comments in five
    /// files, so a raw match count can never reach zero — stripping comments is
    /// what makes ZERO the right assertion instead of an unenforceable one.
    private static func scan(_ needles: [String]) -> Scan {
        var scan = Scan()
        for url in swiftFiles() {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let name = url.lastPathComponent
            for (index, raw) in content.split(separator: "\n",
                                              omittingEmptySubsequences: false).enumerated() {
                let line = String(raw)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isComment = trimmed.hasPrefix("//") || trimmed.hasPrefix("*")
                    || trimmed.hasPrefix("/*")
                let code = isComment ? "" : (line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line)
                if code.contains("TimelineView(") { scan.timelineSites += 1 }
                for needle in needles {
                    if isComment {
                        if line.contains(needle) { scan.inComments[needle, default: 0] += 1 }
                    } else if code.contains(needle) {
                        scan.violations.append("  \(name):\(index + 1)  \(trimmed)")
                    }
                }
            }
        }
        return scan
    }

    @Test("no live layer pauses on window-inactive anywhere in Sources/")
    func noPausedOnInactiveTimelines() {
        // Two needles, deliberately: `controlActiveState` catches the idiom as
        // written, and a bare `paused:` catches the same mistake spelled some
        // other way (`paused: !isActive`, a hoisted helper). No TimelineView in
        // this app has a legitimate reason to pause — a live layer that should
        // stop should not be on screen.
        let needles = ["controlActiveState", "paused:"]
        let scan = Self.scan(needles)

        // ANTI-VACUITY, two ways. A pin whose scan silently walked nothing
        // reports a clean zero, which is the most dangerous kind of green.
        let walkNote = "expected at least 10 TimelineView sites in Sources/, found "
            + "\(scan.timelineSites) — the file walk or the match broke, and the zero "
            + "below would be meaningless"
        #expect(scan.timelineSites >= 10, "\(walkNote)")

        // PER NEEDLE, never summed. The law's verbatim text —
        // `.animation(paused: controlActiveState == .inactive)` — contains BOTH
        // needles on ONE line, so any AGGREGATE threshold is cleared by
        // `controlActiveState` alone while `paused:` matches nothing, ever:
        // half a pin wearing the other half's green. Each needle proves itself
        // against the prose, so a typo in one is a red, not a silent hole.
        // (Both were proved to redden on real code by disjoint mutation at
        // m23-r3b: `controlActiveState` at GainReductionMeter.swift:44,
        // `paused:` — with no `controlActiveState` token present — at :61.)
        for needle in needles {
            let hits = scan.inComments[needle] ?? 0
            let note = "the needle '\(needle)' matched \(hits) comment mentions. This "
                + "law is written down in prose in several files, so ZERO means the "
                + "needle itself is broken and the clean scan below proves nothing "
                + "about that half of the idiom"
            #expect(hits >= 1, "\(note)")
        }

        // The `paused:` needle is deliberately broad, so one day it will hit an
        // argument label that has nothing to do with a timeline schedule. That is
        // the moment this pin is most likely to be deleted for being "wrong", so
        // the instruction for it ships INSIDE the failure the reader will see.
        let violationNote: String = "m22-e POLL-DISCIPLINE VIOLATION — a live layer pauses on "
            + "window-inactive. It will freeze at a stale value whenever DAW Pro is "
            + "not frontmost, which for a socket-driven app is most of the time. Use "
            + "an UNPAUSED TimelineView(.periodic(from: .now, by: rate)) and choose "
            + "the rate deliberately — rate follows the meter's BALLISTICS (sample "
            + "several times per attack tau), not how long its surface lives. If a "
            + "hit below is NOT a TimelineView schedule, this pin is over-broad, not "
            + "wrong: NARROW THE NEEDLE to the schedule. Never delete the pin — the "
            + "idiom it guards has come back twice.\n"
            + scan.violations.joined(separator: "\n")
        #expect(scan.violations.isEmpty, "\(violationNote)")
    }
}
