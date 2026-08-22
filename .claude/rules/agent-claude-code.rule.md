---
paths:
  - "src/usr/local/bin/claude.sh"
  - "src/usr/local/lib/ai-tools/claude-prompt.lib.sh"
  - "src/usr/local/lib/ai-tools/claude-endpoint.lib.sh"
  - "src/usr/local/lib/ai-tools/agents.d/claude-code.conf"
  - "src/usr/local/lib/ai-tools/session-env.d/claude-code.env.sh"
---

# The claude-code agent

Everything specific to Claude Code as a provider: what its manifest declares, how its binary is
resolved and labelled, its launch wrapper, and the two operator-configurable inputs it carries (a
custom system prompt and a custom API endpoint). The **provider seam** these plug into — manifests,
fail-closed enablement, the `session-env.d` contract — is [providers](providers.rule.md); the
**agent-agnostic** launch contract is [launch](launch.rule.md); its Claude Code `settings.json` is
[claude-settings](claude-settings.rule.md), which stays a rule of its own because it is scoped to a
different file set and a different question (what the harness may run), not because the two domains
are unrelated.

`ai-tools-agents-claude-code-restricted` ships the wrapper, the manifest, the session-env fragment,
the two resolver libraries, and the agent's config directory. It adds no sudoers rule: it inherits
the single `%ai-ops` grant on the shared shim.

## What the manifest declares

`/usr/local/lib/ai-tools/agents.d/claude-code.conf`, `644 root:root`, parsed by
`providers.lib.sh`:

| field | value | read by |
|---|---|---|
| `npm_package` | `@anthropic-ai/claude-code` | `ai-tools-bootstrap`, `nvm-update` — what to install |
| `launcher` | `claude` | `ai-tools-launcher-symlink` (which link it may write), `ai-tools-run` (which executables may start a session) |
| `display_name` | `Claude Code` | the launch banner, the unit description |
| `handback` | `hooks` | `ai-tools-run` — this agent converges the tree itself, so the shim adds no session-end sweep |
| `config_dir` | `.claude` | the control-plane mode/label/seeding set, and `→ ai_tools_home_t` |
| `skills_dir` / `subagents_dir` | `skills` / `agents` | where shared assets are symlinked in ([shipped-assets](shipped-assets.rule.md)) |
| `entrypoint_fcontext` | a regex ending `…/@anthropic-ai/claude-code/bin/claude\.exe` | `ai-tools-relabel-agent` — which file takes `ai_tools_exec_t` |
| `default_enable` | `yes` | the baseline set when `operator.conf` names none |

`handback=hooks` is the only literal that switches the shim's sweep off; anything else, including an
absent key, gets the sweep. `config_dir` must equal the directory the session-env fragment pins as
`CLAUDE_CONFIG_DIR`, since the manifest decides the label and the fragment decides where the agent
writes.

## The resolution chain is three links, and each consumer takes a different one

```
/opt/ai-tools/bin/claude                                     [1] stable launcher symlink
  └─ readlink, one hop ─────────────────────────────────────────────────────────────────
/opt/ai-tools/.nvm/versions/node/vX.Y.Z/bin/claude           [2] versioned npm bin symlink
  └─ resolved by the kernel at execve ──────────────────────────────────────────────────
…/vX.Y.Z/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe   [3] the real executable
```

Which link a component addresses is a deliberate choice per component, not an inconsistency:

| component | addresses | why that link |
|---|---|---|
| `ai-tools-launcher-symlink` | writes **[1]**, validated as **[2]** | the only writable control-plane link; `/opt/ai-tools/bin` is `0551`, so the sandbox reaches it only through this root helper |
| `claude.sh` | reads **[1]**, one `readlink` to **[2]** | full resolution would traverse the `700` package directory as the *operator*, an EACCES that aborts the wrapper silently under `set -e` |
| `ai-tools-run` | re-validates **[2]**, execs it | **[2]** is the allowlist shape: an exact `MAJOR.MINOR.PATCH` directory plus one path component an enabled manifest claims |
| the SELinux transition | fires on **[3]** | `execve` resolves symlinks; the label that matters is the one on the inode actually executed |

The one-hop constraint in `claude.sh` exists solely to avoid that EACCES. It carries no coupling to
sudoers matching, which targets the fixed path `/opt/ai-tools/bin/ai-tools-run`.

## Entrypoint labelling: resolved at check time, pattern-matched at apply time

Because the transition fires on **[3]**, that inode must carry `ai_tools_exec_t`, and a freshly
installed one is born the default type — only `restorecon` applies the label. Three components care,
and they reach **[3]** two different ways:

- **`ai-tools-run`'s fail-closed preflight** resolves it. It `realpath -e`s `AI_TOOLS_AGENT_EXEC`
  (succeeding, since it runs as the sandbox account, which owns the `700` package directory) and
  reads `matchpathcon` and `stat -c '%C'` on the **resolved** path. The verdict is the pure
  `ai_tools_confinement_verdict` (see [confinement](confinement.rule.md)).
- **`ai-tools-launcher-symlink`'s idempotency guard** resolves it the same way, so a repoint that
  would drive a needed relabel always fires while a daily no-op run stops churning the link.
- **`ai-tools-relabel-agent` pattern-matches it.** It registers the manifest's
  `entrypoint_fcontext` as a local `semanage fcontext` rule and relabels the files a
  `find -regex` over that pattern returns (`relabel.lib.sh`).

The two strategies agree only while the pattern describes where the package actually puts its
executable. The guarantee that does **not** depend on that agreement is the important one: a label
the transition would not honour is caught by the preflight on the resolved inode, so the failure is
a refused launch, never an unconfined session.

### What a repackaged upstream produces

If the executable moves — most plausibly into a platform-specific optional dependency, the
conventional npm shape for a native binary — the pattern matches nothing while the chain still
resolves. The resulting state is fail-closed but self-inconsistent, and it is worth stating exactly,
because the remedy the refusal names does not clear it:

- `matchpathcon` on the resolved path yields no `ai_tools_exec_t` (no rule covers the new location),
  the core module's file-contexts are live, so the verdict is **`unverifiable`** and the launch is
  **refused**.
- The refusal prints `Fix: ai-tools --relabel`. That helper registers the same stale pattern,
  `find` returns nothing, and `_ai_tools_label_agent_entrypoint` reports `none` and returns **0** —
  so the run **exits successfully**, its only entrypoint line reading `claude-code: its entrypoint
  is not installed -- nothing to label`, which names the wrong cause: the entrypoint is installed,
  and the manifest no longer describes it.

Closing this means resolving the entrypoint at apply time the way the two checkers already resolve
it at check time, rather than declaring its path. The design is drafted in
`wip/ai-tools-claude-code-native-packaging-plan-v0.1.md`.

## The wrapper (`claude.sh`)

`/usr/local/bin/claude`, `root:root 0755`, rpm-owned, running as the invoking operator.
`path-dedup.sh` ranks `/usr/local/bin` (Tier 1) above the nvm shims in operator dotfiles, so this
shadows any nvm-managed `claude` on an operator's PATH ([launch](launch.rule.md)).

It gates in this order, each step refusing before the next can matter:

1. **Required libraries**, fail-closed: `msg.lib.sh` (it carries the yes/no decisions),
   `safe-paths.lib.sh` (the protected-path guard), and `conf.lib.sh` (without it every allowlist
   line parses as no entry, which refuses every launch — indistinguishable from "you have no
   projects" unless the missing component is named). `claude-prompt.lib.sh` loads best-effort; its
   fail-closed decision is made where the configuration is known (below).
2. **Operator gate** — `ai-ops` membership, read from `id -nG` (this shell's live credential set,
   the set `sudo` enforces against). The refusal distinguishes three cases because the fix differs:
   the sandbox account (which must never be an operator), an operator whose shell predates the grant
   (re-login), and a genuine non-operator.
3. **Binary resolution** — `-L` on the stable link (not `-e`, which would dereference into the
   unreadable package directory), one `readlink`, then string-only validation that the target is an
   absolute, `..`-free path matching the versioned shape.
4. **Print-and-exit short-circuit** — `--version`/`-v`/`--help`/`-h` as the *sole* argument skips
   every CWD gate and runs with the sandbox home as `WorkingDirectory`. Such a run touches no
   working tree, so no project grant is implied.
5. **Protected-paths backstop**, then the **allowlist** (exclusions first, since `!` overrides
   allows), both on the `realpath`-canonicalized CWD.
6. **Claim guard** — three gaps detected read-only: group/mode (fatal — the session starts but
   `posix_spawn` fails `EACCES` on every child), SELinux label (fatal under enforcing), and git
   `safe.directory` (non-fatal). The wrapper never performs a `chgrp` or a relabel itself; it
   detects, offers, and delegates to `ai-tools --project-claim` ([cli](cli.rule.md)).
7. **Prompt resolution** and a **best-effort service-health warning** (the relabel watcher; the
   handback socket is the shim's to report — see [launch](launch.rule.md)).
8. `exec sudo -u ai-tools -g ai-tools -- /opt/ai-tools/bin/ai-tools-run`, carrying exactly
   `AI_TOOLS_AGENT_EXEC` and `AI_TOOLS_PROJECT_DIR` through `env_keep`. **No agent identity crosses
   sudo**; the shim derives it from the launcher name in the path.

## Custom system prompt (`claude-prompt.lib.sh`)

Resolved from `operator.conf` and prepended to `"$@"` just before the final `exec`, as
`--append-system-prompt-file <path>` (mode `append`, the default — keeps Claude Code's own tool-use
and safety guidance) or `--system-prompt-file <path>` (mode `replace`).

- **`CLAUDE_SYSTEM_PROMPT_FILE` must resolve under `/etc/ai-tools/prompts/`** — the one location the
  confined `ai_tools_t` domain is granted read on (`etc_t`, via `files_read_etc_files`). A
  root-owned file elsewhere passes the DAC trust check yet is unreadable to the session, so a
  mis-set path would become a failed launch rather than a refused one. The file, its directory, the
  prompts base, and `operator.conf` each pass `ai_tools_conf_is_trusted`, and the file must be
  readable text.
- Claude Code reads the file **verbatim** — not processed, not comment-stripped — so it holds prompt
  text only. The shipped default is therefore **empty**, `0640 root:SANDBOX_GROUP` (a custom prompt
  may be proprietary, so not world-readable; the wrapper only `stat`s it as the operator, and the
  confined binary reads it as the sandbox account). Uncommenting the pointer alone changes nothing.
- **`replace` sets the request's `system` field, not the whole model context.** It does not remove
  the tool definitions or the `CLAUDE.md` context Claude Code injects as `<system-reminder>` blocks;
  those ride in separate request fields. "Only the file reaches the model" is not reachable through
  this flag — shape the final request at the proxy instead.
- **Fail closed only once configured.** An unconfigured host launches with the default prompt; a
  configured-but-unhonourable one (missing, untrusted, outside the base, non-text, unknown mode, or
  a resolver library that will not load) **refuses the launch**. This is a distinct tier from the
  confinement libraries, which fail *every* launch closed.
- **A per-invocation `--{,append-}system-prompt{,-file}` flag suppresses the configured default
  entirely**, scanned in `"$@"`, so the explicit flag wins without depending on Claude Code's own
  flag-precedence behaviour.

## Custom API endpoint (`claude-endpoint.lib.sh`)

The session-env counterpart, resolved **sandbox-side in the fragment** rather than in the wrapper.
`operator.conf` `CLAUDE_BASE_URL_FILE` points at a dedicated file under `/etc/ai-tools/endpoints/`,
from which the resolver reads exactly four recognised keys — `ANTHROPIC_BASE_URL` (required, a
validated http(s) URL), `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`,
`ANTHROPIC_DEFAULT_HAIKU_MODEL` — and turns each valid one into a `--setenv=` entry. An arbitrary key
is never read, so the file cannot inject unrecognised environment.

- **A dedicated `640 root:ai-tools` file, not `operator.conf`.** `ANTHROPIC_AUTH_TOKEN` is a
  credential and `operator.conf` is `644`; the endpoint file is readable by root and the sandbox
  account (which needs the token) but not by the world and not by the operator. That the operator
  cannot read it is why validation happens sandbox-side.
- **The token is imported by name.** A valid token is `export`ed and forwarded as the name-only
  `--setenv=ANTHROPIC_AUTH_TOKEN`, so its value never lands on a command line. This `export` is one
  of the two sanctioned fragment exceptions ([providers](providers.rule.md)).
- **Fail closed on a present-but-invalid option** — malformed URL, a model label with whitespace, a
  token with control bytes, options with no anchoring `ANTHROPIC_BASE_URL`, or a missing/untrusted
  pointer file — the fragment `exit`s the launch, which is clean because it is sourced before the
  unit is created and before the sweep trap is installed. A fully inert file (the shipped default)
  applies nothing; a non-local endpoint with no token warns but still applies.
- **Precedence.** These are process environment variables, so a Claude Code settings `env` block
  (authoritatively `/etc/claude-code/managed-settings.json`) setting the same name wins. The shipped
  settings set no `ANTHROPIC_*` key, so the endpoint file governs by default and
  `managed-settings.json` stays the un-overridable host lock.

**Boundary — this is operator configuration, not an agent-confinement control.** The enforced
property is that the root-owned inputs are not agent-writable, so the sandbox cannot change what any
session launches with, plant a file the resolver would honour, or swap the token other sessions use.
It is not a claim that a running session cannot alter its own environment: a session may set
`ANTHROPIC_BASE_URL` for itself or a child, but that does not repoint the already-started client
(which reads the variable at startup, and a Bash-tool child's `export` never reaches the parent).
Outbound traffic is governed by network policy, not this variable.

## Session environment pins

`session-env.d/claude-code.env.sh` is sourced **last**, after every enabled integration, so its pins
are authoritative. Each exists because the sandbox home is deliberately not agent-writable at its
root:

- **`CLAUDE_CONFIG_DIR=/opt/ai-tools/.claude`** — Claude Code saves `.claude.json` (login,
  onboarding, per-project trust) by writing a temp file beside it and renaming, which needs write on
  the *containing* directory. `.claude` is `3770`, setgid+sticky: the rename works, and the sticky
  bit keeps control files the agent does not own undeletable. Unpinned it would resolve under the
  `2751` home root, where the rename is refused and every session demands a fresh login.
- **`NODE_COMPILE_CACHE=/opt/ai-tools/.cache/node-compile-cache`** — Node's default is under
  `os.tmpdir()` on the shared host `/tmp`, where entries left by an earlier unconfined run carry
  `user_tmp_t`, a type the session's domain has no rule for; Node's own `open()` of its cache is
  then denied and the session dies at startup.
- **`DISABLE_AUTOUPDATER=1`** — the Node program tree is read-only to the session, so an in-session
  self-update cannot write the npm prefix. The `nvm-update` timer maintains the toolchain out of
  band ([updater](updater.rule.md)), which also keeps the toolset stable for the whole session.

## Distribution channel

The agent is provisioned as an **npm package on the sandbox's Node toolchain**: `npm install -g` at
bootstrap and on each updater run, its launcher symlinked into the locked control-plane `bin`, and
its executable accepted only under `/opt/ai-tools/.nvm/versions/node/<semver>/bin/`. That assumption
lives in exactly two places — provisioning and exec validation — and nowhere else in the seam
([providers](providers.rule.md)).

Two properties of the current channel shape the design:

- **The executable is a compiled native binary, not a JavaScript entrypoint.** `claude.exe` is
  reached through two symlinks and executed directly; the session does not run it through `node`.
  The same binary is what every distribution channel delivers — npm is a distribution channel for it
  rather than a different build — so the channel decides provenance, placement, and update cadence,
  not what runs.
- **The sandbox account owns its own entrypoint.** The nvm tree is `SANDBOX_USER`-owned, so unlike
  every other control-plane file the agent binary is agent-writable. That is bounded rather than
  open: `ai-tools-run` accepts only a manifest-claimed launcher at a semver path, the updater
  verifies npm registry signatures before activating a tree, and the SELinux preflight fails closed
  on a label the agent cannot grant itself. A root-owned, agent-read-only exec root would remove the
  bound rather than tighten it, which is the direction the native-packaging plan takes.

## Quirks

- **`ai-tools --relabel` can report success while the launch stays refused.** Covered above: the
  relabel applies a declared pattern, the preflight checks a resolved inode, and only the second is
  layout-independent.
- **A `.rpmnew` for `settings.json` leaves a newly shipped hook installed but uninvoked.** It is
  `%config(noreplace)` for the same reason `operator.conf` is — a dormant option is recoverable, a
  silently reverted setting is not (see [providers](providers.rule.md),
  [claude-settings](claude-settings.rule.md)).
- **The wrapper's `-L` test is not interchangeable with `-e`.** `-e` dereferences the whole chain
  into the `700` package directory, so a perfectly valid link reports "not found" to the operator.

## Deferred

**Moving the agent off npm onto a root-owned native exec root.** The npm package is deprecated
upstream while a native/`dnf` channel exists, and a root-owned entrypoint would close the
agent-writable-exec-root bound above, make the relabel layout-independent, and remove the
reinstall-re-mints-the-entrypoint race the updater currently works around. It needs the `runtime`
field the provider seam already names, a second exec root, and a packaging split. Drafted, not
built: `wip/ai-tools-claude-code-native-packaging-plan-v0.1.md`.
