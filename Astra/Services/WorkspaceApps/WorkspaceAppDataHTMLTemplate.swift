import Foundation

/// Deterministic DATA-BACKED HTML template (Phase 3): a records app whose UI reads/writes the app's
/// OWN governed storage through the injected `astra.*` bridge (query/insert/update). This is the
/// resilient floor for DATA apps — a real CRUD UI with NO model needed, the data-backed analogue of
/// `WorkspaceAppHTMLTemplate`. The model-authored template was adversarially verified for
/// sandbox-safety + correct bridge use; the unit tests re-assert both. `__APP_TITLE__` / `__TABLE__`
/// / `__COLUMNS__` / `__PRIMARY_KEY__` are substituted from the manifest's storage schema.
enum WorkspaceAppDataHTMLTemplate {
    /// Inner HTML wired to `astra.*` for `table`. `columns` is the table's full column set; the
    /// add/edit form uses the non-primary-key columns, and the primary key is generated client-side.
    static func html(title: String, table: String, columns: [WorkspaceAppStorageColumn], primaryKey: String) -> String {
        // Structural placeholders first, then the (escaped) title last — so a title that happens to
        // contain a placeholder token can't perturb the structural substitution. `table` and
        // `primaryKey` are JSON-encoded (quotes included), so an identifier with a quote/`</script>`
        // can't break out of its JS string literal — the helper is safe by construction, not just
        // because today's callers pass hardcoded identifiers.
        return rawTemplate
            .replacingOccurrences(of: "__COLUMNS__", with: scriptSafe(columnsJSON(columns, primaryKey: primaryKey)))
            .replacingOccurrences(of: "__PRIMARY_KEY__", with: jsonString(primaryKey))
            .replacingOccurrences(of: "__TABLE__", with: jsonString(table))
            .replacingOccurrences(of: "__APP_TITLE__", with: escape(title))
    }

    /// A String encoded as a JSON string literal (surrounding quotes + escaping) for safe injection
    /// into the inline `<script>` context. JSONEncoder escapes `"`, `\`, and control chars; `scriptSafe`
    /// then neutralizes `<` so an identifier containing `</script>` (or `<!--`) cannot close the script
    /// element via the HTML parser. The result is valid JSON/JS — the helper is safe by construction.
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return scriptSafe(json)
    }

    /// Replaces `<` with its `<` JS escape. JSONEncoder leaves `<` and `/` literal, so a `</script>`
    /// substring would close the inline script element during HTML parsing regardless of JS string
    /// context; escaping `<` neutralizes that (and `<!--`) while keeping the text valid JSON/JS.
    private static func scriptSafe(_ json: String) -> String {
        json.replacingOccurrences(of: "<", with: "\\u003c")
    }

    /// JSON array of the EDITABLE (non-primary-key) columns as `[{"name","type"}]`, injected as a JS
    /// literal (`var COLUMNS = [...]`).
    private static func columnsJSON(_ columns: [WorkspaceAppStorageColumn], primaryKey: String) -> String {
        struct Col: Encodable { let name: String; let type: String }
        let editable = columns.filter { $0.name != primaryKey }.map { Col(name: $0.name, type: $0.type) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(editable), let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let rawTemplate = """
<div class="app-wrap">
  <header class="app-head">
    <h1>__APP_TITLE__</h1>
    <span id="countBadge" class="count">0 items</span>
  </header>

  <div id="errBanner" class="err" hidden></div>

  <section class="card add-card">
    <form id="addForm" class="add-form"></form>
  </section>

  <section class="card">
    <div id="list" class="list"></div>
    <div id="empty" class="empty" hidden>No items yet</div>
  </section>

  <style>
    .app-wrap { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; max-width: 720px; margin: 0 auto; padding: 20px; color: #1c1c1e; }
    .app-head { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; margin-bottom: 16px; }
    .app-head h1 { font-size: 22px; font-weight: 600; margin: 0; }
    .count { font-size: 13px; color: #6b6b70; background: rgba(120,120,128,0.12); padding: 3px 10px; border-radius: 20px; white-space: nowrap; }
    .card { background: #fff; border: 1px solid rgba(0,0,0,0.08); border-radius: 14px; padding: 16px; margin-bottom: 16px; }
    .add-form { display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-end; }
    .field { display: flex; flex-direction: column; gap: 4px; flex: 1 1 140px; min-width: 120px; }
    .field label { font-size: 12px; font-weight: 500; color: #6b6b70; text-transform: capitalize; }
    input[type=text], input[type=number], input[type=date] { font: inherit; font-size: 14px; padding: 8px 10px; border: 1px solid rgba(0,0,0,0.14); border-radius: 9px; background: #fbfbfd; color: inherit; box-sizing: border-box; width: 100%; }
    input:focus { outline: none; border-color: #0a84ff; }
    input[type=checkbox] { width: 18px; height: 18px; accent-color: #0a84ff; }
    .chk-field { flex-direction: row; align-items: center; gap: 8px; flex: 0 0 auto; }
    .chk-field label { order: 2; }
    button { font: inherit; font-size: 14px; font-weight: 500; padding: 8px 16px; border: none; border-radius: 9px; cursor: pointer; }
    .btn-primary { background: #0a84ff; color: #fff; }
    .btn-primary:hover { background: #0070e0; }
    .btn-ghost { background: rgba(120,120,128,0.12); color: inherit; }
    .btn-ghost:hover { background: rgba(120,120,128,0.2); }
    .list { display: flex; flex-direction: column; gap: 8px; }
    .row { display: flex; align-items: center; gap: 12px; padding: 10px 4px; border-bottom: 1px solid rgba(0,0,0,0.06); }
    .row:last-child { border-bottom: none; }
    .cells { display: flex; flex-wrap: wrap; gap: 4px 16px; flex: 1; min-width: 0; }
    .cell { font-size: 14px; }
    .cell .k { color: #8a8a8e; font-size: 11px; text-transform: capitalize; margin-right: 4px; }
    .row-actions { display: flex; gap: 6px; }
    .edit-inputs { display: flex; flex-wrap: wrap; gap: 10px; flex: 1; }
    .empty { text-align: center; color: #8a8a8e; padding: 28px 0; font-size: 14px; }
    .err { background: #ffe5e5; color: #b00020; border: 1px solid #ffb3b3; border-radius: 10px; padding: 10px 12px; font-size: 13px; margin-bottom: 14px; }
    @media (prefers-color-scheme: dark) {
      .app-wrap { color: #f2f2f7; }
      .count { color: #aeaeb2; background: rgba(120,120,128,0.24); }
      .card { background: #1c1c1e; border-color: rgba(255,255,255,0.1); }
      input[type=text], input[type=number], input[type=date] { background: #2c2c2e; border-color: rgba(255,255,255,0.16); }
      .field label { color: #aeaeb2; }
      .row { border-color: rgba(255,255,255,0.08); }
      .cell .k { color: #8e8e93; }
      .btn-ghost { color: #f2f2f7; }
      .empty { color: #8e8e93; }
      .err { background: #3a1d1d; color: #ff8a8a; border-color: #5a2a2a; }
    }
  </style>

  <script>
    var TABLE = __TABLE__;
    var COLUMNS = __COLUMNS__;
    var PK = __PRIMARY_KEY__;
    var idCounter = 0;
    var rows = [];

    function el(tag, cls, txt) { var e = document.createElement(tag); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; }
    function showErr(msg) { var b = document.getElementById("errBanner"); b.textContent = msg; b.hidden = false; }
    function clearErr() { document.getElementById("errBanner").hidden = true; }
    function genId() { idCounter += 1; return "id-" + Math.random().toString(36).slice(2) + "-" + idCounter; }
    function inputType(t) {
      t = (t || "").toLowerCase();
      if (t === "number" || t === "int" || t === "integer" || t === "double" || t === "real" || t === "float") return "number";
      if (t === "date" || t === "datetime" || t === "timestamp") return "date";
      if (t === "bool" || t === "boolean") return "checkbox";
      return "text";
    }
    function coerce(col, raw) {
      var t = inputType(col.type);
      if (t === "number") { var n = parseFloat(raw); return isNaN(n) ? null : n; }
      if (t === "checkbox") return !!raw;
      return raw;
    }
    function display(v) {
      if (v === true) return "Yes";
      if (v === false) return "No";
      if (v == null || v === "") return "—";
      return String(v);
    }

    function buildField(col, value) {
      var t = inputType(col.type);
      var wrap = el("div", t === "checkbox" ? "field chk-field" : "field");
      var lab = el("label", null, col.name);
      var inp = document.createElement("input");
      inp.type = t;
      inp.dataset.col = col.name;
      if (t === "checkbox") { inp.checked = !!value; }
      else if (value != null) { inp.value = value; }
      wrap.appendChild(lab);
      wrap.appendChild(inp);
      return wrap;
    }
    function readFields(container) {
      var rec = {};
      var ins = container.querySelectorAll("input[data-col]");
      for (var i = 0; i < ins.length; i++) {
        var inp = ins[i];
        var col = null;
        for (var j = 0; j < COLUMNS.length; j++) { if (COLUMNS[j].name === inp.dataset.col) col = COLUMNS[j]; }
        if (!col) continue;
        rec[col.name] = coerce(col, inp.type === "checkbox" ? inp.checked : inp.value);
      }
      return rec;
    }

    function buildAddForm() {
      var form = document.getElementById("addForm");
      form.innerHTML = "";
      for (var i = 0; i < COLUMNS.length; i++) { form.appendChild(buildField(COLUMNS[i], null)); }
      var actions = el("div", "field");
      actions.style.flex = "0 0 auto";
      var btn = el("button", "btn-primary", "Add");
      btn.type = "submit";
      actions.appendChild(el("label", null, " "));
      actions.appendChild(btn);
      form.appendChild(actions);
      form.onsubmit = function (e) {
        e.preventDefault();
        clearErr();
        if (!window.astra) { showErr("Data bridge unavailable."); return; }
        var rec = readFields(form);
        rec[PK] = genId();
        astra.insert(TABLE, rec).then(function () { form.reset(); load(); })
          .catch(function (err) { showErr("Could not add item: " + (err && err.message ? err.message : err)); });
      };
    }

    function renderRow(r) {
      var row = el("div", "row");
      var cells = el("div", "cells");
      for (var i = 0; i < COLUMNS.length; i++) {
        var c = COLUMNS[i];
        var cell = el("div", "cell");
        cell.appendChild(el("span", "k", c.name + ":"));
        cell.appendChild(document.createTextNode(display(r[c.name])));
        cells.appendChild(cell);
      }
      var actions = el("div", "row-actions");
      var editBtn = el("button", "btn-ghost", "Edit");
      editBtn.type = "button";
      editBtn.onclick = function () { renderEditRow(row, r); };
      actions.appendChild(editBtn);
      row.appendChild(cells);
      row.appendChild(actions);
      return row;
    }

    function renderEditRow(rowEl, r) {
      var nrow = el("div", "row");
      var box = el("div", "edit-inputs");
      for (var i = 0; i < COLUMNS.length; i++) { box.appendChild(buildField(COLUMNS[i], r[COLUMNS[i].name])); }
      var actions = el("div", "row-actions");
      var save = el("button", "btn-primary", "Save");
      save.type = "button";
      var cancel = el("button", "btn-ghost", "Cancel");
      cancel.type = "button";
      save.onclick = function () {
        clearErr();
        if (!window.astra) { showErr("Data bridge unavailable."); return; }
        var rec = readFields(box);
        rec[PK] = r[PK];
        astra.update(TABLE, rec).then(function () { load(); })
          .catch(function (err) { showErr("Could not save: " + (err && err.message ? err.message : err)); });
      };
      cancel.onclick = function () { rowEl.parentNode.replaceChild(renderRow(r), nrow); };
      actions.appendChild(save);
      actions.appendChild(cancel);
      nrow.appendChild(box);
      nrow.appendChild(actions);
      rowEl.parentNode.replaceChild(nrow, rowEl);
    }

    function render() {
      var list = document.getElementById("list");
      var empty = document.getElementById("empty");
      list.innerHTML = "";
      document.getElementById("countBadge").textContent = rows.length + (rows.length === 1 ? " item" : " items");
      if (!rows.length) { empty.hidden = false; return; }
      empty.hidden = true;
      for (var i = 0; i < rows.length; i++) { list.appendChild(renderRow(rows[i])); }
    }

    function load() {
      clearErr();
      if (!window.astra) { showErr("Data bridge unavailable."); rows = []; render(); return; }
      astra.query(TABLE, { limit: 500 }).then(function (res) {
        rows = (res && res.rows) ? res.rows : [];
        render();
      }).catch(function (err) {
        showErr("Could not load items: " + (err && err.message ? err.message : err));
        rows = [];
        render();
      });
    }

    buildAddForm();
    load();
  </script>
</div>
"""
}
