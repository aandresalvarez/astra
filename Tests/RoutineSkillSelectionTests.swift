import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// What a routine or a template's defaults can pick is what the scheduler
/// resolves when it fires: after the V20 migration deletes an unedited
/// plugin skill's row, the skill lives only in the plugin's projection, and
/// the editors and the slash-command path must still offer it.
@Suite("Routine skill selection")
@MainActor
struct RoutineSkillSelectionTests {
    @Test("A migrated plugin skill with no stored row is offered to routines and resolves when one fires")
    func projectedPluginSkillIsSelectable() throws {
        let fixture = try PluginMigrationFixture()
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let globalSkills = try context.fetch(FetchDescriptor<Skill>()).filter(\.isGlobal)

        // The rows the editors used to list: none is the plugin's skill.
        let storedIDs = Set(a.skills.map(\.id) + globalSkills.map(\.id))
        let offered = WorkspaceCapabilities.routineSkills(in: a, globalSkills: globalSkills)
        let projected = offered.filter { !storedIDs.contains($0.id) }
        #expect(!projected.isEmpty)
        #expect(offered.map(\.id) == WorkspaceCapabilities(workspace: a, globalSkills: globalSkills).activeSkills.map(\.id))

        let schedule = TaskSchedule(name: "Projected", goal: "G", workspace: a)
        schedule.skillIDs = projected.map(\.id.uuidString)
        context.insert(schedule)
        let resolved = TaskScheduler.resolvedSkills(for: schedule, globalSkills: globalSkills)
        #expect(Set(resolved.map(\.id)) == Set(projected.map(\.id)))
    }

    @Test("Editors resolve routine skills against the catalog they loaded, not the library")
    func editorsResolveAgainstTheirLoadedCatalog() throws {
        let fixture = try PluginMigrationFixture()
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let globalSkills = try context.fetch(FetchDescriptor<Skill>()).filter(\.isGlobal)
        let catalog = RoutineSkillCatalog(packages: fixture.packages, approvalRecords: [], packPolicy: .empty)
        let fromCatalog = WorkspaceCapabilities.routineSkills(in: a, globalSkills: globalSkills, catalog: catalog)
        #expect(fromCatalog.map(\.id) == WorkspaceCapabilities(
            workspace: a, globalSkills: globalSkills, packageDefinitions: fixture.packages
        ).activeSkills.map(\.id))

        // A plugin only the loaded catalog has is offered from it.
        let custom = PluginPackage(
            id: "routine-catalog-only", name: "Catalog Only", icon: "doc", description: "Only in the loaded catalog",
            author: "Tests", category: "Tests", tags: [], version: "1.0.0",
            skills: [PluginSkill(
                name: "Catalog Skill", icon: "doc", description: "From the loaded catalog", allowedTools: ["Read"],
                disallowedTools: [], customTools: [], behaviorInstructions: "Catalog rules.",
                environmentKeys: [], environmentValues: []
            )],
            connectors: [], localTools: [], templates: [], governance: .builtInApproved(riskLevel: .low)
        )
        WorkspaceCapabilityActivation.mutate(a) { $0.enableCapability(custom.id) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: custom.id, in: a))
        WorkspaceCapabilityActivation.recordAccepted(
            pluginID: custom.id, version: custom.version, digest: PluginDefinitionDigest.content(of: custom), in: a
        )
        WorkspaceCapabilityActivation.setKnownComponents(PluginRuntimeProjection.componentIDs(of: custom), on: activation)
        let withCustom = RoutineSkillCatalog(packages: fixture.packages + [custom], approvalRecords: [], packPolicy: .empty)
        #expect(WorkspaceCapabilities.routineSkills(in: a, globalSkills: globalSkills, catalog: withCustom)
            .contains { $0.name == "Catalog Skill" })
        #expect(!WorkspaceCapabilities.routineSkills(in: a, globalSkills: globalSkills, catalog: .builtIns)
            .contains { $0.name == "Catalog Skill" })
    }

    @Test("The routine editors' render path resolves against their loaded catalog")
    func editorRenderPathsUseTheLoadedCatalog() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Astra/Views/ScheduleEditorView.swift", "Astra/Views/ConfigureView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            // Every call names the catalog: the library-backed overload scans
            // the plugin library on each `body` pass.
            let calls = source.components(separatedBy: "WorkspaceCapabilities.routineSkills(").dropFirst()
            #expect(!calls.isEmpty, "\(file)")
            #expect(calls.allSatisfy { $0.prefix(while: { $0 != "\n" }).contains("catalog:") }, "\(file)")
            #expect(source.contains("RoutineSkillCatalog.load("), "\(file)")
        }
    }
}
