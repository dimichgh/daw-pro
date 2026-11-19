import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import AIServices
import DAWCore
import DAWControl
import DAWAppKit

// p2-sing-f — where the Sing screens meet the app: the doors that open them, the recorder's registration with
// the router, the player for guides and recordings, the `debug.singScreens` seam, and the mount
// `ContentView.pickerOverlays` places (the `TemplatePickerCardMount` shape: one line there, everything here).
//
// Every press inside a card is a DAWAppKit model method making the call its wire verb makes (design §6, §13 "One
// command surface"): `ProjectStore.setClipLyrics` / `transposeProject`, `SingJobCoordinator.submit` / `cancel`,
// `SingConsentBroker.approve` / `decline`, `SingVoicePreparation.prepare`.

/// `sing.openVoiceRecorder` reaches the recorder through this (`CommandRouter.singVoiceRecorder`, held weakly;
/// AppModel lives as long as the app). Opening is all an agent can do: only the person presses Record (§5.4).
extension AppModel: SingVoiceRecorderPresenting {
    func openVoiceRecorder(fromAgent: Bool) throws {
        singRecorder.open(fromAgent: fromAgent)
    }
}

extension AppModel {
    /// The clip context menu's "Sing these notes…" and the piano roll's SING chip (§5.1).
    func openSingSheet(clipID: UUID) {
        Task { await singSheet.open(clipID: clipID) }
    }

    func closeSingSheet() { singSheet.close() }

    func closeVoiceRecorder() { singRecorder.close() }

    /// A take was accepted (the sheet's [Sing it], the results card's [Try another take]): onto the unified
    /// progress card as SING (or AGENT for an agent's), and onto the results card.
    func singTakeAccepted(_ status: SingJobStatus, _ request: SingJobRequest) {
        generationPresence.registerSubmission(
            jobID: status.jobID, origin: .forSingJob(fromAgent: request.fromAgent),
            label: SingPresenceBridge.label(voiceName: request.voice.name), state: .running)
        singTakes.track(status, request: request)
    }

    /// §5.6 [▶ Play from here]: the transport's own seek and play, from the take's first beat.
    func playSungTake(trackID: UUID, clipID: UUID) throws {
        guard let clip = store.tracks.first(where: { $0.id == trackID })?.clips.first(where: { $0.id == clipID })
        else { throw SingMountError.takeGone }
        if store.transport.isPlaying { store.stop() }
        try store.seek(toBeats: clip.startBeat)
        store.play()
    }

    /// §5.4 "Use a recording you already have… [Choose file]".
    func chooseVoiceRecordingFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = SingCopy.chooseFile
        guard panel.runModal() == .OK, let url = panel.url else { return }
        singRecorder.useExistingRecording(url)
    }

    /// The four cards' wiring, called once at the tail of `init` (`wireSing()` in DAWProApp.swift holds the two
    /// router/broker lines that need `private` state).
    func wireSingCards() {
        singSheet.onNeedsInstall = { [weak self] in await self?.singConsent.ask(.installEngine) }
        singSheet.onSubmitted = { [weak self] status, request in self?.singTakeAccepted(status, request) }
        singSheet.onAddVoice = { [weak self] in self?.singRecorder.open(fromAgent: false) }
        singTakes.onSubmitted = { [weak self] status, request in self?.singTakeAccepted(status, request) }
        singTakes.onChooseVoice = { [weak self] clipID in self?.openSingSheet(clipID: clipID) }
        singTakes.onPlayFrom = { [weak self] trackID, clipID in try self?.playSungTake(trackID: trackID, clipID: clipID) }
        // p2-sing-x8, §14 "After a styled take": is the melody clip styled (its stored style, normalised)?
        singTakes.styleProbe = { [weak self] clipID in
            guard let clip = self?.store.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clipID }) else { return false }
            return SingTakeModel.styleIsHeard(clip.singStyle)
        }
        singRecorder.onSaved = { [weak self] record in
            guard let self, self.singSheet.isOpen else { return }
            Task { await self.singSheet.reloadVoices(selecting: record.id) }
        }
    }
}

enum SingMountError: Error, LocalizedError {
    case takeGone
    var errorDescription: String? {
        switch self {
        case .takeGone: return "That take is no longer in the song."   // PROVISIONAL
        }
    }
}

/// Plays one guide or recording at a time, OFF the audio engine (the `SketchpadPreview` precedent), and says why
/// when it cannot (the precedent swallowed that).
@MainActor
final class SingAudioPreviewPlayer: NSObject, SingAudioPreviewing, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var onFinish: (@MainActor () -> Void)?

    func play(_ url: URL, onFinish: @escaping @MainActor () -> Void) throws {
        stop()
        let next = try AVAudioPlayer(contentsOf: url)
        next.delegate = self
        guard next.play() else { throw SingAudioStartError(name: url.lastPathComponent) }
        player = next
        self.onFinish = onFinish
    }

    func stop() {
        player?.stop()
        player = nil
        onFinish = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            let finish = self.onFinish
            self.player = nil
            self.onFinish = nil
            finish?()
        }
    }
}

struct SingAudioStartError: Error, LocalizedError {
    var name: String
    var errorDescription: String? { "“\(name)” would not start playing." }   // PROVISIONAL
}

/// The four Sing cards, drawn from AppModel. Always present in `pickerOverlays`, drawing nothing while closed. The
/// recorder is declared after the sheet (it opens over it: "Add your voice…"), and the consent card last (an
/// agent's request can arrive over anything).
struct SingCardMount: View {
    let model: AppModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if model.singTakes.isVisible {
                    SingTakeCardView(model: model.singTakes)
                        .padding(.leading, 24)
                        .padding(.bottom, 84)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .transition(.opacity)
                }
                // A card UNDER another (the sheet under the recorder or the consent card, the recorder under the
                // consent card) is disabled: each card's ✕ carries the `.cancelAction` key equivalent, and two live
                // ones would let Escape close the card underneath. Escape belongs to whatever is on top (m34-k).
                if model.singSheet.isOpen {
                    SingSheetView(model: model.singSheet, windowHeight: Double(geo.size.height),
                                  onClose: { withAnimation(.easeOut(duration: 0.15)) { model.closeSingSheet() } })
                        .disabled(model.singRecorder.isOpen || model.singConsent.isOpen)
                }
                if model.singRecorder.isOpen {
                    SingVoiceRecorderView(
                        model: model.singRecorder,
                        onChooseFile: { model.chooseVoiceRecordingFile() },
                        onClose: { withAnimation(.easeOut(duration: 0.15)) { model.closeVoiceRecorder() } })
                        .disabled(model.singConsent.isOpen)
                }
                if model.singConsent.isOpen {
                    SingConsentCardView(model: model.singConsent)
                }
            }
        }
        // The results card's poll: from acceptance until the checks finish (the model owns every transition).
        .task(id: model.singTakes.status?.jobID) {
            while model.singTakes.needsPolling {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                await model.singTakes.poll()
            }
        }
    }
}

// MARK: - debug.singScreens (app tier, off `allCommands` and MCP)

extension AppModel {
    /// Opens or stages each Sing screen headlessly for the p2-sing-f dogfood, and echoes every screen's words.
    ///
    /// - `{screen: "sheet", clipId}`: the real sheet on that clip.
    /// - `{screen: "consent", action: "install"|"uninstall", fromAgent}`: a PREVIEW card that is NOT in the
    ///   broker, so its [Install] is refused by the broker and can never download.
    /// - `{screen: "recorder", step, elapsed?, level?}`: the recorder staged at a step, nothing capturing.
    /// - `{screen: "take", phase, notes?, words?}`: the results card with a staged status.
    /// - `{screen: "sheetState", …}` (p2-sing-x8): stages the OPEN sheet's expansion states, each optional:
    ///   `text`, `language` ("en"/"zh"/"yue"), `noteWord` (a note index: the note field opens over it),
    ///   `expression` (true: the card opens), `selectNotes` ([note indexes] picked for the card), `parts`
    ///   (["thirdAbove","sixthBelow","thirdBelow","chordNotes"]), `perNote` (the wordless mode), `writeWords`
    ///   (true: the theme field opens), `playheadBeat` (clip beats: the glow with nothing playing; null clears).
    ///   Every one goes through the model method the person's click calls (a language or wordless pick WRITES to
    ///   the open project, like the click: use a test project).
    /// - `{close: true}`: closes all four. No params: the echo only.
    func singScreensDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if params["close"]?.boolValue == true {
            singSheet.close()
            singRecorder.close()
            if singConsent.isOpen { singConsent.dismiss() }
            singTakes.dismiss()
        }
        switch params["screen"]?.stringValue {
        case nil:
            break
        case "sheet"?:
            guard let raw = params["clipId"]?.stringValue, let id = UUID(uuidString: raw) else {
                throw DebugError("debug.singScreens {screen:\"sheet\"} needs clipId")
            }
            openSingSheet(clipID: id)
        case "consent"?:
            let action: SingConsentAction = params["action"]?.stringValue == "uninstall" ? .uninstallEngine : .installEngine
            let fromAgent = params["fromAgent"]?.boolValue ?? false
            singConsent.stagePreview(SingConsentRequest(
                id: "consent-preview", action: action, fromAgent: fromAgent, requestedAt: Date(),
                message: SingConsentBroker.message(for: action, fromAgent: fromAgent)))
        case "recorder"?:
            let step = try Self.recorderStep(params)
            if !singRecorder.isOpen { singRecorder.open(fromAgent: false) }
            singRecorder.stageForCapture(step, elapsed: params["elapsed"]?.doubleValue ?? 0,
                                         levelDbfs: params["level"]?.doubleValue)
        case "take"?:
            try stageTake(params)
        case "sheetState"?:
            try stageSheetState(params)
        case let other?:
            throw DebugError("debug.singScreens: unknown screen \"\(other)\" (sheet, sheetState, consent, recorder, take)")
        }
        return singScreensEcho()
    }

    private static func recorderStep(_ params: [String: JSONValue]) throws -> SingVoiceRecorderModel.Step {
        switch params["step"]?.stringValue ?? "choose" {
        case "choose": return .choose
        case "askingPermission": return .askingPermission
        case "permissionDenied": return .permissionDenied
        case "listening": return .listening
        case "ready": return .ready
        case "recording": return .recording
        case "checking": return .checking
        case "passed": return .passed
        case "failed": return .failed(params["sentence"]?.stringValue ?? SingCopy.recordingStopped)
        case "saving": return .saving
        case "saved":
            return .saved(VoiceRangeFit.voiceSavedSentence(VoiceRange(p10Midi: 40.5, medianMidi: 44, p90Midi: 53)))
        case let other:
            throw DebugError("debug.singScreens: unknown recorder step \"\(other)\"")
        }
    }

    /// `{screen: "sheetState"}`: the open sheet's p2-sing-x8 states, through the click's own model methods.
    private func stageSheetState(_ params: [String: JSONValue]) throws {
        let sheet = singSheet
        guard sheet.isOpen else {
            throw DebugError("debug.singScreens {screen:\"sheetState\"} needs the sheet open ({screen:\"sheet\", clipId})")
        }
        func note(_ index: Int) throws -> UUID {
            guard sheet.preview.notes.indices.contains(index) else {
                throw DebugError("debug.singScreens: note index \(index) is not in the strip (0..<\(sheet.preview.notes.count))")
            }
            return sheet.preview.notes[index].id
        }
        if let text = params["text"]?.stringValue { sheet.setText(text) }
        if let code = params["language"]?.stringValue { sheet.setLanguage(code) }
        if let perNote = params["perNote"]?.boolValue { sheet.setWordlessPerNote(perNote) }
        if params["writeWords"]?.boolValue == true { sheet.openWriteWords() }
        if let open = params["expression"]?.boolValue, open != sheet.expression.isExpanded {
            sheet.expression.toggleExpanded()
        }
        if let picks = params["selectNotes"]?.arrayValue {
            if !sheet.expression.isExpanded { sheet.expression.toggleExpanded() }
            sheet.expression.clearSelection()
            for pick in picks {
                guard let n = pick.doubleValue else { continue }
                sheet.expression.toggleNote(try note(Int(n)))
            }
        }
        if let names = params["parts"]?.arrayValue {
            for name in names.compactMap(\.stringValue) {
                switch name {
                case "thirdAbove": sheet.addHarmony(.thirdAbove)
                case "sixthBelow": sheet.addHarmony(.sixthBelow)
                case "thirdBelow": sheet.addHarmony(.thirdBelow)
                case "chordNotes": sheet.addHarmony(.chordNotes)
                default: throw DebugError("debug.singScreens: unknown part \"\(name)\" (thirdAbove, sixthBelow, thirdBelow, chordNotes)")
                }
            }
        }
        if let index = params["noteWord"]?.doubleValue {
            if sheet.expression.isExpanded { sheet.expression.toggleExpanded() }
            sheet.beginNoteWord(noteID: try note(Int(index)))
        }
        if let raw = params["playheadBeat"] {
            sheet.stagePlayhead(clipBeat: raw.doubleValue)
        }
    }

    private func stageTake(_ params: [String: JSONValue]) throws {
        let phaseName = params["phase"]?.stringValue ?? "done"
        guard let phase = SingJobPhase(rawValue: phaseName) else {
            throw DebugError("debug.singScreens: unknown take phase \"\(phaseName)\"")
        }
        let inTune = params["notes"]?.stringValue != "off"
        let notes = SungNoteAccuracy(hitRate: inTune ? 0.95 : 0.6, meanAbsErrorCents: inTune ? 12 : 48,
                                     voicedCoverage: 0.9, inTune: inTune, offBars: inTune ? [] : [3, 5])
        let verdict = params["words"]?.stringValue ?? SingWordCheck.Verdict.clear
        let words = SungWordCheck(state: SungWordCheck.State.checked, wer: 0.1, heard: nil, verdict: verdict)
        let landed = phase.hasLanded
        let status = try SingStaging.status(
            phase: phase, stageText: params["stageText"]?.stringValue ?? SingJobCoordinator.Copy.landed,
            unitIndex: phase == .singing ? 3 : nil, unitCount: 8, progress: phase == .singing ? 0.4 : 1,
            etaSeconds: phase == .singing ? 65 : nil,
            landedTrackID: landed ? UUID() : nil, landedClipID: landed ? UUID() : nil,
            noteAccuracy: phase == .done ? notes : nil, wordCheck: phase == .done ? words : nil)
        singTakes.stageForCapture(status, request: nil)
    }

    private func singScreensEcho() -> JSONValue {
        func strings(_ list: [String]) -> JSONValue { .array(list.map(JSONValue.string)) }
        func optional(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
        let sheet = singSheet
        let height = sheet.height
        let consentText = singConsent.cardText
        let row = singTakes.row
        return .object([
            "sheet": .object([
                "open": .bool(sheet.isOpen),
                "clipId": optional(sheet.clipID?.uuidString),
                "text": .string(sheet.text),
                "chips": strings(sheet.preview.chips.map(\.text)),
                "warnings": strings(sheet.preview.warnings),
                "refusal": optional(sheet.preview.refusal ?? sheet.refusal),
                "voices": strings(sheet.voices.map(\.name)),
                "voice": .string(sheet.selectedVoice.name),
                "height": height.map { line in
                    .object(["sentence": .string(line.sentence), "move": optional(line.moveTitle),
                             "keep": optional(line.keepTitle), "suggestion": optional(line.suggestion),
                             "octaveShift": .number(Double(line.octaveShift))])
                } ?? .null,
                "transposePreview": optional(sheet.transposeReview?.sentence),
                "canSing": .bool(sheet.canSing),
                "singItDisabledReason": optional(sheet.singItDisabledReason),
                // p2-sing-x8
                "language": .string(sheet.languageTitle),
                "languages": strings(SingCopy.languageCodes.map(SingCopy.languageName)),
                "noteWord": sheet.noteWord.map { field in
                    .object(["noteId": .string(field.noteID.uuidString), "draft": .string(field.draft),
                             "placeholder": .string(SingCopy.noteWordPlaceholder),
                             "hint": .string(SingCopy.noteWordHint), "refusal": optional(field.refusal),
                             "canCommit": .bool(field.canCommit)])
                } ?? .null,
                "playingChip": sheet.playingChipID.map { .number(Double($0)) } ?? .null,
                "derivations": .number(Double(sheet.derivationCount)),
                "wordless": .object(["offered": .bool(sheet.wordlessOffered), "perNote": .bool(sheet.wordlessPerNote),
                                     "lead": .string(SingCopy.wordlessLead)]),
                "writeWords": .object(["offered": .bool(sheet.canWriteWords), "open": .bool(sheet.writeWords.isOpen),
                                       "writing": .bool(sheet.writeWords.isWriting),
                                       "notice": optional(sheet.writeWords.notice),
                                       "disabledReason": optional(sheet.writeWordsDisabledReason)]),
                "expression": .object([
                    "open": .bool(sheet.expression.isExpanded), "summary": .string(sheet.expression.summary),
                    "selection": optional(sheet.expression.selectionLine),
                    "vibrato": optional(sheet.expression.vibrato.map(SingCopy.vibratoName)),
                    "air": sheet.expression.air.map(JSONValue.number) ?? .null,
                    "followsVelocity": .bool(sheet.expression.followsVelocity),
                    "followDisabledReason": optional(sheet.expression.followDisabledReason),
                    "styledNotes": .number(Double(sheet.expression.notesWithOwnSetting.count)),
                    "refusal": optional(sheet.expression.refusal),
                ]),
                "harmony": .object([
                    "choices": strings(sheet.harmonyChoices.map(\.title)),
                    "otherMelodies": strings(sheet.otherMelodies.map(\.title)),
                    "key": optional(sheet.harmonyKey.line),
                    "addDisabledReason": optional(sheet.addHarmonyDisabledReason),
                    "parts": .array(sheet.harmonyRows.map { row in
                        .object(["name": .string(row.name), "voice": .string(row.voiceName),
                                 "range": optional(row.rangeLine), "fits": .bool(row.fits),
                                 "refusal": optional(row.refusal)])
                    }),
                ]),
            ]),
            "consent": .object([
                "open": .bool(singConsent.isOpen),
                "phase": .string(String(describing: singConsent.phase)),
                "preview": .bool(singConsent.isPreview),
                "body": optional(consentText?.body),
                "agentLine": optional(consentText?.agentLine),
                "primary": optional(consentText?.primary),
                "secondary": optional(consentText?.secondary),
                "error": optional(singConsent.errorText),
            ]),
            "recorder": .object([
                "open": .bool(singRecorder.isOpen),
                "step": .string(String(describing: singRecorder.step)),
                "notice": optional(singRecorder.notice),
                "projectRecordRefusal": optional(singRecorder.projectRecordRefusal),
            ]),
            "take": .object([
                "visible": .bool(singTakes.isVisible),
                "stage": optional(row?.stage),
                "resultLine": optional(row?.resultLine),
                "tone": optional(row?.tone.rawValue),
                "cancelTitle": optional(row?.cancelTitle),
                "eta": optional(row?.eta),
                "tip": .bool(singTakes.showsTip),
                "styledTip": optional(singTakes.styledTakeTip),
            ]),
        ])
    }
}
