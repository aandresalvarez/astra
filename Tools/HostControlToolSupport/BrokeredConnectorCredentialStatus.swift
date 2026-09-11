import Foundation

/// Why a brokered connector's credential is not in this run's broker
/// configuration.
///
/// Two very different answers used to share one word. `api_token_present:
/// false` meant both "the user never configured this connector" and "the user
/// configured it, ASTRA verified it, and this run was not allowed to unseal
/// it". An agent reading that line can only report the first, so in production
/// it told a user their working Jira credentials were missing and the user
/// re-saved correct credentials twice. The third case has to be nameable
/// before the agent can say the true thing.
public enum BrokeredCredentialAvailability: String, Codable, Sendable, Equatable {
    /// A value for this credential is in the broker's environment for this run.
    case present
    /// ASTRA holds a value and deliberately did not expose it to this run.
    case withheld
    /// Nothing is stored for this credential.
    case absent

    /// How the status text spells it. `present` and `absent` keep the boolean
    /// wording the tool has always used, so an agent that learned
    /// `api_token_present: true` does not have to relearn it to gain a third
    /// case — only the new case needs reading.
    public var statusValue: String {
        switch self {
        case .present: "true"
        case .withheld: "withheld"
        case .absent: "false"
        }
    }
}

/// One brokered connector whose stored credentials this run may not unseal.
///
/// Key *names* only. The point of the record is to let the broker say "this
/// exists and is being held back" without the value being anywhere near the
/// process boundary that is holding it back.
public struct BrokeredConnectorCredentialWithholding: Codable, Equatable, Sendable {
    public struct Credential: Codable, Equatable, Sendable {
        /// The connector's own key name, e.g. `JIRA_API_TOKEN`.
        public var key: String
        /// The environment variable the value would have been projected into.
        public var envKey: String
        /// The manifest's logical name for it, e.g. `apiToken`.
        public var logicalName: String

        public init(key: String, envKey: String, logicalName: String) {
            self.key = key
            self.envKey = envKey
            self.logicalName = logicalName
        }
    }

    public var connectorID: String
    public var alias: String
    public var name: String
    public var serviceType: String
    public var toolName: String
    public var credentials: [Credential]

    public init(
        connectorID: String,
        alias: String,
        name: String,
        serviceType: String,
        toolName: String,
        credentials: [Credential]
    ) {
        self.connectorID = connectorID
        self.alias = alias
        self.name = name
        self.serviceType = serviceType
        self.toolName = toolName
        self.credentials = credentials
    }

    /// Matches the same way `HostControlConnector.environmentKey(forLogicalName:)`
    /// does, because the caller asks both with the same candidate names and a
    /// credential that resolves in one and not the other would report as absent.
    public func credential(named logicalName: String) -> Credential? {
        let normalized = logicalName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return nil }
        if let exact = credentials.first(where: {
            $0.logicalName == logicalName || $0.key.uppercased() == normalized
        }) {
            return exact
        }
        return credentials.first {
            $0.envKey.uppercased().hasSuffix(normalized) || $0.envKey.uppercased() == normalized
        }
    }
}

/// Every connector whose credentials this run holds back, projected into the
/// broker's own configuration.
///
/// This never reaches the agent's process. `HostControlBrokerSessionRegistry`
/// builds it alongside the credentials it *did* unseal and hands both to the
/// in-app broker; the agent sees only the status text the broker writes from it.
public struct BrokeredConnectorCredentialWithholdingManifest: Codable, Equatable, Sendable {
    public static let environmentKey = "ASTRA_CONNECTOR_CREDENTIALS_WITHHELD"

    public var version: Int
    public var connectors: [BrokeredConnectorCredentialWithholding]

    public init(version: Int = 1, connectors: [BrokeredConnectorCredentialWithholding]) {
        self.version = version
        self.connectors = connectors
    }

    public var isEmpty: Bool { connectors.isEmpty }

    public func encoded() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decoding failure is reported as "nothing withheld" rather than thrown:
    /// a malformed marker must not be able to fail a tool call the credentials
    /// would otherwise have served.
    public static func decoded(from json: String?) -> BrokeredConnectorCredentialWithholdingManifest {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return BrokeredConnectorCredentialWithholdingManifest(connectors: [])
        }
        return decoded
    }
}

public extension HostControlToolConfiguration {
    var withheldConnectorCredentials: BrokeredConnectorCredentialWithholdingManifest {
        .decoded(from: environment[BrokeredConnectorCredentialWithholdingManifest.environmentKey])
    }

    func withheldCredentials(
        for connector: HostControlConnector
    ) -> BrokeredConnectorCredentialWithholding? {
        withheldConnectorCredentials.connectors.first {
            $0.connectorID.caseInsensitiveCompare(connector.id) == .orderedSame
        }
    }
}

public extension HostControlConnector {
    /// The environment variable this connector's manifest entry binds
    /// `logicalName` to.
    ///
    /// One copy. This lookup was written out three times — once per typed
    /// handler plus the server — and each copy is a place where a connector
    /// could start resolving its token differently from the projection that
    /// created it.
    func environmentKey(forLogicalName logicalName: String) -> String? {
        if let key = credentials[logicalName] ?? env[logicalName] {
            return key
        }
        let normalized = logicalName.uppercased()
        return (Array(credentials.values) + Array(env.values)).first {
            $0.uppercased().hasSuffix(normalized) || $0.uppercased() == normalized
        }
    }
}

/// The readiness answer every broker-owned connector gives, in one shape.
///
/// Jira and REDCap each had their own status struct and their own formatter
/// with the same field names in them. Landing the withheld case once means
/// landing it here, and a third brokered service inherits it by construction
/// rather than by someone remembering.
public struct BrokeredConnectorStatusReport: Equatable, Sendable {
    /// A credential the caller wants reported, named the way the status text
    /// names it (`email`, `api_token`) and resolved through the same candidate
    /// list the connector's manifest entry might have bound it under.
    public struct CredentialRequest: Equatable, Sendable {
        public var label: String
        public var candidateLogicalNames: [String]

        public init(label: String, candidateLogicalNames: [String]) {
            self.label = label
            self.candidateLogicalNames = candidateLogicalNames
        }
    }

    public struct Credential: Equatable, Sendable {
        public var label: String
        public var envKey: String?
        public var availability: BrokeredCredentialAvailability
    }

    public var serviceLabel: String
    public var alias: String
    public var baseURL: String
    public var baseURLReady: Bool
    public var credentials: [Credential]

    public init(
        serviceLabel: String,
        connector: HostControlConnector,
        configuration: HostControlToolConfiguration,
        credentials requests: [CredentialRequest]
    ) {
        let scheme = URL(string: connector.baseURL)?.scheme?.lowercased()
        let withholding = configuration.withheldCredentials(for: connector)
        self.serviceLabel = serviceLabel
        alias = connector.alias
        baseURL = connector.baseURL
        baseURLReady = scheme == "http" || scheme == "https"
        credentials = requests.map { request in
            Self.resolve(
                request,
                connector: connector,
                configuration: configuration,
                withholding: withholding
            )
        }
    }

    private static func resolve(
        _ request: CredentialRequest,
        connector: HostControlConnector,
        configuration: HostControlToolConfiguration,
        withholding: BrokeredConnectorCredentialWithholding?
    ) -> Credential {
        let boundKey = request.candidateLogicalNames
            .lazy
            .compactMap { connector.environmentKey(forLogicalName: $0) }
            .first
        // A withheld credential is skipped by the projection, so it has no
        // manifest binding and no environment value: the withholding record is
        // the only place its name still exists. Consulting it before falling
        // back to `absent` is the whole fix.
        let withheld = request.candidateLogicalNames
            .lazy
            .compactMap { withholding?.credential(named: $0) }
            .first
        if let boundKey {
            let value = configuration.environment[boundKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty {
                return Credential(label: request.label, envKey: boundKey, availability: .present)
            }
            if let withheld {
                return Credential(label: request.label, envKey: withheld.envKey, availability: .withheld)
            }
            return Credential(label: request.label, envKey: boundKey, availability: .absent)
        }
        if let withheld {
            return Credential(label: request.label, envKey: withheld.envKey, availability: .withheld)
        }
        return Credential(label: request.label, envKey: nil, availability: .absent)
    }

    public var withheldCredentials: [Credential] {
        credentials.filter { $0.availability == .withheld }
    }

    public var hasWithheldCredentials: Bool { !withheldCredentials.isEmpty }

    public var ready: Bool {
        baseURLReady && credentials.allSatisfy { $0.availability == .present }
    }

    public func value(labeled label: String) -> Credential? {
        credentials.first { $0.label == label }
    }

    /// What the diagnostics log says when a call could not proceed.
    ///
    /// "not configured" was the only phrasing available, and it was written
    /// into the log for the withheld case too — so the log agreed with the
    /// wrong story the agent told, and reading it back confirmed the mistake
    /// instead of catching it.
    public var blockedDiagnosticReason: String {
        if hasWithheldCredentials { return "credentials withheld from this run" }
        return "not configured"
    }

    /// Reports the *name* of the variable holding each credential and whether
    /// it is populated. Never the value — this is the call an agent makes when
    /// it is working out why a connector is unavailable, so it is the one most
    /// likely to end up quoted in a transcript.
    public func formatted() -> String {
        var lines = [
            "alias: \(alias)",
            "base_url: \(baseURLReady ? baseURL : "<missing or invalid>")"
        ]
        for credential in credentials {
            lines.append("\(credential.label)_env_key: \(credential.envKey ?? "<missing>")")
            lines.append("\(credential.label)_present: \(credential.availability.statusValue)")
        }
        lines.append("ready: \(ready)")
        lines.append(contentsOf: withheldGuidance())
        return lines.joined(separator: "\n")
    }

    /// The sentences that decide what the agent tells the user.
    ///
    /// Written to close off the wrong conclusion explicitly rather than leaving
    /// it merely unstated: the failure this replaces was an agent inferring a
    /// broken configuration from a silence, and inference is what has to be
    /// pre-empted.
    private func withheldGuidance() -> [String] {
        let withheld = withheldCredentials
        guard !withheld.isEmpty else { return [] }
        let keys = withheld.compactMap(\.envKey).joined(separator: ", ")
        return [
            "credentials_withheld: true",
            "credentials_withheld_keys: \(keys)",
            "credentials_withheld_reason: the user has configured these credentials and ASTRA still holds them. "
                + "This turn's wording did not mention \(serviceLabel), so ASTRA did not unseal them for this run. "
                + "Nothing about the saved configuration is missing, expired, or wrong.",
            "next_step: this needs approval, not reconfiguration. ASTRA raises a credential approval request for "
                + "'\(alias)' from this call; ask the user to approve it in ASTRA and then retry. Do not tell the "
                + "user the connector is unconfigured, and do not ask them to re-enter, re-save, or re-verify the "
                + "credentials."
        ]
    }
}

/// Told when the agent actually calls a brokered connector whose credentials
/// this run withheld.
///
/// The tool call is the narration. A connector the turn's wording never named
/// cannot make the launch ask the user for anything — that is the rule this
/// broker exists under — but an agent reaching for the tool is the run saying
/// it wants the connector, and that is a different signal arriving at a
/// different time. The observer only records it; it must not block, and
/// nothing downstream of it may change what this run does.
public protocol BrokeredCredentialWithholdingObserving: AnyObject, Sendable {
    /// Called on the broker's connection queue, inside the lock that serializes
    /// tool calls. Implementations return immediately.
    func brokeredConnectorInvokedWithWithheldCredentials(
        _ withholding: BrokeredConnectorCredentialWithholding
    )
}

public extension BrokeredCredentialWithholdingObserving {
    func noteWithheldCredentials(
        for connector: HostControlConnector,
        configuration: HostControlToolConfiguration
    ) {
        guard let withholding = configuration.withheldCredentials(for: connector) else { return }
        brokeredConnectorInvokedWithWithheldCredentials(withholding)
    }
}
