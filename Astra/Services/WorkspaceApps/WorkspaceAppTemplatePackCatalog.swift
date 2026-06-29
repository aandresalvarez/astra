import Foundation
import ASTRACore

struct WorkspaceAppTemplatePackDescriptor: Identifiable, Equatable, Sendable {
    var packID: String
    var packDisplayName: String
    var packSource: AstraPackSource
    var templateContributionID: String
    var templateID: String
    var displayName: String
    var capabilityPackageIDs: [String]
    var branding: AstraPackBranding?

    var id: String { "\(packID)/\(templateContributionID)" }
}

struct WorkspaceAppStudioTemplateContext: Equatable, Sendable {
    var packID: String?
    var packDisplayName: String?
    var templateID: String
    var displayName: String
    var capabilityPackageIDs: [String]
    var branding: AstraPackBranding?

    init(
        packID: String? = nil,
        packDisplayName: String? = nil,
        templateID: String,
        displayName: String,
        capabilityPackageIDs: [String] = [],
        branding: AstraPackBranding? = nil
    ) {
        self.packID = packID
        self.packDisplayName = packDisplayName
        self.templateID = templateID
        self.displayName = displayName
        self.capabilityPackageIDs = capabilityPackageIDs
        self.branding = branding
    }

    init(packTemplate descriptor: WorkspaceAppTemplatePackDescriptor) {
        self.init(
            packID: descriptor.packID,
            packDisplayName: descriptor.packDisplayName,
            templateID: descriptor.templateID,
            displayName: descriptor.displayName,
            capabilityPackageIDs: descriptor.capabilityPackageIDs,
            branding: descriptor.branding
        )
    }
}

struct WorkspaceAppTemplatePackCatalog: Equatable {
    var snapshot: AstraPackCatalogSnapshot
    var enabledPackIDs: Set<String>

    init(snapshot: AstraPackCatalogSnapshot, enabledPackIDs: Set<String> = []) {
        self.snapshot = snapshot
        self.enabledPackIDs = enabledPackIDs
    }

    var templates: [WorkspaceAppTemplatePackDescriptor] {
        snapshot.entries.flatMap { entry -> [WorkspaceAppTemplatePackDescriptor] in
            guard enabledPackIDs.contains(entry.manifest.id) else { return [] }
            return entry.manifest.appTemplates.compactMap { template in
                guard template.contributionKind == "workspaceApp" else { return nil }
                return WorkspaceAppTemplatePackDescriptor(
                    packID: entry.manifest.id,
                    packDisplayName: entry.manifest.name,
                    packSource: entry.source,
                    templateContributionID: template.id,
                    templateID: template.templateID,
                    displayName: template.name,
                    capabilityPackageIDs: template.capabilityPackageIDs,
                    branding: entry.manifest.branding
                )
            }
        }
    }
}
