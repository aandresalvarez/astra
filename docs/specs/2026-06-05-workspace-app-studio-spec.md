# Workspace App Studio Product And Architecture Spec

**Status:** Draft product and architecture specification
**Authoring date:** 2026-06-05
**Scope:** Final product direction for chat-built, durable, shareable workspace apps in ASTRA
**Audience:** Product, design, and engineering contributors implementing the Workspace Apps system

## 1. Purpose

This document defines the target product and architecture for **Workspace Apps**
and **App Studio** in ASTRA.

The core goal is:

> Let a user say "build me an app for this process" and get a persistent,
> editable, actionable workspace app with its own storage, UI, automation,
> dashboards, and governed access to the workspace's tools and data.

This is broader than the earlier "Data Apps" framing. Data is often involved,
but the product is not limited to dashboards or database queries. A Workspace
App can be a local database app, a REDCap data-entry replacement, a BigQuery to
REDCap reconciliation tool, a pipeline monitor, a report generator, a review
queue, a lookup tool, or a custom operational surface built from prior ASTRA
conversation context.

The target experience should feel closer to:

- Gradio, because a user can quickly turn logic into an app surface.
- Retool, because apps can connect to data and operations.
- Airtable, because apps can own lightweight structured storage.
- Workflow automation tools, because apps can run processes over time.
- ASTRA, because apps inherit task runtime, capabilities, governance, local
  workspace context, artifacts, and agent reasoning.

The product should not become a generic web-hosted app platform. ASTRA remains
the trusted host, runtime, credential boundary, and workspace owner.

## 2. Product Definition

### 2.1 Workspace App

A **Workspace App** is a durable, user-created tool inside an ASTRA workspace.
It has a name, icon, purpose, app-owned state, UI, actions, optional storage,
optional connector dependencies, optional automations, and an audit trail.

Workspace Apps sit beside tasks as reusable surfaces for repeated work. Tasks
remain episodic work records. Apps are the durable interfaces users come back
to.

Examples:

- "Latest BQ records in REDCap?"
- "REDCap data-entry replacement"
- "Grocery tracker"
- "Weekly enrollment report generator"
- "Missing-record triage queue"
- "Pipeline to speed up this process"
- "Dashboard of latest task outcomes"
- "Form that creates standardized ASTRA tasks"

### 2.2 App Studio

**App Studio** is the chat-based builder and editor for Workspace Apps.

Users describe what they want. ASTRA asks clarifying questions only when needed,
discovers available capabilities, proposes an app design, builds the manifest,
previews the app, validates the app, and publishes it into the workspace.

App Studio can build from:

- A blank request.
- A workspace conversation.
- A completed task and its artifacts.
- A query in the Query shelf.
- A REDCap project or BigQuery table.
- A package imported from another ASTRA installation.
- A previous app that the user wants to clone or adapt.

### 2.3 App Package

An **ASTRA App Package** is the shareable representation of a Workspace App.
It is intended for ASTRA-to-ASTRA sharing only. It contains the app manifest,
view specs, storage schema, actions, automations, required capabilities,
version metadata, and optional sample data. It does not contain credentials or
sensitive cached records by default.

## 3. North Star User Prompts

The final product should handle prompts like these.

### 3.1 BigQuery To REDCap Reconciliation

User:

```text
Build me an app to show the latest records from BigQuery table
clinical.enrollment_candidates and check whether each record exists in our
REDCap project. Present the result in a dashboard.
```

ASTRA builds:

- BigQuery source using the workspace BigQuery capability.
- REDCap source using the workspace REDCap capability.
- Matching rules, such as MRN, participant ID, or study ID.
- Summary metrics: latest records, matched, missing, ambiguous, errored.
- Exception table for missing or ambiguous records.
- Detail view for one row.
- Actions:
  - create ASTRA review task
  - export missing records as CSV
  - prepare REDCap create/update payloads in draft mode
  - submit approved writes if the app is allowed to write
- Refresh button and optional schedule.
- Audit log of reads, writes, approvals, and generated review tasks.

### 3.2 REDCap Data-Entry Replacement

User:

```text
Build me a data entry replacement for this REDCap project.
```

ASTRA builds:

- REDCap project metadata introspection.
- Native form screens from REDCap fields.
- Required-field validation.
- Type validation.
- Choice lists.
- Basic branching logic where it can be represented safely.
- Draft records stored locally until submit.
- Submit action that writes to REDCap only through the declared write mode.
- Review screen before writes.
- Audit trail of draft creation, validation failures, approvals, and submits.

REDCap remains the system of record. ASTRA is the app surface, validation layer,
draft store, and governed submitter.

### 3.3 Local Storage App

User:

```text
Build me a database app to store my groceries.
```

ASTRA builds:

- App-owned SQLite database.
- Tables such as `items`, `stores`, `shopping_lists`, and `purchases`.
- CRUD forms.
- Table views and detail views.
- Metrics:
  - total spend
  - spend by category
  - items bought most often
  - upcoming shopping list
- Charts:
  - category breakdown
  - monthly spend trend
- Actions:
  - add item
  - mark purchased
  - generate shopping list
  - export CSV
  - create reminder task

No external connector is required. The app is still a first-class Workspace App
because app-owned storage is a core primitive.

### 3.4 Pipeline App Ideation

User:

```text
Based on the conversation we had, ideate a pipeline app to speed up this
process.
```

ASTRA analyzes:

- Recent conversation.
- Task goals.
- Generated artifacts.
- Files referenced by the task.
- Available workspace capabilities.
- Repeated manual steps.
- Approval or compliance points.

ASTRA proposes app candidates:

- "Daily reconciliation monitor"
- "Missing REDCap record review queue"
- "Weekly report generator"
- "Data quality pipeline"
- "One-click status update pack"

After the user chooses one, App Studio builds the app with inputs, views,
actions, automations, and approval points.

## 4. Product Principles

### 4.1 Workspace-native

Apps live inside workspaces. They inherit workspace capabilities, files,
tasks, artifacts, and governance. They should not require separate external
configuration unless a dependency is missing.

### 4.2 Chat-built, inspectable, and editable

The user can build and refine apps through natural language, but the resulting
app must be inspectable. ASTRA must show the app's data model, sources,
actions, automations, and permissions in a form that a user can review.

### 4.3 Swift owns state and actions

Swift and ASTRA services own durable state, credentials, approvals, task
creation, connector execution, local storage, and audit trails.

Web or JavaScript surfaces may render advanced visuals, but they do not own
credentials, filesystem access, network access, or privileged actions.

### 4.4 Storage is first-class

Apps can own local structured data. A grocery app, lightweight CRM, study log,
review queue, or local registry should not need an external database.

### 4.5 Capabilities are contracts

Apps should call deterministic capability operations, not rely on an agent to
improvise connector calls for every click.

Agent reasoning is used for building, mapping fields, classification,
summarization, and governed judgment. Routine app execution should be
deterministic when possible.

### 4.6 Source systems remain source systems

For external systems such as REDCap, BigQuery, GitHub, or Slack, ASTRA does not
silently become the source of truth. ASTRA can cache, draft, reconcile, and
submit approved changes, but external systems remain durable owners of their
own records.

### 4.7 Governance is visible before execution

Every app declares what it reads, writes, runs, stores, and schedules. Users can
see the app's permission mode before enabling it.

### 4.8 Share ASTRA apps with ASTRA

App sharing targets other ASTRA installations or workspaces. Exporting as a
standalone website is out of scope for the core product because the app depends
on ASTRA capabilities, storage, tasks, approvals, and local context.

## 5. Non-goals

This system does not require:

- Arbitrary native code plugins.
- Arbitrary JavaScript apps with direct credentials or filesystem access.
- Public web hosting for apps.
- A marketplace in the first product milestone.
- Replacing REDCap, BigQuery, Slack, GitHub, or any other external source of
  truth.
- Building a separate agent task runtime for apps.
- Making every app a dashboard.
- A visual node editor before the chat-builder and manifest model are proven.
- Multi-user permissions in the first local implementation.

## 6. Mental Model

The earlier five archetypes still help as templates:

- Dashboard
- Lookup Tool
- Action Panel
- Monitor
- Pipeline

They should not be the core architecture. The final product should be built on
app primitives.

### 6.1 Core Primitives

Every Workspace App is composed from these primitives.

#### Storage

App-owned data:

- Local tables.
- Records.
- Drafts.
- Cached connector results.
- Run history.
- Audit events.
- Generated artifacts.
- App settings.

#### Sources

Places the app reads from:

- BigQuery.
- REDCap.
- SQLite app tables.
- Files.
- APIs.
- Local tools.
- Browser outputs.
- Prior ASTRA task artifacts.
- Manual user input.
- Other app outputs.

#### Views

How information is presented:

- Forms.
- Tables.
- Record grids.
- Detail views.
- Dashboards.
- Metric cards.
- Charts.
- Diagrams.
- Markdown reports.
- Kanban or review queues.
- Timeline or calendar views.
- Run history.
- Approval cards.

#### Actions

Operations the user or automation can trigger:

- Query data.
- Add or update app-owned record.
- Validate draft.
- Submit REDCap record.
- Export CSV or JSON.
- Send Slack message.
- Create ASTRA task.
- Run ASTRA task.
- Open file.
- Open URL.
- Run approved local tool.
- Refresh dashboard.
- Generate report artifact.

#### Automation

Time-based or event-based behavior:

- Manual run.
- Scheduled refresh.
- Monitor thresholds.
- Pipeline steps.
- Retries.
- Human approval gates.
- Agent judgment gates.
- Notifications.

#### Agent Reasoning

Places where model reasoning is appropriate:

- Build the app manifest.
- Propose app ideas from conversation context.
- Map fields between BigQuery and REDCap.
- Generate validation rules.
- Classify ambiguous records.
- Summarize app results.
- Explain errors.
- Draft task goals.
- Recommend next actions.
- Make governed decisions at explicit agent gates.

#### Governance

Cross-cutting controls:

- Read-only.
- Draft-only.
- Approval-required writes.
- Pre-approved low-risk actions.
- Destructive action confirmation.
- Data classification.
- Audit and provenance.
- Package install review.

### 6.2 Archetypes As Recipes

Archetypes are recipes built from primitives.

| Archetype | Primitive composition |
| --- | --- |
| Dashboard | sources + views + metrics + charts + refresh |
| Lookup Tool | form + source query + detail view + optional action |
| Action Panel | actions + status + audit + optional forms |
| Monitor | source + schedule + thresholds + notifications |
| Pipeline | automation + actions + gates + run history |
| Form App | storage or connector + forms + validation + submit |
| Local Database App | storage + CRUD views + metrics + import/export |
| Reconciliation App | multiple sources + matching rules + exceptions + actions |
| Report Generator | inputs + task/action + artifact preview + export |
| Review Queue | storage or source + table/kanban + assignment/status actions |
| Agentic Workflow | task steps + agent gates + loops + run history + output binding |

The product UI can still offer "start from dashboard" or "start from pipeline"
because those words are understandable. Internally, the app builder should
assemble primitives.

## 7. User Experience

### 7.1 Workspace Placement

Workspace Apps should appear in three places.

#### Workspace Home

The workspace home shows an **Apps** section near the top of the page, before
task-heavy surfaces. It should be scan-first and follow ASTRA's lean UI system.

The section contains:

- Header: `Apps`, count, `New App`.
- App cards with icon, name, short purpose, last status, and last opened or
  refreshed timestamp.
- No empty section when there are no apps. The `New App` button remains visible
  in the workspace home header or primary action area.

#### Sidebar

Apps appear as workspace children near tasks. They use an app icon rather than a
task status circle.

The sidebar should support:

- Open app.
- Open in App Studio.
- Duplicate.
- Export.
- Delete.
- Show missing dependency state.

#### Detail Area

Opening an app renders the app in the detail column. It is not a marketing
landing page. The first screen should be the working app surface.

The detail top bar includes:

- App icon and name.
- Status.
- Refresh or Run button where applicable.
- Edit button.
- Share/export menu.
- Dependency warning if required.

### 7.2 App Studio Builder

App Studio is a builder mode that combines conversation, preview, and
inspectable app state.

Recommended layout:

- Detail area: builder conversation and structured decisions.
- Shelf or side panel: live app preview and validation state.
- Inspector section: sources, storage, actions, automations, permissions.

The builder should avoid asking many up-front questions. It should infer, build
a draft, and ask targeted questions when ambiguity affects safety or app
correctness.

Builder stages:

1. **Intent capture**
   - User describes the app.
   - ASTRA extracts app goal, users, data, actions, and risk hints.

2. **Context discovery**
   - Inspect workspace capabilities.
   - Inspect relevant conversation, task artifacts, files, and existing
     connectors.
   - Identify missing dependencies.

3. **App proposal**
   - Present app name, purpose, primitives, views, actions, storage, sources,
     and permission mode.
   - Offer two or three alternatives only when the product direction is
     genuinely ambiguous.

4. **Manifest generation**
   - Generate the structured app manifest.
   - Generate storage schema if needed.
   - Generate view specs.
   - Generate action specs.
   - Generate automation specs if requested.

5. **Validation**
   - Decode and validate manifest.
   - Validate capability references.
   - Validate storage schema and migrations.
   - Validate actions against governance rules.
   - Validate WebView widgets if present.
   - Show blockers and warnings.

6. **Preview**
   - Render native preview with sample data, cached data, or live read-only
     data depending on capability and risk.
   - Make validation errors visible inline.

7. **Publish**
   - Save app to workspace.
   - Create app storage.
   - Record app version.
   - Disable schedules until explicitly enabled.
   - Add app to workspace home and sidebar.

8. **Iterate**
   - User can say "add a chart", "make this a table", "add a REDCap submit
     button", "make writes approval-only", or "create a pipeline from this".
   - ASTRA patches the manifest through a validated diff.

### 7.3 App Ideation From Conversation

When the user asks for app ideas based on a conversation, ASTRA should produce a
small set of app proposals.

Each proposal should include:

- Name.
- Problem solved.
- Required sources.
- App-owned storage.
- Main views.
- Actions.
- Automation.
- Risk mode.
- Why this app speeds up the process.

The user chooses one proposal, then App Studio builds it.

### 7.4 Dependency Mapping

If the app references a missing source or connector, ASTRA should show a
dependency resolution panel.

Example:

```text
This app needs:

- BigQuery read access to clinical.enrollment_candidates
- REDCap metadata and record read access for Enrollment Study
- Optional REDCap write access for creating missing records

Map dependencies:

BigQuery source: Clinical Warehouse -> [Choose connector]
REDCap project: Enrollment Study -> [Choose connector/project]
Write mode: Draft only / Approval required / Disabled
```

### 7.5 Permission Mode Selection

For any app that may write externally or run side-effecting tools, App Studio
must ask the user to choose a write mode.

Modes:

- `readOnly`: app can read and display data.
- `draftOnly`: app can prepare changes but cannot submit them.
- `approvalRequired`: app can submit only after user approval.
- `preApproved`: app can run approved low-risk actions without per-action
  confirmation.

Destructive actions always require confirmation regardless of mode.

## 8. Canonical Product Objects

The implementation may refine names, but these boundaries should remain clear.

### 8.1 WorkspaceApp

Durable ASTRA-owned metadata for one installed app.

Responsibilities:

- Identity.
- Workspace relationship.
- Current manifest version.
- Published/draft status.
- Dependency status.
- Permission mode.
- Last opened/refreshed/run timestamps.
- Pointer to app storage.
- Pointer to app package/export identity.

### 8.2 WorkspaceAppManifest

The versioned declarative definition of the app.

Responsibilities:

- App name and description.
- Required capabilities.
- Storage schema.
- Source definitions.
- View definitions.
- Action definitions.
- Automation definitions.
- Permission declarations.
- Package metadata.

The manifest is generated and patched by App Studio, but always validated by
ASTRA before execution.

### 8.3 AppStorage

App-owned structured storage, usually backed by per-app SQLite.

Responsibilities:

- Dynamic user-defined tables.
- Draft records.
- Cached external reads.
- App settings.
- Local-only app data.
- Schema migration state.

### 8.4 AppSource

A declared readable data source.

Examples:

- App SQLite table.
- BigQuery query.
- REDCap project records.
- File.
- Task artifact.
- HTTP API through a capability contract.

### 8.5 AppView

A declared UI screen or component tree.

Examples:

- Dashboard.
- Form.
- Table.
- Detail page.
- Chart page.
- Pipeline run view.
- Review queue.
- Diagram.

### 8.6 AppAction

A declared operation triggered by a user, automation, or pipeline step.

Examples:

- Insert app record.
- Run BigQuery query.
- Validate REDCap draft.
- Submit REDCap record.
- Create ASTRA task.
- Export CSV.
- Send Slack message.

### 8.7 AppAutomation

A schedule, monitor, or pipeline definition.

Examples:

- Refresh every hour.
- Run every Monday at 9 AM.
- Alert when missing-record count exceeds 10.
- Run reconciliation, then create review task if there are exceptions.

### 8.8 AppRun

One execution of an app action, refresh, pipeline, or automation.

Responsibilities:

- Run status.
- Start/end timestamps.
- Trigger source.
- Step events.
- Linked task IDs.
- Outputs.
- Errors.
- Approvals.

AppRun should not replace AgentTask or TaskRun. If an app step creates agent
work, that step links to a normal `AgentTask` and `TaskRun`. The agent task
remains the source of truth for provider execution, transcript, tools,
artifacts, and validation. AppRun owns the app-level orchestration record.

### 8.9 AppPackage

Portable ASTRA-to-ASTRA app bundle.

Responsibilities:

- Export app manifest.
- Export storage schema.
- Export optional seed/sample data.
- Declare required capability types.
- Declare risk and permissions.
- Exclude credentials.
- Support import dependency mapping.

## 9. Manifest Shape

This is a conceptual JSON shape. The Swift implementation should use Codable
types and deterministic validators rather than ad hoc string parsing.

```json
{
  "schemaVersion": 1,
  "app": {
    "id": "enrollment-reconciliation",
    "name": "Enrollment Reconciliation",
    "icon": "checklist.checked",
    "description": "Compare latest BigQuery enrollment candidates against REDCap records.",
    "tags": ["redcap", "bigquery", "reconciliation"],
    "archetypes": ["dashboard", "reviewQueue"]
  },
  "requirements": [
    {
      "id": "sourceWarehouse",
      "contract": "tabularQuery.read",
      "minVersion": "1.0.0",
      "operations": ["describeTable", "runReadOnlyQuery"],
      "providerHint": "bigQuery",
      "dataClass": "sensitive"
    },
    {
      "id": "targetRecords",
      "contract": "recordProject.read",
      "minVersion": "1.0.0",
      "operations": ["describeProject", "readRecords", "validateRecord"],
      "providerHint": "redcap",
      "dataClass": "sensitive"
    }
  ],
  "storage": {
    "tables": [
      {
        "name": "review_items",
        "columns": [
          {"name": "id", "type": "uuid", "primaryKey": true},
          {"name": "source_record_id", "type": "text", "required": true},
          {"name": "match_status", "type": "text", "required": true},
          {"name": "created_at", "type": "datetime", "required": true}
        ]
      }
    ]
  },
  "sources": [
    {
      "id": "latest_candidates",
      "requirementRef": "sourceWarehouse",
      "operation": "runReadOnlyQuery",
      "mode": "read",
      "query": "SELECT * FROM clinical.enrollment_candidates ORDER BY updated_at DESC LIMIT 100"
    },
    {
      "id": "redcap_records",
      "requirementRef": "targetRecords",
      "operation": "readRecords",
      "mode": "read",
      "projectRef": "enrollment-study"
    }
  ],
  "views": [
    {
      "id": "dashboard",
      "type": "dashboard",
      "title": "Enrollment Reconciliation",
      "sections": [
        {
          "title": "Summary",
          "widgets": [
            {"type": "metric", "label": "Latest records", "binding": "metrics.latestCount"},
            {"type": "metric", "label": "Missing in REDCap", "binding": "metrics.missingCount"}
          ]
        },
        {
          "title": "Exceptions",
          "widgets": [
            {"type": "table", "source": "review_items"}
          ]
        }
      ]
    }
  ],
  "actions": [
    {
      "id": "refresh",
      "type": "pipeline",
      "label": "Refresh",
      "steps": ["query_latest_candidates", "read_redcap_records", "match_records", "store_review_items"]
    },
    {
      "id": "create_review_task",
      "type": "createTask",
      "label": "Create Review Task",
      "goalTemplate": "Review missing REDCap records from {{app.name}}."
    }
  ],
  "automations": [
    {
      "id": "daily_refresh",
      "type": "schedule",
      "enabledByDefault": false,
      "action": "refresh",
      "cron": "0 9 * * *"
    }
  ],
  "permissions": {
    "reads": ["bigquery", "redcap"],
    "writes": ["appStorage"],
    "externalWrites": [],
    "defaultMode": "readOnly"
  }
}
```

## 10. Storage Model

### 10.1 Why App Storage Is Required

Workspace Apps must support apps that do not depend on external systems. A user
must be able to build:

- Grocery tracker.
- Study log.
- Lightweight CRM.
- Inventory tracker.
- Review queue.
- Mapping table.
- Checklist app.
- Local audit registry.

These require app-owned tables. SwiftData is appropriate for ASTRA's typed
domain models, but arbitrary user-defined app tables need a more dynamic
storage engine.

### 10.2 Recommended Storage Architecture

Use:

- SwiftData for ASTRA-owned domain entities, such as `WorkspaceApp`,
  `AppRun`, dependency bindings, and package installation records.
- Per-app SQLite for app-owned dynamic tables, records, caches, drafts, and
  local app data.
- Keychain for credentials.
- Workspace hidden app folder for exportable app assets and generated artifacts.
- App Support for channel-local runtime caches that should not be shared.

Recommended layout:

```text
<workspace>/
  .astra/
    apps/
      <app-id>/
        manifest.json
        app.sqlite
        assets/
        exports/
        README.md
```

Sensitive caches should be excluded from package export unless the user chooses
full export.

### 10.3 SQLite Responsibilities

The app SQLite database stores:

- User-defined tables.
- Draft records.
- App settings that are not ASTRA domain settings.
- Cached connector results.
- Materialized query results.
- Local queues.
- Import/export state.

SQLite should not store:

- Connector credentials.
- Provider tokens.
- Raw secrets.
- ASTRA task transcripts as duplicated data.
- App package install approval state.

### 10.4 Schema Migrations

Each app manifest version may include a storage migration plan.

Migration requirements:

- Deterministic.
- Validated before applying.
- Backed up before destructive changes.
- Audit event emitted.
- Rollback path for failed migration.
- User approval required for destructive table/column drops.

### 10.5 Data Classification

Each table and source may declare data classification:

- `localOnly`
- `workspaceInternal`
- `sensitive`
- `regulated`
- `unknown`

The default for external clinical or research connectors should be at least
`sensitive` unless the capability declares otherwise.

## 11. Capability Contracts

Apps need deterministic operations. The app builder should generate against
capability contracts, not vague connector names.

The contract model must support many future ASTRA capabilities. BigQuery and
REDCap are examples, not special cases. As ASTRA grows, new capability packages
should become usable by Workspace Apps by declaring compatible operations,
without requiring App Studio to hardcode each provider.

The key rule is:

```text
Apps target stable contract families.
Capabilities provide implementations.
Workspace bindings connect app requirements to configured capability instances.
```

### 11.1 Core Terms

#### Capability Package

A capability package declares what a capability is, how it is configured, what
tools or connectors it exposes, and how it is governed. This builds on ASTRA's
existing `PluginPackage` direction for skills, connectors, local tools, MCP
servers, templates, prerequisites, setup text, source metadata, and governance.

Capability packages remain the unit of installation, approval, enablement, and
runtime readiness.

#### Contract Family

A contract family is a stable, provider-neutral interface that apps can depend
on.

Examples:

- `tabularQuery.read`
- `tabularQuery.write`
- `recordProject.read`
- `recordProject.write`
- `formSchema.read`
- `appStorage.records`
- `task.launch`
- `message.send`
- `issueTracker.mutate`
- `file.readWrite`
- `browser.controlledAutomation`

Contract families are intentionally broader than individual providers. BigQuery,
Snowflake, Postgres, DuckDB, and Google Sheets may all implement some form of
`tabularQuery.read`. REDCap, Airtable, a REST registry, and a lab-specific API
may all implement some form of `recordProject.read`.

#### Contract Operation

An operation is a single callable behavior inside a contract family.

Examples:

- `describeTable`
- `runReadOnlyQuery`
- `describeProject`
- `readRecords`
- `validateRecord`
- `submitRecord`
- `insertRecord`
- `createTask`
- `sendMessage`

Each operation has a versioned input schema, output schema, effect type, risk
metadata, timeout behavior, and audit metadata.

#### Contract Implementation

A contract implementation is how one installed capability satisfies one or more
contract operations.

Implementation types:

- `native`: Swift service implemented in ASTRA.
- `http`: declarative HTTP operation using a connector's configured base URL
  and credentials.
- `cli`: local tool command with JSON input/output.
- `mcp`: MCP tool call with JSON input/output.
- `taskBacked`: normal ASTRA task launch that uses a capability and returns
  task/artifact status.

The implementation type is an implementation detail. Apps depend on contract
families and operations, not on whether the call is native, HTTP, CLI, MCP, or
task-backed.

#### Workspace Binding

A workspace binding maps an app's logical requirement to a configured
capability instance in the current workspace.

Example:

```text
App requirement: sourceWarehouse implements tabularQuery.read
Workspace binding: sourceWarehouse -> Clinical Warehouse BigQuery connector
```

Bindings are created during app build, import, or dependency review. They are
stored locally and can be remapped without editing the app's logical design.

### 11.2 Contract Shape

A capability contract declares:

- Operations.
- Input schema.
- Output schema.
- Read/write behavior.
- Risk level.
- Required credentials.
- Dry-run support.
- Validation support.
- Audit fields.
- Pagination and streaming behavior where applicable.
- Redaction rules for sensitive input or output fields.
- Minimum ASTRA version and operation version.

Conceptual shape:

```text
ContractFamily
- id: tabularQuery.read
- version: 1.0.0
- displayName
- operations:
  - name
  - inputSchema
  - outputSchema
  - effect: read | localWrite | externalWrite | destructive
  - supportsDryRun
  - requiredApproval
  - timeout
  - pagination
  - redaction
```

An implementation then declares which operations it provides:

```text
ContractImplementation
- id: bigquery-standard-sql-read
- family: tabularQuery.read
- provider: bigQuery
- transport: native | http | cli | mcp | taskBacked
- operations:
  - describeTable
  - dryRunQuery
  - runReadOnlyQuery
- credentialBinding: connector.bigQuery
- governance:
  - dataAccess
  - externalEffects
  - riskLevel
```

### 11.3 App Requirements

App manifests should declare requirements in provider-neutral terms wherever
possible.

Example:

```json
{
  "requirements": [
    {
      "id": "sourceWarehouse",
      "contract": "tabularQuery.read",
      "operations": ["describeTable", "runReadOnlyQuery"],
      "dataClass": "sensitive",
      "providerHint": "bigQuery"
    },
    {
      "id": "targetRecords",
      "contract": "recordProject.read",
      "operations": ["describeProject", "readRecords", "validateRecord"],
      "dataClass": "sensitive",
      "providerHint": "redcap"
    }
  ]
}
```

`providerHint` is optional. It helps App Studio preserve user intent and improve
dependency mapping, but the app should remain portable to another provider that
implements the required contract operations.

When provider-specific behavior is truly required, the requirement should say
so explicitly:

```json
{
  "id": "redcapSubmitTarget",
  "contract": "recordProject.write",
  "providerRequired": "redcap",
  "operations": ["submitRecord"],
  "reason": "The app submits payloads to a REDCap project and relies on REDCap field metadata."
}
```

### 11.4 Capability Discovery

App Studio should receive a compact registry of approved, enabled, and
workspace-configured contract implementations.

For each implementation, the builder context should include:

- Contract family and version.
- Operation names.
- Human-readable capability name.
- Whether credentials are configured.
- Read/write effects.
- Data access classifications.
- Governance constraints.
- Provider hints.
- Setup status.

The model should generate app requirements against this registry. ASTRA still
validates the result deterministically before saving or running the app.

### 11.5 Implementation Tiers

ASTRA should support capabilities through multiple tiers so App Studio scales as
the capability catalog grows.

#### Tier 1: Native Swift Implementations

Best for high-value or high-risk operations that need strong validation,
latency, or UI integration.

Examples:

- App storage records.
- ASTRA task launch.
- BigQuery read operations.
- REDCap metadata and record operations.

#### Tier 2: Declarative HTTP Implementations

Good for simple REST APIs where the capability package can declare endpoint
templates, auth binding, request schema, response schema, and effect metadata.

The HTTP implementation must not allow arbitrary network calls. It can only
call declared endpoints through the configured connector.

#### Tier 3: CLI-backed Implementations

Good for systems that already have local command-line tools.

Requirements:

- Command declared in the capability package.
- JSON input/output when possible.
- No shell control syntax in command or default arguments.
- Timeout declared.
- Exit-code handling declared.
- Redaction rules declared.

#### Tier 4: MCP-backed Implementations

Good for tools exposed through MCP servers.

Requirements:

- MCP server declared by the capability package.
- Tool name declared.
- JSON input/output schema declared.
- Governance metadata declared.
- Runtime readiness checked before app execution.

#### Tier 5: Task-backed Fallback

Used when no deterministic operation exists yet.

The app action creates a normal ASTRA task with a structured goal, enabled
capabilities, and expected outputs. The app displays task status and artifacts.

This fallback is portable and auditable, but it is not low-latency and should
not be presented as a deterministic button-click connector call.

### 11.6 Example Contract Families

#### `tabularQuery.read`

Initial operations:

- `listDatasets`
- `listTables`
- `describeTable`
- `previewRows`
- `dryRunQuery`
- `runReadOnlyQuery`
- `exportResults`

Possible providers:

- BigQuery.
- Postgres.
- Snowflake.
- DuckDB.
- SQLite.
- Google Sheets.
- CSV files through app storage import.

#### `recordProject.read`

Initial operations:

- `describeProject`
- `listForms`
- `listFields`
- `readRecords`
- `lookupRecord`
- `validateRecord`

Possible providers:

- REDCap.
- Airtable.
- REST record APIs.
- Salesforce-like systems.
- App-owned SQLite tables.

#### `recordProject.write`

Initial operations:

- `prepareCreate`
- `prepareUpdate`
- `validateWrite`
- `submitCreate`
- `submitUpdate`

This family always carries external write governance. Implementations can be
draft-only, approval-required, or pre-approved only for explicitly low-risk
uses.

#### `appStorage.records`

Operations:

- `createTable`
- `addColumn`
- `insertRecord`
- `updateRecord`
- `deleteRecord`
- `queryRecords`
- `exportTable`
- `importCSV`

Deletes require confirmation unless the app is clearly operating on local
draft-only data.

#### `task.launch`

Operations:

- `createDraftTask`
- `createAndRunTask`
- `continueTask`
- `openTask`
- `bindTaskOutput`
- `readTaskArtifactMetadata`

This contract should reuse existing `AgentTask`, `TaskRun`, and task event
services. App actions that create tasks should capture a task link in AppRun.

#### `message.send`

Operations:

- `prepareMessage`
- `sendMessage`

Possible providers:

- Slack.
- Email.
- Microsoft Teams.
- GitHub comments.

Message sending usually requires approval unless the app is explicitly
pre-approved for a narrow destination.

### 11.7 Provider-specific Profiles

Provider-specific profiles are still useful. They capture details that are not
portable across every implementation of a contract family.

Examples:

- BigQuery location and billing project.
- REDCap project metadata version.
- Jira project key.
- Slack channel ID.
- GitHub repository owner/name.

The app manifest should keep these under dependency bindings or source
configuration, not bake them into the contract family itself. During package
import, ASTRA can ask the user to remap provider-specific profile values.

### 11.8 Contract Versioning

Contracts are versioned independently from capability packages.

Compatibility rules:

- Patch versions are compatible by default.
- Minor versions may add optional fields or operations.
- Major versions may change required fields or semantics.
- Apps declare minimum contract family versions and operation names.
- Import blocks if no compatible implementation exists.
- App Studio can offer a migration if a newer contract is available.

### 11.9 Contract Registry

ASTRA should maintain a contract registry assembled from:

- Built-in native implementations.
- Installed and approved capability packages.
- Workspace-enabled capability instances.
- Local development packages in the development channel.

The registry should be queryable by:

- Contract family.
- Operation.
- Provider.
- Effect type.
- Data classification.
- Credential readiness.
- Workspace availability.

This registry is what App Studio uses to design apps and what the runtime uses
to resolve app requirements.

### 11.10 Portability Rule

Portable app packages should depend on contract requirements, not local
workspace IDs.

Good:

```text
requires sourceWarehouse implements tabularQuery.read.runReadOnlyQuery
```

Avoid:

```text
requires connector UUID 71B0... from Alvaro's development workspace
```

Packages may include provider hints and sample mappings, but import must always
support remapping to a different compatible capability implementation.

## 12. App Runtime Architecture

### 12.1 Trusted Host

ASTRA's Swift app is the trusted host.

Swift owns:

- Workspace selection.
- App metadata.
- App storage.
- Capabilities.
- Credentials.
- Action execution.
- Approvals.
- Scheduling.
- Task creation.
- Audit.
- Package import/export.

### 12.2 Core Services

Recommended services:

#### WorkspaceAppService

Creates, updates, deletes, duplicates, and opens Workspace Apps.

#### AppManifestValidator

Decodes and validates manifests. It returns structured blockers and warnings.

Validation includes:

- Schema version compatibility.
- Unique IDs.
- Storage schema validity.
- View references.
- Action references.
- Source references.
- Capability requirements.
- Permission declarations.
- WebView widget restrictions.
- Automation safety.

#### AppStorageService

Manages per-app SQLite:

- Create database.
- Apply migrations.
- Query tables.
- Validate app-owned records.
- Backup before destructive changes.
- Export/import app data.

#### AppSourceResolver

Reads from app sources:

- App SQLite.
- BigQuery.
- REDCap.
- Files.
- Task artifacts.
- Capability contracts.

#### AppActionExecutor

Runs declared actions:

- Local app storage mutations.
- Deterministic capability operations.
- ASTRA task creation.
- Export operations.
- Notification operations.
- Pipeline starts.

All side-effecting actions go through approval policy.

#### AppAutomationScheduler

Runs scheduled refreshes and monitors. Schedules are disabled on import by
default.

#### AppRunRecorder

Creates and updates AppRun and AppRunEvent records.

#### AppStudioEngine

Builds and patches app manifests from natural-language requests. It uses model
reasoning, but final manifests pass through deterministic validation.

#### AppPackageService

Exports and imports `.astra-app` packages.

#### AppWebViewBridge

Hosts sandboxed WebView widgets and mediates message passing between WebView
presentation code and Swift-owned state/actions.

### 12.3 Execution Rule

Routine app execution should prefer deterministic paths:

```text
Button click -> AppActionExecutor -> CapabilityContract/AppStorage/TaskService
```

Agent-mediated execution should be explicit:

```text
Button click -> AppActionExecutor -> create AgentTask -> normal task runtime
```

The UI should show the difference. A deterministic action can show immediate
loading and result state. A task-backed action should show task status and link
to the created task.

## 13. Rendering Architecture

### 13.1 Native SwiftUI Renderer

The default renderer should be SwiftUI.

Native widgets:

- Metric card.
- Table.
- Record grid.
- Form.
- Detail panel.
- Chart wrapper.
- Markdown block.
- Action button.
- Status indicator.
- Run history.
- Approval card.
- Review queue.
- Kanban board.
- Timeline.
- Calendar.
- File/artifact preview link.

Native rendering gives ASTRA:

- Accessibility.
- macOS feel.
- Keyboard support.
- Deterministic tests.
- Permission consistency.
- Easier integration with task/runtime state.

### 13.2 WKWebView Renderer

Use WKWebView selectively for:

- Complex charts.
- Diagrams.
- Generated HTML dashboards.
- Custom visual layouts.
- Future advanced user-authored widgets.

The WebView is a presentation layer. It does not get direct credentials,
filesystem access, shell access, or arbitrary network access.

### 13.3 JavaScript Sandbox

Advanced custom widgets may eventually use JavaScript, but only inside a
restricted sandbox.

Sandbox rules:

- No direct network by default.
- No direct filesystem.
- No credentials.
- No shell commands.
- No arbitrary native bridge.
- Content Security Policy enforced.
- Data passed in through explicit payloads.
- Actions requested through a narrow message bridge.
- Swift validates every requested action.
- WebView can be disabled for high-risk environments.

Message bridge example:

```text
WebView -> Swift:
  requestAction(actionID, input)

Swift:
  validate action exists
  validate input schema
  enforce permission mode
  request approval if needed
  execute through AppActionExecutor
  return result payload
```

### 13.4 Why Not Pure JavaScript

A pure JavaScript/HTML app runtime would make rich interfaces easier early, but
it conflicts with ASTRA's strengths:

- Credential boundary.
- Local file and workspace governance.
- SwiftData task/runtime state.
- App Intents.
- Native approvals.
- Deterministic capability execution.
- Local security and audit.

The correct architecture is hybrid:

```text
Swift host + SQLite storage + native widgets + optional sandboxed WebView
```

## 14. Views And Widgets

### 14.1 View Types

Initial target view types:

- `dashboard`
- `form`
- `table`
- `recordDetail`
- `reviewQueue`
- `pipelineRun`
- `report`
- `diagram`
- `calendar`
- `kanban`
- `settings`

### 14.2 Widget Types

Core widgets:

- Metric.
- Chart.
- Table.
- Form field.
- Button.
- Markdown.
- Status.
- Divider/section label.
- Detail field.
- File/artifact link.
- Approval card.
- Run history.

Advanced widgets:

- Diagram.
- Timeline.
- Calendar.
- Kanban board.
- Rich HTML panel.
- Custom WebView widget.

### 14.3 Layout

Use a constrained layout model:

- Sections stack vertically.
- Sections can use one to four columns.
- Widgets declare column span.
- Detail area collapses to one column under narrow width.
- Dense operational surfaces should follow ASTRA's lean UI rules:
  - one card boundary
  - no card inside card
  - scan-first rows
  - progressive disclosure
  - one primary action per row

### 14.4 Charts, Metrics, And Diagrams

Metrics and charts should be actionable:

- Clicking a metric can filter the underlying table.
- Clicking a chart segment can open matching records.
- Diagrams can link to app records, tasks, or artifacts.
- Empty states should offer the next useful action.

Charts should support:

- line
- bar
- stacked bar
- scatter
- pie/donut only when categories are small
- histogram
- sparkline

Diagrams should support:

- Mermaid-style generated diagrams for process views.
- Entity relationship diagrams for app storage.
- Pipeline diagrams.
- Simple flow diagrams.

Native rendering is preferred where practical. WebView can be used for rich
diagram rendering if needed.

## 15. Actions And Permissions

### 15.1 Action Types

Required action types:

- `appStorage.insert`
- `appStorage.update`
- `appStorage.delete`
- `appStorage.query`
- `capability.read`
- `capability.write`
- `task.createDraft`
- `task.createAndRun`
- `task.open`
- `artifact.open`
- `artifact.export`
- `pipeline.run`
- `notification.show`
- `url.open`
- `clipboard.copy`

Future action types:

- `slack.sendMessage`
- `github.createIssue`
- `redcap.submitRecord`
- `bigquery.export`
- `browser.openControlled`

These may be specific capability operations rather than generic action strings.

### 15.2 Permission Modes

Every app declares its default permission mode.

| Mode | Behavior |
| --- | --- |
| `readOnly` | Reads data and renders views. No external writes. |
| `draftOnly` | Prepares drafts locally but cannot submit external writes. |
| `approvalRequired` | External writes require explicit user approval. |
| `preApproved` | Only declared low-risk operations run without repeated approval. |

### 15.3 Confirmation Rules

Always confirm:

- Destructive deletes.
- External writes in sensitive systems.
- Credential changes.
- Schedule enablement after import.
- Package install with write permissions.
- App storage destructive migration.

Usually confirm:

- Bulk updates.
- Sending messages.
- Creating issues/tickets.
- Running local tools with side effects.

Do not require repeated confirmation for:

- Read-only queries.
- Local draft saves.
- Opening files.
- Exporting local non-sensitive app data.

### 15.4 Audit

Every side-effecting action records:

- App ID.
- App version.
- Workspace ID.
- User action or automation trigger.
- Action ID.
- Inputs with redaction.
- Dependency/capability used.
- Approval decision.
- Output summary.
- Linked task or artifact.
- Timestamp.

## 16. Automation And Pipelines

### 16.1 Automation Types

Automation can be:

- Manual run.
- Scheduled run.
- Threshold monitor.
- Pipeline.
- Task-backed process.

### 16.2 Pipeline Steps

Pipeline steps may include:

- Source read.
- App storage query.
- Transform.
- Validation.
- App storage write.
- Capability read/write.
- Task creation.
- Agent classification.
- Human approval.
- Notification.
- Export.

### 16.3 Gates

Gate types:

- Deterministic expression gate.
- Human approval gate.
- Agent recommendation gate.

Agent gates must declare:

- Prompt.
- Input bindings.
- Available decisions.
- Policy mode.
- Token budget.
- Whether human approval is required.

### 16.4 Loops

Loops require:

- Maximum iteration count.
- Timeout.
- Optional delay.
- Clear stop condition.
- Audit events per iteration.

### 16.5 Relationship To Tasks

Pipelines should not create a parallel agent runtime.

If a step needs agent work:

1. AppRun creates a normal `AgentTask`.
2. Task runs through existing `TaskLifecycleCoordinator` and runtime services.
3. AppRun records the linked task ID.
4. App renders task status and output summary.
5. Task remains inspectable in the normal task UI.

## 17. App Studio Builder Protocol

### 17.1 Builder Inputs

App Studio should provide the model with:

- User request.
- Relevant conversation excerpts.
- Workspace capabilities.
- Capability contracts.
- Existing app manifest if editing.
- App storage schema if editing.
- Task artifacts selected by the user.
- Query shelf state if starting from a query.
- Package metadata if editing imported app.
- Widget and view schema.
- Permission rules.

### 17.2 Structured Output

The model should return structured app spec blocks, for example:

```text
ASTRA_APP_MANIFEST
{ ... JSON ... }
END_ASTRA_APP_MANIFEST
```

or validated patch blocks:

```text
ASTRA_APP_PATCH
[
  {"op": "add", "path": "/views/0/sections/1", "value": {...}}
]
END_ASTRA_APP_PATCH
```

ASTRA must treat model output as untrusted until decoded and validated.

### 17.3 Validation Feedback Loop

If validation fails:

- Show concise user-facing issue.
- Feed structured validation errors back into App Studio.
- Ask the model to repair the manifest.
- Preserve the last valid version.

### 17.4 Versioning And Undo

Every published app has versions.

Minimum behavior:

- Draft version while editing.
- Published version.
- Last known good version.
- Revert to previous published version.

Future behavior:

- Full version history.
- Diff viewer.
- Package update merge.

### 17.5 Builder Safety Prompts

The builder must stop for user confirmation when:

- It needs external write permission.
- It will store sensitive data locally.
- It will create a schedule.
- It will run a local tool.
- It cannot determine a safe matching key.
- It will use agent judgment for decisions affecting external systems.

## 18. Sharing And Packages

### 18.1 Sharing Goal

Workspace Apps should be shareable between ASTRA workspaces and ASTRA
installations.

The initial sharing model is ASTRA-to-ASTRA only:

```text
.astra-app
```

No standalone web export is required. A Workspace App is portable because
another ASTRA installation can import the package, review it, map its
dependencies, create local storage, and run it through ASTRA's trusted runtime.

The package should be portable across:

- Development and production ASTRA channels, subject to version compatibility.
- Different local workspaces on the same Mac.
- Different ASTRA installations on different Macs.
- Different capability instances that implement the same contract requirements.

It should not depend on:

- Local SwiftData object IDs.
- Absolute local paths.
- Keychain item IDs from the source machine.
- Workspace-specific connector UUIDs.
- App Support runtime cache.
- Provider sessions from the source machine.

### 18.2 Package Portability Model

Portability has four layers.

#### App Definition Portability

The app manifest, views, storage schema, actions, automations, and permission
declarations travel with the package.

#### Dependency Portability

The package declares logical dependency requirements using contract families
and operations. It may include provider hints, but import must support mapping
to any compatible capability implementation.

Example:

```text
sourceWarehouse:
  requires tabularQuery.read
  operations: describeTable, runReadOnlyQuery
  provider hint: bigQuery

targetRecords:
  requires recordProject.read
  operations: describeProject, readRecords, validateRecord
  provider hint: redcap
```

During import, ASTRA maps these logical dependencies to configured workspace
capabilities.

#### Data Portability

The package can include no data, sample data, seed data, or full app-owned data
depending on the export mode. External connector data is not included by
default.

#### Runtime Portability

The package does not ship privileged runtime code. It runs through the importing
ASTRA installation's native services, approved capability packages, local
storage service, task runtime, and optional sandboxed WebView renderer.

### 18.3 Package Shape

The exact archive format can be decided later, but the logical package should
look like this:

```text
example.astra-app/
  package.json
  manifest.json
  storage/
    schema.json
    migrations/
      001-initial.json
    data/
      sample/
      seed/
      full/
  assets/
    images/
    web/
  docs/
    README.md
  checksums.json
```

The package may be stored as a zip archive, directory bundle, or another
container format. The internal logical structure should remain stable so it can
be validated and inspected without launching arbitrary code.

### 18.4 Package Contents

An `.astra-app` package contains:

- Package manifest.
- Workspace app manifest.
- View specs.
- Storage schema.
- Storage migrations.
- Contract requirements.
- Optional provider hints and sample dependency mappings.
- Actions.
- Automations.
- Risk declaration.
- Permission declaration.
- Version metadata.
- Author/provenance metadata.
- Optional sample data.
- Optional seed data.
- Optional assets.
- Optional README.
- Checksums for package files.

### 18.5 Package Exclusions

Packages must not include by default:

- API keys.
- OAuth tokens.
- REDCap tokens.
- BigQuery credentials.
- Keychain values.
- Private absolute local paths.
- Sensitive cached connector results.
- Task transcripts containing sensitive content.
- App Support runtime cache.
- Provider session state.
- Browser cookies or authenticated browser state.
- Source workspace IDs as required bindings.
- Source machine user names in required paths.

### 18.6 Export Modes

#### Template Only

Default mode. Shares app structure, views, actions, automations, and storage
schema. No user data.

#### Template Plus Sample Data

Shares safe sample records for demos and onboarding.

Sample data must be explicitly marked sample and should be generated or
de-identified. Importing sample data should never imply that the app has been
connected to real source systems.

#### Template Plus Seed Data

Shares initial app-owned records that are part of the app's intended setup.

Examples:

- Default categories for a grocery app.
- Status values for a review queue.
- Standard report sections.
- Empty mapping rows that the importing user fills in.

Seed data should be safe to import into a real workspace.

#### Full App Export

Includes app-owned local records. Requires explicit warning and should still
exclude external credentials. This mode may contain sensitive data and must be
treated accordingly.

Full export should materialize app-owned records into portable data files such
as JSONL or CSV plus schema metadata. It should not require the receiving ASTRA
installation to trust a raw SQLite file from another machine. A raw SQLite copy
can be an optimization later, but the canonical portable representation should
be typed records plus schema.

### 18.7 Data Export Rules

For each app table, export policy can be:

- `exclude`
- `sample`
- `seed`
- `full`

For each external source cache, export policy can be:

- `exclude`
- `sampleOnly`
- `includeWithWarning`

Default policy:

- App-owned schema: include.
- App-owned records: exclude unless the user chooses seed or full export.
- External connector caches: exclude.
- Sensitive or regulated data: exclude unless full export is explicitly
  selected and confirmed.
- Generated artifacts: include only if selected and classified safe.

### 18.8 Import Flow

Import steps:

1. Select `.astra-app`.
2. Decode package.
3. Validate package.
4. Show package identity, author, version, required ASTRA version, and
   permissions.
5. Show required dependencies.
6. Map dependencies to current workspace capabilities.
7. Review storage schema.
8. Review automations, disabled by default.
9. Choose permission mode.
10. Install as forked local app.
11. Create app storage.
12. Open app in dependency review or App Studio.

### 18.9 Dependency Mapping

Imported packages reference capability requirements, not credentials.

Example:

```text
Package requires:
- sourceWarehouse implements tabularQuery.read
  operations: describeTable, runReadOnlyQuery
  provider hint: BigQuery

- targetRecords implements recordProject.read
  operations: describeProject, readRecords, validateRecord
  provider hint: REDCap

- targetWrite implements recordProject.write
  operations: validateWrite, submitCreate
  optional: true
  default mode: disabled

Current workspace mapping:
- sourceWarehouse -> Clinical Warehouse Dev BigQuery
- targetRecords -> Enrollment REDCap Test
- targetWrite -> Disabled
```

Mapping should support:

- exact provider match
- compatible provider match
- disabled optional dependency
- task-backed fallback
- missing required dependency blocker

### 18.10 Portable Identifiers

Packages should use stable logical IDs:

- app ID
- view ID
- source ID
- action ID
- automation ID
- storage table name
- dependency requirement ID

Packages should not require:

- SwiftData persistent identifiers from the source workspace.
- Local connector UUIDs.
- Local task IDs.
- Absolute file paths.
- Channel-specific App Support paths.

If an exported app references a task, artifact, or file, the package should
represent it as optional provenance or selected portable content, not as a hard
runtime dependency.

### 18.11 Package Versioning

Each package declares:

- Package ID.
- App ID.
- Semantic version.
- Minimum ASTRA version.
- Required capability contract versions.
- Author.
- Created timestamp.
- Source app version.

Imported apps are forked by default. Updates can be applied later, but local
changes are never overwritten silently.

### 18.12 App Forking And Updates

Import creates a local fork by default:

```text
source package -> imported app fork -> local edits
```

The imported app records:

- Source package ID.
- Source package version.
- Source digest.
- Import timestamp.
- Local app ID.
- Local app version.
- Dependency mappings.

If a newer package version is imported later, ASTRA can offer:

- create a second app
- update this app
- compare versions
- apply manifest changes only
- apply storage migrations only
- keep local dependency mappings
- skip changes that conflict with local edits

Updates must never silently overwrite local app data, credentials, dependency
mappings, permission modes, or schedules.

### 18.13 Package Validation

Package validation should be deterministic and testable without running the
app.

Validation checks:

- Package JSON decodes.
- Required files are present.
- Checksums match.
- Manifest schema version is supported.
- Storage schema is valid.
- Migrations are ordered and valid.
- View/action/source references resolve.
- Contract requirements are valid.
- Required ASTRA version is compatible.
- Required contract versions are compatible.
- No credentials are present.
- No forbidden absolute paths are present.
- WebView assets follow sandbox rules.
- Schedules default disabled on import.
- Permission declarations match declared effects.
- Full export data is clearly flagged.

### 18.14 Package Install States

Imported packages should move through explicit states:

- `decoded`
- `validated`
- `needsDependencyMapping`
- `needsPermissionReview`
- `readyToInstall`
- `installedDisabled`
- `installedReady`
- `blocked`

An app with missing required dependencies can still be installed for inspection
or editing, but it cannot run affected actions until the dependencies are
resolved.

### 18.15 Signed Packages

Package signing is a future enhancement.

The initial local import flow should still compute a package digest and record
it in the install record. Any package edit after review should require review
again.

Future signed packages should include:

- signer identity
- signing timestamp
- package digest
- trust source
- revocation status if available
- signature validation result

## 19. Security And Governance

### 19.1 Trust Boundary

Trusted:

- ASTRA Swift runtime.
- Manifest validators.
- App storage service.
- Capability contracts.
- Action executor.
- App package validator.

Untrusted:

- Model-generated manifests before validation.
- Imported packages before validation.
- WebView content.
- User-provided sample data.
- External connector responses.

### 19.2 Credential Handling

Credentials remain in existing secure stores such as Keychain and capability
configuration. Apps reference capability bindings. Apps do not store raw
credentials.

### 19.3 External Writes

External writes require:

- Declared capability operation.
- Input schema validation.
- Permission mode check.
- Approval if required.
- Audit event.
- Error capture.

### 19.4 Sensitive Data

Apps that read or store sensitive data must show:

- Data source.
- Local storage behavior.
- Export behavior.
- Sharing warning.
- Whether cached data is included in package export.

### 19.5 WebView Security

WebView widgets:

- Receive only the data they need.
- Use a restricted message bridge.
- Cannot call capabilities directly.
- Cannot access credentials.
- Cannot run shell commands.
- Cannot persist arbitrary files.
- Must declare required external assets.

## 20. Detailed Example Designs

### 20.1 BigQuery To REDCap Reconciliation App

Primitives:

- Sources:
  - BigQuery latest rows.
  - REDCap records.
- Storage:
  - `review_items`.
  - `match_runs`.
  - `field_mappings`.
- Views:
  - Dashboard.
  - Exceptions table.
  - Record detail.
  - Mapping settings.
  - Run history.
- Actions:
  - Refresh.
  - Export missing records.
  - Create review task.
  - Prepare REDCap drafts.
  - Submit approved REDCap writes.
- Automation:
  - Optional daily refresh.
  - Optional threshold notification.
- Governance:
  - Read-only by default.
  - REDCap writes disabled until explicitly enabled.

Core flow:

1. User opens app.
2. App shows last cached run with staleness.
3. User clicks Refresh.
4. BigQuery read operation fetches latest rows.
5. REDCap read operation fetches matching candidates.
6. Matching service compares records by declared keys.
7. Results are stored in app SQLite.
8. Dashboard updates.
9. User opens exceptions.
10. User exports CSV or creates a review task.
11. If write mode is enabled, user reviews draft REDCap payloads before submit.

### 20.2 REDCap Data Entry App

Primitives:

- Source:
  - REDCap metadata.
- Storage:
  - local drafts.
  - validation results.
  - submit attempts.
- Views:
  - instrument list.
  - data-entry form.
  - draft list.
  - validation panel.
  - submit review.
- Actions:
  - save draft.
  - validate.
  - submit.
  - export draft.
- Governance:
  - Draft-only or approval-required by default.

Core flow:

1. App loads REDCap metadata.
2. ASTRA renders native forms.
3. User enters data.
4. App validates local fields.
5. User saves draft.
6. User opens submit review.
7. App shows exact payload and destination project.
8. User approves submit.
9. REDCap write operation runs.
10. App records audit event and response.

### 20.3 Grocery Database App

Primitives:

- Storage:
  - `items`.
  - `stores`.
  - `purchases`.
  - `shopping_lists`.
- Views:
  - item table.
  - item form.
  - shopping list.
  - spend dashboard.
  - category charts.
- Actions:
  - add item.
  - mark purchased.
  - export CSV.
  - generate list.
  - create reminder task.
- Automation:
  - optional weekly reminder.
- Governance:
  - local storage only.

Core flow:

1. User asks for app.
2. App Studio proposes tables and views.
3. User publishes.
4. App creates SQLite database.
5. User adds groceries through native forms.
6. App shows metrics and charts from local data.
7. User exports CSV or creates a reminder task.

### 20.4 Conversation-Derived Pipeline App

Primitives:

- Sources:
  - prior task artifacts.
  - selected connector data.
- Storage:
  - run history.
  - intermediate outputs.
- Views:
  - pipeline overview.
  - run history.
  - approval queue.
  - output report.
- Actions:
  - run pipeline.
  - approve step.
  - create follow-up task.
  - export report.
- Automation:
  - optional schedule.
  - gates and retries.
- Agent reasoning:
  - classification.
  - summary.
  - recommendation.

Core flow:

1. User asks ASTRA to ideate from conversation.
2. App Studio proposes pipeline app candidates.
3. User chooses one.
4. App Studio generates manifest.
5. User reviews sources, actions, and permission mode.
6. App is published.
7. Pipeline runs manually first.
8. Schedule can be enabled after the user trusts it.

## 21. Relationship To Existing ASTRA Features

### 21.1 Tasks

Tasks remain the main record for agent work. Apps can create, open, continue,
and summarize tasks. Agent steps inside apps create normal tasks.

### 21.2 Task Events And Runs

App runs should link to task runs where applicable. They should not duplicate
provider logs or transcripts.

### 21.3 Query Shelf

The Query shelf remains an ad hoc SQL workbench. A query can become an app
source or seed an app through "Save as App".

### 21.4 Capability Packages

Workspace Apps should eventually become part of capability packages or a
parallel app package format. Shared apps can depend on capabilities without
shipping credentials.

### 21.5 App Intents And URL Routes

Apps should integrate with ASTRA's external route and App Intent system.

Expected additions:

- Open ASTRA App.
- Run ASTRA App Action.
- Create ASTRA App from prompt, possibly later.

Development channel routes should use the development URL scheme.

### 21.6 Schedules

App schedules should reuse ASTRA schedule infrastructure where practical, but
AppRun should record app-level execution state.

## 22. Design Guidance

Workspace Apps should follow ASTRA's lean operational UI language.

### 22.1 General UI Rules

- Build the usable app as the first screen.
- Avoid marketing-style hero pages.
- Avoid nested cards.
- Use one card boundary per concept.
- Keep dense tables readable.
- Use progressive disclosure for settings and advanced controls.
- Put actions close to the records they affect.
- Use icons for common actions.
- Make status scan-first.
- Avoid hiding critical errors in logs only.

### 22.2 App Cards

App cards should show:

- Icon.
- Name.
- One-line purpose.
- Status.
- Last opened/refreshed/run timestamp.
- Dependency warning if needed.

### 22.3 App Detail

App detail should show:

- Top bar.
- Primary working view.
- Inline loading and error states.
- Status and staleness.
- Action buttons.
- Audit/run history access.
- Settings only behind expansion or edit mode.

### 22.4 App Studio

App Studio should show:

- Builder chat.
- Live preview.
- Validation state.
- Sources.
- Storage.
- Actions.
- Automations.
- Permissions.

It should not hide generated behavior inside a black box.

## 23. Validation And Testing

Every bug fix and new feature in this system needs regression coverage. The
spec itself is documentation, but implementation work must include tests.

### 23.1 Unit Tests

Required test areas:

- Manifest decoding.
- Manifest validation.
- Manifest patch validation.
- Storage schema validation.
- SQLite migration planning.
- Permission mode enforcement.
- Capability dependency resolution.
- Action input validation.
- WebView bridge request validation.
- Package export redaction.
- Package import dependency mapping.
- AppRun event recording.

### 23.2 Integration Tests

Required flows:

- Create local storage app.
- Create app from BigQuery source.
- Create REDCap metadata-backed form app with mocked contract.
- Resolve app requirements through the contract registry.
- Resolve the same `tabularQuery.read` requirement through two compatible
  provider implementations.
- App action creates ASTRA task.
- App package export/import round trip.
- App package import remaps logical dependencies to different local capability
  instances.
- Full export excludes credentials and materializes app-owned data in portable
  typed records.
- Imported schedules default disabled.
- Missing dependency blocks run but allows review.
- Approval-required write pauses for approval.

### 23.3 UI Tests Or View Tests

Useful coverage:

- Workspace home app card presentation.
- Sidebar app rows.
- App detail placeholder and active state.
- App Studio validation errors.
- Dependency mapping UI.
- Permission review UI.
- App package import review.

### 23.4 Manual Checks

For feature branches:

```bash
swift test --filter WorkspaceApp
swift test --filter AppManifest
swift test --filter AppPackage
git diff --check
./script/build_and_run.sh --verify
```

Broaden to full `swift test` for schema, persistence, package, runtime,
capability, or scheduling changes.

## 24. Implementation Roadmap

This section is a de-risking sequence, not a limitation on the final product.

### 24.1 Foundation

- Add WorkspaceApp domain model.
- Add manifest Codable types.
- Add manifest validator.
- Add app home/sidebar/detail shell.
- Add URL route and App Intent for opening apps.
- Add regression tests for persistence and routing.

### 24.2 App-Owned Storage

- Add per-app SQLite database management.
- Add storage schema manifest.
- Add CRUD service.
- Add migration planner.
- Add simple table/form app rendering.
- Build local grocery-style app end to end.

### 24.3 Native Renderer

- Add native sections, metrics, tables, forms, buttons, markdown, charts, and
  run history.
- Add layout collapse behavior.
- Add view tests for lean presentation rules.

### 24.4 Capability Contracts

- Add contract family and operation types.
- Add contract registry assembled from native implementations and approved
  capability packages.
- Add dependency requirement resolution from app manifests to workspace
  bindings.
- Add package-declared implementation descriptors for HTTP, CLI, MCP, and
  task-backed operations.
- Add deterministic BigQuery read implementation for `tabularQuery.read`.
- Add REDCap metadata/read/validate/write implementations for
  `recordProject.read`, `recordProject.write`, and `formSchema.read`.
- Add task action contract.
- Add source resolver and action executor.
- Build BigQuery to REDCap reconciliation app with mocked services first.

### 24.5 App Studio

- Add app builder mode.
- Add structured manifest generation and patching.
- Add preview.
- Add validation feedback loop.
- Add app ideation from conversation.

### 24.6 Automation And Pipelines

- Add AppRun.
- Add app automation scheduler.
- Add pipeline action type.
- Add deterministic gates.
- Add human approval gates.
- Add task-backed agent steps.
- Add agent recommendation gates with budget and approval policy.

### 24.7 Sharing

- Add `.astra-app` package format.
- Add export/import.
- Add dependency mapping.
- Add logical dependency IDs and portable contract requirements.
- Add export modes: template, sample data, seed data, full app export.
- Add typed portable data export for app-owned records.
- Add package install states and validation blockers.
- Add package digest.
- Add sample data mode and full export warning.

### 24.8 Advanced Rendering

- Add sandboxed WKWebView widgets.
- Add chart/diagram rendering improvements.
- Add custom visual widgets through message bridge.

### 24.9 Team Library

- Add local team library or shared folder import path.
- Add package update checks.
- Add package signing and trust metadata if needed.

### 24.10 Agentic Workflows

An Agentic Workflow app lets a user describe a problem and get a reusable app
that orchestrates a workflow of governed ASTRA agents to solve it. It is a new
archetype recipe, not a new runtime. It composes the existing task, agent team,
gate, loop, run, and audit primitives. The execution rule in 16.5 is binding:
workflow steps that need agent work create normal `AgentTask`s through
`TaskLifecycleCoordinator`; the app never starts a parallel agent runtime.

- Add the Agentic Workflow archetype recipe and an App Studio entry for it.
- Reuse task-backed steps (`task.createDraft`, `task.createAndRun`), agent
  teams (`useAgentTeam`, `teamSize`), and `chainedGoal`; do not duplicate the
  agent runtime.
- Add await-and-resume for long-running agent steps so a workflow can suspend
  on a launched task and continue when it completes, across app sessions.
- Add typed step output-to-input bindings so a step can consume a prior step's
  structured result and write it into app storage, instead of sharing a single
  row buffer.
- Add agent recommendation gates with per-step and whole-run token budgets and
  approval policy.
- Add run visualization, an approval queue for blocked runs, and per-step audit
  drill-in.
- Later only: parallel fan-out (agent teams running concurrently), conditional
  branching beyond linear step lists, and an aggregation/reduce step for
  combining parallel agent outputs.

## 25. First-Principles Decisions

This section resolves the major architectural questions from the rest of the
spec. The common principles are:

- Durable app definition should live with the workspace so it is portable and
  recoverable.
- ASTRA should keep one clear owner for mutable state. If the same fact appears
  in two places, one is canonical and the other is a derived index or cache.
- Trusted state and side effects stay in Swift services, not WebView content or
  model output.
- Imported packages should be inspectable before they are runnable.
- Sensitive data should not become portable by accident.

### 25.1 App SQLite Location

Decision:

Store app-owned SQLite databases under the workspace's hidden app folder:

```text
<workspace>/
  .astra/
    apps/
      <app-id>/
        manifest.json
        data/
          app.sqlite
        assets/
        exports/
```

Channel separation comes from ASTRA's existing channel-separated workspace
roots:

- Development workspaces live under the development workspace root.
- Production workspaces live under the production workspace root.

Do not store the canonical app database under channel App Support. App Support
is appropriate for runtime indexes, transient caches, approval records, and
downloaded package cache, but the user-created app data belongs to the
workspace.

Rationale:

- App-owned records are workspace artifacts, not app-internal cache.
- Workspace-local storage makes app backup, export, and future source control
  easier.
- Development and production isolation already exists at the workspace root.
- Keeping the database near the manifest makes package export and inspection
  straightforward.

Exception:

Highly transient runtime caches may live under channel App Support if they are
rebuildable and excluded from app export.

### 25.2 Manifest Ownership

Decision:

Use both workspace files and SwiftData, but with one canonical owner:

- Canonical app definition: `<workspace>/.astra/apps/<app-id>/manifest.json`
- Canonical app-owned records: `<workspace>/.astra/apps/<app-id>/data/app.sqlite`
- SwiftData: indexed metadata, app lifecycle state, dependency bindings,
  current manifest digest, last opened/refreshed timestamps, AppRun summaries,
  package provenance, and UI selection state.

Edits must go through a `WorkspaceAppService` that writes the manifest file,
computes a digest, validates the manifest, and refreshes SwiftData indexes.
SwiftData should not become a second mutable owner of the app definition.

Rationale:

- A file manifest is portable, inspectable, packageable, and diffable.
- SwiftData is still valuable for fast UI queries and relationships.
- The digest makes drift visible if a manifest is edited outside ASTRA.
- This preserves ASTRA's principle of durable domain state without creating two
  conflicting owners.

### 25.3 REDCap Branching Logic

Decision:

Support a safe subset first and represent unsupported logic explicitly.

Minimum supported REDCap form behavior:

- Field type rendering.
- Required fields.
- Choice lists.
- Basic validation.
- Calculated display labels where deterministic.
- Branching rules using:
  - equality and inequality
  - empty/not-empty checks
  - numeric comparisons
  - checkbox contains selected value
  - boolean `and` / `or` / `not`
  - references to fields in the current record

Unsupported behavior should not be silently ignored. The form should show an
inline warning for affected fields or instruments and offer one of:

- open the record in REDCap
- keep the field read-only
- require manual review before submit
- disable submit until the unsupported rule is resolved

Rationale:

- A REDCap replacement that ignores branching logic can create invalid or
  misleading data.
- A narrow deterministic subset covers many practical forms.
- Explicit unsupported-rule handling is safer than trying to emulate all
  REDCap behavior immediately.

### 25.4 Chart And Diagram Rendering

Decision:

Use a hybrid renderer with native SwiftUI as the default:

- Native SwiftUI for common metrics, tables, forms, basic charts, run history,
  approvals, and app chrome.
- System or lightweight native chart rendering for common chart types where it
  is sufficient.
- WKWebView only for advanced diagrams, complex visualizations, generated HTML
  reports, or custom visual widgets.

Do not make WebView the default app runtime.

Rationale:

- Native controls keep accessibility, keyboard behavior, approvals, and
  testing closer to ASTRA's existing UI.
- Most operational apps need reliable tables/forms/actions more than exotic
  visualization.
- WebView is useful for rich visual surfaces, but it should stay a presentation
  layer behind the Swift-owned bridge.

### 25.5 Package Archive Format

Decision:

Use a zip-backed directory bundle with `.astra-app` extension.

Logical package shape:

```text
example.astra-app/
  package.json
  manifest.json
  storage/
    schema.json
    migrations/
    data/
      sample/
      seed/
      full/
  assets/
  docs/
  checksums.json
```

On disk and in the file picker this can be a single `.astra-app` archive. When
validated, ASTRA treats it as a structured directory.

Rationale:

- Single JSON is too limited for assets, migrations, sample data, and docs.
- Raw directory bundles are easy to inspect during development but less
  convenient to share.
- A zip-backed bundle gives both portability and inspectability.
- Checksums can be computed for every file without executing package content.

### 25.6 Imported WebView Widgets

Decision:

Do not allow imported packages to declare arbitrary custom WebView widgets in
the first sharing milestone.

Allowed initially:

- Native widgets.
- ASTRA-known WebView renderers.
- Static assets used by ASTRA-known renderers.
- Generated HTML artifacts opened as documents, not privileged widgets.

Later custom WebView widgets require:

- Sandbox policy.
- Content security policy.
- No direct credentials.
- No direct network by default.
- No direct filesystem.
- Narrow message bridge.
- Package validation.
- Optional package signing/trust source.

Rationale:

- Imported JavaScript is code, even if it is "just UI".
- It can create confusing data exfiltration and action-spoofing risks.
- The app system should prove manifest, storage, native rendering, and action
  governance before allowing portable custom code.

### 25.7 Package Signing

Decision:

Use digest-based local review first. Require stronger signing only for team
libraries, remote distribution, or packages that include custom WebView code.

Initial local import:

- Compute canonical package digest.
- Show source path, contents, permissions, dependencies, and warnings.
- Store local approval against package ID, version, and digest.
- Any package content change invalidates approval.

Team sharing or remote library:

- Require signer identity or trusted source metadata.
- Validate digest and signature.
- Show trust source in import UI.
- Keep local review even when the signature is valid.

Rationale:

- Signing should not block early local ASTRA-to-ASTRA sharing.
- Digest review already prevents silent package mutation after approval.
- Team or remote distribution changes the threat model and justifies stronger
  trust metadata.

### 25.8 Multi-user Model

Decision:

The first implementation remains single-user and workspace-local. Future
multi-user support should inherit workspace permissions before introducing
app-specific ACLs.

Future model:

- Workspace is the primary sharing boundary.
- App permissions inherit workspace permissions by default.
- App actions still declare read/write/effect permissions.
- Role restrictions can be added at action level before row-level ACLs.
- Row-level permissions are out of scope until ASTRA has a broader multi-user
  data model.

Rationale:

- App-level multi-user permissions cannot be correct in isolation.
- External systems already have their own access rules.
- ASTRA should not invent row-level security before the workspace sharing model
  exists.

### 25.9 Cached External Data Retention

Decision:

Every external source cache must declare a retention policy and data
classification. Defaults should minimize sensitive persistence.

Default retention:

- App-owned local records: retained until user deletes them or app storage is
  exported/deleted.
- External non-sensitive cache: 7 days.
- External sensitive cache: 24 hours.
- External regulated cache: disabled by default unless the user explicitly
  enables persistent cache.
- Derived aggregate metrics with no record-level identifiers: 30 days.
- Task artifacts: existing task/artifact retention policy.

The app should still show stale state clearly:

```text
Stale · last refreshed 2h ago
```

Rationale:

- Dashboards need cached results for continuity and offline inspection.
- Sensitive connector records should not become long-lived local data by
  accident.
- Aggregate metrics and app-owned records have different risk from raw external
  records.

### 25.10 Row-level Audit

Decision:

All apps get action-level audit. Row-level audit is enabled by default only for
sensitive apps, regulated apps, external write apps, approval-required apps, and
apps that opt in.

Always audit:

- App action execution.
- External reads at operation summary level.
- External writes.
- Approvals.
- Package import/export.
- Storage migrations.
- Schedule enable/disable.

Row-level audit records:

- table name
- row identifier
- changed fields
- old/new values with redaction as needed
- action ID
- actor/trigger
- timestamp

Rationale:

- Full row-level audit for a grocery app is unnecessary overhead.
- Full row-level audit for REDCap-facing or regulated workflows is essential.
- The audit model should scale with risk.

### 25.11 Built-in Versus Package-declared Contracts

Decision:

ASTRA owns the stable contract family schemas. Capability packages provide
implementations.

Built into ASTRA as stable contract families:

- `appStorage.records`
- `task.launch`
- `artifact.read`
- `file.readWrite`
- `tabularQuery.read`
- `recordProject.read`
- `recordProject.write`
- `formSchema.read`
- `message.send`
- `issueTracker.mutate`

Not every built-in family needs a native implementation on day one. The family
schema is the portable vocabulary. Native, HTTP, CLI, MCP, and task-backed
implementations can arrive over time.

Capability packages may declare implementation support for existing families.
Packages may also propose provider-specific extension families under a package
namespace, but those are less portable until ASTRA promotes them to stable
contract families.

Rationale:

- Portability requires a shared vocabulary.
- Letting every package invent unrelated contract families would fragment App
  Studio.
- Letting packages implement reviewed families lets ASTRA scale to many
  capabilities.

### 25.12 HTTP, CLI, And MCP Implementation Timing

Decision:

Do not ship general package-declared HTTP, CLI, and MCP contract execution in
the first App Studio milestone.

Recommended sequence:

1. Native implementations for app storage, task launch, and one or two core
   data families.
2. Task-backed fallback for capabilities without deterministic app operations.
3. Declarative HTTP implementations for read-only operations.
4. CLI-backed implementations with JSON schema, timeout, and redaction rules.
5. MCP-backed implementations with tool schema and runtime readiness checks.
6. External writes through HTTP/CLI/MCP only after the approval and audit model
   is proven.

Rationale:

- General package-declared execution is powerful and risky.
- Native and task-backed paths prove the app model without opening every
  extension surface at once.
- Read-only HTTP is the next safest expansion point.
- CLI and MCP need strong validation because they can bridge into broad local
  or external effects.

## 26. Success Criteria

The final product direction succeeds when:

1. A user can build a useful local database app from a natural-language prompt.
2. A user can build a connector-backed app from workspace capabilities without
   separate setup.
3. A user can build a REDCap data-entry or reconciliation app with visible
   governance.
4. A user can turn a repeated conversation/task process into a reusable app.
5. Apps can display metrics, charts, diagrams, tables, forms, and actionable
   controls.
6. Apps can create and run normal ASTRA tasks when agent work is needed.
7. Apps can be shared to another ASTRA workspace without sharing credentials.
8. Imported apps clearly declare dependencies and permissions before use.
9. New capability packages can make themselves app-usable by declaring
   compatible contract operations.
10. Swift remains the trusted runtime for state, actions, credentials, and audit.
11. WebView or JavaScript, if used, remains sandboxed presentation rather than
    privileged runtime.

## 27. Final Product Statement

ASTRA App Studio turns workspace knowledge, capabilities, and repeated
processes into durable apps.

The app is not just a dashboard and not just a task template. It can own local
storage, read external systems, render forms and charts, run governed actions,
coordinate pipelines, create tasks, and package the result for another ASTRA
workspace.

The architectural rule is:

```text
Swift owns state and actions.
SQLite owns app-defined records.
Capabilities own external access.
Tasks own agent work.
WebView renders advanced presentation.
Packages move apps between ASTRA workspaces without credentials.
```
