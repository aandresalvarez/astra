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
        return document(body)
    }

    /// A `chartComposite` renderer: an inline-SVG-free, CSS-bar chart from pre-aggregated
    /// bars (label + proportional fraction + display value). No JS, same locked-down CSP
    /// as the table report — a richer visual style than the native row widgets.
    static func chartHTML(
        title: String,
        bars: [WorkspaceAppChartPresentation.Bar]
    ) -> String {
        var body = "<h1>\(escape(title))</h1>"
        if bars.isEmpty {
            body += "<p class=\"empty\">No data yet.</p>"
        } else {
            body += "<div class=\"chart\">"
            for bar in bars {
                let pct = max(0, min(100, Int((bar.fraction * 100).rounded())))
                body += "<div class=\"row\">"
                body += "<div class=\"lbl\">\(escape(bar.label))</div>"
                body += "<div class=\"track\"><div class=\"bar\" style=\"width:\(pct)%\"></div></div>"
                body += "<div class=\"val\">\(escape(bar.displayValue))</div>"
                body += "</div>"
            }
            body += "</div>"
        }
        return document(body)
    }

    /// Wraps body HTML in the shared, CSP-locked document shell (no script, no network).
    private static func document(_ body: String) -> String {
        """
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
        .chart { display: flex; flex-direction: column; gap: 8px; }
        .row { display: flex; align-items: center; gap: 8px; font-size: 12px; }
        .lbl { width: 32%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .track { flex: 1; background: rgba(127,127,127,0.12); border-radius: 4px; height: 14px; }
        .bar { height: 14px; border-radius: 4px; background: #4a7ba6; min-width: 2px; }
        .val { width: 48px; text-align: right; color: #666; }
        </style></head><body>
        \(body)
        </body></html>
        """
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
