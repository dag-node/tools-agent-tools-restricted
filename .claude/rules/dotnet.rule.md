---
paths:
  - "src/usr/local/lib/ai-tools/session-env.d/dotnet.env.sh"
  - "src/usr/local/lib/ai-tools/filters.d/dotnet.rules"
  - "src/usr/local/lib/ai-tools/integrations.d/dotnet.conf"
  - "src/usr/local/lib/ai-tools/admin-commands.d/**"
  - "selinux/policy/ai_tools_tmpmap.te"
  - "selinux/policy/ai_tools_apphost.te"
  - "selinux/policy/ai_tools_localipc.te"
  - "selinux/policy/ai_tools_buildexec.te"
  - "selinux/policy/ai_tools_dotnet.te"
  - "selinux/policy/ai_tools_dotnet.fc"
  - "src/usr/local/share/man/man5/ai-tools-providers.5"
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
  telemetry and banner opt-outs, the MSBuild node-reuse switch, and the `Development`
  environment — and adds `integrations/dotnet/tools` to PATH. The set is the one current for
  **.NET 8 LTS and later**; the .NET Core 2.x/3.x-era opt-outs (`DOTNET_SKIP_FIRST_TIME_EXPERIENCE`,
  `DOTNET_PRINT_TELEMETRY_MESSAGE`) are absent because the SDK does not read them.
  `DOTNET_CLI_HOME=…/integrations/dotnet/cli` is what keeps the shared-tools tree read-only: the
  SDK's own state (first-use sentinels, CLI logs) defaults to `$HOME/.dotnet`, so it is pinned at
  a writable sibling inside the same state root. Only the root-owned tools dir joins PATH; a tool
  the agent installs for itself under `DOTNET_CLI_HOME` stays reachable by full path but never
  lands on the session PATH, so the sandbox cannot put an executable of its choosing on it.
- The manifest (`ai-tools-providers(5)` is the operator's statement of every key) declares what
  the SELinux layer needs from this toolchain: `build_output_dirs`, the directories that hold its
  build output, which `relabel.lib.sh` maps to the build-output type; `selinux_layout_module`,
  the module that types them at creation; and `selinux_groups`, the policy groups a full workflow
  needs (see
  [The policy groups](#the-policy-groups-a-net-workflow-needs-and-the-layout-module-that-is-not-one)).
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
  `restorecon`s what stays behind on final erase. `bootstrap` also loads the layout module the
  manifest declares, and `status` reports it and the declared groups' state.

The state root's label comes from the base's static rule on `integrations(/.*)?`; the CLR runs on
the already-granted `execmem` (shared with V8). Everything past that point is the optional
groups, which a DAC-only host does not need.

## The policy groups a .NET workflow needs, and the layout module that is not one

The groups are named for the **capability** each grants, not for .NET, because each is a class of
SELinux access another toolchain needs too ([confinement](confinement.rule.md) covers the group
machinery). They are disjoint — one never implies another — so a session takes on only the surface
its workload needs. What is .NET's about them is declared in the integration's manifest
(`ai-tools-providers(5)`): `selinux_groups` names the set, and the `--providers` status block and
`ai-tools-admin dotnet status` read that key to name the ones not loaded, with the command that
enables them. No group is enabled automatically.

| group | grants | needed for |
|---|---|---|
| `tmpmap` | `ai_tools_tmp_t:file map` | NuGet **restore** and **build** — the runtime mmaps a shared-memory mutex under `/tmp/.dotnet/shm`. Also git/SQLite in `/tmp`. |
| `apphost` | `tmpfs_t:file map+execute` (anonymous memfd) | **building/JIT-ing** an executable — CoreCLR maps generated code and the apphost from a memfd `PROT_EXEC`. `execmem` (base) covers anonymous exec; this covers a file-backed one. Experimental until its grant is scoped to a private memfd type; it takes a mechanism name then. |
| `localipc` | unix sockets and FIFOs under `/tmp` and the home state, `connectto` on the domain's own stream sockets, loopback TCP to an ephemeral port, `getsid`, `/proc/sys/net` | **`dotnet test`** (diagnostic socket, test-host connect) and **multi-node MSBuild** (worker pipes); also a dev server and the browser driven against it, a language server |
| `buildexec` | execute on `ai_tools_project_build_t` (`file { map execute execute_no_trans execmod }`), the base's build-output type | **running** an apphost/testhost/R2R image the agent built |

**The layout module `ai_tools_dotnet` is not a group.** It carries the `bin`/`obj`/`artifacts`
transitions and the sandbox-clone rule that put .NET's output on the build-output type at creation
([The build-output type](#the-build-output-type-and-what-scoping-to-it-does-and-does-not-do)),
and it does not add any permission, so it is not an operator's
consent point:
`ai-tools-admin dotnet bootstrap` loads it where the policy package is installed, the policy
package's `%post` loads the layout module of every installed integration that declares one
(`selinux_layout_module`), the integration's `%postun` unloads it on final erase, and
`install-selinux.sh install`/`rebuild` compile and load it from source. Without it, output is
typed at the next relabel instead of when it is created.

## Which groups a project needs

| workload | tmpmap | apphost | localipc | buildexec |
|---|---|---|---|---|
| class **library** build | ✓ | | | |
| **executable / host** build (console, ASP.NET Core, worker, single-file) | ✓ | ✓ | | |
| **run** an IL-only assembly through the host binary (`dotnet exec App.dll`) | | ✓ | | |
| **in-process** tests (MSTest on Microsoft.Testing.Platform) | ✓ | ✓ | ✓ | |
| **run** a native host / out-of-process testhost / R2R image (`dotnet run`, `./App`, `xunit.v3`) | ✓ | ✓ | ✓ | ✓ |
| multi-node MSBuild (drop the `-m:1` workaround) | ✓ | ✓ | ✓ | |

The short version: **`tmpmap` to restore/build, `+apphost` to build an executable, `+localipc` to
test, `+buildexec` to run what was built.** Enable all four for a full build-test-run .NET
workflow; `ai-tools-admin selinux groups enable` takes them in one command, and the experimental
one is compiled from a source checkout.

An IL-only assembly run through the host binary does not need execute on any project file: the process
image is `/usr/bin/dotnet`, the assembly is mapped for reading, and the JIT emits into the memfd
mapping `apphost` covers, so that row holds wherever in the tree the assembly sits. What
`buildexec` is for is a process image or an executable mapping that *is* a project file: the
apphost ELF, a test host, a ReadyToRun image.

## Why the denials split the way they do

An enforcing bring-up of a build-test-run cycle produces a small, fixed denial set. It sorts into
one benign group and one sensitive one — the reasoning that shaped `localipc` and `buildexec`:

| denial (`ai_tools_t` →) | what it is | home |
|---|---|---|
| `tmp_t:sock_file create` | `/tmp/dotnet-diagnostic-*` port; MSBuild worker pipes | `localipc` |
| `tmp_t:fifo_file create` | `/tmp/clr-debug-pipe-*` | `localipc` |
| `ai_tools_home_t:sock_file create` | `.local/share/<guid>/.p` IPC socket | `localipc` |
| `self:unix_stream_socket connectto` | Microsoft.Testing.Platform runner → test-host connect | `localipc` |
| `self:process getsession` | `getsid(2)` from `csc`/`dotnet` | `localipc` |
| `kernel_read_network_state_symlinks` | `/proc/sys/net/*` at startup | `localipc` |
| `corenet_tcp_connect_generic_port` | xUnit/VSTest runner → out-of-process test host over loopback TCP | `localipc` |
| `ai_tools_project_build_t:file execute` (+`execmod`/`execute_no_trans`) | running a native host / R2R code built in the tree | `buildexec` |

The `/tmp` socket/FIFO **create** denials have a precise cause: the base `files_tmp_filetrans`
transitions new `/tmp` **files/dirs/symlinks** to the private `ai_tools_tmp_t` but **not sockets or
FIFOs**, so those default to `tmp_t`, which the domain cannot create — which is why multi-node
MSBuild hangs on its worker **named pipes** (the `-m:1` workaround avoids the pipes). A
named-socket **connect** needs a second grant the base also lacks:
`create_stream_socket_perms` covers `connect` but **not `connectto`** (the peer permission to a
listener), so `dotnet test`'s Microsoft.Testing.Platform runner gets `EACCES` reaching its test
host over the `.local/share` socket even once the socket file exists. `localipc` grants the
socket/FIFO transition and management **and** `self:unix_stream_socket connectto`; all of it is
benign — the sandbox's own processes doing socket/FIFO IPC in their own tmp/home, the same class as
the file management the base already grants.

`buildexec` is the boundary: **execute on `ai_tools_project_build_t`** is on-disk code run as a
new process image. It does not grant a new privilege (`execmem` already concedes in-process native
code, and `execute_no_trans` keeps the child in `ai_tools_t` with no entrypoint to a more
privileged domain), but it is the reason the module is off by default; its stability is the
registry's field to state (`selinux-groups.lib.sh`). `execmod` covers an R2R image relocated in
place.

### The build-output type, and what scoping to it does and does not do

`ai_tools_project_build_t` is a second project type the **base** declares, mirroring every grant it
holds on `ai_tools_project_t` (`ai_tools_t` manage and `map`, `unconfined_t` manage and relabel,
`ai_tools_handback_t` manage), so a build, an operator's own work, a claim relabel and the ownership
handback treat the two types alike. The base names **no directory** for it — a base that named
`bin/` would carry one toolchain's layout, which the provider seam exists to keep out of it — and
declares it rather than the group because `semanage fcontext` refuses a type the loaded policy does
not define, and the per-project rule is written whether or not any group is loaded. `buildexec`
grants execute on this type and not on `ai_tools_project_t`, so loading it lets the session run
what it built without git running a project's hooks or a Makefile recipe running a script the tree
carries.

**This is a convenience, not a security control.** The type follows the directory *name*: a
script the session writes under `bin/`, and a source directory that happens to be called `bin/`
(this repository's own `bin/` and `src/opt/ai-tools/bin/`), carry it too, and with `buildexec`
loaded the files in them are executable to the session. That is the same class as a script an
agent drops under `bin/`, it is accepted, and it is why the group stays off by default. The
narrowing is not presented anywhere as closing it.

**Which names, declared once as data and twice as policy literals.** The `dotnet` integration
manifest's `build_output_dirs` (`bin obj artifacts`: the SDK's defaults, and the root of the .NET 8
artifacts layout, whose own `bin`, `obj`, `publish` and `package` sit under it) is the declared
set. `relabel.lib.sh` reads it from every **installed** integration manifest — installed, not
enabled, since a label is a property of the tree and stays correct whichever integrations a later
session enables — validates each name to one plain component, and writes a second per-project
rule beside the project rule, `<dir>(/.*)?/(bin|obj|artifacts)(/.*)?`, so existing output at any
depth takes the type at claim and at `install-selinux.sh relabel`. The same three names are
literals in the layout module: `filetrans_pattern` rules in `ai_tools_dotnet.te` type a directory
of that name at creation, for `ai_tools_t` and for `unconfined_t`, so a fresh build and an
operator's own build both land on the type with no relabel, and a static rule in
`ai_tools_dotnet.fc` covers sandbox clones, which take no per-project rule. The three MUST agree:
a name known to the manifest alone is typed only at the next relabel, and one known to the policy
alone only when it is created. The **precedence** of the build rule over the project rule, and the
`matchpathcon` check that verifies it on a host, are stated in `ai_tools_project_build_pattern`
(`relabel.lib.sh`); the same property holds between the two clone rules.

What follows from that placement:

- A project that redirects its output (`OutDir`, `-o`, `BaseIntermediateOutputPath`) to a name
  outside the set gets `ai_tools_project_t` output, which `buildexec` does not let it run.
- Without the layout module, a session's build creates `bin/` as `ai_tools_project_t`; the next
  relabel corrects it, and neither type is executable without `buildexec`, so the difference has
  no effect until then. Both group paths restore labels after a module change:
  `install-selinux.sh enable-group`/`disable-group` re-run the project and clone sweeps, and
  `ai-tools-admin selinux groups enable`/`disable` restore the sandbox-clone area, the one tree a
  module's own file contexts decide.
- `SKIP_ARTIFACT_DIRS` (`skip-dirs.lib.sh`) is a walk-cost setting with its own name set; the two
  mechanisms do not read each other.
- `ai_tools_project_labelled` and the project verdict in `--status` read the project root's type
  alone; a build directory carrying the wrong type is not reported anywhere. A build-type check
  belongs in `dotnet status`, and is not built.
- Unclaim finds the build rule by **listing** the local rules registered under the project rule,
  so a rule written under an earlier name set is dropped with the claim and does not keep a
  subtree of an unclaimed project on a type the confined domain manages.

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

- **Groups are named for the capability, and the integration names the set.** `localipc` and
  `buildexec` each read as one class of access an administrator could have written, and neither
  module names a toolchain. A host that only runs in-process MSTest enables `localipc` without
  `buildexec`, and a Node workload driving a browser over a socket enables `localipc` without any
  .NET at all. What is .NET's — the output layout and the list of groups — is the integration's
  manifest and its layout module, so a second toolchain adds a manifest and a layout module and
  touches neither the base nor a group.
- **Base stays Claude-Code-minimal.** Even the benign IPC is kept out of the core domain, because
  the agent itself needs none of it; it is toolchain-driven and loads with the groups.
- **A group graduates to `stable`** — the registry field in `selinux-groups.lib.sh` that decides
  how it ships and which front door enables it — after an enforcing `selinux/avc` bring-up trims
  its rule to the observed minimum. `localipc` and `buildexec` are stable: the IPC rules were
  brought up against `dotnet test` and multi-node MSBuild, and the execute rule only narrows the
  grant that bring-up carried. `apphost` stays experimental until its grant is scoped from the
  shared `tmpfs_t` to a private memfd type through a `type_transition` and verified on an
  enforcing host; it is renamed for the mechanism (`memfdexec`) in the same change, and the
  former-module seam carries a host across. `dotnet exec` of an R2R assembly is the case to watch
  for extra `map`/`execmod` on `ai_tools_project_build_t`.
