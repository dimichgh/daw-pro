import SwiftUI
import DAWAppKit

/// The WRITE-WITH-AI Lyrics Workshop (M6), embedded in the Sketchpad panel above
/// the lyrics editor as a disclosure. Theme + style fields, an editable structure
/// chip row, WRITE / REFINE with a busy state, an error strip, and APPLY (pushes
/// the finished bracketed draft into the Sketchpad's lyrics editor).
///
/// VIOLET IS CORRECT HERE: every word this produces is AI-authored, so the whole
/// workshop carries `DAWTheme.ai` ("violet always means AI-generated",
/// docs/DESIGN-LANGUAGE.md). All state + transitions live in the headless
/// `LyricsWorkshopModel` (Sources/DAWAppKit); this view is thin over it.
struct LyricsWorkshopView: View {
    @Bindable var model: LyricsWorkshopModel
    /// Disclosure state, hoisted onto AppModel so the debug capture commands and
    /// the live window share it.
    @Binding var expanded: Bool

    /// The quick-add section tags (mirrors the Sketchpad's own insert row).
    private let quickTags = ["verse", "chorus", "bridge", "outro"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            disclosureHeader
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    themeField
                    styleField
                    structureEditor
                    writeRow
                    if case .failed(let message) = model.state { errorStrip(message) }
                    if model.canApply { draftFooter }
                }
                .padding(.top, 10)
            }
        }
        .padding(10)
        .background(DAWTheme.ai.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DAWTheme.ai.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Header

    private var disclosureHeader: some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DAWTheme.ai)
                Text("WRITE WITH AI")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.6)
                    .foregroundStyle(DAWTheme.textPrimary)
                Spacer()
                if let provider = model.lastProvider, !model.draft.isEmpty {
                    Text("via \(provider)")
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(DAWTheme.ai.opacity(0.8))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .buttonStyle(.plain)
        .help("Write or refine lyrics with AI, tied to the project key/tempo")
    }

    // MARK: - Fields

    private var themeField: some View {
        VStack(alignment: .leading, spacing: 4) {
            label("THEME")
            miniEditor(text: $model.theme, height: 38,
                       placeholder: "what the song is about — e.g. a long drive home")
        }
    }

    private var styleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            label("STYLE")
            miniEditor(text: $model.style, height: 30,
                       placeholder: "optional — e.g. 90s pop-punk, slow R&B")
        }
    }

    // MARK: - Structure editor

    private var structureEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                label("STRUCTURE")
                Spacer()
                Button { model.resetStructure() } label: {
                    Text("RESET")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(DAWTheme.textDim)
                }
                .buttonStyle(.plain)
                .help("Reset to the default song structure")
            }
            // Current section chips, each removable.
            FlowChips(tags: Array(model.structure.enumerated())) { index, tag in
                sectionChip(tag) { model.removeSection(at: index) }
            }
            // Quick-add row.
            HStack(spacing: 6) {
                ForEach(quickTags, id: \.self) { tag in
                    Button { model.addSection(tag) } label: {
                        Text("+ \(tag)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(DAWTheme.ai)
                            .padding(.horizontal, 7).padding(.vertical, 2.5)
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .stroke(DAWTheme.ai.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Add a \(tag) section")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func sectionChip(_ tag: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(DAWTheme.textPrimary)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Remove this section")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(DAWTheme.ai.opacity(0.12))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(DAWTheme.ai.opacity(0.35), lineWidth: 1))
    }

    // MARK: - Write / refine

    private var writeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { Task { await model.write() } } label: {
                HStack(spacing: 6) {
                    if model.isBusy {
                        ProgressView().controlSize(.small).tint(.black)
                        Text("WRITING…")
                    } else {
                        Image(systemName: "pencil.and.scribble")
                        Text(model.canApply ? "REWRITE" : "WRITE")
                    }
                }
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(model.canWrite ? Color.black : DAWTheme.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(model.canWrite ? DAWTheme.ai : DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .glow(model.canWrite ? DAWTheme.ai : .clear, radius: 6, intensity: 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!model.canWrite)

            // Refine appears once there's a draft to work on.
            if model.canApply {
                HStack(spacing: 6) {
                    miniEditor(text: $model.refineInstruction, height: 30,
                               placeholder: "refine — e.g. make the chorus more hopeful")
                    Button { Task { await model.refine() } } label: {
                        Text("REFINE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(model.canRefine ? DAWTheme.ai : DAWTheme.textDim)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke((model.canRefine ? DAWTheme.ai : DAWTheme.textDim).opacity(0.6),
                                        lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canRefine)
                    .help("Revise the current draft with the instruction")
                }
            }
        }
    }

    private var draftFooter: some View {
        HStack(spacing: 8) {
            Text("Draft ready")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(DAWTheme.textDim)
            Spacer()
            Button { model.apply() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.doc")
                    Text("APPLY TO LYRICS")
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Color.black)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(DAWTheme.ai)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .glow(DAWTheme.ai, radius: 5, intensity: 0.5)
            }
            .buttonStyle(.plain)
            .help("Send the draft into the Sketchpad's lyrics editor")
        }
    }

    private func errorStrip(_ message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.clip)
            Text(message)
                .font(.system(size: 9.5))
                .foregroundStyle(DAWTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(DAWTheme.clip.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.clip.opacity(0.35), lineWidth: 1))
    }

    // MARK: - Reusable bits

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(DAWTheme.textDim)
    }

    private func miniEditor(text: Binding<String>, height: CGFloat, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DAWTheme.textFaint)
                    .padding(.horizontal, 7).padding(.vertical, 7)
                    .allowsHitTesting(false)
            }
            TextEditor(text: text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(DAWTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 3).padding(.vertical, 3)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(DAWTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
    }
}

/// A minimal wrapping chip row — lays the section chips out left-to-right and
/// wraps to the next line when they run past the width. Generic over an indexed
/// tag list so the Structure editor can remove by index.
private struct FlowChips: View {
    let tags: [(offset: Int, element: String)]
    let chip: (Int, String) -> AnyView

    init<Chip: View>(tags: [(offset: Int, element: String)], @ViewBuilder chip: @escaping (Int, String) -> Chip) {
        self.tags = tags
        self.chip = { AnyView(chip($0, $1)) }
    }

    var body: some View {
        // A simple fixed-column flow: SwiftUI's Layout would be heavier than
        // needed here; the chip count is small (a handful of sections).
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(tags, id: \.offset) { item in
                chip(item.offset, item.element)
            }
        }
    }
}

/// Tiny flow layout: places subviews left-to-right, wrapping on overflow.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x - bounds.minX + size.width > maxWidth, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
