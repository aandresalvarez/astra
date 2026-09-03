import Foundation

/// Exact, one-shot scope for committing a connector mutation the agent staged
/// but did not send.
///
/// Every host-control connector operation before this one was a read, and that
/// was the entire safety argument: a brokered tool is granted to the agent
/// unconditionally — `HostControlPlaneMCPProjection` puts it in `allowedTools`,
/// never `askFirstTools`, and an MCP tool name cannot enter the ask tier at all
/// (`AgentPolicyAdapters.safeCanonicalClaudeToolName` maps only native provider
/// tools). So the per-tool grant the user gives once, before any content
/// exists, is the only consent in the system. It cannot be stretched to cover a
/// write.
///
/// This type is the vocabulary that lets a mutation exist without stretching
/// it. The agent composes a payload and stages it to the task folder; the
/// broker returns a digest and sends nothing. Approving *this* authorization is
/// what sends it, and `requestDigest` binds that approval to the exact staged
/// bytes — so a payload rewritten between review and commit produces a
/// mismatch and is refused rather than sent.
///
/// Shaped deliberately after `GitPublishAuthorization`, which solved the same
/// problem for pull requests: name the scope, bind the content by digest, and
/// keep the content itself out of the permission ledger. `target` is the
/// self-describing scope (the Jira project and issue type, as `repository` and
/// the branch pair are for a publish). The title and body are content and stay
/// in the staged file, reachable for review through `stagedPayloadPath`.
public struct ConnectorMutationAuthorization: Codable, Equatable, Hashable, Sendable {
    /// The connector whose credential the app will use. Resolved in-app at
    /// commit time; it is never projected to the agent, which is what makes
    /// staging safe.
    public var connectorID: UUID
    /// Lowercased connector service type, e.g. `jira`. Must be a service the
    /// broker owns — see `HostControlBrokeredServices.toolNamesByServiceType`.
    public var serviceType: String
    /// The mutating operation to perform, e.g. `create_issue`. Distinct from
    /// the `propose_issue` the agent called: proposing and committing are
    /// different acts by different parties, and naming them the same thing is
    /// how they get conflated.
    public var operation: String
    /// Human-readable destination, e.g. `STAR / Bug`. Scope, not content.
    public var target: String
    /// Absolute path to the staged payload the broker wrote.
    public var stagedPayloadPath: String
    /// SHA-256 over the staged payload, lowercase hex. Re-verified immediately
    /// before the request leaves the app.
    public var requestDigest: String

    public init(
        connectorID: UUID,
        serviceType: String,
        operation: String,
        target: String,
        stagedPayloadPath: String,
        requestDigest: String
    ) {
        self.connectorID = connectorID
        self.serviceType = serviceType
        self.operation = operation
        self.target = target
        self.stagedPayloadPath = stagedPayloadPath
        self.requestDigest = requestDigest
    }
}
