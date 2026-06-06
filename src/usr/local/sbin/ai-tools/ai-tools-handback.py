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
# Deploy: install.sh deploys src/usr/local/sbin/ai-tools/ai-tools-handback.py
# to /usr/local/sbin/ai-tools/ai-tools-handback (750 root:root, @SANDBOX_USER@
# substituted by install_subst).

import pwd
import signal
import socket
import struct
import subprocess
import sys

_SANDBOX_USER = '@SANDBOX_USER@'

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
        sys.stderr.write(
            'ai-tools-handback: unknown sandbox user %r\n' % _SANDBOX_USER
        )
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
        sys.stderr.write('ai-tools-handback: SO_PEERCRED: %s\n' % exc)
        _send('ERR internal: credential check failed')
        sys.exit(1)

    peer_pid, peer_uid, _ = struct.unpack('iII', cred_raw)
    if peer_uid != expected_uid:
        sys.stderr.write(
            'ai-tools-handback: rejected uid %d pid %d (want uid %d)\n'
            % (peer_uid, peer_pid, expected_uid)
        )
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
        sys.stderr.write(
            'ai-tools-handback: timeout: no request received in %ds\n' % _READ_TIMEOUT
        )
        sys.exit(1)

    signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(_READ_TIMEOUT)
    try:
        raw = sys.stdin.buffer.readline(_MAX_LINE)
        line = raw.decode('utf-8', errors='replace').rstrip('\n')
    except OSError as exc:
        sys.stderr.write('ai-tools-handback: read: %s\n' % exc)
        _send('ERR read error')
        sys.exit(1)
    finally:
        signal.alarm(0)  # cancel the alarm once the read completes

    if not line:
        _send('ERR empty request')
        sys.exit(1)

    parts = line.split(' ', 1)
    # .strip() on the verb tolerates a stray CR (CRLF-terminated client) so it does
    # not turn an otherwise-valid verb into "unknown verb".
    verb = parts[0].strip().upper()
    arg = parts[1].strip() if len(parts) > 1 else ''

    if verb not in _HELPERS:
        _send('ERR unknown verb %r' % verb)
        sys.exit(1)
    if not arg:
        _send('ERR missing argument for %s' % verb)
        sys.exit(1)

    # Fail-fast pre-filter (defense in depth, NOT a replacement for the helpers'
    # validation): every verb takes an absolute path, so reject anything that is not
    # absolute, is longer than PATH_MAX, or carries control characters (including the
    # embedded NUL that execve(2) rejects).  A malformed request never reaches a
    # helper; a well-formed one is still fully re-validated there.
    if not arg.startswith('/') or len(arg) > _MAX_ARG \
            or any(ord(c) < 0x20 or ord(c) == 0x7f for c in arg):
        sys.stderr.write(
            'ai-tools-handback: rejected malformed arg for %s (pid %d)\n'
            % (verb, peer_pid)
        )
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
        sys.stderr.write(
            'ai-tools-handback: %s timed out after %ds (pid %d)\n'
            % (verb, _HELPER_TIMEOUT, peer_pid)
        )
        _send('ERR helper timed out')
        sys.exit(1)
    except (OSError, ValueError) as exc:
        sys.stderr.write('ai-tools-handback: exec %r: %s\n' % (_HELPERS[verb], exc))
        _send('ERR exec failed: %s' % exc)
        sys.exit(1)

    stderr_text = (
        result.stderr.decode('utf-8', errors='replace') if result.stderr else ''
    )
    for msg in stderr_text.splitlines()[:_MAX_MSG_LINES]:
        sys.stderr.write(msg + '\n')          # → journal
        safe = msg.strip()[:500]
        if safe:
            _send('MSG ' + safe)              # → client → hook stderr → session

    if result.returncode == 0:
        _send('OK')
    else:
        _send('ERR helper exited %d' % result.returncode)


if __name__ == '__main__':
    main()
