import Foundation

// Sample-library import orchestration (m19-c/m19-d, design §5.1):
// extension dispatch → (SFZ only) preprocess → parse → map, then (apply
// mode) the EXISTING instrument-set path so an import journals/undoes like
// any other instrument edit — one command surface, UI and wire converge
// here.
extension ProjectStore {
    /// Imports a sample-library file onto an INSTRUMENT track's built-in
    /// Sampler. Supported: `.sfz` (documented subset) and `.dspreset` — see
    /// docs/SFZ-SUPPORT.md for the exact boundary; `.dslibrary` errors with
    /// the unzip hint.
    ///
    /// `dryRun` computes the full `SampleLibraryImportReport` and touches
    /// NOTHING — no edit, no undo entry, no engine reconcile. Apply mode
    /// routes through `setInstrument(kind: .sampler, sampler:)`, so the
    /// change is ONE journaled "Change Instrument" step (undo restores the
    /// previous instrument), zone media is validated by the same path every
    /// sampler edit uses, and zero playable zones is a refusal (§2.3: never
    /// a silent empty instrument). `force` overrides the mapper's 4 GB
    /// sample-size refusal (the 500 MB warning always reports).
    ///
    /// Copy law: this imports ".sfz (documented subset) and .dspreset
    /// sample-library files" — never a product-compatibility claim.
    @discardableResult
    public func importSampleLibrary(trackID: UUID, path: String,
                                    dryRun: Bool = false,
                                    force: Bool = false) throws
        -> SampleLibraryImportReport {
        // Track guards FIRST (fail fast, before any file work) — the
        // setInstrument kind rule: only instrument tracks host instruments.
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard tracks[index].kind == .instrument else {
            throw ProjectError.instrumentRequiresInstrumentTrack(tracks[index].kind)
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let format = url.pathExtension.lowercased()
        switch format {
        case "sfz", "dspreset":
            break
        case "dslibrary":
            throw SampleLibraryImportError.dslibraryIsZipArchive
        default:
            throw SampleLibraryImportError.notASampleLibrary(
                fileName: url.lastPathComponent)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SampleLibraryImportError.fileNotFound(path: url.path)
        }

        // Per-format parse onto the shared IR, then the ONE §2.3 policy
        // pass. SFZ preprocesses first (structured aborts: missing/cyclic
        // includes, undefined $VARs); a `.dspreset` is one self-contained
        // XML file — no preprocessor step, structured aborts only for
        // malformed XML / a wrong root element.
        let ir: SampleLibraryIR
        if format == "sfz" {
            let text = try SFZPreprocessor.preprocess(fileAt: url)
            ir = SFZParser.parse(text: text,
                                 baseDirectory: url.deletingLastPathComponent())
        } else {
            ir = try DSPresetParser.parse(fileAt: url)
        }
        var (params, report) = try SampleLibraryMapper.map(ir, force: force)
        // m26-h: record WHICH library this is, here and nowhere else. The
        // mapper cannot do it — `SampleLibraryIR` carries only `baseDirectory`,
        // not the main file — and no caller may do it, because a provenance an
        // agent can assert is a provenance that can lie. Before this, an
        // imported track read `kind: "sampler"` and nothing else, so "which
        // bass is this?" meant dumping a ~1 MB snapshot and eyeballing a zone's
        // directory (field report 2026-08-17, finding 13).
        params.sourcePath = url.path
        let stem = url.deletingPathExtension().lastPathComponent
        params.displayName = stem.isEmpty ? url.lastPathComponent : stem

        if dryRun { return report }
        guard !params.zones.isEmpty else {
            throw SampleLibraryImportError.noPlayableZones(report)
        }
        // The EXISTING instrument-set path: journaled ("Change Instrument"),
        // zone media validated before the edit, engine reconciles via
        // tracksDidChange — an import is just a big sampler edit.
        _ = try setInstrument(id: trackID, kind: .sampler, sampler: params)
        return report
    }
}
