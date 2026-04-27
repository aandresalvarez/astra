# ASTRA — Agentic UI V1 Product Spec

**Status:** Draft for implementation  
**Audience:** New engineers joining the project  
**Authoring date:** 2026-04-23  
**Scope:** Core product model and UI behavior for an agentic macOS app built on the current `Workspace` / `AgentTask` architecture

---

## 1. Purpose

This document defines the intended product model and UI behavior for ASTRA's first real "agentic" experience.

It is written for implementation, not ideation. A new engineer should be able to read this document, map it to the current codebase, and ship the core surfaces without guessing the intended mental model.

This spec replaces the old implicit framing of the app as:

`folder -> task -> transcript`

with the new product framing:

`agent -> delegated work -> supervision`

The key point is:

- Users may enter task-first.
- The system should still be built on durable agents.
- The UI should progressively reveal the deeper model only when it becomes useful.

---

## 2. Product Definition

ASTRA is a supervision system for delegated work.

It is **not** primarily a chat interface.
It is **not** primarily a task list.
It is **not** primarily a workflow builder.

It is a product where users assign work to durable software operators, observe what they are doing, decide when to trust them, and intervene when needed.

The product should answer six questions quickly:

1. What agents do I have?
2. What is each agent responsible for?
3. What is each agent doing right now?
4. What does the agent need from me?
5. What did the agent change, learn, or decide?
6. Can I trust this agent right now?

---

## 3. Design Principles

### 3.1 Durable identity over ephemeral sessions

Tasks are episodic. Responsibility, memory, permissions, triggers, and trust accumulate over time.
Those concepts belong to an **agent**, not to a single thread.

### 3.2 Task-first entry, agent-first architecture

Many users will begin with "help me do this one thing."
The UI must support that.
The underlying system must still preserve durable agent state.

### 3.3 Inbox before logs

Humans should supervise meaningful work, not parse raw event streams.
The inbox is the escalation surface.
Logs and run details are secondary and should be reached only when needed.

### 3.4 Plans before transcripts

Whenever possible, show:

`intent -> next step -> result -> evidence`

Do not make raw transcripts the main product surface.

### 3.5 Trust must be visible

Trust may be computed from several signals, but it must be shown as a first-class state.
Users should not reconstruct trust manually from logs, permissions, and memory.

### 3.6 Progressive disclosure

The app should hide internal execution complexity unless the user is debugging or tuning behavior.

### 3.7 Multiple lenses

The system is agent-centric structurally, but users must be able to view work through:

- agent view
- task/outcome view
- time/activity view

### 3.8 Every surface must expose the next step

If a user cannot answer "what happens next?" within two seconds, the UI is failing.

---

## 4. Non-Goals

This spec does **not** require:

- renaming persistent storage types in V1
- building a full autonomous swarm system
- exposing every low-level runtime event in the default UI
- creating a complex policy editor before high-level autonomy modes exist
- forcing all users into an agent-centric navigation model on day one

---

## 5. Canonical Product Objects

These are the core product objects. The backend may store them differently in V1, but the UI and interaction model should honor these boundaries.

### 5.1 Agent

A durable operator with:

- identity
- mission
- memory
- tools and access
- policies
- triggers
- trust state
- current workload

### 5.2 Task

A bounded unit of work owned by one agent.

Tasks may be:

- user-created
- agent-created follow-ups
- trigger-created recurring tasks
- blocked or awaiting review

### 5.3 Run

A specific execution attempt for a task.

Runs matter for diagnostics, cost, and retries.
Runs should be mostly hidden in the default UI and revealed in debugging contexts.

### 5.4 Inbox Item

A human-attention object.

Examples:

- needs approval
- needs answer
- failure requiring guidance
- completed work for review
- suggestion from agent

### 5.5 Memory

Durable context an agent should reuse across tasks.

Memory types in the product model:

- fact
- preference
- decision
- operating playbook
- open question

### 5.6 Artifact

A visible output of work.

Examples:

- diff
- changed file
- note
- report
- PR
- generated document

### 5.7 Policy

Rules defining what an agent may do without asking.

### 5.8 Trigger

A wake-up condition for an agent.

Examples:

- user request
- schedule
- repo change
- failure event
- external connector event

---

## 6. Mapping to the Current Codebase

V1 should reuse the current data model where possible.

### 6.1 Type mapping

| Product concept | Current type | Notes |
|---|---|---|
| Agent | `Workspace` | Keep storage name in V1. Relabel as "Agent" in primary UI where appropriate. |
| Task | `AgentTask` | Already good enough for V1. |
| Run | `TaskRun` | Debug/diagnostic surface only by default. |
| Activity event | `TaskEvent` | Use categories to drive filtered activity UI. |
| Artifact | `Artifact` | Treat as the default visible output of a task. |
| Trigger | `TaskSchedule` | Broaden conceptually to "trigger" in UI language over time. |
| Agent memory | `Workspace.memories` | V1 can synthesize typed memory UI from strings; V2 should add a structured model. |
| Agent capabilities | `Workspace.skills`, `connectors`, `localTools` | These become the agent's tools and access surface. |

### 6.2 Existing files most affected by this spec

- `Astra/Models/Workspace.swift`
- `Astra/Models/AgentTask.swift`
- `Astra/Models/TaskRun.swift`
- `Astra/Models/TaskEvent.swift`
- `Astra/Models/Artifact.swift`
- `Astra/Models/TaskSchedule.swift`
- `Astra/Views/ContentView.swift`
- `Astra/Views/WorkspaceHomeView.swift`
- `Astra/Views/WorkspaceRightRailView.swift`
- `Astra/Views/TaskMainView.swift`
- `Astra/Views/TaskSidebarView.swift`
- `Astra/Views/ChatPanelView.swift`
- `Astra/Services/TaskQueue.swift`
- `Astra/Services/TaskScheduler.swift`
- `Astra/Services/ClaudeCodeWorker.swift`

### 6.3 Important implementation constraint

V1 should prefer **new computed view models and presentation logic** over risky schema churn.

Examples of acceptable V1 additions:

- `AgentSummaryViewModel`
- `TrustStateViewModel`
- `InboxItemViewModel`
- `AutonomyMode`
- `MemoryHealthState`

Do **not** block V1 on renaming `Workspace` to `Agent` in persistent storage.

---

## 7. User Modes

The product must support two modes of use.

### 7.1 Task-first mode

This is the default mode for new and casual users.

The user starts with:

`What do you want help with?`

The system should then:

- route the task to an existing agent, or
- create a lightweight new agent, or
- let the user run a one-off task while still attaching it to an agent behind the scenes

The user does **not** need to understand policies, triggers, or memory up front.

### 7.2 Operator mode

This is the advanced mode.

The user thinks in terms of:

- which agents exist
- what each agent is allowed to do
- what each agent is watching
- which items require supervision

The UI should progressively reveal this mode as usage deepens.

---

## 8. Global Information Architecture

The app should have five primary top-level surfaces:

1. `Home`
2. `Inbox`
3. `Agents`
4. `Artifacts`
5. `Settings`

The app must also support three viewing lenses for ongoing work:

1. `Agent lens`
2. `Task lens`
3. `Timeline lens`

These are not separate products. They are alternate views over the same underlying state.

### 8.1 Recommended macOS layout

Use the existing three-zone layout concept:

- left sidebar for navigation and object lists
- center canvas for the main selected surface
- right rail for trust, context, actions, and detail

This fits the current architecture and minimizes disruptive refactors.

---

## 9. Core Surfaces

### 9.1 Home

### Purpose

Provide the fastest task-first entry point.

### Required elements

- primary task composer
- recent agents
- recent tasks
- pending inbox count
- suggestions such as "create a reusable agent for this kind of work"

### Required behavior

- User can submit a task without first creating an agent manually.
- System chooses an agent or offers a lightweight agent selection.
- If similar work repeats, the UI suggests persisting or strengthening the agent.

### Success criterion

A first-time user can delegate one task within one minute without understanding the full system model.

### 9.2 Inbox

### Purpose

Provide a single supervision surface for meaningful human attention.

### Inbox item types

- approval request
- clarification request
- review result
- failure
- suggestion
- completed work awaiting filing

### Required item fields

- title
- short summary
- why the item matters
- source agent
- source task
- recommended next action
- urgency
- trust signal

### Required actions

- approve
- reject
- answer
- review diff
- retry
- ignore once
- promote to policy

### Required behavior

- Inbox is for escalations, not for all activity.
- Low-risk work may proceed silently.
- Similar low-risk items should be batchable.
- The inbox must support grouped review.

### Explicit anti-goal

Do not mirror the raw event log into the inbox.

### 9.3 Agents List

### Purpose

Show durable operators, not just folders.

### Agent card fields

- name
- mission
- current state
- trust state
- autonomy mode
- active task count
- waiting-on-you count
- latest useful output
- next step

### Required behavior

- Cards should work as a control tower.
- User should understand what each agent is for without opening it.
- User should be able to sort/filter by trust, activity, and waiting state.

### 9.4 Agent Home

### Purpose

Make one agent feel like a durable coworker with context, responsibilities, and active workload.

### Required top summary

- mission
- trust state
- autonomy mode
- current workload summary
- primary actions: new task, pause work, inspect inbox, edit access

### Required sections

1. `Inbox`
2. `Current Work`
3. `Memory`
4. `Tools and Access`
5. `Triggers`
6. `Activity`

### Current Work states

V1 should map existing task state to these user-facing categories:

| UI category | Current model |
|---|---|
| Draft | `status == .draft && isDone == false` |
| Queued | `status == .queued && isDone == false` |
| Running | `status == .running && isDone == false` |
| Needs Review | `status == .pendingUser && isDone == false` |
| Finished | `status in {completed, failed, cancelled, budgetExceeded} && isDone == false` |
| Done | `isDone == true` |

### Required behavior

- The agent page should center the agent, not any single task.
- The user should be able to see all active supervision needs without opening every task.
- The agent page should surface the next expected step for the agent as a whole.

### 9.5 Task Detail

### Purpose

Provide the working context for a single unit of delegated work.

### Required tabs

1. `Overview`
2. `Thread`
3. `Changes`
4. `Runs`

### Overview must show

- task objective
- current status
- next expected step
- trust signal
- cost so far
- key artifacts
- latest run result

### Thread must show

- user messages
- agent responses
- major lifecycle messages

Do not overload the default thread with every low-level event.

### Changes must show

- changed files
- generated artifacts
- diff-adjacent summaries
- stale artifact warnings where relevant

### Runs must show

- run list
- duration
- tokens
- cost
- stop reason
- failure diagnostics

This tab is primarily for debugging and advanced users.

### 9.6 Artifacts

### Purpose

Provide an output-first view across work.

### Required behavior

- Users should be able to browse outputs without remembering which run or task created them.
- Each artifact must link back to its source task and source agent.
- Artifacts should carry review state where applicable.

### 9.7 Activity

### Purpose

Provide a timeline lens across agents and tasks.

### Required behavior

- Activity should filter by agent, task, time range, and event category.
- This surface is broader than inbox and lower priority than inbox.
- Runs and system events may be more visible here than in other surfaces.

---

## 10. Trust Model

Trust must be a first-class visible state on both agents and tasks.

### 10.1 Trust state inputs

Trust should be derived from these dimensions:

- recent reliability
- novelty of context
- memory health
- scope of action
- approval history
- failure frequency
- budget/cost risk

### 10.2 Trust presentation

V1 should display:

- overall trust state
- short explanation string
- main causes

Recommended visual states:

- `High`
- `Moderate`
- `Low`
- `Needs Review`

### 10.3 Trust behavior

Trust does not block action by itself.
Trust changes:

- how loudly the system escalates
- how much review is required
- whether items may auto-resolve

---

## 11. Memory Model

Memory is a first-class product surface.

### 11.1 Memory categories

Even if V1 stores memory as strings, the UI should classify items into:

- facts
- preferences
- decisions
- playbook
- open questions

### 11.2 Required memory fields

- content
- category
- source
- last touched
- last validated by human
- confidence
- health state

### 11.3 Memory safety requirements

The system must guard against quiet memory corruption.

V1 should support:

- contradiction indication
- aging or staleness indication
- human validation state

### 11.4 V1 implementation note

If the current schema cannot support all fields durably, use:

- synthesized metadata in view models for now
- visible "unstructured memory" labeling where needed

Do not falsely imply stronger guarantees than the system has.

---

## 12. Policies and Autonomy

Policy must be understandable before it is configurable in detail.

### 12.1 Autonomy modes

V1 should introduce these high-level modes:

- `Conservative`
- `Balanced`
- `Autonomous`

### 12.2 Mode intent

`Conservative`

- ask before impactful actions
- ask before cost grows
- prefer explicit review

`Balanced`

- proceed on low-risk work
- escalate meaningful uncertainty
- batch low-risk notifications

`Autonomous`

- proceed broadly within allowed scope
- escalate only high-risk or ambiguous work

### 12.3 Detailed rules

Detailed policies may exist behind each mode, but should be secondary.

Examples:

- may edit files without asking
- may run tests
- may create branches
- may open PRs
- must ask before deleting files
- must ask before using costly external actions

### 12.4 Required policy surface

Users must always be able to answer:

- what can this agent do without asking?
- what will always require approval?

---

## 13. Failure Model

Failure handling is part of the product, not an implementation accident.

### 13.1 Required failure behaviors

Each meaningful failure should map to one of:

- `silent retry`
- `escalate`
- `rollback and notify`
- `ask for guidance`

### 13.2 Failure UX requirements

Users must be able to tell:

- what failed
- whether the system retried
- whether anything was rolled back
- whether the agent is blocked
- what decision the user needs to make

### 13.3 Default escalation guidance

Escalate when:

- the agent is blocked on permission or clarification
- the failure repeats
- trust is already low
- costs are rising unusually
- changes may be unsafe or irreversible

---

## 14. Cost and Budget

Cost is a first-class product concept in agentic systems.

### Required cost surfaces

- per task cost
- recent agent cost
- run-level cost in diagnostics
- budget risk warning

### Required behavior

- Running work should show "cost so far".
- Expensive tasks should become more interruptible, not less visible.
- Budget-related failure should be distinct from generic failure.

---

## 15. Interruptibility

Users must be able to intervene in running work.

### Required actions on running tasks

- pause or stop
- send guidance
- lower or raise urgency
- inspect latest output

### Required behavior

- Interruptibility should be available from both task detail and higher-level workload views.
- Stopping work should not erase context.
- Resume should preserve thread continuity where supported.

---

## 16. Multi-Agent Coordination

The product model must support more than one agent acting in one workspace of concern.

### V1 requirements

- One task belongs to one primary agent.
- Artifacts can be shared or referenced across agents.
- Activity should show cross-agent dependencies where visible.

### V1 non-requirement

Do not block launch on a full orchestration graph UI.

### Future direction

Support:

- agent-to-agent handoff
- delegated sub-agents
- shared artifacts
- dependency visualization

---

## 17. Recommended UI Copy Strategy

Use simple user-facing language.

Prefer:

- `Agent`
- `Task`
- `Needs Review`
- `Finished`
- `Needs Answer`
- `Can act on its own`

Avoid exposing implementation-heavy language by default:

- `Run`
- `Event`
- `Execution graph`
- `Thread state`
- `Ontology`

These may appear in debugging views only.

---

## 18. V1 Implementation Strategy

Implementation should happen in three phases.

### Phase 1 — Reframe existing workspace UI as an agent UI

### Goals

- preserve current storage model
- improve terminology
- make trust and next step visible
- split task states into clearer user-facing categories

### Required changes

- Present `Workspace` as an agent in primary surfaces.
- Add agent summary cards/list rows.
- Rework current workspace home around:
  - inbox summary
  - current work
  - memory
  - tools/access
  - triggers
  - activity summary
- Change task board language to:
  - Draft
  - Queued
  - Running
  - Needs Review
  - Finished
  - Done
- Add trust summary UI at agent and task level.
- Add next-step text everywhere work is listed.

### Phase 2 — Make supervision explicit

### Goals

- promote inbox as escalation surface
- simplify autonomy controls
- make failure and budget behavior visible

### Required changes

- Add a dedicated inbox view.
- Generate inbox items from task state and event patterns.
- Add autonomy mode selector.
- Add cost and budget indicators to task and agent summaries.
- Add clearer failure presentation and guidance states.

### Phase 3 — Deepen durability

### Goals

- improve memory safety
- strengthen triggers
- support stronger multi-agent workflows

### Required changes

- add richer structured memory
- improve contradiction and validation handling
- broaden triggers beyond schedules
- add cross-agent coordination affordances

---

## 19. Acceptance Criteria

The V1 implementation is successful when all of the following are true.

### Entry and onboarding

- A new user can submit a task without first understanding the agent model.
- The system still assigns that task to a durable agent identity.

### Agent visibility

- Every agent surface clearly states mission, current workload, trust, and next step.
- A user can tell what an agent is doing without opening every task.

### Inbox quality

- Inbox contains supervision-worthy items, not raw noise.
- A user can resolve the most common attention requests in one click or one short response.

### Task clarity

- Every task detail view clearly shows objective, status, next step, outputs, and cost.
- Run-level diagnostics are available without cluttering the default task surface.

### Trust and autonomy

- Users can see why an agent is considered safe or risky.
- Users can tell what the agent may do without asking.

### Failure handling

- Failure states explain what happened and what should happen next.
- Repeated or risky failure escalates clearly.

### Implementation sanity

- V1 ships without requiring a destructive persistence migration.
- Existing `Workspace`, `AgentTask`, `TaskRun`, `TaskEvent`, `Artifact`, and `TaskSchedule` remain usable.

---

## 20. Final Product Thesis

ASTRA should not be designed as chat with better chrome.

It should be designed as a supervision system for delegated work:

- task-first when users begin
- agent-centered underneath
- trust-visible
- output-first
- interruptible
- scalable under real operational load

That is the standard new implementation work should preserve.
