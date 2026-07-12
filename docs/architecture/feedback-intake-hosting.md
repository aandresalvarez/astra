# ADR: Feedback Intake Hosting and Storage Boundary

- **Status:** Proposed; production provisioning requires repository-owner approval
- **Date:** 2026-07-09
- **Decision owner:** ASTRA repository owner
- **Scope:** PRs 7 and 8 of the feedback-to-fix implementation plan

## Context and root cause

ASTRA has no deployed intake service today. The missing architectural owner is
not an HTTP framework: it is one durable boundary that atomically owns report
idempotency, receipt-scoped status-read authorization, private evidence
retention, and downstream projection jobs. Putting those responsibilities in
the macOS client or GitHub would disclose credentials or evidence, couple
acceptance to GitHub, and make retries create competing state.

The future backend implementation must define provider-neutral ports for:

- atomic installation/idempotency/digest and receipt persistence;
- encrypted private evidence storage and expiry;
- installation/network abuse decisions;
- durable projection-job enqueueing; and
- clock, status-read credential, and audit-event generation.

Deployment adapters must preserve those semantics. A provider choice must not
change the intake policy or the PR 1 wire contract.

## Options considered

### 1. Cloudflare Workers, D1, R2, Queues, and Workers secrets

This is the fewest-service edge deployment. D1 can own the idempotency unique
constraint and receipt mapping, R2 can hold expiring private objects, and Queues
can decouple GitHub projection. Cloudflare publishes both free and paid usage
tiers for Workers and D1, so billing limits still need an owner even if initial
traffic fits a free tier.

Tradeoffs: the production adapter would normally be TypeScript/JavaScript,
which constrains the backend language choice. Encryption, transaction, queue
retry, and audit guarantees must be proven against Cloudflare-specific behavior
rather than inferred from deterministic fakes.

Official reference: https://developers.cloudflare.com/workers/platform/pricing/

### 2. Google Cloud Run, Firestore, Cloud Storage, Cloud Tasks, and Secret Manager

This keeps the service container portable and permits a Swift or other
containerized adapter. Firestore transactions can own atomic idempotency and
receipt records; Cloud Storage lifecycle rules can expire evidence; Cloud Tasks
can decouple projection; Secret Manager and IAM can scope GitHub App and
encryption material. Google documents that Firestore charges for operations,
storage, and bandwidth and requires billing for features such as TTL deletes.
Cloud Run's own guidance recommends Secret Manager for service secrets.

Tradeoffs: it provisions more named resources than Cloudflare and needs careful
IAM, regional alignment, budget alerts, and lifecycle configuration. Firestore
is not a relational database, so the adapter must make the report insert,
idempotency claim, receipt index, and job intent one transaction.

Official references:

- https://cloud.google.com/firestore/pricing
- https://cloud.google.com/secret-manager/pricing
- https://docs.cloud.google.com/run/docs/configuring/services/secrets

### 3. AWS API Gateway/Lambda, DynamoDB, S3, SQS, KMS, and Secrets Manager

This provides mature primitives for conditional idempotency writes, encrypted
object storage, queues, IAM, and audit trails. AWS's Lambda architecture
guidance explicitly requires durable state to be committed to services such as
S3, DynamoDB, or SQS before an invocation exits.

Tradeoffs: it has the largest IAM and provisioning surface of the three options
for this small service. API Gateway, Lambda, DynamoDB, S3, SQS, KMS, Secrets
Manager, logging, and budget controls all require explicit ownership and can
incur usage charges.

Official reference:
https://docs.aws.amazon.com/lambda/latest/dg/concepts-application-design.html

### 4. One self-hosted VM with a database and filesystem

This has a small resource count but transfers encryption, patching, backups,
availability, abuse protection, retention jobs, and incident response to the
ASTRA owner. It is not the smallest maintainable option for sensitive evidence
and is rejected.

## Decision

Use a provider-neutral intake core and deterministic in-memory adapters in the
future backend repository for PR 7. Recommend **Google Cloud Run + Firestore +
Cloud Storage + Cloud Tasks + Secret Manager** for the first production
deployment because it keeps the executable container portable while providing
transactional metadata, private object storage, lifecycle deletion,
asynchronous work, IAM, and audit boundaries as managed services.

The deployed service should live in a dedicated private backend repository so
deployment code, infrastructure state, and GitHub App configuration are not
shipped with the macOS application. The PR 1 fixtures remain the cross-repository
compatibility authority. Until that repository and GCP environment are approved,
PR 7 implementation is blocked; this document is not a production endpoint.

The recommended repository name is `aandresalvarez/astra-feedback-service`, but
that name, owner, and private visibility are proposals only. This ADR does not
authorize repository creation. No backend executable, server framework, cloud
adapter, infrastructure manifest, or GitHub App code belongs in ASTRA's macOS
SwiftPM package. PRs 7 and 8 start in the selected backend repository after the
decisions below are recorded.

## Durable API and job boundary

PR 7 must own three independently authenticated surfaces:

1. The frozen `POST /v1/feedback/reports` intake endpoint, which validates the
   exact PR 1 media types, headers, canonical envelope, digests, evidence
   inventory, and consent. It stores any separately uploaded private evidence,
   atomically commits the installation/idempotency/digest claim, report, the
   status-read credential's one-way verifier and its encrypted recoverable
   representation plus expiry, and outbox intent, then returns the stable HTTP
   `202` receipt without waiting for GitHub or assessment. The encrypted
   recoverable credential is committed in this same transaction so a lost
   initial `202` can still be reconstructed on an idempotent retry; the
   verifier alone can prove the duplicate but cannot rebuild the receipt the
   frozen schema requires the retry to return.
2. The frozen `POST /v1/feedback/status` endpoint, which verifies the receipt
   ID, installation ID, and expiring status-read credential from the request
   body and returns only `FeedbackRemoteStatusDTOv1`. A report UUID alone is
   never authorization.
3. A staff API with separate reader, triage-writer, security-responder, and
   release-reconciler roles. Mutations use expected aggregate versions,
   idempotency keys, and append-only actor/reason audit events.

The staff boundary must support sanitized queue/detail reads and explicit
`needs_information`, `accepted`, `duplicate`, `declined`, and
`security_private` decisions. Implementation approval is a separate recorded
human gate; a triage decision never starts an agent directly.

PR 7 must also reserve signed, deduplicated internal webhook/event inputs for
GitHub state and release/appcast reconciliation. `merged` and `released` remain
distinct durable states. A later backend-owned PR 11 adapter can reconcile
verified merge and release events and publish receipt-scoped status-notification
readiness without creating another status owner.

Durable jobs use deterministic keys and typed payloads containing report IDs,
not report bodies or evidence. Required kinds are GitHub projection and
reconciliation, optional assessment, evidence expiration, GitHub/release status
reconciliation, and receipt-scoped reporter-status notification readiness. Job
intent is committed in the same metadata transaction as the state change that
requires it; workers use bounded leases, retries, and dead-letter state.

V1 collects no reporter name, email address, or other contact channel. Because
the frozen schema generally permits inert additive members, PR 7 must run the
threat model's narrow prohibited-contact member-name guard over the bounded raw
JSON tree before normal decode, canonical projection, logging, or persistence.
Other additive members remain allowed. Reporter follow-up is owned by the
receipt ID, installation ID, expiring status-read credential, and in-app status
endpoint. ASTRA may produce an optional local notification after it observes a
receipt-scoped status change; the backend sends no email or other
identity-addressed message.

## Assessment isolation boundary

An assessment worker is a separate sandbox identity, not a privileged intake or
GitHub worker with a restrictive prompt. It must have no network egress, tools,
shell, package managers, secrets, cloud metadata, deployment credentials, or
write access to source. It receives only sanitized serialized report data and a
read-only exact-release checkout, has bounded ephemeral scratch/CPU/memory/time,
and returns schema-constrained output to a trusted coordinator. The coordinator
validates the output and owns all durable writes.

## Required user-owned provisioning and secrets

No item below is created by PRs 7 or 8.

1. A user- or organization-owned Google Cloud account, billing account, project,
   region, budgets, alerts, and cost ceiling.
2. A private backend GitHub repository and CI identity. Prefer workload identity
   federation; do not create a long-lived service-account key.
3. Cloud Run service and runtime service account with least-privilege IAM.
4. Firestore database and indexes, including an atomic unique idempotency design.
5. Private Cloud Storage bucket, retention/lifecycle rules, public-access
   prevention, and an explicit encryption-key decision (provider-managed or
   customer-managed KMS).
6. Cloud Tasks queue, retry/dead-letter policy, and worker authentication.
7. Secret Manager entries for GitHub App credentials, status-read credential
   verifier/encryption material, and evidence-encryption material. Secret values
   must never enter this repository.
8. A GitHub App owned by the user or organization, installed only on the chosen
   engineering repository, with minimum Issues metadata/read/write permissions.
9. A private security-routing destination and named responders for possible
   credentials, security defects, or data-loss reports.
10. DNS/custom-domain and certificate ownership if a branded intake URL is
    required.

All managed options can incur charges. Production work is blocked until the
owner approves the provider, billing/cost ceiling, backend repository, region,
retention periods, encryption-key ownership, GitHub destination, and security
routing policy.

## Default policies proposed for explicit approval

- Standard evidence retention: 30 days after intake.
- Security-routed evidence retention: 14 days, extendable only by a recorded
  responder decision.
- Minimal report/receipt/status audit metadata: 365 days, containing no report
  body or raw evidence.
- Abuse identity: the contract's non-secret installation ID plus a
  privacy-preserving network bucket and the later approved authentication
  profile; no personal account requirement and no raw IP persisted in report
  records.
- Public issue bodies: sanitized summary and non-sensitive build/component facts
  only; never raw evidence, status-read credentials, object keys, expiring
  evidence links, or reporter contact data. V1 does not collect reporter contact
  data; this last exclusion is defense in depth for future contract versions.

These defaults are policy inputs, not silently activated production settings.

## Consequences and validation gates

- Intake success is independent of GitHub and assessment availability.
- PR 7 must pass the independent PR 1 golden-fixture verifier and backend-side
  JSON Schema/OpenAPI conformance tests without modifying the frozen artifacts.
- Contact-field rejection must occur on raw member names before a decoder can
  discard additive unknown members, and rejection must produce zero persistence,
  evidence, job, GitHub, assessment, or sensitive-log side effects.
- Metadata and evidence remain separate owners with separate retention.
- The datastore adapter must prove atomic idempotency under concurrency.
- The object-store adapter must prove private-by-default access, authenticated
  reads, hash/size/type checks, encrypted-at-rest semantics, and deletion.
- A durable job intent must be committed with the accepted report. An adapter
  may use an outbox table/collection and dispatcher rather than claiming a
  cross-service transaction.
- Provider integration, deployment, load tests, IAM tests, encryption controls,
  backup/recovery, and cost alarms remain blocked until provisioning is approved.
