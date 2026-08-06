import Foundation

/// The ONE home for "what did a `debug.markerRename` request ask for, and is it
/// answerable?" (m23-ba-1) — the decision half of the arrange marker-lane
/// rename staging seam.
///
/// ═══ WHY THIS EXISTS ═══
///
/// Until m23-ba-1 the seam had exactly one mode: set (or nil) the staged marker
/// id. `{clear:true}` nils it, which unmounts the flag's `TextField` outright.
///
/// ⭐ MEASURED LIVE ON STAGING 2026-08-05, and this is the fact the whole item
/// turns on: **that teardown DISCARDS the typed draft.** It does not commit and
/// it does not cancel — neither `onCommitRename` nor `onCancelRename` runs,
/// because the view carrying them is gone before SwiftUI would deliver the
/// focus-loss `.onChange`. The measurement used a draft the model could not
/// have produced (open the field on a marker named "Chorus", then rename the
/// marker to "Verse" OVER THE WIRE so the field's `@State` draft and the
/// model's name genuinely differ — `debug.keySpace` confirmed the live field
/// editor still read "Chorus" while `marker.list` read "Verse"), then cleared:
/// `marker.list` still read **"Verse"**. A commit would have written "Chorus".
///
/// ⚠️ THE OBVIOUS SECOND EXPERIMENT CANNOT DISCRIMINATE, and it is the one a
/// future cycle will reach for first: typing spaces into the field (the m17-d
/// shape) leaves the draft `"  "`, which `TrackRename.committedName` trims to
/// empty and drops — so the marker's name is unchanged whether the teardown
/// committed or discarded. Measured too, same run: name stayed "Bridge" either
/// way. Only a draft that WOULD survive the commit rule proves anything here.
///
/// ═══ THE THREE REAL RESOLUTION PATHS (and the fourth thing `clear` is) ═══
///
/// | User action        | Handler                          | Result            |
/// |--------------------|----------------------------------|-------------------|
/// | Return             | `.onSubmit` → `commit()`         | commits, trimmed  |
/// | Escape             | `.onKeyPress(.escape)`           | cancels, reverts  |
/// | Click away         | `.onChange(of: fieldFocused)`    | **COMMITS**       |
///
/// ⚠️ CLICKING AWAY COMMITS. m17-d's original code cleared focus with a staged
/// click and its comment called that "escape-equivalent" — which is wrong about
/// the app's real behaviour twice over: a staged click cannot resign a field
/// editor at all (m23-ba), and if it could, losing focus commits rather than
/// cancels. A seam standing in for "the user clicked off the field" must
/// therefore drive COMMIT.
///
/// `clear` is none of the three. It is a RESET — "make sure no rename field is
/// standing" — and it is kept, unchanged, because m17-d/m23-g1/m23-x/m23-aj use
/// it purely to resign the field editor and read nothing of the marker's name
/// afterwards. Its documentation now says what it measurably does.
///
/// ═══ WHY IN DAWAppKit ═══
///
/// `DAWApp` has no test target, so a refusal rule written there is invisible to
/// the Swift suite (the `DeleteMenuPolicy` / `ArrangeScrollQuery` /
/// `GenerationCardDebugKeys` standing remedy). Everything that DECIDES — which
/// mode was asked for, which requests are refused and with what sentence —
/// lives here and is unit-tested; `DAWApp` keeps only the mechanical half:
/// pulling values out of `JSONValue`, staging the action, and reading the
/// view's report back.
///
/// The COMMIT RULE itself is deliberately NOT here: it already lives in
/// `TrackRename.committedName(draft:current:)` and the marker flag already
/// calls it. A second copy would be a second opinion.
public enum MarkerRenameStaging {

    // MARK: - What a request resolves to

    /// The four things `debug.markerRename` can be asked to do.
    public enum Action: Equatable, Sendable {
        /// Open the inline rename field. `markerID` nil = "the first marker"
        /// (the seam's long-standing convenience for `debug.markerRename {}`).
        case open(markerID: String?)
        /// Tear the field down WITHOUT running either resolution handler. The
        /// typed draft is DISCARDED — see the type's doc comment for the
        /// measurement. A focus-clearer, not a stand-in for a user gesture.
        case clear
        /// Drive the flag's own `commit()` — i.e. `onCommitRename(draft)` with
        /// the field's LIVE draft, through `TrackRename.committedName`. That
        /// body is what Return AND click-away both reach.
        ///
        /// ⚠️ IT RUNS THE BODY, NOT THE TRIGGER. The staged mode calls
        /// `commit()` directly; it never drives the `fieldFocused` transition,
        /// so focus-loss DETECTION is not exercised. A fine limitation — the
        /// same kind `debug.arrangePointer` carries by never producing an
        /// `NSEvent` — but this whole item exists because a seam was mistaken
        /// for a gesture, so the distinction is written down rather than left
        /// to be re-derived.
        case commit
        /// Drive `onCancelRename(draft)` — the Escape path. Reverts.
        case cancel

        /// Stable wire spelling for the echo, so a gate can assert which mode
        /// the seam actually resolved rather than which one it meant to send.
        public var wireName: String {
            switch self {
            case .open: return "open"
            case .clear: return "clear"
            case .commit: return "commit"
            case .cancel: return "cancel"
            }
        }

        /// True for the two modes that RESOLVE a standing rename through a real
        /// handler (as opposed to opening or tearing one down).
        public var resolvesRename: Bool {
            switch self {
            case .commit, .cancel: return true
            case .open, .clear: return false
            }
        }
    }

    /// A refusal, carrying the sentence the seam answers with verbatim.
    public struct Refusal: Error, Equatable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    // MARK: - The request

    /// Every key `debug.markerRename` recognizes. Spelled once so the validator
    /// and the teaching message can never disagree about what is valid.
    public static let allowedKeys: Set<String> = ["markerId", "clear", "commit", "cancel"]

    /// One `debug.markerRename` call, reduced to plain Swift.
    ///
    /// ⚠️ `malformedKeys` is not decoration and it is not the same thing as an
    /// unknown key. m23-ah's whole arc was `debug.*` verbs answering a
    /// MISSPELLED request with a success-shaped response; `{clear: "true"}` is
    /// the same defect wearing a correct key name — a `boolValue` read returns
    /// nil, the old seam read that as "not requested", and the caller got a
    /// cheerful `renamingMarkerId` for a clear that never happened. The caller
    /// fills this with every recognized key whose VALUE had the wrong JSON
    /// type, and every one of them is refused by name.
    ///
    /// `fieldOpenMarkerID` is the marker whose field the VIEW is actually
    /// rendering, reported UP by the view — never the seam's own staged input
    /// (the `arrangeHScrollReported` honesty rule). It matters because
    /// `commit`/`cancel` are meaningless with no field standing, and a seam
    /// that answered `ok` for them would be manufacturing exactly the false
    /// confidence this item was filed about.
    public struct Request: Equatable, Sendable {
        /// Every key the caller sent, verbatim (including unknown ones).
        public var keys: Set<String>
        /// `markerId` when present AND a string; nil when absent or malformed.
        public var markerID: String?
        /// `clear`/`commit`/`cancel` when present AND a bool.
        public var clear: Bool?
        public var commit: Bool?
        public var cancel: Bool?
        /// Recognized keys whose value had the wrong JSON type.
        public var malformedKeys: Set<String>
        /// Whether `markerID` names a marker that exists — nil when no
        /// `markerId` was given. A lookup result, not a decision.
        public var markerIDIsKnown: Bool?
        /// How many markers the project has (the `{}` "first marker" path needs
        /// at least one, and answering `renamingMarkerId: null` for a request
        /// that opened nothing is the m23-ah success-shaped-failure class).
        public var markerCount: Int
        /// The marker whose rename field the VIEW reports it is rendering.
        public var fieldOpenMarkerID: String?

        public init(
            keys: Set<String> = [],
            markerID: String? = nil,
            clear: Bool? = nil,
            commit: Bool? = nil,
            cancel: Bool? = nil,
            malformedKeys: Set<String> = [],
            markerIDIsKnown: Bool? = nil,
            markerCount: Int = 0,
            fieldOpenMarkerID: String? = nil
        ) {
            self.keys = keys
            self.markerID = markerID
            self.clear = clear
            self.commit = commit
            self.cancel = cancel
            self.malformedKeys = malformedKeys
            self.markerIDIsKnown = markerIDIsKnown
            self.markerCount = markerCount
            self.fieldOpenMarkerID = fieldOpenMarkerID
        }
    }

    // MARK: - Resolution

    /// The mode this request asks for, or a `Refusal` naming what is wrong.
    ///
    /// ⚠️ EVERY REFUSAL IS DECIDED BEFORE THE CALLER MUTATES ANYTHING. That
    /// ordering is the m23-ah-6 lesson paid for in full: ah-6's own hardening
    /// fix created a half-applied path (`{clear:true, seed:<bad>}` emptied the
    /// card and THEN threw) that did not exist before it. This function is
    /// total and side-effect-free precisely so the caller can run it first and
    /// stage second — `throws` before any assignment, always.
    ///
    /// Order of refusals is deliberate: shape first (unknown / malformed keys),
    /// then intent (conflicting modes), then feasibility (nothing to open, no
    /// field to resolve). A caller who typo'd a key learns that before being
    /// told their marker doesn't exist.
    public static func resolve(_ request: Request) throws -> Action {
        // ── 1. Shape: keys we do not recognize at all. ──────────────────────
        let unknown = request.keys.subtracting(allowedKeys).sorted()
        if !unknown.isEmpty {
            let named = unknown.map { "'\($0)'" }.joined(separator: ", ")
            let valid = allowedKeys.sorted().map { "'\($0)'" }.joined(separator: ", ")
            throw Refusal(
                "debug.markerRename: unknown parameter\(unknown.count > 1 ? "s" : "") \(named) — valid keys are \(valid)")
        }

        // ── 2. Shape: recognized keys carrying the wrong JSON type. ─────────
        let malformed = request.malformedKeys.sorted()
        if !malformed.isEmpty {
            let named = malformed.map { key -> String in
                key == "markerId" ? "'markerId' must be a marker-id string"
                                  : "'\(key)' must be true or false"
            }.joined(separator: "; ")
            throw Refusal("debug.markerRename: \(named)")
        }

        // ── 3. Intent: at most one mode. ───────────────────────────────────
        var requested: [String] = []
        if request.clear == true { requested.append("clear") }
        if request.commit == true { requested.append("commit") }
        if request.cancel == true { requested.append("cancel") }
        if requested.count > 1 {
            let named = requested.map { "'\($0)'" }.joined(separator: " and ")
            throw Refusal(
                "debug.markerRename: \(named) name different outcomes — pass exactly one " +
                "('commit' = Return / click away, 'cancel' = Escape, 'clear' = tear the field down and DISCARD the draft)")
        }
        if let mode = requested.first, request.markerID != nil {
            throw Refusal(
                "debug.markerRename: 'markerId' OPENS a rename field and '\(mode)' resolves one — " +
                "pass them in separate calls")
        }

        // ── 4. Feasibility of the two resolution modes. ────────────────────
        if let mode = requested.first, mode != "clear", request.fieldOpenMarkerID == nil {
            throw Refusal(
                "debug.markerRename: '\(mode)' needs a rename field to be open — " +
                "call debug.markerRename {markerId} first (the view reports no marker being renamed)")
        }
        if request.commit == true { return .commit }
        if request.cancel == true { return .cancel }
        // `clear` is a RESET, deliberately idempotent: it is legal with nothing
        // open, because "make sure no field is standing" is a coherent ask and
        // four gates already use it that way.
        if request.clear == true { return .clear }

        // ── 5. Feasibility of the open path. ───────────────────────────────
        if let id = request.markerID {
            guard request.markerIDIsKnown == true else {
                throw Refusal("debug.markerRename: no marker with id \(id) — list them with marker.list")
            }
            return .open(markerID: id)
        }
        guard request.markerCount > 0 else {
            throw Refusal(
                "debug.markerRename: the project has no markers to rename — add one with marker.add first")
        }
        return .open(markerID: nil)
    }
}
