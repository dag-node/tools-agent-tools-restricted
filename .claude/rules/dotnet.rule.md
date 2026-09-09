---
paths:
  - "src/usr/local/lib/ai-tools/session-env.d/dotnet.env.sh"
  - "src/usr/local/lib/ai-tools/filters.d/dotnet.rules"
  - "src/usr/local/lib/ai-tools/integrations.d/dotnet.conf"
  - "src/usr/local/lib/ai-tools/admin-commands.d/**"
  - "selinux/policy/ai_tools_tmpmap.te"
  - "selinux/policy/ai_tools_apphost.te"
  - "selinux/policy/ai_tools_netcore.te"
---

# Running .NET (CoreCLR) in the sandbox

The `dotnet` **integration** (`ai-tools-integration-dotnet`) hands a session the host .NET
toolchain through the provider seam — a manifest, a session-env fragment, a filter rule set, and a
contributed `ai-tools-admin` domain, whose contracts are [providers](providers.rule.md). This rule
holds what each of those does for .NET, and what the **SELinux** confinement additionally needs,
because CoreCLR's runtime behaviour — memory-mapping a shared mutex, executing JIT'd code, opening
diagnostic IPC sockets, running a native host it built — reaches past the repo-only base domain.
None of that is required by the Claude Code agent itself, so all of it lives in **optional policy
groups**, off by default, loaded only where .NET is brought up. On a DAC-only host (no SELinux) the
groups do not apply and the integration alone is the whole mechanism.

## The integration

Integrates a **host-managed** .NET toolchain (RPM `dotnet`, at `/usr/bin/dotnet` +
`/usr/lib64/dotnet`); the package carries **no dotnet RPM dependency** and is inert without one. The
`ai-tools-integration` umbrella pulls it as a dnf **weak dependency** (`Recommends`), so it installs
by default on every host yet stays fully optional — removable with no effect on the rest of the
stack. `default_enable=no` (it widens surface: a new runtime exec, NuGet egress, a writable cache),
so a session gets dotnet only when `dotnet` is in `AI_TOOLS_INTEGRATIONS`.

- `session-env.d/dotnet.env.sh` self-gates on `/usr/bin/dotnet`, then sets the variables the
  fragment declares — the toolchain root, the NuGet cache and CLI home under its state root, the
  telemetry and banner opt-outs, the MSBuild node-reuse switch (below), and the `Development`
  environment — and adds `integrations/dotnet/tools` to PATH. The set is the one current for
  **.NET 8 LTS and later**; the .NET Core 2.x/3.x-era opt-outs (`DOTNET_SKIP_FIRST_TIME_EXPERIENCE`,
  `DOTNET_PRINT_TELEMETRY_MESSAGE`) are absent because the SDK does not read them.
  `DOTNET_CLI_HOME=…/integrations/dotnet/cli` is what keeps the shared-tools tree read-only: the
  SDK's own state (first-use sentinels, CLI logs) defaults to `$HOME/.dotnet`, so it is pinned at
  a writable sibling inside the same state root. Only the root-owned tools dir joins PATH; a tool
  the agent installs for itself under `DOTNET_CLI_HOME` stays reachable by full path but never
  lands on the session PATH, so the sandbox cannot put an executable of its choosing on it.
- `filters.d/dotnet.rules` quiets `build`, `publish`, `restore`, `run` and `test` with `-v q`;
  the rule, and why verbosity is a command rule rather than a fragment variable, are in
  [filters](filters.rule.md).
- `admin-commands.d/dotnet` is this package's contributed domain, so its administration is spelled
  `sudo ai-tools-admin dotnet <verb>` ([cli-grammar](cli-grammar.rule.md) for the spelling).
  `dotnet bootstrap` creates that state root and its three directories: the NuGet cache and the
  SDK's CLI home are agent-**writable** (`2770`, setgid), the shared tools are **read-only** to the
  agent (`0755`, root-only writes). It applies **no** SELinux policy of its own — the base's static
  rule on `integrations(/.*)?` already maps the whole tree to `ai_tools_home_t`, so the type grants
  `ai_tools_t` the access (write on the cache, exec on the tools) while the DAC modes are the
  enforced read/write boundary. It also drops the local fcontext rules earlier versions added for
  the old home-root dotdirs. `dotnet tools install <pkg...>` installs shared global tools;
  `dotnet status` reports host SDKs/runtimes, and reads enablement through
  `ai_tools_enabled_integrations` so it reports the same verdict `ai-tools-run` reaches. Its
  journald tag and log file are `ai-tools-dotnet`/`dotnet.log`, the identity an operator queries.
- Every step **fails loudly**. A directory it cannot create, or a label it cannot apply on a host
  that supports labelling, exits non-zero with the cause logged through `log.lib.sh` to journald and
  `/var/log/ai-tools/dotnet.log` (see [logging](logging.rule.md)) — a half-provisioned integration
  that looks installed surfaces later as an opaque denial inside a confined session. The genuine
  no-ops are recognized as such: `selinux_active` gates the labelling on SELinux being enabled,
  `policycoreutils` present, and the `ai_tools` module loaded, and skips with a logged line
  otherwise. The RPM `%post` runs `dotnet bootstrap`, reports the remedy and exits non-zero on
  failure (rpm records a scriptlet failure against this package while the transaction completes —
  the right blast radius for a weakly-pulled optional integration); `%postun` drops the fcontexts and
  `restorecon`s what stays behind on final erase.

The state root's label comes from the base's static rule on `integrations(/.*)?`; the CLR runs on
the already-granted `execmem` (shared with V8). Everything past that point is the optional groups
below, which a DAC-only host does not need.

## The three .NET policy groups

Each is a separate, composable group ([confinement](confinement.rule.md) covers the group
machinery). They are disjoint — one never implies another — so a session takes on only the surface
its workload needs, and the `ai-tools` status block nudges for each under enforcing when `dotnet`
is enabled.

| group | grants | needed for |
|---|---|---|
| `tmpmap` | `ai_tools_tmp_t:file map` | NuGet **restore** and **build** — the runtime mmaps a shared-memory mutex under `/tmp/.dotnet/shm`. Also git/SQLite in `/tmp`. |
| `apphost` | `tmpfs_t:file map+execute` (anonymous memfd) | **building/JIT-ing** an executable — CoreCLR maps generated code and the apphost from a memfd `PROT_EXEC`. `execmem` (base) covers anonymous exec; this covers a file-backed one. |
| `netcore` | runtime IPC (sockets/FIFOs, `getsid`, `/proc/sys/net`, loopback TCP connect) **and** execute on every file labelled `ai_tools_project_t` (`file { map execute execute_no_trans execmod }`) — a built binary, and equally a git hook or a project script | **`dotnet test`**, **multi-node MSBuild**, and **running** an apphost/testhost/R2R assembly the agent built |

## Which groups a project needs

| workload | tmpmap | apphost | netcore |
|---|---|---|---|
| class **library** build | ✓ | | |
| **executable / host** build (console, ASP.NET Core, worker, single-file) | ✓ | ✓ | |
| **in-process** tests (MSTest on Microsoft.Testing.Platform) | ✓ | ✓ | ✓ (diagnostic socket) |
| **run** the built binary / out-of-process testhost (`xunit.v3`, `dotnet exec`, `dotnet run`) | ✓ | ✓ | ✓ (on-disk execute) |
| multi-node MSBuild (drop the `-m:1` workaround) | ✓ | ✓ | ✓ (worker pipes) |

The short version: **`tmpmap` to restore/build, `+apphost` to build an executable, `+netcore` to
test and run.** Enable all three for a full build-test-run .NET workflow.

## Why the denials split the way they do

An enforcing bring-up of a build-test-run cycle produces a small, fixed denial set. It sorts into
one benign group grant and one sensitive one — the reasoning that shaped `netcore`:

| denial (`ai_tools_t` →) | what it is | home |
|---|---|---|
| `tmp_t:sock_file create` | `/tmp/dotnet-diagnostic-*` port; MSBuild worker pipes | `netcore` §1 |
| `tmp_t:fifo_file create` | `/tmp/clr-debug-pipe-*` | `netcore` §1 |
| `ai_tools_home_t:sock_file create` | `.local/share/<guid>/.p` IPC socket | `netcore` §1 |
| `self:unix_stream_socket connectto` | Microsoft.Testing.Platform runner → test-host connect | `netcore` §1 |
| `self:process getsession` | `getsid(2)` from `csc`/`dotnet` | `netcore` §1 |
| `kernel_read_network_state_symlinks` | `/proc/sys/net/*` at startup | `netcore` §1 |
| `corenet_tcp_connect_generic_port` | xUnit/VSTest runner → out-of-process test host over loopback TCP | `netcore` §1 |
| `ai_tools_project_t:file execute` (+`execmod`/`execute_no_trans`) | running a native host / R2R code built in the tree | `netcore` §2 |

The `/tmp` socket/FIFO **create** denials have a precise cause: the base `files_tmp_filetrans`
transitions new `/tmp` **files/dirs/symlinks** to the private `ai_tools_tmp_t` but **not sockets or
FIFOs**, so those default to `tmp_t`, which the domain cannot create — which is why multi-node
MSBuild hangs on its worker **named pipes** (the `-m:1` workaround avoids the pipes). A
named-socket **connect** needs a second grant the base also lacks:
`create_stream_socket_perms` covers `connect` but **not `connectto`** (the peer permission to a
listener), so `dotnet test`'s Microsoft.Testing.Platform runner gets `EACCES` reaching its test
host over the `.local/share` socket even once the socket file exists. `netcore` §1 grants the
socket/FIFO transition and management **and** `self:unix_stream_socket connectto`; all of it is
benign — the sandbox's own processes doing socket/FIFO IPC in their own tmp/home, the same class as
the file management the base already grants.

`netcore` §2 is the boundary: **execute on `ai_tools_project_t`** is on-disk code run as a new
process image, and the grant covers every file carrying that label — every file in every claimed
project, a built binary and a git hook alike — so with `netcore` loaded git runs a project's hooks,
and `./configure` or a Makefile recipe runs the script the tree carries. It does not grant a new
privilege (`execmem` already concedes in-process native code, and `execute_no_trans` keeps the
child in `ai_tools_t` with no entrypoint to a more privileged domain), but it is the reason the
whole `netcore` module is off by default; its stability is the registry's field to state
(`selinux-groups.lib.sh`). `execmod` covers an R2R image relocated in place.

## Not SELinux

One .NET fix is runtime-env, not policy, and applies on a DAC-only host too:
**`MSBUILDDISABLENODEREUSE=1`** (`dotnet.env.sh`) — persistent MSBuild nodes lock a prior project's
output between builds (dotnet/msbuild#6461); disabling reuse makes sequential builds in one solution
deterministic under the shared UID.

The `setfscreate` grant (base) is also .NET-adjacent — it silences the libselinux
"failed to set default file creation context" warnings most visible in `dotnet build`/restore
output — but it is a general coreutils fix in the core domain, not a .NET group
([confinement](confinement.rule.md)).

## Design notes

- **`netcore` bundles a benign half and a sensitive half in one module** by choice: a .NET
  bring-up wants both, and enabling one group is simpler than enabling two. The `.te` sections
  them explicitly, and §2 splits cleanly into its own group where IPC without on-disk execute is
  the need (a host that only runs in-process MSTest).
- **Base stays Claude-Code-minimal.** Even the benign IPC is kept out of the core domain, because
  the agent itself needs none of it; it is `.NET`-driven and loads with the `.NET` groups.
- **A group graduates to `stable`** — the registry field in `selinux-groups.lib.sh` that decides
  how it ships and which front door enables it — after an enforcing `selinux/avc` bring-up trims
  its rule to the observed minimum (for `apphost`, scoping to a private memfd type as well).
  `dotnet exec` of an R2R assembly is the case to watch for extra `map`/`execmod` on
  `ai_tools_project_t`.
