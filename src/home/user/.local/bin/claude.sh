#!/usr/bin/env bash
# ~/.local/bin/claude
# Sandboxed claude wrapper. Resolves the current versioned claude binary under
# /opt/ai-tools via a stable symlink maintained by nvm-update.sh, exports the
# resolved path as CLAUDE_EXEC, then re-executes /opt/ai-tools/bin/claude-run as
# the ai-tools user via sudo. claude-run wraps the session in a systemd transient
# service (systemd-run --user --pty; RestrictNamespaces=yes, PrivateTmp, UMask=0007)
# before exec'ing the versioned binary.
# Placed before nvm shims in PATH so it shadows any nvm-managed claude.

set -euo pipefail
IFS=$'\n\t'

readonly AI_TOOLS_NVM_DIR="/opt/ai-tools/.nvm"
readonly CLAUDE_LINK="/opt/ai-tools/bin/claude"
readonly AI_TOOLS_CLI="/usr/local/bin/ai-tools"

# Shared message formatter: frames refusals in the paste-safe '#' box (wrapped within
# 80 columns) on a real terminal, plain text otherwise. Best-effort -- if the lib is
# absent, the fallback reproduces the prior plain-stderr behaviour so the wrapper (and
# its tests) keep working unchanged.
readonly MSG_LIB="/usr/local/lib/ai-tools/msg.lib.sh"
# shellcheck source=/dev/null
if ! source "${MSG_LIB}" 2>/dev/null; then
    ai_tools_msg_error()  { printf '%s\n' "$@" >&2; }
    ai_tools_msg_notice() { printf '%s\n' "$@" >&2; }
    ai_tools_msg_block()  { shift; printf '%s\n' "$@" >&2; }
    ai_tools_msg_pick()   { printf '%s' "$1"; }   # no lib: take the default (Cancel)
fi

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

# have_tty: true only when a controlling terminal can actually be opened. `[[ -r /dev/tty ]]`
# is NOT a controlling-tty test -- the /dev/tty node is mode crw-rw-rw-, so the permission
# bits read true even with no controlling terminal (e.g. under setsid). Opening it is the
# only honest probe: with no controlling tty the open fails ENXIO and this returns non-zero,
# so the prompt guards below skip cleanly instead of writing to /dev/tty and aborting.
have_tty() { { : > /dev/tty; } 2>/dev/null; }

# Test the symlink itself with -L, NOT -e: -e dereferences the full chain
# (bin/claude -> versioned bin/claude -> .../claude-code/bin/claude.exe), and the
# package dir claude-code/ is mode 700 owned ai-tools. The invoking user cannot
# stat the final target (EACCES), so -e would report "not found" on a perfectly
# valid link. -L checks link existence without traversing past the first hop;
# the readlink + string validation below handle correctness, and the binary is
# only ever reached via sudo as ai-tools.
if [[ ! -L "${CLAUDE_LINK}" ]]; then
    die "ERROR: claude symlink not found at ${CLAUDE_LINK}" \
        "       Run: systemctl --user start nvm-update.service"
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
                [[ -t 0 ]] && read -r -p "Press Enter to close..." < /dev/tty 2>/dev/null || true
                exit 0
            fi
            die "claude: sandbox creation did not complete -- see the output above"
            ;;
        2)
            # Claim in place. ASSUME_YES answers only the CLI's top-level confirm (you chose
            # it here); the secret-lockdown prompt and the sudo relabel stay explicit.
            # --project-claim is idempotent and registers a brand-new path from scratch.
            AI_TOOLS_ASSUME_YES=1 "${AI_TOOLS_CLI}" --project-claim "${cwd}" || true
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
    claim_hint='[y/N]'; claim_default_yes=false
    ${own_gap} || { claim_hint='[Y/n]'; claim_default_yes=true; }
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
    reply=""
    if have_tty; then
        printf 'Claim it in place now? %s ' "${claim_hint}" > /dev/tty
        read -r reply < /dev/tty || reply=""
    fi
    claim_ok=false
    if ${claim_default_yes}; then
        [[ ! "${reply}" =~ ^[nN] ]] && claim_ok=true
    else
        [[ "${reply}" =~ ^[yY] ]] && claim_ok=true
    fi
    if ${claim_ok}; then
        # Delegate the claim. ASSUME_YES answers only the CLI's top-level confirm (you
        # answered it here); its secret-lockdown prompt and the sudo relabel stay
        # explicit. --project-claim is idempotent and closes whichever gaps apply.
        AI_TOOLS_ASSUME_YES=1 "${AI_TOOLS_CLI}" --project-claim "${cwd}" || true
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
    # Ownership is fine; only git's safe.directory is missing -- non-fatal, git alone is
    # affected. This wrapper runs as the operator, who owns ${GITCONFIG} (640), so offer to
    # add the single entry directly rather than only pointing at project-claim. It is a
    # restrict-nothing change (git merely trusts a dir you already approved to launch in),
    # so unlike the recursive in-place claim it defaults YES. Adding only safe.directory is
    # consistent here because the other invariants (allowlist, group, label) already hold --
    # this is the narrow safe.directory gap, not the full project-claim. With no TTY to
    # confirm on, fall back to a NOTICE so a non-interactive launch never silently writes
    # the control-plane gitconfig.
    ai_tools_msg_notice \
        "claude: ${cwd} is not in git safe.directory; git will report \"dubious ownership\" here until it is registered."
    if have_tty; then
        printf 'Add it to %s now? [Y/n] ' "${GITCONFIG}" > /dev/tty
        reply=""
        read -r reply < /dev/tty || reply=""
        if [[ ! "${reply}" =~ ^[nN] ]]; then
            if git config --file "${GITCONFIG}" --add safe.directory "${cwd}"; then
                printf 'claude: registered %s in git safe.directory.\n' "${cwd}" >&2
            else
                ai_tools_msg_notice "claude: could not write ${GITCONFIG} -- register manually:"
                printf '  git config --file %q --add safe.directory %q\n' "${GITCONFIG}" "${cwd}" >&2
            fi
        fi
    else
        printf '  register it with: git config --file %q --add safe.directory %q\n' "${GITCONFIG}" "${cwd}" >&2
    fi
fi

if [[ -t 1 ]]; then
    readonly _C_BOLD=$'\033[1m' _C_DIM=$'\033[2m' _C_RST=$'\033[0m'
    printf '\n'
    printf '%s%s%s\n' "${_C_BOLD}" '  ____ _      _    _   _ ____   _____    ____ ____ '     "${_C_RST}"
    printf '%s%s%s\n' "${_C_BOLD}" ' / ___| |    / \  | | | |  _ \ | ____|  /  __|    \ '    "${_C_RST}"
    printf '%s%s%s\n' "${_C_BOLD}" '| |     |   / _ \ | | | | | |  |  _|   |  |  | __) | '   "${_C_RST}"
    printf '%s%s%s\n' "${_C_BOLD}" '| |___| |_ / ___ \| |_|   |_|   |___   |  |__|   _ < '   "${_C_RST}"
    printf '%s%s%s\n' "${_C_BOLD}" ' \____|______/  __\_____/|____/|_____|  \____|_| \__\ '   "${_C_RST}"
    printf '\n'
    printf '  %sClaude Code Restricted, run sessions as sandboxed user.%s\n' "${_C_DIM}" "${_C_RST}"
    printf '\n'
fi

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
