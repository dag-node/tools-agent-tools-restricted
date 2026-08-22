#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/relabel.sh
# Unit test for the entrypoint file-context predicate (relabel.lib.sh): the pure
# ai_tools_entrypoint_fcontext_valid that gates every pattern an agent manifest declares before
# it becomes a `semanage fcontext` rule mapping files to ai_tools_exec_t -- the exec entrypoint of
# the confined domain.
#
# The property under test is containment: a declared pattern may only ever match inside the
# sandbox's own Node toolchain. A manifest is root-owned, so this is defense in depth rather than
# the only guard, but the failure it prevents is severe and silent -- a pattern with an
# alternation, a traversal, or a foreign prefix would hand ai_tools_exec_t to a file outside the
# toolchain, making it an entrypoint into the agent's domain. The type itself is never
# manifest-supplied, which this file also pins.
#
# Sources the deployed library; no SELinux host, no privilege of its own. Run as root via sudo
# (suite contract).

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly LIB="/usr/local/lib/ai-tools/relabel.lib.sh"
section "relabel: agent entrypoint file-context validation (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "entrypoint fcontext validation" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}" || ! declare -F ai_tools_entrypoint_fcontext_valid >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define ai_tools_entrypoint_fcontext_valid"
    finish; exit
fi

# accepts/rejects <pattern> [why]
accepts() {
    if ai_tools_entrypoint_fcontext_valid "$1"; then pass "accepts ${1:-<empty>}"
    else fail "rejected a valid entrypoint pattern: $1"; fi
}
rejects() {
    if ai_tools_entrypoint_fcontext_valid "$1"; then fail "ACCEPTED ${2}: ${1:-<empty>}"
    else pass "rejects ${2}"; fi
}

# The shipped shape, and the same path written without the SELinux backslash escapes.
accepts '/opt/ai-tools/\.nvm/versions/node/[^/]+/lib/node_modules/@anthropic-ai/claude-code/bin/claude\.exe'
accepts '/opt/ai-tools/.nvm/versions/node/[^/]+/bin/some-agent'

# Containment: every way a pattern could name something outside the toolchain root.
rejects ''                                              "an empty pattern"
rejects '/etc/shadow'                                   "a path outside the toolchain root"
rejects '/usr/bin/sudo'                                 "a host binary"
rejects '/opt/ai-tools/.nvm/versions/node/../../../usr/bin/sudo' "a parent-directory traversal"
rejects '/opt/ai-tools/.nvm/versions/node/x|/usr/bin/sudo'       "an alternation escaping the root"
rejects '(/usr/bin/sudo|/opt/ai-tools/.nvm/versions/node/x)'     "a group whose first branch is foreign"
rejects '.*'                                            "a match-anything pattern"
# shellcheck disable=SC2016  # the literal $(...) is the input under test, not an expansion
rejects '/opt/ai-tools/.nvm/versions/node/$(id)/bin/x'  "a shell-substitution character"
rejects '/opt/ai-tools/.nvm/versions/node/a b/bin/x'    "whitespace in the pattern"

# The entrypoint TYPE is the library's, never a manifest's: an agent declares which file is its
# entrypoint, not what label a file gets. A manifest that could name the type could name any
# type -- the reason this constant lives here.
if [[ "${AI_TOOLS_ENTRYPOINT_TYPE:-}" == "ai_tools_exec_t" ]]; then
    pass "the entrypoint type is pinned by the library (ai_tools_exec_t)"
else
    fail "AI_TOOLS_ENTRYPOINT_TYPE is '${AI_TOOLS_ENTRYPOINT_TYPE:-unset}', not the pinned ai_tools_exec_t"
fi

# ── Reconciling the declared rule against the INSTALLED entrypoint ────────────────────────────
# The label is applied from the manifest's declared pattern, but the SELinux transition fires on
# the inode the launcher symlink resolves to -- so the two can disagree, and did nothing about it
# the relabel would report success while every launch fail-closed on an unlabelled entrypoint.
# ai_tools_entrypoint_reconcile_verdict is the pure decision that closes that: `stale` is the
# verdict that must make a relabel FAIL, because it is the one cause a rerun cannot clear. Pinned
# here over the whole truth table; the resolution it consumes needs a provisioned host and lives
# in integration/selinux.sh.
section "relabel: declared-vs-installed entrypoint reconciliation (unit)"

readonly INSTALLED='/opt/ai-tools/.nvm/versions/node/v22.23.2/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe'

# verdict_is <expected> <installed> <covered> <matched> <why>
verdict_is() {
    local expected="$1" got
    got="$(ai_tools_entrypoint_reconcile_verdict "$2" "$3" "$4")"
    if [[ "${got}" == "${expected}" ]]; then pass "${5} -> ${expected}"
    else fail "${5}: expected ${expected}, got '${got}'"; fi
}

if declare -F ai_tools_entrypoint_reconcile_verdict >/dev/null 2>&1; then
    verdict_is ok    "${INSTALLED}" yes yes "an installed entrypoint the declared rule covers"
    verdict_is stale "${INSTALLED}" no  no  "an installed entrypoint the rule matches nothing for"
    verdict_is stale "${INSTALLED}" no  yes "the rule matched some OTHER file, not the installed one"
    verdict_is none  ""            no  no  "no entrypoint installed and no match (not provisioned)"
    verdict_is ok    ""            no  yes "no launcher resolves but the rule matched a copy"
    # Unknown flags must not read as "covered": an input this function cannot interpret errs
    # toward reporting a divergence, which fails a relabel loudly rather than blessing one.
    verdict_is stale "${INSTALLED}" ""      "" "an empty covered flag"
    verdict_is stale "${INSTALLED}" YES     no "a flag that is not the exact literal yes"
    verdict_is none  ""             yes     "" "covered claimed with nothing installed"
else
    skip "entrypoint reconciliation" "ai_tools_entrypoint_reconcile_verdict not defined by ${LIB}"
fi

# ── Reporting an agent-influenced path ────────────────────────────────────────────────────────
# The resolved entrypoint is reached through an npm symlink the SANDBOX account owns, and it is
# printed into a status line that a root helper splits on whitespace and renders to an operator's
# terminal. So the name is carried only while it is drawn from the same character set a declared
# pattern is -- an allowlist, matching ai_tools_entrypoint_fcontext_valid's posture.
section "relabel: reportability of an agent-influenced entrypoint path (unit)"

# reportable/unreportable <path> [why]
reportable() {
    if _ai_tools_entrypoint_path_reportable "$1"; then pass "reports ${1}"
    else fail "refused a legitimate entrypoint path: $1"; fi
}
unreportable() {
    if _ai_tools_entrypoint_path_reportable "$1"; then fail "REPORTED ${2}: ${1:-<empty>}"
    else pass "refuses ${2}"; fi
}

if declare -F _ai_tools_entrypoint_path_reportable >/dev/null 2>&1; then
    reportable "${INSTALLED}"
    reportable '/opt/ai-tools/.nvm/versions/node/v22.23.2/bin/some-agent'
    unreportable ''                              "an empty path"
    unreportable 'relative/claude.exe'           "a relative path"
    unreportable '/opt/ai-tools/../etc/shadow'   "a parent-directory traversal"
    unreportable '/opt/ai-tools/bin/a b'         "whitespace, which would split the status line"
    unreportable "/opt/ai-tools/bin/$(printf 'a\tb')" "a tab, which would split the status line"
    unreportable "/opt/ai-tools/bin/$(printf 'a\033[2Kb')" "an ANSI escape aimed at the terminal"
    # shellcheck disable=SC2016  # the literal $(...) is the input under test, not an expansion
    unreportable '/opt/ai-tools/bin/$(id)'       "shell-substitution characters"
else
    skip "entrypoint path reportability" "_ai_tools_entrypoint_path_reportable not defined by ${LIB}"
fi

# ── The project-label verification predicate (relabel.lib.sh) ─────────────────────────────────
# ai_tools_label_project trusts the ACHIEVED label, not restorecon's exit status: after the
# relabel it calls ai_tools_project_labelled to confirm the tree actually carries
# ai_tools_project_t, so a silent mislabel -- an fcontext rule made unreachable by a path alias
# (file_contexts.subs_dist `/var/opt /opt`), or a module not loaded -- is a hard failure instead
# of a false success. This pins the predicate that gate rests on. A genuinely-labelled path needs
# an enforcing SELinux host, so the positive case (label applies AND verifies) lives in
# integration/selinux.sh; here the negative is hermetic -- a plain /tmp dir carries no project
# type on any host, SELinux or not, so the predicate must report false for it.
section "relabel: project-label verification predicate (unit)"
if declare -F ai_tools_project_labelled >/dev/null 2>&1; then
    mktestdir
    mkdir -p "${TESTDIR}/plain"
    if ai_tools_project_labelled "${TESTDIR}/plain"; then
        fail "ai_tools_project_labelled reported a plain dir as ai_tools_project_t"
    else
        pass "ai_tools_project_labelled rejects a path that is not ai_tools_project_t"
    fi
    if ai_tools_project_labelled "${TESTDIR}/does-not-exist"; then
        fail "ai_tools_project_labelled reported a missing path as labelled"
    else
        pass "ai_tools_project_labelled returns false for a missing path"
    fi
else
    skip "project-label verification" "ai_tools_project_labelled not defined by ${LIB}"
fi

finish
