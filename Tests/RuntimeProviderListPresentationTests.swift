import Testing
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
