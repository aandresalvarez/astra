import Darwin
import Foundation
import ASTRACore

/// Location identity, not inode identity: provider settings are atomically replaced.
/// Resolve existing components in filesystem order, including symlinks before `..`.
enum ProviderSharedStateIdentity {
    struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? {
            "The provider did not start. ASTRA cannot safely reserve its configuration: \(detail). Review the provider home and try again."
        }
    }

    static func canonicalPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw Failure(detail: "the path must be absolute") }
        var resolved = ""
        var missing = false
        for component in path.split(separator: "/") {
            if component == "." { continue }
            guard !(missing && component == "..") else { throw Failure(detail: "a missing directory precedes '..'") }
            let candidate = resolved + "/" + component
            if let physical = realpath(candidate, nil) {
                defer { free(physical) }
                resolved = String(cString: physical)
                var info = stat()
                guard stat(resolved, &info) == 0 else { throw Failure(detail: "the path could not be inspected") }
                guard info.st_mode & S_IFMT == S_IFDIR || (info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1) else {
                    throw Failure(detail: "hard-linked or special configuration files are unsupported")
                }
            } else {
                guard errno == ENOENT else { throw Failure(detail: "the path cannot be resolved") }
                // A dangling symlink is not an absent settings file. Its destination
                // could later materialize as a different resource.
                var info = stat()
                guard lstat(candidate, &info) != 0 else { throw Failure(detail: "the path contains a dangling link") }
                missing = true
                resolved = candidate
            }
        }
        return try normalizedComponents(resolved.isEmpty ? "/" : resolved) { parent in
            var info = stat()
            guard stat(parent, &info) == 0 else {
                if errno == ENOENT { return nil }
                throw Failure(detail: "the volume identity cannot be inspected")
            }
            let values = try URL(fileURLWithPath: parent).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            guard let sensitive = values.volumeSupportsCaseSensitiveNames else { throw Failure(detail: "the volume identity is unavailable") }
            return sensitive
        }
    }

    /// Each name belongs to its parent's volume. A case-insensitive mount
    /// must not fold the case-sensitive ancestors of the mount point itself.
    static func normalizedComponents(_ path: String, sensitivity: (String) throws -> Bool?) throws -> String {
        var originalParent = "/"
        var result = ""
        var sensitive = true
        for component in path.split(separator: "/") {
            sensitive = try sensitivity(originalParent) ?? sensitive
            let name = String(component)
            result += "/" + (sensitive ? name : name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")))
            originalParent = originalParent == "/" ? "/" + name : originalParent + "/" + name
        }
        return result.isEmpty ? "/" : result
    }

    static func providerHome(_ configured: String) throws -> String {
        let path = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty means inherited HOME, not a user-authorized grant to the whole home.
        return path.isEmpty ? "" : try canonicalPath(path)
    }

    static func effectiveHome(configured: String, environment: [String: String]) throws -> String {
        let explicit = try providerHome(configured)
        if !explicit.isEmpty { return explicit }
        return try canonicalPath(environment["HOME"] ?? ProcessInfo.processInfo.environment["HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path)
    }
}

extension AgentRuntimeSharedStateKey {
    private static var filePrefix: String { "file-v1:" }
    init(runtime: AgentRuntimeID, fileURL: URL) throws {
        self.init(runtime: runtime, identifier: Self.filePrefix + (try ProviderSharedStateIdentity.canonicalPath(fileURL.path)))
    }
    var runtimeName: String { String(rawValue.prefix { $0 != ":" }) }
    var filePath: String? {
        let prefix = runtimeName + ":" + Self.filePrefix
        guard rawValue.hasPrefix(prefix + "/") else { return nil }
        return String(rawValue.dropFirst(prefix.count))
    }
    func validate(fileURL: URL) throws {
        guard let filePath, try ProviderSharedStateIdentity.canonicalPath(fileURL.path) == filePath else {
            throw ProviderSharedStateIdentity.Failure(detail: "the configuration path changed while this task was waiting")
        }
    }
    /// Legacy receipts did not capture physical identity. Resolving their path
    /// today cannot prove what an earlier execution still owns.
    func conflicts(withRecorded raw: String) -> Bool {
        if raw == rawValue { return true }
        guard filePath != nil, raw.hasPrefix(runtimeName + ":") else { return false }
        return !raw.hasPrefix(runtimeName + ":" + Self.filePrefix + "/")
    }
}
