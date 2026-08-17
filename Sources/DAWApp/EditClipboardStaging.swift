import Foundation
import DAWControl
import DAWCore
import DAWAppKit

// The `debug.editClipboard` handler for the m23-ek-3 clipboard, in the
// `ArrangeMarqueeStaging` / `PianoRollMarqueeStaging` tradition: the seam drives
// the SAME `AppModel.performMenuCopy/Cut/Paste` the menu buttons call, and
// echoes the resolved MENU ITEMS beside the result — so the seam cannot drift
// from the menu, and every `refusedBy` branch is assertable without a
// screenshot.
//
// ⚠️ IT SPANS BOTH SURFACES, so it lives at the top level of `Sources/DAWApp`
// rather than under `PianoRoll/` — the clipboard's clip half has nothing to do
// with the roll.
//
// ⚠️ IT LIVES IN AN `extension AppModel` IN ITS OWN FILE — the m23-cq-1
// deviation, for its reason: `DAWProApp.swift` is 9 000+ lines and a standing
// merge magnet, so the footprint there is one dispatch line.
//
// ⚠️⚠️ COPY/CUT STILL HAVE ZERO WIRE GROWTH, AND THAT HALF OF THE ARGUMENT
// STILL HOLDS. `edit.copy` / `edit.cut` HAVE NO DOMAIN EFFECT AT ALL — copy
// mutates nothing, and putting either on the wire means putting APP CLIPBOARD
// STATE on the wire, the same category `debug.arrangeMarquee` rejects for
// selection ("the selection is UI state"). Neither exists as a control command
// today and this file's reasoning for that is unchanged.
//
// ⚠️⚠️ **PASTE'S HALF WAS OVERTURNED, BY USER RULING (2026-08-17) — DO NOT
// RE-LITIGATE IT.** This comment used to argue `edit.paste` "would have to
// read that app-tier clipboard, so it cannot be a headless `DAWControl` verb;
// it would route through `appCommandHandler` … a debug command wearing a
// badge." That objection is answered, not overridden: `edit.pasteClips`
// (m26-k) does NOT route through `appCommandHandler` — it routes through a
// TYPED seam, `EditPasteControlling` (`Sources/DAWControl/EditPasteSurface.swift`),
// the exact `plugin.*` precedent this file's own sibling command family
// (`PluginUISurface.swift`) already used for an app-tier capability that is on
// `allCommands` with a real MCP tool. A typed seam with its own
// `rejectUnknownKeys` site is not `appCommandHandler`'s untyped debug switch,
// so the "debug command wearing a badge" objection does not apply to it.
// `AppModel.pasteClipsFromClipboard(intoTrack:)` is still this seam's ONE
// HOME (unchanged); `edit.pasteClips` is a new WIRE ROUTE to it, not a new
// operation, and it does not touch `performMenuCopy/Cut/Paste` or this file's
// `debug.editClipboard` handler.
//
// AND THE HONEST AUDIT STILL SAYS AGENTS LOSE NOTHING BEYOND CLIP PASTE.
// Notes remain reachable through `clip.setNotes`/`clip.getNotes` (read the
// clip's current array, merge a transposed copy, write the whole array back —
// one call, one undo step) — there is still no `edit.pasteNotes` wire verb,
// and `edit.pasteClips` returns a named `wrongPayloadKind` outcome (never a
// bare `false`) precisely so an agent whose clipboard holds notes is told to
// use that pair instead of guessing why nothing landed. The ONLY remaining
// gap is ATOMIC multi-clip duplication, whose honest form is one
// `clip.duplicateBatch` verb — still a user decision to be filed with its own
// evidence if a real workflow needs it, not a wire verb over the clipboard.
//
// Counts: see `docs/ARCHITECTURE.md`'s "Wire surface — CURRENT TOTALS" table,
// the one to trust — this file does not re-state them (that is exactly the
// prose-headline rot the constitution warns about elsewhere).

extension AppModel {

    /// Spins the main runloop, BOUNDED, until a staged clipboard request has been
    /// THROUGH the roll and landed — the m23-e echo-seam law.
    ///
    /// ⚠️ WHY A WAIT IS NEEDED AT ALL. The ARRANGE half of every verb runs
    /// synchronously inside `performMenuCopy/Cut/Paste`. The NOTE half cannot:
    /// `PianoRollModel` is `@State private`, so the request crosses into the roll
    /// as a nonce and is applied on SwiftUI's next body pass. Echoing without
    /// waiting would answer with the PRE-request clipboard on every note
    /// operation — and a stale echo does not merely fail a gate, it poisons every
    /// diagnosis made through it.
    ///
    /// WAITS ON THE RIGHT SIGNAL PER VERB, deliberately, rather than on one
    /// convenient counter:
    ///   • copy / cut — `EditClipboard.seq`, which bumps only when the roll
    ///     actually PUT something. A cut the store refused never bumps it, so the
    ///     wait expires and the echo honestly shows an unchanged clipboard.
    ///   • paste — the store's `lastEditEvent.seq`, because a paste's observable
    ///     product is a JOURNALED EDIT, not a clipboard write (the clipboard is
    ///     unchanged by a paste — decision 4, the anchor does not advance).
    ///
    /// Bounded twice over: it stops the instant the signal moves, and hard-stops
    /// at the deadline when nothing is there to move it (no roll mounted, a
    /// refused operation, an empty selection).
    func awaitClipboardApplied(verb: ClipboardVerb, clipboardSeqBefore: Int,
                               editSeqBefore: Int?) {
        let deadline = Date().addingTimeInterval(0.30)
        while Date() < deadline {
            switch verb {
            case .copy, .cut:
                if clipboard.seq != clipboardSeqBefore { return }
            case .paste:
                if store.lastEditEvent?.seq != editSeqBefore { return }
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// `debug.editClipboard {act?}` — the m23-ek-3 clipboard seam. App-level,
    /// debug tier ONLY (off `allCommands`, off MCP, off the Copilot catalog).
    ///
    ///   - `{}` — READ-ONLY (the m11-a bare-read law). Answers what the clipboard
    ///     holds AND how all three menu items currently resolve, so a caller can
    ///     assert that Paste went live the instant a Copy landed without taking a
    ///     screenshot.
    ///   - `{act:"copy"|"cut"|"paste"}` — drives the SAME
    ///     `performMenuCopy/Cut/Paste` the menu buttons call (the
    ///     `debug.arrangeSelection {act:"delete"}` precedent), so the seam cannot
    ///     drift from the menu.
    ///
    /// ⚠️⚠️ NO LEG BUILT ON THIS MAY DEPEND ON A REAL KEY EVENT. There are no
    /// ⌘C/⌘X/⌘V key equivalents in v1 (the user's ruling), and an unbundled
    /// staging binary would not route them anyway (the m23-g1 law) — a leg that
    /// tried would pass or fail for reasons unrelated to this code.
    ///
    /// THE ECHO IS GROUND TRUTH: `kind`/`clipCount`/`noteCount`/`seq` come off
    /// the live `EditClipboard`, the `menu` block off the same three `AppModel`
    /// properties `EditCommands` renders, and `pastedClipIds` off the live
    /// selection after the paste — never off this function's own input.
    func editClipboardDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        var lastResult: Bool?
        var lastVerb: ClipboardVerb?
        if let act = params["act"]?.stringValue {
            guard let verb = ClipboardVerb(rawValue: act) else {
                // Teaching-error shape (m23-cy): name the valid values rather
                // than reporting a bare rejection.
                throw DebugError(
                    "unknown act \"\(act)\" — expected \"copy\", \"cut\" or \"paste\"")
            }
            // The clipboard only acts in the arrange workspace (its policy's
            // first guard), so putting the workspace right mirrors
            // `debug.pianoRollMarquee`. OPENING a clip or making a selection is
            // deliberately NOT done here — those are
            // `debug.arrangeSelection`'s job, and a seam that silently did them
            // would be staging two gestures per call.
            workspaceMode = .arrange
            let clipboardSeqBefore = clipboard.seq
            let editSeqBefore = store.lastEditEvent?.seq
            switch verb {
            case .copy: lastResult = performMenuCopy()
            case .cut: lastResult = performMenuCut()
            case .paste: lastResult = performMenuPaste()
            }
            lastVerb = verb
            awaitClipboardApplied(verb: verb, clipboardSeqBefore: clipboardSeqBefore,
                                  editSeqBefore: editSeqBefore)
        }

        var object: [String: JSONValue] = [:]
        object["kind"] = clipboard.kind.map { .string($0.rawValue) } ?? .null
        object["clipCount"] = .number(Double(clipboard.clipCount))
        object["noteCount"] = .number(Double(clipboard.noteCount))
        object["seq"] = .number(Double(clipboard.seq))
        // THE MENU BLOCK is what makes every `refusedBy` branch gate-able. Read
        // from the very properties `EditCommands` renders, so a leg asserting
        // "Paste is greyed because no roll is open" is asserting about the menu
        // the user sees.
        let describe: (ClipboardMenuItem) -> JSONValue = { item in
            .object([
                "title": .string(item.title),
                "enabled": .bool(item.isEnabled),
                "surface": item.surface.map { .string($0.rawValue) } ?? .null,
                "refusedBy": item.refusedBy.map { .string($0.rawValue) } ?? .null,
            ])
        }
        object["menu"] = .object([
            "copy": describe(copyMenuItem),
            "cut": describe(cutMenuItem),
            "paste": describe(pasteMenuItem),
        ])
        // THE KEYSTROKE ROUTE'S RAW WIRING (m25-f-1), so the one thing about
        // ⌘X/⌘C/⌘V that IS machine-observable can be observed: whether the
        // responder exists, whether it sits in the content window's chain, and
        // what AppKit resolves `copy:` to right now.
        //
        // ⚠️⚠️ RAW FACTS, NEVER A VERDICT, AND NEVER A GATE ASSERTION ON ITS OWN.
        // A keystroke is still invisible to every gate in this tree; and on a
        // staging binary the content window is frequently not key, where
        // `NSApp.target(forAction:)` answers nil for reasons that have nothing to
        // do with this code. A leg that read `targetForCopy == null` as "broken"
        // would be measuring the harness.
        object["responder"] = clipboardResponderFacts
        // The CONTEXT a red leg needs to read as a sentence rather than a
        // mystery: which workspace, whether a roll is open, how many tracks, and
        // where the playhead — the anchor every paste is resolved against.
        object["workspaceMode"] = .string(workspaceMode.rawValue)
        object["rollOpen"] = .bool(openEditorClip != nil)
        object["editorClipId"] = openEditorClip.map { .string($0.id.uuidString) } ?? .null
        object["trackCount"] = .number(Double(store.tracks.count))
        object["playheadBeat"] = .number(store.transport.positionBeats)
        object["result"] = lastResult.map { .bool($0) } ?? .null
        object["act"] = lastVerb.map { .string($0.rawValue) } ?? .null
        // The ARRANGE SELECTION after the fact — which, after a clip paste, IS
        // the set of pasted clips (`pasteClipsFromClipboard` selects them). The
        // ids are read back off the model rather than remembered from the paste,
        // so a leg proving "the pasted clips are selected" is proving it about
        // the live selection.
        object["selectedClipIds"] =
            .array(arrangeSelection.ids.map(\.uuidString).sorted().map { .string($0) })
        object["focusClipId"] = arrangeSelection.focusID.map { .string($0.uuidString) } ?? .null
        // m25-l-1 — WHERE THE PASTE WAS AIMED. `activeTrackId` is the RESOLVED
        // value `pasteClipsFromClipboard` actually hands to `PasteAnchorPolicy`,
        // read off the same `AppModel.activeTrack` resolution, so a leg asserting
        // a landing can name the intended target instead of inferring it from
        // where the clips ended up (which is the thing under test).
        //
        // ⚠️ Exactly the same value while `pasteClipsFromClipboard(intoTrack:)`
        // is nil, which every shipped caller is. When m25-f-4 starts passing a
        // per-gesture destination, that paste's target will NOT be this field —
        // the menu item will have to echo its own.
        //
        // ⭐⭐ **m25-l-3 REVERSED WHAT THIS FIELD MEANS FOR A LEG, BY USER RULING
        // (2026-08-13).** The note here used to read: *"A LEG MUST NOT EXPECT
        // THIS TO STEER AN ORDINARY PASTE … a leg that copies from a live track
        // and expects the active track to win is measuring its own premise."*
        // That is now backwards — such a leg is measuring the fix. A copy from a
        // LIVE track pasted after a HEADER CLICK lands on the clicked track.
        // What still does not steer is an INFERRED destination (no header click;
        // the field merely names the focused clip's owner), which is why
        // `activeTrackOrigin` is echoed beside it: a leg cannot tell the two
        // cases apart from the id, and they now have different outcomes.
        object["activeTrackId"] = activeTrackID.map { .string($0.uuidString) } ?? .null
        object["activeTrackOrigin"] =
            activeTrack.map { .string($0.origin.rawValue) } ?? .null
        object["explicitActiveTrackId"] =
            explicitActiveTrackID.map { .string($0.uuidString) } ?? .null
        // Every clip in the project, with its track and beat — so a leg can
        // DERIVE the expected landing from the echoed playhead and then check it,
        // instead of hardcoding beats the fixture cannot know.
        object["clips"] = .array(store.tracks.enumerated().flatMap { index, track in
            track.clips.map { clip in
                JSONValue.object([
                    "id": .string(clip.id.uuidString),
                    "name": .string(clip.name),
                    "trackId": .string(track.id.uuidString),
                    "trackIndex": .number(Double(index)),
                    "startBeat": .number(clip.startBeat),
                    "lengthBeats": .number(clip.lengthBeats),
                    "isMIDI": .bool(clip.isMIDI),
                    "noteCount": .number(Double(clip.notes?.count ?? 0)),
                ])
            }
        })
        // The open clip's NOTES, so a note round-trip can be checked for
        // content-equality rather than for a count.
        object["editorNotes"] = .array((openEditorClip?.notes ?? []).map { note in
            .object([
                "id": .string(note.id.uuidString),
                "pitch": .number(Double(note.pitch)),
                "velocity": .number(Double(note.velocity)),
                "startBeat": .number(note.startBeat),
                "lengthBeats": .number(note.lengthBeats),
            ])
        })
        // The undo stack's labels, newest first — so "one paste = ONE undo step"
        // is checkable here without a second command.
        object["undoLabels"] = .array(store.undoHistory().undo.map { JSONValue.string($0) })
        return .object(object)
    }
}
