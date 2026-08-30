import Foundation

/// m24-n — the two things a user can ASK about the voices a project carries,
/// and the one thing they can DO with them.
///
/// Everything here is DERIVED from the live model plus the filesystem at the
/// moment it is called. There is deliberately no embedded-voice manifest in
/// `project.json`: a record of what the `voices/` folder contains is a record
/// that can disagree with the folder, and "the record says X, the source says
/// Y, and nothing compares them" is this tree's characteristic defect. The
/// directory IS the record.
@MainActor
extension ProjectStore {

    // MARK: - What is this project carrying, and why

    /// Every voice this project names, what it costs, and where it can be found
    /// (m24-n).
    ///
    /// Answers the support question a silent 240 MB would otherwise become. For
    /// each distinct voice named by some track's `voiceProvenance`, plus every
    /// voice still sitting in the bundle that no track names any more:
    ///  - is a copy EMBEDDED in the saved bundle, and how many bytes is it,
    ///  - is a usable copy INSTALLED on this machine (i.e. could a conversion
    ///    with it run right now),
    ///  - and one plain sentence saying what that combination means.
    ///
    /// ⚠️ **Nothing here is a failure.** A voice named by provenance that
    /// exists nowhere is a normal state: the converted audio still plays,
    /// because the track holds ordinary audio clips. Only RE-conversion is
    /// unavailable, and the note says exactly that.
    ///
    /// Cheap: one `fileExists` per whitelisted file per voice. No audio is
    /// opened and no model is loaded.
    public func embeddedVoicesReport() -> EmbeddedVoicesReport {
        let fm = FileManager.default
        let bundleURL = projectPath.map { URL(fileURLWithPath: $0).standardizedFileURL }

        // Distinct voices in session order; the FIRST provenance wins the
        // display name (deterministic, and it is the topmost track the user
        // sees).
        var order: [String] = []
        var names: [String: String] = [:]
        var users: [String: [String]] = [:]
        for track in tracks {
            guard let provenance = track.voiceProvenance else { continue }
            if users[provenance.voiceId] == nil {
                order.append(provenance.voiceId)
                names[provenance.voiceId] = provenance.voiceName
                users[provenance.voiceId] = []
            }
            users[provenance.voiceId]?.append(track.name)
        }

        // Voices the BUNDLE carries. A save never deletes media (the
        // undo-resurrection rule in `ProjectBundle.write`), and that rule holds
        // for voices, so deleting a converted track leaves its voice behind.
        var carried: [String] = []
        if let bundleURL {
            let voicesDir = bundleURL.appendingPathComponent(
                VoiceStore.bundleFolderName, isDirectory: true)
            let entries = (try? fm.contentsOfDirectory(
                at: voicesDir, includingPropertiesForKeys: nil)) ?? []
            carried = entries
                .map(\.lastPathComponent)
                .filter { !$0.hasPrefix(".") }
                .sorted()
        }
        let orphans = carried.filter { !order.contains($0) }

        var rows: [EmbeddedVoiceStatus] = []
        var total = 0
        for voiceId in order + orphans {
            let embeddedDir = bundleURL.flatMap {
                VoiceStore.embeddedDirectory(voiceId: voiceId, bundleURL: $0)
            }
            let embeddedFiles = embeddedDir.map {
                VoiceStore.embeddableFiles(in: $0, fileManager: fm)
            } ?? []
            let embeddedBytes = embeddedFiles.reduce(0) { $0 + $1.byteCount }
            let embedded = embeddedDir.map {
                VoiceStore.isUsableVoiceDirectory($0, fileManager: fm)
            } ?? false
            total += embeddedBytes

            let installed = VoiceStore.isUsableVoiceDirectory(
                voiceStoreDirectory.appendingPathComponent(voiceId, isDirectory: true),
                fileManager: fm)
            let isOrphan = users[voiceId] == nil
            rows.append(EmbeddedVoiceStatus(
                voiceId: voiceId,
                voiceName: names[voiceId] ?? voiceId,
                tracks: users[voiceId] ?? [],
                embeddedInProject: embedded,
                embeddedBytes: embeddedBytes,
                installedLocally: installed,
                note: Self.embeddedVoiceNote(
                    voiceId: voiceId, embedded: embedded, installed: installed,
                    isOrphan: isOrphan, isSaved: bundleURL != nil)))
        }
        return EmbeddedVoicesReport(
            projectPath: bundleURL?.path, voices: rows,
            embeddedBytes: total, orphanedVoiceIds: orphans)
    }

    /// The one plain sentence per voice. Written to be read by someone who has
    /// never heard of an `.npz` and is asking why their project is 240 MB.
    static func embeddedVoiceNote(
        voiceId: String, embedded: Bool, installed: Bool,
        isOrphan: Bool, isSaved: Bool
    ) -> String {
        if voiceId == VoiceStore.reservedVoiceId {
            return "the built-in pipeline smoke target — it ships with the app, so nothing "
                + "needs to be carried in the project"
        }
        if isOrphan {
            return "no track uses this voice any more — it stayed behind when the converted "
                + "track was removed, and it still takes up room; deleting the project's "
                + "voices/\(voiceId) folder is safe"
        }
        switch (embedded, installed) {
        case (true, true):
            return "carried inside this project AND installed on this machine — you can "
                + "re-convert here, and so can anyone you send the project to"
        case (true, false):
            return "carried inside this project but not installed on this machine — the "
                + "converted audio plays fine; install it (vc.installEmbeddedVoice) to "
                + "convert anything new with it"
        case (false, true):
            return isSaved
                ? "installed on this machine but not yet carried in this project — the next "
                    + "save embeds a copy so the project stays re-convertible elsewhere"
                : "installed on this machine; this project has never been saved, so the "
                    + "copy that makes it portable will be embedded at the first save"
        case (false, false):
            return "not on this machine and not carried in this project — the converted "
                + "audio still plays; only converting AGAIN with this voice is unavailable, "
                + "and it would need the voice installed first (vc.importVoiceModel)"
        }
    }

    // MARK: - Making an embedded voice usable

    /// Promotes this project's embedded copy of `voiceId` into this machine's
    /// voice store, where the RVC sidecar can find it (m24-n).
    ///
    /// ⭐ **This is what makes "re-convertible on another machine" true rather
    /// than decorative.** The sidecar scans exactly ONE directory — the store
    /// this method writes into (`RVC_VOICES_DIR`, set at every spawn) — so
    /// without this step the bytes a project carries are inert.
    ///
    /// ⚠️ **Deliberately NOT automatic on open.** Opening a project would
    /// otherwise write up to ~84 MB per voice into Application Support without
    /// being asked, and would silently shadow a voice of the same id the user
    /// already had. It is one explicit action, taken when the user wants to
    /// convert with the voice — which is the only moment it is needed.
    ///
    /// Writes the app's voice store; touches neither the project nor the undo
    /// journal, and never sets `isDirty` — installing a voice is not an edit.
    ///
    /// - Parameters:
    ///   - voiceId: the id as recorded in provenance / listed by
    ///     `embeddedVoicesReport()`.
    ///   - overwrite: replace a voice of the same id already in the store
    ///     (the `vc.importVoiceModel` `overwrite` precedent). Without it, an
    ///     existing voice is a REFUSAL, not a silent replacement.
    @discardableResult
    public func installEmbeddedVoice(
        voiceId: String, overwrite: Bool = false
    ) throws -> EmbeddedVoiceInstallResult {
        let fm = FileManager.default
        guard voiceId != VoiceStore.reservedVoiceId else {
            throw ProjectError.embeddedVoiceUnavailable(
                "'\(VoiceStore.reservedVoiceId)' is the built-in pipeline smoke target, not a "
                + "voice in the store — it ships with the app and is already usable; nothing "
                + "to install")
        }
        guard VoiceStore.isSafeVoiceId(voiceId) else {
            throw ProjectError.embeddedVoiceUnavailable(
                "'\(voiceId)' is not a usable voice id — ids are letters, digits, '-' and '_'. "
                + "List what this project carries with project.embeddedVoices")
        }
        guard let path = projectPath else {
            throw ProjectError.embeddedVoiceUnavailable(
                "this project has never been saved, so it carries no embedded voices yet — "
                + "save it first (voices are embedded on save)")
        }
        let bundleURL = URL(fileURLWithPath: path).standardizedFileURL
        guard let sourceDir = VoiceStore.embeddedDirectory(
            voiceId: voiceId, bundleURL: bundleURL),
            VoiceStore.isUsableVoiceDirectory(sourceDir, fileManager: fm) else {
            throw ProjectError.embeddedVoiceUnavailable(
                "this project carries no usable copy of voice '\(voiceId)' — "
                + "project.embeddedVoices lists what it does carry")
        }

        let destinationDir = voiceStoreDirectory
            .appendingPathComponent(voiceId, isDirectory: true)
        let replacing = VoiceStore.isUsableVoiceDirectory(destinationDir, fileManager: fm)
        if replacing && !overwrite {
            throw ProjectError.embeddedVoiceAlreadyInstalled(voiceId)
        }

        let files = VoiceStore.embeddableFiles(in: sourceDir, fileManager: fm)
        do {
            try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            for file in files {
                let destination = destinationDir.appendingPathComponent(file.name)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: file.url, to: destination)
            }
        } catch {
            throw ProjectError.embeddedVoiceUnavailable(
                "could not install voice '\(voiceId)' into the voice store: "
                + "\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }

        // The display name the project recorded beats the id, and beats
        // re-reading voice.json: provenance is what the user saw when they
        // converted.
        let recorded = tracks.compactMap(\.voiceProvenance)
            .first { $0.voiceId == voiceId }?.voiceName
        return EmbeddedVoiceInstallResult(
            voiceId: voiceId,
            voiceName: recorded ?? voiceId,
            directoryPath: destinationDir.path,
            files: files.map(\.name),
            byteCount: files.reduce(0) { $0 + $1.byteCount },
            replacedExisting: replacing)
    }
}
