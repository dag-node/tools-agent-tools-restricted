<!-- GENERATED from src/usr/local/bin/ai-tools.sh (OPTION_SPELLINGS) by tools/generators/option-spellings.sh; do not edit this
     file. Change a row in the table and run `bash tools/generators/option-spellings.sh generate`; tests/unit/cli-verbs.sh
     regenerates the page and fails on a difference. -->
<!-- prose-check: ignore-file -->
# Option spellings and the commands they run

`ai-tools` spells a command as a bare word: a collection and its verb (`ai-tools projects claim`), or one word for
the host (`ai-tools status`), with `--` reserved for an option. That is the preferred form, and the option spelling
each command had in earlier releases is kept for compatibility: it is rewritten to the command ahead of every check,
prints one notice, [MSG-W3W8](../src/usr/local/bin/ai-tools.sh), naming the preferred form, and exits as that command
does, so a script written against an earlier release runs unchanged.

| Option spelling              | Preferred form               |
|------------------------------|------------------------------|
| `ai-tools --list`            | `ai-tools projects list`     |
| `ai-tools --project-create`  | `ai-tools projects create`   |
| `ai-tools --project-claim`   | `ai-tools projects claim`    |
| `ai-tools --project-unclaim` | `ai-tools projects unclaim`  |
| `ai-tools --project-remove`  | `ai-tools projects remove`   |
| `ai-tools --project-enable`  | `ai-tools projects enable`   |
| `ai-tools --project-disable` | `ai-tools projects disable`  |
| `ai-tools --sandbox-create`  | `ai-tools projects clone`    |
| `ai-tools --sandbox-push`    | `ai-tools projects push`     |
| `ai-tools --sandbox-remove`  | `ai-tools projects remove`   |
| `ai-tools --lockdown`        | `ai-tools projects lockdown` |
| `ai-tools --reclaim`         | `ai-tools projects handback` |
| `ai-tools --providers`       | `ai-tools providers list`    |
| `ai-tools --status`          | `ai-tools status`            |
| `ai-tools --audit`           | `ai-tools audit`             |
| `ai-tools --stop`            | `ai-tools stop`              |
| `-V`                         | `ai-tools --version`         |
| `-g`                         | `--group`                    |

`-g` is the short form `ai-tools projects unclaim` took for `--group`, and `-V` the short form of `--version`; each
is rewritten wherever it stands.

`ai-tools --relabel` is not in the table: the entrypoint reconcile is `sudo ai-tools-admin system entrypoints relabel`,
a root command this CLI refuses to run, so that spelling prints the command and exits 2 instead of running it.
