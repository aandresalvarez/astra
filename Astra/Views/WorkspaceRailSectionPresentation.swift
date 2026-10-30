import Foundation

/// Pure presentation model for the Workspace Context rail v2
/// (`docs/specs/2026-10-26-workspace-context-rail-v2.md`, rev 2).
///
/// The rail lists what the workspace has; absence is not a state. This type
/// turns plain workspace facts into boxes and rows and encodes the four rules
/// the spec fixes:
///
/// 1. Presence makes a row. A row exists when there is something behind it.
///    Instructions is the one exception: it always shows, and when empty it
///    reads `Write` with no warning tint.
/// 2. No box without content. A box renders only when it has at least one
///    row; an absent box's first add lives in the rail-level `Add…`.
/// 3. Only two things get colour: a blocked capability's repair verb, and a
///    working tree whose sync is blocking (info tint, never the accent).
/// 4. One line per fact. Rows are key/value on a single line.
///
/// It owns no state and imports no UI, so a test can pin every rule.
enum WorkspaceRailSectionPresentation {

    // MARK: - Boxes

    /// The boxes in their fixed order. There is no adaptive reorder: the old
    /// one existed to surface pending setup, a concept this model does not
    /// have. Outputs is last and task-scoped: the files the selected task
    /// produced, so the rail ends the way Claude Code's and Codex's do.
    enum Section: String, CaseIterable, Equatable {
        case environment
        case context
        case capabilities
        case outputs

        var title: String {
            switch self {
            case .environment: "Environment"
            case .context: "Context"
            case .capabilities: "Capabilities"
            case .outputs: "Outputs"
            }
        }
    }

    static let sectionOrder: [Section] = [.environment, .context, .capabilities, .outputs]

    // MARK: - Facts (inputs)

    /// What the workspace runs in. Plain values so the model needs no
    /// SwiftData or view model.
    enum ExecutionEnvironment: Equatable {
        case local
        case container(name: String)

        var label: String {
            switch self {
            case .local:
                return "Local"
            case .container(let name):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "Docker" : "Docker · \(trimmed)"
            }
        }
    }

    struct EnvironmentFacts: Equatable {
        var primaryPath: String
        var additionalPaths: [String] = []
        /// The active repository's display name, when one exists.
        var repositoryName: String? = nil
        /// The active repository's path, shown beside its name when it is not
        /// the primary folder.
        var repositoryPath: String? = nil
        var hasMultipleRepositories: Bool = false
        var branch: String? = nil
        var changedFileCount: Int = 0
        var aheadCount: Int = 0
        var behindCount: Int = 0
        /// Readiness is supplied by WorkspaceGitViewModel, not inferred from counts.
        var canStartPullRequest: Bool = false
        /// A label for the open pull request (`#552 · draft`), when one exists.
        var openPullRequestLabel: String? = nil
        var executionEnvironment: ExecutionEnvironment = .local
        var remoteServerNames: [String] = []
    }

    struct ContextFacts: Equatable {
        var instructions: String = ""
        var memoryCount: Int = 0
        var routineTitles: [String] = []
    }

    struct CapabilityFacts: Equatable, Identifiable {
        var id: String
        var name: String
        /// Enabled, but unable to run until the user acts (sign in, approve,
        /// install, start something).
        var isBlocked: Bool = false
        /// The repair verb a blocked capability shows as its button.
        var blockedVerb: String? = nil
        var isDraft: Bool = false
    }

    /// Where an output opens when tapped: the shelf that renders its kind.
    enum OutputDestination: Equatable, Sendable {
        case files
        case browser
        case query
        case none

        var systemImage: String {
            switch self {
            case .files: "doc.text"
            case .browser: "globe"
            case .query: "tablecells"
            case .none: "doc"
            }
        }
    }

    /// One file the selected task produced, newest first as given. Inputs the
    /// user attached are not outputs and never reach this list.
    struct OutputFile: Equatable, Identifiable, Sendable {
        var path: String
        var destination: OutputDestination = .files

        var id: String { path }
        var name: String { WorkspaceRailSectionPresentation.lastPathComponent(path) }
    }

    struct OutputFacts: Equatable, Sendable {
        var files: [OutputFile] = []
    }

    // MARK: - Rows

    enum RowTone: Equatable {
        /// Neutral key/value: the default for every fact.
        case neutral
        /// A sync that blocks pushing (behind, diverged). Info tint, never the
        /// "ready" accent, so it never implies an action is safe.
        case info
        /// A tappable link (an open pull request). Accent is allowed because
        /// the row itself is the action.
        case link
    }

    enum RowAction: Equatable {
        /// An accent verb beside the row (`Write`, `Edit`), a separate tap
        /// target from the row body.
        case verb(String)
        /// A tinted button for a blocked capability. The button is the whole
        /// signal; there is no separate pill.
        case repair(String)
        /// Tertiary text with no action (`Draft`).
        case label(String)
    }

    enum RowKind: Hashable {
        case folder
        case repository
        case branch
        case runsIn
        case remote
        case pullRequest
        case instructions
        case memory
        case routines
        case capability(id: String)
        case output(path: String)
        /// The files past the row limit, as one link row into the Files shelf.
        case outputsOverflow(hiddenCount: Int, firstHiddenPath: String)
    }

    struct Row: Equatable, Identifiable {
        struct ID: Hashable {
            var kind: RowKind
            var path: String?
        }

        var id: ID { ID(kind: kind, path: representedPath) }
        var kind: RowKind
        var systemImage: String
        var title: String
        /// Trailing value on the same line (`main`, `3 details`).
        var value: String? = nil
        /// Muted text after the value (`3 changed`).
        var detail: String? = nil
        var tone: RowTone = .neutral
        var action: RowAction? = nil
        /// Whether the row body expands in place (editors, pickers, details).
        var isExpandable: Bool = false
        /// Full normalized path, never the abbreviated display value.
        var representedPath: String? = nil
    }

    /// What a box's `+` (and the rail-level `Add…`) can add.
    enum AddAction: String, CaseIterable, Equatable {
        case addCapability
        case addMemory
        case newRoutine
        case addFolder
        case connectServer
        case runInContainer

        var title: String {
            switch self {
            case .addCapability: "Add capability…"
            case .addMemory: "Add memory"
            case .newRoutine: "New routine…"
            case .addFolder: "Add folder…"
            case .connectServer: "Connect a server…"
            case .runInContainer: "Run in a container…"
            }
        }

        var section: Section {
            switch self {
            case .addCapability: .capabilities
            case .addMemory, .newRoutine: .context
            case .addFolder, .connectServer, .runInContainer: .environment
            }
        }

        static func actions(for section: Section) -> [AddAction] {
            allCases.filter { $0.section == section }
        }
    }

    struct Box: Equatable {
        var section: Section
        var rows: [Row]
        /// Verbs in the button footer. Empty when nothing is actionable.
        var footerActions: [String] = []
        /// The one line a collapsed box shows after its title.
        var collapsedSummary: String
        /// Re-opens on its own while something inside needs the user.
        var forcesExpansion: Bool = false

        var title: String { section.title }
        var addActions: [AddAction] { AddAction.actions(for: section) }
    }

    // MARK: - Copy

    static let instructionsTitle = "Instructions"
    static let writeInstructionsVerb = "Write"
    static let editInstructionsVerb = "Edit"
    static let chooseFolderVerb = "Choose…"
    static let defaultBlockedVerb = "Set up"
    static let draftLabel = "Draft"
    static let untitledCapabilityName = "Untitled capability"
    static let commitAndPushAction = "Commit & push"
    static let pushAction = "Push"
    static let createPullRequestAction = "Create PR"
    static let cleanTreeSummary = "clean"
    static let emptyContextSummary = "No instructions yet"
    static let railAddTitle = "Add…"
    static let summarySeparator = " · "
    /// How many outputs the box lists before folding the rest into one row.
    static let outputRowLimit = 8

    // MARK: - Building boxes

    /// Every box that has content, in the fixed order. Never returns a box
    /// with zero rows.
    static func boxes(
        environment: EnvironmentFacts,
        context: ContextFacts,
        capabilities: [CapabilityFacts],
        outputs: OutputFacts = OutputFacts()
    ) -> [Box] {
        let built: [Section: Box?] = [
            .environment: environmentBox(environment),
            .context: contextBox(context),
            .capabilities: capabilitiesBox(capabilities),
            .outputs: outputsBox(outputs)
        ]
        return sectionOrder.compactMap { built[$0] ?? nil }.filter { !$0.rows.isEmpty }
    }

    /// The rail-level `Add…` menu: the adds of absent boxes first (so the
    /// first capability is one tap away even with no Capabilities box), then
    /// the present boxes' adds, both in section order.
    static func railAddActions(for boxes: [Box]) -> [AddAction] {
        let present = Set(boxes.map(\.section))
        let absent = sectionOrder.filter { !present.contains($0) }
        let shown = sectionOrder.filter { present.contains($0) }
        return (absent + shown).flatMap(AddAction.actions(for:))
    }

    // MARK: Environment

    static func environmentBox(_ facts: EnvironmentFacts) -> Box {
        var rows: [Row] = []

        let root = standardizedPath(facts.primaryPath)
        if root.isEmpty {
            rows.append(Row(kind: .folder, systemImage: "folder", title: "Folder", action: .verb(chooseFolderVerb)))
        } else {
            rows.append(Row(kind: .folder, systemImage: "folder", title: "Folder", value: abbreviatedPath(root), isExpandable: true, representedPath: root))
        }
        for path in uniqueAdditionalPaths(facts.additionalPaths, excluding: root) {
            rows.append(Row(kind: .folder, systemImage: "folder", title: "Folder", value: abbreviatedPath(path), isExpandable: true, representedPath: path))
        }

        // Where it is, where it runs, then source control, which carries the
        // verbs footer at the foot of the box.
        let servers = facts.remoteServerNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !servers.isEmpty {
            rows.append(Row(kind: .remote, systemImage: "network", title: "Remote", value: remoteSummary(servers), isExpandable: true))
        }

        rows.append(Row(
            kind: .runsIn,
            systemImage: facts.executionEnvironment == .local ? "desktopcomputer" : "shippingbox",
            title: "Runs in",
            value: facts.executionEnvironment.label,
            isExpandable: true
        ))

        if let name = facts.repositoryName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            var value = name
            if let repositoryPath = facts.repositoryPath.map(standardizedPath),
               !repositoryPath.isEmpty, repositoryPath != root {
                value += summarySeparator + abbreviatedPath(repositoryPath)
            }
            rows.append(Row(
                kind: .repository,
                systemImage: "folder",
                title: "Repository",
                value: value,
                isExpandable: facts.hasMultipleRepositories
            ))
        }

        if let branch = facts.branch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty {
            rows.append(Row(
                kind: .branch,
                systemImage: "arrow.triangle.branch",
                title: "Branch",
                value: branch,
                detail: workingTreeSummary(facts),
                tone: facts.behindCount > 0 ? .info : .neutral,
                isExpandable: true
            ))
        }

        if let pullRequest = facts.openPullRequestLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !pullRequest.isEmpty {
            rows.append(Row(kind: .pullRequest, systemImage: "arrow.triangle.pull", title: "Pull request", value: pullRequest, tone: .link))
        }

        return Box(
            section: .environment,
            rows: rows,
            footerActions: footerActions(facts),
            collapsedSummary: environmentSummary(facts, root: root)
        )
    }

    /// Verbs are a button footer, rendered only when something is actionable.
    /// A clean, published branch can still create a PR. An existing PR is a
    /// row, so it needs no footer when no commit or push remains.
    static func footerActions(_ facts: EnvironmentFacts) -> [String] {
        guard facts.branch != nil else { return [] }
        var actions: [String] = []
        if facts.changedFileCount > 0 {
            actions.append(commitAndPushAction)
        } else if facts.aheadCount > 0 {
            actions.append(pushAction)
        }
        if facts.openPullRequestLabel == nil, !actions.isEmpty || facts.canStartPullRequest {
            actions.append(createPullRequestAction)
        }
        return actions
    }

    /// `3 changed`, `2 ahead`, `1 behind`, or combinations; nil when clean.
    static func workingTreeSummary(_ facts: EnvironmentFacts) -> String? {
        var parts: [String] = []
        if facts.changedFileCount > 0 { parts.append("\(facts.changedFileCount) changed") }
        if facts.aheadCount > 0 { parts.append("\(facts.aheadCount) ahead") }
        if facts.behindCount > 0 { parts.append("\(facts.behindCount) behind") }
        return parts.isEmpty ? nil : parts.joined(separator: summarySeparator)
    }

    static func environmentSummary(_ facts: EnvironmentFacts, root: String) -> String {
        var parts: [String] = []
        let name = facts.repositoryName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        parts.append(name.isEmpty ? lastPathComponent(root) : name)
        if let branch = facts.branch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty {
            parts.append(branch)
            parts.append(workingTreeSummary(facts) ?? cleanTreeSummary)
        } else {
            parts.append(facts.executionEnvironment.label)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: summarySeparator)
    }

    static func remoteSummary(_ servers: [String]) -> String {
        servers.count == 1
            ? "1 server" + summarySeparator + servers[0]
            : "\(servers.count) servers"
    }

    // MARK: Context

    static func contextBox(_ facts: ContextFacts) -> Box {
        var rows: [Row] = []

        let firstLine = instructionsFirstLine(facts.instructions)
        rows.append(Row(
            kind: .instructions,
            systemImage: "text.quote",
            title: instructionsTitle,
            value: firstLine,
            action: .verb(firstLine == nil ? writeInstructionsVerb : editInstructionsVerb),
            isExpandable: true
        ))

        if facts.memoryCount > 0 {
            rows.append(Row(
                kind: .memory,
                systemImage: "text.badge.checkmark",
                title: "Memory",
                value: countPhrase(facts.memoryCount, "detail", "details"),
                isExpandable: true
            ))
        }

        let routines = facts.routineTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !routines.isEmpty {
            rows.append(Row(
                kind: .routines,
                systemImage: "arrow.triangle.2.circlepath",
                title: "Routines",
                value: routines.count == 1 ? routines[0] : countPhrase(routines.count, "scheduled", "scheduled"),
                isExpandable: true
            ))
        }

        return Box(section: .context, rows: rows, collapsedSummary: contextSummary(facts, routineCount: routines.count))
    }

    static func contextSummary(_ facts: ContextFacts, routineCount: Int) -> String {
        var parts: [String] = []
        if instructionsFirstLine(facts.instructions) != nil { parts.append(instructionsTitle) }
        if facts.memoryCount > 0 { parts.append(countPhrase(facts.memoryCount, "detail", "details")) }
        if routineCount > 0 { parts.append(countPhrase(routineCount, "routine", "routines")) }
        return parts.isEmpty ? emptyContextSummary : parts.joined(separator: summarySeparator)
    }

    /// The first non-blank line of the instructions, or nil when there are
    /// none. The row shows it as its value; the editor shows the whole text.
    static func instructionsFirstLine(_ instructions: String) -> String? {
        instructions
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    // MARK: Capabilities

    /// Nil when the workspace has no capability: the box does not render, and
    /// `Add capability…` leads the rail-level `Add…` instead.
    static func capabilitiesBox(_ capabilities: [CapabilityFacts]) -> Box? {
        guard !capabilities.isEmpty else { return nil }
        let ordered = capabilities.sorted(by: capabilityOrder)
        let rows = ordered.map(capabilityRow)
        return Box(
            section: .capabilities,
            rows: rows,
            collapsedSummary: ordered.map { displayName($0) }.joined(separator: summarySeparator),
            forcesExpansion: capabilities.contains { $0.isBlocked && !$0.isDraft }
        )
    }

    /// Blocked first, then ready, then drafts; by name within a group.
    static func capabilityOrder(_ lhs: CapabilityFacts, _ rhs: CapabilityFacts) -> Bool {
        let lhsRank = capabilityRank(lhs)
        let rhsRank = capabilityRank(rhs)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return displayName(lhs).localizedCaseInsensitiveCompare(displayName(rhs)) == .orderedAscending
    }

    private static func capabilityRank(_ capability: CapabilityFacts) -> Int {
        if capability.isDraft { return 2 }
        return capability.isBlocked ? 0 : 1
    }

    static func capabilityRow(_ capability: CapabilityFacts) -> Row {
        let action: RowAction?
        if capability.isDraft {
            action = .label(draftLabel)
        } else if capability.isBlocked {
            let verb = capability.blockedVerb?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            action = .repair(verb.isEmpty ? defaultBlockedVerb : verb)
        } else {
            action = nil
        }
        return Row(
            kind: .capability(id: capability.id),
            systemImage: "puzzlepiece.extension",
            title: displayName(capability),
            action: action,
            isExpandable: true
        )
    }

    static func displayName(_ capability: CapabilityFacts) -> String {
        let trimmed = capability.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? untitledCapabilityName : trimmed
    }

    // MARK: Outputs

    /// Nil when the task produced nothing (or no task is selected): the box
    /// does not render. Up to `outputRowLimit` files, newest first, then one
    /// row that names the rest and opens the Files shelf.
    static func outputsBox(_ facts: OutputFacts) -> Box? {
        var seen = Set<String>()
        let files = facts.files.filter { !$0.path.isEmpty && seen.insert($0.path).inserted }
        guard !files.isEmpty else { return nil }

        let duplicateNames = duplicateBasenames(files.map(\.path))
        let shown = files.prefix(outputRowLimit)
        var rows: [Row] = shown.map { file in
            Row(
                kind: .output(path: file.path),
                systemImage: file.destination.systemImage,
                title: outputDisplayName(file.path, duplicateBasenames: duplicateNames),
                isExpandable: false
            )
        }
        let hidden = files.dropFirst(outputRowLimit)
        if let first = hidden.first {
            rows.append(Row(
                kind: .outputsOverflow(hiddenCount: hidden.count, firstHiddenPath: first.path),
                systemImage: "folder",
                title: "\(hidden.count) more in Files",
                tone: .link
            ))
        }

        return Box(section: .outputs, rows: rows, collapsedSummary: outputsSummary(files))
    }

    static func outputsSummary(_ files: [OutputFile]) -> String {
        let names = files.prefix(3).map(\.name)
        let remaining = files.count - names.count
        let list = remaining > 0 ? names.joined(separator: ", ") + " +\(remaining)" : names.joined(separator: ", ")
        return countPhrase(files.count, "file", "files") + summarySeparator + list
    }

    /// Basenames that appear more than once (case-insensitive), so those rows
    /// can lead with their parent folder.
    static func duplicateBasenames(_ paths: [String]) -> Set<String> {
        var counts: [String: Int] = [:]
        for path in paths {
            counts[lastPathComponent(path).lowercased(), default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.map(\.key))
    }

    static func outputDisplayName(_ path: String, duplicateBasenames: Set<String>) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard let basename = components.last else { return path }
        guard duplicateBasenames.contains(basename.lowercased()), components.count > 1 else { return basename }
        return components[components.count - 2] + "/" + basename
    }

    // MARK: - Paths and counts

    static func standardizedPath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.hasPrefix("/") ? URL(fileURLWithPath: trimmed).standardizedFileURL.path : trimmed
    }

    static func uniqueAdditionalPaths(_ paths: [String], excluding root: String) -> [String] {
        var seen: Set<String> = [root]
        return paths.map(standardizedPath).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `…/last/two` for a long path; short paths and `~` forms stay whole.
    static func abbreviatedPath(_ path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 2 else { return path }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    static func lastPathComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func countPhrase(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    // MARK: - Density

    /// One-line rows at the sidebar's density, inside today's box chrome.
    enum Layout {
        static let boxTitleFontSize: CGFloat = 13
        static let rowTitleFontSize: CGFloat = 13
        static let rowValueFontSize: CGFloat = 12
        static let rowHeight: CGFloat = 30
        static let leadingIconFontSize: CGFloat = 13
        static let leadingIconFrame: CGFloat = 20
        static let boxPaddingTop: CGFloat = 4
        static let boxPaddingHorizontal: CGFloat = 6
        static let boxPaddingBottom: CGFloat = 8
        static let boxSpacing: CGFloat = 10
        static let columnWidth: CGFloat = 340
        static let minimumColumnWidth: CGFloat = 300
        /// The widest the automatic docked size grows on a large window; the
        /// user can still drag to `maximumColumnWidth`.
        static let automaticMaximumColumnWidth: CGFloat = 380
        static let maximumColumnWidth: CGFloat = 420
    }
}
