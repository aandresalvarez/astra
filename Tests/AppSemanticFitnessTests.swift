import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("App Semantic Fitness")
struct AppSemanticFitnessTests {
    @Test("Historical SwiftData schemas only reference frozen schema-local model types")
    func historicalSwiftDataSchemasOnlyReferenceFrozenSchemaLocalModelTypes() {
        let historicalSchemas: [(String, [any PersistentModel.Type])] = [
            ("ASTRASchemaV1", ASTRASchemaV1.models),
            ("ASTRASchemaV2", ASTRASchemaV2.models),
            ("ASTRASchemaV3", ASTRASchemaV3.models),
            ("ASTRASchemaV4", ASTRASchemaV4.models),
            ("ASTRASchemaV5", ASTRASchemaV5.models),
            ("ASTRASchemaV6", ASTRASchemaV6.models),
            ("ASTRASchemaV7", ASTRASchemaV7.models),
            ("ASTRASchemaV8", ASTRASchemaV8.models),
            ("ASTRASchemaV9", ASTRASchemaV9.models),
            ("ASTRASchemaV10", ASTRASchemaV10.models),
            ("ASTRASchemaV11", ASTRASchemaV11.models)
        ]

        let liveReferences = historicalSchemas.flatMap { schemaName, models in
            models.compactMap { model -> String? in
                let reflectedName = String(reflecting: model)
                guard reflectedName.contains(".\(schemaName).") else { return "\(schemaName): \(reflectedName)" }
                return nil
            }
        }

        #expect(
            liveReferences.isEmpty,
            "Historical VersionedSchema models must be declared inside their own schema enum: \(liveReferences)"
        )
    }

    @Test("Prompt section provider identifiers are unique and used by known prompt modes")
    @MainActor
    func promptSectionProviderIdentifiersAreUniqueAndUsedByKnownModes() {
        let allIDs = PromptContextSectionProviderID.allCases
        let rawValues = allIDs.map(\.rawValue)

        #expect(Set(allIDs).count == allIDs.count)
        #expect(Set(rawValues).count == rawValues.count)
        #expect(rawValues.allSatisfy { $0.range(of: #"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil })

        for mode in [PromptAssemblyMode.initialRun, .followUp] {
            let providers = AgentPromptBuilder.promptSectionProviderIDs(for: mode)
            #expect(!providers.isEmpty)
            #expect(Set(providers).count == providers.count)
            #expect(providers.allSatisfy { allIDs.contains($0) })
        }
    }

    @Test("Typed task event constants are categorized explicitly")
    func typedTaskEventConstantsAreCategorizedExplicitly() throws {
        let expectedCategories: [String: TaskEventCategory] = [
            "activity.compacted": .lifecycle,
            "astra.artifact_preflight": .system,
            "budget.exceeded": .system,
            "budget.warning": .system,
            "corrective.step.approved": .lifecycle,
            "corrective.step.created": .lifecycle,
            "corrective.step.dismissed": .lifecycle,
            "corrective.task.created": .lifecycle,
            "deliverable.verification.failed": .lifecycle,
            "deliverable.verification.passed": .lifecycle,
            "deliverable.verification.review_needed": .lifecycle,
            "error": .system,
            "handoff.created": .lifecycle,
            "handoff.missing": .lifecycle,
            "handoff.updated": .lifecycle,
            "mission.action.approved": .lifecycle,
            "mission.action.correction_created": .lifecycle,
            "mission.action.dismissed": .lifecycle,
            "mission.action.retry_requested": .lifecycle,
            "mission.audit_bundle.created": .lifecycle,
            "mission.checkpoint.created": .lifecycle,
            "mission.milestone.completed": .lifecycle,
            "mission.milestone.created": .lifecycle,
            "permission.approval.requested": .system,
            "permission.denied": .tool,
            "permission.request.resolved": .system,
            "permission.grant.task": .system,
            "plan.approved": .lifecycle,
            "plan.assistant.message": .conversation,
            "plan.cancelled": .lifecycle,
            "plan.created": .lifecycle,
            "plan.execution.completed": .lifecycle,
            "plan.execution.failed": .lifecycle,
            "plan.execution.started": .lifecycle,
            "plan.step.blocked": .tool,
            "plan.step.completed": .tool,
            "plan.step.skipped": .tool,
            "plan.step.started": .tool,
            "plan.updated": .lifecycle,
            "plan.user.message": .conversation,
            "recap.result": .system,
            "resource.lock.acquired": .lifecycle,
            "resource.lock.released": .lifecycle,
            "resource.lock.requested": .lifecycle,
            "resource.lock.waiting": .lifecycle,
            "role.profile.changed": .lifecycle,
            "role.profile.selected": .lifecycle,
            "runtime.launch_blocked": .system,
            "schedule.result": .system,
            "skill.active": .system,
            "system.info": .system,
            "task.cancelled": .lifecycle,
            "task.chained": .system,
            "task.checkpoint": .lifecycle,
            "task.completed": .lifecycle,
            "task.dismissed": .lifecycle,
            "task.interrupted": .lifecycle,
            "task.resumed": .lifecycle,
            "task.retried": .lifecycle,
            "task.approved": .lifecycle,
            "task.started": .lifecycle,
            "task.stats": .system,
            "team.agent.completed": .team,
            "team.agent.started": .team,
            "team.created": .team,
            "team.deleted": .team,
            "team.message": .team,
            "tool.result": .tool,
            "tool.use": .tool,
            "user.message": .conversation,
            "agent.response": .conversation,
            "agent.thinking": .conversation,
            "validation.assertion.defined": .tool,
            "validation.assertion.failed": .tool,
            "validation.assertion.passed": .tool,
            "validation.assertion.reviewed": .tool,
            "validation.assertion.skipped": .tool,
            "validation.assertion.started": .tool,
            "validation.behavior.evidence.attached": .lifecycle,
            "validation.behavior.failed": .lifecycle,
            "validation.behavior.passed": .lifecycle,
            "validation.behavior.started": .lifecycle,
            "validation.contract.created": .lifecycle,
            "validation.contract.failed": .lifecycle,
            "validation.contract.override": .lifecycle,
            "validation.contract.passed": .lifecycle,
            "validation.contract.updated": .lifecycle,
            "validation.evidence": .system,
            "verifier.completed": .lifecycle,
            "verifier.failed": .lifecycle,
            "verifier.started": .lifecycle
        ]

        let declaredConstants = try declaredTaskEventTypeConstants()
        #expect(declaredConstants == Set(expectedCategories.keys), "Update this fitness test when adding a typed task event.")

        for (rawValue, category) in expectedCategories {
            #expect(TaskEventTypes.category(forRawValue: rawValue) == category)
            #expect(TaskEvent.categoryFor(type: rawValue) == category.rawValue)
        }
    }

    private func declaredTaskEventTypeConstants() throws -> Set<String> {
        let file = try repositoryRoot().appendingPathComponent("Astra/Models/TaskEventTypes.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"static let \w+: TaskEventType = "([^"]+)""#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        return Set(regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[valueRange])
        })
    }

    private func repositoryRoot() throws -> URL {
        try TestRepositoryRoot.resolve()
    }
}
