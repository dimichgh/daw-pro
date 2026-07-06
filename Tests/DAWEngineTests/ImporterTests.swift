import Foundation
import Testing
import DAWCore
@testable import DAWEngine

@Suite("AudioFileImporter")
struct AudioFileImporterTests {
    @Test("reads facts from a real system audio file")
    func readsSystemSound() throws {
        // Ships on every macOS install.
        let url = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")
        let info = try AudioFileImporter().audioFileInfo(at: url)
        #expect(info.durationSeconds > 0.1)
        #expect(info.durationSeconds < 10)
        #expect(info.sampleRate >= 8000)
        #expect(info.channelCount >= 1)
    }

    @Test("nonexistent path throws importFailed")
    func missingFile() {
        let url = URL(fileURLWithPath: "/no/such/file-\(UUID().uuidString).wav")
        do {
            _ = try AudioFileImporter().audioFileInfo(at: url)
            Issue.record("expected throw")
        } catch let error as ProjectError {
            guard case .importFailed = error else {
                Issue.record("wrong case: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
