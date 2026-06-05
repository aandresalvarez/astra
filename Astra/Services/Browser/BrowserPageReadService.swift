import Foundation

enum BrowserPageReadService {
    static let defaultLimit = 50_000
    static let defaultChunkSize = 8_000

    static func normalizedLimit(_ value: Int?) -> Int {
        max(1_000, min(value ?? defaultLimit, 250_000))
    }

    static func normalizedChunkSize(_ value: Int?) -> Int {
        max(1_000, min(value ?? defaultChunkSize, 32_000))
    }

    static func normalizedFormat(_ value: String?) -> String {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch normalized {
        case "markdown", "md":
            return "markdown"
        case "json":
            return "json"
        default:
            return "text"
        }
    }

    static func response(
        url: String,
        title: String,
        engine: String,
        backend: String,
        format: String?,
        limit: Int?,
        chunkSize: Int?,
        frames rawFrames: [[String: Any]],
        warnings rawWarnings: [String] = [],
        diagnostics: [String: Any] = [:]
    ) -> [String: Any] {
        let normalizedFormat = normalizedFormat(format)
        let contentLimit = normalizedLimit(limit)
        let normalizedChunkSize = normalizedChunkSize(chunkSize)
        let frames = rawFrames.enumerated().map { index, frame in
            normalizeFrame(frame, index: index)
        }
        var warnings = rawWarnings
        var hasPartialFrame = false
        var hasReadableFrame = false
        var anyFrameTruncated = false

        for frame in frames {
            let accessible = boolValue(frame["accessible"])
            let text = frame["text"] as? String ?? ""
            if accessible && !text.isEmpty {
                hasReadableFrame = true
            }
            if !accessible {
                hasPartialFrame = true
            }
            if boolValue(frame["truncated"]) {
                anyFrameTruncated = true
            }
        }

        if frames.isEmpty {
            warnings.append("No readable frame reports were returned.")
        }
        if anyFrameTruncated {
            warnings.append("One or more frame reads were truncated.")
        }

        let combinedResult = combinedContent(
            frames: frames,
            pageTitle: title,
            pageURL: url,
            format: normalizedFormat
        )
        warnings.append(contentsOf: combinedResult.warnings)
        let combined = combinedResult.text
        let limitedContent: String
        let combinedTruncated: Bool
        if combined.count > contentLimit {
            limitedContent = String(combined.prefix(contentLimit))
            combinedTruncated = true
        } else {
            limitedContent = combined
            combinedTruncated = false
        }

        if combinedTruncated {
            warnings.append("Combined page content exceeded the requested limit.")
        }

        let coverage: String
        if !hasReadableFrame {
            coverage = "unknown"
        } else if hasPartialFrame || anyFrameTruncated || combinedTruncated || !warnings.isEmpty {
            // Warnings intentionally downgrade coverage. Canvas-heavy surfaces such as
            // Google Workspace editors can be readable through helpers while still being
            // incomplete through generic DOM/AX page reads.
            coverage = "partial"
        } else {
            coverage = "full"
        }

        var response: [String: Any] = [
            "ok": true,
            "url": url,
            "title": title,
            "engine": engine,
            "backend": backend,
            "format": normalizedFormat,
            "coverage": coverage,
            "truncated": combinedTruncated || anyFrameTruncated,
            "content": limitedContent,
            "chunks": chunks(limitedContent, chunkSize: normalizedChunkSize),
            "frames": frames,
            "frameCount": frames.count,
            "readableFrameCount": frames.filter { boolValue($0["accessible"]) && !(($0["text"] as? String ?? "").isEmpty) }.count,
            "warnings": Array(Set(warnings)).sorted(),
            "limit": contentLimit,
            "chunkSize": normalizedChunkSize
        ]

        if !diagnostics.isEmpty {
            response["diagnostics"] = diagnostics
        }
        return response
    }

    static func responseFromSnapshot(
        _ snapshot: [String: Any],
        engine: String,
        backend: String,
        format: String?,
        limit: Int?,
        chunkSize: Int?,
        warnings: [String] = [],
        diagnostics: [String: Any] = ["source": "snapshot"]
    ) -> [String: Any] {
        let text = snapshot["text"] as? String ?? ""
        let frame: [String: Any] = [
            "frameID": "main",
            "url": snapshot["url"] as? String ?? "",
            "title": snapshot["title"] as? String ?? "",
            "text": text,
            "textLength": text.count,
            "returnedTextLength": text.count,
            "accessible": !text.isEmpty,
            "source": "snapshot"
        ]
        return response(
            url: snapshot["url"] as? String ?? "",
            title: snapshot["title"] as? String ?? "",
            engine: engine,
            backend: backend,
            format: format,
            limit: limit,
            chunkSize: chunkSize,
            frames: [frame],
            warnings: warnings,
            diagnostics: diagnostics
        )
    }

    private static func normalizeFrame(_ frame: [String: Any], index: Int) -> [String: Any] {
        let text = stringValue(frame["text"])
        let textLength = intValue(frame["textLength"]) ?? text.count
        var normalized: [String: Any] = [
            "frameID": stringValue(frame["frameID"]).isEmpty ? "frame-\(index)" : stringValue(frame["frameID"]),
            "url": stringValue(frame["url"]),
            "title": stringValue(frame["title"]),
            "text": text,
            "textLength": textLength,
            "returnedTextLength": text.count,
            "truncated": boolValue(frame["truncated"]),
            "accessible": frame["accessible"] == nil ? !text.isEmpty : boolValue(frame["accessible"]),
            "source": stringValue(frame["source"]).isEmpty ? "unknown" : stringValue(frame["source"])
        ]
        if let parentFrameID = frame["parentFrameID"] as? String, !parentFrameID.isEmpty {
            normalized["parentFrameID"] = parentFrameID
        }
        if let childFrames = frame["childFrames"] as? [[String: Any]] {
            normalized["childFrames"] = childFrames
        }
        if let warnings = frame["warnings"] as? [String], !warnings.isEmpty {
            normalized["warnings"] = warnings
        }
        if let error = frame["error"] as? String, !error.isEmpty {
            normalized["error"] = error
        }
        return normalized
    }

    private static func combinedContent(
        frames: [[String: Any]],
        pageTitle: String,
        pageURL: String,
        format: String
    ) -> (text: String, warnings: [String]) {
        let readableFrames = frames.filter { boolValue($0["accessible"]) && !(($0["text"] as? String ?? "").isEmpty) }
        guard !readableFrames.isEmpty else { return ("", []) }

        let textContent = readableFrames.enumerated().map { index, frame in
            let title = frame["title"] as? String ?? ""
            let url = frame["url"] as? String ?? ""
            let text = frame["text"] as? String ?? ""
            if format == "markdown" {
                let heading = index == 0 ? "# \(title.isEmpty ? "Page" : title)" : "## Frame \(index + 1): \(title.isEmpty ? url : title)"
                let source = url.isEmpty ? "" : "\n\nSource: \(url)"
                return "\(heading)\(source)\n\n\(text)"
            }
            let heading = index == 0 ? "Page: \(title.isEmpty ? url : title)" : "Frame \(index + 1): \(title.isEmpty ? url : title)"
            return "\(heading)\n\(url)\n\n\(text)"
        }.joined(separator: "\n\n---\n\n")

        if format == "json" {
            let object: [String: Any] = [
                "title": pageTitle,
                "url": pageURL,
                "frames": readableFrames.map { frame in
                    [
                        "title": frame["title"] as? String ?? "",
                        "url": frame["url"] as? String ?? "",
                        "text": frame["text"] as? String ?? ""
                    ]
                }
            ]
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                return (string, [])
            }
            return (textContent, ["Requested JSON format unavailable; returned text instead."])
        }

        return (textContent, [])
    }

    private static func chunks(_ text: String, chunkSize: Int) -> [[String: Any]] {
        guard !text.isEmpty else { return [] }
        var result: [[String: Any]] = []
        var start = text.startIndex
        var index = 0
        while start < text.endIndex {
            let end = text.index(start, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            result.append([
                "index": index,
                "text": String(text[start..<end])
            ])
            index += 1
            start = end
        }
        return result
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["true", "1", "yes"].contains(string.lowercased())
        }
        return false
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        return ""
    }
}
