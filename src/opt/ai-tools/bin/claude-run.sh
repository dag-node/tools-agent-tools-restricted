#!/usr/bin/env bash
# /opt/ai-tools/bin/claude-run
# Launched by the claude wrapper (as @SANDBOX_USER@ via sudo). Wraps the versioned
# claude binary in a systemd transient service unit (--pty, so the TUI keeps an
# interactive terminal) to apply per-session security properties before the agent
# process starts.
#
# ── Security properties applied ─────────────────────────────────────────────
#
# RestrictNamespaces=yes
#   Blocks creation (and joining) of EVERY namespace type for the session and all
#   processes it spawns.  This is the minimal allow-list -- and that minimal set is
#   empty: the agent legitimately needs to create no namespace at all.  An
#   unprivileged process (the agent holds no capabilities) can only ever create a
#   *user* namespace by itself; every other type (cgroup/ipc/mnt/net/pid/uts) needs
#   CAP_SYS_ADMIN, which is reachable only THROUGH a user namespace.  So blocking
#   user already blocks them all transitively; =yes makes that explicit and, unlike
#   a ~user deny-list, also fail-CLOSES against any namespace type a future kernel
#   adds (a deny-list would silently permit it).
#
#   The load-bearing effect is closing clone(CLONE_NEWUSER) (ESC-001 in the
#   avc-denials probe): without the filter an unprivileged process can
#   unshare(CLONE_NEWUSER) to appear as uid 0 inside a private namespace, which
#   (a) is the primary vector for exploiting kernel bugs that require 'root-in-userns'
#   and (b) enables overlay mounts over /etc that confuse application-layer checks.
#   SELinux type enforcement survives into user namespaces (the domain stays
#   ai_tools_t and file labels are unchanged), so the real risk is kernel CVE
#   surface, not direct file-access bypass.  SELinux cannot block the creation
#   itself on this policy -- the process2 class carries no create_user_ns permission
#   yet (see ESC-001 in ai_tools.te) -- so this seccomp filter is the only enforcing
#   layer until the base policy gains that permission.
#
#   System-wide user namespaces are intentionally kept enabled: Firefox requires
#   them for its renderer sandbox and rootless containers (Podman) use them as
#   their operating mechanism.  setting user.max_user_namespaces=0 would break
#   both.  This filter applies the restriction per-session without touching the
#   sysctl, so Firefox and container workloads are completely unaffected.
#
#   TRADE-OFF: =yes is incompatible with running unprivileged bubblewrap INSIDE the
#   session (bwrap must create user+mnt namespaces itself).  The deferred bwrap phase
#   has to resolve that -- bwrap before this filter, or a privileged bwrap -- if it
#   lands.
#
# PrivateTmp -- deliberately NOT set
#   PrivateTmp=yes is a no-op for an unprivileged --user manager, which cannot pivot the
#   private-/tmp mount for the payload: the unit sees the shared host /tmp regardless
#   (verified -- a --user unit with PrivateTmp=yes starts, but the payload's mountinfo shows
#   no private bind over /tmp and claude's runtime dir stays visible).  Sessions therefore
#   share /tmp, where claude keeps its runtime at a fixed /tmp/claude-<uid> (it does not
#   honour TMPDIR) and reuses it across sessions; claude-run does not touch that dir (see the
#   note by the launch).  Enforced /tmp isolation is DAC + the ai_tools_tmp_t type, not a
#   private mount.  Some hardened hosts ADDITIONALLY run pam_namespace polyinstantiation of
#   /tmp (optional, non-default); the sandbox does not assume or require it and works either
#   way -- when present, reach a session's /tmp instance from the host via /proc/<pid>/root/tmp.
#   True per-session /tmp isolation (and concurrent instances) would require a privileged
#   (--system) manager mounting PrivateTmp for the payload.
#
# ── NoNewPrivileges is FORCED ON by RestrictNamespaces (not optional) ─────────
#
# RestrictNamespaces=yes is a seccomp filter, and systemd sets PR_SET_NO_NEW_PRIVS
# whenever any seccomp sandbox directive is present -- on BOTH --user and --system
# units, and an explicit NoNewPrivileges=no does NOT override it (verified live:
# /proc/<pid>/status shows NoNewPrivs:1 inside the unit).  So the session ALWAYS runs
# under NNP.  This is unavoidable while the namespace block comes from systemd seccomp:
# SELinux cannot block clone(CLONE_NEWUSER) on this policy -- the process2 class has no
# create_user_ns permission (confirmed: `seinfo -c process2 -x` lists only
# nnp_transition + nosuid_transition; see ESC-001 in ai_tools.te) -- so the seccomp
# filter, and therefore NNP, is mandatory.  The unit ALSO sets NoNewPrivileges=yes
# explicitly (see the systemd-run call below): redundant with the line above, but it
# documents the guarantee at the call site.  It is safe -- it does not re-break the
# transition -- precisely because of consequence (1): ai_tools.te grants the
# process2:nnp_transition the bounded transition needs.
#
# Two consequences follow, both load-bearing:
#
#   (1) The domain transition into ai_tools_t is a BOUNDED transition under NNP, which
#       the kernel denies unless the policy grants process2:nnp_transition on the
#       target.  ai_tools.te grants it for the authorised source domains; without it
#       the session silently runs UNCONFINED (SELINUX_ERR security_bounded_transition,
#       AVC denied { nnp_transition }).  The grant does NOT relax NNP -- it only lets
#       the type change happen; the agent still runs with NO_NEW_PRIVS set.
#
#   (2) PR_SET_NO_NEW_PRIVS drops the SUID bit on execve, so `sudo` cannot become root
#       (verified: "sudo: the 'no new privileges' flag is set").  The
#       PostToolUse/Stop/SessionStart hooks call
#         sudo /usr/local/sbin/ai-tools/ai-tools-chown
#         sudo /usr/local/sbin/ai-tools/ai-tools-setgid
#       which therefore FAIL -- the ownership hand-back and secret-quarantine
#       mechanism does not work under NNP, and CANNOT while the hooks use SUID sudo.
#       The fix is to move those operations behind a root-owned, socket-activated
#       helper the agent calls without setuid (deferred; see the socket-helper design
#       in selinux/README / project memory).  Until that lands the hooks are inert.
#
# ── SELinux interaction ───────────────────────────────────────────────────────
#
# This script runs as @SANDBOX_USER@ after the sudo drop, under the bash interpreter
# (bin_t label) -- no domain transition fires at this stage.  It calls systemd-run
# --user, which hands the unit to @SANDBOX_USER@'s `systemd --user` manager; that
# manager exec's the versioned claude.exe (ai_tools_exec_t), and the transition into
# ai_tools_t fires there via domtrans_pattern(init_t, ai_tools_exec_t, ai_tools_t)
# in ai_tools.te.  The source domain is the user-manager domain -- init_t on
# RHEL/Rocky 9 targeted policy; VERIFY on the live box with
#   ps -eZ | grep 'systemd --user'
# and key the domtrans rule to whatever it actually is.  If the rule's source does
# not match, no transition fires and the session would run unconfined -- which the
# confinement preflight below catches BEFORE launch: it reads the manager's domain and
# the entrypoint label, refuses when SELinux is enforcing and confinement was expected
# but would not fire, and logs those inputs for every launch.  (The check is pre-launch,
# not post-transition: a wrapper cannot observe its successor's domain -- the transition
# happens when the manager exec's claude.exe, replacing nothing the wrapper can read --
# so it verifies the two transition inputs instead.)
#
# --service --pty (NOT --scope) is required: RestrictNamespaces is an exec-context
# sandbox directive, which systemd 252 REJECTS on a scope unit ("Unknown
# assignment") -- a scope has no exec context, because the caller (not the manager)
# performs the final exec.  Only a service unit, where the manager exec's ExecStart,
# accepts it.  The cost is that the exec now originates from the user manager (init_t)
# rather than from systemd-run in unconfined_t, which is why the domtrans rule is
# keyed on init_t.  --pty keeps stdin/stdout/stderr wired to the terminal so claude's
# TUI works; a plain service unit would detach from the controlling tty.
#
# ── Optional SELinux groups vs this namespace filter ─────────────────────────
#
# RestrictNamespaces=yes is a seccomp layer, ORTHOGONAL to SELinux: enabling an
# optional policy group (selinux/install-selinux.sh enable-group <name>) widens what
# SELinux permits but does NOT lift this filter.  Of the optional groups only
# `podman` creates namespaces -- rootless containers need user+mnt+pid+ipc+net+uts.
# With RestrictNamespaces=yes the kernel returns EPERM on those clone()/unshare()
# calls, so podman/buildah fail at startup even with the podman SELinux group loaded:
# the SELinux grant is necessary but NOT sufficient.  (systemd, pkgmgmt, and netadmin
# create no namespaces and are unaffected.)
#
# TO RE-FOCUS LATER: supporting rootless podman means re-allowing the user namespace
# -- which is exactly ESC-001 -- so it is not a clean partial relaxation.  Either run
# containers outside the sandbox, or, accepting the reopened CVE surface for that
# session, replace RestrictNamespaces=yes below with an explicit allow-list of just
# the types the workload needs (podman: user mnt pid ipc net uts) and re-test.  The
# pre-flight check below emits an actionable NOTICE when the podman group is loaded
# while this filter is active, instead of leaving a cryptic EPERM deep in a build.
#
# ── Ownership ────────────────────────────────────────────────────────────────
# 550 @PROJECTS_USER@:@SANDBOX_GROUP@ -- @SANDBOX_USER@ gets group r-x (execute)
# but no write.  /opt/ai-tools/bin is itself 550, so the agent cannot unlink or
# replace this file.
#
# ── CLAUDE_EXEC double-validation ────────────────────────────────────────────
# The wrapper validates and exports CLAUDE_EXEC before sudo; this script re-checks
# it so a tampered env_keep value cannot redirect execution to an arbitrary binary.
# Neither side is a single point of trust.

set -euo pipefail

readonly AI_TOOLS_NVM_DIR="/opt/ai-tools/.nvm"

# Shared message formatter: frames the pre-launch refusals and the podman NOTICE below
# in the paste-safe '#' box (wrapped within 80 columns) on a terminal, plain text
# otherwise. Best-effort -- the fallback keeps the prior plain-stderr behaviour if the
# lib is missing.
readonly MSG_LIB="/usr/local/lib/ai-tools/msg.lib.sh"
# shellcheck source=/dev/null
if ! source "${MSG_LIB}" 2>/dev/null; then
    ai_tools_msg_error()  { printf '%s\n' "$@" >&2; }
    ai_tools_msg_notice() { printf '%s\n' "$@" >&2; }
fi

# Re-validate CLAUDE_EXEC against the same versioned-path pattern the wrapper
# checked.  Uses ${CLAUDE_EXEC:-} so an absent variable matches the * branch.
case "${CLAUDE_EXEC:-}" in
    "${AI_TOOLS_NVM_DIR}/versions/node/"*/bin/claude) ;;
    *) ai_tools_msg_error 'claude-run: invalid or absent CLAUDE_EXEC -- cannot launch'; exit 1 ;;
esac
if [[ "${CLAUDE_EXEC}" == *"/../"* ]]; then
    ai_tools_msg_error 'claude-run: CLAUDE_EXEC contains parent-directory references'; exit 1
fi

# Working directory for the session. The wrapper validated the project dir (realpath,
# allowlist, claim) and exported it as CLAUDE_PROJECT_DIR; re-validate here (defence in
# depth, same posture as CLAUDE_EXEC -- neither side is a single point of trust) before
# handing it to systemd-run as --working-directory. A transient unit does NOT inherit the
# caller's cwd, so without this the agent starts in / instead of the project. When the var
# is absent (a direct/diagnostic exec outside the wrapper) the option is omitted and the
# systemd default applies; when present it must be an absolute, ..-free, existing directory,
# else fail closed rather than silently run in the wrong place.
_workdir=""
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    case "${CLAUDE_PROJECT_DIR}" in
        /*) ;;
        *) ai_tools_msg_error 'claude-run: CLAUDE_PROJECT_DIR must be an absolute path'; exit 1 ;;
    esac
    if [[ "${CLAUDE_PROJECT_DIR}" == *"/../"* || "${CLAUDE_PROJECT_DIR}" == *"/.." ]]; then
        ai_tools_msg_error 'claude-run: CLAUDE_PROJECT_DIR contains parent-directory references'; exit 1
    fi
    if [[ ! -d "${CLAUDE_PROJECT_DIR}" ]]; then
        ai_tools_msg_error "claude-run: CLAUDE_PROJECT_DIR is not an existing directory: ${CLAUDE_PROJECT_DIR}"; exit 1
    fi
    _workdir="${CLAUDE_PROJECT_DIR}"
fi

# $UID is a bash read-only built-in set at startup from the process real UID --
# no external command, no PATH dependency.  After the sudo drop we are @SANDBOX_USER@,
# so this correctly resolves to @SANDBOX_USER@'s runtime directory.
export XDG_RUNTIME_DIR="/run/user/${UID}"

# Pre-flight: verify the @SANDBOX_USER@ user instance bus socket exists before
# handing off to systemd-run.  systemd-run produces a cryptic dbus error when
# the instance is not running; this gives an actionable message instead.
if [[ ! -S "${XDG_RUNTIME_DIR}/bus" ]]; then
    ai_tools_msg_error \
        "claude-run: @SANDBOX_USER@ user instance not reachable (bus socket absent: ${XDG_RUNTIME_DIR}/bus)" \
        "ensure linger is enabled:  loginctl enable-linger @SANDBOX_USER@"
    exit 1
fi

# Fail-closed confinement preflight (SELinux).  A session that does not transition into
# ai_tools_t runs UNCONFINED, and because ai-tools is mapped to unconfined_u that cannot
# be forbidden in the policy module (the ESC-001 base-policy floor; a confined user_u
# mapping was rejected -- it breaks the ai-tools->root sudo the hooks need).  So verify
# HERE, before launch, that the transition will fire, and log the inputs every time.
# The unit's ExecStart is claude.exe (ai_tools_exec_t) and the systemd --user MANAGER
# exec's it, so the transition is domtrans_pattern(<manager domain>, ai_tools_exec_t,
# ai_tools_t).  Two things must hold: (a) claude.exe is labelled ai_tools_exec_t, and
# (b) the manager runs in a domain ai_tools.te has a domtrans rule for (init_t or
# unconfined_t -- keep this list in sync with the domtrans_pattern lines there).
# All signals are root-free; the gate fires ONLY when SELinux is enforcing AND the
# module is installed (matchpathcon resolves ai_tools_exec_t), so DAC-only and
# permissive boxes are unaffected.  A signal we cannot read (e.g. the manager domain)
# is logged as unknown and does not block the launch.
if command -v getenforce >/dev/null 2>&1; then
    _enf="$(getenforce 2>/dev/null || echo unknown)"
    # realpath resolves the bin/claude symlink chain to the real claude.exe (the
    # transition entrypoint).  It succeeds because claude-run runs as @SANDBOX_USER@,
    # which owns the 700 package dir (it would EACCES for the operator).
    _real="$(realpath -e "${CLAUDE_EXEC}" 2>/dev/null || printf '%s' "${CLAUDE_EXEC}")"
    _want="" _have="" _mgrdom=""
    if command -v matchpathcon >/dev/null 2>&1; then
        _want="$(matchpathcon -n "${_real}" 2>/dev/null | awk -F: '{print $3}' || true)"   # expected label (module installed?)
        _have="$(stat -c '%C' -- "${_real}" 2>/dev/null | awk -F: '{print $3}' || true)"   # live label
    fi
    # The manager is the systemd --user process that will exec claude.exe; read its
    # domain (same uid, so /proc/<pid>/attr/current is readable).
    _mgrpid="$(pgrep -u "${UID}" -f 'systemd --user' 2>/dev/null | head -n1 || true)"
    [[ -n "${_mgrpid}" ]] && _mgrdom="$(tr -d '\000' < "/proc/${_mgrpid}/attr/current" 2>/dev/null | awk -F: '{print $3}' || true)"

    command -v logger >/dev/null 2>&1 && logger -t claude-run -p authpriv.info \
        "launch: selinux=${_enf} exec_label=${_have:-none} expected=${_want:-none} manager_domain=${_mgrdom:-unknown}"

    if [[ "${_enf}" == "Enforcing" && "${_want}" == "ai_tools_exec_t" ]]; then
        if [[ "${_have}" != "ai_tools_exec_t" ]]; then
            ai_tools_msg_error \
                "claude-run: refusing to launch -- ${_real} is mislabelled \"${_have:-none}\"" \
                "(expected ai_tools_exec_t), so no domain transition fires and the session would run UNCONFINED (relabel is required after upgrade)." \
                "Fix:  ai-tools --relabel"
            command -v logger >/dev/null 2>&1 && logger -t claude-run -p authpriv.warning \
                "REFUSED: entrypoint mislabelled (${_have:-none}, want ai_tools_exec_t)"
            exit 1
        fi
        if [[ -n "${_mgrdom}" && "${_mgrdom}" != "init_t" && "${_mgrdom}" != "unconfined_t" ]]; then
            ai_tools_msg_error \
                "claude-run: refusing to launch -- the systemd --user manager runs in domain \"${_mgrdom}\", which no domtrans_pattern in ai_tools.te covers, so the session would run UNCONFINED.  Add the source and rebuild:" \
                "  domtrans_pattern(${_mgrdom}, ai_tools_exec_t, ai_tools_t)   # in selinux/policy/ai_tools.te" \
                "  sudo selinux/install-selinux.sh rebuild"
            command -v logger >/dev/null 2>&1 && logger -t claude-run -p authpriv.warning \
                "REFUSED: manager domain ${_mgrdom} has no domtrans to ai_tools_t"
            exit 1
        fi
    fi
fi

# Pre-flight: if the namespace-creating optional group (podman) is loaded, the
# RestrictNamespaces=yes filter below will still block the user namespace it needs.
# Surface that as an actionable NOTICE rather than a cryptic EPERM in a later build.
# Best-effort only: `semodule -l` may be absent or unreadable to this uid -- any
# failure is swallowed and launch proceeds (the header documents the cases we cannot
# detect here).  The regex tolerates both the name-only and name+version list formats.
if command -v semodule >/dev/null 2>&1 \
   && semodule -l 2>/dev/null | grep -qE '^ai_tools_podman([[:space:]]|$)'; then
    ai_tools_msg_notice \
        "claude-run: the \"podman\" SELinux group is enabled, but RestrictNamespaces=yes blocks the user namespace rootless podman/buildah require -- they will fail with EPERM on clone(CLONE_NEWUSER).  To allow containers, relax RestrictNamespaces in ${0} -- note that permitting the user namespace reopens ESC-001."
fi

# A service unit is spawned by the user manager with ITS OWN environment and umask,
# NOT claude-run's -- unlike a scope unit, which inherits both by running as a child
# of the caller.  That difference is a SECURITY OPPORTUNITY for the environment: a
# scope inherited claude-run's whole (post-sudo) environment wholesale, whereas here
# we forward only an explicit, non-sensitive ALLOWLIST.  The operator's environment
# can hold API keys, tokens, SSH_AUTH_SOCK, or cloud credentials; none of it crosses
# into the sandbox unless named below -- a guarantee by construction, independent of
# how sudo's env_reset/env_keep happens to be configured.  Two things are carried
# over explicitly:
#
#   * Environment (allowlist).  --setenv=NAME imports NAME by name from this process's
#     environment (absent vars are skipped; the value never touches the command line,
#     so no quoting/injection risk).  Only terminal-, locale-, and connectivity-shaping
#     vars are forwarded.  HOME and PATH are SET to sandbox values, never inherited:
#     HOME must be the agent's own /opt/ai-tools, and PATH is pinned to a known-good
#     list that includes the versioned node bin dir.  To pass an additional var (e.g. a
#     token you deliberately want shared), add its name to _ENV_ALLOW.
#   * UMask.  The collaborative-ownership model needs 0007 (group rwx) on agent-created
#     files; the sudoers umask set claude-run's umask, which a scope inherited but a
#     service does not.  Set it as a unit property instead.  (Like RestrictNamespaces,
#     UMask is an exec-context directive, so it too is only honoured on a service unit.)
_ENV_ALLOW=(
    TERM COLORTERM                                  # TUI rendering
    LANG LANGUAGE LC_ALL LC_CTYPE LC_MESSAGES       # locale / UTF-8 handling
    LC_COLLATE LC_NUMERIC LC_TIME LC_MONETARY
    XDG_RUNTIME_DIR                                 # user bus / runtime dir
    HTTP_PROXY HTTPS_PROXY NO_PROXY                 # outbound to the Anthropic API
    http_proxy https_proxy no_proxy
)
declare -a _setenv=()
for _name in "${_ENV_ALLOW[@]}"; do
    [[ -n "${!_name:-}" ]] && _setenv+=( "--setenv=${_name}" )
done
# HOME and PATH are pinned to sandbox values, never inherited from the operator.
# PATH mirrors /etc/profile.d/path_dedup.sh's security ordering: root-owned, least-
# writable dirs first (Tier 1) so they win first-match, with the versioned node bin
# placed LAST (path_dedup's Tier 4).  Safe because no node/npm/npx exists in any system
# dir, so the version-pinned node still resolves without being shadowed.  Redundant
# /sbin and /bin are dropped (usrmerge symlinks them onto /usr/sbin and /usr/bin).
_setenv+=( "--setenv=HOME=/opt/ai-tools" )
_setenv+=( "--setenv=PATH=/usr/local/sbin:/usr/sbin:/usr/local/bin:/usr/bin:$(dirname -- "${CLAUDE_EXEC}")" )

# Pin Node's V8 compile cache to the agent's own state area instead of letting it
# default to os.tmpdir()/node-compile-cache.  Node honours NODE_COMPILE_CACHE (>=v22.1)
# and claude calls module.enableCompileCache(), so without this the cache lands at
# /tmp/node-compile-cache/<ver>-<uid>/ on the SHARED host /tmp.  Two problems there,
# both fatal under enforcing: (a) any entry created during an earlier UNCONFINED run
# carries user_tmp_t (not ai_tools_tmp_t), a type ai_tools_t has no rule for, so node's
# open() of its own cached file is denied and the session dies at startup; (b) the
# top-level /tmp/node-compile-cache dir is shared across uids, so a peer uid that runs
# node first owns it as their user_tmp_t and the agent cannot add its subdir.  Routing
# the cache under /opt/ai-tools/.cache (ai_tools_home_t -- already managed by the agent,
# absolute so it is independent of HOME) sidesteps both: the cache never touches shared
# /tmp and is always on a type the policy grants.  This is the durable fix; clearing the
# stale /tmp/{claude-<uid>,node-compile-cache} leftovers is the one-time migration.
_setenv+=( "--setenv=NODE_COMPILE_CACHE=/opt/ai-tools/.cache/node-compile-cache" )

# Disable claude's in-session auto-updater.  The agent's Node program tree
# (.nvm/versions/node/*) is bin_t/lib_t -- READ-ONLY to ai_tools_t by policy (see
# ai_tools.fc) -- so an in-session `npm install -g` self-update cannot write the npm
# prefix: it would fail every launch ("Auto-update failed: no write permission to npm
# prefix") and emit an AVC under enforcing.  Node/claude updates are handled out-of-band
# by the scheduled nvm-update timer (unconfined, version-pinned), so the in-session
# updater is pure noise here.  Pinning it off keeps the toolset stable for the whole
# session, which is the intended behaviour.
_setenv+=( "--setenv=DISABLE_AUTOUPDATER=1" )

# ExecStart is claude.exe directly: the systemd --user manager exec's the labelled
# ai_tools_exec_t binary, so domtrans_pattern(<manager domain>, ai_tools_exec_t,
# ai_tools_t) fires cleanly with no intermediary.  The confinement preflight above has
# already verified that transition will land in ai_tools_t.
# claude owns its runtime dir at a fixed /tmp/claude-<uid> (it does not honour TMPDIR) and
# reuses it across sessions: when the dir already exists it skips creating it.  claude-run
# must NOT delete it -- removing it races claude's exists-then-mkdir check against the
# sandbox uid's other live sessions, which recreate the dir in the window and make startup
# fail with "EEXIST mkdir /tmp/claude-<uid>".  Leaving it in place keeps claude on the reuse
# path.  The dir is one fixed path per uid (it does not accumulate) and carries
# ai_tools_tmp_t (claude creates it post-transition).  Concurrent same-uid sessions share
# it; true per-session isolation needs a real private /tmp (--system PrivateTmp, see header).

# Descriptive transient unit name instead of systemd-run's auto-generated "run-uNN":
# makes the session identifiable in `systemctl --user list-units` (and the journal)
# as @SANDBOX_USER@'s Claude Code rather than an opaque counter.  The PID suffix keeps
# concurrent sessions from colliding on the unit name.
_unit="@SANDBOX_USER@-claude-$$.service"

# Set the unit's WorkingDirectory to the validated project dir so the session starts IN
# the project (a transient unit otherwise defaults to /).  Omitted when _workdir is empty
# (direct exec outside the wrapper).  NOTE for the enforcing bring-up: the WorkingDirectory
# chdir runs in the systemd --user MANAGER's domain (unconfined_t / init_t -- see the
# domtrans block) BEFORE the execve that transitions into ai_tools_t, so the manager domain
# needs search on ai_tools_project_t; verify no AVC fires here under enforcing.
declare -a _workdir_opt=()
[[ -n "${_workdir}" ]] && _workdir_opt=( "--working-directory=${_workdir}" )

exec systemd-run --user --pty \
    --unit="${_unit}" \
    --description="Claude Code @SANDBOX_USER@ session" \
    "${_setenv[@]}" \
    "${_workdir_opt[@]}" \
    --property=RestrictNamespaces=yes \
    --property=NoNewPrivileges=yes \
    --property=UMask=0007 \
    -- "${CLAUDE_EXEC}" "$@"
