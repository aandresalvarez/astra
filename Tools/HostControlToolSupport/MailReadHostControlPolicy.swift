import Foundation
import MCPServerKit

/// A reader bound by ASTRA to one accepted task/run. The caller can select
/// only a captured account, never a vault service, URL, tenant or live row.
public protocol BrokeredMailReading: AnyObject, Sendable {
    func readMail(_ request: MailReadRequest) throws -> Data
    func cancelPendingReads()
    func closeMailAccess()
}

/// Fixed messages only: provider responses and credential values never
/// become transport error details.
public enum MailReadFailure: Error, Equatable {
    case notApproved, noAccounts, ambiguousAccount, unknownAccount, invalidSnapshot, connectionUnavailable, outputUnavailable

    public var message: String {
        switch self {
        case .notApproved: "Approve Outlook access for this task before reading mail."
        case .noAccounts: "No Outlook account is available to this task."
        case .ambiguousAccount: "More than one captured account matches. Choose its full account ID."
        case .unknownAccount: "That account is not approved for this task."
        case .invalidSnapshot: "This task's captured mail accounts could not be verified."
        case .outputUnavailable: "ASTRA could not save this mail response within the task's output limits."
        case .connectionUnavailable: "This task's mail authorization is unavailable. Reconnect the account and start a new task."
        }
    }
}

public struct MailReadRequest: Equatable, Sendable {
    public enum Operation: String, Sendable { case accounts, folders, search, get }
    public let operation: Operation
    public let account: String?
    public let query: String?
    public let messageID: String?
    public let limit: Int

    public static func parse(_ arguments: [String: Any]) -> Self? {
        guard let raw = arguments["operation"] as? String, let operation = Operation(rawValue: raw) else { return nil }
        var allowed: Set<String> = ["operation"]
        switch operation {
        case .accounts: break
        case .folders: allowed.formUnion(["account", "limit"])
        case .search: allowed.formUnion(["account", "limit", "query"])
        case .get: allowed.formUnion(["account", "message_id"])
        }
        guard Set(arguments.keys).isSubset(of: allowed) else { return nil }
        func text(_ key: String, maximum: Int) -> String? {
            guard let value = arguments[key] as? String, !value.isEmpty,
                  value.utf8.count <= maximum, !value.contains("\0") else { return nil }
            return value
        }
        let account = text("account", maximum: 320)
        guard arguments["account"] == nil || account?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        let query = text("query", maximum: 2_048)
        let messageID = text("message_id", maximum: 4_096)
        guard arguments["query"] == nil || query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              operation != .get || messageID != nil else { return nil }
        var limit = operation == .folders ? 50 : 10
        if let rawLimit = arguments["limit"] {
            guard let value = rawLimit as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 1, value.doubleValue <= Double(operation == .folders ? 100 : 25),
                  value.doubleValue.rounded() == value.doubleValue else { return nil }
            limit = value.intValue
        }
        return Self(operation: operation, account: account, query: query, messageID: messageID, limit: limit)
    }
    public static func arguments(fromCLI arguments: [String]) -> [String: Any]? {
        guard let operation = arguments.first, Operation(rawValue: operation) != nil else { return nil }
        var result: [String: Any] = ["operation": operation]
        let keys = ["--account": "account", "--query": "query", "--message-id": "message_id", "--limit": "limit"]
        var remaining = arguments.dropFirst()
        while let option = remaining.first {
            remaining = remaining.dropFirst()
            guard let key = keys[option], let value = remaining.first, result[key] == nil else { return nil }
            remaining = remaining.dropFirst()
            if key == "limit" {
                guard let limit = Int(value), limit > 0 else { return nil }
                result[key] = min(limit, operation == "folders" ? 100 : 25)
            } else { result[key] = value }
        }
        return parse(result) == nil ? nil : result
    }

}

enum MailReadHostControlPolicy {
    // Both relay transports cap the complete JSON-RPC envelope at 1 MiB.
    // Leave room for JSON string escaping in BOTH the MCP envelope and
    // the file-drop response envelope, plus their metadata.
    static let maximumResponseBytes = 128 * 1_024

    static func handle(arguments: [String: Any], reader: (any BrokeredMailReading)?, configuration: HostControlToolConfiguration) -> MCPServerReply {
        guard let request = MailReadRequest.parse(arguments) else {
            return .error(code: -32602, message: "mail accepts accounts, folders, search or get, with an account selector and bounded operation parameters.")
        }
        guard let reader else {
            return .error(code: -32000, message: "Mail is unavailable on this task's transport. Reconnect through ASTRA; no other account will be used.")
        }
        do {
            let data = try reader.readMail(request)
            guard data.count <= MailReadArtifact.maximumBytes,
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                return .error(code: -32000, message: "The mail response could not be displayed within its limit.")
            }
            let output = data.count <= maximumResponseBytes ? data : try MailReadArtifact.store(data, configuration: configuration)
            guard let text = String(data: output, encoding: .utf8) else { throw MailReadFailure.outputUnavailable }
            return .result(["content": [["type": "text", "text": text]], "isError": false])
        } catch let failure as MailReadFailure {
            return .error(code: -32000, message: failure.message)
        } catch {
            // Provider error bodies can contain credentials. Only the app's
            // structured outcome may supply user-facing detail in future.
            return .error(code: -32000, message: "ASTRA could not read the captured mail account. Check its connection and retry.")
        }
    }

    static let schema: [String: Any] = [
        "name": "mail",
        "description": "Read accounts, folders or messages from this task's approved Outlook accounts. Cannot send, modify or delete mail.",
        "inputSchema": ["type": "object", "properties": [
            "operation": ["type": "string", "enum": ["accounts", "folders", "search", "get"]],
            "account": ["type": "string", "maxLength": 320],
            "query": ["type": "string", "maxLength": 2_048],
            "message_id": ["type": "string", "maxLength": 4_096],
            "limit": ["type": "integer", "minimum": 1, "maximum": 100]
        ], "required": ["operation"], "additionalProperties": false]
    ]
}
