import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

/// The two density modes every panel carries (docs/DESIGN-LANGUAGE.md "Panels").
/// Simple is the default: add / move / delete on a Beat grid, nothing else.
/// Pro adds the velocity lane, snap picker, and resize handles.
enum PianoRollMode: String, CaseIterable {
    case simple
    case pro
    var label: String { self == .simple ? "Simple" : "Pro" }
}

/// Bottom piano-roll editor panel for a MIDI clip. Thin over `PianoRollModel`:
/// all geometry + edits live there, this draws the grid/notes (Canvas) and
/// routes gestures. Every edit mutates the model draft; the draft is submitted
/// through `onCommit` on gesture END only (never per tick).
struct PianoRollView: View {
    /// The clip being edited (value input — previewable without the store).
    var clip: Clip
    var beatsPerBar: Int
    /// Submits the whole note array (wired to `ProjectStore.setClipNotes`).
    var onCommit: ([MIDINote]) -> Void
    var onClose: () -> Void

    @State private var model: PianoRollModel
    @State private var mode: PianoRollMode = .simple
    @State private var snap: SnapResolution = .beat
    @State private var activeDrag: ActiveDrag = .none
    @State private var didMove = false
    @FocusState private var isFocused: Bool

    private static let keyboardWidth: CGFloat = 54

    init(clip: Clip, beatsPerBar: Int,
         onCommit: @escaping ([MIDINote]) -> Void, onClose: @escaping () -> Void) {
        self.clip = clip
        self.beatsPerBar = beatsPerBar
        self.onCommit = onCommit
        self.onClose = onClose
        _model = State(initialValue: PianoRollModel(
            notes: clip.notes ?? [],
            clipLengthBeats: clip.lengthBeats
        ))
    }

    /// Simple mode locks snapping to whole beats; Pro honors the picker.
    private var effectiveSnap: SnapResolution { mode == .simple ? .beat : snap }

    /// Violet whenever the clip is AI-touched, else playback cyan.
    private var noteColor: Color { clip.isAIGenerated ? DAWTheme.ai : DAWTheme.playback }

    private enum ActiveDrag: Equatable {
        case none
        case click(UUID?)     // shift-click or empty — resolved on drag end
        case move
        case resize(UUID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DAWTheme.hairline)
            editor
            if mode == .pro {
                Divider().overlay(DAWTheme.hairline)
                velocitySection
            }
        }
        .glassPanel()
        .focusable()
        .focused($isFocused)
        .onKeyPress(.delete) {
            guard !model.selection.isEmpty else { return .ignored }
            model.deleteSelection()
            commit()
            return .handled
        }
        .onAppear { isFocused = true }
    }

    private func commit() { onCommit(model.buildSubmission()) }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "pianokeys")
                .font(.system(size: 12))
                .foregroundStyle(noteColor)
            Text(clip.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.textPrimary)
                .lineLimit(1)
            if clip.isAIGenerated {
                Text("AI")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(DAWTheme.ai)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(DAWTheme.ai.opacity(0.6), lineWidth: 1))
            }

            Spacer()

            modeToggle
            if mode == .pro { snapPicker }
            closeButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Simple / Pro segmented chip (docs/DESIGN-LANGUAGE.md density modes).
    private var modeToggle: some View {
        HStack(spacing: 0) {
            ForEach(PianoRollMode.allCases, id: \.self) { candidate in
                let isOn = mode == candidate
                Button {
                    mode = candidate
                } label: {
                    Text(candidate.label.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(isOn ? DAWTheme.playback : DAWTheme.textDim)
                        .frame(height: 20)
                        .padding(.horizontal, 9)
                        .background(isOn ? DAWTheme.playback.opacity(0.18) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        .help("Simple: add, move, delete on a beat grid. Pro: velocity, snap, resize.")
    }

    /// Themed snap menu (Pro only) — styled like the input-device picker chip,
    /// never a stock gray control (docs/DESIGN-LANGUAGE.md rule 2).
    private var snapPicker: some View {
        Menu {
            ForEach(SnapResolution.allCases, id: \.self) { resolution in
                Button {
                    snap = resolution
                } label: {
                    if snap == resolution {
                        Label(resolution.label, systemImage: "checkmark")
                    } else {
                        Text(resolution.label)
                    }
                }
            }
        } label: {
            Text("SNAP: \(snap.label)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Grid snap resolution")
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: 22, height: 22)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Close piano roll")
    }

    // MARK: - Editor (keyboard + grid), vertically scrolled together

    private var editor: some View {
        ScrollView(.vertical, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                KeyboardSidebar(model: model, width: Self.keyboardWidth)
                ScrollView(.horizontal, showsIndicators: true) {
                    grid
                        .frame(width: model.contentWidth, height: model.contentHeight)
                        .gesture(gridDrag)
                        .simultaneousGesture(
                            SpatialTapGesture(count: 2).onEnded { value in
                                let note = model.addNote(
                                    atBeat: model.beat(forX: value.location.x),
                                    pitch: model.pitch(forY: value.location.y),
                                    resolution: effectiveSnap
                                )
                                model.selectOnly(note.id)
                                commit()
                            }
                        )
                }
            }
        }
        .defaultScrollAnchor(.center)   // open near middle C, full 0-127 scrollable
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        Canvas { context, size in
            drawBlackKeyRows(&context, size: size)
            drawGridLines(&context, size: size)
            drawOutOfClipShade(&context, size: size)
            drawNotes(&context)
        }
    }

    private func drawBlackKeyRows(_ context: inout GraphicsContext, size: CGSize) {
        for pitch in 0..<PianoRollModel.pitchCount where KeyboardSidebar.isBlackKey(pitch) {
            let y = model.y(forPitch: pitch)
            context.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: model.rowHeight)),
                with: .color(Color.black.opacity(0.22))
            )
        }
        // Octave separators.
        for pitch in stride(from: 0, through: PianoRollModel.pitchCount - 1, by: 12) {
            let y = model.y(forPitch: pitch)
            context.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                with: .color(Color.white.opacity(0.10))
            )
        }
    }

    private func drawGridLines(_ context: inout GraphicsContext, size: CGSize) {
        let beatsShown = Int((size.width / model.pixelsPerBeat).rounded(.up))
        let step = effectiveSnap.beats ?? 1
        var beat = 0.0
        while beat <= Double(beatsShown) + 0.0001 {
            let x = model.x(forBeat: beat)
            let isBar = beat.truncatingRemainder(dividingBy: Double(beatsPerBar)).magnitude < 0.001
            let isBeat = beat.truncatingRemainder(dividingBy: 1).magnitude < 0.001
            let color = isBar
                ? Color.white.opacity(0.16)
                : (isBeat ? DAWTheme.hairline : DAWTheme.hairline.opacity(0.5))
            context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(color))
            beat += step
        }
    }

    private func drawOutOfClipShade(_ context: inout GraphicsContext, size: CGSize) {
        let clipX = model.x(forBeat: model.clipLengthBeats)
        guard clipX < size.width else { return }
        context.fill(
            Path(CGRect(x: clipX, y: 0, width: size.width - clipX, height: size.height)),
            with: .color(Color.black.opacity(0.28))
        )
    }

    private func drawNotes(_ context: inout GraphicsContext) {
        for note in model.draft {
            let rect = model.rect(for: note).insetBy(dx: 0.5, dy: 1.5)
            let selected = model.isSelected(note.id)
            let velocity = Double(note.velocity) / 127
            let opacity = 0.45 + 0.5 * velocity
            let path = Path(roundedRect: rect, cornerRadius: 3)
            if selected {
                // Subtle bloom behind a selected note.
                context.fill(
                    Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4),
                    with: .color(noteColor.opacity(0.28))
                )
            }
            context.fill(path, with: .color(noteColor.opacity(selected ? min(1, opacity + 0.2) : opacity)))
            context.stroke(
                path,
                with: .color(selected ? DAWTheme.textPrimary.opacity(0.9) : noteColor.opacity(0.9)),
                lineWidth: selected ? 1 : 0.5
            )
        }
    }

    // MARK: - Grid gesture (move / resize / click-select)

    private var gridDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if activeDrag == .none {
                    beginGesture(at: value.startLocation)
                    didMove = false
                }
                applyGesture(value)
            }
            .onEnded { value in
                endGesture(value)
            }
    }

    private func beginGesture(at start: CGPoint) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        let hit = model.hitTest(start)
        if let hit, !shift, hit.zone == .resizeHandle, mode == .pro {
            if !model.isSelected(hit.id) { model.selectOnly(hit.id) }
            activeDrag = .resize(hit.id)
        } else if let hit, !shift {
            if !model.isSelected(hit.id) { model.selectOnly(hit.id) }
            model.beginMove()
            activeDrag = .move
        } else {
            activeDrag = .click(hit?.id)
        }
    }

    private func applyGesture(_ value: DragGesture.Value) {
        switch activeDrag {
        case .move:
            let deltaBeats = model.beat(forX: value.translation.width)
            let deltaPitch = -Int((value.translation.height / model.rowHeight).rounded())
            model.moveSelection(deltaBeats: deltaBeats, deltaPitch: deltaPitch, resolution: effectiveSnap)
            if abs(value.translation.width) > 3 || abs(value.translation.height) > 3 { didMove = true }
        case .resize(let id):
            model.resizeNote(id: id, toEndBeat: model.beat(forX: value.location.x), resolution: effectiveSnap)
            if abs(value.translation.width) > 3 { didMove = true }
        case .click, .none:
            break
        }
    }

    private func endGesture(_ value: DragGesture.Value) {
        switch activeDrag {
        case .move, .resize:
            if didMove { commit() }   // else it was a plain click; selection already set
        case .click(let id):
            let shift = NSEvent.modifierFlags.contains(.shift)
            if let id {
                if shift { model.toggle(id) } else { model.selectOnly(id) }
            } else if !shift {
                model.clearSelection()
            }
        case .none:
            break
        }
        activeDrag = .none
        didMove = false
    }

    // MARK: - Velocity lane (Pro)

    private var velocitySection: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("VEL")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: Self.keyboardWidth, height: VelocityLane.height, alignment: .center)
            ScrollView(.horizontal, showsIndicators: false) {
                VelocityLane(model: model, noteColor: noteColor, onCommit: commit)
                    .frame(width: model.contentWidth)
            }
        }
        .frame(height: VelocityLane.height)
    }
}
