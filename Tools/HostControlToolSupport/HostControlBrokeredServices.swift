import Foundation

/// The services whose credentials this broker owns.
///
/// The distinction that matters is not "is there a host-control tool for this"
/// but "does a tool in this process read this connector's credentials itself".
/// `github`, `gcloud`, `bq` and `ssh` are CLI passthroughs: they forward
/// arguments to a binary that authenticates from its own on-disk state, so the
/// connector's environment still has to reach the agent. `jira` and `redcap`
/// are typed brokers: they read the credential out of *this* process's
/// environment and never hand it back, which is what makes it safe — and
/// necessary — to strip those variables from the agent's environment entirely.
///
/// That inversion is the point. Before this existed, the strip list was a
/// hard-coded `== "jira"` in the app, so adding a broker here left the
/// credential projected into the agent anyway and nothing failed. Now the
/// broker declares what it owns and the app reads the declaration, with
/// `Tests/ArchitectureFitnessTests` failing the build if a typed handler
/// appears without a matching entry.
public enum HostControlBrokeredServices {
    /// Connector service type (lowercased) → the host-control tool that owns it.
    ///
    /// Keys are connector `serviceType` values as they arrive in
    /// `ASTRA_CONNECTORS`; values are names in
    /// `HostControlToolServer.knownToolNames`.
    public static let toolNamesByServiceType: [String: String] = [
        "jira": "jira",
        "redcap": "redcap"
    ]

    /// Every tool name that reads connector credentials in this process.
    public static var brokeredToolNames: Set<String> {
        Set(toolNamesByServiceType.values)
    }

    public static func toolName(forServiceType serviceType: String) -> String? {
        toolNamesByServiceType[normalized(serviceType)]
    }

    /// True when the credentials for `serviceType` are resolved inside the
    /// broker, and therefore must not be projected into the agent process.
    public static func ownsConfiguration(ofServiceType serviceType: String) -> Bool {
        toolName(forServiceType: serviceType) != nil
    }

    /// The only sanctioned way for a tool handler to reach a connector.
    ///
    /// Going through here is enforced by
    /// `Tests/ArchitectureFitnessTests`, which fails if any other file in this
    /// module filters `connectorManifest.connectors` itself. The reason is the
    /// `guard` on the first line: an unregistered service type resolves to no
    /// connector at all, so a handler physically cannot read credentials that
    /// the app is still projecting into the agent. Registration and stripping
    /// happen together or neither happens.
    ///
    /// Returns a resolution rather than an optional because "there is no such
    /// connector" and "say which one" are different answers and the agent can
    /// only act on one of them. Picking the first match for an omitted alias —
    /// which is what this used to do — sends a query to whichever Jira tenant
    /// or REDCap study happens to sort first in the manifest, and for `redcap`
    /// that means exporting one study's subject data because the tool call was
    /// under-specified. An answer that is silently arbitrary is worse than an
    /// error the agent is told how to fix.
    public static func resolveConnector(
        forServiceType serviceType: String,
        alias: String?,
        in configuration: HostControlToolConfiguration
    ) -> HostControlConnectorResolution {
        let wanted = normalized(serviceType)
        guard ownsConfiguration(ofServiceType: wanted) else { return .notProjected }
        let connectors = configuration.connectorManifest.connectors
            .filter { normalized($0.serviceType) == wanted }
        guard !connectors.isEmpty else { return .notProjected }

        guard let alias, !alias.isEmpty else {
            // Omission is only unambiguous when there is one candidate.
            guard connectors.count == 1 else {
                return .ambiguous(alias: nil, candidates: aliases(of: connectors))
            }
            return .resolved(connectors[0])
        }

        let matches = connectors.filter { $0.alias == alias || $0.name == alias || $0.id == alias }
        guard !matches.isEmpty else {
            return .unknownAlias(alias, candidates: aliases(of: connectors))
        }
        guard matches.count > 1 else { return .resolved(matches[0]) }
        // Two connectors can share an alias or a display name; they cannot
        // share an ID. So a lookup that is ambiguous by name still resolves
        // when the caller gave the one string that is unique by construction,
        // and the error below is what tells the agent to reach for it.
        let byID = matches.filter { $0.id == alias }
        guard byID.count == 1 else {
            return .ambiguous(alias: alias, candidates: identities(of: matches))
        }
        return .resolved(byID[0])
    }

    private static func aliases(of connectors: [HostControlConnector]) -> [String] {
        connectors.map(\.alias).sorted()
    }

    /// Aliases *and* IDs, for the case where the alias is what collided —
    /// listing the colliding name back at the caller would not help.
    private static func identities(of connectors: [HostControlConnector]) -> [String] {
        connectors.map { "\($0.alias) (id \($0.id))" }.sorted()
    }

    private static func normalized(_ serviceType: String) -> String {
        serviceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// What a connector lookup found. Everything except `.resolved` is a refusal
/// that names its own remedy: the broker turns each into a message the agent
/// can act on without guessing.
public enum HostControlConnectorResolution: Equatable, Sendable {
    case resolved(HostControlConnector)
    /// No connector of this service type is in scope — or the service type is
    /// not brokered at all, which is the same thing from the handler's side.
    case notProjected
    /// An alias was given and matched nothing.
    case unknownAlias(String, candidates: [String])
    /// More than one connector matched. `alias` is `nil` when the call omitted
    /// it entirely, which is the common case and the one worth wording
    /// differently.
    case ambiguous(alias: String?, candidates: [String])

    public var connector: HostControlConnector? {
        if case let .resolved(connector) = self { return connector }
        return nil
    }

    /// The refusal, phrased for the agent that has to fix the call.
    /// `nil` when there is nothing to refuse.
    public func failureMessage(serviceLabel: String) -> String? {
        switch self {
        case .resolved:
            nil
        case .notProjected:
            "No \(serviceLabel) connector is projected into ASTRA_CONNECTORS"
        case let .unknownAlias(alias, candidates):
            "No \(serviceLabel) connector matches alias '\(alias)'. In scope: "
                + candidates.joined(separator: ", ")
        case let .ambiguous(alias, candidates):
            alias.map {
                "More than one \(serviceLabel) connector matches alias '\($0)'. Pass the connector "
                    + "id instead: " + candidates.joined(separator: ", ")
            } ?? ("\(candidates.count) \(serviceLabel) connectors are in scope, so ASTRA will not "
                + "guess which one you mean. Pass alias with one of: " + candidates.joined(separator: ", "))
        }
    }
}
