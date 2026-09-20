#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/session-env.sh
# Unit test for the per-agent session pins under session-env.d (providers.rule.md, "The session-env.d seam"). A pins
# file is sourced by ai-tools-run into EVERY session of the account while its agent is enabled -- a session of every
# other agent included -- which is what lets an agent started from inside another agent's session find its state
# directory, and what makes the file's content a disclosure question: a credential or a route in it reaches every
# agent's sessions. So the contract is an allowlist, and this file holds every shipped pins file to it:
#
#   1. IT NAMES AN INSTALLED AGENT. <name>.pins.env.sh is sourced by the name of an enabled agent's manifest, so
#      a pins file with no agents.d/<name>.conf beside it is never sourced and reads as a packaging mistake.
#   2. IT SOURCES CLEAN and appends `--setenv=NAME=value` lines alone: no name-only import (`--setenv=NAME`, the shape
#      that forwards a value from the caller's environment), no PATH tail, and every value a path under /opt/ai-tools
#      or a switch (0/1) -- a state directory, a cache, an updater switch.
#   3. IT DOES NOT EXIT, EXEC, EXPORT, OR READ STDIN. Those are the fragment's two sanctioned exceptions and the
#      fragment reaches the launching agent's sessions alone; a pins file that took either would take it for every
#      agent's launch.
#
# The checker is driven on fixtures it must refuse -- a name-only import, a token value, a PATH tail -- so a green run
# is not an allowlist that admits everything. Pure: the pins files are read from the checkout, the fixtures are files this test
# writes in its testdir, and no host state is read. Run without root.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="${ROOT}/src/usr/local/lib/ai-tools"

section "session pins: every shipped <name>.pins.env.sh holds to the pins contract (unit)"

if [[ ! -d "${LIB_DIR}/session-env.d" ]]; then
    skip "session pins" "not a source checkout (no ${LIB_DIR}/session-env.d)"
    finish; exit
fi

mktestdir

# The allowlist. A pin is `--setenv=NAME=value`; NAME is an environment name and value is a path under the sandbox home
# or a one-character switch. Anything else -- a name-only import, a URL, a token, a PATH entry -- is refused.
readonly PIN_RE='^--setenv=[A-Z][A-Z0-9_]*=(/opt/ai-tools(/[A-Za-z0-9._-]+)*|[01])$'

# pins_effect <file>: print what sourcing <file> appends, one entry per line, PATH entries prefixed, in a clean shell
# under the shim's own options. A non-zero status is the file exiting or failing, which the caller reports.
pins_effect() {
    bash -c '
        set -euo pipefail
        declare -a session_environment_options=() session_path_entries=()
        source "$1"
        printf "%s\n" "${session_environment_options[@]+"${session_environment_options[@]}"}"
        printf "PATH:%s\n" "${session_path_entries[@]+"${session_path_entries[@]}"}"
    ' _ "$1" 2>&1
}

# check_pins <file> <label>: the three properties, each its own result line.
check_pins() {
    local file="$1" label="$2" name effect rc offending
    name="${file##*/}"; name="${name%.pins.env.sh}"
    if [[ -f "${LIB_DIR}/agents.d/${name}.conf" ]]; then
        pass "${label}: names the installed agent ${name}"
    else
        fail "${label}: no agent manifest ${LIB_DIR}/agents.d/${name}.conf -- the shim sources pins by an enabled agent's name, so this file is never sourced"
    fi
    effect="$(pins_effect "${file}")" && rc=0 || rc=$?
    if (( rc != 0 )); then
        fail "${label}: sourcing it fails (rc ${rc}): $(tr '\n' '|' <<<"${effect}" | head -c 200)"
        return 0
    fi
    offending="$(grep -vE "${PIN_RE}" <<<"${effect}" | grep -vx 'PATH:' || true)"
    if [[ -n "${offending}" ]]; then
        fail "${label}: appends something outside the pins allowlist: $(tr '\n' '|' <<<"${offending}")"
    elif ! grep -qE "${PIN_RE}" <<<"${effect}"; then
        fail "${label}: appends no pin at all"
    else
        pass "${label}: appends --setenv=NAME=value pins alone and no PATH entry: $(grep -E "${PIN_RE}" <<<"${effect}" | sed 's/^--setenv=//; s/=.*//' | tr '\n' ' ')"
    fi
    if ! grep -qE '^[^#]*\b(exit|exec|export|read)\b' "${file}"; then
        pass "${label}: does not exit, exec, export, or read stdin"
    else
        fail "${label}: carries an exit/exec/export/read outside a comment: $(grep -nE '^[^#]*\b(exit|exec|export|read)\b' "${file}" | head -3 | tr '\n' '|')"
    fi
}

# ── 1. The shipped pins files ─────────────────────────────────────────────────────────────────
shipped=0
for pins_file in "${LIB_DIR}"/session-env.d/*.pins.env.sh; do
    [[ -e "${pins_file}" ]] || continue
    shipped=$(( shipped + 1 ))
    check_pins "${pins_file}" "${pins_file##*/}"
done
if (( shipped == 0 )); then
    fail "no pins file is shipped under ${LIB_DIR}/session-env.d -- every agent package ships one"
fi

# ── 2. The allowlist refuses what it exists to refuse ─────────────────────────────────────────
# Fixtures the allowlist must refuse, driven through the effect reader alone, so a pass over the shipped files is
# evidence about them and not about a pattern that matches anything.
section "session pins: the allowlist refuses a name-only import and a token value"
fixture="${TESTDIR}/fixture.pins.env.sh"
printf '%s\n' 'session_environment_options+=( "--setenv=ANTHROPIC_AUTH_TOKEN" )' > "${fixture}"
effect="$(pins_effect "${fixture}")"
if grep -vE "${PIN_RE}" <<<"${effect}" | grep -qv '^PATH:$'; then
    pass "a name-only import (--setenv=NAME) is outside the allowlist"
else
    fail "a name-only import passed the allowlist: $(tr '\n' '|' <<<"${effect}")"
fi
printf '%s\n' 'session_environment_options+=( "--setenv=ANTHROPIC_BASE_URL=https://example.invalid" "--setenv=API_KEY=sk-test" )' > "${fixture}"
effect="$(pins_effect "${fixture}")"
if [[ "$(grep -vE "${PIN_RE}" <<<"${effect}" | grep -cv '^PATH:$')" -eq 2 ]]; then
    pass "a URL and a token value are outside the allowlist"
else
    fail "a URL or a token value passed the allowlist: $(tr '\n' '|' <<<"${effect}")"
fi
printf '%s\n' 'session_path_entries+=( "/opt/ai-tools/somewhere/bin" )' > "${fixture}"
effect="$(pins_effect "${fixture}")"
if grep -q '^PATH:/' <<<"${effect}" && grep -vE "${PIN_RE}" <<<"${effect}" | grep -qv '^PATH:$'; then
    pass "a PATH tail is outside the allowlist"
else
    fail "a PATH tail passed the allowlist: $(tr '\n' '|' <<<"${effect}")"
fi

finish
