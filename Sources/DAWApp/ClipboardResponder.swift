import AppKit
import DAWAppKit
import DAWControl
import Foundation

// m25-f-1 — ⌘X / ⌘C / ⌘V, ON THE RESPONDER CHAIN.
//
// ⚠️ READ `ClipboardResponderRouting`'s banner FIRST: it carries the user's
// 2026-08-12 authorisation, the reason a `.keyboardShortcut` would be a
// regression rather than a shortcut, and the seven measurements (P1–P7) this
// file's every decision rests on.
//
// THE WHOLE MECHANISM IN FOUR LINES: SwiftUI's Edit menu already ships
// nil-target `cut:` ⌘X / `copy:` ⌘C / `paste:` ⌘V items (P2). A nil-target item
// is dispatched to the FIRST responder that claims the selector. This object
// claims all three and is spliced in AFTER the window (P1), i.e. behind every
// text field, every field editor and every view in the window. So text keeps
// ⌘C for free (P4) and the app gets it everywhere else — with no key equivalent
// of our own outranking anything.
//
// ⚠️ IT DECIDES NOTHING. `ClipboardMenuPolicy` (via `AppModel.copyMenuItem` /
// `cutMenuItem` / `pasteMenuItem`) decides which surface owns each verb and
// whether it is live; `AppModel.performMenuCopy/Cut/Paste` performs it. This is
// the SECOND ROUTE to those verbs, never a second policy — the m23-cf rule.
//
// ⚠️ THE TITLE IS NOT THE POLICY'S ANY MORE (2026-08-12, the user's ruling): the
// native items read the BARE macOS word in every state. Enablement is untouched
// by that ruling and is still entirely the policy's.
//
// ⚠️ IT LIVES IN ITS OWN FILE with its `AppModel` extension, the
// `EditClipboardStaging` / m23-cq-1 deviation: `DAWProApp.swift` is 9 000+ lines
// and a standing merge magnet, so its footprint there is two stored properties
// and one call.

/// The app's clipboard responder: the object that makes the NATIVE Edit ▸ Cut /
/// Copy / Paste items — and therefore ⌘X / ⌘C / ⌘V — act on clips and notes.
///
/// SPLICED IN AT `window.nextResponder`, WHICH IS THE ENTIRE SAFETY ARGUMENT.
/// AppKit resolves a nil-target action by walking the chain from the first
/// responder outwards; every text surface in the window is nearer the front than
/// the window itself, so a focused rename field, the Copilot input and every
/// Settings field claim `copy:` before this object is ever reached (MEASURED,
/// P4: with a field editor focused the resolved target was `NSTextView` and this
/// object's `validateMenuItem` was not called at all).
@MainActor
final class ClipboardResponder: NSResponder, NSMenuItemValidation {

    /// Weak — the model owns the app's lifetime, not the other way round, and a
    /// responder left in a torn-down window's chain must never keep it alive.
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // Never unarchived: this object is created in code and spliced into a
        // live window's chain. A `fatalError` here is unreachable by design.
        fatalError("ClipboardResponder is not archivable")
    }

    // MARK: - The four verbs

    // ⚠️ THESE FOUR ARE THE ONLY SELECTORS THIS OBJECT MAY CLAIM, and
    // `ClipboardResponderRouting.claimedSelectorNames` is where that list lives
    // with its reasons — notably why `delete:` is STILL excluded, and what
    // decision admitted `selectAll:` at m25-s.
    //
    // ⚠️ NO `override` ON THE CLIPBOARD THREE. `NSResponder` declares none of
    // them (measured: the compiler rejects `override` on `copy(_:)`), so they are
    // plain `@objc` methods whose selectors happen to be the ones AppKit's menu
    // items send. ⚠️ `selectAll(_:)` IS THE EXCEPTION and DOES need `override` —
    // see its own note; do not "make them consistent".

    @objc func cut(_ sender: Any?) {
        model?.performMenuCut()
    }

    @objc func copy(_ sender: Any?) {
        model?.performMenuCopy()
    }

    @objc func paste(_ sender: Any?) {
        model?.performMenuPaste()
    }

    /// ⌘A / Edit ▸ Select All (m25-s) — selects every note in the piano roll, and
    /// ONLY there. `SelectAllMenuPolicy` decides; this routes.
    ///
    /// ⚠️⚠️ **`override` IS REQUIRED HERE AND IS REJECTED ON THE THREE ABOVE.
    /// MEASURED, and the asymmetry is real rather than a style slip** — a reader
    /// who "fixes" this to match its neighbours gets a compile error, and one who
    /// makes the neighbours match this gets three. `NSResponder.h` declares
    /// `selectAll:` (in the informal `NSStandardKeyBindingMethods` category) and
    /// does NOT declare `copy:` / `cut:` / `paste:`, so Swift imports the former
    /// as an overridable member of `NSResponder` and the latter as nothing at all.
    ///
    /// ⭐ IT DECLARES IT WITHOUT IMPLEMENTING IT, WHICH IS WHY CLAIMING IT IS SAFE:
    /// `class_getInstanceMethod(NSResponder.self, "selectAll:")` is **nil**
    /// (measured 2026-08-13), as it is on `NSWindow`, `NSWindowController` and
    /// `NSApplication`. So no object behind our splice point responds to it, the
    /// chain walk cannot be intercepted between us and NSApp, and — measured in
    /// the same probe — the native item was ALREADY DISABLED before we claimed it.
    ///
    /// ⚠️ NEVER CALL `super.selectAll(sender)`. The superclass declaration has no
    /// implementation behind it; that is an unrecognized-selector crash, not a
    /// polite no-op.
    override func selectAll(_ sender: Any?) {
        model?.performMenuSelectAll()
    }

    // MARK: - Validation

    /// Drives the native item's ENABLED STATE and TITLE off the same
    /// `ClipboardMenuPolicy` resolution the app has always used.
    ///
    /// ⚠️⚠️ **THE `NSMenuItemValidation` CONFORMANCE ON THE CLASS IS
    /// LOAD-BEARING, NOT DECORATION.** AppKit only consults `validateMenuItem:`
    /// on a target that CONFORMS to this protocol. Write the method without the
    /// conformance and AppKit falls back to "the target responds to the
    /// selector, therefore enable it" — the items would never grey out, and ⌘C
    /// would fire clip-copy in the Mix console and behind modal panels. That
    /// failure is silent, so `ClipboardResponderSiteTests` pins the conformance.
    ///
    /// ⭐ THE TITLE ASSIGNMENT IS A NO-OP THAT STATES A CONTRACT, and that is
    /// deliberate. `ClipboardResponderRouting.presentation` resolves the BARE
    /// macOS word for every state — the user's 2026-08-12 ruling ("we do not
    /// need to use copy 3 clips… use common logic and commonly adopted partice
    /// for such behavior") — so this line writes "Copy" over "Copy". Keeping it
    /// means the plain word is RESTORED rather than merely never set, so a future
    /// retitle from anywhere else cannot leave a stale count on the item.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let model, let action = menuItem.action else { return true }
        let name = NSStringFromSelector(action)

        // ⚠️⚠️ **SELECT ALL IS DISPATCHED BEFORE THE CLIPBOARD LOOKUP, AND THE
        // ORDER IS THE BUG THIS AVOIDS.** `ClipboardResponderRouting.verb`
        // answers nil for `selectAll:` — it is claimed, but it is not a clipboard
        // verb — so resolving it through that lookup first would drop it into the
        // fallback below and return `true`. The item would be PERMANENTLY LIVE in
        // every state while `performMenuSelectAll()` quietly returned false: a
        // menu row that is never greyed and never does anything, which is exactly
        // the "silently nothing" this feature was required not to ship.
        if name == ClipboardResponderRouting.selectAllSelectorName {
            let presentation = ClipboardResponderRouting.presentation(
                for: model.selectAllMenuItem)
            menuItem.title = presentation.title
            return presentation.isEnabled
        }

        guard let verb = ClipboardResponderRouting.verb(forSelectorName: name) else {
            // Unreachable in practice: AppKit only routes here for a selector
            // this object implements, and every one of them is handled above.
            // `true` rather than `false` so a hypothetical fifth selector is
            // left alone rather than silently disabled.
            return true
        }
        let presentation = ClipboardResponderRouting.presentation(
            for: model.clipboardMenuItem(for: verb))
        menuItem.title = presentation.title
        return presentation.isEnabled
    }

    // ⛔ THE PRE-DISPLAY TITLE RESET WAS HERE AND WAS DELETED 2026-08-12.
    //
    // It existed for exactly one job: un-write a COUNTED title ("Copy 3 Clips")
    // that `validateMenuItem` had put on a native item, in the one state where
    // this object is never asked again — a rename field focused, the field
    // editor owning ⌘C (P4). The user then ruled counted titles out ("we do not
    // need to use copy 3 clips… use common logic and commonly adopted partice
    // for such behavior"), so nothing in this app ever writes a title other than
    // the bare macOS word, and there is nothing left to reset.
    //
    // ⭐ IT WORKED, AND THE MEASUREMENT IS KEPT ON `ClipboardResponderRouting`
    // (P5/P6) so that nobody re-derives it: `NSMenu.didBeginTrackingNotification`
    // fires before the whole validation pass, which is early enough to reset
    // titles from. If counted titles are ever wanted again, that is the hook —
    // and NOT the Edit menu's delegate slot, which SwiftUI owns (P7).
}

// MARK: - Installation

extension AppModel {

    /// The resolved Edit-menu item for one verb — the ONE place a verb becomes a
    /// `ClipboardMenuItem`, so the responder cannot resolve Paste through Copy's
    /// policy function.
    ///
    /// ⚠️ THE SWITCH IS NOT CEREMONY. Copy and Cut share a body
    /// (`ClipboardMenuPolicy.copyMenuItem(verb:…)`, so Cut's enablement can never
    /// drift from Copy's); PASTE DOES NOT — it is routed on the CLIPBOARD'S KIND
    /// rather than on a selection, because you can paste with nothing selected at
    /// all. Handing `.paste` to the copy body would compile and answer a
    /// different question.
    func clipboardMenuItem(for verb: ClipboardVerb) -> ClipboardMenuItem {
        switch verb {
        case .copy: return copyMenuItem
        case .cut: return cutMenuItem
        case .paste: return pasteMenuItem
        }
    }

    /// Splices the clipboard responder into the content window's chain, and arms
    /// the pre-display title reset. Idempotent — safe to call on every window
    /// appearance and every key-window transition.
    ///
    /// ⚠️ **INSTALLED INTO `contentWindow`, THE SAME WINDOW IDENTITY THE SPACE
    /// AND DELETE KEYS GUARD** (`transportKeyWindow`'s `.main`). One notion of
    /// "our window" across the key path and the menu path, so the two can never
    /// disagree about which window the app's keyboard belongs to.
    ///
    /// ⚠️ **THE PREVIOUS `nextResponder` IS PRESERVED, NOT DROPPED.** MEASURED
    /// (P1): the window's next responder is `AppKitWindowController`, and behind
    /// it sit `AppKitApplication` and SwiftUI's own app delegate. Overwriting
    /// that link without re-attaching it would cut every unhandled action in the
    /// app off from NSApp — window ordering, Help, and anything SwiftUI routes
    /// through its delegate.
    ///
    /// ⚠️ **RE-ASSERTED, BECAUSE A CHAIN LINK IS NOT OURS TO OWN.** SwiftUI
    /// creates and re-creates window controllers; if it ever reassigns
    /// `nextResponder`, this object drops silently out of the chain and ⌘C stops
    /// working with no error anywhere. `applyWindowFloor()` (window appearance)
    /// and the key-window notification below both re-assert, and the install is
    /// a no-op when already correct (`ClipboardChainInstall.alreadyInstalled`) —
    /// splicing twice would set this object's `nextResponder` to itself and hang
    /// every chain walk in the process.
    @discardableResult
    func installClipboardResponder() -> ClipboardChainInstall {
        let responder = clipboardResponder ?? ClipboardResponder(model: self)
        clipboardResponder = responder
        armClipboardKeyWindowObserver()

        let plan = ClipboardResponderRouting.chainInstall(
            hasWindow: contentWindow != nil,
            windowNextResponderIsOurs: contentWindow?.nextResponder === responder)
        switch plan {
        case .noWindow, .alreadyInstalled:
            return plan
        case .insert:
            guard let window = contentWindow else { return .noWindow }
            responder.nextResponder = window.nextResponder
            window.nextResponder = responder
            return .insert
        }
    }

    /// Arms the KEY-WINDOW RE-ASSERT, once.
    ///
    /// `installClipboardResponder()` is idempotent and cheap, so re-running it
    /// whenever a window becomes key is the safety net for the one failure this
    /// design cannot otherwise detect: SwiftUI reassigning `nextResponder` and
    /// silently unhooking ⌘C, with no error anywhere.
    private func armClipboardKeyWindowObserver() {
        guard clipboardKeyWindowObserver == nil else { return }
        clipboardKeyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The `.main` queue guarantees the main thread; the install touches
            // only main-actor state.
            MainActor.assumeIsolated { _ = self?.installClipboardResponder() }
        }
    }

    /// The RAW facts behind `debug.editClipboard`'s `responder` block — see the
    /// echo's own note. Deliberately raw and never a verdict: on a staging binary
    /// the content window is frequently not key, and `NSApp.target(forAction:)`
    /// legitimately answers nil there, so a boolean "wired: false" would report a
    /// broken feature where there is none.
    var clipboardResponderFacts: JSONValue {
        let responder = clipboardResponder
        var chain: [JSONValue] = []
        var walker: NSResponder? = contentWindow?.firstResponder
        var hops = 0
        while let current = walker, hops < 24 {
            chain.append(.string(current === responder
                                 ? "ClipboardResponder"
                                 : String(describing: type(of: current))))
            walker = current.nextResponder
            hops += 1
        }
        let target = NSApp.target(forAction: Selector(ClipboardResponderRouting.copySelectorName),
                                  to: nil, from: nil)
        return .object([
            "created": .bool(responder != nil),
            "hasContentWindow": .bool(contentWindow != nil),
            "windowNextResponder": contentWindow?.nextResponder.map {
                .string($0 === responder ? "ClipboardResponder"
                                         : String(describing: type(of: $0)))
            } ?? .null,
            "chainFromFirstResponder": .array(chain),
            "targetForCopy": target.map {
                .string(($0 as AnyObject) === responder ? "ClipboardResponder"
                                                        : String(describing: type(of: $0)))
            } ?? .null,
            "keyWindowObserverArmed": .bool(clipboardKeyWindowObserver != nil),
        ])
    }
}
