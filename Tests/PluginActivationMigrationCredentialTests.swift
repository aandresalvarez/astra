import Foundation
import SwiftData
import Testing
import ASTRACore
@testable import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin activation migration credential publication", .serialized)
struct PluginActivationMigrationCredentialTests {
    @Test("Migrating a later legacy field cannot configure an already accepted queued skill", arguments: [false, true])
    func legacyRawValueCannotEnterAcceptedNamespace(privateNamespace: Bool) throws {
        try withLegacyState(privateNamespace: privateNamespace) { state in
            let report = try PluginActivationMigration.migrate(modelContext: state.env.context, packages: [state.package])
            try #require(report.skillsProjected == 1)
            let current = try #require(PluginRuntimeProjection.project(workspace: state.env.workspace, packages: [state.package]).skills.first)
            try #require(current.environmentVariables["SECOND_TOKEN"] == "later-legacy-migration-token")
            let accepted = try state.acceptedSkill()
            #expect(accepted.environmentVariables["API_TOKEN"] == "accepted-before-activation-migration")
            #expect(accepted.environmentVariables["SECOND_TOKEN"] == nil)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "SECOND_TOKEN", skillID: state.namespace, store: KeychainSecretStore()) == nil)
            let outbox = try #require(PluginSecretCleanupOutbox(for: state.env.context))
            #expect(try outbox.pending().contains(state.namespace))
            PluginSecretCleanupOutbox.resumePending(modelContext: state.env.context)
            #expect(try state.acceptedSkill().environmentVariables["API_TOKEN"] == "accepted-before-activation-migration")
        }
    }

    @Test("An unproved migration save never publishes a credential or acknowledges model changes", arguments: [false, true])
    func unprovedSaveKeepsSourceAndAuthority(throwing: Bool) throws {
        try withLegacyState { state in
            let before = WorkspaceCapabilityActivation.snapshot(state.env.workspace)
            var observedBeforeCommit: String?
            #expect(throws: (any Error).self) {
                _ = try PluginActivationMigration.migrate(modelContext: state.env.context, packages: [state.package], persist: { _ in
                    observedBeforeCommit = SkillSecretSeam.required.loadSecretValue(key: "SECOND_TOKEN", skillID: state.namespace, store: KeychainSecretStore())
                    if throwing { throw NSError(domain: "synthetic.activation-migration.save", code: 1) }
                })
            }
            #expect(observedBeforeCommit == nil)
            #expect(WorkspaceCapabilityActivation.snapshot(state.env.workspace) == before)
            let saved = ModelContext(state.env.context.container)
            #expect(try saved.fetchCount(FetchDescriptor<PluginActivation>()) == 0)
            let source = try #require(try saved.fetch(FetchDescriptor<Skill>()).first { $0.id == state.skillID })
            #expect(source.environmentValues == ["", "later-legacy-migration-token"])
            #expect(try state.acceptedSkill().environmentVariables["SECOND_TOKEN"] == nil)
        }
    }

    @Test("A saved migration keeps its credential and resumes its original receipt after reopening", arguments: [false, true])
    func savedMigrationRecoversForward(reportedSaveFailure: Bool) throws {
        try withLegacyState { state in
            let persist: ((ModelContext) throws -> Void)? = reportedSaveFailure ? { context in
                try context.save()
                throw NSError(domain: "synthetic.activation-migration.reported-save", code: 1)
            } : nil
            var operationID: UUID?
            do {
                _ = try PluginActivationMigration.migrate(modelContext: state.env.context, packages: [state.package],
                    persist: persist, rewriteMirror: reportedSaveFailure ? nil : { _ in false })
                Issue.record("An incomplete saved migration must report its recovery")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            catch { Issue.record("A saved migration must retain a typed recovery boundary: \(type(of: error))") }
            let reopened = try state.env.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).first)
            let namespace = PluginRuntimeProjection.credentialID(of: saved, componentID: CapabilityResourceOrigin.componentID(for: state.package.skills[0]))
            #expect(SkillSecretSeam.required.loadSecretValue(key: "SECOND_TOKEN", skillID: namespace, store: KeychainSecretStore()) == "later-legacy-migration-token")
            #expect(state.env.workspace.legacyEnabledCapabilityIDs.isEmpty)
            let id = try #require(operationID)
            #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt == nil)
            #expect(PluginOperationRecovery.resumePending(modelContext: reopened.mainContext, only: id).completed == 1)
            PluginSecretCleanupOutbox.resumePending(modelContext: reopened.mainContext)
            #expect(PluginRuntimeProjection.credentialID(of: saved, componentID: CapabilityResourceOrigin.componentID(for: state.package.skills[0])) == namespace)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "SECOND_TOKEN", skillID: namespace, store: KeychainSecretStore()) == "later-legacy-migration-token")
            let task = try #require(try reopened.mainContext.fetch(FetchDescriptor<AgentTask>()).first { $0.id == state.task.id })
            let request = try #require(try reopened.mainContext.fetch(FetchDescriptor<TaskTurnRequest>()).first)
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            let accepted = try #require(TaskCapabilityResolver(task: launch).resourceInventory.behaviorSkills.first { $0.id == state.skillID })
            #expect(accepted.environmentVariables["API_TOKEN"] == "accepted-before-activation-migration")
            #expect(accepted.environmentVariables["SECOND_TOKEN"] == nil)
        }
    }

    @Test("Migration cannot save unrelated editor work")
    func migrationRejectsPendingEdits() throws {
        try withLegacyState { state in
            let name = state.env.workspace.name
            state.env.workspace.name = "Unfinished unrelated edit"
            #expect(throws: PluginActivationMigration.MigrationError.pendingEdits) {
                _ = try PluginActivationMigration.migrate(modelContext: state.env.context, packages: [state.package])
            }
            #expect(state.env.workspace.name == "Unfinished unrelated edit")
            #expect(state.env.context.hasChanges)
            let savedName = try ModelContext(state.env.context.container).fetch(FetchDescriptor<Workspace>()).first?.name
            #expect(savedName == name)
        }
    }

    @MainActor
    private struct LegacyState {
        let env: PluginAddCommitTests.Fixture
        let package: PluginPackage
        let task: AgentTask
        let snapshot: AgentTaskLaunchSnapshot
        let namespace: UUID
        let skillID: UUID
        func acceptedSkill() throws -> Skill {
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            return try #require(TaskCapabilityResolver(task: launch).resourceInventory.behaviorSkills.first { $0.id == skillID })
        }
    }

    private func withLegacyState(privateNamespace: Bool = false, _ body: (LegacyState) throws -> Void) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            var package = PluginOperationsTests.package(version: "1.0.0")
            package.id = env.package.id
            package.connectors = []; package.localTools = []
            package.skills[0].environmentKeys = ["API_TOKEN", "SECOND_TOKEN"]
            package.skills[0].environmentValues = ["", ""]
            let library = CapabilityLibrary()
            try library.install(package)
            defer { _ = try? library.removePackage(id: package.id) }
            let spec = package.skills[0]
            let skill = Skill(name: spec.name, icon: spec.icon, skillDescription: spec.description,
                allowedTools: spec.allowedTools, disallowedTools: spec.disallowedTools,
                customTools: spec.customTools, behaviorInstructions: spec.behaviorInstructions)
            skill.environmentKeys = spec.environmentKeys
            skill.environmentValues = spec.environmentValues
            if privateNamespace { skill.credentialNamespaceID = UUID() }
            CapabilityResourceOrigin.stamp(skill, package: package, componentID: CapabilityResourceOrigin.componentID(for: spec))
            skill.workspace = env.workspace
            env.context.insert(skill)
            env.workspace.legacyEnabledCapabilityIDs = [package.id]
            env.workspace.legacyInstalledPluginIDs = [package.id]
            env.workspace.legacyInstalledPluginVersions = [package.version]
            let namespace = skill.secretNamespaceID
            let skillID = skill.id
            try #require(SkillSecretSeam.required.saveSecretValue("accepted-before-activation-migration", key: "API_TOKEN",
                skillID: namespace, skillName: skill.name, allowUserInteraction: false))
            let task = AgentTask(title: "Queued before activation migration", goal: "Use accepted legacy skill", workspace: env.workspace)
            task.skills = [skill]
            env.context.insert(task)
            try env.context.save()
            let before = try #require(TaskCapabilityResolver(task: task).resourceInventory.behaviorSkills.first { $0.id == skillID })
            try #require(before.environmentVariables["API_TOKEN"] == "accepted-before-activation-migration")
            try #require(before.environmentVariables["SECOND_TOKEN"] == nil)
            _ = try ExecutionRequestSubmissionService.submitInitial(for: task, into: env.context).get()
            let request = try #require(try env.context.fetch(FetchDescriptor<TaskTurnRequest>()).first)
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            try #require(snapshot.authoredSkills?.contains { $0.id == skillID } == true)
            skill.environmentValues = ["", "later-legacy-migration-token"]
            try env.context.save()
            try body(LegacyState(env: env, package: package, task: task, snapshot: snapshot, namespace: namespace, skillID: skillID))
        }
    }
}
