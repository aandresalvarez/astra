import Foundation

/// Deterministic, self-contained interactive HTML UI templates — the resilient FLOOR that
/// guarantees App Studio always yields a real, working dynamic UI even when model generation
/// times out or fails (instead of a placeholder scaffold or a static data shell).
///
/// Each `rawTemplate` is INNER html (markup + <style> + <script>) that `WorkspaceAppWebReportHTML
/// .appDocument` wraps in the CSP-locked, no-network, no-bridge WebView. Every template is
/// self-contained (no external resources, no `eval`, no `<iframe>`) so it passes
/// `WorkspaceAppManifestValidator.validateHTMLApp`, and every one is genuinely interactive. The
/// templates were model-authored then adversarially verified for sandbox-safety + interactivity;
/// the unit tests re-assert both invariants. `__APP_TITLE__` is replaced with the app name.
enum WorkspaceAppHTMLTemplate: String, CaseIterable, Sendable {
    case calculator, checklist, board, dashboard, form, list, generic

    /// Pick the closest template for a free-text intent. Specific archetypes win; anything that
    /// doesn't match a known shape gets the polished `generic` shell — so there is ALWAYS a real
    /// interactive result.
    static func classify(_ intent: String) -> WorkspaceAppHTMLTemplate {
        let text = intent.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if has(["calculator", "calculate", "converter", "convert", "unit conversion", "tip calc",
                "tip calculator", "bmi", "mortgage", "loan", "percentage"]) { return .calculator }
        // Dashboard BEFORE board: "board" is a substring of "dashboard".
        if has(["dashboard", "metrics", "analytics", "kpi", "stats", "chart", "graph", "report"]) { return .dashboard }
        // List BEFORE board: a sorted/prioritized list beats a kanban for "ordered by" intents.
        if has(["list of", "ordered by", "sorted by", "ranked by", "rank by", "prioriti",
                "leaderboard", "feed of", "table of", "queue of", "sortable"]) { return .list }
        if has(["kanban", "board", "pull request", "open pr", " prs", "ticket", "issue tracker",
                "issues", "triage", "backlog", "sprint", "cards"]) { return .board }
        if has(["form", "intake", "survey", "questionnaire", "sign up", "signup", "register",
                "application form", "feedback"]) { return .form }
        if has(["todo", "to-do", "to do", "checklist", "task list", "tasks"]) { return .checklist }
        return .generic
    }

    /// Inner HTML with the app title injected (HTML-escaped so a crafted name cannot inject markup).
    func html(title: String) -> String {
        rawTemplate.replacingOccurrences(of: "__APP_TITLE__", with: Self.escape(title))
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private var rawTemplate: String {
        switch self {
        case .calculator: return Self.calculatorHTML
        case .checklist: return Self.checklistHTML
        case .board: return Self.boardHTML
        case .dashboard: return Self.dashboardHTML
        case .form: return Self.formHTML
        case .list: return Self.listHTML
        case .generic: return Self.genericHTML
        }
    }

    private static let calculatorHTML = """
<div class="calc-shell">
  <h1 class="calc-title">__APP_TITLE__</h1>
  <div class="calc">
    <div class="calc-display" id="display" aria-live="polite">0</div>
    <div class="calc-grid">
      <button class="key key-fn" data-clear>C</button>
      <button class="key key-fn" data-op="/">&divide;</button>
      <button class="key key-fn" data-op="*">&times;</button>
      <button class="key key-fn" data-op="-">&minus;</button>
      <button class="key" data-num="7">7</button>
      <button class="key" data-num="8">8</button>
      <button class="key" data-num="9">9</button>
      <button class="key key-op" data-op="+">+</button>
      <button class="key" data-num="4">4</button>
      <button class="key" data-num="5">5</button>
      <button class="key" data-num="6">6</button>
      <button class="key key-eq" data-eq>=</button>
      <button class="key" data-num="1">1</button>
      <button class="key" data-num="2">2</button>
      <button class="key" data-num="3">3</button>
      <button class="key key-zero" data-num="0">0</button>
      <button class="key" data-num=".">.</button>
    </div>
  </div>
  <p class="calc-hint">Sample: 42 &times; 2 = 84 &middot; 7 / 0 = Error</p>
</div>

<style>
  .calc-shell { max-width: 320px; margin: 0 auto; font-family: -apple-system, system-ui, sans-serif; color: #1c1c1e; }
  .calc-title { font-size: 18px; font-weight: 600; margin: 0 0 14px; text-align: center; }
  .calc { background: #f5f5f7; border: 1px solid #e2e2e7; border-radius: 18px; padding: 16px; }
  .calc-display { background: #fff; border: 1px solid #e2e2e7; border-radius: 12px; padding: 18px 16px; font-size: 34px; font-weight: 500; text-align: right; min-height: 24px; overflow-x: auto; white-space: nowrap; font-variant-numeric: tabular-nums; }
  .calc-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; margin-top: 14px; }
  .key { border: none; border-radius: 12px; padding: 16px 0; font-size: 20px; font-weight: 500; background: #fff; color: #1c1c1e; cursor: pointer; transition: transform .05s ease, filter .12s ease; box-shadow: 0 1px 1px rgba(0,0,0,.04); }
  .key:hover { filter: brightness(.96); }
  .key:active { transform: scale(.95); }
  .key-fn { background: #e6e6eb; color: #1c1c1e; }
  .key-op { background: #ff9f0a; color: #fff; }
  .key-eq { background: #0a84ff; color: #fff; }
  .key-zero { grid-column: span 2; text-align: left; padding-left: 26px; }
  .calc-hint { margin: 12px 0 0; font-size: 12px; color: #8e8e93; text-align: center; }
  @media (prefers-color-scheme: dark) {
    .calc-shell { color: #f2f2f7; }
    .calc { background: #1c1c1e; border-color: #2c2c2e; }
    .calc-display { background: #2c2c2e; border-color: #3a3a3c; color: #f2f2f7; }
    .key { background: #3a3a3c; color: #f2f2f7; box-shadow: none; }
    .key-fn { background: #545458; }
    .calc-hint { color: #8e8e93; }
  }
</style>

<script>
  (function () {
    var display = document.getElementById("display");
    var current = "0";
    var stored = null;
    var pendingOp = null;
    var resetNext = false;

    function show(v) { display.textContent = v; }

    function compute(a, op, b) {
      if (op === "+") return a + b;
      if (op === "-") return a - b;
      if (op === "*") return a * b;
      if (op === "/") return b === 0 ? null : a / b;
      return b;
    }

    function format(n) {
      if (n === null) return "Error";
      var r = Math.round(n * 1e10) / 1e10;
      return String(r);
    }

    document.querySelectorAll("[data-num]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        if (current === "Error" || resetNext) { current = "0"; resetNext = false; }
        var d = btn.getAttribute("data-num");
        if (d === ".") {
          if (current.indexOf(".") === -1) current = current + ".";
        } else if (current === "0") {
          current = d;
        } else {
          current = current + d;
        }
        show(current);
      });
    });

    document.querySelectorAll("[data-op]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        if (current === "Error") return;
        var val = parseFloat(current);
        if (stored !== null && pendingOp && !resetNext) {
          var res = compute(stored, pendingOp, val);
          stored = res;
          show(format(res));
        } else {
          stored = val;
        }
        pendingOp = btn.getAttribute("data-op");
        resetNext = true;
      });
    });

    document.querySelector("[data-eq]").addEventListener("click", function () {
      if (pendingOp === null || stored === null || current === "Error") return;
      var res = compute(stored, pendingOp, parseFloat(current));
      var out = format(res);
      show(out);
      current = res === null ? "Error" : out;
      stored = null;
      pendingOp = null;
      resetNext = true;
    });

    document.querySelector("[data-clear]").addEventListener("click", function () {
      current = "0"; stored = null; pendingOp = null; resetNext = false;
      show(current);
    });
  })();
</script>
"""

    private static let checklistHTML = """
<style>
  .cl-wrap { font-family: -apple-system, system-ui, sans-serif; max-width: 480px; margin: 0 auto; color: #1c1c1e; }
  .cl-wrap h1 { font-size: 22px; font-weight: 700; margin: 0 0 16px; letter-spacing: -0.02em; }
  .cl-row.add { display: flex; gap: 8px; margin-bottom: 14px; }
  .cl-input { flex: 1; padding: 10px 12px; font: inherit; font-size: 15px; border: 1px solid #d8d8dd; border-radius: 10px; background: #fff; color: inherit; outline: none; }
  .cl-input:focus { border-color: #0a84ff; }
  .cl-btn { padding: 10px 16px; font: inherit; font-size: 15px; font-weight: 600; border: none; border-radius: 10px; background: #0a84ff; color: #fff; cursor: pointer; }
  .cl-btn:active { opacity: 0.85; }
  .cl-filters { display: flex; gap: 6px; margin-bottom: 12px; }
  .cl-filter { padding: 6px 12px; font: inherit; font-size: 13px; border: 1px solid #d8d8dd; border-radius: 8px; background: transparent; color: #636366; cursor: pointer; }
  .cl-filter.on { background: #0a84ff; border-color: #0a84ff; color: #fff; }
  .cl-list { list-style: none; margin: 0; padding: 0; }
  .cl-item { display: flex; align-items: center; gap: 10px; padding: 11px 12px; border: 1px solid #ececf0; border-radius: 10px; margin-bottom: 8px; background: #fafafb; }
  .cl-item input[type=checkbox] { width: 18px; height: 18px; accent-color: #0a84ff; cursor: pointer; flex: none; }
  .cl-item .cl-label { flex: 1; font-size: 15px; }
  .cl-item.done .cl-label { text-decoration: line-through; color: #aeaeb2; }
  .cl-count { margin-top: 12px; font-size: 13px; color: #636366; }
  @media (prefers-color-scheme: dark) {
    .cl-wrap { color: #f2f2f7; }
    .cl-input { background: #1c1c1e; border-color: #3a3a3c; }
    .cl-filter { border-color: #3a3a3c; color: #aeaeb2; }
    .cl-item { background: #1c1c1e; border-color: #2c2c2e; }
    .cl-count { color: #aeaeb2; }
  }
</style>

<div class="cl-wrap">
  <h1>__APP_TITLE__</h1>
  <div class="cl-row add">
    <input class="cl-input" id="clInput" type="text" placeholder="Add a task and press Enter">
    <button class="cl-btn" id="clAdd">Add</button>
  </div>
  <div class="cl-filters" id="clFilters">
    <button class="cl-filter on" data-f="all">All</button>
    <button class="cl-filter" data-f="active">Active</button>
    <button class="cl-filter" data-f="done">Done</button>
  </div>
  <ul class="cl-list" id="clList"></ul>
  <div class="cl-count" id="clCount"></div>
</div>

<script>
  var items = [
    { text: "Draft the launch announcement", done: false },
    { text: "Review pull request feedback", done: true },
    { text: "Update the project roadmap", done: false },
    { text: "Archive last sprint notes", done: true }
  ];
  var filter = "all";
  var list = document.getElementById("clList");
  var count = document.getElementById("clCount");
  var input = document.getElementById("clInput");

  function render() {
    list.innerHTML = "";
    items.forEach(function (it, i) {
      if (filter === "active" && it.done) return;
      if (filter === "done" && !it.done) return;
      var li = document.createElement("li");
      li.className = "cl-item" + (it.done ? " done" : "");
      var cb = document.createElement("input");
      cb.type = "checkbox";
      cb.checked = it.done;
      cb.addEventListener("change", function () {
        items[i].done = cb.checked;
        render();
      });
      var span = document.createElement("span");
      span.className = "cl-label";
      span.textContent = it.text;
      li.appendChild(cb);
      li.appendChild(span);
      list.appendChild(li);
    });
    var left = items.filter(function (it) { return !it.done; }).length;
    count.textContent = left + (left === 1 ? " item left" : " items left");
  }

  function add() {
    var v = input.value.trim();
    if (!v) return;
    items.push({ text: v, done: false });
    input.value = "";
    render();
  }

  document.getElementById("clAdd").addEventListener("click", add);
  input.addEventListener("keydown", function (e) {
    if (e.key === "Enter") add();
  });
  document.getElementById("clFilters").addEventListener("click", function (e) {
    var b = e.target.closest(".cl-filter");
    if (!b) return;
    filter = b.getAttribute("data-f");
    var btns = this.querySelectorAll(".cl-filter");
    for (var j = 0; j < btns.length; j++) btns[j].classList.remove("on");
    b.classList.add("on");
    render();
  });

  render();
</script>
"""

    private static let boardHTML = """
<div class="board-wrap">
  <h1 class="board-title">__APP_TITLE__</h1>
  <p class="board-sub">Click any card to advance it to the next column.</p>
  <div class="board" id="board">
    <section class="col" data-stage="0">
      <header class="col-head"><span class="col-name">To Do</span><span class="count" data-count>0</span></header>
      <div class="col-body" data-body></div>
    </section>
    <section class="col" data-stage="1">
      <header class="col-head"><span class="col-name">In Progress</span><span class="count" data-count>0</span></header>
      <div class="col-body" data-body></div>
    </section>
    <section class="col" data-stage="2">
      <header class="col-head"><span class="col-name">Done</span><span class="count" data-count>0</span></header>
      <div class="col-body" data-body></div>
    </section>
  </div>
</div>

<style>
  .board-wrap{font-family:-apple-system,system-ui,sans-serif;max-width:960px;margin:0 auto;padding:28px 20px;color:#1c1c1e;-webkit-font-smoothing:antialiased;}
  .board-title{font-size:24px;font-weight:700;margin:0 0 4px;letter-spacing:-0.02em;}
  .board-sub{font-size:13px;color:#8a8a8e;margin:0 0 22px;}
  .board{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;align-items:start;}
  .col{background:#f5f5f7;border:1px solid #e4e4e9;border-radius:14px;padding:12px;}
  .col-head{display:flex;align-items:center;justify-content:space-between;margin:2px 4px 12px;}
  .col-name{font-size:13px;font-weight:600;text-transform:uppercase;letter-spacing:0.04em;color:#6c6c70;}
  .count{font-size:12px;font-weight:600;min-width:22px;text-align:center;background:#e4e4e9;color:#6c6c70;border-radius:999px;padding:2px 8px;}
  .col-body{display:flex;flex-direction:column;gap:10px;min-height:40px;}
  .card{background:#fff;border:1px solid #e4e4e9;border-radius:10px;padding:12px 14px;cursor:pointer;transition:transform .12s ease,box-shadow .12s ease,border-color .12s ease;box-shadow:0 1px 2px rgba(0,0,0,.04);}
  .card:hover{transform:translateY(-2px);box-shadow:0 4px 12px rgba(0,0,0,.08);border-color:#c9c9d0;}
  .card:active{transform:translateY(0);}
  .card-title{font-size:14px;font-weight:600;margin:0 0 5px;line-height:1.3;}
  .card-meta{font-size:12px;color:#8a8a8e;margin:0;}
  @media (prefers-color-scheme:dark){
    .board-wrap{color:#f2f2f7;}
    .board-sub{color:#8e8e93;}
    .col{background:#1c1c1e;border-color:#2c2c2e;}
    .col-name{color:#98989d;}
    .count{background:#2c2c2e;color:#98989d;}
    .card{background:#2c2c2e;border-color:#3a3a3c;box-shadow:none;}
    .card:hover{border-color:#48484a;box-shadow:0 4px 12px rgba(0,0,0,.4);}
    .card-meta{color:#8e8e93;}
  }
</style>

<script>
  var cards = [
    {title:"Draft onboarding email", meta:"Growth · due Fri", stage:0},
    {title:"Fix login redirect bug", meta:"Eng · high priority", stage:0},
    {title:"Update pricing page copy", meta:"Marketing · M. Ortiz", stage:1},
    {title:"Q3 roadmap review", meta:"Product · 2 reviewers", stage:1},
    {title:"Migrate analytics events", meta:"Data · shipped", stage:2},
    {title:"Design new empty states", meta:"Design · approved", stage:2}
  ];
  var bodies = document.querySelectorAll("[data-body]");
  var counts = document.querySelectorAll("[data-count]");

  function render(){
    for(var s=0;s<3;s++){ bodies[s].innerHTML=""; }
    var tallies=[0,0,0];
    cards.forEach(function(c){
      tallies[c.stage]++;
      var el=document.createElement("div");
      el.className="card";
      var t=document.createElement("p"); t.className="card-title"; t.textContent=c.title;
      var m=document.createElement("p"); m.className="card-meta"; m.textContent=c.meta;
      el.appendChild(t); el.appendChild(m);
      el.addEventListener("click", function(){
        c.stage = (c.stage + 1) % 3;
        render();
      });
      bodies[c.stage].appendChild(el);
    });
    for(var i=0;i<3;i++){ counts[i].textContent = tallies[i]; }
  }
  render();
</script>
"""

    private static let dashboardHTML = """
<h2 class="sr-only">Metrics dashboard with summary cards and a bar chart, switchable across 7, 30, and 90 day ranges.</h2>
<style>
  .dash { font-family: -apple-system, system-ui, sans-serif; color: #1c1c1e; padding: 4px 0 8px; }
  .dash-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; margin-bottom: 18px; }
  .dash-head h1 { font-size: 22px; font-weight: 500; margin: 0; }
  .seg { display: inline-flex; background: rgba(120,120,128,0.12); border-radius: 9px; padding: 3px; gap: 2px; }
  .seg button { font: inherit; font-size: 13px; border: 0; background: transparent; color: #6b6b70; padding: 5px 13px; border-radius: 7px; cursor: pointer; transition: background .15s, color .15s; }
  .seg button.on { background: #fff; color: #1c1c1e; box-shadow: 0 1px 2px rgba(0,0,0,0.12); }
  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 12px; margin-bottom: 22px; }
  .card { background: rgba(120,120,128,0.08); border-radius: 12px; padding: 14px 16px; }
  .card .lbl { font-size: 13px; color: #6b6b70; margin: 0 0 6px; }
  .card .num { font-size: 26px; font-weight: 500; margin: 0; letter-spacing: -0.4px; }
  .card .delta { font-size: 12px; font-weight: 500; margin: 5px 0 0; }
  .up { color: #1a7f4b; } .down { color: #c0392b; }
  .chart-wrap { background: rgba(120,120,128,0.06); border: 0.5px solid rgba(120,120,128,0.22); border-radius: 12px; padding: 16px 18px; }
  .chart-title { font-size: 13px; color: #6b6b70; margin: 0 0 14px; }
  .bar-row { display: flex; align-items: center; gap: 12px; margin: 9px 0; }
  .bar-name { flex: 0 0 78px; font-size: 13px; color: #46464a; }
  .bar-track { flex: 1; background: rgba(120,120,128,0.14); border-radius: 6px; height: 22px; overflow: hidden; }
  .bar-fill { height: 100%; width: 0; background: #3266ad; border-radius: 6px; transition: width .5s ease; }
  .bar-val { flex: 0 0 52px; text-align: right; font-size: 13px; font-weight: 500; }
  @media (prefers-color-scheme: dark) {
    .dash { color: #f2f2f5; }
    .seg { background: rgba(120,120,128,0.24); }
    .seg button { color: #a0a0a8; }
    .seg button.on { background: #48484c; color: #fff; box-shadow: none; }
    .card { background: rgba(120,120,128,0.16); }
    .card .lbl, .chart-title { color: #a0a0a8; }
    .bar-name { color: #c4c4cb; }
    .chart-wrap { background: rgba(120,120,128,0.10); border-color: rgba(120,120,128,0.30); }
    .bar-fill { background: #5a9be6; }
    .up { color: #4cd07d; } .down { color: #ff6b5e; }
  }
</style>

<div class="dash">
  <div class="dash-head">
    <h1>__APP_TITLE__</h1>
    <div class="seg" id="seg">
      <button data-k="7d" class="on">7d</button>
      <button data-k="30d">30d</button>
      <button data-k="90d">90d</button>
    </div>
  </div>

  <div class="cards" id="cards"></div>

  <div class="chart-wrap">
    <p class="chart-title">Sessions by channel</p>
    <div id="bars"></div>
  </div>
</div>

<script>
  var DATA = {
    "7d": {
      cards: [
        { lbl: "Active users", num: "1,284", d: "+8.2%", up: true },
        { lbl: "Sessions", num: "3,910", d: "+4.1%", up: true },
        { lbl: "Avg. duration", num: "4m 12s", d: "-1.3%", up: false },
        { lbl: "Conversion", num: "3.6%", d: "+0.4%", up: true }
      ],
      bars: [
        { name: "Direct", v: 1420 }, { name: "Search", v: 1180 },
        { name: "Social", v: 760 }, { name: "Referral", v: 390 },
        { name: "Email", v: 160 }
      ]
    },
    "30d": {
      cards: [
        { lbl: "Active users", num: "5,640", d: "+12.7%", up: true },
        { lbl: "Sessions", num: "16,240", d: "+9.0%", up: true },
        { lbl: "Avg. duration", num: "4m 38s", d: "+2.1%", up: true },
        { lbl: "Conversion", num: "3.9%", d: "-0.2%", up: false }
      ],
      bars: [
        { name: "Direct", v: 5800 }, { name: "Search", v: 5120 },
        { name: "Social", v: 3050 }, { name: "Referral", v: 1480 },
        { name: "Email", v: 790 }
      ]
    },
    "90d": {
      cards: [
        { lbl: "Active users", num: "18,910", d: "+21.4%", up: true },
        { lbl: "Sessions", num: "52,380", d: "+15.6%", up: true },
        { lbl: "Avg. duration", num: "4m 51s", d: "+3.8%", up: true },
        { lbl: "Conversion", num: "4.2%", d: "+0.6%", up: true }
      ],
      bars: [
        { name: "Direct", v: 19200 }, { name: "Search", v: 17400 },
        { name: "Social", v: 9600 }, { name: "Referral", v: 4900 },
        { name: "Email", v: 2300 }
      ]
    }
  };

  var cardsEl = document.getElementById("cards");
  var barsEl = document.getElementById("bars");
  var seg = document.getElementById("seg");

  function render(key) {
    var d = DATA[key];
    cardsEl.innerHTML = d.cards.map(function (c) {
      var cls = c.up ? "up" : "down";
      var arrow = c.up ? "+" : "";
      return "<div class='card'><p class='lbl'>" + c.lbl + "</p><p class='num'>" + c.num +
        "</p><p class='delta " + cls + "'>" + c.d + "</p></div>";
    }).join("");

    var max = d.bars.reduce(function (m, b) { return Math.max(m, b.v); }, 0);
    barsEl.innerHTML = d.bars.map(function (b) {
      var pct = Math.round((b.v / max) * 100);
      return "<div class='bar-row'><span class='bar-name'>" + b.name +
        "</span><span class='bar-track'><span class='bar-fill' data-w='" + pct +
        "'></span></span><span class='bar-val'>" + b.v.toLocaleString() + "</span></div>";
    }).join("");

    requestAnimationFrame(function () {
      var fills = barsEl.querySelectorAll(".bar-fill");
      for (var i = 0; i < fills.length; i++) {
        fills[i].style.width = fills[i].getAttribute("data-w") + "%";
      }
    });
  }

  seg.addEventListener("click", function (e) {
    var btn = e.target.closest("button");
    if (!btn) return;
    var btns = seg.querySelectorAll("button");
    for (var i = 0; i < btns.length; i++) btns[i].classList.remove("on");
    btn.classList.add("on");
    render(btn.getAttribute("data-k"));
  });

  render("7d");
</script>
"""

    private static let formHTML = """
<h2 class="sr-only">A request intake form with validation and a submitted summary.</h2>
<style>
  .fs-wrap { max-width: 560px; margin: 0 auto; padding: 1rem 0; font-family: -apple-system, system-ui, sans-serif; color: var(--color-text-primary); }
  .fs-card { background: var(--color-background-primary); border: 0.5px solid var(--color-border-tertiary); border-radius: var(--border-radius-lg); padding: 1.5rem; }
  .fs-h { font-size: 22px; font-weight: 500; margin: 0 0 0.25rem; }
  .fs-sub { font-size: 14px; color: var(--color-text-secondary); margin: 0 0 1.5rem; }
  .fs-field { margin-bottom: 1.1rem; }
  .fs-label { display: block; font-size: 13px; font-weight: 500; margin-bottom: 6px; }
  .fs-input, .fs-select, .fs-area { width: 100%; box-sizing: border-box; font-family: inherit; }
  .fs-area { min-height: 84px; resize: vertical; padding: 8px 10px; }
  .fs-check { display: flex; align-items: flex-start; gap: 10px; font-size: 14px; color: var(--color-text-secondary); cursor: pointer; }
  .fs-check input { margin-top: 2px; }
  .fs-err { color: var(--color-text-danger); font-size: 12px; margin: 5px 0 0; display: none; }
  .fs-invalid { border-color: var(--color-border-danger) !important; box-shadow: 0 0 0 2px var(--color-border-danger); }
  .fs-actions { display: flex; gap: 10px; margin-top: 1.5rem; }
  .fs-btn-primary { background: var(--color-text-info); color: var(--color-background-primary); border: none; padding: 9px 18px; border-radius: var(--border-radius-md); font-family: inherit; font-size: 14px; font-weight: 500; cursor: pointer; }
  .fs-summary { background: var(--color-background-secondary); border-radius: var(--border-radius-md); padding: 1.25rem; }
  .fs-srow { display: flex; justify-content: space-between; gap: 16px; padding: 8px 0; border-bottom: 0.5px solid var(--color-border-tertiary); font-size: 14px; }
  .fs-srow:last-child { border-bottom: none; }
  .fs-skey { color: var(--color-text-secondary); }
  .fs-sval { text-align: right; max-width: 65%; word-break: break-word; }
  .fs-badge { display: inline-flex; align-items: center; gap: 6px; background: var(--color-background-success); color: var(--color-text-success); font-size: 12px; font-weight: 500; padding: 4px 12px; border-radius: var(--border-radius-md); margin-bottom: 14px; }
  .fs-hidden { display: none; }
</style>
<div class="fs-wrap">
  <div class="fs-card">
    <h1 class="fs-h">__APP_TITLE__</h1>
    <p class="fs-sub">Fill in the details below and submit your request.</p>

    <form id="fs-form" novalidate>
      <div class="fs-field">
        <label class="fs-label" for="fs-name">Full name</label>
        <input class="fs-input" id="fs-name" type="text" placeholder="e.g. Maya Rodriguez" />
        <p class="fs-err" id="fs-name-err">Please enter your name.</p>
      </div>
      <div class="fs-field">
        <label class="fs-label" for="fs-topic">Request type</label>
        <select class="fs-select" id="fs-topic">
          <option value="" disabled selected>Choose a type</option>
          <option>Feature request</option>
          <option>Bug report</option>
          <option>Account help</option>
          <option>Billing question</option>
          <option>Other</option>
        </select>
        <p class="fs-err" id="fs-topic-err">Please choose a request type.</p>
      </div>
      <div class="fs-field">
        <label class="fs-label" for="fs-date">Needed by</label>
        <input class="fs-input" id="fs-date" type="date" />
        <p class="fs-err" id="fs-date-err">Please pick a date.</p>
      </div>
      <div class="fs-field">
        <label class="fs-label" for="fs-notes">Details</label>
        <textarea class="fs-area" id="fs-notes" placeholder="Describe what you need in a sentence or two..."></textarea>
        <p class="fs-err" id="fs-notes-err">Please add some details.</p>
      </div>
      <div class="fs-field">
        <label class="fs-check">
          <input type="checkbox" id="fs-agree" />
          <span>I confirm the information above is accurate.</span>
        </label>
        <p class="fs-err" id="fs-agree-err">You must confirm before submitting.</p>
      </div>
      <div class="fs-actions">
        <button type="submit" class="fs-btn-primary">Submit request</button>
      </div>
    </form>

    <div id="fs-result" class="fs-hidden">
      <span class="fs-badge"><i class="ti ti-circle-check" aria-hidden="true"></i> Submitted</span>
      <div class="fs-summary" id="fs-summary"></div>
      <div class="fs-actions">
        <button type="button" class="fs-btn-primary" id="fs-reset">Reset</button>
      </div>
    </div>
  </div>
</div>
<script>
  (function () {
    var form = document.getElementById('fs-form');
    var result = document.getElementById('fs-result');
    var summary = document.getElementById('fs-summary');

    var fields = [
      { id: 'fs-name', err: 'fs-name-err', label: 'Full name', type: 'text' },
      { id: 'fs-topic', err: 'fs-topic-err', label: 'Request type', type: 'text' },
      { id: 'fs-date', err: 'fs-date-err', label: 'Needed by', type: 'date' },
      { id: 'fs-notes', err: 'fs-notes-err', label: 'Details', type: 'text' },
      { id: 'fs-agree', err: 'fs-agree-err', label: 'Confirmed', type: 'check' }
    ];

    function setError(field, show) {
      var el = document.getElementById(field.id);
      var errEl = document.getElementById(field.err);
      errEl.style.display = show ? 'block' : 'none';
      if (field.type === 'check') return;
      if (show) { el.classList.add('fs-invalid'); } else { el.classList.remove('fs-invalid'); }
    }

    function value(field) {
      var el = document.getElementById(field.id);
      if (field.type === 'check') return el.checked;
      return el.value.trim();
    }

    function isEmpty(field) {
      var v = value(field);
      if (field.type === 'check') return v !== true;
      return v.length === 0;
    }

    function prettyDate(raw) {
      if (!raw) return '';
      var parts = raw.split('-');
      if (parts.length !== 3) return raw;
      var months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      var m = parseInt(parts[1], 10) - 1;
      return months[m] + ' ' + parseInt(parts[2], 10) + ', ' + parts[0];
    }

    fields.forEach(function (f) {
      var el = document.getElementById(f.id);
      var ev = f.type === 'check' ? 'change' : 'input';
      el.addEventListener(ev, function () {
        if (!isEmpty(f)) setError(f, false);
      });
      el.addEventListener('change', function () {
        if (!isEmpty(f)) setError(f, false);
      });
    });

    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var ok = true;
      fields.forEach(function (f) {
        var empty = isEmpty(f);
        setError(f, empty);
        if (empty) ok = false;
      });
      if (!ok) return;

      var rows = [
        ['Full name', value(fields[0])],
        ['Request type', value(fields[1])],
        ['Needed by', prettyDate(value(fields[2]))],
        ['Details', value(fields[3])],
        ['Confirmed', 'Yes']
      ];
      var html = '';
      rows.forEach(function (r) {
        html += '<div class="fs-srow"><span class="fs-skey">' + r[0] + '</span><span class="fs-sval">' + r[1] + '</span></div>';
      });
      summary.innerHTML = html;
      form.classList.add('fs-hidden');
      result.classList.remove('fs-hidden');
    });

    document.getElementById('fs-reset').addEventListener('click', function () {
      form.reset();
      fields.forEach(function (f) { setError(f, false); });
      result.classList.add('fs-hidden');
      form.classList.remove('fs-hidden');
    });
  })();
</script>
"""

    private static let genericHTML = """
<style>
  .ga-root { font-family: -apple-system, system-ui, sans-serif; max-width: 760px; margin: 0 auto; padding: 20px; color: #1c1c1e; }
  .ga-header { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; margin-bottom: 18px; flex-wrap: wrap; }
  .ga-title { font-size: 26px; font-weight: 700; letter-spacing: -0.02em; margin: 0; }
  .ga-sub { font-size: 13px; color: #8a8a8e; }
  .ga-tabs { display: inline-flex; background: #f0f0f3; border-radius: 10px; padding: 3px; gap: 2px; margin-bottom: 20px; }
  .ga-tab { border: 0; background: transparent; font: inherit; font-size: 14px; font-weight: 500; color: #6c6c70; padding: 7px 18px; border-radius: 8px; cursor: pointer; transition: background 0.15s, color 0.15s; }
  .ga-tab.active { background: #fff; color: #1c1c1e; box-shadow: 0 1px 3px rgba(0,0,0,0.12); }
  .ga-panel { display: none; }
  .ga-panel.active { display: block; }
  .ga-tiles { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px; }
  .ga-tile { background: #fff; border: 1px solid #e5e5ea; border-radius: 14px; padding: 18px; }
  .ga-tile-label { font-size: 12px; color: #8a8a8e; text-transform: uppercase; letter-spacing: 0.04em; }
  .ga-tile-value { font-size: 30px; font-weight: 700; margin-top: 6px; letter-spacing: -0.02em; }
  .ga-tile-delta { font-size: 13px; margin-top: 4px; color: #34c759; }
  .ga-list { list-style: none; padding: 0; margin: 0; border: 1px solid #e5e5ea; border-radius: 14px; overflow: hidden; background: #fff; }
  .ga-item { display: flex; align-items: center; justify-content: space-between; padding: 14px 16px; border-bottom: 1px solid #f0f0f3; cursor: pointer; transition: background 0.12s; }
  .ga-item:last-child { border-bottom: 0; }
  .ga-item:hover { background: #f7f7fa; }
  .ga-item.done .ga-item-name { text-decoration: line-through; color: #b0b0b5; }
  .ga-item-name { font-size: 15px; font-weight: 500; }
  .ga-item-meta { font-size: 12px; color: #8a8a8e; }
  .ga-badge { font-size: 11px; font-weight: 600; padding: 3px 9px; border-radius: 20px; background: #eef1ff; color: #4b5bd6; }
  .ga-row { display: flex; align-items: center; justify-content: space-between; padding: 16px; background: #fff; border: 1px solid #e5e5ea; border-radius: 14px; margin-bottom: 12px; }
  .ga-row-label { font-size: 15px; font-weight: 500; }
  .ga-row-hint { font-size: 12px; color: #8a8a8e; margin-top: 2px; }
  .ga-toggle { width: 50px; height: 30px; border-radius: 16px; border: 0; background: #d1d1d6; cursor: pointer; position: relative; transition: background 0.18s; flex-shrink: 0; }
  .ga-toggle.on { background: #34c759; }
  .ga-knob { position: absolute; top: 3px; left: 3px; width: 24px; height: 24px; border-radius: 50%; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,0.3); transition: left 0.18s; }
  .ga-toggle.on .ga-knob { left: 23px; }
  .ga-stepper { display: inline-flex; align-items: center; gap: 14px; }
  .ga-step-btn { width: 32px; height: 32px; border-radius: 8px; border: 1px solid #e5e5ea; background: #f7f7fa; font-size: 18px; font-weight: 600; color: #1c1c1e; cursor: pointer; line-height: 1; }
  .ga-step-btn:active { background: #e5e5ea; }
  .ga-step-val { font-size: 17px; font-weight: 600; min-width: 28px; text-align: center; }
  .ga-root.dark { color: #f2f2f7; }
  .ga-root.dark .ga-sub, .ga-root.dark .ga-tile-label, .ga-root.dark .ga-item-meta, .ga-root.dark .ga-row-hint { color: #98989f; }
  .ga-root.dark .ga-tabs { background: #2c2c2e; }
  .ga-root.dark .ga-tab { color: #98989f; }
  .ga-root.dark .ga-tab.active { background: #48484a; color: #fff; }
  .ga-root.dark .ga-tile, .ga-root.dark .ga-list, .ga-root.dark .ga-row { background: #1c1c1e; border-color: #38383a; }
  .ga-root.dark .ga-item { border-color: #2c2c2e; }
  .ga-root.dark .ga-item:hover { background: #2c2c2e; }
  .ga-root.dark .ga-step-btn { background: #2c2c2e; border-color: #38383a; color: #f2f2f7; }
  .ga-root.dark .ga-badge { background: #2a2f4d; color: #aab4ff; }
  @media (prefers-color-scheme: dark) {
    .ga-root { color: #f2f2f7; }
    .ga-sub, .ga-tile-label, .ga-item-meta, .ga-row-hint { color: #98989f; }
    .ga-tabs { background: #2c2c2e; }
    .ga-tab { color: #98989f; }
    .ga-tab.active { background: #48484a; color: #fff; }
    .ga-tile, .ga-list, .ga-row { background: #1c1c1e; border-color: #38383a; }
    .ga-item { border-color: #2c2c2e; }
    .ga-item:hover { background: #2c2c2e; }
    .ga-step-btn { background: #2c2c2e; border-color: #38383a; color: #f2f2f7; }
    .ga-badge { background: #2a2f4d; color: #aab4ff; }
  }
</style>

<div class="ga-root" id="gaRoot">
  <div class="ga-header">
    <h1 class="ga-title">__APP_TITLE__</h1>
    <span class="ga-sub">Updated just now</span>
  </div>

  <div class="ga-tabs" id="gaTabs">
    <button class="ga-tab active" data-panel="overview">Overview</button>
    <button class="ga-tab" data-panel="items">Items</button>
    <button class="ga-tab" data-panel="settings">Settings</button>
  </div>

  <div class="ga-panel active" data-panel="overview">
    <div class="ga-tiles">
      <div class="ga-tile"><div class="ga-tile-label">Active</div><div class="ga-tile-value">128</div><div class="ga-tile-delta">+12 this week</div></div>
      <div class="ga-tile"><div class="ga-tile-label">Pending</div><div class="ga-tile-value">7</div><div class="ga-tile-delta" style="color:#ff9500">3 due today</div></div>
      <div class="ga-tile"><div class="ga-tile-label">Completed</div><div class="ga-tile-value">94%</div><div class="ga-tile-delta">+2.4%</div></div>
    </div>
  </div>

  <div class="ga-panel" data-panel="items">
    <ul class="ga-list" id="gaList">
      <li class="ga-item"><div><div class="ga-item-name">Quarterly report draft</div><div class="ga-item-meta">Owner: Dana · Updated 2h ago</div></div><span class="ga-badge">In review</span></li>
      <li class="ga-item"><div><div class="ga-item-name">Onboarding checklist</div><div class="ga-item-meta">Owner: Priya · Updated yesterday</div></div><span class="ga-badge">Active</span></li>
      <li class="ga-item"><div><div class="ga-item-name">API rate-limit fix</div><div class="ga-item-meta">Owner: Marco · Updated 3d ago</div></div><span class="ga-badge">Blocked</span></li>
      <li class="ga-item"><div><div class="ga-item-name">Design system audit</div><div class="ga-item-meta">Owner: Lin · Updated 5d ago</div></div><span class="ga-badge">Active</span></li>
    </ul>
    <p class="ga-sub" style="margin-top:10px">Tap a row to mark it done.</p>
  </div>

  <div class="ga-panel" data-panel="settings">
    <div class="ga-row">
      <div><div class="ga-row-label">Dark appearance</div><div class="ga-row-hint">Override the system theme</div></div>
      <button class="ga-toggle" id="gaTheme" aria-label="Toggle dark mode"><span class="ga-knob"></span></button>
    </div>
    <div class="ga-row">
      <div><div class="ga-row-label">Items per page</div><div class="ga-row-hint">How many rows to show at once</div></div>
      <div class="ga-stepper">
        <button class="ga-step-btn" id="gaMinus">-</button>
        <span class="ga-step-val" id="gaStepVal">10</span>
        <button class="ga-step-btn" id="gaPlus">+</button>
      </div>
    </div>
  </div>
</div>

<script>
  (function () {
    var root = document.getElementById('gaRoot');
    var tabs = root.querySelectorAll('.ga-tab');
    var panels = root.querySelectorAll('.ga-panel');
    tabs.forEach(function (tab) {
      tab.addEventListener('click', function () {
        var target = tab.getAttribute('data-panel');
        tabs.forEach(function (t) { t.classList.toggle('active', t === tab); });
        panels.forEach(function (p) { p.classList.toggle('active', p.getAttribute('data-panel') === target); });
      });
    });

    root.querySelectorAll('.ga-item').forEach(function (item) {
      item.addEventListener('click', function () { item.classList.toggle('done'); });
    });

    var themeBtn = document.getElementById('gaTheme');
    themeBtn.addEventListener('click', function () {
      var on = themeBtn.classList.toggle('on');
      root.classList.toggle('dark', on);
    });

    var val = 10;
    var valEl = document.getElementById('gaStepVal');
    document.getElementById('gaMinus').addEventListener('click', function () {
      if (val > 1) { val -= 1; valEl.textContent = val; }
    });
    document.getElementById('gaPlus').addEventListener('click', function () {
      if (val < 99) { val += 1; valEl.textContent = val; }
    });
  })();
</script>
"""

    private static let listHTML = """
<style>
  .plist-wrap {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    color: #1d1d22;
    max-width: 760px;
    margin: 0 auto;
    padding: 4px;
  }
  .plist-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    flex-wrap: wrap;
    margin-bottom: 14px;
  }
  .plist-title { font-size: 21px; font-weight: 680; letter-spacing: -0.01em; margin: 0; }
  .plist-sub { font-size: 13px; color: #71717a; margin: 3px 0 0; }
  .plist-sort { display: flex; align-items: center; gap: 8px; }
  .plist-sort label { font-size: 12px; color: #71717a; font-weight: 560; }
  .plist-sort select {
    font: inherit; font-size: 13px; padding: 7px 10px;
    border: 1px solid #e0e0e6; border-radius: 9px; background: #fff;
    color: inherit; cursor: pointer;
  }
  .plist-table { border: 1px solid #e8e8ee; border-radius: 14px; overflow: hidden; background: #fff; }
  .plist-row {
    display: grid;
    grid-template-columns: 4px 1fr auto auto auto;
    align-items: center;
    gap: 14px;
    padding: 12px 16px 12px 0;
    border-top: 1px solid #f0f0f4;
    cursor: default;
    transition: background 0.12s ease;
  }
  .plist-row:first-of-type { border-top: none; }
  .plist-row:nth-child(even) { background: #fafafb; }
  .plist-row:hover { background: #f3f4f8; }
  .accent { width: 4px; align-self: stretch; border-radius: 0 3px 3px 0; }
  .accent.high { background: #e0483d; }
  .accent.medium { background: #e0992f; }
  .accent.low { background: #3d8be0; }
  .cell-main { min-width: 0; }
  .row-title { font-size: 14px; font-weight: 560; margin: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .row-proj { font-size: 12px; color: #8a8a93; margin: 2px 0 0; }
  .badge {
    font-size: 12px; font-weight: 620; font-variant-numeric: tabular-nums;
    background: #eef0f4; color: #50505a; padding: 4px 9px; border-radius: 999px;
    white-space: nowrap;
  }
  .age { font-size: 12.5px; color: #8a8a93; font-variant-numeric: tabular-nums; min-width: 34px; text-align: right; }
  .pill {
    font-size: 11.5px; font-weight: 640; padding: 4px 11px; border-radius: 999px; white-space: nowrap;
  }
  .pill.high { background: #fbe5e3; color: #b6342a; }
  .pill.medium { background: #fbefdc; color: #98661a; }
  .pill.low { background: #e2eefb; color: #2a64a8; }
  @media (prefers-color-scheme: dark) {
    .plist-wrap { color: #e8e8ec; }
    .plist-sub, .plist-sort label { color: #9a9aa3; }
    .plist-sort select { background: #1c1c20; border-color: #38383f; color: #e8e8ec; }
    .plist-table { background: #161619; border-color: #2c2c32; }
    .plist-row { border-top-color: #232328; }
    .plist-row:nth-child(even) { background: #1a1a1e; }
    .plist-row:hover { background: #25252b; }
    .row-proj, .age { color: #8d8d96; }
    .badge { background: #2a2a30; color: #c2c2cc; }
  }
</style>

<div class="plist-wrap">
  <div class="plist-head">
    <div>
      <h1 class="plist-title">__APP_TITLE__</h1>
      <p class="plist-sub" id="summary">6 items</p>
    </div>
    <div class="plist-sort">
      <label for="sortby">Sort</label>
      <select id="sortby">
        <option value="comments">Most comments</option>
        <option value="age">Oldest first</option>
        <option value="title">Title (A-Z)</option>
        <option value="project">Project</option>
      </select>
    </div>
  </div>

  <div class="plist-table" id="list">
    <div class="plist-row" data-comments="14" data-age="12" data-title="Fix flaky auth test" data-project="astra-core" data-prio="high">
      <span class="accent high"></span>
      <div class="cell-main"><p class="row-title">Fix flaky auth test</p><p class="row-proj">astra-core</p></div>
      <span class="badge">14</span><span class="age">12d</span><span class="pill high">High</span>
    </div>
    <div class="plist-row" data-comments="3" data-age="31" data-title="Add dark-mode tokens" data-project="design-sys" data-prio="low">
      <span class="accent low"></span>
      <div class="cell-main"><p class="row-title">Add dark-mode tokens</p><p class="row-proj">design-sys</p></div>
      <span class="badge">3</span><span class="age">31d</span><span class="pill low">Low</span>
    </div>
    <div class="plist-row" data-comments="9" data-age="5" data-title="Refactor preview shelf" data-project="app-studio" data-prio="medium">
      <span class="accent medium"></span>
      <div class="cell-main"><p class="row-title">Refactor preview shelf</p><p class="row-proj">app-studio</p></div>
      <span class="badge">9</span><span class="age">5d</span><span class="pill medium">Medium</span>
    </div>
    <div class="plist-row" data-comments="21" data-age="2" data-title="Sandbox egress audit" data-project="astra-core" data-prio="high">
      <span class="accent high"></span>
      <div class="cell-main"><p class="row-title">Sandbox egress audit</p><p class="row-proj">astra-core</p></div>
      <span class="badge">21</span><span class="age">2d</span><span class="pill high">High</span>
    </div>
    <div class="plist-row" data-comments="6" data-age="18" data-title="Capsule query conditioning" data-project="capsule" data-prio="medium">
      <span class="accent medium"></span>
      <div class="cell-main"><p class="row-title">Capsule query conditioning</p><p class="row-proj">capsule</p></div>
      <span class="badge">6</span><span class="age">18d</span><span class="pill medium">Medium</span>
    </div>
    <div class="plist-row" data-comments="1" data-age="44" data-title="Bump VERSION docs" data-project="docs" data-prio="low">
      <span class="accent low"></span>
      <div class="cell-main"><p class="row-title">Bump VERSION docs</p><p class="row-proj">docs</p></div>
      <span class="badge">1</span><span class="age">44d</span><span class="pill low">Low</span>
    </div>
  </div>
</div>

<script>
  (function () {
    var list = document.getElementById("list");
    var select = document.getElementById("sortby");
    var summary = document.getElementById("summary");
    var comparators = {
      comments: function (a, b) { return Number(b.dataset.comments) - Number(a.dataset.comments); },
      age: function (a, b) { return Number(b.dataset.age) - Number(a.dataset.age); },
      title: function (a, b) { return a.dataset.title.localeCompare(b.dataset.title); },
      project: function (a, b) { return a.dataset.project.localeCompare(b.dataset.project); }
    };
    function render(key) {
      var rows = Array.prototype.slice.call(list.querySelectorAll(".plist-row"));
      rows.sort(comparators[key] || comparators.comments);
      rows.forEach(function (r) { list.appendChild(r); });
      summary.textContent = rows.length + " items";
    }
    select.addEventListener("change", function () { render(select.value); });
    render(select.value);
  })();
</script>
"""
}
