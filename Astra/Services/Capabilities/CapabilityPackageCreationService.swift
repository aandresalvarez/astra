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

            let installationResult = try installer.install(
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
            let approvalRecord = try saveApprovalRecordIfNeeded(
                pendingApprovalRecord,
                package: validatedPackage
            )
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
        if CapabilityCatalogPolicy.decision(for: package, context: existingContext).canEnable {
            return nil
        }

        let approvedAt = Date()
        let pendingRecord = CapabilityApprovalRecord(
            packageID: package.id,
            packageVersion: package.version,
            status: .approved,
            approvedBy: "ASTRA Create",
            approvedAt: approvedAt,
            reviewNotes: "Created in ASTRA and approved for immediate workspace enablement.",
            sourceDigest: try CapabilityApprovalDigest.digest(for: package)
        )
        var reviewedContext = existingContext
        reviewedContext.approvalRecords.append(pendingRecord)
        let decision = CapabilityCatalogPolicy.decision(for: package, context: reviewedContext)
        guard decision.canEnable else {
            throw CapabilityInstaller.InstallationError.blocked(decision.blockerMessages)
        }

        return pendingRecord
    }

    private func saveApprovalRecordIfNeeded(
        _ pendingRecord: CapabilityApprovalRecord?,
        package: PluginPackage
    ) throws -> CapabilityApprovalRecord? {
        guard let pendingRecord else { return nil }
        return try approvalStore.save(
            package: package,
            status: pendingRecord.status,
            approvedBy: pendingRecord.approvedBy,
            reviewNotes: pendingRecord.reviewNotes,
            approvedAt: pendingRecord.approvedAt
        )
    }
}
