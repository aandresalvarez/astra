import Foundation

/// OpenSSH parses UserKnownHostsFile as a list after the shell has parsed argv.
/// Preserve quotes for that second parser, including for paths with spaces.
public enum SSHKnownHostsOption {
    public static func value(path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "UserKnownHostsFile=\"\(escaped)\""
    }
}
