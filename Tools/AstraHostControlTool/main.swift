import Darwin
import Foundation
import ASTRACore
import HostControlToolSupport

@main
struct AstraHostControlTool {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let endpoint = ProcessInfo.processInfo.environment[
            HostControlBrokerIPC.endpointEnvironmentKey
        ]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !endpoint.isEmpty {
            if arguments.isEmpty {
                AstraHostControlBrokerClient.run(socketPath: endpoint)
            } else {
                Darwin.exit(AstraHostControlBrokerCLI.run(arguments: arguments, socketPath: endpoint))
            }
            return
        }
        if !arguments.isEmpty {
            FileHandle.standardError.write(Data(
                "astra-host-control commands require an active ASTRA broker session.\n".utf8
            ))
            Darwin.exit(2)
        }
        AstraHostControlToolMain.run()
    }
}

private enum AstraHostControlBrokerClient {
    private static let maximumReplyBytes = 1_048_576

    static func run(socketPath: String) {
        let descriptor: Int32
        do {
            descriptor = try connect(socketPath: socketPath)
        } catch {
            relayBrokerFailure(error.localizedDescription)
            return
        }
        defer { Darwin.close(descriptor) }

        var pendingReply = Data()
        while let line = Swift.readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            do {
                try writeLine(line, to: descriptor)
                let reply = try readLine(from: descriptor, pending: &pendingReply)
                if !reply.isEmpty {
                    writeLine(reply)
                }
            } catch {
                writeLine(brokerFailureLine(for: line, message: error.localizedDescription))
                relayBrokerFailure(error.localizedDescription)
                return
            }
        }

    }

    static func request(_ line: String, socketPath: String) throws -> String {
        let descriptor = try connect(socketPath: socketPath)
        defer { Darwin.close(descriptor) }
        try writeLine(line, to: descriptor)
        var pending = Data()
        return try readLine(from: descriptor, pending: &pending)
    }

    private static func connect(socketPath: String) throws -> Int32 {
        let path = try HostControlBrokerIPC.validatedSocketPath(socketPath)
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw HostControlBrokerClientError.invalidEndpoint
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw HostControlBrokerClientError.unavailable
        }
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var timeout = timeval(tv_sec: 305, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw HostControlBrokerClientError.unavailable
        }
        return descriptor
    }

    private static func writeLine(_ line: String, to descriptor: Int32) throws {
        let data = Data((line + "\n").utf8)
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
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
                    throw HostControlBrokerClientError.disconnected
                }
                guard written > 0 else {
                    throw HostControlBrokerClientError.disconnected
                }
                offset += written
            }
        }
    }

    private static func readLine(
        from descriptor: Int32,
        pending: inout Data
    ) throws -> String {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            if let newlineIndex = pending.firstIndex(of: 0x0A) {
                var line = String(decoding: pending[..<newlineIndex], as: UTF8.self)
                pending.removeSubrange(...newlineIndex)
                if line.last == "\r" {
                    line.removeLast()
                }
                return line
            }
            guard pending.count <= maximumReplyBytes else {
                throw HostControlBrokerClientError.replyTooLarge
            }

            let count = chunk.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count == 0 {
                throw HostControlBrokerClientError.disconnected
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw HostControlBrokerClientError.timedOut
                }
                throw HostControlBrokerClientError.disconnected
            }
            pending.append(contentsOf: chunk.prefix(count))
        }
    }

    private static func relayBrokerFailure(_ message: String) {
        while let line = Swift.readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            writeLine(brokerFailureLine(for: line, message: message))
        }
    }

    private static func brokerFailureLine(for requestLine: String, message: String) -> String {
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
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"ASTRA host-control broker failed."}}"#
        }
        return line
    }

    private static func writeLine(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

private enum AstraHostControlBrokerCLI {
    static func run(arguments: [String], socketPath: String) -> Int32 {
        do {
            let invocation = try invocation(arguments)
            let request: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": [
                    "name": invocation.tool,
                    "arguments": invocation.arguments
                ]
            ]
            let requestData = try JSONSerialization.data(
                withJSONObject: request,
                options: [.sortedKeys]
            )
            guard let requestLine = String(data: requestData, encoding: .utf8) else {
                throw HostControlBrokerCLIError.invalidArguments
            }
            let response = try AstraHostControlBrokerClient.request(
                requestLine,
                socketPath: socketPath
            )
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
            return responseIndicatesFailure(response) ? 1 : 0
        } catch {
            FileHandle.standardError.write(Data(
                "\(error.localizedDescription)\n\(usage)\n".utf8
            ))
            return 2
        }
    }

    private struct Invocation {
        let tool: String
        let arguments: [String: Any]
    }

    private static func invocation(_ arguments: [String]) throws -> Invocation {
        guard let rawTool = arguments.first else {
            throw HostControlBrokerCLIError.invalidArguments
        }
        let tool = rawTool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let remaining = Array(arguments.dropFirst())
        switch tool {
        case "jira":
            return Invocation(tool: tool, arguments: try jiraArguments(remaining))
        case "ssh":
            return Invocation(tool: tool, arguments: try sshArguments(remaining))
        case "github", "gcloud", "bq":
            let commandArguments = remaining.first == "--"
                ? Array(remaining.dropFirst())
                : remaining
            guard !commandArguments.isEmpty else {
                throw HostControlBrokerCLIError.invalidArguments
            }
            return Invocation(tool: tool, arguments: ["arguments": commandArguments])
        default:
            throw HostControlBrokerCLIError.unsupportedTool(tool)
        }
    }

    private static func jiraArguments(_ arguments: [String]) throws -> [String: Any] {
        let values = try parsedOptions(
            arguments,
            allowed: [
                "--operation", "--alias", "--issue-key", "--jql",
                "--max-results", "--next-page-token", "--timeout-seconds"
            ]
        )
        var output: [String: Any] = [:]
        let operation = (values["--operation"] ?? "status")
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        guard ["status", "get_issue", "search_jql"].contains(operation) else {
            throw HostControlBrokerCLIError.invalidArguments
        }
        output["operation"] = operation
        copy("--alias", to: "alias", from: values, into: &output)
        copy("--issue-key", to: "issue_key", from: values, into: &output)
        copy("--jql", to: "jql", from: values, into: &output)
        copy("--next-page-token", to: "next_page_token", from: values, into: &output)
        if let value = values["--max-results"], let parsed = Int(value), parsed > 0 {
            output["max_results"] = parsed
        } else if values["--max-results"] != nil {
            throw HostControlBrokerCLIError.invalidArguments
        }
        if let value = values["--timeout-seconds"],
           let parsed = Double(value),
           parsed.isFinite,
           parsed > 0 {
            output["timeout_seconds"] = parsed
        } else if values["--timeout-seconds"] != nil {
            throw HostControlBrokerCLIError.invalidArguments
        }
        return output
    }

    private static func sshArguments(_ arguments: [String]) throws -> [String: Any] {
        let values = try parsedOptions(
            arguments,
            allowed: ["--alias", "--timeout-seconds"]
        )
        guard let alias = values["--alias"], !alias.isEmpty else {
            throw HostControlBrokerCLIError.invalidArguments
        }
        var output: [String: Any] = ["alias": alias]
        if let value = values["--timeout-seconds"],
           let parsed = Double(value),
           parsed.isFinite,
           parsed > 0 {
            output["timeout_seconds"] = parsed
        } else if values["--timeout-seconds"] != nil {
            throw HostControlBrokerCLIError.invalidArguments
        }
        return output
    }

    private static func parsedOptions(
        _ arguments: [String],
        allowed: Set<String>
    ) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else {
            throw HostControlBrokerCLIError.invalidArguments
        }
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            let value = arguments[index + 1]
            guard allowed.contains(key),
                  values[key] == nil,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HostControlBrokerCLIError.invalidArguments
            }
            values[key] = value
            index += 2
        }
        return values
    }

    private static func copy(
        _ source: String,
        to destination: String,
        from values: [String: String],
        into output: inout [String: Any]
    ) {
        if let value = values[source] {
            output[destination] = value
        }
    }

    private static func responseIndicatesFailure(_ response: String) -> Bool {
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        if object["error"] != nil {
            return true
        }
        if let result = object["result"] as? [String: Any],
           result["isError"] as? Bool == true {
            return true
        }
        return false
    }

    private static let usage = """
    Usage:
      astra-host-control jira --operation status|search-jql|get-issue [--alias NAME] [--jql JQL] [--issue-key KEY] [--max-results N]
      astra-host-control ssh --alias NAME
      astra-host-control github|gcloud|bq -- ARGUMENT...
    """
}

private enum HostControlBrokerCLIError: LocalizedError {
    case invalidArguments
    case unsupportedTool(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Invalid ASTRA host-control command arguments."
        case .unsupportedTool(let tool):
            "Unsupported ASTRA host-control tool '\(tool)'."
        }
    }
}

private enum HostControlBrokerClientError: LocalizedError {
    case invalidEndpoint
    case unavailable
    case disconnected
    case timedOut
    case replyTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "ASTRA host-control broker socket is invalid."
        case .unavailable:
            "ASTRA host-control broker is unavailable."
        case .disconnected:
            "ASTRA host-control broker disconnected."
        case .timedOut:
            "ASTRA host-control broker timed out."
        case .replyTooLarge:
            "ASTRA host-control broker reply exceeded its size limit."
        }
    }
}
