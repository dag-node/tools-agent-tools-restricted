#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/cli-state-machine.sh
# The `projects` verbs as a state machine: every verb that acts on a registered path, over every state the registry
# classifier gives a path, one row per (verb, state) asserting the message code on the output, the exit status
# and whether the registry changed. The verbs and the states are declared lists, and the table is checked complete
# before a row runs, so a verb or a state added without its cells fails this file. The rows after the table cover
# what a cell cannot: discovery (a verb run without a path), the required path, the registry gate on a legacy file,
# nested disabled projects, the listing over a '%' line, and the same edits under `--for`.
#
# Each row runs the deployed CLI as the projects user over a fixture registry (AI_TOOLS_ALLOWLIST) and the root-helper
# stubs of tests/lib/cli-stubs.sh, under setsid so every prompt takes its default; the fixture tree and the registry are
# rebuilt before each row, since a removal deletes its tree.
#
# Needs: root (runuser), a provisioned host (the CLI's bootstrap gate), an exec-capable fixture directory,
# and the `nobody` account as the enrolled `--for` target.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/cli-spelling.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/cli-stubs.sh"
require_root
umask 022

readonly CLI="/usr/local/bin/ai-tools"
readonly FOR_USER="nobody"
readonly REG_MARKER="# ai-tools-project-registry-format: 1.0"

section "ai-tools: the projects verbs over every registry state (integration)"

if [[ ! -x "${CLI}" ]]; then skip "cli state machine" "not installed at ${CLI}"; finish; exit; fi
if ! provisioned_agent; then skip_unprovisioned "cli state machine"; finish; exit; fi
if ! getent passwd "${FOR_USER}" >/dev/null 2>&1; then skip "cli state machine" "no ${FOR_USER} account"; finish; exit; fi
# shellcheck source=../../src/usr/local/lib/ai-tools/conf.lib.sh
source /usr/local/lib/ai-tools/conf.lib.sh

mktestdir
R="${TESTDIR}"
probe="${R}/.exec-probe"; printf '#!/bin/sh\nexit 0\n' > "${probe}"; chmod 0700 "${probe}"
if ! "${probe}" >/dev/null 2>&1; then mk_fixture_dir R "${PROJECTS_HOME}" cli-state-machine; fi
rm -f "${probe}"
chmod 0755 "${R}"
AL="${R}/registry"; FOR_AL="${R}/for-allowlist"; GC="${R}/gitconfig"; CONF="${R}/operator.conf"; SBROOT="${R}/sandbox"
mk_operator_conf "${CONF}" "${PROJECTS_USER}" "${FOR_USER}"
cli_stubs_install "${R}"
cli_stub_ai_ops "${FOR_USER}"
# The fixture root is the projects user's: a create makes its directory there, an edit of the registry writes
# its temporary file beside it, and the stubs append to the call log as that user. The operator.conf fixture stays
# root's (reset re-asserts it): the gate honours its AI_TOOLS_AGENTS line in a trusted file alone.
chmod -R u+rwX,go+rX "${R}"
chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${R}"
chown root:root "${CONF}"

# The fixture: one registry holding a path in every state, and the directories it names.
#   P disabled, L enabled (L/sub inside it), B/x enabled and B/pb disabled under the disabled B, W/k excluded inside W
#   (W/k/deep inside W and under the exclusion), A an ancestor of A/one and A/two, U unregistered, W/n a project
#   nested in W, G/m/cache/deep under a glob exclusion of G. The *new paths name directories create makes. Each line
#   is a sign, one space and the path, at no indentation, so a line a verb leaves as it was reads as it was written
#   and one the canonical writer rewrote reads at its depth in the forest.
REG_LINES=("% ${R}/P" "@ ${R}/L" "% ${R}/B" "@ ${R}/B/x" "@ ${R}/W" "! ${R}/W/k" "@ ${R}/W/n"
    "@ ${R}/A/one" "@ ${R}/A/two" "@ ${R}/G" "! ${R}/G/*/cache"
    "% ${R}/pnew" "@ ${R}/lnew" "@ ${R}/B/lbnew" "! ${R}/W/knew" "@ ${R}/anew/x"
    "% ${R}/B/pb" "% ${R}/B/pbnew")
FIXTURE_DIRS=(P/sub L/sub B/x B/pb W/k/deep W/n A/one A/two U G/m/cache/deep)

# reset: rebuild the tree, the registry and the `--for` target's registry, and clear the stub log.
reset() {
    local d
    rm -rf "${R}/tree-marker" "${R}/P" "${R}/L" "${R}/B" "${R}/W" "${R}/A" "${R}/U" "${R}/G" \
        "${R}/pnew" "${R}/lnew" "${R}/anew" "${R}/unew" "${R}/bad*name" "${R}/q\"q" "${SBROOT}"
    for d in "${FIXTURE_DIRS[@]}"; do mkdir -p "${R}/${d}"; done
    mkdir -p "${SBROOT}"
    printf '%s\n' "${REG_MARKER}" "${REG_LINES[@]}" > "${AL}"
    printf '%s\n' "${REG_MARKER}" "${REG_LINES[@]}" > "${FOR_AL}"
    : > "${GC}"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/P" "${R}/L" "${R}/B" "${R}/W" "${R}/A" "${R}/U" \
        "${R}/G" "${SBROOT}" "${AL}" "${FOR_AL}" "${GC}"
    chown root:root "${CONF}"
    cli_stub_reset
}

# run_in <cwd> <args...>: the deployed CLI as the projects user over the fixtures, output with stderr.
# With RUN_TTY_ANSWERS set it runs under script(1) on a pseudo-terminal fed that text, for a question no flag
# pre-answers (cli-flags.sh's run_in states the shape); bounded, since a question the answers do not reach would wait.
# shellcheck disable=SC2016  # the inner shell expands $1 and $@
run_in() {
    local cwd="$1"; shift
    local -a command=(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}"
        PATH="${CLI_STUB_PATH}:/usr/local/bin:/usr/bin:/bin"
        AI_TOOLS_OPERATOR_CONF="${CONF}" AI_TOOLS_ALLOWLIST="${REG_FILE:-${AL}}" AI_TOOLS_GITCONFIG="${GC}"
        AI_TOOLS_SANDBOX_ROOT="${SBROOT}")
    if [[ -n "${RUN_TTY_ANSWERS:-}" ]]; then
        command+=(bash -c 'cd "$1" && exec script -qec "$2" /dev/null' _ "${cwd}" "$(printf '%q ' "${CLI}" "$@")")
        printf '%b' "${RUN_TTY_ANSWERS}" | timeout 120 "${command[@]}" 2>&1
        return
    fi
    "${command[@]}" bash -c 'cd "$1" && shift && exec setsid -w "$@"' _ "${cwd}" "${CLI}" "$@" 2>&1
}
# digest: the hash of the registry a row asserts on -- the one the CLI reads, or the `--for` target's.
digest() { sha256sum "${DIGEST_FILE:-${REG_FILE:-${AL}}}" | cut -c1-64; }

# check <label> <want-code|-> <want-exit> <same|changed> [<helper>] : assert the last run's code, exit and registry
# change, and with <helper> the stub log: a helper name it must hold, `!<name>` one it must not, `-` an empty log (a
# refusal does not reach a helper), `?` or absent for a run whose calls the row does not read.
out=""; rc=0; before=""
check() {
    local label="$1" code="$2" want_rc="$3" change="$4" helper="${5:-?}" after
    after="$(digest)"
    if [[ "${rc}" -eq "${want_rc}" ]]; then pass "${label}: exit ${rc}"
    else fail "${label}: exit ${rc}, expected ${want_rc}: $(awk 'NF' <<<"${out}" | tail -n 3 | tr '\n' '~')"; fi
    [[ "${code}" == - ]] || assert_msg "${code}" "${out}" "${label}: ${code}"
    if [[ "${change}" == same && "${after}" == "${before}" ]] || [[ "${change}" == changed && "${after}" != "${before}" ]]
    then pass "${label}: registry ${change}"
    else fail "${label}: registry expected ${change}"; fi
    case "${helper}" in
        '?') ;;
        -)   if cli_log_empty; then pass "${label}: no helper called"
             else fail "${label}: a helper was called: $(cut -f1 "${CLI_STUB_LOG}" | sort -u | tr '\n' ' ')"; fi ;;
        '!'*) if cli_called "${helper:1}"; then fail "${label}: ${helper:1} was called"
              else pass "${label}: ${helper:1} not called"; fi ;;
        *)   if cli_called "${helper}"; then pass "${label}: ${helper} called"
             else fail "${label}: ${helper} not called: $(cut -f1 "${CLI_STUB_LOG}" | sort -u | tr '\n' ' ')"; fi ;;
    esac
}

# ── The table ─────────────────────────────────────────────────────────────────────────────
readonly VERBS=(claim create remove unclaim enable disable handback lockdown push)
readonly STATES=(disabled disabled-blocked enabled enabled-blocked excluded inside inside-blocked ancestor unregistered)
# verb | state | path under R | extra argument (or -) | code (or -) | exit | registry | helper: a helper the run calls,
# `!<helper>` for one it does not call, `-` for a run that calls none (every refusal), `?` where the call is not read
TABLE="$(cat <<'ROWS'
claim    | disabled         | P         | -y | -        | 1 | same    | -
claim    | disabled-blocked | B/pb      | -y | MSG-R8C7 | 1 | same    | -
claim    | enabled          | L         | -y | -        | 0 | same    | ai-tools-safedir
claim    | enabled-blocked  | B/x       | -y | MSG-R8C7 | 1 | same    | -
claim    | excluded         | W/k       | -y | MSG-W4S7 | 1 | same    | -
claim    | inside           | L/sub     | -y | -        | 0 | changed | ai-tools-safedir
claim    | inside-blocked   | W/k/deep  | -y | MSG-R8C7 | 1 | same    | -
claim    | ancestor         | A         | -y | -        | 0 | changed | ai-tools-safedir
claim    | unregistered     | U         | -y | -        | 0 | changed | ai-tools-safedir
create   | disabled         | pnew      | -  | -        | 1 | same    | -
create   | disabled-blocked | B/pbnew   | -  | MSG-R8C7 | 1 | same    | -
create   | enabled          | lnew      | -  | -        | 0 | same    | ai-tools-safedir
create   | enabled-blocked  | B/lbnew   | -  | MSG-R8C7 | 1 | same    | -
create   | excluded         | W/knew    | -  | MSG-W4S7 | 1 | same    | -
create   | inside           | L/inew    | -  | -        | 0 | changed | ai-tools-safedir
create   | inside-blocked   | W/k/ibnew | -  | MSG-R8C7 | 1 | same    | -
create   | ancestor         | anew      | -  | -        | 0 | changed | ai-tools-safedir
create   | unregistered     | unew      | -  | -        | 0 | changed | ai-tools-safedir
remove   | disabled         | P         | -y | -        | 0 | changed | ?
remove   | disabled-blocked | B/pb      | -y | -        | 0 | changed | ?
remove   | enabled          | L         | -y | -        | 0 | changed | ?
remove   | enabled-blocked  | B/x       | -y | -        | 0 | changed | ?
remove   | excluded         | W/k       | -y | MSG-W4S7 | 1 | same    | -
remove   | inside           | L/sub     | -y | MSG-T5A3 | 1 | same    | -
remove   | inside-blocked   | W/k/deep  | -y | MSG-T5A3 | 1 | same    | -
remove   | ancestor         | A         | -y | MSG-F4D8 | 1 | same    | -
remove   | unregistered     | U         | -y | MSG-P8Y8 | 1 | same    | -
unclaim  | disabled         | P         | -y | -        | 1 | same    | !ai-tools-unclaim
unclaim  | disabled-blocked | B/pb      | -y | -        | 1 | same    | !ai-tools-unclaim
unclaim  | enabled          | L         | -y | -        | 0 | changed | ai-tools-unclaim
unclaim  | enabled-blocked  | B/x       | -y | -        | 1 | changed | !ai-tools-unclaim
unclaim  | excluded         | W/k       | -y | MSG-W4S7 | 1 | same    | -
unclaim  | inside           | L/sub     | -y | MSG-T5A3 | 1 | same    | -
unclaim  | inside-blocked   | W/k/deep  | -y | MSG-T5A3 | 1 | same    | -
unclaim  | ancestor         | A         | -y | -        | 0 | changed | ai-tools-unclaim
unclaim  | unregistered     | U         | -y | MSG-P8W2 | 1 | same    | -
enable   | disabled         | P         | -  | -        | 0 | changed | -
enable   | disabled-blocked | B/pb      | -  | -        | 0 | changed | -
enable   | enabled          | L         | -  | -        | 0 | same    | -
enable   | enabled-blocked  | B/x       | -  | -        | 0 | same    | -
enable   | excluded         | W/k       | -  | MSG-W4S7 | 1 | same    | -
enable   | inside           | L/sub     | -  | MSG-T5A3 | 1 | same    | -
enable   | inside-blocked   | W/k/deep  | -  | MSG-T5A3 | 1 | same    | -
enable   | ancestor         | A         | -  | MSG-T4A8 | 1 | same    | -
enable   | unregistered     | U         | -  | MSG-T4A8 | 1 | same    | -
disable  | disabled         | P         | -  | -        | 0 | same    | -
disable  | disabled-blocked | B/pb      | -  | -        | 0 | same    | -
disable  | enabled          | L         | -  | -        | 0 | changed | -
disable  | enabled-blocked  | B/x       | -  | -        | 0 | changed | -
disable  | excluded         | W/k       | -  | MSG-W4S7 | 1 | same    | -
disable  | inside           | L/sub     | -  | MSG-T5A3 | 1 | same    | -
disable  | inside-blocked   | W/k/deep  | -  | MSG-T5A3 | 1 | same    | -
disable  | ancestor         | A         | -  | MSG-T4A8 | 1 | same    | -
disable  | unregistered     | U         | -  | MSG-T4A8 | 1 | same    | -
handback | disabled         | P         | -  | MSG-W3S4 | 1 | same    | -
handback | disabled-blocked | B/pb      | -  | MSG-W3S4 | 1 | same    | -
handback | enabled          | L         | -  | -        | 0 | same    | ai-tools-reclaim
handback | enabled-blocked  | B/x       | -  | MSG-R8C7 | 1 | same    | -
handback | excluded         | W/k       | -  | MSG-R8C7 | 1 | same    | -
handback | inside           | L/sub     | -  | -        | 0 | same    | ai-tools-reclaim
handback | inside-blocked   | W/k/deep  | -  | MSG-R8C7 | 1 | same    | -
handback | ancestor         | A         | -  | MSG-J3K5 | 1 | same    | -
handback | unregistered     | U         | -  | MSG-J3K5 | 1 | same    | -
lockdown | disabled         | P         | -  | MSG-W3S4 | 1 | same    | -
lockdown | disabled-blocked | B/pb      | -  | MSG-W3S4 | 1 | same    | -
lockdown | enabled          | L         | -  | -        | 0 | same    | ai-tools-lockdown
lockdown | enabled-blocked  | B/x       | -  | MSG-R8C7 | 1 | same    | -
lockdown | excluded         | W/k       | -  | MSG-R8C7 | 1 | same    | -
lockdown | inside           | L/sub     | -  | -        | 0 | same    | ai-tools-lockdown
lockdown | inside-blocked   | W/k/deep  | -  | MSG-R8C7 | 1 | same    | -
lockdown | ancestor         | A         | -  | MSG-J3K5 | 1 | same    | -
lockdown | unregistered     | U         | -  | MSG-J3K5 | 1 | same    | -
push     | disabled         | P         | -  | MSG-T4Z6 | 1 | same    | -
push     | disabled-blocked | B/pb      | -  | MSG-T4Z6 | 1 | same    | -
push     | enabled          | L         | -  | MSG-T4Z6 | 1 | same    | -
push     | enabled-blocked  | B/x       | -  | MSG-T4Z6 | 1 | same    | -
push     | excluded         | W/k       | -  | MSG-T4Z6 | 1 | same    | -
push     | inside           | L/sub     | -  | MSG-T4Z6 | 1 | same    | -
push     | inside-blocked   | W/k/deep  | -  | MSG-T4Z6 | 1 | same    | -
push     | ancestor         | A         | -  | MSG-T4Z6 | 1 | same    | -
push     | unregistered     | U         | -  | MSG-T4Z6 | 1 | same    | -
ROWS
)"

# trim <text> : <text> without leading or trailing spaces.
trim() { local t="$1"; t="${t#"${t%%[! ]*}"}"; printf '%s' "${t%"${t##*[! ]}"}"; }

# The push column is the gate's: `projects push` with a path does not read the registry state (require_sandbox_clone
# decides), so each of its cells proves the clone check refuses every state. A push over a real clone is a discovery
# row.

# The table is complete before a row runs: one cell per (verb, state), and no cell for an undeclared verb or state.
declare -A cells=()
while IFS='|' read -r verb state _; do
    cells["$(trim "${verb}"):$(trim "${state}")"]=1
done <<< "${TABLE}"
missing=()
for verb in "${VERBS[@]}"; do
    for state in "${STATES[@]}"; do
        [[ -n "${cells[${verb}:${state}]:-}" ]] || missing+=("${verb}:${state}")
    done
done
if (( ${#missing[@]} == 0 && ${#cells[@]} == ${#VERBS[@]} * ${#STATES[@]} )); then
    pass "the table holds one cell per verb and state (${#cells[@]})"
else
    fail "the table is incomplete: missing ${missing[*]:-none}, ${#cells[@]} cells for ${#VERBS[@]} x ${#STATES[@]}"
    finish; exit
fi

# Each path is in the state its column names before any cell reads it, so a fixture that drifts fails here rather than
# letting a cell pass for another reason: `enabled-blocked` and `inside-blocked` read as enabled or inside with a line
# in `blocked`, and `enabled` and `inside` with none.
reset
declare -A proven=()
drifted=()
while IFS='|' read -r _ state path _; do
    state="$(trim "${state}")"; path="${R}/$(trim "${path}")"
    [[ -z "${proven[${path}]:-}" ]] || continue; proven["${path}"]=1
    IFS=$'\t' read -r got _ _ _ blocked _ _ <<< "$(ai_tools_conf__read_registry_path_class "${AL}" "${path}")"
    case "${state}" in
        *-blocked)      [[ "${got}" == "${state%-blocked}" && "${blocked}" != - ]] || drifted+=("${path}=${got}/${blocked}") ;;
        enabled|inside) [[ "${got}" == "${state}" && "${blocked}" == - ]]          || drifted+=("${path}=${got}/${blocked}") ;;
        *)              [[ "${got}" == "${state}" ]]                               || drifted+=("${path}=${got}") ;;
    esac
done <<< "${TABLE}"
if (( ${#drifted[@]} == 0 )); then
    pass "every fixture path reads the state its column names (${#proven[@]} paths)"
else
    fail "fixture paths in another state: ${drifted[*]}"
    finish; exit
fi

while IFS='|' read -r verb state path extra code want_rc change helper; do
    verb="$(trim "${verb}")"; state="$(trim "${state}")"; path="${R}/$(trim "${path}")"; extra="$(trim "${extra}")"
    code="$(trim "${code}")"; want_rc="$(trim "${want_rc}")"; change="$(trim "${change}")"; helper="$(trim "${helper}")"
    reset; before="$(digest)"
    key="ai-tools.projects.${verb}"; [[ "${verb}" == remove ]] && key=ai-tools.projects.remove.inplace
    cli_cmd "${key}"
    args=("${CLI_ARGV[@]}"); [[ "${extra}" == - ]] || args+=("${extra}")
    rc=0; out="$(run_in "${R}" "${args[@]}" "${path}")" || rc=$?
    check "${verb} x ${state}" "${code}" "${want_rc}" "${change}" "${helper}"
done <<< "${TABLE}"

# ── A disabled project under another '%' line ───────────────────────────────────────────────────────
# The covering line is read before the re-enable is offered: a claim of B/pb answered yes on a terminal is refused
# with its '%' standing, the question not asked, since the line on B refuses the claim whatever the answer.
section "ai-tools: a disabled project another line covers"
reset; before="$(digest)"; cli_cmd ai-tools.projects.claim
rc=0; out="$(RUN_TTY_ANSWERS='y\ny\n' run_in "${R}" "${CLI_ARGV[@]}" -y "${R}/B/pb")" || rc=$?
# On a terminal the code is the box title's (`#-- ERROR MSG-R8C7 --#`), not a line of its own, so it is read there.
check "claim of a disabled project under a '%' line, the re-enable answered" - 1 same -
if grep -qE '^#-+ ERROR MSG-R8C7 ' <<<"$(tr -d '\r' <<<"${out}")"; then pass "the refusal is MSG-R8C7, in the box title"
else fail "the refusal's code: $(grep -m1 -o 'MSG-[A-Z0-9]*' <<<"${out}" || echo none)"; fi
if grep -qxF "% ${R}/B/pb" "${AL}" && ! grep -qF "Re-enable this project" <<<"${out}"; then
    pass "the own '%' stands and the re-enable is not offered"
else
    fail "the claim under a '%' line: $(grep -F "${R}/B/pb" "${AL}" || echo gone): $(awk 'NF' <<<"${out}" | head -n 4 | tr '\n' '~')"
fi
reset; before="$(digest)"; cli_cmd ai-tools.projects.unclaim
rc=0; out="$(RUN_TTY_ANSWERS='y\ny\n\n' run_in "${R}" "${CLI_ARGV[@]}" -y "${R}/B/pb")" || rc=$?
check "unclaim of a disabled project under a '%' line, on a terminal" - 1 same '!ai-tools-unclaim'
if ! grep -qF "Re-enable this project" <<<"${out}" && grep -qF "atr projects unclaim ${R}/B/pb" <<<"${out}"; then
    pass "the unclaim does not offer the re-enable and names itself as the retry"
else
    fail "the unclaim under a '%' line: $(awk 'NF' <<<"${out}" | tail -n 4 | tr '\n' '~')"
fi

# An enable reports the entry and the gate apart: under a covering line the entry is enabled, the warning names
# the line, and the close neither says sessions may start nor points at a claim, which would refuse. The listed project
# under the same '%' line, already enabled, takes the same close; P, with no line over it, is the control. The line is
# named as the file holds it, and the line on B is `% <path>` at no indentation in the fixture and in the canonical
# form the enable writes.
enable_close() {   # enable_close <label> <path> <blocked|reachable>
    local label="$1" path="$2" want="$3"
    reset; before="$(digest)"; cli_cmd ai-tools.projects.enable
    rc=0; out="$(run_in "${R}" "${CLI_ARGV[@]}" "${path}")" || rc=$?
    if [[ "${want}" == blocked ]]; then
        if grep -qF "% ${R}/B" <<<"${out}" && ! grep -qF "sessions may start" <<<"${out}" \
                && ! grep -qF "projects claim" <<<"${out}"; then
            pass "${label}: the covering line is named, and no sessions line or claim is printed"
        else
            fail "${label}: $(awk 'NF' <<<"${out}" | tail -n 5 | tr '\n' '~')"
        fi
    elif grep -qF "sessions may start" <<<"${out}" && grep -qF "projects claim" <<<"${out}"; then
        pass "${label}: the sessions line and the claim are printed (the control)"
    else
        fail "${label}: $(awk 'NF' <<<"${out}" | tail -n 5 | tr '\n' '~')"
    fi
}
enable_close "enable of a disabled project under a '%' line" "${R}/B/pb" blocked
check "enable of a disabled project under a '%' line" - 0 changed -
enable_close "enable of a listed project under a '%' line" "${R}/B/x" blocked
enable_close "enable of a disabled project" "${R}/P" reachable

# ── A `--for` removal of an unregistered tree ──────────────────────────────────────────────────────────
# `--force` binds the hand-back to the account running it, so the remedy names the target as that account and no line
# carries both flags; `--force` beside `--for` is the gate's refusal, ahead of the verb's own.
section "ai-tools: a --for removal of an unregistered tree"
DIGEST_FILE="${FOR_AL}"
reset; before="$(digest)"; cli_cmd ai-tools.projects.remove.inplace
rc=0; out="$(run_in "${R}" --for "${FOR_USER}" "${CLI_ARGV[@]}" -y "${R}/U")" || rc=$?
check "remove --for of an unregistered tree" MSG-P8Y8 1 same
if grep -qF "As ${FOR_USER}, run:" <<<"${out}" && ! grep -qE -- '--for.*--force|--force.*--for' <<<"${out}" \
        && grep -qxF "       atr projects unclaim --force $(printf '%q' "${R}/U")" <<<"${out}"; then
    pass "the remedy names ${FOR_USER} as the account, and no line holds --for beside --force"
else
    fail "the --for removal remedy: $(awk 'NF' <<<"${out}" | tail -n 4 | tr '\n' '~')"
fi
reset; before="$(digest)"
rc=0; out="$(run_in "${R}" --for "${FOR_USER}" "${CLI_ARGV[@]}" --force "${R}/U")" || rc=$?
check "remove --for --force" MSG-B5K3 1 same -
if ! grep -qE -- '--for.*--force|--force.*--for' <<<"$(grep -F 'atr ' <<<"${out}")"; then
    pass "the refusal prints no command holding --for beside --force"
else
    fail "the --for --force refusal: $(grep -F 'atr ' <<<"${out}" | head -n 2 | tr '\n' '~')"
fi
DIGEST_FILE=""

# ── Discovery: a file verb run without a path acts on the project the current directory is in ──────────
section "ai-tools: discovery from the current directory"
discover() { local cwd="$1" key="$2"; cli_cmd "${key}"; rc=0; out="$(run_in "${cwd}" "${CLI_ARGV[@]}")" || rc=$?; }
reset; before="$(digest)"
discover "${R}/L/sub" ai-tools.projects.handback
check "handback inside a listed project" - 0 same
if grep -qF "projects handback: ${R}/L (the project the current directory is in)" <<<"${out}"; then
    pass "the discovered project is named first"
else
    fail "the discovered project was not named: $(awk 'NF' <<<"${out}" | head -n 3 | tr '\n' '~')"
fi
discover "${R}/P/sub" ai-tools.projects.handback;      check "handback inside a disabled project" MSG-R8C7 1 same
discover "${R}/W/k/deep" ai-tools.projects.lockdown;   check "lockdown inside an excluded path" MSG-R8C7 1 same
# The walk refuses at a directory a glob covers between the current directory and the project, where the launch gate
# reads the current directory alone (cli.rule.md).
discover "${R}/G/m/cache/deep" ai-tools.projects.handback
check "handback under an intermediate glob" MSG-R8C7 1 same
discover "${R}/U" ai-tools.projects.handback;          check "handback outside every project" MSG-K8R8 2 same
discover "${R}/L/sub" ai-tools.projects.push;          check "push on a candidate that is not a clone" MSG-T4Z6 1 same
# A real clone: a bare repository cloned under the clone area and registered, with no commit ahead of its upstream.
# Signing is off, since a host whose git config signs commits waits on a pinentry the run cannot answer.
git_fx() { runuser -u "${PROJECTS_USER}" -- git -c user.name=cli-state-machine -c user.email=csm@example.invalid \
    -c init.defaultBranch=main -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
# make_source: a fresh source repository at R/src, its one commit pushed to the bare origin at R/origin.git.
make_source() {
    rm -rf "${R}/origin.git" "${R}/src"
    mkdir -p "${R}/origin.git" "${R}/src"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/origin.git" "${R}/src"
    git_fx init -q --bare "${R}/origin.git"
    git_fx init -q "${R}/src"
    printf '# src\n' > "${R}/src/README.md"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/src/README.md"
    git_fx -C "${R}/src" add README.md
    git_fx -C "${R}/src" commit -q -m first
    git_fx -C "${R}/src" remote add origin "${R}/origin.git"
    git_fx -C "${R}/src" push -q origin main
}
reset; make_source
git_fx clone -q "${R}/origin.git" "${SBROOT}/clonefx"
printf '%s\n' "@ ${SBROOT}/clonefx" >> "${AL}"
if [[ -d "${SBROOT}/clonefx/.git" ]]; then
    before="$(digest)"
    discover "${SBROOT}/clonefx" ai-tools.projects.push; check "push from inside a registered clone" - 0 same
    if grep -qF "projects push: ${SBROOT}/clonefx (the project the current directory is in)" <<<"${out}"; then
        pass "the discovered clone is named first"
    else
        fail "the discovered clone was not named: $(awk 'NF' <<<"${out}" | head -n 3 | tr '\n' '~')"
    fi
else
    fail "the clone fixture was not made at ${SBROOT}/clonefx"
fi

# ── Names the registry cannot carry: create and clone refuse before their first write ────────────────────────────
section "ai-tools: a directory name the registry cannot carry"
for name in 'bad*name' 'q"q'; do
    reset; before="$(digest)"; cli_cmd ai-tools.projects.create
    rc=0; out="$(run_in "${R}" "${CLI_ARGV[@]}" "${R}/${name}")" || rc=$?
    check "create ${name}" MSG-Z9R2 1 same -
    if [[ ! -e "${R}/${name}" ]]; then pass "create ${name}: the directory was not made"
    else fail "create ${name}: the directory was made"; fi
done
# The clone reads its source and the remote before the name check, and makes the branch and the clone after it.
remote_branch() { git -c safe.directory='*' -C "${R}/origin.git" rev-parse --verify --quiet "refs/heads/$1" >/dev/null 2>&1; }
for name in 'bad*name' plain; do
    reset; make_source
    before="$(digest)"; cli_cmd ai-tools.projects.clone
    rc=0; out="$(run_in "${R}/src" "${CLI_ARGV[@]}" "$(cli_flag dir)" "${name}" "${R}/src")" || rc=$?
    if [[ "${name}" == plain ]]; then
        # The control: a plain name passes the check, so the branch is pushed and the clone made, whatever the steps
        # after them (the label, the gate) end in.
        if remote_branch sandbox/main && [[ -d "${SBROOT}/plain" ]]; then
            pass "clone --dir plain pushes the branch and makes the clone (the control)"
        else
            fail "clone --dir plain: no branch or no clone: $(awk 'NF' <<<"${out}" | tail -n 3 | tr '\n' '~')"
        fi
    else
        check "clone --dir ${name}" MSG-Z9R2 1 same -
        if ! remote_branch sandbox/main && ! git -c safe.directory='*' -C "${R}/src" rev-parse --verify --quiet \
                refs/heads/sandbox/main >/dev/null 2>&1 && [[ ! -e "${SBROOT}/${name}" ]]; then
            pass "clone --dir ${name}: neither the branch nor the clone was made"
        else
            fail "clone --dir ${name}: a branch or the clone was made"
        fi
    fi
done
rm -rf "${R}/origin.git" "${R}/src"

# ── Unclaim: a hand-back given up ──────────────────────────────────────────────────────────────────
section "ai-tools: an unclaim whose hand-back did not run"
cli_cmd ai-tools.projects.unclaim

# A disabled target whose re-enable is declined (no terminal answers it) keeps its '%' line under either disposition,
# and the close names this unclaim again as what completes it.
reset; before="$(digest)"
rc=0; out="$(run_in "${R}" "${CLI_ARGV[@]}" -y "${R}/P")" || rc=$?
check "unclaim of a disabled project, re-enable declined" - 1 same '!ai-tools-unclaim'
if grep -qxF "% ${R}/P" "${AL}"; then pass "the line stays disabled"; else fail "the disabled line: $(grep -F "${R}/P" "${AL}" || echo gone)"; fi
if grep -qF "atr projects unclaim ${R}/P" <<<"${out}"; then pass "the remedy is the unclaim again"
else fail "the remedy: $(awk 'NF' <<<"${out}" | tail -n 4 | tr '\n' '~')"; fi
# The remedy over the registry that run left, the re-enable answered on a terminal: the hand-back runs and the line
# goes.
before="$(digest)"; cli_stub_reset
rc=0; out="$(RUN_TTY_ANSWERS='y\ny\n\n' run_in "${R}" "${CLI_ARGV[@]}" -y "${R}/P")" || rc=$?
check "the remedy unclaim, the re-enable answered" - 0 changed ai-tools-unclaim
if ! grep -qF "${R}/P" "${AL}"; then pass "the remedy drops the line"; else fail "the line after the remedy: $(grep -F "${R}/P" "${AL}")"; fi
# A project a line elsewhere covers takes the '%' itself, so the remedy has a line to act on. The write is canonical,
# so the line sits under B, the entry enclosing it.
reset; before="$(digest)"
rc=0; out="$(run_in "${R}" "${CLI_ARGV[@]}" -y "${R}/B/x")" || rc=$?
check "unclaim of a project under a '%' line" - 1 changed '!ai-tools-unclaim'
if grep -qxF "  % ${R}/B/x" "${AL}"; then pass "the covered project's line is disabled"
else fail "the covered line: $(grep -F "${R}/B/x" "${AL}" || echo gone)"; fi
if grep -qF "atr projects unclaim ${R}/B/x" <<<"${out}"; then pass "its remedy is the unclaim again"
else fail "the covered remedy: $(awk 'NF' <<<"${out}" | tail -n 4 | tr '\n' '~')"; fi

# ── The claim of an ancestor names the entries under it ────────────────────────────────────────────────
reset; before="$(digest)"; cli_cmd ai-tools.projects.claim
rc=0; out="$(run_in "${R}" "${CLI_ARGV[@]}" -y "${R}/A")" || rc=$?
if grep -qF "${R}/A/one" <<<"${out}" && grep -qF "${R}/A/two" <<<"${out}"; then
    pass "the claim of an ancestor names A/one and A/two"
else
    fail "the ancestor claim's Review block: $(awk 'NF' <<<"${out}" | head -n 8 | tr '\n' '~')"
fi

# ── The required path ─────────────────────────────────────────────────────────────────────
section "ai-tools: the verbs that require their path"
for verb in claim clone remove unclaim enable disable; do
    key="ai-tools.projects.${verb}"; [[ "${verb}" == remove ]] && key=ai-tools.projects.remove.inplace
    reset; before="$(digest)"; cli_cmd "${key}"
    rc=0; out="$(run_in "${R}/L" "${CLI_ARGV[@]}")" || rc=$?
    check "${verb} without a path" MSG-K7D9 2 same
done
reset; before="$(digest)"; cli_cmd ai-tools.projects.enable
rc=0; out="$(run_in "${R}/P" "${CLI_ARGV[@]}" .)" || rc=$?
check "enable . names the current directory" - 0 changed

# ── The registry gate: a legacy file ──────────────────────────────────────────────────────────
section "ai-tools: a registry not yet migrated"
LEGACY="${R}/allowed-projects"
for verb in claim create remove unclaim enable disable clone push handback lockdown; do
    key="ai-tools.projects.${verb}"; [[ "${verb}" == remove ]] && key=ai-tools.projects.remove.inplace
    reset; printf '%s\n' "${R}/L" "!${R}/P" > "${LEGACY}"; chown "${PROJECTS_USER}" "${LEGACY}"
    REG_FILE="${LEGACY}"; before="$(digest)"; cli_cmd "${key}"
    rc=0; out="$(run_in "${R}" "${CLI_ARGV[@]}" "${R}/L")" || rc=$?
    check "${verb} on a legacy registry" MSG-J6S8 1 same
    REG_FILE=""
done
REG_FILE="${LEGACY}"; before="$(digest)"; cli_cmd ai-tools.projects.list
rc=0; out="$(run_in "${R}" "${CLI_ARGV[@]}")" || rc=$?
check "list on a legacy registry" - 0 same
if grep -qF "post-upgrade" <<<"${out}" && grep -qE "exclude[[:space:]]+${R}/P" <<<"${out}"; then
    pass "the listing names the migration and reads every '!' line as an exclusion"
else
    fail "the legacy listing: $(awk 'NF' <<<"${out}" | head -n 6 | tr '\n' '~')"
fi
REG_FILE=""

# ── The registry gate: two signs on one path ───────────────────────────────────────────────────
# Two lines naming one written path with different signs state two things about one directory, so the grammar refuses
# the whole file and every verb refuses over it, the listing included: the library's line, then the CLI's, with the file
# as it was. A trailing slash does not make a second path.
section "ai-tools: a registry holding two signs on one path"
CONFLICT_REG="${R}/registry-conflict"
for verb in list claim create remove unclaim enable disable clone push handback lockdown; do
    key="ai-tools.projects.${verb}"; [[ "${verb}" == remove ]] && key=ai-tools.projects.remove.inplace
    reset; printf '%s\n' "${REG_MARKER}" "@ ${R}/L" "! ${R}/L" > "${CONFLICT_REG}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${CONFLICT_REG}"
    REG_FILE="${CONFLICT_REG}"; before="$(digest)"; cli_cmd "${key}"
    args=("${CLI_ARGV[@]}"); [[ "${verb}" == list ]] || args+=("${R}/L")
    rc=0; out="$(run_in "${R}" "${args[@]}")" || rc=$?
    check "${verb} over '@' and '!' on one path" MSG-B8U2 1 same -
    assert_msg MSG-Y7K5 "${out}" "${verb} over '@' and '!' on one path: the CLI's refusal follows"
    REG_FILE=""
done
reset; printf '%s\n' "${REG_MARKER}" "@ ${R}/L" "% ${R}/L/" > "${CONFLICT_REG}"
chown "${PROJECTS_USER}:${PROJECTS_USER}" "${CONFLICT_REG}"
REG_FILE="${CONFLICT_REG}"; before="$(digest)"; cli_cmd ai-tools.projects.disable
rc=0; out="$(run_in "${R}" "${CLI_ARGV[@]}" "${R}/L")" || rc=$?
check "disable over '@' and '%' on one path" MSG-B8U2 1 same -
assert_msg MSG-Y7K5 "${out}" "disable over '@' and '%' on one path: the CLI's refusal follows"
REG_FILE=""; rm -f "${CONFLICT_REG}"

# ── Nested disabled projects, the listing over a '%' line, and the same edits under `--for` ──────────
section "ai-tools: nested disabled projects, the listing, --for"
reset; before="$(digest)"; cli_cmd ai-tools.projects.disable
rc=0; out="$(run_in "${R}" "${CLI_ARGV[@]}" "${R}/W/n")" || rc=$?
check "disable writes '%' on a project nested in a listed one" - 0 changed
if grep -qxF "  % ${R}/W/n" "${AL}" && grep -qxF "@ ${R}/W" "${AL}"; then
    pass "the nested line takes the '%', indented under the project enclosing it"
else
    fail "the nested '%' line: $(cat "${AL}")"
fi
before="$(digest)"; cli_cmd ai-tools.projects.enable
rc=0; out="$(run_in "${R}" "${CLI_ARGV[@]}" "${R}/W/n")" || rc=$?
check "enable lifts a nested '%' line" - 0 changed
reset; before="$(digest)"; cli_cmd ai-tools.projects.list
rc=0; out="$(run_in "${R}" "${CLI_ARGV[@]}")" || rc=$?
check "list" - 0 same
if grep -qE "disabled[[:space:]]+${R}/P([[:space:]]|$)" <<<"${out}" \
        && ! grep -qE "${R}/P([[:space:]]|$)" <<<"$(sed -n '/Suggested cleanup/,$p' <<<"${out}")"; then
    pass "a '%' line lists as disabled and never as stale"
else
    fail "the listing over a '%' line: $(awk 'NF' <<<"${out}" | head -n 8 | tr '\n' '~')"
fi

# `--for`: the same edits on the target's registry, through the helper (its stub edits the target's file).
DIGEST_FILE="${FOR_AL}"
for_run() { cli_cmd "$1"; shift; rc=0; out="$(run_in "${R}" --for "${FOR_USER}" "${CLI_ARGV[@]}" "$@")" || rc=$?; }
reset; before="$(digest)"; for_run ai-tools.projects.disable "${R}/W/n"
check "disable --for writes '%' on a nested project" - 0 changed
if grep -qxF "  % ${R}/W/n" "${FOR_AL}"; then pass "the target's nested line takes the '%'"; else fail "the --for nested '%' line"; fi
before="$(digest)"; for_run ai-tools.projects.enable "${R}/W/n"
check "enable --for lifts the nested '%' line" - 0 changed
reset; before="$(digest)"; for_run ai-tools.projects.enable "${R}/W/k"
check "enable --for refuses an excluded path" MSG-W4S7 1 same
reset; before="$(digest)"; for_run ai-tools.projects.list
check "list --for" - 0 same
if grep -qE "disabled[[:space:]]+${R}/P" <<<"${out}"; then pass "the --for listing reads the '%' line"; else fail "the --for listing"; fi
# A stale line's removal command runs as the target on the target's file, named in the tilde-user form the shell
# expands: `%q` would escape the `~`.
for_sed="$(grep -m1 -E '^[[:space:]]+sudo -u [^ ]+ sed -i ' <<<"${out}" | sed 's/^[[:space:]]*//')"
if [[ "${for_sed}" == "sudo -u ${FOR_USER} sed -i "* && "${for_sed}" == *" ~${FOR_USER}/.config/ai-tools/project-registry" ]]; then
    pass "the --for removal command runs as ${FOR_USER} on ~${FOR_USER}/.config/ai-tools/project-registry, unescaped"
else
    fail "the --for removal command: '${for_sed}'"
fi
# A `--for` run reads a snapshot of the target's file, and every refusal names the target's registry by its path: never
# the snapshot, which the EXIT trap has removed by the time the message is read. A printed remedy carries `--for`.
for_shown="~${FOR_USER}/.config/ai-tools/project-registry"
# A claim checks the tree's owner first, so its path is the target's, as a `--for` claim's tree is.
for_refusal() {   # for_refusal <label> <code> <key> <path> [<arg>...]
    local label="$1" code="$2" key="$3" path="$4"; shift 4
    reset; [[ "${key}" == ai-tools.projects.claim ]] && chown "${FOR_USER}" "${path}"
    before="$(digest)"; for_run "${key}" "$@" "${path}"
    check "${label}" "${code}" 1 same
    if grep -qE "${TMPDIR:-/tmp}/tmp\." <<<"${out}"; then
        fail "${label}: a line names the snapshot: $(grep -E "${TMPDIR:-/tmp}/tmp\." <<<"${out}" | head -n 1)"
    else
        pass "${label}: no line names the snapshot"
    fi
}
for_refusal "claim --for on an excluded path"        MSG-W4S7 ai-tools.projects.claim    "${R}/W/k" -y
for_refusal "claim --for under an excluded path"     MSG-R8C7 ai-tools.projects.claim    "${R}/W/k/deep" -y
for_refusal "claim --for under a '%' line"           MSG-R8C7 ai-tools.projects.claim    "${R}/B/x" -y
for_refusal "handback --for on an excluded path"     MSG-R8C7 ai-tools.projects.handback "${R}/W/k"
for_refusal "handback --for under an excluded path"  MSG-R8C7 ai-tools.projects.handback "${R}/W/k/deep"
if grep -qF "${for_shown}" <<<"${out}"; then
    pass "the excluded-path remedy names the target's registry"
else
    fail "the excluded-path remedy: $(awk 'NF' <<<"${out}" | tail -n 2 | tr '\n' '~')"
fi
for_refusal "handback --for under a '%' line"        MSG-R8C7 ai-tools.projects.handback "${R}/B/x"
want_remedy="atr projects enable --for ${FOR_USER} ${R}/B"
if grep -qF "${want_remedy}" <<<"${out}"; then
    pass "the re-enable remedy reads '${want_remedy}'"
else
    fail "the re-enable remedy: $(awk 'NF' <<<"${out}" | tail -n 2 | tr '\n' '~')"
fi
# Following the remedy lifts the target's '%' and leaves the invoker's registry as it was.
al_before="$(sha256sum "${AL}")"; before="$(digest)"; for_run ai-tools.projects.enable "${R}/B"
check "the re-enable remedy, run" - 0 changed
if [[ "$(sha256sum "${AL}")" == "${al_before}" ]] && grep -qxF "@ ${R}/B" "${FOR_AL}"; then
    pass "the remedy changed the target's registry and not the invoker's"
else
    fail "the remedy's registries: invoker $( [[ "$(sha256sum "${AL}")" == "${al_before}" ]] && echo same || echo changed)"
fi
DIGEST_FILE=""

# ── The remedy names the disabled path, not the line as displayed ─────────────────────────────────
# A tab before a '%' line's comment is shown as '?' in the classifier's blocked field; the enable remedy reads
# the parsed path beside it, so it names the project. A disabled path with a space and a '#' prints %q-encoded, one word to paste.
section "ai-tools: the re-enable remedy names the disabled path"
FC_REG="${R}/registry-fc"
reset; rm -rf "${R}/N" "${R}/P dir#1"; mkdir -p "${R}/N/o" "${R}/P dir#1/q"
printf '%s\n' "${REG_MARKER}" "% ${R}/N"$'\t'"# disabled" "@ ${R}/N/o" "% \"${R}/P dir#1\"" > "${FC_REG}"
chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${R}/N" "${R}/P dir#1" "${FC_REG}"
REG_FILE="${FC_REG}"; cli_cmd ai-tools.projects.handback
before="$(digest)"; rc=0; out="$(run_in "${R}" "${CLI_ARGV[@]}" "${R}/N/o")" || rc=$?
check "handback under a '%' line whose comment follows a tab" MSG-R8C7 1 same -
if grep -qE "atr projects enable ${R}/N\$" <<<"${out}"; then
    pass "the remedy reads 'atr projects enable ${R}/N'"
else
    fail "the tab-comment remedy: $(grep -F 'atr projects enable' <<<"${out}" | head -n 1)"
fi
before="$(digest)"; rc=0; out="$(run_in "${R}" "${CLI_ARGV[@]}" "${R}/P dir#1/q")" || rc=$?
check "handback under a '%' line with a space and a '#'" MSG-R8C7 1 same -
want_remedy="atr projects enable $(printf '%q' "${R}/P dir#1")"
pasted="$(grep -oF "${want_remedy}" <<<"${out}" | head -n 1)"
# The words after `enable` as a shell reads a paste of them, the %q encoding undone.
pasted_words=(); eval "pasted_words=( ${pasted#atr projects enable } )"
if [[ -n "${pasted}" && "${#pasted_words[@]}" -eq 1 && "${pasted_words[0]}" == "${R}/P dir#1" ]]; then
    pass "the remedy reads '${want_remedy}', one word naming the disabled project"
else
    fail "the space-and-hash remedy: $(grep -F 'atr projects enable' <<<"${out}" | head -n 1)"
fi
REG_FILE=""; rm -rf "${R}/N" "${R}/P dir#1" "${FC_REG}"

# ── A composed command stands on its own line under the frame ────────────────────────────────────
# On a terminal the alert emitter wraps every line on whitespace, and the remedy's command carries a %q-escaped space.
# Run on a pseudo-terminal over a '%' line whose path is longer than the frame, the command is printed whole on one line
# outside the `#` frame, and no framed line holds it; the same under `--for`, the flag on that line.
section "ai-tools: a composed command under the frame"
LP="${R}/a-disabled-project-whose-path-runs-past-the-frame dir#1"
reset; rm -rf "${LP}"; mkdir -p "${LP}/q"
printf '%s\n' "${REG_MARKER}" "%\"${LP}\"" > "${FC_REG}"; cp -- "${FC_REG}" "${FOR_AL}"
chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${LP}" "${FC_REG}" "${FOR_AL}"
# framed_command_check <label> <want-command> : assert the last run's output holds <want-command> as a whole line
# outside the frame, and that no line inside the frame carries `atr projects`.
framed_command_check() {
    local label="$1" want="$2" lines
    lines="$(tr -d '\r' <<<"${out}")"
    if ! grep -q '^#' <<<"${lines}"; then
        fail "${label}: the run drew no frame, so the case did not run on a terminal: $(head -n 3 <<<"${lines}" | tr '\n' '~')"
    elif grep -qxF -- "       ${want}" <<<"${lines}" && ! grep -E '^#' <<<"${lines}" | grep -qF 'atr projects'; then
        pass "${label}: '${want}' stands whole on one line under the frame"
    else
        fail "${label}: $(grep -n -e 'atr projects' -e 'enable' <<<"${lines}" | head -n 4 | tr '\n' '~')"
    fi
}
REG_FILE="${FC_REG}"; cli_cmd ai-tools.projects.handback
rc=0; out="$(RUN_TTY_ANSWERS='\n' run_in "${R}" "${CLI_ARGV[@]}" "${LP}/q")" || rc=$?
framed_command_check "handback under a long '%' line, on a terminal" "atr projects enable $(printf '%q' "${LP}")"
REG_FILE=""; cli_cmd ai-tools.projects.handback
rc=0; out="$(RUN_TTY_ANSWERS='\n' run_in "${R}" --for "${FOR_USER}" "${CLI_ARGV[@]}" "${LP}/q")" || rc=$?
framed_command_check "handback --for under a long '%' line, on a terminal" \
    "atr projects enable --for ${FOR_USER} $(printf '%q' "${LP}")"
rm -rf "${LP}" "${FC_REG}"

finish
