import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

struct BrowserSessionPolicy: Equatable {
    var enabledBrowserAdapters: [String]
    var githubReadOnlyMode: Bool

    static let failClosed = BrowserSessionPolicy(
        enabledBrowserAdapters: [],
        githubReadOnlyMode: true
    )
}

struct BrowserSessionPolicySignature: Equatable {
    var taskOwnerID: PersistentIdentifier? = nil
    var workspaceOwnerID: PersistentIdentifier? = nil
    var taskID: UUID?
    var workspaceID: UUID?
    var environmentRevision: String
    var enabledCapabilityIDs: [String]
    var approvalRevision: String
    var packageDefinitionFingerprint: String
    var taskEventRevision: String
    var catalogPolicyRevision: String

    init(
        taskID: UUID?,
        workspaceID: UUID? = nil,
        taskOwnerID: PersistentIdentifier? = nil,
        workspaceOwnerID: PersistentIdentifier? = nil,
        environmentRevision: String = "host",
        enabledCapabilityIDs: [String],
        approvalRevision: String,
        packageDefinitionFingerprint: String,
        taskEventRevision: String,
        catalogPolicyRevision: String = ""
    ) {
        self.taskOwnerID = taskOwnerID
        self.workspaceOwnerID = workspaceOwnerID
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.environmentRevision = environmentRevision
        self.enabledCapabilityIDs = enabledCapabilityIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        self.approvalRevision = approvalRevision
        self.packageDefinitionFingerprint = packageDefinitionFingerprint
        self.taskEventRevision = taskEventRevision
        self.catalogPolicyRevision = catalogPolicyRevision
    }

    var refreshKey: String {
        [
            String(describing: taskOwnerID),
            String(describing: workspaceOwnerID),
            taskID?.uuidString ?? "no-task",
            workspaceID?.uuidString ?? "no-workspace",
            environmentRevision,
            enabledCapabilityIDs.joined(separator: ","),
            approvalRevision,
            packageDefinitionFingerprint,
            taskEventRevision,
            catalogPolicyRevision
        ].joined(separator: "|")
    }
}

struct BrowserSessionPolicySource {
    var packageDefinitions: () throws -> [PluginPackage]
    var approvalRecords: () throws -> [CapabilityApprovalRecord]
    var latestContextText: () throws -> String
    var environment: () throws -> WorkspaceExecutionEnvironment
    var enabledBrowserAdapters: (BrowserSessionPolicySignature, [PluginPackage], [CapabilityApprovalRecord]) throws -> [String]
    var githubReadOnlyMode: (WorkspaceExecutionEnvironment, String) throws -> Bool

    init(
        packageDefinitions: @escaping () throws -> [PluginPackage],
        approvalRecords: @escaping () throws -> [CapabilityApprovalRecord],
        latestContextText: @escaping () throws -> String,
        environment: @escaping () throws -> WorkspaceExecutionEnvironment,
        enabledBrowserAdapters: @escaping (
            BrowserSessionPolicySignature,
            [PluginPackage],
            [CapabilityApprovalRecord]
        ) throws -> [String] = BrowserSessionPolicySource.defaultEnabledBrowserAdapters,
        githubReadOnlyMode: @escaping (WorkspaceExecutionEnvironment, String) throws -> Bool = { _, _ in false }
    ) {
        self.packageDefinitions = packageDefinitions
        self.approvalRecords = approvalRecords
        self.latestContextText = latestContextText
        self.environment = environment
        self.enabledBrowserAdapters = enabledBrowserAdapters
        self.githubReadOnlyMode = githubReadOnlyMode
    }

    private static func defaultEnabledBrowserAdapters(
        signature: BrowserSessionPolicySignature,
        packages: [PluginPackage],
        approvalRecords: [CapabilityApprovalRecord]
    ) -> [String] {
        let enabledPackageIDs = Set(signature.enabledCapabilityIDs)
        guard !enabledPackageIDs.isEmpty else { return [] }

        var seen = Set<String>()
        var adapters: [String] = []
        for package in packages where enabledPackageIDs.contains(package.id) {
            for adapter in package.browserAdapters {
                guard let normalized = BrowserSiteAdapterID.normalized(adapter),
                      seen.insert(normalized).inserted else {
                    continue
                }
                adapters.append(normalized)
            }
        }
        return adapters
    }
}

struct BrowserSessionPolicyCache {
    private var signature: BrowserSessionPolicySignature?
    private var policy = BrowserSessionPolicy.failClosed

    mutating func policy(
        for signature: BrowserSessionPolicySignature,
        source: BrowserSessionPolicySource
    ) -> BrowserSessionPolicy {
        if self.signature == signature {
            return policy
        }

        do {
            let packages = try source.packageDefinitions()
            let approvalRecords = try source.approvalRecords()
            let contextText = try source.latestContextText()
            let environment = try source.environment()
            let refreshed = BrowserSessionPolicy(
                enabledBrowserAdapters: try source.enabledBrowserAdapters(signature, packages, approvalRecords),
                githubReadOnlyMode: try source.githubReadOnlyMode(environment, contextText)
            )
            self.signature = signature
            policy = refreshed
            return refreshed
        } catch {
            self.signature = signature
            policy = .failClosed
            return policy
        }
    }
}

/// Main-actor acceptance gate for asynchronous policy refreshes. Starting a
/// refresh immediately exposes the fail-closed policy; only the newest token
/// may publish a result. This keeps separate windows independent and prevents a
/// slow refresh for the previous workspace or task from overwriting new state.
struct BrowserSessionPolicyRefreshGate {
    struct Token: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private(set) var policy = BrowserSessionPolicy.failClosed
    private var generation: UInt64 = 0

    mutating func begin() -> Token {
        generation &+= 1
        policy = .failClosed
        return Token(generation: generation)
    }

    @discardableResult
    mutating func accept(_ refreshedPolicy: BrowserSessionPolicy, for token: Token) -> Bool {
        guard token.generation == generation else { return false }
        policy = refreshedPolicy
        return true
    }
}

/// Which session a published policy belonged to.
///
/// `BrowserSessionPolicy` carries no identity, so a policy remembered across a
/// task or workspace switch is indistinguishable from one the new session
/// resolved for itself. Comparing the two answers a question nobody asked —
/// "does the new session agree with the old one?" — in place of the one the
/// audit below exists to answer.
struct BrowserSessionPolicyPublication: Equatable {
    var taskOwnerID: PersistentIdentifier? = nil
    var workspaceOwnerID: PersistentIdentifier? = nil
    var taskID: UUID?
    var workspaceID: UUID?
    var policy: BrowserSessionPolicy

    /// Only a publication from the same session can be the `previous` one.
    func policyForSession(taskID: UUID?, workspaceID: UUID?, taskOwnerID: PersistentIdentifier? = nil, workspaceOwnerID: PersistentIdentifier? = nil) -> BrowserSessionPolicy? {
        guard self.taskID == taskID, self.workspaceID == workspaceID,
              self.taskOwnerID == taskOwnerID, self.workspaceOwnerID == workspaceOwnerID else { return nil }
        return policy
    }
}

/// What one accepted refresh should say about itself in the log.
///
/// A refresh that resolves to the policy already in force is the overwhelmingly
/// common case: across the three retained production log rotations
/// (2026-08-31 to 2026-09-08) the event fired 3,607 times and 3,498 of those —
/// 97.0% — reported the same policy for the same task as the line above them,
/// out of 65 distinct states in the whole window. The refresh is driven by
/// `AgentTask.updatedAt`, which moves for reasons that have nothing to do with
/// browser policy. Two fields turn that wall into data: `changed` says whether
/// the work mattered, and `duration_ms` says what it cost (the disk hop for
/// package definitions and approval records is not free). No-ops drop to debug
/// so the info channel carries only the transitions; the count is still
/// recoverable from a debug-level capture.
///
/// This lives outside the view because the decision — not the logging — is the
/// part worth pinning: `previous` is the last *published* policy, not the gate's
/// current one, since `BrowserSessionPolicyRefreshGate.begin()` resets the gate
/// to `.failClosed` and would make every refresh look like a transition.
struct BrowserSessionPolicyRefreshAudit: Equatable {
    var source: String
    /// The policy this *same* session last published, or nil when this is its
    /// first. A carried-over value from another task or workspace is not a
    /// previous policy — see `BrowserSessionPolicyPublication`.
    var previous: BrowserSessionPolicy?
    var published: BrowserSessionPolicy
    var durationMilliseconds: Double

    /// The first publish counts as a change: there was no policy in force, and
    /// the value the session starts at is worth one info line. That holds per
    /// session, not per process — switching tasks starts a new one, and its
    /// baseline is the line task-scoped diagnostics need most. Two sessions
    /// that happen to resolve the same policy would otherwise silence it.
    var changed: Bool { previous != published }

    var level: LogLevel { changed ? .info : .debug }

    var fields: [String: String] {
        [
            "event": "browser_session_policy_refreshed",
            "source": source,
            "enabled_browser_adapters": published.enabledBrowserAdapters.joined(separator: ","),
            "github_read_only_mode": String(published.githubReadOnlyMode),
            "changed": String(changed),
            "duration_ms": String(format: "%.2f", durationMilliseconds)
        ]
    }
}

/// Allocation-light identity observed by SwiftUI. Expensive approval/package
/// fingerprints and event payload inspection deliberately do not participate;
/// they are captured only after this key schedules an asynchronous refresh.
struct BrowserSessionPolicyRefreshTrigger: Equatable {
    var taskOwnerID: PersistentIdentifier? = nil
    var workspaceOwnerID: PersistentIdentifier? = nil
    var taskID: UUID?
    var workspaceID: UUID?
    var enabledCapabilityIDs: [String]
    var taskRevision: String
    var workspaceRevision: String
    var environmentRevision: String

    var rawValue: String {
        [
            String(describing: taskOwnerID),
            String(describing: workspaceOwnerID),
            taskID?.uuidString ?? "no-task",
            workspaceID?.uuidString ?? "no-workspace",
            enabledCapabilityIDs.joined(separator: ","),
            taskRevision,
            workspaceRevision,
            environmentRevision
        ].joined(separator: "|")
    }
}

enum BrowserSessionPolicyContext {
    /// Bounded, immutable task state captured on the main actor before policy
    /// resolution moves to a detached task. It deliberately contains no
    /// SwiftData models, package definitions, or filesystem-backed state.
    struct HostControlInput: Sendable {
        let enabledPackageIDs: Set<String>
        let taskID: UUID

        /// Strict O(1) admission boundary. SwiftData relationships are
        /// deliberately absent: without a separately maintained immutable
        /// provider-scope projection, this UI cache cannot prove a negative and
        /// must keep GitHub read-only.
        @MainActor
        init(task: AgentTask, enabledPackageIDs: [String], contextText: String) {
            self.enabledPackageIDs = Set(enabledPackageIDs)
            taskID = task.id
            _ = contextText
        }

        func resolve(packageDefinitions: [PluginPackage]) -> HostControlPlaneMCPProjection.CapabilitySnapshot {
            _ = packageDefinitions
            return HostControlPlaneMCPProjection.CapabilitySnapshot(
                enabledPackageIDs: enabledPackageIDs,
                behaviorSkillOriginPackageIDs: [],
                effectiveBehaviorInstructions: [],
                resolutionIsComplete: false
            )
        }
    }

    struct CatalogPolicyInput: Sendable {
        let installedPackageIDs: Set<String>
        let enabledPackageIDs: Set<String>
        let enabledPackIDs: [String]

        @MainActor
        init(workspace: Workspace) {
            installedPackageIDs = workspace.installedPluginIDSet
            enabledPackageIDs = Set(workspace.enabledCapabilityIDs)
            enabledPackIDs = workspace.enabledPackIDs
        }

        func resolve() -> CapabilityCatalogPolicyContext {
            CapabilityCatalogPolicyContext(
                installedPackageIDs: installedPackageIDs,
                enabledPackageIDs: enabledPackageIDs,
                packPolicy: PackWorkspacePolicyProvider.resolvedPolicy(enabledPackIDs: enabledPackIDs)
            )
        }

        var signature: String {
            [
                installedPackageIDs.sorted().joined(separator: ","),
                enabledPackageIDs.sorted().joined(separator: ","),
                enabledPackIDs.sorted().joined(separator: ",")
            ].joined(separator: "|")
        }
    }

    struct UserMessage: Equatable {
        let payload: String
        let timestamp: Date
        let eventID: UUID
    }

    struct Snapshot: Sendable {
        let goal: String
        let latestUserMessage: String?

        init(goal: String, latestUserMessage: String?) {
            self.goal = goal
            self.latestUserMessage = latestUserMessage
        }
    }

    static func latestContextText(in snapshot: Snapshot) -> String {
        let latestUserMessage = snapshot.latestUserMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        return latestUserMessage.flatMap { $0.isEmpty ? nil : $0 } ?? snapshot.goal
    }

    static func githubReadOnlyMode(
        environment: WorkspaceExecutionEnvironment,
        capabilitySnapshot: HostControlPlaneMCPProjection.CapabilitySnapshot?
    ) -> Bool {
        guard let capabilitySnapshot else { return true }
        return HostControlPlaneMCPProjection.githubIsEnabled(
            for: environment,
            capabilitySnapshot: capabilitySnapshot
        )
    }

    @MainActor
    static func latestUserMessage(task: AgentTask, modelContext: ModelContext) -> UserMessage? {
        let owner = task.persistentModelID
        let userMessageType = TaskEventTypes.Conversation.userMessage.rawValue
        var descriptor = FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> { event in
                event.type == userMessageType && event.task?.persistentModelID == owner
            },
            sortBy: [
                SortDescriptor(\TaskEvent.timestamp, order: .reverse),
                SortDescriptor(\TaskEvent.id, order: .reverse)
            ]
        )
        descriptor.fetchLimit = 1
        guard let event = try? modelContext.fetch(descriptor).first else { return nil }
        return UserMessage(payload: event.payload, timestamp: event.timestamp, eventID: event.id)
    }

    static func taskPolicyRevision(for task: AgentTask?) -> String {
        guard let task else { return "no-task" }
        return [
            task.id.uuidString,
            // Output, usage, title, unread and lifecycle timestamps do not
            // change browser policy. User messages invalidate via the typed
            // event projection; package/approval edits via notifications.
            task.goal,
            task.status == .draft ? "draft" : "accepted"
        ].joined(separator: "|")
    }

    @MainActor
    static func hasRuns(task: AgentTask, modelContext: ModelContext) -> Bool {
        let owner = task.persistentModelID
        var descriptor = FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> { run in run.task?.persistentModelID == owner }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor).isEmpty == false) ?? false
    }
}

struct BrowserSessionPolicyTaskProjection {
    private var latestUserMessageByTask: [PersistentIdentifier: BrowserSessionPolicyContext.UserMessage] = [:]
    private var eventRevisionByTask: [UUID: UUID] = [:]

    @MainActor
    mutating func latestUserMessage(for task: AgentTask?, modelContext: ModelContext) -> String? {
        guard let task else { return nil }
        let owner = task.persistentModelID
        let latest = latestUserMessageByTask[owner]
            ?? BrowserSessionPolicyContext.latestUserMessage(task: task, modelContext: modelContext)
        latestUserMessageByTask[owner] = latest
        return latest?.payload
    }

    func revision(for task: AgentTask?) -> String {
        guard let task else { return BrowserSessionPolicyContext.taskPolicyRevision(for: nil) }
        return [String(describing: task.persistentModelID),
            BrowserSessionPolicyContext.taskPolicyRevision(for: task),
            eventRevisionByTask[task.id]?.uuidString ?? "no-user-event"
        ].joined(separator: "|")
    }

    mutating func record(_ insertion: DurableTaskEventInsertion, selectedTaskID: UUID?) -> Bool {
        guard insertion.type == TaskEventTypes.Conversation.userMessage.rawValue else { return false }
        // Notifications carry a portable UUID, not ownership. They invalidate
        // the projection; only a fresh owner-scoped storage read supplies text.
        latestUserMessageByTask.removeAll()
        eventRevisionByTask[insertion.taskID] = insertion.eventID
        return insertion.taskID == selectedTaskID
    }
}
