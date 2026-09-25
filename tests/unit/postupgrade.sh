#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/postupgrade.sh
# Hermetic unit test for `ai-tools-admin system post-upgrade`: the reconciliation of the .rpmnew copies an upgrade
# leaves beside the %config(noreplace) files this stack owns.
#
# Worth pinning because the command edits an operator-owned control-plane file and because its three treatments are
# what lets an operator predict it. The assertions therefore ask, per file, which treatment it got: the settings JSON is
# MERGED (each shipped declaration the kept file lacks arrives, the permission rules the file was kept for survive,
# a dated .bak lands first, and every addition is named), operator.conf is REPORTED and byte-identical afterwards,
# and the sudoers grant is SHOWN and neither written nor dropped -- its fixture here is a grant of everything
# to everyone, the one a silent adoption would be worst for. A kept file the registry does not name is found by its
# directory and never printed, since one may hold a credential. The removal command is offered only where the file
# mentions every option the copy documents and carries the same comment prose. The last property belongs to every case:
# a .rpmnew survives the run, because the copy is the baseline an operator merges from, and each case asserts it is
# still there and named as theirs to delete.
#
# Drives the DEPLOYED helper against fixtures in the testdir through AI_TOOLS_POSTUPGRADE_ROOT, the root-only path hook
# (like AI_TOOLS_ALLOWLIST): the live control plane is never read, written or listed. Every run is under setsid, so each
# prompt is answered by its own default -- which is both what an unattended host gets and what makes the run
# reproducible.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/libexec/ai-tools/ai-tools-admin"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHIPPED_SETTINGS="${REPO_ROOT}/src/opt/ai-tools/agents/claude-code/settings.json"

section "ai-tools-admin system post-upgrade: .rpmnew reconciliation (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "system post-upgrade" "not installed at ${HELPER}"; finish; exit
elif [[ ! -r "${SHIPPED_SETTINGS}" ]]; then
    skip "system post-upgrade" "needs the shipped settings.json from the checkout"; finish; exit
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
    mkdir -p "${ROOT}/opt/ai-tools/.claude" "${ROOT}/etc/ai-tools/endpoints" "${ROOT}/etc/sudoers.d" "${ROOT}/etc/codex"
}

# Run the deployed command against the fixture root and echo everything it said.
run_pu() {
    setsid env AI_TOOLS_POSTUPGRADE_ROOT="${ROOT}" "${HELPER}" system post-upgrade < /dev/null 2>&1 || true
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
# Doubles as the probe for a deployed helper that predates the command: it dies on an unknown subcommand instead
# of reporting a reconciled host.
reset_root
cp "${SHIPPED_SETTINGS}" "${SETTINGS}"
printf 'OPERATORS="root"\n' > "${CONF}"
before="$(md5sum "${SETTINGS}" "${CONF}")"
out="$(run_pu)"
if [[ "${out}" != *"no .rpmnew"* ]]; then
    skip "system post-upgrade" "deployed ai-tools-admin predates the command -- re-run sudo ./install.sh install"
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
if [[ -f "${SETTINGS}.rpmnew" && "${out}" == *"then remove ${SETTINGS}.rpmnew"* ]]; then
    pass "the copy survives the merge and is named as the operator's to remove"
else
    fail "dropped a .rpmnew, or did not name it as the file to remove by hand"
fi

# The command claims to be idempotent, and an operator re-runs it: a second pass does not merge a declaration and does
# not write a second backup.
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

# ── (C2) settings.json: the rules and settings left once the hooks are current, compared as sets ─────────────
# The shape an upgraded host shows: two deny rules the package added, one rule of the host's own, the ask list moved
# ahead of allow, and the two Bash PostToolUse commands split into two groups, as the hook merge leaves them. Only
# the two missing rules are the operator's to act on; order and grouping are not differences.
reset_root
jq '.permissions.deny -= ["Bash(gpg)", "Bash(gpg *)"] | .permissions.deny += ["Bash(hosttuned:*)"]
    | .permissions = ({ask: .permissions.ask} + .permissions)
    | .hooks.PostToolUse = [.hooks.PostToolUse[] | if .matcher == "Bash" then (.hooks[] as $h | .hooks = [$h]) else . end]' \
    "${SHIPPED_SETTINGS}" > "${SETTINGS}"
cp "${SHIPPED_SETTINGS}" "${SETTINGS}.rpmnew"
before="$(md5sum < "${SETTINGS}")"
out="$(run_pu)"
if [[ "${out}" == *"rules this version ships that the file does not carry"* && "${out}" == *"deny: Bash(gpg)"* \
      && "${out}" == *"deny: Bash(gpg *)"* && "${out}" == *"kept as yours"* && "${out}" == *"deny: Bash(hosttuned:*)"* \
      && "${out}" != *"other settings differ"* && "${out}" != *"@@"* \
      && "${out}" == *"sudoedit ${SETTINGS} ${SETTINGS}.rpmnew"* ]]; then
    pass "the missing rules are named, the host's own listed as its, and order and hook grouping are not shown"
else
    fail "the settings difference was not reported as sets: ${out}"
fi
if [[ "$(md5sum < "${SETTINGS}")" == "${before}" && -f "${SETTINGS}.rpmnew" ]]; then
    pass "the settings file is left as written"
else
    fail "the set comparison wrote the settings file or dropped its copy"
fi
out="$(setsid env AI_TOOLS_POSTUPGRADE_ROOT="${ROOT}" "${HELPER}" system post-upgrade --check < /dev/null 2>&1)" \
    && check_rc=0 || check_rc=$?
if [[ "${check_rc}" == 1 ]] \
        && grep -qxF "$(printf '%s\t%s\t%s\t%s' MSG-Z8U4 "${SETTINGS}" rule-missing 'deny: Bash(gpg)')" <<< "${out}" \
        && grep -qxF "$(printf '%s\t%s\t%s\t%s' MSG-Z8U4 "${SETTINGS}" rule-missing 'deny: Bash(gpg *)')" <<< "${out}" \
        && ! grep -qF 'hosttuned' <<< "${out}" && ! grep -qF 'rpmnew-differs' <<< "${out}"; then
    pass "--check reports each missing rule as rule-missing, and neither the host's rule nor the layout"
else
    fail "--check did not report the missing rules alone (exit ${check_rc}): ${out}"
fi

# A difference in order and layout alone is not one to carry over, and a changed setting outside the rule lists is shown
# as one.
jq '.permissions = ({ask: .permissions.ask} + .permissions)' "${SHIPPED_SETTINGS}" > "${SETTINGS}"
out="$(run_pu)"
if [[ "${out}" == *"apart from order and layout"* && "${out}" == *"nothing is left to carry over"* ]]; then
    pass "a file differing only in order is reported as having nothing to carry over"
else
    fail "an order-only difference was reported as one to act on: ${out}"
fi
jq '.env.CLAUDE_CODE_MAX_OUTPUT_TOKENS = 1' "${SHIPPED_SETTINGS}" > "${SETTINGS}"
out="$(run_pu)"
if [[ "${out}" == *"other settings differ"* && "${out}" == *"CLAUDE_CODE_MAX_OUTPUT_TOKENS"* \
      && "${out}" == *"--- ${SETTINGS}"* ]]; then
    pass "a setting outside the rule lists is shown as a diff labelled with the real files"
else
    fail "a changed setting was not shown: ${out}"
fi

# ── (D) A merge that matches the shipped copy still leaves it to the operator ──────────────────
reset_root
jq . "${SHIPPED_SETTINGS}" > "${SETTINGS}.rpmnew"
cp "${SETTINGS}.rpmnew" "${TESTDIR}/canonical.json"
jq '.hooks.PostToolUse = [ .hooks.PostToolUse[0] ]' "${TESTDIR}/canonical.json" > "${SETTINGS}"
out="$(run_pu)"
if [[ -f "${SETTINGS}.rpmnew" ]] && cmp -s "${SETTINGS}" "${TESTDIR}/canonical.json" \
        && [[ "${out}" == *"nothing is left to carry over"* && "${out}" == *"sudo rm ${SETTINGS}.rpmnew"* ]]; then
    pass "a copy with nothing left to carry over is reported as the operator's to remove"
else
    fail "removed a .rpmnew, or did not say the merge left nothing to carry over"
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

if grep -qE '^  operator\.conf: +NEW_OPTION$' <<< "${out}"; then
    pass "an option the kept file never mentions is named"
else
    fail "the new option was not reported"
fi
if ! grep -qE '^  operator\.conf: +EXISTING_OPTION$' <<< "${out}"; then
    pass "an option the operator has already commented out is not re-announced"
else
    fail "re-announced an option the file already mentions"
fi
if cmp -s "${CONF}" "${TESTDIR}/pre.conf" && [[ "$(sidecars "${CONF}")" == 0 ]]; then
    pass "the file is byte-identical afterwards and gains no sidecar"
else
    fail "a KEY=value config was rewritten or backed up"
fi
if [[ -f "${CONF}.rpmnew" && "${out}" == *"then remove ${CONF}.rpmnew"* ]]; then
    pass "the copy to merge from is kept, with the hand-merge named"
else
    fail "dropped the .rpmnew an operator still has to merge by hand"
fi

# ── (E2) operator.conf: the removal is offered only when the file covers every option and the prose ─────
# Every option mentioned and the same comment prose, only re-wrapped, so the removal command is printed.
reset_root
printf '# The accounts enrolled as operators, managed by\n# the admin command.\nOPERATORS="root"\n' > "${CONF}"
printf '# The accounts enrolled as operators,\n# managed by the admin command.\n#OPERATORS=""\n' > "${CONF}.rpmnew"
out="$(run_pu)"
if [[ "${out}" == *"sudo rm ${CONF}.rpmnew"* && "${out}" != *"comments differ"* ]]; then
    pass "a copy whose options are all mentioned and whose comments are only re-wrapped is offered for removal"
else
    fail "a copy adding nothing was not offered for removal: ${out}"
fi
if [[ "${out}" == *"kept as set: OPERATORS"* ]]; then
    pass "the host's own settings are named as kept"
else
    fail "the host's own settings were not named"
fi
if [[ "${out}" == *"Post-upgrade done -- nothing needs your attention"* && "${out}" == *"good to go"* ]]; then
    pass "a run with nothing to carry over closes by saying nothing needs attention"
else
    fail "a run with nothing to act on closed with the wrong summary: ${out}"
fi
# The same file with one comment reworded: the copy now holds prose the file lacks, so no removal is offered.
printf '# The accounts that run agent sessions,\n# managed by the admin command.\n#OPERATORS=""\n' > "${CONF}.rpmnew"
out="$(run_pu)"
if [[ "${out}" == *"comments differ"* && "${out}" != *"sudo rm"* && "${out}" == *"then remove ${CONF}.rpmnew"* ]]; then
    pass "a reworded comment withholds the removal and names the difference"
else
    fail "a copy carrying new prose was offered for removal: ${out}"
fi
if [[ "${out}" == *"Post-upgrade done -- review the warnings above"* && "${out}" == *"Happy merging!"* \
      && "${out}" != *"good to go"* ]]; then
    pass "a run with something to carry over closes by asking for a manual review"
else
    fail "a run with something to act on closed without asking for a review: ${out}"
fi
if grep -qxE '  SUDO_EDITOR=(meld|vimdiff) sudoedit <file> <file>.rpmnew' <<< "${out}"; then
    pass "a run with a difference left to act on prints the sudoedit comparison, the file on the left, on a line of its own"
else
    fail "the meld line is missing where a difference is left: ${out}"
fi

# A host kept from before the bracketed list form: each commented default is a setting, not prose, so a template
# that writes the same defaults in brackets is still a copy adding nothing, and its removal is offered.
printf '# Walk skips.\n#SKIP_VCS_DIRS=".git"\n#SKIP_PACKAGE_DIRS="node_modules .venv packages"\nOPERATORS="root"\n' \
    > "${CONF}"
printf '# Walk skips.\n#SKIP_VCS_DIRS=[.git]\n#SKIP_PACKAGE_DIRS=[node_modules, .venv, packages]\n#OPERATORS=[]\n' \
    > "${CONF}.rpmnew"
out="$(run_pu)"
if [[ "${out}" == *"sudo rm ${CONF}.rpmnew"* && "${out}" != *"comments differ"* ]]; then
    pass "commented defaults moved to the bracketed form are not reported as changed prose"
else
    fail "a template differing only in the list form of its commented defaults was reported: ${out}"
fi

# ── (E3) A kept file another package ships: found, reported, and never printed ─────────────────────
# The registry is base's, so an integration's endpoint file is found by the directory it sits in. It carries a key,
# so neither its value nor the copy's content may reach the output.
reset_root
ENDPOINT="${ROOT}/etc/ai-tools/endpoints/example.conf"
printf 'EXAMPLE_API_KEY="apikey_secretvalue"\n' > "${ENDPOINT}"
printf '# Example endpoint.\n#EXAMPLE_API_KEY=""\n#EXAMPLE_TIMEOUT_MS="15000"\n' > "${ENDPOINT}.rpmnew"
printf 'approval_policy = "never"\n' > "${ROOT}/etc/codex/managed_config.toml"
printf 'approval_policy = "never"\ncheck_for_update_on_startup = false\n' > "${ROOT}/etc/codex/managed_config.toml.rpmnew"
out="$(run_pu)"
if [[ "${out}" == *"${ENDPOINT}"* && "${out}" == *"EXAMPLE_TIMEOUT_MS"* ]]; then
    pass "a .rpmnew the registry does not name is found and its new option named"
else
    fail "an integration's kept config was not reported: ${out}"
fi
if [[ "${out}" != *"secretvalue"* && "${out}" != *"check_for_update_on_startup"* ]]; then
    pass "neither a value nor a copy's content is printed for a discovered file"
else
    fail "a discovered file's content reached the output"
fi
if [[ "${out}" == *"sudoedit ${ROOT}/etc/codex/managed_config.toml ${ROOT}/etc/codex/managed_config.toml.rpmnew"* \
      && -f "${ROOT}/etc/codex/managed_config.toml.rpmnew" ]]; then
    pass "a file with no treatment is named with the sudoedit merge, the file on the left, and its copy kept"
else
    fail "a file with no treatment was not named, or its copy was dropped"
fi

# ── (E4) Provenance: a copy dated before this installation is said to be an earlier template ──────────
reset_root
printf 'OPERATORS="root"\n' > "${CONF}"
printf '#OPERATORS=""\n' > "${CONF}.rpmnew"
touch -d 2020-01-01 "${CONF}.rpmnew"
out="$(run_pu)"
if [[ "${out}" == *"dated 2020-01-01 -- older than this installation"* ]]; then
    pass "a copy older than the installation is named as an earlier version's template"
else
    fail "a stale copy was not dated or not marked as older: ${out}"
fi

# ── (E5) Earlier copies are listed and never removed ──────────────────────────────────────────────
reset_root
cp "${SHIPPED_SETTINGS}" "${SETTINGS}"
printf '{}\n' > "${SETTINGS}.20200101.bak"
printf 'OPERATORS="root"\n' > "${CONF}"
printf 'OPERATORS=""\n' > "${CONF}.20200101-2.shipped"
out="$(run_pu)"
if [[ "${out}" == *"${SETTINGS}.20200101.bak  (before this installation)"* \
      && "${out}" == *"${CONF}.20200101-2.shipped  (before this installation)"* \
      && -f "${SETTINGS}.20200101.bak" && -f "${CONF}.20200101-2.shipped" ]]; then
    pass "earlier .bak and .shipped copies are listed with their age and left in place"
else
    fail "an earlier copy was not listed, or was removed: ${out}"
fi

# ── (E6) A copy identical to the file gets no block, only a removal line, and no comparison is offered ──────────
reset_root
mkdir -p "${ROOT}/etc/ai-tools/prompts"
PROMPT="${ROOT}/etc/ai-tools/prompts/prompt.md"
: > "${PROMPT}"; : > "${PROMPT}.rpmnew"
out="$(run_pu)"
if ! grep -qxF "${PROMPT}" <<< "${out}" && grep -qxF "    sudo rm ${PROMPT}.rpmnew" <<< "${out}" \
      && [[ "${out}" != *"identical to the package copy"* && "${out}" == *"to remove when you are ready:"* \
      && "${out}" == *"every config file is reconciled"* && "${out}" != *"nothing needs your attention"* \
      && -f "${PROMPT}.rpmnew" ]]; then
    pass "an identical copy gets no block, is offered for removal on one line, and is kept"
else
    fail "an identical copy was reported as a difference or not offered for removal: ${out}"
fi
if [[ "${out}" != *"sudoedit <file>"* ]]; then
    pass "a run with nothing left to merge does not offer a comparison"
else
    fail "the meld comparison was offered with nothing to merge: ${out}"
fi

# ── (E7) Earlier copies are listed in the order they were made ───────────────────────────────────
# An unnumbered copy is the name an earlier release gave the day's first, so it lists before that day's -2 and -3.
reset_root
printf 'OPERATORS="root"\n' > "${CONF}"
for suffix in 20200105-3 20200105 20200103 20200105-2; do : > "${CONF}.${suffix}.shipped"; done
listed="$(run_pu | grep -oE 'operator\.conf\.[0-9-]+\.shipped' | tr '\n' ' ')"
if [[ "${listed}" == "operator.conf.20200103.shipped operator.conf.20200105.shipped operator.conf.20200105-2.shipped operator.conf.20200105-3.shipped " ]]; then
    pass "a day's copies list in the order they were made, the unnumbered first"
else
    fail "copies listed out of order: ${listed}"
fi

# ── (E8) An ask entry the kept file lacks: reported with or without a copy, and never written ────────
# rpm parks a copy only on the upgrade that changed the shipped file, so the run checks the kept settings.json with no
# .rpmnew waiting. The command is a stub under the prefix root, the only thing the check reads it for.
reset_root
mkdir -p "${ROOT}/usr/local/lib/ai-tools/typesafe"
: > "${ROOT}/usr/local/lib/ai-tools/typesafe/decide.mjs"
jq 'del(.permissions.ask)' "${SHIPPED_SETTINGS}" > "${SETTINGS}"
cp "${SETTINGS}" "${TESTDIR}/pre.settings"
out="$(run_pu)"
if [[ "${out}" == *'"Bash(node /usr/local/lib/ai-tools/typesafe/decide.mjs *)"'* \
      && "${out}" == *'right after its {:'* && "${out}" == *'"ask": ['* && "${out}" == *"review the warnings"* ]]; then
    pass "a missing ask entry is named with the JSON to paste and where, and the run asks for a review"
else
    fail "a missing ask entry was not reported: ${out}"
fi
if cmp -s "${SETTINGS}" "${TESTDIR}/pre.settings" && [[ "$(sidecars "${SETTINGS}")" == 0 ]]; then
    pass "the file is left byte-identical and gains no sidecar"
else
    fail "the ask check wrote to settings.json"
fi
cp "${SHIPPED_SETTINGS}" "${SETTINGS}"
out="$(run_pu)"
if [[ "${out}" != *"without asking"* && "${out}" == *"no .rpmnew"* ]]; then
    pass "a file carrying every ask entry is not reported"
else
    fail "a current file was reported as missing an ask entry: ${out}"
fi

# ── (E8b) A key a managed file lacks against its shipped copy: named with the merge command, left as written ─────
# An agent's managed files are the ones its manifest declares, with the shipped copy under /usr/share/ai-tools; both,
# and the manifest, are read under the prefix root. A fixture agent declares one file whose shipped copy carries a key
# the kept file does not set, as a release adds one to a %config(noreplace) file.
reset_root
mkdir -p "${ROOT}/usr/local/lib/ai-tools/agents.d" "${ROOT}/usr/share/ai-tools/acme" "${ROOT}/etc/acme"
chmod 0755 "${ROOT}/usr/local/lib/ai-tools/agents.d"
printf 'npm_package=@acme/agent\nlauncher=acme\ndefault_enable=no\nmanaged_files=/etc/acme/req.toml\n' \
    > "${ROOT}/usr/local/lib/ai-tools/agents.d/acme.conf"
chmod 0644 "${ROOT}/usr/local/lib/ai-tools/agents.d/acme.conf"
printf 'pin = 1\n\n# why the feature is off\n[features]\nauto_start = false\n' > "${ROOT}/usr/share/ai-tools/acme/req.toml"
printf 'pin = 2\n' > "${ROOT}/etc/acme/req.toml"
cp "${ROOT}/etc/acme/req.toml" "${TESTDIR}/pre.req"
out="$(run_pu)"
if [[ "${out}" == *"req.toml -- keys this release ships that the file does not set"* \
      && "${out}" == *"features.auto_start"* \
      && "${out}" == *"sudo cp ${ROOT}/usr/share/ai-tools/acme/req.toml ${ROOT}/etc/acme/req.toml.rpmnew"* \
      && "${out}" == *"sudoedit ${ROOT}/etc/acme/req.toml ${ROOT}/etc/acme/req.toml.rpmnew"* \
      && "${out}" == *"review the warnings"* ]]; then
    pass "a key the kept file lacks is named, with the package copy recreated and merged, the file on the left"
else
    fail "a missing managed-file key was not reported: ${out}"
fi
if cmp -s "${ROOT}/etc/acme/req.toml" "${TESTDIR}/pre.req" && [[ "$(sidecars "${ROOT}/etc/acme/req.toml")" == 0 ]]; then
    pass "the managed file is left byte-identical and gains no sidecar"
else
    fail "the key check wrote to the managed file"
fi
out="$(setsid env AI_TOOLS_POSTUPGRADE_ROOT="${ROOT}" "${HELPER}" system post-upgrade --check < /dev/null 2>&1)" \
    && check_rc=0 || check_rc=$?
if [[ "${check_rc}" -eq 1 ]] \
        && grep -qxF "$(printf '%s\t%s\t%s\t%s' MSG-K5H2 "${ROOT}/etc/acme/req.toml" key-missing features.auto_start)" \
            <<< "${out}" \
        && ! grep -qF "${ROOT}/etc/acme/req.toml"$'\t'key-missing$'\t'pin <<< "${out}"; then
    pass "--check reports the missing key as key-missing under its code, not the key set to another value, and exits 1"
else
    fail "--check did not report the missing key alone (exit ${check_rc}): ${out}"
fi
cp "${ROOT}/usr/share/ai-tools/acme/req.toml" "${ROOT}/etc/acme/req.toml.rpmnew"
out="$(run_pu)"
if [[ "${out}" == *"sudoedit ${ROOT}/etc/acme/req.toml ${ROOT}/etc/acme/req.toml.rpmnew"* \
      && "${out}" != *"sudo cp ${ROOT}/usr/share/ai-tools/acme/req.toml"* ]]; then
    pass "with a .rpmnew waiting, the merge uses it and does not recreate one"
else
    fail "the merge did not use the waiting .rpmnew: ${out}"
fi
rm -f "${ROOT}/etc/acme/req.toml.rpmnew"
printf 'pin = 2\n[features]\nauto_start = true\n' > "${ROOT}/etc/acme/req.toml"
out="$(run_pu)"
if [[ "${out}" != *"keys this release ships"* ]]; then
    pass "a file that sets every key is not reported, whatever its values"
else
    fail "a file setting every key was reported: ${out}"
fi

# ── (E9) --check: one tab-separated line per finding, nothing when clean, and no write ───────────────────────
# It is what cron runs, so a clean host must print nothing at all and exit 0, a finding must be one line a monitor
# splits on a tab -- its code, the path, the finding, the detail -- and a merge the interactive run would make must be
# reported without being made. The findings that need no action appear under --all alone and leave the exit at 0.
run_check() {
    local rc=0
    out="$(setsid env AI_TOOLS_POSTUPGRADE_ROOT="${ROOT}" "${HELPER}" system post-upgrade --check "$@" \
        < /dev/null 2>&1)" || rc=$?
    check_rc="${rc}"
}
# has_finding <code> <path> <finding> <detail>: the output holds exactly that line.
has_finding() { grep -qxF "$(printf '%s\t%s\t%s\t%s' "$@")" <<< "${out}"; }

reset_root
cp "${SHIPPED_SETTINGS}" "${SETTINGS}"
mkdir -p "${ROOT}/etc/ai-tools/prompts"
: > "${ROOT}/etc/ai-tools/prompts/prompt.md"; : > "${ROOT}/etc/ai-tools/prompts/prompt.md.rpmnew"
: > "${SETTINGS}.20200101-1.bak"
run_check
if [[ -z "${out}" && "${check_rc}" == 0 ]]; then
    pass "a host with nothing to act on prints nothing and exits 0 under --check"
else
    fail "a clean host was reported under --check (exit ${check_rc}): ${out}"
fi
run_check --all
if [[ "${check_rc}" == 0 ]] && has_finding MSG-J3X7 "${ROOT}/etc/ai-tools/prompts/prompt.md.rpmnew" rpmnew-residual - \
        && has_finding MSG-W8F8 "${SETTINGS}.20200101-1.bak" copy-kept -; then
    pass "--all adds the identical copy and the kept backup, and the exit stays 0"
else
    fail "--all did not list the no-action findings, or changed the exit (exit ${check_rc}): ${out}"
fi

reset_root
jq 'del(.hooks.PreToolUse) | del(.permissions.ask)' "${SHIPPED_SETTINGS}" > "${SETTINGS}"
cp "${SHIPPED_SETTINGS}" "${SETTINGS}.rpmnew"
mkdir -p "${ROOT}/usr/local/lib/ai-tools/typesafe"
: > "${ROOT}/usr/local/lib/ai-tools/typesafe/decide.mjs"
: > "${ROOT}/etc/codex/gone.toml.rpmnew"
cp "${SETTINGS}" "${TESTDIR}/pre-check.json"
shipped_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "${SHIPPED_SETTINGS}")"
run_check
if [[ "${check_rc}" == 1 ]] && has_finding MSG-F2G7 "${SETTINGS}" hook-missing "PreToolUse: ${shipped_cmd}" \
        && has_finding MSG-E9V5 "${SETTINGS}" ask-missing 'Bash(node /usr/local/lib/ai-tools/typesafe/decide.mjs *)' \
        && has_finding MSG-K8D2 "${ROOT}/etc/codex/gone.toml.rpmnew" rpmnew-orphan "the file it belongs to is gone"; then
    pass "each finding is one line of code, path, finding and detail, and the run exits 1"
else
    fail "--check did not report the pending merge, the missing ask entry and the orphan (exit ${check_rc}): ${out}"
fi
if ! grep -qvP '^MSG-[A-Z][0-9][A-Z][0-9]\t/[^\t]+\t[a-z-]+\t[^\t]+$' <<< "${out}"; then
    pass "every line --check prints has the four-field shape and no other text"
else
    fail "--check printed a line outside the finding shape: ${out}"
fi
if cmp -s "${SETTINGS}" "${TESTDIR}/pre-check.json" && [[ "$(sidecars "${SETTINGS}")" == 0 ]]; then
    pass "--check writes nothing: the file is byte-identical and gains no backup"
else
    fail "--check changed settings.json or left a sidecar"
fi

# A shipped skill whose live copy is an empty directory is not offered to a session, so it needs attention; the same
# skill seeded at an older version is the operator's choice and appears under --all alone.
reset_root
cp "${SHIPPED_SETTINGS}" "${SETTINGS}"
mkdir -p "${ROOT}/usr/share/ai-tools/skills/ai-tools-demo" "${ROOT}/opt/ai-tools/skills/ai-tools-demo"
printf -- '---\nname: ai-tools-demo\nx-ai-tools-managed: true\nx-ai-tools-version: 2\n---\n' \
    > "${ROOT}/usr/share/ai-tools/skills/ai-tools-demo/SKILL.md"
run_check
if [[ "${check_rc}" == 1 ]] && has_finding MSG-X6H5 "${ROOT}/opt/ai-tools/skills/ai-tools-demo" asset-missing \
        "not seeded -- sessions are not offered it"; then
    pass "a shipped skill whose live directory is empty is reported missing"
else
    fail "an empty live skill directory was not reported (exit ${check_rc}): ${out}"
fi
sed 's/version: 2/version: 1/' "${ROOT}/usr/share/ai-tools/skills/ai-tools-demo/SKILL.md" \
    > "${ROOT}/opt/ai-tools/skills/ai-tools-demo/SKILL.md"
run_check --all
if has_finding MSG-R6B2 "${ROOT}/opt/ai-tools/skills/ai-tools-demo" asset-outdated "v1 live, v2 shipped" \
        && ! grep -q asset-missing <<< "${out}"; then
    pass "a live skill older than the shipped one is listed under --all as outdated"
else
    fail "an outdated live skill was not listed under --all: ${out}"
fi

for bad in "--all" "--format tsv" "--check --format json" "--check --bogus"; do
    # shellcheck disable=SC2086  # each case is a word list on purpose
    if bad_out="$(setsid env AI_TOOLS_POSTUPGRADE_ROOT="${ROOT}" "${HELPER}" system post-upgrade ${bad} \
            < /dev/null 2>&1)"; then
        fail "system post-upgrade ${bad} was accepted"
    else
        assert_msg MSG-S9M6 "${bad_out}" "system post-upgrade ${bad} is refused"
    fi
done

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

# ── (H) Provider lists an earlier release wrote bare: rewritten on every run ─────────────────
# The one rewrite the command makes to operator.conf, with no .rpmnew waiting: `--check` names each key the run would
# rewrite and each name it cannot, and writes nothing; the run rewrites the mappable key after a backup and leaves
# the other as written, named; a second `--check` names only what is left. The installed names come from fixture
# directories through the resolver's root-only hooks.
reset_root
mkdir -p "${TESTDIR}/kinds/agents.d" "${TESTDIR}/kinds/integrations.d" "${TESTDIR}/kinds/filters.d"
touch "${TESTDIR}/kinds/agents.d/acme.conf" "${TESTDIR}/kinds/filters.d/base.rules"
printf '%s\n' '# host options' 'OPERATORS=[op]' 'AI_TOOLS_AGENTS=[acme]' 'AI_TOOLS_INTEGRATIONS=[nosuch]' \
    'AI_TOOLS_FILTERS=[core]' > "${CONF}"
chmod 0644 "${CONF}"; cp "${CONF}" "${TESTDIR}/pre.operator.conf"
kinds_env=(AI_TOOLS_AGENTS_DIR="${TESTDIR}/kinds/agents.d" AI_TOOLS_INTEGRATIONS_DIR="${TESTDIR}/kinds/integrations.d"
           AI_TOOLS_FILTERS_DIR="${TESTDIR}/kinds/filters.d")
check_rc=0
out="$(setsid env "${kinds_env[@]}" AI_TOOLS_POSTUPGRADE_ROOT="${ROOT}" "${HELPER}" system post-upgrade --check \
    < /dev/null 2>&1)" || check_rc=$?
if [[ "${check_rc}" == 1 ]] \
        && has_finding MSG-P5K4 "${CONF}" list-unmigrated 'AI_TOOLS_AGENTS: [acme] -> [agent-acme]' \
        && has_finding MSG-S3D8 "${CONF}" list-unmigratable 'AI_TOOLS_INTEGRATIONS: nosuch' \
        && has_finding MSG-P5K4 "${CONF}" list-unmigrated 'AI_TOOLS_FILTERS: [core] -> [filter-base]'; then
    pass "--check names each list it would rewrite and each name it cannot, and exits 1"
else
    fail "--check over bare provider lists (exit ${check_rc}): ${out}"
fi
if cmp -s "${CONF}" "${TESTDIR}/pre.operator.conf" && [[ "$(sidecars "${CONF}")" == 0 ]]; then
    pass "--check leaves the bare lists as written and takes no backup"
else
    fail "--check changed operator.conf or left a sidecar"
fi
out="$(setsid env "${kinds_env[@]}" AI_TOOLS_POSTUPGRADE_ROOT="${ROOT}" "${HELPER}" system post-upgrade \
    < /dev/null 2>&1 || true)"
if [[ "$(tr '\n' '|' < "${CONF}")" == '# host options|OPERATORS=[op]|AI_TOOLS_AGENTS=[agent-acme]|AI_TOOLS_INTEGRATIONS=[nosuch]|AI_TOOLS_FILTERS=[filter-base]|' ]]; then
    pass "the run rewrites each mappable list and leaves the unmappable one as written, with no .rpmnew waiting"
else
    fail "the run left operator.conf as '$(tr '\n' '|' < "${CONF}")'"
fi
if [[ "$(sidecars "${CONF}")" == 1 && "${out}" == *"[agent-acme]"* && "${out}" == *"nosuch"* ]]; then
    pass "the run takes one backup and reports the rewrite and the name it left"
else
    fail "the run's backup or report: $(sidecars "${CONF}") sidecar(s), output ${out}"
fi
check_rc=0
out="$(setsid env "${kinds_env[@]}" AI_TOOLS_POSTUPGRADE_ROOT="${ROOT}" "${HELPER}" system post-upgrade --check \
    < /dev/null 2>&1)" || check_rc=$?
if [[ "${check_rc}" == 1 && "$(grep -c . <<< "${out}")" == 1 ]] \
        && has_finding MSG-S3D8 "${CONF}" list-unmigratable 'AI_TOOLS_INTEGRATIONS: nosuch'; then
    pass "after the run --check names only the name left to edit by hand"
else
    fail "--check after the run (exit ${check_rc}): ${out}"
fi

# ── (G) Dispatch ─────────────────────────────────────────────────────────────────────────────
reset_root
if out="$(setsid env AI_TOOLS_POSTUPGRADE_ROOT="${ROOT}" "${HELPER}" system post-upgrade extra \
        < /dev/null 2>&1)"; then
    fail "accepted an argument the command does not take"
else
    assert_msg MSG-S9M6 "${out}" "an argument is refused with the usage, not silently ignored"
fi

finish
