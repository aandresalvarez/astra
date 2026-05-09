import Foundation
import Network

struct BrowserBridgeRequest {
    let method: String
    let path: String
    let queryItems: [String: String]
    let body: Data

    func decodeJSON<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: body)
    }

    func queryValue(_ name: String) -> String? {
        queryItems[name]
    }
}

struct BrowserBridgeResponse {
    let statusCode: Int
    let contentType: String
    let body: Data

    static func json(_ object: Any, statusCode: Int = 200) -> BrowserBridgeResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            ?? Data(#"{"ok":false,"error":"encoding_failed"}"#.utf8)
        return BrowserBridgeResponse(statusCode: statusCode, contentType: "application/json; charset=utf-8", body: data)
    }

    static func rawJSON(_ json: String, statusCode: Int = 200) -> BrowserBridgeResponse {
        BrowserBridgeResponse(statusCode: statusCode, contentType: "application/json; charset=utf-8", body: Data(json.utf8))
    }
}

final class BrowserBridgeServer: @unchecked Sendable {
    typealias RouteHandler = @Sendable (BrowserBridgeRequest) async -> BrowserBridgeResponse
    typealias EndpointHandler = @Sendable (String?) -> Void

    private let queue = DispatchQueue(label: "com.coral.astra.browser-bridge")
    private let route: RouteHandler
    private let onEndpointChanged: EndpointHandler
    private var listener: NWListener?

    init(route: @escaping RouteHandler, onEndpointChanged: @escaping EndpointHandler) {
        self.route = route
        self.onEndpointChanged = onEndpointChanged
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.onEndpointChanged(nil)
        }
    }

    private func startOnQueue() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

            let listener = try NWListener(using: parameters, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = listener?.port {
                        self.onEndpointChanged("http://127.0.0.1:\(port.rawValue)")
                    }
                case .failed, .cancelled:
                    self.onEndpointChanged(nil)
                case .setup, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            onEndpointChanged(nil)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil else {
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            if let request = Self.parseRequest(from: buffer) {
                Task {
                    let response = await self.route(request)
                    self.send(response, on: connection)
                }
                return
            }

            guard buffer.count < 1024 * 1024 else {
                self.send(.json(["ok": false, "error": "request_too_large"], statusCode: 413), on: connection)
                return
            }

            self.receive(on: connection, accumulated: buffer)
        }
    }

    private func send(_ response: BrowserBridgeResponse, on connection: NWConnection) {
        var header = ""
        header += "HTTP/1.1 \(response.statusCode) \(Self.reasonPhrase(for: response.statusCode))\r\n"
        header += "Content-Type: \(response.contentType)\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Connection: close\r\n\r\n"

        var payload = Data(header.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseRequest(from data: Data) -> BrowserBridgeRequest? {
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<separatorRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = separatorRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = data[bodyStart..<(bodyStart + contentLength)]
        let requestTarget = requestParts[1]
        let components = URLComponents(string: requestTarget)
        let path = components?.path.isEmpty == false ? components?.path ?? requestTarget : requestTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestTarget
        var queryItems: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            if let value = item.value {
                queryItems[item.name] = value
            }
        }

        return BrowserBridgeRequest(
            method: requestParts[0].uppercased(),
            path: path,
            queryItems: queryItems,
            body: Data(body)
        )
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        default: return "OK"
        }
    }
}
