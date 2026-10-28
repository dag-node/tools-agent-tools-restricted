<!-- GENERATED from src/usr/local/bin/ai-tools.sh (OPTION_SPELLINGS) by tools/generators/option-spellings.sh; do not edit this
     file. Change a row in the table and run `bash tools/generators/option-spellings.sh generate`; tests/unit/cli-verbs.sh
     regenerates the page and fails on a difference. -->
<!-- prose-check: ignore-file -->
# Option spellings and the commands they run

`atr` spells a command as a bare word: a collection and its verb (`atr projects claim`), or one word for
the host (`atr status`), with `--` reserved for an option. That is the preferred form, and the option spelling
each command had in earlier releases is kept for compatibility: it is rewritten to the command ahead of every check,
prints one notice, [MSG-W3W8](../src/usr/local/bin/ai-tools.sh), naming the preferred form, and exits as that command
does, so a script written against an earlier release runs unchanged.

| Option spelling              | Preferred form          |
|------------------------------|-------------------------|
| `ai-tools --list`            | `atr projects list`     |
| `ai-tools --project-create`  | `atr projects create`   |
| `ai-tools --project-claim`   | `atr projects claim`    |
| `ai-tools --project-unclaim` | `atr projects unclaim`  |
| `ai-tools --project-remove`  | `atr projects remove`   |
| `ai-tools --project-enable`  | `atr projects enable`   |
| `ai-tools --project-disable` | `atr projects disable`  |
| `ai-tools --sandbox-create`  | `atr projects clone`    |
| `ai-tools --sandbox-push`    | `atr projects push`     |
| `ai-tools --sandbox-remove`  | `atr projects remove`   |
| `ai-tools --lockdown`        | `atr projects lockdown` |
| `ai-tools --reclaim`         | `atr projects handback` |
| `ai-tools --providers`       | `atr providers list`    |
| `ai-tools --status`          | `atr status`            |
| `ai-tools --audit`           | `atr audit`             |
| `ai-tools --stop`            | `atr stop`              |
| `-V`                         | `atr --version`         |
| `-g`                         | `--group`               |

`-g` is the short form `atr projects unclaim` took for `--group`, and `-V` the short form of `--version`; each
is rewritten wherever it stands.

`atr --relabel` is not in the table: the entrypoint reconcile is `atr admin system entrypoints relabel`,
a root command this CLI refuses to run, so that spelling prints the command and exits 2 instead of running it.
