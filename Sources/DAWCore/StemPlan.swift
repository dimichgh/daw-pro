import Foundation

/// Which master input a stem represents (M5 iv-c, spec §2): a direct-to-master
/// track's dry post-fader signal, or a bus (carrying everything routed into it
/// AND every send contribution, through the bus chain and fader).
public enum StemKind: String, Codable, Sendable { case track, bus }

/// One planned stem: a master input plus the sanitized, collision-free file
/// name it will be written under ("NN Name.wav", 1-based partition order).
public struct StemDescriptor: Identifiable, Sendable, Equatable {
    /// The master input's id — a direct track's or a bus track's UUID.
    public let id: UUID
    public let kind: StemKind
    /// Raw track name, unsanitized (display / wire identity).
    public let name: String
    /// "NN Name.wav" — sanitized, collision-suffixed (spec §2/§4).
    public let fileName: String

    public init(id: UUID, kind: StemKind, name: String, fileName: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.fileName = fileName
    }
}

/// One written stem file in a `StemExportResult` (spec §4.2). Codable = the
/// `render.stems` wire shape (iv-d) — wire-never-drifts. Stems are NEVER
/// normalized (spec §4.1): `measurement` is the honest report of exactly what
/// hit disk, including > 0 dBFS true peaks (Float32 end-to-end, the ii-e
/// no-baked-headroom stance).
public struct StemFile: Codable, Sendable, Equatable {
    public var trackId: UUID
    public var name: String
    public var kind: StemKind
    public var path: String
    public var measurement: LoudnessMeasurement

    public init(trackId: UUID, name: String, kind: StemKind, path: String,
                measurement: LoudnessMeasurement) {
        self.trackId = trackId
        self.name = name
        self.kind = kind
        self.path = path
        self.measurement = measurement
    }
}

/// The optional `includeMixdown` reference file ("00 Mixdown.wav") — the
/// null-check anchor: Σ stems ≡ this file, ≤ 1e-4 residual peak (spec §1).
public struct MixdownFile: Codable, Sendable, Equatable {
    public var path: String
    public var measurement: LoudnessMeasurement

    public init(path: String, measurement: LoudnessMeasurement) {
        self.path = path
        self.measurement = measurement
    }
}

/// Result of `ProjectStore.renderStems` (spec §4.2). Every file shares one
/// duration/rate/channel shape — summation requires it, so the window is
/// computed once per call.
public struct StemExportResult: Codable, Sendable, Equatable {
    public var directory: String
    public var sampleRate: Double
    public var durationSeconds: Double
    public var channels: Int
    public var stems: [StemFile]
    public var mixdown: MixdownFile?

    public init(directory: String, sampleRate: Double, durationSeconds: Double,
                channels: Int, stems: [StemFile], mixdown: MixdownFile? = nil) {
        self.directory = directory
        self.sampleRate = sampleRate
        self.durationSeconds = durationSeconds
        self.channels = channels
        self.stems = stems
        self.mixdown = mixdown
    }
}

/// The stem plan (M5 iv-c, spec §2) — a PURE track-list transform, zero engine
/// knowledge, headless-testable.
///
/// Stems are the MASTER-INPUT PARTITION: one per signal the main mixer sums —
/// (a) every audio/instrument track routed direct to master
/// (`outputBusID == nil`) and (b) every bus track. A track's send contribution
/// lives in the DESTINATION bus's stem (the only partition where nonlinear bus
/// FX stay correct); the source track's stem is its dry post-fader signal.
/// Tracks routed INTO a bus have no stem of their own.
///
/// The normative invariant this plan exists to uphold:
/// Σ stems ≡ the mixdown, null residual peak ≤ 1e-4 — which additionally
/// requires every pass to run under the FULL-SESSION PDC plan
/// (`ProjectStore.renderStems` forces it; a subset auto-plan combs).
public enum StemPlan {

    /// The master-input partition in track-list order. `ids == nil` → all
    /// master inputs. Throws `ProjectError.trackNotFound` for an unknown id,
    /// or `.stemNotMasterInput` for a bus-routed source track id (its signal
    /// is part of the destination bus's stem — the message says so verbatim).
    public static func descriptors(tracks: [Track],
                                   including ids: [UUID]?) throws -> [StemDescriptor] {
        // Validate the request BEFORE filtering, so a bus-routed id rejects
        // readably instead of silently vanishing from the export.
        if let ids {
            for id in ids {
                guard let track = tracks.first(where: { $0.id == id }) else {
                    throw ProjectError.trackNotFound(id)
                }
                if track.kind != .bus, let busID = track.outputBusID {
                    let busName = tracks.first(where: { $0.id == busID })?.name
                        ?? busID.uuidString
                    throw ProjectError.stemNotMasterInput(
                        "'\(track.name)' is routed to bus '\(busName)' — its signal is part of that bus's stem"
                    )
                }
            }
        }
        let requested = ids.map(Set.init)
        let selected = tracks.filter { track in
            let isMasterInput = track.kind == .bus || track.outputBusID == nil
            guard isMasterInput else { return false }
            return requested?.contains(track.id) ?? true
        }
        var taken = Set<String>()
        return selected.enumerated().map { index, track in
            let kind: StemKind = track.kind == .bus ? .bus : .track
            return StemDescriptor(
                id: track.id, kind: kind, name: track.name,
                fileName: fileName(index: index + 1, name: track.name,
                                   kind: kind, taken: &taken)
            )
        }
    }

    /// The solo transform: the subset track list whose master input is EXACTLY
    /// this stem's signal, given the full session track list.
    ///
    /// - `.track` stem T → `[T with sends = []]`. Removing sends cannot change
    ///   the direct signal — sends are post-fader FAN-OUT; the direct path is
    ///   untouched.
    /// - `.bus` stem B → every contributing source track (routed into B, or
    ///   with any send targeting B) with its sends filtered to ONLY those
    ///   targeting B and its direct out rewritten to a fresh SILENT DUMMY BUS
    ///   unless it already is B; plus bus track B unchanged; plus the dummy
    ///   (kind .bus, volume 0, no effects) exactly when some direct out was
    ///   rerouted. The dummy exists because a source track's direct out must
    ///   keep running (post-fader sends tap the strip output) yet must not
    ///   reach master — and the graph's missing-bus fallback IS master, so
    ///   "point at a missing bus" would leak the dry signal into the stem.
    ///
    /// Automation, clip gain/fades, stretch, comp members all ride along —
    /// tracks pass whole.
    public static func passTracks(for stem: StemDescriptor,
                                  session: [Track]) -> [Track] {
        switch stem.kind {
        case .track:
            guard var track = session.first(where: { $0.id == stem.id }) else {
                return []
            }
            track.sends = []
            return [track]

        case .bus:
            let dummy = Track(name: "Stem Dummy", kind: .bus, volume: 0)
            var needsDummy = false
            var pass: [Track] = []
            for track in session {
                if track.id == stem.id {
                    pass.append(track)  // The bus itself, untouched.
                    continue
                }
                guard track.kind != .bus else { continue }  // Foreign buses out.
                let routesIn = track.outputBusID == stem.id
                let sendsIn = track.sends.contains { $0.destinationBusID == stem.id }
                guard routesIn || sendsIn else { continue }
                var contributor = track
                contributor.sends = track.sends.filter { $0.destinationBusID == stem.id }
                if contributor.outputBusID != stem.id {
                    contributor.outputBusID = dummy.id
                    needsDummy = true
                }
                pass.append(contributor)
            }
            if needsDummy { pass.append(dummy) }
            return pass
        }
    }

    /// "NN Name.wav" builder (spec §2): strip control characters and
    /// `/\:?%*|"<>`, trim whitespace/dots off the ends, empty → "Track"/"Bus";
    /// 2-digit 1-based index prefix in partition order; duplicate names get
    /// " 2", " 3"… suffixes (the media-copy collision precedent), compared
    /// case-insensitively because the default APFS volume is.
    static func fileName(index: Int, name: String, kind: StemKind,
                         taken: inout Set<String>) -> String {
        let illegal = Set("/\\:?%*|\"<>")
        var sanitized = String(name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !illegal.contains(Character($0))
        })
        let trimSet = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "."))
        sanitized = sanitized.trimmingCharacters(in: trimSet)
        if sanitized.isEmpty {
            sanitized = kind == .bus ? "Bus" : "Track"
        }
        var candidate = sanitized
        var suffix = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(sanitized) \(suffix)"
            suffix += 1
        }
        taken.insert(candidate.lowercased())
        return String(format: "%02d %@.wav", index, candidate)
    }
}
