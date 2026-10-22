import CryptoKit
import Foundation

/// Oversized mail stays complete in the sanctioned task folder, like other
/// brokered exports. It is never truncated to fit a transport envelope.
enum MailReadArtifact {
    static let maximumBytes = 8 * 1_024 * 1_024

    static func store(_ data: Data, configuration: HostControlToolConfiguration) throws -> Data {
        guard !configuration.taskFolder.isEmpty, data.count <= maximumBytes else { throw MailReadFailure.outputUnavailable }
        let root = TaskFolderContainment.resolvedRoot(configuration.taskFolder)
        let directory = try TaskFolderContainment.openDirectory(named: "mail-reads", beneath: root,
            refusal: "write mail outside this task", makeError: { _ in MailReadFailure.outputUnavailable })
        let temporary = ".mail-\(UUID().uuidString).partial"
        try directory.writeExclusively(data, named: temporary)
        defer { directory.removeFile(named: temporary) }
        let name = "outlook-mail-\(UUID().uuidString).json"
        guard directory.link(temporary: temporary, to: name) == 0 else { throw MailReadFailure.outputUnavailable }
        let path = (directory.path as NSString).appendingPathComponent(name)
        return try JSONSerialization.data(withJSONObject: [
            "output_file": path, "byte_count": data.count,
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "note": "The complete mail response is saved in this task's mail-reads folder."
        ], options: [.sortedKeys])
    }
}
