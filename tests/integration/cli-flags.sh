#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/cli-flags.sh
# Every ai-tools command and every option ai-tools(1) documents, asserted by what it ACHIEVES and never by what it
# prints. Each row drives the deployed CLI as the projects user against fixtures it owns and reads one of three
# channels: the root-helper call the CLI made (recorded by the `sudo` shim in tests/lib/cli-stubs.sh, which does not
# elevate the CLI), the registry or filesystem state it left (the fixture allowlist read through the deployed
# conf.lib.sh, a fixture gitconfig, a directory, a branch tip in a fixture remote), or its exit status -- for a refusal,
# paired with an empty call log, which is also the rule that a refused command does not reach sudo first.
#
# No row spells a command: each names a key that tests/lib/cli-spelling.sh turns into today's tokens. The conversion
# to the resource grammar (.claude/rules/cli-grammar.rule.md) edits that table alone, and this file green
# before and after it is the proof that every option still does what it did. The closing check extracts the options
# the man page documents and fails on any without a row here, so the coverage is measured rather than promised.
#
# The CLI keeps the option spelling of each command beside the collection form, so the rows run once per spelling,
# on fresh fixtures, with AI_TOOLS_CLI_SPELLING selecting which one the table fills (`collection`, then `option`;
# the variable set in the environment names the spellings to run instead). Every row asserts the same effect in each
# spelling, which is the proof that a kept spelling runs as the command it spells; one row per spelling asserts
# the notice the option spelling prints, and one drives `-g`, which is an option spelling in either form.
#
# Prompts: every run is under `setsid -w`, so each prompt takes its non-interactive default. A default-NO prompt
# therefore declines, which is what makes `--yes` observable -- the row without it does not record a helper call,
# the row with it records the call. A default-YES prompt proceeds, so a `--yes` on such a command (the clone's create
# confirm) is asserted as accepted, its effect being unobservable without a terminal. One removal verb decides its kind
# from the path, so its rows drive a project in place under ai-tools.projects.remove.inplace and a clone under
# ai-tools.projects.remove.clone.
#
# Trace mode: with AI_TOOLS_CLI_FLAGS_TRACE=<file> the run also RECORDS every outcome, so a diff of two traces reports
# every difference between two builds, including one no row names.  The file opens with a surface digest read
# from the CLI source -- per command key, the option arms its parser accepts and the gating tables that list it, plus
# any dispatch arm no key maps to -- so a command that gained an option, a gate, or a sibling shows without a row
# for it. Every driven row then appends its key-form label, exit status, the full call log, and a digest
# of the registries and the fixture tree (types, modes, paths). Fixture paths and account names are replaced by tokens,
# so the two traces to compare are the one from `develop` and the one from the conversion branch, each recorded
# on the same host after `install.sh` deployed that tree (the rows drive the installed binary; the digest reads
# the checkout when one is present). One trace is written per spelling, at `<file>.collection` and `<file>.option`,
# and each compares with the `develop` trace on its own.
#
# Needs: root (runuser), a provisioned host (the CLI's bootstrap gate), an exec-capable fixture directory (/tmp is
# noexec on a hardened host, so the fixtures fall back beside the projects user's home), and the `nobody` account
# as the enrolled `--for` target.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/cli-spelling.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/cli-stubs.sh"
require_root
# The umask is process state the CLI inherits through runuser (whose PAM stack does not run pam_umask), so this file
# decides it rather than the host: the rows and the trace run under 022, which makes a trace comparable across hosts,
# and the umask independence section re-runs the rows a umask could change under the stricter values a hardened host
# sets. Nothing on the host is changed by it -- a umask is per process and dies with this shell.
umask 022

readonly CLI="/usr/local/bin/ai-tools"
readonly CONF_LIB="/usr/local/lib/ai-tools/conf.lib.sh"
readonly FOR_USER="nobody"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPELLING="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/cli-spelling.sh"
# The CLI source the surface digest and the coverage check read: the checkout when there is one, the installed script
# otherwise (it is a plain bash file).
CLI_SRC="${ROOT}/src/usr/local/bin/ai-tools.sh"; [[ -r "${CLI_SRC}" ]] || CLI_SRC="${CLI}"
TRACE_BASE="${AI_TOOLS_CLI_FLAGS_TRACE:-}"; TRACE=""

section "ai-tools: every command and option, by effect (integration)"

if [[ ! -x "${CLI}" ]]; then skip "cli flags" "not installed at ${CLI}"; finish; exit; fi
# Every gated row would refuse at the CLI's bootstrap gate where the harness's provisioned_agent read fails.
if ! provisioned_agent; then skip_unprovisioned "cli flags"; finish; exit; fi
if [[ ! -r "${CONF_LIB}" ]]; then skip "cli flags" "no ${CONF_LIB} to read registry state with"; finish; exit; fi
if ! command -v runuser >/dev/null 2>&1; then skip "cli flags" "runuser unavailable"; finish; exit; fi
if ! getent passwd "${FOR_USER}" >/dev/null 2>&1; then skip "cli flags" "no ${FOR_USER} account for the --for rows"; finish; exit; fi
if ! getent group "${SANDBOX_GROUP}" >/dev/null 2>&1; then skip "cli flags" "no ${SANDBOX_GROUP} group"; finish; exit; fi
# shellcheck source=../../src/usr/local/lib/ai-tools/conf.lib.sh
source /usr/local/lib/ai-tools/conf.lib.sh

# exec_capable <dir>: succeed when a file created in <dir> can be run from it (the shim and the stubs are executed,
# so /tmp's noexec would fail every row for a reason that is not the CLI's).
exec_capable() {
    local probe="$1/.exec-probe.$$" ok=1
    printf '#!/bin/sh\nexit 0\n' > "${probe}" 2>/dev/null || return 1
    chmod 0700 "${probe}"
    "${probe}" >/dev/null 2>&1 && ok=0
    rm -f "${probe}"
    return "${ok}"
}

# make_fixtures: a fresh testdir and every fixture in it, built once per spelling so no row meets what the other
# spelling's rows left. The names are globals the drivers, the readers and the rows read; mktestdir registers each
# testdir for teardown.
make_fixtures() {
    mktestdir
    R="${TESTDIR}"
    if ! exec_capable "${R}"; then
        mk_fixture_dir R "${PROJECTS_HOME}" cli-flags
    fi
    if ! exec_capable "${R}"; then
        skip "cli flags" "no exec-capable directory for the fixtures (${R})"; finish; exit
    fi
    chmod 0755 "${R}"

    # ── Fixtures ─────────────────────────────────────────────────────────────────────
    FOR_GROUP="$(id -gn "${FOR_USER}")"
    AL="${R}/allowlist"; FOR_AL="${R}/for-allowlist"; GC="${R}/gitconfig"; CONF="${R}/operator.conf"
    SBROOT="${R}/sandbox-projects"
    # Every directory the CLI itself names -- a clone takes its source's basename or `--dir` -- is named
    # by the harness's fixture rule, so a clone that ever lands outside the fixture clone area (an installed CLI
    # ignoring the override) reads as this suite's residue and the sweep finds it. Generated once, so the trace
    # normaliser can replace each with a fixed
    # token.
    N_SRC="$(ai_test_name src)"; N_C2="$(ai_test_name c2)"; N_C3="$(ai_test_name c3)"
    N_C4="$(ai_test_name c4)"; N_C5="$(ai_test_name c5)"
    declare -gA N_CL=([077]="$(ai_test_name clone-077)" [027]="$(ai_test_name clone-027)" [002]="$(ai_test_name clone-002)")
    SRC="${R}/${N_SRC}"
    mk_operator_conf "${CONF}" "${PROJECTS_USER}" "${FOR_USER}"
    printf '%s\n' "${REG_MARKER}" > "${AL}"; printf '%s\n' "${REG_MARKER}" > "${FOR_AL}"; : > "${GC}"
    mkdir -p "${SBROOT}"
    for d in pa pb pc pd pe pf pg psd psu plain unreg parent/p1 parent/p2 hold/inner for1 for2; do
        mkdir -p "${R}/${d}"; printf '# %s\n' "${d}" > "${R}/${d}/README.md"
    done
    mkdir -p "${R}/unreg/node_modules/dep"; : > "${R}/unreg/node_modules/dep/index.js"

    # A source repository with a bare origin, for the clone rows. Signing is off: a host whose git config signs commits
    # would wait on a pinentry the run cannot answer.
    git_q() { git -c user.name=cli-flags -c user.email=cli-flags@example.invalid -c init.defaultBranch=main -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
    git_q init --bare "${R}/remote.git"
    git_q init "${SRC}"
    printf '# src\n' > "${SRC}/README.md"
    git_q -C "${SRC}" add README.md
    git_q -C "${SRC}" commit -m "first"
    git_q -C "${SRC}" branch base2
    git_q -C "${SRC}" commit --allow-empty -m "second on main"
    git_q -C "${SRC}" checkout base2
    git_q -C "${SRC}" commit --allow-empty -m "second on base2"
    git_q -C "${SRC}" checkout main
    git_q -C "${SRC}" remote add origin "${R}/remote.git"
    git_q -C "${SRC}" push origin main base2

    cli_stubs_install "${R}"
    # The `--for` target holds both facts of an operator: OPERATORS (the fixture conf) and ai-ops (the id shim).
    cli_stub_ai_ops "${FOR_USER}"
    # Explicit modes: the suite runs under sudo, and a root umask of 077 would leave every fixture owner-only --
    # readable by the projects user where it owns them, and closed to it where the `--for` target does, which is
    # where the claim's secret scan then fails to enter the tree.
    chmod -R u+rwX,go+rX "${R}"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${R}"
    # The operator.conf fixture stays root's: the gate honours its AI_TOOLS_AGENTS line in a trusted file alone.
    chown root:root "${CONF}"
    # The `--for` target must own the tree a claim for it acts on (the claim's owner rule).
    chown -R "${FOR_USER}:${FOR_GROUP}" "${R}/for1" "${R}/for2"
    # An unregistered tree carrying the ai-tools fingerprint: the sandbox group.
    chgrp -R "${SANDBOX_GROUP}" "${R}/unreg"
}

# ── Drivers and readers ───────────────────────────────────────────────────────────
# run_in <cwd> <args...>: the deployed CLI as the projects user, shim first on PATH, every registry pointed
# at a fixture, under setsid so no prompt can block. Output captured with stderr, or with stderr written to the file
# RUN_STDERR names when it is set; RUN_EXTRA_ENV adds NAME=value pairs to the environment; RUN_CLI runs another copy
# of the CLI in its place.  The inner shell expands $1 and $@ itself, which is why they sit in single quotes.
# With RUN_TTY_ANSWERS set the CLI runs under script(1) instead, on a pseudo-terminal fed that text, for the one
# question no flag pre-answers: confirm reads /dev/tty, which script makes the controlling terminal and holds
# the answers on until they are read (the shape unit/msg.sh drives its menus through). Bounded, since a question
# the answers do not reach would wait on the terminal.
# shellcheck disable=SC2016
RUN_EXTRA_ENV=()
run_in() {
    local cwd="$1"; shift
    local -a command=(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}"
        PATH="${CLI_STUB_PATH}:/usr/local/bin:/usr/bin:/bin"
        AI_TOOLS_OPERATOR_CONF="${CONF}" AI_TOOLS_ALLOWLIST="${AL}" AI_TOOLS_GITCONFIG="${GC}"
        AI_TOOLS_SANDBOX_ROOT="${SBROOT}" "${RUN_EXTRA_ENV[@]}")
    if [[ -n "${RUN_TTY_ANSWERS:-}" ]]; then
        command+=(bash -c 'cd "$1" && exec script -qec "$2" /dev/null' _ "${cwd}" "$(printf '%q ' "${RUN_CLI:-${CLI}}" "$@")")
        printf '%b' "${RUN_TTY_ANSWERS}" | timeout 120 "${command[@]}" 2>&1
        return
    fi
    command+=(bash -c 'cd "$1" && shift && exec setsid -w "$@"' _ "${cwd}" "${RUN_CLI:-${CLI}}" "$@")
    if [[ -n "${RUN_STDERR:-}" ]]; then
        "${command[@]}" 2>"${RUN_STDERR}"
    else
        "${command[@]}" 2>&1
    fi
}
# cli <key> [args...] / cli_in <cwd> <key> [args...]: the command named by its spelling key.  cli_flag_first <key>
# <flag...>: the flags AHEAD of the command, the other order --for accepts.
cli()    { local key="$1"; shift; cli_cmd "${key}" || return 2; run_in "${R}" "${CLI_ARGV[@]}" "$@"; }
# cli_stdout <key> <args...>: cli with stderr kept apart in ${R}/.stderr, so `out` holds stdout alone -- for the rows
# asserting what a command writes to stdout. Every other row reads the two streams merged.
cli_stdout() {
    local key="$1"; shift; cli_cmd "${key}" || return 2
    RUN_STDERR="${R}/.stderr" run_in "${R}" "${CLI_ARGV[@]}" "$@"
}
cli_in() { local cwd="$1" key="$2"; shift 2; cli_cmd "${key}" || return 2; run_in "${cwd}" "${CLI_ARGV[@]}" "$@"; }
# cli_tty <answers> <key> <args...>: cli on a pseudo-terminal, <answers> typed at its questions.
cli_tty() { local answers="$1" key="$2"; shift 2; cli_cmd "${key}" || return 2; RUN_TTY_ANSWERS="${answers}" run_in "${R}" "${CLI_ARGV[@]}" "$@"; }
cli_flag_first() { local key="$1"; shift; cli_cmd "${key}" || return 2; run_in "${R}" "$@" "${CLI_ARGV[@]}"; }
# cli_for_first <key> [args...]: `--for` and the target ahead of the command, the command's own arguments after it.
cli_for_first() { local key="$1"; shift; cli_cmd "${key}" || return 2; run_in "${R}" "$(f for)" "${FOR_USER}" "${CLI_ARGV[@]}" "$@"; }
f() { cli_flag "$1"; }

# seed and seed_for write a registry in the format this release reads: the marker, then one line per argument.
readonly REG_MARKER="# ai-tools-project-registry-format: 1.0"
seed()     { printf '%s\n' "${REG_MARKER}" "$@" > "${AL}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${AL}"; cli_stub_reset; }
seed_for() { printf '%s\n' "${REG_MARKER}" "$@" > "${FOR_AL}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${FOR_AL}"; }
seed_gc()  { : > "${GC}"; local p; for p in "$@"; do git config --file "${GC}" --add safe.directory "${p}"; done; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${GC}"; }
st()       { ai_tools_conf__read_allowlist_state "${AL}" "$1"; }
st_for()   { ai_tools_conf__read_allowlist_state "${FOR_AL}" "$1"; }
gc_has()   { git config --file "${GC}" --get-all safe.directory 2>/dev/null | grep -qxF -- "$1"; }
gc_lacks() { ! gc_has "$1"; }
sha()      { sha256sum "$1" | cut -c1-64; }
# gitr: a git READ made by root on a repository the projects user owns, which git otherwise refuses as dubious
# ownership.
gitr()     { git -c safe.directory='*' "$@"; }
remote_tip() { gitr -C "${R}/remote.git" rev-parse --verify --quiet "refs/heads/$1" 2>/dev/null; }

# expect <desc> <command...>: PASS when the command succeeds; FAIL naming the tail of the last CLI output, which is
# where a refusal or a die() lands.
out=""; rc=0
expect() {
    local desc="$1"; shift
    if "$@"; then pass "${desc}"
    else fail "${desc} (rc=${rc}): $(awk 'NF' <<<"${out}" | tail -n 3 | tr '\n' '~')"
    fi
}

# ── Trace ─────────────────────────────────────────────────────────────────────────
# norm: fixture paths and account names as tokens, so a trace compares across hosts and runs.
norm() {
    sed -e "s#${R}#\$R#g" -e "s#\\b${PROJECTS_USER}\\b#\$OP#g" -e "s#\\b${FOR_USER}\\b#\$FOR#g" \
        -e "s#\\b${PROJECTS_GROUP}\\b#\$OPGRP#g" -e "s#\\b${FOR_GROUP}\\b#\$FORGRP#g" \
        -e "s#\\b${SANDBOX_GROUP}\\b#\$SBGRP#g" \
        -e "s#${N_SRC}#\$SRC#g" -e "s#${N_C2}#\$C2#g" -e "s#${N_C3}#\$C3#g" -e "s#${N_C4}#\$C4#g" \
        -e "s#${N_C5}#\$C5#g" -e "s#${N_CL[077]}#\$CL077#g" -e "s#${N_CL[027]}#\$CL027#g" -e "s#${N_CL[002]}#\$CL002#g"
}
# state_digest: the registries and the fixture tree (type, mode, path), less the shim, the log and git's internals,
# hashed. Commit ids and times are left out, since they differ per run.
state_digest() {
    { norm < "${AL}"; printf -- '--\n'; norm < "${FOR_AL}"; printf -- '--\n'; norm < "${GC}"; printf -- '--\n'
      ( cd "${R}" && find . -mindepth 1 -maxdepth 3 -not -path './stub*' -not -path './sudo-calls.log' \
            -not -path '*.git/*' \( -type d -o -type f \) -printf '%y %m %p\n' | norm | sort ); } \
        | sha256sum | cut -c1-12
}
trace_seq=0
# trace_row <label>: one line per driven row -- the label in key form, the exit status, every helper call recorded
# so far, and the state digest.
trace_row() {
    [[ -n "${TRACE}" ]] || return 0
    trace_seq=$(( trace_seq + 1 ))
    local calls; calls="$(norm < "${CLI_STUB_LOG}" | tr '\t' ' ' | paste -sd ';' -)"
    printf 'row %03d %s rc=%s calls=[%s] state=%s\n' "${trace_seq}" "$(norm <<<"$1")" "${rc}" "${calls}" "$(state_digest)" >> "${TRACE}"
}
# fn_defined <name>: the CLI source defines a function of that name.
fn_defined() { grep -qE "^$1\(\) \{" "${CLI_SRC}"; }
# arm_body <start-regex> <token>: the body of the first `case` arm after <start-regex> whose alternatives include
# <token>, or an empty result. Reads the flat dispatch and a nested `<noun>_dispatch` function alike, which is
# how the two command surfaces this project has are
# shaped.
arm_body() {
    awk -v start="$1" -v tok="$2" '
        $0 ~ start { on=1; next }
        on && /^}/ { exit }
        on && match($0, /^[ \t]*[^)#]*\)/) {
            arms=substr($0, RSTART, RLENGTH); rest=substr($0, RLENGTH+1)
            gsub(/^[ \t]+|\)$/, "", arms); n=split(arms, a, "|")
            for (i=1; i<=n; i++) { gsub(/"/, "", a[i]); if (a[i]==tok) { print rest; exit } }
        }' "${CLI_SRC}"
}
# first_defined_fn <body>: the first identifier in an arm body that the source defines.
first_defined_fn() {
    local w
    while read -r w; do
        if fn_defined "${w}"; then printf '%s' "${w}"; return 0; fi
    done < <(grep -oE '[a-z_]+' <<<"$1")
    return 0
}
# key_function <token...>: the function the dispatch reaches for a command's tokens.
key_function() {
    local fn
    fn="$(first_defined_fn "$(arm_body '^# ── Dispatch' "$1")")"
    if [[ "${fn}" == *_dispatch && -n "${2:-}" ]]; then
        fn="$(first_defined_fn "$(arm_body "^${fn}\\(\\) \\{" "$2")")"
    fi
    printf '%s' "${fn}"
}
# fn_options <function>: the option tokens that function's own parser arms accept, sorted. An alternative is kept only
# in option shape, which drops a heredoc or prose line that happens to end in a parenthesis, and the catch-alls (`-*`,
# `--`, `*`).
fn_options() {
    awk -v fn="$1" '
        $0 ~ ("^" fn "\\(\\) \\{") { on=1; next }
        on && /^}/ { exit }
        on && match($0, /^[ \t]*-[^)#]*\)/) {
            arms=substr($0, RSTART, RLENGTH); gsub(/^[ \t]+|\)$/, "", arms); n=split(arms, a, "|")
            for (i=1; i<=n; i++) if (a[i] ~ /^--?[A-Za-z][A-Za-z-]*(=\*)?$/) print a[i]
        }' "${CLI_SRC}" | sort -u
}
# table_lists <TABLE> <command>: the gating table names the command (one token or a spaced path).
table_lists() {
    sed -n "/^readonly $1=(/,/)/p" "${CLI_SRC}" | tr -d '"' | grep -qwF -- "$2"
}
# trace_surface: the header of a trace -- one line per command key with the options its parser accepts and the gates
# that list it, then the dispatch arms without a key.
trace_surface() {
    [[ -n "${TRACE}" ]] || return 0
    : > "${TRACE}"
    printf '# ai-tools cli-flags trace\n' >> "${TRACE}"
    local key fn opts gates cmd t mapped=""
    while read -r key; do
        # The digest reads the dispatch, which the collection spelling names, whichever spelling the rows run in.
        AI_TOOLS_CLI_SPELLING=collection cli_cmd "${key}" || continue
        cmd="${CLI_ARGV[*]}"; mapped="${mapped} ${CLI_ARGV[0]}"
        fn="$(key_function "${CLI_ARGV[@]}")"
        opts="$( [[ -n "${fn}" ]] && fn_options "${fn}" | paste -sd, - )"
        gates=""
        for t in OPERATOR_VERBS ROOT_ALLOWED_VERBS BOOTSTRAP_EXEMPT_VERBS FOR_ALLOWED_VERBS; do
            table_lists "${t}" "${cmd}" && gates="${gates}${gates:+,}${t%_VERBS}"
        done
        printf 'surface %s options=%s gates=%s\n' "${key}" "${opts:-none}" "${gates:-none}" >> "${TRACE}"
    done < <(sed -n '/^cli_cmd() {/,/^}/p' "${SPELLING}" | grep -oE '^[ \t]+[a-z][a-z.-]*\)' | tr -d ' \t)')
    # Top-level dispatch arms none of whose alternatives is a key's first token; the catch-all that answers an unknown
    # command is not one.
    local unmapped
    unmapped="$(awk '/^# ── Dispatch/ { on=1; next } on && /^esac/ { exit }
                     on && match($0, /^[ \t]*[^)#]*\)/) { a=substr($0, RSTART, RLENGTH); gsub(/^[ \t]+|\)$/, "", a); if (a != "*") print a }' "${CLI_SRC}" \
               | while IFS= read -r arms; do
                     hit=false
                     for t in ${arms//|/ }; do t="${t//\"/}"; [[ " ${mapped} " == *" ${t} "* ]] && hit=true; done
                     ${hit} || printf '%s\n' "${arms}"
                 done | paste -sd' ' -)"
    printf 'surface-unmapped %s\n' "${unmapped:-none}" >> "${TRACE}"
}

# drive <command...>: run one row, keep its output and status, and trace it under a key-form label --
# what `cli`/`cli_in`/`cli_flag_first` were given, which does not carry a spelling.
drive() {
    local label
    case "$1" in
        cli)            label="${*:2}" ;;
        cli_in)         label="in $2: ${*:3}" ;;
        cli_tty)        label="tty ${*:3}" ;;
        cli_flag_first) label="flag-first ${*:2}" ;;
        cli_for_first)  label="for-first ${*:2}" ;;
        cli_stdout)     label="stdout-only ${*:2}" ;;
        *)              label="$*" ;;
    esac
    out="$("$@")" && rc=0 || rc=$?
    trace_row "${label}"
}
rc_is()   { [[ "${rc}" -eq "$1" ]]; }
# The record-stream readers, over a row driven through cli_stdout. out_is_empty: stdout is exactly empty.
# out_is_records: stdout is the header ai-tools-records(5) states, then at least one row, every row eleven tab-separated
# fields with a severity from the page's set. out_has_row <finding>: some row carries <finding>. err_has <text>:
# the stderr the row kept apart holds <text>.
readonly RECORD_HEADER=$'observed-at\toccurred-at\tcode\trecord-id\tseverity\tfinding\tsubject-type\toperator\titem\tsubject\tdetail'
out_is_empty() { [[ -z "${out}" ]]; }
out_is_records() {
    [[ "${out%%$'\n'*}" == "${RECORD_HEADER}" ]] || return 1
    awk -F'\t' 'NR > 1 { rows++; if (NF != 11 || $5 !~ /^(ok|info|attention|unreadable)$/) bad = 1 }
                 END { exit (bad || rows < 1) }' <<< "${out}"
}
out_has_row() { awk -F'\t' -v f="$1" 'NR > 1 && $6 == f { found = 1 } END { exit !found }' <<< "${out}"; }
# out_has_finding_item <finding> <item>: a row with that finding whose item column (the ninth, ai-tools-records(5)) is
# <item>.
out_has_finding_item() {
    awk -F'\t' -v f="$1" -v i="$2" 'NR > 1 && $6 == f && $9 == i { found = 1 } END { exit !found }' <<< "${out}"
}
err_has() { grep -qF -- "$1" "${R}/.stderr"; }
# out_has_text <text>: the row's captured output holds <text>.
out_has_text() { grep -qF -- "$1" <<< "${out}"; }
out_lacks_text() { ! out_has_text "$1"; }
# out_line_has_text <a> <b>: one line of the output carries both texts.
out_line_has_text() { grep -F -- "$1" <<< "${out}" | grep -qF -- "$2"; }
rc_not0() { [[ "${rc}" -ne 0 ]]; }
# quiet_rc <n> / quiet_refusal: the exit status AND an empty call log -- a refusal that did not reach a helper, which is
# the ordering rule that a refused command does not prompt for sudo first.
quiet_rc()      { [[ "${rc}" -eq "$1" ]] && cli_log_empty; }
cli_log_lacks() { ! cli_called "$@"; }
quiet_refusal() { [[ "${rc}" -ne 0 ]] && cli_log_empty; }
# quiet_report <rc>...: a report that RAN and reached no helper. A report closes at one of the statuses
# ai-tools-records(5) gives every report -- 0, 4 with findings, 5 with a reading it could not make -- and which of them
# depends on the host, so the status is one of a set rather than fixed. The set is what separates a report
# from a command that never started, which leaves the same empty call log.
quiet_report()  {
    local allowed
    for allowed in "$@"; do
        [[ "${rc}" -eq "${allowed}" ]] && { cli_log_empty; return; }
    done
    return 1
}
st_is()   { [[ "$(st "$1")" == "$2" ]]; }
st_for_is() { [[ "$(st_for "$1")" == "$2" ]]; }
not_called() { ! cli_called "$1"; }
# before <helper> <ere> <helper> <ere>: both calls recorded, the first ahead of the second.
before() {
    local a b; a="$(cli_call_index "$1" "$2")"; b="$(cli_call_index "$3" "$4")"
    [[ -n "${a}" && -n "${b}" && "${a}" -lt "${b}" ]]
}
T=$'\t'

# drive_rows <spelling>: every row, against the fixtures make_fixtures built, in the spelling cli_cmd is set to.
drive_rows() {
    local spelling="$1"
    trace_surface

    # ── A. Reads, help, and the incident rung ─────────────────────────────────────────
    section "reports, ai-tools.help, ai-tools.version, ai-tools.stop, ai-tools.audit"
    seed "@ ${R}/pa"
    drive cli ai-tools.help;               expect "help exits 0 with no helper call"            rc_is 0
    expect "help reaches no helper" cli_log_empty
    drive run_in "${R}";          expect "the bare invocation exits 0"                  rc_is 0
    # The version is substituted at install from the RPM version-release, which carries a dash, so the row pins
    # the line's shape -- the name and one whitespace-free token -- rather than a version grammar. The token may not
    # open with a dash: the option spelling prints `ai-tools --version` in its notice, which is not the version line.
    drive cli ai-tools.version;            expect "version exits 0 and prints the version line" test "${rc}" -eq 0 -a "$(grep -cE '^ai-tools [^-[:space:]][^[:space:]]*$' <<<"${out}")" -eq 1
    expect "version reaches no helper" cli_log_empty
    drive cli ai-tools.projects.list;      expect "the project listing exits 0"                 rc_is 0
    expect "the listing reaches no helper" cli_log_empty
    # The one row that reads the spelling: an option spelling runs its command with the exit status unchanged and prints
    # the notice naming the preferred form, which the collection spelling does not print.
    if [[ "${spelling}" == option ]]; then
        assert_msg MSG-W3W8 "${out}" "the option spelling runs the listing and notices the preferred form"
    else
        expect "the collection spelling prints no spelling notice" test "$(grep -cxF MSG-W3W8 <<<"${out}")" -eq 0
    fi
    # Both reports are asserted to have RUN as well as to have reached no helper. An empty call log is also what a row
    # whose command never started leaves behind, so on its own it passes for the wrong reason -- which is how a key this
    # table no longer holds reads as a green row. `status` exits 4 to report findings on this host and 5 for a reading
    # it could not make, so the assertion is on the statuses a report can close with.
    drive cli ai-tools.status;    expect "the host report runs and reaches no helper"     quiet_report 0 4 5
    drive cli ai-tools.providers; expect "the provider report runs and reaches no helper" quiet_report 0
    # A report does not take any argument, and one given is refused rather than ignored. The bare `providers` reads
    # a second word as its verb, so its refusal is the unknown-command one in the collection spelling and the parser's
    # in the option spelling; the row asserts the refusal and the empty call log, which the two share.
    drive cli ai-tools.projects.list "${R}/pa"; expect "projects list refuses an argument with exit 2, no helper" quiet_rc 2
    drive cli ai-tools.status "${R}/pa";        expect "status refuses an argument with exit 2, no helper"        quiet_rc 2
    drive cli ai-tools.providers "${R}/pa";     expect "providers refuses an argument, no helper"                 quiet_refusal

    cli_stub_reset
    drive cli ai-tools.stop;               expect "stop calls the stop helper with no argument" test "$(cli_call_count ai-tools-stop)" -eq 1 -a -z "$(cli_calls ai-tools-stop)"
    for k in all dry-run yes yes.short force; do
        cli_stub_reset; drive cli ai-tools.stop "$(f "${k}")"
        expect "stop passes $(f "${k}") through to the helper" cli_called ai-tools-stop "^$(f "${k}")$"
    done
    cli_stub_reset; drive cli ai-tools.stop -n
    expect "stop has no -n short form (it is kept free for a --no)"   quiet_rc 2
    cli_stub_reset; drive cli ai-tools.stop "${R}/pa"
    expect "stop refuses a path with exit 2"                          rc_is 2
    expect "stop's refused path reaches no helper"                    cli_log_empty
    cli_stub_reset; drive cli ai-tools.stop --bogus
    expect "stop refuses an unknown option with exit 2, no helper"    quiet_rc 2

    cli_stub_reset; drive cli ai-tools.audit
    expect "audit calls the audit helper"                             cli_called ai-tools-audit
    cli_stub_reset; drive cli ai-tools.audit "$(f since)" "2 days ago"
    expect "audit passes --since and its value through verbatim"      cli_called ai-tools-audit "^$(f since)${T}2 days ago$"

    # ── B. Claim ─────────────────────────────────────────────────────────────────────
    section "ai-tools.projects.claim"
    seed "@ ${R}/pb"
    drive cli ai-tools.projects.claim "${R}/pa"
    expect "claim without --yes declines at the proceed prompt"       rc_not0
    expect "the declined claim registers nothing"                     st_is "${R}/pa" absent
    expect "the declined claim reaches no helper"                     cli_log_empty

    cli_stub_reset; drive cli ai-tools.projects.claim "$(f yes)" "${R}/pa"
    expect "claim --yes exits 0"                                      rc_is 0
    expect "claim --yes registers the project"                        st_is "${R}/pa" enabled
    expect "claim --yes scans for secrets in the project"             cli_called ai-tools-lockdown "^--gate${T}--${T}"
    expect "claim --yes registers safe.directory"                     cli_called ai-tools-safedir "^${R}/pa$"
    expect "claim --yes sets the group and setgid"                    cli_called ai-tools-setgid "^${R}/pa$"
    expect "claim --yes applies the ACL"                              cli_called ai-tools-setfacl "${R}/pa$"
    expect "a first claim's walk regroups every path"                 cli_log_lacks ai-tools-setfacl "--skip-drifted"
    expect "the safe.directory entry is on record"                    gc_has "${R}/pa"
    expect "the secret scan precedes every access-granting step"     before ai-tools-lockdown "^--gate${T}--${T}" ai-tools-setgid "."

    cli_stub_reset; drive cli ai-tools.projects.claim "$(f yes.short)" "${R}/pc"
    expect "claim -y is the short form of --yes"                      st_is "${R}/pc" enabled

    cli_stub_reset; drive cli_in "${R}/pd" ai-tools.projects.claim "$(f yes)"
    expect "claim without a path is a rejected command line"          rc_is 2
    expect "the pathless claim registers nothing"                     st_is "${R}/pd" absent
    cli_stub_reset; drive cli_in "${R}/pd" ai-tools.projects.claim "$(f yes)" .
    expect "claim . names the current directory"                      st_is "${R}/pd" enabled
    expect "the claim of . names that directory"                      cli_called ai-tools-safedir "^${R}/pd$"

    cli_stub_reset; cli_stub_secrets "${R}/pe/.env"; drive cli ai-tools.projects.claim "$(f yes)" "${R}/pe"
    expect "a found secret is locked down before access is granted"  before ai-tools-lockdown "^--gate${T}--${T}" ai-tools-setgid "."
    expect "the secret gate is one helper call"                       test "$(cli_calls ai-tools-lockdown | wc -l)" = 1
    expect "the claim with a secret still registers the project"     st_is "${R}/pe" enabled
    # A declined lockdown (the helper's exit 6) fails the claim closed: no access granted, the new entry rolled back.
    cli_stub_reset; cli_stub_secrets "${R}/psd/.env"; cli_stub_decline_lockdown
    drive cli ai-tools.projects.claim "$(f yes)" "${R}/psd"
    expect "a declined secret lockdown stops the claim"               rc_not0
    expect "the declined claim grants no access"                      cli_log_lacks ai-tools-setgid
    expect "the declined claim rolls back its allowlist entry"        st_is "${R}/psd" absent
    cli_stub_reset

    # A safe.directory list git cannot read stops the claim ahead of its Review block: an error row and exit 5, with no
    # registry line written and no helper called. The same claim over the readable list is the control.
    local gc_saved; gc_saved="$(cat "${GC}")"
    printf '[safe\n' > "${GC}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${GC}"
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f yes)" "${R}/psu"
    expect "a claim over a safe.directory list git cannot read exits 5" rc_is 5
    expect "that stop is read by its code"                            out_has_text MSG-S3F4
    expect "the stopped claim registers nothing"                      st_is "${R}/psu" absent
    expect "the stopped claim reaches no helper"                      cli_log_empty
    printf '%s\n' "${gc_saved}" > "${GC}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${GC}"
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f yes)" "${R}/psu"
    expect "control: the same claim over the readable list exits 0"   rc_is 0
    expect "control: and registers the project"                       st_is "${R}/psu" enabled
    cli_stub_reset

    drive cli ai-tools.projects.claim --bogus "${R}/pa"
    expect "claim refuses an unknown option with exit 2, no helper"   quiet_rc 2
    cli_stub_reset; drive cli ai-tools.projects.claim "${R}/pa" "${R}/pb"
    expect "claim refuses two paths with exit 2, no helper"           quiet_rc 2

    # `--format tsv`: stdout carries the record stream and no page line. A first claim scans for no drift, so its stream
    # is empty and the page went to stderr.
    cli_stub_reset; drive cli_stdout ai-tools.projects.claim "$(f format)" tsv "$(f yes)" "${R}/pf"
    expect "claim --format tsv exits 0 on a first claim"              rc_is 0
    expect "claim --format tsv registers the project"                 st_is "${R}/pf" enabled
    expect "claim --format tsv writes nothing to stdout on a first claim" out_is_empty
    expect "claim --format tsv writes its page to stderr"             err_has "Claim project"
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f format)" json "${R}/pa"
    expect "claim refuses a --format other than tsv with exit 2"      quiet_rc 2
    cli_stub_reset; drive cli_stdout ai-tools.projects.claim "$(f format)"
    expect "claim refuses --format without a value with exit 2"       quiet_rc 2
    expect "the refused --format writes nothing to stdout"            out_is_empty

    # ── B2. Claim: drift rows and exits ──────────────────────────────────────────────
    # A re-claim over a project already carrying the claim's group, setgid and default ACL, with one file moved in (the
    # projects user's own group, 640): the group scan finds it, no terminal declines the repair, and the per-path check
    # reads it not fixed. The fixture's root is left unlabelled, so the relabel is a pending step the stub applies,
    # and `--yes` answers the proceed prompt.
    section "ai-tools.projects.claim: drift rows and exits"
    claimed_fixture() {  # claimed_fixture <dir>: a project the claim has already applied its group and ACL to
        mkdir -p "$1"; printf '# fixture\n' > "$1/README.md"
        chown -R "${PROJECTS_USER}:${SANDBOX_GROUP}" "$1"
        chmod 2770 "$1"; chmod 0660 "$1/README.md"
        setfacl -m "g:${SANDBOX_GROUP}:rwX" -d -m "g:${SANDBOX_GROUP}:rwX" "$1"
        : > "$1/moved-in.txt"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "$1/moved-in.txt"; chmod 0640 "$1/moved-in.txt"
    }
    claimed_fixture "${R}/ph"
    seed "@ ${R}/ph"; seed_gc "${R}/ph"
    cli_stub_reset; drive cli_stdout ai-tools.projects.claim "$(f format)" tsv "$(f yes)" "${R}/ph"
    expect "a declined group repair exits 4"                          rc_is 4
    expect "the stream is the header and whole rows"                  out_is_records
    expect "the stream carries the file as group-not-fixed"           out_has_row group-not-fixed
    expect "the page went to stderr"                                  err_has "Claim project"
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f yes)" "${R}/ph"
    expect "the same claim on the page exits 4"                       rc_is 4
    # A secret-named path in a drift list is marked, read with the operator's patterns -- here a fixture set
    # through the classifier's own file override -- and a plain path beside it is not.
    printf '*.pem\n' > "${R}/secret-patterns"; chmod 0644 "${R}/secret-patterns"
    : > "${R}/ph/deploy.pem"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/ph/deploy.pem"; chmod 0640 "${R}/ph/deploy.pem"
    RUN_EXTRA_ENV=(AI_TOOLS_SECRET_PATTERNS_FILE="${R}/secret-patterns")
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f yes)" "${R}/ph"
    expect "a secret-named drift path is marked"                      out_has_text "deploy.pem [secret]"
    expect "a plain drift path beside it is not"                      out_lacks_text "moved-in.txt [secret]"
    RUN_EXTRA_ENV=(); rm -f "${R}/ph/deploy.pem"

    # A root step that fails outranks the rows: the safe.directory entry is missing, so its helper runs on every host,
    # and it exits 1; the claim exits 1 with the file still reported not fixed.
    seed_gc
    cli_stub_reset; cli_stub_fail ai-tools-safedir
    drive cli_stdout ai-tools.projects.claim "$(f format)" tsv "$(f yes)" "${R}/ph"
    expect "a failed root step exits 1 over the drift left"           rc_is 1
    expect "the failed claim still writes its rows"                   out_has_row group-not-fixed
    cli_stub_reset; seed_gc "${R}/ph"

    # A declined group repair holds for the walk the claim runs for another step: here the `.git` share, which a run
    # without a terminal accepts by its default. The repository belongs to the projects user, so its git reads it.
    claimed_fixture "${R}/pj"
    git init -q "${R}/pj"; chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/pj/.git"
    seed "@ ${R}/pj"; seed_gc "${R}/pj"
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f yes)" "${R}/pj"
    expect "control: the re-claim lists the moved-in file as group drift" out_has_text "Interior drift: group and ACL"
    expect "the walk the .git share runs leaves the declined drift as it is" \
        cli_called ai-tools-setfacl "^--with-git${T}--skip-drifted${T}${R}/pj$"

    # A worktree's `.git` is a pointer file the walk grants, so one moved in with the projects user's own group is group
    # drift like the moved-in file: listed, and left as it is by the walk when the repair is declined. A file carrying
    # an earlier claim's entries makes the ACL step's walk the one that runs, since a pointer file has no `.git` tree
    # to share. The worktree is a real one, so the owner-side read finds the project its own toplevel.
    git init -q "${R}/pw-main"
    git -C "${R}/pw-main" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
        commit -q --allow-empty -m fixture
    git -C "${R}/pw-main" worktree add -q "${R}/pw"
    claimed_fixture "${R}/pw"; rm -f "${R}/pw/moved-in.txt"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/pw-main"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/pw/.git"; chmod 0640 "${R}/pw/.git"
    : > "${R}/pw/data"; chown "${PROJECTS_USER}:${SANDBOX_GROUP}" "${R}/pw/data"; chmod 0660 "${R}/pw/data"
    setfacl -m "u:${PROJECTS_USER}:rw-,g:${SANDBOX_GROUP}:rw-" "${R}/pw/data"
    seed "@ ${R}/pw"; seed_gc "${R}/pw"
    if [[ -f "${R}/pw/.git" ]]; then
        pass "control: the worktree fixture's .git is a pointer file"
    else
        fail "control: the worktree fixture has no .git pointer file -- the rows below are not evidence"
    fi
    cli_stub_reset; drive cli_stdout ai-tools.projects.claim "$(f format)" tsv "$(f yes)" "${R}/pw"
    expect "the re-claim lists the worktree's .git pointer as group drift" \
        out_line_has_text group-not-fixed "${R}/pw/.git"
    expect "control: the earlier claim's entries make the ACL step's walk run" out_has_row narrow-acl-entries-not-fixed
    expect "the declined repair passes --skip-drifted to that walk"   cli_called ai-tools-setfacl "^--skip-drifted${T}${R}/pw$"

    # A project an earlier release claimed: one file carrying that release's entries, rw- for the operator
    # and the sandbox group. The re-claim lists it as a pending step under the proceed confirm, so a run without
    # a terminal declines before any helper, and `--yes` runs the ACL step's walk, which no other step of this fixture
    # calls for. The stubbed walk does not change the file, so the check after it reads the entries not fixed
    # and the claim exits 4. With the file carrying the walk's own entries the re-claim does not list a file and does
    # not walk.
    claimed_fixture "${R}/pn"; rm -f "${R}/pn/moved-in.txt"
    : > "${R}/pn/data"; chown "${PROJECTS_USER}:${SANDBOX_GROUP}" "${R}/pn/data"; chmod 0660 "${R}/pn/data"
    setfacl -m "u:${PROJECTS_USER}:rw-,g:${SANDBOX_GROUP}:rw-" "${R}/pn/data"
    seed "@ ${R}/pn"; seed_gc "${R}/pn"
    cli_stub_reset; drive cli ai-tools.projects.claim "${R}/pn"
    expect "the re-claim lists the earlier claim's entries"           out_has_text "ACL entries from an earlier claim"
    expect "without --yes and a terminal the entries step declines"   rc_not0
    expect "the declined entries step reaches no helper"              cli_log_empty
    cli_stub_reset; drive cli_stdout ai-tools.projects.claim "$(f format)" tsv "$(f yes)" "${R}/pn"
    expect "--yes runs the ACL step's walk for the listed entries"   cli_called ai-tools-setfacl "${R}/pn$"
    expect "the entries step takes the secret gate"                   before ai-tools-lockdown "^--gate${T}--${T}" ai-tools-setfacl "."
    expect "the stubbed walk leaves the entries, read as not fixed"   out_has_row narrow-acl-entries-not-fixed
    expect "and the claim exits 4"                                    rc_is 4
    setfacl -n -m "u:${PROJECTS_USER}:rwx,g:${SANDBOX_GROUP}:rwx,m::rw-" "${R}/pn/data"
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f yes)" "${R}/pn"
    expect "with the walk's entries the re-claim lists none"          out_lacks_text "ACL entries from an earlier claim"
    expect "and does not walk the tree"                               cli_log_lacks ai-tools-setfacl

    # A walk that fails to read part of the tree: a root-owned 0700 directory, which the projects user lacks search
    # permission on, makes the group walk write to stderr, which the claim reports as an `error` row and exit 5 rather
    # than as a complete scan of a smaller tree.
    claimed_fixture "${R}/pk"
    mkdir -p "${R}/pk/locked"; chown root:root "${R}/pk/locked"; chmod 0700 "${R}/pk/locked"
    seed "@ ${R}/pk"; seed_gc "${R}/pk"
    cli_stub_reset; drive cli_stdout ai-tools.projects.claim "$(f format)" tsv "$(f yes)" "${R}/pk"
    expect "an unreadable directory in the tree exits 5"              rc_is 5
    expect "the unread walk is an error row"                          out_has_row error
    chmod 0755 "${R}/pk/locked"

    # A repository the projects user's git refuses: a `.git` root owns, the shape a `--for` claim reads a target-owned
    # repository in. The core.filemode reading cannot be made, so the claim writes an `error` row whose item names
    # the step and exits 5 rather than reading the step as not applicable.
    claimed_fixture "${R}/pm"; rm -f "${R}/pm/moved-in.txt"
    git init -q "${R}/pm"
    seed "@ ${R}/pm"; seed_gc "${R}/pm"
    cli_stub_reset; drive cli_stdout ai-tools.projects.claim "$(f format)" tsv "$(f yes)" "${R}/pm"
    expect "a repository the operator's git refuses exits 5"          rc_is 5
    expect "the unread core.filemode step is an error row"            out_has_finding_item error filemode
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f yes)" "${R}/pm"
    expect "the page names the command that pins core.filemode"       out_has_text "config core.filemode true"
    # The same reading under a path holding a space: the printed command carries the path as one bash word, so it pastes
    # whole. The entry is quoted, the form the allowlist grammar reads a path with a space in.
    claimed_fixture "${R}/pm space"; rm -f "${R}/pm space/moved-in.txt"
    git init -q "${R}/pm space"
    seed "@ \"${R}/pm space\""; seed_gc "${R}/pm space"
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f yes)" "${R}/pm space"
    expect "control: the claim of the spaced path reads core.filemode as unread" rc_is 5
    expect "the printed command quotes a path with a space"           out_has_text "git -C $(LC_ALL=C printf '%q' "${R}/pm space") config core.filemode true"

    # The unattended relabel: a root carrying the project type, so the label scan runs, with its own type other than
    # the one the policy gives its path, so it is drift. Without a terminal only `--yes` relabels,
    # and AI_TOOLS_ASSUME_YES does not, with or without it.
    claimed_fixture "${R}/pl"; rm -f "${R}/pl/moved-in.txt"
    seed "@ ${R}/pl"; seed_gc "${R}/pl"
    # The fixture's path needs a default label for the dry run to compare against: under /tmp the policy gives none.
    # getenforce and restorecon live in /usr/sbin, which run_in's PATH leaves out, so these rows add it: without it
    # the CLI reads the host as having no SELinux and never runs the label scan.
    if ! command -v restorecon >/dev/null 2>&1 || [[ "$(getenforce 2>/dev/null)" == Disabled ]] \
            || [[ "$(matchpathcon -n "${R}/pl" 2>/dev/null)" != *:*:*:* ]] \
            || ! chcon -t ai_tools_project_t "${R}/pl" 2>/dev/null; then
        skip "ai-tools.projects.claim unattended relabel" \
            "SELinux is disabled, ${R} has no default label, or chcon to ai_tools_project_t failed"
    else
        local sbin_path="${CLI_STUB_PATH}:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin"
        RUN_EXTRA_ENV=(PATH="${sbin_path}")
        cli_stub_reset; drive cli ai-tools.projects.claim "${R}/pl"
        expect "the label scan saw the root's foreign type"           out_has_text "Interior drift: SELinux type"
        expect "no terminal, no --yes: the relabel is not run"        cli_log_lacks ai-tools-relabel
        expect "the unrelabelled root leaves exit 4"                  rc_is 4
        cli_stub_reset; drive cli ai-tools.projects.claim "$(f yes)" "${R}/pl"
        expect "no terminal, --yes: the relabel runs"                 cli_called ai-tools-relabel
        cli_stub_reset; RUN_EXTRA_ENV=(PATH="${sbin_path}" AI_TOOLS_ASSUME_YES=1)
        drive cli ai-tools.projects.claim "${R}/pl"
        expect "AI_TOOLS_ASSUME_YES without --yes: not run"           cli_log_lacks ai-tools-relabel
        expect "AI_TOOLS_ASSUME_YES without --yes still saw the drift" out_has_text "Interior drift: SELinux type"
        cli_stub_reset; drive cli ai-tools.projects.claim "$(f yes)" "${R}/pl"
        expect "AI_TOOLS_ASSUME_YES with --yes: the relabel runs"     cli_called ai-tools-relabel
        # A file on both lists: a foreign type and a foreign group. With the relabel not run, the group question is not
        # asked, since the group change alone would not share the file; with the relabel run it is asked again.
        RUN_EXTRA_ENV=(PATH="${sbin_path}")
        : > "${R}/pl/both.txt"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/pl/both.txt"
        chmod 0640 "${R}/pl/both.txt"; chcon -t user_tmp_t "${R}/pl/both.txt"
        cli_stub_reset; drive cli ai-tools.projects.claim "${R}/pl"
        if [[ "$(getenforce 2>/dev/null)" == Enforcing ]]; then
            expect "relabel not run, enforcing: the group question is not asked" out_has_text "group repair not offered"
        else
            expect "relabel not run, not enforcing: the group question is asked" out_lacks_text "group repair not offered"
        fi
        expect "the drift left on both lists exits 4"                 rc_is 4
        cli_stub_reset; drive cli ai-tools.projects.claim "$(f yes)" "${R}/pl"
        expect "relabel run: the group question is asked"             out_lacks_text "group repair not offered"
        rm -f "${R}/pl/both.txt"
        RUN_EXTRA_ENV=()
    fi
    cli_stub_reset

    # ── B3. Claim: the traverse grant takes the gate ─────────────────────────────────
    # A claimed project under a parent the sandbox account cannot enter has one pending step, the traverse grant,
    # which makes the tree reachable with whatever readable secrets were added since its last scan. So an accepted grant
    # runs the secret scan ahead of the setfacl, and a declined scan leaves the parent as it was. The question is
    # default-NO and no flag answers it, so the accepted answer is typed on a pseudo-terminal; the grant is
    # an unprivileged setfacl, which the sudo shim does not see, so it is read back from the parent. The rows run
    # where the fixture has no other pending step: on a host with SELinux enabled its files would read as label drift,
    # whose question would take the typed answer and, accepted, the gate on its own.
    section "ai-tools.projects.claim: traverse grant"
    reach_fx="${R}/reach"; reach_proj="${reach_fx}/proj"
    claimed_fixture "${reach_proj}"; rm -f "${reach_proj}/moved-in.txt"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${reach_fx}"; chmod 0700 "${reach_fx}"
    reach_why=""
    if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != Disabled ]]; then
        reach_why="SELinux is enabled, so the fixture's files would read as label drift"
    elif ! runuser -u "${SANDBOX_USER}" -- test -x "${R}" 2>/dev/null; then
        reach_why="the sandbox account cannot enter ${R}, so the grant would fall on a directory outside the fixtures"
    elif ! command -v script >/dev/null 2>&1; then
        reach_why="script(1) not available for a pseudo-terminal"
    fi
    if [[ -n "${reach_why}" ]]; then
        skip "claim traverse-grant rows" "${reach_why}"
    else
        granted()     { getfacl -p "${reach_fx}" 2>/dev/null | grep -qE "^user:${SANDBOX_USER}:..x"; }
        not_granted() { ! granted; }
        seed "@ ${reach_proj}"; seed_gc "${reach_proj}"
        cli_stub_reset; drive cli ai-tools.projects.claim "${reach_proj}"
        expect "a claimed project with the grant pending exits 0 with no terminal" rc_is 0
        expect "the declined grant runs no secret scan"                   not_called ai-tools-lockdown
        expect "the declined grant leaves the parent as it was"           not_granted
        cli_stub_reset; drive cli_tty 'y\n' ai-tools.projects.claim "${reach_proj}"
        expect "the accepted grant exits 0"                               rc_is 0
        expect "the accepted grant runs the secret scan"                  cli_called ai-tools-lockdown "^--gate${T}--${T}"
        expect "the accepted grant is applied once the scan passed"       granted
        setfacl -x "u:${SANDBOX_USER}" "${reach_fx}"
        cli_stub_reset; cli_stub_secrets "${reach_proj}/.env"; cli_stub_decline_lockdown
        drive cli_tty 'y\n' ai-tools.projects.claim "${reach_proj}"
        expect "a declined scan stops the claim"                          rc_not0
        expect "a declined scan leaves the parent as it was"              not_granted
        cli_stub_reset
    fi

    # ── C. Create ─────────────────────────────────────────────────────────────────────
    section "ai-tools.projects.create"
    seed "@ ${R}/pa"
    drive cli ai-tools.projects.create
    expect "create without a path is refused"                         rc_not0
    expect "the refused create reaches no helper"                     cli_log_empty
    cli_stub_reset; drive cli ai-tools.projects.create "${R}/new"
    expect "create exits 0"                                           rc_is 0
    expect "create makes the directory"                               test -d "${R}/new"
    expect "create initialises git"                                   test -d "${R}/new/.git"
    expect "create seeds a README"                                    test -f "${R}/new/README.md"
    expect "create registers the project"                             st_is "${R}/new" enabled
    expect "create registers safe.directory"                          cli_called ai-tools-safedir "^${R}/new$"
    expect "create sets the group and setgid"                         cli_called ai-tools-setgid "^${R}/new$"
    expect "create applies the ACL"                                   cli_called ai-tools-setfacl "${R}/new$"
    expect "create skips the secret scan on the tree it just made"   not_called ai-tools-lockdown
    # The `.git` question is asked on a new tree too, default yes: without a terminal the default shares `.git`,
    # and at a pseudo-terminal an `n` keeps it out of the ACL step.
    expect "without a terminal the .git question takes its default, --with-git" cli_called ai-tools-setfacl "^--with-git${T}${R}/new$"
    cli_stub_reset; drive cli_tty 'n\n' ai-tools.projects.create "${R}/new-nogit"
    expect "create at a terminal answered n exits 0"                  rc_is 0
    expect "the ACL step runs without --with-git"                     cli_called ai-tools-setfacl "^${R}/new-nogit$"
    expect "and is not asked for .git"                                cli_log_lacks ai-tools-setfacl "--with-git"
    # A declined share leaves .git as the create set it, which the stubbed helpers do not change: no access for other
    # accounts, the owner's primary group, no group write, and no ACL entry naming the sandbox account or its group --
    # under a 022 umask, under 002 (the default a user-private-group login takes on RHEL and Fedora) and 000, where git
    # builds .git group-writable, under a 077 one, and under a setgid parent in the sandbox group, where git builds .git
    # in that group.
    git_withheld() {  # git_withheld <dir>: .git carries no other bit, the projects group, no sandbox ACL entry
        [[ -z "$(find "$1/.git" -perm /o=rwx -print -quit)" ]] \
            && [[ "$(stat -c %G -- "$1/.git")" == "${PROJECTS_GROUP}" ]] \
            && [[ -z "$(find "$1/.git" ! -group "${PROJECTS_GROUP}" -print -quit)" ]] \
            && ! getfacl -R -p -- "$1/.git" 2>/dev/null | grep -qE "^(default:)?(user:${SANDBOX_USER}|group:${SANDBOX_GROUP}):"
    }
    git_modes_withheld() {  # git_modes_withheld <dir>: directories 2750 or 750, no path with group write or other bits
        [[ -z "$(find "$1/.git" -type d ! -perm 2750 ! -perm 750 -print -quit)" ]] \
            && [[ -z "$(find "$1/.git" -perm /g=w,o=rwx -print -quit)" ]]
    }
    expect "the declined .git is withheld from the agent"            git_withheld "${R}/new-nogit"
    # The file runs under 022 (its header); runuser hands the CLI this shell's umask.
    cli_stub_reset; drive cli_tty 'n\n' ai-tools.projects.create "${R}/new-nogit-022"
    expect "under a 022 umask the declined create exits 0"           rc_is 0
    expect "and its .git is withheld from the agent"                 git_withheld "${R}/new-nogit-022"
    expect "and the mode bits under .git hold no group write or other bits" git_modes_withheld "${R}/new-nogit-022"
    local um
    for um in 002 000 077; do
        umask "${um}"; cli_stub_reset; drive cli_tty 'n\n' ai-tools.projects.create "${R}/new-nogit-${um}"; umask 022
        expect "under a ${um} umask the declined create exits 0"     rc_is 0
        expect "and its .git is withheld from the agent"             git_withheld "${R}/new-nogit-${um}"
        expect "and the mode bits under .git hold no group write or other bits" git_modes_withheld "${R}/new-nogit-${um}"
    done
    expect "and .git stays readable to its group, for a later share" test -z "$(find "${R}/new-nogit-077/.git" ! -perm -g=r -print -quit)"
    # The parent's default ACL also names a third account and a second group, the shape of the clone area's
    # `group:ai-ops` entry: the create strips every extended entry and the default ACL under .git, so the mode bits
    # alone decide who reads it.
    local sg_parent="${R}/sg-parent" third_group
    third_group="$(id -gn nobody)"
    mkdir -p "${sg_parent}"; chown "${PROJECTS_USER}:${SANDBOX_GROUP}" "${sg_parent}"; chmod 2770 "${sg_parent}"
    setfacl -m "d:g:${SANDBOX_GROUP}:rwx,d:u:nobody:rwx,d:g:${third_group}:rwx" "${sg_parent}"
    git_acl_stripped() {  # git_acl_stripped <dir>: no named entry and no default entry under .git
        ! getfacl -R -p -- "$1/.git" 2>/dev/null | grep -qE '^(default:|(user|group):[^:])'
    }
    cli_stub_reset; drive cli_tty 'n\n' ai-tools.projects.create "${sg_parent}/new"
    expect "under a setgid parent in the sandbox group the declined create exits 0" rc_is 0
    expect "control: the new tree takes the parent's group"          test "$(stat -c %G -- "${sg_parent}/new")" = "${SANDBOX_GROUP}"
    expect "control: the new tree inherits the parent's named entries" \
        bash -c 'getfacl -p -- "$1" 2>/dev/null | grep -q "^user:nobody:"' _ "${sg_parent}/new"
    expect "and its .git is withheld from the agent"                 git_withheld "${sg_parent}/new"
    expect "and .git carries no named or default ACL entry"         git_acl_stripped "${sg_parent}/new"
    expect "and the mode bits under .git hold no group write or other bits" git_modes_withheld "${sg_parent}/new"
    # The boundary half, read by the kernel as the sandbox account: it reads the README in the tree it can enter, and
    # is refused the declined .git.
    sandbox_reads() { runuser -u "${SANDBOX_USER}" -- cat -- "$1" >/dev/null 2>&1; }
    sandbox_refused() { ! sandbox_reads "$1"; }
    expect "control: the sandbox account reads the new tree's README" sandbox_reads "${sg_parent}/new/README.md"
    expect "the sandbox account is refused the declined .git"        sandbox_refused "${sg_parent}/new/.git/HEAD"
    rm -rf "${sg_parent}" "${R}"/new-nogit-{022,002,000,077}
    # A claim that stops after the create's mkdir: a failed safe.directory step, which no terminal declines to go
    # past, ends the run 1 with the directory in place, and the run names it and the claim that finishes it.
    cli_stub_reset; cli_stub_fail ai-tools-safedir
    drive cli ai-tools.projects.create "${R}/new-stopped"
    expect "a create whose claim stops after the mkdir exits 1"       rc_is 1
    expect "the directory stays"                                      test -d "${R}/new-stopped"
    expect "the run names the tree it left under its code"            out_has_text MSG-S3U5
    expect "and the claim that finishes it"                           out_has_text "atr projects claim ${R}/new-stopped"
    cli_stub_reset; drive cli ai-tools.projects.create "${R}/new-done"
    expect "control: a create that completes does not name a tree left" out_lacks_text MSG-S3U5
    cli_stub_reset; drive cli ai-tools.projects.create "${R}/pa"
    expect "create refuses an existing path"                          rc_not0
    expect "the refused create reaches no helper"                     cli_log_empty
    cli_stub_reset; drive cli ai-tools.projects.create "${R}/nope/x"
    expect "create refuses a missing parent"                          rc_not0
    expect "create does not manufacture the parent"                   test ! -e "${R}/nope"
    cli_stub_reset; drive cli ai-tools.projects.create "$(f yes)" "${R}/new2"
    expect "create takes no options"                                  rc_not0
    expect "the refused create makes nothing"                         test ! -e "${R}/new2"
    # A registry line the writer cannot write back would fail the claim's registry write after the directory, its
    # repository and its README exist, so the create refuses before the mkdir.
    seed "@ ${R}/pa" "@ ${R}/cq\"q'q"
    expect "the registry holding the unrenderable line validates"     ai_tools_conf__validate_registry "${AL}" current
    drive cli ai-tools.projects.create "${R}/new3"
    expect "create over an unrenderable line exits non-zero"          rc_not0
    expect "that refusal names the line under its code"               out_has_text MSG-A5Y2
    expect "the refused create makes no directory"                    test ! -e "${R}/new3"
    expect "the refused create reaches no helper"                     cli_log_empty

    # ── D. Unclaim ────────────────────────────────────────────────────────────────────
    section "ai-tools.projects.unclaim"
    seed "@ ${R}/pa" "@ ${R}/pb" "@ ${R}/pc" "@ ${R}/pd" "@ ${R}/pg" "@ ${R}/parent/p1" "@ ${R}/parent/p2"
    seed_gc "${R}/pa" "${R}/pb" "${R}/pc" "${R}/pd" "${R}/pg"
    drive cli ai-tools.projects.unclaim "${R}/pa"
    expect "unclaim without --yes declines at the confirm"            rc_not0
    expect "the declined unclaim leaves the entry"                    st_is "${R}/pa" enabled
    expect "the declined unclaim reaches no helper"                   cli_log_empty

    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f yes)" "${R}/pa"
    expect "unclaim --yes hands the tree back to the invoker's group" cli_called ai-tools-unclaim "^${R}/pa${T}${PROJECTS_GROUP}$"
    expect "unclaim --yes drops the entry"                            st_is "${R}/pa" absent
    expect "unclaim --yes drops safe.directory"                       cli_called ai-tools-safedir "^$(printf -- '--remove')${T}${R}/pa$"
    expect "the safe.directory entry is gone"                         gc_lacks "${R}/pa"

    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f yes)" "$(f group)" "${FOR_GROUP}" "${R}/pb"
    expect "unclaim --group names the hand-back group"                cli_called ai-tools-unclaim "^${R}/pb${T}${FOR_GROUP}$"
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f yes)" "$(f group)=${FOR_GROUP}" "${R}/pc"
    expect "unclaim --group=<group> is the same option"               cli_called ai-tools-unclaim "^${R}/pc${T}${FOR_GROUP}$"
    # `-g` is an option spelling in either form: the CLI rewrites it to `--group` wherever it stands and notices.
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f yes)" "$(f group.short)" "${FOR_GROUP}" "${R}/pg"
    expect "unclaim -g names the hand-back group as --group does"     cli_called ai-tools-unclaim "^${R}/pg${T}${FOR_GROUP}$"
    assert_msg MSG-W3W8 "${out}" "unclaim -g notices the preferred form in either spelling"
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f yes)" "$(f full)" "${R}/pd"
    expect "unclaim --full asks the helper for the skipped trees"     cli_called ai-tools-unclaim "^${R}/pd${T}[^${T}]+${T}$(f full)$"

    # A label reversal the live-session gate refused: the hand-back and the registry reversal still apply,
    # and the unclaim ends non-zero without its ✓. The rows run with a getenforce that reports SELinux enforcing,
    # so the CLI reaches the relabel step, and the stubbed helper exits with the gate's status; the same unclaim
    # with the helper succeeding is the control.
    local selinux_on="${R}/selinux-on-bin"
    mkdir -p "${selinux_on}" "${R}/pe"
    printf '#!/bin/sh\necho Enforcing\n' > "${selinux_on}/getenforce"
    chmod 0755 "${selinux_on}" "${selinux_on}/getenforce"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/pe"
    RUN_EXTRA_ENV=(PATH="${selinux_on}:${CLI_STUB_PATH}:/usr/local/bin:/usr/bin:/bin")
    seed "@ ${R}/pe"; drive cli ai-tools.projects.unclaim "$(f yes)" "${R}/pe"
    expect "control: with SELinux on, unclaim reverts the label and exits 0" rc_is 0
    expect "the label reversal reaches the relabel helper"            cli_called ai-tools-relabel "^--remove${T}${R}/pe$"
    seed "@ ${R}/pe"; cli_stub_fail_status ai-tools-relabel 4
    drive cli ai-tools.projects.unclaim "$(f yes)" "${R}/pe"
    expect "an unclaim whose label reversal the gate refused exits non-zero" rc_not0
    expect "that unclaim still hands the tree back"                   cli_called ai-tools-unclaim "^${R}/pe${T}"
    expect "that unclaim still drops the entry"                       st_is "${R}/pe" absent
    RUN_EXTRA_ENV=()

    # A hand-back that did not run leaves the entry disabled rather than dropped, so the unclaim that completes
    # the reversal has a line to resolve the owner through.
    seed "@ ${R}/pa"; cli_stub_fail ai-tools-unclaim
    drive cli ai-tools.projects.unclaim "$(f yes)" "${R}/pa"
    expect "an unclaim whose hand-back failed exits non-zero"         rc_not0
    expect "the hand-back was attempted"                              cli_called ai-tools-unclaim "^${R}/pa${T}"
    expect "that unclaim disables the entry instead of dropping it"   st_is "${R}/pa" disabled

    # No option chooses what becomes of the entry; `--keep-entry` is written as typed, since no key spells it.
    seed "@ ${R}/pa"; drive cli ai-tools.projects.unclaim --keep-entry "${R}/pa"
    expect "unclaim refuses --keep-entry as an unknown option, exit 2, no helper" quiet_rc 2
    expect "the refused unclaim leaves the entry"                     st_is "${R}/pa" enabled
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f dry-run)" "${R}/pa"
    expect "--dry-run without --force is refused"                     rc_not0
    expect "that refusal reaches no helper"                           cli_log_empty
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f force)" "$(f yes)" "${R}/pa"
    expect "--force on a registered project is refused"               rc_not0
    expect "the refused --force reaches no helper"                    cli_log_empty
    expect "the refused --force leaves the entry"                     st_is "${R}/pa" enabled

    cli_stub_reset; drive cli ai-tools.projects.unclaim "${R}/unreg"
    expect "an unregistered tree with residue is reported, not acted on" quiet_rc 0
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f force)" "$(f dry-run)" "${R}/unreg"
    expect "--force --dry-run previews and applies nothing"           quiet_rc 0
    expect "the preview leaves the fingerprint in place"              test "$(stat -c %G "${R}/unreg")" = "${SANDBOX_GROUP}"
    for pair in "dry-run yes" "yes dry-run" "dry-run yes.short"; do
        read -r k1 k2 <<< "${pair}"
        cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f force)" "$(f "${k1}")" "$(f "${k2}")" "${R}/unreg"
        expect "unclaim refuses $(f "${k1}") $(f "${k2}") with exit 2, no helper" quiet_rc 2
    done
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f force)" "${R}/unreg"
    expect "--force without --yes declines at the confirm"            rc_not0
    expect "the declined --force reaches no helper"                   cli_log_empty
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f force)" "$(f yes)" "${R}/unreg"
    expect "--force --yes normalizes the tree through the helper's unlisted mode" cli_called ai-tools-unclaim "^${R}/unreg${T}${PROJECTS_GROUP}${T}--unlisted$"
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f force)" "$(f yes)" "$(f full)" "${R}/unreg"
    expect "--force --full reaches the skip-listed residue too"       cli_called ai-tools-unclaim "^${R}/unreg${T}${PROJECTS_GROUP}${T}--unlisted${T}$(f full)$"
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f force)" "$(f yes)" "${R}/plain"
    expect "--force on a tree with no residue is refused"             rc_not0
    expect "that refusal reaches no helper"                           cli_log_empty

    seed "@ ${R}/parent/p1" "@ ${R}/parent/p2"
    drive cli ai-tools.projects.unclaim "${R}/parent"
    expect "an ancestor unclaim without --yes declines"               rc_not0
    expect "the declined ancestor unclaim reaches no helper"          cli_log_empty
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f yes)" "${R}/parent"
    expect "an ancestor unclaim --yes unclaims every project under it" test "$(cli_call_count ai-tools-unclaim)" -eq 2
    expect "both nested entries are dropped"                          test "$(st "${R}/parent/p1")" = absent -a "$(st "${R}/parent/p2")" = absent
    seed "@ ${R}/hold"; drive cli ai-tools.projects.unclaim "$(f yes)" "${R}/hold/inner"
    expect "a path inside a project is refused"                       rc_not0
    expect "that refusal reaches no helper"                           cli_log_empty
    expect "the enclosing entry is untouched"                         st_is "${R}/hold" enabled

    # ── E. Remove ─────────────────────────────────────────────────────────────────────
    section "ai-tools.projects.remove.inplace"
    mkdir -p "${R}/rm1" "${R}/rm2" "${R}/rm3" "${R}/rm4" "${R}/rmp/nested"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/rm1" "${R}/rm2" "${R}/rm3" "${R}/rm4" "${R}/rmp"
    seed "@ ${R}/rm1" "% ${R}/rm2" "@ ${R}/rm3" "@ ${R}/rm4" "@ ${R}/rmp" "@ ${R}/rmp/nested"
    seed_gc "${R}/rm1" "${R}/rm2"
    drive cli ai-tools.projects.remove.inplace "${R}/rm1"
    expect "remove without --yes declines at the confirm"             rc_not0
    expect "the declined remove leaves the tree"                      test -d "${R}/rm1"
    expect "the declined remove reaches no helper"                    cli_log_empty
    cli_stub_reset; drive cli_in "${R}/rm1" ai-tools.projects.remove.inplace
    expect "remove without a path is a rejected command line"         rc_is 2
    expect "the pathless remove leaves the tree"                      test -d "${R}/rm1"
    expect "the pathless remove reaches no helper"                    cli_log_empty
    cli_stub_reset; drive cli_in "${R}/rm1" ai-tools.projects.remove.inplace "$(f yes)"
    expect "remove --yes without a path is refused"                   rc_is 2
    expect "the refused remove leaves the tree"                       test -d "${R}/rm1"
    cli_stub_reset; drive cli ai-tools.projects.remove.inplace "$(f yes)" "${R}/rm1"
    expect "remove --yes <path> deletes the tree"                     test ! -e "${R}/rm1"
    expect "remove --yes drops the entry"                             st_is "${R}/rm1" absent
    expect "remove --yes drops safe.directory"                        cli_called ai-tools-safedir "^--remove${T}${R}/rm1$"
    expect "remove does not run the filesystem hand-back"             not_called ai-tools-unclaim
    cli_stub_reset; drive cli ai-tools.projects.remove.inplace "$(f yes)" "${R}/rm2"
    expect "a disabled entry authorizes its removal"                  test ! -e "${R}/rm2"
    expect "the disabled line goes with the tree"                     st_is "${R}/rm2" absent
    cli_stub_reset; drive cli ai-tools.projects.remove.inplace "$(f force)" "${R}/rm3"
    expect "remove has no --force"                                    rc_not0
    expect "the refused remove leaves the tree"                       test -d "${R}/rm3"
    expect "that refusal reaches no helper"                           cli_log_empty
    cli_stub_reset; drive cli ai-tools.projects.remove.inplace "$(f yes)" "${R}/plain"
    expect "remove refuses an unregistered path"                      rc_not0
    expect "the unregistered tree stands"                             test -d "${R}/plain"
    cli_stub_reset; drive cli ai-tools.projects.remove.inplace "$(f yes)" "${R}/rmp"
    expect "remove refuses an entry containing another claimed project" rc_not0
    expect "the containing tree stands"                               test -d "${R}/rmp/nested"
    expect "that refusal reaches no helper"                           cli_log_empty
    # The live-session gate's refusal of the label reversal stops the removal before either registry changes, since
    # the helper cannot revert a path the removal deleted. SELinux reported enforcing, as in the unclaim rows.
    RUN_EXTRA_ENV=(PATH="${R}/selinux-on-bin:${CLI_STUB_PATH}:/usr/local/bin:/usr/bin:/bin")
    cli_stub_reset; cli_stub_fail_status ai-tools-relabel 4
    drive cli ai-tools.projects.remove.inplace "$(f yes)" "${R}/rm4"
    expect "a removal whose label reversal the gate refused exits non-zero" rc_not0
    expect "that removal leaves the tree"                             test -d "${R}/rm4"
    expect "that removal leaves the entry"                            st_is "${R}/rm4" enabled
    expect "that removal leaves safe.directory alone"                 not_called ai-tools-safedir
    RUN_EXTRA_ENV=()

    # ── F. Enable and disable ─────────────────────────────────────────────────────────
    section "ai-tools.projects.disable / ai-tools.projects.enable"
    seed "@ ${R}/pa" "@ ${R}/hold" "@ ${R}/hold/inner"
    drive cli ai-tools.projects.disable "${R}/pa"
    expect "disable writes '%' on the entry"                          st_is "${R}/pa" disabled
    expect "disable is a registry edit alone"                         cli_log_empty
    drive cli ai-tools.projects.enable "${R}/pa"
    expect "enable restores the entry"                                st_is "${R}/pa" enabled
    expect "enable is a registry edit alone"                          cli_log_empty
    drive cli ai-tools.projects.disable "${R}/hold/inner"
    expect "disable writes '%' on a project nested in a listed one"   rc_is 0
    expect "the nested entry reads as disabled"                       st_is "${R}/hold/inner" disabled
    expect "the enclosing entry stays listed"                         st_is "${R}/hold" enabled
    drive cli ai-tools.projects.enable "${R}/hold/inner"
    expect "enable lifts the nested '%'"                              st_is "${R}/hold/inner" enabled
    drive cli ai-tools.projects.enable "${R}/plain"
    expect "enable refuses a path with no entry"                      rc_not0
    expect "enable invents no entry"                                  st_is "${R}/plain" absent
    drive cli ai-tools.projects.disable "$(f yes)" "${R}/pa"
    expect "disable takes no options"                                 rc_not0

    # ── G. Acting for another operator ────────────────────────────────────────────────
    section "--for"
    seed "@ ${R}/pa"; seed_for "@ ${R}/for1"
    inv_before="$(sha "${AL}")"
    for order in "lead" "trail"; do
        cli_stub_reset
        if [[ "${order}" == lead ]]; then drive cli_flag_first ai-tools.projects.list "$(f for)" "${FOR_USER}"
        else drive cli ai-tools.projects.list "$(f for)" "${FOR_USER}"; fi
        expect "the listing --for reads the target's registry (${order}ing flag)" cli_called ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--print$"
    done
    expect "--for leaves the invoker's registry byte-identical"       test "$(sha "${AL}")" = "${inv_before}"
    # A `--for` listing's first sudo is the registry reader, so a caller without a grant for it is refused before any
    # sudo prompt; the control is the same listing with the grant, which reaches the snapshot.
    cli_stub_reset; cli_stub_no_grant ai-tools-allowlist
    drive cli ai-tools.projects.list "$(f for)" "${FOR_USER}"
    expect "the listing --for without a grant for the registry reader exits 1 before any helper" quiet_rc 1
    expect "and the refusal is read by its code" out_has_text MSG-R4J2
    cli_stub_reset; drive cli ai-tools.projects.list "$(f for)" "${FOR_USER}"
    expect "control: with the grant, the listing --for reaches the snapshot" cli_called ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--print$"
    # The removal a `--for` listing names for a stale entry edits the target's registry through the helper; an excluded
    # line keeps the sed form, since the helper's removal leaves an excluded line standing, and so does an entry whose
    # `realpath -m` the helper's backstop refuses, though its written path is not protected.
    # An excluded line under a directory the invoker cannot enter is unreadable rather than stale. Only a `--for` run
    # reaches it: the invoker's own gate refuses a file whose exclusion crosses a directory it cannot search, and the
    # `--for` gate reads the snapshot's grammar alone.
    mkdir -p "${R}/for-sealed"; chown root:root "${R}/for-sealed"; chmod 0700 "${R}/for-sealed"
    seed_for "@ ${R}/for1" "@ ${R}/for-gone" "! ${R}/for-excluded-gone" "! ${R}/for-sealed/inner" "@ /etc/for-missing/.."
    cli_stub_reset; drive cli ai-tools.projects.list "$(f for)" "${FOR_USER}"
    expect "a stale entry's removal under --for goes through the helper" out_has_text "ai-tools-allowlist --operator ${FOR_USER} --remove ${R}/for-gone"
    expect "a stale excluded line's removal under --for keeps the sed form" out_has_text "sudo -u ${FOR_USER} sed -i"
    expect "a stale entry the helper's backstop refuses is not given the helper's removal" out_lacks_text "--operator ${FOR_USER} --remove /etc/for-missing/.."
    expect "and keeps the sed form run as the target" out_line_has_text "sudo -u ${FOR_USER} sed -i" "for-missing"
    expect "an excluded line under a directory the invoker cannot enter is reported unreadable" out_has_text "cannot be read as ${PROJECTS_USER}"
    expect "and the target's own listing is named as the one that reads it" out_has_text "${FOR_USER}'s own atr projects reads it"
    seed_for "@ ${R}/for1"
    rmdir "${R}/for-sealed"

    cli_stub_reset; drive cli ai-tools.projects.disable "$(f for)" "${FOR_USER}" "${R}/for1"
    expect "disable --for edits the target's registry through the helper" cli_called ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--disable${T}${R}/for1$"
    expect "the target's entry is disabled"                           st_for_is "${R}/for1" disabled
    cli_stub_reset; drive cli ai-tools.projects.enable "$(f for)" "${FOR_USER}" "${R}/for1"
    expect "enable --for restores the target's entry"                 st_for_is "${R}/for1" enabled
    expect "--for leaves the invoker's registry byte-identical"       test "$(sha "${AL}")" = "${inv_before}"

    # The claim reads the tree as the target, through `sudo -u` (the shim logs it as `runas`). An owner-side read that
    # does not complete ends the claim 5 before any write: an `error` row naming the read, the registry byte-identical,
    # and no helper past the snapshot. The control is the same claim with the read answering.
    local for_sha; for_sha="$(sha "${FOR_AL}")"
    cli_stub_reset; cli_stub_fail runas:ai-tools
    drive cli_stdout ai-tools.projects.claim "$(f for)" "${FOR_USER}" "$(f format)" tsv "$(f yes)" "${R}/for2"
    expect "a --for claim whose owner-side read fails exits 5"        rc_is 5
    expect "its error row names the read as its item"                 out_has_finding_item error inspect
    expect "that row carries the error code"                          out_has_text MSG-Q6X2
    expect "the failed read is noticed under its code"                err_has MSG-X7N2
    expect "the target's registry is byte-identical"                  test "$(sha "${FOR_AL}")" = "${for_sha}"
    expect "no helper is called past the snapshot" test -z "$(awk -F'\t' '$1 != "runas" && !($1 == "ai-tools-allowlist" && $NF == "--print")' "${CLI_STUB_LOG}")"
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f for)" "${FOR_USER}" "$(f yes)" "${R}/for2"
    expect "claim --for asks for the owner-side read as the target"   cli_called runas "^${FOR_USER}${T}${CLI}${T}projects${T}inspect${T}(.*${T})?--${T}${R}/for2$"
    expect "the owner-side read precedes the first helper the claim calls" before runas "${T}projects${T}inspect${T}" ai-tools-allowlist "--add"
    expect "claim --for writes the target's registry"                 cli_called ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--add${T}${R}/for2$"
    expect "the target's registry lists the project"                  st_for_is "${R}/for2" enabled
    expect "claim --for grants access through the helpers"            cli_called ai-tools-setgid "^${R}/for2$"
    expect "--for leaves the invoker's registry byte-identical"       test "$(sha "${AL}")" = "${inv_before}"
    # A project that is a subdirectory of an enclosing repository, with no .git of its own: the claim does not pin
    # core.filemode in that repository, plain or with `--for`. A project with a repository of its own is the control
    # that the pin is written. Each repository starts at core.filemode false, so a pin changes its config; the git calls
    # run as root over root-owned trees before the chown, and the read back is `--file`, as data.
    local encl="${R}/enclosing" encl_sha
    git init -q "${encl}"; git -C "${encl}" config core.filemode false
    git init -q "${encl}/sub-own"; git -C "${encl}/sub-own" config core.filemode false
    mkdir -p "${encl}/sub-plain" "${encl}/sub-for"
    chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${encl}"; chown "${FOR_USER}:${FOR_GROUP}" "${encl}/sub-for"
    encl_sha="$(sha "${encl}/.git/config")"
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f yes)" "${encl}/sub-plain"
    expect "a claim of a subdirectory of an enclosing repository exits 0" rc_is 0
    expect "and leaves the enclosing .git/config byte-identical"     test "$(sha "${encl}/.git/config")" = "${encl_sha}"
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f for)" "${FOR_USER}" "$(f yes)" "${encl}/sub-for"
    expect "claim --for of such a subdirectory exits 0"              rc_is 0
    expect "and leaves the enclosing .git/config byte-identical"     test "$(sha "${encl}/.git/config")" = "${encl_sha}"
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f yes)" "${encl}/sub-own"
    expect "control: a project with its own repository takes the core.filemode pin" \
        test "$(git config --file "${encl}/sub-own/.git/config" --get core.filemode)" = true
    expect "and the enclosing .git/config stays byte-identical"      test "$(sha "${encl}/.git/config")" = "${encl_sha}"
    # The reading a 0700 root refuses one account and allows its owner, made by the owner-side read itself: run as the
    # target over its own tree, and as the projects user over the same tree. Each run does not read a registry or reach
    # a helper, so it is the installed command alone, with a copy of the fixture operator.conf naming both accounts.
    # Both sit in the /tmp testdir, which both accounts traverse: on a host whose /tmp is noexec the other fixtures live
    # beside the projects user's home, which the target cannot enter. Neither needs an exec mount.
    local two="${TESTDIR}/two-account"
    not_as_projects_user() { ! runuser -u "${PROJECTS_USER}" -- "$@"; }
    chmod 0755 "${TESTDIR}"; mkdir -p "${two}"; chmod 0755 "${two}"
    install -m 0644 -o root -g root "${CONF}" "${two}/operator.conf"
    mkdir -p "${two}/closed"; git init -q "${two}/closed"; git -C "${two}/closed" config core.filemode false
    chown -R "${FOR_USER}:${FOR_GROUP}" "${two}/closed"; chmod 0700 "${two}/closed"
    inspect_as() {  # inspect_as <account> <dir> [option...]: the record stream ai-tools.projects.inspect prints as <account>
        local account="$1" dir="$2"; shift 2
        AI_TOOLS_CLI_SPELLING=collection cli_cmd ai-tools.projects.inspect || return 2
        runuser -u "${account}" -- env -i HOME=/ PATH=/usr/local/bin:/usr/bin:/bin \
            AI_TOOLS_OPERATOR_CONF="${two}/operator.conf" "${CLI}" "${CLI_ARGV[@]}" "$@" -- "${dir}" \
            < /dev/null 2> "${two}/stderr.${account}"
    }
    out="$(inspect_as "${FOR_USER}" "${two}/closed")" && rc=0 || rc=$?
    # A failed run names its refusal in the result line, so the reason is on the page.
    [[ "${rc}" -eq 0 ]] || out+=$'\n'"$(tail -n 3 "${two}/stderr.${FOR_USER}" 2>/dev/null)"
    expect "projects inspect as the target reads its 0700 tree's filemode" out_has_text "state${T}filemode${T}false"
    expect "and its .git, which is not normalized"                    out_has_text "state${T}git${T}true"
    expect "and completes the sealed-setgid scan, exit 0" test "${rc}" -eq 0 -a -n "$(grep -xF "scan${T}sealed-setgid${T}complete${T}" <<< "${out}")"
    out="$(inspect_as "${PROJECTS_USER}" "${two}/closed")" && rc=0 || rc=$?
    expect "as the projects user the same tree's filemode reads unknown" out_has_text "state${T}filemode${T}unknown"
    expect "and its .git reads unknown"                               out_has_text "state${T}git${T}unknown"
    expect "and the sealed-setgid scan is not made, exit 0" test "${rc}" -eq 0 -a -n "$(grep -xF "scan${T}sealed-setgid${T}not-made${T}" <<< "${out}")"
    # A drifted file in a tree whose root the sandbox group traverses and the projects user cannot: the drift record
    # carries the owner and mode as the target reads them, the reading the claim's listing prints.
    mkdir -p "${two}/drifted"; : > "${two}/drifted/shared"
    chown -R "${FOR_USER}:${FOR_GROUP}" "${two}/drifted"; chmod 0664 "${two}/drifted/shared"
    chgrp "${SANDBOX_GROUP}" "${two}/drifted"; chmod 2710 "${two}/drifted"
    out="$(inspect_as "${FOR_USER}" "${two}/drifted" --scan-group)" && rc=0 || rc=$?
    [[ "${rc}" -eq 0 ]] || out+=$'\n'"$(tail -n 3 "${two}/stderr.${FOR_USER}" 2>/dev/null)"
    expect "control: the projects user cannot enter that tree"       not_as_projects_user test -x "${two}/drifted"
    expect "projects inspect --scan-group as the target records the drift with the target's reading" \
        out_has_text "group-drift${T}${two}/drifted/shared${T}${FOR_USER}:${FOR_GROUP} 664${T}"
    rm -rf "${two}"
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f for)" "${FOR_USER}" "$(f yes)" "${R}/for2"
    expect "unclaim --for drops the target's entry through the helper" cli_called ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--remove${T}${R}/for2$"
    expect "the target's entry is gone"                               st_for_is "${R}/for2" absent
    # A registry removal the helper refuses ends the verb non-zero with the entry still listed (MSG-K8S2): the unclaim
    # after its hand-back, the remove before its deletion. The marker fails the helper's `--remove` call alone,
    # so the snapshot's `--print` still answers; each case's control is the same command without it.
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f for)" "${FOR_USER}" "$(f yes)" "${R}/for2"
    cli_stub_reset; cli_stub_fail ai-tools-allowlist:--remove
    drive cli ai-tools.projects.unclaim "$(f for)" "${FOR_USER}" "$(f yes)" "${R}/for2"
    expect "unclaim --for exits non-zero when the target's entry cannot be removed" rc_not0
    expect "that refusal carries its code"                            out_has_text MSG-K8S2
    expect "the target's entry is still listed"                       st_for_is "${R}/for2" enabled
    expect "the hand-back ran ahead of the registry step"             cli_called ai-tools-unclaim "^${R}/for2${T}"
    expect "the helper was asked to remove the entry"                 cli_called ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--remove${T}${R}/for2$"
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f for)" "${FOR_USER}" "$(f yes)" "${R}/for2"
    expect "control: the same unclaim --for drops the entry"          st_for_is "${R}/for2" absent
    # The removal's tree belongs to the projects user, since the shim runs the owner's steps as the invoker.
    mkdir -p "${R}/for3"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/for3"
    printf '%s\n' "@ ${R}/for3" >> "${FOR_AL}"
    seed_gc "${R}/for3"
    cli_stub_reset; cli_stub_fail ai-tools-allowlist:--remove
    drive cli ai-tools.projects.remove.inplace "$(f for)" "${FOR_USER}" "$(f yes)" "${R}/for3"
    expect "remove --for exits non-zero when the target's entry cannot be removed" rc_not0
    expect "that refusal carries its code"                            out_has_text MSG-K8S2
    expect "the tree is not deleted past the refused registry step"  test -d "${R}/for3"
    expect "the target's entry is still listed"                       st_for_is "${R}/for3" enabled
    expect "the safe.directory entry is not removed ahead of the refused registry step" not_called ai-tools-safedir
    cli_stub_reset; drive cli ai-tools.projects.remove.inplace "$(f for)" "${FOR_USER}" "$(f yes)" "${R}/for3"
    expect "control: the same remove --for deletes the tree"         test ! -e "${R}/for3"
    expect "control: and drops the target's entry"                    st_for_is "${R}/for3" absent
    expect "control: and its safe.directory entry"                    cli_called ai-tools-safedir "^--remove${T}${R}/for3$"
    # A deletion that leaves paths behind names the target as the account to finish it, with one deletion command,
    # the path in `%q`. A tree the owner cannot write is refused by the pre-flight before the registry step, so
    # the deletion is failed by an `rm` first on the CLI's PATH, matching its arguments as whole words, that refuses
    # the one path its target file names and runs the real `rm` for every other call. The path carries a space and its
    # line is written quoted.
    local rm_stub="${R}/rm-stub-bin"
    mkdir -p "${rm_stub}" "${R}/for 5/keep"; : > "${R}/for 5/keep/held"
    cat > "${rm_stub}/rm" <<EOF
#!/bin/bash
[[ "\$1" == -rf && "\$2" == -- && "\$3" == "\$(< "${rm_stub}/target")" ]] && exit 1
exec $(type -P rm) "\$@"
EOF
    chmod 0755 "${rm_stub}" "${rm_stub}/rm"
    printf '%s' "${R}/for 5" > "${rm_stub}/target"; chmod 0644 "${rm_stub}/target"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/for 5"
    printf '@ "%s"\n' "${R}/for 5" >> "${FOR_AL}"
    seed_gc "${R}/for 5"
    RUN_EXTRA_ENV=(PATH="${rm_stub}:${CLI_STUB_PATH}:/usr/local/bin:/usr/bin:/bin")
    cli_stub_reset; drive cli ai-tools.projects.remove.inplace "$(f for)" "${FOR_USER}" "$(f yes)" "${R}/for 5"
    RUN_EXTRA_ENV=()
    expect "remove --for whose deletion leaves paths behind exits non-zero" rc_not0
    expect "the target's entry was dropped ahead of the deletion"     st_for_is "${R}/for 5" absent
    expect "and its safe.directory entry"                             cli_called ai-tools-safedir "^--remove${T}${R}/for 5$"
    expect "and the entry is gone from the gitconfig"                 gc_lacks "${R}/for 5"
    expect "the paths the deletion left are still there"              test -e "${R}/for 5/keep/held"
    expect "the remedy names the target as the account to run it"     out_has_text "As ${FOR_USER}, run:"
    expect "the remedy is one deletion, the path in %q"               out_has_text "rm -rf $(LC_ALL=C printf '%q' "${R}/for 5")"
    expect "the report does not call the tree out of the agent's reach" out_lacks_text "out of the agent's reach"
    expect "and names no entry it is still under, there being none"   out_lacks_text "still authorizes"
    # The same report states what the label step did. A getenforce reporting SELinux enforcing puts the CLI
    # on the label step on any host; the stubbed relabel helper fails it, and the same removal with the helper
    # succeeding is the control. A failed reversal asks whether to go on, which no terminal declines, so
    # the safe.directory step is skipped and its entry stays. The path carries a space, so the relabel command printed
    # with the failure is the quoted one.
    local label_dir="${R}/lb 1" label_al_saved
    label_al_saved="$(cat "${AL}")"
    mkdir -p "${label_dir}/keep"; : > "${label_dir}/keep/held"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${label_dir}"
    printf '%s' "${label_dir}" > "${rm_stub}/target"
    RUN_EXTRA_ENV=(PATH="${R}/selinux-on-bin:${rm_stub}:${CLI_STUB_PATH}:/usr/local/bin:/usr/bin:/bin")
    seed "@ \"${label_dir}\""; seed_gc "${label_dir}"; cli_stub_fail ai-tools-relabel
    drive cli ai-tools.projects.remove.inplace "$(f yes)" "${label_dir}"
    expect "a removal whose label reversal and deletion both failed exits non-zero" rc_not0
    expect "the label reversal reached the relabel helper"            cli_called ai-tools-relabel "^--remove${T}${label_dir}$"
    expect "the entry was dropped ahead of the deletion"              st_is "${label_dir}" absent
    expect "the paths the deletion left are still there"              test -e "${label_dir}/keep/held"
    expect "the report says the label step did not complete"          out_has_text "SELinux label step did not complete"
    expect "and does not say it completed"                            out_lacks_text "label step completed"
    expect "the relabel command printed with the failure is quoted"   out_has_text "--remove $(LC_ALL=C printf '%q' "${label_dir}")"
    expect "no terminal declines going on, so safe.directory stays"   gc_has "${label_dir}"
    seed "@ \"${label_dir}\""; seed_gc "${label_dir}"
    drive cli ai-tools.projects.remove.inplace "$(f yes)" "${label_dir}"
    expect "control: the relabel succeeding, the removal still exits non-zero" rc_not0
    expect "control: the report says the label step completed"        out_has_text "SELinux label step completed"
    expect "control: and does not say it did not complete"            out_lacks_text "label step did not complete"
    # A project nested in an enabled project: the tree its failed deletion leaves stays launchable under the parent's
    # entry, and the report names that entry. With a disabled or excluded line covering the nested project from
    # an ancestor, the launch gate refuses there whatever entry encloses it, so the report names none.
    mkdir -p "${R}/nest/app/keep"; : > "${R}/nest/app/keep/held"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/nest"
    printf '%s' "${R}/nest/app" > "${rm_stub}/target"
    RUN_EXTRA_ENV=(PATH="${rm_stub}:${CLI_STUB_PATH}:/usr/local/bin:/usr/bin:/bin")
    seed "@ ${R}/nest" "@ ${R}/nest/app"; seed_gc "${R}/nest" "${R}/nest/app"
    drive cli ai-tools.projects.remove.inplace "$(f yes)" "${R}/nest/app"
    expect "a nested removal whose deletion fails exits non-zero"     rc_not0
    expect "the nested project's entry was dropped"                   st_is "${R}/nest/app" absent
    expect "the enclosing project's entry stays"                      st_is "${R}/nest" enabled
    expect "the report names the entry the tree is still under"       out_has_text "the entry for ${R}/nest still authorizes a launch there"
    mkdir -p "${R}/nest/private/app/keep"; : > "${R}/nest/private/app/keep/held"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/nest"
    printf '%s' "${R}/nest/private/app" > "${rm_stub}/target"
    seed "@ ${R}/nest" "! ${R}/nest/private" "@ ${R}/nest/private/app"; seed_gc "${R}/nest" "${R}/nest/private/app"
    drive cli ai-tools.projects.remove.inplace "$(f yes)" "${R}/nest/private/app"
    expect "a removal under an excluded line whose deletion fails exits non-zero" rc_not0
    expect "its entry was dropped"                                    st_is "${R}/nest/private/app" absent
    expect "the report says its own entry no longer authorizes a launch" out_has_text "no longer authorizes a launch there"
    expect "and names no entry that still does, the excluded line refusing it" out_lacks_text "still authorizes"
    mkdir -p "${R}/top/mid/app/keep"; : > "${R}/top/mid/app/keep/held"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/top"
    printf '%s' "${R}/top/mid/app" > "${rm_stub}/target"
    seed "% ${R}/top" "@ ${R}/top/mid" "@ ${R}/top/mid/app"; seed_gc "${R}/top/mid" "${R}/top/mid/app"
    drive cli ai-tools.projects.remove.inplace "$(f yes)" "${R}/top/mid/app"
    expect "a removal under a disabled project whose deletion fails exits non-zero" rc_not0
    expect "its entry was dropped"                                    st_is "${R}/top/mid/app" absent
    expect "the report says its own entry no longer authorizes a launch" out_has_text "no longer authorizes a launch there"
    expect "and names no entry that still does, the disabled line refusing it" out_lacks_text "still authorizes"
    RUN_EXTRA_ENV=()
    printf '%s\n' "${label_al_saved}" > "${AL}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${AL}"; cli_stub_reset
    # A hand-back that did not run disables the target's entry through the helper; a disable the helper refuses then
    # ends the unclaim non-zero with the entry still enabled, after the hand-back was attempted. The control fails
    # the hand-back alone: the entry is disabled, and the unclaim still ends non-zero, its reversal incomplete.
    mkdir -p "${R}/for4"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/for4"
    printf '%s\n' "@ ${R}/for4" >> "${FOR_AL}"
    cli_stub_reset; cli_stub_fail ai-tools-unclaim ai-tools-allowlist:--disable
    drive cli ai-tools.projects.unclaim "$(f for)" "${FOR_USER}" "$(f yes)" "${R}/for4"
    expect "unclaim --for exits non-zero when the disable is refused" rc_not0
    expect "the target's entry is still enabled"                      st_for_is "${R}/for4" enabled
    expect "the hand-back was attempted ahead of the disable"         before ai-tools-unclaim "^${R}/for4${T}" ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--disable${T}${R}/for4$"
    cli_stub_reset; cli_stub_fail ai-tools-unclaim
    drive cli ai-tools.projects.unclaim "$(f for)" "${FOR_USER}" "$(f yes)" "${R}/for4"
    expect "control: the same unclaim disables the target's entry"    st_for_is "${R}/for4" disabled
    expect "control: and exits non-zero, the hand-back not run"       rc_not0

    # A line of the registry the writer cannot write back -- a path carrying both quote characters, which the grammar
    # reads and the formatter does not render -- stops every edit of the file, whatever path the edit names. remove
    # and unclaim refuse before their first change, disable reports the line once its edit fails, and each names it
    # under one code with the registry byte-identical. Each fixture validates first, so the refusal is the edit's.
    local al_saved for_saved ur_sha
    al_saved="$(cat "${AL}")"; for_saved="$(cat "${FOR_AL}")"
    mkdir -p "${R}/ur1" "${R}/ur2" "${R}/fur1"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/ur1" "${R}/ur2" "${R}/fur1"
    seed "@ ${R}/ur1" "@ ${R}/ur2" "@ ${R}/q\"q'q"
    expect "the registry holding the unrenderable line validates"     ai_tools_conf__validate_registry "${AL}" current
    ur_sha="$(sha "${AL}")"
    drive cli ai-tools.projects.remove.inplace "$(f yes)" "${R}/ur1"
    expect "remove over an unrenderable line exits non-zero"          rc_not0
    expect "that refusal names the line under its code"               out_has_text MSG-A5Y2
    expect "the tree stands"                                          test -d "${R}/ur1"
    expect "the registry is byte-identical"                           test "$(sha "${AL}")" = "${ur_sha}"
    expect "the refused remove reaches no helper"                     cli_log_empty
    cli_stub_reset; drive cli ai-tools.projects.disable "${R}/ur1"
    expect "disable over an unrenderable line exits non-zero"         rc_not0
    expect "that refusal names the line under its code"               out_has_text MSG-A5Y2
    expect "the entry is still enabled"                               st_is "${R}/ur1" enabled
    expect "the registry is byte-identical"                           test "$(sha "${AL}")" = "${ur_sha}"
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f yes)" "${R}/ur2"
    expect "unclaim over an unrenderable line exits non-zero"         rc_not0
    expect "that refusal names the line under its code"               out_has_text MSG-A5Y2
    expect "the hand-back does not run"                               not_called ai-tools-unclaim
    expect "the label is not reverted"                                not_called ai-tools-relabel
    expect "the registry is byte-identical"                           test "$(sha "${AL}")" = "${ur_sha}"
    seed_for "@ ${R}/fur1" "@ ${R}/q\"q'q"
    ur_sha="$(sha "${FOR_AL}")"
    cli_stub_reset; drive cli ai-tools.projects.disable "$(f for)" "${FOR_USER}" "${R}/fur1"
    expect "disable --for over an unrenderable line exits non-zero"   rc_not0
    expect "the helper was asked to disable the entry"                cli_called ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--disable${T}${R}/fur1$"
    expect "the CLI names the target's line under its code"           out_has_text MSG-A5Y2
    expect "the target's registry is byte-identical"                  test "$(sha "${FOR_AL}")" = "${ur_sha}"
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f for)" "${FOR_USER}" "$(f yes)" "${R}/fur1"
    expect "unclaim --for over an unrenderable line exits non-zero"   rc_not0
    expect "that refusal names the target's line under its code"      out_has_text MSG-A5Y2
    expect "the hand-back does not run"                               not_called ai-tools-unclaim
    expect "the helper is not asked to edit the target's registry"    cli_log_lacks ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--(remove|disable)"
    expect "the target's registry is byte-identical"                  test "$(sha "${FOR_AL}")" = "${ur_sha}"
    # The verb's own target is the line the writer cannot write back: the removal deletes that line before it renders
    # the rest, so an unclaim or a remove of it runs, and the disable a failed hand-back leaves, which keeps the line,
    # names it.
    local own_q="${R}/q\"q'q" own_r="${R}/r\"r'r"
    mkdir -p "${own_q}" "${own_r}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${own_q}" "${own_r}"
    seed "@ ${R}/ur1" "@ ${own_q}"
    drive cli ai-tools.projects.unclaim "$(f yes)" "${own_q}"
    expect "unclaim of the unrenderable line's own project exits 0"   rc_is 0
    expect "its hand-back runs"                                       cli_called ai-tools-unclaim
    expect "its entry is gone"                                        st_is "${own_q}" absent
    expect "the other entry stays, the file canonical"                test "$(cat "${AL}")" = "$(printf '%s\n' "${REG_MARKER}" "@ ${R}/ur1")"
    seed "@ ${R}/ur1" "@ ${own_q}"
    cli_stub_fail ai-tools-unclaim; drive cli ai-tools.projects.unclaim "$(f yes)" "${own_q}"
    expect "a failed hand-back of that project exits non-zero"        rc_not0
    expect "the disable it leaves names the line under its code"      out_has_text MSG-A5Y2
    expect "the entry is still enabled"                               st_is "${own_q}" enabled
    seed "@ ${R}/ur1" "@ ${own_q}" "@ ${own_r}"
    drive cli ai-tools.projects.unclaim "$(f yes)" "${own_q}"
    expect "another unrenderable line still refuses the unclaim"      rc_not0
    expect "that refusal names the other line"                        out_has_text "@ ${own_r}"
    expect "and the hand-back does not run"                           not_called ai-tools-unclaim
    seed "@ ${R}/ur1" "@ ${own_q}"
    drive cli ai-tools.projects.remove.inplace "$(f yes)" "${own_q}"
    expect "remove of the unrenderable line's own project deletes it" test ! -e "${own_q}"
    expect "and drops its entry"                                      st_is "${own_q}" absent
    mkdir -p "${R}/fq\"q'q"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/fq\"q'q"
    seed_for "@ ${R}/fur1" "@ ${R}/fq\"q'q"
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f for)" "${FOR_USER}" "$(f yes)" "${R}/fq\"q'q"
    expect "unclaim --for of the unrenderable line's own project runs the hand-back" cli_called ai-tools-unclaim
    expect "and asks the helper to remove the entry"                  cli_called ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--remove${T}${R}/fq\"q'q$"
    # A comment's control byte reaches the report as `?`: the grammar accepts one there, and the line may be another
    # operator's.
    seed "@ ${R}/ur1" "@ ${own_r} # note "$'\e'"[2J"
    expect "the registry whose comment carries an escape validates"   ai_tools_conf__validate_registry "${AL}" current
    drive cli ai-tools.projects.remove.inplace "$(f yes)" "${R}/ur1"
    expect "remove over a line whose comment carries an escape is refused" rc_not0
    expect "that refusal is the unrenderable line's"                  out_has_text MSG-A5Y2
    expect "the report shows the comment's escape as ?"               out_has_text "# note ?[2J"
    expect "and prints no escape byte"                                out_lacks_text $'\e'
    rm -rf "${own_r}" "${R}/fq\"q'q"
    printf '%s\n' "${al_saved}" > "${AL}"; printf '%s\n' "${for_saved}" > "${FOR_AL}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${AL}" "${FOR_AL}"

    for key in ai-tools.projects.clone ai-tools.projects.push ai-tools.status ai-tools.stop; do
        cli_stub_reset; drive cli "${key}" "$(f for)" "${FOR_USER}" "${SRC}"
        expect "--for is refused on ${key}"                           rc_not0
        expect "the refused ${key} --for reaches no helper"           cli_log_empty
    done
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f for)" "not-an-operator" "$(f yes)" "${R}/for1"
    expect "--for refuses an unenrolled target"                       rc_not0
    expect "that refusal reaches no helper"                           cli_log_empty
    # A target in OPERATORS and outside ai-ops, the state a name written into operator.conf by hand leaves: the create
    # is refused before the snapshot, so it reaches no helper and makes no directory. The control puts the target back
    # in the group and drives the same create into its own refusal of a missing parent, which also precedes
    # the snapshot.
    cli_stub_ai_ops
    cli_stub_reset; drive cli ai-tools.projects.create "$(f for)" "${FOR_USER}" "${R}/for-new"
    expect "create --for refuses a target outside ai-ops with exit 1" rc_is 1
    expect "that refusal carries its code"                            out_has_text MSG-B9Y4
    expect "that refusal reaches no helper"                           cli_log_empty
    expect "that refusal creates no directory"                        test ! -e "${R}/for-new"
    cli_stub_ai_ops "${FOR_USER}"
    # The snapshot's own refusal, the run's first sudo: the helper fails, and the run stops there having called it once
    # and made no directory.
    cli_stub_reset; cli_stub_fail ai-tools-allowlist
    drive cli ai-tools.projects.create "$(f for)" "${FOR_USER}" "${R}/for-new"
    expect "create --for stops at a snapshot the helper refuses, exit 1" rc_is 1
    expect "that refusal carries its code"                            out_has_text MSG-E8W4
    expect "that run called the helper once"                          test "$(cli_call_count ai-tools-allowlist)" = 1
    expect "that one call is the snapshot"                            cli_called ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--print$"
    expect "that refusal creates no directory"                        test ! -e "${R}/for-new"
    cli_stub_reset; drive cli ai-tools.projects.create "$(f for)" "${FOR_USER}" "${R}/for-none/new"
    expect "control: a target in ai-ops passes the gate to the create's own refusal" out_has_text MSG-J3R8
    expect "control: and that refusal precedes the snapshot"          cli_log_empty
    # The same refusal over the target's snapshot: the run's one helper call is the snapshot, and no directory is made.
    local for_create_saved; for_create_saved="$(cat "${FOR_AL}")"
    seed_for "@ ${R}/fcq\"q'q"
    cli_stub_reset; drive cli ai-tools.projects.create "$(f for)" "${FOR_USER}" "${R}/for-new"
    expect "create --for over an unrenderable line exits non-zero"    rc_not0
    expect "that refusal names the target's line under its code"      out_has_text MSG-A5Y2
    expect "that run called the helper once, for the snapshot"        test "$(cli_call_count ai-tools-allowlist)" = 1
    expect "that refusal creates no directory"                        test ! -e "${R}/for-new"
    printf '%s\n' "${for_create_saved}" > "${FOR_AL}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${FOR_AL}"
    # A `--for` create whose claim stops after the mkdir names the claim with `--for`: the shim makes the directory
    # as the projects user, so the claim's owner rule refuses it once it exists.
    cli_stub_reset; drive cli ai-tools.projects.create "$(f for)" "${FOR_USER}" "${R}/for-made"
    expect "a create --for whose claim stops after the mkdir exits 1" rc_is 1
    expect "the run names the tree it left under its code"            out_has_text MSG-S3U5
    expect "and the claim with --for that finishes it" out_has_text "atr projects claim --for ${FOR_USER} ${R}/for-made"
    rm -rf "${R}/for-made"
    for who in root "${SANDBOX_USER}"; do
        cli_stub_reset; drive cli ai-tools.projects.claim "$(f for)" "${who}" "$(f yes)" "${R}/for1"
        expect "--for refuses ${who}"                                 rc_not0
        expect "that refusal reaches no helper"                       cli_log_empty
    done
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f for)" "${FOR_USER}" "$(f force)" "${R}/unreg"
    expect "--for with --force is refused"                            rc_not0
    expect "that refusal reaches no helper"                           cli_log_empty

    # A command line the verb refuses is refused before the target's registry is read, the run's first sudo, in either
    # order of the flag: each verb FOR_ALLOWED_VERBS names with an unknown option exits 2 with an empty call log, and so
    # do a claim and a remove without a path. A create over a path that exists is refused the same way.
    local for_key
    for for_key in ai-tools.projects.claim ai-tools.projects.create ai-tools.projects.unclaim \
            ai-tools.projects.remove.inplace ai-tools.projects.enable ai-tools.projects.disable \
            ai-tools.projects.lockdown ai-tools.projects.handback ai-tools.projects.list; do
        cli_stub_reset; drive cli "${for_key}" "$(f for)" "${FOR_USER}" --bogus "${R}/for1"
        expect "${for_key} --for refuses an unknown option with exit 2, before the snapshot" quiet_rc 2
        cli_stub_reset; drive cli_for_first "${for_key}" --bogus "${R}/for1"
        expect "${for_key} with --for ahead of it refuses the same, before the snapshot" quiet_rc 2
    done
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f for)" "${FOR_USER}"
    expect "claim --for without a path exits 2 before the snapshot"   quiet_rc 2
    cli_stub_reset; drive cli ai-tools.projects.remove.inplace "$(f for)" "${FOR_USER}" "$(f yes)"
    expect "remove --for without a path exits 2 before the snapshot"  quiet_rc 2
    cli_stub_reset; drive cli ai-tools.projects.create "$(f for)" "${FOR_USER}" "${R}/for1"
    expect "create --for over an existing path is refused before the snapshot" quiet_rc 1
    expect "under its code, naming the claim with --for"              out_has_text MSG-T4B9
    expect "and the claim it names carries --for" out_has_text "atr projects claim --for ${FOR_USER} ${R}/for1"

    # ── H. Clone ──────────────────────────────────────────────────────────────────────
    # The clone rows run only against an installed CLI that honours the clone-area override; an older deployment would
    # put every clone in the real clone area, which the hermeticity contract forbids.
    HAVE_SBROOT=false; grep -q 'AI_TOOLS_SANDBOX_ROOT' "${CLI}" && HAVE_SBROOT=true
    if ! ${HAVE_SBROOT}; then
        section "ai-tools.projects.clone / .push / .remove.clone"
        skip "clone, push and clone-removal rows" "the installed ${CLI} predates the AI_TOOLS_SANDBOX_ROOT override; deploy the checkout first"
    else
    section "ai-tools.projects.clone"
    # The fixture clone area lies outside the static rule that labels the real one ai_tools_project_t, so a relabel
    # there leaves the clone root another type and the clone stops before it opens. The clone rows therefore run
    # with a getenforce that reports SELinux disabled, the state in which the clone does not take a label; the label
    # step is tests/unit/sandbox.sh's.
    local selinux_off="${R}/selinux-off-bin"
    mkdir -p "${selinux_off}"
    printf '#!/bin/sh\necho Disabled\n' > "${selinux_off}/getenforce"
    chmod 0755 "${selinux_off}" "${selinux_off}/getenforce"
    RUN_EXTRA_ENV=(PATH="${selinux_off}:${CLI_STUB_PATH}:/usr/local/bin:/usr/bin:/bin")
    seed
    cli_stub_reset; drive cli ai-tools.projects.clone "${SRC}"
    expect "clone exits 0"                                            rc_is 0
    expect "clone lands under the sandbox area, named after the source" test -d "${SBROOT}/${N_SRC}/.git"
    expect "clone pushes the default branch, sandbox/<base>"          test -n "$(remote_tip sandbox/main)"
    expect "clone registers the clone"                                st_is "${SBROOT}/${N_SRC}" enabled
    expect "clone scans the clone for secrets before opening it"      cli_called ai-tools-lockdown "^--gate${T}--${T}"
    expect "the scan is given the clone's path"                       cli_called ai-tools-lockdown "${T}--${T}${SBROOT}/${N_SRC}$"
    expect "clone registers safe.directory for the clone"             cli_called ai-tools-safedir "^${SBROOT}/${N_SRC}$"
    expect "the clone is shallow"                                     test "$(gitr -C "${SBROOT}/${N_SRC}" rev-list --count HEAD)" -eq 1

    cli_stub_reset; drive cli ai-tools.projects.clone "$(f branch)" "feature/x" "$(f dir)" "${N_C2}" "${SRC}"
    expect "clone --branch names the pushed branch"                   test -n "$(remote_tip feature/x)"
    expect "clone --dir names the clone directory"                    test -d "${SBROOT}/${N_C2}/.git"
    cli_stub_reset; drive cli ai-tools.projects.clone "$(f from)" "base2" "$(f branch)" "sb3" "$(f dir)" "${N_C3}" "${SRC}"
    expect "clone --from forks the branch from that base"             test "$(remote_tip sb3)" = "$(gitr -C "${SRC}" rev-parse base2)"
    cli_stub_reset; drive cli ai-tools.projects.clone "$(f yes)" "$(f dir)" "${N_C4}" "${SRC}"
    expect "clone accepts --yes"                                      test "${rc}" -eq 0 -a -d "${SBROOT}/${N_C4}/.git"
    # The registration follows the push and the clone, so a registry line the writer cannot write back refuses the
    # clone before either.
    local clone_al_saved; clone_al_saved="$(cat "${AL}")"
    printf '%s\n' "@ ${R}/cq\"q'q" >> "${AL}"
    expect "the registry holding the unrenderable line validates"     ai_tools_conf__validate_registry "${AL}" current
    cli_stub_reset; drive cli ai-tools.projects.clone "$(f yes)" "$(f branch)" "sb-unrenderable" "$(f dir)" "unrenderable" "${SRC}"
    expect "clone over an unrenderable line exits non-zero"           rc_not0
    expect "that refusal names the line under its code"               out_has_text MSG-A5Y2
    expect "the refused clone pushes no branch"                       test -z "$(remote_tip sb-unrenderable)"
    expect "the refused clone makes no clone directory"               test ! -e "${SBROOT}/unrenderable"
    printf '%s\n' "${clone_al_saved}" > "${AL}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${AL}"

    cli_stub_reset; drive cli ai-tools.projects.clone "${SBROOT}/${N_C4}"
    expect "clone on an existing clone path resumes its finalization" cli_called ai-tools-lockdown "^--gate${T}--${T}"
    expect "the resume is given that clone's path"                    cli_called ai-tools-lockdown "${T}--${T}${SBROOT}/${N_C4}$"
    expect "the resume makes no second clone"                         test "$(find "${SBROOT}" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 4
    expect "the resumed clone stays registered"                       st_is "${SBROOT}/${N_C4}" enabled
    # A resume on a clone already opened leaves the tree as it is: a directory the operator sealed inside it since keeps
    # its mode, where a normalize re-run over the tree would open it to the group.
    sealed="${SBROOT}/${N_C4}/private"
    mkdir -m 700 "${sealed}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${sealed}"
    cli_stub_reset; drive cli ai-tools.projects.clone "${SBROOT}/${N_C4}"
    expect "a resume on an opened clone keeps a directory sealed inside it at 700" test "$(perm "${sealed}")" = 700

    cli_stub_reset; drive cli ai-tools.projects.clone "${SRC}" "$(f from)"
    expect "clone --from without a value is refused"                  rc_not0
    expect "that refusal reaches no helper"                           cli_log_empty
    cli_stub_reset; drive cli ai-tools.projects.clone "${R}/plain"
    expect "clone refuses a directory that is not a repository"       rc_not0
    expect "that refusal reaches no helper"                           cli_log_empty
    cli_stub_reset; drive cli ai-tools.projects.clone "$(f dir)" "${N_C2}" "${SRC}"
    expect "clone refuses an existing destination"                    rc_not0
    expect "that refusal reaches no helper"                           cli_log_empty
    cli_stub_reset; drive cli ai-tools.projects.clone "$(f from)" "no-such-ref" "$(f dir)" "${N_C5}" "${SRC}"
    expect "clone refuses an unknown base"                            rc_not0
    expect "the refused clone makes no directory"                     test ! -e "${SBROOT}/${N_C5}"
    RUN_EXTRA_ENV=()

    # ── I. Push, and the clone kind's removal ─────────────────────────────────────────
    section "ai-tools.projects.push / ai-tools.projects.remove.clone"
    runuser -u "${PROJECTS_USER}" -- git -C "${SBROOT}/${N_SRC}" -c user.name=cli-flags -c user.email=cli-flags@example.invalid \
        -c commit.gpgsign=false commit --allow-empty -m "sandbox work" >/dev/null 2>&1
    # The verb does not take any option: one is refused with the usage status ahead of the push, since the confirm
    # defaults to yes and a `--dry-run` dropped from the command line would push where the caller asked to look.
    # The unpushed commit stays unpushed, which the first successful push row then reads as its own precondition.
    cli_stub_reset; drive cli ai-tools.projects.push "$(f dry-run)" "${SBROOT}/${N_SRC}"
    expect "push refuses --dry-run with exit 2, no helper"           quiet_rc 2
    expect "the refused push advances no branch"                      test "$(remote_tip sandbox/main)" != "$(gitr -C "${SBROOT}/${N_SRC}" rev-parse HEAD)"
    drive cli ai-tools.projects.push "${SBROOT}/${N_SRC}" "${R}/pa"
    expect "push refuses two paths with exit 2, no helper"            quiet_rc 2
    cli_stub_reset; drive cli ai-tools.projects.push "${SBROOT}/${N_SRC}"
    expect "push exits 0"                                             rc_is 0
    expect "push advances the remote branch to the clone's HEAD"      test "$(remote_tip sandbox/main)" = "$(gitr -C "${SBROOT}/${N_SRC}" rev-parse HEAD)"
    expect "push reaches no helper"                                   cli_log_empty
    drive cli ai-tools.projects.push "${SBROOT}/${N_SRC}"
    expect "push with nothing to push exits 0"                        rc_is 0
    drive cli ai-tools.projects.push "${R}/pa"
    expect "push refuses a path that is not a clone"                  rc_not0
    drive cli_in "${SBROOT}/${N_SRC}" ai-tools.projects.push
    expect "push without a path acts on the clone the current directory is in" rc_is 0

    cli_stub_reset; drive cli ai-tools.projects.remove.clone "${SBROOT}/${N_C2}"
    expect "the clone removal declines with no terminal"              rc_not0
    expect "the declined removal leaves the clone"                    test -d "${SBROOT}/${N_C2}"
    expect "the declined removal leaves the entry"                    st_is "${SBROOT}/${N_C2}" enabled
    cli_stub_reset; drive cli_in "${SBROOT}/${N_C2}" ai-tools.projects.remove.clone "$(f yes)"
    expect "the clone removal --yes without a path is refused"        rc_is 2
    expect "the refused removal leaves the clone"                     test -d "${SBROOT}/${N_C2}"
    cli_stub_reset; drive cli ai-tools.projects.remove.clone "$(f yes)" "${SBROOT}/${N_C2}"
    expect "the clone removal --yes <path> deletes the clone"         test ! -e "${SBROOT}/${N_C2}"
    expect "the clone removal --yes drops the entry"                  st_is "${SBROOT}/${N_C2}" absent
    expect "the clone removal --yes drops safe.directory"             cli_called ai-tools-safedir "^--remove${T}${SBROOT}/${N_C2}$"
    expect "the clone removal runs no typed-name challenge and no hand-back" not_called ai-tools-unclaim
    cli_stub_reset; drive cli ai-tools.projects.remove.clone "$(f yes)" "${R}/pa"
    expect "the clone kind is decided by the path: a project in place takes the registry gate" rc_not0
    expect "that refusal leaves the tree"                             test -d "${R}/pa"
    # A clone the `--for` target holds, the shape a create for that account in the clone area leaves: read with one
    # `stat` as the target, accepted on its root's owner, deleted, and its entry dropped from the target's registry
    # through the helper. The shim runs the owner's commands as the projects user, so the fixture is opened to it.
    # The clone's safe.directory entry is added beside the ones the file holds, since the removal drops only an entry it
    # finds listed.
    local for_clone="${SBROOT}/for-clone" for_clone_saved
    for_clone_saved="$(cat "${FOR_AL}")"
    mkdir -p "${for_clone}/.git"; : > "${for_clone}/.git/HEAD"
    chown -R "${FOR_USER}:${FOR_GROUP}" "${for_clone}"; chmod -R a+rwX "${for_clone}"
    seed_for "@ ${for_clone}"
    git config --file "${GC}" --add safe.directory "${for_clone}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${GC}"
    expect "control: the clone's safe.directory entry is listed"     gc_has "${for_clone}"
    # A path nested under a clone is refused by the path check, ahead of the snapshot that is a `--for` run's first
    # sudo.
    cli_stub_reset; drive cli ai-tools.projects.remove.clone "$(f for)" "${FOR_USER}" "$(f yes)" "${for_clone}/.git"
    expect "remove --for of a path nested in the clone area is refused"   rc_not0
    expect "that refusal is the one-level path check"                 out_has_text MSG-W3H3
    expect "and comes ahead of the registry snapshot"                 not_called ai-tools-allowlist
    expect "and leaves the clone"                                     test -d "${for_clone}/.git"
    cli_stub_reset; drive cli ai-tools.projects.remove.clone "$(f for)" "${FOR_USER}" "$(f yes)" "${for_clone}"
    expect "remove --for of a clone the target holds exits 0"         rc_is 0
    expect "the clone is read with one stat as the target"            cli_called runas "^${FOR_USER}${T}stat${T}"
    expect "and is deleted"                                           test ! -e "${for_clone}"
    expect "its entry is dropped through the helper" \
        cli_called ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--remove${T}${for_clone}$"
    expect "and its safe.directory entry is dropped"                  cli_called ai-tools-safedir "^--remove${T}${for_clone}$"
    rm -rf "${for_clone}"
    printf '%s\n' "${for_clone_saved}" > "${FOR_AL}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${FOR_AL}"
    # A clone removal whose deletion fails reports the entry the clone had and the one that still covers it, read
    # from the registry record ahead of the registry step. The `rm` stub of the `--for` group fails the clone's path;
    # an enabled entry over the clone area is the covering one, and a clone no line names had no entry of its own, since
    # a clone is removed on its place, its owner and its shape.
    local clone_al_saved; clone_al_saved="$(cat "${AL}")"
    printf '%s' "${SBROOT}/${N_SRC}" > "${rm_stub}/target"
    RUN_EXTRA_ENV=(PATH="${rm_stub}:${CLI_STUB_PATH}:/usr/local/bin:/usr/bin:/bin")
    seed "@ ${SBROOT}" "@ ${SBROOT}/${N_SRC}"; seed_gc "${SBROOT}/${N_SRC}"
    drive cli ai-tools.projects.remove.clone "$(f yes)" "${SBROOT}/${N_SRC}"
    expect "a clone removal whose deletion fails exits non-zero"      rc_not0
    expect "the clone is left on disk"                                test -d "${SBROOT}/${N_SRC}"
    expect "its entry was dropped ahead of the deletion"              st_is "${SBROOT}/${N_SRC}" absent
    expect "the report says the clone's own entry is removed"         out_has_text "clone's own registry entry is removed"
    expect "and names the entry over the clone area that still covers it" out_has_text "the entry for ${SBROOT} still authorizes a launch there"
    seed "@ ${R}/pa"; seed_gc "${SBROOT}/${N_SRC}"
    drive cli ai-tools.projects.remove.clone "$(f yes)" "${SBROOT}/${N_SRC}"
    expect "a removal of a clone no line names, its deletion failing, exits non-zero" rc_not0
    expect "the report says the clone had no entry of its own"        out_has_text "clone had no registry entry of its own"
    expect "and does not say an entry of its own was removed"         out_lacks_text "own registry entry is removed"
    expect "and names no entry that covers it, there being none"      out_lacks_text "still authorizes"
    RUN_EXTRA_ENV=()
    printf '%s\n' "${clone_al_saved}" > "${AL}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${AL}"; cli_stub_reset
    rm -rf "${SBROOT:?}/${N_SRC}"
    fi

    # ── J. Lockdown and reclaim ───────────────────────────────────────────────────────
    section "ai-tools.projects.lockdown / ai-tools.projects.handback"
    seed "@ ${R}/pa"
    cli_stub_reset; drive cli ai-tools.projects.lockdown "${R}/pa"
    expect "lockdown gives the helper the project's path"             cli_called ai-tools-lockdown "^--${T}${R}/pa$"
    expect "lockdown passes no flag by default"                       test "$(cli_calls ai-tools-lockdown)" = "--${T}${R}/pa"
    cli_stub_reset; cli_stub_secrets "${R}/pa/.env"; cli_stub_decline_lockdown
    drive cli ai-tools.projects.lockdown "${R}/pa"
    expect "a declined lockdown exits 6, the decline code"            rc_is 6
    cli_stub_reset
    for k in dry-run yes yes.short; do
        cli_stub_reset; drive cli ai-tools.projects.lockdown "$(f "${k}")" "${R}/pa"
        expect "lockdown passes $(f "${k}") through to the helper"     cli_called ai-tools-lockdown "^$(f "${k}")${T}--${T}${R}/pa$"
    done
    cli_stub_reset; drive cli ai-tools.projects.lockdown -n "${R}/pa"
    expect "lockdown has no -n short form, no helper"                 quiet_refusal
    for pair in "dry-run yes" "yes dry-run" "dry-run yes.short"; do
        read -r k1 k2 <<< "${pair}"
        cli_stub_reset; drive cli ai-tools.projects.lockdown "$(f "${k1}")" "$(f "${k2}")" "${R}/pa"
        expect "lockdown refuses $(f "${k1}") $(f "${k2}") with exit 2, no helper" quiet_rc 2
    done
    cli_stub_reset; drive cli ai-tools.projects.unclaim "$(f force)" -n "${R}/unreg"
    expect "unclaim has no -n short form, no helper"                  quiet_refusal
    guard="${R}/pa/CLAUDE.md"
    printf '<!-- ai-tools-lockdown-guard -->\n# guard\n' > "${guard}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${guard}"
    cli_stub_reset; drive cli ai-tools.projects.lockdown "$(f dry-run)" "${R}/pa"
    expect "a dry-run lockdown leaves the guard file"                 test -f "${guard}"
    cli_stub_reset; drive cli ai-tools.projects.lockdown "${R}/pa"
    expect "a completed lockdown clears the guard file"               test ! -e "${guard}"
    cli_stub_reset; drive cli ai-tools.projects.lockdown "${R}/plain"
    expect "lockdown refuses a path outside every project"            rc_not0
    expect "that refusal reaches no helper"                           cli_log_empty
    cli_stub_reset; drive cli ai-tools.projects.lockdown --bogus "${R}/pa"
    expect "lockdown refuses an unknown option with exit 2, no helper" quiet_rc 2

    cli_stub_reset; drive cli ai-tools.projects.handback "${R}/pa"
    expect "reclaim hands the project to the reclaim helper"          cli_called ai-tools-reclaim "^${R}/pa$"
    cli_stub_reset; drive cli ai-tools.projects.handback "$(f full)" "${R}/pa"
    expect "reclaim --full asks the helper for the skipped trees"     cli_called ai-tools-reclaim "^$(f full)${T}${R}/pa$"
    cli_stub_reset; drive cli_in "${R}/pa" ai-tools.projects.handback
    expect "reclaim without a path acts on the project the current directory is in" cli_called ai-tools-reclaim "^${R}/pa$"
    cli_stub_reset; drive cli ai-tools.projects.handback "${R}/plain"
    expect "reclaim refuses a path outside every project"             rc_not0
    expect "that refusal reaches no helper"                           cli_log_empty
    cli_stub_reset; drive cli ai-tools.projects.handback --bogus "${R}/pa"
    expect "reclaim refuses an unknown option with exit 2, no helper"  quiet_rc 2

    # ── L. The operator's umask does not decide what the agent can read ──────────────
    # A create sets its modes outright and a clone is created private and then opened, so neither depends on the umask
    # the operator's shell carries. Both are re-driven under the values a hardened host sets and held to the modes
    # ai-tools(1) states. Restored afterwards, so the coverage check and the teardown run under the pinned 022.
    section "help requests"
    # help_printed: the row exited 0 with one `Usage:` line on stdout and called no helper.
    help_printed() { [[ "${rc}" -eq 0 && "$(grep -c '^Usage:$' <<<"${out}")" -eq 1 ]] && cli_log_empty; }
    # A help request prints the help on stdout, exits 0 and does not call a helper, wherever its flag stands; the rows
    # of each command's own section are the control that the same command without the flag reaches the recorder.
    for key in ai-tools.projects.list ai-tools.projects.create ai-tools.projects.claim ai-tools.projects.unclaim \
            ai-tools.projects.remove.inplace ai-tools.projects.disable ai-tools.projects.enable \
            ai-tools.projects.clone ai-tools.projects.push ai-tools.projects.lockdown ai-tools.projects.handback \
            ai-tools.providers ai-tools.status ai-tools.audit ai-tools.stop; do
        argument=("${R}/pa")
        case "${key}" in ai-tools.projects.list|ai-tools.providers|ai-tools.status|ai-tools.audit|ai-tools.stop) argument=() ;; esac
        for flag in --help -h; do
            cli_stub_reset; drive cli_stdout "${key}" "${argument[@]}" "${flag}"
            expect "${key} ${flag} prints its help and calls no helper" help_printed
        done
    done
    for key in ai-tools.projects.help ai-tools.providers.help; do
        cli_stub_reset; drive cli_stdout "${key}"
        expect "${key} prints the help and calls no helper" help_printed
    done
    # A `--for` run's help request exits ahead of the snapshot, the run's first sudo, and a help flag in `--for`'s value
    # slot is the help request itself; another option there stays the refusal.
    cli_stub_reset; drive cli_stdout ai-tools.projects.claim . --help "$(f for)" "${FOR_USER}"
    expect "a --for run's help request prints and reaches no helper" help_printed
    cli_stub_reset; drive cli_stdout ai-tools.projects.claim "$(f for)" --help
    expect "a help flag as --for's value is the help request" help_printed
    cli_stub_reset; drive cli_flag_first ai-tools.projects.claim "$(f for)" -h
    expect "-h as --for's value ahead of the command is the help request" quiet_rc 0
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f for)" -x
    expect "another option as --for's value stays refused, with no helper" quiet_rc 1
    assert_msg MSG-B4G2 "${out}" "another option as --for's value is the --for refusal"
    # A help flag ahead of an invalid or a missing `--for` value is the help request; behind `--` it is an argument,
    # and the refusal stands.
    cli_stub_reset; drive cli ai-tools.projects.claim --help "$(f for)" -x
    expect "a help flag ahead of an invalid --for value is the help request" help_printed
    cli_stub_reset; drive cli ai-tools.projects.claim --help "$(f for)"
    expect "a help flag ahead of a missing --for value is the help request" help_printed
    cli_stub_reset; drive cli ai-tools.projects.claim "$(f for)" -- --help
    expect "-- as --for's value is not a value, and a help flag behind it leaves the refusal" quiet_rc 1
    assert_msg MSG-B4G2 "${out}" "-- as --for's value is the --for refusal"
    cli_stub_reset; drive cli ai-tools.projects.claim --help "$(f for)" --
    expect "a help flag ahead of --for and a -- after it is the help request" help_printed
    # `--version` in the first slot is the version whatever help flag follows; a `--for` beside it is checked
    # as anywhere.
    cli_stub_reset; drive cli ai-tools.version --help
    expect "--version --help prints the version line" \
        test "${rc}" -eq 0 -a "$(grep -cE '^ai-tools [^-[:space:]][^[:space:]]*$' <<<"${out}")" -eq 1
    cli_stub_reset; drive cli ai-tools.version "$(f for)" -x
    expect "--version beside an invalid --for value is the --for refusal, with no helper" quiet_rc 1
    assert_msg MSG-B4G2 "${out}" "--version beside an invalid --for value is the --for refusal"
    cli_stub_reset; drive cli ai-tools.projects.claim -- --help "$(f for)" -x
    expect "a help flag behind -- leaves an invalid --for value refused, with no helper" quiet_rc 1
    assert_msg MSG-B4G2 "${out}" "a help flag behind -- leaves the --for refusal"
    # The incident rung runs without help.lib.sh: a copy of the deployed CLI whose library path names an absent file
    # still reaches the stop helper for a stop with no help flag, and refuses every other line at exit 3 with no helper.
    nohelp_cli="${CLI_STUB_PATH}/ai-tools-nohelp"
    sed "s#^readonly HELP_LIB=.*#readonly HELP_LIB=${CLI_STUB_PATH}/absent-help.lib.sh#" "${CLI}" > "${nohelp_cli}"
    chmod 0755 "${nohelp_cli}"
    if ! grep -qF "readonly HELP_LIB=${CLI_STUB_PATH}/absent-help.lib.sh" "${nohelp_cli}"; then
        fail "the copy of the CLI does not carry the rewritten help library path, so its rows prove nothing"
    else
        cli_stub_reset; RUN_CLI="${nohelp_cli}" drive cli ai-tools.stop "$(f dry-run)"
        expect "without help.lib.sh, stop --dry-run reaches the stop helper" cli_called ai-tools-stop "^$(f dry-run)$"
        cli_stub_reset; RUN_CLI="${nohelp_cli}" drive cli ai-tools.projects.list
        expect "without help.lib.sh, the listing refuses at exit 3 with no helper" quiet_rc 3
        cli_stub_reset; RUN_CLI="${nohelp_cli}" drive cli ai-tools.stop --help
        expect "without help.lib.sh, stop --help refuses at exit 3 with no helper" quiet_rc 3
    fi
    # A help request on an unknown path is the unknown-command refusal, exit 2, with no helper.
    cli_stub_reset; drive run_in "${R}" projects bogus --help
    expect "a help request on an unknown path is refused with exit 2 and no helper" quiet_rc 2
    assert_msg MSG-S2H5 "${out}" "a help request on an unknown path is the unknown-command refusal"

    section "umask independence"
    has_bits() { (( ( 8#$(stat -c '%a' "$1") & 8#$2 ) == 8#$2 )); }
    for u in 077 027 002; do
        umask "${u}"
        seed; drive cli ai-tools.projects.create "${R}/new-${u}"
        expect "create under umask ${u} exits 0"                        rc_is 0
        expect "create under umask ${u}: the directory is 750"          test "$(perm "${R}/new-${u}")" = 750
        expect "create under umask ${u}: the README is 640"             test "$(perm "${R}/new-${u}/README.md")" = 640
        expect "create under umask ${u}: .git is group r-x"             has_bits "${R}/new-${u}/.git" 050
        expect "create under umask ${u}: .git holds no group write or other bits" \
            test -z "$(find "${R}/new-${u}/.git" -perm /g=w,o=rwx -print -quit)"
        if ${HAVE_SBROOT}; then
            RUN_EXTRA_ENV=(PATH="${R}/selinux-off-bin:${CLI_STUB_PATH}:/usr/local/bin:/usr/bin:/bin")
            seed; drive cli ai-tools.projects.clone "$(f dir)" "${N_CL[${u}]}" "${SRC}"
            RUN_EXTRA_ENV=()
            expect "clone under umask ${u} exits 0"                     rc_is 0
            expect "clone under umask ${u}: the clone root is 770"      test "$(perm "${SBROOT}/${N_CL[${u}]}")" = 770
            expect "clone under umask ${u}: the clone root is setgid"   has_bits "${SBROOT}/${N_CL[${u}]}" 2000
            expect "clone under umask ${u}: a checked-out file is 660"  test "$(perm "${SBROOT}/${N_CL[${u}]}/README.md")" = 660
        fi
    done
    umask 022
}

# ── Both spellings ────────────────────────────────────────────────────────────────
# Fresh fixtures and every row once per spelling. The harness counters accumulate across the passes, and the trace
# of each pass is its own file, so a spelling's outcomes compare with the `develop` trace on their own.
read -ra spellings <<<"${AI_TOOLS_CLI_SPELLING:-collection option}"
for spelling in "${spellings[@]}"; do
    section "spelling: ${spelling}"
    AI_TOOLS_CLI_SPELLING="${spelling}"
    TRACE="${TRACE_BASE:+${TRACE_BASE}.${spelling}}"; trace_seq=0
    make_fixtures
    drive_rows "${spelling}"
done
AI_TOOLS_CLI_SPELLING=collection

# ── K. Coverage: every documented option has a row here ──────────────────────────
section "coverage against ai-tools(1)"
MAN="${ROOT}/src/usr/local/share/man/man1/ai-tools.1"
if [[ ! -r "${MAN}" ]]; then
    MAN="/usr/local/share/man/man1/ai-tools.1"; [[ -r "${MAN}" ]] || MAN="/usr/local/share/man/man1/ai-tools.1.gz"
fi
if [[ ! -r "${MAN}" ]]; then
    skip "coverage" "no ai-tools(1) source or installed page"
else
    read_man() { case "$1" in *.gz) zcat "$1" ;; *) cat "$1" ;; esac | sed 's/\\-/-/g'; }
    man_section() { read_man "$1" | awk -v s=".SH $2" '$0==s{f=1;next} /^\.SH /{f=0} f'; }
    # Options are the long tokens on the OPTIONS headings plus the ones on COMMANDS headings at any depth, less the two
    # options answered as commands, which the command keys `help` and `version` drive.
    documented="$( { man_section "${MAN}" OPTIONS | grep -E '^\.(B|BR|BI) ' | grep -oE -- '--[a-z][a-z-]+';
                     man_section "${MAN}" COMMANDS | awk '
                        /^\.RS/{d++; next} /^\.RE/{if (d>0) d--; next} /^\.TP/{want=1; next}
                        want && /^\.(B|BR|BI) /{ line=$0
                            while (match(line, /--[a-z][a-z-]+/)) {
                                print substr(line, RSTART, RLENGTH); line=substr(line, RSTART+RLENGTH) }
                            want=0 }'; } | sort -u \
                   | comm -23 - <(printf '%s\n' "$(cli_cmd_text ai-tools.help)" "$(cli_cmd_text ai-tools.version)" | sort -u))"
    # The keys this file drives: every literal `$(f <key>)`, plus the keys of each `for k in ...` loop over flags. A key
    # reaches the table through cli_flag, so a typo does not yield a token.
    used="$( { grep -oE '\$\(f [a-z.-]+\)' "${BASH_SOURCE[0]}" | awk '{print $2}' | tr -d ')';
               grep -oE '^[[:space:]]*for k in [a-z. -]+; do' "${BASH_SOURCE[0]}" \
                   | sed 's/^[[:space:]]*for k in //; s/; do$//' | tr ' ' '\n'; } \
            | sort -u | while read -r k; do cli_flag "${k}" 2>/dev/null && printf '\n'; done | grep -E '^--' | sort -u)"
    unrowed="$(comm -23 <(printf '%s\n' "${documented}") <(printf '%s\n' "${used}"))"
    stale="$(comm -13 <(printf '%s\n' "${documented}") <(printf '%s\n' "${used}"))"
    if [[ -z "${documented}" ]]; then
        fail "could not extract any option from ${MAN}"
    elif [[ -n "${unrowed}" ]]; then
        fail "option(s) ai-tools(1) documents with no row in this file: $(tr '\n' ' ' <<<"${unrowed}")"
    else
        pass "every option ai-tools(1) documents has a row here ($(wc -l <<<"${documented}") options)"
    fi
    if [[ -n "${stale}" ]]; then
        fail "option(s) driven here that ai-tools(1) no longer documents: $(tr '\n' ' ' <<<"${stale}")"
    else
        pass "no row drives an option the page does not document"
    fi
fi

finish
