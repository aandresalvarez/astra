import Foundation
import ASTRACore
import ASTRAModels

enum TaskExecutionResourceScopeValidation {
    static func diagnostics(
        task: AgentTask,
        scope: TaskExecutionResourceScope,
        workspacePath: String,
        environment: WorkspaceExecutionEnvironment,
        grants: [RuntimePathGrant],
        mounts: [RuntimeContainerMountGrant]
    ) -> [RuntimeResourceDiagnostic] {
        var diagnostics: [RuntimeResourceDiagnostic] = []
        func reject(_ code: String, _ message: String) {
            diagnostics.append(.init(severity: .error, code: code, message: message,
                repairAction: "Submit a new turn to authorize the required folders and execution environment."))
        }
        if !scope.isValid || TaskExecutionResourceScope.canonicalPath(workspacePath) != TaskExecutionResourceScope.canonicalPath(scope.workingDirectory) {
            reject("execution_resource_scope_invalid", "The accepted execution root or a resource identity changed.")
        }
        var requestedEnvironment = environment
        var acceptedEnvironment = scope.executionEnvironment
        requestedEnvironment.mounts = []
        acceptedEnvironment.mounts = []
        if requestedEnvironment != acceptedEnvironment {
            reject("execution_resource_scope_expansion", "The launch execution environment differs from the accepted environment.")
        }
        let taskDataSources: Set<TaskLaunchResourceSource> = [
            .workspace, .taskInput, .userAttachment, .dockerEnvironment, .dockerCredential, .sandboxApproval
        ]
        for grant in grants {
            let taskData = taskDataSources.contains(grant.source)
            if (taskData && !scope.coversRead(to: grant.path))
                || ((taskData || grant.source == .gitCredential) && grant.access != .read && !scope.coversWrite(to: grant.path)) {
                reject("execution_resource_scope_expansion", "Launch requested unadmitted \(grant.access.rawValue) access to \(grant.path).")
            }
        }
        // Check the supplied mounts as well as the projected mounts: filtering
        // an unknown mount must not silently turn configuration drift into success.
        let acceptedMounts = scope.executionEnvironment.mounts
            + (scope.executionEnvironment.isContainerized ? DockerExecutionPlanner.mountPlan(
                currentDirectory: workspacePath, environment: scope.executionEnvironment,
                task: task, workspaceAccess: scope.executionAccess) : [])
        for mount in environment.mounts {
            if !scope.coversRead(to: mount.hostPath) || !acceptedMounts.contains(mount) {
                reject("execution_resource_scope_expansion", "Launch requested an unadmitted mount at \(mount.hostPath).")
            }
        }
        for mount in mounts {
            if !scope.coversRead(to: mount.hostPath)
                || (mount.access != "ro" && !scope.coversWrite(to: mount.hostPath)) {
                reject("execution_resource_scope_expansion", "Launch requested an unadmitted mount at \(mount.hostPath).")
            }
        }
        return diagnostics
    }
}
