import Testing
import Foundation
@testable import ASTRA

// MARK: - Phase 1A: Dictionary duplicate-key crash prevention

@Suite("Duplicate Key Safety")
struct DuplicateKeyTests {

    @Test("Skill.environmentVariables does not crash with duplicate keys")
    func skillDuplicateKeysNoCrash() {
        let skill = Skill(name: "Test")
        // Manually inject duplicate keys (simulates corruption or migration bug)
        skill.environmentKeys = ["API_KEY", "TOKEN", "API_KEY"]
        skill.environmentValues = ["first", "tok", "second"]

        // This must not crash — should use last value for duplicates
        let dict = skill.environmentVariables
        #expect(dict["API_KEY"] == "second")
        #expect(dict["TOKEN"] == "tok")
    }

    @Test("Connector.config does not crash with duplicate keys")
    func connectorDuplicateKeysNoCrash() {
        let connector = Connector(name: "Test")
        // Manually inject duplicate keys
        connector.configKeys = ["PROJECT", "ORG", "PROJECT"]
        connector.configValues = ["first", "acme", "second"]

        // This must not crash — should use last value for duplicates
        let dict = connector.config
        #expect(dict["PROJECT"] == "second")
        #expect(dict["ORG"] == "acme")
    }

    @Test("Skill.environmentVariables with mismatched array lengths doesn't crash")
    func skillMismatchedArrayLengths() {
        let skill = Skill(name: "Test")
        skill.environmentKeys = ["A", "B", "C"]
        skill.environmentValues = ["1", "2"] // shorter

        // zip stops at shorter array — must not crash
        let dict = skill.environmentVariables
        #expect(dict["A"] == "1")
        #expect(dict["B"] == "2")
        #expect(dict["C"] == nil) // dropped by zip
    }

    @Test("Connector.config with mismatched array lengths doesn't crash")
    func connectorMismatchedArrayLengths() {
        let connector = Connector(name: "Test")
        connector.configKeys = ["X", "Y"]
        connector.configValues = ["1", "2", "3"] // longer

        let dict = connector.config
        #expect(dict["X"] == "1")
        #expect(dict["Y"] == "2")
        #expect(dict.count == 2) // extra value is dropped
    }
}

// MARK: - Phase 1B: Credential key case normalization

@Suite("Credential Key Case Normalization")
struct CredentialKeyCaseTests {

    @Test("saveCredential uppercases key and deduplicates")
    func saveCredentialUppercaseDedup() {
        let connector = Connector(name: "Test")

        // Add a credential with lowercase key
        connector.saveCredential(key: "api_token", value: "v1")
        #expect(connector.credentialKeys == ["API_TOKEN"])

        // Save again with same lowercase key — should NOT create duplicate
        connector.saveCredential(key: "api_token", value: "v2")
        #expect(connector.credentialKeys.count == 1)
        #expect(connector.credentialKeys == ["API_TOKEN"])
    }

    @Test("saveCredential with mixed case finds existing uppercase entry")
    func saveCredentialMixedCase() {
        let connector = Connector(name: "Test")
        connector.saveCredential(key: "MyToken", value: "v1")
        #expect(connector.credentialKeys == ["MYTOKEN"])

        connector.saveCredential(key: "mytoken", value: "v2")
        #expect(connector.credentialKeys.count == 1)
        #expect(connector.credentialKeys == ["MYTOKEN"])
    }
}

// MARK: - Phase 4B: AgentTask default status

@Suite("AgentTask Defaults")
struct AgentTaskDefaultTests {

    @Test("New AgentTask defaults to .draft status")
    func taskDefaultsDraft() {
        let task = AgentTask(title: "Test", goal: "test")
        #expect(task.status == .draft)
    }

    @Test("New AgentTask defaults to shared execution settings")
    func taskDefaultsExecutionSettings() {
        let task = AgentTask(title: "Test", goal: "test")
        #expect(task.tokenBudget == TaskExecutionDefaults.tokenBudget)
        #expect(task.model == TaskExecutionDefaults.model)
        #expect(task.resolvedRuntimeID == TaskExecutionDefaults.runtime)
    }

    @Test("New TaskTemplate phases default to shared token budget")
    func taskTemplateDefaultsExecutionBudget() {
        let template = TaskTemplate(name: "Template", mainGoal: "Do work")
        #expect(template.beforeBudget == TaskExecutionDefaults.tokenBudget)
        #expect(template.mainBudget == TaskExecutionDefaults.tokenBudget)
        #expect(template.afterBudget == TaskExecutionDefaults.tokenBudget)
    }

    @Test("budgetProgress returns 0 for zero tokenBudget")
    func budgetProgressZeroBudget() {
        let task = AgentTask(title: "Test", goal: "test", tokenBudget: 0)
        #expect(task.budgetProgress == 0)
    }

    @Test("budgetProgress returns 0 for negative tokenBudget")
    func budgetProgressNegativeBudget() {
        let task = AgentTask(title: "Test", goal: "test")
        task.tokenBudget = -100
        #expect(task.budgetProgress >= 0)
    }

    @Test("ensureTaskFolder returns empty string when no workspace")
    func ensureTaskFolderNoWorkspace() throws {
        let task = AgentTask(title: "Test", goal: "test")
        let result = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        #expect(result == "")
    }
}

// MARK: - Phase 1C: Workspace delete cleans up Keychain

@Suite("Workspace Deletion Cleanup")
struct WorkspaceDeletionTests {

    @Test("Connector cleanupKeychain is idempotent")
    func connectorCleanupIdempotent() {
        let connector = Connector(name: "Test")
        // Calling cleanup on connector with no Keychain entries should not crash
        connector.cleanupKeychain()
        connector.cleanupKeychain()
    }

    @Test("All connectors on workspace can be iterated for cleanup")
    func workspaceConnectorsIterable() {
        let ws = Workspace(name: "Test", primaryPath: "/tmp/test")
        let c1 = Connector(name: "Jira")
        let c2 = Connector(name: "GitHub")
        c1.workspace = ws
        c2.workspace = ws

        // Verify all connectors are accessible for cleanup
        #expect(ws.connectors.count == 2)
        for connector in ws.connectors {
            connector.cleanupKeychain()
        }
    }

    @Test("Skill connectors are also reachable through workspace")
    func skillConnectorsReachable() {
        let ws = Workspace(name: "Test", primaryPath: "/tmp/test")
        let skill = Skill(name: "Dev")
        skill.workspace = ws
        let c = Connector(name: "DB")
        c.skill = skill

        // Connectors attached to skills should also be accessible
        let allConnectors = ws.connectors + ws.skills.flatMap(\.connectors)
        #expect(allConnectors.contains(where: { $0.name == "DB" }))
    }
}
