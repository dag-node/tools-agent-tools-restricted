---
paths:
  - "selinux/policy/*.te"
  - "selinux/policy/*.fc"
  - "selinux/policy/*.if"
  - "selinux/policy/Makefile"
  - "selinux/install-selinux.sh"
  - "selinux/avc/*.sh"
  - "packaging/ai-tools.spec"
  - "selinux/README.md"
  - "src/opt/ai-tools/bin/ai-tools-run.sh"
  - "src/usr/local/lib/ai-tools/confinement.lib.sh"
  - "src/usr/local/lib/ai-tools/selinux-groups.lib.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-admin.sh"
---

# Session confinement (namespaces, SELinux, `/tmp`)

The kernel-level isolation `ai-tools-run` applies to each session unit, the SELinux
domain transition that confines it, and the `/tmp` model. Launch mechanics
(env, WorkingDirectory, sudoers) are in [launch](launch.rule.md).

## `RestrictNamespaces=yes` — the namespace filter

`RestrictNamespaces=yes` installs a seccomp filter blocking creation and joining of
every namespace type for the entire session process tree. This is the minimal
allow-list, and the set the agent needs is empty: an unprivileged process (the agent
holds an empty capability set) can only ever create a *user* namespace by itself, since every
other type (`cgroup`/`ipc`/`mnt`/`net`/`pid`/`uts`) requires `CAP_SYS_ADMIN`, reachable
only *through* a user namespace. Blocking `user` blocks all the rest transitively;
`=yes` makes that explicit and, unlike a `~user` denylist, fail-closes against any
namespace type a future kernel adds.

The load-bearing effect is closing `clone(CLONE_NEWUSER)`: an agent-accessible user
namespace lets a process appear as uid 0 inside it — the precondition for exploiting
kernel bugs that require root-in-userns and for overlay mounts that confuse
application-layer access checks. seccomp runs at syscall entry, before the SELinux LSM
hook, so this is also the only *enforcing* layer for user-ns creation: SELinux cannot
block it on this policy (the `process2` class carries no `create_user_ns` permission;
see ESC-001 in `ai_tools.te`). SELinux type enforcement survives into any namespace, so
the residual risk is kernel-CVE surface, not file-access bypass.

System-wide user namespaces stay enabled (Firefox and rootless Podman need them); the
filter is per-session and leaves every sysctl alone, so other workloads are unaffected. One
trade-off: `=yes` is incompatible with running unprivileged `bubblewrap` *inside* the
session (bwrap must create user+mnt namespaces), which the deferred bwrap phase must
resolve.

## `NoNewPrivileges` — explicit and always in effect

The unit sets `NoNewPrivileges=yes` for clarity, and the session runs under
`PR_SET_NO_NEW_PRIVS` regardless: `RestrictNamespaces=yes` installs its seccomp filter
via that flag, and NNP is a precondition for seccomp, not a setting the unit can opt
out of. The `ai_tools_t` transition completes under NNP because the policy grants
`process2:nnp_transition` to the authorised source domains (`ai_tools.te`); without that
grant, setting NNP (explicitly or via the filter) sends the session unconfined.

Under NNP the kernel runs `check_nnp_nosuid()` on the computed transition: it tries
`process2:nnp_transition` where the **`nnp_nosuid_transition` policy capability** is
enabled, falls back to `security_bounded_transition()` — a `typebounds` rule, which this
module does not declare — and returns `-EPERM` when both fail. `selinux_bprm_creds_for_exec()`
propagates that, so a missing grant **fails the `execve`** and the unit does not start.

**That failure direction is what makes the preflight's shape correct.** A denied transition
costs the launch, not the confinement, so it does not need a probe. The dangerous case is the
opposite one: a **mislabelled** entrypoint does not compute any transition, `new_sid ==
old_sid` returns 0 on `check_nnp_nosuid()`'s "no change in credentials" path, and the exec
succeeds in the manager's domain. Silent, and unconfined — which is the state the label
probe refuses on, and why the preflight probes the label rather than the transition.

The capability is turned on by an explicit `policycap nnp_nosuid_transition;` statement,
which stock EL policy carries. It was introduced to repair systemd-hardening breakage
without lowering security: applying `NoNewPrivileges` to a unit left only the `typebounds`
path, which is impractical to define per service domain and which reference policy does not
define at all, so services failed to reach their domains. A `0` therefore indicates an old
or custom-built base policy rather than a stricter one. Read it with
`cat /sys/fs/selinux/policy_capabilities/nnp_nosuid_transition` (expect `1`).

NNP drops `sudo`'s SUID bit, so the hooks reach root operations through the handback
socket bridge rather than `sudo` (see [handback-bridge](handback-bridge.rule.md)).

## SELinux domain transition

In `--pty` service mode the user manager performs the `exec`, so the SELinux
transition is keyed on the manager's domain — `init_t` on RHEL/Rocky 9 targeted — via
`domtrans_pattern(init_t, ai_tools_exec_t, ai_tools_t)` in `ai_tools.te` (an
`unconfined_t` rule is retained for a direct exec). The live manager domain and its
role are verifiable on the box (`ps -eZ | grep 'systemd --user'`); the policy
authorises both `unconfined_r` and `system_r` for `ai_tools_t`, so the transition fires
regardless of which role the manager holds. The manager's domain also needs `search` on
`ai_tools_project_t` for the `WorkingDirectory` chdir.

### The operator config subtree is mode-gated, not policy-gated

`~/.config/ai-tools` carries its own type, `ai_tools_conf_t`, applied by `install-selinux.sh`
with `semanage fcontext` because the operator's home path is dynamic. The narrow type is what
lets a grant name that one subtree instead of the whole of `config_home_t`; every other file in
`~/.config` stays refused, and a `dontaudit` keeps the git and Node probes that follow quiet.

Two domains hold the grant. `ai_tools_handback_t` is the load-bearing one — the root helpers
read `allowed-projects` and `secret-patterns` there on the operator's behalf, and without it
ownership handback silently no-ops. The confined session domain `ai_tools_t` holds it as well,
which sounds like a widening and is not: DAC and type enforcement must both allow, and at the
shipped `700` directory with `600` files DAC refuses the session before the type is reached.

What the session grant buys is that the **file mode stays the operator's knob**. An operator who
decides to open either file gets the read they intended rather than an AVC denial they could
clear only by editing policy. Opening `allowed-projects` lets a session read where it may work
instead of being told or probing for refusals; opening `secret-patterns` tells it which basenames
are quarantined, which it can already infer from the NOTICE each quarantine emits (see
[secret-handling](secret-handling.rule.md)). Removing the session grant was considered and
rejected, because it moves that decision from a mode the operator manages into policy they would
have to rebuild.

### Fail-closed confinement preflight

A session that fails to transition into `ai_tools_t` runs *unconfined*, and because
`ai-tools` maps to `unconfined_u` the module cannot forbid that (the ESC-001 base-policy
floor; `user_u` was rejected because it breaks the `ai-tools`→root sudo). A wrapper
cannot observe its successor's post-`exec` domain, so `ai-tools-run` probes the
transition's inputs *before* launch and logs them on every launch (journald, `ai-tools-run`
tag): the entrypoint's label (`matchpathcon` vs `stat -c %C`), the `systemd --user` manager's
domain (`/proc/<pid>/attr/current`), and whether the core module's **file-contexts are live**.

That last one is probed with `matchpathcon` on a core-owned path (`/opt/ai-tools/.config`
resolves to `ai_tools_home_t` only when the module is loaded) rather than read from the module
store with `semodule -l`, and the reason is the account: `ai-tools-run` runs as the sandbox
account, which cannot read the root-only store, so that read returns a systematic false "no" —
which on the unresolved-label branch would fail *open*, launching DAC-only where the module is
loaded. The `matchpathcon` probe does not need any privilege — it reads the
world-readable file-contexts — and the agent cannot influence it, file-contexts and the shim both
being root-owned.

`ai-tools-run` performs that probing and I/O; the launch-vs-refuse decision is the pure
`ai_tools_confinement_verdict` (`confinement.lib.sh`), which carries the six inputs and the
verdict token for each combination as its contract, and is unit-tested apart from the probing
(`tests/unit/confinement.sh` drives the truth table with no SELinux host).

The policy that table implements is **fail-closed once confinement is expected**. Where SELinux
is enforcing and `matchpathcon` resolves the entrypoint to `ai_tools_exec_t`, a live label that
is anything else refuses (`mislabel`, → `relabel`), as does a manager domain no
`domtrans_pattern` in `ai_tools.te` covers (`manager-domain`, → add the rule and `rebuild`; this
one is advisory, and an unreadable domain does not block). Where the label does **not** resolve,
the verdict splits on module presence: **present** means confinement is installed yet the
transition is unverifiable, so it refuses (`unverifiable`, →
`ai-tools-admin system entrypoints relabel` or `install-selinux.sh install`) rather than launch
DAC-only and silently drop confinement; **absent** means the SELinux layer was never installed
here, so it launches — an intentional DAC-only deployment, cleared for a staged host with
`semodule -r ai_tools` or permissive mode. The check is a no-op where SELinux is not enforcing,
so DAC-only and permissive boxes are unaffected.

One residual the `matchpathcon` probe cannot see: a module **staged in the store but with its
file-contexts never loaded** into the running policy reads as "absent" (the core-owned path resolves
to its default type), so that narrow half-installed state launches DAC-only rather than refusing.
Detecting it requires reading the store, which the sandbox account cannot do — no unprivileged probe
can — and a normal `semodule -i` loads store and policy together, so it is reached only by a
half-completed install. `AI_TOOLS_REQUIRE_SELINUX` closes it outright, below.

#### The toolchain is read-only to the confined domain <a id="ref-section-w4z6"></a>

The preflight checks that the entrypoint carries `ai_tools_exec_t`; the type layout is what stops
the confined agent changing it afterwards. `ai_tools.fc` deliberately leaves the whole nvm tree at
its default `usr_t`/`bin_t`/`lib_t`, and `ai_tools.te` grants `manage_*_pattern` only for the
types it declares for the agent's own trees — `ai_tools_project_t`, `ai_tools_project_build_t`
(the build output inside a project, see [dotnet](dotnet.rule.md)), `ai_tools_home_t`,
`ai_tools_tmp_t`. None of them appears in the exec
chain: the versioned launcher symlink is `bin_t`, the agent's package directory `lib_t`, and the
entrypoint `ai_tools_exec_t`, on which `ai_tools_t` holds `execute_no_trans` plus what
`application_domain` gives (entrypoint/read/getattr), and no other permission.

So on an enforcing host with the module loaded, `ai_tools_t` can neither write the entrypoint, nor
unlink or rename over it (no `add_name`/`remove_name` on a `lib_t` directory), nor repoint the
`bin_t` symlink — even though DAC alone would allow all three, since the account owns that tree.
This is the layer that makes the exec root read-only to the agent, and it is why the
launch-time entrypoint re-check in [launch](launch.rule.md) is a **DAC-only** concern. The residual
is the unconfined `--user` manager: anything the agent persuades that manager to run executes
outside `ai_tools_t`, which is why `~/.config/systemd/user` must stay root-owned.

#### `AI_TOOLS_REQUIRE_SELINUX` — operator-declared fail-closed

The unprivileged wrapper cannot tell an *intentional* DAC-only host from a *degraded* one —
permissive drift, module removed or staged-not-active, mislabelled entrypoint — so by default it
launches on that state rather than break the DAC-only hosts the project supports. The gap that
leaves is a false sense of security: an operator who believes confinement is enforcing can have
sessions silently run `unconfined_t`. DAC, the seccomp `RestrictNamespaces` filter,
`NoNewPrivileges` and the env allowlist all still hold, so what is lost is the `ai_tools_t` type
layer — a defence-in-depth layer, not a DAC bypass.

`AI_TOOLS_REQUIRE_SELINUX=yes` in `operator.conf` lets the operator **declare** the requirement.
`ai-tools-run` passes it as the verdict's sixth `require` input, which turns the two DAC-only
*launch* exits into refusals: `require-not-enforcing` (SELinux not `Enforcing`) and
`require-inactive` (enforcing but the module's file-contexts are not live). Having the operator
assert intent rather than the wrapper guess it closes the whole "thinks-enforcing" family, the
staged-but-not-active residual above included, and adds **no** store-read surface.

It is opt-in: the default (key absent, or any value outside the true set `yes|true|1|on`) is `no`,
so intentional DAC-only hosts are untouched. `require` tightens those two exits alone — the
`mislabel`/`manager-domain`/`unverifiable` refusals already fail closed and are unchanged, and the
`manager-domain` advisory stays advisory under `require`, since it targets the `/proc` read rather
than a DAC-only launch. The switch is read only while `ai_tools_conf_is_trusted` holds for
`operator.conf` (root-owned, non-group/other-writable, not a symlink), so the agent can neither set
nor clear it.

`require` is the one input whose read failure resolves toward *more* access: an untrusted or
absent file yields `no`, which is the default posture, so the two refusals it would otherwise
produce — `require-not-enforcing` and `require-inactive` — stay DAC-only launches instead. The
package installs `operator.conf` as `0644 root:root` and `tests/integration/perms.sh` asserts that
ownership and mode, so a file failing `ai_tools_conf_is_trusted` is a misconfigured host rather
than a state this model covers. The agent cannot produce it: the file and the directory holding it
are root-owned. The posture rides in the per-launch audit line (`require=yes|no`).

## `/tmp` model

`PrivateTmp` is not used; the session shares the host `/tmp`. systemd `PrivateTmp` is a
no-op for an unprivileged `--user` manager: it cannot pivot a private `/tmp` for the
payload (the unit starts, but the payload still sees the shared `/tmp` — claude's
runtime dir stays visible and no private bind mount appears in the payload's
`mountinfo`). claude keeps its runtime at a fixed `/tmp/claude-<uid>`, does not honour
`TMPDIR`, and reuses the dir across sessions. `ai-tools-run` does not touch that
directory: removing it would race claude's exists-then-`mkdir` check against another
live same-uid session, failing startup with `EEXIST mkdir /tmp/claude-<uid>`.

The enforced `/tmp` isolation is ordinary Unix permissions plus the `ai_tools_tmp_t`
type: a dir claude creates is born `ai_tools_tmp_t` via the `tmp_t:dir` →
`ai_tools_tmp_t` type_transition, which `ai_tools_t` fully manages but which keeps it
off other domains' `tmp_t`/`user_tmp_t` files. Per-session `/tmp` isolation would
require a privileged (`--system`) manager that mounts and pivots `PrivateTmp` for the
payload during unit setup.

Node's V8 compile cache is the one piece of session scratch kept OUT of `/tmp` —
pinned to `ai_tools_home_t` via `NODE_COMPILE_CACHE` (see [launch](launch.rule.md)) — because
its default `/tmp/node-compile-cache` otherwise collides with `user_tmp_t` leftovers and
other uids, and an entry carrying `user_tmp_t` denies node's own `open()` under
enforcing, killing the session at startup.

### Optional `pam_namespace` polyinstantiation (host dependency)

Some hardened hosts additionally run `pam_namespace` polyinstantiation of `/tmp` and
`/var/tmp` (`/etc/security/namespace.conf`, e.g. `method=level`) — an optional,
non-default measure. The sandbox neither requires nor configures it, does not assume it
is present, and works correctly with or without it. When present, each SELinux level
gets its own `/tmp` instance bind-mounted into the session's mount namespace, adding
per-level isolation. Operational notes for that case:

- The instance is slave-propagated and invisible from the host init namespace; root
  reaches it only via `/proc/<pid>/root/tmp` of a live session (the
  `/tmp/tmp-inst/<context>_<user>` path does not resolve outside the namespace).
- It is keyed by level, not session, so same-level sessions still share one `/tmp` and
  serialise on `/tmp/claude-<uid>`.
- It lives in tmpfs and is cleared on reboot.
- A stale `user_tmp_t` dir left in the instance by an earlier unconfined run blocks
  startup under enforcing (`ai_tools_t` has no `user_tmp_t:dir` access → `EEXIST`); clear
  it via `/proc/<pid>/root/tmp` or a reboot.

## Optional SELinux groups and the namespace filter

The optional groups (`systemd`/`pkgmgmt`/`netadmin`/`podman`/`tmpmap`/`apphost`/`localipc`/`buildexec`) are all off by
default and each carries a **stability** field in the registry (`experimental`/`stable`)
that decides how it is shipped and enabled. Both front doors draw the group set, descriptions,
and stability from one place — `selinux-groups.lib.sh`, so they cannot disagree. The same registry
records a renamed group's **former module name**, and every path that loads policy — either front
door, and the selinux subpackage's `%post` where the current module is on the shipped set — replaces a
loaded former module with the group's current one in a single `semodule` transaction, so a host
that enabled a group under its old name keeps the workload running across the rename and does not
hold both rule sets:

- **Stable** groups (`tmpmap`, `localipc`, `buildexec`: a rule set exercised against its workload
  on an enforcing host) are on the **shipped set**: compiled as `ai_tools_<group>.pp` beside the
  core in `/usr/share/selinux/packages/ai-tools/` (how, and by what, is in *How the policy ships*
  below), where `sudo ai-tools-admin selinux groups enable <name>` `semodule`-loads one on an
  installed host without a source tree or `selinux-policy-devel`, then restores the labels the
  group's own file contexts decide (the sandbox-clone area). A bare `selinux groups` lists
  them and `selinux groups disable <name>` rounds it out, working for any loaded group. The
  spelling these commands take is set by [cli-grammar](cli-grammar.rule.md).
- **Experimental** groups are unaudited drafts and are **off the shipped set**;
  `ai-tools-admin selinux groups enable` refuses one and points at the source workflow rather than
  loading an unaudited module. They are compiled and verified from a source checkout —
  `sudo selinux/install-selinux.sh enable-group <name>` (which compiles from `.te`/`.fc`, then
  loads, then re-runs the project and clone label sweeps, since a group may ship file contexts of
  its own; `disable-group` sweeps the same way after the unload) plus the `avc/` bring-up loop.
  Promoting one to stable means marking it `stable` in the registry: the shipped set is derived
  from that field, so no packaging file names the group.

A group is named for the capability it grants, never for a toolchain, so an administrator reads
each as the class of access it is. What a toolchain needs is its integration manifest's to say
(`selinux_groups`, read by the status reports to name the groups not loaded) — and where a
toolchain's output layout must be typed at creation, its manifest names a **layout module**
(`selinux_layout_module`, `ai_tools_dotnet` for .NET), a policy module that carries file
transitions and file contexts and does not add any permission. A layout module is not a group and not a consent
point: it loads with its integration (the integration's `bootstrap`, the policy package's `%post`
for every installed integration declaring one, and `install-selinux.sh install`/`rebuild` from
source), is unloaded by the integration's erase, and is on the shipped set like a stable group,
derived from the manifest that declares it. The keys are in `ai-tools-providers(5)`; the one
layout module and the groups it serves are in [dotnet](dotnet.rule.md).

Enabling an optional policy group widens what SELinux permits but does not lift the seccomp
filter. Of the optional groups only
`podman` creates namespaces (rootless containers need user+mnt+pid+ipc+net+uts), so
`RestrictNamespaces=yes` blocks it even with the podman group loaded — the SELinux grant
is necessary but not sufficient. Supporting rootless podman means re-allowing the user
namespace, which *is* ESC-001, so it is not a clean partial relaxation. `ai-tools-run`
emits an actionable NOTICE at launch when the podman group is loaded while the filter is
active.

After editing policy source, rebuild and reload the loaded module with
`sudo selinux/install-selinux.sh rebuild`.

## Bring-up and enforce-verification (`selinux/avc/`)

The rule set is arrived at by observation: load permissive (`permissive ai_tools_t;` in
`ai_tools.te`), exercise the surface, fold the logged denials in, then remove that line.
Two harnesses drive it, each **split into an agent half and a root half**, because the
agent exercises the surface but cannot read `/var/log/audit`, and root reads the log but
does not run in `ai_tools_t`.

`avc-testsuite.sh` (agent) exercises what the agent needs and writes a start marker;
`avc-analyze.sh` (root) reads that marker so `ausearch -ts` starts at the right instant,
and sorts each denial into **NEW**, **EXPECTED BOUNDARY** (an access `ai_tools.te`
`dontaudit`s) or **EXPECTED GROUP-DISABLED** (one only an optional group would allow).
Only NEW is a candidate to fold in.

`avc-denials.sh` proves the inverse — that what the agent must not do is refused. Its root
half brackets the probe with `semodule -DB` … `semodule -B`, since a `dontaudit` suppresses
the audit record and an empty `ausearch` result would otherwise be indistinguishable from a
probe that never ran; a trap restores dontaudit on any exit, Ctrl-C included.

Both agent halves **abort unless the calling process is in `ai_tools_t`**: run unconfined
they log no `ai_tools_t` denial at all, and that empty result reads as success. The
procedure for running either is in `selinux/README.md` §2 and §4.

## References

- [SELinux Notebook — AV rules](https://github.com/SELinuxProject/selinux-notebook/blob/main/src/avc_rules.md)
  — `allow`, `dontaudit`, `auditallow`, `neverallow`. `dontaudit` "stops the auditing of
  denial messages"; it is the absent `allow` that denies.
- [SELinux Notebook — reference policy](https://github.com/SELinuxProject/selinux-notebook/blob/main/src/reference_policy.md)
  — the `.te`/`.if`/`.fc` source layout and building a module against installed policy headers.
- [Smalley, "Generalize support for NNP/nosuid SELinux domain transitions"](https://patchwork.kernel.org/project/selinux/patch/20170714164647.6183-1-sds@tycho.nsa.gov/)
  — the patch adding the `process2` class and its `nnp_transition`/`nosuid_transition`
  permissions, gated on the `nnp_nosuid_transition` policy capability, and the rationale:
  packagers were turning systemd hardening options off to preserve SELinux transitions,
  because `typebounds` for every service domain is impractical. The branch is
  `check_nnp_nosuid()` in `security/selinux/hooks.c`.
- [Moore, "Linux v4.14 Released"](https://www.paul-moore.com/blog/d/2017/11/linux_v414.html)
  — the kernel release the capability landed in.
- [Red Hat bug 1480518](https://bugzilla.redhat.com/show_bug.cgi?id=1480518)
  — the distro-side record: units carrying `NoNewPrivileges` lost their domain transitions,
  which is the breakage the capability was added to repair.
- [refpolicy list, "Re: nnp_transition"](https://www.spinics.net/lists/selinux-refpolicy/msg00215.html)
  — reference policy defines no `typebounds`, so the fallback path is unavailable to a
  refpolicy-derived base policy: enabling the capability is what makes NNP transitions work.
- [Walsh, "Teaching an old dog new tricks"](https://danwalsh.livejournal.com/78312.html)
  — `nnp_transition` in practice: the transition is allowed under NNP with no `typebounds`
  rule in place.
- [`systemd.exec(5)`](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html)
  — `RestrictNamespaces=` limits `unshare(2)`, `clone(2)` and `setns(2)`; `NoNewPrivileges=`
  and `PR_SET_NO_NEW_PRIVS`.
- [RHEL 9, *Using SELinux*](https://docs.redhat.com/en-us/documentation/red_hat_enterprise_linux/9/html/using_selinux/)
  — `semanage fcontext` writes the persistent rule, `restorecon` applies it; `-F` resets a
  customizable type a plain run preserves.

## How the policy ships

The policy is its own subpackage, `ai-tools-selinux`, and `ai-tools-base` **recommends** it. Three
independent properties meet at that boundary:

- **Build.** The shipped set — the core, each `stable` group, each layout module — is compiled in
  the spec's `%build` from the `.te`/`.if`/`.fc` in the source tarball, against the policy headers
  of the distribution the RPM is built on (`BuildRequires: selinux-policy-devel`), and the
  `%{?dist}` tag on the Release keeps each build on its own distribution. `selinux/policy/shipped-modules.sh`
  derives the set from the registry's `stability` field and the `selinux_layout_module` key of each
  integration manifest under `src/`; `%build`, `%install`, and `%files` (through a file list
  `%install` writes) read that one derivation, so promoting a group or adding a layout module edits
  the registry or a manifest and no packaging file. No compiled module is tracked: `.gitignore`
  covers `*.pp`, `make dist` refuses a tarball carrying one, and `tests/unit/selinux-groups.sh`
  fails on a tracked one, since a tracked binary was built on some other host's headers and no
  review can read it. A source install compiles the same set from the checkout —
  `install-selinux.sh build`, which `install.sh` runs — and stages it in the package directory
  above; where SELinux is active and `selinux-policy-devel` is absent, `install.sh` refuses the
  SELinux step and names the package, so the absent modules are reported at install rather than
  met later as a launch the preflight refuses. The container self-tests compile in each image and
  assert the packaged set against the derivation (`rpm -qlp`), so an interface that does not
  resolve on a distribution fails that distribution's build; they do not load a module
  (`getenforce` is `Disabled` in a container), so a rule that fails to load is caught on an
  enforcing host only.
- **Licence.** A compiled `.pp` embeds macro expansions from the SELinux reference policy, so it is
  `GPL-2.0-or-later` while the rest of the stack is `AGPL-3.0-only`. Everything under
  `selinux/policy/` carries that identifier: the `.te`/`.if`/`.fc` sources (they call refpolicy
  interfaces that expand on compile) and the scripts controlling their compilation — the `Makefile`
  and `shipped-modules.sh` — which GPLv2 s.3 counts as part of the corresponding source. The
  surrounding tooling — `install-selinux.sh`, `selinux/avc/*.sh`, `selinux-groups.lib.sh` — is
  `AGPL-3.0-only`, holding no refpolicy content and loading or reading a module rather than
  compiling it. The subpackage conveys the GPL text via `%license`, and the source tarball
  carries `selinux/policy/` whole, which is the corresponding source of every `.pp` the RPM built
  from it conveys; `make dist` refuses a tarball without the policy sources.
- **Degradation.** The weak dependency is what `ai_tools_confinement_verdict` already expects: a
  host without the subpackage has no module in the store, which is the intentional DAC-only
  deployment that launches, not the half-installed state that refuses. Dropping the policy costs
  confinement alone.

The load and unload scriptlets live in the subpackage, with the payload, so no cross-subpackage
ordering question arises. `%post` runs `semodule -i` — into the running kernel policy, not only the
module store, since the entrypoint cannot be labelled until the module's types exist in the kernel —
at the default module priority, the same slot `install-selinux.sh` and `ai-tools-admin` address, so a
host holds one copy of each module. A load that fails is **reported with `semodule`'s own message**
and the command that repeats it, rather than swallowed: every type the entrypoint and project labels
name comes from this module, so a load that did not happen surfaces later as a relabel that cannot
register its rules and a launch that fail-closes, with no message naming this as the cause. The
transaction still completes — the remedy is a re-run, not a rollback. After the module load, `%post` also `restorecon`s the trees
that carry `ai_tools*` types (the handback daemon among them) and, when the handback socket is
already active — an upgrade — refreshes the live listener: `restorecon` fixes the daemon binary's
on-disk label, but the socket bound on tmpfs `/run/ai-tools` keeps its stale context and its
per-connection handler keeps running `unconfined_service_t`, so `daemon-reexec` + a socket restart
re-derive the listener context from the now-correct binary label (the same sequence
`install-selinux.sh` `_relabel_runtime` runs; see [handback-bridge](handback-bridge.rule.md)).
Without it a session's `connectto` to the handback socket is denied under enforcing and every hook
handback silently no-ops. On a fresh install the socket is not up yet — `ai-tools-base` `%posttrans`
starts it later, already correctly labelled — so the refresh no-ops there. `%postun` on final erase unloads every loaded `ai_tools*` module,
enumerated rather than named: a group's `.pp` is erased with the package while the compiled module
persists in the store, and a group compiled from a source checkout was never in the rpm database at
all.

The `%selinux_*` rpm macros are not used. `%selinux_requires` records the build host's
`selinux-policy` version as a `Requires`, which a `noarch` package cannot satisfy across both EL
targets; `%selinux_modules_install`/`_uninstall` operate at priority 200, splitting the module slot
against the two source-tree tools, and the uninstall half removes only the modules it names, which
would strand any group enabled on the host.
