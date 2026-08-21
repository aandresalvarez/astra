import Foundation
import ASTRAModels
import ASTRAPersistence

/// A workspace whose capability setup is worth offering to copy, carrying the
/// summary that established that.
///
/// Keeping the summary is the whole point: producing one costs a Keychain
/// sweep, and the menu title and the copy action both need it. Holding the
/// derived values rather than the `Workspace` also keeps a SwiftData model out
/// of `@State`, so a row deleted behind the sheet cannot be read back through a
/// stale reference.
struct CopyableCapabilitySetup: Identifiable {
    let id: UUID
    let name: String
    let summary: CapabilitySetupCopySummary

    /// The menu row's title: the workspace name, plus what would come with it.
    var menuTitle: String {
        let names = OnboardingCapabilitySetup.selectedDisplayNames(from: summary.selectedPackageIDs)
        guard !names.isEmpty else { return name }
        return "\(name) - \(names.joined(separator: ", "))"
    }
}

/// Builds the "reuse setup from another workspace" list, and the cheap key that
/// says when it needs rebuilding.
///
/// This lives outside the view because of how expensive it is to get wrong.
/// `WorkspaceSetupForm` used to reach it through a computed property read three
/// times per body pass — once to decide whether to show the shortcut, once for
/// the menu's `ForEach`, once more per row for the title — and `body` re-runs on
/// every keystroke into the workspace name field. Each read is an unbounded
/// Keychain sweep: every workspace × every installable package's connectors ×
/// every credential hint × every key alias × every entity-ID namespace, each
/// leaf a synchronous securityd round trip. On a 16-workspace store that
/// measured in the thousands of round trips per body pass, which is what hung
/// the New Workspace sheet. Callers drive `resolve` from a `.task(id: key)`.
enum CopyableCapabilitySetupResolver {

    /// Describes when the copy-from list could have changed.
    ///
    /// Reads only stored scalars on objects the caller's `@Query`s have already
    /// materialized — deliberately no relationship traversal, because this is
    /// the part that *is* evaluated on every body pass.
    static func key(sources: [Workspace], globalConnectors: [Connector]) -> String {
        let workspaces = sources.map { "\($0.id.uuidString)@\($0.updatedAt.timeIntervalSince1970)" }
        return (workspaces + globalConnectors.map(\.id.uuidString)).joined(separator: "|")
    }

    /// Stays on the main actor: `copySetup` walks `Workspace.connectors` and the
    /// `Connector` rows behind it, and those are SwiftData models bound to the
    /// main context. The fix is not to move this work off the main thread but to
    /// stop doing it from `body`.
    @MainActor
    static func resolve(
        sources: [Workspace],
        globalConnectors: [Connector],
        copier: CapabilitySetupCopier = CapabilitySetupCopier()
    ) -> [CopyableCapabilitySetup] {
        defer { AstraSecureKeychainStore.logPendingKeychainFailure(scope: "workspace_setup") }
        return sources.compactMap { workspace in
            let summary = copier.copySetup(from: workspace, globalConnectors: globalConnectors)
            guard !summary.selectedPackageIDs.isEmpty, !summary.inputsByPackageID.isEmpty else {
                return nil
            }
            return CopyableCapabilitySetup(id: workspace.id, name: workspace.name, summary: summary)
        }
    }
}
