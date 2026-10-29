import SwiftUI
import ASTRACore
import ASTRAModels

/// Rail-generic presentation helpers that outlive the v1 checklist: the
/// capability composition summary (now a tooltip) and the detail-list overflow
/// line used by the expanded remote and routine editors. The boxes, rows and
/// order come from `WorkspaceRailSectionPresentation`.
enum WorkspaceRightRailPresentation {
    /// How many items an expanded detail list shows before an overflow line.
    static let detailPreviewLimit = 4

    static func compositionSummary(for item: RailCapabilityItem) -> String {
        var parts: [String] = []
        appendCount(item.skillNames.count, singular: "skill", plural: "skills", to: &parts)
        appendCount(item.connectorNames.count, singular: "connector", plural: "connectors", to: &parts)
        appendCount(item.toolNames.count, singular: "tool", plural: "tools", to: &parts)
        appendCount(item.mcpServerNames.count, singular: "MCP server", plural: "MCP servers", to: &parts)
        appendCount(item.browserAdapterNames.count, singular: "browser adapter", plural: "browser adapters", to: &parts)
        appendCount(item.templateNames.count, singular: "template", plural: "templates", to: &parts)

        if !parts.isEmpty {
            return parts.joined(separator: ", ")
        }

        let fallback = item.presentation.rowSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "No resources" : fallback
    }

    static func overflowSummary(
        total: Int,
        visible: Int,
        singular: String,
        plural: String
    ) -> String? {
        let remaining = total - visible
        guard remaining > 0 else { return nil }
        return "\(remaining) more \(remaining == 1 ? singular : plural)"
    }

    private static func appendCount(_ count: Int, singular: String, plural: String, to parts: inout [String]) {
        guard count > 0 else { return }
        parts.append("\(count) \(count == 1 ? singular : plural)")
    }
}

/// Folder facts for the rail's Environment rows and the Workspace home
/// screen: which configured paths count as added folders (the root is a
/// reference, not an addition), their detail rows, and removal.
struct WorkspaceFolderDetailRowPresentation: Equatable {
    let title: String
    let subtitle: String
    let path: String
    let copyPathHelp: String
    let canRemove: Bool
    let showsPathInBody: Bool
}

enum WorkspaceFolderPresentation {
    static let folderAccessTitle = "Folder access"
    static let addFolderActionTitle = "Add folder"
    static let workspaceRootFolderSubtitle = "Workspace root"
    static let additionalFolderSubtitle = "Additional folder"
    static let copyFolderPathHelp = "Copy folder path"
    static let showsFolderPathInDetailRows = false
    static let missingWorkspaceRootSubtitle = "No workspace root selected."
    static let referenceOnlyFolderSubtitle = "Workspace root only"

    static func shouldShowWorkspaceRootMissingMessage(primaryPath: String) -> Bool {
        WorkspacePathPresentation.standardizedPath(primaryPath).isEmpty
    }

    static func userConfiguredFolderDescriptors(_ additionalPaths: [String]) -> [WorkspacePathDescriptor] {
        userConfiguredFolderDescriptors(primaryPath: "", additionalPaths: additionalPaths)
    }

    static func userConfiguredFolderDescriptors(
        primaryPath: String,
        additionalPaths: [String]
    ) -> [WorkspacePathDescriptor] {
        let rootPath = WorkspacePathPresentation.standardizedPath(primaryPath)
        let folderPaths = additionalPaths.filter { rawPath in
            let folderPath = WorkspacePathPresentation.standardizedPath(rawPath)
            return rootPath.isEmpty || folderPath != rootPath
        }
        return WorkspacePathPresentation.descriptors(primaryPath: "", additionalPaths: folderPaths)
    }

    static func userConfiguredFolderCount(_ additionalPaths: [String]) -> Int {
        userConfiguredFolderDescriptors(additionalPaths).count
    }

    static func userConfiguredFolderCount(primaryPath: String, additionalPaths: [String]) -> Int {
        userConfiguredFolderDescriptors(primaryPath: primaryPath, additionalPaths: additionalPaths).count
    }

    static func remainingAdditionalPaths(
        afterRemovingFolderMatching path: String,
        from additionalPaths: [String]
    ) -> [String] {
        let removedPath = WorkspacePathPresentation.standardizedPath(path)
        guard !removedPath.isEmpty else { return additionalPaths }
        return additionalPaths.filter { rawPath in
            WorkspacePathPresentation.standardizedPath(rawPath) != removedPath
        }
    }

    static func folderDetailRow(for descriptor: WorkspacePathDescriptor) -> WorkspaceFolderDetailRowPresentation {
        WorkspaceFolderDetailRowPresentation(
            title: descriptor.title,
            subtitle: descriptor.role == .primary ? workspaceRootFolderSubtitle : additionalFolderSubtitle,
            path: descriptor.path,
            copyPathHelp: copyFolderPathHelp,
            canRemove: descriptor.role == .additional,
            showsPathInBody: showsFolderPathInDetailRows
        )
    }

    static func folderSubtitle(primaryPath: String, additionalPaths: [String]) -> String {
        guard !shouldShowWorkspaceRootMissingMessage(primaryPath: primaryPath) else {
            return missingWorkspaceRootSubtitle
        }
        let count = userConfiguredFolderCount(primaryPath: primaryPath, additionalPaths: additionalPaths)
        guard count > 0 else { return referenceOnlyFolderSubtitle }
        return "\(count) added \(count == 1 ? "folder" : "folders")"
    }
}

enum WorkspaceContextIconography {
    static func capabilityIcon(name: String, fallback: String) -> String {
        CapabilityIconPresentation
            .make(name: name, fallbackSystemName: fallback)
            .legacySystemName
    }
}

struct CapabilityRuntimePermissionAttention: Equatable {
    let connectorID: UUID
    let requestDisplayName: String
    let credentialCount: Int

    static func pending(for task: AgentTask?) -> [CapabilityRuntimePermissionAttention] {
        guard let task else { return [] }
        return TaskRuntimePermissionOpenRequestStore.openRequestPayloads(for: task).flatMap {
            payload -> [CapabilityRuntimePermissionAttention] in
            guard let decoded = PermissionApprovalEventPayload.decoded(from: payload) else { return [] }
            switch decoded.request {
            case .connectorCredentials(let connectorID, let displayName, let labels):
                // One request can name several connectors — the launch gate asks
                // for every connector a launch needs at once — so mark each one.
                let labelsByConnector = Dictionary(grouping: labels) {
                    ConnectorRuntimeProjection.connectorID(fromCredentialLabel: $0) ?? connectorID
                }
                guard !labelsByConnector.isEmpty else {
                    return [CapabilityRuntimePermissionAttention(
                        connectorID: connectorID,
                        requestDisplayName: displayName,
                        credentialCount: 1
                    )]
                }
                return labelsByConnector
                    .sorted { $0.key.uuidString < $1.key.uuidString }
                    .map { id, connectorLabels in
                        CapabilityRuntimePermissionAttention(
                            connectorID: id,
                            requestDisplayName: displayName,
                            credentialCount: connectorLabels.count
                        )
                    }
            case .credential(let label):
                guard let connectorID = ConnectorRuntimeProjection.connectorID(fromCredentialLabel: label) else {
                    return []
                }
                return [CapabilityRuntimePermissionAttention(
                    connectorID: connectorID,
                    requestDisplayName: "Connector credentials",
                    credentialCount: 1
                )]
            default:
                return []
            }
        }
    }

    static func applying(
        _ attentions: [CapabilityRuntimePermissionAttention],
        to items: [RailCapabilityItem],
        connectors: [Connector]
    ) -> [RailCapabilityItem] {
        var result = items
        for attention in attentions {
            guard let connector = connectors.first(where: { $0.id == attention.connectorID }),
                  let targetIndex = targetIndex(for: connector, in: result) else {
                continue
            }
            result[targetIndex] = result[targetIndex].applyingRuntimePermissionAttention(
                attention,
                connectorName: connector.name
            )
        }
        return result
    }

    static func ownershipConnectors(
        workspaceConnectors: [Connector],
        availableGlobalConnectors: [Connector]
    ) -> [Connector] {
        var seen = Set<UUID>()
        return (workspaceConnectors + availableGlobalConnectors).filter {
            seen.insert($0.id).inserted
        }
    }

    func rowSubtitle(connectorName: String) -> String {
        let noun = credentialCount == 1 ? "credential" : "credentials"
        let trimmedConnectorName = connectorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = trimmedConnectorName.isEmpty ? requestDisplayName : trimmedConnectorName
        return "\(subject): permission to use \(credentialCount) configured \(noun) for this task"
    }

    private static func targetIndex(for connector: Connector, in items: [RailCapabilityItem]) -> Int? {
        let packageID = connector.originPackageID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let packageID, !packageID.isEmpty,
           let match = items.firstIndex(where: { item in
               guard case .package(let package) = item.source else { return false }
               return package.id.lowercased() == packageID
           }) {
            return match
        }

        let connectorName = connector.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !connectorName.isEmpty else { return nil }
        return items.firstIndex { item in
            item.connectorNames.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(connectorName) == .orderedSame
            }
        }
    }
}

private extension RailCapabilityItem {
    func applyingRuntimePermissionAttention(
        _ attention: CapabilityRuntimePermissionAttention,
        connectorName: String
    ) -> RailCapabilityItem {
        let permissionMessage = attention.rowSubtitle(connectorName: connectorName)
        let existingMessages = readiness.level == .ready ? [] : readiness.messages
        return RailCapabilityItem(
            id: id,
            name: name,
            icon: icon,
            summary: summary,
            color: color,
            isEnabled: isEnabled,
            readiness: CapabilityReadiness(
                level: .needsAttention,
                messages: [permissionMessage] + existingMessages
            ),
            presentation: CapabilityRailPackagePresentation(
                statusLabel: "Approval needed",
                actionTitle: presentation.actionTitle,
                rowSubtitle: permissionMessage,
                scopeValues: [permissionMessage] + presentation.scopeValues
            ),
            source: source,
            skillNames: skillNames,
            connectorNames: connectorNames,
            toolNames: toolNames,
            mcpServerNames: mcpServerNames,
            browserAdapterNames: browserAdapterNames,
            templateNames: templateNames,
            requirementNames: requirementNames,
            runtimePermissionAttention: attention
        )
    }
}

enum WorkspaceInstructionEditorPresentation {
    static let saveActionTitle = "Save"
    static let clearActionTitle = "Clear"
    static let savedStatusTitle = "Saved"
    static let unsavedStatusTitle = "Unsaved changes"
    static let includedInPromptHint = "Included in every new task prompt."

    static func persistedInstructions(fromDraft draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasUnsavedChanges(draft: String, persisted: String) -> Bool {
        persistedInstructions(fromDraft: draft) != persistedInstructions(fromDraft: persisted)
    }

    static func effectiveDraft(localDraft: String, persisted: String, isSynced: Bool) -> String {
        isSynced ? localDraft : persisted
    }

    static func hasUnsavedChanges(localDraft: String, persisted: String, isSynced: Bool) -> Bool {
        hasUnsavedChanges(
            draft: effectiveDraft(localDraft: localDraft, persisted: persisted, isSynced: isSynced),
            persisted: persisted
        )
    }

    static func shouldShowClearAction(localDraft: String, persisted: String, isSynced: Bool) -> Bool {
        !persistedInstructions(
            fromDraft: effectiveDraft(localDraft: localDraft, persisted: persisted, isSynced: isSynced)
        ).isEmpty
    }

    static func statusTitle(draft: String, persisted: String, didRecentlySave: Bool) -> String? {
        if hasUnsavedChanges(draft: draft, persisted: persisted) {
            return unsavedStatusTitle
        }

        if didRecentlySave || !persistedInstructions(fromDraft: persisted).isEmpty {
            return savedStatusTitle
        }

        return nil
    }

    static func statusTitle(
        localDraft: String,
        persisted: String,
        isSynced: Bool,
        didRecentlySave: Bool
    ) -> String? {
        statusTitle(
            draft: effectiveDraft(localDraft: localDraft, persisted: persisted, isSynced: isSynced),
            persisted: persisted,
            didRecentlySave: didRecentlySave
        )
    }
}

enum CapabilityRailLayout {
    static let compactContentPadding: CGFloat = 16
    static let regularContentPadding: CGFloat = 14
    static let compactPanelSpacing: CGFloat = 14
    static let regularPanelSpacing: CGFloat = 12
    static let compactSectionPadding: CGFloat = 18
    static let regularSectionPadding: CGFloat = 16
    static let compactSectionContentSpacing: CGFloat = 10
    static let regularSectionContentSpacing: CGFloat = 8
    static let compactGroupSpacing: CGFloat = 14
    static let regularGroupSpacing: CGFloat = 12
    static let sectionTitleFontSize: CGFloat = 13
    static let sectionActionFontSize: CGFloat = 13
    static let sectionActionSubtitleFontSize: CGFloat = 10
    static let groupHeadingFontSize: CGFloat = 12
    static let leadingIconFontSize: CGFloat = 16
    static let leadingIconFrame: CGFloat = 30
    static let leadingIconSpacing: CGFloat = 12
    static let rowTitleFontSize: CGFloat = 14
    static let rowSubtitleFontSize: CGFloat = 12
    static let rowActionFontSize: CGFloat = 12
    static let rowChevronFontSize: CGFloat = 11
    static let compactRowMinHeight: CGFloat = 60
    static let regularRowMinHeight: CGFloat = 56
    static let summaryRowMinHeight: CGFloat = 58
    static let setupRowMinHeight: CGFloat = 56
    static let usesNestedGroupChrome = false
    static let titleLineHeight: CGFloat = 18
    static let subtitleLineHeight: CGFloat = 15
    static let titleSubtitleSpacing: CGFloat = 3
    static let textVerticalBreathingRoom: CGFloat = 12

    static var minimumTwoLineRowHeight: CGFloat {
        titleLineHeight + subtitleLineHeight + titleSubtitleSpacing + textVerticalBreathingRoom
    }

    static func rowMinHeight(isCompact: Bool) -> CGFloat {
        isCompact ? compactRowMinHeight : regularRowMinHeight
    }

    static func groupHorizontalPadding(isCompact _: Bool) -> CGFloat {
        0
    }

    static func dividerLeadingPadding(isCompact _: Bool) -> CGFloat {
        leadingIconFrame
    }

    static func dividerTrailingPadding(isCompact _: Bool) -> CGFloat {
        0
    }
}

struct CapabilityRailPackagePresentation: Equatable {
    let statusLabel: String?
    let actionTitle: String
    let rowSubtitle: String
    let scopeValues: [String]

    static func make(
        isEnabled: Bool,
        readinessLevel: CapabilityReadinessLevel,
        workspaceName: String,
        sharedResourceCount: Int,
        workspaceResourceCount: Int,
        declaredResourceCount: Int,
        contentSummary: String
    ) -> CapabilityRailPackagePresentation {
        let statusLabel: String?
        if !isEnabled {
            statusLabel = "Available"
        } else {
            switch readinessLevel {
            case .ready:
                statusLabel = nil
            case .needsAttention:
                statusLabel = "Needs setup"
            case .inactive:
                statusLabel = "Disabled"
            }
        }

        let actionTitle = "Details"
        let workspaceLabel = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "this workspace"
            : workspaceName
        var scopeValues: [String] = [
            isEnabled ? "Enabled for \(workspaceLabel)" : "Available in the library; not active here"
        ]

        if sharedResourceCount > 0 {
            scopeValues.append(
                "Uses \(countPhrase(sharedResourceCount, singular: "shared resource", plural: "shared resources")) reusable in other workspaces"
            )
        }
        if workspaceResourceCount > 0 {
            scopeValues.append(
                "Uses \(countPhrase(workspaceResourceCount, singular: "workspace resource", plural: "workspace resources")) that can differ here"
            )
        }
        if sharedResourceCount == 0, workspaceResourceCount == 0, declaredResourceCount > 0 {
            scopeValues.append("Installing links the declared package resources to this workspace")
        }

        let trimmedSummary = contentSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let rowSubtitle: String
        if !trimmedSummary.isEmpty {
            rowSubtitle = trimmedSummary
        } else if declaredResourceCount > 0 {
            rowSubtitle = countPhrase(declaredResourceCount, singular: "declared resource", plural: "declared resources")
        } else {
            rowSubtitle = "Capability available to tasks"
        }

        return CapabilityRailPackagePresentation(
            statusLabel: statusLabel,
            actionTitle: actionTitle,
            rowSubtitle: rowSubtitle,
            scopeValues: scopeValues
        )
    }

    private static func countPhrase(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}
