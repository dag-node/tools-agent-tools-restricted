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

It reads both trails and reports what refused, was rejected, was stranded,
or was flagged — a breached secret, a rejected socket peer, a helper timeout,
a refused launch. It exits non-zero when anything is reported, so it works
from `cron` or a login banner without its output being parsed. Findings
from the root-only files and refusals from the session's own journald tag are
reported **separately**, because only the first is a trail the agent cannot
write.

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
