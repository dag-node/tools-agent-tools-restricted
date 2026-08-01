#!/usr/bin/env bash
# tests/unit/postupgrade.sh
# Hermetic unit test for `ai-tools-admin postupgrade`: the reconciliation of the .rpmnew copies an
# upgrade leaves beside the %config(noreplace) files this stack owns.
#
# Worth pinning because the command edits an operator-owned control-plane file and because its
# three treatments are what lets an operator predict it. The assertions therefore ask, per file,
# which treatment it got: the settings JSON is MERGED (each shipped declaration the kept file
# lacks arrives, the permission rules the file was kept for survive, a dated .bak lands first, and
# every addition is named), operator.conf is REPORTED and byte-identical afterwards, and the
# sudoers grant is SHOWN and neither written nor dropped -- its fixture here is a grant of
# everything to everyone, the one a silent adoption would be worst for. The .rpmnew cleanup is the
# fourth property: it defaults to yes only once the two files match, so a copy still carrying
# something to review survives the run.
#
# Drives the DEPLOYED helper against fixtures in the testdir through AI_TOOLS_POSTUPGRADE_ROOT,
# the root-only path hook (like AI_TOOLS_ALLOWLIST): the live control plane is never read, written
# or listed. Every run is under setsid, so each prompt is answered by its own default -- which is
# both what an unattended host gets and what makes the run reproducible.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/sbin/ai-tools/ai-tools-admin"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHIPPED_SETTINGS="${REPO_ROOT}/src/opt/ai-tools/agents/claude-code/settings.json"

section "ai-tools-admin postupgrade: .rpmnew reconciliation (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "postupgrade" "not installed at ${HELPER}"; finish; exit
elif [[ ! -r "${SHIPPED_SETTINGS}" ]]; then
    skip "postupgrade" "needs the shipped settings.json from the checkout"; finish; exit
elif ! command -v jq >/dev/null 2>&1; then
    fail "jq is missing -- it is a package dependency of the agent package"; finish; exit
fi

mktestdir
ROOT="${TESTDIR}/root"
SETTINGS="${ROOT}/opt/ai-tools/.claude/settings.json"
CONF="${ROOT}/etc/ai-tools/operator.conf"
SUDOERS="${ROOT}/etc/sudoers.d/ai-tools"

# Each case starts from an empty prefix root, so no case inherits another's leftovers.
reset_root() {
    rm -rf "${ROOT}"
    mkdir -p "${ROOT}/opt/ai-tools/.claude" "${ROOT}/etc/ai-tools" "${ROOT}/etc/sudoers.d"
}

# Run the deployed command against the fixture root and echo everything it said.
run_pu() {
    setsid env AI_TOOLS_POSTUPGRADE_ROOT="${ROOT}" "${HELPER}" postupgrade < /dev/null 2>&1 || true
}

# The sidecars the run left beside a file, as a count -- a keyval file must gain none.
sidecars() {
    local file="$1" found=()
    shopt -s nullglob
    found=( "${file}".*.bak "${file}".*.shipped )
    shopt -u nullglob
    printf '%d' "${#found[@]}"
}

declares() {
    jq -e --arg e "$2" --arg c "$3" \
        '[.hooks[$e][]?.hooks[]?.command] | index($c) != null' "$1" >/dev/null 2>&1
}

# ── (A) Nothing waiting ───────────────────────────────────────────────────────────────────────
# Doubles as the probe for a deployed helper that predates the subcommand: it dies on an unknown
# subcommand instead of reporting a reconciled host.
reset_root
cp "${SHIPPED_SETTINGS}" "${SETTINGS}"
printf 'OPERATORS="root"\n' > "${CONF}"
before="$(md5sum "${SETTINGS}" "${CONF}")"
out="$(run_pu)"
if [[ "${out}" != *"no .rpmnew"* ]]; then
    skip "postupgrade" "deployed ai-tools-admin predates the subcommand -- re-run sudo ./install.sh install"
    finish; exit
fi
if [[ "$(md5sum "${SETTINGS}" "${CONF}")" == "${before}" ]]; then
    pass "a host with no .rpmnew is reported reconciled and nothing is touched"
else
    fail "a file with no .rpmnew beside it was modified"
fi

# ── (B) settings.json: the merge that carries a newly shipped hook onto a kept file ───────────
reset_root
jq 'del(.hooks.PreToolUse) | .permissions.deny += ["Bash(hosttuned:*)"]' \
    "${SHIPPED_SETTINGS}" > "${SETTINGS}"
cp "${SHIPPED_SETTINGS}" "${SETTINGS}.rpmnew"
cp "${SETTINGS}" "${TESTDIR}/pre-merge.json"
shipped_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "${SHIPPED_SETTINGS}")"
out="$(run_pu)"

if declares "${SETTINGS}" PreToolUse "${shipped_cmd}"; then
    pass "the declaration the kept file lacked arrives"
else
    fail "PreToolUse '${shipped_cmd}' is still undeclared after the merge"
fi
if jq -e '[.permissions.deny[]] | index("Bash(hosttuned:*)") != null' "${SETTINGS}" >/dev/null 2>&1 \
        && declares "${SETTINGS}" PostToolUse "$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "${SHIPPED_SETTINGS}")"; then
    pass "the host's own deny entry and its existing hooks survive the merge"
else
    fail "the merge did not preserve the file it was kept for"
fi
if [[ "${out}" == *"+ PreToolUse: ${shipped_cmd}"* ]]; then
    pass "every addition is named, so the edit is reviewable in the run's output"
else
    fail "the run did not name the declaration it added"
fi

shopt -s nullglob
baks=( "${SETTINGS}".*.bak )
shopt -u nullglob
if [[ ${#baks[@]} -eq 1 ]] && cmp -s "${baks[0]}" "${TESTDIR}/pre-merge.json"; then
    pass "a dated .bak holds exactly what the operator had before the merge"
else
    fail "the pre-merge file was not backed up (found ${#baks[@]} .bak copies)"
fi
if [[ ${#baks[@]} -eq 1 && "${out}" == *"${baks[0]}"* ]]; then
    pass "the backup is named in the output, not just written"
else
    fail "the run did not name the backup it wrote"
fi
if [[ -f "${SETTINGS}.rpmnew" ]]; then
    pass "the copy is kept while the permission rules still differ"
else
    fail "dropped a .rpmnew that still had a difference to review"
fi

# The command claims to be idempotent, and an operator re-runs it: a second pass merges nothing
# and writes no second backup.
out="$(run_pu)"
shopt -s nullglob
baks_again=( "${SETTINGS}".*.bak )
shopt -u nullglob
if [[ "${out}" == *"already current"* && ${#baks_again[@]} -eq ${#baks[@]} ]]; then
    pass "a re-run merges nothing and writes no second backup"
else
    fail "the re-run was not a no-op (${#baks_again[@]} backups, expected ${#baks[@]})"
fi

# ── (C) settings.json: hooks already current ─────────────────────────────────────────────────
reset_root
jq '.permissions.deny += ["Bash(hosttuned:*)"]' "${SHIPPED_SETTINGS}" > "${SETTINGS}"
cp "${SHIPPED_SETTINGS}" "${SETTINGS}.rpmnew"
before="$(md5sum < "${SETTINGS}")"
out="$(run_pu)"
if [[ "${out}" == *"already current"* && "$(md5sum < "${SETTINGS}")" == "${before}" \
        && "$(sidecars "${SETTINGS}")" == 0 && -f "${SETTINGS}.rpmnew" ]]; then
    pass "a file already declaring everything shipped is left byte-identical"
else
    fail "a current file was rewritten, backed up, or lost its .rpmnew"
fi

# ── (D) The cleanup prompt defaults to yes only once nothing is left ─────────────────────────
reset_root
jq . "${SHIPPED_SETTINGS}" > "${SETTINGS}.rpmnew"
cp "${SETTINGS}.rpmnew" "${TESTDIR}/canonical.json"
jq '.hooks.PostToolUse = [ .hooks.PostToolUse[0] ]' "${TESTDIR}/canonical.json" > "${SETTINGS}"
out="$(run_pu)"
if [[ ! -e "${SETTINGS}.rpmnew" ]] && cmp -s "${SETTINGS}" "${TESTDIR}/canonical.json"; then
    pass "a merge that leaves the two files identical clears the copy"
else
    fail "kept a .rpmnew that had nothing left to say"
fi

# ── (E) operator.conf: reported, never written ───────────────────────────────────────────────
reset_root
cat > "${CONF}" <<'CONF'
# The host's own file, as an upgrade found it.
OPERATORS="root"
#EXISTING_OPTION="a"
CONF
cat > "${CONF}.rpmnew" <<'CONF'
# The template this version ships.
#OPERATORS=""
#EXISTING_OPTION="a"

# The option this version introduces.
#NEW_OPTION="b"
CONF
cp "${CONF}" "${TESTDIR}/pre.conf"
out="$(run_pu)"

if grep -qE '^ai-tools-admin: +NEW_OPTION$' <<< "${out}"; then
    pass "an option the kept file never mentions is named"
else
    fail "the new option was not reported"
fi
if ! grep -qE '^ai-tools-admin: +EXISTING_OPTION$' <<< "${out}"; then
    pass "an option the operator has already commented out is not re-announced"
else
    fail "re-announced an option the file already mentions"
fi
if cmp -s "${CONF}" "${TESTDIR}/pre.conf" && [[ "$(sidecars "${CONF}")" == 0 ]]; then
    pass "the file is byte-identical afterwards and gains no sidecar"
else
    fail "a KEY=value config was rewritten or backed up"
fi
if [[ -f "${CONF}.rpmnew" ]]; then
    pass "the copy to merge from is kept for the operator's own edit"
else
    fail "dropped the .rpmnew an operator still has to merge by hand"
fi

# ── (F) The sudoers grant: shown, never adopted ──────────────────────────────────────────────
reset_root
printf '%%ai-ops ALL=(ai-tools:ai-tools) NOPASSWD: /opt/ai-tools/bin/ai-tools-run\n' > "${SUDOERS}"
printf '%%ai-ops ALL=(ALL) NOPASSWD: ALL\n' > "${SUDOERS}.rpmnew"
cp "${SUDOERS}" "${TESTDIR}/pre.sudoers"
out="$(run_pu)"
if cmp -s "${SUDOERS}" "${TESTDIR}/pre.sudoers"; then
    pass "the deployed sudo grant is never rewritten from a .rpmnew"
else
    fail "adopted a packaged sudoers file without the operator"
fi
if [[ -f "${SUDOERS}.rpmnew" && "${out}" == *"visudo -c -f"* ]]; then
    pass "the packaged grant is shown with the check to run before adopting it"
else
    fail "the sudoers copy was dropped or shown without its verification step"
fi

# ── (G) Dispatch ─────────────────────────────────────────────────────────────────────────────
reset_root
if out="$(setsid env AI_TOOLS_POSTUPGRADE_ROOT="${ROOT}" "${HELPER}" postupgrade extra \
        < /dev/null 2>&1)"; then
    fail "accepted an argument the subcommand does not take"
elif [[ "${out}" == *"takes no arguments"* ]]; then
    pass "an argument is refused with the usage, not silently ignored"
else
    fail "refused an argument without saying why: ${out}"
fi

finish
