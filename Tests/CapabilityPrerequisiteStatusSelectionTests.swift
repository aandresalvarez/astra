import Testing
import ASTRACore
@testable import ASTRA

@Suite("Capability prerequisite status selection")
struct CapabilityPrerequisiteStatusSelectionTests {
    @Test("Unverified target is visible but does not mask a later blocker")
    func unverifiedTargetDoesNotMaskBlocker() throws {
        let repository = CommonCLIPrerequisites.githubAuth
        let requiredTool = CLIPrerequisite(
            binary: "required-tool",
            displayName: "Required tool",
            purpose: "Required by the test."
        )
        let prerequisites = [repository, requiredTool]
        let statuses: [String: HealthStatus] = [
            repository.id: .unverified(
                path: "/opt/homebrew/bin/gh",
                detail: "No repository target was resolved."
            ),
            requiredTool.id: .missingBinary
        ]

        let firstUnready = try #require(
            CapabilityPrerequisiteStatusSelection.firstUnready(
                prerequisites,
                statuses: statuses
            )
        )
        let firstBlocking = try #require(
            CapabilityPrerequisiteStatusSelection.firstBlocking(
                prerequisites,
                statuses: statuses
            )
        )

        #expect(firstUnready.0.id == repository.id)
        #expect(firstBlocking.0.id == requiredTool.id)
        #expect(!CapabilityPrerequisiteStatusSelection.allVerified(
            prerequisites,
            statuses: statuses
        ))
    }
}
