import SwiftUI
import UniformTypeIdentifiers
import AIServices
import DAWAppKit

/// Dragging a voice model onto a track header — the m24-m **leg C** affordance,
/// and the user's own original sketch for this feature (2026-08-13: *"drag a
/// trained voice model onto it"*).
///
/// ⭐⭐ **A SECOND ENTRY POINT, NOT A SECOND FLOW.** A drop calls
/// `AppModel.performVoiceModelDrop`, which calls `openVoiceConvert(clipIDs:…)` —
/// the SAME funnel the arrange clip's context menu and Edit ▸ Convert go
/// through, opening the SAME panel over the SAME `ProjectStore.convertClipsToVoice`
/// store seam (leg A). Nothing here converts anything. If dragging a voice onto
/// a track produced a different result from selecting that track's clips and
/// using Edit ▸ Convert, that would be a bug, not a feature.
///
/// ⭐ **WHY THIS ROUTE EXISTS AT ALL when two already do.** The clip context
/// menu is **Pro-only** (sp-c) and Edit ▸ Convert needs a selection the user has
/// to know to make. This route is the only one that is *discoverable*: the
/// voices are visible in the Voice panel, tracks are visible beside them, and
/// the gesture between them is the one every DAW teaches. It also works in
/// **Simple** density, where the context-menu route does not exist — so it is
/// the beginner's route, which is exactly what Rule 6 asks for.

// MARK: - The payload

extension UTType {
    /// The drag type for a voice model, owned by this app.
    ///
    /// ⚠️ **A PRIVATE TYPE RATHER THAN `.text`, AND THAT IS LOAD-BEARING.** The
    /// arrange lanes already own a `.fileURL` drop (`AudioLaneDropDelegate`) and
    /// the track list already owns a row-reorder `DragGesture`. A voice drag
    /// carrying a plain string would be claimable by any text well in the app,
    /// and a Finder file would be claimable by a track header. With a type only
    /// this app vends, the two drags cannot see each other — the "two rules that
    /// can disagree" failure is removed structurally instead of being tested for.
    static let dawProVoiceModel = UTType(exportedAs: "com.dawpro.voice-model")
}

/// What a dragged voice model carries: its id (the only thing the conversion
/// needs) and its name (so a future drag preview can say it without a second
/// lookup).
///
/// **A value, not a reference** — a drop handler must not reach back into a
/// panel that may have refreshed its voice list mid-drag.
struct VoiceModelDragPayload: Codable, Transferable, Sendable, Equatable {
    var voiceID: String
    var voiceName: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .dawProVoiceModel)
    }
}

// MARK: - The drop affordance

/// The chip a track header shows while a voice model hovers it — the visible
/// half of the drop target.
///
/// ⭐ **THE DROP MUST BE VISIBLY A DROP TARGET** (docs/DESIGN-LANGUAGE.md): an
/// invisible hit region is indistinguishable from a broken one, and this
/// gesture crosses the whole window, so the moment the row answers is the only
/// feedback the user gets before committing.
///
/// **Ink, and both halves are earned by state (Rule 3):**
///  - **Accepting → VIOLET + the glow recipe.** A voice model is AI identity and
///    the drop produces a violet AI track, so violet is the honest token here as
///    it is on the VOICE chip and the panel's picked row. ⚠️ It must not be
///    confused with an **AI track at rest**, which already wears a violet card
///    stroke: that one is `ai.opacity(0.35)` and has **no glow**, while this is
///    a full-strength stroke UNDER a bloom. Static chrome never glows, so a
///    glowing row can only mean "right now, this".
///  - **Refusing → AMBER, no glow.** `DAWTheme.record` is this app's refusal
///    register (`ArrangeRefusalBubble`, `deleteBarBlockedReason`), and nothing
///    is being invited, so nothing blooms.
///
/// Plain value inputs, so a preview and the live row share one implementation.
struct VoiceModelDropChip: View {
    var verdict: VoiceConvertDropVerdict

    /// The accept chip's words. **SF Mono, because it is a COUNT** — the house
    /// split (mono for numeric readouts, SF Pro for prose) applied inside one
    /// control, which is why the refusal beside it is not mono.
    static func acceptText(clipCount: Int) -> String {
        "CONVERT \(clipCount) CLIP\(clipCount == 1 ? "" : "S")"
    }

    var body: some View {
        switch verdict {
        case .accepts(let command):
            Text(Self.acceptText(clipCount: command.clipIDs.count))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(DAWTheme.ai)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7).padding(.vertical, 3)
                // ⚠️⚠️ **OPAQUE BASE UNDER THE TINT, AND THIS WAS A MEASURED
                // BUG.** It shipped as a bare `ai.opacity(0.16)` fill, which is
                // TRANSLUCENT — and this chip floats over the row's M / S / R
                // buttons. A capture (m24m-8-drop-accept.png) showed the letters
                // reading straight through it: "CONVERTM3 CLIPB". Every probe
                // assertion was green; only the pixels said anything. The
                // refusal chip beside it was correct by accident, because
                // `panelRaised` is opaque — so the fix is to give this one the
                // same floor and lay the violet tint ON it, which is also what
                // `trackClickAckBubble` does (a darker chip on a raised row
                // reads as a hole; a raised chip reads as a layer).
                .background(DAWTheme.ai.opacity(0.18).background(DAWTheme.panelRaised))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(DAWTheme.ai.opacity(0.75), lineWidth: 1))
                .glow(DAWTheme.ai, radius: 5, intensity: 0.7)
                // The same cast shadow the ack bubble uses: it is what makes a
                // chip read as floating OVER the controls rather than as part of
                // the row, which matters most exactly where it occludes them.
                .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                .padding(.trailing, 8)
                .allowsHitTesting(false)
        case .refuses(let reason):
            Text(reason)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(DAWTheme.record)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(DAWTheme.record.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                .padding(.trailing, 8)
                .allowsHitTesting(false)
        }
    }
}

/// The card treatment for a hovered track: the stroke colour and the bloom.
///
/// A `struct` of two plain values rather than two `if`s at the call site, so the
/// row's existing stroke expression (dragging → cyan, AI → violet-dim, else
/// hairline) grows exactly ONE term and the drop states stay describable in one
/// place.
struct VoiceModelDropInk {
    var stroke: Color
    var glowIntensity: Double

    static func ink(for verdict: VoiceConvertDropVerdict) -> VoiceModelDropInk {
        switch verdict {
        case .accepts: VoiceModelDropInk(stroke: DAWTheme.ai.opacity(0.9), glowIntensity: 0.55)
        case .refuses: VoiceModelDropInk(stroke: DAWTheme.record.opacity(0.75), glowIntensity: 0)
        }
    }
}

/// One track header's live answer to a voice model hovering over it: WHICH row,
/// and WHAT it says.
///
/// The id and the verdict travel together (the `ClipDeleteCommand` law applied
/// to a hover) so the chip drawn on a row and the decision the drop takes are
/// the same value — "lit up violet, then swallowed the drop" is not
/// representable.
struct VoiceModelDropHover: Equatable {
    var trackID: UUID
    var verdict: VoiceConvertDropVerdict
}
