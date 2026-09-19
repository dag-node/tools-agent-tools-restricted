---
paths:
  - "src/usr/local/bin/codex.sh"
  - "src/usr/local/lib/ai-tools/agents.d/codex.conf"
  - "src/usr/local/lib/ai-tools/session-env.d/codex.env.sh"
  - "src/etc/codex/**"
  - "src/opt/ai-tools/agents/codex/**"
---

# The codex agent

Everything specific to Codex as a provider: what its manifest declares, how its launcher chain ends on the vendor
binary, its launch wrapper, the two managed files codex reads from `/etc/codex`, its hooks, and where the shared skills
and the orientation text reach it. The **provider seam** these plug into — manifests, fail-closed enablement,
the `session-env.d` contract, the `launcher_target` re-link — is [providers](providers.rule.md); the **agent-agnostic**
launch contract is [launch](launch.rule.md); the ownership handback and the sweep are
[ownership-and-hooks](ownership-and-hooks.rule.md). The claude-code counterpart of every item here is
[agent-claude-code](agent-claude-code.rule.md), and where the two differ the difference is stated in this rule.

`ai-tools-agents-codex-restricted` ships the wrapper, the manifest, the session-env fragment, the two managed files
with a pristine copy of each, the two hooks, and the agent's config directory. Like every agent package it ships
`default_enable=no`: `codex` is provisioned and launched once `AI_TOOLS_AGENTS` names it, which the bootstrap writes
for the agent an operator chooses ([providers](providers.rule.md)). It does not add a sudoers rule: it inherits
the single `%ai-ops` grant on the shared shim. `install.sh` lays down the same files from the source tree, beside
the claude-code ones, and runs what the package's `%post` runs — the `3770` mode of the config directory, the skills
link, the orientation link — so a from-source host carries the package whole; its `uninstall` removes the wrapper,
the hooks, the managed files and the pristine copies, and the skills link where it is managed, leaving the agent's state
under `.codex` as it leaves claude's.

## The boundary is the host's; codex's configuration is not a security control

Every guarantee this project states for a codex session rests on the host — DAC, the `ai_tools_t` domain, the session
unit's properties, the launch chain, the handback — exactly as it does for claude. Which files codex reads, which keys
it takes, and what a refused flag falls back to are the vendor's to change between releases; the package ships
that configuration so a session works and does not break its own tool calls. A codex release that takes other keys
refuses to start (every subcommand exits 1 naming the key) or starts with tool calls that fail: a loud functional
failure, and a documentation change, never a change of access. The two managed files are edited by an operator holding
sudo to that release's keys, and the host's boundary stays where it is.

**The pin that reads as "no sandbox" is what keeps the host's sandbox closed.** The package pins codex
to `danger-full-access`. Codex's own sandbox is bubblewrap, which needs an unprivileged user namespace; the session unit
refuses namespaces (`RestrictNamespaces=yes`, [confinement](confinement.rule.md)), and that refusal is a load-bearing
invariant of the host's confinement. Letting codex sandbox itself would mean opening that refusal — the real widening.
`danger-full-access` therefore means "codex adds no sandbox of its own, and the host's DAC plus `ai_tools_t` is
the boundary", as for claude, and it is the vendor's own documented recipe for running inside an outer sandbox. The name
is the vendor's; the containment is the host's.

## What the manifest declares

`/usr/local/lib/ai-tools/agents.d/codex.conf`, `644 root:root`, parsed by `providers.lib.sh`:

| field | value | read by |
|---|---|---|
| `npm_package` | `@openai/codex` | `ai-tools-bootstrap`, `nvm-update` — what to install |
| `launcher` | `codex` | `ai-tools-launcher-symlink` (which link it may write), `ai-tools-run` (which executables may start a session) |
| `launcher_target` | the vendor binary's path inside the version directory, under `…/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex` | `ai-tools-bootstrap`, `nvm-update` — where `<version-dir>/bin/codex` is re-linked after each install ([providers](providers.rule.md)) |
| `display_name` | `Codex` | the launch banner, the unit description |
| `handback` | `none` | `ai-tools-run` — the shim sweeps the project at session end (see [Handback](#handback-the-shims-sweep-is-the-guarantee-the-hooks-are-the-cadence)) |
| `config_dir` | `.codex` | the control-plane mode/label set, and `→ ai_tools_home_t`; the fragment pins `CODEX_HOME` there |
| `memory_file` | `AGENTS.md` | where the shared orientation text is linked — the global-scope instructions codex reads first ([shipped-assets](shipped-assets.rule.md)) |
| `managed_files` | `/etc/codex/requirements.toml`, `/etc/codex/managed_config.toml` | `ai-tools status` and `ai-tools-admin status` — which live files to compare against the pristine copies under `/usr/share/ai-tools/codex/` ([providers](providers.rule.md)) |
| `entrypoint_fcontext` | a regex ending on the same vendor path `launcher_target` names | `ai-tools-relabel-agent` — which file takes `ai_tools_exec_t` |
| `default_enable` | `no` | every agent manifest's value: the agents' baseline is empty, and the bootstrap writes the enabled set |

Not declared, and why: `skills_dir` and `subagents_dir`, because codex reads skills from its admin scope
(`/etc/codex/skills`, not a directory inside `CODEX_HOME`) and its sub-agent roles are a different shape from the shared
subagent definitions; and the three release-verification fields, because the npm channel does not publish a signed
per-release checksum manifest. The launch is therefore `unpinned`, and a host that sets
`AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY` does not launch codex ([updater](updater.rule.md)). `tests/unit/codex-package.sh`
asserts each of these.

## The resolution chain ends on the vendor binary, by the re-link

npm nests the platform package under the meta-package and links `<version-dir>/bin/codex` at `bin/codex.js`,
a JavaScript shim that spawns the binary. That shim is not the file the session runs and not the file
`entrypoint_fcontext` names, so the toolchain re-links the versioned launcher at `launcher_target` after every install
and before the stable symlink is repointed:

```
/opt/ai-tools/bin/codex                                          [1] stable launcher symlink
  └─ readlink, one hop ────────────────────────────────────────────────────────────────────────
/opt/ai-tools/.nvm/versions/node/vX.Y.Z/bin/codex                [2] versioned launcher, RE-LINKED by the toolchain
  └─ ../lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex
…/vendor/x86_64-unknown-linux-musl/bin/codex                     [3] the vendor binary: static, the one inode
```

The three consumers take the same links they take for claude ([agent-claude-code](agent-claude-code.rule.md)):
the wrapper reads **[1]** one hop to **[2]**, `ai-tools-run` re-validates **[2]** and requires its target to stay inside
the same version directory, the SELinux transition fires on **[3]**. What the re-link buys is that **[3]** is the file
the manifest's pattern covers, so the relabel reconciliation reads `ok` and the launch preflight finds `ai_tools_exec_t`
on the inode it executes. A host where the re-link was refused — a target escaping the version directory,
a non-executable, a pattern that does not cover it — keeps npm's link to `codex.js`, which carries the default `lib_t`,
and the launch fails closed at the label preflight: the same state a host with no such key is
in ([providers](providers.rule.md), [updater](updater.rule.md)).

The binary's vendored helpers (`bwrap`, `rg`, `zsh`, `codex-code-mode-host`) sit beside it and stay `lib_t`,
which `ai_tools_t` executes like every other program on the toolchain
([ref-section-w4z6](confinement.rule.md#ref-section-w4z6)): a session searches with codex's own `rg`, and the audit
record of a refused read names it. The transition in `ai_tools.te` is keyed on `ai_tools_exec_t`, so the user manager
enters `ai_tools_t` on that type alone. The manifest names the one binary that carries it, so a helper a later release
adds beside it runs as a program and is not the file a launch transitions on.

The binary is also its own helper set. At session start codex stages symlinks to **[3]**
under `$CODEX_HOME/tmp/arg0/<random>/`, named `apply_patch`, `applypatch`, `codex-execve-wrapper`
and `codex-linux-sandbox`, and removes the directory at exit; an `apply_patch` edit execs the entrypoint inode
through one of them, which `ai_tools_t`'s `execute_no_trans` on `ai_tools_exec_t` permits. The main process keeps
the real path as `argv[0]` and `exe`, and a shell command is a direct `bash` child of it. That exec is why the grant
stays in the core module; what else a session may start through it is in [launch](launch.rule.md).

## The wrapper (`codex.sh`)

`/usr/local/bin/codex`, `root:root 0755`, rpm-owned, running as the invoking operator. It is the shared gate library
alone: it sources `launch-wrapper.lib.sh` fail-closed, calls `ai_tools_launch_init codex`, runs
`ai_tools_launch_gates "$@"`, and ends in `ai_tools_launch_session "$@"`. The gate order — required libraries,
the operator gate, binary resolution, the print-and-exit short-circuit, the protected-paths backstop and the allowlist,
the claim guard, the service-health warning, the `exec` — is the library's and is stated once
in [launch](launch.rule.md). Codex has no launch input of its own: a custom system prompt and a custom endpoint are keys
of `managed_config.toml`, read by codex itself, so no resolver sits between the gates and the session and the operator's
arguments go through as typed.

The one refusal the wrapper carries itself — the gate library will not load — cites `MSG-R3Q4`, the code claude's
wrapper defines for the same situation: one situation, two wrappers, one token to search
([messaging](messaging.rule.md)). `path-order.lib.sh` reads every enabled agent's launcher, so an operator's shell
that would find another `codex` ahead of `/usr/local/bin` is reported for this launcher exactly as for `claude`
([launch](launch.rule.md)).

## The two managed files (`/etc/codex`)

Codex reads two root-owned files from a fixed path, and the package ships both as `0644 root:root`,
`%config(noreplace)`: an operator's edit survives an upgrade, and a newer copy lands beside it as `.rpmnew`,
which the package's `%post` names. Each carries a header stating the codex release its keys were measured
against and the contract in [The boundary is
the host's](#the-boundary-is-the-hosts-codexs-configuration-is-not-a-security-control). Both hold to the config-header
form ([providers](providers.rule.md)): 72 columns, and every bare key **ahead of the first table header** — a bare key
written after one is that table's key and is silently ignored, which is how two harness runs measured a pin
as "accepted" that codex never read.

**`requirements.toml`** is what a session cannot override. `allowed_sandbox_modes` lists `read-only`
and `danger-full-access` (codex refuses the list without `read-only`); `default_permissions`
and the `[allowed_permission_profiles]` table name full access alone, so a session that selects another mode —
a `--sandbox` flag, a `-c` override, a profile, a relocated `CODEX_HOME` — lands on the managed default with no notice;
`allowed_approval_policies = ["never"]`; `allowed_login_methods = ["chatgpt"]` bounds the account type
to the subscription login (an API key through a root-placed `auth.json` is the optional path); `[marketplaces]` is
restricted with no allowed source; and `allow_managed_hooks_only = true` with the `[hooks]` table makes the package's
hooks the only hooks — a user `hooks.json` does not run.

Its `[rules]` table is the **per-command deny layer**, codex's counterpart to `settings.json`'s deny groups
([claude-settings](claude-settings.rule.md)), and it carries **two** of that layer's three groups, held to the same
criteria. The **irreversible VCS** rows are destruction with no undo, unprivileged, in the operator's own tree, where no
host control refuses: `git push` with `-f`/`--force`/`--force-with-lease`/`--force-if-includes`, `git reset --hard`,
and `git clean`. The **host-survey** rows are commands that run as the sandbox account and disclose host state beyond
the file-read baseline: `id`, `getent`, `rpm`, `ps`, `df`, `du`, `mount`, `readlink`, `getenforce`, `matchpathcon`.
Thirteen rows, each `decision = "forbidden"` with a justification codex surfaces in the refusal. A requirements rule
takes `prompt` or `forbidden` and never `allow`, and the most restrictive match wins, so the table narrows a session
and cannot widen one.

The third group, the **categorical dead-ends** (`sudo`, `systemctl`, `dnf`, …), is left out: `NoNewPrivileges`
and the confined domain refuse those already, so a row would buy a message and no mediation. The survey group is the one
that does **not** divide that way — each of its commands succeeds — so a row is the only thing standing
between the session and the command. **The two agents arrive there from opposite defaults, as this project configures
each**, and the comparison is worth stating in those terms rather than as attended against unattended. claude-code ships
with auto mode off (`disableAutoMode`, [claude-settings](claude-settings.rule.md)), so it asks before a command it is
not configured to allow; its deny entry is needed because the harness auto-approves a **safe read** without asking,
and a host-survey command reads as one. Codex is pinned to `allowed_approval_policies = ["never"]`, so it asks in no
session at all — interactive or `codex exec` alike — and the table is the whole of its per-command mediation. An agent
that needs one of these raises it in the session with its reasoning, and the operator runs it.

**The table is a narrower instrument than claude-code's, not a stronger one.** A row that matches refuses, on either
agent; what differs is how much a row matches, and the exact-prefix grammar this section describes next catches **less**
than a glob does. So the layer's worth is the bargain the VCS rows are held to — it takes the habitual spelling
out of the shell and puts it in front of the operator — and neither agent's table is a boundary. What bounds a session
is the sandbox account, the domain and the unit.

A pattern is an **exact prefix** of the command's arguments, matched token by token, so `git push origin main --force`
does not match — the reach `Bash(git push --force*)` has too, and the same bargain: what the layer buys is
that the habitual spelling cannot be taken silently. One spelling is **narrower** here than claude-code's, since a token
is matched whole: `--force-with-lease=main` is a single token equal to none of the four in the `any_of` list,
where the glob `--force*` covers it. A row per `=`-suffixed form would enumerate what a later git release may extend,
so the bargain is what the row claims rather than coverage of every spelling. The prefix grammar is also why each survey
command is **one** row where claude-code needs a pair (`Bash(ps)` and `Bash(ps *)`): a single-token pattern is a prefix
of both the bare command and every argument form. `git clean` is refused as a whole verb rather than by flag, the one
row wider than claude-code's, since its destructive spellings (`-f`, `-fd`, `-ffd`, `-xf`, …) are one token each
and an enumeration leaks the one it misses. `unit/codex-package.sh` pins the rows and that no decision reads `allow`;
`integration/hooks.sh` pins them in the deployed file, which is where an operator's edit is kept across an upgrade.

**A refusal reaches the model and does not wait for anyone.** Since codex asks in no session, the open question was
what a refusal does where there is nobody to ask — `codex exec`, the shape a scheduled or scripted run takes, is
where a decision wanting an answer would block until its timeout. Measured on codex 0.155, one `codex exec` turn
per group: asked to run `git clean -fd`, and asked to run `ps aux`. Each completed at exit 0 with the command not run,
and the model reported the refusal quoting that row's own `justification` back. So `forbidden` is the decision both
groups take. The only other decision a requirements rule offers is `prompt`, which puts the command to the operator
for approval — and in a session pinned never to ask, run by a schedule or a script, there is nobody present to answer
it. `forbidden` is therefore the one of the two that resolves without a person in the room.

Three properties of the matcher are read off those two runs, and each is why a row is written the way it is. The refusal
names `/usr/bin/bash -lc '<command>'`, so codex matches the **inner** command rather than the shell invocation carrying
it. A **one-token** pattern matched `ps aux`, which is what lets one row stand where claude-code's glob layer needs
a pair. And the `justification` is the text the model receives, so it is written as the reason an operator would give,
not as a policy label.

**`managed_config.toml`** is the defaults codex applies ahead of any user config: the mode and the approval policy
the requirements pin, `check_for_update_on_startup = false` (the `nvm-update` timer maintains the toolchain,
and the Node tree is read-only to the session), `[agents] enabled = false`, `[tui] animations = false`
and `notifications = false` (a session runs under a service account on a terminal an operator may be reading over ssh:
an animation redraws a line that reports nothing new, and a notification reaches the desktop of someone who did not
start the session), and the `[analytics]`, `[feedback]` and `[otel]` opt-outs. The opt-outs are **dispositional**:
a release that reads other keys posts again, and the residual is on the API's own domain. Two operator keys ship
commented, each the codex counterpart of a claude-code `operator.conf` key: `model_instructions_file` (replaces
the built-in instructions; the file sits under `/etc/ai-tools/prompts`, the one root the confined domain reads)
and `openai_base_url` (the API-key path only).

What neither file can do is enlarge what the account may reach, since codex runs as that account in that domain.
An unreadable `requirements.toml` refuses the start: the loud direction.

**A kept file is reported, never overwritten.** The package ships a pristine copy of each managed file
under `/usr/share/ai-tools/codex/`, the manifest names both in `managed_files`, and the two status reports compare
the live file against its copy through `ai_tools_managed_file_state` ([providers](providers.rule.md)): a file
that differs prints the two consequences — codex reads the live file alone, so a key this release adds is not in it,
and what it declares is the host's — with the copy's path, and is not counted toward the exit status, since an edited
managed file is a supported state; a missing one is counted, since the package is then broken and a reinstall is
the remedy. `install.sh` says the same at install time, on the kept file's own line. The report is where an operator
learns a `.rpmnew` was parked, or a from-source install kept an edit, after the install output has scrolled by.

## Handback: the shim's sweep is the guarantee, the hooks are the cadence

The manifest declares `handback=none`, **and** the package ships hooks. That is the hybrid, and `none` is the stronger
declaration here: `ai-tools-run` traps `EXIT` and sweeps the project for every declaration but the literal `hooks`
([providers](providers.rule.md)), so a session converges at exit whether or not codex ran a hook, and the managed
`PostToolUse` and `Stop` hooks converge the tree per call and per turn on top of it. `handback=hooks` would switch
the shim's sweep **off** and leave convergence to a driver codex enforces — a release that stopped running managed hooks
would then leave the tree sandbox-owned with no sweep behind it. The cost is one sweep per session over the project
tree, redundant on a session whose hooks all ran. What neither covers is the same as for claude: a `SIGKILL`
or `ai-tools stop` leaves in-flight writes to the next session's `SessionStart` pass, the next shim sweep,
or `ai-tools projects handback`.

The hooks live in the config directory, `750 root:SANDBOX_GROUP` under the sticky `.codex`, and are declared
in `requirements.toml` with the argument each dispatches on. They are adapters of claude's to codex's payload shapes,
which differ in the write tool and in none of the keys the sweep reads (`cwd` and `source` arrive under the same keys):

| event | matcher | runs | what differs from claude |
|---|---|---|---|
| `PostToolUse` | `.*` | `post-tool-hook.sh` | one entry for every tool: records the call (a `Bash` call carries `tool_input.command`, as claude's does), and for an `apply_patch` call hands back each file the patch names. Codex has no `Write`/`Edit` carrying a `file_path`; a write is an `apply_patch` whose `tool_input` carries the patch text (read under every spelling the vendor has used — `input`, `patch`, and the `command` key 0.154 sends, shared with `Bash` but reached only on the patch branch), so the paths come from its `*** Add File:` / `*** Update File:` / `*** Delete File:` / `*** Move to:` lines, a relative one joined to the event's `cwd`. The record carries the first path and, past one, the count |
| `Stop` | — | `session-hook.sh`, `timeout = 600` | the per-turn sweep, sized to the timeout: codex holds a `Stop` hook to its declared timeout and kills it hard past it, with no grace |
| `SessionStart` | `startup\|resume` | `session-hook.sh session-start`, `timeout = 60` | the unbounded pass, the setgid normalization, the `.git` reclaim; the matcher selects the two sources the pass acts on, and the script holds the same line |
| `SessionEnd` | — | `session-hook.sh session-end`, `timeout = 3` | codex caps `SessionEnd` at 3 s whatever is declared, so the clean-exit marker is cleared **first** and the `.git` reclaim is best-effort; the next `session-start` pass and the shim's sweep catch what the cap cut short |

The interrupted-session NOTICE is emitted as `additionalContext` inside the `hookSpecificOutput` envelope, **and in no
other key**. Codex 0.154 rejects a reply carrying the top-level `additionalContext` its own hook contract names:
measured one shape per session, the envelope alone reads `SessionStart Completed` while the top-level key — by itself,
or beside the envelope — reads `SessionStart Failed`, which costs the whole reply rather than the key it did not know.
So a second spelling does not hold whichever a release reads; it loses the relay, and the shape is re-measured
when a release moves it. `tests/unit/codex-package.sh` pins the single-key reply and drives both scripts on the payload
key sets the harness captured; the live chain runs through the package's own path on an installed host.

## Skills at the admin scope, and the orientation text

Codex reads skills from four scopes, and the one a host administers is `/etc/codex/skills`. The package's `%post` points
it at the live shared root `/opt/ai-tools/skills` **without displacing what the host holds there**
(`ai_tools_link_shared_root`, [shipped-assets](shipped-assets.rule.md)): absent → a symlink to the shared root;
a symlink to the shared root → current; a symlink elsewhere → the host's, left and reported; a real directory →
the host's own skills, kept as they are, with the shared assets linked into it one per free name and a taken name left
to the host. Nothing under `/etc/codex` carries a guarantee, so a host-owned entry there can only reduce what a session
loads, never widen access. Codex lists a skill placed there to the model whether the path is a symlink to the shared
root, a directory of per-asset symlinks, or a copy — measured, which is why the lightest link ships. Erasing the package
removes the link to the shared root, or the managed links inside a host-owned directory, and no other entry. The link is
deliberately not in the package's file list: a listed path would be written over whatever a host holds there.

The orientation text is linked as `/opt/ai-tools/.codex/AGENTS.md`, the global-scope instructions codex reads
before a project's own `AGENTS.md` files (`ai_tools_link_agent_memory`, the same non-displacing rule).

## Session environment pins

`session-env.d/codex.env.sh` is sourced **last**, after every enabled integration, and pins one variable:
**`CODEX_HOME=/opt/ai-tools/.codex`** — the directory codex writes its login (`auth.json`), its session logs
and memories, its shell snapshots, and a `tmp/` tree of symlinks to its own binary that it appends to a tool's `PATH`.
Unpinned it resolves under the `2751` home root, where the directory cannot be created; the `3770` config directory
grants that write, and its sticky bit keeps the root-placed hooks, and a root-placed `auth.json`, undeletable
by the session. The fragment does not carry a `CODEX_MANAGED_*` variable (the binary behaves the same without
the shim's) or a credential: the API-key path is a root-placed `auth.json`, so there is no token to import by name. No
Node runs in the chain, so there is no compile cache to relocate.

`auth.json` is codex's own state in its own home, the standing claude's `.claude.json` has: sandbox-owned and writable
on the default login path, root-placed `0640 root:SANDBOX_GROUP` on the API-key path, and in neither case confidential
against a same-UID peer — two agents under one account read each other's state, which is misdirection rather than
escalation ([CLAUDE.md](../../CLAUDE.md), Boundaries and non-goals).

## The config directory's mode is the package's own to pin

`ai_tools_agent_config_dirs` walks **enabled** agents, so base re-asserts the `3770` mode of an enabled agent's config
directory only, and codex ships disabled. The package's `%post` and `%posttrans` therefore `chmod 3770` `.codex`
themselves — rpm on EL10 drops setgid from an `%attr` directory mode — so the sticky bit holds from the first install
whether or not the operator has enabled the agent yet. `install.sh` asserts the directory by name after the same walk,
and `tests/integration/perms.sh` checks it by name whenever the walk did not list it, so the assertion holds on a host
in either state.

## What the suite proves on an installed host

The package's files are held to the seams before any host installs them (`tests/unit/codex-package.sh`, which also
drives enablement through the real resolver over this manifest: disabled with `AI_TOOLS_AGENTS` unset, enabled
when named, and skipped when the manifest is group-writable however `operator.conf` reads). On the host,
`tests/integration/perms.sh` pins the owner and mode of every file this rule names and the shape of `/etc/codex/skills`
in each state the linker leaves; `tests/boundary/providers.sh` and `tests/boundary/access.sh` assert, as the agent,
that the manifest, the fragment, `/etc/codex` and both managed files are not writable and that both hooks are executable
and not writable; `tests/integration/hooks.sh` reads `requirements.toml` as codex does and pins the pin, managed hooks
only, the four hook declarations against the installed bodies, and the refused git verbs;
and `tests/integration/wrapper.sh` drives `/usr/local/bin/codex` in whichever state the host is in — refused
at the launcher gate while codex is disabled, since a disabled agent has no launcher symlink, and refused
at the allowlist gate once it is enabled and provisioned — while holding the launcher symlink and the enabled set
to agreement. The rows that need a codex session — a turn under the pin, a hook-written file handed back, the sweep-only
path, a skill listed through `/etc/codex/skills` — run through the package's own path on a host whose operator enabled
codex, the way the claude chain runs in `tests/manual/verify-live-flows.sh`.

## The reduced set

What a codex session does not get, stated as the posture the operator buys: no codex-side sandbox and no unprivileged
user namespace (the host's confinement is the only one); no MCP servers, no sub-agents, no plugins or marketplaces, no
image generation; the browser-callback login unavailable (device code and an API key are); telemetry off by disposition;
and no entrypoint provenance on the npm channel. Egress is not controlled by this package; one identity per host, since
`auth.json` lives in the shared `CODEX_HOME`.

## Quirks

- **A `.rpmnew` for either managed file leaves a newly shipped key unread.** Codex reads the live file alone;
  the `%post` names the parked copy, and the operator carries the keys over by hand. No merge tool exists for these two
  files (they are TOML, not the JSON `ai-tools-admin system post-upgrade` merges).
- **A mode flag is ignored, not refused.** `--sandbox workspace-write` under the shipped requirements lands
  on `danger-full-access` with no notice, since the profile table lists full access alone. Under a requirements file
  without the `default_permissions` pair, the same flag falls back to a read-only managed profile whose tool calls fail
  on bubblewrap — the shape that ships is the one that does not.
- **`codex features list` loads the whole configuration without a credential and does not open a socket**, so it is
  the credential-free check that a managed file parses on this release.

## Deferred

A token-saving filter adapter on `PreToolUse` (codex's `updatedInput`), entrypoint provenance through the vendor's
standalone sigstore-signed tarball, an egress boundary, and root-owned integrity tracking over the agents' shared state
are each their own ticket. The two session hooks share most of their body with claude's; factoring that body into a base
library is deferred until the codex hooks have run on a host.
