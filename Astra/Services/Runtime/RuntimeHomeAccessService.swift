import Foundation
import ASTRACore

/// Immutable launch facts cross the actor boundary; no task/model is retained
/// while potentially slow filesystem calls run off the main actor.
struct RuntimeHomeAccessRequest: Sendable {
    let runtime: AgentRuntimeID
    let policy: RuntimeHomeAccessPolicy
    var environment: [String: String]
    var workingDirectory: String
    var userHome: String
    var resumeSessionID: String? = nil
    var sandboxReceipt: ExecutionSandboxBoundaryReceipt? = nil
    var insideContainer = false
    var copilotHomeOverride: String? = nil
    var providersFileBlocks = true
}

enum RuntimeHomeAccessService {
    static let launchStopReason = "runtime_readiness_failed"

    static func checkID(for runtime: AgentRuntimeID) -> String {
        runtime == .copilotCLI ? CopilotHomeAccessCheck.readinessCheckID : "provider-home-access-\(runtime.rawValue)"
    }

    static func check(
        _ request: RuntimeHomeAccessRequest,
        inspector: @escaping @Sendable (RuntimeHomeAccessRequest) -> RuntimeReadinessCheck? = { RuntimeHomeAccessService.inspect($0) }
    ) async -> RuntimeReadinessCheck? {
        let work = Task.detached(priority: .utility) { inspector(request) }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    /// Synchronous core for deterministic filesystem tests. Production callers
    /// always use `check`, including readiness and post-failure diagnostics.
    static func inspect(_ request: RuntimeHomeAccessRequest) -> RuntimeReadinessCheck? {
        // Container launches run the same provider policy in the container,
        // with its real uid, home and mounts, immediately before exec.
        guard !request.insideContainer, !Task.isCancelled else { return nil }
        if request.runtime == .copilotCLI {
            let home = request.copilotHomeOverride ?? request.policy.roots.first?.path(
                environment: request.environment, userHome: request.userHome, workingDirectory: request.workingDirectory
            ) ?? (request.userHome as NSString).appendingPathComponent(".copilot")
            return CopilotHomeAccessCheck.readinessCheck(for: CopilotHomeAccessCheck.inspect(
                home: home, resumeSessionID: request.resumeSessionID, environment: request.environment,
                workingDirectory: request.workingDirectory, sandboxReceipt: request.sandboxReceipt
            ), providersFileBlocks: request.providersFileBlocks)
        }
        var problems: [String] = []
        for root in request.policy.roots {
            if Task.isCancelled { return nil }
            let path = root.path(environment: request.environment, userHome: request.userHome, workingDirectory: request.workingDirectory)
            if let issue = problem(path, directory: true, writable: root.writable, create: root.createIfMissing ?? root.writable, receipt: request.sandboxReceipt) {
                problems.append(issue)
                continue
            }
            for file in root.files {
                if let issue = problem((path as NSString).appendingPathComponent(file), directory: false, writable: false, receipt: request.sandboxReceipt) {
                    problems.append(issue)
                }
            }
            for directory in root.directories {
                if let issue = problem((path as NSString).appendingPathComponent(directory), directory: true, writable: root.writable, create: root.writable, receipt: request.sandboxReceipt) {
                    problems.append(issue)
                }
            }
        }
        var extraFiles = request.policy.homeFilePaths(
            environment: request.environment, userHome: request.userHome, workingDirectory: request.workingDirectory
        )
        for variable in request.policy.environmentFiles {
            guard let path = request.environment[variable], !path.isEmpty else { continue }
            let absolute = path.hasPrefix("/") ? path : (request.workingDirectory as NSString).appendingPathComponent(path)
            if !FileManager.default.fileExists(atPath: absolute) { problems.append("\(variable) names an inaccessible file: \(absolute)") }
            else { extraFiles.append(absolute) }
        }
        for file in extraFiles {
            if let issue = problem(file, directory: false, writable: false, receipt: request.sandboxReceipt) {
                problems.append(issue)
            }
        }
        guard !problems.isEmpty else { return nil }
        return RuntimeReadinessCheck(
            id: checkID(for: request.runtime), title: "\(request.runtime.displayName) settings and state",
            detail: "\(request.runtime.displayName) cannot use its settings or state: \(problems.prefix(5).joined(separator: "; ")).",
            state: .blocked,
            remediation: "Restore access to these paths for your user, or correct the provider's configured home. If the task sandbox denies a path, review its folder access and read-only inputs. Then retry."
        )
    }

    private static func problem(
        _ path: String, directory: Bool, writable: Bool, create: Bool = false,
        receipt: ExecutionSandboxBoundaryReceipt?
    ) -> String? {
        let display = (path as NSString).abbreviatingWithTildeInPath
        var info = stat()
        if stat(path, &info) != 0 {
            let error = errno
            var link = stat()
            if lstat(path, &link) == 0 { return "\(display) is a broken link" }
            guard error == ENOENT else { return "\(display) is inaccessible" }
            guard create else { return nil }
            var parent = (path as NSString).deletingLastPathComponent
            while parent != "/", stat(parent, &info) != 0 {
                guard errno == ENOENT else { return "\(display) has an inaccessible parent" }
                parent = (parent as NSString).deletingLastPathComponent
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR, access(parent, W_OK | X_OK) == 0,
                  !CopilotHomeAccessCheck.lockState(of: parent, followLinks: true).immutable else {
                return "\(display) cannot be created"
            }
        } else {
            let correctKind = directory ? (info.st_mode & S_IFMT) == S_IFDIR : (info.st_mode & S_IFMT) == S_IFREG
            guard correctKind else { return "\(display) has the wrong file type" }
            guard access(path, directory ? R_OK | X_OK : R_OK) == 0 else { return "\(display) is unreadable" }
            if writable, access(path, W_OK) != 0 || CopilotHomeAccessCheck.lockState(of: path, followLinks: true).any {
                return "\(display) is not writable"
            }
        }
        if let receipt {
            if receipt.explains(.init(operation: .read, path: path, detail: ""))
                || (writable && receipt.explains(.init(operation: .write, path: path, detail: ""))) {
                return "\(display) is denied by this task's sandbox"
            }
        }
        return nil
    }
}
