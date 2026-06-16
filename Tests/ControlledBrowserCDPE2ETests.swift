import CryptoKit
import Foundation
import Network
import Testing
@testable import ASTRA

@Suite("Controlled Browser CDP E2E")
struct ControlledBrowserCDPE2ETests {
    @Test("Settlement runner consumes real WebSocket CDP success events")
    func settlementRunnerConsumesRealWebSocketCDPSuccessEvents() async throws {
        let server = try await FakeCDPWebSocketServer.start(scenario: .success)
        defer { server.stop() }

        let sample = try await ControlledBrowserActionSettlementRunner.dispatchMouseClick(
            webSocketURL: server.webSocketURL,
            x: 14,
            y: 18
        )
        let result = ControlledBrowserActionSettlement.evaluate(
            action: "click",
            beforeURL: "http://127.0.0.1/before",
            beforeTitle: "Before",
            afterURL: "http://127.0.0.1/after",
            afterTitle: "After",
            events: sample.events,
            accessibilityNodeCount: sample.accessibilityNodeCount,
            elapsedMs: sample.elapsedMs
        )

        #expect(result.isSettled)
        #expect(result.signals.contains("page.lifecycle.networkIdle"))
        #expect(result.accessibilityRefreshed)
        #expect(server.receivedMethods.contains("Input.dispatchMouseEvent"))
        #expect(server.receivedMethods.contains("Accessibility.getFullAXTree"))
    }

    @Test("Settlement runner surfaces real WebSocket CDP runtime failures")
    func settlementRunnerSurfacesRealWebSocketCDPRuntimeFailures() async throws {
        let server = try await FakeCDPWebSocketServer.start(scenario: .runtimeFailure)
        defer { server.stop() }

        let sample = try await ControlledBrowserActionSettlementRunner.dispatchMouseClick(
            webSocketURL: server.webSocketURL,
            x: 14,
            y: 18
        )
        let result = ControlledBrowserActionSettlement.evaluate(
            action: "click",
            beforeURL: "http://127.0.0.1/form",
            beforeTitle: "Form",
            afterURL: "http://127.0.0.1/form",
            afterTitle: "Form",
            events: sample.events,
            accessibilityNodeCount: sample.accessibilityNodeCount,
            elapsedMs: sample.elapsedMs
        )

        #expect(result.isSettled == false)
        #expect(result.errors.contains("runtime.exception"))
        #expect(server.receivedMethods.contains("Input.dispatchMouseEvent"))
    }

    @Test("Settlement runner evaluates JavaScript through real WebSocket CDP")
    func settlementRunnerEvaluatesJavaScriptThroughRealWebSocketCDP() async throws {
        let server = try await FakeCDPWebSocketServer.start(scenario: .success)
        defer { server.stop() }

        let evaluated = try await ControlledBrowserActionSettlementRunner.evaluate(
            webSocketURL: server.webSocketURL,
            script: "JSON.stringify({ok:true})"
        )

        #expect(evaluated.value == #"{"ok":true}"#)
        #expect(evaluated.sample.accessibilityNodeCount == 2)
        #expect(server.receivedMethods.contains("Runtime.evaluate"))
        #expect(server.receivedMethods.contains("Accessibility.getFullAXTree"))
    }

    @Test("Live controlled browser smoke is available behind an explicit environment gate")
    func liveControlledBrowserSmokeIsAvailableBehindExplicitEnvironmentGate() async throws {
        guard ProcessInfo.processInfo.environment["ASTRA_CONTROLLED_BROWSER_E2E"] == "1" else {
            return
        }
        guard let browser = ControlledBrowserCandidate.firstAvailable() else {
            Issue.record("ASTRA_CONTROLLED_BROWSER_E2E=1 but no supported Chromium browser was found")
            return
        }

        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-controlled-browser-e2e-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)

        let port = UInt16.random(in: 42_000...62_000)
        let fixture = "data:text/html,<button id='target' onclick=\"document.title='clicked';document.body.setAttribute('data-clicked','1')\">Click</button>"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: browser.executablePath)
        process.arguments = browser.launchArguments(
            profilePath: profile.path,
            debugPort: port,
            initialURL: URL(string: fixture)
        )
        try process.run()
        defer { process.terminate() }

        let page = try await waitForInspectablePage(port: port)
        let webSocketURL = try #require(URL(string: page.webSocketDebuggerURL))
        let sample = try await ControlledBrowserActionSettlementRunner.dispatchMouseClick(
            webSocketURL: webSocketURL,
            x: 30,
            y: 20
        )

        #expect(sample.accessibilityNodeCount > 0)
        #expect(sample.events.contains { ($0["method"] as? String) == "Page.lifecycleEvent" }
            || sample.events.contains { ($0["method"] as? String) == "Page.loadEventFired" })
    }

    private func waitForInspectablePage(port: UInt16) async throws -> DevToolsPage {
        let url = URL(string: "http://127.0.0.1:\(port)/json")!
        var lastError: Error?
        for _ in 0..<80 {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let pages = try JSONDecoder().decode([DevToolsPage].self, from: data)
                if let page = pages.first(where: { $0.type == "page" && !$0.webSocketDebuggerURL.isEmpty }) {
                    return page
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw lastError ?? ControlledBrowserError.noInspectablePage
    }
}

private final class FakeCDPWebSocketServer: @unchecked Sendable {
    enum Scenario {
        case success
        case runtimeFailure
    }

    private let listener: NWListener
    private let scenario: Scenario
    private let queue = DispatchQueue(label: "com.coral.astra.tests.fake-cdp-websocket")
    private var port: UInt16 = 0
    private var methods: [String] = []

    var webSocketURL: URL {
        URL(string: "ws://127.0.0.1:\(queue.sync { port })/devtools/page/fake")!
    }

    var receivedMethods: [String] {
        queue.sync { methods }
    }

    static func start(scenario: Scenario) async throws -> FakeCDPWebSocketServer {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        let server = FakeCDPWebSocketServer(listener: listener, scenario: scenario)
        try await server.start()
        return server
    }

    private init(listener: NWListener, scenario: Scenario) {
        self.listener = listener
        self.scenario = scenario
    }

    func stop() {
        listener.cancel()
    }

    private func start() async throws {
        let resume = SingleResume<Void>()
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port else {
                    resume.resume(throwing: ControlledBrowserError.missingDebugPort)
                    return
                }
                self.queue.async {
                    self.port = port.rawValue
                    resume.resume(returning: ())
                }
            case .failed(let error):
                resume.resume(throwing: error)
            case .cancelled:
                resume.resume(throwing: ControlledBrowserError.timedOut("starting fake CDP server"))
            default:
                break
            }
        }
        listener.start(queue: queue)
        try await resume.value()
    }

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                self.readHandshake(on: connection)
            }
        }
        connection.start(queue: queue)
    }

    private func readHandshake(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, isComplete, error in
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            guard let request = String(data: nextBuffer, encoding: .utf8),
                  request.contains("\r\n\r\n") else {
                self.readHandshake(on: connection, buffer: nextBuffer)
                return
            }
            guard let key = self.webSocketKey(from: request) else {
                connection.cancel()
                return
            }
            self.sendHandshakeResponse(accepting: key, on: connection)
        }
    }

    private func sendHandshakeResponse(accepting key: String, on connection: NWConnection) {
        let accept = webSocketAccept(key: key)
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { error in
            if error != nil {
                connection.cancel()
                return
            }
            self.readFrame(on: connection)
        })
    }

    private func readFrame(on connection: NWConnection) {
        receiveExact(length: 2, on: connection) { header in
            guard let header else {
                connection.cancel()
                return
            }
            let bytes = [UInt8](header)
            let opcode = bytes[0] & 0x0f
            let masked = (bytes[1] & 0x80) != 0
            let shortLength = Int(bytes[1] & 0x7f)

            if opcode == 0x8 {
                connection.cancel()
                return
            }
            self.readPayloadLength(
                shortLength: shortLength,
                masked: masked,
                on: connection
            ) { length, mask in
                self.readPayload(length: length, mask: mask, on: connection) { payload in
                    if opcode == 0x1,
                       let text = String(data: payload, encoding: .utf8) {
                        self.handleMessage(text, on: connection)
                    } else {
                        self.readFrame(on: connection)
                    }
                }
            }
        }
    }

    private func readPayloadLength(
        shortLength: Int,
        masked: Bool,
        on connection: NWConnection,
        completion: @escaping (Int, [UInt8]?) -> Void
    ) {
        let readMask: (Int) -> Void = { length in
            guard masked else {
                completion(length, nil)
                return
            }
            self.receiveExact(length: 4, on: connection) { maskData in
                guard let maskData else {
                    connection.cancel()
                    return
                }
                completion(length, [UInt8](maskData))
            }
        }

        switch shortLength {
        case 0...125:
            readMask(shortLength)
        case 126:
            self.receiveExact(length: 2, on: connection) { data in
                guard let data else {
                    connection.cancel()
                    return
                }
                let bytes = [UInt8](data)
                readMask(Int(bytes[0]) << 8 | Int(bytes[1]))
            }
        default:
            self.receiveExact(length: 8, on: connection) { data in
                guard let data else {
                    connection.cancel()
                    return
                }
                let length = [UInt8](data).reduce(0) { partial, byte in
                    (partial << 8) | Int(byte)
                }
                readMask(length)
            }
        }
    }

    private func readPayload(
        length: Int,
        mask: [UInt8]?,
        on connection: NWConnection,
        completion: @escaping (Data) -> Void
    ) {
        guard length > 0 else {
            completion(Data())
            return
        }
        receiveExact(length: length, on: connection) { data in
            guard let data else {
                connection.cancel()
                return
            }
            var bytes = [UInt8](data)
            if let mask {
                for index in bytes.indices {
                    bytes[index] ^= mask[index % 4]
                }
            }
            completion(Data(bytes))
        }
    }

    private func receiveExact(length: Int, on connection: NWConnection, completion: @escaping (Data?) -> Void) {
        receiveExact(length: length, buffer: Data(), on: connection, completion: completion)
    }

    private func receiveExact(
        length: Int,
        buffer: Data,
        on connection: NWConnection,
        completion: @escaping (Data?) -> Void
    ) {
        let remaining = length - buffer.count
        guard remaining > 0 else {
            completion(buffer)
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
            if error != nil {
                completion(nil)
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if nextBuffer.count == length {
                completion(nextBuffer)
                return
            }

            guard !isComplete else {
                completion(nil)
                return
            }

            self.receiveExact(length: length, buffer: nextBuffer, on: connection, completion: completion)
        }
    }

    private func handleMessage(_ text: String, on connection: NWConnection) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            readFrame(on: connection)
            return
        }
        let id = object["id"] as? Int ?? (object["id"] as? NSNumber)?.intValue ?? 0
        let method = object["method"] as? String ?? ""
        methods.append(method)

        send(responseFor: method, id: id, on: connection) {
            if method == "Input.dispatchMouseEvent",
               let params = object["params"] as? [String: Any],
               params["type"] as? String == "mouseReleased" {
                self.sendScenarioEvents(on: connection) {
                    self.readFrame(on: connection)
                }
            } else {
                self.readFrame(on: connection)
            }
        }
    }

    private func responseFor(_ method: String, id: Int) -> [String: Any] {
        switch method {
        case "Accessibility.getFullAXTree":
            [
                "id": id,
                "result": [
                    "nodes": [
                        ["nodeId": "1", "role": ["value": "RootWebArea"]],
                        ["nodeId": "2", "role": ["value": "button"], "name": ["value": "Click"]]
                    ]
                ]
            ]
        case "Runtime.evaluate":
            [
                "id": id,
                "result": [
                    "result": [
                        "type": "string",
                        "value": #"{"ok":true}"#
                    ]
                ]
            ]
        default:
            ["id": id, "result": [:]]
        }
    }

    private func send(responseFor method: String, id: Int, on connection: NWConnection, completion: @escaping () -> Void) {
        sendJSON(responseFor(method, id: id), on: connection, completion: completion)
    }

    private func sendScenarioEvents(on connection: NWConnection, completion: @escaping () -> Void) {
        let events: [[String: Any]]
        switch scenario {
        case .success:
            events = [
                ["method": "Page.lifecycleEvent", "params": ["name": "networkIdle", "frameId": "main"]],
                ["method": "Page.loadEventFired", "params": [:]]
            ]
        case .runtimeFailure:
            events = [
                ["method": "Runtime.exceptionThrown", "params": ["exceptionDetails": ["text": "boom"]]]
            ]
        }
        sendJSONSequence(events, on: connection, completion: completion)
    }

    private func sendJSONSequence(_ objects: [[String: Any]], on connection: NWConnection, completion: @escaping () -> Void) {
        var remaining = objects
        guard !remaining.isEmpty else {
            completion()
            return
        }
        let next = remaining.removeFirst()
        sendJSON(next, on: connection) {
            self.sendJSONSequence(remaining, on: connection, completion: completion)
        }
    }

    private func sendJSON(_ object: [String: Any], on connection: NWConnection, completion: @escaping () -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            connection.cancel()
            return
        }
        connection.send(content: webSocketTextFrame(text), completion: .contentProcessed { error in
            if error != nil {
                connection.cancel()
                return
            }
            completion()
        })
    }

    private func webSocketTextFrame(_ text: String) -> Data {
        let payload = [UInt8](text.utf8)
        var frame = Data([0x81])
        if payload.count <= 125 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xff))
            frame.append(UInt8(payload.count & 0xff))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((payload.count >> shift) & 0xff))
            }
        }
        frame.append(contentsOf: payload)
        return frame
    }

    private func webSocketKey(from request: String) -> String? {
        request
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
            .split(separator: ":", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func webSocketAccept(key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }
}

private final class SingleResume<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(returning value: Value) {
        finish(.success(value))
    }

    func resume(throwing error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
