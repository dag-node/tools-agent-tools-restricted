# Skills — one view, every agent

`/opt/ai-tools/skills` is the view: each skill in it is linked into the skills directory of every enabled agent, so one
copy serves all of them. The skills come from asset sets, signed packages you install and then enable:

```bash
sudo dnf install ai-tools-assets-core
sudo ai-tools-admin assets enable --set core
```

`core` carries the writing standard (`ai-tools-technical-writing`), the cross-reference grammar (`ai-tools-reftags`),
and the engineering and governance skills; `ls /usr/share/ai-tools-assets/core/skills` lists them. `AI_TOOLS_ASSETS`
in `/etc/ai-tools/operator.conf` names each asset a session loads, and `sudo ai-tools-admin status` reports one
that does not link, with the reason.

The base package seeds one skill here itself, `ai-tools-typesafe-filter`, on behalf
of the `ai-tools-integration-typesafe` package, and only while that integration is installed.

## A skill of your own

| You want the skill | Put it at | The agent |
|---|---|---|
| in one project | `<project>/.claude/skills/<name>/SKILL.md` | reads it and may edit it, in that project's sessions |
| in every project, for one agent | `/opt/ai-tools/.claude/skills/<name>/`, `root:ai-tools`, directories 750, files 640 | reads it; the modes refuse it a write |
| in every project, for every agent | an asset set of your own, signed and enabled | reads it; the set is root's and read-only |

An entry in an agent's skills directory that the sandbox account can write is reported by `status`
as `agent-entry-untrusted`, since every later session loads it. An entry you place in the view itself is reported
as `view-foreign` and is not linked into an agent's directory.

## The seeded skill and its version

A seeded skill carries `x-ai-tools-managed: true` and a monotonic `x-ai-tools-version` in its frontmatter. On install
or bootstrap a newer version replaces the live copy, so an edit made in place is lost at the next release; delete
the `x-ai-tools-managed: true` line to keep the copy as your own. A skill this package stops shipping is moved
to `/opt/ai-tools/retired/`, where its last copy stays for you to recover.

Each reason `status` names, and the view's rules: `man ai-tools-assets`.
