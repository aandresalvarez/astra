import SwiftUI
import SwiftData
import ASTRACore
import ASTRAModels

/// The expanded part of a `PluginRow` on the Plugins surface: what the
/// plugin brings, its settings and accounts in this workspace, and the
/// row's actions. Inline editing appears only here, after expansion
/// (`docs/design-system/lean-ui-system.md`).
///
/// Every change goes through `CapabilityCatalogActionService`
/// (`PluginsSurfaceFitnessTests`); destructive ones ask the surface for a
/// confirmation first.
struct PluginRowDetailsView<SetupRow: View>: View {
    let row: PluginRow
    let workspace: Workspace
    let setupRow: (PluginComponent) -> SetupRow
    let onEditAccount: (UUID) -> Void
    let onConfirm: (PluginsSurfaceConfirmation) -> Void
    let approvalRecords: [CapabilityApprovalRecord]
    let policyContext: CapabilityCatalogPolicyContext
    let onTurnOff: () -> Void
    let onSetApproval: (CapabilityApprovalStatus) -> Void
    let onUpdate: () -> Void
    let onChanged: () -> Void
    let onError: (String) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var drafts: [String: String] = [:]

    private var actions: CapabilityCatalogActionService { CapabilityCatalogActionService() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(row.package.skills.enumerated()), id: \.offset) { _, skill in
                skillSection(skill)
            }
            ForEach(Array(row.package.connectors.enumerated()), id: \.offset) { _, connector in
                accountSection(connector)
            }
            ForEach(Array(otherComponents.enumerated()), id: \.offset) { _, component in
                setupRow(component)
            }
            adminReview
            footer
        }
        .onAppear(perform: loadDrafts)
    }

    private var otherComponents: [PluginComponent] {
        PluginManifestConverter.manifest(from: row.package).components
            .filter { $0.kind != .skill && $0.kind != .connector }
    }

    // MARK: - Skill settings

    @ViewBuilder
    private func skillSection(_ skill: PluginSkill) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            componentHeader(skill.name, kind: "Skill")
            if row.activation != nil {
                ForEach(skill.environmentKeys, id: \.self) { key in
                    settingField(key, of: skill)
                }
            }
        }
    }

    private func settingField(_ key: String, of skill: PluginSkill) -> some View {
        let draftKey = "\(CapabilityResourceOrigin.componentID(for: skill)).\(key)"
        let binding = Binding(get: { drafts[draftKey] ?? "" }, set: { drafts[draftKey] = $0 })
        return HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            Group {
                if Skill.isSecretEnvironmentKey(key) {
                    SecretEntryField(key, text: binding)
                } else {
                    TextField(key, text: binding)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .controlSize(.small)
            Button("Save") { save(key, of: skill, value: drafts[draftKey] ?? "") }
                .controlSize(.small)
        }
    }

    // MARK: - Accounts

    @ViewBuilder
    private func accountSection(_ connector: PluginConnector) -> some View {
        let componentID = CapabilityResourceOrigin.componentID(for: connector)
        let accounts = row.activation?.accounts(forComponent: componentID) ?? []
        VStack(alignment: .leading, spacing: 4) {
            componentHeader(connector.name, kind: "Account")
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                HStack(spacing: 8) {
                    Text(account.name).font(Stanford.ui(12))
                    if !account.baseURL.isEmpty {
                        Text(account.baseURL)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if index == 0, accounts.count > 1 {
                        Text("Default").font(Stanford.caption(11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if index > 0 {
                        Button("Make default") { makeDefault(account, componentID: componentID) }
                            .controlSize(.small)
                    }
                    Button("Edit") { onEditAccount(account.id) }
                        .controlSize(.small)
                    Button("Delete", role: .destructive) {
                        onConfirm(.deleteAccount(packageID: row.package.id, accountID: account.id))
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 12)
            }
            if row.activation?.isEnabled == true {
                Button(accounts.isEmpty ? "Add account" : "Add another account") { addAccount(connector) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Stanford.lagunita)
                    .padding(.leading, 12)
            }
        }
    }

    // MARK: - Admin review

    /// An admin's review of this version: Approve, Deprecate or Block, keyed
    /// to its digest (the approval store records which one was reviewed).
    @ViewBuilder
    private var adminReview: some View {
        if let review = PluginCatalogApprovalState.adminReviewState(
            for: row.package, policyContext: policyContext, approvalRecords: approvalRecords
        ) {
            HStack(spacing: 8) {
                Text("Review").font(Stanford.ui(13))
                Text(review.digestLabel).font(Stanford.caption(11)).foregroundStyle(.secondary)
                Spacer()
                Button("Approve") { onSetApproval(.approved) }
                    .disabled(review.record?.status == .approved)
                Button("Deprecate") { onSetApproval(.deprecated) }
                    .disabled(review.record?.status == .deprecated)
                Button("Block", role: .destructive) { onSetApproval(.blocked) }
                    .disabled(review.record?.status == .blocked)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let activation = row.activation, activation.isEnabled {
                // Turning off deletes nothing, so it asks nothing.
                Toggle("On in this workspace", isOn: Binding(get: { true }, set: { if !$0 { onTurnOff() } }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if row.display.verb == .update {
                Button("Update") { onUpdate() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Stanford.lagunita)
            }
            Spacer()
            if row.display.isRemovable {
                Button("Remove", role: .destructive) { onConfirm(.remove(packageID: row.package.id)) }
                    .controlSize(.small)
            }
        }
        .padding(.top, 4)
    }

    private func componentHeader(_ name: String, kind: String) -> some View {
        HStack(spacing: 8) {
            Text(name).font(Stanford.ui(13))
            Text(kind).font(Stanford.caption(11)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func loadDrafts() {
        guard let activation = row.activation else { return }
        var next: [String: String] = [:]
        for skill in row.package.skills {
            let componentID = CapabilityResourceOrigin.componentID(for: skill)
            for key in skill.environmentKeys {
                next["\(componentID).\(key)"] = PluginOperations.setting(key, of: skill, in: activation)
            }
        }
        drafts = next
    }

    private func save(_ key: String, of skill: PluginSkill, value: String) {
        do {
            try actions.setSetting(key, to: value, of: skill, package: row.package, workspace: workspace, modelContext: modelContext)
            onChanged()
        } catch {
            onError("Couldn't save \(key): \(error.localizedDescription)")
        }
    }

    private func addAccount(_ connector: PluginConnector) {
        do {
            let account = try actions.addAccount(for: connector, of: row.package, workspace: workspace, modelContext: modelContext)
            onChanged()
            onEditAccount(account.id)
        } catch {
            onError("Couldn't add an account: \(error.localizedDescription)")
        }
    }

    private func makeDefault(_ account: Connector, componentID: String) {
        do {
            try actions.makeDefault(account, componentID: componentID, package: row.package, workspace: workspace, modelContext: modelContext)
            onChanged()
        } catch {
            onError("Couldn't change the default account: \(error.localizedDescription)")
        }
    }
}
