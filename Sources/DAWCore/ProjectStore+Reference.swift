import Foundation

/// Reference-track store ops (m22-g, design-m22g-reference-tracks §3.4).
/// P1 verbs: import / remove / analyze / status; P2 verbs: the A/B monitor
/// (transient, never journaled), offset, trim, and compare.
///
/// Recording guard: none of these verbs is announce-capable (the monitor
/// lane is permanent, design §5.1), so all stay legal mid-record per the
/// m13-c doctrine — `requireRoutingMutationAllowed` is NOT extended.
@MainActor
extension ProjectStore {

    /// Imports an audio file as THE project reference: copies it into the
    /// stable References/ app-support home (import copies, never moves —
    /// the SoundBank/VoiceDataset law), probes it via the media service,
    /// runs the one-time engine-side analysis, and sets the slot as ONE
    /// journaled edit — REPLACING any existing slot in the SAME edit, so a
    /// single undo restores the prior slot (orchestrator decision, design
    /// §12.4). Analysis failure is NOT fatal: the slot lands with
    /// `analysis: nil` plus a warning in the outcome (the sanitized-load
    /// idiom; `reference.analyze` retries).
    ///
    /// The file copy runs detached off the main actor (the m10-n
    /// detached-load precedent); the engine runs the analysis in its own
    /// detached context.
    @discardableResult
    public func importReference(path: String, name: String? = nil) async throws
        -> ReferenceImportOutcome {
        guard let media else { throw ProjectError.mediaServiceUnavailable }
        let expanded = (path as NSString).expandingTildeInPath
        let sourceURL = URL(fileURLWithPath: expanded).standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ProjectError.importFailed("no file at \(sourceURL.path)")
        }
        // Probe first — a non-audio file refuses HERE with the importer's
        // own message, before anything is copied or mutated.
        _ = try media.audioFileInfo(at: sourceURL)

        // Copy into the stable pre-save home, uniquified on collision
        // (never overwrite an earlier import's bytes), off the main actor.
        let importsDir = referenceImportsDirectory
        let stableURL = try await Task.detached(priority: .userInitiated) {
            try Self.copyReferenceSource(sourceURL, into: importsDir)
        }.value

        // One-time analysis via the engine seam (throwing default). A
        // headless store, an engine without the capability, or a real
        // analysis failure all land the slot WITHOUT analysis + a warning.
        var warnings: [String] = []
        var analysis: ReferenceAnalysis?
        if let engine {
            do {
                analysis = try await engine.analyzeReferenceFile(at: stableURL)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                warnings.append(
                    "reference analysis failed (\(reason)) — the reference was "
                    + "imported without analysis; run reference.analyze to retry")
            }
        } else {
            warnings.append(
                "no audio engine attached — the reference was imported without analysis; "
                + "run reference.analyze once an engine is available")
        }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (trimmedName?.isEmpty == false)
            ? trimmedName!
            : sourceURL.deletingPathExtension().lastPathComponent
        let slot = ReferenceSlot(
            name: displayName, sourcePath: stableURL.path, analysis: analysis)
        // Replacing the slot mid-audition ends the OLD reference's monitor
        // first (m22-g P2): a new file needs a fresh toggle-ON (fresh match
        // basis) — the lane is never silently re-aimed.
        stopReferenceMonitorIfNeeded()
        performEdit("Import Reference") {
            // Replace-in-one-edit: the captured before-state carries any
            // prior slot, so one undo restores it (analysis included).
            reference = slot
        }
        engine?.referenceChanged(slot)
        return ReferenceImportOutcome(slot: slot, warnings: warnings)
    }

    /// Clears the reference slot as one journaled edit ("Remove Reference");
    /// one undo restores the slot, analysis included. The imported copy in
    /// References/ is NOT deleted (no GC — the undo-resurrection rationale
    /// the bundle media/ policy documents). Empty slot → the
    /// `referenceNotSet` teaching error.
    @discardableResult
    public func removeReference() throws -> ReferenceSlot {
        guard let slot = reference else { throw ProjectError.referenceNotSet }
        // Removing the slot mid-audition ends the monitor (m22-g P2) — the
        // mix un-gates; a removed reference must never keep sounding.
        stopReferenceMonitorIfNeeded()
        performEdit("Remove Reference") {
            reference = nil
        }
        engine?.referenceChanged(nil)
        return slot
    }

    /// Re-runs the one-time analysis on demand (missing/failed/
    /// analyzer-version-bumped analysis) and stores the fresh result as one
    /// journaled edit ("Analyze Reference"). Refusals, verbatim: no slot →
    /// `referenceNotSet`; file gone from disk → `referenceFileMissing`
    /// (naming the path and the fixing verb); headless / no capability →
    /// `engineUnavailable` (the throwing-default seam).
    @discardableResult
    public func analyzeReference() async throws -> ReferenceAnalysis {
        guard let slot = reference else { throw ProjectError.referenceNotSet }
        guard FileManager.default.fileExists(atPath: slot.sourcePath) else {
            throw ProjectError.referenceFileMissing(slot.sourcePath)
        }
        guard let engine else { throw ProjectError.engineUnavailable }
        let analysis = try await engine.analyzeReferenceFile(
            at: URL(fileURLWithPath: slot.sourcePath))
        // Async race (the analyzeClipAudio re-locate rule): the slot may
        // have been replaced/removed while the analysis ran — a stale
        // result must never land on a different slot.
        guard var current = reference, current.id == slot.id else {
            throw ProjectError.referenceNotSet
        }
        performEdit("Analyze Reference") {
            current.analysis = analysis
            reference = current
        }
        engine.referenceChanged(current)
        return analysis
    }

    /// Read-only status for `reference.status` — never throws (the design's
    /// read-only contract): the slot (nil when none), the transient monitor
    /// state, and the `wouldMatchGainDb` preview computed through the exact
    /// `ReferenceLevelMatch` law whenever the slot carries a computable
    /// analysis (basis = the live mix integrated when an engine reports
    /// one, else the −14 LUFS fallback). While MONITORING the toggle-ON
    /// snapshot's `matchGainDb`/`matchBasis`/`ceilingLimited` ride too —
    /// never emitted un-monitored (the reserved-fields contract).
    public func referenceStatus() -> ReferenceStatus {
        var wouldMatchGainDb: Double?
        if let slot = reference, let analysis = slot.analysis,
           let refLufs = analysis.integratedLufs {
            let mixLufs = engine?.liveLoudness(reset: false)?.integratedLufs
            wouldMatchGainDb = ReferenceLevelMatch.compute(
                mixIntegratedLufs: mixLufs,
                refIntegratedLufs: refLufs,
                refTruePeakDbtp: analysis.truePeakDbtp,
                trimDb: slot.trimDb).matchGainDb
        }
        if let monitor = referenceMonitor {
            return ReferenceStatus(
                reference: reference,
                monitoring: true,
                wouldMatchGainDb: wouldMatchGainDb,
                matchGainDb: monitor.match.matchGainDb,
                matchBasis: monitor.match.matchBasis,
                ceilingLimited: monitor.match.ceilingLimited)
        }
        return ReferenceStatus(
            reference: reference,
            monitoring: false,
            wouldMatchGainDb: wouldMatchGainDb)
    }

    // MARK: - P2: A/B monitor, offset, trim, compare

    /// Toggles the A/B monitor (design D4/§5.6). ON: the refusal ladder
    /// throws verbatim teaching errors (no slot → `referenceNotSet`; no
    /// analysis → `referenceNotAnalyzed`; gated-silent → `referenceSilent`;
    /// file gone → `referenceFileMissing`; headless → `engineUnavailable`),
    /// then the level-match law is computed ONCE from the live mix
    /// integrated (or the −14 LUFS fallback) and SNAPSHOTTED — the gain
    /// never chases the evolving reading mid-audition. OFF: idempotent,
    /// never throws. NOT journaled — transient state, the `isPlaying`
    /// analogy (design §3.4).
    @discardableResult
    public func setReferenceMonitor(on: Bool) throws -> ReferenceMonitorResult {
        guard on else {
            stopReferenceMonitorIfNeeded()
            return ReferenceMonitorResult(monitoring: false)
        }
        guard let slot = reference else { throw ProjectError.referenceNotSet }
        guard let analysis = slot.analysis else { throw ProjectError.referenceNotAnalyzed }
        guard let refLufs = analysis.integratedLufs else { throw ProjectError.referenceSilent }
        guard FileManager.default.fileExists(atPath: slot.sourcePath) else {
            throw ProjectError.referenceFileMissing(slot.sourcePath)
        }
        guard let engine else { throw ProjectError.engineUnavailable }
        // Snapshot the basis at toggle-ON (design §5.6): nil reading → the
        // −14 LUFS fallback inside the law, surfaced as matchBasis.
        let mixLufs = engine.liveLoudness(reset: false)?.integratedLufs
        let match = ReferenceLevelMatch.compute(
            mixIntegratedLufs: mixLufs,
            refIntegratedLufs: refLufs,
            refTruePeakDbtp: analysis.truePeakDbtp,
            trimDb: slot.trimDb)
        // Cache before toggle so the engine schedules against THIS slot.
        engine.referenceChanged(slot)
        try engine.setReferenceMonitor(on: true, matchGainDb: match.matchGainDb)
        referenceMonitor = ReferenceMonitorSnapshot(
            slotID: slot.id, mixIntegratedLufs: mixLufs,
            referenceIntegratedLufs: refLufs,
            referenceTruePeakDbtp: analysis.truePeakDbtp, match: match)
        return ReferenceMonitorResult(
            monitoring: true,
            matchGainDb: match.matchGainDb,
            matchBasis: match.matchBasis,
            mixIntegratedLufs: mixLufs,
            referenceIntegratedLufs: refLufs,
            ceilingLimited: match.ceilingLimited)
    }

    /// Sets the timeline↔file offset (file time = timeline seconds +
    /// offsetSeconds, design D6) as one coalesced journaled edit. While
    /// monitoring during playback the engine re-anchors the reference
    /// player LOCALLY off the `referenceChanged` push (the metronome
    /// enable-mid-play mechanism) — the transport is never touched.
    @discardableResult
    public func setReferenceOffset(seconds: Double) throws -> ReferenceSlot {
        guard var slot = reference else { throw ProjectError.referenceNotSet }
        slot.offsetSeconds = seconds
        performEdit("Set Reference Offset", key: "reference.offset") {
            reference = slot
        }
        engine?.referenceChanged(slot)
        return slot
    }

    /// Sets the user trim (clamped ±24 dB) as one coalesced journaled edit.
    /// While monitoring, the law recomputes against the SNAPSHOTTED
    /// toggle-ON basis (never the evolving live reading — design §5.6) and
    /// ONLY the gain re-applies: one node-volume write, never a re-anchor.
    /// Returns the slot echo plus the re-applied `matchGainDb` when
    /// monitoring (nil otherwise).
    @discardableResult
    public func setReferenceTrim(db: Double) throws
        -> (slot: ReferenceSlot, matchGainDb: Double?) {
        guard var slot = reference else { throw ProjectError.referenceNotSet }
        slot.trimDb = db.clamped(to: ReferenceSlot.trimRangeDb)
        performEdit("Set Reference Trim", key: "reference.trim") {
            reference = slot
        }
        engine?.referenceChanged(slot)
        var appliedMatchGainDb: Double?
        if var monitor = referenceMonitor, monitor.slotID == slot.id {
            let match = ReferenceLevelMatch.compute(
                mixIntegratedLufs: monitor.mixIntegratedLufs,
                refIntegratedLufs: monitor.referenceIntegratedLufs,
                refTruePeakDbtp: monitor.referenceTruePeakDbtp,
                trimDb: slot.trimDb)
            monitor.match = match
            referenceMonitor = monitor
            engine?.referenceMatchGainChanged(matchGainDb: match.matchGainDb)
            appliedMatchGainDb = match.matchGainDb
        }
        return (slot, appliedMatchGainDb)
    }

    /// Assembles the mix-vs-reference comparison (design §6): live loudness
    /// (integrated/TP/LRA) + master analyzer (bands/width/correlation) on
    /// the mix side, the stored whole-file analysis on the reference side,
    /// delta = reference − mix per field — each omitted when either side
    /// lacks evidence (honest nils). Refusals verbatim: no slot →
    /// `referenceNotSet`; no analysis → `referenceNotAnalyzed`; headless /
    /// no live meter → `engineUnavailable` (floors would fake deltas — a
    /// live meter is never faked, the m22-c law).
    public func referenceCompare() throws -> ReferenceCompareResult {
        guard let slot = reference else { throw ProjectError.referenceNotSet }
        guard let analysis = slot.analysis else { throw ProjectError.referenceNotAnalyzed }
        let live = try liveLoudness(reset: false)
        return ReferenceCompareResult.assemble(
            live: live, master: masterAnalysis(), analysis: analysis)
    }

    /// Ends an active audition (mix un-gates, reference player stops) and
    /// clears the transient snapshot. Idempotent; never throws (the OFF
    /// path of an engine that turned the monitor ON cannot refuse).
    func stopReferenceMonitorIfNeeded() {
        guard referenceMonitor != nil else { return }
        try? engine?.setReferenceMonitor(on: false, matchGainDb: 0)
        referenceMonitor = nil
    }

    /// Restore-funnel consistency (undo/redo/project-boundary): keeps the
    /// transient monitor honest after `reference` was swapped under it —
    /// slot removed/replaced or no longer computable → monitor OFF; same
    /// slot with a different trim → recompute against the snapshotted basis
    /// and re-apply just the gain (offset moves ride the caller's
    /// `referenceChanged` push).
    func syncReferenceMonitorAfterSlotChange() {
        guard var monitor = referenceMonitor else { return }
        guard let slot = reference, slot.id == monitor.slotID,
              let refLufs = slot.analysis?.integratedLufs else {
            stopReferenceMonitorIfNeeded()
            return
        }
        // The analysis itself may have been swapped (undo of analyze):
        // refresh the snapshot's reference inputs alongside the trim.
        monitor.referenceIntegratedLufs = refLufs
        monitor.referenceTruePeakDbtp = slot.analysis?.truePeakDbtp
        let match = ReferenceLevelMatch.compute(
            mixIntegratedLufs: monitor.mixIntegratedLufs,
            refIntegratedLufs: refLufs,
            refTruePeakDbtp: monitor.referenceTruePeakDbtp,
            trimDb: slot.trimDb)
        if match != monitor.match {
            monitor.match = match
            engine?.referenceMatchGainChanged(matchGainDb: match.matchGainDb)
        }
        referenceMonitor = monitor
    }

    /// Copies `source` into `directory` preserving the basename, `-2`/`-3`
    /// suffixing on collision (the `ProjectBundle.uniqueName` machinery —
    /// an existing file is NEVER overwritten: two imports of same-named but
    /// different files must not alias). nonisolated: runs inside the
    /// detached import task.
    nonisolated static func copyReferenceSource(
        _ source: URL, into directory: URL
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var taken = Set<String>()
        if let existing = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in existing { taken.insert(file.lastPathComponent) }
        }
        let name = ProjectBundle.uniqueName(for: source.lastPathComponent, taken: taken)
        let destination = directory.appendingPathComponent(name)
        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            throw ProjectError.importFailed(
                "could not copy \(source.path) into \(directory.path): "
                + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
        return destination
    }
}
