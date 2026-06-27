import Foundation

/// Deterministic HTML for the GitHub pull-request reader app — the reliable floor the Studio ships when
/// the model is unavailable, and a verified reference for the connector-read recipe. The UI reads LIVE
/// PRs through the vetted `astra.read` bridge (no network of its own), renders them, and lets the user
/// switch state (open/closed/all). Self-contained: inline markup + CSS + JS, no eval, no external loads.
enum WorkspaceAppGitHubPRTemplate {
    /// `sourceId` is the manifest source id the page reads (must match the `capability.read` action's
    /// `sourceRef` — the bridge's read allowlist). `title` is the app name shown in the header.
    static func html(title: String, sourceId: String) -> String {
        let safeTitle = escaped(title)
        let safeSource = jsString(sourceId)
        return """
        <style>
          :root { color-scheme: light dark; }
          .pr-wrap { font: 14px/1.5 -apple-system, system-ui, sans-serif; padding: 16px; max-width: 880px; margin: 0 auto; }
          .pr-head { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; margin-bottom: 12px; }
          .pr-head h1 { font-size: 18px; margin: 0; flex: 1; }
          .pr-head select, .pr-head button { font: inherit; padding: 4px 8px; border-radius: 6px; }
          .pr-status { color: #888; margin: 8px 0; }
          .pr-error { color: #c0392b; background: rgba(192,57,43,0.08); padding: 10px 12px; border-radius: 8px; margin: 8px 0; }
          .pr-list { list-style: none; padding: 0; margin: 0; }
          .pr-item { padding: 12px 0; border-top: 1px solid rgba(128,128,128,0.25); }
          .pr-item .pr-title { font-weight: 600; }
          .pr-meta { color: #888; font-size: 12px; margin-top: 4px; display: flex; gap: 10px; flex-wrap: wrap; }
          .pr-badge { font-size: 11px; padding: 1px 7px; border-radius: 999px; background: rgba(46,160,67,0.18); color: #2ea043; }
          .pr-badge.draft { background: rgba(128,128,128,0.18); color: #888; }
          .pr-url { color: #6b7bd6; word-break: break-all; }
        </style>
        <div class="pr-wrap">
          <div class="pr-head">
            <h1>\(safeTitle)</h1>
            <label>State
              <select id="pr-state">
                <option value="open" selected>Open</option>
                <option value="closed">Closed</option>
                <option value="all">All</option>
              </select>
            </label>
            <button id="pr-refresh" type="button">Refresh</button>
          </div>
          <div id="pr-status" class="pr-status">Loading your pull requests…</div>
          <div id="pr-error" class="pr-error" style="display:none"></div>
          <ul id="pr-list" class="pr-list"></ul>
        </div>
        <script>
          (function () {
            var SOURCE = \(safeSource);
            var statusEl = document.getElementById("pr-status");
            var errorEl = document.getElementById("pr-error");
            var listEl = document.getElementById("pr-list");
            var stateEl = document.getElementById("pr-state");

            function esc(v) {
              return String(v == null ? "" : v)
                .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
            }
            function showError(msg) {
              errorEl.style.display = "block";
              errorEl.textContent = msg;
            }
            function render(rows) {
              listEl.innerHTML = "";
              if (!rows.length) { statusEl.textContent = "No pull requests for this filter."; return; }
              statusEl.textContent = rows.length + " pull request" + (rows.length === 1 ? "" : "s") + ".";
              rows.forEach(function (pr) {
                var li = document.createElement("li");
                li.className = "pr-item";
                var draft = pr.isDraft ? " draft" : "";
                var num = pr.number != null ? ("#" + esc(pr.number) + " ") : "";
                li.innerHTML =
                  '<div class="pr-title">' + num + esc(pr.title) +
                  ' <span class="pr-badge' + draft + '">' + esc(pr.isDraft ? "draft" : (pr.state || "")) + '</span></div>' +
                  '<div class="pr-meta">' +
                    (pr.repository ? '<span>' + esc(pr.repository) + '</span>' : '') +
                    (pr.author ? '<span>@' + esc(pr.author) + '</span>' : '') +
                    (pr.updatedAt ? '<span>updated ' + esc(pr.updatedAt) + '</span>' : '') +
                  '</div>' +
                  (pr.url ? '<div class="pr-meta"><span class="pr-url">' + esc(pr.url) + '</span></div>' : '');
                listEl.appendChild(li);
              });
            }
            function load() {
              errorEl.style.display = "none";
              statusEl.textContent = "Loading your pull requests…";
              listEl.innerHTML = "";
              var state = stateEl ? stateEl.value : "open";
              Promise.resolve(astra.read(SOURCE, { params: { state: state } }))
                .then(function (res) { render((res && res.rows) || []); })
                .catch(function (e) {
                  statusEl.textContent = "";
                  showError("Couldn't load pull requests: " + (e && e.message ? e.message : e) +
                    " — make sure the GitHub CLI (gh) is installed and signed in (gh auth login).");
                });
            }
            document.getElementById("pr-refresh").addEventListener("click", load);
            if (stateEl) { stateEl.addEventListener("change", load); }
            load();
          })();
        </script>
        """
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A safely-quoted JS string literal for an interpolated id (defends against a quote/backslash in
    /// the source id leaking out of the literal). Source ids are kebab anyway, but be strict.
    private static func jsString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        return "\"\(escaped)\""
    }
}
