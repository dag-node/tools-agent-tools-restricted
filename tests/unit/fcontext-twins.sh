#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/fcontext-twins.sh
# Hermetic check that every file-context rule the policy sources write under /opt/ai-tools/sandbox-projects has a twin
# under /var/opt/ai-tools/sandbox-projects with the same regex tail, file type and context, and the reverse.
#
# The clones live on disk under /var/opt. Whether libselinux looks such a path up as /opt/... depends on the host's
# file_contexts.subs_dist: EL10 ships the `/var/opt /opt` alias and EL9 does not, so each host reaches one rule
# of a pair (the note in selinux/policy/ai_tools.fc). integration/selinux.sh asserts the rule this host reaches,
# which on EL10 is the /opt one whether or not its twin exists -- so a pair broken on the EL9 side passes there. Reading
# the sources pins both halves on any host. No root, no SELinux dependency: it reads the checkout.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly POLICY_DIR="${ROOT}/selinux/policy"
readonly OPT_PREFIX="/opt/ai-tools/sandbox-projects/"
readonly VAR_PREFIX="/var/opt/ai-tools/sandbox-projects/"
section "SELinux file contexts: every sandbox-clone rule is carried under /opt and /var/opt (unit)"

shopt -s nullglob
fc_files=("${POLICY_DIR}"/*.fc)
shopt -u nullglob
if (( ${#fc_files[@]} == 0 )); then
    skip "clone rule twins" "no .fc source under ${POLICY_DIR} (not a checkout)"
    finish; exit
fi

# normalized_rules <prefix> <file>...: print each rule starting with <prefix> as "<file> <tail> <rest>", the prefix
# stripped and the whitespace between fields collapsed, so a twin compares equal whatever column it is aligned to.
normalized_rules() {
    local prefix="$1"; shift
    awk -v p="${prefix}" '
        index($0, p) == 1 {
            tail = substr($1, length(p) + 1); rest = ""
            for (i = 2; i <= NF; i++) rest = rest " " $i
            n = split(FILENAME, parts, "/")
            print parts[n] " " tail rest
        }' "$@" | LC_ALL=C sort
}

opt_rules="$(normalized_rules "${OPT_PREFIX}" "${fc_files[@]}")"
var_rules="$(normalized_rules "${VAR_PREFIX}" "${fc_files[@]}")"

# The control: the sources this test exists for do carry clone rules. A pattern that stopped matching them would
# otherwise compare two empty sets and pass.
if [[ -z "${opt_rules}" ]]; then
    fail "no rule under ${OPT_PREFIX} in ${POLICY_DIR}/*.fc -- the reader matched nothing, so the comparison below proves nothing"
else
    pass "control: $(wc -l <<<"${opt_rules}") clone rule(s) under ${OPT_PREFIX} read from the sources"
fi

if [[ "${opt_rules}" == "${var_rules}" ]]; then
    pass "every clone rule under /opt has its /var/opt twin, and no /var/opt rule lacks one"
else
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        fail "clone rule without its twin: ${line}"
    done < <(LC_ALL=C comm -3 <(printf '%s\n' "${opt_rules}") <(printf '%s\n' "${var_rules}"))
fi

finish
