# Plugin credential metadata upgrade

Cleanup and own-mirror recovery use `PluginCredentialMetadataPolicy`. An
ambiguous source holds cleanup. A positive source retains its namespace or key
references. A matching accepted definition is required to prove that an empty
inventory has no namespaces. Component history alone does not prove that an
old empty secret-marker array was complete.

`WorkspaceCapabilityActivation` owns value-free recovery evidence in the
existing retired-activation JSON field. This does not change the SwiftData
schema. Internal retention records include live credential evidence; the public
retirement view contains only kept retirement state. Owner mutations and
transaction snapshots retain both kinds of record. Export also reads raw durable setting key names before portable
configuration removes secret values and malformed fields.

Startup rereads the current own mirror for existing workspace UUIDs at first
admission, without reimporting them. A file replaced after the asynchronous
scan must contribute its current proof. UUID text case does not change identity;
malformed or different workspace IDs fail closed. The saved export, direct own-file export and
termination paths provide the same admission boundary when startup has not
completed it. Admission considers the same plugin activation and credential
generation. It records missing references and a completion marker through the
activation owner, then saves before creating the background projection lease.
Later exports use the durable marker and do not read the prior file again.
Admission decodes only the workspace ID and plugin credential projection. A
supported legacy skills-only mirror does not need current UI fields to retry;
unreadable or contradictory plugin fields still hold cleanup.

Retention bookkeeping does not change activation revisions. Freshness checks
still compare activation generations, settings, bindings, acceptance and real
retirement state. After that check, a clean caller context refreshes newer saved
retention facts through the owner before mutating or preparing credentials.
This prevents bookkeeping from invalidating its own operation or a stale cached
JSON field from overwriting newer retention evidence.
The completion marker is local to that database. Export omits it and recovery
ignores a copied marker; restoring a mirror still admits the current own file.
A newer legacy-path copy cannot stand in for a current file that still exists.
Admission reads only the current own mirror, or its legacy path when the
current file is absent. It does not scan backup directories.

Startup cleanup's shared-snapshot batch performs the same admission for every
exported workspace in a fresh saved context, before creating its committed-store
generation fence or taking its single backup. Admission cannot commit pending
edits in the caller's context. Physical destinations stay bound through this
phase. A fresh scope check under the generation fence rejects an activation
that still needs admission, including a generation changed by another context.
The batch then derives all mirrors from the admitted store snapshot. It does
not depend on recovery discovery having run earlier in the launch.
The generation fence retains the original pre-admission store identity through
publication. Its initializer cannot accept a replacement file as a new baseline,
even when that file has the same workspace UUIDs and paths.

A pending edit, unreadable prior file or failed admission save prevents
replacement. The last file and committed export obligation remain available
for retry. A scoped synchronous drain preserves other workspace obligations. Admission does not save unrelated pending edits. Read-only
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
