import Foundation
import Testing
@testable import ASTRA

@Suite("Capability Package Factory")
struct CapabilityPackageFactoryTests {
    @Test("behavior-only capability creates one skill")
    @MainActor
    func behaviorOnlyCapability() {
        let package = CapabilityPackageFactory.makePackage(
            name: "Research Reviewer",
            description: "Review research docs",
            behaviorInstructions: "Stay read-only.",
            allowedTools: ["Read", "Grep"]
        )

        #expect(package.id == "local.research-reviewer")
        #expect(package.skills.count == 1)
        #expect(package.connectors.isEmpty)
        #expect(package.localTools.isEmpty)
        #expect(package.skills.first?.behaviorInstructions == "Stay read-only.")
    }

    @Test("connector-only capability creates standalone connector package")
    @MainActor
    func connectorOnlyCapability() {
        let connector = Connector(name: "REDCap", serviceType: "rest_api", icon: "server.rack", connectorDescription: "REDCap API")
        connector.baseURL = "https://redcap.stanford.edu"
        connector.authMethod = "bearer"
        connector.credentialKeys = ["REDCAP_TOKEN"]
        connector.configKeys = ["REDCAP_PROJECT"]

        let package = CapabilityPackageFactory.makePackage(
            name: "REDCap Connector",
            description: "Connect to REDCap",
            connectors: [connector]
        )

        #expect(package.skills.isEmpty)
        #expect(package.connectors.count == 1)
        #expect(package.connectors.first?.credentialHints.map(\.key) == ["REDCAP_TOKEN"])
        #expect(package.connectors.first?.configHints.map(\.key) == ["REDCAP_PROJECT"])
    }

    @Test("tool-only capability creates standalone tool package")
    @MainActor
    func toolOnlyCapability() {
        let tool = LocalTool(name: "bq", toolDescription: "BigQuery CLI", toolType: "cli", command: "bq", arguments: "--format=json")

        let package = CapabilityPackageFactory.makePackage(
            name: "BigQuery Tool",
            description: "Run bq",
            localTools: [tool]
        )

        #expect(package.skills.isEmpty)
        #expect(package.localTools.count == 1)
        #expect(package.localTools.first?.command == "bq")
        #expect(package.localTools.first?.arguments == "--format=json")
    }

    @Test("full capability includes behavior connectors and tools")
    @MainActor
    func fullCapability() {
        let connector = Connector(name: "Google Cloud", serviceType: "google_cloud")
        let tool = LocalTool(name: "gcloud", toolType: "cli", command: "gcloud")

        let package = CapabilityPackageFactory.makePackage(
            name: "GCP Analyst",
            description: "Analyze GCP projects",
            behaviorInstructions: "Prefer dry runs.",
            connectors: [connector],
            localTools: [tool]
        )

        #expect(package.skills.count == 1)
        #expect(package.connectors.count == 1)
        #expect(package.localTools.count == 1)
        #expect(package.sourceMetadata == .localLibrary())
    }
}
