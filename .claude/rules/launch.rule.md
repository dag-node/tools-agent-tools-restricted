---
paths:
  - "src/opt/ai-tools/bin/ai-tools-run.sh"
  - "src/etc/sudoers.d/ai-tools"
  - "src/usr/local/lib/ai-tools/path-dedup.sh"
  - "src/usr/local/lib/ai-tools/session-env.d/**"
---

# Launch path and project gating

The agent wrapper → `ai-tools-run` → session handoff: the gating contract every wrapper
owes, and placing the session in a transient systemd unit. Kernel confinement
of that unit (namespaces, SELinux transition, `/tmp`) lives in
[confinement](confinement.rule.md); ownership handback in
[ownership-and-hooks](ownership-and-hooks.rule.md). One agent's wrapper and its
agent-specific inputs live in that agent's own rule —
[agent-claude-code](agent-claude-code.rule.md) for Claude Code.

## The wrapper contract (agent-side)

Each `ai-tools-agents-*` package ships one wrapper into `/usr/local/bin`, `root:root 0755`,
rpm-owned, running as the invoking operator. `path-dedup.sh`, wired into the operator's
dotfiles by `ai-tools-admin operator add`, ranks `/usr/local/bin` (Tier 1) above the nvm
shims, so a wrapper shadows the nvm-managed launcher of the same name on the operator's
PATH. Whatever else a wrapper does, these five gates are what the security model rests on,
and every one of them refuses toward *less* access:

1. **Operator gate first** — a caller not in the `ai-ops` operators group is refused before
   anything else happens, with a framed `msg.lib` message naming the
   `ai-tools-admin operator add` fix rather than leaking the raw `sudo` denial the
   `%ai-ops` rule would otherwise produce.
2. **Protected-paths backstop, then the allowlist**, both on the `realpath -e`-canonicalized
   CWD. A session starts only inside an allowed project and never in a CWD carved out by a
   `!` exclusion. Every allowlist entry is canonicalized before matching and the match is
   exact-or-`/`-prefixed, so a symlink or `..` component cannot smuggle a CWD past the gate
   and a sibling sharing a name prefix does not match. `ai-tools-chown` parses the same list
   the same way, so the launch gate and the ownership handback agree on what is in-project.
3. **Binary resolution to the versioned shape** — the stable symlink
   `/opt/ai-tools/bin/<launcher>` is resolved and the target validated as an absolute,
   `..`-free path under the sandbox toolchain, then exported as `AI_TOOLS_AGENT_EXEC`. This
   validation is an integrity check against a misconfigured or compromised
   `ai-tools-launcher-symlink` root helper, not a guard against external injection — only
   root writes `/opt/ai-tools/bin` (`0551 root:SANDBOX_GROUP`). `ai-tools-run` re-validates
   it regardless, so a wrapper is never the only thing checking.
4. **Print-and-exit short-circuit** — `--version`/`-v`/`--help`/`-h` as the *sole* argument
   skips the CWD gates (backstop, allowlist, claim): such a run touches no working tree, so
   no project grant is implied. It still launches the same validated binary confined as
   `SANDBOX_USER`, with the sandbox home as `WorkingDirectory`.
5. **`exec sudo -u SANDBOX_USER -g SANDBOX_GROUP -- /opt/ai-tools/bin/ai-tools-run`**,
   carrying exactly `AI_TOOLS_AGENT_EXEC` and `AI_TOOLS_PROJECT_DIR` through `env_keep`.

A wrapper **detects and delegates; it never repairs.** Ownership, label, and
`safe.directory` gaps are reported read-only and fixed by `ai-tools --project-claim` (see
[cli](cli.rule.md)) — no wrapper performs a `chgrp` or a relabel itself.

Agent-specific inputs a wrapper may additionally resolve (a custom system prompt, an API
endpoint) are that agent's rule to document, not this one's.

## The `ai-tools-run` service shim (launch mechanics)

`ai-tools-run` (`/opt/ai-tools/bin/ai-tools-run`, `0550 root:SANDBOX_GROUP`, not writable by
the agent) is **`ai-tools-base`-owned and names no agent**. One shim confines every agent, so
an `ai-tools-agents-*` package ships only its wrapper, its manifest, and its session-env
fragment, and inherits the single `%ai-ops` sudoers grant rather than adding one — the grant
surface does not grow with the number of agents.

The whole wrapper contract is two variables carried through sudo's `env_keep`:
`AI_TOOLS_AGENT_EXEC` (the versioned executable) and `AI_TOOLS_PROJECT_DIR` (the working
directory). **No agent identity crosses sudo**: which agent this is follows from the launcher
name in the executable path, matched against the installed manifests, so the shim derives it
rather than trusting it.

The executable is re-validated on an **allowlist assembled from root-owned data**: it is
accepted only at `${AI_TOOLS_NVM_DIR}/versions/node/<semver>/bin/<launcher>` — an exact
`MAJOR.MINOR.PATCH` version directory and a single path component — **and** only when
`<launcher>` is the `launcher` of an agent that `operator.conf` enables (see
[providers](providers.rule.md)). A binary the sandbox account drops beside the launcher
therefore cannot start a session, because no manifest claims it. A `..` component is refused
before the match, and the resolution fails closed: with no enabled agent, nothing launches.

**What is checked is what is exec'd.** That validated path is the versioned launcher *symlink*; the
file `execve` transitions on is what it resolves to. The shim resolves it once, requires the target
to stay inside the **same semver version directory** the launcher was accepted at (a property
string-matching cannot carry across a symlink, and what stops a link repointed at another version's
tree or out of the toolchain), and then uses that single path for both the SELinux label preflight
and the unit's `ExecStart` — so the manager is never handed a link to re-resolve after the checks
have run. Immediately before the launch it re-resolves and re-compares a device/inode/size/ctime
identity, refusing if the entrypoint moved: a repoint changes the path, a rename-over keeps the path
and changes the inode, an in-place write keeps both and changes ctime (which no unprivileged caller
can roll back — `utimes(2)` sets atime and mtime, never ctime).

**The entrypoint pin is compared in the same breath**, because that is the one place where hashing
the file and starting it are adjacent. The pin is what root recorded after verifying this entrypoint
against the checksum its vendor signed, in a directory this account cannot write (see
[updater](updater.rule.md)); a **mismatch** means the binary changed after it was verified, and
refuses the launch unconditionally. An **unpinned** entrypoint is a different fact and launches
normally — it is equally the state of an air-gapped host, one whose vendor published no manifest for
the installed release, and one that has not reconciled yet — unless
`AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY` declares otherwise, the same operator-asserts-intent shape as
`AI_TOOLS_REQUIRE_SELINUX`. The verdict rides the per-launch audit line.

That re-check **narrows** the window a concurrent same-uid process would have to win, from the whole
preflight to the `systemd-run` round trip; it does not close it. Only an exec root the agent cannot
write does — which under SELinux already holds, so there is no swap to observe there (see
[the type layout](confinement.rule.md#the-toolchain-is-read-only-to-the-confined-domain)). The
re-check is for the **DAC-only** deployment, where it is the only observer of one.

It then wraps the session in a transient systemd *service* unit (`systemd-run --user --pty`)
before exec'ing the versioned binary. The service runs in `SANDBOX_USER`'s systemd user instance, kept alive by
`loginctl enable-linger` (see [updater](updater.rule.md)). The kernel security properties
that unit carries are in [confinement](confinement.rule.md); the launch-shaping properties:

**`UMask=0007`** keeps agent-created files group-writable so the collaborative
ownership model holds. A service unit does not inherit the caller's umask (a scope
does), so the umask is set as a unit property, authoritative over the per-command
sudoers `umask`.

**Environment is an explicit allowlist.** The user manager spawns the service with
its own environment, not `ai-tools-run`'s, so nothing crosses into the session unless
it is named. `ai-tools-run` forwards only terminal-, locale-, and connectivity-shaping
variables **by name** (`FORWARDED_ENVIRONMENT_VARIABLES`: `TERM`/`COLORTERM`, the
`LANG`/`LANGUAGE`/`LC_*` set, `XDG_RUNTIME_DIR`, and the upper- and lower-case proxy
vars) via `--setenv=NAME`, so a value never reaches the command line. The operator's
secrets (`ANTHROPIC_API_KEY`, `AWS_*`, `SSH_AUTH_SOCK`, …) stay out of the session by
construction, independent of sudo's `env_reset`/`env_keep`. To share a variable
deliberately, add its name to that array.

It **pins** three things itself: `HOME=/opt/ai-tools`, `SHELL=/usr/bin/bash`, and a
controlled `PATH`, so the session's identity and shell tooling are the sandbox's rather
than whatever the operator's login carries. `HOME` stays `/opt/ai-tools` because the
agent's control plane (`settings.json`, the hooks) is root-owned and `ai_tools_home_t`,
and is not relocated into the agent-writable project tree.

Everything **agent-specific** — a config directory, a compile cache, an autoupdater
switch — is pinned by that agent's own session-env fragment rather than here, so the shim
names no agent (see [providers](providers.rule.md), and
[agent-claude-code](agent-claude-code.rule.md) for the pins Claude Code makes and why each
is load-bearing).

**Enabled providers extend that allowlist, and nothing else may.** Every enabled provider —
each integration *and* the agent itself — may contribute session env and a PATH tail through a
root-owned fragment `/usr/local/lib/ai-tools/session-env.d/<name>.env.sh`, which `ai-tools-run`
sources: integrations first, **the agent last**, so the agent's own pins (its config directory,
its cache) are authoritative over an integration's. See [providers](providers.rule.md) for the
manifests, the enablement rules, and the trust checks every input passes.

Two launch-side consequences: PATH is **assembled and emitted once**, after the fragments run,
so the base tiers (root-owned, least-writable first) always precede any addition; and the
fragments are sourced **as `SANDBOX_USER`, before the unit is created**, which is why each one —
and the directory holding it, and the libraries doing the sourcing — must be root-owned and
non-group-writable. A failing check skips that fragment and logs it; an installed-but-disabled
provider contributes nothing. Fragments are additive, so a skipped one costs the session that
provider's environment and leaves every property in this section intact.

**A session-end ownership sweep for agents that carry no hooks.** The shim reads the resolved
agent's `handback` declaration (see [providers](providers.rule.md)): `handback=hooks` means the
agent converges the tree itself and the shim adds nothing, and any other declaration makes the
shim sweep the project once the session exits, offering each `SANDBOX_USER`-owned path to
`ai-tools-chown` through the handback socket. The sweep is installed as an `EXIT` trap before the
launch, so it also runs on an interrupted shim.

**A handback-socket preflight, warn-not-block.** Every agent's ownership handback — the per-turn
hooks and this session-end sweep alike — runs over `/run/ai-tools/handback.sock`. If it is down,
every `CHOWN` fails and the tree silently rots into "dubious ownership". Before launch (when a
project directory is set — a bare `--version`/`--help` run writes nothing), the shim checks the
socket and, if absent, emits a framed NOTICE naming the fix (`systemctl enable --now
ai-tools-handback.socket`, then `ai-tools --reclaim <project>`) and **proceeds**. This is not a
confinement boundary — DAC, `ai_tools_t`, and the project `user:<operator>` ACL keep the operator's
access intact regardless — so a down socket warns rather than refusing the launch (refusing would
trade availability for a non-security convenience). The session-end sweep re-checks the socket and,
when it is down, skips the walk and records the stranded count rather than a tally of failed calls
(see [handback-bridge](handback-bridge.rule.md), [ownership-and-hooks](ownership-and-hooks.rule.md)).

**An operator-side pre-launch service warning (wrapper-side).** Before the final `exec`, the wrapper
runs one more warn-not-block check, from `services.lib.sh` — the same registry `ai-tools --status`
reads (see [cli](cli.rule.md)). It warns about a down **system** service the wrapper owns, currently
the `ai-tools-relabel.path` watcher: while it is down a post-upgrade launch fail-closes on a
mislabelled entrypoint, so surfacing it *before* the next Node bump is the point. The registry marks
each service with a `preflight` — `ai-tools-handback.socket` is `shim` (the socket NOTICE above owns
it, so the wrapper does **not** repeat it), `ai-tools-relabel.path` is `wrapper` — so the two
preflights partition the units and never double-warn. This is best-effort and non-blocking like the
socket check: a health warning is not a security gate, so a missing `services.lib.sh` skips the
warning rather than failing the launch closed (unlike the `safe-paths` load, which does), and a
healthy host prints nothing. The print-and-exit path exec'd earlier, so a bare `--version`/`--help`
never triggers it.

**`WorkingDirectory` is the validated project directory.** A transient unit defaults
its cwd to `/`. The wrapper exports the realpath'd, allowlist- and claim-validated
project directory as `AI_TOOLS_PROJECT_DIR`, carried through sudo via `env_keep`;
`ai-tools-run` re-validates it (absolute, `..`-free, existing) and sets it as the unit's
`--working-directory`, so the session starts in the project. The `chdir` runs in the
user manager's domain before the transitioning `exec`, so that domain needs `search`
on `ai_tools_project_t` (see [confinement](confinement.rule.md)).

**`--pty` service, not `--scope`.** `RestrictNamespaces` and `UMask` are exec-context
directives; systemd 252 rejects them on a scope unit (`Unknown assignment`) because a
scope has no exec context — the caller, not the manager, performs the final `exec`.
A service unit (the manager execs `ExecStart`) accepts them, and `--pty` keeps the
session attached to the terminal so the agent's TUI works.

## Operator-configured launch inputs

A wrapper may resolve agent-specific configuration from `operator.conf` and prepend it to the
operator's `"$@"` before the final `exec`. These inputs are **not confinement**, so they take a
distinct fail-closed tier from the confinement libraries (`safe-paths`/`conf`/`msg`, which fail
*every* launch closed): an unconfigured host launches untouched, while a configured-but-unhonourable
input **refuses the launch** rather than silently reverting to the default the operator did not ask
for. Whatever the input, the enforced property is that its sources are root-owned and pass
`ai_tools_conf_is_trusted`, so the sandbox can neither set one nor plant a file a resolver would
honour.

Claude Code's two — a custom system prompt (wrapper-side) and a custom API endpoint (resolved
sandbox-side in its session-env fragment) — are in
[agent-claude-code](agent-claude-code.rule.md).

## Why `/opt/ai-tools`, not `/home`

`/home` is mounted `nosuid`, so a `sudo` UID-switch that execs a binary there still
runs as the invoking user. `/opt/ai-tools` has no `nosuid`, so the switch to
`SANDBOX_USER` takes effect and the binary is owned by `SANDBOX_USER`.

## Sudoers grants (the two `%ai-ops` rules)

The drop-in (`/etc/sudoers.d/ai-tools`) is a **static** `%ai-ops` group rule the
package ships unchanged — membership in the `ai-ops` operators group (managed by
`ai-tools-admin`) is what grants access, so there is no per-operator line to generate:

```
%ai-ops  ALL=(SANDBOX_USER:SANDBOX_GROUP) NOPASSWD: /opt/ai-tools/bin/ai-tools-run
%ai-ops  ALL=(root)                       NOPASSWD: /usr/local/libexec/ai-tools/ai-tools-relabel-agent ""
```

The first rule **drops** privilege to the lower-privileged `SANDBOX_USER`; the agent runs
*as* `SANDBOX_USER`, which is not in `ai-ops` and has no rule of its own, so it can invoke
neither. `ai-tools-run` is a fixed-path target (no glob); the versioned binary is exec'd by
`ai-tools-run` after it re-validates `AI_TOOLS_AGENT_EXEC`.

The second rule runs **as root**: `ai-tools --relabel` uses it to restore `ai_tools_exec_t`
on each enabled agent's entrypoint after a Node upgrade, which needs the `unconfined_t` that root
holds (see [updater](updater.rule.md)). The grant is scoped to exactly that action — a
**fixed, non-glob path**, plus the trailing `""` that pins it to the **zero-argument** form, since
a command listed without arguments permits *any* (`sudoers(5)`). So it resolves to one program
doing one thing, and the helper's other form, `--remove <agent>` (the agent package's erase-time
step), stays reachable by root alone. The helper is `750 root:root`, owned and
writable by root alone. It is an operators-group grant, keeping the root privilege on the
operator side beside the launch rule. The automatic post-upgrade relabel runs through the
root-side `ai-tools-relabel.path` watcher, which needs no sudo rule. The toolchain update
runs as `SANDBOX_USER` in its own `systemd --user` instance, so it needs no sudo rule
either.

`SANDBOX_USER` holds no sudo rights in this file. Two `ai-tools-run` preflights enforce the
account boundary the sudoers model assumes: it refuses to launch unless it runs **as**
`SANDBOX_USER` (a direct or sudo invocation landing as root or another user fails closed), and
it refuses if `SANDBOX_USER` is ever a member of `ai-ops` (so the sandbox account can never
hold the operator grant). See the security-model invariants in `CLAUDE.md`.

`umask=0007,umask_override` and `env_keep += "AI_TOOLS_AGENT_EXEC AI_TOOLS_PROJECT_DIR"` (for
`ai-tools-run`) are scoped per-command with
`Defaults!<command>`, applying only to those commands. The sudoers `umask` sets
`ai-tools-run`'s own process umask; the transient service unit does not inherit it, so
the agent's umask comes authoritatively from the `UMask=0007` unit property.
`AI_TOOLS_AGENT_EXEC` carries the wrapper-validated versioned path for re-validation;
`AI_TOOLS_PROJECT_DIR` carries the validated project directory, becoming the unit's
`WorkingDirectory`.

## Allowlist `!` exclusions are honored by both consumers

`!`-prefixed lines in `allowed-projects` are exclusions and override allows. The
wrapper refuses to launch with an excluded CWD, and `ai-tools-chown` skips ownership
restoration on excluded paths. Keep the two in sync — a plain `!`-path also covers its
contents; globs match as-is.

## PATH ordering

Every agent wrapper lives in `/usr/local/bin`, which `path-dedup.sh`
(`/usr/local/lib/ai-tools/path-dedup.sh`, `644 root:root`) ranks Tier 1 — above the nvm
shims it leaves in Tier 4 — so `/usr/local/bin/<launcher>` resolves ahead of the
nvm-managed binary of the same name and typing the launcher always enters the sandboxed
launch path. The fragment is
sourced per-account: `ai-tools-admin operator add` offers to add the guard line to the
operator's `~/.bashrc` and `~/.bash_profile` **after** their nvm init, the one position
where the ordering holds (the dedup must follow anything that prepends to PATH, and
non-login interactive shells read `~/.bashrc` only). Per-account wiring scopes the reorder
to the operators who launch the agent: root and accounts unrelated to ai-tools keep their
stock PATH, and ai-tools ships nothing into `/etc/profile.d`, keeping the host's
every-login-shell code surface untouched. The sandbox account needs no wiring:
`ai-tools-run` pins the session PATH as a unit property, on the same Tier-1-first ordering.
