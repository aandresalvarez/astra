import Foundation
import ASTRACore
import ASTRAModels

/// Everything `updateDerivedFields` asks the filesystem about a task's
/// outputs, answered in one pass that needs no model state.
///
/// The derive used to ask these questions on the main actor, one syscall
/// chain at a time: the output-folder scan (about eight symlink resolutions
/// per entry through the access broker), then a symlink-resolving visibility
/// check per recorded file change, discovered file and remembered path — three
/// times over for each change — and an existence check per artifact. On
/// E0F780F8 (104 output files, 111 artifacts) that was half of every apply, and
/// the half that grows with the folder: `context_state_refresh_breakdown` put
/// apply at p50 250 ms and 2.2 s while a run was writing files.
///
/// `refreshLoadingOffMainActor` builds one of these in its off-actor hop and
/// hands it to the apply, which then answers from memory. Every other caller
/// passes nothing and gets today's behaviour, answered live on the actor.
public struct TaskOutputObservation: Sendable {
    /// The roots this was observed under. The apply ignores the observation
    /// unless they still match the task's, so a repointed workspace or a moved
    /// task folder can only cost a live answer, never a wrong one.
    public let taskFolder: String
    public let workspacePath: String
    public let discoveredFiles: [TaskOutputDiscoveredFile]
    fileprivate let normalizedPaths: [String: String]
    fileprivate let userFacingPaths: [String: Bool]
    fileprivate let existingPaths: [String: Bool]

    /// Scans the task folder and settles every question the derive will ask
    /// about `paths` and about what the scan found.
    ///
    /// The paths are the model's — recorded file changes and artifacts —
    /// gathered on the actor before the hop, plus the state file's remembered
    /// ones. A path recorded after they were gathered is simply not here, and
    /// the resolver answers it live: a handful of lookups, not a scan.
    ///
    /// Nil once the calling task is cancelled, checked per entry of the walk
    /// and per path: a superseded refresh must not finish its scan while the
    /// one replacing it starts its own.
    public nonisolated static func observe(
        taskFolder: String,
        workspacePath: String,
        paths: [String]
    ) -> TaskOutputObservation? {
        guard let discovered = TaskOutputDiscovery.files(
            in: taskFolder,
            isCancelled: { Task.isCancelled }
        ) else { return nil }
        let scope = TaskOutputVisibilityScope(taskFolder: taskFolder, workspacePath: workspacePath)
        var normalizedPaths: [String: String] = [:]
        var userFacingPaths: [String: Bool] = [:]
        var existingPaths: [String: Bool] = [:]
        for path in paths + discovered.map(\.path) where normalizedPaths[path] == nil {
            guard !Task.isCancelled else { return nil }
            let normalized = TaskArtifactPathNormalizer.normalizedPath(
                path,
                workspacePath: workspacePath,
                taskFolder: taskFolder
            )
            normalizedPaths[path] = normalized
            guard userFacingPaths[normalized] == nil else { continue }
            userFacingPaths[normalized] = TaskContextStateManager.isUserFacingNormalizedOutputPath(
                normalized,
                scope: scope
            )
            existingPaths[normalized] = FileManager.default.fileExists(atPath: normalized)
        }
        return TaskOutputObservation(
            taskFolder: taskFolder,
            workspacePath: workspacePath,
            discoveredFiles: discovered,
            normalizedPaths: normalizedPaths,
            userFacingPaths: userFacingPaths,
            existingPaths: existingPaths
        )
    }

    /// The model paths an observation should cover: every recorded file
    /// change and every artifact. In-memory reads only — the same ones the
    /// apply makes right after, so they arrive already faulted. They traverse
    /// relationships, so only for a task that is still live.
    @MainActor
    public static func candidatePaths(for task: AgentTask) -> [String] {
        task.runs.flatMap(\.fileChanges).map(\.path) + task.artifacts.map(\.path)
    }
}

/// The derive's one doorway to output-path facts: answers from an observation
/// when it has one for these roots, and live otherwise, memoizing either way
/// for the length of one derive pass.
///
/// Live is the synchronous paths' answer — `refresh(task:)` and `recordTurn`,
/// which callers rely on to have seen the folder as of their own write — and
/// the off-actor path's answer for anything its observation did not cover.
/// One scope for the pass: resolving the two roots per path is what once
/// turned a large task folder into an unrecoverable main-thread spin.
@MainActor
final class TaskOutputPathResolver {
    private let workspacePath: String
    private let taskFolder: String
    private let scope: TaskOutputVisibilityScope
    private let observation: TaskOutputObservation?
    private var normalizedPaths: [String: String] = [:]
    private var userFacingPaths: [String: Bool] = [:]
    private var existingPaths: [String: Bool] = [:]

    init(task: AgentTask, observation: TaskOutputObservation?) {
        let access = TaskWorkspaceAccess(task: task)
        let workspacePath = access.effectiveWorkspacePath
        let taskFolder = access.taskFolder
        self.workspacePath = workspacePath
        self.taskFolder = taskFolder
        scope = TaskOutputVisibilityScope(taskFolder: taskFolder, workspacePath: workspacePath)
        self.observation = observation.flatMap {
            $0.taskFolder == taskFolder && $0.workspacePath == workspacePath ? $0 : nil
        }
    }

    private(set) lazy var discoveredFiles: [TaskOutputDiscoveredFile] = {
        if let observation { return observation.discoveredFiles }
        #if DEBUG
        Self.liveScanCountForTesting += 1
        #endif
        return TaskOutputDiscovery.files(in: taskFolder)
    }()

    func normalizedPath(_ path: String) -> String {
        if let known = normalizedPaths[path] ?? observation?.normalizedPaths[path] { return known }
        #if DEBUG
        Self.liveLookupCountForTesting += 1
        #endif
        let normalized = TaskArtifactPathNormalizer.normalizedPath(
            path,
            workspacePath: workspacePath,
            taskFolder: taskFolder
        )
        normalizedPaths[path] = normalized
        return normalized
    }

    func isUserFacing(_ path: String) -> Bool {
        isUserFacingNormalized(normalizedPath(path))
    }

    func isUserFacingNormalized(_ path: String) -> Bool {
        if let known = userFacingPaths[path] ?? observation?.userFacingPaths[path] { return known }
        #if DEBUG
        Self.liveLookupCountForTesting += 1
        #endif
        let userFacing = TaskContextStateManager.isUserFacingNormalizedOutputPath(path, scope: scope)
        userFacingPaths[path] = userFacing
        return userFacing
    }

    func fileExists(normalizedPath path: String) -> Bool {
        if let known = existingPaths[path] ?? observation?.existingPaths[path] { return known }
        #if DEBUG
        Self.liveLookupCountForTesting += 1
        #endif
        let exists = FileManager.default.fileExists(atPath: path)
        existingPaths[path] = exists
        return exists
    }

    #if DEBUG
    /// Output-folder scans, and path normalizations, visibility checks and
    /// existence checks, that the derive answered live on the actor. The
    /// off-actor refresh exists to keep both at zero.
    static var liveScanCountForTesting = 0
    static var liveLookupCountForTesting = 0
    #endif
}
