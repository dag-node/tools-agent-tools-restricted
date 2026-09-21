---
paths:
  - "src/usr/local/libexec/ai-tools/ai-tools-stop.sh"
---

# Stopping running sessions (`ai-tools-stop`)

`ai-tools-stop` (`/usr/local/libexec/ai-tools/ai-tools-stop`, `750 root:root`) terminates every agent session
on the host and everything each one spawned. It is the stop rung of the incident ladder
([governance](governance.rule.md)): the one control that acts on a session **already running**, where every other
operator control — unclaiming a project, disabling a provider, revoking an operator, relabelling an entrypoint — changes
what the *next* launch gets. `ai-tools stop`, the verb that reaches it, its option grammar, and its place
among the verbs root may run are in [cli](cli.rule.md); what an operator runs and reads is
[docs/sessions/stop.md](../../docs/sessions/stop.md); the helper's own header states its exit contract
and which externals sit on the kill path.

The property this component holds is one sentence: **a stop that is asked for and reported as done has happened.**
A session is an interactive process with tool access, running as a shared service account, able to spawn arbitrary
children, and — in the case this control exists for — one that may be doing something an operator wants ended now
and may not cooperate. The design is therefore judged by one question: can the monitored system decline, evade,
or disarm it? Every decision in this rule follows from that.

## The invariants it rests on

| # | Invariant | Where it comes from | What would break it |
|---|---|---|---|
| I1 | A process stays in the cgroup it is in until something writes its pid to a `cgroup.procs`, and a child inherits it across `fork()`. Membership survives `setsid(2)` and the double fork that re-parents to PID 1. | `cgroups(7)` | a kernel that lets a task rewrite its own membership |
| I2 | Every process of the sandbox account lives under that account's per-user slice, `user-<uid>.slice`. | `systemd-logind(8)` places user processes there; the account has no login shell, so no other path creates one | a process escaping to another slice — needs the user manager, which SELinux denies and DAC-only leaves as a residual |
| I3 | `SIGKILL` is neither catchable nor blockable, and `cgroup.kill` (Linux ≥ 5.14) delivers it to a whole cgroup **atomically** — one write freezes the cgroup and kills every member including descendants. | `signal(7)`; `cgroups(7)` | no userspace mechanism |
| I4 | The kernel answers "is anything alive here" itself: `cgroup.events`' `populated` field is 1 while the cgroup **or any descendant** holds a live process. | cgroup v2 interface files | a threaded subtree, where `cgroup.procs` reads fail — handled by reading `cgroup.threads` beside it |
| I5 | Only root may signal across accounts and write `cgroup.kill`. The sandbox account does not hold a `sudo` rule, and the session runs under `PR_SET_NO_NEW_PRIVS`, which drops `sudo`'s SUID bit outright. | the sudoers drop-in; `ai-tools-run`'s unit properties | an operator adding a rule for the sandbox account |
| I6 | The set of sessions terminated is decided by cgroup-slice membership alone — no input the account can write reaches that decision, because the command accepts neither a target nor an authorization argument. | this command's own grammar | adding a per-project form scoped by anything the account reports |
| I7 | `/proc` and `/sys` reads plus bash builtins need no external binary. The kill path calls `sleep` alone. | the helper's own construction | — |

Two of these carry the whole design. **I1 is why discovery is by cgroup**: a process group is broken by `setsid(2)`
and a ppid walk is broken by the double fork, so neither can enumerate what a session spawned. **I3 is why the kill is
by cgroup too**: signalling a list of pids races the fork that happens between reading the list and signalling it,
and `cgroup.kill` has no such window.

## Who may stop what <a id="ref-section-r5r9"></a>

Any `ai-ops` operator may run it, and so may root, and it terminates every agent session on the host, including other
operators'. `--all` never took an authorization input, so the command does not widen what an operator could already do,
and there is no politer form beside it, because a politer form was not a control. On a shared host one operator's stop
ends every operator's sessions, and the trail records who asked.

**It runs without a password, and that is the requirement the grant answers.** The `%ai-ops` drop-in carries a NOPASSWD
rule for the helper's bare form ([launch](launch.rule.md) holds the drop-in):

```
%ai-ops ALL=(root) NOPASSWD: /usr/local/libexec/ai-tools/ai-tools-stop ""
```

The deciding argument is automation. A service that detects a session doing something that must end now cannot answer
an interactive password prompt, so a stop gated behind one is reachable only by a human at a terminal, which makes
the ladder's last rung unavailable during exactly the incidents it exists for. The bare command is the whole
of what a detector needs, because the confirmation defaults yes and proceeds with no terminal. The trailing `""` pins
the rule to that zero-argument form, so every option — `--force` (which drops the grace period and the current turn's
unsaved work with it), `--dry-run` (a detector does not preview), `-y`, and the inert `--all` — falls outside it
and meets sudo's ordinary prompt behind a general sudo grant; `cmd_stop` passes each one through to the helper. Since
the helper does not take a target or an authorization input, the rule has no argument surface at all: the narrowest
shape a NOPASSWD rule can have.

Root reaches the same command directly: `ai-tools stop` is one of the verbs that leave operator-owned state untouched,
so the CLI admits root, and the helper requires root regardless. That matters because root is the identity a monitoring
daemon usually runs as.

What this widens, stated plainly: any `ai-ops` member ends every operator's sessions without authenticating. That is
availability-only, it was already true of anyone holding a general grant, and it moves in the **corrigible** direction:
every other control in this project resolves failure toward *less access*, and this one resolves toward *less activity*,
so making it easier to reach is asymmetrically safe.

A per-project form would have to decide which sessions belong to a project, and every available answer is written
by the account being stopped — the unit's `WorkingDirectory`, its name, its launch line. Scoping a stop by any of them
lets a session influence what a stop reaches, which is exactly inverted. The alternative that would work is
a session-to-project mapping recorded by **root** at launch (through the handback socket, whose peer uid the kernel
supplies), and that is real machinery: a verb, a registry, and its lifecycle. It is not built, because the routine way
to end a session is `/exit`, and the incident that reaches for this rung wants everything stopped. A path is refused
with exit 2 rather than accepted and ignored (`refuse_positional_argument`), so a targeted form, if built, moves
`stop <path>` from *error* to *accepted* without changing what any existing command line means.

## Where containment ends

systemd **delegates** the per-user subtree to the account — that is what lets its user manager create units at all —
and delegation permits the delegatee to move its own tasks between cgroups *inside* that subtree. Containment holds
at the delegation boundary, not within it.

On a host with the SELinux module loaded this is closed outright: the policy does not grant `ai_tools_t` any permission
on `cgroup_t` beyond a `dontaudit … getattr`, so a session can neither write a `cgroup.procs` nor create a cgroup,
and it has no `connectto` on the user runtime socket, so it cannot reach its own user manager to ask for a unit either.
**On a DAC-only host a session reaches both the delegated cgroup files and its own bus socket**, since the account owns
them.

This is why the sweep **covers every cgroup**, the account's own `systemd --user` and its `init.scope` included.
An exemption is a destination: any cgroup left out is one a session on a DAC-only host can move into, whether it is
named or identified by exact path. Covering every cgroup means there is nowhere to move to, and a unit the session asks
its manager to create is still inside the slice being swept. It also means no unit name appears in the helper at all,
so there is no name here to differ between EL9, EL10 and Fedora.

The cost is that the user manager is terminated too, and `SIGKILL` leaves `user@<uid>.service` **failed** rather than
restarting it. That is paid back rather than exempted: `restore_user_manager` runs after the kill *and*
after the verification, restarts the unit, and reports the outcome on its own, so a manager that did not come back never
changes what the command says about the stop. If it fails, the message names the fix, and the next launch needs it
before a session can start. A rerun is therefore not silent: the restored manager is back inside the swept slice,
so a second run terminates and restarts it again. The command is idempotent in end state — no sessions, manager up —
and not in what it reports, since a silent rerun would cost either an exemption or a name-decided sweep.

A final sweep re-enumerates after the run and reports a cgroup that became live after being verified empty
(`AI_TOOLS_RESULT=reappeared`), which is what a mid-run launch looks like from here. Re-running is the remedy.

Attribution is best-effort and display-only: a `WorkingDirectory` is read from the account's own user manager,
so a rogue unit can misreport it, and all that buys is a wrong label in the table and a missing `projects handback`
line. It cannot affect what is terminated, because the sweep does not consult it. The split between agent sessions
and the account's own plumbing (its user manager, dbus, login session scopes) is advisory in the same sense: the class
comes from a unit name, which inside a delegated subtree is the delegatee's to choose, so a session can name itself
out of the agent class and does not gain an exemption by it. The split orders the table, separates the two counts,
and decides which rows carry a `projects handback` line; both classes are enumerated, listed and killed identically.
Only an agent session gets a `projects handback` line: the account's dbus broker reports `/opt/ai-tools` as its working
directory, the control plane, which the protected-paths backstop refuses.

## Residual failure modes

Stated so the guarantee is bounded rather than overstated.

- **Uninterruptible sleep.** A `D`-state task cannot be reaped until its syscall returns; the run reports it
  as surviving (exit 1). It stays off the CPU meanwhile.
- **The helper itself is `SIGKILL`ed mid-run.** An `EXIT` trap narrows the *audit* gap (it covers every signal bash can
  handle) but no mechanism narrows the *state* gap. The remedy is that the command is idempotent: run it again.
  A watchdog would be a second privileged daemon for a case a rerun already answers.
- **The launch/stop window.** A session launched after the final sweep is outside the command's window. Closing it needs
  a gate shared with the launcher, which does not exist; for the incident case the operator holds the launch path
  anyway, and for an adversarial session the answer is a revoked launch grant beside the stop, not a stronger promise
  here.
- **Blast radius.** Everything in the account's slice is in scope, including an in-flight toolchain update
  and the account's own user manager. The updater is fail-closed on interruption and leaves the previous, trusted
  version active ([updater](updater.rule.md)); the manager is restarted afterwards.
- **The manager does not come back.** The restart is best-effort and reported separately. Until it succeeds no *new*
  session starts, since `ai-tools-run` launches each one as a transient unit of that manager, which is nearer
  to the point of this command than against it; the message names the command that fixes it.
- **Kernel below 5.14 or a cgroup-v1-only host.** Without `cgroup.kill` the fallback re-collects and re-signals
  in a loop, narrowing the fork window without closing it. With no cgroup v2 hierarchy at all the helper **refuses**
  (exit 5) and names the manual command, rather than reporting that no session is running. Both supported EL targets are
  unified and ≥ 5.14.
- **Both log sinks unavailable.** The stop still succeeds or correctly fails; the record is lost. The two sinks fail
  independently.

## What the monitored system can do about it

The helper is `750 root:root` in a `750 root:root` directory, so the sandbox account cannot read, write or execute it,
and the account does not hold a `sudo` rule to reach root by, asserted from the agent's own vantage
in `tests/boundary/access.sh`. The command does not take an authorization input for it to aim at. The kill is delivered
by root to a cgroup, and no process inside the cgroup takes part in it.

**No name buys anything, because no name is spared.** One cgroup is matched by name at all — the manager unit,
`user@<uid>.service`, by exact path — and it is not an exemption: it is descended into rather than emitted, so its
contents (`init.scope` among them) are listed and killed individually instead of the whole manager subtree being
swallowed as one opaque row. A nested cgroup that names itself `init.scope`, or `user@0.service`, is enumerated like any
other, because every name inside a delegated subtree is the delegatee's to choose. Dot-named cgroups are enumerated
for the same reason.

## Implementation

The functions are named for the question they answer, so the kill path reads as prose:

```
find_session_cgroups → has_own_tasks → cgroup_pids → cgroup_is_live
confirm_stop → end_session → terminate_gracefully → kill_outright → restore_user_manager
```

### The five phases

```
  ┌ 1. parse ──────────────────────────────────────────────────────────────────┐
  │  no target, no authorization input: nothing to decide, nothing to trust    │
  │  --all accepted and inert; a PATH is refused (exit 2), never ignored       │
  └────────────────────────────────────────────────────────────────────────────┘
  ┌ 2. enumerate ──────────────────────────────────────────────────────────────┐
  │  walk  /sys/fs/cgroup/user.slice/user-<uid>.slice                          │
  │        descend slices → stop at the first .service/.scope = ONE SESSION    │
  │        the manager service is descended into, never emitted                │
  │        NOTHING is exempt -- init.scope is enumerated like anything else    │
  │  attribute each unit via WorkingDirectory  (best-effort, DISPLAY ONLY:     │
  │        it selects nothing, so `unknown` costs a label, not a target)       │
  │  classify agent session vs account plumbing  (advisory, DISPLAY ONLY:      │
  │        splits the counts and orders the table; selects nothing)            │
  └────────────────────────────────────────────────────────────────────────────┘
  ┌ 3. confirm ────────────────────────────────────────────────────────────────┐
  │  the table, then a question that DEFAULTS TO YES; consent path recorded    │
  └────────────────────────────────────────────────────────────────────────────┘
  ┌ 4. end each session ───────────────────────────────────────────────────────┐
  │  SIGTERM pass, deepest-first, re-collected each second, up to 10s          │
  │        → empty?  outcome = terminated                                      │
  │  SIGKILL pass:  write cgroup.kill (atomic, re-asserted per pass)           │
  │                 + validated per-pid kill as the pre-5.14 fallback          │
  │        → empty?  outcome = killed        else  outcome = alive             │
  └────────────────────────────────────────────────────────────────────────────┘
  ┌ 5. sweep, restore, report ─────────────────────────────────────────────────┐
  │  re-enumerate the whole slice; any live cgroup → did not complete (exit 1) │
  │  live but not one the loop reported  → reappeared: a session started       │
  │                                        mid-run; re-running is the remedy   │
  │  restart user@<uid>.service -- AFTER verification, reported separately,    │
  │        never folded into the stop's exit status                            │
  │  name the projects handback per project terminated                         │
  └────────────────────────────────────────────────────────────────────────────┘
```

### The decisions inside those phases

- **A systemd *unit* is the unit of work.** The walk descends `.slice` directories and stops at the first
  `.service`/`.scope`, emitting it whole: its nested cgroups are part of it, so descending further would list the same
  processes twice and offer a parent slice as a stoppable thing, which would take every sibling unit with it. No task is
  lost by stopping there, because the only place a task can hide from a unit walk is a slice, and a slice holding tasks
  *directly* is emitted in its own right.
- **Deepest-first signalling.** Children are reached before their parents, so a parent is never left waiting on a child
  it can still see.
- **Re-collect between passes.** A set read once and signalled twice misses whatever was forked in between. Each pass
  re-reads the cgroup.
- **Validate a pid's start time immediately before signalling it** (`/proc/<pid>/stat` field 22), so a pid recycled
  between collection and kill is skipped rather than signalled blind. This is the pre-5.14 path; `cgroup.kill` does not
  signal any pid.
- **Every liveness read fails closed.** Only one failure means "empty": the file not existing, which is what a completed
  kill looks like, since the cgroup was removed. A permission-unreadable `cgroup.procs` reports LIVE. A threaded cgroup
  — whose `cgroup.procs` read fails while live threads sit in it — is read against `cgroup.threads` (I4), because bash
  cannot tell a failed `read(2)` from a clean EOF.
- **Verification never runs through an external command.** A liveness predicate piped through `head` answers "no tasks"
  when `head` is absent, and reports a stop as complete while the session runs. Every other external in the file fails
  toward doing *less*; that one would fail toward *claiming more*, on the one check the guarantee rests on.
- **The two attribution calls into the sandbox account's user manager run under `timeout`**, since a stop that hangs is
  a stop that did not happen; a value the helper cannot interpret degrades to `unknown` ([logging](logging.rule.md)
  states the reduction it applies before printing one).

### Degradation policy: two inversions, one reason <a id="ref-section-e8k5"></a>

For every other component here the safe direction is **don't act**. For this one it is **act**, so two project-wide
conventions are inverted, each for that reason alone:

1. **No required dependencies, and no `set -e`.** A missing library that aborted the run, or an unexpected non-zero
   that abandoned a half-finished kill, would be a stop that did not happen. The rule is about *abandonment*, and not
   about one shell option: `set -u` **is** used, and it ends the shell just as abruptly wherever a name or an argument
   is read unset, so a value a caller may legitimately not have passed is defaulted where it is read (`confirm_stop`)
   rather than left to abort a run mid-way. What is guaranteed is independence from *this project's* libraries: **no
   project library is load-bearing here at all.** The command does not take any input that decides which sessions
   to stop, so there is no input left for a library to gate. `log.lib.sh` and `msg.lib.sh` load best-effort for output
   quality, behind inline fallbacks that keep the sanitizer and the code-rendering the loaded library would supply
   ([logging](logging.rule.md), [messaging](messaging.rule.md)); `safe-paths.lib.sh` and `operator.lib.sh` are not
   loaded, since each exists to vet or authorize a caller-supplied target ([safe-paths](safe-paths.rule.md)). It is not
   independence from the base system: which externals a run touches, and which of them are on the kill path (I7), is
   stated in the helper's header, beside the code.
2. **The confirmation defaults to yes.** The principle in [messaging](messaging.rule.md) is unchanged — *the default is
   the safe outcome* — and which outcome is safe is what flips: for the one control whose job is to end a session
   already running, declining is the failure. A bare Enter, a pipe, a cron run and an absent `msg.lib.sh` all proceed;
   only a deliberate `n` declines, and `--dry-run` is how the command is looked at without acting. The no-terminal path
   is a legitimate path here, so the helper records **which** path gave consent (`flag`, `prompt`, `fallback-prompt`,
   `no-tty`) beside the answer.

## Design notes

Each of these looks like a defect to a fresh reader, and each is deliberate: a change reverting one of them retires
the guarantee its row names.

| Decision | Why |
|---|---|
| The confirmation defaults **yes** | for the one control whose job is to act, declining is the failure ([Degradation policy](#degradation-policy-two-inversions-one-reason)) |
| No `set -e`, no required library, and every value defaulted where `set -u` would abort | an aborted run is a stop that did not happen, including one aborted by an argument a caller did not pass ([Degradation policy](#degradation-policy-two-inversions-one-reason)) |
| There is **no per-project form**, and a path is an error | every way to attribute a session to a project is written by the account being stopped ([Who may stop what](#who-may-stop-what)) |
| A path errors rather than being ignored | it keeps targeted stopping addable later without changing what an existing command means ([Who may stop what](#who-may-stop-what)) |
| **No cgroup is exempt**, `init.scope` included | an exemption is a cgroup a session can move into on a DAC-only host ([Where containment ends](#where-containment-ends)) |
| The user manager is restarted, not spared | the exemption it would need costs more than the restart does ([Where containment ends](#where-containment-ends)) |
| The restart runs after verification and is reported on its own, outside the exit status | the invariant is that the *stop* happened; the manager is a separate fact ([Where containment ends](#where-containment-ends)) |
| Liveness comes from cgroups only | systemd never decides whether something is running ([The decisions inside those phases](#the-decisions-inside-those-phases)) |
| Attribution is best-effort and display-only | the sweep does not consult it, so a misreported project costs a label rather than a target ([Where containment ends](#where-containment-ends)) |
| Agent sessions and account plumbing are counted apart, advisorily | the class comes from a unit name, so it is the account's word; it labels a row and never selects one, and a headline that counted four units of scaffolding as four agent sessions misread the incident ([Where containment ends](#where-containment-ends)) |
| A second run terminates and restarts the manager again | idempotence is in end state; a silent rerun costs either an exemption or a name-decided sweep ([Where containment ends](#where-containment-ends)) |

## Why not

- **`systemctl --user -M ai-tools@.host stop <unit>`.** The obvious one-liner is the wrong instrument for four reasons,
  each of which is a chunk of the code. It asks the monitored system's own manager, which runs as the account being
  stopped over a bus that account can reach, so its answer is the session's account of itself. It reports on unit state
  rather than on processes: "the unit is gone" and "no task is left" are different facts, and a wedged manager,
  an absent machine transport and "already stopped" are one exit status, so the helper never lets systemd decide
  liveness and verifies against `cgroup.procs` and `/proc`, where the kernel wins when the two views disagree. It is
  unavailable exactly when it is needed, since an incident is when the user manager is most likely to be wedged,
  which is why the kill path depends on no project library, no `set -e`, and no external binary but `sleep` (I7). And it
  stops one named unit, where the command has to *find* the sessions first, across a delegated subtree whose names
  the delegatee chooses, and say what it did. Almost none of the code is the turning off: it is discovery, consent,
  verification, restoration, and the record.
- **A dedicated slice for agent sessions.** Launching into an `ai-tools.slice` would let the sweep spare the user
  manager structurally instead of restarting it. It would also put every cgroup *outside* that slice out of reach,
  and on a DAC-only host a session can create a unit there by asking its own user manager, so the slice would buy
  a tidier blast radius at the cost of the property that makes this rung worth having. Revisit only together
  with closing that reach.

## Deferred

Known, bounded, and not built:

- **Pin the cgroup by file descriptor.** A unit can exit and systemd recreate the same path, so a kill could
  in principle hit a newer invocation. Holding an fd on the cgroup directory and working through `/proc/self/fd/<n>/`
  makes a recreated path read `ENOENT`. The worst case today is stopping a *newly started session of the same account*,
  which is not an escalation and is what `--all` would do anyway.
- **A root-recorded session registry.** The prerequisite for any per-project form: `ai-tools-run` recording unit→project
  through the handback socket, whose peer uid the kernel supplies, so the mapping is not the account's word. A verb,
  a registry, and its lifecycle, deferred because `/exit` covers the routine case ([Who may stop
  what](#who-may-stop-what)).
- **A launch/stop gate.** A session launched after the final sweep is outside the window; closing that needs
  the launcher to take the same lock. It would also serialize concurrent stops, whose current cost is duplicate audit
  events rather than a wrong result.
