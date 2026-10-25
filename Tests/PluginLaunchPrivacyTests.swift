import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin launch privacy")
struct PluginLaunchPrivacyTests {
    @Test("Old nested checkpoint records retain authority references and plain values without copying secrets")
    func oldCheckpointProjectionKeepsReferences() throws {
        let namespace = UUID()
        let account = Connector(name: "Checkpoint account", serviceType: "custom", baseURL: "https://api.example.com")
        account.credentialNamespaceID = namespace
        account.credentialKeys = ["API_TOKEN"]
        account.configKeys = ["API_TOKEN", "REGION"]
        account.configValues = ["checkpoint-account-secret", "retained-region"]
        let accountJSON = try object(PluginAccountRecord(account))
        let originalSkill = Skill(name: "Checkpoint skill")
        originalSkill.environmentKeys = ["API_TOKEN", "REGION"]
        originalSkill.environmentValues = ["", "retained-region"]
        var skill = try object(SkillLaunchRecord(originalSkill, workspaceID: UUID()))
        // The shape an older version could have persisted, including attached accounts.
        skill["environmentValues"] = ["checkpoint-skill-secret", "retained-region"]
        skill["attachedConnectors"] = [accountJSON]
        let policy: [String: Any] = [
            "pluginAccounts": [accountJSON], "authoredSkills": [skill],
            "pluginOverrides": ["skills": [skill]],
            "accountInventory": ["entries": [["account": accountJSON, "parentSkill": skill]]],
            "futureMetadata": ["reference": namespace.uuidString]
        ]
        let payload = try #require(String(data: JSONSerialization.data(withJSONObject: [
            "launchSnapshot": policy, "unknownCheckpointField": "preserved"
        ]), encoding: .utf8))
        let event = TaskEvent(task: AgentTask(title: "Old checkpoint", goal: "Recover accepted records"), eventType: "runtime.result.captured", payload: payload)
        let projection = try #require(WorkspaceConfigManager.taskRecoveryPayload(event))
        #expect(!projection.contains("checkpoint-account-secret"))
        #expect(!projection.contains("checkpoint-skill-secret"))
        #expect(projection.contains("retained-region"))
        #expect(projection.contains("preserved"))
        let result = try #require(JSONSerialization.jsonObject(with: Data(projection.utf8)) as? [String: Any])
        let launch = try #require(result["launchSnapshot"] as? [String: Any])
        let accounts = try #require(launch["pluginAccounts"] as? [[String: Any]])
        #expect((accounts.first?["credentialNamespaceID"] as? String) == namespace.uuidString)
        #expect((accounts.first?["id"] as? String) == account.id.uuidString)
        let inventory = try #require(launch["accountInventory"] as? [String: Any])
        let entries = try #require(inventory["entries"] as? [[String: Any]])
        let acceptedAccount = try #require(entries.first?["account"] as? [String: Any])
        #expect((acceptedAccount["credentialNamespaceID"] as? String) == namespace.uuidString)
        #expect(event.payload == payload)
        #expect(account.configValues == ["checkpoint-account-secret", "retained-region"])
    }

    @Test("An unreadable nested account refuses checkpoint export instead of copying unredacted payload")
    func malformedRecordIsNotExported() throws {
        let payload = #"{"launchSnapshot":{"pluginAccounts":[{"configKeys":"malformed","configValues":["legacy-secret"]}]}}"#
        let event = TaskEvent(task: AgentTask(title: "Unreadable checkpoint", goal: "Refuse malformed export"), eventType: "runtime.result.captured", payload: payload)
        #expect(WorkspaceConfigManager.taskRecoveryPayload(event) == nil)
        #expect(event.payload == payload)
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}
