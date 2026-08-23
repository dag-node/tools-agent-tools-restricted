# Stopping a running session

`ai-tools --stop` ends agent sessions that are **already running**, and everything they spawned.
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

Three other rules carry a one-line note that this component is their exception, each linking back
here: [messaging](../.claude/rules/messaging.rule.md) (the confirmation defaults *yes*),
[safe-paths](../.claude/rules/safe-paths.rule.md) (the protected-paths backstop is advisory), and
[logging](../.claude/rules/logging.rule.md) (the logger loads best-effort).

**The code is the fourth surface, and it is meant to be read directly.** The functions are named
for the question they answer, so the kill path reads as prose without a comment per line:

```
find_session_cgroups → has_own_tasks → cgroup_pids → cgroup_is_live
authorize_scoped_stop → confirm_stop → end_session → terminate_gracefully → kill_outright
```

---

## 1. For the operator

### The two forms

```
sudo ai-tools --stop                       # sessions running in this project (cwd)
sudo ai-tools --stop /path/to/project      # sessions running in that project
sudo ai-tools --stop --all                 # every agent session on this host
```

Add `-n`/`--dry-run` to list what would stop and change nothing. Add `-y`/`--yes` to skip the
confirmation, `--force` to skip the ten-second grace period and kill immediately. The full grammar
and every exit code are in `ai-tools(1)`.

**Reach for `--all` in an incident.** The scoped form is for routine use — ending your own session
in one project. `--all` needs no allowlist coverage, cannot be evaded from inside a session, and
can only ever over-stop; §2 explains why that difference is real and not caution.

### What you get

Each session is listed with its unit, how many processes it holds and the project it is running in,
and the confirmation is answered against that list — agreeing to stop "3 sessions" without seeing
which projects they are in is not agreeing to anything.

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
| 3 | refused — unclaimed target, or a live session it could not attribute to a project | use `--all`, which needs neither |
| 4 | you declined at the confirmation | nothing was stopped |
| 5 | the helper could not run (no cgroup v2, no sandbox account) | a broken host, not a failed stop |

Exit 0 means precisely this: every session matching the request that existed when the command
enumerated was stopped and verified gone, and a final re-enumeration found nothing matching still
live. It does **not** mean none can start afterwards — see *Residual failure modes* in §2.

### After a stop: reclaim

A stop cannot run the agent's own session-end handback — that hook fires when an agent exits on its
own terms, not when it is signalled. Files written up to the last completed turn were already
handed back; the in-flight turn's writes may still be owned by the sandbox account. The command
names the command to run for each project it stopped:

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
| I6 | The identity a scoped stop authorizes against cannot be written by the account being stopped: `SUDO_USER` is set by a root process (cross-checked against `SUDO_UID`), and an allowlist is `0600` inside a `0700` home. | sudo; the claim CLI | the operator's home permissions |
| I7 | `/proc` and `/sys` reads plus bash builtins need no external binary. The kill path calls `sleep` and nothing else. | the helper's own construction | — |

Two of these carry the whole design. **I1 is why discovery is by cgroup**: a process group is
broken by `setsid(2)` and a ppid walk is broken by the double fork, so neither can enumerate what a
session spawned. **I3 is why the kill is by cgroup too**: signalling a list of pids races the fork
that happens between reading the list and signalling it, and `cgroup.kill` has no such window.

### Who may stop what

All sessions run as one account, so a routine stop must be scoped or one operator would end
another's work. The scoping input has to be something the sandbox account cannot write — which
rules out everything a session records about itself. The launch line, the unit name, and the unit's
own properties are all written by that account: if a stop scoped "which sessions may this operator
end" to a launcher identity recorded there, a session could name any operator it liked and get one
operator to stop another's work.

So the input is the **caller's own `allowed-projects`** (I6) matched against the project a session
is attributed to. Two operators who both claimed a project can stop each other's sessions in it,
which is consistent with them already sharing write access to that tree.

`--all` takes **no authorization input at all**, and that is a decision rather than an omission: a
stop path the monitored system can put itself outside of is not a stop path. It reaches every
cgroup in the account's slice, so there is nothing to be outside of, and its only failure direction
is over-stopping.

### Where containment ends

systemd **delegates** the per-user subtree to the account — that is what lets its user manager
create units at all — and delegation permits the delegatee to move its own tasks between cgroups
*inside* that subtree. Containment holds at the delegation boundary, not within it.

The consequence is precise, and it is why the two forms differ in strength:

- **`--all`** reaches every cgroup in the account's slice, so a move *within* the slice cannot
  escape it. **This form holds against a hostile session.**
- **scoped** selects by the project a cgroup is attributed to, so a process moved into a cgroup
  attributed elsewhere is no longer selected. **This form is for routine use and must not be relied
  on against a session actively evading it.**

A final sweep re-enumerates after the run and reports a cgroup that became live after being
verified empty (`AI_TOOLS_RESULT=reappeared`) — that is what such a move, or a session starting
mid-run, looks like from here. It sends the operator to `--all`.

Attribution is best-effort for the same reason: a `WorkingDirectory` is read from the account's own
user manager, so a rogue unit can misreport it. It cannot use that to *evade* a stop — a misreported
directory makes the session unattributable, which refuses the scoped stop outright rather than
narrowing it silently. The lie costs the liar; it does not buy survival.

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
  case the operator holds the launch path anyway, and for an adversarial session the answer is
  `--all` plus a revoked launch grant, not a stronger promise here.
- **`--all` blast radius.** Everything in the account's slice outside the user manager's own
  `init.scope` is in scope, including an in-flight toolchain update. Harmless — the updater is
  fail-closed on interruption and leaves the previous, trusted version active — but not a surprise
  worth discovering during an incident.
- **Kernel below 5.14 or a cgroup-v1-only host.** Without `cgroup.kill` the fallback re-collects
  and re-signals in a loop, narrowing the fork window without closing it. With no cgroup v2
  hierarchy at all the helper **refuses** (exit 5) and names the manual command, rather than
  reporting that nothing is running. Both supported EL targets are unified and ≥ 5.14.
- **Both log sinks unavailable.** The stop still succeeds or correctly fails; the record is lost.
  The two sinks fail independently.

### What the monitored system can do about it

Nothing, and this is asserted from the agent's own vantage in `tests/boundary/access.sh`: the
sandbox account cannot read, write or execute the helper, cannot reach any operator's
`allowed-projects`, and holds no `sudo` rule to reach root by. The kill is delivered by root to a
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
   subtree whose names the delegatee chooses — decide which of them this operator may stop, and say
   what it did.

That is the answer to "why so much code to turn off a service": almost none of it is the turning
off. It is discovery, authorization, attribution, consent, verification, and the record.

### The five phases

```
  ┌ 1. authorize ──────────────────────────────────────────────────────────────┐
  │  --all      → no input needed, no path accepted                            │
  │  scoped     → absolute path, canonicalized, covered by the CALLER'S OWN     │
  │               allowed-projects (read as root; the sandbox cannot write it)  │
  └────────────────────────────────────────────────────────────────────────────┘
  ┌ 2. enumerate ──────────────────────────────────────────────────────────────┐
  │  walk  /sys/fs/cgroup/user.slice/user-<uid>.slice                           │
  │        descend slices → stop at the first .service/.scope = ONE SESSION     │
  │        the manager service is descended into, never emitted                 │
  │        its init.scope is skipped whole (by exact path)                      │
  │  attribute each unit to a project via WorkingDirectory  (best-effort)       │
  │        scoped + unattributable  →  REFUSE (exit 3), naming each blocker     │
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
  ┌ 5. sweep and report ───────────────────────────────────────────────────────┐
  │  re-enumerate the whole slice (--all) or re-match the project (scoped)      │
  │  any live cgroup  → the run did not complete (exit 1)                       │
  │  live but not one the loop reported  → reappeared: a session moved or       │
  │                                        started mid-run; send to --all       │
  │  name the --reclaim per project stopped                                     │
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

### Degradation policy: three inversions, one reason

For every other component here the safe direction is **don't act**. For this one it is **act**. So
three project-wide conventions are inverted, and each is inverted for that reason alone:

1. **No required dependencies, and no `set -e`.** A missing library that aborted the run would be a
   stop that did not happen. Every library loads behind an inline fallback; an unexpected non-zero
   must never abandon a half-finished kill. Scoped precisely: this does not survive a broken
   coreutils and does not pretend to — `id`, `realpath`, `date`, `logger`, `systemctl` and `sudo`
   are all reachable from a run, each outside the kill path or best-effort within it. What is
   guaranteed is independence from *this project's* libraries. The one seam kept single-sourced is
   the allowlist matcher; if it will not load, the scoped form refuses and names `--all`, which
   stops *more* — so even that degradation moves toward stopping.
2. **The confirmation defaults to yes.** The principle in
   [messaging](../.claude/rules/messaging.rule.md) is unchanged — *the default is the safe
   outcome*; which outcome is safe is what flips.
3. **The protected-paths backstop is advisory.** Every other helper *writes* to the path it is
   given; this one only selects processes by it, so a missing backstop degrades to no gate rather
   than to no stop.

---

## 4. Decisions that must not be reverted

Each of these looks like a defect to a fresh reader, and each is deliberate. If you are about to
"fix" one, this is the section that says why not.

| Decision | Why |
|---|---|
| The confirmation defaults **yes** | for the one control whose job is to act, declining is the failure (§3) |
| No `set -e`, no required library | an aborted run is a stop that did not happen (§3) |
| `safe-paths` is advisory here | this helper writes nothing to the path it is given (§3) |
| Scoped and `--all` differ in strength | delegation is real; do not argue the gap away — it is why `--all` exists (§2) |
| Liveness comes from cgroups only | systemd never decides whether something is running (§3) |
| Attribution is best-effort | it can cost a session its scoped stop, never its survival (§2) |
| A refusal names every blocking cgroup | one unattributable cgroup otherwise blocks every scoped stop with nothing to act on |
| `init.scope` is spared by exact path, not basename | every name in a delegated subtree is the delegatee's to choose |

## 5. Deferred hardening

Known, bounded, and not yet built:

- **Pin the cgroup by file descriptor.** A unit can exit and systemd recreate the same path, so a
  kill could in principle hit a newer invocation. Holding an fd on the cgroup directory and working
  through `/proc/self/fd/<n>/` makes a recreated path read `ENOENT`. The worst case today is
  stopping a *newly started session of the same account*, which is not an escalation and is what
  `--all` would do anyway.
- **A dedicated slice for agent sessions.** Bounding `--all` to an `ai-tools.slice` under the user
  manager would remove the blast radius noted in §2. It is a change to how sessions are launched,
  not to this helper.
- **A launch/stop gate.** The only way to make a scoped stop atomic against a concurrent launch;
  the launcher must take the same lock. The same lock would serialize concurrent stops, whose
  current cost is duplicate audit events rather than a wrong result.

## See also

- `ai-tools(1)` — the option grammar and every exit code
- [docs/project-lifecycle.md](project-lifecycle.md) — claiming projects, and `--reclaim`
- [`.claude/rules/cli.rule.md`](../.claude/rules/cli.rule.md) — the domain contract, for contributors
- [`.claude/rules/governance.rule.md`](../.claude/rules/governance.rule.md) — where this rung sits
  in the incident ladder
