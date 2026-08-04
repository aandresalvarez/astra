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

    @Test("Unverified repository access gates configuration as usable, not as verified")
    func unverifiedTargetIsUsableForConfigurationGating() {
        let cli = CommonCLIPrerequisites.githubCLI
        let repository = CommonCLIPrerequisites.githubAuth
        let prerequisites = [cli, repository]
        let statuses: [String: HealthStatus] = [
            cli.id: .healthy(path: "/opt/homebrew/bin/gh", version: "gh version 2.62.0"),
            repository.id: .unverified(
                path: "/opt/homebrew/bin/gh",
                detail: "Authenticated as octocat; no repository target was resolved from this workspace."
            )
        ]

        // Authenticated `gh` in a folder with no GitHub remote is the normal state during
        // workspace setup: usable for gating, but never presented as proved access.
        #expect(CapabilityPrerequisiteStatusSelection.allUsable(prerequisites, statuses: statuses))
        #expect(!CapabilityPrerequisiteStatusSelection.allVerified(prerequisites, statuses: statuses))
        #expect(CapabilityPrerequisiteStatusSelection.firstBlocking(prerequisites, statuses: statuses) == nil)
    }

    @Test("Unprobed and blocked prerequisites are not usable")
    func blockedPrerequisitesAreNotUsable() {
        let cli = CommonCLIPrerequisites.githubCLI
        let repository = CommonCLIPrerequisites.githubAuth
        let prerequisites = [cli, repository]
        let healthyCLI: HealthStatus = .healthy(path: "/opt/homebrew/bin/gh", version: "gh version 2.62.0")

        #expect(!CapabilityPrerequisiteStatusSelection.allUsable(prerequisites, statuses: [:]))
        #expect(!CapabilityPrerequisiteStatusSelection.allUsable(prerequisites, statuses: [
            cli.id: healthyCLI,
            repository.id: .unauthenticated(detail: "No account is signed in.")
        ]))
        #expect(!CapabilityPrerequisiteStatusSelection.allUsable(prerequisites, statuses: [
            cli.id: healthyCLI,
            repository.id: .authorizationRequired(detail: "SAML SSO required", authorizationURL: nil)
        ]))
        #expect(!CapabilityPrerequisiteStatusSelection.allUsable(prerequisites, statuses: [
            cli.id: .missingBinary,
            repository.id: healthyCLI
        ]))
    }
}
