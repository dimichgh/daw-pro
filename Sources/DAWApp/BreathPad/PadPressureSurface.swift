import AppKit
import DAWAppKit
import DAWCore
import SwiftUI

/// m34-f step ① — THE PRESSURE BRIDGE. An `NSView` that owns the breath pad's
/// mouse so it can read `NSEvent.pressure`, which SwiftUI has no API for at all.
///
/// ## Why an `NSView` and not an event monitor or a transparent overlay
///
/// ⛔ **`pressureConfiguration` IS READ FROM THE VIEW THAT RECEIVES THE
/// `mouseDown`, so the configuration and the mouse handling cannot live in
/// different objects.** AppKit sets up the trackpad *before* the click lands
/// ("the system will go ahead and set up the trackpad before mouse down even
/// occurs", WWDC 2015 session 217), using the configuration of the view under
/// the pointer. A hit-test-transparent overlay never receives the `mouseDown`,
/// so its configuration is never consulted; a local `NSEvent` monitor sees the
/// pressure events but has no view whose configuration AppKit could read. Either
/// shape would leave the gesture on the system default — which is exactly the
/// one we must not have (below).
///
/// ⚠️ **THEREFORE THE SwiftUI `DragGesture` ON THE DIAL IS REPLACED, NOT
/// SUPPLEMENTED.** Two input paths onto one model would double every
/// `beginDrag`, and the pad's commit is gated on "the dot moved", so a doubled
/// gesture would spend two undo steps on one click. There is exactly one mouse
/// handler for the dial and it is this view.
///
/// ## `.primaryGeneric`, and why the default is wrong for music
///
/// ⛔⛔ **THE SYSTEM DEFAULT `.primaryDeepClick` IS A TWO-STAGE, *ACTUATED*
/// BEHAVIOUR: crossing into stage 2 fires the Force Click haptic "thunk".** A
/// physical click transient firing mid-note because the player leaned in a
/// little harder would punch a detent through the middle of a breath swell — it
/// would read as a mixing artefact, not as expression. `.primaryGeneric` is one
/// stage, no actuation, full 0…1 dynamic range, and is the case Apple's own
/// header calls out as "suitable for drawing and general pressure use".
///
/// ⚠️ **NO GATE IN THIS TREE CAN FEEL A HAPTIC DETENT.** That this configuration
/// takes effect is a HAND check: press slowly into the pad through a swell and
/// feel for a click that is not there. What IS machine-checkable — that the
/// configuration object is built with `.primaryGeneric` and installed on the
/// view — is pinned by `PadPressureSurfaceTests`.
///
/// ## Coordinates
///
/// ⚠️ **`isFlipped` IS `true` AND THAT IS LOAD-BEARING.** AppKit's default
/// coordinate space is y-UP; `BreathPadGeometry` was written for SwiftUI's
/// y-DOWN. Without the flip every gesture would land mirrored about the
/// horizontal axis — the dot would answer a press in the wrong half of the ring,
/// which is invisible to every synthetic test (they call the model directly and
/// never go through this view) and obvious to a human within one second.
struct PadPressureSurface: NSViewRepresentable {
    @Bindable var model: BreathPadModel
    var side: CGFloat

    func makeNSView(context: Context) -> PadPressureNSView {
        let view = PadPressureNSView()
        view.model = model
        view.side = side
        return view
    }

    func updateNSView(_ view: PadPressureNSView, context: Context) {
        view.model = model
        view.side = side
    }
}

/// The mouse/pressure handler. Public-in-module so a test can construct it and
/// assert the configuration without a running app.
final class PadPressureNSView: NSView {
    /// Weak by construction of ownership: the model is owned by `AppModel` for
    /// the life of the app, and the view is recreated by SwiftUI freely.
    weak var model: BreathPadModel?
    var side: CGFloat = 0

    /// THE configuration, built once and named so a test can assert it rather
    /// than re-deriving the reasoning.
    static let musicalPressure = NSPressureConfiguration(pressureBehavior: .primaryGeneric)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pressureConfiguration = Self.musicalPressure
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    /// SwiftUI's y-down space, so `BreathPadGeometry` needs no conversion.
    override var isFlipped: Bool { true }

    /// The pad is a control, not a background: a click that also brings the
    /// window forward must still be the first frame of the gesture, or the user
    /// has to click twice to start playing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var geometry: BreathPadGeometry {
        // The side the VIEW was given, falling back to its own bounds. Both are
        // the same number in practice; the parameter exists so the geometry
        // cannot silently disagree with the Canvas drawn beneath.
        BreathPadGeometry(side: side > 0 ? side : min(bounds.width, bounds.height))
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        model.beginDrag(at: convert(event.locationInWindow, from: nil), geometry: geometry)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, model.gesture != nil else { return }
        model.drag(to: convert(event.locationInWindow, from: nil), geometry: geometry)
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        _ = model.endDrag()
    }

    /// ⭐ **THE THIRD AXIS.** `NSEventTypePressure` is emitted only by a Force
    /// Touch trackpad, which is why its ARRIVAL — not any value it carries — is
    /// what tells the model the machine has a Z axis at all. A mouse and a
    /// non-Force trackpad never send one, so `BreathPadModel.pressure` stays
    /// `nil` there forever and the pad streams exactly what it always did.
    ///
    /// ⚠️ **`stage` IS DELIBERATELY NOT CONSULTED.** With `.primaryGeneric`
    /// there is only ever one stage, so branching on it would be branching on a
    /// constant — and a future reader could not tell that from a real condition.
    override func pressureChange(with event: NSEvent) {
        model?.pressureChanged(Double(event.pressure))
    }
}
