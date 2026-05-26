import Foundation
import SwiftData
import ASTRACore

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
            let approvalRecord = try approvalRecordForImmediateEnablement(
                package: validatedPackage,
                workspace: workspace,
                policyContext: policyContext
            )
            var enablePolicyContext = policyContext ?? CapabilityCatalogPolicyContext.workspaceUser(
                workspace: workspace,
                isAdmin: true,
                approvalRecords: approvalStore.records()
            )
            if let approvalRecord,
               !enablePolicyContext.approvalRecords.contains(approvalRecord) {
                enablePolicyContext.approvalRecords.append(approvalRecord)
            }

            let installationResult = try installer.install(
                validatedPackage,
                into: workspace,
                modelContext: modelContext,
                credentialInputs: credentialInputs,
                configInputs: configInputs,
                baseURLOverrides: baseURLOverrides,
                policyContext: enablePolicyContext,
                traceID: traceID
            )
            return CapabilityPackageCreationResult(
                package: validatedPackage,
                sourceURL: writtenSourceURL,
                approvalRecord: approvalRecord,
                installationResult: installationResult
            )
        }

        try library.install(validatedPackage)
        return CapabilityPackageCreationResult(
            package: validatedPackage,
            sourceURL: writtenSourceURL,
            approvalRecord: nil,
            installationResult: nil
        )
    }

    private func approvalRecordForImmediateEnablement(
        package: PluginPackage,
        workspace: Workspace,
        policyContext: CapabilityCatalogPolicyContext?
    ) throws -> CapabilityApprovalRecord? {
        let existingContext = policyContext ?? CapabilityCatalogPolicyContext.workspaceUser(
            workspace: workspace,
            isAdmin: true,
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

        return try approvalStore.save(
            package: package,
            status: .approved,
            approvedBy: pendingRecord.approvedBy,
            reviewNotes: pendingRecord.reviewNotes,
            approvedAt: approvedAt
        )
    }
}
