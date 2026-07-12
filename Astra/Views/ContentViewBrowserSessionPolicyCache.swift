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
    var taskID: UUID?
    var workspaceID: UUID?
    var environmentRevision: String
    var enabledCapabilityIDs: [String]
    var approvalRevision: String
    var packageDefinitionFingerprint: String
    var taskEventRevision: String

    init(
        taskID: UUID?,
        workspaceID: UUID? = nil,
        environmentRevision: String = "host",
        enabledCapabilityIDs: [String],
        approvalRevision: String,
        packageDefinitionFingerprint: String,
        taskEventRevision: String
    ) {
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
    }

    var refreshKey: String {
        [
            taskID?.uuidString ?? "no-task",
            workspaceID?.uuidString ?? "no-workspace",
            environmentRevision,
            enabledCapabilityIDs.joined(separator: ","),
            approvalRevision,
            packageDefinitionFingerprint,
            taskEventRevision
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

/// Allocation-light identity observed by SwiftUI. Expensive approval/package
/// fingerprints and event payload inspection deliberately do not participate;
/// they are captured only after this key schedules an asynchronous refresh.
struct BrowserSessionPolicyRefreshTrigger: Equatable {
    var taskID: UUID?
    var workspaceID: UUID?
    var enabledCapabilityIDs: [String]
    var taskCanvasRevision: String
    var taskRevision: String
    var workspaceRevision: String
    var environmentRevision: String

    var rawValue: String {
        [
            taskID?.uuidString ?? "no-task",
            workspaceID?.uuidString ?? "no-workspace",
            enabledCapabilityIDs.joined(separator: ","),
            taskCanvasRevision,
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
    static func latestUserMessage(taskID: UUID, modelContext: ModelContext) -> UserMessage? {
        let userMessageType = TaskEventTypes.Conversation.userMessage.rawValue
        var descriptor = FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> { event in
                event.type == userMessageType && event.task?.id == taskID
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

    static func taskEventRevision(for task: AgentTask?) -> String {
        guard let task else { return "no-task" }
        return [
            task.id.uuidString,
            String(task.updatedAt.timeIntervalSince1970)
        ].joined(separator: "|")
    }
}

struct BrowserSessionPolicyTaskProjection {
    private var latestUserMessageByTask: [UUID: BrowserSessionPolicyContext.UserMessage] = [:]
    private var eventRevisionByTask: [UUID: UUID] = [:]

    @MainActor
    mutating func latestUserMessage(for taskID: UUID?, modelContext: ModelContext) -> String? {
        guard let taskID else { return nil }
        let latest = latestUserMessageByTask[taskID]
            ?? BrowserSessionPolicyContext.latestUserMessage(taskID: taskID, modelContext: modelContext)
        latestUserMessageByTask[taskID] = latest
        return latest?.payload
    }

    func revision(for task: AgentTask?) -> String {
        guard let task else { return BrowserSessionPolicyContext.taskEventRevision(for: nil) }
        return eventRevisionByTask[task.id]?.uuidString
            ?? BrowserSessionPolicyContext.taskEventRevision(for: task)
    }

    mutating func record(_ insertion: DurableTaskEventInsertion, selectedTaskID: UUID?) -> Bool {
        guard insertion.type == TaskEventTypes.Conversation.userMessage.rawValue else { return false }
        let candidate = BrowserSessionPolicyContext.UserMessage(
            payload: insertion.payload,
            timestamp: insertion.timestamp,
            eventID: insertion.eventID
        )
        if let current = latestUserMessageByTask[insertion.taskID] {
            if candidate.timestamp > current.timestamp
                || (candidate.timestamp == current.timestamp
                    && candidate.eventID.uuidString > current.eventID.uuidString) {
                latestUserMessageByTask[insertion.taskID] = candidate
            }
        } else {
            latestUserMessageByTask[insertion.taskID] = candidate
        }
        eventRevisionByTask[insertion.taskID] = insertion.eventID
        return insertion.taskID == selectedTaskID
    }
}
