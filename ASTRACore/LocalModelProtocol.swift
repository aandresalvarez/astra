import Foundation

public struct LocalModelChatMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct LocalModelRunRequest: Codable, Sendable, Equatable {
    public var prompt: String
    public var messages: [LocalModelChatMessage]
    public var model: String
    public var modelDirectory: String?
    public var permissionMode: String
    public var experimentalToolsEnabled: Bool
    public var maxContextTokens: Int?
    public var maxOutputTokens: Int?
    public var memoryBudgetBytes: Int?
    public var cacheLimitBytes: Int?
    public var keepWarmTTLSeconds: Int?

    public init(
        prompt: String,
        messages: [LocalModelChatMessage],
        model: String,
        modelDirectory: String?,
        permissionMode: String,
        experimentalToolsEnabled: Bool,
        maxContextTokens: Int?,
        maxOutputTokens: Int? = nil,
        memoryBudgetBytes: Int? = nil,
        cacheLimitBytes: Int? = nil,
        keepWarmTTLSeconds: Int? = nil
    ) {
        self.prompt = prompt
        self.messages = messages
        self.model = model
        self.modelDirectory = modelDirectory
        self.permissionMode = permissionMode
        self.experimentalToolsEnabled = experimentalToolsEnabled
        self.maxContextTokens = maxContextTokens
        self.maxOutputTokens = maxOutputTokens
        self.memoryBudgetBytes = memoryBudgetBytes
        self.cacheLimitBytes = cacheLimitBytes
        self.keepWarmTTLSeconds = keepWarmTTLSeconds
    }
}

public enum LocalModelJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: LocalModelJSONValue])
    case array([LocalModelJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([LocalModelJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: LocalModelJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: LocalModelJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .number(let value):
            return value.isFinite ? Int(value) : nil
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    public var numberValue: Double? {
        switch self {
        case .number(let value):
            return value.isFinite ? value : nil
        case .string(let value):
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}

public enum LocalModelAction: Sendable, Equatable {
    case final(id: String?, answer: String)
    case toolCall(id: String, tool: String, arguments: [String: LocalModelJSONValue], safety: String?)
    case plan(id: String?, steps: [String])
    case askUser(id: String?, question: String)
    case blocked(id: String?, reason: String)
    case cancelled(id: String?, reason: String?)
}

public struct LocalModelActionEnvelope: Codable, Sendable, Equatable {
    public var type: String
    public var id: String?
    public var answer: String?
    public var tool: String?
    public var arguments: [String: LocalModelJSONValue]?
    public var safety: String?
    public var steps: [String]?
    public var question: String?
    public var reason: String?
    public var message: String?

    public init(
        type: String,
        id: String? = nil,
        answer: String? = nil,
        tool: String? = nil,
        arguments: [String: LocalModelJSONValue]? = nil,
        safety: String? = nil,
        steps: [String]? = nil,
        question: String? = nil,
        reason: String? = nil,
        message: String? = nil
    ) {
        self.type = type
        self.id = id
        self.answer = answer
        self.tool = tool
        self.arguments = arguments
        self.safety = safety
        self.steps = steps
        self.question = question
        self.reason = reason
        self.message = message
    }

    public func action() throws -> LocalModelAction {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalizedType {
        case "final":
            let value = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { throw LocalModelActionParseError.missingField("answer") }
            return .final(id: cleaned(id), answer: value)
        case "tool_call", "tool":
            let toolName = normalizedToolName(tool?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            guard !toolName.isEmpty else { throw LocalModelActionParseError.missingField("tool") }
            return .toolCall(
                id: cleaned(id) ?? UUID().uuidString,
                tool: toolName,
                arguments: arguments ?? [:],
                safety: cleaned(safety)
            )
        case "plan":
            let plannedSteps = (steps ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !plannedSteps.isEmpty else { throw LocalModelActionParseError.missingField("steps") }
            return .plan(id: cleaned(id), steps: plannedSteps)
        case "ask_user", "ask":
            let value = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { throw LocalModelActionParseError.missingField("question") }
            return .askUser(id: cleaned(id), question: value)
        case "blocked", "block":
            let value = cleaned(reason) ?? cleaned(message) ?? cleaned(question) ?? ""
            guard !value.isEmpty else { throw LocalModelActionParseError.missingField("reason") }
            return .blocked(id: cleaned(id), reason: value)
        case "cancelled", "canceled", "cancel":
            return .cancelled(id: cleaned(id), reason: cleaned(reason) ?? cleaned(message))
        default:
            throw LocalModelActionParseError.unsupportedType(type)
        }
    }

    private func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedToolName(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "shell", "bash":
            return "shell.exec"
        case "network", "fetch", "webfetch", "web_fetch":
            return "network.fetch"
        default:
            return value
        }
    }
}

public enum LocalModelActionParseError: Error, Sendable, Equatable, LocalizedError {
    case noJSONObject
    case invalidJSON
    case missingField(String)
    case unsupportedType(String)

    public var errorDescription: String? {
        switch self {
        case .noJSONObject:
            return "No JSON action object was found."
        case .invalidJSON:
            return "The JSON action object could not be decoded."
        case .missingField(let field):
            return "The JSON action object is missing `\(field)`."
        case .unsupportedType(let type):
            return "Unsupported local action type `\(type)`."
        }
    }
}

public enum LocalModelActionParser {
    public static func parse(_ text: String) -> Result<LocalModelAction, LocalModelActionParseError> {
        guard let json = extractJSONObject(from: text),
              let data = json.data(using: .utf8) else {
            return .failure(.noJSONObject)
        }
        let actionData = normalizedToolNameTypeData(from: data) ?? data
        do {
            return .success(try JSONDecoder().decode(LocalModelActionEnvelope.self, from: actionData).action())
        } catch let error as LocalModelActionParseError {
            return .failure(error)
        } catch {
            return .failure(.invalidJSON)
        }
    }

    public static func extractJSONObject(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }
        if let fenced = fencedJSONObject(in: trimmed) {
            return fenced
        }
        return firstBalancedJSONObject(in: trimmed)
    }

    private static func fencedJSONObject(in text: String) -> String? {
        let pattern = #"(?s)```(?:json)?\s*(.*?)\s*```"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let fencedContent = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        if fencedContent.hasPrefix("{"), fencedContent.hasSuffix("}") {
            return fencedContent
        }
        return firstBalancedJSONObject(in: fencedContent)
    }

    private static func firstBalancedJSONObject(in text: String) -> String? {
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaping = false

        for index in text.indices {
            let character = text[index]
            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            if character == "\"" {
                inString = true
            } else if character == "{" {
                if depth == 0 {
                    start = index
                }
                depth += 1
            } else if character == "}" {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let start {
                    return String(text[start...index])
                }
            }
        }
        return nil
    }

    private static func normalizedToolNameTypeData(from data: Data) -> Data? {
        guard var object = try? JSONDecoder().decode([String: LocalModelJSONValue].self, from: data),
              let type = object["type"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              type.contains(".") else {
            return nil
        }

        let tool = object["tool"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        object["type"] = .string("tool_call")
        object["tool"] = .string((tool?.isEmpty == false) ? tool! : type)
        if object["arguments"]?.objectValue == nil {
            if let arguments = object["args"]?.objectValue ?? object["parameters"]?.objectValue ?? object["input"]?.objectValue {
                object["arguments"] = .object(arguments)
            } else {
                object["arguments"] = .object(topLevelToolArguments(from: object))
            }
        }
        return try? JSONEncoder().encode(object)
    }

    private static func topLevelToolArguments(from object: [String: LocalModelJSONValue]) -> [String: LocalModelJSONValue] {
        let reservedKeys: Set<String> = [
            "type",
            "id",
            "tool",
            "arguments",
            "args",
            "parameters",
            "input",
            "safety",
            "answer",
            "steps",
            "question",
            "reason",
            "message"
        ]
        return object.filter { !reservedKeys.contains($0.key) }
    }
}

public struct LocalModelReasoningFilter: Sendable {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var buffer = ""
    private var pendingLeadingVisibleText = ""
    private var insideReasoningBlock = false
    private var hasEmittedVisibleText = false
    private var pendingUnavailableLineAfterPromptEcho = false

    public init() {}

    public mutating func process(text: String) -> String {
        guard !text.isEmpty else { return "" }
        buffer += text

        var visible = ""
        while !buffer.isEmpty {
            if insideReasoningBlock {
                if let closeRange = buffer.range(
                    of: Self.closeTag,
                    options: [.caseInsensitive]
                ) {
                    buffer.removeSubrange(buffer.startIndex..<closeRange.upperBound)
                    insideReasoningBlock = false
                    continue
                }
                buffer = String(buffer.suffix(Self.partialTagSuffixLength(in: buffer, tag: Self.closeTag)))
                break
            }

            if let openRange = buffer.range(
                of: Self.openTag,
                options: [.caseInsensitive]
            ) {
                visible += String(buffer[..<openRange.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<openRange.upperBound)
                insideReasoningBlock = true
                continue
            }

            let retained = Self.partialTagSuffixLength(in: buffer, tag: Self.openTag)
            guard retained > 0 else {
                visible += buffer
                buffer.removeAll(keepingCapacity: true)
                break
            }

            let emitEnd = buffer.index(buffer.endIndex, offsetBy: -retained)
            visible += String(buffer[..<emitEnd])
            buffer = String(buffer[emitEnd...])
            break
        }

        return normalizedVisibleText(visible)
    }

    public mutating func flush() -> String {
        defer {
            buffer.removeAll(keepingCapacity: true)
            pendingLeadingVisibleText.removeAll(keepingCapacity: true)
            insideReasoningBlock = false
            pendingUnavailableLineAfterPromptEcho = false
        }

        guard !insideReasoningBlock else { return "" }
        let rawRemainder = pendingLeadingVisibleText + buffer
        let remainder = pendingUnavailableLineAfterPromptEcho
            ? Self.strippingUnavailableLineAfterPromptEcho(from: rawRemainder, allowPending: false).text
            : rawRemainder
        let lowercased = remainder.lowercased()
        if Self.openTag.hasPrefix(lowercased) || Self.closeTag.hasPrefix(lowercased) {
            return ""
        }
        return normalizedVisibleText(remainder)
    }

    public static func visibleText(from text: String) -> String {
        var filter = LocalModelReasoningFilter()
        return filter.process(text: text) + filter.flush()
    }

    private static func partialTagSuffixLength(in text: String, tag: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let lowercasedText = text.lowercased()
        let lowercasedTag = tag.lowercased()
        let maximum = min(lowercasedText.count, max(0, lowercasedTag.count - 1))
        guard maximum > 0 else { return 0 }

        for length in stride(from: maximum, through: 1, by: -1) {
            if lowercasedTag.hasPrefix(String(lowercasedText.suffix(length))) {
                return length
            }
        }
        return 0
    }

    private mutating func normalizedVisibleText(_ text: String) -> String {
        let visible: String
        if hasEmittedVisibleText {
            visible = text
        } else if pendingUnavailableLineAfterPromptEcho {
            let candidate = pendingLeadingVisibleText + text
            let cleaned = Self.strippingUnavailableLineAfterPromptEcho(from: candidate, allowPending: true)
            if cleaned.isPending {
                pendingLeadingVisibleText = candidate
                return ""
            }
            pendingLeadingVisibleText.removeAll(keepingCapacity: true)
            pendingUnavailableLineAfterPromptEcho = false
            visible = Self.trimmingLeadingWhitespace(from: cleaned.text)
        } else {
            let candidate = pendingLeadingVisibleText + text
            let cleaned = Self.strippingLeadingPromptEcho(from: candidate, allowPending: true)
            if cleaned.isPending {
                pendingLeadingVisibleText = candidate
                return ""
            }
            pendingLeadingVisibleText.removeAll(keepingCapacity: true)
            pendingUnavailableLineAfterPromptEcho = cleaned.strippedPromptEcho
            visible = Self.trimmingLeadingWhitespace(from: cleaned.text)
        }
        if !visible.isEmpty {
            hasEmittedVisibleText = true
            pendingUnavailableLineAfterPromptEcho = false
        }
        return visible
    }

    private static func strippingLeadingPromptEcho(from text: String, allowPending: Bool) -> (text: String, isPending: Bool, strippedPromptEcho: Bool) {
        let leadingTrimmed = trimmingLeadingWhitespace(from: text)
        let lowercased = leadingTrimmed.lowercased()
        let promptPrefixes = [
            "local chat mode:",
            "system: local chat mode:",
            "you are astra's private local chat utility."
        ]
        guard promptPrefixes.contains(where: { lowercased.hasPrefix($0) }) else {
            return (text, false, false)
        }

        let completionMarkers = [
            "do not claim that you ran a connector",
            "do not claim you used files"
        ]
        for marker in completionMarkers {
            guard let markerRange = lowercased.range(of: marker) else { continue }
            let lineEnd = lowercased[markerRange.upperBound...].firstIndex(of: "\n") ?? lowercased.endIndex
            let offset = lowercased.distance(from: lowercased.startIndex, to: lineEnd)
            let stripEnd = leadingTrimmed.index(leadingTrimmed.startIndex, offsetBy: offset)
            var remainder = String(leadingTrimmed[stripEnd...])
            remainder = strippingUnavailableLine(from: remainder)
            return (trimmingLeadingWhitespace(from: remainder), false, true)
        }

        if let blankLine = lowercased.range(of: "\n\n") {
            let offset = lowercased.distance(from: lowercased.startIndex, to: blankLine.upperBound)
            let stripEnd = leadingTrimmed.index(leadingTrimmed.startIndex, offsetBy: offset)
            return (trimmingLeadingWhitespace(from: String(leadingTrimmed[stripEnd...])), false, true)
        }

        return allowPending ? ("", true, false) : ("", false, true)
    }

    private static func strippingUnavailableLineAfterPromptEcho(from text: String, allowPending: Bool) -> (text: String, isPending: Bool) {
        let trimmed = trimmingLeadingWhitespace(from: text)
        guard trimmed.lowercased().hasPrefix("unavailable in this local chat run:") else {
            return (text, false)
        }
        guard let lineEnd = trimmed.firstIndex(of: "\n") else {
            return allowPending ? ("", true) : ("", false)
        }
        return (trimmingLeadingWhitespace(from: String(trimmed[trimmed.index(after: lineEnd)...])), false)
    }

    private static func strippingUnavailableLine(from text: String) -> String {
        let trimmed = trimmingLeadingWhitespace(from: text)
        guard trimmed.lowercased().hasPrefix("unavailable in this local chat run:") else {
            return trimmed
        }
        guard let lineEnd = trimmed.firstIndex(of: "\n") else {
            return ""
        }
        return trimmingLeadingWhitespace(from: String(trimmed[trimmed.index(after: lineEnd)...]))
    }

    private static func trimmingLeadingWhitespace(from text: String) -> String {
        var start = text.startIndex
        while start < text.endIndex {
            let character = text[start]
            guard character.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                break
            }
            start = text.index(after: start)
        }
        return String(text[start...])
    }
}

public struct LocalModelControlMessage: Codable, Sendable, Equatable {
    public var v: Int
    public var type: String
    public var reason: String?

    public init(v: Int = 1, type: String, reason: String? = nil) {
        self.v = v
        self.type = type
        self.reason = reason
    }

    public static func cancel(reason: String) -> LocalModelControlMessage {
        LocalModelControlMessage(type: "cancel", reason: reason)
    }
}

public struct LocalModelSmokeReport: Codable, Sendable, Equatable {
    public var status: String
    public var backend: String
    public var model: String?
    public var message: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var durationMs: Int?
    public var firstTokenLatencyMs: Int?
    public var tokensPerSecond: Double?

    public init(
        status: String,
        backend: String,
        model: String? = nil,
        message: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        durationMs: Int? = nil,
        firstTokenLatencyMs: Int? = nil,
        tokensPerSecond: Double? = nil
    ) {
        self.status = status
        self.backend = backend
        self.model = model
        self.message = message
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.durationMs = durationMs
        self.firstTokenLatencyMs = firstTokenLatencyMs
        self.tokensPerSecond = tokensPerSecond
    }
}

public struct LocalModelListEntry: Codable, Sendable, Equatable {
    public var model: String
    public var displayName: String
    public var directory: String
    public var selected: Bool

    public init(model: String, displayName: String, directory: String, selected: Bool = false) {
        self.model = model
        self.displayName = displayName
        self.directory = directory
        self.selected = selected
    }
}

public struct LocalModelListReport: Codable, Sendable, Equatable {
    public var status: String
    public var backend: String
    public var models: [LocalModelListEntry]
    public var message: String?

    public init(
        status: String,
        backend: String,
        models: [LocalModelListEntry],
        message: String? = nil
    ) {
        self.status = status
        self.backend = backend
        self.models = models
        self.message = message
    }
}

public enum LocalModelListScanner {
    private static let knownModelsByDirectoryName: [String: (model: String, displayName: String)] = [
        "Qwen3-4B-MLX-4bit": ("Qwen/Qwen3-4B-MLX-4bit", "Qwen 3 4B"),
        "Qwen3-8B-MLX-4bit": ("Qwen/Qwen3-8B-MLX-4bit", "Qwen 3 8B"),
        "Llama-3.2-3B-Instruct-4bit": ("mlx-community/Llama-3.2-3B-Instruct-4bit", "Llama 3.2 3B")
    ]
    private static let curatedModelOrder = [
        "Qwen/Qwen3-4B-MLX-4bit": 0,
        "Qwen/Qwen3-8B-MLX-4bit": 1,
        "mlx-community/Llama-3.2-3B-Instruct-4bit": 2
    ]

    public static func scan(
        modelsRoot: String?,
        selectedModelDirectory: String?,
        backend: String,
        fileManager: FileManager = .default
    ) -> LocalModelListReport {
        let directories = candidateDirectories(
            modelsRoot: modelsRoot,
            selectedModelDirectory: selectedModelDirectory,
            fileManager: fileManager
        )
        let selectedPath = standardizedPath(selectedModelDirectory)
        let entries = directories.compactMap { directory -> LocalModelListEntry? in
            guard isRunnableModelDirectory(directory, fileManager: fileManager) else { return nil }
            let path = standardizedPath(directory) ?? directory
            let directoryName = URL(fileURLWithPath: path).lastPathComponent
            let known = knownModelsByDirectoryName[directoryName]
            let model = known?.model ?? modelID(from: path, fileManager: fileManager) ?? directoryName
            let displayName = known?.displayName ?? directoryName
            return LocalModelListEntry(
                model: model,
                displayName: displayName,
                directory: path,
                selected: selectedPath == path
            )
        }.sorted(by: compareModelListEntries)

        return LocalModelListReport(
            status: "ok",
            backend: backend,
            models: entries,
            message: entries.isEmpty ? "No installed local MLX models were found." : nil
        )
    }

    private static func candidateDirectories(
        modelsRoot: String?,
        selectedModelDirectory: String?,
        fileManager: FileManager
    ) -> [String] {
        var seen = Set<String>()
        var directories: [String] = []

        func append(_ path: String?) {
            guard let standardized = standardizedPath(path),
                  seen.insert(standardized).inserted else {
                return
            }
            directories.append(standardized)
        }

        if let root = standardizedPath(modelsRoot),
           let children = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
           ) {
            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    append(child.path)
                }
            }
        }
        append(selectedModelDirectory)
        return directories
    }

    private static func isRunnableModelDirectory(_ directory: String, fileManager: FileManager) -> Bool {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        let hasConfig = fileManager.fileExists(atPath: url.appendingPathComponent("config.json").path)
        let hasTokenizer = [
            "tokenizer.json",
            "tokenizer.model",
            "tokenizer_config.json"
        ].contains { fileManager.fileExists(atPath: url.appendingPathComponent($0).path) }
        let hasWeights = (try? fileManager.contentsOfDirectory(atPath: directory).contains {
            $0.hasSuffix(".safetensors")
        }) ?? false
        return hasConfig
            && hasTokenizer
            && hasWeights
            && !isUnsupportedForTextRuntime(
                configURL: url.appendingPathComponent("config.json"),
                fileManager: fileManager
            )
    }

    private static func modelID(from directory: String, fileManager: FileManager) -> String? {
        let configURL = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("config.json")
        guard let data = fileManager.contents(atPath: configURL.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object["_name_or_path"] as? String)
            ?? (object["model_id"] as? String)
            ?? (object["name_or_path"] as? String)
    }

    private static func compareModelListEntries(_ lhs: LocalModelListEntry, _ rhs: LocalModelListEntry) -> Bool {
        let lhsPriority = curatedModelOrder[lhs.model] ?? Int.max
        let rhsPriority = curatedModelOrder[rhs.model] ?? Int.max
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        let displayComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if displayComparison != .orderedSame {
            return displayComparison == .orderedAscending
        }
        return lhs.directory.localizedStandardCompare(rhs.directory) == .orderedAscending
    }

    private static func isUnsupportedForTextRuntime(configURL: URL, fileManager: FileManager) -> Bool {
        guard let data = fileManager.contents(atPath: configURL.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if object["vision_config"] is [String: Any] {
            return true
        }
        let modelType = (object["model_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard modelType?.hasPrefix("gemma4") == true else {
            return false
        }
        return true
    }

    private static func standardizedPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }
}

public struct LocalModelProtocolEnvelope: Codable, Sendable, Equatable {
    public var v: Int
    public var type: String
    public var sessionID: String?
    public var model: String?
    public var text: String?
    public var summary: String?
    public var message: String?
    public var name: String?
    public var id: String?
    public var inputSummary: String?
    public var content: String?
    public var path: String?
    public var kind: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var costUSD: Double?
    public var durationMs: Int?
    public var turns: Int?
    public var phase: String?
    public var activeMemoryBytes: Int?
    public var peakMemoryBytes: Int?
    public var cacheMemoryBytes: Int?
    public var memoryLimitBytes: Int?
    public var cacheLimitBytes: Int?
    public var memoryBudgetBytes: Int?
    public var promptTokensPerSecond: Double?
    public var tokensPerSecond: Double?
    public var firstTokenLatencyMs: Int?

    public init(
        v: Int = 1,
        type: String,
        sessionID: String? = nil,
        model: String? = nil,
        text: String? = nil,
        summary: String? = nil,
        message: String? = nil,
        name: String? = nil,
        id: String? = nil,
        inputSummary: String? = nil,
        content: String? = nil,
        path: String? = nil,
        kind: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        costUSD: Double? = nil,
        durationMs: Int? = nil,
        turns: Int? = nil,
        phase: String? = nil,
        activeMemoryBytes: Int? = nil,
        peakMemoryBytes: Int? = nil,
        cacheMemoryBytes: Int? = nil,
        memoryLimitBytes: Int? = nil,
        cacheLimitBytes: Int? = nil,
        memoryBudgetBytes: Int? = nil,
        promptTokensPerSecond: Double? = nil,
        tokensPerSecond: Double? = nil,
        firstTokenLatencyMs: Int? = nil
    ) {
        self.v = v
        self.type = type
        self.sessionID = sessionID
        self.model = model
        self.text = text
        self.summary = summary
        self.message = message
        self.name = name
        self.id = id
        self.inputSummary = inputSummary
        self.content = content
        self.path = path
        self.kind = kind
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.durationMs = durationMs
        self.turns = turns
        self.phase = phase
        self.activeMemoryBytes = activeMemoryBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.cacheMemoryBytes = cacheMemoryBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.cacheLimitBytes = cacheLimitBytes
        self.memoryBudgetBytes = memoryBudgetBytes
        self.promptTokensPerSecond = promptTokensPerSecond
        self.tokensPerSecond = tokensPerSecond
        self.firstTokenLatencyMs = firstTokenLatencyMs
    }
}

public enum LocalModelProtocolParser {
    public static func agentEvents(from line: String) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(LocalModelProtocolEnvelope.self, from: data) else {
            return []
        }

        switch envelope.type {
        case "started", "session_started":
            return [.started(sessionID: envelope.sessionID, model: envelope.model)]
        case "thinking":
            return envelope.text.map { [.thinking(text: $0)] } ?? []
        case "text", "text_delta", "message_delta":
            return envelope.text.map { [.text(text: $0)] } ?? []
        case "tool_use", "tool_request":
            guard let name = envelope.name, let id = envelope.id else { return [] }
            return [.toolUse(name: name, id: id, inputSummary: envelope.inputSummary)]
        case "tool_result":
            guard let id = envelope.id else { return [] }
            return [.toolResult(id: id, content: envelope.content ?? "")]
        case "file_change":
            guard let path = envelope.path, let kind = envelope.kind else { return [] }
            return [.fileChange(path: path, kind: kind, summary: envelope.summary)]
        case "permission_requested":
            guard let name = envelope.name else { return [] }
            return [.permissionRequested(tool: name, reason: envelope.message ?? envelope.summary ?? "Local model requested permission.")]
        case "phase", "progress":
            return [.thinking(text: envelope.message ?? envelope.summary ?? envelope.phase.map { "Local MLX \($0)." } ?? "Local MLX is working.")]
        case "memory", "memory_telemetry":
            return [.diagnostic(kind: "local_model.memory", message: memorySummary(from: envelope))]
        case "stats", "usage":
            return [.stats(
                inputTokens: envelope.inputTokens ?? 0,
                outputTokens: envelope.outputTokens ?? 0,
                costUSD: envelope.costUSD,
                durationMs: envelope.durationMs,
                turns: envelope.turns
            )]
        case "completed", "done":
            let summary = (envelope.summary ?? envelope.text).map {
                LocalModelReasoningFilter.visibleText(from: $0)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return [.completed(summary: summary?.isEmpty == true ? nil : summary)]
        case "cancelled", "canceled":
            return [.diagnostic(
                kind: "local_model.cancelled",
                message: envelope.message ?? envelope.summary ?? "Local MLX run cancelled."
            )]
        case "failed", "error":
            return [.failed(message: envelope.message ?? envelope.summary ?? "Local model helper failed.")]
        default:
            return [.unknown(provider: AgentRuntimeID.localMLX.rawValue, type: envelope.type, raw: line)]
        }
    }

    private static func memorySummary(from envelope: LocalModelProtocolEnvelope) -> String {
        let phase = envelope.phase.map { "phase: \($0)" }
        let message = (envelope.message ?? envelope.summary).map { "message: \($0)" }
        let parts = [
            phase,
            message,
            byteSummary("active", envelope.activeMemoryBytes),
            byteSummary("peak", envelope.peakMemoryBytes),
            byteSummary("cache", envelope.cacheMemoryBytes),
            byteSummary("memory limit", envelope.memoryLimitBytes),
            byteSummary("cache limit", envelope.cacheLimitBytes),
            byteSummary("budget", envelope.memoryBudgetBytes)
        ].compactMap { $0 }
        return parts.isEmpty ? "Local MLX memory telemetry." : "Local MLX memory: \(parts.joined(separator: " | "))"
    }

    private static func byteSummary(_ label: String, _ value: Int?) -> String? {
        guard let value else { return nil }
        return "\(label): \(formatBytes(value))"
    }

    private static func formatBytes(_ bytes: Int) -> String {
        guard bytes >= 0 else { return "\(bytes) B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[index])
    }
}
