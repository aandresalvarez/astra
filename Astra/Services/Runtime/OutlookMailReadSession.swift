import Foundation
import ASTRAModels
import ASTRACore
import HostControlToolSupport

/// Values from one accepted scope, never live account lookups. The injected
/// loader owns OAuth and Graph; this session owns account selection only.
@MainActor
final class OutlookMailReadSession {
    private let accounts: [PluginAccountRecord]
    private let withheldAccounts: Int
    private let load: @MainActor @Sendable (PluginAccountRecord, MailReadRequest) async throws -> Data

    init(accounts: [PluginAccountRecord], withheldAccounts: Int = 0,
         load: @escaping @MainActor @Sendable (PluginAccountRecord, MailReadRequest) async throws -> Data) throws {
        var unique: [UUID: PluginAccountRecord] = [:]
        for account in accounts {
            guard account.serviceType == StanfordOutlookMail.serviceType,
                  unique[account.id] == nil || unique[account.id] == account else { throw MailReadFailure.invalidSnapshot }
            unique[account.id] = account
        }
        self.accounts = unique.values.sorted { $0.id.uuidString < $1.id.uuidString }
        self.withheldAccounts = max(0, withheldAccounts)
        self.load = load
    }

    func readMail(_ request: MailReadRequest) async throws -> Data {
        try Task.checkCancellation()
        guard !accounts.isEmpty else {
            throw withheldAccounts > 0 ? MailReadFailure.notApproved : MailReadFailure.noAccounts
        }
        if request.operation == .accounts {
            let entries: [[String: String]] = accounts.map { account in
                ["connectorID": account.id.uuidString, "name": account.name,
                 "email": config("ASTRA_MAIL_EMAIL", in: account),
                 "displayName": config("ASTRA_MAIL_DISPLAY_NAME", in: account),
                 "tenantDomain": config("ASTRA_MAIL_TENANT_DOMAIN", in: account),
                 "channel": AppChannel.current.rawValue]
            }
            return try JSONSerialization.data(withJSONObject: ["accounts": entries, "withheldAccountCount": withheldAccounts], options: [.sortedKeys])
        }
        let account = try select(request.account)
        let data = try await load(account, request)
        try Task.checkCancellation()
        return data
    }

    private func select(_ selector: String?) throws -> PluginAccountRecord {
        guard let selector else {
            guard accounts.count == 1 else { throw MailReadFailure.ambiguousAccount }
            return accounts[0]
        }
        let name = selector.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = accounts.filter { account in
            [account.id.uuidString, account.name, config("ASTRA_MAIL_EMAIL", in: account)]
                .contains { $0.lowercased() == name }
        }
        guard !matches.isEmpty else { throw MailReadFailure.unknownAccount }
        guard matches.count == 1 else { throw MailReadFailure.ambiguousAccount }
        return matches[0]
    }

    private func config(_ key: String, in account: PluginAccountRecord) -> String {
        guard let index = account.configKeys.firstIndex(of: key), index < account.configValues.count else { return "" }
        return account.configValues[index]
    }
}
