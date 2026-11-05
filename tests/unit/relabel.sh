#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/relabel.sh
# Unit test for the file-context decisions relabel.lib.sh makes about an agent's declared paths: the toolchain root it
# holds every pattern an agent manifest declares to before the pattern becomes a `semanage fcontext` rule mapping files
# to ai_tools_exec_t -- the exec entrypoint of the confined domain -- and ai_tools_relabel__is_operator_conf_valid,
# which gates the path that becomes an ai_tools_conf_t rule for one operator's config subtree.
#
# The property under test is containment: a declared pattern may only ever match inside the sandbox's own Node
# toolchain, and a config rule may only ever name one account's ~/.config/ai-tools. Both inputs are root-owned or read
# from a passwd entry, so this is defense in depth rather than the only guard, but the failure it prevents is severe
# and silent -- a pattern with an alternation, a traversal, or a foreign prefix would hand ai_tools_exec_t to a file
# outside the toolchain, making it an entrypoint into the agent's domain. The containment predicate itself takes
# the root as an argument and is the launcher re-link's (ai_tools_providers__is_entrypoint_fcontext_valid,
# providers.lib.sh), so its truth table is unit/launcher-target.sh's; what this file pins is the root this library
# passes it, and that the shipped shape holds under it. The entrypoint type is never manifest-supplied and the config
# type never caller-supplied, which this file also pins.
#
# Sources the deployed library; no SELinux host, no privilege of its own. Run as root via sudo (suite contract).

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly LIB="/usr/local/lib/ai-tools/relabel.lib.sh"
section "relabel: agent entrypoint file-context validation (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "entrypoint fcontext validation" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}" || ! declare -F ai_tools_providers__is_entrypoint_fcontext_valid >/dev/null 2>&1; then
    fail "could not source ${LIB}, or ai_tools_providers__is_entrypoint_fcontext_valid is not in scope once it is sourced"
    finish; exit
fi
# The ROOT is the library's: every declared pattern is held to it, so a manifest chooses which file under the toolchain
# is its entrypoint and never a tree of its own. Pinned by value and by being readonly -- a root a caller could move
# would move what may be labelled into the confined domain's entrypoint type.
if [[ "${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT:-}" == "/opt/ai-tools/.nvm/versions/node" ]]; then
    pass "the Node versions root is pinned by the library (/opt/ai-tools/.nvm/versions/node)"
else
    fail "AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT is '${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT:-unset}', not the pinned toolchain root"
fi
readonly_names="$(readonly -p)"   # captured, then matched: a builtin writing into a closed pipe would fail the pipeline
if grep -q ' AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT=' <<<"${readonly_names}"; then
    pass "the Node versions root is readonly"
else
    fail "AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT is not readonly"
fi
# The shipped shape holds under the pinned root, and a host binary does not: the two ends of the containment as this
# library applies it. The predicate's own truth table is unit/launcher-target.sh's.
if ai_tools_providers__is_entrypoint_fcontext_valid \
        '/opt/ai-tools/\.nvm/versions/node/[^/]+/lib/node_modules/@anthropic-ai/claude-code/bin/claude\.exe' \
        "${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}"; then
    pass "the shipped entrypoint shape is contained under the pinned root"
else
    fail "the shipped entrypoint shape is refused under ${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}"
fi
if ai_tools_providers__is_entrypoint_fcontext_valid '/usr/bin/sudo' "${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}"; then
    fail "ACCEPTED a host binary under the pinned root"
else
    pass "a host binary is refused under the pinned root"
fi

# The entrypoint TYPE is the library's, never a manifest's: an agent declares which file is its entrypoint, not
# what label a file gets. A manifest that could name the type could name any type -- the reason this constant lives
# here.
if [[ "${AI_TOOLS_RELABEL__ENTRYPOINT_TYPE:-}" == "ai_tools_exec_t" ]]; then
    pass "the entrypoint type is pinned by the library (ai_tools_exec_t)"
else
    fail "AI_TOOLS_RELABEL__ENTRYPOINT_TYPE is '${AI_TOOLS_RELABEL__ENTRYPOINT_TYPE:-unset}', not the pinned ai_tools_exec_t"
fi

# ── Reconciling the declared rule against the INSTALLED entrypoint ────────────────────────────
# The label is applied from the manifest's declared pattern, but the SELinux transition fires on the inode the launcher
# symlink resolves to -- so the two can disagree, and this file covered neither side of it the relabel would report
# success while every launch fail-closed on an unlabelled entrypoint. ai_tools_relabel__evaluate_entrypoint_reconcile is
# the pure decision that closes that: `stale` and `incomplete` are the verdicts that must make a relabel FAIL, being
# the causes a rerun cannot clear, and they must be told apart -- each sends the operator to a different repair,
# and naming the wrong one is a loop rather than a fix. Pinned here over the whole truth table; the resolution it
# consumes needs a provisioned host and lives in integration/selinux.sh.
section "relabel: declared-vs-installed entrypoint reconciliation (unit)"

readonly INSTALLED='/opt/ai-tools/.nvm/versions/node/v22.23.2/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe'

# verdict_is <expected> <installed> <covered> <matched> <why> [copy]
verdict_is() {
    local expected="$1" got
    got="$(ai_tools_relabel__evaluate_entrypoint_reconcile "$2" "$3" "$4" "${6:-}")"
    if [[ "${got}" == "${expected}" ]]; then pass "${5} -> ${expected}"
    else fail "${5}: expected ${expected}, got '${got}'"; fi
}

if declare -F ai_tools_relabel__evaluate_entrypoint_reconcile >/dev/null 2>&1; then
    verdict_is ok         "${INSTALLED}" yes yes "an installed entrypoint the declared rule covers"
    verdict_is incomplete "${INSTALLED}" no  no  "an installed entrypoint the rule matches nothing for"
    verdict_is stale      "${INSTALLED}" no  yes "the rule matched some OTHER file, not the installed one"
    verdict_is none       ""             no  no  "no entrypoint installed and no match (not provisioned)"
    verdict_is ok         ""             no  yes "no launcher resolves but the rule matched a copy"
    # A copy of a declared entrypoint is the links' fault, not the manifest's: the toolchain run restores it, and naming
    # a newer agent package would send the operator to a repair that does not change the file.
    verdict_is copied     "${INSTALLED}" no  yes "the launcher resolves to a byte-identical copy of a match" yes
    verdict_is stale      "${INSTALLED}" no  yes "the installed file differs from every match" no
    verdict_is incomplete "${INSTALLED}" no  no  "a copy flag with nothing matched cannot be a copy" yes
    verdict_is ok         "${INSTALLED}" yes yes "covered wins over a copy flag" yes
    verdict_is stale      "${INSTALLED}" no  yes "a copy flag that is not the exact literal yes" YES
    # Unknown flags must not read as "covered": an input this function cannot interpret errs toward reporting
    # a divergence, which fails a relabel loudly rather than blessing one. Which divergence it lands on decides only
    # the remedy the caller names.
    verdict_is incomplete "${INSTALLED}" ""      "" "an empty covered flag"
    verdict_is incomplete "${INSTALLED}" YES     no "a flag that is not the exact literal yes"
    verdict_is none       ""             yes     "" "covered claimed with nothing installed"
else
    skip "entrypoint reconciliation" "ai_tools_relabel__evaluate_entrypoint_reconcile not defined by ${LIB}"
fi

# ── Reporting an agent-influenced path ────────────────────────────────────────────────────────
# The resolved entrypoint is reached through an npm symlink the SANDBOX account owns, and it is printed into a status
# line that a root helper splits on whitespace and renders to an operator's terminal. So the name is carried only while
# it is drawn from the same character set a declared pattern is -- an allowlist, matching
# ai_tools_providers__is_entrypoint_fcontext_valid's posture.
section "relabel: reportability of an agent-influenced entrypoint path (unit)"

# reportable/unreportable <path> [why]
reportable() {
    if _ai_tools_relabel__is_entrypoint_path_reportable "$1"; then pass "reports ${1}"
    else fail "refused a legitimate entrypoint path: $1"; fi
}
unreportable() {
    if _ai_tools_relabel__is_entrypoint_path_reportable "$1"; then fail "REPORTED ${2}: ${1:-<empty>}"
    else pass "refuses ${2}"; fi
}

if declare -F _ai_tools_relabel__is_entrypoint_path_reportable >/dev/null 2>&1; then
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
    skip "entrypoint path reportability" "_ai_tools_relabel__is_entrypoint_path_reportable not defined by ${LIB}"
fi

# ── The project-label verification predicate (relabel.lib.sh) ─────────────────────────────────
# ai_tools_relabel__label_project trusts the ACHIEVED label, not restorecon's exit status: after the relabel it calls
# ai_tools_relabel__is_project_labelled to confirm the tree actually carries ai_tools_project_t, so a silent mislabel --
# an fcontext rule made unreachable by a path alias (file_contexts.subs_dist `/var/opt /opt`), or a module not loaded --
# is a hard failure instead of a false success. This pins the predicate that gate rests on. A genuinely-labelled path
# needs an enforcing SELinux host, so the positive case (label applies AND verifies) lives in integration/selinux.sh;
# here the negative is hermetic -- a plain /tmp dir does not carry a project type on any host, SELinux or not,
# so the predicate must report false for it.
section "relabel: project-label verification predicate (unit)"
if declare -F ai_tools_relabel__is_project_labelled >/dev/null 2>&1; then
    mktestdir
    mkdir -p "${TESTDIR}/plain"
    if ai_tools_relabel__is_project_labelled "${TESTDIR}/plain"; then
        fail "ai_tools_relabel__is_project_labelled reported a plain dir as ai_tools_project_t"
    else
        pass "ai_tools_relabel__is_project_labelled rejects a path that is not ai_tools_project_t"
    fi
    if ai_tools_relabel__is_project_labelled "${TESTDIR}/does-not-exist"; then
        fail "ai_tools_relabel__is_project_labelled reported a missing path as labelled"
    else
        pass "ai_tools_relabel__is_project_labelled returns false for a missing path"
    fi
else
    skip "project-label verification" "ai_tools_relabel__is_project_labelled not defined by ${LIB}"
fi

# ── The build-output rule beside the project rule ─────────────────────────────────────────────
# A claim labels a project's build-output directories ai_tools_project_build_t, the type the buildexec policy group may
# grant execute on, from the names each installed integration manifest declares (build_output_dirs). Three properties
# carry the weight. The NAMES come from the manifests and are validated to one plain component each, since they are
# spliced into a file-context regex and a `/`, `|` or `(` would let a manifest widen the rule past the directories it
# names. The label writes the project rule FIRST and the build rule second, in that order, because among rules sharing
# a stem the later one is the match. And the unlabel drops the build rule by LISTING the local rules under the project
# rule, so a rule written under an earlier name set is removed with the claim rather than left on a subtree the confined
# domain manages. semanage, the tree walk and the availability probe are stubbed; no policy store is touched.
section "relabel: the build-output rule (unit)"
if declare -F ai_tools_relabel__read_project_build_pattern >/dev/null 2>&1 \
        && declare -F ai_tools_relabel__label_project >/dev/null 2>&1; then
    # The manifest reader is stubbed at the seam relabel.lib.sh consumes it through.
    ai_tools_providers__list_integrations_declaring() {
        [[ "$1" == build_output_dirs ]] || return 0
        printf 'dotnet\tbin obj artifacts\n'
        printf 'evil\tbin/../etc x|y (z) .hidden\n'   # every name but .hidden must be refused
    }
    # C-locale order: `.` sorts before a letter, and the order is part of the pattern a claim writes.
    got="$(ai_tools_relabel__read_project_build_pattern /home/op/proj)"
    if [[ "${got}" == '/home/op/proj(/.*)?/(\.hidden|artifacts|bin|obj)(/.*)?' ]]; then
        pass "the build pattern unions the declared names in C order, refuses a path or a metacharacter, and escapes a dot"
    else
        fail "build pattern: '${got}'"
    fi
    ai_tools_providers__list_integrations_declaring() { :; }
    if ai_tools_relabel__read_project_build_pattern /home/op/proj >/dev/null; then
        fail "a host with no declared build-output names still produced a build pattern"
    else
        pass "with no declared names the build pattern is empty and the caller writes no rule"
    fi

    # Order and content of the semanage calls a label makes.
    ai_tools_providers__list_integrations_declaring() { printf 'dotnet\tbin obj\n'; }
    ai_tools_relabel__is_available() { return 0; }
    ai_tools_relabel__is_project_labelled()  { return 0; }
    eval "build_real_relabel_tree() $(declare -f _ai_tools_relabel__relabel_tree | tail -n +2)"
    _ai_tools_relabel__relabel_tree() { return 0; }
    CALLS=""
    semanage() { CALLS+="$*"$'\n'; return 0; }
    ai_tools_relabel__label_project /home/op/proj
    if [[ "${CALLS}" == "fcontext -a -t ai_tools_project_t /home/op/proj(/.*)?"$'\n'"fcontext -a -t ai_tools_project_build_t -- /home/op/proj(/.*)?/(bin|obj)(/.*)?"$'\n' ]]; then
        pass "a label registers the project rule, then the build rule"
    else
        fail "label calls: ${CALLS//$'\n'/ | }"
    fi
    # A build rule the store refuses (a policy older than the library) fails the label, so the claim reports it rather
    # than leaving output on a type the group cannot run.
    semanage() { [[ "$*" == *ai_tools_project_build_t* ]] && return 1; return 0; }
    if ai_tools_relabel__label_project /home/op/proj; then
        fail "a refused build rule did not fail the label"
    else
        pass "a refused build rule fails the label (reported, not silently skipped)"
    fi
    # Sandbox clones take neither rule: the static rules cover them.
    CALLS=""; semanage() { CALLS+="$*"$'\n'; return 0; }
    ai_tools_relabel__label_project /var/opt/ai-tools/sandbox-projects/clone
    if [[ -z "${CALLS}" ]]; then
        pass "a sandbox clone registers no per-project rule"
    else
        fail "a sandbox clone registered rules: ${CALLS//$'\n'/ | }"
    fi

    # The unlabel finds the build rule by listing, whatever name set wrote it, and parses the row format semanage prints
    # (pattern, file-type words, context).
    semanage() {
        case "$*" in
            "fcontext -l -C -n")
                printf '%-50s %-18s %s\n' '/home/op/proj(/.*)?' 'all files' 'system_u:object_r:ai_tools_project_t:s0'
                printf '%-50s %-18s %s\n' '/home/op/proj(/.*)?/(bin|target)(/.*)?' 'all files' 'system_u:object_r:ai_tools_project_build_t:s0'
                printf '%-50s %-18s %s\n' '/home/op/proj-two(/.*)?/(bin)(/.*)?' 'all files' 'system_u:object_r:ai_tools_project_build_t:s0'
                printf '%-50s %-18s %s\n' '/home/op/other space(/.*)?/(bin)(/.*)?' 'all files' 'system_u:object_r:ai_tools_project_build_t:s0'
                return 0 ;;
            *) CALLS+="$*"$'\n'; return 0 ;;
        esac
    }
    CALLS=""
    ai_tools_relabel__unlabel_project /home/op/proj || true   # 3: no tree stands at the path; the row reads the calls
    if [[ "${CALLS}" == "fcontext -d -- /home/op/proj(/.*)?/(bin|target)(/.*)?"$'\n'"fcontext -d /home/op/proj(/.*)?"$'\n' ]]; then
        pass "an unlabel drops the build rule found by listing (an older name set included), then the project rule, and leaves a sibling project's rule alone"
    else
        fail "unlabel calls: ${CALLS//$'\n'/ | }"
    fi
    got="$(_ai_tools_relabel__list_local_rules_under '/home/op/other space')"
    if [[ "${got}" == '/home/op/other space(/.*)?/(bin)(/.*)?' ]]; then
        pass "a pattern carrying a space survives the row parse"
    else
        fail "row parse of a pattern with a space: '${got}'"
    fi

    # A project path is a literal inside the rule's regex: `.` in app.v1 would also match appXv1, and `+`, `(`, `|`
    # change which paths the rule covers. The label writes the escaped path, and the unlabel removes the escaped rule.
    got="$(ai_tools_relabel__get_fcontext_literal '/home/op/a.b+c(d)|e[f]$^*?{g}\h')"
    if [[ "${got}" == '/home/op/a\.b\+c\(d\)\|e\[f\]\$\^\*\?\{g\}\\h' ]]; then
        pass "ai_tools_relabel__get_fcontext_literal escapes every regex metacharacter and leaves the rest"
    else
        fail "ai_tools_relabel__get_fcontext_literal: '${got}'"
    fi
    CALLS=""; semanage() { CALLS+="$*"$'\n'; return 0; }
    ai_tools_relabel__label_project '/home/op/app.v1+x'
    if [[ "${CALLS}" == "fcontext -a -t ai_tools_project_t /home/op/app\\.v1\\+x(/.*)?"$'\n'"fcontext -a -t ai_tools_project_build_t -- /home/op/app\\.v1\\+x(/.*)?/(bin|obj)(/.*)?"$'\n' ]]; then
        pass "a label escapes the project path in both rules"
    else
        fail "label calls for a path with metacharacters: ${CALLS//$'\n'/ | }"
    fi
    CALLS=""
    ai_tools_relabel__unlabel_project '/home/op/app.v1' || true
    if [[ "${CALLS}" == "fcontext -d /home/op/app\\.v1(/.*)?"$'\n' ]]; then
        pass "an unlabel removes the escaped rule alone"
    else
        fail "unlabel calls for a dotted path: ${CALLS//$'\n'/ | }"
    fi
    unset -f ai_tools_providers__list_integrations_declaring ai_tools_relabel__is_available \
             ai_tools_relabel__is_project_labelled semanage
    eval "_ai_tools_relabel__relabel_tree() $(declare -f build_real_relabel_tree | tail -n +2)"
    unset -f build_real_relabel_tree
    unset CALLS
else
    skip "build-output rule" "ai_tools_relabel__read_project_build_pattern not defined by ${LIB}"
fi

# ── The walks run the descriptor-pinned tree walker ──────────────────────────────────────────
# Every recursive relabel goes through _ai_tools_relabel__relabel_tree, which runs ai-tools-relabel-tree. The walk is
# stubbed to each status it returns, recording its argument, and each function that runs it is driven over the status:
# a walker that could not run (6) reaches the caller before the post-condition, a walk that left hardlinked files (4)
# passes the post-condition and is returned, an entry the walk could not label (1) fails the function, an unlabel
# of a name that is not a directory reaches the walker, and an unlabel of an absent directory drops its rules with no
# walk.
section "relabel: the walks run the tree walker and read each of its statuses (unit)"
if declare -F _ai_tools_relabel__relabel_tree >/dev/null 2>&1 && declare -F ai_tools_relabel__label_project >/dev/null 2>&1; then
    if [[ ! -e /usr/local/libexec/ai-tools/ai-tools-relabel-tree ]]; then
        status=0; _ai_tools_relabel__relabel_tree "${TESTDIR}" || status=$?
        if [[ "${status}" -eq 6 && "${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS}" == *"/usr/local/libexec/ai-tools/ai-tools-relabel-tree"* ]]; then
            pass "a walker that is not installed returns 6 and names its path"
        else
            fail "a walker that is not installed: status ${status}, '${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS}'"
        fi
    else
        note "an absent walker" "the walker is installed on this host, so its absence is not driven"
    fi
    eval "walk_real_relabel_tree() $(declare -f _ai_tools_relabel__relabel_tree | tail -n +2)"
    WALKS=""; LABEL_CHECKS=0; stub_labelled=0
    _ai_tools_relabel__relabel_tree() {
        WALKS+="$1"$'\n'
        AI_TOOLS_RELABEL__TREE_DIAGNOSTICS="${stub_walk_diagnostics}"
        _AI_TOOLS_RELABEL__SKIPPED_HARDLINK_COUNT="${stub_skipped_count:-0}"
        return "${stub_walk_status}"
    }
    ai_tools_relabel__is_available() { return 0; }
    ai_tools_relabel__is_project_labelled() { LABEL_CHECKS=$(( LABEL_CHECKS + 1 )); return "${stub_labelled}"; }
    ai_tools_providers__list_integrations_declaring() { :; }
    semanage() { return 0; }
    # walk_is <function> <dir> <walk-status> <labelled-status> <expected> <expected-checks> <why>
    walk_is() {
        local fn="$1" dir="$2" expected="$5" expected_checks="$6" why="$7" status=0
        stub_walk_status="$3"; stub_labelled="$4"; stub_walk_diagnostics="skipped hardlinked path ${dir}/x (link count 2)"
        WALKS=""; LABEL_CHECKS=0
        "${fn}" "${dir}" >/dev/null 2>&1 || status=$?
        if [[ "${status}" -eq "${expected}" && "${WALKS}" == "${dir}"$'\n' && "${LABEL_CHECKS}" -eq "${expected_checks}" ]]; then
            pass "${why}: status ${expected}"
        else
            fail "${why}: status ${status}, walks '${WALKS//$'\n'/|}', post-condition reads ${LABEL_CHECKS}"
        fi
    }
    walk_is ai_tools_relabel__label_project /home/op/proj 0 0 0 1 "control: a label whose walk labelled every entry"
    walk_is ai_tools_relabel__label_project /home/op/proj 6 0 6 0 "a label whose walker could not run returns before the post-condition"
    walk_is ai_tools_relabel__label_project /home/op/proj 4 0 4 1 "a label whose walk left hardlinked files passes the post-condition"
    walk_is ai_tools_relabel__label_project /home/op/proj 4 1 1 1 "a label whose walk left hardlinked files and a root on another type fails"
    walk_is ai_tools_relabel__label_project /home/op/proj 1 0 1 0 "a label whose walk could not label an entry fails"
    # A root the walk left on another type carries why, in place of the walk's own lines, for the helper to print.
    stub_walk_status=4; stub_labelled=1
    ai_tools_relabel__label_project /home/op/proj >/dev/null 2>&1 || true
    if [[ "${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS}" == *"/home/op/proj does not carry ai_tools_project_t"* ]]; then
        pass "a root the walk left on another type sets the diagnostic that names it"
    else
        fail "a root left on another type: diagnostic '${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS}'"
    fi
    # A label refused before the walk starts finds no diagnostic, an earlier walk's included.
    AI_TOOLS_RELABEL__TREE_DIAGNOSTICS="left by an earlier walk"
    semanage() { return 1; }
    ai_tools_relabel__label_project /home/op/proj >/dev/null 2>&1 || true
    if [[ -z "${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS}" ]]; then
        pass "a label refused at its rule clears an earlier walk's diagnostic"
    else
        fail "a label refused at its rule kept '${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS}'"
    fi
    semanage() { return 0; }
    walk_is ai_tools_relabel__unlabel_project "${TESTDIR}" 0 0 0 0 "control: an unlabel of a directory walks it"
    walk_is ai_tools_relabel__unlabel_project "${TESTDIR}" 4 0 4 0 "an unlabel whose walk left hardlinked files"
    walk_is ai_tools_relabel__unlabel_project "${TESTDIR}" 6 0 6 0 "an unlabel whose walker could not run"
    walk_is ai_tools_relabel__unlabel_project "${TESTDIR}" 1 0 1 0 "an unlabel whose walk could not label an entry"
    # A name at the root that is not a directory -- a tree renamed aside and a file or a link put in its place --
    # reaches the walker, whose root check refuses it with 1, rather than reading as an absent tree.
    : > "${TESTDIR}/file-root"
    ln -s "${TESTDIR}/absent-target" "${TESTDIR}/dangling-root"
    ln -s "${TESTDIR}" "${TESTDIR}/dir-link-root"
    if [[ -f "${TESTDIR}/file-root" && -L "${TESTDIR}/dangling-root" && ! -e "${TESTDIR}/dangling-root" \
            && -L "${TESTDIR}/dir-link-root" && -d "${TESTDIR}/dir-link-root" ]]; then
        pass "setup: a regular file, a dangling symlink and a symlink to a directory stand at three roots"
    else
        fail "setup: the three non-directory roots were not created"
    fi
    walk_is ai_tools_relabel__unlabel_project "${TESTDIR}/file-root" 1 0 1 0 \
        "an unlabel of a regular file at the root walks it and fails"
    walk_is ai_tools_relabel__unlabel_project "${TESTDIR}/dangling-root" 1 0 1 0 \
        "an unlabel of a dangling symlink at the root walks it and fails"
    walk_is ai_tools_relabel__unlabel_project "${TESTDIR}/dir-link-root" 1 0 1 0 \
        "an unlabel of a directory symlink at the root walks it and fails"
    CALLS=""; WALKS=""; stub_walk_status=0
    semanage() { CALLS+="$*"$'\n'; return 0; }
    status=0; ai_tools_relabel__unlabel_project "${TESTDIR}/absent" || status=$?
    if [[ "${status}" -eq 3 && -z "${WALKS}" \
            && "${CALLS}" == *"fcontext -d $(ai_tools_relabel__get_fcontext_literal "${TESTDIR}/absent")(/.*)?"* ]]; then
        pass "an unlabel of an absent directory drops its rules, does not walk, and returns 3"
    else
        fail "an unlabel of an absent directory: status ${status}, walks '${WALKS}', calls ${CALLS//$'\n'/ | }"
    fi
    # A tree that stands when the unlabel starts and is moved away while the rules are dropped reads as absent
    # at the walk, and returns 3 for the caller to tell from a tree already gone.
    mkdir "${TESTDIR}/vanishing"
    semanage() { CALLS+="$*"$'\n'; [[ "$*" != "fcontext -d "* ]] || rm -rf -- "${TESTDIR}/vanishing"; return 0; }
    CALLS=""; WALKS=""
    status=0; ai_tools_relabel__unlabel_project "${TESTDIR}/vanishing" || status=$?
    if [[ "${status}" -eq 3 && -z "${WALKS}" && ! -e "${TESTDIR}/vanishing" && "${CALLS}" == *"fcontext -d "* ]]; then
        pass "an unlabel whose tree is removed while its rules are dropped returns 3 and does not walk"
    else
        fail "an unlabel whose tree is removed during the rule drop: status ${status}, walks '${WALKS}', calls ${CALLS//$'\n'/ | }"
    fi
    semanage() { CALLS+="$*"$'\n'; return 0; }

    # The config directory: a name under the control-plane home that exists on every installed host stands in for one,
    # with the manifest reader, the validator and the rule writer stubbed.
    if [[ -d "${CP_HOME:-/opt/ai-tools}/bin" ]] && declare -F _ai_tools_relabel__label_agent_config_dir >/dev/null 2>&1; then
        # Each function the rows override is kept, and put back after them, so a later section reads the library's own.
        walk_saved="$(declare -f ai_tools_providers__read_agent_manifest_field ai_tools_control_plane__is_agent_config_dir_valid \
                          _ai_tools_relabel__register_fcontext _ai_tools_relabel__read_live_type \
                          _ai_tools_relabel__is_entrypoint_policy_active ai_tools_providers__list_enabled_agents \
                          _ai_tools_relabel__label_agent_entrypoint 2>/dev/null || true)"
        ai_tools_providers__read_agent_manifest_field() { case "$2" in config_dir) printf 'bin' ;; *) : ;; esac; }
        ai_tools_control_plane__is_agent_config_dir_valid() { return 0; }
        _ai_tools_relabel__register_fcontext() { return 0; }
        _ai_tools_relabel__read_live_type() { printf '%s\n' "${AI_TOOLS_RELABEL__AGENT_CONFIG_TYPE}"; }
        config_path="${CP_HOME:-/opt/ai-tools}/bin"
        # config_is <walk-status> <expected-status> <expected-lines> <why>
        config_is() {
            local status=0 line
            stub_walk_status="$1"; stub_skipped_count=2
            stub_walk_diagnostics="skipped hardlinked path ${config_path}/a (link count 2); skipped hardlinked path ${config_path}/b (link count 3)"
            line="$(_ai_tools_relabel__label_agent_config_dir acme)" || status=$?
            if [[ "${status}" -eq "$2" && "${line}" == "$3" ]]; then
                pass "$4: status $2"
            else
                fail "$4: status ${status}, lines '${line//$'\n'/ | }'"
            fi
        }
        config_is 0 0 "ok ${config_path}" "control: a config directory whose walk labelled every entry"
        config_is 4 0 "partial acme 2"$'\n'"ok ${config_path}" "a config directory whose walk left two hardlinked files"
        config_is 6 1 "skip acme could not walk its config directory -- skipped hardlinked path ${config_path}/a (link count 2); skipped hardlinked path ${config_path}/b (link count 3)" \
            "a config directory whose walker could not run"
        config_is 1 1 "bad ${config_path} unknown ${AI_TOOLS_RELABEL__AGENT_CONFIG_TYPE}" "a config directory whose walk could not label an entry"
        # The agent's closing verdict over a walker that could not run: the config half returns 1, so it is filed
        # failed.
        _ai_tools_relabel__is_entrypoint_policy_active() { return 0; }
        ai_tools_providers__list_enabled_agents() { printf 'acme\t\t\n'; }
        _ai_tools_relabel__label_agent_entrypoint() { printf 'ok /fixture-entrypoint\n'; return 0; }
        stub_walk_status=6; status=0
        line="$(ai_tools_relabel__label_agent_paths)" || status=$?
        if [[ "${status}" -eq 1 && "${line}" == *"agent acme failed" ]]; then
            pass "an agent whose config walk could not run is filed failed and fails the run"
        else
            fail "an agent whose config walk could not run: status ${status}, '${line//$'\n'/ | }'"
        fi
        # The erase: the rules are dropped, then the walk's status is returned, a walk that could not label an entry
        # as 5, apart from the 1 of an agent that declares no usable rule.
        for walk_pair in 4:4 6:6 1:5; do
            stub_walk_status="${walk_pair%%:*}"; status=0
            ai_tools_relabel__unlabel_agent_paths acme >/dev/null 2>&1 || status=$?
            if [[ "${status}" -eq "${walk_pair##*:}" ]]; then
                pass "an agent unlabel whose config walk returned ${walk_pair%%:*} returns ${walk_pair##*:}"
            else
                fail "an agent unlabel whose config walk returned ${walk_pair%%:*} returned ${status}"
            fi
        done
        stub_walk_status=0; status=0
        ai_tools_relabel__unlabel_agent_paths acme >/dev/null 2>&1 || status=$?
        if [[ "${status}" -eq 0 ]]; then
            pass "control: an agent unlabel whose config walk labelled every entry returns 0"
        else
            fail "control: an agent unlabel whose config walk labelled every entry returned ${status}"
        fi
        unset -f ai_tools_providers__read_agent_manifest_field ai_tools_control_plane__is_agent_config_dir_valid \
                 _ai_tools_relabel__register_fcontext _ai_tools_relabel__read_live_type \
                 _ai_tools_relabel__is_entrypoint_policy_active ai_tools_providers__list_enabled_agents \
                 _ai_tools_relabel__label_agent_entrypoint
        eval "${walk_saved}"
        unset walk_saved
    else
        skip "the config-directory walk" "no ${CP_HOME:-/opt/ai-tools}/bin to stand in for a config directory"
    fi
    eval "_ai_tools_relabel__relabel_tree() $(declare -f walk_real_relabel_tree | tail -n +2)"
    unset -f walk_real_relabel_tree ai_tools_relabel__is_available ai_tools_relabel__is_project_labelled \
             ai_tools_providers__list_integrations_declaring semanage
    unset CALLS WALKS
else
    skip "the tree walk" "_ai_tools_relabel__relabel_tree not defined by ${LIB}"
fi

# ── Reporting WHY a file-context rule was refused ─────────────────────────────────────────────
# semanage's stderr is the only account of why a rule did not land, and "could not register its entrypoint file-context
# rule" does not name a cause on its own -- an operator reading it has no next step to act on, and the condition (a
# policy store another transaction holds, a type the loaded policy does not define) needs different remedies.
# So the reason is collected for the caller to log. The stream split is the load-bearing part: the caller parses this
# library's STDOUT as verdict lines, so semanage's own stdout must never reach it while its stderr must survive.
# semanage is stubbed as a shell function -- no policy store is touched.
section "relabel: the local rules naming a type of the policy (unit)"
if ! declare -F ai_tools_relabel__list_local_rules_naming_policy_types >/dev/null 2>&1; then
    skip "policy-type rule listing" "${LIB} does not define ai_tools_relabel__list_local_rules_naming_policy_types"
else
    # A store mixing rules this library wrote, rules an earlier release wrote, and rules of other types: the unload
    # refuses on every ai_tools-typed one whatever wrote it, so the listing is that set and nothing else.
    semanage() {
        [[ "$*" == "fcontext -l -C -n" ]] || return 1
        printf '%-50s %-18s %s\n' '/home/op/gone(/.*)?' 'all files' 'system_u:object_r:ai_tools_project_t:s0'
        printf '%-50s %-18s %s\n' '/home/op/.config/ai-tools(/.*)?' 'all files' 'system_u:object_r:ai_tools_conf_t:s0'
        printf '%-50s %-18s %s\n' '/opt/ai-tools/\.nvm/versions/node/[^/]+/lib/node_modules/@acme/cli/bin/acme\.exe' 'regular file' 'system_u:object_r:ai_tools_exec_t:s0'
        printf '%-50s %-18s %s\n' '/home/op/other space(/.*)?/(bin)(/.*)?' 'all files' 'system_u:object_r:ai_tools_project_build_t:s0'
        printf '%-50s %-18s %s\n' '/home/op/gone(/.*)?/www(/.*)?' 'all files' 'system_u:object_r:httpd_sys_content_t:s0'
        printf '%-50s %-18s %s\n' '/srv/www(/.*)?' 'directory' 'system_u:object_r:httpd_sys_content_t:s0'
        printf '%-50s %-18s %s\n' '/var/lib/acme/sock' 'socket' 'system_u:object_r:ai_tools_run_t:s0'
    }
    got="$(ai_tools_relabel__list_local_rules_naming_policy_types)"
    expected="/home/op/gone(/.*)?"$'\t'"a"$'\t'"ai_tools_project_t"$'\n'
    expected+="/home/op/.config/ai-tools(/.*)?"$'\t'"a"$'\t'"ai_tools_conf_t"$'\n'
    expected+='/opt/ai-tools/\.nvm/versions/node/[^/]+/lib/node_modules/@acme/cli/bin/acme\.exe'$'\t'"f"$'\t'"ai_tools_exec_t"$'\n'
    expected+="/home/op/other space(/.*)?/(bin)(/.*)?"$'\t'"a"$'\t'"ai_tools_project_build_t"$'\n'
    expected+="/var/lib/acme/sock"$'\t'"s"$'\t'"ai_tools_run_t"
    if [[ "${got}" == "${expected}" ]]; then
        pass "every local rule naming an ai_tools type is listed with its pattern, file-type letter and type, whatever wrote it, and no rule of another type is"
    else
        fail "policy-type rule listing: $(printf '%s' "${got}" | tr '\t\n' '|;')"
    fi
    semanage() { return 1; }
    rc=0; got="$(ai_tools_relabel__list_local_rules_naming_policy_types)" || rc=$?
    [[ -z "${got}" && ${rc} -eq 0 ]] && pass "a store that cannot be listed yields no rule and no failure" \
        || fail "unlistable store: rc ${rc}, output '${got}'"

    # The config unlabel drops the rule under the escaped encoding the label writes.
    CALLS=""; semanage() { CALLS+="$*"$'\n'; return 0; }
    ai_tools_relabel__is_available() { return 0; }
    restorecon() { return 0; }
    ai_tools_relabel__unlabel_operator_conf '/home/some.user/.config/ai-tools'
    if [[ "${CALLS}" == 'fcontext -d -f a -- /home/some\.user/\.config/ai-tools(/.*)?'$'\n' ]]; then
        pass "the config unlabel drops the escaped rule alone"
    else
        fail "config unlabel calls: ${CALLS//$'\n'/ | }"
    fi
fi

section "relabel: a refused file-context rule reports semanage's reason (unit)"
if declare -F _ai_tools_relabel__register_fcontext >/dev/null 2>&1 \
        && declare -F _ai_tools_relabel__label_agent_entrypoint >/dev/null 2>&1; then
    semanage() {
        case "${2:-}" in
            -a) printf 'libsemanage: Could not get direct lock\nOSError: Resource unavailable\n' >&2; return 1 ;;
            -m) printf 'ValueError: File context for /opt/ai-tools/x is not defined\n' >&2; return 1 ;;
            *)  return 0 ;;
        esac
    }
    _ai_tools_relabel__register_fcontext add f ai_tools_exec_t '/opt/ai-tools/x' >/dev/null && fcontext_rc=0 || fcontext_rc=$?
    if [[ "${fcontext_rc}" -ne 0 ]]; then pass "a refused rule returns non-zero"
    else fail "a refused rule returned 0"; fi
    # The ADD's message names the cause; the modify's reports the consequence ("not defined"), so reporting the modify's
    # would send an operator after the wrong condition.
    if [[ "${AI_TOOLS_RELABEL__FCONTEXT_ERROR:-}" == *"Could not get direct lock"* ]]; then
        pass "the reason carries the add's stderr"
    else fail "the reason does not carry the add's stderr: ${AI_TOOLS_RELABEL__FCONTEXT_ERROR:-<none>}"; fi
    # The reason lands on a status line whose reader splits the report per line, so a multi-line semanage message must
    # not read as extra verdicts.
    if [[ "${AI_TOOLS_RELABEL__FCONTEXT_ERROR:-}" != *$'\n'* ]]; then
        pass "the reason is collapsed to a single line"
    else fail "the reason spans lines: ${AI_TOOLS_RELABEL__FCONTEXT_ERROR:-<none>}"; fi

    # The reason has to reach the caller through the REPORT, not through the variable: ai-tools-relabel-agent runs
    # the labelling inside a `$(...)`, and a variable set in that subshell is gone by the time the renderer reads it.
    # So the capture is the production call shape, and the assertion is that the status line itself carries the cause.
    ai_tools_providers__read_agent_manifest_field() {
        if [[ "$2" == entrypoint_fcontext ]]; then
            printf '/opt/ai-tools/\\.nvm/versions/node/[^/]+/bin/some-agent'
        fi
        return 0
    }
    ai_tools_relabel__resolve_agent_entrypoint_path() { return 1; }
    AI_TOOLS_RELABEL__FCONTEXT_ERROR=""
    skip_line="$(_ai_tools_relabel__label_agent_entrypoint some-agent)" || true
    if [[ "${skip_line}" == skip* && "${skip_line}" == *"Could not get direct lock"* ]]; then
        pass "the reason survives the report's subshell on the status line"
    else fail "the status line does not carry the cause: ${skip_line:-<empty>}"; fi
    if [[ "$(printf '%s' "${skip_line}" | wc -l)" -eq 0 ]]; then
        pass "the refusal stays one status line"
    else fail "the refusal spans several report lines: ${skip_line}"; fi

    # semanage announces "already defined, modifying instead" on STDOUT, which the caller reads as a verdict line --
    # so a rule that registers must leave that stream empty.
    semanage() { echo "File context already defined, modifying instead"; return 0; }
    fcontext_stdout="$(_ai_tools_relabel__register_fcontext add a ai_tools_home_t '/opt/ai-tools/\.claude(/.*)?')" \
        && fcontext_rc=0 || fcontext_rc=$?
    if [[ "${fcontext_rc}" -eq 0 ]]; then pass "a rule that registers returns 0"
    else fail "a successful add returned ${fcontext_rc}"; fi
    if [[ -z "${fcontext_stdout}" ]]; then
        pass "semanage's stdout never reaches the caller's verdict stream"
    else fail "semanage stdout leaked into the report: ${fcontext_stdout}"; fi
    unset -f semanage ai_tools_providers__read_agent_manifest_field ai_tools_relabel__resolve_agent_entrypoint_path
else
    skip "file-context refusal reporting" "the fcontext helpers are not defined by ${LIB}"
fi

# ── Serializing writes to the policy store ────────────────────────────────────────────────────
# semanage reports an error to whichever process finds the policy store held, rather than waiting, so two root helpers
# that overlap -- an agent package's %post relabel and the ai-tools-relabel.path watcher triggered by the same upgrade
# -- both fail on a store neither of them broke. ai_tools_relabel__lock makes the second wait. Each case runs in its own
# process (the lock is an open file descriptor, so it cannot be exercised in one shell), against a lock file in this
# test's own directory via the root-only AI_TOOLS_RELABEL_LOCK hook.
section "relabel: relabels serialize on the policy store (unit)"
if ! declare -F ai_tools_relabel__lock >/dev/null 2>&1; then
    skip "relabel serialization" "ai_tools_relabel__lock not defined by ${LIB}"
elif ! command -v flock >/dev/null 2>&1; then
    skip "relabel serialization" "flock is not installed"
else
    mktestdir
    LOCK="${TESTDIR}/relabel.lock"

    # take_lock <wait-seconds> <hold-seconds> -- acquire in a child process and print the note.
    take_lock() {
        # shellcheck disable=SC2016  # the child shell expands these, not this one
        env AI_TOOLS_RELABEL_LOCK="${LOCK}" AI_TOOLS_RELABEL_LOCK_WAIT="$1" \
            bash -c 'source "$1"; ai_tools_relabel__lock; printf "%s" "${AI_TOOLS_RELABEL__LOCK_NOTE}"; sleep "$2"' \
            _ "${LIB}" "$2"
    }

    take_lock 5 3 >/dev/null &
    holder=$!
    sleep 0.5   # let the holder acquire before the contender starts waiting

    # A wait shorter than the hold proves the lock is genuinely held across processes.
    contended="$(take_lock 1 0)"
    if [[ "${contended}" == *"held the policy store"* ]]; then
        pass "a concurrent relabel reports the store as held"
    else fail "expected a held-store note while another process held the lock, got '${contended:-<empty>}'"; fi

    # And it proceeds anyway: labelling is idempotent and every refusal is reported, so a lock this helper cannot take
    # costs a repeat run rather than a wrong label.
    if take_lock 1 0 >/dev/null; then pass "a contended relabel proceeds rather than aborting"
    else fail "ai_tools_relabel__lock returned non-zero under contention"; fi

    wait "${holder}" 2>/dev/null || true
    uncontended="$(take_lock 5 0)"
    if [[ -z "${uncontended}" ]]; then pass "the lock is released when the holder exits"
    else fail "the lock was still held after its holder exited: ${uncontended}"; fi

    # A lock file that cannot be created is reported, not fatal: a host where /run/lock is unwritable still relabels.
    # shellcheck disable=SC2016  # the child shell expands these, not this one
    unwritable="$(env AI_TOOLS_RELABEL_LOCK="${TESTDIR}/no-such-dir/relabel.lock" \
        bash -c 'source "$1"; ai_tools_relabel__lock || echo RETURNED-NONZERO; printf "%s" "${AI_TOOLS_RELABEL__LOCK_NOTE}"' \
        _ "${LIB}" 2>&1)"
    if [[ "${unwritable}" == "cannot write ${TESTDIR}/no-such-dir/relabel.lock" ]]; then
        pass "an uncreatable lock file is reported and the relabel proceeds"
    else fail "expected a single cannot-write note, got '${unwritable}'"; fi

    # install-selinux.sh writes the store in sections with prompts between them, so it releases the lock
    # between sections through ai_tools_relabel__unlock rather than at exit. The holder signals its release
    # with a marker file so the contender does not race the unlock itself.
    if declare -F ai_tools_relabel__unlock >/dev/null 2>&1; then
        RELEASED="${TESTDIR}/released"
        # shellcheck disable=SC2016  # the child shell expands these, not this one
        env AI_TOOLS_RELABEL_LOCK="${LOCK}" AI_TOOLS_RELABEL_LOCK_WAIT=5 \
            bash -c 'source "$1"; ai_tools_relabel__lock; ai_tools_relabel__unlock; : >"$2"; sleep 3' \
            _ "${LIB}" "${RELEASED}" &
        holder=$!
        for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -e "${RELEASED}" ]] && break; sleep 0.2; done
        after_unlock="$(take_lock 1 0)"
        if [[ -e "${RELEASED}" && -z "${after_unlock}" ]]; then
            pass "ai_tools_relabel__unlock releases the lock while its holder still runs"
        else fail "the lock was still held after ai_tools_relabel__unlock: '${after_unlock:-<no note>}' (released marker: $([[ -e "${RELEASED}" ]] && echo yes || echo no))"; fi
        wait "${holder}" 2>/dev/null || true

        # A section wrapper that locks around a helper that already holds the lock must not wait on itself: flock
        # serializes open file descriptions, and a second descriptor on the same file would block for the whole wait.
        # The wait here is shorter than the hold, so a self-wait would show as the held-store note.
        # shellcheck disable=SC2016  # the child shell expands these, not this one
        relock="$(env AI_TOOLS_RELABEL_LOCK="${LOCK}" AI_TOOLS_RELABEL_LOCK_WAIT=1 \
            bash -c 'source "$1"; ai_tools_relabel__lock; ai_tools_relabel__lock; printf "%s" "${AI_TOOLS_RELABEL__LOCK_NOTE}"' \
            _ "${LIB}")"
        if [[ -z "${relock}" ]]; then
            pass "a second ai_tools_relabel__lock in the holding process returns without waiting"
        else fail "re-taking the held lock waited on itself: ${relock}"; fi
    else
        skip "lock release between sections" "ai_tools_relabel__unlock not defined by ${LIB}"
    fi

    # The ai-tools-selinux %post cannot source the library, so it open-codes flock on the same path. Two writers
    # serialize only on one file, so the literal in the spec is pinned to the library's default here rather than trusted
    # to stay in step by hand.
    SPEC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/packaging/ai-tools.spec"
    # shellcheck disable=SC2016  # the child shell expands these, not this one
    default_lock="$(env -u AI_TOOLS_RELABEL_LOCK bash -c 'source "$1"; printf "%s" "${AI_TOOLS_RELABEL_LOCK}"' _ "${LIB}")"
    if [[ ! -r "${SPEC}" ]]; then
        skip "the scriptlet's lock path" "packaging/ai-tools.spec is not beside this suite"
    elif [[ "${default_lock}" != /run/lock/* ]]; then
        fail "the library's default lock is not under /run/lock: '${default_lock}'"
    else
        # The section is captured before the grep: under pipefail a `sed | grep -q` reports the SIGPIPE grep hands sed
        # on its first match as a failed pipeline.
        selinux_post="$(sed -n '/^%post -n ai-tools-selinux$/,/^%postun -n ai-tools-selinux$/p' "${SPEC}")"
        if grep -qF -- "=${default_lock}" <<<"${selinux_post}"; then
            pass "the ai-tools-selinux %post locks the library's own path: ${default_lock}"
        else fail "the ai-tools-selinux %post does not lock ${default_lock}, the library's default"; fi
    fi
fi

# ── The per-agent outcome the report closes with ──────────────────────────────────────────────
# ai-tools-relabel-agent records this per agent so ai-tools.status can report the labelling half of a reconciliation;
# the operator cannot inspect the labels themselves, the entrypoint living in a toolchain they cannot traverse. Two
# properties matter beyond the mapping. A path that is not installed YET (rc 3 -- the ordinary pre-bootstrap state) must
# not read as labels applied, or a host that has never provisioned reports green for work that did not happen; and it
# must not fail the relabel either, which would make every fresh install exit non-zero. Both halves are stubbed, so this
# drives the decision without a policy store.
section "relabel: the per-agent outcome closing the report (unit)"
if declare -F ai_tools_relabel__label_agent_paths >/dev/null 2>&1; then
    _ai_tools_relabel__is_entrypoint_policy_active() { return 0; }
    ai_tools_providers__list_enabled_agents() { printf 'some-agent\t\t\n'; }

    # outcome_is <expected-outcome> <expected-run-status> <entrypoint-rc> <config-rc> <why>
    outcome_is() {
        local expected="$1" expected_status="$2" entry_rc="$3" config_rc="$4" why="$5" line got status=0
        eval "_ai_tools_relabel__label_agent_entrypoint() { return ${entry_rc}; }"
        eval "_ai_tools_relabel__label_agent_config_dir()  { return ${config_rc}; }"
        line="$(ai_tools_relabel__label_agent_paths)" || status=$?
        got="$(printf '%s\n' "${line}" | sed -n 's/^agent some-agent //p')"
        if [[ "${got}" == "${expected}" && "${status}" -eq "${expected_status}" ]]; then
            pass "${why} -> ${expected} (run status ${expected_status})"
        else
            fail "${why}: expected ${expected}/${expected_status}, got '${got:-<none>}'/${status}"
        fi
    }

    outcome_is ok     0 0 0 "both halves applied their labels"
    outcome_is failed 1 1 0 "the entrypoint half failed"
    outcome_is failed 1 0 1 "the config-directory half failed"
    outcome_is failed 1 1 1 "both halves failed"
    outcome_is none   0 3 3 "neither path is installed yet (not provisioned)"
    outcome_is ok     0 3 0 "the entrypoint is not installed but the config directory took its type"
    outcome_is ok     0 0 3 "the config directory is absent but the entrypoint took its type"
    outcome_is failed 1 1 3 "a real failure outranks a path that is not installed"

    unset -f _ai_tools_relabel__is_entrypoint_policy_active ai_tools_providers__list_enabled_agents \
             _ai_tools_relabel__label_agent_entrypoint _ai_tools_relabel__label_agent_config_dir
else
    skip "per-agent labelling outcome" "ai_tools_relabel__label_agent_paths not defined by ${LIB}"
fi

# ── The read-only live-label report ──────────────────────────────────────────────────────────
# `ai-tools-admin status` reports the type each agent path carries RIGHT NOW, which is a different claim from the one
# the relabel records: that says what the last run achieved, an event that may be hours old, while this says what is
# true at the moment it is asked. Two properties carry the weight. It must be READ-ONLY -- a status command
# that relabelled the host it is reporting on would change the state it is describing, and would need a policy-store
# lock to do it -- so both writers are stubbed to fail the test loudly if they are ever reached. And its FIELD ORDER is
# a contract: the consumer reads each line with a plain `read`, so a path arriving one field out would be rendered
# as a type and a type as a path, in a report whose whole job is to be believed.
section "relabel: the read-only live-label report (unit)"
if ! declare -F ai_tools_relabel__list_agent_labels >/dev/null 2>&1; then
    skip "live-label report" "ai_tools_relabel__list_agent_labels not defined by ${LIB}"
else
    mktestdir
    # CP_HOME is a readonly constant, so the config directory cannot be moved into the testdir. `.some-agent` is a name
    # no package ships, so `${CP_HOME}/.some-agent` is absent on every host and that half reports deterministically
    # as not installed -- which is a case worth asserting anyway, and leaves the entrypoint half to carry the type
    # comparisons.
    _ai_tools_relabel__is_entrypoint_policy_active() { return 0; }
    ai_tools_providers__list_enabled_agents() { printf 'some-agent\t\t\n'; }
    ai_tools_providers__read_agent_manifest_field() { [[ "$2" == config_dir ]] && printf '.some-agent'; return 0; }
    ai_tools_control_plane__is_agent_config_dir_valid() { return 0; }
    # A write is what this report must never make, and both writers run in a `$(...)` subshell where a failed assertion
    # would not survive -- so each leaves a marker on disk instead, and the whole section is judged on the markers still
    # being absent at the end.
    WROTE="${TESTDIR}/a-writer-ran"
    restorecon() { printf 'restorecon %s\n' "$*" >> "${WROTE}"; }
    semanage()   { printf 'semanage %s\n'   "$*" >> "${WROTE}"; }

    # report_has <expected-line> <why> ; entrypoint path and live types come from the stubs.
    report_has() {
        local expected="$1" why="$2" got
        got="$(ai_tools_relabel__list_agent_labels || true)"
        if grep -qxF -- "${expected}" <<<"${got}"; then
            pass "${why}"
        else
            fail "${why}: no line '${expected}' in '${got//$'\n'/ | }'"
        fi
    }

    ai_tools_relabel__resolve_agent_entrypoint_path() { printf '/opt/toolchain/claude\n'; }
    _ai_tools_relabel__read_live_type() { printf 'ai_tools_exec_t'; }
    report_has 'ok some-agent entrypoint /opt/toolchain/claude ai_tools_exec_t' \
        "a path carrying its pinned type reports ok, in the order agent, what, path, type"
    report_has 'none some-agent config-directory' \
        "a config directory that is not installed reports 'none' with no path to render"

    _ai_tools_relabel__read_live_type() {
        case "$1" in /opt/toolchain/claude) printf 'usr_t' ;; *) printf 'ai_tools_home_t' ;; esac
    }
    rc=0; out="$(ai_tools_relabel__list_agent_labels)" || rc=$?
    if [[ "${rc}" -eq 1 ]] \
            && grep -qx 'bad some-agent entrypoint /opt/toolchain/claude usr_t ai_tools_exec_t' <<<"${out}"; then
        pass "an entrypoint carrying the wrong type reports bad, with the type it has and the one it needs"
    else
        fail "a mislabelled entrypoint was not reported (rc=${rc}): ${out//$'\n'/ | }"
    fi

    # A label the read does not resolve prints as 'unknown', keeping the field count: an empty field would shift every
    # later field left in a line the consumer splits on whitespace. Captured before matching, never piped: the report
    # exits non-zero on a mislabelled path and `pipefail` would fail the whole pipeline whatever grep found.
    _ai_tools_relabel__read_live_type() { return 0; }
    out="$(ai_tools_relabel__list_agent_labels || true)"
    if grep -qx 'bad some-agent entrypoint /opt/toolchain/claude unknown ai_tools_exec_t' <<<"${out}"; then
        pass "an unreadable label reports 'unknown' rather than an empty field"
    else
        fail "an unreadable label did not keep the field count: ${out//$'\n'/ | }"
    fi

    # Not provisioned: ai_tools_relabel__resolve_agent_entrypoint_path returns non-zero because the launcher symlink
    # does not resolve. It is the ordinary pre-bootstrap state and must not read as a fault, or every host reports
    # a problem before it is set
    # up.
    ai_tools_relabel__resolve_agent_entrypoint_path() { return 1; }
    _ai_tools_relabel__read_live_type() { printf 'ai_tools_home_t'; }
    rc=0; out="$(ai_tools_relabel__list_agent_labels)" || rc=$?
    if [[ "${rc}" -eq 0 ]] && grep -qx 'none some-agent entrypoint' <<<"${out}"; then
        pass "an entrypoint that is not installed reports 'none' and is not a fault"
    else
        fail "an uninstalled entrypoint was misreported (rc=${rc}): ${out//$'\n'/ | }"
    fi

    # A function the report calls that is not defined is a reading it could not make: 3 with no report, told apart
    # from the inactive layer's 2, so a caller does not render a partial load as SELinux being off or an entrypoint
    # as not installed. Each is removed inside the capture's subshell, which the next case does not inherit.
    for reader in ai_tools_providers__list_enabled_agents ai_tools_providers__read_agent_manifest_field \
                  ai_tools_relabel__resolve_agent_entrypoint_path; do
        rc=0; out="$(unset -f "${reader}"; ai_tools_relabel__list_agent_labels)" || rc=$?
        if [[ "${rc}" -eq 3 && -z "${out}" ]]; then
            pass "the report without ${reader} returns 3 with no report, not the inactive layer's 2"
        else
            fail "the report without ${reader} returned ${rc}: ${out//$'\n'/ | }"
        fi
    done

    _ai_tools_relabel__is_entrypoint_policy_active() { return 1; }
    rc=0; out="$(ai_tools_relabel__list_agent_labels)" || rc=$?
    if [[ "${rc}" -eq 2 && -z "${out}" ]]; then
        pass "an inactive SELinux layer returns 2 with no report, not a wall of failures"
    else
        fail "an inactive SELinux layer was misreported (rc=${rc}): ${out//$'\n'/ | }"
    fi

    if [[ ! -e "${WROTE}" ]]; then
        pass "the whole report ran read-only -- no restorecon, no semanage, no policy-store lock"
    else
        fail "the report wrote to the host: $(tr '\n' '|' < "${WROTE}")"
    fi

    unset -f _ai_tools_relabel__is_entrypoint_policy_active ai_tools_providers__list_enabled_agents \
             ai_tools_providers__read_agent_manifest_field ai_tools_control_plane__is_agent_config_dir_valid \
             ai_tools_relabel__resolve_agent_entrypoint_path _ai_tools_relabel__read_live_type restorecon semanage
fi

# ── The deployed helper's allowlist gate ─────────────────────────────────────────────────────
# ai-tools-relabel grants a project the type the confined domain may work in, so the gate deciding WHICH paths get it is
# the one thing here worth driving through the real helper. Only the REFUSAL is: the accepting branch registers
# a semanage fcontext rule, and this suite does not mutate the host's policy store to test a helper (the same line
# integration/selinux.sh draws). The accepting branch on a MULTI-OPERATOR host -- the case that matters, since the entry
# authorizing a label may live in any operator's registry -- is covered live in tests/manual/verify-live-flows.sh,
# which has a second enrolled operator to act for.
section "relabel: the deployed helper refuses a path no allowlist covers (unit)"
RELABEL_BIN=/usr/local/libexec/ai-tools/ai-tools-relabel
if [[ ! -x "${RELABEL_BIN}" ]]; then
    skip "relabel allowlist gate" "${RELABEL_BIN} not installed"
elif [[ "${EUID}" -ne 0 ]]; then
    skip "relabel allowlist gate" "needs root (the helper refuses a non-root caller first)"
elif ! command -v getenforce >/dev/null 2>&1 || [[ "$(getenforce 2>/dev/null)" == Disabled ]]; then
    # The helper reports that this host has no label to apply and exits 5 BEFORE the gate, so there is no state
    # to assert here on a DAC-only host.
    skip "relabel allowlist gate" "SELinux inactive -- the helper exits before the gate"
else
    mktestdir
    unlisted="${TESTDIR}/unlisted-project"; mkdir -p "${unlisted}"
    : > "${TESTDIR}/empty-allowlist"
    out="$(AI_TOOLS_ALLOWLIST="${TESTDIR}/empty-allowlist" "${RELABEL_BIN}" "${unlisted}" 2>&1)" && rc=0 || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        pass "a path no allowlist covers is refused, before any policy write"
    else
        fail "the helper did not refuse an unlisted path (rc=${rc}): ${out}"
    fi
    assert_msg MSG-P8J7 "${out}" "the unlisted-path refusal is the one reported"
fi

# ── The helper's `--remove` form ─────────────────────────────────────────────────────────────
# A revert may name a tree a removal has deleted, so `--remove` resolves its path with `realpath -m` and a label keeps
# `realpath -e`; the resolved path must be absolute and free of `.` and `..` components before the protected-paths
# backstop reads it, and the library then drops the rules without a walk. The helper runs as root over the policy store,
# so the arg resolution is read from its text: the checkout's where this file runs from one, the deployed copy
# otherwise.
section "relabel: the helper's --remove form resolves a path that may be gone (unit)"
relabel_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/usr/local/libexec/ai-tools/ai-tools-relabel.sh"
[[ -r "${relabel_helper}" ]] || relabel_helper=/usr/local/libexec/ai-tools/ai-tools-relabel
# shellcheck disable=SC2016  # the single-quoted patterns are the helper's text, matched literally
if [[ ! -r "${relabel_helper}" ]]; then
    skip "the --remove form" "no readable ai-tools-relabel"
else
    resolve_block="$(sed -n '/^if \${remove}; then$/,/^fi$/p' "${relabel_helper}" | head -n 12)"
    if grep -qF 'realpath -m -- "${target}"' <<<"${resolve_block}" \
            && grep -qF 'realpath -e -- "${target}"' <<<"${resolve_block}"; then
        pass "--remove resolves with realpath -m and a label with realpath -e"
    else
        fail "the helper's path resolution does not split -m for --remove and -e for a label: ${resolve_block//$'\n'/ | }"
    fi
    if grep -qF '"${dir}" == /*' <<<"${resolve_block}" && grep -qF '*"/./"*' <<<"${resolve_block}" \
            && grep -qF '*"/../"*' <<<"${resolve_block}"; then
        pass "--remove holds the resolved path to an absolute path without . or .. components"
    else
        fail "the --remove form does not hold its path to an absolute one without . or ..: ${resolve_block//$'\n'/ | }"
    fi
    resolve_line="$(grep -n '^if \${remove}; then$' "${relabel_helper}" | head -n 1 | cut -d: -f1)"
    backstop_line="$(grep -n 'ai_tools_safe_paths__assert_safe_target "\${dir}"' "${relabel_helper}" | head -n 1 | cut -d: -f1)"
    if [[ -n "${resolve_line}" && -n "${backstop_line}" ]] && (( resolve_line < backstop_line )); then
        pass "the protected-paths backstop reads the path after it is resolved"
    else
        fail "the backstop does not follow the resolution (resolve line '${resolve_line}', backstop line '${backstop_line}')"
    fi

    # The library returns 3 where no name stands at the path once the rules are dropped. The helper reads whether a name
    # stood there at its own start, ahead of the lock wait and the library call, and report_revert_status reads 3
    # as success only where none did. The function is driven out of the helper's text with its emitters stubbed.
    presence_line="$(grep -n '^root_present_at_start=false$' "${relabel_helper}" | head -n 1 | cut -d: -f1)"
    lock_line="$(grep -n '^ai_tools_relabel__lock$' "${relabel_helper}" | head -n 1 | cut -d: -f1)"
    if [[ -n "${presence_line}" && -n "${lock_line}" ]] && (( presence_line < lock_line )); then
        pass "--remove reads whether a name stands at the path ahead of the lock wait and the revert"
    else
        fail "the presence read does not precede the lock (presence line '${presence_line}', lock line '${lock_line}')"
    fi
    # A separate presence read after the directory check would record a tree moved away between the two as absent,
    # and its later 3 as success: the check reads the value the presence read recorded.
    directory_check="$(grep -n '^\[\[ -d "\${dir}" \]\] ||' "${relabel_helper}" | head -n 1)"
    if [[ -n "${presence_line}" && "${directory_check%%:*}" =~ ^[0-9]+$ ]] && (( presence_line < ${directory_check%%:*} )) \
            && [[ "${directory_check}" == *'! ${root_present_at_start}'* ]]; then
        pass "--remove reads presence once, ahead of the directory check, which reads that value"
    else
        fail "the directory check does not follow and read the presence read (presence line '${presence_line}', check '${directory_check}')"
    fi
    revert_body="$(extract_function "${relabel_helper}" report_revert_status)"
    # revert_run <status> <present-at-start> [diagnostics] : report_revert_status <status> over /home/op/proj, with
    #   [diagnostics] as the walk's; prints both streams and the exit status last, as `exit=<n>`.
    # shellcheck disable=SC2016  # the inner shell expands these, not this one
    revert_run() {
        bash -c '
            set -euo pipefail
            eval "$1"
            dir=/home/op/proj root_present_at_start="$3" AI_TOOLS_RELABEL__TREE_DIAGNOSTICS="${4:-}"
            ai_tools_log__structured() { :; }
            err()  { printf "%s\n" "$@"; }
            die()  { printf "%s\n" "$@"; exit 1; }
            exit_walker_unavailable() { exit 6; }
            report_revert_status "$2"
        ' _ "${revert_body}" "$1" "$2" "${3:-}" 2>&1 && printf 'exit=0\n' || printf 'exit=%s\n' "$?"
    }
    if [[ -z "${revert_body}" ]]; then
        fail "ai-tools-relabel does not define report_revert_status() in the form this file reads"
    else
        # The label's twin: report_label_status over a failure with and without the library's diagnostic.
        label_body="$(extract_function "${relabel_helper}" report_label_status)"
        # shellcheck disable=SC2016  # the inner shell expands these, not this one
        label_run() {
            bash -c '
                set -euo pipefail
                eval "$1"
                dir=/home/op/proj AI_TOOLS_RELABEL__TREE_DIAGNOSTICS="$3"
                ai_tools_log__structured() { :; }
                die()  { printf "%s\n" "$@"; exit 1; }
                report_label_status "$2"
            ' _ "${label_body}" "$1" "$2" 2>&1 && printf 'exit=0\n' || printf 'exit=%s\n' "$?"
        }
        if [[ -z "${label_body}" ]]; then
            fail "ai-tools-relabel does not define report_label_status() in the form this file reads"
        else
            label_out="$(label_run 1 "failed to restore the file context of /home/op/proj/a: Permission denied")"
            if [[ "${label_out}" == *"MSG-F8F6"*"failed to label /home/op/proj -- failed to restore the file context of /home/op/proj/a: Permission denied"* \
                    && "${label_out}" != *"policy module loaded"* && "${label_out}" == *$'\n'"exit=1" ]]; then
                pass "a label whose walk failed names the path and its error, not the policy remedy"
            else
                fail "a label whose walk failed: ${label_out//$'\n'/ | }"
            fi
            label_out="$(label_run 1 "")"
            if [[ "${label_out}" == *"MSG-M2D2"*"is the ai_tools policy module loaded?"* && "${label_out}" == *$'\n'"exit=1" ]]; then
                pass "control: a label refused at its rule names the policy remedy"
            else
                fail "a label refused at its rule: ${label_out//$'\n'/ | }"
            fi
        fi
        revert_out="$(revert_run 3 false)"
        if [[ "${revert_out}" == *$'\n'"exit=0" && "${revert_out}" != *MSG-* ]]; then
            pass "control: a revert of a path absent at the helper's start that finds no tree exits 0"
        else
            fail "a revert of a path absent at the start: ${revert_out//$'\n'/ | }"
        fi
        revert_out="$(revert_run 3 true)"
        assert_msg MSG-M2A2 "${revert_out}" "a revert whose tree was moved away during it names the move"
        if [[ "${revert_out}" == *$'\n'"exit=1" ]]; then
            pass "a revert whose tree stood at the start and was gone at the walk exits 1"
        else
            fail "a revert whose tree was moved away during it: ${revert_out//$'\n'/ | }"
        fi
        revert_out="$(revert_run 0 true)"
        if [[ "${revert_out}" == *"reverted /home/op/proj"*$'\n'"exit=0" ]]; then
            pass "control: a revert that walked the tree exits 0"
        else
            fail "a revert that walked the tree: ${revert_out//$'\n'/ | }"
        fi
        # A walk that skipped more hardlinked paths than it names: the message carries the walker's bounded list with
        # its count of the rest, and calls the find a listing of the tree as it is now, not of the walk's set.
        revert_skipped="skipped hardlinked path /home/op/proj/1 (link count 2, inode 11)"
        for (( revert_i = 2; revert_i <= 20; revert_i++ )); do
            revert_skipped+="; skipped hardlinked path /home/op/proj/${revert_i} (link count 2, inode 1${revert_i})"
        done
        revert_skipped+="; 6 more hardlinked paths skipped, not listed"
        revert_out="$(revert_run 4 true "${revert_skipped}")"
        assert_msg MSG-D2T9 "${revert_out}" "a revert that left 26 hardlinked paths reports them"
        if [[ "${revert_out}" == *"/home/op/proj/20 "*"6 more hardlinked paths skipped, not listed"* \
                && "${revert_out}" != *"/home/op/proj/21"* \
                && "${revert_out}" == *"list the hardlinked files the tree holds now with: find /home/op/proj "* \
                && "${revert_out}" == *$'\n'"exit=4" ]]; then
            pass "it names the first 20, counts the other 6, offers the find as a listing of the tree now, and exits 4"
        else
            fail "a revert that left 26 hardlinked paths: ${revert_out//$'\n'/ | }"
        fi
    fi
fi

# ── The operator config subtree predicate ────────────────────────────────────────────────────
# ai_tools_relabel__is_operator_conf_valid gates what becomes a `semanage fcontext` rule for ai_tools_conf_t, the type
# the root helpers read an operator's allowlist through. Its input is a home path from a passwd entry, so the property
# under test is the containment ai_tools_providers__is_entrypoint_fcontext_valid holds for a toolchain path: the rule
# may name one account's ~/.config/ai-tools and no other path. A regex metacharacter reaching the pattern would widen it
# to homes nobody enrolled, and refusing costs that one operator's label, which the caller reports -- so every ambiguous
# shape must be refused. Pure: no filesystem, no privilege, no SELinux host.
section "relabel: the operator config subtree predicate (unit)"

if ! declare -F ai_tools_relabel__is_operator_conf_valid >/dev/null 2>&1; then
    skip "operator conf predicate" "${LIB} does not define ai_tools_relabel__is_operator_conf_valid"
else
    conf_accepts() {
        if ai_tools_relabel__is_operator_conf_valid "$1"; then pass "accepts ${1:-<empty>}"
        else fail "rejected a valid operator config dir: $1"; fi
    }
    conf_rejects() {
        if ai_tools_relabel__is_operator_conf_valid "$1"; then fail "ACCEPTED ${2}: ${1:-<empty>}"
        else pass "rejects ${2}"; fi
    }

    conf_accepts '/home/op/.config/ai-tools'
    conf_accepts '/home/some.user/.config/ai-tools'      # a dotted account name is ordinary
    conf_accepts '/var/lib/svc-account/.config/ai-tools' # a service account's home need not be /home

    conf_rejects ''                                  "an empty path"
    conf_rejects 'home/op/.config/ai-tools'          "a relative path"
    conf_rejects '/home/op/.config'                  "the parent, which would cover every ~/.config file"
    conf_rejects '/home/op'                          "a whole home"
    conf_rejects '/home/op/.config/ai-tools/sub'     "a path below the config dir"
    conf_rejects '/home/../etc/.config/ai-tools'     "a parent-directory traversal"
    conf_rejects '/.config/ai-tools'                 "a home of / -- the filesystem root"
    conf_rejects '/home/a|b/.config/ai-tools'        "an alternation in the home"
    conf_rejects '/home/*/.config/ai-tools'          "a wildcard matching every home"
    conf_rejects '/home/[ab]/.config/ai-tools'       "a bracket expression in the home"
    conf_rejects '/home/a b/.config/ai-tools'        "whitespace in the home"
    # shellcheck disable=SC2016  # the literal $(...) is the input under test, not an expansion
    conf_rejects '/home/$(id)/.config/ai-tools'      "a shell-substitution character"

    # The TYPE is the library's, never a caller's -- the same rule the entrypoint type follows.
    if [[ "${AI_TOOLS_RELABEL__OPERATOR_CONF_TYPE:-}" == ai_tools_conf_t ]]; then
        pass "the operator config type is pinned in the library (ai_tools_conf_t)"
    else
        fail "AI_TOOLS_RELABEL__OPERATOR_CONF_TYPE is '${AI_TOOLS_RELABEL__OPERATOR_CONF_TYPE:-unset}', expected ai_tools_conf_t"
    fi

    # A dot in the pattern must be escaped, or the rule matches homes the operator does not own.
    pattern="$(_ai_tools_relabel__get_operator_conf_pattern '/home/some.user/.config/ai-tools')"
    if [[ "${pattern}" == '/home/some\.user/\.config/ai-tools(/.*)?' ]]; then
        pass "the pattern escapes every dot and covers the subtree"
    else
        fail "pattern is '${pattern}', expected every dot escaped and a (/.*)? tail"
    fi
fi


# ── The real wrapper over each walker status ─────────────────────────────────────────────────
# _ai_tools_relabel__relabel_tree runs the walker at a readonly path, so each case sources a copy of the library
# whose walker path is substituted, in a shell of its own, beside the real library's siblings. With /bin/bash
# as the walker the wrapper's `<walker> -- <dir>` runs <dir> as a script, so a fixture script stands for the walker's
# exit status and stderr without an executable fixture; a missing and a non-executable walker path are the two it
# refuses before running anything. Each case prints the wrapper's status, the skipped count and the diagnostics, one
# per line, the last absent where the diagnostics are empty.
section "relabel: the real tree-walk wrapper reads each walker status and the summary line (unit)"
if grep -q '^readonly _AI_TOOLS_RELABEL__TREE_WALKER_PATH=' "${LIB}"; then
    # walker_copy <walker-path> : print the path of a library copy whose walker is <walker-path>.
    walker_copy() {
        local dir lib
        dir="$(mktemp -d "${TESTDIR}/lib-copy.XXXXXX")"
        for lib in "${LIB%/*}"/*.lib.sh; do ln -s "${lib}" "${dir}/${lib##*/}"; done
        rm -f "${dir}/relabel.lib.sh"
        sed "s|^readonly _AI_TOOLS_RELABEL__TREE_WALKER_PATH=.*|readonly _AI_TOOLS_RELABEL__TREE_WALKER_PATH=$1|" "${LIB}" \
            > "${dir}/relabel.lib.sh"
        printf '%s\n' "${dir}/relabel.lib.sh"
    }
    # wrapper_run <copy> <script> : the wrapper's three outputs over <script> as the walked directory.
    # shellcheck disable=SC2016  # the inner shell expands these
    wrapper_run() {
        bash -c 'source "$1" 2>/dev/null; status=0; _ai_tools_relabel__relabel_tree "$2" || status=$?
                 printf "%s\n%s\n%s\n" "${status}" "$(ai_tools_relabel__get_skipped_hardlink_count)" \
                     "${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS}"' _ "$1" "$2"
    }
    # wrapper_is <why> <script-body> <status> <count> <diagnostics-glob>
    bash_copy="$(walker_copy /bin/bash)"
    wrapper_is() {
        local script out
        script="$(mktemp "${TESTDIR}/walker.XXXXXX")"
        printf '%s\n' "$2" > "${script}"
        out="$(wrapper_run "${bash_copy}" "${script}")"
        local status count diagnostics
        { IFS= read -r status; IFS= read -r count; IFS= read -r diagnostics || true; } <<< "${out}"
        # shellcheck disable=SC2053  # $5 is a glob the case states
        if [[ "${status}" == "$3" && "${count}" == "$4" && "${diagnostics}" == $5 ]]; then
            pass "$1: status $3, count $4"
        else
            fail "$1: status ${status}, count ${count}, diagnostics '${diagnostics}'"
        fi
    }
    wrapper_is "control: a walk that labelled every entry" 'exit 0' 0 0 ''
    wrapper_is "a walk that left 25 hardlinked paths, 20 listed" \
        'for i in $(seq 20); do echo "skipped hardlinked path /p/$i (link count 2)" >&2; done
         echo "5 more hardlinked paths skipped, not listed" >&2
         echo "summary hardlinks-left=25 failures=0" >&2; exit 4' \
        4 25 'skipped hardlinked path /p/1 (link count 2); *; 5 more hardlinked paths skipped, not listed'
    wrapper_is "a name carrying the summary text, escaped onto one line, is not counted as it" \
        "echo \"skipped hardlinked path \$'/p/a\\\\x0asummary hardlinks-left=99 failures=0' (link count 2)\" >&2
         echo 'summary hardlinks-left=1 failures=0' >&2; exit 4" \
        4 1 "skipped hardlinked path \$'/p/a\\\\x0asummary hardlinks-left=99 failures=0' (link count 2)"
    wrapper_is "libselinux not loading is a walker that could not run" \
        'echo "ai-tools-relabel-tree: libselinux.so.1 does not load: x" >&2; exit 3' 6 0 '*libselinux.so.1 does not load*'
    wrapper_is "a silent exit 3 names libselinux" 'exit 3' 6 0 'libselinux.so.1 did not load'
    wrapper_is "an entry the walk could not label" \
        'echo "failed to restore the file context of /p/a: Permission denied" >&2; echo "1 entries not labelled" >&2
         echo "summary hardlinks-left=0 failures=1" >&2; exit 1' \
        1 0 'failed to restore the file context of /p/a: Permission denied; 1 entries not labelled'
    wrapper_is "a walker exiting 1 with no diagnostic is named by its status" 'exit 1' 1 0 \
        'the walker exited 1 without a diagnostic'
    wrapper_is "a walker killed by a signal is named by its status" 'kill -KILL $$' 1 0 \
        'the walker exited 137 without a diagnostic'
    wrapper_is "a usage refusal is a failed walk" 'exit 2' 1 0 'the walker exited 2 without a diagnostic'
    for absent_case in missing nonexec; do
        if [[ "${absent_case}" == missing ]]; then
            walker_path="${TESTDIR}/no-such-walker"
        else
            walker_path="${TESTDIR}/nonexec-walker"; : > "${walker_path}"; chmod 0644 "${walker_path}"
        fi
        out="$(wrapper_run "$(walker_copy "${walker_path}")" "${TESTDIR}")"
        { IFS= read -r status; IFS= read -r _count; IFS= read -r diagnostics || true; } <<< "${out}"
        if [[ "${status}" == 6 && "${diagnostics}" == "${walker_path} is not installed or not executable" ]]; then
            pass "a ${absent_case} walker returns 6 and names its path"
        else
            fail "a ${absent_case} walker: status ${status}, '${diagnostics}'"
        fi
    done
else
    skip "the real wrapper" "${LIB} does not hold the walker path in the form this file substitutes"
fi

finish
