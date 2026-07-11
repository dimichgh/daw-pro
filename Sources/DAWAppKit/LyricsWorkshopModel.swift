import Foundation
import AIServices

/// Headless state machine for the Lyrics Workshop (M6): the Anthropic/OpenAI-
/// powered write/refine panel that feeds bracketed-structure lyrics into the AI
/// Sketchpad. No SwiftUI, no network — the view is thin over this and the tests
/// drive it against a scripted fake writer (the `SketchpadModel`/`SettingsModel`
/// precedent: all logic here, capturable and testable without a window).
///
/// v0 keeps a SINGLE current draft (no history): a `write()` replaces it, a
/// `refine()` revises it, and `apply()` hands it to the Sketchpad. Provider
/// selection + the key chain live in AIServices — this model injects a `makeWriter`
/// factory that either yields a configured `LyricsGenerating` or THROWS the
/// actionable no-key error, which surfaces here as `.failed(message)`. It never
/// holds or logs key material.
///
/// Violet is correct here: everything the workshop produces is AI-authored, so the
/// view paints it in `DAWTheme.ai` ("violet always means AI-generated",
/// docs/DESIGN-LANGUAGE.md).
@MainActor
@Observable
public final class LyricsWorkshopModel {
    // MARK: - Composer inputs

    /// What the song is about (the required theme). Empty blocks `write()`.
    public var theme: String = ""

    /// Optional style/genre guidance, e.g. "90s pop-punk".
    public var style: String = ""

    /// Ordered section tags shaping the song. Seeded with the familiar pop
    /// default; the chip row adds/removes/reorders entries.
    public private(set) var structure: [String] = LyricsWriteRequest.defaultStructure

    /// REFINE instruction, e.g. "make the chorus more hopeful". Empty blocks
    /// `refine()`.
    public var refineInstruction: String = ""

    // MARK: - Output

    /// The current bracketed-structure draft (empty until the first write). The
    /// view shows this and `apply()` hands it to the Sketchpad.
    public private(set) var draft: String = ""

    /// Which provider produced the current draft (`AIProviderID.rawValue`), for a
    /// small "written by …" credit. Nil until the first successful write.
    public private(set) var lastProvider: String?

    /// The write/refine lifecycle.
    public enum State: Equatable, Sendable {
        case idle
        case writing
        case failed(String)
    }
    public private(set) var state: State = .idle

    // MARK: - Injected seams

    /// Yields a configured lyrics writer, or THROWS the actionable no-key error.
    /// A factory (not a resolved writer) so the no-provider case can be surfaced
    /// at write time as `.failed`, and so the app can re-resolve against the live
    /// key chain each call. `@MainActor` because the app's implementation reads
    /// the shared key store; the model is `@MainActor` too, so calling it is direct.
    private let makeWriter: @MainActor () throws -> any LyricsGenerating

    /// Supplies the project's musical context (key/tempo/time-signature/genre)
    /// from the store snapshot, read fresh on each write so a tempo change lands.
    private let contextProvider: @MainActor () -> LyricsWriteContext

    /// Hands the finished bracketed lyrics to the Sketchpad (the app sets
    /// `sketchpad.lyrics`). Kept as a closure so DAWAppKit never reaches the store.
    private let applier: @MainActor (String) -> Void

    public init(
        makeWriter: @escaping @MainActor () throws -> any LyricsGenerating,
        contextProvider: @escaping @MainActor () -> LyricsWriteContext = { LyricsWriteContext() },
        applier: @escaping @MainActor (String) -> Void
    ) {
        self.makeWriter = makeWriter
        self.contextProvider = contextProvider
        self.applier = applier
    }

    // MARK: - Structure chips

    /// Appends a section tag (bare name, e.g. "verse"). No-op for a blank tag.
    public func addSection(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        structure.append(trimmed)
    }

    /// Removes the tag at `index` (bounds-checked).
    public func removeSection(at index: Int) {
        guard structure.indices.contains(index) else { return }
        structure.remove(at: index)
    }

    /// Moves the tag at `from` to `to` (both bounds-checked; a no-op otherwise).
    public func moveSection(from: Int, to: Int) {
        guard structure.indices.contains(from), from != to else { return }
        let clampedTo = min(max(0, to), structure.count - 1)
        let tag = structure.remove(at: from)
        structure.insert(tag, at: clampedTo)
    }

    /// Restores the default pop structure.
    public func resetStructure() {
        structure = LyricsWriteRequest.defaultStructure
    }

    // MARK: - Gating

    private var trimmedTheme: String { theme.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True while a write/refine is in flight — the view dims the buttons.
    public var isBusy: Bool { state == .writing }

    /// A write needs a non-blank theme and no in-flight request.
    public var canWrite: Bool { !trimmedTheme.isEmpty && !isBusy }

    /// A refine needs an existing draft, a non-blank instruction, and idleness.
    public var canRefine: Bool {
        !draft.isEmpty
            && !refineInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isBusy
    }

    /// True once there's a draft to push into the Sketchpad.
    public var canApply: Bool { !draft.isEmpty }

    // MARK: - Write / refine

    /// Writes a fresh draft from theme/style/structure + the live project context.
    /// A blank theme or an in-flight request is a no-op; any error (including the
    /// no-provider case) lands as `.failed(message)`.
    public func write() async {
        guard canWrite else { return }
        await run(buildRequest(refine: false))
    }

    /// Refines the current draft with `refineInstruction` (REFINE mode). A no-op
    /// unless `canRefine`.
    public func refine() async {
        guard canRefine else { return }
        await run(buildRequest(refine: true))
    }

    private func run(_ request: LyricsWriteRequest) async {
        state = .writing
        do {
            let writer = try makeWriter()
            let result = try await writer.writeLyrics(request)
            draft = result.lyrics
            lastProvider = result.provider
            state = .idle
        } catch {
            state = .failed(Self.message(from: error))
        }
    }

    private func buildRequest(refine: Bool) -> LyricsWriteRequest {
        LyricsWriteRequest(
            prompt: trimmedTheme,
            style: style.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            structure: structure,
            context: contextProvider(),
            existingLyrics: refine ? draft : nil,
            instruction: refine ? refineInstruction.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
    }

    // MARK: - Apply

    /// Hands the current draft to the Sketchpad lyrics editor (via the injected
    /// applier). No-op when there's no draft.
    public func apply() {
        guard canApply else { return }
        applier(draft)
    }

    // MARK: - Capture seeding (debug only)

    /// Stages a draft (and its provider credit) directly, for a capture that can't
    /// reach a written state over the wire (the `SketchpadModel.setCandidatesForCapture`
    /// precedent). Debug/capture use only.
    public func setDraftForCapture(_ lyrics: String, provider: String?) {
        draft = lyrics
        lastProvider = provider
        state = .idle
    }

    /// Sets the structure chips directly, for a capture seed.
    public func setStructureForCapture(_ tags: [String]) {
        structure = tags
    }

    static func message(from error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "\(error)"
    }
}

private extension String {
    /// Nil when the string is empty (after the caller has trimmed it) — keeps an
    /// empty style field out of the request as a true absence.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
