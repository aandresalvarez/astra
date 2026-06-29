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

struct WorkspaceAppStudioTemplatePackLoadingSource: Equatable, Sendable {
    var enabledPackIDs: Set<String>

    init(enabledPackIDs: Set<String> = []) {
        self.enabledPackIDs = enabledPackIDs
    }

    @MainActor
    init(workspace: Workspace) {
        self.enabledPackIDs = Set(workspace.enabledPackIDs)
    }

    func loadSignature(workspaceID: UUID) -> String {
        ([workspaceID.uuidString] + enabledPackIDs.sorted()).joined(separator: "|")
    }

    func loadSignature(workspaceID: UUID, refreshRevision: Int) -> String {
        ([workspaceID.uuidString, String(refreshRevision)] + enabledPackIDs.sorted()).joined(separator: "|")
    }

    func templates(in snapshot: AstraPackCatalogSnapshot) -> [WorkspaceAppTemplatePackDescriptor] {
        WorkspaceAppTemplatePackCatalog(snapshot: snapshot, enabledPackIDs: enabledPackIDs).templates
    }
}

struct WorkspaceAppStudioTemplatePackRefreshApplyGate: Equatable, Sendable {
    var capturedSignature: String

    func shouldApply(currentSignature: String?, isCancelled: Bool) -> Bool {
        !isCancelled && capturedSignature == currentSignature
    }

    func apply(
        templates: [WorkspaceAppTemplatePackDescriptor],
        currentSignature: String?,
        isCancelled: Bool,
        configure: ([WorkspaceAppTemplatePackDescriptor]) -> Void
    ) {
        guard shouldApply(currentSignature: currentSignature, isCancelled: isCancelled) else { return }
        configure(templates)
    }
}

struct WorkspaceAppStudioTemplateChoice: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var iconSystemName: String
    var isSelected: Bool
}

enum WorkspaceAppStudioTemplateChoicePresentation {
    static func choices(
        from templates: [WorkspaceAppTemplatePackDescriptor],
        selectedTemplateID: String?
    ) -> [WorkspaceAppStudioTemplateChoice] {
        templates
            .sorted(by: stableOrder)
            .map { template in
                WorkspaceAppStudioTemplateChoice(
                    id: template.id,
                    title: template.displayName,
                    subtitle: template.packDisplayName,
                    iconSystemName: template.branding?.iconSystemName.isEmpty == false
                        ? template.branding?.iconSystemName ?? "square.grid.2x2"
                        : "square.grid.2x2",
                    isSelected: template.id == selectedTemplateID
                )
            }
    }

    private static func stableOrder(
        _ lhs: WorkspaceAppTemplatePackDescriptor,
        _ rhs: WorkspaceAppTemplatePackDescriptor
    ) -> Bool {
        let lhsKey = [lhs.displayName, lhs.packDisplayName, lhs.id]
        let rhsKey = [rhs.displayName, rhs.packDisplayName, rhs.id]
        return lhsKey.lexicographicallyPrecedes(rhsKey) { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
