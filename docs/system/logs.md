# Read the logs

[System](index.md) · **Logs** · [SELinux](selinux.md) · [Entrypoint
verification](entrypoint-verification.md) — [all docs](../index.md)

One command answers "has anything gone wrong lately?", and two sinks answer
everything after that: journald for every component, root-only files
for the privileged helpers.

```bash
sudo ai-tools audit                      # findings in the last 7 days
sudo ai-tools audit --since '2 days ago' # any window date(1) understands
```

It reads all three trails and reports what refused, was rejected, was stranded,
or was flagged — a breached secret, a rejected socket peer, a helper timeout,
a refused launch, an agent started from inside another session. It exits
non-zero when anything is reported, so it works from `cron` or a login banner
without its output being parsed. Findings from the root-only files and refusals
from the session's own journald tag are reported **separately**, because only
the first is a trail the agent cannot write.

## An agent started from inside a session

A session can start an agent's binary directly, at its path in the sandbox
toolchain, and that child runs inside the session it was started from: same
unit, same confinement, same account. So the launch line and every ownership
hand-back carry the *parent's* identity, and neither of those two trails tells
the child apart. The kernel does:

```bash
sudo ai-tools audit                         # the records, classified
sudo ausearch -m AVC -ts today | grep -A8 'granted.*execute_no_trans'   # raw
```

The SELinux policy writes the record: the confinement module audits the one
access such a start takes, so the kernel logs it and your own launches are not
in it. No audit rule file is installed. `ai-tools audit` names the agent
for each record and lists them; it also says plainly when it could not make
the reading — no audit daemon running, the policy not loaded, or a policy older
than the rule — rather than showing an empty window.

Both agents also re-run their own binary to reach a tool they bundle — codex
to apply an edit, Claude Code to search files — and those records are counted
in one line rather than listed individually. That split reads the name
the caller passed, so treat the count as noise reduction and the records
as the evidence.

## What the agent ran

Every tool call a session makes is recorded, one line each:

```bash
sudo journalctl -t ai-tools-hook _UID="$(id -u ai-tools)"   # what the agent ran and wrote
```

A `Bash` record carries the command's leading two words and its argument count
— never the command line, which through a here-doc would carry file contents.
The same facts are emitted as native journald fields (`AI_TOOLS_TOOL`,
`AI_TOOLS_CMD`, `AI_TOOLS_ARGC`, `AI_TOOLS_PATH`), so a journal ingester
selects on them without re-parsing the message:

```bash
sudo journalctl -t ai-tools-hook -o json _UID="$(id -u ai-tools)" | jq
```

## Query a component, and pair the tag with a uid

```bash
sudo journalctl -t ai-tools-chown _UID=0                  # the ownership-restore helper
sudo journalctl -t ai-tools-lockdown _UID=0 -p warning    # the secret lockdown
sudo journalctl -t ai-tools-handback _UID=0               # the privilege bridge (one line per request)
sudo journalctl -t ai-tools-run _UID="$(id -u ai-tools)"  # session launches
sudo journalctl -t ai-tools _UID="$(id -u)"               # the CLI (project created, sandbox created, …)
```

The uid matters because a syslog tag is chosen by whoever writes the line,
and the sandbox account can write to `/dev/log` — so a session could emit
a line under a root helper's tag. `_UID` is stamped by journald
from the sender's kernel credentials and cannot be forged, so pairing it
with the tag is what makes a line attributable.

`ai-tools-hook` is the one tag no filter separates: the lifecycle hooks run
**as** the agent, so it is that tag's legitimate writer. Read those lines
as the session's own account, and reconcile them against the root-written
trail.

## The two sinks

Every component logs to **journald**. The root helpers additionally write
to **`/var/log/ai-tools/`**, which is root-owned and readable by root alone,
so the agent can neither read nor append to it — that is what makes it
the trail worth reconciling the session's own lines against. The directory
listing is the set of files; each is named for the helper that writes it.

The handback daemon keeps a per-request audit line — the peer PID, the verb,
the path, and the helper result — plus a `WARNING` for every rejected peer
or malformed request, so each privileged action is attributable at the socket
layer.
