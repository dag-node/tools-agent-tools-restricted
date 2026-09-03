---
paths:
  - "src/opt/ai-tools/agents/*/settings.json"
  - "src/etc/claude-code/managed-settings.json"
---

# Claude Code settings (`settings.json`)

`settings.json` is the agent session's Claude Code configuration. It declares the
ownership hooks (covered in [ownership-and-hooks](ownership-and-hooks.rule.md)), the
token-saving filter hook on both `Bash` events (covered in [filters](filters.rule.md)), the
Bash-tool permission rules, an `env` block, the auto-mode default, and the observability
defaults. This rule covers the **permission rules** and how they couple to the SELinux policy,
the **`env` block**, the **observability defaults**, and the **`disableAutoMode`** default. The
catalog of other Claude Code
options an operator MAY add — and which are set elsewhere — is in
[`docs/claude-options.md`](../../docs/claude-options.md).

Settings coupled to the sandbox's layout rather than to Claude Code policy live in
`ai-tools-run`'s environment allowlist instead of here: `DISABLE_AUTOUPDATER=1` (the agent's
Node tree is not agent-writable, so in-session self-update fails; updates run out-of-band —
see [updater](updater.rule.md)) and the `HOME`/`PATH`/`CLAUDE_CONFIG_DIR` pins (see
[launch](launch.rule.md)).

## Permission rules — three outcomes

The two arrays sort a Bash command into one of three observable outcomes: **runs
without asking** (`allow`), **asks first** (unlisted — the default), or **refused**
(`deny`). None of this is a capability boundary — whatever runs still executes as
`SANDBOX_USER` confined by `ai_tools_t`, and a tool absent from the host simply fails
to resolve. The lists manage the **operator-visibility surface**: what is silent, what
is mediated by a prompt, and what the agent must raise with the operator in
conversation. JSON carries no comments, so the per-entry rationale lives here.

### Runs without asking (`allow`)

An entry earns its place by being **frequent** and **inspection-only**: it discloses
nothing beyond what the harness's dedicated read tools (Read/Grep/Glob) already access
without any Bash prompt, or it processes data already in hand.

**Project VCS state** — the working set every session touches:

| Entry | Why |
|---|---|
| `git status`, `git status *` | Working-tree state — the agent's most frequent check. |
| `git diff`, `git diff --staged*`, `git diff --cached*` | Pending and staged changes. Only these forms; other `git diff` arguments still prompt. |
| `git branch`, `git branch *` | Branch listing and context. The starred form also covers create/delete — accepted: branches are project-tree state the agent already fully writes. |

**Filesystem inspection and lint**:

| Entry | Why |
|---|---|
| `git log`, `git log *`, `git show`, `git show *`, `git blame *` | Project history — what changed, when, in which commit. |
| `shellcheck *`, `rpmlint *`, `yamllint *` | Lint project sources in-session instead of pushing the first lint to CI. Host-provided (EPEL packages all three on EL; `install.sh` suggests whichever the enabled repos offer, print-only — it never installs them or enables a repo). |
| `jq *` | Filter/inspect JSON already in hand (tool output, configs). |
| `ls`, `ls *`, `tree`, `tree *` | Listings with owner/mode — the ownership model's primary observable. |
| `stat *`, `getfacl *` | Per-path owner/mode/context and the collaborative-ownership ACL grants — diagnose handback and claim state ([ownership-and-hooks](ownership-and-hooks.rule.md)). |
| `head *`, `tail *`, `wc *`, `sort`, `sort *`, `uniq`, `uniq *`, `grep *` | Pipeline staples that bound and filter the output of the commands above. |
| `file *` | Identify a file's type before reading it. |

### A rewritten command is what these rules match

The `PreToolUse` filter hook may narrow a Bash command before it runs
([filters](filters.rule.md)). It returns no permission decision, so the three outcomes above are
decided on the **rewritten** command. Two consequences bound what a rule may do:

- A rule that only inserts arguments after the leading words leaves every entry here matching as
  written — `Bash(git log *)` covers `git log --format=… -- src/x.c`, so a narrowing rule needs no
  allow entry of its own.
- A rule that changes the leading command word is matched as that new command, and an entry broad
  enough to cover a general-purpose wrapper (`Bash(<wrapper> *)`) is broader than the
  inspection-only criterion this list holds to. Narrow per-command entries are the form that fits.

A `deny` entry overrides a rewrite in either shape, so no rule can turn a refused command into a
permitted one.

### Asks first (everything unlisted)

The default for a command in neither list — mutations (`chmod`, `git push`, …) and
one-off tools. One caveat bounds what "unlisted" buys: the harness's own command
analysis auto-approves commands it classifies as safe reads, **past both the allow list
and the prompt** (verified empirically: `df` ran silently in a session whose local
settings layers were empty, while `ls > file` in the same session prompted — the same
analysis reclassifies a redirect as a write). An unlisted safe-read therefore does
**not** reliably prompt; a read that must stay operator-visible needs a `deny` entry,
which is why the host-survey group below is denied rather than merely unlisted.

### Refused (`deny`)

Three groups with distinct criteria.

**Irreversible VCS operations** — these **succeed**, and what they take has no undo: history
rewritten, a published branch overwritten for everyone else holding it, uncommitted or untracked
work deleted from the tree.

| Entry | What it destroys |
|---|---|
| `git push --force*` | The remote's history for every other clone. The pattern also covers `--force-with-lease`, which narrows the race but still overwrites. |
| `git push -f *` | The short spelling of the same. |
| `git reset --hard*` | The working tree and index, including changes never committed. |
| `git clean -f*` | Untracked files — the ones no commit and no reflog can bring back. |

The criterion is **destruction with no undo**, so the refusal holds regardless of target: a
scratch branch and `main` are denied alike, because a deny rule matches a command string and
cannot tell them apart. These would prompt if merely unlisted (they are mutations, not the
auto-approved safe reads of the host-survey group), and a prompt is the wrong gate for them —
it approves a command string, while what the operator has to weigh is what is about to be lost.
Denied, the agent raises the operation in conversation, and the operator runs it where the
consequence lands.

The group is deliberately narrow, and it is a gate rather than a boundary: the same destruction
is still reachable through a spelling the pattern does not match (`--force` placed after the
refspec, `git push origin +branch`, an `rm -rf` of the work tree), and matching those would take
a matcher over intent rather than over text. What it buys is that the **habitual** spellings —
the ones an agent reaches for without deliberating — cannot be taken silently.

**Categorical dead-ends** — the core posture refuses these regardless of arguments or
target, so a deny stops the agent spending a tool call, and emitting an AVC, on an
action the kernel refuses anyway:

- `sudo`, `su` — SUID is inoperative under the session's `PR_SET_NO_NEW_PRIVS` (see
  below), so both fail by construction.
- `journalctl`, `systemctl` — the SELinux core module denies talking to the
  user/system manager and reading the journal.
- `ausearch`/`auditctl`/`aureport` — the core module denies the audit surface.
- `dnf`, `yum` — package management is the `pkgmgmt` optional group, disabled by
  default; with it off the core module refuses the package-manager stack.
- `mount *`, `umount` — mounting needs `CAP_SYS_ADMIN`, and `RestrictNamespaces=yes`
  closes the user-namespace route to it. (Bare `mount` succeeds — it lists the mount
  table — so it is denied with the host-survey group below instead.)
- `setenforce`/`semodule`/`semanage` — root-only SELinux management; label repair flows
  through the root-side relabel path, never the agent.

`sudo` is the purest case: it is structurally inoperative under the session's
`PR_SET_NO_NEW_PRIVS`, which drops the SUID bit (see [confinement](confinement.rule.md)),
so its deny entry corresponds to a capability no policy change can restore — pure noise
suppression. A command that fails only situationally does not belong in this group (see
Why not).

**Host-survey queries** — these **succeed** but disclose system state beyond the
file-read baseline, and the harness's safe-read auto-approval means an unlisted one runs
silently (see "Asks first"). `deny` is the one settings layer that overrides that
auto-approval, so the set ships denied. This is stronger mediation than a prompt, not
weaker: the agent that genuinely needs one must ask the operator in conversation, with
its reasoning, instead of the operator approving a bare command string. A host that
wants one silent removes the deny entry in its settings layer.

| Entry | What it discloses |
|---|---|
| `id`, `id *`, `getent *` | Account and group enumeration — NSS can reach a directory service (sssd/LDAP), beyond local file reads. |
| `rpm`, `rpm *` | Installed-package inventory — a classic reconnaissance target (the write forms fail as non-root anyway). |
| `ps`, `ps *` | Host-wide process survey. |
| `df`, `df *`, `du`, `du *`, `mount` | Mount/storage topology and tree-size surveys. |
| `readlink *` | Runtime layout via `/proc` magic links; benign in-project symlink inspection is covered by the allowed `ls -l`. |
| `getenforce`, `matchpathcon *` | Security-posture probing — whether enforcement is on, which labels are expected. When diagnosing confinement *with* the operator, the operator runs them or relaxes the entry. |

This layer is a **tooling hint, not a boundary.** The enforced isolation is SELinux type
enforcement plus DAC (see [confinement](confinement.rule.md)); a `deny` entry only keeps
the agent from attempting a denied action. Removing an entry re-exposes the attempt to the
SELinux floor — it does not by itself grant the capability.

`tests/integration/hooks.sh` pins all three deny groups at install time (the verify phase
runs it): a missing categorical or irreversible-VCS entry fails; host-survey relaxations are
reported by name and pass, but a file with none of them (a kept pre-upgrade settings.json)
fails; an entry in both lists fails as drift. The irreversible-VCS entries are pinned
strictly rather than reported, because the paths that preserve a host's tuning — the
keep-existing install and `%config(noreplace)` on upgrade — are also the paths by which a
settings.json predating them, or edited in the permission arrays it invites tuning of,
silently loses the gate.

## The tool-call record is declared as its own matcher group

`post-tool-hook.sh` appears twice under `PostToolUse`: argument-less on `Write|Edit` (record
then hand back) and as `post-tool-hook.sh record` on `Bash` (record only). One widened
`Write|Edit|Bash` matcher would express the same intent in a single group and **would not reach
an upgraded host**: `ai_tools_conf_merge_hook_declarations` keys on the *command string*, not on
the matcher, so a kept `settings.json` already declaring that command counts the group as
present and the widened matcher is never merged in. The `Bash` records would then be emitted on
a fresh install and silently nowhere else — precisely the failure the merge exists to prevent.
A distinct argument makes it a distinct command string, so the merge carries it like any other
newly shipped declaration. This is the same dispatch-on-`$1` shape `session-hook.sh` and
`filter-hook.sh` already use, and it is why the argument-less form must stay argument-less:
renaming it would leave the old declaration in place beside the new one and run the handback
twice per write.

## `env` — the privacy and output defaults

The top-level `env` block applies environment variables to every session. It ships two
entries:

```json
"env": {
  "CLAUDE_CODE_MAX_OUTPUT_TOKENS": 131072,
  "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
}
```

`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` opts the session out of all non-essential
outbound traffic in one variable: it subsumes `DISABLE_TELEMETRY`,
`DISABLE_ERROR_REPORTING`, `DISABLE_FEEDBACK_COMMAND`, and
`CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY`, so the four are redundant beside it and are not set
individually. The essential Anthropic API traffic the agent needs is unaffected, as is the
WebFetch domain safety check (which has its own `skipWebFetchPreflight` opt-out, left on).

`CLAUDE_CODE_MAX_OUTPUT_TOKENS=131072` sets the per-response output-token cap a session
requests. It shapes response length and cost, not authority — a capped and an uncapped session
may do exactly the same things.

Both live here rather than in `ai-tools-run`'s allowlist because they are Claude Code product
policy, not confinement structure — Claude Code's own config surface, beside the permission
and hook declarations. Layering and override are under "Control-plane integrity" below.

## `showThinkingSummaries` and `verbose` — the observability defaults

```json
"showThinkingSummaries": true,
"verbose": true
```

Both put more of a session in front of the operator watching it: `showThinkingSummaries` re-shows
the thinking blocks Claude Code hides by default, and `verbose` shows Bash and command output in
full rather than truncated. They cost terminal space and nothing else — the session's authority is
identical either way — and what they buy is that the operator confirming an action sees the
reasoning that produced it and the output it produced, which is the difference between approving a
command string and approving what the command did.

They are the operator-side complement to `disableAutoMode` below: that key decides *whether* a
human is asked, these decide *how much* that human is shown. The catalog of the other UI and
behavior keys an operator MAY add is in
[`docs/claude-options.md`](../../docs/claude-options.md).

## `disableAutoMode` — confirm-by-default

```json
"disableAutoMode": "disable"
```

`"disable"` removes `auto` from the `Shift+Tab` permission-mode cycle and rejects
`--permission-mode auto` at startup, so a session takes actions under a confirming
permission mode rather than acting autonomously. The value is the literal string
`"disable"`; the key absent (or any other value) leaves auto mode selectable.

The default keeps a human in the loop for the outward-facing, irreversible actions a
session reaches — commits, pushes, other state-changing Bash commands — which the sandbox
confines but does not gate on confirmation. It is a control-plane default, overridable per
project (see "Control-plane integrity" below).

## Coupling to optional SELinux groups

The deny list is matched to the **core** policy alone. Enabling an optional SELinux group
(`install-selinux.sh enable-group <name>` — `systemd`, `pkgmgmt`, `netadmin`, `podman`,
all disabled by default; see [confinement](confinement.rule.md)) widens what `ai_tools_t`
may do, but a `deny` entry here still blocks the matching command **before** SELinux is
consulted. A capability a group newly grants stays unreachable until its deny entry is
relaxed in the same change.

For example, enabling the `systemd` group so the agent can drive its own services has no
effect while `Bash(systemctl*)` and `Bash(journalctl*)` remain in `deny`: the tool
refuses the command first. An operator who enables a group relaxes the corresponding deny
entry alongside it. The audit CLIs map to no optional group today; granting them needs a
new policy module, and the same relax-the-deny-entry step applies.

## Control-plane integrity

`settings.json` is root-owned (`root:SANDBOX_GROUP`, no group write) and lives under
the setgid+sticky `.claude` directory, so the agent cannot edit or replace **this file**
from inside a session (see [ownership-and-hooks](ownership-and-hooks.rule.md)). It is the
user-level settings layer; Claude Code merges a higher-precedence **project** layer
(`.claude/settings.local.json`, then `.claude/settings.json`) over it, and that layer lives
in the agent-writable project tree. The layers compose differently per setting:

- The **deny rules** and **hook declarations** merge additively across every layer — a
  deny from any source wins over any allow, and project hooks add to rather than replace
  these — so a project layer cannot remove them. They hold for the whole session.
- The **`env` block**, the **observability defaults**, and **`disableAutoMode`** are
  single-valued: a higher-precedence project layer overrides them per key — control-plane
  defaults, not locks. None is a containment boundary (telemetry and an output cap are not
  one, the observability keys only change how much is displayed, and `disableAutoMode` only
  removes confirmation prompts; the session's confinement is unchanged either way), so a lock
  is unneeded. The one unoverridable layer, managed policy
  (`/etc/claude-code/managed-settings.json`), is machine-wide — it applies to every Claude
  Code user on the host — so the sandbox does not ship it.

### An upgrade keeps host tuning and still lands this version's hooks

An install **keeps** an existing `settings.json` by default (`install.sh`'s `keep_existing`
prompt; an unattended run always keeps), because the file carries host tuning a reset would
revert — a deny entry relaxed alongside an enabled SELinux group, an added `env` key. Kept
files then have this version's **hook declarations** merged in
(`ai_tools_conf_merge_hook_declarations`, in `conf.lib.sh`): each shipped declaration the
file does not carry is added,
every other key — the permission arrays it was kept for, an operator's own hook — is left as
written, and each addition is named in the install log.

The split follows the layering above: hook declarations are control plane that merges
additively and that no lower-precedence layer may remove, while the permission rules are the
host's to tune. The merge is what carries a newly shipped hook onto an existing host: its body
and data arrive with the package, and this is the step that makes the file declare it, so the
hook runs rather than sitting installed and uninvoked.

Each outcome is reported at the severity it earns, so neither is lost in an install's output:
a merge reports at `ok` and **names every declaration it added**, which is what makes an edit
to an operator-owned file reviewable. A file already declaring everything shipped is not
rewritten.

Two sidecar files serve two different recoveries, and neither substitutes for the other:

| file | written when | answers |
|---|---|---|
| `settings.json.<YYYYMMDD>.bak` | a merge is about to replace the file | "what did I have?" — the only copy that can restore host tuning if a merge produces valid JSON that is nonetheless wrong, the one failure a parse check cannot catch |
| `settings.json.<YYYYMMDD>.shipped` | a merge could **not** run — absent `jq`, malformed JSON, a result that does not parse | "what was I supposed to get?" — the baseline to merge from by hand, since an RPM-installed host has no source checkout to copy from |

Each failure direction leaves the deployed file byte-identical and warns, naming which check
refused. Both sidecars are date-stamped and neither overwrites an earlier copy, and a no-op run
writes neither. They differ in what a repeat run produces, because they record different things:
a `.bak` records that a run replaced the file, so every rewrite writes one, while a `.shipped`
records the baseline that was on offer, so a refusal resolves to the copy already beside the file
when its content matches and dates a new one only for a baseline the directory does not hold. A
host re-running the installer therefore holds one `.shipped` per **different** baseline it was
offered. The suffix is deliberately not `.rpmnew` — no rpm transaction produced it, and rpm's
suffix would both claim a provenance it lacks and hand the file to the tooling that sweeps rpm
leftovers.

**On an RPM host the same merge runs on request.** `settings.json` is `%config(noreplace)`, so an
upgrade keeps a file the host edited and parks this version's copy as `settings.json.rpmnew`. A
file the host never edited is replaced outright and its hook declarations are current with no
operator step.

No rpm directive resolves the split on its own, because rpm has no vocabulary for merging one
subtree of a file: plain `%config` would install the shipped file and move the host's aside to
`.rpmsave`, reverting the permission rules the file was kept for, while `%config(noreplace)` alone
leaves a newly shipped hook declared nowhere. The merge therefore runs on request —
**`sudo ai-tools-admin postupgrade`**, through the same `conf.lib.sh` entry point — and the agent
package's `%post` prints that pointer whenever a `.rpmnew` is present. No scriptlet edits a config
file.

The command runs the merge on a throwaway copy first, so the list it shows is the exact set of
declarations the real merge adds rather than a promise of one. It then confirms, writes the dated
`.bak`, names that backup, and offers to drop the `.rpmnew` against what is actually left: the
cleanup prompt defaults to yes once the two files match, and to no while the permission rules still
differ. A refusal on this path needs no `.shipped` sidecar — the `.rpmnew` is that baseline, and
the throwaway copy is where the refused merge's own copy lands and is discarded.

`jq` is a hard runtime dependency of every hook this agent ships, not a convenience: each
parses its event JSON with it, and absent it they take their no-op paths silently — the
handback stops returning ownership, the session sweeps stop running, and the filters stop
filtering. The agent package `Requires: jq` for that reason.

## Why not

- **Denying `chmod`/`chown` and other target-dependent refusals**: they succeed on
  agent-owned files (the routine case — making a generated script executable) and fail
  only on operator-owned ones; a deny rule matches the command string, not the target's
  owner, so it would break the valid majority to suppress an occasional EPERM — and that
  EPERM is informative (it names the file as the operator's; the agent asks instead of
  retrying). A deny here also reduces no surface: mode changes are reachable through
  `install -m`, `cp -p`, `setfacl`, `os.chmod`, …, and the abuse-shaped forms
  (`777`/`o+w`/`+s`) are already reverted by the handback's world-bit stripping while
  setuid on a sandbox-owned file escalates nothing. The same reasoning keeps a
  "safe subset" like `chmod +x *` out of `allow`: the allow list stays inspection-only
  so its criterion stays crisp.
- **Filtering `allow` to the host's installed tools** (at install or after): an entry for
  an absent tool is inert — the command fails to resolve — and *removing* it makes the
  interaction worse (the operator gets prompted for a tool that then fails anyway). A
  filtered file also drifts from the package (`rpm -V` flags the root-of-trust file), goes
  stale the moment an admin installs a tool afterwards, and the keep-existing install
  prompt then preserves the stale filter across reinstalls. Host- or project-specific
  tuning layers **additively** via Claude Code's settings merge; the shipped baseline
  stays byte-identical on every host.
- **Leaving the host-survey reads unlisted (or allowing them) instead of denying**: no
  capability is at stake either way (DAC + `ai_tools_t` decide), but "unlisted" does not
  mean "prompted" — the harness's safe-read analysis auto-approves them silently (see
  "Asks first"), and allowing them would make that silence official. Only a deny keeps
  reconnaissance-shaped queries operator-mediated, by forcing the agent to ask in
  conversation.

## Deferred

The deny list and optional-group enablement are kept in sync **by hand** — nothing links
`enable-group` to relaxing the matching deny entry, so a group enabled on its own has no
effect at the tooling layer. A durable fix derives the deny set from the loaded policy
groups, or has `enable-group` adjust `settings.json`, so the two layers cannot drift.
