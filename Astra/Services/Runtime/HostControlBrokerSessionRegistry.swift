import Darwin
import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import HostControlToolSupport

protocol HostControlBrokerSessionManaging: AnyObject {
    func isAvailable() -> Bool

    @MainActor
    func prepare(
        task: AgentTask,
        runID: UUID?,
        capabilityScope: TaskCapabilityPromptScope,
        requiredTools: [String],
        currentDirectory: String
    ) -> Bool

    func registerProviderProcess(taskID: UUID, runID: UUID?, processID: Int32)
    func stop(taskID: UUID, runID: UUID?)
}

final class HostControlBrokerSessionManager: HostControlBrokerSessionManaging {
    private let expectedHelperPath: String

    init(expectedHelperPath: String = HostControlBrokerReadiness.helperPath) {
        self.expectedHelperPath = expectedHelperPath
    }

    func isAvailable() -> Bool {
        HostControlBrokerReadiness.isAvailable(expectedHelperPath: expectedHelperPath)
    }

    @MainActor
    func prepare(
        task: AgentTask,
        runID: UUID?,
        capabilityScope: TaskCapabilityPromptScope,
        requiredTools: [String],
        currentDirectory: String
    ) -> Bool {
        HostControlBrokerSessionRegistry.shared.prepare(
            task: task,
            runID: runID,
            capabilityScope: capabilityScope,
            requiredTools: requiredTools,
            currentDirectory: currentDirectory,
            expectedHelperPath: expectedHelperPath
        )
    }

    func registerProviderProcess(taskID: UUID, runID: UUID?, processID: Int32) {
        HostControlBrokerSessionRegistry.shared.registerProviderProcess(
            taskID: taskID,
            runID: runID,
            processID: processID
        )
    }

    func stop(taskID: UUID, runID: UUID?) {
        HostControlBrokerSessionRegistry.shared.stop(taskID: taskID, runID: runID)
    }
}

final class HostControlBrokerSessionRegistry: @unchecked Sendable {
    static let shared = HostControlBrokerSessionRegistry()

    private struct SessionKey: Hashable {
        let taskID: UUID
        let runID: String
    }

    private let lock = NSLock()
    private var sessions: [SessionKey: HostControlBrokerSession] = [:]

    private init() {}

    @MainActor
    @discardableResult
    func prepare(
        task: AgentTask,
        runID: UUID?,
        capabilityScope: TaskCapabilityPromptScope,
        requiredTools: [String],
        currentDirectory: String,
        expectedHelperPath: String = HostControlBrokerReadiness.helperPath
    ) -> Bool {
        guard !requiredTools.isEmpty else { return false }
        guard HostControlBrokerReadiness.isAvailable(
            expectedHelperPath: expectedHelperPath
        ) else {
            return false
        }

        let brokeredTools = Set(requiredTools.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let brokeredConnectors = capabilityScope.connectors.filter {
            HostControlPlaneMCPProjection.brokerOwnsConnectorConfiguration($0.serviceType)
                && HostControlPlaneMCPProjection.connectorToolName($0.serviceType)
                    .map(brokeredTools.contains) == true
        }
        let connectorEnvironment = ConnectorRuntimeProjection(
            connectors: brokeredConnectors,
            secretStore: KeychainSecretStore(),
            credentialExposurePolicy: .allowAllCredentials
        ).environmentVariables()
        let executionEnvironment = DockerExecutionPlanner.resolveEnvironment(for: task)
        let hostEnvironment = HostControlPlaneMCPProjection.environmentVariables(
            task: task,
            environment: executionEnvironment,
            currentDirectory: currentDirectory,
            runID: runID,
            capabilityScope: capabilityScope,
            precomputedRuntimeRequirements: TaskRuntimeRequirementSet(
                hostControlTools: requiredTools,
                requiresDockerWorkspaceShell: false,
                requiresBrowserControl: false
            )
        )
        var environment = ProcessInfo.processInfo.environment
        environment.merge(connectorEnvironment) { _, brokerValue in brokerValue }
        environment.merge(hostEnvironment) { _, brokerValue in brokerValue }

        let configuration = HostControlToolConfiguration.fromEnvironment(environment)
        let session = HostControlBrokerSession(
            configuration: configuration,
            expectedHelperPath: expectedHelperPath
        )
        guard let socketPath = session.start() else { return false }

        let key = sessionKey(taskID: task.id, runID: runID)
        lock.lock()
        let previous = sessions.updateValue(session, forKey: key)
        lock.unlock()
        previous?.invalidate()
        session.socketPath = socketPath
        return true
    }

    func endpoint(taskID: UUID, runID: UUID?) -> String? {
        let key = sessionKey(taskID: taskID, runID: runID)
        lock.lock()
        defer { lock.unlock() }
        return sessions[key]?.socketPath
    }

    func registerProviderProcess(taskID: UUID, runID: UUID?, processID: Int32) {
        let key = sessionKey(taskID: taskID, runID: runID)
        lock.lock()
        let session = sessions[key]
        lock.unlock()
        session?.registerProviderProcess(processID)
    }

    func stop(taskID: UUID, runID: UUID?) {
        let key = sessionKey(taskID: taskID, runID: runID)
        lock.lock()
        let session = sessions.removeValue(forKey: key)
        lock.unlock()
        session?.invalidate()
    }

    private func sessionKey(taskID: UUID, runID: UUID?) -> SessionKey {
        SessionKey(taskID: taskID, runID: runID?.uuidString ?? "run")
    }
}

private final class HostControlBrokerSession: @unchecked Sendable {
    private static let maximumRequestBytes = 1_048_576

    private let server: HostControlMCPServer
    private let expectedHelperPath: String
    private let processCondition = NSCondition()
    private let serverLock = NSLock()
    private let connectionLock = NSLock()
    private let listenerQueue = DispatchQueue(label: "com.coral.astra.host-control-broker.listener")
    private let connectionQueue = DispatchQueue(
        label: "com.coral.astra.host-control-broker.connections",
        attributes: .concurrent
    )
    private var providerProcessID: Int32?
    private var listenerDescriptor: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var connectionDescriptors: Set<Int32> = []
    private var invalidated = false
    fileprivate var socketPath: String?

    init(configuration: HostControlToolConfiguration, expectedHelperPath: String) {
        server = HostControlMCPServer(configuration: configuration)
        self.expectedHelperPath = Self.canonicalPath(expectedHelperPath)
    }

    func start() -> String? {
        let candidatePath = "/tmp/astra-host-control-\(UUID().uuidString.lowercased()).sock"
        guard let path = try? HostControlBrokerIPC.validatedSocketPath(candidatePath) else {
            return nil
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        guard Self.bindListener(descriptor: descriptor, path: path) else {
            Darwin.close(descriptor)
            return nil
        }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0,
              Darwin.listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            unlink(path)
            return nil
        }

        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let currentFlags = fcntl(descriptor, F_GETFL)
        if currentFlags >= 0 {
            _ = fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK)
        }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: listenerQueue
        )
        connectionLock.lock()
        listenerDescriptor = descriptor
        listenerSource = source
        socketPath = path
        connectionLock.unlock()
        source.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        source.resume()
        return path
    }

    func registerProviderProcess(_ processID: Int32) {
        processCondition.lock()
        providerProcessID = processID
        processCondition.broadcast()
        processCondition.unlock()
    }

    func invalidate() {
        processCondition.lock()
        processCondition.broadcast()
        processCondition.unlock()

        connectionLock.lock()
        guard !invalidated else {
            connectionLock.unlock()
            return
        }
        invalidated = true
        server.cancelActiveOperations()
        let source = listenerSource
        let descriptor = listenerDescriptor
        let path = socketPath
        listenerSource = nil
        listenerDescriptor = -1
        for connection in connectionDescriptors {
            Darwin.shutdown(connection, SHUT_RDWR)
        }
        connectionLock.unlock()

        source?.cancel()
        if source != nil {
            listenerQueue.sync {}
        }
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
        if let path {
            unlink(path)
        }
    }

    private func acceptConnections() {
        connectionLock.lock()
        let descriptor = listenerDescriptor
        let isInvalidated = invalidated
        connectionLock.unlock()
        guard descriptor >= 0, !isInvalidated else { return }

        while true {
            let connection = Darwin.accept(descriptor, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR {
                    continue
                }
                return
            }
            _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
            let connectionFlags = fcntl(connection, F_GETFL)
            if connectionFlags >= 0 {
                _ = fcntl(connection, F_SETFL, connectionFlags & ~O_NONBLOCK)
            }
            var noSigPipe: Int32 = 1
            _ = setsockopt(
                connection,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            )

            connectionLock.lock()
            if invalidated {
                connectionLock.unlock()
                Darwin.close(connection)
                return
            }
            connectionDescriptors.insert(connection)
            connectionLock.unlock()
            connectionQueue.async { [weak self] in
                guard let self else {
                    Darwin.close(connection)
                    return
                }
                self.serveConnection(connection)
            }
        }
    }

    private func serveConnection(_ descriptor: Int32) {
        defer {
            connectionLock.lock()
            connectionDescriptors.remove(descriptor)
            connectionLock.unlock()
            Darwin.close(descriptor)
        }

        guard let helperProcessID = Self.peerProcessID(descriptor: descriptor),
              Self.canonicalExecutablePath(processID: helperProcessID) == expectedHelperPath,
              helperBelongsToProvider(helperProcessID) else {
            return
        }

        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = chunk.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count == 0 {
                return
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }
            pending.append(contentsOf: chunk.prefix(count))
            guard pending.count <= Self.maximumRequestBytes else {
                _ = Self.writeLine(
                    Self.errorResponse(
                        requestLine: "",
                        message: "ASTRA host-control broker request exceeded its size limit."
                    ),
                    to: descriptor
                )
                return
            }

            while let newlineIndex = pending.firstIndex(of: 0x0A) {
                var line = String(decoding: pending[..<newlineIndex], as: UTF8.self)
                pending.removeSubrange(...newlineIndex)
                if line.last == "\r" {
                    line.removeLast()
                }
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }

                serverLock.lock()
                let response = server.handleLine(line) ?? ""
                serverLock.unlock()
                guard Self.writeLine(response, to: descriptor) else {
                    return
                }
            }
        }
    }

    private func helperBelongsToProvider(_ helperProcessID: Int32) -> Bool {
        processCondition.lock()
        if providerProcessID == nil {
            _ = processCondition.wait(until: Date().addingTimeInterval(2))
        }
        let providerProcessID = providerProcessID
        processCondition.unlock()
        guard let providerProcessID else { return false }

        var current = helperProcessID
        for _ in 0..<8 {
            guard let parent = Self.parentProcessID(of: current), parent > 1 else {
                return false
            }
            if parent == providerProcessID {
                return true
            }
            current = parent
        }
        return false
    }

    private static func bindListener(descriptor: Int32, path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                ) == 0
            }
        }
    }

    private static func peerProcessID(descriptor: Int32) -> Int32? {
        var processID: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &processID,
            &size
        )
        return result == 0 && processID > 1 ? Int32(processID) : nil
    }

    private static func writeLine(_ line: String, to descriptor: Int32) -> Bool {
        let data = Data((line + "\n").utf8)
        return data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return false
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private static func canonicalExecutablePath(processID: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return canonicalPath(String(cString: buffer))
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func parentProcessID(of processID: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return Int32(info.pbi_ppid)
    }

    private static func errorResponse(requestLine: String, message: String) -> String {
        let requestID: Any = {
            guard let data = requestLine.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return NSNull()
            }
            return request["id"] ?? NSNull()
        }()
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "error": [
                "code": -32000,
                "message": message
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let line = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"ASTRA host-control broker rejected the request."}}"#
        }
        return line
    }
}
