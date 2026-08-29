#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/bin/ai-tools
# Project-lifecycle CLI for the ai-tools Claude Code sandbox. Runs AS the invoking operator (not
# as root, not as the sandbox account). It writes the operator-owned allowlist
# (~/.config/ai-tools/allowed-projects) directly, and reaches the root-owned bits
# -- the git safe.directory list in /opt/ai-tools/.gitconfig, the SELinux label, the ACL, and
# secret lockdown -- through the sudo root helpers (no NOPASSWD: the operator is prompted for a
# password; the sandbox account holds no grant).
#
# Four preflight gates run before dispatch: require_bootstrap (provisioned install); for the
# operator-acting commands (--project-*/--sandbox-*/--lockdown/--reclaim/--relabel),
# require_operator -- the invoking user must be in OPERATORS in operator.conf, since the root
# helpers resolve the caller's identity from that list; require_sudo_access, which refuses a verb
# whose root helper this caller holds no sudo grant for, before sudo prompts for a password it
# will then reject; and require_for_target, which validates a --for run and re-points the registry
# at its target. --help/--version/--list/--providers stay open to any user.
#
# The principal guard above them refuses the sandbox account outright and allows root only the
# verbs that write no operator state (ROOT_ALLOWED_VERBS): the four reports, --audit needing root
# by construction since the trail it reads is 700 root:root, plus --stop, whose helper requires
# root anyway.
#
# --for <operator> performs a command ON BEHALF OF another enrolled operator: the allowlist entry
# lands in THEIR registry, so ai-tools-setfacl grants user:<them>, the handback restores to them,
# and their agent's launch gate covers the path. It exists for a service account that runs an
# agent but holds no password to authenticate a claim of its own. The target's registry is
# unreadable to the invoker (0600 in a 0700 directory), so a --for run reads a root-side snapshot
# of it and routes its writes through ai-tools-allowlist.
#
# Commands (each confirms before applying and reports the result):
#   --project-claim   [path]  claim a project in place -- grant the agent access (idempotent;
#                             default: cwd); -y/--yes pre-answers its proceed prompt (delegated)
#   --project-create  <path>  create a NEW project directory (one mkdir, git init, README.md)
#                             and claim it; refuses a path that already exists and one whose
#                             parent does not, and takes no cwd default -- the cwd always exists
#   --project-unclaim [path]  release a project -- revoke the agent's access and hand the tree
#                             back to your own group (or a named user's), the agent's write
#                             removed; the directory is left on disk
#   --project-remove  [path]  alias for --project-unclaim (kept for back-compat)
#   --sandbox-create [path]   shallow-clone a repo into the sandbox area (private,
#                             umask 077), lock down tip-commit secrets, then grant
#                             the agent access and register -- fail-closed: an
#                             unsecured clone stays private and unregistered; run
#                             again on the clone path to resume securing it
#   --sandbox-push   [path]   push the sandbox clone's commits to its branch
#   --sandbox-remove [path]   remove a sandbox clone and unregister it
#   --lockdown [path]         lock down secret-named files under the project (sudo)
#   --reclaim [--full] [path] take back ownership of agent-written files -- the project stays
#                             claimed and the agent keeps access; the on-demand ownership
#                             handback, e.g. before an ACL-unaware backup (sudo; default: cwd)
#   --relabel                 reconcile the enabled agents' entrypoints -- verify each against its
#                             vendor's signed release checksum and pin it, then relabel (sudo)
#   --providers               report the installed agents/integrations, which are enabled,
#                             and why (read-only; resolved through providers.lib.sh)
#   --status                  report ai-tools service health (read-only; services.lib.sh)
#   --list                    list registered projects (real vs sandbox)
#   --version                 print the installed ai-tools version
#   --help
#
# Sandbox model: the agent works in a shallow clone under SANDBOX_ROOT so it never
# reads the original repo's full git history. Work is pushed to a per-repo branch
# ai-tools/sandbox-<user>/<leaf> (default leaf: main). Only the projects user can
# push -- the sandbox account has no git credentials. Anyone with repo access then
# merges that branch back, preserving the agent's commits granularly. See
# /var/opt/ai-tools/README.md.
#
# Deploy: install -o root -g root -m 755 src/usr/local/bin/ai-tools.sh \
#         /usr/local/bin/ai-tools

set -euo pipefail
IFS=$'\n\t'

readonly SANDBOX_USER="@SANDBOX_USER@"
readonly SANDBOX_GROUP="@SANDBOX_GROUP@"
# Substituted at deploy time (install.sh from packaging/VERSION; the RPM from %{version});
# a raw source-tree run reports "dev".
AI_TOOLS_VERSION="@AI_TOOLS_VERSION@"
[[ "${AI_TOOLS_VERSION}" == @*@ ]] && AI_TOOLS_VERSION="dev"
readonly AI_TOOLS_VERSION
# AI_TOOLS_GITCONFIG / AI_TOOLS_ALLOWLIST (below): root-only test hooks, the same family the
# root helpers carry (see tests.rule.md). The CLI runs as the operator, who owns both files
# anyway, so an override widens nothing it could not already do by editing them directly; sudo
# strips both (env_reset, not env_keep) before any root helper, which re-resolves the real paths
# itself, and the sandbox account is refused by the principal guard below before either is read.
readonly GITCONFIG="${AI_TOOLS_GITCONFIG:-/opt/ai-tools/.gitconfig}"
readonly SANDBOX_ROOT="/var/opt/ai-tools/sandbox-projects"
# Bootstrap's last load-bearing artifact -- the require_bootstrap gate keys on it (below).
# Same symlink the launch wrapper resolves; kept identical to claude.sh's CLAUDE_LINK.
readonly CLAUDE_LINK="/opt/ai-tools/bin/claude"
# Root-only secret lockdown helper. Invoked via sudo (NO NOPASSWD grant exists for
# it -- by design), so sudo prompts for the projects user's password.
readonly LOCKDOWN_BIN="/usr/local/libexec/ai-tools/ai-tools-lockdown"
# Root-only SELinux project-label helper, same sudo (no NOPASSWD) model as lockdown.
# Applies/reverts ai_tools_project_t so the confined agent can access a claimed,
# in-place tree; the per-project semanage fcontext rule it adds needs root, which
# this unprivileged CLI lacks. Sandbox clones do NOT use it (static rule + plain
# restorecon -- see relabel_clone).
readonly RELABEL_BIN="/usr/local/libexec/ai-tools/ai-tools-relabel"
# Root-only ACL helper, same sudo (no NOPASSWD) model as lockdown/relabel. Applies the
# project's group-permission ACL (default + access group:SANDBOX_GROUP:rwX, other denied)
# so files the projects user's git checkout/merge writes under a restrictive umask stay
# group-accessible to the agent. Needs root (CAP_FOWNER) to ACL files the projects user
# does not own; this unprivileged CLI lacks that.
readonly SETFACL_BIN="/usr/local/libexec/ai-tools/ai-tools-setfacl"
# Root-only setgid helper, same sudo (no NOPASSWD) model. Sets group SANDBOX_GROUP + the setgid
# bit on a claimed project's directories. The operator is not a SANDBOX_GROUP member
# (multi-operator), so the group change needs root; the helper carries its own allowlist + owner
# guard. Also invoked by the handback daemon for the SessionStart normalization pass.
readonly SETGID_BIN="/usr/local/libexec/ai-tools/ai-tools-setgid"
# Root-only unclaim helper, same sudo (no NOPASSWD) model. Reverses the filesystem side
# of a claim: clears the agent ACL + default ACL, regroups the tree to a target group, and
# removes group write. Needs root to chgrp to an arbitrary group and to act on files the
# projects user does not own.
readonly UNCLAIM_BIN="/usr/local/libexec/ai-tools/ai-tools-unclaim"
# Root-only entrypoint-relabel helper, same sudo (no NOPASSWD) model. Restores
# ai_tools_exec_t on the claude.exe entrypoint(s) after a Node auto-upgrade leaves them
# mislabelled; needs root (the projects user runs as unconfined_t, which can relabel, but
# only via sudo as the helper is 750 root:root). --relabel is the one caller that goes through
# sudo; the ai-tools-relabel.path watcher, ai-tools-bootstrap, and the agent package's %post all
# reach the same helper as root.
readonly RELABEL_ENTRYPOINT_BIN="/usr/local/libexec/ai-tools/ai-tools-relabel-agent"
# Root-only git safe.directory helper, same sudo (no NOPASSWD) model as lockdown/relabel/
# setfacl/unclaim. /opt/ai-tools/.gitconfig is root-owned 644: world-readable (the agent reads
# safe.directory on startup) but root-write-only, so neither the operator nor the agent writes it
# directly -- the operator reaches the validated add/--remove through this helper.
readonly SAFEDIR_BIN="/usr/local/libexec/ai-tools/ai-tools-safedir"
# Root-only ownership-reclaim helper, same sudo (no NOPASSWD) model. Hands agent-written files
# under a project back to the operator via ai-tools-chown (the per-path trust boundary), needed for
# the .git tree the per-session sweeps skip; useful before an ACL-unaware backup.
readonly RECLAIM_BIN="/usr/local/libexec/ai-tools/ai-tools-reclaim"
# Root-only cross-operator allowlist helper, same sudo (no NOPASSWD) model. Reads and edits ANOTHER
# enrolled operator's allowed-projects for a --for run; root is needed for the READ too, since an
# allowlist is 0600 inside a 0700 .config/ai-tools. Only a --for run reaches it -- without the flag
# the CLI writes the invoker's own registry directly, as before.
readonly ALLOWLIST_BIN="/usr/local/libexec/ai-tools/ai-tools-allowlist"

# Reader for the refusal/rejection trails (--audit). Root-only, since the trail it reads is
# 700 root:root; no NOPASSWD rule, so sudo prompts like the other per-project helpers.
readonly AUDIT_BIN="/usr/local/libexec/ai-tools/ai-tools-audit"
# Session-stop helper (--stop). Root-only, since a session is a transient unit in the sandbox
# account's own `systemd --user` manager, which no operator can reach; no NOPASSWD rule, so sudo
# prompts like the other root helpers. What it accepts, and why so little: cmd_stop.
readonly STOP_BIN="/usr/local/libexec/ai-tools/ai-tools-stop"
# Sentinel in a guard CLAUDE.md (see drop_lockdown_guard) so the lockdown step can
# recognise and remove its own placeholder once secrets are secured.
readonly GUARD_MARKER="ai-tools-lockdown-guard"

# ── Verb sets ────────────────────────────────────────────────────────────────────
# Two sets of verbs are tested in more than one place. Each is named ONCE here, so a verb added
# to a set cannot be added to one of its readers and missed by another.
#
# ROOT_ALLOWED_VERBS -- what root may run. The criterion is WRITES NO OPERATOR-OWNED STATE, which
# is what the root guard exists to protect: a registry written by root names an owner whose own
# launch gate cannot read it. A verb qualifies on what it writes rather than on what it reads, so
# --stop belongs here despite being the one member that ACTS: it writes no registry, and root is
# the identity an unattended detector usually runs as -- the caller this rung most has to serve.
# Admitting it grants nothing new either, since root can already run ai-tools-stop directly and
# can signal any process on the host; what it removes is a CLI that refused the one principal its
# own helper requires. Read by the principal guard below, by that guard's own refusal (which lists
# them), and by ai-tools(1).
readonly ROOT_ALLOWED_VERBS=(--audit --status --list --providers --stop)
# BOOTSTRAP_EXEMPT_VERBS -- what runs on an unprovisioned host. Deliberately NOT the set above:
# each of these is meant for a host that may be broken (--status reports the unprovisioned state
# itself; --audit reads a historical trail, which an install that never finished does not
# invalidate; --stop ends sessions already running, and needs nothing from the toolchain to do it
# -- the gate keys on ONE agent's launcher symlink, so leaving --stop behind it would put the
# incident ladder's last rung out of reach on a host that enables a different agent, or that lost
# that symlink while sessions were running). --list and --providers describe a toolchain that has
# to exist first and stay behind the gate.
readonly BOOTSTRAP_EXEMPT_VERBS=(--status --audit --stop)

# verb_in <verb> <name>... -- true when <verb> is one of the named verbs.
verb_in() {
    local verb="$1"; shift
    local name; for name in "$@"; do [[ "${verb}" == "${name}" ]] && return 0; done
    return 1
}
# join_words <word>... -- the words joined by single spaces, for a message. Pins IFS locally: the
# CLI runs under IFS=$'\n\t', so a bare "${array[*]}" would join on a NEWLINE.
join_words() { local IFS=' '; printf '%s' "$*"; }

# ── Invoker guards ───────────────────────────────────────────────────────────────
# This is a user tool. It must run as the projects user, and never as the sandbox account --
# the agent must not manage its own allowlist. That refusal is unconditional and first: no
# verb, and no argument, makes the agent a legitimate caller.
#
# Root is refused for every verb that WRITES (it would write the operator registries owned by
# root, where the operator's own launch gate cannot read them) and allowed for the four that
# only read. That split is decided below, once the verb is known -- see "Root and the read-only
# reports".
INVOKING_USER="$(id -un)"
[[ "${INVOKING_USER}" == "${SANDBOX_USER}" ]] \
    && { echo "ai-tools: refusing to run as the sandbox account ${SANDBOX_USER}" >&2; exit 1; }

HOME_DIR="$(getent passwd "${INVOKING_USER}" | cut -d: -f6)"
[[ -d "${HOME_DIR}" ]] || { echo "ai-tools: cannot resolve home for ${INVOKING_USER}" >&2; exit 1; }
readonly INVOKING_USER HOME_DIR

# ── --for <operator>: act on another enrolled operator's project registry ────────
# A service account that runs an agent has no password, so it cannot authenticate the claim's own
# root helpers -- and a project claimed by a human lands in the HUMAN's registry, which is not the
# one that account's launch gate reads. --for closes both: a human operator performs the claim ON
# BEHALF OF the target, whose allowlist then covers the path, so ai-tools-setfacl grants
# user:<target>, the handback restores to <target>, and that account's own launch finds the project
# already claimed and never reaches a password prompt.
#
# The flag is separated from the command's own arguments HERE, before the registry path below is
# resolved and before dispatch, so every command reads one already-decided owner instead of each
# parsing the flag itself. Validation (is the target enrolled, does this verb accept --for) needs
# conf.lib.sh and runs at the dispatch gate.
FOR_OPERATOR=""
_forless_args=()
while (( $# )); do
    case "$1" in
        --for)   [[ -n "${2:-}" && "${2:-}" != -* ]] \
                     || { echo "ai-tools: --for needs an operator name" >&2; exit 1; }
                 FOR_OPERATOR="$2"; shift 2 ;;
        --for=*) FOR_OPERATOR="${1#--for=}"
                 [[ -n "${FOR_OPERATOR}" ]] \
                     || { echo "ai-tools: --for needs an operator name" >&2; exit 1; }
                 shift ;;
        *)       _forless_args+=("$1"); shift ;;
    esac
done
set -- "${_forless_args[@]}"
unset _forless_args

# ── Root and the verbs that write no operator state ──────────────────────────────
# Root may run the verbs that write no registry -- the four reports, plus --stop -- and no other.
# --audit is why the carve-out exists: the trail it reads is 700 root:root, so the verb needs root
# by construction, and a blanket refusal left it unreachable from BOTH sides on a host whose only
# operator holds no general sudo grant. --stop is here for the mirror of that reason: its helper
# requires root, and an incident response running as root should reach the rung through the same
# command an operator uses. The mutating verbs keep refusing root for the reason this
# guard has always existed -- they would write the operator registries owned by root, where that
# operator's own launch gate cannot read them.
#
# The check runs HERE, after --for is separated out, for two reasons. Before that point $1 is not
# reliably the verb (`ai-tools --for op --list` leads with the flag). And running it here refuses
# --for for root in EITHER argument order: root is not in OPERATORS, so a --for run performed by
# root would write an entry that names an owner no ownership helper can resolve. require_operator
# does not cover that on its own -- it gates the mutating verbs, and --list is not one of them.
#
# Plain echo, not die(): this runs before msg.lib.sh is sourced, like the sandbox refusal above.
root_may_run() {
    [[ -z "${FOR_OPERATOR}" ]] || return 1
    verb_in "$1" "${ROOT_ALLOWED_VERBS[@]}"
}
if [[ "${INVOKING_USER}" == "root" ]] && ! root_may_run "${1:-}"; then
    echo "ai-tools: do not run as root -- run as the projects user, without sudo" >&2
    echo "          (the CLI invokes sudo itself for the steps that need it)" >&2
    echo "          as root you can run the verbs that write no operator state:" \
         "$(join_words "${ROOT_ALLOWED_VERBS[@]}")" >&2
    exit 1
fi

# The operator this run acts FOR: the --for target, or the invoker. Every message that names the
# owner a file ends up with, and every scan that matches on that owner, reads these rather than
# INVOKING_USER -- on a --for run the tree belongs to the target, so naming the invoker would
# misreport who ends up holding the files. What a root helper's walk treats as "the operator" is
# still resolved per
# path from the path's own allowlist coverage, never from either of these.
OWNER_USER="${FOR_OPERATOR:-${INVOKING_USER}}"
# Without --for the owner is the invoker, whose group always resolves. With --for the group is
# resolved by require_for_target only AFTER the target is confirmed enrolled: a name that is
# neither an operator nor a user on this host has to be refused with the actionable "not a
# configured ai-tools operator -- enrol it with ..." message, not with a getent failure that names
# the wrong problem.
OWNER_GROUP=""
if [[ -z "${FOR_OPERATOR}" ]]; then
    OWNER_GROUP="$(id -gn "${OWNER_USER}" 2>/dev/null)" \
        || { echo "ai-tools: cannot resolve the primary group of ${OWNER_USER}" >&2; exit 1; }
fi
readonly FOR_OPERATOR OWNER_USER

# The registry this run reads and writes. Without --for it is the invoker's own file, read and
# written directly. With --for, require_for_target re-points it at a root-side SNAPSHOT of the
# target's file: an allowlist is 0600 inside a 0700 .config/ai-tools, so one operator cannot read
# another's at all, and every decision made from it (is the path listed, which '!' exclusions
# apply, what --list reports) would otherwise read an unreadable file as an empty one. One
# resolution point for readers AND writers (reg_allow/unreg_allow), so a fixture test that sets
# AI_TOOLS_ALLOWLIST never mutates the operator's real registry. Root-only test hook -- see the
# GITCONFIG note above for why the override grants the CLI's operator caller nothing new.
ALLOWLIST="${AI_TOOLS_ALLOWLIST:-${HOME_DIR}/.config/ai-tools/allowed-projects}"

# ── Output / prompt helpers ──────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    readonly C_BOLD=$'\033[1m' C_DIM=$'\033[2m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_RED=$'\033[31m' C_RST=$'\033[0m'
else
    readonly C_BOLD='' C_DIM='' C_GRN='' C_YEL='' C_RED='' C_RST=''
fi

# Each takes ONE line and prints it. "$1", not "$*": this CLI runs under IFS=$'\n\t', so "$*"
# would join a second argument on a NEWLINE rather than a space -- a silently mis-rendered message
# for a caller that reasonably expects printf-style words.
say()     { printf '%s\n' "$1"; }
section() { printf '\n%s%s%s\n' "${C_BOLD}" "$1" "${C_RST}"; }
ok()      { printf '  %s✓%s %s\n' "${C_GRN}" "${C_RST}" "$1"; }
warn()    { ai_tools_msg_warn "$@"; }
die()     { ai_tools_log_error "$*"; ai_tools_msg_error "ai-tools: $*"; exit 1; }
# The claim/sandbox flows are sequences of SELF-CONTAINED blocks, each opened by a wide
# headline box (title + summary prose), with details, prompts, and results printed plain
# below it and a closing ✓ (or a fail-closed error) ending the block -- see
# messaging.rule.md. headline() narrates to stdout; headline_warn() carries a
# "WARNING: ..."-titled block on stderr.
headline()      { ai_tools_msg_headline "$1" 1 "${@:2}"; }
headline_warn() { ai_tools_msg_headline "$1" 2 "${@:2}"; }

# Shared leveled logger -- journald only (this CLI runs as the projects user, not root,
# so it cannot write the root-only /var/log/ai-tools files). Records workflow
# milestones (project/sandbox created, pushed, removed, locked down) at INFO under the
# tag "ai-tools". Best-effort no-op fallback if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# Shared message formatter -- die()/warn() above frame their text in the paste-safe
# '#' alert box (50 columns) and headline()/headline_warn() open the wide (80-column)
# flow blocks on a terminal, plain text otherwise, and
# ai_tools_msg_confirm carries every yes/no prompt. REQUIRED, like safe-paths.lib.sh
# below: the confirms gate real decisions, so a missing lib fails closed instead of
# running through a private fallback (see messaging.rule.md).
readonly MSG_LIB="/usr/local/lib/ai-tools/msg.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/msg.lib.sh
if ! source "${MSG_LIB}" 2>/dev/null; then
    command -v logger >/dev/null 2>&1 \
        && logger -t ai-tools -p user.err \
            "required library ${MSG_LIB} unavailable -- ai-tools refused (fail closed)"
    printf 'ai-tools: cannot load required library %s\n' "${MSG_LIB}" >&2
    printf '  the install is incomplete or /usr/local/lib/ai-tools is not traversable;\n' >&2
    printf '  refusing (fail closed) -- reinstall the ai-tools package, then retry.\n' >&2
    exit 3
fi
# One fixed 80-column frame for every box this CLI shows: a claim/reclaim run emits a
# SEQUENCE of boxes, which aligns instead of each sizing to its own text.
export AI_TOOLS_MSG_FULLWIDTH=1

# Protected-paths backstop (safe-paths.lib.sh): refuse to claim a system directory, and vet
# ancestors for the reachability grant (reg_reach -> grantable_ancestor). It is REQUIRED:
# FAIL CLOSED if it cannot be sourced (missing, unreadable, or the lib dir is not traversable)
# or does not define its guard. A broken install is not a state to run through with the guard
# disabled -- a stubbed no-op would skip the system-dir refusal AND silently never grant
# ancestor traversal (a claimed project the agent cannot reach). Log to journald (via logger,
# independent of log.lib which may share the broken dir) and warn the user, then exit.
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/safe-paths.lib.sh
if ! source "${SAFE_PATHS_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_assert_safe_target  >/dev/null 2>&1 \
        || ! declare -F ai_tools_protected_path_match >/dev/null 2>&1; then
    command -v logger >/dev/null 2>&1 \
        && logger -t ai-tools -p user.err \
            "required safety library ${SAFE_PATHS_LIB} unavailable -- ai-tools refused (fail closed)"
    ai_tools_msg_error "ai-tools: cannot load required safety library ${SAFE_PATHS_LIB}" \
        "the install is incomplete or /usr/local/lib/ai-tools is not traversable (expected 0751);" \
        "refusing (fail closed) -- reinstall the ai-tools package, then retry."
    exit 3
fi

# The shared config grammar, which this CLI reads allowed-projects with (ai_tools_conf_path_entry)
# so its project listing and the launch wrapper's gate agree on what every line denotes. REQUIRED:
# a private fallback parser is exactly the drift the shared grammar exists to prevent, and a CLI
# that lists a different set of projects than the wrapper will launch in is worse than one that
# refuses.
readonly CONF_LIB="/usr/local/lib/ai-tools/conf.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/conf.lib.sh
if ! source "${CONF_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_conf_path_entry >/dev/null 2>&1; then
    ai_tools_msg_error "ai-tools: cannot load required config library ${CONF_LIB}" \
        "the install is incomplete or /usr/local/lib/ai-tools is not traversable (expected 0751);" \
        "refusing (fail closed) -- reinstall the ai-tools package, then retry."
    exit 3
fi

# Skip-dir selector (the single skip source shared with the sweeps and the claim helpers).
# The claim drift scan uses it to tell repairable hits from skip-listed ones. Fail-soft: a
# missing lib classifies nothing as skip-listed -- a noisier report, never a wrong repair
# (the root helpers load their own copy for the walks).
readonly SKIP_DIRS_LIB="/usr/local/lib/ai-tools/skip-dirs.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/skip-dirs.lib.sh
source "${SKIP_DIRS_LIB}" 2>/dev/null \
    || ai_tools_skip_find_expr() { AI_TOOLS_SKIP_NAMES=(); AI_TOOLS_SKIP_FIND_EXPR=(); return 0; }

# Service-health registry (services.lib.sh): the single source `ai-tools --status` and the launch
# wrapper's pre-launch health warning share, so the two never disagree on which units matter or how
# to fix one. Best-effort -- only --status reads it, and it degrades to a "registry unavailable"
# notice rather than failing any command.
readonly SERVICES_LIB="/usr/local/lib/ai-tools/services.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/services.lib.sh
source "${SERVICES_LIB}" 2>/dev/null || true

# ── Reaching a root helper ───────────────────────────────────────────────────────
# Most verbs do work only root can do, through a helper in /usr/local/libexec/ai-tools (750
# root:root -- the operator cannot even stat one). Two facts about the caller decide HOW, and
# WHETHER, that helper is reached; both are answered here rather than at each call site.
#
# ALREADY ROOT -- run the helper directly, with no sudo in between. Root reaches only the
# read-only verbs (see the principal guard above), so today that is --audit alone. The condition
# lives here rather than inside cmd_audit so a read-only verb added later inherits it.
#
# NO SUDO GRANT -- refuse before sudo prompts. Every helper outside the %ai-ops NOPASSWD rules
# (the shipped sudoers drop-in holds their list) is reached by a plain
# sudo, which assumes the operator ALSO holds a general grant. An ai-ops-only account does not --
# and sudo authenticates BEFORE it refuses, so such an operator is asked for a password and turned
# away after supplying it, for a decision that was knowable without asking. require_sudo_access
# answers it up front instead, and probes with -n so the probe itself never prompts.
#
# THE PROBE IS NOT A SECURITY GATE and is deliberately fail-OPEN, against the project's usual
# direction. sudo remains the thing that decides; this only replaces a refusal that was going to
# happen anyway with one that says what to do instead. So an inconclusive probe falls through to
# the call site and lets sudo answer, because the failure it would otherwise cause is the serious
# one: refusing an operator who does hold a grant, on the strength of a message we did not parse.

# run_root_helper <bin> [args...] -- run a root helper, directly when the caller is already root
# and through sudo otherwise. The helper's exit status propagates either way (--audit and --stop
# both publish theirs as their own contract).
run_root_helper() {
    if [[ "${INVOKING_USER}" == "root" ]]; then "$@"; else sudo "$@"; fi
}

# root_helper_reachable -- false only when no root helper can be reached at all: not root, and no
# sudo binary. Call sites that fall back to "run as root: <helper>" gate on this rather than on a
# bare `command -v sudo`, which reads as missing to root as well.
root_helper_reachable() { [[ "${INVOKING_USER}" == "root" ]] || command -v sudo >/dev/null 2>&1; }

# sudo_grant_missing <bin> -- true only when sudo will refuse <bin> for this caller OUTRIGHT,
# without a password ever being able to help.
#
# `sudo -n -l <bin>` asks sudo the question directly and, with -n, cannot prompt. Four answers,
# and the second is the one this reads:
#
#   exit 0                       the rule exists; sudo echoes the command it would run. This is
#                                what a general-grant operator gets whether or not a credential is
#                                cached -- LISTING an allowed command is not itself password-gated
#                                on a stock sudoers.
#   exit != 0, NO OUTPUT         sudo's answer for "no rule matches this command". It is silent,
#                                so there is no message to match on: the refusal that reaches the
#                                terminal ("Sorry, user op is not allowed to execute ...") comes
#                                from the attempt to RUN the command, never from -l. This is the
#                                ai-ops-only account the gate exists for.
#   exit != 0, "password is required"   listing is password-gated here (sudoers `listpw`). The
#                                grant may well exist, so that caller is left to the ordinary
#                                prompt.
#   exit != 0, any other text    not understood -- fall through and let sudo answer at the call
#                                site, the fail-open direction described above.
#
# Silence is only conclusive while sudo is answering at all, so it is confirmed against a bare
# `sudo -n -l`: that lists the caller's whole rule set (an ai-ops member always has one), and its
# success is what separates "sudo knows this caller and has no rule for that command" from a sudo
# that failed for its own reasons -- an unreachable sudoers backend, a host that refuses -l
# outright. Only the first is read as a missing grant; the second falls open like any other
# answer that cannot be read. LC_ALL=C pins the wording of the one text match.
# An optional <runas> asks the same question about `sudo -u <runas> <bin>` -- the form run_as_owner
# uses -- so a host whose sudoers restricts Runas to root is read here rather than at the call site,
# where it would abort a create half-way through a tree.
sudo_grant_missing() {
    local bin="$1" runas="${2:-}" answer
    local -a probe=(-n -l)
    [[ -n "${runas}" ]] && probe+=(-u "${runas}")
    [[ "${INVOKING_USER}" == "root" ]] && return 1
    command -v sudo >/dev/null 2>&1 || return 1
    answer="$(LC_ALL=C sudo "${probe[@]}" "${bin}" 2>&1)" && return 1
    [[ "${answer}" == *"password is required"* ]] && return 1
    if [[ -z "${answer//[[:space:]]/}" ]]; then
        LC_ALL=C sudo -n -l >/dev/null 2>&1 && return 0
        return 1
    fi
    [[ "${answer}" == *"not allowed to execute"* || "${answer}" == *"may not run sudo"* ]]
}

# confirm <prompt> <y|n>  -- the shared yes/no prompt (ai_tools_msg_confirm; see
# msg.lib.sh): the explicit default decides the Enter answer and the no-tty answer, so
# each caller states the default whose unattended answer is the safe outcome for its
# question. AI_TOOLS_ASSUME_YES=1 fast-tracks only default-YES prompts (the lib's rule);
# a default-NO prompt is answered ahead of time only by the CLI's own --yes flag -- the
# launch wrapper passes it for a delegated --project-claim after taking its own
# confirmation, so the claim's proceed prompt does not ask a second time.
# have_tty: true only when a controlling terminal can actually be opened. `[[ -r /dev/tty ]]`
# tests the node's permission bits (crw-rw-rw-), not openability, so it reads true even with no
# controlling terminal (e.g. a systemd unit or under setsid); opening /dev/tty is the only honest
# probe -- with no controlling tty the open fails ENXIO, so the prompt guards skip cleanly instead
# of writing to /dev/tty and aborting. Mirrors claude.sh's have_tty.
have_tty() { { : > /dev/tty; } 2>/dev/null; }

confirm() { ai_tools_msg_confirm "$@"; }

# ask <prompt> <default>  -- echo the chosen value on stdout; prompt to the tty.
ask() {
    local prompt="$1" def="$2" resp
    if have_tty; then
        printf '%s %s[%s]%s: ' "${prompt}" "${C_DIM}" "${def}" "${C_RST}" > /dev/tty
        read -r resp < /dev/tty || resp=""
    else
        resp=""
    fi
    printf '%s' "${resp:-$def}"
}

# ── Path helpers ─────────────────────────────────────────────────────────────────

# resolve_dir <path>  -- canonicalize <path> (realpath -e) to stdout; die if absent.
resolve_dir() {
    local p
    p="$(realpath -e "$1" 2>/dev/null)" || die "path not found: $1"
    printf '%s' "${p}"
}

# require_sandbox_clone <path>  -- die unless <path> is a real sandbox CLONE: it passes the
# protected-paths backstop, is a DIRECT child of SANDBOX_ROOT (exactly one component under it --
# never SANDBOX_ROOT itself, never a nested or system path), and is a git worktree. This scopes the
# destructive --sandbox-remove (rm -rf) and --sandbox-push to an actual clone, so neither the shared
# clone area root nor an unrelated path can ever be the target.
require_sandbox_clone() {
    local d="$1" rel
    ai_tools_assert_safe_target "${d}" "sandbox" || exit 3
    [[ "${d}" == "${SANDBOX_ROOT}/"* ]] \
        || die "not a sandbox clone (must be a clone under ${SANDBOX_ROOT}): ${d}"
    rel="${d#"${SANDBOX_ROOT}/"}"
    [[ -n "${rel}" && "${rel}" != */* ]] \
        || die "not a sandbox clone (expected ${SANDBOX_ROOT}/<clone>, one level deep): ${d}"
    git -C "${d}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "not a git clone: ${d} -- if it is a stray directory, remove it by hand"
}

# run_as_owner <cmd> [args...]  -- run <cmd> as the operator this run acts FOR. Without --for that
# is the invoker, so the command runs directly and nothing is prefixed; with --for it is the
# target, and the command runs under `sudo -u <target> -H`. The seam every step that must touch
# the filesystem AS AN OWNER goes through.
#
# It grants nothing new. `sudo -u <target>` rides the caller's GENERAL sudo grant -- the separate
# authority axis CLAUDE.md names, which nothing in this project writes or records -- so an operator
# who reaches it could already act as that account. The sandbox account holds no sudo rule and runs
# under PR_SET_NO_NEW_PRIVS, which drops sudo's SUID bit, so it reaches none of this.
#
# -H is load-bearing rather than tidiness: without it (and without sudoers' always_set_home) sudo
# leaves HOME pointing at the INVOKER's home, so a command that reads a dotfile -- git above all --
# would configure the target's tree from the invoker's settings.
run_as_owner() {
    if [[ -z "${FOR_OPERATOR}" ]]; then "$@"; return; fi
    sudo -u "${OWNER_USER}" -H -- "$@"
}

# ── Registry helpers (the only mutating filesystem writes besides clones) ─────────
# allowed-projects: one absolute path per line; '!'-prefixed lines are exclusions.
# safe.directory: git refuses to operate in a dir it does not own, and the clone is
# owned by the projects user, so the sandbox account (which runs git as the agent)
# needs an explicit entry per registered path.

reg_allow() {
    local dir="$1"
    # A --for run edits a registry in a home this operator cannot even read, so the write goes
    # through the root helper (which re-reads the real file and applies its own idempotency), and
    # the snapshot is refreshed so the rest of this run sees the entry it just added.
    if [[ -n "${FOR_OPERATOR}" ]]; then
        if sudo "${ALLOWLIST_BIN}" --operator "${FOR_OPERATOR}" --add "${dir}" >/dev/null; then
            snapshot_allowlist
            say "    allowed-projects: added for ${FOR_OPERATOR}"
        else
            die "could not add ${dir} to ${FOR_OPERATOR}'s allowed-projects"
        fi
        return 0
    fi
    [[ -f "${ALLOWLIST}" ]] || die "allowlist not found at ${ALLOWLIST} -- run install first"
    # Match through the shared grammar, not a raw line: a hand-added entry with a comment or
    # quotes is already listed, and appending would duplicate it (conf.lib.sh).
    if ai_tools_conf_allowlist_has_entry "${ALLOWLIST}" "${dir}"; then
        say "    allowed-projects: already listed"
    else
        printf '%s\n' "${dir}" >> "${ALLOWLIST}"
        say "    allowed-projects: added"
    fi
}

# allow_escape <text>  -- escape <text> so it matches literally inside a sed `\|^...$|` address:
# the '|' delimiter, backslash, and the BRE metacharacters (`.[]*^$`). Shared by unreg_allow,
# which runs the anchored-exact line deletion, and cmd_list, which prints the same deletion as a
# copy-paste remediation command. Both delete a whole RAW allowlist line, which may carry a
# comment or a dot in a path, so an under-escaped pattern would match a sibling line or none.
allow_escape() { printf '%s' "$1" | sed 's/[]\.*^$|[]/\\&/g'; }

unreg_allow() {
    local dir="$1"
    # A --for run de-lists through the root helper, which applies the same raw-line matcher below
    # to the real file; the snapshot is refreshed so a later read in this run agrees with it.
    if [[ -n "${FOR_OPERATOR}" ]]; then
        if sudo "${ALLOWLIST_BIN}" --operator "${FOR_OPERATOR}" --remove "${dir}" >/dev/null; then
            snapshot_allowlist
            say "    allowed-projects: removed for ${FOR_OPERATOR}"
        else
            warn "could not remove ${dir} from ${FOR_OPERATOR}'s allowed-projects -- run:"
            say  "      ${C_BOLD}sudo ${ALLOWLIST_BIN} --operator ${FOR_OPERATOR} --remove ${dir}${C_RST}"
        fi
        return 0
    fi
    [[ -f "${ALLOWLIST}" ]] || return 0
    # Delete the RAW line(s) whose grammar entry matches ${dir}, not a line rebuilt from ${dir}:
    # a hand-added entry may carry a comment or quotes (conf.lib.sh), and anchoring on ${dir}
    # alone would miss it -- the same blind spot that used to leave the entry (and the agent's
    # access) behind on unclaim.
    local -a lines=() raw
    if ai_tools_conf_allowlist_matching_lines lines "${ALLOWLIST}" "${dir}"; then
        for raw in "${lines[@]}"; do
            sed -i "\|^$(allow_escape "${raw}")$|d" "${ALLOWLIST}"
        done
        say "    allowed-projects: removed"
    else
        say "    allowed-projects: not listed"
    fi
}

# reg_safedir <dir>  -- register <dir> in the agent's git safe.directory list: read unprivileged
# for idempotency, then write via the SAFEDIR_BIN root helper (see its declaration for the
# sudo/644 rationale). The entry lets the agent's git trust this tree, so the step is
# best-effort: when sudo is absent or the helper does not complete, it prints the manual command
# as a hint and lets the claim carry on.
reg_safedir() {
    local dir="$1"
    if git config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null \
            | grep -qxF "${dir}"; then
        say "    git safe.directory: already listed"
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        warn "sudo not found -- cannot register git safe.directory automatically"
        say  "      ${C_BOLD}sudo ${SAFEDIR_BIN} ${dir}${C_RST}"
        return 0
    fi
    if sudo "${SAFEDIR_BIN}" "${dir}"; then
        say "    git safe.directory: added"
    else
        warn "could not register git safe.directory -- run it by hand:"
        say  "      ${C_BOLD}sudo ${SAFEDIR_BIN} ${dir}${C_RST}"
    fi
}

# unreg_safedir <dir>  -- the unclaim counterpart to reg_safedir: drop <dir> via SAFEDIR_BIN
# --remove. Called after unreg_allow, so the helper's --remove is lenient about allowlist
# membership. Best-effort like reg_safedir: warns with the manual command and lets the unclaim
# carry on.
unreg_safedir() {
    local dir="$1"
    if ! git config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null \
            | grep -qxF "${dir}"; then
        say "    git safe.directory: not listed"
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        warn "sudo not found -- cannot remove git safe.directory automatically"
        say  "      ${C_BOLD}sudo ${SAFEDIR_BIN} --remove ${dir}${C_RST}"
        return 0
    fi
    if sudo "${SAFEDIR_BIN}" --remove "${dir}"; then
        say "    git safe.directory: removed"
    else
        warn "could not remove git safe.directory -- run it by hand:"
        say  "      ${C_BOLD}sudo ${SAFEDIR_BIN} --remove ${dir}${C_RST}"
    fi
}

# reg_filemode <dir>  -- pin core.filemode=true in the project's own .git/config so
# git tracks the executable bit deterministically for BOTH co-writers, regardless of
# either user's global git config. Repo-LOCAL (not the shared /opt/ai-tools/.gitconfig,
# which is the agent's global): the setting must be shared by the projects user and the
# agent, and .git is reclaimed to the projects user, who can write it. Idempotent and
# quiet when already set; a no-op (with a note) when <dir> is not a git work tree.
# Orthogonal to the ACL hardening -- filemode governs only the exec bit, never group/
# other permission bits -- but claimed in the same git-config step as safe.directory.
reg_filemode() {
    local dir="$1"
    if ! git -C "${dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        say "    git core.filemode: not a git work tree -- skipped"
        return 0
    fi
    if [[ "$(git -C "${dir}" config --local --get core.filemode 2>/dev/null)" == "true" ]]; then
        say "    git core.filemode: already true"
    else
        if git -C "${dir}" config --local core.filemode true; then
            say "    git core.filemode: set true"
        else
            warn "git core.filemode: could not set (continuing)"
        fi
    fi
}

# acl_gap <dir>  -- true (0) when the project's group-permission ACL is NOT yet in
# place: <dir>'s root carries no `default:group:SANDBOX_GROUP:` entry. Read-only and
# unprivileged. Returns false (1) when the ACL is present, and ALSO when ACLs cannot be
# inspected at all (getfacl missing) -- there is then no gap we can act on, so claim
# does not perpetually re-prompt for a step that cannot run. Mirrors the dir_owngap /
# project_state "na when unavailable" convention.
acl_gap() {
    local dir="$1"
    command -v getfacl >/dev/null 2>&1 || return 1
    getfacl -p "${dir}" 2>/dev/null \
        | grep -qE "^default:group:${SANDBOX_GROUP}:" && return 1
    return 0
}

# git_gap <dir>  -- true (0) when <dir> has a .git tree NOT yet normalized for agent
# git-history access: its .git root lacks group SANDBOX_GROUP, the setgid bit, or the
# default group ACL. Read-only and unprivileged. Returns false (1) when there is no .git
# tree (none, or a submodule/worktree .git FILE), when .git is already normalized, and when
# ACLs cannot be inspected (getfacl missing) -- there is then no gap we can act on, so claim
# does not perpetually re-offer a step that cannot run. Mirrors the acl_gap / dir_owngap
# "na when unavailable" convention. Unlike the other gaps, normalizing .git is opt-in (the
# operator is asked, default yes), so this only DETECTS the gap; cmd_project_claim decides.
git_gap() {
    local dir="$1" grp mode
    [[ -d "${dir}/.git" ]] || return 1
    command -v getfacl >/dev/null 2>&1 || return 1
    # IFS pinned to a space: the script's global IFS ($'\n\t') would land the whole
    # stat line in grp and leave mode empty -- the same pitfall project_state's reader
    # documents.
    IFS=' ' read -r grp mode < <(stat -c '%G %a' "${dir}/.git" 2>/dev/null) || return 1
    [[ "${grp}" == "${SANDBOX_GROUP}" ]] \
        && (( (0${mode} & 02000) != 0 )) \
        && getfacl -p "${dir}/.git" 2>/dev/null | grep -qE "^default:group:${SANDBOX_GROUP}:" \
        && return 1
    return 0
}

# dir_owngap <dir>  -- true (0) when <dir> is NOT group-accessible to the sandbox
# account: group is not SANDBOX_GROUP, or the group-execute bit is clear. The
# sandbox user runs with the project as its cwd, and Node's posix_spawn needs
# group-execute there to launch ANY child (hooks, the Bash tool). This is the exact
# gap the launch wrapper refuses to start on, factored here so both agree.
dir_owngap() {
    local dir="$1" grp mode
    grp="$(stat -c '%G' "${dir}" 2>/dev/null)" || return 0
    mode="$(stat -c '%a' "${dir}" 2>/dev/null)" || return 0
    [[ "${grp}" == "${SANDBOX_GROUP}" ]] && (( (0${mode} & 010) != 0 )) && return 1
    return 0
}

# acl_drift_scan <dir>  -- list paths inside a claimed tree that look shared but carry the
# wrong group: owned by the operator or the sandbox account, group not SANDBOX_GROUP, yet
# with group/other permission bits set. Creation under a claimed tree inherits the group
# (setgid) and the ACLs (default entries); a path lacking both arrived by rename(2) -- mv
# from outside the tree preserves the old group and inherits nothing -- and the agent gets
# EACCES on it deep inside an allowlisted project. Owner-only paths (600/700: locked-down
# secrets, deliberately private files) and '!'-excluded subtrees are not reported -- out of
# the agent's reach by intent. Read-only and unprivileged, detection only: the repair runs
# behind the claim confirm + secret gate, and the helper walks keep their own secret-name/
# exclusion/foreign-owner skips, so reporting a path here never by itself widens access.
acl_drift_scan() {
    local dir="$1" excl
    local -a skip=( -name .git -prune )
    # Leave this project's '!'-excluded subtrees out of the walk: an intentional
    # carve-out stays unreported.
    while IFS= read -r excl; do
        excl="${excl#!}"
        [[ "${excl}" == "${dir}"/* ]] && skip+=( -o -path "${excl}" -prune )
    done < <(grep '^!' "${ALLOWLIST}" 2>/dev/null || true)
    find "${dir}" -xdev \( "${skip[@]}" \) -o \
        \( -user "${OWNER_USER}" -o -user "${SANDBOX_USER}" \) \
        ! -group "${SANDBOX_GROUP}" -perm /077 -print 2>/dev/null
}

# sealed_setgid_scan <dir>  -- list owner-only directories inside a claimed tree whose setgid bit
# carries a THIRD-party group: neither SANDBOX_GROUP nor the group of the directory's own owner.
# When the claim walks seal a path they clear a setgid bit belonging to one of those two, since a
# claimed tree carries no other legitimately; any further group reads as a deliberate operator
# choice and is kept (owner-only.lib.sh). That leaves the operator the one who decides, so the
# claim has to say so rather than act. Read-only and unprivileged, detection only -- a path
# reported here is one the claim did NOT touch, so reporting it never widens access.
#
# "Third party" is decided per path, against the OWNER's primary group -- not against the invoking
# user's. The two differ on a multi-operator host, where the group the claim walks treat as
# legitimate is the resolved project owner's (they act only on paths that owner or the sandbox
# account holds, so the owner's group is exactly what their check comes to), and reporting against
# the invoker's would flag a bit the claim goes on to strip, or stay silent about one it keeps.
sealed_setgid_scan() {
    local dir="$1" excl
    local -a skip=( -name .git -prune )
    while IFS= read -r excl; do
        excl="${excl#!}"
        [[ "${excl}" == "${dir}"/* ]] && skip+=( -o -path "${excl}" -prune )
    done < <(grep '^!' "${ALLOWLIST}" 2>/dev/null || true)
    # find cannot compare a path's group to its own owner's, so it narrows to the candidates
    # (owner-only, setgid, not the sandbox group) and the owner comparison is made per path here.
    # An owner with no passwd entry resolves to no group and is therefore reported, which is the
    # right way round: a setgid whose group cannot be tied to the owner is one to look at.
    find "${dir}" -xdev \( "${skip[@]}" \) -o \
        -type d ! -perm /077 -perm -2000 ! -group "${SANDBOX_GROUP}" \
        -printf '%U\t%G\t%p\n' 2>/dev/null \
    | while IFS=$'\t' read -r _uid _grp _path; do
          [[ "${_grp}" == "$(id -gn "${_uid}" 2>/dev/null || true)" ]] && continue
          printf '%s\n' "${_path}"
      done
}

# reg_ownership <dir>  -- make <dir> usable by the sandbox account: group SANDBOX_GROUP + the
# setgid bit on the project's directories, via the root ai-tools-setgid helper, so the agent can
# enter the tree and files born there inherit the group. Without it a path can be allowlisted yet
# fail every posix_spawn -- the session starts but cannot enter the tree or run a child. The
# operator is not a SANDBOX_GROUP member (multi-operator), so it cannot chgrp to that group
# unprivileged; the helper does it as root and carries its own allowlist + owner guard (a dir owned
# by a third party is left untouched). Pre-existing FILES become agent-accessible through the group
# ACL claim_setfacl applies next -- not a recursive chgrp: only a DRIFTED file (group-accessible
# yet foreign group, per acl_drift_scan) gets its primary group normalized there, which is what
# settles the drift report instead of re-flagging the same paths on every claim.
#
# CALLER MUST run secret_gate "${dir}" first: claim_setfacl then grants the agent group access to
# existing files, so a group-readable secret left un-locked (e.g. appsettings.json 640) would
# become readable by the agent. secret_gate locks secrets to 600/700 first.
reg_ownership() {
    local dir="$1" force="${2:-}"
    # 'force' runs the helper walk even when the project root already matches -- the
    # interior-drift repair, where the gap sits below the root.
    if [[ "${force}" != force ]] && ! dir_owngap "${dir}"; then
        say "    ownership: already group ${SANDBOX_GROUP}, setgid"
        return 0
    fi
    if sudo "${SETGID_BIN}" "${dir}"; then
        say "    ownership: set group ${SANDBOX_GROUP} + setgid on the project directories"
    else
        warn "ownership: could not set group/setgid on ${dir} -- run: sudo ${SETGID_BIN} ${dir}"
    fi
}

# agent_can_traverse <dir>  -- 0 if the sandbox account (SANDBOX_USER, a SANDBOX_GROUP member) can
# ENTER <dir>: world-execute, or group-execute with the directory in group SANDBOX_GROUP, or an
# explicit user:SANDBOX_USER ACL carrying execute.
agent_can_traverse() {
    local d="$1" m grp
    m="$(stat -c '%a' "${d}" 2>/dev/null)" || return 1
    if (( 8#${m} & 0001 )); then return 0; fi
    grp="$(stat -c '%G' "${d}" 2>/dev/null || true)"
    if [[ "${grp}" == "${SANDBOX_GROUP}" ]] && (( 8#${m} & 0010 )); then return 0; fi
    if command -v getfacl >/dev/null 2>&1 \
            && getfacl -p "${d}" 2>/dev/null | grep -qE "^user:${SANDBOX_USER}:..x"; then
        return 0
    fi
    return 1
}

# grantable_ancestor <dir>  -- 0 if reg_reach may grant traverse on <dir>. The rule itself lives in
# safe-paths.lib.sh (ai_tools_traverse_grant_allowed), single-sourced with the two new project
# verbs; this is the call site. Fail-closed when the predicate is unavailable, so a broken install
# never widens a directory it cannot vet.
#
# On a --for run the owner is the target, whose directories the invoker cannot setfacl unprivileged;
# reg_reach applies the grant through the runas seam instead.
grantable_ancestor() {
    local p="$1"
    declare -F ai_tools_traverse_grant_allowed >/dev/null 2>&1 || return 1
    ai_tools_traverse_grant_allowed "${p}" "${OWNER_USER}"
}

# reach_scan <dir>  -- detect the traverse gap between the sandbox account and <dir>:
# fills REACH_GRANT (each blocking ancestor a grant may cover: operator-owned, not a
# protected system directory) and REACH_BLOCKED (the first blocking ancestor no grant may
# cover, empty when none). Read-only and unprivileged; reg_reach acts on the result, and
# the claim's pending overview reads it so the traverse opt-in is announced up front.
reach_scan() {
    local dir="$1" anc
    REACH_GRANT=(); REACH_BLOCKED=""
    anc="$(dirname "${dir}")"
    while [[ "${anc}" != / && "${anc}" != . ]]; do
        if agent_can_traverse "${anc}"; then break; fi
        if grantable_ancestor "${anc}"; then
            REACH_GRANT+=("${anc}")
        else
            REACH_BLOCKED="${anc}"; break
        fi
        anc="$(dirname "${anc}")"
    done
}

# reg_reach <dir>  -- the reachability block: ensure the sandbox account can TRAVERSE the
# path to <dir>, acting on reach_scan's result (the CALLER runs reach_scan first). The
# confined session runs as the sandbox account; a project nested under a directory it
# cannot enter (a private home, 700) is unreachable, so ai-tools-run reports it missing even
# after a clean claim. Grant traverse-only (execute, no read -- u:SANDBOX_USER:--x) on
# each blocking ancestor the operator owns and that is not a protected system directory:
# enough to enter and reach the project, never to list or read it, and unprivileged
# because the operator owns those directories. A blocking ancestor that is a system
# directory or someone else's is left untouched -- there an isolated sandbox clone (under
# /var/opt/ai-tools, already agent-traversable) is the way in. Default-NO: it widens
# access ABOVE the project, so it is a separate, explicit opt-in.
reg_reach() {
    local dir="$1" a
    if [[ -n "${REACH_BLOCKED}" ]]; then
        local why blocked_owner
        blocked_owner="$(stat -c '%U' "${REACH_BLOCKED}" 2>/dev/null || echo '?')"
        if ! declare -F ai_tools_traverse_grant_allowed >/dev/null 2>&1; then
            why="the safe-paths traverse rule is not loaded, so ancestors cannot be vetted"
        elif [[ "${blocked_owner}" != "${OWNER_USER}" ]]; then
            why="owned by ${blocked_owner}, not by ${OWNER_USER}"
        else
            why="a protected system directory"
        fi
        headline_warn "WARNING: project unreachable for the sandbox account" \
            "the sandbox account cannot traverse ${REACH_BLOCKED} (${why}), so it cannot reach ${dir}; an isolated clone under the sandbox area is the way in:"
        say "      ${C_BOLD}ai-tools --sandbox-create ${dir}${C_RST}"
        return 0
    fi
    if (( ${#REACH_GRANT[@]} == 0 )); then return 0; fi

    headline_warn "WARNING: parent directories block the agent" \
        "the sandbox account must be able to traverse every parent directory to reach the project; the grant below is traverse-only (enter, never list or read): u:${SANDBOX_USER}:--x"
    for a in "${REACH_GRANT[@]}"; do say "      ${a}"; done

    # The owner's own HOME ROOT is the one entry in that list whose consequence has to be stated,
    # and what to state is a CONDITION rather than an assertion of exposure. `--x` conveys no
    # listing of the directory and nothing at all about the files in it -- each file's own mode
    # and ACL still decides, and the sandbox account is neither their owner nor in their group.
    # So the grant opens nothing; it makes already-world-readable entries REACHABLE. Under
    # umask 077 that set is empty; under the RHEL default 022 it is the 644 skel files and
    # anything else written world-readable. Which of those this host is, is a question with a
    # one-line answer, so the prompt names the command instead of guessing.
    local owner_home includes_home=false
    owner_home="$(getent passwd "${OWNER_USER}" 2>/dev/null | cut -d: -f6)"
    if [[ -n "${owner_home}" ]]; then
        for a in "${REACH_GRANT[@]}"; do
            [[ "${a}" == "${owner_home%/}" ]] && { includes_home=true; break; }
        done
    fi
    if ${includes_home}; then
        say ""
        say "  ${owner_home} is ${OWNER_USER}'s home directory. Traverse conveys no listing of it"
        say "  and no access to the files in it -- each file's own mode and ACL still decides."
        say "  What it makes reachable is whatever there is already world-readable; this lists it:"
        say ""
        say "      ${C_BOLD}find ${owner_home} -maxdepth 1 -perm -o+r${C_RST}"
        say ""
    fi

    # Default NO, and deliberately not pre-answerable: the grant widens access ABOVE the project,
    # so neither AI_TOOLS_ASSUME_YES (which only fast-tracks default-YES questions) nor the claim's
    # own -y reaches it. A run with no terminal therefore declines, and prints the commands so the
    # refusal is actionable rather than merely recorded.
    if confirm "Grant the sandbox account traverse-only access on them?" n; then
        local failed=false
        for a in "${REACH_GRANT[@]}"; do
            # A --for run's ancestors belong to the TARGET, so an unprivileged setfacl by the
            # invoker fails on every one of them; run_as_owner applies it as the owner instead.
            if run_as_owner setfacl -m "u:${SANDBOX_USER}:--x" "${a}" 2>/dev/null; then
                say "    reach: u:${SANDBOX_USER}:--x ${a}"
            else
                failed=true
                warn "reach: could not grant on ${a} -- run it as ${OWNER_USER} or as root:"
                say  "      ${C_BOLD}setfacl -m u:${SANDBOX_USER}:--x ${a}${C_RST}"
            fi
        done
        ${failed} || ok "parent directories traversable by the sandbox account"
    else
        say "    reach: left as-is -- the agent may be unable to enter ${dir}"
        have_tty || for a in "${REACH_GRANT[@]}"; do
            say "      ${C_BOLD}setfacl -m u:${SANDBOX_USER}:--x ${a}${C_RST}"
        done
    fi
}

# normalize_clone <dir> [locked-path...]  -- make a freshly created clone
# agent-accessible. The clone is born in group SANDBOX_GROUP via the setgid SANDBOX_ROOT
# but cloned under umask 077 (see cmd_sandbox_create), so nothing in it is
# group-readable until this step. Add group rwX and the setgid bit on every directory
# (owner stays the projects user); the SessionStart ai-tools-setgid pass keeps it
# normalized thereafter. Every <locked-path> (the secret gate's finds, locked to
# owner-only by ai-tools-lockdown) is PRUNED from both walks -- re-opening one here
# would undo the lockdown this step is sequenced after.
normalize_clone() {
    local d="$1"; shift
    local -a prune=() p
    for p in "$@"; do prune+=( -path "${p}" -prune -o ); done
    find "${d}" "${prune[@]}" -exec chmod g+rwX {} +
    find "${d}" "${prune[@]}" -type d -exec chmod g+s {} +
}

# relabel_clone <dir>  -- apply the SELinux project label so the agent (ai_tools_t)
# can read/write the clone. A static fcontext rule in selinux/policy/ai_tools.fc maps every
# directory under sandbox-projects/ to ai_tools_project_t, so a plain restorecon
# labels it -- no per-project semanage and no root: the projects user runs as
# unconfined_t, which the policy grants relabel to ai_tools_project_t. No-op when
# SELinux is disabled (or the module is not loaded, in which case the label stays
# the default and the operator must run selinux/install-selinux.sh install).
relabel_clone() {
    local d="$1"
    command -v restorecon >/dev/null 2>&1 || return 0
    [[ "$(getenforce 2>/dev/null)" == "Disabled" ]] && return 0
    if restorecon -FR "${d}" 2>/dev/null; then
        ok "labelled clone ai_tools_project_t (SELinux)"
    else
        warn "could not relabel ${d} for SELinux; if enforcing, run: sudo restorecon -FR ${d}"
    fi
}

# ── Lockdown helpers ───────────────────────────────────────────────────────────
# ai-tools-lockdown revokes ai-tools' read access to secret-named files under a
# project. It is root-only and reads its target from the working directory, so we
# cd there and sudo it; there is no NOPASSWD grant, so sudo prompts for a password.

# run_lockdown <dir> [extra-args...]  -- run the helper on <dir>; returns its status.
run_lockdown() {
    local d="$1"; shift
    ( cd "${d}" && sudo "${LOCKDOWN_BIN}" "$@" )
}

# run_relabel <dir> [--remove]  -- apply (or revert) the SELinux project label on
# <dir> via the root helper (sudo, password); returns its status. The helper parses
# the path and the optional flag in any order.
run_relabel() {
    local d="$1"; shift
    sudo "${RELABEL_BIN}" "$@" "${d}"
}

# run_reclaim <dir> [--full]  -- hand agent-written files under <dir> back to the operator via
# the root helper (sudo, password); returns its status. The helper parses the path and --full in
# any order.
run_reclaim() {
    local d="$1"; shift
    sudo "${RECLAIM_BIN}" "$@" "${d}"
}

# run_setfacl <dir> <with_git>  -- apply the project's group-permission ACL on <dir> via
# the root helper (sudo, password); when <with_git> is true, also pass --with-git so the
# helper normalizes the .git tree too. Returns its status.
run_setfacl() {
    local d="$1" with_git="${2:-false}"
    if ${with_git}; then
        sudo "${SETFACL_BIN}" --with-git "${d}"
    else
        sudo "${SETFACL_BIN}" "${d}"
    fi
}

# run_unclaim <dir> <target-group> [helper-flag...]  -- clear the agent ACL, regroup <dir> to
# <target-group>, and remove group write, via the root helper (sudo, password); returns
# its status. Trailing flags (--unlisted, --full) pass straight through: the helper re-derives
# every gate from them itself rather than trusting this caller's classification.
run_unclaim() {
    local d="$1" g="$2"; shift 2
    sudo "${UNCLAIM_BIN}" "${d}" "${g}" "$@"
}

# secret_gate <dir>  -- the secret-lockdown block: before ANY step grants the agent
# access to <dir> (the group ACL, the setgid group change, .git normalization, the
# clone normalize), make sure no group-readable secret would be exposed. The CLI cannot
# read the root-only secret-pattern library, so detection is delegated to
# ai-tools-lockdown --dry-run (sudo, password -- the first sudo prompt of a claim, so it
# lands right under this block's headline). Found secrets are listed and the user is
# asked to lock them down (--yes apply); the helper's own interactive mode is NOT used
# for this because it exits 0 whether the user applies or aborts, which would let an
# un-locked tree through. Fills SECRET_GATE_LOCKED with the found paths so
# normalize_clone can prune them. Returns 0 only when the tree is safe to expose (no
# secrets found, or all locked down); non-zero means the caller must fail closed.
secret_gate() {
    local dir="$1" out
    SECRET_GATE_LOCKED=()
    headline "Secret lockdown" \
        "scanning ${dir} for secret-named files before the agent is granted access"
    if ! out="$(run_lockdown "${dir}" --dry-run 2>&1)"; then
        warn "secret scan failed -- not granting access:"
        printf '%s\n' "${out}" >&2
        ai_tools_log_error "secret pre-check: scan failed for ${dir}, access not granted"
        return 1
    fi
    # "N secret-matching path(s)" when any are found vs "no secret-matching paths"
    # when clean -- match the count form to tell them apart.
    if ! grep -qE 'ai-tools-lockdown: [0-9]+ secret-matching' <<<"${out}"; then
        ok "no secret-matching paths found"
        ai_tools_log_info "secret pre-check: clean, no secret-matching paths under ${dir}"
        return 0                                   # clean tree: safe to expose
    fi

    # The helper has already logged the count and each path (journald + lockdown.log);
    # record the operator-side decision here too.
    mapfile -t SECRET_GATE_LOCKED < <(printf '%s\n' "${out}" \
        | sed -n 's/^[[:space:]]*\[\(file\|dir\)\][[:space:]]*//p')
    say ""
    say "  found ${#SECRET_GATE_LOCKED[@]} secret-matching path(s):"
    printf '%s\n' "${out}" | grep -E '\[(file|dir)\]' >&2 || true
    warn "lockdown is best effort, matching only known secret patterns -- handle any secret it misses yourself first"
    ai_tools_log_warn "secret pre-check: secrets present under ${dir} (see lockdown.log for paths)"
    # Default YES: locking down is the safe direction and the list above may be long,
    # so Enter -- and an unattended run -- proceeds to lock down.
    if ! confirm "Lock down these secrets now?" y; then
        warn "declined -- access will not be granted while secrets are exposed"
        ai_tools_log_warn "secret pre-check: lockdown declined for ${dir}, access not granted"
        return 1
    fi
    if run_lockdown "${dir}" --yes; then
        say ""
        ok "secrets locked down"
        ai_tools_log_info "secret pre-check: secrets locked down under ${dir}"
        return 0
    fi
    warn "lockdown did not complete -- not granting access"
    ai_tools_log_error "secret pre-check: lockdown failed under ${dir}, access not granted"
    return 1
}

# drop_lockdown_guard <dir>  -- write a placeholder CLAUDE.md telling the agent to
# do nothing until lockdown runs, used when a fresh sandbox clone's tip-commit
# secrets are still readable. An existing CLAUDE.md is preserved as CLAUDE.md.bak
# (via git mv, falling back to a plain mv) and restored by clear_lockdown_guard.
drop_lockdown_guard() {
    local d="$1"; local md="${d}/CLAUDE.md"
    if [[ -f "${md}" ]] && grep -q "${GUARD_MARKER}" "${md}" 2>/dev/null; then
        return 0                                   # already guarded (re-run)
    fi
    if [[ -e "${md}" ]]; then
        if [[ -e "${d}/CLAUDE.md.bak" ]]; then
            warn "CLAUDE.md.bak already exists in ${d}; not overwriting -- guard skipped"
            return 0
        fi
        git -C "${d}" mv CLAUDE.md CLAUDE.md.bak 2>/dev/null \
            || mv "${md}" "${d}/CLAUDE.md.bak"
        say "    preserved existing CLAUDE.md as CLAUDE.md.bak"
    fi
    cat > "${md}" <<EOF
<!-- ${GUARD_MARKER} -->
# STOP — this sandbox is not secured yet

\`ai-tools-lockdown\` has **not** been run on this shallow clone, so credential
files in its tip commit (\`.env\`, \`appsettings.*.json\`, \`*.key\`, …) may still be
readable by the agent.

Until lockdown is performed:

- **Do not read, open, copy, or transmit any file in this project.**
- **Do not run any command.**
- Ask the operator to secure it first by running, as the projects user:

      ai-tools --lockdown ${d}

Only paths approved in the operator's \`allowed-projects\` allowlist are ever in
scope, and only after lockdown has revoked the agent's read access to secrets.

This file is a temporary guard. It is removed automatically once lockdown runs,
and any original CLAUDE.md is restored from CLAUDE.md.bak.
EOF
    ok "wrote a guard CLAUDE.md (agent told to wait for lockdown)"
}

# clear_lockdown_guard <dir>  -- remove a guard CLAUDE.md and restore any
# CLAUDE.md.bak it set aside. No-op unless the guard sentinel is present. Called
# after a successful (non-dry-run) lockdown.
clear_lockdown_guard() {
    local d="$1"; local md="${d}/CLAUDE.md"
    [[ -f "${md}" ]] || return 0
    grep -q "${GUARD_MARKER}" "${md}" 2>/dev/null || return 0
    rm -f "${md}"
    if [[ -e "${d}/CLAUDE.md.bak" ]]; then
        git -C "${d}" mv CLAUDE.md.bak CLAUDE.md 2>/dev/null \
            || mv "${d}/CLAUDE.md.bak" "${md}"
        say "    restored original CLAUDE.md from CLAUDE.md.bak"
    fi
    ok "removed the lockdown guard from ${d}"
}

# ── Commands ─────────────────────────────────────────────────────────────────────

# project_state <dir>  -- print the claim state of <dir> as seven space-separated
# tokens: "<listed> <safedir> <filemode> <owngap> <acl> <labelled> <git>". listed/safedir
# reflect the two registries; filemode is true when repo-local core.filemode is already
# true ("na" when <dir> is not a git work tree); owngap is true when the agent still
# lacks group access (see dir_owngap); acl is true when the group-permission ACL still
# needs applying (see acl_gap); labelled is the live SELinux type check -- true/false
# when SELinux is active, "na" when it is disabled (no label needed); git is true when a
# .git tree is present but not yet normalized for agent history sharing (see git_gap),
# false otherwise -- it gates the opt-in .git prompt, not a mandatory claim step. Read-only,
# no privilege. The ai_tools_project_t string is the single fact mirrored from the root
# labelling lib; the authoritative semanage/restorecon logic is NOT duplicated here.
project_state() {
    local dir="$1" listed=false safedir=false filemode=na owngap=true acl=false labelled=na git=false
    ai_tools_conf_allowlist_has_entry "${ALLOWLIST}" "${dir}" 2>/dev/null && listed=true
    git config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null \
        | grep -qxF "${dir}" && safedir=true
    if git -C "${dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        [[ "$(git -C "${dir}" config --local --get core.filemode 2>/dev/null)" == "true" ]] \
            && filemode=true || filemode=false
    fi
    dir_owngap "${dir}" || owngap=false
    acl_gap "${dir}" && acl=true
    if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
        if ls -Zd "${dir}" 2>/dev/null | grep -q ':ai_tools_project_t:'; then
            labelled=true
        else
            labelled=false
        fi
    fi
    git_gap "${dir}" && git=true
    printf '%s %s %s %s %s %s %s\n' \
        "${listed}" "${safedir}" "${filemode}" "${owngap}" "${acl}" "${labelled}" "${git}"
}

# claim_relabel <dir>  -- apply the SELinux project label via the root helper so the
# confined agent can access the tree. Best-effort, mirroring lockdown: warns with the
# manual command (never dies) when sudo is missing or the helper fails.
claim_relabel() {
    local d="$1"
    if ! command -v sudo >/dev/null 2>&1; then
        warn "sudo not found -- cannot apply the SELinux label automatically"
        say  "      ${C_BOLD}sudo ${RELABEL_BIN} ${d}${C_RST}"
        return 0
    fi
    if run_relabel "${d}"; then
        say "    SELinux label: ai_tools_project_t applied"
    else
        warn "could not apply the SELinux label -- run it by hand:"
        say  "      ${C_BOLD}sudo ${RELABEL_BIN} ${d}${C_RST}"
    fi
}

# claim_setfacl <dir> <with_git>  -- apply the group-permission ACL via the root helper so
# files the projects user's git checkout/merge writes under a restrictive umask stay group-
# accessible; when <with_git> is true the helper also normalizes the .git tree (group +
# setgid + ACL) so the operator's commits stay agent-accessible. Best-effort, mirroring
# claim_relabel: warns with the manual command (never dies) when sudo is missing or fails.
claim_setfacl() {
    local d="$1" with_git="${2:-false}" flag="" note=""
    ${with_git} && { flag=" --with-git"; note=" (incl. .git)"; }
    if ! command -v sudo >/dev/null 2>&1; then
        warn "sudo not found -- cannot apply the project ACL automatically"
        say  "      ${C_BOLD}sudo ${SETFACL_BIN}${flag} ${d}${C_RST}"
        return 0
    fi
    if run_setfacl "${d}" "${with_git}"; then
        say "    group-permission ACL: applied${note}"
    else
        warn "could not apply the project ACL -- run it by hand:"
        say  "      ${C_BOLD}sudo ${SETFACL_BIN}${flag} ${d}${C_RST}"
    fi
}

# cmd_project_claim [path]  -- idempotently bring a real, IN-PLACE project (default:
# cwd) to a fully claimed state: allowlist + git safe.directory + git core.filemode +
# secret lockdown + recursive ownership + group-permission ACL + SELinux
# ai_tools_project_t label, so the agent can work the REAL tree. Inspects current state
# first and performs ONLY the missing steps, so a re-run is quiet and a fully-claimed
# project is a clean no-op (no prompt, no sudo).
#
# The flow is a sequence of SELF-CONTAINED blocks, each opened by a headline box and
# closed by its own confirm/result, in this order:
#   1. Review    -- the pending-step overview (every later block announced), the drift
#                   reports, and -- when a heavy step (chgrp, ACL, relabel, drift repair)
#                   is pending -- the default-NO proceed confirm that covers exactly the
#                   steps listed.
#   2. Secret lockdown -- BEFORE any access-granting step, whenever one is pending or
#                   this is a first claim (see secret_gate); fails the claim closed.
#   3. .git history  -- separate default-YES opt-in (ai-tools-setfacl --with-git).
#   4. Reachability  -- separate default-NO opt-in for traverse-only ancestor ACLs.
#   5. Apply     -- the approved steps back to back, one result line each, closed by
#                   the final "claimed" ✓.
# A re-claim with ownership in place also scans for interior drift (acl_drift_scan:
# shared-looking paths brought into the tree without inheriting the group/ACL) and folds
# the group+ACL re-apply into the proceed confirm and secret gate -- repair never runs
# unconfirmed. A first claim skips the report: its normal walk repairs the whole tree.
# path_detail_lines <path...>  -- print each path prefixed with its owner:group and mode, the
# columns that show at a glance why a path is flagged (the foreign or agent group) and whether
# its mode is what the operator expects. Shared by the claim's drift report and the unclaim's
# residue report: both answer the same question about a path, so both show the same columns.
path_detail_lines() {
    local _p _og _m
    for _p in "$@"; do
        IFS=' ' read -r _og _m < <(stat -c '%U:%G %a' "${_p}" 2>/dev/null) \
            || { _og='?'; _m='?'; }
        printf '        %s%-18s %-4s %s%s\n' "${C_DIM}" "${_og}" "${_m}" "${_p}" "${C_RST}"
    done
}

# offer_full_listing <label> <path...>  -- after a truncated sample, offer the full list with
# ownership and mode. Default yes: it is read-only and the point of asking is that the list is
# long, so Enter shows it and a piped/delegated run prints it too (grep-able).
offer_full_listing() {
    local _label="$1"; shift
    confirm "      List all $# ${_label} with ownership and mode?" y || return 0
    path_detail_lines "$@"
}

# path_listing <label> <path...>  -- report a set of paths: in FULL when there are few enough that
# the whole list is shorter than a sample plus the question about it, otherwise a three-path sample
# and an offer to see the rest. One decision in one place, because getting it wrong is invisible in
# the code and glaring on screen: sampling four paths prints three, says "... and 1 more", asks a
# question, and then prints all four again -- seven lines and a prompt to show four paths.
# SAMPLE is the sample size; the full-list cut-off is twice it, the point past which the sample is
# genuinely saving the reader something.
readonly PATH_LISTING_SAMPLE=3
path_listing() {
    local _label="$1"; shift
    if (( $# <= 2 * PATH_LISTING_SAMPLE )); then
        path_detail_lines "$@"
        return 0
    fi
    path_detail_lines "${@:1:PATH_LISTING_SAMPLE}"
    say "        ${C_DIM}... and $(( $# - PATH_LISTING_SAMPLE )) more${C_RST}"
    offer_full_listing "${_label}" "$@"
}

# under_skip_listed_name <base> <path>  -- 0 when <path> sits under a skip-listed directory NAME
# (build output, dependencies, caches) relative to <base>, honoring the relative artifact
# exclusions that re-open a subtree to the walks. The single predicate behind both the claim's
# "drift I cannot repair" split and the unclaim's "residue the default walk will not reach"
# split, so one skip contract decides both. Returns 1 when the skip list is unavailable, which
# treats every hit as reachable -- the fail-soft direction for a walk-cost optimization.
under_skip_listed_name() {
    local _base="$1" _path="$2" _rel _seg _name _s _x
    [[ "${#AI_TOOLS_SKIP_NAMES[@]}" -gt 0 ]] || return 1
    _rel="${_path#"${_base}"/}"
    IFS=/ read -ra _seg <<< "${_rel}"
    for _name in "${AI_TOOLS_SKIP_NAMES[@]}"; do
        for _s in "${_seg[@]}"; do
            if [[ "${_s}" == "${_name}" ]]; then
                # A relative artifact exclusion re-opens its subtree to the walks, so a hit
                # under one is reachable, not skip-listed.
                for _x in "${AI_TOOLS_SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE[@]:-}"; do
                    [[ -z "${_x}" ]] && continue
                    _x="${_x%/}"
                    [[ "${_rel}" == "${_x}" || "${_rel}" == "${_x}"/* ]] && return 1
                done
                return 0
            fi
        done
    done
    return 1
}

# require_claimable_owner <dir>  -- die unless <dir> is held by the operator this run acts FOR or
# by the sandbox account. The two root helpers that grant the agent its access -- ai-tools-setgid
# and ai-tools-setfacl -- act only on those two owners, so a project root held by anyone else
# takes neither the group/setgid change nor the ACL, while the allowlist entry, the git
# safe.directory entry and the SELinux label all still apply. The claim would close with its ✓
# having granted nothing, and the agent could not enter the tree.
#
# The case this exists for is a --for claim: `mkdir ~/proj && ai-tools --project-claim --for svc
# ~/proj` resolves the owner to svc, so every inode in the tree fails the helpers' guard. This is
# the CLI-side front line for the count those helpers now report; the refusal names the chown that
# fixes it, because transferring a tree recursively needs an authority this CLI does not hold.
require_claimable_owner() {
    local d="$1" owner
    owner="$(stat -c '%U' "${d}" 2>/dev/null)" || die "cannot read the owner of ${d}"
    [[ "${owner}" == "${OWNER_USER}" || "${owner}" == "${SANDBOX_USER}" ]] && return 0

    # The remedy is a command, so it prints plain and ahead of die(), whose emitter would wrap it
    # across lines (messaging.rule.md).
    printf '\n' >&2
    printf '  %s\n' "Give the tree to ${OWNER_USER}, then re-run the claim:" "" \
                    "    sudo chown -R ${OWNER_USER} ${d}" >&2
    printf '\n' >&2
    local -a why=(
        "this project directory is owned by ${owner}, and the claim grants it to ${OWNER_USER}."
        "The claim's setgid and ACL steps act only on paths held by ${OWNER_USER} or ${SANDBOX_USER}, so here they would apply nothing while the registries and the SELinux label still would -- a claim that reports success and leaves the agent unable to enter the project."
    )
    [[ -n "${FOR_OPERATOR}" ]] && why+=(
        "You are claiming for ${FOR_OPERATOR}, so the tree has to belong to ${FOR_OPERATOR} rather than to you."
    )
    die "${why[@]}"
}

cmd_project_claim() {
    # -y/--yes pre-answers the claim's own proceed prompt ("Apply the pending steps IN
    # PLACE?", default NO) -- an explicit per-invocation flag, passed by a caller that
    # already confirmed the same decision (the launch wrapper's delegated claim). The
    # scoped opt-ins (secret lockdown, .git history, ancestor traversal) are separate
    # questions it does not answer.
    local a path="" ASSUME_YES=false
    for a in "$@"; do
        case "${a}" in
            -y|--yes) ASSUME_YES=true ;;
            -*) die "unknown --project-claim option: ${a} (allowed: -y/--yes)" ;;
            *)  if [[ -z "${path}" ]]; then path="${a}"
                else die "--project-claim takes a single path"; fi ;;
        esac
    done
    local d; d="$(resolve_dir "${path:-$PWD}")"
    [[ -d "${d}" ]] || die "not a directory: ${d}"
    # Refuse to claim a protected system directory before it ever reaches the allowlist. The
    # safe-paths guard is guaranteed loaded (the top-level source fails closed otherwise).
    ai_tools_assert_safe_target "${d}" "project claim" || exit 3
    # Before any registry write: a root the access-granting helpers cannot act on makes the whole
    # claim a no-op they would report only as a count on stderr.
    require_claimable_owner "${d}"

    local listed safedir filemode owngap acl labelled git
    # project_state prints seven SPACE-separated tokens; this script's global IFS is
    # $'\n\t' (no space), so a bare read would collapse the whole line into the first
    # field and leave the rest empty -- silently skipping the label/ACL/ownership steps.
    # Pin IFS=' ' for this read so the tokens split as intended.
    IFS=' ' read -r listed safedir filemode owngap acl labelled git < <(project_state "${d}")
    local need_label=false; [[ "${labelled}" == false ]] && need_label=true
    local need_filemode=false; [[ "${filemode}" == false ]] && need_filemode=true
    local need_acl=false; [[ "${acl}" == true ]] && need_acl=true
    local need_git=false; [[ "${git}" == true ]] && need_git=true

    # Interior drift: the root-level state says nothing about paths brought INTO a claimed
    # tree without inheriting the group/ACL (mv keeps the old group). Detect them here;
    # the repair applies further down behind the same confirm + secret gate as the other
    # in-place steps. Scanned only on a RE-CLAIM whose ownership is already in place: a
    # first claim (or one with the setgid step still pending) walks and repairs the whole
    # tree anyway, and its every path would trivially match the drift predicate -- a
    # 200-line report of what the claim is about to fix is noise, not signal.
    local -a drift=()
    if [[ "${listed}" == true && "${owngap}" == false ]]; then
        mapfile -t drift < <(acl_drift_scan "${d}" | head -n 200)
    fi

    # Split the hits on the shared skip list: the sweeps AND the claim walks leave a
    # skip-listed directory's contents alone (one skip contract), so a re-claim cannot
    # repair a hit under one -- it gets its own report with the remedies that can.
    local -a drift_skipped=()
    if ai_tools_skip_find_expr sweep 2>/dev/null && (( ${#AI_TOOLS_SKIP_NAMES[@]} )); then
        local -a _keep=()
        local _hit
        for _hit in "${drift[@]}"; do
            if under_skip_listed_name "${d}" "${_hit}"; then
                drift_skipped+=("${_hit}")
            else
                _keep+=("${_hit}")
            fi
        done
        drift=("${_keep[@]}")
    fi

    # A setgid bit on a sealed dir that belongs to some third group is the one piece of residue
    # the claim walks decline to remove, so it is surfaced here rather than left to the helper's
    # stderr, where it scrolls past under the Apply step.
    local -a sealed_setgid=()
    mapfile -t sealed_setgid < <(sealed_setgid_scan "${d}" | head -n 200)

    sealed_setgid_note() {
        (( ${#sealed_setgid[@]} )) || return 0
        headline_warn "NOTICE: setgid on an owner-only directory" \
            "${#sealed_setgid[@]} sealed director(ies) carry a setgid bit set to a group that is neither ${SANDBOX_GROUP} nor yours. The claim keeps it -- it cannot tell a deliberate choice from a leftover -- so new files there are still born in that group."
        path_listing "director(ies)" "${sealed_setgid[@]}"
        say "      ${C_DIM}if it was not intended, clear it yourself:  chmod g-s <dir>${C_RST}"
    }

    # skip_listed_note: the skip-listed hits are informational either way -- shown both on
    # the fully-claimed early return and in the pending flow.
    skip_listed_note() {
        (( ${#drift_skipped[@]} )) || return 0
        headline_warn "NOTICE: drift under skip-listed directories" \
            "${#drift_skipped[@]} path(s) with a foreign group sit under skip-listed directory names (build output, dependencies, caches); claim leaves those trees untouched."
        path_listing "path(s)" "${drift_skipped[@]}"
        say "      ${C_DIM}if one is source in this project, exempt it in /etc/ai-tools/operator.conf --${C_RST}"
        say "      ${C_DIM}narrow the category (SKIP_ARTIFACT_DIRS=...) or list the path relative to the${C_RST}"
        say "      ${C_DIM}project root in SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE -- then re-claim;${C_RST}"
        say "      ${C_DIM}ownership only: ai-tools --reclaim --full${C_RST}"
    }

    # ── Review block: the flow headline, the pending-step overview, and the drift
    # reports, so the proceed confirm that closes it covers exactly what was just
    # shown. Every later block is announced here with a "you will be asked" marker. ──
    local heavy=false
    local -a head=("${d}")
    if [[ "${owngap}" == true ]] || ${need_acl} || ${need_label} || (( ${#drift[@]} )); then
        heavy=true
        head+=("claiming in place grants the agent group access to this whole tree")
        # Said plainly, before the confirm that authorizes it: the steps below rewrite metadata
        # across the tree, and unclaim NORMALIZES rather than restores (setfacl -b clears ACLs
        # that predate the claim; the result is 640/750). No prior state is recorded anywhere,
        # so no command can put it back -- which makes "back up first" the only real safeguard.
        head+=("It MODIFIES group, permissions and ACLs throughout this tree, sets setgid on its directories, and removes world access. Files and directories that are owner-only (0600/0700) are left alone, out of the agent's reach. The previous permissions are NOT recorded anywhere, so this is NOT reversible -- unclaiming later normalizes the tree rather than restoring it. Back up first. See: man ai-tools")
    fi
    headline "Claim project (in place)" "${head[@]}"

    reach_scan "${d}"

    # The project root being owner-only is reach_scan's problem one level down: ai-tools-setfacl
    # honours a 0600/0700 mode and skips the path, so every later step still succeeds and the
    # claim closes with its ✓ while the sandbox account cannot enter the tree at all. Stated
    # here, before the confirm, rather than left to the helper's skip count afterwards.
    local root_mode
    root_mode="$(stat -c '%a' "${d}" 2>/dev/null || echo 755)"
    if (( ( 8#${root_mode} & 077 ) == 0 )); then
        headline_warn "NOTICE: this project directory is owner-only" \
            "${d} is mode ${root_mode}, which keeps it out of the sandbox account's reach: the claim honours that mode and grants nothing on it."
        say ""
    fi

    if [[ "${listed}" == true && "${safedir}" == true && "${owngap}" == false ]] \
            && ! ${need_filemode} && ! ${need_acl} && ! ${need_label} && ! ${need_git} \
            && (( ${#drift[@]} == 0 )); then
        skip_listed_note
        sealed_setgid_note
        # A claimed project can still sit under a non-traversable parent (a later
        # chmod 700 above it), so the reachability block runs on the no-op path too.
        reg_reach "${d}"
        ok "already fully claimed -- nothing to do"
        return 0
    fi

    # The gate runs whenever any pending step widens the agent's access -- the setgid
    # group change, the group ACL, drift repair, .git normalization, the SELinux label --
    # and on every first claim (a tree can be group-accessible by setgid inheritance yet
    # never scanned). Only pure registry additions (safedir, filemode) skip it.
    local need_gate=false
    if [[ "${listed}" != true || "${owngap}" == true ]] \
            || ${need_acl} || ${need_git} || ${need_label} || (( ${#drift[@]} )); then
        need_gate=true
    fi

    say ""
    say "  pending:"
    [[ "${listed}"  == true  ]] || say "    - add to allowed-projects"
    [[ "${safedir}" == true  ]] || say "    - add git safe.directory"
    ${need_filemode} && say "    - set git core.filemode true"
    [[ "${owngap}"  == true  ]] && say "    - set group ${SANDBOX_GROUP} + setgid on the project directories"
    ${need_acl} && say "    - apply group-permission ACL (default + access g:${SANDBOX_GROUP}:rwX)"
    ${need_label} && say "    - apply SELinux ai_tools_project_t label"
    (( ${#drift[@]} )) && say "    - re-apply group ${SANDBOX_GROUP} + ACL to ${#drift[@]} drifted path(s) -- details below"
    ${need_gate} && say "    - scan for secret-named files and lock them down -- you will confirm"
    ${need_git} && say "    - normalize .git so the agent can access git history -- you will be asked"
    (( ${#REACH_GRANT[@]} )) && say "    - grant traverse-only access on ${#REACH_GRANT[@]} parent path(s) -- you will be asked"

    if (( ${#drift[@]} )); then
        headline_warn "WARNING: interior permission drift" \
            "${#drift[@]} path(s) inside the tree carry a foreign group yet stay group-accessible (they arrived without inheriting the project group or ACL)."
        path_listing "path(s)" "${drift[@]}"
        # The cap is a property of the SCAN, not of this listing, so it is said whether the paths
        # were sampled or shown in full.
        if (( ${#drift[@]} >= 200 )); then
            say "        ${C_DIM}(scan capped at 200 paths)${C_RST}"
        fi
    fi
    skip_listed_note
    sealed_setgid_note

    # Heavy steps (recursive chgrp; sudo relabel/ACL; drift repair) close the Review
    # block behind the proceed confirm; pure registry additions do not. --yes pre-answers
    # exactly this prompt: the launch wrapper passes it after taking its own "Claim it in
    # place now?" confirmation, so a delegated claim does not ask the same question
    # twice. The scoped opt-ins below (secret lockdown, .git history, ancestor traversal)
    # still ask on their own terms.
    if ${heavy}; then
        ${ASSUME_YES} || confirm "Apply the pending steps above IN PLACE?" n \
            || die "aborted"
    fi

    # Allowlist first: ai-tools-lockdown only scans an allowlisted path. Rolled back on
    # a failed gate.
    [[ "${listed}" == true ]] || reg_allow "${d}"

    if ${need_gate}; then
        if ! secret_gate "${d}"; then
            [[ "${listed}" == true ]] || unreg_allow "${d}"
            say "    lock down secrets first, then re-run the claim:"
            say "      ${C_BOLD}ai-tools --lockdown ${d}${C_RST}"
            die "claim stopped -- secrets not locked down"
        fi
    fi

    # .git access is opt-in (default yes), asked separately from the proceed prompt --
    # which --yes covers; this one it does not, so a wrapper-delegated claim still asks
    # before exposing the repo's full git history.
    local do_git=false
    if ${need_git}; then
        headline_warn "WARNING: git history exposure" \
            "normalizing .git lets the agent read this repo's full git history"
        if confirm "Normalize .git so the agent can access git history here?" y; then
            do_git=true
        else
            say "    .git: left as-is (history not accessible to the agent)"
        fi
    fi

    reg_reach "${d}"

    # ── Apply block: the approved steps run back to back, each reporting one result
    # line; the closing ✓ is the claim's completion. ──
    headline "Applying claim steps" "${d}"
    [[ "${safedir}" == true  ]] || reg_safedir "${d}"
    ${need_filemode} && reg_filemode "${d}"
    if [[ "${owngap}" == true ]]; then
        reg_ownership "${d}"
    elif (( ${#drift[@]} )); then
        reg_ownership "${d}" force
    fi
    { ${need_acl} || ${do_git} || (( ${#drift[@]} )); } && claim_setfacl "${d}" "${do_git}"
    ${need_label} && claim_relabel "${d}"
    say ""
    ok "claimed ${d}"
    ai_tools_log_info "claimed project ${d}"
}

# cmd_project_create <path> [-y]  -- create a NEW project directory and claim it: ONE mkdir, an
# empty git repository, a README.md, then the ordinary claim flow on the result. The parent
# directory must already exist; see the refusal below for why it is not created.
#
# It REFUSES a path that already exists, which is the sharp line between this verb and
# --project-claim: a create that quietly claimed whatever was already there would make the two
# interchangeable, and the operation that grants an agent access to a tree is not one to arrive at
# by a typo. Recovering a half-finished create is therefore --project-claim on the new directory,
# never a re-run of this.
#
# <path> is REQUIRED and has no cwd default, unlike every other verb here: the cwd always exists,
# so a defaulted create could only ever refuse.
#
# Every filesystem step goes through run_as_owner, so a create for another operator produces a
# TARGET-owned tree. That is not tidiness -- the claim's setgid and ACL helpers act only on paths
# the resolved operator or the sandbox account holds, so a tree born owned by the invoker is one
# require_claimable_owner then refuses.
cmd_project_create() {
    local a path="" ASSUME_YES=false
    for a in "$@"; do
        case "${a}" in
            -y|--yes) ASSUME_YES=true ;;
            -*) die "unknown --project-create option: ${a} (allowed: -y/--yes)" ;;
            *)  if [[ -z "${path}" ]]; then path="${a}"
                else die "--project-create takes a single path"; fi ;;
        esac
    done
    [[ -n "${path}" ]] || die "--project-create needs a path: it creates a NEW project directory." \
        "To claim a directory that already exists, use: ai-tools --project-claim [path]"

    local d
    d="$(realpath -m -- "${path}" 2>/dev/null)" || die "cannot resolve the path: ${path}"
    if [[ -e "${d}" ]]; then
        die "this path already exists: ${d}" \
            "--project-create only ever creates. Claim what is already there instead:" \
            "       ai-tools --project-claim ${d}"
    fi

    # ONE directory is created -- the final component, never a path of them. The parent has to
    # exist already, and a parent that does not is refused rather than built.
    #
    # This is the verb's main safety property, not a limitation of it. `mkdir -p` turns a mistyped
    # path into a silently manufactured tree: `--project-create ~/Devlopment/app` would create the
    # typo, create the project inside it, claim it, and report success, leaving the operator with
    # a working project nobody meant to make in a directory nobody meant to make. Requiring the
    # parent means a typo surfaces as a refusal that names the missing directory. It also removes
    # every question that a multi-component create raises: which components were created, which to
    # vet against the backstop, and what to remove when a later step fails.
    local parent="${d%/*}"; [[ -n "${parent}" ]] || parent=/
    if [[ ! -d "${parent}" ]]; then
        die "the parent directory does not exist: ${parent}" \
            "--project-create creates ONE directory, not a path of them, so a mistyped path is refused here rather than created. Check the path; if it is right, create the parent yourself and re-run:" \
            "       mkdir -p ${parent}"
    fi

    # The backstop on the target. Only one directory is created, so this is the whole surface: it
    # refuses a create that would MANUFACTURE a protected directory (`/efi` or `/lost+found` on a
    # host without one). It does not refuse a project nested INSIDE a protected tree -- descendants
    # pass by design here exactly as they do for a claim, or no project under a home would work.
    ai_tools_assert_safe_target "${d}" "project create" || exit 3

    # Reachability pre-flight. The parent exists by now, so this scans the project's real ancestry:
    # a blocker no grant may cover means the sandbox account could never enter this project, so the
    # create is refused BEFORE anything exists rather than leaving a directory to clean up. A
    # blocker the predicate DOES permit is not a refusal -- it becomes the claim's own traverse
    # opt-in below, which offers the grant and the exact setfacl for anything it cannot apply.
    reach_scan "${d}"
    if [[ -n "${REACH_BLOCKED}" ]]; then
        # State the blocker and why no grant covers it, and stop there. The claim's own version of
        # this refusal points at --sandbox-create, which does not apply here: that verb clones an
        # EXISTING repository into the sandbox area, and this verb's whole subject is a project
        # that does not exist yet, so there is nothing to name as its source.
        local why blocked_owner
        blocked_owner="$(stat -c '%U' "${REACH_BLOCKED}" 2>/dev/null || true)"
        if [[ -z "${blocked_owner}" ]]; then
            why="its owner cannot be read from here"
        elif [[ "${blocked_owner}" != "${OWNER_USER}" ]]; then
            why="it belongs to ${blocked_owner}, not to ${OWNER_USER}"
        else
            why="it is a protected system directory"
        fi
        headline_warn "WARNING: the agent could not reach a project here" \
            "the sandbox account cannot traverse ${REACH_BLOCKED} (${why}), so it could not enter a project created at ${d}. Nothing has been created. Create the project somewhere the sandbox account can reach: every parent directory has to be one it can already enter, or one you own and can grant traverse on."

        # One alternative is offered, and only after it has been CHECKED on this host rather than
        # assumed: the owner's home is the usual reachable location, but whether it is depends on
        # the ancestry above it, which differs per host. A suggestion that cannot be verified is
        # not made at all.
        local home_dir candidate
        home_dir="$(getent passwd "${OWNER_USER}" 2>/dev/null | cut -d: -f6)"
        if [[ -n "${home_dir}" && -d "${home_dir}" ]]; then
            candidate="${home_dir%/}/${d##*/}"
            reach_scan "${candidate}"
            if [[ -z "${REACH_BLOCKED}" && ! -e "${candidate}" ]]; then
                say ""
                say "  this location is reachable:"
                say "      ${C_BOLD}ai-tools --project-create ${candidate}${C_RST}"
            fi
        fi
        die "project create stopped -- the agent could not reach a project at that location"
    fi

    # ── Review block: the creation steps, then ONE default-NO confirm covering the whole
    # operation. The claim that follows prints its own review but does not ask again (it is
    # passed --yes, the same delegated-claim contract the launch wrapper uses); its scoped
    # opt-ins -- secret lockdown, .git history, ancestor traversal -- still ask on their own
    # terms. ──
    headline "Create project" "${d}" \
        "This creates the directory, initializes an empty git repository in it, writes a README.md, and then claims it -- which grants the sandbox account group access to the tree. One confirmation covers all of that; the secret-lockdown, git-history and parent-traversal questions are asked separately below."
    say ""
    say "  pending:"
    say "    - create ${d}"
    say "    - initialize an empty git repository"
    say "    - write README.md"
    say "    - claim the project -- the claim reviews its own steps below"
    say ""
    ${ASSUME_YES} || confirm "Create and claim this project?" n || die "aborted"

    # ── Apply ──
    headline "Creating the project" "${d}"
    run_as_owner mkdir -- "${d}" || die "could not create ${d}"
    say "    created ${d}"
    ai_tools_log_info "created project directory ${d}"

    # Plain `git init`, so the operator's own init.defaultBranch decides the branch name rather
    # than this tool holding an opinion about it. run_as_owner passes -H, so it is the TARGET's
    # git config that is read on a --for run.
    if run_as_owner git init -q -- "${d}"; then
        say "    git: initialized an empty repository"
    else
        warn "git init failed -- the directory is created but is not a git repository"
    fi

    # The basename verbatim, with no prettifying: a project skeleton is a different feature and
    # would need an opinion this tool should not hold. Written through `tee` as the owner, since a
    # shell redirect here would create the file as the INVOKER on a --for run.
    if printf '# %s\n' "${d##*/}" | run_as_owner tee -- "${d}/README.md" >/dev/null; then
        say "    wrote README.md"
    else
        warn "could not write ${d}/README.md (continuing)"
    fi

    # The claim runs unchanged on the new tree -- one implementation of what claiming means.
    cmd_project_claim --yes "${d}"
}

# positive_project_entries  -- print each allowed-projects entry that names a real,
# resolvable project directory (canonicalized), one per line, skipping blanks, comments,
# and '!' exclusions. Read with the shared config grammar so it agrees with cmd_list and
# the launch wrapper on what a line denotes. Stale (unresolvable) lines are omitted -- they
# name nothing on disk, so they can neither be nor contain an unclaim target.
positive_project_entries() {
    local entry dir
    [[ -f "${ALLOWLIST}" ]] || return 0
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
        ai_tools_conf_path_entry "${entry}" || continue
        entry="${_ai_tools_conf_value}"
        [[ "${entry}" == '!'* ]] && continue
        dir="$(realpath -e "${entry}" 2>/dev/null)" || continue
        printf '%s\n' "${dir}"
    done < "${ALLOWLIST}"
}

# covered_by_project <dir>  -- 0 when <dir> is at or under a positive allowed-projects entry in the
# invoking operator's own allowlist, honoring '!' exclusions (an exclusion wins). The CLI front-line
# for the per-project verbs (reclaim, lockdown): a path outside every claimed project is refused up
# front with a clear message, not a silent helper no-op. Scoped to the operator's own allowlist like
# every other CLI read; the root helpers re-check coverage (multi-operator) independently. Mirrors
# operator.lib's ai_tools_allowlist_covers.
covered_by_project() {
    local d="$1" entry val dir covered=1
    [[ -f "${ALLOWLIST}" ]] || return 1
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
        ai_tools_conf_path_entry "${entry}" || continue
        val="${_ai_tools_conf_value}"
        if [[ "${val}" == '!'* ]]; then
            val="${val#!}"; val="${val%/}"
            # SC2053: the unquoted RHS is the operator-owned glob pattern (see shellcheck.rule.md).
            [[ "${d}" == ${val} ]] && return 1                                  # exclusion wins
            [[ "${val}" != *'*'* && "${d}" == "${val}/"* ]] && return 1
        else
            dir="$(realpath -e "${val}" 2>/dev/null)" || continue
            [[ "${d}" == "${dir}" || "${d}" == "${dir}/"* ]] && covered=0
        fi
    done < "${ALLOWLIST}"
    return "${covered}"
}

# unclaim_one <dir> <group|""> <hint> [helper-flag...]  -- revert one claimed project. Order
# matters: revert
# the SELinux label first (keeps the invariant "labelled => allowlisted"), then run the
# filesystem hand-back WHILE THE ALLOWLIST ENTRY IS STILL PRESENT (ai-tools-unclaim refuses a
# target not in allowed-projects), and only then drop the two registries. <group> empty means
# "unregister only, leave permissions"; <hint> non-empty prints the manual hand-back command
# (used when the hand-back was wanted but could not run). Best-effort throughout: a step warns
# with its manual command and never aborts the pass.
unclaim_one() {
    local d="$1" group="$2" hint="$3"; shift 3
    local flags=""; (( $# )) && flags=" $*"
    if command -v sudo >/dev/null 2>&1 \
            && command -v getenforce >/dev/null 2>&1 \
            && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
        run_relabel "${d}" --remove \
            || warn "could not revert SELinux label -- run: sudo ${RELABEL_BIN} --remove ${d}"
    fi
    if [[ -n "${group}" ]]; then
        if run_unclaim "${d}" "${group}" "$@"; then
            ok "handed ${d} back to group ${group}, agent write access removed"
        else
            warn "could not hand the files back -- run it by hand:"
            say  "      ${C_BOLD}sudo ${UNCLAIM_BIN} ${d} ${group}${flags}${C_RST}"
        fi
    elif [[ -n "${hint}" ]]; then
        say  "      run it later with: ${C_BOLD}sudo ${UNCLAIM_BIN} ${d} <group>${flags}${C_RST}"
    fi
    unreg_safedir "${d}"
    unreg_allow "${d}"
    ok "unclaimed ${d}"
    ai_tools_log_info "unclaimed project ${d}"
}

# residue_scan <dir>  -- fill RESIDUE and RESIDUE_SKIPPED with every path under <dir> that still
# carries ai-tools ownership or group: the on-disk fingerprint of a claim. RESIDUE holds what the
# default helper walk reaches, RESIDUE_SKIPPED what only --full does; .git counts as reachable
# because the helper reverts it in a dedicated pass regardless of the skip list. Read-only and
# unprivileged, so it is a PREVIEW: the helper re-derives the same predicate as root, where it
# also sees the ACL-only paths this scan cannot cheaply detect and the paths this operator cannot
# traverse. Under-reporting is the safe direction -- the gate it feeds only ever decides whether
# there is anything to offer, never what may be touched.
residue_scan() {
    local d="$1" hit
    RESIDUE=(); RESIDUE_SKIPPED=()
    ai_tools_skip_find_expr sweep 2>/dev/null || true
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        if [[ "${hit}" != "${d}/.git/"* && "${hit}" != "${d}/.git" ]] \
                && under_skip_listed_name "${d}" "${hit}"; then
            RESIDUE_SKIPPED+=("${hit}")
        else
            RESIDUE+=("${hit}")
        fi
    done < <(find "${d}" -xdev \
                  '(' -user "${SANDBOX_USER}" -o -group "${SANDBOX_GROUP}" ')' \
                  '(' -type d -o -type f ')' -print 2>/dev/null)
}

# resolve_handback_group <group-opt>  -- decide the filesystem hand-back's target group. It has
# TWO results and sets both as globals in the CALLER's shell:
#   HANDBACK_GROUP  the target group; empty means "unregister only, leave permissions alone".
#   HANDBACK_HINT   non-empty when a hand-back was wanted but cannot run, so the caller prints
#                   the manual command instead of silently doing nothing.
# Globals, not stdout, precisely BECAUSE there are two: a `$(...)` capture runs the function in a
# subshell, where the second result is lost -- and reading it back under `set -u` aborts the whole
# unclaim before it touches anything. Prompts draw on /dev/tty and warnings on stderr, so a caller
# needs neither redirection nor a capture.
# --group answers both questions at once (whether to hand back, and to which group), so an
# automated run never depends on the prompt's no-terminal fallback quietly picking the invoking
# user's group. Without it the default-YES confirm and the user->group prompt run as before.
HANDBACK_GROUP=""
HANDBACK_HINT=""
resolve_handback_group() {
    local group_opt="$1" hb_user
    HANDBACK_GROUP=""
    HANDBACK_HINT=""
    if [[ -n "${group_opt}" ]]; then
        if command -v sudo >/dev/null 2>&1; then
            HANDBACK_GROUP="${group_opt}"
        else
            warn "sudo not found -- cannot hand the files back automatically"
            HANDBACK_HINT=1
        fi
        return 0
    fi
    # Default YES: the natural completion of an unclaim. Still confirmed, because it rewrites
    # ownership and permissions across the tree.
    if confirm "Hand the files back to a group and remove the agent's write access?" y; then
        hb_user="$(ask "  Hand the files to which user's group?" "${OWNER_USER}")"
        if ! HANDBACK_GROUP="$(id -gn "${hb_user}" 2>/dev/null)"; then
            warn "no such user '${hb_user}' -- skipping the filesystem hand-back"
            HANDBACK_GROUP=""; HANDBACK_HINT=1
        elif ! command -v sudo >/dev/null 2>&1; then
            warn "sudo not found -- cannot hand the files back automatically"
            HANDBACK_GROUP=""; HANDBACK_HINT=1
        fi
    fi
    return 0
}

# cmd_unclaim_unlisted <dir> <force> <full> <dry> <assume-yes> <group-opt>  -- the UNRELATED
# branch: no allowlist entry covers <dir>. Detection guides; only --force acts, and even then the
# helper touches a path solely while it still carries the ai-tools fingerprint, so running this on
# a directory that was never claimed changes nothing at all. That per-path gate -- not any
# conservatism about which bits to write -- is what makes the mode safe on a mistyped path: what
# it DOES to a path it accepts is identical to a registered unclaim.
cmd_unclaim_unlisted() {
    local d="$1" force="$2" full="$3" dry="$4" assume_yes="$5" group_opt="$6"

    ai_tools_assert_safe_target "${d}" "project unclaim" || exit 3
    # A sandbox clone has its own lifecycle verb, which also removes the clone itself.
    if [[ "${d}" == "${SANDBOX_ROOT}/"* ]]; then
        die "that is a sandbox clone: ${d}" \
            "       remove it with: ai-tools --sandbox-remove ${d}"
    fi

    residue_scan "${d}"
    local n_res="${#RESIDUE[@]}" n_skip="${#RESIDUE_SKIPPED[@]}"
    if (( n_res == 0 && n_skip == 0 )); then
        die "nothing to unclaim here: ${d}" \
            "       it is not a registered project, and nothing in it carries ai-tools ownership or group" \
            "       list your registered projects with: ai-tools --list"
    fi

    local extra=""
    (( n_skip )) && extra=", plus ${n_skip} more under skip-listed directories (--full reaches those)"

    # Detection GUIDES but never lowers the gate: the fingerprint improves the message, --force
    # still authorizes, and the confirm below still executes.
    if [[ "${force}" != true ]]; then
        ai_tools_msg_notice \
            "ai-tools: not a registered project, but it carries ai-tools permissions:" \
            "${d}" \
            "${n_res} path(s) owned by or grouped to ${SANDBOX_USER}${extra}." \
            "This looks like a claimed project copied or moved here without unclaiming. To normalize its permissions without registering it, re-run with --force:"
        say ""
        say "   preview:  ${C_BOLD}ai-tools --project-unclaim --force --dry-run ${d}${C_RST}"
        say "   apply:    ${C_BOLD}ai-tools --project-unclaim --force ${d}${C_RST}"
        say "   see:      ${C_BOLD}man ai-tools${C_RST}"
        exit 0
    fi

    if [[ "${dry}" == true ]]; then
        section "Dry run -- nothing is changed"
        say "  ${d}"
        say ""
        say "  ${n_res} path(s) the default walk reaches:"
        path_detail_lines "${RESIDUE[@]}"
        if (( n_skip )); then
            say ""
            say "  ${n_skip} path(s) under skip-listed directories, reached only with --full:"
            path_detail_lines "${RESIDUE_SKIPPED[@]}"
        fi
        say ""
        say "  ${C_DIM}the helper re-derives this as root, where it also sees ACL-only paths${C_RST}"
        say "  ${C_DIM}and any path this account cannot traverse${C_RST}"
        exit 0
    fi

    headline_warn "WARNING: unclaim an unregistered tree" \
        "${d} is NOT a registered project. Only paths still carrying ai-tools ownership, group, or ACL are changed; every other path is left untouched." \
        "On each matching path it clears the ACLs, regroups to the target group and removes group write -- landing on 640, or 750 where the owner has execute -- clears the setgid bit and resets the SELinux label. World access, which the claim removed, is NOT restored. The previous permissions are recorded nowhere, so this is IRREVERSIBLE. Back up first. See: man ai-tools"
    say ""
    say "    ${n_res} path(s)${extra}"
    path_listing "path(s)" "${RESIDUE[@]}"
    say ""

    # Heavy trees: informational unless --full was asked for. With --full the operator has already
    # recorded the intent on the command line, so the confirm defaults YES -- an automated run
    # carries through on that default while an interactive one still sees and answers it.
    local -a helper_flags=(--unlisted)
    if (( n_skip )); then
        if [[ "${full}" == true ]]; then
            headline_warn "Skip-listed directories (--full)" \
                "${n_skip} path(s) carrying ai-tools ownership or group sit under skip-listed directory names (build output, dependencies, caches). --full includes them in this pass."
            path_listing "path(s)" "${RESIDUE_SKIPPED[@]}"
            say ""
            confirm "Include these ${n_skip} path(s) under skip-listed directories?" y \
                && helper_flags+=(--full)
        else
            headline_warn "NOTICE: residue under skip-listed directories" \
                "${n_skip} path(s) carrying ai-tools ownership or group sit under skip-listed directory names (build output, dependencies, caches). This pass leaves them untouched; add --full to include them."
            path_detail_lines "${RESIDUE_SKIPPED[@]:0:3}"
            (( n_skip > 3 )) && say "        ${C_DIM}... and $(( n_skip - 3 )) more${C_RST}"
            say ""
        fi
    fi

    # The one decision --force does not make for you. -y pre-answers it, the same explicit
    # per-invocation convention as --project-claim -y.
    if [[ "${assume_yes}" != true ]]; then
        confirm "Unclaim this unregistered tree?" n || die "aborted"
    fi

    local hb_group hb_hint
    resolve_handback_group "${group_opt}"
    hb_group="${HANDBACK_GROUP}"; hb_hint="${HANDBACK_HINT}"
    if [[ -z "${hb_group}" ]]; then
        [[ -n "${hb_hint}" ]] \
            && say "      run it later with: ${C_BOLD}sudo ${UNCLAIM_BIN} ${d} <group> ${helper_flags[*]}${C_RST}"
        die "nothing to do without a hand-back group -- there are no registries to drop for an unregistered tree"
    fi

    if run_unclaim "${d}" "${hb_group}" "${helper_flags[@]}"; then
        ok "normalized ${d} to group ${hb_group}, ai-tools access removed"
        ai_tools_log_info "unclaimed unregistered tree ${d} (group -> ${hb_group})"
    else
        warn "could not normalize the tree -- run it by hand:"
        say  "      ${C_BOLD}sudo ${UNCLAIM_BIN} ${d} ${hb_group} ${helper_flags[*]}${C_RST}"
        exit 1
    fi
}

# cmd_project_unclaim [path]  -- undo an in-place claim (default: cwd): revert the SELinux
# label, drop both registries, and (default-yes confirm) hand the tree's filesystem back to a
# target group with the agent's write access revoked. The directory itself is left on disk. The
# filesystem hand-back (ai-tools-unclaim) clears the agent ACL + default ACL, regroups every
# eligible file to the target group, and removes group write (660->640, 770->750, 400 stays 400).
# The target group defaults to the invoking user's own group; any other system user can be named.
#
# The path is classified against allowed-projects into five outcomes, so unclaim only ever
# modifies permissions where something authorizes it:
#   EXACT       the path is itself a claimed project -- unclaim it.
#   ANCESTOR    claimed projects are nested under it -- list them and, behind a single default-NO
#               warning, unclaim each, outermost first.
#   DESCENDANT  the path sits INSIDE a claimed project -- refuse, naming the nearest claimed
#               parent (the longest matching entry) and the command that does work.
#   UNRELATED + residue   no allowlist entry covers it, but it still carries the ai-tools
#               fingerprint: a claimed project copied or moved here and never unclaimed. Detection
#               only GUIDES; acting needs an explicit --force, which swaps the allowlist gate for
#               a per-path residue gate in the helper.
#   UNRELATED, clean      refuse -- nothing here was ever claimed, so there is nothing to undo.
# A protected system path is refused up front. For a registered project this only guards a
# hand-edited allowlist (claim/setgid/setfacl never let one become a claimed project), whose
# cleanup ai-tools --list reports; --force never relaxes it.
cmd_project_unclaim() {
    # --force gates on the on-disk fingerprint instead of allowlist membership; it never relaxes
    # the protected-paths backstop, the owner guard, or the secret/'!' skips. -y/--yes pre-answers
    # the default-NO confirm in EVERY mode -- the registered project's, the ancestor batch's, and
    # --force's -- the same explicit-flag convention as --project-claim -y; it never answers the
    # hand-back or skip-listed questions, which ask on their own terms. --group names the hand-back
    # group outright, so a script never depends on the prompt's no-tty fallback -- and it works in
    # both modes.
    local a path="" force=false full=false dry=false assume_yes=false group_opt="" want_group=false
    for a in "$@"; do
        if ${want_group}; then group_opt="${a}"; want_group=false; continue; fi
        case "${a}" in
            --force)      force=true ;;
            --full)       full=true ;;
            -n|--dry-run) dry=true ;;
            -y|--yes)     assume_yes=true ;;
            --group)      want_group=true ;;
            --group=*)    group_opt="${a#--group=}" ;;
            -*) die "unknown --project-unclaim option: ${a}" \
                    "       allowed: --force, --full, -n/--dry-run, -y/--yes, --group <group>" ;;
            *)  if [[ -z "${path}" ]]; then path="${a}"
                else die "--project-unclaim takes a single path"; fi ;;
        esac
    done
    ${want_group} && die "--group needs a group name"
    if [[ -n "${group_opt}" ]] && ! getent group "${group_opt}" >/dev/null 2>&1; then
        die "no such group: ${group_opt}"
    fi
    if ${dry} && ! ${force}; then
        die "-n/--dry-run applies to --force only" \
            "       a registered project's unclaim previews itself: it lists what it will do and asks before acting"
    fi

    local d; d="$(resolve_dir "${path:-$PWD}")"
    [[ -d "${d}" ]] || die "not a directory: ${d}"

    # Classify d: exact entry, ancestor of entries, descendant of one, or unrelated.
    local -a entries=() targets=()
    local e
    while IFS= read -r e; do [[ -n "${e}" ]] && entries+=("${e}"); done \
        < <(positive_project_entries)
    local mode=unrelated nearest=""
    for e in "${entries[@]:-}"; do
        [[ "${e}" == "${d}" ]] && { mode=exact; targets=("${d}"); break; }
    done
    if [[ "${mode}" == unrelated ]]; then
        for e in "${entries[@]:-}"; do
            [[ "${e}" == "${d}/"* ]] && targets+=("${e}")
        done
        if (( ${#targets[@]} )); then
            mode=ancestor
            # Outermost first: a parent path sorts before every path nested in it (it is their
            # prefix), so a containing project is handed back before one inside it. Each still
            # needs its own registry and label drop, so a nested entry is never skipped.
            mapfile -t targets < <(printf '%s\n' "${targets[@]}" | sort)
        fi
    fi
    if [[ "${mode}" == unrelated ]]; then
        # Nearest claimed parent: the LONGEST entry that is a prefix of d. With both /a and /a/b
        # claimed, /a/b/c belongs to /a/b. One length comparison -- no tree, no traversal.
        for e in "${entries[@]:-}"; do
            if [[ "${d}" == "${e}/"* ]] && (( ${#e} > ${#nearest} )); then nearest="${e}"; fi
        done
        [[ -n "${nearest}" ]] && mode=descendant
    fi

    if [[ "${mode}" == descendant ]]; then
        die "this path is inside a claimed project, not a project itself: ${d}" \
            "       the claimed project is: ${nearest}" \
            "       unclaim that instead: ai-tools --project-unclaim ${nearest}"
    fi

    if [[ "${mode}" == unrelated ]]; then
        cmd_unclaim_unlisted "${d}" "${force}" "${full}" "${dry}" "${assume_yes}" "${group_opt}"
        return
    fi

    # Protected-path front line: never modify permissions on a protected system path. Guard
    # each MODIFICATION target (in ancestor mode the search root may be protected, e.g. /home,
    # while the projects nested under it are not).
    local t
    for t in "${targets[@]}"; do
        ai_tools_assert_safe_target "${t}" "project unclaim" || exit 3
    done

    # --force is about reaching a tree the allowlist does not cover; here one does. Say so
    # rather than silently ignoring the flag, and name the project that made it unnecessary.
    if ${force}; then
        ai_tools_msg_notice \
            "ai-tools: --force is not needed here -- this path is covered by the allowlist:" \
            "${targets[0]}" \
            "unclaiming it the normal way, which reverts the whole registered tree."
    fi

    if [[ "${mode}" == exact ]]; then
        section "Unclaim project"
        say "  ${d}"
        say "  ${C_DIM}(the directory itself is left on disk)${C_RST}"
        ${assume_yes} || confirm "Unclaim this project?" n || die "aborted"
    else
        headline_warn "WARNING: unclaim multiple projects" \
            "${d} is not itself a claimed project, but ${#targets[@]} claimed project(s) are nested under it." \
            "Unclaiming MODIFIES FILE PERMISSIONS AND OWNERSHIP in ALL of the projects listed below." \
            "The directories themselves are left on disk."
        for t in "${targets[@]}"; do printf '    %s\n' "${t}"; done
        say ""
        ${assume_yes} || confirm "Unclaim ALL ${#targets[@]} projects listed above?" n || die "aborted"
    fi

    # Filesystem hand-back: decided ONCE for the whole batch.
    local hb_group hb_hint
    resolve_handback_group "${group_opt}"
    hb_group="${HANDBACK_GROUP}"; hb_hint="${HANDBACK_HINT}"

    local -a helper_flags=()
    ${full} && helper_flags=(--full)

    for t in "${targets[@]}"; do
        unclaim_one "${t}" "${hb_group}" "${hb_hint}" "${helper_flags[@]}"
    done

    # Mixed tree: the registered projects are done, but ai-tools residue can still sit elsewhere
    # under this path (another copy, a leftover from a tree that was never registered). Reported
    # only when --force asked about residue in the first place, so the common path pays no scan.
    # The projects just unclaimed are no longer registered, so a re-run now classifies the whole
    # path as unrelated and the one command finishes the job.
    if ${force} && [[ "${mode}" == ancestor ]]; then
        residue_scan "${d}"
        local left=$(( ${#RESIDUE[@]} + ${#RESIDUE_SKIPPED[@]} ))
        if (( left )); then
            say ""
            ai_tools_msg_notice \
                "ai-tools: ${left} path(s) under this directory still carry ai-tools ownership or group, outside the projects just unclaimed." \
                "Re-run to normalize them now that nothing here is registered:"
            say ""
            say "   ${C_BOLD}ai-tools --project-unclaim --force --dry-run ${d}${C_RST}"
        fi
    fi
}

# sandbox_finalize <dst>  -- the access-granting tail of every sandbox create, run only
# AFTER the clone exists: allowlist (the lockdown scan acts only on an allowlisted path;
# rolled back on a failed gate), the secret-lockdown gate, then -- strictly past the
# gate -- normalize (pruning the locked paths), relabel, and register. FAIL CLOSED: a
# declined or failed gate leaves the clone on disk but private to the operator -- cloned
# under umask 077, so nothing in it is group-readable -- not normalized, not relabelled,
# not registered, with a guard CLAUDE.md dropped and the resume command printed.
# Re-running --sandbox-create on the existing clone path resumes here.
sandbox_finalize() {
    local dst="$1"
    reg_allow "${dst}"
    if ! secret_gate "${dst}"; then
        unreg_allow "${dst}"
        drop_lockdown_guard "${dst}"
        warn "sandbox not secured -- the clone stays private to you:" \
             "not group-accessible, not registered; the agent has no access to it"
        say  "    handle the secrets, then finish the create:"
        say  "      ${C_BOLD}ai-tools --sandbox-create ${dst}${C_RST}"
        die "sandbox create stopped -- secrets not locked down"
    fi
    clear_lockdown_guard "${dst}"
    normalize_clone "${dst}" "${SECRET_GATE_LOCKED[@]}"
    say "    access: group ${SANDBOX_GROUP} rwX + setgid dirs (locked secrets stay private)"
    relabel_clone "${dst}"
    reg_safedir "${dst}"
    say ""
    ok "sandbox ready: ${dst}"
    ai_tools_log_info "sandbox secured and registered: ${dst}"

    section "Next"
    say "  run the agent  : ${C_BOLD}cd ${dst} && claude${C_RST}"
    say "  push its work  : ${C_BOLD}ai-tools --sandbox-push ${dst}${C_RST}"
    say "  ${C_YEL}shallow${C_RST}        : push-only -- never git pull/fetch here, or you pull the full history"
}

# sandbox_default_branch <from>  -- echo the DEFAULT sandbox branch name for a fork of <from>:
# "sandbox/<leaf>", where <leaf> is <from>'s last path component (so a fork of develop defaults to
# sandbox/develop, and origin/feature/x to sandbox/x). The literal "sandbox" carries NO host,
# machine, or operator identity by design -- the branch is pushed to a shared remote, so the default
# must leak nothing about who or where created it. It is only a DEFAULT: the operator overrides the
# whole name with --branch (or the prompt), and any valid git ref is accepted, so the sandbox
# workflow is not tied to this shape. Pure; unit-tested (tests/unit/sandbox.sh).
sandbox_default_branch() {
    printf 'sandbox/%s' "${1##*/}"
}

# sandbox_resolve_base <top> <remote> <base>  -- echo a ref naming <base>'s tip in the source
# repo, or return 1 if none does. Tries <base> as a local branch first, then the remote-tracking
# form <remote>/<base> (so a base that lives only on the remote -- e.g. master while you are on
# develop -- resolves without a local checkout), then any other commit-ish (a tag or SHA). This is
# what lets the sandbox branch be forked from a base OTHER than the current HEAD. Read-only (no
# ref is created here); unit-tested against a fixture repo (tests/unit/sandbox.sh).
sandbox_resolve_base() {
    local top="$1" remote="$2" base="$3"
    git -C "${top}" rev-parse --verify --quiet "refs/heads/${base}" >/dev/null 2>&1 \
        && { printf '%s' "${base}"; return 0; }
    git -C "${top}" rev-parse --verify --quiet "refs/remotes/${remote}/${base}" >/dev/null 2>&1 \
        && { printf 'refs/remotes/%s/%s' "${remote}" "${base}"; return 0; }
    git -C "${top}" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 \
        && { printf '%s' "${base}"; return 0; }
    return 1
}

# cmd_sandbox_create [path] [--from <ref>] [--branch <name>] [--dir <name>] [-y|--yes]
#   -- create or reuse a sandbox branch, shallow-clone it PRIVATELY (umask 077) into SANDBOX_ROOT,
#   then hand off to sandbox_finalize: secret lockdown first, and only past that gate normalize +
#   relabel + register (fail-closed otherwise). Pointed at an EXISTING clone under SANDBOX_ROOT, it
#   resumes sandbox_finalize on it (flags are then irrelevant) -- the recovery path for a create
#   whose gate was declined or failed.
#
#   Every input has a default and an optional flag, so the command is fully scriptable and the
#   prompts are only the interactive fallback (a flag skips its prompt; no flag + no tty takes the
#   default). The branch is a FULL git ref of any shape -- the "sandbox/<leaf>" default is a
#   convention, not a required structure (see sandbox_default_branch); it is validated with
#   git check-ref-format, never silently rewritten. -y/--yes pre-answers the create confirm only;
#   the secret-lockdown and .git gates in sandbox_finalize still apply (messaging.rule.md doctrine).
cmd_sandbox_create() {
    local o_path="" o_from="" o_branch="" o_dir="" o_yes=false
    local have_from=false have_branch=false have_dir=false
    # _need_value <flag> [remaining args...]: die unless a value follows the flag AND that value is
    # not itself option-shaped. A leading '-' is a mistyped flag far more often than a real ref or
    # directory name, and taking it at face value hands it to git as an option -- so the run would
    # fail with git's own parse error, which names neither this flag nor the value. Refused here,
    # where the message can name both, and before the push.
    _need_value() {
        local flag="$1"; shift
        (( $# )) || die "${flag} needs a value"
        [[ "$1" != -* ]] || die "${flag} needs a value, not another option: $1"
    }
    while (( $# )); do
        case "$1" in
            --from)   _need_value --from   "${@:2}"; o_from="$2";   have_from=true;   shift 2 ;;
            --branch) _need_value --branch "${@:2}"; o_branch="$2"; have_branch=true; shift 2 ;;
            --dir)    _need_value --dir    "${@:2}"; o_dir="$2";    have_dir=true;    shift 2 ;;
            -y|--yes) o_yes=true; shift ;;
            --)       shift ;;
            -*)       die "unknown option: $1 (see: ai-tools --help)" ;;
            *)        [[ -z "${o_path}" ]] || die "unexpected extra argument: $1"; o_path="$1"; shift ;;
        esac
    done
    local src; src="$(resolve_dir "${o_path:-$PWD}")"

    case "${src}/" in
        "${SANDBOX_ROOT}"/*)
            git -C "${src}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
                || die "not a git clone: ${src}"
            headline "Resume sandbox project" "${src}" \
                "securing and registering an existing clone"
            sandbox_finalize "${src}"
            return 0 ;;
    esac
    git -C "${src}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "not a git repository: ${src}"
    local top; top="$(git -C "${src}" rev-parse --show-toplevel)"
    local cur
    cur="$(git -C "${top}" symbolic-ref --short HEAD 2>/dev/null)" \
        || die "repository is in detached HEAD; check out a branch first: ${top}"

    local remote
    if git -C "${top}" remote | grep -qx "origin"; then
        remote="origin"
    else
        remote="$(git -C "${top}" remote | head -1)"
    fi
    [[ -n "${remote}" ]] || die "repository has no remote; the sandbox workflow needs one: ${top}"
    local remote_url; remote_url="$(git -C "${top}" remote get-url "${remote}")"

    headline "Create sandbox project" \
        "an isolated shallow clone of this repo, registered for the agent; work is pushed to a dedicated branch that you merge back"
    say "  source repo    : ${top}"
    say "  current branch : ${cur}"
    say "  remote         : ${remote}  ${C_DIM}${remote_url}${C_RST}"

    # Resolve every input BEFORE any push or checkout: a flag wins, else the prompt (interactive) or
    # the default (no tty). So an Enter-through reproduces the previous shape and a fully-flagged run
    # needs no terminal, while a bad value stops here rather than after the push.

    # Base to fork from -- defaults to the current branch, but can be any base (e.g. main for a
    # hotfix while you sit on develop): a local branch, a <remote>/<base>, or any ref.
    local base
    if ${have_from}; then base="${o_from}"; else base="$(ask "Base branch to fork from" "${cur}")"; fi
    [[ -n "${base}" ]] || die "base branch cannot be empty"
    local base_ref
    base_ref="$(sandbox_resolve_base "${top}" "${remote}" "${base}")" \
        || die "base not found: ${base} (not a local branch, ${remote}/${base}, or a known ref)"

    # Sandbox branch -- a FULL git ref of any shape. Defaults to the convention sandbox/<leaf-of-base>
    # but the operator may enter anything (a flat name, a hotfix/x, or the old ai-tools/... form).
    # Validated with git check-ref-format and refused if invalid -- never silently rewritten.
    local br
    if ${have_branch}; then br="${o_branch}"
    else br="$(ask "Sandbox branch to create/track" "$(sandbox_default_branch "${base}")")"; fi
    [[ -n "${br}" ]] || die "sandbox branch cannot be empty"
    git check-ref-format "refs/heads/${br}" 2>/dev/null \
        || die "invalid branch name: ${br} (must be a valid git ref -- see git-check-ref-format(1))"

    local name
    if ${have_dir}; then name="${o_dir}"
    else name="$(ask "Sandbox directory name under ${SANDBOX_ROOT}" "$(basename "${top}")")"; fi
    # One component, and a real one: '.' and '..' pass the no-slash test but name the clone area
    # itself or its parent, where the next check would refuse them as "already exists" -- true, but
    # not what went wrong.
    [[ -n "${name}" && "${name}" != */* && "${name}" != . && "${name}" != .. ]] \
        || die "invalid directory name: ${name} (one path component, under ${SANDBOX_ROOT})"
    local dst="${SANDBOX_ROOT}/${name}"
    if [[ -e "${dst}" ]]; then
        say "    to finish securing/registering an earlier clone of this name:"
        say "      ${C_BOLD}ai-tools --sandbox-create ${dst}${C_RST}"
        die "destination already exists: ${dst}"
    fi
    [[ -d "${SANDBOX_ROOT}" ]] || die "sandbox area missing: ${SANDBOX_ROOT} -- run install first"

    # git silently ignores --depth for a clone from a local path, which would copy the FULL history
    # into the sandbox and defeat the isolation. Force the file:// transport for local-path remotes
    # so depth=1 is honored; network remotes (ssh/https) honor it natively and keep their URL.
    # Computed here (not after the confirm) so the preview shows the exact clone command.
    local clone_url="${remote_url}"
    case "${remote_url}" in
        /*|./*|../*) clone_url="file://$(realpath -m "${remote_url}")" ;;
    esac

    # If the branch already exists on the remote (a prior sandbox of this repo), reuse it rather
    # than force-pushing over it -- this resumes earlier work and never discards commits. To reset
    # it, delete the remote branch or pick a new leaf.
    local br_exists=false
    [[ -n "$(git -C "${top}" ls-remote --heads "${remote}" "${br}" 2>/dev/null)" ]] \
        && br_exists=true

    # Preview the ACTUAL commands, verbatim on their own lines (a long clone line overflows the
    # frame intact rather than wrapping -- see messaging.rule.md / console-command-formatting).
    say ""
    if ${br_exists}; then
        say "  will run (reusing existing remote branch ${br}; ${base} is NOT pushed over it):"
    else
        say "  will run:"
        say "    git branch -f ${br} ${base_ref}"
        say "    git push ${remote} ${br}"
    fi
    say "    git clone --depth=1 -b ${br} ${clone_url} ${dst}"
    say ""
    say "  then: lock down tip-commit secrets, grant the agent access, register the clone"
    # -y/--yes pre-answers this create confirm only (an auditable per-invocation flag, as elsewhere);
    # the secret-lockdown and .git gates in sandbox_finalize still prompt on their own terms.
    ${o_yes} || confirm "Create the sandbox clone?" y || die "aborted"

    if ${br_exists}; then
        ok "reusing existing remote branch ${br}"
    else
        git -C "${top}" branch -f "${br}" "${base_ref}"
        git -C "${top}" push "${remote}" "${br}"
        ok "pushed ${br} to ${remote}"
    fi

    # umask 077: the clone is born OWNER-ONLY, so the tip commit's files -- possibly checked-in
    # credentials -- are unreadable to the sandbox account (the setgid SANDBOX_ROOT already puts
    # them in group SANDBOX_GROUP) until the secret gate has run and normalize_clone deliberately
    # opens the non-secret paths.
    ( umask 077 && git clone --depth=1 -b "${br}" "${clone_url}" "${dst}" )
    ok "shallow-cloned into ${dst} (private until secured)"
    ai_tools_log_info "created sandbox clone ${dst} (branch ${br}, base ${base_ref}, remote ${remote})"

    sandbox_finalize "${dst}"
}

# cmd_sandbox_push [path]  -- push the sandbox clone's commits ahead of its upstream
# branch, after listing them and confirming. No-op when already up to date.
cmd_sandbox_push() {
    local d; d="$(resolve_dir "${1:-$PWD}")"
    require_sandbox_clone "${d}"
    local up
    up="$(git -C "${d}" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" \
        || die "no upstream configured for the current branch in ${d}"
    local n; n="$(git -C "${d}" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"

    section "Push sandbox work"
    say "  sandbox  : ${d}"
    say "  upstream : ${up}"
    if [[ "${n}" == "0" ]]; then
        ok "nothing to push (already up to date with ${up})"
        return 0
    fi
    say "  ${n} commit(s) to push:"
    git -C "${d}" --no-pager log --oneline '@{u}..HEAD' | sed 's/^/      /'
    confirm "Push ${n} commit(s) to ${up}?" y || die "aborted"
    git -C "${d}" push
    ok "pushed ${n} commit(s) to ${up}"
    ai_tools_log_info "pushed ${n} commit(s) from sandbox ${d} to ${up}"
}

# cmd_sandbox_remove [path]  -- delete a sandbox clone and unregister it, warning
# first about any unpushed commits. The remote branch is left intact.
cmd_sandbox_remove() {
    local d; d="$(resolve_dir "${1:-$PWD}")"
    require_sandbox_clone "${d}"
    section "Remove sandbox project"
    say "  ${d}"

    # require_sandbox_clone guarantees a git worktree; @{u} may be absent (no upstream) -> 0.
    local n; n="$(git -C "${d}" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    if [[ "${n}" != "0" ]]; then
        warn "${n} unpushed commit(s) will be lost (already-pushed work stays on the remote)"
        confirm "Discard ${n} unpushed commit(s) and remove ${d}?" n || die "aborted"
    else
        confirm "Remove ${d} and unregister it?" n || die "aborted"
    fi

    rm -rf "${d}"
    unreg_allow "${d}"
    unreg_safedir "${d}"
    ok "removed ${d} and unregistered it"
    ai_tools_log_info "removed sandbox ${d} and unregistered it"
    say "  ${C_DIM}remote branch left intact -- others may still merge it${C_RST}"
}

# cmd_lockdown [path] [-n|-y]  -- run ai-tools-lockdown (via sudo) on the project to
# revoke ai-tools' read access to secret files; clears any guard CLAUDE.md on a real
# (non-dry-run) success. -n/--dry-run and -y/--yes pass through to the helper.
cmd_lockdown() {
    local d="" a dry=false; local -a passthru=()
    for a in "$@"; do
        case "${a}" in
            -n|--dry-run) passthru+=("${a}"); dry=true ;;
            -y|--yes)     passthru+=("${a}") ;;
            -*)           die "unknown --lockdown option: ${a} (allowed: --dry-run, --yes)" ;;
            *)            if [[ -z "${d}" ]]; then d="${a}"; else die "--lockdown takes a single path"; fi ;;
        esac
    done
    d="$(resolve_dir "${d:-$PWD}")"
    [[ -d "${d}" ]] || die "not a directory: ${d}"
    covered_by_project "${d}" \
        || die "not a claimed project: ${d}" \
               "it is not at or under any project in your allowed-projects" \
               "       list your registered projects with: ai-tools --list"
    # No readable-path pre-check: /usr/local/libexec/ai-tools is 750 root:root, so the
    # projects user cannot even stat the helper -- only sudo (as root) can reach it.
    # If it is genuinely missing, sudo reports it and run_lockdown returns non-zero.
    section "Lock down project secrets"
    say "  ${d}"
    say "  ${C_DIM}secret-matching files -> 600, dirs -> 700, owner ${OWNER_USER}:${OWNER_GROUP}${C_RST}"
    if run_lockdown "${d}" "${passthru[@]}"; then
        ${dry} || clear_lockdown_guard "${d}"
        ok "lockdown done: ${d}"
        ${dry} || ai_tools_log_info "locked down secrets in ${d}"
    else
        die "lockdown failed for ${d}"
    fi
}

# cmd_reclaim [--full] [path]  -- hand agent-written files under the project (default: cwd) back to
# ${OWNER_USER}:${SANDBOX_GROUP} via ai-tools-reclaim (sudo). Reclaims the .git tree the per-session sweeps
# skip; run it before an ACL-unaware backup so ownership (not the per-project ACL) carries the
# operator's access into the copy. --full also reclaims the heavy trees the default run skips
# (node_modules, .venv, ...).
cmd_reclaim() {
    local d="" a full=false; local -a passthru=()
    for a in "$@"; do
        case "${a}" in
            --full) passthru+=("${a}"); full=true ;;
            -*)     die "unknown --reclaim option: ${a} (allowed: --full)" ;;
            *)      if [[ -z "${d}" ]]; then d="${a}"; else die "--reclaim takes a single path"; fi ;;
        esac
    done
    d="$(resolve_dir "${d:-$PWD}")"
    [[ -d "${d}" ]] || die "not a directory: ${d}"
    covered_by_project "${d}" \
        || die "not a claimed project: ${d}" \
               "it is not at or under any project in your allowed-projects" \
               "       list your registered projects with: ai-tools --list"
    section "Reclaim agent-written files"
    say "  ${d}${C_DIM}$(${full} && printf ' (--full: incl. node_modules, .venv, ...)')${C_RST}"
    say "  ${C_DIM}-> ${OWNER_USER}:${SANDBOX_GROUP} (secret-named files stay ${OWNER_USER}:${OWNER_GROUP} 600)${C_RST}"
    # The helper reports the outcome itself -- the pre-scan count, the one whole-set
    # confirm, then "handed back N" / "nothing to reclaim" / "declined" -- so no blanket
    # success line here: the CLI states only what actually happened.
    run_reclaim "${d}" "${passthru[@]}" || die "reclaim failed for ${d}"
    ai_tools_log_info "reclaim run for ${d}$(${full} && printf ' (full)')"
}

# cmd_relabel  -- reconcile each enabled agent's entrypoint after a toolchain change, via the root
# helper (sudo, no password: the dedicated fixed-path rule). Two steps, in this order:
#   1. VERIFY the entrypoint against the checksum its vendor signed and record it in that agent's
#      pin, which ai-tools-run compares the binary against at launch. Needs the host online, and
#      fails soft when it cannot reach the vendor; a MISMATCH fails the command.
#   2. RELABEL it to ai_tools_exec_t. An nvm-update installs a fresh agent binary that npm leaves
#      mislabelled (bin_t), so the domain transition stops firing and ai-tools-run refuses to
#      launch (fail-closed) until the label is restored.
# Takes no path -- the helper resolves the entrypoints from the agent manifests.
#
# The verb keeps the name it had when relabelling was its only step; why the two are one command
# is in .claude/rules/cli.rule.md.
cmd_relabel() {
    [[ "$#" -eq 0 ]] || die "--relabel takes no arguments"
    section "Reconcile the agent entrypoints (after a toolchain change)"
    say "  Verifies each agent binary against the checksum its vendor signed, then relabels"
    say "  it so the sandbox can confine the session; until then the agent refuses to launch."
    command -v sudo >/dev/null 2>&1 \
        || die "sudo not found -- cannot reconcile; run as root: ${RELABEL_ENTRYPOINT_BIN}"
    # Reaches the helper through the dedicated fixed-path NOPASSWD rule (the same one the
    # nvm-update timer uses), so this runs as root without a password prompt.
    if sudo "${RELABEL_ENTRYPOINT_BIN}"; then
        ok "entrypoints reconciled -- exit any running session and relaunch"
        ai_tools_log_info "reconciled the agent entrypoints (verify + relabel)"
    else
        die "reconcile failed -- see the message above"
    fi
}

# cmd_audit -- report what has refused, been rejected, been stranded or been flagged since a
# given time. A thin pass-through to the root helper, which does the reading and the rendering:
# the trail is 700 root:root, so there is nothing this unprivileged CLI could usefully do with
# it first. The helper's EXIT STATUS is propagated deliberately -- non-zero means findings --
# so `ai-tools --audit` is usable from cron or a login banner without parsing its output, the
# same contract --status already offers.
cmd_audit() {
    root_helper_reachable \
        || die "sudo not found -- cannot read the root-only trail; run as root: ${AUDIT_BIN}"
    run_root_helper "${AUDIT_BIN}" "$@"
}

# cmd_stop -- terminate every running agent session, through ai-tools-stop. Thin by design, and the
# thinness is the whole contract: the command takes no target and no authorization input, so there
# is nothing on this side to decide. What a stop reaches follows from membership of the sandbox
# account's cgroup slice, which only the root helper can read, and every remaining decision is a
# security decision that must not be made twice in two places. Option grammar is all that lives
# here. Why the command is shaped this way: docs/session-stop.md.
#
# The helper's EXIT STATUS propagates unchanged, so a caller reads one set of codes whichever side
# refused. They are listed in ai-tools(1) and are not restated here, so the two cannot drift.
#
# die_stop_usage -- refuse a --stop command line in the HELPER's exit-code space (2 = usage), not
# the CLI's own (die exits 1). Because cmd_stop propagates the helper's status, 2 is what a caller
# reading --stop's exit code is told a usage error is -- in ai-tools(1) and docs/session-stop.md
# alike -- and WHICH SIDE refused is an implementation detail of the ordering below, not something
# the caller asked about. Exiting 1 here would report the same mistake as one code from the CLI and
# another from a direct root call, and 1 already means "a process survived SIGKILL".
die_stop_usage() { ai_tools_log_error "$*"; ai_tools_msg_error "ai-tools: $*"; exit 2; }

cmd_stop() {
    local argument; local -a passthru=()
    for argument in "$@"; do
        case "${argument}" in
            # --all is accepted and inert; ai-tools(1) says why it exists at all.
            --all|-n|--dry-run|-y|--yes|--force) passthru+=("${argument}") ;;
            -*) die_stop_usage "unknown --stop option: ${argument}" \
                    "allowed: --all, --dry-run/-n, --yes/-y, --force" ;;
            # A PATH IS REFUSED HERE, NOT PASSED ON. The helper refuses it too -- that is the last
            # line, for a direct root call -- but the refusal has to happen on this side as well,
            # BEFORE the sudo below: a command that is going to be refused must not first prompt
            # for a password (the ordering rule --for follows). Why refusing beats ignoring is in
            # the helper's refuse_positional_argument.
            #
            # THIS TEXT IS A DELIBERATE TWIN of that function's, and the duplication is unavoidable:
            # the two run in different processes and the helper is 750 root:root, so neither can
            # source the other, while an operator meets whichever side refused. The two must say the
            # same thing and offer the same four commands -- change one, change both.
            #
            # The commands are printed PLAIN, ahead of die(): die() joins its arguments and wraps
            # them through the error emitter, which would break a command across lines
            # (messaging.rule.md).
            *)  printf '\n' >&2
                printf '  %s\n' \
                    "Terminate every session:    ai-tools --stop" \
                    "See what is running first:  ai-tools --stop --dry-run" \
                    "End one session cleanly:    /exit inside it, which runs its session-end handback" \
                    "Terminate one by hand:      sudo systemctl --user -M ${SANDBOX_USER}@.host stop <unit>" >&2
                printf '\n' >&2
                die_stop_usage "--stop takes no path: ${argument}. It TERMINATES every agent session on this host -- killing the process tree, so no session-end handback runs -- and has no per-project form, because a session is attributed to a project by the sandbox account's own user manager -- the account being stopped -- so that attribution is reported, never trusted to decide what a stop reaches." ;;
        esac
    done
    root_helper_reachable \
        || die "sudo not found -- a session runs in the sandbox account's cgroups, which only root can signal" \
               "run as root: ${STOP_BIN}"
    run_root_helper "${STOP_BIN}" "${passthru[@]}"
}

# cmd_providers  -- report the installed providers of both kinds and, for each, whether a
# session gets it and why. Read-only: it resolves through providers.lib.sh, the same resolver
# ai-tools-run and the toolchain layer use, so what it reports is what a session gets rather than
# a second reading of operator.conf. The resolver's refusals -- an untrusted manifest, an
# enabled-but-uninstalled name -- go to its stderr and are captured and shown here; at launch
# they reach only the terminal and journald.
cmd_providers() {
    [[ "$#" -eq 0 ]] || die "--providers takes no arguments"
    local providers_lib=/usr/local/lib/ai-tools/providers.lib.sh
    # shellcheck source=SCRIPTDIR/../lib/ai-tools/providers.lib.sh
    if ! source "${providers_lib}" 2>/dev/null \
            || ! declare -F ai_tools_enabled_agents >/dev/null 2>&1 \
            || ! declare -F ai_tools_provider_gate  >/dev/null 2>&1; then
        die "cannot load ${providers_lib} -- reinstall the ai-tools package"
    fi

    # The resolvers report every refusal on stderr; collect both kinds' into one file so they
    # are shown together at the end instead of interleaved with the listings.
    local refusals; refusals="$(mktemp)"

    # gate_line <conf-key> -- the gating decision for one kind, in the operator's terms.
    gate_line() {
        case "$(ai_tools_provider_gate "$1")" in
            allowlist) printf '%s in %s (an exact allowlist)' "$1" "${AI_TOOLS_OPERATOR_CONF}" ;;
            untrusted) printf '%sdefault_enable only -- %s is ignored (not root-owned, or writable by group/other)%s' \
                           "${C_YEL}" "${AI_TOOLS_OPERATOR_CONF}" "${C_RST}" ;;
            *)         printf 'default_enable (no %s in %s)' "$1" "${AI_TOOLS_OPERATOR_CONF}" ;;
        esac
    }
    # agent_detail <name> -- an agent manifest's own description of itself. Empty for a manifest
    # the trust predicate refuses; that is the refusals block's story to tell.
    agent_detail() {
        local package launcher handback
        package="$( ai_tools_agent_manifest_field "$1" npm_package || true)"
        launcher="$(ai_tools_agent_manifest_field "$1" launcher    || true)"
        handback="$(ai_tools_agent_manifest_field "$1" handback    || true)"
        [[ -n "${package}" ]] || return 0
        printf '%s%s%s' "${package}" "${launcher:+, launcher ${launcher}}" \
            "${handback:+, handback ${handback}}"
    }
    # kind_block <label> <conf-key> <manifest-dir> <resolver> <detail-fn|-> -- one section per
    # provider kind: the gating decision, then every INSTALLED manifest marked enabled or
    # disabled. Installed comes from the directory listing and enabled from the resolver, so a
    # manifest the resolver refuses shows as disabled with its reason in the refusals block.
    kind_block() {
        local label="$1" conf_key="$2" dir="$3" resolver="$4" detail_fn="$5"
        local enabled manifest name detail state colour found=0
        section "${label}"
        say "  enabled by: $(gate_line "${conf_key}")"
        # cut -f1 reads both resolvers the same way (agents print further TAB-separated fields).
        enabled="$("${resolver}" 2>>"${refusals}" | cut -f1)"
        for manifest in "${dir}"/*.conf; do
            [[ -e "${manifest}" ]] || continue
            found=1
            name="${manifest##*/}"; name="${name%.conf}"
            detail=""; [[ "${detail_fn}" == - ]] || detail="$("${detail_fn}" "${name}")"
            if grep -qxF -- "${name}" <<<"${enabled}"; then
                state=enabled;  colour="${C_GRN}"
            else
                state=disabled; colour="${C_DIM}"
            fi
            printf '    %s%-8s%s %-16s %s\n' "${colour}" "${state}" "${C_RST}" "${name}" "${detail}"
        done
        (( found )) || say "    (none installed)"
    }

    kind_block "Agents"       AI_TOOLS_AGENTS       "${AI_TOOLS_AGENTS_DIR}" \
               ai_tools_enabled_agents agent_detail
    kind_block "Integrations" AI_TOOLS_INTEGRATIONS "${AI_TOOLS_INTEGRATIONS_DIR}" \
               ai_tools_enabled_integrations -

    # The enabled integration names, reused by the SELinux advisory below. stderr is dropped here
    # (the integrations kind_block already captured any refusals into ${refusals}).
    local enabled_integrations
    enabled_integrations="$(ai_tools_enabled_integrations 2>/dev/null | cut -f1)"

    # SELinux policy groups -- reported only where the MAC layer is active (Enforcing/Permissive);
    # a DAC-only or SELinux-absent host skips the whole block. Read-only and unprivileged: getenforce
    # and `semodule -l` read without root (the same read the confinement preflight does as the
    # sandbox account); if the store is not readable unprivileged it degrades to a pointer rather
    # than misreporting. The group set + predicates come from the shared registry.
    selinux_groups_block() {
        local enforce; enforce="$(getenforce 2>/dev/null || true)"
        [[ -n "${enforce}" && "${enforce}" != "Disabled" ]] || return 0
        command -v semodule >/dev/null 2>&1 || return 0
        local groups_lib=/usr/local/lib/ai-tools/selinux-groups.lib.sh
        # shellcheck source=SCRIPTDIR/../lib/ai-tools/selinux-groups.lib.sh
        source "${groups_lib}" 2>/dev/null \
            && declare -F ai_tools_selinux_group_name >/dev/null 2>&1 || return 0

        # Read the loaded module list FIRST. If it is not readable unprivileged (common: the policy
        # store is root-only on many hosts), omit the whole section rather than print a section that
        # only says "cannot read" -- the group/dependency reporting below all needs this list, so
        # without it there is nothing accurate to show. `sudo ai-tools-admin selinux list-groups` is
        # where an operator inspects policy groups.
        local modules
        { modules="$(semodule -l 2>/dev/null)" && [[ -n "${modules}" ]]; } || return 0
        group_loaded() { grep -qxF "ai_tools_$1" <<<"${modules}"; }

        section "SELinux policy groups (${enforce})"

        if grep -qxF 'ai_tools' <<<"${modules}"; then
            say "  core module ai_tools: ${C_GRN}loaded${C_RST}"
        else
            say "  core module ai_tools: ${C_DIM}not loaded (DAC-only confinement)${C_RST}"
        fi
        local entry gname loaded_any=0
        for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
            gname="$(ai_tools_selinux_group_name "${entry}")"
            if group_loaded "${gname}"; then
                printf '    %sloaded%s   %s -- %s\n' "${C_GRN}" "${C_RST}" \
                    "${gname}" "$(ai_tools_selinux_group_desc "${entry}")"
                loaded_any=1
            fi
        done
        (( loaded_any )) || say "    ${C_DIM}(no optional groups loaded)${C_RST}"
        say "    ${C_DIM}toggle with: sudo ai-tools-admin selinux enable-group <name>${C_RST}"

        # dotnet <-> tmpmap: dotnet restore/build mmaps a shared-memory file under /tmp, which
        # needs the 'tmpmap' group. Under enforcing, if dotnet is enabled but tmpmap is not loaded
        # the build fails with an opaque EACCES -- surface the exact fix here instead.
        if [[ "${enforce}" == "Enforcing" ]] \
                && grep -qxF dotnet <<<"${enabled_integrations}" \
                && ! group_loaded tmpmap; then
            say ""
            say "  ${C_YEL}dotnet is enabled but the 'tmpmap' SELinux group is not loaded:${C_RST}"
            say "  ${C_YEL}dotnet restore/build will fail under enforcing (EACCES on mmap of /tmp).${C_RST}"
            say "  fix: sudo ai-tools-admin selinux enable-group tmpmap"
        fi
        # dotnet <-> apphost: executable/host projects run their apphost/JIT code from an
        # anonymous memfd file, which needs the 'apphost' group -- disjoint from tmpmap (that
        # is /tmp mmap; this is memfd execute), so a full build-and-run workflow wants both.
        # apphost is experimental, so its fix is the source enable path, not ai-tools-admin
        # (which loads only prebuilt stable groups).
        if [[ "${enforce}" == "Enforcing" ]] \
                && grep -qxF dotnet <<<"${enabled_integrations}" \
                && ! group_loaded apphost; then
            say ""
            say "  ${C_YEL}dotnet is enabled but the 'apphost' SELinux group is not loaded:${C_RST}"
            say "  ${C_YEL}executable/host projects (dotnet run, ASP.NET Core, xunit.v3) will fail (memfd exec denied).${C_RST}"
            say "  ${C_DIM}library builds and in-process test runners (MSTest) are unaffected.${C_RST}"
            say "  fix: sudo selinux/install-selinux.sh enable-group apphost  ${C_DIM}(from a source checkout)${C_RST}"
        fi
        # dotnet <-> netcore: the runtime's diagnostic sockets/FIFOs (dotnet test, multi-node
        # MSBuild pipes) and running a binary built in the project tree. Experimental, so the fix
        # is the source enable path. See .claude/rules/dotnet.rule.md.
        if [[ "${enforce}" == "Enforcing" ]] \
                && grep -qxF dotnet <<<"${enabled_integrations}" \
                && ! group_loaded netcore; then
            say ""
            say "  ${C_YEL}dotnet is enabled but the 'netcore' SELinux group is not loaded:${C_RST}"
            say "  ${C_YEL}dotnet test can't open its diagnostic socket, multi-node MSBuild hangs, and a built${C_RST}"
            say "  ${C_YEL}binary won't run from the project tree.${C_RST}"
            say "  fix: sudo selinux/install-selinux.sh enable-group netcore  ${C_DIM}(from a source checkout)${C_RST}"
        fi
    }
    selinux_groups_block

    if [[ -s "${refusals}" ]]; then
        section "Refused inputs"
        sed 's/^/    /' "${refusals}"
        say "    a refusal always means LESS access -- the provider is skipped, never guessed."
    fi
    rm -f "${refusals}"
    say ""
    say "  ${C_DIM}providers are enabled by name in ${AI_TOOLS_OPERATOR_CONF} (root-owned, root-edited)${C_RST}"
}

# list_maintenance_note  -- the compact pointer to the existing per-project verbs, printed
# below the listing so --list doubles as a reconciliation/maintenance view.
list_maintenance_note() {
    section "Maintenance"
    say "  ai-tools --project-claim <path>     claim a project / finish claiming one"
    say "  ai-tools --project-unclaim <path>   release a project (revoke agent access)"
    say "  ai-tools --reclaim [--full] <path>  take back ownership; project stays claimed"
    say "  ai-tools --lockdown <path>          lock down secret-named files"
    say "  ai-tools --relabel                  re-verify and relabel the agent entrypoints"
}

# status_fmt_age <seconds>  -- render an age the way an operator reads it ("3 days ago"), not as a
# duration to be mentally subtracted from now. Coarsens with distance: the exact minute matters for
# a run that just happened and not at all for one from last week. Empty input prints nothing, so a
# caller can drop the clause entirely when the age is unknown.
status_fmt_age() {
    local s="${1:-}"
    [[ "${s}" =~ ^[0-9]+$ ]] || return 0
    if   [[ "${s}" -lt 90      ]]; then printf 'just now'
    elif [[ "${s}" -lt 5400    ]]; then printf '%d min ago'  "$(( s / 60 ))"
    elif [[ "${s}" -lt 172800  ]]; then printf '%d hours ago' "$(( s / 3600 ))"
    else                                printf '%d days ago'  "$(( s / 86400 ))"
    fi
}

# status_sandbox_unit_commands <unit>  -- print the three commands that inspect and re-run a unit
# living in the SANDBOX account's own `systemd --user` manager. That manager is unreachable from
# the operator's session, so every one of them goes through root:
#   * status/restart use the MACHINE transport (systemctl --user -M <account>@.host), which reaches
#     that manager over the system bus where root is already authorized. A plain
#     `sudo -u <account> systemctl --user` gets that account's own bus refused even when the manager
#     is healthy (no XDG_RUNTIME_DIR) -- the same reason tests' sandbox_systemctl prefers this form.
#   * the journal query matches on the JOURNAL FIELDS instead: `journalctl --user-unit` as root
#     reads ROOT's user units, never another account's, so the unit is selected by
#     _SYSTEMD_USER_UNIT and narrowed to the sandbox account by _UID (different field names AND
#     together). This catches the unit's own output and the `systemd-cat` lines its script emits,
#     since both are logged from the same cgroup.
# Composed here rather than stored in services.lib.sh because each names the sandbox account, and
# that library is deployed with no @SANDBOX_USER@ substitution.
status_sandbox_unit_commands() {
    local unit="$1" uid
    uid="$(id -u "${SANDBOX_USER}" 2>/dev/null || true)"
    say "      ${C_BOLD}sudo systemctl --user -M ${SANDBOX_USER}@.host status ${unit}${C_RST}"
    if [[ -n "${uid}" ]]; then
        say "      ${C_BOLD}sudo journalctl _SYSTEMD_USER_UNIT=${unit} _UID=${uid} -n 50 --no-pager${C_RST}"
    fi
    say "      ${C_BOLD}sudo systemctl --user -M ${SANDBOX_USER}@.host restart ${unit}${C_RST}"
}

# cmd_status  -- report the host's ai-tools service health: provisioning state, then each managed
# systemd unit (OK / SKIPPED / STALE / DOWN / FAILED / n/a / ?) and, for anything not plainly
# healthy, its consequence and the exact commands that inspect and fix it.
# Reuses services.lib.sh -- the SAME registry the launch-time warning reads -- so the status view and
# the launch warning never disagree. Informational (no operator gate), like --list/--providers.
# status_entrypoint_pins  -- report, per enabled agent, whether its entrypoint carries a verified
# checksum, and under it (status_entrypoint_label) what the last reconciliation could do about that
# agent's labels. The entrypoint itself lives in a 0750 toolchain the operator cannot read, so both
# lines report root-written records placed where they can. Without them the only signals are a
# warning in a journal the operator cannot reach and, eventually, a refused launch.
#
# The pin is written in the same KEY=value stamp grammar as the updater's last-run record, so it is
# read through the SAME accessors -- charset-clamped fields and one age implementation - rather than
# a second reader that could drift. Its path comes from entrypoint-verify.lib.sh, never hardcoded.
#
# Returns non-zero only when an unpinned entrypoint is actually actionable, which is exactly when
# the operator has required verification: everywhere else unpinned is a legitimate state (an
# air-gapped host, a release the vendor published no manifest for) and must not make a healthy host
# alarm, the same rule the unqueryable units follow. A pin this account cannot read is reported as
# unknown and is never a fault -- --status stays open to a non-operator, who cannot traverse the
# state directory at all.
status_entrypoint_pins() {
    local providers_lib=/usr/local/lib/ai-tools/providers.lib.sh
    local verify_lib=/usr/local/lib/ai-tools/entrypoint-verify.lib.sh
    # shellcheck source=SCRIPTDIR/../lib/ai-tools/providers.lib.sh
    source "${providers_lib}" 2>/dev/null || true
    # shellcheck source=SCRIPTDIR/../lib/ai-tools/entrypoint-verify.lib.sh
    source "${verify_lib}" 2>/dev/null || true
    declare -F ai_tools_enabled_agents      >/dev/null 2>&1 || return 0
    declare -F ai_tools_entrypoint_pin_path >/dev/null 2>&1 || return 0
    declare -F ai_tools_service_stamp_field >/dev/null 2>&1 || return 0

    local strict=no
    declare -F ai_tools_entrypoint_verify_required >/dev/null 2>&1 \
        && ai_tools_entrypoint_verify_required && strict=yes

    local agent pin version verified age seen=0 unpinned=0 mislabelled=0
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        # An agent whose package declares no release manifest has nothing to verify against, so it
        # is left out entirely rather than reported as perpetually unpinned.
        [[ -n "$(ai_tools_agent_manifest_field "${agent}" release_manifest_url 2>/dev/null || true)" ]] || continue
        (( seen++ == 0 )) && section "Entrypoint verification"
        pin="$(ai_tools_entrypoint_pin_path "${agent}" 2>/dev/null || true)"
        version="$(ai_tools_service_stamp_field "${pin}" VERSION)"
        if [[ -n "${version}" ]]; then
            verified="$(ai_tools_service_stamp_age "${pin}" VERIFIED)"
            age="$(status_fmt_age "${verified}")"
            printf '  %-28s %sVERIFIED%s %s(%s%s)%s\n' "${agent}" "${C_GRN}" "${C_RST}" \
                "${C_DIM}" "${version}" "${age:+, ${age}}" "${C_RST}"
        elif [[ -e "${pin}" && ! -r "${pin}" ]]; then
            # Not a fault: --status stays open to a non-operator, who cannot traverse the state
            # directory at all. It says only that this vantage cannot tell.
            printf '  %-28s %s? (pin not readable from this account)%s\n' "${agent}" "${C_DIM}" "${C_RST}"
        elif [[ -e "${pin}" ]]; then
            # Readable but carrying no VERSION the clamped reader will accept. Distinct from both
            # states above and from a missing pin, because the remedy is to rewrite it -- and it is
            # never read as verified, since the version check above is what gates that line.
            printf '  %-28s %sunverified%s %s(pin present but unreadable -- rewrite it: ai-tools --relabel)%s\n' \
                "${agent}" "${C_DIM}" "${C_RST}" "${C_DIM}" "${C_RST}"
        else
            unpinned=$(( unpinned + 1 ))
            if [[ "${strict}" == yes ]]; then
                printf '  %-28s %sUNVERIFIED%s\n' "${agent}" "${C_YEL}" "${C_RST}"
                say "      this host requires verification, so its sessions will not launch"
                say "      ${C_BOLD}ai-tools --relabel${C_RST} ${C_DIM}(needs network -- it fetches the vendor's signed manifest)${C_RST}"
            else
                printf '  %-28s %sunverified%s %s(no pin -- launches are not blocked)%s\n' \
                    "${agent}" "${C_DIM}" "${C_RST}" "${C_DIM}" "${C_RST}"
            fi
        fi
        status_entrypoint_label "${agent}" || mislabelled=$(( mislabelled + 1 ))
    done < <(ai_tools_enabled_agents 2>/dev/null)

    [[ "${mislabelled}" -gt 0 ]] && return 1
    [[ "${strict}" == yes && "${unpinned}" -gt 0 ]] && return 1
    return 0
}

# status_entrypoint_label <agent>  -- report what the last reconciliation could do about that
# agent's SELinux labels, under its verification line. The two halves of one reconciliation are
# reported together because they are asked from the same vantage and fail independently: on a host
# whose relabel could not register its file-context rules, the pin line alone reads as a fresh green
# all-clear for the half that did work.
#
# The label itself stays unreadable from here -- the entrypoint lives in a 0750 toolchain this
# account cannot traverse, and matchpathcon computes only what a label SHOULD be -- so this reports
# the root-written record instead, through the same stamp accessors as the pin. It reports an EVENT:
# what the last run could do, and when. Confirming the labels are right NOW is `ai-tools --relabel`,
# which the failure line names.
#
# Returns non-zero only for a recorded failure, which is the one state that stops a launch.
status_entrypoint_label() {
    local agent="$1" record result reason age
    declare -F ai_tools_entrypoint_label_path >/dev/null 2>&1 || return 0
    record="$(ai_tools_entrypoint_label_path "${agent}" 2>/dev/null || true)"
    result="$(ai_tools_service_stamp_field "${record}" RESULT)"
    age="$(status_fmt_age "$(ai_tools_service_stamp_age "${record}" LABELLED)")"
    reason="$(ai_tools_service_stamp_field "${record}" REASON)"
    case "${result}" in
        ok)      printf '  %-28s %slabelled%s %s(%s)%s\n' "" "${C_DIM}" "${C_RST}" \
                     "${C_DIM}" "${age:-at an unknown time}" "${C_RST}" ;;
        failed)  printf '  %-28s %sNOT LABELLED%s %s(%s%s)%s\n' "" "${C_RED}" "${C_RST}" \
                     "${C_DIM}" "${age:-at an unknown time}" "${reason:+, ${reason}}" "${C_RST}"
                 say "      its next session refuses to launch rather than run unconfined"
                 say "      ${C_BOLD}sudo systemctl start ai-tools-relabel.service${C_RST} ${C_DIM}(then: journalctl -t ai-tools-relabel-agent)${C_RST}"
                 return 1 ;;
        # Nothing to label -- a DAC-only host, or an agent the toolchain has not provisioned yet.
        # Neither is a fault, so neither is coloured or counted.
        skipped) printf '  %-28s %snot labelled (%s)%s\n' "" "${C_DIM}" \
                     "${reason:-nothing to label}" "${C_RST}" ;;
        # No record at all: this host has not run a reconciliation since the record was introduced,
        # or the state directory is unreadable from this account. It says only that, and never
        # counts against the exit status -- the same rule the unqueryable units follow.
        *)       printf '  %-28s %s? (no labelling recorded -- run: ai-tools --relabel)%s\n' \
                     "" "${C_DIM}" "${C_RST}" ;;
    esac
    return 0
}

cmd_status() {
    local problems=0

    section "Version"
    say "  ai-tools ${AI_TOOLS_VERSION}"
    # The agent version lives in the sandbox toolchain the operator cannot read, so it stays a
    # pointer. Node does not have to: the updater records the version it left active in its stamp,
    # so read it from whichever registry record publishes one -- no unit is named here, and a host
    # whose updater has not run yet simply keeps the pointer.
    local rec node_ver=""
    if declare -F ai_tools_service_stamp_field >/dev/null 2>&1; then
        while IFS= read -r rec; do
            node_ver="$(ai_tools_service_stamp_field "$(ai_tools_service_field "${rec}" 7)" NODE)"
            [[ -n "${node_ver}" && "${node_ver}" != unknown ]] && break
            node_ver=""
        done < <(ai_tools_service_records)
    fi
    [[ -n "${node_ver}" ]] && say "  node ${node_ver} ${C_DIM}(as of the last toolchain update)${C_RST}"
    say "  ${C_DIM}agent version: run 'claude --version'${C_RST}"

    section "Provisioning"
    # CLAUDE_LINK is bootstrap's last artifact (the gate require_bootstrap keys on), so its presence
    # means the toolchain is installed.
    if [[ -L "${CLAUDE_LINK}" ]]; then
        ok "toolchain provisioned"
    else
        say "  ${C_YEL}not provisioned${C_RST} -- run: ${C_BOLD}sudo ai-tools-bootstrap${C_RST}"
    fi

    section "Services"
    # A missing registry is a broken install, not an unknowable state, so this is one of the
    # conditions --status exits non-zero on rather than reporting a clean bill it cannot support.
    if ! declare -F ai_tools_service_records >/dev/null 2>&1 \
            || ! declare -F ai_tools_service_state_of >/dev/null 2>&1 \
            || ! declare -F ai_tools_service_stamp_field >/dev/null 2>&1; then
        warn "service registry unavailable (${SERVICES_LIB}) -- cannot report service health"
        return 1
    fi
    local unit scope stamp mode state age when exit_code reason remedy
    while IFS= read -r rec; do
        unit="$(ai_tools_service_field "${rec}" 1)"
        scope="$(ai_tools_service_field "${rec}" 2)"
        stamp="$(ai_tools_service_field "${rec}" 7)"
        mode="$(ai_tools_service_field "${rec}" 8)"
        state="$(ai_tools_service_state_of "${rec}")"
        # A stamped unit is reported from its LAST RUN, not live, so every line says WHEN -- relative
        # first, since "3 days ago" is the part an operator acts on. An unknown age prints nothing
        # rather than a placeholder.
        age=""; when=""
        if [[ -n "${stamp}" ]]; then
            age="$(status_fmt_age "$(ai_tools_service_stamp_age "${stamp}")")"
            [[ -n "${age}" ]] && when=" ${C_DIM}(last run ${age})${C_RST}"
        fi
        case "${state}" in
            # In 'fired' mode the stamp belongs to another unit; this one is only inferred from the
            # fact that a run happened at all, so the line says so rather than claiming a live check.
            active) if [[ "${mode}" == fired && -n "${age}" ]]; then
                        printf '  %-28s %sOK%s %s(inferred -- a run completed %s)%s\n' \
                            "${unit}" "${C_GRN}" "${C_RST}" "${C_DIM}" "${age}" "${C_RST}"
                    else
                        printf '  %-28s %sOK%s%s\n' "${unit}" "${C_GRN}" "${C_RST}" "${when}"
                    fi ;;
            down)   printf '  %-28s %sDOWN%s\n' "${unit}" "${C_YEL}" "${C_RST}" ;;
            # A run that correctly did nothing (the updater with an unreachable registry) is dim,
            # not yellow: yellow is this report's attention colour, and there is nothing to attend
            # to -- the previous toolchain is intact and the next run will try again. If the
            # condition persists the line turns STALE on its own once the stamp ages past its
            # grace, which is where the operator is meant to look.
            skipped) reason="$(ai_tools_service_stamp_field "${stamp}" REASON)"
                    printf '  %-28s %sSKIPPED%s %s(last run %s%s -- nothing was changed)%s\n' \
                        "${unit}" "${C_DIM}" "${C_RST}" "${C_DIM}" "${age:-at an unknown time}" \
                        "${reason:+, ${reason}}" "${C_RST}" ;;
            # Two forms, because the two kinds of failed unit know different things about the run.
            # A stamped unit records when it ran; a system oneshot's result comes from systemd,
            # which knows the exit status but is read here without a time, so the line does not
            # claim one.
            failed) if [[ -n "${stamp}" ]]; then
                        exit_code="$(ai_tools_service_stamp_field "${stamp}" EXIT_CODE)"
                        printf '  %-28s %sFAILED%s %s(last run %s, exit %s)%s\n' "${unit}" \
                            "${C_RED}" "${C_RST}" "${C_DIM}" "${age:-at an unknown time}" \
                            "${exit_code:-?}" "${C_RST}"
                    else
                        exit_code="$(ai_tools_service_unit_property "${unit}" ExecMainStatus)"
                        printf '  %-28s %sFAILED%s %s(its last run exited %s)%s\n' "${unit}" \
                            "${C_RED}" "${C_RST}" "${C_DIM}" "${exit_code:-non-zero}" "${C_RST}"
                    fi ;;
            stale)  printf '  %-28s %sSTALE%s %s(last run %s)%s\n' \
                        "${unit}" "${C_YEL}" "${C_RST}" "${C_DIM}" "${age:-long ago}" "${C_RST}" ;;
            absent) printf '  %-28s %sn/a (not installed)%s\n' "${unit}" "${C_DIM}" "${C_RST}" ;;
            # 'unknown' is not a problem report -- it says only that this vantage point cannot tell.
            # It stays a single line carrying the one command that CAN tell, so a healthy host's
            # report does not grow a diagnostic block per unit it simply cannot query.
            *)      if [[ "${scope}" == sandbox-user ]]; then
                        printf '  %-28s %s? (sandbox --user unit -- check: sudo systemctl --user -M %s@.host status %s)%s\n' \
                            "${unit}" "${C_DIM}" "${SANDBOX_USER}" "${unit}" "${C_RST}"
                    else
                        printf '  %-28s %s? (systemctl unavailable)%s\n' "${unit}" "${C_DIM}" "${C_RST}"
                    fi ;;
        esac
        # A unit that IS reported broken names its consequence, then every command that inspects and
        # fixes it. A sandbox-user unit's are composed here rather than stored in the registry: they
        # name the sandbox ACCOUNT, and services.lib.sh is deployed with no @SANDBOX_USER@ pass.
        if ai_tools_service_needs_attention "${state}"; then
            problems=$(( problems + 1 ))
            say "      $(ai_tools_service_field "${rec}" 5)"
            if [[ "${scope}" == sandbox-user ]]; then
                status_sandbox_unit_commands "${unit}"
            fi
            remedy="$(ai_tools_service_field "${rec}" 6)"
            if [[ -n "${remedy}" ]]; then
                say "      ${C_BOLD}${remedy}${C_RST}"
            fi
        fi
    done < <(ai_tools_service_records)

    status_entrypoint_pins || problems=$(( problems + 1 ))

    # Pointers, not duplication: name the sibling read-only reports (which own their own detail) and
    # where the full command list lives, so --status is a hub without re-implementing --providers or
    # --help.
    section "More"
    say "  ai-tools --providers   installed agents/integrations and which are enabled"
    say "  ai-tools --list        registered projects (real and sandbox)"
    say "  ai-tools --help        the full command list"

    # Exit non-zero when anything is actually broken, so --status is usable unattended (a cron
    # check, a monitor) without parsing this output. 'unknown' and 'n/a' are not faults and do not
    # count -- an unqueryable unit must not make a healthy host alarm every night.
    [[ "${problems}" -eq 0 ]]
}

# cmd_list  -- print each allowlist entry as project, sandbox, or exclude, with its git
# safe.directory status, then flag inconsistent hand-edited entries under "Suggested cleanup"
# with copy-paste remediation commands (the allowlist is operator-owned and hand-editable, so a
# line can name a protected system path the tools refuse to touch, a stale path that no longer
# exists, or a project listed but never fully claimed). All read-only, reusing existing predicates
# and verbs -- no recovery machinery of its own.
cmd_list() {
    [[ -f "${ALLOWLIST}" ]] || { say "no allowlist at ${ALLOWLIST}"; return 0; }
    # Name the operator on a --for run: the entries below are that account's launch gate, not the
    # invoker's, and an unlabelled listing of someone else's projects reads as your own.
    if [[ -n "${FOR_OPERATOR}" ]]; then
        section "Registered projects for ${FOR_OPERATOR}"
    else
        section "Registered projects"
    fi
    # Root reads ROOT's allowlist, which no bootstrap creates -- so the report is empty, and
    # correct, and reads as a fault. An allowlist is per-operator by design (it is that operator's
    # own launch gate), so say whose registry this is and name the ones that hold projects. Root
    # cannot follow this with --for: that flag needs an enrolled invoker, and root is not one.
    if [[ "${INVOKING_USER}" == "root" ]]; then
        local -a enrolled=()
        ai_tools_conf_list enrolled "${AI_TOOLS_OPERATOR_CONF:-/etc/ai-tools/operator.conf}" \
            OPERATORS 2>/dev/null || enrolled=()
        say "  ${C_DIM}root's own registry -- projects are registered per operator${C_RST}"
        (( ${#enrolled[@]} )) && say \
            "  ${C_DIM}read one as that operator ($(join_words "${enrolled[@]}")): su - <operator> -c 'ai-tools --list'${C_RST}"
    fi
    local raw entry excl kind safe sd shown=0
    local -a cleanup=()

    # _is_labelled <dir>  -- 0 when SELinux is active and <dir> carries ai_tools_project_t.
    _is_labelled() {
        command -v getenforce >/dev/null 2>&1 \
            && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]] || return 1
        ls -Zd "$1" 2>/dev/null | grep -q ':ai_tools_project_t:'
    }
    # _has_glob <str>  -- 0 when <str> carries a shell glob metacharacter (* ? [). Globs are
    # honored only in '!' exclusion lines (both the wrapper and ai-tools-chown match them as
    # globs); an allow line is realpath'd, so a glob there resolves to nothing and is inert.
    _has_glob() { [[ "$1" == *[*?[]* ]]; }
    # _remove_line_cmd <raw-line>  -- the copy-paste sed that deletes the VERBATIM allowlist line
    # (comment and all), so it matches what is stored even when the entry carries an end-of-line
    # comment or quotes; allow_escape makes the line a literal BRE.
    _remove_line_cmd() { printf "          sed -i '\\\\|^%s\$|d' %s" "$(allow_escape "$1")" "${ALLOWLIST}"; }
    # _reconcile <entry> <kind> <safedir-yes> <raw-line>  -- append a remediation block for an
    # inconsistent entry (stale / protected / listed-but-not-fully-claimed). Nested so it shares
    # `cleanup`; <raw-line> is the verbatim source line the removal command deletes.
    _reconcile() {
        local e="$1" k="$2" sdy="$3" raw="$4"
        if ! realpath -e "${e}" >/dev/null 2>&1; then
            cleanup+=( "  ${e}" \
                "      ${C_YEL}no longer exists${C_RST} (stale entry); remove it:" \
                "$(_remove_line_cmd "${raw}")" )
            ${sdy} && cleanup+=( "          sudo ${SAFEDIR_BIN} --remove ${e}" )
            return 0                                    # ${sdy}=false returns 1; don't kill cmd_list's set -e loop
        fi
        if ai_tools_protected_path_match "${e}" >/dev/null 2>&1; then
            cleanup+=( "  ${e}" \
                "      ${C_YEL}protected system path${C_RST} -- the tools refuse to operate on it; remove it:" \
                "$(_remove_line_cmd "${raw}")" )
            ${sdy} && cleanup+=( "          sudo ${SAFEDIR_BIN} --remove ${e}" )
            _is_labelled "${e}" && cleanup+=( "          sudo ${RELABEL_BIN} --remove ${e}" )
            return 0                                    # trailing conditionals above return 1; don't kill the loop
        fi
        [[ "${k}" == project ]] || return 0            # sandbox clones are managed by --sandbox-*
        # Not fully claimed: agent has no group access, the ACL is missing, or (SELinux active)
        # the tree is unlabelled. Read from the same project_state tokens the claim flow uses.
        local listed safedir filemode owngap acl labelled git
        IFS=' ' read -r listed safedir filemode owngap acl labelled git < <(project_state "${e}")
        if [[ "${owngap}" == true || "${acl}" == true || "${labelled}" == false ]]; then
            cleanup+=( "  ${e}" \
                "      ${C_YEL}listed but not fully claimed${C_RST}; finish claiming it:" \
                "          ai-tools --project-claim ${e}" )
        fi
    }

    while IFS= read -r raw || [[ -n "${raw}" ]]; do
        # Same shared grammar the wrapper and the chown helper read this file with; keep the
        # verbatim ${raw} line so a stale/protected remediation deletes exactly what is stored.
        ai_tools_conf_path_entry "${raw}" || continue
        entry="${_ai_tools_conf_value}"
        shown=1
        if [[ "${entry}" == '!'* ]]; then
            excl="${entry:1}"
            printf '  %-8s %s\n' "exclude" "${excl}"
            # A stale exclusion excludes nothing. Flag a non-glob '!' path that no longer exists;
            # a glob exclusion is valid as written (it need not resolve today), so leave it.
            if ! _has_glob "${excl}" && ! realpath -e "${excl}" >/dev/null 2>&1; then
                cleanup+=( "  ${entry}" \
                    "      ${C_YEL}no longer exists${C_RST} (stale exclusion); remove it:" \
                    "$(_remove_line_cmd "${raw}")" )
            fi
            continue
        fi
        # A glob in an ALLOW line is silently inert -- the wrapper realpath's allow entries, so
        # the pattern resolves to nothing and never gates a launch. Flag it rather than letting it
        # masquerade as a claimable project (globs belong on '!' lines).
        if _has_glob "${entry}"; then
            printf '  %-8s %-50s %s\n' "unusable" "${entry}" "${C_YEL}glob in allow line${C_RST}"
            cleanup+=( "  ${entry}" \
                "      ${C_YEL}glob in an allow line${C_RST} -- globs work only in '!' exclusion lines; an allow entry must be a literal directory. Remove it:" \
                "$(_remove_line_cmd "${raw}")" )
            continue
        fi
        case "${entry}/" in
            "${SANDBOX_ROOT}"/*) kind="sandbox" ;;
            *)                   kind="project" ;;
        esac
        if git config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null \
                | grep -qxF "${entry}"; then
            safe="safe.dir:yes"; sd=true
        else
            safe="safe.dir:${C_YEL}NO${C_RST}"; sd=false
        fi
        printf '  %-8s %-50s %s\n' "${kind}" "${entry}" "${safe}"
        _reconcile "${entry}" "${kind}" "${sd}" "${raw}"
    done < "${ALLOWLIST}"
    (( shown )) || say "  (none)"

    # Reverse reconciliation: a git safe.directory entry with no matching allowlist line is an
    # ORPHAN -- git still trusts the tree though nothing lists it (the allowlist line was
    # hand-deleted, or an unclaim was interrupted before the safedir drop). Removing the stale
    # safedir (and its label) is the cleanup; the entry is not a claimed project, so it is not
    # offered --project-unclaim, which would refuse an unlisted target. Control-plane entries
    # (/opt/ai-tools) are registered deliberately and are protected paths, so they are skipped.
    local sdir
    while IFS= read -r sdir; do
        [[ -n "${sdir}" ]] || continue
        ai_tools_protected_path_match "${sdir}" >/dev/null 2>&1 && continue
        ai_tools_conf_allowlist_has_entry "${ALLOWLIST}" "${sdir}" && continue
        cleanup+=( "  ${sdir}" \
            "      ${C_YEL}git safe.directory with no allowlist entry${C_RST} (orphaned); remove it:" \
            "          sudo ${SAFEDIR_BIN} --remove ${sdir}" )
        _is_labelled "${sdir}" && cleanup+=( "          sudo ${RELABEL_BIN} --remove ${sdir}" )
    done < <(git config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null || true)

    if (( ${#cleanup[@]} )); then
        section "Suggested cleanup"
        printf '%s\n' "${cleanup[@]}"
        say "  ${C_DIM}review each path before running the command; the allowlist is yours to edit${C_RST}"
    fi
    list_maintenance_note
}

# usage() is paired with the ai-tools(1) man page (src/usr/local/share/man/man1/
# ai-tools.1): tests/unit/man.sh asserts the two long-option sets match, so an option
# added, renamed, or removed here changes the man page in the same commit.
usage() {
    cat <<EOF
ai-tools -- manage Claude Code sandbox projects (run as the projects user)

  ai-tools --project-claim [-y] [path]  claim a project in place: grant the agent access (default: cwd)
  ai-tools --project-create  <path>  create a new project directory, init git, and claim it
  ai-tools --project-unclaim [path]  release a project: revoke agent access, return the tree to your group
  ai-tools --project-remove  [path]  alias for --project-unclaim (back-compat)
  ai-tools --sandbox-create [path]   shallow-clone a repo into the sandbox area
  ai-tools --sandbox-push   [path]   push the sandbox clone's commits to its branch
  ai-tools --sandbox-remove [path]   remove a sandbox clone and unregister it
  ai-tools --lockdown [path] [-n|-y] lock down secret files (sudo; default: cwd)
  ai-tools --reclaim [--full] [path] take back ownership of agent files; project stays claimed (sudo; default: cwd)
  ai-tools --stop                    terminate every agent session and all it spawned (sudo)
  ai-tools --relabel                 re-verify and relabel the agent entrypoints (sudo)
  ai-tools --providers               list installed agents/integrations and which are enabled
  ai-tools --audit [--since <when>]  report what refused, was rejected or stranded (sudo; default: 7 days)
  ai-tools --status                  report service health (handback socket, relabel watcher, updater)
  ai-tools --list                    list registered projects
  ai-tools --version
  ai-tools --help

  --project-claim options: -y/--yes (pre-answer the proceed prompt; the secret-lockdown,
                      .git-history, and ancestor-traversal questions still ask)
  --project-unclaim options: --group <group> (hand back to <group> without prompting),
                      --full (also cover node_modules, .venv, ...), -y/--yes (pre-answer
                      the confirm), --force (normalize a COPY of a claimed project that is
                      not registered; acts only on paths still carrying ai-tools ownership,
                      group, or ACL), -n/--dry-run (with --force: list, change nothing)
  --sandbox-create options: --from <ref> (branch/ref to fork from; default: current branch),
                      --branch <name> (full sandbox branch to create/track; default:
                      sandbox/<leaf of --from>; any valid git ref), --dir <name> (sandbox
                      directory name; default: repo basename), -y/--yes (skip the create confirm)
  --lockdown options: -n/--dry-run (preview only), -y/--yes (skip confirmation)
  --reclaim options:  --full (also reclaim node_modules, .venv, ... not just the work tree + .git)
  --stop options:     -n/--dry-run (list what would be terminated, change nothing), -y/--yes
                      (skip the confirmation, which DEFAULTS TO YES here: an unattended stop
                      that declines is a stop that failed), --force (kill immediately, no
                      grace period -- the current turn's unsaved work is lost), --all
                      (accepted and inert; every run already terminates every session).
                      It takes NO path: there is no per-project form, because a session is
                      attributed to a project by the account being stopped. To finish one
                      session cleanly use /exit inside it, which runs its session-end
                      handback. Exits 1 if anything survived, 2 on a path, 4 declined.
  --audit options:    --since <when> (anything date(1) parses: '2 days ago', '2026-08-01';
                      default: 7 days ago). Exits non-zero when anything is reported, so it
                      is usable from cron or a login banner without parsing its output.

  Runs as an operator, without sudo -- the CLI invokes sudo itself for the steps that need
  it. Root is accepted for the verbs that write no operator state (--audit, --status,
  --list, --providers, --stop); every other verb writes operator-owned state and refuses
  root. A caller holding no sudo grant for a verb's root helper is told so before sudo
  prompts, with the command an operator who does hold one can run instead; --stop needs no
  such grant (%ai-ops carries a NOPASSWD rule for its bare form).

  --for <operator>    act on another enrolled operator's projects instead of your own: the
                      entry lands in THEIR allowed-projects, so the tree is granted to them and
                      their agent launches there. For a service account that runs an agent but
                      has no password to authenticate a claim of its own. Accepted on
                      --project-claim/-create, --project-unclaim/-remove, --lockdown,
                      --reclaim and --list; not with --project-unclaim --force.
                      Enrol the target first: sudo ai-tools-admin operator add <operator>

Sandbox workflow: /var/opt/ai-tools/README.md
EOF
}

# Refuse early on an unprovisioned install. CLAUDE_LINK is bootstrap's last load-bearing
# artifact -- written after the account, Node, and the agent package all succeed -- so
# its presence means provisioning finished. Gate before dispatch so a broken install stops
# here, not mid-operation in a root helper. -L avoids dereferencing the 700 package dir the
# operator cannot traverse. See cli.rule.md (Bootstrap preflight).
require_bootstrap() {
    [[ -L "${CLAUDE_LINK}" ]] && return 0
    die "the sandbox is not provisioned (no ${CLAUDE_LINK}) -- provision it with:" \
        "       sudo ai-tools-bootstrap"
}

# When this file is SOURCED rather than executed (tests/unit/sandbox.sh loads it to exercise the
# pure sandbox_* helpers above), stop here: expose the functions, run none of the gates or
# dispatch below. On execution BASH_SOURCE[0] equals $0, so this is a no-op and the CLI proceeds.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] || return 0

# The two diagnostics meant to run WHEN things may be broken bypass the provisioning gate
# (BOOTSTRAP_EXEMPT_VERBS): cmd_status reports the unprovisioned state itself instead of being
# blocked by it, and --audit reads a record of what already happened, which an install that never
# finished does not invalidate -- a failed provisioning is precisely when that record is worth
# reading. Every other command stays gated.
verb_in "${1:-}" "${BOOTSTRAP_EXEMPT_VERBS[@]}" || require_bootstrap

# require_operator -- refuse a command that acts as an operator unless the invoking user is
# listed in OPERATORS in operator.conf. The project/sandbox/lockdown/reclaim paths resolve the
# caller's identity from that list (operator.lib.sh, via the root helpers); an unenrolled user
# would otherwise proceed through the registry writes and confirm prompts only to be refused by
# the first root helper that resolves owner (e.g. ai-tools-lockdown says "not in allowed projects
# for current operator"), after partial state was written and rolled back -- the misleading flow
# this gate replaces with one up-front message. operator.conf is 644, so the unprivileged CLI
# reads OPERATORS directly; adding a name there takes effect on the next command (no re-login,
# unlike the ai-ops group the admin verb also grants for launching the agent).
require_operator() {
    local conf="${AI_TOOLS_OPERATOR_CONF:-/etc/ai-tools/operator.conf}"
    local -a ops=(); local op
    if ai_tools_conf_list ops "${conf}" OPERATORS 2>/dev/null; then
        for op in "${ops[@]}"; do [[ "${op}" == "${INVOKING_USER}" ]] && return 0; done
    fi
    die "you (${INVOKING_USER}) are not a configured ai-tools operator -- add your name to OPERATORS in ${conf} with:" \
        "       sudo ai-tools-admin operator add ${INVOKING_USER}"
}

# handover_target [args...] -- the project path to name in a handed-over command. Naming it
# explicitly is the point: the operator who runs that command is standing somewhere else, so a
# path-less suggestion would resolve against THEIR directory.
#
# It falls back to the current directory only when the caller named no path, which is what these
# verbs default to anyway. A path the caller DID name is passed through as typed even when it does
# not exist, because substituting the current directory there composes a command against a
# directory nobody named -- and since the suggestion is a claim, a plausible-looking one the
# operator pastes would grant the agent access to whatever they happened to be standing in.
# Mistyping a path must cost a re-typed path, so the mistyped one is what the message shows.
#
# Arguments are matched positionally: a flag is skipped, and so is the value of one that takes
# one, so `--group <name>` cannot be read as the project.
handover_target() {
    local argument first_named="" skip_value=0
    for argument in "$@"; do
        if (( skip_value )); then skip_value=0; continue; fi
        case "${argument}" in
            -g|--group|--from|--branch|--dir|--since) skip_value=1; continue ;;
            -*) continue ;;
        esac
        [[ -d "${argument}" ]] && { printf '%s' "${argument}"; return 0; }
        [[ -n "${first_named}" ]] || first_named="${argument}"
    done
    printf '%s' "${first_named:-${PWD}}"
}

# require_sudo_access <verb> [verb-args...] -- refuse a verb whose root helper this caller holds no
# sudo grant for, and say who can run it instead.
#
# The case it exists for is an ai-ops-only account: in the operators group, in no sudoers rule.
# That is a supported shape, not a misconfiguration -- it is what --for was built for -- and it is
# NOT the same as having no password. An operator who has one is the worse case today: sudo
# authenticates before it decides, so they are asked for a password and refused after supplying
# it. Nothing here changes what anyone is granted; it moves a refusal that was already coming to
# before the prompt, and attaches the route to the result.
#
# Every verb that reaches a root helper is covered, and each is probed on the FIRST helper it
# reaches -- a site that grants some helpers and not others is then answered accurately rather
# than by a single representative. The refusal precedes the run's first sudo, which is the same
# ordering require_for_target follows: a command that is going to be refused must not prompt first.
require_sudo_access() {
    local verb="${1:-}"; shift || true
    local bin="" what="" delegable=false
    case "${verb}" in
        --audit)                            bin="${AUDIT_BIN}"    what="reading the refusal trail" ;;
        --lockdown)                         bin="${LOCKDOWN_BIN}" what="locking down secret files"; delegable=true ;;
        --reclaim)                          bin="${RECLAIM_BIN}"  what="reclaiming agent-written files"; delegable=true ;;
        --project-claim)                    bin="${LOCKDOWN_BIN}" what="claiming a project"; delegable=true ;;
        --project-create)                   bin="${LOCKDOWN_BIN}" what="creating a project"; delegable=true ;;
        --project-unclaim|--project-remove) bin="${UNCLAIM_BIN}"  what="unclaiming a project"; delegable=true ;;
        --sandbox-create)                   bin="${LOCKDOWN_BIN}" what="creating a sandbox clone" ;;
        # --sandbox-push/-remove and the informational verbs reach no helper that can refuse the
        # command: the only sudo either of the sandbox pair makes is unreg_allow's safedir removal,
        # which already warns and carries on rather than failing the verb.
        #
        # --relabel and --stop need no entry: they are the privileged verbs that WORK for an
        # account holding no general grant, since %ai-ops carries a dedicated NOPASSWD rule for
        # each of their helpers. Probing either is harmless -- `sudo -n -l <helper>` answers exit 0
        # for those rules even though the drop-in pins each to its helper's zero-argument form (the
        # trailing ""), because the probe passes no operand. Listing them here would only ever
        # produce "grant present", so they stay out and the verbs reach sudo directly, which
        # reports a missing drop-in itself.
        # The pin also means --stop's FLAGGED forms fall outside the rule and meet sudo's ordinary
        # prompt (deliberate; docs/session-stop.md). This probe could not report that either: it
        # asks about the helper, while what a flag changes is whether the rule matches the command
        # line.
        *) return 0 ;;
    esac
    # A --for run's first helper is the allowlist READER, before the verb's own -- so that is what
    # decides whether the run can start at all.
    [[ -z "${FOR_OPERATOR}" ]] || bin="${ALLOWLIST_BIN}"
    sudo_grant_missing "${bin}" || return 0

    # The route out, printed PLAIN and ahead of die(): die() wraps its text through the error
    # emitter, which would break a command across lines (messaging.rule.md).
    # WHAT THIS MESSAGE DOES NOT SAY. It names the account and the command, and stops. Who that
    # account belongs to is not knowable here -- a service account, a person with a restricted
    # login, an administrator working from one deliberately -- and neither is who runs the
    # suggested command or what they are to each other. So there is no advice to obtain a grant,
    # and nothing is described as anyone's: a message that guesses the arrangement is wrong in
    # exactly the deployments this refusal exists for.
    local -a advice=("Ask an administrator or an ai-ops operator with sudo to run:" "")
    if [[ -n "${FOR_OPERATOR}" ]]; then
        advice+=( "    ai-tools ${verb} --for ${FOR_OPERATOR} $(handover_target "$@")" )
    elif ${delegable}; then
        # --for is the whole answer here: the verb runs against ${INVOKING_USER}'s registry whoever performs
        # it, which is what the pre-configured no-sudo account needs.
        advice+=( "    ai-tools ${verb} --for ${INVOKING_USER} $(handover_target "$@")" )
    elif [[ "${verb}" == --sandbox-create ]]; then
        # The one verb --for is refused on: a clone is made with the git credentials of whoever
        # runs it. The REGISTRY half is delegable all the same, and the clone area is deliberately
        # outside the protected-paths set so that claim is allowed. Two commands, two acts.
        local source_dir clone_dir
        source_dir="$(handover_target "$@")"
        clone_dir="${SANDBOX_ROOT}/$(basename "${source_dir}")"
        # The chown is not optional bookkeeping: the clone is created by whoever runs the first
        # command, and a claim FOR another operator over a tree that operator does not own grants
        # nothing (require_claimable_owner refuses it). Three commands, because the middle one is
        # the only thing that makes the third do anything.
        advice+=( "    ai-tools --sandbox-create ${source_dir}" \
                  "    sudo chown -R ${INVOKING_USER} ${clone_dir}" \
                  "    ai-tools --project-claim --for ${INVOKING_USER} ${clone_dir}" "" \
                  "--sandbox-create takes no --for: the clone is made with the git credentials of" \
                  "whoever runs it, so it is born owned by them. The chown hands it to" \
                  "${INVOKING_USER}, and the claim registers it for ${INVOKING_USER}." )
    else
        local rest=""; (( $# )) && rest="$(printf ' %q' "$@")"
        advice+=( "    ai-tools ${verb}${rest}" )
    fi
    # The trail is written to journald as well, which many hosts let an ordinary account read --
    # a partial view (the file sink is the authoritative one) but one that needs no one else.
    [[ "${verb}" == --audit ]] && advice+=( "" \
        "Some of the same events reach the journal, readable without root on many hosts:" "" \
        "    journalctl -p notice --since '7 days ago' | grep ai-tools" )

    printf '\n' >&2
    printf '  %s\n' "${advice[@]}" >&2
    printf '\n' >&2
    die "${what} needs root, and ${INVOKING_USER} holds no sudo grant for ${bin##*/}." \
        "Membership of ai-ops does not carry a general sudo grant."
}

# require_runas_target <verb> [verb-args...] -- refuse a --for run whose filesystem steps cannot be
# performed AS the target. A no-op without --for, and a no-op for every verb that touches the
# filesystem only through a root helper.
#
# --project-create writes the tree as an owner, through run_as_owner, i.e. `sudo -u <target>`. That
# is a different sudoers question from the one require_sudo_access asks: a host can grant every
# ai-tools helper and still restrict Runas to root, and there the create would fail partway --
# after making directories, or after making the tree and before claiming it. Probing first is what
# keeps the verb's "refused before anything exists" property true on such a host.
#
# Each command the run actually executes is probed rather than one representative, for the reason
# require_sudo_access gives: a sudoers permitting some and not others is then answered accurately.
# `sudo -n -l -u <target> <cmd>` cannot prompt, so this costs no password, and it runs before
# require_for_target's snapshot -- the run's first real sudo -- like every other refusal here.
require_runas_target() {
    local verb="${1:-}"
    [[ -n "${FOR_OPERATOR}" ]] || return 0
    local -a needed=()
    case "${verb}" in
        --project-create) needed=(mkdir git tee setfacl) ;;
        *) return 0 ;;
    esac
    local name resolved blocked=""
    for name in "${needed[@]}"; do
        resolved="$(command -v -- "${name}" 2>/dev/null)" || continue   # absent: its own call site reports it
        if sudo_grant_missing "${resolved}" "${FOR_OPERATOR}"; then blocked="${resolved}"; break; fi
    done
    [[ -n "${blocked}" ]] || return 0

    # Printed plain and ahead of die(), whose emitter would wrap a command across lines.
    printf '\n' >&2
    printf '  %s\n' "Run it as ${FOR_OPERATOR}, or create the project without --for and hand it over:" "" \
                    "    ai-tools --project-create <path>" \
                    "    sudo chown -R ${FOR_OPERATOR} <path>" \
                    "    ai-tools --project-claim --for ${FOR_OPERATOR} <path>" >&2
    printf '\n' >&2
    die "${verb} --for ${FOR_OPERATOR} builds the tree as ${FOR_OPERATOR}, and ${INVOKING_USER} holds no sudo grant to run ${blocked##*/} as that account." \
        "This is a separate sudoers question from the ai-tools helpers: a host can grant every one of those and still restrict which accounts you may act as."
}

# snapshot_allowlist -- point ALLOWLIST at a private copy of the --for target's registry, read
# through the root helper. The copy is read-only input for THIS run: every mutation goes back
# through the helper, which re-reads the real file, so a stale snapshot can never be what a write
# is based on -- and reg_allow/unreg_allow refresh it after theirs. mktemp creates it 0600, and the
# EXIT trap removes it, so another operator's project list does not outlive the command.
ALLOWLIST_SNAPSHOT=""
snapshot_allowlist() {
    if [[ -z "${ALLOWLIST_SNAPSHOT}" ]]; then
        ALLOWLIST_SNAPSHOT="$(mktemp)" || die "cannot create a temporary file for the allowlist snapshot"
        trap 'rm -f -- "${ALLOWLIST_SNAPSHOT}"' EXIT
    fi
    # shellcheck disable=SC2024  # the redirect is meant to be the CALLER's: root reads the
    # 0600 allowlist, this shell writes the snapshot it owns. `sudo tee` would create the temp
    # file as root and leave the CLI unable to read back what it just asked for.
    sudo "${ALLOWLIST_BIN}" --operator "${FOR_OPERATOR}" --print > "${ALLOWLIST_SNAPSHOT}" \
        || die "could not read ${FOR_OPERATOR}'s allowed-projects"
    ALLOWLIST="${ALLOWLIST_SNAPSHOT}"
}

# require_for_target <verb> [verb-args...] -- validate a --for run, resolve the target's group, and
# re-point ALLOWLIST at the target's registry. A no-op without the flag, so nothing below changes
# for an ordinary run.
#
# EVERY refusal here precedes snapshot_allowlist, which is the run's first sudo: a command that is
# going to be refused must not first prompt the operator for a password. That ordering is why the
# --force incompatibility is checked HERE, on the verb's own arguments, rather than where --force is
# parsed in cmd_project_unclaim -- that runs after this gate, so the prompt would come first.
#
# --for is accepted only on the verbs whose whole effect is decided by WHICH operator's allowlist
# covers the path: the registry pair, the two per-project root helpers that gate on allowlist
# coverage, and the listing. Elsewhere it is REFUSED rather than ignored -- a --sandbox-create
# --for that silently cloned as the invoker would leave the tree owned by the wrong operator with
# nothing to show the flag was disregarded.
#
# The target must be ENROLLED in OPERATORS: ai-tools-setfacl and the handback helpers resolve a
# path's owner over that list, so an entry written for an unenrolled name would create a launch
# gate no ownership machinery can act on. Enrollment is checked before the group lookup, so an
# unknown name is refused with the enrolment command rather than a getent failure.
require_for_target() {
    local verb="${1:-}"; shift || true
    [[ -n "${FOR_OPERATOR}" ]] || return 0
    case "${verb}" in
        --project-claim|--project-create|--project-unclaim|--project-remove|\
        --lockdown|--reclaim|--list) ;;
        *) die "--for is not accepted on ${verb}" \
               "it applies to: --project-claim, --project-create, --project-unclaim," \
               "       --project-remove, --lockdown, --reclaim, --list" ;;
    esac
    # --force reaches a tree NO allowlist names, so ai-tools-unclaim cannot resolve its owner from
    # an entry and binds the walk to the INVOKING uid instead -- the guard that stops one operator
    # rewriting another's files. Honouring --for there would have the CLI name one operator while
    # the helper acted as another.
    local a
    for a in "$@"; do
        [[ "${a}" == "--force" ]] || continue
        die "--for cannot be combined with --force" \
            "an unlisted tree has no allowlist entry naming its owner, so the unclaim is bound to" \
            "       you as the invoking operator; run it as ${FOR_OPERATOR}, or unclaim the registered" \
            "       project without --force"
    done
    [[ "${FOR_OPERATOR}" != "${SANDBOX_USER}" ]] \
        || die "the sandbox account is not an operator and must not own projects"
    [[ "${FOR_OPERATOR}" != "root" ]] || die "root is not an operator"
    local conf="${AI_TOOLS_OPERATOR_CONF:-/etc/ai-tools/operator.conf}"
    local -a ops=(); local op found=false
    if ai_tools_conf_list ops "${conf}" OPERATORS 2>/dev/null; then
        for op in "${ops[@]}"; do
            [[ "${op}" == "${FOR_OPERATOR}" ]] && { found=true; break; }
        done
    fi
    ${found} || die "${FOR_OPERATOR} is not a configured ai-tools operator -- enrol it first with:" \
        "       sudo ai-tools-admin operator add ${FOR_OPERATOR}"
    OWNER_GROUP="$(id -gn "${FOR_OPERATOR}" 2>/dev/null)" \
        || die "cannot resolve the primary group of ${FOR_OPERATOR}"
    snapshot_allowlist
}

# Gate the operator-acting commands up front; the informational ones (--help/--version/--list/
# --providers) stay open so an unenrolled user can still read usage and inspect the host.
case "${1:-}" in
    --project-claim|--project-create|--project-unclaim|--project-remove|\
    --sandbox-create|--sandbox-push|--sandbox-remove|\
    --lockdown|--reclaim|--relabel) require_operator ;;
esac

# Refuse a verb whose root helper this caller has no sudo grant for, before require_for_target --
# whose snapshot is a --for run's first sudo. Both gates keep the same ordering rule: a command
# that is going to be refused must not prompt for a password first.
require_sudo_access "$@"

# And refuse a --for run that cannot perform its filesystem steps AS the target -- a separate
# sudoers question from the helper grants above, and one that would otherwise surface partway
# through building a tree. Same ordering rule: ahead of the snapshot, which is the first sudo that
# can prompt.
require_runas_target "$@"

# Validate a --for run and re-point the registry at the target, after require_operator: acting for
# another operator is an operator action, so the invoker must be enrolled before the target is even
# looked up.
require_for_target "$@"

# ── Dispatch ─────────────────────────────────────────────────────────────────────
case "${1:-}" in
    --project-claim)   shift; cmd_project_claim   "$@" ;;
    --project-create)  shift; cmd_project_create  "$@" ;;
    --project-unclaim) shift; cmd_project_unclaim "$@" ;;
    --project-remove)  shift; cmd_project_unclaim "$@" ;;
    --sandbox-create) shift; cmd_sandbox_create "$@" ;;
    --sandbox-push)   shift; cmd_sandbox_push   "${1:-}" ;;
    --sandbox-remove) shift; cmd_sandbox_remove "${1:-}" ;;
    --lockdown)       shift; cmd_lockdown "$@" ;;
    --reclaim)        shift; cmd_reclaim "$@" ;;
    --relabel)        shift; cmd_relabel "$@" ;;
    --providers)      shift; cmd_providers "$@" ;;
    --audit)          shift; cmd_audit "$@" ;;
    --stop)           shift; cmd_stop "$@" ;;
    --status)         cmd_status ;;
    --list)           cmd_list ;;
    --version|-V)     printf 'ai-tools %s\n' "${AI_TOOLS_VERSION}" ;;
    --help|-h|"")     usage ;;
    *) printf 'ai-tools: unknown command: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
esac
