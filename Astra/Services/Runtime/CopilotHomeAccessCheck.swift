import Foundation

/// An entry under Copilot's state home that the current user cannot use.
struct CopilotHomeAccessProblem: Equatable, Sendable {
    enum Access: String, Sendable {
        /// Copilot cannot read it at all: the CLI exits 1 with no output.
        case unreadable
        /// Copilot can read it but cannot save to it.
        case unwritable
        /// The state home exists but is a file, so Copilot has nowhere to
        /// keep its config.
        case notADirectory
    }

    let path: String
    let isDirectory: Bool
    let owner: String?
    let ownedByCurrentUser: Bool
    let posixPermissions: Int?
    let access: Access
    /// Whether Copilot reads this entry when it starts. An unreadable entry it
    /// never opens (a stray `config.json.bak`) is worth a warning, not a block.
    let isReadAtStartup: Bool

    /// Kills every Copilot turn before it prints a byte.
    var blocksCopilot: Bool {
        switch access {
        case .notADirectory: return true
        case .unreadable: return isReadAtStartup
        case .unwritable: return false
        }
    }

    var displayPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    var ownershipDescription: String {
        var parts: [String] = []
        if let owner { parts.append("owned by \(owner)") }
        if let posixPermissions { parts.append("mode \(String(posixPermissions & 0o777, radix: 8))") }
        return parts.joined(separator: ", ")
    }
}

/// What `CopilotHomeAccessCheck` found under one Copilot state home.
struct CopilotHomeAccessReport: Equatable, Sendable {
    let home: String
    let problems: [CopilotHomeAccessProblem]

    var isClean: Bool { problems.isEmpty }

    /// An unreadable startup entry kills every Copilot turn before it prints
    /// a byte. An unwritable one may only fail when Copilot saves state, and an
    /// unreadable one it never opens does not fail at all, so both are
    /// warnings, not launch blockers.
    var blocksCopilot: Bool {
        problems.contains(where: \.blocksCopilot)
    }

    /// One sentence naming what is wrong, e.g. "Copilot cannot read
    /// ~/.copilot/config.json (owned by root, mode 600)."
    var cause: String {
        guard !problems.isEmpty else { return "" }
        if let misplaced = problems.first(where: { $0.access == .notADirectory }) {
            return "\(misplaced.displayPath) is a file, not a folder, so Copilot has nowhere to keep its settings."
        }
        let unreadable = problems.filter { $0.access == .unreadable }
        let unwritable = problems.filter { $0.access == .unwritable }
        var sentences: [String] = []
        if !unreadable.isEmpty {
            sentences.append("Copilot cannot read \(Self.list(unreadable)).")
        }
        if !unwritable.isEmpty {
            sentences.append("Copilot cannot write \(Self.list(unwritable)).")
        }
        if problems.contains(where: { !$0.ownedByCurrentUser }) {
            sentences.append("This usually happens after Copilot was run with sudo.")
        }
        return sentences.joined(separator: " ")
    }

    /// A Terminal command that restores access. Entries owned by someone else
    /// (usually root) get their ownership back first; then every entry gets
    /// its owner permission bits back, because a chown alone leaves a mode-000
    /// file just as unreadable as before.
    var fixCommand: String {
        if let misplaced = problems.first(where: { $0.access == .notADirectory }) {
            let path = RuntimeRemediationCatalog.shellQuoted(misplaced.path)
            let backup = RuntimeRemediationCatalog.shellQuoted(misplaced.path + ".bak")
            return "mv \(path) \(backup)"
        }
        let foreign = problems.filter { !$0.ownedByCurrentUser }
        var commands: [String] = []
        if !foreign.isEmpty {
            let recursive = foreign.contains(where: \.isDirectory) ? " -R" : ""
            commands.append("sudo chown\(recursive) \"$USER\":staff \(Self.quotedPaths(foreign))")
        }
        let files = problems.filter { !$0.isDirectory }
        let directories = problems.filter(\.isDirectory)
        if !directories.isEmpty {
            commands.append("chmod u+rwx \(Self.quotedPaths(directories))")
        }
        if !files.isEmpty {
            commands.append("chmod u+rw \(Self.quotedPaths(files))")
        }
        return commands.joined(separator: " && ")
    }

    /// Cause plus fix, for blocker text and readiness remediation.
    var userMessage: String {
        guard !problems.isEmpty else { return "" }
        return "\(cause) Run `\(fixCommand)` in Terminal, then retry."
    }

    private static func list(_ problems: [CopilotHomeAccessProblem]) -> String {
        problems.map { problem in
            let detail = problem.ownershipDescription
            return detail.isEmpty ? problem.displayPath : "\(problem.displayPath) (\(detail))"
        }
        .joined(separator: ", ")
    }

    private static func quotedPaths(_ problems: [CopilotHomeAccessProblem]) -> String {
        problems.map { RuntimeRemediationCatalog.shellQuoted($0.path) }.joined(separator: " ")
    }
}

/// The one owner of "can this user actually use Copilot's state home?".
///
/// Copilot CLI exits 1 after a few seconds with zero bytes on stdout and
/// stderr, and writes no log, when it cannot read `~/.copilot/config.json`.
/// That happened in prod (2026-10-16) after something ran Copilot as root and
/// left the file `root:staff 600`. Both the readiness preflight and the
/// failure classifier ask this check, so the two can never disagree about it.
///
/// Only the home and its direct children are inspected: the CLI reads its
/// config and opens its top-level state folders on every turn, and walking
/// `session-state` recursively would cost a stat per historical session.
enum CopilotHomeAccessCheck {
    /// Keeps blocker text readable when a whole tree went root-owned.
    static let maximumReportedProblems = 5

    /// Config files Copilot only reads during a task. ASTRA already denies
    /// task-side writes to them (`configWriteDenyPaths`), so a user who made
    /// them read-only has a working, hardened setup, not a broken one.
    static let readOnlyConfigFileNames: Set<String> = Set(
        CopilotCLIRuntime.configWriteDenyPaths(userHome: "/").map { ($0 as NSString).lastPathComponent }
    )

    /// Top-level entries of a Copilot CLI 1.0.x home that hold its config or
    /// session state. Only these can block a launch when unreadable; anything
    /// else in the folder (backups, caches, other tools' files) is a warning.
    static let startupEntryNames: Set<String> = readOnlyConfigFileNames.union([
        "settings.json",
        "permissions-config.json",
        "session-state",
        "session-store.db",
        "session-store.db-wal",
        "session-store.db-shm"
    ])

    static let readinessCheckID = "copilot-home-access"

    static func inspect(
        home: String = CopilotCLIRuntime.defaultHome(),
        fileManager: FileManager = .default,
        currentUserID: uid_t = getuid()
    ) -> CopilotHomeAccessReport {
        let trimmedHome = home.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHome.isEmpty else {
            return CopilotHomeAccessReport(home: home, problems: [])
        }
        var isDirectory: ObjCBool = false
        // A missing home is not a problem: Copilot creates it on first run.
        guard fileManager.fileExists(atPath: trimmedHome, isDirectory: &isDirectory) else {
            return CopilotHomeAccessReport(home: trimmedHome, problems: [])
        }
        var problems: [CopilotHomeAccessProblem] = []
        guard isDirectory.boolValue else {
            let problem = problem(
                at: trimmedHome, requiresWrite: true, isReadAtStartup: true,
                fileManager: fileManager, currentUserID: currentUserID, forcedAccess: .notADirectory
            )
            return CopilotHomeAccessReport(home: trimmedHome, problems: problem.map { [$0] } ?? [])
        }
        if let homeProblem = problem(
            at: trimmedHome, requiresWrite: true, isReadAtStartup: true,
            fileManager: fileManager, currentUserID: currentUserID
        ) {
            // An unreadable home hides everything inside it, and the fix for
            // the home (a recursive chown) covers its children too. A home
            // that is only unwritable can still hide an unreadable config, so
            // its children are still checked.
            guard homeProblem.access == .unwritable else {
                return CopilotHomeAccessReport(home: trimmedHome, problems: [homeProblem])
            }
            problems.append(homeProblem)
        }
        guard let children = try? fileManager.contentsOfDirectory(atPath: trimmedHome) else {
            return CopilotHomeAccessReport(home: trimmedHome, problems: problems)
        }
        for child in children.sorted() {
            let path = (trimmedHome as NSString).appendingPathComponent(child)
            if let problem = problem(
                at: path,
                requiresWrite: !readOnlyConfigFileNames.contains(child),
                isReadAtStartup: startupEntryNames.contains(child),
                fileManager: fileManager,
                currentUserID: currentUserID
            ) {
                problems.append(problem)
            }
        }
        // Blocking entries first: they are the ones that kill the CLI.
        let ordered = problems.filter(\.blocksCopilot)
            + problems.filter { !$0.blocksCopilot && $0.access == .unreadable }
            + problems.filter { $0.access == .unwritable }
        return CopilotHomeAccessReport(
            home: trimmedHome,
            problems: Array(ordered.prefix(maximumReportedProblems))
        )
    }

    /// The readiness row for a report, or nil when nothing is wrong.
    static func readinessCheck(for report: CopilotHomeAccessReport) -> RuntimeReadinessCheck? {
        guard !report.isClean else { return nil }
        return RuntimeReadinessCheck(
            id: readinessCheckID,
            title: "Copilot settings folder",
            detail: report.cause,
            state: report.blocksCopilot ? .blocked : .warning,
            remediation: "Run `\(report.fixCommand)` in Terminal."
        )
    }

    private static func problem(
        at path: String,
        requiresWrite: Bool,
        isReadAtStartup: Bool,
        fileManager: FileManager,
        currentUserID: uid_t,
        forcedAccess: CopilotHomeAccessProblem.Access? = nil
    ) -> CopilotHomeAccessProblem? {
        // `attributesOfItem` does not follow symlinks; a link's target lives
        // outside Copilot's home and is not this check's to judge.
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return nil }
        let type = attributes[.type] as? FileAttributeType
        if type == .typeSymbolicLink { return nil }
        let isDirectory = type == .typeDirectory
        let readMode = isDirectory ? (R_OK | X_OK) : R_OK
        let access: CopilotHomeAccessProblem.Access
        if let forcedAccess {
            access = forcedAccess
        } else if Darwin.access(path, readMode) != 0 {
            access = .unreadable
        } else if requiresWrite, Darwin.access(path, W_OK) != 0 {
            access = .unwritable
        } else {
            return nil
        }
        let ownerID = (attributes[.ownerAccountID] as? NSNumber).map { uid_t($0.uint32Value) }
        return CopilotHomeAccessProblem(
            path: path,
            isDirectory: isDirectory,
            owner: attributes[.ownerAccountName] as? String,
            ownedByCurrentUser: ownerID.map { $0 == currentUserID } ?? true,
            posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue,
            access: access,
            isReadAtStartup: isReadAtStartup
        )
    }
}
