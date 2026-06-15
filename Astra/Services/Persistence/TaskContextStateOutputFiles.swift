import Foundation

extension TaskContextStateManager {
    static func outputTurnFiles(in outputDirectory: String) -> [String] {
        let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        let accessIntent = HostFileAccessIntent.astraManagedStorage(root: outputURL.deletingLastPathComponent())
        guard !outputDirectory.isEmpty,
              let urls = try? HostFileAccessBroker().contentsOfDirectory(
                at: outputURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles],
                intent: accessIntent
              ) else { return [] }
        return urls
            .filter { $0.lastPathComponent.hasPrefix("turn_") && $0.lastPathComponent.hasSuffix(".md") }
            .map(\.path)
            .sorted()
    }
}
