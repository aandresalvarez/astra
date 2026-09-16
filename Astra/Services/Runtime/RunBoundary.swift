import Foundation
import ASTRACore

/// The one derivation of a run's filesystem authority.
///
/// ASTRA scopes paths in two independent enforcement tiers: the OS sandbox
/// (`ExecutionSandbox`, Seatbelt) and the brokered stream guard
/// (`AgentRuntimePolicyGuard`). Those tiers are *inversely* activated — the
/// brokered guard is what remains when the sandbox is turned off — so any root
/// one tier grants and the other has never heard of becomes a boundary the
/// provider was never told about and is then punished for crossing.
///
/// That is not hypothetical: `AgentRuntimeHomeStateAccess` declares `~/.claude`
/// provider-owned state, `ExecutionSandbox.providerStateRoots` honours it, and
/// the brokered guard did not — so an Auto-mode run with the sandbox disabled
/// was terminated on its very first tool call for reading the provider's own
/// memory index.
///
/// `RunBoundary` exists so both tiers ask one value the same question. Adding a
/// root here reaches every tier at once; adding one to a single tier is the bug
/// this type is designed to make impossible.
struct RunBoundary: Equatable, Sendable {
    /// Roots the provider may read *and* write: the workspace anchor plus every
    /// additional runtime-writable path admitted for this run.
    let workspaceRoots: [String]

    /// Task inputs projected read-only (attachments, task inputs, approved
    /// sandbox reads). Readable, never writable — even when the same file also
    /// happens to live inside a writable workspace root.
    let readOnlyInputRoots: [String]

    /// The provider CLI's own private state under the run's HOME (`~/.claude`,
    /// `~/.codex`, `~/.cursor`, …).
    ///
    /// Provider state is not task data. It is the CLI's own memory, session,
    /// auth, and config bookkeeping — the provider wrote it, the provider owns
    /// it, and every tier that can see the filesystem at all already grants it
    /// (see `ExecutionSandbox.providerStateRoots`). Treating it as "outside the
    /// workspace" makes ASTRA punish a provider for using itself.
    let providerStateRoots: [String]

    /// `<workspace root>/.astra/tasks/<PREFIX8>` for each workspace root.
    /// Derived from `workspaceRoots` only: provider state and read-only inputs
    /// never host ASTRA task output.
    let taskOutputRoots: [String]

    private let workspacePath: String
    private let pathMapper: ExecutionEnvironmentPathMapper?

    init(
        manifest: RunPermissionManifest,
        pathMapper: ExecutionEnvironmentPathMapper? = nil,
        homeDirectories: [String] = [NSHomeDirectory()],
        homeStateAccess: AgentRuntimeHomeStateAccess? = nil
    ) {
        self.workspacePath = manifest.workspacePath
        self.pathMapper = pathMapper

        let workspaceRoots = ([manifest.workspacePath] + manifest.additionalPaths)
            .map(Self.standardizedAbsolutePath)
            .filter { !$0.isEmpty }
        self.workspaceRoots = Array(Set(workspaceRoots)).sorted()

        self.readOnlyInputRoots = Array(Set(
            manifest.additionalReadOnlyPaths
                .map(Self.standardizedAbsolutePath)
                .filter { !$0.isEmpty }
        )).sorted()

        let access = homeStateAccess ?? AgentRuntimeAdapterRegistry.homeStateAccess(for: manifest.providerID)
        self.providerStateRoots = Self.providerStateRoots(
            access: access,
            homeDirectories: homeDirectories
        )

        let taskFolderName = String(manifest.taskID.uuidString.prefix(8)).uppercased()
        self.taskOutputRoots = Array(Set(
            workspaceRoots
                .map { ($0 as NSString).appendingPathComponent(".astra/tasks/\(taskFolderName)") }
                .map(Self.standardizedAbsolutePath)
                .filter { !$0.isEmpty }
        )).sorted()
    }

    /// Derives the boundary from the same launch plan the OS-sandbox tier reads.
    ///
    /// Taking `sandboxHomeStateAccess` off the plan rather than re-looking it up
    /// by provider ID is the point: both tiers then consume one artifact, so a
    /// runtime cannot declare state to the sandbox and stay invisible here.
    /// Both homes are considered — a configured provider HOME does not stop the
    /// CLI's state under the real one from being provider-owned rather than
    /// task data.
    init(manifest: RunPermissionManifest, plan: AgentRuntimeProcessLaunchPlan) {
        self.init(
            manifest: manifest,
            pathMapper: plan.pathMapper,
            homeDirectories: [plan.environment["HOME"], NSHomeDirectory()].compactMap { $0 },
            homeStateAccess: plan.sandboxHomeStateAccess
        )
    }

    /// Every root the provider may read from.
    var readableRoots: [String] {
        Array(Set(workspaceRoots + readOnlyInputRoots + providerStateRoots)).sorted()
    }

    /// Every root the provider may write to.
    var writableRoots: [String] {
        Array(Set(workspaceRoots + providerStateRoots)).sorted()
    }

    func isReadable(_ rawPath: String) -> Bool {
        contains(rawPath, in: workspaceRoots)
            || contains(rawPath, in: readOnlyInputRoots)
            || contains(rawPath, in: providerStateRoots)
    }

    func isWritable(_ rawPath: String) -> Bool {
        contains(rawPath, in: workspaceRoots) || contains(rawPath, in: providerStateRoots)
    }

    /// True when `rawPath` falls under one of the run's explicitly read-only
    /// input paths — regardless of whether that same path also sits inside a
    /// writable root (e.g. an attached context file inside the workspace).
    /// Unlike `isReadable(_:) && !isWritable(_:)`, this stays true for
    /// read-only inputs nested inside a writable workspace, so the
    /// read-only-input mutation guard can't be bypassed just by attaching a file
    /// that already lives under the workspace root.
    func isReadOnlyInput(_ rawPath: String) -> Bool {
        contains(rawPath, in: readOnlyInputRoots)
    }

    /// True when `rawPath` is the provider CLI's own private state rather than
    /// task data. Callers use this to explain *why* an otherwise out-of-workspace
    /// path is allowed.
    func isProviderState(_ rawPath: String) -> Bool {
        contains(rawPath, in: providerStateRoots)
    }

    func isInTaskOutput(_ rawPath: String) -> Bool {
        taskOutputRelativePath(rawPath) != nil
    }

    func taskOutputRelativePath(_ rawPath: String) -> String? {
        let candidate = standardizedRunPath(rawPath)
        for root in taskOutputRoots {
            if candidate == root { return "" }
            let prefix = root + "/"
            if candidate.hasPrefix(prefix) {
                return String(candidate.dropFirst(prefix.count))
            }
        }
        return nil
    }

    /// Resolves a provider-reported path — container or host, absolute or
    /// workspace-relative — to the host path this boundary reasons about.
    func standardizedRunPath(_ rawPath: String) -> String {
        let rawPath = translatedPath(rawPath)
        if rawPath.hasPrefix("/") {
            return Self.standardizedAbsolutePath(rawPath)
        }
        return Self.standardizedAbsolutePath((workspacePath as NSString).appendingPathComponent(rawPath))
    }

    private func contains(_ rawPath: String, in roots: [String]) -> Bool {
        guard !roots.isEmpty else { return false }
        let candidate = standardizedRunPath(rawPath)
        return roots.contains { root in
            candidate == root || candidate.hasPrefix(root + "/")
        }
    }

    private func translatedPath(_ rawPath: String) -> String {
        guard rawPath.hasPrefix("/"),
              let hostPath = pathMapper?.hostPath(forContainerPath: rawPath) else {
            return rawPath
        }
        return hostPath
    }

    /// Mirrors `ExecutionSandbox.providerStateRoots`: the *inherited* relative
    /// paths are the ones that describe provider-owned state under a HOME ASTRA
    /// did not create. The `explicit` set additionally covers generic tool
    /// caches ASTRA provisions inside a managed HOME, which are not
    /// provider-identifying and must not widen an unsandboxed run's boundary.
    private static func providerStateRoots(
        access: AgentRuntimeHomeStateAccess,
        homeDirectories: [String]
    ) -> [String] {
        let relativePaths = access.inheritedHomeWritableRelativePaths
        guard !relativePaths.isEmpty else { return [] }

        var roots: Set<String> = []
        for home in homeDirectories {
            let trimmed = home.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "/" else { continue }
            let standardizedHome = standardizedAbsolutePath(trimmed)
            guard !standardizedHome.isEmpty, standardizedHome != "/" else { continue }
            for relative in relativePaths {
                let path = standardizedAbsolutePath(
                    (standardizedHome as NSString).appendingPathComponent(relative)
                )
                guard !path.isEmpty, path != "/", path != standardizedHome else { continue }
                roots.insert(path)
            }
        }
        return roots.sorted()
    }

    /// Resolves symlinks through the deepest existing ancestor so a path that
    /// does not exist yet still standardizes consistently with one that does.
    static func standardizedAbsolutePath(_ path: String) -> String {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        var existingAncestor = standardized
        var missingComponents: [String] = []
        let fileManager = FileManager.default

        while !fileManager.fileExists(atPath: existingAncestor.path),
              existingAncestor.path != "/" {
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor.deleteLastPathComponent()
        }

        var resolved = existingAncestor
            .resolvingSymlinksInPath()
            .standardizedFileURL
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }
}
