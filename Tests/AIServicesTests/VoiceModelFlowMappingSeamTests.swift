import Foundation
import Testing

@testable import AIServices

/// m23-fn — the normalising-flow slot-mapping fix, pinned from the Swift side.
///
/// The defect this guards: a raw RVC checkpoint stores its coupling layers at
/// the EVEN PyTorch indices `flow.flows.{0,2,4,6}` (the odd ones are `Flip`
/// modules). The MLX port declares `flow.flow_0 … flow.flow_3`. The loader
/// that actually runs — `remap_keys`, `rvc_mlx/infer/infer_mlx.py:66-80` —
/// renames VERBATIM, producing `flow_0/2/4/6`; the vendored tree's OTHER
/// implementation of the same mapping, `tools/convert_rvc_model.py:179-188`,
/// computes `real_idx = flow_idx // 2` and documents why. Because
/// `load_weights(..., strict=False)` (`infer_mlx.py:248`) turns an unsupplied
/// parameter into a silent success, the verbatim path leaves `flow_1` and
/// `flow_3` at a FRESH RANDOM DRAW on every construction, puts the
/// checkpoint's flow 2 in `flow_2` where `flow_1` belongs, and discards 36
/// tensors. Measured 18/0/18/0 filled of 19 declared per slot; corrected,
/// 18/18/18/18 with zero discarded and zero cross-process variation.
///
/// **Why these tests are structural rather than numeric.** The measurement
/// itself needs MLX and a 70 MB checkpoint, so it lives in
/// `scripts/rvc-model/gate_flow_mapping.py` (phases B/C/D) and is run against
/// a real model. What Swift can guard cheaply and usefully is that the fix
/// exists, is outside the read-only `scripts/rvc/` fence, still computes
/// `// 2`, and is NAMED at the import seam that will one day produce `.npz`
/// files (`m23-di-2b`, blocked on the user). The last one is the one that
/// matters: an import path written later must not silently reintroduce the
/// defect.
///
/// Test 4 is not a file-existence check — it EXECUTES the tool's stdlib-only
/// gate phase, which includes an equality assertion against the documented
/// reference mapping and three refusal guards.
@Suite("Voice model flow-slot mapping seam (m23-fn)")
struct VoiceModelFlowMappingSeamTests {
    /// Walk up from this test file to the repository root.
    private func repoRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path)
            {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate the repo root from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    @Test("the flow-slot corrector exists at the path the import seam names")
    func correctorExists() {
        let path = repoRoot().appendingPathComponent(
            VoiceModelImport.flowMappingCorrectorPath)
        #expect(
            FileManager.default.fileExists(atPath: path.path),
            """
            m23-fn's corrector is missing at \(path.path). Every .npz this \
            project produces must route through it, or two of four flow \
            coupling layers run on random weights.
            """)
    }

    @Test("the corrector lives OUTSIDE the read-only scripts/rvc/ fence")
    func correctorIsOutsideTheFence() {
        let rel = VoiceModelImport.flowMappingCorrectorPath
        #expect(
            !rel.hasPrefix("scripts/rvc/"),
            """
            \(rel) is inside the read-only vendored tree. The whole point of \
            this fix is that it needs no fenced write: remap_keys only \
            rewrites keys beginning 'flow.flows.' (plural), so corrected \
            'flow.flow_N.…' names pass through the unmodified loader.
            """)
    }

    @Test("the corrector still computes the reference i // 2 slot mapping")
    func correctorStillHalvesTheIndex() throws {
        let path = repoRoot().appendingPathComponent(
            VoiceModelImport.flowMappingCorrectorPath)
        let source = try String(contentsOf: path, encoding: .utf8)
        #expect(
            source.contains("raw_idx // 2"),
            """
            the corrector no longer halves the PyTorch flow index. Verbatim \
            renaming is exactly the m23-fn defect: flow_1 and flow_3 receive \
            nothing and keep a fresh random draw per load.
            """)
    }

    @Test("the corrector's own stdlib gate phase passes (mapping + refusals)")
    func correctorGatePhasePasses() throws {
        let root = repoRoot()
        let gate = root.appendingPathComponent("scripts/rvc-model/gate_flow_mapping.py")
        try #require(FileManager.default.fileExists(atPath: gate.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", gate.path, "--no-vendored"]
        // The vendored tree is READ-ONLY, .pyc included. The gate does not
        // import it in this mode, but the discipline is unconditional.
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        #expect(
            process.terminationStatus == 0,
            "m23-fn mapping gate went RED:\n\(output)")
        #expect(
            output.contains("GATE GREEN"),
            "gate produced no green verdict:\n\(output)")
    }

    @Test("the import seam's documentation names the corrector, so it cannot be orphaned")
    func importSeamNamesTheCorrector() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "Sources/AIServices/VoiceModelImport.swift"), encoding: .utf8)
        #expect(source.contains("scripts/rvc-model/flow_remap.py"))
        #expect(
            source.contains("convert_pth_to_mlx.py"),
            """
            the import seam must keep naming the converter that CAUSES the \
            defect, or a future m23-di-2b implementation will reach for it \
            without knowing.
            """)
    }
}
