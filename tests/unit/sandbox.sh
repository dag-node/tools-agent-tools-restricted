#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/sandbox.sh
# Unit test for the pure decisions behind the ai-tools.sh flows -- the ai-tools.projects.clone pair, the precondition
# ai-tools.projects.create's skipped prompts rest on (tree_is_pristine), the exclusion reader the claim-time scans prune
# their walks with (allowlist_exclusions), and the re-claim's SELinux drift reader (label_drift_scan, at the end).
#
# The ai-tools.projects.clone pair:
#   * sandbox_default_branch -- composes the DEFAULT sandbox branch (sandbox/<leaf-of-from>) with no
#     host or operator identity in it; the operator overrides the whole name with `--branch`, so this
#     only pins the default shape and the leaf extraction.
#   * sandbox_resolve_base -- resolves the base branch to fork from (a local branch, a
#     <remote>/<base>, or any commit-ish), so the sandbox branch can be based on something OTHER than
#     the current HEAD (e.g. main for a hotfix) and a base that cannot be forked is refused BEFORE
#     any push/clone.
# These are the flow's inputs-with-consequences; the interactive shell around them (tty prompts,
# the remote push, the sandbox-area clone) is not driven here -- it needs a terminal, credentials,
# and the real sandbox tree.
#
# The CLI carries a sourced-guard, so this loads it to expose its functions without running the gates or dispatch. It
# must be sourced AS THE PROJECTS USER: ai-tools refuses to run (even to be sourced) as root or the sandbox account.
# Fixtures live in the /tmp testdir, owned by that user so its git can read them. Run as root via sudo (suite contract).

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly CLI="/usr/local/bin/ai-tools"
section "sandbox: create-flow helpers (unit)"

if [[ ! -x "${CLI}" ]]; then
    skip "sandbox create-flow helpers" "CLI not installed at ${CLI}"; finish; exit
fi
if ! command -v git >/dev/null 2>&1; then
    skip "sandbox create-flow helpers" "git not available"; finish; exit
fi

# call <helper> <args...> : source the CLI as the projects user (sourced-guard skips gates/dispatch) and run one helper,
# echoing its stdout; returns the helper's exit status. $0 is set to "_" so the guard sees BASH_SOURCE[0] (the CLI path)
# != $0 and returns from the source.
call() {
    local helper="$1"; shift
    # shellcheck disable=SC2016  # the $N are for the inner `bash -c`, not this shell -- do not expand here
    runuser -u "${PROJECTS_USER}" -- bash -c '
        helper="$1"; cli="$2"; shift 2
        # The CLI reads its command from the positional parameters and shifts them as it goes, so the helper'"'"'s
        # arguments are held aside and the source sees none.
        args=("$@"); set --
        source "${cli}" >/dev/null 2>&1 || exit 99
        "${helper}" "${args[@]}"
    ' _ "${helper}" "${CLI}" "$@"
}

# Sourceable-and-defines probe: an install missing a required lib exits 3 on source -- skip cleanly.
# shellcheck disable=SC2016  # the $1 is for the inner `bash -c`, not this shell -- do not expand here
if ! runuser -u "${PROJECTS_USER}" -- bash -c \
        'source "$1" >/dev/null 2>&1; declare -F sandbox_default_branch >/dev/null 2>&1 \
            && declare -F sandbox_resolve_base >/dev/null 2>&1' _ "${CLI}"; then
    skip "sandbox create-flow helpers" "CLI not sourceable or helpers absent (partial install?)"
    finish; exit
fi

# ── sandbox_default_branch ────────────────────────────────────────────────────────────────────
# The default is sandbox/<leaf>, leaf = the from-ref's last component, with NO host/operator identity -- so it is stable
# whoever runs it and wherever, and does not leak either into the branch name.
def_is() {  # def_is <from> <expected>
    local got; got="$(call sandbox_default_branch "$1")" \
        && [[ "${got}" == "$2" ]] \
        && pass "default_branch '${1}' -> '${2}'" \
        || fail "default_branch '${1}' -> '${got:-<empty/err>}', expected '${2}'"
}
def_is "develop"                     "sandbox/develop"    # plain branch
def_is "main"                        "sandbox/main"
def_is "origin/master"               "sandbox/master"     # remote-qualified -> leaf only
def_is "feature/x"                   "sandbox/x"          # hierarchical -> last component
def_is "refs/remotes/origin/release" "sandbox/release"    # fully-qualified ref -> leaf only

# ── sandbox_resolve_base ──────────────────────────────────────────────────────────────────────
mktestdir
repo="${TESTDIR}/src"; bare="${TESTDIR}/remote.git"
git init -q -b main "${repo}"
git -C "${repo}" config user.email t@example.invalid
git -C "${repo}" config user.name  "sandbox test"
: > "${repo}/f"; git -C "${repo}" add f; git -C "${repo}" commit -qm init
git init -q --bare "${bare}"
git -C "${repo}" remote add origin "${bare}"
git -C "${repo}" push -q origin main
git -C "${repo}" branch develop                 # local-only branch
git -C "${repo}" branch release                 # will become remote-only
git -C "${repo}" push -q origin release
git -C "${repo}" branch -D release
git -C "${repo}" fetch -q origin                # populate refs/remotes/origin/*
# Own the fixture as the projects user so its git (run under runuser) is not "dubious ownership".
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${repo}" "${bare}"

base_is() {  # base_is <base> <expected-ref>
    local got; got="$(call sandbox_resolve_base "${repo}" origin "$1")" \
        && [[ "${got}" == "$2" ]] \
        && pass "resolve_base '${1}' -> '${2}'" \
        || fail "resolve_base '${1}' -> '${got:-<empty/err>}', expected '${2}'"
}

base_is develop develop                                 # local branch resolves to itself
base_is main    main                                    # local (and remote) -> local wins
base_is release "refs/remotes/origin/release"           # remote-only -> remote-tracking ref
if call sandbox_resolve_base "${repo}" origin nope >/dev/null 2>&1; then
    fail "resolve_base accepted a nonexistent base"
else
    pass "resolve_base refuses a base that is not a branch, remote branch, or ref"
fi

# ── tree_is_pristine ──────────────────────────────────────────────────────────────────────────
# The predicate ai-tools.projects.create's flow rests on, and the reason it is pinned here rather than left to the CLI
# test: what it gates is the SECRET SCAN. A claim skips that scan, the git-history prompt, and the proceed confirm
# when this returns 0, so every way it could wrongly say yes is a way to grant an agent access to a tree no scan has
# covered. It must answer for the tree as it is on disk -- never for what a caller asserts about it -- so the cases are
# the states that must read as NOT pristine.
section "tree_is_pristine: the precondition behind ai-tools.projects.create's skipped prompts (unit)"

pristine() { call tree_is_pristine "$1"; }

# Fixtures are built AS ROOT and handed over at the end, the same way the repo fixture is. The predicate only reads
# the tree, so what matters is that the projects user can read it when `call` runs; driving each mkdir/git
# through runuser instead would make every fixture line a command that can fail under `set -e` for reasons unrelated
# to what is being tested.
work="${TESTDIR}/pristine"
fresh="${work}/fresh"
bare="${work}/bare"
mkdir -p "${fresh}" "${bare}"
git init -q "${fresh}"
printf '# fresh\n' > "${fresh}/README.md"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${work}"

if pristine "${fresh}"; then
    pass "a freshly created project (empty repo + README) reads as pristine"
else
    fail "a freshly created project was not recognised as pristine"
fi

# A secret-named file is the exact thing the skipped scan exists to catch, so its presence has to put the scan back.
printf 'TOKEN=x\n' > "${fresh}/.env"
chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${fresh}/.env"
if pristine "${fresh}"; then
    fail "a tree containing .env still read as pristine -- the secret scan would be skipped"
else
    pass "any file beyond the README makes a tree non-pristine (the secret scan runs)"
fi
rm -f "${fresh}/.env"

# A file nested deeper counts too: a check that only looked at the top level would miss it.
mkdir -p "${fresh}/sub"
printf 'x\n' > "${fresh}/sub/deep.txt"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${fresh}/sub"
if pristine "${fresh}"; then
    fail "a nested file still read as pristine -- the check is not walking the tree"
else
    pass "a file nested below the root makes a tree non-pristine"
fi
rm -rf "${fresh}/sub"

# Commits are the other half: the git-history prompt is inferred to yes only because a repository with no commits has no
# history to expose.
git -C "${fresh}" -c user.email=t@example.invalid -c user.name=t add -A
git -C "${fresh}" -c user.email=t@example.invalid -c user.name=t commit -qm first
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${fresh}"
if pristine "${fresh}"; then
    fail "a repository with a commit read as pristine -- history would be shared unasked"
else
    pass "a repository carrying any commit is not pristine (the history prompt returns)"
fi

# An empty directory with no repository at all is still pristine: the predicate is about contents,
# and ai-tools.projects.create's git init failing is a warning, not a reason to rescan an empty tree.
if pristine "${bare}"; then
    pass "an empty directory with no repository is pristine"
else
    fail "an empty directory was not recognised as pristine"
fi

# ── allowlist_exclusions ──────────────────────────────────────────────────────────────────────
# The read-only scans a claim runs (acl_drift_scan, sealed_setgid_scan) prune every '!' exclusion from their walk,
# and read the registry through the shared allowlist grammar: an exclusion line carrying an end-of-line comment
# or quotes names the same path here as in the launch wrapper, so a carve-out is neither reported as drift nor offered
# to the repair walk. Only the exclusions are printed, without their '!', and a commented-out line is not one.
section "allowlist_exclusions: the carve-outs the claim-time scans prune (unit)"

excl_work="${TESTDIR}/exclusions"
excl_list="${excl_work}/allowed-projects"
mkdir -p "${excl_work}"
printf '%s\n' "/p" "!/p/plain" "!/p/vendor   # carve-out" '!"/p/with space"' "# !/p/commented-out" \
    > "${excl_list}"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${excl_work}"
# The CLI reads AI_TOOLS_ALLOWLIST when sourced; runuser resets the environment, so it is set inside.
# shellcheck disable=SC2016  # the $1 is for the inner `bash -c`, not this shell -- do not expand here
excl_got="$(runuser -u "${PROJECTS_USER}" -- env AI_TOOLS_ALLOWLIST="${excl_list}" bash -c \
    'source "$1" >/dev/null 2>&1 || exit 99; allowlist_exclusions' _ "${CLI}" | sort | tr '\n' '|')"
excl_want="$(printf '%s\n' "/p/plain" "/p/vendor" "/p/with space" | sort | tr '\n' '|')"
if [[ "${excl_got}" == "${excl_want}" ]]; then
    pass "allowlist_exclusions prints each '!' entry read through the shared grammar (comment, quotes)"
else
    fail "allowlist_exclusions printed '${excl_got}' (want '${excl_want}')"
fi

# ── label_drift_scan ──────────────────────────────────────────────────────────────────────────
# The re-claim's SELinux half reads a dry run of the relabel the claim performs, so restorecon is stubbed with a canned
# transcript and the scan is judged on which lines it keeps. The stub records its arguments each followed by a space,
# not as "$*", which joins them with the CLI's IFS (a newline); the dry-run flag is asserted among them: the scan runs
# unprivileged and reports, and a stub that saw no `-n` would mean a claim that relabels while it is still asking. Kept:
# a type difference, and a path holding " from " and " to " with an MLS range in its context. Dropped: a difference
# in the SELinux user alone, an owner-only file, a path under a '!' carve-out, and a line other than a relabel line.
section "label_drift_scan: the paths a re-claim asks to relabel (unit)"

ld_work="${TESTDIR}/label-drift"
ld_tree="${ld_work}/p"
mkdir -p "${ld_tree}/excl"
for ld_name in moved useronly "name from a to b" excl/x; do
    : > "${ld_tree}/${ld_name}"; chmod 0640 "${ld_tree}/${ld_name}"
done
: > "${ld_tree}/private"; chmod 0600 "${ld_tree}/private"
printf '%s\n' "${ld_tree}" "!${ld_tree}/excl" > "${ld_work}/allowed-projects"
{
    printf 'Would relabel %s from %s to %s\n' \
        "${ld_tree}/moved" unconfined_u:object_r:user_home_t:s0 system_u:object_r:ai_tools_project_t:s0 \
        "${ld_tree}/useronly" unconfined_u:object_r:ai_tools_project_t:s0 system_u:object_r:ai_tools_project_t:s0 \
        "${ld_tree}/private" unconfined_u:object_r:user_home_t:s0 system_u:object_r:ai_tools_project_t:s0 \
        "${ld_tree}/excl/x" unconfined_u:object_r:user_home_t:s0 system_u:object_r:ai_tools_project_t:s0 \
        "${ld_tree}/name from a to b" system_u:object_r:container_file_t:s0:c1,c2 system_u:object_r:ai_tools_project_t:s0
    printf 'restorecon: a warning line that is not a relabel line\n'
} > "${ld_work}/transcript"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${ld_work}"

ld_rc=0
# shellcheck disable=SC2016  # the $1..$3 are for the inner `bash -c`, not this shell -- do not expand here
ld_got="$(runuser -u "${PROJECTS_USER}" -- env AI_TOOLS_ALLOWLIST="${ld_work}/allowed-projects" bash -c \
    'cli="$1"; transcript="$2"; tree="$3"; set --
     source "${cli}" >/dev/null 2>&1 || exit 99
     declare -F label_drift_scan >/dev/null || exit 98
     restorecon() { printf "%s " "$@" > "${transcript}.args"; cat "${transcript}"; }
     label_drift_scan "${tree}"' _ "${CLI}" "${ld_work}/transcript" "${ld_tree}")" || ld_rc=$?
ld_want="$(printf '%s\t%s\t%s\n' "${ld_tree}/moved" user_home_t ai_tools_project_t \
    "${ld_tree}/name from a to b" container_file_t ai_tools_project_t)"
if [[ "${ld_rc}" -eq 98 ]]; then
    skip "label_drift_scan" "the installed CLI predates it"
elif [[ "${ld_rc}" -ne 0 ]]; then
    fail "label_drift_scan could not be driven (exit ${ld_rc})"
else
    if [[ " $(cat "${ld_work}/transcript.args" 2>/dev/null) " == *" -n "* ]]; then
        pass "label_drift_scan asks restorecon for a dry run"
    else
        fail "label_drift_scan called restorecon without -n: '$(cat "${ld_work}/transcript.args" 2>/dev/null)'"
    fi
    if [[ "${ld_got}" == "${ld_want}" ]]; then
        pass "label_drift_scan keeps type differences and drops user-only, owner-only and carved-out paths"
    else
        fail "label_drift_scan printed '$(tr '\t\n' '>|' <<<"${ld_got}")' (want '$(tr '\t\n' '>|' <<<"${ld_want}")')"
    fi
fi

finish
