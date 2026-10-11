---
paths:
  - "src/**/*.sh"
  - "install.sh"
  - "selinux/**/*.sh"
  - "packaging/**/*.sh"
  - "tests/**/*.sh"
  - "tools/**/*.sh"
---

# Shell naming conventions

Files sourced into one shell share its function definitions and global variables. A second definition silently replaces
the first.

`ai-tools-run` sources provider session-env fragments into the shell that holds the trust libraries. `nvm-update.sh`
sources `nvm.sh`. Therefore every name this project defines carries the project prefix and names the owning module
before `__`. Collisions become visible in the name, and `git grep` finds every use of a module.

## Name forms

| Kind | Form | Example |
|---|---|---|
| Public function | `ai_tools_<module>__<member>` | `ai_tools_conf__is_trusted` |
| Private function | `_ai_tools_<module>__<member>` | `_ai_tools_relabel__register_fcontext` |
| Public global or constant | `AI_TOOLS_<MODULE>__<NAME>` | `AI_TOOLS_ASSETS__STATE` |
| Private global | `_AI_TOOLS_<MODULE>__<NAME>` | `_AI_TOOLS_ASSETS__KIND_COLUMNS` |
| Environment variable, `operator.conf` key, root-only test hook, journald field | `AI_TOOLS_<NAME>` (no `__`) | `AI_TOOLS_ASSETS_HOME`, `AI_TOOLS_REQUIRE_SELINUX` |
| Function-local variable | lowercase `snake_case`, declared `local` | `local agent_name` |

Bash scopes `local` variables dynamically, so they are visible to every function the current function calls.
When a function takes a variable name from its caller via `local -n`, give its own locals a prefix the caller's name
does not carry. This prevents name resolution to the wrong variable:

- `_ai_tools_conf__pair_list_item`
- `_records_dec_out`

## Module derivation

1. Remove `.lib.sh` or `.sh` from the defining file's name.
2. Remove a leading `ai-tools-`.
3. Replace each `-` with `_`.

Examples:

- `assets-verify.lib.sh` → `assets_verify`
- `ai-tools-run.sh` → `run`
- `nvm-update.sh` → `nvm_update`

A module name must be unique among files that can share a shell. Libraries live in one directory. When an executable's
derived name would match a library it sources, choose a different module name before using the module form.

## Syntax

- `__` appears exactly once, between the module and the member.
- A single `_` separates words inside a name.
- Every name must be a valid shell identifier for both functions and variables. Do not use `::`.

## Scope

- A leading `_` marks an implementation detail of one module. No other production file may read or write it. Tests may.
- Any name accessed by another production file must use the public form. The defining library assigns the name
  before any read on every code path, so an inherited environment value is never used.
- A library loads another library by sourcing it or by testing for the public function it calls (`declare -F`). Do not
  read another library's load guard.
- External interfaces keep their existing names (operator files, man pages, journal fields).

## Member naming

| Function purpose | Member form | Example |
|---|---|---|
| Tests a condition | `is_`, `has_`, or `can_` + condition | `is_trusted`, `has_project_marker`, `can_session_read` |
| Returns a value it holds, or derives one from its arguments alone | `get_` | `get_pin_path` |
| Turns text into values | `parse_` | `parse_path_entry` |
| Reads a file, the kernel, or another program's output | `read_` | `read_pin` |
| Prints several items, one per line | `list_` | `list_enabled_agents` |
| Searches and prints matches | `find_` | `find_raw_rule_matches` |
| Computes a value | `calculate_` | `calculate_sha256` |
| Decides a verdict token from its inputs | `evaluate_` | `evaluate_pin` |
| Renders text for a reader | `format_` | `format_age` |
| Resolves a reference or location | `resolve_` | `resolve_agent_entrypoint_path` |
| Keeps state for a later report | `record_` | `record_finding` |
| Performs other work | the verb for that work | `register_fcontext`, `write_pin`, `load_rules` |

A `get_` function reads its arguments and its module's own state alone. One that reaches a file, the kernel or another
program's state, itself or through a function it calls, is a reader: `read_project_build_pattern` reads
the integrations' manifests.

An action keeps its action name even when a caller tests its exit status. `if write_pin …` does not turn `write_pin`
into a predicate.

Spell words in full. Keep these established short terms: `acl`, `dir`, `fcontext`, `fd`, `id`, `jq`, `kv`, `npm`, `nvm`,
`sha256`, `toml`, `tsv`, `tty`, `uid`.

## Exceptions

| Name | Reason |
|---|---|
| `ai_tools_conf__allowlist_<verb>` | `ai-tools.sh` composes the name from the verb an operator typed; the family shares one stem. |
| `ai_tools_log__<level>`, `ai_tools_msg__<class>`, a module's own `_warn` and `_notice` | Emitters are named for the class of message they produce (`info`, `warn`, `headline`), and a module's emitter for one situation adds it: `_ai_tools_toolchain__notice_state_left`. |
| `ai_tools_launch_hook__append_args` | Contract of the `launch.d` seam. Every hook defines it. The wrapper sources only the launching agent's hook, calls it, and execs, so one definition exists per shell. |

## Deferred

Executable globals take the module form `AI_TOOLS_<MODULE>__<NAME>`, with the module derived from the executable's name.
This ensures that a later change which sources a file into an executable does not alter that executable's naming.

Until that change lands, executables may keep unprefixed globals (for example `SANDBOX_ROOT` in `ai-tools.sh`).
The first step of the change settles the executables whose derived name matches a library (`ai-tools-relabel.sh`
and `relabel.lib.sh`). Prefixed executable constants already use the form (`AI_TOOLS_RUN__LIB_DIR`).
