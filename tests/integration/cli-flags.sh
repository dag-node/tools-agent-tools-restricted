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
# Prompts: every run is under `setsid -w`, so each prompt takes its non-interactive default. A default-NO prompt
# therefore declines, which is what makes `--yes` observable -- the row without it does not record a helper call,
# the row with it records the call. A default-YES prompt proceeds, so a `--yes` on such a command (the clone's create
# confirm) is asserted as accepted, its effect being unobservable without a terminal. The clone kind's removal does not
# take a `--yes`, so only its declined path is drivable here; the positive path lands with the conversion.
#
# Trace mode: with AI_TOOLS_CLI_FLAGS_TRACE=<file> the run also RECORDS every outcome, so a diff of two traces reports
# every difference between two builds, including one no row names.  The file opens with a surface digest read
# from the CLI source -- per command key, the option arms its parser accepts and the gating tables that list it, plus
# any dispatch arm no key maps to -- so a command that gained an option, a gate, or a sibling shows without a row
# for it. Every driven row then appends its key-form label, exit status, the full call log, and a digest
# of the registries and the fixture tree (types, modes, paths). Fixture paths and account names are replaced by tokens,
# so the two traces to compare are the one from `develop` and the one from the conversion branch, each recorded
# on the same host after `install.sh` deployed that tree (the rows drive the installed binary; the digest reads
# the checkout when one is present).
#
# Needs: root (runuser), a provisioned host (the CLI's bootstrap gate), an exec-capable fixture directory (/tmp is
# noexec on a hardened host, so the fixtures fall back beside the projects user's home), and the `nobody` account
# as the enrolled --for target.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/cli-spelling.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/cli-stubs.sh"
require_root
# The umask is process state the CLI inherits through runuser (whose PAM stack does not run
# pam_umask), so this file decides it rather than the host: the rows and the trace run under
# 022, which makes a trace comparable across hosts, and the umask independence section re-runs the rows a
# umask could change under the stricter values a hardened host sets. Nothing on the host is
# changed by it -- a umask is per process and dies with this shell.
umask 022

readonly CLI="/usr/local/bin/ai-tools"
readonly CONF_LIB="/usr/local/lib/ai-tools/conf.lib.sh"
readonly CLAUDE_LINK="/opt/ai-tools/bin/claude"
readonly FOR_USER="nobody"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPELLING="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/cli-spelling.sh"
# The CLI source the surface digest and the coverage check read: the checkout when there is one, the installed script
# otherwise (it is a plain bash file).
CLI_SRC="${ROOT}/src/usr/local/bin/ai-tools.sh"; [[ -r "${CLI_SRC}" ]] || CLI_SRC="${CLI}"
TRACE="${AI_TOOLS_CLI_FLAGS_TRACE:-}"

section "ai-tools: every command and option, by effect (integration)"

if [[ ! -x "${CLI}" ]]; then skip "cli flags" "not installed at ${CLI}"; finish; exit; fi
if [[ ! -L "${CLAUDE_LINK}" ]]; then skip "cli flags" "host not provisioned (no ${CLAUDE_LINK}); the CLI's bootstrap gate refuses"; finish; exit; fi
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
# Every directory the CLI itself names -- a clone takes its source's basename or --dir -- is
# named by the harness's fixture rule, so a clone that ever lands outside the fixture clone area
# (an installed CLI ignoring the override) reads as this suite's residue and the sweep finds it.
# Generated once, so the trace normaliser can replace each with a fixed token.
N_SRC="$(ai_test_name src)"; N_C2="$(ai_test_name c2)"; N_C3="$(ai_test_name c3)"
N_C4="$(ai_test_name c4)"; N_C5="$(ai_test_name c5)"
declare -A N_CL=([077]="$(ai_test_name clone-077)" [027]="$(ai_test_name clone-027)")
SRC="${R}/${N_SRC}"
printf 'OPERATORS="%s %s"\n' "${PROJECTS_USER}" "${FOR_USER}" > "${CONF}"; chmod 0644 "${CONF}"
: > "${AL}"; : > "${FOR_AL}"; : > "${GC}"
mkdir -p "${SBROOT}"
for d in pa pb pc pd pe pf plain unreg parent/p1 parent/p2 hold/inner for1 for2; do
    mkdir -p "${R}/${d}"; printf '# %s\n' "${d}" > "${R}/${d}/README.md"
done
mkdir -p "${R}/unreg/node_modules/dep"; : > "${R}/unreg/node_modules/dep/index.js"

# A source repository with a bare origin, for the clone rows. Signing is off: a host whose git
# config signs commits would wait on a pinentry the run cannot answer.
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
# Explicit modes: the suite runs under sudo, and a root umask of 077 would leave every fixture
# owner-only -- readable by the projects user where it owns them, and closed to it where the
# --for target does, which is where the claim's secret scan then fails to enter the tree.
chmod -R u+rwX,go+rX "${R}"
chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${R}"
# The --for target must own the tree a claim for it acts on (the claim's owner rule).
chown -R "${FOR_USER}:${FOR_GROUP}" "${R}/for1" "${R}/for2"
# An unregistered tree carrying the ai-tools fingerprint: the sandbox group.
chgrp -R "${SANDBOX_GROUP}" "${R}/unreg"

# ── Drivers and readers ───────────────────────────────────────────────────────────
# run_in <cwd> <args...>: the deployed CLI as the projects user, shim first on PATH, every registry pointed
# at a fixture, under setsid so no prompt can block. Output captured with stderr.  The inner shell expands $1 and $@
# itself, which is why they sit in single quotes.
# shellcheck disable=SC2016
run_in() {
    local cwd="$1"; shift
    runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
        PATH="${CLI_STUB_PATH}:/usr/local/bin:/usr/bin:/bin" \
        AI_TOOLS_OPERATOR_CONF="${CONF}" AI_TOOLS_ALLOWLIST="${AL}" AI_TOOLS_GITCONFIG="${GC}" \
        AI_TOOLS_SANDBOX_ROOT="${SBROOT}" \
        bash -c 'cd "$1" && shift && exec setsid -w "$@"' _ "${cwd}" "${CLI}" "$@" 2>&1
}
# cli <key> [args...] / cli_in <cwd> <key> [args...]: the command named by its spelling key.  cli_flag_first <key>
# <flag...>: the flags AHEAD of the command, the other order --for accepts.
cli()    { local key="$1"; shift; cli_cmd "${key}" || return 2; run_in "${R}" "${CLI_ARGV[@]}" "$@"; }
cli_in() { local cwd="$1" key="$2"; shift 2; cli_cmd "${key}" || return 2; run_in "${cwd}" "${CLI_ARGV[@]}" "$@"; }
cli_flag_first() { local key="$1"; shift; cli_cmd "${key}" || return 2; run_in "${R}" "$@" "${CLI_ARGV[@]}"; }
f() { cli_flag "$1"; }

seed()     { : > "${AL}"; (( $# )) && printf '%s\n' "$@" > "${AL}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${AL}"; cli_stub_reset; }
seed_for() { printf '%s\n' "$@" > "${FOR_AL}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${FOR_AL}"; }
seed_gc()  { : > "${GC}"; local p; for p in "$@"; do git config --file "${GC}" --add safe.directory "${p}"; done; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${GC}"; }
st()       { ai_tools_conf_allowlist_state "${AL}" "$1"; }
st_for()   { ai_tools_conf_allowlist_state "${FOR_AL}" "$1"; }
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
        -e "s#${N_C5}#\$C5#g" -e "s#${N_CL[077]}#\$CL077#g" -e "s#${N_CL[027]}#\$CL027#g"
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
        cli_cmd "${key}" || continue
        cmd="${CLI_ARGV[*]}"; mapped="${mapped} ${CLI_ARGV[0]}"
        fn="$(key_function "${CLI_ARGV[@]}")"
        opts="$( [[ -n "${fn}" ]] && fn_options "${fn}" | paste -sd, - )"
        gates=""
        for t in OPERATOR_VERBS ROOT_ALLOWED_VERBS BOOTSTRAP_EXEMPT_VERBS FOR_ALLOWED_VERBS; do
            table_lists "${t}" "${cmd}" && gates="${gates}${gates:+,}${t%_VERBS}"
        done
        printf 'surface %s options=%s gates=%s\n' "${key}" "${opts:-none}" "${gates:-none}" >> "${TRACE}"
    done < <(sed -n '/^cli_cmd() {/,/^}/p' "${SPELLING}" | grep -oE '^[ \t]+[a-z][a-z.]*\)' | tr -d ' \t)')
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
        cli_flag_first) label="flag-first ${*:2}" ;;
        *)              label="$*" ;;
    esac
    out="$("$@")" && rc=0 || rc=$?
    trace_row "${label}"
}
rc_is()   { [[ "${rc}" -eq "$1" ]]; }
rc_not0() { [[ "${rc}" -ne 0 ]]; }
# quiet_rc <n> / quiet_refusal: the exit status AND an empty call log -- a refusal that did not reach a helper, which is
# the ordering rule that a refused command does not prompt for sudo first.
quiet_rc()      { [[ "${rc}" -eq "$1" ]] && cli_log_empty; }
quiet_refusal() { [[ "${rc}" -ne 0 ]] && cli_log_empty; }
st_is()   { [[ "$(st "$1")" == "$2" ]]; }
st_for_is() { [[ "$(st_for "$1")" == "$2" ]]; }
not_called() { ! cli_called "$1"; }
# before <helper> <ere> <helper> <ere>: both calls recorded, the first ahead of the second.
before() {
    local a b; a="$(cli_call_index "$1" "$2")"; b="$(cli_call_index "$3" "$4")"
    [[ -n "${a}" && -n "${b}" && "${a}" -lt "${b}" ]]
}
# cwd_of <helper>: the directory the first call to <helper> was made from.
cwd_of() { awk -F'\t' -v h="$1" '$1==h {print $2; exit}' "${CLI_STUB_LOG}"; }
T=$'\t'

trace_surface

# ── A. Reads, help, and the incident rung ─────────────────────────────────────────
section "reports, help, version, stop, audit"
seed "${R}/pa"
drive cli help;               expect "help exits 0 with no helper call"            rc_is 0
expect "help reaches no helper" cli_log_empty
drive run_in "${R}";          expect "the bare invocation exits 0"                  rc_is 0
drive cli version;            expect "version exits 0 and prints one line"         test "${rc}" -eq 0 -a "$(wc -l <<<"${out}")" -eq 1
expect "version reaches no helper" cli_log_empty
drive cli projects.list;      expect "the project listing exits 0"                 rc_is 0
expect "the listing reaches no helper" cli_log_empty
drive cli status;             expect "status reaches no helper"                    cli_log_empty
drive cli providers;          expect "providers reaches no helper"                 cli_log_empty

cli_stub_reset
drive cli stop;               expect "stop calls the stop helper with no argument" test "$(cli_call_count ai-tools-stop)" -eq 1 -a -z "$(cli_calls ai-tools-stop)"
for k in all dry-run yes yes.short force; do
    cli_stub_reset; drive cli stop "$(f "${k}")"
    expect "stop passes $(f "${k}") through to the helper" cli_called ai-tools-stop "^$(f "${k}")$"
done
cli_stub_reset; drive cli stop -n
expect "stop has no -n short form (it is kept free for a --no)"   quiet_rc 2
cli_stub_reset; drive cli stop "${R}/pa"
expect "stop refuses a path with exit 2"                          rc_is 2
expect "stop's refused path reaches no helper"                    cli_log_empty
cli_stub_reset; drive cli stop --bogus
expect "stop refuses an unknown option with exit 2, no helper"    quiet_rc 2

cli_stub_reset; drive cli audit
expect "audit calls the audit helper"                             cli_called ai-tools-audit
cli_stub_reset; drive cli audit "$(f since)" "2 days ago"
expect "audit passes --since and its value through verbatim"      cli_called ai-tools-audit "^$(f since)${T}2 days ago$"

# ── B. Claim ─────────────────────────────────────────────────────────────────────
section "projects claim"
seed "${R}/pb"
drive cli projects.claim "${R}/pa"
expect "claim without --yes declines at the proceed prompt"       rc_not0
expect "the declined claim registers nothing"                     st_is "${R}/pa" absent
expect "the declined claim reaches no helper"                     cli_log_empty

cli_stub_reset; drive cli projects.claim "$(f yes)" "${R}/pa"
expect "claim --yes exits 0"                                      rc_is 0
expect "claim --yes registers the project"                        st_is "${R}/pa" listed
expect "claim --yes scans for secrets in the project"             cli_called ai-tools-lockdown "^$(f dry-run)$"
expect "claim --yes registers safe.directory"                     cli_called ai-tools-safedir "^${R}/pa$"
expect "claim --yes sets the group and setgid"                    cli_called ai-tools-setgid "^${R}/pa$"
expect "claim --yes applies the ACL"                              cli_called ai-tools-setfacl "${R}/pa$"
expect "the safe.directory entry is on record"                    gc_has "${R}/pa"
expect "the secret scan precedes every access-granting step"     before ai-tools-lockdown "^$(f dry-run)$" ai-tools-setgid "."

cli_stub_reset; drive cli projects.claim "$(f yes.short)" "${R}/pc"
expect "claim -y is the short form of --yes"                      st_is "${R}/pc" listed

cli_stub_reset; drive cli_in "${R}/pd" projects.claim "$(f yes)"
expect "claim defaults to the current directory"                  st_is "${R}/pd" listed
expect "the default-directory claim names that directory"         cli_called ai-tools-safedir "^${R}/pd$"

cli_stub_reset; cli_stub_secrets "${R}/pe/.env"; drive cli projects.claim "$(f yes)" "${R}/pe"
expect "a found secret is locked down before access is granted"  before ai-tools-lockdown "^$(f yes)$" ai-tools-setgid "."
expect "the claim with a secret still registers the project"     st_is "${R}/pe" listed
cli_stub_reset

drive cli projects.claim --bogus "${R}/pa"
expect "claim refuses an unknown option"                          rc_not0
expect "the refused claim reaches no helper"                      cli_log_empty

# ── C. Create ─────────────────────────────────────────────────────────────────────
section "projects create"
seed "${R}/pa"
drive cli projects.create
expect "create without a path is refused"                         rc_not0
expect "the refused create reaches no helper"                     cli_log_empty
cli_stub_reset; drive cli projects.create "${R}/new"
expect "create exits 0"                                           rc_is 0
expect "create makes the directory"                               test -d "${R}/new"
expect "create initialises git"                                   test -d "${R}/new/.git"
expect "create seeds a README"                                    test -f "${R}/new/README.md"
expect "create registers the project"                             st_is "${R}/new" listed
expect "create registers safe.directory"                          cli_called ai-tools-safedir "^${R}/new$"
expect "create sets the group and setgid"                         cli_called ai-tools-setgid "^${R}/new$"
expect "create applies the ACL"                                   cli_called ai-tools-setfacl "${R}/new$"
expect "create skips the secret scan on the tree it just made"   not_called ai-tools-lockdown
cli_stub_reset; drive cli projects.create "${R}/pa"
expect "create refuses an existing path"                          rc_not0
expect "the refused create reaches no helper"                     cli_log_empty
cli_stub_reset; drive cli projects.create "${R}/nope/x"
expect "create refuses a missing parent"                          rc_not0
expect "create does not manufacture the parent"                   test ! -e "${R}/nope"
cli_stub_reset; drive cli projects.create "$(f yes)" "${R}/new2"
expect "create takes no options"                                  rc_not0
expect "the refused create makes nothing"                         test ! -e "${R}/new2"

# ── D. Unclaim ────────────────────────────────────────────────────────────────────
section "projects unclaim"
seed "${R}/pa" "${R}/pb" "${R}/pc" "${R}/pd" "${R}/parent/p1" "${R}/parent/p2"
seed_gc "${R}/pa" "${R}/pb" "${R}/pc" "${R}/pd"
drive cli projects.unclaim "${R}/pa"
expect "unclaim without --yes declines at the confirm"            rc_not0
expect "the declined unclaim leaves the entry"                    st_is "${R}/pa" listed
expect "the declined unclaim reaches no helper"                   cli_log_empty

cli_stub_reset; drive cli projects.unclaim "$(f yes)" "${R}/pa"
expect "unclaim --yes hands the tree back to the invoker's group" cli_called ai-tools-unclaim "^${R}/pa${T}${PROJECTS_GROUP}$"
expect "unclaim --yes drops the entry"                            st_is "${R}/pa" absent
expect "unclaim --yes drops safe.directory"                       cli_called ai-tools-safedir "^$(printf -- '--remove')${T}${R}/pa$"
expect "the safe.directory entry is gone"                         gc_lacks "${R}/pa"

cli_stub_reset; drive cli projects.unclaim "$(f yes)" "$(f group)" "${FOR_GROUP}" "${R}/pb"
expect "unclaim --group names the hand-back group"                cli_called ai-tools-unclaim "^${R}/pb${T}${FOR_GROUP}$"
cli_stub_reset; drive cli projects.unclaim "$(f yes)" "$(f group)=${FOR_GROUP}" "${R}/pc"
expect "unclaim --group=<group> is the same option"               cli_called ai-tools-unclaim "^${R}/pc${T}${FOR_GROUP}$"
cli_stub_reset; drive cli projects.unclaim "$(f yes)" "$(f full)" "${R}/pd"
expect "unclaim --full asks the helper for the skipped trees"     cli_called ai-tools-unclaim "^${R}/pd${T}[^${T}]+${T}$(f full)$"

seed "${R}/pa"; drive cli projects.unclaim "$(f yes)" "$(f keep-entry)" "${R}/pa"
expect "unclaim --keep-entry parks the entry instead of dropping it" st_is "${R}/pa" disabled
expect "unclaim --keep-entry still hands the tree back"           cli_called ai-tools-unclaim "^${R}/pa${T}"

seed "${R}/pa"; drive cli projects.unclaim "$(f keep-entry)" "$(f force)" "${R}/pa"
expect "--keep-entry with --force is refused"                     rc_not0
expect "the refused unclaim reaches no helper"                    cli_log_empty
cli_stub_reset; drive cli projects.unclaim "$(f dry-run)" "${R}/pa"
expect "--dry-run without --force is refused"                     rc_not0
expect "that refusal reaches no helper"                           cli_log_empty
cli_stub_reset; drive cli projects.unclaim "$(f force)" "$(f yes)" "${R}/pa"
expect "--force on a registered project is refused"               rc_not0
expect "the refused --force reaches no helper"                    cli_log_empty
expect "the refused --force leaves the entry"                     st_is "${R}/pa" listed

cli_stub_reset; drive cli projects.unclaim "${R}/unreg"
expect "an unregistered tree with residue is reported, not acted on" quiet_rc 0
cli_stub_reset; drive cli projects.unclaim "$(f force)" "$(f dry-run)" "${R}/unreg"
expect "--force --dry-run previews and applies nothing"           quiet_rc 0
expect "the preview leaves the fingerprint in place"              test "$(stat -c %G "${R}/unreg")" = "${SANDBOX_GROUP}"
cli_stub_reset; drive cli projects.unclaim "$(f force)" "${R}/unreg"
expect "--force without --yes declines at the confirm"            rc_not0
expect "the declined --force reaches no helper"                   cli_log_empty
cli_stub_reset; drive cli projects.unclaim "$(f force)" "$(f yes)" "${R}/unreg"
expect "--force --yes normalizes the tree through the helper's unlisted mode" cli_called ai-tools-unclaim "^${R}/unreg${T}${PROJECTS_GROUP}${T}--unlisted$"
cli_stub_reset; drive cli projects.unclaim "$(f force)" "$(f yes)" "$(f full)" "${R}/unreg"
expect "--force --full reaches the skip-listed residue too"       cli_called ai-tools-unclaim "^${R}/unreg${T}${PROJECTS_GROUP}${T}--unlisted${T}$(f full)$"
cli_stub_reset; drive cli projects.unclaim "$(f force)" "$(f yes)" "${R}/plain"
expect "--force on a tree with no residue is refused"             rc_not0
expect "that refusal reaches no helper"                           cli_log_empty

seed "${R}/parent/p1" "${R}/parent/p2"
drive cli projects.unclaim "${R}/parent"
expect "an ancestor unclaim without --yes declines"               rc_not0
expect "the declined ancestor unclaim reaches no helper"          cli_log_empty
cli_stub_reset; drive cli projects.unclaim "$(f yes)" "${R}/parent"
expect "an ancestor unclaim --yes unclaims every project under it" test "$(cli_call_count ai-tools-unclaim)" -eq 2
expect "both nested entries are dropped"                          test "$(st "${R}/parent/p1")" = absent -a "$(st "${R}/parent/p2")" = absent
seed "${R}/hold"; drive cli projects.unclaim "$(f yes)" "${R}/hold/inner"
expect "a path inside a project is refused"                       rc_not0
expect "that refusal reaches no helper"                           cli_log_empty
expect "the enclosing entry is untouched"                         st_is "${R}/hold" listed

# ── E. Remove ─────────────────────────────────────────────────────────────────────
section "projects remove"
mkdir -p "${R}/rm1" "${R}/rm2" "${R}/rm3" "${R}/rmp/nested"; chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/rm1" "${R}/rm2" "${R}/rm3" "${R}/rmp"
seed "${R}/rm1" "!${R}/rm2" "${R}/rm3" "${R}/rmp" "${R}/rmp/nested"
seed_gc "${R}/rm1" "${R}/rm2"
drive cli projects.remove "${R}/rm1"
expect "remove without --yes declines at the confirm"             rc_not0
expect "the declined remove leaves the tree"                      test -d "${R}/rm1"
expect "the declined remove reaches no helper"                    cli_log_empty
cli_stub_reset; drive cli_in "${R}/rm1" projects.remove "$(f yes)"
expect "remove --yes without a path is refused"                   rc_not0
expect "the refused remove leaves the tree"                       test -d "${R}/rm1"
cli_stub_reset; drive cli projects.remove "$(f yes)" "${R}/rm1"
expect "remove --yes <path> deletes the tree"                     test ! -e "${R}/rm1"
expect "remove --yes drops the entry"                             st_is "${R}/rm1" absent
expect "remove --yes drops safe.directory"                        cli_called ai-tools-safedir "^--remove${T}${R}/rm1$"
expect "remove does not run the filesystem hand-back"             not_called ai-tools-unclaim
cli_stub_reset; drive cli projects.remove "$(f yes)" "${R}/rm2"
expect "a parked entry authorizes its removal"                    test ! -e "${R}/rm2"
expect "the parked line goes with the tree"                       st_is "${R}/rm2" absent
cli_stub_reset; drive cli projects.remove "$(f force)" "${R}/rm3"
expect "remove has no --force"                                    rc_not0
expect "the refused remove leaves the tree"                       test -d "${R}/rm3"
expect "that refusal reaches no helper"                           cli_log_empty
cli_stub_reset; drive cli projects.remove "$(f yes)" "${R}/plain"
expect "remove refuses an unregistered path"                      rc_not0
expect "the unregistered tree stands"                             test -d "${R}/plain"
cli_stub_reset; drive cli projects.remove "$(f yes)" "${R}/rmp"
expect "remove refuses an entry containing another claimed project" rc_not0
expect "the containing tree stands"                               test -d "${R}/rmp/nested"
expect "that refusal reaches no helper"                           cli_log_empty

# ── F. Enable and disable ─────────────────────────────────────────────────────────
section "projects disable / enable"
seed "${R}/pa" "${R}/hold" "${R}/hold/inner"
drive cli projects.disable "${R}/pa"
expect "disable parks the entry"                                  st_is "${R}/pa" disabled
expect "disable is a registry edit alone"                         cli_log_empty
drive cli projects.enable "${R}/pa"
expect "enable restores the entry"                                st_is "${R}/pa" listed
expect "enable is a registry edit alone"                          cli_log_empty
drive cli projects.disable "${R}/hold/inner"
expect "disable refuses a project nested in a listed one"         rc_not0
expect "the nested entry is unchanged"                            st_is "${R}/hold/inner" listed
drive cli projects.enable "${R}/plain"
expect "enable refuses a path with no entry"                      rc_not0
expect "enable invents no entry"                                  st_is "${R}/plain" absent
drive cli projects.disable "$(f yes)" "${R}/pa"
expect "disable takes no options"                                 rc_not0

# ── G. Acting for another operator ────────────────────────────────────────────────
section "--for"
seed "${R}/pa"; seed_for "${R}/for1"
inv_before="$(sha "${AL}")"
for order in "lead" "trail"; do
    cli_stub_reset
    if [[ "${order}" == lead ]]; then drive cli_flag_first projects.list "$(f for)" "${FOR_USER}"
    else drive cli projects.list "$(f for)" "${FOR_USER}"; fi
    expect "the listing --for reads the target's registry (${order}ing flag)" cli_called ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--print$"
done
expect "--for leaves the invoker's registry byte-identical"       test "$(sha "${AL}")" = "${inv_before}"

cli_stub_reset; drive cli projects.disable "$(f for)" "${FOR_USER}" "${R}/for1"
expect "disable --for edits the target's registry through the helper" cli_called ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--disable${T}${R}/for1$"
expect "the target's entry is parked"                             st_for_is "${R}/for1" disabled
cli_stub_reset; drive cli projects.enable "$(f for)" "${FOR_USER}" "${R}/for1"
expect "enable --for restores the target's entry"                 st_for_is "${R}/for1" listed
expect "--for leaves the invoker's registry byte-identical"       test "$(sha "${AL}")" = "${inv_before}"

cli_stub_reset; drive cli projects.claim "$(f for)" "${FOR_USER}" "$(f yes)" "${R}/for2"
expect "claim --for writes the target's registry"                 cli_called ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--add${T}${R}/for2$"
expect "the target's registry lists the project"                  st_for_is "${R}/for2" listed
expect "claim --for grants access through the helpers"            cli_called ai-tools-setgid "^${R}/for2$"
expect "--for leaves the invoker's registry byte-identical"       test "$(sha "${AL}")" = "${inv_before}"
cli_stub_reset; drive cli projects.unclaim "$(f for)" "${FOR_USER}" "$(f yes)" "${R}/for2"
expect "unclaim --for drops the target's entry through the helper" cli_called ai-tools-allowlist "^--operator${T}${FOR_USER}${T}--remove${T}${R}/for2$"
expect "the target's entry is gone"                               st_for_is "${R}/for2" absent

for key in projects.clone projects.push status stop; do
    cli_stub_reset; drive cli "${key}" "$(f for)" "${FOR_USER}" "${SRC}"
    expect "--for is refused on ${key}"                           rc_not0
    expect "the refused ${key} --for reaches no helper"           cli_log_empty
done
cli_stub_reset; drive cli projects.claim "$(f for)" "not-an-operator" "$(f yes)" "${R}/for1"
expect "--for refuses an unenrolled target"                       rc_not0
expect "that refusal reaches no helper"                           cli_log_empty
for who in root "${SANDBOX_USER}"; do
    cli_stub_reset; drive cli projects.claim "$(f for)" "${who}" "$(f yes)" "${R}/for1"
    expect "--for refuses ${who}"                                 rc_not0
    expect "that refusal reaches no helper"                       cli_log_empty
done
cli_stub_reset; drive cli projects.unclaim "$(f for)" "${FOR_USER}" "$(f force)" "${R}/unreg"
expect "--for with --force is refused"                            rc_not0
expect "that refusal reaches no helper"                           cli_log_empty

# ── H. Clone ──────────────────────────────────────────────────────────────────────
# The clone rows run only against an installed CLI that honours the clone-area override; an older
# deployment would put every clone in the real clone area, which the hermeticity contract forbids.
HAVE_SBROOT=false; grep -q 'AI_TOOLS_SANDBOX_ROOT' "${CLI}" && HAVE_SBROOT=true
if ! ${HAVE_SBROOT}; then
    section "projects clone / push / sandbox remove"
    skip "clone, push and clone-removal rows" "the installed ${CLI} predates the AI_TOOLS_SANDBOX_ROOT override; deploy the checkout first"
else
section "projects clone"
seed
cli_stub_reset; drive cli projects.clone "${SRC}"
expect "clone exits 0"                                            rc_is 0
expect "clone lands under the sandbox area, named after the source" test -d "${SBROOT}/${N_SRC}/.git"
expect "clone pushes the default branch, sandbox/<base>"          test -n "$(remote_tip sandbox/main)"
expect "clone registers the clone"                                st_is "${SBROOT}/${N_SRC}" listed
expect "clone scans the clone for secrets before opening it"      cli_called ai-tools-lockdown "^$(f dry-run)$"
expect "the scan runs inside the clone"                           test "$(cwd_of ai-tools-lockdown)" = "${SBROOT}/${N_SRC}"
expect "clone registers safe.directory for the clone"             cli_called ai-tools-safedir "^${SBROOT}/${N_SRC}$"
expect "the clone is shallow"                                     test "$(gitr -C "${SBROOT}/${N_SRC}" rev-list --count HEAD)" -eq 1

cli_stub_reset; drive cli projects.clone "$(f branch)" "feature/x" "$(f dir)" "${N_C2}" "${SRC}"
expect "clone --branch names the pushed branch"                   test -n "$(remote_tip feature/x)"
expect "clone --dir names the clone directory"                    test -d "${SBROOT}/${N_C2}/.git"
cli_stub_reset; drive cli projects.clone "$(f from)" "base2" "$(f branch)" "sb3" "$(f dir)" "${N_C3}" "${SRC}"
expect "clone --from forks the branch from that base"             test "$(remote_tip sb3)" = "$(gitr -C "${SRC}" rev-parse base2)"
cli_stub_reset; drive cli projects.clone "$(f yes)" "$(f dir)" "${N_C4}" "${SRC}"
expect "clone accepts --yes"                                      test "${rc}" -eq 0 -a -d "${SBROOT}/${N_C4}/.git"

cli_stub_reset; drive cli projects.clone "${SBROOT}/${N_C4}"
expect "clone on an existing clone path resumes its finalization" cli_called ai-tools-lockdown "^$(f dry-run)$"
expect "the resume runs inside that clone"                        test "$(cwd_of ai-tools-lockdown)" = "${SBROOT}/${N_C4}"
expect "the resume makes no second clone"                         test "$(find "${SBROOT}" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 4
expect "the resumed clone stays registered"                       st_is "${SBROOT}/${N_C4}" listed

cli_stub_reset; drive cli projects.clone "${SRC}" "$(f from)"
expect "clone --from without a value is refused"                  rc_not0
expect "that refusal reaches no helper"                           cli_log_empty
cli_stub_reset; drive cli projects.clone "${R}/plain"
expect "clone refuses a directory that is not a repository"       rc_not0
expect "that refusal reaches no helper"                           cli_log_empty
cli_stub_reset; drive cli projects.clone "$(f dir)" "${N_C2}" "${SRC}"
expect "clone refuses an existing destination"                    rc_not0
expect "that refusal reaches no helper"                           cli_log_empty
cli_stub_reset; drive cli projects.clone "$(f from)" "no-such-ref" "$(f dir)" "${N_C5}" "${SRC}"
expect "clone refuses an unknown base"                            rc_not0
expect "the refused clone makes no directory"                     test ! -e "${SBROOT}/${N_C5}"

# ── I. Push, and the clone kind's removal ─────────────────────────────────────────
section "projects push / sandbox remove"
runuser -u "${PROJECTS_USER}" -- git -C "${SBROOT}/${N_SRC}" -c user.name=cli-flags -c user.email=cli-flags@example.invalid \
    -c commit.gpgsign=false commit --allow-empty -m "sandbox work" >/dev/null 2>&1
cli_stub_reset; drive cli projects.push "${SBROOT}/${N_SRC}"
expect "push exits 0"                                             rc_is 0
expect "push advances the remote branch to the clone's HEAD"      test "$(remote_tip sandbox/main)" = "$(gitr -C "${SBROOT}/${N_SRC}" rev-parse HEAD)"
expect "push reaches no helper"                                   cli_log_empty
drive cli projects.push "${SBROOT}/${N_SRC}"
expect "push with nothing to push exits 0"                        rc_is 0
drive cli projects.push "${R}/pa"
expect "push refuses a path that is not a clone"                  rc_not0
drive cli_in "${SBROOT}/${N_SRC}" projects.push
expect "push defaults to the current directory"                   rc_is 0

cli_stub_reset; drive cli sandbox.remove "${SBROOT}/${N_C2}"
expect "the clone removal declines with no terminal"              rc_not0
expect "the declined removal leaves the clone"                    test -d "${SBROOT}/${N_C2}"
expect "the declined removal leaves the entry"                    st_is "${SBROOT}/${N_C2}" listed
drive cli sandbox.remove "${R}/pa"
expect "the clone removal refuses a path that is not a clone"     rc_not0
expect "that refusal leaves the tree"                             test -d "${R}/pa"
fi

# ── J. Lockdown and reclaim ───────────────────────────────────────────────────────
section "projects lockdown / reclaim"
seed "${R}/pa"
cli_stub_reset; drive cli projects.lockdown "${R}/pa"
expect "lockdown runs the helper inside the project"              test "$(cwd_of ai-tools-lockdown)" = "${R}/pa"
expect "lockdown passes no flag by default"                       test -z "$(cli_calls ai-tools-lockdown)"
for k in dry-run yes yes.short; do
    cli_stub_reset; drive cli projects.lockdown "$(f "${k}")" "${R}/pa"
    expect "lockdown passes $(f "${k}") through to the helper"     cli_called ai-tools-lockdown "^$(f "${k}")$"
done
cli_stub_reset; drive cli projects.lockdown -n "${R}/pa"
expect "lockdown has no -n short form, no helper"                 quiet_refusal
cli_stub_reset; drive cli projects.unclaim "$(f force)" -n "${R}/unreg"
expect "unclaim has no -n short form, no helper"                  quiet_refusal
guard="${R}/pa/CLAUDE.md"
printf '<!-- ai-tools-lockdown-guard -->\n# guard\n' > "${guard}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${guard}"
cli_stub_reset; drive cli projects.lockdown "$(f dry-run)" "${R}/pa"
expect "a dry-run lockdown leaves the guard file"                 test -f "${guard}"
cli_stub_reset; drive cli projects.lockdown "${R}/pa"
expect "a completed lockdown clears the guard file"               test ! -e "${guard}"
cli_stub_reset; drive cli projects.lockdown "${R}/plain"
expect "lockdown refuses a path outside every project"            rc_not0
expect "that refusal reaches no helper"                           cli_log_empty
cli_stub_reset; drive cli projects.lockdown --bogus "${R}/pa"
expect "lockdown refuses an unknown option, no helper"            quiet_refusal

cli_stub_reset; drive cli projects.reclaim "${R}/pa"
expect "reclaim hands the project to the reclaim helper"          cli_called ai-tools-reclaim "^${R}/pa$"
cli_stub_reset; drive cli projects.reclaim "$(f full)" "${R}/pa"
expect "reclaim --full asks the helper for the skipped trees"     cli_called ai-tools-reclaim "^$(f full)${T}${R}/pa$"
cli_stub_reset; drive cli_in "${R}/pa" projects.reclaim
expect "reclaim defaults to the current directory"                cli_called ai-tools-reclaim "^${R}/pa$"
cli_stub_reset; drive cli projects.reclaim "${R}/plain"
expect "reclaim refuses a path outside every project"             rc_not0
expect "that refusal reaches no helper"                           cli_log_empty
cli_stub_reset; drive cli projects.reclaim --bogus "${R}/pa"
expect "reclaim refuses an unknown option, no helper"             quiet_refusal

# ── L. The operator's umask does not decide what the agent can read ──────────────
# A create sets its modes outright and a clone is born private and then opened, so neither depends
# on the umask the operator's shell carries. Both are re-driven under the values a hardened host
# sets and held to the modes ai-tools(1) states. Restored afterwards, so the coverage check and
# the teardown run under the pinned 022.
section "umask independence"
has_bits() { (( ( 8#$(stat -c '%a' "$1") & 8#$2 ) == 8#$2 )); }
for u in 077 027; do
    umask "${u}"; TRACE_TAG="umask=${u}"
    seed; drive cli projects.create "${R}/new-${u}"
    expect "create under umask ${u} exits 0"                        rc_is 0
    expect "create under umask ${u}: the directory is 750"          test "$(perm "${R}/new-${u}")" = 750
    expect "create under umask ${u}: the README is 640"             test "$(perm "${R}/new-${u}/README.md")" = 640
    expect "create under umask ${u}: .git is group r-x"             has_bits "${R}/new-${u}/.git" 050
    if ${HAVE_SBROOT}; then
        seed; drive cli projects.clone "$(f dir)" "${N_CL[${u}]}" "${SRC}"
        expect "clone under umask ${u} exits 0"                     rc_is 0
        expect "clone under umask ${u}: the clone root is 770"      test "$(perm "${SBROOT}/${N_CL[${u}]}")" = 770
        expect "clone under umask ${u}: the clone root is setgid"   has_bits "${SBROOT}/${N_CL[${u}]}" 2000
        expect "clone under umask ${u}: a checked-out file is 660"  test "$(perm "${SBROOT}/${N_CL[${u}]}/README.md")" = 660
    fi
done
umask 022; TRACE_TAG=""

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
    # Options are the long tokens on the OPTIONS headings plus the ones on COMMANDS headings at any depth, less
    # the first token of a top-level entry (the verb) and the verbs the help lists.
    verbs="$(sed -n '/^usage() {/,/^EOF$/p' "${CLI_SRC}" | grep -E '^    --[a-z]' | grep -oE -- '--[a-z][a-z-]+' | sort -u)"
    documented="$( { man_section "${MAN}" OPTIONS | grep -E '^\.(B|BR|BI) ' | grep -oE -- '--[a-z][a-z-]+';
                     man_section "${MAN}" COMMANDS | awk '
                        /^\.RS/{d++; next} /^\.RE/{if (d>0) d--; next} /^\.TP/{want=1; next}
                        want && /^\.(B|BR|BI) /{ line=$0; first=1
                            while (match(line, /--[a-z][a-z-]+/)) {
                                tok=substr(line, RSTART, RLENGTH); if (!(d==0 && first)) print tok
                                first=0; line=substr(line, RSTART+RLENGTH) }
                            want=0 }'; } | sort -u | comm -23 - <(printf '%s\n' "${verbs}"))"
    # The keys this file drives: every literal `$(f <key>)`, plus the keys of each `for k in ...` loop over flags. A key
    # reaches the table through cli_flag, so a typo does not yield a token.
    used="$( { grep -oE '\$\(f [a-z.-]+\)' "${BASH_SOURCE[0]}" | awk '{print $2}' | tr -d ')';
               grep -oE '^for k in [a-z. -]+; do' "${BASH_SOURCE[0]}" | sed 's/^for k in //; s/; do$//' | tr ' ' '\n'; } \
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
