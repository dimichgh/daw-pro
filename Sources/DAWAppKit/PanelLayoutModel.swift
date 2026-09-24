import CoreGraphics
import Foundation
import Observation
import DAWCore

/// The persistence seam for `PanelLayoutStore` (beta m10-d). Injected so the store
/// is hermetic in tests (an in-memory / spy backing) while the app wires a
/// UserDefaults-backed one — the layout is an app-side sticky PREFERENCE (window
/// chrome), never project data, so it survives relaunch but is never written into
/// the project file. One `Double`-valued slot per dimension, keyed by a stable
/// name. `@MainActor` because the store (a UI-state model) is main-actor isolated.
/// The `PanelDensityBacking` precedent — pure model here, no SwiftUI.
@MainActor
public protocol PanelLayoutBacking: AnyObject {
    /// The stored value for `key`, or nil if that dimension has never been set.
    func loadValue(forKey key: String) -> Double?
    /// Persists `value` for `key`.
    func storeValue(_ value: Double, forKey key: String)
}

/// Adjustable window layout (beta m10-d): the arrange track-sidebar width, the
/// bottom editor's height as a fraction of the window, the GLOBAL track-row
/// height (one value shared by the sidebar headers and the timeline lanes, so
/// they stay pixel-aligned at every size), the two zoom scales, the mixer
/// console's INSERTS disclosure (m23-a), and the follow-the-playhead switch
/// (m23-c2). Each dimension is an
/// app-side sticky PREFERENCE — never project data — persisted through the injected
/// `PanelLayoutBacking` under `panelLayout.<dimension>`, so a resized layout
/// survives close/reopen and relaunch (the `PanelDensityStore` precedent).
///
/// **Clamping lives here**: every setter tames its input to the dimension's range
/// (setting 9999 stores the max), so the view layer can hand a raw drag delta
/// straight through. `@Observable` so a bound view re-renders when a value changes;
/// `@ObservationIgnored` shields the backing (persistence, not observed state).
///
/// SwiftUI-free (this target has no SwiftUI): the DAWApp `PanelSplitter` component
/// drives the setters from its drag gestures and the views read the values.
@MainActor
@Observable
public final class PanelLayoutStore {

    // MARK: - Persistence keys (one per dimension)

    public static let sidebarWidthKey = "sidebarWidth"
    public static let editorFractionKey = "editorFraction"
    public static let rowHeightKey = "rowHeight"
    /// Arrange horizontal zoom (m17-b) — pixels per beat. Rides the same
    /// app-sticky preference mechanism as the other dimensions (never project
    /// data, never undoable, never in the wire snapshot).
    public static let arrangePPBKey = "arrangePPB"
    /// Piano-roll horizontal zoom (m21-c) — the `arrangePPB` sibling slot.
    public static let pianoRollPPBKey = "pianoRollPPB"
    /// PITCH-EDITOR horizontal zoom (m23-ap p2-b) — the `pianoRollPPB` twin for
    /// the second bottom editor pane. Design §5.8.
    ///
    /// ⚠️ **`debug.panelLayout` TIER, NEVER `view.panelLayout`.** That verb owns
    /// only what determines *what a capture can SEE* and accepts exactly two
    /// keys; a pitch-editor zoom *"changes what an eye prefers, not what exists
    /// to be seen"*, so it joins `pianoRollPPB` in the debug tier and sending it
    /// to `view.panelLayout` is a rejected unknown key ON PURPOSE.
    ///
    /// ⚠️ **NO ANCHOR RE-PIN RIDES ON THIS SLOT, UNLIKE `pianoRollPPB`.** The
    /// roll's no-jump rule hangs off `PianoRollView.repinZoomAnchor`'s
    /// `.onChange(of: layout.pianoRollPPB)`; the pitch editor's Increment A has
    /// no scroll anchor to preserve (it lays its content out from the clip's
    /// left edge and does not restore a scroll offset). ⭐ If a later increment
    /// gives it one, the anchor rule belongs on THIS slot's `onChange`, not on
    /// its callers — that asymmetry is argued on `setPianoRollPPB`.
    public static let pitchEditorPPBKey = "pitchEditorPPB"
    /// Piano-roll VERTICAL zoom (m25-b-4) — the pitch-row height, in points.
    ///
    /// ⚠️⚠️ **NOT `rowHeightKey` ABOVE, AND THE NAME COLLISION IS THE WHOLE REASON
    /// THIS COMMENT EXISTS.** `rowHeight` in this store is the ARRANGE track-lane
    /// height (`24...64`, "Global track-row height (beta m10-d)" at its call site).
    /// Same word, different surface, different units, different range — a slot that
    /// borrowed the name would send every future reader to the wrong axis.
    public static let pianoRollRowHeightKey = "pianoRollRowHeight"
    /// Pitch-editor VERTICAL zoom (m23-ap C4) — the SEMITONE-row height, points.
    ///
    /// ⚠️ **A THIRD SLOT ON THIS AXIS, AND ALL THREE ARE DIFFERENT SURFACES.**
    /// `rowHeight` is the arrange's TRACK lane; `pianoRollRowHeight` is the
    /// roll's pitch rows; this is the pitch editor's. The two bottom panes get
    /// separate slots for the reason `pitchEditorPPB` does: they are never on
    /// screen together (design §3.6), so a shared value would silently rescale
    /// the roll every time a vocal was inspected.
    public static let pitchEditorRowHeightKey = "pitchEditorRowHeight"
    /// Mixer INSERTS disclosure (m23-a) — collapsed vs expanded, for the whole
    /// console (the density precedent: the mixer is ONE panel, so its strips do
    /// not each carry their own chrome state). Stored in the shared `Double`
    /// backing as 1 = collapsed / 0 = expanded; the public API is a `Bool`, so the
    /// encoding never escapes this file.
    public static let mixerInsertsCollapsedKey = "mixerInsertsCollapsed"
    /// Follow-the-playhead (m23-c2) — the ONE opt-in flag every following surface
    /// reads (arrange lanes + all three piano-roll bands), so the two surfaces can
    /// never be in different follow states. Stored in the shared `Double` backing
    /// as 1 = following / 0 = free, the `mixerInsertsCollapsed` encoding; the
    /// public API is a `Bool`.
    public static let followPlayheadKey = "followPlayhead"
    /// Note audition while editing (m23-d) — whether dragging a note vertically
    /// and clicking a key in the gutter sound the pitch on the track's
    /// instrument. Stored in the shared `Double` backing as 1 = on / 0 = off,
    /// the `followPlayhead` encoding; the public API is a `Bool`. This is a
    /// VIEW-CHROME preference and rides the debug tier only: the `note.audition`
    /// wire verb deliberately ignores it (an agent asking to hear something is
    /// making an explicit request, and this switch means "don't sound notes
    /// while I edit", not "never make sound").
    public static let auditionEnabledKey = "auditionEnabled"
    /// Waveform auto-fit (m25-e) — whether an audio clip's peak outline is scaled
    /// up to fill its block (capped) or drawn at raw amplitude. Stored in the
    /// shared `Double` backing as 1 = fit / 0 = raw, the `followPlayhead`
    /// encoding; the public API is a `Bool`.
    public static let waveformNormalizeKey = "waveformNormalize"
    /// Waveform vertical zoom (m25-e) — the magnification applied ON TOP of the
    /// fit (or of raw amplitude), so a user can push a quiet passage's shape up
    /// until the pattern reads. The `arrangePPB` slot's VERTICAL sibling.
    public static let waveformVerticalZoomKey = "waveformVerticalZoom"
    /// Bottom-editor MAXIMIZED mode (m25-b-1) — whether the note editor is
    /// currently suspending the `editorFraction` clamp and filling the window.
    /// Stored in the shared `Double` backing as 1 = maximized / 0 = normal, the
    /// `followPlayhead` encoding; the public API is a `Bool`.
    ///
    /// ⚠️⚠️ **THIS SLOT AND `editorFraction` ARE INDEPENDENT ON PURPOSE.**
    /// Maximizing NEVER writes `editorFraction` — the mode is a render-time
    /// override (`EditorMaximize.effectiveFraction`), so the dragged height is
    /// still sitting in its own slot, unclamped-by-nothing and unchanged, and
    /// leaving the mode restores the USER'S previous height rather than a
    /// default. Anything that "helpfully" writes the maximized fraction back into
    /// `editorFraction` destroys that and would be clamped to 0.55 on the way in
    /// anyway, silently changing the user's layout.
    public static let editorMaximizedKey = "editorMaximized"
    /// Piano-roll VIEWPORT MINIMAP (m25-b-2) — whether the corner navigator is
    /// shown over the note grid. Stored in the shared `Double` backing as
    /// 1 = shown / 0 = collapsed, the `followPlayhead` encoding; the public API is
    /// a `Bool`.
    ///
    /// ⚠️ **It is persisted rather than view `@State` for a structural reason, not
    /// for tidiness.** `PianoRollView` is mounted `.id(clip.id)`, so it — and every
    /// piece of `@State` it owns — is destroyed and rebuilt on a clip switch. A
    /// dismissal held in the view would resurrect itself the next time the user
    /// opened a different clip, which is the "I turned this off and it keeps coming
    /// back" class of defect.
    public static let pianoRollMinimapKey = "pianoRollMinimap"

    // MARK: - Defaults (today's hardcoded values — the pre-m10-d look)

    /// Track sidebar width — was `frame(width: 260)` in ContentView.
    public static let defaultSidebarWidth: CGFloat = 260
    /// Bottom editor height as a fraction of window height — was `geo.height * 0.45`.
    public static let defaultEditorFraction: CGFloat = 0.45
    /// Global track-row / timeline-lane height — was `TimelineLanesView.laneHeight`.
    public static let defaultRowHeight: CGFloat = 34
    /// Arrange pixels-per-beat (m17-b) — the historical fixed 16 pt/beat scale.
    public static let defaultArrangePPB: CGFloat = ArrangeZoom.defaultPixelsPerBeat
    /// Piano-roll pixels-per-beat (m21-c) — the historical fixed 32 pt/beat.
    public static let defaultPianoRollPPB: CGFloat = PianoRollZoom.defaultPixelsPerBeat
    /// Pitch-editor pixels-per-beat (m23-ap p2-b) — opens at the roll's scale so
    /// the two bottom-pane editors feel like siblings.
    /// `PitchEditorGeometry.defaultPixelsPerBeat` is the SAME constant read from
    /// the SAME home; neither is a second copy.
    public static let defaultPitchEditorPPB: CGFloat = PianoRollZoom.defaultPixelsPerBeat
    /// Mixer inserts start EXPANDED (m23-a) — the pre-m23-a look. A persisted
    /// default of "collapsed" would make every existing user's insert chains
    /// vanish on the update; the disclosure is an escape hatch, not the norm.
    public static let defaultMixerInsertsCollapsed = false
    /// Follow starts OFF (m23-c2). The item is explicitly OPT-IN: a view that
    /// moves on its own is the kind of surprise that has to be asked for, and a
    /// persisted default of "on" would start every existing session scrolling.
    public static let defaultFollowPlayhead = false
    /// Note audition starts ON (m23-d): hearing the pitch you drag is the
    /// feature, and the switch exists as an escape hatch for a user who finds
    /// it noisy — not as an opt-in that leaves the item invisible by default.
    public static let defaultAuditionEnabled = true
    /// Waveform auto-fit starts ON (m25-e) — the `auditionEnabled` rationale, not
    /// the `followPlayhead` one. The reported defect IS the un-normalised look, so
    /// an opt-in default would ship the fix invisible; the switch is the escape
    /// hatch back to true amplitude. Reason in full: `WaveformScale`.
    public static let defaultWaveformNormalize = WaveformScale.defaultNormalize
    /// The roll's pitch rows start at their historical 14 pt (m25-b-4) — the zoom
    /// is new, the look is not, so a session that never touches it is unchanged.
    /// ONE home for the number: `PianoRollZoom.defaultRowHeight`, which
    /// `PianoRollModel.defaultRowHeight` also reads.
    public static let defaultPianoRollRowHeight = PianoRollZoom.defaultRowHeight
    /// The pitch editor's semitone rows start at the same 14 pt the roll's do
    /// (m23-ap C4) — `PitchEditorGeometry.defaultRowHeight` is the SAME constant
    /// from the SAME home, so a session that never touches the zoom draws
    /// byte-identically to the read-only Increment A.
    public static let defaultPitchEditorRowHeight = PianoRollZoom.defaultRowHeight
    /// Waveform vertical zoom starts at 1× (m25-e) — no magnification on top of
    /// the fit, the ⌥⌘0 reset target.
    public static let defaultWaveformVerticalZoom = WaveformScale.defaultVerticalZoom
    /// The editor starts NORMAL (m25-b-1) — the `followPlayhead` rationale, not
    /// the `auditionEnabled` one. Maximized is a MODE the user asks for; a
    /// persisted default of "on" would open every existing session with the
    /// arrange collapsed to a ruler strip, which reads as a broken window rather
    /// than as a mode. It is still STICKY once chosen (every dimension here is):
    /// a user who quit maximized reopens maximized, with the toggle lit and
    /// Escape live.
    public static let defaultEditorMaximized = false
    /// The minimap starts SHOWN (m25-b-2) — the `auditionEnabled` rationale, not
    /// the `followPlayhead` one. The user ASKED for this map to exist; shipping it
    /// opt-in would ship it invisible, and a navigator nobody can find is worth
    /// nothing. It costs no layout (it floats over the grid's corner) and it
    /// collapses to a 22×22 chip in that same corner, so the escape hatch is one
    /// click away and in the place the eye is already looking.
    public static let defaultPianoRollMinimap = true

    // MARK: - Clamp ranges
    //
    // These ranges are deliberately CONSERVATIVE (beta m10-d gate): the reachable
    // extremes must not visibly break at the window size the app actually runs at.
    // The track-header row does not fully priority-shrink (fixed-width meter + M/S/A
    // chips). As of m10-j the WINDOW has a measured floor (`WindowFloor`) and the
    // arrange track area SCROLLS as one unit rather than overflowing, so a small
    // window scrolls instead of pushing chrome off-frame — the ranges + the floor +
    // the shared scroll now hold the line together.

    /// Sidebar min = the header row's measured intrinsic floor (headless
    /// `fittingSize`: ~242 pt empty / ~267 pt with a clip-count, name truncated),
    /// tolerance-matched to the proven-clean 260 pt default; max leaves the timeline
    /// room. The soft name (m10-i) + the take-group automation fold (m10-j,
    /// `TrackHeaderLayout`) keep the name readable at this floor without inflating it.
    public static let sidebarWidthRange: ClosedRange<CGFloat> = 250...420
    /// Editor max (0.55) keeps the app header + arrange chrome + transport visible;
    /// it is the WORST case the window's measured height floor (`WindowFloor`, m10-j)
    /// is derived against, so the chrome stays visible at the floor with the editor
    /// open. Min stays comfortably usable.
    public static let editorFractionRange: ClosedRange<CGFloat> = 0.30...0.55
    /// Row height spans a dense multitrack view up to a comfortable large row (this
    /// range was innocent — the earlier tall-editor overflow came from the fraction,
    /// not the row height).
    public static let rowHeightRange: ClosedRange<CGFloat> = 24...64
    /// Arrange zoom bounds (m17-b) — one source of truth in `ArrangeZoom`.
    public static let arrangePPBRange: ClosedRange<CGFloat> = ArrangeZoom.pixelsPerBeatRange
    /// Piano-roll zoom bounds (m21-c) — one source of truth in `PianoRollZoom`.
    public static let pianoRollPPBRange: ClosedRange<CGFloat> = PianoRollZoom.pixelsPerBeatRange
    /// Pitch-editor zoom bounds (m23-ap p2-b) — the SAME range as the roll, from
    /// the SAME home. A second ladder would let the two bottom panes disagree
    /// about what "one step in" means, and `PitchEditorGeometry` already opens at
    /// `PianoRollZoom.defaultPixelsPerBeat` for that reason.
    public static let pitchEditorPPBRange: ClosedRange<CGFloat> = PianoRollZoom.pixelsPerBeatRange
    /// Pitch-row-height bounds (m25-b-4) — one source of truth in `PianoRollZoom`,
    /// where the measured legibility floor and the stated span ceiling are argued.
    public static let pianoRollRowHeightRange: ClosedRange<CGFloat> = PianoRollZoom.rowHeightRange
    /// Pitch-editor row-height bounds (m23-ap C4) — the SAME range as the roll,
    /// from the SAME home, for the reason `pitchEditorPPBRange` shares it: a
    /// second ladder would let the two bottom panes disagree about what "one
    /// step taller" means.
    public static let pitchEditorRowHeightRange: ClosedRange<CGFloat> = PianoRollZoom.rowHeightRange
    /// Waveform vertical-zoom bounds (m25-e) — one source of truth in
    /// `WaveformScale`, the `ArrangeZoom`/`PianoRollZoom` discipline.
    public static let waveformVerticalZoomRange: ClosedRange<CGFloat> = WaveformScale.verticalZoomRange

    // MARK: - Live values (observed)

    public private(set) var sidebarWidth: CGFloat
    public private(set) var editorFraction: CGFloat
    public private(set) var rowHeight: CGFloat
    /// Arrange pixels-per-beat (m17-b) — read by every beat↔x mapping surface in
    /// the arrange workspace (ruler block, lanes, playhead, clip gestures…).
    public private(set) var arrangePPB: CGFloat
    /// Piano-roll pixels-per-beat (m21-c) — the roll's edit models re-read it,
    /// so all three bands (note grid, velocity lane, controller strip) rescale
    /// off the ONE value.
    public private(set) var pianoRollPPB: CGFloat
    /// Pitch-editor pixels-per-beat (m23-ap p2-b) — the second bottom pane's own
    /// horizontal scale, read by `PitchEditorGeometry`. A SEPARATE slot from the
    /// roll's on purpose: the two panes are never on screen at once (design
    /// §3.6), so sharing one value would silently rescale the roll every time a
    /// vocal was inspected.
    public private(set) var pitchEditorPPB: CGFloat
    /// Piano-roll pitch-row height (m25-b-4) — the `pianoRollPPB` sibling on the
    /// other axis. Read by the note grid, the keyboard gutter, the marquee and the
    /// minimap off the ONE value, so they rescale together by construction.
    public private(set) var pianoRollRowHeight: CGFloat
    /// Pitch-editor semitone-row height (m23-ap C4) — read by
    /// `PitchEditorGeometry`, which the surface, the ruler sidebar and the hit
    /// testing all share, so they rescale together by construction.
    public private(set) var pitchEditorRowHeight: CGFloat
    /// Whether the mixer console's INSERTS sections are collapsed (m23-a). ONE
    /// value for the whole console — channel strips, bus strips, and the master
    /// chain all read it, the way density is read per-console and never per-strip.
    public private(set) var mixerInsertsCollapsed: Bool
    /// Whether the arrange lanes and the piano-roll bands keep the playhead in
    /// frame during playback (m23-c2). ONE value for both surfaces — the follow
    /// POLICY is shared, so its switch is too.
    public private(set) var followPlayhead: Bool
    /// Whether a piano-roll drag / keyboard-gutter click sounds the pitch on
    /// the track's instrument (m23-d). ONE value for both audition surfaces.
    public private(set) var auditionEnabled: Bool
    /// Whether audio waveforms are scaled up to fill their block (m25-e). ONE
    /// value for every waveform in the arrange workspace — the clip blocks AND
    /// the take lanes read it, so the two surfaces can never draw the same file
    /// at different scales.
    public private(set) var waveformNormalize: Bool
    /// Extra vertical magnification applied to every audio waveform (m25-e),
    /// on top of the fit. Shares `waveformNormalize`'s one-value-both-surfaces
    /// discipline.
    public private(set) var waveformVerticalZoom: CGFloat
    /// Whether the bottom note editor is MAXIMIZED (m25-b-1) — suspending the
    /// `editorFraction` clamp for as long as the mode is on. Read by the pane's
    /// height expression, by the arrange row's pinned height, and by the roll's
    /// header toggle; written by that toggle and by Escape. `editorFraction` is
    /// untouched throughout, which is what makes the restore land on the user's
    /// own height (see `editorMaximizedKey`).
    public private(set) var editorMaximized: Bool
    /// Whether the piano roll shows its corner viewport minimap (m25-b-2). Read by
    /// the roll's overlay; written by the map's own collapse chip and by the chip
    /// that brings it back.
    public private(set) var pianoRollMinimap: Bool

    @ObservationIgnored private let backing: PanelLayoutBacking

    /// - Parameter backing: the persistence seam. Defaults to an in-memory backing
    ///   (previews / tests / a session that shouldn't persist). Persisted values are
    ///   re-clamped on load, so a corrupt or out-of-range stored number is tamed.
    public init(backing: PanelLayoutBacking? = nil) {
        let backing = backing ?? InMemoryPanelLayoutBacking()
        self.backing = backing
        self.sidebarWidth = Self.loaded(backing, Self.sidebarWidthKey,
                                        default: Self.defaultSidebarWidth, range: Self.sidebarWidthRange)
        self.editorFraction = Self.loaded(backing, Self.editorFractionKey,
                                          default: Self.defaultEditorFraction, range: Self.editorFractionRange)
        self.rowHeight = Self.loaded(backing, Self.rowHeightKey,
                                     default: Self.defaultRowHeight, range: Self.rowHeightRange)
        self.arrangePPB = Self.loaded(backing, Self.arrangePPBKey,
                                      default: Self.defaultArrangePPB, range: Self.arrangePPBRange)
        self.pianoRollPPB = Self.loaded(backing, Self.pianoRollPPBKey,
                                        default: Self.defaultPianoRollPPB, range: Self.pianoRollPPBRange)
        self.pitchEditorPPB = Self.loaded(backing, Self.pitchEditorPPBKey,
                                          default: Self.defaultPitchEditorPPB,
                                          range: Self.pitchEditorPPBRange)
        self.pianoRollRowHeight = Self.loaded(backing, Self.pianoRollRowHeightKey,
                                              default: Self.defaultPianoRollRowHeight,
                                              range: Self.pianoRollRowHeightRange)
        self.pitchEditorRowHeight = Self.loaded(backing, Self.pitchEditorRowHeightKey,
                                                default: Self.defaultPitchEditorRowHeight,
                                                range: Self.pitchEditorRowHeightRange)
        self.mixerInsertsCollapsed = backing.loadValue(forKey: Self.mixerInsertsCollapsedKey)
            .map { $0 != 0 } ?? Self.defaultMixerInsertsCollapsed
        self.followPlayhead = backing.loadValue(forKey: Self.followPlayheadKey)
            .map { $0 != 0 } ?? Self.defaultFollowPlayhead
        self.auditionEnabled = backing.loadValue(forKey: Self.auditionEnabledKey)
            .map { $0 != 0 } ?? Self.defaultAuditionEnabled
        self.waveformNormalize = backing.loadValue(forKey: Self.waveformNormalizeKey)
            .map { $0 != 0 } ?? Self.defaultWaveformNormalize
        self.waveformVerticalZoom = Self.loaded(backing, Self.waveformVerticalZoomKey,
                                                default: Self.defaultWaveformVerticalZoom,
                                                range: Self.waveformVerticalZoomRange)
        self.editorMaximized = backing.loadValue(forKey: Self.editorMaximizedKey)
            .map { $0 != 0 } ?? Self.defaultEditorMaximized
        self.pianoRollMinimap = backing.loadValue(forKey: Self.pianoRollMinimapKey)
            .map { $0 != 0 } ?? Self.defaultPianoRollMinimap
    }

    private static func loaded(_ backing: PanelLayoutBacking, _ key: String,
                               default fallback: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        (backing.loadValue(forKey: key).map { CGFloat($0) } ?? fallback).clamped(to: range)
    }

    // MARK: - Setters (clamp + write-through)

    public func setSidebarWidth(_ value: CGFloat) {
        sidebarWidth = value.clamped(to: Self.sidebarWidthRange)
        backing.storeValue(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
    }

    public func setEditorFraction(_ value: CGFloat) {
        editorFraction = value.clamped(to: Self.editorFractionRange)
        backing.storeValue(Double(editorFraction), forKey: Self.editorFractionKey)
    }

    public func setRowHeight(_ value: CGFloat) {
        rowHeight = value.clamped(to: Self.rowHeightRange)
        backing.storeValue(Double(rowHeight), forKey: Self.rowHeightKey)
    }

    /// Sets the arrange horizontal zoom (m17-b). Clamped like every dimension;
    /// callers that need the no-jump anchor rule go through the AppModel zoom
    /// entry points, which recompute the scroll offset BEFORE writing here.
    public func setArrangePPB(_ value: CGFloat) {
        arrangePPB = value.clamped(to: Self.arrangePPBRange)
        backing.storeValue(Double(arrangePPB), forKey: Self.arrangePPBKey)
    }

    /// Sets the piano-roll horizontal zoom (m21-c). Clamped like every dimension.
    ///
    /// ⭐⭐ **m25-b-3 — THE ANCHOR RULE NOW RIDES ON THIS SLOT, AND THIS COMMENT
    /// USED TO SAY THE OPPOSITE.** It read *"a zoom does not re-pin an anchor beat
    /// under the cursor here, so no offset recompute rides along (unlike
    /// `setArrangePPB`'s callers)"*, and that sentence was the filed evidence for
    /// the defect it described: the roll's content slid out from under the pointer
    /// on every pinch and every ⌘±.
    ///
    /// The recompute is deliberately NOT here — this type is the storage, and it
    /// has no scroll offset, no viewport width and no playhead. It hangs off the
    /// roll's `onChange` of this value (`PianoRollView.repinZoomAnchor`), which is
    /// the one event every driver shares. **The consequence for a caller is the
    /// opposite of the old note: you do not need a special zoom entry point here —
    /// writing this slot from anywhere (including `debug.panelLayout`) gets the
    /// no-jump rule.** `setArrangePPB`'s callers still must route through
    /// `setArrangeZoom`; that asymmetry is real and is explained on the funnel.
    public func setPianoRollPPB(_ value: CGFloat) {
        pianoRollPPB = value.clamped(to: Self.pianoRollPPBRange)
        backing.storeValue(Double(pianoRollPPB), forKey: Self.pianoRollPPBKey)
    }

    /// Sets the PITCH-EDITOR horizontal zoom (m23-ap p2-b). Clamped like every
    /// dimension; write-through like every dimension.
    ///
    /// Drivers: `AppModel.zoomPitchEditorIn/Out/Reset` (⌘+ / ⌘− / ⌘0, routed by
    /// `EditorSurfaceRouter.resolve` — never by a raw
    /// `openPitchEditorClip != nil`) and `debug.panelLayout {pitchEditorPPB}`.
    public func setPitchEditorPPB(_ value: CGFloat) {
        pitchEditorPPB = value.clamped(to: Self.pitchEditorPPBRange)
        backing.storeValue(Double(pitchEditorPPB), forKey: Self.pitchEditorPPBKey)
    }

    /// Sets the PITCH-EDITOR vertical zoom (m23-ap C4) — the semitone-row
    /// height. Clamped like every dimension; write-through like every dimension.
    ///
    /// Drivers: the pane's own zoom cluster and
    /// `debug.panelLayout {pitchEditorRowHeight}`. ⚠️ **NOT the View menu's
    /// Note Row Height items (⌃⌘=/−/0)** — those write
    /// `pianoRollRowHeight` unconditionally, so they still target the ROLL
    /// while this pane is engaged. That is a live routing gap, reported rather
    /// than silently patched here: routing them on `activeEditorSurface` is a
    /// change to `EditorSurfaceRouter`'s tested policy and belongs with it.
    public func setPitchEditorRowHeight(_ value: CGFloat) {
        pitchEditorRowHeight = value.clamped(to: Self.pitchEditorRowHeightRange)
        backing.storeValue(Double(pitchEditorRowHeight), forKey: Self.pitchEditorRowHeightKey)
    }

    /// Sets the piano-roll VERTICAL zoom (m25-b-4) — the pitch-row height.
    /// Clamped like every dimension.
    ///
    /// ⭐ **THE ANCHOR RULE RIDES ON THIS SLOT, NOT ON ITS CALLERS** — the
    /// `setPianoRollPPB` shape, deliberately, one axis over. The recompute is not
    /// here (this type has no scroll offset and no viewport height); it hangs off
    /// the roll's `onChange` of this value (`PianoRollView.repinRowZoomAnchor`),
    /// which is the one event every driver shares. So writing this slot from
    /// anywhere — the View menu's row-height items or `debug.panelLayout
    /// {pianoRollRowHeight}` — gets the no-jump rule, and a driver cannot forget it.
    ///
    /// ⚠️ **`setWaveformVerticalZoom` BELOW IS NOT THE PRECEDENT FOR THIS, AND ITS
    /// DOC SAYS WHY IN WORDS THAT ARE TRUE THERE AND FALSE HERE:** "the vertical
    /// axis has no scroll offset to preserve — the clip block's height never
    /// changes, only what is drawn inside it". The roll's `contentHeight` IS
    /// `pitchCount · rowHeight`, so this zoom changes the scrollable extent and
    /// does need an anchor.
    public func setPianoRollRowHeight(_ value: CGFloat) {
        pianoRollRowHeight = value.clamped(to: Self.pianoRollRowHeightRange)
        backing.storeValue(Double(pianoRollRowHeight), forKey: Self.pianoRollRowHeightKey)
    }

    /// A one-shot request to scroll the piano roll's PITCH axis so `pitch` sits in
    /// the middle of the note grid.
    ///
    /// ⚠️ **DELIBERATELY NOT PERSISTED, and the only slot on this type that is
    /// not.** Every other value here is a remembered dimension; this one is an
    /// EVENT — "put that pitch in frame, now" — and a remembered scroll position
    /// would fight the roll's own anchor rules on the next launch. The
    /// `followTargetX`/`followNonce` idiom is the precedent: the nonce is what
    /// makes a repeat of the SAME pitch still scroll, so a driver can ask twice.
    ///
    /// WHY IT EXISTS: the roll opens anchored near the middle of the 128-row
    /// stack, so a clip written low (a 49 Hz heartbeat at C1, an 808 at F1) opens
    /// on an EMPTY grid — the notes are real, visible in the minimap and in the
    /// velocity lane, and simply below the viewport. Shrinking `pianoRollRowHeight`
    /// does not fix it: measured at the 10 pt floor -- the CLAMP, which is where a
    /// request for 5 lands -- the grid still bottomed out at F2. Auto-centring the roll on its clip's own pitch range when it OPENS is
    /// the product fix (m35-h); this slot is the drivable one underneath it.
    public private(set) var pianoRollFocusPitch: Int?
    public private(set) var pianoRollFocusNonce: Int = 0

    /// Asks the open piano roll to centre its pitch axis on `pitch` (0...127,
    /// clamped). Bumps the nonce so an identical repeat still applies.
    public func requestPianoRollFocus(pitch: Int) {
        pianoRollFocusPitch = pitch.clamped(to: 0...127)
        pianoRollFocusNonce += 1
    }

    /// Collapses or expands the mixer console's INSERTS sections (m23-a). No clamp
    /// to apply — a `Bool` has no out-of-range value — but it write-throughs like
    /// every other dimension, so the disclosure survives relaunch.
    public func setMixerInsertsCollapsed(_ collapsed: Bool) {
        mixerInsertsCollapsed = collapsed
        backing.storeValue(collapsed ? 1 : 0, forKey: Self.mixerInsertsCollapsedKey)
    }

    /// Turns follow-the-playhead on or off (m23-c2). Write-throughs like every
    /// other dimension, so an opted-in session is still following after relaunch.
    public func setFollowPlayhead(_ following: Bool) {
        followPlayhead = following
        backing.storeValue(following ? 1 : 0, forKey: Self.followPlayheadKey)
    }

    /// Turns note audition while editing on or off (m23-d). Write-throughs like
    /// every other dimension, so a user who silenced it stays silenced after
    /// relaunch. The wire verb is NOT gated on this by design.
    public func setAuditionEnabled(_ enabled: Bool) {
        auditionEnabled = enabled
        backing.storeValue(enabled ? 1 : 0, forKey: Self.auditionEnabledKey)
    }

    /// Turns waveform auto-fit on (FIT) or off (RAW) (m25-e). Write-throughs like
    /// every other dimension, so a user who went back to true amplitude is still
    /// there after relaunch.
    public func setWaveformNormalize(_ normalize: Bool) {
        waveformNormalize = normalize
        backing.storeValue(normalize ? 1 : 0, forKey: Self.waveformNormalizeKey)
    }

    /// Sets the waveform vertical zoom (m25-e). Clamped like every dimension, so
    /// the view layer can hand a raw stepper/wire value straight through. No
    /// anchor recompute rides along (unlike `setArrangePPB`): the vertical axis
    /// has no scroll offset to preserve — the clip block's height never changes,
    /// only what is drawn inside it.
    public func setWaveformVerticalZoom(_ zoom: CGFloat) {
        waveformVerticalZoom = zoom.clamped(to: Self.waveformVerticalZoomRange)
        backing.storeValue(Double(waveformVerticalZoom), forKey: Self.waveformVerticalZoomKey)
    }

    /// Maximizes or restores the bottom note editor (m25-b-1). Write-throughs
    /// like every other dimension, so the mode survives relaunch.
    ///
    /// ⚠️ **DELIBERATELY DOES NOT TOUCH `editorFraction`.** That is the whole
    /// restore mechanism: the user's dragged height stays where it is and comes
    /// back untouched when the mode ends. Two callers converge here — the roll's
    /// header toggle and the Escape route — and both SET rather than toggle, so a
    /// double-delivered Escape cannot re-maximize.
    public func setEditorMaximized(_ maximized: Bool) {
        editorMaximized = maximized
        backing.storeValue(maximized ? 1 : 0, forKey: Self.editorMaximizedKey)
    }

    /// Shows or collapses the piano roll's viewport minimap (m25-b-2).
    /// Write-throughs like every other dimension, so a user who dismissed the map
    /// stays dismissed across a clip switch AND across a relaunch — the clip switch
    /// being the one that a view-local flag could not have survived.
    public func setPianoRollMinimap(_ shown: Bool) {
        pianoRollMinimap = shown
        backing.storeValue(shown ? 1 : 0, forKey: Self.pianoRollMinimapKey)
    }

    /// Restores every dimension to its default (and persists the reset).
    public func reset() {
        setSidebarWidth(Self.defaultSidebarWidth)
        setEditorFraction(Self.defaultEditorFraction)
        setRowHeight(Self.defaultRowHeight)
        setArrangePPB(Self.defaultArrangePPB)
        setPianoRollPPB(Self.defaultPianoRollPPB)
        setPitchEditorPPB(Self.defaultPitchEditorPPB)
        setPianoRollRowHeight(Self.defaultPianoRollRowHeight)
        setPitchEditorRowHeight(Self.defaultPitchEditorRowHeight)
        setMixerInsertsCollapsed(Self.defaultMixerInsertsCollapsed)
        setFollowPlayhead(Self.defaultFollowPlayhead)
        setAuditionEnabled(Self.defaultAuditionEnabled)
        setWaveformNormalize(Self.defaultWaveformNormalize)
        setWaveformVerticalZoom(Self.defaultWaveformVerticalZoom)
        setEditorMaximized(Self.defaultEditorMaximized)
        setPianoRollMinimap(Self.defaultPianoRollMinimap)
    }
}

/// A non-persistent in-memory backing — the default for `PanelLayoutStore`, used by
/// previews and tests. Just a dictionary.
@MainActor
public final class InMemoryPanelLayoutBacking: PanelLayoutBacking {
    private var storage: [String: Double]

    public init(_ initial: [String: Double] = [:]) {
        self.storage = initial
    }

    public func loadValue(forKey key: String) -> Double? { storage[key] }
    public func storeValue(_ value: Double, forKey key: String) { storage[key] = value }
}

/// UserDefaults-backed persistence for the app: one key per dimension,
/// `panelLayout.<dimension>`, storing the value as a Double. This makes the layout
/// an app-side sticky preference (survives relaunch) that is NEVER part of the
/// project file. Foundation-only, so it can live here in DAWAppKit.
@MainActor
public final class UserDefaultsPanelLayoutBacking: PanelLayoutBacking {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "panelLayout.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    private func key(_ dimension: String) -> String { keyPrefix + dimension }

    public func loadValue(forKey key: String) -> Double? {
        // `object(forKey:)` distinguishes "never set" (nil) from a stored 0.
        guard defaults.object(forKey: self.key(key)) != nil else { return nil }
        return defaults.double(forKey: self.key(key))
    }

    public func storeValue(_ value: Double, forKey key: String) {
        defaults.set(value, forKey: self.key(key))
    }
}
