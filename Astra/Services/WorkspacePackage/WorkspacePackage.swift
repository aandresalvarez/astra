import Foundation

/// How much of a workspace's state a `.astra-share` package carries.
///
/// `configurationOnly` is the only profile Phase 1 implements: every embedded
/// app is exported at `WorkspaceAppPackageExportMode.templateOnly` and no
/// task/run history travels at all. `configurationPlusHistory`/`complete` are
/// reserved names for later phases, not yet produced or accepted anywhere.
enum WorkspacePackageExportProfile: String, Codable, Sendable, CaseIterable {
    case configurationOnly
}

/// Severity/path/message shape shared by this format's own validation report.
/// Deliberately a fresh type rather than a modification to
/// `WorkspaceAppPackageValidationReport.Issue` (`WorkspaceAppPackageService.swift:137-146`,
/// same shape) — reusing the *shape* without touching that file's working,
/// separately-tested code.
struct PortablePackageValidationIssue: Sendable, Equatable {
    enum Severity: String, Sendable, Equatable {
        case blocker
        case warning
    }

    var severity: Severity
    var path: String
    var message: String
}

struct WorkspacePackageChecksum: Codable, Sendable, Equatable {
    var path: String
    var sha256: String
}

/// Top-level manifest for a `.astra-share` portable workspace package.
struct WorkspacePackageManifest: Codable, Sendable, Equatable {
    var packageID: String
    /// The source `Workspace.id` at export time. Reference/display only — an
    /// importer must mint a fresh `Workspace.id` on install, never reuse this
    /// directly, or two people importing the same shared package would
    /// collide on identity.
    var sourceWorkspaceID: String
    var workspaceName: String
    var packageVersion: String
    /// Actually enforced at validation time (unlike `.astra-app`'s own
    /// `minimumASTRAVersion`, which is stored and displayed but never
    /// compared against the running app version).
    var minimumASTRAVersion: String
    var exportProfile: WorkspacePackageExportProfile
    /// sha256 of `workspace-share.json`, cross-checked at validation time.
    var sourceShareDigest: String
    var createdAt: Date
    var author: String?
    var appEntries: [WorkspacePackageAppEntry]
    var capabilityEntries: [WorkspacePackageCapabilityEntry]

    // Domain-3 descriptive inventory: never embeds credentials or tokens,
    // only names what the recipient will need to resolve on their own
    // machine before the workspace is fully usable.
    var requiredConnectorServiceTypes: [String]
    var googleAccountsRequiringReauth: [String]
    var sshConnectionsRequiringLocalKeys: [String]
}

struct WorkspacePackageAppEntry: Codable, Sendable, Equatable {
    var logicalID: String
    var displayName: String
    var relativeBundlePath: String
    /// Cross-checked against the embedded `.astra-app` bundle's own
    /// `checksums.json`-derived package digest at validation time.
    var packageDigest: String
}

struct WorkspacePackageCapabilityEntry: Codable, Sendable, Equatable {
    var packageID: String
    var displayName: String
    var relativePath: String
    var sha256: String
}
