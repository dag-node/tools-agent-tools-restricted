# Subagents — one view, every agent

`/opt/ai-tools/subagents` is the view of subagent definitions, the delegate
roles an agent dispatches to: each one in it is linked into every enabled agent
that reads subagents. Claude Code calls them agents and reads them
from `/opt/ai-tools/.claude/agents/`; this project says subagent, since
an agent here is the coding assistant itself. They come from asset sets:

```bash
sudo dnf install ai-tools-assets-sets-core
atr admin assets enable --set core
```

`core` carries `ai-tools-reference-docs-maintainer`;
`ls /usr/share/ai-tools-assets/core/agents` lists what the set holds. The base
package does not seed a subagent.

A subagent of your own for one agent is a file in that agent's directory,
`root:ai-tools` and mode 640, so the agent reads it and cannot write it. One
for one project goes in `<project>/.claude/agents/`. An entry the sandbox
account can write is reported by `atr admin status` as `agent-entry-untrusted`.

Each reason `status` names, and the view's rules: `man ai-tools-assets`.
