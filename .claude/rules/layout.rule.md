---
paths:
  - "src/usr/local/lib/ai-tools/layout.lib.sh"
  - "tests/unit/layout.sh"
  - "tests/integration/perms.sh"
---

# The installed layout as one table

Every path this project installs or creates on a host is one row of a table `layout.lib.sh` declares, with the owner,
the mode and the ACL the row carries; the SELinux type is derived at read time from the policy. The library reads
what each row carries now and repairs a drifted row under the preconditions this rule states. Three consumers read it:
`atr admin system layout` (the human table and the `--check` record stream, [cli-grammar](cli-grammar.rule.md)
for the spelling, `ai-tools-admin(8)` for the contract), `atr admin system layout reconcile`,
and `tests/integration/perms.sh`, whose first section is the table's loop. [Where it runs](#where-it-runs) names
the callers of the reconcile.

**The trusted-bootstrap assumption.** The admin executable and the libraries beside it are the ones the package
installed before a repair starts: the reconcile reads its own table from a root-owned file and writes as root, so a host
where the executable or a library is not the package's is repaired by reinstalling the package or redeploying
from source, and not by this command. Every input it reads beyond its own table passes `ai_tools_conf__is_trusted`
([providers](providers.rule.md)).

## The entry

A declared row is one line of `_AI_TOOLS_LAYOUT__STATIC_ENTRIES`, seven TAB-separated fields: the path, the subject type
(`file`, `directory`, `link`), the owner as `user:group`, a four-digit mode (`0777` on a link), the named access
and default ACL entries in `getfacl`'s long form or `-`, the package whose sentinel decides whether the row applies,
and the flags. The flags each name one fact: `files` (rpm payload, listed in the package's `%files`), `config`
(`%config`, so the content is the operator's), `ghost` and `optional` (an absent entry is not a finding), `boundary` (a
read-side gate refuses the path's reader when the path is not at this row), and `compressed` (a manual page, whose entry
is the `.gz` where one exists). A row with none of `files`, `config` or `ghost` is runtime-created and its content is
not read.

The table is validated whole at load, in two provenances. A static row is held to printable ASCII without whitespace,
a backslash or a glob character; a dynamic row to any absolute normalized path, since an operator's home is the account
database's to spell. Every row is held to the field grammar, to one named user and one named group per ACL block
(`getfacl` orders named entries by id, so one of each keeps the text comparable without a sort), to a named entry within
the mode's group bits (the mask then equals the group bits), to a default entry on a directory alone, to a package list
on a directory alone, and to a path declared once. One refused declaration leaves `AI_TOOLS_LAYOUT__DECLARATION_ERROR`
set: the source succeeds, so the command names the row, and every public reader returns 2 without output, except
the stream writer, which writes the one `error` row the command's refusal is. `/opt/ai-tools` rows take their modes
from `control-plane.lib.sh`'s constants, which stay declared there.

## The entry set

`ai_tools_layout__list_entries` prints the rows that apply on this host in the records framing, the static
and the dynamic rows sorted together by path under `LC_ALL=C` so a parent precedes every path under it, then an `error`
line for each input it needed and could not read. It returns 0 for a complete discovery, 1 after an `error` line, and 2
without output while the table did not validate, so a consumer tells a complete empty set from a failed discovery. Every
consumer reads the set through `ai_tools_layout__read_entry_lines`, a collector under the rule
[records](records.rule.md) states, which waits for the enumerator and appends one `error` line for a status the lines do
not account for — 1 with no `error` line among them, or any other non-zero status — so an enumerator that ends
on a shell error or a signal reads as an incomplete discovery and never as a complete smaller set.

**A package applies while either of two files it ships exists.** `_AI_TOOLS_LAYOUT__PACKAGE_SENTINELS` names two `files`
rows per package, read with `lstat`, so one of them deleted is a `missing` row with its remedy and not a package gone
from the table with every row it places. A sentinel is a filesystem read, so it answers inside a transaction
and on a source install alike; an rpm query is not part of applicability. A package with both sentinels gone reads
as absent and does not contribute a row or a finding: `rpm -Va` is the check beyond that blind spot,
and `ai-tools-admin(8)` states it.

**The dynamic rows come from inputs the reconcile has brought to their rows first.** One `directory` row per installed
agent manifest with a valid `config_dir`, at `CP_AGENT_CONFIG_MODE`, and per enrolled operator a row
for `~/.config/ai-tools` and for each file `operators add` seeds in it (`~/.config/ai-tools/project-registry`,
`~/.config/ai-tools/secret-patterns`), with an optional row for the `~/.config/ai-tools/allowed-projects` an earlier
release wrote, which stays the registry until `system post-upgrade` migrates it. While that file exists, the operator's
`~/.config/ai-tools/project-registry` row is optional too: the migration creates it, and `--check` reports the operator
as unmigrated. Each input is read through `ai_tools_records_base__read_subject_type` and `ai_tools_conf__is_trusted`
before anything in it: an absent input does not contribute a row, since its static row reports the absence, and an input
that is present but unreadable, untrusted, of another type or not parsed whole is an `error` line and never an empty
set. A dynamic path the table declares is an `error` line too.

**Not rows:** the sandbox account's own trees and the toolchain under them, every project tree and clone, the asset
contents under the shared roots ([shipped-assets](shipped-assets.rule.md)), the entrypoint and its label
([updater](updater.rule.md)), the compiled policy module set and `/etc/codex/skills` (`perms.sh` keeps both blocks),
shipped data under `%files` without `%attr`, and every link target, which `integration/wrapper.sh` checks.

## How each entry is read

`ai_tools_layout__read_entry_state` reads one entry into the caller's associative array and appends its findings
to the caller's indexed array, validating both names as `records-base.lib.sh` validates its own
([records](records.rule.md)). The fields are read in order: the type from one `lstat`, the owner and the mode without
`-L`, the ACL text whole from one `getfacl -P` observation, the label
through `ai_tools_project_permissions__get_context_type` over `matchpathcon` and `stat -c '%C'`, and the content
of a package file from the collector. A row that is missing or of another type does not read further; a field
whose reading did not complete is `unreadable` for that row, with the field named and every finding read before it kept.

**Label applicability.** `n/a` where `/sys/fs/selinux/enforce` does not exist or `getenforce` prints `Disabled`;
on an enabled host a missing `matchpathcon`, a lookup that fails or a context that does not validate is `unreadable`,
and a path `matchpathcon` prints `<<none>>` for has no expectation. The command owns the type alone: user, role
and range are not compared, logged or changed.

**Content rests on positive evidence.** `rpm -Vv --nodeps --noscripts` prints one line per payload file, so a `verified`
state rests on a line whose digest column passed; a `5` there is `drift`, a `?` and a `missing` line are `unreadable`,
and a path with no line is `unverified`. `--nodeps --noscripts` keep a dependency line and a `%verifyscript`
out of the stream, and the collector does not run package-defined code; an unrecognized line makes the package `error`.
A verbose line may end in the file state rpm records: `not installed` and `net shared` make a row's absence not
a finding and its presence `unverified`, `replaced` is `unverified`, and `wrong color`, `no state` and `unknown state`
are `unreadable`; a `missing` line's errno text is carried in its reason, with the state rpm appends after it
on the same line, and any other suffix is an unrecognized line. rpm records the first two for a file it left
out at install (`--excludepath`, `tsflags=nodocs`) or shares with another host (`%_netsharedpath`), so a host installed
that way does not read as one package `error`. Where `rpm` is absent, where the package is not in the rpm database (a
source install), and under `--without-rpm`, every package file is `unverified`, which the reconcile reads
as a precondition. A host that holds the packages and takes a source install over them reads each file the install
replaced as `drift`, since the rpm database still lists the file with the package's digest; `install.sh` warns before it
writes there. **One pass owns its observations**: `ai_tools_layout__begin_pass` resets the SELinux applicability
and the collector's results, so a second report or a repair's re-read does not reuse what an earlier pass recorded.

**Mode and ACL are one permission contract.** `_ai_tools_layout__get_expected_acl` derives the full ACL text a row's
mode and named entries give, in `getfacl`'s order, and the observed text is compared whole, so a drift anywhere
in the ACL, the base entries and the masks included, is `acl-drift`. The mask equals the mode's group bits
by the load-time rule, so `stat`'s group bits, which show the mask where one exists, equal the declared mode
on a converged entry; a default ACL present where none is declared is `acl-drift`.

## Boundary rows and the read-side gate

A `boundary` row is availability, as every other row is: the table reports its drift and the reconcile converges it,
and no launch decision reads the table. The predicate that refuses a session is the row's own reader, by the process
making the decision, which keeps `unreadable` a per-reader state ([providers](providers.rule.md)): `system layout` runs
as root, so its `unreadable` is root's own failed read, and the state the sandbox account meets on a `0600 root:root`
`operator.conf` reads here as `mode-drift` and converges, while the gate that refuses the session names the account
and the remedy. `tests/unit/layout.sh` holds every boundary row to a map naming the gate and the runtime and boundary
test files that drive the pair ([tests](tests.rule.md)).

## The reconcile

`ai_tools_layout__reconcile` requires root, takes the lock, repairs the discovery-input rows first (the agents
directory, each manifest under it, `operator.conf`, and their ancestors in the table), then enumerates the union once
and repairs it parent-first, and prints one tagged line per observation: `changed <path> <field> <from> <to>`,
`refused <path> <field> <reason>`, `error <path> <field> <reason>`. A row is acted on while every ancestor row of it is
at its row after that ancestor's own step; otherwise it is refused naming the ancestor and is not read through it,
containment being by path component. An ancestor outside the table is the host's. The rule reads paths decoded: an entry
line is decoded once where the reconcile consumes it, and the maps that record which rows are in the set and where each
row stands are keyed by the bytes the filesystem holds, so an operator home carrying a TAB, a backslash or a byte
outside ASCII, which the stream encoder escapes, keeps the rule.

**The lock fails closed.** The reconcile takes `flock` on `/run/lock/ai-tools-layout.lock` for up to 60 seconds,
and a wait that runs out, a host without `flock` or a lock file it cannot create is an `error` line and exit 5 with no
write: two reconciles interleaving their `setfacl --set` calls is the one way this library could leave an entry
at neither state. The relabel lock proceeds unserialized for the opposite reason, stated in [updater](updater.rule.md).
`AI_TOOLS_LAYOUT_LOCK` and `AI_TOOLS_LAYOUT_LOCK_WAIT` move the pair under test. The lock bounds how long a run waits
for another; **a deadline bounds the run holding it.** `ai-tools-admin system layout reconcile` reads the library's
lines against `AI_TOOLS_LAYOUT_RUN_BOUND` seconds (600 by default, a root-only test hook whose malformed value takes
the default), and past it sends the collector and its direct children `SIGTERM`, then `SIGKILL`, and reports `MSG-H8U2`
at exit 1, since the run did not complete its table: an open blocked on a FIFO at a row's path, which the pin does not
time out, would otherwise hold the lock every caller in [Where it runs](#where-it-runs) waits on.

**Preconditions, per entry.** A `files` regular file is repaired only when its content is `verified`: `content-drift`
refuses the whole entry naming `dnf reinstall`, `unreadable` content is `error` and the entry is left whole,
and `unverified` content leaves a drifted entry reported per field and unrepaired, naming the full pass, since a mode
fixed on unverified bytes would re-bless them. A regular file, whatever its flags, is repaired in place only
at the row's owner and while no account the row does not name could write it: no group or other `w` bit the row lacks,
and no named ACL entry carrying `w` the row's text lacks, masked or not
(`_ai_tools_layout__evaluate_file_write_exposure`). A file at another owner is refused on `owner`, and one writable
beyond its row on the field that widened it, each with a detail naming the observation — the owner that is not
the row's, the mode or the named entry that grants write beyond the row — and that another account may therefore have
written the bytes, then the remedy, in one of two forms (`_ai_tools_layout__get_refusal_remedy`). A payload file names
the reinstall, which replaces the inode with the package's bytes. Every other regular file — `config`, `ghost`,
runtime-written, an operator's — names a review of its content and its restore by hand, `setfacl -b`, `chown`, `chmod`
and the row's named entries, each path quoted for a shell: `setfacl -b` removes a foreign entry `chmod` leaves masked,
a reinstall keeps an edited `%config(noreplace)` file and leaves a log as it is, and removing `.gitconfig` or a log
would drop the claims' `safe.directory` entries or the evidence. A file at a mode narrower than its row converges, since
no account the row does not name could write it, and a directory and a link take the owner repair. A missing `directory`
is created by `mkdir -m 0700`, exclusively and only under a parent that exists as a directory: a name occupied since
the read, a symlink included, fails the create and is an `error` with no further write, and a missing parent is
a refusal naming it, so no intermediate component is created. The created directory is read again and its owner, ACL,
mode and label go through the pinned apply like any drifted entry, which gives it its `changed` lines after the `type`
line. Until then no account but root can enter it, since `-m` also masks every entry a parent's default ACL hands
the directory, which a umask does not. Under a setgid parent the directory carries that parent's group and bit,
which the apply brings to the row. A missing file or link and an entry of another type are refused with the remedy
the finding carries: `operators add` for an operator's file, the reinstall for every other row.

**Fields, through a pinned descriptor.** A file or directory row is repaired the way `ai-tools-chown`'s apply block
repairs a path ([safe-paths](safe-paths.rule.md)): each write names `/proc/self/fd/N` once the descriptor holds
the identity the read observed and `ai_tools_safe_paths__is_pinned_fd_at_path` holds, and `restorecon` without `-F`
takes the path after those checks. A mismatch at any check is `error` with no write.
`_ai_tools_layout__apply_entry_fields` states the checks and the order of the writes. The parent is resolved once
before the identity read, since an ancestor outside the table may be a symlink by the host's choice, and the leaf is not
resolved, since a symlink there is what the pin exists to catch. A `link` row takes `chown --no-dereference` alone.
**The read after the steps is the postcondition.** `changed` is written for each field the steps wrote whose final value
is the row's, from the state the repair started from (the read after the create, for a created directory, whose `type`
line comes first); a field they wrote that still reports its finding, a field they did not write that drifted meanwhile,
and an entry no longer at its path or of another type are each a repair that did not hold, an `error`
at the write-failed outcome, the last with no `changed` line and its ancestor verdict `bad`; an `unreadable` field there
is an incomplete observation, and a created directory whose final type is `unreadable` does not write its `type` line.

**Each change is one log line** through `log.lib.sh` under the tag `ai-tools-layout` and `layout.log`, at `notice`
for a widening — an owner or group moving to an account other than root, a mode bit set that was clear or a setgid
or sticky bit cleared, an ACL entry added or one gaining a bit, any label change — and `info` otherwise
(`_ai_tools_layout__evaluate_change_log_level`, pure). A refusal and an error log at `warning`.

**The outcome folds in the order `ai-tools-records(5)` states for a command that changes the host:** 1 where a write
returned non-zero or the read after a repair found it did not hold, else 5 where an observation was incomplete, else 4
where a refusal remains, else 0. The unattended callers ignore the status: a layout finding is logged and does not fail
an upgrade, an install, a bootstrap or the relabel's recorded result, which stays the relabel helper's
through `ExecStart=-`.

## Where it runs

The transaction file trigger of `ai-tools-base` runs the reconcile with `--without-rpm` once per transaction, whichever
packages placed files under the install prefixes, and a `%transfiletriggerpostun` twin runs it after an erase,
so a removed package's rows leave with its sentinel; the rpm database is held while a transaction runs, so the content
comparison waits for the relabel service the base `%posttrans` starts, whose first `ExecStart=-` line is the full pass.
`install.sh` and `ai-tools-bootstrap` run the installed command before each seeds the timer stamp, so the reconcile
creates the unit search path chain and the stamp directory as rows ([ownership-and-hooks](ownership-and-hooks.rule.md)).
Every caller runs the command, so every caller takes its deadline. The base `%post` keeps its `setfacl` lines and its
setgid re-assert as the first state before any library loads; removing them is a later release's.

## Tests

`tests/unit/layout.sh` loads the checkout's library by path, with the sandbox tokens substituted into a copy
as `install.sh` substitutes them, and prints the path first. Unprivileged it drives each reader, the validator,
the entry set, the `--check` stream and the reconcile's decisions, and the per-entry repair over owned fixtures,
where a leaf or a parent swapped after the identity read is refused with the file outside the fixture left as it was. It
holds the table in lockstep with `packaging/ai-tools.spec` — every `%attr` line resolves to a row with the same owner,
mode, package and `config`/`ghost` flag, and every `files` row is a `%files` line of each package it names. As root it
builds a tree from the table itself over `AI_TOOLS_LAYOUT_ROOT` and drives the reconcile over the whole tree: each
planted drift it repairs converges in one run, each state it refuses is left as it was, and the exit order holds.
`tests/unit/layout-bound.sh` sources the checkout's `ai-tools-admin.sh` with the library stubbed and holds the command's
deadline: a reconcile sleeping past a two-second bound returns within a few seconds at exit 1 under its code, its
collector gone, beside a control that finishes inside it. `tests/integration/perms.sh` is the loop over the installed
library, and `tests/boundary/access.sh` probes the library, every boundary row, and the reconcile through the installed
`/usr/sbin/ai-tools-admin` link, established as root first, as the sandbox account, holding the status to the two
a refusal produces.

## Design notes

- **The pinned descriptor is what the sandbox-writable parents require.** `.claude`, `.codex`, `.local`
  and `.local/share` are `3770`: sandbox-group-writable and sticky, with rows under each. A sandbox-owned drifted entry
  under one can be renamed aside and a symlink planted between the read and the write,
  and `ai_tools_control_plane__apply_mode` is a `chmod`, which follows the link. The sequence every elevated helper
  that changes a path takes ([safe-paths](safe-paths.rule.md)) closes it, and the create is exclusive for the same
  reason: `install -d` accepts an existing entry and follows a symlink to a directory. The residual is the chown
  helper's: a FIFO planted at a row's path blocks the open, the command's deadline ends that run, and the lock bounds
  the next run to its wait.
- **Owner and write exposure are preconditions on a file.** Every content observation reads by path, and `rpm` does not
  verify a descriptor, so a `verified` state does not bind to the inode the pin later holds: a `chown` or a `chmod`
  on a file another account owns or could write would hand root's trust to bytes that account wrote, or writes
  after the observation through a descriptor it holds open, which a digest of the pinned descriptor would not close
  either. Refusing the file with a remedy that replaces the inode or restores it by hand closes both without a second
  content oracle. A directory has no bytes, and every link row sits in a root-only directory, so both keep the owner
  repair. A row whose declared owner is the sandbox account (`cache-cleanup.status`, `nvm-update.status`) reaches
  the repair at that owner: the precondition holds the writer set to the row's, the content is that account's by design
  and `services.lib.sh` reads it as untrusted status, and the path `restorecon` labels after the pin is stable because
  the `state` parent is root-owned and not group-writable; the timer-stamp directory the sandbox owns by design is
  a directory, which the pin's type check holds. The cost is the operator's: a package file an operator chowned
  or chmodded by hand is reinstalled, any other file reviewed and restored, and an `operator.conf` another account could
  write stays unread, with the rows it names, until it is restored by hand.
- **The discovery inputs go first because the dynamic rows are read through them.** An untrusted `agents.d` does not
  yield an agent config directory row, and an untrusted `operator.conf` does not yield an operator row, so a pass
  over the union alone would converge the input and leave the rows it hides for the next run. The first phase brings
  the inputs to their rows, the enumeration then reads them trusted, and the union pass meets the rows under `.claude`,
  `.codex` and `~/.config/ai-tools` after their parents.
- **Sentinels, not `rpm -q`.** A failed query would widen or empty the write set, and the transaction pass runs while
  the rpm database is held; two files per package keep one deleted sentinel visible as a finding.
- **The transaction file trigger is the one owner of the upgrade pass.** A trigger on the install prefixes runs once
  per transaction for every package that placed a file, so a subpackage-only install, upgrade or erase converges too,
  where a `%posttrans` of the base package runs only when the base package is in the transaction.
- **Content before mode.** A package file whose bytes are not the package's is reinstalled, not re-blessed; a mode fixed
  on it would make a tampered file look installed.
- **Label `n/a` is SELinux disabled alone.** An enabled host with the `ai_tools` module absent takes the base policy's
  type, which is what `restorecon` applies; a missing tool is `unreadable` and not a host without labels.

## Deferred

- A declared per-row override (`/etc/ai-tools/layout.d/`), so a value an operator keeps at another mode stops reading
  as drift, and the same directory as the seam a third-party package adds rows through.
- The label field is driven on a packaged host: every fixture of `tests/unit/layout.sh` is under `/tmp`,
  where the policy does not declare a label expectation, so the `label-drift` repair has no unit case.
- Two runtime gates without a test driving them, which the boundary-pair map records as notes: `ai-tools-run`'s skip
  of an untrusted session-env fragment, and the `claude-prompt`/`claude-endpoint` loader refusal.
