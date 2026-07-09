# Feedback Intake and Projection Threat Model

**Status:** Design requirement for blocked backend PRs 7 and 8. No service is
deployed by this repository.

## Assets

- Report intent, sanitized summary, and private evidence. V1 contains no
  reporter name, email address, or other contact field.
- Receipt IDs, expiring status-read credentials, and installation authentication
  state.
- Staff identities, roles, triage decisions, overrides, and audit history.
- Evidence-encryption material, status-read credential verifier/encryption
  material, and cloud credentials.
- GitHub App private key and installation token.
- Fingerprint-to-issue mappings, occurrence records, merge state, release state,
  and receipt-scoped status-notification readiness state.

## Trust boundaries

1. The public internet to intake: all headers, JSON, evidence, filenames, MIME
   declarations, hashes, identifiers, and text are hostile.
2. Intake to metadata and object storage: acceptance requires private encrypted
   evidence and an atomic metadata/idempotency/outbox transaction.
3. Receipt holder to reporter status: the body-bound installation ID, receipt
   ID, and expiring status-read credential form a scoped capability, not a staff
   identity and not evidence authorization.
4. Staff identity to triage: authentication, role authorization, optimistic
   concurrency, idempotency, and audit are required for every mutation.
5. Job coordinator to workers: typed job data is untrusted input; a lease is not
   authorization to invoke arbitrary providers or methods.
6. Backend to GitHub: only the GitHub App projection adapter receives minimum
   issue permissions. Intake, assessment, and reporter status do not.
7. Backend to assessment: the assessment worker is isolated from networks,
   tools, shells, secrets, deployment credentials, and source writes.
8. Signed webhooks to reconciliation: signatures are verified over raw bytes
   before parsing, delivery IDs are deduplicated, and event text is data.

## Required invariants

- Report acceptance never waits for GitHub or assessment.
- One installation ID, idempotency key, and canonical digest produce one report
  and one receipt.
- The same installation/key with a changed digest is a permanent
  `idempotency_key_reuse`; another installation reusing the key is a permanent
  `cross_installation_replay`.
- A report UUID alone grants no read access.
- Evidence is never public, never placed in issue bodies, and is deleted under a
  recorded retention policy while minimal audit/status metadata remains.
- Operational logs contain typed identifiers and result categories, not report
  bodies, evidence, status-read credentials, object keys, or secrets. Reporter
  contact data is absent by construction in V1 and remains prohibited as defense
  in depth.
- External report content cannot authorize triage, task execution, GitHub API
  methods, assessment tools, merge, release, or notification.
- One report/fingerprint occurrence is counted once despite retries.
- Possible security, credentials, or data loss produces zero public issues.
- `merged` never implies `released`; release requires independently verified
  immutable source and release/appcast evidence.

## Abuse and attack paths

### Resource exhaustion and storage abuse

Attackers can send oversized bodies, many evidence items, decompression bombs,
hash mismatches, slow uploads, high-cardinality installation identities, or
concurrent idempotency races. The service must impose limits before allocation,
stream bounded uploads, reject unsupported content types, rate-limit both opaque
authentication identities and privacy-preserving network buckets, and prove
atomic duplicate handling under concurrency.

### Authorization and cross-report access

Guessable status credentials, credential logging, UUID authorization,
timing-sensitive verifier comparison, broken staff role checks, or object-store
public access could expose private reports. Status-read credentials require high
entropy, an expiry, body-only transport bound to installation and receipt IDs,
keyed-verifier or encrypted storage, bounded status responses, and revocation
policy. Evidence reads require staff role and purpose audit. Buckets deny public
access and use narrowly scoped service identities.

### Raw prohibited-contact field gate

V1 intentionally allows inert additive unknown object members, so the service
must not set `additionalProperties: false` or reject all future fields. Instead,
PR 7 performs a narrow privacy pass over the bounded raw JSON tree before normal
contract decode or canonical projection can discard unknown members.

For this pass, normalize each raw member name by requiring valid Unicode,
normalizing to NFC, lowercasing with a locale-independent mapping, and removing
ASCII space, tab, `_`, `-`, and `.` separators. Reject an exact normalized match
in this set:

```text
contact
contactaddress
contactemail
contactemailaddress
contactinfo
contactinformation
contactname
contactphone
contactphonenumber
email
emailaddress
fullname
phone
phonenumber
replyto
reporter
reportercontact
reportercontactaddress
reporteremail
reporteremailaddress
reportername
reporterphone
reporterphonenumber
telephone
```

Exact matching—not substring matching—is required. Therefore the schema-owned
`contactPatterns` redaction counter and an additive diagnostic such as
`emailDeliveryFailed` remain allowed. Values are not treated as member names;
free text still passes through the separately owned sanitization/redaction
policy. Duplicate JSON members and invalid Unicode fail before this policy.

Future backend regression fixtures are defined as mutations of PR 1's exact
`fixtures/request.json` bytes after parsing and re-canonicalizing under the
frozen profile:

| Fixture | Mutation | Expected |
| --- | --- | --- |
| `allow-golden-request` | No mutation; includes `redaction.contactPatterns` | allow |
| `allow-additive-unknown` | Add `/payload/futureMetadata = {"futureFlag":true}` | allow |
| `allow-email-diagnostic-name` | Add `/payload/futureMetadata = {"emailDeliveryFailed":true}` | allow |
| `allow-email-word-in-statement` | Set `/payload/statement/actualResult` to `The email workflow failed.` | allow |
| `deny-top-level-reporter-email` | Add `/reporterEmail = "reporter@example.test"` | reject |
| `deny-nested-email` | Add `/payload/futureMetadata/email = "reporter@example.test"` | reject |
| `deny-case-separator-email` | Add `/payload/futureMetadata/Reporter_Email = "reporter@example.test"` | reject |
| `deny-contact-address-alias` | Add `/payload/futureMetadata/CONTACT-ADDRESS = "reporter@example.test"` | reject |
| `deny-reply-to-alias` | Add `/payload/futureMetadata/reply_to = "reporter@example.test"` | reject |
| `deny-phone-alias-in-array` | Add `/payload/futureMetadata = [{"phone-number":"5550100"}]` | reject |
| `deny-reporter-object` | Add `/payload/futureMetadata/reporter = {"name":"Example"}` | reject |
| `deny-contact-info-object` | Add `/payload/futureMetadata/contactInfo = {"value":"Example"}` | reject |

Every deny case must return the same non-retryable, schema-valid error without
echoing the field or value. Spies/fakes must prove zero normal-decoder,
database, object-store, outbox/job, GitHub, or assessment calls, and captured
logs must contain neither the prohibited member name nor its value.

### Injection and hostile text

Report text may contain prompt injection, Markdown/HTML, issue commands, URLs,
GitHub mentions, path traversal, log escapes, or fake serialized instructions.
It remains inert typed data. Sanitization and bounded rendering occur before
GitHub. The GitHub adapter accepts typed allowlisted operations and configuration
owned by the service, never repository/API/label selections from a report.

### Idempotency and partial failure

Evidence bytes are outside the V1 JSON envelope; PR 7 owns the upload sequence.
Failures can occur after evidence upload, metadata commit, issue creation, or
occurrence update. Evidence keys and job IDs are deterministic. Orphan evidence
is garbage-collected. Metadata and outbox intent commit atomically. A create
timeout reconciles an exact fingerprint marker before another create. Unique
occurrence records prevent double increments.

### Security-routing failure

Keyword-only detection can miss true security reports or route benign reports
privately. Routing uses explicit evidence categories and conservative policy,
records uncertainty, allows authorized responder correction, and fails toward
private handling when credential/data-loss indicators are present. Private
security state is not mirrored to a public issue.

### Assessment escape

A prompt claiming an analyzer is read-only does not stop tool use, network
exfiltration, or secret access. The worker must run under a separate identity
and process/container sandbox with no network namespace/egress, tools, shell,
package managers, secret mounts, cloud metadata, or source writes. It receives
sanitized serialized input and read-only exact-release source; output is schema
validated by a trusted coordinator that owns all writes.

### Webhook forgery and release confusion

Forged or replayed webhook events can falsely mark fixes merged or released.
Verify provider signatures over raw bytes, bind events to configured repository
and installation, deduplicate deliveries, fetch authoritative state through a
least-privilege adapter when needed, and require immutable commit containment
before reporting a released version.

## Severity calibration

- **Critical:** cross-reporter private evidence access; GitHub App, cloud, KMS,
  or signing-secret disclosure; internet-controlled code execution in a worker;
  forged release state affecting many reporters.
- **High:** public disclosure of raw evidence; staff authorization bypass;
  public issue creation for a security/credential report; idempotency failure
  causing widespread duplicate issues or cross-report status-notification
  disclosure.
- **Medium:** bounded denial of service; one report's occurrence counted twice;
  retention deletion failure without evidence exposure; recoverable projection
  delay or incorrect non-security label.
- **Low:** exposure of aggregate operational counts or already-public issue
  metadata without report content, identities, credentials, or authority change.

Production validation must include contract golden-byte conformance, concurrent
idempotency, receipt isolation, object-store privacy, retention deletion,
rate-limit/load tests, hostile input, GitHub partial failure, security routing,
staff RBAC, webhook replay, sandbox escape attempts, and audit-log content tests.
It must run the independent frozen fixture verifier and prove the exact raw
contact-field allow/deny matrix above, zero rejected-input side effects, and that
optional local notification derives only from authenticated receipt-scoped
status.
