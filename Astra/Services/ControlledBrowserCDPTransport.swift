import Foundation

enum ControlledBrowserCDPTransport {
    static func sendWebSocketMessage(
        _ message: URLSessionWebSocketTask.Message,
        on task: URLSessionWebSocketTask,
        timeout: TimeInterval,
        operationName: String
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let box = CallbackBox<Void>()
            let timeoutItem = DispatchWorkItem {
                task.cancel(with: .goingAway, reason: nil)
                box.finish(.failure(ControlledBrowserError.timedOut(operationName)), continuation: continuation)
            }
            box.timeoutItem = timeoutItem
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            task.send(message) { error in
                if let error {
                    box.finish(.failure(error), continuation: continuation)
                } else {
                    box.finish(.success(()), continuation: continuation)
                }
            }
        }
    }

    static func receiveWebSocketMessage(
        from task: URLSessionWebSocketTask,
        timeout: TimeInterval,
        operationName: String
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let box = CallbackBox<URLSessionWebSocketTask.Message>()
            let timeoutItem = DispatchWorkItem {
                task.cancel(with: .goingAway, reason: nil)
                box.finish(.failure(ControlledBrowserError.timedOut(operationName)), continuation: continuation)
            }
            box.timeoutItem = timeoutItem
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            task.receive { result in
                box.finish(result, continuation: continuation)
            }
        }
    }

    static func responseID(from object: [String: Any]) -> Int? {
        if let id = object["id"] as? Int {
            return id
        }
        if let id = object["id"] as? NSNumber {
            return id.intValue
        }
        if let id = object["id"] as? String {
            return Int(id)
        }
        return nil
    }

    static func stringValue(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return ""
    }

    private final class CallbackBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var didFinish = false
        var timeoutItem: DispatchWorkItem?

        func finish(_ result: Result<T, Error>, continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return
            }
            didFinish = true
            let item = timeoutItem
            timeoutItem = nil
            lock.unlock()

            item?.cancel()
            continuation.resume(with: result)
        }
    }
}

final class PersistentCDPDiagnosticsClient: @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let queue = DispatchQueue(label: "com.coral.astra.controlled-browser.cdp-diagnostics")
    private var nextID = 1
    private var responses: [Int: [String: Any]] = [:]
    private var events: [[String: Any]] = []
    private var receiveTask: Task<Void, Never>?
    private var isClosed = false
    private var capabilities = ControlledBrowserCDPCapabilityReport(
        browser: "",
        protocolVersion: "",
        domains: [:],
        errors: [:]
    )

    init(webSocketURL: URL) {
        configuration = .ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 0
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: webSocketURL)
    }

    func connect() async throws {
        task.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func close() {
        queue.sync {
            isClosed = true
        }
        receiveTask?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    func probeAndEnable(version: DevToolsVersion) async throws {
        var domains = try await schemaDomains()
        var errors: [String: String] = [:]
        let activeProbes: [(domain: String, method: String)] = [
            ("Runtime", "Runtime.enable"),
            ("Log", "Log.enable"),
            ("Network", "Network.enable"),
            ("Page", "Page.enable"),
            ("DOM", "DOM.enable")
        ]

        for probe in activeProbes {
            do {
                _ = try await send(method: probe.method)
                domains[probe.domain] = true
            } catch {
                domains[probe.domain] = false
                errors[probe.domain] = error.localizedDescription
            }
        }

        if domains["Accessibility"] == true {
            do {
                _ = try await send(method: "Accessibility.getFullAXTree", params: ["interestingOnly": true])
            } catch {
                domains["Accessibility"] = false
                errors["Accessibility"] = error.localizedDescription
            }
        }

        queue.sync {
            capabilities = ControlledBrowserCDPCapabilityReport(
                browser: version.browser,
                protocolVersion: version.protocolVersion,
                domains: domains,
                errors: errors
            )
        }
    }

    func snapshot(url: String, title: String) -> [String: Any] {
        let state = queue.sync {
            (events, capabilities)
        }
        return ControlledBrowserCDPDiagnosticsFormatter.diagnosticsObject(
            url: url,
            title: title,
            events: state.0,
            capabilities: state.1
        )
    }

    private func schemaDomains() async throws -> [String: Bool] {
        do {
            let response = try await send(method: "Schema.getDomains")
            let rawDomains = ((response["result"] as? [String: Any])?["domains"] as? [[String: Any]]) ?? []
            var domains: [String: Bool] = [:]
            for domain in rawDomains {
                let name = ControlledBrowserCDPTransport.stringValue(domain["name"])
                if !name.isEmpty {
                    domains[name] = true
                }
            }
            return domains
        } catch {
            return [
                "Runtime": false,
                "Log": false,
                "Network": false,
                "Page": false,
                "DOM": false,
                "Accessibility": false,
                "Input": false
            ]
        }
    }

    private func send(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let id = queue.sync {
            let value = nextID
            nextID += 1
            return value
        }

        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }
        try await ControlledBrowserCDPTransport.sendWebSocketMessage(
            .string(json),
            on: task,
            timeout: 4,
            operationName: "sending a browser diagnostics command"
        )

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let response = queue.sync {
                responses.removeValue(forKey: id)
            }
            if let response {
                if let error = response["error"] as? [String: Any] {
                    throw ControlledBrowserError.commandFailed(String(describing: error))
                }
                return response
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ControlledBrowserError.timedOut("waiting for a browser diagnostics command response")
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            let closed = queue.sync { isClosed }
            if closed { return }

            do {
                let message = try await receiveWebSocketMessage()
                let messageData: Data
                switch message {
                case .data(let data):
                    messageData = data
                case .string(let text):
                    messageData = Data(text.utf8)
                @unknown default:
                    continue
                }
                guard let object = try JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                    continue
                }
                record(object)
            } catch {
                return
            }
        }
    }

    private func record(_ object: [String: Any]) {
        queue.sync {
            if let id = ControlledBrowserCDPTransport.responseID(from: object) {
                responses[id] = object
                return
            }
            events.append(object)
            if events.count > 240 {
                events.removeFirst(events.count - 240)
            }
        }
    }

    private func receiveWebSocketMessage() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            task.receive { result in
                continuation.resume(with: result)
            }
        }
    }
}

// Operation-scoped and serial-only. Callers must not invoke send concurrently;
// nextID and the event buffer intentionally avoid locking for this short-lived read path.
final class OperationCDPClient: @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var nextID = 1
    private(set) var events: [[String: Any]] = []

    init(webSocketURL: URL) {
        configuration = .ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: webSocketURL)
    }

    func connect() async throws {
        task.resume()
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    func drainEvents() -> [[String: Any]] {
        let drained = events
        events.removeAll()
        return drained
    }

    func send(
        method: String,
        params: [String: Any] = [:],
        sessionID: String? = nil
    ) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        var payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params
        ]
        if let sessionID, !sessionID.isEmpty {
            payload["sessionId"] = sessionID
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }

        try await ControlledBrowserCDPTransport.sendWebSocketMessage(
            .string(json),
            on: task,
            timeout: 4,
            operationName: "sending a browser command"
        )

        let deadline = Date().addingTimeInterval(10)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw ControlledBrowserError.timedOut("waiting for a browser command response")
            }
            let message = try await ControlledBrowserCDPTransport.receiveWebSocketMessage(
                from: task,
                timeout: remaining,
                operationName: "waiting for a browser command response"
            )
            let messageData: Data
            switch message {
            case .data(let data):
                messageData = data
            case .string(let text):
                messageData = Data(text.utf8)
            @unknown default:
                continue
            }
            guard let object = try JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                continue
            }
            if ControlledBrowserCDPTransport.responseID(from: object) == id {
                if let error = object["error"] as? [String: Any] {
                    throw ControlledBrowserError.commandFailed(String(describing: error))
                }
                return object
            }
            events.append(object)
        }
    }
}

struct DevToolsPage: Decodable {
    let id: String?
    let type: String
    let title: String
    let url: String
    let webSocketDebuggerURL: String

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case url
        case webSocketDebuggerURL = "webSocketDebuggerUrl"
    }
}

struct DevToolsVersion: Decodable {
    let webSocketDebuggerURL: String
    let browser: String
    let protocolVersion: String

    enum CodingKeys: String, CodingKey {
        case webSocketDebuggerURL = "webSocketDebuggerUrl"
        case browser = "Browser"
        case protocolVersion = "Protocol-Version"
    }
}
