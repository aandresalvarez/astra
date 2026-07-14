import Testing
import Foundation
@testable import ASTRA
import ASTRACore

@Suite("Runtime Provider List Presentation")
struct RuntimeProviderListPresentationTests {
    @Test("Future providers render as selectable setup rows")
    func futureProvidersRenderAsSetupRows() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))
        let row = RuntimeProviderListPresentation.row(
            runtime: futureRuntime,
            descriptor: descriptor(for: futureRuntime),
            selectedRuntime: .claudeCode,
            status: .missingBinary,
            isProbing: false,
            installingRuntime: nil,
            installCommand: "brew install future-cli"
        )

        #expect(row.id == futureRuntime)
        #expect(row.title == "Future CLI")
        #expect(row.subtitle == "brew install future-cli")
        #expect(row.state == .missing)
        #expect(row.isSelected == false)
        #expect(row.isInstalled == false)
        #expect(row.installCommand == "brew install future-cli")
    }

    @Test("Selected healthy provider reads as selected instead of another installed row")
    func selectedHealthyProviderReadsAsSelected() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))
        let row = RuntimeProviderListPresentation.row(
            runtime: futureRuntime,
            descriptor: descriptor(for: futureRuntime),
            selectedRuntime: futureRuntime,
            status: .healthy(path: "/opt/future/bin/future-cli", version: "Future CLI 2.0"),
            isProbing: false,
            installingRuntime: nil,
            installCommand: nil
        )

        #expect(row.subtitle == "Selected and ready")
        #expect(row.state == .selectedReady)
        #expect(row.isSelected)
        #expect(row.isInstalled)
    }

    @Test("Checking preserves installed state from the last known status")
    func checkingPreservesInstalledStateFromLastKnownStatus() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))
        let row = RuntimeProviderListPresentation.row(
            runtime: futureRuntime,
            descriptor: descriptor(for: futureRuntime),
            selectedRuntime: .claudeCode,
            status: .healthy(path: "/opt/future/bin/future-cli", version: "Future CLI 2.0"),
            isProbing: true,
            installingRuntime: nil,
            installCommand: "brew install future-cli"
        )

        #expect(row.state == .checking)
        #expect(row.subtitle == "Checking...")
        #expect(row.isInstalled)
    }

    @Test("Provider rows preserve registry order as the list grows")
    func providerRowsPreserveOrderAsListGrows() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))
        let runtimes: [AgentRuntimeID] = [.claudeCode, .copilotCLI, futureRuntime]
        let rows = runtimes.map { runtime in
            RuntimeProviderListPresentation.row(
                runtime: runtime,
                descriptor: descriptor(for: runtime),
                selectedRuntime: .copilotCLI,
                status: nil,
                isProbing: false,
                installingRuntime: nil,
                installCommand: nil
            )
        }

        #expect(rows.map(\.id) == runtimes)
        #expect(rows.map(\.title) == ["Claude Code", "GitHub Copilot CLI", "Future CLI"])
        #expect(rows[1].isSelected)
        #expect(rows[2].state == .unknown)
    }

    @Test("Auth probe results override the green installed state")
    func authStateOverridesInstalledGreen() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))
        let signedOut = RuntimeProviderListPresentation.row(
            runtime: futureRuntime,
            descriptor: descriptor(for: futureRuntime),
            selectedRuntime: .claudeCode,
            status: .healthy(path: "/opt/future/bin/future-cli", version: "2.0"),
            isProbing: false,
            installingRuntime: nil,
            installCommand: nil,
            authState: .unauthenticated(detail: "Signed out")
        )
        #expect(signedOut.state == .unauthenticated)
        #expect(signedOut.subtitle == "Signed out")
        #expect(signedOut.primaryAction == .signIn)
        #expect(signedOut.isInstalled)

        let unverified = RuntimeProviderListPresentation.row(
            runtime: futureRuntime,
            descriptor: descriptor(for: futureRuntime),
            selectedRuntime: .claudeCode,
            status: .healthy(path: "/opt/future/bin/future-cli", version: "2.0"),
            isProbing: false,
            installingRuntime: nil,
            installCommand: nil,
            authState: .unverified(note: "Verified on first task")
        )
        #expect(unverified.state == .unverified)
        #expect(unverified.primaryAction == .use)
    }

    @Test("An active sign-in session renders as awaiting with a cancel action")
    func signingInRuntimeAwaits() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))
        let row = RuntimeProviderListPresentation.row(
            runtime: futureRuntime,
            descriptor: descriptor(for: futureRuntime),
            selectedRuntime: futureRuntime,
            status: .healthy(path: "/opt/future/bin/future-cli", version: "2.0"),
            isProbing: false,
            installingRuntime: nil,
            installCommand: nil,
            signingInRuntime: futureRuntime
        )
        #expect(row.state == .awaitingSignIn)
        #expect(row.primaryAction == .cancelSignIn)
    }

    @Test("Missing runtimes only offer Install when a plan exists, else the install page")
    func missingRuntimeActionNeverDeadEnds() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))
        let url = try #require(URL(string: "https://example.com/install"))

        let withPlan = RuntimeProviderListPresentation.row(
            runtime: futureRuntime,
            descriptor: descriptor(for: futureRuntime),
            selectedRuntime: .claudeCode,
            status: .missingBinary,
            isProbing: false,
            installingRuntime: nil,
            installCommand: "brew install future-cli",
            installPageURL: url
        )
        #expect(withPlan.primaryAction == .install(displayCommand: "brew install future-cli"))

        let linkOnly = RuntimeProviderListPresentation.row(
            runtime: futureRuntime,
            descriptor: descriptor(for: futureRuntime),
            selectedRuntime: .claudeCode,
            status: .missingBinary,
            isProbing: false,
            installingRuntime: nil,
            installCommand: nil,
            installPageURL: url
        )
        #expect(linkOnly.primaryAction == .openInstallPage(url))
    }

    @Test("Sections group rows by readiness and collapse the not-installed tail")
    func sectionsGroupRows() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))
        func row(
            _ runtime: AgentRuntimeID,
            status: HealthStatus?,
            authState: RuntimeProviderAuthState = .unknown
        ) -> RuntimeProviderRowPresentation {
            RuntimeProviderListPresentation.row(
                runtime: runtime,
                descriptor: descriptor(for: runtime),
                selectedRuntime: .claudeCode,
                status: status,
                isProbing: false,
                installingRuntime: nil,
                installCommand: nil,
                authState: authState
            )
        }

        let sections = RuntimeProviderListPresentation.sections(rows: [
            row(futureRuntime, status: .healthy(path: "/x", version: "1")),
            row(.copilotCLI, status: .healthy(path: "/x", version: "1"), authState: .unverified(note: "later")),
            row(.codexCLI, status: .healthy(path: "/x", version: "1"), authState: .unauthenticated(detail: "out")),
            row(.cursorCLI, status: .missingBinary),
            row(.claudeCode, status: .missingBinary)
        ])

        #expect(sections.ready.map(\.id) == [.copilotCLI, futureRuntime])
        #expect(sections.needsAttention.map(\.id) == [.codexCLI])
        #expect(sections.notInstalled.map(\.id) == [.claudeCode, .cursorCLI])
    }

    @Test("An installing runtime stays in the always-visible attention section")
    func installingRowIsAlwaysVisible() {
        let installing = RuntimeProviderListPresentation.row(
            runtime: .codexCLI,
            descriptor: descriptor(for: .codexCLI),
            selectedRuntime: .claudeCode,
            status: .missingBinary,
            isProbing: false,
            installingRuntime: .codexCLI,
            installCommand: "npm install -g @openai/codex"
        )
        let sections = RuntimeProviderListPresentation.sections(rows: [installing])

        #expect(sections.needsAttention.map(\.id) == [.codexCLI])
        #expect(sections.notInstalled.isEmpty, "install progress must not hide in the collapsed disclosure")
        #expect(installing.primaryAction == .cancelInstall)
    }

    @Test("Onboarding keeps the selected and recommended runtimes above the disclosure")
    func onboardingKeepsPrimaryRuntimesVisible() {
        let registryOrder: [AgentRuntimeID] = [
            .cursorCLI,
            .openCodeCLI,
            .codexCLI,
            .claudeCode,
            .copilotCLI
        ]
        let rows = registryOrder.map { runtime in
            RuntimeProviderListPresentation.row(
                runtime: runtime,
                descriptor: descriptor(for: runtime),
                selectedRuntime: .cursorCLI,
                status: .healthy(path: "/usr/bin/\(runtime.rawValue)", version: "1"),
                isProbing: false,
                installingRuntime: nil,
                installCommand: nil
            )
        }

        let ordered = OnboardingRuntimeListPresentation.orderedRows(rows, registryOrder: registryOrder)

        #expect(OnboardingRuntimeListPresentation.primaryRows(from: ordered).map(\.id) == [
            .cursorCLI,
            .claudeCode,
            .copilotCLI
        ])
        #expect(OnboardingRuntimeListPresentation.additionalRows(from: ordered).map(\.id) == [
            .openCodeCLI,
            .codexCLI
        ])
    }

    private func descriptor(for runtime: AgentRuntimeID) -> AgentRuntimeDescriptor {
        AgentRuntimeDescriptor(
            id: runtime,
            displayName: runtime.rawValue == "future_cli" ? "Future CLI" : runtime.displayName,
            executableName: runtime.rawValue,
            installHint: "Install \(runtime.displayName)",
            authHint: "Authenticate \(runtime.displayName)",
            defaultModels: ["default"],
            supportsAstraRunProtocol: false
        )
    }
}
