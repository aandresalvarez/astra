import Foundation
import ASTRACore

/// Asks a provider's own on-disk session store whether a session id ASTRA
/// captured can still be resumed, so a missing one is caught before launch.
///
/// Only runtimes that mishandle a stale id are checked:
/// - Antigravity silently opens a fresh conversation under an unknown id, so the
///   follow-up would lose its history without any error.
/// - Copilot exits 1 on an unknown id and has no stale-session recovery, so
///   Retry would replay the same dead id forever.
/// Claude Code and Codex fail loudly and already clear a stale session. Cursor
/// does not resume natively (its resumed turns come back empty too often), so
/// it never reaches this check.
///
/// The layouts below were read off the real CLIs. A layout change reads as
/// "missing", which degrades to the rebuilt-prompt continuation ASTRA used
/// before native resume — never to a broken launch.
enum ProviderNativeSessionStore {
    static func sessionExists(
        runtime: AgentRuntimeID,
        sessionID: String,
        providerHomeDirectory: String = "",
        userHome: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> Bool {
        guard verifiesBeforeResume(runtime) else { return true }
        // The id is built into a path below, so it must be a plain token.
        guard isPlainSessionToken(sessionID) else { return false }
        let home = providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        switch runtime {
        case .antigravityCLI:
            // `agy` reads its store out of HOME, which ASTRA points at the
            // configured provider home when there is one.
            let base = home.isEmpty ? userHome : home
            return fileManager.fileExists(atPath: path(
                base, ".gemini", "antigravity-cli", "conversations", "\(sessionID).db"
            ))
        case .copilotCLI:
            return fileManager.fileExists(atPath: path(
                CopilotCLIRuntime.defaultHome(userHome: userHome), "session-state", sessionID
            ))
        default:
            return true
        }
    }

    static func verifiesBeforeResume(_ runtime: AgentRuntimeID) -> Bool {
        switch runtime {
        case .antigravityCLI, .copilotCLI: true
        default: false
        }
    }

    private static func isPlainSessionToken(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              value.unicodeScalars.count <= 128,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func path(_ components: String...) -> String {
        components.dropFirst().reduce(components[0]) { ($0 as NSString).appendingPathComponent($1) }
    }
}
