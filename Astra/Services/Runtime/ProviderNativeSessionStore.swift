import Foundation
import SQLite3
import ASTRACore

/// Asks a provider's own on-disk session store whether a session id ASTRA
/// captured can still be resumed, so a missing one is caught before launch.
///
/// Only runtimes that mishandle a stale id are checked:
/// - Cursor and Antigravity silently open a fresh conversation under an unknown
///   id, so the follow-up would lose its history without any error.
/// - Copilot and OpenCode exit 1 on an unknown id and have no stale-session
///   recovery, so Retry would replay the same dead id forever.
/// Claude Code and Codex fail loudly and already clear a stale session.
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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        guard verifiesBeforeResume(runtime) else { return true }
        // The id is built into a path below, so it must be a plain token.
        guard isPlainSessionToken(sessionID) else { return false }
        let home = providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        switch runtime {
        case .cursorCLI:
            // Cursor reads `~/.cursor` from the launch's HOME, which a skill can scope.
            let launchHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return cursorChatExists(sessionID, userHome: launchHome.isEmpty ? userHome : launchHome, fileManager: fileManager)
        case .antigravityCLI:
            // `agy` reads its store out of HOME: the configured provider home when there is one,
            // else the launch's own HOME (a skill can scope it), else ASTRA's.
            let launchHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let base = !home.isEmpty ? home : (launchHome.isEmpty ? userHome : launchHome)
            return fileManager.fileExists(atPath: path(
                base, ".gemini", "antigravity-cli", "conversations", "\(sessionID).db"
            ))
        case .copilotCLI:
            return fileManager.fileExists(atPath: path(
                CopilotCLIRuntime.defaultHome(userHome: userHome), "session-state", sessionID
            ))
        case .openCodeCLI:
            return openCodeSessionExists(sessionID, userHome: userHome, environment: environment, fileManager: fileManager)
        default:
            return true
        }
    }

    static func verifiesBeforeResume(_ runtime: AgentRuntimeID) -> Bool {
        switch runtime {
        case .cursorCLI, .antigravityCLI, .copilotCLI, .openCodeCLI: true
        default: false
        }
    }

    /// Cursor files chats under a per-workspace hash directory it does not
    /// document, so look for the chat id one level down.
    private static func cursorChatExists(_ sessionID: String, userHome: String, fileManager: FileManager) -> Bool {
        let chatsRoot = path(userHome, ".cursor", "chats")
        guard let workspaces = try? fileManager.contentsOfDirectory(atPath: chatsRoot) else { return false }
        return workspaces.contains { fileManager.fileExists(atPath: path(chatsRoot, $0, sessionID)) }
    }

    /// OpenCode keeps sessions as rows of its SQLite database. Opened read-only
    /// with a short busy timeout so a running OpenCode never blocks a launch;
    /// any failure to read it counts as "missing".
    private static func openCodeSessionExists(
        _ sessionID: String,
        userHome: String,
        environment: [String: String],
        fileManager: FileManager
    ) -> Bool {
        // The launch's own XDG_DATA_HOME wins, then the launch's HOME (a skill can scope either), then ASTRA's.
        let configured = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let launchHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dataHome = !configured.isEmpty
            ? configured
            : path(launchHome.isEmpty ? userHome : launchHome, ".local", "share")
        // OPENCODE_DB overrides the file: absolute as given, relative to OpenCode's own data directory.
        let override = environment["OPENCODE_DB"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let databasePath = override.isEmpty
            ? path(dataHome, "opencode", "opencode.db")
            : (override.hasPrefix("/") ? override : path(dataHome, "opencode", override))
        guard fileManager.fileExists(atPath: databasePath) else { return false }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return false
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM session WHERE id = ?1 LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, sessionID, -1, transient) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
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
