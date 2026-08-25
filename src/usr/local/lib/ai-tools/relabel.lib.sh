#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/relabel.lib.sh
# Single source of the SELinux labelling primitives the sandbox applies at runtime, in two
# families:
#   * PROJECTS -- map an approved project directory to ai_tools_project_t (or revert it) so the
#     confined agent (ai_tools_t) can read and write the tree. Sourced by the root helper
#     ai-tools-relabel and by selinux/install-selinux.sh's allowlist sweep.
#   * AGENT PATHS -- map each enabled agent's own paths to the types this policy defines: its
#     launcher binary to ai_tools_exec_t (the label that drives the -> ai_tools_t domain
#     transition on exec) and its config directory to ai_tools_home_t (so the confined session can
#     write its state). Sourced by the root helper ai-tools-relabel-agent and by the same
#     installer's verify pass. The declared pattern APPLIES the label (an fcontext rule is what
#     makes a type survive a later restorecon); the launcher symlink, resolved the way the launch
#     preflight resolves it, CHECKS the result -- so a manifest that has stopped describing where
#     its package installs the executable is reported as such instead of passing as "not
#     installed" (ai_tools_entrypoint_reconcile_verdict).
# Both families keep their `semanage fcontext` + `restorecon` body in exactly one place, and both
# write the one policy store -- so the library also owns the lock that serializes them
# (ai_tools_relabel_lock) and the reason a refused rule reports (AI_TOOLS_FCONTEXT_ERROR).
#
# In-place project paths (under a user's home) are DYNAMIC, so they get a
# per-project `semanage fcontext` rule here. Sandbox clones under
# /var/opt/ai-tools/sandbox-projects are already mapped by a STATIC rule in
# selinux/policy/ai_tools.fc, so for those a plain restorecon suffices and adding a local
# rule would be redundant -- the helpers below detect and skip the semanage step
# for sandbox paths. See selinux/policy/ai_tools.fc and selinux/policy/ai_tools.te.
#
# Every mutating function is root-only: semanage writes the policy store and
# restorecon needs relabel. Callers must already be root. The functions are
# best-effort -- a disabled SELinux or a missing toolchain is reported via the
# return code (2 = unavailable, 1 = hard failure), never an abort -- so a sourcing
# script keeps `set -e` semantics by checking the return value.

readonly AI_TOOLS_PROJECT_TYPE="ai_tools_project_t"
readonly AI_TOOLS_SANDBOX_ROOT="/var/opt/ai-tools/sandbox-projects"
# The entrypoint type is pinned HERE, not read from a manifest: an agent package declares only
# WHICH path is its entrypoint, never what type to give it, so no manifest can label a file into
# a domain of its choosing.
readonly AI_TOOLS_ENTRYPOINT_TYPE="ai_tools_exec_t"
# The type every agent's own config directory carries -- the same one the rest of the agent's
# home state uses, so the confined domain may write its session state there.
readonly AI_TOOLS_AGENT_CONFIG_TYPE="ai_tools_home_t"
# The one tree an agent entrypoint may live in -- the sandbox's own Node toolchain. Every
# declared pattern is checked against it (ai_tools_entrypoint_fcontext_valid).
readonly AI_TOOLS_ENTRYPOINT_ROOT="/opt/ai-tools/.nvm/versions/node"
# The locked control-plane directory holding every agent's stable launcher symlink. Resolving
# through it is how this library learns where a package actually PUT its executable, rather than
# only where a manifest says it is (ai_tools_agent_entrypoint_path). Root-only test hook, the same
# posture as providers.lib.sh's manifest directories: the helpers that source this file run under
# sudo, which scrubs the environment, and the sudoers rules keep none of these names.
: "${AI_TOOLS_LAUNCHER_DIR:=/opt/ai-tools/bin}"

# Which agents are enabled and what each declares comes from the provider manifests; the home
# root, the config-directory contract, and its name validator come from control-plane.lib.sh
# (which loads providers itself). Both best-effort: without them the agent functions below refuse
# (they resolve no agent), while the project functions -- which need neither -- keep working.
# shellcheck source=SCRIPTDIR/providers.lib.sh
source "${BASH_SOURCE[0]%/*}/providers.lib.sh" 2>/dev/null || true
# shellcheck source=SCRIPTDIR/control-plane.lib.sh
source "${BASH_SOURCE[0]%/*}/control-plane.lib.sh" 2>/dev/null || true

# ── Serializing writes to the policy store ───────────────────────────────────────────────────
# semanage serializes on the policy store and reports an error to whichever process finds it held,
# rather than waiting for it, so two root helpers running at once leave rules unregistered and
# both report a failure neither caused. The helpers take this lock so the second one waits. Which
# callers overlap, and when, is in .claude/rules/updater.rule.md.
#
# Root-only test hooks, the same posture as AI_TOOLS_LAUNCHER_DIR above: the helpers that take
# this lock run under sudo, which scrubs the environment, and the sudoers rules keep neither name.
# A caller that did set one moves an advisory lock or shortens a wait, which can only leave a run
# unserialized -- the documented fail-soft below -- and never changes what a label may be applied
# to.
: "${AI_TOOLS_RELABEL_LOCK:=/run/lock/ai-tools-relabel.lock}"
: "${AI_TOOLS_RELABEL_LOCK_WAIT:=120}"
# Why the lock could not be taken, or empty when it is held. Read by the caller after
# ai_tools_relabel_lock, which reports it in its own voice.
AI_TOOLS_RELABEL_LOCK_NOTE=""

# ai_tools_relabel_lock: hold AI_TOOLS_RELABEL_LOCK for the rest of the calling process, so a
#   concurrent relabel waits rather than colliding inside semanage. Root-only: the lock file is
#   created under /run/lock.
#
#   Call it in the CALLING shell, never through `$(...)`: the lock is an open file descriptor, and
#   a command substitution's subshell would drop it the moment the substitution returns. The
#   reason travels in AI_TOOLS_RELABEL_LOCK_NOTE for the same reason.
#
#   ALWAYS returns 0. A host without flock, a lock file that cannot be created, and a wait that
#   runs out all proceed unserialized: labelling is idempotent and every refusal is reported, so a
#   lock this helper cannot take costs a repeat run rather than a wrong label.
# shellcheck disable=SC2034  # AI_TOOLS_RELABEL_LOCK_NOTE is this function's output, read by
#                              ai-tools-relabel-agent and ai-tools-relabel.
ai_tools_relabel_lock() {
    AI_TOOLS_RELABEL_LOCK_NOTE=""
    if ! command -v flock >/dev/null 2>&1; then
        AI_TOOLS_RELABEL_LOCK_NOTE="flock is not installed"
        return 0
    fi
    # Two bash properties decide the shape of this line. The file is created by a SIMPLE command
    # first, because a failed redirection on a command-less `exec` exits a non-interactive shell
    # outright -- turning "cannot serialize" into "no relabel at all". And stderr is redirected
    # BEFORE the create, because bash reports a failed redirection on whatever stderr is in force
    # as it processes that redirection, so the `>file 2>/dev/null` order still prints the error and
    # the note below would be a second message for one condition.
    if ! : 2>/dev/null >"${AI_TOOLS_RELABEL_LOCK}"; then
        AI_TOOLS_RELABEL_LOCK_NOTE="cannot write ${AI_TOOLS_RELABEL_LOCK}"
        return 0
    fi
    exec {_ai_tools_relabel_lock_fd}>"${AI_TOOLS_RELABEL_LOCK}"
    flock -w "${AI_TOOLS_RELABEL_LOCK_WAIT}" "${_ai_tools_relabel_lock_fd}" \
        || AI_TOOLS_RELABEL_LOCK_NOTE="another relabel held the policy store for more than ${AI_TOOLS_RELABEL_LOCK_WAIT}s"
    return 0
}

# ai_tools_relabel_available: 0 when SELinux is active and restorecon is present,
# i.e. when labelling can do anything. Non-zero (2) otherwise.
ai_tools_relabel_available() {
    command -v restorecon >/dev/null 2>&1 || return 2
    [[ "$(getenforce 2>/dev/null)" == "Disabled" ]] && return 2
    return 0
}

# _ai_tools_is_sandbox <dir>: 0 if <dir> lies under the statically-labelled sandbox
# root, whose subtree ai_tools.fc already maps to ai_tools_project_t.
_ai_tools_is_sandbox() { [[ "$1/" == "${AI_TOOLS_SANDBOX_ROOT}/"* ]]; }

# ai_tools_label_project <dir>: ensure <dir> and its subtree carry ai_tools_project_t.
# Adds (or refreshes) the per-project fcontext rule -- skipped for sandbox clones, which the
# static rule already covers -- then forces the label with `restorecon -FR`.
# Returns 2 if SELinux is unavailable, 1 on a hard failure (e.g. the type is not in the loaded
# policy because the module is not installed, or restorecon left the tree on the wrong type
# because no fcontext rule matched the path), 0 on success.
#
# The relabel is FORCED (`-F`), and that is load-bearing, not a tuning choice. A file created
# inside a labelled directory inherits ai_tools_project_t on its own, so an ordinary edit never
# drifts. But a file brought in carrying an EXPLICIT foreign context -- a context-preserving copy
# (`cp -a`, `tar --selinux`) of a system path, or any customizable type (e.g. httpd_sys_content_t)
# -- is one a plain `restorecon` deliberately PRESERVES. Only `-F` resets those to the project
# type. Skipping it leaves such a file unreadable to the confined agent (ai_tools_t), whose startup
# workspace walk then denies on every one -- a per-file AVC that setroubleshootd amplifies into a
# host-wide CPU flood. `-F` rewrites nothing already correct (restorecon compares before it writes,
# so it is idempotent on a matching context and costs the same walk either way), so forcing pays
# only for the drifted files it fixes.
#
# The fcontext rule is asserted whether or not the type already matches: it is what makes the type
# survive a future restorecon, and re-asserting it is how a type change from a policy bump reaches
# an existing project.
ai_tools_label_project() {
    local dir="$1"
    ai_tools_relabel_available || return 2
    if ! _ai_tools_is_sandbox "${dir}"; then
        # `-a` on an existing entry reports it on stdout as well as failing, so both streams are
        # dropped: the fallback to `-m` is the handling, and the message reads as an error.
        semanage fcontext -a -t "${AI_TOOLS_PROJECT_TYPE}" "${dir}(/.*)?" >/dev/null 2>&1 \
            || semanage fcontext -m -t "${AI_TOOLS_PROJECT_TYPE}" "${dir}(/.*)?" >/dev/null 2>&1 \
            || return 1
    fi
    restorecon -FR "${dir}" 2>/dev/null || return 1
    # Post-condition: verify the achieved label, do not trust restorecon's exit code. restorecon
    # exits 0 whenever it could WRITE a context -- including when the context it wrote is the wrong
    # type because no fcontext rule matched the path (a rule keyed on a prefix that libselinux
    # aliases away, e.g. `/var/opt` -> `/opt` via file_contexts.subs_dist, matches nothing and
    # leaves the tree on its default type). Left unchecked that is a silent mislabel the confined
    # agent cannot use; treat it as a hard failure the caller reports rather than a false success.
    ai_tools_project_labelled "${dir}" || return 1
}

# ai_tools_unlabel_project <dir>: drop any per-project fcontext rule for <dir> and
# restorecon the subtree back to its default type (e.g. user_home_t). The semanage
# delete is skipped for sandbox clones (no local rule was ever added); the
# restorecon still runs. Returns 2 if SELinux is unavailable, 1 on restorecon
# failure, 0 otherwise.
ai_tools_unlabel_project() {
    local dir="$1"
    ai_tools_relabel_available || return 2
    _ai_tools_is_sandbox "${dir}" \
        || semanage fcontext -d "${dir}(/.*)?" 2>/dev/null || true
    restorecon -FR "${dir}" 2>/dev/null || return 1
}

# ── Agent-declared SELinux paths ─────────────────────────────────────────────────────────────
# Two paths per agent must carry a type from this policy, and both are agent-specific, so each
# agent package DECLARES them in its manifest and the rules are applied as LOCAL
# `semanage fcontext` entries rather than carried in the base policy module:
#
#   entrypoint_fcontext -> ai_tools_exec_t   the launcher binary. Without this label its exec
#                                            fires no domain transition and the session would run
#                                            unconfined (ai-tools-run refuses to launch instead).
#   config_dir          -> ai_tools_home_t   the agent's control-plane directory. Without it the
#                                            confined session cannot write its own state (the
#                                            home root is usr_t, which ai_tools_t may not write).
#
# The base pins the TYPES here; a manifest chooses only which path is which, and each declaration
# is checked to be containable -- the entrypoint pattern under the sandbox toolchain, the config
# directory to one component under the sandbox home. So a second agent brings its binary and its
# state directory into this policy without the base policy naming either.

# ai_tools_entrypoint_fcontext_valid <pattern>: pure check, no I/O -- succeed when <pattern> is a
#   file-context regex that can only ever match inside the sandbox toolchain. Two conditions,
#   both required, because the type it will be given is an exec entrypoint of the confined
#   domain: with its backslash escapes removed the pattern must start with the toolchain root
#   (so the literal head is anchored there), and it must contain no `|`, `(`, or other
#   metacharacter that could match a path outside that head. Character classes, `*`, `+`, `.`,
#   and escapes are what a path pattern needs and all it gets.
ai_tools_entrypoint_fcontext_valid() {
    # Path characters, character classes, `*`, `+`, `.` and escapes -- no `|`, no `(`, no `$`,
    # no whitespace. `]` leads the set and `-` closes it, the POSIX way to include both.
    local allowed='^[]A-Za-z0-9_./@+*^[\-]+$'
    local pattern="${1:-}" plain="${1//\\/}"
    [[ -n "${pattern}" ]] || return 1
    [[ "${pattern}" =~ ${allowed} ]] || return 1
    [[ "${pattern}" != *..* ]] || return 1
    [[ "${plain}" == "${AI_TOOLS_ENTRYPOINT_ROOT}/"* ]]
}

# _ai_tools_entrypoint_path_reportable <path>: succeed when <path> may be put in a status line.
#   The paths reconciled below are AGENT-INFLUENCED -- the middle link of the launcher chain is an
#   npm symlink the sandbox account owns -- and a status line is read back by a root helper that
#   splits it on whitespace and prints the fields to an operator's terminal. So a name is carried
#   only while it is absolute, `..`-free, and drawn from the same character set a declared pattern
#   is allowed; anything else is reported as unusable rather than emitted raw. Allowlist, not
#   blocklist: `]` leads the set and `-` closes it, the POSIX way to include both.
_ai_tools_entrypoint_path_reportable() {
    local path="${1:-}"
    [[ "${path}" == /* && "${path}" != *..* ]] || return 1
    [[ "${path}" =~ ^[]A-Za-z0-9_./@+^[-]+$ ]]
}

# ai_tools_entrypoint_reconcile_verdict <installed-path> <covered> <matched>: pure verdict, no I/O
#   -- reconcile what an agent's manifest DECLARES against what its package actually INSTALLED,
#   and print one of:
#     ok     the declared rule governs the installed entrypoint (or nothing is installed and the
#            rule matched a file anyway -- another Node version's copy, mid-upgrade)
#     none   nothing is installed and nothing matched: the agent is simply not provisioned yet
#     stale  an entrypoint IS installed and the declared rule does not cover it
#   <installed-path> is the file the agent's launcher symlink resolves to, empty when it does not
#   resolve; <covered> is whether that file was among the pattern's matches; <matched> is whether
#   the pattern matched anything at all. Both flags are `yes`/`no`, and anything other than the
#   exact literal `yes` reads as `no` -- an unknown input errs toward reporting a divergence, which
#   is the direction that fails a relabel loudly rather than blessing one silently.
#
#   `stale` exists because the two are checked by different mechanisms and can disagree: the launch
#   preflight and the symlink helper RESOLVE the entrypoint, while this library PATTERN-MATCHES a
#   declared path. Where they disagree the launch fail-closes on an unlabelled inode, so a relabel
#   that reported `none` and exited 0 would name the wrong cause ("not installed") and send the
#   operator back around a loop that cannot clear it. The relabel does not label the resolved path
#   to compensate: the set of files that ever take ai_tools_exec_t -- the exec entrypoint of the
#   confined domain -- stays exactly the set the root-owned manifests declare, so a stale manifest
#   is fixed by updating the agent package, not by this helper widening the set on its own.
#   Unit-tested over the truth table (tests/unit/relabel.sh).
ai_tools_entrypoint_reconcile_verdict() {
    local installed="${1:-}" covered="${2:-}" matched="${3:-}"
    if [[ -z "${installed}" ]]; then
        [[ "${matched}" == yes ]] && { printf 'ok'; return 0; }
        printf 'none'; return 0
    fi
    [[ "${covered}" == yes ]] && { printf 'ok'; return 0; }
    printf 'stale'
}

# _ai_tools_entrypoint_policy_active: succeed when there is an ai_tools_exec_t to assign, i.e.
#   SELinux is on, the labelling tools are present, and the ai_tools module is loaded. Where it
#   fails there is nothing to label and that is not an error -- the SELinux layer is optional.
_ai_tools_entrypoint_policy_active() {
    ai_tools_relabel_available || return 1
    command -v semanage >/dev/null 2>&1 || return 1
    command -v semodule  >/dev/null 2>&1 || return 1
    semodule -l 2>/dev/null | grep -qE '^ai_tools([[:space:]]|$)'
}

# Why the last file-context rule could not be registered -- semanage's own stderr, newlines
# collapsed to keep it on one line. Set by _ai_tools_fcontext for the caller that just called it,
# which appends it to the `skip` status line it prints. That is why the reason travels on STDOUT
# rather than in this variable alone: ai_tools_label_agent_paths runs inside a `$(...)` in
# ai-tools-relabel-agent, and a variable set in that subshell does not survive the substitution,
# while its report does.
AI_TOOLS_FCONTEXT_ERROR=""

# _ai_tools_fcontext <add|delete> <file-type> <selinux-type> <pattern>: register or drop the local
#   file-context rule mapping <pattern> to <selinux-type>, scoped by semanage's file-type letter
#   (`f` regular files, as the base policy's own `--` rules are scoped; `a` all types, for a
#   subtree). Some semanage versions refuse an `-a` for a pattern already registered and others
#   modify it in place, so an add falls back to `-m` and the call is idempotent either way.
_ai_tools_fcontext() {
    local action="$1" file_type="$2" selinux_type="$3" pattern="$4" add_error modify_error
    AI_TOOLS_FCONTEXT_ERROR=""
    if [[ "${action}" == delete ]]; then
        semanage fcontext -d -f "${file_type}" -- "${pattern}" >/dev/null 2>&1 || true
        return 0
    fi
    # stdout is dropped and stderr is KEPT. semanage announces "already defined, modifying
    # instead" on stdout, while this function's caller emits a PARSED report on that stream, so
    # anything written there is read as a verdict line. stderr carries the reason an add was
    # refused -- a policy store another semanage transaction holds, a type the loaded policy does
    # not define -- which reaches the operator through AI_TOOLS_FCONTEXT_ERROR.
    add_error="$(semanage fcontext -a -f "${file_type}" -t "${selinux_type}" -- "${pattern}" 2>&1 >/dev/null)" \
        && return 0
    modify_error="$(semanage fcontext -m -f "${file_type}" -t "${selinux_type}" -- "${pattern}" 2>&1 >/dev/null)" \
        && return 0
    # The add's message names the cause; the modify's usually reports the consequence ("not
    # defined"), so it is the fallback rather than the first choice. Newlines and carriage returns
    # are collapsed: the caller puts this on a status line its reader splits per line, so a
    # multi-line message would read as extra verdicts.
    AI_TOOLS_FCONTEXT_ERROR="${add_error:-${modify_error:-semanage gave no reason}}"
    AI_TOOLS_FCONTEXT_ERROR="${AI_TOOLS_FCONTEXT_ERROR//$'\n'/ }"
    AI_TOOLS_FCONTEXT_ERROR="${AI_TOOLS_FCONTEXT_ERROR//$'\r'/ }"
    return 1
}

# _ai_tools_agent_config_pattern <config-dir-name>: print the file-context pattern for an agent's
#   config directory and everything under it. Dots are escaped (a bare `.` in a regex matches any
#   character), and the name has already been validated as one component.
_ai_tools_agent_config_pattern() {
    printf '%s/%s(/.*)?' "${CP_HOME}" "${1//./\\.}"
}

# _ai_tools_entrypoint_paths <pattern>: print each installed file the pattern matches. find's
#   POSIX-extended `-regex` matches the whole path, the same anchoring SELinux gives a file-context
#   regex, so the set relabelled here is the set the rule governs -- no second pattern language.
#   The walk is rooted at the toolchain (never `/`) and runs on a relabel, not on a launch.
_ai_tools_entrypoint_paths() {
    find "${AI_TOOLS_ENTRYPOINT_ROOT}" -xdev -regextype posix-extended \
         -regex "$1" -type f 2>/dev/null
}

# ai_tools_agent_entrypoint_path <agent>: print the file <agent>'s stable launcher symlink resolves to
#   -- the inode execve transitions on, which is what makes the reconciliation below independent of
#   where a manifest says the executable lives. This is the SAME resolution ai-tools-run's preflight
#   and ai-tools-launcher-symlink's idempotency guard perform (`realpath -e` through the chain), so
#   the three cannot disagree about which file is the entrypoint. Runs as root, which can traverse
#   the 0750 toolchain the chain ends in.
#
#   Prints nothing and returns non-zero when the agent declares no usable launcher name, the link
#   does not resolve (the agent is not provisioned -- the ordinary pre-bootstrap state), or the
#   result is not reportable. The launcher name is allowlisted to one plain component before it
#   becomes a path, the same guard ai_tools_agent_manifest_field applies to an agent name, so a
#   manifest cannot address a link outside the control-plane bin directory.
ai_tools_agent_entrypoint_path() {
    local agent="$1" launcher resolved
    launcher="$(ai_tools_agent_manifest_field "${agent}" launcher || true)"
    [[ "${launcher}" =~ ^[A-Za-z0-9._-]+$ && "${launcher}" != *..* ]] || return 1
    resolved="$(realpath -e "${AI_TOOLS_LAUNCHER_DIR}/${launcher}" 2>/dev/null)" || return 1
    _ai_tools_entrypoint_path_reportable "${resolved}" || return 1
    printf '%s\n' "${resolved}"
}

# _ai_tools_verify_label <path> <wanted-type> : restore the label on <path> and report the
#   outcome as one status line (see ai_tools_label_agent_paths). Returns non-zero when the path
#   did not take the type.
_ai_tools_verify_label() {
    local path="$1" wanted="$2" context
    restorecon -F "${path}" 2>/dev/null || true
    context="$(stat -c '%C' -- "${path}" 2>/dev/null | awk -F: '{print $3}')"
    if [[ "${context}" == "${wanted}" ]]; then
        printf 'ok %s\n' "${path}"
        return 0
    fi
    printf 'bad %s %s %s\n' "${path}" "${context:-unknown}" "${wanted}"
    return 1
}

# _ai_tools_label_agent_entrypoint <agent> : the entrypoint half of the loop below. Applies the
#   declared rule, then RECONCILES it against the installed entrypoint. Emits status lines; returns
#   non-zero on a refusal, a path that did not take the type, or a declaration the installed
#   entrypoint has outgrown.
#
#   The declared pattern stays the mechanism that APPLIES the label, because a `semanage fcontext`
#   rule is what makes the type survive a later restorecon -- resolution alone would relabel an
#   inode nothing keeps labelled. Resolution is what CHECKS the result, so this helper's exit
#   status answers the question the operator actually asked: will the next launch be confined?
_ai_tools_label_agent_entrypoint() {
    local agent="$1" pattern path status=0 matched=no installed covered=no
    # Resolved BEFORE the rule is applied, so a refusal below still leaves the reconciliation
    # inputs gathered from the same state the launch preflight would see.
    installed="$(ai_tools_agent_entrypoint_path "${agent}" || true)"
    pattern="$(ai_tools_agent_manifest_field "${agent}" entrypoint_fcontext || true)"
    if [[ -z "${pattern}" ]]; then
        printf 'skip %s declares no entrypoint_fcontext\n' "${agent}"
        return 0
    fi
    if ! ai_tools_entrypoint_fcontext_valid "${pattern}"; then
        printf 'skip %s entrypoint_fcontext is not a plain path pattern under %s\n' \
            "${agent}" "${AI_TOOLS_ENTRYPOINT_ROOT}"
        return 1
    fi
    if ! _ai_tools_fcontext add f "${AI_TOOLS_ENTRYPOINT_TYPE}" "${pattern}"; then
        printf 'skip %s could not register its entrypoint file-context rule -- %s\n' \
            "${agent}" "${AI_TOOLS_FCONTEXT_ERROR}"
        return 1
    fi
    while IFS= read -r path; do
        matched=yes
        [[ "${path}" == "${installed}" ]] && covered=yes
        _ai_tools_verify_label "${path}" "${AI_TOOLS_ENTRYPOINT_TYPE}" || status=1
    done < <(_ai_tools_entrypoint_paths "${pattern}")

    case "$(ai_tools_entrypoint_reconcile_verdict "${installed}" "${covered}" "${matched}")" in
        none)  printf 'none %s its entrypoint\n' "${agent}" ;;
        stale) printf 'stale %s %s\n' "${agent}" "${installed}"; status=1 ;;
    esac
    return "${status}"
}

# _ai_tools_label_agent_config_dir <agent> : the config-directory half. Same shape; the subtree is
#   restored recursively, and only the directory itself is verified (its contents inherit).
_ai_tools_label_agent_config_dir() {
    local agent="$1" config_dir path pattern
    config_dir="$(ai_tools_agent_manifest_field "${agent}" config_dir || true)"
    if [[ -z "${config_dir}" ]]; then
        printf 'skip %s declares no config_dir\n' "${agent}"
        return 0
    fi
    if ! declare -F ai_tools_agent_config_dir_valid >/dev/null 2>&1 \
            || ! ai_tools_agent_config_dir_valid "${config_dir}"; then
        printf 'skip %s config_dir is not one plain component under %s\n' "${agent}" "${CP_HOME}"
        return 1
    fi
    pattern="$(_ai_tools_agent_config_pattern "${config_dir}")"
    if ! _ai_tools_fcontext add a "${AI_TOOLS_AGENT_CONFIG_TYPE}" "${pattern}"; then
        printf 'skip %s could not register its config-directory file-context rule -- %s\n' \
            "${agent}" "${AI_TOOLS_FCONTEXT_ERROR}"
        return 1
    fi
    path="${CP_HOME}/${config_dir}"
    if [[ ! -d "${path}" ]]; then
        printf 'none %s its config directory\n' "${agent}"
        return 0
    fi
    restorecon -FR "${path}" 2>/dev/null || true
    _ai_tools_verify_label "${path}" "${AI_TOOLS_AGENT_CONFIG_TYPE}"
}

# ai_tools_label_agent_paths: apply every ENABLED agent's declared file-context rules -- its
#   entrypoint and its config directory -- and restore the labels on what they match. Prints one
#   status line per outcome, for the caller to render in its own voice:
#     ok    <path>                     the path carries the type the base pins for it
#     bad   <path> <actual> <wanted>   it does not -- the session would break or run unconfined
#     none  <agent> <what>             declared, but not installed (yet)
#     stale <agent> <installed-path>   an entrypoint IS installed and the agent's declared rule
#                                      does not cover it, so no relabel can label it -- the
#                                      agent package's manifest has to be updated
#     skip  <agent> <reason...>        nothing to apply, or a declaration was refused
#   Returns 0 when every path it managed is correctly labelled, 1 when one is not, a rule could
#   not be registered, or a declaration is stale, and 2 when the SELinux layer is inactive
#   (nothing to do).
ai_tools_label_agent_paths() {
    _ai_tools_entrypoint_policy_active || return 2
    declare -F ai_tools_enabled_agents >/dev/null 2>&1 || return 2
    local agent status=0
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        _ai_tools_label_agent_entrypoint "${agent}" || status=1
        _ai_tools_label_agent_config_dir "${agent}" || status=1
    done < <(ai_tools_enabled_agents 2>/dev/null)
    return "${status}"
}

# ai_tools_unlabel_agent_paths <agent>: drop that agent's declared file-context rules and restore
#   default labels on what they matched -- the erase-time counterpart, so a removed agent package
#   leaves no rule behind for types its host may no longer define. Reads the manifest, so it runs
#   while that package's files are still present (rpm %preun). Returns 2 when the SELinux layer is
#   inactive, 1 when the agent declares nothing usable, 0 otherwise.
ai_tools_unlabel_agent_paths() {
    local agent="$1" pattern config_dir path dropped=1
    _ai_tools_entrypoint_policy_active || return 2
    declare -F ai_tools_agent_manifest_field >/dev/null 2>&1 || return 2

    pattern="$(ai_tools_agent_manifest_field "${agent}" entrypoint_fcontext || true)"
    if ai_tools_entrypoint_fcontext_valid "${pattern}"; then
        _ai_tools_fcontext delete f "${AI_TOOLS_ENTRYPOINT_TYPE}" "${pattern}"
        while IFS= read -r path; do
            restorecon -F "${path}" 2>/dev/null || true
        done < <(_ai_tools_entrypoint_paths "${pattern}")
        dropped=0
    fi

    config_dir="$(ai_tools_agent_manifest_field "${agent}" config_dir || true)"
    if declare -F ai_tools_agent_config_dir_valid >/dev/null 2>&1 \
            && ai_tools_agent_config_dir_valid "${config_dir}"; then
        _ai_tools_fcontext delete a "${AI_TOOLS_AGENT_CONFIG_TYPE}" \
            "$(_ai_tools_agent_config_pattern "${config_dir}")"
        # The directory itself is agent STATE and survives the package (like .nvm), so it is
        # relabelled to whatever the remaining policy maps it to rather than left on a type this
        # host may stop defining.
        path="${CP_HOME}/${config_dir}"
        [[ -d "${path}" ]] && restorecon -FR "${path}" 2>/dev/null
        dropped=0
    fi
    return "${dropped}"
}

# ai_tools_project_labelled <dir>: 0 if <dir>'s root currently carries
# ai_tools_project_t. A cheap, read-only state check for idempotent callers -- it
# inspects the live label, makes no policy change, and needs no privilege.
ai_tools_project_labelled() {
    local ctx
    ctx="$(ls -Zd "$1" 2>/dev/null | awk '{print $1}')" || return 1
    [[ "${ctx}" == *":${AI_TOOLS_PROJECT_TYPE}:"* ]]
}
