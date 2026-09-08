#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/bin/ai-tools-handback-client
# Client for the ai-tools handback privilege bridge.
#
# Usage: ai-tools-handback-client VERB ARG
#
# Connects to /run/ai-tools/handback.sock (AF_UNIX SOCK_STREAM), sends one
# "VERB ARG\n" request, reads the response, relays MSG lines to stderr (so the
# calling hook can surface NOTICEs in the agent's session), and exits 0 on
# OK or 1 on ERR/error.
#
# This is how the agent process tree reaches ai-tools-{chown,setgid,launcher-symlink}.
# A `sudo` call cannot serve there: under NNP (PR_SET_NO_NEW_PRIVS, forced by
# RestrictNamespaces=yes in the session service unit) sudo loses its SUID bit and
# keeps running as @SANDBOX_USER@ -- unable to read /etc/sudoers or switch uid -- so
# the call fails silently.  This client uses no SUID at all: it connects a socket
# only root and @SANDBOX_GROUP@ members can reach (0660 SocketGroup=@SANDBOX_GROUP@),
# and the daemon authenticates the connection via SO_PEERCRED.
#
# Installed 750 root:@SANDBOX_GROUP@ as ai-tools-handback-client, with @SANDBOX_GROUP@
# substituted at install: the group execute bit is what lets a session run it, and root
# ownership is what stops the session rewriting it. Deploying from a checkout:
# docs/install-from-source.md.

import socket
import sys

_SOCK_PATH = '/run/ai-tools/handback.sock'


def main():
    if len(sys.argv) != 3:
        sys.stderr.write('usage: %s VERB ARG\n' % sys.argv[0])
        sys.exit(1)

    verb = sys.argv[1].upper()
    arg = sys.argv[2]

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            try:
                sock.connect(_SOCK_PATH)
            except OSError as exc:
                # Name the socket and the likely cause: a bare "[Errno 2] No such file
                # or directory" from connect() gives the caller no next step.
                sys.stderr.write(
                    'ai-tools-handback-client: cannot reach the handback socket %s '
                    '(%s) -- is ai-tools-handback.socket running?\n'
                    % (_SOCK_PATH, exc)
                )
                sys.exit(1)
            sock.sendall(('%s %s\n' % (verb, arg)).encode('utf-8'))
            # Read the response line by line.  sock.makefile() wraps the socket in a
            # buffered text reader; closing it does NOT close the underlying socket
            # (Python documented behaviour), which is then closed by the with block.
            with sock.makefile('r', encoding='utf-8', errors='replace') as sf:
                for line in sf:
                    line = line.rstrip('\n')
                    if line.startswith('MSG '):
                        # Relay helper stderr (NOTICEs, warnings) to our stderr so
                        # the calling hook surfaces them in the agent's session.
                        sys.stderr.write(line[4:] + '\n')
                    elif line == 'OK':
                        sys.exit(0)
                    elif line.startswith('ERR'):
                        reason = line[4:] if len(line) > 4 else '(no reason)'
                        sys.stderr.write(
                            'ai-tools-handback-client: %s\n' % reason
                        )
                        sys.exit(1)
    except OSError as exc:
        sys.stderr.write('ai-tools-handback-client: %s\n' % exc)
        sys.exit(1)

    # Fell through with no OK or ERR -- daemon closed the connection without a
    # terminal response (crash, protocol error).
    sys.stderr.write('ai-tools-handback-client: incomplete response\n')
    sys.exit(1)


if __name__ == '__main__':
    main()
