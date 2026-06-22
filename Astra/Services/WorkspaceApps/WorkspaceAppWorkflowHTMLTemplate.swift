import Foundation

/// Deterministic, parameterized DATA + WORKFLOW HTML template (Phase 5): the resilient floor for the
/// richer app archetypes that used to require the native widget surface. One template covers:
///   - **multi-table CRUD** (grocery and any multi-subject data app) via `astra.query/insert/update`,
///   - an optional **dashboard** (count metrics + a horizontal bar chart computed client-side from a
///     table's rows), and
///   - optional **workflow run buttons** (`astra.runAction`) + a **run-history** panel (`astra.runs`)
///     for pipeline / report / review-queue / agentic apps. Human approval still happens in the
///     native attention queue rendered around this surface — JS only TRIGGERS the run.
///
/// Everything is driven by a single injected `__CONFIG__` JSON object (tables, actions, chart, title),
/// so the template is injection-safe by construction: one JSON encode + a `<`-escape pass means a
/// crafted identifier can't break out of the inline `<script>`. No eval, no network, no external
/// resources — same locked CSP as every other HTML app.
enum WorkspaceAppWorkflowHTMLTemplate {
    struct TableSpec {
        var name: String
        var columns: [WorkspaceAppStorageColumn]
        var primaryKey: String
    }

    struct ActionSpec {
        var id: String
        var label: String
    }

    /// A horizontal bar chart: count of rows in `table` grouped by the value of `groupBy`.
    struct ChartSpec {
        var table: String
        var groupBy: String
        var title: String
    }

    /// Inner HTML wired to `astra.*` for the given tables / actions / optional chart. All identifiers
    /// flow through `configJSON`, which JSON-encodes them and escapes `<`, so the result is safe to
    /// embed in the inline `<script>` regardless of identifier contents.
    static func html(title: String, tables: [TableSpec], actions: [ActionSpec], chart: ChartSpec?) -> String {
        rawTemplate.replacingOccurrences(of: "__CONFIG__", with: configJSON(title: title, tables: tables, actions: actions, chart: chart))
    }

    private static func configJSON(title: String, tables: [TableSpec], actions: [ActionSpec], chart: ChartSpec?) -> String {
        struct ColJSON: Encodable { let name: String; let type: String }
        struct TableJSON: Encodable { let name: String; let pk: String; let columns: [ColJSON] }
        struct ActionJSON: Encodable { let id: String; let label: String }
        struct ChartJSON: Encodable { let table: String; let groupBy: String; let title: String }
        struct Config: Encodable { let title: String; let tables: [TableJSON]; let actions: [ActionJSON]; let chart: ChartJSON? }
        let config = Config(
            title: title,
            tables: tables.map { table in
                TableJSON(
                    name: table.name,
                    pk: table.primaryKey,
                    columns: table.columns.filter { $0.name != table.primaryKey }.map { ColJSON(name: $0.name, type: $0.type) }
                )
            },
            actions: actions.map { ActionJSON(id: $0.id, label: $0.label) },
            chart: chart.map { ChartJSON(table: $0.table, groupBy: $0.groupBy, title: $0.title) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(config)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"title\":\"App\",\"tables\":[],\"actions\":[],\"chart\":null}"
        // JSONEncoder leaves `<` literal, so escape it: a crafted identifier containing `</script>`
        // can't close the inline script element via the HTML parser.
        return json.replacingOccurrences(of: "<", with: "\\u003c")
    }

    private static let rawTemplate = """
<div class="app-wrap">
  <header class="app-head"><h1 id="appTitle"></h1></header>
  <div id="errBanner" class="err" hidden></div>
  <section id="metrics" class="metrics" hidden></section>
  <section id="chartCard" class="card chart-card" hidden>
    <h2 id="chartTitle" class="section-title"></h2>
    <div id="chart" class="chart"></div>
  </section>
  <section id="actionsCard" class="card" hidden>
    <h2 class="section-title">Actions</h2>
    <div id="actionButtons" class="action-buttons"></div>
    <div id="runs" class="runs"></div>
  </section>
  <div id="tables"></div>

  <style>
    .app-wrap { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; max-width: 820px; margin: 0 auto; padding: 20px; color: #1c1c1e; }
    .app-head { margin-bottom: 16px; }
    .app-head h1 { font-size: 22px; font-weight: 600; margin: 0; }
    .section-title { font-size: 15px; font-weight: 600; margin: 0 0 12px; }
    .card { background: #fff; border: 1px solid rgba(0,0,0,0.08); border-radius: 14px; padding: 16px; margin-bottom: 16px; }
    .table-head { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
    .table-head h2 { font-size: 16px; font-weight: 600; margin: 0; text-transform: capitalize; }
    .count { font-size: 13px; color: #6b6b70; background: rgba(120,120,128,0.12); padding: 3px 10px; border-radius: 20px; white-space: nowrap; }
    .metrics { display: flex; flex-wrap: wrap; gap: 10px; margin-bottom: 16px; }
    .metric { background: #fff; border: 1px solid rgba(0,0,0,0.08); border-radius: 12px; padding: 12px 16px; min-width: 120px; }
    .metric .v { font-size: 22px; font-weight: 700; }
    .metric .l { font-size: 12px; color: #6b6b70; text-transform: capitalize; }
    .chart { display: flex; flex-direction: column; gap: 8px; }
    .bar-row { display: flex; align-items: center; gap: 10px; }
    .bar-label { font-size: 12px; color: #3a3a3c; width: 120px; text-align: right; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bar-track { flex: 1; background: rgba(120,120,128,0.12); border-radius: 6px; height: 18px; overflow: hidden; }
    .bar-fill { background: #0a84ff; height: 100%; border-radius: 6px; min-width: 2px; }
    .bar-val { font-size: 12px; color: #6b6b70; width: 36px; }
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
    .action-buttons { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 12px; }
    .list { display: flex; flex-direction: column; gap: 8px; }
    .row { display: flex; align-items: center; gap: 12px; padding: 10px 4px; border-bottom: 1px solid rgba(0,0,0,0.06); }
    .row:last-child { border-bottom: none; }
    .cells { display: flex; flex-wrap: wrap; gap: 4px 16px; flex: 1; min-width: 0; }
    .cell { font-size: 14px; }
    .cell .k { color: #8a8a8e; font-size: 11px; text-transform: capitalize; margin-right: 4px; }
    .row-actions, .edit-inputs { display: flex; gap: 6px; flex-wrap: wrap; }
    .edit-inputs { flex: 1; }
    .empty { text-align: center; color: #8a8a8e; padding: 20px 0; font-size: 14px; }
    .runs { display: flex; flex-direction: column; gap: 6px; }
    .run { display: flex; align-items: center; gap: 10px; font-size: 13px; padding: 6px 0; border-top: 1px solid rgba(0,0,0,0.06); }
    .badge { font-size: 11px; font-weight: 600; padding: 2px 8px; border-radius: 20px; text-transform: capitalize; }
    .badge.completed { background: rgba(52,199,89,0.16); color: #1d7a37; }
    .badge.waiting { background: rgba(255,159,10,0.18); color: #9a5b00; }
    .badge.running { background: rgba(10,132,255,0.16); color: #0058c0; }
    .badge.failed, .badge.blocked, .badge.cancelled { background: rgba(255,69,58,0.16); color: #b00020; }
    .run-summary { color: #3a3a3c; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .err { background: #ffe5e5; color: #b00020; border: 1px solid #ffb3b3; border-radius: 10px; padding: 10px 12px; font-size: 13px; margin-bottom: 14px; }
    @media (prefers-color-scheme: dark) {
      .app-wrap { color: #f2f2f7; }
      .count, .metric .l { color: #aeaeb2; }
      .card, .metric { background: #1c1c1e; border-color: rgba(255,255,255,0.1); }
      input[type=text], input[type=number], input[type=date] { background: #2c2c2e; border-color: rgba(255,255,255,0.16); }
      .field label { color: #aeaeb2; }
      .row, .run { border-color: rgba(255,255,255,0.08); }
      .bar-label, .run-summary { color: #d0d0d4; }
      .btn-ghost { color: #f2f2f7; }
      .err { background: #3a1d1d; color: #ff8a8a; border-color: #5a2a2a; }
    }
  </style>

  <script>
    var CONFIG = __CONFIG__;
    var idCounter = 0;

    function el(tag, cls, txt) { var e = document.createElement(tag); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; }
    function showErr(msg) { var b = document.getElementById("errBanner"); b.textContent = msg; b.hidden = false; }
    function clearErr() { document.getElementById("errBanner").hidden = true; }
    function genId() { idCounter += 1; return "id-" + Math.random().toString(36).slice(2) + "-" + idCounter; }
    function errText(err) { return (err && err.message) ? err.message : String(err); }
    function inputType(t) {
      if (t === "number" || t === "int" || t === "integer" || t === "double" || t === "real") return "number";
      if (t === "date" || t === "datetime") return "date";
      if (t === "bool") return "checkbox";
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
      if (t === "checkbox") { inp.checked = !!value; } else if (value != null) { inp.value = value; }
      wrap.appendChild(lab);
      wrap.appendChild(inp);
      return wrap;
    }
    function readFields(container, columns) {
      var rec = {};
      var ins = container.querySelectorAll("input[data-col]");
      for (var i = 0; i < ins.length; i++) {
        var inp = ins[i], col = null;
        for (var j = 0; j < columns.length; j++) { if (columns[j].name === inp.dataset.col) col = columns[j]; }
        if (!col) continue;
        rec[col.name] = coerce(col, inp.type === "checkbox" ? inp.checked : inp.value);
      }
      return rec;
    }

    // ----- per-table CRUD section -----
    function tableSection(tcfg) {
      var card = el("section", "card");
      var head = el("div", "table-head");
      head.appendChild(el("h2", null, tcfg.name));
      var badge = el("span", "count", "0 items");
      head.appendChild(badge);
      card.appendChild(head);

      var form = el("form", "add-form");
      for (var i = 0; i < tcfg.columns.length; i++) { form.appendChild(buildField(tcfg.columns[i], null)); }
      var act = el("div", "field"); act.style.flex = "0 0 auto";
      var addBtn = el("button", "btn-primary", "Add"); addBtn.type = "submit";
      act.appendChild(el("label", null, " ")); act.appendChild(addBtn);
      form.appendChild(act);
      form.onsubmit = function (e) {
        e.preventDefault(); clearErr();
        if (!window.astra) { showErr("Data bridge unavailable."); return; }
        var rec = readFields(form, tcfg.columns); rec[tcfg.pk] = genId();
        astra.insert(tcfg.name, rec).then(function () { form.reset(); loadTable(tcfg); refreshDashboard(); })
          .catch(function (err) { showErr("Could not add: " + errText(err)); });
      };
      card.appendChild(form);

      var list = el("div", "list"); list.id = "list-" + tcfg.name;
      var empty = el("div", "empty", "No items yet"); empty.id = "empty-" + tcfg.name; empty.hidden = true;
      card.appendChild(list); card.appendChild(empty);
      card._cfg = tcfg; card._badge = badge; card._list = list; card._empty = empty;
      return card;
    }
    function renderRow(tcfg, r) {
      var row = el("div", "row");
      var cells = el("div", "cells");
      for (var i = 0; i < tcfg.columns.length; i++) {
        var c = tcfg.columns[i], cell = el("div", "cell");
        cell.appendChild(el("span", "k", c.name + ":"));
        cell.appendChild(document.createTextNode(display(r[c.name])));
        cells.appendChild(cell);
      }
      var actions = el("div", "row-actions");
      var editBtn = el("button", "btn-ghost", "Edit"); editBtn.type = "button";
      editBtn.onclick = function () { renderEditRow(tcfg, row, r); };
      actions.appendChild(editBtn);
      row.appendChild(cells); row.appendChild(actions);
      return row;
    }
    function renderEditRow(tcfg, rowEl, r) {
      var nrow = el("div", "row"), box = el("div", "edit-inputs");
      for (var i = 0; i < tcfg.columns.length; i++) { box.appendChild(buildField(tcfg.columns[i], r[tcfg.columns[i].name])); }
      var actions = el("div", "row-actions");
      var save = el("button", "btn-primary", "Save"); save.type = "button";
      var cancel = el("button", "btn-ghost", "Cancel"); cancel.type = "button";
      save.onclick = function () {
        clearErr();
        if (!window.astra) { showErr("Data bridge unavailable."); return; }
        var rec = readFields(box, tcfg.columns); rec[tcfg.pk] = r[tcfg.pk];
        astra.update(tcfg.name, rec).then(function () { loadTable(tcfg); refreshDashboard(); })
          .catch(function (err) { showErr("Could not save: " + errText(err)); });
      };
      cancel.onclick = function () { rowEl.parentNode.replaceChild(renderRow(tcfg, r), nrow); };
      actions.appendChild(save); actions.appendChild(cancel);
      nrow.appendChild(box); nrow.appendChild(actions);
      rowEl.parentNode.replaceChild(nrow, rowEl);
    }
    var SECTIONS = {};
    function loadTable(tcfg) {
      if (!window.astra) { showErr("Data bridge unavailable."); return; }
      astra.query(tcfg.name, { limit: 500 }).then(function (res) {
        var rows = (res && res.rows) ? res.rows : [];
        var card = SECTIONS[tcfg.name];
        card._badge.textContent = rows.length + (rows.length === 1 ? " item" : " items");
        card._list.innerHTML = "";
        card._empty.hidden = rows.length !== 0;
        for (var i = 0; i < rows.length; i++) { card._list.appendChild(renderRow(tcfg, rows[i])); }
      }).catch(function (err) { showErr("Could not load " + tcfg.name + ": " + errText(err)); });
    }

    // ----- dashboard: metrics + bar chart -----
    function refreshDashboard() {
      renderMetrics();
      if (CONFIG.chart) { renderChart(CONFIG.chart); }
    }
    function renderMetrics() {
      if (!CONFIG.tables.length) { return; }
      var box = document.getElementById("metrics");
      box.innerHTML = ""; box.hidden = false;
      CONFIG.tables.forEach(function (tcfg) {
        astra.query(tcfg.name, { limit: 1000 }).then(function (res) {
          var n = (res && res.rows) ? res.rows.length : 0;
          var card = el("div", "metric");
          card.appendChild(el("div", "v", String(n)));
          card.appendChild(el("div", "l", tcfg.name));
          box.appendChild(card);
        }).catch(function () {});
      });
    }
    function renderChart(ccfg) {
      if (!window.astra) { return; }
      var card = document.getElementById("chartCard");
      document.getElementById("chartTitle").textContent = ccfg.title || ("By " + ccfg.groupBy);
      card.hidden = false;
      astra.query(ccfg.table, { limit: 1000 }).then(function (res) {
        var rows = (res && res.rows) ? res.rows : [];
        var counts = {}, order = [];
        for (var i = 0; i < rows.length; i++) {
          var key = display(rows[i][ccfg.groupBy]);
          if (counts[key] == null) { counts[key] = 0; order.push(key); }
          counts[key] += 1;
        }
        var max = 1;
        for (var k = 0; k < order.length; k++) { if (counts[order[k]] > max) max = counts[order[k]]; }
        var chart = document.getElementById("chart"); chart.innerHTML = "";
        if (!order.length) { chart.appendChild(el("div", "empty", "No data yet")); return; }
        order.forEach(function (key) {
          var rowEl = el("div", "bar-row");
          rowEl.appendChild(el("div", "bar-label", key));
          var track = el("div", "bar-track");
          var fill = el("div", "bar-fill"); fill.style.width = Math.round((counts[key] / max) * 100) + "%";
          track.appendChild(fill);
          rowEl.appendChild(track);
          rowEl.appendChild(el("div", "bar-val", String(counts[key])));
          chart.appendChild(rowEl);
        });
      }).catch(function (err) { showErr("Could not build chart: " + errText(err)); });
    }

    // ----- workflow actions + run history -----
    var runsTimer = null;
    function renderActions() {
      if (!CONFIG.actions.length) { return; }
      document.getElementById("actionsCard").hidden = false;
      var box = document.getElementById("actionButtons"); box.innerHTML = "";
      CONFIG.actions.forEach(function (a) {
        var btn = el("button", "btn-primary", a.label || a.id); btn.type = "button";
        btn.onclick = function () {
          clearErr();
          if (!window.astra) { showErr("Workflow bridge unavailable."); return; }
          btn.disabled = true;
          astra.runAction(a.id).then(function (res) {
            btn.disabled = false;
            refreshRuns();
            refreshDashboard();
          }).catch(function (err) { btn.disabled = false; showErr("Could not run " + (a.label || a.id) + ": " + errText(err)); });
        };
        box.appendChild(btn);
      });
      refreshRuns();
    }
    function refreshRuns() {
      if (!window.astra || !astra.runs) { return; }
      astra.runs({ limit: 25 }).then(function (res) {
        var runs = (res && res.runs) ? res.runs : [];
        var box = document.getElementById("runs"); box.innerHTML = "";
        var pending = false;
        for (var i = 0; i < runs.length; i++) {
          var r = runs[i];
          if (r.status === "waiting" || r.status === "running") { pending = true; }
          var rowEl = el("div", "run");
          rowEl.appendChild(el("span", "badge " + r.status, r.status));
          rowEl.appendChild(el("span", "run-summary", (r.actionId || "") + (r.summary ? (" — " + r.summary) : "")));
          box.appendChild(rowEl);
        }
        // Poll while a run is waiting on approval or still running (the native queue resolves it).
        if (runsTimer) { clearTimeout(runsTimer); runsTimer = null; }
        if (pending) { runsTimer = setTimeout(refreshRuns, 3000); }
      }).catch(function () {});
    }

    function init() {
      document.getElementById("appTitle").textContent = CONFIG.title || "App";
      var host = document.getElementById("tables");
      CONFIG.tables.forEach(function (tcfg) {
        var card = tableSection(tcfg);
        SECTIONS[tcfg.name] = card;
        host.appendChild(card);
        loadTable(tcfg);
      });
      refreshDashboard();
      renderActions();
    }
    init();
  </script>
</div>
"""
}
