import Foundation
import Testing

/// m39-tpl-8 — the template picker's WIRING in `DAWApp`, which has no test
/// target: so these read the source (comment-stripped), the
/// `EscapeKeyMonitorSiteTests` method. They pin the four things a refactor could
/// drop silently:
///
/// 1. the card is a LISTED modal (`isModalPresented`) — else ⌫ and the arrows
///    reach the clips behind its scrim (m34-k);
/// 2. it is mounted (`pickerOverlays`) and opened by its three doors;
/// 3. the Sketchpad button no longer starts a pop song under a `try?`;
/// 4. NO `try?` anywhere on the picker's path, and no violet (§9.3, §9.4).
@Suite("m39-tpl-8: the template picker's wiring in DAWApp (source reads)")
struct TemplatePickerSiteTests {

    static func sourcesDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources", isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Sources from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    /// A source file with every comment stripped (a `try?` in a comment is not a `try?`).
    static func code(_ relativePath: String) -> String {
        let url = sourcesDir().appendingPathComponent(relativePath)
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            Issue.record("Could not read \(relativePath): \(error)")
            return ""
        }
        return content.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { return "" }
            return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    /// The inside of the first braced block opening at or after `marker`.
    static func block(after marker: String, in code: String) -> String? {
        guard let start = code.range(of: marker),
              let open = code[start.lowerBound...].firstIndex(of: "{") else { return nil }
        var depth = 1
        var out = ""
        var index = code.index(after: open)
        while index < code.endIndex {
            let ch = code[index]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return out }
            }
            out.append(ch)
            index = code.index(after: index)
        }
        return nil
    }

    /// Every file on the picker's path: the headless half and the views.
    static let pickerFiles = [
        "DAWAppKit/TemplatePickerCopy.swift",
        "DAWAppKit/TemplatePickerLayout.swift",
        "DAWAppKit/TemplatePickerState.swift",
        "DAWAppKit/TemplatePickerModel.swift",
        "DAWApp/TemplatePicker/TemplatePickerCard.swift",
        "DAWApp/TemplatePicker/TemplatePickerSaveSheet.swift",
        "DAWApp/TemplatePicker/TemplatePickerMount.swift",
    ]

    @Test("the picker is a LISTED modal: `isModalPresented` names it, so ⌫ and the arrows cannot reach the clips behind its scrim")
    func pickerIsAListedModal() throws {
        let app = Self.code("DAWApp/DAWProApp.swift")
        #expect(app.count > 100_000, "POSITIVE CONTROL: DAWProApp.swift came back short (\(app.count))")
        let modal = try #require(Self.block(after: "var isModalPresented: Bool {", in: app))
        #expect(modal.contains("tuneToMelodyDoor.card != nil"), "POSITIVE CONTROL: the block reader found the list")
        #expect(modal.contains("templatePicker.isOpen"))
    }

    @Test("it is mounted in pickerOverlays, and its three doors open it: the Sketchpad button, the add-track menu, a track's menu")
    func mountedAndOpened() throws {
        let content = Self.code("DAWApp/ContentView.swift")
        let overlays = try #require(Self.block(after: "private var pickerOverlays: some View {", in: content))
        #expect(overlays.contains("TuneToMelodyCardMount(model: model)"), "POSITIVE CONTROL")
        #expect(overlays.contains("TemplatePickerCardMount(model: model)"))

        let sketchpad = Self.code("DAWApp/Sketchpad/SketchpadView.swift")
        let button = try #require(Self.block(after: "private var templateButton: some View {", in: sketchpad))
        #expect(button.contains("app.openTemplatePicker()"))
        #expect(!button.contains("applySongSkeleton"), "the Sketchpad must open the picker, not start a song itself")
        #expect(!button.contains("try?"))

        let trackList = Self.code("DAWApp/TrackListView.swift")
        let addMenu = try #require(Self.block(after: "struct AddTrackMenu<ChipLabel: View>: View {", in: trackList))
        #expect(addMenu.contains("store.addTrack(kind: .bus)"), "POSITIVE CONTROL: the reader reached the menu")
        #expect(addMenu.contains("TemplatePickerCopy.addBandMenuItem"))
        #expect(addMenu.contains("app.openTemplatePicker()"))
        #expect(trackList.contains("case .saveAsTemplate:"))
        #expect(trackList.contains("model.openSaveTrackAsTemplate(trackID: track.id)"))
    }

    /// `try?` as a WORD: a bare substring search also matches `selectedEntry?`
    /// (en-TRY-?), which is how the first draft of this test went red on clean code.
    static var tryQuestion: NSRegularExpression { regex(#"\btry\?"#) }
    static var tryWord: NSRegularExpression { regex(#"\btry\b"#) }

    static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            Issue.record("bad pattern \(pattern): \(error)")
            return NSRegularExpression()
        }
    }

    static func count(_ regex: NSRegularExpression, in text: String) -> Int {
        regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    @Test("the `try?` matcher sees a real one and ignores look-alikes (positive and negative control)")
    func tryMatcherControls() {
        #expect(Self.count(Self.tryQuestion, in: "let x = try? store.applyTemplate(t)") == 1)
        #expect(Self.count(Self.tryQuestion, in: "guard let e = state.selectedEntry?.id else { }") == 0)
        #expect(Self.count(Self.tryWord, in: "let r = try store.applyTemplate(t)") == 1)
    }

    @Test("NO `try?` anywhere on the picker's path, and no violet: a refusal reaches the card in the store's words, and a scaffold is not AI")
    func noTryQuestionAndNoViolet() {
        var seenTry = 0
        for path in Self.pickerFiles {
            let text = Self.code(path)
            #expect(text.count > 500, "POSITIVE CONTROL: \(path) came back short (\(text.count))")
            seenTry += Self.count(Self.tryWord, in: text)
            #expect(Self.count(Self.tryQuestion, in: text) == 0, "\(path) swallows an error with `try?`")
            #expect(!text.contains("DAWTheme.ai"), "\(path) uses the AI violet")
        }
        #expect(seenTry > 5, "POSITIVE CONTROL: the reader saw the path's real `try` calls (\(seenTry))")
    }
}
