import Foundation
import ASTRACore
import ASTRAModels

/// The credentials a run must not carry.
///
/// A brokered connector's secrets stay in the host-control broker, which makes
/// the request on the agent's behalf; the agent gets a socket path. This type
/// is the single derivation of "which environment keys does that cover", used
/// both to strip the launch environment and to report it. Two derivations would
/// drift, and the drift is what produced a permission manifest that listed a
/// Jira token the run had already had stripped.
@MainActor
enum BrokeredConnectorEnvironment {
    /// In-scope connectors whose service type a broker speaks for.
    ///
    /// Deliberately not conditioned on whether the broker actually launched. A
    /// credential the broker owns does not become the agent's to hold because
    /// the runtime could not deliver the tool — the run fails closed and says
    /// so, which is recoverable. Handing the raw token over instead is not.
    /// Reads the reachable set, matching `CapabilitySnapshot`: a connector the
    /// broker will serve this run is exactly one whose route that snapshot
    /// projects. Reading the narrated subset here would strip a smaller set than
    /// the broker owns and leak the difference into the agent's environment.
    static func brokeredConnectors(in capabilityScope: TaskCapabilityPromptScope) -> [Connector] {
        capabilityScope.reachableConnectors.filter {
            HostControlPlaneMCPProjection.brokerOwnsConnectorConfiguration($0.serviceType)
        }
    }

    /// Config keys carried by skill snapshots for brokered services. A detached
    /// snapshot outlives the connector row it came from, so its keys have to be
    /// stripped by name rather than through the connector.
    static func brokeredSnapshotConfigKeys(in capabilityScope: TaskCapabilityPromptScope) -> Set<String> {
        Set(
            capabilityScope.resolver.detachedSnapshots
                .flatMap { $0.connectorSnapshots ?? [] }
                .filter { HostControlPlaneMCPProjection.brokerOwnsConnectorConfiguration($0.serviceType) }
                .flatMap(\.configKeys)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    /// Every environment key the broker owns for this run.
    static func strippedKeys(in capabilityScope: TaskCapabilityPromptScope) -> Set<String> {
        let connectors = brokeredConnectors(in: capabilityScope)
        let snapshotKeys = brokeredSnapshotConfigKeys(in: capabilityScope)
        guard !connectors.isEmpty || !snapshotKeys.isEmpty else { return [] }
        return ConnectorRuntimeProjection(connectors: connectors)
            .declaredEnvironmentBindingKeys()
            .union(snapshotKeys)
    }

    /// Credential labels the broker holds for this run. Reported separately
    /// from `credentialLabels` so a reader can tell "the run can use this" from
    /// "the agent process was handed this".
    ///
    /// Declared rather than loaded, matching `strippedKeys(in:)`: the agent does
    /// not get these keys whether or not the value is currently readable, and a
    /// report that quietly drops an unset credential would say the run holds
    /// less than it withholds.
    ///
    /// Filtered by approval, though, because that is a different question from
    /// readability. `brokeredConnectors(in:)` is deliberately reachability-wide
    /// — the strip must cover every credential the broker owns — but the broker
    /// only unseals a reachable-but-unnarrated connector's secret when a durable
    /// grant already covers it (see
    /// `HostControlBrokerSessionRegistry.brokeredConnectorEnvironment`). Listing
    /// the rest here tells the user a route is usable on a run where the broker
    /// will refuse it. Passing no task means no grants are known, which reports
    /// the narrated connectors only: understating beats overstating.
    static func credentialLabels(
        in capabilityScope: TaskCapabilityPromptScope,
        task: AgentTask? = nil,
        runtime: AgentRuntimeID? = nil
    ) -> [String] {
        let connectors = brokeredConnectors(in: capabilityScope)
        guard !connectors.isEmpty else { return [] }
        let narratedConnectorIDs = Set(capabilityScope.connectors.map(\.id))
        let approvedLabels = Set(task.map {
            TaskRuntimePermissionGrants.approvedCredentialLabels(for: $0, runtime: runtime)
        } ?? [])
        return connectors.flatMap { connector -> [String] in
            let labels = ConnectorRuntimeProjection(connectors: [connector]).declaredCredentialLabels()
            guard !narratedConnectorIDs.contains(connector.id) else { return labels }
            return labels.filter(approvedLabels.contains)
        }
        .sorted()
    }

    /// Removes the brokered keys from `environment` and prunes the brokered
    /// connectors out of `ASTRA_CONNECTORS`, so nothing downstream can rebuild
    /// a request from the manifest either.
    static func strip(from environment: inout [String: String], capabilityScope: TaskCapabilityPromptScope) {
        let brokeredConnectors = brokeredConnectors(in: capabilityScope)
        let strippedKeys = strippedKeys(in: capabilityScope)
        guard !strippedKeys.isEmpty || !brokeredConnectors.isEmpty else { return }

        for key in strippedKeys {
            environment.removeValue(forKey: key)
        }

        guard let manifestJSON = environment["ASTRA_CONNECTORS"],
              let manifestData = manifestJSON.data(using: .utf8),
              var manifest = try? JSONDecoder().decode(
                  ConnectorRuntimeProjection.Manifest.self,
                  from: manifestData
              ) else {
            environment.removeValue(forKey: "ASTRA_CONNECTORS")
            return
        }
        let brokeredConnectorIDs = Set(brokeredConnectors.map { $0.id.uuidString.lowercased() })
        manifest.connectors.removeAll {
            brokeredConnectorIDs.contains($0.id.lowercased())
        }
        guard !manifest.connectors.isEmpty else {
            environment.removeValue(forKey: "ASTRA_CONNECTORS")
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let filteredData = try? encoder.encode(manifest),
           let filteredJSON = String(data: filteredData, encoding: .utf8) {
            environment["ASTRA_CONNECTORS"] = filteredJSON
        } else {
            environment.removeValue(forKey: "ASTRA_CONNECTORS")
        }
    }
}
