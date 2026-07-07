import Foundation
import Testing
import ASTRAPersistence
@testable import ASTRA

@Suite("Prompt Context IO Snapshot Loader")
struct PromptContextIOSnapshotLoaderTests {
    @Test("Prompt IO byte limits keep default windows precise but clamp misconfigured windows")
    func promptIOByteLimitsClampMisconfiguredWindows() {
        #expect(PromptContextIOSnapshotLoader.byteLimit(for: 8_000) == 32_000)
        #expect(PromptContextIOSnapshotLoader.byteLimit(for: 0) == 0)
        #expect(PromptContextIOSnapshotLoader.byteLimit(for: -1) == 0)

        let hugeLimit = PromptContextIOSnapshotLoader.byteLimit(for: Int.max)
        #expect(hugeLimit < Int.max)
        #expect(hugeLimit == PromptContextIOSnapshotLoader.byteLimit(for: Int.max / 4))
    }

    @Test("Prompt IO UTF-8 repair trims only scalar-boundary bytes")
    func promptIOUTF8RepairTrimsOnlyScalarBoundaryBytes() {
        var prefixBoundary = Data("prefix".utf8)
        prefixBoundary.append(contentsOf: [0xf0, 0x9f, 0x98])
        #expect(PromptContextIOSnapshotLoader.utf8String(from: prefixBoundary, keeping: .prefix) == "prefix")

        var suffixBoundary = Data([0x9f, 0x98])
        suffixBoundary.append(Data("suffix".utf8))
        #expect(PromptContextIOSnapshotLoader.utf8String(from: suffixBoundary, keeping: .suffix) == "suffix")

        var invalidRun = Data(repeating: 0xff, count: 8)
        invalidRun.append(Data("tail".utf8))
        #expect(PromptContextIOSnapshotLoader.utf8String(from: invalidRun, keeping: .suffix) == nil)
    }

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
