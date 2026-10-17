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
        /// The state home is missing and `path`, its nearest existing parent,
        /// does not let the user create it.
        case cannotCreateHome
        /// A startup entry is a folder where Copilot expects a file, or the
        /// other way round.
        case wrongType
        /// The state home is a symlink to nothing (or a link loop): Copilot
        /// cannot create a folder through it, because the link itself exists.
        case danglingLink
        /// A startup entry links outside the Copilot home. Readable here, but a
        /// sandboxed task is granted only `~/.copilot` and cannot follow it.
        case linksOutsideHome
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
    /// An extended ACL can deny access the mode bits allow, so restoring mode
    /// bits alone would leave the entry broken.
    var hasACL = false
    /// Set when `path` is a symlink: Copilot follows it, so the target is what
    /// must be readable, and ASTRA never suggests changing a file outside the
    /// Copilot home.
    var symlinkTarget: String?
    /// For `.notADirectory` and `.wrongType`: an unused name to move the
    /// entry aside to.
    var backupPath: String?
    /// For `.danglingLink`: the link ends in a loop rather than a missing path.
    var isLinkLoop = false
    /// An unreadable home whose children could not be listed: the fix must
    /// restore read access below it too, not only on the home itself.
    var hidesChildren = false

    /// Fixed by moving the entry aside rather than by changing permissions.
    var isMisplaced: Bool {
        access == .danglingLink || ((access == .notADirectory || access == .wrongType) && symlinkTarget == nil)
    }

    /// Kills every Copilot turn before it prints a byte.
    var blocksCopilot: Bool {
        switch access {
        case .notADirectory, .cannotCreateHome, .wrongType, .danglingLink: return true
        case .unreadable: return isReadAtStartup
        case .unwritable, .linksOutsideHome: return false
        }
    }

    var displayPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    var detail: String {
        if let symlinkTarget {
            return "a link to \((symlinkTarget as NSString).abbreviatingWithTildeInPath)"
        }
        var parts: [String] = []
        if let owner { parts.append("owned by \(owner)") }
        if let posixPermissions { parts.append("mode \(String(posixPermissions & 0o777, radix: 8))") }
        if hasACL { parts.append("with an ACL") }
        return parts.joined(separator: ", ")
    }

    var describedPath: String {
        detail.isEmpty ? displayPath : "\(displayPath) (\(detail))"
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

    /// What is wrong, e.g. "Copilot cannot read ~/.copilot/config.json
    /// (owned by root, mode 600)."
    var cause: String {
        guard !problems.isEmpty else { return "" }
        if let misplaced = problems.first(where: { $0.access == .notADirectory }) {
            return "\(misplaced.displayPath) is a file, not a folder, so Copilot has nowhere to keep its settings."
        }
        if let dangling = problems.first(where: { $0.access == .danglingLink }) {
            let why = dangling.isLinkLoop ? "which loops back on itself" : "which does not exist"
            return "\(dangling.displayPath) is \(dangling.detail), \(why), so Copilot cannot create its settings folder."
        }
        if let parent = problems.first(where: { $0.access == .cannotCreateHome }) {
            let homePath = (home as NSString).abbreviatingWithTildeInPath
            return "Copilot cannot create \(homePath) because \(parent.describedPath) is not writable."
        }
        let unreadable = problems.filter { $0.access == .unreadable }
        let unwritable = problems.filter { $0.access == .unwritable }
        var sentences: [String] = []
        for misshapen in problems where misshapen.access == .wrongType {
            let found = misshapen.isDirectory ? "a folder" : "a file"
            let expected = misshapen.isDirectory ? "a file" : "a folder"
            let verb = misshapen.symlinkTarget == nil ? "is" : "links to"
            sentences.append("\(misshapen.displayPath) \(verb) \(found), but Copilot expects \(expected) there.")
        }
        if !unreadable.isEmpty {
            sentences.append("Copilot cannot read \(Self.listed(unreadable)).")
        }
        if !unwritable.isEmpty {
            sentences.append("Copilot cannot write \(Self.listed(unwritable)).")
        }
        let outside = problems.filter { $0.access == .linksOutsideHome }
        if !outside.isEmpty {
            sentences.append("\(Self.listed(outside)) point outside the Copilot folder, so a task run under a sandboxed policy cannot read them.")
        }
        if problems.contains(where: { !$0.ownedByCurrentUser && $0.symlinkTarget == nil }) {
            sentences.append("This usually happens after Copilot was run with sudo.")
        }
        return sentences.joined(separator: " ")
    }

    /// A Terminal command that restores access, or "" when nothing inside the
    /// Copilot home can be repaired by one. Entries owned by someone else
    /// (usually root) get their ownership back first; ACLs are removed next;
    /// then every entry gets its owner permission bits back, because a chown
    /// alone leaves a mode-000 file just as unreadable as before.
    var fixCommand: String {
        var commands: [String] = []
        let repairable = problems.filter { $0.symlinkTarget == nil && !$0.isMisplaced }
        let foreign = repairable.filter { !$0.ownedByCurrentUser }
        if !foreign.isEmpty {
            // Recursive only inside the Copilot home: the parent a missing home
            // would be created in is usually the user's whole home folder.
            let recursive = foreign.contains { $0.isDirectory && $0.access != .cannotCreateHome } ? " -R" : ""
            commands.append("sudo chown\(recursive) \"$USER\":staff \(Self.quotedPaths(foreign))")
        }
        let withACL = repairable.filter(\.hasACL)
        if !withACL.isEmpty {
            commands.append("chmod -N \(Self.quotedPaths(withACL))")
        }
        let directories = repairable.filter(\.isDirectory)
        if !directories.isEmpty {
            commands.append("chmod u+rwx \(Self.quotedPaths(directories))")
        }
        let files = repairable.filter { !$0.isDirectory }
        if !files.isEmpty {
            commands.append("chmod u+rw \(Self.quotedPaths(files))")
        }
        // Read and traverse only: write stays as the user set it, so a
        // deliberately read-only config file is not loosened.
        let hiding = repairable.filter(\.hidesChildren)
        if !hiding.isEmpty {
            commands.append("chmod -R u+rX \(Self.quotedPaths(hiding))")
        }
        // Moves last: renaming an entry needs its parent repaired first.
        for misplaced in problems where misplaced.isMisplaced {
            let backup = misplaced.backupPath ?? misplaced.path + ".bak"
            // `-n` so an earlier backup is never overwritten.
            commands.append("mv -n \(Self.quoted(misplaced.path)) \(Self.quoted(backup))")
        }
        return commands.joined(separator: " && ")
    }

    /// How to fix it: the command, plus what to restore for a symlinked entry
    /// whose target lives outside the Copilot home.
    var remediation: String {
        var sentences: [String] = []
        let command = fixCommand
        if !command.isEmpty {
            sentences.append("Run `\(command)` in Terminal.")
        }
        for linked in problems where linked.symlinkTarget != nil && !linked.isMisplaced {
            if linked.access == .wrongType {
                sentences.append("Replace the link at \(linked.displayPath).")
                continue
            }
            if linked.access == .linksOutsideHome {
                sentences.append("To use sandboxed policies, replace the link at \(linked.displayPath) with a copy of the file.")
                continue
            }
            let target = ((linked.symlinkTarget ?? "") as NSString).abbreviatingWithTildeInPath
            let ability = linked.access == .unwritable ? "writable" : "readable"
            sentences.append("Make \(target) \(ability) again, or replace the link at \(linked.displayPath).")
        }
        return sentences.joined(separator: " ")
    }

    /// Cause plus fix, for blocker text.
    var userMessage: String {
        guard !problems.isEmpty else { return "" }
        return "\(cause) \(remediation) Then retry."
    }

    /// Paths for the explanation, capped so a whole root-owned tree stays
    /// readable. The fix command always covers every problem.
    private static func listed(_ problems: [CopilotHomeAccessProblem]) -> String {
        let shown = problems.prefix(CopilotHomeAccessCheck.maximumListedProblems).map(\.describedPath)
        let hidden = problems.count - shown.count
        return (shown + (hidden > 0 ? ["and \(hidden) more"] : [])).joined(separator: ", ")
    }

    private static func quoted(_ path: String) -> String {
        RuntimeRemediationCatalog.shellQuoted(path)
    }

    private static func quotedPaths(_ problems: [CopilotHomeAccessProblem]) -> String {
        problems.map { quoted($0.path) }.joined(separator: " ")
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
    /// Keeps blocker text readable when a whole tree went root-owned. Only the
    /// explanation is capped; the fix command repairs every problem.
    static let maximumListedProblems = 5

    /// Config files Copilot only reads during a task. ASTRA already denies
    /// task-side writes to them (`configWriteDenyPaths`), so a user who made
    /// them read-only has a working, hardened setup, not a broken one.
    static let readOnlyConfigFileNames: Set<String> = Set(
        CopilotCLIRuntime.configWriteDenyPaths(userHome: "/").map { ($0 as NSString).lastPathComponent }
    )

    enum EntryKind: Sendable { case file, directory }

    /// Top-level entries of a Copilot CLI 1.0.x home that hold its config or
    /// session state, and the type Copilot needs each to be. Only these can
    /// block a launch; anything else in the folder (backups, caches, other
    /// tools' files) is at most a warning. `settings.json` is not here:
    /// Copilot ignores an unreadable one with a startup warning.
    static let startupEntries: [String: EntryKind] = readOnlyConfigFileNames
        .reduce(into: [
            // The user-level provider and model registry BYOK models read.
            providersFileName: .file,
            "permissions-config.json": .file,
            // The extensionless name older CLI releases used; read only when
            // `permissions-config.json` does not exist.
            "permissions-config": .file,
            "session-state": .directory,
            "session-store.db": .file,
            "session-store.db-wal": .file,
            "session-store.db-shm": .file
        ]) { entries, name in entries[name] = .file }

    static let providersFileName = "providers.json"
    /// Replaces `~/.copilot/providers.json` when set in Copilot's environment.
    static let providersOverrideVariable = "COPILOT_PROVIDERS_CONFIG"

    /// The startup entries Copilot will actually open for this home and
    /// environment, following its own fallback rules.
    static func effectiveStartupEntries(
        present children: Set<String>,
        providersOverride: String?
    ) -> [String: EntryKind] {
        var entries = startupEntries
        if children.contains("permissions-config.json") {
            entries["permissions-config"] = nil
        }
        if providersOverride != nil {
            entries[providersFileName] = nil
        }
        return entries
    }

    static let readinessCheckID = "copilot-home-access"

    /// `resumeSessionID`, when the turn resumes a native Copilot session, adds
    /// that one `session-state/<id>` folder to the check; the rest of the
    /// session history is not walked.
    static func inspect(
        home: String = CopilotCLIRuntime.defaultHome(),
        resumeSessionID: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        currentUserID: uid_t = getuid()
    ) -> CopilotHomeAccessReport {
        let providersOverride = environment[providersOverrideVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyExpandingTilde
        let trimmedHome = home.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHome.isEmpty else {
            return CopilotHomeAccessReport(home: home, problems: [])
        }
        // A symlinked home is used through its target, so the target is what
        // must be a writable folder.
        let homeIsLink = (try? fileManager.attributesOfItem(atPath: trimmedHome))?[.type] as? FileAttributeType
            == .typeSymbolicLink
        let resolvedHome = homeIsLink ? linkTarget(of: trimmedHome, fileManager: fileManager) : trimmedHome
        // `fileExists` follows links, so it is false for a link to nothing and
        // for a link loop alike.
        if homeIsLink, !fileManager.fileExists(atPath: trimmedHome),
           var dangling = problem(
               at: trimmedHome, requiresWrite: true, isReadAtStartup: true,
               fileManager: fileManager, currentUserID: currentUserID, forcedAccess: .danglingLink
           ) {
            dangling.symlinkTarget = resolvedHome
            dangling.isLinkLoop = (try? fileManager.attributesOfItem(atPath: resolvedHome))?[.type] as? FileAttributeType
                == .typeSymbolicLink
            dangling.backupPath = unusedBackupPath(for: trimmedHome, fileManager: fileManager)
            return CopilotHomeAccessReport(home: trimmedHome, problems: [dangling])
        }
        var isDirectory: ObjCBool = false
        // A missing home is fine as long as Copilot can create it.
        guard fileManager.fileExists(atPath: resolvedHome, isDirectory: &isDirectory) else {
            let parent = creationProblem(for: trimmedHome, fileManager: fileManager, currentUserID: currentUserID)
            return CopilotHomeAccessReport(home: trimmedHome, problems: parent.map { [$0] } ?? [])
        }
        var problems: [CopilotHomeAccessProblem] = []
        guard isDirectory.boolValue else {
            var problem = problem(
                at: trimmedHome, requiresWrite: true, isReadAtStartup: true,
                fileManager: fileManager, currentUserID: currentUserID, forcedAccess: .notADirectory
            )
            problem?.backupPath = unusedBackupPath(for: trimmedHome, fileManager: fileManager)
            return CopilotHomeAccessReport(home: trimmedHome, problems: problem.map { [$0] } ?? [])
        }
        if let homeProblem = problem(
            at: resolvedHome, requiresWrite: true, isReadAtStartup: true,
            fileManager: fileManager, currentUserID: currentUserID
        ) {
            // An unreadable home hides everything inside it, and the fix for
            // the home (a recursive chown) covers its children too. A home
            // that is only unwritable can still hide an unreadable config, so
            // its children are still checked.
            guard homeProblem.access == .unwritable else {
                var hiding = homeProblem
                hiding.hidesChildren = hiding.isDirectory
                return CopilotHomeAccessReport(home: trimmedHome, problems: [hiding])
            }
            problems.append(homeProblem)
        }
        guard let children = try? fileManager.contentsOfDirectory(atPath: resolvedHome) else {
            return CopilotHomeAccessReport(home: trimmedHome, problems: problems)
        }
        let startup = effectiveStartupEntries(present: Set(children), providersOverride: providersOverride)
        for child in children.sorted() {
            let path = (resolvedHome as NSString).appendingPathComponent(child)
            if var problem = problem(
                at: path,
                requiresWrite: !readOnlyConfigFileNames.contains(child),
                isReadAtStartup: startup[child] != nil,
                expectedKind: startup[child],
                home: resolvedHome,
                fileManager: fileManager,
                currentUserID: currentUserID
            ) {
                if problem.isMisplaced {
                    problem.backupPath = unusedBackupPath(for: path, fileManager: fileManager)
                }
                problems.append(problem)
            }
        }
        if let sessionID = resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty, !sessionID.contains("/"), sessionID != ".", sessionID != ".." {
            let session = (resolvedHome as NSString).appendingPathComponent("session-state/\(sessionID)")
            if let problem = problem(
                at: session, requiresWrite: true, isReadAtStartup: true, expectedKind: .directory,
                fileManager: fileManager, currentUserID: currentUserID
            ) {
                problems.append(problem)
            }
        }
        // The override replaces the default file, so it is what must be readable.
        if let providersOverride, let problem = problem(
            at: providersOverride, requiresWrite: false, isReadAtStartup: true, expectedKind: .file,
            fileManager: fileManager, currentUserID: currentUserID
        ) {
            problems.append(problem)
        }
        // Blocking entries first: they are the ones that kill the CLI.
        let ordered = problems.filter(\.blocksCopilot) + problems.filter { !$0.blocksCopilot }
        return CopilotHomeAccessReport(home: trimmedHome, problems: ordered)
    }

    /// The readiness row for a report, or nil when nothing is wrong.
    static func readinessCheck(for report: CopilotHomeAccessReport) -> RuntimeReadinessCheck? {
        guard !report.isClean else { return nil }
        return RuntimeReadinessCheck(
            id: readinessCheckID,
            title: "Copilot settings folder",
            detail: report.cause,
            state: report.blocksCopilot ? .blocked : .warning,
            remediation: report.remediation
        )
    }

    /// The nearest existing parent of a missing home, when it does not let
    /// the user create folders in it. `AgentRuntimeProcessRunner` ignores a
    /// failed `createDirectory`, so without this the CLI would be launched
    /// with no usable home.
    private static func creationProblem(
        for home: String,
        fileManager: FileManager,
        currentUserID: uid_t
    ) -> CopilotHomeAccessProblem? {
        var parent = (home as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        while !parent.isEmpty, parent != "/", !fileManager.fileExists(atPath: parent, isDirectory: &isDirectory) {
            parent = (parent as NSString).deletingLastPathComponent
        }
        guard !parent.isEmpty, isDirectory.boolValue || parent == "/",
              Darwin.access(parent, W_OK | X_OK) != 0 else {
            return nil
        }
        return problem(
            at: parent, requiresWrite: true, isReadAtStartup: true,
            fileManager: fileManager, currentUserID: currentUserID, forcedAccess: .cannotCreateHome
        )
    }

    /// `<home>.bak`, or the first `<home>.bak-N` that does not exist yet.
    private static func unusedBackupPath(for path: String, fileManager: FileManager) -> String {
        func exists(_ candidate: String) -> Bool {
            // `attributesOfItem` also sees a dangling symlink, which `mv` would replace.
            (try? fileManager.attributesOfItem(atPath: candidate)) != nil
        }
        let base = path + ".bak"
        guard exists(base) else { return base }
        var index = 2
        while exists("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }

    /// Whether the entry itself (not a link target) carries an extended ACL.
    private static func hasExtendedACL(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }

    private static func problem(
        at path: String,
        requiresWrite: Bool,
        isReadAtStartup: Bool,
        expectedKind: EntryKind? = nil,
        home: String? = nil,
        fileManager: FileManager,
        currentUserID: uid_t,
        forcedAccess: CopilotHomeAccessProblem.Access? = nil
    ) -> CopilotHomeAccessProblem? {
        // `attributesOfItem` does not follow symlinks.
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return nil }
        let type = attributes[.type] as? FileAttributeType
        // A forced verdict is about the entry itself, link or not.
        if type == .typeSymbolicLink, forcedAccess == nil {
            return symlinkProblem(
                at: path, requiresWrite: requiresWrite, isReadAtStartup: isReadAtStartup,
                expectedKind: expectedKind, home: home, fileManager: fileManager
            )
        }
        let isDirectory = type == .typeDirectory
        let readMode = isDirectory ? (R_OK | X_OK) : R_OK
        let access: CopilotHomeAccessProblem.Access
        if let forcedAccess {
            access = forcedAccess
        } else if let expectedKind, isDirectory != (expectedKind == .directory) {
            access = .wrongType
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
            isReadAtStartup: isReadAtStartup,
            hasACL: hasExtendedACL(path)
        )
    }

    /// Copilot follows a symlinked startup entry, so its target must be
    /// readable. Only reading is checked: the target lives outside the
    /// Copilot home, and its write access is the user's own choice.
    private static func symlinkProblem(
        at path: String,
        requiresWrite: Bool,
        isReadAtStartup: Bool,
        expectedKind: EntryKind?,
        home: String?,
        fileManager: FileManager
    ) -> CopilotHomeAccessProblem? {
        guard isReadAtStartup else { return nil }
        var isDirectory: ObjCBool = false
        let targetExists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        let readMode = isDirectory.boolValue ? (R_OK | X_OK) : R_OK
        let target = linkTarget(of: path, fileManager: fileManager)
        let access: CopilotHomeAccessProblem.Access
        if targetExists, let expectedKind, isDirectory.boolValue != (expectedKind == .directory) {
            access = .wrongType
        } else if !targetExists || Darwin.access(path, readMode) != 0 {
            access = .unreadable
        } else if let home, !canonicalPath(path).hasPrefix(canonicalPath(home) + "/") {
            // Canonical on both sides, so an intermediate link out of the home
            // counts. ASTRA does not widen the sandbox to follow it: a link
            // would then grant a task read access to whatever it points at.
            access = .linksOutsideHome
        } else if requiresWrite, Darwin.access(path, W_OK) != 0 {
            access = .unwritable
        } else {
            return nil
        }
        return CopilotHomeAccessProblem(
            path: path,
            isDirectory: isDirectory.boolValue,
            owner: nil,
            ownedByCurrentUser: true,
            posixPermissions: nil,
            access: access,
            isReadAtStartup: true,
            symlinkTarget: target
        )
    }

    /// The fully resolved path, every intermediate link included, as the
    /// kernel and the sandbox see it; the standardized path when it does not
    /// resolve.
    private static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Where a symlink finally points, following up to eight hops. Absolute,
    /// standardized, but `/var` is not rewritten to `/private/var`.
    private static func linkTarget(of path: String, fileManager: FileManager) -> String {
        var current = path
        for _ in 0..<8 {
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: current) else { break }
            current = destination.hasPrefix("/")
                ? destination
                : ((current as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
        }
        return (current as NSString).standardizingPath
    }
}

private extension String {
    /// nil for an empty value, else the path with a leading `~` expanded.
    var nonEmptyExpandingTilde: String? {
        isEmpty ? nil : (self as NSString).expandingTildeInPath
    }
}
