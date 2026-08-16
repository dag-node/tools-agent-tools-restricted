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
