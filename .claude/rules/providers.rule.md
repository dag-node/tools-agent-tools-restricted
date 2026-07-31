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
  call it), `handback` (which side converges ownership — below), `entrypoint_fcontext` and
  `config_dir` (the two paths it declares to SELinux — below), `skills_dir` / `subagents_dir`
  (where inside its config directory it reads each shared asset kind, so the shared copies can be
  symlinked in — see [shipped-assets](shipped-assets.rule.md)), `default_enable`.
- integrations: `default_enable`.

Either kind may also ship `session-env.d/<name>.env.sh`, keyed by the same `<name>` — one flat
namespace across both kinds, so a provider name is unique host-wide. A package with commands of
its own may additionally ship `filters.d/<name>.rules`, keyed the same way, carrying the
token-saving rules for those commands (see [filters](filters.rule.md)). That set is read by an
agent's filter hook rather than by `ai-tools-run`, and it is not gated on provider enablement — a
rule is inert unless the agent runs the command it matches — so it is a rule-set name rather than
a provider capability.

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

## `entrypoint_fcontext` and `config_dir` — the agent declares its own paths

Two paths per agent must carry a type this policy defines, and both belong to the agent rather
than to the base, so the base SELinux module declares **neither** and the manifest carries both:

| manifest field | path | type | without it |
|---|---|---|---|
| `entrypoint_fcontext` | the launcher binary (a file-context regex; `[^/]+` spans the Node version directory) | `ai_tools_exec_t` | no domain transition — the session would run unconfined, so `ai-tools-run` refuses to launch |
| `config_dir` | the agent's control-plane directory, one component under `/opt/ai-tools` | `ai_tools_home_t` | the confined session cannot write its own state (the home root is `usr_t`) |

`ai-tools-relabel-agent` registers each as a local `semanage fcontext` rule and relabels what it
matches (see [updater](updater.rule.md)). A second agent package therefore brings both its binary
and its state directory into this policy without touching the base.

`config_dir` is more than a label: the agent's package **owns that directory** and the files in it
(`settings.json`, the hooks), while the base pins its mode (`CP_AGENT_CONFIG_MODE`,
setgid+sticky) and resolves the set of them (`ai_tools_agent_config_dirs` in
`control-plane.lib.sh`) for the installer, the labelling, the managed-asset seeding, and the
permission test. The agent's session-env fragment pins the same directory as its config variable
(`CLAUDE_CONFIG_DIR`), so the manifest and the fragment must agree.

Two constraints keep that from being a label-anything primitive, and both live in
`relabel.lib.sh`, not in the manifest:

- **The types are pinned there**, never in a manifest. An agent declares *which path* is which,
  never *what label* a path gets.
- **Each declaration must be containable**: the entrypoint pattern to an anchored literal head
  under `/opt/ai-tools/.nvm/versions/node/`, with no `..` and none of the regex constructs (`|`,
  groups) that could make it match elsewhere; the config directory to one plain component under
  the sandbox home. `tests/unit/relabel.sh` drives both predicates.

The rule's lifecycle follows the package: applied by the agent package's `%post` (and by
`install.sh`, `ai-tools-bootstrap`, the relabel watcher, and `ai-tools --relabel`), dropped by its
`%preun` on final erase via `ai-tools-relabel-agent --remove <agent>`.

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

- `ai_tools_provider_gate <conf-key>` — how a kind's enabled set is being decided (`allowlist` /
  `baseline` / `untrusted`), read-only and side-effect free. The resolvers read it, and so does
  `ai-tools --providers` (see [cli](cli.rule.md)), so an operator asking what is enabled and a
  session being launched consult one implementation.

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
  `NUGET_PACKAGES` and `DOTNET_CLI_HOME` under its state root, `DOTNET_CLI_TELEMETRY_OPTOUT`,
  `DOTNET_NOLOGO`, and `ASPNETCORE_ENVIRONMENT`/`DOTNET_ENVIRONMENT=Development`, and adds
  `integrations/dotnet/tools` to PATH. The variables are those current for **.NET 8 LTS and
  later**; the .NET Core 2.x/3.x-era opt-outs (`DOTNET_SKIP_FIRST_TIME_EXPERIENCE`,
  `DOTNET_PRINT_TELEMETRY_MESSAGE`) are absent because the SDK no longer reads them.
  `DOTNET_CLI_HOME=…/integrations/dotnet/cli` is what keeps the shared-tools tree read-only: the
  SDK's own state (first-use sentinels, CLI logs) defaults to `$HOME/.dotnet`, so it is pinned at
  a writable sibling inside the same state root. Only the root-owned tools dir joins PATH; a tool the agent
  installs for itself under `DOTNET_CLI_HOME` stays reachable by full path but never lands on the
  session PATH, so the sandbox cannot put an executable of its choosing on it.
- `filters.d/dotnet.rules` sets `--nologo -v q` on `dotnet build|publish|restore|run|test`. The
  SDK's verbosity has no environment-variable form, so it belongs in a command rule rather than in
  the fragment above; quiet verbosity keeps errors and warnings. See [filters](filters.rule.md).
- `ai-tools-dotnet` (root/sudo helper) `setup` creates that state root and its three
  directories: the NuGet cache and the SDK's CLI home are agent-**writable** (`2770`, setgid),
  the shared tools are **read-only** to the agent (`0755`, sudo-only writes). It applies **no**
  SELinux policy of its own — the base's static rule on `integrations(/.*)?` already maps the
  whole tree to `ai_tools_home_t`, so the type grants `ai_tools_t` the access (write on the
  cache, exec on the tools) while the DAC modes are the enforced read/write boundary. `setup`
  also drops the local fcontext rules earlier versions added for the old home-root dotdirs. `install-tools <pkg...>` installs shared global tools;
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

The state root's label comes from the base's static rule on `integrations(/.*)?`; the CLR runs on
the already-granted `execmem` (shared with V8).

**SELinux enforcing requires the `tmpmap` policy group for restore/build.** .NET backs a named
mutex with a shared-memory file under `/tmp/.dotnet/shm` and NuGet takes one on every restore, but
the core module holds no `map` on `ai_tools_tmp_t`, so without that grant the mmap fails `EACCES`
and `dotnet new`/`restore`/`build` abort. Running an already-built assembly (`dotnet exec`) works
regardless, and a DAC-only host is unaffected. The grant is **not dotnet-specific** — any tool
that mmaps a temp file needs it, `git` in a `/tmp` working tree included — so it lives in the
optional `tmpmap` policy group, off by default like the others, rather than in the base module or
in this integration. Enable it on an installed host with
`sudo ai-tools-admin selinux enable-group tmpmap` (or `selinux/install-selinux.sh enable-group
tmpmap` from a source checkout). See `selinux/policy/ai_tools_tmpmap.te`.

That group's one rule is `file:map`, which is mmap-at-all and **not** executable mapping:
`PROT_EXEC` on a file additionally requires `file:execute`, which this domain does not hold on its
tmp type, and `/tmp` is mounted `noexec`, which no SELinux rule can override. The remaining
**bring-up unknown** is whether .NET needs `execmod`/`execstack` on `/usr/lib64/dotnet/*.so`
beyond `execmem` — verifiable only on an enforcing host with real `restore`/`build`/`test`/`run`
workloads (the `selinux/avc` loop).

## Boundaries

Two limits of this seam are deliberate, stated so neither reads as an oversight:

**The provider namespace is flat.** A name is unique host-wide, not per kind: an agent and an
integration both called `foo` are one token in two different gating keys and share one fragment,
`session-env.d/foo.env.sh`. Every manifest and fragment is root-owned, so a collision is a
packaging mistake — a provider cannot capture another's fragment without root — which makes it a
correctness wart rather than a hole, and a naming convention (`ai-tools-agents-<name>` /
`ai-tools-integration-<name>`, so the clash is visible where it would be made) the lightest
mechanism that answers it. No enforcement code.

**An agent is an npm package on the sandbox's Node toolchain.** `npm_package` is effectively
required (a manifest naming none provisions nothing), `ai-tools-bootstrap`/`nvm-update` install it
with `npm install -g`, and `ai-tools-run` accepts an executable only under
`/opt/ai-tools/.nvm/versions/node/<semver>/bin/`. That assumption lives in exactly two places —
**provisioning** (which command installs the agent and where its launcher lands) and **exec
validation** (which paths may start a session) — and nowhere else in the seam.

### Fitting a second agent runtime

A non-npm agent is an open direction, not a closed one: the host-managed .NET toolchain already
sits in this seam as an integration, so a thin .NET agent is the near case. What it would add, and
what it would leave alone:

- **A `runtime` field on the agent manifest** (`nodejs` when absent, so today's manifests are
  unchanged) selecting both halves of the assumption above. `npm_package` becomes the `nodejs`
  runtime's provisioning key rather than a universal one.
- **An exec root and a launcher shape per runtime.** The current rule is `<nvm>/versions/node/
  <semver>/bin/<launcher>`; the version directory pins the launcher to the toolchain version the
  updater installed. A dotnet global tool has no version directory, so its rule is its own exec
  root (`/opt/ai-tools/integrations/dotnet/tools/<launcher>`, root-owned and read-only to the agent — stricter
  than the nvm tree, which the sandbox account owns). What every rule must keep is the property
  the current one carries: an absolute, `..`-free path under a known sandbox toolchain root whose
  launcher an **enabled manifest claims**, so nothing the agent can drop beside a launcher starts
  a session.
- **A provisioning branch** for that runtime (`dotnet tool install --tool-path` in place of
  `npm install -g`), invoked from the same enabled-agent loop `ai-tools-bootstrap` and
  `nvm-update` already run.
- **Its SELinux entrypoint file-context**, which the manifest already carries per agent, so a new
  entrypoint takes `ai_tools_exec_t` without touching the base policy.

Unchanged: enablement and its fail-closed trust rules, the `session-env.d` fragment (a .NET agent
inherits the dotnet integration's `DOTNET_ROOT`/NuGet-cache pins by enabling it), the `handback`
capability (an agent with no hook system declares `handback=none` and gets the shim's session-end
sweep), its own `config_dir` (mode, label, and ownership already follow the manifest), the
confinement unit, and the single `%ai-ops` sudoers grant.

None of it is built. The fields are named here so the first non-npm agent adds a runtime to the
seam rather than reshaping it.
