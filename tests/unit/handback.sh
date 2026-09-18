#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/handback.sh
# Unit test for the handback daemon's own audit record: the native journald entry it writes, and the session unit it
# stamps on one. The daemon is the only component placed to name the session a root operation was performed for, a root
# helper not running in that unit, so what this file asserts is that the value arrives, that an unreadable cgroup leaves
# the field absent, and that no value a peer controls can forge a field beside it.
#
# The record's shape is asserted through the PURE builder (_journal_entry), so every case runs with no socket and no
# journald. The transport (_journal_send) is one case of its own, skipped on a host that refuses the send, and its fail
# direction is asserted beside it: an absent socket is reported and not raised, leaving the stream sink to carry
# the MESSAGE.
#
# Hermetic: every fixture lives in the test's own /tmp testdir, and the deployed daemon is
# loaded as a MODULE (compile+exec under a non-__main__ name, so its `if __name__` guard does
# not run it) and driven function by function. Pure text plus one AF_UNIX socket, so it does not need any privilege
# of its own; run as root via sudo like the rest of the suite.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly DAEMON="/usr/local/libexec/ai-tools/ai-tools-handback"
section "handback: the daemon's journal record (unit)"

if ! command -v python3 >/dev/null 2>&1; then
    skip "handback record" "python3 not available"; finish; exit
fi
if [[ ! -r "${DAEMON}" ]]; then
    skip "handback record" "daemon not readable at ${DAEMON}"; finish; exit
fi

mktestdir

# The driver prints one `<case> <verdict> <detail>` line per assertion. A verdict is PASS, FAIL, or the SKIP
# the transport case takes on a host that refuses the send. Each result is reported by the harness under its own case
# id, and a failure carries what arrived.
DRIVER="${TESTDIR}/driver.py"
cat > "${DRIVER}" <<'PY'
import builtins
import os
import socket
import sys

daemon_path, testdir = sys.argv[1:3]
socket_path = os.path.join(testdir, "journal.sock")
os.environ["AI_TOOLS_JOURNAL_SOCKET"] = socket_path

# The installed daemon has no .py suffix, so spec_from_file_location cannot guess a loader;
# compile+exec loads it from any path and bypasses the bytecode cache, so a stale .pyc can
# never mislead this check. __name__ is a non-__main__ value, so main() does not run.
namespace = {"__name__": "ai_tools_handback_probe"}
with open(daemon_path) as handle:
    exec(compile(handle.read(), daemon_path, "exec"), namespace)

for name in ("_audit", "_journal_entry", "_journal_send", "_peer_user_unit", "_unit_name_or_empty"):
    if name not in namespace:
        sys.exit(2)  # installed daemon predates the fields -> report as skip

entry_of = namespace["_journal_entry"]
unit_of = namespace["_peer_user_unit"]


def lines_of(level, message, fields):
    return entry_of(level, message, fields).decode("utf-8", "replace").splitlines()


def report(case, ok, detail=""):
    print("%s %s %s" % (case, "PASS" if ok else "FAIL", detail))


served = lines_of("info", "served CHOWN pid=42 arg=/project/file -> OK", (
    ("AI_TOOLS_SESSION_UNIT", "claude-session.service"),
    ("AI_TOOLS_VERB", "CHOWN"),
    ("AI_TOOLS_PATH", "/project/file"),
    ("AI_TOOLS_RESULT", "ok"),
))
report("TEST-HB-01-envelope",
       "MESSAGE=served CHOWN pid=42 arg=/project/file -> OK" in served
       and "PRIORITY=6" in served
       and "SYSLOG_IDENTIFIER=ai-tools-handback" in served
       and "SYSLOG_FACILITY=3" in served,
       repr(served))
report("TEST-HB-02-fields",
       "AI_TOOLS_SESSION_UNIT=claude-session.service" in served
       and "AI_TOOLS_VERB=CHOWN" in served
       and "AI_TOOLS_PATH=/project/file" in served
       and "AI_TOOLS_RESULT=ok" in served,
       repr(served))

# A refused peer is recorded before any session is resolved, and each level maps to its own
# numeric priority, so `journalctl -p warning` selects a refusal exactly as it did before.
refused = lines_of("warning", "rejected uid 0 pid 7 (want uid 995)", (
    ("AI_TOOLS_SESSION_UNIT", ""),
    ("AI_TOOLS_RESULT", "refused"),
))
report("TEST-HB-03-absent-field",
       not any(line.startswith("AI_TOOLS_SESSION_UNIT=") for line in refused)
       and "PRIORITY=4" in refused
       and "AI_TOOLS_RESULT=refused" in refused,
       repr(refused))

# THE CLAIM. Every value on this record is derived from a path the sandbox account chose,
# and the protocol is newline-delimited, so a newline that survived would parse as a field
# of its own -- including one naming the session unit, the field this record is trusted for.
forged = lines_of("info", "served CHOWN", (
    ("AI_TOOLS_SESSION_UNIT", "claude-session.service"),
    ("AI_TOOLS_PATH", "/project/\x1b[31mx\nAI_TOOLS_SESSION_UNIT=forged.service"),
    ("AI_TOOLS_RESULT", "ok"),
))
report("TEST-HB-04-no-forgery",
       "AI_TOOLS_SESSION_UNIT=forged.service" not in forged
       and "AI_TOOLS_SESSION_UNIT=claude-session.service" in forged
       and all("\x1b" not in line for line in forged),
       repr(forged))

# The session unit is read from the peer's cgroup the way journald derives its own
# _SYSTEMD_USER_UNIT. A shape it cannot read does not yield any value, so the field stays
# absent: the value is attribution, and the uid check is what authorizes a request.
real_open = builtins.open
fixture = os.path.join(testdir, "cgroup")

# A cgroup DIRECTORY name is held to no systemd rule -- the kernel takes any byte but NUL and '/' -- and the session's
# manager delegates a subtree the sandbox account may mkdir in, so this component is agent-influenceable. What the
# reader admits is systemd's own valid-unit-name set within UNIT_NAME_MAX; each crafted row in the cases list is a way
# a forged component could reach the operator's terminal or the record's own field, and each must read as NO unit.
LONG = "a" * 300


def under_manager(component):
    return "0::/user.slice/user-995.slice/user@995.service/app.slice/%s\n" % component


cases = [
    ("0::/user.slice/user-1000.slice/user@1000.service/app.slice/claude-x.service\n",
     "claude-x.service", "a session service under the user manager"),
    ("0::/user.slice/user-995.slice/user@995.service/ai-tools.slice/sess.scope\n",
     "sess.scope", "a scope under the user manager"),
    ("0::/user.slice/user-1000.slice/session-3.scope\n",
     "", "a login session outside any user manager"),
    ("0::/user.slice/user-995.slice/user@995.service/session.slice/dbus.socket\n",
     "", "a unit that is neither a service nor a scope"),
    ("", "", "an empty cgroup file"),
    # Accepted: every character systemd itself may put in a unit name, so the allowlist does not reject a real host.
    (under_manager("ai-tools-codex-65490.service"), "ai-tools-codex-65490.service", "a real session unit name"),
    (under_manager("getty@tty1.service"), "getty@tty1.service", "a template instance"),
    (under_manager("dev-disk-by\\x2duuid-0f3.service"), "dev-disk-by\\x2duuid-0f3.service", "an escaped unit name"),
    # Refused: each is a directory name the kernel accepts and systemd's own unit-name validator rejects.
    (under_manager("evil\x1b[31m.service"), "", "an escape sequence in the component"),
    (under_manager("a\tb.service"), "", "a control character in the component"),
    (under_manager("AI_TOOLS_SESSION_UNIT=x.service"), "", "a component shaped like a field assignment"),
    (under_manager("with space.service"), "", "a space in the component"),
    (under_manager(LONG + ".service"), "", "a component over UNIT_NAME_MAX"),
]
failures = []
for text, want, label in cases:
    with real_open(fixture, "w") as handle:
        handle.write(text)
    builtins.open = (lambda name, *args, **kwargs:
                     real_open(fixture) if str(name).startswith("/proc/")
                     else real_open(name, *args, **kwargs))
    try:
        got = unit_of(1)
    finally:
        builtins.open = real_open
    if got != want:
        failures.append("%s: got %r want %r" % (label, got, want))
report("TEST-HB-05-cgroup", not failures, "; ".join(failures))

# The fail direction, which does not need any socket: an absent journal socket is reported
# and not raised, so _audit falls through to the stream sink and the MESSAGE still lands.
report("TEST-HB-06-fallback",
       namespace["_journal_send"]("info", "no socket is bound", ()) is False)

# The transport itself. Bind the socket the override names and assert the bytes arrive; a host
# that refuses an AF_UNIX datagram send reports a skip, since an absent datagram is not evidence
# about the daemon. The BIND is refused on the same hosts as the send (a confined session is one),
# so it is inside the skip rather than outside it: raising there would abort the driver and cost
# every case after this one its result, which the harness reads as the driver never having run.
listener = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
try:
    listener.bind(socket_path)
except OSError as exc:
    print("TEST-HB-07-transport SKIP the AF_UNIX bind is refused here (%s)" % exc.strerror)
    listener.close()
    listener = None
if listener is not None:
    listener.settimeout(5)
    try:
        sent = namespace["_journal_send"]("notice", "a datagram", (("AI_TOOLS_VERB", "SETGID"),))
        if not sent:
            print("TEST-HB-07-transport SKIP the AF_UNIX datagram send is refused here")
        else:
            arrived = listener.recv(65536).decode("utf-8", "replace").splitlines()
            report("TEST-HB-07-transport",
                   "MESSAGE=a datagram" in arrived
                   and "PRIORITY=5" in arrived
                   and "AI_TOOLS_VERB=SETGID" in arrived,
                   repr(arrived))
    except socket.timeout:
        report("TEST-HB-07-transport", False, "the send reported success and nothing arrived")
    finally:
        listener.close()

# A rejected component is the only trace that something wrote the delegated cgroup subtree directly, so it is RECORDED
# rather than silently absent -- at warning, the level malformed peer input takes here, naming the peer pid. The routine
# absent case (no user@<uid>.service component at all) must stay silent, or a host with any peer outside a user
# manager warns on every served request and the record stops marking anything out.
recorded = []
real_audit = namespace["_audit"]
namespace["_audit"] = (lambda level, msg, **kwargs: recorded.append((level, msg)))
audit_cases = [
    (under_manager("evil\x1b[31m.service"), True, "a forged component"),
    (under_manager(LONG + ".service"), True, "an over-long component"),
    ("0::/user.slice/user-1000.slice/session-3.scope\n", False, "a peer outside any user manager"),
    (under_manager("claude-x.service"), False, "a well-formed unit name"),
]
audit_failures = []
for text, want_record, label in audit_cases:
    del recorded[:]
    with real_open(fixture, "w") as handle:
        handle.write(text)
    builtins.open = (lambda name, *args, **kwargs:
                     real_open(fixture) if str(name).startswith("/proc/")
                     else real_open(name, *args, **kwargs))
    try:
        unit_of(4743)
    finally:
        builtins.open = real_open
    if want_record:
        if len(recorded) != 1:
            audit_failures.append("%s: recorded %r" % (label, recorded))
            continue
        level, msg = recorded[0]
        if level != "warning" or "4743" not in msg:
            audit_failures.append("%s: got %r" % (label, (level, msg)))
    elif recorded:
        audit_failures.append("%s: recorded %r and should not have" % (label, recorded))
namespace["_audit"] = real_audit
report("TEST-HB-08-rejection-recorded", not audit_failures, "; ".join(audit_failures))

# The rejected value reaches the record through _audit's own sanitizer, so the forged bytes cannot survive into
# the journald datagram as a field of their own. Driven through the real _audit path, with the builder as the oracle.
crafted = lines_of("warning",
                   "rejected malformed cgroup unit name (pid 4743, characters outside the unit-name set): "
                   "x\nAI_TOOLS_SESSION_UNIT=forged.service",
                   (("AI_TOOLS_RESULT", ""),))
report("TEST-HB-09-rejection-sanitized",
       "AI_TOOLS_SESSION_UNIT=forged.service" not in crafted
       and not any(line.startswith("AI_TOOLS_SESSION_UNIT=") for line in crafted)
       and "PRIORITY=4" in crafted,
       repr(crafted))
PY
RC=0
OUT="$(python3 "${DRIVER}" "${DAEMON}" "${TESTDIR}" 2>&1)" || RC=$?

case "${RC}" in
    0) while read -r case verdict detail; do
           [[ -n "${case}" ]] || continue
           case "${verdict}" in
               PASS) pass "${case}" ;;
               SKIP) skip "${case}" "${detail}" ;;
               *)    fail "${case}: ${detail}" ;;
           esac
       done <<<"${OUT}" ;;
    2) skip "handback record" "installed daemon predates the journal fields" ;;
    *) fail "handback record: the driver did not run (rc ${RC}): ${OUT}" ;;
esac

finish
