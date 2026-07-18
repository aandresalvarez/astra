import Foundation
import ASTRAPersistence

enum WorkspacePackageImportItemStatus: String, Sendable, Equatable {
    case ready
    case alreadyInstalled
    case needsApproval
    case needsAuthentication
    case needsLocalSetup
    case missing
    case incompatible

    var displayLabel: String {
        switch self {
        case .ready: "Ready"
        case .alreadyInstalled: "Already installed"
        case .needsApproval: "Needs approval"
        case .needsAuthentication: "Needs authentication"
        case .needsLocalSetup: "Needs local setup"
        case .missing: "Missing"
        case .incompatible: "Incompatible"
        }
    }
}

struct WorkspacePackageImportPlanItem: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var detail: String
    var status: WorkspacePackageImportItemStatus
}

/// Read-only pre-import inventory: what the package contains, what can run
/// immediately on this machine, and what the recipient must install,
/// authenticate, or approve first. Pure data — building a plan never mutates
/// SwiftData, the capability library, or the filesystem.
struct WorkspacePackageImportPlan: Sendable, Equatable {
    var workspaceName: String
    var packageID: String
    var exportProfile: WorkspacePackageExportProfile
    var blockers: [PortablePackageValidationIssue]
    var apps: [WorkspacePackageImportPlanItem]
    var capabilities: [WorkspacePackageImportPlanItem]
    var connectors: [WorkspacePackageImportPlanItem]
    var accounts: [WorkspacePackageImportPlanItem]
    var sshConnections: [WorkspacePackageImportPlanItem]
    var quarantinedScheduleCount: Int
    var droppedMachinePaths: [String]

    var canImport: Bool { blockers.isEmpty }

    var allItems: [WorkspacePackageImportPlanItem] {
        apps + capabilities + connectors + accounts + sshConnections
    }
}

/// Classifies a validated package against the *recipient* machine's state.
/// Lookups are injected so tests can model any machine without touching the
/// real capability library.
struct WorkspacePackageImportPlanner {
    var installedCapabilityIDs: () -> Set<String> = {
        Set(CapabilityLibrary().installedPackages().map(\.id))
    }

    func plan(from report: WorkspacePackageValidationReport) -> WorkspacePackageImportPlan? {
        guard let manifest = report.manifest, let document = report.shareDocument else { return nil }
        let installed = installedCapabilityIDs()

        let apps = manifest.appEntries.map { entry -> WorkspacePackageImportPlanItem in
            let appReport = report.appReports[entry.logicalID]
            let status: WorkspacePackageImportItemStatus
            let detail: String
            if let appReport, appReport.canInstall {
                if appReport.installState == .needsPermissionReview {
                    status = .needsApproval
                    detail = "Requests more than read-only permissions; review before enabling."
                } else if appReport.installState == .needsDependencyMapping {
                    status = .needsLocalSetup
                    detail = "One or more app dependencies need mapping on this machine."
                } else {
                    status = .ready
                    detail = "Imports as a draft app with its manifest and template."
                }
            } else {
                status = .incompatible
                detail = appReport?.blockers.first?.message ?? "Embedded app package did not validate."
            }
            return WorkspacePackageImportPlanItem(
                id: "app:\(entry.logicalID)",
                name: entry.displayName,
                detail: detail,
                status: status
            )
        }

        var capabilities: [WorkspacePackageImportPlanItem] = []
        let embeddedIDs = Set(manifest.capabilityEntries.map(\.packageID))
        for entry in manifest.capabilityEntries {
            let already = installed.contains(entry.packageID)
            capabilities.append(WorkspacePackageImportPlanItem(
                id: "capability:\(entry.packageID)",
                name: entry.displayName,
                detail: already
                    ? "A capability with this ID is already in your library; the embedded copy is skipped."
                    : "Installs as a local draft pending governance review.",
                status: already ? .alreadyInstalled : .needsApproval
            ))
        }
        for capabilityID in document.capabilityIDs where !embeddedIDs.contains(capabilityID) {
            // Referenced but not embedded: built-in or remote-approved on the
            // exporting machine. Ready if this machine has it, missing if not.
            let available = installed.contains(capabilityID)
            capabilities.append(WorkspacePackageImportPlanItem(
                id: "capability:\(capabilityID)",
                name: capabilityID,
                detail: available
                    ? "Referenced capability is available on this machine."
                    : "Referenced capability is not installed on this machine; enable or install it after import.",
                status: available ? .ready : .missing
            ))
        }

        let connectors = document.connectors.map { connector -> WorkspacePackageImportPlanItem in
            if connector.credentialKeys.isEmpty {
                return WorkspacePackageImportPlanItem(
                    id: "connector:\(connector.name)",
                    name: connector.name,
                    detail: "No credentials required.",
                    status: .ready
                )
            }
            return WorkspacePackageImportPlanItem(
                id: "connector:\(connector.name)",
                name: connector.name,
                detail: "Credential values never travel in a package. Provide: \(connector.credentialKeys.joined(separator: ", "))",
                status: .needsAuthentication
            )
        }

        let accounts = manifest.googleAccountsRequiringReauth.map { email in
            WorkspacePackageImportPlanItem(
                id: "account:\(email)",
                name: email,
                detail: "Sign in to this Google account on this machine to restore access.",
                status: .needsAuthentication
            )
        }

        let sshConnections = manifest.sshConnectionsRequiringLocalKeys.map { label in
            WorkspacePackageImportPlanItem(
                id: "ssh:\(label)",
                name: label,
                detail: "Uses an SSH key path that must exist on this machine.",
                status: .needsLocalSetup
            )
        }

        return WorkspacePackageImportPlan(
            workspaceName: manifest.workspaceName,
            packageID: manifest.packageID,
            exportProfile: manifest.exportProfile,
            blockers: report.blockers,
            apps: apps,
            capabilities: capabilities,
            connectors: connectors,
            accounts: accounts,
            sshConnections: sshConnections,
            // Every imported routine is quarantined until re-enabled.
            quarantinedScheduleCount: document.schedules.count,
            // Machine-local paths never travel in the share format.
            droppedMachinePaths: []
        )
    }
}
