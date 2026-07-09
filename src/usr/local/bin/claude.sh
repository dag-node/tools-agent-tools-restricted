#!/usr/bin/env bash
# /usr/local/bin/claude
# Sandboxed claude wrapper. Ships system-wide (root:root 0755, rpm-owned) and runs as the
# invoking operator. Refuses a non-operator (not in the ai-ops group) up front with a framed
# refusal, then resolves the current versioned claude binary under /opt/ai-tools via a stable
# symlink maintained by nvm-update.sh, exports the resolved path as CLAUDE_EXEC, and
# re-executes /opt/ai-tools/bin/claude-run as the ai-tools user via sudo. claude-run wraps
# the session in a systemd transient service (systemd-run --user --pty;
# RestrictNamespaces=yes, PrivateTmp, UMask=0007) before exec'ing the versioned binary.
# path-dedup.sh (wired into operator dotfiles by ai-tools-admin) ranks /usr/local/bin
# (Tier 1) above the nvm shims, so this shadows any nvm-managed claude on an operator's PATH.

set -euo pipefail
IFS=$'\n\t'

readonly AI_TOOLS_NVM_DIR="/opt/ai-tools/.nvm"
readonly CLAUDE_LINK="/opt/ai-tools/bin/claude"
readonly AI_TOOLS_CLI="/usr/local/bin/ai-tools"

# Shared message formatter: frames refusals in the paste-safe '#' box (wrapped within
# 80 columns) on a real terminal, plain text otherwise; ai_tools_msg_pick and
# ai_tools_msg_confirm carry the launch path's questions. REQUIRED, like
# safe-paths.lib.sh below: the prompts gate real decisions, so a missing lib fails the
# launch closed instead of running through a private fallback (see messaging.rule.md).
readonly MSG_LIB="/usr/local/lib/ai-tools/msg.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/msg.lib.sh
if ! source "${MSG_LIB}" 2>/dev/null; then
    command -v logger >/dev/null 2>&1 \
        && logger -t claude-wrapper -p user.err \
            "required library ${MSG_LIB} unavailable -- launch refused (fail closed)"
    printf 'claude: cannot load required library %s\n' "${MSG_LIB}" >&2
    printf '  the install is incomplete or /usr/local/lib/ai-tools is not traversable;\n' >&2
    printf '  refusing to launch (fail closed) -- reinstall ai-tools, then retry.\n' >&2
    exit 1
fi
# One fixed 80-column frame for every box the wrapper shows, so the guidance screens
# and refusals of a launch align instead of each sizing to its own text.
export AI_TOOLS_MSG_FULLWIDTH=1

# Protected-paths backstop (safe-paths.lib.sh): refuse to LAUNCH in a system directory even
# when the allowlist includes it. This is the launch path's front-line security guard, so it
# is REQUIRED -- loaded and VERIFIED just below (after die() is defined), and the wrapper
# FAILS CLOSED if it cannot load. A broken or mis-permissioned install is not a state to
# launch through with the guard disabled. Every safe-paths consumer fails closed the same way
# (no fail-open stub anywhere); see safe-paths.rule.md.
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"

# Print error lines to stderr (framed by ai_tools_msg_error), then pause for Enter when
# stdin is a tty.
# A bare terminal: user reads the error and presses Enter to dismiss.
# An IDE console (Rider, etc.) that closes on exit: the pause keeps it open.
# A script/pipe: stdin is not a tty, so the read is skipped.
die() {
    ai_tools_msg_error "$@"
    if [[ -t 0 ]]; then
        read -r -p "Press Enter to close..." < /dev/tty 2>/dev/null || true
    fi
    exit 1
}

# Load the launch safety library and FAIL CLOSED if it is unreachable. A silent no-op stub
# would start the wrapper with the protected-path guard OFF -- the quiet degradation that
# lets a broken or mis-permissioned install (e.g. a lib dir an operator cannot traverse) pass
# unnoticed. Source it, then require its guard functions to exist; refuse to launch otherwise,
# naming the likely cause. Logs to journald (via logger, since the wrapper does not source
# log.lib and it may share the broken dir) for the audit trail, then die()s to warn the user
# (die needs only ai_tools_msg_error, already set with a plain fallback, so the refusal still
# renders even if msg.lib was the missing piece).
# shellcheck source=SCRIPTDIR/../lib/ai-tools/safe-paths.lib.sh
if ! source "${SAFE_PATHS_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_assert_safe_target  >/dev/null 2>&1 \
        || ! declare -F ai_tools_protected_path_match >/dev/null 2>&1; then
    command -v logger >/dev/null 2>&1 \
        && logger -t claude -p user.err \
            "required safety library ${SAFE_PATHS_LIB} unavailable for $(id -un 2>/dev/null) -- launch refused (fail closed)"
    die "claude: cannot load the launch safety library -- refusing to start" \
        "       ${SAFE_PATHS_LIB}" \
        "       A critical ai-tools component is missing or unreadable, so the protected-path" \
        "       guard cannot run. Check that /usr/local/lib/ai-tools is traversable and its" \
        "       libraries are present, then reinstall the package if needed."
fi

# have_tty: true only when a controlling terminal can actually be opened. `[[ -r /dev/tty ]]`
# is NOT a controlling-tty test -- the /dev/tty node is mode crw-rw-rw-, so the permission
# bits read true even with no controlling terminal (e.g. under setsid). Opening it is the
# only honest probe: with no controlling tty the open fails ENXIO and this returns non-zero,
# so the prompt guards below skip cleanly instead of writing to /dev/tty and aborting.
have_tty() { { : > /dev/tty; } 2>/dev/null; }

# Operator gate: only a member of the ai-ops operators group may launch a session. The
# sudoers grant below is a %ai-ops group rule, so a non-operator fails at sudo regardless --
# this gate turns that raw denial into a framed refusal that names the right next step.
# `id -nG` (no user argument) lists THIS shell's live credential set, the same set sudo
# enforces against; the space-padding makes the match exact so a group whose name merely
# contains "ai-ops" cannot satisfy it. When the live check fails the refusal distinguishes
# three cases, because the fix differs in each: the sandbox account (which must never be an
# operator), an operator whose shell predates the grant (a stale session -- re-login), and a
# genuine non-operator.
readonly OPERATORS_GROUP="ai-ops"
readonly SANDBOX_USER="@SANDBOX_USER@"
_user="$(id -un)"
if [[ " $(id -nG 2>/dev/null) " != *" ${OPERATORS_GROUP} "* ]]; then
    if [[ "${_user}" == "${SANDBOX_USER}" ]]; then
        # The sandbox account itself (e.g. `sudo -u ai-tools claude`). It is deliberately kept
        # out of ai-ops -- a member could drive a session as an operator -- so "add it to the
        # group" is the wrong advice. An operator launches the wrapper from their own login and
        # the wrapper drops to the sandbox account on its own.
        die "claude: this is the sandbox account ${SANDBOX_USER}, which is not an ai-tools operator" \
            "       the sandbox account must never be one -- launch claude from your operator login;" \
            "       the wrapper drops to ${SANDBOX_USER} for you"
    elif id -nG "${_user}" 2>/dev/null | tr ' ' '\n' | grep -qx "${OPERATORS_GROUP}"; then
        # In ai-ops per the group database (id -nG <user> reads it) but absent from this shell's
        # live credentials -- a session started before the grant took effect. A fresh login
        # rebuilds the credential set; newgrp adopts the group in the current shell.
        die "claude: ${_user} is an ai-tools operator, but this shell started before the grant" \
            "       start a fresh login session to pick up the ${OPERATORS_GROUP} group --" \
            "       log out and back in, or adopt it in this shell with:" \
            "         newgrp ${OPERATORS_GROUP}"
    else
        die "claude: ${_user} is not an ai-tools operator -- not a member of the ${OPERATORS_GROUP} group" \
            "       an administrator can grant access with:" \
            "         sudo ai-tools-admin operator add ${_user}"
    fi
fi

# Test the symlink itself with -L, NOT -e: -e dereferences the full chain
# (bin/claude -> versioned bin/claude -> .../claude-code/bin/claude.exe), and the
# package dir claude-code/ is mode 700 owned ai-tools. The invoking user cannot
# stat the final target (EACCES), so -e would report "not found" on a perfectly
# valid link. -L checks link existence without traversing past the first hop;
# the readlink + string validation below handle correctness, and the binary is
# only ever reached via sudo as ai-tools.
if [[ ! -L "${CLAUDE_LINK}" ]]; then
    die "ERROR: claude symlink not found at ${CLAUDE_LINK}" \
        "       the sandbox toolchain is not provisioned yet -- provision it with:" \
        "         sudo ai-tools-bootstrap"
fi

# Resolve the stable symlink ONE hop -- it points directly at the versioned
# .../node/<ver>/bin/claude, which is exactly the path the sudoers rule matches.
#
# Do NOT use realpath (or readlink -f): the versioned bin/claude is itself an
# npm symlink into the package (-> .../claude-code/bin/claude.exe). Following
# it fully would (a) yield a path the sudoers NOPASSWD rule cannot match, so
# sudo would deny/prompt, and (b) require traversing the package directory
# (mode 700, owned ai-tools), which the invoking user cannot enter -- realpath
# would fail with EACCES and, under set -e, abort the wrapper with no message.
CLAUDE_REAL="$(readlink -- "${CLAUDE_LINK}")" \
    || die "ERROR: ${CLAUDE_LINK} is not a symlink -- reinstall or run nvm-update.sh"

# Safety: the target must be an absolute, ..-free path under the ai-tools nvm
# tree matching the versioned binary the sudoers rule allows. This blocks
# path-injection if the symlink is tampered with, using only string checks so
# no filesystem traversal beyond the symlink itself is required.
case "${CLAUDE_REAL}" in
    "${AI_TOOLS_NVM_DIR}/versions/node/"*/bin/claude) ;;
    *) die "ERROR: resolved claude path '${CLAUDE_REAL}' is not an approved ai-tools binary" ;;
esac
if [[ "${CLAUDE_REAL}" == *"/../"* ]]; then
    die "ERROR: resolved claude path '${CLAUDE_REAL}' contains parent-directory references"
fi

# Print-and-exit invocations (--version/--help as the sole argument) carry no project
# surface: the binary prints and exits without touching a working tree, so no allowlist,
# backstop, or claim gate applies to the CWD. The session still runs confined as the
# sandbox account -- the same validated binary under the same unit properties -- with the
# sandbox home as its WorkingDirectory (always present, no project grant implied).
if [[ $# -eq 1 ]]; then
    case "$1" in
        --version|-v|--help|-h)
            export CLAUDE_EXEC="${CLAUDE_REAL}"
            export CLAUDE_PROJECT_DIR="/opt/ai-tools"
            exec sudo -u ai-tools -g ai-tools -- /opt/ai-tools/bin/claude-run "$@"
            ;;
    esac
fi

# Allowlist guard: Claude Code only runs in explicitly approved directories.
# Create ~/.config/ai-tools/allowed-projects (one path per line) before use.
# Lines beginning with ! are exclusions. They override allows -- exactly as in
# ai-tools-chown -- so ! means the same thing in the launch gate as it does in
# the ownership hand-back: a subdirectory under an approved parent can be carved
# back out, and Claude Code will refuse to start there.
ALLOWLIST="${HOME}/.config/ai-tools/allowed-projects"
if [[ ! -f "${ALLOWLIST}" ]]; then
    die "claude: approved-projects allowlist not found" \
        "claude: create ${ALLOWLIST} and add project directories"
fi
cwd="$(realpath -e "${PWD}" 2>/dev/null)" \
    || die "claude: cannot resolve working directory"

# Refuse to launch in a protected system directory before consulting the allowlist, so a
# mis-entered allowlist cannot start a session where the ownership handback would then act.
ai_tools_assert_safe_target "${cwd}" "launch" || exit 1

declare -a allowed=()
declare -a excluded=()
while IFS= read -r entry || [[ -n "${entry}" ]]; do
    [[ -z "${entry}" || "${entry}" == '#'* ]] && continue
    if [[ "${entry}" == '!'* ]]; then
        excluded+=("${entry:1}")              # strip leading !, keep raw (may contain glob)
    else
        dir="$(realpath -e "${entry}" 2>/dev/null)" || continue
        allowed+=("${dir}")
    fi
done < "${ALLOWLIST}"

# Exclusions are checked first and override allows (mirrors ai-tools-chown).
if [[ "${#excluded[@]}" -gt 0 ]]; then
    for pat in "${excluded[@]}"; do
        pat="${pat%/}"                         # normalise: strip trailing slash
        if [[ "${cwd}" == ${pat} ]]; then
            die "claude: $(pwd): excluded by '!' rule in approved projects list"
        fi
        # For plain paths (no glob), also exclude directory contents
        if [[ "${pat}" != *'*'* && "${cwd}" == "${pat}/"* ]]; then
            die "claude: $(pwd): excluded by '!' rule in approved projects list"
        fi
    done
fi

approved=false
if [[ "${#allowed[@]}" -gt 0 ]]; then
    for dir in "${allowed[@]}"; do
        if [[ "${cwd}" == "${dir}" || "${cwd}" == "${dir}/"* ]]; then
            approved=true
            break
        fi
    done
fi
if [[ "${approved}" != true ]]; then
    declare -a blk=(
        "Two ways to make the project available to ai-tools sandboxed agent:"
        ""
        "  1) Create sandbox -- isolated shallow branch copy in sandbox-projects:"
        "       ${AI_TOOLS_CLI} --sandbox-create"
        ""
        "  2) Claim in place -- grant permissions to work inside this directory:"
        "       ${AI_TOOLS_CLI} --project-claim"
        ""
        "Note: --project-claim changes group ownership to ai-tools."
        "See 'ai-tools --help' for more info about these options."
    )
    ai_tools_msg_block "This directory is not accessible to sandbox user" "${blk[@]}"
    # Default Cancel: an unattended/piped run (no tty) takes option 3 and refuses to launch.
    sel=3
    if have_tty; then
        sel="$(ai_tools_msg_pick 3 "Create sandbox" "Claim in place" "Cancel")"
    fi
    case "${sel}" in
        1)
            # Create sandbox -- an isolated shallow clone under the sandbox-projects area. The
            # agent runs IN the clone, so the wrapper points the user there and stops; it does
            # not launch in this directory.
            if "${AI_TOOLS_CLI}" --sandbox-create "${cwd}"; then
                ai_tools_msg_notice "claude: sandbox ready -- cd into the clone path shown above, then run claude there"
                if [[ -t 0 ]]; then read -r -p "Press Enter to close..." < /dev/tty 2>/dev/null || true; fi
                exit 0
            fi
            die "claude: sandbox creation did not complete -- see the output above"
            ;;
        2)
            # Claim in place. --yes pre-answers only the CLI's proceed prompt (you chose
            # claiming here); the secret-lockdown prompt, the .git history grant, and the
            # traverse grant stay explicit. --project-claim is idempotent and registers a
            # brand-new path from scratch.
            "${AI_TOOLS_CLI}" --project-claim --yes "${cwd}" || true
            # Confirm the claim registered the path before falling through to the claim guard,
            # which re-verifies ownership/label (both just applied) and then launches.
            grep -qxF "${cwd}" "${ALLOWLIST}" 2>/dev/null \
                || die "claude: ${cwd}: still not accessible -- the claim did not complete"
            ;;
        *)
            die "claude: ${cwd} is not accessible to the sandbox" \
                "       run one of the listed commands, then start claude again"
            ;;
    esac
fi

# ── Claim guard ─────────────────────────────────────────────────────────────────
# The cwd passed the allowlist, but a registered path can still be incompletely
# "claimed". Three independent gaps, all detected read-only here; the fix is always
# delegated to `ai-tools --project-claim` (idempotent) -- this wrapper never performs a
# chgrp or a relabel itself, it only detects, offers, and (on consent) calls the CLI:
#   ownership  -- group not ai-tools, or no group-execute. The sandbox user runs with
#                 this dir as its cwd, and Node's posix_spawn then fails EACCES on every
#                 child (hooks, the Bash tool): the session starts but can do nothing.
#                 FATAL. Closing it grants the agent recursive group access to this real
#                 tree (a chgrp) -- the heavy LAST-RESORT path; the clean alternative is
#                 an isolated sandbox clone, recommended first.
#   label      -- under SELinux enforcing, the tree must carry ai_tools_project_t or the
#                 agent (ai_tools_t) cannot read/write it: again the session starts but
#                 every file op is denied. FATAL. The relabel needs root, so the claim
#                 runs it via sudo. Cheap -- no clone needed.
#   safe.dir   -- cwd absent from ai-tools' git safe.directory. git refuses to operate
#                 ("dubious ownership"). Non-fatal; only git, no ownership/label change.
readonly GITCONFIG="/opt/ai-tools/.gitconfig"
# Root helper that writes the safe.directory entry. .gitconfig is root-owned 644 (readable here
# for the gap check, writable only by root), so the operator registers through sudo -- the same
# helper the CLI's reg_safedir uses. See ai-tools-safedir's header for the model.
readonly SAFEDIR_BIN="/usr/local/sbin/ai-tools/ai-tools-safedir"

# project_labelled <dir>  -- 0 when SELinux is NOT enforcing (no label needed) or <dir>
# already carries ai_tools_project_t. Read-only, no privilege; the authoritative relabel
# lives in `ai-tools --project-claim` (-> ai-tools-relabel), never duplicated here.
project_labelled() {
    command -v getenforce >/dev/null 2>&1 || return 0
    [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]] || return 0
    ls -Zd "$1" 2>/dev/null | grep -q ':ai_tools_project_t:'
}

own_gap=false
cwd_gid="$(stat -c '%G' "${cwd}" 2>/dev/null || true)"
cwd_mode="$(stat -c '%a' "${cwd}" 2>/dev/null || true)"
if [[ "${cwd_gid}" != "ai-tools" ]] || (( (0${cwd_mode:-0} & 010) == 0 )); then
    own_gap=true
fi
label_gap=false
project_labelled "${cwd}" || label_gap=true
safe_gap=false
if ! git config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null \
        | grep -qxF "${cwd}"; then
    safe_gap=true
fi

if ${own_gap} || ${label_gap}; then
    # Severity-based default: the in-place ownership grant is heavy (recursive chgrp), so
    # it defaults NO and recommends the clone; a label-only gap is cheap and required, so
    # it defaults YES.
    claim_default='n'
    ${own_gap} || claim_default='y'
    declare -a blk2=()
    ${own_gap}   && blk2+=( "- group is '${cwd_gid:-?}', not 'ai-tools' -- sessions cannot spawn children here" )
    ${label_gap} && blk2+=( "- missing SELinux label ai_tools_project_t -- the agent cannot read/write here" )
    ${safe_gap}  && blk2+=( "- also not in git safe.directory" )
    blk2+=( "" )
    if ${own_gap}; then
        blk2+=(
            "Recommended -- an isolated shallow branch copy in sandbox-projects:"
            "       ${AI_TOOLS_CLI} --sandbox-create"
            "Allow access -- claim this directory in place (give access to ai-tools; needs sudo):"
            "       ${AI_TOOLS_CLI} --project-claim"
        )
    else
        blk2+=(
            "Claim it -- applies the SELinux label; needs sudo for the relabel:"
            "       ${AI_TOOLS_CLI} --project-claim"
        )
    fi
    blk2+=( "" "Both default to the current directory. See 'ai-tools --help' for what each does." )
    ai_tools_msg_block "This project is not fully claimed" "${blk2[@]}"
    claim_ok=false
    ai_tools_msg_confirm "Claim it in place now?" "${claim_default}" && claim_ok=true
    if ${claim_ok}; then
        # Delegate the claim. --yes pre-answers only the CLI's proceed prompt (you
        # answered it here); its secret-lockdown prompt, the .git history grant, and the
        # traverse grant stay explicit. --project-claim is idempotent and closes
        # whichever gaps apply.
        "${AI_TOOLS_CLI}" --project-claim --yes "${cwd}" || true
        # Re-verify the FATAL gaps actually closed before launching.
        cwd_gid="$(stat -c '%G' "${cwd}" 2>/dev/null || true)"
        cwd_mode="$(stat -c '%a' "${cwd}" 2>/dev/null || true)"
        if [[ "${cwd_gid}" != "ai-tools" ]] || (( (0${cwd_mode:-0} & 010) == 0 )); then
            die "claude: ${cwd}: still not accessible -- the claim did not complete"
        fi
        if ! project_labelled "${cwd}"; then
            # The relabel is the one claim step that needs root; the CLI runs it as
            # `sudo ai-tools-relabel` and prompts for your password. Re-running the claim
            # (NOT `sudo ai-tools` -- the CLI refuses to run as root) re-attempts it.
            die "claude: ${cwd}: SELinux label still missing -- the claim did not complete" \
                "       re-run: ${AI_TOOLS_CLI} --project-claim ${cwd}" \
                "       (enter your password when it prompts for the SELinux relabel)"
        fi
    else
        die "claude: refusing to launch -- ${cwd} is not fully claimed for the sandbox" \
            "       run one of the commands above, then start claude again"
    fi
elif ${safe_gap}; then
    # Ownership and label hold; the git safe.directory entry is the one piece missing. Offer to
    # register it via the SAFEDIR_BIN sudo helper -- the path reg_safedir uses (see
    # ai-tools-safedir for the 644/sudo model). Defaults YES (a restrict-nothing change for a
    # tree already approved to launch in); a non-interactive launch prints the command instead.
    ai_tools_msg_notice \
        "claude: ${cwd} is not in git safe.directory; git will report \"dubious ownership\" here until it is registered."
    if have_tty; then
        if ai_tools_msg_confirm "Register it now (needs sudo)?" y; then
            if sudo "${SAFEDIR_BIN}" "${cwd}"; then
                printf 'claude: registered %s in git safe.directory.\n' "${cwd}" >&2
            else
                ai_tools_msg_notice "claude: could not register ${cwd} -- add it with:"
                printf '  sudo %q %q\n' "${SAFEDIR_BIN}" "${cwd}" >&2
            fi
        fi
    else
        printf '  register it with: sudo %q %q\n' "${SAFEDIR_BIN}" "${cwd}" >&2
    fi
fi

# The launch banner is emitted by claude-run, not here: it runs as the sandbox account and
# can read the toolchain the operator cannot (the 700 package tree), so it reports the
# Claude Code / Node / ai-tools versions under the umbrella logo. See claude-run.

# Pass the validated versioned path to claude-run via an env var that sudo's
# env_keep carries through. claude-run re-validates before using it.
export CLAUDE_EXEC="${CLAUDE_REAL}"
# Pass the project directory the session should run IN. ${cwd} is the realpath'd PWD
# that already cleared the allowlist + claim gates above, so it is the trustworthy
# value -- a systemd transient unit does NOT inherit the caller's cwd (it defaults to
# /), so claude-run hands this to systemd-run as the unit's WorkingDirectory. Carried
# through sudo via env_keep (sudoers.d/ai-tools-claude); claude-run re-validates it.
export CLAUDE_PROJECT_DIR="${cwd}"
exec sudo -u ai-tools -g ai-tools -- /opt/ai-tools/bin/claude-run "$@"
