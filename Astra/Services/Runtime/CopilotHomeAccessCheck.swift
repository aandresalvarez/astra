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

    var path: String
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
    /// An unreadable folder whose children could not be listed: the fix must
    /// restore read access below it too, not only on the folder itself.
    var hidesChildren = false
    /// Whether Copilot writes this entry. A read-only config file is repaired
    /// with read access only, so a hardened mode stays hardened.
    var requiresWrite = true
    /// For `.wrongType`: a FIFO, socket or device where a file belongs.
    var isSpecialFile = false
    /// The Copilot home itself, whose recursive repair must stay read-only so
    /// hardened config files below it keep their mode.
    var isHome = false
    /// The file `COPILOT_PROVIDERS_CONFIG` names.
    var isProvidersOverride = false
    /// The default `providers.json` or the override: which one Copilot opens
    /// depends on the launch's environment, known only at launch.
    var isProvidersFile = false
    /// A macOS user-immutable or append-only flag blocks writes the mode bits
    /// allow; the fix clears it.
    var hasLockFlag = false
    /// False under a symlinked home ASTRA cannot vouch for (one that links to
    /// a folder the user does not own): no command is suggested there, so the
    /// fix can never chown or chmod an unrelated or system folder.
    var isRepairable = true

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
        if hasLockFlag { parts.append("locked") }
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
            let found = misshapen.isSpecialFile
                ? "a special file (FIFO, socket or device)"
                : (misshapen.isDirectory ? "a folder" : "a file")
            let expected = misshapen.isDirectory || misshapen.isSpecialFile ? "a regular file" : "a folder"
            let verb = misshapen.symlinkTarget == nil ? "is" : "links to"
            sentences.append("\(misshapen.displayPath) \(verb) \(found), but Copilot expects \(expected) there.")
        }
        if !unreadable.isEmpty {
            sentences.append("Copilot cannot read \(Self.listed(unreadable)).")
        }
        if !unwritable.isEmpty {
            sentences.append("Copilot cannot write \(Self.listed(unwritable)).")
        }
        let outside = problems.filter { $0.access == .linksOutsideHome && !$0.isProvidersOverride }
        if !outside.isEmpty {
            sentences.append("\(Self.listed(outside)) point outside the Copilot folder, so a task run under a sandboxed policy cannot read them.")
        }
        if let override = problems.first(where: { $0.access == .linksOutsideHome && $0.isProvidersOverride }) {
            sentences.append("COPILOT_PROVIDERS_CONFIG names \(override.displayPath), outside the Copilot folder, so a task run under a sandboxed policy cannot read it.")
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
        let repairable = problems.filter { $0.isRepairable && $0.symlinkTarget == nil && !$0.isMisplaced }
        // First: a locked entry refuses even a chown. Clearing another user's
        // flag needs sudo.
        // Misplaced entries too: a locked entry cannot be moved aside either.
        let locked = problems.filter { $0.isRepairable && $0.symlinkTarget == nil && $0.hasLockFlag }
        if !locked.isEmpty {
            let sudo = locked.contains { !$0.ownedByCurrentUser } ? "sudo " : ""
            commands.append("\(sudo)chflags nouchg,nouappnd \(Self.quotedPaths(locked))")
        }
        let foreign = repairable.filter { !$0.ownedByCurrentUser }
        if !foreign.isEmpty {
            // Recursive only inside the Copilot home: the parent a missing home
            // would be created in is usually the user's whole home folder.
            let recursive = foreign.contains { $0.isDirectory && $0.access != .cannotCreateHome } ? " -R" : ""
            // Owner only: changing the group too would hand the entry's group
            // bits to everyone in `staff`.
            commands.append("sudo chown\(recursive) \"$USER\" \(Self.quotedPaths(foreign))")
        }
        let withACL = repairable.filter(\.hasACL)
        if !withACL.isEmpty {
            commands.append("chmod -N \(Self.quotedPaths(withACL))")
        }
        let directories = repairable.filter(\.isDirectory)
        if !directories.isEmpty {
            commands.append("chmod u+rwx \(Self.quotedPaths(directories))")
        }
        let files = repairable.filter { !$0.isDirectory && $0.requiresWrite }
        if !files.isEmpty {
            commands.append("chmod u+rw \(Self.quotedPaths(files))")
        }
        let readOnlyFiles = repairable.filter { !$0.isDirectory && !$0.requiresWrite }
        if !readOnlyFiles.isEmpty {
            commands.append("chmod u+r \(Self.quotedPaths(readOnlyFiles))")
        }
        // Below the home: read and traverse only, so a deliberately read-only
        // config file is not loosened.
        let hidingHome = repairable.filter { $0.hidesChildren && $0.isHome }
        if !hidingHome.isEmpty {
            commands.append("chmod -R u+rX \(Self.quotedPaths(hidingHome))")
        }
        // Below a state folder (session-state): Copilot writes there, so
        // write comes back too.
        let hidingState = repairable.filter { $0.hidesChildren && !$0.isHome }
        if !hidingState.isEmpty {
            commands.append("chmod -R u+rwX \(Self.quotedPaths(hidingState))")
        }
        // Moves last: renaming an entry needs its parent repaired first.
        for misplaced in problems where misplaced.isMisplaced && misplaced.isRepairable {
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
        sentences += manualRemediation
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

    /// Advice for problems no command is suggested for.
    private var manualRemediation: [String] {
        var sentences: [String] = []
        let unvouched = problems.filter { !$0.isRepairable && $0.symlinkTarget == nil && !$0.isProvidersOverride }
        if let override = problems.first(where: { !$0.isRepairable && $0.isProvidersOverride }) {
            sentences.append("COPILOT_PROVIDERS_CONFIG names \(override.displayPath), outside the Copilot folder, so ASTRA suggests no command for it; fix it yourself or point the variable at a file you own.")
        }
        if !unvouched.isEmpty {
            let homePath = (home as NSString).abbreviatingWithTildeInPath
            sentences.append("\(homePath) links to a folder you do not own, so ASTRA suggests no command; restore access to \(Self.listed(unvouched)) yourself or point \(homePath) at a folder you own.")
        }
        if problems.contains(where: { $0.access == .linksOutsideHome && $0.isProvidersOverride }) {
            sentences.append("To use sandboxed policies, keep the providers file inside the Copilot folder.")
        }
        return sentences
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
        workingDirectory: String? = nil,
        fileManager: FileManager = .default,
        currentUserID: uid_t = getuid()
    ) -> CopilotHomeAccessReport {
        // A relative override is relative to Copilot's own working directory,
        // the task workspace, not ASTRA's.
        let providersOverride = environment[providersOverrideVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyExpandingTilde
            .map { path in
                guard !path.hasPrefix("/"), let workingDirectory, !workingDirectory.isEmpty else { return path }
                return ((workingDirectory as NSString).appendingPathComponent(path) as NSString).standardizingPath
            }
        let trimmedHome = home.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHome.isEmpty else {
            return CopilotHomeAccessReport(home: home, problems: [])
        }
        let homeIsLink = (try? fileManager.attributesOfItem(atPath: trimmedHome))?[.type] as? FileAttributeType
            == .typeSymbolicLink
        let resolvedHome = homeIsLink ? linkTarget(of: trimmedHome, fileManager: fileManager) : trimmedHome
        var problems = homeProblems(
            home: trimmedHome, resolvedHome: resolvedHome, homeIsLink: homeIsLink,
            resumeSessionID: resumeSessionID, providersOverride: providersOverride,
            fileManager: fileManager, currentUserID: currentUserID
        )
        // The override replaces the default file, so it is what must be
        // readable, whether or not the home exists yet.
        if let providersOverride {
            problems += overrideProblems(
                providersOverride, home: resolvedHome, fileManager: fileManager, currentUserID: currentUserID
            )
        }
        // Blocking entries first: they are the ones that kill the CLI.
        let ordered = problems.filter(\.blocksCopilot) + problems.filter { !$0.blocksCopilot }
        return CopilotHomeAccessReport(home: trimmedHome, problems: ordered)
    }

    private static func homeProblems(
        home trimmedHome: String,
        resolvedHome: String,
        homeIsLink: Bool,
        resumeSessionID: String?,
        providersOverride: String?,
        fileManager: FileManager,
        currentUserID: uid_t
    ) -> [CopilotHomeAccessProblem] {
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
            return [dangling]
        }
        var isDirectory: ObjCBool = false
        // A missing home is fine as long as Copilot can create it.
        guard fileManager.fileExists(atPath: resolvedHome, isDirectory: &isDirectory) else {
            let parent = creationProblem(for: trimmedHome, fileManager: fileManager, currentUserID: currentUserID)
            return parent.map { [$0] } ?? []
        }
        guard isDirectory.boolValue else {
            var problem = problem(
                at: trimmedHome, requiresWrite: true, isReadAtStartup: true,
                fileManager: fileManager, currentUserID: currentUserID, forcedAccess: .notADirectory
            )
            problem?.backupPath = unusedBackupPath(for: trimmedHome, fileManager: fileManager)
            return problem.map { [$0] } ?? []
        }
        var problems: [CopilotHomeAccessProblem] = []
        if var homeProblem = problem(
            at: resolvedHome, requiresWrite: true, isReadAtStartup: true,
            fileManager: fileManager, currentUserID: currentUserID
        ) {
            homeProblem.isHome = true
            // A linked home is the link's to fix, not its target's: the
            // target may be an unrelated or system folder (`/etc`), and a
            // recursive chown of it would be destructive.
            if homeIsLink {
                homeProblem.path = trimmedHome
                homeProblem.symlinkTarget = resolvedHome
                homeProblem.hidesChildren = false
            }
            // An unreadable home hides everything inside it, and the fix for
            // the home (a recursive chown) covers its children too. A home
            // that is only unwritable can still hide an unreadable config, so
            // its children are still checked.
            guard homeProblem.access == .unwritable else { return [homeProblem] }
            problems.append(homeProblem)
        }
        if let children = try? fileManager.contentsOfDirectory(atPath: resolvedHome) {
            let startup = effectiveStartupEntries(present: Set(children), providersOverride: providersOverride)
            let overridePath = providersOverride.map(canonicalPath)
            for child in children.sorted() {
                let path = (resolvedHome as NSString).appendingPathComponent(child)
                // The override has its own, read-only check.
                if let overridePath, canonicalPath(path) == overridePath { continue }
                if var problem = problem(
                    at: path,
                    requiresWrite: !readOnlyConfigFileNames.contains(child),
                    isReadAtStartup: startup[child] != nil,
                    expectedKind: startup[child],
                    home: resolvedHome,
                    fileManager: fileManager,
                    currentUserID: currentUserID
                ) {
                    problem.isProvidersFile = child == providersFileName
                    problems.append(problem)
                }
            }
        }
        if let sessionID = resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty, !sessionID.contains("/"), sessionID != ".", sessionID != ".." {
            let session = (resolvedHome as NSString).appendingPathComponent("session-state/\(sessionID)")
            if let problem = problem(
                at: session, requiresWrite: true, isReadAtStartup: true, expectedKind: .directory,
                home: resolvedHome, fileManager: fileManager, currentUserID: currentUserID
            ) {
                problems.append(problem)
            }
        }
        // A linked home owned by someone else may be a shared or system
        // folder: report what is wrong there, but suggest no command for it.
        let targetOwner = (try? fileManager.attributesOfItem(atPath: resolvedHome))?[.ownerAccountID] as? NSNumber
        if homeIsLink, targetOwner.map({ uid_t($0.uint32Value) != currentUserID }) ?? true {
            for index in problems.indices { problems[index].isRepairable = false }
        }
        return problems
    }

    private static func overrideProblems(
        _ override: String,
        home: String,
        fileManager: FileManager,
        currentUserID: uid_t
    ) -> [CopilotHomeAccessProblem] {
        let insideHome = canonicalPath(override).hasPrefix(canonicalPath(home) + "/")
        if var problem = problem(
            at: override, requiresWrite: false, isReadAtStartup: true, expectedKind: .file,
            fileManager: fileManager, currentUserID: currentUserID
        ) {
            problem.isProvidersOverride = true
            problem.isProvidersFile = true
            // The variable can name any file (`/etc/sudoers`); outside the
            // Copilot home no chown, chmod or move is ever suggested for it.
            problem.isRepairable = insideHome
            return [problem]
        }
        // Readable here, but a sandboxed task is granted only the Copilot
        // home. ASTRA does not widen the sandbox to it: the variable would
        // then grant the whole task read access to any file it names.
        guard !insideHome, let attributes = try? fileManager.attributesOfItem(atPath: override) else {
            return []
        }
        var outside = CopilotHomeAccessProblem(
            path: override,
            isDirectory: false,
            owner: attributes[.ownerAccountName] as? String,
            ownedByCurrentUser: true,
            posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue,
            access: .linksOutsideHome,
            isReadAtStartup: true
        )
        outside.isProvidersOverride = true
        outside.isProvidersFile = true
        return [outside]
    }

    /// The launch-time gate: the same check run with the launch's own
    /// environment (a skill can set `COPILOT_PROVIDERS_CONFIG`) and the session
    /// it resumes, neither of which the earlier readiness preflight can know.
    /// A report to fail the launch with when Copilot would exit silently, else
    /// nil; warnings stay with readiness.
    static func launchBlocker(
        home: String = CopilotCLIRuntime.defaultHome(),
        resumeSessionID: String?,
        environment: [String: String],
        workingDirectory: String?,
        fileManager: FileManager = .default
    ) -> RuntimeReadinessReport? {
        let report = inspect(
            home: home, resumeSessionID: resumeSessionID, environment: environment,
            workingDirectory: workingDirectory, fileManager: fileManager
        )
        guard report.blocksCopilot, let check = readinessCheck(for: report) else { return nil }
        return RuntimeReadinessReport(checks: [check])
    }

    /// The readiness row for a report, or nil when nothing is wrong.
    /// `providersFileBlocks: false` is for checks that run before the task's
    /// own environment exists: a skill may still point COPILOT_PROVIDERS_CONFIG
    /// at a working file, so a providers problem there is a warning and the
    /// launch gate, which knows the environment, decides.
    static func readinessCheck(
        for report: CopilotHomeAccessReport,
        providersFileBlocks: Bool = true
    ) -> RuntimeReadinessCheck? {
        guard !report.isClean else { return nil }
        let blocks = report.problems.contains { $0.blocksCopilot && (providersFileBlocks || !$0.isProvidersFile) }
        return RuntimeReadinessCheck(
            id: readinessCheckID,
            title: "Copilot settings folder",
            detail: report.cause,
            state: blocks ? .blocked : .warning,
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
        } else if let expectedKind, !matches(expectedKind, type: type) {
            access = .wrongType
        } else if Darwin.access(path, readMode) != 0 {
            access = .unreadable
        } else if requiresWrite, Darwin.access(path, W_OK) != 0 || isLocked(attributes) {
            // BSD flags override the mode bits, and `access` may not see them.
            access = .unwritable
        } else {
            return nil
        }
        let ownerID = (attributes[.ownerAccountID] as? NSNumber).map { uid_t($0.uint32Value) }
        var problem = CopilotHomeAccessProblem(
            path: path,
            isDirectory: isDirectory,
            owner: attributes[.ownerAccountName] as? String,
            ownedByCurrentUser: ownerID.map { $0 == currentUserID } ?? true,
            posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue,
            access: access,
            isReadAtStartup: isReadAtStartup
        )
        // An ACL is blamed (and removed by the fix) only when the owner's mode
        // bits already allow the access that failed; otherwise the mode bits
        // are the cause, and a legitimate sharing ACL is left alone.
        problem.hasACL = problem.ownedByCurrentUser
            && ownerBitsAllow(access, isDirectory: isDirectory, mode: problem.posixPermissions)
            && hasExtendedACL(path)
        problem.requiresWrite = requiresWrite
        // A locked entry refuses writes, and a move aside as well.
        problem.hasLockFlag = isLocked(attributes)
            && (requiresWrite || access == .notADirectory || access == .wrongType)
        problem.isSpecialFile = !isDirectory && type != .typeRegular
        // An unreadable folder hides what is inside it, so its repair must
        // reach below it (a resumed session under session-state, say).
        problem.hidesChildren = isDirectory && access == .unreadable
        if problem.isMisplaced {
            problem.backupPath = unusedBackupPath(for: path, fileManager: fileManager)
        }
        return problem
    }

    private static func isLocked(_ attributes: [FileAttributeKey: Any]) -> Bool {
        attributes[.immutable] as? Bool == true || attributes[.appendOnly] as? Bool == true
    }

    private static func ownerBitsAllow(
        _ access: CopilotHomeAccessProblem.Access,
        isDirectory: Bool,
        mode: Int?
    ) -> Bool {
        guard let mode else { return false }
        let traverse = isDirectory ? 0o100 : 0
        switch access {
        case .unreadable: return mode & (0o400 | traverse) == (0o400 | traverse)
        case .unwritable: return mode & (0o200 | traverse) == (0o200 | traverse)
        default: return false
        }
    }

    /// Copilot reads a `.file` entry as JSON or SQLite, so only a regular
    /// file will do; a FIFO, socket or device would hang or fail the read.
    private static func matches(_ kind: EntryKind, type: FileAttributeType?) -> Bool {
        switch kind {
        case .directory: return type == .typeDirectory
        case .file: return type == .typeRegular
        }
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
        // `attributesOfItem` on the canonical path describes the real target.
        let targetAttributes = try? fileManager.attributesOfItem(atPath: canonicalPath(path))
        let targetType = targetAttributes?[.type] as? FileAttributeType
        let access: CopilotHomeAccessProblem.Access
        if targetExists, let expectedKind, !matches(expectedKind, type: targetType) {
            access = .wrongType
        } else if !targetExists || Darwin.access(path, readMode) != 0 {
            access = .unreadable
        } else if let home, !canonicalPath(path).hasPrefix(canonicalPath(home) + "/") {
            // Canonical on both sides, so an intermediate link out of the home
            // counts. ASTRA does not widen the sandbox to follow it: a link
            // would then grant a task read access to whatever it points at.
            access = .linksOutsideHome
        } else if requiresWrite, Darwin.access(path, W_OK) != 0 || isLocked(targetAttributes ?? [:]) {
            access = .unwritable
        } else {
            return nil
        }
        var problem = CopilotHomeAccessProblem(
            path: path,
            isDirectory: isDirectory.boolValue,
            owner: nil,
            ownedByCurrentUser: true,
            posixPermissions: nil,
            access: access,
            isReadAtStartup: true,
            symlinkTarget: target
        )
        problem.isSpecialFile = targetExists && !isDirectory.boolValue && targetType != .typeRegular
        problem.hasLockFlag = access == .unwritable && isLocked(targetAttributes ?? [:])
        return problem
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
