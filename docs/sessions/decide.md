# Delegating a listing decision to TypeSafe

[Sessions](index.md) · **Decide** — [all docs](../index.md)

```bash
sudo dnf install ai-tools-integration-typesafe
sudo sed -i 's/^#\?AI_TOOLS_INTEGRATIONS=.*/AI_TOOLS_INTEGRATIONS=typesafe/' /etc/ai-tools/operator.conf
sudoedit /etc/ai-tools/endpoints/typesafe.conf   # set TYPESAFE_API_KEY
```

With the `typesafe` integration enabled, a session that meets a long listing —
a grep with sixty hits, a `git log`, a checker's findings — can hand it
to TypeSafe's classifier with the task in one sentence and get back the lines
that bear on it. The agent runs the decide command itself, guided
by the `ai-tools-decide` skill the package ships:

```bash
grep -rn 'resolve_owner' src tests | node /usr/local/lib/ai-tools/typesafe/decide.mjs filter --task "rename resolve_owner in every caller"
```

The kept lines print in full, then one summary line names every other line
by id, so the agent still sees what was set aside. On any failure the command
prints one line saying why and no result, and the agent reads the full listing
as it would have without the integration.

## What leaves the host

The task sentence and the listing lines the agent pipes. The skill's first rule
is to pipe listings and not a file's contents, and the command refuses
a listing over its bound rather than truncating it. Claude Code asks
before running the command, since it is not on the shipped allow list;
the prompt is where you see each call. Whether a given project's lines may
leave the host is your decision, which is why the integration is off until you
name it in `/etc/ai-tools/operator.conf` and set the key.

## The credential

`/etc/ai-tools/endpoints/typesafe.conf` holds the API key and names the host it
may be sent to. It is root-owned in the sandbox group at mode `0640`, so root
and the sandbox account read it and no other account does; edit it with `sudo`.
The command reads it when it runs, and a session is handed the file's path
alone, so the key is in no session's environment. The shipped file has the key
commented: until you set it, the command reports the file as not configured
and does not make a request. An upgrade keeps your copy.
`man 5 ai-tools-typesafe.conf` states each option.

## Turning it off

Remove `typesafe` from `AI_TOOLS_INTEGRATIONS`, or comment the key: either way
the next session's calls fall back to the full listing. Removing the package
withdraws the skill from every agent and leaves the credential file
and the usage log in place.

## The usage log

`/opt/ai-tools/integrations/typesafe/usage.log` gets one line per call: counts,
the model that answered, tokens, elapsed time and the outcome. It does not hold
task text, a listing line, or the key, and the sandbox account writes it, so it
is cost accounting rather than an audit trail; the vendor's console is
the authoritative record.
