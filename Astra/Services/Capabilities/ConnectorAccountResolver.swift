import Foundation
import ASTRACore
import ASTRAModels

/// Picks which account a turn uses when a workspace has more than one connector
/// of the same service (two Jira sites, two REDCap projects).
///
/// Every runnable account used to reach the agent, and the only disambiguation
/// was the broker refusing an unaliased call. The resolver narrows on an
/// explicit signal only, in this order:
///
/// 1. the task names an account, by its alias or its name (a name that is just
///    the service word, like "Jira", names nothing);
/// 2. the workspace's default account for that service.
///
/// With neither, every account stays in scope as before: the prompt tells the
/// agent to ask, and the broker still refuses a call that does not say which.
enum ConnectorAccountResolver {
    struct Resolution {
        /// The connectors to keep, in input order.
        var connectors: [Connector]
        /// Accounts left out because the task or the workspace chose another
        /// account of the same service; nothing should add them back.
        var excludedConnectorIDs: Set<UUID>
        /// Service type → the chosen account, for audit.
        var chosenByService: [String: Connector]
    }

    static func resolve(
        _ connectors: [Connector],
        contextText: String,
        activation: WorkspaceCapabilityActivationState?
    ) -> Resolution {
        let normalizedText = normalized(contextText)
        var groups: [String: [Connector]] = [:]
        for connector in connectors {
            groups[WorkspaceCapabilityActivationState.normalizedService(connector.serviceType), default: []].append(connector)
        }

        var excluded = Set<UUID>()
        var chosen: [String: Connector] = [:]
        for (service, accounts) in groups where accounts.count > 1 {
            guard let pick = choice(
                among: accounts,
                service: service,
                normalizedText: normalizedText,
                defaultID: activation?.defaultAccountID(forService: service)
            ) else { continue }
            chosen[service] = pick
            for account in accounts where account.id != pick.id {
                excluded.insert(account.id)
            }
        }
        return Resolution(
            connectors: connectors.filter { !excluded.contains($0.id) },
            excludedConnectorIDs: excluded,
            chosenByService: chosen
        )
    }

    private static func choice(
        among accounts: [Connector],
        service: String,
        normalizedText: String,
        defaultID: String?
    ) -> Connector? {
        let named = accounts.filter { names(of: $0, service: service).contains { mentions(normalizedText, $0) } }
        let fallback = defaultID.flatMap { id in accounts.first { $0.id.uuidString == id } }
        if named.count == 1 { return named[0] }
        if named.count > 1 { return fallback.flatMap { pick in named.contains { $0.id == pick.id } ? pick : nil } }
        return fallback
    }

    /// The words that name this account. The service word itself ("jira") and
    /// anything empty are dropped: every account of the service shares them.
    static func names(of connector: Connector, service: String) -> [String] {
        [connector.accountAlias ?? "", connector.name]
            .map(normalized)
            .filter { !$0.isEmpty && $0 != service && $0 != normalized(connector.serviceType) }
    }

    private static func mentions(_ normalizedText: String, _ phrase: String) -> Bool {
        " \(normalizedText) ".contains(" \(phrase) ")
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
