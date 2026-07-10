#!/usr/bin/env python3
# /usr/local/sbin/ai-tools/ai-tools-handback
# Socket-activated per-connection privilege bridge for the ai-tools sandbox.
#
# Spawned once per connection by ai-tools-handback@.service (Accept=yes socket
# activation) with the accepted AF_UNIX socket as stdin AND stdout.  Serves one
# request then exits.
#
# Protocol (UTF-8, LF-terminated):
#   request:   VERB SP ARGUMENT LF
#   response:  zero or more "MSG" SP TEXT LF  (stderr relay -- NOTICEs to session)
#              then:  "OK" LF   |   "ERR" SP REASON LF
#
# Verbs:
#   CHOWN  <abs-path>        -- ownership handback (ai-tools-chown)
#   SETGID <abs-path>        -- setgid normalisation (ai-tools-setgid)
#   SYMLINK <versioned-path> -- stable symlink repoint (ai-tools-claude-symlink)
#
# Security model:
#   DAC: socket is 0660 SocketGroup=@SANDBOX_GROUP@ -- only root and @SANDBOX_USER@
#        can connect.  Every other uid gets EACCES before reaching this handler.
#   AuthN: SO_PEERCRED verifies peer uid == @SANDBOX_USER@ uid (second gate, inside
#          the handler).
#   Validation: each verb delegates to the existing root helper, which re-validates
#     the allowlist, exclusions, and path constraints -- the helpers are the trust
#     boundary and this handler does NOT duplicate that logic.
#
# stderr relay: the root helpers print NOTICE lines to stderr (e.g. when a
# secret-named file is detected).  This handler captures helper stderr, echoes
# each line to its own stderr (-> journal via StandardError=journal), and relays
# each line as a MSG response line so the client can forward it to its own stderr,
# which the hooks forward to the agent session -- preserving the NOTICE UX.
#
# Audit trail (_audit): the daemon records its own events -- rejected peers, malformed or
# refused requests, helper timeouts/exec failures, and one line per served request -- to
# journald AND the root-only /var/log/ai-tools/handback.log, the socket-layer counterpart to
# the helpers' chown.log/setgid.log/symlink.log.  Only the root daemon writes the file; the
# agent-side client cannot (DAC), so it stays journald-only.
#
# Deploy: install.sh deploys src/usr/local/sbin/ai-tools/ai-tools-handback.py
# to /usr/local/sbin/ai-tools/ai-tools-handback (750 root:root, @SANDBOX_USER@
# substituted by install_subst).

import datetime
import os
import pwd
import signal
import socket
import struct
import subprocess
import sys
import unicodedata  # used by the deferred _sanitize_unicode_controlchars detector below

_SANDBOX_USER = '@SANDBOX_USER@'

# Durable operation trail, co-located with the root helpers' own logs under the root-only
# /var/log/ai-tools (dir 0700, files 0600 root:root; labelled ai_tools_log_t, which
# ai_tools_handback_t may create/append -- see ai_tools.te). The daemon runs as root, so it
# can write it; the client runs as the agent and cannot (DAC), so the file trail is the
# daemon's alone, while the client stays journald-only. _audit records the events a reader
# of chown.log/setgid.log/symlink.log would NOT otherwise see -- rejected peers, malformed
# or refused requests, helper timeouts/exec failures -- plus one line per served request, so
# the bridge's own activity is visible rather than inferred from the helpers' logs.
_LOG_FILE = '/var/log/ai-tools/handback.log'

# sd-daemon log-level prefixes: systemd's journal stream parses a leading "<N>" as the
# syslog priority, so `journalctl -t ai-tools-handback -p warning` filters correctly without
# spawning logger(1) (a subprocess the tight SystemCallFilter is better off not needing).
_PRIO = {'error': '<3>', 'warning': '<4>', 'notice': '<5>', 'info': '<6>', 'debug': '<7>'}


def _sanitize(msg):
    # type: (str) -> str
    # Reduce the message to safe-for-display characters before it reaches either sink. A
    # default-deny allowlist mirroring log.lib.sh's ai_tools_log_sanitize: keep only printable
    # ASCII (0x20-0x7E) and replace every other code point -- ASCII controls, and the whole
    # Unicode control/format/bidi space -- with '?'. Allowing a known-safe set (rather than
    # blocklisting an open-ended set of dangerous code points) rejects every unknown by
    # construction. The request-arg pre-filter already rejects a control BYTE, but a bidi
    # override or zero-width character is a valid path byte that reaches this trail via the
    # served-request line, so it is reduced here. (A deferred detector that instead flags such
    # bytes as a malicious-attempt signal is noted in logging.rule.md.)
    return ''.join(c if ' ' <= c <= '~' else '?' for c in msg)


def _sanitize_unicode_controlchars(msg):
    # type: (str) -> str
    # DEFERRED -- retained, not yet called. The complement to _sanitize (the allowlist): where
    # that reduces every non-ASCII code point to '?' for safe display, this targets exactly the
    # control/format/bidi space -- Unicode general categories Cc, Cf, Cs, Co plus the
    # line/paragraph separators Zl, Zp (U+2028/2029), and via unicodedata it also catches the
    # astral tag characters (U+E0000-E007F) -- leaving ordinary text, spaces, and legitimate
    # multi-byte UTF-8 intact. A sane agent never emits these in a path, so their presence is a
    # malicious-attempt signal worth quarantine-logging rather than silently reducing. Kept so
    # the authoritative UCD-backed set is not lost; wire it into a quarantine sink when that
    # detector is built (see the "## Deferred" section of logging.rule.md).
    return ''.join(
        '?' if unicodedata.category(c) in ('Cc', 'Cf', 'Cs', 'Co', 'Zl', 'Zp') else c
        for c in msg
    )


def _audit(level, msg):
    # type: (str, str) -> None
    # Two sinks, mirroring log.lib.sh: journald via stderr (StandardError=journal; systemd
    # stamps the timestamp + identifier, the "<N>" prefix the priority) ALWAYS, and the
    # root-only file with an explicit "<ts> <LEVEL> [<pid>] <msg>" line matching the helpers'
    # format. Both are best-effort: a failed write never aborts or delays the handback. The
    # message is reduced to safe-for-display characters once for both sinks; if anything was
    # replaced it is flagged inline (a non-standard byte where a path is expected is a probe
    # worth recording). The marker is pure ASCII, so it cannot itself re-trigger a replacement.
    clean = _sanitize(msg)
    if clean != msg:
        clean += '  [!] non-standard characters replaced'
    msg = clean
    try:
        sys.stderr.write(_PRIO.get(level, '<6>') + msg + '\n')
        sys.stderr.flush()
    except OSError:
        pass
    try:
        stamp = datetime.datetime.now().astimezone().replace(microsecond=0).isoformat()
        line = '%s %-7s [%d] %s\n' % (stamp, level.upper(), os.getpid(), msg)
        fd = os.open(_LOG_FILE, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, line.encode('utf-8', 'replace'))
        finally:
            os.close(fd)
    except OSError:
        pass

# Request line is capped at _MAX_LINE bytes (binary read) so a client that omits
# the trailing newline cannot force the handler to buffer arbitrarily large data.
# PATH_MAX on Linux is 4096; adding the verb, space, and newline still fits well
# within 8192 bytes.
_MAX_LINE = 8192

# Seconds to wait for the client to send a request after the SO_PEERCRED check.
# A client that connects and then idles would otherwise hold a root process
# forever.  SIGALRM interrupts the blocked read() at the OS level.
_READ_TIMEOUT = 30

# Wall-clock cap on a single helper invocation.  The SIGALRM above only bounds the
# read phase; without this a helper that stalls (a SETGID walk over a huge tree, or
# realpath on a hung autofs/NFS mount) would hold a root process indefinitely, and
# up to MaxConnections of them at once.  120s is far above any legitimate handback.
_HELPER_TIMEOUT = 120

# Defensive bound on the argument length.  Every verb takes an absolute filesystem
# path; PATH_MAX is 4096, so anything longer is malformed by construction.  This is
# a fail-fast pre-filter, NOT a substitute for the helpers' own validation.
_MAX_ARG = 4096

# Cap on how many helper-stderr lines are relayed back as MSG lines, so a helper bug
# that floods stderr cannot turn into an unbounded write loop on the socket.  The
# current helpers emit at most a few lines.
_MAX_MSG_LINES = 50

_HELPERS = {
    'CHOWN':   '/usr/local/sbin/ai-tools/ai-tools-chown',
    'SETGID':  '/usr/local/sbin/ai-tools/ai-tools-setgid',
    'SYMLINK': '/usr/local/sbin/ai-tools/ai-tools-claude-symlink',
}


def _send(text):
    # type: (str) -> None
    # BrokenPipeError means the client disconnected before we could respond.
    # Swallow it: the handler exits cleanly without a spurious traceback in the
    # journal.
    try:
        sys.stdout.write(text + '\n')
        sys.stdout.flush()
    except BrokenPipeError:
        pass


def main():
    # Resolve the expected sandbox UID at startup.  A missing account means nothing
    # valid can connect, so refuse all requests (fail closed).
    try:
        expected_uid = pwd.getpwnam(_SANDBOX_USER).pw_uid
    except KeyError:
        _audit('error', 'unknown sandbox user %r' % _SANDBOX_USER)
        _send('ERR internal: unknown sandbox user %s' % _SANDBOX_USER)
        sys.exit(1)

    # stdin (fd 0) is the accepted AF_UNIX socket.  Duplicate it into a socket
    # object to call getsockopt(SO_PEERCRED), then close the dup so only fd 0 /
    # sys.stdin remain for I/O.  struct ucred on Linux: { pid_t(i), uid_t(I), gid_t(I) }
    try:
        sock = socket.fromfd(sys.stdin.fileno(), socket.AF_UNIX, socket.SOCK_STREAM)
        cred_raw = sock.getsockopt(
            socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize('iII')
        )
        sock.close()
    except OSError as exc:
        _audit('error', 'SO_PEERCRED check failed: %s' % exc)
        _send('ERR internal: credential check failed')
        sys.exit(1)

    peer_pid, peer_uid, _ = struct.unpack('iII', cred_raw)
    if peer_uid != expected_uid:
        _audit('warning',
               'rejected uid %d pid %d (want uid %d)' % (peer_uid, peer_pid, expected_uid))
        _send('ERR unauthorized uid %d' % peer_uid)
        sys.exit(1)

    # Read exactly one request line.  Two independent guards prevent this blocking
    # forever or exhausting memory:
    #
    #   1. SIGALRM fires after _READ_TIMEOUT seconds and exits the process.
    #      The signal interrupts the blocked read() at the OS level (the Python
    #      wrapper raises InterruptedError or the handler calls sys.exit directly).
    #      The finally block cancels the alarm as soon as the read completes.
    #
    #   2. sys.stdin.buffer.readline(_MAX_LINE) caps the read at _MAX_LINE bytes.
    #      Reading via the binary buffer keeps the cap in bytes rather than decoded
    #      characters, so a run of multi-byte UTF-8 cannot sneak past the limit.
    def _on_alarm(signum, frame):  # type: ignore[override]
        _audit('warning', 'timeout: no request received in %ds' % _READ_TIMEOUT)
        sys.exit(1)

    signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(_READ_TIMEOUT)
    try:
        raw = sys.stdin.buffer.readline(_MAX_LINE)
        line = raw.decode('utf-8', errors='replace').rstrip('\n')
    except OSError as exc:
        _audit('error', 'read error: %s' % exc)
        _send('ERR read error')
        sys.exit(1)
    finally:
        signal.alarm(0)  # cancel the alarm once the read completes

    if not line:
        _audit('warning', 'empty request from pid %d' % peer_pid)
        _send('ERR empty request')
        sys.exit(1)

    parts = line.split(' ', 1)
    # .strip() on the verb tolerates a stray CR (CRLF-terminated client) so it does
    # not turn an otherwise-valid verb into "unknown verb".
    verb = parts[0].strip().upper()
    arg = parts[1].strip() if len(parts) > 1 else ''

    if verb not in _HELPERS:
        _audit('warning', 'unknown verb %r from pid %d' % (verb, peer_pid))
        _send('ERR unknown verb %r' % verb)
        sys.exit(1)
    if not arg:
        _audit('warning', 'missing argument for %s from pid %d' % (verb, peer_pid))
        _send('ERR missing argument for %s' % verb)
        sys.exit(1)

    # Fail-fast pre-filter (defense in depth, NOT a replacement for the helpers'
    # validation): every verb takes an absolute path, so reject anything that is not
    # absolute, is longer than PATH_MAX, or carries control characters (including the
    # embedded NUL that execve(2) rejects).  A malformed request never reaches a
    # helper; a well-formed one is still fully re-validated there.
    if not arg.startswith('/') or len(arg) > _MAX_ARG \
            or any(ord(c) < 0x20 or ord(c) == 0x7f for c in arg):
        _audit('warning', 'rejected malformed arg for %s (pid %d)' % (verb, peer_pid))
        _send('ERR malformed argument')
        sys.exit(1)

    # Execute the matching root helper.  stdin=/dev/null forces the non-interactive
    # branch (no TTY prompts) -- same as the previous `sudo ... </dev/null`.
    # Capture stderr to relay NOTICE lines back to the client; also echo each to our
    # own stderr so they reach the journal regardless (StandardError=journal in the
    # service template).
    #
    # ValueError is raised when arg contains an embedded null byte: Python refuses
    # to pass it to execve(2) because C strings are null-terminated.  The pre-filter
    # above already rejects NUL, but catching it here keeps the exec robust against
    # any future change to that filter.
    # TimeoutExpired bounds a stalled helper at _HELPER_TIMEOUT (see above); the
    # child is killed and the request fails cleanly rather than pinning a root
    # process.  stderr captured before the timeout is discarded with the child.
    try:
        result = subprocess.run(
            [_HELPERS[verb], arg],
            stdin=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=_HELPER_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        _audit('error',
               '%s timed out after %ds (pid %d)' % (verb, _HELPER_TIMEOUT, peer_pid))
        _send('ERR helper timed out')
        sys.exit(1)
    except (OSError, ValueError) as exc:
        _audit('error', 'exec %r failed: %s' % (_HELPERS[verb], exc))
        _send('ERR exec failed: %s' % exc)
        sys.exit(1)

    stderr_text = (
        result.stderr.decode('utf-8', errors='replace') if result.stderr else ''
    )
    for line in stderr_text.splitlines()[:_MAX_MSG_LINES]:
        # Sanitize before relaying: the helpers already reduce agent-named paths in their
        # NOTICEs, but the daemon does not trust that -- a relayed line reaches journald AND
        # the agent session's terminal, so it must not carry a raw control/escape byte here.
        msg = _sanitize(line)
        sys.stderr.write(msg + '\n')          # → journal
        safe = msg.strip()[:500]
        if safe:
            _send('MSG ' + safe)              # → client → hook stderr → session

    # One served-request line so the bridge's activity is visible in its own log rather than
    # inferred from the helpers'. A non-zero helper exit is NOT necessarily an error (e.g.
    # ai-tools-chown exits 1 for a path outside the allowlist, a routine skip), so the served
    # line stays INFO and records the code; the daemon-level failures above carry the
    # WARNING/ERROR levels.
    if result.returncode == 0:
        _audit('info', 'served %s pid=%d arg=%s -> OK' % (verb, peer_pid, arg))
        _send('OK')
    else:
        _audit('info',
               'served %s pid=%d arg=%s -> ERR(%d)' % (verb, peer_pid, arg, result.returncode))
        _send('ERR helper exited %d' % result.returncode)


if __name__ == '__main__':
    main()
