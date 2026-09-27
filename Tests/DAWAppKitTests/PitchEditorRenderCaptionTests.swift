import Testing
import DAWCore
@testable import DAWAppKit

/// p2-ren Stage B″(c) — the note editor's "Preview" caption decides ONE thing:
/// it shows exactly while the clip plays a quick PREVIEW of the latest change
/// (`ClipRenderAudible.preview`), and never for the exact render, the previous
/// version, silence, or an engine that cannot say.
///
/// Nonisolated value logic, so a plain suite (no `@MainActor` slot is spent).
struct PitchEditorRenderCaptionTests {

    @Test("B″(c) — the caption shows for .preview ONLY: hidden for .exact, .previous, .silent and nil; every state is swept, so a new case must be decided here")
    func showsOnlyForAPreview() {
        for state in [ClipRenderAudible.exact, .preview, .previous, .silent] {
            let text = PitchEditorRenderCaption.text(for: state)
            switch state {
            case .preview:
                #expect(text == PitchEditorRenderCaption.previewText)
            case .exact, .previous, .silent:
                #expect(text == nil, "\(state) drew \"\(text ?? "")\": it is not a preview")
            }
        }
        #expect(PitchEditorRenderCaption.text(for: nil) == nil, "an engine that cannot say says nothing")
    }

    @Test("B″(c) — the words: short, a beginner's, in the engine notice's own vocabulary (a quick preview; the exact version replaces it), with no jargon")
    func theWords() {
        let text = PitchEditorRenderCaption.previewText
        #expect(text == "Playing a quick preview. The exact version replaces it in a moment.")
        #expect(text.count <= 80, "the status line is one row")
        for jargon in ["render", "provisional", "splice", "cache", "bridge"] {
            #expect(!text.lowercased().contains(jargon), "\"\(jargon)\" is not a beginner's word")
        }
    }

    @Test("B″(c) — the poll runs at no more than 4 Hz")
    func thePollIsLight() {
        #expect(PitchEditorRenderCaption.pollInterval >= .milliseconds(250))
    }
}
