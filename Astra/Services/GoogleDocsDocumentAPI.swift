import Foundation

enum GoogleDocsDocumentAPI {
    struct DocumentSnapshot: Equatable {
        let documentID: String
        let title: String
        let text: String
        let endIndex: Int
    }

    static func readDocument(urlString: String) async -> [String: Any] {
        guard let documentID = documentID(from: urlString) else {
            return unavailable(reason: "document_id_not_found", urlString: urlString)
        }
        guard let token = await accessToken() else {
            return unavailable(reason: "google_docs_auth_unavailable", urlString: urlString)
        }

        do {
            let snapshot = try await fetchDocument(documentID: documentID, token: token)
            return [
                "ok": true,
                "documentID": documentID,
                "title": snapshot.title,
                "text": snapshot.text,
                "textLength": snapshot.text.count,
                "apiPath": "google_docs_api"
            ]
        } catch {
            return unavailable(
                reason: apiFailureReason(error),
                urlString: urlString,
                statusCode: apiStatusCode(error)
            )
        }
    }

    static func replaceDocument(urlString: String, text: String, verifyText: String?) async -> [String: Any] {
        guard let documentID = documentID(from: urlString) else {
            return unavailable(reason: "document_id_not_found", urlString: urlString)
        }
        guard let token = await accessToken() else {
            return unavailable(reason: "google_docs_auth_unavailable", urlString: urlString)
        }

        do {
            let before = try await fetchDocument(documentID: documentID, token: token)
            var requests: [[String: Any]] = []
            let deleteEndIndex = max(1, before.endIndex - 1)
            if deleteEndIndex > 1 {
                requests.append([
                    "deleteContentRange": [
                        "range": [
                            "startIndex": 1,
                            "endIndex": deleteEndIndex
                        ]
                    ]
                ])
            }
            requests.append([
                "insertText": [
                    "location": ["index": 1],
                    "text": text
                ]
            ])

            try await batchUpdate(documentID: documentID, token: token, requests: requests)
            let after = try await fetchDocument(documentID: documentID, token: token)
            let verificationText = verifyText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let verified: Bool
            if let verificationText, !verificationText.isEmpty {
                verified = after.text.localizedCaseInsensitiveContains(verificationText)
            } else {
                verified = after.text.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard verified else {
                return [
                    "ok": false,
                    "error": "google_docs_safe_edit_verification_failed",
                    "documentID": documentID,
                    "title": after.title,
                    "textLength": after.text.count,
                    "verifyTextLength": verificationText?.count ?? 0,
                    "apiPath": "google_docs_api"
                ]
            }

            return [
                "ok": true,
                "documentID": documentID,
                "title": after.title,
                "textLength": after.text.count,
                "verifyTextLength": verificationText?.count ?? 0,
                "verified": true,
                "apiPath": "google_docs_api"
            ]
        } catch {
            return unavailable(
                reason: apiFailureReason(error),
                urlString: urlString,
                statusCode: apiStatusCode(error)
            ).merging([
                "textLength": text.count,
                "verifyTextLength": verifyText?.count ?? 0
            ], uniquingKeysWith: { current, _ in current })
        }
    }

    static func documentID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              url.host?.lowercased() == "docs.google.com" else {
            return nil
        }
        let components = url.pathComponents
        guard let markerIndex = components.firstIndex(of: "d"),
              components.indices.contains(markerIndex + 1) else {
            return nil
        }
        let documentID = components[markerIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return documentID.isEmpty ? nil : documentID
    }

    static func extractDocumentSnapshot(documentID: String, object: [String: Any]) -> DocumentSnapshot? {
        let title = object["title"] as? String ?? ""
        guard let body = object["body"] as? [String: Any],
              let content = body["content"] as? [[String: Any]] else {
            return nil
        }

        var text = ""
        var endIndex = 1
        for block in content {
            if let blockEndIndex = intValue(block["endIndex"]) {
                endIndex = max(endIndex, blockEndIndex)
            }
            guard let paragraph = block["paragraph"] as? [String: Any],
                  let elements = paragraph["elements"] as? [[String: Any]] else {
                continue
            }
            for element in elements {
                if let elementEndIndex = intValue(element["endIndex"]) {
                    endIndex = max(endIndex, elementEndIndex)
                }
                guard let textRun = element["textRun"] as? [String: Any],
                      let content = textRun["content"] as? String else {
                    continue
                }
                text += content
            }
        }

        return DocumentSnapshot(
            documentID: documentID,
            title: title,
            text: text,
            endIndex: endIndex
        )
    }

    private static func fetchDocument(documentID: String, token: String) async throws -> DocumentSnapshot {
        let encodedID = documentID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? documentID
        guard let url = URL(string: "https://docs.googleapis.com/v1/documents/\(encodedID)") else {
            throw APIError.invalidURL
        }
        let object = try await googleAPIRequest(url: url, token: token, method: "GET", body: nil)
        guard let snapshot = extractDocumentSnapshot(documentID: documentID, object: object) else {
            throw APIError.invalidResponse
        }
        return snapshot
    }

    private static func batchUpdate(documentID: String, token: String, requests: [[String: Any]]) async throws {
        let encodedID = documentID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? documentID
        guard let url = URL(string: "https://docs.googleapis.com/v1/documents/\(encodedID):batchUpdate") else {
            throw APIError.invalidURL
        }
        let body = try JSONSerialization.data(withJSONObject: ["requests": requests])
        _ = try await googleAPIRequest(url: url, token: token, method: "POST", body: body)
    }

    private static func googleAPIRequest(url: URL, token: String, method: String, body: Data?) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            throw APIError.httpStatus(statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        return object
    }

    private static func accessToken(environment: [String: String] = ProcessInfo.processInfo.environment) async -> String? {
        if let token = environment["GOOGLE_OAUTH_ACCESS_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }

        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gcloud", "auth", "print-access-token"]
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let token = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return token.isEmpty ? nil : token
            } catch {
                return nil
            }
        }.value
    }

    private static func unavailable(reason: String, urlString: String, statusCode: Int? = nil) -> [String: Any] {
        var result: [String: Any] = [
            "ok": false,
            "error": "google_docs_safe_edit_unavailable",
            "safeEditUnavailable": true,
            "reason": reason,
            "url": BrowserFlightPageSnapshot.redactedURLString(urlString),
            "hint": "ASTRA could not use a safe Google Docs API path. Do not fall back to raw Cmd+A/Delete or manual full-document keyboard replacement."
        ]
        if let statusCode {
            result["statusCode"] = statusCode
        }
        return result
    }

    private static func apiFailureReason(_ error: Error) -> String {
        switch error {
        case APIError.httpStatus(let statusCode):
            return "google_docs_api_http_\(statusCode)"
        case APIError.invalidResponse:
            return "google_docs_api_invalid_response"
        case APIError.invalidURL:
            return "google_docs_api_invalid_url"
        default:
            return "google_docs_api_request_failed"
        }
    }

    private static func apiStatusCode(_ error: Error) -> Int? {
        guard case APIError.httpStatus(let statusCode) = error else { return nil }
        return statusCode
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private enum APIError: Error {
        case invalidURL
        case invalidResponse
        case httpStatus(Int)
    }
}
