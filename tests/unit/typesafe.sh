#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/typesafe.sh
# Unit test for the typesafe integration's shell-side files (typesafe.rule.md): the manifest keeps the integration
# off until an operator names it, the session-env fragment hands a session the credential file's path and the usage
# log's path alone -- no PATH tail, no export, no exit, no value that is not one of those two paths -- the shipped
# credential template is inert: the key is commented, so the decide command, given the template itself, refuses
# with the configuration status before any request -- and the vendored command is the signed release
# tools/generators/typesafe-client.pin names, file for file. The command's own refusals are the suite of its source
# repository, dag-node/typesafe-client-js; the agent-side half of these guarantees is tests/boundary/typesafe.sh.
#
# Pure: reads the checkout, runs the fragment in a subshell with the two arrays declared, runs the command
# against a copy of the template in its own testdir, and runs the generator's offline `stale` verb. Run without root.

set -euo pipefail
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="${ROOT}/src/usr/local/lib/ai-tools"
MANIFEST="${LIB_DIR}/integrations.d/typesafe.conf"
FRAGMENT="${LIB_DIR}/session-env.d/typesafe.env.sh"
TEMPLATE="${ROOT}/src/etc/ai-tools/endpoints/typesafe.conf"
CLI="${LIB_DIR}/typesafe/decide.mjs"

section "typesafe: manifest, session-env fragment, and the shipped credential template (unit)"

if [[ ! -r "${MANIFEST}" || ! -r "${FRAGMENT}" || ! -r "${TEMPLATE}" ]]; then
    skip "typesafe" "not a source checkout (${MANIFEST}, ${FRAGMENT}, ${TEMPLATE})"; finish; exit
fi
# shellcheck source=/dev/null
source "${LIB_DIR}/conf.lib.sh"

# ── 1. The manifest keeps the integration off by default ─────────────────────────────────────────
# A call sends listing lines off the host, so the integration is the surface-widening kind: providers.lib.sh turns it
# on only where AI_TOOLS_INTEGRATIONS names it (tests/unit/providers.sh drives the verdict).
if ai_tools_conf_read "${MANIFEST}" default_enable && [[ "${_ai_tools_conf_value}" == "no" ]]; then
    pass "integrations.d/typesafe.conf declares default_enable=no"
else
    fail "integrations.d/typesafe.conf does not declare default_enable=no (read '${_ai_tools_conf_value:-}')"
fi

# ── 2. The fragment hands a session two paths alone ──────────────────────────────────────────────
# Sourced the way ai-tools-run sources it, with the two arrays it appends to declared. The fragment self-gates
# on the INSTALLED credential file (a fixed path it does not take from the caller), so its effect on this host is either
# the two `--setenv` entries or none -- both are asserted against the same allowlist, and the export/exit/exec grep
# holds whichever branch ran.
fragment_effect() {
    bash -c '
        set -euo pipefail
        declare -a session_environment_options=() session_path_entries=()
        source "$1"
        printf "%s\n" "${session_environment_options[@]+"${session_environment_options[@]}"}"
        printf "PATH:%s\n" "${session_path_entries[@]+"${session_path_entries[@]}"}"
    ' _ "$1" 2>&1
}
effect="$(fragment_effect "${FRAGMENT}")" || fail "the fragment does not source cleanly: $(tr '\n' '|' <<<"${effect}")"
allowed='^--setenv=AI_TOOLS_TYPESAFE_(CONF=/etc/ai-tools/endpoints/typesafe\.conf|USAGE_LOG=/opt/ai-tools/integrations/typesafe/usage\.log)$'
offending="$(grep -vE "${allowed}" <<<"${effect}" | grep -v '^PATH:$' || true)"
if [[ -z "${offending}" ]]; then
    pass "the fragment appends the credential file path and the usage log path alone, with no PATH tail"
else
    fail "the fragment appends an entry outside its two paths: $(tr '\n' '|' <<<"${offending}")"
fi
count="$(grep -cE "${allowed}" <<<"${effect}" || true)"
if [[ -f /etc/ai-tools/endpoints/typesafe.conf ]]; then
    want=2; state="with the credential file installed"
else
    want=0; state="without the credential file"
fi
if [[ "${count}" -eq "${want}" ]]; then
    pass "${state}, the fragment sets ${want} variable(s)"
else
    fail "${state}, the fragment sets ${count} variable(s), not ${want}"
fi
# The two sanctioned fragment exceptions (export, exit) are not taken: this fragment does not carry a credential
# and does not refuse a launch, and each would reach ai-tools-run's own shell.
if grep -qE '^[[:space:]]*(export|exit|exec)\b' "${FRAGMENT}"; then
    fail "the fragment exports, exits, or execs -- it hands over two paths and takes neither exception"
else
    pass "the fragment does not export, exit, or exec"
fi

# ── 3. The shipped credential template is inert ──────────────────────────────────────────────────
# The key is commented, and the command, given the template, refuses before a request.
if ai_tools_conf_read "${TEMPLATE}" TYPESAFE_API_KEY && [[ -n "${_ai_tools_conf_value}" ]]; then
    fail "the shipped template sets TYPESAFE_API_KEY ('${_ai_tools_conf_value}') -- it ships with the key commented"
else
    pass "the shipped template leaves TYPESAFE_API_KEY commented"
fi
if ai_tools_conf_read "${TEMPLATE}" TYPESAFE_MODEL && [[ "${_ai_tools_conf_value}" =~ ^jev-[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pass "the shipped template pins a versioned model (${_ai_tools_conf_value}), not the moving alias"
else
    fail "the shipped template does not pin a versioned model (read '${_ai_tools_conf_value:-}')"
fi
if [[ -r "${CLI}" ]] && command -v node >/dev/null 2>&1; then
    mktestdir
    cp "${TEMPLATE}" "${TESTDIR}/typesafe.conf"; chmod 0600 "${TESTDIR}/typesafe.conf"
    set +e
    out="$(printf 'a:1: x\n' | node "${CLI}" filter --task t --config "${TESTDIR}/typesafe.conf" 2>"${TESTDIR}/err")"
    rc=$?
    set -e
    if [[ ${rc} -eq 3 && -z "${out}" && "$(cat "${TESTDIR}/err")" == "decide: configuration: "* ]]; then
        pass "given the shipped template, the command exits 3 (configuration) with no result and no request"
    else
        fail "given the shipped template, the command exited ${rc} (stdout '${out}', stderr '$(head -c 200 "${TESTDIR}/err")')"
    fi
else
    skip "template through the command" "decide.mjs or node not available"
fi

# ── 4. The vendored command is the pinned release ────────────────────────────────────────────────
# The modules and notices are a signed release's, unmodified: an edit here, or a file added or removed, reads as stale.
# Whether the pin itself names a release that verifies is the generator's `verify`, which needs the network and runs
# in CI.
GENERATOR="${ROOT}/tools/generators/typesafe-client.sh"
if [[ -r "${GENERATOR}" ]]; then
    if out="$(bash "${GENERATOR}" stale 2>&1)"; then
        pass "the vendored files match tools/generators/typesafe-client.pin"
    else
        fail "the vendored files do not match the pin: ${out}"
    fi
else
    skip "vendored files against the pin" "not a checkout (no ${GENERATOR})"
fi

finish
