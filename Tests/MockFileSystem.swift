import Foundation
import ASTRACore

final class MockFileSystem: FileSystem {
    private(set) var createdDirectories: [URL] = []
    private var existingPaths: Set<String> = []
    var shouldThrowOnCreate = false

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        if shouldThrowOnCreate {
            throw CocoaError(.fileWriteNoPermission)
        }
        createdDirectories.append(url)
        existingPaths.insert(url.path)
    }

    func fileExists(atPath path: String) -> Bool {
        existingPaths.contains(path)
    }

    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?) throws -> [URL] {
        []
    }

    func addExistingPath(_ path: String) {
        existingPaths.insert(path)
    }
}
