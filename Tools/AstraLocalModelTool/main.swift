import Darwin
import Foundation
import ASTRACore

private let version = "astra-local-model 0.1.0"

func main() -> Int32 {
    signal(SIGPIPE, SIG_IGN)
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--version") {
        print(version)
        return 0
    }
    if arguments.contains("--health") {
        print(#"{"status":"ok","backend":"scaffold"}"#)
        return 0
    }
    if arguments.contains("--list-models") {
        printModelList(arguments: arguments, backend: "scaffold")
        return 0
    }
    if arguments.contains("--smoke") {
        let report = LocalModelSmokeReport(
            status: "blocked",
            backend: "scaffold",
            message: "Native MLX inference is not enabled in this helper build."
        )
        printSmokeReport(report)
        return 78
    }

    guard arguments.first == "run" else {
        FileHandle.standardError.writeString("Usage: astra-local-model run --request-file <path>\n")
        return 64
    }

    startParentWatchdog()

    do {
        let request = try loadRequest(from: arguments)
        let output = protocolOutputHandle()
        startControlMonitor(output: output)
        try emit(.init(type: "started", sessionID: UUID().uuidString, model: request.model), to: output)
        try emit(.init(
            type: "failed",
            message: "Native MLX inference is not enabled in this helper build."
        ), to: output)
        return 78
    } catch {
        if isProtocolChannelClosed(error) {
            return 0
        }
        do {
            try emit(.init(type: "failed", message: error.localizedDescription), to: protocolOutputHandle())
        } catch {
            if isProtocolChannelClosed(error) {
                return 0
            }
            FileHandle.standardError.writeString("Failed to write protocol event: \(error.localizedDescription)\n")
        }
        return 1
    }
}

func printModelList(arguments: [String], backend: String) {
    let report = LocalModelListScanner.scan(
        modelsRoot: modelRootArgumentValue(in: arguments),
        selectedModelDirectory: argumentValue("--model-dir", in: arguments),
        backend: backend
    )
    guard let data = try? JSONEncoder().encode(report),
          let text = String(data: data, encoding: .utf8) else {
        print(#"{"status":"blocked","backend":"scaffold","models":[],"message":"Could not encode model list."}"#)
        return
    }
    print(text)
}

func loadRequest(from arguments: [String]) throws -> LocalModelRunRequest {
    guard let index = arguments.firstIndex(of: "--request-file"),
          arguments.indices.contains(arguments.index(after: index)) else {
        return LocalModelRunRequest(
            prompt: "",
            messages: [],
            model: "Qwen/Qwen3-4B-MLX-4bit",
            modelDirectory: nil,
            permissionMode: "restricted",
            experimentalToolsEnabled: false,
            maxContextTokens: nil
        )
    }

    let requestPath = arguments[arguments.index(after: index)]
    let data = try Data(contentsOf: URL(fileURLWithPath: requestPath))
    return try JSONDecoder().decode(LocalModelRunRequest.self, from: data)
}

func argumentValue(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name),
          arguments.indices.contains(arguments.index(after: index)) else {
        return nil
    }
    return arguments[arguments.index(after: index)]
}

func modelRootArgumentValue(in arguments: [String]) -> String? {
    argumentValue("--models-root", in: arguments) ?? argumentValue("--models-dir", in: arguments)
}

func protocolOutputHandle() -> FileHandle {
    let rawFD = ProcessInfo.processInfo.environment["ASTRA_LOCAL_MODEL_PROTOCOL_FD"] ?? "3"
    let fd = Int32(rawFD) ?? 3
    guard fd >= 0, fcntl(fd, F_GETFD) != -1 else {
        return .standardOutput
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: false)
}

func protocolControlHandle() -> FileHandle? {
    let rawFD = ProcessInfo.processInfo.environment["ASTRA_LOCAL_MODEL_CONTROL_FD"] ?? "4"
    let fd = Int32(rawFD) ?? 4
    guard fd >= 0, fcntl(fd, F_GETFD) != -1 else {
        return nil
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: false)
}

func startControlMonitor(output: FileHandle) {
    guard let control = protocolControlHandle() else { return }
    DispatchQueue.global(qos: .utility).async {
        let data = control.readDataToEndOfFile()
        guard !data.isEmpty,
              let line = String(data: data, encoding: .utf8)?
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                .first,
              let messageData = String(line).data(using: .utf8),
              let message = try? JSONDecoder().decode(LocalModelControlMessage.self, from: messageData),
              message.type == "cancel" else {
            return
        }
        try? emit(.init(
            type: "cancelled",
            message: message.reason ?? "Local MLX run cancelled."
        ), to: output)
        exit(130)
    }
}

func emit(_ envelope: LocalModelProtocolEnvelope, to handle: FileHandle) throws {
    let data = try JSONEncoder().encode(envelope)
    try writeAll(data + Data([0x0a]), to: handle.fileDescriptor)
}

func printSmokeReport(_ report: LocalModelSmokeReport) {
    guard let data = try? JSONEncoder().encode(report),
          let text = String(data: data, encoding: .utf8) else {
        print(#"{"status":"blocked","backend":"scaffold","message":"Could not encode smoke report."}"#)
        return
    }
    print(text)
}

func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
    _ = fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let written = Darwin.write(fileDescriptor, baseAddress.advanced(by: offset), data.count - offset)
            if written > 0 {
                offset += written
            } else if written == -1 && errno == EINTR {
                continue
            } else if written == -1 && errno == EPIPE {
                throw LocalModelToolError.protocolChannelClosed
            } else {
                throw LocalModelToolError.protocolWriteFailed(errno)
            }
        }
    }
}

func isProtocolChannelClosed(_ error: Error) -> Bool {
    if case LocalModelToolError.protocolChannelClosed = error {
        return true
    }
    return false
}

func startParentWatchdog() {
    let originalParent = getppid()
    DispatchQueue.global(qos: .utility).async {
        while true {
            sleep(2)
            let parent = getppid()
            if parent == 1 || parent != originalParent {
                exit(0)
            }
        }
    }
}

enum LocalModelToolError: LocalizedError {
    case protocolChannelClosed
    case protocolWriteFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .protocolChannelClosed:
            return "Local model protocol channel closed."
        case .protocolWriteFailed(let code):
            return "Local model protocol write failed: \(String(cString: strerror(code)))."
        }
    }
}

extension FileHandle {
    func writeString(_ value: String) {
        if let data = value.data(using: .utf8) {
            write(data)
        }
    }
}

exit(main())
