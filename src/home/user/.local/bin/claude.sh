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

# Print error lines to stderr, then pause for Enter when stdin is a tty.
# A bare terminal: user reads the error and presses Enter to dismiss.
# An IDE console (Rider, etc.) that closes on exit: the pause keeps it open.
# A script/pipe: stdin is not a tty, so the read is skipped.
die() {
    printf '%s\n' "$@" >&2
    if [[ -t 0 ]]; then
        read -r -p "Press Enter to close..." < /dev/tty 2>/dev/null || true
    fi
    exit 1
}

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
    die "claude: ${cwd}: not in approved projects list" \
        "claude: register it first (run as you, no sudo):" \
        "  ai-tools --sandbox-create ${cwd}  # isolated clone (recommended)" \
        "  ai-tools --project-create ${cwd}  # in place"
fi

# ── Claim guard ─────────────────────────────────────────────────────────────────
# The cwd passed the allowlist, but a registered path can still be incompletely
# "claimed". Two independent gaps:
#   ownership  -- group not ai-tools, or no group-execute. The sandbox user runs with
#                 this dir as its cwd, and Node's posix_spawn then fails EACCES on
#                 every child (hooks, the Bash tool): the session starts but can do
#                 nothing. FATAL. Closing it means granting the agent group access to
#                 this real tree -- a recursive chgrp, the heavy LAST-RESORT path. The
#                 clean alternative is an isolated sandbox clone, recommended first.
#   safe.dir   -- cwd absent from ai-tools' git safe.directory. git refuses to operate
#                 ("dubious ownership"). Non-fatal; only git, no ownership change.
# This wrapper runs as the operator (you), before the sudo drop, so an offer here is
# an operator action. It never performs the recursive grant itself: it recommends the
# clean path, then (last resort) delegates to `ai-tools --project-create` -- the one
# place that locks down secrets and normalizes ownership -- which the user confirms.
readonly AI_TOOLS_CLI="/usr/local/bin/ai-tools"
readonly GITCONFIG="/opt/ai-tools/.gitconfig"

own_gap=false
cwd_gid="$(stat -c '%G' "${cwd}" 2>/dev/null || true)"
cwd_mode="$(stat -c '%a' "${cwd}" 2>/dev/null || true)"
if [[ "${cwd_gid}" != "ai-tools" ]] || (( (0${cwd_mode:-0} & 010) == 0 )); then
    own_gap=true
fi
safe_gap=false
if ! git config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null \
        | grep -qxF "${cwd}"; then
    safe_gap=true
fi

if ${own_gap}; then
    {
        printf '\nclaude: %s is approved but not claimed for the sandbox.\n' "${cwd}"
        printf "  - group is '%s', not 'ai-tools' -- sessions cannot spawn children here\n" "${cwd_gid:-?}"
        if ${safe_gap}; then printf '  - also not in git safe.directory\n'; fi
        printf '\nRecommended -- an isolated clone that never touches this tree:\n'
        printf '  %s --sandbox-create %q\n' "${AI_TOOLS_CLI}" "${cwd}"
        printf '\nLast resort -- claim THIS tree in place (grants the agent recursive\n'
        printf 'group access to %s; secrets are locked down first):\n' "${cwd}"
    } >&2
    reply=""
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        printf 'Claim this tree in place now? [y/N] ' > /dev/tty
        read -r reply < /dev/tty || reply=""
    fi
    if [[ "${reply}" =~ ^[yY] ]]; then
        # Delegate the actual claim. ASSUME_YES skips only the CLI's top-level confirm
        # (you just answered it here); its secret-lockdown prompt stays explicit.
        AI_TOOLS_ASSUME_YES=1 "${AI_TOOLS_CLI}" --project-create "${cwd}" || true
        # Only launch if the claim truly made the tree accessible.
        cwd_gid="$(stat -c '%G' "${cwd}" 2>/dev/null || true)"
        cwd_mode="$(stat -c '%a' "${cwd}" 2>/dev/null || true)"
        if [[ "${cwd_gid}" != "ai-tools" ]] || (( (0${cwd_mode:-0} & 010) == 0 )); then
            die "claude: ${cwd}: still not accessible -- the claim did not complete"
        fi
    else
        die "claude: refusing to launch: ${cwd} is not accessible to the sandbox account" \
            "       run one of the commands above, then start claude again"
    fi
elif ${safe_gap}; then
    # Ownership is fine; only git's safe.directory is missing -- non-fatal, git alone is
    # affected. This wrapper runs as the operator, who owns ${GITCONFIG} (640), so offer to
    # add the single entry directly rather than only pointing at project-create. It is a
    # restrict-nothing change (git merely trusts a dir you already approved to launch in),
    # so unlike the recursive in-place claim it defaults YES. Adding only safe.directory is
    # consistent here because the other invariants (allowlist, group) already hold -- this
    # is the narrow safe.directory gap, not the full project-create claim. With no TTY to
    # confirm on, fall back to a NOTICE so a non-interactive launch never silently writes
    # the control-plane gitconfig.
    {
        printf '\nclaude: NOTICE: %s is not in git safe.directory;\n' "${cwd}"
        printf '  git will report "dubious ownership" here until it is registered.\n'
    } >&2
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        printf 'Add it to %s now? [Y/n] ' "${GITCONFIG}" > /dev/tty
        reply=""
        read -r reply < /dev/tty || reply=""
        if [[ ! "${reply}" =~ ^[nN] ]]; then
            if git config --file "${GITCONFIG}" --add safe.directory "${cwd}"; then
                printf 'claude: registered %s in git safe.directory.\n' "${cwd}" >&2
            else
                printf 'claude: NOTICE: could not write %s -- register manually:\n' "${GITCONFIG}" >&2
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
exec sudo -u ai-tools -g ai-tools -- /opt/ai-tools/bin/claude-run "$@"
