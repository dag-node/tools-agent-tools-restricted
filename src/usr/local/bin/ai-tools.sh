#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/bin/ai-tools
# Project-lifecycle CLI for the ai-tools sandbox. Runs AS the invoking operator (not as root, not as the sandbox
# account). It writes the operator-owned allowlist (~/.config/ai-tools/allowed-projects) directly --
# through conf.lib.sh's allowlist-editing functions, the one implementation shared with the ai-tools-allowlist root
# helper and install.sh -- and reaches the root-owned bits -- the git safe.directory list in /opt/ai-tools/.gitconfig,
# the SELinux label, the ACL, and secret lockdown -- through the sudo root helpers (the *_BIN constants),
# over the operator's general sudo grant: the drop-in carries no NOPASSWD rule for them, so sudo prompts for a password,
# and the sandbox account has no grant. The one helper with a rule of its own is `stop`'s (STOP_BIN).
#
# A command is a bare word in the resource grammar (cli-grammar.rule.md): `projects <verb> [DIRECTORY]` for the project
# lifecycle, `status`, `providers`, `audit` and `stop` for the host, and `--` introduces an option. The command path is
# read once from the arguments, ahead of every gate, into COMMAND (the rule is at verb_in), and each gate
# and the dispatch key on that one string. The option spelling of a command (`--project-claim`) is kept
# for compatibility: it is rewritten to its path before that read and a notice names the preferred form once the message
# library is loaded (OPTION_SPELLINGS).
#
# The preflight gates run before dispatch, in this order: require_bootstrap (provisioned install);
# for the operator-acting commands (OPERATOR_VERBS), require_operator -- the invoking user must be in OPERATORS
# in operator.conf, since the root helpers resolve the caller's identity from that list; require_sudo_access,
# which refuses a verb whose root helper this caller does not hold a sudo grant for, before sudo prompts for a password
# it will then reject; require_runas_target, which refuses a --for run whose filesystem steps sudo will not run
# as the target; and require_for_target, which validates a --for run and re-points the registry at its target. `--help`,
# `--version`, `projects list` and `providers list` stay open to any user.
#
# The principal guard refuses the sandbox account outright and allows root only the verbs that write no operator state
# (ROOT_ALLOWED_VERBS): the reports -- `audit` needs root by construction, since the trail it reads is 700 root:root --
# plus `stop`, whose helper requires root anyway.
#
# `--for <operator>` runs a command on behalf of another enrolled operator, whose registry the entry then lands
# in (require_for_target validates the run). `projects clone` and `projects push` are the sandbox model, a shallow clone
# under SANDBOX_ROOT pushed to a per-repo branch. The account `--for` serves, the snapshot it reads and the sandbox
# model are cli.rule.md's. usage() is the orientation (one line per verb) and ai-tools(1) the reference for every
# per-verb option; tests/unit/cli-verbs.sh and tests/unit/man.sh hold each to the dispatcher. Its domain rules are
# cli.rule.md (what each command does) and cli-grammar.rule.md (how it is spelled).

set -euo pipefail
IFS=$'\n\t'

readonly SANDBOX_USER="@SANDBOX_USER@"
readonly SANDBOX_GROUP="@SANDBOX_GROUP@"
# Substituted at deploy time (install.sh from packaging/VERSION; the RPM from %{version}); a raw source-tree run reports
# "dev".
AI_TOOLS_VERSION="@AI_TOOLS_VERSION@"
[[ "${AI_TOOLS_VERSION}" == @*@ ]] && AI_TOOLS_VERSION="dev"
readonly AI_TOOLS_VERSION
# AI_TOOLS_GITCONFIG / AI_TOOLS_ALLOWLIST / AI_TOOLS_SANDBOX_ROOT: test hooks of the family the root helpers carry
# root-only (see tests.rule.md). Here they are operator-settable, since the CLI runs as the operator and not
# through sudo -- and that operator owns the two files and every clone anyway, so an override does not add reach they
# could not already have by editing the files directly or by claiming a clone made elsewhere. sudo strips all three
# (env_reset, not env_keep) before any root helper, which re-resolves the real paths itself, and the sandbox account is
# refused by the principal guard before any of them is read. The clone-area override moves where a clone is made
# and which paths read as the sandbox kind; the destructive clone removal stays scoped to a direct child of whatever
# directory that is, and the protected-paths backstop still refuses a system directory there.
readonly GITCONFIG="${AI_TOOLS_GITCONFIG:-/opt/ai-tools/.gitconfig}"
readonly SANDBOX_ROOT="${AI_TOOLS_SANDBOX_ROOT:-/var/opt/ai-tools/sandbox-projects}"
# Where bootstrap writes each enabled agent's stable launcher symlink, its last load-bearing artifact per agent:
# the require_bootstrap gate and `status` key on those links, and each launch wrapper resolves its own.
# AI_TOOLS_LAUNCHER_DIR is the hook relabel.lib.sh reads for the same directory, operator-settable here like
# AI_TOOLS_GITCONFIG, AI_TOOLS_ALLOWLIST and AI_TOOLS_SANDBOX_ROOT: what it moves is a report and an early refusal, no
# access decision reads it, and the sandbox account is refused before it is read.
readonly LAUNCHER_DIR="${AI_TOOLS_LAUNCHER_DIR:-/opt/ai-tools/bin}"
# Root-only secret lockdown helper.
readonly LOCKDOWN_BIN="/usr/local/libexec/ai-tools/ai-tools-lockdown"
# Root-only SELinux project-label helper: applies/reverts ai_tools_project_t so the confined agent can access a claimed,
# in-place tree; the per-project semanage fcontext rule it adds needs root. Sandbox clones do not use it (static rule +
# plain restorecon -- see relabel_clone).
readonly RELABEL_BIN="/usr/local/libexec/ai-tools/ai-tools-relabel"
# Root-only ACL helper: applies the project's group-permission ACL (default + access group:SANDBOX_GROUP:rwX, other
# denied) so files the projects user's git checkout/merge writes under a restrictive umask stay group-accessible
# to the agent. CAP_FOWNER lets it ACL files the projects user does not own.
readonly SETFACL_BIN="/usr/local/libexec/ai-tools/ai-tools-setfacl"
# Root-only setgid helper: sets group SANDBOX_GROUP + the setgid bit on a claimed project's directories. The operator is
# not a SANDBOX_GROUP member (multi-operator), so the group change needs root; the helper carries its own allowlist +
# owner guard. Also invoked by the handback daemon for the SessionStart normalization pass.
readonly SETGID_BIN="/usr/local/libexec/ai-tools/ai-tools-setgid"
# Root-only unclaim helper: reverses the filesystem side of a claim -- clears the agent ACL + default ACL, regroups
# the tree to a target group, and removes group write. Root is what a chgrp to an arbitrary group, and a change
# to a file the projects user does not own, need.
readonly UNCLAIM_BIN="/usr/local/libexec/ai-tools/ai-tools-unclaim"
# Root-only git safe.directory helper. /opt/ai-tools/.gitconfig is root-owned 644: world-readable (the agent reads
# safe.directory on startup) and root-write-only, so neither the operator nor the agent writes it directly --
# the operator reaches the validated add and `--remove` through this helper.
readonly SAFEDIR_BIN="/usr/local/libexec/ai-tools/ai-tools-safedir"
# Root-only ownership-reclaim helper: hands agent-written files under a project back to the operator via ai-tools-chown
# (the per-path trust boundary), needed for the .git tree the per-session sweeps skip; useful before an ACL-unaware
# backup.
readonly RECLAIM_BIN="/usr/local/libexec/ai-tools/ai-tools-reclaim"
# Root-only cross-operator allowlist helper: reads and edits ANOTHER enrolled operator's allowed-projects for a `--for`
# run; root is needed for the READ too, since an allowlist is 0600 inside a 0700 .config/ai-tools. Only a `--for` run
# reaches it -- without the flag the CLI writes the invoker's own registry directly.
readonly ALLOWLIST_BIN="/usr/local/libexec/ai-tools/ai-tools-allowlist"

# Reader for the refusal/rejection trails (`audit`). Root-only, since the trail it reads is 700 root:root.
readonly AUDIT_BIN="/usr/local/libexec/ai-tools/ai-tools-audit"
# Session-stop helper (`stop`). Root-only, since a session is a transient unit in the sandbox account's own
# `systemd --user` manager, which no operator can reach. The one helper with a %ai-ops NOPASSWD rule of its own, pinned
# to the zero-argument form by the drop-in's trailing "", so the bare command runs without a prompt and a flagged form
# meets sudo's ordinary prompt. What it accepts, and why so little: cmd_stop.
readonly STOP_BIN="/usr/local/libexec/ai-tools/ai-tools-stop"
# Sentinel in a guard CLAUDE.md (see drop_lockdown_guard) so the lockdown step can recognise and remove its own
# placeholder once secrets are secured.
readonly GUARD_MARKER="ai-tools-lockdown-guard"

# ── Verb sets ────────────────────────────────────────────────────────────────────
# Each table names a set of commands by their command path -- the string COMMAND holds, `projects claim` -- and each is
# named ONCE here, so a command added to a set cannot be added to one of its readers and missed by another.
#
# ROOT_ALLOWED_VERBS -- what root may run. The criterion is WRITES NO OPERATOR-OWNED STATE, which is what the root guard
# exists to protect: a registry written by root names an owner whose own launch gate cannot read it. A verb qualifies
# on what it writes, whatever it reads, so `stop` belongs here despite being the one member that ACTS: it does not write
# a registry, and root is the identity an unattended detector usually runs as -- the caller this rung most has to serve.
# Admitting it does not add a capability either, since root can already run ai-tools-stop directly and can signal any
# process on the host; what it removes is a CLI that refused the one principal its own helper requires. Read
# by the principal guard, by that guard's own refusal (which lists them), and by ai-tools(1).
readonly ROOT_ALLOWED_VERBS=("audit" "status" "projects list" "providers list" "stop")
# BOOTSTRAP_EXEMPT_VERBS -- what runs on an unprovisioned host. Deliberately NOT ROOT_ALLOWED_VERBS: each of these is
# meant for a host that may be broken (`status` reports the unprovisioned state itself; `audit` reads a historical
# trail, which an install that never finished does not invalidate; `stop` ends sessions already running, and does not
# read toolchain state to do it -- the gate keys on the enabled agents' launcher symlinks, so leaving `stop` behind it
# would put the incident ladder's last rung out of reach on a host that lost them while sessions were running).
# `--help`, `--version` and the bare invocation describe the CLI rather than the toolchain -- usage()
# and AI_TOOLS_VERSION read no installed state -- and gating them leaves a caller who cannot print the usage with only
# the gate's own message to find the provisioning command by. `projects list` and `providers list` describe a toolchain
# that has to exist first and stay behind the gate.
readonly BOOTSTRAP_EXEMPT_VERBS=("status" "audit" "stop" "--help" "--version")
# OPERATOR_VERBS -- what only an enrolled operator may run. The criterion is ACTS AS AN OPERATOR: the verb resolves
# the caller's identity out of OPERATORS somewhere in its call chain (the root helpers do, via operator.lib.sh),
# so an unenrolled caller would otherwise get through the registry writes and the confirm prompts only to be refused
# by the first helper that resolves an owner. Its complement is the informational set -- `--help`, `--version`,
# `projects list`, `providers list`, `status`, `audit` and `stop` -- which stays open so an unenrolled user can still
# read usage and inspect the host.
readonly OPERATOR_VERBS=("projects create" "projects claim" "projects unclaim" "projects remove"
                         "projects enable" "projects disable" "projects clone" "projects push"
                         "projects lockdown" "projects handback")
# FOR_ALLOWED_VERBS -- what --for accepts: the verbs whose whole effect is decided by WHICH operator's allowlist covers
# the path. Elsewhere the flag is REFUSED rather than ignored (see
# require_for_target).
readonly FOR_ALLOWED_VERBS=("projects claim" "projects create" "projects unclaim" "projects remove"
                            "projects enable" "projects disable" "projects lockdown" "projects handback"
                            "projects list")
# COLLECTIONS -- the plural nouns a verb follows. A bare one is its `list`, the grammar's zero-argument default.
readonly COLLECTIONS=(projects providers)
# OPTION_SPELLINGS -- the option spelling of each command, from the releases before the resource grammar, and the two
# short options that went with them, each mapped to what it runs: a command path, or for `-g` the long option it stands
# for. Every key is kept for compatibility, since the typed command surface is the one interface an operator's own
# scripts bind to, and the collection form is the preferred one: rewrite_option_spelling applies the table ahead
# of every gate, so every verb table and the dispatch see the command path alone and no key sits in a dispatch arm
# or in usage(), and note_option_spellings names the preferred form. One row per line:
# tools/generators/option-spellings.sh reads the rows by text to generate docs/option-spellings.md,
# and tests/unit/cli-verbs.sh holds every value to a dispatched
# path.
declare -rA OPTION_SPELLINGS=(
    [--list]="projects list"
    [--project-create]="projects create"
    [--project-claim]="projects claim"
    [--project-unclaim]="projects unclaim"
    [--project-remove]="projects remove"
    [--project-enable]="projects enable"
    [--project-disable]="projects disable"
    [--sandbox-create]="projects clone"
    [--sandbox-push]="projects push"
    [--sandbox-remove]="projects remove"
    [--lockdown]="projects lockdown"
    [--reclaim]="projects handback"
    [--providers]="providers list"
    [--status]="status"
    [--audit]="audit"
    [--stop]="stop"
    [-V]="--version"
    [-g]="--group"
)

# verb_in <command> <path>... -- true when <command> is one of the named command paths.
#
# A command path is the leading argument tokens that spell a command, as one space-joined string: a token matching
# ^[a-z][a-z-]*$ is a command word; the first one is the path, and where it names a COLLECTION the next command word is
# its verb, so the path is at most two tokens and ends at the first option or path argument. A bare collection is its
# `list`, no tokens at all is `--help`, and `-h` is `--help`. The options answered as commands, `--help`
# and `--version`, are paths of their own. read_command applies the rule once, to COMMAND, and every verb table is keyed
# on it, the shape tests/unit/man.sh reads for ai-tools-admin(8).
verb_in() {
    local verb="$1"; shift
    local name; for name in "$@"; do [[ "${verb}" == "${name}" ]] && return 0; done
    return 1
}
# join_words <word>... -- the words joined by single spaces, for a message. Pins IFS locally: the CLI runs
# under IFS=$'\n\t', so a bare "${array[*]}" would join on a NEWLINE.
join_words() { local IFS=' '; printf '%s' "$*"; }
# join_paths <path>... -- the command paths joined by a comma and a space, for a message that lists a table: a path is
# itself two words, so a space-joined list would run them together.
join_paths() { local IFS=','; printf '%s' "${*// /_}" | sed 's/,/, /g; s/_/ /g'; }

# read_command <arg>... -- set COMMAND to the command path "$@" spells and COMMAND_TOKENS to the number of leading
# arguments it took, by verb_in's rule. An argument that is neither a command word nor a recognised option -- a path,
# or an option no command answers -- is taken whole as the path, so the dispatch refuses it as an unknown command rather
# than reading the argument after it.
COMMAND=""; COMMAND_TOKENS=0
read_command() {
    case "${1:-}" in
        "")        COMMAND="--help" ;;
        --help|-h) COMMAND="--help";    COMMAND_TOKENS=1 ;;
        --version) COMMAND="--version"; COMMAND_TOKENS=1 ;;
        *)
            COMMAND="$1"; COMMAND_TOKENS=1
            if [[ "$1" =~ ^[a-z][a-z-]*$ ]] && verb_in "$1" "${COLLECTIONS[@]}"; then
                if [[ "${2:-}" =~ ^[a-z][a-z-]*$ ]]; then
                    COMMAND="$1 $2"; COMMAND_TOKENS=2
                else
                    COMMAND="$1 list"
                fi
            fi ;;
    esac
}

# refuse_early <code> <line>...  -- the refusals that fire before msg.lib.sh is sourced: the principal guards
# and --for's argument check, which answer ahead of every library load. They cannot reach die(), so this renders
# what plain mode renders -- the code on its own leading line, then each caller line whole -- and exits 1. The matcher
# is the library's own anchored form (tests/unit/msg.sh holds every inline copy to it).
refuse_early() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf '%s\n' "$@" >&2
    exit 1
}

# ── Invoker guards ───────────────────────────────────────────────────────────────
# This is a user tool. It must run as the projects user, and never as the sandbox account -- the agent must not manage
# its own allowlist. That refusal is unconditional and first: no verb, and no argument, makes the agent a legitimate
# caller.
#
# Root is refused for every verb that WRITES (it would write the operator registries owned by root, where the operator's
# own launch gate cannot read them) and allowed the verbs that write no operator-owned state (ROOT_ALLOWED_VERBS).
# That split is decided once the verb is known -- see "Root and the read-only reports".
INVOKING_USER="$(id -un)"
[[ "${INVOKING_USER}" == "${SANDBOX_USER}" ]] \
    && refuse_early MSG-Q6Q8 "ai-tools: refusing to run as the sandbox account ${SANDBOX_USER}"

HOME_DIR="$(getent passwd "${INVOKING_USER}" | cut -d: -f6)"
[[ -d "${HOME_DIR}" ]] || { echo "ai-tools: cannot resolve home for ${INVOKING_USER}" >&2; exit 1; }
readonly INVOKING_USER HOME_DIR

# ── --for <operator>: act on another enrolled operator's project registry ────────
# A service account that runs an agent has no password, so it cannot authenticate the claim's own root helpers --
# and a project claimed by a human lands in the HUMAN's registry, which is not the one that account's launch gate reads.
# --for closes both: a human operator performs the claim ON BEHALF OF the target, whose allowlist then covers the path,
# so ai-tools-setfacl grants user:<target>, the handback restores to <target>, and that account's own launch finds
# the project already claimed and never reaches a password prompt.
#
# The flag is separated from the command's own arguments HERE, before the registry path is resolved and before dispatch,
# so every command reads one already-decided owner instead of each parsing the flag itself. Validation (is the target
# enrolled, does this verb accept --for) needs conf.lib.sh and runs at the dispatch gate.
FOR_OPERATOR=""
_forless_args=()
while (( $# )); do
    case "$1" in
        --for)   FOR_OPERATOR="${2-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
        --for=*) FOR_OPERATOR="${1#--for=}"; shift ;;
        *)       _forless_args+=("$1"); shift; continue ;;
    esac
    # Both spellings are the same situation -- the flag names the operator the run acts for, and neither an empty value
    # nor another option in its place is a name -- so they share one refusal, checked once after the branch that read
    # the value.
    [[ -n "${FOR_OPERATOR}" && "${FOR_OPERATOR}" != -* ]] \
        || refuse_early MSG-B4G2 "ai-tools: --for needs an operator name"
done
set -- "${_forless_args[@]}"
unset _forless_args

# ── A verb that moved to ai-tools-admin ──────────────────────────────────────────
# --relabel is spelled correctly, worked in an earlier release, and is printed as the remedy in release notes that stay
# published, so the usage()-plus-"unknown command" a stranger gets would read as a typo. It is a pointer and not
# an alias: the command reconciles a root-owned pin and a file context, so it runs as root, which this CLI refuses.
#
# It answers ahead of every gate on purpose. The bootstrap gate would otherwise send an unprovisioned host
# to the provisioning command, and the root guard would answer `sudo ai-tools --relabel` -- the spelling the older docs
# printed -- with a list of the verbs root may run, none of which reconciles an entrypoint. Exit 2 is the documented
# code for a rejected command line (ai-tools(1)).
if [[ "${1:-}" == "--relabel" ]]; then
    echo "ai-tools: --relabel is now a root command:" >&2
    echo "              sudo ai-tools-admin system entrypoints relabel" >&2
    exit 2
fi

# ── Option spellings ─────────────────────────────────────────────────────────────
# rewrite_option_spelling <arg>... -- set REWRITTEN_ARGS to the arguments with each OPTION_SPELLINGS key replaced by its
# value: the leading argument where it is a key, since an option-spelled command leads the command line, and `-g`
# wherever it stands, since it is an option of `projects unclaim`. Each rewrite is appended to OPTION_SPELLINGS_USED
# as the token typed, a tab, and the preferred form -- `ai-tools` and the command path, or the long option alone --
# for note_option_spellings, which prints once msg.lib.sh is loaded. It runs here, after `--for` is separated
# out and ahead of read_command, so every gate and the dispatch read the command path alone. `--relabel` is left
# out of the table: it names a root command this CLI refuses to run, and its pointer answers it ahead of this rewrite.
OPTION_SPELLINGS_USED=()
REWRITTEN_ARGS=()
rewrite_option_spelling() {
    local argument
    REWRITTEN_ARGS=()
    # An empty subscript is a bash error, so the leading argument is tested before it is looked up.
    if [[ -n "${1:-}" && "$1" != -g && -n "${OPTION_SPELLINGS[$1]+set}" ]]; then
        OPTION_SPELLINGS_USED+=("$1"$'\t'"ai-tools ${OPTION_SPELLINGS[$1]}")
        # The value is a space-joined command path; this CLI's IFS has no space, so the split pins its own.
        local IFS=' '
        read -ra REWRITTEN_ARGS <<<"${OPTION_SPELLINGS[$1]}"
        shift
    fi
    for argument in "$@"; do
        if [[ "${argument}" == -g ]]; then
            OPTION_SPELLINGS_USED+=("-g"$'\t'"${OPTION_SPELLINGS[-g]}")
            argument="${OPTION_SPELLINGS[-g]}"
        fi
        REWRITTEN_ARGS+=("${argument}")
    done
}
rewrite_option_spelling "$@"
set -- "${REWRITTEN_ARGS[@]}"
unset REWRITTEN_ARGS

# ── The command path ─────────────────────────────────────────────────────────────
# Read once, after `--for` is separated out and the option spellings are rewritten, before the first gate, so every gate
# and the dispatch key on one string. The arguments left are the command's own.
read_command "$@"
readonly COMMAND COMMAND_TOKENS
set -- "${@:COMMAND_TOKENS+1}"

# ── Root and the verbs that write no operator state ──────────────────────────────
# Root may run the verbs that write no registry -- the four reports, plus `stop` -- and no other. `audit` is
# why the carve-out exists: the trail it reads is 700 root:root, so the verb needs root by construction, and a blanket
# refusal left it unreachable from BOTH sides on a host whose only operator does not hold a general sudo grant. `stop`
# is here for the mirror of that reason: its helper requires root, and an incident response running as root should reach
# the rung through the same command an operator uses. The mutating verbs keep refusing root for the reason this guard
# has always existed -- they would write the operator registries owned by root, where that operator's own launch gate
# cannot read them.
#
# The check runs HERE, after --for is separated out, for two reasons. Before that point the command is not reliably
# the first argument (`ai-tools --for op projects` leads with the flag). And running it here refuses --for for root
# in EITHER argument order: root is not in OPERATORS, so a --for run performed by root would write an entry that names
# an owner no ownership helper can resolve. require_operator does not cover that on its own -- it gates the mutating
# verbs, and `projects list` is not one of them.
#
# refuse_early, not die(): this runs before msg.lib.sh is sourced, like the sandbox refusal.
root_may_run() {
    [[ -z "${FOR_OPERATOR}" ]] || return 1
    verb_in "${COMMAND}" "${ROOT_ALLOWED_VERBS[@]}"
}
if [[ "${INVOKING_USER}" == "root" ]] && ! root_may_run; then
    refuse_early MSG-H6W7 "ai-tools: do not run as root -- run as the projects user, without sudo" \
        "          (the CLI invokes sudo itself for the steps that need it)" \
        "          as root you can run the verbs that write no operator state: $(join_paths "${ROOT_ALLOWED_VERBS[@]}")"
fi

# The operator this run acts FOR: the --for target, or the invoker. Every message that names the owner a file ends
# up with, and every scan that matches on that owner, reads these rather than INVOKING_USER -- on a --for run the tree
# belongs to the target, so naming the invoker would misreport who ends up holding the files. What a root helper's walk
# treats as "the operator" is still resolved per path from the path's own allowlist coverage, never from either
# of these.
OWNER_USER="${FOR_OPERATOR:-${INVOKING_USER}}"
# Without --for the owner is the invoker, whose group always resolves. With --for the group is resolved
# by require_for_target only AFTER the target is confirmed enrolled: a name that is neither an operator nor a user
# on this host has to be refused with the actionable "not a configured ai-tools operator -- enrol it with ..." message,
# not with a getent failure that names the wrong problem.
OWNER_GROUP=""
if [[ -z "${FOR_OPERATOR}" ]]; then
    OWNER_GROUP="$(id -gn "${OWNER_USER}" 2>/dev/null)" \
        || { echo "ai-tools: cannot resolve the primary group of ${OWNER_USER}" >&2; exit 1; }
fi
readonly FOR_OPERATOR OWNER_USER

# The operator this run acts FOR rides as per-run log context (logging.rule.md). journald stamps the invoking uid
# itself, so the field adds the `--for` case, where the operator whose registries and tree a command edits is not
# the one who ran it.
AI_TOOLS_LOG_OPERATOR="${OWNER_USER}"

# The registry this run reads and writes. Without --for it is the invoker's own file, read and written directly.
# With `--for`, require_for_target re-points it at a root-side SNAPSHOT of the target's file: an allowlist is 0600
# inside a 0700 .config/ai-tools, so one operator cannot read another's at all, and every decision made from it (is
# the path listed, which '!' exclusions apply, what `projects list` reports) would otherwise read an unreadable file
# as an empty one. One resolution point for readers AND writers (reg_allow/unreg_allow), so a fixture test that sets
# AI_TOOLS_ALLOWLIST never mutates the operator's real registry. Root-only test hook -- see the GITCONFIG note
# for why the override grants the CLI's operator caller no new capability.
ALLOWLIST="${AI_TOOLS_ALLOWLIST:-${HOME_DIR}/.config/ai-tools/allowed-projects}"

# ── Output / prompt helpers ──────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    readonly C_BOLD=$'\033[1m' C_DIM=$'\033[2m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_RED=$'\033[31m' C_RST=$'\033[0m'
else
    readonly C_BOLD='' C_DIM='' C_GRN='' C_YEL='' C_RED='' C_RST=''
fi

# Each takes ONE line and prints it. "$1", not "$*": this CLI runs under IFS=$'\n\t', so "$*" would join a second
# argument on a NEWLINE rather than a space -- a silently mis-rendered message for a caller that reasonably expects
# printf-style words.
say()     { printf '%s\n' "$1"; }
section() { printf '\n%s%s%s\n' "${C_BOLD}" "$1" "${C_RST}"; }
ok()      { printf '  %s✓%s %s\n' "${C_GRN}" "${C_RST}" "$1"; }
warn()    { ai_tools_msg_warn "$@"; }
note()    { ai_tools_msg_notice "$@"; }
# die takes the library's optional leading code and carries it into the log line -- as the leading token of the text
# and as the AI_TOOLS_MSG field, which ai_tools_log_coded writes
# (logging.rule.md).
# The code is split off so the "ai-tools: " prefix lands on the message rather than on the code.
die() {
    local code=""
    if ai_tools_msg_is_code "${1-}"; then code="$1"; shift; fi
    ai_tools_log_coded error "${code}" "$*"
    ai_tools_msg_error ${code:+"${code}"} "ai-tools: $*"
    exit 1
}
# die_usage is die for a command line the verb refuses, and exits 2 -- the usage code ai-tools(1) states.
die_usage() {
    local code=""
    if ai_tools_msg_is_code "${1-}"; then code="$1"; shift; fi
    ai_tools_log_coded error "${code}" "$*"
    ai_tools_msg_error ${code:+"${code}"} "ai-tools: $*"
    exit 2
}
# The claim/sandbox flows are sequences of SELF-CONTAINED blocks, each opened by a wide headline box (title + summary
# prose), with details, prompts, and results printed plain under it and a closing ✓ (or a fail-closed error) ending
# the block -- see messaging.rule.md. headline() narrates to stdout; headline_warn() carries a "WARNING: ..."-titled
# block on stderr.
headline()      { ai_tools_msg_headline "$1" 1 "${@:2}"; }
headline_warn() { ai_tools_msg_headline "$1" 2 "${@:2}"; }

# Shared leveled logger -- journald only (this CLI runs as the projects user, not root, so it cannot write the root-only
# /var/log/ai-tools files). Records workflow milestones (project/sandbox created, pushed, removed, locked down) at INFO
# under the tag "ai-tools". Best-effort no-op fallback if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
    ai_tools_log_structured() { :; }; ai_tools_log_coded() { :; }
    # Not a logger but the display sanitizer the drift records print paths through, so it keeps working, byte for byte
    # the library's: printable ASCII kept, every other byte replaced.
    ai_tools_log_sanitize() { local LC_ALL=C; printf '%s' "${1//[^[:print:]]/?}"; }
fi

# Shared message formatter -- die()/warn() frame their text in the paste-safe '#' alert box (50 columns)
# and headline()/headline_warn() open the wide (80-column) flow blocks on a terminal, plain text otherwise,
# and ai_tools_msg_confirm carries every yes/no prompt. REQUIRED, like safe-paths.lib.sh: the confirms gate real
# decisions, so a missing lib fails closed instead of running through a private fallback (see messaging.rule.md).
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
# One fixed 80-column frame for every box this CLI shows: a claim/reclaim run emits a SEQUENCE of boxes, which aligns
# instead of each sizing to its own text.
export AI_TOOLS_MSG_FULLWIDTH=1

# note_option_spellings -- one notice per token rewrite_option_spelling recorded, ahead of every gate and the dispatch,
# so a refusal that follows still names the spelling that led to it. The command then runs with its exit status
# unchanged: the spelling is kept, and the notice says which form is preferred. The preferred form stands on a line
# of its own, since the alert wraps its text and a command must not break across lines (messaging.rule.md).
note_option_spellings() {
    local used
    for used in "${OPTION_SPELLINGS_USED[@]}"; do
        note MSG-W3W8 "option spelling ${used%%$'\t'*} is kept for compatibility -- the preferred form is:" \
            "${used#*$'\t'}"
    done
}
note_option_spellings

# Protected-paths backstop (safe-paths.lib.sh): refuse to claim a system directory, and vet ancestors
# for the reachability grant (confirm_ancestor_traversal -> grantable_ancestor). It is REQUIRED: FAIL CLOSED if it
# cannot be sourced (missing, unreadable, or the lib dir is not traversable) or does not define its guard. A broken
# install is not a state to run through with the guard disabled -- a stubbed no-op would skip the system-dir refusal
# AND silently never grant ancestor traversal (a claimed project the agent cannot reach). Log to journald (via logger,
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

# The shared config grammar, which this CLI reads allowed-projects with (ai_tools_conf_path_entry) so its project
# listing and the launch wrapper's gate agree on what every line denotes. REQUIRED: a private fallback parser is exactly
# the drift the shared grammar exists to prevent, and a CLI that lists a different set of projects than the wrapper will
# launch in is worse than one that
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

# Skip-dir selector (the single skip source shared with the sweeps and the claim helpers). The claim drift scan uses it
# to tell repairable hits from skip-listed ones. Fail-soft: a missing lib classifies every path as walkable -- a noisier
# report, never a wrong repair (the root helpers load their own copy for the walks).
readonly SKIP_DIRS_LIB="/usr/local/lib/ai-tools/skip-dirs.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/skip-dirs.lib.sh
source "${SKIP_DIRS_LIB}" 2>/dev/null \
    || ai_tools_skip_find_expr() { AI_TOOLS_SKIP_NAMES=(); AI_TOOLS_SKIP_FIND_EXPR=(); return 0; }

# Unreadable ancestor configuration (ancestor-config.lib.sh): the claim reports the configuration files in a project's
# ancestry that ai_tools_session_can_read refuses, so a build that would fail on one says so here rather than
# from inside a session. Best-effort: the report is advisory and does not change any file, so a missing lib costs
# the notice and leaves every claim step as it was. It is sourced AFTER safe-paths, whose backstop bounds its walk.
readonly ANCESTOR_CONFIG_LIB="/usr/local/lib/ai-tools/ancestor-config.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/ancestor-config.lib.sh
source "${ANCESTOR_CONFIG_LIB}" 2>/dev/null || true

# Service-health registry (services.lib.sh): the single source `ai-tools status`, the launch wrapper's pre-launch health
# warning and `ai-tools-admin status` share, so no two of them disagree on which units matter, what one is doing,
# or how to fix it. Best-effort -- only `status` reads it, and it degrades to a "registry unavailable" notice rather
# than failing any command.
readonly SERVICES_LIB="/usr/local/lib/ai-tools/services.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/services.lib.sh
source "${SERVICES_LIB}" 2>/dev/null || true
# The exit statuses `status` ends with and the fold that computes one (records-base.lib.sh, ai-tools-records(5)). Loaded
# inside cmd_status, the one command that reads it, and required there: a report whose exit contract did not load
# refuses, so it does not exit 0 over a host it did not read. Loading it here would make a broken install refuse `stop`,
# which must reach the incident ladder's last rung on exactly such a host.
readonly RECORDS_BASE_LIB="/usr/local/lib/ai-tools/records-base.lib.sh"
# The claim's outcome records (records-tsv.lib.sh) and the per-path checks it collects drift and verifies repairs
# with (project-permissions.lib.sh). Loaded by claim_load_libraries, for the same reason records-base is loaded late.
readonly RECORDS_TSV_LIB="/usr/local/lib/ai-tools/records-tsv.lib.sh"
readonly PROJECT_PERMISSIONS_LIB="/usr/local/lib/ai-tools/project-permissions.lib.sh"
# The secret-name classifier ai-tools-lockdown matches with (secret-patterns.lib.sh), which marks a secret-named path
# in the claim's drift lists. Loaded by claim_load_libraries and not required: the mark is advisory, and the secret gate
# makes the decision whether or not it loaded.
readonly SECRET_PATTERNS_LIB="/usr/local/lib/ai-tools/secret-patterns.lib.sh"
# The toolchain readers `status` makes from the operator's vantage (toolchain.lib.sh): a disabled agent's remaining
# launcher link, and the Node version the enabled agents' links name. Loaded by the sections that read it,
# through toolchain_lib_loaded, since only `status` reads it.
readonly TOOLCHAIN_LIB="/usr/local/lib/ai-tools/toolchain.lib.sh"
readonly CONFINEMENT_LIB="/usr/local/lib/ai-tools/confinement.lib.sh"
# The account whose `systemd --user` units the registry may read live. Naming it does not by itself enable the probe:
# _ai_tools_service_systemctl still requires root and a working machine transport, and refuses this CLI run
# as an operator. So an operator's report is unchanged, while `sudo ai-tools status` completes the reads that need root
# -- one resource, degrading by privilege, which is what keeps this report and `ai-tools-admin status` from being two
# answers.
if declare -F ai_tools_service_sandbox_account >/dev/null 2>&1; then
    ai_tools_service_sandbox_account "${SANDBOX_USER}"
fi

# ── Reaching a root helper ───────────────────────────────────────────────────────
# Most verbs do work only root can do, through a helper in /usr/local/libexec/ai-tools (750 root:root -- the operator
# cannot even stat one). Two facts about the caller decide HOW, and WHETHER, that helper is reached; both are answered
# here rather than at each call site.
#
# ALREADY ROOT -- run the helper directly, with no sudo in between. Root reaches only ROOT_ALLOWED_VERBS (the principal
# guard), and of those `audit` and `stop` reach a helper through here. The condition lives here rather than inside each
# command so a verb added to that set later inherits it.
#
# NO SUDO GRANT -- refuse before sudo prompts. Every helper outside the %ai-ops NOPASSWD rules (the shipped sudoers
# drop-in holds their list) is reached by a plain sudo, which assumes the operator ALSO holds a general grant.
# An ai-ops-only account does not -- and sudo authenticates BEFORE it refuses, so such an operator is asked
# for a password and turned away after supplying it, for a decision that was knowable without asking.
# require_sudo_access answers it up front instead, and probes with -n so the probe itself never prompts.
#
# THE PROBE IS NOT A SECURITY GATE and is deliberately fail-OPEN, against the project's usual direction. sudo remains
# the thing that decides; this only replaces a refusal that was going to happen anyway with one that says what to do
# instead. So an inconclusive probe falls through to the call site and lets sudo answer, because the failure it would
# otherwise cause is the serious one: refusing an operator who does hold a grant, on the strength of a message we did
# not parse.

# run_root_helper <bin> [args...] -- run a root helper, directly when the caller is already root and through sudo
# otherwise. The helper's exit status propagates either way (`audit` and `stop` both publish theirs as their own
# contract).
run_root_helper() {
    if [[ "${INVOKING_USER}" == "root" ]]; then "$@"; else sudo "$@"; fi
}

# root_helper_reachable -- false only when no root helper can be reached at all: not root, and no sudo binary. Call
# sites that fall back to "run as root: <helper>" gate on this rather than on a bare `command -v sudo`, which reads
# as missing to root as well.
root_helper_reachable() { [[ "${INVOKING_USER}" == "root" ]] || command -v sudo >/dev/null 2>&1; }

# sudo_grant_missing <bin> -- true only when sudo will refuse <bin> for this caller OUTRIGHT, without a password ever
# being able to help.
#
# `sudo -n -l <bin>` asks sudo the question directly and, with -n, cannot prompt. Four answers, and the second is
# the one this reads:
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
#                                site, this probe's fail-open direction.
#
# Silence is only conclusive while sudo is answering at all, so it is confirmed against a bare `sudo -n -l`: that lists
# the caller's whole rule set (an ai-ops member always has one), and its success is what separates "sudo knows this
# caller and has no rule for that command" from a sudo that failed for its own reasons -- an unreachable sudoers
# backend, a host that refuses -l outright. Only the first is read as a missing grant; the second falls open like any
# other answer that cannot be read. LC_ALL=C pins the wording of the one text match. An optional <runas> asks the same
# question about `sudo -u <runas> <bin>` -- the form run_as_owner uses -- so a host whose sudoers restricts Runas
# to root is read here rather than at the call site, where it would abort a create half-way through a tree.
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

# ── Reacting to a root step that did not apply ───────────────────────────────────
# Every root helper authenticates on its own, and a flow cannot pre-authenticate a step: a hardened sudoers may set
# timestamp_timeout=0, where a credential is never cached and every invocation prompts, so one mistyped password costs
# a full round of attempts PER STEP. note_root_failure asks ONCE whether to attempt the rest -- default NO, which is
# also the no-terminal answer -- and once per RUN rather than per step or per project. It is asked rather than inferred:
# a mistyped password and an absent grant are indistinguishable at this point and call for opposite actions.
#
# The answer decides only which steps are ATTEMPTED; what a partial result means is the caller's to report, and differs
# per verb (cli.rule.md).
ROOT_STEP_FAILURES=0
_root_step_asked=false
_root_step_carry_on=1
note_root_failure() {
    ROOT_STEP_FAILURES=$(( ROOT_STEP_FAILURES + 1 ))
    if ! ${_root_step_asked}; then
        _root_step_asked=true
        say ""
        if confirm "That step needed root and did not apply. Try the remaining steps? (each one asks for your password again)" n; then
            _root_step_carry_on=0
        else
            _root_step_carry_on=1
        fi
    fi
    return "${_root_step_carry_on}"
}

# confirm <prompt> <y|n>  -- the shared yes/no prompt (ai_tools_msg_confirm; see msg.lib.sh): the explicit default
# decides the Enter answer and the no-tty answer, so each caller states the default whose unattended answer is the safe
# outcome for its question. AI_TOOLS_ASSUME_YES=1 fast-tracks only default-YES prompts (the lib's rule); a default-NO
# prompt is answered ahead of time only by the CLI's own `--yes` flag -- the launch wrapper passes it for a delegated
# `projects claim` after taking its own confirmation, so the claim's proceed prompt does not ask a second time.
# have_tty: true only when a controlling terminal can be opened. `[[ -r /dev/tty ]]` tests the node's permission bits
# (crw-rw-rw-), not openability, so it reads true even with no controlling terminal (e.g. a systemd unit
# or under setsid); opening /dev/tty is the only honest probe -- with no controlling tty the open fails ENXIO,
# so the prompt guards skip cleanly instead of writing to /dev/tty and aborting. Mirrors launch-wrapper.lib.sh's
# ai_tools_launch_have_tty.
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

# resolve_dir <path>  -- canonicalize <path> (realpath -e) to stdout; die if it is absent or its canonical form holds
# a control character.
resolve_dir() {
    local p LC_ALL=C
    # realpath ends its answer with one line feed; the sentinel keeps a line feed that is part of the name, which a bare
    # command substitution would strip and so resolve `project<LF>` to its sibling `project`.
    p="$(realpath -e -- "$1" 2>/dev/null && printf x)" || die "path not found: $(ai_tools_log_sanitize "$1")"
    p="${p%x}"
    p="${p%$'\n'}"
    # A project root is registered one per line in allowed-projects and printed on the claim's page, so a control byte
    # in it, a line feed first among them, is refused before any verb acts on the path.
    if [[ "${p}" =~ [[:cntrl:]] ]]; then
        die MSG-V8Z5 "project path holds a control character: $(ai_tools_log_sanitize "${p}") -- rename it first"
    fi
    printf '%s' "${p}"
}

# require_sandbox_clone <path>  -- die unless <path> is a real sandbox CLONE: it passes the protected-paths backstop, is
# a DIRECT child of SANDBOX_ROOT (exactly one component under it -- never SANDBOX_ROOT itself, never a nested or system
# path), and is a git worktree. This scopes the clone kind of `projects remove` (`rm -rf`) and `projects push`
# to an actual clone, so neither the shared clone area root nor an unrelated path can ever be the target.
require_sandbox_clone() {
    local d="$1" rel
    ai_tools_assert_safe_target "${d}" "sandbox" || exit 3
    [[ "${d}" == "${SANDBOX_ROOT}/"* ]] \
        || die MSG-T4Z6 "not a sandbox clone (must be a clone under ${SANDBOX_ROOT}): ${d}"
    rel="${d#"${SANDBOX_ROOT}/"}"
    [[ -n "${rel}" && "${rel}" != */* ]] \
        || die MSG-W3H3 "not a sandbox clone (expected ${SANDBOX_ROOT}/<clone>, one level deep): ${d}"
    git -C "${d}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "not a git clone: ${d} -- if it is a stray directory, remove it by hand"
}

# run_as_owner <cmd> [args...]  -- run <cmd> as the operator this run acts FOR: directly without --for,
# and under `sudo -u <target> -H` with it. The seam every step that touches the filesystem AS AN OWNER goes
# through; the general sudo grant `sudo -u` rides, and why that adds the caller no authority, are cli.rule.md's.
#
# `-H` is load-bearing: without it (and without sudoers' always_set_home) sudo leaves HOME pointing at the INVOKER's
# home, so a command that reads a dotfile -- git most of all -- would configure the target's tree from the invoker's.
run_as_owner() {
    if [[ -z "${FOR_OPERATOR}" ]]; then "$@"; return; fi
    sudo -u "${OWNER_USER}" -H -- "$@"
}

# ── Registry helpers (the only mutating filesystem writes besides clones) ─────────
# allowed-projects: one absolute path per line; '!'-prefixed lines are exclusions. safe.directory: git refuses
# to operate in a dir it does not own, and the clone is owned by the projects user, so the sandbox account (which runs
# git as the agent) needs an explicit entry per registered path.

# Every edit here goes through conf.lib.sh's allowlist-editing functions -- the one implementation of a registry change,
# shared with the ai-tools-allowlist root helper (a --for run) and install.sh (de-registering its own checkout).
# What stays here is the CLI's half: which principal performs the write, and what the operator is told about it.

# allow_state <dir>  -- `listed` / `disabled` / `absent` for the registry THIS run reads (the invoker's, or a --for
# target's snapshot). See ai_tools_conf_allowlist_state for what each means and why an exclusion outranks an allow
# entry.
allow_state() { ai_tools_conf_allowlist_state "${ALLOWLIST}" "$1"; }

# disabled_note <dir>  -- print the raw '!' line(s) parking <dir>, indented, for a message that has just called it
# disabled. What the operator needs next is the line itself, verbatim.
disabled_note() {
    local -a lines=(); local raw
    ai_tools_conf_allowlist_exclusion_lines lines "${ALLOWLIST}" "$1" || return 0
    for raw in "${lines[@]}"; do say "      ${C_BOLD}${raw}${C_RST}"; done
}

# retag_allow <dir> <enable|disable>  -- park or restore <dir> in place, through the root helper on a --for run
# and directly otherwise. Both directions report their own failure with the command that repeats it; the library
# verifies the resulting state, so a "done" here means the file says so. Returns non-zero if the state did not change
# as asked.
retag_allow() {
    local dir="$1" op="$2" rc=0 done_word="disabled"
    [[ "${op}" == enable ]] && done_word="re-enabled in place"
    if [[ -n "${FOR_OPERATOR}" ]]; then
        if sudo "${ALLOWLIST_BIN}" --operator "${FOR_OPERATOR}" "--${op}" "${dir}" >/dev/null; then
            snapshot_allowlist
            say "    allowed-projects: ${done_word} for ${FOR_OPERATOR}"
            return 0
        fi
        warn "could not ${op} ${dir} in ${FOR_OPERATOR}'s allowed-projects -- run:"
        say  "      ${C_BOLD}sudo ${ALLOWLIST_BIN} --operator ${FOR_OPERATOR} --${op} ${dir}${C_RST}"
        return 1
    fi
    "ai_tools_conf_allowlist_${op}" "${ALLOWLIST}" "${dir}" || rc=$?
    if (( rc )); then
        warn "could not ${op} ${dir} in allowed-projects -- the file was not changed. Edit the line by hand:"
        [[ "${op}" == enable ]] && disabled_note "${dir}"
        return 1
    fi
    say "    allowed-projects: ${done_word}"
}

# offer_reenable <dir> <what>  -- the shared disabled-project gate: report that <dir> is parked, show the line, ask
# (default NO) whether to un-park it, and return 0 only once it is listed again. Every verb that needs the project
# REACHABLE goes through it, because the root helpers resolve a path's owner through the same allow/exclude matcher
# the launch gate uses: while the '!' stands, ai-tools-unclaim, -chown, -setfacl and -setgid resolve no owner and exit 0
# having done NOTHING, and ai-tools-lockdown refuses outright. Proceeding over that would report steps as applied
# that never ran -- the one thing these flows may not do. <what> is named in the message; a THIRD argument makes
# a declined confirm return non-zero instead of aborting the command, for the one caller whose remaining work is still
# worth doing.
offer_reenable() {
    local dir="$1" what="$2" decline_returns="${3:-}"
    refuse_carveout "${dir}" "${what}"
    headline_warn "This project is disabled" \
        "An exclusion line in allowed-projects parks ${dir}. While it stands the agent cannot launch there, and the root helpers resolve no owner for it -- so ${what} would report steps it did not apply. Re-enabling changes nothing else: the project keeps its permissions, its ACLs and its label."
    disabled_note "${dir}"
    say ""
    if ! confirm "Re-enable this project (delete the '!' from that line)?" n; then
        [[ -n "${decline_returns}" ]] || die "aborted -- ${dir} stays disabled and nothing was changed"
        return 1
    fi
    retag_allow "${dir}" enable
}

reg_allow() {
    local dir="$1" rc=0
    # A --for run edits a registry in a home this operator cannot even read, so the write goes through the root helper
    # (which re-reads the real file and applies the same library rules), and the snapshot is refreshed so the rest
    # of this run sees the entry it just added.
    if [[ -n "${FOR_OPERATOR}" ]]; then
        if sudo "${ALLOWLIST_BIN}" --operator "${FOR_OPERATOR}" --add "${dir}" >/dev/null; then
            snapshot_allowlist
            say "    allowed-projects: added for ${FOR_OPERATOR}"
            return 0
        fi
        # rc 2 from the helper is the disabled refusal, reported the same way; anything else is a write that did not
        # happen.
        if [[ "$(allow_state "${dir}")" == disabled ]]; then
            offer_reenable "${dir}" "the claim" \
                || die "allowed-projects not updated -- ${dir} is still disabled"
            return 0
        fi
        die "could not add ${dir} to ${FOR_OPERATOR}'s allowed-projects"
    fi
    [[ -f "${ALLOWLIST}" ]] || die "no allowlist at ${ALLOWLIST} -- nothing changed.
       If this account is meant to run sandboxed sessions, enrol it first with:
       sudo ai-tools-admin operators add ${USER:-$(id -un)}"
    local before; before="$(allow_state "${dir}")"
    ai_tools_conf_allowlist_add "${ALLOWLIST}" "${dir}" || rc=$?
    case "${rc}" in
        0) if [[ "${before}" == listed ]]; then
               say "    allowed-projects: already listed"
           else
               say "    allowed-projects: added"
           fi ;;
        2) # DISABLED. cmd_project_claim answers this up front, so reaching it here means another
           # caller (or a file changed under a running flow) -- the backstop that keeps the rule in the library rather
           # than in one caller: a second, positive line would leave the '!' winning at the launch gate while the claim
           # reported success.
           offer_reenable "${dir}" "the claim" \
               || die "allowed-projects not updated -- ${dir} is still disabled" ;;
        *) die "could not add ${dir} to allowed-projects -- it is not registered" ;;
    esac
}

# allow_escape <text>  -- escape <text> so it matches literally inside a sed `\|^...$|` address: the '|' delimiter,
# backslash, and the BRE metacharacters (`.[]*^$`). Shared by unreg_allow, which runs the anchored-exact line deletion,
# and cmd_project_list, which prints the same deletion as a copy-paste remediation command. Both delete a whole RAW
# allowlist line, which may carry a comment or a dot in a path, so an under-escaped pattern would match a sibling line
# or none.
allow_escape() { printf '%s' "$1" | sed 's/[]\.*^$|[]/\\&/g'; }

unreg_allow() {
    local dir="$1"
    # A --for run de-lists through the root helper, which applies the same raw-line matcher to the real file;
    # the snapshot is refreshed so a later read in this run agrees with it.
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
    # The library deletes every RAW line naming ${dir} -- allow AND exclusion -- matched through the shared grammar
    # rather than rebuilt from the path, so an entry carrying a comment or quotes is not missed (the blind spot
    # that used to leave the entry, and the agent's access, behind on unclaim), and a project the operator had parked
    # leaves no '!' behind to disable whatever is claimed at that path next.
    local -a lines=() excl=(); local raw before
    before="$(allow_state "${dir}")"
    ai_tools_conf_allowlist_matching_lines  lines "${ALLOWLIST}" "${dir}" || true
    ai_tools_conf_allowlist_exclusion_lines excl  "${ALLOWLIST}" "${dir}" || true
    lines+=("${excl[@]}")
    # The library verifies the removal by re-reading the file: this entry is the launch gate, and cmd_project_remove
    # deletes the tree in its next step. Reported and fatal, since `sed -i` writes its temporary file
    # into the allowlist's own DIRECTORY and so fails on a config dir this operator cannot write even when the allowlist
    # itself is writable.
    if ! ai_tools_conf_allowlist_remove "${ALLOWLIST}" "${dir}"; then
        warn "could not remove ${dir} from allowed-projects -- a line naming it survived. While an allow line stands the agent can still launch there, and a '!' line left behind parks the path against a future claim. Remove it by hand:"
        for raw in "${lines[@]}"; do
            printf "      %ssed -i '\\\\|^%s\$|d' %s%s\n" \
                "${C_BOLD}" "$(allow_escape "${raw}")" "${ALLOWLIST}" "${C_RST}"
        done
        die MSG-K8S2 "allowed-projects not updated -- ${dir} is still registered"
    fi
    if [[ "${before}" == absent ]]; then
        say "    allowed-projects: not listed"
    else
        say "    allowed-projects: removed"
    fi
}

# reg_safedir <dir>  -- register <dir> in the agent's git safe.directory list: read unprivileged for idempotency, then
# write via the SAFEDIR_BIN root helper (see its declaration for the sudo/644 rationale). The entry lets the agent's git
# trust this tree, so the step is best-effort: when sudo is absent or the helper does not complete, it prints the manual
# command as a hint and lets the claim carry on.
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
        return 1
    fi
}

# unreg_safedir <dir>  -- the unclaim counterpart to reg_safedir: drop <dir> via SAFEDIR_BIN --remove. Called
# after unreg_allow, so the helper's --remove is lenient about allowlist membership. Best-effort like reg_safedir: warns
# with the manual command and lets the unclaim carry on.
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
        return 1
    fi
}

# reg_filemode <dir>  -- pin core.filemode=true in the project's own .git/config, so git tracks the executable bit
# the same way for BOTH co-writers whatever either user's global git config: repo-LOCAL, since /opt/ai-tools/.gitconfig
# is the agent's global alone. Every git call runs through run_as_owner, since under `--for` the .git/config it writes
# belongs to the target operator. Idempotent and quiet when already set; a no-op (with a note) outside a git work tree.
reg_filemode() {
    local dir="$1"
    if ! run_as_owner git -C "${dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        say "    git core.filemode: not a git work tree -- skipped"
        return 0
    fi
    if [[ "$(run_as_owner git -C "${dir}" config --local --get core.filemode 2>/dev/null)" == "true" ]]; then
        say "    git core.filemode: already true"
    else
        if run_as_owner git -C "${dir}" config --local core.filemode true; then
            say "    git core.filemode: set true"
        else
            warn "git core.filemode: could not set (continuing)"
        fi
    fi
}

# acl_gap <dir>  -- true (0) when the project's group-permission ACL is NOT yet in place: <dir>'s root carries no
# `default:group:SANDBOX_GROUP:` entry. Read-only and unprivileged. Returns false (1) when the ACL is present, and ALSO
# when ACLs cannot be inspected at all (getfacl missing) -- there is then no gap we can act on, so claim does not
# perpetually re-prompt for a step that cannot run. Mirrors the dir_owngap / project_state "na when unavailable"
# convention.
acl_gap() {
    local dir="$1"
    command -v getfacl >/dev/null 2>&1 || return 1
    getfacl -p "${dir}" 2>/dev/null \
        | grep -qE "^default:group:${SANDBOX_GROUP}:" && return 1
    return 0
}

# git_gap <dir>  -- true (0) when <dir> has a .git tree NOT yet normalized for agent git-history access: its .git root
# lacks group SANDBOX_GROUP, the setgid bit, or the default group ACL. Read-only and unprivileged. Returns false (1)
# when there is no .git tree (none, or a submodule/worktree .git FILE), when .git is already normalized, and when ACLs
# cannot be inspected (getfacl missing) -- there is then no gap we can act on, so claim does not perpetually re-offer
# a step that cannot run. Mirrors the acl_gap / dir_owngap "na when unavailable" convention. Unlike the other gaps,
# normalizing .git is opt-in (the operator is asked, default yes), so this only DETECTS the gap; cmd_project_claim
# decides.
git_gap() {
    local dir="$1" grp mode
    [[ -d "${dir}/.git" ]] || return 1
    command -v getfacl >/dev/null 2>&1 || return 1
    # IFS pinned (see join_words).
    IFS=' ' read -r grp mode < <(stat -c '%G %a' "${dir}/.git" 2>/dev/null) || return 1
    [[ "${grp}" == "${SANDBOX_GROUP}" ]] \
        && (( (0${mode} & 02000) != 0 )) \
        && getfacl -p "${dir}/.git" 2>/dev/null | grep -qE "^default:group:${SANDBOX_GROUP}:" \
        && return 1
    return 0
}

# dir_owngap <dir>  -- true (0) when <dir> is NOT group-accessible to the sandbox account: group is not SANDBOX_GROUP,
# or the group-execute bit is clear. The sandbox user runs with the project as its cwd, and Node's posix_spawn needs
# group-execute there to launch ANY child (hooks, the Bash tool). This is the exact gap the launch wrapper refuses
# to start on, factored here so both agree.
dir_owngap() {
    local dir="$1" grp mode
    grp="$(stat -c '%G' "${dir}" 2>/dev/null)" || return 0
    mode="$(stat -c '%a' "${dir}" 2>/dev/null)" || return 0
    [[ "${grp}" == "${SANDBOX_GROUP}" ]] && (( (0${mode} & 010) != 0 )) && return 1
    return 0
}

# drift_walk_read <capture-file> <paths-array>  -- read a walk's NUL-separated capture into <paths-array> in byte order
# (`sort -z` in the C locale, in place): `find` returns a directory's entries in the order the filesystem stores them,
# so without the sort the page and the record stream would list drift in an order that differs between filesystems
# and between two walks of one tree. Returns 1, with the array empty, when the capture is missing, not a regular file,
# cannot be sorted or cannot be read: a walk whose output was not read is not an empty tree.
drift_walk_read() {
    local -n _walk_paths="$2"
    _walk_paths=()
    [[ -f "$1" && ! -L "$1" && -r "$1" ]] || return 1
    LC_ALL=C sort -z -o "$1" -- "$1" 2>/dev/null || return 1
    mapfile -d '' -t _walk_paths 2>/dev/null < "$1" || { _walk_paths=(); return 1; }
}

# drift_walk_failure <status> <stderr-capture>  -- print why a walk did not complete: its exit status and the first line
# of its stderr, sanitized for display.
drift_walk_failure() {
    local first=""
    IFS= read -r first 2>/dev/null < "$2" || true
    printf 'exited %s%s' "$1" "${first:+: $(ai_tools_log_sanitize "${first}")}"
}

# acl_drift_scan <dir> <work-dir> <paths-array> <detail-var>  -- fill <paths-array> with the paths inside a claimed tree
# that look shared but carry the wrong group: owned by the operator or the sandbox account, group not SANDBOX_GROUP,
# yet with group/other permission bits set. Creation under a claimed tree inherits the group (setgid) and the ACLs
# (default entries); a path lacking both arrived by rename(2) -- mv from outside the tree preserves the old group
# and inherits neither setgid nor the ACL -- and the agent gets EACCES on it deep inside an allowlisted project.
# The walk is the repair's (ai-tools-setfacl): `-xdev`, `.git` pruned, and this project's '!'-excluded subtrees pruned,
# since an intentional carve-out stays unreported; owner-only paths (600/700: locked-down secrets, deliberately private
# files) are left out by the `-perm /077` predicate. The paths come NUL-separated, so a name holding a tab or a line
# feed arrives whole. Returns 1, with <detail-var> naming why, when the walk exits non-zero or writes to stderr, or its
# capture cannot be read: a failed walk is not a complete scan of a smaller tree. Read-only and unprivileged, detection
# only.
acl_drift_scan() {
    local dir="$1" work="$2" excl status=0
    local -n _acl_scan_paths="$3" _acl_scan_detail="$4"
    local -a skip=( -name .git -prune )
    _acl_scan_paths=() _acl_scan_detail=""
    while IFS= read -r excl; do
        [[ "${excl}" == "${dir}"/* ]] && skip+=( -o -path "${excl}" -prune )
    done < <(allowlist_exclusions)
    { LC_ALL=C find "${dir}" -xdev \( "${skip[@]}" \) -o \
        \( -user "${OWNER_USER}" -o -user "${SANDBOX_USER}" \) \
        ! -group "${SANDBOX_GROUP}" -perm /077 -print0 \
        > "${work}/acl.walk" 2> "${work}/acl.walk.err"; } 2>/dev/null || status=$?
    if (( status != 0 )) || [[ ! -f "${work}/acl.walk.err" || -s "${work}/acl.walk.err" ]]; then
        _acl_scan_detail="the group walk $(drift_walk_failure "${status}" "${work}/acl.walk.err")"
        drift_walk_read "${work}/acl.walk" _acl_scan_paths || true
        return 1
    fi
    if ! drift_walk_read "${work}/acl.walk" _acl_scan_paths; then
        _acl_scan_detail="the group walk's output could not be read"
        return 1
    fi
    return 0
}

# label_drift_scan <dir> <work-dir> <paths-array> <types-map> <detail-var>  -- fill <paths-array> with the paths inside
# a claimed tree whose SELinux type differs from the one the claim's relabel would apply, and <types-map>
# with `<type it carries> -> <type the policy gives it>` under each. The expected type is asked of the policy: a dry run
# of the relabel the claim performs (`restorecon -n -F`, unprivileged, reading the world-readable file contexts).
# The walk is the relabel's scope (`restorecon -FR`, ai_tools_label_project): every directory, `.git` and skip-listed
# names included, crossing mount points. Every walked name without a line feed goes into one non-recursive batch
# with `-i`, since a path removed after the walk is outside the run's scope; a name holding one goes
# through ai_tools_project_permissions_label_check on its own, so no record can be a fragment of another
# (project-permissions.lib.sh). Only a TYPE difference counts: `-F` also reports the SELinux user and the MLS range,
# and on the file classes the targeted policy constrains the user for create, relabelfrom and relabelto alone,
# and ai_tools_t does not carry mcs_constrained_type, so a user or category difference on its own does not deny
# the agent (`seinfo --constrain` and `seinfo -a mcs_constrained_type -x` read both on a host). Owner-only paths
# and '!'-excluded subtrees are filtered out afterwards, as the group scan leaves them out. Returns 1, with <detail-var>
# naming why, when restorecon is absent, the walk or the batch output is not complete, a per-path check reads unknown,
# or a drifted path's mode cannot be read and the path is not confirmed gone; the drift it did read stays in the arrays.
label_drift_scan() {
    local dir="$1" work="$2" status=0 path outcome from to excl skip mode incomplete=0 index
    local -n _label_scan_paths="$3" _label_scan_types="$4" _label_scan_detail="$5"
    local -a walked=() batched=() exclusions=() unread=() unread_absence=()
    local -A batch_listed=() batch_drift=()
    _label_scan_paths=() _label_scan_types=() _label_scan_detail=""
    # The scan runs only over a labelled root, so SELinux is in use: a missing restorecon is a reading this run could
    # not make, not a tree without drift.
    if ! command -v restorecon >/dev/null 2>&1; then
        _label_scan_detail="restorecon is not installed, so the tree's types could not be read"
        return 1
    fi
    { LC_ALL=C find "${dir}" -print0 > "${work}/label.walk" 2> "${work}/label.walk.err"; } 2>/dev/null || status=$?
    if (( status != 0 )) || [[ ! -f "${work}/label.walk.err" || -s "${work}/label.walk.err" ]]; then
        _label_scan_detail="the label walk $(drift_walk_failure "${status}" "${work}/label.walk.err")"
        incomplete=1
    fi
    if ! drift_walk_read "${work}/label.walk" walked; then
        [[ -n "${_label_scan_detail}" ]] || _label_scan_detail="the label walk's output could not be read"
        return 1
    fi
    for path in "${walked[@]}"; do
        [[ "${path}" == *$'\n'* ]] && continue
        batched+=("${path}")
        batch_listed["${path}"]=1
    done
    if (( ${#batched[@]} )); then
        if ! claim_write_list "${work}/label.list" "${batched[@]}"; then
            [[ -n "${_label_scan_detail}" ]] || _label_scan_detail="the path list for the relabel dry run could not be written"
            incomplete=1
        elif ! ai_tools_project_permissions_label_batch "${work}/label.list" "${work}" batch_listed batch_drift -i; then
            [[ -n "${_label_scan_detail}" ]] || _label_scan_detail="the relabel dry run's output was not complete"
            incomplete=1
        fi
    fi
    for path in "${walked[@]}"; do
        [[ "${path}" == *$'\n'* ]] || continue
        ai_tools_project_permissions_label_check "${path}" "${work}" outcome from to
        case "${outcome}" in
            drift) batch_drift["${path}"]="${from}"$'\t'"${to}" ;;
            unknown)
                [[ -n "${_label_scan_detail}" ]] \
                    || _label_scan_detail="a name holding a line feed could not be checked: $(ai_tools_log_sanitize "${path}")"
                incomplete=1 ;;
        esac
    done
    mapfile -t exclusions < <(allowlist_exclusions)
    for path in "${walked[@]}"; do
        [[ -n "${batch_drift[${path}]+set}" ]] || continue
        skip=false
        for excl in "${exclusions[@]}"; do
            # The exclusion is the pattern (a '!' line may be a glob); the path is matched literally.
            [[ "${path}" == ${excl} || "${path}" == ${excl}/* ]] && { skip=true; break; }
        done
        ${skip} && continue
        # A drifted path whose mode stat fails to read goes to the absence check that follows the loop, and is not
        # dropped.
        if ! mode="$(stat -c '%a' -- "${path}" 2>/dev/null)"; then
            unread+=("${path}")
            continue
        fi
        (( (8#${mode} & 077) == 0 )) && continue
        _label_scan_paths+=("${path}")
        _label_scan_types["${path}"]="${batch_drift[${path}]%%$'\t'*} -> ${batch_drift[${path}]#*$'\t'}"
    done
    # A drifted path removed after the batch is outside the run's scope; one whose mode could not be read for any other
    # reason leaves the scan incomplete, so it is not silently dropped.
    if (( ${#unread[@]} )); then
        if ! claim_write_list "${work}/label.unread" "${unread[@]}" \
                || ! ai_tools_project_permissions_lstat_outcomes "${work}/label.unread" "${work}" unread_absence; then
            unread_absence=()
        fi
        for index in "${!unread[@]}"; do
            [[ "${unread_absence[index]:-unknown}" == gone ]] && continue
            [[ -n "${_label_scan_detail}" ]] \
                || _label_scan_detail="the mode of a drifted path could not be read: $(ai_tools_log_sanitize "${unread[index]}")"
            incomplete=1
        done
    fi
    return "${incomplete}"
}

# sealed_setgid_scan <dir>  -- list owner-only directories inside a claimed tree whose setgid bit carries a THIRD-party
# group: neither SANDBOX_GROUP nor the group of the directory's own owner, the one piece of residue the claim walks keep
# rather than strip (owner-only.lib.sh). Read-only and unprivileged, detection only: a path reported here is one
# the claim did not touch. "Third party" is decided per path, against the OWNER's primary group and not the invoking
# user's: on a multi-operator host the group the claim walks treat as legitimate is the resolved project owner's, since
# they act only on paths that owner or the sandbox account holds, so reporting against the invoker's would flag a bit
# the claim goes on to strip, or stay silent about one it keeps.
sealed_setgid_scan() {
    local dir="$1" excl
    local -a skip=( -name .git -prune )
    while IFS= read -r excl; do
        [[ "${excl}" == "${dir}"/* ]] && skip+=( -o -path "${excl}" -prune )
    done < <(allowlist_exclusions)
    # find cannot compare a path's group to its own owner's, so it narrows to the candidates (owner-only, setgid, not
    # the sandbox group) and the owner comparison is made per path here. An owner with no passwd entry resolves to no
    # group and is therefore reported, which is the right way round: a setgid whose group cannot be tied to the owner is
    # one to look at.
    find "${dir}" -xdev \( "${skip[@]}" \) -o \
        -type d ! -perm /077 -perm -2000 ! -group "${SANDBOX_GROUP}" \
        -printf '%U\t%G\t%p\n' 2>/dev/null \
    | while IFS=$'\t' read -r _uid _grp _path; do
          [[ "${_grp}" == "$(id -gn "${_uid}" 2>/dev/null || true)" ]] && continue
          printf '%s\n' "${_path}"
      done
}

# reg_ownership <dir> [force]  -- make <dir> usable by the sandbox account: group SANDBOX_GROUP + the setgid bit
# on the project's directories, via the root ai-tools-setgid helper, so the agent can enter the tree and files born
# there inherit the group. Without it a path can be allowlisted yet fail every posix_spawn -- the session starts
# but cannot enter the tree or run a child. The operator is not a SANDBOX_GROUP member (multi-operator), so the chgrp
# needs root; the helper carries its own allowlist + owner guard. Pre-existing FILES become agent-accessible
# through the ACL claim_setfacl applies next (ai-tools-setfacl's header states which paths it regroups).
#
# CALLER MUST run secret_gate "${dir}" first: the steps this one leads open existing files to the agent's group,
# and the gate locks secrets to 600/700 ahead of them.
reg_ownership() {
    local dir="$1" force="${2:-}"
    if [[ "${force}" != force ]] && ! dir_owngap "${dir}"; then
        say "    ownership: already group ${SANDBOX_GROUP}, setgid"
        return 0
    fi
    if sudo "${SETGID_BIN}" "${dir}"; then
        say "    ownership: set group ${SANDBOX_GROUP} + setgid on the project directories"
    else
        warn "ownership: could not set group/setgid on ${dir} -- run it by hand:"
        say  "      ${C_BOLD}sudo ${SETGID_BIN} ${dir}${C_RST}"
        return 1
    fi
}

# agent_can_traverse <dir>  -- 0 if the sandbox account (SANDBOX_USER, a SANDBOX_GROUP member) can ENTER <dir>, decided
# the way the kernel decides it (acl(5)): the owner entry when the account owns the directory; else the named-user entry
# for the account when there is one, whatever the group and other entries say; else the owning-group entry
# when the directory is in SANDBOX_GROUP, and every named-group entry for SANDBOX_GROUP; else the other entry.
# A named entry and the owning-group entry are narrowed by the mask, so `user:SANDBOX_USER:--x` under `mask::---`
# -- the state a `chmod 700` after an earlier grant leaves -- reads as blocked, and the grant is offered again. Returns
# 1 when the account cannot enter, and 2 when the answer cannot be read: the stat fails, or getfacl is installed
# and fails on the directory. A mode read in place of an ACL that could not be read would say "traversable" over a named
# entry denying it, so the caller reads 2 as blocked by a directory no grant may cover. Without getfacl on the host
# the mode bits alone decide, since no ACL can be inspected there at all.
agent_can_traverse() {
    local dir="$1" mode owner grp acl
    # IFS pinned (see join_words).
    IFS=' ' read -r mode owner grp < <(stat -c '%a %U %G' -- "${dir}" 2>/dev/null) || return 2
    if command -v getfacl >/dev/null 2>&1; then
        acl="$(getfacl -p -c -E -- "${dir}" 2>/dev/null)" || return 2
        local line tag name perms mask="" named_user="" owner_perms="" other="" found_group=false
        local -a group_perms=()
        while IFS= read -r line; do
            IFS=: read -r tag name perms <<< "${line}"
            case "${tag}:${name}" in
                "user:")                   owner_perms="${perms}" ;;
                "user:${SANDBOX_USER}")    named_user="${perms}" ;;
                "group:")                  [[ "${grp}" == "${SANDBOX_GROUP}" ]] && group_perms+=("${perms}") ;;
                "group:${SANDBOX_GROUP}")  group_perms+=("${perms}") ;;
                "mask:")                   mask="${perms}" ;;
                "other:")                  other="${perms}" ;;
            esac
        done <<< "${acl}"
        _masked_x() { [[ "$1" == *x* ]] && [[ -z "${mask}" || "${mask}" == *x* ]]; }
        if [[ "${owner}" == "${SANDBOX_USER}" ]]; then [[ "${owner_perms}" == *x* ]]; return; fi
        if [[ -n "${named_user}" ]]; then _masked_x "${named_user}"; return; fi
        for perms in "${group_perms[@]}"; do
            found_group=true
            _masked_x "${perms}" && return 0
        done
        ${found_group} && return 1
        [[ "${other}" == *x* ]]; return
    fi
    if [[ "${owner}" == "${SANDBOX_USER}" ]]; then (( 8#${mode} & 0100 )); return; fi
    if [[ "${grp}" == "${SANDBOX_GROUP}" ]]; then (( 8#${mode} & 0010 )); return; fi
    (( 8#${mode} & 0001 ))
}

# grantable_ancestor <dir>  -- 0 if confirm_ancestor_traversal may offer traverse on <dir>: the call site
# of ai_tools_traverse_grant_allowed (safe-paths.lib.sh), asked for the owner this run acts FOR. Returns 1
# when the predicate is not loaded, so a broken install never widens a directory it cannot vet.
grantable_ancestor() {
    local p="$1"
    declare -F ai_tools_traverse_grant_allowed >/dev/null 2>&1 || return 1
    ai_tools_traverse_grant_allowed "${p}" "${OWNER_USER}"
}

# find_blocking_ancestors <dir>  -- detect the traverse gap between the sandbox account and <dir>: fills
# TRAVERSAL_GRANT_PATHS (each blocking ancestor a grant may cover: operator-owned, not a protected system directory)
# and TRAVERSAL_BLOCKED_PATH (the first blocking ancestor no grant may cover, empty when none),
# with TRAVERSAL_BLOCKED_REASON naming why where the reason is the read rather than the directory. Read-only
# and unprivileged. An ancestor whose ACL could not be read (agent_can_traverse returns 2) is the blocker, whoever owns
# it: no grant is offered on a state the walk did not read. The walk reads every ancestor up to `/`, since the kernel
# resolves each component on its own and a `700` parent of a `755` directory blocks the path as surely as the reverse;
# it ends early only at a blocker no grant covers, since a grant on a directory inside that blocker could not open
# the path.
find_blocking_ancestors() {
    local dir="$1" anc traverse=0
    TRAVERSAL_GRANT_PATHS=(); TRAVERSAL_BLOCKED_PATH=""; TRAVERSAL_BLOCKED_REASON=""
    anc="$(dirname "${dir}")"
    while [[ "${anc}" != / && "${anc}" != . ]]; do
        traverse=0; agent_can_traverse "${anc}" || traverse=$?
        if (( traverse == 2 )); then
            TRAVERSAL_BLOCKED_PATH="${anc}"; TRAVERSAL_BLOCKED_REASON="its permissions could not be read"; break
        elif (( traverse != 0 )); then
            if grantable_ancestor "${anc}"; then
                TRAVERSAL_GRANT_PATHS+=("${anc}")
            else
                TRAVERSAL_BLOCKED_PATH="${anc}"; break
            fi
        fi
        anc="$(dirname "${anc}")"
    done
}

# confirm_ancestor_traversal <dir>  -- the reachability block's question, asked on find_blocking_ancestors's result (the
# CALLER runs it first): a default-NO confirm for a traverse-only `u:SANDBOX_USER:--x` entry on each blocking ancestor,
# listing under each path every entry the grant widens beside the account's own (traverse_grant_plan). Sets
# TRAVERSAL_GRANT_CONFIRMED and does not set the ACL: an accepted grant is an access-widening step, so the caller runs
# the secret gate on it and applies it with grant_ancestor_traversal in the Apply block, after the gate. A blocker no
# grant covers gets the warning naming the clone as the way in. The reachability story is cli.rule.md's.
confirm_ancestor_traversal() {
    local dir="$1" a
    TRAVERSAL_GRANT_CONFIRMED=false
    if [[ -n "${TRAVERSAL_BLOCKED_PATH}" ]]; then
        local why blocked_owner
        blocked_owner="$(stat -c '%U' "${TRAVERSAL_BLOCKED_PATH}" 2>/dev/null || echo '?')"
        if [[ -n "${TRAVERSAL_BLOCKED_REASON}" ]]; then
            why="${TRAVERSAL_BLOCKED_REASON}, so no grant is offered on it"
        elif ! declare -F ai_tools_traverse_grant_allowed >/dev/null 2>&1; then
            why="the safe-paths traverse rule is not loaded, so ancestors cannot be vetted"
        elif [[ "${blocked_owner}" != "${OWNER_USER}" ]]; then
            why="owned by ${blocked_owner}, not by ${OWNER_USER}"
        else
            why="a protected system directory"
        fi
        headline_warn "WARNING: project unreachable for the sandbox account" \
            "the sandbox account cannot traverse ${TRAVERSAL_BLOCKED_PATH} (${why}), so it cannot reach ${dir}; an isolated clone under the sandbox area is the way in:"
        say "      ${C_BOLD}ai-tools projects clone ${dir}${C_RST}"
        return 0
    fi
    if (( ${#TRAVERSAL_GRANT_PATHS[@]} == 0 )); then return 0; fi

    headline_warn "WARNING: parent directories block the agent" \
        "the sandbox account must be able to traverse every parent directory to reach the project; the grant below is traverse-only (enter, never list or read): u:${SANDBOX_USER}:--x"
    local -a grant_argv=() grant_widened=() entry
    for a in "${TRAVERSAL_GRANT_PATHS[@]}"; do
        say "      ${a}"
        traverse_grant_plan "${a}" grant_argv grant_widened || continue
        (( ${#grant_widened[@]} )) || continue
        say "        the mask on it rises to carry execute, so these entries gain traverse with the account:"
        for entry in "${grant_widened[@]}"; do say "          ${entry}"; done
    done

    # The owner's own HOME ROOT is the one entry in that list whose consequence is stated, as a condition the named
    # command answers on this host; the condition itself is safe-paths.rule.md's.
    local owner_home includes_home=false
    owner_home="$(getent passwd "${OWNER_USER}" 2>/dev/null | cut -d: -f6)"
    if [[ -n "${owner_home}" ]]; then
        for a in "${TRAVERSAL_GRANT_PATHS[@]}"; do
            [[ "${a}" == "${owner_home%/}" ]] && { includes_home=true; break; }
        done
    fi
    if ${includes_home}; then
        say ""
        say "  ${owner_home} is ${OWNER_USER}'s home directory. Traversal does not list it and"
        say "  does not open the files in it -- each file's own mode and ACL still decides."
        say "  What it makes reachable is whatever there is already world-readable; this lists it:"
        say ""
        say "      ${C_BOLD}find ${owner_home} -maxdepth 1 -perm -o+r${C_RST}"
        say ""
    fi

    # Default NO, and deliberately not pre-answerable: the grant widens access on the project's ANCESTORS, so neither
    # AI_TOOLS_ASSUME_YES (which only fast-tracks default-YES questions) nor the claim's own -y reaches it. A run
    # with no terminal therefore declines, and prints the commands so the refusal is actionable rather than merely
    # recorded.
    if confirm "Grant the sandbox account traverse-only access on them?" n; then
        TRAVERSAL_GRANT_CONFIRMED=true
    else
        say "    reach: left as-is -- the agent may be unable to enter ${dir}"
        have_tty || for a in "${TRAVERSAL_GRANT_PATHS[@]}"; do
            traverse_grant_plan "${a}" grant_argv grant_widened || grant_argv=(-n -m "u:${SANDBOX_USER}:--x")
            say "      ${C_BOLD}setfacl ${grant_argv[*]} -- ${a}${C_RST}"
        done
    fi
}

# traverse_grant_plan <dir> <argv-var> <widened-var>  -- compute the setfacl arguments that give the sandbox account
# traverse on <dir> without raising the mask past execute, and the entries that gain traverse alongside it. `setfacl -m`
# recalculates the mask to the union of every group-class entry, so a directory holding `group:devs:rwx` under
# `mask::---` would end with `mask::rwx` and that group at full access; `-n` keeps the mask as it is, which leaves
# the new entry with no effect where the mask lacks execute. So the call is `-n` with the mask set explicitly to what it
# was -- `group::` where the directory has no mask, as setfacl derives one -- plus execute. Every other masked entry
# that holds execute then gains it in effect, and <widened-var> names each as `<tag>:<name> <perms>` for the prompt.
# Returns 1 with both empty where the ACL could not be read, so no call is made on a state that was not read.
traverse_grant_plan() {
    local dir="$1"
    local -n _plan_argv="$2" _plan_widened="$3"
    local acl line tag name perms mask="" owning_group_perms="" base
    local -a masked=()
    _plan_argv=(); _plan_widened=()
    acl="$(getfacl -p -c -E -- "${dir}" 2>/dev/null)" || return 1
    while IFS= read -r line; do
        IFS=: read -r tag name perms <<< "${line}"
        case "${tag}:${name}" in
            "mask:")                mask="${perms}" ;;
            "group:")               owning_group_perms="${perms}"; masked+=("${tag}:${name} ${perms}") ;;
            "user:${SANDBOX_USER}") ;;
            user:|other:|default*)  ;;
            user:*|group:*)         masked+=("${tag}:${name} ${perms}") ;;
        esac
    done <<< "${acl}"
    base="${mask:-${owning_group_perms}}"
    [[ "${base}" =~ ^[r-][w-][x-]$ ]] || return 1
    _plan_argv=(-n -m "u:${SANDBOX_USER}:--x" -m "m::${base:0:2}x")
    [[ "${base}" == *x* ]] && return 0
    for line in "${masked[@]}"; do
        [[ "${line##* }" == *x* ]] && _plan_widened+=("${line}")
    done
    return 0
}

# grant_ancestor_traversal  -- apply the grant confirm_ancestor_traversal accepted: one traverse-only ACL entry
# per blocking ancestor, each reported on its own result line, and a manual command for one that could not be set.
# Unprivileged, since the operator owns those directories; the CALLER runs the secret gate first. The call is
# traverse_grant_plan's, so the mask rises to execute and no further. Returns non-zero when any ancestor was not
# granted, an ACL that could not be read included: one left blocking keeps the project out of reach whatever the others
# took, so the caller counts it as a step that did not apply.
grant_ancestor_traversal() {
    local a failed=false
    local -a grant_argv=() grant_widened=()
    for a in "${TRAVERSAL_GRANT_PATHS[@]}"; do
        # A --for run's ancestors belong to the TARGET, so an unprivileged setfacl by the invoker fails on every one
        # of them; run_as_owner applies it as the owner instead.
        if traverse_grant_plan "${a}" grant_argv grant_widened \
                && run_as_owner setfacl "${grant_argv[@]}" -- "${a}" 2>/dev/null; then
            say "    reach: u:${SANDBOX_USER}:--x ${a}"
        else
            failed=true
            (( ${#grant_argv[@]} )) || grant_argv=(-n -m "u:${SANDBOX_USER}:--x")
            warn "reach: could not grant on ${a} -- run it as ${OWNER_USER} or as root:"
            say  "      ${C_BOLD}setfacl ${grant_argv[*]} -- ${a}${C_RST}"
        fi
    done
    ! ${failed}
}

# normalize_clone <dir> [locked-path...]  -- make a freshly created clone agent-accessible: group rwX on every path
# and the setgid bit on every directory (the owner stays the projects user), with every <locked-path> -- the secret
# gate's finds, locked owner-only by ai-tools-lockdown -- PRUNED from both walks, since re-opening one would undo
# the lockdown this step follows. It prunes what THIS run's gate reported alone, which is why sandbox_finalize runs it
# once, while the root is still owner-only (clone_is_private). The gate's walk covers every tree this opens
# (ai-tools-lockdown's header). Both walks act on regular files and directories alone and stay on the clone's filesystem
# (`-xdev`): chmod follows a symlink named on its command line, so a tracked symlink handed to it would change a target
# outside the clone. A locked path is pruned by its literal name: `-path` reads its argument as a pattern, so `[`, `*`,
# `?` and `\` are escaped first (find_pattern_literal), or the walk would re-open the secret.
normalize_clone() {
    local d="$1"; shift
    local -a prune=() p pattern
    for p in "$@"; do
        find_pattern_literal pattern "${p}"
        prune+=( -path "${pattern}" -prune -o )
    done
    find "${d}" -xdev "${prune[@]}" '(' -type f -o -type d ')' -exec chmod g+rwX {} +
    find "${d}" -xdev "${prune[@]}" -type d -exec chmod g+s {} +
}

# find_pattern_literal <output-variable> <path>  -- set <output-variable> to <path> escaped for find's `-path`/`-name`
# pattern grammar, so it matches the path literally: a backslash escapes `\`, `*`, `?` and `[`, the characters
# fnmatch(3) reads as pattern syntax. The result is set rather than printed: a `$(...)` capture strips a trailing
# newline, so a locked name ending in one would lose it and miss its prune.
find_pattern_literal() {
    local -n _pattern_out="$1"
    local s="$2"
    s="${s//\\/\\\\}"; s="${s//\*/\\*}"; s="${s//\?/\\?}"; s="${s//\[/\\[}"
    _pattern_out="${s}"
}

# clone_is_private <dir>  -- 0 while the clone root is owner-only: the state cmd_project_clone's pinned umask leaves
# a clone in, and a declined gate leaves it in (owner-only.lib.sh states the predicate the root helpers apply). A mode
# that cannot be read counts as opened, so a resume does not widen a tree it could not read.
clone_is_private() {
    local mode
    mode="$(stat -c '%a' "$1" 2>/dev/null)" || return 1
    [[ "${mode}" =~ ^[0-7]+$ ]] || return 1
    (( ( 8#${mode} & 077 ) == 0 ))
}

# relabel_clone <dir>  -- apply the SELinux project label so the agent (ai_tools_t) can read/write the clone. A static
# fcontext rule in selinux/policy/ai_tools.fc maps every directory under sandbox-projects/ to ai_tools_project_t,
# so a plain restorecon labels it -- no per-project semanage and no root: the projects user runs as unconfined_t,
# which the policy grants relabel to ai_tools_project_t. No-op when SELinux is disabled (or the module is not loaded,
# in which case the label stays the default until the operator installs ai-tools-selinux, or from a checkout runs
# selinux/install-selinux.sh install).
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
# ai-tools-lockdown revokes ai-tools' read access to secret-named files under a project. It is root-only and reads its
# target from the working directory, so run_lockdown cds there and sudos it.

# run_lockdown <dir> [extra-args...]  -- run the helper on <dir>; returns its status.
run_lockdown() {
    local d="$1"; shift
    ( cd "${d}" && sudo "${LOCKDOWN_BIN}" "$@" )
}

# run_relabel <dir> [--remove]  -- apply (or revert) the SELinux project label on <dir> via the root helper (sudo,
# password); returns its status. The helper parses the path and the optional flag in any order.
run_relabel() {
    local d="$1"; shift
    # stdout suppressed: the helper narrates its own success ("labelled <path> ai_tools_project_t"), which lands
    # unindented in the middle of a flow block whose result lines are all indented. stderr is kept -- that is
    # where a failure explains itself.
    sudo "${RELABEL_BIN}" "$@" "${d}" >/dev/null
}

# run_reclaim <dir> [--full]  -- hand agent-written files under <dir> back to the operator via the root helper (sudo,
# password); returns its status. The helper parses the path and --full in any order.
run_reclaim() {
    local d="$1"; shift
    sudo "${RECLAIM_BIN}" "$@" "${d}"
}

# run_setfacl <dir> <with_git>  -- apply the project's group-permission ACL on <dir> via the root helper (sudo,
# password); when <with_git> is true, also pass --with-git so the helper normalizes the .git tree too. Returns its
# status.
run_setfacl() {
    local d="$1" with_git="${2:-false}"
    if ${with_git}; then
        sudo "${SETFACL_BIN}" --with-git "${d}"
    else
        sudo "${SETFACL_BIN}" "${d}"
    fi
}

# run_unclaim <dir> <target-group> [helper-flag...]  -- clear the agent ACL, regroup <dir> to <target-group>, and remove
# group write, via the root helper (sudo, password); returns its status. Trailing flags (--unlisted, --full) pass
# straight through: the helper re-derives every gate from them itself rather than trusting this caller's classification.
run_unclaim() {
    local d="$1" g="$2"; shift 2
    sudo "${UNCLAIM_BIN}" "${d}" "${g}" "$@"
}

# secret_gate <dir>  -- the secret-lockdown block: before any step grants the agent access to <dir> -- the setgid group
# change, the group ACL, a drift repair, .git normalization, the SELinux label, an accepted traverse grant, the clone
# normalize -- one `ai-tools-lockdown --gate` call (sudo; the first prompt of a claim, so it lands under this block's
# headline) scans, lists, asks and locks, so a host whose sudo does not cache the password asks once. Its walk covers
# every tree the steps after it open (ai-tools-lockdown's header). Its exit decides: 0 locked or found none, 6 declined,
# anything else failed. AI_TOOLS_ASSUME_YES is passed as `--yes`, since sudo does not pass the variable through. Fills
# SECRET_MATCH_PATHS with every path the helper wrote to stdout, for normalize_clone to prune. Returns 0 only
# when the tree is safe to expose; on non-zero the caller fails closed.
secret_gate() {
    local dir="$1" found status=0
    local -a args=(--gate)
    SECRET_MATCH_PATHS=()
    [[ "${AI_TOOLS_ASSUME_YES:-}" == 1 ]] && args+=(--yes)
    headline "Secret lockdown" "${dir}"
    found="$(mktemp)" || { warn "cannot create a temporary file for the secret scan -- not granting access"; return 1; }
    run_lockdown "${dir}" "${args[@]}" > "${found}" || status=$?
    mapfile -d '' -t SECRET_MATCH_PATHS < "${found}"
    rm -f "${found}"
    case "${status}" in
        0)
            if (( ${#SECRET_MATCH_PATHS[@]} )); then
                ok "secrets locked down"
                ai_tools_log_structured info "secret pre-check: secrets locked down under ${dir}" \
                    "AI_TOOLS_PROJECT=${dir}" "AI_TOOLS_RESULT=ok"
            else
                ok "no secret-matching paths found"
                ai_tools_log_structured info \
                    "secret pre-check: clean, no secret-matching paths under ${dir}" \
                    "AI_TOOLS_PROJECT=${dir}" "AI_TOOLS_RESULT=ok"
            fi
            return 0 ;;
        6)
            warn "declined -- access will not be granted while secrets are exposed"
            ai_tools_log_structured warning \
                "secret pre-check: lockdown declined for ${dir}, access not granted" \
                "AI_TOOLS_PROJECT=${dir}" "AI_TOOLS_RESULT=refused"
            return 1 ;;
        *)
            warn "secret lockdown did not complete -- not granting access"
            ai_tools_log_structured error "secret pre-check: lockdown failed under ${dir}, access not granted" \
                "AI_TOOLS_PROJECT=${dir}" "AI_TOOLS_RESULT=failed"
            return 1 ;;
    esac
}

# drop_lockdown_guard <dir>  -- write a placeholder CLAUDE.md telling the agent to wait until lockdown runs, used
# when a fresh sandbox clone's tip-commit secrets are still readable. An existing CLAUDE.md is preserved
# as CLAUDE.md.bak (via git mv, falling back to a plain mv) and restored by clear_lockdown_guard. The command it names
# is the clone's resume: after a declined gate the clone is unregistered, so `projects lockdown` would refuse it
# as outside every claimed project, while `projects clone` on the clone path re-enters the gate.
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
- Ask the operator to secure it first by resuming the clone, as the projects user:

      ai-tools projects clone ${d}

Only paths approved in the operator's \`allowed-projects\` allowlist are ever in
scope, and only after lockdown has revoked the agent's read access to secrets.

This file is a temporary guard. It is removed automatically once lockdown runs,
and any original CLAUDE.md is restored from CLAUDE.md.bak.
EOF
    ok "wrote a guard CLAUDE.md (agent told to wait for lockdown)"
}

# clear_lockdown_guard <dir>  -- remove a guard CLAUDE.md and restore any CLAUDE.md.bak it set aside. No-op unless
# the guard sentinel is present. Called after a successful (non-dry-run) lockdown.
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

# project_state <dir>  -- print the claim state of <dir> as seven space-separated tokens: "<listed> <safedir> <filemode>
# <owngap> <acl> <labelled> <git>". listed/safedir reflect the two registries; filemode is true when repo-local
# core.filemode is already true ("na" when <dir> is not a git work tree); owngap is true when the agent still lacks
# group access (see dir_owngap); acl is true when the group-permission ACL still needs applying (see acl_gap); labelled
# is the live SELinux type check -- true/false when SELinux is active, "na" when it is disabled (no label needed); git
# is true when a .git tree is present but not yet normalized for agent history sharing (see git_gap), false otherwise --
# it gates the opt-in .git prompt, not a mandatory claim step. Read-only, no privilege. The ai_tools_project_t string is
# the single fact mirrored from the root labelling lib; the authoritative semanage/restorecon logic is NOT duplicated
# here.
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

# claim_relabel <dir>  -- apply the SELinux project label via the root helper so the confined agent can access the tree.
# Best-effort, mirroring lockdown: warns with the manual command (never dies) when sudo is missing or the helper fails.
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
        return 1
    fi
}

# claim_setfacl <dir> <with_git>  -- apply the group-permission ACL via the root helper so files the projects user's git
# checkout/merge writes under a restrictive umask stay group- accessible; when <with_git> is true the helper also
# normalizes the .git tree (group + setgid + ACL) so the operator's commits stay agent-accessible. Best-effort,
# mirroring claim_relabel: warns with the manual command (never dies) when sudo is missing or fails.
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
        return 1
    fi
}

# path_detail_lines <path...>  -- print each path prefixed with its owner:group and mode, the columns that show
# at a glance why a path is flagged (the foreign or agent group) and whether its mode is what the operator expects.
# Shared by the claim's drift report and the unclaim's residue report: both answer the same question about a path,
# so both show the same columns. A caller listing drift sets PATH_DETAIL_MARK=1 for the call, which appends
# drift_secret_mark to each line.
path_detail_lines() {
    local _p _og _m _mark=""
    for _p in "$@"; do
        IFS=' ' read -r _og _m < <(stat -c '%U:%G %a' "${_p}" 2>/dev/null) \
            || { _og='?'; _m='?'; }
        [[ -z "${PATH_DETAIL_MARK:-}" ]] || _mark="$(drift_secret_mark "${_p}")"
        printf '        %s%-18s %-4s %s%s%s\n' "${C_DIM}" "${_og}" "${_m}" "$(ai_tools_log_sanitize "${_p}")" "${C_RST}" \
            "${_mark}"
    done
}

# drift_secret_mark <path>  -- print ` [secret]` when a component of <path> under the project root <d> (the claim's
# local, in scope wherever the claim lists its drift) matches a loaded secret pattern, the match ai-tools-lockdown makes
# before any repair runs. Prints nothing when no pattern set is loaded.
drift_secret_mark() {
    declare -F ai_tools_is_secret_basename >/dev/null 2>&1 && [[ -n "${_AI_TOOLS_PATTERNS_LOADED:-}" ]] || return 0
    local _part
    local -a _parts=()
    IFS=/ read -r -a _parts <<< "${1#"${d}"/}"
    for _part in "${_parts[@]}"; do
        if [[ -n "${_part}" ]] && ai_tools_is_secret_basename "${_part}"; then
            printf ' %s[secret]%s' "${C_YEL}" "${C_RST}"
            return 0
        fi
    done
}

# drift_secret_legend <path...>  -- under a drift list holding a secret-named path, say what the secret gate does
# with one.
drift_secret_legend() {
    local _p
    for _p in "$@"; do
        [[ -n "$(drift_secret_mark "${_p}")" ]] || continue
        say "      ${C_YEL}[secret]${C_RST} if you accept a repair, the secret gate locks it down (owner-only)"
        say "      first, so no repair shares it with the agent"
        return 0
    done
}

# item_listing <label> <printer> <item...>  -- report a set of items through <printer>, a function printing one line
# per item it is given: in FULL when there are few enough that the whole list is shorter than a sample plus the question
# about it, otherwise a three-item sample and an offer to see the rest. One decision in one place, because getting it
# wrong is invisible in the code and glaring on screen: sampling four items prints three, says "... and 1 more", asks
# a question, and then prints all four again -- seven lines and a prompt to show four items. SAMPLE is the sample size;
# the full-list cut-off is twice it, the point past which the sample is genuinely saving the reader something. The offer
# defaults to yes: it is read-only and the point of asking is that the list is long, so Enter shows it and a piped
# or delegated run prints it too (grep-able). It prints the items the sample did not, so no line is shown twice.
# A caller that asks a question about the set asks it after this returns, so the question follows the last line
# of the list rather than scrolling out of view before it.
readonly PATH_LISTING_SAMPLE=3
item_listing() {
    local _label="$1" _printer="$2"; shift 2
    if (( $# <= 2 * PATH_LISTING_SAMPLE )); then
        "${_printer}" "$@"
        return 0
    fi
    "${_printer}" "${@:1:PATH_LISTING_SAMPLE}"
    say "        ${C_DIM}... and $(( $# - PATH_LISTING_SAMPLE )) more${C_RST}"
    confirm "      List the other $(( $# - PATH_LISTING_SAMPLE )) ${_label}?" y || return 0
    "${_printer}" "${@:PATH_LISTING_SAMPLE+1}"
}

# path_listing <label> <path...>  -- item_listing over paths, each shown with its ownership and mode.
path_listing() { item_listing "$1 with ownership and mode" path_detail_lines "${@:2}"; }

# label_drift_lines <path...>  -- print each path label_drift_scan reported as the type it carries, the type the policy
# gives it, and the path. The types are read from the claim's label_drift_types map, which is in scope wherever
# the claim calls this through item_listing.
label_drift_lines() {
    local _path
    for _path in "$@"; do
        printf '        %s%s  %s%s%s\n' "${C_DIM}" "${label_drift_types[${_path}]:-?}" \
            "$(ai_tools_log_sanitize "${_path}")" "${C_RST}" "$(drift_secret_mark "${_path}")"
    done
}

# outcome_record <outcome> <kind> <path> <detail>  -- one page line recording what a run did about one path, indented
# under its heading with the outcome and kind in aligned columns, uncoloured, so a grep for an outcome finds every path
# it names; `--format tsv` carries the same outcomes for a script. The path is printed through the display sanitizer,
# since a path under a claimed tree may be one the agent named, and that keeps a newline in it from splitting the line.
outcome_record() {
    printf '    %-10s  %-5s  %s  %s\n' "$1" "$2" "$(ai_tools_log_sanitize "$3")" "${4:--}"
}

# claim_load_libraries -- load the record writer and the per-path checks the claim collects its drift and verifies its
# repairs with. Required: a claim whose checks or exit contract did not load would report a repair it could not verify,
# so it refuses before its first write.
claim_load_libraries() {
    local loaded=true function
    # shellcheck source=SCRIPTDIR/../lib/ai-tools/records-base.lib.sh
    source "${RECORDS_BASE_LIB}" 2>/dev/null || loaded=false
    # shellcheck source=SCRIPTDIR/../lib/ai-tools/records-tsv.lib.sh
    ${loaded} && { source "${RECORDS_TSV_LIB}" 2>/dev/null || loaded=false; }
    # shellcheck source=SCRIPTDIR/../lib/ai-tools/project-permissions.lib.sh
    ${loaded} && { source "${PROJECT_PERMISSIONS_LIB}" 2>/dev/null || loaded=false; }
    for function in ai_tools_records_begin_report ai_tools_records_accumulate_severity \
            ai_tools_records_get_exit_status ai_tools_records_tsv_write_record \
            ai_tools_records_tsv_frame_item_components ai_tools_project_permissions_label_batch \
            ai_tools_project_permissions_label_check ai_tools_project_permissions_lstat_outcomes \
            ai_tools_project_permissions_group_check; do
        declare -F "${function}" >/dev/null 2>&1 || loaded=false
    done
    if ! ${loaded}; then
        die MSG-X3G7 "cannot load the libraries the claim checks its drift and states its exit codes with -- reinstall the ai-tools package"
    fi
    # The invoker's own patterns file, the one ai-tools-lockdown reads for a project the invoker owns. Under `--for`
    # the target's file is unreadable from here, so no pattern set is loaded and drift_secret_mark does not mark any
    # path.
    if [[ -z "${FOR_OPERATOR}" ]]; then
        # shellcheck source=SCRIPTDIR/../lib/ai-tools/secret-patterns.lib.sh
        { source "${SECRET_PATTERNS_LIB}" && PROJECTS_HOME="${HOME_DIR}" ai_tools_load_secret_patterns; } 2>/dev/null \
            || true
    fi
}

# claim_work_dir -- create CLAIM_WORK, the private directory (`mktemp -d`, 0700) holding a claim's path lists
# and the tool output its checks capture, removed by the EXIT trap with the allowlist snapshot.
CLAIM_WORK=""
claim_work_dir() {
    if [[ -z "${CLAIM_WORK}" ]]; then
        CLAIM_WORK="$(mktemp -d)" || die "cannot create a private work directory for the claim's drift checks"
        trap remove_run_files EXIT
    fi
}

# The claim's outcome rows (ai-tools-records(5)). _claim_info / _claim_attention / _claim_unreadable <code> <finding>
# put the code and severity a finding token carries into _CLAIM_CODE and _CLAIM_SEVERITY -- one word per severity,
# the code first, so the message index reads each table line as the definition it is and the messages page derives
# the severity from the word.
readonly CLAIM_SCAN_CAP=200
CLAIM_FORMAT=page
_CLAIM_CODE=""
_CLAIM_SEVERITY=""
_claim_info()       { _CLAIM_CODE="$1"; _CLAIM_SEVERITY=info; }
_claim_attention()  { _CLAIM_CODE="$1"; _CLAIM_SEVERITY=attention; }
_claim_unreadable() { _CLAIM_CODE="$1"; _CLAIM_SEVERITY=unreadable; }

# claim_write_row <finding> <subject-type> <kind> <path> <detail>  -- record one outcome of the claim's drift checks
# and fold its severity into the report state the exit is read from. <kind> is `label` or `group`, the row's one item
# component; the operator is the one the run acts for. Under `--format tsv` the row goes to fd 3 as a record;
# on the page it is an outcome_record line whose first field is the finding without its kind.
claim_write_row() {
    local finding="$1" subject_type="$2" kind="$3" path="$4" detail="$5" item=""
    case "${finding}" in
        label-fixed)      _claim_info       MSG-T8F5 "label-fixed" ;;
        label-not-fixed)  _claim_attention  MSG-Q4G7 "label-not-fixed" ;;
        label-unverified) _claim_unreadable MSG-P4K8 "label-unverified" ;;
        label-gone)       _claim_info       MSG-E4Y3 "label-gone" ;;
        group-fixed)      _claim_info       MSG-J7X4 "group-fixed" ;;
        group-not-fixed)  _claim_attention  MSG-T6G3 "group-not-fixed" ;;
        group-unverified) _claim_unreadable MSG-D3K4 "group-unverified" ;;
        group-gone)       _claim_info       MSG-B6S7 "group-gone" ;;
        scan-capped)      _claim_attention  MSG-B7P8 "scan-capped" ;;
        error)            _claim_unreadable MSG-Q6X2 "error" ;;
        *) claim_write_row error directory "${kind}" "${path}" "no code for the finding '${finding}'"; return 0 ;;
    esac
    if [[ "${CLAIM_FORMAT}" == tsv ]]; then
        if ! ai_tools_records_tsv_frame_item_components item "${kind}"; then
            ai_tools_records_accumulate_severity unreadable
            return 0
        fi
        ai_tools_records_tsv_write_record "" "${_CLAIM_CODE}" "${_CLAIM_SEVERITY}" "${finding}" "${subject_type}" \
            "${OWNER_USER}" "${item}" "${path}" "${detail}" >&3 || true
        return 0
    fi
    ai_tools_records_accumulate_severity "${_CLAIM_SEVERITY}"
    outcome_record "${finding#"${kind}"-}" "${kind}" "${path}" "${detail}"
}

# claim_write_list <file> [<path>...]  -- write the paths NUL-separated to <file>, removing any earlier copy first.
# Returns 1 when the write fails and removes the partial file, so the reader that follows fails too and its paths read
# unknown; a stale list is not read.
claim_write_list() {
    local file="$1"
    shift
    rm -f -- "${file}" 2>/dev/null || return 1
    { printf '%s\0' "$@" > "${file}"; } 2>/dev/null || { rm -f -- "${file}" 2>/dev/null; return 1; }
}

# claim_subject_type <path>  -- print `directory` when the path itself is a directory and `file` for anything else,
# a symlink to a directory included: the subject-type a row records, read at collection so a `gone` row keeps
# what the path was.
claim_subject_type() {
    if [[ -d "$1" && ! -L "$1" ]]; then printf 'directory'; else printf 'file'; fi
}

# claim_verify_label <paths-array> <outcomes-array>  -- after the Apply block, check each listed label-drift path on its
# own and fill <outcomes-array>, index for index, with the outcome tokens claim_write_row records. Absence is looked
# up first (project-permissions.lib.sh); the paths that exist and hold no line feed go into one batch WITHOUT `-i`,
# so a path removed after that lookup fails the batch rather than reading as a match, and a name holding a line feed is
# checked on its own. From a batch whose output is not complete only the drift records it carried whole are read,
# and the lookup runs again over every path still unresolved: a confirmed absence is `gone`, anything else
# `unverified`.
# shellcheck disable=SC2034  # batch_listed is read by the library through the nameref it is passed as
claim_verify_label() {
    local -n _verify_label_paths="$1" _verify_label_outcomes="$2"
    local path index outcome from to complete=true
    local -a absence=() batched=() recheck=() recheck_absence=()
    local -A batch_listed=() batch_drift=()
    _verify_label_outcomes=()
    if ! claim_write_list "${CLAIM_WORK}/verify-label.list" "${_verify_label_paths[@]}" \
            || ! ai_tools_project_permissions_lstat_outcomes "${CLAIM_WORK}/verify-label.list" "${CLAIM_WORK}" absence; then
        absence=()
    fi
    for index in "${!_verify_label_paths[@]}"; do
        path="${_verify_label_paths[index]}"
        case "${absence[index]:-unknown}" in
            gone)    _verify_label_outcomes[index]=gone ;;
            unknown) _verify_label_outcomes[index]=unverified ;;
            exists)
                if [[ "${path}" == *$'\n'* ]]; then
                    ai_tools_project_permissions_label_check "${path}" "${CLAIM_WORK}" outcome from to
                    case "${outcome}" in
                        match) _verify_label_outcomes[index]=fixed ;;
                        drift) _verify_label_outcomes[index]=not-fixed ;;
                        *)     recheck+=("${index}") ;;
                    esac
                else
                    batch_listed["${path}"]=1
                    batched+=("${index}")
                fi ;;
        esac
    done
    if (( ${#batched[@]} )); then
        local -a batch_paths=()
        for index in "${batched[@]}"; do batch_paths+=("${_verify_label_paths[index]}"); done
        if ! claim_write_list "${CLAIM_WORK}/verify-label.batch" "${batch_paths[@]}" \
                || ! ai_tools_project_permissions_label_batch "${CLAIM_WORK}/verify-label.batch" "${CLAIM_WORK}" \
                    batch_listed batch_drift; then
            complete=false
        fi
        for index in "${batched[@]}"; do
            path="${_verify_label_paths[index]}"
            if [[ -n "${batch_drift[${path}]+set}" ]]; then
                _verify_label_outcomes[index]=not-fixed
            elif ${complete}; then
                _verify_label_outcomes[index]=fixed
            else
                recheck+=("${index}")
            fi
        done
    fi
    (( ${#recheck[@]} )) || return 0
    local -a recheck_paths=()
    for index in "${recheck[@]}"; do recheck_paths+=("${_verify_label_paths[index]}"); done
    if ! claim_write_list "${CLAIM_WORK}/verify-label.recheck" "${recheck_paths[@]}" \
            || ! ai_tools_project_permissions_lstat_outcomes "${CLAIM_WORK}/verify-label.recheck" "${CLAIM_WORK}" \
                recheck_absence; then
        recheck_absence=()
    fi
    for index in "${!recheck[@]}"; do
        if [[ "${recheck_absence[index]:-unknown}" == gone ]]; then
            _verify_label_outcomes[recheck[index]]=gone
        else
            _verify_label_outcomes[recheck[index]]=unverified
        fi
    done
}

# claim_verify_group <paths-array> <outcomes-array> <details-array>  -- after the Apply block, check each listed
# group-drift path against the postconditions the repair establishes (ai_tools_project_permissions_group_check) and fill
# <outcomes-array> with the outcome tokens claim_write_row records, and <details-array> with the check's reason
# for a path it did not pass. The identities are resolved to numeric ids once; one that does not resolve leaves every
# path `unverified`.
claim_verify_group() {
    local -n _verify_group_paths="$1" _verify_group_outcomes="$2" _verify_group_details="$3"
    local index outcome detail operator_uid="" sandbox_uid="" sandbox_gid=""
    local -a absence=()
    _verify_group_outcomes=() _verify_group_details=()
    operator_uid="$(id -u "${OWNER_USER}" 2>/dev/null)" || operator_uid=""
    sandbox_uid="$(id -u "${SANDBOX_USER}" 2>/dev/null)" || sandbox_uid=""
    sandbox_gid="$(getent group "${SANDBOX_GROUP}" 2>/dev/null | cut -d: -f3)" || sandbox_gid=""
    if ! claim_write_list "${CLAIM_WORK}/verify-group.list" "${_verify_group_paths[@]}" \
            || ! ai_tools_project_permissions_lstat_outcomes "${CLAIM_WORK}/verify-group.list" "${CLAIM_WORK}" absence; then
        absence=()
    fi
    for index in "${!_verify_group_paths[@]}"; do
        case "${absence[index]:-unknown}" in
            gone)
                _verify_group_outcomes[index]=gone _verify_group_details[index]="no entry at the path" ;;
            unknown)
                _verify_group_outcomes[index]=unverified
                _verify_group_details[index]="whether the path exists could not be read" ;;
            exists)
                if [[ ! "${operator_uid}${sandbox_uid}${sandbox_gid}" =~ ^[0-9]+$ || -z "${operator_uid}" \
                        || -z "${sandbox_uid}" || -z "${sandbox_gid}" ]]; then
                    _verify_group_outcomes[index]=unverified
                    _verify_group_details[index]="the operator, the sandbox account or its group did not resolve to an id"
                    continue
                fi
                ai_tools_project_permissions_group_check "${_verify_group_paths[index]}" "${CLAIM_WORK}" \
                    "${operator_uid}" "${sandbox_uid}" "${sandbox_gid}" outcome detail
                case "${outcome}" in
                    match) _verify_group_outcomes[index]=fixed ;;
                    drift) _verify_group_outcomes[index]=not-fixed ;;
                    *)     _verify_group_outcomes[index]=unverified ;;
                esac
                _verify_group_details[index]="${detail}" ;;
        esac
    done
}

# under_skip_listed_name <base> <path>  -- 0 when <path> sits under a skip-listed directory NAME (build output,
# dependencies, caches) relative to <base>, honoring the relative artifact exclusions that re-open a subtree
# to the walks. The single predicate behind both the claim's "drift I cannot repair" split and the unclaim's "residue
# the default walk will not reach" split, so one skip contract decides both. Returns 1 when the skip list is
# unavailable, which treats every hit as reachable -- the fail-soft direction for a walk-cost optimization.
under_skip_listed_name() {
    local _base="$1" _path="$2" _rel _seg _name _s _x
    [[ "${#AI_TOOLS_SKIP_NAMES[@]}" -gt 0 ]] || return 1
    _rel="${_path#"${_base}"/}"
    # Split on `/` alone: a read would stop at a line feed in the name and judge the path on its first line.
    mapfile -d / -t _seg < <(printf '%s' "${_rel}")
    for _name in "${AI_TOOLS_SKIP_NAMES[@]}"; do
        for _s in "${_seg[@]}"; do
            if [[ "${_s}" == "${_name}" ]]; then
                # A relative artifact exclusion re-opens its subtree to the walks, so a hit under one is reachable, not
                # skip-listed.
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

# tree_is_pristine <dir>  -- 0 when <dir> holds only what `projects create` just put there: no file outside .git except
# README.md, and a git repository with no commits. One `find` that stops at the first hit and one `git rev-parse`,
# unprivileged.
#
# It is re-derived here rather than trusted from the caller, because what it gates is the secret scan: a stale
# or planted CLAIM_FRESH_TREE must not be able to skip that on a tree with content in it. Both halves are the actual
# preconditions -- no files means no secret-named files, and no commits means no history -- so the answer is a property
# of the tree, not a claim about it.
tree_is_pristine() {
    local d="$1"
    [[ -z "$(find "${d}" -path "${d}/.git" -prune -o ! -type d ! -path "${d}/README.md" \
                 -print -quit 2>/dev/null)" ]] || return 1
    [[ -d "${d}/.git" ]] || return 0
    ! git -C "${d}" rev-parse --verify --quiet HEAD >/dev/null 2>&1
}

# require_claimable_owner <dir>  -- die unless <dir> is held by the operator this run acts FOR or by the sandbox
# account: ai-tools-setgid and ai-tools-setfacl, the two helpers that grant the agent its access, act only on those two
# owners, so a root held by anyone else would take every registry step and none of the access-granting ones. The case it
# exists for is a `--for` claim over a tree the invoker made
# (`mkdir ~/proj && ai-tools projects claim --for svc ~/proj`), and the refusal names the chown that fixes it, since
# transferring a tree recursively needs an authority this CLI does not hold. The consequence and the remedy are
# cli.rule.md's.
require_claimable_owner() {
    local d="$1" owner
    owner="$(stat -c '%U' "${d}" 2>/dev/null)" || die "cannot read the owner of ${d}"
    [[ "${owner}" == "${OWNER_USER}" || "${owner}" == "${SANDBOX_USER}" ]] && return 0

    # The remedy is a command, so it prints plain and ahead of die(), whose emitter would wrap it across lines
    # (messaging.rule.md).
    printf '\n' >&2
    printf '  %s\n' "Give the tree to ${OWNER_USER}, then re-run the claim:" "" \
                    "    sudo chown -R ${OWNER_USER} ${d}" >&2
    printf '\n' >&2
    # The headline is passed literally rather than out of the array, so the message code labels a string the reference
    # index can read (a quoted value opening with `$` is a citation, not a target) -- see messaging.rule.md.
    local -a why=(
        "The claim's setgid and ACL steps act only on paths held by ${OWNER_USER} or ${SANDBOX_USER}, so here they would apply nothing while the registries and the SELinux label still would -- a claim that reports success and leaves the agent unable to enter the project."
    )
    [[ -n "${FOR_OPERATOR}" ]] && why+=(
        "You are claiming for ${FOR_OPERATOR}, so the tree has to belong to ${FOR_OPERATOR} rather than to you."
    )
    die MSG-U8G4 "this project directory is owned by ${owner}, and the claim grants it to ${OWNER_USER}." \
        "${why[@]}"
}

# cmd_project_claim [path] [-y|--yes] [--format tsv]  -- bring a real, IN-PLACE project (default: cwd) to a fully
# claimed state, idempotently: it reads the current state and performs the missing steps alone, so a fully claimed
# project is a quiet no-op. Six blocks in run order -- Review, Interior drift, Reachability, Secret lockdown, `.git`
# history, Apply -- each opened by a headline box and closed by its own confirm or result lines; a first claim skips
# the drift scans, since its normal walks repair the whole tree. `-y`/`--yes` pre-answers the proceed confirm
# and the interior relabel question alone; `--format tsv` puts the outcome rows on stdout as a record stream and every
# other line on stderr. The blocks' order and their defaults are cli.rule.md's.
cmd_project_claim() {
    # `-y`/`--yes` is an explicit per-invocation flag, passed by a caller that already confirmed the same decision (the
    # launch wrapper's delegated claim); the scoped opt-ins (secret lockdown, .git history, ancestor traversal)
    # and the group repair are separate questions it does not answer.
    #
    # `--format tsv`: once the command line is parsed, fd 3 takes stdout and stdout takes stderr, so every page line,
    # refusal and hint -- a helper's own output included -- lands on stderr without a change at any call site. A run
    # refused before that point writes only to stderr too, since die and warn already do. The questions keep asking
    # on /dev/tty.
    local a path="" ASSUME_YES=false format="" format_given=false expect_format=false
    for a in "$@"; do
        if ${expect_format}; then format="${a}"; expect_format=false; continue; fi
        case "${a}" in
            -y|--yes) ASSUME_YES=true ;;
            --format) expect_format=true format_given=true ;;
            --format=*) format="${a#--format=}" format_given=true ;;
            -*) die_usage MSG-J2A7 "unknown projects claim option: ${a} (allowed: -y/--yes, --format tsv)" ;;
            *)  if [[ -z "${path}" ]]; then path="${a}"
                else die_usage MSG-F8G9 "projects claim takes a single path"; fi ;;
        esac
    done
    if ${expect_format} || { ${format_given} && [[ "${format}" != tsv ]]; }; then
        die_usage MSG-S9A3 "projects claim --format takes one value, tsv"
    fi
    if [[ "${format}" == tsv ]]; then
        CLAIM_FORMAT=tsv
        exec 3>&1 1>&2
    fi
    local d; d="$(resolve_dir "${path:-$PWD}")"
    [[ -d "${d}" ]] || die "not a directory: ${d}"
    claim_load_libraries
    ai_tools_assert_safe_target "${d}" "project claim" || exit 3
    require_claimable_owner "${d}"

    # A parked project is answered up front (offer_reenable), ahead of the proceed confirm a run with no terminal
    # answers first; declining aborts the claim before any write.
    if [[ "$(allow_state "${d}")" == disabled ]]; then
        offer_reenable "${d}" "the claim" \
            || die "allowed-projects not updated -- ${d} is still disabled"
    fi

    # A tree `projects create` just made (tree_is_pristine re-derives it from the tree); each question it answers is
    # marked where it is asked.
    local fresh=false
    if [[ "${CLAIM_FRESH_TREE:-}" == "${d}" ]] && tree_is_pristine "${d}"; then fresh=true; fi

    local listed safedir filemode owngap acl labelled git
    # IFS pinned (see join_words).
    IFS=' ' read -r listed safedir filemode owngap acl labelled git < <(project_state "${d}")
    local need_label=false; [[ "${labelled}" == false ]] && need_label=true
    local need_filemode=false; [[ "${filemode}" == false ]] && need_filemode=true
    local need_acl=false; [[ "${acl}" == true ]] && need_acl=true
    local need_git=false; [[ "${git}" == true ]] && need_git=true

    # Interior drift is detected here and repaired in Apply, behind the same confirm and gate as the other in-place
    # steps; scanned on a re-claim whose ownership is in place, since a first claim repairs the whole tree
    # (cli.rule.md). Each walk reads the whole tree; past CLAIM_SCAN_CAP the claim keeps that many paths and writes
    # a `scan-capped` row, the group cap applied after the skip-list split so hits the claim cannot repair do not take
    # the places of ones it can.
    claim_work_dir
    ai_tools_records_begin_report
    local -a drift=()
    local group_scan_detail="" group_capped=false
    if [[ "${listed}" == true && "${owngap}" == false ]]; then
        acl_drift_scan "${d}" "${CLAIM_WORK}" drift group_scan_detail || true
    fi

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
    if (( ${#drift[@]} > CLAIM_SCAN_CAP )); then
        drift=("${drift[@]:0:CLAIM_SCAN_CAP}")
        group_capped=true
    fi
    # What each drifted path is before a repair, for the outcome records: a repair rewrites exactly those columns.
    # The subject-type each row records is read now too, so a `gone` row keeps what the path was.
    local -a drift_before=() drift_types=()
    local _hit _hit_detail
    for _hit in "${drift[@]}"; do
        _hit_detail="$(stat -c '%U:%G %a' -- "${_hit}" 2>/dev/null)" || _hit_detail='?'
        drift_before+=("${_hit_detail}")
        drift_types+=("$(claim_subject_type "${_hit}")")
    done

    # Interior label drift (label_drift_scan), scanned where the root is labelled: otherwise the whole-tree relabel is
    # pending anyway.
    local -a label_drift=()
    local -A label_drift_types=()
    local label_scan_detail="" label_capped=false
    if [[ "${listed}" == true && "${labelled}" == true ]]; then
        label_drift_scan "${d}" "${CLAIM_WORK}" label_drift label_drift_types label_scan_detail || true
        if (( ${#label_drift[@]} > CLAIM_SCAN_CAP )); then
            label_drift=("${label_drift[@]:0:CLAIM_SCAN_CAP}")
            label_capped=true
        fi
    fi
    local -a label_subject_types=()
    for _hit in "${label_drift[@]}"; do label_subject_types+=("$(claim_subject_type "${_hit}")"); done

    # A setgid bit on a sealed dir that belongs to some third group is the one piece of residue the claim walks decline
    # to remove, so it is surfaced here rather than left to the helper's stderr, where it scrolls past under the Apply
    # step.
    local -a sealed_setgid=()
    mapfile -t sealed_setgid < <(sealed_setgid_scan "${d}" | head -n 200)

    sealed_setgid_note() {
        (( ${#sealed_setgid[@]} )) || return 0
        headline_warn "NOTICE: setgid on an owner-only directory" \
            "${#sealed_setgid[@]} sealed director(ies) carry a setgid bit set to a group that is neither ${SANDBOX_GROUP} nor yours. The claim keeps it -- it cannot tell a deliberate choice from a leftover -- so new files there are still born in that group."
        path_listing "director(ies)" "${sealed_setgid[@]}"
        say "      ${C_DIM}if it was not intended, clear it yourself:  chmod g-s <dir>${C_RST}"
    }

    # Configuration a build reads from the project's ancestor directories. The toolchain walks the ancestry and opens
    # each file it recognises, so one the sandbox account is denied is a hard error naming that path, and the message
    # does not mention the sandbox boundary (ancestor-config.lib.sh). Read-only, and reported rather than repaired:
    # every step of a claim acts inside the project, so none of them closes this.
    local -a ancestor_configs=()
    if declare -F ai_tools_unreadable_ancestor_configs >/dev/null 2>&1; then
        mapfile -t ancestor_configs < <(ai_tools_unreadable_ancestor_configs "${d}")
    fi

    ancestor_config_note() {
        (( ${#ancestor_configs[@]} )) || return 0
        headline_warn "NOTICE: configuration above this project the agent cannot read" \
            "${#ancestor_configs[@]} file(s) above ${d} are configuration an installed toolchain reads for a build here, and the sandbox account cannot open them -- a build that reads one fails on it, naming a path outside the project. The claim acts inside the project, so it leaves them as they are."
        path_listing "file(s)" "${ancestor_configs[@]}"
        say "      ${C_DIM}a file moved into the project is readable to the sandbox account,${C_RST}"
        say "      ${C_DIM}which one above it is not${C_RST}"
    }

    skip_listed_note() {
        (( ${#drift_skipped[@]} )) || return 0
        headline_warn "NOTICE: drift under skip-listed directories" \
            "${#drift_skipped[@]} path(s) with a foreign group sit under skip-listed directory names (build output, dependencies, caches); claim leaves those trees untouched."
        path_listing "path(s)" "${drift_skipped[@]}"
        say "      ${C_DIM}if one is source in this project, exempt it in /etc/ai-tools/operator.conf --${C_RST}"
        say "      ${C_DIM}narrow the category (SKIP_ARTIFACT_DIRS=...) or list the path relative to the${C_RST}"
        say "      ${C_DIM}project root in SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE -- then re-claim;${C_RST}"
        say "      ${C_DIM}ownership only: ai-tools projects handback --full${C_RST}"
    }

    # claim_scan_rows: the rows a scan itself earns -- an `error` for a walk or batch whose output was not complete,
    # a `scan-capped` where it stopped at CLAIM_SCAN_CAP. Written on every path the claim ends by, the fully-claimed
    # no-op included, since an incomplete scan without drift rows does not describe a clean tree.
    claim_scan_rows() {
        [[ -z "${label_scan_detail}" ]] || claim_write_row error directory label "${d}" "${label_scan_detail}"
        [[ -z "${group_scan_detail}" ]] || claim_write_row error directory group "${d}" "${group_scan_detail}"
        ! ${label_capped} || claim_write_row scan-capped directory label "${d}" \
            "the label scan stopped at ${CLAIM_SCAN_CAP} paths; re-claim once these are settled"
        ! ${group_capped} || claim_write_row scan-capped directory group "${d}" \
            "the group scan stopped at ${CLAIM_SCAN_CAP} paths; re-claim once these are settled"
        return 0
    }

    # claim_drift_records: after the Apply block, check each drifted path on its own and write one row per path --
    # `fixed` where its postcondition now holds, `not-fixed` where it does not (declined, not authorized, or a repair
    # that did not take), `unverified` where the check could not be read, and `gone` where the path is confirmed absent.
    # A re-scan of the tree is not what decides `fixed`: a path can be missing from one because it was capped, failed,
    # or excluded (cli.rule.md). The ways to settle a not-fixed path follow the rows.
    claim_drift_records() {
        (( ${#label_drift[@]} || ${#drift[@]} )) || { claim_scan_rows; return 0; }
        local _i _outcome _detail _left_label=false _left_group=false _mixed=0 _group_fixed _label_fixed
        local -a _label_outcomes=() _group_outcomes=() _group_details=()
        local -A _label_by_path=()
        [[ "${CLAIM_FORMAT}" == tsv ]] || say "  interior drift:"
        claim_scan_rows
        if (( ${#label_drift[@]} )); then
            claim_verify_label label_drift _label_outcomes
            for _i in "${!label_drift[@]}"; do
                _outcome="${_label_outcomes[_i]:-unverified}"
                case "${_outcome}" in
                    unverified) _detail="its type could not be read after the relabel" ;;
                    gone)       _detail="no entry at the path" ;;
                    *)          _detail="${label_drift_types[${label_drift[_i]}]:-}" ;;
                esac
                [[ "${_outcome}" == not-fixed ]] && _left_label=true
                _label_by_path["${label_drift[_i]}"]="${_outcome}"
                claim_write_row "label-${_outcome}" "${label_subject_types[_i]}" label "${label_drift[_i]}" "${_detail}"
            done
        fi
        if (( ${#drift[@]} )); then
            claim_verify_group drift _group_outcomes _group_details
            for _i in "${!drift[@]}"; do
                _outcome="${_group_outcomes[_i]:-unverified}"
                _detail="${_group_details[_i]:-}"
                [[ "${_outcome}" == fixed ]] && _detail="was ${drift_before[_i]}"
                # A repair that did not run, over a path still as the scan read it, is said in the fixed row's terms.
                # A path something else changed since -- the secret gate sealing it owner-only -- keeps the check's own
                # reason, which names what it now is.
                if [[ "${_outcome}" == not-fixed ]] && ! ${do_drift} \
                        && [[ "$(stat -c '%U:%G %a' -- "${drift[_i]}" 2>/dev/null)" == "${drift_before[_i]}" ]]; then
                    _detail="still ${drift_before[_i]}"
                fi
                [[ "${_outcome}" == not-fixed ]] && _left_group=true
                # A path on both lists is reachable only once both repairs took: its permissions and its type each
                # refuse the agent on their own, so one fixed and the other not leaves it as closed
                # as before, which neither row says alone.
                if [[ -n "${_label_by_path[${drift[_i]}]+set}" ]]; then
                    _group_fixed=false _label_fixed=false
                    [[ "${_outcome}" == fixed ]] && _group_fixed=true
                    [[ "${_label_by_path[${drift[_i]}]}" == fixed ]] && _label_fixed=true
                    [[ "${_group_fixed}" != "${_label_fixed}" ]] && _mixed=$(( _mixed + 1 ))
                fi
                claim_write_row "group-${_outcome}" "${drift_types[_i]}" group "${drift[_i]}" "${_detail}"
            done
        fi
        [[ "${CLAIM_FORMAT}" == tsv ]] && return 0
        if (( _mixed )); then
            say "      ${_mixed} path(s) were fixed for one kind only -- the agent still cannot open them;"
            say "      re-run the claim and answer yes to the other question to share them"
        fi
        ${_left_label} || ${_left_group} || return 0
        # The settle commands are the per-path form the claim's repairs do not have, since each repair acts on every
        # path it reaches. A path's owner may set its label without sudo, so a relabel of a few paths is one command
        # each; the owner is not in the sandbox group, so the paths to keep from the group repair are sealed or carved
        # out first. Under `--for` those files belong to the target operator, and the commands are theirs to run.
        local _who="you"
        [[ -n "${FOR_OPERATOR}" ]] && _who="${OWNER_USER}"
        say "      ${C_DIM}to share them all with the agent, re-run the claim and answer yes${C_RST}"
        say "      ${C_DIM}to keep one out of its reach, as ${_who}: chmod 600 <path>${C_RST}"
        say "      ${C_DIM}to stop a re-claim asking about one, as ${_who}: add a line !<path>${C_RST}"
        say "      ${C_DIM}to ~/.config/ai-tools/allowed-projects${C_RST}"
        if ${_left_label}; then
            say "      ${C_DIM}to relabel only some, as ${_who}: restorecon -F <path>${C_RST}"
        fi
        if ${_left_group}; then
            say "      ${C_DIM}to repair the group for only some, chmod 600 or add a ! line for the others,${C_RST}"
            say "      ${C_DIM}then re-run the claim and answer yes${C_RST}"
        fi
        return 0
    }

    # ── Review block: the flow headline, the pending-step overview, and the drift reports, so the proceed confirm
    # that closes it covers exactly what was just shown. Every later block is announced here with a `you will be asked`
    # marker. ──
    local heavy=false
    local -a head=("${d}")
    if [[ "${owngap}" == true ]] || ${need_acl} || ${need_label}; then
        heavy=true
    fi
    # Not said on a pristine tree (cli.rule.md, `projects create`). The warning is what the operator sees of the fact
    # that an unclaim normalizes rather than restores (ai-tools-unclaim's header).
    if ${heavy} && ! ${fresh}; then
        head+=("claiming in place grants the agent group access to this whole tree")
        head+=("It MODIFIES group, permissions and ACLs throughout this tree, sets setgid on its directories, and removes world access. Files and directories that are owner-only (0600/0700) are left alone, out of the agent's reach. The previous permissions are NOT recorded anywhere, so this is NOT reversible -- unclaiming later normalizes the tree rather than restoring it. Back up first. See: man ai-tools")
    fi
    headline "Claim project (in place)" "${head[@]}"

    find_blocking_ancestors "${d}"

    # The project root being owner-only is find_blocking_ancestors's problem one level down: ai-tools-setfacl honours
    # a 0600/0700 mode and skips the path, so every later step still succeeds and the claim closes with its ✓ while
    # the sandbox account cannot enter the tree at all. Stated here, before the confirm, rather than left
    # to the helper's skip count
    # afterwards.
    local root_mode
    root_mode="$(stat -c '%a' "${d}" 2>/dev/null || echo 755)"
    if (( ( 8#${root_mode} & 077 ) == 0 )); then
        headline_warn "NOTICE: this project directory is owner-only" \
            "${d} is mode ${root_mode}, which keeps it out of the sandbox account's reach: the claim honours that mode and grants nothing on it."
        say ""
    fi

    # A claimed project can still sit under a non-traversable parent (a later chmod 700 on an ancestor), and the grant
    # that closes that is a pending step like the others -- it takes the gate -- so a project with one takes
    # the pending-steps flow rather than this path.
    if [[ "${listed}" == true && "${safedir}" == true && "${owngap}" == false ]] \
            && ! ${need_filemode} && ! ${need_acl} && ! ${need_label} && ! ${need_git} \
            && (( ${#drift[@]} == 0 && ${#label_drift[@]} == 0 && ${#TRAVERSAL_GRANT_PATHS[@]} == 0 )); then
        skip_listed_note
        sealed_setgid_note
        ancestor_config_note
        # With no grant to offer, this prints the blocked-ancestor warning alone, where there is one.
        confirm_ancestor_traversal "${d}"
        claim_scan_rows
        ok "already fully claimed -- nothing to do"
        claim_end
        return 0
    fi

    # The gate runs where a pending step widens access (secret_gate) and on every first claim; a drift repair
    # and the traverse grant count once answered yes, so here they decide only whether the overview announces it.
    local need_gate=false
    if [[ "${listed}" != true || "${owngap}" == true ]] \
            || ${need_acl} || ${need_git} || ${need_label}; then
        need_gate=true
    fi
    # A pristine tree has no secret-named file to find (cli.rule.md, `projects create`).
    if ${fresh}; then need_gate=false; fi
    local gate_announced="${need_gate}"
    (( ${#drift[@]} || ${#label_drift[@]} || ${#TRAVERSAL_GRANT_PATHS[@]} )) && gate_announced=true

    say ""
    say "  pending:"
    [[ "${listed}"  == true  ]] || say "    - add to allowed-projects"
    [[ "${safedir}" == true  ]] || say "    - add git safe.directory"
    ${need_filemode} && say "    - set git core.filemode true"
    [[ "${owngap}"  == true  ]] && say "    - set group ${SANDBOX_GROUP} + setgid on the project directories"
    ${need_acl} && say "    - apply group-permission ACL (default + access g:${SANDBOX_GROUP}:rwX)"
    ${need_label} && say "    - apply SELinux ai_tools_project_t label"
    (( ${#label_drift[@]} )) \
        && say "    - SELinux type differs on ${#label_drift[@]} path(s) -- you will be asked to relabel the tree (default no)"
    (( ${#drift[@]} )) \
        && say "    - group differs on ${#drift[@]} path(s) -- you will be asked to move them to group ${SANDBOX_GROUP} (default no)"
    if ${need_gate}; then
        say "    - scan for secret-named files and lock them down -- you will confirm"
    elif ${gate_announced}; then
        say "    - scan for secret-named files if you accept a repair -- you will confirm"
    fi
    if ${need_git}; then
        if ${fresh}; then say "    - normalize .git so the agent can access git history"
        else say "    - normalize .git so the agent can access git history -- you will be asked"; fi
    fi
    (( ${#TRAVERSAL_GRANT_PATHS[@]} )) && say "    - grant traverse-only access on ${#TRAVERSAL_GRANT_PATHS[@]} parent path(s) -- you will be asked"

    skip_listed_note
    sealed_setgid_note
    ancestor_config_note

    # Heavy steps close the Review block behind the proceed confirm, the one prompt `--yes` pre-answers; a pristine tree
    # skips it with the warnings it authorizes.
    if ${heavy} && ! ${fresh}; then
        ${ASSUME_YES} || confirm "Apply these pending steps to the tree in place?" n \
            || die "aborted"
    fi

    # ── Interior drift: one block per kind, each its list and then its question, so the answer follows the paths it is
    # about. Each repair can widen the agent's access, so each defaults to no (cli.rule.md). A declined repair is
    # reported as not fixed; the claim goes on. ──
    local do_label_drift=false do_drift=false
    if (( ${#label_drift[@]} )); then
        headline_warn "Interior drift: SELinux type" \
            "SELinux type differs on ${#label_drift[@]} path(s) inside the tree: each carries a type other than the one this project's file-context rules give it -- moved in with mv, cp -a or tar --selinux, or relabelled by another tool. The agent is refused them whatever their permissions say."
        item_listing "path(s) with their types" label_drift_lines "${label_drift[@]}"
        drift_secret_legend "${label_drift[@]}"
        ! ${label_capped} || say "        ${C_DIM}(scan capped at ${CLAIM_SCAN_CAP} paths)${C_RST}"
        # What the answer changes, and what it costs, sit directly ahead of the question: the relabel reaches every path
        # in the tree, not only the ones listed.
        say "      a relabel changes SELinux types only; owner, group and mode stay"
        say "      ${C_YEL}it resets every type in the tree: a Podman :Z volume or a directory${C_RST}"
        say "      ${C_YEL}httpd serves is reset too, and that service loses its access${C_RST}"
        # Only an explicit `--yes` answers this without a terminal, and AI_TOOLS_ASSUME_YES does not answer it at all:
        # the relabel resets every type in the tree, so an unattended run relabels only where its caller said
        # so on the command line.
        if ${ASSUME_YES}; then
            do_label_drift=true
        elif have_tty; then
            if AI_TOOLS_ASSUME_YES='' confirm "Relabel the tree to the project's SELinux types?" n; then
                do_label_drift=true
            fi
        else
            say "      relabel not run: no terminal to ask on, and --yes was not given"
        fi
    fi
    # With the relabel not run and every path of this list also on the relabel list, a group repair would share none
    # of them (cli.rule.md), so the question is not asked and the rows report the group as not fixed.
    local group_needs_label=false _p
    # On a host not enforcing, a foreign type does not refuse the agent, so the group repair alone shares the path.
    if (( ${#drift[@]} && ${#label_drift[@]} )) && ! ${do_label_drift} \
            && [[ "$(getenforce 2>/dev/null)" == Enforcing ]]; then
        local -A _on_label_list=()
        for _p in "${label_drift[@]}"; do _on_label_list["${_p}"]=1; done
        group_needs_label=true
        for _p in "${drift[@]}"; do
            [[ -n "${_on_label_list[${_p}]+set}" ]] || { group_needs_label=false; break; }
        done
    fi
    if (( ${#drift[@]} )); then
        headline_warn "Interior drift: group and ACL" \
            "Group differs on ${#drift[@]} path(s) inside the tree: each has a group other than ${SANDBOX_GROUP} and group access -- it arrived without inheriting the project group or ACL." \
            "Keep a file shared with a team group or read by a service's group as it is."
        PATH_DETAIL_MARK=1 path_listing "path(s)" "${drift[@]}"
        drift_secret_legend "${drift[@]}"
        ! ${group_capped} || say "        ${C_DIM}(scan capped at ${CLAIM_SCAN_CAP} paths)${C_RST}"
        if ${group_needs_label}; then
            say "      group repair not offered: these path(s) keep a type the agent is"
            say "      refused, so a group change alone gives it no access -- re-run the"
            say "      claim and relabel to share them"
        else
            say "      a move changes group and ACL only; the SELinux type stays"
            say "      ${C_YEL}the agent gets what each path's group bits grant, and the group it${C_RST}"
            say "      ${C_YEL}has now loses its access${C_RST}"
            if confirm "Move these ${#drift[@]} path(s) to group ${SANDBOX_GROUP} with the project ACL?" n; then
                do_drift=true
            fi
        fi
    fi
    if ${do_label_drift} || ${do_drift}; then
        ${fresh} || need_gate=true
    fi

    # An accepted traverse grant is an access-widening step, so it takes the gate (confirm_ancestor_traversal); the ACL
    # is set in Apply.
    confirm_ancestor_traversal "${d}"
    if ${TRAVERSAL_GRANT_CONFIRMED}; then
        ${fresh} || need_gate=true
    fi

    # Allowlist first: ai-tools-lockdown only scans an allowlisted path. Rolled back on a failed gate.
    [[ "${listed}" == true ]] || reg_allow "${d}"

    if ${need_gate}; then
        if ! secret_gate "${d}"; then
            [[ "${listed}" == true ]] || unreg_allow "${d}"
            say "    lock down secrets first, then re-run the claim:"
            say "      ${C_BOLD}ai-tools projects lockdown ${d}${C_RST}"
            die "claim stopped -- secrets not locked down"
        fi
    fi

    # .git access is opt-in (default yes), asked separately from the proceed prompt -- which --yes covers; this one it
    # does not, so a wrapper-delegated claim still asks before exposing the repo's full git history.
    local do_git=false
    if ${need_git}; then
        if ${fresh}; then
            # Inferred, not asked. The question is about exposing history, and a repository with no commits has none;
            # normalizing is meanwhile the outcome the operator wants either way, since it is what keeps THEIR later
            # commits readable by the agent. Asking would offer a choice between one real option and one that costs them
            # something for no gain.
            do_git=true
            say "    .git: normalizing for shared history (new repository -- no history to expose)"
        else
            headline_warn "WARNING: git history exposure" \
                "normalizing .git lets the agent read this repo's full git history"
            if confirm "Normalize .git so the agent can access git history here?" y; then
                do_git=true
            else
                say "    .git: left as-is (history not accessible to the agent)"
            fi
        fi
    fi

    # ── Apply block: the approved steps run back to back, each reporting one result line; the closing ✓ is the claim's
    # completion. The headline opens only over a step that runs: with every repair declined there is none, and an empty
    # block would read as work done. ──
    local apply_steps=false
    if [[ "${safedir}" != true || "${owngap}" == true ]] || ${need_filemode} || ${need_acl} || ${do_git} \
            || ${need_label} || ${do_drift} || ${do_label_drift} || ${TRAVERSAL_GRANT_CONFIRMED}; then
        apply_steps=true
    fi
    if ${apply_steps}; then headline "Applying claim steps" "${d}"; fi

    # The traverse grant goes first: it is unprivileged, so it cannot fail a password round, and a stop
    # by note_root_failure would otherwise skip it. A grant that did not take counts with the root steps that did not
    # apply, and does not ask note_root_failure's question, which is about a password round.
    if ${TRAVERSAL_GRANT_CONFIRMED} && ! grant_ancestor_traversal; then
        ROOT_STEP_FAILURES=$(( ROOT_STEP_FAILURES + 1 ))
    fi

    # A failed step asks once before the next is attempted (note_root_failure); stopping is the safe direction here.
    local stopped=false
    if [[ "${safedir}" != true ]]; then
        reg_safedir "${d}" || note_root_failure || stopped=true
    fi
    ${need_filemode} && reg_filemode "${d}"
    if ! ${stopped}; then
        if [[ "${owngap}" == true ]]; then
            reg_ownership "${d}" || note_root_failure || stopped=true
        elif ${do_drift}; then
            reg_ownership "${d}" force || note_root_failure || stopped=true
        fi
    fi
    if ! ${stopped} && { ${need_acl} || ${do_git} || ${do_drift}; }; then
        claim_setfacl "${d}" "${do_git}" || note_root_failure || stopped=true
    fi
    if ! ${stopped} && { ${need_label} || ${do_label_drift}; }; then
        claim_relabel "${d}" || note_root_failure || stopped=true
    fi
    say ""
    claim_drift_records

    # A claim whose access-granting steps did not apply exits 1 in place of the ✓: no success mark over a project
    # the agent has no group or ACL entry into. The registry entries stand, so a re-run applies what is missing.
    if (( ROOT_STEP_FAILURES )); then
        headline_warn "WARNING: the claim did not complete" \
            "${d} is registered, but ${ROOT_STEP_FAILURES} step(s) that grant the agent access did not apply, so it cannot work there yet. Each is named above with the command that applies it. Re-running the claim is the simpler route -- it is idempotent and does only what is still missing:"
        say "      ${C_BOLD}ai-tools projects claim ${d}${C_RST}"
        ai_tools_log_structured warning \
            "claim of ${d} incomplete -- ${ROOT_STEP_FAILURES} root step(s) did not apply" \
            "AI_TOOLS_PROJECT=${d}" "AI_TOOLS_RESULT=failed"
        exit 1
    fi
    # `no change applied` is said only where no step that writes could have run: no registry entry, no secret scan, no
    # traverse grant offered, and no Apply step. Any other run keeps the plain line, which does not say either way.
    # The ✓ is kept for a claim that left no drift and no capped scan: with a not-fixed or a scan-capped row the claim
    # ends non-zero, and the line takes the mark that status carries.
    local closing="claimed ${d}"
    if ! ${apply_steps} && [[ "${listed}" == true ]] && ! ${need_gate} && (( ${#TRAVERSAL_GRANT_PATHS[@]} == 0 )); then
        closing+=" -- no change applied"
    fi
    if ai_tools_records_get_exit_status; then
        ok "${closing}"
    else
        say "  ${C_YEL}!${C_RST} ${closing}"
    fi
    ai_tools_log_structured info "claimed project ${d}" \
        "AI_TOOLS_PROJECT=${d}" "AI_TOOLS_RESULT=ok"
    claim_end
}

# claim_end -- end a claim that applied its steps with the report state's status (ai-tools-records(5)), which the rows
# written before it folded their severity into. A root step that failed has already exited 1, which outranks both (1
# over 5 over 4). On the page a non-zero status is said in one line, since the rows printed before it name each path.
claim_end() {
    local status=0
    ai_tools_records_get_exit_status || status=$?
    (( status )) || return 0
    if [[ "${CLAIM_FORMAT}" != tsv ]]; then
        if (( status == AI_TOOLS_EXIT_UNREADABLE )); then
            say "  ${C_DIM}exit ${status}: a drift check could not be read -- the unverified and error rows name it${C_RST}"
        else
            say "  ${C_DIM}exit ${status}: drift is left in place -- the not-fixed and scan-capped rows name it${C_RST}"
        fi
    fi
    exit "${status}"
}

# cmd_project_create <path>  -- create a NEW project directory and claim it: ONE mkdir, an empty git repository,
# a README.md, then cmd_project_claim unchanged on the result. It refuses a path that exists (naming `projects claim`)
# and a parent that does not, and <path> is required with no cwd default. Every filesystem step goes
# through run_as_owner, so a create under `--for` produces a TARGET-owned tree, the one require_claimable_owner then
# admits. It does not take `-y`: it does not ask a question a flag could pre-answer, and the traverse grant
# on an ancestor, the one question that can still appear, is answered by a person at a terminal alone. The refusals,
# the modes it sets and the claim questions it infers are cli.rule.md's.
cmd_project_create() {
    local a path=""
    for a in "$@"; do
        case "${a}" in
            -*) die_usage MSG-C5T8 "unknown projects create option: ${a}" \
                    "       it takes a path and nothing else; see: man ai-tools" ;;
            *)  if [[ -z "${path}" ]]; then path="${a}"
                else die_usage MSG-Z5Y7 "projects create takes a single path"; fi ;;
        esac
    done
    [[ -n "${path}" ]] || die MSG-A7D3 "projects create needs a path: it creates a NEW project directory." \
        "To claim a directory that already exists, use: ai-tools projects claim [path]"

    local d
    d="$(realpath -m -- "${path}" 2>/dev/null)" || die "cannot resolve the path: ${path}"
    if [[ -e "${d}" ]]; then
        die MSG-T4B9 "this path already exists: ${d}" \
            "projects create only ever creates. Claim what is already there instead:" \
            "       ai-tools projects claim ${d}"
    fi

    # ONE directory is created, the final component, and a parent that does not exist is refused: a mistyped path
    # surfaces as a refusal naming the missing directory and does not become a manufactured tree with a claimed project
    # inside it.
    local parent="${d%/*}"; [[ -n "${parent}" ]] || parent=/
    if [[ ! -d "${parent}" ]]; then
        die MSG-J3R8 "the parent directory does not exist: ${parent}" \
            "projects create creates ONE directory, not a path of them, so a mistyped path is refused here rather than created. Check the path; if it is right, create the parent yourself and re-run:" \
            "       mkdir -p ${parent}"
    fi

    # The backstop on the target. Only one directory is created, so this is the whole surface: it refuses a create
    # that would MANUFACTURE a protected directory (`/efi` or `/lost+found` on a host without one). It does not refuse
    # a project nested INSIDE a protected tree -- descendants pass by design here exactly as they do for a claim, or no
    # project under a home would work.
    ai_tools_assert_safe_target "${d}" "project create" || exit 3

    # Reachability pre-flight. The parent exists by now, so this scans the project's real ancestry: a blocker no grant
    # may cover means the sandbox account could never enter this project, so the create is refused BEFORE anything
    # exists rather than leaving a directory to clean up. A blocker the predicate DOES permit is not a refusal -- it
    # becomes the claim's own traverse opt-in, which offers the grant and the exact setfacl for anything it cannot
    # apply.
    find_blocking_ancestors "${d}"
    if [[ -n "${TRAVERSAL_BLOCKED_PATH}" ]]; then
        # State the blocker and why no grant covers it, and stop there. The claim's own version of this refusal points
        # at `projects clone`, which does not apply here: that verb clones an EXISTING repository into the sandbox area,
        # and this verb's whole subject is a project that does not exist yet, so there is no source to name.
        local why blocked_owner
        blocked_owner="$(stat -c '%U' "${TRAVERSAL_BLOCKED_PATH}" 2>/dev/null || true)"
        if [[ -n "${TRAVERSAL_BLOCKED_REASON}" ]]; then
            why="${TRAVERSAL_BLOCKED_REASON}, so no grant is offered on it"
        elif [[ -z "${blocked_owner}" ]]; then
            why="its owner cannot be read from here"
        elif [[ "${blocked_owner}" != "${OWNER_USER}" ]]; then
            why="it belongs to ${blocked_owner}, not to ${OWNER_USER}"
        else
            why="it is a protected system directory"
        fi
        headline_warn "WARNING: the agent could not reach a project here" \
            "the sandbox account cannot traverse ${TRAVERSAL_BLOCKED_PATH} (${why}), so it could not enter a project created at ${d}. Nothing has been created. Create the project somewhere the sandbox account can reach: every parent directory has to be one it can already enter, or one you own and can grant traverse on."

        # One alternative is offered, and only after it has been CHECKED on this host rather than assumed: the owner's
        # home is the usual reachable location, but whether it is depends on its ancestry, which differs per host.
        # A suggestion that cannot be verified is not made at all.
        local home_dir candidate
        home_dir="$(getent passwd "${OWNER_USER}" 2>/dev/null | cut -d: -f6)"
        if [[ -n "${home_dir}" && -d "${home_dir}" ]]; then
            candidate="${home_dir%/}/${d##*/}"
            find_blocking_ancestors "${candidate}"
            if [[ -z "${TRAVERSAL_BLOCKED_PATH}" && ! -e "${candidate}" ]]; then
                say ""
                say "  this location is reachable:"
                say "      ${C_BOLD}ai-tools projects create ${candidate}${C_RST}"
            fi
        fi
        die "project create stopped -- the agent could not reach a project at that location"
    fi

    # ── Apply. Deliberately ONE block, not a review followed by an apply: this verb does not ask for confirmation,
    # so a pending list would announce three steps whose result lines follow immediately underneath -- the same
    # information twice -- and the claim opens with a pending list of its own, which made the pair read as one repeated
    # block. ──
    headline "Create project" "${d}" \
        "Creating the directory, an empty git repository in it, and a README.md, then claiming it so the sandbox account can work there."
    # Mode 0750 set explicitly (`mkdir -m` applies it after creation, so the umask does not mask it): under a 077 umask
    # the directory would be born 0700, the seal ai-tools-setgid and ai-tools-setfacl honour and skip, and the claim
    # would register a project the agent cannot enter. 0750 and not 0770: write comes from the claim's ACL, and 0750 is
    # the mode an unclaim normalizes a directory back to. Why a umask is not a seal is cli.rule.md's.
    local umask_would_be
    printf -v umask_would_be '%04o' "$(( 0777 & ~0$(umask) ))"
    run_as_owner mkdir -m 0750 -- "${d}" || die "could not create ${d}"
    say "    created ${d}"
    if (( (8#${umask_would_be} & 077) == 0 )); then
        say "    ${C_DIM}modes set to 0750/0640 -- your umask ($(umask)) would have made them${C_RST}"
        say "    ${C_DIM}owner-only, which the agent cannot read${C_RST}"
    fi
    ai_tools_log_structured info "created project directory ${d}" \
        "AI_TOOLS_PROJECT=${d}" "AI_TOOLS_RESULT=ok"

    # Plain `git init`, so the operator's own init.defaultBranch decides the branch name rather than this tool holding
    # an opinion about it. run_as_owner passes -H, so it is the TARGET's git config that is read on a --for run.
    if run_as_owner git init -q -- "${d}"; then
        # git builds .git under the caller's umask, so on an 077 host it is born owner-only and the `--with-git` pass
        # would skip it as a seal. g+rX alone: write comes from the claim's ACL, as for the work tree.
        run_as_owner chmod -R g+rX -- "${d}/.git" \
            || warn "could not open .git for the agent -- git history may stay out of its reach"
        say "    git: initialized an empty repository"
    else
        warn "git init failed -- the directory is created but is not a git repository"
    fi

    # Written through `tee` as the owner, since a shell redirect here would create the file as the INVOKER on a --for
    # run.
    if printf '# %s\n' "${d##*/}" | run_as_owner tee -- "${d}/README.md" >/dev/null; then
        # tee creates under the caller's umask (0600 on an 077 host), a seal ai-tools-setfacl leaves alone; 0640 is
        # the mode an unclaim normalizes a file back to.
        run_as_owner chmod 0640 -- "${d}/README.md" \
            || warn "could not set the mode on README.md -- the agent may not be able to read it"
        say "    wrote README.md"
    else
        warn "could not write ${d}/README.md (continuing)"
    fi

    # The claim runs unchanged on the new tree; CLAIM_FRESH_TREE is a hint it re-derives (tree_is_pristine).
    CLAIM_FRESH_TREE="${d}"
    cmd_project_claim "${d}"
}

# positive_project_entries  -- print each allowed-projects entry that names a real, resolvable project directory
# (canonicalized), one per line, skipping blanks, comments, and '!' exclusions. Read with the shared config grammar
# so it agrees with cmd_project_list and the launch wrapper on what a line denotes. Stale (unresolvable) lines are
# omitted -- they name no path on disk, so they can neither be nor contain an unclaim target.
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

# project_entries  -- every entry the per-project verbs may act on: positive_project_entries PLUS the projects a '!'
# line parks. A disabled project is still a project the operator registered, so a verb that classifies against this list
# answers "this is your project, and it is disabled". A "not a claimed project" refusal there would send the operator
# to look for a claim that is in the file all along. Ordering follows the file, deduplicated, so a path carrying both
# an allow line and an exclusion (the pair a claim over a parked project used to create) appears once.
#
# An exclusion naming a path INSIDE a listed project is a carve-out, not a disabled project, and is left out: it names
# a subtree the operator withheld from the agent, and no per-project verb has ever taken one as a target.
project_entries() {
    local entry dir
    [[ -f "${ALLOWLIST}" ]] || return 0
    local -A seen_dirs=()
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
        ai_tools_conf_path_entry "${entry}" || continue
        entry="${_ai_tools_conf_value}"
        entry="${entry#\!}"
        dir="$(realpath -e "${entry}" 2>/dev/null)" || continue
        [[ -n "${seen_dirs[${dir}]:-}" ]] && continue
        seen_dirs["${dir}"]=1
        printf '%s\n' "${dir}"
    done < "${ALLOWLIST}"
}

# inside_listed_project <path>  -- 0 when a listed project STRICTLY ENCLOSES <path>. This is what separates a CARVE-OUT
# from a PARKED PROJECT, the two things a '!' line can mean: an exclusion under a listed project withholds a subtree
# from the agent and is working exactly as intended, while one no listed project contains is a project taken
# out of service. Strictly enclosing, because a path carrying both an allow line and an exclusion is parked (the
# exclusion wins at the launch gate) rather than carved out of itself. covered_by_project cannot answer this -- it
# honours exclusions, so it says "no" for every excluded path, which is every path that asks.
inside_listed_project() {
    local p="$1" e
    while IFS= read -r e; do
        [[ -n "${e}" ]] || continue
        [[ "${p}" == "${e}/"* ]] && return 0
    done < <(positive_project_entries)
    return 1
}

# refuse_carveout <dir> <verb>  -- stop a re-enable that would delete a carve-out. Lifting an exclusion is the one
# registry edit in this file that WIDENS what the agent reaches, and on a subtree an operator withheld from a project
# that is the whole point of the line. So the enabling paths -- the verb and the claim's prompt -- act only on a parked
# PROJECT, and a carve-out is refused back to the editor it was written in. Disabling does not need that guard: it moves
# the other way, and a path with no entry of its own is already refused for having no entry to park.
refuse_carveout() {
    local d="$1" verb="$2" parent=""
    inside_listed_project "${d}" || return 0
    local e
    while IFS= read -r e; do
        [[ -n "${e}" ]] || continue
        if [[ "${d}" == "${e}/"* ]] && (( ${#e} > ${#parent} )); then parent="${e}"; fi
    done < <(positive_project_entries)
    printf '\n' >&2
    disabled_note "${d}" >&2
    printf '\n' >&2
    die MSG-W4S7 "this is an excluded path inside a claimed project, not a disabled project: ${d}" \
        "the project is: ${parent}" \
        "That line withholds this subtree from the agent, and ${verb} would hand it over. If that is what you mean, delete the '!' line yourself -- allowed-projects is yours to edit."
}

# refuse_nested_park <dir> <verb>  -- the other half of keeping a '!' line unambiguous. Parking a project that sits
# INSIDE another listed project would write a line indistinguishable from a carve-out (an operator's exclusion
# withholding a subtree), and no field in the file could tell the two apart afterwards -- so re-enabling it later could
# only be a guess, on an edit that WIDENS what the agent reaches. No verb writes that line: with this refusal in place,
# every exclusion inside a listed project is a carve-out by construction, which is exactly what refuse_carveout relies
# on. The operator can still park a nested project by hand; the tool simply will not do it for them.
refuse_nested_park() {
    local d="$1" verb="$2" parent="" e
    inside_listed_project "${d}" || return 0
    while IFS= read -r e; do
        [[ -n "${e}" ]] || continue
        if [[ "${d}" == "${e}/"* ]] && (( ${#e} > ${#parent} )); then parent="${e}"; fi
    done < <(positive_project_entries)
    die MSG-D8C8 "this project is nested inside another claimed project: ${d}" \
        "the project above it is: ${parent}" \
        "Parking it would write a '!' line that cannot be told apart from an exclusion withholding a subtree from ${parent}, so ${verb} declines to write one. Either unclaim this project (ai-tools projects unclaim ${d}), or park the one above it (ai-tools projects disable ${parent})."
}

# blocking_exclusion <dir>  -- print the raw exclusion line that keeps <dir> out of reach without naming it: a parked
# ancestor, or a glob that matches. This is the gap between what the FILE says about an entry and what the LAUNCH GATE
# does with it -- a project can carry a clean allow line and still be unreachable -- so the verbs that report a state
# consult it and say which line is responsible, rather than reporting "enabled" over a path no session can enter.
blocking_exclusion() {
    local d="$1" raw entry val
    [[ -f "${ALLOWLIST}" ]] || return 1
    while IFS= read -r raw || [[ -n "${raw}" ]]; do
        ai_tools_conf_path_entry "${raw}" || continue
        entry="${_ai_tools_conf_value}"
        [[ "${entry}" == '!'* ]] || continue
        val="${entry:1}"; val="${val%/}"
        [[ "$(realpath -e "${val}" 2>/dev/null || printf '%s' "${val}")" == "${d}" ]] && continue
        # SC2053: the unquoted RHS is the operator-owned glob pattern (see shellcheck.rule.md).
        if [[ "${d}" == ${val} ]] || { [[ "${val}" != *'*'* ]] && [[ "${d}" == "${val}/"* ]]; }; then
            printf '%s\n' "${raw}"; return 0
        fi
    done < "${ALLOWLIST}"
    return 1
}

# report_still_blocked <dir>  -- after an enable, or over a project that already reads as listed, say so when something
# else still parks it. Informational: the entry IS what the operator asked for, and the remaining block is a line they
# wrote elsewhere and must edit themselves.
report_still_blocked() {
    local d="$1" raw
    raw="$(blocking_exclusion "${d}")" || return 0
    say ""
    warn "another exclusion still covers this path, so no session can start here:"
    say  "      ${C_BOLD}${raw}${C_RST}"
    say  "  ${C_DIM}it parks an ancestor or matches as a glob, so it is not this project's own entry;"
    say  "  edit that line in ${ALLOWLIST} to lift it.${C_RST}"
}

# allowlist_exclusions  -- print this registry's '!' exclusion entries, one per line without the '!', each read
# through the shared grammar (ai_tools_conf_path_entry), so a commented or quoted line denotes the same path here
# as in every other reader of the file. Feeds the read-only claim-time scans (acl_drift_scan, sealed_setgid_scan),
# which prune each carve-out from their walk. A missing registry yields an empty list.
allowlist_exclusions() {
    local line
    [[ -f "${ALLOWLIST}" ]] || return 0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        ai_tools_conf_path_entry "${line}" || continue
        if [[ "${_ai_tools_conf_value}" == '!'* ]]; then
            printf '%s\n' "${_ai_tools_conf_value#!}"
        fi
    done < "${ALLOWLIST}"
}

# covered_by_project <dir>  -- 0 when <dir> is at or under a positive allowed-projects entry in the invoking operator's
# own allowlist, honoring '!' exclusions (an exclusion wins). The CLI front-line for the per-project verbs (reclaim,
# lockdown): a path outside every claimed project is refused up front with a clear message, not a silent helper no-op.
# Scoped to the operator's own allowlist like every other CLI read; the root helpers re-check coverage (multi-operator)
# independently. Mirrors operator.lib's ai_tools_allowlist_covers.
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

# not_covered_die <dir>  -- the shared refusal for a per-project verb whose target no allowlist entry covers. It
# separates the two ways that happens, because the remedies share no step in common: a DISABLED project is registered
# and parked, so the fix is one command and the helpers would refuse it anyway (they resolve a path's owner
# through the same matcher, where an exclusion wins); anything else was never claimed. The old message said "not
# a claimed project" for both, which for a parked project is the one thing that is not true about it.
not_covered_die() {
    local d="$1"
    if [[ "$(allow_state "${d}")" == disabled ]]; then
        printf '\n' >&2
        disabled_note "${d}" >&2
        printf '\n' >&2
        die MSG-W3S4 "this project is disabled: ${d}" \
            "an exclusion line parks it, so no session runs there and the root helpers act on nothing." \
            "Re-enable it first:  ai-tools projects enable ${d}"
    fi
    die MSG-J3K5 "not a claimed project: ${d}" \
        "it is not at or under any project in your allowed-projects" \
        "       list your registered projects with: ai-tools projects"
}

# unclaim_one <dir> <group|""> <hint> <drop|park> [helper-flag...]  -- revert one claimed project. Order matters: revert
# the SELinux label first (keeps the invariant "labelled => allowlisted"), then run the filesystem hand-back WHILE
# THE ALLOWLIST ENTRY IS STILL PRESENT (ai-tools-unclaim refuses a target not in allowed-projects), and only then drop
# the two registries. <group> empty means "unregister only, leave permissions"; <hint> non-empty prints the manual
# hand-back command (used when the hand-back was wanted but could not run); the fourth argument is what becomes
# of the allowlist line (the <registry> disposition). Best-effort throughout: a step warns with its manual command
# and never aborts the pass.
unclaim_one() {
    local d="$1" group="$2" hint="$3" registry="$4"; shift 4
    local flags=""; (( $# )) && flags=" $*"
    local stopped=false handback_missing=false

    if command -v sudo >/dev/null 2>&1 \
            && command -v getenforce >/dev/null 2>&1 \
            && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
        if ! run_relabel "${d}" --remove; then
            warn "could not revert the SELinux label -- run it by hand:"
            say  "      ${C_BOLD}sudo ${RELABEL_BIN} --remove ${d}${C_RST}"
            note_root_failure || stopped=true
        fi
    fi

    # The filesystem hand-back is the step that revokes the agent's access to the FILES, so a failure here is the one
    # an operator must not be able to miss: everything else this function does is registry work, which stops the agent
    # launching here but leaves the tree group-owned by it. Recorded rather than merely warned about, and reported
    # in the close.
    if [[ -n "${group}" ]]; then
        if ${stopped}; then
            handback_missing=true
            warn "the files were NOT handed back -- run it by hand:"
            say  "      ${C_BOLD}sudo ${UNCLAIM_BIN} ${d} ${group}${flags}${C_RST}"
        elif run_unclaim "${d}" "${group}" "$@"; then
            ok "handed ${d} back to group ${group}, agent write access removed"
        else
            handback_missing=true
            warn "could not hand the files back -- run it by hand:"
            say  "      ${C_BOLD}sudo ${UNCLAIM_BIN} ${d} ${group}${flags}${C_RST}"
            note_root_failure || stopped=true
        fi
    elif [[ -n "${hint}" ]]; then
        handback_missing=true
        say  "      run it later with: ${C_BOLD}sudo ${UNCLAIM_BIN} ${d} <group>${flags}${C_RST}"
    fi

    # The registry drops run REGARDLESS of the hand-back decision, and that is the difference from a claim: dropping
    # them is what moves to LESS access -- the agent can no longer launch here -- so stopping short of them would be
    # the unsafe direction. Only the safe.directory removal, which is cleanup and needs its own authentication, is
    # skipped once the operator has said to stop; ai-tools projects reports the entry it leaves behind.
    ${stopped} || unreg_safedir "${d}" || note_root_failure || true
    # <registry> decides what happens to the allowlist line, never WHETHER it stops mattering: both dispositions end
    # with no session able to start here. `drop` deletes it; `park` prefixes it with '!' in place, keeping its position
    # and comment for an operator whose allowed-projects is an ordered, commented document and who unclaims
    # between development stages. Parking runs AFTER the hand-back for the same reason dropping does -- the helpers
    # resolve this path's owner through the allowlist, and an exclusion stops them as surely as a missing entry.
    if [[ "${registry}" == park ]]; then
        retag_allow "${d}" disable || warn "the allowlist entry could not be parked -- it is still active"
    else
        unreg_allow "${d}"
    fi

    # No bare ✓ over an unclaim whose hand-back did not run. A claim that under-applies leaves the agent with too little
    # access, which is merely inconvenient; an unclaim that under-applies leaves it with access the operator has just
    # been told was removed.
    if ${handback_missing}; then
        headline_warn "WARNING: deregistered, but the files were not handed back" \
            "${d} is out of allowed-projects, so no session can launch there. Its files still carry group ${SANDBOX_GROUP}, so an agent session that can reach the path keeps its access to them. The command above completes the reversal."
        ai_tools_log_structured warning \
            "unclaimed ${d} (registries dropped; filesystem hand-back did NOT run)" \
            "AI_TOOLS_PROJECT=${d}" "AI_TOOLS_RESULT=failed"
        return 1
    fi
    ok "unclaimed ${d}"
    ai_tools_log_structured info "unclaimed project ${d}" \
        "AI_TOOLS_PROJECT=${d}" "AI_TOOLS_RESULT=ok"
}

# undeletable_scan <dir>  -- print every directory under <dir> the ACTING OWNER can neither write nor traverse, one
# per line, capped. Read-only and run AS that owner, so it answers the question the removal depends on: rm -rf needs
# write+execute on a directory to unlink what is in it, and the realistic blocker is a sandbox-owned 0700 directory
# a session left behind.
#
# This is the pre-flight that keeps `projects remove` from having the one failure mode a destructive verb must not have:
# a tree deleted to the first directory the owner has no traverse on, with no registry entry left to find the remains
# by. Under-reporting is not the safe direction here -- unlike residue_scan, whose gate only decides what to OFFER --
# so the walk reports a directory it cannot descend rather than skipping it silently.
undeletable_scan() {
    local d="$1"
    run_as_owner find "${d}" -xdev -type d '(' -not -writable -o -not -executable ')' \
        -print 2>/dev/null | head -n 50
}

# residue_scan <dir>  -- fill RESIDUE and RESIDUE_SKIPPED with every path under <dir> that still carries ai-tools
# ownership or group: the on-disk fingerprint of a claim. RESIDUE holds what the default helper walk reaches,
# RESIDUE_SKIPPED what only --full does; .git counts as reachable because the helper reverts it in a dedicated pass
# regardless of the skip list. Read-only and unprivileged, so it is a PREVIEW: the helper re-derives the same predicate
# as root, where it also sees the ACL-only paths this scan cannot cheaply detect and the paths this operator cannot
# traverse. Under-reporting is the safe direction -- the gate it feeds only ever decides whether there is anything
# to offer, never what may be touched.
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
#                   the manual command instead of silently skipping the step.
# Globals, not stdout, precisely BECAUSE there are two: a `$(...)` capture runs the function in a subshell,
# where the second result is lost -- and reading it back under `set -u` aborts the whole unclaim before it touches
# anything. Prompts draw on /dev/tty and warnings on stderr, so a caller needs neither redirection nor a capture.
# --group answers both questions at once (whether to hand back, and to which group), so an automated run never depends
# on the prompt's no-terminal fallback quietly picking the invoking user's group. Without it the default-YES confirm
# and the user->group prompt run as before.
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
    # Default YES: the natural completion of an unclaim. Still confirmed, because it rewrites ownership and permissions
    # across the tree.
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

# cmd_unclaim_unlisted <dir> <force> <full> <dry> <assume-yes> <group-opt>  -- the UNRELATED branch: no allowlist entry
# covers <dir>. Detection guides; only --force acts, and even then the helper touches a path solely while it still
# carries the ai-tools fingerprint, so running this on a directory that was never claimed leaves every path as it found
# it. That per-path gate -- not any conservatism about which bits to write -- is what makes the mode safe on a mistyped
# path: what it DOES to a path it accepts is identical to a registered unclaim.
cmd_unclaim_unlisted() {
    local d="$1" force="$2" full="$3" dry="$4" assume_yes="$5" group_opt="$6"

    ai_tools_assert_safe_target "${d}" "project unclaim" || exit 3
    # A sandbox clone has its own lifecycle verb, which also removes the clone itself.
    if [[ "${d}" == "${SANDBOX_ROOT}/"* ]]; then
        die "that is a sandbox clone: ${d}" \
            "       remove it with: ai-tools projects remove ${d}"
    fi

    residue_scan "${d}"
    local n_res="${#RESIDUE[@]}" n_skip="${#RESIDUE_SKIPPED[@]}"
    if (( n_res == 0 && n_skip == 0 )); then
        die MSG-P8W2 "nothing to unclaim here: ${d}" \
            "       it is not a registered project, and nothing in it carries ai-tools ownership or group" \
            "       list your registered projects with: ai-tools projects"
    fi

    local extra=""
    (( n_skip )) && extra=", plus ${n_skip} more under skip-listed directories (--full reaches those)"

    # Detection GUIDES but never lowers the gate: the fingerprint improves the message, --force still authorizes,
    # and the confirm still executes.
    if [[ "${force}" != true ]]; then
        ai_tools_msg_notice \
            "ai-tools: not a registered project, but it carries ai-tools permissions:" \
            "${d}" \
            "${n_res} path(s) owned by or grouped to ${SANDBOX_USER}${extra}." \
            "This looks like a claimed project copied or moved here without unclaiming. To normalize its permissions without registering it, re-run with --force:"
        say ""
        say "   preview:  ${C_BOLD}ai-tools projects unclaim --force --dry-run ${d}${C_RST}"
        say "   apply:    ${C_BOLD}ai-tools projects unclaim --force ${d}${C_RST}"
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

    # Heavy trees: informational unless --full was asked for. With --full the operator has already recorded the intent
    # on the command line, so the confirm defaults YES -- an automated run carries through on that default while
    # an interactive one still sees and answers it.
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

    # The one decision `--force` does not make for you. `-y` pre-answers it, the same explicit per-invocation convention
    # as `projects claim` `-y`.
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
        ai_tools_log_structured info "unclaimed unregistered tree ${d} (group -> ${hb_group})" \
            "AI_TOOLS_PROJECT=${d}" "AI_TOOLS_RESULT=ok"
    else
        warn "could not normalize the tree -- run it by hand:"
        say  "      ${C_BOLD}sudo ${UNCLAIM_BIN} ${d} ${hb_group} ${helper_flags[*]}${C_RST}"
        exit 1
    fi
}

# cmd_project_unclaim [path] [--force] [--full] [--keep-entry] [--dry-run] [-y|--yes] [--group <group>]  -- undo
# an in-place claim (default: cwd): revert the SELinux label, drop both registries (or park the allowlist line
# under `--keep-entry`), and behind a default-yes confirm hand the tree back to a target group through ai-tools-unclaim,
# with the agent's write access revoked; the directory itself is left on disk. The target is classified
# against allowed-projects first (cli.rule.md, Unclaim), and a protected system path is refused up front, whatever
# the mode: the backstop reads the path alone, so `--force` does not relax it. A parked target is answered up front
# (offer_reenable). `-y`/`--yes` pre-answers the default-NO confirm in every mode and is not read by the hand-back
# or skip-listed questions, which ask on their own terms; `--group` names the hand-back group outright, so a script
# never depends on the prompt's no-tty fallback.
cmd_project_unclaim() {
    # `--force` swaps the allowlist gate for the helper's per-path residue gate (ai-tools-unclaim's header) and does not
    # relax any other gate.
    local a path="" force=false full=false dry=false assume_yes=false group_opt="" want_group=false
    local registry=drop
    for a in "$@"; do
        if ${want_group}; then group_opt="${a}"; want_group=false; continue; fi
        case "${a}" in
            --force)      force=true ;;
            --full)       full=true ;;
            --dry-run)    dry=true ;;
            -y|--yes)     assume_yes=true ;;
            --group)      want_group=true ;;
            --group=*)    group_opt="${a#--group=}" ;;
            --keep-entry) registry=park ;;
            -*) die_usage MSG-F7J9 "unknown projects unclaim option: ${a}" \
                    "       allowed: --force, --full, --keep-entry, --dry-run, -y/--yes, --group <group>" ;;
            *)  if [[ -z "${path}" ]]; then path="${a}"
                else die_usage MSG-C8P8 "projects unclaim takes a single path"; fi ;;
        esac
    done
    ${want_group} && die "--group needs a group name"
    if [[ -n "${group_opt}" ]] && ! getent group "${group_opt}" >/dev/null 2>&1; then
        die "no such group: ${group_opt}"
    fi
    if ${dry} && ${assume_yes}; then
        die_usage MSG-P4D2 "--yes has no effect with --dry-run, which neither changes a path nor asks"
    fi
    if ${dry} && ! ${force}; then
        die "--dry-run applies to --force only" \
            "       a registered project's unclaim previews itself: it lists what it will do and asks before acting"
    fi
    # --force reaches a tree the allowlist does not name, so there is no line to park. Refused rather than ignored:
    # the flag's whole purpose is what happens to an entry.
    if [[ "${registry}" == park ]] && ${force}; then
        die MSG-R3G9 "--keep-entry cannot be combined with --force" \
            "       --force unclaims a tree that has no allowed-projects entry, so there is nothing to keep"
    fi

    local d; d="$(resolve_dir "${path:-$PWD}")"
    [[ -d "${d}" ]] || die "not a directory: ${d}"

    # Classify d: exact entry, ancestor of entries, descendant of one, or unrelated. A DISABLED project counts
    # as an entry here (project_entries, not positive_project_entries): it is a project this operator registered
    # and then parked, and calling it "not a claimed project" sent them looking for a claim that was there all along.
    local -a entries=() targets=()
    local e
    while IFS= read -r e; do [[ -n "${e}" ]] && entries+=("${e}"); done \
        < <(project_entries)
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
            # Outermost first; each nested entry still takes its own registry and label drop.
            mapfile -t targets < <(printf '%s\n' "${targets[@]}" | sort)
        fi
    fi
    if [[ "${mode}" == unrelated ]]; then
        # Nearest claimed parent: the longest entry that is a prefix of d.
        for e in "${entries[@]:-}"; do
            if [[ "${d}" == "${e}/"* ]] && (( ${#e} > ${#nearest} )); then nearest="${e}"; fi
        done
        [[ -n "${nearest}" ]] && mode=descendant
    fi

    if [[ "${mode}" == descendant ]]; then
        die MSG-T5A3 "this path is inside a claimed project, not a project itself: ${d}" \
            "       the claimed project is: ${nearest}" \
            "       unclaim that instead: ai-tools projects unclaim ${nearest}"
    fi

    if [[ "${mode}" == unrelated ]]; then
        cmd_unclaim_unlisted "${d}" "${force}" "${full}" "${dry}" "${assume_yes}" "${group_opt}"
        return
    fi

    # Protected-path front line: never modify permissions on a protected system path. Guard each MODIFICATION target (in
    # ancestor mode the search root may be protected, e.g. /home, while the projects nested under it are not).
    local t
    for t in "${targets[@]}"; do
        ai_tools_assert_safe_target "${t}" "project unclaim" || exit 3
    done

    # --force is about reaching a tree the allowlist does not cover; here one does. Refused, like every other flag
    # that does not apply to the run it was given: a flag accepted and ignored hides the difference
    # between what the operator asked for and what ran, and ai-tools(1) states the refusal. The registered unclaim is
    # one word away.
    if ${force}; then
        die "--force does not apply here -- this path is covered by the allowlist: ${targets[0]}" \
            "       --force reaches a tree the allowlist does not name; unclaim a registered project without it:" \
            "       ai-tools projects unclaim ${targets[0]}"
    fi

    # A parked target is answered up front (offer_reenable), since under the exclusion the hand-back would exit 0
    # without handing back a path. Declining does not abort: the registry reversal still applies, and the hand-back
    # alone is given up and reported as not having run, with a non-zero exit (cli.rule.md).
    local -a handback_blocked=()
    local t
    for t in "${targets[@]}"; do
        [[ "$(allow_state "${t}")" == disabled ]] || continue
        offer_reenable "${t}" "the unclaim" decline-returns || handback_blocked+=("${t}")
    done

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

    # `--keep-entry` ends by PARKING each target's line, so it takes the same refusal `projects disable` does: a nested
    # project's parked line would be indistinguishable from a carve-out. Checked before any target is touched,
    # so the run refuses whole rather than unclaiming some and stopping.
    if [[ "${registry}" == park ]]; then
        for t in "${targets[@]}"; do
            refuse_nested_park "${t}" "--keep-entry"
        done
    fi

    # Filesystem hand-back: decided ONCE for the whole batch.
    local hb_group hb_hint
    resolve_handback_group "${group_opt}"
    hb_group="${HANDBACK_GROUP}"; hb_hint="${HANDBACK_HINT}"

    local -a helper_flags=()
    ${full} && helper_flags=(--full)

    local incomplete=0
    for t in "${targets[@]}"; do
        # A target whose exclusion was left standing takes the registry-only path: no group means unclaim_one skips
        # the hand-back, and the hint is what it prints in its place.
        local t_group="${hb_group}" t_hint="${hb_hint}" b
        for b in "${handback_blocked[@]:-}"; do
            [[ "${b}" == "${t}" ]] || continue
            t_group=""; t_hint="re-enable it (ai-tools projects enable ${t}), then: ai-tools projects handback --full ${t}"
            break
        done
        unclaim_one "${t}" "${t_group}" "${t_hint}" "${registry}" "${helper_flags[@]}" \
            || incomplete=$(( incomplete + 1 ))
    done

    # An incomplete reversal reaches the exit status, so a script sees it; the registries drop regardless, which is
    # why this reports rather than aborts.
    if (( incomplete )); then
        ai_tools_log_structured warning \
            "unclaim finished with ${incomplete} of ${#targets[@]} project(s) not fully reversed" \
            "AI_TOOLS_RESULT=failed"
    fi

    # Mixed tree: the registered projects are done, but ai-tools residue can still sit elsewhere under this path
    # (another copy, a leftover from a tree that was never registered). Reported only when --force asked about residue
    # in the first place, so the common path does not pay for a scan. The projects just unclaimed are no longer
    # registered, so a re-run now classifies the whole path as unrelated and the one command finishes the job.
    if ${force} && [[ "${mode}" == ancestor ]]; then
        residue_scan "${d}"
        local left=$(( ${#RESIDUE[@]} + ${#RESIDUE_SKIPPED[@]} ))
        if (( left )); then
            say ""
            ai_tools_msg_notice \
                "ai-tools: ${left} path(s) under this directory still carry ai-tools ownership or group, outside the projects just unclaimed." \
                "Re-run to normalize them now that nothing here is registered:"
            say ""
            say "   ${C_BOLD}ai-tools projects unclaim --force --dry-run ${d}${C_RST}"
        fi
    fi
    (( incomplete == 0 ))
}

# cmd_project_remove [path] [-y|--yes]  -- unclaim a project AND delete its directory (default: cwd); `projects unclaim`
# is the non-destructive reversal these refusals point at. One verb, two kinds: a path under SANDBOX_ROOT is a sandbox
# clone and takes remove_clone, every other path is a project claimed in place. Authorization is an EXACT registry
# entry, allow or parked, and the verb does not take `--force`; teardown is registries first, deletion last, so a failed
# deletion leaves an unregistered tree, and the filesystem hand-back is not run over files about to be deleted
# (cli.rule.md, Remove). `-y` pre-answers the default-NO confirm and the typed-name challenge of either kind, and needs
# a DIRECTORY for either.
cmd_project_remove() {
    local a path="" assume_yes=false
    for a in "$@"; do
        case "${a}" in
            -y|--yes) assume_yes=true ;;
            --force) die MSG-S6Q5 "projects remove has no --force: a registry entry is what authorizes a deletion here." \
                         "To reverse a claim on an unregistered tree, and then remove it yourself:" \
                         "       ai-tools projects unclaim --force ${path:-<path>}" ;;
            # Deliberately does not enumerate the options the way the other verbs' refusals do: the only one this verb
            # has pre-answers both the confirmation and the typed-name challenge, and a caller who has just mistyped
            # a flag is not who that is for.
            -*) die_usage MSG-M3Y5 "unknown projects remove option: ${a}" \
                    "       the options this verb takes are in: man ai-tools" ;;
            *)  if [[ -z "${path}" ]]; then path="${a}"
                else die_usage MSG-M2U9 "projects remove takes a single path"; fi ;;
        esac
    done
    # An unattended run must never delete whatever directory it happened to start in, so the one mode that can proceed
    # without a terminal has to name its target explicitly.
    if ${assume_yes} && [[ -z "${path}" ]]; then
        die MSG-K7D9 "projects remove -y needs a path." \
            "-y pre-answers the confirmation and the typed-name challenge, so an unattended run must say which project it means rather than inheriting the current directory."
    fi

    local d; d="$(resolve_dir "${path:-$PWD}")"
    [[ -d "${d}" ]] || die "not a directory: ${d}"
    if [[ "${d}" == "${SANDBOX_ROOT}/"* ]]; then
        remove_clone "${d}" "${assume_yes}"
        return
    fi
    ai_tools_assert_safe_target "${d}" "project remove" || exit 3

    # ── Classification: an EXACT entry, and only that, is a removal target; a parked entry (project_entries) authorizes
    # it as an active one does (cli.rule.md). ──
    local -a entries=() nested=()
    local e
    while IFS= read -r e; do [[ -n "${e}" ]] && entries+=("${e}"); done \
        < <(project_entries)
    local exact=false nearest=""
    for e in "${entries[@]:-}"; do
        [[ "${e}" == "${d}" ]] && exact=true
        [[ "${e}" == "${d}/"* ]] && nested+=("${e}")
        if [[ "${d}" == "${e}/"* ]] && (( ${#e} > ${#nearest} )); then nearest="${e}"; fi
    done

    if ! ${exact}; then
        if (( ${#nested[@]} )); then
            printf '\n' >&2
            printf '    %s\n' "${nested[@]}" >&2
            printf '\n' >&2
            die MSG-F4D8 "this is not a claimed project, but ${#nested[@]} claimed project(s) are nested under it: ${d}" \
                "projects remove deletes one registered project, never a directory that merely contains some. Reverse the claims first:" \
                "       ai-tools projects unclaim ${d}"
        fi
        if [[ -n "${nearest}" ]]; then
            die MSG-K5Y4 "this path is inside a claimed project, not a project itself: ${d}" \
                "       the claimed project is: ${nearest}" \
                "       remove that instead: ai-tools projects remove ${nearest}"
        fi
        die MSG-P8Y8 "not a claimed project: ${d}" \
            "projects remove deletes only a registered project -- the registry entry is what authorizes the deletion. See what is registered with: ai-tools projects" \
            "To reverse a claim on an unregistered tree, and then remove it yourself:" \
            "       ai-tools projects unclaim --force ${d}"
    fi

    # An entry containing other claimed projects is refused (cli.rule.md); the check sees the registry THIS run reads
    # alone, so another operator's nested project is not visible here.
    if (( ${#nested[@]} )); then
        printf '\n' >&2
        printf '    %s\n' "${nested[@]}" >&2
        printf '\n' >&2
        die MSG-Q3R9 "this project contains ${#nested[@]} other claimed project(s), listed above: ${d}" \
            "Deleting it would delete them too, leaving each one registered, git-trusted and SELinux-labelled at a path that no longer exists. Remove or unclaim those first, then re-run this."
    fi

    # ── Deletability pre-flight: read-only, run as the acting owner. ── The parent first: `rm -rf <d>` ends
    # by unlinking <d> from it, which the walk over the tree does not cover (cli.rule.md).
    local rm_parent="${d%/*}"; [[ -n "${rm_parent}" ]] || rm_parent=/
    if [[ -z "$(run_as_owner find "${rm_parent}" -maxdepth 0 -writable -executable 2>/dev/null)" ]]; then
        die MSG-H3F6 "the parent directory is not writable by ${OWNER_USER}: ${rm_parent}" \
            "Removing ${d} means unlinking it from that directory, and ${OWNER_USER} cannot write there. Nothing has been changed. To release the project and leave the files where they are, use:" \
            "       ai-tools projects unclaim ${d}"
    fi

    local -a undeletable=()
    mapfile -t undeletable < <(undeletable_scan "${d}")
    if (( ${#undeletable[@]} )); then
        headline_warn "WARNING: this tree cannot be fully deleted" \
            "${#undeletable[@]} director(ies) under ${d} cannot be written or entered by ${OWNER_USER}, so a removal would stop partway and leave the rest behind -- unregistered, and harder to find than it is now. Nothing has been changed."
        path_listing "director(ies)" "${undeletable[@]}"
        say ""
        say "  take ownership of the tree first, then re-run the removal:"
        say "      ${C_BOLD}ai-tools projects handback --full ${d}${C_RST}"
        die "project remove stopped -- the tree is not fully deletable by ${OWNER_USER}"
    fi

    # ── Git safety report: what deleting this loses. Reported, never refused -- a scratch repository with uncommitted
    # work is a legitimate thing to delete on purpose. ──
    if git -C "${d}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        local dirty upstream ahead
        dirty="$(git -C "${d}" status --porcelain 2>/dev/null | wc -l)"
        (( dirty )) && warn "${dirty} uncommitted change(s) in this repository"
        if upstream="$(git -C "${d}" rev-parse --abbrev-ref '@{u}' 2>/dev/null)"; then
            ahead="$(git -C "${d}" rev-list --count "${upstream}..HEAD" 2>/dev/null || echo 0)"
            (( ahead )) && warn "${ahead} commit(s) not pushed to ${upstream}"
        else
            warn "no upstream is configured -- every commit in this repository is local"
        fi
    fi

    # A parked project gets its own notice and its own default-NO confirm, BEFORE the deletion warning: the operator
    # parked this tree deliberately, so "you disabled this on purpose" is a different question from "this deletes
    # everything", and answering the second does not answer the first. No entry is re-enabled -- the removal does not
    # need a launch gate open, and the allowlist line goes with the tree.
    if [[ "$(allow_state "${d}")" == disabled ]]; then
        headline_warn "This project is disabled" \
            "An exclusion line in allowed-projects parks ${d}, so it was taken out of service rather than released. Removing it deletes the directory and both lines."
        disabled_note "${d}"
        say ""
        if ! ${assume_yes}; then
            confirm "Continue removing this disabled project?" n || die "aborted"
        fi
    fi

    # ── Confirmation: a default-NO confirm, then the typed name; this command's own `-y` is the one thing that answers
    # them ahead of time, and with no terminal each declines on its own (messaging.rule.md). ──
    headline_warn "WARNING: this deletes the project directory" \
        "${d} and everything in it is deleted. This is NOT reversible: there is no undo, and the tree is not moved to a trash location. To release the project and keep the files, use ai-tools projects unclaim instead."
    if ! ${assume_yes}; then
        confirm "Delete this project directory and everything in it?" n || die "aborted"
        ai_tools_msg_challenge "  Confirm the project to delete" "${d##*/}" \
            || die "aborted -- the name did not match"
    fi

    # ── Apply: registries first, deletion last. ──
    headline "Removing the project" "${d}"
    # A failed cleanup step asks once (note_root_failure) and does not stop the removal: the registries drop regardless,
    # and `ai-tools projects` reports what is left behind.
    local cleanup_stopped=false
    if command -v sudo >/dev/null 2>&1 \
            && command -v getenforce >/dev/null 2>&1 \
            && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
        if ! run_relabel "${d}" --remove; then
            warn "could not revert the SELinux label -- run it by hand:"
            say  "      ${C_BOLD}sudo ${RELABEL_BIN} --remove ${d}${C_RST}"
            note_root_failure || cleanup_stopped=true
        fi
    fi
    ${cleanup_stopped} || unreg_safedir "${d}" || note_root_failure || true
    unreg_allow "${d}"

    if ! run_as_owner rm -rf -- "${d}"; then
        warn "the deletion did not complete -- the project is already unregistered, so it is out of the agent's reach; remove what is left by hand:"
        say  "      ${C_BOLD}rm -rf ${d}${C_RST}"
        die "project remove incomplete -- paths were left behind"
    fi
    if [[ -e "${d}" ]]; then
        warn "paths were left behind under ${d} -- the project is already unregistered; remove them by hand:"
        say  "      ${C_BOLD}rm -rf ${d}${C_RST}"
        die "project remove incomplete -- paths were left behind"
    fi

    say ""
    ai_tools_log_structured info "removed project ${d}" \
        "AI_TOOLS_PROJECT=${d}" "AI_TOOLS_RESULT=ok"
    # The tree is gone either way, but a green ✓ is this project's report card and there is no reading of it that covers
    # "and two cleanup steps failed". So the check mark is reserved for a clean run, and a run with failures closes
    # by stating both facts and exits non-zero, which is also what lets a script tell the two apart.
    if (( ROOT_STEP_FAILURES )); then
        warn MSG-S6V2 "removed ${d}, but ${ROOT_STEP_FAILURES} cleanup step(s) did not run"
        say  "  Each is named above with the command that completes it. Registry entries left"
        say  "  behind now point at a path that no longer exists; this lists every entry that"
        say  "  needs attention, across all your projects:"
        say  ""
        say  "      ${C_BOLD}ai-tools projects${C_RST}"
        ai_tools_log_structured warning \
            "removed ${d} with ${ROOT_STEP_FAILURES} cleanup step(s) incomplete" \
            "AI_TOOLS_PROJECT=${d}" "AI_TOOLS_RESULT=failed"
    else
        ok "removed ${d}"
    fi
    [[ "${PWD}" == "${d}" || "${PWD}" == "${d}/"* ]] \
        && say "  ${C_DIM}your shell is still in the deleted directory -- cd somewhere else${C_RST}"
    (( ROOT_STEP_FAILURES == 0 ))
}

# sandbox_finalize <dst>  -- the access-granting tail of every sandbox create, run once the clone exists: allowlist
# entry (the lockdown scan acts only on an allowlisted path; rolled back on a failed gate), the secret gate, then --
# past the gate alone -- normalize (pruning the locked paths), relabel, and register. A declined or failed gate leaves
# the clone on disk, private and unregistered, with a guard CLAUDE.md and the resume command printed (fail closed:
# cli.rule.md, Sandbox clone). The normalize runs once, while the root is still owner-only (clone_is_private).
sandbox_finalize() {
    local dst="$1"
    reg_allow "${dst}"
    if ! secret_gate "${dst}"; then
        unreg_allow "${dst}"
        drop_lockdown_guard "${dst}"
        warn "sandbox not secured -- the clone stays private to you:" \
             "not group-accessible, not registered; the agent has no access to it"
        say  "    handle the secrets, then finish the create:"
        say  "      ${C_BOLD}ai-tools projects clone ${dst}${C_RST}"
        die "sandbox create stopped -- secrets not locked down"
    fi
    clear_lockdown_guard "${dst}"
    # A resume over a clone already opened leaves the tree as it is (normalize_clone's header states why).
    if clone_is_private "${dst}"; then
        normalize_clone "${dst}" "${SECRET_MATCH_PATHS[@]}"
        say "    access: group ${SANDBOX_GROUP} rwX + setgid dirs (locked secrets stay private)"
    else
        say "    access: already granted; the tree is left as it is"
    fi
    relabel_clone "${dst}"
    # A clone exists to run git in, and without safe.directory the agent's git refuses the tree ("dubious ownership"),
    # so the failure is reported at the close rather than left under the ✓; reg_safedir returns non-zero, so a bare call
    # under `set -e` would abort the create.
    local safedir_ok=true
    reg_safedir "${dst}" || safedir_ok=false
    say ""
    if ! ${safedir_ok}; then
        headline_warn "WARNING: the clone is not git-ready" \
            "${dst} is created, secured and registered, but git safe.directory could not be added, so the agent's git will refuse to operate in it. The command above adds the entry; nothing else about the clone needs redoing."
        ai_tools_log_structured warning \
            "sandbox ${dst} registered without a git safe.directory entry" \
            "AI_TOOLS_PROJECT=${dst}"
        return 1
    fi
    ok "sandbox ready: ${dst}"
    ai_tools_log_structured info "sandbox secured and registered: ${dst}" \
        "AI_TOOLS_PROJECT=${dst}" "AI_TOOLS_RESULT=ok"

    section "Next"
    # One line per enabled agent: the gate resolved the set before dispatch, so it is read, never re-resolved, here.
    local agent_launcher
    resolve_enabled_agents || true
    while IFS= read -r agent_launcher; do
        say "  run the agent  : ${C_BOLD}cd ${dst} && ${agent_launcher}${C_RST}"
    done < <(enabled_agent_launchers)
    say "  push its work  : ${C_BOLD}ai-tools projects push ${dst}${C_RST}"
    say "  ${C_YEL}shallow${C_RST}        : push-only -- never git pull/fetch here, or you pull the full history"
}

# sandbox_default_branch <from>  -- echo the DEFAULT sandbox branch name for a fork of <from>: "sandbox/<leaf>",
# where <leaf> is <from>'s last path component (so a fork of develop defaults to sandbox/develop, and origin/feature/x
# to sandbox/x). The literal "sandbox" carries NO host, machine, or operator identity by design -- the branch is pushed
# to a shared remote, so the default must leak no detail of who or where created it. It is only a DEFAULT: the operator
# overrides the whole name with --branch (or the prompt), and any valid git ref is accepted, so the sandbox workflow is
# not tied to this shape. Pure; unit-tested (tests/unit/sandbox.sh).
sandbox_default_branch() {
    printf 'sandbox/%s' "${1##*/}"
}

# sandbox_resolve_base <top> <remote> <base>  -- echo a ref naming <base>'s tip in the source repo, or return 1 if none
# does. Tries <base> as a local branch first, then the remote-tracking form <remote>/<base> (so a base that lives only
# on the remote -- e.g. master while you are on develop -- resolves without a local checkout), then any other commit-ish
# (a tag or SHA). This is what lets the sandbox branch be forked from a base OTHER than the current HEAD. Read-only (no
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

# cmd_project_clone [path] [--from <ref>] [--branch <name>] [--dir <name>] [-y|--yes]  -- create or reuse a sandbox
# branch, shallow-clone it PRIVATELY (umask 077) into SANDBOX_ROOT, then hand off to sandbox_finalize, which gates
# and opens it. Pointed at an EXISTING clone under SANDBOX_ROOT, it resumes sandbox_finalize on it (the flags are then
# not read). Every input has a default and an optional flag, so the command is scriptable and the prompts are
# the interactive fallback: a flag skips its prompt, and no flag with no tty takes the default. The branch is a FULL git
# ref of any shape -- the "sandbox/<leaf>" default is a convention (sandbox_default_branch) -- validated with git
# check-ref-format and refused rather than rewritten.
cmd_project_clone() {
    local o_path="" o_from="" o_branch="" o_dir="" o_yes=false
    local have_from=false have_branch=false have_dir=false
    # _need_value <flag> [remaining args...]: die unless a value follows the flag AND that value is not itself
    # option-shaped. A leading '-' is a mistyped flag far more often than a real ref or directory name, and taking it
    # at face value hands it to git as an option -- so the run would fail with git's own parse error, which names
    # neither this flag nor the value. Refused here, where the message can name both, and before the push.
    _need_value() {
        local flag="$1"; shift
        (( $# )) || die MSG-J4P9 "a value is required after ${flag}"
        [[ "$1" != -* ]] || die MSG-Z5V5 "a value is required after ${flag}, not another option: $1"
    }
    while (( $# )); do
        case "$1" in
            --from)   _need_value --from   "${@:2}"; o_from="$2";   have_from=true;   shift 2 ;;
            --branch) _need_value --branch "${@:2}"; o_branch="$2"; have_branch=true; shift 2 ;;
            --dir)    _need_value --dir    "${@:2}"; o_dir="$2";    have_dir=true;    shift 2 ;;
            -y|--yes) o_yes=true; shift ;;
            --)       shift ;;
            -*)       die_usage MSG-U8N3 "unknown projects clone option: $1 (see: ai-tools --help)" ;;
            *)        [[ -z "${o_path}" ]] || die_usage MSG-J3Q9 "projects clone takes a single path: unexpected extra argument $1"; o_path="$1"; shift ;;
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

    # Resolve every input BEFORE any push or checkout: a flag wins, else the prompt (interactive) or the default (no
    # tty). So an Enter-through reproduces the previous shape and a fully-flagged run does not need a terminal, while
    # a bad value stops here rather than after the push.

    # Base to fork from -- defaults to the current branch, but can be any base (e.g. main for a hotfix while you sit
    # on develop): a local branch, a <remote>/<base>, or any ref.
    local base
    if ${have_from}; then base="${o_from}"; else base="$(ask "Base branch to fork from" "${cur}")"; fi
    [[ -n "${base}" ]] || die "base branch cannot be empty"
    local base_ref
    base_ref="$(sandbox_resolve_base "${top}" "${remote}" "${base}")" \
        || die "base not found: ${base} (not a local branch, ${remote}/${base}, or a known ref)"

    # Sandbox branch -- a FULL git ref of any shape. Defaults to the convention sandbox/<leaf-of-base> but the operator
    # may enter anything (a flat name, a hotfix/x, or the old ai-tools/... form). Validated with git check-ref-format
    # and refused if invalid -- never silently rewritten.
    local br
    if ${have_branch}; then br="${o_branch}"
    else br="$(ask "Sandbox branch to create/track" "$(sandbox_default_branch "${base}")")"; fi
    [[ -n "${br}" ]] || die "sandbox branch cannot be empty"
    git check-ref-format "refs/heads/${br}" 2>/dev/null \
        || die "invalid branch name: ${br} (must be a valid git ref -- see git-check-ref-format(1))"

    local name
    if ${have_dir}; then name="${o_dir}"
    else name="$(ask "Sandbox directory name under ${SANDBOX_ROOT}" "$(basename "${top}")")"; fi
    # One component, and a real one: '.' and '..' pass the no-slash test but name the clone area itself or its parent,
    # where the next check would refuse them as "already exists" -- true, but not what went wrong.
    [[ -n "${name}" && "${name}" != */* && "${name}" != . && "${name}" != .. ]] \
        || die "invalid directory name: ${name} (one path component, under ${SANDBOX_ROOT})"
    local dst="${SANDBOX_ROOT}/${name}"
    if [[ -e "${dst}" ]]; then
        say "    to finish securing/registering an earlier clone of this name:"
        say "      ${C_BOLD}ai-tools projects clone ${dst}${C_RST}"
        die MSG-H2D4 "destination already exists: ${dst}"
    fi
    [[ -d "${SANDBOX_ROOT}" ]] || die "sandbox area missing: ${SANDBOX_ROOT} -- run install first"

    # git silently ignores --depth for a clone from a local path, which would copy the FULL history into the sandbox
    # and defeat the isolation. Force the file:// transport for local-path remotes so depth=1 is honored; network
    # remotes (ssh/https) honor it natively and keep their URL. Computed here (not after the confirm) so the preview
    # shows the exact clone command.
    local clone_url="${remote_url}"
    case "${remote_url}" in
        /*|./*|../*) clone_url="file://$(realpath -m "${remote_url}")" ;;
    esac

    # If the branch already exists on the remote (a prior sandbox of this repo), reuse it rather than force-pushing
    # over it -- this resumes earlier work and never discards commits. To reset it, delete the remote branch or pick
    # a new leaf.
    local br_exists=false
    [[ -n "$(git -C "${top}" ls-remote --heads "${remote}" "${br}" 2>/dev/null)" ]] \
        && br_exists=true

    # Preview the ACTUAL commands, verbatim on their own lines (a long clone line overflows the frame intact rather than
    # wrapping -- see messaging.rule.md / console-command-formatting).
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
    # `-y`/`--yes` pre-answers this create confirm only (an auditable per-invocation flag, as elsewhere); the secret
    # gate in sandbox_finalize still prompts on its own terms.
    ${o_yes} || confirm "Create the sandbox clone?" y || die "aborted"

    if ${br_exists}; then
        ok "reusing existing remote branch ${br}"
    else
        git -C "${top}" branch -f "${br}" "${base_ref}"
        git -C "${top}" push "${remote}" "${br}"
        ok "pushed ${br} to ${remote}"
    fi

    # umask 077: the clone is born OWNER-ONLY, so the tip commit's files -- possibly checked-in credentials -- are
    # unreadable to the sandbox account until the gate has run and normalize_clone opens the non-secret paths.
    ( umask 077 && git clone --depth=1 -b "${br}" "${clone_url}" "${dst}" )
    ok "shallow-cloned into ${dst} (private until secured)"
    ai_tools_log_structured info \
        "created sandbox clone ${dst} (branch ${br}, base ${base_ref}, remote ${remote})" \
        "AI_TOOLS_PROJECT=${dst}" "AI_TOOLS_RESULT=ok"

    sandbox_finalize "${dst}"
}

# cmd_project_push [path]  -- push the sandbox clone's commits ahead of its upstream branch, after listing them
# and confirming. No-op when already up to date. The verb does not take any option, so one is refused with the usage
# status rather than dropped: the push confirm defaults to yes and is taken without a terminal, so a `--dry-run` read
# as a path or silently discarded would push where the caller asked to look.
cmd_project_push() {
    local d="" a
    for a in "$@"; do
        case "${a}" in
            -*) die_usage MSG-C2U5 "unknown projects push option: ${a} (projects push takes no options)" ;;
            *)  if [[ -z "${d}" ]]; then d="${a}"; else die_usage MSG-K4R8 "projects push takes a single path"; fi ;;
        esac
    done
    d="$(resolve_dir "${d:-$PWD}")"
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
    ai_tools_log_structured info "pushed ${n} commit(s) from sandbox ${d} to ${up}" \
        "AI_TOOLS_PROJECT=${d}" "AI_TOOLS_RESULT=ok"
}

# remove_clone <dir> <assume-yes>  -- the clone kind of `projects remove`: delete a sandbox clone and unregister it,
# warning first about any unpushed commits. <assume-yes> true pre-answers the one default-NO confirm. The remote branch
# is left intact.
remove_clone() {
    local d="$1" assume_yes="$2"
    require_sandbox_clone "${d}"
    section "Remove sandbox project"
    say "  ${d}"

    local n; n="$(git -C "${d}" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    if [[ "${n}" != "0" ]]; then
        warn "${n} unpushed commit(s) will be lost (already-pushed work stays on the remote)"
        ${assume_yes} || confirm "Discard ${n} unpushed commit(s) and remove ${d}?" n || die "aborted"
    else
        ${assume_yes} || confirm "Remove ${d} and unregister it?" n || die "aborted"
    fi

    # As the owner: a clone claimed for another operator belongs to that operator, and the run's `--for` is what names
    # them.
    run_as_owner rm -rf -- "${d}"
    unreg_allow "${d}"
    # `|| true`: the clone is already gone, so a safe.directory entry that could not be removed is a stale line pointing
    # at a path that is gone -- reported by ai-tools projects, and not a reason to abort a removal that has already
    # happened. unreg_safedir signals failure now, and a bare call under set -e would do exactly that.
    unreg_safedir "${d}" || true
    ok "removed ${d} and unregistered it"
    ai_tools_log_structured info "removed sandbox ${d} and unregistered it" \
        "AI_TOOLS_PROJECT=${d}" "AI_TOOLS_RESULT=ok"
    say "  ${C_DIM}remote branch left intact -- others may still merge it${C_RST}"
}

# cmd_project_lockdown [path] [--dry-run] [-y]  -- run ai-tools-lockdown (via sudo) on the project to revoke ai-tools'
# read access to secret files; clears any guard CLAUDE.md on a real (non-dry-run) success. --dry-run and -y/--yes pass
# through to the helper.
cmd_project_lockdown() {
    local d="" a dry=false assume_yes=false; local -a passthru=()
    for a in "$@"; do
        case "${a}" in
            --dry-run)    passthru+=("${a}"); dry=true ;;
            -y|--yes)     passthru+=("${a}"); assume_yes=true ;;
            -*)           die_usage MSG-R3H8 "unknown projects lockdown option: ${a} (allowed: --dry-run, --yes)" ;;
            *)            if [[ -z "${d}" ]]; then d="${a}"; else die_usage MSG-Y6V3 "projects lockdown takes a single path"; fi ;;
        esac
    done
    # Refused here, before the helper's sudo.
    if ${dry} && ${assume_yes}; then
        die_usage MSG-P5P8 "--yes has no effect with --dry-run, which neither changes a path nor asks"
    fi
    d="$(resolve_dir "${d:-$PWD}")"
    [[ -d "${d}" ]] || die "not a directory: ${d}"
    covered_by_project "${d}" || not_covered_die "${d}"
    # No pre-check of the helper's path: the libexec directory is root-only (cli.rule.md), so a missing helper is
    # reported by sudo.
    section "Lock down project secrets"
    say "  ${d}"
    say "  ${C_DIM}secret-matching files -> 600, dirs -> 700, owner ${OWNER_USER}:${OWNER_GROUP}${C_RST}"
    local status=0
    run_lockdown "${d}" "${passthru[@]}" || status=$?
    case "${status}" in
        0)
            ${dry} || clear_lockdown_guard "${d}"
            ok "lockdown done: ${d}"
            ${dry} || ai_tools_log_structured info "locked down secrets in ${d}" \
                "AI_TOOLS_PROJECT=${d}" "AI_TOOLS_RESULT=ok"
            ;;
        6)  # the helper's decline: nothing changed, and the exit carries it (ai-tools(1))
            say "  declined -- no path was changed"
            exit 6 ;;
        *)  die "lockdown failed for ${d}" ;;
    esac
}

# ── Enable / disable a claimed project ───────────────────────────────────────────
# Each is a REGISTRY edit through conf.lib.sh's allowlist editing -- the tree keeps its group, its ACLs, its setgid bits
# and its SELinux label -- so neither runs the secret gate, and disable does not ask for confirmation, since it moves
# to less access. What parking costs downstream of the allowlist is offer_reenable's header and cli.rule.md's.

# no_entry_die <dir> <what>  -- the enable/disable pair's shared refusal. Neither verb invents an entry (registering
# a project is a claim, which scans for secrets first), so a path the file does not name is refused by both and pointed
# at the claim. One function rather than one per verb, so the situation carries one message code.
no_entry_die() {
    die MSG-T4A8 "not a claimed project: $1" \
        "there is no allowed-projects entry to $2. List what is registered with: ai-tools projects" \
        "To register it: ai-tools projects claim $1"
}

# cmd_project_disable [path]  -- park a claimed project: prefix its allowed-projects line with '!'.
cmd_project_disable() {
    local d="" a
    for a in "$@"; do
        case "${a}" in
            -*) die_usage MSG-K5W9 "unknown projects disable option: ${a} (it takes a path only)" ;;
            *)  if [[ -z "${d}" ]]; then d="${a}"; else die_usage MSG-W3C7 "projects disable takes a single path"; fi ;;
        esac
    done
    d="$(resolve_dir "${d:-$PWD}")"
    [[ -d "${d}" ]] || die "not a directory: ${d}"

    case "$(allow_state "${d}")" in
        disabled)
            section "Disable project"
            say "  ${d}"
            say "    allowed-projects: already disabled"
            disabled_note "${d}"
            return 0 ;;
        absent)
            no_entry_die "${d}" disable ;;
    esac

    refuse_nested_park "${d}" "projects disable"
    section "Disable project"
    say "  ${d}"
    retag_allow "${d}" disable || die "allowed-projects not updated -- ${d} is still enabled"
    ai_tools_log_structured info "project disabled: ${d} (owner ${OWNER_USER})" \
        "AI_TOOLS_PROJECT=${d}" "AI_TOOLS_RESULT=ok"
    say ""
    say "  ${C_DIM}no session can start here until it is re-enabled, and the ownership handback no"
    say "  longer restores files written under it. The files, their group, ACLs and label are"
    say "  unchanged.${C_RST}"
    say "  re-enable it with: ${C_BOLD}ai-tools projects enable ${d}${C_RST}"
}

# cmd_project_enable [path]  -- restore a parked project: delete the '!' from its line.
cmd_project_enable() {
    local d="" a
    for a in "$@"; do
        case "${a}" in
            -*) die_usage MSG-Q3K7 "unknown projects enable option: ${a} (it takes a path only)" ;;
            *)  if [[ -z "${d}" ]]; then d="${a}"; else die_usage MSG-T5S8 "projects enable takes a single path"; fi ;;
        esac
    done
    d="$(resolve_dir "${d:-$PWD}")"
    [[ -d "${d}" ]] || die "not a directory: ${d}"

    case "$(allow_state "${d}")" in
        listed)
            section "Enable project"
            say "  ${d}"
            say "    allowed-projects: already enabled"
            report_still_blocked "${d}"
            return 0 ;;
        absent)
            # Deliberately not an implicit claim: claiming runs a secret scan and grants the agent access to the tree,
            # which is a different decision from lifting a '!' the operator put there.
            no_entry_die "${d}" enable ;;
    esac

    refuse_carveout "${d}" "projects enable"
    section "Enable project"
    say "  ${d}"
    retag_allow "${d}" enable || die "allowed-projects not updated -- ${d} is still disabled"
    ai_tools_log_structured info "project enabled: ${d} (owner ${OWNER_USER})" \
        "AI_TOOLS_PROJECT=${d}" "AI_TOOLS_RESULT=ok"
    report_still_blocked "${d}"
    # A project parked long enough may have drifted out of a fully claimed state; the claim is idempotent and reports
    # what is missing, so point at it rather than re-deriving that here.
    say ""
    say "  ${C_DIM}sessions may start here again. If the project was parked across an upgrade or a"
    say "  permission change, re-run the claim to reconcile it:${C_RST}"
    say "  ${C_BOLD}ai-tools projects claim ${d}${C_RST}"
}

# cmd_project_handback [--full] [path]  -- hand agent-written files under the project (default: cwd) back
# to ${OWNER_USER}:${SANDBOX_GROUP} via ai-tools-reclaim (sudo). Reclaims the .git tree the per-session sweeps skip; run
# it before an ACL-unaware backup so ownership (not the per-project ACL) carries the operator's access into the copy.
# --full also reclaims the heavy trees the default run skips (node_modules, .venv, ...).
cmd_project_handback() {
    local d="" a full=false; local -a passthru=()
    for a in "$@"; do
        case "${a}" in
            --full) passthru+=("${a}"); full=true ;;
            -*)     die_usage MSG-U3R3 "unknown projects handback option: ${a} (allowed: --full)" ;;
            *)      if [[ -z "${d}" ]]; then d="${a}"; else die_usage MSG-D9C7 "projects handback takes a single path"; fi ;;
        esac
    done
    d="$(resolve_dir "${d:-$PWD}")"
    [[ -d "${d}" ]] || die "not a directory: ${d}"
    covered_by_project "${d}" || not_covered_die "${d}"
    section "Reclaim agent-written files"
    say "  ${d}${C_DIM}$(${full} && printf ' (--full: incl. node_modules, .venv, ...)')${C_RST}"
    say "  ${C_DIM}-> ${OWNER_USER}:${SANDBOX_GROUP} (secret-named files stay ${OWNER_USER}:${OWNER_GROUP} 600)${C_RST}"
    # The helper reports the outcome itself -- the pre-scan count, the one whole-set confirm, then the `handed back N` /
    # `nothing to reclaim` / `declined` line -- so no blanket success line here: the CLI states only what happened.
    run_reclaim "${d}" "${passthru[@]}" || die "reclaim failed for ${d}"
    ai_tools_log_structured info "reclaim run for ${d}$(${full} && printf ' (full)')" \
        "AI_TOOLS_PROJECT=${d}" "AI_TOOLS_RESULT=ok"
}

# cmd_audit -- report what has refused, been rejected, been stranded or been flagged since a given time. A thin
# pass-through to the root helper, which does the reading and the rendering: the trail is 700 root:root, so there is no
# use this unprivileged CLI could make of it first. The helper's EXIT STATUS is propagated deliberately -- non-zero
# means findings -- so `ai-tools audit` is usable from cron or a login banner without parsing its output, the same
# contract `status` already offers.
cmd_audit() {
    root_helper_reachable \
        || die "sudo not found -- cannot read the root-only trail; run as root: ${AUDIT_BIN}"
    run_root_helper "${AUDIT_BIN}" "$@"
}

# cmd_stop -- terminate every running agent session, through ai-tools-stop. Thin by design, and the thinness is
# the whole contract: the command accepts neither a target nor an authorization input, so this side has no decision left
# to make. What a stop reaches follows from membership of the sandbox account's cgroup slice, which only the root helper
# can read, and every remaining decision is a security decision that must not be made twice in two places. Option
# grammar is all that lives here. Why the command is shaped this way: stop.rule.md.
#
# The helper's EXIT STATUS propagates unchanged, so a caller reads one set of codes whichever side refused. They are
# listed in ai-tools(1) and are not restated here, so the two cannot drift.
#
# die_stop_usage -- refuse a `stop` command line in the HELPER's exit-code space (2 = usage), not the CLI's own (die
# exits 1). Because cmd_stop propagates the helper's status, 2 is what a caller reading `stop`'s exit code is told
# a usage error is (ai-tools(1)) -- and WHICH SIDE refused is an implementation detail of the ordering, not something
# the caller asked about. Exiting 1 here would report the same mistake as one code from the CLI and another
# from a direct root call, and 1 already means "a process survived SIGKILL". It splits a leading code off exactly
# as die() does, so a `stop` refusal carries one.
die_stop_usage() {
    local code=""
    if ai_tools_msg_is_code "${1-}"; then code="$1"; shift; fi
    ai_tools_log_coded error "${code}" "$*"
    ai_tools_msg_error ${code:+"${code}"} "ai-tools: $*"
    exit 2
}

cmd_stop() {
    local argument; local -a passthru=()
    for argument in "$@"; do
        case "${argument}" in
            # --all is accepted and inert; ai-tools(1) says why it exists at all.
            --all|--dry-run|-y|--yes|--force) passthru+=("${argument}") ;;
            -*) die_stop_usage MSG-B7K4 "unknown option for stop: ${argument}" \
                    "allowed: --all, --dry-run, --yes/-y, --force" ;;
            # A PATH IS REFUSED HERE, NOT PASSED ON. The helper refuses it too -- that is the last line, for a direct
            # root call -- but the refusal has to happen on this side as well, BEFORE the sudo: a command that is going
            # to be refused must not first prompt for a password (the ordering rule --for follows). Why refusing beats
            # ignoring is in the helper's refuse_positional_argument.
            #
            # THIS TEXT IS A DELIBERATE TWIN of that function's, and the duplication is unavoidable: the two run
            # in different processes and the helper is 750 root:root, so neither can source the other, while an operator
            # meets whichever side refused. The two must say the same thing and offer the same four commands -- change
            # one, change both.
            #
            # The commands are printed PLAIN, ahead of die(): die() joins its arguments and wraps them through the error
            # emitter, which would break a command across lines
            # (messaging.rule.md).
            *)  printf '\n' >&2
                printf '  %s\n' \
                    "Terminate every session:    ai-tools stop" \
                    "See what is running first:  ai-tools stop --dry-run" \
                    "End one session cleanly:    /exit inside it, which runs its session-end handback" \
                    "Terminate one by hand:      sudo systemctl --user -M ${SANDBOX_USER}@.host stop <unit>" >&2
                printf '\n' >&2
                die_stop_usage MSG-A3M9 "stop takes no path: ${argument}. It TERMINATES every agent session on this host -- killing the process tree, so no session-end handback runs -- and has no per-project form, because a session is attributed to a project by the sandbox account's own user manager -- the account being stopped -- so that attribution is reported, never trusted to decide what a stop reaches." ;;
        esac
    done
    root_helper_reachable \
        || die "sudo not found -- a session runs in the sandbox account's cgroups, which only root can signal" \
               "run as root: ${STOP_BIN}"
    run_root_helper "${STOP_BIN}" "${passthru[@]}"
}

# cmd_providers  -- report the installed providers of both kinds and, for each, whether a session gets it and why.
# Read-only: it resolves through providers.lib.sh, the same resolver ai-tools-run and the toolchain layer use,
# so what it reports is what a session gets rather than a second reading of operator.conf. The resolver's refusals --
# an untrusted manifest, an enabled-but-uninstalled name -- go to its stderr and are captured and shown here; at launch
# they reach only the terminal and journald.
cmd_providers() {
    [[ "$#" -eq 0 ]] || die_usage MSG-H2P7 "providers list takes no arguments"
    local providers_lib=/usr/local/lib/ai-tools/providers.lib.sh
    # shellcheck source=SCRIPTDIR/../lib/ai-tools/providers.lib.sh
    if ! source "${providers_lib}" 2>/dev/null \
            || ! declare -F ai_tools_enabled_agents >/dev/null 2>&1 \
            || ! declare -F ai_tools_provider_gate  >/dev/null 2>&1; then
        die "cannot load ${providers_lib} -- reinstall the ai-tools package"
    fi

    # The resolvers report every refusal on stderr; collect both kinds' into one file so they are shown together
    # at the end instead of interleaved with the listings.
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
    # agent_detail <name> -- an agent manifest's own description of itself. Empty for a manifest the trust predicate
    # refuses; that is the refusals block's story to tell.
    agent_detail() {
        local package launcher handback
        package="$( ai_tools_agent_manifest_field "$1" npm_package || true)"
        launcher="$(ai_tools_agent_manifest_field "$1" launcher    || true)"
        handback="$(ai_tools_agent_manifest_field "$1" handback    || true)"
        [[ -n "${package}" ]] || return 0
        printf '%s%s%s' "${package}" "${launcher:+, launcher ${launcher}}" \
            "${handback:+, handback ${handback}}"
    }
    # kind_block <label> <conf-key> <manifest-dir> <resolver> <detail-fn|-> -- one section per provider kind: the gating
    # decision, then every INSTALLED manifest marked enabled or disabled. Installed comes from the directory listing
    # and enabled from the resolver, so a manifest the resolver refuses shows as disabled with its reason
    # in the refusals block.
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

    # The enabled integration names, reused by the SELinux advisory. stderr is dropped here (the integrations kind_block
    # already captured any refusals into ${refusals}).
    local enabled_integrations
    enabled_integrations="$(ai_tools_enabled_integrations 2>/dev/null | cut -f1)"

    # SELinux policy groups -- reported only where the MAC layer is active (Enforcing/Permissive); a DAC-only
    # or SELinux-absent host skips the whole block. Read-only and unprivileged: getenforce and `semodule -l` read
    # without root (the same read the confinement preflight does as the sandbox account); if the store is not readable
    # unprivileged it degrades to a pointer rather than misreporting. The group set + predicates come from the shared
    # registry.
    selinux_groups_block() {
        local enforce; enforce="$(getenforce 2>/dev/null || true)"
        [[ -n "${enforce}" && "${enforce}" != "Disabled" ]] || return 0
        command -v semodule >/dev/null 2>&1 || return 0
        local groups_lib=/usr/local/lib/ai-tools/selinux-groups.lib.sh
        # shellcheck source=SCRIPTDIR/../lib/ai-tools/selinux-groups.lib.sh
        source "${groups_lib}" 2>/dev/null \
            && declare -F ai_tools_selinux_group_name >/dev/null 2>&1 || return 0

        # Read the loaded module list FIRST. If it is not readable unprivileged (common: the policy store is root-only
        # on many hosts), omit the whole section rather than print a section that only says "cannot read" --
        # the group/dependency reporting all needs this list, so without it there is no accurate report to show.
        # `sudo ai-tools-admin selinux groups` is where an operator inspects policy groups.
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
        say "    ${C_DIM}toggle with: sudo ai-tools-admin selinux groups enable <name>${C_RST}"

        # Each enabled integration declares the policy groups its toolchain needs under enforcing (selinux_groups in its
        # manifest, ai-tools-providers(5)); the ones not loaded are named here with the command that enables them, since
        # the failure they cause inside a session is an opaque EACCES. Stable groups take one ai-tools-admin command;
        # an experimental one is compiled from a source checkout, so it is named on its own line.
        [[ "${enforce}" == "Enforcing" ]] || return 0
        declare -F ai_tools_provider_manifest_field >/dev/null 2>&1 || return 0
        local integration declared missing_stable missing_experimental gname gdesc
        local -a declared_groups
        while IFS= read -r integration; do
            [[ -n "${integration}" ]] || continue
            declared="$(ai_tools_provider_manifest_field "${integration}" selinux_groups 2>/dev/null || true)"
            [[ -n "${declared}" ]] || continue
            declared_groups=()
            ai_tools_conf_list_value declared_groups "${declared}" 0 "selinux_groups in the ${integration} manifest"
            missing_stable=""; missing_experimental=""
            for gname in "${declared_groups[@]}"; do
                ai_tools_selinux_group_valid "${gname}" || continue
                group_loaded "${gname}" && continue
                if ai_tools_selinux_group_is_experimental "${gname}"; then
                    missing_experimental+="${missing_experimental:+ }${gname}"
                else
                    missing_stable+="${missing_stable:+ }${gname}"
                fi
            done
            [[ -n "${missing_stable}${missing_experimental}" ]] || continue
            say ""
            say "  ${C_YEL}${integration} is enabled but not every SELinux group it needs is loaded:${C_RST}"
            for gname in ${missing_stable} ${missing_experimental}; do
                for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
                    [[ "$(ai_tools_selinux_group_name "${entry}")" == "${gname}" ]] || continue
                    gdesc="$(ai_tools_selinux_group_desc "${entry}")"
                    say "    ${C_YEL}${gname}${C_RST} -- ${gdesc%%:*}"
                done
            done
            [[ -z "${missing_stable}" ]] \
                || say "  fix: sudo ai-tools-admin selinux groups enable ${missing_stable}"
            [[ -z "${missing_experimental}" ]] \
                || say "  and, from a source checkout (experimental): sudo selinux/install-selinux.sh enable-group ${missing_experimental}"
        done <<<"${enabled_integrations}"
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

# list_maintenance_note  -- the compact pointer to the existing per-project verbs, printed under the listing
# so `projects list` doubles as a reconciliation/maintenance view.
list_maintenance_note() {
    section "Maintenance"
    say "  ai-tools projects claim DIRECTORY             claim a project / finish claiming one"
    say "  ai-tools projects unclaim DIRECTORY           release a project (revoke agent access)"
    say "  ai-tools projects handback [--full] DIRECTORY  take back ownership; project stays claimed"
    say "  ai-tools projects lockdown DIRECTORY          lock down secret-named files"
}

# status_fmt_age <seconds>  -- render an age the way an operator reads it ("3 days ago"). The wording is single-sourced
# in services.lib.sh beside the age it formats, so this report and `ai-tools-admin status` cannot describe the same
# stamp two ways; this stays a local name because the report calls it on nearly every line. Fail-soft, like the rest
# of that library's use here: a missing lib drops the relative clause rather than the line.
status_fmt_age() {
    declare -F ai_tools_service_fmt_age >/dev/null 2>&1 || return 0
    ai_tools_service_fmt_age "${1:-}"
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

# cmd_status  -- report the host's ai-tools service health: provisioning state, then each managed systemd unit (OK /
# SKIPPED / STALE / DOWN / FAILED / n/a / ?) and, for anything not plainly healthy, its consequence and the exact
# commands that inspect and fix it. Reuses services.lib.sh -- the SAME registry the launch-time warning reads --
# so the status view and the launch warning never disagree. Informational (no operator gate), like
# `projects list`/`providers list`. The exit is the report state's (ai-tools-records(5)): 4 where a section read
# a fault, 5 where a section could not make a reading it promises (a library base ships did not load), and a `?`
# or `n/a` line -- a reading this vantage cannot make -- leaves it at 0. status_entrypoint_pins  -- report, per enabled
# agent, whether its entrypoint carries a verified checksum, and under it (status_entrypoint_label) what the last
# reconciliation could do about that agent's labels. The entrypoint itself lives in a 0750 toolchain the operator cannot
# read, so both lines report root-written records placed where they can. Without them the only signals are a warning
# in a journal the operator cannot reach and, eventually, a refused launch.
#
# The pin is written in the same KEY=value stamp grammar as the updater's last-run record, so it is read
# through the SAME accessors -- charset-clamped fields and one age implementation - rather than a second reader
# that could drift. Its path comes from entrypoint-verify.lib.sh, never hardcoded.
#
# Returns non-zero only when an unpinned entrypoint is actionable, which is exactly when the operator has required
# verification: everywhere else unpinned is a legitimate state (an air-gapped host, a release the vendor published no
# manifest for) and must not make a healthy host alarm, the same rule the unqueryable units follow. A pin this account
# has no read on is reported as unknown, which ai_tools_service_needs_attention does not count as a fault: `status`
# stays open to a non-operator, whom the state directory's mode keeps out. status_path_order -- where THIS shell finds
# each enabled agent's launcher. The one reading this report can make for free and no other vantage can make at all:
# the CLI runs in the operator's own login shell, so `command -v claude` resolves exactly what typing `claude` would
# run. A launcher resolving to a file other than the wrapper starts UNCONFINED, as the operator, so it counts toward
# the report's exit status and names the command that repairs it. What each state means is launch.rule.md's PATH
# ordering section; what this report says about each is cli.rule.md.
#
# Best-effort like the rest of this report: without the library or the provider resolver this vantage has no launcher
# to resolve, so the section is omitted rather than guessed at.
status_path_order() {
    local path_order_lib=/usr/local/lib/ai-tools/path-order.lib.sh
    local providers_lib=/usr/local/lib/ai-tools/providers.lib.sh
    # shellcheck source=SCRIPTDIR/../lib/ai-tools/providers.lib.sh
    source "${providers_lib}" 2>/dev/null || true
    # shellcheck source=SCRIPTDIR/../lib/ai-tools/path-order.lib.sh
    source "${path_order_lib}" 2>/dev/null || true
    declare -F ai_tools_path_order_read_here >/dev/null 2>&1 || return 0

    local state pair launcher winner seen=0
    ai_tools_path_order_read_here || true
    state="${AI_TOOLS_PATH_ORDER_STATE:-unknown}"
    for pair in "${AI_TOOLS_PATH_ORDER_WINNERS[@]+"${AI_TOOLS_PATH_ORDER_WINNERS[@]}"}"; do
        launcher="${pair%%=*}"; winner="${pair#*=}"
        (( seen++ == 0 )) && section "PATH ordering"
        case "${winner}" in
            # This host does not install a wrapper of that name, so its PATH has no ordering to get wrong here --
            # reported, and not a fault.
            '')  printf '  %-28s %sn/a (no wrapper installed)%s\n' "${launcher}" "${C_DIM}" "${C_RST}" ;;
            '?') printf '  %-28s %s? (this shell cannot resolve the name)%s\n' "${launcher}" "${C_DIM}" "${C_RST}" ;;
            "${AI_TOOLS_PATH_ORDER_WRAPPER_DIR}/${launcher}")
                 printf '  %-28s %sOK%s %s(%s -- the sandbox wrapper)%s\n' \
                     "${launcher}" "${C_GRN}" "${C_RST}" "${C_DIM}" "${winner}" "${C_RST}" ;;
            *)   printf '  %-28s %sUNCONFINED%s %s(%s)%s\n' \
                     "${launcher}" "${C_RED}" "${C_RST}" "${C_DIM}" "${winner}" "${C_RST}" ;;
        esac
    done
    (( seen )) || return 0

    case "${state}" in
        shadowed)
            say "      typing that name starts an agent OUTSIDE the sandbox: as you, with your"
            say "      credentials and home, and no allowlist, confinement or ownership handback"
            say "      ${C_BOLD}sudo ai-tools-admin operators add ${INVOKING_USER}${C_RST}"
            return 1 ;;
        # Reaching the wrapper without the ordering line is right today and right by accident: the next thing
        # that prepends to PATH takes it away silently. Dim rather than yellow, since this account's sessions are
        # sandboxed today: it does not alarm and does not count toward the exit status.
        clear)
            say "  ${C_DIM}the PATH ordering line is not in your shell init -- add it with:"
            say "  sudo ai-tools-admin operators add ${INVOKING_USER}${C_RST}" ;;
    esac
    return 0
}

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

    local agent pin version verified age kind seen=0 blocking=0 mislabelled=0 stale=0
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        # An agent whose package declares no release manifest has no published checksum to verify against. Root records
        # what is installed for it instead, so it is reported once that pin exists and left out while there is nothing
        # yet to report.
        pin="$(ai_tools_entrypoint_pin_path "${agent}" 2>/dev/null || true)"
        if [[ -z "$(ai_tools_agent_manifest_field "${agent}" release_manifest_url 2>/dev/null || true)" \
              && ! -e "${pin}" ]]; then
            continue
        fi
        (( seen++ == 0 )) && section "Entrypoint verification"
        version="$(ai_tools_service_stamp_field "${pin}" VERSION)"
        # Read BEFORE the pin's own fields, and reported in place of them. A reconciliation that refused to re-record
        # leaves the pin exactly as it was -- that staleness is what makes the next launch refuse -- so the pin still
        # carries a version and a date and would otherwise render as a fresh, successful verification beside the line
        # saying it no longer describes the installed binary.
        if status_entrypoint_stale "${agent}"; then
            stale=$(( stale + 1 ))
        elif [[ -n "${version}" ]]; then
            verified="$(ai_tools_service_stamp_age "${pin}" VERIFIED)"
            age="$(status_fmt_age "${verified}")"
            kind="$(ai_tools_entrypoint_pin_kind "${agent}" 2>/dev/null || true)"
            if [[ "${kind}" == observed ]]; then
                # The weaker tier states what the comparison proves -- the binary is the one root recorded -- and not
                # VERIFIED, which claims a vendor signature this agent's channel does not publish, nor any word
                # asserting the binary was sound when it was first recorded, which no pin can say. It is a pin, so it
                # satisfies the strictness switch and blocks no launch; what it does not carry is the origin.
                printf '  %-28s %sUNCHANGED%s %s(%s%s, as installed)%s\n' "${agent}" "${C_GRN}" "${C_RST}" \
                    "${C_DIM}" "${version}" "${age:+, ${age}}" "${C_RST}"
            else
                printf '  %-28s %sVERIFIED%s %s(%s%s)%s\n' "${agent}" "${C_GRN}" "${C_RST}" \
                    "${C_DIM}" "${version}" "${age:+, ${age}}" "${C_RST}"
            fi
        elif [[ -e "${pin}" && ! -r "${pin}" ]]; then
            # Not a fault: `status` stays open to a non-operator, whom the state directory's mode keeps out. It says
            # only that this vantage has no reading to give.
            printf '  %-28s %s? (pin not readable from this account)%s\n' "${agent}" "${C_DIM}" "${C_RST}"
        elif [[ -e "${pin}" ]]; then
            # Readable but carrying no VERSION the clamped reader will accept. Distinct from both other states
            # and from a missing pin, because the remedy is to rewrite it -- and it is never read as verified, since
            # the version check is what gates that line.
            printf '  %-28s %sunverified%s %s(pin present but unreadable)%s\n' \
                "${agent}" "${C_DIM}" "${C_RST}" "${C_DIM}" "${C_RST}"
            say "      ${C_BOLD}sudo ai-tools-admin system entrypoints relabel${C_RST} ${C_DIM}(rewrites the pin)${C_RST}"
        else
            blocking=$(( blocking + 1 ))
            if [[ "${strict}" == yes ]]; then
                printf '  %-28s %sUNVERIFIED%s\n' "${agent}" "${C_YEL}" "${C_RST}"
                say "      this host requires verification, so its sessions will not launch"
                say "      ${C_BOLD}sudo ai-tools-admin system entrypoints relabel${C_RST} ${C_DIM}(needs network -- it fetches the vendor's signed manifest)${C_RST}"
            else
                printf '  %-28s %sunverified%s %s(no pin -- launches are not blocked)%s\n' \
                    "${agent}" "${C_DIM}" "${C_RST}" "${C_DIM}" "${C_RST}"
            fi
        fi
        status_entrypoint_label "${agent}" || mislabelled=$(( mislabelled + 1 ))
    done < <(ai_tools_enabled_agents 2>/dev/null)

    [[ "${stale}" -gt 0 ]] && return 1
    [[ "${mislabelled}" -gt 0 ]] && return 1
    [[ "${strict}" == yes && "${blocking}" -gt 0 ]] && return 1
    return 0
}

# status_selinux_attestation [operator-conf] -- the per-domain mode of ai_tools_t and the Booleans that widen it, read
# through the launch shim's own reader and judged by its verdict (confinement.lib.sh), so this report and the launch
# cannot disagree; ai-tools-admin status renders the same reading. Returns 1 for a finding only
# where AI_TOOLS_REQUIRE_SELINUX makes it refuse every launch, STATUS_UNREADABLE when the library did not load, and 0
# otherwise. The section is omitted where SELinux is off or getenforce cannot say.
status_selinux_attestation() {
    local operator_conf="${1:-${AI_TOOLS_OPERATOR_CONF:-/etc/ai-tools/operator.conf}}"
    local IFS=$' \t\n'   # the refused spec splits on spaces; this CLI sets IFS to newline and tab
    local selinux_mode
    selinux_mode="$(getenforce 2>/dev/null || true)"
    [[ -n "${selinux_mode}" && "${selinux_mode}" != Disabled ]] || return 0
    section "SELinux attestation"
    # shellcheck source=SCRIPTDIR/../lib/ai-tools/confinement.lib.sh
    source "${CONFINEMENT_LIB}" 2>/dev/null || true
    if ! declare -F ai_tools_confinement_read_attestation_records >/dev/null 2>&1 \
            || ! declare -F ai_tools_confinement_classify_boolean_row >/dev/null 2>&1; then
        warn MSG-M9H2 "the confinement library ${CONFINEMENT_LIB} did not load its attestation readers -- reinstall the ai-tools package"
        return "${STATUS_UNREADABLE}"
    fi
    local selinux_required=no declaration_state declared_boolean_values required_boolean_values attestation_records
    local attestation_verdict declared_entry
    local -a declared_boolean_names=()
    ai_tools_confinement_is_selinux_required "${operator_conf}" && selinux_required=yes
    { read -r declaration_state; IFS= read -r required_boolean_values; IFS= read -r declared_boolean_values; } \
        < <(ai_tools_confinement_read_boolean_requirement "${operator_conf}")
    for declared_entry in ${declared_boolean_values}; do declared_boolean_names+=( "${declared_entry%%=*}" ); done
    attestation_records="$(ai_tools_confinement_read_attestation_records /sys/fs/selinux \
        "${declared_boolean_names[@]+"${declared_boolean_names[@]}"}")"
    local row_kind boolean_name boolean_state required_value requirement_origin opening_value boolean_grants
    local origin_note
    while IFS=$'\t' read -r row_kind boolean_name boolean_state required_value requirement_origin opening_value \
            boolean_grants; do
        if [[ "${row_kind}" == domain ]]; then
            case "${boolean_name}" in
                no)  printf '  %-28s %senforcing%s\n' "ai_tools_t" "${C_GRN}" "${C_RST}" ;;
                yes) printf '  %-28s %sPERMISSIVE%s %s(its denials are logged and not enforced)%s\n' \
                         "ai_tools_t" "${C_YEL}" "${C_RST}" "${C_DIM}" "${C_RST}"
                     say "      ${C_BOLD}sudo semanage permissive -d ai_tools_t${C_RST}" ;;
                *)   printf '  %-28s %s? (whether it is a permissive domain could not be read)%s\n' \
                         "ai_tools_t" "${C_DIM}" "${C_RST}" ;;
            esac
            continue
        fi
        origin_note=""
        [[ "${requirement_origin}" == operator.conf ]] && origin_note=", declared in operator.conf"
        [[ "${requirement_origin}" == built-in ]] && origin_note=", built in"
        case "$(ai_tools_confinement_classify_boolean_row "${boolean_state}" "${required_value}" "${opening_value}")" in
            matches) printf '  %-28s %s%s (required%s)%s\n' "${boolean_name}" "${C_DIM}" "${boolean_state}" \
                         "${origin_note}" "${C_RST}" ;;
            differs) printf '  %-28s %s%s%s %s(required %s%s -- opens %s)%s\n' "${boolean_name}" "${C_YEL}" \
                         "${boolean_state^^}" "${C_RST}" "${C_DIM}" "${required_value}" "${origin_note}" \
                         "${boolean_grants}" "${C_RST}"
                     say "      ${C_BOLD}sudo setsebool -P ${boolean_name}=${required_value}${C_RST}" ;;
            open)    printf '  %-28s %s %s(opens %s)%s\n' "${boolean_name}" "${boolean_state}" "${C_DIM}" \
                         "${boolean_grants}" "${C_RST}" ;;
            closed)  printf '  %-28s %s%s%s\n' "${boolean_name}" "${C_DIM}" "${boolean_state}" "${C_RST}" ;;
            malformed) printf '  %-28s %sMALFORMED%s %s(%s has %s)%s\n' "${boolean_name}" "${C_YEL}" "${C_RST}" \
                           "${C_DIM}" "${operator_conf}" "${boolean_grants}" "${C_RST}"
                       say "      every launch refuses until it is fixed" ;;
            *)       printf '  %-28s %s? (could not be read)%s\n' "${boolean_name}" "${C_DIM}" "${C_RST}" ;;
        esac
    done < <(ai_tools_confinement_list_attestation_rows "${required_boolean_values}" "${declared_boolean_values}" \
                 <<< "${attestation_records}")
    attestation_verdict="$(ai_tools_confinement_parse_attestation_records <<< "${attestation_records}" \
        | { IFS='|' read -r domain_permissive current_boolean_values
            ai_tools_confinement_attestation_verdict "${domain_permissive}" "${current_boolean_values}" \
                "${required_boolean_values}"; })" || true
    [[ "${attestation_verdict}" == ok ]] && return 0
    if [[ "${selinux_required}" == yes ]]; then
        say "  AI_TOOLS_REQUIRE_SELINUX is set, so every launch refuses while this stands"
        return 1
    fi
    say "  ${C_DIM}AI_TOOLS_REQUIRE_SELINUX is not set, so launches are not refused for this${C_RST}"
    return 0
}

# status_entrypoint_stale <agent>  -- report, and return 0, when the last reconciliation REFUSED to re-record this
# agent's pin: the entrypoint changed in a way no update explains, so the pin was deliberately left standing
# and the next launch refuses. Returns non-zero when there is no such mark, which is the ordinary state.
#
# This is the one line in the section that reports a REFUSAL: the pin a refusal leaves behind is a valid record
# of a verification that once succeeded, so without the mark each status report renders it green while every status
# reports render it green while every launch of that agent is already refused. The remedy is the reconcile command,
# which re-reads the installed binary -- and the commands that replace it are the relabel helper's to print, since only
# root can name the package directory.
status_entrypoint_stale() {
    local agent="$1" record state version reason detected age
    declare -F ai_tools_entrypoint_stale_path >/dev/null 2>&1 || return 1
    record="$(ai_tools_entrypoint_stale_path "${agent}" 2>/dev/null || true)"
    [[ -n "${record}" && -r "${record}" ]] || return 1
    state="$(ai_tools_service_stamp_field "${record}" STATE)"
    [[ "${state}" == stale ]] || return 1
    version="$(ai_tools_service_stamp_field "${record}" VERSION)"
    reason="$(ai_tools_service_stamp_field "${record}" REASON)"
    detected="$(ai_tools_service_stamp_age "${record}" DETECTED)"
    age="$(status_fmt_age "${detected}")"
    printf '  %-28s %sPIN STALE%s %s(%s%s)%s\n' "${agent}" "${C_RED}" "${C_RST}" \
        "${C_DIM}" "${reason:-refused}" "${age:+, ${age}}" "${C_RST}"
    say "      the pinned binary${version:+ (${version})} is not the one installed, so this agent's sessions refuse to start"
    say "      ${C_BOLD}sudo ai-tools-admin system entrypoints relabel${C_RST} ${C_DIM}(re-reads the entrypoint and prints how to replace it)${C_RST}"
    return 0
}

# status_entrypoint_label <agent>  -- report what the last reconciliation could do about that agent's SELinux labels,
# under its verification line. The two halves of one reconciliation are reported together because they are asked
# from the same vantage and fail independently: on a host whose relabel could not register its file-context rules,
# the pin line alone reads as a fresh green all-clear for the half that did work.
#
# The label itself stays unreadable from here -- the entrypoint lives in a 0750 toolchain this account cannot traverse,
# and matchpathcon computes only what a label SHOULD be -- so this reports the root-written record instead,
# through the same stamp accessors as the pin. It reports an EVENT: what the last run could do, and when -- not
# the label the entrypoint carries now, which the record does not hold: a refused rule ends the run before its verify
# pass, and the launch reads the live type rather than this record. So the failure line names `ai-tools-admin status`,
# which reads the labels as root, and the service start that re-runs the work and clears the unit's own recorded failure
# with it.
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
        # One reason is read rather than only printed: `incomplete-package` (written by ai-tools-relabel-agent) says
        # the executable the manifest declares is not installed, which no relabel can supply -- so naming the relabel
        # as the retry would send the operator around the loop this report exists to end. The package is what has to be
        # reinstalled, and the provisioning command is what does it.
        failed)  printf '  %-28s %sNOT LABELLED%s %s(%s%s)%s\n' "" "${C_RED}" "${C_RST}" \
                     "${C_DIM}" "${age:-at an unknown time}" "${reason:+, ${reason}}" "${C_RST}"
                 if [[ "${reason}" == incomplete-package ]]; then
                     say "      this agent's package does not hold the executable its manifest declares, so there is"
                     say "      nothing to label and no session of it starts; reinstall the package:"
                     say "      ${C_BOLD}sudo ai-tools-admin system bootstrap${C_RST} ${C_DIM}(its output names an install that did not complete)${C_RST}"
                 else
                     say "      the last reconciliation could not apply this agent's labels; the label its"
                     say "      entrypoint carries now is read by: ${C_BOLD}sudo ai-tools-admin status${C_RST}"
                     say "      retry: ${C_BOLD}sudo systemctl start ai-tools-relabel.service${C_RST} ${C_DIM}(then: journalctl -t ai-tools-relabel-agent)${C_RST}"
                 fi
                 return 1 ;;
        # Nothing to label -- a DAC-only host, or an agent the toolchain has not provisioned yet. Neither is a fault,
        # so neither is coloured or counted.
        skipped) printf '  %-28s %snot labelled (%s)%s\n' "" "${C_DIM}" \
                     "${reason:-nothing to label}" "${C_RST}" ;;
        # No record at all: this host has not run a reconciliation since the record was introduced, or the state
        # directory is unreadable from this account. It says only that, and never counts against the exit status --
        # the same rule the unqueryable units follow.
        *)       printf '  %-28s %s? (no labelling recorded -- run: sudo ai-tools-admin system entrypoints relabel)%s\n' \
                     "" "${C_DIM}" "${C_RST}" ;;
    esac
    return 0
}

# status_provisioning -- the Provisioning section: one line per enabled agent, provisioned or not, keyed on the same
# launcher symlink the bootstrap gate reads (bootstrap's last artifact per agent), so the gate's refusal and this report
# cannot disagree about which agent lacks its link. An unprovisioned agent and an empty enabled set are reported and not
# counted: an unfinished install is what this section exists to say, not a fault in a finished one. Returns non-zero
# when the enabled agents cannot be read at all, which is a broken install, like a missing service registry,
# and when an installed agent that is not enabled still has its link (status_residue), the state every launch is refused
# in.
status_provisioning() {
    local rec agent_name launcher reason faults=0 unreadable
    section "Provisioning"
    # The resolver not loading is a broken install, a reading this section could not make: STATUS_UNREADABLE,
    # so the report exits 5 rather than counting it among the faults it did read.
    if ! resolve_enabled_agents; then
        say "  ${C_YEL}cannot read the enabled agents${C_RST} -- ${ENABLED_AGENTS_ERROR}"
        return "${STATUS_UNREADABLE}"
    fi
    if (( ${#ENABLED_AGENTS[@]} == 0 )); then
        IFS=$'\t' read -r _ reason <<<"$(ai_tools_agents_empty_verdict)"
        say "  ${C_YEL}no agent enabled${C_RST} -- ${reason}"
    fi
    for rec in "${ENABLED_AGENTS[@]+"${ENABLED_AGENTS[@]}"}"; do
        IFS=$'\t' read -r agent_name _ launcher <<<"${rec}"
        if agent_provisioned "${launcher}"; then
            ok "${agent_name} provisioned (${launcher})"
        else
            say "  ${C_YEL}${agent_name} not provisioned${C_RST} -- run: ${C_BOLD}sudo ai-tools-admin system bootstrap${C_RST}"
        fi
        status_managed_files "${agent_name}" || faults=$(( faults + 1 ))
    done
    status_residue || {
        unreadable=$?
        if (( unreadable == STATUS_UNREADABLE )); then return "${STATUS_UNREADABLE}"; fi
        faults=$(( faults + 1 ))
    }
    (( faults == 0 ))
}

# status_residue -- one line per agent this host installed, did not enable, and still holds the stable launcher link
# of: the operator-side read of a package left in the sandbox toolchain (ai_tools_agent_residue_links,
# toolchain.lib.sh), which the launch wrapper refuses every launch on from the same link and the shim from the tree.
# Counted, since the host is in the state where no session starts, and the line names the run that clears it. Returns 1
# for a residue line, and STATUS_UNREADABLE for a library that will not load: the report then has no reading of whether
# a launch is refused, which is a broken install like a missing registry.
status_residue() {
    local agent launcher rc=0
    if ! toolchain_lib_loaded; then
        say "  ${C_YEL}cannot check the toolchain for a disabled agent's package${C_RST} -- cannot load ${TOOLCHAIN_LIB}; reinstall the ai-tools package"
        return "${STATUS_UNREADABLE}"
    fi
    while IFS=$'\t' read -r agent launcher; do
        [[ -n "${agent}" ]] || continue
        say "  ${C_RED}${agent} is installed but not enabled, and its package is still in the toolchain${C_RST} (${LAUNCHER_DIR}/${launcher})"
        say "      every launch is refused until it is removed -- run: ${C_BOLD}sudo ai-tools-admin system bootstrap${C_RST}"
        rc=1
    done < <(ai_tools_agent_residue_links "${LAUNCHER_DIR}" 2>/dev/null)
    return "${rc}"
}

# toolchain_lib_loaded -- source toolchain.lib.sh and succeed once its readers are defined. The library is
# include-guarded, so each section that reads it calls this and the second call is a no-op; it requires providers.lib.sh
# and returns non-zero WITHOUT defining a reader when that is missing, so the probe is on the readers rather than
# on the source's own status.
toolchain_lib_loaded() {
    # shellcheck source=SCRIPTDIR/../lib/ai-tools/toolchain.lib.sh
    source "${TOOLCHAIN_LIB}" 2>/dev/null || true
    declare -F ai_tools_agent_residue_links >/dev/null 2>&1 \
        && declare -F ai_tools_agent_link_node_versions >/dev/null 2>&1 \
        && declare -F ai_tools_node_version_verdict >/dev/null 2>&1
}

# status_node_version -- the Version section's Node line. The active version is read from the enabled agents' stable
# launcher links (ai_tools_agent_link_node_versions): every path that changes Node repoints them, so the line is right
# after a bootstrap as much as after an update, and the read is unprivileged -- one readlink hop, the read the launch
# wrapper makes. The updater's stamp records the version its last run left active and is shown only where it differs,
# the one fact the link cannot carry: the toolchain changed after the updater last ran. Which case applies is
# ai_tools_node_version_verdict's, so this and ai-tools-admin cannot disagree; a host with neither a link nor a stamp
# gets no Node line, and Provisioning says why. Never counted: no case here is a fault.
status_node_version() {
    local rec stamp_node="" verdict kind version stamp_seen
    if declare -F ai_tools_service_stamp_field >/dev/null 2>&1; then
        while IFS= read -r rec; do
            stamp_node="$(ai_tools_service_stamp_field "$(ai_tools_service_field "${rec}" 7)" NODE)"
            [[ -n "${stamp_node}" && "${stamp_node}" != unknown ]] && break
            stamp_node=""
        done < <(ai_tools_service_records)
    fi
    if toolchain_lib_loaded; then
        verdict="$(ai_tools_agent_link_node_versions "${LAUNCHER_DIR}" 2>/dev/null \
                       | ai_tools_node_version_verdict "${stamp_node}")"
    elif [[ -n "${stamp_node}" ]]; then
        verdict=$'stamp\t'"${stamp_node}"     # no link reader: the stamp is the only reading left
    else
        verdict=none
    fi
    IFS=$'\t' read -r kind version stamp_seen <<<"${verdict}"
    case "${kind}" in
        active) if [[ -n "${stamp_seen}" ]]; then
                    say "  node ${version} ${C_DIM}(active; the last update run saw ${stamp_seen})${C_RST}"
                else
                    say "  node ${version}"
                fi ;;
        split)  say "  node ${C_YEL}${version}${C_RST} ${C_DIM}(the enabled agents' launchers name different Node versions -- an update may be in progress)${C_RST}" ;;
        stamp)  say "  node ${version} ${C_DIM}(as of the last toolchain update -- no launcher link names one)${C_RST}" ;;
    esac
    return 0
}

# status_managed_files <agent> -- one line per managed file the agent's manifest names (managed_files,
# ai-tools-providers(5)) whose live copy is not the shipped one. The package never overwrites such a file, so the report
# is where an operator learns the live file differs: the agent reads it alone, a key this release adds is not in it,
# and what it declares is the host's rather than the package's. A file matching the shipped copy is not reported,
# and an edited one is not counted -- it is a supported state -- while a missing one is, since the package is then
# broken and a reinstall is the remedy. Returns non-zero for a missing file.
status_managed_files() {
    local agent="$1" live reference state rc=0
    declare -F ai_tools_agent_managed_files >/dev/null 2>&1 || return 0
    while IFS=$'\t' read -r live reference; do
        [[ -n "${live}" ]] || continue
        state="$(ai_tools_managed_file_state "${live}" "${reference}")"
        case "${state}" in
            shipped) ;;
            edited)  say "  ${C_YEL}${agent}: ${live} differs from the shipped copy${C_RST}"
                     say "      ${agent} reads the live file alone: a key this release adds is not in it, and what it declares is the host's"
                     say "      shipped copy: ${reference}" ;;
            missing) say "  ${C_RED}${agent}: ${live} is missing${C_RST} -- reinstall the ${agent} package"
                     rc=1 ;;
            *)       say "  ${C_DIM}${agent}: ${live} -- cannot compare with the shipped copy ${reference}${C_RST}" ;;
        esac
    done < <(ai_tools_agent_managed_files "${agent}")
    return "${rc}"
}

# A section reports a reading it could not make by returning this, apart from 1, which is a fault it read. cmd_status
# folds the first as `unreadable` and the second as `attention`, so the sections stay free of the records library
# and drivable on their own.
readonly STATUS_UNREADABLE=2

# status_fold <section status> -- fold one section's return into the report state: STATUS_UNREADABLE as `unreadable`,
# any other non-zero as `attention`. Called as `section || status_fold $?`, where `$?` is the section's status.
status_fold() {
    if (( $1 == STATUS_UNREADABLE )); then
        ai_tools_records_accumulate_severity unreadable
    else
        ai_tools_records_accumulate_severity attention
    fi
}

cmd_status() {
    # A report does not take any argument; one given is refused with the usage status rather than ignored, so a caller
    # reading the exit code from cron learns the command line is wrong instead of reading a report it did not ask for.
    [[ "$#" -eq 0 ]] || die_usage MSG-X9Z9 "status takes no arguments"
    # shellcheck source=SCRIPTDIR/../lib/ai-tools/records-base.lib.sh
    if ! source "${RECORDS_BASE_LIB}" 2>/dev/null \
            || ! declare -F ai_tools_records_get_exit_status >/dev/null 2>&1; then
        die MSG-B9A2 "cannot load ${RECORDS_BASE_LIB}, which states this report's exit codes -- reinstall the ai-tools package"
    fi
    ai_tools_records_begin_report

    section "Version"
    say "  ai-tools ${AI_TOOLS_VERSION}"
    # The agent version lives in the sandbox toolchain the operator cannot read, so it stays a pointer. Node does not
    # have to: its version is in the launcher link's target (status_node_version).
    status_node_version
    # One pointer per enabled agent whose wrapper this host installs (an agent without one is the PATH ordering
    # section's to report). Through ai_tools_cmd_display, so the command printed here is the one that reaches
    # the sandbox: it renders the bare name only while this shell resolves it to the wrapper, and the absolute path
    # otherwise. On a shadowed account the bare name resolves to the binary the PATH ordering section reports, so this
    # line prints the wrapper's own path instead of sending them there.
    local rec agent_name launcher agents_read=1
    resolve_enabled_agents || agents_read=0
    if (( agents_read )); then
        for rec in "${ENABLED_AGENTS[@]+"${ENABLED_AGENTS[@]}"}"; do
            IFS=$'\t' read -r agent_name _ launcher <<<"${rec}"
            [[ -x "/usr/local/bin/${launcher}" ]] || continue
            say "  ${C_DIM}${agent_name} version: run '$(ai_tools_cmd_display "/usr/local/bin/${launcher}") --version'${C_RST}"
        done
    fi

    status_provisioning || status_fold $?

    section "Services"
    # A missing registry is a broken install, not an unknowable state: a reading this report could not make, which exits
    # 5, since a clean bill would have no reading behind it. The sections after it are still read, so the page carries
    # every reading that could be made beside the one that could not.
    if ! declare -F ai_tools_service_records >/dev/null 2>&1 \
            || ! declare -F ai_tools_service_state_of >/dev/null 2>&1 \
            || ! declare -F ai_tools_service_stamp_field >/dev/null 2>&1; then
        warn MSG-X5Z8 "service registry unavailable (${SERVICES_LIB}) -- cannot report service health; reinstall the ai-tools package"
        ai_tools_records_accumulate_severity unreadable
    else
        status_services
    fi

    status_path_order      || status_fold $?
    status_entrypoint_pins || status_fold $?
    status_selinux_attestation "${AI_TOOLS_OPERATOR_CONF:-/etc/ai-tools/operator.conf}" || status_fold $?

    # Pointers, not duplication: name the sibling read-only reports (which own their own detail) and where the full
    # command list lives, so `status` is a hub without re-implementing `providers list` or
    # `--help`.
    section "More"
    say "  ai-tools providers   installed agents/integrations and which are enabled"
    say "  ai-tools projects    registered projects (in place and sandbox clones)"
    say "  ai-tools --help      the full command list"

    # The exit is the report state's (ai-tools-records(5), EXIT STATUS): 4 when something is broken, 5 when a reading
    # could not be made, so `status` is usable unattended (a cron check, a monitor) without parsing this output.
    # 'unknown' and 'n/a' are not faults and do not count -- an unqueryable unit must not make a healthy host alarm
    # every night.
    ai_tools_records_get_exit_status || return $?
    return 0
}

# status_services -- each unit the registry names, with its consequence and remedy where one needs attention. Runs
# in the report's own shell so its fold reaches the report state; requires the registry readers cmd_status checked.
status_services() {
    local rec unit scope stamp mode state age when exit_code reason remedy
    while IFS= read -r rec; do
        unit="$(ai_tools_service_field "${rec}" 1)"
        scope="$(ai_tools_service_field "${rec}" 2)"
        stamp="$(ai_tools_service_field "${rec}" 7)"
        mode="$(ai_tools_service_field "${rec}" 8)"
        state="$(ai_tools_service_state_of "${rec}")"
        # A stamped unit is reported from its LAST RUN, not live, so every line says WHEN -- relative first, since "3
        # days ago" is the part an operator acts on. An unknown age omits the relative form rather than a placeholder.
        age=""; when=""
        if [[ -n "${stamp}" ]]; then
            age="$(status_fmt_age "$(ai_tools_service_stamp_age "${stamp}")")"
            [[ -n "${age}" ]] && when=" ${C_DIM}(last run ${age})${C_RST}"
        fi
        case "${state}" in
            # In 'fired' mode the stamp belongs to another unit; this one is only inferred from the fact that a run
            # happened at all, so the line says so rather than claiming a live check.
            active) if [[ "${mode}" == fired && -n "${age}" ]]; then
                        printf '  %-28s %sOK%s %s(inferred -- a run completed %s)%s\n' \
                            "${unit}" "${C_GRN}" "${C_RST}" "${C_DIM}" "${age}" "${C_RST}"
                    else
                        printf '  %-28s %sOK%s%s\n' "${unit}" "${C_GRN}" "${C_RST}" "${when}"
                    fi ;;
            down)   printf '  %-28s %sDOWN%s\n' "${unit}" "${C_YEL}" "${C_RST}" ;;
            # A run that correctly declined to act (the updater with an unreachable registry) is dim, not yellow: yellow
            # is this report's attention colour, and there is no fault to attend to -- the previous toolchain is intact
            # and the next run will try again. If the condition persists the line turns STALE on its own once the stamp
            # ages past its grace, which is where the operator is meant to look.
            skipped) reason="$(ai_tools_service_stamp_field "${stamp}" REASON)"
                    printf '  %-28s %sSKIPPED%s %s(last run %s%s -- nothing was changed)%s\n' \
                        "${unit}" "${C_DIM}" "${C_RST}" "${C_DIM}" "${age:-at an unknown time}" \
                        "${reason:+, ${reason}}" "${C_RST}" ;;
            # Two forms, because the two kinds of failed unit know different things about the run. A stamped unit
            # records when it ran; a system oneshot's result comes from systemd, which knows the exit status but is read
            # here without a time, so the line does not claim one.
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
            # 'unknown' is not a problem report -- it says only that this vantage point cannot tell. It stays a single
            # line carrying the one command that CAN tell, so a healthy host's report does not grow a diagnostic block
            # per unit it simply cannot query. One reading is separable here: a stamp still empty as the package seeded
            # it means the unit has never run, the state a freshly provisioned host is in until its first scheduled
            # window, so the line says that and keeps the check command beside it.
            *)      if [[ "${scope}" == sandbox-user ]]; then
                        if declare -F ai_tools_service_stamp_unwritten >/dev/null 2>&1 \
                                && ai_tools_service_stamp_unwritten "${stamp}"; then
                            printf '  %-28s %s? (no run recorded yet -- its first scheduled run has not happened; check: sudo systemctl --user -M %s@.host status %s)%s\n' \
                                "${unit}" "${C_DIM}" "${SANDBOX_USER}" "${unit}" "${C_RST}"
                        else
                            printf '  %-28s %s? (sandbox --user unit -- check: sudo systemctl --user -M %s@.host status %s)%s\n' \
                                "${unit}" "${C_DIM}" "${SANDBOX_USER}" "${unit}" "${C_RST}"
                        fi
                    else
                        printf '  %-28s %s? (systemctl unavailable)%s\n' "${unit}" "${C_DIM}" "${C_RST}"
                    fi ;;
        esac
        # A unit that IS reported broken names its consequence, then every command that inspects and fixes it.
        # A sandbox-user unit's are composed here rather than stored in the registry: they name the sandbox ACCOUNT,
        # and services.lib.sh is deployed with no @SANDBOX_USER@ pass.
        if ai_tools_service_needs_attention "${state}"; then
            ai_tools_records_accumulate_severity attention
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
    return 0
}

# cmd_project_list  -- print each allowlist entry as project, sandbox, or exclude, with its git safe.directory status,
# then flag inconsistent hand-edited entries under "Suggested cleanup" with copy-paste remediation commands (the
# allowlist is operator-owned and hand-editable, so a line can name a protected system path the tools refuse to touch,
# a stale path that no longer exists, or a project listed but never fully claimed). All read-only, reusing existing
# predicates and verbs -- no recovery machinery of its own.
cmd_project_list() {
    [[ "$#" -eq 0 ]] || die_usage MSG-E2A5 "projects list takes no arguments"
    [[ -f "${ALLOWLIST}" ]] || { say "no allowlist at ${ALLOWLIST}"; return 0; }
    # Name the operator on a --for run: the listed entries are that account's launch gate, not the invoker's,
    # and an unlabelled listing of someone else's projects reads as your own.
    if [[ -n "${FOR_OPERATOR}" ]]; then
        section "Registered projects for ${FOR_OPERATOR}"
    else
        section "Registered projects"
    fi
    # Root reads ROOT's allowlist, which no bootstrap creates -- so the report is empty, and correct, and reads
    # as a fault. An allowlist is per-operator by design (it is that operator's own launch gate), so say whose registry
    # this is and name the ones that hold projects. Root cannot follow this with --for: that flag needs an enrolled
    # invoker, and root is not one.
    if [[ "${INVOKING_USER}" == "root" ]]; then
        local -a enrolled=()
        ai_tools_conf_list enrolled "${AI_TOOLS_OPERATOR_CONF:-/etc/ai-tools/operator.conf}" \
            OPERATORS 2>/dev/null || enrolled=()
        say "  ${C_DIM}root's own registry -- projects are registered per operator${C_RST}"
        (( ${#enrolled[@]} )) && say \
            "  ${C_DIM}read one as that operator ($(join_words "${enrolled[@]}")): su - <operator> -c 'ai-tools projects'${C_RST}"
    fi
    local raw entry excl kind safe sd shown=0
    local -a cleanup=()

    # _is_labelled <dir>  -- 0 when SELinux is active and <dir> carries ai_tools_project_t.
    _is_labelled() {
        command -v getenforce >/dev/null 2>&1 \
            && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]] || return 1
        ls -Zd "$1" 2>/dev/null | grep -q ':ai_tools_project_t:'
    }
    # _has_glob <str>  -- 0 when <str> carries a shell glob metacharacter (* ? [). Globs are honored only in '!'
    # exclusion lines (both the wrapper and ai-tools-chown match them as globs); an allow line is realpath'd, so a glob
    # there resolves to no path and is inert.
    _has_glob() { [[ "$1" == *[*?[]* ]]; }
    # _remove_line_cmd <raw-line>  -- the copy-paste sed that deletes the VERBATIM allowlist line (comment and all),
    # so it matches what is stored even when the entry carries an end-of-line comment or quotes; allow_escape makes
    # the line a literal BRE.
    _remove_line_cmd() { printf "          sed -i '\\\\|^%s\$|d' %s" "$(allow_escape "$1")" "${ALLOWLIST}"; }
    # _reconcile <entry> <kind> <safedir-yes> <raw-line>  -- append a remediation block for an inconsistent entry (stale
    # / protected / listed-but-not-fully-claimed). Nested so it shares `cleanup`; <raw-line> is the verbatim source line
    # the removal command deletes.
    _reconcile() {
        local e="$1" k="$2" sdy="$3" raw="$4"
        if ! realpath -e "${e}" >/dev/null 2>&1; then
            cleanup+=( "  ${e}" \
                "      ${C_YEL}no longer exists${C_RST} (stale entry); remove it:" \
                "$(_remove_line_cmd "${raw}")" )
            ${sdy} && cleanup+=( "          sudo ${SAFEDIR_BIN} --remove ${e}" )
            return 0                                    # ${sdy}=false returns 1; don't kill cmd_project_list's set -e loop
        fi
        if ai_tools_protected_path_match "${e}" >/dev/null 2>&1; then
            cleanup+=( "  ${e}" \
                "      ${C_YEL}protected system path${C_RST} -- the tools refuse to operate on it; remove it:" \
                "$(_remove_line_cmd "${raw}")" )
            ${sdy} && cleanup+=( "          sudo ${SAFEDIR_BIN} --remove ${e}" )
            _is_labelled "${e}" && cleanup+=( "          sudo ${RELABEL_BIN} --remove ${e}" )
            return 0                                    # trailing conditionals above return 1; don't kill the loop
        fi
        [[ "${k}" == project ]] || return 0            # a sandbox clone takes the clone kind of `projects remove`
        # Not fully claimed: agent has no group access, the ACL is missing, or (SELinux active) the tree is unlabelled.
        # Read from the same project_state tokens the claim flow uses.
        local listed safedir filemode owngap acl labelled git
        IFS=' ' read -r listed safedir filemode owngap acl labelled git < <(project_state "${e}")
        if [[ "${owngap}" == true || "${acl}" == true || "${labelled}" == false ]]; then
            cleanup+=( "  ${e}" \
                "      ${C_YEL}listed but not fully claimed${C_RST}; finish claiming it:" \
                "          ai-tools projects claim ${e}" )
        fi
    }

    while IFS= read -r raw || [[ -n "${raw}" ]]; do
        # Same shared grammar the wrapper and the chown helper read this file with; keep the verbatim ${raw} line
        # so a stale/protected remediation deletes exactly what is stored.
        ai_tools_conf_path_entry "${raw}" || continue
        entry="${_ai_tools_conf_value}"
        shown=1
        if [[ "${entry}" == '!'* ]]; then
            excl="${entry:1}"
            # Two different things wear a '!', and telling them apart is the whole reason this report has a `disabled`
            # row: an exclusion INSIDE a listed project is a carve-out (a subtree withheld from the agent, working
            # exactly as intended), while one that no listed project contains is a PARKED PROJECT -- the operator took
            # it out of service and will want it back. A carve-out has no remedy to offer; a parked project is shown
            # with the verb that restores it, in place.
            if ! _has_glob "${excl}" && [[ -d "${excl}" ]] && ! inside_listed_project "${excl}"; then
                printf '  %-8s %-50s %s\n' "disabled" "${excl}" "${C_DIM}no session may start here${C_RST}"
                say "           ${C_DIM}re-enable: ai-tools projects enable ${excl}${C_RST}"
            else
                printf '  %-8s %s\n' "exclude" "${excl}"
            fi
            # A stale exclusion does not match a path on disk. Flag a non-glob '!' path that no longer exists; a glob
            # exclusion is valid as written (it need not resolve today), so leave it.
            if ! _has_glob "${excl}" && ! realpath -e "${excl}" >/dev/null 2>&1; then
                cleanup+=( "  ${entry}" \
                    "      ${C_YEL}no longer exists${C_RST} (stale exclusion); remove it:" \
                    "$(_remove_line_cmd "${raw}")" )
            fi
            continue
        fi
        # A glob in an ALLOW line is silently inert -- the wrapper realpath's allow entries, so the pattern resolves
        # to no path and never gates a launch. Flag it rather than letting it masquerade as a claimable project (globs
        # belong on '!' lines).
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

    # Reverse reconciliation: a git safe.directory entry with no matching allowlist line is an ORPHAN -- git still
    # trusts the tree though no allowlist line names it (the line was hand-deleted, or an unclaim was interrupted
    # before the safedir drop). Removing the stale safedir (and its label) is the cleanup; the entry is not a claimed
    # project, so it is not offered `ai-tools projects unclaim`, which would refuse an unlisted target. Control-plane
    # entries (/opt/ai-tools) are registered deliberately and are protected paths, so they are skipped.
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

# usage() is ORIENTATION, not reference: the verbs, one line each, and the three flags that cross verbs. Every per-verb
# option lives in ai-tools(1), so there is one reference surface for options and one operational surface for finding
# a verb -- rather than two copies of the same list, which is what this text had become (it was longer than the command
# summary it introduced).
#
# The two are paired by tests/unit/man.sh, which asserts: the VERB sets match in both directions, every long option
# named here is documented in the page, and every option the page's OPTIONS section documents is one a CLI parser
# accepts. So a verb added, renamed, or removed here changes the page in the same commit, and an option that outlives
# its parser fails the suite.
#
# The layout is load-bearing for that test: a verb line is indented FOUR spaces and starts with its long option, while
# the cross-verb flag lines are indented two. Keep descriptions free of long options, or they read as verbs.
usage() {
    cat <<EOF
ai-tools -- manage the projects a sandboxed coding agent may work in

  Projects
    projects                       the registered projects, in place and sandbox clones
    projects create DIRECTORY      create a new project directory, init git, and claim it
    projects claim [DIRECTORY]     claim an existing project in place
    projects unclaim [DIRECTORY]   release a project; the directory stays on disk
    projects remove [DIRECTORY]    release a project AND delete its directory
    projects disable [DIRECTORY]   park a project: no session may start in it
    projects enable [DIRECTORY]    un-park a project disabled earlier
    projects clone [DIRECTORY]     shallow-clone a repository into the sandbox area
    projects push [DIRECTORY]      push a sandbox clone's commits to its branch
    projects lockdown [DIRECTORY]  lock down secret-named files
    projects handback [DIRECTORY]  take back ownership of agent-written files
  Reports
    status                         service health, and whether anything needs attention
    providers                      installed agents and integrations, and which are enabled
    audit                          what has refused, been rejected, or been stranded
  Incident
    stop                           terminate every agent session on this host

    --version                      the installed version
    --help                         this summary

  -y/--yes        pre-answer a command's own confirmation (never its scoped opt-ins)
  --dry-run       show what would change, change nothing
  --for OPERATOR  act on another enrolled operator's projects instead of your own

  Run as an operator, without sudo -- the CLI invokes sudo itself for the steps that
  need it. Root may run only the verbs that write no operator state.

  Every option, exit code and example:  man ai-tools
  Sandbox workflow:                     /var/opt/ai-tools/README.md
EOF
}

# ── The enabled agents: what the provisioning gate, `status` and the clone hint resolve from ──────────────────────
# resolve_enabled_agents -- fill ENABLED_AGENTS with one "name<TAB>npm_package<TAB>launcher" line per enabled installed
# agent, from providers.lib.sh: the resolver ai-tools-run and the toolchain layer provision from, so this CLI does not
# name an agent of its own and a host that enables one agent, or several, is read the same way. Cached, since the gate,
# `status` and the clone hint each read it once per run. Returns non-zero when the library will not load,
# with ENABLED_AGENTS_ERROR naming it, so the gate refuses and the diagnostic says so; neither reads an empty set as "no
# agent" on that failure.
ENABLED_AGENTS=(); ENABLED_AGENTS_ERROR=""
resolve_enabled_agents() {
    if [[ -n "${_ENABLED_AGENTS_RESOLVED:-}" ]]; then [[ -z "${ENABLED_AGENTS_ERROR}" ]]; return; fi
    _ENABLED_AGENTS_RESOLVED=1
    local providers_lib=/usr/local/lib/ai-tools/providers.lib.sh
    # shellcheck source=SCRIPTDIR/../lib/ai-tools/providers.lib.sh
    if ! source "${providers_lib}" 2>/dev/null \
            || ! declare -F ai_tools_enabled_agents      >/dev/null 2>&1 \
            || ! declare -F ai_tools_agents_empty_verdict >/dev/null 2>&1; then
        ENABLED_AGENTS_ERROR="cannot load ${providers_lib} -- reinstall the ai-tools package"
        return 1
    fi
    mapfile -t ENABLED_AGENTS < <(ai_tools_enabled_agents)
    return 0
}

# enabled_agent_launchers -- one launcher name per enabled agent, in manifest order, on stdout.
enabled_agent_launchers() {
    local rec launcher
    for rec in "${ENABLED_AGENTS[@]+"${ENABLED_AGENTS[@]}"}"; do
        IFS=$'\t' read -r _ _ launcher <<<"${rec}"
        [[ -n "${launcher}" ]] && printf '%s\n' "${launcher}"
    done
    return 0
}

# agent_provisioned <launcher> -- succeed when that agent's stable launcher symlink exists. `-L`, not `-e`: `-e`
# dereferences into the 0750 toolchain, where the operator's stat fails with EACCES, and reports a valid link
# as missing.
agent_provisioned() { [[ -L "${LAUNCHER_DIR}/$1" ]]; }

# Refuse early on an unprovisioned install. A launcher symlink is bootstrap's last load-bearing artifact per agent --
# written after the account, Node and that agent's package all succeed -- so one existing for any enabled agent means
# provisioning finished. Gate before dispatch so a broken install stops here, not mid-operation in a root helper. Each
# way the read can fail refuses rather than passes: an unloadable resolver, an enabled set none of whose links exist,
# and an empty enabled set, whose reason the resolver's verdict names (an input it refused, or a configuration that asks
# for no agent). See cli.rule.md (Bootstrap preflight).
require_bootstrap() {
    resolve_enabled_agents || die MSG-V3N7 "the provider resolver is unavailable: ${ENABLED_AGENTS_ERROR}"
    local rec name launcher verdict reason remedy joined
    local -a unlinked=()
    for rec in "${ENABLED_AGENTS[@]+"${ENABLED_AGENTS[@]}"}"; do
        IFS=$'\t' read -r name _ launcher <<<"${rec}"
        agent_provisioned "${launcher}" && return 0
        unlinked+=("${name} (no ${LAUNCHER_DIR}/${launcher})")
    done
    if (( ${#unlinked[@]} > 0 )); then
        printf -v joined '%s, ' "${unlinked[@]}"
        die MSG-X9H7 "the sandbox is not provisioned for any enabled agent: ${joined%, } -- provision it with:" \
            "       sudo ai-tools-admin system bootstrap"
    fi
    IFS=$'\t' read -r verdict reason <<<"$(ai_tools_agents_empty_verdict)"
    case "${verdict}" in
        none) remedy="       enable one in /etc/ai-tools/operator.conf (AI_TOOLS_AGENTS), or install an ai-tools-agents package" ;;
        *)    remedy="       repair the input named there, then rerun" ;;
    esac
    die MSG-K7A6 "no agent is enabled or resolved, so there is no agent to provision a project for -- ${reason}" \
        "${remedy}"
}

# When this file is SOURCED rather than executed (tests/unit/sandbox.sh loads it to exercise the pure sandbox_*
# helpers), stop here: expose the functions, run neither the gates nor the dispatch. On execution BASH_SOURCE[0] equals
# $0, so this is a no-op and the CLI proceeds.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] || return 0

# The verbs meant to run WHEN things may be broken bypass the provisioning gate. Which ones, and what each of them reads
# on a host whose install never finished, is at BOOTSTRAP_EXEMPT_VERBS. Every other command stays gated.
verb_in "${COMMAND}" "${BOOTSTRAP_EXEMPT_VERBS[@]}" || require_bootstrap

# require_operator -- refuse a command that acts as an operator unless the invoking user is listed in OPERATORS
# in operator.conf. The project/sandbox/lockdown/reclaim paths resolve the caller's identity from that list
# (operator.lib.sh, via the root helpers); an unenrolled user would otherwise proceed through the registry writes
# and confirm prompts only to be refused by the first root helper that resolves owner (e.g. ai-tools-lockdown says "not
# in allowed projects for current operator"), after partial state was written and rolled back -- the misleading flow
# this gate replaces with one up-front message. operator.conf is 644, so the unprivileged CLI reads OPERATORS directly;
# adding a name there takes effect on the next command (no re-login, unlike the ai-ops group the admin verb also grants
# for launching the agent).
require_operator() {
    local conf="${AI_TOOLS_OPERATOR_CONF:-/etc/ai-tools/operator.conf}"
    local -a ops=(); local op
    if ai_tools_conf_list ops "${conf}" OPERATORS 2>/dev/null; then
        for op in "${ops[@]}"; do [[ "${op}" == "${INVOKING_USER}" ]] && return 0; done
    fi
    die MSG-X6U2 "you (${INVOKING_USER}) are not a configured ai-tools operator -- add your name to OPERATORS in ${conf} with:" \
        "       sudo ai-tools-admin operators add ${INVOKING_USER}"
}

# handover_target [args...] -- the project path to name in a handed-over command. Naming it explicitly is the point:
# the operator who runs that command is standing somewhere else, so a path-less suggestion would resolve against THEIR
# directory.
#
# It falls back to the current directory only when the caller named no path, which is what these verbs default
# to anyway. A path the caller DID name is passed through as typed even when it does not exist, because substituting
# the current directory there composes a command against a directory nobody named -- and since the suggestion is
# a claim, a plausible-looking one the operator pastes would grant the agent access to whatever they happened to be
# standing in. Mistyping a path must cost a re-typed path, so the mistyped one is what the message shows.
#
# Arguments are matched positionally: a flag is skipped, and so is the value of one that takes one, so `--group <name>`
# cannot be read as the project.
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

# require_sudo_access [verb-args...] -- refuse COMMAND when this caller does not hold a sudo grant for the root helper
# it reaches, and say who can run it instead.
#
# The case it exists for is an ai-ops-only account: in the operators group, in no sudoers rule. That is a supported
# shape, not a misconfiguration -- it is what --for was built for -- and it is NOT the same as having no password.
# An operator who has one is the worse case today: sudo authenticates before it decides, so they are asked
# for a password and refused after supplying it. Nothing here changes what anyone is granted; it moves a refusal
# that was already coming to before the prompt, and attaches the route to the result.
#
# Every verb that reaches a root helper is covered, and each is probed on the FIRST helper it reaches -- a site
# that grants some helpers and not others is then answered accurately rather than by a single representative.
# The refusal precedes the run's first sudo, which is the same ordering require_for_target follows: a command that is
# going to be refused must not prompt first.
require_sudo_access() {
    local bin="" what="" delegable=false
    case "${COMMAND}" in
        audit)                bin="${AUDIT_BIN}"    what="reading the refusal trail" ;;
        "projects lockdown")  bin="${LOCKDOWN_BIN}" what="locking down secret files"; delegable=true ;;
        "projects handback")  bin="${RECLAIM_BIN}"  what="handing back agent-written files"; delegable=true ;;
        "projects claim")     bin="${LOCKDOWN_BIN}" what="claiming a project"; delegable=true ;;
        # A create skips the secret gate (its tree is empty by construction), so the first helper it reaches is
        # the safe.directory registration, not the lockdown scan.
        "projects create")    bin="${SAFEDIR_BIN}"  what="creating a project"; delegable=true ;;
        "projects unclaim")   bin="${UNCLAIM_BIN}"  what="unclaiming a project"; delegable=true ;;
        # `projects remove` does not run ai-tools-unclaim: it deletes the tree instead of handing it back, so the first
        # helper it reaches is the safe.directory de-registration. The clone kind does not reach a helper that can
        # refuse the command -- its one sudo is unreg_safedir's removal, which warns and carries on rather than failing
        # the verb -- so a target under the clone area is not probed.
        "projects remove")
            [[ "$(realpath -m -- "$(handover_target "$@")" 2>/dev/null)" == "${SANDBOX_ROOT}/"* ]] && return 0
            bin="${SAFEDIR_BIN}"  what="removing a project"; delegable=true ;;
        "projects clone")     bin="${LOCKDOWN_BIN}" what="creating a sandbox clone" ;;
        # The enable/disable pair edits ONE line of the caller's own registry and does not reach a root helper at all,
        # so a plain run is not probed: refusing it for a missing grant would deny a no-sudo service account the one
        # pair of verbs it can run unaided. Only the --for form needs one, where ai-tools-allowlist performs the edit
        # on another operator's file.
        "projects enable"|"projects disable")
            [[ -n "${FOR_OPERATOR}" ]] || return 0
            bin="${ALLOWLIST_BIN}" what="enabling or disabling a project for ${FOR_OPERATOR}" ;;
        # `projects push` and the informational verbs reach no helper that can refuse the command.
        #
        # `stop` is deliberately absent from this table: it is the privileged verb that WORKS for an account without
        # a general grant, since %ai-ops carries a dedicated NOPASSWD rule for its helper. Probing it is harmless --
        # `sudo -n -l <helper>` answers exit 0 for that rule even though the drop-in pins it to the helper's
        # zero-argument form (the trailing ""), because the probe does not pass an operand. An entry here would only
        # ever produce "grant present", so it stays out and the verb reaches sudo directly, which reports a missing
        # drop-in itself. The pin also means `stop`'s FLAGGED forms fall outside the rule and meet sudo's ordinary
        # prompt (deliberate; stop.rule.md). This probe could not report that either: it asks about the helper, while
        # what a flag changes is whether the rule matches the command
        # line.
        *) return 0 ;;
    esac
    # A --for run's first helper is the allowlist READER, before the verb's own -- so that is what decides whether
    # the run can start at all.
    [[ -z "${FOR_OPERATOR}" ]] || bin="${ALLOWLIST_BIN}"
    sudo_grant_missing "${bin}" || return 0

    # The route out, printed PLAIN and ahead of die(): die() wraps its text through the error emitter, which would break
    # a command across lines (messaging.rule.md). WHAT THIS MESSAGE DOES NOT SAY. It names the account and the command,
    # and stops. Who that account belongs to is not knowable here -- a service account, a person with a restricted
    # login, an administrator working from one deliberately -- and neither is who runs the suggested command
    # or what they are to each other. So there is no advice to obtain a grant, and the account is not described
    # as anyone's: a message that guesses the arrangement is wrong in exactly the deployments this refusal exists for.
    local -a advice=("Ask an administrator or an ai-ops operator with sudo to run:" "")
    if [[ -n "${FOR_OPERATOR}" ]]; then
        advice+=( "    ai-tools ${COMMAND} --for ${FOR_OPERATOR} $(handover_target "$@")" )
    elif ${delegable}; then
        # --for is the whole answer here: the verb runs against ${INVOKING_USER}'s registry whoever performs it,
        # which is what the pre-configured no-sudo account needs.
        advice+=( "    ai-tools ${COMMAND} --for ${INVOKING_USER} $(handover_target "$@")" )
    elif [[ "${COMMAND}" == "projects clone" ]]; then
        # The one verb --for is refused on: a clone is made with the git credentials of whoever runs it. The REGISTRY
        # half is delegable all the same, and the clone area is deliberately outside the protected-paths set
        # so that claim is allowed. Two commands, two acts.
        local source_dir clone_dir
        source_dir="$(handover_target "$@")"
        clone_dir="${SANDBOX_ROOT}/$(basename "${source_dir}")"
        # The chown is not optional bookkeeping: the clone is created by whoever runs the first command, and a claim
        # FOR another operator over a tree that operator does not own leaves the agent without access
        # (require_claimable_owner refuses it). Three commands, because the middle one is the only thing that makes
        # the third do anything.
        advice+=( "    ai-tools projects clone ${source_dir}" \
                  "    sudo chown -R ${INVOKING_USER} ${clone_dir}" \
                  "    ai-tools projects claim --for ${INVOKING_USER} ${clone_dir}" "" \
                  "projects clone takes no --for: the clone is made with the git credentials of" \
                  "whoever runs it, so it is born owned by them. The chown hands it to" \
                  "${INVOKING_USER}, and the claim registers it for ${INVOKING_USER}." )
    else
        local rest=""; (( $# )) && rest="$(printf ' %q' "$@")"
        advice+=( "    ai-tools ${COMMAND}${rest}" )
    fi
    # The trail is written to journald as well, which many hosts let an ordinary account read -- a partial view (the
    # file sink is the authoritative one) but one the operator reads unaided.
    [[ "${COMMAND}" == audit ]] && advice+=( "" \
        "Some of the same events reach the journal, readable without root on many hosts:" "" \
        "    journalctl -p notice --since '7 days ago' | grep ai-tools" )

    printf '\n' >&2
    printf '  %s\n' "${advice[@]}" >&2
    printf '\n' >&2
    die MSG-R4J2 "this run needs root: ${what} goes through ${bin##*/}, and ${INVOKING_USER} holds no sudo grant for it." \
        "Membership of ai-ops does not carry a general sudo grant."
}

# require_runas_target -- refuse a `--for` run whose filesystem steps `sudo -n -l -u <target>` does not let the caller
# run AS the target. A no-op without --for, and a no-op for every verb that touches the filesystem only through a root
# helper.
#
# `projects create` and `projects remove` build and destroy a tree as an OWNER, through run_as_owner i.e.
# `sudo -u <target>`. That is a different sudoers question from the one require_sudo_access asks: a host can grant every
# ai-tools helper and still restrict Runas to root, and there each verb would fail at the worst moment -- the create
# after making the directory and before claiming it, the remove after unregistering the project and before deleting it.
# Probing first is what keeps "refused before anything changes" true on such a host.
#
# `projects claim` runs steps as the acting operator too -- its traverse ACL, its drift probe, its core.filemode pin --
# and is not probed here. Each of those warns and continues on its own, so a claim on a Runas-restricted host loses
# those steps individually and leaves the tree whole. Probing would refuse the whole claim over one step the rest does
# not need.
#
# Each command the run executes is probed rather than one representative, for the reason require_sudo_access gives:
# a sudoers permitting some and not others is then answered accurately. `sudo -n -l -u <target> <cmd>` cannot prompt,
# so this costs the caller no password, and it runs before require_for_target's snapshot -- the run's first real sudo --
# like every other refusal here.
require_runas_target() {
    [[ -n "${FOR_OPERATOR}" ]] || return 0
    local -a needed=()
    case "${COMMAND}" in
        "projects create") needed=(mkdir git tee chmod setfacl) ;;
        "projects remove") needed=(find rm) ;;
        *) return 0 ;;
    esac
    local name resolved blocked=""
    for name in "${needed[@]}"; do
        resolved="$(command -v -- "${name}" 2>/dev/null)" || continue   # absent: its own call site reports it
        if sudo_grant_missing "${resolved}" "${FOR_OPERATOR}"; then blocked="${resolved}"; break; fi
    done
    [[ -n "${blocked}" ]] || return 0

    # Printed plain and ahead of die(), whose emitter would wrap a command across lines.
    local -a advice=("Run it as ${FOR_OPERATOR} instead.")
    if [[ "${COMMAND}" == "projects create" ]]; then
        advice=("Run it as ${FOR_OPERATOR}, or create the project without --for and hand it over:" "" \
                "    ai-tools projects create DIRECTORY" \
                "    sudo chown -R ${FOR_OPERATOR} DIRECTORY" \
                "    ai-tools projects claim --for ${FOR_OPERATOR} DIRECTORY")
    fi
    printf '\n' >&2
    printf '  %s\n' "${advice[@]}" >&2
    printf '\n' >&2
    die MSG-Z6Q6 "a --for run acts on the filesystem AS the target: ${COMMAND} --for ${FOR_OPERATOR} runs ${blocked##*/} as ${FOR_OPERATOR}, and ${INVOKING_USER} holds no sudo grant to do that." \
        "This is a separate sudoers question from the ai-tools helpers: a host can grant every one of those and still restrict which accounts you may act as."
}

# snapshot_allowlist -- point ALLOWLIST at a private copy of the --for target's registry, read through the root helper.
# The copy is read-only input for THIS run: every mutation goes back through the helper, which re-reads the real file,
# so a stale snapshot can never be what a write is based on -- and reg_allow/unreg_allow refresh it after theirs. mktemp
# creates it 0600, and the EXIT trap removes it, so another operator's project list does not outlive the command.
ALLOWLIST_SNAPSHOT=""
snapshot_allowlist() {
    if [[ -z "${ALLOWLIST_SNAPSHOT}" ]]; then
        ALLOWLIST_SNAPSHOT="$(mktemp)" || die "cannot create a temporary file for the allowlist snapshot"
        trap remove_run_files EXIT
    fi
    # shellcheck disable=SC2024  # the redirect is meant to be the CALLER's: root reads the
    # 0600 allowlist, this shell writes the snapshot it owns. `sudo tee` would create the temp file as root and leave
    # the CLI unable to read back what it just asked for.
    sudo "${ALLOWLIST_BIN}" --operator "${FOR_OPERATOR}" --print > "${ALLOWLIST_SNAPSHOT}" \
        || die "could not read ${FOR_OPERATOR}'s allowed-projects"
    ALLOWLIST="${ALLOWLIST_SNAPSHOT}"
}

# remove_run_files -- the EXIT trap: remove the files a run made for itself, the allowlist snapshot and the claim's work
# directory. One function, since a run has one EXIT trap and either file may be the second one made.
remove_run_files() {
    [[ -z "${ALLOWLIST_SNAPSHOT}" ]] || rm -f -- "${ALLOWLIST_SNAPSHOT}"
    [[ -z "${CLAIM_WORK}" ]] || rm -rf -- "${CLAIM_WORK}"
    return 0
}

# require_for_target [verb-args...] -- validate a --for run of COMMAND, resolve the target's group, and re-point
# ALLOWLIST at the target's registry. A no-op without the flag, so no other code changes for an ordinary run.
#
# EVERY refusal here precedes snapshot_allowlist, which is the run's first sudo: a command that is going to be refused
# must not first prompt the operator for a password. That ordering is why the --force incompatibility is checked HERE,
# on the verb's own arguments, rather than where --force is parsed in cmd_project_unclaim -- that runs after this gate,
# so the prompt would come first.
#
# --for is accepted only on the verbs whose whole effect is decided by WHICH operator's allowlist covers the path:
# the registry pair, the two per-project root helpers that gate on allowlist coverage, and the listing. Elsewhere it is
# REFUSED rather than ignored -- a `projects clone --for` that silently cloned as the invoker would leave the tree owned
# by the wrong operator with no output to show the flag was disregarded.
#
# The target must be ENROLLED in OPERATORS: ai-tools-setfacl and the handback helpers resolve a path's owner
# over that list, so an entry written for an unenrolled name would create a launch gate no ownership machinery can act
# on. Enrollment is checked before the group lookup, so an unknown name is refused with the enrolment command rather
# than a getent failure.
require_for_target() {
    [[ -n "${FOR_OPERATOR}" ]] || return 0
    verb_in "${COMMAND}" "${FOR_ALLOWED_VERBS[@]}" \
        || die MSG-U7R7 "--for is not accepted on ${COMMAND}" \
               "it applies to: $(join_paths "${FOR_ALLOWED_VERBS[@]}")"
    # --force reaches a tree NO allowlist names, so ai-tools-unclaim cannot resolve its owner from an entry and binds
    # the walk to the INVOKING uid instead -- the guard that stops one operator rewriting another's files. Honouring
    # --for there would have the CLI name one operator while the helper acted as another.
    local a
    for a in "$@"; do
        [[ "${a}" == "--force" ]] || continue
        die MSG-B5K3 "--for cannot be combined with --force" \
            "an unlisted tree has no allowlist entry naming its owner, so the unclaim is bound to" \
            "       you as the invoking operator; run it as ${FOR_OPERATOR}, or unclaim the registered" \
            "       project without --force"
    done
    [[ "${FOR_OPERATOR}" != "${SANDBOX_USER}" ]] \
        || die MSG-M3Z3 "the sandbox account is not an operator and must not own projects"
    [[ "${FOR_OPERATOR}" != "root" ]] || die MSG-C4Y4 "root is not an operator"
    local conf="${AI_TOOLS_OPERATOR_CONF:-/etc/ai-tools/operator.conf}"
    local -a ops=(); local op found=false
    if ai_tools_conf_list ops "${conf}" OPERATORS 2>/dev/null; then
        for op in "${ops[@]}"; do
            [[ "${op}" == "${FOR_OPERATOR}" ]] && { found=true; break; }
        done
    fi
    ${found} || die MSG-E3D2 "not a configured ai-tools operator: ${FOR_OPERATOR} -- enrol it first with:" \
        "       sudo ai-tools-admin operators add ${FOR_OPERATOR}"
    OWNER_GROUP="$(id -gn "${FOR_OPERATOR}" 2>/dev/null)" \
        || die "cannot resolve the primary group of ${FOR_OPERATOR}"
    snapshot_allowlist
}

# Gate the operator-acting commands up front; the informational ones (`--help`, `--version`, `projects list`,
# `providers list`) stay open so an unenrolled user can still read usage and inspect the host.
if verb_in "${COMMAND}" "${OPERATOR_VERBS[@]}"; then require_operator; fi

# Refuse a verb whose root helper this caller has no sudo grant for, before require_for_target -- whose snapshot is
# a --for run's first sudo. Both gates keep the same ordering rule: a command that is going to be refused must not
# prompt for a password first.
require_sudo_access "$@"

# And refuse a --for run that cannot perform its filesystem steps AS the target -- a separate sudoers question
# from the helper grants, and one that would otherwise surface partway through building a tree. Same ordering rule:
# ahead of the snapshot, which is the first sudo that can prompt.
require_runas_target "$@"

# Validate a --for run and re-point the registry at the target, after require_operator: acting for another operator is
# an operator action, so the invoker must be enrolled before the target is even looked up.
require_for_target "$@"

# unknown_command <command> -- the refusal for a command path no arm accepts: the usage follows it, since the mistake is
# most often a verb typed for the wrong collection.
unknown_command() {
    printf 'ai-tools: unknown command: %s\n\n' "$1" >&2
    usage >&2
    exit 1
}

# One dispatch per collection, nested under the top-level one on the first token of COMMAND -- the shape ai-tools-admin
# takes, and the one tests/unit/man.sh and tests/integration/cli-flags.sh read the arms from.
projects_dispatch() {
    local verb="$1"; shift
    case "${verb}" in
        list)     cmd_project_list     "$@" ;;
        create)   cmd_project_create   "$@" ;;
        claim)    cmd_project_claim    "$@" ;;
        unclaim)  cmd_project_unclaim  "$@" ;;
        remove)   cmd_project_remove   "$@" ;;
        enable)   cmd_project_enable   "$@" ;;
        disable)  cmd_project_disable  "$@" ;;
        clone)    cmd_project_clone    "$@" ;;
        push)     cmd_project_push     "$@" ;;
        lockdown) cmd_project_lockdown "$@" ;;
        handback) cmd_project_handback "$@" ;;
        *)        unknown_command "projects ${verb}" ;;
    esac
}
providers_dispatch() {
    local verb="$1"; shift
    case "${verb}" in
        list) cmd_providers "$@" ;;
        *)    unknown_command "providers ${verb}" ;;
    esac
}

# ── Dispatch ─────────────────────────────────────────────────────────────────────
case "${COMMAND%% *}" in
    projects)  projects_dispatch  "${COMMAND#* }" "$@" ;;
    providers) providers_dispatch "${COMMAND#* }" "$@" ;;
    status)    cmd_status "$@" ;;
    audit)     cmd_audit "$@" ;;
    stop)      cmd_stop  "$@" ;;
    --version) printf 'ai-tools %s\n' "${AI_TOOLS_VERSION}" ;;
    --help)    usage ;;
    *)         unknown_command "${COMMAND}" ;;
esac
