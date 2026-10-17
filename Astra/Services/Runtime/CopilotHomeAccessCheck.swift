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
    /// A deny-delete ACL on this misplaced entry would refuse the move; the
    /// fix removes it (the entry is being set aside anyway).
    var moveDeniedByOwnACL = false
    /// A deny-delete_child ACL on the folder holding this misplaced entry.
    /// That folder's ACLs may be deliberate, so this is advice only.
    var moveDeniedByParentACL = false
    /// The entry does not exist or cannot be reached at all (a missing
    /// COPILOT_PROVIDERS_CONFIG target).
    var isMissing = false
    /// For `.cannotCreateHome`: the nearest existing ancestor is a file, so
    /// no permission change can make room for the home.
    var ancestorIsFile = false
    /// For `.danglingLink`: the link ends in a loop rather than a missing path.
    var isLinkLoop = false
    /// An unreadable folder whose children could not be listed. The fix
    /// repairs the folder alone, never recursively (what is inside was not
    /// inspected and may hold hard links), and the next check looks inside.
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
    /// For `.linksOutsideHome`: the canonical file Copilot actually reads,
    /// judged against the launch's sandbox boundary.
    var readPath: String?
    /// A file with other hard links: chown and chmod act on the shared inode,
    /// so they would change every other name for it too. Advice only.
    var hasOtherHardLinks = false
    /// `path` is itself a symlink. chmod and chown follow links, so no such
    /// command is ever generated for it; only `chflags -h` and `mv` act on it.
    var pathIsLink = false
    /// The symlink itself (not its target) carries a user lock, so it cannot
    /// be replaced until `chflags -h` unlocks it.
    var linkIsLocked = false
    /// A system lock (schg/sappnd): only root can clear it, sometimes only
    /// from recovery, so the fix never tries; the user is told instead.
    var hasSystemLockFlag = false
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
        if isMissing { return "missing" }
        if hasLockFlag { parts.append("locked") }
        if hasSystemLockFlag { parts.append("system-locked") }
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
    /// The sandbox boundary the launch really applies. An entry Copilot reads
    /// from outside its home blocks only when this boundary would deny it.
    var sandboxReceipt: ExecutionSandboxBoundaryReceipt?

    var isClean: Bool { problems.isEmpty }

    func blocks(_ problem: CopilotHomeAccessProblem) -> Bool {
        if problem.blocksCopilot { return true }
        guard problem.access == .linksOutsideHome, let sandboxReceipt else { return false }
        let path = problem.readPath ?? problem.path
        if sandboxReceipt.explains(RuntimeSandboxFileDenial(operation: .read, path: path, detail: "")) { return true }
        // A state entry Copilot writes (session-state, session-store.db) must
        // also be writable under the boundary, or its first update fails.
        return problem.requiresWrite
            && sandboxReceipt.explains(RuntimeSandboxFileDenial(operation: .write, path: path, detail: ""))
    }

    /// An unreadable startup entry kills every Copilot turn before it prints
    /// a byte. An unwritable one may only fail when Copilot saves state, and an
    /// unreadable one it never opens does not fail at all, so both are
    /// warnings, not launch blockers.
    var blocksCopilot: Bool {
        problems.contains(where: blocks)
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
        if let parent = problems.first(where: { $0.access == .cannotCreateHome && $0.ancestorIsFile }) {
            let homePath = (home as NSString).abbreviatingWithTildeInPath
            return "Copilot cannot create \(homePath) because \(parent.displayPath) is a file, not a folder; move or rename it yourself."
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
        let repairable = problems.filter {
            $0.isRepairable && $0.symlinkTarget == nil && !$0.pathIsLink && !$0.isMisplaced
        }
        // First: a locked entry refuses even a chown, and a move aside too, so
        // misplaced entries (a dangling home link among them) are unlocked
        // here as well. `-h` acts on a link itself, never on what it points
        // to. Clearing another user's flag needs sudo.
        let locked = problems.filter {
            $0.isRepairable && $0.hasLockFlag && ($0.symlinkTarget == nil || $0.isMisplaced)
        }
        // A broken startup link the user must replace is unlocked too.
        let lockedLinks = problems.filter { $0.isRepairable && $0.linkIsLocked && !locked.contains($0) }
        if !(locked + lockedLinks).isEmpty {
            let sudo = (locked + lockedLinks).contains { !$0.ownedByCurrentUser } ? "sudo " : ""
            commands.append("\(sudo)chflags -h nouchg,nouappnd \(Self.quotedPaths(locked + lockedLinks))")
        }
        // Never recursive: what lies below a folder was not inspected (it may
        // hold hard links to files elsewhere), so only the entries reported
        // here are changed, and the next check looks inside.
        let foreign = repairable.filter { !$0.ownedByCurrentUser }
        if !foreign.isEmpty {
            // Owner only: changing the group too would hand the entry's group
            // bits to everyone in `staff`.
            commands.append("sudo chown \"$USER\" \(Self.quotedPaths(foreign))")
        }
        let withACL = repairable.filter(\.hasACL)
        if !withACL.isEmpty {
            commands.append("chmod -N \(Self.quotedPaths(withACL))")
        }
        // Write comes back only where Copilot writes: the home, its state
        // folders and the folder a missing home is created in. Any other
        // folder gets read and search back, so read-only content stays so.
        let mutableDirectories = repairable.filter { $0.isDirectory && Self.isMutableFolder($0) }
        if !mutableDirectories.isEmpty {
            commands.append("chmod u+rwx \(Self.quotedPaths(mutableDirectories))")
        }
        let otherDirectories = repairable.filter { $0.isDirectory && !Self.isMutableFolder($0) }
        if !otherDirectories.isEmpty {
            commands.append("chmod u+rx \(Self.quotedPaths(otherDirectories))")
        }
        let files = repairable.filter { !$0.isDirectory && $0.requiresWrite }
        if !files.isEmpty {
            commands.append("chmod u+rw \(Self.quotedPaths(files))")
        }
        let readOnlyFiles = repairable.filter { !$0.isDirectory && !$0.requiresWrite }
        if !readOnlyFiles.isEmpty {
            commands.append("chmod u+r \(Self.quotedPaths(readOnlyFiles))")
        }
        let unlockedForMove = problems.filter { $0.isMisplaced && $0.isRepairable && $0.moveDeniedByOwnACL }
        if !unlockedForMove.isEmpty {
            commands.append("chmod -h -N \(Self.quotedPaths(unlockedForMove))")
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
        if let blocked = problems.first(where: { $0.isMisplaced && $0.moveDeniedByParentACL }) {
            let folder = ((blocked.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
            sentences.append("An ACL on \(folder) forbids removing entries from it, so moving \(blocked.displayPath) aside will fail until you change that ACL.")
        }
        let hardLinked = problems.filter(\.hasOtherHardLinks)
        if !hardLinked.isEmpty {
            sentences.append("\(Self.listed(hardLinked)) also exist under another name (hard links), so changing them would change those too; ASTRA suggests no command for them.")
        }
        let systemLocked = problems.filter(\.hasSystemLockFlag)
        if !systemLocked.isEmpty {
            sentences.append("\(Self.listed(systemLocked)) carry a system lock flag (schg or sappnd), which only an administrator can clear; ASTRA suggests no command for it.")
        }
        let unvouched = problems.filter {
            !$0.isRepairable && $0.symlinkTarget == nil && !$0.isProvidersOverride
                && !$0.hasSystemLockFlag && !$0.hasOtherHardLinks
        }
        if let override = problems.first(where: { !$0.isRepairable && $0.isProvidersOverride }) {
            sentences.append("COPILOT_PROVIDERS_CONFIG names \(override.displayPath), which is not in a Copilot folder ASTRA manages, so ASTRA suggests no command for it; fix it yourself or point the variable at a file you own.")
        }
        if !unvouched.isEmpty {
            let homePath = (home as NSString).abbreviatingWithTildeInPath
            sentences.append("\(homePath) links to a folder you do not own, so ASTRA suggests no command; restore access to \(Self.listed(unvouched)) yourself or point \(homePath) at a folder you own.")
        }
        if let hiding = problems.first(where: { $0.hidesChildren && $0.isRepairable }) {
            sentences.append("Entries inside \(hiding.displayPath) could not be checked; once it is readable ASTRA checks them and suggests anything still needed.")
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

    private static func isMutableFolder(_ problem: CopilotHomeAccessProblem) -> Bool {
        problem.isHome || problem.access == .cannotCreateHome || (problem.isReadAtStartup && problem.requiresWrite)
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
    /// The stop reason when the launch is refused before Copilot starts.
    static let launchStopReason = "runtime_readiness_failed"

    /// `resumeSessionID`, when the turn resumes a native Copilot session, adds
    /// that one `session-state/<id>` folder to the check; the rest of the
    /// session history is not walked.
    static func inspect(
        home: String = CopilotCLIRuntime.defaultHome(),
        resumeSessionID: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: String? = nil,
        sandboxReceipt: ExecutionSandboxBoundaryReceipt? = nil,
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
        // A home reached through a link may land in a folder the sandbox does
        // not grant (it drops broad roots such as /Applications); then Copilot
        // cannot read even its config there.
        let reachedIndirectly = homeIsLink || hasAncestorLink(trimmedHome, fileManager: fileManager)
        if let sandboxReceipt, reachedIndirectly,
           sandboxReceipt.explains(RuntimeSandboxFileDenial(
               operation: .read, path: canonicalPath(resolvedHome), detail: ""
           )) || sandboxReceipt.explains(RuntimeSandboxFileDenial(
               // Copilot writes its session state there too.
               operation: .write, path: canonicalPath(resolvedHome), detail: ""
           )) {
            var unreachable = CopilotHomeAccessProblem(
                path: trimmedHome, isDirectory: true, owner: nil, ownedByCurrentUser: true,
                posixPermissions: nil, access: .linksOutsideHome, isReadAtStartup: true,
                symlinkTarget: canonicalPath(resolvedHome)
            )
            unreachable.readPath = canonicalPath(resolvedHome)
            unreachable.pathIsLink = homeIsLink
            problems.append(unreachable)
        }
        // One rule decides where a command may be suggested, after every
        // branch has reported: only inside a Copilot home ASTRA trusts (a real
        // folder, or a link to one the user owns), plus the home entry itself
        // and the parent a missing home would be created in. Anything else,
        // a linked system folder or an override naming `/etc/sudoers`, is
        // reported with advice only.
        // The fully resolved target, every hop and intermediate link included:
        // trust is never decided from a partially resolved chain.
        let targetOwner = (try? fileManager.attributesOfItem(atPath: canonicalPath(resolvedHome)))?[.ownerAccountID] as? NSNumber
        // A link anywhere on the way counts, not only the final `.copilot`
        // (a `/Users/alice` that links to someone else's folder, say).
        let homeTrusted = !reachedIndirectly || targetOwner.map { uid_t($0.uint32Value) == currentUserID } ?? false
        let homeParentPath = canonicalPath((trimmedHome as NSString).deletingLastPathComponent)
        let parentOwner = (try? fileManager.attributesOfItem(atPath: homeParentPath))?[.ownerAccountID] as? NSNumber
        let parentTrusted = !hasAncestorLink(trimmedHome, fileManager: fileManager)
            || parentOwner.map { uid_t($0.uint32Value) == currentUserID } ?? false
        let trustedRoot = canonicalPath(resolvedHome)
        // The providers override never gets a command: it can name any path,
        // the home itself included, and the fix there is the variable.
        let homeParent = (trimmedHome as NSString).deletingLastPathComponent
        for index in problems.indices {
            let problem = problems[index]
            let entry = canonicalEntryPath(problem.path)
            let inside = homeTrusted && (entry == trustedRoot || entry.hasPrefix(trustedRoot + "/"))
            // The home entry itself (moved aside when malformed) only when the
            // folder it sits in is trusted: through a linked ancestor it may
            // sit in someone else's tree.
            let isHomeEntry = problem.path == trimmedHome && problem.access != .cannotCreateHome && parentTrusted
            // Only the direct, user-owned parent: never a shared ancestor such
            // as /Users when the user's own home is missing.
            let isOwnedHomeParent = problem.access == .cannotCreateHome
                && problem.path == homeParent && problem.ownedByCurrentUser
            if problem.isProvidersOverride || problem.hasOtherHardLinks || !(inside || isHomeEntry || isOwnedHomeParent) {
                problems[index].isRepairable = false
            }
        }
        var report = CopilotHomeAccessReport(home: trimmedHome, problems: problems)
        report.sandboxReceipt = sandboxReceipt
        // Blocking entries first: they are the ones that kill the CLI.
        let ordered = problems.filter(report.blocks) + problems.filter { !report.blocks($0) }
        var orderedReport = CopilotHomeAccessReport(home: trimmedHome, problems: ordered)
        orderedReport.sandboxReceipt = sandboxReceipt
        return orderedReport
    }

    /// Whether any folder above `path` is a symlink, ignoring the system's own
    /// top-level links (`/var`, `/tmp`, `/etc` point into `/private`).
    private static func hasAncestorLink(_ path: String, fileManager: FileManager) -> Bool {
        var current = (path as NSString).deletingLastPathComponent
        while !current.isEmpty, current != "/" {
            let parent = (current as NSString).deletingLastPathComponent
            var info = stat()
            if lstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK,
               !(parent == "/" && info.st_uid == 0) {
                return true
            }
            current = parent
        }
        return false
    }

    /// The canonical path of an entry's folder plus its own name: a link is
    /// placed where it sits, not where it points.
    private static func canonicalEntryPath(_ path: String) -> String {
        let parent = canonicalPath((path as NSString).deletingLastPathComponent)
        return (parent as NSString).appendingPathComponent((path as NSString).lastPathComponent)
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
            // Moving it aside needs write and search on its parent.
            let parent = creationProblem(for: trimmedHome, fileManager: fileManager, currentUserID: currentUserID)
            return [dangling] + (parent.map { [$0] } ?? [])
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
            // Moving it aside needs write and search on its parent.
            let parent = creationProblem(for: trimmedHome, fileManager: fileManager, currentUserID: currentUserID)
            return (problem.map { [$0] } ?? []) + (parent.map { [$0] } ?? [])
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
            return [problem]
        }
        // Readable here, but a sandboxed task is granted only the Copilot
        // home. ASTRA does not widen the sandbox to it: the variable would
        // then grant the whole task read access to any file it names.
        guard let attributes = try? fileManager.attributesOfItem(atPath: override) else {
            // Missing or unreachable: Copilot is told to read a registry it
            // cannot open. The variable is what needs fixing.
            var missing = CopilotHomeAccessProblem(
                path: override, isDirectory: false, owner: nil, ownedByCurrentUser: true,
                posixPermissions: nil, access: .unreadable, isReadAtStartup: true
            )
            missing.isMissing = true
            missing.isProvidersOverride = true
            missing.isProvidersFile = true
            missing.requiresWrite = false
            return [missing]
        }
        guard !insideHome else { return [] }
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
        outside.requiresWrite = false
        outside.readPath = canonicalPath(override)
        var linkInfo = stat()
        outside.pathIsLink = lstat(override, &linkInfo) == 0 && (linkInfo.st_mode & S_IFMT) == S_IFLNK
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
        sandboxReceipt: ExecutionSandboxBoundaryReceipt? = nil,
        fileManager: FileManager = .default
    ) -> RuntimeReadinessReport? {
        let report = inspect(
            home: home, resumeSessionID: resumeSessionID, environment: environment,
            workingDirectory: workingDirectory, sandboxReceipt: sandboxReceipt, fileManager: fileManager
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
        let blocks = report.problems.contains { report.blocks($0) && (providersFileBlocks || !$0.isProvidersFile) }
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
        guard !parent.isEmpty else { return nil }
        // A file where a folder of the home's path should be: nothing short
        // of moving the user's file makes room, so advice only.
        if !isDirectory.boolValue, parent != "/" {
            var blocked = problem(
                at: parent, requiresWrite: true, isReadAtStartup: true,
                fileManager: fileManager, currentUserID: currentUserID, forcedAccess: .cannotCreateHome
            )
            blocked?.ancestorIsFile = true
            blocked?.isRepairable = false
            return blocked
        }
        // A lock flag forbids creating entries even where `access` says yes.
        guard Darwin.access(parent, W_OK | X_OK) != 0 || lockState(of: parent, followLinks: true).any else {
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

    /// Whether the entry's own ACL (links not followed) has a deny entry for
    /// `permission`, for any principal.
    private static func aclDenies(_ path: String, _ permission: acl_perm_t) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var entryID = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, entryID, &entry) == 0, let current = entry {
            entryID = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard acl_get_tag_type(current, &tag) == 0, tag == ACL_EXTENDED_DENY,
                  acl_get_permset(current, &permissions) == 0, let permissions else { continue }
            if acl_get_perm_np(permissions, permission) == 1 { return true }
        }
        return false
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
                at: path, requiresWrite: requiresWrite, isReadAtStartup: isReadAtStartup, currentUserID: currentUserID,
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
        } else if requiresWrite, writeDenied(path) || lockState(of: path, followLinks: false).any {
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
        // Ownership does not matter here: the fix makes the user the owner
        // first, and a chown leaves a denying ACL in place.
        // Only when nothing else explains the refusal: macOS `access` also
        // refuses a write on a locked entry, and a sharing ACL must survive
        // the unlock. If an ACL denies too, the next check will say so.
        let locked = lockState(of: path, followLinks: false).any
        let accessRefused = access == .unreadable
            || ((access == .unwritable || access == .cannotCreateHome) && writeDenied(path) && !locked)
        // Blamed when the owner bits allow the access (so only the ACL can be
        // refusing it), or when the ACL itself carries a matching deny entry
        // (then it refuses whatever the mode bits become).
        problem.hasACL = accessRefused && hasExtendedACL(path)
            && (ownerBitsAllow(access, isDirectory: isDirectory, mode: problem.posixPermissions)
                || deniedPermissions(for: access, isDirectory: isDirectory).contains { aclDenies(path, $0) })
        var linkCount = stat()
        problem.hasOtherHardLinks = !isDirectory && lstat(path, &linkCount) == 0 && linkCount.st_nlink > 1
        problem.requiresWrite = requiresWrite
        problem.pathIsLink = type == .typeSymbolicLink
        // A locked entry refuses writes, and a move aside as well.
        let locks = lockState(of: path, followLinks: false)
        let lockMatters = requiresWrite || access == .notADirectory || access == .wrongType
            || access == .danglingLink || access == .cannotCreateHome
        problem.hasLockFlag = lockMatters && locks.user
        problem.hasSystemLockFlag = lockMatters && locks.system
        if problem.hasSystemLockFlag { problem.isRepairable = false }
        problem.isSpecialFile = !isDirectory && type != .typeRegular
        // An unreadable folder hides what is inside it, so its repair must
        // reach below it (a resumed session under session-state, say).
        problem.hidesChildren = isDirectory && access == .unreadable
        if problem.isMisplaced {
            problem.backupPath = unusedBackupPath(for: path, fileManager: fileManager)
            problem.moveDeniedByOwnACL = aclDenies(path, ACL_DELETE)
            problem.moveDeniedByParentACL = aclDenies((path as NSString).deletingLastPathComponent, ACL_DELETE_CHILD)
        }
        return problem
    }

    private static func writeDenied(_ path: String) -> Bool {
        Darwin.access(path, W_OK) != 0
    }

    struct LockState {
        var user = false
        var system = false
        var any: Bool { user || system }
    }

    /// The BSD lock flags, read straight from `st_flags` so the user ones
    /// (uchg, uappnd: the owner can clear them) are told apart from the
    /// system ones (schg, sappnd: root only).
    static func lockState(of path: String, followLinks: Bool) -> LockState {
        var info = stat()
        let result = followLinks ? stat(path, &info) : lstat(path, &info)
        guard result == 0 else { return LockState() }
        let flags = info.st_flags
        let userImmutable: UInt32 = 0x0000_0002, userAppend: UInt32 = 0x0000_0004
        let systemImmutable: UInt32 = 0x0002_0000, systemAppend: UInt32 = 0x0004_0000
        return LockState(
            user: flags & (userImmutable | userAppend) != 0,
            system: flags & (systemImmutable | systemAppend) != 0
        )
    }

    /// The ACL permissions whose deny entry would cause `access`.
    private static func deniedPermissions(
        for access: CopilotHomeAccessProblem.Access,
        isDirectory: Bool
    ) -> [acl_perm_t] {
        switch access {
        case .unreadable:
            return isDirectory ? [ACL_LIST_DIRECTORY, ACL_SEARCH] : [ACL_READ_DATA]
        case .unwritable:
            return isDirectory ? [ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY] : [ACL_WRITE_DATA, ACL_APPEND_DATA]
        case .cannotCreateHome:
            return [ACL_ADD_SUBDIRECTORY, ACL_SEARCH]
        default:
            return []
        }
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
        // Creating the home needs write and search on its parent.
        case .cannotCreateHome: return mode & 0o300 == 0o300
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
        currentUserID: uid_t,
        expectedKind: EntryKind?,
        home: String?,
        fileManager: FileManager
    ) -> CopilotHomeAccessProblem? {
        guard isReadAtStartup else { return nil }
        // The link's own owner: unlocking it needs sudo when it is not the user's.
        var linkInfo = stat()
        let linkOwnerID: uid_t? = lstat(path, &linkInfo) == 0 ? linkInfo.st_uid : nil
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
        } else if requiresWrite, Darwin.access(path, W_OK) != 0 || lockState(of: path, followLinks: true).any {
            access = .unwritable
        } else {
            return nil
        }
        var problem = CopilotHomeAccessProblem(
            path: path,
            isDirectory: isDirectory.boolValue,
            owner: nil,
            ownedByCurrentUser: linkOwnerID.map { $0 == currentUserID } ?? true,
            posixPermissions: nil,
            access: access,
            isReadAtStartup: true,
            symlinkTarget: target
        )
        problem.requiresWrite = requiresWrite
        problem.isSpecialFile = targetExists && !isDirectory.boolValue && targetType != .typeRegular
        problem.pathIsLink = true
        problem.readPath = canonicalPath(path)
        problem.hasLockFlag = access == .unwritable && lockState(of: path, followLinks: true).any
        // A link the user has to replace (broken or the wrong type) must be
        // unlocked first.
        let linkLocks = lockState(of: path, followLinks: false)
        if access == .unreadable || access == .wrongType {
            problem.linkIsLocked = linkLocks.user
            problem.hasSystemLockFlag = linkLocks.system
        }
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
        // A longer chain: the kernel's own resolution, so every later use sees
        // the real target rather than an intermediate link.
        if (try? fileManager.destinationOfSymbolicLink(atPath: current)) != nil, let resolved = realpath(current, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
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
