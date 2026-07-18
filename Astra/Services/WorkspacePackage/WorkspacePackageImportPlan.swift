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
    var packs: [WorkspacePackageImportPlanItem]
    var connectors: [WorkspacePackageImportPlanItem]
    var localTools: [WorkspacePackageImportPlanItem]
    var accounts: [WorkspacePackageImportPlanItem]
    var sshConnections: [WorkspacePackageImportPlanItem]
    var quarantinedScheduleCount: Int
    var droppedMachinePaths: [String]

    var canImport: Bool { blockers.isEmpty }

    var allItems: [WorkspacePackageImportPlanItem] {
        apps + capabilities + packs + connectors + localTools + accounts + sshConnections
    }
}

/// Classifies a validated package against the *recipient* machine's state.
/// Lookups are injected so tests can model any machine without touching the
/// real capability library.
struct WorkspacePackageImportPlanner {
    var installedCapabilityIDs: () -> Set<String> = {
        Set(CapabilityLibrary().installedPackages().map(\.id))
    }
    var approvedCapabilityIDs: () -> Set<String> = {
        // Effective approval, matching runtime exposure: a custom capability's
        // on-disk governance is normalized to `.draft`, so approval lives in a
        // digest-bound approval record — a raw `.approved` check would report
        // every locally-approved custom capability as unapproved.
        let records = CapabilityApprovalStore().records()
        return Set(CapabilityLibrary().installedPackages()
            .filter { WorkspacePackageCapabilityApproval.isEffectivelyApproved($0, records: records) }
            .map(\.id))
    }
    var availablePackIDs: () -> Set<String> = {
        Set(AstraPackCatalog().load().entries.map { $0.manifest.id })
    }

    func plan(from report: WorkspacePackageValidationReport) -> WorkspacePackageImportPlan? {
        guard let manifest = report.manifest, let document = report.shareDocument else { return nil }
        let installed = installedCapabilityIDs()
        let approved = approvedCapabilityIDs()

        let apps = manifest.appEntries.map { entry -> WorkspacePackageImportPlanItem in
            let appReport = report.appReports[entry.logicalID]
            let status: WorkspacePackageImportItemStatus
            let detail: String
            if let appReport, appReport.canInstall {
                // Derive permission and dependency warnings INDEPENDENTLY:
                // `installState` reports only one, so an app that both requests
                // elevated permissions and has an unresolved dependency would
                // otherwise hide its permission request behind the dependency
                // status. Surface both in the detail even though one badge shows.
                let elevatedPermission = (appReport.manifest?.permissions.defaultMode ?? .readOnly) != .readOnly
                let needsDependencyMapping = appReport.installState == .needsDependencyMapping
                var notes: [String] = []
                if elevatedPermission { notes.append("requests more than read-only permissions") }
                if needsDependencyMapping { notes.append("has app dependencies that need mapping on this machine") }
                if elevatedPermission {
                    status = .needsApproval
                } else if needsDependencyMapping {
                    status = .needsLocalSetup
                } else {
                    status = .ready
                }
                detail = notes.isEmpty
                    ? "Imports as a draft app with its manifest and template."
                    : "This app " + notes.joined(separator: ", and ") + "; review before enabling."
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
        // Installed capabilities keyed by their on-disk storage name: the library
        // writes each package to `safeFileName(for:)`, which is case-insensitive
        // and folds separators, so `local.tool` and `local-tool` collide. The
        // coordinator skips an embedded package whose storage name matches an
        // installed one, so the review must disclose that rather than promise a
        // draft install that cannot occur.
        // Match the coordinator's storage key EXACTLY (safeFileName + lowercased),
        // so a case-only difference like `Local.Tool` vs installed `local.tool`
        // — which the default case-insensitive macOS filesystem collides and the
        // coordinator skips — is reported here rather than promised as a draft.
        let storageKey: (String) -> String = { CapabilityLibrary.safeFileName(for: $0).lowercased() }
        let installedStorageNames = Set(installed.map(storageKey))
        for entry in manifest.capabilityEntries {
            let already = installed.contains(entry.packageID)
            let storageCollision = !already
                && installedStorageNames.contains(storageKey(entry.packageID))
            let requirements = report.capabilityRequirements[entry.packageID]
            let status: WorkspacePackageImportItemStatus
            let detail: String
            if already && approved.contains(entry.packageID) {
                status = .alreadyInstalled
                detail = "A capability with this ID is already in your library; the embedded copy is skipped."
            } else if already {
                // Installed here but NOT approved: the coordinator skips the
                // embedded copy AND strips the unapproved ID from the enabled
                // set, so the imported workspace won't have it. Disclose that.
                status = .needsApproval
                detail = "A capability with this ID exists locally but isn't approved; approve it, then enable it after import."
            } else if storageCollision {
                status = .incompatible
                detail = "Its storage name collides with a capability already on this machine; the embedded copy will be skipped."
            } else {
                // Build the detail from BOTH requirement arrays: a capability can
                // need an account AND a local CLI, and reporting only one would
                // let the recipient approve it only to find it still can't run.
                let accounts = requirements?.accountRequirements ?? []
                let cli = requirements?.cliPrerequisites ?? []
                var notes: [String] = []
                if !accounts.isEmpty { notes.append("sign in to: \(accounts.joined(separator: ", "))") }
                if !cli.isEmpty { notes.append("requires locally: \(cli.joined(separator: ", "))") }
                // Badge: authentication takes precedence over local setup.
                if !accounts.isEmpty {
                    status = .needsAuthentication
                } else if !cli.isEmpty {
                    status = .needsLocalSetup
                } else {
                    status = .needsApproval
                }
                detail = notes.isEmpty
                    ? "Installs as a local draft pending governance review."
                    : "Installs as a draft; " + notes.joined(separator: "; ") + "."
            }
            capabilities.append(WorkspacePackageImportPlanItem(
                id: "capability:\(entry.packageID)",
                name: entry.displayName,
                detail: detail,
                status: status
            ))
        }
        for capabilityID in document.capabilityIDs where !embeddedIDs.contains(capabilityID) {
            // Referenced but not embedded: built-in or remote-approved on the
            // exporting machine. Ready only if installed AND approved here — the
            // importer strips installed-but-unapproved IDs from the enabled set,
            // so classifying by installation alone would promise "Ready" for a
            // capability the imported workspace silently won't have.
            let status: WorkspacePackageImportItemStatus
            let detail: String
            if approved.contains(capabilityID) {
                status = .ready
                detail = "Referenced capability is available on this machine."
            } else if installed.contains(capabilityID) {
                status = .needsApproval
                detail = "Referenced capability is installed but not approved; approve it, then enable after import."
            } else {
                status = .missing
                detail = "Referenced capability is not installed on this machine; enable or install it after import."
            }
            capabilities.append(WorkspacePackageImportPlanItem(
                id: "capability:\(capabilityID)",
                name: capabilityID,
                detail: detail,
                status: status
            ))
        }

        // Packs are referenced by ID only. An enabled-but-unresolved pack makes
        // the workspace hide pack-addressable shelves and applies an unresolved
        // policy, so surface which referenced packs this machine lacks (the
        // importer only enables the ones it can resolve).
        let availablePacks = availablePackIDs()
        let packs = document.packIDs.map { packID -> WorkspacePackageImportPlanItem in
            let available = availablePacks.contains(packID)
            return WorkspacePackageImportPlanItem(
                id: "pack:\(packID)",
                name: packID,
                detail: available
                    ? "Referenced pack is available on this machine."
                    : "Referenced pack is not installed on this machine; it will not be enabled.",
                status: available ? .ready : .missing
            )
        }

        let connectors = document.connectors.map { connector -> WorkspacePackageImportPlanItem in
            if connector.credentialKeys.isEmpty {
                // A connector with no credentials but non-secret config keys
                // (values dropped from the share) is not runnable until those
                // settings are re-entered — surface it as local setup, not Ready.
                if !connector.configKeys.isEmpty {
                    return WorkspacePackageImportPlanItem(
                        id: "connector:\(connector.name)",
                        name: connector.name,
                        detail: "Configuration values never travel in a package. Re-enter: \(connector.configKeys.joined(separator: ", "))",
                        status: .needsLocalSetup
                    )
                }
                return WorkspacePackageImportPlanItem(
                    id: "connector:\(connector.name)",
                    name: connector.name,
                    detail: "No credentials required.",
                    status: .ready
                )
            }
            // Credential-bearing: also disclose any config keys (their values are
            // blanked too), so a connector needing an API token AND a tenant ID
            // isn't reported as needing only authentication.
            var detail = "Credential values never travel in a package. Provide: \(connector.credentialKeys.joined(separator: ", "))"
            if !connector.configKeys.isEmpty {
                detail += ". Also re-enter configuration: \(connector.configKeys.joined(separator: ", "))"
            }
            return WorkspacePackageImportPlanItem(
                id: "connector:\(connector.name)",
                name: connector.name,
                detail: detail,
                status: .needsAuthentication
            )
        }

        // Local tools add executable commands (e.g. `curl`, `gh`) that
        // `TaskCapabilityResolver.allLocalTools` exposes to tasks. Surface them —
        // with their command — in the review so the recipient sees the tooling a
        // package adds, not just a post-import count.
        let localTools = document.localTools.map { tool -> WorkspacePackageImportPlanItem in
            let invocation = [tool.command, tool.arguments]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return WorkspacePackageImportPlanItem(
                id: "localTool:\(tool.name)",
                name: tool.name,
                detail: invocation.isEmpty
                    ? "Adds a local tool to this workspace."
                    : "Adds a local tool that runs: \(invocation)",
                status: .ready
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

        // Every shared SSH connection is imported and injected into task prompts
        // (host/user/remotePath), so the review must list them ALL — not only the
        // ones the manifest flags as needing local keys/aliases. The manifest set
        // (and a nonempty configAlias) chooses the setup status; the rest import
        // ready but still appear so the recipient sees what remote hosts a package
        // adds.
        let sshRequiringSetup = Set(manifest.sshConnectionsRequiringLocalKeys)
        let sshConnections = document.sshConnections.map { ssh -> WorkspacePackageImportPlanItem in
            let label = ssh.name.isEmpty ? "\(ssh.user)@\(ssh.host):\(ssh.remotePath)" : ssh.name
            let needsSetup = sshRequiringSetup.contains(label) || !ssh.configAlias.isEmpty
            return WorkspacePackageImportPlanItem(
                id: "ssh:\(label)",
                name: label,
                detail: needsSetup
                    ? "Uses an SSH key path or config alias that must exist on this machine."
                    : "Adds an SSH connection to \(ssh.user)@\(ssh.host).",
                status: needsSetup ? .needsLocalSetup : .ready
            )
        }

        return WorkspacePackageImportPlan(
            workspaceName: manifest.workspaceName,
            packageID: manifest.packageID,
            exportProfile: manifest.exportProfile,
            blockers: report.blockers,
            apps: apps,
            capabilities: capabilities,
            packs: packs,
            connectors: connectors,
            localTools: localTools,
            accounts: accounts,
            sshConnections: sshConnections,
            // Every imported routine is quarantined until re-enabled.
            quarantinedScheduleCount: document.schedules.count,
            // Machine-local paths never travel in the share format.
            droppedMachinePaths: []
        )
    }
}
