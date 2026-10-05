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
/// before native resume — never to a broken launch. An entry that cannot be
/// reached (an unreadable directory on its path) is unverifiable, not missing.
enum ProviderNativeSessionStore {
    /// What a lookup could establish. Only a confirmed absence may be acted on destructively; a store
    /// that could not be read (busy, unreadable, unexpected layout) proves nothing about the session.
    enum Lookup: Equatable {
        case present
        case absent
        case unverifiable
    }

    static func sessionExists(
        runtime: AgentRuntimeID,
        sessionID: String,
        providerHomeDirectory: String = "",
        userHome: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        lookup(
            runtime: runtime, sessionID: sessionID, providerHomeDirectory: providerHomeDirectory,
            userHome: userHome, environment: environment, fileManager: fileManager
        ) == .present
    }

    static func lookup(
        runtime: AgentRuntimeID,
        sessionID: String,
        providerHomeDirectory: String = "",
        userHome: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Lookup {
        guard verifiesBeforeResume(runtime) else { return .present }
        // The id is built into a path below, so it must be a plain token.
        guard isPlainSessionToken(sessionID) else { return .absent }
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
            return entryLookup(
                path(base, ".gemini", "antigravity-cli", "conversations", "\(sessionID).db"), fileManager: fileManager
            )
        case .copilotCLI:
            return entryLookup(
                path(CopilotCLIRuntime.defaultHome(userHome: userHome), "session-state", sessionID), fileManager: fileManager
            )
        case .openCodeCLI:
            return openCodeSessionExists(sessionID, userHome: userHome, environment: environment, fileManager: fileManager)
        default:
            return .present
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
    private static func cursorChatExists(_ sessionID: String, userHome: String, fileManager: FileManager) -> Lookup {
        let chatsRoot = path(userHome, ".cursor", "chats")
        let root = entryLookup(chatsRoot, fileManager: fileManager)
        guard root == .present else { return root }
        guard let workspaces = try? fileManager.contentsOfDirectory(atPath: chatsRoot) else { return .unverifiable }
        let lookups = workspaces.map { entryLookup(path(chatsRoot, $0, sessionID), fileManager: fileManager) }
        if lookups.contains(.present) { return .present }
        return lookups.contains(.unverifiable) ? .unverifiable : .absent
    }

    /// OpenCode keeps sessions as rows of its SQLite database. Opened read-only
    /// with a short busy timeout so a running OpenCode never blocks a launch;
    /// a database that cannot be read proves nothing about the session.
    private static func openCodeSessionExists(
        _ sessionID: String,
        userHome: String,
        environment: [String: String],
        fileManager: FileManager
    ) -> Lookup {
        // The launch's own XDG_DATA_HOME wins, then the launch HOME (a skill can scope either), then ASTRA's.
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
        let databaseEntry = entryLookup(databasePath, fileManager: fileManager)
        guard databaseEntry == .present else { return databaseEntry }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return .unverifiable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM session WHERE id = ?1 LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            return .unverifiable
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, sessionID, -1, transient) == SQLITE_OK else { return .unverifiable }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return .present
        case SQLITE_DONE: return .absent
        default: return .unverifiable // busy past the timeout, a read error
        }
    }

    /// `fileExists` is false for an entry it could not reach as well as for a missing one, so only
    /// a lookup that fails with "no such entry" confirms absence.
    private static func entryLookup(_ path: String, fileManager: FileManager) -> Lookup {
        if fileManager.fileExists(atPath: path) { return .present }
        var info = stat()
        guard stat(path, &info) != 0 else { return .present }
        return errno == ENOENT || errno == ENOTDIR ? .absent : .unverifiable
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
