---
paths:
  - "src/usr/local/lib/ai-tools/conf.lib.sh"
  - "src/usr/local/lib/ai-tools/providers.lib.sh"
  - "src/usr/local/lib/ai-tools/agents.d/**"
  - "src/usr/local/lib/ai-tools/integrations.d/**"
  - "src/usr/local/lib/ai-tools/session-env.d/**"
  - "src/usr/local/sbin/ai-tools/ai-tools-dotnet.sh"
---

# Provider manifests, enablement, and integrations

The toolchain and launch layers provision providers without naming any: which providers exist,
and how each is provisioned, comes from per-package manifests gated by `operator.conf`, resolved
by `providers.lib.sh`. Two provider kinds share the mechanism:

- **Agents** (`ai-tools-agents-*`) — the AI coding agents. `ai-tools-bootstrap`/`nvm-update` install
  each enabled agent's npm package and symlink its launcher (see [updater](updater.rule.md)).
- **Integrations** (`ai-tools-integration-*`) — host-toolchain layers. `ai-tools-run` sources each
  enabled integration's session-env fragment (see [launch](launch.rule.md)).

## Manifests

Each installed member package ships one manifest, `/usr/local/lib/ai-tools/{agents,integrations}.d/
<name>.conf`, `644 root:root`. `<name>` (the basename) is the token an operator writes in
`AI_TOOLS_AGENTS` / `AI_TOOLS_INTEGRATIONS`. It is `KEY=value` data — **parsed, never sourced**, the
same posture as `operator.conf`/`skip-dirs.lib.sh`, so a malformed or tampered manifest cannot
execute code in the privileged scripts that read it:

- agents: `npm_package` (the registry package), `launcher` (the bin symlinked at
  `/opt/ai-tools/bin/<launcher>`, and the name `ai-tools-run` matches an executable against to
  decide whether it may launch), `display_name` (what the launch banner and the unit description
  call it), `handback` (which side converges ownership — below), `default_enable`.
- integrations: `default_enable`.

Either kind may also ship `session-env.d/<name>.env.sh`, keyed by the same `<name>` — one flat
namespace across both kinds, so a provider name is unique host-wide.

`ai-tools-base` owns the three directories (`agents.d`, `integrations.d`, `session-env.d`), ships
`providers.lib.sh`, and owns the `ai-tools-run` shim that reads them; each member package ships
only its own files into them.

## The `handback` capability — which side converges ownership

Files the agent writes are born `SANDBOX_USER`-owned, and the ownership handback returns them to
the operator (see [ownership-and-hooks](ownership-and-hooks.rule.md)). That handback needs a
**driver**, and only the agent knows whether it has one, so the manifest declares it:

- **`handback=hooks`** — the agent runs the hooks itself, per tool call and per turn (Claude
  Code's `PostToolUse`/`Stop`/`SessionStart`/`SessionEnd` entries in `settings.json`).
  `ai-tools-run` adds nothing.
- **anything else** (`handback=none`, an unrecognized value, an absent key) — no driver, so
  `ai-tools-run` sweeps the project itself once the session exits: every `SANDBOX_USER`-owned path
  under the project directory (heavy trees skipped, `.git` walked — the `reclaim` selector in
  `skip-dirs.lib.sh`) is offered to `ai-tools-chown` through the handback socket. Convergence is
  per session rather than per turn; the end state is the same.

`ai_tools_agent_sweeps_at_exit <declaration>` is the pure verdict, and it is an **allowlist**:
only the exact literal `hooks` switches the sweep off, so an agent that declares nothing gets the
sweep — a redundant walk is the recoverable error, an operator tree left sandbox-owned is not.

The sweep only chooses which paths to **offer**; each one still passes `ai-tools-chown`'s
allowlist, exclusion, secret, and born-owner re-validation as root, so it reaches nothing the
hooks could reach. It runs from an `EXIT` trap, so an interrupted shim (Ctrl-C, `SIGTERM`) still
converges; a `SIGKILL` leaves the tree to the next session's sweep or `ai-tools --reclaim`.

## The shared config grammar (`conf.lib.sh`)

Every `KEY=value` file in the project — `/etc/ai-tools/operator.conf` and every manifest — is read
by one parser, `conf.lib.sh`, which `operator.lib.sh`, `skip-dirs.lib.sh`, and `providers.lib.sh`
all source. One grammar means a key reads the same whichever component reads it:

```
KEY=value            quotes optional; whitespace around the key and `=` trimmed
KEY="a b"            one layer of matched quotes stripped
KEY=a, b  c          list items separate on commas AND whitespace, freely mixed
KEY=value   # why    `#` at the start of a value or after whitespace ends it; inside
                     quotes it is literal, so a value containing one is written "a#b"
KEY=                 PRESENT with an empty value — distinct from an ABSENT key
```

A repeated key takes its last assignment; a line with no `=` is ignored. Files are **parsed, never
sourced**, so a malformed or tampered one yields a bad value, never executed code.

`ai_tools_conf_read` returns present/absent separately from the value, which is what makes
`KEY=` (an explicit "none") distinguishable from an omitted key — the distinction the gating below
turns on. `ai_tools_conf_list` overwrites its target array **only** when the key is present, so an
override key overrides and an absent one leaves the caller's default standing (how the `SKIP_*`
categories in [ownership-and-hooks](ownership-and-hooks.rule.md) keep their built-in defaults).

**Splitting pins `IFS` locally.** The parser is sourced into scripts that set the strict-mode
`IFS=$'\n\t'` (`nvm-update.sh`, `claude.sh`), where an inherited `IFS` would read `"a b"` as one
item — for a provider allowlist that reads as "no such provider", a wrong verdict that disables a
configured agent with only a warning. `tests/unit/conf.sh` drives the splitter under that IFS.

## Enablement is fail-closed

`operator.conf` `AI_TOOLS_AGENTS` / `AI_TOOLS_INTEGRATIONS` (provider names, in the grammar above)
gates each kind:

- **key present** → enabled = exactly the listed names (an allowlist; an empty value = none).
  `default_enable` is ignored, so an operator's explicit list always wins.
- **key absent** → enabled = installed providers with `default_enable=yes` (the baseline). Both
  keys ship commented in the template, so a fresh or upgraded host (whose `%config(noreplace)` file
  may predate them) runs the baseline.
- **config unreadable, malformed, or untrusted** → treated as absent (the baseline; never
  "enable all").
- **a listed name with no installed manifest** → reported and skipped, never guessed.

A `default_enable=yes` is the shipping package's claim that its provider widens no host surface
beyond the sandbox (Claude Code); a surface-widening one ships `default_enable=no` and is enabled
only when an operator names it (dotnet). This is the fail-closed default-when-unset rule.

## The sandbox cannot widen its own surface

The inputs above decide which agents get installed and what environment a session is handed, and
the code that reads them runs **as `SANDBOX_USER`** (`ai-tools-run`, `nvm-update`). So each input is
honored only while `ai_tools_conf_is_trusted` holds for it — it exists, is not a symlink, is owned
by root, and is writable by neither group nor other — and so is the **directory** holding it, since
a group-writable directory lets a non-root writer unlink a root-owned file and put its own in that
name. Each refusal moves to *less* access and is reported (stderr for the operator, journald for
the trail), never silently:

| untrusted input | verdict |
|---|---|
| `operator.conf` | ignored → the baseline (which only enables what a package marked `default_enable=yes`) |
| a manifest directory | that whole provider kind is refused |
| one manifest | that one provider is skipped |
| `session-env.d` or a fragment | that fragment is not sourced |
| `/usr/local/lib/ai-tools` itself | no integration env at all (`ai-tools-run`'s bootstrap check) |

Trust bootstraps on the lib directory, which `ai-tools-run` checks inline before sourcing anything
from it — the predicate that checks everything else lives inside it. `0751 root:SANDBOX_GROUP` on
that directory is therefore load-bearing, not housekeeping, and
`tests/integration/perms.sh` asserts it along with the three provider directories.

This is enforced from both ends, and both halves are required: `tests/unit/providers.sh` drives
each untrusted state through the resolver and asserts it fails closed (catching a host someone has
already broken), while `tests/boundary/providers.sh` probes the deployed surface **as the agent**
and asserts none of it is agent-writable (catching the agent trying to break it).

## Resolution

`providers.lib.sh` splits a pure verdict from the I/O, mirroring `confinement.lib.sh`:

- `ai_tools_provider_is_enabled <name> <default_enable> <allowlist_active> <allowlist>` — the pure
  enablement decision, no I/O, unit-tested over the truth table (`tests/unit/providers.sh`).
- `ai_tools_agent_sweeps_at_exit <handback-declaration>` — the pure handback-driver decision
  (above), likewise no I/O and unit-tested.
- `ai_tools_enabled_agents` — prints `name<TAB>npm_package<TAB>launcher` per enabled installed agent.
- `ai_tools_enabled_integrations` — prints one enabled installed integration name per line.
- `ai_tools_agent_manifest_field <name> <key>` — one further field of a trusted manifest, for a
  caller that has already resolved which agent it has. The name is allowlisted to a plain
  identifier before it becomes a path, so it addresses nothing outside the manifest directory.

Data-only stdout (safe in `$(...)`); enabled-but-uninstalled names and every trust refusal go to
stderr, and to journald when `log.lib.sh` is loadable.
`AI_TOOLS_{AGENTS,INTEGRATIONS}_DIR` and `AI_TOOLS_OPERATOR_CONF` are root-only test hooks.

`conf.lib.sh` is a **required** dependency: without it `providers.lib.sh` can neither parse a
manifest nor tell a trusted input from a planted one, and guessing either is the fail-open this
seam exists to prevent. It therefore returns non-zero and defines nothing, so every consumer loads
it as `source … && declare -F <resolver>` and resolves no providers when that fails — Node-only for
`ai-tools-bootstrap`, npm-only for `nvm-update`, no integration env for `ai-tools-run`.

## The `session-env.d` seam

A fragment `/usr/local/lib/ai-tools/session-env.d/<name>.env.sh` appends to two arrays the
launcher owns — `session_environment_options` (`--setenv=` entries) and `session_path_entries`
(PATH tail) — which `ai-tools-run` emits into the transient unit. Both provider kinds use it:
`ai-tools-run` sources each enabled **integration**'s fragment, then the resolved **agent**'s,
so the agent's pins are authoritative over an integration's. See [launch](launch.rule.md) for
where that sits in the launch sequence.

This is where per-agent environment lives, rather than as manifest fields: an agent's pins are
arbitrary `KEY=value` shell, and a fragment is a mechanism the seam already has.

The seam is **best-effort**, not the fail-closed tier `msg.lib`/`confinement.lib` hold: a missing
or untrusted lib, directory, or fragment yields no integration env and leaves the confined launch
unaffected, because the integration env is additive, not load-bearing. "Fail closed" here means
*no integration*, which is always a safe answer. Everything it sources is gated by the trust rules
above; a fragment self-gates on its host tool, so it is inert on a host without the toolchain even
when enabled.

A fragment runs in `ai-tools-run`'s own scope, so it appends to the two arrays and nothing else: it
must not exec, prompt, read stdin (the loop feeding it is on a process substitution), or depend on
the caller's environment, and it unsets its own temporaries.

## dotnet integration (`ai-tools-integration-dotnet`)

Integrates a **host-managed** .NET toolchain (RPM `dotnet`, at `/usr/bin/dotnet` +
`/usr/lib64/dotnet`); the package carries **no dotnet RPM dependency** and is inert without one. The
`ai-tools-integration` umbrella pulls it as a dnf **weak dependency** (`Recommends`), so it installs
by default on every host yet stays fully optional — removable with no effect on the rest of the
stack. `default_enable=no` (it widens surface: a new runtime exec, NuGet egress, a writable cache),
so a session gets dotnet only when `dotnet` is in `AI_TOOLS_INTEGRATIONS`.

- `session-env.d/dotnet.env.sh` self-gates on `/usr/bin/dotnet`, then sets `DOTNET_ROOT`,
  `NUGET_PACKAGES=/opt/ai-tools/.nuget/packages`, `DOTNET_CLI_HOME`, `DOTNET_CLI_TELEMETRY_OPTOUT`,
  `DOTNET_NOLOGO`, and `ASPNETCORE_ENVIRONMENT`/`DOTNET_ENVIRONMENT=Development`, and adds
  `/opt/ai-tools/.dotnet/tools` to PATH. The variables are those current for **.NET 8 LTS and
  later**; the .NET Core 2.x/3.x-era opt-outs (`DOTNET_SKIP_FIRST_TIME_EXPERIENCE`,
  `DOTNET_PRINT_TELEMETRY_MESSAGE`) are absent because the SDK no longer reads them.
  `DOTNET_CLI_HOME=/opt/ai-tools/.cache/dotnet` is what keeps the read-only shared-tools tree
  read-only: the SDK's own state (first-use sentinels, CLI logs) defaults to `$HOME/.dotnet`, which
  here IS that tree, so it is redirected into the already-writable, already-`ai_tools_home_t`
  `.cache` subtree — no extra fcontext. Only the root-owned tools dir joins PATH; a tool the agent
  installs for itself under `DOTNET_CLI_HOME` stays reachable by full path but never lands on the
  session PATH, so the sandbox cannot put an executable of its choosing on it.
- `ai-tools-dotnet` (root/sudo helper) `setup` creates the two dirs and labels them: the NuGet
  cache `/opt/ai-tools/.nuget` is agent-**writable** (`2770`, setgid), the shared tools
  `/opt/ai-tools/.dotnet` are **read-only** to the agent (`0755`, sudo-only writes). **Both** are
  labelled `ai_tools_home_t` via a local `semanage fcontext` (not a core-module change): the type
  grants `ai_tools_t` the SELinux access (write on the cache, exec on the tools) while the DAC modes
  are the enforced read/write boundary. `install-tools <pkg...>` installs shared global tools;
  `status` reports host SDKs/runtimes, and reads enablement through `ai_tools_enabled_integrations`
  so it reports the same verdict `ai-tools-run` reaches.
- Every step **fails loudly**. A directory it cannot create, or a label it cannot apply on a host
  that supports labelling, exits non-zero with the cause logged through `log.lib.sh` to journald and
  `/var/log/ai-tools/dotnet.log` (see [logging](logging.rule.md)) — a half-provisioned integration
  that looks installed surfaces later as an opaque denial inside a confined session. The genuine
  no-ops are recognized as such: `selinux_active` gates the labelling on SELinux being enabled,
  `policycoreutils` present, and the `ai_tools` module loaded, and skips with a logged line
  otherwise. The RPM `%post` runs `setup`, reports the remedy and exits non-zero on failure (rpm
  records a scriptlet failure against this package while the transaction completes — the right
  blast radius for a weakly-pulled optional integration); `%postun` drops the fcontexts and
  `restorecon`s what stays behind on final erase.

The `.nuget` fcontext + the dirs are the enforced-writable-cache path; the CLR runs on the already-
granted `execmem` (shared with V8). The one **SELinux bring-up unknown** is whether .NET needs
`execmod`/`execstack` on `/usr/lib64/dotnet/*.so` beyond `execmem` — verifiable only on an enforcing
host with real `restore`/`build`/`test`/`run` workloads (the `selinux/avc` loop). If needed, that is
the single line that would touch the core `.te` (still no new module).

## Deferred

- **Per-agent launcher symlink repoint.** The stable-symlink repoint (`ai-tools-claude-symlink`, the
  handback `SYMLINK` verb) validates a `.../bin/claude` path, so it is claude-specific; `nvm-update`
  repoints only `claude` and skips cleanly when it is not installed. Generalizing to arbitrary
  launchers travels with a second agent.
