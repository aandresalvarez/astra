import Foundation

struct TaskInputFileMetadata: Sendable {
    let items: [String: TaskFileItem]
    let missing: Set<String>

    static func load(paths: [String]) -> Self {
        var items: [String: TaskFileItem] = [:]
        var missing: Set<String> = []
        for raw in paths {
            let path = TaskFileIndex.normalizedPath(raw)
            var directory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else {
                missing.insert(raw)
                continue
            }
            items[raw] = TaskFileIndex.fileItem(path: path, isDirectory: directory.boolValue, source: "input")
        }
        return Self(items: items, missing: missing)
    }
}
