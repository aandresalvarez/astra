import Foundation

/// Opening, during a run, a connector the launch held back.
///
/// The offered tier gives a run the route to a connector its turn never named
/// and keeps the secret. Where ASTRA would grant that secret without asking the
/// user anyway, waiting for the run to end only costs them the answer they asked
/// for. So a read may open it at the moment it is needed. The broker decides
/// nothing: it holds the values apart, asks ASTRA, and uses them only after
/// ASTRA says it has saved that it allowed the connector.

/// Credentials the launch held back that ASTRA may still open in the same run.
///
/// Kept apart from the broker's environment, which every host process it starts
/// inherits: a value joins a call only after ASTRA has allowed its connector, and
/// only for reads of that connector.
public struct BrokeredSealedCredentials: Equatable, Sendable {
    /// `ASTRA_CONNECTORS` as it reads with these credentials opened: the same
    /// connectors under the same aliases, now with their credential bindings.
    public var connectorsJSON: String
    /// The held-back values, by the environment variable the withholding record
    /// names.
    public var environment: [String: String]

    public init(connectorsJSON: String, environment: [String: String]) {
        self.connectorsJSON = connectorsJSON
        self.environment = environment
    }
}

extension HostControlToolConfiguration {
    /// This configuration with one held-back connector opened, or nil when
    /// `sealed` cannot supply every value held back for it. Other held-back
    /// connectors gain a manifest binding but no value, so they stay withheld.
    func opening(
        _ withholding: BrokeredConnectorCredentialWithholding,
        from sealed: BrokeredSealedCredentials
    ) -> HostControlToolConfiguration? {
        var opened = self
        for credential in withholding.credentials {
            guard let value = sealed.environment[credential.envKey] else { return nil }
            opened.environment[credential.envKey] = value
        }
        opened.connectorsJSON = sealed.connectorsJSON
        return opened
    }
}

/// How one read of a connector is served, and what getting there cost.
struct BrokeredReadAccess {
    var configuration: HostControlToolConfiguration
    var connector: HostControlConnector
    /// How long this call waited for ASTRA to allow the connector.
    var waitedSeconds: TimeInterval = 0
}

extension HostControlProcessLimits {
    /// A read's timeout when the call has already waited for ASTRA. Both come out
    /// of one allowance: the caller stops listening shortly after the longest
    /// read, so a wait added on top of it would cost the agent the answer.
    func readTimeout(_ requested: TimeInterval, afterWaiting waited: TimeInterval) -> TimeInterval {
        min(requested, clampedTimeout(maximumTimeoutSeconds - waited))
    }
}

/// One broker session's held-back credentials and what ASTRA has opened of them.
///
/// Calls reach the broker one at a time, so the set of opened connectors needs no
/// lock of its own.
final class BrokeredCredentialOpener {
    private let sealed: BrokeredSealedCredentials
    private let requester: any BrokeredExternalActionRequesting
    /// Remembered so ASTRA is asked once. A refusal is not remembered: it may
    /// only have been a busy app.
    private var openedConnectorIDs: Set<String> = []

    init(sealed: BrokeredSealedCredentials, requester: any BrokeredExternalActionRequesting) {
        self.sealed = sealed
        self.requester = requester
    }

    /// What a write of `connector` is composed against: the launch's
    /// configuration, still without the value, but saying so when a read has
    /// already had the connector allowed, so the reply does not claim otherwise.
    func configuration(
        forWriting connector: HostControlConnector,
        in launch: HostControlToolConfiguration
    ) -> HostControlToolConfiguration {
        guard openedConnectorIDs.contains(connector.id) else { return launch }
        var manifest = launch.withheldConnectorCredentials
        for index in manifest.connectors.indices
        where manifest.connectors[index].connectorID.caseInsensitiveCompare(connector.id) == .orderedSame {
            manifest.connectors[index].consent = .given
        }
        guard let encoded = manifest.encoded() else { return launch }
        var marked = launch
        marked.environment[BrokeredConnectorCredentialWithholdingManifest.environmentKey] = encoded
        return marked
    }

    /// What serves a read of `connector`: the launch's own configuration, or one
    /// with the connector opened. Only reads come through here; a write composed
    /// in this run stays held back.
    func access(
        toRead connector: HostControlConnector,
        in launch: HostControlToolConfiguration
    ) -> BrokeredReadAccess {
        let heldBack = BrokeredReadAccess(configuration: launch, connector: connector)
        guard let withholding = launch.withheldCredentials(for: connector),
              let opened = launch.opening(withholding, from: sealed),
              let openedConnector = HostControlBrokeredServices.resolveConnector(
                  forServiceType: connector.serviceType,
                  alias: connector.alias,
                  in: opened
              ).connector,
              openedConnector.id == connector.id else {
            return heldBack
        }
        var access = BrokeredReadAccess(configuration: opened, connector: openedConnector)
        if !openedConnectorIDs.contains(connector.id) {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            guard requester.allowHeldBackConnector(withholding) else { return heldBack }
            access.waitedSeconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
            openedConnectorIDs.insert(connector.id)
        }
        return access
    }
}
