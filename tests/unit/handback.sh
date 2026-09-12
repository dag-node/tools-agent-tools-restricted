#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/handback.sh
# Unit test for the handback daemon's own audit record: the native journald entry it writes,
# and the session unit it stamps on one. The daemon is the only component placed to name
# the session a root operation was performed for, a root helper not running in that unit,
# so what this file asserts is that the value arrives, that an unreadable cgroup leaves
# the field absent, and that no value a peer controls can forge a field beside it.
#
# The record's shape is asserted through the PURE builder (_journal_entry), so every case
# runs with no socket and no journald. The transport (_journal_send) is one case of its own,
# skipped on a host that refuses the send, and its fail direction is asserted beside it:
# an absent socket is reported and not raised, leaving the stream sink to carry the MESSAGE.
#
# Hermetic: every fixture lives in the test's own /tmp testdir, and the deployed daemon is
# loaded as a MODULE (compile+exec under a non-__main__ name, so its `if __name__` guard does
# not run it) and driven function by function. Pure text plus one AF_UNIX socket, so it does
# not need any privilege of its own; run as root via sudo like the rest of the suite.
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

# The driver prints one `<case> <verdict> <detail>` line per assertion. A verdict is
# PASS, FAIL, or the SKIP the transport case takes on a host that refuses the send.
# Each result is reported by the harness under its own case id, and a failure carries
# what arrived.
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

for name in ("_audit", "_journal_entry", "_journal_send", "_peer_user_unit"):
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
# about the daemon.
listener = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
listener.bind(socket_path)
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
