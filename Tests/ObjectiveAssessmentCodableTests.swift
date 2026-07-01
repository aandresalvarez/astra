import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeObjectiveAssessmentContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Objective assessment codable")
@MainActor
struct ObjectiveAssessmentCodableTests {
    @Test("ObjectiveAssessment round-trips through Codable inside TaskContextState")
    func objectiveAssessmentRoundTrips() throws {
        var state = Self.minimalState()
        state.objectiveAssessment = TaskContextState.ObjectiveAssessment(
            verdict: "superseded",
            currentObjective: "Ship the reworked exporter instead",
            assessedAtTurn: 3,
            inputHash: "abc123"
        )

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TaskContextState.self, from: encoded)

        #expect(decoded.objectiveAssessment == state.objectiveAssessment)
        #expect(decoded.objectiveAssessment?.verdict == "superseded")
        #expect(decoded.objectiveAssessment?.currentObjective == "Ship the reworked exporter instead")
        #expect(decoded.objectiveAssessment?.assessedAtTurn == 3)
        #expect(decoded.objectiveAssessment?.inputHash == "abc123")
    }

    @Test("v2 capsule JSON omitting objectiveAssessment decodes with nil (backward compatible)")
    func omittedObjectiveAssessmentDecodesAsNil() throws {
        let legacyJSON = """
        {
          "schemaVersion": 2,
          "mode": "planning",
          "startingRequest": "Make current_state canonical",
          "currentObjective": "Keep old context available",
          "objective": {
            "startingRequest": "Make current_state canonical",
            "currentObjective": "Keep old context available",
            "approvedGoal": null,
            "sourcePointers": []
          },
          "constraints": [],
          "acceptanceCriteria": [],
          "testCommand": null,
          "decisions": [],
          "decisionFacts": [],
          "rejectedOptions": [],
          "openQuestions": [],
          "candidateGoals": [],
          "approvedGoal": null,
          "blockers": [],
          "blockerFacts": [],
          "filesChanged": [],
          "changedFiles": [],
          "artifacts": [],
          "verification": {
            "status": "not_verified",
            "strategy": "manual",
            "command": null,
            "summary": "No validation has run.",
            "evidence": [],
            "updatedAt": null,
            "completionVerified": false,
            "artifactStatus": "unknown",
            "deliverableChecks": []
          },
          "validationContract": null,
          "latestHandoff": null,
          "correctiveWork": null,
          "sourcePointers": [],
          "nextLikelyAction": null,
          "objectiveDivergenceNote": null,
          "standingInstructions": null,
          "turns": [],
          "updatedAt": "2026-05-30T00:00:00.000Z"
        }
        """

        let decoded = try JSONDecoder().decode(TaskContextState.self, from: Data(legacyJSON.utf8))

        #expect(decoded.schemaVersion == 2)
        #expect(decoded.objectiveAssessment == nil)
    }

    @Test("promptContext includes an assessment line only when objectiveAssessment is non-nil")
    func promptContextRendersAssessmentOnlyWhenPresent() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeObjectiveAssessmentContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Assessment", primaryPath: root)
        let task = AgentTask(title: "Assessment", goal: "Track objective assessment rendering", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        TaskContextStateManager.refresh(task: task)

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let withoutAssessment = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(withoutAssessment.objectiveAssessment == nil)

        let promptWithoutAssessment = try #require(TaskContextStateManager.promptContext(for: task))
        #expect(!promptWithoutAssessment.contains("Objective assessment:"))

        var withAssessment = withoutAssessment
        withAssessment.objectiveAssessment = TaskContextState.ObjectiveAssessment(
            verdict: "original_satisfied",
            currentObjective: nil,
            assessedAtTurn: 2,
            inputHash: "deadbeef"
        )
        let jsonPath = (folder as NSString).appendingPathComponent(TaskContextStateManager.jsonFileName)
        try JSONEncoder().encode(withAssessment).write(to: URL(fileURLWithPath: jsonPath))

        let promptWithAssessment = try #require(TaskContextStateManager.promptContext(for: task))
        #expect(promptWithAssessment.contains("Objective assessment: original_satisfied (turn 2)"))
    }

    private static func minimalState(schemaVersion: Int = 2) -> TaskContextState {
        TaskContextState(
            schemaVersion: schemaVersion,
            mode: .exploration,
            startingRequest: "Start",
            currentObjective: "Current",
            objective: TaskContextState.Objective(
                startingRequest: "Start",
                currentObjective: "Current",
                approvedGoal: nil,
                sourcePointers: []
            ),
            constraints: [],
            acceptanceCriteria: [],
            testCommand: nil,
            decisions: [],
            decisionFacts: [],
            rejectedOptions: [],
            openQuestions: [],
            candidateGoals: [],
            approvedGoal: nil,
            blockers: [],
            blockerFacts: [],
            filesChanged: [],
            changedFiles: [],
            artifacts: [],
            verification: TaskContextState.Verification(
                status: "not_verified",
                strategy: "manual",
                command: nil,
                summary: "No validation has run.",
                evidence: [],
                updatedAt: nil
            ),
            validationContract: nil,
            latestHandoff: nil,
            correctiveWork: nil,
            sourcePointers: [],
            nextLikelyAction: nil,
            objectiveDivergenceNote: nil,
            standingInstructions: nil,
            turns: [],
            updatedAt: "2026-06-05T00:00:00Z"
        )
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-objective-assessment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
