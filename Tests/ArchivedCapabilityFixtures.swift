import Foundation
import ASTRACore

/// Former built-in packages archived in `capabilities/archived/`. The app no
/// longer ships them, but the code they exercise (Google Workspace OAuth and
/// remote MCP, the Drive browser adapter, the Stanford mail tools) still
/// does, so tests keep using the real definitions as fixtures.
enum ArchivedCapabilityFixtures {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("capabilities/archived", isDirectory: true)
    }

    static func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    static func package(_ id: String) throws -> PluginPackage {
        try JSONDecoder().decode(PluginPackage.self, from: Data(contentsOf: url(for: id)))
    }
}
