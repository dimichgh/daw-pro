import DAWCore

/// p2-ren Stage B″(c) — the note editor's **"Preview" caption** (design
/// `docs/design/2026-09-25-incremental-note-render.md`, Stage B″): what the pitch
/// editor's status line says while the clip it is open on plays a quick PREVIEW
/// of the latest change instead of the exact render.
///
/// ⭐ **ONE STATE SHOWS IT, AND ONLY ONE.** `ClipRenderAudible.preview` is Stage
/// B's provisional splice — a stand-in the exact render replaces on its own. The
/// others are not previews and are said elsewhere or not at all:
///  - `.exact` is the normal case: nothing to say;
///  - `.previous` (Stage A's bridge: the clip plays how it sounded BEFORE the
///    change) and `.silent` (nothing to stand in with) are already said by the
///    engine's notices and the clip's shimmer, which keeps meaning "rendering";
///    calling either one a "preview" would name a sound that is not playing;
///  - `nil` is an engine that cannot say (headless, a preview canvas).
///
/// The words follow the engine's `clip-render-preview` notice ("playing a quick
/// preview … the exact version replaces it in a moment") so the two never
/// disagree about what a preview is. The DECISION lives here, headless, so it is
/// tested without a view; the pane draws the string verbatim.
public enum PitchEditorRenderCaption {
    /// The caption, word for word.
    public static let previewText = "Playing a quick preview. The exact version replaces it in a moment."

    /// The caption for a clip's render state, or `nil` when there is nothing to
    /// say — every state but `.preview`.
    public static func text(for audible: ClipRenderAudible?) -> String? {
        audible == .preview ? previewText : nil
    }

    /// How often the app asks the engine while the pane is open. A PICK: a
    /// preview lasts until the exact render lands (hundreds of milliseconds to
    /// seconds), so a quarter second shows it promptly, and each ask is one
    /// dictionary walk over the graph's tracks on the main actor — the same call
    /// `project.snapshot` makes per tuned clip.
    public static let pollInterval: Duration = .milliseconds(250)
}
