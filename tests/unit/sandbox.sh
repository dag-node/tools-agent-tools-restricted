#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/sandbox.sh
# Unit test for the two pure decisions behind the --sandbox-create flow (ai-tools.sh):
#   * sandbox_default_branch -- composes the DEFAULT sandbox branch (sandbox/<leaf-of-from>) with no
#     host or operator identity in it; the operator overrides the whole name with --branch, so this
#     only pins the default shape and the leaf extraction.
#   * sandbox_resolve_base -- resolves the base branch to fork from (a local branch, a
#     <remote>/<base>, or any commit-ish), so the sandbox branch can be based on something OTHER than
#     the current HEAD (e.g. main for a hotfix) and a base that cannot be forked is refused BEFORE
#     any push/clone.
# These are the flow's inputs-with-consequences; the interactive shell around them (tty prompts,
# the remote push, the sandbox-area clone) is not driven here -- it needs a terminal, credentials,
# and the real sandbox tree.
#
# The CLI carries a sourced-guard, so this loads it to expose its functions without running the
# gates or dispatch. It must be sourced AS THE PROJECTS USER: ai-tools refuses to run (even to be
# sourced) as root or the sandbox account. Fixtures live in the /tmp testdir, owned by that user so
# its git can read them. Run as root via sudo (suite contract).

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

# call <helper> <args...> : source the CLI as the projects user (sourced-guard skips gates/dispatch)
# and run one helper, echoing its stdout; returns the helper's exit status. $0 is set to "_" so the
# guard sees BASH_SOURCE[0] (the CLI path) != $0 and returns from the source.
call() {
    local helper="$1"; shift
    # shellcheck disable=SC2016  # the $N are for the inner `bash -c`, not this shell -- do not expand here
    runuser -u "${PROJECTS_USER}" -- bash -c '
        helper="$1"; cli="$2"; shift 2
        source "${cli}" >/dev/null 2>&1 || exit 99
        "${helper}" "$@"
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
# The default is sandbox/<leaf>, leaf = the from-ref's last component, with NO host/operator
# identity -- so it is stable and leaks nothing regardless of who or where runs it.
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

finish
