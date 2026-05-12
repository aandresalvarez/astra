# Data Query Shelf V1 Plan

## Goal

Add a task-aware SQL shelf for data engineering and data science workflows. The shelf should let users edit, dry-run, run, inspect, visualize, and recover SQL work from ASTRA tasks without making the main task view more crowded.

V1 starts with BigQuery through the existing capability model, but the product and code architecture must remain database-agnostic.

## Product Principles

- Connection first, dialect derived. Users choose a connection; ASTRA infers the SQL flavor and execution rules.
- Read-only by default. `SELECT` and `WITH` are the normal run path.
- Mutations require an explicit recovery plan before execution.
- Dry run is the default preflight for engines that support it, especially BigQuery.
- The shelf is task-aware: SQL files, SQL blocks, query errors, and query results from a task can open in the shelf.
- Main task pane remains an index. The shelf is the focused SQL workbench.

## V1 User Experience

Add a new top-right shelf button:

- Label/help: `Show Query Shelf`
- Icon candidate: `cylinder.split.1x2`, `tablecells`, or `terminal`
- Visible when any of these are true:
  - workspace has a database capability enabled
  - selected task has detected SQL content or `.sql` files
  - query shelf is already open

The Query Shelf layout:

- Top bar:
  - connection selector
  - dialect indicator/selector
  - default dataset/schema selector when available
  - `Dry Run`
  - `Run`
- Main editor:
  - SQL text editor
  - read-only/generated query state vs editable query state
  - format SQL
  - copy query
- Bottom workspace tabs:
  - `Results`
  - `Chart`
  - `Explain`
  - `History`
  - `Schema`

## Connection And Dialect Model

Represent these separately:

- `DatabaseConnection`: where the query runs.
- `SQLDialect`: how SQL is parsed, highlighted, formatted, and classified.
- `DatabaseAdapter`: execution implementation for dry run, run, schema, and recovery.

V1 supported modes:

- `No connection / Edit only`
- `BigQuery / BigQuery Standard SQL`

Future adapters:

- Postgres
- Snowflake
- DuckDB
- SQLite
- Databricks SQL
- Redshift

## Query Classification

Before execution, classify SQL into:

- read query: `SELECT`, `WITH`
- DDL: `CREATE`, `ALTER`, `DROP`
- DML: `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `TRUNCATE`
- script or unknown

V1 behavior:

- Read queries can dry-run and run.
- DDL/DML/script queries show a mutation warning.
- Mutation execution is disabled unless a recovery plan exists or the query writes only to a new/staging table.

## BigQuery V1 Adapter

The BigQuery adapter should support:

- connection discovery from the BigQuery capability configuration
- selected project, dataset, and location
- dry run with bytes processed estimate
- query execution with row limit
- result schema and preview rows
- job ID capture
- error capture
- result export metadata

V1 can use the existing BigQuery capability/tooling path. If that path only supports agent-side execution, add a small app-side service boundary first so the shelf can call it directly later.

## Recovery Model

The shelf should expose a recovery strip above execution controls.

Read query:

```text
Read query
No rollback needed
```

Mutation query:

```text
Mutation query
Recovery required before run
Affected table: dataset.table
Recovery: snapshot or copy backup
```

Recovery tiers:

- Transaction rollback for engines that support it.
- Snapshot/copy backup for BigQuery.
- Staging table write for transformations.
- Explicit user override only after strong warning.

BigQuery V1 recovery options:

- create table snapshot before mutation
- copy affected table to backup table
- run write into staging table first
- store restore SQL or restore instructions
- record BigQuery job IDs and backup table IDs

V1 mutation policy:

- Allow read queries.
- Allow `CREATE TABLE ... AS SELECT` only when target table does not already exist.
- Block destructive DML/DDL unless recovery creation succeeds.

## Results Grid

V1 results should include:

- column names and types
- row preview
- sortable columns if cheap locally
- copy cell, row, and table
- export CSV/JSON
- row limit indicator
- elapsed time
- bytes processed
- job ID

Do not build a full BI grid in V1. Keep it fast and readable.

## Chart Mode

V1 charting should be lightweight:

- date/time + numeric -> line chart
- category + numeric -> bar chart
- two numeric columns -> scatter

The chart tab should auto-suggest a chart but let users change x/y columns.

Skip maps, dashboards, and complex chart configuration in V1.

## Schema Explorer

V1 schema tab:

- list datasets/schemas if adapter supports it
- list tables
- show columns and types
- insert table name into editor
- insert selected columns into editor

If schema APIs are not ready, show a placeholder with an adapter capability warning and prioritize dry-run/run first.

## Query History

Store query executions task-scoped first:

- SQL text
- connection ID
- dialect
- classification
- dry-run result
- execution result
- job ID
- status
- error message
- result row count
- bytes processed
- recovery metadata
- timestamp

Workspace-scoped saved queries can come after task-scoped history.

## Agent Integration

Actions from the shelf:

- `Ask agent to explain query`
- `Ask agent to fix error`
- `Ask agent to optimize query`
- `Ask agent to summarize results`
- `Create follow-up task`
- `Attach results to task`

When a query fails, include:

- SQL
- selected connection/dialect
- error text
- dry-run metadata
- schema context if available

## Data Model Sketch

```swift
enum SQLDialect {
    case bigQueryStandard
    case postgres
    case snowflake
    case duckDB
    case sqlite
    case unknown
}

enum QueryClassification {
    case read
    case ddl
    case dml
    case script
    case unknown
}

struct DatabaseConnection {
    var id: String
    var displayName: String
    var adapterID: String
    var dialect: SQLDialect
    var defaultNamespace: String?
}

protocol DatabaseAdapter {
    func dryRun(_ request: QueryRequest) async throws -> QueryDryRunResult
    func run(_ request: QueryRequest) async throws -> QueryExecutionResult
    func schema(_ request: SchemaRequest) async throws -> SchemaCatalog
    func prepareRecovery(_ request: RecoveryRequest) async throws -> RecoveryPlan
}
```

## Implementation Phases

### Phase 1: Shelf Shell

- Add `WorkspaceCanvasItem.query`.
- Add query shelf button to top-right toolbar rules.
- Add `QueryShelfPanelView`.
- Add connection/dialect top bar in edit-only mode.
- Add SQL editor and local query tabs.

### Phase 2: SQL Detection And Routing

- Recognize `.sql` files as query shelf files.
- Detect SQL blocks in task output.
- Add `Open in Query Shelf` from task file popover and task output.
- Keep Text shelf behavior for generic text files.

### Phase 3: BigQuery Dry Run And Run

- Add BigQuery adapter boundary.
- Implement dry run.
- Implement read query execution with row limit.
- Show result grid, bytes processed, duration, and job ID.

### Phase 4: Safety And Recovery

- Add query classification.
- Add mutation warning strip.
- Add BigQuery snapshot/copy backup preparation.
- Store recovery metadata in query history.
- Gate destructive execution behind recovery success.

### Phase 5: Results Enhancements

- Add chart suggestions.
- Add CSV/JSON export.
- Add schema explorer basics.
- Add agent actions for explain/fix/optimize/summarize.

## Verification

Focused tests:

- SQL classification.
- Query shelf toolbar visibility.
- `.sql` routing to query shelf.
- BigQuery dry-run adapter parsing.
- Recovery-plan gating for mutations.
- Query history serialization.

Manual checks:

- `swift test --filter <RelevantSuite>`
- `swift test --filter ViewTests`
- `git diff --check`
- `./script/build_and_run.sh --verify`

