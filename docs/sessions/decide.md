# Delegating a listing decision to TypeSafe

[Sessions](index.md) · **Decide** — [all docs](../index.md)

```bash
sudo dnf install ai-tools-integration-typesafe
sudoedit /etc/ai-tools/operator.conf             # add integration-typesafe to AI_TOOLS_INTEGRATIONS
sudoedit /etc/ai-tools/endpoints/typesafe.conf   # set TYPESAFE_API_KEY
```

`integration-typesafe` joins any integration already named, for example
`AI_TOOLS_INTEGRATIONS=[integration-dotnet, integration-typesafe]`.

With the `typesafe` integration enabled, a session that meets a long listing —
a grep with sixty hits, a `git log`, a checker's findings, a build log — can
hand it to TypeSafe's classifier with the task in one sentence and get back
the lines that bear on it. The agent runs the decide command itself, guided
by the `ai-tools-decide` skill the package ships:

```bash
grep -rn 'resolve_owner' src tests | node /usr/local/lib/ai-tools/typesafe/decide.mjs filter --config "$AI_TOOLS_TYPESAFE_CONF" --usage-log "$AI_TOOLS_TYPESAFE_USAGE_LOG" --task "rename resolve_owner in every caller"
```

The kept lines print in full, then one summary line names every other line
by id, so the agent still sees what was set aside. On any failure the command
prints one line saying why and no result, and the agent reads the full listing
as it would have without the integration.

A build log is handed over as its diagnostics rather than as its lines:

```bash
dotnet build -v n 2>&1 | node /usr/local/lib/ai-tools/typesafe/decide.mjs filter --config "$AI_TOOLS_TYPESAFE_CONF" --usage-log "$AI_TOOLS_TYPESAFE_USAGE_LOG" --format msbuild --task "which diagnostics are the cause"
```

The command keeps each diagnostic, collapses the repeat MSBuild prints in its
summary, and says on the summary line how many lines it set aside — a build log
carries its compiler invocations in the same stream, and one of those lines can
be tens of kilobytes on its own.

## What leaves the host

The task sentence and the listing lines the agent pipes. The skill's first rule
is to pipe listings and not a file's contents, and the command refuses
a listing over its bound rather than truncating it. It also refuses a stream
that is not text — one holding a NUL byte or a run of undecodable bytes —
so a binary file piped in by mistake does not reach the service.

Claude Code asks you before every call, whatever permission mode the session
runs in. Codex runs it without a prompt: this project pins it to ask only
about a command one of its rules marks `prompt`, and the shipped rules mark
none ([Misleading agent setting names](../agents/setting-names.md)). Enabling
the integration is therefore where you consent: whether a given project's lines
may leave the host is your decision, which is why the integration is off until
you name it in `/etc/ai-tools/operator.conf` and set the key. The usage log
records each call afterwards, as counts without content.

## The credential

`/etc/ai-tools/endpoints/typesafe.conf` holds the API key and names the host it
may be sent to. It is root-owned in the sandbox group at mode `0640`, so root
and the sandbox account read it and no other account does; edit it with `sudo`.
The command reads it when it runs, and a session is handed the file's path
alone, so the key is in no session's environment. The shipped file has the key
commented: until you set it, the command reports the file as not configured
and does not make a request. The keep threshold, the uncertain band
and the time one request may take sit beside it, each commented at its default.
An upgrade keeps your copy. `man 5 ai-tools-typesafe.conf` states each option.

The shipped file names the model `jev-latest`, which TypeSafe moves to each
stable release; the usage log records the version that answered each call.
A release can score the same line differently, so to keep the answers of one
release, name it:

```ini
TYPESAFE_MODEL=jev-1.13.0
```

> [!WARNING]
> Every agent session runs as the sandbox account and can therefore read
> the key in this file. The only way to keep the key out of the sandbox's reach
> is an authenticating proxy that holds the key outside the sandbox.

## Rotating the key

```bash
sudoedit /etc/ai-tools/endpoints/typesafe.conf
printf 'basket.txt:1: apple\n' | sudo -u ai-tools node /usr/local/lib/ai-tools/typesafe/decide.mjs filter --task "which lines name a fruit" --config /etc/ai-tools/endpoints/typesafe.conf
```

Replace `TYPESAFE_API_KEY`, then send one synthetic line as the sandbox
account.

- A working key prints the line and a summary that names the model.
- A refused key prints a single `decide: provider:` line with `status=401`
  or `status=403` and TypeSafe's reason.

Until the key is fixed, sessions fall back to the full listing. The agent stops
calling after the first refusal and tells you.

## Turning it off

Remove `integration-typesafe` from `AI_TOOLS_INTEGRATIONS`, or comment the key:
either way the next session's calls fall back to the full listing. Removing
the package withdraws the skill from every agent and leaves the credential file
and the usage log in place.

## The usage log

`/opt/ai-tools/integrations/typesafe/usage.log` gets one line per call: counts,
the model that answered, tokens, elapsed time and the outcome. It does not hold
task text, a listing line, or the key, and the sandbox account writes it, so it
is cost accounting rather than an audit trail; the vendor's console is
the authoritative record.
