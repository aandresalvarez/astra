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
    /// A setup component, with the prerequisite position it checks
    /// (`PluginManifestConverter.prerequisitePosition`).
    let setupRow: (PluginComponent, Int?) -> SetupRow
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
    /// What each draft was loaded as, so a reload keeps the ones the person
    /// is still editing.
    @State private var loadedDrafts: [String: String] = [:]
    @State private var readFailures: [String: String] = [:]

    private var actions: CapabilityCatalogActionService { CapabilityCatalogActionService() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(row.package.skills.enumerated()), id: \.offset) { _, skill in
                skillSection(skill)
            }
            ForEach(Array(row.package.connectors.enumerated()), id: \.offset) { _, connector in
                if row.activation != nil { accountSection(connector) }
            }
            ForEach(Array(otherComponents.enumerated()), id: \.offset) { _, entry in
                setupRow(entry.component, entry.position)
            }
            adminReview
            footer
        }
        .onAppear(perform: loadDrafts)
        // An Update while the row stays open renames or adds settings: the
        // drafts follow the activation and the definition.
        .onChange(of: draftSource) { _, _ in loadDrafts() }
    }

    private var draftSource: String {
        PluginSettingDrafts.source(package: row.package, activation: row.activation)
    }

    private var otherComponents: [(component: PluginComponent, position: Int?)] {
        PluginsSurfacePresentation.expandedSetupComponents(for: row, in: workspace)
    }

    // MARK: - Skill settings

    @ViewBuilder
    private func skillSection(_ skill: PluginSkill) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            componentHeader(skill.name, kind: "Skill")
            ForEach(PluginsSurfacePresentation.settingKeys(of: skill, in: row.activation, package: row.package), id: \.self) { key in
                settingField(key, of: skill)
            }
        }
    }

    private func settingField(_ key: String, of skill: PluginSkill) -> some View {
        let draftKey = PluginActivation.settingKey(componentID: CapabilityResourceOrigin.componentID(for: skill), key: key)
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
            if let failure = readFailures[draftKey] {
                Text("Credential unavailable").font(.caption).foregroundStyle(.secondary).help(failure)
                Button("Retry", action: loadDrafts).controlSize(.small)
            }
            Button("Save") { save(key, of: skill, value: drafts[draftKey] ?? "") }
                .controlSize(.small)
                .disabled(readFailures[draftKey] != nil)
        }
    }

    // MARK: - Accounts

    @ViewBuilder
    private func accountSection(_ connector: PluginConnector) -> some View {
        let componentID = CapabilityResourceOrigin.componentID(for: connector)
        let accounts = row.activation?.accounts(forComponent: componentID) ?? []
        VStack(alignment: .leading, spacing: 4) {
            componentHeader(connector.name, kind: "Account")
            ForEach(accounts, id: \.id) { account in
                // The workspace has one default per service, which may be
                // another plugin's account: the binding says, not the order.
                let isDefault = row.activation?.bindings.contains {
                    !$0.isDeleted && $0.componentID == componentID && $0.account?.id == account.id && $0.isDefault
                } ?? false
                HStack(spacing: 8) {
                    // The name this workspace knows it by: a colliding shared
                    // account's binding alias, which the runtime uses too.
                    Text(PluginsSurfacePresentation.accountTitle(account, in: workspace)).font(Stanford.ui(12))
                    if !account.baseURL.isEmpty {
                        Text(account.baseURL)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if isDefault {
                        Text("Default").font(Stanford.caption(11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !isDefault {
                        Button("Make default") { makeDefault(account, componentID: componentID) }
                            .controlSize(.small)
                            .disabled(!row.canChangeAccountBindings)
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
                    .disabled(!row.canChangeAccountBindings)
                if !row.canChangeAccountBindings {
                    Text("Update the plugin before changing its accounts.")
                        .font(.caption).foregroundStyle(.secondary).padding(.leading, 12)
                }
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
            if PluginsSurfacePresentation.showsTurnOff(row) {
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
            // Remove reaches every workspace, so it is offered once the plugin
            // is off here.
            // A plugin the library no longer has runs nowhere: it is offered
            // even while its activation is on.
            if PluginsSurfacePresentation.showsRemove(row) {
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
        let snapshot = PluginSettingDrafts.load(package: row.package, activation: row.activation) { key, skill, activation in
            try PluginOperations.setting(key, of: skill, in: activation)
        }
        let fresh = snapshot.values
        readFailures = snapshot.failures
        // A field whose draft differs from what it was loaded as has an
        // unsaved edit: saving another setting must not discard it.
        var next = fresh
        for (key, value) in drafts where loadedDrafts[key] != value && (fresh[key] != nil || readFailures[key] != nil) {
            next[key] = value
        }
        loadedDrafts = fresh
        drafts = next
    }

    private func save(_ key: String, of skill: PluginSkill, value: String) {
        let field = PluginActivation.settingKey(componentID: CapabilityResourceOrigin.componentID(for: skill), key: key)
        guard readFailures[field] == nil,
              PluginsSurfacePresentation.settingKeys(of: skill, in: row.activation, package: row.package).contains(key) else { return }
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
