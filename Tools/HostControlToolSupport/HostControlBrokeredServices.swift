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
    public static func connector(
        forServiceType serviceType: String,
        alias: String?,
        in configuration: HostControlToolConfiguration
    ) -> HostControlConnector? {
        let wanted = normalized(serviceType)
        guard ownsConfiguration(ofServiceType: wanted) else { return nil }
        let connectors = configuration.connectorManifest.connectors
            .filter { normalized($0.serviceType) == wanted }
        guard let alias, !alias.isEmpty else { return connectors.first }
        return connectors.first { $0.alias == alias || $0.name == alias || $0.id == alias }
    }

    private static func normalized(_ serviceType: String) -> String {
        serviceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
