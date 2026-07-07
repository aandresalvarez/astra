import Foundation

enum TestRepositoryRoot {
    static func resolve(
        fileManager: FileManager = .default,
        startingAt startPath: String = FileManager.default.currentDirectoryPath
    ) throws -> URL {
        var candidate = URL(fileURLWithPath: startPath)
        while true {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path),
               fileManager.fileExists(atPath: candidate.appendingPathComponent("Astra").path) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                throw TestRepositoryRootError.notFound(startPath: startPath, finalPath: candidate.path)
            }
            candidate = parent
        }
    }
}

enum TestRepositoryRootError: Error, CustomStringConvertible {
    case notFound(startPath: String, finalPath: String)

    var description: String {
        switch self {
        case let .notFound(startPath, finalPath):
            "Could not find ASTRA repository root from \(startPath); stopped at \(finalPath)"
        }
    }
}
