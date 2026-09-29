#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/sandbox.sh
# Unit test for the pure decisions behind the ai-tools.sh flows -- the ai-tools.projects.clone pair, the precondition
# ai-tools.projects.create's skipped prompts rest on (tree_is_pristine), the exclusion reader the claim-time scans prune
# their walks with (allowlist_exclusions), the re-claim's SELinux drift scan (label_drift_scan), and the checks
# the claim runs after its Apply block (claim_verify_label, claim_verify_group, at the end).
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

# call_script <script> <args...> : like call, running <script> in the sourced CLI's shell with the arguments held
# in `args`, for a helper that publishes its result as arrays rather than on stdout, or one whose dependency the case
# shadows with a shell function ahead of the call.
call_script() {
    local script="$1"; shift
    # shellcheck disable=SC2016  # the $N are for the inner `bash -c`, not this shell -- do not expand here
    runuser -u "${PROJECTS_USER}" -- bash -c '
        script="$1"; cli="$2"; shift 2
        args=("$@"); set --
        source "${cli}" >/dev/null 2>&1 || exit 99
        eval "${script}"
    ' _ "${script}" "${CLI}" "$@"
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
# The re-claim's SELinux half walks the tree and reads one non-recursive dry run of the relabel the claim performs
# over the walked paths, so restorecon is stubbed with a canned transcript and the scan is judged on what it keeps.
# The stub records its arguments each followed by a space, not as "$*", which joins them with the CLI's IFS (a newline):
# the scan runs unprivileged and reports, so a stub that saw no `-n` would mean a claim that relabels while it is still
# asking, and one that saw `-R` would mean a batch whose records no longer belong to the listed paths alone. Kept:
# a type difference, and a path holding " from " and " to " with an MLS range in its context. Dropped: a difference
# in the SELinux user alone, an owner-only file, and a path under a '!' carve-out. A line other than a relabel record
# makes the scan incomplete (return 1, with a detail), and the drift it did read is still reported.
section "label_drift_scan: the paths a re-claim asks to relabel (unit)"

ld_work="${TESTDIR}/label-drift"
ld_tree="${ld_work}/p"
mkdir -p "${ld_tree}/excl" "${ld_work}/scan"
for ld_name in moved useronly "name from a to b" excl/x; do
    : > "${ld_tree}/${ld_name}"; chmod 0640 "${ld_tree}/${ld_name}"
done
: > "${ld_tree}/private"; chmod 0600 "${ld_tree}/private"
printf '%s\n' "${ld_tree}" "!${ld_tree}/excl" > "${ld_work}/allowed-projects"
printf 'Would relabel %s from %s to %s\n' \
    "${ld_tree}/moved" unconfined_u:object_r:user_home_t:s0 system_u:object_r:ai_tools_project_t:s0 \
    "${ld_tree}/useronly" unconfined_u:object_r:ai_tools_project_t:s0 system_u:object_r:ai_tools_project_t:s0 \
    "${ld_tree}/private" unconfined_u:object_r:user_home_t:s0 system_u:object_r:ai_tools_project_t:s0 \
    "${ld_tree}/excl/x" unconfined_u:object_r:user_home_t:s0 system_u:object_r:ai_tools_project_t:s0 \
    "${ld_tree}/name from a to b" system_u:object_r:container_file_t:s0:c1,c2 system_u:object_r:ai_tools_project_t:s0 \
    > "${ld_work}/transcript"
{ cat "${ld_work}/transcript"; printf 'restorecon: a line that is not a relabel record\n'; } > "${ld_work}/transcript-bad"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${ld_work}"

# ld_run <transcript>: source the CLI as the projects user, load the claim's libraries, stub restorecon, run the scan,
# and print each kept path with its types, then the scan's status and detail.
ld_run() {
    # shellcheck disable=SC2016  # the $1..$4 are for the inner `bash -c`, not this shell -- do not expand here
    runuser -u "${PROJECTS_USER}" -- env AI_TOOLS_ALLOWLIST="${ld_work}/allowed-projects" bash -c \
        'cli="$1"; transcript="$2"; tree="$3"; work="$4"; set --
         source "${cli}" >/dev/null 2>&1 || exit 99
         declare -F claim_load_libraries >/dev/null || exit 98
         claim_load_libraries >/dev/null 2>&1 || exit 97
         restorecon() { printf "%s " "$@" > "${transcript}.args"; cat "${transcript}"; }
         declare -a paths=(); declare -A types=(); detail=""; rc=0
         label_drift_scan "${tree}" "${work}" paths types detail || rc=$?
         for p in "${paths[@]}"; do printf "%s\t%s\n" "${p}" "${types[${p}]}"; done
         printf "rc=%s detail=%s\n" "${rc}" "${detail}"' _ "${CLI}" "$1" "${ld_tree}" "${ld_work}/scan"
}

ld_rc=0
ld_got="$(ld_run "${ld_work}/transcript")" || ld_rc=$?
ld_want="$(printf '%s\t%s\n' "${ld_tree}/moved" "user_home_t -> ai_tools_project_t" \
    "${ld_tree}/name from a to b" "container_file_t -> ai_tools_project_t"; printf 'rc=0 detail=\n')"
if [[ "${ld_rc}" -eq 98 || "${ld_rc}" -eq 97 ]]; then
    skip "label_drift_scan" "the installed CLI predates the per-path checks"
elif [[ "${ld_rc}" -ne 0 ]]; then
    fail "label_drift_scan could not be driven (exit ${ld_rc})"
else
    ld_args=" $(cat "${ld_work}/transcript.args" 2>/dev/null) "
    if [[ "${ld_args}" == *" -n "* && "${ld_args}" == *" -F "* && "${ld_args}" == *" -0 "* \
            && "${ld_args}" != *" -R "* ]]; then
        pass "label_drift_scan asks for a forced, non-recursive dry run over a NUL list"
    else
        fail "label_drift_scan called restorecon with '${ld_args}'"
    fi
    if [[ "${ld_got}" == "${ld_want}" ]]; then
        pass "label_drift_scan keeps type differences and drops user-only, owner-only and carved-out paths"
    else
        fail "label_drift_scan printed '$(tr '\t\n' '>|' <<<"${ld_got}")' (want '$(tr '\t\n' '>|' <<<"${ld_want}")')"
    fi
    ld_got="$(ld_run "${ld_work}/transcript-bad")" || true
    if [[ "${ld_got}" == *"${ld_tree}/moved"* && "${ld_got}" == *"rc=1 detail="?* ]]; then
        pass "a line that is not a relabel record makes the scan incomplete, and its drift is still reported"
    else
        fail "label_drift_scan over a transcript with a stray line printed '$(tr '\t\n' '>|' <<<"${ld_got}")'"
    fi
fi

# ── drift_walk_read ───────────────────────────────────────────────────────────────────────────
# The reader both scans take their walk through orders the capture in the C locale, so the rows a claim writes do not
# follow the filesystem's entry order; the capture here is written out of order on purpose, since a `find`
# over the fixture would be in whatever order this host's filesystem returns.
section "drift_walk_read: a walk's capture is read in byte order (unit)"

dw_work="${TESTDIR}/walk-read"
mkdir -p "${dw_work}"
printf '%s\0' "/p/n b" "/p/m" $'/p/a\nb' "/p/M" > "${dw_work}/capture"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${dw_work}"
# shellcheck disable=SC2016  # the $N are for the inner `bash -c`, not this shell
dw_got="$(runuser -u "${PROJECTS_USER}" -- bash -c \
    'cli="$1"; capture="$2"; set --
     source "${cli}" >/dev/null 2>&1 || exit 99
     declare -F drift_walk_read >/dev/null || exit 98
     declare -a paths=()
     drift_walk_read "${capture}" paths || exit 97
     printf "%s|" "${paths[@]}"' _ "${CLI}" "${dw_work}/capture" 2>/dev/null)" || dw_rc=$?
dw_want="$(printf '%s|' "/p/M" $'/p/a\nb' "/p/m" "/p/n b")"
if (( ${dw_rc:-0} == 99 || ${dw_rc:-0} == 98 )); then
    skip "drift_walk_read" "the installed CLI predates the shared walk reader"
elif (( ${dw_rc:-0} != 0 )); then
    fail "drift_walk_read could not be driven (exit ${dw_rc})"
elif [[ "${dw_got}" == "${dw_want}" ]]; then
    pass "drift_walk_read orders an unsorted capture by byte, a line feed in a name kept"
else
    fail "drift_walk_read printed '$(tr '\n' '>' <<<"${dw_got}")', want '$(tr '\n' '>' <<<"${dw_want}")'"
fi

# ── claim_verify_label / claim_verify_group ───────────────────────────────────────────────────
# The checks after the Apply block, driven through the sourced CLI with restorecon a stub: a path removed
# before the check reads gone, a batch that fails reads the paths still present unverified and the ones now absent gone
# -- never fixed -- and a clean batch reads fixed. The group side reads a moved-in file not fixed and a removed one
# gone.
section "claim_verify_label / claim_verify_group: the checks after the Apply block (unit)"

cv_work="${TESTDIR}/verify"
mkdir -p "${cv_work}/scratch"
: > "${cv_work}/present"; chmod 0640 "${cv_work}/present"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${cv_work}"

# cv_run <restorecon-status>: print the label outcomes, then the group outcomes, for the present path and a path
# that does not exist. The CLI resolves OWNER_USER from `id -un` at its top level and makes it readonly, so the inner
# shell runs as the fixture's owner and asserts the resolved owner rather than assigning it.
cv_run() {
    # shellcheck disable=SC2016  # the $N are for the inner `bash -c`, not this shell -- do not expand here
    runuser -u "${PROJECTS_USER}" -- bash -c \
        'cli="$1"; work="$2"; status="$3"; user="$4"; set --
         source "${cli}" >/dev/null 2>&1 || exit 99
         declare -F claim_verify_label >/dev/null || exit 98
         claim_load_libraries >/dev/null 2>&1 || exit 97
         [[ "${OWNER_USER}" == "${user}" ]] \
             || { echo "OWNER_USER resolved to ${OWNER_USER}, not ${user}" >&2; exit 96; }
         CLAIM_WORK="${work}/scratch"
         restorecon() { return "${status}"; }
         declare -a paths=("${work}/present" "${work}/absent") label=() group=() details=()
         claim_verify_label paths label
         claim_verify_group paths group details
         printf "%s " "${label[@]}"; printf "| "; printf "%s " "${group[@]}"' \
        _ "${CLI}" "${cv_work}" "$1" "${PROJECTS_USER}" 2> "${cv_work}/stderr"
}

cv_is() {  # cv_is <what> <restorecon-status> <want>
    local got rc=0
    got="$(cv_run "$2")" || rc=$?
    if (( rc == 98 || rc == 97 )); then
        skip "claim_verify: $1" "the installed CLI predates the per-path checks"
    elif (( rc != 0 )); then
        # The inner shell's stderr names what stopped it; its last lines ride the result line.
        fail "claim_verify: $1 could not be driven (exit ${rc}): $(tail -n 3 "${cv_work}/stderr" 2>/dev/null | tr '\n' '|')"
    elif [[ "${got}" == "$3" ]]; then
        pass "claim_verify: $1 -> ${got}"
    else
        fail "claim_verify: $1 -> '${got}', want '$3'"
    fi
}
cv_is "a clean batch" 0 "fixed gone | not-fixed gone "
cv_is "a batch that exits 1" 1 "unverified gone | not-fixed gone "

# ── agent_can_traverse ───────────────────────────────────────────────────────────────────────
# The read behind the traverse grant: whether the sandbox account can enter a directory, decided as the kernel decides
# it. Each row is one entry the algorithm consults, and the two that carry weight are the ones a mode read gets wrong:
# a named-user entry the mask narrows to no permission (a `chmod 700` after an earlier grant), which must read
# as blocked so the grant is offered again, and a named-user entry denying execute beside world execute, which must
# read as blocked because a named entry is consulted ahead of the other entry.
section "agent_can_traverse: the kernel's access order, mask included (unit)"
if ! command -v setfacl >/dev/null 2>&1 || ! command -v getfacl >/dev/null 2>&1 \
        || ! getent passwd "${SANDBOX_USER}" >/dev/null 2>&1 || ! getent group "${SANDBOX_GROUP}" >/dev/null 2>&1; then
    skip "agent_can_traverse" "setfacl/getfacl or the ${SANDBOX_USER} account is unavailable"
else
    ct_work="${TESTDIR}/ct"; mkdir -p "${ct_work}"
    chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${ct_work}"; chmod 0755 "${ct_work}"
    # ct_dir <name> <mode> [setfacl-spec...]: a directory of the projects user at <mode>, with the ACL specs applied
    # in order; a spec `chmod:<mode>` re-modes the directory after the entries before it, which is how a mask narrows.
    ct_dir() {
        local name="$1" mode="$2" spec; shift 2
        mkdir -p "${ct_work}/${name}"; chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${ct_work}/${name}"
        chmod "${mode}" "${ct_work}/${name}"
        for spec in "$@"; do
            if [[ "${spec}" == chmod:* ]]; then chmod "${spec#chmod:}" "${ct_work}/${name}"
            else setfacl -m "${spec}" "${ct_work}/${name}"; fi
        done
    }
    ct_is() {  # ct_is <name> <yes|no> <what>
        local rc=0; call agent_can_traverse "${ct_work}/$1" >/dev/null 2>&1 || rc=$?
        if (( rc == 99 )); then fail "agent_can_traverse: $3 -- CLI not sourceable"
        elif { [[ "$2" == yes ]] && (( rc == 0 )); } || { [[ "$2" == no ]] && (( rc == 1 )); }; then pass "agent_can_traverse: $3 -> $2"
        else fail "agent_can_traverse: $3 -> exit ${rc}, want $2"; fi
    }
    ct_dir world 0711;                                             ct_is world      yes "world execute"
    ct_dir closed 0700;                                            ct_is closed     no  "owner-only, no ACL"
    ct_dir named 0700 "u:${SANDBOX_USER}:--x";                     ct_is named      yes "named-user entry with execute"
    ct_dir masked 0700 "u:${SANDBOX_USER}:--x" chmod:0700;         ct_is masked     no  "named-user entry under mask ---"
    ct_dir denied 0711 "u:${SANDBOX_USER}:---";                    ct_is denied     no  "named-user entry denying execute beside world execute"
    ct_dir ngroup 0700 "g:${SANDBOX_GROUP}:--x";                   ct_is ngroup     yes "named-group entry with execute"
    ct_dir ogroup 0710; chgrp "${SANDBOX_GROUP}" "${ct_work}/ogroup"; ct_is ogroup   yes "owning group is the sandbox group, group execute"
    ct_dir fgroup 0710;                                            ct_is fgroup     no  "group execute for a group that is not the sandbox group"
fi

# ── find_blocking_ancestors ──────────────────────────────────────────────────────────────────
# The walk behind the traverse grant. The kernel resolves each component on its own, so what the walk must not do is
# stop at the first directory the account can enter: a 700 directory that is the parent of a 755 one blocks the path,
# and a walk that ended at the open one would report the gap closed with the outer one still shut. A blocker no grant
# covers ends the walk, since a grant on a directory inside it could not open the path.
section "find_blocking_ancestors: every ancestor up to / is read, and only an ungrantable blocker ends the walk (unit)"
fb_work="${TESTDIR}/fb"
mkdir -p "${fb_work}/private/open/proj" "${fb_work}/foreign/mine/proj"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${fb_work}"
chown root:root "${fb_work}/foreign"
chmod 0755 "${fb_work}" "${fb_work}/private/open" "${fb_work}/private/open/proj" "${fb_work}/foreign/mine/proj"
chmod 0700 "${fb_work}/private" "${fb_work}/foreign" "${fb_work}/foreign/mine"
# fb_walk <dir>: print one `G=<path>` line per grant path and one `B=<path>` line, from the sourced shell.
fb_walk() {
    # shellcheck disable=SC2016  # the expansions are the inner shell's
    call_script 'find_blocking_ancestors "${args[0]}"
        printf "G=%s\n" "${TRAVERSAL_GRANT_PATHS[@]}"; printf "B=%s\n" "${TRAVERSAL_BLOCKED_PATH}"' "$1" 2>/dev/null
}
fb_out="$(fb_walk "${fb_work}/private/open/proj")" || true
if [[ "${fb_out}" == "G=${fb_work}/private"$'\n'"B=" ]]; then
    pass "find_blocking_ancestors reads past an open directory to its closed parent"
else
    fail "find_blocking_ancestors over 700/755/proj: $(tr '\n' '|' <<< "${fb_out}")"
fi
fb_out="$(fb_walk "${fb_work}/foreign/mine/proj")" || true
if [[ "${fb_out}" == "G=${fb_work}/foreign/mine"$'\n'"B=${fb_work}/foreign" ]]; then
    pass "find_blocking_ancestors collects the grantable blocker and stops at its foreign parent"
else
    fail "find_blocking_ancestors over root-700/700/proj: $(tr '\n' '|' <<< "${fb_out}")"
fi

# ── normalize_clone ──────────────────────────────────────────────────────────────────────────
# The step that opens a clone to the agent group once the gate has passed. What it must not do: change a path the gate
# did not scan -- chmod follows a symlink named on its command line, so a tracked link to a file outside the clone
# would take its target's mode with it -- and re-open a path the gate locked, which `-path` would miss if the locked
# name carried a pattern character (the bracket here) and were not escaped.
section "normalize_clone: opens files and directories alone, and keeps a locked path locked (unit)"
nc_work="${TESTDIR}/nc"; nc_out="${TESTDIR}/nc-outside"
mkdir -p "${nc_work}/config[prod]" "${nc_work}/sub"
: > "${nc_work}/config[prod]/.env"; : > "${nc_work}/plain.txt"; : > "${nc_out}"
ln -s "${nc_out}" "${nc_work}/link"
chown -R -h "${PROJECTS_USER}:${PROJECTS_GROUP}" "${nc_work}" "${nc_out}"
chmod 0700 "${nc_work}" "${nc_work}/config[prod]" "${nc_work}/sub"
chmod 0600 "${nc_work}/config[prod]/.env" "${nc_work}/plain.txt" "${nc_out}"
if call normalize_clone "${nc_work}" "${nc_work}/config[prod]/.env" >/dev/null 2>&1; then
    nc_ok=true
    [[ "$(perm "${nc_work}/plain.txt")" == 660 ]]  || { fail "normalize_clone: plain.txt is $(perm "${nc_work}/plain.txt"), want 660"; nc_ok=false; }
    [[ "$(stat -c '%a' "${nc_work}/sub")" == 2770 ]] || { fail "normalize_clone: sub is $(stat -c '%a' "${nc_work}/sub"), want 2770"; nc_ok=false; }
    ${nc_ok} && pass "normalize_clone opens a file to the group and sets setgid on a directory"
    if [[ "$(perm "${nc_out}")" == 600 ]]; then
        pass "normalize_clone leaves a symlink's target outside the clone as it was"
    else
        fail "normalize_clone changed the symlink target outside the clone: $(perm "${nc_out}")"
    fi
    if [[ "$(perm "${nc_work}/config[prod]/.env")" == 600 ]]; then
        pass "normalize_clone keeps a locked path whose name carries a pattern character locked"
    else
        fail "normalize_clone re-opened the locked path: $(perm "${nc_work}/config[prod]/.env")"
    fi
else
    fail "normalize_clone could not be driven (exit $?)"
fi

finish
