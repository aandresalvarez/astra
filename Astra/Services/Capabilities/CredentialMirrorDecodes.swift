import Foundation
import ASTRAPersistence

/// Recovery mirror files read and decoded ahead of a credential pass, off the
/// main actor, so the pass doesn't decode tens of megabytes of JSON on it.
///
/// A derived cache, never an owner: the pass still reads every file itself,
/// on the main actor, and takes a decode from here only for the very bytes it
/// read (`file(at:ifContentsAre:)`). Each shape's decode depends on those
/// bytes alone, so what the pass decides is what decoding them on the main
/// actor would have given. A file that changed since, or wasn't decoded here,
/// is decoded by the pass as before.
struct CredentialMirrorDecodes: Sendable {
    /// One file's bytes, decoded as each shape a pass reads it as; a shape is
    /// nil when the bytes don't decode as it.
    struct File: Sendable {
        let data: Data
        let identity: CredentialMirrorIdentity?
        let connectors: ConnectorMirrorListing?
        let references: PluginCredentialMirrorListing?

        init(data: Data) {
            self.data = data
            identity = CredentialMirrorIdentity.decode(data)
            connectors = ConnectorMirrorListing.decode(data)
            references = PluginCredentialMirrorListing.decode(data)
        }
    }

    private let files: [String: File]

    var fileCount: Int { files.count }
    var byteCount: Int { files.values.reduce(0) { $0 + $1.data.count } }

    /// The decode of the file at `path`, when it was made from `data`.
    func file(at path: String, ifContentsAre data: Data) -> File? {
        guard let file = files[path], file.data == data else { return nil }
        return file
    }

    private static let queue = DispatchQueue(label: "com.coral.astra.credential-mirror-decode", qos: .utility)

    /// Reads and decodes `candidates` on a dedicated queue, never the
    /// cooperative pool a stalled read would starve, as
    /// `CredentialRecoveryMirrors.read` reads them: each list in order,
    /// stopping at the first file that is there. One that can't be read is
    /// left out, and ends its list; the pass reads it itself.
    static func decode(_ candidates: [[String]]) async -> Self {
        await withCheckedContinuation { (continuation: CheckedContinuation<Self, Never>) in
            queue.async { continuation.resume(returning: decodeNow(candidates)) }
        }
    }

    private static func decodeNow(_ candidates: [[String]]) -> Self {
        var files: [String: File] = [:]
        for list in candidates {
            for path in list {
                do {
                    files[path] = File(data: try Data(contentsOf: URL(fileURLWithPath: path)))
                } catch {
                    if WorkspaceFileLayout.isMissingFile(error) { continue }
                }
                break
            }
        }
        return Self(files: files)
    }
}
