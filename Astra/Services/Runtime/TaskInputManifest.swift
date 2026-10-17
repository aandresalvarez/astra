import Foundation

/// A disposable projection of AgentTask.inputs, refreshed before every launch.
/// It retains exact identities without reading selected files or growing prompts.
struct TaskInputManifest: Codable, Equatable, Sendable {
    let files: [String]
    let context: [String]

    init(inputs: [String]) {
        var seen: Set<String> = []
        files = inputs.compactMap(Self.inputPath).filter { seen.insert($0).inserted }
        context = inputs.filter { Self.inputPath($0) == nil }
    }

    static func url(taskFolder: String) -> URL {
        URL(fileURLWithPath: taskFolder).appendingPathComponent("diagnostics/task_inputs.json")
    }

    func persist(taskFolder: String) throws {
        guard !taskFolder.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        let url = Self.url(taskFolder: taskFolder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private static func inputPath(_ raw: String) -> String? {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL { return url.path }
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
        return (path as NSString).expandingTildeInPath
    }
}
