---
paths:
  - "src/usr/local/lib/ai-tools/providers.lib.sh"
  - "src/usr/local/lib/ai-tools/agents.d/**"
---

# Agent provider manifests and enablement

The toolchain layer provisions agents without naming any: which AI agents to install, and how,
comes from per-package manifests gated by `operator.conf`, resolved by `providers.lib.sh`. This
is the seam that keeps `ai-tools-bootstrap` and `nvm-update` (see [updater](updater.rule.md))
agent-agnostic — neither carries a hardcoded npm package or launcher.

## Manifest

Each installed `ai-tools-agents-*` package ships one manifest,
`/usr/local/lib/ai-tools/agents.d/<name>.conf`, `644 root:root`. `<name>` (the basename) is the
token an operator writes in `AI_TOOLS_AGENTS`. It is `KEY=value` data — **parsed, never
sourced**, the same posture as `operator.conf`/`skip-dirs.lib.sh`, so a malformed or tampered
manifest cannot execute code in the privileged toolchain scripts that read it:

- `npm_pkg` — the registry package the toolchain installs and keeps current.
- `launcher` — the bin symlinked at `/opt/ai-tools/bin/<launcher>` for the wrapper to resolve.
- `default_enable` — `yes` provisions the agent when `operator.conf` names no explicit set.

The `agents.d` directory is owned by `ai-tools-base` (which also ships `providers.lib.sh`); each
member package ships only its own `<name>.conf` into it. `ai-tools-agents-claude-code-restricted`
ships `claude-code.conf` (`@anthropic-ai/claude-code`, `claude`, `default_enable=yes`).

## Enablement is fail-closed

`operator.conf` `AI_TOOLS_AGENTS="<name> ..."` gates provisioning:

- **key present** → enabled = exactly the listed names (an allowlist; an empty value = no
  agents). `default_enable` is ignored, so an operator's explicit list always wins.
- **key absent** → enabled = installed agents with `default_enable=yes` (the baseline). This is
  the shipped default: the `AI_TOOLS_AGENTS` line is commented in the template, so a fresh or
  upgraded host (whose `%config(noreplace)` file may predate the key) provisions the baseline.
- **config unreadable/malformed** → treated as absent (the baseline; never "enable all").
- **a listed name with no installed manifest** → reported to stderr and skipped, never guessed
  into a package name.

A `default_enable=yes` on a manifest is the shipping package's claim that its agent widens no
host surface beyond the sandbox; a surface-widening integration ships `default_enable=no` and is
provisioned only when an operator names it. This is the fail-closed default-when-unset rule the
enablement design fixes.

## Resolution

`providers.lib.sh` splits a pure verdict from the I/O, mirroring `confinement.lib.sh` /
`npm-verify.lib.sh`:

- `ai_tools_agent_is_enabled <name> <default_enable> <allowlist_active> <allowlist>` — the pure
  enablement decision, no filesystem or config read, unit-tested over the truth table
  (`tests/unit/providers.sh`).
- `ai_tools_enabled_agents` — reads `agents.d` and `operator.conf`, applies the verdict, and
  prints one `name<TAB>npm_pkg<TAB>launcher` line per enabled installed agent (data-only stdout,
  warnings to stderr). `AI_TOOLS_AGENTS_DIR` and `AI_TOOLS_OPERATOR_CONF` are root-only test
  hooks (same rationale as `skip-dirs.lib.sh`'s override).

## Consumers

Both toolchain scripts source `providers.lib.sh` and provision the enabled set (see
[updater](updater.rule.md) for their mechanics):

- `ai-tools-bootstrap` installs each enabled agent's `npm_pkg` (npm `--allow-scripts` scoped to
  the full set) and symlinks each `launcher`. A bootstrap that precedes control-plane install
  finds no lib and provisions Node alone; a re-run picks up the agents.
- `nvm-update` builds its managed tool set as `npm` plus each enabled agent's `npm_pkg`. A
  missing lib (a broken, root-owned install) degrades to `npm` alone rather than failing —
  existing agents keep working, unrefreshed that run. An explicit `AI_TOOLS_GLOBAL_TOOLS`
  overrides the derived set.

## Deferred

- **Per-agent launcher symlink repoint.** The stable-symlink repoint (`ai-tools-claude-symlink`,
  the handback `SYMLINK` verb) validates a `.../bin/claude` path, so it is claude-specific;
  `nvm-update` repoints only `claude` and skips cleanly when claude is not installed. Generalizing
  to arbitrary launchers travels with a second agent.
- **Integrations and session env.** The `AI_TOOLS_INTEGRATIONS` switch and the `claude-run.d`
  session-env seam are not built here; they arrive with the first optional integration (dotnet),
  which needs them.
