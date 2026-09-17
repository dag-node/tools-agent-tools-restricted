#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/cli-agent-set.sh
# Unit test for the ai-tools CLI's provisioning gate and the report beside it (require_bootstrap, status_provisioning).
# Both read the ENABLED agents through providers.lib.sh and key on each agent's stable launcher symlink, so the CLI does
# not name an agent of its own. Each read is asserted in its fail direction: any enabled agent's link passes the gate;
# an enabled set with no link refuses, naming the bootstrap command; an empty enabled set refuses with the resolver's
# reason -- a configuration asking for no agent, an allowlisted name with no manifest, an input the trust predicate
# refused -- with a link present, since the gate reads the set before the link; and the report says per agent
# what the gate decided.
#
# The CLI carries a sourced-guard, so this loads it as the projects user (it refuses root and the sandbox account)
# with three hooks pointed at fixtures in the testdir: AI_TOOLS_AGENTS_DIR and AI_TOOLS_OPERATOR_CONF (the resolver's,
# the pattern unit/providers.sh uses) and AI_TOOLS_LAUNCHER_DIR (the link directory, the hook relabel.lib.sh reads
# for the same directory). Fixtures are root-owned, 0644 and 0755 -- anything else the trust predicate refuses,
# which one case drives on purpose. Run as root via sudo (suite contract); no agent package needs to be installed.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root
umask 022

readonly CLI="/usr/local/bin/ai-tools"
section "cli: the provisioning gate reads the enabled agents (unit)"

if [[ ! -x "${CLI}" ]]; then skip "cli agent set" "CLI not installed at ${CLI}"; finish; exit; fi
if ! command -v runuser >/dev/null 2>&1; then skip "cli agent set" "runuser unavailable"; finish; exit; fi
# shellcheck disable=SC2016  # the $1 is for the inner `bash -c`, not this shell -- do not expand here
if ! runuser -u "${PROJECTS_USER}" -- bash -c \
        'set --; source "$1" >/dev/null 2>&1; declare -F require_bootstrap >/dev/null 2>&1 \
            && declare -F status_provisioning >/dev/null 2>&1' _ "${CLI}"; then
    skip "cli agent set" "CLI not sourceable or the gate absent (partial install?)"; finish; exit
fi

mktestdir
AGENTS_DIR="${TESTDIR}/agents.d"; CONF="${TESTDIR}/operator.conf"; LINKS="${TESTDIR}/bin"
mkdir -m 0755 "${AGENTS_DIR}" "${LINKS}"

# manifest <name> <launcher> <default_enable> : one agent manifest, root-owned 0644, so the trust predicate admits it.
manifest() {
    printf 'npm_package=@fixture/%s\nlauncher=%s\ndefault_enable=%s\n' "$1" "$2" "$3" > "${AGENTS_DIR}/$1.conf"
    chmod 0644 "${AGENTS_DIR}/$1.conf"
}
# operator_conf [line] : the operator.conf fixture -- OPERATORS naming the projects user, as mk_operator writes it, plus
# one optional line (an AI_TOOLS_AGENTS allowlist).
operator_conf() {
    { printf 'OPERATORS="%s"\n' "${PROJECTS_USER}"; [[ $# -gt 0 ]] && printf '%s\n' "$1"; } > "${CONF}"
    chmod 0644 "${CONF}"
}
# link <launcher> : the stable launcher symlink bootstrap writes last. Dangling on purpose: the gate reads it with `-L`.
link() { ln -s "/nonexistent/${1}" "${LINKS}/${1}"; }
reset_fixtures() { rm -f "${AGENTS_DIR}"/*.conf "${LINKS}"/*; chmod 0755 "${AGENTS_DIR}"; operator_conf; }

# call <function> : source the CLI as the projects user with the three hooks set and run one of its functions; both
# streams on stdout, the function's exit status returned. AI_TOOLS_MSG_PLAIN keeps a refusal's code on its own line.
# shellcheck disable=SC2016  # the $1/$2 are for the inner `bash -c`, not this shell -- do not expand here
call() {
    runuser -u "${PROJECTS_USER}" -- env \
        AI_TOOLS_AGENTS_DIR="${AGENTS_DIR}" AI_TOOLS_OPERATOR_CONF="${CONF}" AI_TOOLS_LAUNCHER_DIR="${LINKS}" \
        AI_TOOLS_MSG_PLAIN=1 \
        bash -c 'set --; source "$1" >/dev/null 2>&1 || exit 99; "$2"' _ "${CLI}" "$1" 2>&1
}
# refused <what> <code> <rc> <output> : a refusal is its code AND a non-zero status -- a refusal printed at exit 0 is
# one the dispatch would read as a pass.
refused() {
    local what="$1" code="$2" rc="$3" out="$4"
    if [[ "${rc}" -eq 0 ]]; then fail "${what}: exit 0 (the gate passed): $(head -c 200 <<<"${out}" | tr '\n' '|')"
    else assert_msg "${code}" "${out}" "${what}"; fi
}
# passed <what> <rc> <output>
passed() {
    if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1: rc $2: $(head -c 200 <<<"$3" | tr '\n' '|')"; fi
}
# says <what> <pattern> <output> : the output carries the content a refusal or a report owes the reader.
says() {
    if grep -q -- "$2" <<<"$3"; then pass "$1"; else fail "$1: '$2' absent: $(head -c 300 <<<"$3" | tr '\n' '|')"; fi
}

# ── (1) Any enabled agent's launcher symlink passes ─────────────────────────────
reset_fixtures; manifest alpha la yes; link la
rc=0; out="$(call require_bootstrap)" || rc=$?
passed "one enabled agent with its launcher symlink passes the gate" "${rc}" "${out}"

reset_fixtures; manifest alpha la yes; manifest beta lb yes; link lb
rc=0; out="$(call require_bootstrap)" || rc=$?
passed "a link for either of two enabled agents passes the gate (the CLI names no agent)" "${rc}" "${out}"

# ── (2) An enabled set with no link refuses, naming the agents and the bootstrap command ──
reset_fixtures; manifest alpha la yes; manifest beta lb yes
rc=0; out="$(call require_bootstrap)" || rc=$?
refused "two enabled agents with no launcher symlink are refused" MSG-X9H7 "${rc}" "${out}"
if grep -q 'alpha' <<<"${out}" && grep -q 'beta' <<<"${out}" && grep -q 'system bootstrap' <<<"${out}"; then
    pass "the refusal names each unprovisioned agent and the bootstrap command"
else
    fail "the refusal does not name both agents and the bootstrap command: $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi

# ── (3) An empty enabled set refuses with the resolver's reason, a link present notwithstanding ──

# The allowlist is exact: the gate reads the enabled set before any link, so a link for an agent the operator did not
# enable does not pass it.
reset_fixtures; manifest alpha la yes; link la; operator_conf 'AI_TOOLS_AGENTS='
rc=0; out="$(call require_bootstrap)" || rc=$?
refused "an empty AI_TOOLS_AGENTS refuses with a link present" MSG-K7A6 "${rc}" "${out}"
says "the empty-allowlist refusal carries the resolver's reason" 'set and empty' "${out}"

reset_fixtures; manifest alpha la yes; link la; operator_conf 'AI_TOOLS_AGENTS=ghost'
rc=0; out="$(call require_bootstrap)" || rc=$?
refused "an allowlisted name with no manifest refuses with a link present" MSG-K7A6 "${rc}" "${out}"
says "the uninstalled-name refusal names the name" 'ghost' "${out}"

# A manifest directory a non-root writer could plant in does not yield an agent, so the gate refuses -- less access,
# reported -- where a reader of the link alone would have passed.
reset_fixtures; manifest alpha la yes; link la; chmod 0777 "${AGENTS_DIR}"
rc=0; out="$(call require_bootstrap)" || rc=$?
refused "a group-writable manifest directory refuses with a link present" MSG-K7A6 "${rc}" "${out}"
says "the untrusted-directory refusal names the trust check" 'trust check' "${out}"

# ── (4) `status` reports the same read, per agent ───────────────────────────────
reset_fixtures; manifest alpha la yes; manifest beta lb yes; link la
rc=0; out="$(call status_provisioning)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -qF 'alpha provisioned (la)' <<<"${out}" && grep -qF 'beta not provisioned' <<<"${out}"; then
    pass "status reports each enabled agent as provisioned or not, by its own link"
else
    fail "status provisioning lines (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi
says "the unprovisioned line names the bootstrap command" 'system bootstrap' "${out}"

reset_fixtures; operator_conf 'AI_TOOLS_AGENTS='
rc=0; out="$(call status_provisioning)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q 'no agent enabled' <<<"${out}"; then
    pass "status reports an empty enabled set as such, without counting it as a fault"
else
    fail "status on an empty enabled set (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi

finish
