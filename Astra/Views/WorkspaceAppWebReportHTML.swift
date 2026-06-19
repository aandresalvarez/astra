import Foundation

/// Builds a self-contained, CSP-locked HTML document for a `webView` / `htmlReport`
/// widget from the app's OWN data (every cell escaped). The Content-Security-Policy
/// `default-src 'none'` blocks all network + scripts; only inline styles are allowed,
/// and there is no `<script>`. Pure + value-typed so the sandboxed WKWebView stays a
/// dumb renderer and the document assembly is unit-tested.
enum WorkspaceAppWebReportHTML {
    static func html(
        title: String,
        columns: [String],
        rows: [[String: WorkspaceAppStorageValue]]
    ) -> String {
        let head = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline';">
        <style>
        :root { color-scheme: light dark; }
        body { font: 13px -apple-system, system-ui, sans-serif; margin: 16px; color: #1d1d1f; background: transparent; }
        @media (prefers-color-scheme: dark) { body { color: #f5f5f7; } th { color: #9b9b9b; } th, td { border-color: #333; } }
        h1 { font-size: 15px; margin: 0 0 12px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid #e5e5e5; font-size: 12px; }
        th { color: #666; font-weight: 600; }
        tr:nth-child(even) td { background: rgba(127,127,127,0.06); }
        .empty { color: #888; font-style: italic; }
        </style></head><body>
        """
        var body = "<h1>\(escape(title))</h1>"
        if columns.isEmpty || rows.isEmpty {
            body += "<p class=\"empty\">No data yet.</p>"
        } else {
            body += "<table><thead><tr>"
            for column in columns { body += "<th>\(escape(column))</th>" }
            body += "</tr></thead><tbody>"
            for row in rows {
                body += "<tr>"
                for column in columns {
                    let value = WorkspaceAppStorageRowActionPresentationBuilder.displayValue(row[column])
                    body += "<td>\(escape(value))</td>"
                }
                body += "</tr>"
            }
            body += "</tbody></table>"
        }
        return head + body + "</body></html>"
    }

    /// HTML-escapes text so app data can never inject markup or break out of a cell.
    static func escape(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&#39;")
        return result
    }
}
