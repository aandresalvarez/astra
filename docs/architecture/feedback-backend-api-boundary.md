# Feedback Backend API and Durable Job Boundary

**Status:** Design only. This is not PR 7 or PR 8 and deploys nothing.

This document defines the minimum provider-neutral boundary that the future
private feedback backend repository must implement. The backend consumes the
PR 1 machine-readable schema and golden bytes without copying or redefining its
contract types.

## Frozen contract authority

This design was audited against draft PR 1 `#257` at exact head
`0b0e55ce53c1b039b3e520c9e14de719aa26b662`. Downstream implementations consume
these read-only authorities:

- `docs/contracts/feedback/v1/feedback-contract.schema.json`
- `docs/contracts/feedback/v1/openapi.yaml`
- `docs/contracts/feedback/v1/README.md`
- `docs/contracts/feedback/v1/verify_fixtures.py`
- `docs/contracts/feedback/v1/fixtures/*`

The Swift projection under `ASTRACore/Feedback/` remains owned exclusively by
PR 1. A backend must run the independent fixture verifier and its own schema and
OpenAPI conformance tests against the exact checked-in bytes; it must not copy,
reformat, extend, or redeclare the contract as a competing authority.

## Repository ownership

Recommended, not authorized, repository: private
`aandresalvarez/astra-feedback-service`.

The future repository owns public intake, metadata and evidence persistence,
staff triage APIs, durable jobs, GitHub projection, assessment isolation,
release reconciliation, deployment adapters, infrastructure, and secrets.
ASTRA's macOS repository owns the client contract and application behavior; it
must not contain the backend executable, GitHub App credentials, or cloud
configuration.

## Durable behavioral owner

One report aggregate owns idempotency, status-read authorization, remote status,
evidence lifecycle, triage decisions, projection mapping, merge state, and
release state. Its metadata transaction atomically claims uniqueness on the
idempotency key alone, then compares the stored installation ID and canonical
digest against the incoming request inside that same transaction: a matching
installation and digest replays the original receipt, a changed digest is a
permanent `idempotency_key_reuse`, and a different installation is a permanent
`cross_installation_replay`. A claim keyed on the installation/key/digest tuple
cannot detect either case, because a changed digest or a different installation
simply forms a different tuple instead of colliding with the original row. On
first acceptance the transaction also stores both a keyed one-way verifier of
the status-read credential and an encrypted, recoverable representation of that
same credential plus its expiry — the one-way verifier alone cannot reconstruct
the secret the frozen receipt schema requires when a lost `202` response must be
replayed — advances state, and inserts every required outbox job intent.

Private evidence is stored separately under deterministic object keys. Evidence
upload completes before report acceptance. GitHub and assessment are
asynchronous projections and cannot roll back an accepted report.

The aggregate minimally records:

```text
report_id
installation_id
idempotency_key_hash
canonical_digest_sha256
payload_sha256
evidence_archive_sha256
receipt_id
status_read_credential_verifier + encrypted_status_read_credential + expires_at
contract_version
received_at
remote_status
aggregate_version
evidence_state + expires_at
projection_state + issue_mapping
assessment_state
triage_decision + actor + timestamp
implementation_approval + actor + timestamp
merged_commit + merged_at
released_version + released_at
```

V1 has no reporter name, email, or contact field. Report bodies, evidence bytes,
secrets, and status-read credentials are not job payloads. The raw-intake privacy
guard below rejects prohibited reporter-contact fields before normal contract
decode, canonical projection, logging, or persistence.

## Raw prohibited-contact privacy gate

The frozen schema deliberately permits inert additive unknown members. PR 7
must preserve that compatibility rule while applying one narrower defense: after
bounded JSON parsing with duplicate-member detection, but before normal V1
decode/canonical projection, it recursively inspects every raw object member
name and rejects the prohibited reporter-contact aliases defined in the threat
model. It must not globally reject additive members.

This guard runs before operational logging, database/object-store access, job
creation, GitHub projection, or assessment. A rejection returns a schema-valid
`FeedbackAPIErrorV1` with code `prohibited_reporter_contact`, `retryable: false`,
and a constant safe message that does not echo the member name or value.

## Reporter interfaces

### `POST /v1/feedback/reports`

- Authentication is deliberately unspecified until the owner selects an opaque
  authentication profile bound to the contract's non-secret installation ID,
  including enrollment and revocation. PR 7 adds that separately versioned
  profile without changing the V1 body.
- The request body is the exact canonical `FeedbackReportEnvelopeV1` bytes with
  `Content-Type: application/vnd.astra.feedback.v1+json` and
  `Accept: application/vnd.astra.feedback.receipt.v1+json`.
- Required headers are `Idempotency-Key`, `ASTRA-Installation-ID`,
  `ASTRA-Payload-SHA256`, `ASTRA-Request-Digest-SHA256`, and `Content-Length`.
  `ASTRA-Evidence-SHA256` is present exactly when evidence archive bytes exist.
  Header values must equal the corresponding envelope members.
- The raw prohibited-contact gate runs before the normal schema, canonical-byte,
  hash, size, evidence inventory, and consent validation.
- Evidence bytes are outside the JSON envelope in V1. PR 7 must select and test
  an upload sequence without changing envelope bytes, hash inputs, or retry
  identity. Acceptance occurs only after any declared evidence is privately
  stored, encrypted, and verified against its final archive/artifact hashes.
- The transaction commits the report, the status-read credential's verifier and
  its encrypted recoverable representation, and downstream job intents before
  returning the stable receipt.
- GitHub and assessment are not in the acceptance path.
- Reuse by the same installation of the same idempotency key and canonical
  digest returns the original receipt. A changed digest returns permanent
  `idempotency_key_reuse`; another installation returns permanent
  `cross_installation_replay`.
- Success is HTTP `202` with
  `application/vnd.astra.feedback.receipt.v1+json`. Contract failures use the
  frozen `FeedbackAPIErrorV1` media type and the OpenAPI `400`, `409`, or `413`
  framing.

### `POST /v1/feedback/status`

- The body is the exact `FeedbackStatusReadRequestV1` using
  `application/vnd.astra.feedback.status-read.v1+json`; the credential never
  appears in a URL, header log, issue, or analytics record.
- `installationID`, `receiptID`, and the high-entropy, expiring
  `statusReadCredential` are jointly verified. A report UUID never authorizes
  access. The server stores only a keyed verifier or encrypted representation,
  never plaintext logs.
- HTTP `200` returns the exact `FeedbackRemoteStatusDTOv1` as
  `application/vnd.astra.feedback.status.v1+json`; `400`, `401`, and `410` use
  the frozen typed error body.
- Report bodies, evidence references, staff notes, and other reporters' state
  are excluded. Reporter contact is absent by construction in V1.

## Staff triage interfaces

Staff identity is separate from reporter authentication. Required roles are
`triage_reader`, `triage_writer`, `security_responder`, and
`release_reconciler`.

- `GET /v1/staff/reports?state=&cursor=&limit=` returns sanitized queue rows.
- `GET /v1/staff/reports/{reportID}` returns sanitized details, evidence
  availability/expiry, assessment state, projection state, and audit history.
- `POST /v1/staff/reports/{reportID}/decisions` records exactly one
  `needs_information`, `accepted`, `duplicate`, `declined`, or
  `security_private` decision using the frozen
  `FeedbackStaffTriageDecisionV1`/`$defs/staffTriage` body. Its
  `draftTaskRequested`, optional `priorityOverride`, reviewer, reason,
  assessment revision, and timestamp fields are not redeclared by the backend.

Every mutation requires an expected aggregate version, request idempotency key,
role authorization, actor identity, reason, and append-only audit event. Staff
triage cannot directly start an agent, create a branch, merge, release, or read
private evidence without an access-purpose audit event.

Assessment workers return the exact frozen `FeedbackAssessmentV1`/
`$defs/assessment` shape. Schema-valid output remains a recommendation; it does
not grant staff, task, GitHub, or release authority.

## Reconciliation interfaces

- `POST /v1/internal/github/webhooks` verifies the GitHub signature over raw
  bytes before parsing, deduplicates by delivery ID, and schedules a typed job.
- `POST /v1/internal/releases` accepts a separately authenticated release event
  with repository, tag/version, immutable commit, artifact or appcast identity,
  and delivery idempotency key.
- `POST /v1/internal/reconciliation/runs` schedules a bounded reconciliation
  run and cannot accept arbitrary URLs or commands.

`merged` and `released` are distinct durable states. Only a verified release
whose immutable source contains the linked merged fix can transition a report
to `released`. A later backend-owned PR 11 work package implements provider
adapters and publishes receipt-scoped status-notification readiness on top of
this owner. ASTRA consumes that status and may show an optional local
notification; the backend has no reporter contact channel.

## Durable jobs

Every job has deterministic identity `<kind>:<reportID>:<generation>` and state:

```text
pending -> leased -> succeeded | retryable_failure | dead_letter
```

Leases expire; attempts are bounded; retry delay is deterministic with bounded
jitter; external effects use provider idempotency keys. Required job kinds are:

- `github_projection_requested`
- `github_projection_reconcile`
- `assessment_requested`
- `evidence_expiration`
- `github_state_reconcile`
- `release_state_reconcile`
- `reporter_status_notification_ready`

## PR 8 GitHub projection port

The privileged adapter exposes only typed operations:

```text
findOpenIssueByFingerprint(fingerprint)
createIssue(sanitizedTitle, sanitizedBody, labels, fingerprintMarker)
incrementOccurrence(issueID, expectedCount, sanitizedBuildRange)
readIssue(issueID)
ensureLabels(allowlistedLabels)
```

Report content cannot provide URLs, GraphQL, shell fragments, API methods, label
names, or repository identifiers. The deterministic fake must inject timeout
before creation, timeout after creation, permission denial, missing label,
stale occurrence count, and not-found outcomes.

The mapping store—not GitHub search text—owns `fingerprint -> active issue`.
After a create timeout, reconciliation searches for an exact inert fingerprint
marker and persists the mapping before another create. A unique
`(reportID, fingerprint)` occurrence record prevents double increments.

Fingerprint policy is versioned and length-prefixes normalized component,
failure kind, stable failure code/category, and selected non-sensitive invariant
evidence. It excludes report ID, free-form text, timestamps, reporter identity,
file paths, and raw evidence. V1 contains no reporter identity or contact field.

Security, credential, and data-loss signals route to private security state and
create no public issue. Public issue bodies contain only sanitized summary and
non-sensitive component/kind/build/occurrence facts. They never contain raw
evidence, evidence links or keys, status-read credentials, secrets, home paths,
or staff-only assessment content. Reporter contact data is also prohibited as
a defense-in-depth rule, although V1 never collects it.

## Decisions blocking implementation

Implementation remains blocked until the owner approves:

1. Backend organization, repository name, and private visibility.
2. Provider/runtime, datastore, object store, queue, secret manager, KMS, and
   infrastructure-as-code tool.
3. Region, data residency, backup, and disaster-recovery policy.
4. Reporter installation authentication, enrollment, revocation, and abuse
   policy.
5. Staff identity provider, role membership owner, and break-glass policy.
6. Standard, security, and minimal audit/status retention.
7. Billing account, monthly cost ceiling, deployment owner, and on-call owner.
8. GitHub App owner, installation scope, engineering repository visibility,
   private security destination, and minimum permissions.

Reporter communication is resolved, not a remaining implementation decision:
receipt-scoped in-app status is authoritative and ASTRA may provide an optional
local notification. V1 collects no email or contact channel.

No backend repository, cloud resource, GitHub App, paid service, or secret is
created or modified by this design.
