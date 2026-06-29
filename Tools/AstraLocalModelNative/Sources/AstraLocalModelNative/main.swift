import Darwin
import Foundation
import ASTRACore

#if arch(arm64)
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers
#endif

private let version = "astra-local-model 0.1.0"

@main
enum AstraLocalModelNative {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let exitCode = await LocalModelNativeMain().run(arguments: Array(CommandLine.arguments.dropFirst()))
        Darwin.exit(exitCode)
    }
}

struct LocalModelNativeMain {
    func run(arguments: [String]) async -> Int32 {
        if arguments.contains("--version") {
            print(version)
            return 0
        }
        if arguments.contains("--health") {
            print(#"{"status":"ok","backend":"mlx"}"#)
            return 0
        }
        if arguments.contains("--list-models") {
            printModelList(arguments: arguments)
            return 0
        }
        if arguments.contains("--smoke") {
            return await runSmoke(arguments: arguments)
        }

        if arguments.first == "serve" {
            startParentWatchdog()
            return await runServe(arguments: arguments)
        }

        guard arguments.first == "run" else {
            FileHandle.standardError.writeString(
                "Usage: astra-local-model (run --request-file <path> | serve [--idle-ttl-seconds <n>])\n")
            return 64
        }

        startParentWatchdog()

        do {
            let request = try loadRequest(from: arguments)
            let output = protocolOutputHandle()
            let cancellation = startControlMonitor(output: output)
            try emit(.init(type: "started", sessionID: UUID().uuidString, model: request.model), to: output)
            try await runInference(request: request, output: output, cancellation: cancellation)
            return 0
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

    private func loadRequest(from arguments: [String]) throws -> LocalModelRunRequest {
        guard let index = arguments.firstIndex(of: "--request-file"),
              arguments.indices.contains(arguments.index(after: index)) else {
            throw LocalModelNativeError.missingRequestFile
        }

        let requestPath = arguments[arguments.index(after: index)]
        let data = try Data(contentsOf: URL(fileURLWithPath: requestPath))
        return try JSONDecoder().decode(LocalModelRunRequest.self, from: data)
    }

    private func runSmoke(arguments: [String]) async -> Int32 {
        #if arch(arm64)
        let model = argumentValue("--model", in: arguments) ?? "local"
        let startedAt = Date()
        do {
            guard let modelDirectory = argumentValue("--model-dir", in: arguments)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !modelDirectory.isEmpty else {
                printSmokeReport(.init(
                    status: "blocked",
                    backend: "mlx",
                    model: model,
                    message: "Missing --model-dir for local MLX smoke test."
                ))
                return 64
            }

            let request = LocalModelRunRequest(
                prompt: "Reply with OK.",
                messages: [LocalModelChatMessage(role: "user", content: "Reply with OK.")],
                model: model,
                modelDirectory: modelDirectory,
                permissionMode: "restricted",
                experimentalToolsEnabled: false,
                maxContextTokens: intArgumentValue("--max-context-tokens", in: arguments),
                maxOutputTokens: intArgumentValue("--max-output-tokens", in: arguments) ?? 1,
                memoryBudgetBytes: intArgumentValue("--memory-budget-bytes", in: arguments),
                cacheLimitBytes: intArgumentValue("--cache-limit-bytes", in: arguments),
                keepWarmTTLSeconds: 0
            )
            configureMemoryLimits(for: request)
            defer { Memory.clearCache() }

            let container = try await MLXLMCommon.loadModelContainer(
                from: URL(fileURLWithPath: modelDirectory, isDirectory: true),
                using: #huggingFaceTokenizerLoader()
            )
            let preparedInput = try await container.prepare(input: UserInput(chat: try chatMessages(from: request)))
            let parameters = GenerateParameters(
                maxTokens: request.maxOutputTokens ?? 1,
                maxKVSize: request.maxContextTokens,
                temperature: 0.0
            )
            let firstTokenStartedAt = Date()
            var firstTokenLatencyMs: Int?
            var inputTokens = 0
            var outputTokens = 0
            var tokensPerSecond: Double?
            let stream = try await container.generate(input: preparedInput, parameters: parameters)
            for await generation in stream {
                switch generation {
                case .chunk:
                    if firstTokenLatencyMs == nil {
                        firstTokenLatencyMs = Int(Date().timeIntervalSince(firstTokenStartedAt) * 1_000)
                    }
                case .info(let info):
                    inputTokens = info.promptTokenCount
                    outputTokens = info.generationTokenCount
                    tokensPerSecond = finite(info.tokensPerSecond)
                case .toolCall:
                    break
                }
            }
            _ = container
            printSmokeReport(.init(
                status: "ok",
                backend: "mlx",
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                firstTokenLatencyMs: firstTokenLatencyMs,
                tokensPerSecond: tokensPerSecond
            ))
            return 0
        } catch {
            printSmokeReport(.init(
                status: "blocked",
                backend: "mlx",
                model: model,
                message: error.localizedDescription,
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1_000)
            ))
            return 1
        }
        #else
        printSmokeReport(.init(
            status: "blocked",
            backend: "mlx",
            message: "Native MLX smoke tests require an arm64 Apple Silicon build."
        ))
        return 78
        #endif
    }

    private func runInference(
        request: LocalModelRunRequest,
        output: FileHandle,
        cancellation: LocalModelCancellationToken
    ) async throws {
        #if arch(arm64)
        try cancellation.check()
        guard let modelDirectory = request.modelDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelDirectory.isEmpty else {
            throw LocalModelNativeError.missingModelDirectory
        }

        let startedAt = Date()
        configureMemoryLimits(for: request)
        defer { Memory.clearCache() }
        try emit(.init(type: "phase", message: "Loading local MLX model.", phase: "load_model"), to: output)
        try emitMemoryTelemetry(phase: "before_load", request: request, to: output)
        try cancellation.check()

        let modelURL = URL(fileURLWithPath: modelDirectory, isDirectory: true)
        let container = try await MLXLMCommon.loadModelContainer(
            from: modelURL,
            using: #huggingFaceTokenizerLoader()
        )
        try emitMemoryTelemetry(phase: "after_load", request: request, to: output)
        try cancellation.check()

        let input = UserInput(chat: try chatMessages(from: request))
        try emit(.init(type: "phase", message: "Preparing local MLX prompt.", phase: "prepare_prompt"), to: output)
        let preparedInput = try await container.prepare(input: input)
        try emitMemoryTelemetry(phase: "after_prepare", request: request, to: output)
        try cancellation.check()

        let parameters = GenerateParameters(
            maxTokens: request.maxOutputTokens ?? 1_024,
            maxKVSize: request.maxContextTokens,
            temperature: 0.2
        )
        try emit(.init(type: "phase", message: "Generating local MLX response.", phase: "generate"), to: output)
        let firstTokenStartedAt = Date()
        var firstTokenLatencyMs: Int?
        let stream = try await container.generate(input: preparedInput, parameters: parameters)

        var outputTokens = 0
        var inputTokens = 0
        var fullText = ""
        var reasoningFilter = LocalModelReasoningFilter()
        for await generation in stream {
            try cancellation.check()
            switch generation {
            case .chunk(let text):
                if firstTokenLatencyMs == nil {
                    firstTokenLatencyMs = Int(Date().timeIntervalSince(firstTokenStartedAt) * 1_000)
                    try emitMemoryTelemetry(phase: "first_token", request: request, to: output)
                }
                let visibleText = reasoningFilter.process(text: text)
                if !visibleText.isEmpty {
                    fullText += visibleText
                    try emit(.init(type: "text", text: visibleText), to: output)
                }
                try enforceMemoryBudget(request: request, output: output)
            case .info(let info):
                inputTokens = info.promptTokenCount
                outputTokens = info.generationTokenCount
                try emit(.init(
                    type: "stats",
                    inputTokens: info.promptTokenCount,
                    outputTokens: info.generationTokenCount,
                    durationMs: Int((info.promptTime + info.generateTime) * 1_000),
                    turns: 1,
                    promptTokensPerSecond: finite(info.promptTokensPerSecond),
                    tokensPerSecond: finite(info.tokensPerSecond),
                    firstTokenLatencyMs: firstTokenLatencyMs
                ), to: output)
                try emitMemoryTelemetry(phase: "generation_info", request: request, to: output)
            case .toolCall(let call):
                if request.experimentalToolsEnabled {
                    try emit(.init(
                        type: "tool_request",
                        name: call.function.name,
                        id: UUID().uuidString,
                        inputSummary: toolArgumentsSummary(call.function.arguments)
                    ), to: output)
                }
            }
        }

        let trailingText = reasoningFilter.flush()
        if !trailingText.isEmpty {
            fullText += trailingText
            try emit(.init(type: "text", text: trailingText), to: output)
        }
        try emitMemoryTelemetry(phase: "completed", request: request, to: output)
        if outputTokens == 0 {
            let estimated = max(1, fullText.split(whereSeparator: \.isWhitespace).count)
            outputTokens = estimated
        }
        try emit(.init(
            type: "stats",
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
            turns: 1,
            firstTokenLatencyMs: firstTokenLatencyMs
        ), to: output)
        try emit(.init(type: "completed", summary: fullText), to: output)
        _ = container
        #else
        throw LocalModelNativeError.unsupportedArchitecture
        #endif
    }

    private func loadRequestFile(_ path: String) throws -> LocalModelRunRequest {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(LocalModelRunRequest.self, from: data)
    }

    /// Persistent inference: load the model once, then serve many turns over the control channel
    /// (fd 4) keeping the `ModelContainer` resident. Reloads only when the selected model directory
    /// changes; exits cleanly on `shutdown`, on idle TTL, or when the control channel closes.
    private func runServe(arguments: [String]) async -> Int32 {
        #if arch(arm64)
        let output = protocolOutputHandle()
        let control = ServeControlChannel(handle: protocolControlHandle())
        let idleTTL = TimeInterval(max(1, intArgumentValue("--idle-ttl-seconds", in: arguments) ?? 300))
        var loadedDirectory: String?
        var container: ModelContainer?

        while let message = await control.next(timeout: idleTTL) {
            switch message.type {
            case "shutdown":
                return 0
            case "run":
                guard let requestFile = message.requestFile else { continue }
                let requestID = message.requestID
                let request: LocalModelRunRequest
                do {
                    request = try loadRequestFile(requestFile)
                } catch {
                    try? emit(.init(type: "failed", requestID: requestID,
                                    message: "Could not read local model request: \(error.localizedDescription)"),
                              to: output)
                    continue
                }
                let cancellation = control.beginTurn()
                do {
                    try emit(.init(type: "started", requestID: requestID, model: request.model), to: output)
                    configureMemoryLimits(for: request)
                    guard let modelDirectory = request.modelDirectory?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !modelDirectory.isEmpty else {
                        throw LocalModelNativeError.missingModelDirectory
                    }
                    try cancellation.check()
                    if modelDirectory != loadedDirectory || container == nil {
                        try emit(.init(type: "phase", requestID: requestID,
                                       message: "Loading local MLX model.", phase: "load_model"), to: output)
                        container = try await MLXLMCommon.loadModelContainer(
                            from: URL(fileURLWithPath: modelDirectory, isDirectory: true),
                            using: #huggingFaceTokenizerLoader())
                        loadedDirectory = modelDirectory
                    }
                    try await generateServeTurn(
                        request: request,
                        container: container!,
                        output: output,
                        requestID: requestID,
                        cancellation: cancellation
                    )
                } catch {
                    if isProtocolChannelClosed(error) { return 0 }
                    if case LocalModelNativeError.cancelled(let reason) = error {
                        try? emit(.init(type: "cancelled", requestID: requestID,
                                        message: reason ?? "Local MLX run cancelled."), to: output)
                        continue
                    }
                    Memory.clearCache()
                    try? emit(.init(type: "failed", requestID: requestID,
                                    message: error.localizedDescription), to: output)
                    // A memory-budget breach leaves MLX state suspect — exit so the app respawns clean.
                    if case LocalModelNativeError.memoryBudgetExceeded = error { return 1 }
                }
            default:
                continue
            }
        }
        return 0
        #else
        FileHandle.standardError.writeString("Native MLX serve requires an arm64 Apple Silicon build.\n")
        return 78
        #endif
    }

    #if arch(arm64)
    /// One generation against an already-resident container. Mirrors the streaming core of
    /// `runInference` but does NOT load the model, clear the cache, or idle — those are owned by the
    /// `serve` loop so the model stays warm across turns. Every envelope carries `requestID`.
    private func generateServeTurn(
        request: LocalModelRunRequest,
        container: ModelContainer,
        output: FileHandle,
        requestID: String?,
        cancellation: LocalModelCancellationToken
    ) async throws {
        let startedAt = Date()
        try cancellation.check()
        let input = UserInput(chat: try chatMessages(from: request))
        try emit(.init(type: "phase", requestID: requestID,
                       message: "Preparing local MLX prompt.", phase: "prepare_prompt"), to: output)
        let preparedInput = try await container.prepare(input: input)
        try cancellation.check()

        let parameters = GenerateParameters(
            maxTokens: request.maxOutputTokens ?? 1_024,
            maxKVSize: request.maxContextTokens,
            temperature: 0.2
        )
        try emit(.init(type: "phase", requestID: requestID,
                       message: "Generating local MLX response.", phase: "generate"), to: output)
        let firstTokenStartedAt = Date()
        var firstTokenLatencyMs: Int?
        let stream = try await container.generate(input: preparedInput, parameters: parameters)

        var outputTokens = 0
        var inputTokens = 0
        var fullText = ""
        var reasoningFilter = LocalModelReasoningFilter()
        for await generation in stream {
            try cancellation.check()
            switch generation {
            case .chunk(let text):
                if firstTokenLatencyMs == nil {
                    firstTokenLatencyMs = Int(Date().timeIntervalSince(firstTokenStartedAt) * 1_000)
                }
                let visibleText = reasoningFilter.process(text: text)
                if !visibleText.isEmpty {
                    fullText += visibleText
                    try emit(.init(type: "text", requestID: requestID, text: visibleText), to: output)
                }
                try enforceMemoryBudget(request: request, output: output)
            case .info(let info):
                inputTokens = info.promptTokenCount
                outputTokens = info.generationTokenCount
                try emit(.init(
                    type: "stats",
                    requestID: requestID,
                    inputTokens: info.promptTokenCount,
                    outputTokens: info.generationTokenCount,
                    durationMs: Int((info.promptTime + info.generateTime) * 1_000),
                    turns: 1,
                    promptTokensPerSecond: finite(info.promptTokensPerSecond),
                    tokensPerSecond: finite(info.tokensPerSecond),
                    firstTokenLatencyMs: firstTokenLatencyMs
                ), to: output)
            case .toolCall:
                break
            }
        }

        let trailingText = reasoningFilter.flush()
        if !trailingText.isEmpty {
            fullText += trailingText
            try emit(.init(type: "text", requestID: requestID, text: trailingText), to: output)
        }
        if outputTokens == 0 {
            outputTokens = max(1, fullText.split(whereSeparator: \.isWhitespace).count)
        }
        try emit(.init(
            type: "stats",
            requestID: requestID,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
            turns: 1,
            firstTokenLatencyMs: firstTokenLatencyMs
        ), to: output)
        try emit(.init(type: "completed", requestID: requestID, summary: fullText), to: output)
    }
    #endif

    #if arch(arm64)
    private func configureMemoryLimits(for request: LocalModelRunRequest) {
        if let memoryBudgetBytes = request.memoryBudgetBytes, memoryBudgetBytes > 0 {
            Memory.memoryLimit = memoryBudgetBytes
        }
        if let cacheLimitBytes = request.cacheLimitBytes, cacheLimitBytes >= 0 {
            Memory.cacheLimit = cacheLimitBytes
        }
    }

    private func emitMemoryTelemetry(phase: String, request: LocalModelRunRequest, to output: FileHandle) throws {
        let snapshot = Memory.snapshot()
        try emit(.init(
            type: "memory",
            phase: phase,
            activeMemoryBytes: snapshot.activeMemory,
            peakMemoryBytes: snapshot.peakMemory,
            cacheMemoryBytes: snapshot.cacheMemory,
            memoryLimitBytes: Memory.memoryLimit,
            cacheLimitBytes: Memory.cacheLimit,
            memoryBudgetBytes: request.memoryBudgetBytes
        ), to: output)
    }

    private func enforceMemoryBudget(request: LocalModelRunRequest, output: FileHandle) throws {
        guard let budget = request.memoryBudgetBytes, budget > 0 else { return }
        let snapshot = Memory.snapshot()
        let resident = snapshot.activeMemory + snapshot.cacheMemory
        guard resident > budget else { return }
        try emitMemoryTelemetry(phase: "memory_budget_exceeded", request: request, to: output)
        Memory.clearCache()
        throw LocalModelNativeError.memoryBudgetExceeded(activeBytes: resident, budgetBytes: budget)
    }

    private func finite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }

    private func chatMessages(from request: LocalModelRunRequest) throws -> [Chat.Message] {
        let messages = chatMessagesWithThinkingDisabledIfNeeded(from: request)
        return try messages.map { message in
            let images = try imageInputs(from: message.attachments)
            switch message.role.lowercased() {
            case "system":
                return .system(message.content, images: images)
            case "assistant":
                return .assistant(message.content, images: images)
            case "tool":
                return .tool(message.content)
            default:
                return .user(message.content, images: images)
            }
        }
    }

    private func imageInputs(from attachments: [LocalModelMediaAttachment]) throws -> [UserInput.Image] {
        try attachments.compactMap { attachment in
            guard attachment.isImage else { return nil }
            let path = attachment.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                throw LocalModelNativeError.invalidImageInput("Image attachment path is empty.")
            }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw LocalModelNativeError.invalidImageInput("Image attachment does not exist: \(url.path)")
            }
            guard Self.supportedImageExtensions.contains(url.pathExtension.lowercased()) else {
                throw LocalModelNativeError.invalidImageInput("Unsupported image attachment type: \(url.lastPathComponent)")
            }
            return UserInput.Image.url(url)
        }
    }

    private static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "bmp", "heic"
    ]

    private func chatMessagesWithThinkingDisabledIfNeeded(from request: LocalModelRunRequest) -> [LocalModelChatMessage] {
        var messages = request.messages.isEmpty
            ? [LocalModelChatMessage(role: "user", content: request.prompt)]
            : request.messages

        guard request.model.range(of: "qwen3", options: [.caseInsensitive]) != nil,
              let lastUserIndex = messages.indices.last(where: {
                messages[$0].role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user"
              }) else {
            return messages
        }
        let lowercasedContent = messages[lastUserIndex].content.lowercased()
        guard !lowercasedContent.contains("/no_think"),
              !lowercasedContent.contains("/think") else {
            return messages
        }
        messages[lastUserIndex].content += "\n\n/no_think"
        return messages
    }

    private func toolArgumentsSummary(_ arguments: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(arguments),
              let summary = String(data: data, encoding: .utf8) else {
            return "\(arguments.count) argument(s)"
        }
        return summary
    }

    private func waitForKeepWarmTTL(
        request: LocalModelRunRequest,
        output: FileHandle,
        cancellation: LocalModelCancellationToken
    ) async throws {
        guard let ttlSeconds = request.keepWarmTTLSeconds, ttlSeconds > 0 else {
            return
        }
        try emit(.init(
            type: "phase",
            message: "Keeping local MLX model warm for \(ttlSeconds) second(s).",
            phase: "idle_keep_warm"
        ), to: output)
        let deadline = Date().addingTimeInterval(TimeInterval(ttlSeconds))
        while Date() < deadline {
            try cancellation.check()
            try await Task.sleep(for: .milliseconds(250))
        }
        try cancellation.check()
    }
    #endif

    private func protocolOutputHandle() -> FileHandle {
        let rawFD = ProcessInfo.processInfo.environment["ASTRA_LOCAL_MODEL_PROTOCOL_FD"] ?? "3"
        let fd = Int32(rawFD) ?? 3
        guard fd >= 0, fcntl(fd, F_GETFD) != -1 else {
            return .standardOutput
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }

    private func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }

    private func intArgumentValue(_ name: String, in arguments: [String]) -> Int? {
        argumentValue(name, in: arguments).flatMap(Int.init)
    }

    private func modelRootArgumentValue(in arguments: [String]) -> String? {
        argumentValue("--models-root", in: arguments) ?? argumentValue("--models-dir", in: arguments)
    }

    private func printModelList(arguments: [String]) {
        let report = LocalModelListScanner.scan(
            modelsRoot: modelRootArgumentValue(in: arguments),
            selectedModelDirectory: argumentValue("--model-dir", in: arguments),
            backend: "mlx"
        )
        guard let data = try? JSONEncoder().encode(report),
              let text = String(data: data, encoding: .utf8) else {
            print(#"{"status":"blocked","backend":"mlx","models":[],"message":"Could not encode model list."}"#)
            return
        }
        print(text)
    }

    private func printSmokeReport(_ report: LocalModelSmokeReport) {
        guard let data = try? JSONEncoder().encode(report),
              let text = String(data: data, encoding: .utf8) else {
            print(#"{"status":"blocked","backend":"mlx","message":"Could not encode smoke report."}"#)
            return
        }
        print(text)
    }

    private func protocolControlHandle() -> FileHandle? {
        let rawFD = ProcessInfo.processInfo.environment["ASTRA_LOCAL_MODEL_CONTROL_FD"] ?? "4"
        let fd = Int32(rawFD) ?? 4
        guard fd >= 0, fcntl(fd, F_GETFD) != -1 else {
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }

    private func startControlMonitor(output: FileHandle) -> LocalModelCancellationToken {
        let token = LocalModelCancellationToken()
        guard let control = protocolControlHandle() else {
            return token
        }
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
            token.cancel(reason: message.reason)
            releaseLocalModelMemory()
            try? emit(.init(
                type: "cancelled",
                message: message.reason ?? "Local MLX run cancelled."
            ), to: output)
            Darwin.exit(130)
        }
        return token
    }

    private func releaseLocalModelMemory() {
        #if arch(arm64)
        Memory.clearCache()
        #endif
    }

    private func emit(_ envelope: LocalModelProtocolEnvelope, to handle: FileHandle) throws {
        let data = try JSONEncoder().encode(envelope)
        try writeAll(data + Data([0x0a]), to: handle.fileDescriptor)
    }

    private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
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
                    throw LocalModelNativeError.protocolChannelClosed
                } else {
                    throw LocalModelNativeError.protocolWriteFailed(errno)
                }
            }
        }
    }

    private func isProtocolChannelClosed(_ error: Error) -> Bool {
        if case LocalModelNativeError.protocolChannelClosed = error {
            return true
        }
        return false
    }

    private func startParentWatchdog() {
        let originalParent = getppid()
        DispatchQueue.global(qos: .utility).async {
            while true {
                sleep(2)
                let parent = getppid()
                if parent == 1 || parent != originalParent {
                    Darwin.exit(0)
                }
            }
        }
    }
}

enum LocalModelNativeError: LocalizedError {
    case missingRequestFile
    case missingModelDirectory
    case unsupportedArchitecture
    case invalidImageInput(String)
    case memoryBudgetExceeded(activeBytes: Int, budgetBytes: Int)
    case cancelled(reason: String?)
    case protocolChannelClosed
    case protocolWriteFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .missingRequestFile:
            return "Missing --request-file for local model run."
        case .missingModelDirectory:
            return "Native MLX inference requires a selected local model directory."
        case .unsupportedArchitecture:
            return "Native MLX inference requires an arm64 Apple Silicon build."
        case .invalidImageInput(let message):
            return message
        case .memoryBudgetExceeded(let activeBytes, let budgetBytes):
            return "Native MLX inference exceeded its memory budget: active plus cache memory \(activeBytes) bytes exceeded budget \(budgetBytes) bytes."
        case .cancelled(let reason):
            return reason ?? "Local MLX run cancelled."
        case .protocolChannelClosed:
            return "Local model protocol channel closed."
        case .protocolWriteFailed(let code):
            return "Local model protocol write failed: \(String(cString: strerror(code)))."
        }
    }
}

final class LocalModelCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledReason: String?

    func cancel(reason: String?) {
        lock.lock()
        cancelledReason = reason ?? "Local MLX run cancelled."
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let reason = cancelledReason
        lock.unlock()
        if let reason {
            throw LocalModelNativeError.cancelled(reason: reason)
        }
    }
}

/// Line-delimited reader for the control channel (fd 4) in `serve` mode. Delivers `run`/`shutdown`
/// messages to the serve loop (one at a time, with an idle timeout), and applies `cancel` messages
/// immediately to the current turn's cancellation token — so a cancel interrupts the in-flight
/// generation without queueing behind a pending run.
final class ServeControlChannel: @unchecked Sendable {
    private let handle: FileHandle?
    private let lock = NSLock()
    private var buffer = ""
    private var pending: [LocalModelControlMessage] = []
    private var waiter: CheckedContinuation<LocalModelControlMessage?, Never>?
    private var waiterTimeout: DispatchWorkItem?
    private var closed = false
    private var currentToken: LocalModelCancellationToken?

    init(handle: FileHandle?) {
        self.handle = handle
        startReading()
    }

    /// Begins a new turn, rotating in a fresh cancellation token that `cancel` messages target.
    func beginTurn() -> LocalModelCancellationToken {
        let token = LocalModelCancellationToken()
        lock.lock()
        currentToken = token
        lock.unlock()
        return token
    }

    /// Awaits the next `run`/`shutdown` message. Returns nil if the channel closed or no message
    /// arrived within `timeout` seconds (idle TTL).
    func next(timeout: TimeInterval) async -> LocalModelControlMessage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<LocalModelControlMessage?, Never>) in
            lock.lock()
            if !pending.isEmpty {
                let message = pending.removeFirst()
                lock.unlock()
                continuation.resume(returning: message)
                return
            }
            if closed {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.resumeWaiter(with: nil)
            }
            waiter = continuation
            waiterTimeout = timeoutItem
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        }
    }

    private func startReading() {
        guard let handle else {
            lock.lock(); closed = true; lock.unlock()
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    self?.finish()
                    return
                }
                self?.ingest(chunk)
            }
        }
    }

    private func ingest(_ chunk: Data) {
        // Control messages are small ASCII JSON lines; partial multi-byte splits are not expected.
        guard let text = String(data: chunk, encoding: .utf8) else { return }
        var delivered: [LocalModelControlMessage] = []
        lock.lock()
        buffer += text
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newlineIndex])
            buffer = String(buffer[buffer.index(after: newlineIndex)...])
            guard let data = line.data(using: .utf8),
                  let message = try? JSONDecoder().decode(LocalModelControlMessage.self, from: data) else {
                continue
            }
            if message.type == "cancel" {
                currentToken?.cancel(reason: message.reason)
            } else {
                delivered.append(message)
            }
        }
        lock.unlock()
        for message in delivered {
            deliver(message)
        }
    }

    private func deliver(_ message: LocalModelControlMessage) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            waiterTimeout?.cancel()
            waiterTimeout = nil
            lock.unlock()
            waiter.resume(returning: message)
        } else {
            pending.append(message)
            lock.unlock()
        }
    }

    private func resumeWaiter(with message: LocalModelControlMessage?) {
        lock.lock()
        guard let waiter else { lock.unlock(); return }
        self.waiter = nil
        waiterTimeout?.cancel()
        waiterTimeout = nil
        lock.unlock()
        waiter.resume(returning: message)
    }

    private func finish() {
        lock.lock()
        closed = true
        lock.unlock()
        resumeWaiter(with: nil)
    }
}

extension FileHandle {
    func writeString(_ value: String) {
        if let data = value.data(using: .utf8) {
            write(data)
        }
    }
}
