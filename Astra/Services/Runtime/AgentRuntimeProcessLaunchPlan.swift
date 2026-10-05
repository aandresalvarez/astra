import Foundation
import ASTRACore
import ASTRAModels

struct AgentRuntimeProcessLaunchPlan: Equatable {
    var preparationError: String?
    let runtime: AgentRuntimeID
    let executablePath: String
    let arguments: [String]
    let currentDirectory: String
    let environment: [String: String]
    let browserShimDirectory: String?
    let providerVersion: String?
    let parsesJSONLines: Bool
    let directoriesToCreate: [String]
    let sandboxReadablePaths: [String]
    let sandboxHomeStateAccess: AgentRuntimeHomeStateAccess
    /// Files carved back out of a writable root as read-only (write-deny over
    /// write-allow). See `CopilotCLIRuntime.configWriteDenyPaths`.
    let sandboxProtectedWriteDenyPaths: [String]
    let providerDetectedFields: [String: String]
    let commandPlannedFields: [String: String]
    var interactiveAsk: AgentRuntimeInteractiveAskPlan?
    var pathMapper: ExecutionEnvironmentPathMapper?
    var executionEnvironment: WorkspaceExecutionEnvironment
    /// Set only by `AgentRuntimeProcessRunner` after every required read-only
    /// enforcement surface has been applied and verified.
    var readOnlyBoundaryReceipt: ReadOnlyResourceBoundaryReceipt?
    /// Evidence from the exact Seatbelt profile applied to this launch. The
    /// monitor uses it to distinguish a policy-denied path from an unrelated
    /// host filesystem EPERM.
    var executionSandboxBoundaryReceipt: ExecutionSandboxBoundaryReceipt?

    init(
        runtime: AgentRuntimeID,
        executablePath: String,
        arguments: [String],
        currentDirectory: String,
        environment: [String: String],
        browserShimDirectory: String?,
        providerVersion: String?,
        parsesJSONLines: Bool,
        directoriesToCreate: [String] = [],
        sandboxReadablePaths: [String] = [],
        sandboxHomeStateAccess: AgentRuntimeHomeStateAccess? = nil,
        sandboxProtectedWriteDenyPaths: [String] = [],
        providerDetectedFields: [String: String] = [:],
        commandPlannedFields: [String: String] = [:],
        interactiveAsk: AgentRuntimeInteractiveAskPlan? = nil,
        pathMapper: ExecutionEnvironmentPathMapper? = nil,
        executionEnvironment: WorkspaceExecutionEnvironment = .host,
        preparationError: String? = nil
    ) {
        self.runtime = runtime
        self.preparationError = preparationError
        self.executablePath = executablePath
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.browserShimDirectory = browserShimDirectory
        self.providerVersion = providerVersion
        self.parsesJSONLines = parsesJSONLines
        self.directoriesToCreate = directoriesToCreate
        self.sandboxReadablePaths = sandboxReadablePaths
        self.sandboxHomeStateAccess = sandboxHomeStateAccess ?? AgentRuntimeAdapterRegistry.homeStateAccess(for: runtime)
        self.sandboxProtectedWriteDenyPaths = sandboxProtectedWriteDenyPaths
        self.providerDetectedFields = providerDetectedFields
        self.commandPlannedFields = commandPlannedFields
        self.interactiveAsk = interactiveAsk
        self.pathMapper = pathMapper
        self.executionEnvironment = executionEnvironment
        self.readOnlyBoundaryReceipt = nil
        self.executionSandboxBoundaryReceipt = nil
    }
}
