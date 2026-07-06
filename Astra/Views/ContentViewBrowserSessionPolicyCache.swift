import Foundation
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
    var enabledCapabilityIDs: [String]
    var approvalRevision: String
    var packageDefinitionFingerprint: String
    var taskEventRevision: String

    init(
        taskID: UUID?,
        enabledCapabilityIDs: [String],
        approvalRevision: String,
        packageDefinitionFingerprint: String,
        taskEventRevision: String
    ) {
        self.taskID = taskID
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

enum BrowserSessionPolicyContext {
    static func latestContextText(for task: AgentTask) -> String {
        let latestUserMessage = task.events
            .filter { $0.type == "user.message" }
            .max { $0.timestamp < $1.timestamp }?
            .payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let latestUserMessage, !latestUserMessage.isEmpty {
            return latestUserMessage
        }
        return task.goal
    }

    static func taskEventRevision(for task: AgentTask?) -> String {
        guard let task else { return "no-task" }
        let userMessages = task.events.filter { $0.type == "user.message" }
        let latest = userMessages.max { $0.timestamp < $1.timestamp }
        return [
            task.id.uuidString,
            String(userMessages.count),
            String(latest?.timestamp.timeIntervalSince1970 ?? 0),
            String(latest?.payload.hashValue ?? 0)
        ].joined(separator: "|")
    }
}
