---
paths:
  - "src/usr/local/lib/ai-tools/providers.lib.sh"
  - "src/usr/local/lib/ai-tools/agents.d/**"
  - "src/usr/local/lib/ai-tools/integrations.d/**"
  - "src/usr/local/lib/ai-tools/claude-run.d/**"
  - "src/usr/local/sbin/ai-tools/ai-tools-dotnet.sh"
---

# Provider manifests, enablement, and integrations

The toolchain and launch layers provision providers without naming any: which providers exist,
and how each is provisioned, comes from per-package manifests gated by `operator.conf`, resolved
by `providers.lib.sh`. Two provider kinds share the mechanism:

- **Agents** (`ai-tools-agents-*`) — the AI coding agents. `ai-tools-bootstrap`/`nvm-update` install
  each enabled agent's npm package and symlink its launcher (see [updater](updater.rule.md)).
- **Integrations** (`ai-tools-integration-*`) — host-toolchain layers. `claude-run` sources each
  enabled integration's session-env fragment (see [launch](launch.rule.md)).

## Manifests

Each installed member package ships one manifest, `/usr/local/lib/ai-tools/{agents,integrations}.d/
<name>.conf`, `644 root:root`. `<name>` (the basename) is the token an operator writes in
`AI_TOOLS_AGENTS` / `AI_TOOLS_INTEGRATIONS`. It is `KEY=value` data — **parsed, never sourced**, the
same posture as `operator.conf`/`skip-dirs.lib.sh`, so a malformed or tampered manifest cannot
execute code in the privileged scripts that read it:

- agents: `npm_pkg` (the registry package), `launcher` (the bin symlinked at
  `/opt/ai-tools/bin/<launcher>`), `default_enable`.
- integrations: `default_enable`. The integration's session env lives in
  `claude-run.d/<name>.env.sh`, keyed by the same `<name>`.

`ai-tools-base` owns the three directories (`agents.d`, `integrations.d`, `claude-run.d`) and ships
`providers.lib.sh`; each member package ships only its own files into them.

## Enablement is fail-closed

`operator.conf` `AI_TOOLS_AGENTS` / `AI_TOOLS_INTEGRATIONS` (space-separated names) gates each kind:

- **key present** → enabled = exactly the listed names (an allowlist; an empty value = none).
  `default_enable` is ignored, so an operator's explicit list always wins.
- **key absent** → enabled = installed providers with `default_enable=yes` (the baseline). Both
  keys ship commented in the template, so a fresh or upgraded host (whose `%config(noreplace)` file
  may predate them) runs the baseline.
- **config unreadable/malformed** → treated as absent (the baseline; never "enable all").
- **a listed name with no installed manifest** → reported to stderr and skipped, never guessed.

A `default_enable=yes` is the shipping package's claim that its provider widens no host surface
beyond the sandbox (Claude Code); a surface-widening one ships `default_enable=no` and is enabled
only when an operator names it (dotnet). This is the fail-closed default-when-unset rule.

## Resolution

`providers.lib.sh` splits a pure verdict from the I/O, mirroring `confinement.lib.sh`:

- `ai_tools_provider_is_enabled <name> <default_enable> <allowlist_active> <allowlist>` — the pure
  enablement decision, no I/O, unit-tested over the truth table (`tests/unit/providers.sh`).
- `ai_tools_enabled_agents` — prints `name<TAB>npm_pkg<TAB>launcher` per enabled installed agent.
- `ai_tools_enabled_integrations` — prints one enabled installed integration name per line.

Data-only stdout (safe in `$(...)`); enabled-but-uninstalled names warn to stderr.
`AI_TOOLS_{AGENTS,INTEGRATIONS}_DIR` and `AI_TOOLS_OPERATOR_CONF` are root-only test hooks.

## The `claude-run.d` session-env seam

`claude-run` reads the enabled integrations and, for each, sources
`/usr/local/lib/ai-tools/claude-run.d/<name>.env.sh` — a fragment that appends to the launcher's
`_setenv` (session env) and `_extra_path` (PATH tail), emitted into the transient unit. The seam
is **best-effort**, not the fail-closed tier `msg.lib`/`confinement.lib` hold: a missing
`providers.lib.sh` yields no integration env and leaves the confined launch unaffected, because the
integration env is additive, not load-bearing. A fragment is sourced as `SANDBOX_USER` (post-sudo),
so it is trusted **only** because it is root-owned and not group/other-writable — `claude-run` skips
and logs any fragment failing that check, so the agent cannot inject env by planting a writable
fragment. A fragment self-gates on its host tool, so it is inert on a host without the toolchain
even when enabled.

## dotnet integration (`ai-tools-integration-dotnet`)

Integrates a **host-managed** .NET toolchain (RPM `dotnet`, at `/usr/bin/dotnet` +
`/usr/lib64/dotnet`); the package carries **no dotnet RPM dependency** and is inert without one. The
`ai-tools-integration` umbrella pulls it as a dnf **weak dependency** (`Recommends`), so it installs
by default on every host yet stays fully optional — removable with no effect on the rest of the
stack. `default_enable=no` (it widens surface: a new runtime exec, NuGet egress, a writable cache),
so a session gets dotnet only when `dotnet` is in `AI_TOOLS_INTEGRATIONS`.

- `claude-run.d/dotnet.env.sh` self-gates on `/usr/bin/dotnet`, then sets `DOTNET_ROOT`,
  `NUGET_PACKAGES=/opt/ai-tools/.nuget/packages`, the telemetry/first-run-off vars, and
  `ASPNETCORE_ENVIRONMENT`/`DOTNET_ENVIRONMENT=Development`, and adds `/opt/ai-tools/.dotnet/tools`
  to PATH.
- `ai-tools-dotnet` (root/sudo helper) `setup` creates the two dirs and labels them: the NuGet
  cache `/opt/ai-tools/.nuget` is agent-**writable** (`2770`, setgid), the shared tools
  `/opt/ai-tools/.dotnet` are **read-only** to the agent (`0755`, sudo-only writes). **Both** are
  labelled `ai_tools_home_t` via a local `semanage fcontext` (not a core-module change): the type
  grants `ai_tools_t` the SELinux access (write on the cache, exec on the tools) while the DAC modes
  are the enforced read/write boundary. `install-tools <pkg...>` installs shared global tools;
  `status` reports host SDKs/runtimes and enablement. The RPM `%post` runs `setup`; `%postun` drops
  the fcontexts on final erase.

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
