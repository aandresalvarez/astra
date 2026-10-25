import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

struct CapabilityPackageCreationResult {
    var package: PluginPackage
    var sourceURL: URL?
    var approvalRecord: CapabilityApprovalRecord?
    var installationResult: CapabilityInstaller.InstallationResult?
}

enum CapabilityPackageCreationError: LocalizedError {
    case invalidPackage(CapabilityPackageValidationReport)
    var errorDescription: String? {
        switch self {
        case .invalidPackage(let report):
            return report.summary
        }
    }
}

@MainActor
struct CapabilityPackageCreationService {
    let library: CapabilityLibrary
    let sourceExporter: CapabilityPackageSourceExporter
    let approvalStore: CapabilityApprovalStore
    let installer: CapabilityInstaller
    let sourceStore: PluginSourceStore

    init(
        library: CapabilityLibrary = CapabilityLibrary(),
        sourceExporter: CapabilityPackageSourceExporter = CapabilityPackageSourceExporter(),
        approvalStore: CapabilityApprovalStore = CapabilityApprovalStore(),
        appVersion: SemanticVersion = SemanticVersion(string: AppBuildInfo.current.version) ?? SemanticVersion(0, 0, 0),
        sourceStore: PluginSourceStore = PluginSourceStore()
    ) {
        self.library = library
        self.sourceExporter = sourceExporter
        self.approvalStore = approvalStore
        self.sourceStore = sourceStore
        self.installer = CapabilityInstaller(library: library, appVersion: appVersion, sourceStore: sourceStore)
    }

    @discardableResult
    func create(
        _ package: PluginPackage,
        enableHere: Bool,
        sourceURL: URL?,
        workspace: Workspace,
        modelContext: ModelContext,
        credentialInputs: [String: String] = [:],
        configInputs: [String: String] = [:],
        baseURLOverrides: [String: String] = [:],
        allowCredentialUserInteraction: Bool = false,
        policyContext: CapabilityCatalogPolicyContext? = nil,
        traceID: String? = nil,
        mutationPermit: PluginMutationScope.Permit? = nil
    ) throws -> CapabilityPackageCreationResult {
        if enableHere {
            try PluginActivationAdmission.requireNoUnrelatedEditsForAdd(in: workspace, modelContext: modelContext)
        }
        guard let mutationPermit else {
            return try PluginMutationScope.perform(pluginID: package.id, library: library, store: sourceStore,
                modelContext: modelContext, approvals: approvalStore) { permit in
                try create(package, enableHere: enableHere, sourceURL: sourceURL, workspace: workspace,
                    modelContext: modelContext, credentialInputs: credentialInputs, configInputs: configInputs,
                    baseURLOverrides: baseURLOverrides, allowCredentialUserInteraction: allowCredentialUserInteraction,
                    policyContext: policyContext, traceID: traceID, mutationPermit: permit)
            }
        }
        try PluginMutationScope.perform(pluginID: package.id, library: library, store: sourceStore,
            modelContext: modelContext, permit: mutationPermit) { _ in }
        let validation = CapabilityPackageValidator.validate(
            package: package,
            installedPackages: library.installedPackages(),
            checkPrerequisites: false
        )
        guard validation.blockers.isEmpty, let checkedPackage = validation.package else {
            throw CapabilityPackageCreationError.invalidPackage(validation)
        }

        var located = checkedPackage
        if located.iconDescriptor.kind == .asset { located.sourceMetadata?.url = package.sourceMetadata?.url }
        let validatedPackage = PluginInstallationTransaction.reviewedPackage(located)
        let writtenSourceURL: URL?
        if let sourceURL {
            writtenSourceURL = try sourceExporter.export(validatedPackage, to: sourceURL)
        } else {
            writtenSourceURL = nil
        }

        return try PluginSourceDefinitionOperation(library: library, store: sourceStore).installing(validatedPackage,
            clearSource: true, modelContext: modelContext, approvals: approvalStore) { operation in
            guard enableHere else {
                let transaction = try PluginInstallationTransaction.prepare(package: validatedPackage, library: library,
                    modelContext: modelContext, approvals: approvalStore, operation: operation)
                let installed = try transaction.commitWithoutEnabling(modelContext: modelContext)
                return CapabilityPackageCreationResult(package: installed, sourceURL: writtenSourceURL,
                    approvalRecord: nil, installationResult: nil)
            }
            let pendingApproval = try pendingApprovalRecordForImmediateEnablement(
                package: validatedPackage, workspace: workspace, policyContext: policyContext)
            var enablePolicyContext = policyContext ?? CapabilityCatalogPolicyContext.currentUser(
                workspace: workspace, approvalRecords: approvalStore.records())
            if let pendingApproval, !enablePolicyContext.approvalRecords.contains(pendingApproval) {
                enablePolicyContext.approvalRecords.append(pendingApproval)
            }
            let installation = try installer.install(validatedPackage, into: workspace, modelContext: modelContext,
                credentialInputs: credentialInputs, configInputs: configInputs, baseURLOverrides: baseURLOverrides,
                allowCredentialUserInteraction: allowCredentialUserInteraction, policyContext: enablePolicyContext,
                traceID: traceID, announceCatalogMutation: false, approvalStore: approvalStore,
                pendingApproval: pendingApproval, fileOperation: operation, mutationPermit: mutationPermit)
            CapabilityCatalogPersistenceEvents.post(.global)
            return CapabilityPackageCreationResult(package: validatedPackage, sourceURL: writtenSourceURL,
                approvalRecord: pendingApproval, installationResult: installation)
        }
    }

    private func pendingApprovalRecordForImmediateEnablement(
        package: PluginPackage,
        workspace: Workspace,
        policyContext: CapabilityCatalogPolicyContext?
    ) throws -> CapabilityApprovalRecord? {
        let existingContext = policyContext ?? CapabilityCatalogPolicyContext.currentUser(
            workspace: workspace,
            approvalRecords: approvalStore.records()
        )
        return try CapabilityApprovalGrant.pendingRecord(
            for: package,
            context: existingContext,
            approvedBy: "ASTRA Create",
            reviewNotes: "Created in ASTRA and approved for immediate workspace enablement."
        )
    }

}
