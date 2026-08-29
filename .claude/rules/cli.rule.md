---
paths:
  - "src/usr/local/bin/ai-tools.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-setfacl.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-unclaim.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-safedir.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-reclaim.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-relabel.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-stop.sh"
  - "src/usr/local/lib/ai-tools/relabel.lib.sh"
  - "src/usr/local/lib/ai-tools/services.lib.sh"
---

# Management CLI and project lifecycle (`ai-tools`)

`ai-tools` (`/usr/local/bin/ai-tools`) is the project-lifecycle CLI. It runs **as the
projects user** — not root, not the sandbox account. It writes the operator-owned allowlist
(`~/.config/ai-tools/allowed-projects`) directly, and reaches the root-owned git
`safe.directory` list in `/opt/ai-tools/.gitconfig` (`root:ai-tools 644`: world-readable,
root-write-only) through the `ai-tools-safedir` root helper (`sudo`), alongside its other
root operations. It refuses to run as the sandbox account (the agent must not manage its own
allowlist).

**Root runs the verbs that write no operator-owned state, and no others.** That criterion is what
the root refusal protects: a registry written by root names an owner whose own launch gate cannot
read it. `ROOT_ALLOWED_VERBS` — `--audit`, `--status`, `--list`, `--providers`, `--stop` — is the
whole set, and a verb joins it on what it **writes** rather than on what it reads. `--audit` is
what the carve-out exists for: the trail it reads is `700 root:root`, so the verb needs root by
construction, and a blanket refusal left it unreachable from both sides on a host whose only
operator holds no general sudo grant. `--stop` is the one member that **acts** rather than
reports: it writes no registry, its helper requires root anyway, and root is the identity an
unattended detector usually runs as — so a CLI that refused root there refused the one principal
the rung most has to serve, while granting nothing new (root can run the helper directly and can
signal any process on the host). The set is named once and read by the guard, by the guard's own
refusal, and by `ai-tools(1)`.

The check runs **after** `--for` is separated from the command's arguments, because `$1` before
that point is not reliably the verb (`ai-tools --for op --list` leads with the flag). That
placement also refuses `--for` for root in either argument order: root is absent from `OPERATORS`,
so an entry written for it would name an owner no ownership helper can resolve. `require_operator`
does not cover this on its own — it gates the mutating verbs, and `--list` is not one.

`--list` run by root reads root's own registry, which no bootstrap creates, so it reports an empty
list correctly and misleadingly. It therefore says whose registry it read and names the enrolled
operators, since an allowlist is per-operator by design. Root cannot follow that with `--for`, so
the line points at running the report as the operator instead.

## Bootstrap preflight

A single `require_bootstrap` gate runs **before dispatch**: it keys on a launcher symlink under
`/opt/ai-tools/bin` — bootstrap's last load-bearing artifact, written after the account, Node, and
the agent package all succeed — so its presence means provisioning finished, and its absence fails
the CLI fast with the provisioning hint rather than mid-operation in a root helper. It is the same
symlink the launch wrapper gates on, so both entry points share one definition of "provisioned".
Every command is behind the gate, `--version` included — an unfinished install reports nothing,
fail-closed. Three bypass it (`BOOTSTRAP_EXEMPT_VERBS`), each because it is meant for a host that
may be broken: `--status`, the diagnostic, reports the unprovisioned state itself, since
a health check must run precisely when provisioning may have failed; `--audit` reads a record
of what already happened, which an install that never finished does not invalidate — a failed
provisioning is when that record is most worth reading; and `--stop` ends sessions **already
running**, needing nothing from the toolchain to do it. That last one matters because of the gate's
own coupling below: keying on one agent's launcher symlink would otherwise put the incident
ladder's last rung out of reach on a host that enables a different agent, or that lost the symlink
while sessions were live. The set is deliberately narrower than
`ROOT_ALLOWED_VERBS`: `--list` and `--providers` describe a toolchain that has to exist first, so
they stay behind the gate.

**The gate names one agent.** `CLAUDE_LINK` is the literal `/opt/ai-tools/bin/claude`, so a host
that enables a different agent and disables `claude-code` has a provisioned toolchain the CLI
refuses to act on. This is the one place the otherwise agent-agnostic CLI is coupled to a specific
provider; the sentinel it needs is a launcher symlink for *any* enabled agent, which
`ai_tools_enabled_agents` already resolves ([providers](providers.rule.md)).

## Operator preflight

A second gate, `require_operator`, runs before dispatch for the **operator-acting** commands
(`--project-*`, `--sandbox-*`, `--lockdown`, `--reclaim`, `--relabel`) and refuses when the
invoking user is not listed in `OPERATORS` in `operator.conf`. Those commands resolve the
caller's identity from that list (`operator.lib.sh`, inside the root helpers); without the gate an
unenrolled user proceeds through the registry writes and confirm prompts only to be refused by the
first helper that resolves owner (`ai-tools-lockdown`: "not in allowed projects for current
operator"), after partial state was written and rolled back. The gate replaces that with one
up-front message pointing at `sudo ai-tools-admin operator add <user>`. `operator.conf` is `644`,
so the unprivileged CLI reads `OPERATORS` directly, and enrollment there takes effect on the next
command — no re-login, unlike the `ai-ops` group the admin verb also grants (which the launch
wrapper needs and which does require a fresh login). The **informational** commands
(`--help`/`--version`/`--list`/`--providers`) stay open, so an unenrolled user can still read usage
and inspect the host.

A third gate, `require_sudo_access`, refuses a verb whose root helper the caller holds no sudo
grant for, and names the command that reaches it instead (below). A fourth, `require_for_target`,
runs last and validates a `--for` run (see *Acting for another operator* below). It is a no-op
without the flag.

### The caller with no sudo grant

Every helper outside the `%ai-ops` NOPASSWD rules ([launch](launch.rule.md) holds the drop-in's
contents) is reached by a plain `sudo`, which assumes the operator also holds a general grant. An
account in `ai-ops` and in no sudoers rule is a supported shape — it is what `--for` exists for —
and it is distinct from having no password.

`sudo` authenticates before it decides whether a rule matches. `require_sudo_access` answers that
question ahead of it, before the run's first `sudo` — the same ordering `require_for_target`
follows — so a caller holding a password is never asked for it on a verb no rule lets them run. Each verb is
probed on the **first** helper it reaches (a `--for` run on `ai-tools-allowlist`, whose snapshot
precedes the verb's own helper), so a host granting some helpers and not others is answered
accurately rather than through one representative. `--sandbox-push`, `--sandbox-remove`, and the
informational verbs reach no helper that can refuse the command, and are not probed. Neither are
`--relabel` and `--stop`, the privileged verbs an operator without a general grant can already run
through the `%ai-ops` rules for their helpers: probing either answers "grant present" every time,
so the entry would carry no information. (`--stop`'s rule covers its bare form only, so its flagged
forms do meet sudo's ordinary prompt — see [docs/session-stop.md](../../docs/session-stop.md). The
probe could not have reported that either: it asks about a helper, not about a command line.)

The probe is `sudo -n -l <helper>`, which cannot prompt. An operator holding a general grant gets
exit 0 and the command echoed back, whether or not a credential is cached — listing an allowed
command is not itself password-gated on a stock sudoers. **The refusal is silent:** for a command
no rule matches, `sudo -l` exits non-zero and prints nothing, and the *"Sorry, user … is not
allowed to execute"* line an operator sees comes from the attempt to **run** the command, never
from the listing. So silence with a non-zero status is the answer this reads as a missing grant.

Silence is conclusive only while sudo is answering, so it is confirmed against a bare `sudo -n -l`,
which lists the caller's whole rule set — an `ai-ops` member always has one. That separates "sudo
knows this caller and has no rule for that command" from a sudo that failed for its own reasons,
and only the first refuses. A *password is required* answer means listing is itself password-gated
(sudoers `listpw`), so the grant may exist and that caller is left to the ordinary prompt;
`LC_ALL=C` pins the wording of that one match.

**The gate reports; it does not decide, and so it fails open.** The project's fail-closed rule
governs the predicates that decide what a principal may do: each resolves, on any failure, to
*less* access ([CLAUDE.md](../../CLAUDE.md)). This gate is not one of them. It grants nothing, and
`sudo` is still the only thing consulted about the helper — so an inconclusive probe (no `sudo`
binary, a translated or unrecognized answer) falls through to the call site and lets sudo answer,
leaving the access outcome identical to having no gate at all. The composition stays fail-closed
because the enforcement point it sits in front of is.

Failing *closed* here would invert that: refusing on an unparsed message subtracts access sudo
would have granted, turning a diagnostic into an access decision that can only ever take away —
a `wheel` operator whose sudo answered in a locale the match did not cover would lose a command
they hold the grant for. The cost of the direction chosen is bounded and is never a security one:
on a host where the answer cannot be read, the operator meets sudo's own message, which is the
behaviour this gate exists to improve on rather than to guarantee.

The refusal names the account, the helper, and one command, and stops there. Who that account
belongs to is not knowable — a service account, a person on a restricted login, an administrator
working from one deliberately — nor is who runs the suggested command or what they are to each
other. So it recommends no route to obtaining a grant, and describes nothing as anyone's. For the
delegable verbs the command carries `--for <account>`, which is the whole mechanism: the verb runs
against that account's registry whoever performs it. `--sandbox-create` takes no `--for` (the clone
is made with the git credentials of whoever runs it), so its refusal names two commands — the
create, then a `--project-claim --for <account>` over the resulting clone, which the protected-paths
backstop deliberately permits. `--audit` additionally names a `journalctl` query, since the trail is
written to journald as well and many hosts let an ordinary account read it — a partial view, the
file sink being the authoritative one.

## Commands

- `--project-claim [path]` — claim a real project in place
  (idempotent; default cwd): register it (allowlist + git `safe.directory` via
  `ai-tools-safedir`), pin repo-local `core.filemode=true`, set the project's directory group +
  setgid via `ai-tools-setgid` and apply the group-permission ACL via `ai-tools-setfacl`, apply the
  SELinux project label, run the secret pre-check, ensure the sandbox account can traverse the path
  to the project (a default-NO prompt grants a traverse-only `u:SANDBOX_USER:--x` ACL on each
  blocking ancestor the operator owns and that is not a system directory; see *Reachability* below),
  and — when a `.git` tree is present but not yet normalized — offer (default-yes prompt) to
  normalize it for agent git-history access via `ai-tools-setfacl --with-git`. The flow renders
  as a sequence of **self-contained blocks** (see [messaging](messaging.rule.md) for the headline
  frame): *Review* (the pending-step overview announcing every later block, the drift reports, and
  the default-NO proceed confirm covering exactly the steps listed), *Secret lockdown* (before any
  access-granting step; fails the claim closed), the *`.git` history* and *Reachability* opt-ins,
  then *Apply* (one result line per step, closed by the final `claimed` ✓ — **only** when the steps
  that grant access actually applied; see below). `-y/--yes` pre-answers
  only the claim's own default-NO proceed prompt ("Apply the pending steps above IN PLACE?") — the
  launch wrapper passes it for a delegated claim after taking its own confirmation, so the same
  decision is not asked twice; the scoped opt-ins (secret lockdown, `.git` history, ancestor
  traversal) still ask on their own terms (see [messaging](messaging.rule.md) for the
  prompt/pre-answer doctrine).
- `--project-create <path>` — create a **new** project directory and claim it: one `mkdir`, an
  empty `git init`, a `README.md` naming the directory, then `cmd_project_claim` unchanged on the
  result (one implementation of what claiming means, not a second). Every filesystem step goes
  through the `run_as_owner` seam below, so a create under `--for` produces a **target-owned** tree
  — which is not tidiness: a tree born owned by the invoker is one the claim then refuses (the
  owner rule under *Two project models*).

  Two refusals define the verb, and both exist so that a create is never a claim in disguise. A
  path that **already exists** is refused naming `--project-claim`: the operation that grants an
  agent access to an existing tree must not be reachable by a typo, and a half-finished create is
  recovered with a claim rather than a re-run. A **parent that does not exist** is refused rather
  than created — only the final component is ever made, so a mistyped path surfaces instead of
  becoming a manufactured tree with a claimed project inside it, and the question of what to clean
  up after a mid-way failure does not arise. `<path>` is required and has no cwd default, since the
  cwd always exists. A reachability pre-flight refuses a location the sandbox account could never
  enter, before anything is created, and names an alternative only after checking that one on this
  host (`--sandbox-create` is deliberately *not* named here: it clones an existing repository, and
  this verb's subject is a project that does not exist yet).

  **It takes no options and asks no confirmation.** Its tree is empty by construction, which
  answers three of the claim's questions outright, so `cmd_project_claim` infers them instead of
  asking — gated on `tree_is_pristine`, which the claim re-derives itself (no file outside `.git`
  but `README.md`, and a repository with no commits) rather than trusting the caller's
  `CLAIM_FRESH_TREE` hint, since what it gates is the secret scan. The proceed confirm and the
  warnings it authorizes are **not shown**: every sentence in them ("MODIFIES group, permissions
  and ACLs throughout this tree", "NOT reversible", "Back up first") is false for a directory that
  did not exist a moment ago, and a warning that is routinely untrue is what teaches an operator
  to click through the ones that are not. The **secret gate** is skipped: its job is to find
  secret-named files before access is granted, a tree whose only file is the README this command
  wrote provably has none, and `ai-tools-lockdown` carries no NOPASSWD rule — so the scan costs a
  sudo *password* prompt to search a directory the tool itself just made. The **`.git` history**
  question is inferred to yes: it asks about exposing history, a repository with no commits has
  none, and normalizing is what keeps the operator's own later commits readable by the agent, so
  asking would offer a choice between one real option and one that costs something for nothing.
  The traverse grant still asks — it widens access *above* the project, on directories that do
  exist and do have contents.

  **Nothing it seeds is left owner-only, whatever the host umask.** A new directory, `git init`'s
  `.git`, and the `README.md` are all born under the caller's umask, so on an `077` host they come
  out `0700`/`0600` — and an owner-only path is one `ai-tools-setgid` and `ai-tools-setfacl` honour
  as the operator's standing **seal** and skip, taking a directory's subtree with it. A create that
  inherited that would register a project whose README the agent cannot read and whose `.git` it
  cannot use, having just reported that it normalized both. So the directory is made `mkdir -m
  0750`, the README `chmod 0640`, and `.git` opened with `chmod -R g+rX` — group read and traverse
  only, since write comes from the claim's ACL exactly as it does for the work tree. `0750`/`0640`
  rather than `0770`/`0660` because group write here would widen the tree to the *operator's*
  primary group, shared on some hosts, for no gain; they are also the modes an unclaim normalizes
  back to. This is **not** a prompt: the seal is a statement about a path an operator restricted
  deliberately, while a umask is a default for every new file that carries no intent about a
  directory created a moment ago by a command whose purpose is to give the agent somewhere to work.
  Where the umask *would* have sealed it, the create says so in a line rather than asking.
- `--project-remove [path]` — unclaim a project **and delete its directory**; `--project-unclaim`
  stays the non-destructive reversal its refusals point at. Detail below under *Remove*.
- `--project-unclaim [path]` — unclaim a real project
  (directory left on disk): revert the label, drop both registries, and (default-yes
  confirm) hand the tree's files back to a target group with the agent's write access
  revoked, via `ai-tools-unclaim`. The target is classified against `allowed-projects`
  first, and a protected system directory is refused up front — see *Unclaim* below for
  the classification and the `--force` gate. Options are in `ai-tools(1)`.
- `--project-disable [path]` / `--project-enable [path]` — park a claimed project and restore it,
  by putting a `!` on its `allowed-projects` line and taking it off again, **in place**. Detail
  below under *Enabled, disabled, absent*.
- `--sandbox-create [path]` — shallow-clone a repo into the sandbox area **privately**
  (`umask 077`), lock down tip-commit secrets, and only past that gate grant the agent
  access and register the clone; fail-closed otherwise, resumable by re-running on the
  clone path (see *Sandbox clone* below).
- `--sandbox-push [path]` / `--sandbox-remove [path]` — push the clone's commits to its
  branch / remove the clone and unregister it. Both gate the target through
  `require_sandbox_clone`: it must be a **real clone** — a direct child of `SANDBOX_ROOT`
  (exactly one level deep, so never the shared area root and never a nested or system path)
  that is a git worktree, and it passes the protected-paths backstop. This scopes
  `--sandbox-remove`'s `rm -rf` to one recognized clone; a stray non-git directory is refused
  ("remove it by hand"). `--sandbox-create` scopes its own destination
  (`<name>` with no `/`, under `SANDBOX_ROOT`), so it needs no such guard.
- `--lockdown [path]` — wrapper over `ai-tools-lockdown` (see
  [secret-handling](secret-handling.rule.md)). Refuses a path outside every claimed project
  up front (`covered_by_project`, before the sudo prompt), the same front-line the helper's
  own `_is_allowed` enforces.
- `--reclaim [--full] [path]` — hand agent-written files under the project back to the
  operator via `ai-tools-reclaim` (which walks the tree and delegates per-path to
  `ai-tools-chown`, the same boundary the handback uses). Refuses a path outside every claimed
  project up front (`covered_by_project`), so it never runs a silent no-op; `ai-tools-reclaim`
  additionally reports "nothing to reclaim" for a direct `sudo` call past the CLI. Reclaims the
  `.git` tree the per-session sweeps skip; the ownership companion to the `user:<operator>` ACL,
  run on demand before an ACL-unaware backup so ownership (not the ACL) carries the operator's
  access into the copy. `--full` includes the skipped heavy trees (`node_modules`, `.venv`, …). See
  [ownership-and-hooks](ownership-and-hooks.rule.md).
- `--relabel` — restore `ai_tools_exec_t` on every enabled agent's entrypoint after a Node
  upgrade, via `ai-tools-relabel-agent`. The manual counterpart to the automatic post-upgrade
  relabel the `nvm-update` timer runs (see [updater](updater.rule.md)); for an out-of-band
  upgrade or if the timer's relabel failed and `ai-tools-run` is fail-closing on the launch.
  **The verb reconciles the entrypoint, of which the label is one half.** It first verifies each
  agent's entrypoint against the checksum its vendor signed and pins the result — the half that also
  runs on a DAC-only host, and the operator-facing way to pin an entrypoint the watcher was offline
  for. That step, its three outcomes, and why it is not a command of its own are in
  [updater](updater.rule.md).

  It then applies each agent's **declared** `entrypoint_fcontext` pattern and reconciles the result
  against the entrypoint that agent's launcher symlink actually resolves to — the inode the launch
  preflight checks. An entrypoint that is installed where the declaration does not reach exits
  non-zero naming that cause, so this command never reports success on a host whose next launch
  will fail closed. See [agent-claude-code](agent-claude-code.rule.md) for the reconciliation and
  what each verdict looks like to an operator.
- `--providers` — read-only report of the installed agents and integrations, which of them a
  session gets, and why. It resolves through `providers.lib.sh` (see
  [providers](providers.rule.md)) rather than re-reading `operator.conf`, so the report and the
  launch agree by construction: the per-kind gating line comes from `ai_tools_provider_gate`
  (`allowlist` / `baseline` / `untrusted`), the enabled set from the same
  `ai_tools_enabled_{agents,integrations}` the toolchain and `ai-tools-run` use, and the installed
  set from the manifest directory listing — so a manifest the resolver refuses shows as disabled.
  The resolvers' refusals, which at launch reach only the terminal and journald, are captured from
  their stderr and reported in a closing block. On a host where SELinux is not `Disabled` it adds a
  **SELinux policy groups** section: the core module's load state and every loaded optional group,
  read unprivileged via `semodule -l`, keyed off the shared `selinux-groups.lib.sh` registry. The
  whole section is **omitted** when that list is not readable unprivileged (common — the policy store
  is root-only on many hosts): every line it prints needs the module list, so a section that could
  only say "cannot read" is not shown at all (inspect groups with
  `sudo ai-tools-admin selinux list-groups`). When the `dotnet` integration is enabled under **Enforcing** it
  warns of the two disjoint policy groups a full .NET workflow wants but that are not loaded:
  `tmpmap` (restore/build mmap of `/tmp`, `EACCES` without it) and `apphost` (executable/host
  projects — `dotnet run`, ASP.NET Core, `xunit.v3` — whose memfd exec is denied without it), each
  with its own enable command: `ai-tools-admin selinux enable-group tmpmap` for the stable one, the
  source `install-selinux.sh enable-group apphost` for the experimental one. These are the
  dependencies [providers](providers.rule.md) documents, surfaced where the operator checks status.
- `--audit [--since <when>]` — report what has refused, been rejected, been stranded, or been
  flagged since a given time, through the `ai-tools-audit` root helper (`sudo`, no NOPASSWD).
  The detections it reports already existed and were already recorded; what they lacked was a
  reader, and a detection nobody reads is decoration. The verb is the lightest thing that
  qualifies as one — not an alerting stack, one command with a consumer.

  **It invents no detection and matches no per-case wording.** The root-only file sink already
  encodes severity in its line format (`<ts> <LEVEL> [<pid>] <msg>`), so a finding is a line at
  `NOTICE` or above. `NOTICE` is in scope deliberately: `ai-tools-chown` records a breached
  secret at that level, and a leaked credential is the most actionable thing the command can
  surface. Nothing drifts — a helper that adds a warning is reported the day it ships.

  **Two sources, not equal, and the report says so.** `/var/log/ai-tools/*.log` is `700
  root:root`, root writers only, so the sandbox account can neither read nor append to it: those
  lines are **evidence**. Launch refusals are the exception — `ai-tools-run` runs *as* the
  sandbox account and reaches only journald, under a tag whose legitimate writer is that same
  account — so they are shown in a section of their own as the session's own account of itself,
  to reconcile against the first rather than to rely on alone (see [logging](logging.rule.md)).
  This is the split that keeps an agent-writable trail from being presented as proof.

  **It reports events, never current state.** Each line is something that *happened* between
  two points in time; a condition recorded here may have been resolved since. That distinction is
  load-bearing and the report states it, because the failure mode is specific and easy: a dated
  `ERROR` read as a standing fault sends an operator to fix something already fixed, and erodes
  trust in the trail on the first false alarm. Confirming what is true *now* is `--status`'s job
  (and `--relabel`'s), and the report closes by naming them rather than implying it answered that
  question itself. The command deliberately does **not** re-verify a finding: knowing how to
  re-check each condition is exactly the per-detection knowledge it refuses to carry.

  **Repeats collapse, and severity leads.** A recurring condition writes one line per
  occurrence, so an uncollapsed report buries the finding that needs acting on under one already
  understood — the same reason `INFO` is out of scope. Findings are grouped by their message with
  digit runs normalized, so occurrences differing only in a pid or a count fold into one line
  carrying the number of times it happened and the most recent example in full; nothing is
  hidden, since the count states what was folded. Ordering is severity first, recency second —
  the two questions actually being asked: what is worst, and is it still happening.

  Exits **non-zero when anything is reported**, so it runs unattended from cron or a login
  banner without parsing its output — the same contract `--status` offers. A `--since` value
  `date(1)` cannot parse is refused rather than treated as "everything", so a typo does not
  silently become a reassuring wall of old findings.
- `--stop` — terminate every running agent session and everything it spawned, through the
  `ai-tools-stop` root helper, which `%ai-ops` grants NOPASSWD in its bare form (the one rule in
  the drop-in whose passwordlessness is its purpose: an unattended detector cannot answer a prompt
  — [docs/session-stop.md](../../docs/session-stop.md)). The only verb that acts on a session
  **already running**; every other control here changes what the *next* launch gets. It is **not**
  the session-lifecycle command — `/exit` inside a session is, and it lets the session run its own
  `SessionEnd` handback. The CLI half is deliberately thin — option grammar only — because every
  remaining decision is a security decision that must not be made twice in two places.

  Four properties a contributor has to hold on to; the reasoning for each is in
  **[docs/session-stop.md](../../docs/session-stop.md)**, which is this component's single source
  of truth:

  - **Sessions are found and killed by cgroup**, never by process tree, and liveness is read from
    the kernel. systemd supplies one thing only — a unit's `WorkingDirectory` — and that is
    **display**: it labels a row and names a `--reclaim`, and selects nothing. The report's split
    between agent sessions and the account's own plumbing (its user manager, dbus, login session
    scopes) is display in that same sense and carries the same caveat — the class comes from a unit
    name, which inside a delegated subtree is the delegatee's to choose. It splits the two counts,
    orders the table and decides which rows get a `--reclaim`; it selects nothing, and both classes
    are killed identically.
  - **It takes no target and no authorization input.** There is no per-project form, because every
    way to attribute a session to a project is written by the account being stopped. A path is
    **refused (exit 2), not ignored** — which is also what keeps targeted stopping addable later
    without changing what an existing command line means. `--all` is accepted and inert.
  - **Nothing is exempt, including the account's own `systemd --user` and its `init.scope`.** An
    exemption is a cgroup a session can move into on a DAC-only host. The manager is **restarted
    afterwards** (`restore_user_manager`), as a step that runs after verification and is reported
    on its own — it never changes what the command says about the stop. One consequence to keep:
    a **rerun is therefore not silent**, since the restored manager is back inside the swept slice.
    The command is idempotent in *end state*, not in what it reports, and buying a silent rerun
    would cost either an exemption or a name-decided sweep.
  - **Two project conventions are inverted here**, both because the safe direction for this one
    component is *act*: the confirmation defaults YES ([messaging](messaging.rule.md)), and no
    library is required nor `set -e` used ([logging](logging.rule.md)). No project library is
    load-bearing at all: with no target to vet or authorize, `safe-paths.lib.sh` and
    `operator.lib.sh` are not loaded ([safe-paths](safe-paths.rule.md)). The second inversion is
    about *abandonment*, not about one shell option — `set -u` is on, and it ends a run just as
    abruptly, so a value a caller may not have passed is defaulted where it is read rather than
    left to abort a stop that was already asked for.

  A stop cannot run the agent's `SessionEnd` hook, so the in-flight turn's writes may still be
  sandbox-owned and the clean-exit marker is left for the next `SessionStart`
  ([ownership-and-hooks](ownership-and-hooks.rule.md)); the command names the `--reclaim` per
  project it terminated. On a shared host one operator's stop ends every operator's sessions — a
  stated consequence, not an oversight, since `--all` never took an authorization input either.
  Everything is recorded to `stop.log` and journald, including which path gave consent and which
  pass ended each session. Exit codes are in `ai-tools(1)`.
- `--status` — read-only health report: the installed `ai-tools` version, whether the toolchain is
  provisioned, then each managed systemd unit (`ai-tools-handback.socket`, `ai-tools-relabel.path`
  and the `ai-tools-relabel.service` it triggers, and the sandbox account's `nvm-update.timer` and
  `nvm-update.service`) as OK / SKIPPED / STALE /
  DOWN / FAILED /
  not-installed, with the consequence and the exact remedy for anything broken, and a closing
  **More** block that points at the sibling
  reports (`--providers`, `--list`, `--help`) without repeating their detail — so it reads as a hub. It resolves through `services.lib.sh` — the **same registry** the launch
  wrapper's pre-launch health warning reads (`claude.sh`, see [launch](launch.rule.md)) — so the
  status view and the launch warning never disagree on which units matter or how to fix one.
  `--status` is the one command that
  **bypasses the bootstrap gate** (below): a diagnostic must run when things may be broken, so it
  reports the unprovisioned state rather than being blocked by it.

  A unit in the sandbox account's own `systemd --user` manager is not queryable from the operator's
  session at all, so its state comes from a **last-run stamp** it publishes where the operator can
  read it (`nvm-update.service`, see [updater](updater.rule.md)) and stays `?` where it publishes
  none. One live fact about that manager *is* readable — whether the unit **file** is installed —
  and it is checked first, so a unit an optional package never shipped (the `nvm-update` pair
  without the nodejs integration) reads as not-installed rather than as one this host cannot see,
  and a stamp an uninstall left behind cannot make a gone unit look present. A run that **correctly
did nothing** reads `SKIPPED` with its reason (the updater against an unreachable registry, see
[updater](updater.rule.md)): it is dim rather than yellow and does not count as a fault, so a
disconnected laptop does not make `--status` exit non-zero every night — while the same stamp still
ages into `STALE` if the condition persists, which is where a toolchain that has genuinely stopped
advancing surfaces. The account's own
  `~/.config/systemd/user` is not searched: it sits inside a home the operator cannot traverse, and
  every unit the registry names ships to the system-wide user-unit directory. A stamped unit's OK carries the time of that run rather than implying it is running now,
  and a `FAILED` carries the run's exit code. The `?` line is not a problem report — it says only
  that this vantage point cannot tell — so it stays a single line naming the one command that can,
  and the multi-command diagnostic block is reserved for a unit actually reported broken.

  **A stamp is read for two properties, and one stamp can serve two units.** `RESULT` answers *did
  the last run succeed*; its **age** answers *are runs still happening* — a distinct question a
  `RESULT` cannot express, since a schedule that quietly stops firing leaves every recorded run
  successful and would otherwise read as a permanent, increasingly wrong OK. Past the record's
  `max_age` (48h for `nvm-update`, twice its daily `OnCalendar`) the unit reports **`STALE`**. The
  registry's `stamp_mode` field selects which property a record reads: `result` for the unit that
  ran, `fired` for the one that triggered it — so `nvm-update.timer` derives a verdict of its own
  from the *same* stamp on recency alone (a systemd-started run, successful or not, proves the
  timer fired), instead of the `?` it could otherwise only report. A failing service therefore does
  not also condemn the working schedule that started it. Only a systemd-started run counts, read
  from the stamp's `TRIGGER` (see [updater](updater.rule.md)): a run the operator did by hand is no
  evidence about a schedule, and counting one would both report a dead timer as healthy and
  suppress the staleness that is the only way a stopped schedule shows up. An unknown age never
  manufactures staleness either: no `max_age`, an unparseable date, or a stamp dated in the future
  all decline the judgment.

  Times render **relative first** (`last run 3 days ago`), coarsening with distance, because the
  age is what the operator acts on. Every unit line feeds one predicate,
  `ai_tools_service_needs_attention` (`down`/`failed`/`stale`, never `unknown`), which is
  both what the scanner collects and what `--status`'s **exit status** reports — non-zero when
  anything is broken, so the command is usable from a monitor or cron without parsing its output.
  An unqueryable unit is not a fault and does not alarm.

  **Both halves of the entrypoint reconciliation are reported, from the records it writes.** Neither
  the binary nor its label can be inspected from this account, so each half leaves a root-owned
  record where the operator can read it. The *pin* is the verification half: `--status` reports one
  line per agent that declares a release
  manifest: `VERIFIED` with the pinned version and how long ago, or `unverified`, or `?` when this
  account cannot read the pin at all (`--status` stays open to a non-operator, who cannot traverse
  the state directory). It reads through the **same stamp accessors** as the unit records — the pin
  is written in that grammar — so the charset clamp and the age calculation have one implementation.
  An agent whose package declares no release manifest is omitted rather than reported as perpetually
  unverified. Unpinned counts toward the **exit status only where the operator required verification**
  (`AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY`), since that is exactly when it will refuse a launch;
  everywhere else it is a legitimate state — an air-gapped host, a release the vendor published no
  manifest for — and must not alarm, the same rule the unqueryable units follow.

  The **labelling** is reported beneath it, from a second record the same helper writes
  (`state/entrypoint-label.d/<agent>`, see [updater](updater.rule.md)): `labelled` with its age,
  `NOT LABELLED` with the class of failure, `not labelled` for a host with nothing to label (the
  SELinux layer inactive, or an agent the toolchain has not provisioned), or `?` where no
  reconciliation has been recorded. Only a recorded failure counts toward the exit status, since it
  is the one state that stops the next launch.

  **The two halves are reported together because they fail independently.** Verification and
  labelling run in the same helper, in that order, and the first can succeed while the second does
  not — leaving the pin line freshly green, written by the very run whose labelling failed. Reported
  alone it reads as an all-clear rather than as half a story.

  What is reported is the last run's **outcome**, not the live label. Reading an entrypoint's actual
  context means `stat`ing a file under `/opt/ai-tools/.nvm`, which `ai-tools-bootstrap` creates
  `0750 SANDBOX_USER:SANDBOX_GROUP` — the operator is not in that group and cannot traverse it, and
  `matchpathcon` computes only what a label *should* be, never what it is. So the record carries the
  same caveat as the rest of this report: it is an event, and `ai-tools --relabel` is what confirms
  the labels now. A mislabel that arises after it still stops the next launch with the fault and the
  command that clears it.

  **The unit that does the labelling is reported too, and it is not the same signal.**
  `ai-tools-relabel.service` is in the registry beside the `.path` that triggers it, because a
  healthy watcher says only that a run *started* — on the upgrade that motivated both records, the
  watcher was `OK` and the relabel it fired had failed. A `Type=oneshot` service is inactive
  whenever it is healthy, so it is judged by the result of its last run rather than by `is-active`
  (see `services.lib.sh`), and its remedy is `systemctl start ai-tools-relabel.service`: that
  re-runs the work *and* clears the recorded failure the report reads, which `ai-tools --relabel`
  does not. The two records answer different questions — the label record covers every caller
  (an rpm `%post`, the watcher, `--relabel`), while the unit covers a watcher run that failed before
  it reached any labelling at all.

  Every command for such a unit goes through root, and the CLI composes them rather than the
  registry storing them: each names the sandbox **account**, and `services.lib.sh` is deployed with
  no `@SANDBOX_USER@` substitution. Status and restart use the **machine transport**
  (`sudo systemctl --user -M ai-tools@.host …`), which reaches that manager over the system bus
  where root is authorized — a plain `sudo -u ai-tools systemctl --user` gets its own bus refused
  even when the manager is healthy (the reason the tests' `sandbox_systemctl` prefers it). The
  journal query cannot use either: `journalctl --user-unit` as root reads **root's** user units, so
  the unit is selected by the journal fields instead
  (`sudo journalctl _SYSTEMD_USER_UNIT=<unit> _UID=<sandbox uid>`), which ANDs across the two field
  names and catches both the unit's own output and the `systemd-cat` lines its script emits.
- `--list` — report every allowlist entry (project / sandbox / exclude / unusable) with its git
  `safe.directory` status, then a **Suggested cleanup** section flagging inconsistent
  hand-edited entries, each with a copy-paste remediation carrying the full absolute path (an
  anchored `sed` line-deletion, plus `ai-tools-safedir --remove` / `ai-tools-relabel --remove`
  where they apply, or `ai-tools --project-claim` to finish a partial claim). It flags, in both
  directions: a protected system path the tools refuse to touch; a stale allow entry or a stale
  non-glob `!` exclusion whose path no longer exists; a **glob in an allow line** (unusable —
  the launch wrapper realpath's allow entries, so a glob there resolves to nothing and is inert;
  globs belong only on `!` lines); a project listed but not fully claimed; and — the reverse
  direction — a git `safe.directory` with **no** allowlist entry (orphaned, e.g. a hand-deleted
  line), skipping the deliberately-registered control-plane paths the protected-paths backstop
  already covers. Entry membership is decided through the shared grammar matcher in
  `conf.lib.sh` (`ai_tools_conf_allowlist_has_entry`), realpath-normalized, so an entry carrying
  an end-of-line comment or quotes — or reached by a symlink — reconciles the same as the launch
  gate reads it, rather than reading as unlisted. It reuses existing predicates and verbs only
  (no recovery machinery), stays **read-only** (every fix is an emitted command, never an
  in-place rewrite), and closes with a compact **Maintenance** pointer to the per-project verbs.
  Informational, so it stays open to a non-operator.
- `--version` (the deploy-stamped package version; `dev` from a raw source tree), `--help`.
- `--for <operator>` — a **modifier**, not a command: run the verb on behalf of another enrolled
  operator (see *Acting for another operator* below).

The CLI ships a man page, `ai-tools(1)`
(`src/usr/local/share/man/man1/ai-tools.1` → `/usr/local/share/man/man1/`, deployed by
`install.sh` and the RPM with the same `@AI_TOOLS_VERSION@` substitution as the CLI).
It is hand-written troff — the CLI cannot be executed at package-build time for
`help2man` (the bootstrap gate fail-closes on an unprovisioned host) — and
The two are **not** copies of each other: `usage()` is orientation — the verbs, one line each,
and the three cross-verb flags — while the page is the reference for every per-verb option, which
is why a per-verb option lives under its verb there rather than in a flat list that would separate
`--branch` or `--dir` from the only command they mean anything for. `tests/unit/man.sh` keeps them
honest with three checks in place of the old set-equality: the **verb** sets match in both
directions, every option `usage()` names is documented in the page, and every option the page
documents is one a CLI **parser** accepts. That last direction replaces "the help must name it
too", which made moving an option out of the help fail as a stale man entry; what actually goes
stale is an option outliving its parser.

## Acting for another operator (`--for`)

`--for <operator>` performs a command **on behalf of** another enrolled operator: the allowlist
entry lands in *their* `~/.config/ai-tools/allowed-projects`, so `ai-tools-setfacl` grants
`user:<them>`, the ownership handback restores to them, and their agent's launch gate covers the
path. It exists for a **service account that runs an agent but holds no password**: such an account
cannot authenticate the claim's own no-NOPASSWD root helpers, and a claim performed by a human
would otherwise register the project in the *human's* registry — not the one that account's launch
wrapper reads. A human operator claims once with `--for`, and that account's session then finds the
project fully claimed and never reaches a password prompt.

The flag is separated from the verb's own arguments **before dispatch**, so every command reads one
already-decided owner rather than each parsing it. Two globals carry the result: `OWNER_USER` /
`OWNER_GROUP` name the operator the run acts for (the target, or the invoker), and every message
that names the owner a file ends up with — and every scan that matches on that owner
(`acl_drift_scan`, `grantable_ancestor`, the hand-back prompt's default) — reads them rather than
the invoking user. What a *root helper's* walk treats as the operator is still resolved per path
from that path's allowlist coverage (`operator.lib.sh`), never from either global.

**The target's registry is unreadable to the invoker.** An allowlist is `0600` inside a `0700`
`.config/ai-tools` (seeded that way by `ai-tools-admin`), so one operator cannot read another's at
all — and every decision the CLI makes from it (is the path listed, which `!` exclusions apply, what
`--list` reports) would read an unreadable file as an empty one. A `--for` run therefore takes a
root-side **snapshot** through `ai-tools-allowlist --print` into a `0600` temp file removed on exit,
and points `ALLOWLIST` at it for reads. The snapshot is read-only input for that run: mutations go
back through the helper, which re-reads the real file and applies its own idempotency, and
`reg_allow`/`unreg_allow` refresh the snapshot after theirs — so a stale copy is never what a write
is based on.

`require_for_target` gates the run, after `require_operator` (acting for another operator is itself
an operator action, so the invoker must be enrolled before the target is looked up). It accepts the
flag only on the verbs whose whole effect is decided by *which* operator's allowlist covers the
path — `--project-claim`/`-create`, `--project-unclaim`/`-remove`, `--lockdown`, `--reclaim`,
`--list` — and **refuses it elsewhere rather than ignoring it**: a `--sandbox-create --for` that
silently cloned as the invoker would leave the tree owned by the wrong operator with nothing to
show the flag was disregarded. The target must be **enrolled in `OPERATORS`**, since the ownership
helpers resolve a path's owner over that list and an entry written for an unenrolled name would be
a launch gate nothing can act on; the sandbox account and `root` are refused outright.

`--for` is **refused with `--project-unclaim --force`**. That mode reaches a tree no allowlist
names, so `ai-tools-unclaim` cannot resolve an owner from an entry and binds the walk to the
**invoking uid** instead — the guard that stops one operator rewriting another's files. Honouring
`--for` there would have the CLI name one operator while the helper acted as another.

**Every refusal in the gate precedes the snapshot**, which is a `--for` run's first `sudo`: a
command that is going to be refused must not first prompt for a password. That ordering is what
places the `--force` check in the gate — reading the verb's own arguments — rather than where
`--force` is parsed in `cmd_project_unclaim`, which runs after the gate and so would prompt first.
The target's group is likewise resolved only *after* enrollment is confirmed, so a name that is
neither an operator nor a user on this host is refused with the enrolment command rather than a
`getent` failure naming the wrong problem.

Sandbox clones stay invoker-only: `--sandbox-create` clones as the invoking user with that user's
git credentials, so pointing it at another owner is more than a registry redirect and is not
attempted here.

### The runas seam, and why it needs a grant `--for` alone does not

Most `--for` verbs redirect a **registry**: the entry lands in the target's allowlist and the root
helpers resolve the owner from it. Two do not. `--project-create` and `--project-remove` write the
**filesystem** as an owner — a tree the target must own for the claim's helpers to act on it, and a
tree only its owner can delete — so both go through `run_as_owner`, which prefixes `sudo -u
<target> -H` when `--for` is set and runs the command directly otherwise. `reg_reach` uses the same
seam for the traverse ACL, whose ancestors belong to the target on a `--for` run.

`-H` is load-bearing rather than tidiness: without it (and without sudoers' `always_set_home`) sudo
leaves `HOME` pointing at the **invoker's** home, so the `git init` inside a create would configure
the target's repository from the invoker's `~/.gitconfig`.

**It grants nothing new.** `sudo -u <target>` rides the caller's **general** sudo grant — the
separate authority axis [CLAUDE.md](../../CLAUDE.md) names, which nothing here writes or records —
so an operator who reaches it could already act as that account. The sandbox account holds no sudo
rule and runs under `PR_SET_NO_NEW_PRIVS`, which drops sudo's SUID bit, so it reaches none of it.

It is nonetheless a **distinct sudoers question** from the helper grants `require_sudo_access`
probes: a host can grant every `ai-tools-*` helper and still restrict `Runas` to root.
`require_runas_target` asks it up front — probing each command the run will actually execute, not
one representative, for the reason that gate gives — because the alternative is failing at the
worst moment: a create after making the directory and before claiming it, a remove after
unregistering the project and before deleting it. Like every refusal in this family it precedes the
`--for` snapshot, which is the run's first sudo.

**What this widens, stated plainly.** An allowlist is an operator's own launch gate, and `--for`
lets one operator write into another's. That sits inside the model's standing "`ai-ops` operators
are trusted" boundary — an operator could already claim the project themselves — but it is a real
change in who curates a gate, so every mutation is logged with both the caller and the target. The
sandbox account reaches none of it: the helper is `750 root:root` inside a `750 root:root`
directory and the account holds no sudo rule.

## Enabled, disabled, absent — the three states of an entry

`allowed-projects` is a document the operator edits, and prefixing a line with `!` to take a
project out of service is a workflow that predates any verb for it. The file therefore has three
states per path, not two, and the CLI names all three (`ai_tools_conf_allowlist_state`):

| state | the file says | what it means |
|---|---|---|
| `listed` | an allow line names the path | sessions may start there |
| `disabled` | a `!` line names it | no session starts there; the entry, the permissions and the label are all still in place |
| `absent` | neither | not a project |

**An exclusion outranks an allow line for the same path**, exactly as it does at the launch gate:
with both present nothing can start there, so `disabled` is the only honest answer. Reading only
`listed`/`absent` is what made a parked project indistinguishable from an unclaimed one — a claim
appended a duplicate over an exclusion that still won and reported success, and every per-project
verb refused a parked project as "not a claimed project".

**Entry state is not reachability.** A path can hold a clean allow line and still be unreachable,
because an *ancestor* is parked or a glob exclusion matches it — neither of which names the path.
That is `covered_by_project`'s question, and the two are reported apart: a verb that changes an
entry says what the entry now is, and names the other line when one still blocks the path
(`blocking_exclusion`). Reporting a project "enabled" that no session can enter is the misreport
this split exists to prevent.

### The two verbs

`--project-disable` puts the `!` on; `--project-enable` takes it off. Both edit **the operator's
own line, in place** — position, indentation and end-of-line comment survive — which is their
reason to exist rather than being an add/remove pair: an ordered, commented allowlist comes back
exactly as it was. Both are **registry-only**: group, ACLs, setgid and the SELinux label are
untouched, so re-enabling grants nothing that was not already granted and neither runs the secret
gate. Neither invents an entry — a path the file does not name is refused, naming
`--project-claim`, because registering a project is a claim and a claim scans for secrets first.

What disabling costs is everything downstream of the allowlist, and the verb says so: the root
helpers resolve a path's owner through the same allow/exclude matcher, so while a project is
parked `ai-tools-unclaim`, `-chown`, `-setfacl` and `-setgid` resolve no owner and **exit 0 having
done nothing**, and `ai-tools-lockdown` refuses. The ownership handback therefore stops restoring
files written under it — the consequence to know before parking a project a session is still
writing to.

On a **parked** target the unclaim asks to lift the exclusion first, because the hand-back cannot
run under one. Declining does not abort: the registry reversal still applies — the entry dropped,
or parked under `--keep-entry` — and only the hand-back is given up, reported as not having run
with the `--project-enable` + `--reclaim --full` pair that completes it, and a non-zero exit. That
is the same treatment a hand-back that was wanted and failed already gets.

`--project-unclaim --keep-entry` is the same edit at the end of an unclaim: the files are handed
back as usual, then the line is parked instead of deleted. It serves the release cycle — unclaim
for clean permissions before a release, claim again for the next stage — without the project
losing its place in the file.

### Why no verb writes an ambiguous `!`

A `!` line means one of two things, and **after the edit they are the same text**: a *parked
project*, or a *carve-out* — a subtree an operator withheld from an enclosing project. Nested
claimed projects are a supported shape, so "an exclusion inside a listed project is a carve-out"
is not sound on its own. The ambiguity is removed by refusing to create it, in both directions:

- `--project-disable` (and `--keep-entry`) **refuses a project nested inside another listed
  project**, naming the two alternatives — unclaim the nested project, or park the one above it.
- `--project-enable` therefore **refuses every exclusion inside a listed project** as the
  carve-out it must be, since no verb wrote it. Lifting one is the only registry edit here that
  *widens* what the agent reaches, so it is left to the editor it was written in.

Neither refusal touches the hand-edited workflow: an operator may still park a nested project
themselves, and delete the `!` themselves. The tool declines to guess, and declines toward less
access. The full state model, the cases, and the alternatives rejected (a marker comment, a
prompt, a structured `projects.*` registry) are in the design note that accompanies this work.

### One implementation of a registry change

Three components write this file — the CLI (the operator's own), `ai-tools-allowlist` (another
operator's, for `--for`), `install.sh` (de-registering its own checkout) — and all three call the
same functions in `conf.lib.sh`: `_state`, `_add`, `_remove`, `_enable`, `_disable`. Each verifies
by re-reading the file and separates *applied* (0) from *could not write* (1) from *does not apply
from this state* (2). Two rules live there rather than in any caller, so no writer can skip them:
`_add` **refuses** a disabled path (appending under a winning `!` is the duplicate-pair bug), and
`_remove` takes **both** line kinds, so de-registering a parked project leaves no `!` behind to
park whatever is claimed at that path next. `_enable` additionally collapses an existing duplicate
pair to one live entry, in the earliest position it held.

Before this, the same edit existed three times — an append here, a hand-escaped `sed -i` there, a
read-transform-rename in the third, each with its own idea of what a match is. For a file that is
the launch gate, a writer that matches lines differently from the reader is a project that stays
reachable after a "removal".

## Two project models

**Claim in place** (`--project-claim`) registers an existing working tree where it lives.
The confined agent (`ai_tools_t`) reaches it only if the tree carries the
`ai_tools_project_t` SELinux label, so claim applies that label via the root helper
`ai-tools-relabel`, and `--project-unclaim` reverts it. The label primitive (semanage
fcontext + restorecon) lives in the shared `relabel.lib.sh`, sourced by both
`ai-tools-relabel` and `install-selinux.sh`, so the CLI and the policy installer apply one
implementation. The relabel is **forced** (`restorecon -FR`): a file created in a labelled
directory inherits `ai_tools_project_t` on its own, but a file brought in carrying an explicit
foreign context — a context-preserving copy (`cp -a`, `tar --selinux`) of a system path, or any
customizable type — is one a plain `restorecon` preserves, and only `-F` resets it to the project
type. `restorecon` writes only a file whose context differs, so forcing is idempotent on an
already-labelled tree (a walk, no writes) and the installer's per-install sweep re-asserts the
label cheaply while still correcting such drift — the state the confined agent must be able to
read, or its startup workspace walk denies on every foreign-labelled path.
Claim sets group `SANDBOX_GROUP` + the setgid bit on the project's directories
(via `ai-tools-setgid`, so the agent traverses the tree and new files inherit the group), applies
the group-permission ACL for existing files (via `ai-tools-setfacl`), and pins repo-local
`core.filemode=true`.
A separate default-yes prompt offers to normalize the `.git` tree (`ai-tools-setfacl
--with-git`: group `SANDBOX_GROUP` + setgid on its dirs + the same ACL) so the operator's
own commits stay agent-readable — `.git` being the one heavy tree the per-session passes
skip yet both parties write (see [ownership-and-hooks](ownership-and-hooks.rule.md)).
Claim inspects current state and runs only the missing steps, so a re-run is a quiet no-op
and existing projects retrofit the ACL/`filemode`/`.git` normalization on the next claim.
`--project-create` is part of this model rather than a third one: it makes the directory and then
runs the same claim on it.

**The project root must be held by the resolved operator or the sandbox account, and a claim
refuses otherwise.** `ai-tools-setgid` and `ai-tools-setfacl` — the two helpers that grant the
agent its access — act only on those two owners (the *Owner guard* below), while the registries,
the `safe.directory` entry and the SELinux label apply regardless. A tree held by anyone else
therefore took every step that registers a project and none that grants access to one, and the
claim closed with its `✓` over an agent that cannot enter the tree. The commonest route to it is a
claim for someone else — `mkdir ~/proj && ai-tools --project-claim --for svc ~/proj` resolves the
owner to `svc`, so every inode fails the guard. `require_claimable_owner` checks the root before
the first registry write and refuses, naming the `chown` that fixes it; transferring a tree
recursively needs an authority this CLI does not hold, and is deliberately not built (a repair path
would need a privileged helper). The helpers report the same condition from their side: each walk
counts what its owner guard skipped and says so, with the project root called out on its own
([ownership-and-hooks](ownership-and-hooks.rule.md)).

**Remove** (`--project-remove`) deletes the directory as well. Its authorization is an **exact**
`allowed-projects` entry — allow or parked, since a `!` records "not right now" rather than "not
mine", and requiring the operator to re-enable a project first would make a tree they mean to
delete launchable on the way out. A parked one gets its own default-NO confirm naming that state,
ahead of the deletion warning, and both its lines go with the tree. Nothing else authorizes it: there is no `--force` — that flag exists on unclaim to
reach a tree the allowlist does not name, and "delete a tree nothing registered" is an unclaim plus
an `rm` the operator types themselves, where the destructive step is theirs. An ancestor, a path
inside a project, and an unregistered path are each refused with the command that does apply; so is
an exact entry that **contains another claimed project**, which `rm -rf` would take with it and
leave registered, git-trusted and labelled at a path that no longer exists (the check sees only the
registry this run can read, so another operator's nested project is not visible to it).

A read-only **deletability pre-flight**, run as the acting owner, refuses up front when any
directory in the tree is not writable and traversable by them — naming `ai-tools --reclaim --full`
— because the failure a destructive verb must not have is a tree deleted down to the first
directory it could not enter, with no registry entry left to find the remains by. It checks the
project's **parent** separately and first, since `rm -rf <d>` finishes by unlinking `<d>` from the
directory containing it: that needs write and execute *there*, on a directory that is not part of
the project and so is not covered by the walk. Missing it is the worst outcome the verb has — `rm`
descends, deletes every file, and fails only on the top directory, leaving an empty husk that is
already deregistered — and its remedy is not `--reclaim`, the parent never having been the
project's to reclaim, so it is a refusal of its own naming `--project-unclaim` instead. Teardown then
runs **registries first, deletion last**: the label, the `safe.directory` entry and the allowlist
entry go, and only then the tree, so a failed deletion leaves an *unregistered* tree — less access,
not more — where the reverse order would leave a half-deleted one the agent still reaches. The
allowlist step is **fatal** if it cannot complete: that entry is the launch gate, so a removal that
deleted the tree past a failed de-registration would strand exactly the entry this ordering exists
to drop. `unreg_allow` therefore verifies the entry is gone by re-reading the file rather
than trusting `sed`'s exit status, and refuses with the manual line to delete (`sed -i` writes its
temporary file into the allowlist's own directory, so it fails on a config directory the operator
cannot write even when the allowlist itself is writable). The
filesystem hand-back `--project-unclaim` performs is deliberately **not** run: it is a full-tree
`chgrp`/`chmod` pass over files about to be deleted.

It confirms **twice** — a default-NO prompt, then `ai_tools_msg_challenge` for the project's name
([messaging](messaging.rule.md)) — and neither is answered by a run with no terminal, so nothing is
deleted unattended without `-y`; `AI_TOOLS_ASSUME_YES` never answers either, since it only
fast-tracks default-YES questions and the challenge has no default at all. With `-y` a `path`
argument is **required**, so an unattended removal cannot inherit the directory it started in. The
verb's unknown-option refusal deliberately does not enumerate `-y`, unlike the other verbs': a
caller who has just mistyped a flag is not who a both-prompts bypass is for, and it is documented
in `ai-tools(1)` where reaching it is deliberate.
The flow carries no inline `--sandbox-create` cross-references — the launch wrapper's
choice screen and `--help`/docs present the sandbox-clone alternative; the one exception
is the *Reachability* blocked case below, where an in-place claim genuinely cannot work.

**Interior drift.** Root-level state cannot see paths inside a claimed tree that lack the
group/ACL — brought in by rename (which keeps the old group and carries no ACL entries;
creation under the setgid + default-ACL parents inherits both), or sitting under a
skip-listed directory name the claim walks leave alone. A **re-claim whose ownership is
already in place** therefore scans the tree (`acl_drift_scan`, read-only and unprivileged)
for shared-looking paths with a foreign group — owner-only paths (`600`/`700`, e.g.
locked-down secrets) and `!`-excluded subtrees stay unreported as out-of-reach by intent,
the same predicate `ai-tools-setfacl` skips on, so the scan never reports a path the repair
would decline to touch (see [secret-handling](secret-handling.rule.md)).
A first claim (or one with the setgid step still pending) skips the report: its normal
walk repairs the whole tree, and every path would trivially match the predicate. The scan
splits the hits on the shared skip list
(`skip-dirs.lib.sh`, which the CLI sources): repairable hits become a pending step whose
repair (setgid walk + ACL walk) runs only behind the same default-NO confirm and secret gate
as a first claim. The ACL walk (`ai-tools-setfacl`) settles the drift itself: alongside the
ACL it normalizes a drifted path's primary group to `SANDBOX_GROUP` (same predicate as the
scan), so the next claim reports the tree clean instead of re-flagging the same paths.
Hits under skip-listed names get an informational block naming the
remedies that do reach them — narrow the category override in `operator.conf`, list the
path in `SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE` (a source dir sharing a skipped
build-output name), then re-claim; or `ai-tools --reclaim --full` for ownership alone.
Declining plus a `!` exclusion (or `chmod 700`) records an intentional carve-out so it is
not re-reported.

**Sealed directories with a third-party setgid.** A second read-only scan
(`sealed_setgid_scan`) reports the one piece of residue the claim walks decline to remove: a
setgid bit on an owner-only directory whose group is neither `SANDBOX_GROUP` nor the group of
that directory's own owner (see [ownership-and-hooks](ownership-and-hooks.rule.md) for the strip
those walks do perform). The walks cannot ask whether such a bit was deliberate, so they keep it
and the operator decides — which means the claim has to *say* it kept it, in the Review block
before the confirm rather than from a helper's stderr under Apply, where it scrolls past the
decision it informs. The comparison is made **per path against the owner's primary group**, not
against the invoking user's: on a multi-operator host the group the walks treat as legitimate is
the resolved project owner's, so comparing against the invoker's would report a bit the claim goes
on to strip, or stay silent about one it keeps. New files in such a directory are still born in
that third group, so the block names the paths and the `chmod g-s` that clears one.

**A claim that could not apply its root steps does not report success.** `reg_safedir`,
`reg_ownership`, `claim_setfacl` and `claim_relabel` each return non-zero when their helper fails,
the Apply block counts that, and a non-zero count closes the flow with a warning naming what is
still pending and **exit 1** instead of the `claimed` ✓. This is the owner rule at the other end of
the same flow: no ✓ over a project the agent cannot work in. The registries stand either way, and
the claim is idempotent, so a re-run applies exactly what is missing.

**A failed step asks once before attempting the next.** Every step authenticates separately and
**nothing can be pre-authenticated** — a hardened sudoers may set `timestamp_timeout=0`, where a
credential is never cached and every invocation prompts — so a mistyped password costs a full round
of attempts *per step*: nine prompts for one claim, twenty-seven for an unclaim over three nested
projects. `note_root_failure` asks once, default **NO**, which is also the no-terminal answer, and
asks once **per run** rather than per step or per project. The question is genuinely unanswerable
from here — a mistyped password and an absent grant look identical at this point — which is why it
is asked rather than inferred.

That decision covers only which steps are **attempted**; what a partial result means differs by
verb, because the safe direction does:

| verb | on a failed root step | why |
|---|---|---|
| `--project-claim` | stops, reports what is pending, exits 1 | fewer steps applied is *less* access, and a re-run is idempotent |
| `--project-unclaim` | applies the registry reversal **anyway**, then reports — dropping the entry, or parking it under `--keep-entry` | either disposition ends with no session able to start there, so it is what moves to less access; stopping short would leave the project launchable |
| `--project-remove` | deletes **anyway**, notes the cleanup that did not run | the leftovers point at a path that no longer exists; refusing to delete would leave the tree |
| `--sandbox-create` | reports the clone is not git-ready, exits 1 | a clone exists to run git in, and without `safe.directory` the agent's git refuses the tree |

**An unclaim whose hand-back did not run says so, and exits non-zero.** That step is what revokes
the agent's access to the *files*; everything else `unclaim_one` does is registry work, which stops
a session launching there but leaves the tree group-owned by the sandbox account. A bare `✓
unclaimed` over it is the worst misreport in this file — a claim that under-applies leaves the
agent too little access, which is inconvenient, while an unclaim that under-applies leaves it
access the operator has just been told was removed. The batch loop counts such targets and the verb
exits non-zero.

**Reachability.** The confined session runs *as* the sandbox account, so it must be able to
**traverse** the path to the project; a project nested under a directory the account cannot enter
(a private home, `700`) is unreachable, and `ai-tools-run` — which re-checks the project directory as
the agent — refuses it as missing even after a clean claim. Claim closes this with a **default-NO**
prompt that grants a **traverse-only** ACL (`u:SANDBOX_USER:--x` — execute, no read) on each
blocking ancestor, so the account can *enter* a directory to reach the project but never *list* or
*read* it. The grant is scoped by the same owner-guard + [safe-paths](safe-paths.rule.md) backstop
the rest of claim uses: only directories the **operator owns** and that are **not** protected system
directories, and it is **unprivileged** (the operator owns them, so no `sudo`). A blocking ancestor
that is a system directory or owned by someone else is left untouched — there the sandbox clone
(under `/var/opt/ai-tools`, already agent-traversable) is the way in. The grant is idempotent: an
ancestor the account can already traverse (e.g. one carrying the ACL from a prior claim) is skipped.
Detection (`reach_scan`) runs up front so the Review overview announces the opt-in, and the
block runs on the fully-claimed no-op path too — a claimed project can still lose
reachability to a later `chmod 700` above it.

**Unclaim** (`--project-unclaim`) reverts that. The CLI classifies the target against
`allowed-projects` and acts only where something authorizes it:

| target | outcome |
|---|---|
| a listed project | unclaimed |
| an ancestor of listed projects | all of them, outermost-first, behind one default-NO confirm |
| inside a listed project | refused, naming the nearest claimed parent |
| unlisted, carrying the ai-tools fingerprint | reported; acting needs `--force` |
| unlisted, no fingerprint | refused |

`--keep-entry` changes only what becomes of the line at the end (parked, not deleted) and is
refused with `--force`, which reaches a tree no entry names. `--force` **swaps one gate for
another, never removes one**: the helper's allowlist-membership
check is replaced by a per-path residue predicate, so on a tree that was never claimed it changes
nothing, and what it does to a path it *accepts* is identical to a registered unclaim — the
reversal is specified and tested once. It relaxes nothing else (protected paths, owner guard,
hardlink guard, secret/`!` skips), and is refused on a registered project. The CLI's
classification is the front line; `ai-tools-unclaim`'s own gate is the last line, the same
two-layer split as the rest of this section — so the CLI may never be the only thing standing
between a caller and a tree. Mechanism, and why an unlisted tree resolves its owner
differently, live in that helper's header.
For each selected project it removes the SELinux label and both registries — or, under
`--keep-entry`, parks the allowlist line in place instead of deleting it — and (default-yes
confirm) runs `ai-tools-unclaim` to hand the filesystem back — the hand-back running **before**
the allowlist entry is dropped, so the helper still sees the target listed (see the owner/allowlist
guard below).
For every eligible path that helper clears the agent ACL **and** the default ACL
(`setfacl -b`), changes the group owner to a target group (the invoking user's own group by
default; any other user can be named, handing the tree to that user's group), and removes
group write (`660→640`, `770→750`, `400` stays `400`) — additionally clearing the setgid bit
claim added on **directories** (numeric `chmod` cannot, so symbolic `g-s` is used), returning
them to plain perms. The agent loses access via both the group owner and the named ACL entry,
while the new group owner keeps read/traverse. `.git`, skipped by the main walk like the other
heavy trees, is reverted by its own pass — for the same reason claim normalizes it (both
parties write it) — so the unclaim fully revokes git-history access too.

**Hardlinked files are refused, in both modes.** A regular file with more than one name is left
untouched: `chgrp`/`chmod` act on the *inode*, which the second name reaches from outside the
tree, so acting would change a path the pass never authorized — and for the common case,
`git clone --local` (which hardlinks `.git/objects` to the source repo), it would rewrite the
**origin's** objects. This is the one refusal in the project that leaves *more* access than acting
would, since the inode keeps its group and the agent therefore keeps those files after the project
is deregistered. It is accepted rather than resolved — the alternative reaches outside the
authorized tree — and paid for in disclosure: the count is reported to the terminal with what it
leaves behind and the `find … -links +1 -group SANDBOX_GROUP` that lists the files, so the
operator can decide about them deliberately instead of inferring the gap from two counts.

**Owner guard (claim and unclaim).** The root helpers `ai-tools-setgid`, `ai-tools-setfacl`,
and `ai-tools-unclaim` act **only** on paths owned by the projects user or the sandbox
account; a path owned by any third party (root, another developer) is left untouched, on top
of the secret-name and `!`-exclusion skips. `ai-tools-unclaim` additionally refuses a target
that does not resolve **at or under a registered project** (`allowed-projects`) — a silent
no-op, matching `ai-tools-setgid`/`-setfacl` — so it never rewrites a tree outside the
allowlist. This is why the CLI runs the hand-back before dropping the entry: the helper is the
last-line backstop for "unclaim never modifies permissions on an unlisted directory", and the
CLI's classification is the front-line gate. This is the claim-side partner to
`ai-tools-chown`'s "act only on `SANDBOX_USER`-owned paths" rule
([ownership-and-hooks](ownership-and-hooks.rule.md)): claim never pulls a foreign-owned file
into the agent's group, and unclaim never regroups one out.

**Sandbox clone** (`--sandbox-create`) shallow-clones the repo under `SANDBOX_ROOT`
(`/var/opt/ai-tools/sandbox-projects`) so the agent never reads the origin's full history.
Work is pushed to a per-repo branch `ai-tools/sandbox-<user>/<leaf>` (default leaf `main`);
only the projects user can push (the sandbox account holds no git credentials), and anyone
with repo access merges that branch back, preserving the agent's commits granularly (see
`/var/opt/ai-tools/README.md`). Clones are labelled statically by `ai_tools.fc` + a plain
restorecon, not by `ai-tools-relabel`.

The create is **lock-before-grant**: the clone is born owner-only (`umask 077` around the
`git clone`, so the tip commit's possibly checked-in credentials are unreadable to the
sandbox account from the first instant), then `sandbox_finalize` runs the same secret gate
as a claim — allowlist entry first (the lockdown scan acts only on an allowlisted path;
rolled back on a failed gate), the scan + lockdown confirm — and only past the gate opens
the clone up: `normalize_clone` adds group `rwX` + setgid dirs while **pruning every path
the gate locked** (re-opening one would undo the lockdown), then relabels and registers.
A declined or failed gate **fails closed**: the clone stays on disk but private —
not group-accessible, not relabelled, not registered — with a guard `CLAUDE.md` dropped
and the resume command printed. Re-running `--sandbox-create` **on the existing clone
path** (any path under `SANDBOX_ROOT`) resumes `sandbox_finalize` on it.

The shared sandbox area carries a `g:ai-ops:rwX` ACL (traverse on `/var/opt/ai-tools`, rwX +
default on `sandbox-projects`, applied by `install.sh`), so an operator creates and works in
clones without `SANDBOX_GROUP` membership — the shared-area counterpart to `ai-tools-setfacl`'s
per-project `user:<operator>` grant. The agent is not in `ai-ops` (`ai-tools-run` refuses to launch
otherwise), so the grant adds it no access.

## Privilege model

The CLI itself is unprivileged. Eight of its root operations — `ai-tools-lockdown`,
`ai-tools-relabel`, `ai-tools-setfacl`, `ai-tools-setgid`, `ai-tools-unclaim`, `ai-tools-safedir`,
`ai-tools-reclaim`, and `ai-tools-allowlist` — run via `sudo` with **no** NOPASSWD grant by design,
so sudo prompts for the projects user's password; the sandbox account has no grant for any. Two are
the exception — `--relabel` → `ai-tools-relabel-agent` and `--stop` → `ai-tools-stop` — each with a
dedicated fixed-path NOPASSWD rule of its own
(see [launch](launch.rule.md)), so each runs **as root without a prompt**, kept safe by being a
fixed path the projects user cannot modify and granted only in its zero-argument form (the rule's
trailing `""`). `ai-tools --relabel` is that rule's only consumer: the `ai-tools-relabel.path`
watcher and the agent package's `%post` both reach the same helper as root and need no rule, and
the `nvm-update` timer runs as the sandbox account, which `ai-tools-run` refuses to launch for if
it ever appears in `ai-ops`. `ai-tools-setfacl` and `ai-tools-unclaim` need root
(`CAP_FOWNER`) to act on files the projects user does not own (e.g. agent-written files from
a prior session); `ai-tools-setgid` needs root to `chgrp` the project's directories to
`SANDBOX_GROUP` — a group the operator is not a member of (multi-operator), so the change is not
possible unprivileged. Each re-validates its target path against the allowlist and shares the
exclusion/secret-skip/skip-list rules (see [ownership-and-hooks](ownership-and-hooks.rule.md)). `ai-tools-safedir` needs root to
write the root-owned `.gitconfig`; on add it re-validates the path against the allowlist through
the shared `operator.lib.sh` resolver, but edits a single entry rather than walking a tree.
`ai-tools-relabel` re-validates the same way — **per path**, not against one operator's registry:
the entry that authorizes a label lives in whichever operator's allowlist holds the project, so
resolving a single operator up front would refuse every project registered to any of the others
(a secondary operator's own claim, and every `--project-claim --for`). It then additionally
requires an **exact** entry there, since a label is applied to a registered project root rather
than to a directory inside one.
`ai-tools-reclaim` walks the project and hands each agent-owned path to `ai-tools-chown`, so the
allowlist/secret/exclusion enforcement and the need for root are that helper's, not its own.
`ai-tools-allowlist` needs root for the **read** as much as the write, since an allowlist is `0600`
inside a `0700` directory in a home the invoker cannot traverse; it is reached only by a `--for`
run, and it authorizes against `SUDO_UID` — the uid sudo sets, not the spoofable `SUDO_USER` name —
refusing a bare root call outright.
Repo-local `core.filemode=true` and the allowlist are plain writes the projects user performs
unprivileged.
`/usr/local/libexec/ai-tools` is `750 root:root`, so the projects user cannot even stat the
helpers — only sudo, as root, reaches them.

`--project-create` and `--project-remove` add no helper and no sudoers rule. What they add is
`sudo -u <target>` on a `--for` run (the *runas seam* above), which is not a new grant either: it
rides the same general axis, and without `--for` they run as the invoker with no `sudo` at all.

**Those eight calls assume a grant `ai-ops` membership does not carry** — a **general** sudo grant
is a separate host-level axis that nothing in this project writes or records
([naming-conventions](../../docs/naming-conventions.md) fixes the vocabulary), and the CLI answers
for it ahead of the run's first prompt (*The caller with no sudo grant*, above). A host needs at
least one operator holding it, since root is refused every mutating verb — the requirement, and why
root cannot stand in, are in [CLAUDE.md](../../CLAUDE.md).

## Secret pre-check on claim/clone

Before granting access, the CLI runs `ai-tools-lockdown --dry-run` and, when secret-matching
files are present, prompts to lock them down (see
[secret-handling](secret-handling.rule.md)). On a claim the gate (`secret_gate`) runs
whenever **any pending step widens the agent's access** — the setgid group change, the
group ACL, drift repair, `.git` normalization, the SELinux label — and on every first
claim (a tree can be group-accessible by setgid inheritance yet never scanned); only pure
registry additions (safedir, filemode) skip it. A declined or failed gate fails the
operation closed: the claim aborts (rolling back its own allowlist addition) and the
sandbox create leaves the clone private and unregistered, dropping a guard `CLAUDE.md`
(sentinel `ai-tools-lockdown-guard`) instructing the agent to do nothing until lockdown
runs, preserving any real `CLAUDE.md` via `git mv` to `CLAUDE.md.bak`. The gate exports
the found paths (`SECRET_GATE_LOCKED`) so `normalize_clone` prunes them from its
group-access walk.
