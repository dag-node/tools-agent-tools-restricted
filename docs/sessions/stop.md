# Stopping a running session

[Sessions](index.md) · **Stop** — [all docs](../index.md)

`ai-tools stop` terminates agent sessions that are **already running**,
and everything they spawned. It is not how you finish a session you are done
with — `/exit` inside the session is, and it lets the session run its own
session-end handback. This kills the process tree instead. Every other operator
control changes what the *next* launch gets: unclaiming a project, disabling
a provider, revoking an operator, relabelling an entrypoint. This is the one
that acts on a session in flight, so it is the rung an incident actually lands
on.

The property it holds is one sentence: **a stop that is asked for and reported
as done has happened.** Everything on this page follows from that.

This page says what to run, what each outcome means, and what to do next;
`ai-tools(1)` holds the option grammar and every exit code. The invariants
the stop rests on, where containment ends, and its residual failure modes are
written for a reviewer or a contributor
in [the stop rule](../../.claude/rules/stop.rule.md).

## One form

```
ai-tools stop              # terminate every agent session on this host
ai-tools stop --dry-run    # list what would be terminated, change nothing
```

Run it as yourself, not under `sudo` — the CLI reaches the root helper on its
own, and the bare form runs without a password at all, so an unattended
detector reaches it too
([ref-section-r5r9](../../.claude/rules/stop.rule.md#ref-section-r5r9)). Every
option falls outside that grant — `--dry-run`, `--force`, `-y` and `--all`
alike — so a flagged form prompts for your password. Root may run the command
too.

Add `-y`/`--yes` to skip the confirmation, `--force` to skip the ten-second
grace period and kill immediately. `--all` is accepted and has no effect: every
run already terminates every session. The full grammar and every exit code are
in `ai-tools(1)`.

**There is no per-project form, and a path is refused rather than ignored.**
Two reasons, and the first is the one that matters:

- *Attribution comes from the account being stopped.* A session is tied
  to a project by reading its `WorkingDirectory` from the sandbox account's own
  `systemd --user manager`. That is fine for telling you what is running; it is
  not fine for deciding what a stop reaches, because anything a session reports
  about itself would then shape what gets terminated. A unit name is no better
  — on a host without SELinux a session can reach that manager and choose its
  own. So attribution is **reported, never obeyed**, and the set of things
  terminated is decided by the one fact a session cannot influence: membership
  of the account's cgroup slice.
- *It is not a session-lifecycle command.* The routine way to end a session is
  `/exit`. This is the incident rung, and it stops every session at once.

A path is refused with exit 2 rather than accepted-and-ignored, so that if
targeted stopping is ever built — which needs a session-to-project mapping
recorded by **root** at launch, not the user manager's word — `stop <path>`
moves from *error* to *accepted*. Nobody's existing command silently changes
meaning.

## What you get

Each session is listed with its unit, how many processes it holds
and the project it is running in, and the confirmation is answered
against that list — agreeing to terminate "3 sessions" without seeing
which projects they are in is not agreeing to anything. A session whose project
cannot be read shows as `unknown` and is terminated like any other; attribution
is for you to read, so a missing one costs you a label rather than costing
the stop a target.

**Agent sessions and the account's own plumbing are counted separately.**
The slice holds more than sessions: the account's `systemd --user` and its
`init.scope`, a dbus broker, and a login session scope for every `sudo -u`
that crossed `pam_systemd`. All of them are terminated — no cgroup is exempt —
but they are listed after the agent sessions and marked `(account plumbing)`,
and the headline gives the two counts apart:

```
1 agent session(s) will be terminated, with everything they spawned. 3 unit(s) of the
ai-tools account's own plumbing (marked below) go with them -- nothing in the account's
slice is exempt -- and its user manager is restarted afterwards.

            SESSION                              PROCS  PROJECT
  stop      ai-tools-claude-code-4711.service        1  /home/<you>/projects/api
  stop      session-c27.scope                        4  unknown        (account plumbing)
  stop      dbus-broker.service                      2  /opt/ai-tools  (account plumbing)
  stop      init.scope                               2  unknown        (account plumbing)
```

The split is **advisory, exactly like attribution, and for the same reason**:
a unit name inside the delegated subtree is the delegatee's to choose,
so a session can name itself out of the agent class. That gains it no
exemption: both classes are enumerated, listed and killed identically,
and the sweep consults neither class to decide what it reaches. What the split
buys is that the line you read first during an incident does not tell you four
agents were running when one was.

Only agent sessions produce a `projects handback` line, because only they have
a project to hand back. The account's dbus broker reports `/opt/ai-tools`
as its working directory — the control plane, which the protected-paths
backstop refuses — so listing it offered a remedy that cannot run.

## A second run is not silent

Running `stop` again straight after a successful one is **not** a no-op,
and that follows from sweeping every cgroup rather than being a defect in it.
The user manager the first run restored is itself inside the swept slice,
so the second run finds it, terminates it, and restarts it again:

```
No agent session is running. 1 unit(s) of the ai-tools account's own plumbing (marked below)
are stopped regardless -- nothing in the account's slice is exempt -- and its user manager is
restarted afterwards.
```

The command is idempotent in **end state** — no sessions, manager up — which is
what "re-running is the remedy" means. It is not idempotent in what it
*reports*, and it cannot be without either exempting the manager (a cgroup
a session could then move into) or letting a name decide what is swept.

> **The confirmation defaults to *yes*.** A bare Enter, a pipe, a cron job
> and a login banner all proceed; only a deliberate `n` declines. This is
> the opposite of every other destructive command here, on purpose
> ([ref-section-e8k5](../../.claude/rules/stop.rule.md#ref-section-e8k5)). Use
> `--dry-run` to look without acting.

Each session then gets **10 seconds** to exit on `SIGTERM` before it is killed.
The report says which pass ended it, because that is the most useful line
in the trail afterwards:

```
  stopped    ai-tools-claude-code-4711.service  (/home/<you>/projects/api)
  KILLED     ai-tools-claude-code-4823.service  (/home/<you>/projects/web)  did not exit within 10s
```

## Outcomes

| Exit | Meaning | What to do |
|---|---|---|
| 0 | stopped and verified gone, or no session was running | reclaim the projects it names ([After a stop: reclaim](#after-a-stop-reclaim)) |
| 1 | something survived `SIGKILL` | see [A process survived](#a-process-survived-exit-1) |
| 2 | usage — an unknown option, or a path (this command does not take a target) | run `ai-tools stop` |
| 4 | you declined at the confirmation | no session was stopped |
| 5 | the helper could not run (no cgroup v2, no sandbox account) | a broken host, not a failed stop |
| 130 | the run was interrupted by a signal | some sessions may be partially stopped; run it again |

Exit 0 means precisely this: every session that existed when the command
enumerated was terminated and verified gone, and a final re-enumeration found
no process still live. It does **not** mean none can start afterwards — the
residual failure modes are in [the stop
rule](../../.claude/rules/stop.rule.md) — and it makes **no claim about
the user manager**, whose restoration is reported on its own line and is not
part of this status.

## After a stop: reclaim

A stop cannot run the agent's own session-end handback — that hook fires
when an agent exits on its own terms, not when it is signalled. Files written
up to the last completed turn were already handed back; the in-flight turn's
writes may still be owned by the sandbox account. The command names the command
to run for each project it terminated:

```
ai-tools projects handback /home/<you>/projects/api
```

The next session that starts in that project also notices the missing
clean-exit marker, widens its `.git` reclaim and warns you.

## What a stop does not undo

Stopping ends the process. It does not roll back what the session already did:
files it wrote are on disk, commits it made are in the repository, and anything
it pushed to a remote is gone. This rung is **containment, not reversal**. If
the concern is what a session may still do rather than what it has done, stop
first and investigate second — that ordering is the point of the rung.

## A process survived (exit 1)

A task only outlives `SIGKILL` while blocked in an uninterruptible kernel call
(`D` state): a hung NFS mount, a wedged block device, a stalled page fault.
Worth knowing before you escalate: such a task is off the run queue: it
consumes no CPU, does not execute a further instruction, and cannot start
a process — it is stopped in every sense that matters — but only the I/O
completing or a reboot clears it from the process table.

```
sudo ps -o pid,stat,wchan:20,cmd -u ai-tools
sudo cat /proc/<pid>/stack
```

## Reading the trail

Every run is recorded twice: to journald, and to a root-only file the sandbox
account can neither read nor append to.

```
sudo cat /var/log/ai-tools/stop.log
sudo journalctl -t ai-tools-stop _UID=0 -n 50
journalctl -t ai-tools-stop -o json | jq 'select(.AI_TOOLS_RESULT)'
```

Recorded: the request and who made it, which path gave consent (`flag`,
`prompt`, `fallback-prompt`, `no-tty` — the last means nobody was asked,
which is legitimate and is exactly what you want to see when asking
why a session stopped at 4am), each session ended and which pass ended it,
and anything that survived. An interrupted run records that too, so silence
in the trail is never ambiguous.

One operator ending another operator's work is a thing the trail shows. That is
deliberate: all sessions run as one shared account, so the trail is the only
place the *human* behind a stop is recorded.

## The drill

`tests/manual/verify-live-flows.sh --stop-all-drill` runs the destructive form
end to end and checks the result against the kernel. An escalation ladder
nobody has climbed is a document, not a control — run it deliberately,
periodically, and read the trail afterwards. Without the flag the same section
still exercises everything reversible (the dry run, both refusals, the trail).
