---
paths:
  - "src/usr/local/lib/ai-tools/session-env.d/dotnet.env.sh"
  - "src/usr/local/lib/ai-tools/filters.d/dotnet.rules"
  - "src/usr/local/lib/ai-tools/integrations.d/dotnet.conf"
  - "src/usr/local/libexec/ai-tools/ai-tools-dotnet.sh"
  - "selinux/policy/ai_tools_tmpmap.te"
  - "selinux/policy/ai_tools_apphost.te"
  - "selinux/policy/ai_tools_netcore.te"
---

# Running .NET (CoreCLR) in the sandbox

The `dotnet` **integration** hands a session the host .NET toolchain (`DOTNET_ROOT`, a
sandbox-writable NuGet cache and CLI home, the shared tools dir on PATH — see
[providers](providers.rule.md) for the env/filters/helper mechanism). This rule is the other
half: what the **SELinux** confinement additionally needs, because CoreCLR's runtime behaviour —
memory-mapping a shared mutex, executing JIT'd code, opening diagnostic IPC sockets, running a
native host it built — reaches past the repo-only base domain. None of it is required by the Claude
Code agent itself, so all of it lives in **optional policy groups**, off by default, loaded only
where .NET is brought up. On a DAC-only host (no SELinux) none of this applies.

`ai-tools-dotnet`'s own subcommands are spelled to the standard in
[cli-grammar](cli-grammar.rule.md), which also sets where a root-only integration command lives.

## The three .NET policy groups

Each is a separate, composable group ([confinement](confinement.rule.md) covers the group
machinery). They are disjoint — one never implies another — so a session takes on only the surface
its workload needs, and the `ai-tools` status block nudges for each under enforcing when `dotnet`
is enabled.

| group | grants | needed for |
|---|---|---|
| `tmpmap` | `ai_tools_tmp_t:file map` | NuGet **restore** and **build** — the runtime mmaps a shared-memory mutex under `/tmp/.dotnet/shm`. Also git/SQLite in `/tmp`. |
| `apphost` | `tmpfs_t:file map+execute` (anonymous memfd) | **building/JIT-ing** an executable — CoreCLR maps generated code and the apphost from a memfd `PROT_EXEC`. `execmem` (base) covers anonymous exec; this covers a file-backed one. |
| `netcore` | runtime IPC (sockets/FIFOs, `getsid`, `/proc/sys/net`, loopback TCP connect) **and** executing a built binary from the project tree (`ai_tools_project_t:file execute`) | **`dotnet test`**, **multi-node MSBuild**, and **running** an apphost/testhost/R2R assembly the agent built |

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
MSBuild hangs on its worker **named pipes** (the `-m:1` workaround sidesteps them rather than
fixing them). A named-socket **connect** needs a second grant the base also lacks:
`create_stream_socket_perms` covers `connect` but **not `connectto`** (the peer permission to a
listener), so `dotnet test`'s Microsoft.Testing.Platform runner gets `EACCES` reaching its test
host over the `.local/share` socket even once the socket file exists. `netcore` §1 grants the
socket/FIFO transition and management **and** `self:unix_stream_socket connectto`; all of it is
benign — the sandbox's own processes doing socket/FIFO IPC in their own tmp/home, the same class as
the file management the base already grants.

`netcore` §2 is the boundary: **execute on `ai_tools_project_t`** is on-disk native code the sandbox
wrote, run as a new process image. It confers no new privilege (`execmem` already concedes
in-process native code, and `execute_no_trans` keeps the child in `ai_tools_t` with no entrypoint to
a more privileged domain), but it is the reason the whole `netcore` module is off by default and
`experimental`. `execmod` covers an R2R image relocated in place.

## Not SELinux

Two .NET fixes are runtime-env, not policy, and apply on a DAC-only host too:

- **`MSBUILDDISABLENODEREUSE=1`** (`dotnet.env.sh`) — persistent MSBuild nodes lock a prior
  project's output between builds (dotnet/msbuild#6461); disabling reuse makes sequential builds in
  one solution deterministic under the shared UID.
- **Verbosity** — `dotnet.rules` sets `-v q` on `build`/`publish`/`restore`/`run`/`test`
  ([filters](filters.rule.md)).

The `setfscreate` grant (base) is also .NET-adjacent — it silences the libselinux
"failed to set default file creation context" warnings most visible in `dotnet build`/restore
output — but it is a general coreutils fix in the core domain, not a .NET group
([confinement](confinement.rule.md)).

## Design notes

- **`netcore` bundles a benign half and a sensitive half in one module** by choice: a .NET
  bring-up wants both, and one `enable-group` is simpler than two. The `.te` sections them
  explicitly. If finer granularity is ever wanted (IPC without on-disk execute — e.g. a host that
  only runs in-process MSTest), §2 splits cleanly into its own group.
- **Base stays Claude-Code-minimal.** Even the benign IPC is kept out of the core domain, because
  the agent itself needs none of it; it is `.NET`-driven and loads with the `.NET` groups.
- **Graduation to stable** for each group needs the enforcing `selinux/avc` bring-up to trim the
  rule to the observed minimum (and, for `apphost`, scope to a private memfd type). `dotnet exec`
  of an R2R assembly is the case to watch for extra `map`/`execmod` on `ai_tools_project_t`.
