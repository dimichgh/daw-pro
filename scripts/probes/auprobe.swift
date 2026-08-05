// m23-av route (b) feasibility probe — ORIENTATION ONLY, reads nothing from the repo.
//
// Phase 1 (default, SAFE — no instantiation): enumerate installed AUs and report,
// for each, whether the system flags it `isV3AudioUnit` and whether it is
// delivered as an app EXTENSION (.appex) or a classic .component bundle.
// That pair is what decides whether out-of-process hosting is even available.
//
// Phase 2 (`--instantiate in|out <subtype>`): attempt ONE instantiation with the
// named option and report wall time / outcome. Run in its own process, because a
// wedging plug-in poisons the process it loads into.

import Foundation
import AVFoundation
import AudioToolbox
import CoreAudioKit

func fourCC(_ s: String) -> OSType {
    var r: OSType = 0
    for b in s.utf8.prefix(4) { r = (r << 8) | OSType(b) }
    return r
}
func str(_ c: OSType) -> String {
    let b = [UInt8((c >> 24) & 0xff), UInt8((c >> 16) & 0xff), UInt8((c >> 8) & 0xff), UInt8(c & 0xff)]
    return String(bytes: b, encoding: .ascii) ?? "????"
}

let args = CommandLine.arguments

if args.count >= 3, args[1] == "--instantiate" {
    let mode = args[2]
    let want = args.count >= 4 ? args[3] : "SgXT"
    var desc = AudioComponentDescription()
    desc.componentType = 0; desc.componentSubType = 0; desc.componentManufacturer = 0
    let all = AVAudioUnitComponentManager.shared().components(matching: desc)
    guard let match = all.first(where: { str($0.audioComponentDescription.componentSubType) == want }) else {
        print("PROBE: no component with subtype \(want)"); exit(2)
    }
    let cd = match.audioComponentDescription
    let isV3 = (cd.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue) != 0
    let opts: AudioComponentInstantiationOptions = (mode == "out") ? [.loadOutOfProcess] : [.loadInProcess]
    print("PROBE: \(match.name) subtype=\(str(cd.componentSubType)) isV3=\(isV3) mode=\(mode)")

    let start = DispatchTime.now()
    nonisolated(unsafe) var done = false
    nonisolated(unsafe) var result = "none"
    AUAudioUnit.instantiate(with: cd, options: opts) { au, err in
        let dt = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        if let au {
            // The question that matters: did it land in ANOTHER process?
            result = "OK in \(dt) s — renderResourcesAllocated=\(au.renderResourcesAllocated)"
        } else {
            result = "FAILED in \(dt) s — \(err.map { "\($0)" } ?? "nil error")"
        }
        done = true
    }
    // Pump the main run loop; out-of-process instantiation needs it.
    let deadline = Date().addingTimeInterval(90)
    while !done && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    let total = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    print("PROBE RESULT: \(done ? result : "NO CALLBACK within 90 s — WEDGED") (total \(total) s)")
    // --full: walk the rest of the real prepare path, timing each phase, to find
    // WHERE the wedge lives. Instantiation alone never reproduced it.
    if args.contains("--full"), done, result.hasPrefix("OK") {
        nonisolated(unsafe) var theAU: AUAudioUnit? = nil
        AUAudioUnit.instantiate(with: cd, options: opts) { au, _ in theAU = au }
        let dl = Date().addingTimeInterval(30)
        while theAU == nil && Date() < dl { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        guard let au = theAU else { print("PROBE: second instantiate failed"); exit(4) }

        func phase(_ name: String, _ body: () throws -> Void) {
            let t = DispatchTime.now()
            do { try body() } catch { print("PROBE PHASE \(name): THREW \(error)") }
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e9
            print("PROBE PHASE \(name): \(dt) s")
        }
        if let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) {
            phase("setFormat") { try au.outputBusses[0].setFormat(fmt) }
        }
        au.maximumFramesToRender = 512
        phase("allocateRenderResources") { try au.allocateRenderResources() }

        let t = DispatchTime.now()
        nonisolated(unsafe) var vcDone = false
        au.requestViewController { _ in vcDone = true }
        let vdl = Date().addingTimeInterval(120)
        while !vcDone && Date() < vdl { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        let vdt = Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e9
        print("PROBE PHASE requestViewController: \(vdt) s \(vcDone ? "" : "— NO CALLBACK (WEDGED)")")
    }
    // --hold N: keep the instance alive so an observer can look for a helper process.
    if let i = args.firstIndex(of: "--hold"), i + 1 < args.count, let secs = Double(args[i + 1]) {
        print("PROBE: holding \(secs) s (pid \(ProcessInfo.processInfo.processIdentifier))")
        Thread.sleep(forTimeInterval: secs)
        print("PROBE: released")
    }
    exit(done ? 0 : 3)
}

// ---- Phase 1: enumerate, no instantiation ----
var any = AudioComponentDescription()
let comps = AVAudioUnitComponentManager.shared().components(matching: any)
print("PROBE: \(comps.count) audio units visible\n")
print(String(format: "%-34@ %-6@ %-6@ %-6@ %-6@ %@", "name" as NSString, "type" as NSString,
             "sub" as NSString, "mfr" as NSString, "isV3" as NSString, "packaging"))
for c in comps.sorted(by: { $0.name < $1.name }) {
    let cd = c.audioComponentDescription
    let isV3 = (cd.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue) != 0
    let path = c.componentURL?.path ?? "<built-in>"
    let packaging: String
    if path.contains(".appex") { packaging = "APPEX (extension → out-of-process capable)" }
    else if path.hasSuffix(".component") { packaging = ".component" }
    else { packaging = path == "<built-in>" ? "built-in (Apple)" : path }
    // only print third-party + anything v3, to keep it readable
    if cd.componentManufacturer != fourCC("appl") || isV3 {
        print(String(format: "%-34@ %-6@ %-6@ %-6@ %-6@ %@",
                     String(c.name.prefix(33)) as NSString, str(cd.componentType) as NSString,
                     str(cd.componentSubType) as NSString, str(cd.componentManufacturer) as NSString,
                     (isV3 ? "YES" : "no") as NSString, packaging))
    }
}
