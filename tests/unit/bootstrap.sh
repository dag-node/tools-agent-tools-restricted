#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/bootstrap.sh
# Unit test for report_shadowed_operators -- the lines `ai-tools-admin system bootstrap` closes with when an enrolled
# operator's shell would run an agent of the launcher's name from somewhere other than /usr/local/bin.
#
# What gives it teeth is that this report is the last thing said before a host is treated as ready. A run that named
# nobody on a shadowed host would state readiness over an operator whose next `claude` starts an UNCONFINED session
# as them, and one that named an account on every host would be read past. So both directions are driven, and so is
# what the report tells the operator to do: the message names the account, the launcher and the binary that wins,
# and the two ways out are the enrolment command that ranks the wrapper first and the path to remove.
#
# The reading underneath it is path-order.lib.sh's and is pinned in unit/path-order.sh; what this file covers is
# the composition -- which operators are asked about, what is printed per record, that finding a fault does not become
# this command's exit status, and that no init file is written.
#
# The helper is SOURCED, not run: it stops at the guard before its provisioning, so one function is driven with no
# toolchain to install. Each case runs in its own bash, because the helper and the harness both declare SANDBOX_USER
# readonly. The libraries are sourced BEFORE the stubs, so the include guard makes the helper's own `source` a no-op
# and the stubs stand; the helper reads them at their installed paths, so a host without them skips rather than driving
# a different library.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="/usr/local/libexec/ai-tools/ai-tools-bootstrap"
[[ -r "${HELPER}" ]] || HELPER="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-bootstrap.sh"
PATH_ORDER_LIB="/usr/local/lib/ai-tools/path-order.lib.sh"
OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# Where a second agent of the wrapper's name is found on a real host. This project's wrapper is /usr/local/bin/claude;
# what can win ahead of it is the operator's own `npm i -g` under their nvm, or the vendor package's /usr/bin/claude --
# the same file as /bin/claude, which is the spelling the reading prints where /bin is the usr-merge symlink and PATH
# carries that form. Each is outside /usr/local/bin, so each shadows the wrapper, and the report names the one the shell
# would run.
SHADOW_NVM="/home/op/.nvm/versions/node/v22.0.0/bin/claude"
SHADOW_PKG="/usr/bin/claude"
SHADOW_MERGED="/bin/claude"

section "ai-tools-admin system bootstrap: the shadowed-operator report (unit)"

if [[ ! -r "${HELPER}" ]]; then
    skip "shadowed-operator report" "helper not readable (neither installed nor in a checkout)"
    finish; exit
fi
if [[ ! -r "${PATH_ORDER_LIB}" || ! -r "${OPERATOR_LIB}" ]]; then
    skip "shadowed-operator report" "the helper reads ${PATH_ORDER_LIB} and ${OPERATOR_LIB}, which this host has not deployed"
    finish; exit
fi

mktestdir
READ_MARKER="${TESTDIR}/read-was-taken"
WRITE_MARKER="${TESTDIR}/init-was-rewritten"

# run_report <stub-code> -- drive one case and echo everything it said, with the function's own status on a last `rc=`
# line. The stubs land between the libraries and the helper, which is the one order in which they survive: sourced first
# they would be overwritten, and sourced after the helper they would not be in place when it runs.
run_report() {
    bash -c '
        set -euo pipefail
        # shellcheck source=/dev/null
        source "$1"
        # shellcheck source=/dev/null
        source "$2"
        eval "$4"
        # shellcheck source=/dev/null
        source "$3"
        declare -F report_shadowed_operators >/dev/null 2>&1 \
            || { printf "NO SUCH FUNCTION\n"; exit 0; }
        rc=0
        report_shadowed_operators || rc=$?
        printf "rc=%s\n" "${rc}"
    ' _ "${PATH_ORDER_LIB}" "${OPERATOR_LIB}" "${HELPER}" "$1" 2>&1 || true
}

# The stubs a case composes from. `stub_reading <state> <users> <winner>` answers for the named accounts
# with that winner and leaves every other account reading as a host whose ordering is right, so a case states
# which accounts are shadowed and by which binary rather than restating the reading. Each recording that a reading was
# taken at all, which is what (F) asserts the absence of.
stub_operators() { printf 'ai_tools_load_operators() { AI_TOOLS_OPERATORS=(%s); }\n' "$*"; }
stub_unenrolled() { printf 'ai_tools_load_operators() { AI_TOOLS_OPERATORS=(); return 1; }\n'; }
stub_reading() {
    printf '
ai_tools_path_order_read_user() {
    : > "%s"
    AI_TOOLS_PATH_ORDER_WINNERS=( "claude=${AI_TOOLS_PATH_ORDER_WRAPPER_DIR}/claude" )
    AI_TOOLS_PATH_ORDER_SHADOW=""
    AI_TOOLS_PATH_ORDER_STATE=%s
    for _shadowed in %s; do
        [[ "$1" == "${_shadowed}" ]] || continue
        AI_TOOLS_PATH_ORDER_SHADOW="%s"
        AI_TOOLS_PATH_ORDER_WINNERS=( "claude=${AI_TOOLS_PATH_ORDER_SHADOW}" )
        AI_TOOLS_PATH_ORDER_STATE=shadowed
        return 1
    done
    return 0
}
ai_tools_path_order_repoint_user() { : > "%s"; }
' "${READ_MARKER}" "${1:-wired}" "${2:-}" "${3:-}" "${WRITE_MARKER}"
}

# ── (A) Each shape of shadowing binary is named, as the shell would print it ──────────────────
out="$(run_report "$(stub_operators op; stub_reading wired op "${SHADOW_NVM}")")"
if [[ "${out}" == *"NO SUCH FUNCTION"* ]]; then
    fail "the helper does not define report_shadowed_operators when sourced"
    finish; exit 1
fi
for winner in "${SHADOW_NVM}" "${SHADOW_PKG}" "${SHADOW_MERGED}"; do
    out="$(run_report "$(stub_operators op; stub_reading wired op "${winner}")")"
    assert_msg MSG-K2D4 "${out}" "an agent at ${winner} is reported at its own message code"
    if grep -qF "operator op who types claude would run ${winner}" <<<"${out}"; then
        pass "the message names the account, the launcher and ${winner}"
    else
        fail "the message does not name what the operator has to act on (${out})"
    fi
done

# ── (B) Both ways out are named, against the vendor package's own path ───────────────────────
out="$(run_report "$(stub_operators op; stub_reading wired op "${SHADOW_PKG}")")"
if grep -qF "sudo ai-tools-admin operators add op" <<<"${out}"; then
    pass "the first way out is the enrolment command that ranks the wrapper first"
else
    fail "the report does not name the command that fixes the ordering (${out})"
fi
if grep -qF "or remove that install:        ${SHADOW_PKG}" <<<"${out}"; then
    pass "the second way out names the install to remove"
else
    fail "the report does not offer removing the agent that wins (${out})"
fi

# ── (C) A fault the host owns is not this command's exit status ──────────────────────────────
# The provisioning succeeded; what the report found is a state of the operator's shell, and a non-zero status here would
# report the toolchain install as failed.
if grep -qx 'rc=0' <<<"${out}"; then
    pass "a report that found a shadowed operator still returns 0"
else
    fail "the report returned non-zero for a fault it only reports ($(grep '^rc=' <<<"${out}"))"
fi

# ── (D) It does not rewrite an init file ─────────────────────────────────────────────────────────────
# `operators add` is this project's one writer of the guard line, behind its confirm; a report that repointed on its own
# would edit an operator's home without asking.
if [[ ! -e "${WRITE_MARKER}" ]]; then
    pass "the report does not reach an init-file write"
else
    fail "the report called the repoint, which belongs to operators add"
fi

# ── (E) Every enrolled operator is asked about ───────────────────────────────────────────────
out="$(run_report "$(stub_operators op two; stub_reading wired "op two" "${SHADOW_PKG}")")"
if [[ "$(grep -c '^MSG-K2D4$' <<<"${out}")" -eq 2 ]]; then
    pass "each shadowed operator is named by a record of its own"
else
    fail "the report does not carry one record per shadowed operator (${out})"
fi

# ── (F) Every other state is silence ─────────────────────────────────────────────────────────
# A host whose ordering is right, and one whose reading could not be taken, are the runs an operator sees most; a line
# on either teaches them to read past the one that matters.
for state in wired clear unknown; do
    out="$(run_report "$(stub_operators op; stub_reading "${state}" "" "")")"
    if grep -q 'MSG-K2D4' <<<"${out}"; then
        fail "named an operator whose ordering read as ${state}"
        break
    fi
done
if ! grep -q 'MSG-K2D4' <<<"${out}"; then
    pass "an operator who reaches the wrapper is named by no line, whatever the state"
fi

# ── (G) An unenrolled host asks about nobody ─────────────────────────────────────────────────
# Bootstrap runs before the first enrolment as often as after it, and a reading is a login shell per account: with no
# operator recorded there is no account to read and none to name.
rm -f "${READ_MARKER}"
out="$(run_report "$(stub_unenrolled; stub_reading wired op "${SHADOW_PKG}")")"
if grep -q 'MSG-K2D4' <<<"${out}"; then
    fail "named an operator on a host that has enrolled none (${out})"
elif [[ -e "${READ_MARKER}" ]]; then
    fail "took a login-shell reading with no operator enrolled"
else
    pass "an unenrolled host is neither read nor reported on"
fi

# ── choose_agents: which agents the run provisions, decided before the first network step ─────
# No agent ships enabled, so this is the step that makes a host run one, and every input it reads is driven in its fail
# direction: an unanswered menu, "none" chosen, and an untrusted config each leave the key unwritten and the run at exit
# 0 (Node alone); an unknown `--agents` name refuses with the key unwritten; a present key is not asked about and a key
# naming more than one agent gets the shared-account notice once; the chosen or given names land in the file
# the resolver reads. The manifests are a synthetic pair (no shipped agent is named, so a literal name in the code path
# fails here), root-owned because the resolver trusts root-owned manifests alone -- so this section runs as root
# and skips otherwise. The menu is stubbed: a drawn menu would block on /dev/tty, and which index it returns is
# the library's own test (unit/msg.sh).
section "ai-tools-admin system bootstrap: the agent choice (unit)"

PROVIDERS_LIB="/usr/local/lib/ai-tools/providers.lib.sh"
MSG_LIB="/usr/local/lib/ai-tools/msg.lib.sh"
if [[ "${EUID}" -ne 0 ]]; then
    skip "agent choice" "the resolver trusts root-owned manifests alone; run as root"
elif [[ ! -r "${PROVIDERS_LIB}" || ! -r "${MSG_LIB}" ]]; then
    skip "agent choice" "the helper reads ${PROVIDERS_LIB} and ${MSG_LIB}, which this host has not deployed"
else
    AGENTS_DIR="${TESTDIR}/agents.d"
    CONF_DIR="${TESTDIR}/etc"
    CONF="${CONF_DIR}/operator.conf"
    PICK_MARKER="${TESTDIR}/menu-was-drawn"
    install -d -o root -g root -m 755 "${AGENTS_DIR}" "${CONF_DIR}"
    printf 'npm_package=@acme/experimental\nlauncher=acme\ndisplay_name=Acme\ndefault_enable=no\n' > "${AGENTS_DIR}/acme.conf"
    printf 'npm_package=@acme/beta\nlauncher=beta\ndisplay_name=Beta\ndefault_enable=no\n'         > "${AGENTS_DIR}/beta.conf"
    chmod 0644 "${AGENTS_DIR}"/*.conf
    export AI_TOOLS_AGENTS_DIR="${AGENTS_DIR}" AI_TOOLS_OPERATOR_CONF="${CONF}"

    # The shipped template's shape: the key commented under its block, so an in-place rewrite is observable.
    seed_conf() {
        rm -f "${PICK_MARKER}"
        printf '%s\n' '# host options' 'OPERATORS="op"' '' '# The agents this host runs.' "${1:-#AI_TOOLS_AGENTS=\"\"}" > "${CONF}"
        chmod 0644 "${CONF}"; chown root:root "${CONF}"
    }
    # stub_pick <index|none> : the menu answers <index>, or ends unanswered (no terminal, closed input, three misses)
    # on `none`. Either way it records that it was drawn, which is what the not-asked cases assert against.
    stub_pick() {
        printf 'ai_tools_msg_pick() { : > "%s"; [[ "%s" == none ]] && return 1; printf "%%s" "%s"; }\n' \
            "${PICK_MARKER}" "$1" "$1"
        printf 'ai_tools_msg_block() { :; }\n'
    }
    # run_choose <stub-code> <requested> : drive choose_agents in its own bash and echo what it said,
    # with the function's status on a last `rc=` line -- absent when a die ended the shell. The libraries are sourced
    # before the stubs, so the helper's own require_msg_lib re-source is a no-op under the include guard and the stub
    # stands.
    run_choose() {
        bash -c '
            set -euo pipefail
            # shellcheck source=/dev/null
            source "$1"
            # shellcheck source=/dev/null
            source "$2"
            eval "$4"
            # shellcheck source=/dev/null
            source "$3"
            declare -F choose_agents >/dev/null 2>&1 || { printf "NO SUCH FUNCTION\n"; exit 0; }
            rc=0
            choose_agents "$5" || rc=$?
            printf "rc=%s\n" "${rc}"
        ' _ "${PROVIDERS_LIB}" "${MSG_LIB}" "${HELPER}" "$1" "$2" 2>&1 || true
    }
    key_value() { AI_TOOLS_OPERATOR_CONF="${CONF}" bash -c 'source "$1"; ai_tools_conf_get "$2" AI_TOOLS_AGENTS' _ "${PROVIDERS_LIB}" "${CONF}" 2>/dev/null || true; }
    key_present() { grep -qE '^[[:space:]]*AI_TOOLS_AGENTS[[:space:]]*=' "${CONF}"; }

    # ── (H) An unanswered menu does not enable an agent and does not fail the run ─────────────
    seed_conf
    out="$(run_choose "$(stub_pick none)" "")"
    if [[ "${out}" == *"NO SUCH FUNCTION"* ]]; then
        fail "the helper does not define choose_agents when sourced"
    else
        assert_msg MSG-X3M9 "${out}" "an unanswered menu is reported as no agent chosen"
        if grep -qx 'rc=0' <<<"${out}" && ! key_present && [[ -e "${PICK_MARKER}" ]]; then
            pass "an unanswered menu leaves the key unwritten and returns 0 (Node alone)"
        else
            fail "unanswered menu: $(grep '^rc=' <<<"${out}" || echo 'no rc'), key present=$(key_present && echo yes || echo no), drawn=$([[ -e "${PICK_MARKER}" ]] && echo yes || echo no)"
        fi
        if grep -qF 'sudo ai-tools-admin system bootstrap' <<<"${out}"; then
            pass "the warning names the re-run"
        else
            fail "the warning does not name the re-run (${out})"
        fi

        # ── (I) The chosen agent is written in place, and one agent does not draw a notice ─────
        seed_conf
        out="$(run_choose "$(stub_pick 2)" "")"
        if grep -qx 'rc=0' <<<"${out}" && [[ "$(key_value)" == "beta" ]]; then
            pass "the chosen option's agent is written as AI_TOOLS_AGENTS"
        else
            fail "chose 2 (beta): $(grep '^rc=' <<<"${out}" || echo 'no rc'), key '$(key_value)' (${out})"
        fi
        if [[ "$(grep -c 'AI_TOOLS_AGENTS' "${CONF}")" -eq 1 && "$(wc -l < "${CONF}")" -eq 5 ]]; then
            pass "the commented default is rewritten in place under its comment block"
        else
            fail "the write did not land in place: $(tr '\n' '|' < "${CONF}")"
        fi
        if ! grep -q 'MSG-C8W2' <<<"${out}"; then
            pass "one agent chosen draws no shared-account notice"
        else
            fail "a single agent drew the shared-account notice"
        fi

        # ── (N) "None now" is the last option and does not enable an agent ───────────────────
        seed_conf
        out="$(run_choose "$(stub_pick 3)" "")"
        assert_msg MSG-X3M9 "${out}" "the none option is reported as no agent chosen"
        if grep -qx 'rc=0' <<<"${out}" && ! key_present; then
            pass "the none option leaves the key unwritten and returns 0"
        else
            fail "none option: $(grep '^rc=' <<<"${out}" || echo 'no rc'), key present=$(key_present && echo yes || echo no)"
        fi

        # ── (J) A present key is the operator's declaration: no menu ─────────────────────────
        seed_conf 'AI_TOOLS_AGENTS="acme"'
        out="$(run_choose "$(stub_pick 2)" "")"
        if grep -qx 'rc=0' <<<"${out}" && [[ ! -e "${PICK_MARKER}" && "$(key_value)" == "acme" ]]; then
            pass "a key naming one agent is left as written and no menu is drawn"
        else
            fail "present key: $(grep '^rc=' <<<"${out}" || echo 'no rc'), drawn=$([[ -e "${PICK_MARKER}" ]] && echo yes || echo no), key '$(key_value)'"
        fi
        if ! grep -q 'MSG-C8W2' <<<"${out}"; then
            pass "a key naming one agent draws no shared-account notice"
        else
            fail "a single-agent key drew the shared-account notice"
        fi

        # ── (K) A key naming more than one agent gets the notice, once, and no menu ──────────
        seed_conf 'AI_TOOLS_AGENTS="acme beta"'
        out="$(run_choose "$(stub_pick 2)" "")"
        assert_msg MSG-C8W2 "${out}" "a key naming two agents draws the shared-account notice"
        if [[ "$(grep -c '^MSG-C8W2$' <<<"${out}")" -eq 1 && ! -e "${PICK_MARKER}" && "$(key_value)" == "acme beta" ]]; then
            pass "the notice is printed once, the key is left as written, no menu is drawn"
        else
            fail "two-agent key: notices=$(grep -c '^MSG-C8W2$' <<<"${out}"), drawn=$([[ -e "${PICK_MARKER}" ]] && echo yes || echo no), key '$(key_value)'"
        fi

        # ── (L) `--agents` writes the names given, notice once, no menu ───────────────────────
        seed_conf
        out="$(run_choose "$(stub_pick 2)" "beta,acme")"
        if grep -qx 'rc=0' <<<"${out}" && [[ "$(key_value)" == "beta acme" && ! -e "${PICK_MARKER}" ]]; then
            pass "--agents writes both names in the shared list grammar and draws no menu"
        else
            fail "--agents beta,acme: $(grep '^rc=' <<<"${out}" || echo 'no rc'), key '$(key_value)', drawn=$([[ -e "${PICK_MARKER}" ]] && echo yes || echo no)"
        fi
        if [[ "$(grep -c '^MSG-C8W2$' <<<"${out}")" -eq 1 ]]; then
            pass "--agents naming two agents draws the shared-account notice once"
        else
            fail "--agents naming two agents drew the notice $(grep -c '^MSG-C8W2$' <<<"${out}") time(s)"
        fi
        seed_conf 'AI_TOOLS_AGENTS="acme beta"'
        out="$(run_choose "$(stub_pick 2)" "acme")"
        if grep -qx 'rc=0' <<<"${out}" && [[ "$(key_value)" == "acme" ]] && ! grep -q 'MSG-C8W2' <<<"${out}"; then
            pass "--agents replaces a present key with the names given, and one name draws no notice"
        else
            fail "--agents acme over a two-agent key: key '$(key_value)' (${out})"
        fi

        # ── (M) An unknown `--agents` name refuses with the key unwritten ────────────────────
        seed_conf
        out="$(run_choose "$(stub_pick 2)" "acme,bogus")"
        assert_msg MSG-M2N6 "${out}" "a name with no installed manifest is refused under its code"
        if ! grep -q '^rc=' <<<"${out}" && ! key_present && [[ ! -e "${PICK_MARKER}" ]]; then
            pass "the refusal ends the run with the key unwritten and no menu drawn"
        else
            fail "unknown name: $(grep '^rc=' <<<"${out}" || echo 'run ended'), key present=$(key_present && echo yes || echo no), drawn=$([[ -e "${PICK_MARKER}" ]] && echo yes || echo no)"
        fi
        if grep -qF 'bogus' <<<"${out}" && grep -qF 'acme beta' <<<"${out}"; then
            pass "the refusal names the unknown name and the installed set"
        else
            fail "the refusal does not name what was unknown against what is installed (${out})"
        fi
        seed_conf
        out="$(run_choose "$(stub_pick 2)" ",")"
        assert_msg MSG-X8K6 "${out}" "a value naming no agent is refused as a valueless --agents"

        # ── (O) An untrusted operator.conf is neither asked about nor written ────────────────
        seed_conf
        chmod 0666 "${CONF}"
        out="$(run_choose "$(stub_pick 2)" "")"
        if grep -qx 'rc=0' <<<"${out}" && [[ ! -e "${PICK_MARKER}" ]] && ! key_present; then
            pass "an untrusted operator.conf draws no menu and takes no write"
        else
            fail "untrusted config: $(grep '^rc=' <<<"${out}" || echo 'no rc'), drawn=$([[ -e "${PICK_MARKER}" ]] && echo yes || echo no), key present=$(key_present && echo yes || echo no)"
        fi
        chmod 0644 "${CONF}"

        # ── (P) No manifest installed: no menu, Node alone ────────────────────────────────────
        seed_conf
        empty_dir="${TESTDIR}/empty.d"; install -d -o root -g root -m 755 "${empty_dir}"
        out="$(AI_TOOLS_AGENTS_DIR="${empty_dir}" run_choose "$(stub_pick 1)" "")"
        if grep -qx 'rc=0' <<<"${out}" && [[ ! -e "${PICK_MARKER}" ]] && ! key_present; then
            pass "a host with no agent manifest is not asked and provisions Node alone"
        else
            fail "no manifests: $(grep '^rc=' <<<"${out}" || echo 'no rc'), drawn=$([[ -e "${PICK_MARKER}" ]] && echo yes || echo no)"
        fi
        out="$(AI_TOOLS_AGENTS_DIR="${empty_dir}" run_choose "$(stub_pick 1)" "acme")"
        assert_msg MSG-M2N6 "${out}" "--agents on a host with no manifest is refused, naming none installed"
    fi
    unset AI_TOOLS_AGENTS_DIR AI_TOOLS_OPERATOR_CONF
fi

# ── remove_residue: the order it runs in ─────────────────────────────────────────────────────
# The removal of a disabled agent's package sits after the agent choice (it reads the set that choice wrote) and ahead
# of the first network step (the nvm version resolve), so an offline host still cleans up before its npm step fails.
# That is a property of the SCRIPT's provisioning sequence, which the sourced-guard keeps this file from running, so it
# is read as source order, the way unit/launcher-target.sh reads the re-link's; the routine itself is driven
# in unit/toolchain.sh. Outside a checkout there is no script to read and the section skips.
section "ai-tools-admin system bootstrap: the residue removal's place in the sequence (unit)"
SCRIPT="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-bootstrap.sh"
if [[ ! -d "${ROOT}/.git" || ! -r "${SCRIPT}" ]]; then
    skip "the removal precedes the network step" "not a checkout, so the helper cannot be read from the repository"
else
    choose_line="$(grep -n -m1 -E '^choose_agents "\$\{REQUESTED_AGENTS\}"' "${SCRIPT}" | cut -d: -f1)"
    remove_line="$(grep -n -m1 -E '^remove_residue$' "${SCRIPT}" | cut -d: -f1)"
    resolve_line="$(grep -n -m1 -E '^NVM_VERSION="\$\(resolve_nvm_version\)"' "${SCRIPT}" | cut -d: -f1)"
    if [[ -z "${choose_line}" || -z "${remove_line}" || -z "${resolve_line}" ]]; then
        fail "the agent choice, the removal or the version resolve is no longer where this reads it (choice -> ${choose_line:-none}, removal -> ${remove_line:-none}, resolve -> ${resolve_line:-none})"
    elif (( choose_line < remove_line && remove_line < resolve_line )); then
        pass "the residue removal runs after the agent choice and before the first network step"
    else
        fail "the residue removal is out of place: choice at ${choose_line}, removal at ${remove_line}, resolve at ${resolve_line}"
    fi
fi

finish
