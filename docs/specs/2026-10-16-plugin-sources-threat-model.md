# Plugin sources: threat model (Plugins 2.0 R5)

Status: draft for review, 2026-10-16. Parent spec:
`docs/specs/2026-10-15-plugins-2-capability-redesign.md` (phase R5).

## What a source is

A plugin source is a place ASTRA lists plugins from besides its built-ins: a
git repository (https or ssh) or a local folder, holding a marketplace file
(`.claude-plugin/marketplace.json` or `astra-marketplace.json`) whose entries
point at plugin directories inside it. Listing a source shows its plugins on
the Plugins screen as Available; adding one goes through the same review,
approval and Add as an imported plugin file.

The first build of sources (phase 3, superseded) drew about eight P1 review
findings, each a different way untrusted input reached a trusted place:
secrets in URLs, ID and file name collisions, lost provenance, duplicate IDs,
rollback to older versions, silently dropped malformed files, clone
replacement that deleted the fallback first, and asset paths outside the
plugin. This document names the assets and trust boundaries first, then the
rule each threat gets, so the implementation is checked against rules rather
than findings.

## Assets

1. **Secrets**: Keychain credentials of accounts, plugin secret settings, git
   credentials (helper or SSH agent).
2. **The host**: commands ASTRA runs (checks, repairs, local tools, stdio MCP
   servers) and files it writes.
3. **Identity**: a plugin ID, a component ID, the digest an approval is bound
   to, the source a plugin came from.
4. **The library**: installed plugin definitions every workspace runs from.
5. **The person's attention**: what the screen claims a plugin is and does.

## Trust boundaries

- Everything inside a source (marketplace file, manifests, skill text, MCP
  files, icons) is **untrusted** until a person reviews and approves a
  specific digest. Approval covers that digest only.
- The source **location** is typed by the person but is still input: it is
  stored, displayed and handed to git.
- **git** runs on the host with the person's credentials: invoking it is a
  host action, and what it fetches can try to execute during the fetch.
- A **folder** source can change between listing, review and install.

## Threats and rules

| # | Threat | Rule (what the implementation must do) | Test |
| --- | --- | --- | --- |
| T1 | A token embedded in a source URL is stored in `sources.json`, shown on screen and written to logs | Accept only `https://host/path`, `ssh://[user@]host/path`, `git@host:path`, `owner/repo` (GitHub) or an absolute folder path. Refuse a URL with a password, query, fragment, or an https user; refuse `file://`, `ext::` and any other scheme. Private repositories authenticate through git's credential helper or SSH agent only. Locations are logged by source ID, never verbatim | Each refused form; a stored source never contains `@` before the host in https |
| T2 | Argument injection into git (`-uhook`, `--upload-pack=…`) | A location never starts with `-`; git is invoked with an argument array (no shell) and `--` before the location | `-c…` and `--upload-pack` locations refused; the argument vector ends `-- <location> <dir>` |
| T3 | Code runs during fetch (hooks, filters, fsmonitor, LFS smudge, submodules, `ext` transport), including a filter driver or hook the person's own git configuration defines, which a source can select through `.gitattributes` | Neither the system nor the person's git configuration is read (`GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`), so no filter driver, hook path or alias of theirs applies. `git clone --depth 1 --no-checkout --no-recurse-submodules`, then `git checkout` once the tree is measured (T11), after writing `$GIT_DIR/info/attributes` as `* -text -eol -crlf -ident -filter -working-tree-encoding` (that file outranks every in-tree `.gitattributes`, whatever its pattern, macro or nesting, on every git version; `--attr-source` would need Git 2.41, newer than some macOS 14 installs), with `core.attributesFile=/dev/null` and `GIT_ATTR_NOSYSTEM=1`, so no `ident`, `working-tree-encoding`, filter or eol attribute from the repository's `.gitattributes`, the person's `~/.config/git/attributes` or the system file changes what is written and the files are the size measured, each with `-c core.hooksPath=/dev/null -c core.fsmonitor=false -c protocol.allow=never -c protocol.https.allow=always -c protocol.ssh.allow=always -c filter.lfs.smudge= -c filter.lfs.process= -c filter.lfs.required=false -c credential.helper=osxkeychain -c credential.interactive=never`, `GIT_TERMINAL_PROMPT=0`, a minimal environment, and a timeout. Credentials come only from the system keychain helper or the SSH agent. ssh reads no configuration either: `GIT_SSH_COMMAND` is `/usr/bin/ssh -F /dev/null` with `ProxyCommand=none`, `ProxyJump=none`, `PermitLocalCommand=no`, forwarding and control sockets off, `BatchMode=yes` and `IdentityFile=none`, so a `ProxyCommand`, `Match exec` or `LocalCommand` in `~/.ssh/config` or the system file never runs and no key file is read from disk; only the agent's keys authenticate. Every option is one Git 2.39 accepts; `credential.interactive` is ignored before Git 2.47, where `GIT_TERMINAL_PROMPT=0` with no askpass still prevents prompts. Host keys are verified without a prompt: `StrictHostKeyChecking=accept-new` with ASTRA's own `PluginSources/known_hosts` first and the person's `~/.ssh/known_hosts` second, so a host seen for the first time is recorded in ASTRA's file (the person's is read, never written) and a known host whose key changed is refused on every later fetch. ASTRA only reads files from the checkout | The fixed argument and environment set; the effective ssh configuration (`ssh -G`) has no proxy or local command and its identity file list is exactly `none`; the clone, ls-tree and checkout options are all ones Git 2.39 documents; a repository using `*.txt ident`, an `[attr]` macro, `eol=crlf`, `working-tree-encoding` and nested `.gitattributes` checks out byte-identical; a hook the user's git config names does not run; a non-LFS filter driver in the user's global config, selected by the repository's `.gitattributes`, does not run |
| T4 | A marketplace entry or asset path escapes the plugin directory (`..`, absolute paths, symlinks) | Every path a source names is read below the source root through directory descriptors: the root is opened once after the file-access broker allows it, with `O_DIRECTORY|O_NOFOLLOW`, and kept only when `fstat` on the descriptor reports the device and inode that `lstat` recorded for the authorized directory just before the broker check, so a root swapped for a symlink or another directory between the check and the open is refused; and each path component is opened with `openat(…, O_NOFOLLOW)` from the descriptor of the directory above, so a symlink anywhere inside the source is refused, never followed. A scoped plugin reader holds its directory's descriptor, so a directory or file swapped for a symlink after it was checked can't redirect a read. Only a file that `fstat` on its own open descriptor reports as regular is read, opened non-blocking and never past its limit; `..` and absolute paths are refused at the reader as well as in the marketplace entry. A refused path is a visible problem on its entry | `../`, absolute and symlink-out entries are refused; a scoped plugin directory, an intermediate directory, the file itself or the source root swapped for a symlink mid-read never yields bytes from outside; the source root swapped for a symlink or another directory between the broker check and its open yields nothing; a FIFO is refused without blocking |
| T5 | A source plugin claims a built-in's ID or another source's plugin ID, to replace it or take over its accounts and settings | A plugin keeps the source it was installed from (`sourceMetadata`: kind, location ID, plugin path). A source plugin whose ID is a built-in's is refused. One whose ID is installed from elsewhere (a file, another source) is listed as a conflict and offers no Add or Update. Launch recovery of a workspace's own mirror restores an activation as recorded only when the installed copy is from the source the mirror recorded for it (a local copy counts as its own source); one whose plugin is now installed from elsewhere is held as a pending import, off and unbound, and restored once a copy from the recorded source is installed again at any version (a different digest from the same source is the Update it awaited); a chosen file's held import still needs the same digest | Built-in ID refused; cross-source ID shows conflict, no Add; the workspace's own mirror recovered where the same ID is installed from another source, or locally, activates and binds nothing, and the same source's newer copy restores it |
| T6 | Two entries in one marketplace share an ID, or a plugin declares two components with one identity | Duplicate plugin IDs in one source: both are listed with a problem and neither is offered. Component identities are validated as for any package (R3) | Duplicate IDs flagged; duplicate component refused |
| T7 | Rollback: a source serves an older version to replace a newer installed one | An Update is offered only for a strictly greater semantic version from the plugin's own source. Equal version with a different digest is shown as changed and needs review; lower is never offered | Lower and equal versions are not offered as Update |
| T8 | What was reviewed is not what gets installed (folder edited, clone refetched) | Review shows the digest; Add installs the exact package bytes that were reviewed, copied into the library. The runtime never reads a source checkout | Changing the folder after review makes Add refuse with "changed since review" |
| T9 | A source plugin's checks or repairs run host commands | Checks from a source plugin are not run (shown as "not checked") until the read-only rule (parent spec, Health and repair) is enforced against them. Terminal repairs must be a plain call to the component's own CLI, exactly as the check declares it, with no line breaks, control characters or shell metacharacters (`;|&` `` ` `` `$<>()` are refused through `LocalToolSecurityPolicy`, `RepairAction.isSafeTerminalCommand`) (R0), and a button exists only for a known CLI (`HealthCheckPolicy.knownCLIs`, the list version checks use), named as a bare name or a trusted installed path (`TrustedExecutablePath`, symlinks resolved), running one of its listed sign-in commands (`TerminalRepairPolicy`, matched by `CLICommandShape`): positionals must spell the sign-in exactly, and each flag must be one that sign-in lists, with a value it accepts (a flag's separate value counts as a positional unless the flag takes one). Allowed: `gh auth login` (`--hostname`/`-h`, `--git-protocol`/`-p https|ssh`, `--web`/`-w`); `gh auth refresh` (`--hostname`/`-h`); `gcloud auth login` (`--no-launch-browser`, `--update-adc`, `--account`, `--project`, `--configuration`); `gcloud auth application-default login` (the same without `--update-adc`); `az login` (`--tenant`/`-t`, `--use-device-code`); `aws sso login` (`--profile`, `--sso-session`, `--use-device-code`); `aws configure sso` (`--profile`, `--use-device-code`); `codex login`, `cursor-agent login`, `opencode auth login` (no flags); an install step only the reviewed Homebrew command for its component, chosen by the CLI its check runs (`brew install gh`; `brew install --cask google-cloud-sdk` for gcloud, bq, gsutil; `brew install powershell` or `--cask powershell`; `brew install jq`; `brew install --cask docker`; `brew install copilot-cli`; `brew install opencode`), never a tap-qualified name (Homebrew runs a package's code as the person, and `owner/repo/name` adds that tap). A sign-in carries the credential store the failed command selected itself (`CLOUDSDK_CONFIG`, `GH_CONFIG_DIR`, `XDG_CONFIG_HOME`) as an `env` prefix. There is no fallback for other CLIs (an unknown binary gives `auth`/`login`/`sso` any meaning it likes; `touch auth` creates a file): its declared repair is shown as the plugin's own hint, guidance with no button, and import refuses it. Status and probe commands (`gh auth status`, `gcloud auth list`, `print-access-token`, `az account show`, `aws sts get-caller-identity`) change nothing, so they are health checks only, never a repair. Anything unlisted refuses the repair, including `--insecure-storage`, `--scopes`/`-s`, `--with-token`, `--brief`, `--cred-file` and `--impersonate-service-account`. The rule is enforced at launch by every repair button and at import by `CapabilityPackageValidator` ("Unsafe repair command"), so `gcloud projects delete victim --quiet` is never offered. A source plugin's own checks never run: a check naming a known CLI by bare name is replaced at listing time by ASTRA's own read-only check for that CLI (`HealthCheckPolicy.ownCheck`), with its semantic and contextual tests dropped, so a repair is verified against ASTRA's check and the sign-in rule still knows the CLI; any other check is dropped and shown as not run. Any other plugin's checks follow the read-only check rule (parent spec, Health and repair). Nothing a source declares runs without a person's click | A source plugin's `exec` check is never invoked; `gcloud auth login; rm -rf ~`, a lookalike path, `gcloud projects delete victim --quiet`, `gh repo delete x --yes` and `gh api -X DELETE /repos/x` are refused as repairs, as are `gh auth status` in any flag form, `gh auth refresh --insecure-storage`, `gh auth refresh --scopes admin:org` and `touch auth`; every bundled and ASTRA-built repair passes, and every CLI with a sign-in is a known CLI; `gh repo delete x --yes` as a source plugin's check becomes `gh auth status`, a path or unknown binary is dropped, and every own check is read-only |
| T10 | MCP servers and local tools from sources run arbitrary commands or reach plaintext endpoints | The package validator's rules apply unchanged: `LocalToolSecurityPolicy` for commands and default arguments, https (or loopback http) for remote MCP, declared environment keys only; unsupported headers are reported, not dropped | Unsafe command, http remote and undeclared env refused |
| T11 | Malformed or oversized input is dropped silently or exhausts memory or disk (one huge blob, or many files the marketplace never names) | The download is watched and cancelled past 64 MB, and objects over 1 MB are streamed rather than inflated in memory (`core.bigFileThreshold=1m`), so a small pack of a huge compressible blob can't exhaust memory before the tree is measured (128 MiB zero blob: 139 MB peak without, 3.6 MB with); a fetched pack may declare at most 100,000 objects: git writes a pack's header before indexing it, so the download watcher reads the object count (bytes 8–11) of every pack under the clone's `objects/pack`, finished or still being indexed (`tmp_pack_*`), stops git past the bound, and checks again before `ls-tree` (`index-pack` keeps about 80 bytes per object; 1,001,002 objects in 39.6 MB took it to 79.6 MB unbounded and 4.9 MB with the bound, 5,000,000 tiny objects to 405 MB unbounded); the clone has no checkout until `git ls-tree -r -l` shows the tip's files total at most 64 MB and 10,000 files; past either, the fetch is refused and its staging folder removed, keeping the previous checkout. Files over a size limit (marketplace 256 KB, manifest 512 KB, skill text 256 KB, icon 512 KB), more than 200 entries, or undecodable files are listed with a problem, never skipped silently. One listing of a source, folder or git, reads at most 64 MB and 10,000 files in all (`PluginSourceReadBudget`, shared by every plugin's scoped reader): a folder source has no download or checkout bound, and entries naming the same files could otherwise re-read a checkout many times over. Every path that exists counts as one file, whether read, refused or only found too large, and no read asks for more bytes than the budget has left. Past either bound the source is refused with "This source holds more than ASTRA reads for plugins (64 MB or 10,000 files), so it wasn't listed."; the entries listed before stay shown under that problem, and import, which re-lists the source, is refused. An unreadable `sources.json` is reported and never overwritten | Each limit; an oversized repository is refused before any checkout and leaves nothing behind; a corrupt `sources.json` survives a save attempt; a pack header over 100,000 objects stops git while it indexes and a fetched pack over the bound is refused before `ls-tree`; a folder source whose 200 entries name one 1 MB plugin is refused, as are 200 entries × 61 files, and a folder that grows over the limit keeps its previous listing and refuses import |
| T12 | A refetch fails halfway and leaves no usable checkout | Fetch into a temporary directory, then replace the previous checkout atomically; the previous one stays until the new one is complete | A failed fetch keeps the previous checkout |
| T13 | Removing a source while it is fetching, or two fetches of one source | Operations on one source are serialized; Remove waits for, or cancels, a running fetch. Every Add from a source, file import, Create and Remove of a plugin also runs exclusively per plugin ID, keyed as the library names the file (case and separators folded), across sources and ASTRA processes (`PluginSourceStore.exclusively`: an in-process key set plus `flock` on `PluginSources/locks/<sha256>.lock`). A second operation on that ID is refused ("being added, imported or removed already"), not queued, and a source import re-checks the T5 conflict inside the lock | Remove during fetch leaves no orphan directory; a second source's Add of the same ID during the first's library write is refused, and afterwards meets the first's copy as a conflict |
| T14 | A source misrepresents itself on screen (name, author, icon), including with line breaks or bidirectional controls that reorder or fake rows | The screen shows the source's location (sanitized, T1) next to every plugin from it, and the review sheet shows the digest. Names from the source are display text only, cleaned once at listing time, before the digest (`PluginSourceDisplayText`): the package name, author, description, category and tags, each component's name and summary, marketplace entry names, and problem text quoting source paths. Control characters, Unicode format characters (`Cf`, which includes U+202A–U+202E, U+2066–U+2069, U+200E/F, U+061C and zero-width joiners) and line/paragraph separators are removed; a line break or tab becomes a space; whitespace runs collapse and the ends are trimmed; text is capped at 120 characters for names and 1,024 for descriptions, ending in "…". A removed character reports "Display text changed: control characters removed" on the entry and a cut reports "Display text changed: long text shortened"; either way the entry offers no Add. IDs are never changed; they are validated separately. The source's own location and name are display text too: the Sources row, a plugin's subtitle, the review sheet's origin, an installed plugin's origin and the listed package's source metadata show the cleaned form; `PluginSource.make` refuses a location that would need cleaning, and a stored source that needs it (an older or edited `sources.json`) is listed with the same problem, offers nothing, and its import is refused | The row shows the source; a newline, CRLF, RLO, LRI/PDI, ZWJ, the other bidi marks and an over-long name are cleaned and flagged; spacing alone is not flagged; IDs are unchanged; a line separator or an over-long path is refused when added, and a stored RLO location shows cleaned and is refused |

## Out of scope for R5

- Signature verification of sources or plugins (no signing infrastructure).
- Sandboxing the git process beyond T3 (a dedicated helper is future work).
- Plugins whose marketplace `source` is not a path inside the repository
  (another git URL, a package registry): listed as unsupported.

## Exit criteria

Every row's test passes; a full `swift test` passes; adding a plugin from a
local folder source and from a git source (a local bare repository in tests)
installs exactly the reviewed digest, and its later Update follows T7.

## How R5 was built (2026-10-16)

R5 is on `plugins2-r5`, stacked on R4. Each row above has a test in
`PluginSourcesTests`, named by its row.

- **Where the rules live.** `PluginSource.make` (T1, T2),
  `PluginSourceFetcher` (T2, T3, T12), `BrokeredPluginDirectory` and
  `PluginSourcePluginReader` (T4, T11), `PluginSourceCatalog` (T5–T10,
  T14), `PluginSourceStore` (T11), `PluginSourceCoordinator` (T13).
- **Reading.** Every plugin is read through a reader scoped to its own
  directory (`PluginDirectoryReading.scoped(to:)`), so a symlink can't
  reach a sibling plugin either. Only regular files are read, so a FIFO
  can't hang a listing. A source plugin's asset icon is replaced by its
  symbol and reported, so no asset path is read or copied.
- **Checks (T9).** A source plugin's setup checks are stripped from the
  package at listing time and reported as "N setup checks (not run)", so
  nothing it declares can run. Its digest is that of the stripped package.
- **Review and import (T8).** The review sheet shows the source, the digest,
  what isn't brought over, and `worksOn`. Import re-lists the source,
  refuses when the digest changed or a rule now refuses it, and installs
  the reviewed copy. Adding it to a workspace is then the row's Add, as for
  an imported file.
- **Provenance (T5).** The library files every installed plugin as local
  on load (`CapabilityGovernanceNormalizer`), so a file on disk can never
  claim a source. Where an installed plugin came from is a separate record,
  `PluginSources/provenance.json`, keyed by plugin ID, holding the content
  digest of the copy the source installed (`PluginSourceCatalog.contentDigest`).
  A record whose digest no longer matches the installed copy does not
  count, so only that source's own copy is "from" it. Both directions of
  the cross-store transition are journaled before the library write. A
  source import calls `beginProvenance`, which keeps the copy the record
  names and adds the incoming one as `pendingDigest`; only after the
  library write does `recordProvenance` settle on the new digest, so an exit
  between the two leaves whichever copy the library holds recognised as the
  source's own. A local install or Remove ends the record (Remove, a file
  import or Create, through `PluginSourceStore.forgettingProvenance`): before
  the library write it records a `pendingForget` intent (`remove`, or
  `install(digest)` with the digest of the copy being written); after the
  write succeeds the record is dropped; if the write fails the intent is
  cleared and ownership kept. An intent left by an exit is settled by what
  the library holds (`Provenance.resolved`): the record is forgotten when
  the plugin is gone after a Remove or the library holds the local
  install's copy, byte-identical or not, and kept (intent dropped) only when
  the library still holds a copy the record names that the local install
  would not have written. With identical bytes the two copies can't be told
  apart, so the intent forgets; an unowned copy only refuses more.
  `isOwnCopy` applies this at every read and the next load writes it
  (`PluginSourceCoordinator.reload`). A removed source plugin imported again
  from a file is local, with no updates from the old source and no conflict
  shown to other sources, even after an exit at any step.
- **Imported activations (T5).** The workspace mirror records, for each
  plugin activation, the source of the copy its digest names:
  `source: "plugin-source:<id>"` for a copy a source installed, taken from
  provenance at export (`PluginSourceIdentitySeam`), or nothing for a local
  copy; an older file without the field counts as local. A chosen file's
  activation (`.validate`) is enabled, with its settings, overrides and
  accounts restored, only when the installed copy has the same digest and
  its provenance names the same source: a digest proves the content, not
  which source owns its updates. Otherwise it imports off with nothing
  restored, reported as changed (`pluginsChanged`,
  `pluginsFromAnotherSource`). Recovery of the workspace's own mirror
  (`.preserveRecordedState`) restores exactly what was recorded.
- **Held imports (T5).** A chosen workspace file's activation that can't be
  accepted on import (its plugin isn't installed here, or another copy or
  source of it is) is not discarded: its non-secret payload (settings, known
  components, the override and account rows that import created, the digest
  and the source) is kept pending on the workspace, on the record that holds
  pending overrides (`RetiredPluginActivation.pendingImport`), and nothing of
  it is applied or projected while it waits. It is restored once, on Add or
  by the launch pass, when an installed copy has the same digest and source;
  the activation stays on or off as it is, settings, overrides and accounts
  come back only for components the definition declares, and no secret is
  kept or restored. A pending import for another copy or source keeps
  waiting; Remove of the plugin drops it in every workspace, and deleting the
  workspace drops it with the record. A held import is listed under Action
  needed with the plugin's name, why it waits (not installed, another
  version, or a copy from another source, naming both), Add when the
  installed copy is the one it waits for, and Discard, which drops it
  through the same journaled, mirrored save as every plugin-state change.
- **Updates (T7).** Shown in the Sources section: "Review update" for a
  greater version, "Changed: review" for the same version with another
  digest. The import replaces only the copy installed from the same source.
- **Testing transport.** The fetcher's allowed transports are a property
  (https and ssh). Only the tests add `file`, to fetch a local bare
  repository as the exit criteria ask.
