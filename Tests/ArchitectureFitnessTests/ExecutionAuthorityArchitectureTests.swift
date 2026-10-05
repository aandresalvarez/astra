import Foundation
import Testing

@Suite("Execution authority architecture")
struct ExecutionAuthorityArchitectureTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("Run-bound validation has required authority and no live fallback")
    func validationRequiresAuthority() throws {
        for file in [
            "Services/Runtime/AgentRuntimeCompletionValidation.swift",
            "Services/Runtime/ApprovedPlanRuntimeSettlement.swift",
            "Services/Validation/TaskInferredValidationService.swift",
            "Services/Validation/TaskDeliverableVerificationService.swift"
        ] {
            let source = try String(contentsOf: root.appendingPathComponent("Astra/" + file), encoding: .utf8)
            #expect(source.contains("executionContext: TaskExecutionContext"))
            #expect(!source.contains(".legacy("))
            #expect(!source.contains("resourceScope: TaskExecutionResourceScope? = nil"))
        }
        let validation = try String(contentsOf: root.appendingPathComponent("Astra/Services/Validation/ValidationService.swift"), encoding: .utf8)
        #expect(!validation.contains("AgentUtilityRuntimeRunner.runPrompt("))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Astra/Services/Validation/LegacyValidationEntryPoints.swift").path))
    }

    @Test("Git authority does not depend on prose parsing")
    func gitRequirementsAreTyped() throws {
        let resolver = try String(contentsOf: root.appendingPathComponent("Astra/Services/Git/TaskExecutionGitRequirementResolver.swift"), encoding: .utf8)
        #expect(resolver.contains("gitAccessRequirement"))
        #expect(!resolver.contains("regularExpression"))
        #expect(!resolver.contains("acceptedTurn"))
        #expect(!resolver.contains("mutationHint"))
    }
}
