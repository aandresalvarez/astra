import Foundation
import Darwin

/// User settings are deliberately disabled for observation. Check whether doing
/// so would discard authentication or routing before choosing a saved account.
enum ClaudeObservationAuthentication {
    static func unavailableReason(environment: [String: String], projectedEnvironment: [String: String]) -> String? {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let directory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (home as NSString).appendingPathComponent(".claude")
        let settings = URL(fileURLWithPath: directory).appendingPathComponent("settings.json")
        do {
            // Reject unreadable settings and special files rather than treating
            // them as absent, blocking on a FIFO, or following a replacement link.
            let descriptor = open(settings.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
            guard descriptor >= 0 else {
                if errno == ENOENT { return nil }
                return "Claude user authentication settings could not be read safely for investigation."
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                return "Claude user authentication settings are not a regular file."
            }
            let data = try handle.read(upToCount: 262_145) ?? Data()
            guard data.count <= 262_144,
                  let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Claude user authentication settings could not be verified within the investigation limit."
            }
            let authSettings = ["apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "forceLoginMethod", "forceLoginOrgUUID"]
            if authSettings.contains(where: { values[$0] != nil }) {
                return "Claude authentication depends on user settings disabled for investigation. No alternate account was selected."
            }
            if let configured = values["env"] {
                guard let configured = configured as? [String: Any] else {
                    return "Claude user authentication environment settings could not be verified."
                }
                if configured.contains(where: { key, value in
                    isAuthenticationKey(key)
                        && ((value as? String) != projectedEnvironment[key] || (value as? String) == nil)
                }) {
                    return "Claude user settings contain authentication or routing not represented by the isolated launch. No alternate account or backend was selected."
                }
            }
            return nil
        } catch {
            return "Claude user authentication settings could not be read safely for investigation."
        }
    }

    static func isAuthenticationKey(_ key: String) -> Bool {
        if key.hasPrefix("ANTHROPIC_DEFAULT_") || ["ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL"].contains(key) { return false }
        return ["ANTHROPIC_", "AWS_", "GOOGLE_", "GCLOUD_", "CLOUDSDK_", "CLOUD_ML_", "CLAUDE_CODE_USE_",
                "CLAUDE_CODE_SKIP_", "CLAUDE_CODE_OAUTH_", "CLAUDE_CODE_API_"].contains { key.hasPrefix($0) }
            || ["CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "HTTPS_PROXY", "HTTP_PROXY", "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS"].contains(key)
    }
}
