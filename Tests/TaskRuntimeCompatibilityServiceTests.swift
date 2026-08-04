import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Task Runtime Compatibility Service")
struct TaskRuntimeCompatibilityServiceTests {
    @Test("host-control task stays on Cursor through the CLI relay")
    func hostControlTaskReroutesFromCursorToCodex() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: ["github"],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        )
        let result = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .cursorCLI,
            defaultRuntime: .cursorCLI,
            requirements: requirements,
            candidateRuntimes: [.cursorCLI, .codexCLI, .claudeCode],
            profile: { runtime in AgentRuntimeCapabilityProfile.defaultProfile(for: runtime) },
            isRuntimeUsable: { $0 == .cursorCLI || $0 == .codexCLI }
        )

        #expect(result.selectedRuntime == .cursorCLI)
        #expect(result.reroutedFrom == nil)
        #expect(result.incompatibilities[.cursorCLI] == [])
    }

    @Test("explicitly-chosen CLI-relay runtime remains selected")
    func explicitlyChosenCLIRelayRuntimeRemainsSelected() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: ["github"],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        )
        let result = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .cursorCLI,
            defaultRuntime: .cursorCLI,
            requirements: requirements,
            candidateRuntimes: [.cursorCLI, .codexCLI, .claudeCode],
            respectExplicitRuntimeChoice: true,
            profile: { runtime in AgentRuntimeCapabilityProfile.defaultProfile(for: runtime) },
            isRuntimeUsable: { $0 == .cursorCLI || $0 == .codexCLI }
        )

        #expect(result.selectedRuntime == .cursorCLI)
        #expect(result.reroutedFrom == nil)
        #expect(result.launchBlock == nil)
    }

    @Test("Cursor and OpenCode both satisfy host control through CLI relays")
    func cliRelayRuntimesSatisfyHostControl() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: ["jira"],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        )
        let result = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .cursorCLI,
            defaultRuntime: .cursorCLI,
            requirements: requirements,
            candidateRuntimes: [.cursorCLI, .openCodeCLI],
            respectExplicitRuntimeChoice: true,
            profile: { .defaultProfile(for: $0) },
            isRuntimeUsable: { $0 == .cursorCLI || $0 == .openCodeCLI }
        )

        #expect(result.selectedRuntime == .cursorCLI)
        #expect(result.incompatibilities[.cursorCLI] == [])
        #expect(result.launchBlock == nil)
    }

    @Test("default requested CLI-relay runtime does not reroute")
    func nonExplicitCLIRelayRuntimeDoesNotReroute() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: ["github"],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        )
        let result = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .cursorCLI,
            defaultRuntime: .cursorCLI,
            requirements: requirements,
            candidateRuntimes: [.cursorCLI, .codexCLI, .claudeCode],
            respectExplicitRuntimeChoice: false,
            profile: { runtime in AgentRuntimeCapabilityProfile.defaultProfile(for: runtime) },
            isRuntimeUsable: { $0 == .cursorCLI || $0 == .codexCLI }
        )

        #expect(result.selectedRuntime == .cursorCLI)
        #expect(result.reroutedFrom == nil)
        #expect(result.launchBlock == nil)
    }

    @Test("old Copilot is skipped for host-control even when executable exists")
    func oldCopilotIsSkippedForHostControl() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: ["github"],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        )
        let result = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .copilotCLI,
            defaultRuntime: .copilotCLI,
            requirements: requirements,
            candidateRuntimes: [.copilotCLI, .codexCLI],
            profile: { runtime in
                runtime == .copilotCLI
                    ? .copilotProfile(supportsAdditionalMCPConfig: false)
                    : .defaultProfile(for: runtime)
            },
            isRuntimeUsable: { _ in true }
        )

        #expect(result.selectedRuntime == .codexCLI)
        #expect(result.incompatibilities[.copilotCLI]?.contains(.missingHostControlPlane(requiredTools: ["github"])) == true)
    }

    @Test("new Copilot satisfies host-control and Docker MCP requirements")
    func newCopilotSatisfiesHostControlAndDockerMCPRequirements() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: ["github"],
            requiresDockerWorkspaceShell: true,
            requiresBrowserControl: false
        )
        let result = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .copilotCLI,
            defaultRuntime: .codexCLI,
            requirements: requirements,
            candidateRuntimes: [.copilotCLI, .codexCLI],
            profile: { runtime in
                runtime == .copilotCLI
                    ? .copilotProfile(supportsAdditionalMCPConfig: true)
                    : .defaultProfile(for: runtime)
            },
            isRuntimeUsable: { _ in true }
        )

        #expect(result.selectedRuntime == .copilotCLI)
        #expect(result.reroutedFrom == nil)
        #expect(result.incompatibilities[.copilotCLI] == [])
        #expect(result.launchBlock == nil)
    }

    @Test("generic task preserves requested runtime")
    func genericTaskPreservesRequestedRuntime() {
        let result = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .cursorCLI,
            defaultRuntime: .codexCLI,
            requirements: TaskRuntimeRequirementSet(
                hostControlTools: [],
                requiresDockerWorkspaceShell: false,
                requiresBrowserControl: false
            ),
            candidateRuntimes: [.cursorCLI, .codexCLI],
            profile: { .defaultProfile(for: $0) },
            isRuntimeUsable: { _ in true }
        )

        #expect(result.selectedRuntime == .cursorCLI)
        #expect(result.reroutedFrom == nil)
        #expect(result.launchBlock == nil)
    }

    @Test("runtime without MCP or CLI relay returns launch block")
    func noCompatibleRuntimeReturnsLaunchBlock() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: ["jira"],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        )
        let result = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .copilotCLI,
            defaultRuntime: .copilotCLI,
            requirements: requirements,
            candidateRuntimes: [.copilotCLI],
            profile: { _ in .copilotProfile(supportsAdditionalMCPConfig: false) },
            isRuntimeUsable: { $0 == .copilotCLI }
        )

        #expect(result.selectedRuntime == .copilotCLI)
        #expect(result.reroutedFrom == nil)
        #expect(result.launchBlock?.message.contains("ASTRA host tools for jira") == true)
        #expect(result.launchBlock?.missingCapabilities == ["ASTRA host tools for jira"])
    }

    @Test("no compatible Docker runtime returns generic launch block")
    func noCompatibleDockerRuntimeReturnsGenericLaunchBlock() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: [],
            requiresDockerWorkspaceShell: true,
            requiresBrowserControl: false
        )
        let result = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .cursorCLI,
            defaultRuntime: .openCodeCLI,
            requirements: requirements,
            candidateRuntimes: [.cursorCLI, .openCodeCLI],
            profile: { .defaultProfile(for: $0) },
            isRuntimeUsable: { $0 == .cursorCLI || $0 == .openCodeCLI || $0 == .copilotCLI }
        )

        #expect(result.selectedRuntime == .cursorCLI)
        #expect(result.reroutedFrom == nil)
        #expect(result.launchBlock?.stopReason == "runtime_capability_incompatible")
        #expect(result.launchBlock?.stopReason != HostControlPlaneRuntimeLaunchGuard.missingHostControlMCPReason)
        #expect(result.launchBlock?.message.contains("Docker workspace shell MCP") == true)
        #expect(result.launchBlock?.missingCapabilities == ["Docker workspace shell MCP"])
    }

    @Test("no compatible browser runtime returns generic launch block")
    func noCompatibleBrowserRuntimeReturnsGenericLaunchBlock() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: [],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: true
        )
        let result = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .copilotCLI,
            defaultRuntime: .copilotCLI,
            requirements: requirements,
            candidateRuntimes: [.copilotCLI],
            profile: { runtime in
                runtime == .copilotCLI
                    ? .copilotProfile(supportsAdditionalMCPConfig: false)
                    : .defaultProfile(for: runtime)
            },
            isRuntimeUsable: { $0 == .copilotCLI }
        )

        #expect(result.selectedRuntime == .copilotCLI)
        #expect(result.reroutedFrom == nil)
        #expect(result.launchBlock?.stopReason == "runtime_capability_incompatible")
        #expect(result.launchBlock?.stopReason != HostControlPlaneRuntimeLaunchGuard.missingHostControlMCPReason)
        #expect(result.launchBlock?.message.contains("browser control transport") == true)
        #expect(result.launchBlock?.missingCapabilities == ["browser control transport"])
    }

    @Test("unavailable requested runtime reports executable instead of compatible capability")
    func unavailableRequestedRuntimeReportsExecutableInsteadOfCompatibleCapability() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: ["github"],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        )
        let result = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .codexCLI,
            defaultRuntime: .codexCLI,
            requirements: requirements,
            candidateRuntimes: [.codexCLI],
            profile: { .defaultProfile(for: $0) },
            isRuntimeUsable: { _ in false }
        )

        #expect(result.selectedRuntime == .codexCLI)
        #expect(result.reroutedFrom == nil)
        #expect(result.incompatibilities[.codexCLI] == [.runtimeUnavailable])
        #expect(result.launchBlock?.stopReason == "missing_codex")
        #expect(result.launchBlock?.message.contains("runtime executable") == true)
        #expect(result.launchBlock?.message.contains("ASTRA host tools for github") == false)
        #expect(result.launchBlock?.missingCapabilities == ["runtime executable"])
    }

    @Test("unavailable CLI-relay runtime reports only its executable")
    func unavailableCLIRelayRuntimeReportsOnlyExecutable() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: ["github"],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        )
        let result = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .cursorCLI,
            defaultRuntime: .cursorCLI,
            requirements: requirements,
            candidateRuntimes: [.cursorCLI],
            profile: { .defaultProfile(for: $0) },
            isRuntimeUsable: { _ in false }
        )

        #expect(result.selectedRuntime == .cursorCLI)
        #expect(result.reroutedFrom == nil)
        #expect(result.incompatibilities[.cursorCLI] == [.runtimeUnavailable])
        #expect(result.launchBlock?.stopReason == "missing_cursor")
        #expect(result.launchBlock?.message.contains("runtime executable") == true)
        #expect(result.launchBlock?.message.contains("ASTRA host tools for github") == false)
        #expect(result.launchBlock?.missingCapabilities == ["runtime executable"])
    }

    @Test("Docker workspace requirement skips old Copilot")
    func dockerWorkspaceRequirementSkipsOldCopilot() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: [],
            requiresDockerWorkspaceShell: true,
            requiresBrowserControl: false
        )
        let result = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .copilotCLI,
            defaultRuntime: .cursorCLI,
            requirements: requirements,
            candidateRuntimes: [.copilotCLI, .codexCLI],
            profile: { runtime in
                runtime == .copilotCLI
                    ? .copilotProfile(supportsAdditionalMCPConfig: false)
                    : .defaultProfile(for: runtime)
            },
            isRuntimeUsable: { _ in true }
        )

        #expect(result.selectedRuntime == .codexCLI)
        #expect(result.reroutedFrom == .copilotCLI)
        #expect(result.incompatibilities[.copilotCLI]?.contains(.missingDockerWorkspaceShell) == true)
    }

    @Test("Browser requirement can use shell-capable Cursor but not old Copilot")
    func browserRequirementCanUseShellCapableCursorButNotOldCopilot() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: [],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: true
        )
        let cursorResult = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .cursorCLI,
            defaultRuntime: .codexCLI,
            requirements: requirements,
            candidateRuntimes: [.cursorCLI, .codexCLI],
            profile: { .defaultProfile(for: $0) },
            isRuntimeUsable: { _ in true }
        )
        let copilotResult = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .copilotCLI,
            defaultRuntime: .cursorCLI,
            requirements: requirements,
            candidateRuntimes: [.copilotCLI, .cursorCLI],
            profile: { runtime in
                runtime == .copilotCLI
                    ? .copilotProfile(supportsAdditionalMCPConfig: false)
                    : .defaultProfile(for: runtime)
            },
            isRuntimeUsable: { _ in true }
        )

        #expect(cursorResult.selectedRuntime == .cursorCLI)
        #expect(cursorResult.reroutedFrom == nil)

        #expect(copilotResult.selectedRuntime == .cursorCLI)
        #expect(copilotResult.reroutedFrom == .copilotCLI)
        #expect(copilotResult.incompatibilities[.copilotCLI]?.contains(.missingBrowserControlTransport) == true)
    }

    @Test("combined requirements choose first runtime satisfying every requirement")
    func combinedRequirementsChooseFirstRuntimeSatisfyingEveryRequirement() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: ["github"],
            requiresDockerWorkspaceShell: true,
            requiresBrowserControl: true
        )
        let result = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .cursorCLI,
            defaultRuntime: .openCodeCLI,
            requirements: requirements,
            candidateRuntimes: [.cursorCLI, .openCodeCLI, .codexCLI, .claudeCode],
            profile: { .defaultProfile(for: $0) },
            isRuntimeUsable: { _ in true }
        )

        #expect(result.selectedRuntime == .codexCLI)
        #expect(result.reroutedFrom == .cursorCLI)
        #expect(result.incompatibilities[.cursorCLI]?.contains(.missingHostControlPlane(requiredTools: ["github"])) == false)
        #expect(result.incompatibilities[.cursorCLI]?.contains(.missingDockerWorkspaceShell) == true)
        #expect(result.incompatibilities[.cursorCLI]?.contains(.missingBrowserControlTransport) == false)
        #expect(result.incompatibilities[.openCodeCLI]?.contains(.missingHostControlPlane(requiredTools: ["github"])) == false)
        #expect(result.incompatibilities[.openCodeCLI]?.contains(.missingDockerWorkspaceShell) == true)
        #expect(result.incompatibilities[.openCodeCLI]?.contains(.missingBrowserControlTransport) == false)
    }
}
