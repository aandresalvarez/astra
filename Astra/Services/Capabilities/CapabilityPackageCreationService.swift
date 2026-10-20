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
    /// The install failed and the approval saved ahead of it couldn't be
    /// taken back: that version stays approved.
    case approvalNotReverted(installError: String)

    var errorDescription: String? {
        switch self {
        case .invalidPackage(let report):
            return report.summary
        case .approvalNotReverted(let installError):
            return "\(installError) ASTRA also couldn't take back the approval it saved for this version, so it is still approved."
        }
    }
}

@MainActor
struct CapabilityPackageCreationService {
    let library: CapabilityLibrary
    let sourceExporter: CapabilityPackageSourceExporter
    let approvalStore: CapabilityApprovalStore
    let installer: CapabilityInstaller

    init(
        library: CapabilityLibrary = CapabilityLibrary(),
        sourceExporter: CapabilityPackageSourceExporter = CapabilityPackageSourceExporter(),
        approvalStore: CapabilityApprovalStore = CapabilityApprovalStore(),
        appVersion: SemanticVersion = SemanticVersion(string: AppBuildInfo.current.version) ?? SemanticVersion(0, 0, 0)
    ) {
        self.library = library
        self.sourceExporter = sourceExporter
        self.approvalStore = approvalStore
        self.installer = CapabilityInstaller(library: library, appVersion: appVersion)
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
        traceID: String? = nil
    ) throws -> CapabilityPackageCreationResult {
        let validation = CapabilityPackageValidator.validate(
            package: package,
            installedPackages: library.installedPackages(),
            checkPrerequisites: false
        )
        guard validation.blockers.isEmpty, let validatedPackage = validation.package else {
            throw CapabilityPackageCreationError.invalidPackage(validation)
        }

        let writtenSourceURL: URL?
        if let sourceURL {
            writtenSourceURL = try sourceExporter.export(validatedPackage, to: sourceURL)
        } else {
            writtenSourceURL = nil
        }

        if enableHere {
            let pendingApprovalRecord = try pendingApprovalRecordForImmediateEnablement(
                package: validatedPackage,
                workspace: workspace,
                policyContext: policyContext
            )
            var enablePolicyContext = policyContext ?? CapabilityCatalogPolicyContext.currentUser(
                workspace: workspace,
                approvalRecords: approvalStore.records()
            )
            if let pendingApprovalRecord,
               !enablePolicyContext.approvalRecords.contains(pendingApprovalRecord) {
                enablePolicyContext.approvalRecords.append(pendingApprovalRecord)
            }

            // The approval is written before the library entry it covers: an
            // exit between the two must not leave a new version installed
            // with no approval for its digest.
            let approval = try saveApprovalRecordIfNeeded(
                pendingApprovalRecord,
                package: validatedPackage
            )
            let installationResult: CapabilityInstaller.InstallationResult
            do {
                installationResult = try installer.install(
                    validatedPackage,
                    into: workspace,
                    modelContext: modelContext,
                    credentialInputs: credentialInputs,
                    configInputs: configInputs,
                    baseURLOverrides: baseURLOverrides,
                    allowCredentialUserInteraction: allowCredentialUserInteraction,
                    policyContext: enablePolicyContext,
                    traceID: traceID,
                    announceCatalogMutation: false
                )
            } catch let installError {
                guard !PluginOperationProblem.preventsRollback(installError) else { throw installError }
                do {
                    try approval?.revert()
                } catch {
                    throw CapabilityPackageCreationError.approvalNotReverted(installError: installError.localizedDescription)
                }
                throw installError
            }
            let approvalRecord = approval?.record
            CapabilityCatalogPersistenceEvents.post(.global)
            return CapabilityPackageCreationResult(
                package: validatedPackage,
                sourceURL: writtenSourceURL,
                approvalRecord: approvalRecord,
                installationResult: installationResult
            )
        }

        try library.install(validatedPackage)
        CapabilityCatalogPersistenceEvents.post(.global)
        return CapabilityPackageCreationResult(
            package: validatedPackage,
            sourceURL: writtenSourceURL,
            approvalRecord: nil,
            installationResult: nil
        )
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

    private func saveApprovalRecordIfNeeded(
        _ pendingRecord: CapabilityApprovalRecord?,
        package: PluginPackage
    ) throws -> (record: CapabilityApprovalRecord, revert: () throws -> Void)? {
        guard let pendingRecord else { return nil }
        return try approvalStore.saveBeforeDependentWrite(
            package: package,
            status: pendingRecord.status,
            approvedBy: pendingRecord.approvedBy,
            reviewNotes: pendingRecord.reviewNotes,
            approvedAt: pendingRecord.approvedAt
        )
    }
}
