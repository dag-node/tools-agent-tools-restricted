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
import socket
import struct
import subprocess
import sys

_SANDBOX_USER = '@SANDBOX_USER@'

_HELPERS = {
    'CHOWN':   '/usr/local/sbin/ai-tools/ai-tools-chown',
    'SETGID':  '/usr/local/sbin/ai-tools/ai-tools-setgid',
    'SYMLINK': '/usr/local/sbin/ai-tools/ai-tools-claude-symlink',
}


def _send(text):
    # type: (str) -> None
    sys.stdout.write(text + '\n')
    sys.stdout.flush()


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

    _, peer_uid, _ = struct.unpack('iII', cred_raw)
    if peer_uid != expected_uid:
        sys.stderr.write(
            'ai-tools-handback: rejected uid %d (want %d)\n' % (peer_uid, expected_uid)
        )
        _send('ERR unauthorized uid %d' % peer_uid)
        sys.exit(1)

    # Read exactly one request line (blocks until the client sends it).
    try:
        line = sys.stdin.readline().rstrip('\n')
    except OSError as exc:
        sys.stderr.write('ai-tools-handback: read: %s\n' % exc)
        _send('ERR read error')
        sys.exit(1)

    if not line:
        _send('ERR empty request')
        sys.exit(1)

    parts = line.split(' ', 1)
    verb = parts[0].upper()
    arg = parts[1].strip() if len(parts) > 1 else ''

    if verb not in _HELPERS:
        _send('ERR unknown verb %r' % verb)
        sys.exit(1)
    if not arg:
        _send('ERR missing argument for %s' % verb)
        sys.exit(1)

    # Execute the matching root helper.  stdin=/dev/null forces the non-interactive
    # branch (no TTY prompts) -- same as the previous `sudo ... </dev/null`.
    # Capture stderr to relay NOTICE lines back to the client; also echo each to our
    # own stderr so they reach the journal regardless (StandardError=journal in the
    # service template).
    try:
        result = subprocess.run(
            [_HELPERS[verb], arg],
            stdin=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        sys.stderr.write('ai-tools-handback: exec %r: %s\n' % (_HELPERS[verb], exc))
        _send('ERR exec failed: %s' % exc)
        sys.exit(1)

    stderr_text = (
        result.stderr.decode('utf-8', errors='replace') if result.stderr else ''
    )
    for msg in stderr_text.splitlines():
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
