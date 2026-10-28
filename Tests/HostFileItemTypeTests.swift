import Foundation
import Testing
import ASTRACore

@Suite("Host file type-only metadata")
struct HostFileItemTypeTests {
    @Test("Type probe follows links, reports absence and preserves uncertain errors")
    func followsLinksAndKeepsErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("preserved".utf8).write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let directoryLink = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
        let loop = root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
        let broker = HostFileAccessBroker()
        #expect(try broker.itemType(at: root, intent: .explicitUserSelection) == .typeDirectory)
        #expect(try broker.itemType(at: file, intent: .explicitUserSelection) == .typeRegular)
        #expect(try broker.itemType(at: directoryLink, intent: .explicitUserSelection) == .typeDirectory)
        #expect(try broker.itemType(at: link, intent: .explicitUserSelection) == .typeRegular)
        #expect(try broker.itemType(at: root.appendingPathComponent("missing"), intent: .explicitUserSelection) == nil)
        #expect(try broker.itemType(at: file.appendingPathComponent("child"), intent: .explicitUserSelection) == nil)
        #expect(throws: (any Error).self) { try broker.itemType(at: loop, intent: .explicitUserSelection) }
        try FileManager.default.removeItem(at: file)
        #expect(try broker.itemType(at: link, intent: .explicitUserSelection) == nil)
        #expect(try broker.itemType(at: root, intent: .astraManagedStorage(root: root.appendingPathComponent("elsewhere"))) == nil)
    }

    @Test("An injected filesystem remains authoritative and denial is not absence")
    func injectedFilesystemStaysAuthoritative() throws {
        let manager = TypeProbeFileManager()
        let broker = HostFileAccessBroker(fileManager: manager)
        let url = URL(fileURLWithPath: "/tmp/astra-injected-type-probe")
        #expect(try broker.itemType(at: url, intent: .explicitUserSelection) == .typeDirectory)
        manager.deny = true
        #expect(throws: (any Error).self) { try broker.itemType(at: url, intent: .explicitUserSelection) }
        #expect(manager.probes == 2)
    }
}

private final class TypeProbeFileManager: FileManager {
    var deny = false
    var probes = 0
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        probes += 1
        if deny { throw CocoaError(.fileReadNoPermission) }
        return [.type: FileAttributeType.typeDirectory]
    }
}
