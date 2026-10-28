import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// A rebuilt ad-hoc ASTRA can't read Keychain items an earlier build wrote,
/// plugin skill secrets included (`.unavailable`). One such value kept
/// `plugin_activations_v21` deferred for every workspace; now only its skill
/// waits, as it is, until the person re-enters the value.
@MainActor
@Suite("Plugin migration with unreadable skill secrets", .serialized)
struct PluginMigrationUnreadableSkillSecretTests {
    private typealias RefusingVault = PluginMigrationUnreadableCredentialTests.RefusingVault

    @Test("An unreadable plugin skill is left as it is while the rest migrates, and re-entering its value finishes it")
    func unreadableSkillDefersAlone() throws {
        try withLegacySkills { legacy in
            let env = legacy.env
            let report = try PluginActivationMigration.migrate(modelContext: env.context, packages: [legacy.package],
                vault: legacy.vault)
            #expect(report.skillsProjected == 1)
            #expect(report.skillsAwaitingReentry == [legacy.unreadable.id: .init(keys: ["API_TOKEN"], activationID: nil)])
            #expect(env.workspace.legacyInstalledPluginIDs.isEmpty && env.workspace.legacyEnabledCapabilityIDs.isEmpty)
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: legacy.package.id, in: env.workspace))
            let readableCopyID = PluginRuntimeProjection.derivedID(of: activation, componentID: legacy.readableComponent)
            let unreadableCopyID = PluginRuntimeProjection.derivedID(of: activation, componentID: legacy.unreadableComponent)

            // The readable skill moved onto the activation, its value with it.
            #expect(try env.context.fetch(FetchDescriptor<Skill>()).map(\.id) == [legacy.unreadable.id])
            let projected = PluginRuntimeProjection.project(workspace: env.workspace, packages: [legacy.package])
            let readableCopy = try #require(projected.skills.first { $0.id == readableCopyID })
            #expect(readableCopy.environmentVariables["API_TOKEN"] == "one-API_TOKEN")

            // The other row is exactly as it was: provenance, namespace,
            // fields and saved value, and nothing owes its namespace a cleanup.
            #expect(legacy.unreadable.originPackageID == legacy.package.id)
            #expect(legacy.unreadable.originComponentID == legacy.unreadableComponent)
            #expect(legacy.unreadable.credentialNamespaceID == nil)
            #expect(legacy.unreadable.environmentKeys == ["PROJECT", "API_TOKEN"])
            legacy.expectLegacyValueIntact()
            #expect(try PluginSecretCleanupOutbox(for: env.context)?.pending().contains(legacy.unreadable.id) != true)
            // What named it still does; only the moved skill was retargeted.
            #expect(legacy.template.defaultSkillIDs == [readableCopyID.uuidString, legacy.unreadable.id.uuidString])
            #expect(legacy.schedule.skillIDs == [legacy.unreadable.id.uuidString])

            // It is its component's override, the one copy in scope: the
            // plugin's own isn't projected beside it, and the shared list no
            // longer turns it on by itself.
            #expect(activation.overridingRowID(forComponent: legacy.unreadableComponent) == legacy.unreadable.id)
            #expect(Set(projected.skills.map(\.id)) == [readableCopyID, legacy.unreadable.id])
            #expect(!WorkspaceCapabilityActivation.state(of: env.workspace).globalSkillIDs.contains(legacy.unreadable.id.uuidString))
            let active = WorkspaceCapabilities(workspace: env.workspace, globalSkills: [legacy.unreadable],
                packageDefinitions: [legacy.package]).activeSkills
            let activeIDs: [UUID] = active.map(\.id)
            #expect(activeIDs.count == 2)
            #expect(Set(activeIDs) == [readableCopyID, legacy.unreadable.id])

            // Later launches retry it; nothing changes until it is re-entered.
            #expect(PluginActivationMigration.needsMigration(modelContext: env.context, packages: [legacy.package]))
            let again = try PluginActivationMigration.migrate(modelContext: env.context, packages: [legacy.package],
                vault: legacy.vault)
            #expect(again == PluginActivationMigration.Report(skillsAwaitingReentry: report.skillsAwaitingReentry))
            #expect(legacy.unreadable.credentialNamespaceID == nil)
            legacy.expectLegacyValueIntact()

            // The editor names what to re-enter. A plugin row takes no other
            // credential edit: it would stop matching its definition.
            #expect(SkillCredentialEditor.unreadableKeys(of: legacy.unreadable, vault: legacy.vault) == ["API_TOKEN"])
            #expect(throws: SkillCredentialEditor.Failure.changedSkill) {
                try SkillCredentialEditor.save("other-token", forKey: "API_TOKEN", on: legacy.unreadable, modelContext: env.context)
            }
            #expect(throws: SkillCredentialEditor.Failure.changedSkill) {
                try SkillCredentialEditor.save(["OTHER_TOKEN": "other-token"], on: legacy.unreadable,
                    modelContext: env.context, vault: legacy.vault)
            }
            legacy.expectLegacyValueIntact()
            try SkillCredentialEditor.save(["API_TOKEN": "reentered-token"], on: legacy.unreadable,
                modelContext: env.context, vault: legacy.vault)
            #expect(legacy.unreadable.credentialNamespaceID != nil)
            #expect(legacy.unreadable.originPackageID == legacy.package.id)
            #expect(SkillCredentialEditor.unreadableKeys(of: legacy.unreadable, vault: legacy.vault).isEmpty)
            #expect(legacy.unreadable.environmentVariables["API_TOKEN"] == "reentered-token")

            // The next launch moves it like any other.
            let finished = try PluginActivationMigration.migrate(modelContext: env.context, packages: [legacy.package],
                vault: legacy.vault)
            #expect(finished.skillsProjected == 1 && finished.skillsAwaitingReentry.isEmpty)
            #expect(try env.context.fetch(FetchDescriptor<Skill>()).isEmpty)
            #expect(activation.overridingRowID(forComponent: legacy.unreadableComponent) == nil)
            #expect(legacy.template.defaultSkillIDs == [readableCopyID.uuidString, unreadableCopyID.uuidString])
            #expect(legacy.schedule.skillIDs == [unreadableCopyID.uuidString])
            let copies = PluginRuntimeProjection.project(workspace: env.workspace, packages: [legacy.package]).skills
            #expect(Set(copies.map(\.id)) == [readableCopyID, unreadableCopyID])
            #expect(copies.first { $0.id == unreadableCopyID }?.environmentVariables["API_TOKEN"] == "reentered-token")
            #expect(copies.first { $0.id == readableCopyID }?.environmentVariables["API_TOKEN"] == "one-API_TOKEN")
            #expect(!PluginActivationMigration.needsMigration(modelContext: env.context, packages: [legacy.package]))

            let reopened = try env.disk.reopen()
            #expect(try reopened.mainContext.fetch(FetchDescriptor<Skill>()).isEmpty)
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).first)
            #expect(saved.overriddenComponentIDs.isEmpty)
        }
    }

    @Test("A skill whose plugin holds saved settings this build can't read waits, as it is, for those")
    func unreadableActivationSettingDefersTheSkill() throws {
        try withLegacySkills { legacy in
            let env = legacy.env
            _ = try PluginActivationMigration.migrate(modelContext: env.context, packages: [legacy.package], vault: legacy.vault)
            try SkillCredentialEditor.save(["API_TOKEN": "reentered-token"], on: legacy.unreadable,
                modelContext: env.context, vault: legacy.vault)
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: legacy.package.id, in: env.workspace))

            // Rebuilt again before the next launch: the generation the last
            // build gave the activation now refuses this one too. Moving the
            // skill in would mean a generation without that value.
            let generation = PluginRuntimeProjection.credentialID(of: activation, componentID: legacy.readableComponent)
            let rebuilt = RefusingVault(refused: [KeychainSecretStore.skillEntityID(for: generation)])
            let report = try PluginActivationMigration.migrate(modelContext: env.context, packages: [legacy.package],
                vault: rebuilt)
            #expect(report == PluginActivationMigration.Report(
                skillsAwaitingReentry: [legacy.unreadable.id: .init(keys: ["API_TOKEN"], activationID: activation.id)]))
            #expect(PluginRuntimeProjection.credentialID(of: activation, componentID: legacy.readableComponent) == generation)
            #expect(legacy.unreadable.originPackageID == legacy.package.id)
            #expect(legacy.unreadable.environmentVariables["API_TOKEN"] == "reentered-token")
            #expect(activation.overridingRowID(forComponent: legacy.unreadableComponent) == legacy.unreadable.id)

            // Re-entered in the plugin's settings, the activation's values are
            // this build's, and the skill moves on the next launch.
            try PluginOperations.setSetting("API_TOKEN", to: "reentered-readable", of: legacy.package.skills[0],
                package: legacy.package, in: env.workspace, modelContext: env.context)
            let finished = try PluginActivationMigration.migrate(modelContext: env.context, packages: [legacy.package],
                vault: rebuilt)
            #expect(finished.skillsProjected == 1 && finished.skillsAwaitingReentry.isEmpty)
            #expect(try env.context.fetch(FetchDescriptor<Skill>()).isEmpty)
            let copies = PluginRuntimeProjection.project(workspace: env.workspace, packages: [legacy.package]).skills
            let unreadableCopyID = PluginRuntimeProjection.derivedID(of: activation, componentID: legacy.unreadableComponent)
            let readableCopyID = PluginRuntimeProjection.derivedID(of: activation, componentID: legacy.readableComponent)
            #expect(copies.first { $0.id == unreadableCopyID }?.environmentVariables["API_TOKEN"] == "reentered-token")
            #expect(copies.first { $0.id == readableCopyID }?.environmentVariables["API_TOKEN"] == "reentered-readable")
        }
    }

    private struct Legacy {
        let env: PluginAddCommitTests.Fixture
        let package: PluginPackage
        let readableComponent: String
        let unreadableComponent: String
        let readable: Skill
        let unreadable: Skill
        let template: TaskTemplate
        let schedule: TaskSchedule
        let vault: RefusingVault

        /// Read past the refusal: nothing was moved, overwritten or deleted.
        func expectLegacyValueIntact() {
            #expect(AstraSecureKeychainStore.read(service: KeychainSecretStore.skillEntityID(for: unreadable.id),
                account: "API_TOKEN") == .value("two-API_TOKEN"))
        }
    }

    /// A V20-era store: the plugin still enabled through the legacy lists,
    /// two of its unedited skill rows, each with a value saved under the
    /// row's own namespace, and one of them refusing this build.
    private func withLegacySkills(_ body: (Legacy) throws -> Void) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            var package = PluginOperationsTests.package(version: "1.0.0")
            package.id = env.package.id
            package.connectors = []; package.localTools = []
            let template = package.skills[0]
            package.skills = ["Readable Agent", "Unreadable Agent"].map { name in
                var skill = template
                skill.name = name
                skill.environmentKeys = ["PROJECT", "API_TOKEN"]
                skill.environmentValues = ["default-project", ""]
                return skill
            }
            @MainActor func row(_ spec: PluginSkill, host: String, shared: Bool) throws -> (Skill, String) {
                // Environment is assigned after init, which would move a
                // secret-looking value into the Keychain itself.
                let skill = Skill(name: spec.name, icon: spec.icon, skillDescription: spec.description,
                    allowedTools: spec.allowedTools, disallowedTools: spec.disallowedTools,
                    customTools: spec.customTools, behaviorInstructions: spec.behaviorInstructions)
                skill.environmentKeys = spec.environmentKeys
                skill.environmentValues = spec.environmentValues
                skill.isGlobal = shared
                if !shared { skill.workspace = env.workspace }
                let component = CapabilityResourceOrigin.componentID(for: spec)
                CapabilityResourceOrigin.stamp(skill, package: package, componentID: component)
                env.context.insert(skill)
                try #require(AstraSecureKeychainStore.save(service: KeychainSecretStore.skillEntityID(for: skill.id),
                    account: "API_TOKEN", value: "\(host)-API_TOKEN", label: nil))
                return (skill, component)
            }
            let (readable, readableComponent) = try row(package.skills[0], host: "one", shared: false)
            let (unreadable, unreadableComponent) = try row(package.skills[1], host: "two", shared: true)
            let taskTemplate = TaskTemplate(name: "Weekly report", mainGoal: "Write it", workspace: env.workspace)
            taskTemplate.defaultSkillIDs = [readable.id.uuidString, unreadable.id.uuidString]
            env.context.insert(taskTemplate)
            let schedule = TaskSchedule(name: "Weekly", goal: "Write it", workspace: env.workspace)
            schedule.skillIDs = [unreadable.id.uuidString]
            env.context.insert(schedule)
            WorkspaceCapabilityActivation.mutate(env.workspace) { $0.globalSkillIDs.append(unreadable.id.uuidString) }
            env.workspace.legacyEnabledCapabilityIDs = [package.id]
            env.workspace.legacyInstalledPluginIDs = [package.id]
            env.workspace.legacyInstalledPluginVersions = [package.version]
            try env.context.save()
            let vault = RefusingVault(refused: [KeychainSecretStore.skillEntityID(for: unreadable.id)])
            try body(Legacy(env: env, package: package, readableComponent: readableComponent,
                unreadableComponent: unreadableComponent, readable: readable, unreadable: unreadable,
                template: taskTemplate, schedule: schedule, vault: vault))
        }
    }
}
