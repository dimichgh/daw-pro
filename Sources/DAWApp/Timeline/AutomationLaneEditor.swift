import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

/// Canvas breakpoint editor for one automation lane, horizontally aligned with
/// the clip timeline (same beat→x mapping). Thin over the headless
/// `AutomationGeometry` / `AutomationEdit`: it draws a neon polyline with glowing
/// breakpoints and routes gestures, holding a local `draft` array that it submits
/// through `onCommit` (wired to `ProjectStore.setAutomationPoints`, whole-array
/// replace). The store canonicalizes + clamps, so the editor re-reads the
/// canonical points after each gesture rather than assuming its own order.
///
/// Interactions (docs/DESIGN-LANGUAGE.md "Glass Cockpit"):
///  - click empty space = add a breakpoint at that beat/value (then drag it),
///  - drag a breakpoint = move it, with a live value/beat readout by the cursor,
///  - double-click a breakpoint (or select + ⌫) = delete,
///  - a disabled lane renders dimmed (its curve is inert until re-enabled).
struct AutomationLaneEditor: View {
    /// The lane being edited (value input — previewable without the store).
    var lane: AutomationLane
    /// The v0 param this lane drives (volume/pan) — drives color + readout.
    var param: AutomationParam
    var geometry: AutomationGeometry
    /// Drawn width — the timeline's content width, so the lane spans the ruler.
    var contentWidth: CGFloat
    /// Submits the whole point array (wired to `setAutomationPoints`).
    var onCommit: ([AutomationPoint]) -> Void
    /// m23-ai: where this lane publishes "I hold a breakpoint selection, so I
    /// would consume ← / →", and where the debug seam stages one in. Optional
    /// because not every mount is under the arrange's arrow-key handler, and
    /// deliberately WITHOUT a default: there are N mounts of this view, so a
    /// future third one must be made to decide rather than silently inherit
    /// `nil` (the same reason `RescheduleCause` and `StartAnchorPolicy` carry no
    /// defaults — let the compiler enumerate the call sites). This is where it
    /// parts company with `PianoRollView`, which defaults its bridge because it
    /// has exactly one mount.
    var pointSelection: AutomationPointSelectionBridge?

    /// ⭐ THE DELETE KEY, ROUTED (m23-cf, second pass). Returns true when SOME
    /// surface owned the keystroke — which is what this view answers `.handled`
    /// from, and NOT "a breakpoint was removed" (see `AppModel.handleDeleteKey`).
    ///
    /// WHY A THIRD CLAIMANT HAD TO BE ROUTED. This editor owns
    /// `.onKeyPress(.delete)` on its own surface, behind its own `@FocusState`,
    /// alongside `PianoRollView`'s and `ArrangeDeleteKey`'s — three claimants for
    /// one key, arbitrated by SwiftUI in a way this tree measured to be a coin
    /// flip. Leaving this one computing its own rule would have left exactly the
    /// divergence m23-cf exists to remove: a focused lane holding a breakpoint
    /// would eat a DELETE the user meant for the notes selected in the roll.
    ///
    /// ⚠️ OPTIONAL, AND `nil` AT THE MIXER MOUNT ON PURPOSE — the same asymmetry
    /// `pointSelection` already has there, for a stronger reason. `MixerStripView`
    /// mounts the master lane inside the MIX workspace, and `handleDeleteKey`'s
    /// first guard is `workspaceMode == .arrange`; routing that mount would refuse
    /// its DELETE outright and take away a working operation. `nil` keeps this
    /// editor's own `deleteSelection()` as the handler there, which is correct:
    /// in the Mix console it is the only claimant, so there is no arbitration to
    /// make identical. No default, for `pointSelection`'s reason — a future third
    /// mount must be made to decide rather than silently inherit one.
    var onDeleteKey: (() -> Bool)?

    /// Local working copy. Every interaction mutates this; it is submitted on
    /// each change and re-seeded from the canonical lane when a gesture ends.
    @State private var draft: [AutomationPoint]
    @State private var drag: DragState = .idle
    @State private var selection: Int?
    /// Cursor readout during a drag: content-space position + formatted text.
    @State private var readout: Readout?
    @FocusState private var focused: Bool

    init(lane: AutomationLane, param: AutomationParam, geometry: AutomationGeometry,
         contentWidth: CGFloat, onCommit: @escaping ([AutomationPoint]) -> Void,
         pointSelection: AutomationPointSelectionBridge?,
         onDeleteKey: (() -> Bool)?) {
        self.lane = lane
        self.param = param
        self.geometry = geometry
        self.contentWidth = contentWidth
        self.onCommit = onCommit
        self.pointSelection = pointSelection
        self.onDeleteKey = onDeleteKey
        _draft = State(initialValue: lane.points)
    }

    private enum DragState: Equatable {
        case idle
        case moving(Int)   // dragging the breakpoint at this draft index
    }

    private struct Readout: Equatable {
        var position: CGPoint
        var text: String
    }

    /// Volume tracks the fader's cyan; pan stays neutral white (the mixer's
    /// semantics — pan claims no accent). A disabled lane dims to a muted slate.
    private var accent: Color {
        guard lane.isEnabled else { return DAWTheme.textDim }
        switch param {
        case .volume: return DAWTheme.playback
        case .pan: return DAWTheme.textPrimary
        }
    }

    var body: some View {
        canvas
            .frame(width: contentWidth, height: geometry.laneHeight)
            .contentShape(Rectangle())
            // Pointer affordances (docs/DESIGN-LANGUAGE.md): a breakpoint grabs;
            // empty space is a crosshair (click to place a point there).
            .hoverCursor(resolve: pointCursor)
            .gesture(pointDrag)
            .simultaneousGesture(doubleClickDelete)
            .overlay(alignment: .topLeading) { readoutBubble }
            .focusable()
            .focused($focused)
            // m23-cf (second pass): where a routing closure is wired (the ARRANGE
            // mount), DELETE asks the app's ONE ownership decision instead of
            // deciding here — see `onDeleteKey`. The routed answer still lands in
            // `deleteSelection()` below, via `pointSelection.deleteNonce`, so this
            // editor keeps doing its own work through its own `@State private`
            // draft.
            //
            // ⚠️ THE `??` BRANCH IS NOT A FALLBACK FOR "SOMEBODY FORGOT TO WIRE
            // IT" — it is the MIXER mount's shipped behaviour, kept deliberately.
            // That mount lives in the Mix workspace, where `handleDeleteKey`'s
            // workspace guard refuses by design, so routing it would delete the
            // master lane's DELETE key rather than fix it.
            // ⭐⭐ m23-fk — THE KEY LIST IS THE FIX, AND THIS MOUNT IS THE ONE THE
            // USER LOSES SOMETHING BY. `.onKeyPress` matches on the event's
            // CHARACTERS; `KeyEquivalent.delete` is 0x08 (BACKSPACE) and the ⌫
            // key sends 0x7F (DELETE), so `.onKeyPress(.delete)` never fired.
            // Everywhere else the m23-cf-3 `NSEvent` monitor covers for that —
            // but NOT in the Mix console, where `handleDeleteKey`'s first guard
            // is `workspaceMode == .arrange` and the monitor therefore refuses
            // the master lane's DELETE by design (`handleKeyDownEvent` returns
            // the event when `handleDeleteKey()` answers false). This mount is
            // the only path there, so until this spelling it had none: ⌫ on a
            // selected master-volume breakpoint did nothing and double-click was
            // the only way to remove it. NEVER WORKED — not a regression.
            //
            // ⚠️ WHAT IS MEASURED AND WHAT IS NOT, stated because the difference
            // is a real bound on the claim above. MEASURED: the character (the
            // system translates `kVK_Delete` to 0x7F), the mount being in the
            // Mix tree, and that the monitor passes the key on there. NOT
            // MEASURED HEADLESSLY: this editor's `@FocusState` is written in
            // exactly one place — `beginDrag`, i.e. the CLICK — and no seam can
            // click, so a never-clicked staging run reads `focused == false` and
            // the mount receives nothing. In use the two are the same gesture:
            // the click that selects the breakpoint is the click that focuses
            // this editor.
            // ⚠️⚠️ `phases: [.down]` IS LOAD-BEARING — see
            // `ContentView.ArrangeDeleteKey` for the measured sequence. Omitting
            // it admits `.repeat`, and here that would walk a held ⌫ down the
            // breakpoint list one point per repeat tick.
            .onKeyPress(keys: [KeyEquivalent("\u{7F}"), .delete, .deleteForward],
                        phases: [.down]) { _ in
                // m23-fi probe, first statement. ⭐ THIS MOUNT IS THE ONE
                // `deleteKeyFunnelSeq` COULD NEVER SEE AT ALL: the `??` branch
                // below (the MIXER mount, `onDeleteKey == nil`) calls
                // `deleteSelection()` directly and never enters `handleDeleteKey`,
                // so m23-cf's funnel instrument was blind to it by construction.
                KeyPressProbe.automationLaneDelete += 1
                guard let onDeleteKey else { return deleteSelection() }
                return onDeleteKey() ? .handled : .ignored
            }
            // Re-seed from the canonical lane whenever it changes outside a drag
            // (undo, an agent edit, or our own committed gesture landing sorted).
            .onChange(of: lane.points) { _, points in
                if drag == .idle { draft = points; selection = nil }
            }
            // m23-ai: publish whether THIS lane would consume a keystroke — the
            // same `liveSelectionIndex` test the DELETE handler just above
            // applies to decide between consuming and falling through. The
            // arrange's arrow-key nudge refuses while any lane claims, so ← with
            // a breakpoint selected edits the breakpoint instead of sliding the
            // whole clip underneath the user (`AutomationPointSelectionBridge`).
            //
            // KEYED ON THE PREDICATE, NOT ON `selection`, deliberately: the test
            // has two terms and `draft` is the other one. A draft that shrinks
            // under a stale index leaves `selection` unchanged while the editor
            // stops consuming keys, and `.onChange(of: selection)` would never
            // see it — the bridge would keep claiming a key this editor no
            // longer wants. `draft` is `@State` here, so a mutation
            // re-evaluates `body` and this comparison runs.
            //
            // `.onChange`, never `body` (the `PianoRollView` reason: this gates
            // a keyboard path, so it must be an observable transition), and
            // `initial: true` so a lane that appears already selected reports it
            // rather than waiting for a change.
            .onChange(of: liveSelectionIndex != nil, initial: true) { _, claims in
                pointSelection?.report(lane: lane.id, hasSelection: claims)
            }
            // m23-fi PROBE — this editor's `@FocusState` VALUE, keyed by lane id
            // so N mounted lanes cannot clobber each other's report.
            .onChange(of: focused, initial: true) { _, isFocused in
                KeyPressProbe.reportAutomationLaneFocus(lane: lane.id, focused: isFocused)
            }
            // m23-ai: the debug seam's staged selection — the
            // `follow.externalScrollNonce` pattern (watch the NONCE, so a gate
            // asking for the same state twice still applies). This is the only
            // way anything outside can reach `selection` and `draft`, which are
            // `@State private`.
            //
            // AN EMPTY LANE CANNOT BE ARMED: `draft.indices.first` is nil, so
            // `select: true` on a lane with no breakpoints selects nothing and
            // this editor keeps claiming nothing. That is left visible on
            // purpose — `arrangeSelectionDebug` THROWS when the state it staged
            // never arrives, so a gate whose fixture forgot to add a breakpoint
            // fails loudly instead of certifying a guard that was never armed.
            .onChange(of: pointSelection?.stageNonce) { _, _ in
                guard let pointSelection else { return }
                selection = pointSelection.stagedSelect ? draft.indices.first : nil
            }
            // m23-cf: EDIT ▸ DELETE reaching this lane. The menu item cannot call
            // `deleteSelection()` itself (`selection`/`draft` are `@State
            // private`), so it bumps `deleteNonce` and every mounted lane applies
            // it — which is safe precisely because the operation re-applies the
            // editor's OWN `liveSelectionIndex` guard. A lane the user was not
            // editing returns `.ignored` and mutates nothing, so the broadcast
            // touches exactly the lane (or lanes) that would have consumed the
            // DELETE key.
            //
            // THE SAME FUNCTION THE KEY PRESS CALLS, never a parallel mutation:
            // one `commit(AutomationEdit.removePoint(…))`, so undo behaves
            // identically through both routes. The result is discarded because a
            // menu click has no `KeyPress.Result` to answer.
            //
            // ⚠️ NOTE WHAT IS BEING OBSERVED: `Optional<Int>`, exactly like the
            // `stageNonce` handler above, so this also fires on `nil → n` when a
            // bridge ATTACHES — not only on a real `requestDelete()`. That is
            // deliberately harmless rather than accidentally harmless: there is
            // no caller-side emptiness guard here BECAUSE the callee is the one
            // home for it. `deleteSelection()` returns `.ignored` unless
            // `liveSelectionIndex` is non-nil, and a lane that does have a point
            // selected at attach time is precisely a lane where deleting is the
            // correct answer. Do not "fix" this by adding a second selection
            // test at this call site; that is the divergence `liveSelectionIndex`
            // exists to prevent.
            .onChange(of: pointSelection?.deleteNonce) { _, _ in
                _ = deleteSelection()
            }
            .onDisappear {
                // m23-ai: drop THIS lane's claim, and only this lane's. A
                // latched id would kill the arrange's arrow keys for the rest
                // of the session with nothing on screen to explain why; a bare
                // clear-everything would let a closing lane cancel a sibling
                // lane's live claim, which is the clobber the bridge's `Set`
                // exists to prevent.
                pointSelection?.clear(lane: lane.id)
            }
    }

    // MARK: - Drawing

    /// A value snapshot of everything the renderer needs, taken on the main actor
    /// before the closure runs. All fields are Sendable so the `@Sendable` Canvas
    /// closure captures only plain values — never `self` (CANVAS CONTRACT, m16-a).
    private struct DrawContext {
        var draft: [AutomationPoint]
        var geometry: AutomationGeometry
        var param: AutomationParam
        var isEnabled: Bool
        var accent: Color
        var selection: Int?
    }

    private var canvas: some View {
        // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
        // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
        let ctx = DrawContext(
            draft: draft, geometry: geometry, param: param,
            isEnabled: lane.isEnabled, accent: accent, selection: selection)
        return Canvas { @Sendable context, size in
            Self.drawBackground(&context, size: size, ctx: ctx)
            Self.drawGuideLine(&context, size: size, ctx: ctx)
            Self.drawPolyline(&context, size: size, ctx: ctx)
            Self.drawBreakpoints(&context, ctx: ctx)
        }
    }

    private nonisolated static func drawBackground(_ context: inout GraphicsContext, size: CGSize, ctx: DrawContext) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(DAWTheme.background.opacity(ctx.isEnabled ? 0.45 : 0.30))
        )
        // Hairline top edge separating the lane from the clip row above it.
        context.fill(
            Path(CGRect(x: 0, y: 0, width: size.width, height: 1)),
            with: .color(DAWTheme.hairline)
        )
    }

    /// The neutral resting line (unity gain / center pan) — a faint dashed guide.
    private nonisolated static func drawGuideLine(_ context: inout GraphicsContext, size: CGSize, ctx: DrawContext) {
        let y = ctx.geometry.y(forValue: ctx.param.neutralValue)
        context.stroke(
            Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
            with: .color(DAWTheme.textDim.opacity(0.25)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 4])
        )
    }

    /// Neon polyline: flat lead-in from the left edge to the first point, linear
    /// segments between points, flat lead-out to the right edge (matching
    /// `AutomationLane.value(atBeat:)`). Drawn bloom-under-core for the glow
    /// recipe. An empty lane draws a flat line at the neutral value.
    private nonisolated static func drawPolyline(_ context: inout GraphicsContext, size: CGSize, ctx: DrawContext) {
        let sorted = AutomationLane.canonicalize(ctx.draft)
        var line = Path()
        if let first = sorted.first {
            let firstPoint = ctx.geometry.point(for: first)
            line.move(to: CGPoint(x: 0, y: firstPoint.y))
            line.addLine(to: firstPoint)
            for point in sorted.dropFirst() {
                line.addLine(to: ctx.geometry.point(for: point))
            }
            if let last = sorted.last {
                let lastPoint = ctx.geometry.point(for: last)
                line.addLine(to: CGPoint(x: size.width, y: lastPoint.y))
            }
        } else {
            // Empty lane: a flat neutral line (inert but shows the target level).
            let y = ctx.geometry.y(forValue: ctx.param.neutralValue)
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
        }
        let bright = ctx.isEnabled ? 1.0 : 0.4
        // Wide faint bloom first, then the bright core.
        context.stroke(line, with: .color(ctx.accent.opacity(0.18 * bright)),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        context.stroke(line, with: .color(ctx.accent.opacity(0.9 * bright)),
                       style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
    }

    /// Glowing breakpoint dots (faint disc + bright core), the selected one ringed.
    private nonisolated static func drawBreakpoints(_ context: inout GraphicsContext, ctx: DrawContext) {
        let bright = ctx.isEnabled ? 1.0 : 0.45
        for (index, point) in ctx.draft.enumerated() {
            let p = ctx.geometry.point(for: point)
            let isSelected = ctx.selection == index
            // Bloom.
            context.fill(
                Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)),
                with: .color(ctx.accent.opacity(0.22 * bright))
            )
            // Core.
            context.fill(
                Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)),
                with: .color(ctx.accent.opacity(bright))
            )
            if isSelected {
                context.stroke(
                    Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)),
                    with: .color(DAWTheme.textPrimary.opacity(0.9)),
                    lineWidth: 1.5
                )
            }
        }
    }

    // MARK: - Readout bubble

    @ViewBuilder
    private var readoutBubble: some View {
        if let readout {
            Text(readout.text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(param == .pan ? DAWTheme.textPrimary : DAWTheme.playback)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(DAWTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
                .glow(param == .pan ? DAWTheme.textPrimary : DAWTheme.playback, radius: 4, intensity: 0.35)
                .fixedSize()
                // Sit just above the dragged point, clamped into the lane.
                .offset(
                    x: min(max(readout.position.x - 26, 0), max(0, contentWidth - 70)),
                    y: max(0, readout.position.y - 26)
                )
                .allowsHitTesting(false)
        }
    }

    // MARK: - Gestures

    /// Rest cursor: grab over an existing breakpoint (it's movable), crosshair over
    /// empty space (a click there ADDS a point — the place/paint family).
    private func pointCursor(at location: CGPoint) -> CursorKind? {
        geometry.hitTest(location, points: draft) != nil
            ? CursorAffordance.automationPoint.restCursor
            : CursorAffordance.automationField.restCursor
    }

    private var pointDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == .idle {
                    beginDrag(at: value.startLocation)
                    // Either grabbed a point or added one — both MOVE a point now.
                    DragCursor.set(.grabbing)
                }
                applyDrag(to: value.location)
            }
            .onEnded { _ in endDrag(); DragCursor.clear() }
    }

    /// Double-click a breakpoint to delete it (the drag gesture treats the same
    /// presses as a no-move selection — harmless).
    private var doubleClickDelete: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                guard let index = geometry.hitTest(value.location, points: draft) else { return }
                commit(AutomationEdit.removePoint(draft, index: index))
                selection = nil
            }
    }

    private func beginDrag(at start: CGPoint) {
        focused = true
        if let index = geometry.hitTest(start, points: draft) {
            // Grabbed an existing breakpoint — move it.
            selection = index
            drag = .moving(index)
        } else {
            // Empty space — add a breakpoint here and drag it (click = add).
            let beat = geometry.beat(forX: start.x)
            let value = geometry.value(forY: start.y)
            let added = AutomationEdit.addPoint(draft, atBeat: beat, value: value, in: geometry.range)
            let index = added.count - 1
            draft = added
            selection = index
            drag = .moving(index)
            onCommit(added)
            setReadout(at: start, beat: beat, value: value)
        }
    }

    private func applyDrag(to location: CGPoint) {
        guard case .moving(let index) = drag, draft.indices.contains(index) else { return }
        let beat = geometry.beat(forX: location.x)
        let value = geometry.value(forY: location.y)
        let moved = AutomationEdit.movePoint(draft, index: index, toBeat: beat, value: value, in: geometry.range)
        draft = moved
        onCommit(moved)
        setReadout(at: geometry.point(for: moved[index]), beat: beat, value: value)
    }

    private func endDrag() {
        drag = .idle
        readout = nil
        // A final commit lands sorted; onChange(lane.points) re-seeds the draft.
        onCommit(draft)
    }

    /// The breakpoint a key press would act on — nil when this editor would let
    /// the key fall through instead. THE ONE HOME for "would this lane consume
    /// it?": the DELETE handler below and the m23-ai arrow-key report in `body`
    /// both read this property, so the shielded surface's own test and the guard
    /// that mirrors it cannot drift apart.
    private var liveSelectionIndex: Int? {
        guard let index = selection, draft.indices.contains(index) else { return nil }
        return index
    }

    private func deleteSelection() -> KeyPress.Result {
        guard let index = liveSelectionIndex else { return .ignored }
        commit(AutomationEdit.removePoint(draft, index: index))
        selection = nil
        return .handled
    }

    /// Applies a discrete (non-drag) edit: update the draft and submit it.
    private func commit(_ points: [AutomationPoint]) {
        draft = points
        onCommit(points)
    }

    private func setReadout(at position: CGPoint, beat: Double, value: Double) {
        readout = Readout(position: position, text: param.readout(value))
    }
}
