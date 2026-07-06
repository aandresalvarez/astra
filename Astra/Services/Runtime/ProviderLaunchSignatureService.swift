import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

struct ProviderLaunchSignaturePayload: Codable, Equatable {
    let version: Int
    let runtimeID: String
    let model: String
    let policyLevel: String
    var policyScope: String
    let providerAdapterVersion: Int
    let permissionMode: String
    var allowedTools: [String]
    var askFirstTools: [String]
    var deniedTools: [String]
    let allowedShellPatterns: [String]
    let askFirstShellPatterns: [String]
    let deniedShellPatterns: [String]
    let allowedURLPatterns: [String]
    let deniedURLPatterns: [String]
    let runtimeSupportTools: [String]
    let scopedSkillIDs: [String]
    let scopedSkillNames: [String]
    let scopedConnectorDescriptors: [String]
    let scopedLocalToolCommands: [String]
    let environmentKeyNames: [String]
    let credentialLabels: [String]
    let mcpServerIDs: [String]
    let browserAdapters: [String]
    let promptSchemaVersion: String
    let executionEnvironmentFingerprint: String?

    var signatureValue: String {
        [
            "v=\(version)",
            "runtime=\(runtimeID)",
            "model=\(model)",
            "policyLevel=\(policyLevel)",
            "policyScope=\(policyScope)",
            "adapter=\(providerAdapterVersion)",
            "permission=\(permissionMode)",
            "allowed=\(allowedTools.joined(separator: ","))",
            "ask=\(askFirstTools.joined(separator: ","))",
            "denied=\(deniedTools.joined(separator: ","))",
            "allowShell=\(allowedShellPatterns.joined(separator: ","))",
            "askShell=\(askFirstShellPatterns.joined(separator: ","))",
            "denyShell=\(deniedShellPatterns.joined(separator: ","))",
            "allowURL=\(allowedURLPatterns.joined(separator: ","))",
            "denyURL=\(deniedURLPatterns.joined(separator: ","))",
            "support=\(runtimeSupportTools.joined(separator: ","))",
            "skillIDs=\(scopedSkillIDs.joined(separator: ","))",
            "skillNames=\(scopedSkillNames.joined(separator: ","))",
            "connectors=\(scopedConnectorDescriptors.joined(separator: ","))",
            "tools=\(scopedLocalToolCommands.joined(separator: ","))",
            "env=\(environmentKeyNames.joined(separator: ","))",
            "credentials=\(credentialLabels.joined(separator: ","))",
            "mcp=\(mcpServerIDs.joined(separator: ","))",
            "browserAdapters=\(browserAdapters.joined(separator: ","))",
            "prompt=\(promptSchemaVersion)",
            "environment=\(executionEnvironmentFingerprint ?? WorkspaceExecutionEnvironment.host.signatureFingerprint)"
        ].joined(separator: "\u{1f}")
    }
}

enum ProviderLaunchSignatureService {
    static let eventType = "astra.provider_launch_signature"

    @MainActor
    static func make(
        for task: AgentTask,
        manifest: RunPermissionManifest,
        contextText: String,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot
    ) -> ProviderLaunchSignaturePayload {
        let scope = capabilityResolutionSnapshot.scope(.providerLaunch(contextText: contextText))
        let supportTools = manifest.providerRender.runtimeSupportTools.map { descriptor in
            [
                descriptor.name,
                descriptor.providerNativePermission ?? "",
                descriptor.allowedInputKeys.joined(separator: "+"),
                descriptor.deniedInputKeys.joined(separator: "+")
            ].joined(separator: ":")
        }
        let connectorDescriptors = scope.connectors.map { connector in
            [
                connector.id.uuidString,
                connector.name,
                connector.serviceType,
                connector.baseURL
            ].joined(separator: ":")
        }
        let localToolCommands = scope.localTools.compactMap { tool -> String? in
            let command = tool.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return nil }
            return command
        }
        return ProviderLaunchSignaturePayload(
            version: 1,
            runtimeID: manifest.providerID.rawValue,
            model: manifest.model,
            policyLevel: manifest.policyLevel.rawValue,
            policyScope: manifest.policyScope.rawValue,
            providerAdapterVersion: manifest.providerRender.adapterVersion,
            permissionMode: manifest.providerRender.permissionMode.rawValue,
            allowedTools: canonicalStrings(manifest.providerRender.allowedTools),
            askFirstTools: canonicalStrings(manifest.providerRender.askFirstTools),
            deniedTools: canonicalStrings(manifest.providerRender.deniedTools),
            allowedShellPatterns: canonicalStrings(manifest.providerRender.allowedShellPatterns),
            askFirstShellPatterns: canonicalStrings(manifest.providerRender.askFirstShellPatterns),
            deniedShellPatterns: canonicalStrings(manifest.providerRender.deniedShellPatterns),
            allowedURLPatterns: canonicalStrings(manifest.providerRender.allowedURLPatterns),
            deniedURLPatterns: canonicalStrings(manifest.providerRender.deniedURLPatterns),
            runtimeSupportTools: canonicalStrings(supportTools),
            scopedSkillIDs: canonicalStrings(scope.behaviorSkills.map { $0.id.uuidString }),
            scopedSkillNames: canonicalStrings(scope.behaviorSkills.map(\.name)),
            scopedConnectorDescriptors: canonicalStrings(connectorDescriptors),
            scopedLocalToolCommands: canonicalStrings(localToolCommands),
            environmentKeyNames: canonicalStrings(manifest.environmentKeyNames),
            credentialLabels: canonicalStrings(manifest.credentialLabels),
            mcpServerIDs: canonicalStrings(manifest.mcpServers.map { "\($0.packageID):\($0.id)" }),
            browserAdapters: canonicalStrings(scope.enabledBrowserAdapters),
            promptSchemaVersion: "context_capsule_v2",
            executionEnvironmentFingerprint: DockerExecutionPlanner.resolveEnvironment(for: task).signatureFingerprint
        )
    }

    static func grantStrings(for manifest: RunPermissionManifest) -> Set<String> {
        guard !manifest.approvalGrants.isEmpty else { return [] }
        return Set(
            PermissionBroker.providerGrantStrings(for: manifest.approvalGrants, runtime: manifest.providerID)
                + PermissionBroker.providerRuntimeGrantStrings(for: manifest.approvalGrants, runtime: manifest.providerID)
        )
    }

    // Approval grants accumulate inside a task, so signatures are compared
    // modulo grant-derived entries: otherwise the first post-approval turn
    // always reads as a policy change and drops the provider session.
    static func grantNeutralizedValue(
        _ payload: ProviderLaunchSignaturePayload,
        grantStrings: Set<String>
    ) -> String {
        guard !grantStrings.isEmpty else { return payload.signatureValue }
        let grantKeys = Set(grantStrings.map(canonicalToolKey))
        var neutral = payload
        neutral.allowedTools = payload.allowedTools.filter { !grantStrings.contains($0) }
        neutral.askFirstTools = payload.askFirstTools.filter { !grantKeys.contains(canonicalToolKey($0)) }
        neutral.deniedTools = payload.deniedTools.filter { !grantKeys.contains(canonicalToolKey($0)) }
        neutral.policyScope = "grant_neutral"
        return neutral.signatureValue
    }

    @MainActor
    static func record(
        _ signature: ProviderLaunchSignaturePayload,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        guard let data = try? JSONEncoder().encode(signature),
              let payload = String(data: data, encoding: .utf8) else {
            return
        }
        run.providerLaunchSignatureJSON = payload
        modelContext.insert(TaskEvent(task: task, type: eventType, payload: payload, run: run))
    }

    static func storedSignature(for task: AgentTask, run: TaskRun) -> ProviderLaunchSignaturePayload? {
        if let payload = run.providerLaunchSignatureJSON,
           let data = payload.data(using: .utf8),
           let signature = try? JSONDecoder().decode(ProviderLaunchSignaturePayload.self, from: data) {
            return signature
        }
        return task.events
            .filter { $0.type == eventType && $0.run?.id == run.id }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { event -> ProviderLaunchSignaturePayload? in
                guard let data = event.payload.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(ProviderLaunchSignaturePayload.self, from: data)
            }
            .last
    }

    private static func canonicalToolKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func canonicalStrings(_ values: [String]) -> [String] {
        Array(Set(values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
    }
}
