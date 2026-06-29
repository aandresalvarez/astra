import Foundation
import Testing
@testable import ASTRA

@Suite("Prompt Context IO Snapshot Loader")
struct PromptContextIOSnapshotLoaderTests {
    @Test("Prompt IO snapshot bounds file bytes before UTF-8 decoding")
    func promptIOSnapshotBoundsFileBytesBeforeUTF8Decoding() throws {
        let folder = NSTemporaryDirectory() + "prompt-io-bounded-read-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: folder) }

        let outputs = (folder as NSString).appendingPathComponent("outputs")
        try FileManager.default.createDirectory(atPath: outputs, withIntermediateDirectories: true)

        var turnData = Data("SAFE_TURN_OUTPUT_".utf8)
        turnData.append(Data(repeating: UInt8(ascii: "x"), count: 256))
        turnData.append(0xff)
        try turnData.write(to: URL(fileURLWithPath: (outputs as NSString).appendingPathComponent("turn_001.md")))

        var historyData = Data()
        historyData.append(0xff)
        historyData.append(Data(repeating: UInt8(ascii: "y"), count: 256))
        historyData.append(Data("\n## Turn 1\nSAFE_HISTORY_TAIL".utf8))
        try historyData.write(to: URL(fileURLWithPath: SessionHistoryManager.historyPath(taskFolder: folder)))

        let snapshot = PromptContextIOSnapshotLoader.snapshot(
            taskFolder: folder,
            window: PromptContextIOSnapshotLoader.TranscriptWindow(
                fileLimit: 1,
                fullOutputFileLimit: 1,
                fullOutputMaxCharacters: 32,
                olderOutputMaxCharacters: 16
            )
        )

        #expect(snapshot.recentConversationTranscript?.text.contains("SAFE_TURN_OUTPUT") == true)
        #expect(snapshot.sessionHistorySummary?.text.contains("SAFE_HISTORY_TAIL") == true)
    }
}
