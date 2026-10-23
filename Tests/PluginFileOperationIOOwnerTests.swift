import Foundation
import Testing
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Prepared plugin storage owner", .serialized)
struct PluginFileOperationIOOwnerTests {
    @Test("Preparation and replay obey the library's filesystem owner, including refused writes")
    func replayUsesTheLibraryFileManager() throws {
        let fixture = try PluginFileOperationRecoveryTests.Fixture()
        defer { fixture.removeFiles() }
        let files = RecordingFiles(library: fixture.library.directory, target: fixture.target)
        let library = CapabilityLibrary(directory: fixture.library.directory, fileManager: files)
        let journal = PluginFileOperationJournal(library: library,
            approvals: CapabilityApprovalStore(directory: fixture.root.appendingPathComponent("Approvals")))
        let prepared = try journal.prepare(storeIdentity: #require(PersistentStoreIdentity.current(for: fixture.context)),
            pluginIDs: ["example"], changes: [.init(root: .library, name: "example.json", replacement:
                PluginFileImage(isDirectory: false, directories: [], files: ["": Data("replacement".utf8)]))])
        #expect(files.createdLibrary)
        files.refuseTargetRemoval = true
        #expect(throws: (any Error).self) { try journal.apply(prepared, forward: true) }
        #expect(files.refusedRemoval)
        #expect(try fixture.value() == "old definition")
        #expect(try journal.pendingIDs() == [prepared.id])
        files.refuseTargetRemoval = false
        try journal.apply(prepared, forward: true)
        #expect(try fixture.value() == "replacement")
        try journal.apply(prepared, forward: false)
        #expect(try fixture.value() == "old definition")
        try journal.discard(prepared)
    }
}

private final class RecordingFiles: FileManager, @unchecked Sendable {
    let library: String
    let target: String
    var createdLibrary = false
    var refuseTargetRemoval = false
    var refusedRemoval = false
    init(library: URL, target: URL) {
        self.library = library.standardizedFileURL.resolvingSymlinksInPath().path
        self.target = target.standardizedFileURL.resolvingSymlinksInPath().path
        super.init()
    }
    override func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {
        if url.standardizedFileURL.resolvingSymlinksInPath().path == library { createdLibrary = true }
        try super.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: attributes)
    }
    override func removeItem(at url: URL) throws {
        if refuseTargetRemoval, url.standardizedFileURL.resolvingSymlinksInPath().path == target {
            refusedRemoval = true
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}
