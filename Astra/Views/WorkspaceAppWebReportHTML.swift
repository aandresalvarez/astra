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

    /// A `chartInteractive` renderer: the ONLY renderer that runs JavaScript, and only a
    /// Swift-authored, vetted script (below) — never model/user code. The bar data is handed
    /// over as an escaped JSON **data island** (`<script type="application/json">`), so a
    /// malicious cell value cannot break out into an executable context; the script reads it
    /// with `JSON.parse` and writes every data-derived string with `textContent` (never
    /// `innerHTML`). CSP still blocks all network (`default-src 'none'`, no `connect-src`),
    /// there is no JS↔native bridge, and `baseURL` is nil — so the script can render an
    /// interactive chart but can neither exfiltrate data nor escape the sandbox.
    static func interactiveChartHTML(
        title: String,
        bars: [WorkspaceAppChartPresentation.Bar]
    ) -> String {
        let island = scriptSafeJSON(chartDataJSON(bars: bars))
        let body = """
        <h1>\(escape(title))</h1>
        <div id="chart" class="ichart"></div>
        <div id="tip" class="tip" hidden></div>
        <script type="application/json" id="astra-chart-data">\(island)</script>
        <script>\(interactiveChartScript)</script>
        """
        return interactiveDocument(body)
    }

    /// JSON for the data island: a fixed `{ "bars": [{label,value,display}] }` shape encoded
    /// by Swift (so values are properly JSON-escaped). Never interpolates raw cell strings.
    private static func chartDataJSON(bars: [WorkspaceAppChartPresentation.Bar]) -> String {
        struct Item: Encodable { let label: String; let value: Double; let display: String }
        let payload = ["bars": bars.map { Item(label: $0.label, value: $0.value, display: $0.displayValue) }]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload), let json = String(data: data, encoding: .utf8) else {
            return "{\"bars\":[]}"
        }
        return json
    }

    /// Neutralize a JSON string for embedding inside a `<script type="application/json">`
    /// block: escaping `<`/`>`/`&` to their `\uXXXX` JSON forms makes the literal `</script>`
    /// (and `<!--`) impossible to appear from data, while still parsing back identically.
    private static func scriptSafeJSON(_ json: String) -> String {
        json.replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
    }

    /// The vetted interactive-chart script. Reads the JSON data island and renders SVG-free
    /// DOM bars with a hover tooltip. Every data-derived string goes through `textContent`;
    /// the only data→style path is a clamped numeric width. No `eval`, no `innerHTML`, no
    /// network (CSP blocks it anyway), no navigation.
    private static let interactiveChartScript = """
    (function () {
      var node = document.getElementById('astra-chart-data');
      var bars = [];
      try { bars = ((JSON.parse(node.textContent) || {}).bars) || []; } catch (e) { bars = []; }
      var root = document.getElementById('chart');
      var tip = document.getElementById('tip');
      if (!bars.length) { root.textContent = 'No data yet.'; return; }
      var max = 0, i;
      for (i = 0; i < bars.length; i++) { var v = +bars[i].value || 0; if (v > max) max = v; }
      if (max <= 0) max = 1;
      for (i = 0; i < bars.length; i++) {
        var b = bars[i];
        var frac = Math.max(0, Math.min(1, (+b.value || 0) / max));
        var row = document.createElement('div'); row.className = 'irow';
        var lbl = document.createElement('div'); lbl.className = 'ilbl'; lbl.textContent = String(b.label);
        var track = document.createElement('div'); track.className = 'itrack';
        var bar = document.createElement('div'); bar.className = 'ibar'; bar.style.width = (frac * 100).toFixed(2) + '%';
        var val = document.createElement('div'); val.className = 'ival'; val.textContent = String(b.display);
        track.appendChild(bar); row.appendChild(lbl); row.appendChild(track); row.appendChild(val);
        (function (item, el) {
          el.addEventListener('mouseenter', function () { tip.textContent = String(item.label) + ': ' + String(item.display); tip.hidden = false; });
          el.addEventListener('mouseleave', function () { tip.hidden = true; });
        })(b, row);
        root.appendChild(row);
      }
    })();
    """

    /// JS-enabled document shell for the vetted interactive renderer. Same locked-down CSP as
    /// the static shell PLUS `script-src 'unsafe-inline'` (only Swift-authored inline scripts
    /// exist here); `default-src 'none'` still blocks every network fetch.
    private static func interactiveDocument(_ body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none';">
        <style>
        :root { color-scheme: light dark; }
        body { font: 13px -apple-system, system-ui, sans-serif; margin: 16px; color: #1d1d1f; background: transparent; }
        @media (prefers-color-scheme: dark) { body { color: #f5f5f7; } }
        h1 { font-size: 15px; margin: 0 0 12px; }
        .ichart { display: flex; flex-direction: column; gap: 8px; }
        .irow { display: flex; align-items: center; gap: 8px; font-size: 12px; cursor: default; }
        .ilbl { width: 32%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .itrack { flex: 1; background: rgba(127,127,127,0.12); border-radius: 4px; height: 16px; }
        .ibar { height: 16px; border-radius: 4px; background: #4a7ba6; min-width: 2px; transition: filter .1s; }
        .irow:hover .ibar { filter: brightness(1.15); }
        .ival { width: 48px; text-align: right; color: #666; }
        .tip { position: fixed; top: 8px; right: 8px; background: rgba(0,0,0,0.78); color: #fff; padding: 4px 8px; border-radius: 6px; font-size: 12px; pointer-events: none; }
        </style></head><body>
        \(body)
        </body></html>
        """
    }

    /// JS-enabled, CSP-locked shell hosting a Phase 1 dynamic HTML app. UNLIKE every other shell
    /// here, the `innerHTML` is MODEL-authored — so Swift keeps owning everything that matters:
    /// the document, the locked CSP, and the network posture. The model only contributes inner
    /// content (markup + its own `<style>` + `<script>`), which this drops into `<body>`.
    ///
    /// The CSP is the same family as `interactiveDocument`: `default-src 'none'` blocks every
    /// network fetch (fetch/XHR/WebSocket/external script/font), `script-src 'unsafe-inline'` runs
    /// only inline app script + inline event handlers (so an onclick calculator works) but NO
    /// external `<script src>`, `style-src 'unsafe-inline'` allows the app's own CSS, `img-src
    /// data:` allows inline (non-network) images, and `base-uri`/`form-action` are locked. Combined
    /// with `baseURL: nil`, NO `WKScriptMessageHandler` (no native bridge in Phase 1), and the
    /// `WorkspaceAppWebReportView` nav/UI delegates (cancel navigation, deny window.open, deny
    /// file-open panels + JS dialogs), a model HTML app can compute locally but has no exfiltration
    /// channel: no network egress, no native bridge, no navigation. The shell adds only a neutral
    /// reset; the app's own `<style>` owns all layout.
    static func appDocument(innerHTML: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none';">
        <style>
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; }
        html, body { margin: 0; padding: 0; }
        body { font: 13px -apple-system, system-ui, sans-serif; background: transparent; }
        </style></head><body>
        \(innerHTML)
        </body></html>
        """
    }

    /// Wraps body HTML in the shared, CSP-locked document shell (no script, no network).
    private static func document(_ body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none';">
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
