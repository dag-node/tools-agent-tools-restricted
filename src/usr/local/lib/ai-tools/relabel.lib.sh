#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/relabel.lib.sh
# Single source of the SELinux labelling primitives the sandbox applies at runtime, in three
# families:
#   * PROJECTS -- map an approved project directory to ai_tools_project_t (or revert it) so the
#     confined agent (ai_tools_t) can read and write the tree, and its build-output directories
#     to ai_tools_project_build_t. The directory names come from the installed integration
#     manifests (build_output_dirs, see dotnet.rule.md), so this library does not
#     name any toolchain's layout, and a host where no integration declares any writes only the
#     project rule. Sourced by the root helper ai-tools-relabel and by the policy installer
#     install-selinux.sh's registry sweep.
#   * AGENT PATHS -- map each enabled agent's own paths to the types this policy defines: its
#     launcher binary, under each name its manifest declares for that file, to ai_tools_exec_t (the label
#     that drives the -> ai_tools_t domain transition on exec) and its config directory to ai_tools_home_t
#     (so the confined session can write its state). Sourced by the root helper ai-tools-relabel-agent and by the same
#     installer's verify pass. The declared pattern APPLIES the label (an fcontext rule is what
#     makes a type survive a later restorecon); the launcher symlink, resolved the way the launch
#     preflight resolves it, CHECKS the result -- so a manifest that has stopped describing where
#     its package installs the executable, and a package that did not install the executable its
#     manifest declares, are each reported as such instead of passing as "not installed"
#     (ai_tools_relabel__evaluate_entrypoint_reconcile).
#   * OPERATOR CONFIG -- map one operator's ~/.config/ai-tools to ai_tools_conf_t, the narrow type
#     that lets the root helpers read that operator's project registry without reaching the rest of
#     ~/.config. Sourced by ai-tools-admin, which registers the rule for each account it enrols,
#     and by the same installer's sweep over the enrolled set.
# Every family keeps its `semanage fcontext` + `restorecon` body in exactly one place, and they write the one policy
# store -- so the library also owns the lock that serializes them (ai_tools_relabel__lock) and the reason a refused rule
# reports (AI_TOOLS_RELABEL__FCONTEXT_ERROR).
#
# In-place project paths (under a user's home) are DYNAMIC, so they get a per-project `semanage fcontext` rule here.
# Sandbox clones under /var/opt/ai-tools/sandbox-projects are already mapped by a STATIC rule in the policy's
# file-context source ai_tools.fc, so for those a plain restorecon suffices and adding a local rule would be redundant
# -- this library's helpers detect and skip the semanage step for sandbox paths. See ai_tools.fc and ai_tools.te
# in the policy source.
#
# Every mutating function is root-only: semanage writes the policy store and restorecon needs relabel. Callers must
# already be root. The functions are best-effort -- a disabled SELinux or a missing toolchain is reported via the return
# code (2 = unavailable, 1 = hard failure), never an abort -- so a sourcing script keeps `set -e` semantics by checking
# the return value.
#
# A recursive relabel of a tree the sandbox account can write -- a project or an agent's config directory -- runs
# through the descriptor-pinned walker ai-tools-relabel-tree (ai_tools_relabel__relabel_tree), so a rename or a planted
# symlink inside the tree during the walk does not redirect a write, and no walk here gates on a live session. A walk
# that leaves hardlinked paths returns 4 from the function that ran it, and a walker that cannot run returns 6, each
# function's contract stating its set. What the walker pins and the residual it leaves are its header's, and where each
# walk runs is cli.rule.md's (ref-section-e6c6). The per-path `restorecon -F` of an entrypoint is not a walk.

# Every type this library applies is pinned in this file, and the labelling functions do not take a type argument:
# a manifest or a caller names WHICH path is a project, a build-output directory, an entrypoint or a config directory,
# never what type it gets, so no manifest can label a file into a domain of its choosing.
readonly AI_TOOLS_RELABEL__PROJECT_TYPE="ai_tools_project_t"
# A project's build-output directories; a manifest names the directories (build_output_dirs).
readonly AI_TOOLS_RELABEL__PROJECT_BUILD_TYPE="ai_tools_project_build_t"
readonly AI_TOOLS_RELABEL__SANDBOX_ROOT="/var/opt/ai-tools/sandbox-projects"
# An agent's entrypoint: the label that drives the exec transition into ai_tools_t.
readonly AI_TOOLS_RELABEL__ENTRYPOINT_TYPE="ai_tools_exec_t"
# Every agent's own config directory -- the same type as the rest of the agent's home state, so the confined domain may
# write its session state there.
readonly AI_TOOLS_RELABEL__AGENT_CONFIG_TYPE="ai_tools_home_t"
# The one tree an agent entrypoint may live in -- the sandbox's own Node toolchain. Every declared pattern is checked
# against it through ai_tools_providers__is_entrypoint_fcontext_valid (providers.lib.sh), which takes the root
# as an argument so the two writers of the launcher chain hold a pattern to the same containment before they write
# a link to what it
# covers.
readonly AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT="/opt/ai-tools/.nvm/versions/node"
# The locked control-plane directory holding every agent's stable launcher symlink. Resolving through it is how this
# library learns where a package actually PUT its executable, rather than only where a manifest says it is
# (ai_tools_relabel__resolve_agent_entrypoint_path). Root-only test hook, the same posture as providers.lib.sh's
# manifest directories: the helpers that source this file run under sudo, which scrubs the environment, and the sudoers
# rules keep none of these names.
: "${AI_TOOLS_LAUNCHER_DIR:=/opt/ai-tools/bin}"

# Which agents are enabled and what each declares, and the containment predicate every declared entrypoint pattern
# passes, come from the provider manifests' reader; the home root, the config-directory contract, and its name validator
# come from control-plane.lib.sh (which loads providers itself). Both best-effort: without them the agent functions
# refuse (they resolve no agent, and a predicate that is not defined reads as a refusal at each call), while the project
# functions -- which need neither -- keep working.
# shellcheck source=SCRIPTDIR/providers.lib.sh
source "${BASH_SOURCE[0]%/*}/providers.lib.sh" 2>/dev/null || true
# shellcheck source=SCRIPTDIR/control-plane.lib.sh
source "${BASH_SOURCE[0]%/*}/control-plane.lib.sh" 2>/dev/null || true

# ── Serializing writes to the policy store ───────────────────────────────────────────────────
# semanage serializes on the policy store and reports an error to whichever process finds it held, rather than waiting
# for it, so two root helpers running at once leave rules unregistered and both report a failure neither caused.
# The helpers take this lock so the second one waits. Which callers overlap, and when, is in updater.rule.md.
#
# Root-only test hooks, the same posture as AI_TOOLS_LAUNCHER_DIR: the helpers that take this lock run under sudo,
# which scrubs the environment, and the sudoers rules keep neither name. A caller that did set one moves an advisory
# lock or shortens a wait, which can only leave a run unserialized -- the documented fail-soft -- and never changes
# what a label may be applied
# to.
: "${AI_TOOLS_RELABEL_LOCK:=/run/lock/ai-tools-relabel.lock}"
: "${AI_TOOLS_RELABEL_LOCK_WAIT:=120}"
# Why the lock could not be taken, or empty when it is held. Read by the caller after ai_tools_relabel__lock,
# which reports it in its own voice.
AI_TOOLS_RELABEL__LOCK_NOTE=""

# ai_tools_relabel__lock: hold AI_TOOLS_RELABEL_LOCK until ai_tools_relabel__unlock or the end of
#   the calling process.
#   Root-only: the lock file is created under /run/lock. Every writer of the policy store takes
#   it -- the root helpers, install-selinux.sh, and (open-coded on the same path, since a
#   scriptlet does not source this library) the ai-tools-selinux %post.
#
#   Call it in the CALLING shell, never through `$(...)`: the lock is an open file descriptor, and
#   a command substitution's subshell would drop it the moment the substitution returns. The
#   reason travels in AI_TOOLS_RELABEL__LOCK_NOTE for the same reason. A second call while the lock
#   is held returns at once: flock serializes open file descriptions, so a fresh descriptor on the
#   same file would wait on this process's own lock.
#
#   ALWAYS returns 0. A host without flock, a lock file that cannot be created, and a wait that
#   runs out all proceed unserialized: labelling is idempotent and every refusal is reported, so a
#   lock this helper cannot take costs a repeat run rather than a wrong label.
# shellcheck disable=SC2034  # AI_TOOLS_RELABEL__LOCK_NOTE is this function's output, read by
#                              ai-tools-relabel-agent and ai-tools-relabel.
ai_tools_relabel__lock() {
    AI_TOOLS_RELABEL__LOCK_NOTE=""
    [[ -z "${_ai_tools_relabel__lock_fd:-}" ]] || return 0
    if ! command -v flock >/dev/null 2>&1; then
        AI_TOOLS_RELABEL__LOCK_NOTE="flock is not installed"
        return 0
    fi
    # Two bash properties decide the shape of this line. The file is created by a SIMPLE command first, because a failed
    # redirection on a command-less `exec` exits a non-interactive shell outright -- turning "cannot serialize" into "no
    # relabel at all". And stderr is redirected BEFORE the create, because bash reports a failed redirection on whatever
    # stderr is in force as it processes that redirection, so the `>file 2>/dev/null` order still prints the error
    # and the note would be a second message for one condition.
    if ! : 2>/dev/null >"${AI_TOOLS_RELABEL_LOCK}"; then
        AI_TOOLS_RELABEL__LOCK_NOTE="cannot write ${AI_TOOLS_RELABEL_LOCK}"
        return 0
    fi
    exec {_ai_tools_relabel__lock_fd}>"${AI_TOOLS_RELABEL_LOCK}"
    flock -w "${AI_TOOLS_RELABEL_LOCK_WAIT}" "${_ai_tools_relabel__lock_fd}" \
        || AI_TOOLS_RELABEL__LOCK_NOTE="another relabel held the policy store for more than ${AI_TOOLS_RELABEL_LOCK_WAIT}s"
    return 0
}

# ai_tools_relabel__unlock: release the lock ai_tools_relabel__lock took, by closing its descriptor.
#   For a caller that writes the store in sections with a prompt between them
#   (install-selinux.sh): a lock held across a prompt makes every other writer wait out
#   AI_TOOLS_RELABEL_LOCK_WAIT and then proceed unserialized. A no-op when the lock is not held.
ai_tools_relabel__unlock() {
    [[ -n "${_ai_tools_relabel__lock_fd:-}" ]] || return 0
    exec {_ai_tools_relabel__lock_fd}>&-
    unset _ai_tools_relabel__lock_fd
    return 0
}

# ai_tools_relabel__is_available: 0 when restorecon is installed and `getenforce` does not print `Disabled`, the state
#   in which labelling can act; 2 otherwise. A host without `getenforce` reads as active: both ship in policycoreutils,
#   so a missing one is a broken toolchain, which the first semanage call then reports.
ai_tools_relabel__is_available() {
    command -v restorecon >/dev/null 2>&1 || return 2
    [[ "$(getenforce 2>/dev/null)" == "Disabled" ]] && return 2
    return 0
}

# The descriptor-pinned tree relabel every walk in this library runs. Root-only, as the walk is.
readonly _AI_TOOLS_RELABEL__TREE_WALKER_PATH=/usr/local/libexec/ai-tools/ai-tools-relabel-tree
# What the last walk printed on stderr but its summary line -- the hardlinked paths it listed, or why it failed -- its
# lines joined with "; ", since the walker escapes a `;` inside a path; the walker bounds what it prints. Set
# by ai_tools_relabel__relabel_tree for the caller that just called it, and by ai_tools_relabel__label_project
# to why the label did not hold where the walk completed and the root's type is not the project's.
# shellcheck disable=SC2034  # read by ai-tools-relabel, ai-tools-relabel-agent and install-selinux.sh
AI_TOOLS_RELABEL__TREE_DIAGNOSTICS=""
# The hardlinked paths the last walk skipped, from the walker's summary line; 0 where it printed none.
_AI_TOOLS_RELABEL__SKIPPED_HARDLINK_COUNT=0

# ai_tools_relabel__relabel_tree <dir>: label <dir> and every entry under it as `restorecon -FR` would, through
#   ai-tools-relabel-tree, its stderr kept in AI_TOOLS_RELABEL__TREE_DIAGNOSTICS. Returns 0 when the walk labelled every
#   entry, 4 when it completed and left hardlinked paths at their type, 1 when an entry could not be labelled or
#   the walker refused its root or its command line, and 6 when the walker could not run: not installed or not
#   executable, or libselinux.so.1 did not load, which the walker names. Public for install-selinux.sh, whose restores
#   of the sandbox account's trees run through it.
ai_tools_relabel__relabel_tree() {
    local dir="$1" rc=0 walker_diagnostics line kept=""
    AI_TOOLS_RELABEL__TREE_DIAGNOSTICS=""
    _AI_TOOLS_RELABEL__SKIPPED_HARDLINK_COUNT=0
    if [[ ! -x "${_AI_TOOLS_RELABEL__TREE_WALKER_PATH}" ]]; then
        AI_TOOLS_RELABEL__TREE_DIAGNOSTICS="${_AI_TOOLS_RELABEL__TREE_WALKER_PATH} is not installed or not executable"
        return 6
    fi
    walker_diagnostics="$("${_AI_TOOLS_RELABEL__TREE_WALKER_PATH}" -- "${dir}" 2>&1 >/dev/null)" || rc=$?
    # The summary line begins a line, which an escaped path cannot, so a name carrying its text is not read as it.
    while IFS= read -r line; do
        line="${line//$'\r'/}"
        if [[ "${line}" =~ ^summary\ hardlinks-left=([0-9]+)\ failures=[0-9]+$ ]]; then
            _AI_TOOLS_RELABEL__SKIPPED_HARDLINK_COUNT="$(( 10#${BASH_REMATCH[1]} ))"
        elif [[ -n "${line}" ]]; then
            kept+="${kept:+; }${line}"
        fi
    done <<< "${walker_diagnostics}"
    AI_TOOLS_RELABEL__TREE_DIAGNOSTICS="${kept}"
    case "${rc}" in
        0|4) return "${rc}" ;;
        3) AI_TOOLS_RELABEL__TREE_DIAGNOSTICS="${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS:-libselinux.so.1 did not load}"
           return 6 ;;
        *) AI_TOOLS_RELABEL__TREE_DIAGNOSTICS="${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS:-the walker exited ${rc} without a diagnostic}"
           return 1 ;;
    esac
}

# ai_tools_relabel__get_skipped_hardlink_count: print how many hardlinked paths the last walk skipped, as its summary
#   line counted them, listed or not.
ai_tools_relabel__get_skipped_hardlink_count() {
    printf '%s\n' "${_AI_TOOLS_RELABEL__SKIPPED_HARDLINK_COUNT}"
}

# _ai_tools_relabel__is_under_sandbox_root <dir>: 0 if <dir> lies under the statically-labelled sandbox root,
# whose subtree ai_tools.fc already maps to ai_tools_project_t.
_ai_tools_relabel__is_under_sandbox_root() { [[ "$1/" == "${AI_TOOLS_RELABEL__SANDBOX_ROOT}/"* ]]; }

# _ai_tools_relabel__list_build_output_names: print the build-output directory names every installed integration
#   declares (build_output_dirs), one per line, deduplicated. A name is accepted only as one plain
#   component -- letters, digits, `.`, `_`, `-` -- since it is spliced into a file-context regex
#   and a `/`, a `|` or a `(` would let a manifest widen the rule past the directories it names.
#   Sorted in the C locale, so the pattern a claim writes is the same on every host. Empty when
#   no integration declares any, or the provider resolver is not loaded.
_ai_tools_relabel__list_build_output_names() {
    declare -F ai_tools_providers__list_integrations_declaring >/dev/null 2>&1 || return 0
    local declared name
    local -a names
    while IFS=$'\t' read -r _ declared; do
        [[ -n "${declared}" ]] || continue
        names=()
        ai_tools_conf__split_list_value names "${declared}" 0 "build_output_dirs in an integration manifest"
        for name in "${names[@]}"; do
            [[ "${name}" =~ ^[A-Za-z0-9._-]+$ && "${name}" != *..* ]] || continue
            printf '%s\n' "${name}"
        done
    done < <(ai_tools_providers__list_integrations_declaring build_output_dirs 2>/dev/null) | LC_ALL=C sort -u
}

# ai_tools_relabel__read_project_build_pattern <dir>: print the file-context pattern matching every declared
#   build-output directory, at any depth under <dir>, and everything inside it --
#   `<dir>(/.*)?/(bin|obj)(/.*)?` for the names bin and obj. Dots in a name are escaped. Prints an
#   empty string and returns 1 when no name is declared, and the caller then skips the build rule.
#
#   Precedence over the project rule `<dir>(/.*)?` is what makes it a narrowing rather than a
#   no-op: libselinux keys precedence on the literal stem before the first metacharacter, which the
#   two rules share, and among equal stems the later, longer regex is the match. So the project
#   rule is registered FIRST and this one second (ai_tools_relabel__label_project), and the result is
#   verified with matchpathcon on a nested path when the policy is brought up, not assumed.
ai_tools_relabel__read_project_build_pattern() {
    local dir="$1" alternation="" name
    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        alternation+="${alternation:+|}$(ai_tools_relabel__get_fcontext_literal "${name}")"
    done < <(_ai_tools_relabel__list_build_output_names)
    [[ -n "${alternation}" ]] || return 1
    printf '%s(/.*)?/(%s)(/.*)?' "$(ai_tools_relabel__get_fcontext_literal "${dir}")" "${alternation}"
}

# ai_tools_relabel__get_fcontext_literal <text>: print <text> with every regex metacharacter backslash-escaped, so it
#   matches only itself inside a file-context pattern. A path is spliced into a regex, where an unescaped `.` in
#   `app.v1` also matches `appXv1` and a `+`, `(` or `|` changes which paths the rule covers.
#   args: $1 literal text  stdout: the escaped text
ai_tools_relabel__get_fcontext_literal() {
    local text="$1" out="" char i
    for (( i = 0; i < ${#text}; i++ )); do
        char="${text:i:1}"
        case "${char}" in
            \\|.|'['|']'|'('|')'|'{'|'}'|'*'|'+'|'?'|'^'|'$'|'|') out+="\\${char}" ;;
            *) out+="${char}" ;;
        esac
    done
    printf '%s' "${out}"
}

# _ai_tools_relabel__list_local_rules_under <dir>: print every LOCAL file-context pattern registered under
#   <dir>'s own rule -- the ones that start with `<dir>(/.*)?/` -- one per line. That is how an
#   unlabel finds the build rule it has to drop without recomputing it: the declared name set may
#   have changed since the claim, and a rule left behind would keep a subtree of an unclaimed
#   project on a type the confined domain manages. Parses `semanage fcontext -l -C -n` rows
#   (pattern, file-type words, context), stripping the trailing two fields so a pattern carrying
#   a space survives. <dir> is matched as given, so a caller passes the encoding the rule was
#   written with. Root-only, since the store is.
_ai_tools_relabel__list_local_rules_under() {
    local prefix="$1(/.*)?/" line pattern
    while IFS= read -r line; do
        pattern="$(sed -E 's/[[:space:]]+(all files|regular file|directory|character device|block device|socket|symbolic link|named pipe)[[:space:]]+[^[:space:]]+[[:space:]]*$//' <<<"${line}")"
        [[ "${pattern}" == "${prefix}"* ]] || continue
        printf '%s\n' "${pattern}"
    done < <(semanage fcontext -l -C -n 2>/dev/null || true)
}

# ai_tools_relabel__list_local_rules_naming_policy_types: print every LOCAL file-context rule whose type is this
#   policy's (`ai_tools_*`), one per line as `<pattern>TAB<file-type letter>TAB<type>`, the letter being what
#   `semanage fcontext -d -f` takes. `semodule -r` validates the local rules against the policy it leaves and refuses
#   while any names a type it removes, so a remove drops this set by type rather than the rules a registry derives.
#   Rows are parsed from the right, as _ai_tools_relabel__list_local_rules_under does. Root-only, since the store is.
ai_tools_relabel__list_local_rules_naming_policy_types() {
    semanage fcontext -l -C -n 2>/dev/null | awk '
        {
            split($NF, context, ":")
            if (context[3] !~ /^ai_tools_/) next
            if (!match($0, /[[:space:]]+(all files|regular file|directory|character device|block device|socket|symbolic link|named pipe)[[:space:]]+[^[:space:]]+[[:space:]]*$/)) next
            pattern = substr($0, 1, RSTART - 1)
            words = substr($0, RSTART)
            sub(/^[[:space:]]+/, "", words); sub(/[[:space:]]+[^[:space:]]+[[:space:]]*$/, "", words)
            letter = "p"
            if (words == "all files") letter = "a"
            else if (words == "regular file") letter = "f"
            else if (words == "directory") letter = "d"
            else if (words == "character device") letter = "c"
            else if (words == "block device") letter = "b"
            else if (words == "socket") letter = "s"
            else if (words == "symbolic link") letter = "l"
            printf "%s\t%s\t%s\n", pattern, letter, context[3]
        }' || true
}

# ai_tools_relabel__label_project <dir>: ensure <dir> and its subtree carry ai_tools_project_t, and its declared
# build-output directories ai_tools_project_build_t. Adds (or refreshes) the per-project fcontext rules -- skipped
# for sandbox clones, which the static rules already cover -- then forces the label through the tree walker
# (ai_tools_relabel__relabel_tree). Returns 2 if SELinux is unavailable, 1 on a hard failure (e.g. a type is not
# in the loaded policy because the module is not installed, an entry the walk could not label, or a root left
# on the wrong type because no fcontext rule matched the path), 6 when the walker could not run, 4 when the walk
# completed and left hardlinked paths at their type, and 0 on success. Both rules must register: a build rule the store
# refuses is a policy older than this library, and reporting it as a failed label is what gets the module rebuilt rather
# than leaving output on a type the group cannot run.
#
# The relabel is FORCED (`-F`), and that is load-bearing, not a tuning choice. A file created inside a labelled
# directory inherits ai_tools_project_t on its own, so an ordinary edit never drifts. But a file brought in carrying
# an EXPLICIT foreign context -- a context-preserving copy (`cp -a`, `tar --selinux`) of a system path, or any
# customizable type (e.g. httpd_sys_content_t) -- is one a plain `restorecon` deliberately PRESERVES. Only `-F` resets
# those to the project type. Skipping it leaves such a file unreadable to the confined agent (ai_tools_t), whose startup
# workspace walk then denies on every one -- a per-file AVC that setroubleshootd amplifies into a host-wide CPU flood.
# The walker compares before it writes, so it is idempotent on a matching context and costs the same walk either way,
# and forcing pays only for the drifted files it fixes.
#
# The fcontext rule is asserted whether or not the type already matches: it is what makes the type survive a future
# restorecon, and re-asserting it is how a type change from a policy bump reaches an existing project.
ai_tools_relabel__label_project() {
    local dir="$1" build_pattern project_fcontext_literal walk_status=0
    AI_TOOLS_RELABEL__TREE_DIAGNOSTICS=""
    ai_tools_relabel__is_available || return 2
    if ! _ai_tools_relabel__is_under_sandbox_root "${dir}"; then
        project_fcontext_literal="$(ai_tools_relabel__get_fcontext_literal "${dir}")"
        # `-a` on an existing entry reports it on stdout as well as failing, so both streams are dropped: the fallback
        # to `-m` is the handling, and the message reads as an error.
        semanage fcontext -a -t "${AI_TOOLS_RELABEL__PROJECT_TYPE}" "${project_fcontext_literal}(/.*)?" >/dev/null 2>&1 \
            || semanage fcontext -m -t "${AI_TOOLS_RELABEL__PROJECT_TYPE}" "${project_fcontext_literal}(/.*)?" >/dev/null 2>&1 \
            || return 1
        # The build rule goes in AFTER the project rule (see ai_tools_relabel__read_project_build_pattern).
        if build_pattern="$(ai_tools_relabel__read_project_build_pattern "${dir}")"; then
            semanage fcontext -a -t "${AI_TOOLS_RELABEL__PROJECT_BUILD_TYPE}" -- "${build_pattern}" >/dev/null 2>&1 \
                || semanage fcontext -m -t "${AI_TOOLS_RELABEL__PROJECT_BUILD_TYPE}" -- "${build_pattern}" >/dev/null 2>&1 \
                || return 1
        fi
    fi
    ai_tools_relabel__relabel_tree "${dir}" || walk_status=$?
    case "${walk_status}" in
        0|4) ;;
        6)   return 6 ;;
        *)   return 1 ;;
    esac
    # Post-condition: verify the achieved label, do not trust the walk's exit code. The walk writes the type the file
    # contexts give a path, which is the wrong type where no fcontext rule matched it (a rule keyed on a prefix that
    # libselinux aliases away, e.g. `/var/opt` -> `/opt` via file_contexts.subs_dist, does not match a path and leaves
    # the tree on its default type). Left unchecked that is a silent mislabel the confined agent cannot use; treat it as
    # a hard failure the caller reports rather than a false success.
    if ! ai_tools_relabel__is_project_labelled "${dir}"; then
        AI_TOOLS_RELABEL__TREE_DIAGNOSTICS="the walk completed and ${dir} does not carry ${AI_TOOLS_RELABEL__PROJECT_TYPE}: no file-context rule matches the path"
        return 1
    fi
    return "${walk_status}"
}

# ai_tools_relabel__unlabel_project <dir>: drop the per-project fcontext rules for <dir> -- its own rule and every local
# rule registered under it (the build rule, under whatever name set it was written with) -- and walk the subtree back to
# its default type (e.g. user_home_t) wherever a name exists at <dir>: a file or a symlink placed there reaches
# the walker, whose root check refuses it, so a tree renamed aside is not reported reverted. The semanage deletes are
# skipped for sandbox clones (no local rule was ever added); the walk still runs. Returns 2 if SELinux is unavailable,
# 1 when the walk could not label an entry, 6 when the walker could not run, 4 when the walk completed and left
# hardlinked paths at their current type, 3 when no name stands at <dir> once the rules are dropped, so no tree was
# walked, and 0 otherwise. Whether a 3 is the tree the caller expected to be gone or one moved away during the call is
# the caller's to decide, from what it read before. The rules are deleted under the escaped encoding
# ai_tools_relabel__label_project writes.
ai_tools_relabel__unlabel_project() {
    local dir="$1" pattern project_fcontext_literal walk_status=0
    ai_tools_relabel__is_available || return 2
    if ! _ai_tools_relabel__is_under_sandbox_root "${dir}"; then
        project_fcontext_literal="$(ai_tools_relabel__get_fcontext_literal "${dir}")"
        while IFS= read -r pattern; do
            [[ -n "${pattern}" ]] || continue
            semanage fcontext -d -- "${pattern}" >/dev/null 2>&1 || true
        done < <(_ai_tools_relabel__list_local_rules_under "${project_fcontext_literal}")
        semanage fcontext -d "${project_fcontext_literal}(/.*)?" 2>/dev/null || true
    fi
    [[ -e "${dir}" || -L "${dir}" ]] || return 3
    ai_tools_relabel__relabel_tree "${dir}" || walk_status=$?
    case "${walk_status}" in
        0|4|6) return "${walk_status}" ;;
        *)     return 1 ;;
    esac
}

# ── Agent-declared SELinux paths ─────────────────────────────────────────────────────────────
# Two paths per agent must carry a type from this policy, and both are agent-specific, so each agent package DECLARES
# them in its manifest and the rules are applied as LOCAL `semanage fcontext` entries rather than carried in the base
# policy module:
#
#   entrypoint_fcontext -> ai_tools_exec_t   the launcher binary. Without this label its exec
#                                            does not perform a domain transition and the session would run
#                                            unconfined (ai-tools-run refuses to launch instead).
#   entrypoint_link_fcontext -> ai_tools_exec_t
#                                            a further name the package gives that binary's inode (a hard
#                                            link). An inode holds one label, and a relabel that walks by
#                                            path (setfiles, an autorelabel) applies the rule of whichever
#                                            name it meets first, so each name maps to the one type.
#   config_dir          -> ai_tools_home_t   the agent's control-plane directory. Without it the
#                                            confined session cannot write its own state (the
#                                            home root is usr_t, which ai_tools_t may not write).
#
# Each declaration is checked to be containable -- an entrypoint pattern, either key's, under the sandbox toolchain
# (ai_tools_providers__is_entrypoint_fcontext_valid, providers.lib.sh, called
# with AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT), the config directory to one component under the sandbox home
# (ai_tools_control_plane__is_agent_config_dir_valid, control-plane.lib.sh). So a second agent brings its binary and its
# state directory into this policy without the base policy naming either.

# The characters a path in a status line is drawn from, as one bracket expression that bash's `=~` and find's
# POSIX-extended `-regex` both read: the predicate under this line and the entrypoint discovery share it, so a path
# the discovery prints is one the predicate accepts.
readonly _AI_TOOLS_RELABEL__REPORTABLE_PATH_REGEX='[]A-Za-z0-9_./@+^[-]+'

# _ai_tools_relabel__is_entrypoint_path_reportable <path>: succeed when <path> may be put in a status line.
#   The paths this pass reconciles are AGENT-INFLUENCED -- the middle link of the launcher chain is an
#   npm symlink the sandbox account owns -- and a status line is read back by a root helper that
#   splits it on whitespace and prints the fields to an operator's terminal. So a name is carried
#   only while it is absolute, `..`-free, and drawn from the same character set a declared pattern
#   is allowed; anything else is reported as unusable rather than emitted raw. Allowlist, not
#   blocklist: `]` leads the set and `-` closes it, the POSIX way to include both.
_ai_tools_relabel__is_entrypoint_path_reportable() {
    local path="${1:-}"
    [[ "${path}" == /* && "${path}" != *..* ]] || return 1
    [[ "${path}" =~ ^${_AI_TOOLS_RELABEL__REPORTABLE_PATH_REGEX}$ ]]
}

# ai_tools_relabel__evaluate_entrypoint_reconcile <installed-path> <covered> <matched> [copy]: pure verdict, no I/O
#   -- reconcile what an agent's manifest DECLARES against what its package actually INSTALLED,
#   and print one of:
#     ok          the declared rule governs the installed entrypoint (or no entrypoint is installed and
#                 the rule matched a file anyway -- another Node version's copy, mid-upgrade)
#     none        no entrypoint is installed and the rule matched no file: the agent is not provisioned yet
#     stale       an entrypoint IS installed elsewhere and the declared rule covers a file the launcher
#                 does not resolve to: the manifest has stopped describing its own package
#     incomplete  an entrypoint IS installed and the declared rule does not cover any file: the package
#                 did not install the entrypoint it declares
#     copied      the launcher resolves to a regular file outside the rule that is byte-identical to a file
#                 the rule matched and is another inode: a copy of the tree replaced a symlink in the chain
#                 with its target, so the manifest and the package agree and the toolchain's links are
#                 what need restoring
#   <installed-path> is the file the agent's launcher symlink resolves to, empty when it does not
#   resolve; <covered> is whether that file was among the matches of a declared pattern, entrypoint_fcontext's
#   or entrypoint_link_fcontext's, decided by path and not by inode: the launch preflight requires the rule
#   of the resolved path itself to map the entry type; <matched> is whether entrypoint_fcontext matched anything
#   at all; <copy> is whether the installed file is byte-identical to one of those matches. The flags are
#   `yes`/`no`, and anything other than the
#   exact literal `yes` reads as `no` -- an unknown input errs toward reporting a divergence, which
#   is the direction that fails a relabel loudly rather than blessing one silently.
#
#   The two divergent verdicts exist because the two sides are checked by different mechanisms and can
#   disagree: the launch preflight and the symlink helper RESOLVE the entrypoint, while this library
#   PATTERN-MATCHES a declared path. Where they disagree the launch fail-closes on an unlabelled inode,
#   so a relabel that reported `none` and exited 0 would name the wrong cause ("not installed") and send
#   the operator back around a loop that cannot clear it. The relabel does not label the resolved path
#   to compensate: the set of files that ever take ai_tools_exec_t -- the exec entrypoint of the
#   confined domain -- stays exactly the set the root-owned manifests declare, so a divergence is fixed
#   upstream of this helper, not by it widening the set on its own.
#
#   `matched` is what tells the two apart, and it decides which remedy the caller names: a declared rule
#   that covers no installed file at all describes an entrypoint the PACKAGE did not install, which
#   a toolchain reinstall puts back, while a rule covering some other file describes a MANIFEST that has
#   stopped matching the package, which a newer agent package carries. A toolchain holding an older Node
#   version whose package is still whole reads as `stale` on that older copy's match -- the declared
#   entrypoint is installed, and it is the launcher that resolves elsewhere.
#   The unit test relabel.sh drives the truth table.
ai_tools_relabel__evaluate_entrypoint_reconcile() {
    local installed="${1:-}" covered="${2:-}" matched="${3:-}" copy="${4:-}"
    if [[ -z "${installed}" ]]; then
        [[ "${matched}" == yes ]] && { printf 'ok'; return 0; }
        printf 'none'; return 0
    fi
    [[ "${covered}" == yes ]] && { printf 'ok'; return 0; }
    [[ "${matched}" == yes && "${copy}" == yes ]] && { printf 'copied'; return 0; }
    [[ "${matched}" == yes ]] && { printf 'stale'; return 0; }
    printf 'incomplete'
}

# _ai_tools_relabel__is_entrypoint_policy_active: succeed when there is an ai_tools_exec_t to assign, i.e.
#   SELinux is on, the labelling tools are present, and the ai_tools module is loaded. Where it
#   fails there is no entrypoint to label and that is not an error -- the SELinux layer is optional.
_ai_tools_relabel__is_entrypoint_policy_active() {
    ai_tools_relabel__is_available || return 1
    command -v semanage >/dev/null 2>&1 || return 1
    command -v semodule  >/dev/null 2>&1 || return 1
    # Captured ahead of the search (ref-section-d9x2).
    local modules
    modules="$(semodule -l 2>/dev/null || true)"
    grep -qx ai_tools <<<"${modules}"
}

# Why the last file-context rule could not be registered -- semanage's own stderr, newlines collapsed to keep it on one
# line. Set by _ai_tools_relabel__register_fcontext for the caller that just called it, which appends it to the `skip`
# status line it prints. That is why the reason travels on STDOUT rather than in this variable alone:
# ai_tools_relabel__label_agent_paths runs inside a `$(...)` in ai-tools-relabel-agent, and a variable set
# in that subshell does not survive the substitution, while its report does.
AI_TOOLS_RELABEL__FCONTEXT_ERROR=""

# _ai_tools_relabel__register_fcontext <add|delete> <file-type> <selinux-type> <pattern>: register or drop the local
#   file-context rule mapping <pattern> to <selinux-type>, scoped by semanage's file-type letter
#   (`f` regular files, as the base policy's own `--` rules are scoped; `a` all types, for a
#   subtree). Some semanage versions refuse an `-a` for a pattern already registered and others
#   modify it in place, so an add falls back to `-m` and the call is idempotent either way.
_ai_tools_relabel__register_fcontext() {
    local action="$1" file_type="$2" selinux_type="$3" pattern="$4" add_error modify_error
    AI_TOOLS_RELABEL__FCONTEXT_ERROR=""
    if [[ "${action}" == delete ]]; then
        semanage fcontext -d -f "${file_type}" -- "${pattern}" >/dev/null 2>&1 || true
        return 0
    fi
    # stdout is dropped and stderr is KEPT. semanage announces "already defined, modifying instead" on stdout, while
    # this function's caller emits a PARSED report on that stream, so anything written there is read as a verdict line.
    # stderr carries the reason an add was refused -- a policy store another semanage transaction holds, a type
    # the loaded policy does not define -- which reaches the operator through AI_TOOLS_RELABEL__FCONTEXT_ERROR.
    add_error="$(semanage fcontext -a -f "${file_type}" -t "${selinux_type}" -- "${pattern}" 2>&1 >/dev/null)" \
        && return 0
    modify_error="$(semanage fcontext -m -f "${file_type}" -t "${selinux_type}" -- "${pattern}" 2>&1 >/dev/null)" \
        && return 0
    # The add's message names the cause; the modify's usually reports the consequence ("not defined"), so it is
    # the fallback rather than the first choice. Newlines and carriage returns are collapsed: the caller puts this
    # on a status line its reader splits per line, so a multi-line message would read as extra verdicts.
    AI_TOOLS_RELABEL__FCONTEXT_ERROR="${add_error:-${modify_error:-semanage gave no reason}}"
    AI_TOOLS_RELABEL__FCONTEXT_ERROR="${AI_TOOLS_RELABEL__FCONTEXT_ERROR//$'\n'/ }"
    AI_TOOLS_RELABEL__FCONTEXT_ERROR="${AI_TOOLS_RELABEL__FCONTEXT_ERROR//$'\r'/ }"
    return 1
}

# _ai_tools_relabel__get_agent_config_pattern <config-dir-name>: print the file-context pattern for an agent's
#   config directory and everything under it. The name is escaped (ai_tools_relabel__get_fcontext_literal) and has
#   already been validated as one component.
_ai_tools_relabel__get_agent_config_pattern() {
    printf '%s/%s(/.*)?' "$(ai_tools_relabel__get_fcontext_literal "${CP_HOME}")" "$(ai_tools_relabel__get_fcontext_literal "$1")"
}

# _ai_tools_relabel__is_walk_root_absent <root> : succeed when <root> is confirmed not there, which is stat reporting
#   that the path or a component of it does not exist. Fails for every other reading: a root that is there and is not
#   a directory, and one whose state could not be read -- a directory on the way that cannot be searched, a refused
#   or failed read -- so a caller does not take a root it could not read for an empty one.
_ai_tools_relabel__is_walk_root_absent() {
    local report
    report="$(LC_ALL=C stat -- "$1" 2>&1 >/dev/null)" && return 1
    [[ "${report}" == *": No such file or directory" ]]
}

# _ai_tools_relabel__find_entrypoint_paths <pattern> [root]: print each installed file the pattern matches, one path
#   a line. find's POSIX-extended `-regex` matches the whole path, the same anchoring SELinux gives a file-context
#   regex, so the set relabelled here is the set the rule governs -- no second pattern language.
#   The walk is rooted at the toolchain (never `/`) and runs on a relabel, not on a launch.
#
#   A match is printed only while its whole path is drawn from the reportable character set and does not carry `..`
#   (_ai_tools_relabel__is_entrypoint_path_reportable). The class in a declared pattern (`[^/]+`) matches a newline
#   and a space, and the sandbox account names the directories under the root: a path carrying a newline would read
#   as two lines here, the second an absolute path of that account's choosing handed to root's restorecon, and one
#   carrying a space would split the status line it is printed in. Such a match is left as it is and counted
#   by _ai_tools_relabel__count_unprintable_entrypoint_paths. [root] is the fixture root of tests/unit/relabel.sh;
#   every caller in this library passes the pattern alone.
#
#   Returns find's status, so a caller that must know the walk completed captures the output and reads it; a root
#   confirmed not there (_ai_tools_relabel__is_walk_root_absent), the state before the toolchain is provisioned,
#   does not hold a match and returns 0, and one whose state could not be read returns 1.
_ai_tools_relabel__find_entrypoint_paths() {
    if [[ ! -d "${2:-${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}}" ]]; then
        _ai_tools_relabel__is_walk_root_absent "${2:-${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}}" || return 1
        return 0
    fi
    find "${2:-${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}}" -xdev -regextype posix-extended \
         -regex "$1" -regex "${_AI_TOOLS_RELABEL__REPORTABLE_PATH_REGEX}" ! -path '*..*' -type f 2>/dev/null
}

# _ai_tools_relabel__count_unprintable_entrypoint_paths <pattern> [root]: print how many installed files the pattern
#   matches at a path _ai_tools_relabel__find_entrypoint_paths does not print. Each is counted by one byte of find's
#   output, so no path is read. Returns find's status beside the count it could make, so a walk that failed is not
#   read as a count of zero; a root confirmed not there counts 0 and returns 0, and one whose state could not
#   be read prints 0 and returns 1.
_ai_tools_relabel__count_unprintable_entrypoint_paths() {
    local marks status=0
    if [[ ! -d "${2:-${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}}" ]]; then
        printf '0\n'
        _ai_tools_relabel__is_walk_root_absent "${2:-${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}}" || return 1
        return 0
    fi
    marks="$(find "${2:-${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}}" -xdev -regextype posix-extended \
                 -regex "$1" -type f \( ! -regex "${_AI_TOOLS_RELABEL__REPORTABLE_PATH_REGEX}" -o -path '*..*' \) \
                 -printf 'x' 2>/dev/null)" || status=$?
    printf '%s\n' "${#marks}"
    return "${status}"
}

# _ai_tools_relabel__read_mapped_type <path> : print the TYPE field of the context the file-context database maps <path>
#   to (`matchpathcon -n`), the answer a relabel of that path gives; `<<none>>` where no rule maps it. Prints an empty
#   string and returns 1 where the lookup could not be made.
_ai_tools_relabel__read_mapped_type() {
    local context type
    context="$(matchpathcon -n "$1" 2>/dev/null)" || return 1
    [[ -n "${context}" ]] || return 1
    if [[ "${context}" == "<<none>>" ]]; then printf '<<none>>\n'; return 0; fi
    IFS=: read -r _ _ type _ <<< "${context}" || true
    [[ -n "${type}" ]] || return 1
    printf '%s\n' "${type}"
}

# _ai_tools_relabel__list_entrypoint_name_findings <root> <path> : ask the file-context database what it maps each name
#   of <path>'s inode to, and print one line per finding. A file with one link has one name, <path> itself; for one
#   with more, every name under <root> on <path>'s filesystem is read (`find -xdev -samefile`).
#     unmapped <name>        the database maps that name to another type than the entrypoint's: for <path> itself
#                            the launch preflight refuses, and for another name a relabel that walks by path can
#                            leave the inode on that type
#     unchecked <path> <n>   <n> names of the inode are outside the reportable character set, one carrying a newline
#                            among them; such a name is not printed and its mapping is not looked up
#     outside <path> <n>     the inode has <n> more links than names found: it has names outside <root>,
#                            which no rule a manifest declares can cover, since each is contained to that root
#     unread <path>          the link count or a name's mapping could not be read, or the walk failed and left names
#                            unaccounted for
#   The database's own answer decides, not a match against the manifest's patterns: a local rule registered later
#   can map a name a declared pattern matches to another type. Each name is one record of the walk whatever bytes it
#   holds, since find prints a fixed word for a path carrying a newline, so such a name cannot end one record and begin
#   another. Returns 0 with no line where every name is found and mapped to the entry type, whatever the walk exited
#   with; returns 1 with a finding. <root> is an argument, so tests/unit/relabel.sh drives the read over a fixture
#   of real hard links. A read, as root over the 0750 toolchain; it runs on a relabel and in the root status report, not
#   on a launch.
_ai_tools_relabel__list_entrypoint_name_findings() {
    local root="$1" path="$2" link_count records record name mapped_type
    local found_count=0 unchecked_count=0 walk_status=0 mapping_unread=no status=0
    link_count="$(stat -c '%h' -- "${path}" 2>/dev/null)" || link_count=""
    if [[ ! "${link_count}" =~ ^[0-9]+$ ]]; then
        printf 'unread %s\n' "${path}"
        return 1
    fi
    if (( link_count > 1 )); then
        records="$(find "${root}" -xdev -samefile "${path}" \
                       \( -path $'*\n*' -printf 'newline\n' -o -printf 'name %p\n' \) 2>/dev/null)" || walk_status=$?
    else
        # One name, the path itself, so no walk: its mapping is read like any other name's.
        records="name ${path}"
    fi
    while IFS= read -r record; do
        [[ -n "${record}" ]] || continue
        found_count=$(( found_count + 1 ))
        name="${record#name }"
        if [[ "${record}" == newline ]] || ! _ai_tools_relabel__is_entrypoint_path_reportable "${name}"; then
            unchecked_count=$(( unchecked_count + 1 ))
            continue
        fi
        mapped_type="$(_ai_tools_relabel__read_mapped_type "${name}" || true)"
        if [[ -z "${mapped_type}" ]]; then
            mapping_unread=yes
        elif [[ "${mapped_type}" != "${AI_TOOLS_RELABEL__ENTRYPOINT_TYPE}" ]]; then
            printf 'unmapped %s\n' "${name}"
            status=1
        fi
    done <<< "${records}"
    if (( unchecked_count > 0 )); then
        printf 'unchecked %s %s\n' "${path}" "${unchecked_count}"
        status=1
    fi
    if (( found_count < link_count && walk_status == 0 )); then
        printf 'outside %s %s\n' "${path}" "$(( link_count - found_count ))"
        status=1
    fi
    if [[ "${mapping_unread}" == yes ]] || (( found_count < link_count && walk_status != 0 )); then
        printf 'unread %s\n' "${path}"
        status=1
    fi
    return "${status}"
}

# _ai_tools_relabel__read_entrypoint_patterns <agent> <array-name> : fill <array-name> with the entrypoint patterns
#   <agent>'s manifest declares that pass the containment, entrypoint_fcontext first. A key the manifest does not carry
#   and a value the containment refuses are left out, so a caller that must report a refused value reads that key
#   itself. Returns 0.
_ai_tools_relabel__read_entrypoint_patterns() {
    local _relabel_agent="$1" _relabel_key _relabel_value
    local -n _relabel_patterns="$2"
    _relabel_patterns=()
    for _relabel_key in entrypoint_fcontext entrypoint_link_fcontext; do
        _relabel_value="$(ai_tools_providers__read_agent_manifest_field "${_relabel_agent}" "${_relabel_key}" || true)"
        [[ -n "${_relabel_value}" ]] || continue
        ai_tools_providers__is_entrypoint_fcontext_valid "${_relabel_value}" "${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}" \
            || continue
        _relabel_patterns+=("${_relabel_value}")
    done
    return 0
}

# ai_tools_relabel__resolve_agent_entrypoint_path <agent>: print the file <agent>'s stable launcher symlink resolves to
#   -- the inode execve transitions on, which is what makes the reconciliation independent of
#   where a manifest says the executable lives. This is the SAME resolution ai-tools-run's preflight
#   and ai-tools-launcher-symlink's idempotency guard perform (`realpath -e` through the chain), so
#   the three cannot disagree about which file is the entrypoint. Runs as root, which can traverse
#   the 0750 toolchain the chain ends in.
#
#   Prints an empty string and returns non-zero when the agent does not declare a usable launcher name, the link
#   does not resolve (the agent is not provisioned -- the ordinary pre-bootstrap state), or the
#   result is not reportable. The launcher name is allowlisted to one plain component before it
#   becomes a path, the same guard ai_tools_providers__read_agent_manifest_field applies to an agent name, so a
#   manifest cannot address a link outside the control-plane bin directory.
ai_tools_relabel__resolve_agent_entrypoint_path() {
    local agent="$1" launcher resolved
    launcher="$(ai_tools_providers__read_agent_manifest_field "${agent}" launcher || true)"
    [[ "${launcher}" =~ ^[A-Za-z0-9._-]+$ && "${launcher}" != *..* ]] || return 1
    resolved="$(realpath -e "${AI_TOOLS_LAUNCHER_DIR}/${launcher}" 2>/dev/null)" || return 1
    _ai_tools_relabel__is_entrypoint_path_reportable "${resolved}" || return 1
    printf '%s\n' "${resolved}"
}

# _ai_tools_relabel__read_live_type <path> : print the TYPE field of the label <path> carries right now, or an empty
#   string when it cannot be read. The one place a live label is read, shared by the verify verify pass
#   and by the read-only report at the end of this file, so "what type is on this file" has one answer however it is
#   asked. Needs to traverse the 0750 toolchain, so in practice root.
_ai_tools_relabel__read_live_type() {
    stat -c '%C' -- "$1" 2>/dev/null | awk -F: '{print $3}'
}

# _ai_tools_relabel__verify_label <path> <wanted-type> : restore the label on <path> with a per-path `restorecon -F`
#   and report the outcome as one status line (see ai_tools_relabel__label_agent_paths). For an entrypoint alone:
#   a root write by a path that does not walk, under no component the sandbox account can rename. Returns non-zero when
#   the path did not take the type.
_ai_tools_relabel__verify_label() {
    restorecon -F "$1" 2>/dev/null || true
    _ai_tools_relabel__report_current_label "$1" "$2"
}

# _ai_tools_relabel__report_current_label <path> <wanted-type> : read the type <path> carries now, without a write,
#   and report it as one status line (see ai_tools_relabel__label_agent_paths). Returns non-zero when it is not
#   <wanted-type>.
_ai_tools_relabel__report_current_label() {
    local path="$1" wanted="$2" context
    context="$(_ai_tools_relabel__read_live_type "${path}")"
    if [[ "${context}" == "${wanted}" ]]; then
        printf 'ok %s\n' "${path}"
        return 0
    fi
    printf 'bad %s %s %s\n' "${path}" "${context:-unknown}" "${wanted}"
    return 1
}

# _ai_tools_relabel__label_agent_entrypoint <agent> : the entrypoint half of ai_tools_relabel__label_agent_paths.
#   Applies the declared rule, then RECONCILES it against the installed entrypoint. Emits status lines; returns non-zero
#   on a refusal, a path that did not take the type, or a declaration the installed entrypoint has outgrown.
#
#   The declared pattern stays the mechanism that APPLIES the label, because a `semanage fcontext`
#   rule is what makes the type survive a later restorecon -- resolution alone would relabel an
#   inode no rule keeps labelled. Resolution is what CHECKS the result, so this helper's exit
#   status answers the question the operator actually asked: will the next launch be confined?
#
#   A manifest's entrypoint_link_fcontext is registered beside the entrypoint rule, each rule ahead of the first
#   restorecon, and what it matches is labelled and verified the same way. A value the containment refuses is
#   a refusal, as the entrypoint pattern's is. The names of each labelled inode are then read
#   (_ai_tools_relabel__list_entrypoint_name_findings), once per inode, and a finding is printed and leaves
#   the status alone: the inode carries its type, and the next launch is confined. The one finding that fails is
#   the launcher's own resolved path mapped to another type (`mismapped`), which the launch preflight refuses on.
#   A match at a path a status line does not print is not labelled and is counted in a `skip` line. A lookup
#   of the launcher's resolved path that cannot be made fails the same way, with a `skip` line.
_ai_tools_relabel__label_agent_entrypoint() {
    local agent="$1" pattern link_pattern declared_pattern path other seen finding detail unprintable_count
    local status=0 matched=no installed covered=no
    # Resolved BEFORE the rule is applied, so a later refusal still leaves the reconciliation inputs gathered
    # from the same state the launch preflight would see.
    installed="$(ai_tools_relabel__resolve_agent_entrypoint_path "${agent}" || true)"
    pattern="$(ai_tools_providers__read_agent_manifest_field "${agent}" entrypoint_fcontext || true)"
    if [[ -z "${pattern}" ]]; then
        printf 'skip %s declares no entrypoint_fcontext\n' "${agent}"
        return 0
    fi
    if ! ai_tools_providers__is_entrypoint_fcontext_valid "${pattern}" "${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}"; then
        printf 'skip %s entrypoint_fcontext is not a plain path pattern under %s\n' \
            "${agent}" "${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}"
        return 1
    fi
    link_pattern="$(ai_tools_providers__read_agent_manifest_field "${agent}" entrypoint_link_fcontext || true)"
    if [[ -n "${link_pattern}" ]] && ! ai_tools_providers__is_entrypoint_fcontext_valid \
            "${link_pattern}" "${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}"; then
        printf 'skip %s entrypoint_link_fcontext is not a plain path pattern under %s\n' \
            "${agent}" "${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}"
        return 1
    fi
    local -a patterns=("${pattern}") matches=() link_paths=() checked_paths=()
    [[ -z "${link_pattern}" ]] || patterns+=("${link_pattern}")
    # Every rule is registered ahead of the first restorecon, so no name of a hard-linked entrypoint is restored
    # under the default rule of its path while its own rule is still to come.
    for declared_pattern in "${patterns[@]}"; do
        if ! _ai_tools_relabel__register_fcontext add f "${AI_TOOLS_RELABEL__ENTRYPOINT_TYPE}" "${declared_pattern}"; then
            printf 'skip %s could not register its entrypoint file-context rule -- %s\n' \
                "${agent}" "${AI_TOOLS_RELABEL__FCONTEXT_ERROR}"
            return 1
        fi
    done
    while IFS= read -r path; do
        matched=yes
        matches+=("${path}")
        [[ "${path}" == "${installed}" ]] && covered=yes
        _ai_tools_relabel__verify_label "${path}" "${AI_TOOLS_RELABEL__ENTRYPOINT_TYPE}" || status=1
    done < <(_ai_tools_relabel__find_entrypoint_paths "${pattern}")
    if [[ -n "${link_pattern}" ]]; then
        while IFS= read -r path; do
            link_paths+=("${path}")
            [[ "${path}" == "${installed}" ]] && covered=yes
            _ai_tools_relabel__verify_label "${path}" "${AI_TOOLS_RELABEL__ENTRYPOINT_TYPE}" || status=1
        done < <(_ai_tools_relabel__find_entrypoint_paths "${link_pattern}")
    fi
    # The mapping the launch preflight reads is the database's answer for the path the launcher resolves to. A lookup
    # that cannot be made is a launch the preflight refuses, so it fails here with the reason, whatever the names read
    # under this line reports for the inode.
    if [[ -n "${installed}" && -z "$(_ai_tools_relabel__read_mapped_type "${installed}" || true)" ]]; then
        printf 'skip %s could not read what the file-context database maps its entrypoint %s to -- the launch preflight reads that mapping and refuses without it\n' \
            "${agent}" "${installed}"
        status=1
    fi
    # The names of each labelled inode, read once per inode: the names of a hard-linked entrypoint are each a match.
    for path in "${matches[@]}" "${link_paths[@]}"; do
        seen=no
        for other in "${checked_paths[@]}"; do
            if [[ "${path}" -ef "${other}" ]]; then seen=yes; break; fi
        done
        [[ "${seen}" == no ]] || continue
        checked_paths+=("${path}")
        while read -r finding detail; do
            [[ -n "${finding}" ]] || continue
            # The path the launcher resolves to, mapped to another type: the launch preflight reads that mapping
            # and refuses, whatever type the file carries, so it is a failure and not a names finding.
            if [[ "${finding}" == unmapped && -n "${installed}" && "${detail}" == "${installed}" ]]; then
                printf 'mismapped %s %s\n' "${agent}" "${installed}"
                status=1
                continue
            fi
            printf '%s %s %s\n' "${finding}" "${agent}" "${detail}"
        done < <(_ai_tools_relabel__list_entrypoint_name_findings "${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}" "${path}")
    done
    unprintable_count=0
    for declared_pattern in "${patterns[@]}"; do
        unprintable_count=$(( unprintable_count
                              + $(_ai_tools_relabel__count_unprintable_entrypoint_paths "${declared_pattern}" || true) ))
    done
    if (( unprintable_count > 0 )); then
        printf 'skip %s left %s file(s) an entrypoint rule matches unlabelled -- each path carries a character a status line does not print\n' \
            "${agent}" "${unprintable_count}"
    fi
    # Whether the launcher resolves to a copy of a declared entrypoint, the one divergence the toolchain's own links
    # explain. Read by content, a comparison and not an execution, and only once the path check has already failed.
    # A second name of a matched inode is not a copy: it is a link the manifest does not declare, which reads `stale`.
    local copy=no
    if [[ -n "${installed}" && "${covered}" != yes && -f "${installed}" && ! -L "${installed}" ]]; then
        for path in "${matches[@]}"; do
            [[ "${installed}" -ef "${path}" ]] && continue
            cmp -s -- "${installed}" "${path}" && { copy=yes; break; }
        done
    fi

    case "$(ai_tools_relabel__evaluate_entrypoint_reconcile "${installed}" "${covered}" "${matched}" "${copy}")" in
        # 3, not 0: the rule registered and no step failed, but no file took the type because none is installed yet.
        # The caller reports that as `nothing to label`, not as labels applied: on an unprovisioned host that is
        # the difference between a true report and a green line for work that did not happen.
        none)  printf 'none %s its entrypoint\n' "${agent}"
               if [[ "${status}" -eq 0 ]]; then status=3; fi ;;
        stale) printf 'stale %s %s\n' "${agent}" "${installed}"; status=1 ;;
        copied) printf 'copied %s %s\n' "${agent}" "${installed}"; status=1 ;;
        incomplete) printf 'incomplete %s %s\n' "${agent}" "${installed}"; status=1 ;;
    esac
    return "${status}"
}

# _ai_tools_relabel__label_agent_config_dir <agent> : the config-directory half. Same shape; the subtree is labelled
#   through the tree walker, and only the directory itself is then checked, read-only (its contents inherit). Returns 0
#   with no config_dir declared and once the directory carries its type, 1 for a declaration the containment refuses,
#   a rule that could not be registered, a walk that could not run or could not label an entry, and a directory left
#   on another type, and 3 when the directory is not there, the status the caller files it under. A walk that left
#   hardlinked paths prints `partial <agent> <n>` and goes on to the check.
_ai_tools_relabel__label_agent_config_dir() {
    local agent="$1" config_dir path pattern walk_status=0
    config_dir="$(ai_tools_providers__read_agent_manifest_field "${agent}" config_dir || true)"
    if [[ -z "${config_dir}" ]]; then
        printf 'skip %s declares no config_dir\n' "${agent}"
        return 0
    fi
    if ! declare -F ai_tools_control_plane__is_agent_config_dir_valid >/dev/null 2>&1 \
            || ! ai_tools_control_plane__is_agent_config_dir_valid "${config_dir}"; then
        printf 'skip %s config_dir is not one plain component under %s\n' "${agent}" "${CP_HOME}"
        return 1
    fi
    pattern="$(_ai_tools_relabel__get_agent_config_pattern "${config_dir}")"
    if ! _ai_tools_relabel__register_fcontext add a "${AI_TOOLS_RELABEL__AGENT_CONFIG_TYPE}" "${pattern}"; then
        printf 'skip %s could not register its config-directory file-context rule -- %s\n' \
            "${agent}" "${AI_TOOLS_RELABEL__FCONTEXT_ERROR}"
        return 1
    fi
    path="${CP_HOME}/${config_dir}"
    if [[ ! -d "${path}" ]]; then
        printf 'none %s its config directory\n' "${agent}"
        return 3
    fi
    ai_tools_relabel__relabel_tree "${path}" || walk_status=$?
    case "${walk_status}" in
        0) ;;
        4) printf 'partial %s %s\n' "${agent}" "$(ai_tools_relabel__get_skipped_hardlink_count)" ;;
        6) printf 'skip %s could not walk its config directory -- %s\n' "${agent}" "${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS}"
           return 1 ;;
        *) printf 'bad %s unknown %s\n' "${path}" "${AI_TOOLS_RELABEL__AGENT_CONFIG_TYPE}"
           return 1 ;;
    esac
    _ai_tools_relabel__report_current_label "${path}" "${AI_TOOLS_RELABEL__AGENT_CONFIG_TYPE}"
}

# ai_tools_relabel__label_agent_paths: apply every ENABLED agent's declared file-context rules -- its entrypoint and its
#   config directory -- and restore the labels on what they match. Prints one status line per outcome, for the caller
#   to render in its own voice:
#     ok    <path>                     the path carries the type the base pins for it
#     bad   <path> <actual> <wanted>   it does not -- the session would break or run unconfined
#     none  <agent> <what>             declared, but not installed (yet)
#     stale <agent> <installed-path>   an entrypoint IS installed and the agent's declared rule
#                                      covers some other file, so no relabel can label it -- the
#                                      agent package's manifest has to be updated
#     incomplete <agent> <installed-path>
#                                      an entrypoint IS installed and the declared rule covers no
#                                      file at all -- the package did not install the entrypoint it
#                                      declares, and the toolchain has to reinstall it
#     unmapped <agent> <name>          a name of a labelled entrypoint inode that the file-context
#                                      database maps to another type; the inode carries its type,
#                                      and a relabel that walks by path can leave it on that one
#     mismapped <agent> <path>         the file-context database maps the path the agent's launcher
#                                      resolves to, <path>, to another type: the launch preflight reads
#                                      that mapping and refuses, whatever type the file carries
#     unchecked <agent> <path> <n>     <n> names of the inode of <path> carry a character a status line
#                                      does not print, and their mapping was not looked up
#     outside <agent> <path> <n>       the inode of <path> has <n> names outside the toolchain, which
#                                      no declared rule can cover
#     unread <agent> <path>            the names of that inode, or a name's mapping, could not be read
#     skip  <agent> <reason...>        no rule to apply, a declaration was refused, or the walk
#                                      over the config directory could not run
#     partial <agent> <n>              the walk over the config directory completed and left <n>
#                                      hardlinked paths under it at their type; the agent's closing
#                                      line reads ok over it where the declared paths took their
#                                      type, since a path a label leaves keeps the type it had and
#                                      grants the agent no access it lacked
#     agent <agent> <ok|failed|none>   that agent's whole outcome, closing its lines: every path it
#                                      declares took its type, one of them did not, or neither is
#                                      installed to label. This is what ai-tools-relabel-agent
#                                      records per agent for `atr status` to report, so the
#                                      operator can see the labelling half from outside the
#                                      toolchain they cannot read.
#   Returns 0 when every path it managed is correctly labelled, 1 when one is not, a rule could
#   not be registered, or an entrypoint is installed that the declared rule does not govern, and 2
#   when the SELinux layer is inactive (no work to do). An `unmapped`, `unchecked`, `outside` or `unread` line leaves
#   the status and the agent's closing line as they are: the caller records and counts it. A `mismapped` line is
#   a failure.
ai_tools_relabel__label_agent_paths() {
    _ai_tools_relabel__is_entrypoint_policy_active || return 2
    declare -F ai_tools_providers__list_enabled_agents >/dev/null 2>&1 || return 2
    local agent status=0 entrypoint_rc config_rc agent_status
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        entrypoint_rc=0; config_rc=0
        _ai_tools_relabel__label_agent_entrypoint "${agent}" || entrypoint_rc=$?
        _ai_tools_relabel__label_agent_config_dir  "${agent}" || config_rc=$?
        # Only 1 is a failure. 3 says the path is not installed yet, which is the ordinary pre-bootstrap state and must
        # not fail a relabel that did everything it could.
        if [[ "${entrypoint_rc}" -eq 1 || "${config_rc}" -eq 1 ]]; then
            agent_status=failed; status=1
        elif [[ "${entrypoint_rc}" -eq 3 && "${config_rc}" -eq 3 ]]; then
            agent_status=none
        else
            agent_status=ok
        fi
        printf 'agent %s %s\n' "${agent}" "${agent_status}"
    done < <(ai_tools_providers__list_enabled_agents 2>/dev/null)
    return "${status}"
}

# ai_tools_relabel__unlabel_agent_paths <agent>: drop that agent's declared file-context rules and restore
#   default labels on what they matched -- the erase-time counterpart, so a removed agent package
#   leaves behind no rule for types its host may stop defining. Reads the manifest, so it runs
#   while that package's files are still present (rpm %preun). Returns 2 when the SELinux layer is
#   inactive, 1 when the agent does not declare a usable value, 5 when the rules were dropped and a path they covered
#   keeps its type -- an entrypoint path still carrying ai_tools_exec_t after its per-path `restorecon -F`, or one whose
#   type could not be read back, a file a dropped entrypoint rule matched at a path a status line does not print,
#   which is not reverted, a walk for those files that did not complete, or an entry the walk over its config directory
#   could not label -- 4 when the rules
#   were dropped and that walk completed leaving hardlinked paths at their type, 6 when the rules were dropped and
#   the walker could not run, and 0 otherwise. AI_TOOLS_RELABEL__TREE_DIAGNOSTICS names each entrypoint path left,
#   then carries the walk's own lines, and each status after the drop is its own, so a reader does not tell them apart
#   by whether the walker printed. The entrypoint's outcome is a read-back of its type and not restorecon's status,
#   which is swallowed: this is the removal direction, where a path left at the type is more access, and the one
#   the tree walk after the policy's unload does not write, since the entrypoint is hardlinked. Every entrypoint rule
#   the manifest declares is dropped ahead of the first restorecon: a link name restored while its rule still stands
#   puts ai_tools_exec_t back on the inode the entrypoint's revert has just cleared.
ai_tools_relabel__unlabel_agent_paths() {
    local agent="$1" pattern config_dir path live_type matches unprintable_count
    local dropped=1 walk_status=0 walk_complete=yes kept=""
    local -a patterns=()
    AI_TOOLS_RELABEL__TREE_DIAGNOSTICS=""
    _ai_tools_relabel__is_entrypoint_policy_active || return 2
    declare -F ai_tools_providers__read_agent_manifest_field >/dev/null 2>&1 || return 2

    _ai_tools_relabel__read_entrypoint_patterns "${agent}" patterns
    for pattern in "${patterns[@]}"; do
        _ai_tools_relabel__register_fcontext delete f "${AI_TOOLS_RELABEL__ENTRYPOINT_TYPE}" "${pattern}"
        dropped=0
    done
    for pattern in "${patterns[@]}"; do
        # Captured, so the walk's status is read: a walk that failed has not listed every file the rule matched.
        matches="$(_ai_tools_relabel__find_entrypoint_paths "${pattern}")" || walk_complete=no
        while IFS= read -r path; do
            [[ -n "${path}" ]] || continue
            restorecon -F "${path}" 2>/dev/null || true
            live_type="$(_ai_tools_relabel__read_live_type "${path}")"
            if [[ -z "${live_type}" ]]; then
                kept+="${kept:+; }the type of ${path} could not be read back after its revert"
            elif [[ "${live_type}" == "${AI_TOOLS_RELABEL__ENTRYPOINT_TYPE}" ]]; then
                kept+="${kept:+; }${path} keeps ${AI_TOOLS_RELABEL__ENTRYPOINT_TYPE} after its revert"
            fi
        done <<< "${matches}"
        unprintable_count="$(_ai_tools_relabel__count_unprintable_entrypoint_paths "${pattern}")" || walk_complete=no
        if (( unprintable_count > 0 )); then
            kept+="${kept:+; }${unprintable_count} file(s) a dropped entrypoint rule matched were not reverted, each at a path carrying a character a status line does not print"
        fi
    done
    if [[ "${walk_complete}" == no ]]; then
        kept+="${kept:+; }the walk over ${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT} for the files a dropped entrypoint rule matched did not complete, so a file may keep ${AI_TOOLS_RELABEL__ENTRYPOINT_TYPE}"
    fi

    config_dir="$(ai_tools_providers__read_agent_manifest_field "${agent}" config_dir || true)"
    if declare -F ai_tools_control_plane__is_agent_config_dir_valid >/dev/null 2>&1 \
            && ai_tools_control_plane__is_agent_config_dir_valid "${config_dir}"; then
        _ai_tools_relabel__register_fcontext delete a "${AI_TOOLS_RELABEL__AGENT_CONFIG_TYPE}" \
            "$(_ai_tools_relabel__get_agent_config_pattern "${config_dir}")"
        # The directory itself is agent STATE and survives the package (like .nvm), so it is relabelled to whatever
        # the remaining policy maps it to rather than left on a type this host may stop defining.
        path="${CP_HOME}/${config_dir}"
        if [[ -d "${path}" ]]; then
            ai_tools_relabel__relabel_tree "${path}" || walk_status=$?
        fi
        dropped=0
    fi
    # The walk reset the diagnostics to its own lines; the entrypoint paths left go ahead of them.
    AI_TOOLS_RELABEL__TREE_DIAGNOSTICS="${kept}${kept:+${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS:+; }}${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS}"
    [[ -z "${kept}" ]] || return 5
    case "${walk_status}" in
        0)   return "${dropped}" ;;
        4|6) return "${walk_status}" ;;
        *)   return 5 ;;
    esac
}

# ai_tools_relabel__list_agent_labels: PRINT the type each enabled agent's own paths carry RIGHT NOW --
#   its installed entrypoint and its config directory -- against the types this library pins for
#   them. One status line per path, whitespace-separated in a fixed field order so a caller reads
#   it with a plain `read`, and rendered in the caller's own voice:
#     ok   <agent> <what> <path> <type>            it carries the type the base pins for it
#     bad  <agent> <what> <path> <actual> <wanted> it does not -- the session would break or run
#                                                  unconfined
#     none <agent> <what>                          declared, but not installed (the pre-bootstrap
#                                                  state)
#     unmapped <agent> entrypoint <name>           a name of the installed entrypoint's inode that the
#                                                  file-context database maps to another type
#     mismapped <agent> entrypoint <path>          the file-context database maps the entrypoint's own
#                                                  path to another type, so the launch preflight refuses
#     unchecked <agent> entrypoint <path> <n>      <n> of its names carry a character a status line does
#                                                  not print, and their mapping was not looked up
#     outside <agent> entrypoint <path> <n>        that inode has <n> names outside the toolchain
#     unread <agent> entrypoint <path>             its names, or a name's mapping, could not be read
#   <what> is one token, `entrypoint` or `config-directory`, so the field after it is always the
#   path and a caller never has to count words. The names lines are
#   _ai_tools_relabel__list_entrypoint_name_findings's, read for the inode a session execs.
#   Returns 0 when every path it could inspect carries its type and no names line was printed, 1 otherwise, 2 when
#   the SELinux layer is inactive, which yields an empty report and is not a fault, and 3 with an empty
#   report when a function it calls is not defined (the enabled-agent resolver, the manifest-field
#   reader, the entrypoint resolver): a reading it could not make, which must not read as an inactive
#   layer, an uninstalled entrypoint or an agent without a config directory.
#
#   READ-ONLY, which is the whole difference from ai_tools_relabel__label_agent_paths: it calls
#   neither _ai_tools_relabel__register_fcontext, nor restorecon, nor ai_tools_relabel__lock, so it answers a status
#   question without changing the state it reports on. It also answers a different question: the
#   relabel reports what its own run ACHIEVED, while this reports the type on the file now,
#   however long ago that run was.
#
#   The path is resolved through the launcher symlink (ai_tools_relabel__resolve_agent_entrypoint_path), the same
#   resolution the launch preflight performs, so what is inspected is the inode a session execs,
#   which a declared pattern can have stopped describing.
ai_tools_relabel__list_agent_labels() {
    _ai_tools_relabel__is_entrypoint_policy_active || return 2
    declare -F ai_tools_providers__list_enabled_agents >/dev/null 2>&1 || return 3
    declare -F ai_tools_providers__read_agent_manifest_field >/dev/null 2>&1 || return 3
    declare -F ai_tools_relabel__resolve_agent_entrypoint_path >/dev/null 2>&1 || return 3
    local agent entrypoint config_dir path context finding detail status=0
    local -a patterns=()
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        entrypoint="$(ai_tools_relabel__resolve_agent_entrypoint_path "${agent}" || true)"
        if [[ -z "${entrypoint}" ]]; then
            printf 'none %s entrypoint\n' "${agent}"
        else
            # An agent declaring no usable pattern is the relabel's refusal to report, and every name of its entrypoint
            # would read as unmapped here, so the names are read only against a declared pattern.
            _ai_tools_relabel__read_entrypoint_patterns "${agent}" patterns
            if (( ${#patterns[@]} > 0 )); then
                while read -r finding detail; do
                    [[ -n "${finding}" ]] || continue
                    # The entrypoint's own path: the mapping the launch preflight reads.
                    [[ "${finding}" == unmapped && "${detail}" == "${entrypoint}" ]] && finding=mismapped
                    printf '%s %s entrypoint %s\n' "${finding}" "${agent}" "${detail}"
                    status=1
                done < <(_ai_tools_relabel__list_entrypoint_name_findings \
                             "${AI_TOOLS_RELABEL__NODE_VERSIONS_ROOT}" "${entrypoint}")
            fi
            context="$(_ai_tools_relabel__read_live_type "${entrypoint}")"
            if [[ "${context}" == "${AI_TOOLS_RELABEL__ENTRYPOINT_TYPE}" ]]; then
                printf 'ok %s entrypoint %s %s\n' "${agent}" "${entrypoint}" "${context}"
            else
                printf 'bad %s entrypoint %s %s %s\n' "${agent}" "${entrypoint}" \
                    "${context:-unknown}" "${AI_TOOLS_RELABEL__ENTRYPOINT_TYPE}"
                status=1
            fi
        fi

        config_dir="$(ai_tools_providers__read_agent_manifest_field "${agent}" config_dir || true)"
        if [[ -z "${config_dir}" ]] \
                || ! declare -F ai_tools_control_plane__is_agent_config_dir_valid >/dev/null 2>&1 \
                || ! ai_tools_control_plane__is_agent_config_dir_valid "${config_dir}"; then
            continue
        fi
        path="${CP_HOME}/${config_dir}"
        if [[ ! -d "${path}" ]]; then
            printf 'none %s config-directory\n' "${agent}"
            continue
        fi
        context="$(_ai_tools_relabel__read_live_type "${path}")"
        if [[ "${context}" == "${AI_TOOLS_RELABEL__AGENT_CONFIG_TYPE}" ]]; then
            printf 'ok %s config-directory %s %s\n' "${agent}" "${path}" "${context}"
        else
            printf 'bad %s config-directory %s %s %s\n' "${agent}" "${path}" \
                "${context:-unknown}" "${AI_TOOLS_RELABEL__AGENT_CONFIG_TYPE}"
            status=1
        fi
    done < <(ai_tools_providers__list_enabled_agents 2>/dev/null)
    return "${status}"
}

# ai_tools_relabel__is_project_labelled <dir>: 0 if <dir>'s root currently carries ai_tools_project_t. A cheap,
# read-only state check for idempotent callers -- it inspects the live label, leaves the policy alone, and does not need
# privilege.
ai_tools_relabel__is_project_labelled() {
    local ctx
    ctx="$(ls -Zd "$1" 2>/dev/null | awk '{print $1}')" || return 1
    [[ "${ctx}" == *":${AI_TOOLS_RELABEL__PROJECT_TYPE}:"* ]]
}

# ── The operator config subtree ──────────────────────────────────────────────────────────────
# One operator's ~/.config/ai-tools carries ai_tools_conf_t, the type the root helpers read that account's project
# registry and secret-patterns through. A home path is dynamic, so the rule is a local `semanage fcontext` entry rather
# than a line in ai_tools.fc, and there is one per operator. What the type buys, and what an unlabelled subtree costs
# that operator, are in
# confinement.rule.md.

# The type an operator's config subtree carries.
readonly AI_TOOLS_RELABEL__OPERATOR_CONF_TYPE="ai_tools_conf_t"
# The tail every such directory ends with, and the only shape this library will label. Kept as one constant because
# the validator and the pattern builder must agree on it.
readonly AI_TOOLS_RELABEL__OPERATOR_CONF_TAIL="/.config/ai-tools"

# ai_tools_relabel__is_operator_conf_valid <dir> : succeed when <dir> may become an ai_tools_conf_t fcontext rule. PURE
#   -- no filesystem, no privilege -- so the containment property is unit-tested without a labelled host. <dir> must be
#   absolute, carry no `..`, and end in the fixed ~/.config/ai-tools tail with a non-empty home in front of it.
#
#   The home is additionally held to an allowlisted character set, which is the containment guard:
#   it arrives from a passwd entry, and a regex metacharacter there would reach the rule's pattern
#   and widen it past the one subtree -- a `|` naming a second path outright, a `*` or `[` matching
#   homes nobody enrolled. Refusing is safe in the direction that matters: an unlabelled subtree
#   costs that operator their ownership handback, which the caller reports, while a widened rule
#   would hand ai_tools_conf_t to paths that do not belong to any operator.
ai_tools_relabel__is_operator_conf_valid() {
    local dir="${1:-}" home
    [[ "${dir}" == /* ]]                              || return 1
    [[ "${dir}" != *..* ]]                            || return 1
    [[ "${dir}" == *"${AI_TOOLS_RELABEL__OPERATOR_CONF_TAIL}" ]] || return 1
    home="${dir%"${AI_TOOLS_RELABEL__OPERATOR_CONF_TAIL}"}"
    # `/?*` rather than `-n`: a home of `/` would put the rule on the filesystem root's own .config, which is root's
    # home shape, and `ai-tools-admin operators add` refuses root.
    [[ "${home}" == /?* ]]                            || return 1
    [[ "${home}" =~ ^[A-Za-z0-9/._-]+$ ]]             || return 1
    return 0
}

# _ai_tools_relabel__get_operator_conf_pattern <dir> : the file-context pattern covering <dir> and everything under it.
#   The path is escaped (ai_tools_relabel__get_fcontext_literal): a bare `.` in a file-context regex matches any
#   character, so an unescaped `/home/a.b` would also cover `/home/axb`, a home this operator does not own.
_ai_tools_relabel__get_operator_conf_pattern() { printf '%s(/.*)?' "$(ai_tools_relabel__get_fcontext_literal "$1")"; }

# ai_tools_relabel__label_operator_conf <dir> : register the local rule mapping <dir> and its contents
#   to ai_tools_conf_t, then apply it. ROOT ONLY (semanage writes the policy store); the caller takes
#   ai_tools_relabel__lock, as every other writer here does.
#
#   Returns 2 where there is no label to apply -- SELinux inactive, or no semanage -- which is the
#   DAC-only host and not a fault; 1 when the directory is unusable, the rule could not be
#   registered (the reason is left in AI_TOOLS_RELABEL__FCONTEXT_ERROR for the caller to report), or the
#   subtree did not take the type; 0 once it carries it.
#
#   The rule is registered whether or not the type already matches, for the reason
#   ai_tools_relabel__label_project gives: an fcontext entry is what makes the type survive a later
#   restorecon. Re-asserting it is also what a re-run repairs a host with, where a semanage
#   transaction found the store held and the rule was left unregistered.
ai_tools_relabel__label_operator_conf() {
    local dir="${1:-}"
    ai_tools_relabel__is_operator_conf_valid "${dir}" || return 1
    ai_tools_relabel__is_available            || return 2
    command -v semanage >/dev/null 2>&1   || return 2
    [[ -d "${dir}" ]]                     || return 1
    _ai_tools_relabel__register_fcontext add a "${AI_TOOLS_RELABEL__OPERATOR_CONF_TYPE}" \
        "$(_ai_tools_relabel__get_operator_conf_pattern "${dir}")" || return 1
    restorecon -FR "${dir}" 2>/dev/null   || return 1
    # The post-condition, not restorecon's exit code: it exits 0 whenever it could write a context, including one
    # that is the wrong type because no rule matched the path (see ai_tools_relabel__label_project). A wrong type
    # reported as applied leaves the caller recording success over a subtree the root helpers are still denied on.
    [[ "$(_ai_tools_relabel__read_live_type "${dir}")" == "${AI_TOOLS_RELABEL__OPERATOR_CONF_TYPE}" ]]
}

# ai_tools_relabel__unlabel_operator_conf <dir> : drop the local rule for <dir> and restorecon the subtree back to its
#   default type (config_home_t). Root-only. Returns 2 where SELinux is inactive, 1 on a restorecon failure, 0
#   otherwise. The delete is best-effort: a store that does not hold the rule is the state this leaves behind anyway.
#   The rule is dropped under the escaped encoding ai_tools_relabel__label_operator_conf writes.
ai_tools_relabel__unlabel_operator_conf() {
    local dir="${1:-}" pattern
    ai_tools_relabel__is_operator_conf_valid "${dir}" || return 1
    ai_tools_relabel__is_available            || return 2
    command -v semanage >/dev/null 2>&1   || return 2
    pattern="$(_ai_tools_relabel__get_operator_conf_pattern "${dir}")"
    _ai_tools_relabel__register_fcontext delete a "${AI_TOOLS_RELABEL__OPERATOR_CONF_TYPE}" "${pattern}" || true
    [[ -d "${dir}" ]] || return 0
    restorecon -FR "${dir}" 2>/dev/null || return 1
}
