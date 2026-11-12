#!/usr/bin/bash -p
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-relabel
# Apply (or revert) the ai_tools_project_t SELinux label on ONE approved project directory, so the confined agent
# (ai_tools_t) can read and write it. This is the privileged half of project claiming: `semanage fcontext` needs root,
# which the unprivileged `ai-tools` CLI does not have, so `projects claim` (and `projects create` through it) invoke
# this via sudo to label, `projects unclaim` and `projects remove` invoke it with `--remove` to revert,
# and `projects list` prints the revert for a stale entry. There is NO sudoers NOPASSWD grant for it (by design): sudo
# prompts for the projects user's password, the same pattern as ai-tools-lockdown.
#
# The labelling body lives in the shared relabel.lib.sh (single source of truth, also used by the policy installer
# install-selinux.sh's registry sweep). This helper only validates the target and dispatches.
#
# Labelling a path requires an allow line for it in the operator's project registry and no `%` or `!` line naming it:
# only a project a session may start in carries the agent-accessible type. The gate reads the project root alone,
# and the label covers every path under it, an excluded or owner-only path included. Reverting (`--remove`) is lenient
# -- it cleans up a path that may already have been unregistered or deleted, and the walk only restores the system
# default context. A path `--remove` names that does not exist when the helper starts has its rules dropped with no
# walk; a name that stood there at the start and is gone by the walk fails the revert, since the tree it named was moved
# or deleted with its labels as they were.
#
# Runs as root via sudo, invoked by YOU (the projects user) -- not ai-tools:
#       ```bash
#       sudo ai-tools-relabel <dir>            # label <dir> ai_tools_project_t
#       sudo ai-tools-relabel --remove <dir>   # revert <dir> to its default type
#       ```
#
# Exits 0 on success, a label that left hardlinked paths at their type included; 5 where this host has no label to apply
# (SELinux disabled, or no ai_tools policy installed), named on stderr; 4 when a revert left hardlinked paths at their
# current type, the first 20 named with the count of the rest; 6 when the tree walker could not run, so no path was
# walked; 3 on a protected target; and 1 on every other refusal or failure, restorecon missing while SELinux is enabled
# and a tree moved or deleted during a revert among them. The CLI discards this helper's stdout, so every outcome it
# reads is on stderr.
#
# Installed 750 root:root, so only root runs it. Its domain rule is cli.rule.md.

set -euo pipefail

# The interpreter line and this PATH are the start every root helper shares (cli.rule.md, ref-section-g7c8).
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly RELABEL_LIB="/usr/local/lib/ai-tools/relabel.lib.sh"

# Owner resolution from /etc/ai-tools/operator.conf via the shared resolver. AI_TOOLS_OPERATOR_CONF / AI_TOOLS_ALLOWLIST
# override the paths -- root-only test hooks: sudo strips them (env_reset, not in env_keep), so neither the operator
# nor the agent can inject them in production (relabel is only ever reached as root via sudo).
#
# The owner is resolved PER PATH (ai_tools_operator__resolve_owner), the way every other per-project helper does it,
# rather than by loading one operator up front. On a multi-operator host the entry that authorizes a label lives
# in whichever operator's registry holds the project, and reading a single operator's file refuses every project
# registered to any of the others -- a secondary operator's own claim, and every `projects claim --for <op>`, would
# leave the tree unlabelled while the rest of the claim reported success. A load failure leaves the resolver undefined,
# which allowlisted() treats as "no owner" and refuses on: no label is granted from a half-parsed identity.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
source "${OPERATOR_LIB}" 2>/dev/null || true

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/relabel.log. Best-effort -- a no-op
# fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-relabel"
AI_TOOLS_LOG_FILE="relabel.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log__info() { :; }; ai_tools_log__warn() { :; }; ai_tools_log__error() { :; }
    ai_tools_log__structured() { :; }; ai_tools_log__coded() { :; }
fi

# A leading message code (msg.lib.sh states the form) is printed on its own line ahead of the message, the shape
# tests/lib/harness.sh's assert_msg reads, and carried into the log line. Matched inline: this helper does not load
# the library. Every outcome goes to stderr. err and notice print and log one line, the caller choosing the exit status
# after them; die exits 1.
emit_message() {
    local severity="$1" result="$2" code=""; shift 2
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; fi
    ai_tools_log__coded "${severity}" "${code}" "$*" "AI_TOOLS_RESULT=${result}"
    [[ -z "${code}" ]] || printf '%s\n' "${code}" >&2
    printf 'ai-tools-relabel: %s: %s\n' "${severity}" "$*" >&2
}
err()    { emit_message error failed "$@"; }
notice() { emit_message notice ok "$@"; }
die()    { emit_message error failed "$@"; exit 1; }

# Protected-paths backstop (safe-paths.lib.sh): refuse to relabel a system directory even when the allowlist includes
# it. See safe-paths.rule.md.
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/safe-paths.lib.sh
source "${SAFE_PATHS_LIB}"

# Shared allowlist grammar + membership predicate (conf.lib.sh): allowlisted() reads the file through the same parser
# as the launch wrapper and the CLI, so an entry written with an end-of-line comment or quotes is honored here too.
# Required, bare-sourced under `set -e`: a missing lib aborts the helper (no label granted -- fail closed), never
# a raw-line fallback that would silently refuse to (un)label a validly-listed project.
readonly CONF_LIB="/usr/local/lib/ai-tools/conf.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/conf.lib.sh
source "${CONF_LIB}"

[[ "${EUID}" -eq 0 ]] || die MSG-D6R4 "must run as root (via sudo)"

# allowlisted <dir>: 0 when <dir> is an exact, non-excluded entry in the allowlist of the operator who OWNS it. Reads
# through the shared grammar (conf.lib.sh), realpath-normalized, so a listed project with a comment or quotes --
# or reached by a symlink -- is recognized; an explicit `!<dir>` exclusion still wins, at both stages.
#
# Two stages, because they answer different questions: the resolver says WHICH operator's registry covers this path
# (honouring exclusions and covering subtrees, the same matcher the launch gate uses), and the exact-entry check then
# requires the path to be a registered project ROOT in that registry rather than something merely underneath one --
# a label is applied to a project, not to an arbitrary directory inside it.
allowlisted() {
    local dir="$1" file="${AI_TOOLS_ALLOWLIST:-}"
    if [[ -z "${file}" ]]; then
        declare -F ai_tools_operator__resolve_owner >/dev/null 2>&1 || return 1
        ai_tools_operator__resolve_owner "${dir}" >/dev/null 2>&1 || return 1
        file="${AI_TOOLS_OPERATOR__RESOLVED_ALLOWLIST:-}"
    fi
    [[ -n "${file}" && -f "${file}" ]] || return 1
    ai_tools_conf__has_allowlist_exclusion "${file}" "${dir}" && return 1   # explicit exclusion wins
    ai_tools_conf__has_allowlist_entry "${file}" "${dir}"
}

# ── Parse args ─────────────────────────────────────────────────────────────────
remove=false
target=""
for a in "$@"; do
    case "${a}" in
        --remove|-r) remove=true ;;
        -*)          die MSG-Y2P3 "unknown option: ${a} (allowed: --remove)" ;;
        *)           if [[ -z "${target}" ]]; then target="${a}"; else die MSG-F7T7 "takes a single path"; fi ;;
    esac
done
[[ -n "${target}" ]] || die MSG-A6G2 "usage: ai-tools-relabel [--remove] <dir>"

# A label needs the tree; a revert may name a tree a removal has deleted, whose rules are still to drop. Its path is
# resolved without requiring it, and held to the form of a canonical absolute path before the backstop reads it.
if ${remove}; then
    dir="$(realpath -m -- "${target}" 2>/dev/null)" || dir=""
    [[ "${dir}" == /* && "/${dir}/" != *"/./"* && "/${dir}/" != *"/../"* ]] || dir=""
else
    dir="$(realpath -e -- "${target}" 2>/dev/null)" || dir=""
fi
[[ -n "${dir}" ]] || die MSG-N3A5 "path not found: ${target}"
# Read once, ahead of the directory check, which reads this value: where the library does not find a tree to walk (its
# status 3), the tree was already gone if no name stood at <dir> here, and was moved or deleted during the revert if one
# did (report_revert_status). A name moved away between this read and the directory check fails that check.
root_present_at_start=false
[[ ! -e "${dir}" && ! -L "${dir}" ]] || root_present_at_start=true
[[ -d "${dir}" ]] || { ${remove} && ! ${root_present_at_start}; } || die MSG-S3E7 "not a directory: ${dir}"
# Refuse to (un)label a protected system directory.
ai_tools_safe_paths__assert_safe_target "${dir}" "relabel" || exit 3

# Every record past this point is about one project, so it rides as per-run log context (logging.rule.md) instead
# of being named at each site.
AI_TOOLS_LOG_PROJECT="${dir}"

# shellcheck source=SCRIPTDIR/../../lib/ai-tools/relabel.lib.sh
source "${RELABEL_LIB}" 2>/dev/null || die MSG-U2G7 "missing label library: ${RELABEL_LIB}"

# Serialize against the agent relabel (ai-tools-relabel-agent), which writes the same policy store: a claim can land
# while the ai-tools-relabel.path watcher is running one. Proceeding unserialized is reported, not fatal (see
# relabel.lib.sh).
ai_tools_relabel__lock
[[ -z "${AI_TOOLS_RELABEL__LOCK_NOTE}" ]] \
    || { echo "ai-tools-relabel: NOTE: relabels are not serialized on this host -- ${AI_TOOLS_RELABEL__LOCK_NOTE}"
         ai_tools_log__structured warning \
             "proceeding without the relabel lock -- ${AI_TOOLS_RELABEL__LOCK_NOTE}"; }

# exit_not_applicable <reason> : this host has no label to apply, which is not a fault; exits 5.
exit_not_applicable() {
    notice MSG-J5P7 "no SELinux label to apply on ${dir}: $1"
    exit 5
}
# SELinux disabled, read the way ai_tools_relabel__is_available reads it, and restorecon missing are two answers that
# function folds into one status; here the first is a host without a label to apply, and the second a broken toolchain.
[[ "$(getenforce 2>/dev/null)" != "Disabled" ]] || exit_not_applicable "SELinux is disabled on this host"
command -v restorecon >/dev/null 2>&1 \
    || die MSG-U9R2 "restorecon is not installed while SELinux is enabled -- install policycoreutils"
# A host whose ai_tools policy is neither live nor on disk is DAC-only by its own configuration, read through the one
# predicate the launch and the status reports read it by. Loaded best-effort: a reader that did not load proceeds
# to the label, which semanage then refuses with MSG-M2D2.
readonly CONFINEMENT_LIB="/usr/local/lib/ai-tools/confinement.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/confinement.lib.sh
source "${CONFINEMENT_LIB}" 2>/dev/null || true
if declare -F ai_tools_confinement__evaluate_dac_only_state >/dev/null 2>&1 \
        && declare -F ai_tools_confinement__read_module_present >/dev/null 2>&1 \
        && declare -F ai_tools_confinement__read_policy_shipped >/dev/null 2>&1 \
        && module_present="$(ai_tools_confinement__read_module_present \
                                 "${AI_TOOLS_CONFINEMENT__MODULE_PROBE_PATH}" 2>/dev/null)"; then
    policy_shipped="$(ai_tools_confinement__read_policy_shipped "${AI_TOOLS_CONFINEMENT__CORE_MODULE_FILE}")"
    if [[ "$(ai_tools_confinement__evaluate_dac_only_state "$(getenforce 2>/dev/null || true)" \
                 "${module_present}" "${policy_shipped}" || true)" == module-absent ]]; then
        exit_not_applicable "no ai_tools policy is installed on this host (install ai-tools-selinux)"
    fi
fi

# exit_walker_unavailable : the library's status 6 from a walk that could not start; exits 6.
exit_walker_unavailable() {
    err MSG-W9Y5 "the SELinux label on ${dir} was left as it was: the tree walker could not run -- ${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS:-no detail}; reinstall ai-tools-base, or install libselinux where the line names libselinux.so.1, then re-run"
    exit 6
}

# report_revert_status <status> : report ai_tools_relabel__unlabel_project's <status> for ${dir} and exit with this
#   helper's status for it. A 3 is a success only where root_present_at_start is false, the tree a removal already
#   deleted; where a name stood at <dir> at the start, the tree there was moved or deleted during the revert, and its
#   labels were not walked.
report_revert_status() {
    local quoted_dir
    case "$1" in
        0) echo "ai-tools-relabel: reverted ${dir} to its default SELinux type"
           ai_tools_log__structured info "unlabelled project ${dir}" "AI_TOOLS_RESULT=ok" ;;
        3) if ${root_present_at_start}; then
               die MSG-M2A2 "the tree at ${dir} was moved or deleted during the revert -- its SELinux rules are dropped, and its labels are left as they were"
           fi
           echo "ai-tools-relabel: dropped the SELinux rules of ${dir}; no tree stands there to revert"
           ai_tools_log__structured info "dropped the rules of absent project ${dir}" "AI_TOOLS_RESULT=ok" ;;
        # A hardlinked path keeps its current type: through its other name it may be another tree's, so the walk does
        # not write it, and a path left on a type the agent reads and writes is more access, so the exit is a failure.
        4) quoted_dir="$(printf '%q' "${dir}")"
           err MSG-D2T9 "reverted ${dir} to its default SELinux type except these hardlinked paths, which keep their current type: ${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS}; list the hardlinked files the tree holds now with: find ${quoted_dir} -not -type d -links +1"
           exit 4 ;;
        6) exit_walker_unavailable ;;
        *) die MSG-Q4X9 "failed to revert SELinux label on ${dir}${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS:+ -- ${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS}}" ;;
    esac
    exit 0
}

# report_label_status <status> : report ai_tools_relabel__label_project's <status> for ${dir} and exit with this
#   helper's status for it. A failure carries the library's diagnostic where it set one -- the walk's first failed path
#   and its error, or a root no rule matched -- and the policy remedy where it did not, which is a rule semanage
#   refused.
report_label_status() {
    local skipped_hardlink_count
    case "$1" in
        0) echo "ai-tools-relabel: labelled ${dir} ai_tools_project_t"
           ai_tools_log__structured info "labelled project ${dir} ai_tools_project_t" \
               "AI_TOOLS_RESULT=ok" ;;
        2) exit_not_applicable "SELinux is not active on this host" ;;
        # Through another name a hardlinked path may be another tree's, so the walk does not write it.
        4) printf 'ai-tools-relabel: %s\n' "${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS}" >&2
           skipped_hardlink_count="$(ai_tools_relabel__get_skipped_hardlink_count)"
           notice MSG-R5F8 "labelled ${dir} ai_tools_project_t; ${skipped_hardlink_count} hardlinked path(s) kept their current type; the lines above name up to 20 of them" ;;
        6) exit_walker_unavailable ;;
        *) if [[ -n "${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS}" ]]; then
               die MSG-F8F6 "failed to label ${dir} -- ${AI_TOOLS_RELABEL__TREE_DIAGNOSTICS}"
           fi
           die MSG-M2D2 "failed to label ${dir} (is the ai_tools policy module loaded? install ai-tools-selinux, or from a checkout run: sudo selinux/install-selinux.sh install)" ;;
    esac
    exit 0
}

if ${remove}; then
    rc=0; ai_tools_relabel__unlabel_project "${dir}" || rc=$?
    report_revert_status "${rc}"
else
    allowlisted "${dir}" \
        || die MSG-P8J7 "refusing to label ${dir}: not an enabled project in the operator's project registry"
    rc=0; ai_tools_relabel__label_project "${dir}" || rc=$?
    report_label_status "${rc}"
fi
