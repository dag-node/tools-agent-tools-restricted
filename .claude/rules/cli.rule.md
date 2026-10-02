---
paths:
  - "src/usr/local/bin/ai-tools.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-setfacl.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-unclaim.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-safedir.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-reclaim.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-relabel.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-stop.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-admin.sh"
  - "src/usr/local/lib/ai-tools/relabel.lib.sh"
  - "src/usr/local/lib/ai-tools/project-permissions.lib.sh"
  - "src/usr/local/lib/ai-tools/services.lib.sh"
---

# Management CLI and project lifecycle (`ai-tools`)

`ai-tools` (`/usr/local/bin/ai-tools`) is the project-lifecycle CLI. It runs **as the projects user** — not root, not
the sandbox account. It writes the operator-owned allowlist (`~/.config/ai-tools/allowed-projects`) directly,
and reaches the root-owned git `safe.directory` list in `/opt/ai-tools/.gitconfig` (`root:ai-tools 644`: world-readable,
root-write-only) through the `ai-tools-safedir` root helper (`sudo`), alongside its other root operations. It refuses
to run as the sandbox account (the agent must not manage its own allowlist).

How its commands are **spelled** — and why this one binary keeps option-spelled verbs while the rest of the project uses
bare words — is in [cli-grammar](cli-grammar.rule.md). This rule covers what each verb does.

**Root runs only the verbs that leave operator-owned state untouched.** That criterion is what the root refusal
protects: a registry written by root names an owner whose own launch gate cannot read it. `ROOT_ALLOWED_VERBS` —
`audit`, `status`, `projects list`, `providers list`, `stop` — is the whole set, and a verb joins it on what it
**writes**, not on what it reads. `audit` is what the carve-out exists for: the trail it reads is `700 root:root`,
so the verb needs root by construction, and a blanket refusal left it unreachable from both sides on a host whose only
operator does not hold a general sudo grant. `stop` is the one member that **acts** rather than reports: it leaves every
registry untouched, its helper requires root anyway, and root is the identity an unattended detector usually runs as —
so a CLI that refused root there refused the one principal the rung most has to serve, while root already holds both
capabilities directly (it can run the helper and signal any process on the host). The set is named once and read
by the guard, by the guard's own refusal, and by `ai-tools(1)`.

The check runs **after** `--for` is separated from the command's arguments, because `$1` before that point is not
reliably the verb (`ai-tools --for op projects list` leads with the flag). That placement also refuses `--for` for root
in either argument order: root is absent from `OPERATORS`, so an entry written for it would name an owner no ownership
helper can resolve. `require_operator` does not cover this on its own — it gates the mutating verbs, and `projects list`
is not one.

`projects list` run by root reads root's own registry, which no bootstrap creates, so it reports an empty list correctly
and misleadingly. It therefore says whose registry it read and names the enrolled operators, since an allowlist is
per-operator by design. Root cannot follow that with `--for`, so the line points at running the report as the operator
instead.

## Bootstrap preflight

A single `require_bootstrap` gate runs **before dispatch**: it keys on the enabled agents' launcher symlinks
under `/opt/ai-tools/bin` — bootstrap's last load-bearing artifact per agent, written after the account, Node,
and that agent's package all succeed — so one existing for any enabled agent means provisioning finished, and none fails
the CLI fast with the provisioning hint rather than mid-operation in a root helper. The enabled set comes
from `ai_tools_enabled_agents` ([providers](providers.rule.md)), the resolver the toolchain and `ai-tools-run` provision
from, so the CLI does not name an agent of its own and a host that enables one agent, or several, is read the same way;
each launch wrapper gates on its own agent's link, so the two entry points share one definition of "provisioned". Every
way the read can fail **refuses rather than passes**: a resolver library that will not load (`MSG-V3N7`), an enabled set
none of whose links exist (`MSG-X9H7`, naming each agent and the bootstrap command), and an empty enabled set
(`MSG-K7A6`, carrying `ai_tools_agents_empty_verdict`'s reason — an input the trust predicate refused, an allowlisted
name with no manifest, or a configuration that asks for no agent). The set is resolved once per run and read again
by `status` and by the clone verb's next-step hint, which prints one launch command per enabled agent.
`AI_TOOLS_LAUNCHER_DIR` moves the directory the links are read from — the operator-settable hook of the family the CLI's
header states, since what it moves is a report and an early refusal and never an access decision;
`tests/unit/cli-agent-set.sh` drives the gate through it. Every command that acts on the toolchain is behind the gate.
`BOOTSTRAP_EXEMPT_VERBS` names what bypasses it, in two groups.

The **diagnostics** are exempt because each is meant for a host that may be broken: `status` reports the unprovisioned
state itself, since a health check must run precisely when provisioning may have failed; `audit` reads a record
of what already happened, which an install that never finished does not invalidate — a failed provisioning is
when that record is most worth reading; and `stop` ends sessions **already running**, which it does without reading
the toolchain. That last one matters because of what the gate reads: a host that lost its launcher symlinks while
sessions were live must still reach the incident ladder's last rung.

`--help`, `--version` and the bare invocation are exempt because they describe **the CLI** rather than the toolchain:
`usage()` and `AI_TOOLS_VERSION` read no installed state. The gate's own refusal names
`sudo ai-tools-admin system bootstrap` as the command to run next, so gating the usage would leave that message
as the only place an operator could find it. `tests/unit/cli-verbs.sh` pins the membership, since the gate is one line
far from the table it reads and the failure appears only on an unprovisioned host.

The set stays narrower than `ROOT_ALLOWED_VERBS`: `projects list` and `providers` describe a toolchain that has to exist
first, so they stay behind the gate.

**`status` reports the same read, per agent.** Its Provisioning section prints one line per enabled agent, provisioned
or not, from the same resolver and the same link the gate keys on, so the gate's refusal and the diagnostic cannot
disagree about which agent lacks its link; an unprovisioned agent and an empty enabled set are reported and not counted
toward the exit status, since an unfinished install is what the section exists to say, while a resolver that cannot be
read is a broken install and is counted. The section closes with the other thing that link says: an agent that is
installed, **not** enabled, and still has its link is residue (`ai_tools_agent_residue_links`,
[updater](updater.rule.md)), the state in which every launch is refused, so each such agent is reported
with the provisioning run that removes its package and is counted, as is a toolchain library that will not load.

## Operator preflight

A second gate, `require_operator`, runs before dispatch for the **operator-acting** commands (every `projects` verb
except `list`, named in `OPERATOR_VERBS`) and refuses when the invoking user is not listed in `OPERATORS`
in `operator.conf`. Those commands resolve the caller's identity from that list (`operator.lib.sh`, inside the root
helpers); without the gate an unenrolled user proceeds through the registry writes and confirm prompts only to be
refused by the first helper that resolves owner (`ai-tools-lockdown`: "not in allowed projects for current operator"),
after partial state was written and rolled back. The gate replaces that with one up-front message pointing
at `sudo ai-tools-admin operators add <user>`. `operator.conf` is `644`, so the unprivileged CLI reads `OPERATORS`
directly, and enrollment there takes effect on the next command — no re-login, unlike the `ai-ops` group the admin verb
also grants (which the launch wrapper needs and which does require a fresh login). The **informational** commands
(`--help`/`--version`/`projects list`/`providers`) stay open, so an unenrolled user can still read usage and inspect
the host.

A third gate, `require_sudo_access`, refuses a verb whose root helper the caller does not hold a sudo grant
for, and names the command that reaches it instead (see [The caller with no sudo
grant](#the-caller-with-no-sudo-grant)). A fourth, `require_runas_target`, refuses a `--for` run
when `sudo -n -l -u <target>` reports a filesystem step the caller may not run **as** the target (the *runas seam*).
A fifth, `require_for_target`, runs last and validates a `--for` run (see [Acting for another
operator](#acting-for-another-operator---for)). The last two are no-ops without the flag.

### The caller with no sudo grant

Every helper outside the `%ai-ops` NOPASSWD rules ([launch](launch.rule.md) holds the drop-in's contents) is reached
by a plain `sudo`, which assumes the operator also holds a general grant. An account in `ai-ops` and in no sudoers rule
is a supported shape — it is what `--for` exists for — and it is distinct from having no password.

`sudo` authenticates before it decides whether a rule matches. `require_sudo_access` answers that question ahead of it,
before the run's first `sudo` — the same ordering `require_for_target` follows — so a caller holding a password is never
asked for it on a verb no rule lets them run. Each verb is probed on the **first** helper it reaches (a `--for` run
on `ai-tools-allowlist`, whose snapshot precedes the verb's own helper), so a host granting some helpers and not others
is answered accurately rather than through one representative. `projects push`, `projects remove`, and the informational
verbs reach no helper that can refuse the command, and are not probed. Neither is `stop`, the privileged verb
an operator without a general grant can already run through the `%ai-ops` rule for its helper: probing it answers "grant
present" every time, so the entry would carry no information. (That rule covers the bare form only, so `stop`'s flagged
forms do meet sudo's ordinary prompt — [ref-section-r5r9](stop.rule.md#ref-section-r5r9). The probe could not have
reported that either: it asks about a helper, not about a command line.)

The probe is `sudo -n -l <helper>`, which cannot prompt. An operator holding a general grant gets exit 0 and the command
echoed back, whether or not a credential is cached — listing an allowed command is not itself password-gated on a stock
sudoers. **The refusal is silent:** for a command no rule matches, `sudo -l` exits non-zero with empty output,
and the *"Sorry, user … is not allowed to execute"* line an operator sees comes from the attempt to **run** the command,
not from the listing. So silence with a non-zero status is the answer this reads as a missing grant.

Silence is conclusive only while sudo is answering, so it is confirmed against a bare `sudo -n -l`, which lists
the caller's whole rule set — an `ai-ops` member always has one. That separates "sudo knows this caller and has no rule
for that command" from a sudo that failed for its own reasons, and only the first refuses. A *password is required*
answer means listing is itself password-gated (sudoers `listpw`), so the grant may exist and that caller is left
to the ordinary prompt; `LC_ALL=C` pins the wording of that one match.

**The gate reports; it does not decide, and so it fails open.** The project's fail-closed rule governs the predicates
that decide what a principal may do: each resolves, on any failure, to *less* access ([CLAUDE.md](../../CLAUDE.md)).
This gate is not one of them. It does not grant any access, and `sudo` remains the only thing consulted about the helper
— so an inconclusive probe (no `sudo` binary, a translated or unrecognized answer) falls through to the call site
and lets sudo answer, leaving the access outcome identical to having no gate at all. The composition stays fail-closed
because the enforcement point it sits in front of is.

Failing *closed* here would invert that: refusing on an unparsed message subtracts access sudo would have granted,
turning a diagnostic into an access decision that can only ever take away — a `wheel` operator whose sudo answered
in a locale the match did not cover would lose a command they hold the grant for. The cost of the direction chosen is
bounded, and is never a security one: on a host where the answer cannot be read, the operator meets sudo's own message,
which is the behaviour this gate exists to improve on rather than to guarantee.

The refusal names the account, the helper, and one command, and stops there. Who that account belongs to is not knowable
— a service account, a person on a restricted login, an administrator working from one deliberately — nor is who runs
the suggested command or what they are to each other. So it does not suggest how to obtain a grant, and does not
describe the account as anyone's. For the delegable verbs the command carries `--for <account>`, which is the whole
mechanism: the verb runs against that account's registry whoever performs it. `projects clone` does not take `--for`
(the clone is made with the git credentials of whoever runs it), so its refusal names two commands — the create, then
a `projects claim --for <account>` over the resulting clone, which the protected-paths backstop deliberately permits.
`audit` additionally names a `journalctl` query, since the trail is written to journald as well and many hosts let
an ordinary account read it — a partial view, the file sink being the authoritative one.

## Commands

- `projects claim [path]` — claim a real project in place (idempotent; default cwd): register it, grant the agent
  access, run the secret gate before any access-granting step, and offer the traverse and `.git` opt-ins. The model,
  the blocks in run order and what answers each question are under [Claim in place](#claim-in-place); `-y/--yes`,
  `--format tsv` and the exit codes are there and in `ai-tools(1)`. A usage error exits 2.
- `projects create <path>` — create a **new** project directory and claim it, asking about the traverse grant alone
  ([Create](#create)).
- `projects remove [path]` — unclaim a project **and delete its directory**; `projects unclaim` stays
  the non-destructive reversal its refusals point at ([Remove](#remove)).
- `projects unclaim [path]` — unclaim a real project, directory left on disk: revert the label, drop both registries,
  and (default-yes confirm) hand the tree back with the agent's write revoked ([Unclaim](#unclaim)). Options are
  in `ai-tools(1)`.
- `projects disable [path]` / `projects enable [path]` — park a claimed project and restore it, by putting a `!` on its
  `allowed-projects` line and taking it off again, **in place**. Detail under [Enabled, disabled,
  absent](#enabled-disabled-absent--the-three-states-of-an-entry).
- `projects clone [path]` — shallow-clone a repository into the sandbox area privately, lock down tip-commit secrets,
  and only past that gate open, label and register the clone; fail-closed otherwise, and resumable by re-running
  on the clone path ([Sandbox clone](#sandbox-clone)).
- `projects push [path]` — push the clone's commits to its branch. It and the clone kind of `projects remove`,
  which removes the clone and unregisters it, gate the target through `require_sandbox_clone`: it must be a **real
  clone** — a direct child of `SANDBOX_ROOT` (exactly one level deep, so never the shared area root and never a nested
  or system path) that is a git worktree, and it passes the protected-paths backstop. This scopes `projects remove`'s
  `rm -rf` to one recognized clone; a stray non-git directory is refused ("remove it by hand"). `projects clone` scopes
  its own destination (`<name>` with no `/`, under `SANDBOX_ROOT`), so it does not need that guard.
- `projects lockdown [path]` — wrapper over `ai-tools-lockdown` (see [secret-handling](secret-handling.rule.md)).
  Refuses a path outside every claimed project up front (`covered_by_project`, before the sudo prompt), the same
  front-line the helper's own `_is_allowed` enforces.
- `projects handback [--full] [path]` — hand agent-written files under the project back to the operator
  via `ai-tools-reclaim` (which walks the tree and delegates per-path to `ai-tools-chown`, the same boundary
  the handback uses). Refuses a path outside every claimed project up front (`covered_by_project`), so it never runs
  a silent no-op; `ai-tools-reclaim` additionally reports "nothing to reclaim" for a direct `sudo` call past the CLI.
  Reclaims the `.git` tree the per-session sweeps skip; the ownership companion to the `user:<operator>` ACL, run
  on demand before an ACL-unaware backup so ownership (not the ACL) carries the operator's access into the copy.
  `--full` includes the skipped heavy trees (`node_modules`, `.venv`, …). See
  [ownership-and-hooks](ownership-and-hooks.rule.md).
- `providers` — read-only report of the installed agents and integrations, which of them a session gets, and why. It
  resolves through `providers.lib.sh` (see [providers](providers.rule.md)) rather than re-reading `operator.conf`,
  so the report and the launch agree by construction: the per-kind gating line comes from `ai_tools_provider_gate`
  (`allowlist` / `baseline` / `untrusted`), the enabled set from the same `ai_tools_enabled_{agents,integrations}`
  the toolchain and `ai-tools-run` use, and the installed set from the manifest directory listing — so a manifest
  the resolver refuses shows as disabled. The resolvers' refusals, which at launch reach only the terminal and journald,
  are captured from their stderr and reported in a closing block. On a host where SELinux is not `Disabled` it adds
  a **SELinux policy groups** section: the core module's load state and every loaded optional group, read unprivileged
  via `semodule -l`, keyed off the shared `selinux-groups.lib.sh` registry. The whole section is **omitted**
  when that list is not readable unprivileged (common — the policy store is root-only on many hosts): every line it
  prints needs the module list, so a section that could only say "cannot read" is not shown at all (inspect groups
  with `sudo ai-tools-admin selinux groups`). Under **Enforcing** it then reads each enabled integration's manifest
  for the policy groups its toolchain declares (`selinux_groups`, `ai-tools-providers(5)`) and names the ones not
  loaded, each with the registry's description, followed by one `ai-tools-admin selinux groups enable` command carrying
  every missing stable group and, on its own line, the source-checkout command for an experimental one. The block does
  not name any toolchain: the manifest declares the set, the registry supplies the words, and the same read is
  what `ai-tools-admin <integration> status` reports. The .NET set is in [dotnet](dotnet.rule.md).
- `audit [--since <when>]` — report what has refused, been rejected, been stranded, or been flagged since a given time,
  through the `ai-tools-audit` root helper (`sudo`, no NOPASSWD; the root carve-out in `ROOT_ALLOWED_VERBS` exists
  for it, and it runs ahead of the bootstrap gate — see [Bootstrap preflight](#bootstrap-preflight)). The detections it
  reports already existed and were already recorded; the verb supplies the reader. How a finding is decided (a line
  at `NOTICE` or higher in the root-only file sink, so a helper that adds a warning is reported from the day it ships),
  why the records are read raw, how each field is sanitized, and how repeats collapse under severity are the helper's
  own mechanism, stated in its header and beside the code.

  **Three trails, and the report keeps them apart.** The root-only file sink is evidence. A launch refusal reaches only
  journald, under the sandbox account's own tag, so it is shown in a section of its own to reconcile against the first
  rather than to rely on alone — the split [logging](logging.rule.md) states. The third is the kernel's record
  of an agent entrypoint exec'd from inside a running session, which no process of the sandbox account can write
  or remove; the `auditallow` that records it, and the one ordinary exec the report counts rather than itemizes, are
  [ref-section-f2p3](launch.rule.md#ref-section-f2p3). The section states which reading it made — findings
  where the core module carries the rule, a coded notice naming the remedy where SELinux is disabled, the module is not
  loaded or predates the rule, or the host does not run an audit daemon — and an absence the helper observed leaves
  the exit alone, the same rule `status` follows for a `?`. A tool that is present and failed reads as `unreadable`,
  a reading that could not be made, and the run exits 5.

  **Each source is read with its exit status, stdout and stderr apart, and a source whose result is empty is told
  from one that failed by what its tool documents** ([records](records.rule.md) holds the collector shape). `grep` exits
  1 on no match and 2 on a read error; `journalctl` exits 0 over an empty window; `ausearch` exits 1 for no match
  and for an error alike, so its `<no matches>` line is what separates them, and an exit 1 without it is reported
  as unreadable. The log directory is checked before it is listed, since an unexpanded glob over a directory that is
  missing or refuses a listing would read as a host with no log file; a `*.log` entry other than a readable file
  and a record whose timestamp `date(1)` refuses are each a reading that could not be made. The observed absences — no
  `journalctl`, no sandbox account (`getent` exit 2: no session ran), no audit daemon, no SELinux, no `sesearch` — are
  printed as the reading each is, and leave the exit alone.

  **It reports events, never current state.** Each line is something that *happened* between two points in time,
  and a condition recorded here may have been resolved since, so the report closes by naming `status` (and
  `ai-tools-admin system entrypoints relabel`) as what answers *now* rather than re-verifying a finding itself: knowing
  how to re-check each condition is the per-detection knowledge it refuses to carry. Exits **4 when anything is reported
  and 5 when a reading could not be made** — the codes `ai-tools-records(5)` states, folded
  through `records-base.lib.sh` and required at load, so a helper whose exit contract did not load refuses and does not
  exit 0 — so it runs unattended from cron or a login banner without parsing its output, the same contract `status`
  offers. An incomplete run opens by naming each reading it could not make and never prints the clean headline,
  so a section that reads clean after it is not taken for a clean window; the findings it did read follow the list.
  A non-root caller is refused at 5, since the trail is `700 root:root` and no reading is possible. A `--since` value
  `date(1)` does not parse is refused at 2, so a typo does not become a reassuring wall of old findings.
- `stop` — terminate every running agent session and everything it spawned, through the `ai-tools-stop` root helper,
  which `%ai-ops` grants NOPASSWD in its bare form (the one rule in the drop-in whose passwordlessness is its purpose:
  an unattended detector cannot answer a prompt — [ref-section-r5r9](stop.rule.md#ref-section-r5r9)). The only verb
  that acts on a session **already running**; every other control here changes what the *next* launch gets. It is
  **not** the session-lifecycle command — `/exit` inside a session is, and it lets the session run its own `SessionEnd`
  handback. The CLI half is deliberately thin — option grammar only — because every remaining decision is a security
  decision that must not be made twice in two places: `cmd_stop` passes each recognised option through, takes neither
  a target nor an authorization input, and refuses a path with exit 2, in the helper's exit-code space. What the helper
  does with that, the invariants it rests on, and the two project conventions it inverts are in [stop](stop.rule.md),
  which owns the component.

  A stop cannot run the agent's `SessionEnd` hook, so the in-flight turn's writes may still be sandbox-owned
  and the clean-exit marker is left for the next `SessionStart` ([ownership-and-hooks](ownership-and-hooks.rule.md));
  the command names a `projects handback` for each project it terminated a session in. Everything is recorded
  to `stop.log` and journald, including which path gave consent and which pass ended each session. Exit codes are
  in `ai-tools(1)`.
- `status` — read-only health report: the installed `ai-tools` version, the Node version the enabled agents' stable
  launcher links point into (the link's target read one hop with `readlink` and never followed, the read the launch
  wrapper makes; every path that changes Node repoints the link, so the line is current after a bootstrap
  as after an update, with the version the updater's last run recorded shown beside it only where the two differ —
  the one fact a link cannot carry, that the toolchain changed after that run — and links naming different versions
  reported as such; the decision is `ai_tools_node_version_verdict` in `toolchain.lib.sh`, so this report
  and `ai-tools-admin status` render one answer), a version pointer per enabled agent whose wrapper is installed,
  which enabled agents are provisioned (one line each, from the read the bootstrap gate makes — see [Bootstrap
  preflight](#bootstrap-preflight)) and, under each, every managed file its manifest names whose live copy is not
  the shipped one (`managed_files`, [providers](providers.rule.md): an edited file is reported with its two consequences
  and not counted, a missing one is counted, since the package is then broken), then each installed agent that is not
  enabled and still has its launcher link (residue, counted: no launch starts until the provisioning run it names
  removes the package), **where this shell finds each enabled agent's launcher**, then each managed systemd unit
  the `services.lib.sh` registry names as OK / SKIPPED / STALE / DOWN / FAILED / not-installed, with the consequence
  and the exact remedy for anything broken, and a closing **More** block that points at the sibling reports
  (`providers`, `projects list`, `--help`) without repeating their detail — so it reads as a hub. That registry is
  the **same one** the launch wrapper's pre-launch health warning reads (`ai-tools-launch`, see
  [launch](launch.rule.md)), so the status view and the launch warning never disagree on which units matter
  or how to fix one, and the rows live there alone. `status` runs ahead of the bootstrap gate, as the other diagnostics
  do (see [Bootstrap preflight](#bootstrap-preflight)), so it reports the unprovisioned state rather than being blocked
  by it.

  The PATH-ordering line is the one reading this report makes that needs **no** privilege and that no other vantage can
  make at all: the CLI runs in the operator's own login shell, so `command -v` there resolves exactly what typing
  the launcher's name would run. A launcher resolving to a file other than the wrapper is an agent that starts
  **unconfined, as the operator**, so it reads `UNCONFINED`, names `ai-tools-admin operators add <operator>`
  as the repair, and counts toward the non-zero exit. A launcher reaching the wrapper with no ordering line wired is
  right today and says so dimly, since that shell is sandboxed until the next thing that prepends to PATH takes it away.
  A launcher this host does not install a wrapper for, and a name `command -v` does not resolve in this shell, are
  reported and are not faults — the same rule the unqueryable units follow. The states and the reading behind them are
  [ref-section-p3k8](launch.rule.md#ref-section-p3k8).

  A unit in the sandbox account's own `systemd --user manager` is not queryable from the operator's session at all,
  so its state comes from a **last-run stamp** it publishes where the operator can read it (`nvm-update.service`, see
  [updater](updater.rule.md)) and stays `?` where it publishes none. **A root caller reads it live**, over the machine
  transport, and gets that reading through this same command: `services.lib.sh` gates the probe on the caller's own
  capability, so whichever command asks, `sudo ai-tools status` resolves a unit exactly as `ai-tools-admin status` does
  (see [The root vantage: `ai-tools-admin status`](#the-root-vantage-ai-tools-admin-status)). How a live reading
  and a stamp compose into one verdict — which of the two decides a state, and which decides freshness — is
  `ai_tools_service_stamp_verdict`'s contract, stated there. One live fact about that manager *is* readable unprivileged
  — whether the unit **file** is installed — and it is checked first, so a unit an optional package never shipped (the
  `nvm-update` pair without the nodejs integration) reads as not-installed rather than as one this host cannot see,
  and a stamp an uninstall left behind cannot make a gone unit look present. A run that **correctly declined to act**
  reads `SKIPPED` with its reason (the updater against an unreachable registry, or under a clock behind a file it wrote,
  see [updater](updater.rule.md)): it is dim rather than yellow and does not count as a fault, so a disconnected laptop
  does not make `status` exit non-zero every night — while the same stamp still ages into `STALE` if the condition
  persists, which is where a toolchain that has genuinely stopped advancing surfaces. The account's own
  `~/.config/systemd/user` is not searched: it sits inside a home the operator cannot traverse, and every unit
  the registry names ships to the system-wide user-unit directory. A stamped unit's OK carries the time of that run, not
  a claim that it is running now, and a `FAILED` carries the run's exit code. The `?` line is not a problem report — it
  says only that this vantage point cannot tell — so it stays a single line naming the one command that can,
  and the multi-command diagnostic block is reserved for a unit reported broken. One state is separated from it in both
  reports: a stamp still empty as the package seeded it (`ai_tools_service_stamp_unwritten`) reads
  `no run recorded yet`, since that is where a freshly provisioned host stands until the updater's first window,
  and a `?` there would send an operator to check a unit that is fine.

  **A stamp is read for two properties, and one stamp can serve two units.** `RESULT` answers *did the last run
  succeed*; its **age** answers *are runs still happening* — a distinct question a `RESULT` cannot express, since
  a schedule that quietly stops firing leaves every recorded run successful and would otherwise read as a permanent,
  increasingly wrong OK. Past the record's `max_age` — set per unit in the registry, at a multiple of the unit's own
  schedule — the unit reports **`STALE`**. The registry's `stamp_mode` field selects which property a record reads:
  `result` for the unit that ran, `fired` for the one that triggered it — so `nvm-update.timer` derives a verdict of its
  own from the *same* stamp on recency alone (a systemd-started run, successful or not, proves the timer fired), instead
  of the `?` it could otherwise only report. A failing service therefore does not also condemn the working schedule
  that started it. Only a systemd-started run counts, read from the stamp's `TRIGGER` (see [updater](updater.rule.md)):
  a run the operator did by hand is no evidence about a schedule, and counting one would both report a dead timer
  as healthy and suppress the staleness that is the only way a stopped schedule shows up. An unknown age does not
  produce a `STALE` verdict either: no `max_age`, an unparseable date, or a stamp dated in the future all decline
  the judgment.

  Times render **relative first** (`last run 3 days ago`), coarsening with distance, because the age is
  what the operator acts on. Every unit line feeds one predicate, `ai_tools_service_needs_attention`
  (`down`/`failed`/`stale`, not `unknown`), which is both what the scanner collects and what `status`'s **exit status**
  reports — 4 when anything is broken, so the command is usable from a monitor or cron without parsing its output.
  An unqueryable unit is not a fault and does not alarm.

  **The exit is the report state's** (`ai-tools-records(5)`, folded through `records-base.lib.sh`, which `cmd_status`
  loads and requires): 4 where a section read a fault, 5 where a section could not make a reading it promises, and 0
  otherwise. Each section returns 1 for a fault and `STATUS_UNREADABLE` for a reading it could not make,
  and `status_fold` turns the two into the fold, so the sections stay free of the library and drivable on their own.
  What exits 5 is a library base ships that did not load — the service registry, the provider resolver, the toolchain
  readers — a broken install, reported under a code and still followed by every later section, so the page carries each
  reading it could make beside the one it could not. A `?` or `n/a` line is a reading **this vantage** cannot make —
  an operator reading a sandbox-user unit, a pin the account cannot traverse to — and is neither: it leaves the exit
  at 0, since a probe the vantage may fail without the host being broken must not make a nightly `status` alarm.

  **Both halves of the entrypoint reconciliation are reported, from the records it writes.** Neither the binary nor its
  label can be inspected from this account, so each half leaves a root-owned record where the operator can read it.
  The *pin* is the verification half: `status` reports one line per agent that declares a release manifest: `VERIFIED`
  with the pinned version and how long ago, or `unverified`, or `?` when this account cannot read the pin at all
  (`status` stays open to a non-operator, who cannot traverse the state directory). It reads through the **same stamp
  accessors** as the unit records — the pin is written in that grammar — so the charset clamp and the age calculation
  have one implementation. An agent whose package does not declare a release manifest is omitted, not reported
  as perpetually unverified. Unpinned counts toward the **exit status only where the operator required verification**
  (`AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY`), since that is exactly when it will refuse a launch; everywhere else it is
  a legitimate state — an air-gapped host, a release the vendor published no manifest for — and must not alarm, the same
  rule the unqueryable units follow.

  **A pin a reconciliation refused to re-record is reported in place of that line**, from the mark the refusal writes
  beside the pin ([ref-section-b3k5](updater.rule.md#ref-section-b3k5)). It replaces that agent's tier line instead
  of joining it: the pin a refusal left standing is a valid record of a verification that once succeeded, so printing it
  too would pair a green verification with the red line saying it no longer describes the installed binary. It counts
  toward the exit status, being the state in which every launch of that agent is already refused, and it names
  the reconcile command, which re-reads the entrypoint and prints how to replace it.

  The **labelling** is reported beneath it, from a second record the same helper writes
  ([ref-section-j9w8](updater.rule.md#ref-section-j9w8)): `labelled` with its age, `NOT LABELLED` with the class
  of failure, `not labelled` for a host with no entrypoint to label (the SELinux layer inactive, or an agent
  the toolchain has not provisioned), or `?` where no reconciliation has been recorded. Only a recorded failure counts
  toward the exit status, since it is the one state that stops the next launch.

  **One reason token is read rather than printed**, and it is the one whose remedy differs in kind: `incomplete-package`
  says the agent's package does not hold the executable its manifest declares, which no relabel can supply, so the line
  names the provisioning run that reinstalls the package instead of the relabel retry every other failure gets. Offering
  the retry there would be the loop this report exists to end. The token is written by `ai-tools-relabel-agent` (see
  [updater](updater.rule.md)); every other reason is rendered as the record carries it.

  **The two halves are reported together because they fail independently.** Verification and labelling run in the same
  helper, in that order, and the first can succeed while the second does not — leaving the pin line freshly green,
  written by the very run whose labelling failed, which reported alone reads as an all-clear. What is reported is
  the last run's **outcome**, not the live label: the operator can observe neither the label nor the run that applies
  it, which is why the record exists (stated with it), so it carries the same caveat as the rest of this report — it is
  an event. `ai-tools-admin status` reads the label itself (see [The root
  vantage](#the-root-vantage-ai-tools-admin-status)), and `ai-tools-admin system entrypoints relabel` both confirms
  and repairs it. A mislabel that arises after the recorded run still stops the next launch with the fault
  and the command that clears it.

  **The unit that does the labelling is reported too, and answers a different question.** `ai-tools-relabel.service` is
  in the registry beside the `.path` that triggers it, because a healthy watcher says only that a run *started* —
  on the upgrade that motivated both records, the watcher was `OK` and the relabel it fired had failed. A `Type=oneshot`
  service is inactive whenever it is healthy, so it is judged by the result of its last run rather than by `is-active`
  (see `services.lib.sh`), and its remedy is `systemctl start ai-tools-relabel.service`: that re-runs the work *and*
  clears the recorded failure the report reads, which `ai-tools-admin system entrypoints relabel` does not. The two
  records answer different questions — the label record covers every caller (an rpm `%post`, the watcher,
  `system entrypoints relabel`), while the unit covers a watcher run that failed before it reached any labelling at all.

  Every command for such a unit goes through root, and the CLI composes them rather than the registry storing them: each
  names the sandbox **account**, and `services.lib.sh` is deployed with no `@SANDBOX_USER@` substitution. Status
  and restart use the **machine transport** (`sudo systemctl --user -M ai-tools@.host …`), which reaches that manager
  over the system bus where root is authorized — a plain `sudo -u ai-tools systemctl --user` gets its own bus refused
  even when the manager is healthy (the reason the tests' `sandbox_systemctl` prefers it). The journal query cannot use
  either: `journalctl --user-unit` as root reads **root's** user units, so the unit is selected by the journal fields
  instead (`sudo journalctl _SYSTEMD_USER_UNIT=<unit> _UID=<sandbox uid>`), which ANDs across the two field names
  and catches both the unit's own output and the `systemd-cat` lines its script emits.
- `projects list` — report every allowlist entry (project / sandbox / exclude / unusable) with its git `safe.directory`
  status, then a **Suggested cleanup** section flagging inconsistent hand-edited entries, each with a copy-paste
  remediation carrying the full absolute path (an anchored `sed` line-deletion, plus `ai-tools-safedir --remove` /
  `ai-tools-relabel --remove` where they apply, or `ai-tools projects claim` to finish a partial claim). It flags,
  in both directions: a protected system path the tools refuse to touch; a stale allow entry or a stale non-glob `!`
  exclusion whose path no longer exists; a **glob in an allow line** (unusable — the launch wrapper realpath's allow
  entries, so a glob there resolves to no path and is inert; globs belong only on `!` lines); a project listed but not
  fully claimed; and — the reverse direction — a git `safe.directory` with **no** allowlist entry (orphaned, e.g.
  a hand-deleted line), skipping the deliberately-registered control-plane paths the protected-paths backstop already
  covers. Entry membership is decided through the shared grammar matcher in `conf.lib.sh`
  (`ai_tools_conf_allowlist_has_entry`), realpath-normalized, so an entry carrying an end-of-line comment or quotes —
  or reached by a symlink — reconciles the same as the launch gate reads it, rather than reading as unlisted. It reuses
  existing predicates and verbs only (no recovery machinery), stays **read-only** (every fix is an emitted command,
  never an in-place rewrite), and closes with a compact **Maintenance** pointer to the per-project verbs. Informational,
  so it stays open to a non-operator.
- `--version` (the deploy-stamped package version; `dev` from a raw source tree), `--help`.
- `--for <operator>` — a **modifier**, not a command: run the verb on behalf of another enrolled operator (see [Acting
  for another operator](#acting-for-another-operator---for)).

**A command line a verb does not parse is refused with exit 2, the usage status `ai-tools(1)` states, before any helper
or `sudo` runs** — an unknown option, a second path for a verb taking one, an argument to a report taking none, a path
for `stop`, and an option that has no effect beside another. Each refusal carries its own message code (`die_usage`),
so a script tells a rejected command line from an operation that failed (exit 1) by the status alone. The one refusal
this ordering does not yet cover is a `--for` run, whose allowlist snapshot — the run's first `sudo` — precedes
the verb's own parser ([Acting for another operator](#acting-for-another-operator---for)).

**`--relabel` prints the new command and exits 2.** The entrypoint reconcile is
`sudo ai-tools-admin system entrypoints relabel` ([updater](updater.rule.md) owns what it does,
[cli-grammar](cli-grammar.rule.md) why it is spelled that way): it runs as root, which this CLI refuses, so it is not
an alias. The pointer answers **ahead of every gate**, which is where its value is — the bootstrap gate would send
an unprovisioned host to the provisioning command, and the root guard would answer `sudo ai-tools --relabel`,
the spelling the older release notes print, with a list of the verbs root may run, none of which reconciles
an entrypoint. It exits **2**, the documented code for a rejected command line.

The CLI ships a man page, `ai-tools(1)` (`src/usr/local/share/man/man1/ai-tools.1` → `/usr/local/share/man/man1/`,
deployed by `install.sh` and the RPM with the same `@AI_TOOLS_VERSION@` substitution as the CLI). It is hand-written
troff, since the CLI cannot be executed at package-build time for `help2man` (the bootstrap gate fail-closes
on an unprovisioned host). The page and `usage()` are **not** copies of each other: `usage()` is orientation —
the verbs, one line each, and the three cross-verb flags — while the page is the reference for every per-verb option,
which is why a per-verb option lives under its verb there rather than in a flat list that would separate `--branch`
or `--dir` from the only command they mean anything for. `tests/unit/man.sh` keeps them honest with three checks
in place of the old set-equality: the **verb** sets match in both directions, every option `usage()` names is documented
in the page, and every option the page documents is one a CLI **parser** accepts. That last direction replaces "the help
must name it too", which made moving an option out of the help fail as a stale man entry; what goes stale is an option
outliving its parser.

## The root vantage: `ai-tools-admin status`

`status` and `ai-tools-admin status` are **one resource read from two vantages**, not two reports. The root command
reports the same host and adds the readings the operator's prints as `?`:

| reading | what blocks the operator | what root does |
|---|---|---|
| a sandbox-user unit's state | that account's bus needs the machine transport, which is authorized for root alone | `systemctl --user -M <account>@.host`, through the shared registry |
| an entrypoint pin | the state directory is root-owned, without a traverse bit for a non-operator | reads it, through the same stamp accessors |
| whether the installed entrypoint still matches that pin | the toolchain is `0750` and sandbox-owned, so the file cannot be hashed | hashes it and compares, the same comparison the launch shim makes |
| an agent path's SELinux type | the entrypoint sits in a `0750` toolchain owned by the sandbox account | `stat`s the label itself |
| an agent's installed version | the same toolchain | reads the `package.json` around the entrypoint (`ai_tools_entrypoint_installed_version`), as data: running the agent's `--version` would execute a file the sandbox account can write ([ref-section-s9t9](updater.rule.md#ref-section-s9t9)) |
| the sandbox account's systemd unit search path, and the `Persistent=` timer stamp on it | the chain is root-owned without world bits, so an operator outside the sandbox group cannot traverse it, and the stamp sits inside that account's home | reads both: the chain against its declared layout, the stamp's own mtime |

**What keeps them one resource is where the privilege is tested.** `services.lib.sh` offers a live reading to whichever
caller can make one, so the capability is checked at each read rather than at the dispatch: `sudo ai-tools status`
resolves a unit exactly as `ai-tools-admin status` does, and an unprivileged run of either reports the same `?`. Two
commands exist because the binary is the privilege boundary ([cli-grammar](cli-grammar.rule.md)), not because there are
two sets of facts. The **rendering** does differ — this CLI's coloured report against the admin tool's plain
bracket-token table — which is the registry's own contract: it emits records and leaves every consumer to format them,
the same way the launch wrapper's pre-launch warning does.

The pin comparison is the reading that answers *now* rather than *then*: `status` reports what the last reconciliation
recorded, so a binary changed since — by an out-of-band `npm install`, or by anything else writing that tree — is named
here without running the reconcile, and it is named even where no reconciliation has run over that agent at all.
The verdict is `ai_tools_entrypoint_check`'s, so this report and the launch cannot disagree about what a mismatch is.

The label reading is the one no other command gives. `status` reports what the last reconciliation *achieved*, an event
that may be hours old; `ai_tools_agent_label_report` reports the type each path carries **now**, so a label that drifted
since — an out-of-band `restorecon`, a package that reinstalled the binary — is visible without running the reconcile.
It is **read-only**, which is what makes it safe to call from a report, and its whole difference
from `ai_tools_label_agent_paths`; that function's header states which calls each one makes.

**The sandbox unit search path is a section of its own, because only root can read it.** A chain directory that exists
at another owner or mode is `DRIFTED` and counts; an absent one is `n/a`, a host provisioning has not reached;
and an entry under `.local/share/systemd` other than the stamp directory is `UNEXPECTED` and counts. The drift reader's
status keeps a failed reading apart from a clean chain. The `Persistent=` timer stamp is read by its mtime
through `ai_tools_timer_stamp_verdict`, with the tolerance taken from the timer's own accuracy and randomized delay;
only `FUTURE` counts, since a future-dated stamp suppresses the catch-up run a missed window gets. `OVERDUE` is printed
without counting, as the Services section counts that fault. The report does not write the stamp.

The report is otherwise the same contract as `status`: it exits 4 when something needs attention and 5 when a library
base ships did not load, so a section could not make a reading it promises — the two counts `STATUS_PROBLEMS`
and `STATUS_UNREADABLE`, folded through `records-base.lib.sh` at the end — so it runs unattended without parsing its
output, and `?` and `n/a` do not count toward that status: a reading this vantage cannot make must not alarm a healthy
host. A registry that did not load is reported under its code and the later sections still print.

## Acting for another operator (`--for`) <a id="ref-section-z3p9"></a>

`--for <operator>` performs a command **on behalf of** another enrolled operator: the allowlist entry lands
in the target operator's `~/.config/ai-tools/allowed-projects`, so `ai-tools-setfacl` grants `user:<target-operator>`,
the ownership handback restores to that account, and its agent's launch gate covers the path. It exists for a **service
account that runs an agent without holding a password**: such an account cannot authenticate the claim's own no-NOPASSWD
root helpers, and a claim performed by a human would otherwise register the project in the *human's* registry — not
the one that account's launch wrapper reads. A human operator claims once with `--for`, and that account's session then
finds the project fully claimed and never reaches a password prompt.

The flag is separated from the verb's own arguments **before dispatch**, so every command reads one already-decided
owner rather than each parsing it. Two globals carry the result: `OWNER_USER` / `OWNER_GROUP` name the operator the run
acts for (the target, or the invoker), and every message that names the owner a file ends up with — and every scan
that matches on that owner (`acl_drift_scan`, `grantable_ancestor`, the hand-back prompt's default) — reads them rather
than the invoking user. What a *root helper's* walk treats as the operator is still resolved per path from that path's
allowlist coverage (`operator.lib.sh`), not from either global.

**The target's registry is unreadable to the invoker.** An allowlist is `0600` inside a `0700` `.config/ai-tools`
(seeded that way by `ai-tools-admin`), so one operator cannot read another's at all — and every decision the CLI makes
from it (is the path listed, which `!` exclusions apply, what `projects list` reports) would read an unreadable file
as an empty one. A `--for` run therefore takes a root-side **snapshot** through `ai-tools-allowlist --print`
into a `0600` temp file removed on exit, and points `ALLOWLIST` at it for reads. The snapshot is read-only input
for that run: mutations go back through the helper, which re-reads the real file and applies its own idempotency,
and `reg_allow`/`unreg_allow` refresh the snapshot after theirs — so a stale copy is never what a write is based on.

`require_for_target` gates the run, after `require_operator` (acting for another operator is itself an operator action,
so the invoker must be enrolled before the target is looked up). It accepts the flag only on the verbs whose whole
effect is decided by *which* operator's allowlist covers the path — the verbs `FOR_ALLOWED_VERBS` names, which is every
`projects` verb but `clone` and `push` — and **refuses it elsewhere rather than ignoring it**: a `projects clone --for`
that silently cloned as the invoker would leave the tree owned by the wrong operator, with no output to show the flag
was disregarded. The target must be **enrolled in `OPERATORS`**, since the ownership helpers resolve a path's owner
over that list and an entry written for an unenrolled name would be a launch gate no helper can act on; the sandbox
account and `root` are refused outright.

`--for` is **refused with `projects unclaim --force`**. That mode reaches a tree no allowlist names,
so `ai-tools-unclaim` cannot resolve an owner from an entry and binds the walk to the **invoking uid** instead —
the guard that stops one operator rewriting another's files. Honouring `--for` there would have the CLI name one
operator while the helper acted as another.

**Every refusal in the gate precedes the snapshot**, which is a `--for` run's first `sudo`: a command that is going
to be refused must not first prompt for a password. That ordering is what places the `--force` check in the gate —
reading the verb's own arguments — rather than where `--force` is parsed in `cmd_project_unclaim`, which runs
after the gate and so would prompt first. The target's group is likewise resolved only *after* enrollment is confirmed,
so a name that is neither an operator nor a user on this host is refused with the enrolment command rather than
a `getent` failure naming the wrong problem.

Sandbox clones stay invoker-only: `projects clone` clones as the invoking user with that user's git credentials,
so pointing it at another owner is more than a registry redirect and is not attempted here.

### The runas seam, and why it needs a grant `--for` alone does not

Most `--for` verbs redirect a **registry**: the entry lands in the target's allowlist and the root helpers resolve
the owner from it. Two do not. `projects create` and `projects remove` write the **filesystem** as an owner — a tree
the target must own for the claim's helpers to act on it, and a tree only its owner can delete — so both go
through `run_as_owner`, which prefixes `sudo -u <target> -H` when `--for` is set and runs the command directly
otherwise. Two claim steps use the same seam: `grant_ancestor_traversal` for the traverse ACL, whose ancestors belong
to the target on a `--for` run, and `reg_filemode` for the `core.filemode` pin it writes into the target's
`.git/config`.

`-H` is load-bearing rather than tidiness: without it (and without sudoers' `always_set_home`) sudo leaves `HOME`
pointing at the **invoker's** home, so the `git init` inside a create would configure the target's repository
from the invoker's `~/.gitconfig`.

**It uses a grant the caller already holds.** `sudo -u <target>` rides the caller's **general** sudo grant, the axis
[CLAUDE.md](../../CLAUDE.md) names, so an operator who reaches it could already act as that account; the sandbox account
does not hold a sudo rule and runs under `PR_SET_NO_NEW_PRIVS`, which drops sudo's SUID bit, so the seam is out of its
reach.

It is nonetheless a **distinct sudoers question** from the helper grants `require_sudo_access` probes: a host can grant
every `ai-tools-*` helper and still restrict `Runas` to root. `require_runas_target` asks it up front — probing each
command the run will execute, not one representative, for the reason that gate gives — because the alternative is
failing at the worst moment: a create after making the directory and before claiming it, a remove after unregistering
the project and before deleting it. Like every refusal in this family it precedes the `--for` snapshot, which is
the run's first sudo.

`projects claim` stays out of that probe even though it uses the seam. Each of its owner-run steps warns and continues
on its own, so a claim on a `Runas`-restricted host loses those steps individually and leaves the tree whole. Probing
would refuse the whole claim over one step the rest does not need.

**What this widens, stated plainly.** An allowlist is an operator's own launch gate, and `--for` lets one operator write
into another's. That sits inside the model's standing "`ai-ops` operators are trusted" boundary — an operator could
already claim the project themselves — but it is a real change in who curates a gate, so every mutation is logged
with both the caller and the target. The sandbox account reaches none of it: the helper is `750 root:root` inside
a `750 root:root` directory and the account does not hold a sudo rule.

## Enabled, disabled, absent — the three states of an entry <a id="ref-section-v2n3"></a>

`allowed-projects` is a document the operator edits, and prefixing a line with `!` to take a project out of service is
a workflow that predates any verb for it. The file therefore has three states per path, not two, and the CLI names all
three (`ai_tools_conf_allowlist_state`):

<a id="ref-table-d7q3"></a>**The three states of an allowlist entry**

| state | the file says | what it means |
|---|---|---|
| `listed` | an allow line names the path | sessions may start there |
| `disabled` | a `!` line names it | no session starts there; the entry, the permissions and the label are all still in place |
| `absent` | neither | not a project |

**An exclusion outranks an allow line for the same path**, exactly as it does at the launch gate: with both present
a session cannot start there, so `disabled` is the only honest answer. Reading only `listed`/`absent` is what made
a parked project indistinguishable from an unclaimed one — a claim appended a duplicate over an exclusion that still won
and reported success, and every per-project verb refused a parked project as "not a claimed project".

**Entry state is not reachability.** A path can hold a clean allow line and still be unreachable, because an *ancestor*
is parked or a glob exclusion matches it — neither of which names the path. That is `covered_by_project`'s question,
and the two are reported apart: a verb that changes an entry says what the entry now is, and names the other line
when one still blocks the path (`blocking_exclusion`). Reporting a project "enabled" that no session can enter is
the misreport this split exists to prevent.

### The two verbs

`projects disable` puts the `!` on; `projects enable` takes it off. Both edit **the operator's own line, in place** —
position, indentation and end-of-line comment survive — which is their reason to exist rather than being an add/remove
pair: an ordered, commented allowlist comes back exactly as it was. Both are **registry-only**: group, ACLs, setgid
and the SELinux label are untouched, so re-enabling does not grant any access that was not already granted, and neither
verb runs the secret gate. Neither invents an entry — a path the file does not name is refused, naming `projects claim`,
because registering a project is a claim and a claim scans for secrets first.

What disabling costs is everything downstream of the allowlist, and the verb says so: the root helpers resolve a path's
owner through the same allow/exclude matcher, so while a project is parked `ai-tools-unclaim`, `-chown`, `-setfacl`
and `-setgid` fail to resolve an owner and **exit 0 without touching the tree**, and `ai-tools-lockdown` refuses.
The ownership handback therefore stops restoring files written under it — the consequence to know before parking
a project a session is still writing to.

On a **parked** target the unclaim asks to lift the exclusion first, because the hand-back cannot run under one.
Declining does not abort: the registry reversal still applies — the entry dropped, or parked under `--keep-entry` —
and only the hand-back is given up, reported as not having run with the `projects enable` + `projects handback --full`
pair that completes it, and a non-zero exit. That is the same treatment a hand-back that was wanted and failed already
gets.

`projects unclaim --keep-entry` is the same edit at the end of an unclaim: the files are handed back as usual, then
the line is parked instead of deleted. It serves the release cycle — unclaim for clean permissions before a release,
claim again for the next stage — without the project losing its place in the file.

### Why no verb writes an ambiguous `!`

A `!` line means one of two things, and **after the edit they are the same text**: a *parked project*, or a *carve-out*
— a subtree an operator withheld from an enclosing project. Nested claimed projects are a supported shape, so "an
exclusion inside a listed project is a carve-out" is not sound on its own. The ambiguity is removed by refusing
to create it, in both directions:

- `projects disable` (and `--keep-entry`) **refuses a project nested inside another listed project**, naming the two
  alternatives — unclaim the nested project, or park the one enclosing it.
- `projects enable` therefore **refuses every exclusion inside a listed project** as the carve-out it must be, since no
  verb wrote it. Lifting one is the only registry edit here that *widens* what the agent reaches, so it is left
  to the editor it was written in.

Neither refusal touches the hand-edited workflow: an operator may still park a nested project themselves, and delete
the `!` themselves. The tool declines to guess, and declines toward less access. Three ways of modelling the ambiguous
case are rejected: a marker comment on the `!` line, which is absent on every hand-parked entry and, once edited
or copied, is a claim the tool trusts and the file cannot back; a prompt asking the operator to classify, which puts
a question the file cannot answer; and a structured per-project registry, which adds a second parser or a second source
of truth to the launch gate.

### One implementation of a registry change

Every component that edits an entry — the CLI (the operator's own), `ai-tools-allowlist` (another operator's,
for `--for`), `install.sh` (de-registering its own checkout) — calls the same functions in `conf.lib.sh`: `_state`,
`_add`, `_remove`, `_enable`, `_disable`. Each verifies by re-reading the file and separates *applied* (0) from *could
not write* (1) from *does not apply from this state* (2). Two rules live there rather than in any caller, so no writer
can skip them: `_add` **refuses** a disabled path (appending under a winning `!` is the duplicate-pair bug),
and `_remove` takes **both** line kinds, so de-registering a parked project does not leave a `!` behind to park whatever
is claimed at that path next. `_add` also opens a line of its own for the entry it writes: the readers keep
a hand-edited last line that runs to EOF, so an entry appended straight on would join two paths into a third naming no
project, taking the preceding entry off the gate. `_enable` additionally collapses an existing duplicate pair to one
live entry, in the earliest position it held.

For a file that is the launch gate, a writer matching lines differently from the reader would leave a project reachable
after a removal; one shared implementation of the match is what rules that out.

**An option that has no effect beside another is refused rather than ignored**, with the usage status 2
and before the run's first `sudo`: `--yes` beside `--dry-run` in `projects lockdown` and `projects unclaim`, whose dry
runs neither change a path nor ask. A silent drop would leave the caller believing the command did what the combination
asked.

## Two project models

**Claim in place** registers an existing working tree where it lives and grants the agent access to it. **A sandbox
clone** shallow-clones a repository into the sandbox area, so the tree, its history and its ancestors stay out of reach.
`projects create` belongs to the first model: it makes the directory and runs the same claim on it. `projects remove`
reverses either and deletes the tree. Each verb has a section here; the operator-facing walk through each is
`docs/projects/`, and the option grammar is `ai-tools(1)`.

## Claim in place <a id="ref-section-h7d3"></a>

`projects claim` refuses a path whose canonical form holds a control character before any verb acts on it
(`resolve_dir`): `allowed-projects` holds one entry per line, and the path is printed on the claim's page. It then
registers the tree — the allowlist entry, the `safe.directory` entry through `ai-tools-safedir`, and repo-local
`core.filemode=true` through `run_as_owner`, since under `--for` the `.git/config` it writes belongs to the target —
and grants access: group `SANDBOX_GROUP` with the setgid bit on every directory (`ai-tools-setgid`), the two ACL grants
built by `project-permissions.lib.sh` (`ai-tools-setfacl`), and the `ai_tools_project_t` label
through `ai-tools-relabel` with `restorecon -FR`, so a file carrying a foreign context is reset to the type the confined
agent can read (`ai_tools_label_project`'s contract states why forcing stays idempotent). The label primitive lives
in `relabel.lib.sh`, shared with `install-selinux.sh`. A default-yes question offers `ai-tools-setfacl --with-git`,
which gives `.git` the same group, setgid and ACL, so the operator's own commits stay agent-readable
([ownership-and-hooks](ownership-and-hooks.rule.md) states why `.git` is the one skipped tree both parties write).
The claim inspects current state and runs the missing steps alone, so a re-run is a quiet no-op and an existing project
takes each new step on its next claim.

The flow renders as self-contained blocks ([messaging](messaging.rule.md) holds the frame), each closing its own
decision:

<a id="ref-list-g6f5"></a>**The claim's blocks, in run order**

1. *Review* — the pending-step overview naming every later block, the drift reports and the notices, and the default-no
   proceed confirm covering exactly the steps listed.
2. *Interior drift* — one question per drift kind, under its list ([Interior drift](#interior-drift)).
3. *Reachability* — the traverse opt-in, its question alone ([Reachability](#reachability)).
4. *Secret lockdown* — the gate, before any access-granting step ([Secret pre-check](#secret-pre-check-on-claimclone));
   it fails the claim closed.
5. *`.git` history* — the `--with-git` opt-in, shown when a `.git` tree is present and not yet normalized.
6. *Apply* — one result line per step, the traverse grant first, closed by `claimed`, which appears only when every
   access-granting step applied and carries the ✓ only when the report state is clean.

Which answer each question takes is stated once here; the doctrine behind the defaults — a question that widens access
defaults to no and takes an explicit per-invocation flag alone — is [messaging](messaging.rule.md)'s:

<a id="ref-table-s7c5"></a>**What answers each question a claim asks**

| question | default | `-y` / `--yes` | `AI_TOOLS_ASSUME_YES` | no terminal |
|---|---|---|---|---|
| proceed with the pending steps | no | answers yes | does not answer | declines |
| relabel drifted paths | no | answers yes | does not answer | relabels only with `-y` |
| repair a drifted group and ACL | no | does not answer | does not answer | declines |
| grant traverse on ancestors | no | does not answer | does not answer | declines, prints the `setfacl` lines |
| lock secret-named paths (the gate) | yes | does not answer | does not answer | locks |
| normalize `.git` | yes | does not answer | answers yes | normalizes |
| re-enable a parked entry | no | does not answer | does not answer | declines |

The launch wrapper passes `-y` for a delegated claim after taking its own confirmation, so the same decision is not
asked twice. `--format tsv` makes stdout carry the outcome rows as `ai-tools-records(5)` states and no other line: once
the command line is parsed the page, refusals and every helper's output go to stderr, and the questions still ask
on `/dev/tty`.

**The project root must be held by the resolved operator or the sandbox account.** `ai-tools-setgid`
and `ai-tools-setfacl` act only on those two owners ([ref-section-y9z4](ownership-and-hooks.rule.md#ref-section-y9z4)),
while the registries, the `safe.directory` entry and the label apply regardless, so a tree held by anyone else would
take every step that registers a project and none that grants access, and close with a ✓ over a tree the agent cannot
enter. `require_claimable_owner` refuses before the first registry write and names the `chown`; transferring a tree
recursively needs an authority this CLI does not hold, and is deliberately not built. The commonest route to the state
is `mkdir ~/proj && ai-tools projects claim --for svc ~/proj`, where the owner resolves to `svc`.

**A claim that could not apply its root steps does not report success.** `reg_safedir`, `reg_ownership`,
`claim_setfacl`, `claim_relabel` and `grant_ancestor_traversal` each return non-zero when their step did not take,
the Apply block counts that, and a non-zero count closes the flow with a warning naming what is pending and **exit 1**
instead of the `claimed` ✓. The registries stand either way, and the claim is idempotent, so a re-run applies exactly
what is missing.

**A failed step asks once before attempting the next.** Every root step authenticates separately and no step can be
pre-authenticated (a sudoers `timestamp_timeout=0` prompts on every invocation), so a mistyped password would cost
a round of attempts per step. `note_root_failure` asks once per run, default no, which is also the no-terminal answer;
the question is unanswerable from here, since a mistyped password and an absent grant look identical at that point.
That decision covers which steps are attempted; what a partial result means differs by verb, because the safe direction
does:

<a id="ref-table-b9q6"></a>**A failed root step, per verb**

| verb | on a failed root step | why |
|---|---|---|
| `projects claim` | stops, reports what is pending, exits 1 | fewer steps applied is *less* access, and a re-run is idempotent |
| `projects unclaim` | applies the registry reversal **anyway**, then reports — dropping the entry, or parking it under `--keep-entry` | either disposition ends with no session able to start there; stopping short would leave the project launchable |
| `projects remove` | deletes **anyway**, notes the cleanup that did not run | the leftovers point at a path that no longer exists; refusing to delete would leave the tree |
| `projects clone` | reports the clone is not git-ready, exits 1 | a clone exists to run git in, and without `safe.directory` the agent's git refuses the tree |

**Two read-only notices in the Review block name what no claim step changes.** A build toolchain collects configuration
by walking from the project toward `/`, and a file it opens in an ancestor the sandbox account is denied fails the build
with an error naming that path; the Review block reports each one (`ancestor-config.lib.sh`), on the fully-claimed no-op
path as well, from the markers and filenames the installed integration manifests declare, so a project no installed
toolchain claims does not raise a notice. The .NET measurements are [ref-section-t8k3](dotnet.rule.md#ref-section-t8k3).
The second notice (`sealed_setgid_scan`) is a setgid bit on an owner-only directory whose group is neither
`SANDBOX_GROUP` nor the group of that directory's owner, compared per path against the resolved owner's primary group:
the claim walks keep such a bit, since they cannot ask whether it was deliberate, so the claim names the paths
and the `chmod g-s` that clears one, ahead of the confirm rather than from a helper's stderr under Apply.

## Interior drift <a id="ref-section-a9b2"></a>

Root-level state cannot see a path inside a claimed tree that lacks what the claim gave the rest of it, and a rename is
how one arrives: `mv` keeps a file's group, its ACL-less mode and its SELinux type, where creation under the setgid,
default-ACL, labelled parents inherits all three. A re-claim therefore runs two read-only, unprivileged scans, each
leaving out owner-only paths ([ref-definition-e3h3](secret-handling.rule.md#ref-definition-e3h3)) and `!`-excluded
subtrees as out of reach by intent:

- **Group and ACL** (`acl_drift_scan`, when ownership is in place): shared-looking paths with a foreign group,
  the predicate `ai-tools-setfacl` skips on, so the scan does not report a path the repair would decline. The hits split
  on the shared skip list: the claim walks leave a skip-listed directory's contents alone, so hits there get
  an informational block naming the remedies that reach them, which [ownership-and-hooks](ownership-and-hooks.rule.md)
  states with the categories.
- **SELinux type** (`label_drift_scan`, when the root is labelled): the paths whose type is not the one the claim's
  relabel would apply, asked of the policy through a dry run of that relabel (`restorecon -n -F`, unprivileged),
  so every loaded module's types are covered. Only a type difference counts; why a difference in the SELinux user
  or range alone does not deny the agent is in the function's header.

Each scan's walk is in its header, with the conditions that make it incomplete. **A scan reports what it could not
read**: a part of the tree it could not read makes it incomplete, so it writes an `error` row naming why, keeps
the drift it did read, and does not read as a complete scan of a smaller tree. `CLAIM_SCAN_CAP` bounds the paths
the claim asks about; past it the claim writes a `scan-capped` row ([records](records.rule.md) states the row),
the group kind capped after the skip-list split so paths the repair cannot reach do not take the places of ones it can.
A first claim, one with the setgid step pending, or an unlabelled root skips the matching scan: its normal walk repairs
the whole tree.

**Each kind is its own question, asked under its own list**, so the answer follows the paths it is about, and each
defaults to no, since each can widen the agent's access. A relabel leaves owner, group and mode alone, so it gives
the agent a path where its permissions already admit the sandbox account — a moved-in file readable by other is one;
`-y` answers it, since the launch wrapper that passes `-y` has already confirmed a claim of the tree. It also resets
every path in the tree, so a type another service needs inside a project — a Podman `:Z` volume, a directory httpd
serves — is lost to that service; the block says so and lists each hit with its current type. A group and ACL repair
moves a path from the group it holds to `SANDBOX_GROUP`, which is wrong for a file shared with a team group or read
by a service's group, so it defaults to no, and `-y` does not answer it: the wrapper that passes `-y` does not show
the operator these paths. A path on both lists reaches the agent only once both repairs take, since its permissions
and its type each refuse the agent on their own; so on an enforcing host the group question is not asked
when the relabel did not run and every path on its list is also on the relabel list, and where exactly one repair took
the claim adds one line counting those paths. A path in either list whose name, or a directory containing it inside
the project, matches the invoker's secret patterns is marked `[secret]`, with one line saying the gate makes it
owner-only before a repair runs; the mark reads `secret-patterns.lib.sh` and is advisory, so where the library does not
load, or under `--for`, whose target's patterns file the invoker cannot read, no path is marked. Either repair answered
yes joins the secret gate like any other access-granting step, which is why the gate follows both questions. A declined
repair does not stop the claim.

**After the Apply block the claim checks each drifted path on its own** against the postconditions its repair
establishes (`claim_verify_label`, `claim_verify_group`; the contracts are the doc comments
in `project-permissions.lib.sh`). A re-scan does not decide `fixed`, since a path can be missing from one because
the scan was capped, failed, or excludes it; a check that cannot be read yields `unverified` and never `fixed`,
a confirmed absence yields `gone`, and the group check reads owner, group, mode and ACL from one pinned object, so its
result is an observation of that object rather than a guarantee against a later change.

<a id="ref-table-x8q5"></a>**The outcome a re-claim reports per drifted path**

| outcome | meaning | report state |
|---|---|---|
| `fixed` | the path has what the repair gives it | clean |
| `not-fixed` | it does not: the repair was declined or did not take; a group row whose repair did not run reads `still <owner:group mode>` | exit 4 |
| `unverified` | the check could not be read | exit 5 |
| `gone` | the path no longer exists (a confirmed absence) | clean |
| `scan-capped` row | the scan stopped at `CLAIM_SCAN_CAP` | exit 4 |
| `error` row | a scan could not read part of the tree | exit 5 |

Each path gets one row, the rows in the byte order of their paths whatever order the filesystem walked them
(`drift_walk_read`), rendered as an outcome line under its heading with the path sanitized, and folded into the report
state `ai-tools-records(5)` states: 4 when a path is left not-fixed or a scan was capped, 5 when a check or a scan could
not be read, and 1 over both when a root step failed. The ways to settle a not-fixed path follow the rows, each
a command the file's owner runs, since the repairs act on every path they reach. With every repair declined and no other
step pending the Apply block does not open and the closing line carries `no change applied`. The closing line takes
the ✓ only where the report state is clean; a claim ending 4 or 5 marks it `!`.

## Reachability <a id="ref-section-d7d5"></a>

The confined session runs *as* the sandbox account, so it must traverse every ancestor of the project; one it cannot
enter (a private home, `700`) leaves the project unreachable, and `ai-tools-run`, which re-checks the project directory
as the agent, refuses it as missing after a clean claim. `find_blocking_ancestors` reads every ancestor up to `/`,
as the kernel does (`agent_can_traverse`: the owner, named-user, group and other entries under the mask, per acl(5)),
and collects each blocking one a grant may cover: a directory the operator owns, outside the protected system
directories (`ai_tools_traverse_grant_allowed`, [safe-paths](safe-paths.rule.md), which also states the one permitted
protected match, the owner's own home root, and why that grant is a condition rather than an exposure). The first
blocking ancestor no grant covers — a system directory, another account's, or one whose ACL could not be read — ends
the walk and the claim names it, so no grant is offered on a state the walk did not read; the sandbox clone is the way
in there.

The grant is one traverse-only entry, `u:SANDBOX_USER:--x`, on each such ancestor: enter, never list or read. It is
default-no, asked with the drift questions ahead of the gate, and not pre-answered by `-y` or the environment, since it
widens on the project's ancestors; a run without a terminal declines and prints the `setfacl` lines. An accepted grant
makes the tree reachable with whatever readable secrets were added since its last scan, so it schedules the gate,
and `grant_ancestor_traversal` sets the ACL in the Apply block once the gate has passed; a declined or failed gate stops
the claim with the ancestor as it was. Detection runs up front so the Review overview announces the opt-in,
and a claimed project with a grant pending — it can lose reachability to a later `chmod 700` on an ancestor — takes
the full flow rather than the no-op path.

`setfacl -m` would recalculate the mask to the union of every group-class entry, giving a masked `group:devs:rwx` full
access, so the grant is applied with `-n` and the mask set to what it was plus execute (`traverse_grant_plan`,
whose header states the call). A masked entry that holds execute still gains traverse with the account, and the prompt
lists each one under its path. An ancestor the account can already traverse is not listed, which is what makes the grant
idempotent. On a `--for` run the ancestors belong to the target, so the grant runs through `run_as_owner`.

## Create <a id="ref-section-x8s5"></a>

`projects create <path>` makes one directory (`mkdir -m 0750`), runs an empty `git init`, writes a `README.md` naming
the directory, then runs `cmd_project_claim` unchanged on the result, so there is one implementation of what claiming
means. Every filesystem step goes through `run_as_owner`, so a create under `--for` produces a target-owned tree —
the one the claim then accepts under the owner rule. `<path>` is required, since the cwd always exists.

Two refusals keep a create from being a claim in disguise. A path that **already exists** is refused naming
`projects claim`: the operation that grants an agent access to an existing tree must not be reachable by a typo,
and a half-finished create is recovered with a claim. A **parent that does not exist** is refused rather than created,
so a mistyped path surfaces instead of becoming a manufactured tree with a claimed project inside it. A reachability
pre-flight refuses a location the sandbox account could never enter before anything exists, and names an alternative
only after checking it on this host.

The tree is empty by construction, so the claim infers three answers without asking, gated on `tree_is_pristine`,
which the claim re-derives from the tree (no file outside `.git` but `README.md`, and no commits) rather than trusting
the caller's hint, since what it gates is the secret scan. The proceed confirm and its warnings are not shown, being
false for a directory that did not exist a moment ago; the secret gate is skipped, since the tree holds one file this
command wrote and the scan would cost a sudo password; the `.git` question is inferred yes, since there is no history
to expose and normalizing keeps later commits readable. The traverse grant still asks: it widens access on ancestors,
which exist.

No path it seeds is left owner-only: under an `077` umask (the `/etc/login.defs` default on many hosts, which a PAM
session hands the command) the directory, `.git` and the README would come out `0700`/`0600`, the seal `ai-tools-setgid`
and `ai-tools-setfacl` honour and skip, so the create sets `0750`, `0640` and `chmod -R g+rX` on `.git` — group read
and traverse only, since write comes from the claim's ACL, `0770` would open the tree to the operator's primary group,
shared on some hosts, and those are the modes an unclaim normalizes back to. This is a statement, not a prompt: a umask
is a blanket default, not a seal placed on this directory, so where the umask would have sealed it the create says
so in a line.

## Remove <a id="ref-section-k3v7"></a>

`projects remove` deletes the directory as well as unclaiming it. Its authorization is an **exact** `allowed-projects`
entry — allow or parked, since a `!` records a parked project that is still the operator's, and requiring a re-enable
first would make a tree about to be deleted launchable on the way out; a parked one gets its own default-no confirm
naming that state, and both its lines go with the tree. There is no `--force`: that flag exists on unclaim to reach
a tree no entry names, and deleting such a tree is an unclaim plus an `rm` the operator types. An ancestor, a path
inside a project, an unregistered path, and an entry that **contains another claimed project** (which `rm -rf` would
take with it and leave registered at a path that no longer exists) are each refused with the command that applies;
the nested check sees only the registry this run can read. The verb reads the kind from the path, so a clone
under `SANDBOX_ROOT` is removed through `require_sandbox_clone` and every other entry as a project.

A read-only deletability pre-flight runs as the acting owner and refuses when any directory in the tree is not writable
and traversable by them, naming `ai-tools projects handback --full`: the failure a destructive verb must not have is
a tree deleted down to the first directory it could not enter, with no entry left to find the remains by. The project's
**parent** is checked first and separately, since `rm -rf <d>` finishes by unlinking `<d>` from it, and that directory
is not part of the project; missing it leaves an empty, deregistered husk, so its refusal names `projects unclaim`
instead. Teardown then runs registries first, deletion last — the label, the `safe.directory` entry, the allowlist
entry, then the tree — so a failed deletion leaves an *unregistered* tree, less access rather than more. The allowlist
step is fatal if it cannot complete, since that entry is the launch gate: `unreg_allow` verifies the entry is gone
by re-reading the file rather than trusting `sed`, and names the line to delete by hand (`sed -i` writes its temporary
file into the allowlist's own directory, which the operator may not be able to write). The filesystem hand-back
an unclaim performs is not run over files about to be deleted.

It confirms twice — a default-no prompt, then `ai_tools_msg_challenge` for the project's name — and neither is answered
by a run with no terminal or by `AI_TOOLS_ASSUME_YES`; with `-y` a `path` argument is required, so an unattended removal
cannot inherit the directory it started in. The unknown-option refusal does not enumerate `-y`: a caller who mistyped
a flag is not who a both-prompts bypass is for, and `ai-tools(1)` documents it where reaching it is deliberate. The only
inline `projects clone` cross-reference in the claim flows is the Reachability blocked case, where an in-place claim
cannot work.

## Unclaim <a id="ref-section-m5n5"></a>

`projects unclaim` reverts a claim and leaves the directory on disk. The CLI classifies the target
against `allowed-projects` and acts only where something authorizes it:

<a id="ref-table-d9g9"></a>**What an unclaim does with each target**

| target | outcome |
|---|---|
| a listed project | unclaimed |
| an ancestor of listed projects | all of them, outermost-first, behind one default-no confirm |
| inside a listed project | refused, naming the nearest claimed parent |
| unlisted, carrying the ai-tools fingerprint | reported; acting needs `--force` |
| unlisted, no fingerprint | refused |

For each selected project it reverts the label, runs `ai-tools-unclaim` behind a default-yes confirm to hand
the filesystem back **before** the allowlist entry is dropped, so the helper still sees the target listed, and then
removes both registries — or, under `--keep-entry`, parks the line in place instead of deleting it, which serves
the release cycle without the project losing its place in the file. The helper clears the claim's ACL entries
and the default ACL, regroups the tree to the target group (`--group`, or the prompt's user's primary group),
and removes group write and the setgid bit on directories; the per-path reversal, the `.git` pass that revokes history
access the way the claim granted it, and the hardlink refusal are its header's. Hardlinked files are refused in both
modes and counted with the `find` line that lists them: `chgrp` and `chmod` act on the inode, which a second name
reaches from outside the tree, so acting would change a path the pass never authorized. It is the one refusal
that leaves *more* access than acting would, paid for in disclosure.

`--force` **swaps one gate for another and removes neither**: the allowlist-membership check is replaced by a per-path
residue predicate, so on a tree that was never claimed it leaves every path as it found it, and what it does to a path
it accepts is identical to a registered unclaim. It does not relax another gate (protected paths, the owner guard
[ref-section-y9z4](ownership-and-hooks.rule.md#ref-section-y9z4), the hardlink guard, the secret and `!` skips), is
refused on a registered project, and is refused beside `--keep-entry`, which needs an entry to park. The CLI's
classification is the front line and the helper's own gate the last line — `ai-tools-unclaim` refuses a target no entry
names, and under `--force` acts only on a path carrying the residue — so the CLI is never the only thing
between a caller and a tree; the helper's header states its gate and how an unlisted tree resolves its owner.

**An unclaim whose hand-back did not run says so, and exits non-zero.** That step is what revokes the agent's access
to the files; the registry work stops a session launching there but leaves the tree group-owned by the sandbox account,
so a bare ✓ over it would tell the operator access was removed when it was not. On a parked target the unclaim asks
to lift the exclusion first, since the helpers do not act under one; declining does not abort — the registry reversal
still applies, and only the hand-back is given up, reported with the `projects enable` + `projects handback --full` pair
that completes it. A failed root step follows the per-verb table under [Claim in place](#claim-in-place). The filesystem
effect per mode is [ref-table-b5v7](ownership-and-hooks.rule.md#ref-table-b5v7).

## Sandbox clone <a id="ref-section-u9a9"></a>

`projects clone` shallow-clones the repository under `SANDBOX_ROOT` (`/var/opt/ai-tools/sandbox-projects`), so the agent
never reads the origin's full history. Work is pushed to a per-repo branch, `sandbox/<leaf>` by default, where `<leaf>`
is the last component of the ref the clone was forked from (`sandbox_default_branch`; `--branch` names any valid ref);
only the projects user can push, since the sandbox account does not hold git credentials, and anyone with repository
access merges that branch back. Clones are labelled statically by `ai_tools.fc` and a plain `restorecon`, not
by `ai-tools-relabel`. `projects push` and the clone kind of `projects remove` gate the target
through `require_sandbox_clone`: a direct child of `SANDBOX_ROOT` that is a git worktree and passes the protected-paths
backstop, which scopes the `rm -rf` to one recognized clone.

The create is **lock-before-grant**. The clone is born owner-only (`umask 077` around the `git clone`), so a checked-in
credential is unreadable to the sandbox account from the first instant; `sandbox_finalize` then registers the allowlist
entry (the lockdown acts only on an allowlisted path; rolled back on a failed gate), runs the same secret gate
as a claim, and only past it opens the clone: `normalize_clone` adds group `rwX` and setgid directories while pruning
every path the gate locked, then the clone is labelled and registered. A declined or failed gate **fails closed**:
the clone stays on disk, private, unlabelled and unregistered, with a guard `CLAUDE.md` (sentinel
`ai-tools-lockdown-guard`) telling the agent to wait until the lockdown runs, a real `CLAUDE.md` preserved by `git mv`
to `CLAUDE.md.bak`, and the resume command printed. Re-running `projects clone` on the clone path resumes
`sandbox_finalize`, which removes the guard and restores the original on success. A resume is idempotent:
`normalize_clone` runs while the root is still owner-only (`clone_is_private`), the state the pinned umask
and a declined gate each leave, so a resume over an opened clone re-runs the gate and leaves the tree's modes alone,
and a directory the operator sealed inside it keeps its mode.

The shared area carries a `g:ai-ops:rwX` ACL (traverse on `/var/opt/ai-tools`, `rwX` plus default on `sandbox-projects`,
applied by `install.sh`), so an operator creates and works in clones without `SANDBOX_GROUP` membership —
the shared-area counterpart to the per-project `user:<operator>` grant. The agent is not in `ai-ops` (`ai-tools-run`
refuses to launch otherwise), so the grant adds it no access.

## Privilege model

The CLI is unprivileged. Every root helper it reaches — the `*_BIN` constants at the top of `ai-tools.sh` name the set —
runs via `sudo` with **no** NOPASSWD grant by design, so sudo prompts for the projects user's password, and the sandbox
account holds a grant for none. `stop` → `ai-tools-stop` is the exception, carrying the fixed-path zero-argument
NOPASSWD rule [launch](launch.rule.md) states. Each helper re-validates its target against the allowlist — per path,
over whichever operator's registry holds the project, since a secondary operator's claim and every
`projects claim --for` live outside the invoker's file — and shares the exclusion, secret-skip and skip-list rules
([ownership-and-hooks](ownership-and-hooks.rule.md)); why each one needs root is in its header. `ai-tools-allowlist`
needs root for the **read** as well as the write, since an allowlist is `0600` inside a `0700` directory in a home
the invoker cannot traverse, and authorizes against `SUDO_UID`, the uid sudo sets; `SUDO_USER` is a name the caller can
set. Repo-local `core.filemode` and the operator's own allowlist are unprivileged writes. `/usr/local/libexec/ai-tools`
is `750 root:root`, so the projects user cannot stat a helper and the CLI never pre-checks one; only sudo, as root,
reaches it.

Those calls assume a **general** sudo grant, a host-level axis `ai-ops` membership does not carry and this project
neither writes nor records ([CLAUDE.md](../../CLAUDE.md), [naming-conventions](../../docs/naming-conventions.md));
the CLI answers for it ahead of the run's first prompt ([The caller with no sudo
grant](#the-caller-with-no-sudo-grant)), and a `--for` run that writes the filesystem rides the same axis
through the runas seam ([The runas seam](#the-runas-seam-and-why-it-needs-a-grant---for-alone-does-not)).
`projects create` and `projects remove` add no helper and no sudoers rule.

## Secret pre-check on claim/clone <a id="ref-section-u5h3"></a>

Before granting access, the CLI runs `ai-tools-lockdown --gate`, one `sudo` call that lists the secret-matching files,
asks whether to lock them down, and locks them ([secret-handling](secret-handling.rule.md) states the `--gate`
contract); the helper's exit tells a lockdown that ran or found none (0) from a decline (6) and a failure. On a claim
the gate (`secret_gate`) runs whenever **any pending step widens the agent's access** — the setgid group change,
the group ACL, a drift repair, `.git` normalization, the SELinux label, an accepted traverse grant — and on every first
claim, since a tree can be group-accessible by setgid inheritance yet never scanned; the pure registry additions
(safedir, filemode) alone skip it. A declined or failed gate fails the operation closed: the claim aborts, rolling back
its own allowlist addition, and the clone stays private and unregistered under the guard `CLAUDE.md` ([Sandbox
clone](#sandbox-clone)). The gate exports the found paths (`SECRET_MATCH_PATHS`) so `normalize_clone` prunes them
from its group-access walk.

The gate covers what the steps after it expose, which is more than the claim's walks touch: those walks skip the shared
skip list, while the root's traversal, a skipped tree's own world bits and the recursive relabel reach
into `node_modules` and its kind, and `normalize_clone` opens them outright. So the scan does not take a skip list
and prunes only the `.git` subtrees git names itself, on a claim and on a clone alike; the set and why are the helper's,
stated in [secret-handling](secret-handling.rule.md).
