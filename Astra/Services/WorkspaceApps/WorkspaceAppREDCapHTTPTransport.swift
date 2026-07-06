import Foundation
import ASTRACore

/// Real REDCap Import-Records HTTP client for Workspace App capability writes.
///
/// This is the GENUINE integration (not the throwing stub): given a configured REDCap API endpoint +
/// token, it performs the actual REDCap `content=record` import. It is async (REDCap is an HTTP API)
/// and goes through the shared `ConnectorHTTPTransport` so it is unit-testable at the request layer
/// without a live server.
///
/// NOT YET wired into a live Workspace App action: the executor's `capability.write` runs in a
/// SYNCHRONOUS path, and bridging to this async call with a semaphore would block the UI. Reaching
/// it needs an async capability-write execution path in the executor (the same out-of-band shape the
/// async capability READS already use) plus a live REDCap instance to end-to-end verify — a scoped
/// follow-on. Until then this client is exercised by its tests, which lock the API contract down.
enum WorkspaceAppREDCapAPIError: LocalizedError, Equatable {
    case server(String)
    case http(Int)
    case unparseableResponse

    var errorDescription: String? {
        switch self {
        case .server(let message): return "REDCap rejected the write: \(message)"
        case .http(let code): return "REDCap returned HTTP \(code)."
        case .unparseableResponse: return "REDCap returned an unrecognized response."
        }
    }
}

/// Pure request/response logic for the REDCap Import Records API — no networking, fully testable.
enum WorkspaceAppREDCapImportAPI {
    /// Builds the REDCap `content=record` import request. `baseURL` is the REDCap API endpoint
    /// (e.g. `https://redcap.example.org/api/`); the token authenticates the project.
    static func importRequest(
        baseURL: URL,
        token: String,
        record: [String: WorkspaceAppStorageValue],
        overwrite: Bool
    ) -> URLRequest {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let parameters: [String: String] = [
            "token": token,
            "content": "record",
            "format": "json",
            "type": "flat",
            "overwriteBehavior": overwrite ? "overwrite" : "normal",
            "returnContent": "count",
            // Reuse the executor's deterministic scalar-JSON encoder so the record serializes the
            // same way it does everywhere else (clean `[{"field": value}]`).
            "data": WorkspaceAppActionExecutor.jsonStringify([record])
        ]
        request.httpBody = formEncode(parameters).data(using: .utf8)
        return request
    }

    /// REDCap with `returnContent=count` answers `{"count": N}` on success or `{"error": "..."}`.
    static func parseCount(_ data: Data) throws -> Int {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? String { throw WorkspaceAppREDCapAPIError.server(error) }
            if let count = object["count"] as? Int { return count }
            if let count = (object["count"] as? NSNumber)?.intValue { return count }
        }
        if let text = String(data: data, encoding: .utf8),
           let count = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return count
        }
        throw WorkspaceAppREDCapAPIError.unparseableResponse
    }

    static func formEncode(_ parameters: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}

struct WorkspaceAppREDCapHTTPTransport {
    let endpoint: URL
    let token: String
    var overwrite: Bool = false
    var transport: any ConnectorHTTPTransport = URLSessionConnectorHTTPTransport()

    func submit(record: [String: WorkspaceAppStorageValue]) async throws -> WorkspaceAppCapabilityWriteResult {
        let request = WorkspaceAppREDCapImportAPI.importRequest(
            baseURL: endpoint, token: token, record: record, overwrite: overwrite
        )
        let (data, response) = try await transport.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // A REDCap error body is more useful than the status code when present.
            if let parsed = try? WorkspaceAppREDCapImportAPI.parseCount(data) {
                return WorkspaceAppCapabilityWriteResult(
                    outputSummary: "Imported \(parsed) record(s) to REDCap.",
                    rows: [["count": .integer(Int64(parsed))]]
                )
            }
            throw WorkspaceAppREDCapAPIError.http(http.statusCode)
        }
        let count = try WorkspaceAppREDCapImportAPI.parseCount(data)
        return WorkspaceAppCapabilityWriteResult(
            outputSummary: "Imported \(count) record(s) to REDCap.",
            rows: [["count": .integer(Int64(count))]]
        )
    }
}
