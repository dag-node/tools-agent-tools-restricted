# Stopping a running session

`ai-tools --stop` terminates agent sessions that are **already running**, and everything they
spawned. It is not how you finish a session you are done with — `/exit` inside the session is, and
it lets the session run its own session-end handback. This kills the process tree instead.
Every other operator control changes what the *next* launch gets: unclaiming a project, disabling a
provider, revoking an operator, relabelling an entrypoint. This is the one that acts on a session
in flight, so it is the rung an incident actually lands on.

The property it holds is one sentence: **a stop that is asked for and reported as done has
happened.** Everything below follows from that.

---

## Where each fact lives

Four audiences read about this feature, and each fact has exactly one home. Follow the pointer
rather than expecting the same paragraph twice.

| If you are… | Read | It holds | It never holds |
|---|---|---|---|
| an operator running the command | `ai-tools(1)`, then §1 here | the option grammar and exit codes (man page); what to run, what each outcome means, what to do next | why the code is shaped this way |
| a security or systems reviewer | §2–§3 here | the invariants relied on, where containment ends, residual failure modes | how to use the command |
| a contributor or coding agent | [`.claude/rules/cli.rule.md`](../.claude/rules/cli.rule.md) | the domain contract, and which project-wide conventions this component inverts | the reasoning behind each inversion — it links here |
| reading the code | `ai-tools-stop.sh`'s header and its function names | this file's local mechanism and its exit contract | the design essay |

Two other rules carry a one-line note that this component is their exception, each linking back
here: [messaging](../.claude/rules/messaging.rule.md) (the confirmation defaults *yes*) and
[logging](../.claude/rules/logging.rule.md) (the logger loads best-effort).
[safe-paths](../.claude/rules/safe-paths.rule.md) no longer names this helper at all: it took a
caller-supplied path only for the per-project form, and there is no longer one.

**The code is the fourth surface, and it is meant to be read directly.** The functions are named
for the question they answer, so the kill path reads as prose without a comment per line:

```
find_session_cgroups → has_own_tasks → cgroup_pids → cgroup_is_live
confirm_stop → end_session → terminate_gracefully → kill_outright → restore_user_manager
```

---

## 1. For the operator

### One form

```
sudo ai-tools --stop              # terminate every agent session on this host
sudo ai-tools --stop --dry-run    # list what would be terminated, change nothing
```

Add `-y`/`--yes` to skip the confirmation, `--force` to skip the ten-second grace period and kill
immediately. `--all` is accepted and does nothing — every run already terminates every session, and
the flag exists only so a script that spells the intent out is not refused for being explicit. The
full grammar and every exit code are in `ai-tools(1)`.

**There is no per-project form, and a path is refused rather than ignored.** Two reasons, and the
first is the one that matters:

- *Attribution comes from the account being stopped.* A session is tied to a project by reading its
  `WorkingDirectory` from the sandbox account's own `systemd --user` manager. That is fine for
  telling you what is running; it is not fine for deciding what a stop reaches, because anything a
  session reports about itself would then shape what gets terminated. A unit name is no better — on
  a host without SELinux a session can reach that manager and choose its own. So attribution is
  **reported, never obeyed**, and the set of things terminated is decided by the one fact a session
  cannot influence: membership of the account's cgroup slice.
- *It is not a session-lifecycle command.* The routine way to end a session is `/exit`. This is the
  incident rung, and an incident that warrants it is one that wants everything stopped.

A path is refused with exit 2 rather than accepted-and-ignored, so that if targeted stopping is
ever built — which needs a session-to-project mapping recorded by **root** at launch, not the user
manager's word — `--stop <path>` moves from *error* to *accepted*. Nobody's existing command
silently changes meaning.

### What you get

Each session is listed with its unit, how many processes it holds and the project it is running in,
and the confirmation is answered against that list — agreeing to terminate "3 sessions" without
seeing which projects they are in is not agreeing to anything. A session whose project cannot be
read shows as `unknown` and is terminated like any other; attribution is for you to read, so a
missing one costs you a label rather than costing the stop a target.

> **The confirmation defaults to *yes*.** A bare Enter, a pipe, a cron job and a login banner all
> proceed; only a deliberate `n` declines. This is the opposite of every other destructive command
> here, on purpose (§4). Use `--dry-run` to look without acting.

Each session then gets **10 seconds** to exit on `SIGTERM` before it is killed. The report says
which pass ended it, because that is the most useful line in the trail afterwards:

```
  stopped    ai-tools-claude-code-4711.service  (/home/<you>/projects/api)
  KILLED     ai-tools-claude-code-4823.service  (/home/<you>/projects/web)  did not exit within 10s
```

### Outcomes

| Exit | Meaning | What to do |
|---|---|---|
| 0 | stopped and verified gone, or nothing was running | reclaim the projects it names (below) |
| 1 | something survived `SIGKILL` | see *A process survived* below |
| 2 | usage — an unknown option, or a path (this command takes no target) | run `ai-tools --stop` |
| 4 | you declined at the confirmation | nothing was stopped |
| 5 | the helper could not run (no cgroup v2, no sandbox account) | a broken host, not a failed stop |

Exit 0 means precisely this: every session that existed when the command enumerated was terminated
and verified gone, and a final re-enumeration found nothing still live. It does **not** mean none
can start afterwards — see *Residual failure modes* in §2 — and it says **nothing about the user
manager**, whose restoration is reported separately and never folded into this status.

### After a stop: reclaim

A stop cannot run the agent's own session-end handback — that hook fires when an agent exits on its
own terms, not when it is signalled. Files written up to the last completed turn were already
handed back; the in-flight turn's writes may still be owned by the sandbox account. The command
names the command to run for each project it terminated:

```
ai-tools --reclaim /home/<you>/projects/api
```

The next session that starts in that project also notices the missing clean-exit marker, widens its
`.git` reclaim and warns you.

### What a stop does not undo

Stopping ends the process. It does not roll back what the session already did: files it wrote are
on disk, commits it made are in the repository, and anything it pushed to a remote is gone. This
rung is **containment, not reversal**. If the concern is what a session may still do rather than
what it has done, stop first and investigate second — that ordering is the point of the rung.

### A process survived (exit 1)

A task only outlives `SIGKILL` while blocked in an uninterruptible kernel call (`D` state): a hung
NFS mount, a wedged block device, a stalled page fault. Worth knowing before you escalate: such a
task holds no CPU, executes no instructions and can start nothing new — it is stopped in every
sense that matters — but only the I/O completing or a reboot clears it from the process table.

```
sudo ps -o pid,stat,wchan:20,cmd -u ai-tools
sudo cat /proc/<pid>/stack
```

### Reading the trail

Every run is recorded twice: to journald, and to a root-only file the sandbox account can neither
read nor append to.

```
sudo cat /var/log/ai-tools/stop.log
sudo journalctl -t ai-tools-stop _UID=0 -n 50
journalctl -t ai-tools-stop -o json | jq 'select(.AI_TOOLS_RESULT)'
```

Recorded: the request and who made it, which path gave consent (`flag`, `prompt`,
`fallback-prompt`, `no-tty` — the last means nobody was asked, which is legitimate and is exactly
what you want to see when asking why a session stopped at 4am), each session ended and which pass
ended it, and anything that survived. An interrupted run records that too, so silence in the trail
is never ambiguous.

One operator ending another operator's work is a thing the trail shows. That is deliberate: all
sessions run as one shared account, so the trail is the only place the *human* behind a stop is
recorded.

### The drill

`tests/manual/verify-live-flows.sh --stop-all-drill` runs the destructive form end to end and
checks the result against the kernel. An escalation ladder nobody has climbed is a document, not a
control — run it deliberately, periodically, and read the trail afterwards. Without the flag the
same section still exercises everything reversible (the dry run, both refusals, the trail).

---

## 2. For the security specialist

### The threat this rung answers

A session is not a service. It is an interactive process with tool access, running as a shared
service account, able to spawn arbitrary children — and, in the case this control exists for, one
that may be doing something an operator wants ended *now* and may not cooperate. So the stop path
is designed against a session that is at best indifferent and at worst adversarial, and it is
judged by one question: **can the monitored system decline, evade, or disarm it?**

### The invariants it rests on

| # | Invariant | Where it comes from | What would break it |
|---|---|---|---|
| I1 | A process cannot leave the cgroup it is in, and a child inherits it across `fork()`. Membership survives `setsid(2)` and the double fork that re-parents to PID 1. | `cgroups(7)`; a task moves only when something writes a `cgroup.procs` | a kernel that lets a task rewrite its own membership |
| I2 | Every process of the sandbox account lives under that account's per-user slice, `user-<uid>.slice`. | `systemd-logind(8)` places user processes there; the account has no login shell, so nothing else creates one | a process escaping to another slice — needs the user manager, which SELinux denies and DAC-only leaves as a residual |
| I3 | `SIGKILL` is neither catchable nor blockable, and `cgroup.kill` (Linux ≥ 5.14) delivers it to a whole cgroup **atomically** — one write freezes the cgroup and kills every member including descendants. | `signal(7)`; `cgroups(7)` | nothing in userspace |
| I4 | The kernel answers "is anything alive here" itself: `cgroup.events`' `populated` field is 1 while the cgroup **or any descendant** holds a live process. | cgroup v2 interface files | a threaded subtree, where `cgroup.procs` reads fail — handled by corroborating with `cgroup.threads` |
| I5 | Only root may signal across accounts and write `cgroup.kill`. The sandbox account holds no `sudo` rule, and the session runs under `PR_SET_NO_NEW_PRIVS`, which drops `sudo`'s SUID bit outright. | the sudoers drop-in; `ai-tools-run`'s unit properties | an operator adding a rule for the sandbox account |
| I6 | The set of sessions terminated is decided by cgroup-slice membership alone — no input the account can write reaches that decision, because the command takes no target and no authorization argument. | this command's own grammar | adding a per-project form scoped by anything the account reports |
| I7 | `/proc` and `/sys` reads plus bash builtins need no external binary. The kill path calls `sleep` and nothing else. | the helper's own construction | — |

Two of these carry the whole design. **I1 is why discovery is by cgroup**: a process group is
broken by `setsid(2)` and a ppid walk is broken by the double fork, so neither can enumerate what a
session spawned. **I3 is why the kill is by cgroup too**: signalling a list of pids races the fork
that happens between reading the list and signalling it, and `cgroup.kill` has no such window.

### Who may stop what

Any enrolled operator may run it, and it terminates every agent session on the host — including
other operators' sessions. That is deliberate, and it is not a widening: `--all` never took an
authorization input, so an operator could always end everyone's sessions. What changed is that
there is no longer a *politer* form beside it, because the politer form was not a control.

A per-project form would have to decide which sessions belong to a project, and every available
answer is written by the account being stopped — the unit's `WorkingDirectory`, its name, its
launch line. Scoping a stop by any of them lets a session influence what a stop reaches, which is
exactly inverted. The alternative that would work is a session-to-project mapping recorded by
**root** at launch (through the handback socket, whose peer uid the kernel supplies), and that is
real machinery: a verb, a registry, and its lifecycle. It is not built, because the routine way to
end a session is `/exit`, and the incident that reaches for this rung wants everything stopped.

The operational consequence, stated plainly rather than left to be discovered: **on a shared host
one operator's stop ends every operator's sessions.** The trail records who asked.

### Where containment ends

systemd **delegates** the per-user subtree to the account — that is what lets its user manager
create units at all — and delegation permits the delegatee to move its own tasks between cgroups
*inside* that subtree. Containment holds at the delegation boundary, not within it.

On a host with the SELinux module loaded this is closed outright: `ai_tools_t` is granted nothing
on `cgroup_t` (only a `dontaudit … getattr`), so a session can neither write a `cgroup.procs` nor
create a cgroup, and it has no `connectto` on the user runtime socket, so it cannot reach its own
user manager to ask for a unit either. **On a DAC-only host both are reachable**, since the account
owns the delegated cgroup files and its own bus socket.

This is why the sweep **spares nothing** — not the account's own `systemd --user`, not its
`init.scope`. An exemption is a destination: any cgroup left out is one a session on a DAC-only
host can move into, whether it is named or identified by exact path. Sparing nothing means there is
nowhere to move to, and a unit the session asks its manager to create is still inside the slice
being swept. It also means **no unit name appears in the helper at all**, so there is nothing here
to differ between EL9, EL10 and Fedora.

The cost is that the user manager is terminated too, and `SIGKILL` leaves `user@<uid>.service`
**failed** rather than restarting it. That is paid back rather than exempted: `restore_user_manager`
runs after the kill *and* after the verification, restarts the unit, and reports the outcome on its
own — a manager that did not come back never changes what the command says about the stop. If it
fails, the message names the fix and the next launch needs it before a session can start.

A final sweep re-enumerates after the run and reports a cgroup that became live after being
verified empty (`AI_TOOLS_RESULT=reappeared`) — that is what a mid-run launch looks like from here.
Re-running is the remedy; the command is idempotent.

Attribution is best-effort, and now carries no weight: a `WorkingDirectory` is read from the
account's own user manager, so a rogue unit can misreport it — and all that buys is a wrong label
in the table and a missing `--reclaim` line. It cannot affect what is terminated, because nothing
is selected by it.

### Residual failure modes

Stated so the guarantee is bounded honestly rather than overstated.

- **Uninterruptible sleep.** A `D`-state task cannot be reaped until its syscall returns; the run
  reports it as surviving, which is honest. It executes nothing meanwhile.
- **The helper itself is `SIGKILL`ed mid-run.** An `EXIT` trap narrows the *audit* gap (it covers
  every signal bash can handle) but nothing narrows the *state* gap. The remedy is that the command
  is idempotent: run it again. A watchdog would be a second privileged daemon for a case a rerun
  already answers.
- **The launch/stop window.** A session launched after the final sweep is outside the command's
  window. Closing it needs a gate shared with the launcher, which does not exist; for the incident
  case the operator holds the launch path anyway, and for an adversarial session the answer is a
  revoked launch grant beside the stop, not a stronger promise here.
- **Blast radius.** Everything in the account's slice is in scope, including an in-flight toolchain
  update and the account's own user manager. The updater is fail-closed on interruption and leaves
  the previous, trusted version active; the manager is restarted afterwards. Neither is a surprise
  worth discovering during an incident, which is why both are stated here.
- **The manager does not come back.** The restart is best-effort and reported separately. Until it
  succeeds the host cannot start a *new* session — nearer to the point of this command than against
  it, but it must be fixed before work resumes. The message names the command.
- **Kernel below 5.14 or a cgroup-v1-only host.** Without `cgroup.kill` the fallback re-collects
  and re-signals in a loop, narrowing the fork window without closing it. With no cgroup v2
  hierarchy at all the helper **refuses** (exit 5) and names the manual command, rather than
  reporting that nothing is running. Both supported EL targets are unified and ≥ 5.14.
- **Both log sinks unavailable.** The stop still succeeds or correctly fails; the record is lost.
  The two sinks fail independently.

### What the monitored system can do about it

Nothing, and this is asserted from the agent's own vantage in `tests/boundary/access.sh`: the
sandbox account cannot read, write or execute the helper and holds no `sudo` rule to reach root
by. There is no authorization input left for it to aim at, either — the command takes none. The kill is delivered by root to a
cgroup, and nothing inside the cgroup takes part in it. The user manager (`init.scope`) is spared
by exact path, never by basename — a nested cgroup that names itself `init.scope` is enumerated
like any other, because every name inside a delegated subtree is the delegatee's to choose. Dot-
named cgroups are enumerated for the same reason.

---

## 3. Implementation

### Why this is not `systemctl stop`

The obvious one-liner is
`systemctl --user -M ai-tools@.host stop ai-tools-claude-code-<pid>.service`. It is the wrong
instrument here for four reasons, each of which is a chunk of the code:

1. **It asks the monitored system's own manager.** That manager runs as the account being stopped,
   over a bus that account can reach. Its answer is the session's account of itself.
2. **It reports on unit state, not on processes.** "The unit is gone" and "no task is left" are
   different facts, and a wedged manager, an absent machine transport and "already stopped" are one
   exit status. The helper therefore never lets systemd decide liveness; it verifies against
   `cgroup.procs` and `/proc`, and where the two views disagree the kernel wins.
3. **It is unavailable exactly when you need it.** An incident is when the user manager is most
   likely to be wedged. The kill path deliberately depends on no project library, no `set -e`, and
   no external binary but `sleep` (I7).
4. **It stops one named unit.** The command has to *find* the sessions first — across a delegated
   subtree whose names the delegatee chooses — and say what it did.

That is the answer to "why so much code to turn off a service": almost none of it is the turning
off. It is discovery, consent, verification, restoration, and the record.

### The five phases

```
  ┌ 1. parse ──────────────────────────────────────────────────────────────────┐
  │  no target, no authorization input: nothing to decide, nothing to trust     │
  │  --all accepted and inert; a PATH is refused (exit 2), never ignored        │
  └────────────────────────────────────────────────────────────────────────────┘
  ┌ 2. enumerate ──────────────────────────────────────────────────────────────┐
  │  walk  /sys/fs/cgroup/user.slice/user-<uid>.slice                           │
  │        descend slices → stop at the first .service/.scope = ONE SESSION     │
  │        the manager service is descended into, never emitted                 │
  │        NOTHING is exempt -- init.scope is enumerated like anything else     │
  │  attribute each unit via WorkingDirectory  (best-effort, DISPLAY ONLY:      │
  │        it selects nothing, so `unknown` costs a label, not a target)        │
  └────────────────────────────────────────────────────────────────────────────┘
  ┌ 3. confirm ────────────────────────────────────────────────────────────────┐
  │  the table, then a question that DEFAULTS TO YES; consent path recorded     │
  └────────────────────────────────────────────────────────────────────────────┘
  ┌ 4. end each session ───────────────────────────────────────────────────────┐
  │  SIGTERM pass, deepest-first, re-collected each second, up to 10s           │
  │        → empty?  outcome = terminated                                       │
  │  SIGKILL pass:  write cgroup.kill (atomic, re-asserted per pass)            │
  │                 + validated per-pid kill as the pre-5.14 fallback           │
  │        → empty?  outcome = killed        else  outcome = alive              │
  └────────────────────────────────────────────────────────────────────────────┘
  ┌ 5. sweep, restore, report ─────────────────────────────────────────────────┐
  │  re-enumerate the whole slice; any live cgroup → did not complete (exit 1)  │
  │  live but not one the loop reported  → reappeared: a session started        │
  │                                        mid-run; re-running is the remedy    │
  │  restart user@<uid>.service -- AFTER verification, reported separately,     │
  │        never folded into the stop's exit status                             │
  │  name the --reclaim per project terminated                                  │
  └────────────────────────────────────────────────────────────────────────────┘
```

### The decisions inside those phases

- **A systemd *unit* is the unit of work.** The walk descends `.slice` directories and stops at the
  first `.service`/`.scope`, emitting it whole: its nested cgroups are part of it, so descending
  further would list the same processes twice and offer a parent slice as a stoppable thing —
  which would take every sibling unit with it. Nothing is lost, because the only place a task can
  hide from a unit walk is a slice, and a slice holding tasks *directly* is emitted in its own
  right.
- **Deepest-first signalling.** Children are reached before their parents, so a parent is never
  left waiting on a child it can still see.
- **Re-collect between passes.** A set read once and signalled twice misses whatever was forked in
  between. Each pass re-reads the cgroup.
- **Validate a pid's start time immediately before signalling it** (`/proc/<pid>/stat` field 22),
  so a pid recycled between collection and kill is skipped rather than signalled blind. This is the
  pre-5.14 path; `cgroup.kill` signals no pids at all.
- **Every liveness read fails closed.** Only one failure means "empty": the file not existing, i.e.
  the cgroup was removed, which is what a completed kill looks like. A permission-unreadable
  `cgroup.procs` reports LIVE. A threaded cgroup — whose `cgroup.procs` read fails while live
  threads sit in it — is corroborated against `cgroup.threads` (I4), because bash cannot tell a
  failed `read(2)` from a clean EOF.
- **Verification never runs through an external command.** An earlier form of the liveness
  predicate piped to `head`; with `head` absent it would have answered "no tasks" and reported a
  stop as complete while the session ran. Every other external in the file fails toward doing
  *less*; that one failed toward *claiming more*, on the one check the guarantee rests on.

### Degradation policy: two inversions, one reason

For every other component here the safe direction is **don't act**. For this one it is **act**. So
two project-wide conventions are inverted, and each is inverted for that reason alone:

1. **No required dependencies, and no `set -e`.** A missing library that aborted the run would be a
   stop that did not happen. Every library loads behind an inline fallback; an unexpected non-zero
   must never abandon a half-finished kill. Scoped precisely: this does not survive a broken
   coreutils and does not pretend to — `id`, `date`, `logger`, `systemctl` and `sudo` are all
   reachable from a run, each outside the kill path or best-effort within it. What is guaranteed is
   independence from *this project's* libraries, and now absolutely: **no project library is
   load-bearing here at all.** The command takes no input that decides which sessions to stop, so
   there is nothing left for one to gate. `log.lib.sh` and `msg.lib.sh` load best-effort for output
   quality; `safe-paths.lib.sh` and `operator.lib.sh` are no longer loaded, having existed here
   only to vet and authorize a caller-supplied target.
2. **The confirmation defaults to yes.** The principle in
   [messaging](../.claude/rules/messaging.rule.md) is unchanged — *the default is the safe
   outcome*; which outcome is safe is what flips.

---

## 4. Decisions that must not be reverted

Each of these looks like a defect to a fresh reader, and each is deliberate. If you are about to
"fix" one, this is the section that says why not.

| Decision | Why |
|---|---|
| The confirmation defaults **yes** | for the one control whose job is to act, declining is the failure (§3) |
| No `set -e`, no required library | an aborted run is a stop that did not happen (§3) |
| There is **no per-project form**, and a path is an error | every way to attribute a session to a project is written by the account being stopped (§2) |
| A path errors rather than being ignored | it keeps targeted stopping addable later without changing what an existing command means (§1) |
| **Nothing is exempt**, `init.scope` included | an exemption is a cgroup a session can move into on a DAC-only host (§2) |
| The user manager is restarted, not spared | the exemption it would need costs more than the restart does (§2) |
| The restart never changes the exit status | the invariant is that the *stop* happened; the manager is a separate fact (§2) |
| Liveness comes from cgroups only | systemd never decides whether something is running (§3) |
| Attribution is best-effort and display-only | it selects nothing, so a misreported project costs a label, never a target (§2) |

## 5. Deferred hardening

Known, bounded, and not yet built:

- **Pin the cgroup by file descriptor.** A unit can exit and systemd recreate the same path, so a
  kill could in principle hit a newer invocation. Holding an fd on the cgroup directory and working
  through `/proc/self/fd/<n>/` makes a recreated path read `ENOENT`. The worst case today is
  stopping a *newly started session of the same account*, which is not an escalation and is what
  `--all` would do anyway.
- **A dedicated slice for agent sessions.** Launching into an `ai-tools.slice` would let the sweep
  spare the user manager structurally instead of restarting it. **Rejected for now, and the reason
  matters:** it would also put every cgroup *outside* that slice out of reach, and on a DAC-only
  host a session can create a unit there by asking its own user manager — so the slice would buy a
  tidier blast radius at the cost of the property that makes this rung worth having. Revisit only
  together with closing that reach.
- **A root-recorded session registry.** The prerequisite for any per-project form: `ai-tools-run`
  recording unit→project through the handback socket, whose peer uid the kernel supplies, so the
  mapping is not the account's word. A verb, a registry, and its lifecycle — not built, because
  `/exit` covers the routine case (§2).
- **A launch/stop gate.** A session launched after the final sweep is outside the window; closing
  that needs the launcher to take the same lock. It would also serialize concurrent stops, whose
  current cost is duplicate audit events rather than a wrong result.

## See also

- `ai-tools(1)` — the option grammar and every exit code
- [docs/project-lifecycle.md](project-lifecycle.md) — claiming projects, and `--reclaim`
- [`.claude/rules/cli.rule.md`](../.claude/rules/cli.rule.md) — the domain contract, for contributors
- [`.claude/rules/governance.rule.md`](../.claude/rules/governance.rule.md) — where this rung sits
  in the incident ladder
