import Foundation
import ASTRACore

final class MockFileSystem: FileSystem {
    private(set) var createdDirectories: [URL] = []
    private var existingPaths: [String: Bool] = [:]
    var shouldThrowOnCreate = false

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        if shouldThrowOnCreate {
            throw CocoaError(.fileWriteNoPermission)
        }
        createdDirectories.append(url)
        existingPaths[url.path] = true
    }

    func fileExists(atPath path: String) -> Bool {
        existingPaths[path] != nil
    }

    func fileExists(atPath path: String, isDirectory: inout Bool) -> Bool {
        guard let directory = existingPaths[path] else {
            isDirectory = false
            return false
        }
        isDirectory = directory
        return true
    }

    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?) throws -> [URL] {
        []
    }

    func addExistingPath(_ path: String, isDirectory: Bool = false) {
        existingPaths[path] = isDirectory
    }
}
