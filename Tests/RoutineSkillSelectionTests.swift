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
}
