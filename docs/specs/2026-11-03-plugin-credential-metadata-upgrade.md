# Plugin credential metadata upgrade

Cleanup and own-mirror recovery use `PluginCredentialMetadataPolicy`. An
ambiguous source holds cleanup. A positive source retains its namespace or key
references. A matching accepted definition is required to prove that an empty
inventory has no namespaces. Component history alone does not prove that an
old empty secret-marker array was complete.

`WorkspaceCapabilityActivation` owns value-free recovery evidence in the
existing retired-activation JSON field. This does not change the SwiftData
schema. Export also reads raw durable setting key names before portable
configuration removes secret values and malformed fields.

Startup admits the already-loaded prior own mirror for existing workspace IDs
without reimporting them. The saved export, direct own-file export and
termination paths provide the same admission boundary when startup has not
completed it. Admission considers the same plugin activation and credential
generation. It records missing references and a completion marker through the
activation owner, then saves before creating the background projection lease.
Later exports use the durable marker and do not read the prior file again.
The completion marker is local to that database. Export omits it and recovery
ignores a copied marker; restoring a mirror still admits the current own file.
A newer legacy-path copy cannot stand in for a current file that still exists.
Admission reads only the current own mirror, or its legacy path when the
current file is absent. It does not scan backup directories.

A pending edit, unreadable prior file or failed admission save prevents
replacement. The last file and committed export obligation remain available
for retry. Admission does not save unrelated pending edits. Read-only
pre-reset stores can create a first mirror without a bookkeeping save; an
existing mirror remains untouched if admission cannot be saved.

Evidence for a concrete generation retires when a different generation is
published. Missing account references and unparseable setting names lack a
proved skill namespace and remain conservative across skill-generation
changes. Explicit activation removal releases that activation's proof.
Rollback restores the prior evidence with the activation snapshot.

Only publication of a prepared private generation certifies a complete marker
list. Restoring a nonce or seeding known components cannot certify it. The
certificate lets Update settle genuinely stale keys in a fresh generation
without treating a legacy model's default empty array as equivalent evidence.

Regression coverage uses synthetic disk stores, fake secrets, the normal
startup/background writer, save-failure retry and reopened-store admission.
The compatibility matrix also runs inconsistent own-mirror records through
import, save, reopen, rewrite and cleanup.
