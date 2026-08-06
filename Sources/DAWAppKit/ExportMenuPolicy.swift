import Foundation

/// The ONE home for the question "is File ▸ Export Audio… live, and what does it
/// say?" (m23-dd).
///
/// WHY THIS EXISTS. A user reported that export was not in the File menu, and
/// they were right: `grep -rn 'exportSong()' Sources/` found exactly two call
/// sites — the transport bar's EXPORT chip (`TransportBar.swift`) and the
/// onboarding tour's `export` step (`ContentView.swift`). Neither is a menu, and
/// `FileCommands` owned New / Open / Import Audio / Import MIDI / **Export
/// MIDI** / Save / Save As with the audio export simply missing. So the only
/// discoverable route to bouncing a song was one 26-point chip in a transport
/// bar THE SAME USER separately reported as overcrowded (m23-db) — which makes
/// this item relief rather than tidiness. This type is the decision half of the
/// menu route; `FileCommands` keeps only the mount.
///
/// ⚠️⚠️ THIS ITEM SHIPS WITHOUT A KEYBOARD SHORTCUT, ON PURPOSE. Nobody should
/// "finish the job" by adding `.keyboardShortcut("e", …)` — two reasons, and the
/// second is the one that outlives this cycle:
///
///   • IT COULD NOT BE VERIFIED. m23-g1 established that an UNBUNDLED staging
///     binary does not route real key events, so a key equivalent is invisible
///     to every gate this project can run; proving it would take
///     `dist/DAWPro.app` and the user's own hands, and the item could then not
///     be closed on machine evidence.
///   • THERE IS AN OPEN, UNDIAGNOSED KEY-ROUTING DEFECT. m23-cf is still open on
///     a DELETE key that does not reach its handlers. Adding a second key path
///     into the app before the first one is understood makes both harder to
///     diagnose, and would put this feature's fate inside that investigation.
///
/// ⭐ THE DISTINCTION THAT MAKES THIS SHIPPABLE ANYWAY, inherited verbatim from
/// `DeleteMenuPolicy`: THE HAZARD BELONGS TO THE SHORTCUT, NOT TO THE ITEM. A
/// menu item with no key equivalent is fully testable (the policy here) and
/// fully useful (a click). The shortcut is a separate decision for later.
///
/// WHY IN DAWAppKit. `DAWApp` is an executable target with NO test target, so a
/// menu policy written there is unverifiable by the Swift suite — the standing
/// remedy in this tree (`DeleteMenuPolicy`, `ArrangeScrollQuery`,
/// `GenerationCardDebugKeys`, `ArrangeTrackSelection`). Everything that DECIDES
/// lives here; `DAWApp` keeps only composition — reading live state and mounting
/// the `Button`.
public enum ExportMenuPolicy {

    /// What File ▸ Export Audio… says, in BOTH states.
    ///
    /// ⚠️ NOT "Export…", AND THAT IS A COLLISION FIX rather than a style
    /// preference. The File menu already carries "Export MIDI…" (m23-k4b), so a
    /// bare "Export…" sitting beside it asks the user to guess which of the two
    /// is the audio one. Naming the medium in BOTH items is what makes the pair
    /// legible, and it mirrors the imports directly above them ("Import Audio…"
    /// / "Import MIDI…") — the menu reads as a 2×2, not as four unrelated verbs.
    ///
    /// THE ELLIPSIS IS LOAD-BEARING and is the CHARACTER `…`, not three periods:
    /// macOS uses it to promise that the item opens something to confirm rather
    /// than acting immediately, which is exactly true here (the item opens the
    /// Export dialog; the save panel comes later, from the dialog's own button).
    ///
    /// ONE TITLE FOR BOTH STATES, unlike `DeleteMenuPolicy.inertTitle`. That
    /// policy needs a separate inert title because its live titles name a BLAST
    /// RADIUS ("Delete 3 Clips") which a greyed item must not claim. This item
    /// names no quantity and destroys nothing, so there is nothing for a
    /// disabled title to over-promise.
    public static let title = "Export Audio…"

    // MARK: - File ▸ Export Audio…

    /// Resolves the File-menu audio-export item: what it says, and whether it is
    /// live.
    ///
    /// ═══ THE ENABLED RULE ═══
    ///
    /// Disabled when the project has NO TRACKS, because there is then nothing
    /// that could render. Chosen as the guard precisely because it is the half
    /// that is decidable HERE and always correct: clips live on tracks, so zero
    /// tracks means zero clips for ANY render range, at any tempo, with any
    /// selection. The greyed item still teaches — the operation exists, and it
    /// wants some music first.
    ///
    /// ⚠️ "NO CLIPS" IS DELIBERATELY NOT A TERM, and the omission is reasoned.
    /// A project WITH tracks but no audible content also renders nothing, and
    /// `renderBounce` refuses it verbatim ("nothing to render — no clips found
    /// in the render range", `MediaImporting.swift`). Two reasons to leave that
    /// case live rather than grey it:
    ///
    ///   • THIS POLICY CANNOT SEE THE RENDER RANGE. A bounce takes `fromBeat`
    ///     and `durationSeconds`, so "are there clips in range" is a different,
    ///     narrower question than "are there clips" — a greyed item derived from
    ///     the wrong one would refuse exports that would have worked.
    ///   • A SENTENCE BEATS A GREYED ITEM. The store's refusal names the reason
    ///     and the range; a disabled menu item can only say nothing at all. The
    ///     empty-project case is greyed only because there is no plausible
    ///     reading of it in which the export succeeds.
    ///
    /// ⚠️ NEITHER `isExporting` NOR `showExportSheet` IS A TERM, and this is the
    /// ONE-HOME rule showing up as an omission. The transport EXPORT chip is
    /// unconditional and calls `AppModel.exportSong()`; this item calls the SAME
    /// function. Guards that exist on only one of the two routes are how the
    /// routes start meaning different things — and re-opening is already
    /// `openExportSheet`'s own documented behaviour (it refreshes the track
    /// snapshot and drops the previous run's result), with a
    /// `guard !isExporting` inside `ExportDialogModel` covering the double-run.
    ///
    /// THE ASYMMETRY THIS DOES LEAVE, stated rather than hidden: with zero
    /// tracks the menu item is greyed while the transport chip still opens the
    /// dialog (which then reads "no tracks reach the main mix yet"). That is a
    /// difference of AFFORDANCE, not of ACTION — both routes run the identical
    /// function whenever both are live, which is the property the one-home rule
    /// actually protects. Dimming a chip in the glass cockpit is a separate
    /// design question (it is also the onboarding tour's target), so it is left
    /// to whoever takes m23-db rather than smuggled in here.
    ///
    /// - Parameter trackCount: `ProjectStore.tracks.count`. A PLAIN VALUE on
    ///   purpose — a policy that took the store could not be tested headless,
    ///   which is the whole reason this type is in `DAWAppKit`.
    public static func fileMenuItem(trackCount: Int) -> ExportMenuItem {
        // `> 0`, not `!= 0`: a negative count is unrepresentable from
        // `[Track].count`, and resolving it to "disabled" rather than trusting
        // it means a future caller bug degrades to a greyed item instead of
        // opening an export dialog over a session it cannot describe.
        guard trackCount > 0 else { return ExportMenuItem(refusedBy: .emptyProject) }
        return ExportMenuItem()
    }
}

/// WHY File ▸ Export Audio… is inert, named for the guard that refused.
///
/// Carried on the item rather than discarded for the reason
/// `DeleteMenuRefusal` exists: a bare `isEnabled == false` cannot tell a test
/// which guard fired, which is how a dead policy passes a refusal-only suite.
/// One case today; the enum is what keeps a second guard ADDITIVE — and any
/// second guard has to answer the "not a term" arguments on `fileMenuItem`
/// before it earns a case here.
public enum ExportMenuRefusal: String, Sendable, Equatable, CaseIterable {
    /// The project has no tracks, so no render could produce anything.
    case emptyProject = "empty-project"
}

/// The resolved File ▸ Export Audio… item.
public struct ExportMenuItem: Equatable, Sendable {
    /// What the menu says — `ExportMenuPolicy.title` in both states.
    public var title: String
    /// Which guard refused; nil when the item is live.
    public var refusedBy: ExportMenuRefusal?

    /// DERIVED, never stored: "no guard refused" and "the item is clickable" are
    /// the same fact, and a stored twin could drift from it.
    public var isEnabled: Bool { refusedBy == nil }

    public init(title: String = ExportMenuPolicy.title,
                refusedBy: ExportMenuRefusal? = nil) {
        self.title = title
        self.refusedBy = refusedBy
    }
}
