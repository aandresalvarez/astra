import Foundation
import ASTRACore
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

/// A workspace whose saved setup can be copied into one package being
/// installed, carrying the already-computed inputs.
///
/// Same reason as `CopyableCapabilitySetup`: producing the inputs costs a
/// Keychain sweep, and the menu row and the copy action both need them.
struct CopyableCapabilityInstallSource: Identifiable {
    let id: UUID
    let name: String
    let inputs: OnboardingCapabilityInstallationInputs
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
    ///
    /// Connectors carry their `updatedAt` for the same reason workspaces do.
    /// Identity alone was not enough: the summary is derived from whether each
    /// connector's credentials are actually present in the Keychain, and
    /// filling in a missing token neither adds nor removes a row. The key would
    /// not move, the `.task` would not re-fire, and the sheet would keep
    /// offering a setup it had already decided was incomplete. Every credential
    /// write lands in `Connector.recordCredentialSaveResult`, which stamps
    /// `updatedAt`, so the timestamp is the cheap stored scalar that tracks it.
    ///
    /// `prefix` distinguishes callers that key on something else as well — the
    /// package being installed, say — so they do not need a second spelling of
    /// this logic to add it.
    static func key(prefix: String = "", sources: [Workspace], globalConnectors: [Connector]) -> String {
        let workspaces = sources.map { "\($0.id.uuidString)@\($0.updatedAt.timeIntervalSince1970)" }
        let connectors = globalConnectors.map { "\($0.id.uuidString)@\($0.updatedAt.timeIntervalSince1970)" }
        let parts = prefix.isEmpty ? workspaces + connectors : [prefix] + workspaces + connectors
        return parts.joined(separator: "|")
    }

    /// The install sheet's half: which workspaces have setup worth copying into
    /// *this* package.
    ///
    /// Same fault and same fix as `resolve`. In `PluginInstallSheet` this was a
    /// computed property evaluated three times per body pass — the section's
    /// `isEmpty` check, the summary line's `count`, and the menu's `ForEach` —
    /// each running `installationInputs` for every workspace, and `body` re-runs
    /// on every keystroke into the credential fields below it.
    @MainActor
    static func installSources(
        for package: PluginPackage,
        excluding excludedWorkspaceID: UUID,
        sources: [Workspace],
        globalConnectors: [Connector],
        copier: CapabilitySetupCopier = CapabilitySetupCopier()
    ) -> [CopyableCapabilityInstallSource] {
        // This sweep is the app's heaviest batch of credential reads, so it is
        // also where an unopenable keychain shows up first. Drain the pending
        // failure here as well as at startup: a keychain that breaks *while the
        // app is running* — a rebuilt binary, a relocked keychain, a declined
        // prompt — would otherwise never reach the log, which is the exact
        // blindness this reporting was added to remove.
        defer { AstraSecureKeychainStore.logPendingKeychainFailure(scope: "capability_install") }
        return sources.compactMap { sourceWorkspace in
            guard sourceWorkspace.id != excludedWorkspaceID else { return nil }
            let inputs = copier.installationInputs(
                for: package,
                from: sourceWorkspace,
                globalConnectors: globalConnectors
            )
            guard !inputs.credentialInputs.isEmpty
                    || !inputs.configInputs.isEmpty
                    || !inputs.baseURLOverrides.isEmpty else {
                return nil
            }
            return CopyableCapabilityInstallSource(
                id: sourceWorkspace.id,
                name: sourceWorkspace.name,
                inputs: inputs
            )
        }
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
