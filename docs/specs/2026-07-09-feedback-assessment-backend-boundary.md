# Feedback Assessment Backend Boundary

PR 9 deliberately implements only the repository-neutral semantic validator
and deterministic priority policy in ASTRACore. The ASTRA application is not a
safe owner for a production assessment worker: it has runtime adapters,
credentials, writable source checkouts, and task/GitHub mutation paths.

When the backend repository is selected after PRs 7 and 8, the production
integration should use these module boundaries (paths relative to that future
repository):

- `src/feedback/assessment/job_store`: owns pending, failed, retry, and
  completed assessment job state without blocking accepted intake.
- `src/feedback/assessment/input_serializer`: serializes the sanitized report,
  issue summary, and coordinator-issued assessment revision, exact
  source/current-main revision handles, and allowed evidence citation IDs.
  Analyzer-visible copies remain untrusted data; the original trusted context
  is retained outside the analyzer and supplied separately to output
  validation. It never emits shell fragments or interpolated commands.
- `src/feedback/assessment/read_only_sandbox`: launches the analyzer with no
  tools, network, secrets, source writes, issue writes, or deployment
  permissions. The exact release and current-main checkouts are immutable
  mounts.
- `src/feedback/assessment/output_validator`: validates model output against
  the PR 1 `FeedbackAssessmentV1` schema and the semantic rules in
  `FeedbackAssessmentValidator` before persistence. Report ID, assessment
  revision ID, source release, current-main revision, and every evidence or
  counterevidence citation must exactly match coordinator-issued context;
  drift is derived from that context rather than analyzer-authored values.
- `src/feedback/assessment/priority_projection`: ports the deterministic
  `FeedbackPriorityPolicy`; model wording never assigns priority.

The worker must publish only schema-valid assessment data. Missing, malformed,
or unavailable model output stays pending/failed and leaves issue creation,
report acceptance, and authenticated human triage operational.
