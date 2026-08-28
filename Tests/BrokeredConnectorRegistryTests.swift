import Foundation
import Testing
import HostControlToolSupport
@testable import ASTRA

/// Runtime half of the brokered-connector invariant. The source-scanning half
/// is `Tests/ArchitectureFitnessTests/BrokeredConnectorFitnessTests.swift`;
/// this side checks that the declarations actually line up with the tool
/// surface at runtime, which a grep cannot see.
@Suite("Brokered connector registry")
struct BrokeredConnectorRegistryTests {
    @Test("Every brokered service resolves to a real broker tool")
    func everyBrokeredServiceResolvesToARealBrokerTool() {
        for (serviceType, toolName) in HostControlBrokeredServices.toolNamesByServiceType {
            #expect(
                HostControlToolConfiguration.knownToolNames.contains(toolName),
                "\(serviceType) claims broker tool '\(toolName)', which the broker does not implement."
            )
            #expect(
                HostControlPlaneMCPProjection.toolNames.contains(toolName),
                "\(serviceType) claims broker tool '\(toolName)', which the app never projects."
            )
        }
    }

    @Test("A brokered service is stripped from the agent environment")
    func brokeredServiceIsStrippedFromTheAgentEnvironment() {
        for serviceType in HostControlBrokeredServices.toolNamesByServiceType.keys {
            #expect(
                HostControlPlaneMCPProjection.brokerOwnsConnectorConfiguration(serviceType),
                "\(serviceType) has a typed broker handler but its credentials still reach the agent."
            )
            #expect(
                HostControlPlaneMCPProjection.connectorToolName(serviceType) != nil,
                "\(serviceType) is brokered but resolves to no tool, so the tool is never required."
            )
        }
    }

    /// The regression that started this: a REDCap connector in scope used to be
    /// projected as plain environment variables because only Jira was brokered.
    @Test("A REDCap connector requires the REDCap broker tool")
    func redcapConnectorRequiresTheREDCapBrokerTool() {
        let snapshot = HostControlPlaneMCPProjection.CapabilitySnapshot(
            enabledPackageIDs: [],
            behaviorSkillOriginPackageIDs: [],
            effectiveBehaviorInstructions: [],
            connectorServiceTypes: ["REDCap"]
        )

        #expect(HostControlPlaneMCPProjection.requiredToolNames(capabilitySnapshot: snapshot) == ["redcap"])
    }

    /// A CLI passthrough is not a broker: `gh` authenticates from its own
    /// on-disk state, so stripping the connector's environment would break it.
    @Test("CLI passthrough tools are not treated as credential brokers")
    func cliPassthroughToolsAreNotCredentialBrokers() {
        for serviceType in ["github", "gh", "gcloud", "gcp", "ssh", "bq"] {
            #expect(
                !HostControlBrokeredServices.ownsConfiguration(ofServiceType: serviceType),
                "\(serviceType) is a CLI passthrough; stripping its environment would break it."
            )
        }
    }

    /// The runtime consequence of not being registered: a handler written for
    /// an unregistered service reads no connector at all, rather than quietly
    /// reading a credential the agent also holds.
    @Test("An unregistered service type resolves to no connector")
    func unregisteredServiceTypeResolvesToNoConnector() {
        let configuration = Self.configuration(serviceType: "unregistered-service")

        #expect(
            HostControlBrokeredServices.resolveConnector(
                forServiceType: "unregistered-service",
                alias: nil,
                in: configuration
            ) == .notProjected
        )
    }

    @Test("A registered service type resolves case- and whitespace-insensitively")
    func registeredServiceTypeResolvesLoosely() {
        let configuration = Self.configuration(serviceType: "  REDCap ")
        let connector = HostControlBrokeredServices.resolveConnector(
            forServiceType: "redcap",
            alias: nil,
            in: configuration
        ).connector

        #expect(connector?.alias == "primary")
    }

    @Test("An alias selects among connectors of the same service")
    func aliasSelectsAmongConnectorsOfTheSameService() {
        let configuration = Self.twoREDCapConnectors()

        #expect(
            HostControlBrokeredServices.resolveConnector(
                forServiceType: "redcap",
                alias: "secondary",
                in: configuration
            ).connector?.id == "c2"
        )
        #expect(
            HostControlBrokeredServices.resolveConnector(
                forServiceType: "redcap",
                alias: "missing",
                in: configuration
            ) == .unknownAlias("missing", candidates: ["primary", "secondary"])
        )
    }

    /// The reason this returns a resolution rather than an optional. Picking the
    /// first match sends the query to whichever study sorts first in the
    /// manifest — for `redcap` that is one study's subject data exported because
    /// the call was under-specified.
    @Test("An omitted alias with two connectors in scope is refused, not guessed")
    func omittedAliasWithTwoConnectorsIsRefused() {
        let resolution = HostControlBrokeredServices.resolveConnector(
            forServiceType: "redcap",
            alias: nil,
            in: Self.twoREDCapConnectors()
        )

        #expect(resolution.connector == nil)
        #expect(resolution == .ambiguous(alias: nil, candidates: ["primary", "secondary"]))
        let message = resolution.failureMessage(serviceLabel: "REDCap") ?? ""
        #expect(message.contains("will not"))
        #expect(message.contains("primary"))
        #expect(message.contains("secondary"))
    }

    /// Aliases and display names are user-entered and can collide; IDs cannot.
    /// So a name that is ambiguous still resolves when the caller passes the one
    /// string that is unique by construction, and the refusal says so.
    @Test("A duplicated alias is refused by name and resolved by id")
    func duplicatedAliasIsRefusedByNameAndResolvedByID() {
        let configuration = HostControlToolConfiguration(
            connectorsJSON: """
            {"connectors":[\
            \(Self.connectorJSON(id: "c1", alias: "study", serviceType: "redcap")),\
            \(Self.connectorJSON(id: "c2", alias: "study", serviceType: "redcap"))\
            ]}
            """
        )

        let byAlias = HostControlBrokeredServices.resolveConnector(
            forServiceType: "redcap",
            alias: "study",
            in: configuration
        )
        #expect(byAlias.connector == nil)
        #expect(byAlias == .ambiguous(alias: "study", candidates: ["study (id c1)", "study (id c2)"]))
        #expect(byAlias.failureMessage(serviceLabel: "REDCap")?.contains("id c2") == true)

        #expect(
            HostControlBrokeredServices.resolveConnector(
                forServiceType: "redcap",
                alias: "c2",
                in: configuration
            ).connector?.id == "c2"
        )
    }

    // MARK: - Helpers

    private static func twoREDCapConnectors() -> HostControlToolConfiguration {
        HostControlToolConfiguration(
            connectorsJSON: """
            {"connectors":[\
            \(connectorJSON(id: "c1", alias: "primary", serviceType: "redcap")),\
            \(connectorJSON(id: "c2", alias: "secondary", serviceType: "redcap"))\
            ]}
            """
        )
    }

    private static func configuration(serviceType: String) -> HostControlToolConfiguration {
        HostControlToolConfiguration(
            connectorsJSON: """
            {"connectors":[\(connectorJSON(id: "c1", alias: "primary", serviceType: serviceType))]}
            """
        )
    }

    private static func connectorJSON(id: String, alias: String, serviceType: String) -> String {
        """
        {"id":"\(id)","alias":"\(alias)","envPrefix":"REDCAP","name":"REDCap",\
        "serviceType":"\(serviceType)","baseURL":"https://redcap.example.edu/api/",\
        "authMethod":"token","env":{},"credentials":{},"config":{}}
        """
    }
}
