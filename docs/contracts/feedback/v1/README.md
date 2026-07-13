# ASTRA Feedback Contract V1

This directory is the language-neutral authority for the ASTRA feedback wire
contract. `ASTRACore/Feedback` is the Swift implementation. Downstream client,
backend, diagnostics, persistence, UI, transport, assessment, and GitHub tracks
consume this contract and must not redeclare or fork it.

## Root cause and ownership

Before V1, feedback-relevant facts existed only as app-internal diagnostics,
build, and runtime types. No shared owner defined byte representation, privacy
classification, bounds, status vocabulary, or retry identity. Independent
client and server implementations would therefore produce mutually plausible
but incompatible schemas. V1 fixes that ownership gap before any transport or
persistence code is added.

## Documents

- `feedback-contract.schema.json`: JSON Schema 2020-12 for request envelopes,
  receipts, local status projections, and remote status projections.
- `openapi.yaml`: OpenAPI 3.1 request/receipt/status/error framing and reusable
  assessment/staff-triage schema references; it intentionally selects no
  authentication scheme.
- `fixtures/request.json`: canonical request bytes.
- `fixtures/request.sha256`: SHA-256 of the exact `request.json` bytes.
- `fixtures/payload.sha256`: SHA-256 of the exact canonical `payload` member.
- `fixtures/receipt.json`: canonical receipt bytes with a fake status credential.
- `fixtures/status-local.json`: canonical local status bytes.
- `fixtures/status-remote.json`: canonical remote status bytes.
- `fixtures/status-read-request.json`: canonical credentialed status-read bytes.
- `fixtures/error.json`: canonical typed error bytes.
- Matching `.sha256` files contain the hash of every golden document.
- `fixtures/request-hostile.json`: valid hostile-data and unknown-enum fixture.
- `fixtures/request-malformed-unicode.json`: invalid unpaired-surrogate fixture.

Golden JSON files contain no trailing newline. Their bytes, not a parsed and
reformatted equivalent, are the cross-language test vectors.

The schema root uses `anyOf` because additive DTOs deliberately permit unknown
members and some valid documents therefore satisfy more than one narrower
shape. Endpoints and consumers validate against their named `$defs` reference.

## Canonical JSON profile

V1 uses a restricted JSON Canonicalization Scheme profile compatible with RFC
8785, with additional contract constraints:

1. Encode as UTF-8 with no BOM, insignificant whitespace, or trailing newline.
2. Sort every object member by lexicographic UTF-16 code units.
3. Normalize every string value to Unicode NFC and normalize line endings to
   LF before validation. Reject unpaired UTF-16 surrogates and non-NFC input.
4. Escape only JSON control characters, quotation mark, and reverse solidus.
   Use the short escapes `\b`, `\t`, `\n`, `\f`, and `\r`; encode other U+0000
   through U+001F values as lowercase `\u00xx`. Do not escape `/` or printable
   Unicode.
5. UUIDs are lowercase RFC 4122 strings.
6. Timestamps are UTC with exactly millisecond precision:
   `YYYY-MM-DDTHH:mm:ss.SSSZ`. Leap-second inputs are rejected.
7. V1 permits JSON integers only. Floating point, exponent notation, `NaN`, and
   infinities are forbidden. All declared values are bounded well inside the
   interoperable signed 53-bit range.
8. Omit absent optional members. Never encode an absent value as an empty
   string. JSON `null` is not used by the V1 Swift encoder.
9. Sort evidence artifacts by `relativePath`, then `artifactID`, using raw UTF-8
   byte order after NFC normalization. Sort consent selections and omissions by
   `artifactID`; sort warnings by `code`, then `artifactID`.

`JSONEncoder.sortedKeys` is not the portability contract. Implementations must
match the canonical request, receipt, and status golden bytes.

## Hash inputs

- `payloadSHA256` is lowercase hexadecimal SHA-256 of the canonical V1
  known-field projection of the `payload` object alone. Unknown additive members
  are inert and excluded; a producer cannot rely on them for behavior.
- `evidenceArchiveSHA256`, when present, is lowercase hexadecimal SHA-256 of the
  final evidence archive bytes after policy, redaction, ordering, and packaging.
- The request golden hash is SHA-256 of the exact canonical envelope bytes. It
  is a fixture integrity check, not an authentication signature.
- Artifact `sha256` values cover each final artifact's exact bytes, never the
  pre-redaction source bytes.
- `canonicalDigestSHA256` is SHA-256 of this exact UTF-8/LF framing, including
  the final newline:

```text
astra-feedback-digest-v1
formatVersion=1
payloadSHA256=<payload hash>
redactionPolicyVersion=<policy version>
evidenceArchiveSHA256=<archive hash or ->
artifact=<artifact ID>:<final artifact hash>
artifact=<next ID>:<next final artifact hash>
```

Artifact lines use the canonical manifest order. This digest, installation ID,
and idempotency key jointly own retry identity.

Authentication is intentionally not frozen in V1. There is no request-signature
member or algorithm in this schema. PR 7 must select authentication before
adding a separately versioned HTTP authentication profile.

## HTTP request framing

The V1 intake request body is exactly one canonical `FeedbackReportEnvelopeV1`:

```text
POST <intake endpoint>
Content-Type: application/vnd.astra.feedback.v1+json
Accept: application/vnd.astra.feedback.receipt.v1+json
Idempotency-Key: <envelope.idempotencyKey>
ASTRA-Installation-ID: <envelope.installationID>
ASTRA-Payload-SHA256: <envelope.payloadSHA256>
ASTRA-Request-Digest-SHA256: <envelope.canonicalDigestSHA256>
ASTRA-Evidence-SHA256: <envelope.evidenceArchiveSHA256>  # omit when absent
Content-Length: <canonical envelope byte count>
```

The idempotency and installation headers and envelope members must match
exactly. Reuse of one key by the same installation with the same canonical
digest returns the original receipt without creating a second report or
occurrence. Reuse with a changed digest is a permanent
`idempotency_key_reuse` conflict; reuse from another installation is a
`cross_installation_replay` conflict. A retry never generates a new key.

The non-secret report/receipt IDs do not authorize status reads. A receipt
contains a separate high-entropy `statusReadCredential` with an expiry. Status
reads send it in the request body, never a URL, and bind it to the installation
ID and receipt ID. Clients protect it as secret local state. Servers store only
a one-way keyed verifier or encrypted representation, never plaintext logs,
issue content, analytics, or URLs. The checked-in credential is fake test data.

Evidence bytes are intentionally outside the JSON request framing in V1. The
native transport and intake PRs may select an upload sequence, but they must not
change the envelope, hash inputs, or idempotency rules.

## Privacy and unknown values

Evidence disclosure is fail closed:

- `standard`: routinely shareable only after the complete inventory is shown.
- `sensitive`: excluded by default and requires an explicit review timestamp.
- `explicit_opt_in`: browser evidence, screenshots, and macOS diagnostics;
  excluded by default and requires a per-item review timestamp.

### Consent and evidence must agree

`payload.consent.evidenceSelections` and `payload.evidence.artifacts` are two
independently-shaped arrays, so JSON Schema's structural validation cannot
express agreement between them. Every V1 implementation, not only the Swift
one, must enforce both invariants explicitly when validating a `payload`:

1. The set of `artifactID`s with `included: true` in `evidenceSelections`
   must equal the set of `artifactID`s in `evidence.artifacts` exactly: every
   included selection has matching evidence, and no evidence artifact goes
   unselected.
2. For every `evidence.artifacts[]` entry, the corresponding included
   `evidenceSelections[].disclosureClass` must exactly equal
   `evidence.artifacts[].disclosureClass`. Consent may never understate (or
   overstate) an artifact's privacy classification; a mismatch fails closed
   with `payload.consent.evidenceSelections[].disclosureClass is inconsistent`.

These checks apply to the raw `artifactID`/`disclosureClass` values before any
schema-permitted additive members are considered. See the `$comment` on the
`payload` definition in `feedback-contract.schema.json` for the
machine-readable pointer back to this section.

Unknown values are preserved only for explicitly extensible data strings:
artifact kind, runtime ID, runtime failure category, evidence reason, receipt
disposition, and remote engineering status. Unknown disclosure classes, local
workflow states, and failure dispositions fail decoding because guessing would
weaken privacy or mutate the local state machine.

Unknown object members are ignored by V1 decoders and allowed by the schema so
new optional members remain additive. Payload hashing recursively projects only
the members declared in the V1 schema; unknown members do not participate in
V1 bytes or hashes because an older implementation cannot represent them. A
producer that emits an additive member must publish an
updated golden fixture and compatibility evidence before relying on it; fields
that affect identity, privacy, requiredness, ordering, or hashes require V2.

Hostile report text, filenames, runtime summaries, and remote metadata remain
inert JSON strings. Consumers must never interpret them as prompts, shell input,
paths, templates, URLs, or GitHub markup without the later owning boundary's
validation.

## Size limits

| Value | V1 maximum |
| --- | ---: |
| Identifier or idempotency key | 128 characters |
| User statement field | 8,000 characters |
| Other bounded text | 1,024 characters |
| Relative artifact path | 512 characters |
| Status-read credential | 32–512 base64url characters |
| Evidence artifacts/selections | 128 |
| Omissions | 128 |
| Warnings | 128 |
| One artifact | 20 MiB |
| All evidence | 50 MiB |
| Evidence window | 24 hours |
| Upload attempt count | 1,000 |

Reporter email/contact fields are intentionally absent from V1. Receipt-scoped
status is the reporter follow-up channel.

Validation occurs before canonical hashing or transport. Additive optional V1
members are backward compatible and ignored by older decoders. Removing or
renaming members, changing requiredness, bounds, canonicalization, ordering,
hash inputs, closed enums, or fixture bytes requires a compatibility review and
a new format version when old and new peers cannot interoperate.
