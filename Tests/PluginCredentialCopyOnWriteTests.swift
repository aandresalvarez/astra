import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Plugin credential edits preserve the saved generation", .serialized)
@MainActor
struct PluginCredentialCopyOnWriteTests {
    @Test("An unavailable secret read is an error rather than an empty editable setting")
    func unavailableSettingReadIsNotEmpty() throws {
        let activation = PluginActivation(pluginID: "read-status")
        var skill = PluginOperationsTests.package(version: "1.0.0").skills[0]
        skill.environmentKeys = ["PROJECT", "API_TOKEN"]
        skill.environmentValues = ["default-project", ""]
        #expect(throws: PluginOperations.OperationError.secretReadFailed(key: "API_TOKEN")) {
            try PluginOperations.setting("API_TOKEN", of: skill, in: activation, secrets: UnreadableGenerationSecret.self)
        }
        #expect(try PluginOperations.setting("PROJECT", of: skill, in: activation, secrets: UnreadableGenerationSecret.self) == "default-project")
    }

    @Test("An edit preserves a queued request's accepted generation", arguments: [false, true], ["replacement-secret", ""])
    func queuedRequestKeepsItsCredentialValue(legacy: Bool, replacement: String) throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let original: Skill
        if legacy {
            WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableCapability(env.package.id) }
            WorkspaceCapabilityActivation.recordAccepted(pluginID: env.package.id, version: env.package.version,
                digest: PluginDefinitionDigest.content(of: env.package), in: env.workspace)
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace))
            let namespace = PluginRuntimeProjection.credentialID(of: activation, componentID: env.component)
            #expect(GenerationSecrets.saveSecretValue("submitted-secret", key: "API_TOKEN", skillID: namespace,
                skillName: "Legacy", allowUserInteraction: false))
            WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: "\(env.component)#API_TOKEN", on: activation)
            try env.context.save()
            original = try #require(PluginRuntimeProjection.project(workspace: env.workspace, packages: [env.package]).skills.first)
            #expect(original.secretNamespaceID == original.id)
        } else {
            original = try env.enable("submitted-secret")
        }
        let task = AgentTask(title: "Queued credential edit", goal: "Run accepted plugin", workspace: env.workspace)
        env.context.insert(task)
        let message = TaskEvent(task: task, eventType: TaskEventTypes.Conversation.userMessage, payload: "Run accepted plugin")
        env.context.insert(message)
        let request = TaskTurnRequest(task: task, messageEventID: message.id, sequence: 1, pluginDefinitions: [env.package])
        env.context.insert(request)
        try env.context.save()
        let submitted = try #require(request.executionPolicySnapshot?.pluginActivations)
        try PluginOperations.setSetting("API_TOKEN", to: replacement, of: env.package.skills[0],
            pluginID: env.package.id, in: env.workspace, modelContext: env.context, secrets: GenerationSecrets.self)
        let current = try #require(PluginRuntimeProjection.project(workspace: env.workspace, packages: [env.package]).skills.first)
        #expect(current.id == original.id)
        #expect(current.secretNamespaceID != original.secretNamespaceID)
        #expect(current.environmentVariables["API_TOKEN"] == (replacement.isEmpty ? nil : replacement))
        let launch = Workspace(name: "Submitted request", primaryPath: "")
        WorkspaceCapabilityActivation.copyActivations(submitted, of: env.workspace, to: launch,
            accountsByID: [:], definitionsFrozen: true)
        let queued = try #require(PluginRuntimeProjection.project(workspace: launch, packages: [env.package]).skills.first)
        #expect(queued.environmentVariables["API_TOKEN"] == "submitted-secret")
    }

    @Test("Repeated Add preserves an existing request's secret and rotates only the current activation")
    func repeatedAddPreservesQueuedGeneration() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let old = try env.enable("accepted-add-secret")
        let task = AgentTask(title: "Repeated Add", goal: "Run the accepted plugin", workspace: env.workspace)
        env.context.insert(task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [env.package])
        env.context.insert(request)
        try env.context.save()
        let frozen = try #require(request.executionPolicySnapshot?.pluginActivations)
        let current = try env.enable("new-add-secret")
        #expect(current.id == old.id)
        #expect(current.secretNamespaceID != old.secretNamespaceID)
        #expect(current.environmentVariables["API_TOKEN"] == "new-add-secret")
        let launch = Workspace(name: "Accepted Add request", primaryPath: "")
        WorkspaceCapabilityActivation.copyActivations(frozen, of: env.workspace, to: launch,
            accountsByID: [:], definitionsFrozen: true)
        let queued = try #require(PluginRuntimeProjection.project(workspace: launch, packages: [env.package]).skills.first)
        #expect(queued.environmentVariables["API_TOKEN"] == "accepted-add-secret")
    }

    @Test("A failed repeated Add never overwrites the credential referenced by the saved store")
    func failedRepeatedAddPreservesSavedValueBeforeCommit() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let old = try env.enable("saved-add-secret")
        var valueBeforeCommit: String?
        #expect(throws: (any Error).self) {
            try env.installer.enable(env.package, in: env.workspace, modelContext: env.context,
                configInputs: ["API_TOKEN": "attempted-add-secret"], persist: { _, context in
                    let saved = try! ModelContext(context.container).fetch(FetchDescriptor<PluginActivation>()).first!
                    valueBeforeCommit = GenerationSecrets.value(in: PluginRuntimeProjection.credentialID(of: saved, componentID: env.component))
                    return false
                })
        }
        #expect(valueBeforeCommit == "saved-add-secret")
        #expect(GenerationSecrets.value(in: old.secretNamespaceID) == "saved-add-secret")
    }

    @Test("Repeated Add keeps its complete saved generation when recovery is pending", arguments: [false, true])
    func repeatedAddRecoversForward(failureAfterSave: Bool) throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let old = try env.enable("previous-add-value")
        var operationID: UUID?
        do {
            try env.installer.enable(env.package, in: env.workspace, modelContext: env.context,
                configInputs: ["API_TOKEN": "committed-add-value"],
                persist: { _, context in try! context.save(); return !failureAfterSave },
                rewriteMirror: { _ in false })
            Issue.record("The saved Add must report its pending recovery")
        } catch let problem as PluginOperationProblem { operationID = problem.operationID }
        let id = try #require(operationID)
        let reopened = try env.disk.disk.reopen()
        let activation = try #require(try reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).first)
        let current = PluginRuntimeProjection.credentialID(of: activation, componentID: env.component)
        #expect(current != old.secretNamespaceID)
        #expect(GenerationSecrets.value(in: current) == "committed-add-value")
        #expect(GenerationSecrets.value(in: old.secretNamespaceID) == "previous-add-value")
        #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt == nil)
        #expect(PluginOperationRecovery.resumePending(modelContext: reopened.mainContext).completed == 1)
        PluginSecretCleanupOutbox.resumePending(modelContext: reopened.mainContext, outbox: env.outbox,
            secrets: GenerationSecrets.self)
        #expect(GenerationSecrets.value(in: current) == "committed-add-value")
        #expect(GenerationSecrets.value(in: old.secretNamespaceID) == nil)
        #expect(try env.outbox.entries().isEmpty)
    }

    @Test("A failed Add keeps cleanup intent for a new component when Keychain refuses compensation")
    func refusedNewComponentCleanupRetainsIntent() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let old = try env.enable("previous-component-value")
        var package = env.package
        var added = package.skills[0]
        added.id = "new-component"
        added.environmentKeys = ["NEW_TOKEN"]; added.environmentValues = [""]
        package.skills.append(added)
        let component = CapabilityResourceOrigin.componentID(for: added)
        let installer = CapabilityInstaller(library: env.disk.disk.library, skillSecrets: RefusingGenerationCleanup.self)
        var attemptedNamespace: UUID?
        #expect(throws: (any Error).self) {
            try installer.enable(package, in: env.workspace, modelContext: env.context,
                configInputs: ["NEW_TOKEN": "orphaned-component-value"], persist: { _, _ in
                    let activation = WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace)!
                    attemptedNamespace = PluginRuntimeProjection.credentialID(of: activation, componentID: component)
                    return false
                })
        }
        let orphan = try #require(attemptedNamespace)
        #expect(GenerationSecrets.loadSecretValue(key: "NEW_TOKEN", skillID: orphan, store: KeychainSecretStore()) == "orphaned-component-value")
        #expect(try env.outbox.pendingKeys().contains(.init(key: "NEW_TOKEN", skillID: orphan)))
        #expect(GenerationSecrets.value(in: old.secretNamespaceID) == "previous-component-value")
        PluginSecretCleanupOutbox.resumePending(modelContext: ModelContext(env.context.container),
            outbox: env.outbox, secrets: GenerationSecrets.self)
        #expect(GenerationSecrets.loadSecretValue(key: "NEW_TOKEN", skillID: orphan, store: KeychainSecretStore()) == nil)
        #expect(GenerationSecrets.value(in: old.secretNamespaceID) == "previous-component-value")
        #expect(try env.outbox.entries().isEmpty)
    }

    @Test("Update cannot publish a rename when the source credential vault is unavailable", arguments: [false, true])
    func updateRejectsUnreadableRename(automatic: Bool) throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let old = try env.enable("accepted-rename-secret")
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace))
        let before = PluginActivationRecord(activation)
        var update = env.package
        update.version = "2.0.0"
        update.skills[0].replaces = [env.component]
        update.skills[0].id = "renamed-component"
        #expect(throws: (any Error).self) {
            try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [update],
                mode: automatic ? .automatic : .release, secrets: UnreadableGenerationSecret.self)
        }
        let saved = try #require(try ModelContext(env.context.container).fetch(FetchDescriptor<PluginActivation>()).first)
        #expect(PluginActivationRecord(saved) == before)
        #expect(GenerationSecrets.value(in: old.secretNamespaceID) == "accepted-rename-secret")
        #expect(try env.outbox.entries().isEmpty)
    }

    @Test("Add's private rename destination does not depend on deleting its own preparation")
    func addingRenamedPrivateGenerationDoesNotNeedCleanup() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let old = try env.enable("accepted-add-rename-token")
        var updated = env.package
        updated.version = "2.0.0"
        updated.skills[0].id = "private-add-rename"
        updated.skills[0].replaces = [env.component]
        let installer = CapabilityInstaller(library: env.installer.library, appVersion: SemanticVersion(1, 0, 0),
            skillSecrets: RefusingGenerationCleanup.self)
        try installer.enable(updated, in: env.workspace, modelContext: env.context)
        let current = try #require(PluginRuntimeProjection.project(workspace: env.workspace, packages: [updated]).skills.first)
        #expect(current.environmentVariables["API_TOKEN"] == "accepted-add-rename-token")
        #expect(current.secretNamespaceID != old.secretNamespaceID)
        #expect(GenerationSecrets.value(in: old.secretNamespaceID) == "accepted-add-rename-token")
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: updated.id, in: env.workspace))
        let retiredPrivateCopy = PluginRuntimeProjection.credentialID(of: activation, componentID: env.component)
        try #require(GenerationSecrets.value(in: retiredPrivateCopy) == "accepted-add-rename-token")
        #expect(try env.outbox.pending().contains(retiredPrivateCopy))
        PluginSecretCleanupOutbox.resumePending(modelContext: ModelContext(env.context.container),
            outbox: env.outbox, secrets: GenerationSecrets.self)
        #expect(GenerationSecrets.value(in: retiredPrivateCopy) == nil)
        #expect(current.environmentVariables["API_TOKEN"] == "accepted-add-rename-token")
    }

    @Test("A failed Update retains cleanup for a renamed credential when compensation is refused")
    func failedUpdateRetainsRefusedCopyCleanup() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let old = try env.enable("saved-update-value")
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace))
        var update = env.package
        update.version = "2.0.0"
        update.skills[0].replaces = [env.component]
        update.skills[0].id = "renamed-update-component"
        let component = CapabilityResourceOrigin.componentID(for: update.skills[0])
        var stagedOrphan: UUID?
        #expect(throws: (any Error).self) {
            try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [update], mode: .release,
                secrets: RefusingGenerationCleanup.self, persist: { _ in
                    stagedOrphan = PluginRuntimeProjection.credentialID(of: activation, componentID: component)
                    throw CocoaError(.fileWriteUnknown)
                })
        }
        let orphan = try #require(stagedOrphan)
        #expect(orphan != PluginActivation.credentialID(workspaceID: env.workspace.id, pluginID: env.package.id, componentID: component, runtimeSeed: activation.namespaceSeed, generation: activation.credentialNamespaceSeed))
        #expect(GenerationSecrets.value(in: orphan) == "saved-update-value")
        #expect(try env.outbox.pending().contains(orphan))
        #expect(GenerationSecrets.value(in: old.secretNamespaceID) == "saved-update-value")
        PluginSecretCleanupOutbox.resumePending(modelContext: ModelContext(env.context.container),
            outbox: env.outbox, secrets: GenerationSecrets.self)
        #expect(GenerationSecrets.value(in: orphan) == nil)
        #expect(GenerationSecrets.value(in: old.secretNamespaceID) == "saved-update-value")
        #expect(try env.outbox.entries().isEmpty)
    }

    @Test("Before a clear commits, the saved activation still resolves its old secret without compensation")
    func failedClearNeverRemovesTheSavedValue() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let original = try env.enable("durable-secret")
        var recordedBeforeCommit = false
        var valueBeforeCommit: String?
        #expect(throws: PluginOperations.OperationError.saveFailed) {
            try PluginOperations.setSetting("API_TOKEN", to: "", of: env.package.skills[0],
                pluginID: env.package.id, in: env.workspace, modelContext: env.context, secrets: GenerationSecrets.self,
                persist: { _, context in
                    let saved = try #require(try ModelContext(context.container).fetch(FetchDescriptor<PluginActivation>()).first)
                    recordedBeforeCommit = saved.secretSettingKeys.contains("\(env.component)#API_TOKEN")
                    valueBeforeCommit = GenerationSecrets.value(in: PluginRuntimeProjection.credentialID(of: saved, componentID: env.component))
                    throw CocoaError(.fileWriteUnknown)
                })
        }
        #expect(recordedBeforeCommit)
        // This observation is the actual interruption window: catch/restore
        // has not run yet, and the saved store still references this value.
        #expect(valueBeforeCommit == "durable-secret")
        #expect(GenerationSecrets.value(in: original.secretNamespaceID) == "durable-secret")
    }
    @Test("A new generation copies other configured secrets and cleans the old one only after commit")
    func otherKeysSurviveAndCleanupIsDeferred() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        var package = env.package
        package.skills[0].environmentKeys.append("SECOND_TOKEN")
        package.skills[0].environmentValues.append("")
        _ = try env.installer.enable(package, in: env.workspace, modelContext: env.context,
            configInputs: ["API_TOKEN": "original", "SECOND_TOKEN": "retained"])
        let original = try #require(PluginRuntimeProjection.project(workspace: env.workspace, packages: [package]).skills.first)
        try PluginOperations.setSetting("API_TOKEN", to: "updated", of: package.skills[0], pluginID: package.id,
            in: env.workspace, modelContext: env.context, secrets: GenerationSecrets.self)
        let current = try #require(PluginRuntimeProjection.project(workspace: env.workspace, packages: [package]).skills.first)
        #expect(current.environmentVariables["API_TOKEN"] == "updated")
        #expect(current.environmentVariables["SECOND_TOKEN"] == "retained")
        #expect(GenerationSecrets.value(in: original.secretNamespaceID) == "original")
        #expect(try env.outbox.pending().contains(original.secretNamespaceID))
        let journal = try String(contentsOf: env.outbox.fileURL, encoding: .utf8)
        #expect(!journal.contains("original") && !journal.contains("updated") && !journal.contains("retained"))
        PluginSecretCleanupOutbox.resumePending(modelContext: ModelContext(env.context.container),
            outbox: env.outbox, secrets: GenerationSecrets.self)
        #expect(GenerationSecrets.value(in: original.secretNamespaceID) == nil)
        #expect(current.environmentVariables["SECOND_TOKEN"] == "retained")
        #expect(try env.outbox.entries().isEmpty)
    }

    @Test("An unreadable existing key aborts before a generation is written or published")
    func readFailurePreservesTheOriginalGeneration() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        var package = env.package
        package.skills[0].environmentKeys.append("SECOND_TOKEN")
        package.skills[0].environmentValues.append("")
        _ = try env.installer.enable(package, in: env.workspace, modelContext: env.context,
            configInputs: ["API_TOKEN": "original", "SECOND_TOKEN": "locked"])
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let before = PluginActivationRecord(activation)
        #expect(throws: PluginOperations.OperationError.secretReadFailed(key: "SECOND_TOKEN")) {
            try PluginOperations.setSetting("API_TOKEN", to: "unpublished", of: package.skills[0], pluginID: package.id,
                in: env.workspace, modelContext: env.context, secrets: UnreadableGenerationSecret.self)
        }
        #expect(PluginActivationRecord(activation) == before)
        #expect(GenerationSecrets.namespace(holding: "unpublished") == nil)
        #expect(try env.outbox.entries().isEmpty)
    }

    @Test("A saved generation with a failed mirror remains complete and recovers forward after reopen")
    func mirrorFailureKeepsBothGenerationsRecoverable() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let original = try env.enable("old-mirror-value")
        var operationID: UUID?
        do {
            try PluginOperations.setSetting("API_TOKEN", to: "saved-new-value", of: env.package.skills[0],
                pluginID: env.package.id, in: env.workspace, modelContext: env.context, secrets: GenerationSecrets.self,
                rewriteMirror: { _ in false })
            Issue.record("The saved cutover must report its mirror debt")
        } catch let problem as PluginOperationProblem { operationID = problem.operationID }
        let id = try #require(operationID)
        let reopened = try env.disk.disk.reopen()
        let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).first)
        let namespace = PluginRuntimeProjection.credentialID(of: saved, componentID: env.component)
        #expect(namespace != original.secretNamespaceID)
        #expect(GenerationSecrets.value(in: namespace) == "saved-new-value")
        #expect(GenerationSecrets.value(in: original.secretNamespaceID) == "old-mirror-value")
        #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt == nil)
        #expect(PluginOperationRecovery.resumePending(modelContext: reopened.mainContext).completed == 1)
        PluginSecretCleanupOutbox.resumePending(modelContext: reopened.mainContext, outbox: env.outbox,
            secrets: GenerationSecrets.self)
        #expect(GenerationSecrets.value(in: namespace) == "saved-new-value")
        #expect(GenerationSecrets.value(in: original.secretNamespaceID) == nil)
        #expect(try env.outbox.entries().isEmpty)
    }

    @Test("A failed save and refused orphan cleanup never modify the saved secret")
    func failedSaveKeepsCleanupOwedForOnlyTheNewGeneration() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let original = try env.enable("saved-before-edit")
        #expect(throws: PluginOperations.OperationError.saveFailed) {
            try PluginOperations.setSetting("API_TOKEN", to: "orphaned-edit", of: env.package.skills[0],
                pluginID: env.package.id, in: env.workspace, modelContext: env.context, secrets: RefusingGenerationCleanup.self,
                persist: { _, _ in throw CocoaError(.fileWriteUnknown) })
        }
        let orphan = try #require(GenerationSecrets.namespace(holding: "orphaned-edit"))
        #expect(orphan != original.secretNamespaceID)
        #expect(GenerationSecrets.value(in: original.secretNamespaceID) == "saved-before-edit")
        #expect(try env.outbox.pending().contains(orphan))
        PluginSecretCleanupOutbox.resumePending(modelContext: ModelContext(env.context.container),
            outbox: env.outbox, secrets: GenerationSecrets.self)
        #expect(GenerationSecrets.value(in: orphan) == nil)
        #expect(GenerationSecrets.value(in: original.secretNamespaceID) == "saved-before-edit")
        #expect(try env.outbox.entries().isEmpty)
    }

    @Test("An unwritable cleanup intent prevents every new credential write")
    func journalFailureWritesNothing() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let original = try env.enable("journal-protected")
        let file = env.outbox.fileURL
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try PluginOperations.setSetting("API_TOKEN", to: "must-not-write", of: env.package.skills[0],
                pluginID: env.package.id, in: env.workspace, modelContext: env.context, secrets: GenerationSecrets.self)
        }
        #expect(GenerationSecrets.namespace(holding: "must-not-write") == nil)
        #expect(GenerationSecrets.value(in: original.secretNamespaceID) == "journal-protected")
    }

    @Test("A different context cannot acknowledge a credential edit to models it does not own")
    func mismatchedContextCannotPublish() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        _ = try env.enable("context-owned")
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace))
        let before = PluginActivationRecord(activation)
        let other = ModelContext(env.context.container)
        let receiptCount = try other.fetchCount(FetchDescriptor<PluginOperationReceipt>())
        #expect(throws: (any Error).self) {
            try PluginOperations.setSetting("API_TOKEN", to: "wrong-context-write", of: env.package.skills[0],
                pluginID: env.package.id, in: env.workspace, modelContext: other, secrets: GenerationSecrets.self)
        }
        #expect(PluginActivationRecord(activation) == before)
        #expect(GenerationSecrets.namespace(holding: "wrong-context-write") == nil)
        let saved = try #require(try ModelContext(env.context.container).fetch(FetchDescriptor<PluginActivation>()).first)
        #expect(saved.credentialNamespaceSeed == before.credentialNamespaceSeed)
        #expect(try ModelContext(env.context.container).fetchCount(FetchDescriptor<PluginOperationReceipt>()) == receiptCount)
    }

}

private enum UnreadableGenerationSecret: SkillSecretPersisting {
    static func readSecretValue(key: String, skillID: UUID, store: SecretStore) -> SecretReadOutcome { .unavailable }
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? { nil }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool { false }
    static func deleteSecret(key: String, skillID: UUID) -> Bool { false }
    static func secretExists(key: String, skillID: UUID) -> Bool { true }
    static func deleteAllSecrets(skillID: UUID) {}
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { false }
}

private enum RefusingGenerationCleanup: SkillSecretPersisting {
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? {
        GenerationSecrets.loadSecretValue(key: key, skillID: skillID, store: store)
    }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool {
        GenerationSecrets.saveSecretValue(value, key: key, skillID: skillID, skillName: skillName, allowUserInteraction: allowUserInteraction)
    }
    static func deleteSecret(key: String, skillID: UUID) -> Bool { false }
    static func secretExists(key: String, skillID: UUID) -> Bool { GenerationSecrets.secretExists(key: key, skillID: skillID) }
    static func deleteAllSecrets(skillID: UUID) {}
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { false }
}
