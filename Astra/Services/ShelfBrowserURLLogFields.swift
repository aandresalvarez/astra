import Foundation

enum ShelfBrowserURLLogFields {
    static func fields(for url: URL, prefix: String = "url") -> [String: String] {
        var fields: [String: String] = [
            "\(prefix)_kind": url.isFileURL ? "file" : (url.scheme ?? "unknown")
        ]

        if let host = url.host, !host.isEmpty {
            fields["\(prefix)_host"] = host
        }

        let fileName = url.lastPathComponent
        if !fileName.isEmpty {
            fields["\(prefix)_file"] = fileName
        }

        let ext = url.pathExtension
        if !ext.isEmpty {
            fields["\(prefix)_ext"] = ext
        }

        return fields
    }

    static func fields(for urlString: String, prefix: String = "url") -> [String: String] {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ["\(prefix)_kind": "empty"]
        }

        guard let url = URL(string: trimmed) else {
            return [
                "\(prefix)_kind": "unparseable",
                "\(prefix)_length": String(trimmed.count)
            ]
        }

        return fields(for: url, prefix: prefix)
    }
}
