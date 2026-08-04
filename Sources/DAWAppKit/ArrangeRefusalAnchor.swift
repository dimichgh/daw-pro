import Foundation
import DAWCore

// m23-am — the ONE home for "WHICH CLIP does a refused group delete hang its
// amber bubble on". Headless (no SwiftUI, no AppKit) in the `ArrangeSelection` /
// `EditorSurfaceRouter` / `ArrangeDropSnap` tradition, and headless HERE for a
// specific reason: the decision it replaces lived inline in `AppModel.delete-
// ArrangeSelection`, and `DAWApp` has no test target at all — so as written that
// precedence was unprovable by anything except a live gate.
//
// THE DEFECT THIS EXISTS TO MAKE UNREPRESENTABLE, measured on a live staging
// binary before it was fixed: the anchor was `focusID ?? targets.first`, and
// `targets` is a `Set<UUID>`. A track-header click adopts NO focus (m23-y), so a
// header-union delete refused by one take-comp member fell straight through to
// `Set.first` — an ARBITRARY element, unrelated to what refused and not even
// stable between launches (Swift seeds hashing per process). With 8 clips on one
// track and the comp member at creation index 4, the bubble landed on creation
// index 3 and told the user that INNOCENT clip belonged to take group
// 'PROBE TAKES'. Not silence, as the item was filed — a confident lie, which is
// worse: silence at least does not send the user to edit the wrong clip.
//
// NOTE WHAT THIS TYPE DOES NOT DO. It never asks "is this clip a comp member?".
// That question has exactly one home, `ProjectStore.requireNotCompMember`, and
// the answer arrives here inside the error the store already threw. A second
// predicate in the app would be a copy that could drift the moment take-group
// membership gained one more rule.
public enum ArrangeRefusalAnchor {
    /// The clip the refusal should be shown on, in strict preference order.
    ///
    /// 1. **The clip that actually refused**, when the error names one
    ///    (`ProjectError.refusalAnchorClipID`). Highest priority ON PURPOSE, and
    ///    this is the whole fix: the store knows which clip failed, so nothing
    ///    downstream should be guessing.
    /// 2. **The selection's focus.** Only whatever the user last clicked — right
    ///    for a single-clip refusal (where it IS the offender, so 1 and 2 agree
    ///    and the behaviour is unchanged), wrong for a multi-clip one, and absent
    ///    entirely after a track-header click.
    /// 3. **The first target in track-then-clip order.** Reached only by an error
    ///    that names no clip at all with no focus standing; kept so a refusal can
    ///    never be silent, which is the whole point of the m17-c/m23-e amber
    ///    bubble convention. `orderedTargets` is ordered rather than a set so
    ///    even this last resort is reproducible.
    ///
    /// Returns nil only when there is nothing at all to point at (no named clip,
    /// no focus, no targets) — the caller guards a non-empty selection before it
    /// ever reaches the store, so in the delete path that is unreachable.
    ///
    /// - Parameters:
    ///   - error: whatever the store threw. Non-`ProjectError` errors simply fall
    ///     through to the focus, which is the honest answer for an error that
    ///     cannot name a clip.
    ///   - focusID: `ArrangeSelection.focusID` at the moment of the refusal.
    ///   - orderedTargets: the refused ids in the STORE's own iteration order
    ///     (track index, then clip index — the order `ProjectStore.refusalOrder`
    ///     also uses). It is not a second copy of that rule: when the error DOES
    ///     name a clip this argument is not consulted, so the two can never
    ///     disagree about an offender.
    public static func resolve(error: any Error,
                               focusID: UUID?,
                               orderedTargets: [UUID]) -> UUID? {
        if let named = (error as? ProjectError)?.refusalAnchorClipID {
            return named
        }
        return focusID ?? orderedTargets.first
    }
}
