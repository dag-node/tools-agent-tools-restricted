#!/usr/bin/env bash
# tests/unit/settings-merge.sh
# Unit test for the hook-declaration merge (conf.lib.sh), the step that lets a NEWLY SHIPPED hook
# reach a host whose settings.json is kept across the upgrade.
#
# What makes this worth pinning: the merge edits an operator-owned control-plane file, and every
# way it can go wrong is quiet. A merge that drops the permission arrays silently changes what
# runs; a merge that skips an event leaves a hook declared nowhere and the feature inert; a result
# that names fewer additions than it made hides the edit from the operator reviewing the install
# log. So the assertions come in three groups -- what must ARRIVE, what must SURVIVE, and what
# must be REPORTED -- plus the sidecars, which answer different questions (.bak is what the
# operator had, .shipped is what they were meant to get) and do not substitute for each other.
#
# Drives the DEPLOYED library, like the other unit tests: the decision lives in conf.lib.sh
# precisely so it can be exercised without stubs or text extraction.
#
# No network, no session: fixtures are built in the testdir.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly LIB="/usr/local/lib/ai-tools/conf.lib.sh"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHIPPED="${REPO_ROOT}/src/opt/ai-tools/agents/claude-code/settings.json"

section "settings.json hook-declaration merge (unit)"

if [[ ! -r "${LIB}" || ! -r "${SHIPPED}" ]]; then
    skip "settings merge" "needs the deployed conf.lib.sh and the shipped settings.json"; finish; exit
fi
# shellcheck source=/dev/null
source "${LIB}"
if ! declare -F ai_tools_conf_merge_hook_declarations >/dev/null 2>&1; then
    skip "settings merge" "deployed conf.lib.sh predates the merge -- re-run sudo ./install.sh install"
    finish; exit
fi
if ! command -v jq >/dev/null 2>&1; then
    fail "jq is missing -- it is a package dependency of the agent package"; finish; exit
fi

mktestdir

# Render the library's structured result the way a caller does, so the assertions below read what
# an operator would have been told rather than reaching into the library's variables one by one.
# shellcheck disable=SC2154  # the _ai_tools_conf_merge_* results are set by the sourced
# conf.lib.sh, which shellcheck cannot follow through the LIB path variable
merge_report() {
    local status=0
    ai_tools_conf_merge_hook_declarations "$1" "$2" || status=$?
    case "${status}" in
    0)  printf 'added: %s\n' "${_ai_tools_conf_merge_added[@]}"
        [[ -n "${_ai_tools_conf_merge_backup}" ]] \
            && printf 'backup: %s\n' "${_ai_tools_conf_merge_backup}" ;;
    2)  printf 'refused: %s\n' "${_ai_tools_conf_merge_reason}"
        [[ -n "${_ai_tools_conf_merge_reference}" ]] \
            && printf 'reference: %s\n' "${_ai_tools_conf_merge_reference}" ;;
    esac
    return 0
}

# A settings.json as it looks BEFORE this version's hooks existed: the handback hook only.
mk_stale() {
    jq 'del(.hooks.PreToolUse)
        | .hooks.PostToolUse = [ (.hooks.PostToolUse[] | select(.matcher == "Write|Edit")) ]' \
        "${SHIPPED}" > "$1"
}
declares() { jq -e --arg e "$2" --arg c "$3" \
    '[.hooks[$e][]?.hooks[]?.command] | index($c) != null' "$1" >/dev/null 2>&1; }

# --- What must ARRIVE: every shipped declaration the kept file lacks ---------------------------
stale="${TESTDIR}/stale.json"; mk_stale "${stale}"
report="$(merge_report "${stale}" "${SHIPPED}")"

for pair in "PreToolUse:pre-tool-use" "PostToolUse:post-tool-use"; do
    ev="${pair%%:*}"; arg="${pair#*:}"
    if declares "${stale}" "${ev}" "/opt/ai-tools/.claude/filter-hook.sh ${arg}"; then
        pass "${ev} gains the shipped filter-hook declaration"
    else
        fail "${ev} did not gain '/opt/ai-tools/.claude/filter-hook.sh ${arg}'"
    fi
done

# --- What must SURVIVE: everything the file was kept for --------------------------------------
if declares "${stale}" PostToolUse /opt/ai-tools/.claude/post-tool-hook.sh; then
    pass "the existing handback declaration survives the merge"
else
    fail "the handback declaration was lost -- agent-written files would stay sandbox-owned"
fi
if [[ "$(jq -S '.permissions' "${stale}")" == "$(jq -S '.permissions' "${SHIPPED}")" ]]; then
    pass "the permission arrays are untouched"
else
    fail "the permission arrays changed -- a merge must not decide what may run"
fi

# Host tuning is the whole reason the file is kept, so it must survive a merge verbatim: a
# relaxed deny entry (the documented case, alongside an enabled SELinux group) and an added env
# key. Both are states an upgrade must not quietly revert.
tuned="${TESTDIR}/tuned.json"
mk_stale "${tuned}"
jq '.permissions.deny -= ["Bash(rpm)"] | .env.SITE_PROXY = "http://proxy.example:3128"' \
    "${tuned}" > "${tuned}.t" && mv "${tuned}.t" "${tuned}"
merge_report "${tuned}" "${SHIPPED}" >/dev/null
if jq -e '(.permissions.deny | index("Bash(rpm)")) == null
          and .env.SITE_PROXY == "http://proxy.example:3128"' "${tuned}" >/dev/null; then
    pass "a relaxed deny entry and an added env key both survive"
else
    fail "host tuning was reverted by the merge"
fi
if declares "${tuned}" PreToolUse "/opt/ai-tools/.claude/filter-hook.sh pre-tool-use"; then
    pass "the tuned file still gains the shipped declaration"
else
    fail "a tuned file did not gain the shipped declaration"
fi

# An operator's own hook is not shipped by us and must not be treated as drift.
extra="${TESTDIR}/extra.json"; mk_stale "${extra}"
jq '.hooks.PostToolUse += [{matcher:"Bash",
      hooks:[{type:"command", command:"/usr/local/bin/site-audit.sh"}]}]' \
    "${extra}" > "${extra}.t" && mv "${extra}.t" "${extra}"
merge_report "${extra}" "${SHIPPED}" >/dev/null
if declares "${extra}" PostToolUse /usr/local/bin/site-audit.sh \
        && declares "${extra}" PostToolUse "/opt/ai-tools/.claude/filter-hook.sh post-tool-use"; then
    pass "an operator's own hook is kept beside the added one"
else
    fail "an operator's own hook was dropped"
fi

# --- What must be SAID: the operator reviews the log, not the JSON ----------------------------
said_all=true
for arg in pre-tool-use post-tool-use; do
    grep -q "filter-hook.sh ${arg}" <<< "${report}" || said_all=false
done
if ${said_all}; then
    pass "the report names every declaration it added"
else
    fail "the report under-names its additions: ${report}"
fi

# --- Idempotence: a current file is neither rewritten nor reported -----------------------------
current="${TESTDIR}/current.json"; cp "${SHIPPED}" "${current}"
before="$(md5sum < "${current}")"
quiet="$(merge_report "${current}" "${SHIPPED}" 2>&1)"
if [[ "$(md5sum < "${current}")" == "${before}" && -z "${quiet}" ]]; then
    pass "an already-current file is left alone and says nothing"
else
    fail "an already-current file was touched or reported: ${quiet}"
fi

# --- Sidecars: two files, two different recoveries --------------------------------------------
# Both are date-stamped and neither overwrites an earlier copy, so an operator who ran the
# installer twice keeps the first -- the run they usually want back.
count_sidecars() { local g=("$1".*."$2"); [[ -e "${g[0]}" ]] && printf '%d' "${#g[@]}" || printf '0'; }

# .bak answers "what did I have?" -- the only copy that restores host tuning if a merge ever
# produces valid JSON that is nonetheless wrong, which the parse check cannot catch.
bak="${TESTDIR}/bak.json"; mk_stale "${bak}"; original="$(cat "${bak}")"
report="$(merge_report "${bak}" "${SHIPPED}")"
backup_path="$(sed -n 's/^backup: //p' <<< "${report}")"
if [[ -n "${backup_path}" && "$(cat "${backup_path}")" == "${original}" ]]; then
    pass "the pre-merge file is backed up verbatim, and the result names the copy"
else
    fail "no faithful, named backup of the pre-merge file: '${backup_path}'"
fi
if [[ "${backup_path}" == *.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].bak ]]; then
    pass "the backup is date-stamped, so successive installs do not overwrite each other"
else
    fail "the backup is not date-stamped: ${backup_path}"
fi

# A no-op must not litter: a backup beside an unchanged file would imply an edit that never was.
noop="${TESTDIR}/noop.json"; cp "${SHIPPED}" "${noop}"
merge_report "${noop}" "${SHIPPED}" >/dev/null 2>&1
if [[ "$(count_sidecars "${noop}" bak)" == 0 ]]; then
    pass "a no-op run writes no backup"
else
    fail "a no-op run left a backup implying an edit"
fi

# .shipped answers "what was I supposed to get?" -- written only when the merge could NOT run,
# because an RPM-installed host has no source checkout to hand-merge from.
broken="${TESTDIR}/broken.json"; printf '{ "hooks": broken' > "${broken}"
before="$(cat "${broken}")"
report="$(merge_report "${broken}" "${SHIPPED}" 2>&1)"
reference_path="$(sed -n 's/^reference: //p' <<< "${report}")"
if [[ "$(cat "${broken}")" == "${before}" ]]; then
    pass "a malformed settings.json is left byte-identical"
else
    fail "a malformed settings.json was modified"
fi
if [[ -n "${reference_path}" ]] && cmp -s "${reference_path}" "${SHIPPED}"; then
    pass "the shipped baseline is left to merge from by hand, and named"
else
    fail "no named shipped baseline beside an unmergeable file: '${reference_path}'"
fi
if grep -q '^refused: ' <<< "${report}"; then
    pass "the refusal states which check stopped it"
else
    fail "the refusal gives no reason: ${report}"
fi

# A second failed run keeps the first baseline instead of replacing it, so the copies read as a
# history of what each install offered rather than only the most recent.
merge_report "${broken}" "${SHIPPED}" >/dev/null 2>&1
if [[ "$(count_sidecars "${broken}" shipped)" == 2 ]]; then
    pass "a second refusal adds a baseline copy rather than overwriting the first"
else
    fail "expected 2 baseline copies, found $(count_sidecars "${broken}" shipped)"
fi

finish
