import SwiftUI
import SwiftData
import ASTRACore
import ASTRAModels

/// The accounts no plugin row shows, as one more group in the Plugins card:
/// what Remove keeps, or an Update leaves when it drops their component
/// (`PluginsSurfacePresentation.unusedAccounts`). Delete account is the only
/// operation that clears an account's credentials, so these stay reachable
/// once the plugin or component that showed them is gone.
///
/// Rows follow the plugin rows' grammar: the row body expands in place, and
/// Delete asks first, naming every workspace it reaches. Every change goes
/// through `CapabilityCatalogActionService` (`PluginsSurfaceFitnessTests`).
struct PluginAccountsSection: View {
    let accounts: [Connector]
    let onEditAccount: (UUID) -> Void
    let onChanged: () -> Void
    let onError: (String) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var expanded: Set<UUID> = []
    @State private var confirmingID: UUID?

    var body: some View {
        if !accounts.isEmpty {
            Text("Accounts not used by a plugin")
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            ForEach(accounts, id: \.id) { account in
                row(account)
                Divider().padding(.leading, 38)
            }
        }
    }

    private func row(_ account: Connector) -> some View {
        let subtitle = PluginsSurfacePresentation.accountSubtitle(account)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if expanded.contains(account.id) { expanded.remove(account.id) } else { expanded.insert(account.id) }
            } label: {
                HStack(spacing: 10) {
                    CapabilityLeadingIcon(
                        systemImage: account.icon,
                        brand: BrandMark.resolve(id: account.serviceType, name: account.name),
                        pointSize: 16
                    )
                    .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name.isEmpty ? "Untitled account" : account.name)
                            .font(Stanford.ui(14, weight: .semibold))
                        Text(subtitle)
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(subtitle)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded.contains(account.id) ? "chevron.down" : "chevron.right")
                        .font(Stanford.ui(11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded.contains(account.id) {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Edit") { onEditAccount(account.id) }
                        .controlSize(.small)
                    Button("Delete account", role: .destructive) { confirmingID = account.id }
                        .controlSize(.small)
                }
                .padding(.leading, 38)
                if confirmingID == account.id {
                    confirmation(account)
                        .padding(.leading, 38)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func confirmation(_ account: Connector) -> some View {
        // An unreadable delete scope offers no Delete: the confirmation
        // would not name every workspace the deletion reaches.
        let reach = (try? PluginOperations.workspacesUsing(account))?.map(\.name)
        let copy = PluginsSurfaceConfirmation.deleteAccountCopy(name: account.name, workspaces: reach ?? [])
        return PluginsSurfaceConfirmationRow(
            message: reach == nil ? PluginOperations.OperationError.storeUnreadable.localizedDescription : copy.message,
            verb: reach == nil ? nil : copy.verb,
            onCancel: { confirmingID = nil },
            onConfirm: {
                confirmingID = nil
                delete(account)
            }
        )
    }

    private func delete(_ account: Connector) {
        let name = account.name
        do {
            try CapabilityCatalogActionService().deleteAccount(account, modelContext: modelContext)
            expanded.remove(account.id)
            onChanged()
        } catch {
            onError("Couldn't delete \(name): \(error.localizedDescription)")
        }
    }
}

/// The second tap of a destructive Plugins-surface action: what goes, and
/// the verb that does it. No verb when the scope can't be named.
struct PluginsSurfaceConfirmationRow: View {
    let message: String
    let verb: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .font(Stanford.caption(12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel", action: onCancel)
                .controlSize(.small)
            if let verb {
                Button(verb, role: .destructive, action: onConfirm)
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(Stanford.statusError.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
