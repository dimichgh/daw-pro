import Foundation

/// The ONE producer of a counted Edit-menu title — "Copy Clip" for one, "Copy 3
/// Clips" for many.
///
/// WHY IT WAS HOISTED (m23-ek-3). The rule shipped inside
/// `DeleteMenuPolicy.countedTitle`, whose own doc demands "ONE producer, so no
/// surface can invent its own plural" — and that body hardcodes the verb
/// `"Delete"`, so the clipboard's five new titles could not reuse it. Copying it
/// would have created the second plural producer that doc forbids, so the rule
/// moved up one level and `DeleteMenuPolicy.countedTitle` became a forwarder.
/// ⚠️ `DeleteMenuPolicyTests` passes UNEDITED across that refactor, which is the
/// acceptance criterion for it: the Delete titles are unchanged, character for
/// character.
///
/// ENGLISH ONLY, DELIBERATELY, and stated so nobody "fixes" it into a
/// half-localisation. The app ships no `.strings` catalogue and no `String(
/// localized:)` call anywhere; a lone `AttributedString(localized:)` here would
/// look like localisation while the other 40 menu items stayed hardcoded. When
/// localisation lands it lands as one item, and this is the single site the
/// plural rule has to move through.
public enum EditMenuTitles {

    /// "Copy Clip" for one, "Copy 3 Clips" for many.
    ///
    /// THE COUNT IS NAMED FOR EVERY n ≠ 1, INCLUDING ZERO — "Copy 0 Clips" is
    /// never shown (a zero-count surface resolves to the bare inert title before
    /// reaching here) but is the honest answer if it ever were, rather than a
    /// title that quietly claims a blast radius of one.
    public static func counted(verb: String, count: Int,
                               singular: String, plural: String) -> String {
        count == 1 ? "\(verb) \(singular)" : "\(verb) \(count) \(plural)"
    }
}
