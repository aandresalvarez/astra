import Foundation

// Synchronous mirror serialization; storage semantics match the existing
// explicit export path. Diagnostics count bytes only when a cleanup scope exists.
extension WorkspaceConfigManager {
    static func write(_ config: WorkspaceConfig, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let workspaceID = config.id ?? "none"
        let data = try WorkspacePersistenceWork.measure("mirror_encode", workspaceID: workspaceID) {
            try WorkspacePersistenceWork.jsonEncode(workspaceID: workspaceID) { try encoder.encode(config) }
        }
        try WorkspacePersistenceWork.measure("mirror_write", workspaceID: workspaceID) {
            try WorkspacePersistenceWork.jsonWrite(workspaceID: workspaceID, bytes: data.count,
                published: { _ in true }) { try data.write(to: url) }
        }
    }
}
